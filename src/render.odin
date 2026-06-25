package main

import "core:math"
import sg "../sokol/gfx"
import sglue "../sokol/glue"
import slog "../sokol/log"

// Instanced-cube renderer. Everything in the greybox world — environment,
// players, weapons, tracers, projectiles — is a transformed unit cube.

MAX_DYN_INSTANCES :: 8192

Instance :: struct {
	model: Mat4, // column-major, feeds 4 vec4 instance attrs
	color: Vec4,
}

Camera :: struct {
	pos:        Vec3,
	yaw, pitch: f32,
	fov:        f32,
}

Lighting :: struct {
	sun_dir:     Vec3,
	sun_color:   Vec3,
	ambient_up:  Vec3,
	ambient_dn:  Vec3,
	fog_color:   Vec3,
	fog_density: f32,
	// flashlight (camera spot)
	flash_on:    bool,
	flash_pos:   Vec3,
	flash_dir:   Vec3,
	flash_color: Vec3,
}

DAY_LENGTH :: 600.0 // seconds per full cycle

// drive sun/moon, ambient, and fog from time-of-day (0..1, 0.25 = sunrise)
lighting_update :: proc(tod: f32) {
	l := &renderer.light
	ang := (tod - 0.25) * math.PI * 2
	elev := math.sin(ang)
	to_sun := vnorm(Vec3{math.cos(ang) * 0.85, elev, 0.4})

	day_f := smoothstep(-0.04, 0.14, elev)
	moon_f := smoothstep(0.02, 0.22, -elev)

	warm := Vec3{1.0, 0.50, 0.26}
	noon := Vec3{1.0, 0.93, 0.80}
	sun_col := vlerp(warm, noon, smoothstep(0.0, 0.45, elev)) * (1.45 * day_f)
	moon_col := Vec3{0.40, 0.50, 0.72} * (0.34 * moon_f)

	if day_f >= moon_f {
		l.sun_dir = -to_sun
		l.sun_color = sun_col + moon_col * 0.3
	} else {
		// the moon rides the opposite arc, slightly offset
		to_moon := vnorm(Vec3{-to_sun.x, -elev * 0.9 + 0.12, -to_sun.z * 0.8})
		if to_moon.y < 0.08 do to_moon = vnorm(Vec3{to_moon.x, 0.08, to_moon.z})
		l.sun_dir = -to_moon
		l.sun_color = moon_col
	}

	day_amb_up := Vec3{0.20, 0.24, 0.32}
	day_amb_dn := Vec3{0.11, 0.10, 0.095}
	night_amb_up := Vec3{0.012, 0.018, 0.038}
	night_amb_dn := Vec3{0.006, 0.008, 0.014}
	l.ambient_up = vlerp(night_amb_up, day_amb_up, day_f) + Vec3{0.018, 0.026, 0.05} * moon_f
	l.ambient_dn = vlerp(night_amb_dn, day_amb_dn, day_f) + Vec3{0.008, 0.012, 0.022} * moon_f

	day_fog := Vec3{0.26, 0.27, 0.33}
	night_fog := Vec3{0.012, 0.016, 0.034}
	sunset := math.exp(-elev * elev * 28.0) * day_f
	l.fog_color = vlerp(night_fog, day_fog, day_f) + Vec3{0.22, 0.07, 0.0} * sunset
}

renderer: struct {
	pip:       sg.Pipeline,
	vm_pip:    sg.Pipeline, // viewmodel (near=0.01, writes CoC to alpha)
	dof_pip:   sg.Pipeline, // fullscreen DOF composite
	soft_pip:  sg.Pipeline, // alpha-blended, no depth write (dust/smoke)
	vox_pip:   sg.Pipeline,
	vbuf:      sg.Buffer,
	ibuf:      sg.Buffer,
	dyn_inst:  sg.Buffer,
	soft_inst: sg.Buffer,
	dof_quad:  sg.Buffer,   // fullscreen quad for DOF composite
	dyn:       [dynamic]Instance,
	soft:      [dynamic]Instance,
	view_inst: [dynamic]Instance,
	light:     Lighting,
}

// Offscreen render target for the viewmodel pass.
vm_rt: struct {
	color_img: sg.Image,
	depth_img: sg.Image,
	color_att: sg.View, // render-into view
	depth_att: sg.View,
	tex_view:  sg.View, // texture-sample view for DOF composite
	smp:       sg.Sampler,
	w, h:      i32,
}

render_init :: proc() {
	sg.setup({
		environment = sglue.environment(),
		buffer_pool_size = 32768, // two buffers per streamed voxel tile/chunk
		logger = {func = slog.func},
	})

	// unit cube, 24 verts (pos + normal), centered at origin
	V :: 0.5
	vertices := [?]f32{
		// +Z
		-V, -V, V, 0, 0, 1,  V, -V, V, 0, 0, 1,  V, V, V, 0, 0, 1,  -V, V, V, 0, 0, 1,
		// -Z
		V, -V, -V, 0, 0, -1,  -V, -V, -V, 0, 0, -1,  -V, V, -V, 0, 0, -1,  V, V, -V, 0, 0, -1,
		// +X
		V, -V, V, 1, 0, 0,  V, -V, -V, 1, 0, 0,  V, V, -V, 1, 0, 0,  V, V, V, 1, 0, 0,
		// -X
		-V, -V, -V, -1, 0, 0,  -V, -V, V, -1, 0, 0,  -V, V, V, -1, 0, 0,  -V, V, -V, -1, 0, 0,
		// +Y
		-V, V, V, 0, 1, 0,  V, V, V, 0, 1, 0,  V, V, -V, 0, 1, 0,  -V, V, -V, 0, 1, 0,
		// -Y
		-V, -V, -V, 0, -1, 0,  V, -V, -V, 0, -1, 0,  V, -V, V, 0, -1, 0,  -V, -V, V, 0, -1, 0,
	}
	indices: [36]u16
	for f in 0 ..< 6 {
		b := u16(f * 4)
		copy(indices[f * 6:], []u16{b, b + 1, b + 2, b, b + 2, b + 3})
	}

	renderer.vbuf = sg.make_buffer({
		data = {ptr = &vertices, size = size_of(vertices)},
	})
	renderer.ibuf = sg.make_buffer({
		usage = {index_buffer = true},
		data = {ptr = &indices, size = size_of(indices)},
	})
	renderer.dyn_inst = sg.make_buffer({
		usage = {vertex_buffer = true, stream_update = true},
		size = MAX_DYN_INSTANCES * size_of(Instance),
	})

	renderer.pip = sg.make_pipeline({
		shader = sg.make_shader(world_shader_desc(sg.query_backend())),
		layout = {
			buffers = {
				0 = {stride = 24},
				1 = {stride = size_of(Instance), step_func = .PER_INSTANCE},
			},
			attrs = {
				ATTR_world_a_pos = {format = .FLOAT3, buffer_index = 0},
				ATTR_world_a_norm = {format = .FLOAT3, buffer_index = 0},
				ATTR_world_i_col0 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_col1 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_col2 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_col3 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_color = {format = .FLOAT4, buffer_index = 1},
			},
		},
		index_type = .UINT16,
		cull_mode = .BACK,
		face_winding = .CCW, // mesh is CCW; sokol defaults to CW and culls the wrong side
		depth = {write_enabled = true, compare = .LESS_EQUAL},
	})

	renderer.soft_inst = sg.make_buffer({
		usage = {vertex_buffer = true, stream_update = true},
		size = MAX_DYN_INSTANCES * size_of(Instance),
	})
	renderer.soft_pip = sg.make_pipeline({
		shader = sg.make_shader(world_shader_desc(sg.query_backend())),
		layout = {
			buffers = {
				0 = {stride = 24},
				1 = {stride = size_of(Instance), step_func = .PER_INSTANCE},
			},
			attrs = {
				ATTR_world_a_pos = {format = .FLOAT3, buffer_index = 0},
				ATTR_world_a_norm = {format = .FLOAT3, buffer_index = 0},
				ATTR_world_i_col0 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_col1 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_col2 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_col3 = {format = .FLOAT4, buffer_index = 1},
				ATTR_world_i_color = {format = .FLOAT4, buffer_index = 1},
			},
		},
		index_type = .UINT16,
		cull_mode = .NONE, // see through puffs from any side
		face_winding = .CCW,
		depth = {write_enabled = false, compare = .LESS_EQUAL},
		colors = {
			0 = {
				blend = {
					enabled = true,
					src_factor_rgb = .SRC_ALPHA,
					dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
					src_factor_alpha = .ONE,
					dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
				},
			},
		},
	})

	renderer.vox_pip = sg.make_pipeline({
		shader = sg.make_shader(voxel_shader_desc(sg.query_backend())),
		layout = {
			attrs = {
				ATTR_voxel_a_pos = {format = .FLOAT3},
				ATTR_voxel_a_norm = {format = .BYTE4N},
				ATTR_voxel_a_color = {format = .UBYTE4N},
			},
		},
		index_type = .UINT32,
		cull_mode = .BACK,
		face_winding = .CCW,
		depth = {write_enabled = true, compare = .LESS_EQUAL},
	})

	// Viewmodel pipeline — same cube layout as pip but renders to a 1-sample
	// offscreen RT and uses vm_world shader (writes near-DOF CoC into alpha).
	renderer.vm_pip = sg.make_pipeline({
		shader = sg.make_shader(vm_world_shader_desc(sg.query_backend())),
		layout = {
			buffers = {
				0 = {stride = 24},
				1 = {stride = size_of(Instance), step_func = .PER_INSTANCE},
			},
			attrs = {
				ATTR_vm_world_a_pos   = {format = .FLOAT3, buffer_index = 0},
				ATTR_vm_world_a_norm  = {format = .FLOAT3, buffer_index = 0},
				ATTR_vm_world_i_col0  = {format = .FLOAT4, buffer_index = 1},
				ATTR_vm_world_i_col1  = {format = .FLOAT4, buffer_index = 1},
				ATTR_vm_world_i_col2  = {format = .FLOAT4, buffer_index = 1},
				ATTR_vm_world_i_col3  = {format = .FLOAT4, buffer_index = 1},
				ATTR_vm_world_i_color = {format = .FLOAT4, buffer_index = 1},
			},
		},
		index_type   = .UINT16,
		cull_mode    = .BACK,
		face_winding = .CCW,
		depth        = {write_enabled = true, compare = .LESS_EQUAL},
		sample_count = 1, // must match the 1-sample offscreen RT
	})

	// DOF composite pipeline — fullscreen triangle strip, no depth, no blending.
	// background pixels are discarded in the shader to reveal the world.
	dof_verts := [?]f32{
		// pos.x, pos.y, uv.x, uv.y  (triangle strip: BL BR TL TR)
		// V is flipped: D3D11 render targets store rows top-to-bottom,
		// opposite to what the GLSL Y-flip convention produces.
		-1, -1,  0, 1,
		 1, -1,  1, 1,
		-1,  1,  0, 0,
		 1,  1,  1, 0,
	}
	renderer.dof_quad = sg.make_buffer({
		data = {ptr = &dof_verts, size = size_of(dof_verts)},
	})
	renderer.dof_pip = sg.make_pipeline({
		shader = sg.make_shader(vm_dof_shader_desc(sg.query_backend())),
		layout = {
			attrs = {
				ATTR_vm_dof_a_pos = {format = .FLOAT2},
				ATTR_vm_dof_a_uv  = {format = .FLOAT2},
			},
		},
		primitive_type = .TRIANGLE_STRIP,
		depth          = {write_enabled = false, compare = .ALWAYS},
	})

	// Bilinear sampler for the viewmodel RT (no mips, clamp to edge).
	vm_rt.smp = sg.make_sampler({
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		wrap_u     = .CLAMP_TO_EDGE,
		wrap_v     = .CLAMP_TO_EDGE,
	})

	pbr_textures_init()

	// dusk mood: warm low sun, cool fog thick enough to hide the stream edge
	renderer.light = {
		sun_dir     = vnorm({-0.45, -0.42, 0.55}),
		sun_color   = {1.0, 0.62, 0.38} * 1.5,
		ambient_up  = {0.20, 0.24, 0.32},
		ambient_dn  = {0.11, 0.10, 0.095},
		fog_color   = {0.26, 0.27, 0.33},
		fog_density = 0.014,
	}
}

push_cube :: proc(model: Mat4, color: Vec4) {
	if len(renderer.dyn) < MAX_DYN_INSTANCES do append(&renderer.dyn, Instance{model = model, color = color})
}

push_view_cube :: proc(model: Mat4, color: Vec4) {
	if len(renderer.view_inst) < MAX_DYN_INSTANCES do append(&renderer.view_inst, Instance{model = model, color = color})
}

// translucent dust/smoke; drawn after opaques without depth writes
push_cube_soft :: proc(model: Mat4, color: Vec4) {
	if len(renderer.soft) < MAX_DYN_INSTANCES do append(&renderer.soft, Instance{model = model, color = color})
}

camera_view_proj :: proc(cam: Camera, aspect: f32) -> Mat4 {
	fwd := dir_from_angles(cam.yaw, cam.pitch)
	proj := mat4_persp(cam.fov, aspect, 0.05, 400)
	view := mat4_lookat(cam.pos, cam.pos + fwd, {0, 1, 0})
	return proj * view
}

// Separate near/far for the viewmodel: near=0.01 m prevents gun clipping.
camera_viewmodel_vp :: proc(cam: Camera, aspect: f32) -> Mat4 {
	fwd  := dir_from_angles(cam.yaw, cam.pitch)
	proj := mat4_persp(cam.fov, aspect, 0.01, 40)
	view := mat4_lookat(cam.pos, cam.pos + fwd, {0, 1, 0})
	return proj * view
}

// Create or resize the viewmodel offscreen RT.
ensure_vm_rt :: proc(w, h: i32) {
	if vm_rt.w == w && vm_rt.h == h { return }
	if vm_rt.tex_view.id  != 0 { sg.destroy_view(vm_rt.tex_view);   vm_rt.tex_view  = {} }
	if vm_rt.depth_att.id != 0 { sg.destroy_view(vm_rt.depth_att);  vm_rt.depth_att = {} }
	if vm_rt.color_att.id != 0 { sg.destroy_view(vm_rt.color_att);  vm_rt.color_att = {} }
	if vm_rt.depth_img.id != 0 { sg.destroy_image(vm_rt.depth_img); vm_rt.depth_img = {} }
	if vm_rt.color_img.id != 0 { sg.destroy_image(vm_rt.color_img); vm_rt.color_img = {} }
	vm_rt.color_img = sg.make_image({
		usage        = {color_attachment = true},
		width        = w,
		height       = h,
		pixel_format = .RGBA8,
		sample_count = 1,
	})
	vm_rt.depth_img = sg.make_image({
		usage        = {depth_stencil_attachment = true},
		width        = w,
		height       = h,
		pixel_format = .DEPTH,
		sample_count = 1,
	})
	vm_rt.color_att = sg.make_view({color_attachment        = {image = vm_rt.color_img}})
	vm_rt.depth_att = sg.make_view({depth_stencil_attachment = {image = vm_rt.depth_img}})
	vm_rt.tex_view  = sg.make_view({texture                  = {image = vm_rt.color_img}})
	vm_rt.w = w
	vm_rt.h = h
}

FLASH_INNER_COS :: 0.93
FLASH_OUTER_COS :: 0.82

render_uniforms :: proc(cam: Camera, aspect: f32) -> (Vs_Params, Fs_Params) {
	l := renderer.light
	vs := Vs_Params{view_proj = camera_view_proj(cam, aspect)}
	fs := Fs_Params{
		eye_pos     = {cam.pos.x, cam.pos.y, cam.pos.z, 0},
		sun_dir     = {l.sun_dir.x, l.sun_dir.y, l.sun_dir.z, 0},
		sun_color   = {l.sun_color.x, l.sun_color.y, l.sun_color.z, 0},
		ambient_up  = {l.ambient_up.x, l.ambient_up.y, l.ambient_up.z, 0},
		ambient_dn  = {l.ambient_dn.x, l.ambient_dn.y, l.ambient_dn.z, 0},
		fog_color   = {l.fog_color.x, l.fog_color.y, l.fog_color.z, l.fog_density},
		flash_pos   = {l.flash_pos.x, l.flash_pos.y, l.flash_pos.z, l.flash_on ? 1.0 : 0.0},
		flash_dir   = {l.flash_dir.x, l.flash_dir.y, l.flash_dir.z, FLASH_OUTER_COS},
		flash_color = {l.flash_color.x, l.flash_color.y, l.flash_color.z, FLASH_INNER_COS},
	}
	return vs, fs
}

// pass 1: world + dynamic instances, clears to fog color
render_world_pass :: proc(cam: Camera, width, height: f32) {
	fc := renderer.light.fog_color
	sky := Vec3{
		1.0 - (1.0 - fc.x) * (1.0 - fc.x),
		1.0 - (1.0 - fc.y) * (1.0 - fc.y),
		1.0 - (1.0 - fc.z) * (1.0 - fc.z),
	} // cheap gamma-ish match with fog curve in shader
	sg.begin_pass({
		action = {
			colors = {0 = {load_action = .CLEAR, clear_value = {sky.x, sky.y, sky.z, 1}}},
		},
		swapchain = sglue.swapchain(),
	})
	vs, fs := render_uniforms(cam, width / height)

	// voxel terrain chunks (frustum culled)
	sg.apply_pipeline(renderer.vox_pip)
	voxel_draw(frustum_from(vs.view_proj), &vs, &fs)

	// dynamic instances (players, projectiles, particles, tracers)
	sg.apply_pipeline(renderer.pip)
	if len(renderer.dyn) > 0 {
		sg.update_buffer(renderer.dyn_inst, {ptr = raw_data(renderer.dyn), size = uint(len(renderer.dyn) * size_of(Instance))})
		sg.apply_bindings({
			vertex_buffers = {0 = renderer.vbuf, 1 = renderer.dyn_inst},
			index_buffer = renderer.ibuf,
		})
		sg.apply_uniforms(UB_vs_params, {ptr = &vs, size = size_of(vs)})
		sg.apply_uniforms(UB_fs_params, {ptr = &fs, size = size_of(fs)})
		sg.draw(0, 36, len(renderer.dyn))
	}

	// translucent dust/smoke last
	if len(renderer.soft) > 0 {
		sg.update_buffer(renderer.soft_inst, {ptr = raw_data(renderer.soft), size = uint(len(renderer.soft) * size_of(Instance))})
		sg.apply_pipeline(renderer.soft_pip)
		sg.apply_bindings({
			vertex_buffers = {0 = renderer.vbuf, 1 = renderer.soft_inst},
			index_buffer = renderer.ibuf,
		})
		sg.apply_uniforms(UB_vs_params, {ptr = &vs, size = size_of(vs)})
		sg.apply_uniforms(UB_fs_params, {ptr = &fs, size = size_of(fs)})
		sg.draw(0, 36, len(renderer.soft))
	}
	sg.end_pass()
	clear(&renderer.dyn)
	clear(&renderer.soft)
}

viewmodel_inst: sg.Buffer // stream buffer for viewmodel cubes

// pass 2: render viewmodel to offscreen RT with near=0.01, CoC in alpha.
// Ends the pass — caller follows with render_dof_composite_begin.
render_viewmodel_offscreen :: proc(cam: Camera, width, height: f32) {
	w := i32(width)
	h := i32(height)
	ensure_vm_rt(w, h)
	sg.begin_pass({
		action = {
			colors = {0 = {load_action = .CLEAR, clear_value = {0, 0, 0, 0}}},
			depth  = {load_action = .CLEAR, clear_value = 1.0},
		},
		attachments = {
			colors        = {0 = vm_rt.color_att},
			depth_stencil = vm_rt.depth_att,
		},
	})
	if len(renderer.view_inst) > 0 {
		if viewmodel_inst.id == 0 {
			viewmodel_inst = sg.make_buffer({
				usage = {vertex_buffer = true, stream_update = true},
				size  = MAX_DYN_INSTANCES * size_of(Instance),
			})
		}
		vs, fs := render_uniforms(cam, width / height)
		vs.view_proj = camera_viewmodel_vp(cam, width / height)
		sg.update_buffer(viewmodel_inst, {ptr = raw_data(renderer.view_inst), size = uint(len(renderer.view_inst) * size_of(Instance))})
		sg.apply_pipeline(renderer.vm_pip)
		sg.apply_bindings({
			vertex_buffers = {0 = renderer.vbuf, 1 = viewmodel_inst},
			index_buffer   = renderer.ibuf,
		})
		sg.apply_uniforms(UB_vs_params,    {ptr = &vs, size = size_of(vs)})
		sg.apply_uniforms(UB_vm_fs_params, {ptr = &fs, size = size_of(fs)})
		sg.draw(0, 36, len(renderer.view_inst))
	}
	clear(&renderer.view_inst)
	sg.end_pass()
}

// pass 3: composite the DOF viewmodel over the world, then stay open for UI.
render_dof_composite_begin :: proc(width, height: f32) {
	sg.begin_pass({
		action = {
			colors = {0 = {load_action = .LOAD}},
			depth  = {load_action = .CLEAR, clear_value = 1.0},
		},
		swapchain = sglue.swapchain(),
	})
	if vm_rt.tex_view.id == 0 { return }
	params := Dof_Fs_Params{texel_size = {1.0 / width, 1.0 / height, 0, 0}}
	sg.apply_pipeline(renderer.dof_pip)
	sg.apply_bindings({
		vertex_buffers = {0 = renderer.dof_quad},
		views          = {VIEW_t_vm   = vm_rt.tex_view},
		samplers       = {SMP_smp_vm  = vm_rt.smp},
	})
	sg.apply_uniforms(UB_dof_fs_params, {ptr = &params, size = size_of(params)})
	sg.draw(0, 4, 1)
}
