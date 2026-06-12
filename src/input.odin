package main

import "core:math"
import sapp "../sokol/app"
import sdl "vendor:sdl3"

// Unified keyboard/mouse + SDL3 gamepad input with Halo 2/3 style stick
// response: wide radial deadzone, squared response curve, slower pitch,
// and yaw acceleration when the stick is pegged.

MOVE_DEADZONE :: 0.21
LOOK_DEADZONE :: 0.24
LOOK_CURVE_POW :: 2.0
BASE_YAW_DPS :: 165.0 // deg/sec at sensitivity 5, before peg acceleration
BASE_PITCH_DPS :: 105.0
PEG_THRESHOLD :: 0.94
PEG_DELAY :: 0.13 // seconds pegged before acceleration kicks in
PEG_RAMP :: 0.40 // seconds to reach full acceleration
PEG_MULT :: 1.95

Input_Device :: enum {
	KBM,
	Gamepad,
}

Input :: struct {
	last_device:  Input_Device,
	keys:         [512]bool,
	keys_pressed: [512]bool,
	mouse_dx:     f32,
	mouse_dy:     f32,
	mouse_x:      f32,
	mouse_y:      f32,
	mouse_down:   [3]bool,
	mouse_clicked: [3]bool,
	scroll:       f32,
	chars:        [dynamic]rune,

	gamepad:        ^sdl.Gamepad,
	pad_scan_timer: f32,
	pad_buttons:    [32]bool,
	pad_pressed:    [32]bool,
	left_stick:     Vec2,
	right_stick:    Vec2,
	trig_l:         f32,
	trig_r:         f32,
	trig_l_held:    bool,
	trig_r_held:    bool,
	trig_l_pressed: bool,
	trig_r_pressed: bool,
	peg_time:       f32,

	// gamepad sprint is press-to-engage; cleared by gameplay when invalid
	sprint_latch: bool,

	// UI navigation repeat
	nav_repeat_t: f32,
	nav_dir_prev: Vec2,
}

input: Input

input_init :: proc() {
	if !sdl.Init({.GAMEPAD}) {
		// keyboard/mouse still works; report and continue
		return
	}
	input_scan_gamepads()
}

input_scan_gamepads :: proc() {
	if input.gamepad != nil do return
	count: i32
	ids := sdl.GetGamepads(&count)
	if ids != nil {
		if count > 0 {
			input.gamepad = sdl.OpenGamepad(ids[0])
		}
		sdl.free(ids)
	}
}

input_handle_event :: proc(ev: ^sapp.Event) {
	#partial switch ev.type {
	case .KEY_DOWN, .CHAR, .MOUSE_DOWN, .MOUSE_SCROLL:
		input.last_device = .KBM
	}
	#partial switch ev.type {
	case .KEY_DOWN:
		k := int(ev.key_code)
		if k >= 0 && k < 512 {
			if !input.keys[k] do input.keys_pressed[k] = true
			input.keys[k] = true
		}
		// backspace repeats for text fields
		if ev.key_code == .BACKSPACE && ev.key_repeat do input.keys_pressed[int(sapp.Keycode.BACKSPACE)] = true
	case .KEY_UP:
		k := int(ev.key_code)
		if k >= 0 && k < 512 do input.keys[k] = false
	case .CHAR:
		if ev.char_code >= 32 && ev.char_code < 127 do append(&input.chars, rune(ev.char_code))
	case .MOUSE_MOVE:
		input.mouse_dx += ev.mouse_dx
		input.mouse_dy += ev.mouse_dy
		input.mouse_x = ev.mouse_x
		input.mouse_y = ev.mouse_y
	case .MOUSE_DOWN:
		b := int(ev.mouse_button)
		if b >= 0 && b < 3 {
			input.mouse_down[b] = true
			input.mouse_clicked[b] = true
		}
	case .MOUSE_UP:
		b := int(ev.mouse_button)
		if b >= 0 && b < 3 do input.mouse_down[b] = false
	case .MOUSE_SCROLL:
		input.scroll += ev.scroll_y
	case .UNFOCUSED:
		for &k in input.keys do k = false
		for &b in input.mouse_down do b = false
	}
}

pad_axis :: proc(axis: sdl.GamepadAxis) -> f32 {
	if input.gamepad == nil do return 0
	return f32(sdl.GetGamepadAxis(input.gamepad, axis)) / 32767.0
}

input_poll_gamepad :: proc(dt: f32) {
	if input.gamepad != nil && !sdl.GamepadConnected(input.gamepad) {
		sdl.CloseGamepad(input.gamepad)
		input.gamepad = nil
	}
	input.pad_scan_timer -= dt
	if input.gamepad == nil && input.pad_scan_timer <= 0 {
		input.pad_scan_timer = 1.0
		input_scan_gamepads()
	}
	sdl.UpdateGamepads()

	any_pad := false
	for b in 0 ..< 32 {
		down := false
		if input.gamepad != nil {
			down = sdl.GetGamepadButton(input.gamepad, sdl.GamepadButton(b))
		}
		input.pad_pressed[b] = down && !input.pad_buttons[b]
		input.pad_buttons[b] = down
		if down do any_pad = true
	}

	input.left_stick = {pad_axis(.LEFTX), pad_axis(.LEFTY)}
	input.right_stick = {pad_axis(.RIGHTX), pad_axis(.RIGHTY)}
	tl := max(pad_axis(.LEFT_TRIGGER), 0)
	tr := max(pad_axis(.RIGHT_TRIGGER), 0)
	input.trig_l_pressed = tl > 0.5 && !input.trig_l_held
	input.trig_r_pressed = tr > 0.5 && !input.trig_r_held
	input.trig_l_held = tl > 0.5
	input.trig_r_held = tr > 0.5
	input.trig_l = tl
	input.trig_r = tr

	if any_pad || tl > 0.3 || tr > 0.3 ||
	   abs(input.left_stick.x) > 0.3 || abs(input.left_stick.y) > 0.3 ||
	   abs(input.right_stick.x) > 0.3 || abs(input.right_stick.y) > 0.3 {
		input.last_device = .Gamepad
	}
}

input_end_frame :: proc() {
	for &k in input.keys_pressed do k = false
	for &b in input.mouse_clicked do b = false
	input.mouse_dx = 0
	input.mouse_dy = 0
	input.scroll = 0
	clear(&input.chars)
}

key_down :: proc(k: sapp.Keycode) -> bool {
	return input.keys[int(k)]
}

key_pressed :: proc(k: sapp.Keycode) -> bool {
	return input.keys_pressed[int(k)]
}

pad_down :: proc(b: sdl.GamepadButton) -> bool {
	return input.pad_buttons[int(b)]
}

pad_pressed :: proc(b: sdl.GamepadButton) -> bool {
	return input.pad_pressed[int(b)]
}

radial_deadzone :: proc(v: Vec2, dz: f32) -> Vec2 {
	mag := math.sqrt(v.x * v.x + v.y * v.y)
	if mag < dz do return {}
	scaled := min((mag - dz) / (1.0 - dz), 1.0)
	return v * (scaled / mag)
}

// ---- game actions -----------------------------------------------------------

// movement in local space: x = strafe right, y = forward
action_move :: proc() -> Vec2 {
	mv := Vec2{}
	if key_down(.W) do mv.y += 1
	if key_down(.S) do mv.y -= 1
	if key_down(.D) do mv.x += 1
	if key_down(.A) do mv.x -= 1
	stick := radial_deadzone(input.left_stick, MOVE_DEADZONE)
	mv.x += stick.x
	mv.y -= stick.y // stick up is negative
	mag := math.sqrt(mv.x * mv.x + mv.y * mv.y)
	if mag > 1 do mv /= mag
	return mv
}

// look delta in radians for this frame. Halo-style stick handling.
action_look :: proc(dt: f32, mouse_sens, stick_sens: f32, invert_y: bool, zoom_scale: f32) -> Vec2 {
	out := Vec2{}

	// mouse: classic 0.022 deg/count scale
	m_scale := f32(0.022) * mouse_sens * DEG2RAD * zoom_scale
	out.x += input.mouse_dx * m_scale
	out.y -= input.mouse_dy * m_scale

	// stick
	stick := radial_deadzone(input.right_stick, LOOK_DEADZONE)
	mag := math.sqrt(stick.x * stick.x + stick.y * stick.y)
	if mag > 0 {
		curved := math.pow(mag, LOOK_CURVE_POW)
		dir := stick * (curved / mag)

		// pegged-stick yaw acceleration (the Halo "turn faster" ramp)
		raw_mag := math.sqrt(input.right_stick.x * input.right_stick.x + input.right_stick.y * input.right_stick.y)
		if raw_mag > PEG_THRESHOLD && abs(input.right_stick.x) > abs(input.right_stick.y) {
			input.peg_time += dt
		} else {
			input.peg_time = 0
		}
		accel := f32(1)
		if input.peg_time > PEG_DELAY {
			accel = 1 + (PEG_MULT - 1) * min((input.peg_time - PEG_DELAY) / PEG_RAMP, 1.0)
		}

		sens_mult := stick_sens / 5.0
		out.x += dir.x * BASE_YAW_DPS * accel * sens_mult * DEG2RAD * dt * zoom_scale
		out.y -= dir.y * BASE_PITCH_DPS * sens_mult * DEG2RAD * dt * zoom_scale
	} else {
		input.peg_time = 0
	}

	if invert_y do out.y = -out.y
	return out
}

action_jump :: proc() -> bool {
	return key_pressed(.SPACE) || pad_pressed(.SOUTH)
}

action_fire_held :: proc() -> bool {
	return input.mouse_down[0] || input.trig_r_held
}

action_fire_pressed :: proc() -> bool {
	return input.mouse_clicked[0] || input.trig_r_pressed
}

action_ads_held :: proc() -> bool {
	return input.mouse_down[1] || input.trig_l_held
}

action_sprint_key_held :: proc() -> bool {
	return key_down(.LEFT_SHIFT)
}

action_sprint_pad_pressed :: proc() -> bool {
	return pad_pressed(.LEFT_STICK)
}

action_sprint_held :: proc() -> bool {
	return action_sprint_key_held() || input.sprint_latch
}

action_reload :: proc() -> bool {
	return key_pressed(.R) || pad_pressed(.WEST)
}

action_grenade :: proc() -> bool {
	return key_pressed(.G) || pad_pressed(.RIGHT_SHOULDER)
}

action_melee :: proc() -> bool {
	return key_pressed(.V) || pad_pressed(.RIGHT_STICK)
}

action_switch :: proc() -> bool {
	return key_pressed(.Q) || pad_pressed(.NORTH)
}

action_crouch_toggle :: proc() -> bool {
	return key_pressed(.LEFT_CONTROL) || pad_pressed(.EAST)
}

// clear the edges that double as menu navigation, so the keypress that
// opened a menu isn't immediately re-read by the menu itself
input_consume_menu_edges :: proc() {
	input.keys_pressed[int(sapp.Keycode.ESCAPE)] = false
	input.keys_pressed[int(sapp.Keycode.ENTER)] = false
	input.pad_pressed[int(sdl.GamepadButton.START)] = false
	input.pad_pressed[int(sdl.GamepadButton.EAST)] = false
	input.pad_pressed[int(sdl.GamepadButton.SOUTH)] = false
}

action_flashlight :: proc() -> bool {
	return key_pressed(.F) || pad_pressed(.DPAD_UP)
}

action_pause :: proc() -> bool {
	return key_pressed(.ESCAPE) || pad_pressed(.START)
}

action_scoreboard :: proc() -> bool {
	return key_down(.TAB) || pad_down(.BACK)
}

// ---- UI navigation ----------------------------------------------------------

UI_Nav :: struct {
	dir:     Vec2, // -1/0/1 per axis, edge-triggered with repeat
	confirm: bool,
	back:    bool,
}

ui_nav_poll :: proc(dt: f32) -> UI_Nav {
	nav: UI_Nav

	dir := Vec2{}
	if pad_down(.DPAD_UP) do dir.y -= 1
	if pad_down(.DPAD_DOWN) do dir.y += 1
	if pad_down(.DPAD_LEFT) do dir.x -= 1
	if pad_down(.DPAD_RIGHT) do dir.x += 1
	stick := radial_deadzone(input.left_stick, 0.5)
	if stick.y < -0.1 do dir.y -= 1
	if stick.y > 0.1 do dir.y += 1
	if stick.x < -0.1 do dir.x -= 1
	if stick.x > 0.1 do dir.x += 1
	if key_pressed(.UP) do dir.y -= 1
	if key_pressed(.DOWN) do dir.y += 1
	if key_pressed(.LEFT) do dir.x -= 1
	if key_pressed(.RIGHT) do dir.x += 1

	if dir != input.nav_dir_prev {
		input.nav_repeat_t = 0
	}
	if dir.x != 0 || dir.y != 0 {
		if input.nav_repeat_t <= 0 {
			nav.dir = dir
			input.nav_repeat_t = input.nav_dir_prev == dir ? 0.12 : 0.35
		}
		input.nav_repeat_t -= dt
	} else {
		input.nav_repeat_t = 0
	}
	input.nav_dir_prev = dir

	nav.confirm = key_pressed(.ENTER) || pad_pressed(.SOUTH)
	nav.back = key_pressed(.ESCAPE) || pad_pressed(.EAST)
	return nav
}

rumble :: proc(low, high: f32, ms: u32) {
	if input.gamepad == nil do return
	sdl.RumbleGamepad(input.gamepad, u16(clamp(low, 0, 1) * 65535), u16(clamp(high, 0, 1) * 65535), ms)
}
