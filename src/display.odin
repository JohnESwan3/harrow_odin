package main

import "core:c"
import "core:math"
import "core:slice"
import "core:fmt"
import sdl "vendor:sdl3"
import win "core:sys/windows"
import sapp "../sokol/app"

MAX_DISPLAYS  :: 8
MAX_RES_MODES :: 64

Disp_Mode :: struct { w, h: i32 }

// ChangeDisplaySettingsExW is not in Odin's win32 package — declare it manually.
foreign import user32x "system:User32.lib"
foreign user32x {
	ChangeDisplaySettingsExW :: proc "system" (
		lpszDeviceName: win.LPCWSTR,
		lpDevMode:      ^win.DEVMODEW,
		hwnd:           win.HWND,
		dwFlags:        win.DWORD,
		lParam:         rawptr,
	) -> win.LONG ---
}

DM_PELSWIDTH        :: win.DWORD(0x0008_0000)
DM_PELSHEIGHT       :: win.DWORD(0x0010_0000)
DM_DISPLAYFREQUENCY :: win.DWORD(0x0040_0000)
CDS_FULLSCREEN      :: win.DWORD(0x0000_0004)
DISPLAY_DEVICE_ACTIVE :: win.DWORD(0x0000_0001)

disp_state: struct {
	display_ids:   [MAX_DISPLAYS]sdl.DisplayID,
	display_count: int,

	modes:      [MAX_RES_MODES]Disp_Mode,
	mode_count: int,

	refreshes:     [16]f32,
	refresh_count: int,

	win32_devname: [32]win.WCHAR, // Win32 device name for the current display
	has_devname:   bool,
	saved_devmode: win.DEVMODEW,  // original mode, restored on cleanup
}

// Called in main() before sapp.run — SDL VIDEO subsystem must be up.
display_enumerate :: proc() {
	_ = sdl.Init(sdl.INIT_VIDEO)

	n: c.int
	ids := sdl.GetDisplays(&n)
	if ids != nil {
		defer sdl.free(cast(rawptr)ids)
		disp_state.display_count = int(min(n, MAX_DISPLAYS))
		for i in 0 ..< disp_state.display_count {
			disp_state.display_ids[i] = ids[i]
		}
	}
	if disp_state.display_count == 0 {
		disp_state.display_ids[0] = sdl.GetPrimaryDisplay()
		disp_state.display_count  = 1
	}

	game.settings.display_idx = clamp(game.settings.display_idx, 0, disp_state.display_count - 1)

	// Save current primary Win32 display mode for restoration on exit.
	disp_state.saved_devmode.dmSize = u16(size_of(win.DEVMODEW))
	win.EnumDisplaySettingsW(nil, win.ENUM_CURRENT_SETTINGS, &disp_state.saved_devmode)

	display_update_modes()
}

// Rebuild the resolution list for the currently selected monitor.
display_update_modes :: proc() {
	id := disp_state.display_ids[game.settings.display_idx]

	n: c.int
	raw := sdl.GetFullscreenDisplayModes(id, &n)
	defer if raw != nil { sdl.free(cast(rawptr)raw) }

	disp_state.mode_count = 0
	if raw != nil {
		for i in 0 ..< int(n) {
			m := raw[i]
			if m == nil || m.w <= 0 || m.h <= 0 { continue }
			add_mode(i32(m.w), i32(m.h))
		}
	}

	// Always include the desktop (native) mode.
	if dm := sdl.GetDesktopDisplayMode(id); dm != nil && dm.w > 0 {
		add_mode(i32(dm.w), i32(dm.h))
	}

	// Sort largest first by pixel count.
	slice.sort_by(disp_state.modes[:disp_state.mode_count], proc(a, b: Disp_Mode) -> bool {
		return a.w * a.h > b.w * b.h
	})

	if disp_state.mode_count == 0 {
		disp_state.modes[0] = {1920, 1080}
		disp_state.mode_count = 1
	}

	game.settings.res_idx     = clamp(game.settings.res_idx, 0, disp_state.mode_count - 1)
	game.settings.refresh_idx = 0

	display_update_refreshes()
	display_find_win32_dev(id)
}

// Rebuild the refresh-rate list for the currently selected resolution.
display_update_refreshes :: proc() {
	disp_state.refresh_count = 0
	if disp_state.mode_count == 0 { return }

	id  := disp_state.display_ids[game.settings.display_idx]
	sel := disp_state.modes[game.settings.res_idx]

	n: c.int
	raw := sdl.GetFullscreenDisplayModes(id, &n)
	defer if raw != nil { sdl.free(cast(rawptr)raw) }

	if raw != nil {
		for i in 0 ..< int(n) {
			m := raw[i]
			if m == nil { continue }
			if i32(m.w) != sel.w || i32(m.h) != sel.h { continue }
			hz := m.refresh_rate
			if hz <= 0 { continue }
			dupe := false
			for j in 0 ..< disp_state.refresh_count {
				if math.abs(disp_state.refreshes[j] - hz) < 0.5 { dupe = true; break }
			}
			if !dupe && disp_state.refresh_count < 16 {
				disp_state.refreshes[disp_state.refresh_count] = hz
				disp_state.refresh_count += 1
			}
		}
	}

	// Highest rate first.
	slice.sort_by(disp_state.refreshes[:disp_state.refresh_count], proc(a, b: f32) -> bool {
		return a > b
	})

	// Win32 fallback if SDL gave us nothing.
	if disp_state.refresh_count == 0 {
		dm: win.DEVMODEW
		dm.dmSize = u16(size_of(win.DEVMODEW))
		if win.EnumDisplaySettingsW(nil, win.ENUM_CURRENT_SETTINGS, &dm) != win.FALSE {
			disp_state.refreshes[0]   = f32(dm.dmDisplayFrequency)
			disp_state.refresh_count  = 1
		}
	}

	game.settings.refresh_idx = clamp(game.settings.refresh_idx, 0, max(disp_state.refresh_count - 1, 0))
}

// Match an SDL3 display to its Win32 device name via virtual-screen position.
display_find_win32_dev :: proc(id: sdl.DisplayID) {
	disp_state.has_devname = false
	bounds: sdl.Rect
	if !sdl.GetDisplayBounds(id, &bounds) { return }

	dd: win.DISPLAY_DEVICEW
	dd.cb = u32(size_of(win.DISPLAY_DEVICEW))
	for i in win.DWORD(0) ..< 16 {
		if win.EnumDisplayDevicesW(nil, i, &dd, 0) == win.FALSE { break }
		if dd.StateFlags & DISPLAY_DEVICE_ACTIVE == 0 { continue }
		dm: win.DEVMODEW
		dm.dmSize = u16(size_of(win.DEVMODEW))
		if win.EnumDisplaySettingsW(transmute(win.LPCWSTR)&dd.DeviceName[0], win.ENUM_CURRENT_SETTINGS, &dm) == win.FALSE { continue }
		if i32(dm.dmPosition.x) == i32(bounds.x) && i32(dm.dmPosition.y) == i32(bounds.y) {
			copy(disp_state.win32_devname[:], dd.DeviceName[:])
			disp_state.has_devname = true
			return
		}
	}
}

// Apply windowed resolution — sizes and centres the window on the selected monitor.
display_apply_windowed :: proc() {
	if disp_state.mode_count == 0 { return }
	sel  := disp_state.modes[game.settings.res_idx]
	hwnd := win.HWND(sapp.win32_get_hwnd())
	if hwnd == nil { return }

	id := disp_state.display_ids[game.settings.display_idx]
	bounds: sdl.Rect
	sdl.GetDisplayBounds(id, &bounds)

	style := win.GetWindowLongW(hwnd, win.GWL_STYLE)
	rect  := win.RECT{0, 0, sel.w, sel.h}
	win.AdjustWindowRect(&rect, u32(style), win.FALSE)
	ww := rect.right - rect.left
	wh := rect.bottom - rect.top
	cx := i32(bounds.x) + (i32(bounds.w) - sel.w) / 2
	cy := i32(bounds.y) + (i32(bounds.h) - sel.h) / 2
	win.SetWindowPos(hwnd, nil, cx, cy, ww, wh, win.SWP_NOZORDER)
}

// Apply fullscreen: optionally change the display refresh rate, move window to
// the target monitor, then let sokol handle the borderless-fullscreen toggle.
display_apply_fullscreen :: proc() {
	hwnd := win.HWND(sapp.win32_get_hwnd())
	if hwnd == nil { return }

	if disp_state.has_devname && disp_state.refresh_count > 0 && disp_state.mode_count > 0 {
		sel := disp_state.modes[game.settings.res_idx]
		hz  := disp_state.refreshes[game.settings.refresh_idx]
		dm: win.DEVMODEW
		dm.dmSize             = u16(size_of(win.DEVMODEW))
		dm.dmPelsWidth        = win.DWORD(sel.w)
		dm.dmPelsHeight       = win.DWORD(sel.h)
		dm.dmDisplayFrequency = win.DWORD(hz)
		dm.dmFields           = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
		ChangeDisplaySettingsExW(transmute(win.LPCWSTR)&disp_state.win32_devname[0], &dm, nil, CDS_FULLSCREEN, nil)
	}

	id := disp_state.display_ids[game.settings.display_idx]
	bounds: sdl.Rect
	sdl.GetDisplayBounds(id, &bounds)
	win.SetWindowPos(hwnd, nil, i32(bounds.x), i32(bounds.y), 0, 0, win.SWP_NOSIZE | win.SWP_NOZORDER)

	if !sapp.is_fullscreen() { sapp.toggle_fullscreen() }
}

// Restore original display mode — called from cleanup_cb.
display_restore :: proc() {
	if disp_state.has_devname {
		// nil devmode = revert to registry settings
		ChangeDisplaySettingsExW(transmute(win.LPCWSTR)&disp_state.win32_devname[0], nil, nil, 0, nil)
	}
}

// ---- UI helpers (use temp allocator — valid within one frame) ----------------

display_ui_name :: proc(i: int) -> string {
	if i < 0 || i >= disp_state.display_count { return "?" }
	id   := disp_state.display_ids[i]
	name := sdl.GetDisplayName(id)
	if name == nil { return fmt.tprintf("DISPLAY %d", i + 1) }
	return fmt.tprintf("%d — %s", i + 1, name)
}

mode_ui_name :: proc(i: int) -> string {
	m := disp_state.modes[i]
	g  := gcd(m.w, m.h)
	return fmt.tprintf("%d × %d  (%d:%d)", m.w, m.h, m.w / g, m.h / g)
}

refresh_ui_name :: proc(hz: f32) -> string {
	if hz - math.floor(hz) < 0.05 { return fmt.tprintf("%d Hz", int(hz)) }
	return fmt.tprintf("%.2f Hz", hz)
}

// ---- helpers -----------------------------------------------------------------

@(private)
add_mode :: proc(w, h: i32) {
	for j in 0 ..< disp_state.mode_count {
		if disp_state.modes[j].w == w && disp_state.modes[j].h == h { return }
	}
	if disp_state.mode_count < MAX_RES_MODES {
		disp_state.modes[disp_state.mode_count] = {w, h}
		disp_state.mode_count += 1
	}
}

@(private)
gcd :: proc(a, b: i32) -> i32 {
	a, b := a, b
	for b != 0 { a, b = b, a % b }
	return a
}
