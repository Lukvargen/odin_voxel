package main

import "core:fmt"
import SDL "vendor:sdl3"

DOUBLE_TAP_MS :: u64(300)

Game_State :: struct {
    // SDL3
    window:     ^SDL.Window,
    gpu_device: ^SDL.GPUDevice,

    // Camera
    camera: Camera,

    // World
    chunk_map:       map[[3]int]^Chunk,  // persistent world: all ever-generated chunks
    gpu_loaded:      map[[3]int]bool,    // which chunks are currently on the GPU ring
    pool:            Worker_Pool,
    dirty_slots:     [dynamic]int,   // slots needing GPU upload this frame
    index_dirty:     bool,
    gpu_voxels:      []u8,
    gpu_voxel_mask:  []u32,              // 16 u32 (512-bit occupancy) per ring slot
    gpu_index:       []i32,
    gpu_chunk_owner: [][2]i32,           // ring slot -> (world_cx, world_cz)
    brick_pool:      Brick_Pool,         // free-list allocator over pool ids
    player_chunk:    [3]int,
    prof_frames:     int,

    // GPU resources
    pipeline:           ^SDL.GPUComputePipeline,
    vol_pipeline:       ^SDL.GPUComputePipeline,
    comp_pipeline:      ^SDL.GPUComputePipeline,
    gi_update_pipeline: ^SDL.GPUComputePipeline,
    gi_clear_pipeline:  ^SDL.GPUComputePipeline,
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
    gi_cache_buf: ^SDL.GPUBuffer,     // world-space irradiance cache (clipmap)
    light_buf:    ^SDL.GPUBuffer,     // point-light list (lights.odin)
    entity_buf:   ^SDL.GPUBuffer,     // SDF entity list (entities.odin)

    // Emissive blocks (canonical CPU set; chunk-streaming independent).
    // Value = placement time in seconds (drives the intensity ease-in).
    torch_voxels: map[[3]int]f32,
    dying_lights: [dynamic]Dying_Light, // removed torches fading out
    brush_radius:  int,  // edit sphere radius, 0 = single voxel (Ctrl+scroll)
    left_pressed:  bool, // single-frame press edges — with Ctrl held a click
    right_pressed: bool, // performs exactly one edit instead of repeating

    // GI cache bookkeeping (see gpu_render)
    gi_cache_origin:      [3]i32,  // clipmap volume origin, in cache cells
    gi_cache_valid:       bool,    // false until the initial full clear
    gi_alpha_boost_frames: i32,    // >0: high blend floor (light changed / edit / GI re-enabled)
    gi_prev_light_dir:    [3]f32,  // for light-change detection
    gi_epoch:             i32,     // completed sweeps (rotates per-visit ray sets)
    gi_region_frames:     i32,     // >0: priority re-estimation of the region box each frame
    gi_region_min:        [3]i32,  // priority box, world-cell coords
    gi_region_max:        [3]i32,

    // Settings
    light_dir:      [3]f32,
    reflect_amount: i32,
    aa_samples:     i32,   // anti-alias samples: 1/2/4 (F2 cycles)
    shadow_rays:    i32,   // near-surface shadow rays: 1 hard / 3 soft (F3)
    vol_enabled:    bool,  // volumetric god rays on/off (F4)
    vol_steps:      i32,   // volumetric march steps: 16/24/32 (F5 cycles)
    gi_enabled:     bool,  // global illumination on/off (F6)
    gi_frame_index: i32,   // current Fibonacci direction index (0..GI_DIRS-1)
    render_scale:   i32,   // internal-resolution divisor (1/2/4); pixel-art look
    render_w:       i32,   // = TEX_W / render_scale  (current scene texture size)
    render_h:       i32,   // = TEX_H / render_scale
    exposure:       f32,   // pre-tonemap multiplier (options panel)
    fog_density:    f32,   // base distance-fog density (options panel)
    cave_factor:    f32,   // 0 surface .. 1 deep underground, smoothed per frame
    sun_intensity:  f32,   // sun direct-light multiplier
    selected_block: Block_Type, // hotbar selection (keys 1-5)
    light_count:    i32,   // active point lights uploaded this frame

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

    gs.reflect_amount = 1
    gs.aa_samples     = 2   // F2 cycles 4->2->1
    gs.shadow_rays    = 3   // F3 toggles 1<->3 (1=hard, 3=soft near); soft is cheap since the two-level shadow DDA
    gs.vol_enabled    = true // F4 toggles volumetric god rays
    gs.vol_steps      = 16   // measured: 16 = 55 FPS (~baseline), 24/32 cost more for little visual gain. F5 cycles 16/24/32
    gs.gi_enabled     = true // F6 toggles GI; cache converges over a sweep (~GI_SWEEP_FRAMES frames)
    gs.gi_frame_index = 0
    gs.render_scale   = RENDER_SCALE // 1 = full-res, 2/4 = pixel-art (options screen)
    gs.render_w       = TEX_W / gs.render_scale
    gs.render_h       = TEX_H / gs.render_scale
    gs.light_dir      = {0.6, 0.8, 0.4}
    gs.exposure       = 1.0
    gs.fog_density    = 0.0012
    gs.sun_intensity  = 1.9
    gs.selected_block = .Stone
    gs.brush_radius   = BRUSH_RADIUS
    gs.entities_enabled = true
    gs.gi_prev_light_dir = gs.light_dir
    gs.camera.pos     = {0, 80, 0}
    gs.camera.yaw     = 0
    gs.camera.pitch   = -20
    gs.camera.fly_mode = false // start in walk mode

    // SDL init
    if !SDL.Init({.VIDEO, .EVENTS}) {
        fmt.eprintln("SDL.Init failed:", SDL.GetError())
        return
    }
    defer SDL.Quit()

    gs.window = SDL.CreateWindow("Voxel Raytracer", TEX_W, TEX_H, {.RESIZABLE})
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
    generate_world(&gs)
    gpu_init(&gs)
    defer gpu_destroy(&gs)
    entities_init(&gs)
    defer delete(gs.entities)

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
                    gs.aa_samples = gs.aa_samples == 4 ? 2 : (gs.aa_samples == 2 ? 1 : 4)
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
                case SDL.K_F6:
                    gs.gi_enabled = !gs.gi_enabled
                    gs.gi_frame_index = 0
                    if gs.gi_enabled { gs.gi_alpha_boost_frames = GI_SWEEP_FRAMES } // fast refresh of the stale cache
                    fmt.printf("GI: %v\n", gs.gi_enabled)
                // Hotbar: block selection for left-click placement.
                // (Reflection bounces moved to the options panel.)
                case SDL.K_1: gs.selected_block = .Stone
                case SDL.K_2: gs.selected_block = .Grass
                case SDL.K_3: gs.selected_block = .Log
                case SDL.K_4: gs.selected_block = .Leaves
                case SDL.K_5: gs.selected_block = .Torch
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

        if quit { break }

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
        integrate_ready_chunks(&gs)

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
                // Torch placement stays a single voxel regardless of brush
                // (a sphere of emitters would blow past MAX_LIGHTS) and one
                // per click (held-repeat would restart the intensity ease-in
                // every frame).
                radius  := gs.brush_radius
                do_edit := true
                if block == .Torch {
                    radius  = 0
                    do_edit = gs.left_pressed
                }
                if do_edit {
                    dirty: map[int]bool
                    defer delete(dirty)
                    edit_sphere(&gs, target, block, &dirty, radius)
                    // Keep the emissive set in sync: any torch inside the
                    // edited sphere was just overwritten (break OR place).
                    removed := lights_remove_in_sphere(&gs, target, radius)
                    if block == .Torch {
                        lights_add(&gs, target)
                    }
                    // Torch set changed → re-estimate the GI region at high
                    // priority so the lighting crossfades smoothly instead of
                    // ghosting (EMA-only) or popping dark (hard clear).
                    if block == .Torch || removed > 0 {
                        lights_queue_gi_region(&gs, target, radius)
                    }
                    for slot in dirty {
                        if refresh_chunk_index(&gs, slot) { gs.index_dirty = true }
                        append(&gs.dirty_slots, slot)
                    }
                    // Geometry changed: raise the GI blend floor for a sweep
                    // so the cache relights the edit promptly instead of
                    // nudging toward it at the steady-state 1/32 rate.
                    // Single-voxel edits skip this — their lighting impact is
                    // local (torches get the priority-region burst); the
                    // global boost would just churn the whole cache.
                    if radius > 0 {
                        gs.gi_alpha_boost_frames = GI_SWEEP_FRAMES
                    }
                }
            }
        }

        // Light direction changed (Ctrl+look)? Boost the cache EMA so the new
        // lighting overwrites stale irradiance within one sweep instead of
        // slowly blending toward it.
        dl := gs.light_dir - gs.gi_prev_light_dir
        if abs(dl.x) + abs(dl.y) + abs(dl.z) > 0.0005 {
            gs.gi_alpha_boost_frames = GI_SWEEP_FRAMES
        }
        gs.gi_prev_light_dir = gs.light_dir
        if gs.gi_alpha_boost_frames > 0 { gs.gi_alpha_boost_frames -= 1 }

        flush_gpu_uploads(&gs)
        lights_update(&gs)
        entities_update(&gs, dt)
        gpu_render(&gs)
        ui_build_and_render(&gs, dt)

        if gs.gi_enabled {
            gs.gi_frame_index = (gs.gi_frame_index + 1) % GI_SWEEP_FRAMES
            if gs.gi_frame_index == 0 { gs.gi_epoch += 1 }
        }

        gs.prof_frames += 1
        if gs.prof_frames >= 300 {
            profile_dump("last ~300 frames")
            profile_reset()
            gs.prof_frames = 0
        }
    }
}
