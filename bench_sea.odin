package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"

// `bench sea [hour=h] [dir]`: views of the sea life (a warm reef, a kelp
// forest) from under the water and from above it, an underwater look up at
// entities over the surface, with GPU time per view and screenshots.
bench_sea: bool

bench_sea_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    x0, z0 := int(cam.pos.x), int(cam.pos.z)

    bench_swim(gs)

    Spot :: struct { name: string, kind: Sea_Kind, min_depth, max_depth: int, patch_seed: i64, patch_scale, patch_min: f64 }
    spots := []Spot{
        {"reef", .Warm,      5, 12, 41, 36, 0.1},
        {"kelp", .Temperate, 12, 26, 42, 60, 0.2},
    }
    for sp in spots {
        x, z, ok := bench_find_sea(x0, z0, sp.kind, sp.min_depth, sp.max_depth, sp.patch_seed, sp.patch_scale, sp.patch_min)
        if !ok { fmt.printf("sea: no %s found\n", sp.name); continue }
        floor := f32(surface_height_at(x, z))
        fmt.printf("sea: %s at %d,%d, floor %.0f\n", sp.name, x, z, floor)
        bench_teleport(gs, {f32(x) + 0.5, floor + 3.5, f32(z) + 0.5})
        cam.yaw, cam.pitch = 40, -8
        // Fish: fill the schools around here and let them swim a moment.
        gs.entities_enabled = true
        for _ in 0 ..< 12 { fish_manage(gs) }
        for _ in 0 ..< 60 { entities_update(gs, 1.0 / 60) }
        nf := 0
        for e in gs.entities { if e.kind == .Fish { nf += 1 } }
        fmt.printf("  %d fish around\n", nf)
        // Close up on the nearest fish, from 3 m.
        best := -1
        for e, i in gs.entities {
            if e.kind != .Fish { continue }
            if best < 0 || la.length(e.pos - cam.pos) < la.length(gs.entities[best].pos - cam.pos) { best = i }
        }
        if best >= 0 {
            saved := cam.pos
            fp := gs.entities[best].pos
            cam.pos = fp + {2.5, 0.8, 1.2}
            d := la.normalize(fp - cam.pos)
            cam.yaw, cam.pitch = math.to_degrees(math.atan2(d.x, d.z)), math.to_degrees(math.asin(d.y))
            // One frame, no timing run: the fish would flee from the camera.
            entities_update(gs, 0)
            gpu_render(gs)
            if bench_shot_dir != "" { bench_screenshot(gs, fmt.tprintf("%s/%s_fish.bmp", bench_shot_dir, sp.name)) }
            cam.pos = saved
            cam.yaw, cam.pitch = 40, -8
        }
        bench_sea_shot(gs, fmt.tprintf("%s under", sp.name), sp.name)
        cam.pitch = 25
        bench_sea_shot(gs, fmt.tprintf("%s looking up", sp.name), fmt.tprintf("%s_up", sp.name))
        cam.pos.y = SEA_LEVEL + 5
        cam.pitch = -45
        bench_sea_shot(gs, fmt.tprintf("%s from above", sp.name), fmt.tprintf("%s_above", sp.name))

        gs.entities_enabled = false
        if sp.kind == .Temperate {
            // Entities over and under the surface, seen from below.
            cam.pos.y = SEA_LEVEL - 4
            cam.pitch = 18
            fwd := camera_flat_forward(cam^)
            gs.entities_enabled = true
            n0 := len(gs.entities)
            for k in 0 ..< 3 {
                p := cam.pos + fwd * f32(5 + 3 * k)
                p.y = k == 1 ? SEA_LEVEL - 2.5 : SEA_LEVEL + 0.2
                append(&gs.entities, Entity{pos = p, kind = .Crystal, scale = 1})
            }
            bench_sea_shot(gs, "entities from below", "entities_below")
            resize(&gs.entities, n0)
            gs.entities_enabled = false
        }
    }
}

@(private="file")
bench_sea_shot :: proc(gs: ^Game_State, what, shot: string) {
    ms := bench_measure(gs)
    fmt.printf("  %-26s %5.2f ms\n", what, ms)
    if bench_shot_dir != "" { bench_screenshot(gs, fmt.tprintf("%s/%s.bmp", bench_shot_dir, shot)) }
}

// Nearest sea of `kind` with its floor min..max deep, inside a patch of
// noise `seed` (scale, above patch_min): a reef or kelp forest.
@(private="file")
bench_find_sea :: proc(x0, z0: int, kind: Sea_Kind, min_depth, max_depth: int, seed: i64, scale, patch_min: f64) -> (x, z: int, ok: bool) {
    for r := 0; r < 20000; r += 48 {
        steps := max(1, r / 24)
        for i in 0 ..< steps {
            a := f64(i) / f64(steps) * math.TAU
            px := x0 + int(math.cos(a) * f64(r)); pz := z0 + int(math.sin(a) * f64(r))
            s := terrain_at(px, pz)
            depth := SEA_LEVEL - s.height
            if depth < min_depth || depth > max_depth || sea_kind(s) != kind { continue }
            if n2(seed, [2]f64{f64(px), f64(pz)} / scale) < patch_min { continue }
            return px, pz, true
        }
    }
    return
}

// Scripted swimming in deep water: float, dive where you look, come back
// up, then swim at a wall whose lip is one or two blocks above the water
// holding Space and climb out onto it. Prints how each part ends.
@(private="file")
bench_swim :: proc(gs: ^Game_State) {
    cam := &gs.camera
    wx, wz, _, _, ok := bench_find_shore(int(cam.pos.x), int(cam.pos.z))
    if !ok { fmt.println("swim: no deep water found"); return }
    start := [3]f32{f32(wx) + 0.5, SEA_LEVEL + 0.3, f32(wz) + 0.5}
    bench_teleport(gs, start)
    cam.fly_mode = false
    cam.velocity = {}
    cam.yaw, cam.pitch = 0, 0
    step :: proc(gs: ^Game_State, secs: f32, fwd, jump_held, sneak: bool) {
        for _ in 0 ..< int(secs * 60) {
            gs.camera.swim_up = jump_held
            camera_update(&gs.camera, gs, 0, 0, 1.0 / 60, fwd, false, false, false, false, false, sneak, false)
        }
    }
    step(gs, 3, false, false, false)
    fmt.printf("swim: idle 3 s, eye %.2f above the surface (want %.2f)\n", cam.pos.y - SEA_LEVEL, SWIM_FLOAT_EYE)
    back := cam.pos
    cam.pitch = -50
    step(gs, 2, true, false, false)
    fmt.printf("swim: 2 s forward looking 50 deg down: %.2f deep, %.1f along\n",
        SEA_LEVEL - cam.pos.y, math.sqrt((cam.pos.x - back.x) * (cam.pos.x - back.x) + (cam.pos.z - back.z) * (cam.pos.z - back.z)))
    cam.pitch = 0
    step(gs, 3, false, false, false)
    fmt.printf("swim: idle 3 s deep down: %.2f deep\n", SEA_LEVEL - cam.pos.y)
    step(gs, 3, false, true, false)
    step(gs, 2, false, false, false)
    fmt.printf("swim: Space 3 s then idle 2 s: eye %.2f above the surface\n", cam.pos.y - SEA_LEVEL)

    // Walls with their top 1 and 2 blocks over the water, 4 ahead.
    for lip in 1 ..= 2 {
        cam.pos, cam.velocity, cam.yaw, cam.pitch = start + {f32(lip) * 12, 0, 0}, {}, 0, 0
        step(gs, 1, false, false, false)
        dirty: map[int]bool
        changed: [dynamic][3]int
        cx, cz := int(math.floor(cam.pos.x)), int(math.floor(cam.pos.z)) + 4
        for x in cx - 2 ..= cx + 2 {
            for y in SEA_LEVEL - 6 ..< SEA_LEVEL + lip {
                for z in cz ..= cz + 2 { edit_sphere(gs, {x, y, z}, .Stone, &dirty, &changed, 0) }
            }
        }
        delete(dirty); delete(changed)
        t := 0
        for ; t < 60 * 8; t += 1 {
            gs.camera.swim_up = true
            camera_update(&gs.camera, gs, 0, 0, 1.0 / 60, true, false, false, false, false, false, false, false)
            if cam.on_ground && cam.pos.y - PLAYER_EYE_HEIGHT >= f32(SEA_LEVEL + lip) - 0.01 { break }
        }
        fmt.printf("swim: climb a lip %d over the water: %s after %.1f s (feet %.2f, top %d)\n", lip,
            t < 60 * 8 ? "OK" : "FAILED", f32(t) / 60, cam.pos.y - PLAYER_EYE_HEIGHT, SEA_LEVEL + lip)
    }
    cam.fly_mode = true
}
