package main

import "core:fmt"
import "core:math"
import sapp "../sokol/app"
import sg "../sokol/gfx"
import sgl "../sokol/gl"
import sdtx "../sokol/debugtext"
import slog "../sokol/log"

// Immediate-mode UI on sokol_gl (quads) + sokol_debugtext (text).
// Widgets register in call order; focus can be driven by mouse, keyboard
// arrows, or gamepad, and activation by click, Enter, or the A button.

// desaturated field palette: bone, ash, oxide
UI_ACCENT :: Vec4{0.80, 0.76, 0.66, 1}
UI_ACCENT_DIM :: Vec4{0.45, 0.43, 0.38, 1}
UI_WARN :: Vec4{0.78, 0.58, 0.28, 1}
UI_DANGER :: Vec4{0.62, 0.16, 0.12, 1}
UI_TEXT :: Vec4{0.82, 0.81, 0.77, 1}
UI_TEXT_DIM :: Vec4{0.44, 0.44, 0.41, 1}
UI_PANEL :: Vec4{0.030, 0.032, 0.034, 0.92}
UI_PANEL_LIGHT :: Vec4{0.075, 0.078, 0.080, 0.95}
UI_GOOD :: Vec4{0.48, 0.55, 0.36, 1}

UI :: struct {
	pip:         sgl.Pipeline,
	w, h:        f32,
	scale:       f32, // h / 720 reference scale
	nav:         UI_Nav,
	focus:       int,
	item_count:  int,
	hot_field:   int, // index of focused text field, -1 none
	field_count: int,
	mouse_moved: bool,
	last_mouse:  Vec2,
	time:        f32,
}

ui: UI

ui_init :: proc() {
	sgl.setup({logger = {func = slog.func}})
	sdtx.setup({
		fonts = {0 = sdtx.font_kc854(), 1 = sdtx.font_oric()},
		logger = {func = slog.func},
	})
	ui.pip = sgl.make_pipeline({
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
	ui.hot_field = -1
}

ui_begin :: proc(dt: f32) {
	ui.w = sapp.widthf()
	ui.h = sapp.heightf()
	ui.scale = ui.h / 720.0
	ui.time += dt
	ui.nav = ui_nav_poll(dt)
	mouse := Vec2{input.mouse_x, input.mouse_y}
	ui.mouse_moved = vlen({mouse.x - ui.last_mouse.x, mouse.y - ui.last_mouse.y, 0}) > 2
	ui.last_mouse = mouse
	ui.item_count = 0
	ui.field_count = 0

	sgl.defaults()
	sgl.load_pipeline(ui.pip)
	sgl.matrix_mode_projection()
	sgl.ortho(0, ui.w, ui.h, 0, -1, 1)
	sgl.matrix_mode_modelview()
	sgl.load_identity()
}

ui_end :: proc() {
	// wrap focus
	if ui.item_count > 0 {
		if ui.nav.dir.y > 0 do ui.focus = (ui.focus + 1) %% ui.item_count
		if ui.nav.dir.y < 0 do ui.focus = (ui.focus - 1 + ui.item_count) %% ui.item_count
	}
}

ui_reset_focus :: proc() {
	ui.focus = 0
	ui.hot_field = -1
}

// ---- primitives -------------------------------------------------------------

ui_rect :: proc(x, y, w, h: f32, c: Vec4) {
	sgl.begin_quads()
	sgl.c4f(c.r, c.g, c.b, c.a)
	sgl.v2f(x, y)
	sgl.v2f(x + w, y)
	sgl.v2f(x + w, y + h)
	sgl.v2f(x, y + h)
	sgl.end()
}

ui_rect_outline :: proc(x, y, w, h, t: f32, c: Vec4) {
	ui_rect(x, y, w, t, c)
	ui_rect(x, y + h - t, w, t, c)
	ui_rect(x, y, t, h, c)
	ui_rect(x + w - t, y, t, h, c)
}

// text drawn at pixel position with pixel-height sizing (8px glyph base)
ui_text :: proc(x, y, px: f32, c: Vec4, str: string, font: int = 0) {
	scale := px / 8.0
	sdtx.canvas(ui.w / scale, ui.h / scale)
	sdtx.origin(0, 0)
	sdtx.font(font)
	sdtx.color4f(c.r, c.g, c.b, c.a)
	sdtx.pos(x / px, y / px)
	sdtx.puts(fmt.ctprintf("%s", str))
}

ui_text_center :: proc(cx, y, px: f32, c: Vec4, str: string, font: int = 0) {
	w := f32(len(str)) * px
	ui_text(cx - w * 0.5, y, px, c, str, font)
}

ui_text_right :: proc(rx, y, px: f32, c: Vec4, str: string, font: int = 0) {
	w := f32(len(str)) * px
	ui_text(rx - w, y, px, c, str, font)
}

ui_mouse_in :: proc(x, y, w, h: f32) -> bool {
	m := ui.last_mouse
	return m.x >= x && m.x < x + w && m.y >= y && m.y < y + h
}

// ---- widgets ----------------------------------------------------------------

ui_button :: proc(x, y, w, h: f32, label: string) -> bool {
	idx := ui.item_count
	ui.item_count += 1
	hovered := ui_mouse_in(x, y, w, h)
	if hovered && ui.mouse_moved do ui.focus = idx
	focused := ui.focus == idx

	bg := UI_PANEL_LIGHT
	border := Vec4{0.16, 0.16, 0.15, 0.6}
	tcol := UI_TEXT
	if focused {
		pulse := 0.9 + 0.1 * math.sin(ui.time * 4)
		bg = Vec4{0.115, 0.115, 0.105, 0.96}
		border = UI_ACCENT * Vec4{1, 1, 1, pulse}
		tcol = UI_ACCENT
	}
	ui_rect(x, y, w, h, bg)
	ui_rect_outline(x, y, w, h, 1.5 * ui.scale, border)
	if focused {
		ui_rect(x, y, 3 * ui.scale, h, UI_ACCENT)
	}
	px := 18 * ui.scale
	ui_text(x + 16 * ui.scale, y + (h - px) * 0.5, px, tcol, label)

	clicked := hovered && input.mouse_clicked[0]
	activated := focused && ui.nav.confirm
	return clicked || activated
}

// editable single-line field; writes into buf, maintains len via plen
ui_text_field :: proc(x, y, w, h: f32, label: string, buf: []u8, plen: ^int, password := false) {
	idx := ui.item_count
	ui.item_count += 1
	fidx := ui.field_count
	ui.field_count += 1

	hovered := ui_mouse_in(x, y, w, h)
	if hovered && ui.mouse_moved do ui.focus = idx
	focused := ui.focus == idx
	if hovered && input.mouse_clicked[0] do ui.hot_field = fidx
	if focused && ui.nav.confirm do ui.hot_field = fidx
	editing := ui.hot_field == fidx

	if editing {
		for ch in input.chars {
			if plen^ < len(buf) {
				buf[plen^] = u8(ch)
				plen^ += 1
			}
		}
		if key_pressed(.BACKSPACE) && plen^ > 0 do plen^ -= 1
		if key_pressed(.ENTER) || key_pressed(.ESCAPE) do ui.hot_field = -1
	}

	lpx := 13 * ui.scale
	ui_text(x, y - lpx - 6 * ui.scale, lpx, UI_TEXT_DIM, label)

	bg := UI_PANEL_LIGHT
	border := Vec4{0.16, 0.16, 0.15, 0.6}
	if focused do border = UI_ACCENT_DIM
	if editing do border = UI_ACCENT
	ui_rect(x, y, w, h, bg)
	ui_rect_outline(x, y, w, h, 2 * ui.scale, border)

	px := 16 * ui.scale
	shown: string
	if password {
		stars: [64]u8
		for i in 0 ..< min(plen^, 64) do stars[i] = '*'
		shown = string(stars[:min(plen^, 64)])
		shown = fmt.tprintf("%s", shown)
	} else {
		shown = string(buf[:plen^])
	}
	ui_text(x + 12 * ui.scale, y + (h - px) * 0.5, px, UI_TEXT, shown)
	if editing && math.mod(ui.time, 1.0) < 0.55 {
		cx := x + 12 * ui.scale + f32(plen^) * px
		ui_rect(cx, y + h * 0.22, 2.5 * ui.scale, h * 0.56, UI_ACCENT)
	}
}

ui_slider :: proc(x, y, w, h: f32, label: string, value: ^f32, lo, hi: f32, fmt_str: string) {
	idx := ui.item_count
	ui.item_count += 1
	hovered := ui_mouse_in(x, y - 8 * ui.scale, w, h + 16 * ui.scale)
	if hovered && ui.mouse_moved do ui.focus = idx
	focused := ui.focus == idx

	step := (hi - lo) / 20
	if focused && ui.nav.dir.x != 0 {
		value^ = clamp(value^ + ui.nav.dir.x * step, lo, hi)
	}
	if hovered && input.mouse_down[0] {
		t := clamp((ui.last_mouse.x - x) / w, 0, 1)
		value^ = lo + (hi - lo) * t
	}

	lpx := 13 * ui.scale
	ui_text(x, y - lpx - 4 * ui.scale, lpx, focused ? UI_ACCENT : UI_TEXT_DIM, label)
	ui_text_right(x + w, y - lpx - 4 * ui.scale, lpx, UI_TEXT, fmt.tprintf(fmt_str, value^))

	track_h := 4 * ui.scale
	ty := y + h * 0.5 - track_h * 0.5
	ui_rect(x, ty, w, track_h, Vec4{0.15, 0.18, 0.22, 0.9})
	t := (value^ - lo) / (hi - lo)
	ui_rect(x, ty, w * t, track_h, focused ? UI_ACCENT : UI_ACCENT_DIM)
	kx := x + w * t
	ui_rect(kx - 5 * ui.scale, y + h * 0.5 - 9 * ui.scale, 10 * ui.scale, 18 * ui.scale, focused ? UI_ACCENT : UI_TEXT)
}

ui_toggle :: proc(x, y, w, h: f32, label: string, value: ^bool) {
	idx := ui.item_count
	ui.item_count += 1
	hovered := ui_mouse_in(x, y, w, h)
	if hovered && ui.mouse_moved do ui.focus = idx
	focused := ui.focus == idx
	if (hovered && input.mouse_clicked[0]) || (focused && (ui.nav.confirm || ui.nav.dir.x != 0)) {
		value^ = !value^
	}
	px := 15 * ui.scale
	ui_text(x, y + (h - px) * 0.5, px, focused ? UI_ACCENT : UI_TEXT, label)
	bw := 52 * ui.scale
	bx := x + w - bw
	ui_rect(bx, y, bw, h, UI_PANEL_LIGHT)
	ui_rect_outline(bx, y, bw, h, 1.5 * ui.scale, focused ? UI_ACCENT : Vec4{0.16, 0.16, 0.15, 0.6})
	half := bw * 0.5
	if value^ {
		ui_rect(bx + half, y + 3 * ui.scale, half - 3 * ui.scale, h - 6 * ui.scale, UI_GOOD)
	} else {
		ui_rect(bx + 3 * ui.scale, y + 3 * ui.scale, half - 3 * ui.scale, h - 6 * ui.scale, Vec4{0.4, 0.2, 0.2, 1})
	}
}

// selectable row (server list); returns clicked/confirmed
ui_list_row :: proc(x, y, w, h: f32, selected: bool, main_text, right_text: string) -> bool {
	idx := ui.item_count
	ui.item_count += 1
	hovered := ui_mouse_in(x, y, w, h)
	if hovered && ui.mouse_moved do ui.focus = idx
	focused := ui.focus == idx
	bg := selected ? Vec4{0.10, 0.24, 0.28, 0.95} : UI_PANEL_LIGHT
	ui_rect(x, y, w, h, bg)
	if focused do ui_rect_outline(x, y, w, h, 2 * ui.scale, UI_ACCENT)
	px := 15 * ui.scale
	ui_text(x + 12 * ui.scale, y + (h - px) * 0.5, px, selected ? UI_ACCENT : UI_TEXT, main_text)
	ui_text_right(x + w - 12 * ui.scale, y + (h - px) * 0.5, px, UI_TEXT_DIM, right_text)
	return (hovered && input.mouse_clicked[0]) || (focused && ui.nav.confirm)
}

ui_panel :: proc(x, y, w, h: f32, title: string) {
	ui_rect(x, y, w, h, UI_PANEL)
	ui_rect_outline(x, y, w, h, 1.5 * ui.scale, Vec4{0.18, 0.18, 0.17, 0.8})
	ui_rect(x, y, w, 2 * ui.scale, UI_ACCENT_DIM)
	if len(title) > 0 {
		ui_text(x + 18 * ui.scale, y + 16 * ui.scale, 18 * ui.scale, UI_ACCENT, title)
		ui_rect(x + 18 * ui.scale, y + 42 * ui.scale, w - 36 * ui.scale, 1 * ui.scale, Vec4{0.25, 0.25, 0.23, 0.7})
	}
}

// left/right option cycler (resolution, display mode, ...)
ui_selector :: proc(x, y, w, h: f32, label: string, options: []string, idx: ^int) -> bool {
	item := ui.item_count
	ui.item_count += 1
	hovered := ui_mouse_in(x, y, w, h)
	if hovered && ui.mouse_moved do ui.focus = item
	focused := ui.focus == item
	changed := false
	n := len(options)
	if n == 0 do return false
	step := 0
	if focused && ui.nav.dir.x != 0 do step = int(ui.nav.dir.x)
	if hovered && input.mouse_clicked[0] do step = 1
	if step != 0 {
		idx^ = (idx^ + step + n) %% n
		changed = true
	}
	px := 15 * ui.scale
	ui_text(x, y + (h - px) * 0.5, px, focused ? UI_ACCENT : UI_TEXT, label)
	val := options[clamp(idx^, 0, n - 1)]
	arrow_c := focused ? UI_ACCENT : UI_TEXT_DIM
	ui_text_right(x + w - 26 * ui.scale, y + (h - px) * 0.5, px, UI_TEXT, val)
	ui_text_right(x + w, y + (h - px) * 0.5, px, arrow_c, ">")
	ui_text_right(x + w - (f32(len(val)) + 3.5) * px, y + (h - px) * 0.5, px, arrow_c, "<")
	return changed
}

// color swatch row for squad color selection
ui_swatches :: proc(x, y, w, h: f32, label: string, idx: ^int) {
	item := ui.item_count
	ui.item_count += 1
	hovered := ui_mouse_in(x, y, w, h)
	if hovered && ui.mouse_moved do ui.focus = item
	focused := ui.focus == item
	if focused && ui.nav.dir.x != 0 {
		idx^ = (idx^ + int(ui.nav.dir.x) + MAX_PLAYERS) %% MAX_PLAYERS
	}
	px := 13 * ui.scale
	ui_text(x, y - px - 6 * ui.scale, px, focused ? UI_ACCENT : UI_TEXT_DIM, label)
	sw := (w - f32(MAX_PLAYERS - 1) * 8 * ui.scale) / f32(MAX_PLAYERS)
	for i in 0 ..< MAX_PLAYERS {
		sx := x + f32(i) * (sw + 8 * ui.scale)
		c := PLAYER_COLORS[i]
		if hovered && input.mouse_clicked[0] && ui.last_mouse.x >= sx && ui.last_mouse.x < sx + sw {
			idx^ = i
		}
		ui_rect(sx, y, sw, h, c)
		if idx^ == i {
			ui_rect_outline(sx - 2 * ui.scale, y - 2 * ui.scale, sw + 4 * ui.scale, h + 4 * ui.scale, 2 * ui.scale, UI_ACCENT)
		}
	}
}

ui_flush :: proc() {
	sgl.draw()
	sdtx.draw()
}

ui_shutdown :: proc() {
	sdtx.shutdown()
	sgl.shutdown()
	sg.shutdown()
}
