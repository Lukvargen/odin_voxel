package main

import "core:fmt"
import "core:strings"
import "core:time"
import SDL "vendor:sdl3"

// `bench build [dir]`: the building tools on the nearest plains. Stamps each
// shape in a row, fills and clears big areas (timed), undoes it all and
// checks the ground came back, and saves screenshots with the HUD and the
// tool previews. The window stays hidden.
bench_build: bool

bench_build_run :: proc(gs: ^Game_State) {
    ui_init(gs)
    defer ui_shutdown(gs)
    dir := bench_shot_dir != "" ? bench_shot_dir : "."

    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = int(gs.camera.pos.x), int(gs.camera.pos.z) }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 14, f32(z) + 0.5})
    ground := top_solid(gs, x, z)
    gs.camera.fly_mode = true
    gs.camera.yaw, gs.camera.pitch = 0, -30
    gs.mouse_locked = true
    gs.entities_enabled = false
    gs.ui.help_t = 0
    hotbar_select(gs, 2) // stone
    b := &gs.build

    // What the edits will touch, to check undo brings it all back.
    LO :: [3]int{-120, -50, -40}
    HI :: [3]int{120, 60, 200}
    checksum :: proc(gs: ^Game_State, c: [3]int) -> u64 {
        h: u64 = 1469598103934665603
        for zz in LO.z ..= HI.z { for xx in LO.x ..= HI.x { for yy in LO.y ..= HI.y {
            h = (h ~ u64(get_voxel(gs, c.x + xx, c.y + yy, c.z + zz))) * 1099511628211
        }}}
        return h
    }
    base := [3]int{x, ground, z}
    // A flat pad to build on, made before the undo check starts.
    for z0 := -60; z0 < 220; z0 += 70 {
        build_apply(gs, Edit_Region{lo = base + {-130, 1, z0}, hi = base + {130, 70, z0 + 69}}, .Air, .All)
        build_apply(gs, Edit_Region{lo = base + {-130, -4, z0}, hi = base + {130, 0, z0 + 69}}, .Grass, .All)
    }
    for &r in b.undo { delete(r.changes) }
    clear(&b.undo)
    b.undo_voxels = 0
    gs.camera.pos.y = f32(ground) + 16
    before := checksum(gs, base)

    shot :: proc(gs: ^Game_State, dir, name: string) {
        flush_gpu_uploads(gs)
        if fence := gpu_render(gs, want_fence = true); fence != nil {
            _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
            SDL.ReleaseGPUFence(gs.gpu_device, fence)
        }
        r := gs.ui.renderer_data.renderer
        target := SDL.CreateTexture(r, .RGBA32, .TARGET, 1280, 720)
        _ = SDL.SetRenderTarget(r, target)
        ui_draw(gs, 1.0 / 60.0) // Clay measures on the first layout, positions on the second
        ui_draw(gs, 0)
        surf := SDL.RenderReadPixels(r, nil)
        path := fmt.tprintf("%s/build_%s.bmp", dir, name)
        if surf == nil || !SDL.SaveBMP(surf, strings.clone_to_cstring(path, context.temp_allocator)) {
            fmt.eprintln("bench build: couldn't save", path, SDL.GetError())
        }
        SDL.DestroySurface(surf)
        _ = SDL.SetRenderTarget(r, nil)
        SDL.DestroyTexture(target)
        free_all(context.temp_allocator)
    }
    timed :: proc(gs: ^Game_State, what: string, r: Edit_Region, block: Block_Type, mask := Build_Mask.All) {
        t0 := time.tick_now()
        n := build_apply(gs, r, block, mask)
        fmt.printf("bench build: %-28s %8d voxels  %7.1f ms\n", what, n, time.duration_milliseconds(time.tick_since(t0)))
    }
    fwd := camera_flat_forward(gs.camera)
    ahead := proc(gs: ^Game_State, base: [3]int, fwd: [3]f32, d: f32, side: int) -> [3]int {
        p := [3]int{base.x + int(fwd.x * d) + side * int(fwd.z), 0, base.z + int(fwd.z * d) - side * int(fwd.x)}
        p.y = top_solid(gs, p.x, p.z) + 1
        return p
    }

    // The previews.
    b.tool, b.shape, b.size, b.height = .Shape, .Sphere, 5, 5
    shot(gs, dir, "preview_sphere")
    b.shape, b.yaw, b.wall = .Pyramid, 30, 2
    bench_hud_mods = Mods{.Shift}
    shot(gs, dir, "preview_pyramid")
    bench_hud_mods = nil
    b.yaw, b.wall = 0, 0

    // A row of every shape, standing on the ground across the view.
    i := 0
    for kind in Build_Shape {
        c := ahead(gs, base, fwd, 34, (i - 3) * 15)
        s, h := 6, 6
        if kind == .Torus { h = 2 }
        if kind == .Cone || kind == .Pyramid { h = 8 }
        c.y += h
        timed(gs, fmt.tprintf("shape %s", build_shape_name(kind)), shape_region(kind, c, s, h, 0, kind == .Box ? 30 : 0), .Sandstone)
        i += 1
    }
    // A hollow box with a door carved in, and a dome painted over the ground.
    room := ahead(gs, base, fwd, 60, 0)
    room.y += 6
    timed(gs, "hollow box 21^3 walls 1", shape_region(.Box, room, 10, 6, 1, 0), .Stone)
    timed(gs, "door", Edit_Region{lo = room + {-1, -5, -12}, hi = room + {1, -2, 12}}, .Air)
    timed(gs, "paint dome", shape_region(.Dome, ahead(gs, base, fwd, 34, 0) + {0, 0, 0}, 14, 3, 0, 0), .Snow, .Solid)
    gs.camera.pitch = -22
    shot(gs, dir, "shapes")
    {
        saved := gs.camera
        c := ahead(gs, base, fwd, 40, 0)
        gs.camera.pos = {f32(c.x) + 0.5, f32(c.y) + 75, f32(c.z) + 0.5}
        gs.camera.pitch = -89.9
        shot(gs, dir, "shapes_top")
        gs.camera = saved
    }

    // Area drag preview: a 30 x 30 patch, 8 layers, walls 1.
    b.tool, b.layers, b.wall = .Area, 8, 1
    b.dragging, b.drag_fill, b.drag_n = true, true, {0, 1, 0}
    b.drag_a = ahead(gs, base, fwd, 20, -15)
    b.drag_b = ahead(gs, base, fwd, 50, 15)
    b.drag_b.y = b.drag_a.y
    shot(gs, dir, "preview_area")
    build_apply(gs, area_region(b), gs.selected_block, .All)
    b.dragging = false
    shot(gs, dir, "area_walls")

    // Big ones, timed.
    b.wall = 0
    fill_c := ahead(gs, base, fwd, 120, 0)
    timed(gs, "area fill 101x31x101", Edit_Region{lo = fill_c + {-50, 0, -50}, hi = fill_c + {50, 30, 50}}, .Terracotta)
    clr := [3]int{base.x, ground, base.z}
    timed(gs, "area clear 161x41x161", Edit_Region{lo = clr + {-80, -40, -80}, hi = clr + {80, 0, 80}}, .Air)
    timed(gs, "sphere r60 clear", sphere_region(clr + {0, -10, 100}, 60), .Air)
    timed(gs, "too big (refused)", Edit_Region{lo = clr, hi = clr + {300, 300, 300}}, .Stone)
    gs.camera.pitch = -40
    shot(gs, dir, "big")

    // Undo everything, check it's all back, then redo one.
    t0 := time.tick_now()
    n := 0
    for len(b.undo) > 0 {
        build_key(gs, SDL.K_Z, {.Ctrl})
        n += 1
    }
    fmt.printf("bench build: undid %d edits in %.1f ms\n", n, time.duration_milliseconds(time.tick_since(t0)))
    after := checksum(gs, base)
    fmt.println("bench build: undo restored the world:", after == before ? "yes" : "NO")
    build_key(gs, SDL.K_Y, {.Ctrl})
    fmt.println("bench build: redo stack", len(b.redo), "undo stack", len(b.undo))
    b.tool = .Block
    shot(gs, dir, "undone")
    bench_build_keys(gs)
    fmt.println("bench build: wrote screenshots to", dir)
}

// The highest solid voxel of a column (bench: the ground, trees included).
@(private="file")
top_solid :: proc(gs: ^Game_State, x, z: int) -> int {
    for y := 250; y > WORLD_Y_MIN; y -= 1 { if solid_at(gs, x, y, z) { return y } }
    return 0
}

// The modifier rules: a Ctrl or Alt combo never does the plain action.
@(private="file")
bench_build_keys :: proc(gs: ^Game_State) {
    b := &gs.build
    fails := 0
    check :: proc(fails: ^int, ok: bool, what: string) {
        if !ok { fails^ += 1; fmt.println("bench build: KEYS FAIL:", what) }
    }
    b.tool = .Block
    hotbar_select(gs, 2)
    gs.brush_radius = 0
    build_wheel(gs, -1, {.Ctrl})
    check(&fails, gs.hotbar_slot == 2, "Ctrl+wheel changed the hotbar")
    build_wheel(gs, 1, {.Ctrl})
    check(&fails, gs.brush_radius == 1, "Ctrl+wheel up didn't grow the brush")
    build_wheel(gs, -1, {.Alt})
    check(&fails, gs.hotbar_slot == 2 && gs.brush_radius == 1, "Alt+wheel did something in Block")
    build_wheel(gs, -1, {})
    check(&fails, gs.hotbar_slot == 3, "plain wheel down didn't go to the next slot")
    build_wheel(gs, 1, {.Shift})
    check(&fails, gs.hotbar_slot == 2, "Shift+wheel (sneaking) didn't walk the hotbar")
    check(&fails, !build_key(gs, SDL.K_Z, {}), "plain Z undid")
    check(&fails, !build_key(gs, SDL.K_T, {.Ctrl}), "Ctrl+T switched tool")
    check(&fails, b.tool == .Block, "tool changed")
    check(&fails, build_key(gs, SDL.K_T, {.Shift}) && b.tool == .Shape, "Shift+T didn't go back to Shape")
    s0, h0 := b.size, b.height
    build_wheel(gs, 1, {.Ctrl, .Shift})
    check(&fails, b.size == s0 && b.height == h0 && b.wall == 0, "Ctrl+Shift+wheel did something")
    build_wheel(gs, 1, {.Shift})
    check(&fails, b.size == s0 && b.height == h0 + 1, "Shift+wheel isn't height alone")
    build_wheel(gs, 1, {})
    check(&fails, b.size == s0 + 1 && b.height == h0 + 2, "wheel isn't size")
    build_wheel(gs, 2, {.Alt})
    check(&fails, b.yaw == 2 * YAW_STEP, "Alt+wheel isn't turn")
    build_wheel(gs, -1, {.Ctrl})
    check(&fails, b.wall == 0, "walls went below 0")
    check(&fails, !build_key(gs, SDL.K_Q, {.Alt}), "Alt+Q changed shape")
    b.tool = .Area
    l0 := b.layers
    build_wheel(gs, 1, {.Shift})
    check(&fails, b.layers == l0 + 1, "Shift+wheel isn't layers in Area")
    build_wheel(gs, 1, {.Alt})
    check(&fails, b.layers == l0 + 1, "Alt+wheel changed layers")
    fmt.printf("bench build: modifier checks %s (%d failed)\n", fails == 0 ? "passed" : "FAILED", fails)
}
