package main

import "core:math"
import "core:math/linalg"

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Mat4 :: matrix[4, 4]f32

DEG2RAD :: math.PI / 180.0

vnorm :: proc(v: Vec3) -> Vec3 {
	return linalg.normalize0(v)
}

vlen :: proc(v: Vec3) -> f32 {
	return linalg.length(v)
}

vdot :: proc(a, b: Vec3) -> f32 {
	return linalg.dot(a, b)
}

vcross :: proc(a, b: Vec3) -> Vec3 {
	return linalg.cross(a, b)
}

lerp :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

vlerp :: proc(a, b: Vec3, t: f32) -> Vec3 {
	return a + (b - a) * t
}

// framerate-independent exponential smoothing factor
smooth :: proc(rate, dt: f32) -> f32 {
	return 1.0 - math.exp(-rate * dt)
}

angle_lerp :: proc(a, b, t: f32) -> f32 {
	diff := math.mod(b - a + math.PI * 3, math.PI * 2) - math.PI
	return a + diff * t
}

// forward direction from yaw/pitch (yaw 0 = -Z, radians)
dir_from_angles :: proc(yaw, pitch: f32) -> Vec3 {
	cp := math.cos(pitch)
	return Vec3{math.sin(yaw) * cp, math.sin(pitch), -math.cos(yaw) * cp}
}

flat_forward :: proc(yaw: f32) -> Vec3 {
	return Vec3{math.sin(yaw), 0, -math.cos(yaw)}
}

flat_right :: proc(yaw: f32) -> Vec3 {
	return Vec3{math.cos(yaw), 0, math.sin(yaw)}
}

mat4_translate :: proc(v: Vec3) -> Mat4 {
	return linalg.matrix4_translate_f32(v)
}

mat4_scale :: proc(v: Vec3) -> Mat4 {
	return linalg.matrix4_scale_f32(v)
}

mat4_rotate :: proc(axis: Vec3, angle: f32) -> Mat4 {
	return linalg.matrix4_rotate_f32(angle, axis)
}

mat4_persp :: proc(fov_deg, aspect, near, far: f32) -> Mat4 {
	return linalg.matrix4_perspective_f32(fov_deg * DEG2RAD, aspect, near, far)
}

mat4_lookat :: proc(eye, center, up: Vec3) -> Mat4 {
	return linalg.matrix4_look_at_f32(eye, center, up)
}

// model matrix: translate * yaw * pitch * scale
mat4_trs :: proc(pos: Vec3, yaw, pitch: f32, scale: Vec3) -> Mat4 {
	m := mat4_translate(pos)
	if yaw != 0 do m = m * mat4_rotate({0, 1, 0}, -yaw)
	if pitch != 0 do m = m * mat4_rotate({1, 0, 0}, pitch)
	return m * mat4_scale(scale)
}

// orient a unit cube into a beam from a to b with given thickness
mat4_beam :: proc(a, b: Vec3, thickness: f32) -> Mat4 {
	d := b - a
	l := vlen(d)
	if l < 0.0001 do return mat4_translate(a) * mat4_scale({thickness, thickness, thickness})
	z := d / l
	up := Vec3{0, 1, 0}
	if abs(vdot(z, up)) > 0.99 do up = Vec3{1, 0, 0}
	x := vnorm(vcross(up, z))
	y := vcross(z, x)
	mid := (a + b) * 0.5
	m: Mat4 = 1
	m[0] = Vec4{x.x * thickness, x.y * thickness, x.z * thickness, 0}
	m[1] = Vec4{y.x * thickness, y.y * thickness, y.z * thickness, 0}
	m[2] = Vec4{z.x * l, z.y * l, z.z * l, 0}
	m[3] = Vec4{mid.x, mid.y, mid.z, 1}
	return m
}

AABB :: struct {
	min, max: Vec3,
}

aabb_center :: proc(b: AABB) -> Vec3 {
	return (b.min + b.max) * 0.5
}

aabb_half :: proc(b: AABB) -> Vec3 {
	return (b.max - b.min) * 0.5
}

aabb_overlap :: proc(a, b: AABB) -> bool {
	return a.min.x < b.max.x && a.max.x > b.min.x &&
	       a.min.y < b.max.y && a.max.y > b.min.y &&
	       a.min.z < b.max.z && a.max.z > b.min.z
}

// slab raycast; returns hit, entry distance, surface normal
ray_aabb :: proc(origin, dir: Vec3, b: AABB, max_t: f32) -> (hit: bool, t: f32, normal: Vec3) {
	tmin := f32(0)
	tmax := max_t
	normal = Vec3{0, 1, 0}
	axis := -1
	sign := f32(0)
	for i in 0 ..< 3 {
		if abs(dir[i]) < 1e-8 {
			if origin[i] < b.min[i] || origin[i] > b.max[i] do return false, 0, normal
			continue
		}
		inv := 1.0 / dir[i]
		t1 := (b.min[i] - origin[i]) * inv
		t2 := (b.max[i] - origin[i]) * inv
		s := f32(-1)
		if t1 > t2 {
			t1, t2 = t2, t1
			s = 1
		}
		if t1 > tmin {
			tmin = t1
			axis = i
			sign = s
		}
		tmax = min(tmax, t2)
		if tmin > tmax do return false, 0, normal
	}
	if axis >= 0 {
		normal = Vec3{}
		normal[axis] = sign
	}
	return true, tmin, normal
}

// tiny deterministic PRNG for world generation
Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state ~= r.state << 13
	r.state ~= r.state >> 7
	r.state ~= r.state << 17
	return r.state
}

rng_f32 :: proc(r: ^Rng) -> f32 {
	return f32(rng_next(r) & 0xFFFFFF) / f32(0xFFFFFF)
}

rng_range :: proc(r: ^Rng, lo, hi: f32) -> f32 {
	return lo + (hi - lo) * rng_f32(r)
}
