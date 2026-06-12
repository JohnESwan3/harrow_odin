package main

import "core:math"
import "core:os"

// Two-layer voxel world:
//
//   TERRAIN  — signed density field at 0.125 m cells (TVOX). Meshed with
//              surface nets, so hills are round and craters are smooth while
//              destruction stays per-voxel. Procedural base costs nothing;
//              only edited 32^3 density chunks (4 m) materialize.
//
//   STRUCTURES — blocky material grid at 0.25 m cells (SVOX), greedy-meshed.
//              Buildings are rectilinear, so flat faces are the correct look;
//              the coarser grid costs nothing since collision and raycasts
//              union both layers.
//
// Every destruction event is a compact op {pos, radius, power}. A voxel only
// breaks if power >= its material's toughness. Ops replicate over the network
// and persist as an append-only log (world.sav).

TVOX :: 0.125 // terrain cell size (m)
TVOX_INV :: 8.0
SVOX :: 0.25 // structure cell size (m)
SVOX_INV :: 4.0
CHUNK_N :: 32
TCHUNK_M :: f32(CHUNK_N) * TVOX // 4 m terrain density chunks
SCHUNK_M :: f32(CHUNK_N) * SVOX // 8 m structure chunks
WORLD_H :: 64.0 // world height (m)
WORLD_HALF_M :: 1024.0 // playable area 2048 x 2048 m

Material :: enum u8 {
	Air,
	Grass,
	Dirt,
	Rock,
	Sand,
	Concrete,
	Concrete_Dark,
	Metal,
	Wood,
	Bedrock,
}

MAT_COLORS := [Material][4]u8 {
	.Air           = {0, 0, 0, 0},
	.Grass         = {88, 118, 48, 255},
	.Dirt          = {118, 80, 46, 255},
	.Rock          = {104, 100, 94, 255},
	.Sand          = {178, 152, 96, 255},
	.Concrete      = {128, 124, 114, 255},
	.Concrete_Dark = {84, 84, 82, 255},
	.Metal         = {74, 90, 104, 255},
	.Wood          = {118, 76, 42, 255},
	.Bedrock       = {42, 42, 44, 255},
}

// material resistance. Damage is proportional: carve radius scales with
// power/toughness, so every weapon leaves a mark on everything but bedrock —
// tough materials just erode in smaller bites.
MAT_TOUGHNESS := [Material]f32 {
	.Air           = 0,
	.Grass         = 1.0,
	.Dirt          = 1.0,
	.Sand          = 0.8,
	.Wood          = 1.6,
	.Rock          = 2.8,
	.Concrete      = 3.2,
	.Concrete_Dark = 3.2,
	.Metal         = 4.5,
	.Bedrock       = 1e9,
}

// effective carve radius after material resistance; 0 = immune
carve_radius_for :: proc(r, power: f32, mat: Material) -> f32 {
	ratio := power / MAT_TOUGHNESS[mat]
	if ratio < 0.15 do return 0
	if ratio >= 1 do return r
	// weak-vs-tough still chips at least a small bite
	return max(r * ratio, 0.15)
}

Chunk_Key :: [3]i32
Tile_Key :: [2]i32 // terrain mesh tiles are full-height columns

Stamp :: struct {
	min, max: [3]i32, // structure-grid voxel coords
	mat:      Material,
}

Density_Chunk :: [CHUNK_N * CHUNK_N * CHUNK_N]f32

voxw: struct {
	// terrain density edits (4 m chunks, 0.125 m cells)
	tedits:       map[Chunk_Key]^Density_Chunk,
	// structure material edits (8 m chunks, 0.25 m cells)
	sedits:       map[Chunk_Key]^[CHUNK_N * CHUNK_N * CHUNK_N]u8,
	stamps:       [dynamic]Stamp,
	op_log:       [dynamic]Voxel_Op,
	dirty_tiles:  map[Tile_Key]bool, // terrain mesh tiles
	dirty_chunks: map[Chunk_Key]bool, // structure mesh chunks
	spawns:       [dynamic]Vec3,
}

// ---- procedural terrain -------------------------------------------------------

vhash :: proc(x, z: i32) -> f32 {
	h := u32(x) * 374761393 + u32(z) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	return f32(h & 0xFFFFFF) / f32(0xFFFFFF)
}

value_noise :: proc(x, z: f32) -> f32 {
	xi := i32(math.floor(x))
	zi := i32(math.floor(z))
	fx := x - math.floor(x)
	fz := z - math.floor(z)
	fx = fx * fx * (3 - 2 * fx)
	fz = fz * fz * (3 - 2 * fz)
	a := vhash(xi, zi)
	b := vhash(xi + 1, zi)
	c := vhash(xi, zi + 1)
	d := vhash(xi + 1, zi + 1)
	return lerp(lerp(a, b, fx), lerp(c, d, fx), fz)
}

// terrain height in meters at world xz (meters); smooth by construction
terrain_height :: proc(x, z: f32) -> f32 {
	h := f32(7.0)
	h += value_noise(x * 0.008, z * 0.008) * 26.0
	h += value_noise(x * 0.03, z * 0.03) * 6.0
	h += value_noise(x * 0.11, z * 0.11) * 1.2
	d := math.sqrt(x * x + z * z)
	flat := f32(14.0)
	if d < 60 {
		t := clamp((d - 30) / 30.0, 0, 1)
		t = t * t * (3 - 2 * t)
		h = lerp(flat, h, t)
	}
	return h
}

// terrain material by depth below the (original) surface
terrain_material :: proc(p: Vec3) -> Material {
	if p.y < 0.6 do return .Bedrock
	h := terrain_height(p.x, p.z)
	depth := h - p.y
	if depth < 0.45 {
		if h > 30 do return .Rock
		if h < 9 do return .Sand
		return .Grass
	}
	if depth < 2.4 do return .Dirt
	return .Rock
}

// signed density: > 0 inside terrain, smooth across the surface
terrain_density_procedural :: proc(p: Vec3) -> f32 {
	return terrain_height(p.x, p.z) - p.y
}

tchunk_key_of :: proc(cx, cy, cz: i32) -> Chunk_Key {
	return {cx >> 5, cy >> 5, cz >> 5}
}

cell_index :: proc(cx, cy, cz: i32) -> int {
	return(
		int(cy & (CHUNK_N - 1)) * CHUNK_N * CHUNK_N +
		int(cz & (CHUNK_N - 1)) * CHUNK_N +
		int(cx & (CHUNK_N - 1)) \
	)
}

// terrain density at fine-grid integer cell corner
terrain_density_at :: proc(cx, cy, cz: i32) -> f32 {
	p := Vec3{f32(cx) * TVOX, f32(cy) * TVOX, f32(cz) * TVOX}
	if p.y <= 0.25 do return 1.0 // bedrock floor
	key := tchunk_key_of(cx, cy, cz)
	if arr, ok := voxw.tedits[key]; ok {
		return arr[cell_index(cx, cy, cz)]
	}
	return terrain_density_procedural(p)
}

terrain_solid_at :: proc(p: Vec3) -> bool {
	return(
		terrain_density_at(
			i32(math.floor(p.x * TVOX_INV)),
			i32(math.floor(p.y * TVOX_INV)),
			i32(math.floor(p.z * TVOX_INV)),
		) >
		0 \
	)
}

// ---- structures ----------------------------------------------------------------

schunk_key_of :: proc(vx, vy, vz: i32) -> Chunk_Key {
	return {vx >> 5, vy >> 5, vz >> 5}
}

structure_procedural_at :: proc(vx, vy, vz: i32) -> Material {
	mat: Material = .Air
	for s in voxw.stamps {
		if vx >= s.min.x &&
		   vx < s.max.x &&
		   vy >= s.min.y &&
		   vy < s.max.y &&
		   vz >= s.min.z &&
		   vz < s.max.z {
			mat = s.mat
		}
	}
	return mat
}

structure_at :: proc(vx, vy, vz: i32) -> Material {
	key := schunk_key_of(vx, vy, vz)
	if arr, ok := voxw.sedits[key]; ok {
		return Material(arr[cell_index(vx, vy, vz)])
	}
	return structure_procedural_at(vx, vy, vz)
}

structure_solid_at :: proc(p: Vec3) -> bool {
	return(
		structure_at(
			i32(math.floor(p.x * SVOX_INV)),
			i32(math.floor(p.y * SVOX_INV)),
			i32(math.floor(p.z * SVOX_INV)),
		) !=
		.Air \
	)
}

// ---- union queries -------------------------------------------------------------

solid_at_world :: proc(p: Vec3) -> bool {
	return terrain_solid_at(p) || structure_solid_at(p)
}

// material at a hit point (for particles/durability); structures win
material_at_point :: proc(p: Vec3) -> Material {
	m := structure_at(
		i32(math.floor(p.x * SVOX_INV)),
		i32(math.floor(p.y * SVOX_INV)),
		i32(math.floor(p.z * SVOX_INV)),
	)
	if m != .Air do return m
	return terrain_material(p)
}

material_at_hit :: proc(p: Vec3, n: Vec3) -> Material {
	return material_at_point(p - n * (TVOX * 0.75))
}

// ---- edits ---------------------------------------------------------------------

materialize_tchunk :: proc(key: Chunk_Key) -> ^Density_Chunk {
	if arr, ok := voxw.tedits[key]; ok do return arr
	arr := new(Density_Chunk)
	base := Vec3{f32(key.x) * TCHUNK_M, f32(key.y) * TCHUNK_M, f32(key.z) * TCHUNK_M}
	for lz in 0 ..< CHUNK_N {
		for lx in 0 ..< CHUNK_N {
			h := terrain_height(base.x + f32(lx) * TVOX, base.z + f32(lz) * TVOX)
			for ly in 0 ..< CHUNK_N {
				arr[ly * CHUNK_N * CHUNK_N + lz * CHUNK_N + lx] = h - (base.y + f32(ly) * TVOX)
			}
		}
	}
	voxw.tedits[key] = arr
	return arr
}

materialize_schunk :: proc(key: Chunk_Key) -> ^[CHUNK_N * CHUNK_N * CHUNK_N]u8 {
	if arr, ok := voxw.sedits[key]; ok do return arr
	arr := new([CHUNK_N * CHUNK_N * CHUNK_N]u8)
	base := [3]i32{key.x * CHUNK_N, key.y * CHUNK_N, key.z * CHUNK_N}
	cmin := base
	cmax := [3]i32{base.x + CHUNK_N, base.y + CHUNK_N, base.z + CHUNK_N}
	for s in voxw.stamps {
		if s.max.x <= cmin.x ||
		   s.min.x >= cmax.x ||
		   s.max.y <= cmin.y ||
		   s.min.y >= cmax.y ||
		   s.max.z <= cmin.z ||
		   s.min.z >= cmax.z {
			continue
		}
		for vy in max(s.min.y, cmin.y) ..< min(s.max.y, cmax.y) {
			for vz in max(s.min.z, cmin.z) ..< min(s.max.z, cmax.z) {
				for vx in max(s.min.x, cmin.x) ..< min(s.max.x, cmax.x) {
					arr[cell_index(vx, vy, vz)] = u8(s.mat)
				}
			}
		}
	}
	voxw.sedits[key] = arr
	return arr
}

tile_of_cell :: proc(cx, cz: i32) -> Tile_Key {
	return {cx >> 5, cz >> 5}
}

mark_tile_dirty_around :: proc(cx, cz: i32) {
	// a cell edit can move vertices in adjacent tiles' margin cells
	t := tile_of_cell(cx, cz)
	voxw.dirty_tiles[t] = true
	// the render mesh samples 2 fine cells into neighbor tiles
	M :: 2
	lx := cx & (CHUNK_N - 1)
	lz := cz & (CHUNK_N - 1)
	if lx <= M do voxw.dirty_tiles[{t.x - 1, t.y}] = true
	if lx >= CHUNK_N - 1 - M do voxw.dirty_tiles[{t.x + 1, t.y}] = true
	if lz <= M do voxw.dirty_tiles[{t.x, t.y - 1}] = true
	if lz >= CHUNK_N - 1 - M do voxw.dirty_tiles[{t.x, t.y + 1}] = true
	if lx <= M && lz <= M do voxw.dirty_tiles[{t.x - 1, t.y - 1}] = true
	if lx >= CHUNK_N - 1 - M && lz >= CHUNK_N - 1 - M do voxw.dirty_tiles[{t.x + 1, t.y + 1}] = true
	if lx <= M && lz >= CHUNK_N - 1 - M do voxw.dirty_tiles[{t.x - 1, t.y + 1}] = true
	if lx >= CHUNK_N - 1 - M && lz <= M do voxw.dirty_tiles[{t.x + 1, t.y - 1}] = true
}

// carve a sphere; per-cell material toughness gates against op power
voxel_carve :: proc(center: Vec3, r: f32, power: f32) {
	// terrain: subtract a smooth sphere from the density field
	t0 := [3]i32 {
		i32(math.floor((center.x - r - TVOX) * TVOX_INV)),
		i32(math.floor((center.y - r - TVOX) * TVOX_INV)),
		i32(math.floor((center.z - r - TVOX) * TVOX_INV)),
	}
	t1 := [3]i32 {
		i32(math.floor((center.x + r + TVOX) * TVOX_INV)),
		i32(math.floor((center.y + r + TVOX) * TVOX_INV)),
		i32(math.floor((center.z + r + TVOX) * TVOX_INV)),
	}
	for cy in t0.y ..= t1.y {
		py := f32(cy) * TVOX
		if py <= 0.5 do continue // bedrock floor
		for cz in t0.z ..= t1.z {
			for cx in t0.x ..= t1.x {
				p := Vec3{f32(cx) * TVOX, py, f32(cz) * TVOX}
				dist := vlen(p - center)
				r_eff := carve_radius_for(r, power, terrain_material(p))
				if r_eff <= 0 do continue
				carve_d := dist - r_eff // negative inside the sphere
				if carve_d >= TVOX do continue
				key := tchunk_key_of(cx, cy, cz)
				arr := materialize_tchunk(key)
				idx := cell_index(cx, cy, cz)
				if arr[idx] > carve_d {
					arr[idx] = carve_d
					mark_tile_dirty_around(cx, cz)
				}
			}
		}
	}

	// structures: clear cells inside the sphere
	s0 := [3]i32 {
		i32(math.floor((center.x - r) * SVOX_INV)),
		i32(math.floor((center.y - r) * SVOX_INV)),
		i32(math.floor((center.z - r) * SVOX_INV)),
	}
	s1 := [3]i32 {
		i32(math.floor((center.x + r) * SVOX_INV)),
		i32(math.floor((center.y + r) * SVOX_INV)),
		i32(math.floor((center.z + r) * SVOX_INV)),
	}
	r2 := r * r
	for vy in s0.y ..= s1.y {
		for vz in s0.z ..= s1.z {
			for vx in s0.x ..= s1.x {
				c := Vec3{(f32(vx) + 0.5) * SVOX, (f32(vy) + 0.5) * SVOX, (f32(vz) + 0.5) * SVOX}
				d := c - center
				if d.x * d.x + d.y * d.y + d.z * d.z > r2 do continue
				cur := structure_at(vx, vy, vz)
				if cur == .Air do continue
				r_eff := carve_radius_for(r, power, cur)
				// the directly-hit cell always breaks if the material yields at all
				if r_eff <= 0 do continue
				d2 := d.x * d.x + d.y * d.y + d.z * d.z
				if d2 > r_eff * r_eff && d2 > SVOX * SVOX * 0.6 do continue
				key := schunk_key_of(vx, vy, vz)
				arr := materialize_schunk(key)
				arr[cell_index(vx, vy, vz)] = u8(Material.Air)
				voxw.dirty_chunks[key] = true
				lx := vx & (CHUNK_N - 1)
				ly := vy & (CHUNK_N - 1)
				lz := vz & (CHUNK_N - 1)
				if lx == 0 do voxw.dirty_chunks[{key.x - 1, key.y, key.z}] = true
				if lx == CHUNK_N - 1 do voxw.dirty_chunks[{key.x + 1, key.y, key.z}] = true
				if ly == 0 do voxw.dirty_chunks[{key.x, key.y - 1, key.z}] = true
				if ly == CHUNK_N - 1 do voxw.dirty_chunks[{key.x, key.y + 1, key.z}] = true
				if lz == 0 do voxw.dirty_chunks[{key.x, key.y, key.z - 1}] = true
				if lz == CHUNK_N - 1 do voxw.dirty_chunks[{key.x, key.y, key.z + 1}] = true
			}
		}
	}
}

voxel_apply_op :: proc(op: Voxel_Op, record: bool) {
	voxel_carve(op.pos, op.r, op.power)
	if record do append(&voxw.op_log, op)
}

// ---- persistence (versioned op log) ---------------------------------------------

WORLD_SAVE :: "world.sav"
SAVE_MAGIC :: u32(0x48525731) // "HRW1"

voxel_save :: proc() {
	if len(voxw.op_log) == 0 do return
	total := size_of(u32) + len(voxw.op_log) * size_of(Voxel_Op)
	bytes := make([]u8, total, context.temp_allocator)
	(^u32)(&bytes[0])^ = SAVE_MAGIC
	for op, i in voxw.op_log {
		(^Voxel_Op)(&bytes[size_of(u32) + i * size_of(Voxel_Op)])^ = op
	}
	_ = os.write_entire_file(WORLD_SAVE, bytes)
}

voxel_load :: proc() {
	data, err := os.read_entire_file_from_path(WORLD_SAVE, context.temp_allocator)
	if err != nil do return
	if len(data) < size_of(u32) || (^u32)(&data[0])^ != SAVE_MAGIC do return
	count := (len(data) - size_of(u32)) / size_of(Voxel_Op)
	for i in 0 ..< count {
		op := (^Voxel_Op)(&data[size_of(u32) + i * size_of(Voxel_Op)])^
		voxel_apply_op(op, true)
	}
}

// ---- world generation -----------------------------------------------------------

stamp_box_m :: proc(min, max: Vec3, mat: Material) {
	append(
		&voxw.stamps,
		Stamp {
			min = {i32(min.x * SVOX_INV), i32(min.y * SVOX_INV), i32(min.z * SVOX_INV)},
			max = {i32(max.x * SVOX_INV), i32(max.y * SVOX_INV), i32(max.z * SVOX_INV)},
			mat = mat,
		},
	)
}

voxel_world_init :: proc() {
	for _, arr in voxw.tedits do free(arr)
	clear(&voxw.tedits)
	for _, arr in voxw.sedits do free(arr)
	clear(&voxw.sedits)
	clear(&voxw.stamps)
	clear(&voxw.op_log)
	clear(&voxw.dirty_tiles)
	clear(&voxw.dirty_chunks)
	clear(&voxw.spawns)

	G :: 14.0 // plateau ground level

	wall :: proc(min, max: Vec3) {stamp_box_m(min, max, .Concrete)}
	wall({-12, G - 0.5, -10}, {12, G, 10})
	wall({-12, G, 9}, {-2, G + 4, 10})
	wall({2, G, 9}, {12, G + 4, 10})
	wall({-12, G, -10}, {-5, G + 4, -9})
	wall({-2, G, -10}, {2, G + 4, -9})
	wall({5, G, -10}, {12, G + 4, -9})
	wall({-12, G, -9}, {-11, G + 4, 2})
	wall({-12, G, 5}, {-11, G + 4, 9})
	wall({11, G, -9}, {12, G + 4, 2})
	wall({11, G, 5}, {12, G + 4, 9})
	stamp_box_m({-12, G + 4, -10}, {12, G + 4.5, 10}, .Concrete_Dark)
	stamp_box_m({-5, G, -1}, {-2.5, G + 1.25, 0.25}, .Metal)
	stamp_box_m({3, G, -4}, {4.5, G + 1.25, -1}, .Metal)

	// stairs to the roof, 0.25 m risers
	for i in 0 ..< 18 {
		fi := f32(i)
		stamp_box_m({12.0 + fi * 0.5, G, -2}, {12.5 + fi * 0.5, G + 4.5 - fi * 0.25, 2}, .Concrete)
	}

	tower :: proc(cx, cz: f32) {
		gh := terrain_height(cx, cz) + 0.5
		stamp_box_m({cx - 2.5, gh - 2, cz - 2.5}, {cx + 2.5, gh, cz + 2.5}, .Concrete_Dark)
		for sx in ([2]f32{-2, 2}) {
			for sz in ([2]f32{-2, 2}) {
				stamp_box_m(
					{cx + sx - 0.25, gh, cz + sz - 0.25},
					{cx + sx + 0.25, gh + 5, cz + sz + 0.25},
					.Metal,
				)
			}
		}
		stamp_box_m({cx - 2.75, gh + 5, cz - 2.75}, {cx + 2.75, gh + 5.5, cz + 2.75}, .Metal)
		stamp_box_m({cx - 2.75, gh + 5.5, cz - 2.75}, {cx + 2.75, gh + 6.5, cz - 2.5}, .Metal)
		stamp_box_m({cx - 2.75, gh + 5.5, cz + 2.5}, {cx + 2.75, gh + 6.5, cz + 2.75}, .Metal)
		stamp_box_m({cx + 3.0, gh, cz - 0.75}, {cx + 4.5, gh + 1.25, cz + 0.75}, .Wood)
		stamp_box_m({cx + 4.5, gh, cz - 0.75}, {cx + 6.0, gh + 2.5, cz + 0.75}, .Wood)
	}
	tower(-52, -52)
	tower(52, -52)
	tower(-52, 52)
	tower(52, 52)

	rng := Rng {
		state = 0xDEAD_50_11,
	}
	for _ in 0 ..< 140 {
		x := rng_range(&rng, -300, 300)
		z := rng_range(&rng, -300, 300)
		if abs(x) < 18 && abs(z) < 16 do continue
		gh := terrain_height(x, z)
		roll := rng_f32(&rng)
		if roll < 0.45 {
			s := rng_range(&rng, 0.75, 2.0)
			stamp_box_m({x - s / 2, gh - 0.5, z - s / 2}, {x + s / 2, gh + s, z + s / 2}, .Wood)
		} else if roll < 0.7 {
			w := rng_range(&rng, 2, 6)
			h := rng_range(&rng, 1, 3)
			stamp_box_m({x, gh - 0.5, z}, {x + w, gh + h, z + 0.5}, .Concrete_Dark)
		} else {
			th := rng_range(&rng, 3, 7)
			stamp_box_m({x - 0.25, gh - 0.5, z - 0.25}, {x + 0.25, gh + th, z + 0.25}, .Wood)
		}
	}

	for i in 0 ..< 8 {
		a := f32(i) * (math.PI * 2.0 / 8.0)
		x := math.cos(a) * 26
		z := math.sin(a) * 26
		append(&voxw.spawns, Vec3{x, terrain_height(x, z) + 1.2, z})
	}

	voxel_load()
}

// ---- collision -----------------------------------------------------------------

STEP_HEIGHT :: 0.45

// any solid (terrain or structure) inside box; also reports the solid extent
solid_in_box :: proc(bmin, bmax: Vec3) -> (found: bool, smin, smax: Vec3) {
	smin = {max(f32), max(f32), max(f32)}
	smax = {min(f32), min(f32), min(f32)}
	// fine grid sampling at terrain resolution covers both layers
	v0 := [3]i32 {
		i32(math.floor(bmin.x * TVOX_INV)),
		i32(math.floor(bmin.y * TVOX_INV)),
		i32(math.floor(bmin.z * TVOX_INV)),
	}
	v1 := [3]i32 {
		i32(math.floor(bmax.x * TVOX_INV)),
		i32(math.floor(bmax.y * TVOX_INV)),
		i32(math.floor(bmax.z * TVOX_INV)),
	}
	for vy in v0.y ..= v1.y {
		for vz in v0.z ..= v1.z {
			for vx in v0.x ..= v1.x {
				p := Vec3{(f32(vx) + 0.5) * TVOX, (f32(vy) + 0.5) * TVOX, (f32(vz) + 0.5) * TVOX}
				if terrain_density_at(vx, vy, vz) > 0 || structure_solid_at(p) {
					found = true
					smin.x = min(smin.x, f32(vx) * TVOX)
					smin.y = min(smin.y, f32(vy) * TVOX)
					smin.z = min(smin.z, f32(vz) * TVOX)
					smax.x = max(smax.x, f32(vx + 1) * TVOX)
					smax.y = max(smax.y, f32(vy + 1) * TVOX)
					smax.z = max(smax.z, f32(vz + 1) * TVOX)
				}
			}
		}
	}
	return
}

aabb_clear :: proc(center, half: Vec3) -> bool {
	found, _, _ := solid_in_box(center - half, center + half)
	return !found
}

world_move :: proc(
	pos: Vec3,
	half: Vec3,
	delta: Vec3,
	allow_step := false,
) -> (
	out: Vec3,
	on_ground: bool,
	hit_ceiling: bool,
) {
	EPS :: 0.001
	out = pos
	axes := [3]int{0, 2, 1}
	for axis in axes {
		d := delta[axis]
		if d == 0 do continue
		out[axis] += d
		found, smin, smax := solid_in_box(out - half, out + half)
		if found && allow_step && axis != 1 {
			rise := smax.y - (out.y - half.y)
			if rise > 0 && rise <= STEP_HEIGHT {
				stepped := out
				stepped.y += rise + EPS
				if aabb_clear(stepped, half) {
					out = stepped
					continue
				}
			}
		}
		if found {
			if d > 0 {
				out[axis] = smin[axis] - half[axis] - EPS
				if axis == 1 do hit_ceiling = true
			} else {
				out[axis] = smax[axis] + half[axis] + EPS
				if axis == 1 do on_ground = true
			}
		}
	}
	return
}

// DDA raycast on the fine terrain grid; checks both layers per cell
world_raycast :: proc(origin, dir: Vec3, max_t: f32) -> (hit: bool, t: f32, normal: Vec3) {
	v := [3]i32 {
		i32(math.floor(origin.x * TVOX_INV)),
		i32(math.floor(origin.y * TVOX_INV)),
		i32(math.floor(origin.z * TVOX_INV)),
	}
	step: [3]i32
	t_max, t_delta: [3]f32
	for i in 0 ..< 3 {
		if dir[i] > 1e-8 {
			step[i] = 1
			t_max[i] = ((f32(v[i]) + 1) * TVOX - origin[i]) / dir[i]
			t_delta[i] = TVOX / dir[i]
		} else if dir[i] < -1e-8 {
			step[i] = -1
			t_max[i] = (f32(v[i]) * TVOX - origin[i]) / dir[i]
			t_delta[i] = -TVOX / dir[i]
		} else {
			step[i] = 0
			t_max[i] = max(f32)
			t_delta[i] = max(f32)
		}
	}
	cell_solid :: proc(v: [3]i32) -> bool {
		if terrain_density_at(v.x, v.y, v.z) > 0 do return true
		p := Vec3{(f32(v.x) + 0.5) * TVOX, (f32(v.y) + 0.5) * TVOX, (f32(v.z) + 0.5) * TVOX}
		return structure_solid_at(p)
	}
	if cell_solid(v) do return true, 0, {0, 1, 0}
	t = 0
	for t < max_t {
		axis := 0
		if t_max[1] < t_max[0] do axis = 1
		if t_max[2] < t_max[axis] do axis = 2
		t = t_max[axis]
		if t > max_t do break
		v[axis] += step[axis]
		t_max[axis] += t_delta[axis]
		if cell_solid(v) {
			normal = {}
			normal[axis] = -f32(step[axis])
			return true, t, normal
		}
	}
	return false, max_t, {0, 1, 0}
}
