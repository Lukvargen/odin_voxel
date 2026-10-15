package main

import "core:fmt"
import "core:math"
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
    // Open ground: nothing standing on it for a few voxels around and ahead.
    ground :: proc(gs: ^Game_State, x, z: int) -> int {
        for y := 200; y > 0; y -= 1 { if solid_at(gs, x, y, z) { return y } }
        return 0
    }
    open :: proc(gs: ^Game_State, x, z: int) -> bool {
        g := ground(gs, x, z)
        if g <= SEA_LEVEL { return false }
        for dz in -3 ..= 14 { for dx in -5 ..= 5 {
            gg := ground(gs, x + dx, z + dz)
            if abs(gg - g) > 1 { return false }
        }}
        return true
    }
    search: for r in 0 ..< 60 {
        for dx in -r ..= r { for dz in -r ..= r {
            if max(abs(dx), abs(dz)) != r { continue }
            if open(gs, x + dx * 4, z + dz * 4) { x, z = x + dx * 4, z + dz * 4; break search }
        }}
    }
    cam := &gs.camera
    cam.pos = {f32(x) + 0.5, f32(ground(gs, x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5}
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
