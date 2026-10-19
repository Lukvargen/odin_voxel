package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import SDL "vendor:sdl3"
import clay "thirdparty/clay-odin"

// The entity sandbox (the main menu's "Entity sandbox", or the `sandbox`
// argument): a flat, empty world (world_flat) with every creature lined up,
// each playing the animation picked for it. They're posed by the game's own
// code (enemy_pose, slime_add, fox_add, humanoid_add_parts...), so what
// shows here is what the game draws; only what drives the pose (the walk
// phase, the swing's timer, the slime's hop) comes from the sandbox's clock
// instead of the simulation. Nothing hunts here: monsters are off, and the
// exhibits aren't in the simulation at all. F6 and F8 still spawn live ones.
//
// The panel (Tab) picks the creature and its animation, the speed (pause,
// step a frame), the camera, and the time of day. The camera orbits the
// picked one (drag to turn it, wheel to zoom), or is free: Tab closes the
// panel and the usual keys walk and fly about.
//
// Solo hides the others, for looking at one from every side.
//
// The view is kept in saves/sandbox.txt, so a new run comes back to it:
// tools/sandbox_watch.ps1 rebuilds and restarts the sandbox on every saved
// change to the code, which is the quick way to work on a model.
//
// `sandbox <name> [anim=<anim>] shot=<dir>` draws a contact sheet instead,
// with no window to see: the four sides, then four moments of the
// animation, saved as <dir>/<name>_<anim>.png. `sandbox player looks
// shot=<dir> [close] [view=<deg>] [zoom=<k>]` draws the player in each of the looks'
// presets (player_look.odin) instead, as <dir>/player_looks[_close].png.
// The player wears your look (the Character screen's), or `look=<preset>`;
// `body=feminine` / `body=masculine` the build, for both.

Exhibit_Kind :: enum u8 {
    Player, Skeleton, Goblin, Orc, Wolf, Boar, Deer, Archer, Slinger, Spider, Slime_Small, Slime, Slime_Big, Fox, Eagle, Fish, Reef_Fish, Crystal,
}

EXHIBIT_NAMES := [Exhibit_Kind]string{
    .Player = "Player", .Skeleton = "Skeleton", .Goblin = "Goblin", .Orc = "Orc", .Wolf = "Wolf", .Boar = "Boar", .Deer = "Deer", .Archer = "Skeleton archer", .Slinger = "Goblin slinger", .Spider = "Cave spider",
    .Slime_Small = "Small slime", .Slime = "Slime", .Slime_Big = "Big slime",
    .Fox = "Fox", .Eagle = "Eagle", .Fish = "Fish", .Reef_Fish = "Reef fish", .Crystal = "Crystal",
}

// Each kind's animations; an exhibit's anim indexes its kind's.
Walker_Anim  :: enum u8 { Idle, Walk, Run, Jump, Climb, Cast }
Enemy_Anim   :: enum u8 { Idle, Walk, Run, Chop, Slash, Stagger, Die, Rise }
Slime_Anim   :: enum u8 { Idle, Hop, Leap, Hit }
Fox_Anim     :: enum u8 { Idle, Walk, Run }
Eagle_Anim   :: enum u8 { Soar, Flap }
Fish_Anim    :: enum u8 { Swim, Bolt }
Crystal_Anim :: enum u8 { Hover }

Exhibit :: struct {
    pos:   [3]f32, // feet (a flyer's or swimmer's body), world
    anim:  int,
    t:     f32,    // seconds into the animation
    slime: Slime,  // the slimes hop for real: their squash is a spring (slime_puppet)
}

Sandbox :: struct {
    on:        bool,
    exhibits:  [Exhibit_Kind]Exhibit,
    picked:    Exhibit_Kind,
    speed_i:   int,  // SANDBOX_SPEEDS
    paused:    bool,
    step:      bool, // one frame on, while paused
    orbit:     bool, // the camera circles the picked one...
    turntable: bool, // ...going round on its own
    solo:      bool, // only the picked one shows
    yaw:       f32,  // degrees: where round it the camera is (180: in front)...
    pitch:     f32,  // ...how far above...
    zoom:      f32,  // ...and how far away, in multiples of a good distance for its size
    dragging:  bool, // turning the orbit with the pointer (the panel open)
    drag:      [2]f32,
    shot_dir:  string, // contact sheets, then quit (sandbox_shots)
    close:     bool,   // `close`: the sheets framed on the head (faces)
    looks:     bool,   // `looks`: the sheet is the player in each preset (sandbox_look_shots)...
    looks_yaw: f32,    // ...seen from here (`view=`)
    shot_zoom: f32,    // `zoom=`: the sheets this close (multiples of the usual distance), on the middle
    saved:     [1024]u8, // the view as last written to SANDBOX_STATE
    saved_len: int,
    save_t:    f32,
}

SANDBOX_SPEEDS := [?]f32{0.25, 0.5, 1}
SANDBOX_STATE  :: "saves/sandbox.txt"
EXHIBIT_YAW    :: f32(math.PI) // all face the start: toward -z
ENEMY_REST     :: f32(0.8)     // seconds between an attack's recovery and the next windup
SHOT_TILE      :: 480          // a contact sheet's frames are this square

// What the arguments asked for: `sandbox <name> anim=<anim> shot=<dir> [close]`.
@(private="file")
sandbox_ask: struct {
    kind:   Exhibit_Kind,
    picked: bool,
    anim:   string,
}

// An argument for the sandbox (the creature's name, anim=, shot=); true if
// it was one. Any of them means the game starts in the sandbox.
sandbox_arg :: proc(gs: ^Game_State, a: string) -> bool {
    switch {
    case strings.has_prefix(a, "anim="):
        sandbox_ask.anim = a[5:]
    case strings.has_prefix(a, "shot="):
        gs.sandbox.shot_dir = a[5:]
    case a == "close":
        gs.sandbox.close = true
    case a == "looks":
        gs.sandbox.looks = true
    case strings.has_prefix(a, "zoom="):
        gs.sandbox.shot_zoom, _ = strconv.parse_f32(a[5:])
    case strings.has_prefix(a, "view="):
        gs.sandbox.looks_yaw, _ = strconv.parse_f32(a[5:])
    case:
        k, ok := exhibit_by_name(a)
        if !ok { return false }
        sandbox_ask.kind, sandbox_ask.picked = k, true
    }
    return true
}

// Where the sandbox's window was last time (x, y, w, h), for the next run
// to open in the same place.
sandbox_saved_window :: proc() -> (r: [4]i32, ok: bool) {
    data, err := os.read_entire_file(SANDBOX_STATE, context.temp_allocator)
    if err != nil { return }
    for line in strings.split_lines(string(data), context.temp_allocator) {
        if strings.has_prefix(line, "window=") { return parse_rect(line[7:]) }
    }
    return
}

parse_rect :: proc(s: string) -> (r: [4]i32, ok: bool) {
    parts := strings.split(s, ",", context.temp_allocator)
    if len(parts) != 4 { return }
    for p, i in parts {
        v, vok := strconv.parse_int(strings.trim_space(p))
        if !vok { return }
        r[i] = i32(v)
    }
    return r, r[2] > 0 && r[3] > 0
}

// Into the sandbox: before the world is made (world_flat), with the camera
// where it streams from.
sandbox_begin :: proc(gs: ^Game_State) {
    sb := &gs.sandbox
    sb.on = true
    world_flat = true
    save_dir = "saves/.sandbox" // never written: the server doesn't save (server_open)
    view_radius = VIEW_RADII[0] // the lineup is ~50 blocks long: the near view is plenty
    gs.camera.fly_mode = true   // no body under the camera
    gs.ui.biome_seen, gs.ui.biome_shown = true, .Plains // no "Plains" as it opens

    // The lineup, left to right as seen from the start (screen right is -x).
    x: f32
    for k in Exhibit_Kind {
        size := exhibit_size(k)
        if k != .Player { x += (exhibit_size(Exhibit_Kind(int(k) - 1)).width + size.width) * 0.5 + 2.5 }
        sb.exhibits[k].pos = {-x, 0, 0}
    }
    for &e, k in sb.exhibits {
        e.pos.x = (e.pos.x + x * 0.5) * world_scale
        e.pos.y = f32(FLAT_GROUND) + exhibit_size(k).lift * world_scale
        exhibit_reset(&e, k)
    }

    sb.picked, sb.speed_i, sb.orbit, sb.yaw, sb.pitch, sb.zoom = .Goblin, len(SANDBOX_SPEEDS) - 1, true, 210, 12, 1
    hour: f32 = 10
    panel := sandbox_load(gs, &hour)
    if sandbox_ask.picked { sb.picked, sb.orbit = sandbox_ask.kind, true }
    if sandbox_ask.anim != "" {
        for name, i in exhibit_anims(sb.picked) {
            if strings.equal_fold(name, sandbox_ask.anim) { sb.exhibits[sb.picked].anim = i }
        }
    }
    day_set_hour(gs, hour, settle = true)
    gs.day.paused = true
    if sb.orbit { sandbox_place_camera(gs) }
    if panel && sb.shot_dir == "" { ui_open(gs, .Sandbox) }
}

// ─── The exhibits ───────────────────────────────────────────────────────────

exhibit_by_name :: proc(s: string) -> (Exhibit_Kind, bool) {
    for k in Exhibit_Kind {
        if strings.equal_fold(s, fmt.tprint(k)) { return k, true }
    }
    return {}, false
}

@(private="file")
exhibit_arg_name :: proc(k: Exhibit_Kind) -> string { return strings.to_lower(fmt.tprint(k), context.temp_allocator) }

exhibit_anims :: proc(k: Exhibit_Kind) -> []string {
    switch k {
    case .Player:                        return reflect.enum_field_names(Walker_Anim)
    case .Skeleton, .Goblin, .Orc, .Wolf, .Boar, .Deer, .Archer, .Slinger, .Spider:       return reflect.enum_field_names(Enemy_Anim)
    case .Slime_Small, .Slime, .Slime_Big: return reflect.enum_field_names(Slime_Anim)
    case .Fox:                           return reflect.enum_field_names(Fox_Anim)
    case .Eagle:                         return reflect.enum_field_names(Eagle_Anim)
    case .Fish, .Reef_Fish:              return reflect.enum_field_names(Fish_Anim)
    case .Crystal:                       return reflect.enum_field_names(Crystal_Anim)
    }
    return nil
}

@(private="file")
enemy_kind_of :: proc(k: Exhibit_Kind) -> Enemy_Kind { return Enemy_Kind(int(k) - int(Exhibit_Kind.Skeleton)) }
@(private="file")
slime_size_of :: proc(k: Exhibit_Kind) -> Slime_Size { return Slime_Size(int(k) - int(Exhibit_Kind.Slime_Small)) }
@(private="file")
is_slime :: proc(k: Exhibit_Kind) -> bool { return k >= .Slime_Small && k <= .Slime_Big }

// Metres: how tall (the camera frames it), how wide (the lineup's spacing),
// how high it's held off the ground (flyers, swimmers).
@(private="file")
Exhibit_Size :: struct { height, width, lift: f32 }

@(private="file")
exhibit_size :: proc(k: Exhibit_Kind) -> Exhibit_Size {
    switch k {
    case .Player: return {1.9, 1, 0}
    case .Skeleton, .Goblin, .Orc, .Wolf, .Boar, .Deer, .Archer, .Slinger, .Spider:
        sp := ENEMY_SPECS[enemy_kind_of(k)]
        return {sp.height / world_scale, sp.radius * 2 / world_scale + 0.8, 0}
    case .Slime_Small, .Slime, .Slime_Big:
        w := SLIME_KINDS[slime_size_of(k)].width / world_scale
        return {w * 0.86, w, 0}
    case .Fox:              return {0.85, 1, 0}
    case .Eagle:            return {0.4, 3.4, 1.6}
    case .Fish, .Reef_Fish: return {0.35, 0.6, 1}
    case .Crystal:          return {1.4, 0.8, 0}
    }
    return {1, 1, 0}
}

// Seconds the animation takes to come round again.
exhibit_cycle :: proc(k: Exhibit_Kind, anim: int) -> f32 {
    switch k {
    case .Player:
        switch Walker_Anim(anim) {
        case .Idle: return 4
        case .Walk: return math.TAU / (WALK_SPEED / world_scale * 2.4)
        case .Run:  return math.TAU / (WALK_SPEED * SPRINT_FACTOR / world_scale * 2.4)
        case .Jump: return 1.2
        case .Climb: return 1.4 // a pull-up (about 0.9 s) and a moment
        case .Cast:  return 2.5
        }
    case .Skeleton, .Goblin, .Orc, .Wolf, .Boar, .Deer, .Archer, .Slinger, .Spider:
        sp := ENEMY_SPECS[enemy_kind_of(k)]
        switch Enemy_Anim(anim) {
        case .Idle:          return math.TAU / 0.7 // the look about
        case .Walk:          return math.TAU * sp.scale / (sp.walk * 2.6)
        case .Run:           return math.TAU * sp.scale / (sp.run * 2.6)
        case .Chop, .Slash:  return sp.windup + sp.strike + sp.recover + ENEMY_REST
        case .Stagger:       return 1.5
        case .Die:           return 4.5
        case .Rise:          return 2.5
        }
    case .Slime_Small, .Slime, .Slime_Big:
        kind := SLIME_KINDS[slime_size_of(k)]
        switch Slime_Anim(anim) {
        case .Idle: return 2
        case .Hop:  return max((kind.hop_every[0] + kind.hop_every[1]) * 0.5, 2 * kind.hop_up / SLIME_GRAVITY)
        case .Leap: return kind.windup + 2 * SLIME_LEAP_UP / SLIME_GRAVITY + 1
        case .Hit:  return 1.4
        }
    case .Fox:
        switch Fox_Anim(anim) {
        case .Idle: return math.TAU / 0.7
        case .Walk: return math.TAU / (FOX_WALK_SPEED * 5.5 / world_scale)
        case .Run:  return math.TAU / (FOX_FLEE_SPEED * 5.5 / world_scale)
        }
    case .Eagle:            return Eagle_Anim(anim) == .Flap ? math.TAU / 12 : math.TAU / 1.3
    case .Fish, .Reef_Fish: return math.TAU / (5 + (Fish_Anim(anim) == .Bolt ? FISH_BOLT : FISH_CRUISE) * 7)
    case .Crystal:          return math.TAU / 0.8
    }
    return 1
}

// The moment that shows an animation best (the contact sheet's four sides).
@(private="file")
exhibit_key_time :: proc(k: Exhibit_Kind, anim: int) -> f32 {
    c := exhibit_cycle(k, anim)
    #partial switch k {
    case .Skeleton, .Goblin, .Orc, .Wolf, .Boar, .Deer, .Archer, .Slinger, .Spider:
        sp := ENEMY_SPECS[enemy_kind_of(k)]
        #partial switch Enemy_Anim(anim) {
        case .Chop, .Slash: return sp.windup * 0.95 // wound up
        case .Die:          return 1.2              // down
        case .Rise:         return 0.5
        case .Stagger:      return 0.05
        }
    case .Slime_Small, .Slime, .Slime_Big:
        #partial switch Slime_Anim(anim) {
        case .Leap: return SLIME_KINDS[slime_size_of(k)].windup * 0.9
        case .Hit:  return 0.05
        }
        return c * 0.3
    case .Player:
        if Walker_Anim(anim) == .Jump { return 0.3 }
    }
    return c * 0.25
}

// Four moments that tell an animation (the contact sheet's bottom row):
// through the action for the one-off ones, evenly round the loop for gaits.
@(private="file")
exhibit_moments :: proc(k: Exhibit_Kind, anim: int) -> [4]f32 {
    c := exhibit_cycle(k, anim)
    #partial switch k {
    case .Skeleton, .Goblin, .Orc, .Wolf, .Boar, .Deer, .Archer, .Slinger, .Spider:
        sp := ENEMY_SPECS[enemy_kind_of(k)]
        #partial switch Enemy_Anim(anim) {
        case .Chop, .Slash: return {sp.windup * 0.5, sp.windup * 0.95, sp.windup + sp.strike * 0.6, sp.windup + sp.strike + sp.recover * 0.4}
        case .Die:          return {0.1, 0.25, 0.5, 2.4}
        case .Rise:         return {0.05, 0.4, 0.75, 1.1}
        case .Stagger:      return {0, 0.05, 0.2, 0.6}
        }
    case .Slime_Small, .Slime, .Slime_Big:
        kind := SLIME_KINDS[slime_size_of(k)]
        flight := 2 * SLIME_LEAP_UP / SLIME_GRAVITY
        #partial switch Slime_Anim(anim) {
        case .Leap: return {kind.windup * 0.5, kind.windup * 0.95, kind.windup + flight * 0.5, kind.windup + flight + 0.04}
        case .Hit:  return {0.01, 0.06, 0.15, 0.35}
        }
    case .Player:
        #partial switch Walker_Anim(anim) {
        case .Jump:  return {0.05, 0.2, 0.4, 0.65}
        case .Climb: return {0.05, 0.3, 0.55, 0.8}
        case .Cast:  return {0.1, 0.4, 1.2, 2.2}
        }
    }
    return {0, c * 0.25, c * 0.5, c * 0.75}
}

@(private="file")
exhibit_reset :: proc(x: ^Exhibit, k: Exhibit_Kind) {
    x.t = 0
    if is_slime(k) {
        x.slime = {alive = true, size = slime_size_of(k), pos = x.pos, yaw = EXHIBIT_YAW, on_ground = true, age = 1, color = SLIME_COLORS[0]}
    }
}

@(private="file")
exhibit_step :: proc(x: ^Exhibit, k: Exhibit_Kind, dt: f32) {
    if dt <= 0 { return }
    x.t += dt
    if !is_slime(k) { return }
    // The spring is stiff: small steps.
    n := int(math.ceil(dt * 240))
    for _ in 0 ..< n { slime_puppet(x, Slime_Anim(x.anim), dt / f32(n)) }
}

// A slime hopping in place by the rules slime_think and slime_move hop by.
@(private="file")
slime_puppet :: proc(x: ^Exhibit, anim: Slime_Anim, dt: f32) {
    sl := &x.slime
    kind := SLIME_KINDS[sl.size]
    sl.age += dt
    sl.timer -= dt
    sl.flash = max(sl.flash - dt * 4, 0)
    sl.freeze = max(sl.freeze - dt, 0)
    squash_target: f32
    switch anim {
    case .Idle:
        if sl.on_ground && sl.timer <= 0 { sl.vel.y, sl.timer = kind.hop_up * 0.7, 2 }
        if sl.on_ground && sl.timer < 0.12 { squash_target = 0.2 }
    case .Hop:
        if sl.on_ground && sl.timer <= 0 { sl.vel.y, sl.timer = kind.hop_up, (kind.hop_every[0] + kind.hop_every[1]) * 0.5 }
        if sl.on_ground && sl.timer < 0.12 { squash_target = 0.25 }
    case .Leap:
        // Sitting, the tell, the leap, sitting a moment after (the opening).
        #partial switch sl.state {
        case .Windup:
            t := 1 - sl.timer / kind.windup
            squash_target = 0.45 * t + 0.05 * math.sin(sl.age * 70) * t
            if sl.timer <= 0 {
                sl.vel.y = SLIME_LEAP_UP
                sl.state, sl.timer = .Leap, 0
                sl.squash_vel -= 8
            }
        case .Leap:
            if sl.on_ground && sl.timer < -0.1 { sl.state, sl.timer = .Idle, 0.9 }
        case:
            if sl.on_ground && sl.timer <= 0 { sl.state, sl.timer = .Windup, kind.windup }
        }
    case .Hit:
        if sl.timer <= 0 {
            sl.flash, sl.freeze, sl.timer = 1, 0.12, 1.4
            sl.squash_vel += 9
        }
    }
    K :: (7 * 2 * math.PI) * (7 * 2 * math.PI)
    C :: 2 * 0.3 * 7 * 2 * math.PI
    sl.squash_vel += ((squash_target - sl.squash) * K - sl.squash_vel * C) * dt
    sl.squash = clamp(sl.squash + sl.squash_vel * dt, -0.5, 0.65)
    if sl.vel.y != 0 || sl.pos.y > x.pos.y {
        sl.vel.y -= SLIME_GRAVITY * dt
        sl.pos.y += sl.vel.y * dt
        sl.on_ground = false
        if sl.pos.y <= x.pos.y {
            sl.squash_vel += clamp(-sl.vel.y / world_scale * 0.6, 0, 10) // splat
            sl.pos.y, sl.vel.y, sl.on_ground = x.pos.y, 0, true
        }
    }
}

// An enemy standing in for the exhibit, in the state its animation is at.
@(private="file")
enemy_puppet :: proc(x: ^Exhibit, kind: Enemy_Kind) -> Enemy {
    sp := ENEMY_SPECS[kind]
    t := x.t
    e := Enemy{alive = true, kind = kind, pos = x.pos, yaw = EXHIBIT_YAW, on_ground = true, tint = enemy_skin(kind, 0.5), age = t}
    switch Enemy_Anim(x.anim) {
    case .Idle:
    case .Walk, .Run:
        run := Enemy_Anim(x.anim) == .Run
        e.state = run ? .Chase : .Wander
        e.speed = run ? sp.run : sp.walk
        e.walk_phase = t * e.speed * 2.6 / sp.scale
    case .Chop, .Slash:
        e.swing = Enemy_Anim(x.anim) == .Chop ? .Overhead : .Slash
        u := math.mod(t, sp.windup + sp.strike + sp.recover + ENEMY_REST)
        switch {
        case u < sp.windup:                          e.state, e.timer = .Windup, sp.windup - u
        case u < sp.windup + sp.strike:              e.state, e.timer = .Strike, sp.windup + sp.strike - u
        case u < sp.windup + sp.strike + sp.recover: e.state, e.timer = .Recover, sp.windup + sp.strike + sp.recover - u
        }
    case .Stagger: // hit again and again
        u := math.mod(t, 1.5)
        e.state = .Stagger
        e.flash = max(1 - u * 3, 0)
        e.freeze = max(0.1 - u, 0)
    case .Die:
        e.state, e.death = .Dead, math.mod(t, 4.5)
    case .Rise:
        e.rising = max(1 - math.mod(t, 2.5) * 0.9, 0)
    }
    return e
}

sandbox_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    sb := &gs.sandbox
    if !sb.on { return }
    for &x, k in sb.exhibits {
        if sb.solo && k != sb.picked { continue }
        if !ent_begin(f) { return }
        exhibit_add(f, &x, k, gs.look)
        ent_end(f)
    }
}

@(private="file")
exhibit_add :: proc(f: ^Ent_Frame, x: ^Exhibit, k: Exhibit_Kind, look: Look) {
    t := x.t
    switch k {
    case .Player:
        a := Player_Anim{body_yaw = EXHIBIT_YAW}
        sp: f32 // m/s
        feet := x.pos
        fwd := [3]f32{-math.sin(EXHIBIT_YAW), 0, math.cos(EXHIBIT_YAW)}
        act: Body_Act
        switch Walker_Anim(x.anim) {
        case .Idle:
        case .Walk: sp = WALK_SPEED / world_scale
        case .Run:  sp = WALK_SPEED * SPRINT_FACTOR / world_scale
        case .Jump:
            v := min(math.mod(t, 1.2) / 0.8, 1)
            a.air = clamp(math.sin(v * math.PI) * 2.5, 0, 1)
            feet.y += 4 * v * (1 - v) * 1.1 * world_scale
        case .Climb:
            // Up onto a ledge a block and a half high in front (as mantle_pos:
            // up, then over), hands on its lip.
            u := min(math.mod(t, 1.4) / 0.9, 1)
            lip := x.pos + fwd * 0.45 * world_scale + {0, 1.5 * world_scale, 0}
            up := math.smoothstep(f32(0.1), f32(0.7), u)
            over := math.smoothstep(f32(0.6), f32(1), u)
            feet = x.pos + {0, up * 1.5 * world_scale, 0} + fwd * over * 0.8 * world_scale
            act = {climbing = u < 1, at = lip, k = u, t = t}
        case .Cast:
            // Hands up at a block four ahead, the spell coming on.
            u := math.mod(t, 2.5)
            act = {raise = math.smoothstep(f32(0), f32(0.25), u) * (1 - math.smoothstep(f32(2.2), f32(2.5), u)),
                at = x.pos + fwd * 4 * world_scale + {0, 1.2 * world_scale, 0}, k = clamp((u - 0.25) / 1.8, 0, 1), t = t}
        }
        a.walk_phase = t * sp * 2.4
        a.amp = clamp(sp / 5, 0, 1.3)
        ent_scale_about(f, feet, world_scale)
        humanoid_add_parts(f, feet, &a, -math.to_degrees(EXHIBIT_YAW), 0, look, look_paint(look), right_arm = true, act = &act)
    case .Skeleton, .Goblin, .Orc, .Wolf, .Boar, .Deer, .Archer, .Slinger, .Spider:
        e := enemy_puppet(x, enemy_kind_of(k))
        enemy_pose(f, &e)
    case .Slime_Small, .Slime, .Slime_Big:
        slime_add(f, &x.slime)
    case .Fox:
        e := Entity{pos = x.pos, yaw = EXHIBIT_YAW, kind = .Fox, scale = 1, color = FOX_TINTS[0]}
        #partial switch Fox_Anim(x.anim) {
        case .Walk: e.speed = FOX_WALK_SPEED
        case .Run:  e.speed = FOX_FLEE_SPEED
        }
        e.walk_phase = t * e.speed * 5.5 / world_scale
        ent_scale_about(f, x.pos, world_scale)
        fox_add(f, e, t)
    case .Eagle:
        e := Entity{pos = x.pos, yaw = EXHIBIT_YAW, kind = .Bird, scale = 1.6}
        ent_scale_about(f, x.pos, world_scale)
        bird_add(f, e, t, flap = Eagle_Anim(x.anim) == .Flap)
    case .Fish, .Reef_Fish:
        reef := k == .Reef_Fish
        e := Entity{pos = x.pos, yaw = EXHIBIT_YAW, kind = .Fish, scale = reef ? 0.75 : 0.8}
        e.color = reef ? TROPICAL_TINTS[0] : [3]f32{0.62, 0.72, 0.82}
        e.orbit[3] = reef ? 1 : 0
        e.speed = Fish_Anim(x.anim) == .Bolt ? FISH_BOLT : FISH_CRUISE
        e.vel = {-math.sin(EXHIBIT_YAW), 0, math.cos(EXHIBIT_YAW)} * e.speed
        e.walk_phase = t * (5 + e.speed * 7)
        ent_scale_about(f, x.pos, world_scale)
        fish_add(f, e, t)
    case .Crystal:
        ent_scale_about(f, x.pos, world_scale)
        hover := 0.15 * math.sin(t * 2)
        ent_part(f, .Crystal, x.pos + [3]f32{0, 0.75 + hover, 0}, basis_yaw(EXHIBIT_YAW + t * 0.8), {1, 1, 1})
    }
}

// ─── Driving it ─────────────────────────────────────────────────────────────

sandbox_pick :: proc(gs: ^Game_State, k: Exhibit_Kind) {
    gs.sandbox.picked = k
    gs.sandbox.orbit = true
}

sandbox_set_anim :: proc(gs: ^Game_State, anim: int) {
    sb := &gs.sandbox
    x := &sb.exhibits[sb.picked]
    x.anim = anim
    exhibit_reset(x, sb.picked)
}

@(private="file")
sandbox_toggle_pause :: proc(sb: ^Sandbox) { sb.paused = !sb.paused }

// Input the sandbox takes before the game does; true if it took it.
sandbox_event :: proc(gs: ^Game_State, ev: ^SDL.Event) -> bool {
    sb := &gs.sandbox
    over_panel := gs.ui.screen == .Sandbox && clay.PointerOver(clay.ID("SandboxPanel"))
    #partial switch ev.type {
    case .MOUSE_WHEEL:
        // Zooms the orbit, unless it's over the panel or the camera is free.
        if !sb.orbit || over_panel || gs.ui.screen != .None && gs.ui.screen != .Sandbox { return false }
        sb.zoom = clamp(sb.zoom * math.pow(f32(0.88), ev.wheel.y), 0.25, 6)
        return true
    case .MOUSE_BUTTON_DOWN:
        if gs.mouse_locked || gs.ui.screen != .Sandbox || over_panel { return false }
        if ev.button.button == 1 || ev.button.button == 3 { sb.dragging = true }
    case .MOUSE_BUTTON_UP:
        if ev.button.button == 1 || ev.button.button == 3 { sb.dragging = false }
    case .MOUSE_MOTION:
        if sb.dragging && !gs.mouse_locked { sb.drag += {ev.motion.xrel, ev.motion.yrel} }
    }
    return false
}

// A key down (not while typing); true if the sandbox took it.
sandbox_key :: proc(gs: ^Game_State, key: SDL.Keycode, mods: Mods) -> bool {
    sb := &gs.sandbox
    screen := gs.ui.screen
    if !sb.on || screen != .None && screen != .Sandbox || mods & {.Ctrl, .Alt} != {} { return false }
    switch key {
    case SDL.K_TAB:
        ui_open(gs, screen == .Sandbox ? .None : .Sandbox)
    case SDL.K_LEFT, SDL.K_RIGHT:
        sandbox_pick(gs, Exhibit_Kind(cycle(int(sb.picked), len(Exhibit_Kind), key == SDL.K_RIGHT ? 1 : -1)))
    case SDL.K_UP, SDL.K_DOWN:
        x := &sb.exhibits[sb.picked]
        sandbox_set_anim(gs, cycle(x.anim, len(exhibit_anims(sb.picked)), key == SDL.K_DOWN ? 1 : -1))
    case SDL.K_P:
        sandbox_toggle_pause(sb)
    case SDL.K_PERIOD:
        sb.paused, sb.step = true, true
    case:
        return false
    }
    return true
}

// Each frame, after the camera moved: the animations go on, the orbiting
// camera is placed. look: the mouse's movement while it's locked.
sandbox_update :: proc(gs: ^Game_State, dt: f32, look: [2]f32) {
    sb := &gs.sandbox
    adt := sb.paused ? 0 : dt * SANDBOX_SPEEDS[sb.speed_i]
    if sb.step { adt, sb.step = 1.0 / 60, false }
    for &x, k in sb.exhibits { exhibit_step(&x, k, adt) }

    turn := sb.drag
    sb.drag = {}
    if turn != {} { sb.orbit = true } // dragging with the panel open
    if gs.mouse_locked && sb.orbit { turn += look }
    if sb.orbit {
        if sb.turntable { sb.yaw += dt * 24 }
        sb.yaw = math.mod(sb.yaw - turn.x * 0.3 + 360, 360)
        sb.pitch = clamp(sb.pitch + turn.y * 0.3, -8, 80)
        sandbox_place_camera(gs)
        // A click looks; it doesn't build or swing.
        gs.left_pressed, gs.right_pressed, gs.left_held, gs.right_held = false, false, false, false
    }
    sandbox_save(gs, dt)
}

// The orbit's camera, looking at the picked one's middle.
sandbox_place_camera :: proc(gs: ^Game_State) {
    sb := &gs.sandbox
    x := &sb.exhibits[sb.picked]
    size := exhibit_size(sb.picked)
    if (sb.picked >= .Skeleton && sb.picked <= .Spider) && Enemy_Anim(x.anim) == .Die {
        size.height = 0.6 // down on the ground
    }
    target := x.pos + {0, size.height * 0.5 * world_scale, 0}
    if is_slime(sb.picked) { target.y = x.slime.pos.y + size.height * 0.5 * world_scale }
    if sb.close { target.y = x.pos.y + size.height * 0.88 * world_scale } // the head
    dist := sb.zoom * (size.height * 1.2 + max(size.width, 1) * 0.5 + 0.8) * world_scale
    a, p := math.to_radians(sb.yaw), math.to_radians(sb.pitch)
    dir := [3]f32{math.sin(a) * math.cos(p), math.sin(p), math.cos(a) * math.cos(p)}
    cam := &gs.camera
    cam.pos = target + dir * dist
    cam.yaw = math.to_degrees(math.atan2(-dir.x, -dir.z))
    cam.pitch = -sb.pitch
    cam.velocity, cam.view_offset, cam.step_visual_offset = {}, {}, 0
    cam.fly_mode = true
}

// ─── Keeping the view ───────────────────────────────────────────────────────

@(private="file")
sandbox_state :: proc(gs: ^Game_State) -> string {
    sb := &gs.sandbox
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b, "picked=%s\n", exhibit_arg_name(sb.picked))
    for x, k in sb.exhibits { fmt.sbprintf(&b, "anim.%s=%s\n", exhibit_arg_name(k), exhibit_anims(k)[x.anim]) }
    fmt.sbprintf(&b, "speed=%d\npaused=%v\norbit=%v\nturntable=%v\nsolo=%v\nyaw=%.0f\npitch=%.0f\nzoom=%.2f\nhour=%.2f\npanel=%v\n",
        sb.speed_i, sb.paused, sb.orbit, sb.turntable, sb.solo, sb.yaw, sb.pitch, sb.zoom, gs.day.hour, gs.ui.screen == .Sandbox)
    if !sb.orbit {
        c := gs.camera
        fmt.sbprintf(&b, "camera=%.1f,%.1f,%.1f,%.0f,%.0f\n", c.pos.x, c.pos.y, c.pos.z, c.yaw, c.pitch)
    }
    if r, ok := window_rect(gs); ok { fmt.sbprintf(&b, "window=%d,%d,%d,%d\n", r[0], r[1], r[2], r[3]) }
    return strings.to_string(b)
}

// Writes the view when it's changed (at most twice a second): the game may
// be ended at any moment (sandbox_watch.ps1 ends it to restart it).
@(private="file")
sandbox_save :: proc(gs: ^Game_State, dt: f32) {
    sb := &gs.sandbox
    sb.save_t -= dt
    if sb.save_t > 0 || sb.shot_dir != "" { return }
    s := sandbox_state(gs)
    if s == string(sb.saved[:sb.saved_len]) { return }
    sb.save_t = 0.5
    sb.saved_len = copy(sb.saved[:], s)
    if err := os.write_entire_file(SANDBOX_STATE, transmute([]u8)s); err != nil { fmt.eprintln("Sandbox: can't save the view:", err) }
}

@(private="file")
sandbox_load :: proc(gs: ^Game_State, hour: ^f32) -> (panel: bool) {
    sb := &gs.sandbox
    panel = true
    data, err := os.read_entire_file(SANDBOX_STATE, context.temp_allocator)
    if err != nil { return }
    for line in strings.split_lines(string(data), context.temp_allocator) {
        eq := strings.index_byte(line, '=')
        if eq < 0 { continue }
        key, v := line[:eq], line[eq + 1:]
        f, _ := strconv.parse_f32(v)
        switch {
        case key == "picked":
            if k, ok := exhibit_by_name(v); ok { sb.picked = k }
        case strings.has_prefix(key, "anim."):
            if k, ok := exhibit_by_name(key[5:]); ok {
                for name, i in exhibit_anims(k) { if name == v { sb.exhibits[k].anim = i } }
            }
        case key == "speed":     sb.speed_i = clamp(int(f), 0, len(SANDBOX_SPEEDS) - 1)
        case key == "paused":    sb.paused = v == "true"
        case key == "orbit":     sb.orbit = v == "true"
        case key == "turntable": sb.turntable = v == "true"
        case key == "solo":      sb.solo = v == "true"
        case key == "yaw":       sb.yaw = f
        case key == "pitch":     sb.pitch = f
        case key == "zoom":      sb.zoom = clamp(f, 0.25, 6)
        case key == "hour":      hour^ = clamp(f, 0, 23.99)
        case key == "panel":     panel = v == "true"
        case key == "camera":
            parts := strings.split(v, ",", context.temp_allocator)
            if len(parts) == 5 {
                c: [5]f32
                for p, i in parts { c[i], _ = strconv.parse_f32(p) }
                gs.camera.pos, gs.camera.yaw, gs.camera.pitch = {c[0], c[1], c[2]}, c[3], c[4]
            }
        }
    }
    for &x, k in sb.exhibits { exhibit_reset(&x, k) }
    return
}

// ─── The panel and the name tags ────────────────────────────────────────────

sandbox_layout :: proc(gs: ^Game_State, w, h: f32) {
    sb := &gs.sandbox
    ui := &gs.ui
    if !ui.hud_hidden { sandbox_tags(gs, w, h) }
    if ui.screen != .Sandbox {
        if ui.screen == .None && !ui.hud_hidden {
            if clay.UI(clay.ID("SandboxHint"))({
                layout = {padding = {10, 10, 5, 6}},
                floating = anchored(.LeftTop, {16, 16}),
                custom = deco(.Glass_Soft, radius = 6),
            }) {
                hint_line({"Tab", "panel"})
            }
        }
        return
    }
    if clay.UI(clay.ID("SandboxPanel"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(16), childGap = 8, sizing = {clay.SizingFixed(340), clay.SizingFit()}},
        floating = {attachTo = .Root, offset = {16, 16}, zIndex = 20, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Capture},
        custom = deco(.Glass, radius = 12),
    }) {
        text("Entity Sandbox", COLOR_ACCENT, 22, FONT_ID_TITLE)
        heading("Creature")
        names: [len(Exhibit_Kind)]string
        for k in Exhibit_Kind { names[int(k)] = EXHIBIT_NAMES[k] }
        if i := button_grid("Exhibit", names[:], int(sb.picked), 3); i >= 0 { sandbox_pick(gs, Exhibit_Kind(i)) }

        x := &sb.exhibits[sb.picked]
        heading("Animation")
        if i := button_grid("Anim", exhibit_anims(sb.picked), x.anim, 4); i >= 0 { sandbox_set_anim(gs, i) }
        // Where it is in the animation.
        cycle_s := exhibit_cycle(sb.picked, x.anim)
        u := math.mod(x.t, cycle_s) / cycle_s
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 10, childAlignment = {y = .Center}}}) {
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(6)}}, backgroundColor = COLOR_BAR_BG, cornerRadius = clay.CornerRadiusAll(3)}) {
                if clay.UI()({layout = {sizing = {clay.SizingPercent(clamp(u, 0, 1)), clay.SizingGrow()}}, backgroundColor = COLOR_ACCENT, cornerRadius = clay.CornerRadiusAll(3)}) {}
            }
            text(fmt.tprintf("%.2f / %.2f s", u * cycle_s, cycle_s), COLOR_TEXT_DIM, 13)
        }

        heading("Playback")
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
            if button(clay.ID("SbPause"), sb.paused ? "Play" : "Pause", selected = sb.paused) { sandbox_toggle_pause(sb) }
            if button(clay.ID("SbStep"), "Step") { sb.paused, sb.step = true, true }
            if button(clay.ID("SbRestart"), "Restart") { exhibit_reset(x, sb.picked) }
        }
        if i := segmented("SbSpeed", {"0.25x", "0.5x", "1x"}, sb.speed_i); i >= 0 { sb.speed_i, sb.paused = i, false }

        heading("Camera")
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
            if button(clay.ID("SbOrbit"), "Orbit", selected = sb.orbit) { sb.orbit = !sb.orbit }
            if button(clay.ID("SbTurn"), "Turntable", selected = sb.turntable) { sb.turntable = !sb.turntable; sb.orbit ||= sb.turntable }
            if button(clay.ID("SbSolo"), "Solo", selected = sb.solo) { sb.solo = !sb.solo }
        }
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
            if button(clay.ID("SbFront"), "Front") { sb.orbit, sb.yaw, sb.pitch = true, 180, 8 }
            if button(clay.ID("SbSide"), "Side") { sb.orbit, sb.yaw, sb.pitch = true, 270, 8 }
        }

        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 10, childAlignment = {y = .Center}}}) {
            text("Time of day", COLOR_TEXT, 14)
            t := gs.day.hour / 24
            hh, mm := day_clock(gs.day.hour)
            if slider(gs, clay.ID("SbHour"), &t, fmt.tprintf("%02d:%02d", hh, mm)) {
                client_send(gs, .Set_Hour, clamp(t, 0, 0.999) * 24)
            }
        }

        divider()
        hint_line({"Drag", "turn", "Wheel", "zoom", "P", "pause", ".", "a frame on"})
        hint_line({"Left Right", "creature", "Up Down", "animation", "Tab", "walk about"})
    }
}

// Keys and what they do, in pairs, on one line.
@(private="file")
hint_line :: proc(pairs: []string) {
    if clay.UI()({layout = {childGap = 5, childAlignment = {y = .Center}}}) {
        for s, i in pairs {
            if i % 2 == 0 {
                text(s, COLOR_TEXT, 12, FONT_ID_TITLE)
            } else {
                text(i < len(pairs) - 1 ? fmt.tprintf("%s   ", s) : s, COLOR_TEXT_DIM, 12)
            }
        }
    }
}

// Buttons in rows of `cols`, one selected. Returns the clicked index or -1.
@(private="file")
button_grid :: proc(id: string, labels: []string, selected, cols: int) -> int {
    clicked := -1
    if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
        for row := 0; row < len(labels); row += cols {
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
                for i in row ..< row + cols {
                    if i >= len(labels) {
                        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(32)}}}) {}
                    } else if button(clay.ID(id, u32(i)), labels[i], i == selected) {
                        clicked = i
                    }
                }
            }
        }
    }
    return clicked
}

// Each one's name over it; the picked one's animation too.
@(private="file")
sandbox_tags :: proc(gs: ^Game_State, w, h: f32) {
    sb := &gs.sandbox
    cam := gs.camera
    eye := camera_view_eye(cam)
    for &x, k in sb.exhibits {
        if sb.solo && k != sb.picked { continue }
        over := x.pos + {0, (exhibit_size(k).height + 0.35) * world_scale, 0}
        if is_slime(k) { over.y += x.slime.pos.y - x.pos.y }
        px, py, ok := glider_project(cam, over - eye, w, h)
        if !ok { continue }
        picked := k == sb.picked
        if clay.UI(clay.ID("ExhibitTag", u32(k)))({
            layout = {padding = {7, 7, 3, 4}, childGap = 6},
            floating = {attachTo = .Root, offset = {px, py}, zIndex = 6, attachment = {.CenterBottom, .LeftTop}, pointerCaptureMode = .Passthrough},
            backgroundColor = {COLOR_SHADE.r, COLOR_SHADE.g, COLOR_SHADE.b, picked ? 210 : 140},
            cornerRadius = clay.CornerRadiusAll(4),
        }) {
            text(EXHIBIT_NAMES[k], picked ? COLOR_ACCENT : COLOR_TEXT_DIM, 13, FONT_ID_TITLE)
            if picked { text(exhibit_anims(k)[x.anim], COLOR_TEXT, 13) }
        }
    }
}

// ─── Contact sheets ─────────────────────────────────────────────────────────

// The picked creature's contact sheet: the top row its four sides at the
// animation's key moment (front, front quarter, side, back), the bottom row
// four moments through the animation from the front quarter.
sandbox_shots :: proc(gs: ^Game_State) {
    sb := &gs.sandbox
    if sb.looks { sandbox_look_shots(gs); return }
    k := sb.picked
    x := &sb.exhibits[k]
    sb.orbit, sb.turntable, sb.paused, sb.solo, sb.zoom = true, false, true, true, sb.close ? 0.22 : 0.8
    if sb.shot_zoom > 0 { sb.zoom = sb.shot_zoom }
    // Everything near streamed in, the far terrain too.
    sandbox_place_camera(gs)
    bench_teleport(gs, gs.camera.pos)

    Tile :: struct { yaw, t: f32 }
    tiles: [8]Tile
    key_t := exhibit_key_time(k, x.anim)
    for yaw, i in ([4]f32{180, 215, 270, 0}) { tiles[i] = {yaw, key_t} }
    moments := exhibit_moments(k, x.anim)
    for i in 0 ..< 4 { tiles[4 + i] = {215, moments[i]} }

    w, h := int(gs.render_w), int(gs.render_h)
    sheet := make([]u8, 4 * w * 2 * h * 4)
    defer delete(sheet)
    for tile, i in tiles {
        exhibit_reset(x, k)
        for x.t < tile.t - 1e-4 { exhibit_step(x, k, min(1.0 / 60, tile.t - x.t)) }
        sb.yaw, sb.pitch = tile.yaw, 10
        sandbox_place_camera(gs)
        // The first waits for the bounce light to settle; the rest only
        // for the new pose to reach it.
        for _ in 0 ..< (i == 0 ? 120 : 20) {
            flush_gpu_uploads(gs)
            entities_update(gs, 0)
            if fence := gpu_render(gs, want_fence = true); fence != nil {
                _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
                SDL.ReleaseGPUFence(gs.gpu_device, fence)
            }
            free_all(context.temp_allocator)
        }
        pixels := bench_frame_pixels(gs)
        ox, oy := (i % 4) * w, (i / 4) * h
        for row in 0 ..< h {
            copy(sheet[((oy + row) * 4 * w + ox) * 4:][:w * 4], pixels[row * w * 4:][:w * 4])
        }
        delete(pixels)
    }
    _ = os.make_directory_all(sb.shot_dir)
    path := fmt.tprintf("%s/%s_%s.png", sb.shot_dir, exhibit_arg_name(k), strings.to_lower(exhibit_anims(k)[x.anim], context.temp_allocator))
    surf := SDL.CreateSurfaceFrom(i32(4 * w), i32(2 * h), .RGBA32, raw_data(sheet), i32(4 * w * 4))
    defer SDL.DestroySurface(surf)
    if !SDL.SavePNG(surf, strings.clone_to_cstring(path, context.temp_allocator)) {
        fmt.eprintln("Sandbox: can't save", path, SDL.GetError())
        return
    }
    fmt.printf("Sandbox: %s (top: front, quarter, side, back at %.2f s; bottom at %.2f, %.2f, %.2f, %.2f s)\n",
        path, key_t, moments[0], moments[1], moments[2], moments[3])
}

// The player in each of the presets at the animation's key moment, in rows
// of four, all seen from looks_yaw (default: the front quarter).
@(private="file")
sandbox_look_shots :: proc(gs: ^Game_State) {
    sb := &gs.sandbox
    sb.picked = .Player
    x := &sb.exhibits[.Player]
    key_t := exhibit_key_time(.Player, x.anim)
    sb.orbit, sb.turntable, sb.paused, sb.solo, sb.zoom = true, false, true, true, sb.close ? 0.22 : 0.62
    if sb.shot_zoom > 0 { sb.zoom = sb.shot_zoom }
    sb.yaw, sb.pitch = sb.looks_yaw != 0 ? sb.looks_yaw : 205, sb.close ? 4 : 10
    sandbox_place_camera(gs)
    bench_teleport(gs, gs.camera.pos)
    keep := gs.look
    defer gs.look = keep

    w, h := int(gs.render_w), int(gs.render_h)
    rows := (len(LOOK_PRESETS) + 3) / 4
    sheet := make([]u8, 4 * w * rows * h * 4)
    defer delete(sheet)
    for preset, i in LOOK_PRESETS {
        gs.look = look_apply_preset(keep, preset)
        exhibit_reset(x, .Player)
        for x.t < key_t - 1e-4 { exhibit_step(x, .Player, min(1.0 / 60, key_t - x.t)) }
        sandbox_place_camera(gs)
        for _ in 0 ..< (i == 0 ? 120 : 20) {
            flush_gpu_uploads(gs)
            entities_update(gs, 0)
            if fence := gpu_render(gs, want_fence = true); fence != nil {
                _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
                SDL.ReleaseGPUFence(gs.gpu_device, fence)
            }
            free_all(context.temp_allocator)
        }
        pixels := bench_frame_pixels(gs)
        ox, oy := (i % 4) * w, (i / 4) * h
        for row in 0 ..< h {
            copy(sheet[((oy + row) * 4 * w + ox) * 4:][:w * 4], pixels[row * w * 4:][:w * 4])
        }
        delete(pixels)
    }
    _ = os.make_directory_all(sb.shot_dir)
    anim := x.anim == 0 ? "" : fmt.tprintf("_%s", strings.to_lower(exhibit_anims(.Player)[x.anim], context.temp_allocator))
    path := fmt.tprintf("%s/player_looks%s%s%s%s.png", sb.shot_dir, keep.body == .Feminine ? "_fem" : "", anim, sb.close ? "_close" : "", sb.looks_yaw != 0 ? fmt.tprintf("_%.0f", sb.looks_yaw) : "")
    surf := SDL.CreateSurfaceFrom(i32(4 * w), i32(rows * h), .RGBA32, raw_data(sheet), i32(4 * w * 4))
    defer SDL.DestroySurface(surf)
    if !SDL.SavePNG(surf, strings.clone_to_cstring(path, context.temp_allocator)) {
        fmt.eprintln("Sandbox: can't save", path, SDL.GetError())
        return
    }
    names := make([]string, len(LOOK_PRESETS), context.temp_allocator)
    for p, i in LOOK_PRESETS { names[i] = p.name }
    fmt.printfln("Sandbox: %s (%s)", path, strings.join(names, ", ", context.temp_allocator))
}
