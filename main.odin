package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import SDL "vendor:sdl3"

DOUBLE_TAP_MS :: u64(300)

Game_State :: struct {
    // SDL3
    window:     ^SDL.Window,
    gpu_device: ^SDL.GPUDevice,

    // Camera
    camera: Camera,

    // World
    columns:         map[[2]int]^Column, // resident columns (world.odin)
    saved_columns:   map[[2]int]bool,    // columns with a save file (save.odin)
    pool:            Worker_Pool,
    dirty_slots:     [dynamic]int,   // slots whose brick needs GPU upload
    index_dirty:     bool,           // gpu_index changed
    owner_dirty:     bool,           // gpu_chunk_owner changed
    region_count:    []u32,          // non-air slots per 4^3-chunk region (world.odin)
    region_dirty:    bool,

    // Far terrain LOD (far.odin)
    far_cells:       []u32,          // FAR_CELLS_PER_TILE packed cells per tile slot
    far_tiles:       [][4]i32,       // per tile slot: owner tile x, z, max height, unused
    far_dirty:       [dynamic]int,   // tile slots whose cells need upload
    far_tiles_dirty: bool,
    far_player_tile: [2]int,         // player tile at the last far_enqueue
    far_enabled:     bool,
    near_radius_override: int,       // bench: draw voxels only this many chunks out (0 = all)
    gpu_index:       []i32,              // ring slot -> brick pool id, or uniform chunk
    gpu_chunk_owner: [][2]i32,           // ring slot -> (world_cx, world_cz)
    brick_pool:      Brick_Pool,         // free-list allocator over pool ids
    gpu_light_index: []i32,              // ring slot -> light pool id, or uniform light (light.odin)
    light_pool:      Brick_Pool,         // free-list allocator over light pool ids
    light_dirty:     [dynamic]int,       // slots whose light needs GPU upload
    stitch_queue:    [dynamic][2]int,    // integrated columns awaiting light stitching
    save_enabled:    bool,               // off in bench mode, so benches never touch saves
    last_autosave:   time.Tick,
    player_chunk:    [3]int,
    prof_frames:     int,

    // GPU resources
    pipeline:           ^SDL.GPUComputePipeline,
    vol_pipeline:       ^SDL.GPUComputePipeline,
    comp_pipeline:      ^SDL.GPUComputePipeline,
    bloom_pre_pipeline: ^SDL.GPUComputePipeline,
    bloom_h_pipeline:   ^SDL.GPUComputePipeline,
    bloom_v_pipeline:   ^SDL.GPUComputePipeline,
    out_texture:   ^SDL.GPUTexture,
    depth_texture: ^SDL.GPUTexture,
    vol_texture:   ^SDL.GPUTexture,    // half-res volumetric inscatter
    bloom_texture: [2]^SDL.GPUTexture, // half-res bloom ping-pong
    voxel_buf:    ^SDL.GPUBuffer,
    index_buf:    ^SDL.GPUBuffer,
    owner_buf:    ^SDL.GPUBuffer,
    mask_buf:     ^SDL.GPUBuffer,
    far_buf:      ^SDL.GPUBuffer,     // far terrain tile table, then cells (far.odin)
    light_index_buf: ^SDL.GPUBuffer,  // per-slot light pool id / uniform light (light.odin)
    light_pool_buf:  ^SDL.GPUBuffer,  // 512-byte light bricks
    entity_buf:   ^SDL.GPUBuffer,     // SDF entity list (entities.odin)

    brush_radius:  int,  // edit sphere radius, 0 = single voxel (Ctrl+scroll)
    left_pressed:  bool, // single-frame press edges — with Ctrl held a click
    right_pressed: bool, // performs exactly one edit instead of repeating

    // Settings
    light_dir:      [3]f32,
    reflect_amount: i32,
    aa_samples:     i32,   // anti-alias samples: 1/2/4 (F2 cycles)
    shadow_rays:    i32,   // near-surface shadow rays: 1 hard / 3 soft (F3)
    vol_enabled:    bool,  // volumetric god rays on/off (F4)
    vol_steps:      i32,   // volumetric march steps: 16/24/32 (F5 cycles)
    render_scale:   i32,   // internal-resolution divisor (1/2/4); pixel-art look
    render_w:       i32,   // = TEX_W / render_scale  (current scene texture size)
    render_h:       i32,   // = TEX_H / render_scale
    exposure:       f32,   // pre-tonemap multiplier (options panel)
    fog_density:    f32,   // base distance-fog density (options panel)
    cave_factor:    f32,   // 0 surface .. 1 deep underground, smoothed per frame
    sun_intensity:  f32,   // sun direct-light multiplier
    selected_block: Block_Type, // hotbar selection (keys 1-0)

    // SDF entities (entities.odin)
    entities:         [dynamic]Entity,
    entity_count:     i32,  // entities uploaded this frame
    entities_enabled: bool, // options panel toggle

    // Input state
    mouse_locked:        bool,
    last_ticks:          u64,
    left_held:           bool,
    right_held:          bool,
    space_last_press_ms: u64,
    jump_pressed:        bool, // single-frame jump signal

    // UI
    ui: UI_State,
}

main :: proc() {
    gs: Game_State
    bench := len(os.args) > 1 && os.args[1] == "bench"

    gs.reflect_amount = 1
    // Defaults are the cheap settings; each step up roughly adds a frame's
    // worth of GPU time on a GTX 1050 Ti (see `odin run . -- bench`).
    gs.aa_samples     = 1     // F2 cycles 1->2->4
    gs.shadow_rays    = 1     // F3 toggles 1<->3 (1=hard, 3=soft near)
    gs.vol_enabled    = false // F4 toggles volumetric god rays
    gs.vol_steps      = 16    // F5 cycles 16/24/32
    gs.render_scale   = RENDER_SCALE // 1 = full-res, 2/4 = pixel-art (options screen)
    gs.render_w       = TEX_W / gs.render_scale
    gs.render_h       = TEX_H / gs.render_scale
    gs.light_dir      = {0.6, 0.8, 0.4}
    gs.exposure       = 1.0
    gs.fog_density    = 0.0006 // far terrain reaches ~1900 voxels; haze starts showing past ~600
    gs.sun_intensity  = 1.9
    gs.selected_block = .Stone
    gs.brush_radius   = BRUSH_RADIUS
    gs.entities_enabled = true
    gs.far_enabled      = true
    gs.camera.pos     = find_spawn()
    if bench {
        // bench [quick] [at=x,z] [shot_dir]
        for a in os.args[2:] {
            switch {
            case a == "quick": bench_quick = true
            case strings.has_prefix(a, "at="):
                xz := strings.split(a[3:], ",", context.temp_allocator)
                x, _ := strconv.parse_int(xz[0])
                z, _ := strconv.parse_int(xz[1])
                gs.camera.pos = {f32(x) + 0.5, f32(surface_height_at(x, z)) + 3, f32(z) + 0.5}
            case: bench_shot_dir = a
            }
        }
    }
    gs.camera.yaw     = 0
    gs.camera.pitch   = -20
    gs.camera.fly_mode = false // start in walk mode

    // SDL init
    if !SDL.Init({.VIDEO, .EVENTS}) {
        fmt.eprintln("SDL.Init failed:", SDL.GetError())
        return
    }
    defer SDL.Quit()

    // Bench runs hidden and unfocusable so it never interrupts the user.
    window_flags: SDL.WindowFlags = bench ? {.HIDDEN, .NOT_FOCUSABLE} : {.RESIZABLE}
    gs.window = SDL.CreateWindow("Voxel Raytracer", TEX_W, TEX_H, window_flags)
    if gs.window == nil {
        fmt.eprintln("CreateWindow failed:", SDL.GetError())
        return
    }
    defer SDL.DestroyWindow(gs.window)

    // GPU + world setup
    worker_pool_start(&gs.pool)
    defer worker_pool_stop(&gs.pool)
    gs.dirty_slots = make([dynamic]int)
    defer delete(gs.dirty_slots)
    gs.light_dirty = make([dynamic]int)
    defer delete(gs.light_dirty)
    defer delete(gs.stitch_queue)
    if !bench { save_init(&gs) }
    generate_world(&gs)
    gpu_init(&gs)
    defer gpu_destroy(&gs)
    entities_init(&gs)
    defer delete(gs.entities)

    if bench {
        bench_run(&gs)
        return
    }

    ui_init(&gs)
    defer ui_shutdown(&gs)
    gs_ui_left_pressed_state = &gs.ui

    // Lock mouse at start
    _ = SDL.SetWindowRelativeMouseMode(gs.window, true)
    gs.mouse_locked = true

    gs.last_ticks = SDL.GetTicks()

    // Event loop
    for {
        // Delta time
        now := SDL.GetTicks()
        dt  := f32(now - gs.last_ticks) / 1000.0
        gs.last_ticks = now
        if dt > 0.1 { dt = 0.1 }

        // Input state for this frame
        move_fwd, move_back, move_left, move_right: bool
        run_fast, run_ultra: bool
        mouse_dx, mouse_dy: f32
        wheel_dy: f32
        gs.jump_pressed  = false
        gs.left_pressed  = false
        gs.right_pressed = false
        quit := false

        event: SDL.Event
        for SDL.PollEvent(&event) {
            #partial switch event.type {
            case .QUIT:
                quit = true

            case .KEY_DOWN:
                key := event.key.key
                switch key {
                case SDL.K_ESCAPE:
                    quit = true
                case SDL.K_TAB:
                    gs.mouse_locked = !gs.mouse_locked
                    _ = SDL.SetWindowRelativeMouseMode(gs.window, gs.mouse_locked)
                case SDL.K_O:
                    gs.ui.options_open = !gs.ui.options_open
                    gs.mouse_locked = !gs.ui.options_open
                    _ = SDL.SetWindowRelativeMouseMode(gs.window, gs.mouse_locked)
                case SDL.K_F1:
                    fmt.printf("Cam pos: %.1f %.1f %.1f | yaw %.1f pitch %.1f | fly=%v\n",
                        gs.camera.pos.x, gs.camera.pos.y, gs.camera.pos.z,
                        gs.camera.yaw, gs.camera.pitch, gs.camera.fly_mode)
                case SDL.K_F2:
                    gs.aa_samples = gs.aa_samples == 1 ? 2 : (gs.aa_samples == 2 ? 4 : 1)
                    fmt.printf("AA samples: %d\n", gs.aa_samples)
                case SDL.K_F3:
                    gs.shadow_rays = gs.shadow_rays == 3 ? 1 : 3
                    fmt.printf("shadow rays (near): %d\n", gs.shadow_rays)
                case SDL.K_F4:
                    gs.vol_enabled = !gs.vol_enabled
                    fmt.printf("volumetric: %v\n", gs.vol_enabled)
                case SDL.K_F5:
                    gs.vol_steps = gs.vol_steps == 16 ? 24 : (gs.vol_steps == 24 ? 32 : 16)
                    fmt.printf("volumetric steps: %d\n", gs.vol_steps)
                // Hotbar: block selection for left-click placement.
                // (Reflection bounces moved to the options panel.)
                case SDL.K_1: gs.selected_block = .Stone
                case SDL.K_2: gs.selected_block = .Dirt
                case SDL.K_3: gs.selected_block = .Grass
                case SDL.K_4: gs.selected_block = .Sand
                case SDL.K_5: gs.selected_block = .Sandstone
                case SDL.K_6: gs.selected_block = .Log
                case SDL.K_7: gs.selected_block = .Leaves
                case SDL.K_8: gs.selected_block = .Snow
                case SDL.K_9: gs.selected_block = .Terracotta
                case SDL.K_0: gs.selected_block = .Torch
                case SDL.K_SPACE:
                    if !event.key.repeat {
                        press_time := SDL.GetTicks()
                        if gs.space_last_press_ms > 0 && (press_time - gs.space_last_press_ms) <= DOUBLE_TAP_MS {
                            gs.camera.fly_mode = !gs.camera.fly_mode
                            gs.camera.velocity = {}
                            gs.space_last_press_ms = 0
                        } else {
                            gs.space_last_press_ms = press_time
                            gs.jump_pressed = true
                        }
                    }
                }

            case .MOUSE_MOTION:
                if gs.mouse_locked {
                    mouse_dx += event.motion.xrel
                    mouse_dy += event.motion.yrel
                } else {
                    gs.ui.mouse_pos = {event.motion.x, event.motion.y}
                }

            case .MOUSE_WHEEL:
                wheel_dy += event.wheel.y

            case .MOUSE_BUTTON_DOWN:
                if gs.mouse_locked {
                    if event.button.button == 1 { gs.left_held  = true; gs.left_pressed  = true }
                    if event.button.button == 3 { gs.right_held = true; gs.right_pressed = true }
                } else {
                    gs.ui.mouse_pos = {event.button.x, event.button.y}
                    if event.button.button == 1 {
                        gs.ui.mouse_left_down    = true
                        gs.ui.mouse_left_pressed = true
                    }
                }

            case .MOUSE_BUTTON_UP:
                if event.button.button == 1 { gs.left_held  = false }
                if event.button.button == 3 { gs.right_held = false }
                if event.button.button == 1 { gs.ui.mouse_left_down = false }
            }
        }

        if quit {
            if gs.save_enabled { save_all_modified(&gs) }
            break
        }

        // Keyboard held-state for movement
        kb := SDL.GetKeyboardState(nil)
        move_fwd   = kb[SDL.Scancode.W]
        move_back  = kb[SDL.Scancode.S]
        move_left  = kb[SDL.Scancode.A]
        move_right = kb[SDL.Scancode.D]
        run_fast   = kb[SDL.Scancode.LSHIFT]
        run_ultra  = kb[SDL.Scancode.LALT]

        // In fly mode, Space held moves up
        if gs.camera.fly_mode && kb[SDL.Scancode.SPACE] {
            gs.jump_pressed = true // reuse as move_up in fly
        }
        gs.camera.swim_up = kb[SDL.Scancode.SPACE]

        // Light dir: hold L + look direction. (Moved off Ctrl — Ctrl now
        // modifies edits: Ctrl+scroll = brush radius, Ctrl+click = single.)
        if gs.mouse_locked && kb[SDL.Scancode.L] {
            fwd := camera_forward(gs.camera)
            gs.light_dir = fwd
        }

        // Ctrl+scroll: edit brush radius (0 = single voxel).
        ctrl_held := bool(kb[SDL.Scancode.LCTRL])
        if ctrl_held && wheel_dy != 0 {
            gs.brush_radius = clamp(gs.brush_radius + (wheel_dy > 0 ? 1 : -1), 0, 8)
        }

        if gs.mouse_locked {
            camera_update(&gs.camera, &gs, -mouse_dx, mouse_dy, dt,
                move_fwd, move_back, move_left, move_right, gs.jump_pressed,
                run_fast, run_ultra)
        }

        // Underground-ness (0 surface .. 1 deep below): drives cave darkness
        // and cave fog in the shaders. Smoothed ~0.5 s so moving through a
        // cave mouth reads as eye adaptation instead of a pop.
        {
            surface := surface_height_at(int(gs.camera.pos.x), int(gs.camera.pos.z))
            depth_below := f32(surface) - gs.camera.pos.y
            target := clamp((depth_below - 6.0) / 18.0, 0.0, 1.0)
            gs.cave_factor += (target - gs.cave_factor) * min(1.0, dt * 2.0)
        }

        // Enqueue new chunks when crossing a chunk boundary
        new_pc := [3]int{
            floor_div(int(gs.camera.pos.x), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.y), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.z), CHUNK_VOXELS),
        }
        if new_pc != gs.player_chunk {
            gs.player_chunk = new_pc
            worker_pool_set_player(&gs.pool, new_pc[0], new_pc[2])
            enqueue_chunks(&gs)
        }

        // Integrate finished chunks from worker threads
        flat := camera_flat_forward(gs.camera)
        worker_pool_set_view(&gs.pool, flat.x, flat.z)
        integrate_ready_chunks(&gs)
        far_enqueue(&gs)
        integrate_far_tiles(&gs)
        stitch_pending_columns(&gs)

        // Edits. The brush radius is user-set (Ctrl+scroll, 0 = single voxel)
        // and applies to place AND break. Ctrl turns either button into a
        // single-shot (one edit per press — e.g. Ctrl+right with brush 0 is
        // a clean torch pickup); without Ctrl, holding repeats per frame.
        left_edit  := ctrl_held ? gs.left_pressed  : gs.left_held
        right_edit := ctrl_held ? gs.right_pressed : gs.right_held
        if gs.mouse_locked && (left_edit || right_edit) {
            fwd := camera_forward(gs.camera)
            hit, nrm, hit_ok := raycast_voxel(&gs, gs.camera.pos, fwd, 200)
            if hit_ok {
                target: [3]int
                block: Block_Type
                if left_edit {
                    target = {hit[0] + nrm[0], hit[1] + nrm[1], hit[2] + nrm[2]}
                    block  = gs.selected_block
                } else {
                    target = hit
                    block  = .Air
                }
                // Torch placement stays a single voxel regardless of brush,
                // one per click.
                radius  := gs.brush_radius
                do_edit := true
                if block == .Torch {
                    radius  = 0
                    do_edit = gs.left_pressed
                }
                if do_edit {
                    dirty: map[int]bool
                    defer delete(dirty)
                    changed: [dynamic][3]int
                    defer delete(changed)
                    edit_sphere(&gs, target, block, &dirty, &changed, radius)
                    light_on_edit(&gs, changed[:])
                    for slot in dirty { gpu_sync_slot(&gs, slot) }
                    far_update_edited(&gs, changed[:])
                }
            }
        }

        flush_gpu_uploads(&gs)
        entities_update(&gs, dt)
        gpu_render(&gs)
        ui_build_and_render(&gs, dt)
        autosave_tick(&gs)

        free_all(context.temp_allocator)

        gs.prof_frames += 1
        if gs.prof_frames >= 300 {
            profile_dump("last ~300 frames")
            profile_reset()
            gs.prof_frames = 0
        }
    }
}
