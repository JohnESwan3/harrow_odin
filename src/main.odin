package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:net"
import "core:os"
import "core:strconv"
import sapp "../sokol/app"
import sg "../sokol/gfx"
import slog "../sokol/log"

SETTINGS_PATH :: "settings.json"

settings_load :: proc() {
	game.settings = default_settings()
	if data, err := os.read_entire_file_from_path(SETTINGS_PATH, context.allocator); err == nil {
		s := default_settings()
		if json.unmarshal(data, &s) == nil && len(s.player_name) > 0 {
			game.settings = s
		}
		delete(data)
	}
	if len(game.settings.player_name) == 0 {
		game.settings.player_name = callsign_random()
	}
	// res_idx is clamped against the dynamic mode list inside display_update_modes.
	game.settings.color_idx = clamp(game.settings.color_idx, 0, MAX_PLAYERS - 1)
	game.name_len = copy(game.name_buf[:], game.settings.player_name)
}

settings_save :: proc() {
	if data, err := json.marshal(game.settings, {pretty = true}); err == nil {
		_ = os.write_entire_file(SETTINGS_PATH, data)
		delete(data)
	}
}

// ---- video settings ---------------------------------------------------------

apply_resolution :: proc() {
	if game.settings.fullscreen { return }
	display_apply_windowed()
}

apply_display_mode :: proc() {
	if game.settings.fullscreen {
		display_apply_fullscreen()
	} else {
		if sapp.is_fullscreen() { sapp.toggle_fullscreen() }
		display_apply_windowed()
	}
}

request_quit :: proc() {
	sapp.request_quit()
}

// dev sanity check of world generation, written to probe.txt (harrow -probe)
world_probe :: proc() {
	sb: [4096]u8
	n := 0
	put :: proc(buf: []u8, n: ^int, s: string) {
		c := copy(buf[n^:], s)
		n^ += c
	}
	trees := 0
	for cj in i32(-43) ..= 43 {
		for ci in i32(-43) ..= 43 {
			if tree_cell_get(ci, cj).ok do trees += 1
		}
	}
	mountain_n := 0
	snow_n := 0
	cave_n := 0
	total := 0
	hmax := f32(0)
	for z := f32(-500); z <= 500; z += 10 {
		for x := f32(-500); x <= 500; x += 10 {
			h := terrain_height(x, z)
			hmax = max(hmax, h)
			if mountain_at(x, z) > 0.3 do mountain_n += 1
			if h > snowline_at(x, z) do snow_n += 1
			if cave_sdf(Vec3{x, h - 7, z}, 7) < 0 do cave_n += 1
			total += 1
		}
	}
	put(sb[:], &n, fmt.tprintf("trees in 600x600m: %d\n", trees))
	put(sb[:], &n, fmt.tprintf("max height: %.1f m\n", hmax))
	put(sb[:], &n, fmt.tprintf("mountain coverage: %.1f%%\n", f32(mountain_n) / f32(total) * 100))
	put(sb[:], &n, fmt.tprintf("snow coverage: %.1f%%\n", f32(snow_n) / f32(total) * 100))
	put(sb[:], &n, fmt.tprintf("cave fraction at depth 7m: %.1f%%\n", f32(cave_n) / f32(total) * 100))
	put(sb[:], &n, fmt.tprintf("stamps: %d  air boxes: %d  spawns: %d\n", len(voxw.stamps), len(voxw.air_boxes), len(voxw.spawns)))
	_ = os.write_entire_file("probe.txt", sb[:n])
}

// ---- app callbacks ------------------------------------------------------------

init_cb :: proc "c" () {
	context = runtime.default_context()
	render_init()
	ui_init()
	input_init()
	// Move/size the window to match the saved monitor + resolution now that
	// the HWND exists (display_enumerate already ran in main()).
	apply_display_mode()
	voxel_world_init()
	game.screen = .Main_Menu
	game.tod = 0.35 // mid-morning
	// pre-stream the menu backdrop
	voxel_stream({0, 20, 0}, 0, sync_radius_m = 56)
	handle_cli_args()
}

// quick-start flags for development and automated testing:
//   harrow -solo | -host "My Server" | -join 192.168.1.10 [-pass secret]
handle_cli_args :: proc() {
	pass := ""
	for arg, i in os.args {
		if arg == "-pass" && i + 1 < len(os.args) do pass = os.args[i + 1]
	}
	for arg, i in os.args {
		switch arg {
		case "-probe":
			world_probe()
			os.exit(0)
		case "-tod":
			if i + 1 < len(os.args) {
				if v, ok := strconv.parse_f32(os.args[i + 1]); ok do game.tod = v
			}
		case "-flash":
			game.flashlight = true
		case "-solo":
			game_start_solo()
		case "-host":
			name := "DEV SERVER"
			if i + 1 < len(os.args) do name = os.args[i + 1]
			game_start_host(name, pass)
		case "-join":
			if i + 1 < len(os.args) {
				if addr := net.parse_address(os.args[i + 1]); addr != nil {
					net_client_start()
					net_client_join(net.Endpoint{address = addr, port = NET_PORT}, pass, game.settings.player_name)
					game.screen = .Join_Browser
				}
			}
		}
	}
}

frame_cb :: proc "c" () {
	context = runtime.default_context()
	dt := f32(clamp(sapp.frame_duration(), 0.0, 0.05))
	game.time += dt

	input_poll_gamepad(dt)
	net_update(dt)

	if game.screen == .In_Game {
		game_update_ingame(dt)
	}

	// world clock; only a solo pause freezes it
	if !(game.paused && nett.role == .None && game.screen == .In_Game) {
		game.tod = math.mod(game.tod + dt / DAY_LENGTH, 1.0)
	}
	lighting_update(game.tod)

	// screen may have changed during update
	cam: Camera
	if game.screen == .In_Game {
		cam = player_camera(local_player())
		game_push_dynamic()
		game_push_viewmodel(cam)
	} else {
		cam = game_menu_camera(dt)
		if sapp.mouse_locked() do sapp.lock_mouse(false)
	}
	voxel_stream(cam.pos, dt)

	// flashlight follows the camera
	renderer.light.flash_on = game.flashlight && game.screen == .In_Game && local_player().alive
	renderer.light.flash_pos = cam.pos + flat_right(cam.yaw) * 0.22 - Vec3{0, 0.12, 0}
	renderer.light.flash_dir = dir_from_angles(cam.yaw, cam.pitch)
	renderer.light.flash_color = FLASH_COLORS[clamp(game.settings.flash_idx, 0, len(FLASH_COLORS) - 1)]

	w := sapp.widthf()
	h := sapp.heightf()
	render_world_pass(cam, w, h)
	render_viewmodel_offscreen(cam, w, h)   // offscreen RT, near=0.01, CoC→alpha
	render_dof_composite_begin(w, h)        // swapchain pass: DOF blur + stays open for UI
	draw_screen(dt)
	sg.end_pass()
	sg.commit()

	input_end_frame()
	free_all(context.temp_allocator)
}

cleanup_cb :: proc "c" () {
	context = runtime.default_context()
	if nett.role == .Host || (nett.role == .None && game.screen == .In_Game) {
		voxel_save()
	}
	settings_save()
	display_restore()
	net_stop()
	ui_shutdown()
}

event_cb :: proc "c" (ev: ^sapp.Event) {
	context = runtime.default_context()
	input_handle_event(ev)
	#partial switch ev.type {
	case .KEY_DOWN:
		if ev.key_code == .F11 {
			game.settings.fullscreen = !game.settings.fullscreen
			apply_display_mode()
		}
	}
}

main :: proc() {
	settings_load()
	display_enumerate() // build monitor + mode list; clamps res/display indices
	res := disp_state.modes[game.settings.res_idx] if disp_state.mode_count > 0 else Disp_Mode{1920, 1080}
	sapp.run({
		init_cb       = init_cb,
		frame_cb      = frame_cb,
		cleanup_cb    = cleanup_cb,
		event_cb      = event_cb,
		width         = res.w,
		height        = res.h,
		fullscreen    = game.settings.fullscreen,
		sample_count  = 4,
		swap_interval = game.settings.vsync ? 1 : 0,
		window_title  = "HARROW",
		icon          = {sokol_default = true},
		logger        = {func = slog.func},
		high_dpi      = true,
	})
}
