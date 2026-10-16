package main

import "core:fmt"
import "core:strings"
import stbi "vendor:stb/image"

// `odin_raytrace caves [dir] [x] [z]`: the generated ground cut open, for
// judging caves without walking them: a vertical slice 512 blocks along x
// through (x, z), and a horizontal one 512 x 512 around it at a few heights
// (caves_<y>.png). Stone grey, air black (sky blue above the ground),
// water blue, cave life in its colours.
cave_map_export :: proc(dir: string, cx, cz: int) {
    W :: 512
    cols := make(map[[2]int]^Column)
    defer {
        for _, c in cols { column_free(c) }
        delete(cols)
    }
    get :: proc(cols: ^map[[2]int]^Column, x, y, z: int) -> u8 {
        key := [2]int{x >> 3, z >> 3}
        col, ok := cols[key]
        if !ok {
            col = generate_column_at(key.x, key.y)
            cols[key] = col
            free_all(context.temp_allocator)
        }
        iy := chunk_y_index(y >> 3)
        if iy < 0 { return 0 }
        return chunk_voxel(&col.chunks[iy], (x & 7) + (y & 7) * CHUNK_VOXELS + (z & 7) * CHUNK_VOXELS * CHUNK_VOXELS)
    }
    color :: proc(b: u8, sky: bool) -> [3]u8 {
        #partial switch Block_Type(b) {
        case .Air:           return sky ? {150, 190, 230} : {10, 10, 12}
        case .Water:         return {40, 80, 170}
        case .Moss:          return {70, 140, 40}
        case .Dripstone:     return {170, 140, 100}
        case .Roots:         return {120, 90, 50}
        case .Glow_Mushroom: return {90, 240, 250}
        case .Glow_Moss:     return {90, 255, 190}
        case .Crystal:       return {255, 200, 90}
        case .Fern, .Tall_Grass, .Flower, .Mushroom: return {60, 170, 60}
        case .Grass, .Dry_Grass, .Leaves, .Spruce_Leaves, .Birch_Leaves: return {50, 120, 40}
        case .Dirt:          return {110, 80, 50}
        case .Coal_Ore:      return {150, 60, 60}
        case .Iron_Ore:      return {190, 150, 120}
        case .Gold_Ore:      return {240, 200, 60}
        case .Sand, .Sandstone: return {200, 180, 130}
        }
        return {120, 120, 125}
    }
    write :: proc(path: string, px: []u8, w, h: int) {
        if stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(w), i32(h), 3, raw_data(px), i32(w * 3)) == 0 {
            fmt.eprintln("caves: couldn't write", path)
        } else {
            fmt.println("caves:", path)
        }
    }

    // Vertical: x across, y up (top row = highest).
    Y0, Y1 :: -120, 300
    H :: Y1 - Y0
    px := make([]u8, W * H * 3)
    defer delete(px)
    air, total := 0, 0
    for i in 0 ..< W {
        x := cx - W / 2 + i
        ground := surface_height_at(x, cz)
        for y in Y0 ..< Y1 {
            b := get(&cols, x, y, cz)
            c := color(b, y >= ground)
            if y < ground - 4 { total += 1; if b == 0 { air += 1 } }
            row := Y1 - 1 - y
            px[(row * W + i) * 3 + 0], px[(row * W + i) * 3 + 1], px[(row * W + i) * 3 + 2] = c[0], c[1], c[2]
        }
    }
    write(fmt.tprintf("%s/caves_side.png", dir), px, W, H)
    fmt.printf("caves: %.1f%% of the ground in the slice is hollow\n", 100 * f32(air) / f32(max(total, 1)))

    // Openings to the sky: columns whose top block is gone.
    openings := 0
    for j := 0; j < W; j += 2 {
        for i := 0; i < W; i += 2 {
            x, z := cx - W / 2 + i, cz - W / 2 + j
            h := surface_height_at(x, z)
            if h > SEA_LEVEL && get(&cols, x, h - 1, z) == 0 && get(&cols, x, h - 3, z) == 0 { openings += 1 }
        }
    }
    fmt.printf("caves: %d spots (every 2 blocks) open to the sky in the %d x %d square\n", openings, W, W)

    // Horizontal, at a few heights.
    top := make([]u8, W * W * 3)
    defer delete(top)
    for y in ([]int{SEA_LEVEL - 40, SEA_LEVEL - 10, SEA_LEVEL + 20}) {
        for j in 0 ..< W {
            for i in 0 ..< W {
                x, z := cx - W / 2 + i, cz - W / 2 + j
                c := color(get(&cols, x, y, z), y >= surface_height_at(x, z))
                top[(j * W + i) * 3 + 0], top[(j * W + i) * 3 + 1], top[(j * W + i) * 3 + 2] = c[0], c[1], c[2]
            }
        }
        write(fmt.tprintf("%s/caves_%d.png", dir, y), top, W, W)
    }
}
