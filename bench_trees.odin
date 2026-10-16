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
        {"savanna", proc(s: Terrain_Sample, x, z: int) -> bool { return s.biome == .Savanna }},
        {"river", proc(s: Terrain_Sample, x, z: int) -> bool {
            if s.biome != .Plains && s.biome != .Forest || s.wet < 0.5 || s.height > SEA_LEVEL + 10 { return false }
            r := terrain_at(x + 12, z) // the river itself close by
            return r.biome == .River || r.height < SEA_LEVEL
        }},
    }
    for spot in spots {
        x, z, found := bench_find_spot(spot.want, near_only = spot.name == "river")
        if !found { fmt.printf("trees: no %s found\n", spot.name); continue }
        fmt.printf("trees: %s at %d,%d\n", spot.name, x, z)
        for view in 0 ..< 2 {
            g := f32(surface_height_at(x, z))
            at := [3]f32{f32(x) + 0.5, g, f32(z) + 0.5}
            if view == 0 {
                bench_teleport(gs, at + {0, 4, 0})
                cam.yaw, cam.pitch = 35, 2
            } else {
                // From back and above, looking down at it.
                back := [3]f32{-math.sin(math.to_radians(f32(35))), 0, -math.cos(math.to_radians(f32(35)))} * 25
                bench_teleport(gs, at + back + {0, 60, 0})
                cam.yaw, cam.pitch = 35, -math.to_degrees(math.atan2(f32(60), f32(25)))
            }
            bench_clear_view(gs)
            bench_measure(gs)
            bench_screenshot(gs, fmt.tprintf("%s/trees_%s_%d.bmp", bench_shot_dir, spot.name, view))
        }
    }
    // Single trees from the side: the nearest of each kind to the origin.
    for kind in ([]Tree_Kind{.Willow, .Acacia, .Medium_Oak, .Birch, .Dead}) {
        x, z, base, found := bench_find_tree(kind)
        if !found { fmt.printf("trees: no %v found\n", kind); continue }
        fmt.printf("trees: a %v at %d,%d\n", kind, x, z)
        at := [3]f32{f32(x) + 0.5, f32(base), f32(z) + 0.5}
        bench_teleport(gs, at + {-26, 10, -10})
        bench_clear_view(gs)
        to := at + {0, 8, 0} - cam.pos
        cam.yaw = math.to_degrees(math.atan2(to.x, to.z))
        cam.pitch = math.to_degrees(math.atan2(to.y, math.sqrt(to.x * to.x + to.z * to.z)))
        bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/tree_%v.bmp", bench_shot_dir, kind))
    }
}

// Where the nearest tree of `kind` to the origin stands, by asking the
// generator over spots outward.
bench_find_tree :: proc(kind: Tree_Kind) -> (x, z, base: int, ok: bool) {
    CELL :: 64
    for ring in 0 ..< 100 {
        for cz in -ring ..= ring {
            for cx in -ring ..= ring {
                if max(abs(cx), abs(cz)) != ring { continue }
                ox, oz := cx * CELL, cz * CELL
                lat := tree_lattice(ox, oz, CELL)
                for wz in oz ..< oz + CELL {
                    for wx in ox ..< ox + CELL {
                        if k, b := tree_at(&lat, wx, wz); k == kind { return wx, wz, b, true }
                    }
                }
                free_all(context.temp_allocator)
            }
        }
    }
    return 0, 0, 0, false
}

// Whether broadleaves at (x, z) are in an autumn patch (world.odin tree_leaves).
bench_autumn :: proc(x, z: int) -> bool {
    return n2(61, [2]f64{f64(x), f64(z)} / (420 * TERRAIN_SCALE)) > 0.45
}

// The nearest point (searching outward) where `want` holds all around it
// (or just there: near_only).
bench_find_spot :: proc(want: proc(s: Terrain_Sample, x, z: int) -> bool, near_only := false) -> (x, z: int, ok: bool) {
    for r := 0; r < 20000; r += 96 {
        steps := max(1, r / 32)
        for i in 0 ..< steps {
            a := f64(i) / f64(steps) * 6.283185
            px := int(math.cos(a) * f64(r)); pz := int(math.sin(a) * f64(r))
            if want(terrain_at(px, pz), px, pz) && (near_only || want(terrain_at(px + 36, pz), px + 36, pz) &&
               want(terrain_at(px - 36, pz), px - 36, pz) && want(terrain_at(px, pz + 36), px, pz + 36)) {
                return px, pz, true
            }
        }
    }
    return 0, 0, false
}
