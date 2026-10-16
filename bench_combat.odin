package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import "core:strings"
import SDL "vendor:sdl3"

// `bench combat [dir]`: a scripted fight with slimes on the nearest plains
// (three hit combo, dodge, rising slash, air slashes, a plunge, then the
// same from the chase camera), run at a fixed 60 fps with the HUD, saving
// every BENCH_COMBAT_EVERY-th frame as fight_NN.bmp. The window stays hidden.
bench_combat: bool

BENCH_COMBAT_FRAMES :: 300
BENCH_COMBAT_EVERY  :: 3

bench_combat_run :: proc(gs: ^Game_State) {
    ui_init(gs)
    defer ui_shutdown(gs)
    gs_ui_left_pressed_state = &gs.ui
    dir := bench_shot_dir != "" ? bench_shot_dir : "."

    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = int(gs.camera.pos.x), int(gs.camera.pos.z) }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    cam := &gs.camera
    cam.pos = {f32(x) + 0.5, f32(bench_ground(gs, x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5}
    cam.fly_mode, cam.velocity = false, {}
    cam.yaw, cam.pitch = 0, -8
    gs.mouse_locked = true
    gs.ui.help_t = 0
    combat_init(&gs.combat)
    combat_toggle_sword(gs)
    gs.ui.toast_t = 0

    // Slimes in front (+z at yaw 0): a big one to hit, more behind it.
    gs.slimes = {}
    gs.slimes.spawn_timer = 1e9
    put :: proc(gs: ^Game_State, size: Slime_Size, dx, dz: f32, color: int) {
        px, pz := gs.camera.pos.x + dx, gs.camera.pos.z + dz
        y := gs.camera.pos.y - PLAYER_EYE_HEIGHT + 0.3
        if sl := slime_spawn(&gs.slimes, size, {px, y, pz}, {}, SLIME_COLORS[color]); sl != nil {
            sl.age, sl.yaw, sl.timer = 1, math.PI, 0.8
        }
    }
    put(gs, .Big, 0, 3.2, 0)
    put(gs, .Medium, -3, 7, 2)
    put(gs, .Medium, 3.5, 8, 1)
    put(gs, .Small, 1, 11, 3)

    r := gs.ui.renderer_data.renderer
    dt := f32(1.0 / 60)
    shot := 0
    for f in 0 ..< BENCH_COMBAT_FRAMES {
        in_: Combat_Input
        move_left, jump := false, false
        switch f {
        case 8, 24, 40:   in_.attack = true
        case 80:          in_.dodge, in_.move = true, {-1, 0}
        case 105:         in_.special = true
        case 122, 138:    in_.attack = true
        case 175:
            cam.pos.y += 7
            cam.velocity, cam.on_ground = {}, false
            cam.pitch = -70
        case 180:         in_.attack = true
        case 215:
            // The same again from the chase camera.
            cam.pitch = -10
            gs.glider.third_person = true
        case 235, 250, 265: in_.attack = true
        }
        if f >= 80 && f < 86 { move_left = true }

        fx_dt := combat_fx_dt(gs, dt)
        combat_pre_update(gs, in_, dt)
        camera_update(cam, gs, 0, 0, dt, false, false, move_left, false, jump, false, false, false)
        combat_post_update(gs, dt)
        slimes_update(gs, dt)
        fx_update(gs, fx_dt)
        glider_view_update(gs, dt)
        combat_view_update(gs, dt)
        flush_gpu_uploads(gs)
        entities_update(gs, fx_dt)
        if fence := gpu_render(gs, want_fence = true); fence != nil {
            _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
            SDL.ReleaseGPUFence(gs.gpu_device, fence)
        }
        if f % BENCH_COMBAT_EVERY == 0 {
            target := SDL.CreateTexture(r, .RGBA32, .TARGET, 1280, 720)
            _ = SDL.SetRenderTarget(r, target)
            ui_draw(gs, dt) // twice: Clay measures on the first, positions on the second
            ui_draw(gs, 0)
            surf := SDL.RenderReadPixels(r, nil)
            path := fmt.tprintf("%s/fight_%03d.bmp", dir, shot)
            if surf == nil || !SDL.SaveBMP(surf, strings.clone_to_cstring(path, context.temp_allocator)) {
                fmt.eprintln("bench combat: couldn't save", path, SDL.GetError())
            }
            SDL.DestroySurface(surf)
            _ = SDL.SetRenderTarget(r, nil)
            SDL.DestroyTexture(target)
            shot += 1
        }
        free_all(context.temp_allocator)
    }
    c := gs.combat
    fmt.printf("bench combat: best combo %d, %d slimes popped, hp %.0f; wrote %d shots to %s\n", c.best_combo, c.kills, c.hp, shot, dir)
}

// Top solid voxel of the loaded world at (x, z).
bench_ground :: proc(gs: ^Game_State, x, z: int) -> int {
    for y := 200; y > 0; y -= 1 { if solid_at(gs, x, y, z) { return y } }
    return 0
}

// The nearest open, level ground to (x, z): nothing standing on it for a
// few voxels around and ahead (+z).
bench_open_ground :: proc(gs: ^Game_State, x, z: int) -> (int, int) {
    open :: proc(gs: ^Game_State, x, z: int) -> bool {
        g := bench_ground(gs, x, z)
        if g <= SEA_LEVEL { return false }
        for dz in -3 ..= 14 { for dx in -5 ..= 5 {
            gg := bench_ground(gs, x + dx, z + dz)
            if abs(gg - g) > 1 { return false }
        }}
        return true
    }
    for r in 0 ..< 60 {
        for dx in -r ..= r { for dz in -r ..= r {
            if max(abs(dx), abs(dz)) != r { continue }
            if open(gs, x + dx * 4, z + dz * 4) { return x + dx * 4, z + dz * 4 }
        }}
    }
    return x, z
}

// `bench fight`: no pictures. For each enemy kind: one spawned 7 voxels in
// front of a player standing still with the sword out; logs its state
// changes and the player's health: 0-5 s taking the hits, 5-10 s holding
// the guard, 10-15 s raising the guard just before each strike (parries);
// then the player swings at it (facing it) until it dies.
bench_fight: bool

bench_fight_run :: proc(gs: ^Game_State) {
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = 0, 0 }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    cam := &gs.camera
    dt := f32(1.0 / 60.0)
    gs.slimes = {}
    gs.slimes.spawn_timer = 1e9
    for kind in Enemy_Kind {
        for &e in gs.enemies.list { e.alive = false }
        gs.enemies.spawn_timer, gs.enemies.site_timer = 1e9, 1e9
        cam.pos = {f32(x) + 0.5, f32(bench_ground(gs, x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5}
        cam.fly_mode, cam.velocity, cam.yaw, cam.pitch = false, {}, 0, -5
        combat_init(&gs.combat)
        combat_toggle_sword(gs)
        g := bench_ground(gs, x, z + 7) + 1
        e := enemy_spawn(gs, kind, {f32(x) + 0.5, f32(g), f32(z) + 7.5})
        if e == nil { continue }
        e.yaw = math.PI
        last := Enemy_State(255)
        fmt.printf("fight: %v (hp %.0f)\n", kind, e.hp)
        killed_at := f32(-1)
        for f in 0 ..< 60 * 24 {
            t := f32(f) * dt
            in_: Combat_Input
            if t >= 5 && t < 10 { in_.block = true }
            if t >= 10 && t < 15 { in_.block = e.state == .Strike || (e.state == .Windup && e.timer < 0.1) }
            fighting := t >= 15
            if fighting && e.alive && e.state != .Dead {
                to := e.pos - cam.pos
                cam.yaw = math.to_degrees(math.atan2(to.x, to.z))
                in_.attack = f % 18 == 0
            }
            fx_dt := combat_fx_dt(gs, dt)
            combat_pre_update(gs, in_, dt)
            camera_update(cam, gs, 0, 0, dt, false, false, false, false, false, false, false, false)
            combat_post_update(gs, dt)
            enemies_update(gs, dt)
            fx_update(gs, fx_dt)
            combat_view_update(gs, dt)
            if e.state != last {
                fmt.printf("  %5.2fs %v  dist %.1f  player hp %.0f  enemy hp %.0f\n", t, e.state, la.length((e.pos - cam.pos).xz), gs.combat.hp, e.hp)
                last = e.state
            }
            if e.state == .Dead && killed_at < 0 { killed_at = t; fmt.printf("  killed after %.2fs of fighting\n", t - 15) }
            if !e.alive { break }
        }
    }

    // Guards: walk up to each kind of landmark and count what turns up.
    for kind in Landmark_Kind.Tower ..= Landmark_Kind.Camp {
        lm, ok := bench_find_landmark(kind)
        if !ok { continue }
        for &e in gs.enemies.list { e.alive = false }
        clear(&gs.enemies.sites)
        gs.enemies.spawn_timer, gs.enemies.site_timer = 1e9, 0
        bench_teleport(gs, {f32(lm.x) + 30, f32(surface_height_at(lm.x + 30, lm.z)) + 1 + PLAYER_EYE_HEIGHT, f32(lm.z) + 0.5})
        cam.fly_mode = true // hold still (the AI ignores a flying player)
        for _ in 0 ..< 30 {
            gs.enemies.site_timer = 0
            cam.fly_mode = false
            enemies_update(gs, dt)
            cam.fly_mode = true
        }
        counts: [Enemy_Kind]int
        for e in gs.enemies.list { if e.alive && e.guard { counts[e.kind] += 1 } }
        fmt.printf("site %v at %d,%d: guards %v\n", kind, lm.x, lm.z, counts)
    }

    // Night: roaming spawns around the player.
    for &e in gs.enemies.list { e.alive = false }
    gs.day.hour = 23
    day_update(gs, 0)
    cam.fly_mode = false
    gs.enemies.spawn_timer, gs.enemies.site_timer = 0, 1e9
    for _ in 0 ..< 60 * 20 { enemies_update(gs, dt) }
    counts: [Enemy_Kind]int
    rising := 0
    for e in gs.enemies.list { if e.alive { counts[e.kind] += 1; if e.nocturnal { rising += 1 } } }
    fmt.printf("night roamers after 20 s: %v (%d risen from the ground)\n", counts, rising)
}

// `bench nav`: no pictures. Enemies against walls, a raised platform and
// line of sight, on open plains; logs what they do.
bench_nav: bool

bench_nav_run :: proc(gs: ^Game_State) {
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = 0, 0 }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    cam := &gs.camera
    dt := f32(1.0 / 60.0)
    gs.slimes = {}
    gs.slimes.spawn_timer = 1e9
    gy := bench_ground(gs, x, z) + 1 // feet level
    put :: proc(gs: ^Game_State, x, y, z: int, b: Block_Type) {
        dirty: map[int]bool
        changed: [dynamic][3]int
        edit_sphere(gs, {x, y, z}, b, &dirty, &changed, 0)
        delete(dirty); delete(changed)
    }
    clear_area :: proc(gs: ^Game_State, x, z, gy: int, put: proc(^Game_State, int, int, int, Block_Type)) {
        for dz in -4 ..= 16 { for dx in -10 ..= 10 { for dy in 0 ..< 6 { put(gs, x + dx, gy + dy, z + dz, .Air) } } }
    }
    reset :: proc(gs: ^Game_State) {
        for &e in gs.enemies.list { e.alive = false }
        gs.enemies.spawn_timer, gs.enemies.site_timer = 1e9, 1e9
    }
    run :: proc(gs: ^Game_State, e: ^Enemy, seconds: f32, dt: f32) -> (first_strike: f32, closest: f32) {
        first_strike, closest = -1, 1e9
        cam := &gs.camera
        last := e.state
        for f in 0 ..< int(seconds / dt) {
            t := f32(f) * dt
            combat_pre_update(gs, {}, dt)
            camera_update(cam, gs, 0, 0, dt, false, false, false, false, false, false, false, false)
            combat_post_update(gs, dt)
            enemies_update(gs, dt)
            closest = min(closest, la.length((e.pos - (cam.pos - {0, PLAYER_EYE_HEIGHT, 0})).xz))
            if e.state != last {
                fmt.printf("    %5.2fs %v at (%.1f %.1f %.1f)\n", t, e.state, e.pos.x, e.pos.y, e.pos.z)
                last = e.state
            }
            if e.state == .Strike && first_strike < 0 { first_strike = t }
        }
        return
    }
    player_at :: proc(gs: ^Game_State, p: [3]f32) {
        cam := &gs.camera
        cam.pos = p + {0, PLAYER_EYE_HEIGHT, 0}
        cam.fly_mode, cam.velocity = false, {}
        combat_init(&gs.combat)
    }

    // 1) A 3-high wall between them, open at one end: it has to go round.
    clear_area(gs, x, z, gy, put)
    for dx in -6 ..= 4 { for dy in 0 ..< 3 { put(gs, x + dx, gy + dy, z + 5, .Stone) } }
    reset(gs)
    player_at(gs, {f32(x) + 0.5, f32(gy), f32(z) + 0.5})
    for kind in Enemy_Kind {
        reset(gs)
        e := enemy_spawn(gs, kind, {f32(x) + 0.5, f32(gy), f32(z) + 9.5})
        e.state, e.last_seen, e.repath = .Chase, {f32(x) + 0.5, f32(gy), f32(z) + 0.5}, 0
        fmt.printf("wall, %v: knows where you are, wall in between\n", kind)
        fs, cl := run(gs, e, 12, dt)
        fmt.printf("  first strike %.2fs, closest %.1f\n", fs, cl)
    }

    // 2) The player on a 4-high platform, stairs up one side.
    clear_area(gs, x, z, gy, put)
    for dz in 6 ..= 8 { for dx in -1 ..= 1 { for dy in 0 ..< 4 { put(gs, x + dx, gy + dy, z + dz, .Stone) } } }
    for k in 0 ..< 4 { for dy in 0 ..= k { put(gs, x + 2 + 3 - k, gy + dy, z + 7, .Stone) } } // steps from +x
    player_at(gs, {f32(x) + 0.5, f32(gy + 4), f32(z) + 7.5})
    for kind in ([2]Enemy_Kind{.Goblin, .Orc}) {
        reset(gs)
        e := enemy_spawn(gs, kind, {f32(x) + 0.5, f32(gy), f32(z) + 0.5})
        e.state, e.last_seen, e.repath = .Chase, cam.pos - {0, PLAYER_EYE_HEIGHT, 0}, 0
        fmt.printf("platform, %v: player 4 up, stairs on the far side\n", kind)
        fs, cl := run(gs, e, 12, dt)
        fmt.printf("  first strike %.2fs, closest %.1f, ended at height %.1f (player %d)\n", fs, cl, e.pos.y, gy + 4)
    }

    // 3) Sight: idle 10 away behind a wall (doesn't notice), then in the open.
    clear_area(gs, x, z, gy, put)
    for dx in -6 ..= 6 { for dy in 0 ..< 3 { put(gs, x + dx, gy + dy, z + 5, .Stone) } }
    player_at(gs, {f32(x) + 0.5, f32(gy), f32(z) + 0.5})
    reset(gs)
    e := enemy_spawn(gs, .Skeleton, {f32(x) + 0.5, f32(gy), f32(z) + 10.5})
    e.timer = 100 // stands still
    fmt.println("sight: skeleton 10 away behind a wall")
    run(gs, e, 4, dt)
    fmt.printf("  after 4 s: %v\n", e.state)
    for dx in -6 ..= 6 { for dy in 0 ..< 3 { put(gs, x + dx, gy + dy, z + 5, .Air) } }
    fmt.println("  wall gone")
    run(gs, e, 3, dt)
    fmt.printf("  after 3 s more: %v\n", e.state)
}

// `bench crowd`: a crowd around the player (every enemy and slime slot),
// GPU time per frame with and without them, and the CPU time spent posing
// and packing the entity data (the profile dump).
bench_crowd: bool

bench_crowd_run :: proc(gs: ^Game_State) {
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = 0, 0 }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    cam := &gs.camera
    cam.pos = {f32(x) + 0.5, f32(bench_ground(gs, x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5}
    cam.fly_mode, cam.yaw, cam.pitch = true, 0, -12
    gs.slimes, gs.enemies.spawn_timer, gs.enemies.site_timer = {}, 1e9, 1e9
    gs.slimes.spawn_timer = 1e9
    for &e in gs.enemies.list { e.alive = false }
    gs.entities_enabled = false
    fmt.printf("crowd: none        %.2f ms\n", bench_measure(gs))
    gs.entities_enabled = true
    for i in 0 ..< MAX_ENEMIES {
        a := f32(i) / MAX_ENEMIES * 2.4 - 1.2
        r := 5 + f32(i % 4) * 2.5
        px, pz := f32(x) + 0.5 + math.sin(a) * r, f32(z) + 0.5 + math.cos(a) * r
        g := bench_ground(gs, int(math.floor(px)), int(math.floor(pz))) + 1
        if e := enemy_spawn(gs, Enemy_Kind(i % 3), {px, f32(g), pz}); e != nil { e.yaw, e.timer = math.PI, 1e9 }
    }
    for i in 0 ..< MAX_SLIMES {
        a := f32(i) / MAX_SLIMES * 2.4 - 1.2
        r := 4 + f32(i % 5) * 2
        px, pz := f32(x) + 0.5 + math.sin(a) * r, f32(z) + 0.5 + math.cos(a) * r
        g := bench_ground(gs, int(math.floor(px)), int(math.floor(pz))) + 1
        if sl := slime_spawn(&gs.slimes, Slime_Size(i % 3), {px, f32(g), pz}, {}, SLIME_COLORS[i % len(SLIME_COLORS)]); sl != nil { sl.age, sl.timer = 10, 1e9 }
    }
    frame := new(Ent_Frame, context.temp_allocator)
    profile_reset()
    ms := bench_measure(gs)
    // Count what one frame holds.
    enemies_add_parts(gs, frame); slimes_add_parts(gs, frame)
    fmt.printf("crowd: %d enemies + %d slimes: %.2f ms, %d entities / %d parts in the frame\n", MAX_ENEMIES, MAX_SLIMES, ms, frame.n_ents, frame.n_parts)
    profile_dump("crowd")
    if bench_shot_dir != "" { bench_screenshot(gs, fmt.tprintf("%s/crowd.bmp", bench_shot_dir)) }
}
