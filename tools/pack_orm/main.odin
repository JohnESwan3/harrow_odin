// pack_orm — combine ao.png + roughness.png + metallic.png → orm.png
//   R = ambient occlusion   (fallback: 255  = no occlusion)
//   G = roughness           (fallback: 204  ≈ 0.8 rough)
//   B = metallic            (fallback: 0    = dielectric)
//
// Usage: pack_orm.exe [assets/textures]
// Walks every subdirectory of the given root (default: assets/textures).
package main

import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"

FALLBACK_AO        :: u8(255)
FALLBACK_ROUGHNESS :: u8(204)
FALLBACK_METALLIC  :: u8(0)

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
		if pack_dir(e.fullpath) { packed += 1 }
	}
	fmt.printfln("\npacked %d material(s).", packed)
}

// Load one channel from a grayscale or color PNG, returning w*h bytes.
// Returns a solid fallback slice if the file is missing or the wrong size.
@(private)
load_r :: proc(path: cstring, w, h: i32, fallback: u8) -> []u8 {
	n := int(w) * int(h)
	result := make([]u8, n)

	fw, fh, _c: i32
	data := stbi.load(path, &fw, &fh, &_c, 1)
	if data != nil {
		defer stbi.image_free(data)
		if fw == w && fh == h {
			copy(result, data[:n])
			return result
		}
		fmt.printfln("  warn: size mismatch %s (%dx%d, expected %dx%d) — fallback", path, fw, fh, w, h)
	}
	for &b in result { b = fallback }
	return result
}

// Pack ao/roughness/metallic in dir into orm.png. Returns true on success.
@(private)
pack_dir :: proc(dir: string) -> bool {
	// Determine dimensions from the first available source map.
	w, h: i32
	sources := [3]string{"ao", "roughness", "metallic"}
	for src in sources {
		path := fmt.ctprintf("%s/%s.png", dir, src)
		fw, fh, _c: i32
		if stbi.info(path, &fw, &fh, &_c) != 0 {
			w, h = fw, fh
			break
		}
	}
	if w == 0 {
		fmt.printfln("  skip %-20s (no source maps found)", dir)
		return false
	}

	ao_ch := load_r(fmt.ctprintf("%s/ao.png",        dir), w, h, FALLBACK_AO)
	rg_ch := load_r(fmt.ctprintf("%s/roughness.png", dir), w, h, FALLBACK_ROUGHNESS)
	mt_ch := load_r(fmt.ctprintf("%s/metallic.png",  dir), w, h, FALLBACK_METALLIC)
	defer delete(ao_ch)
	defer delete(rg_ch)
	defer delete(mt_ch)

	n   := int(w) * int(h)
	orm := make([]u8, n * 4)
	defer delete(orm)

	for i in 0 ..< n {
		orm[i*4+0] = ao_ch[i]  // R = AO
		orm[i*4+1] = rg_ch[i]  // G = roughness
		orm[i*4+2] = mt_ch[i]  // B = metallic
		orm[i*4+3] = 255
	}

	out := fmt.ctprintf("%s/orm.png", dir)
	if stbi.write_png(out, w, h, 4, raw_data(orm), w * 4) == 0 {
		fmt.printfln("  ERROR: failed to write %s", out)
		return false
	}
	fmt.printfln("  %-50s  %dx%d", out, w, h)
	return true
}
