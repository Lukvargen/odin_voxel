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
    pipeline:      ^SDL.GPUComputePipeline,
    vol_pipeline:  ^SDL.GPUComputePipeline,
    comp_pipeline: ^SDL.GPUComputePipeline,
    out_texture:   ^SDL.GPUTexture,
    depth_texture: ^SDL.GPUTexture,
    vol_texture:   ^SDL.GPUTexture,   // half-res volumetric inscatter
    voxel_buf:   ^SDL.GPUBuffer,
    index_buf:   ^SDL.GPUBuffer,
    owner_buf:   ^SDL.GPUBuffer,
    mask_buf:    ^SDL.GPUBuffer,

    // Settings
    light_dir:      [3]f32,
    reflect_amount: i32,
    aa_samples:     i32,   // anti-alias samples: 1/2/4 (F2 cycles)
    shadow_rays:    i32,   // near-surface shadow rays: 1 hard / 3 soft (F3)
    vol_enabled:    bool,  // volumetric god rays on/off (F4)
    vol_steps:      i32,   // volumetric march steps: 16/24/32 (F5 cycles)

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
    gs.shadow_rays    = 1   // F3 toggles 1<->3 (1=hard, 3=soft near)
    gs.vol_enabled    = true // F4 toggles volumetric god rays
    gs.vol_steps      = 16   // measured: 16 = 55 FPS (~baseline), 24/32 cost more for little visual gain. F5 cycles 16/24/32
    gs.light_dir      = {0.6, 0.8, 0.4}
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
        gs.jump_pressed = false
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
                case SDL.K_1: gs.reflect_amount = 1
                case SDL.K_2: gs.reflect_amount = 2
                case SDL.K_3: gs.reflect_amount = 3
                case SDL.K_4: gs.reflect_amount = 4
                case SDL.K_5: gs.reflect_amount = 5
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

            case .MOUSE_BUTTON_DOWN:
                if gs.mouse_locked {
                    if event.button.button == 1 { gs.left_held  = true }
                    if event.button.button == 3 { gs.right_held = true }
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

        // Light dir: Ctrl + look direction
        if gs.mouse_locked && kb[SDL.Scancode.LCTRL] {
            fwd := camera_forward(gs.camera)
            gs.light_dir = fwd
        }

        if gs.mouse_locked {
            camera_update(&gs.camera, &gs, -mouse_dx, mouse_dy, dt,
                move_fwd, move_back, move_left, move_right, gs.jump_pressed,
                run_fast, run_ultra)
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

        if gs.mouse_locked && (gs.left_held || gs.right_held) {
            fwd := camera_forward(gs.camera)
            hit, nrm, hit_ok := raycast_voxel(&gs, gs.camera.pos, fwd, 200)
            if hit_ok {
                target: [3]int
                block: Block_Type
                if gs.left_held {
                    target = {hit[0] + nrm[0], hit[1] + nrm[1], hit[2] + nrm[2]}
                    block  = .Stone
                } else {
                    target = hit
                    block  = .Air
                }
                dirty: map[int]bool
                defer delete(dirty)
                edit_sphere(&gs, target, block, &dirty)
                for slot in dirty {
                    if refresh_chunk_index(&gs, slot) { gs.index_dirty = true }
                    append(&gs.dirty_slots, slot)
                }
            }
        }

        flush_gpu_uploads(&gs)
        gpu_render(&gs)
        ui_build_and_render(&gs, dt)

        gs.prof_frames += 1
        if gs.prof_frames >= 300 {
            profile_dump("last ~300 frames")
            profile_reset()
            gs.prof_frames = 0
        }
    }
}
