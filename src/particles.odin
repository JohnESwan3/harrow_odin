package main

import "core:math"
import "core:math/rand"

// Pooled cube particles for impacts, debris and muzzle smoke.

MAX_PARTICLES :: 4096

Particle :: struct {
	pos, vel: Vec3,
	color:    Vec4,
	size:     f32,
	life:     f32,
	max_life: f32,
	gravity:  f32,
	drag:     f32,
}

particles: struct {
	pool:  [MAX_PARTICLES]Particle,
	count: int,
}

particle_spawn :: proc(p: Particle) {
	if particles.count >= MAX_PARTICLES do return
	particles.pool[particles.count] = p
	particles.count += 1
}

rand_dir :: proc() -> Vec3 {
	for {
		v := Vec3{rand.float32() * 2 - 1, rand.float32() * 2 - 1, rand.float32() * 2 - 1}
		l := vlen(v)
		if l > 0.001 && l <= 1 do return v / l
	}
}

// debris burst at an impact point, biased along the surface normal
particles_impact :: proc(pos, normal: Vec3, color: Vec4, count: int, speed: f32) {
	for _ in 0 ..< count {
		dir := vnorm(rand_dir() + normal * 1.4)
		sp := speed * (0.4 + rand.float32() * 0.9)
		particle_spawn({
			pos      = pos + normal * 0.03,
			vel      = dir * sp,
			color    = color * Vec4{0.8 + rand.float32() * 0.4, 0.8 + rand.float32() * 0.4, 0.8 + rand.float32() * 0.4, 1},
			size     = 0.04 + rand.float32() * 0.07,
			life     = 0,
			max_life = 0.4 + rand.float32() * 0.5,
			gravity  = 14,
			drag     = 1.5,
		})
	}
}

particles_blood :: proc(pos: Vec3, dir: Vec3) {
	for _ in 0 ..< 9 {
		particle_spawn({
			pos      = pos,
			vel      = vnorm(rand_dir() + dir * 0.6) * (2.5 + rand.float32() * 3.5),
			color    = {0.35 + rand.float32() * 0.2, 0.03, 0.02, 1},
			size     = 0.035 + rand.float32() * 0.05,
			life     = 0,
			max_life = 0.35 + rand.float32() * 0.3,
			gravity  = 16,
			drag     = 1.2,
		})
	}
}

particles_explosion :: proc(pos: Vec3, radius: f32) {
	for _ in 0 ..< 36 {
		hot := rand.float32()
		col := vlerp({1.0, 0.8, 0.35}, {0.25, 0.22, 0.2}, hot)
		particle_spawn({
			pos      = pos + rand_dir() * radius * 0.2,
			vel      = rand_dir() * (4 + rand.float32() * radius * 3),
			color    = {col.x, col.y, col.z, 1},
			size     = 0.08 + rand.float32() * 0.22,
			life     = 0,
			max_life = 0.5 + rand.float32() * 0.8,
			gravity  = hot > 0.5 ? 9.0 : 2.0,
			drag     = 2.2,
		})
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

		// cheap ground stop
		if p.vel.y < 0 && solid_at_world(p.pos) {
			p.pos.y += SVOX * 0.5
			p.vel = {}
			p.gravity = 0
		}

		i += 1
	}
}

particles_push :: proc() {
	for i in 0 ..< particles.count {
		p := &particles.pool[i]
		fade := 1.0 - p.life / p.max_life
		s := p.size * (0.5 + 0.5 * fade)
		push_cube(mat4_trs(p.pos, p.life * 4, p.life * 3, {s, s, s}), p.color)
	}
}