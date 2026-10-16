package main

import "core:fmt"
import "core:math"

// `bench caves [hour=h] [dir]`: inside a cave of each zone (lush, dripstone,
// plain) and at an entrance: the open stretch nearest the zone's middle,
// looked along as it is (dark but for what glows), with a torch in hand,
// and by torches placed ahead.
bench_caves: bool

bench_caves_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    for zone in Cave_Zone {
        zx, zz, found := bench_find_zone(zone)
        if !found { fmt.printf("caves: no %v zone found\n", zone); continue }
        bench_teleport(gs, {f32(zx) + 0.5, f32(surface_height_at(zx, zz)) + 20, f32(zz) + 0.5})
        p, dir, ok := bench_cave_spot(gs, zx, zz)
        if !ok { fmt.printf("caves: no %v cave near %d,%d\n", zone, zx, zz); continue }
        fmt.printf("caves: %v at %d,%d,%d\n", zone, p.x, p.y, p.z)
        bench_teleport(gs, {f32(p.x) + 0.5, f32(p.y) + PLAYER_EYE_HEIGHT, f32(p.z) + 0.5})
        cam.yaw = math.to_degrees(math.atan2(f32(dir.x), f32(dir.y)))
        cam.pitch = -8
        gs.cave_factor = cave_factor_target(gs)
        dark_ms := bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/cave_%v.bmp", bench_shot_dir, zone))
        // A torch in hand.
        held := gs.selected_block
        gs.selected_block = .Torch
        hand_ms := bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/cave_%v_hand.bmp", bench_shot_dir, zone))
        gs.selected_block = held
        // By torchlight: one on the floor a few steps ahead.
        dirty: map[int]bool
        changed: [dynamic][3]int
        for k in 1 ..= 3 {
            ahead := p + {dir.x * 5 * k, 0, dir.y * 5 * k}
            for ahead.y > p.y - 8 && !solid_at(gs, ahead.x, ahead.y - 1, ahead.z) { ahead.y -= 1 }
            if !solid_at(gs, ahead.x, ahead.y, ahead.z) { edit_sphere(gs, ahead, .Torch, &dirty, &changed, 0) }
        }
        light_on_edit(gs, changed[:])
        for slot in dirty { gpu_sync_slot(gs, slot) }
        delete(dirty); delete(changed)
        torch_ms := bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/cave_%v_torch.bmp", bench_shot_dir, zone))
        fmt.printf("caves: %v frame %.2f ms dark, %.2f ms torch in hand, %.2f ms torches placed\n", zone, dark_ms, hand_ms, torch_ms)
    }
    // An entrance: the nearest column open to the sky, looked into from above.
    for r := 0; r < 3000; r += 16 {
        found := false
        for a in 0 ..< max(1, r / 8) {
            t := f64(a) / f64(max(1, r / 8)) * math.TAU
            x, z := int(math.cos(t) * f64(r)), int(math.sin(t) * f64(r))
            h := surface_height_at(x, z)
            if !cave_entrance(x, z, h) { continue }
            bench_teleport(gs, {f32(x) - 10, f32(h) + 12, f32(z) + 0.5})
            if solid_at(gs, x, h - 1, z) || solid_at(gs, x, h - 3, z) || get_voxel(gs, x, h - 1, z) != 0 { continue }
            fmt.printf("caves: entrance at %d,%d\n", x, z)
            cam.yaw, cam.pitch = 90, -40
            gs.cave_factor = 0
            bench_measure(gs)
            bench_screenshot(gs, fmt.tprintf("%s/cave_entrance.bmp", bench_shot_dir))
            found = true
            break
        }
        if found { break }
    }
}

// The nearest point to the origin deep in a zone of caves.
bench_find_zone :: proc(zone: Cave_Zone) -> (x, z: int, ok: bool) {
    for r := 0; r < 20000; r += 64 {
        steps := max(1, r / 32)
        for i in 0 ..< steps {
            a := f64(i) / f64(steps) * math.TAU
            px, pz := int(math.cos(a) * f64(r)), int(math.sin(a) * f64(r))
            if cave_zone(px, pz) == zone && cave_zone(px + 40, pz) == zone && cave_zone(px - 40, pz) == zone &&
               surface_height_at(px, pz) > SEA_LEVEL + 6 {
                return px, pz, true
            }
        }
    }
    return 0, 0, false
}

// A cave floor near (cx, cz) with room to stand, well under the ground,
// and the way along it that's open furthest.
bench_cave_spot :: proc(gs: ^Game_State, cx, cz: int) -> (p: [3]int, dir: [2]int, ok: bool) {
    best := 0
    DIRS :: [8][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
    for dz := -40; dz <= 40; dz += 3 {
        for dx := -40; dx <= 40; dx += 3 {
            x, z := cx + dx, cz + dz
            top := surface_height_at(x, z) - 12
            for y := top; y > CAVE_FLOOR_Y + 2; y -= 1 {
                if !solid_at(gs, x, y - 1, z) || solid_at(gs, x, y, z) || solid_at(gs, x, y + 1, z) || solid_at(gs, x, y + 2, z) || solid_at(gs, x, y + 3, z) { continue }
                for d in DIRS {
                    n := 0
                    for n < 40 && !solid_at(gs, x + d.x * (n + 1), y + 1, z + d.y * (n + 1)) && !solid_at(gs, x + d.x * (n + 1), y + 2, z + d.y * (n + 1)) { n += 1 }
                    if n > best { best, p, dir, ok = n, {x, y, z}, d, true }
                }
                break
            }
        }
    }
    return
}
