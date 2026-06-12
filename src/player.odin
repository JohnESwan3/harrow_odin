package main

import "core:math"

// Player simulation. Halo-paced base movement with sprint on top of it,
// stamina, ADS, recharging shields, and recoil that is partly permanent
// (you manage the climb) and partly recovering.

MAX_PLAYERS :: 8

PLAYER_HALF :: Vec3{0.38, 0.90, 0.38}
PLAYER_HALF_CROUCH :: Vec3{0.38, 0.62, 0.38}
EYE_HEIGHT :: 1.62
EYE_HEIGHT_CROUCH :: 1.04
WALK_SPEED :: 5.2
STRAFE_SPEED :: 4.7
SPRINT_SPEED :: 7.8
CROUCH_SPEED :: 2.6
ADS_SPEED_MULT :: 0.6
GROUND_ACCEL :: 40.0
AIR_ACCEL :: 9.0
FRICTION :: 9.0
GRAVITY :: 11.5
JUMP_VEL :: 4.6
COYOTE_TIME :: 0.10
MAX_SHIELD :: 100.0
MAX_HEALTH :: 100.0
SHIELD_DELAY :: 4.0
SHIELD_RATE :: 55.0
RESPAWN_TIME :: 4.0
MAX_STAMINA :: 100.0
STAMINA_DRAIN :: 16.0
STAMINA_REGEN :: 13.0
STAMINA_REGEN_DELAY :: 1.2

Player_Flags :: enum u8 {
	Firing,
	Crouching,
	Alive,
	ADS,
	Sprinting,
}

Player :: struct {
	pos:         Vec3, // feet center
	vel:         Vec3,
	yaw, pitch:  f32,
	on_ground:   bool,
	crouching:   bool,
	sprinting:   bool,
	alive:       bool,
	health:      f32,
	shield:      f32,
	stamina:     f32,
	stam_delay:  f32,
	last_damage: f32,
	respawn_t:   f32,
	weapon:      Weapon_Kind,
	weapons:     [Weapon_Kind]Weapon_State,
	grenades:    int,
	ads:         bool,
	ads_t:       f32, // 0..1 blend

	// view feel
	coyote:       f32,
	bob_phase:    f32,
	bob_amt:      f32,
	land_dip:     f32,
	recoil_off:   f32, // recovering portion of recoil (radians)
	recoil_kick:  f32, // viewmodel kick
	sway:         Vec2,
	shake:        f32,

	// remote interpolation
	net_pos:    Vec3,
	net_vel:    Vec3,
	net_yaw:    f32,
	net_pitch:  f32,
	net_age:    f32,
	firing_vis: f32,
}

player_spawn :: proc(p: ^Player, spawn_idx: int) {
	sp := voxw.spawns[spawn_idx % len(voxw.spawns)]
	p.pos = sp + Vec3{0, PLAYER_HALF.y + 0.1, 0}
	p.vel = {}
	p.yaw = math.atan2(-sp.x, sp.z) // face the compound
	p.pitch = 0
	p.alive = true
	p.health = MAX_HEALTH
	p.shield = MAX_SHIELD
	p.stamina = MAX_STAMINA
	p.last_damage = 100
	p.crouching = false
	p.sprinting = false
	p.ads = false
	p.ads_t = 0
	p.recoil_off = 0
	p.grenades = 4
	for kind in Weapon_Kind {
		weapon_state_init(&p.weapons[kind], kind)
	}
	p.weapon = .Assault_Rifle
}

player_eye :: proc(p: ^Player) -> Vec3 {
	eye_h := lerp(EYE_HEIGHT, EYE_HEIGHT_CROUCH, p.crouching ? 1.0 : 0.0)
	bob := math.sin(p.bob_phase) * 0.045 * p.bob_amt * (1.0 - p.ads_t * 0.7)
	return p.pos + Vec3{0, eye_h - PLAYER_HALF.y + bob - p.land_dip, 0}
}

player_half :: proc(p: ^Player) -> Vec3 {
	return p.crouching ? PLAYER_HALF_CROUCH : PLAYER_HALF
}

player_aabb :: proc(p: ^Player) -> AABB {
	h := player_half(p)
	return {min = p.pos - h, max = p.pos + h}
}

// recoil: 40% applied to actual pitch (permanent), 60% recovers on a spring
player_recoil :: proc(p: ^Player, pitch_deg, yaw_deg: f32) {
	p.pitch = clamp(p.pitch + pitch_deg * 0.4 * DEG2RAD, -88 * DEG2RAD, 88 * DEG2RAD)
	p.yaw += yaw_deg * DEG2RAD
	p.recoil_off += pitch_deg * 0.6 * DEG2RAD
	p.recoil_kick += pitch_deg * 0.4
}

player_update_local :: proc(p: ^Player, dt: f32) {
	if !p.alive {
		p.respawn_t -= dt
		return
	}

	def := weapon_defs[p.weapon]
	ads_scale := lerp(1.0, 1.0 / def.ads_zoom, p.ads_t)
	look := action_look(dt, game.settings.mouse_sens, game.settings.stick_sens, game.settings.invert_y, ads_scale)
	p.yaw += look.x
	p.pitch = clamp(p.pitch + look.y, -88 * DEG2RAD, 88 * DEG2RAD)
	p.sway = vlerp({p.sway.x, p.sway.y, 0}, {look.x, look.y, 0}, smooth(10, dt)).xy

	// recoil recovery
	p.recoil_off = lerp(p.recoil_off, 0, smooth(7, dt))
	p.recoil_kick = lerp(p.recoil_kick, 0, smooth(11, dt))

	if action_crouch_toggle() {
		if p.crouching {
			if aabb_clear(p.pos + Vec3{0, PLAYER_HALF.y - PLAYER_HALF_CROUCH.y, 0}, PLAYER_HALF) {
				p.crouching = false
			}
		} else {
			p.crouching = true
			p.sprinting = false
		}
	}

	mv := action_move()
	moving_fwd := mv.y > 0.4

	// sprint: hold (shift) or stick-click latch; needs stamina + forward motion
	if action_sprint_pad_pressed() do input.sprint_latch = true
	if action_sprint_held() && moving_fwd && p.on_ground && !p.crouching && p.stamina > 1 {
		if !p.sprinting && p.stamina > 12 do p.sprinting = true
	} else {
		p.sprinting = false
		if !moving_fwd do input.sprint_latch = false
	}
	if p.sprinting {
		p.ads = false
		p.stamina = max(p.stamina - STAMINA_DRAIN * dt, 0)
		p.stam_delay = STAMINA_REGEN_DELAY
		if p.stamina <= 0 do p.sprinting = false
	} else {
		p.stam_delay -= dt
		if p.stam_delay <= 0 {
			p.stamina = min(p.stamina + STAMINA_REGEN * dt, MAX_STAMINA)
		}
	}

	// ADS blend
	p.ads_t = lerp(p.ads_t, p.ads ? 1.0 : 0.0, smooth(14, dt))

	fwd := flat_forward(p.yaw)
	right := flat_right(p.yaw)
	fwd_speed := f32(WALK_SPEED)
	if p.sprinting do fwd_speed = SPRINT_SPEED
	if p.crouching do fwd_speed = CROUCH_SPEED
	side_speed := p.crouching ? f32(CROUCH_SPEED) : f32(STRAFE_SPEED)
	speed_mult := lerp(1.0, ADS_SPEED_MULT, p.ads_t)
	wish := (fwd * (mv.y * fwd_speed) + right * (mv.x * side_speed)) * speed_mult

	accel := p.on_ground ? f32(GROUND_ACCEL) : f32(AIR_ACCEL)
	ref := max(fwd_speed, 0.001)
	p.vel.x = lerp(p.vel.x, wish.x, smooth(accel / ref, dt))
	p.vel.z = lerp(p.vel.z, wish.z, smooth(accel / ref, dt))
	if p.on_ground && mv.x == 0 && mv.y == 0 {
		p.vel.x = lerp(p.vel.x, 0, smooth(FRICTION, dt))
		p.vel.z = lerp(p.vel.z, 0, smooth(FRICTION, dt))
	}

	p.coyote = p.on_ground ? COYOTE_TIME : p.coyote - dt
	if action_jump() && p.coyote > 0 {
		p.vel.y = JUMP_VEL
		p.coyote = 0
		p.on_ground = false
	}
	p.vel.y -= GRAVITY * dt

	was_airborne := !p.on_ground
	fall_speed := -p.vel.y
	new_pos, on_ground, hit_ceiling := world_move(p.pos, player_half(p), p.vel * dt, allow_step = p.on_ground)
	p.pos = new_pos
	p.on_ground = on_ground
	if on_ground && p.vel.y < 0 do p.vel.y = 0
	if hit_ceiling && p.vel.y > 0 do p.vel.y = 0
	if on_ground && was_airborne && fall_speed > 3 {
		p.land_dip = min(fall_speed * 0.02, 0.14)
		rumble(0.3, 0.1, 60)
		// hard landings hurt
		if fall_speed > 12 do player_damage(game.local_id, (fall_speed - 12) * 7)
	}
	p.land_dip = lerp(p.land_dip, 0, smooth(8, dt))

	if p.pos.y < -10 do player_damage(game.local_id, 1000)

	hspeed := vlen({p.vel.x, 0, p.vel.z})
	if p.on_ground && hspeed > 0.5 {
		p.bob_phase += dt * hspeed * 1.9
		p.bob_amt = lerp(p.bob_amt, min(hspeed / WALK_SPEED, 1.3), smooth(8, dt))
	} else {
		p.bob_amt = lerp(p.bob_amt, 0, smooth(8, dt))
	}

	p.last_damage += dt
	if p.last_damage > SHIELD_DELAY {
		p.shield = min(p.shield + SHIELD_RATE * dt, MAX_SHIELD)
	}

	p.shake = lerp(p.shake, 0, smooth(6, dt))
}

player_update_remote :: proc(p: ^Player, dt: f32) {
	p.net_age += dt
	target := p.net_pos + p.net_vel * min(p.net_age, 0.25)
	t := smooth(14, dt)
	p.pos = vlerp(p.pos, target, t)
	p.yaw = angle_lerp(p.yaw, p.net_yaw, t)
	p.pitch = lerp(p.pitch, p.net_pitch, t)
	p.firing_vis = max(p.firing_vis - dt, 0)
	for kind in Weapon_Kind {
		p.weapons[kind].flash = max(p.weapons[kind].flash - dt, 0)
	}
}

player_camera :: proc(p: ^Player) -> Camera {
	shake := Vec3{}
	if p.shake > 0.001 {
		shake = {
			math.sin(game.time * 71) * p.shake * 0.01,
			math.cos(game.time * 83) * p.shake * 0.012,
			0,
		}
	}
	def := weapon_defs[p.weapon]
	fov := lerp(game.settings.fov, game.settings.fov / def.ads_zoom, p.ads_t)
	return {
		pos   = player_eye(p) + shake,
		yaw   = p.yaw,
		pitch = clamp(p.pitch + p.recoil_off, -89 * DEG2RAD, 89 * DEG2RAD),
		fov   = fov,
	}
}

PLAYER_COLORS := [MAX_PLAYERS]Vec4{
	{0.35, 0.38, 0.30, 1}, // olive
	{0.48, 0.30, 0.16, 1}, // rust
	{0.26, 0.33, 0.38, 1}, // slate
	{0.42, 0.38, 0.26, 1}, // tan
	{0.40, 0.18, 0.16, 1}, // oxblood
	{0.22, 0.28, 0.22, 1}, // forest
	{0.45, 0.42, 0.38, 1}, // bone
	{0.28, 0.22, 0.32, 1}, // bruise
}

PLAYER_COLOR_NAMES := [MAX_PLAYERS]string{
	"OLIVE", "RUST", "SLATE", "TAN", "OXBLOOD", "FOREST", "BONE", "BRUISE",
}

player_color :: proc(id: int) -> Vec4 {
	return PLAYER_COLORS[int(game.colors[id]) % MAX_PLAYERS]
}

// greybox body; local player renders without a head (camera lives there)
player_push_body :: proc(p: ^Player, id: int, is_local: bool) {
	if !p.alive do return
	color := player_color(id)
	dark := color * Vec4{0.55, 0.55, 0.55, 1}
	base := p.pos
	h := player_half(p)
	body_h := h.y * 1.16
	push_cube(mat4_trs(base + Vec3{0, -h.y + body_h * 0.5, 0}, p.yaw, 0, {0.58, body_h, 0.36}), color)
	if !is_local {
		head_y := -h.y + body_h + 0.18
		push_cube(mat4_trs(base + Vec3{0, head_y, 0}, p.yaw, 0, {0.28, 0.30, 0.32}), dark)
		visor_off := flat_forward(p.yaw) * 0.12
		push_cube(mat4_trs(base + Vec3{0, head_y + 0.02, 0} + visor_off, p.yaw, 0, {0.20, 0.08, 0.10}), Vec4{0.55, 0.35, 0.15, 1})

		def := weapon_defs[p.weapon]
		eye := base + Vec3{0, -h.y + body_h * 0.82, 0}
		grip := eye + dir_from_angles(p.yaw, p.pitch) * 0.55 + flat_right(p.yaw) * 0.22
		for part in def.parts {
			m := mat4_trs(grip, p.yaw, p.pitch, {1, 1, 1}) * mat4_translate(part.offset) * mat4_scale(part.size)
			push_cube(m, part.color)
		}
		if p.firing_vis > 0 {
			muzzle := grip + dir_from_angles(p.yaw, p.pitch) * 0.8
			push_cube(mat4_trs(muzzle, p.yaw, 0, {0.12, 0.12, 0.12}), Vec4{1.0, 0.85, 0.4, 1})
		}
	}
}
