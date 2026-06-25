package main

import "core:fmt"
import "core:mem"
import "core:os"
import sg "../sokol/gfx"
import stbi "vendor:stb/image"

// One texture-array layer per Material enum value (12 total, Air=0 unused).
N_MAT_LAYERS :: 12

// Directory name per material, indexed by Material enum value.
@(private)
mat_dir := [N_MAT_LAYERS]string{
	"",              // Air — no textures
	"grass",
	"dirt",
	"rock",
	"sand",
	"concrete",
	"concrete_dark",
	"metal",
	"wood",
	"bedrock",
	"snow",
	"leaves",
}

// PBR texture arrays + sampler, all globally accessible from render/draw code.
pbr: struct {
	albedo_img: sg.Image,
	normal_img: sg.Image,
	orm_img:    sg.Image,  // R=ao  G=roughness  B=metallic
	sampler:    sg.Sampler,
	// Views used in Bindings.views[] — slots match layout(binding=N) in vox_fs
	albedo_view: sg.View, // binding 0
	normal_view: sg.View, // binding 1
	orm_view:    sg.View, // binding 2
}

// ---- HPAK format (matches process_textures tool output) -----------------------
// Header 12 bytes: magic "HPK1", format u8, width u16, height u16, mips u8, pad[2]u8
// Data (mip-major): for each mip, one layer of block data
// format: 0=rgba8, 1=bc1, 2=bc3

@(private)
HPAK_MAGIC :: [4]u8{'H', 'P', 'K', '1'}

@(private)
HPAK_Header :: struct #packed {
	magic:  [4]u8,
	format: u8,
	width:  u16,
	height: u16,
	mips:   u8,
	_pad:   [2]u8,
}
#assert(size_of(HPAK_Header) == 12)

@(private)
hpak_sg_format :: proc(fmt_byte: u8) -> sg.Pixel_Format {
	switch fmt_byte {
	case 1: return .BC1_RGBA
	case 2: return .BC3_RGBA
	}
	return .RGBA8
}

// Compressed bytes per layer at a given mip size.
@(private)
hpak_layer_bytes :: proc(w, h: i32, fmt_byte: u8) -> int {
	if fmt_byte == 0 { return int(w) * int(h) * 4 }
	bw := max(i32(1), (w + 3) / 4)
	bh := max(i32(1), (h + 3) / 4)
	return int(bw) * int(bh) * (16 if fmt_byte == 2 else 8)
}

// Fallback block data (one layer worth) for when a material's .hpak is missing.
@(private)
hpak_fallback_layer :: proc(w, h: i32, fmt_byte: u8, map_idx, mat: int) -> []u8 {
	pix := fallback_pixel(map_idx, mat)
	if fmt_byte == 0 {
		n   := int(w) * int(h) * 4
		buf := make([]u8, n)
		for p in 0 ..< n / 4 { copy(buf[p*4:], pix[:]) }
		return buf
	}
	// For BC formats: encode a 4x4 block of the fallback color, repeat to fill.
	block_sz := 16 if fmt_byte == 2 else 8
	bw := max(i32(1), (w + 3) / 4)
	bh := max(i32(1), (h + 3) / 4)
	buf := make([]u8, int(bw) * int(bh) * block_sz)
	// Minimal BC1 block: c0==c1 (same color), all indices=0
	r5 := u16(pix[0] >> 3)
	g6 := u16(pix[1] >> 2)
	b5 := u16(pix[2] >> 3)
	c  := r5 << 11 | g6 << 5 | b5
	bc1: [8]u8 = {u8(c), u8(c >> 8), u8(c), u8(c >> 8), 0, 0, 0, 0}
	if fmt_byte == 2 {
		bc3: [16]u8
		bc3[0] = pix[3]; bc3[1] = pix[3]  // alpha constant
		copy(bc3[8:], bc1[:])
		for b in 0 ..< int(bw) * int(bh) { copy(buf[b*16:], bc3[:]) }
	} else {
		for b in 0 ..< int(bw) * int(bh) { copy(buf[b*8:], bc1[:]) }
	}
	return buf
}

// ---- PNG fallback helpers (unchanged) -----------------------------------------

@(private)
fallback_pixel :: proc(map_idx: int, mat: int) -> [4]u8 {
	switch map_idx {
	case 0:
		c := MAT_COLORS[Material(mat)]
		return {c[0], c[1], c[2], 255}
	case 1:
		return {128, 128, 255, 255}
	case 2:
		return {255, 204, 0, 255}
	}
	return {255, 0, 255, 255}
}

@(private)
mip_level_count :: proc(w, h: i32) -> int {
	levels := 1
	cw, ch := w, h
	for cw > 1 || ch > 1 {
		cw = max(1, cw / 2)
		ch = max(1, ch / 2)
		levels += 1
	}
	return levels
}

@(private)
mip_downsample :: proc(src: []u8, dst: []u8, w, h: i32) {
	dw := max(i32(1), w / 2)
	dh := max(i32(1), h / 2)
	for y in i32(0) ..< dh {
		for x in i32(0) ..< dw {
			sx  := x * 2
			sy  := y * 2
			sx1 := min(sx + 1, w - 1)
			sy1 := min(sy + 1, h - 1)
			p00 := src[(sy  * w + sx ) * 4:]
			p10 := src[(sy  * w + sx1) * 4:]
			p01 := src[(sy1 * w + sx ) * 4:]
			p11 := src[(sy1 * w + sx1) * 4:]
			d   := dst[(y * dw + x) * 4:]
			d[0] = u8((int(p00[0]) + int(p10[0]) + int(p01[0]) + int(p11[0])) / 4)
			d[1] = u8((int(p00[1]) + int(p10[1]) + int(p01[1]) + int(p11[1])) / 4)
			d[2] = u8((int(p00[2]) + int(p10[2]) + int(p01[2]) + int(p11[2])) / 4)
			d[3] = u8((int(p00[3]) + int(p10[3]) + int(p01[3]) + int(p11[3])) / 4)
		}
	}
}

// ---- HPAK array loader --------------------------------------------------------

// Try to build an sg.Image from per-material .hpak files.
// Returns a valid image on success, zeroed image on failure (all materials missing .hpak).
@(private)
try_hpak_array :: proc(map_name: string, map_idx: int) -> (img: sg.Image, ok: bool) {
	// First pass: find dimensions + format from the first loadable .hpak.
	tex_w, tex_h: i32 = 0, 0
	fmt_byte: u8 = 0
	num_mips: int = 0
	for i in 1 ..< N_MAT_LAYERS {
		path := fmt.ctprintf("assets/textures/%s/%s.hpak", mat_dir[i], map_name)
		hdr_buf, rerr := os.read_entire_file(string(path), context.temp_allocator)
		if rerr != nil || len(hdr_buf) < size_of(HPAK_Header) { continue }
		hdr := (^HPAK_Header)(raw_data(hdr_buf))^
		if hdr.magic != HPAK_MAGIC { continue }
		tex_w    = i32(hdr.width)
		tex_h    = i32(hdr.height)
		fmt_byte = hdr.format
		num_mips = int(hdr.mips)
		ok = true
		break
	}
	if !ok { return }

	// Compute per-mip byte offsets in the assembled buffer (mip-major, all layers).
	mip_layer_sz := make([]int, num_mips)
	mip_offsets  := make([]int, num_mips)
	defer delete(mip_layer_sz)
	defer delete(mip_offsets)

	total := 0
	mw, mh := tex_w, tex_h
	for m in 0 ..< num_mips {
		mip_layer_sz[m] = hpak_layer_bytes(mw, mh, fmt_byte)
		mip_offsets[m]  = total
		total           += N_MAT_LAYERS * mip_layer_sz[m]
		mw = max(1, mw / 2)
		mh = max(1, mh / 2)
	}

	buf := make([]u8, total)
	defer delete(buf)

	// Second pass: load each material's .hpak and place its mip data into buf.
	for i in 0 ..< N_MAT_LAYERS {
		if i == 0 || mat_dir[i] == "" {
			// Air layer: fill with fallback for each mip
			mw2, mh2 := tex_w, tex_h
			for m in 0 ..< num_mips {
				fb := hpak_fallback_layer(mw2, mh2, fmt_byte, map_idx, i)
				defer delete(fb)
				dst_off := mip_offsets[m] + i * mip_layer_sz[m]
				copy(buf[dst_off : dst_off + mip_layer_sz[m]], fb)
				mw2 = max(1, mw2 / 2); mh2 = max(1, mh2 / 2)
			}
			continue
		}

		path     := fmt.ctprintf("assets/textures/%s/%s.hpak", mat_dir[i], map_name)
		file_buf, rerr := os.read_entire_file(string(path), context.temp_allocator)
		if rerr != nil || len(file_buf) < size_of(HPAK_Header) {
			// Missing .hpak — fill with fallback
			mw2, mh2 := tex_w, tex_h
			for m in 0 ..< num_mips {
				fb := hpak_fallback_layer(mw2, mh2, fmt_byte, map_idx, i)
				defer delete(fb)
				dst_off := mip_offsets[m] + i * mip_layer_sz[m]
				copy(buf[dst_off : dst_off + mip_layer_sz[m]], fb)
				mw2 = max(1, mw2 / 2); mh2 = max(1, mh2 / 2)
			}
			continue
		}

		src_off := size_of(HPAK_Header)
		for m in 0 ..< num_mips {
			src_end := src_off + mip_layer_sz[m]
			if src_end > len(file_buf) { break }
			dst_off := mip_offsets[m] + i * mip_layer_sz[m]
			copy(buf[dst_off : dst_off + mip_layer_sz[m]], file_buf[src_off:src_end])
			src_off = src_end
		}
	}

	img_data: sg.Image_Data
	for m in 0 ..< num_mips {
		sz := N_MAT_LAYERS * mip_layer_sz[m]
		img_data.mip_levels[m] = {ptr = raw_data(buf[mip_offsets[m]:]), size = uint(sz)}
	}

	img = sg.make_image({
		type         = .ARRAY,
		width        = tex_w,
		height       = tex_h,
		num_slices   = N_MAT_LAYERS,
		num_mipmaps  = i32(num_mips),
		pixel_format = hpak_sg_format(fmt_byte),
		data         = img_data,
	})
	return
}

// ---- PNG fallback array loader ------------------------------------------------

@(private)
make_pbr_array_png :: proc(map_name: string, map_idx: int) -> (img: sg.Image) {
	tex_w, tex_h: i32 = 1, 1
	for i in 1 ..< N_MAT_LAYERS {
		path := fmt.ctprintf("assets/textures/%s/%s.png", mat_dir[i], map_name)
		w, h, _c: i32
		data := stbi.load(path, &w, &h, &_c, 4)
		if data != nil {
			stbi.image_free(data)
			tex_w, tex_h = w, h
			break
		}
	}

	num_mips   := mip_level_count(tex_w, tex_h)
	mip_bufs   := make([][]u8, num_mips)
	defer {
		for b in mip_bufs { delete(b) }
		delete(mip_bufs)
	}

	layer0_bytes := int(tex_w) * int(tex_h) * 4
	mip_bufs[0]  = make([]u8, N_MAT_LAYERS * layer0_bytes)
	for i in 0 ..< N_MAT_LAYERS {
		layer := mip_bufs[0][i * layer0_bytes:(i + 1) * layer0_bytes]
		if i == 0 || mat_dir[i] == "" {
			pix := fallback_pixel(map_idx, i)
			for p in 0 ..< layer0_bytes / 4 { copy(layer[p*4:], pix[:]) }
			continue
		}
		path := fmt.ctprintf("assets/textures/%s/%s.png", mat_dir[i], map_name)
		w, h, _c: i32
		data := stbi.load(path, &w, &h, &_c, 4)
		if data != nil && w == tex_w && h == tex_h {
			copy(layer, mem.byte_slice(data, layer0_bytes))
			stbi.image_free(data)
		} else {
			if data != nil {
				fmt.printf("pbr: size mismatch %s/%s (%dx%d vs %dx%d)\n",
					mat_dir[i], map_name, w, h, tex_w, tex_h)
				stbi.image_free(data)
			}
			pix := fallback_pixel(map_idx, i)
			for p in 0 ..< layer0_bytes / 4 { copy(layer[p*4:], pix[:]) }
		}
	}

	cur_w, cur_h := tex_w, tex_h
	for m in 1 ..< num_mips {
		prev_w, prev_h   := cur_w, cur_h
		cur_w = max(i32(1), cur_w / 2)
		cur_h = max(i32(1), cur_h / 2)
		prev_layer_sz := int(prev_w) * int(prev_h) * 4
		cur_layer_sz  := int(cur_w)  * int(cur_h)  * 4
		mip_bufs[m]    = make([]u8, N_MAT_LAYERS * cur_layer_sz)
		for lay in 0 ..< N_MAT_LAYERS {
			src := mip_bufs[m-1][lay * prev_layer_sz : (lay+1) * prev_layer_sz]
			dst := mip_bufs[m  ][lay * cur_layer_sz  : (lay+1) * cur_layer_sz ]
			mip_downsample(src, dst, prev_w, prev_h)
		}
	}

	img_data: sg.Image_Data
	for m in 0 ..< num_mips {
		img_data.mip_levels[m] = {ptr = raw_data(mip_bufs[m]), size = uint(len(mip_bufs[m]))}
	}
	img = sg.make_image({
		type = .ARRAY, width = tex_w, height = tex_h,
		num_slices = N_MAT_LAYERS, num_mipmaps = i32(num_mips),
		pixel_format = .RGBA8, data = img_data,
	})
	return
}

// ---- Public entry point -------------------------------------------------------

@(private)
make_pbr_array :: proc(map_name: string, map_idx: int) -> sg.Image {
	if img, ok := try_hpak_array(map_name, map_idx); ok { return img }
	return make_pbr_array_png(map_name, map_idx)
}

pbr_textures_init :: proc() {
	pbr.albedo_img = make_pbr_array("base_color", 0)
	pbr.normal_img = make_pbr_array("normal",     1)
	pbr.orm_img    = make_pbr_array("orm",        2)

	pbr.sampler = sg.make_sampler({
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		mipmap_filter  = .LINEAR,
		wrap_u         = .REPEAT,
		wrap_v         = .REPEAT,
		max_anisotropy = 4,
	})

	make_view :: proc(img: sg.Image) -> sg.View {
		return sg.make_view({texture = {image = img}})
	}
	pbr.albedo_view = make_view(pbr.albedo_img)
	pbr.normal_view = make_view(pbr.normal_img)
	pbr.orm_view    = make_view(pbr.orm_img)
}
