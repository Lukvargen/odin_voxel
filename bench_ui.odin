package main

import "core:fmt"
import "core:strings"
import SDL "vendor:sdl3"

// `bench ui [dir]`: screenshots of the HUD, the glider instruments and each
// pause-menu tab, drawn offscreen (the window stays hidden) at two sizes.
bench_ui: bool

bench_ui_run :: proc(gs: ^Game_State) {
    ui_init(gs)
    defer ui_shutdown(gs)
    gs_ui_left_pressed_state = &gs.ui
    dir := bench_shot_dir != "" ? bench_shot_dir : "."

    gs.camera.fly_mode = false
    gs.camera.pitch = -28
    gs.mouse_locked = true
    hotbar_select(gs, 0)
    gs.entities_enabled = false

    Shot :: struct { name: string, setup: proc(gs: ^Game_State) }
    shots := []Shot{
        {"hud_start", proc(gs: ^Game_State) { gs.ui.block_name_t = 1; ui_toast(gs, "Brush: radius 3") }},
        {"hud", proc(gs: ^Game_State) { gs.ui.help_t = 0; gs.ui.toast_t = 0; gs.ui.block_name_t = 0; hotbar_select(gs, 2); gs.brush_radius = 3 }},
        {"hud_debug", proc(gs: ^Game_State) { gs.ui.debug_open = true; gs.glider.equipped = true }},
        {"glider", proc(gs: ^Game_State) {
            gs.ui.debug_open = false
            g := &gs.glider
            g.deployed, g.airspeed, g.vario, g.agl, g.lift_here, g.stall = true, 11.5, 1.8, 84, 1.2, 0.4
            g.aim_yaw, g.aim_pitch, g.heading = gs.camera.yaw + 6, -8, gs.camera.yaw
            gs.camera.velocity = {3, -1, 10}
        }},
        {"menu_graphics", proc(gs: ^Game_State) {
            gs.glider.deployed, gs.glider.equipped = false, false
            ui_open(gs, .Pause)
            gs.ui.menu_tab = .Graphics
        }},
        {"menu_sound", proc(gs: ^Game_State) { gs.ui.menu_tab = .Sound }},
        {"menu_controls", proc(gs: ^Game_State) { gs.ui.menu_tab = .Controls }},
        {"menu_multiplayer", proc(gs: ^Game_State) { gs.ui.menu_tab = .Multiplayer }},
        {"inventory", proc(gs: ^Game_State) {
            ui_open(gs, .Inventory)
            gs.ui.mouse_pos = {640 - 30, 360 - 60} // over a block (the tooltip) at 1280x720
        }},
    }
    sizes := [][2]i32{{1280, 720}, {800, 800}}

    r := gs.ui.renderer_data.renderer
    for sh in shots {
        sh.setup(gs)
        flush_gpu_uploads(gs)
        entities_update(gs, 1.0 / 60.0)
        if fence := gpu_render(gs, want_fence = true); fence != nil {
            _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
            SDL.ReleaseGPUFence(gs.gpu_device, fence)
        }
        for sz in sizes {
            target := SDL.CreateTexture(r, .RGBA32, .TARGET, sz.x, sz.y)
            _ = SDL.SetRenderTarget(r, target)
            // Two layouts: Clay measures on the first and positions on the second.
            ui_draw(gs, 1.0 / 60.0)
            ui_draw(gs, 0)
            surf := SDL.RenderReadPixels(r, nil)
            path := fmt.tprintf("%s/ui_%s_%dx%d.bmp", dir, sh.name, sz.x, sz.y)
            if surf == nil || !SDL.SaveBMP(surf, strings.clone_to_cstring(path, context.temp_allocator)) {
                fmt.eprintln("bench ui: couldn't save", path, SDL.GetError())
            }
            SDL.DestroySurface(surf)
            _ = SDL.SetRenderTarget(r, nil)
            SDL.DestroyTexture(target)
        }
        free_all(context.temp_allocator)
    }
    ui_open(gs, .None)
    fmt.println("bench ui: wrote screenshots to", dir)
}
