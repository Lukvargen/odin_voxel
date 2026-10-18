package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import "core:os"
import "core:path/filepath"
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
// `world=<name>`: the bench plays saves/<name>'s edits (read only; use a copy).
bench_world: bool
// `bench view world=<copy> pos=x,y,z yaw=a pitch=b [notex] [dir]`: one shot
// from there (entities off), e.g. of a spot a player reported.
bench_view: bool
bench_view_pos: [3]f32
bench_view_yaw, bench_view_pitch: f32
// `ab=gi`: every shot (bench_screenshot) twice, into <dir>/on/ and with the
// bounce-light probes off into <dir>/off/, for before/after in one run.
bench_ab_gi: bool
// `bench glider`: fly a scripted hang-glider test instead of the views.
bench_glider: bool
// `bench entcost`: per view, the GPU cost of entity view rays and entity
// shadow rays, configs interleaved in one process so clock swings hit all.
bench_entcost: bool
// `bench stream`: fly in a straight line at 60 m/s (real-time paced) and
// time the main-thread upload flush while terrain streams in.
bench_stream: bool

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

    // Stream the whole load radius before measuring, unless the bench
    // goes somewhere else first (bench_teleport streams there).
    if !bench_teleports_first() {
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
    }
    if bench_glider {
        bench_glider_run(gs)
        return
    }
    if bench_stream {
        bench_stream_run(gs)
        return
    }
    if bench_look {
        bench_look_run(gs)
        return
    }
    if bench_combat {
        bench_combat_run(gs)
        return
    }
    if bench_ui {
        bench_ui_run(gs)
        return
    }
    if bench_build {
        bench_build_run(gs)
        return
    }
    if bench_relight {
        bench_relight_run(gs)
        return
    }
    if bench_crowd {
        bench_crowd_run(gs)
        return
    }
    if bench_nav {
        bench_nav_run(gs)
        return
    }
    if bench_trees {
        bench_trees_run(gs)
        return
    }
    if bench_caves {
        bench_caves_run(gs)
        return
    }
    if bench_fight {
        bench_fight_run(gs)
        return
    }
    if bench_enemies {
        bench_enemies_run(gs)
        return
    }
    if bench_slimes {
        bench_slimes_run(gs)
        return
    }
    if bench_landmarks {
        bench_landmarks_run(gs)
        return
    }
    if bench_players {
        bench_players_run(gs)
        return
    }
    if bench_water {
        bench_water_run(gs)
        return
    }
    if bench_sea {
        bench_sea_run(gs)
        return
    }
    if bench_climb {
        bench_climb_run(gs)
        return
    }
    if bench_doors {
        bench_doors_run(gs)
        return
    }
    if bench_fell {
        bench_fell_run(gs)
        return
    }
    if bench_plants {
        bench_plants_run(gs)
        return
    }
    if bench_hear {
        bench_hear_run(gs)
        return
    }
    if bench_gi {
        bench_gi_run(gs)
        return
    }
    if bench_shade {
        bench_shade_run(gs)
        return
    }
    if bench_torch {
        bench_torch_run(gs)
        return
    }
    if bench_view {
        gs.entities_enabled = false
        entities_update(gs, 0)
        gs.camera.fly_mode = true
        bench_teleport(gs, bench_view_pos)
        gs.camera.yaw, gs.camera.pitch = bench_view_yaw, bench_view_pitch
        bench_measure(gs)
        fmt.printf("view: %v yaw %.1f pitch %.1f\n", bench_view_pos, bench_view_yaw, bench_view_pitch)
        if bench_shot_dir != "" { bench_screenshot(gs, fmt.tprintf("%s/view.bmp", bench_shot_dir)) }
        return
    }

    gs.camera.fly_mode = true
    spawn := gs.camera.pos
    for v in views {
        sx, sz := int(spawn.x), int(spawn.z)
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
        if bench_entcost {
            bench_entity_cost(gs)
            continue
        }
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

bench_stream_run :: proc(gs: ^Game_State) {
    cam := &gs.camera
    cam.fly_mode = true
    cam.yaw, cam.pitch = 30, -10
    cam.pos.y += 40
    FRAMES :: 900
    flush_ms: [FRAMES]f64
    profile_reset()
    defer profile_dump("stream")
    for i in 0 ..< FRAMES {
        frame_start := time.tick_now()
        cam.pos += camera_flat_forward(cam^) * (60.0 / 60.0)
        pc := [3]int{floor_div(int(cam.pos.x), CHUNK_VOXELS), floor_div(int(cam.pos.y), CHUNK_VOXELS), floor_div(int(cam.pos.z), CHUNK_VOXELS)}
        if pc != gs.player_chunk {
            gs.player_chunk = pc
            worker_pool_set_player(&gs.pool, pc[0], pc[2])
            enqueue_chunks(gs)
        }
        flat := camera_flat_forward(cam^)
        worker_pool_set_view(&gs.pool, flat.x, flat.z)
        integrate_ready_chunks(gs)
        far_enqueue(gs)
        integrate_far_tiles(gs)
        stitch_pending_columns(gs)
        t := time.tick_now()
        flush_gpu_uploads(gs)
        flush_ms[i] = time.duration_milliseconds(time.tick_since(t))
        entities_update(gs, 1.0 / 60)
        gpu_render(gs)
        free_all(context.temp_allocator)
        // Real-time pacing so the workers keep up the way they do in game.
        for time.duration_milliseconds(time.tick_since(frame_start)) < 16.6 { time.sleep(200 * time.Microsecond) }
    }
    if bench_shot_dir != "" {
        // Let streaming settle, then a frame to compare against other builds.
        for _ in 0 ..< 120 {
            integrate_ready_chunks(gs); far_enqueue(gs); integrate_far_tiles(gs); stitch_pending_columns(gs)
            flush_gpu_uploads(gs)
            time.sleep(10 * time.Millisecond)
        }
        gs.entities_enabled = false
        entities_update(gs, 0)
        cam.yaw += 180 // back over the terrain that just streamed in
        cam.pitch = -35
        gpu_render(gs)
        bench_screenshot(gs, fmt.tprintf("%s/stream_end.bmp", bench_shot_dir))
    }
    sum, worst: f64
    for m in flush_ms { sum += m; worst = max(worst, m) }
    sorted := flush_ms
    slice.sort(sorted[:])
    fmt.printf("  stream: flush_gpu_uploads avg %.3f ms, p95 %.3f ms, max %.3f ms over %d frames\n",
        sum / FRAMES, sorted[FRAMES * 95 / 100], worst, FRAMES)
}

bench_entity_cost :: proc(gs: ^Game_State) {
    Cfg :: struct { name: string, enabled: bool, debug: int }
    cfgs := []Cfg{
        {"entities off",        false, 0},
        {"all",                 true,  0},
        {"no entity view rays", true,  1},
        {"no entity shadows",   true,  2},
        {"neither (traversal setup only)", true, 3},
        {"no cumulus clouds",   true,  4},
    }
    best: [6]f64
    for &b in best { b = 1e9 }
    for _ in 0 ..< 6 {
        for c, i in cfgs {
            gs.entities_enabled = c.enabled
            gs.ent_debug = c.debug
            best[i] = min(best[i], bench_measure(gs))
        }
    }
    gs.entities_enabled, gs.ent_debug = true, 0
    for c, i in cfgs {
        fmt.printf("  %-32s %6.2f ms  (%+.2f vs off)\n", c.name, best[i], best[i] - best[0])
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
// A frame with the HUD over it (ui_init first), 1280 x 720, saved as a BMP.
bench_hud_shot :: proc(gs: ^Game_State, path: string) {
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
    if surf == nil || !SDL.SaveBMP(surf, strings.clone_to_cstring(path, context.temp_allocator)) {
        fmt.eprintln("bench: couldn't save", path, SDL.GetError())
    }
    SDL.DestroySurface(surf)
    _ = SDL.SetRenderTarget(r, nil)
    SDL.DestroyTexture(target)
    free_all(context.temp_allocator)
}

// Benches whose first move is a bench_teleport: streaming around spawn
// first would only be thrown away.
bench_teleports_first :: proc() -> bool {
    return bench_look || bench_caves || bench_gi || bench_landmarks || bench_trees || bench_sea ||
           bench_slimes || bench_enemies || bench_fight || bench_nav || bench_crowd || bench_players ||
           bench_build || bench_combat || bench_relight || bench_view || bench_torch || bench_shade || bench_fell
}

// Save the last frame as a BMP; with ab=gi also the same view with the
// probes off (see bench_ab_gi).
bench_screenshot :: proc(gs: ^Game_State, path: string) {
    if !bench_ab_gi || !gs.gi.enabled {
        bench_save_frame(gs, path)
        return
    }
    dir, file := filepath.split(path)
    on_dir  := fmt.tprintf("%s/on", dir)
    off_dir := fmt.tprintf("%s/off", dir)
    _ = os.make_directory_all(on_dir)
    _ = os.make_directory_all(off_dir)
    bench_save_frame(gs, fmt.tprintf("%s/%s", on_dir, file))
    // Off needs no settling: one frame. Back on, the probes keep their light.
    gs.gi.enabled = false
    flush_gpu_uploads(gs)
    if fence := gpu_render(gs, want_fence = true); fence != nil {
        _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
        SDL.ReleaseGPUFence(gs.gpu_device, fence)
    }
    bench_save_frame(gs, fmt.tprintf("%s/%s", off_dir, file))
    gs.gi.enabled = true
}

@(private="file")
bench_save_frame :: proc(gs: ^Game_State, path: string) {
    pixels := bench_frame_pixels(gs)
    defer delete(pixels)
    surf := SDL.CreateSurfaceFrom(gs.render_w, gs.render_h, .RGBA32, raw_data(pixels), gs.render_w * 4)
    defer SDL.DestroySurface(surf)
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    if !SDL.SaveBMP(surf, cpath) { fmt.eprintln("SaveBMP failed:", SDL.GetError()) }
}

// The last frame (out_texture, tone-mapped) as RGBA8 pixels; the caller
// deletes them.
bench_frame_pixels :: proc(gs: ^Game_State) -> []u8 {
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
    for i in 0 ..< int(w * h) {
        for c in 0 ..< 3 {
            v := clamp(f32(src[i * 4 + c]), 0, 1)
            pixels[i * 4 + c] = u8(v * 255 + 0.5)
        }
        pixels[i * 4 + 3] = 255
    }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)
    return pixels
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
        len(gs.brick_pool.free_ids) - gs.brick_pool.free_top, len(gs.brick_pool.free_ids),
        len(gs.light_pool.free_ids) - gs.light_pool.free_top, len(gs.light_pool.free_ids))
    far := 0
    for t in gs.far_tiles { if t.x != FAR_NO_TILE { far += 1 } }
    fmt.printf("bench: far tiles %d of %d\n", far, len(gs.far_tiles))
}

// Opening the wing hands-off, from a few starts: it should settle straight
// toward where the pilot looked, not swerve. Prints the worst bank and how
// far off the look the heading ends.
bench_glider_deploys :: proc(gs: ^Game_State, at: [3]f32) {
    g := &gs.glider
    cam := &gs.camera
    Start :: struct { name: string, vel: [3]f32, wind_t: f32 }
    starts := []Start{
        {"from a drop",            {0, -8, 0},   0},
        {"walking jump",           {3, 2, 5},    0},
        {"sideways momentum",      {-14, -3, 6}, 0},
        {"drop, other wind",       {0, -8, 0},   900},
    }
    for st in starts {
        cam.pos, cam.velocity, cam.on_ground = at, st.vel, false
        cam.yaw, cam.pitch = 30, -5
        g.wind_time = st.wind_t
        glider_toggle_deploy(gs)
        worst: f32 = 0
        for _ in 0 ..< 180 { // 3 s, no input
            glider_update(gs, 0, 0, 1.0 / 60, false, false, false, false, false)
            worst = max(worst, abs(g.bank))
            if !g.deployed { break }
        }
        fmt.printf("  deploy %-20s worst bank %5.1fÂ°  heading off the look by %+6.1fÂ° after 3 s\n",
            st.name, worst * 57.3, wrap_angle(g.heading - 30))
        if g.deployed { glider_toggle_deploy(gs) }
    }

    // A strong thermal near the start, passed with its core off the left
    // wing: the left wing should lift (bank right, negative) and the HUD's
    // lift_side point left (positive).
    // Where thermals form: 30 x 30 cells around the start, by the ground
    // under each cell's middle, and what working them out costs.
    {
        cx, cz := int(math.floor(at.x / THERMAL_CELL)), int(math.floor(at.z / THERMAL_CELL))
        cells, have, strong: [Biome]int
        sum: [Biome]f32
        t0 := time.tick_now()
        for dz in -15 ..< 15 { for dx in -15 ..< 15 {
            gx, gz := cx + dx + 1000, cz + dz // fresh cells, not cached by the flights below
            th, ok := thermal_cell(gx, gz)
            b := terrain_at(int((f32(gx) + 0.5) * THERMAL_CELL), int((f32(gz) + 0.5) * THERMAL_CELL)).biome
            cells[b] += 1
            if ok {
                have[b] += 1
                sum[b] += th.strength / TERRAIN_SCALE
                if th.strength >= THERMAL_STRONG { strong[b] += 1 }
            }
        }}
        ms := time.duration_milliseconds(time.tick_since(t0))
        fmt.printf("  thermals: %.3f ms per cell (900 cells)\n", ms / 900)
        for b in Biome {
            if cells[b] == 0 { continue }
            fmt.printf("    %-10s %4d cells  %3.0f%% have one  %3.0f%% strong  avg %.1f m/s (design)\n", b, cells[b],
                100 * f32(have[b]) / f32(cells[b]), 100 * f32(strong[b]) / f32(cells[b]), have[b] > 0 ? sum[b] / f32(have[b]) : 0)
        }
    }

    best, ground, y, found := bench_strong_thermal(at)
    if !found { return }
    g.wind_time = 0
    day_set_hour(gs, 13, settle = true) // full sun for the pass
    defer day_set_hour(gs, DAY_START_HOUR, settle = true)
    fmt.printf("  heat at 13:00 %.2f, at %.1f h %.2f, at 22 h %.2f\n", thermal_heat(gs.day),
        f32(DAY_START_HOUR), thermal_heat({hour = DAY_START_HOUR}), thermal_heat({hour = 22}))
    core, core_lift := thermal_core_at({th = best, ground = ground}, y, glider_wind(0))
    // Heading +z (yaw 0), the core 0.6 radii off the left wing.
    fwd, _ := glider_axes(0, 0, 0)
    left := [3]f32{fwd.z, 0, -fwd.x}
    fmt.printf("  thermal: strength %.1f radius %.0f, %.1f m/s in the core at the pass's height\n", best.strength, best.radius, core_lift)
    start := [3]f32{core.x, y, core.y} - left * best.radius * 0.6 - fwd * 60
    cam.pos, cam.velocity, cam.on_ground = start, {0, -2, 14}, false
    cam.yaw, cam.pitch = 0, -5
    glider_toggle_deploy(gs)
    g.deploy_t = 1
    kick_up, kick_down: f32
    for i in 0 ..< 360 {
        glider_update(gs, 0, 0, 1.0 / 60, false, false, false, false, false)
        glider_view_update(gs, 1.0 / 60)
        kick_up, kick_down = max(kick_up, g.kick), min(kick_down, g.kick)
        if !g.deployed { break }
        if i % 30 == 29 {
            fmt.printf("  thermal pass t=%.1f  lift %+5.2f  lift_side %+5.2f  bank %+5.1fÂ°  hdg %+6.1f  vario %+5.2f\n",
                f32(i + 1) / 60, g.lift_here, g.lift_side, g.bank * 57.3, wrap_angle(g.heading), g.vario)
        }
    }
    fmt.printf("  seat kick: up to %+.2f m, down to %+.2f m\n", kick_up, kick_down)
    if g.deployed { glider_toggle_deploy(gs) }
}


@(private="file")
wrap_angle :: proc(a: f32) -> f32 { return math.mod(a + 540, 360) - 180 }

// The strongest thermal within three cells of `at`, its ground, and a height
// 60 m (design) up it.
bench_strong_thermal :: proc(at: [3]f32) -> (best: Thermal, ground, y: f32, found: bool) {
    cx, cz := int(math.floor(at.x / THERMAL_CELL)), int(math.floor(at.z / THERMAL_CELL))
    for dz in -3 ..= 3 { for dx in -3 ..= 3 {
        th := thermal_cell(cx + dx, cz + dz) or_continue
        if !found || th.strength > best.strength { best, found = th, true }
    }}
    ground = max(f32(surface_height_at(int(best.centre.x), int(best.centre.y))), SEA_LEVEL)
    return best, ground, ground + 60 * TERRAIN_SCALE, found
}

// Scripted flight: prints the flight model's numbers for a few manoeuvres,
// then times and screenshots first-person, look-up and chase views.
bench_glider_run :: proc(gs: ^Game_State) {
    g := &gs.glider
    cam := &gs.camera
    spawn := cam.pos
    surf := f32(surface_height_at(int(spawn.x), int(spawn.z)))
    cam.pos = {spawn.x, surf + 180, spawn.z}
    cam.velocity = {}
    cam.on_ground = false
    cam.yaw, cam.pitch = 30, -5
    g.equipped = true
    bench_glider_deploys(gs, {spawn.x, surf + 180, spawn.z})
    cam.pos = {spawn.x, surf + 180, spawn.z}
    cam.velocity = {}
    cam.yaw, cam.pitch = 30, -5
    glider_toggle_deploy(gs)

    dt := f32(1.0 / 60.0)
    Phase :: struct { name: string, secs: f32, aim_pitch: f32, turn: f32, bar, flare: bool }
    phases := []Phase{
        {"trim (aim -6)",      8, -6,  0,   false, false},
        {"aim level",          5,  0,  0,   false, false},
        {"turn left 180",      5, -6,  180, false, false},
        {"speed bar",          6, -6,  0,   true,  false},
        {"bar released",       5, -6,  0,   false, false},
        {"flare",              2, -6,  0,   false, true},
        {"recover",            5, -10, 0,   false, false},
        {"dive (aim -60)",     4, -60, 0,   false, false},
        {"pull up (aim +30)",  3,  30, 0,   false, false},
    }
    for ph in phases {
        start_yaw := g.aim_yaw
        frames := int(ph.secs / dt)
        for i in 0 ..< frames {
            g.aim_pitch = ph.aim_pitch
            g.aim_yaw = start_yaw + ph.turn * min(f32(i) / 60.0, 1) // turn the aim over 1 s
            glider_update(gs, 0, 0, dt, ph.bar, ph.flare, false, false, false)
            glider_view_update(gs, dt)
            if !g.deployed { fmt.println("  (landed)"); break }
            if i % 60 == 59 || i == frames - 1 {
                fmt.printf("  %-18s t=%4.1f  V %5.1f  vy %+6.2f  aoa %5.1f  bank %5.1f  hdg %6.1f  stall %.2f  lift %+.1f  alt %.0f\n",
                    ph.name, f32(i + 1) * dt, g.airspeed, cam.velocity.y, g.aoa * 57.3, g.bank * 57.3,
                    g.heading, g.stall, g.lift_here, cam.pos.y)
            }
        }
        if !g.deployed { break }
    }

    // CPU cost per frame of entities + glider, as the game loop calls them
    // (no GPU waits: uploads are only submitted).
    {
        cam.pos = {spawn.x, surf + 60, spawn.z}
        if !g.deployed { glider_toggle_deploy(gs) }
        g.aim_pitch = -5
        profile_reset()
        t0 := time.tick_now()
        for _ in 0 ..< 600 {
            g.aim_yaw += 0.3
            glider_update(gs, 0, 0, 1.0 / 60, false, false, false, false, false)
            glider_view_update(gs, 1.0 / 60)
            entities_update(gs, 1.0 / 60)
            free_all(context.temp_allocator)
        }
        total := time.duration_milliseconds(time.tick_since(t0))
        birds := 0
        for e in gs.entities { if e.kind == .Bird { birds += 1 } }
        fmt.printf("  cpu: %.3f ms/frame for glider + entities (%d entities, %d birds, %d uploaded)\n",
            total / 600, len(gs.entities), birds, gs.entity_count)
        profile_dump("glider + entities, 600 frames")
    }

    // Visuals: back near spawn, gliding in a gentle left bank.
    cam.pos = {spawn.x, surf + 25, spawn.z}
    if !g.deployed { glider_toggle_deploy(gs) }
    g.deploy_t = 1
    g.aim_pitch = -8
    g.bank, g.aoa = 0.4, 0.12
    g.path_angle = -0.1
    gs.player_chunk = {
        floor_div(int(cam.pos.x), CHUNK_VOXELS),
        floor_div(int(cam.pos.y), CHUNK_VOXELS),
        floor_div(int(cam.pos.z), CHUNK_VOXELS),
    }
    shots := []struct{ name: string, look_pitch, look_yaw: f32, third: bool, bar: f32 }{
        {"glider_fp",     0,   0,  false, 0},
        {"glider_fp_bar", 0,   0,  false, 1},
        {"glider_up",     70,  20, false, 0},
        {"glider_down",   -55, 0,  false, 0},
        {"glider_chase",  -10, 0,  true,  0},
    }
    for sh in shots {
        g.look_pitch, g.look_yaw = sh.look_pitch, sh.look_yaw
        g.bar = sh.bar
        g.third_person = sh.third
        g.chase_dist = sh.third ? 6.5 : 0
        cam.yaw   = g.aim_yaw + g.look_yaw
        cam.pitch = clamp(g.aim_pitch + g.look_pitch - BAR_VIEW_DIP * g.bar, -89, 89)
        cam.roll  = g.bank * 0.45
        cam.view_offset = {}
        if sh.third {
            back := -camera_forward(cam^)
            cam.view_offset = back * g.chase_dist + [3]f32{0, 1.2, 0}
        }
        // Same pose with and without the glider, interleaved (best of 3)
        // so GPU clock swings hit both.
        with, without: f64 = 1e9, 1e9
        for _ in 0 ..< 3 {
            with = min(with, bench_measure(gs))
            g.deployed = false
            without = min(without, bench_measure(gs))
            g.deployed = true
        }
        fmt.printf("  %-14s %6.2f ms  (glider %+.2f ms)\n", sh.name, with, with - without)
        if bench_shot_dir != "" {
            entities_update(gs, 0) // the last timed frame was the one without the glider
            gpu_render(gs)
            bench_screenshot(gs, fmt.tprintf("%s/%s.bmp", bench_shot_dir, sh.name))
        }
    }
    g.deployed = false
    cam.roll, cam.view_offset = 0, {}

    g.look_pitch, g.look_yaw = 0, 0
    cam.pitch = g.aim_pitch
    ms := bench_measure(gs)
    fmt.printf("  %-14s %6.2f ms\n", "no glider", ms)

    // Close-ups of one entity of each kind, then the player's body in the
    // third-person view.
    if bench_shot_dir == "" { return }
    g.third_person, g.chase_dist = false, 0 // no player body around the camera
    cam.fly_mode = true                     // nor its shadow (player_add_parts)
    for kind in Entity_Kind {
        for e in gs.entities {
            if e.kind != kind { continue }
            target := e.pos + [3]f32{0, kind == .Bird ? 0 : 0.5, 0}
            dist: f32 = kind == .Bird ? 3.2 : 1.6
            // Foxes: a front-quarter view of the head, close in.
            facing := math.atan2(math.cos(e.yaw), -math.sin(e.yaw)) // angle of {-sin, cos} in (x, z)
            if kind == .Fox {
                target = e.pos + [3]f32{-math.sin(e.yaw), 0, math.cos(e.yaw)} * (0.35 * e.scale) + [3]f32{0, 0.65 * e.scale, 0}
                dist = 1.0
            }
            // First direction around the target with a clear view of it.
            for i in 0 ..< 16 {
                a := f32(i) / 16 * 2 * math.PI
                if kind == .Fox { a = facing + 0.7 + f32(i) / 16 * 2 * math.PI }
                cam.pos = target + [3]f32{math.cos(a) * dist, dist * 0.5, math.sin(a) * dist}
                _, _, blocked := raycast_voxel(gs, target, la.normalize(cam.pos - target), dist * 1.2)
                if !blocked { break }
            }
            d := la.normalize(target - cam.pos)
            cam.yaw   = math.to_degrees(math.atan2(d.x, d.z))
            cam.pitch = math.to_degrees(math.asin(d.y))
            entities_update(gs, 0) // dt 0: nobody walks off between frames
            gpu_render(gs)
            bench_screenshot(gs, fmt.tprintf("%s/entity_%v.bmp", bench_shot_dir, kind))
            break
        }
    }

    // Player mid-stride, from the chase camera.
    sx, sz := int(spawn.x), int(spawn.z)
    cam.pos = {f32(sx) + 0.5, f32(surface_height_at(sx, sz)) + 1 + PLAYER_EYE_HEIGHT, f32(sz) + 0.5}
    cam.on_ground = true
    cam.yaw, cam.pitch = 150, -12
    g.third_person, g.chase_dist = true, 4
    gs.player_anim = {body_yaw = -math.to_radians(f32(120)), walk_phase = 1.2, amp = 0.9}
    back := -camera_forward(cam^)
    cam.view_offset = back * g.chase_dist + [3]f32{0, 1.2, 0}
    entities_update(gs, 0)
    gpu_render(gs)
    bench_screenshot(gs, fmt.tprintf("%s/entity_Player.bmp", bench_shot_dir))

    // Cumulus over the nearest strong thermal, seen from the ground.
    g.third_person, g.chase_dist = false, 0
    cam.view_offset = {}
    sky_thermals_update(gs)
    if gs.sky_thermal_count > 0 {
        best := 0
        for th, i in gs.sky_thermals[:gs.sky_thermal_count] {
            if la.length(th.centre - cam.pos.xz) < la.length(gs.sky_thermals[best].centre - cam.pos.xz) { best = i }
        }
        th := gs.sky_thermals[best]
        target := [3]f32{th.centre.x, CUMULUS_BASE, th.centre.y}
        d := la.normalize(target - cam.pos)
        cam.yaw   = math.to_degrees(math.atan2(d.x, d.z))
        cam.pitch = math.to_degrees(math.asin(d.y))
        fmt.printf("  cumulus: %d thermals, nearest %.0f m away\n", gs.sky_thermal_count, la.length(target - cam.pos))
        entities_update(gs, 0)
        gpu_render(gs)
        bench_screenshot(gs, fmt.tprintf("%s/clouds.bmp", bench_shot_dir))

        // From the side at cloud height, as when gliding up to one.
        c := th.centre + glider_wind(g.wind_time).xz * ((CUMULUS_BASE - th.ground) * 0.08)
        side := la.normalize(cam.pos.xz - c)
        cam.pos = {c.x + side.x * th.cloud_r * 3.2, CUMULUS_BASE + 15, c.y + side.y * th.cloud_r * 3.2}
        d = la.normalize([3]f32{c.x, CUMULUS_BASE + 25, c.y} - cam.pos)
        cam.yaw   = math.to_degrees(math.atan2(d.x, d.z))
        cam.pitch = math.to_degrees(math.asin(d.y))
        gs.player_chunk = {floor_div(int(cam.pos.x), CHUNK_VOXELS), floor_div(int(cam.pos.y), CHUNK_VOXELS), floor_div(int(cam.pos.z), CHUNK_VOXELS)}
        entities_update(gs, 0)
        gpu_render(gs)
        bench_screenshot(gs, fmt.tprintf("%s/clouds_side.bmp", bench_shot_dir))
    }
}

// `bench look [dir]`: screenshots of one spot per biome (nearest to spawn),
// from eye height and from above, for judging textures and lighting.
// Entities off so shots from different builds compare.
bench_look: bool

bench_look_run :: proc(gs: ^Game_State) {
    // dig: also a shot down into a freshly dug pit (bare rock, no moss/snow).
    Look :: struct { biome: Biome, yaw: f32, dig: bool }
    looks := []Look{
        {.Plains, 30, false}, {.Forest, 60, false}, {.Taiga, 200, false}, {.Snowy, 120, false},
        {.Desert, 300, false}, {.Badlands, 45, false}, {.Mountains, 150, true}, {.Peaks, 250, true}, {.Beach, 90, false},
    }
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    for lk in looks {
        x, z, found := bench_find_biome(lk.biome)
        if !found { fmt.printf("look: no %v found\n", lk.biome); continue }
        bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 3, f32(z) + 0.5})
        fmt.printf("look: %v at %d,%d\n", lk.biome, x, z)
        bench_clear_view(gs)
        cam.yaw, cam.pitch = lk.yaw, -6
        bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/%v.bmp", bench_shot_dir, lk.biome))
        cam.pos.y += 45
        bench_clear_view(gs)
        cam.pitch = -28
        bench_measure(gs)
        bench_screenshot(gs, fmt.tprintf("%s/%v_high.bmp", bench_shot_dir, lk.biome))
        if lk.dig {
            sx, sz := x + 6, z
            sy := surface_height_at(sx, sz)
            dirty: map[int]bool
            changed: [dynamic][3]int
            edit_sphere(gs, {sx, sy - 2, sz}, .Air, &dirty, &changed, 5)
            light_on_edit(gs, changed[:])
            for slot in dirty { gpu_sync_slot(gs, slot) }
            far_update_edited(gs, changed[:])
            delete(dirty); delete(changed)
            cam.pos = {f32(x) + 0.5, f32(sy) + 6, f32(z) + 0.5}
            bench_clear_view(gs)
            cam.pitch = -50
            cam.yaw = 90 // toward the pit (+x)
            bench_measure(gs)
            bench_screenshot(gs, fmt.tprintf("%s/%v_dug.bmp", bench_shot_dir, lk.biome))
        }
    }
}

// Nearest surface point of biome b, searched outward in rings.
bench_find_biome :: proc(b: Biome) -> (x, z: int, ok: bool) {
    for r := 0; r < 12000; r += 64 {
        steps := max(1, r / 24)
        for i in 0 ..< steps {
            a := f64(i) / f64(steps) * math.TAU
            px := int(math.cos(a) * f64(r)); pz := int(math.sin(a) * f64(r))
            // Want the middle of the biome, not its border.
            if terrain_at(px, pz).biome == b && terrain_at(px + 24, pz).biome == b &&
               terrain_at(px - 24, pz).biome == b && terrain_at(px, pz + 24).biome == b {
                return px, pz, true
            }
        }
    }
    return 0, 0, false
}

// Move the camera and stream the world around it.
bench_teleport :: proc(gs: ^Game_State, pos: [3]f32) {
    gs.camera.pos = pos
    gs.player_chunk = {
        floor_div(int(pos.x), CHUNK_VOXELS),
        floor_div(int(pos.y), CHUNK_VOXELS),
        floor_div(int(pos.z), CHUNK_VOXELS),
    }
    worker_pool_set_player(&gs.pool, gs.player_chunk[0], gs.player_chunk[2])
    // What's out of view from here goes first: a jump across the world would
    // otherwise keep the old place resident until the ring reuses its slots.
    far_away := make([dynamic][2]int, context.temp_allocator)
    for key in gs.columns {
        d := key - [2]int{gs.player_chunk.x, gs.player_chunk.z}
        if d.x * d.x + d.y * d.y > (view_radius + 2) * (view_radius + 2) { append(&far_away, key) }
    }
    for key in far_away { unload_column(gs, key) }
    enqueue_chunks(gs)
    t0 := time.now()
    for !streaming_idle(gs) && time.duration_seconds(time.since(t0)) < 120 {
        integrate_ready_chunks(gs)
        far_enqueue(gs)
        integrate_far_tiles(gs)
        stitch_pending_columns(gs)
        flush_gpu_uploads(gs)
        free_all(context.temp_allocator)
        time.sleep(time.Millisecond)
    }
}

// Raise the camera out of trees, water or rock: nothing within 2 voxels.
bench_clear_view :: proc(gs: ^Game_State) {
    p := &gs.camera.pos
    for _ in 0 ..< 200 {
        clear := true
        for dx in -2 ..= 2 { for dy in -2 ..= 2 { for dz in -2 ..= 2 {
            if get_voxel(gs, int(p.x) + dx, int(p.y) + dy, int(p.z) + dz) != 0 { clear = false }
        }}}
        if clear { return }
        p.y += 1
    }
}
