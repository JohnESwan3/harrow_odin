package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"
import sapp "../sokol/app"

clone_string :: strings.clone

Screen :: enum {
	Main_Menu,
	Host_Setup,
	Join_Browser,
	Settings,
	Settings_Video,
	In_Game,
}

Settings :: struct {
	player_name:  string,
	color_idx:    int,
	mouse_sens:   f32,
	stick_sens:   f32,
	invert_y:     bool,
	fov:          f32,
	show_fps:     bool,
	fullscreen:   bool,
	res_idx:      int,  // index into disp_state.modes (clamped on load)
	display_idx:  int,  // which monitor
	refresh_idx:  int,  // which refresh rate
	vsync:        bool,
	flash_idx:    int,  // flashlight color preset
	draw_dist:    f32,  // view radius in metres
}

FLASH_COLORS := [5]Vec3{
	{1.00, 0.90, 0.70}, // warm
	{0.85, 0.95, 1.00}, // cool
	{1.00, 0.65, 0.25}, // amber
	{0.95, 0.20, 0.15}, // red
	{0.30, 0.95, 0.40}, // green
}
FLASH_NAMES := [5]string{"WARM", "COOL", "AMBER", "RED", "GREEN"}

CALLSIGNS := [?]string{
	"REAPER", "NOMAD", "WRAITH", "BISHOP", "FROST", "ONYX", "HAVOC", "RELIC",
	"DRIFTER", "ASH", "JACKAL", "CINDER", "VANDAL", "WIDOW", "RAVEN", "SABLE",
	"MARROW", "THORN", "GULCH", "TALLOW", "BRIAR", "SLOUGH", "FERAL", "HARROWER",
}

callsign_random :: proc() -> string {
	name := rand.choice(CALLSIGNS[:])
	return fmt.aprintf("%s-%02d", name, rand.int_max(100))
}

default_settings :: proc() -> Settings {
	return {
		player_name = "",
		color_idx   = rand.int_max(MAX_PLAYERS),
		mouse_sens  = 3.0,
		stick_sens  = 5.0,
		fov         = 92,
		show_fps    = true,
		res_idx     = 0,
		vsync       = true,
		draw_dist   = 128.0,
	}
}

Projectile_Kind :: enum {
	Bullet,
	Rocket,
	Grenade,
}

Projectile :: struct {
	kind:          Projectile_Kind,
	weapon:        Weapon_Kind,
	pos, vel:      Vec3,
	owner:         int,
	damage:        f32,
	fuse:          f32,
	authoritative: bool,
	alive:         bool,
}

Tracer :: struct {
	a, b: Vec3,
	life: f32,
}

Explosion :: struct {
	pos: Vec3,
	t:   f32,
	r:   f32,
}

Game :: struct {
	screen:            Screen,
	settings_return:   Screen,
	paused:            bool,
	time:              f32,
	settings:          Settings,
	players:           [MAX_PLAYERS]Player,
	active:            [MAX_PLAYERS]bool,
	names:             [MAX_PLAYERS][NAME_LEN]u8,
	colors:            [MAX_PLAYERS]u8,
	local_id:          int,
	fired_this_window: bool,
	projectiles:       [dynamic]Projectile,
	tracers:           [dynamic]Tracer,
	explosions:        [dynamic]Explosion,
	hitmarker_t:       f32,
	hitmarker_kill:    bool,
	damage_flash:      f32,
	status_buf:        [96]u8,
	status_len:        int,
	status_t:          f32,
	menu_cam_angle:    f32,
	weapon_name_t:     f32,

	host_name:     [SERVER_NAME_LEN]u8,
	host_name_len: int,
	host_pass:     [24]u8,
	host_pass_len: int,
	join_pass:     [24]u8,
	join_pass_len: int,
	join_ip:       [24]u8,
	join_ip_len:   int,
	name_buf:      [NAME_LEN]u8,
	name_len:      int,
	join_selected: int,
	vsync_changed: bool,
	enter_t:       f32, // session entry time; brief fire-input grace
	tod:           f32, // time of day 0..1 (0.25 sunrise, 0.5 noon, 0.75 sunset)
	flashlight:    bool,
}

game: Game

game_status :: proc(msg: string) {
	n := copy(game.status_buf[:], msg)
	game.status_len = n
	game.status_t = 4.0
}

game_status_text :: proc() -> string {
	return string(game.status_buf[:game.status_len])
}

game_player_count :: proc() -> int {
	n := 0
	for a in game.active do if a do n += 1
	return n
}

local_player :: proc() -> ^Player {
	return &game.players[game.local_id]
}

// ---- session lifecycle ------------------------------------------------------

game_session_reset :: proc() {
	for i in 0 ..< MAX_PLAYERS do game.active[i] = false
	clear(&game.projectiles)
	clear(&game.tracers)
	clear(&game.explosions)
	particles.count = 0
	game.paused = false
}

game_begin_local :: proc(id: int) {
	game.local_id = id
	game.active[id] = true
	set_fixed(game.names[id][:], game.settings.player_name)
	game.colors[id] = u8(game.settings.color_idx)
	player_spawn(local_player(), id)
	game.screen = .In_Game
	game.enter_t = game.time
	// stream the immediate area synchronously so we don't fall through the world
	voxel_stream(local_player().pos, 0, sync_radius_m = 40)
}

game_start_solo :: proc() {
	net_stop()
	game_session_reset()
	voxel_world_init()
	game_begin_local(0)
}

game_start_host :: proc(server_name, password: string) {
	game_session_reset()
	voxel_world_init()
	if !net_host_start(server_name, password) do return
	game_begin_local(0)
	game_status(fmt.tprintf("HOSTING - UDP %d", NET_PORT))
}

game_enter_session :: proc(id: int) {
	game_session_reset()
	voxel_world_init() // same deterministic world; host streams its edits after
	game_begin_local(id)
	game_status("CONNECTED")
}

game_leave_session :: proc(reason: string) {
	if nett.role == .Host || nett.role == .None {
		voxel_save()
	}
	net_stop()
	game_session_reset()
	game.screen = .Main_Menu
	ui_reset_focus()
	if len(reason) > 0 do game_status(reason)
}

// ---- combat -----------------------------------------------------------------

game_hit_player :: proc(target: int, dmg: f32) {
	if target == game.local_id {
		player_damage(target, dmg)
	} else {
		net_send_hit(target, dmg)
	}
}

player_damage :: proc(id: int, dmg: f32) {
	p := &game.players[id]
	if !p.alive do return
	p.last_damage = 0
	game.damage_flash = min(game.damage_flash + dmg / 60.0, 1.2)
	p.shake = min(p.shake + dmg * 0.02, 1.5)
	rumble(0.6, 0.4, 120)
	absorbed := min(p.shield, dmg)
	p.shield -= absorbed
	p.health -= (dmg - absorbed)
	if p.health <= 0 {
		p.health = 0
		p.alive = false
		p.respawn_t = RESPAWN_TIME
		p.ads = false
	}
}

players_raycast :: proc(origin, dir: Vec3, max_t: f32, exclude: int) -> (id: int, t: f32, headshot: bool) {
	id = -1
	t = max_t
	for i in 0 ..< MAX_PLAYERS {
		if !game.active[i] || i == exclude do continue
		p := &game.players[i]
		if !p.alive do continue
		ok, bt, _ := ray_aabb(origin, dir, player_aabb(p), t)
		if ok && bt < t {
			id = i
			t = bt
			hit_y := origin.y + dir.y * bt
			headshot = hit_y > p.pos.y + player_half(p).y * 0.55
		}
	}
	return
}

spread_dir :: proc(dir: Vec3, spread_deg: f32) -> Vec3 {
	if spread_deg <= 0 do return dir
	up := Vec3{0, 1, 0}
	if abs(vdot(dir, up)) > 0.99 do up = {1, 0, 0}
	right := vnorm(vcross(dir, up))
	real_up := vcross(right, dir)
	ang := rand.float32() * math.PI * 2
	r := math.sqrt(rand.float32()) * spread_deg * DEG2RAD
	return vnorm(dir + (right * math.cos(ang) + real_up * math.sin(ang)) * math.tan(r))
}

muzzle_pos :: proc(cam: Camera, ads_t: f32) -> Vec3 {
	fwd := dir_from_angles(cam.yaw, cam.pitch)
	right := vnorm(vcross(fwd, Vec3{0, 1, 0}))
	side := lerp(0.18, 0.0, ads_t)
	down := lerp(0.12, 0.05, ads_t)
	return cam.pos + fwd * 0.5 + right * side - Vec3{0, down, 0}
}

game_fire_weapon :: proc(p: ^Player) {
	kind := p.weapon
	def := weapon_defs[kind]
	ws := &p.weapons[kind]
	dmg := weapon_fire(ws, kind)
	cam := player_camera(p)
	aim := dir_from_angles(cam.yaw, cam.pitch)
	muzzle := muzzle_pos(cam, p.ads_t)
	spread := weapon_spread_deg(ws, kind, p.ads)

	for _ in 0 ..< max(def.pellets, 1) {
		dir := spread_dir(aim, spread)
		pk: Projectile_Kind = kind == .Rocket_Launcher ? .Rocket : .Bullet
		append(&game.projectiles, Projectile{
			kind = pk, weapon = kind, pos = muzzle, vel = dir * def.muzzle_vel,
			owner = game.local_id, damage = dmg, fuse = 3.0,
			authoritative = true, alive = true,
		})
		net_send_shot(kind, muzzle, dir, 0)
	}

	particles_muzzle(muzzle, aim)
	player_recoil(p, def.recoil_pitch, (rand.float32() * 2 - 1) * def.recoil_yaw)
	p.shake = min(p.shake + def.recoil_pitch * 0.06, 1.0)
	rumble(def.recoil_pitch * 0.1, def.recoil_pitch * 0.16, 70)
	game.fired_this_window = true
	if ws.mag == 0 && ws.reserve > 0 do weapon_start_reload(ws, kind)
}

game_throw_grenade :: proc(p: ^Player) {
	if p.grenades <= 0 do return
	p.grenades -= 1
	cam := player_camera(p)
	dir := dir_from_angles(p.yaw, p.pitch)
	append(&game.projectiles, Projectile{
		kind = .Grenade, weapon = .Rocket_Launcher, pos = cam.pos + dir * 0.4,
		vel = dir * 16 + Vec3{0, 3.2, 0},
		owner = game.local_id, damage = 100, fuse = 2.0, authoritative = true, alive = true,
	})
	net_send_shot(.Rocket_Launcher, cam.pos + dir * 0.4, dir, -1)
	p.recoil_kick += 1.0
}

game_remote_shot :: proc(msg: Msg_Shot) {
	id := int(msg.shooter)
	if id >= 0 && id < MAX_PLAYERS && game.active[id] {
		game.players[id].firing_vis = 0.1
		game.players[id].weapons[Weapon_Kind(int(msg.weapon) % len(Weapon_Kind))].flash = 0.05
	}
	kind := Weapon_Kind(min(msg.weapon, u8(max(Weapon_Kind))))
	def := weapon_defs[kind]
	origin := Vec3(msg.origin)
	dir := Vec3(msg.dir)
	if msg.hit_t < 0 {
		append(&game.projectiles, Projectile{
			kind = .Grenade, weapon = kind, pos = origin, vel = dir * 16 + Vec3{0, 3.2, 0},
			owner = id, damage = 0, fuse = 2.0, authoritative = false, alive = true,
		})
	} else {
		pk: Projectile_Kind = kind == .Rocket_Launcher ? .Rocket : .Bullet
		append(&game.projectiles, Projectile{
			kind = pk, weapon = kind, pos = origin, vel = dir * def.muzzle_vel,
			owner = id, damage = 0, fuse = 3.0, authoritative = false, alive = true,
		})
	}
}

// explosion: visuals always; damage + world carve only from the owning sim
game_explode :: proc(pos: Vec3, radius, dmg: f32, authoritative: bool, power: f32 = 8.0) {
	append(&game.explosions, Explosion{pos = pos, t = 0, r = radius})
	particles_explosion(pos, radius)
	lp := local_player()
	d := vlen(lp.pos - pos)
	if d < radius * 3 {
		lp.shake = min(lp.shake + (1.0 - d / (radius * 3)) * 1.4, 2.0)
		rumble(0.8, 0.5, 200)
	}
	if !authoritative do return

	// carve the world (replicated as an op)
	op := Voxel_Op{pos = pos, r = radius * 0.55, power = power}
	voxel_apply_op(op, true)
	net_send_voxel_op(op)

	for i in 0 ..< MAX_PLAYERS {
		if !game.active[i] do continue
		p := &game.players[i]
		if !p.alive do continue
		closest := Vec3{
			clamp(pos.x, p.pos.x - player_half(p).x, p.pos.x + player_half(p).x),
			clamp(pos.y, p.pos.y - player_half(p).y, p.pos.y + player_half(p).y),
			clamp(pos.z, p.pos.z - player_half(p).z, p.pos.z + player_half(p).z),
		}
		dist := vlen(closest - pos)
		if dist < radius {
			fall := 1.0 - dist / radius
			game_hit_player(i, dmg * (0.3 + 0.7 * fall))
		}
	}
}

projectile_impact_world :: proc(pr: ^Projectile, hit_pos: Vec3, normal: Vec3) {
	mat := material_at_hit(hit_pos, normal)
	switch pr.kind {
	case .Bullet:
		particles_impact(hit_pos, normal, mat)
		if pr.authoritative {
			// chip the surface; replicated like any other edit
			power := weapon_defs[pr.weapon].impact_power
			op := Voxel_Op{pos = hit_pos - normal * 0.05, r = 0.16 + power * 0.03, power = power}
			voxel_apply_op(op, true)
			net_send_voxel_op(op)
		}
	case .Rocket:
		def := weapon_defs[.Rocket_Launcher]
		game_explode(hit_pos + normal * 0.1, def.splash_radius, pr.damage, pr.authoritative, power = 8.0)
	case .Grenade:
		// grenades bounce; explosion handled by fuse
	}
}

game_update_projectiles :: proc(dt: f32) {
	for &pr in game.projectiles {
		if !pr.alive do continue
		pr.fuse -= dt

		switch pr.kind {
		case .Bullet, .Rocket:
			if pr.kind == .Bullet do pr.vel.y -= 9.8 * dt
			step := pr.vel * dt
			step_len := vlen(step)
			dir := step_len > 0 ? step / step_len : Vec3{0, 0, -1}
			hit_world, wt, wn := world_raycast(pr.pos, dir, step_len)
			pid, pt, headshot := players_raycast(pr.pos, dir, step_len, pr.owner)
			if pid >= 0 && (!hit_world || pt < wt) {
				hp := pr.pos + dir * pt
				particles_blood(hp, dir)
				if pr.authoritative {
					d := pr.damage
					if headshot do d *= weapon_defs[pr.weapon].headshot_mult
					if pr.kind == .Rocket {
						game_explode(hp, weapon_defs[.Rocket_Launcher].splash_radius, pr.damage, true)
					} else {
						game_hit_player(pid, d)
					}
					if pr.owner == game.local_id {
						game.hitmarker_t = 0.25
						game.hitmarker_kill = game.players[pid].health - pr.damage <= 0 && game.players[pid].shield <= 0
						rumble(0.0, 0.35, 50)
					}
				}
				pr.alive = false
			} else if hit_world {
				hp := pr.pos + dir * wt
				projectile_impact_world(&pr, hp, wn)
				pr.alive = false
			} else {
				pr.pos += step
			}
			if pr.fuse <= 0 do pr.alive = false

		case .Grenade:
			pr.vel.y -= GRAVITY * 0.85 * dt
			step := pr.vel * dt
			step_len := vlen(step)
			if step_len > 0.0001 {
				dir := step / step_len
				hit, wt, n := world_raycast(pr.pos, dir, step_len + 0.08)
				if hit && wt <= step_len + 0.08 {
					pr.pos += dir * max(wt - 0.08, 0)
					pr.vel = (pr.vel - n * (2 * vdot(pr.vel, n))) * 0.42
					if vlen(pr.vel) < 0.8 do pr.vel = {}
				} else {
					pr.pos += step
				}
			}
			if pr.fuse <= 0 {
				pr.alive = false
				game_explode(pr.pos, 4.5, pr.authoritative ? pr.damage : 0, pr.authoritative, power = 6.0)
			}
		}
	}
	for i := len(game.projectiles) - 1; i >= 0; i -= 1 {
		if !game.projectiles[i].alive do unordered_remove(&game.projectiles, i)
	}
}

game_update_weapons :: proc(p: ^Player, dt: f32) {
	for kind in Weapon_Kind {
		weapon_update(&p.weapons[kind], kind, dt)
	}
	if !p.alive do return

	kind := p.weapon
	def := weapon_defs[kind]
	ws := &p.weapons[kind]

	switch_to := p.weapon
	if action_switch() {
		switch_to = Weapon_Kind((int(p.weapon) + 1) % len(Weapon_Kind))
	}
	if input.scroll > 0.5 do switch_to = Weapon_Kind((int(p.weapon) + 1) % len(Weapon_Kind))
	if input.scroll < -0.5 do switch_to = Weapon_Kind((int(p.weapon) + len(Weapon_Kind) - 1) % len(Weapon_Kind))
	if key_pressed(._1) do switch_to = .Pistol
	if key_pressed(._2) do switch_to = .SMG
	if key_pressed(._3) do switch_to = .Assault_Rifle
	if key_pressed(._4) do switch_to = .Shotgun
	if key_pressed(._5) do switch_to = .Sniper
	if key_pressed(._6) do switch_to = .Rocket_Launcher
	if switch_to != p.weapon {
		ws.reloading = false
		p.weapon = switch_to
		p.ads = false
		game.weapon_name_t = 1.6
		kind = switch_to
		def = weapon_defs[kind]
		ws = &p.weapons[kind]
	}

	// ADS is a hold; sprint wins
	p.ads = action_ads_held() && !p.sprinting && !ws.reloading

	if action_reload() {
		if ws.reloading {
			weapon_active_attempt(ws, kind)
		} else {
			weapon_start_reload(ws, kind)
		}
	}

	want_fire := def.auto ? action_fire_held() : action_fire_pressed()
	if game.time - game.enter_t < 0.5 do want_fire = false
	if want_fire {
		p.sprinting = false
		input.sprint_latch = false
		if weapon_can_fire(ws) do game_fire_weapon(p)
	}

	if action_grenade() {
		game_throw_grenade(p)
	}

	if action_flashlight() {
		game.flashlight = !game.flashlight
	}

	if action_melee() {
		aim := dir_from_angles(p.yaw, p.pitch)
		eye := player_eye(p)
		pid, mt, _ := players_raycast(eye, aim, 1.8, game.local_id)
		if pid >= 0 {
			game_hit_player(pid, 70)
			game.hitmarker_t = 0.25
			particles_blood(eye + aim * mt, aim)
		}
		p.recoil_kick += 1.2
	}
}

game_update_ingame :: proc(dt: f32) {
	p := local_player()

	if action_pause() {
		game.paused = !game.paused
		ui_reset_focus()
		// eat the edge so the pause menu doesn't see the same press as "back"
		input_consume_menu_edges()
	}

	// solo pauses freeze the whole simulation; multiplayer keeps running
	sim_running := !game.paused || nett.role != .None

	if !game.paused {
		player_update_local(p, dt)
		if p.alive {
			game_update_weapons(p, dt)
		} else if p.respawn_t <= 0 {
			player_spawn(p, int(game.time) % len(voxw.spawns))
		}
	}

	if sim_running {
		for i in 0 ..< MAX_PLAYERS {
			if game.active[i] && i != game.local_id {
				player_update_remote(&game.players[i], dt)
			}
		}

		game_update_projectiles(dt)
		particles_update(dt)

		for &tr in game.tracers do tr.life -= dt
		for i := len(game.tracers) - 1; i >= 0; i -= 1 {
			if game.tracers[i].life <= 0 do unordered_remove(&game.tracers, i)
		}
		for &ex in game.explosions do ex.t += dt
		for i := len(game.explosions) - 1; i >= 0; i -= 1 {
			if game.explosions[i].t > 0.25 do unordered_remove(&game.explosions, i)
		}
	}

	game.hitmarker_t = max(game.hitmarker_t - dt, 0)
	game.damage_flash = max(game.damage_flash - dt * 1.6, 0)
	game.weapon_name_t = max(game.weapon_name_t - dt, 0)

	if sapp.mouse_locked() != !game.paused {
		sapp.lock_mouse(!game.paused)
	}
}

game_push_dynamic :: proc() {
	for i in 0 ..< MAX_PLAYERS {
		if game.active[i] {
			player_push_body(&game.players[i], i, i == game.local_id)
		}
	}
	for pr in game.projectiles {
		switch pr.kind {
		case .Bullet:
			dir := vnorm(pr.vel)
			push_cube(mat4_beam(pr.pos - dir * 0.45, pr.pos, 0.02), Vec4{1.0, 0.84, 0.5, 1})
		case .Rocket:
			dir := vnorm(pr.vel)
			push_cube(mat4_beam(pr.pos - dir * 0.3, pr.pos + dir * 0.3, 0.12), Vec4{0.25, 0.28, 0.30, 1})
			push_cube(mat4_beam(pr.pos - dir * 0.55, pr.pos - dir * 0.3, 0.08), Vec4{1.0, 0.7, 0.3, 1})
		case .Grenade:
			blink := math.mod(pr.fuse, 0.3) < 0.12 ? Vec4{0.9, 0.25, 0.2, 1} : Vec4{0.18, 0.30, 0.20, 1}
			push_cube(mat4_trs(pr.pos, 0, 0, {0.14, 0.14, 0.14}), blink)
		}
	}
	for tr in game.tracers {
		push_cube(mat4_beam(tr.a, tr.b, 0.025), Vec4{1.0, 0.86, 0.55, 1})
	}
	for ex in game.explosions {
		t := ex.t / 0.25
		s := ex.r * (0.3 + 0.7 * t)
		c := vlerp({1.0, 0.85, 0.4}, {0.4, 0.1, 0.05}, t)
		push_cube(mat4_trs(ex.pos, game.time * 3, game.time * 2, {s, s, s}), Vec4{c.x, c.y, c.z, 1})
	}
	particles_push()
}

game_push_viewmodel :: proc(cam: Camera) {
	p := local_player()
	if !p.alive do return
	kind := p.weapon
	def := weapon_defs[kind]
	ws := &p.weapons[kind]

	// full scope view hides the gun
	if def.scope && p.ads_t > 0.85 do return

	fwd := dir_from_angles(cam.yaw, cam.pitch)
	right := vnorm(vcross(fwd, Vec3{0, 1, 0}))
	up := vcross(right, fwd)

	bob_mult := 1.0 - p.ads_t * 0.8
	bob := math.sin(p.bob_phase) * 0.012 * p.bob_amt * bob_mult
	bob2 := math.sin(p.bob_phase * 0.5) * 0.008 * p.bob_amt * bob_mult
	recoil_back := p.recoil_kick * 0.012
	sprint_drop := p.sprinting ? f32(0.12) : 0

	tuck := f32(0)
	if ws.reloading {
		rt := ws.reload_t
		tuck = math.sin(min(rt * 3, 1.0) * math.PI * 0.5) * 0.55
	}

	// hip pose vs ADS pose (centered, raised to the eye line)
	side := lerp(0.21, 0.0, p.ads_t)
	height := lerp(-0.20, -0.085, p.ads_t)
	dist := lerp(0.42, 0.34, p.ads_t)

	grip := cam.pos +
		fwd * (dist - recoil_back) +
		right * (side + bob2 - p.sway.x * 0.4 * bob_mult) +
		up * (height + bob - p.sway.y * 0.3 * bob_mult - tuck * 0.25 - sprint_drop)

	pitch := cam.pitch + p.recoil_kick * 0.02 - tuck * 0.9 + (p.sprinting ? -0.35 : 0)
	base := mat4_trs(grip, cam.yaw, pitch, {1, 1, 1})
	for part in def.parts {
		push_view_cube(base * mat4_translate(part.offset) * mat4_scale(part.size), part.color)
	}
	if ws.flash > 0 {
		mz := Vec3{0, 0.02, -0.75}
		s := 0.08 + ws.flash * 0.7
		push_view_cube(base * mat4_translate(mz) * mat4_scale({s, s, s * 1.4}), Vec4{1.0, 0.88, 0.45, 1})
	}
}

game_menu_camera :: proc(dt: f32) -> Camera {
	game.menu_cam_angle += dt * 0.05
	a := game.menu_cam_angle
	pos := Vec3{math.cos(a) * 38, terrain_height(math.cos(a) * 38, math.sin(a) * 38) + 16, math.sin(a) * 38}
	look := Vec3{0, terrain_height(0, 0) + 3, 0}
	d := vnorm(look - pos)
	return {
		pos   = pos,
		yaw   = math.atan2(d.x, -d.z),
		pitch = math.asin(d.y),
		fov   = 70,
	}
}
