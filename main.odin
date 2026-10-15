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
    glider: Glider, // hang glider (glider.odin)
    player_anim: Player_Anim, // third-person body animation (creatures.odin)
    combat: Combat, // the sword, health, combos (combat.odin)
    slimes: Slimes, // slimes, goo, damage numbers (slime.odin)
    sky_thermals:      [MAX_SKY_THERMALS]Sky_Thermal, // strong thermals near the player, for cumulus (glider.odin)
    sky_thermal_count: int,
    sky_thermal_cell:  [2]int,
    sky_thermals_ok:   bool,

    // World
    columns:         map[[2]int]^Column, // resident columns (world.odin)
    saved_columns:   map[[2]int]bool,    // columns with a save file (save.odin)
    pool:            Worker_Pool,
    dirty_slots:     [dynamic]int,   // slots whose brick needs GPU upload
    index_dirty:     bool,           // gpu_index changed
    owner_dirty:     bool,           // gpu_chunk_owner changed
    // Which ring Z-planes (CHUNKS_W * CHUNKS_H slots each — one column's
    // slots all sit in one plane) of each slot table changed: only those
    // are uploaded, not the multi-MB tables.
    index_planes, owner_planes, light_planes: [CHUNKS_W]bool,
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
    entity_buf:   ^SDL.GPUBuffer,     // entity voxel models + instances (voxel_models.odin)
    ent_dyn_base: int,                // uint4 index of the per-frame part of entity_buf
    ent_debug:    int,                // bench only: see Camera_Uniform.ent_debug
    stage_voxel, stage_light, stage_far: Staging, // upload staging (gpu.odin)
    upload_cmd:   ^SDL.GPUCommandBuffer,  // this frame's upload commands, if any
    ent_transfer: ^SDL.GPUTransferBuffer, // persistent staging for the per-frame entity data
    ent_upload_size: int,             // bytes staged this frame, copied at the start of gpu_render

    brush_radius:  int,  // edit sphere radius, 0 = single voxel (B cycles)
    left_pressed:  bool, // single-frame press edges: a click edits at once,
    right_pressed: bool, // holding repeats every EDIT_REPEAT seconds
    edit_timer:    f32,

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
    selected_block: Block_Type, // = hotbar[hotbar_slot]
    hotbar:         [HOTBAR_SLOTS]Block_Type, // keys 1-9 / wheel; middle click and E change it
    hotbar_slot:    int,

    // Entities (entities.odin, voxel_models.odin)
    entities:         [dynamic]Entity,
    entity_count:     i32,  // entities uploaded this frame
    entities_enabled: bool, // options panel toggle
    clouds_enabled:   bool, // volumetric cumulus over thermals (options panel)

    // Input state
    mouse_locked:        bool,
    last_ticks:          u64,
    left_held:           bool,
    right_held:          bool,
    space_last_press_ms: u64,
    w_last_press_ms:     u64,  // double-tap W sprints
    sprint_latched:      bool, // ... until W is let go
    jump_pressed:        bool, // single-frame jump signal

    // UI
    ui: UI_State,
}

main :: proc() {
    gs: Game_State
    bench := len(os.args) > 1 && os.args[1] == "bench"
    if len(os.args) > 1 && os.args[1] == "sounds" {
        audio_export(len(os.args) > 2 ? os.args[2] : "sounds")
        return
    }

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
    gs.light_dir      = {0.55, 0.52, 0.65} // mid-afternoon: long shadows, golden light
    gs.exposure       = 1.0
    gs.fog_density    = 0.0006 // far terrain reaches ~1900 voxels; haze starts showing past ~600
    gs.sun_intensity  = 1.9
    gs.hotbar         = DEFAULT_HOTBAR
    gs.selected_block = gs.hotbar[0]
    gs.brush_radius   = 0
    gs.entities_enabled = true
    gs.clouds_enabled   = true
    gs.far_enabled      = true
    gs.camera.pos     = find_spawn()
    if bench {
        // bench [quick] [at=x,z] [shot_dir]
        for a in os.args[2:] {
            switch {
            case a == "quick": bench_quick = true
            case a == "glider": bench_glider = true
            case a == "entcost": bench_entcost = true
            case a == "stream": bench_stream = true
            case a == "look": bench_look = true
            case a == "ui": bench_ui = true
            case a == "combat": bench_combat = true
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
    gs.camera.fov_scale = 1
    combat_init(&gs.combat)

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
    audio_init() // after the bench return: bench runs stay silent
    defer audio_shutdown()
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
        mouse_dx, mouse_dy: f32
        wheel_dy: f32
        gs.jump_pressed  = false
        gs.left_pressed  = false
        gs.right_pressed = false
        dodge_pressed   := false
        quit := false
        playing := gs.ui.screen == .None

        event: SDL.Event
        for SDL.PollEvent(&event) {
            #partial switch event.type {
            case .QUIT:
                quit = true

            case .KEY_DOWN:
                key := event.key.key
                if event.key.repeat { break }
                // Keys that work on menu screens too.
                switch key {
                case SDL.K_ESCAPE:
                    ui_back(&gs) // pause menu, or one screen back
                case SDL.K_E:
                    if gs.ui.screen == .None || gs.ui.screen == .Inventory {
                        ui_open(&gs, gs.ui.screen == .None ? .Inventory : .None)
                    }
                case SDL.K_M:
                    audio_toggle_mute()
                    ui_toast(&gs, audio.muted ? "Sound muted" : "Sound on")
                }
                if !playing { break }
                switch key {
                case SDL.K_F1:
                    gs.ui.hud_hidden = !gs.ui.hud_hidden
                case SDL.K_F2:
                    _ = os.make_directory_all("screenshots")
                    path := fmt.tprintf("screenshots/%d.bmp", SDL.GetTicks())
                    bench_screenshot(&gs, path)
                    ui_toast(&gs, fmt.tprintf("Saved %s", path))
                case SDL.K_F3:
                    gs.ui.debug_open = !gs.ui.debug_open
                case SDL.K_H:
                    gs.ui.help_open = !gs.ui.help_open
                    gs.ui.help_t = 0
                case SDL.K_F5:
                    gs.glider.third_person = !gs.glider.third_person
                case SDL.K_F6:
                    slime_debug_spawn(&gs)
                case SDL.K_F7:
                    slimes_clear(&gs)
                case SDL.K_1 ..= SDL.K_9:
                    if gs.combat.sword { combat_toggle_sword(&gs) } // back to building
                    hotbar_select(&gs, int(key - SDL.K_1))
                case SDL.K_R:
                    combat_toggle_sword(&gs)
                case SDL.K_LSHIFT:
                    dodge_pressed = gs.combat.sword
                case SDL.K_B:
                    // Brush sizes for big edits; 0 is one block.
                    BRUSHES :: [6]int{0, 1, 2, 3, 5, 8}
                    brushes := BRUSHES
                    next := 0
                    for r, i in brushes { if r == gs.brush_radius { next = (i + 1) % len(brushes) } }
                    gs.brush_radius = brushes[next]
                    ui_toast(&gs, gs.brush_radius == 0 ? "Brush: one block" : fmt.tprintf("Brush: radius %d", gs.brush_radius))
                case SDL.K_G:
                    if gs.glider.deployed { glider_toggle_deploy(&gs) }
                    gs.glider.equipped = !gs.glider.equipped
                    if gs.glider.equipped { gs.camera.fly_mode = false }
                    ui_toast(&gs, gs.glider.equipped ? "Hang glider: jump, then Space in the air" : "Hang glider put away")
                case SDL.K_W:
                    press_time := SDL.GetTicks()
                    if press_time - gs.w_last_press_ms <= DOUBLE_TAP_MS { gs.sprint_latched = true }
                    gs.w_last_press_ms = press_time
                case SDL.K_SPACE:
                    // Glider equipped: Space in mid-air opens / releases the
                    // wing (and double-tap fly mode is off while it's on).
                    if gs.glider.equipped && glider_can_toggle(&gs) {
                        glider_toggle_deploy(&gs)
                    } else if gs.glider.equipped {
                        gs.jump_pressed = true
                    } else {
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
                    switch event.button.button {
                    case 1: gs.left_held  = true; gs.left_pressed  = true
                    case 3: gs.right_held = true; gs.right_pressed = true
                    case 2: pick_block(&gs)
                    }
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

        if gs.ui.quit_requested { quit = true }
        if quit {
            if gs.save_enabled { save_all_modified(&gs) }
            break
        }

        // Held keys. Ctrl or a double-tapped W sprints, Shift sneaks (and
        // sinks / flies down), Alt flies very fast.
        kb := SDL.GetKeyboardState(nil)
        move_fwd   := kb[SDL.Scancode.W]
        move_back  := kb[SDL.Scancode.S]
        move_left  := kb[SDL.Scancode.A]
        move_right := kb[SDL.Scancode.D]
        ctrl_held  := bool(kb[SDL.Scancode.LCTRL])
        if !move_fwd { gs.sprint_latched = false }
        sprint := ctrl_held || gs.sprint_latched
        sneak  := bool(kb[SDL.Scancode.LSHIFT]) && !gs.combat.sword // drawn, Shift dodges
        ultra  := bool(kb[SDL.Scancode.LALT])
        if !gs.mouse_locked { move_fwd, move_back, move_left, move_right, sneak = false, false, false, false, false }

        // In fly mode, Space held moves up
        if gs.camera.fly_mode && kb[SDL.Scancode.SPACE] && gs.mouse_locked {
            gs.jump_pressed = true // reuse as move_up in fly
        }
        gs.camera.swim_up = kb[SDL.Scancode.SPACE] && gs.mouse_locked

        // Light dir: hold L + look direction.
        if gs.mouse_locked && kb[SDL.Scancode.L] {
            fwd := camera_forward(gs.camera)
            gs.light_dir = fwd
        }

        // The wheel walks the hotbar (down = next).
        if wheel_dy != 0 && gs.mouse_locked && !gs.glider.deployed {
            if gs.combat.sword { combat_toggle_sword(&gs) }
            hotbar_select(&gs, (gs.hotbar_slot + (wheel_dy < 0 ? 1 : HOTBAR_SLOTS - 1)) % HOTBAR_SLOTS)
        }

        // A solid hit freezes the world for a few frames (hit stop); the
        // mouse still looks around.
        world_dt := combat_world_dt(&gs, dt)
        combat_in := Combat_Input{
            attack = gs.left_pressed, attack_held = gs.left_held, special = gs.right_pressed, dodge = dodge_pressed,
            move = {f32(int(move_right)) - f32(int(move_left)), f32(int(move_fwd)) - f32(int(move_back))},
        }
        if !gs.mouse_locked { combat_in = {} }
        combat_pre_update(&gs, combat_in, world_dt)

        if gs.mouse_locked {
            if gs.glider.deployed {
                // W pulls the bar in (fast), S flares (brake), A/D lean, Ctrl looks around.
                glider_update(&gs, -mouse_dx, mouse_dy, dt,
                    move_fwd, move_back, move_left, move_right, ctrl_held)
            } else {
                camera_update(&gs.camera, &gs, -mouse_dx, mouse_dy, world_dt,
                    move_fwd, move_back, move_left, move_right, gs.jump_pressed,
                    sprint, sneak, ultra)
            }
        }
        combat_post_update(&gs, world_dt)
        slimes_update(&gs, world_dt)
        glider_view_update(&gs, dt)
        combat_view_update(&gs, dt, world_dt)

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

        // Edits, Minecraft style: left breaks, right places. A click edits at
        // once; holding the button repeats every EDIT_REPEAT seconds. The
        // brush radius (B) applies to both; torches are always one block.
        gs.edit_timer -= dt
        breaking := gs.left_pressed  || (gs.left_held  && gs.edit_timer <= 0)
        placing  := gs.right_pressed || (gs.right_held && gs.edit_timer <= 0)
        if gs.mouse_locked && !gs.glider.deployed && !gs.combat.sword && (breaking || placing) {
            gs.edit_timer = EDIT_REPEAT
            fwd := camera_forward(gs.camera)
            hit, nrm, hit_ok := raycast_voxel(&gs, gs.camera.pos, fwd, REACH)
            if hit_ok {
                target := hit
                block  := Block_Type.Air
                if !breaking {
                    target = {hit[0] + nrm[0], hit[1] + nrm[1], hit[2] + nrm[2]}
                    block  = gs.selected_block
                }
                radius := block == .Torch ? 0 : gs.brush_radius
                // Don't build a single block into yourself.
                if block == .Air || radius > 0 || !aabb_hits_voxel(gs.camera.pos, target) {
                    old := Block_Type(u8(get_voxel(&gs, target[0], target[1], target[2])))
                    dirty: map[int]bool
                    defer delete(dirty)
                    changed: [dynamic][3]int
                    defer delete(changed)
                    edit_sphere(&gs, target, block, &dirty, &changed, radius)
                    if len(changed) > 0 { audio_edit(target, block, old, radius) }
                    light_on_edit(&gs, changed[:])
                    for slot in dirty { gpu_sync_slot(&gs, slot) }
                    far_update_edited(&gs, changed[:])
                }
            }
        }

        flush_gpu_uploads(&gs)
        entities_update(&gs, world_dt)
        audio_update(&gs, dt)
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

HOTBAR_SLOTS :: 9
DEFAULT_HOTBAR :: [HOTBAR_SLOTS]Block_Type{.Grass, .Dirt, .Stone, .Log, .Leaves, .Sand, .Snow, .Terracotta, .Torch}
EDIT_REPEAT :: f32(0.22) // seconds between edits while a mouse button is held
REACH       :: f32(200)  // voxels: building far away is half the fun here

hotbar_select :: proc(gs: ^Game_State, slot: int) {
    gs.hotbar_slot = clamp(slot, 0, HOTBAR_SLOTS - 1)
    gs.selected_block = gs.hotbar[gs.hotbar_slot]
}

// Middle click: the block you're looking at into your hand. Already on the
// hotbar? Select it; otherwise it replaces the selected slot.
pick_block :: proc(gs: ^Game_State) {
    hit, _, ok := raycast_voxel(gs, gs.camera.pos, camera_forward(gs.camera), REACH)
    if !ok { return }
    b := Block_Type(u8(get_voxel(gs, hit.x, hit.y, hit.z)))
    if b == .Air || b == .Water { return }
    for h, i in gs.hotbar {
        if h == b { hotbar_select(gs, i); return }
    }
    gs.hotbar[gs.hotbar_slot] = b
    hotbar_select(gs, gs.hotbar_slot)
}

// Whether the player's box (eye at `eye`) overlaps voxel v.
aabb_hits_voxel :: proc(eye: [3]f32, v: [3]int) -> bool {
    lo := eye - {PLAYER_HALF_W, PLAYER_EYE_HEIGHT, PLAYER_HALF_W}
    hi := eye + {PLAYER_HALF_W, PLAYER_HEAD_ABOVE, PLAYER_HALF_W}
    return f32(v.x) < hi.x && f32(v.x + 1) > lo.x &&
           f32(v.y) < hi.y && f32(v.y + 1) > lo.y &&
           f32(v.z) < hi.z && f32(v.z + 1) > lo.z
}
