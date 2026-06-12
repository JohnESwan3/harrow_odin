package main

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
}

renderer: struct {
	pip:       sg.Pipeline,
	soft_pip:  sg.Pipeline, // alpha-blended, no depth write (dust/smoke)
	vox_pip:   sg.Pipeline,
	vbuf:      sg.Buffer,
	ibuf:      sg.Buffer,
	dyn_inst:  sg.Buffer,
	soft_inst: sg.Buffer,
	dyn:       [dynamic]Instance,
	soft:      [dynamic]Instance,
	view_inst: [dynamic]Instance,
	light:     Lighting,
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

render_uniforms :: proc(cam: Camera, aspect: f32) -> (Vs_Params, Fs_Params) {
	l := renderer.light
	vs := Vs_Params{view_proj = camera_view_proj(cam, aspect)}
	fs := Fs_Params{
		eye_pos    = {cam.pos.x, cam.pos.y, cam.pos.z, 0},
		sun_dir    = {l.sun_dir.x, l.sun_dir.y, l.sun_dir.z, 0},
		sun_color  = {l.sun_color.x, l.sun_color.y, l.sun_color.z, 0},
		ambient_up = {l.ambient_up.x, l.ambient_up.y, l.ambient_up.z, 0},
		ambient_dn = {l.ambient_dn.x, l.ambient_dn.y, l.ambient_dn.z, 0},
		fog_color  = {l.fog_color.x, l.fog_color.y, l.fog_color.z, l.fog_density},
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

viewmodel_inst: sg.Buffer // lazily created stream buffer for the viewmodel pass

// pass 2: first-person viewmodel, depth cleared so it never clips into walls.
// UI (sgl/sdtx) is drawn by the caller inside this same pass.
render_viewmodel_pass_begin :: proc(cam: Camera, width, height: f32) {
	sg.begin_pass({
		action = {
			colors = {0 = {load_action = .LOAD}},
			depth = {load_action = .CLEAR, clear_value = 1.0},
		},
		swapchain = sglue.swapchain(),
	})
	if len(renderer.view_inst) > 0 {
		if viewmodel_inst.id == 0 {
			viewmodel_inst = sg.make_buffer({
				usage = {vertex_buffer = true, stream_update = true},
				size = MAX_DYN_INSTANCES * size_of(Instance),
			})
		}
		vs, fs := render_uniforms(cam, width / height)
		sg.update_buffer(viewmodel_inst, {ptr = raw_data(renderer.view_inst), size = uint(len(renderer.view_inst) * size_of(Instance))})
		sg.apply_pipeline(renderer.pip)
		sg.apply_bindings({
			vertex_buffers = {0 = renderer.vbuf, 1 = viewmodel_inst},
			index_buffer = renderer.ibuf,
		})
		sg.apply_uniforms(UB_vs_params, {ptr = &vs, size = size_of(vs)})
		sg.apply_uniforms(UB_fs_params, {ptr = &fs, size = size_of(fs)})
		sg.draw(0, 36, len(renderer.view_inst))
	}
	clear(&renderer.view_inst)
}
