package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import SDL "vendor:sdl3"

// GPU benchmark: `odin run . -- bench`. Runs in a hidden, unfocusable window,
// streams the full load radius, then renders fixed camera views under a set
// of quality configs and prints the median GPU frame time of each. Frames are
// fenced one at a time, so the time is the GPU cost of one frame (no vsync,
// no UI pass).

BENCH_WARMUP_FRAMES  :: 40
BENCH_MEASURE_FRAMES :: 60

Bench_View :: struct {
    name:        string,
    height:      f32,  // eye height above the terrain surface
    yaw, pitch:  f32,
    torches:     bool, // ring of torches on the ground in front of the camera
    cave:        bool, // sealed room carved underground, lit by one torch
}

Bench_Config :: struct {
    name:   string,
    aa:     i32,
    shadow: i32,
    vol:    bool,
}

// Directory for one screenshot per view (of the first config); "" = none.
bench_shot_dir: string
// Only measure the first (default) config.
bench_quick: bool

bench_run :: proc(gs: ^Game_State) {
    views := []Bench_View{
        {"horizon",    2,   30, -5,  false, false},
        {"vista",      45,  30, -25, false, false},
        {"torches",    2,   30, -30, true,  false},
        {"cave",       -30, 30, -20, false, true},
        {"canopy",     2,   30, 20,  false, false},
    }
    configs := []Bench_Config{
        {"default (aa1 hard)", 1, 1, false},
        {"soft shadows",       1, 3, false},
        {"aa2",                2, 1, false},
        {"volumetric",         1, 1, true},
        {"all on",             2, 3, true},
    }

    // Stream the whole load radius before measuring.
    t0 := time.now()
    enqueue_chunks(gs)
    for !streaming_idle(gs) {
        integrate_ready_chunks(gs)
        stitch_pending_columns(gs)
        flush_gpu_uploads(gs)
        if time.duration_seconds(time.since(t0)) > 120 {
            fmt.println("bench: streaming did not finish in 120 s, measuring anyway")
            break
        }
        time.sleep(time.Millisecond)
    }
    fmt.printf("bench: world streamed in %.1f s\n", time.duration_seconds(time.since(t0)))

    gs.camera.fly_mode = true
    for v in views {
        sx := 0; sz := 0
        surf := f32(surface_height_at(sx, sz))
        gs.camera.pos   = {f32(sx) + 0.5, surf + v.height, f32(sz) + 0.5}
        gs.camera.yaw   = v.yaw
        gs.camera.pitch = v.pitch
        gs.player_chunk = {
            floor_div(int(gs.camera.pos.x), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.y), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.z), CHUNK_VOXELS),
        }
        if v.torches { bench_place_torches(gs) }
        if v.cave    { bench_carve_cave(gs) }
        // Underground fog/darkness, as the game loop computes it.
        depth_below := surf - gs.camera.pos.y
        gs.cave_factor = clamp((depth_below - 6.0) / 18.0, 0.0, 1.0)

        fmt.printf("\nview %-8s  pos (%.0f %.0f %.0f)\n", v.name,
            gs.camera.pos.x, gs.camera.pos.y, gs.camera.pos.z)
        for c, ci in configs {
            if bench_quick && ci > 0 { break }
            gs.aa_samples  = c.aa
            gs.shadow_rays = c.shadow
            gs.vol_enabled = c.vol
            ms := bench_measure(gs)
            fmt.printf("  %-28s %6.2f ms  (%5.1f fps)\n", c.name, ms, 1000.0 / ms)
            if bench_shot_dir != "" && c.name == configs[0].name {
                bench_screenshot(gs, fmt.tprintf("%s/%s.bmp", bench_shot_dir, v.name))
            }
        }
    }
}

// Median GPU time of one frame, in ms.
bench_measure :: proc(gs: ^Game_State) -> f64 {
    samples: [BENCH_MEASURE_FRAMES]f64
    for i in 0 ..< BENCH_WARMUP_FRAMES + BENCH_MEASURE_FRAMES {
        flush_gpu_uploads(gs)
        entities_update(gs, 1.0 / 60.0)
        t := time.tick_now()
        fence := gpu_render(gs, want_fence = true)
        if fence != nil {
            _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
            SDL.ReleaseGPUFence(gs.gpu_device, fence)
        }
        if i >= BENCH_WARMUP_FRAMES {
            samples[i - BENCH_WARMUP_FRAMES] = time.duration_milliseconds(time.tick_since(t))
        }
    }
    slice.sort(samples[:])
    return samples[BENCH_MEASURE_FRAMES / 2]
}

// Eight torches in a ring on the ground ~10 voxels ahead of the camera.
bench_place_torches :: proc(gs: ^Game_State) {
    fwd := camera_flat_forward(gs.camera)
    cx := gs.camera.pos.x + fwd.x * 10
    cz := gs.camera.pos.z + fwd.z * 10
    dirty: map[int]bool
    defer delete(dirty)
    changed: [dynamic][3]int
    defer delete(changed)
    offsets := [8][2]int{{-4, -4}, {0, -4}, {4, -4}, {-4, 0}, {4, 0}, {-4, 4}, {0, 4}, {4, 4}}
    for o in offsets {
        ox, oz := o[0], o[1]
        wx := int(cx) + ox
        wz := int(cz) + oz
        top, _, ok := raycast_voxel(gs, {f32(wx) + 0.5, gs.camera.pos.y, f32(wz) + 0.5}, {0, -1, 0}, 60)
        if !ok { continue }
        key := [3]int{top[0], top[1] + 1, top[2]}
        edit_sphere(gs, key, .Torch, &dirty, &changed, 0)
    }
    light_on_edit(gs, changed[:])
    for slot in dirty {
        if refresh_chunk_index(gs, slot) { gs.index_dirty = true }
        append(&gs.dirty_slots, slot)
    }
}

// A sealed room around the camera with one torch on the floor ahead.
bench_carve_cave :: proc(gs: ^Game_State) {
    dirty: map[int]bool
    defer delete(dirty)
    changed: [dynamic][3]int
    defer delete(changed)
    c := [3]int{int(gs.camera.pos.x), int(gs.camera.pos.y), int(gs.camera.pos.z)}
    edit_sphere(gs, c, .Air, &dirty, &changed, 7)
    fwd := camera_flat_forward(gs.camera)
    torch := [3]int{c.x + int(fwd.x * 4), c.y - 6, c.z + int(fwd.z * 4)}
    edit_sphere(gs, torch, .Torch, &dirty, &changed, 0)
    light_on_edit(gs, changed[:])
    for slot in dirty {
        if refresh_chunk_index(gs, slot) { gs.index_dirty = true }
        append(&gs.dirty_slots, slot)
    }
}

// Save the current out_texture (tone-mapped RGBA16F) as a BMP.
bench_screenshot :: proc(gs: ^Game_State, path: string) {
    w := u32(gs.render_w); h := u32(gs.render_h)
    size := w * h * 8
    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .DOWNLOAD, size = size})
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)

    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    cp := SDL.BeginGPUCopyPass(cmd)
    SDL.DownloadFromGPUTexture(cp,
        {texture = gs.out_texture, w = w, h = h, d = 1},
        {transfer_buffer = transfer})
    SDL.EndGPUCopyPass(cp)
    fence := SDL.SubmitGPUCommandBufferAndAcquireFence(cmd)
    _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
    SDL.ReleaseGPUFence(gs.gpu_device, fence)

    src := ([^]f16)(SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false))
    pixels := make([]u8, w * h * 4)
    defer delete(pixels)
    for i in 0 ..< int(w * h) {
        for c in 0 ..< 3 {
            v := clamp(f32(src[i * 4 + c]), 0, 1)
            pixels[i * 4 + c] = u8(v * 255 + 0.5)
        }
        pixels[i * 4 + 3] = 255
    }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    surf := SDL.CreateSurfaceFrom(i32(w), i32(h), .RGBA32, raw_data(pixels), i32(w * 4))
    defer SDL.DestroySurface(surf)
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    if !SDL.SaveBMP(surf, cpath) { fmt.eprintln("SaveBMP failed:", SDL.GetError()) }
}
