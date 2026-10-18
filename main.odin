package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import SDL "vendor:sdl3"

DOUBLE_TAP_MS :: u64(300)

Game_State :: struct {
    using sim: Sim, // players, slimes, enemies, the day (sim.odin)
    // The voxels this client sees (world.odin); the server has its own.
    using voxels: World,
    server: Server,     // in-process: singleplayer, or hosting (server.odin)
    loop:   Loopback,   // this client's link to it (net.odin)
    net:    Client_Net, // or to a server elsewhere, and the other players (client.odin)

    // SDL3
    window:     ^SDL.Window,
    gpu_device: ^SDL.GPUDevice,

    // Camera
    camera: Camera,
    glider: Glider, // hang glider (glider.odin)
    player_anim: Player_Anim, // third-person body animation (creatures.odin)
    combat: Combat, // the sword, health, combos (combat.odin)
    fx: Effects, // goo, sparks, dust, damage numbers (fx.odin)
    sky_thermals:      [MAX_SKY_THERMALS]Sky_Thermal, // strong thermals near the player, for cumulus (glider.odin)
    sky_thermal_count: int,
    sky_thermal_cell:  [2]int,
    sky_thermals_ok:   bool,

    // World
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
    light_starved:   [dynamic]int,       // slots that wanted a light brick when none were free (retried)
    brick_starved:   [dynamic]int,       // ... and a voxel brick
    stitch_queue:    [dynamic][2]int,    // integrated columns awaiting light stitching
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
    light_pool_buf:  ^SDL.GPUBuffer,  // light bricks, a u16 per voxel
    entity_buf:   ^SDL.GPUBuffer,     // entity voxel models + instances (voxel_models.odin)
    ent_dyn_base: int,                // uint4 index of the per-frame part of entity_buf
    ent_debug:    int,                // bench only: see Camera_Uniform.ent_debug
    stage_voxel, stage_light, stage_far: Staging, // upload staging (gpu.odin)
    upload_cmd:   ^SDL.GPUCommandBuffer,  // this frame's upload commands, if any
    ent_transfer: ^SDL.GPUTransferBuffer, // persistent staging for the per-frame entity data
    ent_upload_size: int,             // bytes staged this frame, copied at the start of gpu_render

    build:         Build, // building tools: block / area / shape, undo (build_tools.odin)
    brush_radius:  int,  // edit sphere radius, 0 = single voxel (B cycles)
    left_pressed:  bool, // single-frame press edges: a click edits at once,
    right_pressed: bool, // holding repeats every EDIT_REPEAT seconds
    edit_timer:    f32,

    // Settings
    light_dir:      [3]f32,
    sky:            Sky,   // sun or moon light, mist, eye adaptation (daycycle.odin)
    reflect_amount: i32,
    aa_samples:     i32,   // anti-alias samples: 1/2/4 (options screen)
    shadow_rays:    i32,   // near-surface shadow rays: 1 hard / 3 soft (options screen)
    vol_enabled:    bool,  // volumetric god rays on/off (options screen)
    vol_steps:      i32,   // volumetric march steps: 16/24/32 (options screen)
    render_scale:   f32,   // scene resolution / window resolution (options screen)
    upscale_smooth: bool,  // scene upscaled to the window linearly, else nearest (pixel look)
    render_w:       i32,   // current scene texture size (gpu_fit_render_size)
    render_h:       i32,
    gpu_ms:         f32,   // GPU time of a frame's ray tracing, smoothed (gpu_render_timed)
    gpu_time_wait:  int,   // frames until the next timed one
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
    gi:               GI,   // bounce-light probes (gi.odin)
    torch:            Torch_Shadows, // shadows from placed torches and crystals (torch.odin)
    no_textures:      bool, // debug (F10, notex): blocks plain grey, to see the lighting alone

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
    sandbox: Sandbox, // the entity sandbox, when that's what's open (sandbox.odin)
}

// Where the game starts: the main menu, a world, or the entity sandbox.
Start :: enum u8 { Menu, World, Sandbox }

main :: proc() {
    if args := game_main(); args != nil { main_relaunch(args) } // "Main menu" (main_menu.odin)
}

// The game, from the arguments to the end; the arguments to start it again
// with when the player asked for the main menu (nil otherwise).
game_main :: proc() -> (relaunch: []string) {
    // On the heap: the UI, the server and the workers keep pointers into it.
    gs := new(Game_State)
    defer free(gs)
    // (the server points the simulation at its own world: server_init)
    net_host, net_port, join_to := false, NET_PORT, ""
    {
        // Called by your user name, until you say otherwise (name=, or the
        // Multiplayer tab).
        user := text_set(os.get_env("USERNAME", context.temp_allocator), NAME_MAX)
        if user.len == 0 { user = text_set("Player") }
        gs.ui.name_field.len = copy(gs.ui.name_field.buf[:], user.text[:user.len])
    }
    start_yaw: f32
    start_at: bool // at= given: start there, not where we were last
    start := Start.Menu
    window: [4]i32 // window=: where it was last run (x, y, w, h)
    window_given, no_focus := false, false
    server_init(&gs.server, &gs.sim, &gs.loop)
    bench := len(os.args) > 1 && os.args[1] == "bench"
    if len(os.args) > 1 && os.args[1] == "caves" { // the ground cut open (cave_map.odin)
        x, z := 0, 0
        if len(os.args) > 4 { x, _ = strconv.parse_int(os.args[3]); z, _ = strconv.parse_int(os.args[4]) }
        cave_map_export(len(os.args) > 2 ? os.args[2] : ".", x, z)
        return
    }
    if len(os.args) > 1 && os.args[1] == "map" { // terrain from above (terrain_map.odin)
        size, step := 1024, 8
        if len(os.args) > 3 { size, _ = strconv.parse_int(os.args[3]) }
        if len(os.args) > 4 { step, _ = strconv.parse_int(os.args[4]) }
        terrain_map_export(len(os.args) > 2 ? os.args[2] : "map.png", max(size, 16), max(step, 1))
        return
    }
    if len(os.args) > 1 && os.args[1] == "sounds" {
        audio_export(len(os.args) > 2 ? os.args[2] : "sounds")
        return
    }

    gs.reflect_amount = 1
    // Defaults are the cheap settings; each step up roughly adds a frame's
    // worth of GPU time on a GTX 1050 Ti (see `odin run . -- bench`).
    gs.aa_samples     = 1     // 1, 2 or 4
    gs.shadow_rays    = 1     // 1 = hard, 3 = soft near the camera
    gs.vol_enabled    = false // volumetric god rays
    gs.vol_steps      = 16    // 16, 24 or 32
    gs.render_scale   = 1 // full resolution; less = faster, blockier (options screen)
    gs.exposure       = 1.0
    gs.fog_density    = 0.0006 // far terrain reaches ~1900 voxels; haze starts showing past ~600
    gs.sun_intensity  = 1.9
    gs.hotbar         = DEFAULT_HOTBAR
    gs.selected_block = gs.hotbar[0]
    gs.brush_radius   = 0
    gs.entities_enabled = true
    gs.clouds_enabled   = true
    gs.gi.enabled       = true
    gs.torch.enabled    = true
    gs.torch.floor      = 0.35
    gs.far_enabled      = true
    gs.camera.pos     = find_spawn()
    day_init(gs)
    if bench {
        // bench [quick] [at=x,z] [shot_dir]
        world_scale_apply(TERRAIN_SCALE) // the player's size (scale.odin)
        for a in os.args[2:] {
            switch {
            case a == "quick": bench_quick = true
            case a == "glider": bench_glider = true
            case a == "entcost": bench_entcost = true
            case a == "stream": bench_stream = true
            case a == "look": bench_look = true
            case a == "ui": bench_ui = true
            case a == "landmarks": bench_landmarks = true
            case a == "trees": bench_trees = true
            case a == "caves": bench_caves = true
            case a == "players": bench_players = true
            case a == "slimes": bench_slimes = true
            case a == "enemies": bench_enemies = true
            case a == "fight": bench_fight = true
            case a == "nav": bench_nav = true
            case a == "crowd": bench_crowd = true
            case a == "build": bench_build = true
            case a == "relight": bench_relight = true
            case a == "combat": bench_combat = true
            case a == "water": bench_water = true
            case a == "sea": bench_sea = true
            case a == "climb": bench_climb = true
            case a == "doors": bench_doors = true
            case a == "plants": bench_plants = true
            case a == "hear": bench_hear = true
            case a == "gi": bench_gi = true
            case a == "gimove": bench_gi, bench_gi_move = true, true
            case a == "torch": bench_torch = true
            case a == "shade": bench_shade = true
            case strings.has_prefix(a, "hour="):
                h, _ := strconv.parse_f32(a[5:])
                day_set_hour(gs, h, settle = true)
            case a == "gi=0": gs.gi.enabled = false // bounce light from the stand-in only (gi.odin)
            // Shots only: the Short view distance loads ~5x faster than
            // Far (voxels end at 192 blocks, the far terrain beyond).
            // Never for timings: frame times depend on it.
            case a == "fast": view_radius = VIEW_RADII[0]
            case a == "ab=gi": bench_ab_gi = true
            case a == "notex": gs.no_textures = true // blocks plain grey: the lighting alone
            case strings.has_prefix(a, "world="): // a copy of a world, read only: never point it at one being played
                bench_world = true
                save_dir = strings.concatenate({"saves/", a[6:]})
            case a == "view": bench_view = true
            case strings.has_prefix(a, "pos="):
                xyz := strings.split(a[4:], ",", context.temp_allocator)
                for v, i in xyz[:min(len(xyz), 3)] { bench_view_pos[i], _ = strconv.parse_f32(v) }
            case strings.has_prefix(a, "yaw="):   bench_view_yaw, _ = strconv.parse_f32(a[4:])
            case strings.has_prefix(a, "pitch="): bench_view_pitch, _ = strconv.parse_f32(a[6:])
            case a == "torch=0": gs.torch.enabled = false // no shadows from placed torches (torch.odin)
            case strings.has_prefix(a, "torchfloor="): // share of torch light left in its shadow
                f, _ := strconv.parse_f32(a[11:])
                gs.torch.floor = clamp(f, 0, 1)
            case a == "torch=show": gs.gi.show = 3 // every shot: the torch shadow factor (white lit, black hidden)
            case a == "gi=show": gs.gi.show = 1 // every shot: the bounce light alone
            case strings.has_prefix(a, "at="):
                xz := strings.split(a[3:], ",", context.temp_allocator)
                x, _ := strconv.parse_int(xz[0])
                z, _ := strconv.parse_int(xz[1])
                gs.camera.pos = {f32(x) + 0.5, f32(surface_height_at(x, z)) + 3, f32(z) + 0.5}
            case: bench_shot_dir = a
            }
        }
    } else {
        // No arguments: the main menu (main_menu.odin). [menu]: that too,
        // whatever else is given.
        // [world=<name>]: play the world saved in saves/<name>.
        // [host] [port=<n>]: let players elsewhere join (UDP port, default NET_PORT).
        // [join=<address>[:<port>]]: play on someone's server instead.
        // [at=<x>,<z>] [yaw=<degrees>]: start there, facing that way. [hour=<h>]: at that time.
        // [name=<name>]: what other players see you called (else your user name).
        // [sandbox] [<creature>] [anim=<anim>] [shot=<dir>]: the entity
        // sandbox, looking at that creature (sandbox.odin).
        // [window=<x>,<y>,<w>,<h>]: the window there. [nofocus]: the window
        // opens without taking the keyboard (tools/sandbox_watch.ps1).
        // The player's size first: what follows (at=) places the player by it.
        for a in os.args[1:] {
            if !strings.has_prefix(a, "scale=") { continue }
            if v, ok := strconv.parse_f32(a[6:]); ok { world_scale_apply(clamp(v, 0.5, 3)) } // trying another (scale.odin)
        }
        world_scale_apply(TERRAIN_SCALE) // unless scale= did
        for a in os.args[1:] {
            switch {
            case strings.has_prefix(a, "at="):
                start_at = true
                if start == .Menu { start = .World }
                xz := strings.split(a[3:], ",", context.temp_allocator)
                if len(xz) == 2 {
                    x, okx := strconv.parse_int(xz[0])
                    z, okz := strconv.parse_int(xz[1])
                    if okx && okz { gs.camera.pos = {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5} }
                }
            case strings.has_prefix(a, "yaw="):
                start_yaw, _ = strconv.parse_f32(a[4:])
            case a == "notex": gs.no_textures = true // blocks plain grey (F10)
            case a == "f3": gs.ui.debug_open = true // the debug panel open from the start (checking things without input)
            case strings.has_prefix(a, "hour="):
                h, _ := strconv.parse_f32(a[5:])
                day_set_hour(gs, clamp(h, 0, 23.99), settle = true)
            case strings.has_prefix(a, "scale="): // done first, below
            case strings.has_prefix(a, "name="):
                t := text_set(a[5:], NAME_MAX)
                gs.ui.name_field.len = copy(gs.ui.name_field.buf[:], t.text[:t.len])
            case strings.has_prefix(a, "world="):
                save_dir = strings.concatenate({"saves/", a[6:]})
                if start == .Menu { start = .World }
            case a == "host":
                net_host = true
                if start == .Menu { start = .World }
            case strings.has_prefix(a, "port="):
                p, ok := strconv.parse_int(a[5:])
                if ok && p > 0 && p < 65536 { net_port = p } else { fmt.eprintln("Bad port:", a[5:]) }
            case strings.has_prefix(a, "join="):
                join_to = a[5:]
                if start == .Menu { start = .World }
            case a == "sandbox":
                start = .Sandbox
            case a == "menu":
            case strings.has_prefix(a, "window="):
                window, window_given = parse_rect(a[7:])
            case a == "nofocus":
                no_focus = true
            case sandbox_arg(gs, a):
                start = .Sandbox
            case:
                fmt.eprintln("Unknown argument:", a)
            }
        }
        if slice.contains(os.args[1:], "menu") { start = .Menu }
    }
    shots := start == .Sandbox && gs.sandbox.shot_dir != "" // contact sheets, no window to see (sandbox_shots)
    if start == .Sandbox && !window_given { window, window_given = sandbox_saved_window() }
    gs.camera.yaw     = start_yaw
    gs.camera.pitch   = -20
    gs.camera.fly_mode = false // start in walk mode
    gs.camera.fov_scale = 1
    if bench { gs.camera.fov = 90 } // the square view benches were tuned on
    combat_init(&gs.combat)
    build_init(&gs.build)
    defer build_destroy(&gs.build)

    // SDL init
    if !SDL.Init({.VIDEO, .EVENTS}) {
        fmt.eprintln("SDL.Init failed:", SDL.GetError())
        return
    }
    defer SDL.Quit()

    // Bench runs hidden and unfocusable so it never interrupts the user.
    window_flags: SDL.WindowFlags = bench || shots ? {.HIDDEN, .NOT_FOCUSABLE} : {.RESIZABLE}
    // The bench keeps a fixed square view so its timings and shots compare.
    win_w, win_h := i32(WINDOW_W), i32(WINDOW_H)
    if bench { win_w, win_h = BENCH_RENDER_W, BENCH_RENDER_H }
    if shots { win_w, win_h = SHOT_TILE, SHOT_TILE }
    if window_given && !bench && !shots { win_w, win_h = window[2], window[3] }
    if no_focus { SDL.SetHint(SDL.HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0") }
    gs.window = SDL.CreateWindow(GAME_NAME, win_w, win_h, window_flags)
    if gs.window == nil {
        fmt.eprintln("CreateWindow failed:", SDL.GetError())
        return
    }
    defer SDL.DestroyWindow(gs.window)
    if window_given && !bench && !shots { _ = SDL.SetWindowPosition(gs.window, window[0], window[1]) }
    gs.render_w, gs.render_h = render_size(gs)

    // GPU + world setup
    worker_pool_start(&gs.pool)
    defer worker_pool_stop(&gs.pool)
    gs.dirty_slots = make([dynamic]int)
    defer delete(gs.dirty_slots)
    gs.light_dirty = make([dynamic]int)
    defer delete(gs.light_dirty)
    defer delete(gs.light_starved)
    defer delete(gs.brick_starved)
    defer delete(gs.stitch_queue)
    gpu_device_init(gs)
    defer gpu_device_destroy(gs) // last: the UI's renderer shares it

    // The UI first: the main menu draws with it, before there's a world.
    if !bench {
        ui_init(gs)
        if !shots { audio_init() } // bench runs and contact sheets stay silent
    }
    defer if !bench { ui_shutdown(gs) } // benches that draw the HUD make their own
    defer if !bench && !shots { audio_shutdown() }
    if start == .Menu && !bench {
        choice, world := main_menu_run(gs)
        switch choice {
        case .None, .Quit: return
        case .World:       save_dir = strings.concatenate({"saves/", world})
        case .Sandbox:     start = .Sandbox
        }
    }
    if start == .Sandbox { sandbox_begin(gs) } // before the world is made: it's flat
    if !bench && !shots { main_menu_loading(gs, start == .Sandbox ? "the Entity Sandbox" : save_dir[len("saves/"):]) }

    if bench {
        // Benches drive the simulation directly, in the world they look at:
        // the generated one, or with world= a saved one's edits (never saved).
        gs.sim.world = &gs.voxels
        if bench_world {
            _ = world_open(&gs.voxels)
            gs.voxels.save_enabled = false
        }
    } else {
        // Our own server opens the world and tells us which columns differ
        // from the generated one: we fetch those from it while loading.
        server_open(&gs.server, saves = start != .Sandbox)
        server_greet_local(&gs.server, client_name(gs), resume = !start_at && start != .Sandbox)
        client_receive(gs, 0)
    }
    defer server_close(&gs.server)
    generate_world(gs)
    gpu_init(gs)
    defer gpu_destroy(gs)
    if !bench { ui_rewrap_out_texture(gs) } // the UI was made before there was a frame to show
    if start != .Sandbox { entities_init(gs) } // foxes and crystals about
    defer delete(gs.entities)

    if bench {
        bench_run(gs)
        return
    }
    if shots {
        sandbox_shots(gs)
        return
    }

    if world_in_use { ui_toast(gs, "This world is open in another game: playing without saving", 6) }

    // Multiplayer from the command line: join someone's game, or open ours
    // (the pause menu's Multiplayer tab does the same). Failing, play alone.
    defer session_shutdown(gs)
    if join_to != "" {
        session_join(gs, join_to)
    } else if net_host {
        session_host(gs, net_port)
    }

    // Lock mouse at start (not with the sandbox's panel open)
    gs.mouse_locked = gs.ui.screen == .None
    _ = SDL.SetWindowRelativeMouseMode(gs.window, gs.mouse_locked)

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
            if gs.sandbox.on && sandbox_event(gs, &event) { continue }
            #partial switch event.type {
            case .QUIT:
                quit = true

            case .TEXT_INPUT:
                ui_type_text(gs, string(event.text.text))

            case .KEY_DOWN:
                if on_key_down(gs, event.key.key, key_mods(event.key.mod), event.key.repeat, playing) { dodge_pressed = true }

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
                    case 2: pick_block(gs)
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

        if gs.ui.menu_requested { relaunch = main_menu_args(gs) }
        if gs.ui.quit_requested || gs.ui.menu_requested { quit = true }
        if quit {
            break
        }

        // Held keys. Ctrl or a double-tapped W sprints, Shift sneaks (and
        // sinks / flies down), Alt flies very fast. A menu or a text box
        // (chat) has the keyboard: then none of them count.
        kb := SDL.GetKeyboardState(nil)
        keys_free := gs.mouse_locked && gs.ui.typing == nil
        held :: proc(kb: [^]bool, free: bool, sc: SDL.Scancode) -> bool { return free && kb[sc] }
        move_fwd   := held(kb, keys_free, .W)
        move_back  := held(kb, keys_free, .S)
        move_left  := held(kb, keys_free, .A)
        move_right := held(kb, keys_free, .D)
        ctrl_held  := held(kb, keys_free, .LCTRL)
        if !move_fwd { gs.sprint_latched = false }
        sprint := ctrl_held || gs.sprint_latched
        sneak  := held(kb, keys_free, .LSHIFT) && !gs.combat.sword // drawn, Shift dodges
        ultra  := held(kb, keys_free, .LALT)

        // In fly mode, Space held moves up
        if gs.camera.fly_mode && held(kb, keys_free, .SPACE) {
            gs.jump_pressed = true // reuse as move_up in fly
        }
        gs.camera.swim_up = held(kb, keys_free, .SPACE)

        // Light dir: hold L + look direction. The sun is the server's, so
        // everyone sees it (until the clock is set or restarted, options);
        // only the host may aim it.
        if held(kb, keys_free, .L) && !client_joined(gs) {
            fwd := camera_forward(gs.camera)
            gs.day.sun = fwd // ours now; the server's says the same next step
            client_send(gs, .Set_Sun, fwd)
        }
        sky_update(gs, dt) // the clock ticks in the server (server_simulate)

        // The wheel walks the hotbar (down = next) or sizes the current
        // tool (up = bigger), by the modifiers held (build_tools.odin).
        if wheel_dy != 0 && gs.mouse_locked && !gs.glider.deployed {
            if gs.combat.sword { combat_toggle_sword(gs) }
            build_wheel(gs, wheel_dy > 0 ? 1 : -1, held_mods())
        }

        // Playing alone, the pause menu stops everything; with others about
        // (hosting or joined) nothing stops, and a menu or the inventory only
        // takes the keys and mouse: the player still falls, glides, is hit.
        play_dt := game_paused(gs) ? 0 : dt

        // A solid hit freezes the world for a few frames (hit stop); the
        // mouse still looks around.
        fx_dt := combat_fx_dt(gs, play_dt)
        combat_in := Combat_Input{
            attack = gs.left_pressed, attack_held = gs.left_held, special = gs.right_pressed, dodge = dodge_pressed,
            block = held(kb, keys_free, .F),
            move = {f32(int(move_right)) - f32(int(move_left)), f32(int(move_fwd)) - f32(int(move_back))},
        }
        if !gs.mouse_locked { combat_in = {} }
        combat_pre_update(gs, combat_in, play_dt)

        // The sandbox's camera circling a creature, until a move key frees it.
        orbiting := gs.sandbox.on && gs.sandbox.orbit
        if orbiting && (move_fwd || move_back || move_left || move_right) { gs.sandbox.orbit, orbiting = false, false }
        if play_dt > 0 && !orbiting {
            if gs.glider.deployed {
                // W pulls the bar in (fast), S flares (brake), A/D lean, Ctrl looks around.
                glider_update(gs, -mouse_dx, mouse_dy, play_dt,
                    move_fwd, move_back, move_left, move_right, ctrl_held && gs.mouse_locked)
            } else {
                camera_update(&gs.camera, gs, -mouse_dx, mouse_dy, play_dt,
                    move_fwd, move_back, move_left, move_right, gs.jump_pressed,
                    sprint, sneak, ultra)
            }
        }
        combat_post_update(gs, play_dt)

        // The world moves on: this client tells the server about its player
        // (and its sword's hits, sent above), the server steps, and the
        // client plays what happened.
        client_send_input(gs)
        if !client_joined(gs) { server_step(&gs.server, play_dt) }
        client_receive(gs, play_dt)
        fx_update(gs, fx_dt)
        glider_view_update(gs, play_dt)
        combat_view_update(gs, play_dt)
        if gs.sandbox.on { sandbox_update(gs, dt, {mouse_dx, mouse_dy}) }

        // Underground-ness (0 surface .. 1 deep below): drives cave darkness
        // and cave fog in the shaders. Smoothed ~0.5 s so moving through a
        // cave mouth reads as eye adaptation instead of a pop.
        gs.cave_factor += (cave_factor_target(gs) - gs.cave_factor) * min(1.0, play_dt * 2.0)

        // Enqueue new chunks when crossing a chunk boundary
        new_pc := [3]int{
            floor_div(int(gs.camera.pos.x), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.y), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.z), CHUNK_VOXELS),
        }
        if new_pc != gs.player_chunk {
            gs.player_chunk = new_pc
            worker_pool_set_player(&gs.pool, new_pc[0], new_pc[2])
            enqueue_chunks(gs)
        }

        // Integrate finished chunks from worker threads
        flat := camera_flat_forward(gs.camera)
        worker_pool_set_view(&gs.pool, flat.x, flat.z)
        integrate_ready_chunks(gs)
        far_enqueue(gs)
        integrate_far_tiles(gs)
        stitch_pending_columns(gs)

        // Edits with the current tool (build_tools.odin).
        build_update(gs, play_dt)

        flush_gpu_uploads(gs)
        gpu_fit_render_size(gs) // before the entity masks, which are per screen tile
        entities_update(gs, fx_dt)
        audio_update(gs, dt)
        gpu_render_timed(gs)
        ui_build_and_render(gs, dt)

        free_all(context.temp_allocator)

        gs.prof_frames += 1
        if gs.prof_frames >= 300 {
            profile_dump("last ~300 frames")
            profile_reset()
            gs.prof_frames = 0
        }
    }
    return
}

HOTBAR_SLOTS :: 9

// Whether the game stands still: only playing alone, in the pause menu.
game_paused :: proc(gs: ^Game_State) -> bool {
    return gs.ui.screen == .Pause && !client_joined(gs) && !session_hosting(gs)
}
// Underground-ness of the camera, 0 at the surface .. 1 from 24 voxels down.
cave_factor_target :: proc(gs: ^Game_State) -> f32 {
    surface := surface_height_at(int(gs.camera.pos.x), int(gs.camera.pos.z))
    depth_below := f32(surface) - gs.camera.pos.y
    return clamp((depth_below - 6.0) / 18.0, 0.0, 1.0)
}

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
    hit, _, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), REACH, plants = true)
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

// A key going down (not held keys: those are read each frame in main).
// Returns true for a dodge (Shift with the sword drawn).
on_key_down :: proc(gs: ^Game_State, key: SDL.Keycode, mods: Mods, repeat, playing: bool) -> (dodge: bool) {
    if gs.ui.typing != nil { // a text box has the keys (repeats too)
        ui_type_key(gs, key, mods)
        return
    }
    if repeat { return }
    // Ctrl and Alt combos do only what they're bound to, never the
    // plain key's action (Ctrl+3 isn't 3). Shift is sneak, so keys
    // with no Shift binding ignore it (build_tools.odin).
    plain := mods & {.Ctrl, .Alt} == {}
    // Keys that work on menu screens too.
    switch key {
    case SDL.K_ESCAPE:
        ui_back(gs) // pause menu, or one screen back
    case SDL.K_E:
        if plain && (gs.ui.screen == .None || gs.ui.screen == .Inventory) {
            ui_open(gs, gs.ui.screen == .None ? .Inventory : .None)
        }
    case SDL.K_M:
        if plain {
            audio_toggle_mute()
            ui_toast(gs, audio.muted ? "Sound muted" : "Sound on")
        }
    }
    if sandbox_key(gs, key, mods) { return }
    if !playing { return }
    // Movement keys: the modifiers are movement too (Ctrl sprints,
    // Alt flies fast, Shift sneaks or dodges), so these never care.
    switch key {
    case SDL.K_LSHIFT:
        dodge = gs.combat.sword
    case SDL.K_W:
        press_time := SDL.GetTicks()
        if press_time - gs.w_last_press_ms <= DOUBLE_TAP_MS { gs.sprint_latched = true }
        gs.w_last_press_ms = press_time
    case SDL.K_SPACE:
        // Glider equipped: Space in mid-air opens / releases the
        // wing (and double-tap fly mode is off while it's on).
        if gs.glider.equipped && glider_can_toggle(gs) {
            glider_toggle_deploy(gs)
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
    if build_key(gs, key, mods) || !plain { return }
    switch key {
    case SDL.K_RETURN, SDL.K_KP_ENTER:
        ui_open_chat(gs)
    case SDL.K_F1:
        gs.ui.hud_hidden = !gs.ui.hud_hidden
    case SDL.K_F2:
        _ = os.make_directory_all("screenshots")
        path := fmt.tprintf("screenshots/%d.bmp", SDL.GetTicks())
        bench_screenshot(gs, path)
        ui_toast(gs, fmt.tprintf("Saved %s", path))
    case SDL.K_F3:
        gs.ui.debug_open = !gs.ui.debug_open
    case SDL.K_H:
        gs.ui.help_open = !gs.ui.help_open
        gs.ui.help_t = 0
    case SDL.K_F5:
        gs.glider.third_person = !gs.glider.third_person
    case SDL.K_F6:
        slime_debug_spawn(gs)
    case SDL.K_F7:
        client_send_empty(gs, .Clear)
        ui_toast(gs, "Slimes and enemies cleared")
    case SDL.K_F9:
        // Debug: light around the player worked out again (light.odin).
        n := light_relight_near(gs, 6)
        ui_toast(gs, fmt.tprintf("Relit %d columns around you", n))
    case SDL.K_F8:
        enemy_debug_spawn(gs)
    case SDL.K_F10:
        // Debug: every block plain grey, so only light and shading show.
        gs.no_textures = !gs.no_textures
        ui_toast(gs, gs.no_textures ? "Textures off (F10)" : "Textures on")
    case SDL.K_1 ..= SDL.K_9:
        if gs.combat.sword { combat_toggle_sword(gs) } // back to building
        hotbar_select(gs, int(key - SDL.K_1))
    case SDL.K_R:
        combat_toggle_sword(gs)
    case SDL.K_G:
        if gs.glider.deployed { glider_toggle_deploy(gs) }
        gs.glider.equipped = !gs.glider.equipped
        if gs.glider.equipped { gs.camera.fly_mode = false }
        ui_toast(gs, gs.glider.equipped ? "Hang glider: jump, then Space in the air" : "Hang glider put away")
    }
    return
}
