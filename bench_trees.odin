package main

import "core:fmt"
import "core:math"

// `bench trees [hour=h] [dir]`: woods of each kind seen from a little above
// the canopy, for judging tree generation: a warm forest, a birch wood (a
// cool forest), an autumn patch, taiga and plains.
bench_trees: bool

bench_trees_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    Spot :: struct { name: string, want: proc(s: Terrain_Sample, x, z: int) -> bool }
    spots := [?]Spot{
        {"forest", proc(s: Terrain_Sample, x, z: int) -> bool { return s.biome == .Forest && s.temp > 0.1 && !bench_autumn(x, z) }},
        {"birch", proc(s: Terrain_Sample, x, z: int) -> bool { return s.biome == .Forest && s.temp < -0.05 && !bench_autumn(x, z) }},
        {"autumn", proc(s: Terrain_Sample, x, z: int) -> bool { return s.biome == .Forest && bench_autumn(x, z) }},
        {"taiga", proc(s: Terrain_Sample, x, z: int) -> bool { return s.biome == .Taiga }},
        {"plains", proc(s: Terrain_Sample, x, z: int) -> bool { return s.biome == .Plains }},
    }
    for spot in spots {
        x, z, found := bench_find_spot(spot.want)
        if !found { fmt.printf("trees: no %s found\n", spot.name); continue }
        fmt.printf("trees: %s at %d,%d\n", spot.name, x, z)
        for view in 0 ..< 2 {
            g := f32(surface_height_at(x, z))
            bench_teleport(gs, {f32(x) + 0.5, g + (view == 0 ? 4 : 40), f32(z) + 0.5})
            bench_clear_view(gs)
            cam.yaw, cam.pitch = 35, view == 0 ? 2 : -22
            bench_measure(gs)
            bench_screenshot(gs, fmt.tprintf("%s/trees_%s_%d.bmp", bench_shot_dir, spot.name, view))
        }
    }
}

// Whether broadleaves at (x, z) are in an autumn patch (world.odin tree_leaves).
bench_autumn :: proc(x, z: int) -> bool {
    return n2(61, [2]f64{f64(x), f64(z)} / (420 * TERRAIN_SCALE)) > 0.45
}

// The nearest point (searching outward) where `want` holds all around it.
bench_find_spot :: proc(want: proc(s: Terrain_Sample, x, z: int) -> bool) -> (x, z: int, ok: bool) {
    for r := 0; r < 20000; r += 96 {
        steps := max(1, r / 32)
        for i in 0 ..< steps {
            a := f64(i) / f64(steps) * 6.283185
            px := int(math.cos(a) * f64(r)); pz := int(math.sin(a) * f64(r))
            if want(terrain_at(px, pz), px, pz) && want(terrain_at(px + 36, pz), px + 36, pz) &&
               want(terrain_at(px - 36, pz), px - 36, pz) && want(terrain_at(px, pz + 36), px, pz + 36) {
                return px, pz, true
            }
        }
    }
    return 0, 0, false
}
