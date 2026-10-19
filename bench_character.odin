package main

import "core:fmt"
import "core:math"
import SDL "vendor:sdl3"

// `bench character [dir]`: the Character screen (character_screen.odin) on
// open plains: the view swung round in front of the body, the panel beside
// it, in a few of the presets; then closed, and the view back at the eyes
// as it was. Writes character_menu.bmp (the pause menu it opens from) and
// character_<n>.bmp. Never keeps a look (LOOK_FILE is
// yours).
bench_character: bool

bench_character_run :: proc(gs: ^Game_State) {
    ui_init(gs)
    defer ui_shutdown(gs)
    look_keep = false
    cam := &gs.camera
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = int(cam.pos.x), int(cam.pos.z) }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    cam.pos = {f32(x) + 0.5, f32(bench_ground(gs, x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5}
    cam.fly_mode, cam.velocity, cam.yaw, cam.pitch = true, {}, 30, -12
    gs.player_anim.body_yaw = -math.to_radians(cam.yaw)
    day_set_hour(gs, 10, settle = true)

    step :: proc(gs: ^Game_State, frames: int) {
        for _ in 0 ..< frames {
            glider_view_update(gs, 1.0 / 60)
            character_view_update(gs, 1.0 / 60)
            flush_gpu_uploads(gs)
            entities_update(gs, 1.0 / 60)
            if fence := gpu_render(gs, want_fence = true); fence != nil {
                _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
                SDL.ReleaseGPUFence(gs.gpu_device, fence)
            }
            free_all(context.temp_allocator)
        }
    }
    step(gs, 60)
    yaw, pitch := cam.yaw, cam.pitch
    // From the pause menu, as a player gets there.
    ui_open(gs, .Pause)
    bench_hud_shot(gs, fmt.tprintf("%s/character_menu.bmp", bench_shot_dir))
    character_open(gs)
    for i in ([]int{0, 1, 2, 4}) {
        gs.look = look_apply_preset(gs.look, LOOK_PRESETS[i])
        step(gs, i == 0 ? 120 : 30)
        path := fmt.tprintf("%s/character_%d.bmp", bench_shot_dir, i)
        bench_hud_shot(gs, path)
        fmt.printf("bench character: %s wrote %s\n", LOOK_PRESETS[i].name, path)
    }
    ui_open(gs, .None)
    step(gs, 90)
    back := cam.view_turn == {} && cam.yaw == yaw && cam.pitch == pitch && gs.ui.portrait.k == 0
    fmt.printf("bench character: closed, the view back at the eyes: %v\n", back)
}
