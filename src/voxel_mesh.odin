package main

import "core:math"
import "core:slice"
import "core:time"
import sg "../sokol/gfx"

// Meshing + streaming for the two world layers.
//
//   TERRAIN: surface nets over the 0.125 m density field, meshed in 4 m
//   full-height column tiles. Vertices sit on the isosurface with gradient
//   normals, so hills are round and craters are smooth.
//
//   STRUCTURES: greedy blocky meshing of the 0.25 m material grid in 8 m
//   chunks (unchanged look - buildings are rectilinear).
//
// Both produce the same vertex layout and draw with one pipeline.

VIEW_RADIUS_M :: f32(128.0) // fallback; runtime value is game.settings.draw_dist

view_radius :: proc() -> f32 {
	if game.settings.draw_dist > 0 { return game.settings.draw_dist }
	return VIEW_RADIUS_M
}
MESH_BUDGET_MS :: 5.0
EVICT_MARGIN_M :: 24.0

Voxel_Vertex :: struct {
	pos:    [3]f32,
	normal: [4]i8, // BYTE4N
	color:  [4]u8, // UBYTE4N
}

TBand :: [2]i32 // inclusive mesh-row range

Mesh_Buffers :: struct {
	vbuf, ibuf:   sg.Buffer,
	num_idx:      int,
	bound_center: Vec3,
	bound_r:      f32,
}

vmesh: struct {
	tiles:        map[Tile_Key]Mesh_Buffers, // terrain column tiles (4 m)
	chunks:       map[Chunk_Key]Mesh_Buffers, // structure chunks (8 m)
	tile_queue:   [dynamic]Tile_Key,
	tile_queued:  map[Tile_Key]bool,
	chunk_queue:  [dynamic]Chunk_Key,
	chunk_queued: map[Chunk_Key]bool,
	scan_timer:   f32,
	last_center:  Tile_Key,
	evict_timer:  f32,
	chunks_drawn: int,
	tris_drawn:   int,
}

mesh_destroy :: proc(m: ^Mesh_Buffers) {
	if m.vbuf.id != 0 do sg.destroy_buffer(m.vbuf)
	if m.ibuf.id != 0 do sg.destroy_buffer(m.ibuf)
	m^ = {}
}

mesh_upload :: proc(verts: []Voxel_Vertex, indices: []u32) -> (m: Mesh_Buffers) {
	if len(indices) == 0 do return
	m.vbuf = sg.make_buffer({
		data = {ptr = raw_data(verts), size = uint(len(verts) * size_of(Voxel_Vertex))},
	})
	m.ibuf = sg.make_buffer({
		usage = {index_buffer = true},
		data = {ptr = raw_data(indices), size = uint(len(indices) * size_of(u32))},
	})
	m.num_idx = len(indices)
	return
}

// ---- terrain: surface nets ------------------------------------------------------

// The density/destruction field is 0.125 m, but the render mesh samples it at
// 0.25 m: the isosurface interpolation keeps everything smooth, at a quarter
// of the triangle count.
MESH_STRIDE :: 2
MCELL :: TVOX * MESH_STRIDE
MESH_CELLS :: CHUNK_N / MESH_STRIDE // mesh cells per 4 m tile axis

// sample grid: corners -1..MESH_CELLS in local x/z, cells -1..MESH_CELLS-1
SN_S :: MESH_CELLS + 2 // samples per axis (x/z)
SN_C :: MESH_CELLS + 1 // cells per axis (x/z)

terrain_vertex_color :: proc(p: Vec3, n: Vec3) -> [4]u8 {
	probe := p - n * 0.1
	mat_a := terrain_material(probe)

	// Find the nearest material-boundary depth and blend toward the other side.
	// Boundaries: 0.45 m (surface→dirt) and 2.4 m (dirt→rock).
	// Blend zone is ±BLEND_R around each boundary; flat surfaces (depth ≈ 0) are unaffected.
	SURF_BD :: f32(0.45)
	DIRT_BD :: f32(2.40)
	BLEND_R :: f32(0.38)

	h     := terrain_height(probe.x, probe.z)
	depth := h - probe.y

	best_dist := f32(999)
	sec_mat   := mat_a
	boundaries := [2]f32{SURF_BD, DIRT_BD}
	for bd in boundaries {
		d := abs(depth - bd)
		if d < BLEND_R && d < best_dist {
			best_dist = d
			// Sample 0.2 m on the opposite side of the boundary to get the other material.
			other_y := h - (bd + (depth > bd ? f32(-0.2) : f32(0.2)))
			sec_mat  = terrain_material({probe.x, other_y, probe.z})
		}
	}

	blend_w: u8 = 0
	if sec_mat != mat_a {
		t := 1.0 - best_dist / BLEND_R
		blend_w = u8(t * 127.5) // max 0.5 blend at boundary centre
	}

	// r = secondary material, g = blend weight, b = unused, a = primary material
	return {u8(sec_mat), blend_w, 0, u8(mat_a)}
}

tile_remesh :: proc(key: Tile_Key) {
	if m, ok := &vmesh.tiles[key]; ok {
		mesh_destroy(m)
	}

	base_cx := key.x * CHUNK_N // fine-grid cell origin
	base_cz := key.y * CHUNK_N

	// heights for every sample column (mesh-cell stride over the fine grid)
	heights: [SN_S * SN_S]f32
	hmin := f32(1e9)
	hmax := f32(-1e9)
	for sz in 0 ..< SN_S {
		for sx in 0 ..< SN_S {
			h := terrain_height(
				f32(base_cx + (i32(sx) - 1) * MESH_STRIDE) * TVOX,
				f32(base_cz + (i32(sz) - 1) * MESH_STRIDE) * TVOX,
			)
			heights[sz * SN_S + sx] = h
			hmin = min(hmin, h)
			hmax = max(hmax, h)
		}
	}

	// vertical bands (mesh rows): the surface skin, any cave systems found by
	// a coarse probe, and edited chunks. Meshing only active bands keeps deep
	// underground free while still rendering cave walls.
	bands := make([dynamic]TBand, context.temp_allocator)
	max_row := i32(WORLD_H / MCELL) - 1
	append(&bands, TBand{i32(math.floor((hmin - 0.6) / MCELL)), i32(math.ceil((hmax + 0.6) / MCELL))})

	probe_idx := [3]int{1, SN_S / 2, SN_S - 2}
	for szc in probe_idx {
		for sxc in probe_idx {
			h := heights[szc * SN_S + sxc]
			ppx := f32(base_cx + (i32(sxc) - 1) * MESH_STRIDE) * TVOX
			ppz := f32(base_cz + (i32(szc) - 1) * MESH_STRIDE) * TVOX
			for y := f32(2.0); y < h + 0.5; y += 0.75 {
				if cave_sdf(Vec3{ppx, y, ppz}, h - y) < 1.2 {
					r := i32(y / MCELL)
					append(&bands, TBand{r - 4, r + 4})
				}
			}
		}
	}

	has_edits := false
	for ekey, _ in voxw.tedits {
		if ekey.x >= key.x - 1 && ekey.x <= key.x + 1 && ekey.z >= key.y - 1 && ekey.z <= key.y + 1 {
			has_edits = true
			append(&bands, TBand{ekey.y * CHUNK_N / MESH_STRIDE - 1, (ekey.y + 1) * CHUNK_N / MESH_STRIDE + 1})
		}
	}

	for &b in bands {
		b[0] = max(b[0], 1)
		b[1] = min(b[1], max_row)
	}
	slice.sort_by(bands[:], proc(a, b: TBand) -> bool { return a[0] < b[0] })
	merged := make([dynamic]TBand, context.temp_allocator)
	for b in bands {
		if b[1] < b[0] do continue
		if len(merged) > 0 && b[0] <= merged[len(merged) - 1][1] + 2 {
			merged[len(merged) - 1][1] = max(merged[len(merged) - 1][1], b[1])
		} else {
			append(&merged, b)
		}
	}

	verts := make([dynamic]Voxel_Vertex, 0, 4096, context.temp_allocator)
	indices := make([dynamic]u32, 0, 8192, context.temp_allocator)
	di :: proc(sx, sy, sz, ny: int) -> int { return (sz * SN_S + sx) * ny + sy }
	vi :: proc(cx, cy, cz, ncy: int) -> int { return (cz * SN_C + cx) * ncy + cy }
	emit_quad :: proc(indices: ^[dynamic]u32, v0, v1, v2, v3: i32) {
		if v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0 do return
		append(indices, u32(v0), u32(v1), u32(v2), u32(v0), u32(v2), u32(v3))
	}

	for band in merged {
	y0 := band[0]
	y1 := band[1]
	ny := int(y1 - y0 + 1)
	if ny < 2 do continue

	// density samples for this band
	ds := make([]f32, SN_S * SN_S * ny, context.temp_allocator)
	for sz in 0 ..< SN_S {
		for sx in 0 ..< SN_S {
			h := heights[sz * SN_S + sx]
			col := (sz * SN_S + sx) * ny
			px := f32(base_cx + (i32(sx) - 1) * MESH_STRIDE) * TVOX
			pz := f32(base_cz + (i32(sz) - 1) * MESH_STRIDE) * TVOX
			if !has_edits {
				for sy in 0 ..< ny {
					ds[col + sy] = density_from_h(h, Vec3{px, f32(y0 + i32(sy)) * MCELL, pz})
				}
			} else {
				cx := base_cx + (i32(sx) - 1) * MESH_STRIDE
				cz := base_cz + (i32(sz) - 1) * MESH_STRIDE
				for sy in 0 ..< ny {
					ds[col + sy] = terrain_density_at(cx, (y0 + i32(sy)) * MESH_STRIDE, cz)
				}
			}
		}
	}

	// one vertex per sign-crossing cell
	ncy := ny - 1
	vert_idx := make([]i32, SN_C * SN_C * ncy, context.temp_allocator)
	for &v in vert_idx do v = -1

	for cz in 0 ..< SN_C {
		for cx in 0 ..< SN_C {
			for cy in 0 ..< ncy {
				d: [8]f32
				d[0] = ds[di(cx, cy, cz, ny)]
				d[1] = ds[di(cx + 1, cy, cz, ny)]
				d[2] = ds[di(cx, cy + 1, cz, ny)]
				d[3] = ds[di(cx + 1, cy + 1, cz, ny)]
				d[4] = ds[di(cx, cy, cz + 1, ny)]
				d[5] = ds[di(cx + 1, cy, cz + 1, ny)]
				d[6] = ds[di(cx, cy + 1, cz + 1, ny)]
				d[7] = ds[di(cx + 1, cy + 1, cz + 1, ny)]
				solid_mask := 0
				for k in 0 ..< 8 {
					if d[k] > 0 do solid_mask |= 1 << uint(k)
				}
				if solid_mask == 0 || solid_mask == 255 do continue

				// average of edge crossings (surface nets vertex)
				EDGES := [12][2]int{
					{0, 1}, {2, 3}, {4, 5}, {6, 7}, // x edges
					{0, 2}, {1, 3}, {4, 6}, {5, 7}, // y edges
					{0, 4}, {1, 5}, {2, 6}, {3, 7}, // z edges
				}
				CORNER := [8][3]f32{
					{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0},
					{0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1},
				}
				sum: Vec3
				cnt := 0
				for e in EDGES {
					d0 := d[e[0]]
					d1 := d[e[1]]
					if (d0 > 0) == (d1 > 0) do continue
					t := d0 / (d0 - d1)
					a := CORNER[e[0]]
					b := CORNER[e[1]]
					sum += Vec3{
						a[0] + (b[0] - a[0]) * t,
						a[1] + (b[1] - a[1]) * t,
						a[2] + (b[2] - a[2]) * t,
					}
					cnt += 1
				}
				if cnt == 0 do continue
				local := sum / f32(cnt)
				pos := Vec3{
					f32(base_cx) * TVOX + (f32(cx - 1) + local.x) * MCELL,
					(f32(y0 + i32(cy)) + local.y) * MCELL,
					f32(base_cz) * TVOX + (f32(cz - 1) + local.z) * MCELL,
				}

				// gradient normal from corner differences
				gx := (d[1] + d[3] + d[5] + d[7]) - (d[0] + d[2] + d[4] + d[6])
				gy := (d[2] + d[3] + d[6] + d[7]) - (d[0] + d[1] + d[4] + d[5])
				gz := (d[4] + d[5] + d[6] + d[7]) - (d[0] + d[1] + d[2] + d[3])
				n := vnorm(Vec3{-gx, -gy, -gz})
				if n == {} do n = {0, 1, 0}

				vert_idx[vi(cx, cy, cz, ncy)] = i32(len(verts))
				append(&verts, Voxel_Vertex{
					pos    = pos,
					normal = {i8(n.x * 127), i8(n.y * 127), i8(n.z * 127), 0},
					color  = terrain_vertex_color(pos, n),
				})
			}
		}
	}

	// quads: one per sign-changing grid edge; connects the 4 adjacent cells.
	for sz in 1 ..< SN_S - 1 {
		for sx in 1 ..< SN_S - 1 {
			for sy in 0 ..< ny - 1 {
				d0 := ds[di(sx, sy, sz, ny)]
				s0 := d0 > 0

				// x-axis edge (cells vary in y,z)
				if sy > 0 {
					d1 := ds[di(sx + 1, sy, sz, ny)]
					if (d1 > 0) != s0 {
						a := vert_idx[vi(sx, sy - 1, sz - 1, ncy)]
						b := vert_idx[vi(sx, sy, sz - 1, ncy)]
						c := vert_idx[vi(sx, sy, sz, ncy)]
						e := vert_idx[vi(sx, sy - 1, sz, ncy)]
						if s0 do emit_quad(&indices, a, b, c, e)
						else do emit_quad(&indices, a, e, c, b)
					}
				}
				// y-axis edge (cells vary in x,z)
				{
					d1 := ds[di(sx, sy + 1, sz, ny)]
					if (d1 > 0) != s0 {
						a := vert_idx[vi(sx - 1, sy, sz - 1, ncy)]
						b := vert_idx[vi(sx - 1, sy, sz, ncy)]
						c := vert_idx[vi(sx, sy, sz, ncy)]
						e := vert_idx[vi(sx, sy, sz - 1, ncy)]
						if s0 do emit_quad(&indices, a, b, c, e)
						else do emit_quad(&indices, a, e, c, b)
					}
				}
				// z-axis edge (cells vary in x,y)
				if sy > 0 {
					d1 := ds[di(sx, sy, sz + 1, ny)]
					if (d1 > 0) != s0 {
						a := vert_idx[vi(sx - 1, sy - 1, sz, ncy)]
						b := vert_idx[vi(sx, sy - 1, sz, ncy)]
						c := vert_idx[vi(sx, sy, sz, ncy)]
						e := vert_idx[vi(sx - 1, sy, sz, ncy)]
						if s0 do emit_quad(&indices, a, b, c, e)
						else do emit_quad(&indices, a, e, c, b)
					}
				}
			}
		}
	}
	} // bands

	m := mesh_upload(verts[:], indices[:])
	if len(verts) > 0 {
		bmin := verts[0].pos
		bmax := verts[0].pos
		for v in verts {
			bmin.x = min(bmin.x, v.pos.x)
			bmin.y = min(bmin.y, v.pos.y)
			bmin.z = min(bmin.z, v.pos.z)
			bmax.x = max(bmax.x, v.pos.x)
			bmax.y = max(bmax.y, v.pos.y)
			bmax.z = max(bmax.z, v.pos.z)
		}
		m.bound_center = Vec3{(bmin.x + bmax.x), (bmin.y + bmax.y), (bmin.z + bmax.z)} * 0.5
		m.bound_r = vlen(Vec3{bmax.x - bmin.x, bmax.y - bmin.y, bmax.z - bmin.z}) * 0.5 + 0.1
	}
	vmesh.tiles[key] = m
}

// ---- structures: greedy blocky meshing -------------------------------------------

SNAP :: CHUNK_N + 2

structure_snapshot :: proc(key: Chunk_Key, snap: ^[SNAP * SNAP * SNAP]u8) {
	base := [3]i32{key.x * CHUNK_N - 1, key.y * CHUNK_N - 1, key.z * CHUNK_N - 1}
	si :: proc(x, y, z: int) -> int { return (y * SNAP + z) * SNAP + x }
	for i in 0 ..< SNAP * SNAP * SNAP do snap[i] = 0
	smin := base
	smax := [3]i32{base.x + SNAP, base.y + SNAP, base.z + SNAP}

	// trees: collect the few that can reach this chunk, then rasterize
	wmin := Vec3{f32(smin.x) * SVOX, f32(smin.y) * SVOX, f32(smin.z) * SVOX}
	wmax := Vec3{f32(smax.x) * SVOX, f32(smax.y) * SVOX, f32(smax.z) * SVOX}
	trees: [8]Tree
	ntrees := collect_trees(wmin, wmax, &trees)
	if ntrees > 0 {
		for y in 0 ..< SNAP {
			for z in 0 ..< SNAP {
				for x in 0 ..< SNAP {
					p := Vec3{
						(f32(smin.x + i32(x)) + 0.5) * SVOX,
						(f32(smin.y + i32(y)) + 0.5) * SVOX,
						(f32(smin.z + i32(z)) + 0.5) * SVOX,
					}
					for i in 0 ..< ntrees {
						tm := tree_material(trees[i], p)
						if tm != .Air {
							snap[si(x, y, z)] = u8(tm)
							break
						}
					}
				}
			}
		}
	}

	for s in voxw.stamps {
		if s.max.x <= smin.x || s.min.x >= smax.x ||
		   s.max.y <= smin.y || s.min.y >= smax.y ||
		   s.max.z <= smin.z || s.min.z >= smax.z {
			continue
		}
		for vy in max(s.min.y, smin.y) ..< min(s.max.y, smax.y) {
			for vz in max(s.min.z, smin.z) ..< min(s.max.z, smax.z) {
				for vx in max(s.min.x, smin.x) ..< min(s.max.x, smax.x) {
					snap[si(int(vx - base.x), int(vy - base.y), int(vz - base.z))] = u8(s.mat)
				}
			}
		}
	}
	for dy in i32(-1) ..= 1 {
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				nk := Chunk_Key{key.x + dx, key.y + dy, key.z + dz}
				arr, ok := voxw.sedits[nk]
				if !ok do continue
				nbase := [3]i32{nk.x * CHUNK_N, nk.y * CHUNK_N, nk.z * CHUNK_N}
				x0 := max(nbase.x, smin.x)
				x1 := min(nbase.x + CHUNK_N, smax.x)
				y0 := max(nbase.y, smin.y)
				y1 := min(nbase.y + CHUNK_N, smax.y)
				z0 := max(nbase.z, smin.z)
				z1 := min(nbase.z + CHUNK_N, smax.z)
				for vy in y0 ..< y1 {
					for vz in z0 ..< z1 {
						for vx in x0 ..< x1 {
							snap[si(int(vx - base.x), int(vy - base.y), int(vz - base.z))] =
								arr[cell_index(vx, vy, vz)]
						}
					}
				}
			}
		}
	}
}

quad_tint :: proc(mat: Material, vx, vy, vz: i32) -> [4]u8 {
	// r/g/b are now blend channels (secondary_mat, blend_weight, unused).
	// Structure faces have no material blending for now, so r=g=b=0.
	return {0, 0, 0, u8(mat)}
}

chunk_remesh :: proc(key: Chunk_Key) {
	if m, ok := &vmesh.chunks[key]; ok {
		mesh_destroy(m)
	}

	snap := new([SNAP * SNAP * SNAP]u8, context.temp_allocator)
	structure_snapshot(key, snap)
	si :: proc(x, y, z: int) -> int { return (y * SNAP + z) * SNAP + x }

	verts := make([dynamic]Voxel_Vertex, 0, 1024, context.temp_allocator)
	indices := make([dynamic]u32, 0, 1536, context.temp_allocator)
	base_m := Vec3{f32(key.x) * SCHUNK_M, f32(key.y) * SCHUNK_M, f32(key.z) * SCHUNK_M}
	base_v := [3]i32{key.x * CHUNK_N, key.y * CHUNK_N, key.z * CHUNK_N}

	mask: [CHUNK_N * CHUNK_N]u8
	used: [CHUNK_N * CHUNK_N]bool

	for n in 0 ..< 3 {
		u := (n + 1) % 3
		v := (n + 2) % 3
		for sign in 0 ..< 2 {
			dirn := sign == 0 ? 1 : -1
			normal: [4]i8
			normal[n] = i8(dirn * 127)
			for layer in 0 ..< CHUNK_N {
				any_face := false
				for j in 0 ..< CHUNK_N {
					for i in 0 ..< CHUNK_N {
						cell: [3]int
						cell[n] = layer
						cell[u] = i
						cell[v] = j
						m := snap[si(cell[0] + 1, cell[1] + 1, cell[2] + 1)]
						face: u8 = 0
						if m != 0 {
							nb: [3]int = cell
							nb[n] += dirn
							if snap[si(nb[0] + 1, nb[1] + 1, nb[2] + 1)] == 0 {
								// skip faces buried inside terrain
								wp := Vec3{
									base_m.x + (f32(nb[0]) + 0.5) * SVOX,
									base_m.y + (f32(nb[1]) + 0.5) * SVOX,
									base_m.z + (f32(nb[2]) + 0.5) * SVOX,
								}
								if !terrain_solid_at(wp) {
									face = m
									any_face = true
								}
							}
						}
						mask[j * CHUNK_N + i] = face
						used[j * CHUNK_N + i] = false
					}
				}
				if !any_face do continue
				for j in 0 ..< CHUNK_N {
					for i in 0 ..< CHUNK_N {
						idx := j * CHUNK_N + i
						m := mask[idx]
						if m == 0 || used[idx] do continue
						w := 1
						for i + w < CHUNK_N && mask[idx + w] == m && !used[idx + w] do w += 1
						h := 1
						expand: for j + h < CHUNK_N {
							for k in 0 ..< w {
								kidx := (j + h) * CHUNK_N + i + k
								if mask[kidx] != m || used[kidx] do break expand
							}
							h += 1
						}
						for jj in 0 ..< h {
							for ii in 0 ..< w {
								used[(j + jj) * CHUNK_N + i + ii] = true
							}
						}
						cell: [3]int
						cell[n] = layer
						cell[u] = i
						cell[v] = j
						color := quad_tint(Material(m), base_v.x + i32(cell[0]), base_v.y + i32(cell[1]), base_v.z + i32(cell[2]))

						origin: Vec3
						origin[n] = base_m[n] + f32(layer + (sign == 0 ? 1 : 0)) * SVOX
						origin[u] = base_m[u] + f32(i) * SVOX
						origin[v] = base_m[v] + f32(j) * SVOX
						du, dv: Vec3
						du[u] = f32(w) * SVOX
						dv[v] = f32(h) * SVOX
						a, b: Vec3
						if dirn > 0 {
							a = du
							b = dv
						} else {
							a = dv
							b = du
						}
						vbase := u32(len(verts))
						append(&verts, Voxel_Vertex{pos = origin, normal = normal, color = color})
						append(&verts, Voxel_Vertex{pos = origin + a, normal = normal, color = color})
						append(&verts, Voxel_Vertex{pos = origin + a + b, normal = normal, color = color})
						append(&verts, Voxel_Vertex{pos = origin + b, normal = normal, color = color})
						append(&indices, vbase, vbase + 1, vbase + 2, vbase, vbase + 2, vbase + 3)
					}
				}
			}
		}
	}

	m := mesh_upload(verts[:], indices[:])
	m.bound_center = chunk_center(key)
	m.bound_r = CHUNK_BOUND_R
	vmesh.chunks[key] = m
}

// does this structure chunk possibly contain anything?
chunk_has_structures :: proc(key: Chunk_Key, tree_y0, tree_y1: f32, any_tree: bool) -> bool {
	if _, ok := voxw.sedits[key]; ok do return true
	if voxw.stamp_chunks[key] do return true
	if any_tree {
		cy0 := f32(key.y) * SCHUNK_M
		cy1 := cy0 + SCHUNK_M
		if cy1 >= tree_y0 && cy0 <= tree_y1 do return true
	}
	return false
}

// ---- streaming -----------------------------------------------------------------

tile_center :: proc(key: Tile_Key) -> Vec3 {
	return {(f32(key.x) + 0.5) * TCHUNK_M, WORLD_H * 0.5, (f32(key.y) + 0.5) * TCHUNK_M}
}

chunk_center :: proc(key: Chunk_Key) -> Vec3 {
	return {
		(f32(key.x) + 0.5) * SCHUNK_M,
		(f32(key.y) + 0.5) * SCHUNK_M,
		(f32(key.z) + 0.5) * SCHUNK_M,
	}
}

voxel_stream :: proc(center: Vec3, dt: f32, sync_radius_m: f32 = 0) {
	ctx_tile := Tile_Key{i32(math.floor(center.x / TCHUNK_M)), i32(math.floor(center.z / TCHUNK_M))}

	// dirty remeshes happen immediately: destruction feedback must be instant
	for key in voxw.dirty_tiles {
		if _, ok := vmesh.tiles[key]; ok do tile_remesh(key)
	}
	clear(&voxw.dirty_tiles)
	for key in voxw.dirty_chunks {
		if _, ok := vmesh.chunks[key]; ok do chunk_remesh(key)
	}
	clear(&voxw.dirty_chunks)

	// periodic scan for missing meshes
	vmesh.scan_timer -= dt
	if vmesh.scan_timer <= 0 || ctx_tile != vmesh.last_center || sync_radius_m > 0 {
		vmesh.scan_timer = 0.5
		vmesh.last_center = ctx_tile
		// terrain tiles
		TR := i32(view_radius() / TCHUNK_M) + 1
		for dz in -TR ..= TR {
			for dx in -TR ..= TR {
				if dx * dx + dz * dz > TR * TR do continue
				key := Tile_Key{ctx_tile.x + dx, ctx_tile.y + dz}
				if _, ok := vmesh.tiles[key]; ok do continue
				if vmesh.tile_queued[key] do continue
				vmesh.tile_queued[key] = true
				append(&vmesh.tile_queue, key)
			}
		}
		// structure chunks (only where stamps/edits/trees exist)
		ccx := i32(math.floor(center.x / SCHUNK_M))
		ccz := i32(math.floor(center.z / SCHUNK_M))
		SR := i32(view_radius() / SCHUNK_M) + 1
		for dz in -SR ..= SR {
			for dx in -SR ..= SR {
				if dx * dx + dz * dz > SR * SR do continue
				// tree vertical extent for this column, computed once
				colx := f32(ccx + dx) * SCHUNK_M
				colz := f32(ccz + dz) * SCHUNK_M
				trees: [8]Tree
				nt := collect_trees(
					{colx, 0, colz},
					{colx + SCHUNK_M, WORLD_H, colz + SCHUNK_M},
					&trees,
				)
				ty0 := f32(1e9)
				ty1 := f32(-1e9)
				for i in 0 ..< nt {
					t := trees[i]
					ty0 = min(ty0, t.base.y)
					ty1 = max(ty1, t.base.y + t.trunk_h + t.can_r * 1.4)
				}
				for cy in i32(0) ..< i32(WORLD_H / SCHUNK_M) {
					key := Chunk_Key{ccx + dx, cy, ccz + dz}
					if _, ok := vmesh.chunks[key]; ok do continue
					if vmesh.chunk_queued[key] do continue
					if !chunk_has_structures(key, ty0, ty1, nt > 0) {
						vmesh.chunks[key] = {} // record as empty, skip forever
						continue
					}
					vmesh.chunk_queued[key] = true
					append(&vmesh.chunk_queue, key)
				}
			}
		}
		// nearest-last so we pop from the back
		cc := Vec2{center.x, center.z}
		slice.sort_by_cmp(vmesh.tile_queue[:], proc(a, b: Tile_Key) -> slice.Ordering {
			lc := vmesh.last_center
			cc := Vec2{(f32(lc.x) + 0.5) * TCHUNK_M, (f32(lc.y) + 0.5) * TCHUNK_M}
			ca := tile_center(a)
			cb := tile_center(b)
			da := (ca.x - cc.x) * (ca.x - cc.x) + (ca.z - cc.y) * (ca.z - cc.y)
			db := (cb.x - cc.x) * (cb.x - cc.x) + (cb.z - cc.y) * (cb.z - cc.y)
			if da > db do return .Less
			if da < db do return .Greater
			return .Equal
		})
		_ = cc
	}

	// synchronous initial area
	if sync_radius_m > 0 {
		for i := 0; i < len(vmesh.tile_queue); {
			key := vmesh.tile_queue[i]
			c := tile_center(key)
			d := Vec2{c.x - center.x, c.z - center.z}
			if d.x * d.x + d.y * d.y <= sync_radius_m * sync_radius_m {
				tile_remesh(key)
				delete_key(&vmesh.tile_queued, key)
				ordered_remove(&vmesh.tile_queue, i)
			} else {
				i += 1
			}
		}
		for i := 0; i < len(vmesh.chunk_queue); {
			key := vmesh.chunk_queue[i]
			c := chunk_center(key)
			d := Vec2{c.x - center.x, c.z - center.z}
			if d.x * d.x + d.y * d.y <= sync_radius_m * sync_radius_m {
				chunk_remesh(key)
				delete_key(&vmesh.chunk_queued, key)
				ordered_remove(&vmesh.chunk_queue, i)
			} else {
				i += 1
			}
		}
	}

	// time-boxed streaming; structures first (few), then terrain
	start := time.tick_now()
	for len(vmesh.chunk_queue) > 0 {
		key := pop(&vmesh.chunk_queue)
		delete_key(&vmesh.chunk_queued, key)
		chunk_remesh(key)
		if time.duration_milliseconds(time.tick_since(start)) > MESH_BUDGET_MS do break
	}
	for len(vmesh.tile_queue) > 0 {
		if time.duration_milliseconds(time.tick_since(start)) > MESH_BUDGET_MS do break
		key := pop(&vmesh.tile_queue)
		delete_key(&vmesh.tile_queued, key)
		tile_remesh(key)
	}

	// occasional eviction sweep
	vmesh.evict_timer -= dt
	if vmesh.evict_timer <= 0 {
		vmesh.evict_timer = 2.0
		evict_r := view_radius() + EVICT_MARGIN_M
		evict_tiles := make([dynamic]Tile_Key, context.temp_allocator)
		for key, _ in vmesh.tiles {
			c := tile_center(key)
			d := Vec2{c.x - center.x, c.z - center.z}
			if d.x * d.x + d.y * d.y > evict_r * evict_r do append(&evict_tiles, key)
		}
		for key in evict_tiles {
			m := vmesh.tiles[key]
			mesh_destroy(&m)
			delete_key(&vmesh.tiles, key)
		}
		evict_chunks := make([dynamic]Chunk_Key, context.temp_allocator)
		for key, _ in vmesh.chunks {
			c := chunk_center(key)
			d := Vec2{c.x - center.x, c.z - center.z}
			if d.x * d.x + d.y * d.y > evict_r * evict_r do append(&evict_chunks, key)
		}
		for key in evict_chunks {
			m := vmesh.chunks[key]
			mesh_destroy(&m)
			delete_key(&vmesh.chunks, key)
		}
	}
}

// ---- culling + draw --------------------------------------------------------------

Frustum :: [6]Vec4

frustum_from :: proc(m: Mat4) -> (f: Frustum) {
	row :: proc(m: Mat4, r: int) -> Vec4 { return {m[0][r], m[1][r], m[2][r], m[3][r]} }
	r0 := row(m, 0)
	r1 := row(m, 1)
	r2 := row(m, 2)
	r3 := row(m, 3)
	f[0] = r3 + r0
	f[1] = r3 - r0
	f[2] = r3 + r1
	f[3] = r3 - r1
	f[4] = r3 + r2
	f[5] = r3 - r2
	return
}

frustum_sphere_visible :: proc(f: Frustum, c: Vec3, r: f32) -> bool {
	for p in f {
		if p.x * c.x + p.y * c.y + p.z * c.z + p.w < -r * vlen(p.xyz) {
			return false
		}
	}
	return true
}

CHUNK_BOUND_R :: 3.47 // 4 m cube half-diagonal

voxel_draw :: proc(frustum: Frustum, vs: ^Vs_Params, fs: ^Fs_Params) {
	vmesh.chunks_drawn = 0
	vmesh.tris_drawn = 0
	draw_one :: proc(m: Mesh_Buffers, vs: ^Vs_Params, fs: ^Fs_Params) {
		sg.apply_bindings({
			vertex_buffers = {0 = m.vbuf},
			index_buffer   = m.ibuf,
			views = {
				VIEW_t_albedo = pbr.albedo_view,
				VIEW_t_normal = pbr.normal_view,
				VIEW_t_orm    = pbr.orm_view,
			},
			samplers = {SMP_smp = pbr.sampler},
		})
		sg.apply_uniforms(UB_vs_params, {ptr = vs, size = size_of(Vs_Params)})
		sg.apply_uniforms(UB_fs_params, {ptr = fs, size = size_of(Fs_Params)})
		sg.draw(0, m.num_idx, 1)
		vmesh.chunks_drawn += 1
		vmesh.tris_drawn += m.num_idx / 3
	}
	for _, m in vmesh.tiles {
		if m.num_idx == 0 do continue
		if !frustum_sphere_visible(frustum, m.bound_center, m.bound_r) do continue
		draw_one(m, vs, fs)
	}
	for _, m in vmesh.chunks {
		if m.num_idx == 0 do continue
		if !frustum_sphere_visible(frustum, m.bound_center, m.bound_r) do continue
		draw_one(m, vs, fs)
	}
}
