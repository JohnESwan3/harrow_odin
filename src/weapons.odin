package main

// Weapon definitions and reload state. Every gun fires real projectiles with
// gravity; recoil is partly permanent (you pull the muzzle back down) and
// partly recovering, Halo-paced. Active reload (Gears style) stays: a second
// reload press in the marked window finishes early — the small bright window
// also gives a quiet damage bonus for that magazine; missing jams the gun.

Weapon_Kind :: enum u8 {
	Pistol,
	SMG,
	Assault_Rifle,
	Shotgun,
	Sniper,
	Rocket_Launcher,
}

Gun_Part :: struct {
	offset: Vec3, // relative to grip origin, weapon faces -Z
	size:   Vec3,
	color:  Vec4,
}

Weapon_Def :: struct {
	name:           string,
	damage:         f32,
	rpm:            f32,
	auto:           bool,
	mag:            int,
	reserve:        int,
	spread_deg:     f32,
	bloom_deg:      f32,
	pellets:        int,
	muzzle_vel:     f32, // m/s
	splash_radius:  f32, // explosive projectiles
	reload_time:    f32,
	active_perfect: Vec2,
	active_good:    Vec2,
	ads_zoom:       f32, // fov divisor while aiming
	scope:          bool,
	headshot_mult:  f32,
	recoil_pitch:   f32, // degrees per shot
	recoil_yaw:     f32, // random horizontal component
	impact_power:   f32, // gates world destruction vs material toughness
	parts:          []Gun_Part,
}

GM :: Vec4{0.16, 0.17, 0.19, 1} // gunmetal
GM2 :: Vec4{0.10, 0.11, 0.12, 1}
GRIP :: Vec4{0.20, 0.15, 0.11, 1}
SIGHT :: Vec4{0.05, 0.05, 0.05, 1}

weapon_defs := [Weapon_Kind]Weapon_Def{
	.Pistol = {
		name = "PISTOL", damage = 32, rpm = 280, auto = false, mag = 15, reserve = 60,
		spread_deg = 0.5, bloom_deg = 0.45, pellets = 1, muzzle_vel = 160,
		reload_time = 1.15, active_perfect = {0.30, 0.38}, active_good = {0.38, 0.62},
		ads_zoom = 1.25, headshot_mult = 2.0, recoil_pitch = 1.5, recoil_yaw = 0.35, impact_power = 1.5,
		parts = {
			{{0, 0.02, -0.14}, {0.045, 0.07, 0.30}, GM},
			{{0, -0.05, 0.02}, {0.04, 0.12, 0.07}, GRIP},
			{{0, 0.065, -0.10}, {0.03, 0.025, 0.16}, GM2},
			{{0, 0.075, -0.26}, {0.012, 0.02, 0.02}, SIGHT},
			{{0, 0.075, 0.0}, {0.026, 0.018, 0.015}, SIGHT},
		},
	},
	.SMG = {
		name = "SMG", damage = 16, rpm = 820, auto = true, mag = 30, reserve = 150,
		spread_deg = 1.5, bloom_deg = 0.20, pellets = 1, muzzle_vel = 175,
		reload_time = 1.65, active_perfect = {0.28, 0.35}, active_good = {0.35, 0.58},
		ads_zoom = 1.2, headshot_mult = 1.4, recoil_pitch = 0.55, recoil_yaw = 0.3, impact_power = 1.2,
		parts = {
			{{0, 0.02, -0.16}, {0.05, 0.09, 0.34}, GM},
			{{0, -0.07, 0.0}, {0.04, 0.12, 0.06}, GRIP},
			{{0, -0.08, -0.16}, {0.035, 0.14, 0.05}, GM2},
			{{0, 0.02, -0.38}, {0.025, 0.025, 0.12}, GM2},
			{{0, 0.0, 0.1}, {0.045, 0.05, 0.14}, GM2},
			{{0, 0.085, -0.30}, {0.012, 0.022, 0.02}, SIGHT},
			{{0, 0.085, 0.02}, {0.028, 0.02, 0.015}, SIGHT},
		},
	},
	.Assault_Rifle = {
		name = "ASSAULT RIFLE", damage = 25, rpm = 600, auto = true, mag = 30, reserve = 120,
		spread_deg = 1.0, bloom_deg = 0.28, pellets = 1, muzzle_vel = 250,
		reload_time = 1.9, active_perfect = {0.28, 0.35}, active_good = {0.35, 0.60},
		ads_zoom = 1.35, headshot_mult = 1.6, recoil_pitch = 0.85, recoil_yaw = 0.32, impact_power = 1.8,
		parts = {
			{{0, 0.02, -0.22}, {0.055, 0.10, 0.46}, GM},
			{{0, -0.07, 0.0}, {0.045, 0.13, 0.06}, GRIP},
			{{0, -0.09, -0.20}, {0.04, 0.16, 0.06}, GM2},
			{{0, 0.02, -0.52}, {0.03, 0.03, 0.16}, GM2},
			{{0, 0.0, 0.16}, {0.05, 0.07, 0.18}, GM},
			{{0, 0.09, -0.46}, {0.012, 0.025, 0.02}, SIGHT},
			{{0, 0.09, -0.02}, {0.03, 0.022, 0.015}, SIGHT},
		},
	},
	.Shotgun = {
		name = "SHOTGUN", damage = 13, rpm = 68, auto = false, mag = 6, reserve = 36,
		spread_deg = 4.2, bloom_deg = 0, pellets = 8, muzzle_vel = 120,
		reload_time = 2.2, active_perfect = {0.32, 0.40}, active_good = {0.40, 0.64},
		ads_zoom = 1.15, headshot_mult = 1.0, recoil_pitch = 3.4, recoil_yaw = 0.6, impact_power = 1.0,
		parts = {
			{{0, 0.02, -0.26}, {0.06, 0.08, 0.55}, GM},
			{{0, -0.02, -0.30}, {0.05, 0.05, 0.40}, GM2},
			{{0, -0.07, 0.02}, {0.045, 0.12, 0.07}, GRIP},
			{{0, 0.0, 0.16}, {0.05, 0.08, 0.16}, GRIP},
			{{0, 0.075, -0.50}, {0.012, 0.02, 0.02}, SIGHT},
		},
	},
	.Sniper = {
		name = "SNIPER RIFLE", damage = 110, rpm = 45, auto = false, mag = 5, reserve = 25,
		spread_deg = 0.05, bloom_deg = 0, pellets = 1, muzzle_vel = 520,
		reload_time = 2.6, active_perfect = {0.32, 0.39}, active_good = {0.39, 0.62},
		ads_zoom = 4.5, scope = true, headshot_mult = 2.5, recoil_pitch = 4.0, recoil_yaw = 0.5, impact_power = 4.2,
		parts = {
			{{0, 0.02, -0.34}, {0.05, 0.08, 0.75}, GM},
			{{0, 0.02, -0.72}, {0.03, 0.03, 0.30}, GM2},
			{{0, 0.09, -0.18}, {0.04, 0.05, 0.26}, SIGHT},
			{{0, -0.07, 0.02}, {0.045, 0.13, 0.06}, GRIP},
			{{0, -0.06, -0.26}, {0.04, 0.10, 0.05}, GM2},
			{{0, 0.0, 0.18}, {0.05, 0.09, 0.20}, GM},
		},
	},
	.Rocket_Launcher = {
		name = "ROCKET LAUNCHER", damage = 130, rpm = 50, auto = false, mag = 1, reserve = 7,
		spread_deg = 0.2, bloom_deg = 0, pellets = 1, muzzle_vel = 28,
		splash_radius = 4.5,
		reload_time = 3.0, active_perfect = {0.34, 0.42}, active_good = {0.42, 0.66},
		ads_zoom = 1.6, headshot_mult = 1.0, recoil_pitch = 3.0, recoil_yaw = 0.5, impact_power = 8.0,
		parts = {
			{{0, 0.06, -0.30}, {0.13, 0.13, 0.95}, GM},
			{{0, 0.06, -0.30}, {0.145, 0.10, 0.5}, GM2},
			{{0, -0.07, 0.0}, {0.045, 0.13, 0.06}, GRIP},
			{{0, -0.05, -0.25}, {0.04, 0.09, 0.05}, GM2},
			{{0.0, 0.14, -0.1}, {0.03, 0.05, 0.12}, SIGHT},
		},
	},
}

Active_Result :: enum u8 {
	None,
	Perfect,
	Good,
	Jam,
}

Weapon_State :: struct {
	mag:           int,
	reserve:       int,
	cooldown:      f32,
	bloom:         f32,
	reloading:     bool,
	reload_t:      f32,
	reload_total:  f32,
	active_used:   bool,
	active_result: Active_Result,
	boost:         f32,
	flash:         f32,
}

weapon_state_init :: proc(ws: ^Weapon_State, kind: Weapon_Kind) {
	def := weapon_defs[kind]
	ws^ = {
		mag     = def.mag,
		reserve = def.reserve,
		boost   = 1.0,
	}
}

weapon_can_fire :: proc(ws: ^Weapon_State) -> bool {
	return !ws.reloading && ws.cooldown <= 0 && ws.mag > 0
}

weapon_start_reload :: proc(ws: ^Weapon_State, kind: Weapon_Kind) {
	def := weapon_defs[kind]
	if ws.reloading || ws.reserve <= 0 || ws.mag >= def.mag do return
	ws.reloading = true
	ws.reload_t = 0
	ws.reload_total = def.reload_time
	ws.active_used = false
	ws.active_result = .None
}

weapon_active_attempt :: proc(ws: ^Weapon_State, kind: Weapon_Kind) {
	if !ws.reloading || ws.active_used do return
	def := weapon_defs[kind]
	ws.active_used = true
	t := ws.reload_t
	switch {
	case t >= def.active_perfect.x && t < def.active_perfect.y:
		ws.active_result = .Perfect
		weapon_finish_reload(ws, kind)
		ws.boost = 1.15
	case t >= def.active_good.x && t < def.active_good.y:
		ws.active_result = .Good
		weapon_finish_reload(ws, kind)
	case:
		ws.active_result = .Jam
		ws.reload_total = def.reload_time * 1.6
	}
}

weapon_finish_reload :: proc(ws: ^Weapon_State, kind: Weapon_Kind) {
	def := weapon_defs[kind]
	take := min(def.mag - ws.mag, ws.reserve)
	ws.mag += take
	ws.reserve -= take
	ws.reloading = false
	ws.boost = 1.0
}

weapon_update :: proc(ws: ^Weapon_State, kind: Weapon_Kind, dt: f32) {
	def := weapon_defs[kind]
	ws.cooldown = max(ws.cooldown - dt, 0)
	ws.bloom = max(ws.bloom - dt * 6 * (def.bloom_deg + 0.2), 0)
	ws.flash = max(ws.flash - dt, 0)
	if ws.reloading {
		ws.reload_t += dt / ws.reload_total
		if ws.reload_t >= 1 {
			weapon_finish_reload(ws, kind)
			ws.active_result = .None
		}
	}
}

weapon_fire :: proc(ws: ^Weapon_State, kind: Weapon_Kind) -> f32 {
	def := weapon_defs[kind]
	ws.mag -= 1
	ws.cooldown = 60.0 / def.rpm
	ws.bloom = min(ws.bloom + def.bloom_deg, 3.0)
	ws.flash = 0.05
	return def.damage * ws.boost
}

weapon_spread_deg :: proc(ws: ^Weapon_State, kind: Weapon_Kind, ads: bool) -> f32 {
	def := weapon_defs[kind]
	s := def.spread_deg + ws.bloom
	if ads do s *= 0.3
	return s
}
