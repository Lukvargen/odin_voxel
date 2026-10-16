package main

import "core:fmt"
import "core:math"
import "core:strings"
import stbi "vendor:stb/image"

// `odin_raytrace map [file.png] [size] [step]`: the terrain around the
// origin from above, size x size pixels each `step` blocks apart, coloured
// by biome and shaded by slope, with the sea darker the deeper it is; and
// how high it gets. For judging terrain changes without walking them.
terrain_map_export :: proc(path: string, size, step: int) {
    pixels := make([]u8, size * size * 3)
    defer delete(pixels)
    heights := make([]int, size * size)
    defer delete(heights)
    biomes := make([]Biome, size * size)
    defer delete(biomes)
    half := size / 2
    for py in 0 ..< size {
        for px in 0 ..< size {
            s := terrain_at((px - half) * step, (py - half) * step)
            heights[px + py * size] = s.height
            biomes[px + py * size] = s.biome
        }
        free_all(context.temp_allocator)
    }
    top, top_at := min(int), [2]int{}
    count: [Biome]int
    for py in 0 ..< size {
        for px in 0 ..< size {
            i := px + py * size
            h := heights[i]
            count[biomes[i]] += 1
            if h > top { top, top_at = h, {(px - half) * step, (py - half) * step} }
            col := biome_map_color(biomes[i])
            if h < SEA_LEVEL {
                col = math.lerp([3]f32{0.15, 0.35, 0.6}, [3]f32{0.03, 0.08, 0.25}, clamp(f32(SEA_LEVEL - h) / 60, 0, 1))
            } else {
                // Lit from the north-west, by the slope to the neighbours.
                hx := heights[min(px + 1, size - 1) + py * size] - heights[max(px - 1, 0) + py * size]
                hz := heights[px + min(py + 1, size - 1) * size] - heights[px + max(py - 1, 0) * size]
                shade := clamp(1 - f32(hx + hz) / f32(4 * step), 0.45, 1.4)
                col *= shade * (0.8 + 0.4 * clamp(f32(h - SEA_LEVEL) / 300, 0, 1))
            }
            for c, k in col { pixels[i * 3 + k] = u8(clamp(c, 0, 1) * 255) }
        }
    }
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    if stbi.write_png(cpath, i32(size), i32(size), 3, raw_data(pixels), i32(size * 3)) == 0 {
        fmt.eprintln("map: couldn't write", path)
        return
    }
    fmt.printf("map: %s, %d x %d blocks; highest %d at (%d, %d)\n", path, size * step, size * step, top, top_at.x, top_at.y)
    for n, b in count { if n > 0 { fmt.printf("  %-10v %5.1f%%\n", b, 100 * f32(n) / f32(size * size)) } }
}

@(private="file")
biome_map_color :: proc(b: Biome) -> [3]f32 {
    switch b {
    case .Ocean:     return {0.15, 0.35, 0.6}
    case .Beach:     return {0.86, 0.8, 0.55}
    case .River:     return {0.25, 0.5, 0.75}
    case .Plains:    return {0.45, 0.7, 0.3}
    case .Forest:    return {0.2, 0.5, 0.2}
    case .Taiga:     return {0.25, 0.45, 0.38}
    case .Snowy:     return {0.88, 0.92, 0.95}
    case .Desert:    return {0.9, 0.82, 0.5}
    case .Badlands:  return {0.8, 0.45, 0.25}
    case .Mountains: return {0.5, 0.5, 0.48}
    case .Peaks:     return {0.97, 0.97, 1}
    }
    return {1, 0, 1}
}
