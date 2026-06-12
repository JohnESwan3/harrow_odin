package main

import "core:math"
import "core:math/rand"

// Two particle families:
//   Debris — opaque shards: non-uniform scale + tumble so nothing reads as a
//            cube. Profile (count/shape/speed/color) depends on the material.
//   Soft   — alpha-blended dust and smoke puffs that grow and fade; drawn in
//            a separate no-depth-write blend pass. Cheap volumetric read.

MAX_PARTICLES :: 4096

Particle_Kind :: enum u8 {
	Debris,
	Soft,
}

Particle :: struct {
	kind:           Particle_Kind,
	pos, vel:       Vec3,
	color:          Vec4, // soft: .a is peak opacity
	scale:          Vec3,
	yaw, pitch:     f32,
	spin_y, spin_p: f32,
	life, max_life: f32,
	gravity, drag:  f32,
	grow:           f32, // scale growth per second (soft)
}

particles: struct {
	pool:  [MAX_PARTICLES]Particle,
	count: int,
}

particle_spawn :: proc(p: Particle) {
	if particles.count >= MAX_PARTICLES do return
	q := p
	q.yaw = rand.float32() * math.PI * 2
	q.pitch = rand.float32() * math.PI
	particles.pool[particles.count] = q
	particles.count += 1
}

rand_dir :: proc() -> Vec3 {
	for {
		v := Vec3{rand.float32() * 2 - 1, rand.float32() * 2 - 1, rand.float32() * 2 - 1}
		l := vlen(v)
		if l > 0.001 && l <= 1 do return v / l
	}
}

rr :: proc(lo, hi: f32) -> f32 {
	return lo + (hi - lo) * rand.float32()
}

// irregular shard: three independent axes so it never reads as a cube
shard_scale :: proc(base: f32, elongation: f32) -> Vec3 {
	return {
		base * rr(0.5, 1.4),
		base * rr(0.4, 1.1),
		base * rr(0.6, 1.5) * elongation,
	}
}

spawn_debris :: proc(pos, dir: Vec3, color: Vec4, base_size, speed, elong: f32, gravity: f32 = 14, life: f32 = 0.6) {
	particle_spawn({
		kind     = .Debris,
		pos      = pos,
		vel      = dir * speed,
		color    = color * Vec4{rr(0.75, 1.2), rr(0.75, 1.2), rr(0.75, 1.2), 1},
		scale    = shard_scale(base_size, elong),
		spin_y   = rr(-14, 14),
		spin_p   = rr(-14, 14),
		max_life = life * rr(0.7, 1.3),
		gravity  = gravity,
		drag     = 1.6,
	})
}

spawn_dust :: proc(pos, vel: Vec3, color: Vec3, opacity, size, grow, life: f32) {
	particle_spawn({
		kind     = .Soft,
		pos      = pos,
		vel      = vel,
		color    = {color.x, color.y, color.z, opacity},
		scale    = {size, size, size},
		spin_y   = rr(-1.2, 1.2),
		max_life = life * rr(0.8, 1.3),
		gravity  = -0.35, // dust drifts up slightly
		drag     = 2.4,
		grow     = grow,
	})
}

mat_color3 :: proc(mat: Material) -> Vec3 {
	c := MAT_COLORS[mat]
	return {f32(c[0]) / 255.0, f32(c[1]) / 255.0, f32(c[2]) / 255.0}
}

// material-aware impact: chips, splinters, sparks, and the right dust
particles_impact :: proc(pos, normal: Vec3, mat: Material) {
	c3 := mat_color3(mat)
	col := Vec4{c3.x, c3.y, c3.z, 1}
	burst_dir :: proc(normal: Vec3) -> Vec3 { return vnorm(rand_dir() + normal * 1.5) }

	#partial switch mat {
	case .Grass, .Dirt:
		for _ in 0 ..< 7 {
			spawn_debris(pos + normal * 0.03, burst_dir(normal), col, 0.045, rr(1.8, 4.5), 1.0)
		}
		dust := mat == .Grass ? Vec3{0.36, 0.32, 0.22} : Vec3{0.42, 0.32, 0.22}
		for _ in 0 ..< 3 {
			spawn_dust(pos + normal * rr(0.05, 0.2), burst_dir(normal) * rr(0.3, 1.0), dust, 0.30, rr(0.18, 0.3), 1.6, rr(0.7, 1.2))
		}
	case .Sand:
		for _ in 0 ..< 4 {
			spawn_debris(pos + normal * 0.03, burst_dir(normal), col, 0.03, rr(1.5, 3.5), 1.0)
		}
		for _ in 0 ..< 4 {
			spawn_dust(pos + normal * rr(0.05, 0.25), burst_dir(normal) * rr(0.4, 1.2), {0.62, 0.55, 0.4}, 0.35, rr(0.2, 0.35), 2.0, rr(0.8, 1.4))
		}
	case .Rock, .Concrete, .Concrete_Dark, .Bedrock:
		for _ in 0 ..< 8 {
			spawn_debris(pos + normal * 0.03, burst_dir(normal), col, 0.035, rr(2.5, 6.0), 1.2, 16, 0.5)
		}
		for _ in 0 ..< 2 {
			spawn_dust(pos + normal * rr(0.05, 0.15), burst_dir(normal) * rr(0.3, 0.8), c3 * 1.1, 0.26, rr(0.14, 0.24), 1.2, rr(0.5, 0.9))
		}
	case .Metal:
		// sparks: tiny, bright, elongated, fast
		for _ in 0 ..< 10 {
			particle_spawn({
				kind     = .Debris,
				pos      = pos + normal * 0.02,
				vel      = vnorm(rand_dir() + normal * 1.1) * rr(4, 10),
				color    = {1.0, rr(0.7, 0.9), rr(0.25, 0.45), 1},
				scale    = {0.012, 0.012, rr(0.05, 0.12)},
				spin_y   = rr(-20, 20),
				max_life = rr(0.15, 0.4),
				gravity  = 11,
				drag     = 0.7,
			})
		}
		spawn_dust(pos + normal * 0.1, normal * 0.4, {0.5, 0.52, 0.55}, 0.18, 0.12, 1.0, 0.5)
	case .Wood:
		for _ in 0 ..< 7 {
			spawn_debris(pos + normal * 0.03, burst_dir(normal), col, 0.04, rr(2.0, 5.0), 2.6, 13, 0.7)
		}
		spawn_dust(pos + normal * 0.08, normal * 0.5, c3, 0.2, 0.14, 1.1, 0.6)
	case:
		for _ in 0 ..< 6 {
			spawn_debris(pos + normal * 0.03, burst_dir(normal), col, 0.04, rr(2, 4.5), 1.2)
		}
	}
}

particles_blood :: proc(pos: Vec3, dir: Vec3) {
	for _ in 0 ..< 9 {
		spawn_debris(
			pos,
			vnorm(rand_dir() + dir * 0.6),
			{rr(0.35, 0.55), 0.04, 0.03, 1},
			0.03, rr(2.5, 6.0), 1.8, 16, 0.45,
		)
	}
	spawn_dust(pos, dir * 0.8, {0.32, 0.05, 0.04}, 0.22, 0.16, 1.4, 0.45)
}

particles_explosion :: proc(pos: Vec3, radius: f32) {
	// hot fragments
	for _ in 0 ..< 26 {
		hot := rand.float32()
		col := vlerp({1.0, 0.8, 0.35}, {0.3, 0.26, 0.22}, hot)
		spawn_debris(
			pos + rand_dir() * radius * 0.2,
			rand_dir(),
			{col.x, col.y, col.z, 1},
			rr(0.06, 0.16), rr(4, 4 + radius * 3), 1.3,
			hot > 0.5 ? 9.0 : 3.0, rr(0.5, 1.2),
		)
	}
	// rolling smoke + thrown dust
	for _ in 0 ..< 7 {
		spawn_dust(
			pos + rand_dir() * radius * 0.3,
			rand_dir() * rr(0.6, 2.2) + Vec3{0, rr(0.8, 1.8), 0},
			vlerp({0.16, 0.15, 0.14}, {0.34, 0.30, 0.25}, rand.float32()),
			0.42, rr(0.5, 0.9) * radius * 0.35, rr(2.2, 3.6) * radius * 0.3, rr(1.4, 2.4),
		)
	}
	for _ in 0 ..< 5 {
		spawn_dust(
			pos + rand_dir() * radius * 0.4,
			rand_dir() * rr(1.5, 4.0),
			{0.45, 0.38, 0.28},
			0.3, rr(0.3, 0.6) * radius * 0.3, rr(1.5, 2.5), rr(0.9, 1.6),
		)
	}
}

// barrel smoke + muzzle dust kick, called per shot
particles_muzzle :: proc(pos, dir: Vec3) {
	for _ in 0 ..< 2 {
		spawn_dust(
			pos + dir * rr(0.05, 0.25),
			dir * rr(0.6, 1.4) + Vec3{0, rr(0.25, 0.6), 0} + rand_dir() * 0.2,
			{0.42, 0.42, 0.40},
			0.16, rr(0.05, 0.09), rr(0.5, 0.9), rr(0.5, 0.9),
		)
	}
	// ground dust when firing close to a surface below
	hit, t, n := world_raycast(pos, {0, -1, 0}, 1.2)
	if hit {
		gp := pos + Vec3{0, -t, 0}
		c3 := mat_color3(material_at_hit(gp, n))
		spawn_dust(gp + Vec3{0, 0.05, 0}, dir * 0.5 + Vec3{0, 0.3, 0}, c3 * 0.9, 0.2, 0.2, 1.6, 0.8)
	}
}

particles_update :: proc(dt: f32) {
	i := 0
	for i < particles.count {
		p := &particles.pool[i]
		p.life += dt
		if p.life >= p.max_life {
			particles.count -= 1
			particles.pool[i] = particles.pool[particles.count]
			continue
		}
		p.vel.y -= p.gravity * dt
		p.vel *= 1.0 / (1.0 + p.drag * dt)
		p.pos += p.vel * dt
		p.yaw += p.spin_y * dt
		p.pitch += p.spin_p * dt
		if p.kind == .Soft {
			p.scale += p.grow * dt
		} else if p.vel.y < 0 && solid_at_world(p.pos) {
			// debris settles on the ground
			p.pos.y += TVOX * 0.5
			p.vel = {}
			p.gravity = 0
			p.spin_y = 0
			p.spin_p = 0
		}
		i += 1
	}
}

particles_push :: proc() {
	for i in 0 ..< particles.count {
		p := &particles.pool[i]
		t := p.life / p.max_life
		switch p.kind {
		case .Debris:
			s := p.scale * (t > 0.75 ? (1.0 - t) * 4.0 : 1.0) // shrink out at the end
			push_cube(mat4_trs(p.pos, p.yaw, p.pitch, s), p.color)
		case .Soft:
			fade_in := min(p.life * 6.0, 1.0)
			a := p.color.a * fade_in * math.pow(1.0 - t, 1.4)
			push_cube_soft(
				mat4_trs(p.pos, p.yaw, p.pitch * 0.3, p.scale),
				{p.color.r, p.color.g, p.color.b, a},
			)
		}
	}
}
