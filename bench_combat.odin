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

        world_dt := combat_world_dt(gs, dt)
        combat_pre_update(gs, in_, world_dt)
        camera_update(cam, gs, 0, 0, world_dt, false, false, move_left, false, jump, false, false, false)
        combat_post_update(gs, world_dt)
        slimes_update(gs, world_dt)
        glider_view_update(gs, dt)
        combat_view_update(gs, dt, world_dt)
        flush_gpu_uploads(gs)
        entities_update(gs, world_dt)
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
// changes and the player's health for 5 s; then the player swings at it
// (facing it) until it dies, logging how long that took.
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
        for f in 0 ..< 60 * 14 {
            t := f32(f) * dt
            in_: Combat_Input
            fighting := t >= 5
            if fighting && e.alive && e.state != .Dead {
                to := e.pos - cam.pos
                cam.yaw = math.to_degrees(math.atan2(to.x, to.z))
                in_.attack = f % 18 == 0
            }
            world_dt := combat_world_dt(gs, dt)
            combat_pre_update(gs, in_, world_dt)
            camera_update(cam, gs, 0, 0, world_dt, false, false, false, false, false, false, false, false)
            combat_post_update(gs, world_dt)
            enemies_update(gs, world_dt)
            combat_view_update(gs, dt, world_dt)
            if e.state != last {
                fmt.printf("  %5.2fs %v  dist %.1f  player hp %.0f  enemy hp %.0f\n", t, e.state, la.length((e.pos - cam.pos).xz), gs.combat.hp, e.hp)
                last = e.state
            }
            if e.state == .Dead && killed_at < 0 { killed_at = t; fmt.printf("  killed after %.2fs of fighting\n", t - 5) }
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
