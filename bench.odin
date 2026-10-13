package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import SDL "vendor:sdl3"

// GPU benchmark: `odin run . -- bench`. Runs in a hidden, unfocusable window,
// streams the full load radius, then renders fixed camera views under a set
// of quality configs and prints the GPU time per frame of each (no vsync, no
// UI pass; see bench_measure).

BENCH_WARMUP_FRAMES :: 60
BENCH_BATCHES       :: 5
BENCH_BATCH_FRAMES  :: 20

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
    no_far: bool,
    near_r: int,  // near_radius_override
}

// Directory for screenshots (view.bmp for the first config, view_N.bmp for
// config N); "" = none.
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
        {"far",        150, 30, -10, false, false},
    }
    configs := []Bench_Config{
        {"default (aa1 hard)", 1, 1, false, false, 0},
        {"far terrain off",    1, 1, false, true, 0},
        {"far from 16 chunks", 1, 1, false, false, 16},
        {"soft shadows",       1, 3, false, false, 0},
        {"aa2",                2, 1, false, false, 0},
        {"volumetric",         1, 1, true,  false, 0},
        {"all on",             2, 3, true,  false, 0},
    }

    // Stream the whole load radius before measuring.
    t0 := time.now()
    enqueue_chunks(gs)
    for !streaming_idle(gs) {
        integrate_ready_chunks(gs)
        far_enqueue(gs)
        integrate_far_tiles(gs)
        stitch_pending_columns(gs)
        flush_gpu_uploads(gs)
        if time.duration_seconds(time.since(t0)) > 120 {
            fmt.println("bench: streaming did not finish in 120 s, measuring anyway")
            break
        }
        time.sleep(time.Millisecond)
    }
    fmt.printf("bench: world streamed in %.1f s\n", time.duration_seconds(time.since(t0)))
    bench_world_stats(gs)

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
            if bench_quick && ci > 2 { break }
            gs.aa_samples  = c.aa
            gs.shadow_rays = c.shadow
            gs.vol_enabled = c.vol
            gs.far_enabled = !c.no_far
            gs.near_radius_override = c.near_r
            ms := bench_measure(gs)
            fmt.printf("  %-28s %6.2f ms  (%5.1f fps)\n", c.name, ms, 1000.0 / ms)
            if bench_shot_dir != "" {
                suffix := ci == 0 ? "" : fmt.tprintf("_%d", ci)
                bench_screenshot(gs, fmt.tprintf("%s/%s%s.bmp", bench_shot_dir, v.name, suffix))
            }
        }
    }
}

// GPU time of one frame, in ms: the median over batches of frames submitted
// back to back. Waiting on every frame would let the GPU idle between
// frames, and the driver then keeps it at low clocks ("Idle" throttling),
// which makes the numbers depend on what else is running.
bench_measure :: proc(gs: ^Game_State) -> f64 {
    batch :: proc(gs: ^Game_State, n: int) -> f64 {
        t := time.tick_now()
        for i in 0 ..< n {
            flush_gpu_uploads(gs)
            entities_update(gs, 1.0 / 60.0)
            fence := gpu_render(gs, want_fence = i == n - 1)
            if fence != nil {
                _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
                SDL.ReleaseGPUFence(gs.gpu_device, fence)
            }
        }
        return time.duration_milliseconds(time.tick_since(t)) / f64(n)
    }
    batch(gs, BENCH_WARMUP_FRAMES) // also lets the GPU clock up
    samples: [BENCH_BATCHES]f64
    for &s in samples { s = batch(gs, BENCH_BATCH_FRAMES) }
    slice.sort(samples[:])
    return samples[BENCH_BATCHES / 2]
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
    for slot in dirty { gpu_sync_slot(gs, slot) }
    far_update_edited(gs, changed[:])
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
    for slot in dirty { gpu_sync_slot(gs, slot) }
    far_update_edited(gs, changed[:])
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

// Brick counts for the resident world.
bench_world_stats :: proc(gs: ^Game_State) {
    air, solid, mixed := 0, 0, 0
    for _, col in gs.columns {
        for c in col.chunks {
            if c.voxels != nil { mixed += 1 } else if c.fill == 0 { air += 1 } else { solid += 1 }
        }
    }
    fmt.printf("bench: %d columns, chunks: %d air, %d uniform solid, %d mixed\n", len(gs.columns), air, solid, mixed)
    fmt.printf("bench: voxel bricks %d of %d, light bricks %d of %d\n",
        MAX_RESIDENT_BRICKS - gs.brick_pool.free_top, MAX_RESIDENT_BRICKS,
        MAX_LIGHT_BRICKS - gs.light_pool.free_top, MAX_LIGHT_BRICKS)
    far := 0
    for t in gs.far_tiles { if t.x != FAR_NO_TILE { far += 1 } }
    fmt.printf("bench: far tiles %d of %d\n", far, len(gs.far_tiles))
}
