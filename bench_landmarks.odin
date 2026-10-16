package main

import "core:fmt"
import "core:math"

// `bench landmarks [hour=h] [dir]`: the nearest landmark of each kind seen
// from ~30 voxels away, from eye level and from above, plus a cave crystal
// grotto, for judging the ruins in their light.
bench_landmarks: bool

bench_landmarks_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    for kind in Landmark_Kind.Tower ..= Landmark_Kind.Camp {
        lm, found := bench_find_landmark(kind)
        if !found { fmt.printf("landmarks: no %v found\n", kind); continue }
        fmt.printf("landmarks: %v at %d,%d (base %d)\n", kind, lm.x, lm.z, lm.base)
        for view in 0 ..< 2 {
            a := f32(lm.seed % 360)
            d: f32 = view == 0 ? 26 : 40
            p := [3]f32{f32(lm.x) + 0.5 + math.sin(math.to_radians(a)) * d, 0, f32(lm.z) + 0.5 + math.cos(math.to_radians(a)) * d}
            p.y = f32(max(surface_height_at(int(p.x), int(p.z)), lm.base)) + (view == 0 ? 6 : 34)
            bench_teleport(gs, p)
            bench_clear_view(gs)
            to := [3]f32{f32(lm.x) + 0.5, f32(lm.base) + 10, f32(lm.z) + 0.5} - cam.pos
            cam.yaw = math.to_degrees(math.atan2(to.x, to.z))
            cam.pitch = math.to_degrees(math.atan2(to.y, math.sqrt(to.x * to.x + to.z * to.z)))
            bench_measure(gs)
            bench_screenshot(gs, fmt.tprintf("%s/%v_%d.bmp", bench_shot_dir, kind, view))
        }
    }
    bench_crystal_shot(gs, 0, 0)
}

// A cave crystal near (cx, cz), seen from the nearest open spot a few
// voxels away.
bench_crystal_shot :: proc(gs: ^Game_State, cx, cz: int) {
    cam := &gs.camera
    bench_teleport(gs, {f32(cx), f32(surface_height_at(cx, cz)) + 3, f32(cz)})
    for r := 0; r < 160; r += 4 {
        for z in cz - r ..= cz + r {
            for x in cx - r ..= cx + r {
                if max(abs(x - cx), abs(z - cz)) != r { continue }
                for y in CAVE_FLOOR_Y ..< 100 {
                    if get_voxel(gs, x, y, z) != u32(Block_Type.Crystal) { continue }
                    for off in ([][3]int{{5, 2, 0}, {-5, 2, 0}, {0, 2, 5}, {0, 2, -5}, {3, 1, 3}, {-3, 1, -3}, {3, 1, -3}, {-3, 1, 3}}) {
                        p := [3]int{x, y, z} + off
                        if get_voxel(gs, p.x, p.y, p.z) != 0 || get_voxel(gs, p.x, p.y - 1, p.z) != 0 { continue }
                        cam.pos = {f32(p.x) + 0.5, f32(p.y) + 0.5, f32(p.z) + 0.5}
                        to := [3]f32{f32(x) + 0.5, f32(y) + 0.5, f32(z) + 0.5} - cam.pos
                        cam.yaw = math.to_degrees(math.atan2(to.x, to.z))
                        cam.pitch = math.to_degrees(math.atan2(to.y, math.sqrt(to.x * to.x + to.z * to.z)))
                        gs.cave_factor = cave_factor_target(gs)
                        fmt.printf("landmarks: crystal at %d,%d,%d\n", x, y, z)
                        bench_measure(gs)
                        bench_screenshot(gs, fmt.tprintf("%s/Crystal.bmp", bench_shot_dir))
                        return
                    }
                }
            }
        }
    }
    fmt.println("landmarks: no cave crystal found")
}

bench_find_landmark :: proc(kind: Landmark_Kind) -> (Landmark, bool) {
    for r in 0 ..< 40 {
        for cz in -r ..= r {
            for cx in -r ..= r {
                if max(abs(cx), abs(cz)) != r { continue }
                lm := landmark_in_cell(cx, cz)
                if lm.kind == kind { return lm, true }
            }
        }
    }
    return {}, false
}

// `bench slimes [hour=h] [dir]`: one slime of each size and a spread of
// colours lined up on open plains, seen from a few metres, by day and night.
bench_slimes: bool

bench_slimes_run :: proc(gs: ^Game_State) {
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = 0, 0 }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    cam := &gs.camera
    cam.fly_mode = true
    gs.slimes = {}
    gs.slimes.spawn_timer = 1e9
    Put :: struct { size: Slime_Size, dx, dz: f32, color: int }
    puts := []Put{
        {.Big, -2.6, 7, 0}, {.Medium, 0.4, 6.0, 2}, {.Small, 2.2, 5.2, 3},
        {.Medium, 3.8, 8.5, 4}, {.Small, -0.8, 4.4, 1}, {.Big, 5.5, 12, 4},
    }
    for p in puts {
        px, pz := f32(x) + 0.5 + p.dx, f32(z) + 0.5 + p.dz
        g := bench_ground(gs, int(math.floor(px)), int(math.floor(pz))) + 1
        if sl := slime_spawn(&gs.slimes, p.size, {px, f32(g), pz}, {}, SLIME_COLORS[p.color]); sl != nil {
            sl.age, sl.yaw = 10, math.PI
        }
    }
    // Settle them onto the ground (no hops: the timers stay far off).
    for &sl in gs.slimes.list { sl.timer = 1e9 }
    for _ in 0 ..< 60 { sim_sync_local_player(gs); slimes_update(gs, 1.0 / 60.0) }
    cam.pos = {f32(x) + 0.5, f32(bench_ground(gs, x, z)) + 2.6, f32(z) + 0.5}
    cam.yaw, cam.pitch = 15, -12
    bench_measure(gs)
    bench_screenshot(gs, fmt.tprintf("%s/slimes.bmp", bench_shot_dir))
    cam.pos += {1.2, -0.6, 3.2}
    cam.yaw, cam.pitch = 5, -14
    bench_measure(gs)
    bench_screenshot(gs, fmt.tprintf("%s/slimes_close.bmp", bench_shot_dir))
}

// `bench enemies [hour=h] [dir]`: each enemy kind standing, winding up and
// striking, and a fallen skeleton, lined up on open plains.
bench_enemies: bool

bench_enemies_run :: proc(gs: ^Game_State) {
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = 0, 0 }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    cam := &gs.camera
    cam.fly_mode = true
    gs.slimes = {}
    gs.slimes.spawn_timer = 1e9
    base := [3]f32{f32(x) + 0.5, f32(bench_ground(gs, x, z)) + 1, f32(z) + 0.5}
    Row :: struct { name: string, state: Enemy_State, t: f32 }
    rows := []Row{{"idle", .Idle, 0}, {"windup", .Windup, 0.85}, {"strike", .Strike, 0.5}, {"dead", .Dead, 0.6}}
    for row in rows {
      for swing in Swing {
        if (row.state == .Idle || row.state == .Dead) && swing == .Slash { continue }
        for &e in gs.enemies.list { e.alive = false }
        for kind, i in Enemy_Kind {
            px, pz := base.x + f32(i - 1) * 2.4, base.z + 5
            g := bench_ground(gs, int(math.floor(px)), int(math.floor(pz))) + 1
            e := enemy_spawn(gs, kind, {px, f32(g), pz})
            if e == nil { continue }
            e.yaw, e.on_ground, e.state, e.swing = math.PI + 0.35 * f32(i - 1), true, row.state, swing
            sp := ENEMY_SPECS[kind]
            #partial switch row.state {
            case .Windup: e.timer = sp.windup * (1 - row.t)
            case .Strike: e.timer = sp.strike * (1 - row.t)
            case .Dead:   e.death = row.t
            }
        }
        cam.pos = base + {0, 1.5, 0}
        cam.yaw, cam.pitch = 0, -8
        bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/enemies_%s_%v.bmp", bench_shot_dir, row.name, swing))
      }
    }
    // Close-ups: one at a time, a little to the side, half wound up.
    for kind in Enemy_Kind {
        for &e in gs.enemies.list { e.alive = false }
        sp := ENEMY_SPECS[kind]
        px, pz := base.x, base.z + 2.3
        g := bench_ground(gs, int(math.floor(px)), int(math.floor(pz))) + 1
        if e := enemy_spawn(gs, kind, {px, f32(g), pz}); e != nil {
            e.yaw, e.on_ground, e.state, e.timer = math.PI - 0.35, true, .Windup, sp.windup * 0.6
        }
        cam.pos = base + {0, sp.height * 0.8, 0}
        cam.yaw, cam.pitch = 0, -4
        bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/close_%v.bmp", bench_shot_dir, kind))
    }
    // The guard: first person and from behind, an orc winding up in front.
    for &e in gs.enemies.list { e.alive = false }
    {
        px, pz := base.x, base.z + 2.8
        g := bench_ground(gs, int(math.floor(px)), int(math.floor(pz))) + 1
        if e := enemy_spawn(gs, .Orc, {px, f32(g), pz}); e != nil {
            e.yaw, e.on_ground, e.state, e.timer, e.swing = math.PI, true, .Windup, ENEMY_SPECS[.Orc].windup * 0.3, .Overhead
        }
    }
    cam.fly_mode = false
    cam.pos = base + {0, PLAYER_EYE_HEIGHT, 0}
    cam.yaw, cam.pitch = 0, 4
    combat_init(&gs.combat)
    combat_toggle_sword(gs)
    gs.combat.blocking, gs.combat.guard = true, 1
    for view in 0 ..< 2 {
        gs.glider.third_person = view == 1
        for _ in 0 ..< 30 { glider_view_update(gs, 1.0 / 60.0); combat_view_update(gs, 1.0 / 60.0) }
        gs.combat.guard = 1
        combat_view_update(gs, 0)
        bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/guard_%d.bmp", bench_shot_dir, view))
    }
    gs.glider.third_person = false
}
