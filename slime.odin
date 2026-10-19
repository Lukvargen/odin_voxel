package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import la "core:math/linalg"

// Slimes, Cube World style: bouncy rounded cubes that live
// around the player (a few within SLIME_DESPAWN, topped up slowly as they die or
// get left behind).
//
// Idle they hop about; with the player near and the sword drawn (they leave
// a builder alone) they hop after them, and in
// range they squash down and shiver (the tell, eyes narrowing), then leap at
// where the player is going. A leap that lands hurts; after one they sit a
// moment, open to a punish. Hits knock them about (big ones less) and stun
// them; killed, big slimes split into two medium ones, those into two small.
//
// They aren't voxels and aren't the player: a box swept through the world
// axis by axis (like the camera), drawn as one voxel-model part
// (voxel_models.odin) squashed and stretched by its scale. Their goo and
// damage numbers are effects (fx.odin).

MAX_SLIMES        :: 40

SLIME_POPULATION  :: 2       // keep this many slimes about each player (within SLIME_DESPAWN)...
SLIME_SPAWN_EVERY :: f32(40)  // ...spawning one this often while short
SLIME_SPAWN_NEAR  :: f32(36)  // out between these (design blocks), not where it's calm (sim.odin)
SLIME_SPAWN_FAR   :: f32(54)
SLIME_DESPAWN     :: f32(90)  // and forget the ones left this far behind
SLIME_GRAVITY     : f32 = f32(26)
SLIME_AGGRO       : f32 = f32(18)  // notices the player this close...
SLIME_FORGET      : f32 = f32(32)  // ...and loses interest this far
SLIME_LEAP_UP     : f32 = f32(8)   // upward speed of the attack leap
SLIME_LEAP_MAX    : f32 = f32(16)  // horizontal speed of the leap, at most

Slime_Size :: enum u8 { Small, Medium, Big }

Slime_Kind :: struct {
    width:      f32,    // voxels (the model is 1 wide)
    hp:         f32,
    weight:     f32,    // knockback is divided by this
    damage:     f32,
    hop_speed:  f32,    // horizontal, chasing
    hop_up:     f32,
    hop_every:  [2]f32, // seconds between hops, random in this range
    leap_range: f32,
    windup:     f32,    // the tell before a leap
}

SLIME_KINDS := [Slime_Size]Slime_Kind{
    .Small  = {width = 0.7, hp = 24, weight = 1,   damage = 8,  hop_speed = 6,   hop_up = 7.5, hop_every = {0.3, 0.55}, leap_range = 5,   windup = 0.38},
    .Medium = {width = 1.2, hp = 60, weight = 1.4, damage = 14, hop_speed = 5.5, hop_up = 8,   hop_every = {0.45, 0.75}, leap_range = 6,  windup = 0.5},
    .Big    = {width = 2.0, hp = 140, weight = 2.4, damage = 24, hop_speed = 5,   hop_up = 8.5, hop_every = {0.7, 1.0},  leap_range = 7.5, windup = 0.65},
}

// The old Cube World hues, a touch softer.
SLIME_COLORS := [?][3]f32{
    {0.40, 0.78, 0.36}, // lime
    {0.32, 0.64, 0.86}, // sky
    {0.88, 0.48, 0.68}, // rose
    {0.92, 0.72, 0.30}, // honey
    {0.60, 0.46, 0.88}, // grape
}

// A colour for a slime spawning on biome b: mostly its land's own hue.
slime_color_for :: proc(b: Biome) -> [3]f32 {
    if rand.float32() < 0.35 { return SLIME_COLORS[rand.int_max(len(SLIME_COLORS))] }
    #partial switch b {
    case .Desert, .Badlands:         return SLIME_COLORS[3]
    case .Mountains, .Peaks, .Snowy: return SLIME_COLORS[1]
    case .Taiga:                     return SLIME_COLORS[4]
    }
    return SLIME_COLORS[0]
}

Slime_State :: enum u8 { Idle, Chase, Windup, Leap, Stunned }

Slime :: struct {
    alive:      bool,
    size:       Slime_Size,
    state:      Slime_State,
    pos:        [3]f32, // bottom middle
    vel:        [3]f32,
    yaw:        f32,    // entity convention: face toward {-sin, 0, cos}
    on_ground:  bool,
    hp:         f32,
    timer:      f32,    // until the next hop, the end of the tell, the stun...
    color:      [3]f32,
    hit_id:     u32,    // the last swing that hit it
    flash:      f32,    // white on a hit, fading
    squash:     f32,    // squashed flat (> 0) or stretched (< 0), on a spring
    squash_vel: f32,
    bar:        f32,    // the health bar shows for a while after a hit
    level:      u8,     // levels.odin: its health and blows scale with it
    freeze:     f32,    // stuck on the sword: held still, shuddering, then knocked away
    age:        f32,
    prey:       int,    // the player it hops after (sim.odin)
    uid:        u32,    // which slime this slot holds (a hit names it: Msg_Hit)
}

Slimes :: struct {
    list:        [MAX_SLIMES]Slime,
    spawn_timer: f32,
    last_uid:    u32,
}

slime_radius :: proc(size: Slime_Size) -> f32 { return SLIME_KINDS[size].width * 0.5 }

slime_center :: proc(sl: ^Slime) -> [3]f32 {
    return sl.pos + {0, SLIME_KINDS[sl.size].width * 0.42, 0}
}

// Collision box: half width and height.
@(private="file")
slime_box :: proc(size: Slime_Size) -> (hw, h: f32) {
    w := SLIME_KINDS[size].width
    return w * 0.4, w * 0.8
}

slime_spawn :: proc(s: ^Slimes, size: Slime_Size, pos, vel: [3]f32, color: [3]f32) -> ^Slime {
    for &sl in s.list {
        if sl.alive { continue }
        sl = {
            alive = true, size = size, pos = pos, vel = vel,
            yaw   = rand.float32_range(0, 2 * math.PI),
            timer = rand.float32_range(0.5, 2),
            color = color,
        }
        slime_set_level(&sl, monster_level(pos)) // (a split's children take their parent's)
        s.last_uid += 1
        sl.uid = s.last_uid
        return &sl
    }
    return nil
}

// One frame of every slime: spawning, thinking, hopping, falling, hurting
// the player. dt is 0 during hit stop.
slimes_update :: proc(sim: ^Sim, dt: f32) {
    s := &sim.slimes
    if dt <= 0 { return }

    // Keep a few about each player on foot: drop the ones left behind by
    // everyone, spawn while short.
    for &sl in s.list {
        if !sl.alive { continue }
        _, d := nearest_player(sim, sl.pos)
        if d > SLIME_DESPAWN || sl.pos.y < -100 { sl.alive = false }
    }
    s.spawn_timer -= dt
    if s.spawn_timer <= 0 && sim.monsters {
        s.spawn_timer = SLIME_SPAWN_EVERY
        for &p in sim.players {
            if !player_hunted(&p) || p.fly_mode { continue }
            feet := player_feet(&p)
            near := 0
            for &sl in s.list {
                if sl.alive && la.length((sl.pos - feet).xz) < SLIME_DESPAWN { near += 1 }
            }
            if near < SLIME_POPULATION { slime_try_spawn(sim, feet) }
        }
    }

    // Small steps, so a fast slime can't pass through a one-voxel wall.
    steps := max(1, int(math.ceil(dt * 120)))
    h := dt / f32(steps)
    for &sl in s.list {
        if !sl.alive { continue }
        if sl.freeze > 0 {
            sl.freeze -= dt
            continue
        }
        sl.age += dt
        sl.flash = max(sl.flash - dt * 7, 0)
        sl.bar = max(sl.bar - dt, 0)
        sl.timer -= dt
        slime_think(sim, &sl, dt)
        for _ in 0 ..< steps { slime_move(sim, &sl, h) }
    }

    // Push overlapping slimes apart.
    for i in 0 ..< MAX_SLIMES {
        a := &s.list[i]
        if !a.alive { continue }
        for j in i + 1 ..< MAX_SLIMES {
            b := &s.list[j]
            if !b.alive { continue }
            d := (b.pos - a.pos).xz
            l := la.length(d)
            min_d := (slime_radius(a.size) + slime_radius(b.size)) * 0.85
            if l < min_d && abs(b.pos.y - a.pos.y) < 1.2 * world_scale {
                n := l > 0.001 ? d / l : [2]f32{1, 0}
                push := (min_d - l) * 30 * dt
                a.vel.xz -= n * push
                b.vel.xz += n * push
            }
        }
    }
}

// Somewhere on dry, loaded ground a little way off.
@(private="file")
slime_try_spawn :: proc(sim: ^Sim, feet: [3]f32) {
    for _ in 0 ..< 8 {
        a := rand.float32_range(0, 2 * math.PI)
        r := rand.float32_range(SLIME_SPAWN_NEAR, SLIME_SPAWN_FAR) * world_scale
        x := feet.x + math.cos(a) * r
        z := feet.z + math.sin(a) * r
        if calm_at(sim, x, z) { continue }
        ix, iz := int(math.floor(x)), int(math.floor(z))
        ground := surface_height_at(ix, iz)
        if ground <= SEA_LEVEL { continue }
        // On open ground, loaded (stand_y: the surface's own block can be a
        // plant or the air above it).
        y, ok := stand_y(sim, ix, iz, ground + 2)
        if !ok { continue }
        roll := rand.float32()
        size := roll < 0.45 ? Slime_Size.Big : (roll < 0.85 ? .Medium : .Small)
        if sl := slime_spawn(&sim.slimes, size, {x, f32(y) + 0.5 * world_scale, z}, {}, slime_color_for(terrain_at(ix, iz).biome)); sl != nil {
            if sim.day.night > 0.5 { slime_set_level(sl, monster_level(sl.pos, 1)) } // tougher by night
        }
        return
    }
}

@(private="file")
slime_think :: proc(sim: ^Sim, sl: ^Slime, dt: f32) {
    kind := SLIME_KINDS[sl.size]
    // Idle, it turns to whoever is nearest; once after someone, it sticks
    // with them.
    if sl.state == .Idle || !player_hunted(&sim.players[sl.prey]) {
        if i, _ := nearest_player(sim, sl.pos); i >= 0 { sl.prey = i }
    }
    p := &sim.players[sl.prey]
    feet := player_feet(p)
    to_player := feet - sl.pos
    dist := la.length(to_player.xz)
    dir := dist > 0.01 ? to_player.xz / dist : [2]f32{-math.sin(sl.yaw), math.cos(sl.yaw)}
    squash_target: f32
    hunting := player_hunted(p) && p.sword && !p.fly_mode // sheathed, they leave you to build

    switch sl.state {
    case .Idle:
        if dist < SLIME_AGGRO && hunting {
            sl.state, sl.timer = .Chase, rand.float32_range(0.1, 0.4)
        } else if sl.on_ground && sl.timer <= 0 {
            a := rand.float32_range(0, 2 * math.PI)
            w := [2]f32{math.cos(a), math.sin(a)}
            sl.vel = {w.x * 2 * world_scale, kind.hop_up * 0.7, w.y * 2 * world_scale}
            turn_towards(&sl.yaw, w, 10)
            sl.timer = rand.float32_range(1.2, 3)
            sim_emit(sim, {kind = .Slime_Hop, slime = sl.size, pos = sl.pos, amount = 0})
        }
        if sl.on_ground && sl.timer < 0.12 { squash_target = 0.2 }
    case .Chase:
        turn_towards(&sl.yaw, dir, dt * 6)
        if dist > SLIME_FORGET || !hunting {
            sl.state = .Idle
        } else if sl.on_ground && sl.timer <= 0 {
            if dist < kind.leap_range && abs(to_player.y) < 3 * world_scale {
                sl.state, sl.timer = .Windup, kind.windup
            } else {
                j := rand.float32_range(-0.35, 0.35)
                hop := [2]f32{dir.x * math.cos(j) - dir.y * math.sin(j), dir.x * math.sin(j) + dir.y * math.cos(j)}
                sl.vel = {hop.x * kind.hop_speed, kind.hop_up, hop.y * kind.hop_speed}
                sl.timer = rand.float32_range(kind.hop_every[0], kind.hop_every[1])
                sim_emit(sim, {kind = .Slime_Hop, slime = sl.size, pos = sl.pos, amount = 1})
            }
        }
        if sl.on_ground && sl.timer < 0.12 { squash_target = 0.25 }
    case .Windup:
        // The tell: squashing down, shivering.
        turn_towards(&sl.yaw, dir, dt * 12)
        t := 1 - sl.timer / kind.windup
        squash_target = 0.45 * t + 0.05 * math.sin(sl.age * 70) * t
        if sl.timer <= 0 {
            // Leap at where the player is going.
            target := feet + p.velocity * 0.2
            d := (target - sl.pos).xz
            flight := 2 * SLIME_LEAP_UP / SLIME_GRAVITY
            v := d / flight
            if l := la.length(v); l > SLIME_LEAP_MAX { v *= SLIME_LEAP_MAX / l }
            sl.vel = {v.x, SLIME_LEAP_UP, v.y}
            sl.state, sl.timer = .Leap, 0
            sl.squash_vel -= 8
            sim_emit(sim, {kind = .Slime_Hop, slime = sl.size, pos = sl.pos, amount = 2})
        }
    case .Leap:
        if sl.on_ground && sl.timer < -0.1 {
            sl.state, sl.timer = .Chase, 0.9 // sitting a moment after: the opening
        } else if slime_touches_player(sl, p) {
            knock := [3]f32{dir.x * 9, 5, dir.y * 9} * world_scale
            if r := player_hurt(sim, sl.prey, kind.damage * level_damage(sl.level), knock, slime_center(sl)); r != .Missed {
                if r == .Parried { sl.state, sl.timer = .Stunned, 1.2; sl.vel = [3]f32{-dir.x * 7, 6, -dir.y * 7} * world_scale; sl.flash = 1; return }
                sl.vel = [3]f32{-dir.x * 3, 4, -dir.y * 3} * world_scale
                sl.state, sl.timer = .Chase, 1
            }
        }
    case .Stunned:
        if sl.timer <= 0 && sl.on_ground {
            sl.state, sl.timer = .Chase, rand.float32_range(0.2, 0.5)
        }
    }

    // The player can't walk into a slime: the two push apart, the player
    // less (its client steps itself out: monsters_push_player).
    if over, ok := slime_overlap(sl, p.pos); ok {
        sl.vel.xz -= dir * over * 40 * dt / kind.weight
    }

    // Jiggle on a loose spring.
    K :: (7 * 2 * math.PI) * (7 * 2 * math.PI)
    C :: 2 * 0.3 * 7 * 2 * math.PI
    sl.squash_vel += ((squash_target - sl.squash) * K - sl.squash_vel * C) * dt
    sl.squash = clamp(sl.squash + sl.squash_vel * dt, -0.5, 0.65)
}

@(private="file")
slime_move :: proc(sim: ^Sim, sl: ^Slime, dt: f32) {
    hw, h := slime_box(sl.size)
    was_on_ground := sl.on_ground
    falling := -sl.vel.y

    centre := slime_center(sl)
    in_water := block_is_watery(u8(voxel_at(sim.world, centre)))
    if in_water {
        sl.vel *= max(1 - 2 * dt, 0)
        sl.vel.y += 6 * world_scale * dt // they float
    } else if !sl.on_ground {
        sl.vel.y = max(sl.vel.y - SLIME_GRAVITY * dt, -40 * world_scale)
    }
    if sl.on_ground {
        sl.vel.xz *= math.exp(-10 * dt)
        sl.vel.y = max(sl.vel.y, 0)
    }

    d := sl.vel * dt
    p := sl.pos
    if d.x != 0 {
        if box_solid(sim.world, p + {d.x, 0, 0}, hw, h) { sl.vel.x *= -0.2 } else { p.x += d.x }
    }
    if d.z != 0 {
        if box_solid(sim.world, p + {0, 0, d.z}, hw, h) { sl.vel.z *= -0.2 } else { p.z += d.z }
    }
    if d.y != 0 {
        if box_solid(sim.world, p + {0, d.y, 0}, hw, h) {
            if d.y < 0 {
                // Settle exactly onto the voxel top below.
                top := math.floor(p.y + d.y) + 1
                if top <= p.y && !box_solid(sim.world, {p.x, top, p.z}, hw, h) { p.y = top }
            }
            sl.vel.y = 0
        } else {
            p.y += d.y
        }
    }
    // Buried by a placed block: pop out on top.
    if box_solid(sim.world, p, hw, h) { p.y = math.floor(p.y) + 1 }
    sl.pos = p
    sl.on_ground = sl.vel.y <= 0.01 && box_solid(sim.world, p - {0, 0.03, 0}, hw, h)
    if sl.on_ground && !was_on_ground && falling > 3 * world_scale {
        sl.squash_vel += clamp(falling / world_scale * 0.6, 0, 10) // splat
    }
}

// How far a player with the eye at `eye` stands inside the slime's body,
// if it does: along the ground, from the slime to the player. A leaping
// slime is going through you anyway.
slime_overlap :: proc(sl: ^Slime, eye: [3]f32) -> (over: f32, ok: bool) {
    if sl.state == .Leap { return 0, false }
    to_player := eye - {0, PLAYER_EYE_HEIGHT, 0} - sl.pos
    r := slime_radius(sl.size) * 0.85 + PLAYER_HALF_W
    dist := la.length(to_player.xz)
    if dist < r && to_player.y > -SLIME_KINDS[sl.size].width * 0.75 && to_player.y < PLAYER_EYE_HEIGHT { return r - dist, true }
    return 0, false
}

// The slime's body (a ball a little smaller than it looks) against the
// player's box.
@(private="file")
slime_touches_player :: proc(sl: ^Slime, p: ^Player) -> bool {
    c := slime_center(sl)
    r := slime_radius(sl.size) * 0.9
    eye := p.pos
    lo := eye - {PLAYER_HALF_W, PLAYER_EYE_HEIGHT, PLAYER_HALF_W}
    hi := eye + {PLAYER_HALF_W, PLAYER_HEAD_ABOVE, PLAYER_HALF_W}
    return la.length(c - la.clamp(c, lo, hi)) < r
}

// Damage a slime and knock it with velocity `knock` (divided by its
// weight). At no health left it pops, splitting into two of the next size
// down. Returns true if it died.
slime_damage :: proc(sim: ^Sim, sl: ^Slime, damage: f32, knock: [3]f32, boosted: bool) -> bool {
    s := &sim.slimes
    kind := SLIME_KINDS[sl.size]
    sl.hp -= damage
    sl.flash = 1
    sl.bar = 3
    sl.squash_vel += 9
    sl.vel = knock / kind.weight
    sl.vel.y = knock.y / math.sqrt(kind.weight)
    sl.on_ground = false
    sl.state, sl.timer = .Stunned, 0.45

    c := slime_center(sl)
    sim_emit(sim, {kind = .Slime_Hit, slime = sl.size, pos = c, vec = knock, color = sl.color, amount = damage, boosted = boosted})

    if sl.hp > 0 { return false }
    sl.alive = false
    calm_mark(sim, sl.pos)
    sim_emit(sim, {kind = .Slime_Pop, slime = sl.size, pos = c, vec = knock, color = sl.color})
    if sl.size > .Small {
        child := Slime_Size(int(sl.size) - 1)
        across := la.normalize0([3]f32{-knock.z, 0, knock.x})
        if across == 0 { across = {1, 0, 0} }
        for side in ([2]f32{-1, 1}) {
            vel := knock * 0.4 + across * side * 4 + {0, 8, 0}
            if ch := slime_spawn(s, child, sl.pos + across * side * kind.width * 0.25, vel, sl.color); ch != nil {
                slime_set_level(ch, sl.level)
                ch.state, ch.timer = .Stunned, 0.6
                ch.hit_id = sl.hit_id // not hit again by the swing that split it
                ch.squash = -0.3
                ch.age = 1
            }
        }
    }
    return true
}

// Debug (F6): a slime a few steps in front, dropping in; each press the
// next size, big to small. They only come for you with the sword drawn.
@(private="file")
debug_next_size: Slime_Size = .Big

slime_debug_spawn :: proc(gs: ^Game_State) {
    feet := gs.camera.pos - {0, PLAYER_EYE_HEIGHT, 0}
    at := feet + camera_flat_forward(gs.camera) * 4 + {0, 1.5, 0}
    size := debug_next_size
    debug_next_size = size == .Small ? .Big : Slime_Size(int(size) - 1)
    free := 0
    for sl in gs.slimes.list { if !sl.alive { free += 1 } }
    if free == 0 {
        ui_toast(gs, "Too many slimes")
        return
    }
    yaw := -math.to_radians(gs.camera.yaw) + math.PI // facing you
    client_send(gs, .Spawn, Msg_Spawn{target = .Slime, kind = u8(size), pos = at, yaw = yaw})
    ui_toast(gs, fmt.tprintf("Spawned a %v slime", size))
}

// Debug (F7): every slime gone, and none spawning for a while.
slimes_clear :: proc(sim: ^Sim) {
    for &sl in sim.slimes.list { sl.alive = false }
    sim.slimes.spawn_timer = 30
}

// Knocked out: the slimes about are flung away and calm down.
slimes_scatter :: proc(sim: ^Sim, pos: [3]f32) {
    for &sl in sim.slimes.list {
        if !sl.alive { continue }
        d := sl.pos - pos
        d.y = 0
        if la.length(d) < 16 {
            sl.vel = la.normalize0(d) * 12 + {0, 7, 0}
            sl.on_ground = false
            sl.state, sl.timer = .Idle, 3
        }
    }
}

// ─── Drawing ────────────────────────────────────────────────────────────────

// A rounded cube, face toward +z: two eyes with a glint, a small mouth,
// lighter on top, darker underneath.
@(private="file")
shape_slime :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, 0.42, 0}, {0.5, 0.42, 0.5}, 0.22) > 0 { return .Empty }
    q := [3]f32{abs(p.x), p.y, p.z}
    if p.z > 0.4 {
        if abs(q.x - 0.18) < 0.06 && abs(p.y - 0.5) < 0.1 {
            return q.x < 0.16 && p.y > 0.53 ? .Eye_White : .Eye
        }
        if q.x < 0.07 && abs(p.y - 0.3) < 0.025 { return .Mouth }
    }
    if p.y > 0.7 && q.x < 0.3 && abs(p.z + 0.05) < 0.3 { return .Slime_Light }
    if p.y < 0.12 { return .Slime_Core }
    return .Slime
}

@(private="file")
shape_goo :: proc(p: [3]f32, voxel: f32) -> Pal { return .Slime }

combat_models_bake :: proc() {
    ent_models[.Slime] = model_bake({-0.52, 0, -0.52}, {0.52, 0.86, 0.52}, 1.0 / 16, shape_slime)
    ent_models[.Goo]   = model_bake({-0.0625, -0.0625, -0.0625}, {0.0625, 0.0625, 0.0625}, 1.0 / 16, shape_goo)
    // Chunky hand-held things: voxel centres on whole multiples of HAND_VOXEL.
    v := HAND_VOXEL
    ent_models[.Sword]     = model_bake({-3.5 * v, -1.5 * v, -3.5 * v}, {3.5 * v, 1.5 * v, 17.5 * v}, v, shape_sword)
    ent_models[.Wood_Sword]  = model_bake({-3.5 * v, -1.5 * v, -3.5 * v}, {3.5 * v, 1.5 * v, 15.5 * v}, v, shape_wood_sword)
    ent_models[.Stone_Sword] = model_bake({-3.5 * v, -1.5 * v, -3.5 * v}, {3.5 * v, 1.5 * v, 16.5 * v}, v, shape_stone_sword)
    ent_models[.Fist]      = model_bake({-1.5 * v, -1.5 * v, -1.5 * v}, {1.5 * v, 1.5 * v, 1.5 * v}, v, shape_fist)
    ent_models[.Arm_Upper] = model_bake({-1.5 * v, -1.5 * v, 0}, {1.5 * v, 1.5 * v, 1}, v, shape_arm_upper)
    ent_models[.Arm_Fore]  = model_bake({-2.5 * v, -2.5 * v, 0}, {2.5 * v, 2.5 * v, 1}, v, shape_arm_fore)
}

// Each slime is one squashed and stretched part.
slimes_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    s := &gs.slimes
    eye := gs.camera.pos
    for &sl in s.list {
        if !sl.alive || la.length(sl.pos - eye) > ENTITY_CULL_RADIUS { continue }
        if !ent_begin(f) { return }
        slime_add(f, &sl)
        ent_end(f)
    }
}

// One slime's part (also the entity sandbox's: sandbox.odin).
slime_add :: proc(f: ^Ent_Frame, sl: ^Slime) {
    w := SLIME_KINDS[sl.size].width * min(sl.age * 5, 1) // popping into being
    sq := sl.squash - clamp(abs(sl.vel.y) * 0.02, 0, 0.2) // stretched moving fast up or down
    scale := [3]f32{w * (1 + sq * 0.5), w * (1 - sq), w * (1 + sq * 0.5)}
    tint := la.lerp(sl.color, [3]f32{2.4, 2.4, 2.4}, sl.flash * 0.8)
    pos := sl.pos
    if sl.freeze > 0 { // shuddering on the blade
        pos += [3]f32{rand.float32_range(-1, 1), rand.float32_range(-0.5, 0.5), rand.float32_range(-1, 1)} * (0.045 * w)
    }
    ent_part(f, .Slime, pos, basis_yaw(sl.yaw), scale, tint)
}
