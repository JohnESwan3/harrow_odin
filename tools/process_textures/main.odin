// process_textures — resize + BC-compress material textures into .hpak files
//
// .hpak format (mip-major, matches sokol Image_Data layout directly):
//   Header  12 bytes: magic "HPK1", format u8, width u16, height u16, mips u8, pad[2]u8
//   Data:   for each mip (0..mips): one layer of BC block data
//
// BC1 (4 bpp): R+G+B, no alpha.  Good for ORM where artifacts are invisible.
// BC3 (8 bpp): R+G+B+A.          Good for albedo (higher quality color).
// rgba: uncompressed 32bpp.       Used for normal maps until BC5 is added.
//
// Usage: process_textures.exe [assets/textures]
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"
import stbi "vendor:stb/image"

// ---- Settings ------------------------------------------------------------------

Format :: enum u8 { RGBA, BC1, BC3 }

Tex_Cfg :: struct {
	resolution: int,   // 0 = keep source resolution
	format:     Format,
}

Mat_Config :: struct {
	base_color: Tex_Cfg,
	normal:     Tex_Cfg,
	orm:        Tex_Cfg,
}

DEFAULT_CFG :: Mat_Config{
	base_color = {resolution = 2048, format = .BC3},
	normal     = {resolution = 2048, format = .RGBA},
	orm        = {resolution = 1024, format = .BC1},
}

parse_format :: proc(s: string) -> Format {
	switch s {
	case "bc1": return .BC1
	case "bc3": return .BC3
	}
	return .RGBA
}

load_settings :: proc(dir: string) -> Mat_Config {
	cfg := DEFAULT_CFG
	path := fmt.tprintf("%s/settings.toml", dir)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return cfg }

	section := ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		line := strings.trim_space(line)
		if len(line) == 0 || line[0] == '#' { continue }
		if line[0] == '[' {
			section = strings.trim_space(line[1:len(line)-1])
			continue
		}
		eq := strings.index(line, "=")
		if eq < 0 { continue }
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq+1:])

		tcfg: ^Tex_Cfg
		switch section {
		case "base_color": tcfg = &cfg.base_color
		case "normal":     tcfg = &cfg.normal
		case "orm":        tcfg = &cfg.orm
		}
		if tcfg == nil { continue }

		switch key {
		case "resolution": tcfg.resolution, _ = strconv.parse_int(val)
		case "format":     tcfg.format = parse_format(val)
		}
	}
	return cfg
}

// ---- BC compression ------------------------------------------------------------

// Encode three u8 channels as RGB565.
@(private)
rgb565 :: #force_inline proc(r, g, b: u8) -> u16 {
	return u16(r >> 3) << 11 | u16(g >> 2) << 5 | u16(b >> 3)
}

// Decode RGB565 to 8-bit components.
@(private)
decode565 :: #force_inline proc(c: u16) -> (r, g, b: int) {
	r5 := int(c >> 11) & 0x1F
	g6 := int(c >>  5) & 0x3F
	b5 := int(c)       & 0x1F
	r = (r5 << 3) | (r5 >> 2)
	g = (g6 << 2) | (g6 >> 4)
	b = (b5 << 3) | (b5 >> 2)
	return
}

// Compress one 4x4 block to BC1 (8 bytes). pix is RGB (3 bytes per pixel).
@(private)
bc1_block :: proc(pix: [16][3]u8) -> [8]u8 {
	mn, mx := [3]int{255, 255, 255}, [3]int{0, 0, 0}
	for p in pix {
		for ch in 0..<3 {
			v := int(p[ch])
			if v < mn[ch] { mn[ch] = v }
			if v > mx[ch] { mx[ch] = v }
		}
	}

	c0 := rgb565(u8(mx[0]), u8(mx[1]), u8(mx[2]))
	c1 := rgb565(u8(mn[0]), u8(mn[1]), u8(mn[2]))
	if c0 < c1 { c0, c1 = c1, c0 }  // must have c0 >= c1 for 4-color opaque mode

	er0, eg0, eb0 := decode565(c0)
	er1, eg1, eb1 := decode565(c1)

	// 4 interpolated reference colors
	cr := [4]int{er0, er1, (2*er0 + er1) / 3, (er0 + 2*er1) / 3}
	cg := [4]int{eg0, eg1, (2*eg0 + eg1) / 3, (eg0 + 2*eg1) / 3}
	cb := [4]int{eb0, eb1, (2*eb0 + eb1) / 3, (eb0 + 2*eb1) / 3}

	indices: [4]u8
	for row in 0..<4 {
		ri: u8
		for col in 0..<4 {
			p := pix[row*4 + col]
			best_err, best_k := max(int), 0
			for k in 0..<4 {
				dr := int(p[0]) - cr[k]
				dg := int(p[1]) - cg[k]
				db := int(p[2]) - cb[k]
				e  := dr*dr + dg*dg + db*db
				if e < best_err { best_err = e; best_k = k }
			}
			ri |= u8(best_k) << u8(col * 2)
		}
		indices[row] = ri
	}
	return {u8(c0), u8(c0 >> 8), u8(c1), u8(c1 >> 8),
	        indices[0], indices[1], indices[2], indices[3]}
}

// Compress RGBA image (w×h×4 bytes) to BC1 data (ceil(w/4)*ceil(h/4)*8 bytes).
compress_bc1 :: proc(rgba: []u8, w, h: int) -> []u8 {
	bw, bh := (w + 3) / 4, (h + 3) / 4
	out := make([]u8, bw * bh * 8)
	for by in 0..<bh {
		for bx in 0..<bw {
			pix: [16][3]u8
			for py in 0..<4 {
				for px in 0..<4 {
					sx := min(bx*4 + px, w - 1)
					sy := min(by*4 + py, h - 1)
					si := (sy*w + sx) * 4
					pix[py*4+px] = {rgba[si], rgba[si+1], rgba[si+2]}
				}
			}
			block := bc1_block(pix)
			di    := (by*bw + bx) * 8
			copy(out[di:di+8], block[:])
		}
	}
	return out
}

// Compress RGBA image to BC3 data (ceil(w/4)*ceil(h/4)*16 bytes).
// Alpha is assumed to be fully opaque (255) so the alpha block is constant.
compress_bc3 :: proc(rgba: []u8, w, h: int) -> []u8 {
	bw, bh := (w + 3) / 4, (h + 3) / 4
	out := make([]u8, bw * bh * 16)
	// BC4 alpha block: a0=255, a1=0, all 16 pixel indices = 0 → all pixels use a0 = 255
	alpha_block := [8]u8{255, 0, 0, 0, 0, 0, 0, 0}
	for by in 0..<bh {
		for bx in 0..<bw {
			pix: [16][3]u8
			for py in 0..<4 {
				for px in 0..<4 {
					sx := min(bx*4 + px, w - 1)
					sy := min(by*4 + py, h - 1)
					si := (sy*w + sx) * 4
					pix[py*4+px] = {rgba[si], rgba[si+1], rgba[si+2]}
				}
			}
			color_block := bc1_block(pix)
			di          := (by*bw + bx) * 16
			copy(out[di:di+8],   alpha_block[:])
			copy(out[di+8:di+16], color_block[:])
		}
	}
	return out
}

// Returns compressed bytes-per-layer at a given mip size.
@(private)
bc_layer_bytes :: proc(w, h: int, fmt: Format) -> int {
	bw, bh := max(1, (w+3)/4), max(1, (h+3)/4)
	block_sz := 16 if fmt == .BC3 else 8
	return bw * bh * block_sz
}

// ---- HPAK writer ---------------------------------------------------------------

HPAK_MAGIC :: [4]u8{'H', 'P', 'K', '1'}

HPAK_Header :: struct #packed {
	magic:  [4]u8,
	format: u8,     // 0=rgba, 1=bc1, 2=bc3
	width:  u16,
	height: u16,
	mips:   u8,
	_pad:   [2]u8,
}
#assert(size_of(HPAK_Header) == 12)

// Count mip levels for given base dimensions.
mip_count :: proc(w, h: int) -> int {
	n := 1; cw, ch := w, h
	for cw > 1 || ch > 1 { cw = max(1, cw/2); ch = max(1, ch/2); n += 1 }
	return n
}

// Write one material's worth of data to <dir>/<map_name>.hpak.
// Returns true on success.
write_hpak :: proc(dir, map_name: string, rgba_src: []u8, src_w, src_h: int, cfg: Tex_Cfg) -> bool {
	target_w := cfg.resolution if cfg.resolution > 0 else src_w
	target_h := cfg.resolution if cfg.resolution > 0 else src_h

	// Resize source to target if needed
	base_rgba: []u8
	if target_w != src_w || target_h != src_h {
		base_rgba = make([]u8, target_w * target_h * 4)
		stbi.resize_uint8(raw_data(rgba_src), i32(src_w), i32(src_h), 0,
		                  raw_data(base_rgba), i32(target_w), i32(target_h), 0, 4)
	} else {
		base_rgba = rgba_src
	}
	defer if target_w != src_w || target_h != src_h { delete(base_rgba) }

	num_mips := mip_count(target_w, target_h)

	// Build compressed mip chain.  stbi.resize_uint8 from original each time (better quality).
	mip_data := make([][]u8, num_mips)
	defer {
		for d in mip_data { delete(d) }
		delete(mip_data)
	}

	for m in 0..<num_mips {
		mw := max(1, target_w >> uint(m))
		mh := max(1, target_h >> uint(m))
		mip_rgba: []u8
		if m == 0 {
			mip_rgba = base_rgba
		} else {
			mip_rgba = make([]u8, mw * mh * 4)
			stbi.resize_uint8(raw_data(base_rgba), i32(target_w), i32(target_h), 0,
			                  raw_data(mip_rgba), i32(mw), i32(mh), 0, 4)
		}
		switch cfg.format {
		case .BC1:
			mip_data[m] = compress_bc1(mip_rgba, mw, mh)
			if m > 0 { delete(mip_rgba) }
		case .BC3:
			mip_data[m] = compress_bc3(mip_rgba, mw, mh)
			if m > 0 { delete(mip_rgba) }
		case .RGBA:
			if m == 0 {
				// base_rgba may be borrowed from caller — always copy mip 0
				mip_data[m] = make([]u8, len(mip_rgba))
				copy(mip_data[m], mip_rgba)
			} else {
				mip_data[m] = mip_rgba  // steal: freshly allocated by resize
			}
		}
	}

	// Write .hpak
	out_path := fmt.tprintf("%s/%s.hpak", dir, map_name)
	f, err := os.open(out_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default)
	if err != nil {
		fmt.printfln("  ERROR: cannot create %s: %v", out_path, err)
		return false
	}
	defer os.close(f)

	fmt_byte: u8 = 0 if cfg.format == .RGBA else (1 if cfg.format == .BC1 else 2)
	hdr := HPAK_Header{
		magic  = HPAK_MAGIC,
		format = fmt_byte,
		width  = u16(target_w),
		height = u16(target_h),
		mips   = u8(num_mips),
	}
	os.write(f, mem.byte_slice(&hdr, size_of(HPAK_Header)))
	for d in mip_data {
		os.write(f, d)
	}
	return true
}

// ---- Material processing -------------------------------------------------------

process_dir :: proc(dir: string) -> bool {
	cfg := load_settings(dir)

	Map_Entry :: struct { name: string, tcfg: Tex_Cfg }
	maps := [3]Map_Entry{
		{"base_color", cfg.base_color},
		{"normal",     cfg.normal},
		{"orm",        cfg.orm},
	}

	processed := 0
	for entry in maps {
		map_name := entry.name
		tcfg     := entry.tcfg

		src_path  := fmt.tprintf("%s/%s.png",  dir, map_name)
		hpak_path := fmt.tprintf("%s/%s.hpak", dir, map_name)

		// Skip if .hpak exists and is newer than .png (source unchanged).
		png_stat,  png_err  := os.stat(src_path,  context.temp_allocator)
		hpak_stat, hpak_err := os.stat(hpak_path, context.temp_allocator)
		if png_err == nil && hpak_err == nil &&
		   time.diff(png_stat.modification_time, hpak_stat.modification_time) >= 0 {
			fmt.printfln("    skip %s (up to date)", map_name)
			continue
		}

		sw, sh, _c: i32
		src := stbi.load(fmt.ctprintf("%s", src_path), &sw, &sh, &_c, 4)
		if src == nil {
			fmt.printfln("    skip %s (no source)", map_name)
			continue
		}
		n := int(sw) * int(sh) * 4
		rgba := make([]u8, n)
		copy(rgba, src[:n])
		stbi.image_free(src)
		defer delete(rgba)

		if write_hpak(dir, map_name, rgba, int(sw), int(sh), tcfg) {
			processed += 1
		}
	}

	fmt.printfln("  %-25s  %d/3 maps", dir, processed)
	return processed > 0
}

// ---- Main ----------------------------------------------------------------------

main :: proc() {
	root := len(os.args) > 1 ? os.args[1] : "assets/textures"

	entries, err := os.read_all_directory_by_path(root, context.allocator)
	if err != nil {
		fmt.eprintfln("error: cannot read '%s': %v", root, err)
		os.exit(1)
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	packed := 0
	for e in entries {
		if e.type != .Directory { continue }
		if process_dir(e.fullpath) { packed += 1 }
	}
	fmt.printfln("\nprocessed %d material(s).", packed)
}
