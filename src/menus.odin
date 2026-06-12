package main

import "core:fmt"
import "core:math"
import "core:net"

// Menus + HUD. Terse field language; control hints follow the active device.

GAME_TITLE :: "HARROW"
GAME_BUILD :: "ALPHA 0.2 / INTERNAL"

RESOLUTIONS := [?][2]i32{{1280, 720}, {1600, 900}, {1920, 1080}, {2560, 1440}}
RES_NAMES := [?]string{"1280 X 720", "1600 X 900", "1920 X 1080", "2560 X 1440"}
DISPLAY_NAMES := [?]string{"WINDOWED", "FULLSCREEN"}

draw_screen :: proc(dt: f32) {
	ui_begin(dt)
	switch game.screen {
	case .Main_Menu:      draw_main_menu()
	case .Host_Setup:     draw_host_setup()
	case .Join_Browser:   draw_join_browser(dt)
	case .Settings:       draw_settings()
	case .Settings_Video: draw_settings_video()
	case .In_Game:        draw_ingame()
	}
	draw_status_toast(dt)
	if game.settings.show_fps {
		ui_text_right(ui.w - 10 * ui.scale, 8 * ui.scale, 12 * ui.scale, UI_TEXT_DIM,
			fmt.tprintf("%.0f FPS / %d CHUNKS / %dK TRIS", 1.0 / max(dt, 0.0001), vmesh.chunks_drawn, vmesh.tris_drawn / 1000))
	}
	ui_end()
	ui_flush()
}

draw_status_toast :: proc(dt: f32) {
	if game.status_t <= 0 do return
	game.status_t -= dt
	a := clamp(game.status_t, 0, 1)
	msg := game_status_text()
	px := 14 * ui.scale
	w := f32(len(msg)) * px + 36 * ui.scale
	x := (ui.w - w) * 0.5
	y := 86 * ui.scale
	ui_rect(x, y, w, 30 * ui.scale, Vec4{0.03, 0.03, 0.03, 0.85 * a})
	ui_rect(x, y, 3 * ui.scale, 30 * ui.scale, UI_WARN * Vec4{1, 1, 1, a})
	ui_text_center(ui.w * 0.5, y + 8 * ui.scale, px, UI_TEXT * Vec4{1, 1, 1, a}, msg)
}

draw_title_block :: proc() {
	s := ui.scale
	x := 80 * s
	ui_text(x, 70 * s, 58 * s, UI_TEXT, GAME_TITLE)
	ui_text(x + 4 * s, 134 * s, 13 * s, UI_TEXT_DIM, GAME_BUILD)
	ui_rect(x, 160 * s, 400 * s, 1.5 * s, UI_ACCENT_DIM)
}

// hint bar that follows the active input device
draw_hints :: proc() {
	txt: string
	if input.last_device == .Gamepad {
		txt = "D-PAD  NAVIGATE      A  SELECT      B  BACK"
	} else {
		txt = "ARROWS  NAVIGATE      ENTER  SELECT      ESC  BACK"
	}
	ui_text(80 * ui.scale, ui.h - 44 * ui.scale, 12 * ui.scale, UI_TEXT_DIM, txt)
}

draw_main_menu :: proc() {
	draw_title_block()
	s := ui.scale
	x := 80 * s
	y := 220 * s
	bw := 340 * s
	bh := 48 * s
	gap := 14 * s

	if ui_button(x, y, bw, bh, "SINGLEPLAYER") {
		game_start_solo()
	}
	y += bh + gap
	if ui_button(x, y, bw, bh, "HOST") {
		if game.host_name_len == 0 {
			game.host_name_len = copy(game.host_name[:], game.settings.player_name)
		}
		game.screen = .Host_Setup
		ui_reset_focus()
	}
	y += bh + gap
	if ui_button(x, y, bw, bh, "JOIN") {
		game.screen = .Join_Browser
		ui_reset_focus()
		net_client_start()
	}
	y += bh + gap
	if ui_button(x, y, bw, bh, "OPTIONS") {
		game.settings_return = .Main_Menu
		game.screen = .Settings
		ui_reset_focus()
	}
	y += bh + gap
	if ui_button(x, y, bw, bh, "EXIT") {
		request_quit()
	}
	draw_hints()
}

draw_host_setup :: proc() {
	draw_title_block()
	s := ui.scale
	px := 540 * s
	py := 200 * s
	pw := 520 * s
	ui_panel(px, py, pw, 330 * s, "HOST")

	fx := px + 30 * s
	fw := pw - 60 * s
	y := py + 96 * s
	ui_text_field(fx, y, fw, 42 * s, "SERVER NAME", game.host_name[:], &game.host_name_len)
	y += 80 * s
	ui_text_field(fx, y, fw, 42 * s, "PASSWORD", game.host_pass[:], &game.host_pass_len, password = true)
	y += 66 * s

	ui_text(fx, y, 12 * s, UI_TEXT_DIM, fmt.tprintf("UDP %d / LAN DISCOVERY / %d SLOTS", NET_PORT, MAX_PLAYERS))
	y += 30 * s

	if ui_button(fx, y, fw * 0.55, 46 * s, "START") {
		game_start_host(string(game.host_name[:game.host_name_len]), string(game.host_pass[:game.host_pass_len]))
	}
	if ui_button(fx + fw * 0.6, y, fw * 0.4, 46 * s, "BACK") || (ui.nav.back && ui.hot_field < 0) {
		game.screen = .Main_Menu
		ui_reset_focus()
	}
	draw_hints()
}

draw_join_browser :: proc(dt: f32) {
	net_discovery_tick(dt)
	draw_title_block()
	s := ui.scale
	px := 540 * s
	py := 180 * s
	pw := 620 * s
	ui_panel(px, py, pw, 450 * s, "JOIN")

	fx := px + 30 * s
	fw := pw - 60 * s
	y := py + 62 * s

	ui_text(fx, y, 12 * s, UI_TEXT_DIM, nett.joining ? "CONNECTING" : "LAN SERVERS")
	y += 24 * s

	rows := min(len(nett.servers), 4)
	if rows == 0 {
		ui_rect(fx, y, fw, 40 * s, Vec4{0.05, 0.05, 0.05, 0.8})
		ui_text(fx + 12 * s, y + 13 * s, 13 * s, UI_TEXT_DIM, "SCANNING")
		dots := int(math.mod(ui.time * 2, 4))
		for i in 0 ..< dots {
			ui_rect(fx + (92 + f32(i) * 10) * s, y + 22 * s, 4 * s, 4 * s, UI_TEXT_DIM)
		}
		y += 48 * s
	}
	for i in 0 ..< rows {
		sv := nett.servers[i]
		if ui_list_row(fx, y, fw, 40 * s, game.join_selected == i,
			sv.name, fmt.tprintf("%d/%d", sv.players, sv.max)) {
			game.join_selected = i
		}
		y += 46 * s
	}

	y = py + 244 * s
	ui_text_field(fx, y, fw * 0.55, 40 * s, "DIRECT IP", game.join_ip[:], &game.join_ip_len)
	ui_text_field(fx + fw * 0.62, y, fw * 0.38, 40 * s, "PASSWORD", game.join_pass[:], &game.join_pass_len, password = true)
	y += 76 * s

	if ui_button(fx, y, fw * 0.55, 46 * s, nett.joining ? "CONNECTING" : "CONNECT") && !nett.joining {
		pass := string(game.join_pass[:game.join_pass_len])
		pname := game.settings.player_name
		if game.join_ip_len > 0 {
			addr := net.parse_address(string(game.join_ip[:game.join_ip_len]))
			if addr != nil {
				net_client_join(net.Endpoint{address = addr, port = NET_PORT}, pass, pname)
			} else {
				game_status("INVALID ADDRESS")
			}
		} else if game.join_selected < len(nett.servers) {
			net_client_join(nett.servers[game.join_selected].ep, pass, pname)
		} else {
			game_status("NO SERVER SELECTED")
		}
	}
	if ui_button(fx + fw * 0.6, y, fw * 0.4, 46 * s, "BACK") || (ui.nav.back && ui.hot_field < 0) {
		net_stop()
		game.screen = .Main_Menu
		ui_reset_focus()
	}
	draw_hints()
}

draw_settings :: proc() {
	draw_title_block()
	s := ui.scale
	px := 540 * s
	py := 130 * s
	pw := 560 * s
	ui_panel(px, py, pw, 560 * s, "OPTIONS")

	fx := px + 30 * s
	fw := pw - 60 * s
	y := py + 104 * s

	ui_text_field(fx, y, fw, 40 * s, "CALLSIGN", game.name_buf[:], &game.name_len)
	y += 76 * s
	ui_swatches(fx, y, fw, 26 * s, "SQUAD COLOR", &game.settings.color_idx)
	y += 60 * s
	ui_slider(fx, y, fw, 20 * s, "MOUSE SENSITIVITY", &game.settings.mouse_sens, 0.5, 10, "%.1f")
	y += 60 * s
	ui_slider(fx, y, fw, 20 * s, "STICK SENSITIVITY", &game.settings.stick_sens, 1, 10, "%.1f")
	y += 60 * s
	ui_slider(fx, y, fw, 20 * s, "FIELD OF VIEW", &game.settings.fov, 70, 110, "%.0f")
	y += 52 * s
	ui_toggle(fx, y, fw, 34 * s, "INVERT LOOK Y", &game.settings.invert_y)
	y += 50 * s

	if ui_button(fx, y, fw, 44 * s, "VIDEO") {
		game.screen = .Settings_Video
		ui_reset_focus()
	}
	y += 58 * s
	if ui_button(fx, y, fw, 44 * s, "DONE") || (ui.nav.back && ui.hot_field < 0) {
		settings_apply_name()
		settings_save()
		game.screen = game.settings_return
		if game.screen == .In_Game do game.paused = true
		ui_reset_focus()
	}
	draw_hints()
}

draw_settings_video :: proc() {
	draw_title_block()
	s := ui.scale
	px := 540 * s
	py := 170 * s
	pw := 560 * s
	ui_panel(px, py, pw, 430 * s, "VIDEO")

	fx := px + 30 * s
	fw := pw - 60 * s
	y := py + 84 * s

	disp_idx := game.settings.fullscreen ? 1 : 0
	if ui_selector(fx, y, fw, 36 * s, "DISPLAY", DISPLAY_NAMES[:], &disp_idx) {
		game.settings.fullscreen = disp_idx == 1
		apply_display_mode()
	}
	y += 54 * s
	if ui_selector(fx, y, fw, 36 * s, "RESOLUTION", RES_NAMES[:], &game.settings.res_idx) {
		apply_resolution()
	}
	y += 54 * s
	vs := game.settings.vsync
	ui_toggle(fx, y, fw, 34 * s, "VSYNC", &game.settings.vsync)
	if vs != game.settings.vsync do game.vsync_changed = true
	y += 50 * s
	ui_toggle(fx, y, fw, 34 * s, "FPS COUNTER", &game.settings.show_fps)
	y += 56 * s

	ui_text(fx, y, 12 * s, UI_TEXT_DIM, fmt.tprintf("DISPLAY %d HZ", display_refresh_hz()))
	if game.vsync_changed {
		ui_text(fx, y + 20 * s, 12 * s, UI_WARN, "VSYNC CHANGE APPLIES AFTER RESTART")
	}
	y += 54 * s

	if ui_button(fx, y, fw, 44 * s, "BACK") || (ui.nav.back && ui.hot_field < 0) {
		settings_save()
		game.screen = .Settings
		ui_reset_focus()
	}
	draw_hints()
}

settings_apply_name :: proc() {
	if game.name_len > 0 {
		delete(game.settings.player_name)
		game.settings.player_name = clone_string(string(game.name_buf[:game.name_len]))
	}
}

// ---- in-game ----------------------------------------------------------------

draw_ingame :: proc() {
	p := local_player()
	if game.paused {
		draw_pause_menu()
		return
	}
	draw_hud(p)
}

draw_pause_menu :: proc() {
	s := ui.scale
	ui_rect(0, 0, ui.w, ui.h, Vec4{0.01, 0.01, 0.01, 0.65})
	px := ui.w * 0.5 - 220 * s
	py := 140 * s
	ui_panel(px, py, 440 * s, 300 * s, "PAUSED")
	fx := px + 30 * s
	fw := 380 * s
	y := py + 72 * s
	if ui_button(fx, y, fw, 46 * s, "RESUME") || ui.nav.back {
		game.paused = false
	}
	y += 60 * s
	if ui_button(fx, y, fw, 46 * s, "OPTIONS") {
		game.settings_return = .In_Game
		game.screen = .Settings
		ui_reset_focus()
	}
	y += 60 * s
	if ui_button(fx, y, fw, 46 * s, "ABANDON") {
		game_leave_session("")
	}
	if nett.role != .None {
		ui_text(fx, py + 264 * s, 11 * s, UI_TEXT_DIM, "SESSION CONTINUES WHILE PAUSED")
	}

	// control reference for the active device
	cx := px + 470 * s
	ui_panel(cx, py, 360 * s, 300 * s, "CONTROLS")
	ref_kbm := [?][2]string{
		{"MOVE", "WASD"}, {"SPRINT", "SHIFT"}, {"AIM", "RMB"}, {"FIRE", "LMB"},
		{"RELOAD", "R"}, {"GRENADE", "G"}, {"MELEE", "V"}, {"CROUCH", "CTRL"},
		{"WEAPON", "Q / 1-6"}, {"ROSTER", "TAB"},
	}
	ref_pad := [?][2]string{
		{"MOVE", "L STICK"}, {"SPRINT", "L3"}, {"AIM", "LT"}, {"FIRE", "RT"},
		{"RELOAD", "X"}, {"GRENADE", "RB"}, {"MELEE", "R3"}, {"CROUCH", "B"},
		{"WEAPON", "Y"}, {"ROSTER", "BACK"},
	}
	ry := py + 60 * s
	if input.last_device == .Gamepad {
		for r in ref_pad {
			ui_text(cx + 24 * s, ry, 12 * s, UI_TEXT_DIM, r[0])
			ui_text_right(cx + 336 * s, ry, 12 * s, UI_TEXT, r[1])
			ry += 22 * s
		}
	} else {
		for r in ref_kbm {
			ui_text(cx + 24 * s, ry, 12 * s, UI_TEXT_DIM, r[0])
			ui_text_right(cx + 336 * s, ry, 12 * s, UI_TEXT, r[1])
			ry += 22 * s
		}
	}
}

draw_hud :: proc(p: ^Player) {
	s := ui.scale

	// damage vignette
	if game.damage_flash > 0.01 {
		a := min(game.damage_flash, 1) * 0.42
		t := 70 * s
		c := Vec4{0.45, 0.04, 0.02, a}
		ui_rect(0, 0, ui.w, t, c)
		ui_rect(0, ui.h - t, ui.w, t, c)
		ui_rect(0, t, t, ui.h - 2 * t, c)
		ui_rect(ui.w - t, t, t, ui.h - 2 * t, c)
	}

	if !p.alive {
		ui_text_center(ui.w * 0.5, ui.h * 0.42, 28 * s, UI_DANGER, "K.I.A.")
		ui_text_center(ui.w * 0.5, ui.h * 0.42 + 42 * s, 14 * s, UI_TEXT,
			fmt.tprintf("REDEPLOY %.1f", max(p.respawn_t, 0)))
		draw_hud_netinfo()
		return
	}

	def := weapon_defs[p.weapon]
	ws := &p.weapons[p.weapon]
	scoped := def.scope && p.ads_t > 0.85

	// ---- shield / health / stamina, top center
	bw := 300 * s
	bx := (ui.w - bw) * 0.5
	by := 24 * s
	ui_rect(bx - 2 * s, by - 2 * s, bw + 4 * s, 24 * s, Vec4{0.02, 0.02, 0.02, 0.65})
	sh := p.shield / MAX_SHIELD
	ui_rect(bx, by, bw, 8 * s, Vec4{0.09, 0.09, 0.09, 0.9})
	shield_col := Vec4{0.55, 0.62, 0.70, 1}
	if p.shield <= 0 && math.mod(ui.time, 0.4) < 0.2 do shield_col = UI_DANGER
	ui_rect(bx, by, bw * sh, 8 * s, shield_col)
	hp := p.health / MAX_HEALTH
	ui_rect(bx, by + 10 * s, bw, 4 * s, Vec4{0.09, 0.09, 0.09, 0.9})
	ui_rect(bx, by + 10 * s, bw * hp, 4 * s, vlerp_color(UI_DANGER, Vec4{0.55, 0.58, 0.45, 1}, hp))
	st := p.stamina / MAX_STAMINA
	stam_col := st < 0.25 ? UI_WARN : Vec4{0.35, 0.36, 0.33, 1}
	ui_rect(bx, by + 16 * s, bw, 2.5 * s, Vec4{0.09, 0.09, 0.09, 0.9})
	ui_rect(bx, by + 16 * s, bw * st, 2.5 * s, stam_col)

	// ---- reticle
	cx := ui.w * 0.5
	cy := ui.h * 0.5
	if scoped {
		ui_rect(cx - 1 * s, cy - 70 * s, 2 * s, 140 * s, Vec4{0.75, 0.75, 0.72, 0.75})
		ui_rect(cx - 70 * s, cy - 1 * s, 140 * s, 2 * s, Vec4{0.75, 0.75, 0.72, 0.75})
		// scope surround
		half_w := ui.w * 0.5
		half_h := ui.h * 0.5
		r := 150 * s
		dark := Vec4{0.01, 0.01, 0.01, 0.94}
		ui_rect(0, 0, ui.w, half_h - r, dark)
		ui_rect(0, half_h + r, ui.w, half_h - r, dark)
		ui_rect(0, half_h - r, half_w - r, r * 2, dark)
		ui_rect(half_w + r, half_h - r, half_w - r, r * 2, dark)
		ui_text(cx + 120 * s, cy - 146 * s, 11 * s, UI_TEXT_DIM, fmt.tprintf("%.1fX", def.ads_zoom))
	} else if p.ads_t > 0.4 {
		// minimal dot while aiming
		ui_rect(cx - 1 * s, cy - 1 * s, 2 * s, 2 * s, Vec4{0.85, 0.85, 0.8, 0.9})
	} else {
		spread := weapon_spread_deg(ws, p.weapon, false)
		gap := (6 + spread * 7) * s
		l := 8 * s
		t := 1.5 * s
		ch_col := Vec4{0.82, 0.82, 0.78, 0.8}
		ui_rect(cx - gap - l, cy - t * 0.5, l, t, ch_col)
		ui_rect(cx + gap, cy - t * 0.5, l, t, ch_col)
		ui_rect(cx - t * 0.5, cy - gap - l, t, l, ch_col)
		ui_rect(cx - t * 0.5, cy + gap, t, l, ch_col)
	}

	// hitmarker
	if game.hitmarker_t > 0 {
		a := game.hitmarker_t / 0.25
		hc := game.hitmarker_kill ? Vec4{0.8, 0.15, 0.1, a} : Vec4{0.9, 0.9, 0.85, a}
		d := 12 * s
		g := 5 * s
		for sx in ([2]f32{-1, 1}) {
			for sy in ([2]f32{-1, 1}) {
				x1 := cx + sx * g
				y1 := cy + sy * g
				steps := 5
				for i in 0 ..< steps {
					fi := f32(i) / f32(steps)
					ui_rect(x1 + sx * fi * d, y1 + sy * fi * d, 2 * s, 2 * s, hc)
				}
			}
		}
	}

	// ---- reload bar: minimal, only while reloading
	if ws.reloading {
		rw := 240 * s
		rx := (ui.w - rw) * 0.5
		ry := ui.h * 0.60
		rh := 6 * s
		jam := ws.active_result == .Jam
		ui_rect(rx - 2 * s, ry - 2 * s, rw + 4 * s, rh + 4 * s, Vec4{0.02, 0.02, 0.02, 0.7})
		ui_rect(rx, ry, rw, rh, Vec4{0.10, 0.10, 0.10, 1})
		if !jam && !ws.active_used {
			gx := rx + rw * def.active_good.x
			gw := rw * (def.active_good.y - def.active_good.x)
			ui_rect(gx, ry, gw, rh, Vec4{0.28, 0.28, 0.26, 1})
			ppx := rx + rw * def.active_perfect.x
			ppw := rw * (def.active_perfect.y - def.active_perfect.x)
			ui_rect(ppx, ry, ppw, rh, Vec4{0.75, 0.73, 0.66, 1})
		}
		mk := rx + rw * clamp(ws.reload_t, 0, 1)
		ui_rect(mk - 1.5 * s, ry - 4 * s, 3 * s, rh + 8 * s, jam ? UI_DANGER : UI_TEXT)
		if jam {
			ui_text_center(ui.w * 0.5, ry + rh + 8 * s, 11 * s, UI_DANGER, "JAMMED")
		}
	}

	// ---- ammo, bottom right
	ax := ui.w - 56 * s
	ay := ui.h - 110 * s
	if game.weapon_name_t > 0 {
		a := min(game.weapon_name_t, 1)
		ui_text_right(ax, ay - 28 * s, 13 * s, UI_TEXT_DIM * Vec4{1, 1, 1, a}, def.name)
	}
	ui_text_right(ax - 78 * s, ay, 38 * s, ws.mag == 0 ? UI_DANGER : UI_TEXT, fmt.tprintf("%d", ws.mag))
	ui_text_right(ax, ay + 16 * s, 14 * s, UI_TEXT_DIM, fmt.tprintf("/ %d", ws.reserve))
	pip_w := 4 * s
	total := f32(def.mag)
	pips_x := ax - total * (pip_w + 2 * s)
	for i in 0 ..< def.mag {
		c := i < ws.mag ? Vec4{0.66, 0.64, 0.58, 1} : Vec4{0.14, 0.14, 0.13, 0.8}
		ui_rect(pips_x + f32(i) * (pip_w + 2 * s), ay + 42 * s, pip_w, 10 * s, c)
	}

	// grenades, bottom left
	gx := 56 * s
	gy := ui.h - 84 * s
	ui_text(gx, gy - 20 * s, 11 * s, UI_TEXT_DIM, "FRAG")
	for i in 0 ..< 4 {
		c := i < p.grenades ? Vec4{0.55, 0.45, 0.28, 1} : Vec4{0.14, 0.14, 0.13, 0.8}
		ui_rect(gx + f32(i) * 20 * s, gy, 13 * s, 13 * s, c)
	}

	draw_hud_netinfo()

	if action_scoreboard() {
		draw_scoreboard()
	}
}

vlerp_color :: proc(a, b: Vec4, t: f32) -> Vec4 {
	return a + (b - a) * t
}

draw_hud_netinfo :: proc() {
	s := ui.scale
	if nett.role == .None do return
	txt: string
	switch nett.role {
	case .None:
	case .Host:
		txt = fmt.tprintf("HOST / %d UP", game_player_count())
	case .Client:
		txt = fmt.tprintf("%d MS / %d UP", nett.ping_ms, game_player_count())
	}
	ui_text_right(ui.w - 16 * s, ui.h - 26 * s, 11 * s, UI_TEXT_DIM, txt)
}

draw_scoreboard :: proc() {
	s := ui.scale
	pw := 440 * s
	px := (ui.w - pw) * 0.5
	py := 140 * s
	n := game_player_count()
	ui_panel(px, py, pw, (86 + f32(n) * 32) * s, "ROSTER")
	y := py + 60 * s
	for i in 0 ..< MAX_PLAYERS {
		if !game.active[i] do continue
		p := &game.players[i]
		name := fixed_str(game.names[i][:])
		ui_rect(px + 24 * s, y + 2 * s, 13 * s, 13 * s, player_color(i))
		marker := i == game.local_id ? " *" : ""
		ui_text(px + 48 * s, y, 13 * s, UI_TEXT, fmt.tprintf("%s%s", name, marker))
		state := p.alive ? fmt.tprintf("%.0f", p.health) : "DOWN"
		ui_text_right(px + pw - 24 * s, y, 13 * s, p.alive ? UI_TEXT_DIM : UI_DANGER, state)
		y += 32 * s
	}
}
