package main

import "core:math"
import la "core:math/linalg"

// Things thrown and shot at the player: a skeleton archer's arrows, a
// goblin slinger's stones (enemies.odin: specs with a shot). The server's
// simulation flies them (Sim.shots) and decides what they hit: a player's
// box hurts them as a blow would (a guard takes it, a parry turns it
// aside), the ground or a wall stops them. The clients hear of each one
// fired (Sim_Event .Shot_Fired) and fly a copy of their own to draw
// (Game_State.shot_fx), the same way, so it needs no more messages.

Shot_Kind :: enum u8 { Arrow, Stone }

SHOT_GRAVITY := [Shot_Kind]f32{.Arrow = 7, .Stone = 12} // m/s² (world_scale at use): arrows fly flatter
SHOT_LIFE    :: f32(5)
MAX_SHOTS    :: 48

Shot :: struct {
    alive:  bool,
    kind:   Shot_Kind,
    pos:    [3]f32,
    vel:    [3]f32,
    age:    f32,
    damage: f32,
}

Shots :: struct {
    list: [MAX_SHOTS]Shot,
    next: int,
}

// Fires a shot from `from` at a target centred at `at`, moving at
// `target_vel`: led a little, and aimed above for the drop. Server side.
shot_fire :: proc(sim: ^Sim, kind: Shot_Kind, from, at, target_vel: [3]f32, speed, damage: f32) {
    g := SHOT_GRAVITY[kind] * world_scale
    d := at - from
    t := la.length(d) / max(speed, 0.01)
    aim := at + target_vel * (t * 0.6) // where they'll about be
    vel := la.normalize0(aim - from) * speed
    vel.y += 0.5 * g * t // the drop over the flight
    shot_add(&sim.shots, {kind = kind, pos = from, vel = vel, damage = damage})
    sim_emit(sim, {kind = .Shot_Fired, pos = from, vec = vel, amount = f32(kind)})
}

@(private="file")
shot_add :: proc(s: ^Shots, sh: Shot) -> ^Shot {
    slot := &s.list[s.next]
    s.next = (s.next + 1) % MAX_SHOTS
    slot^ = sh
    slot.alive = true
    return slot
}

// One step of a shot's flight: gravity, then on through the air in small
// steps; false once it's stopped by something solid or flown its time.
@(private="file")
shot_fly :: proc(w: ^World, sh: ^Shot, dt: f32) -> bool {
    sh.age += dt
    if sh.age > SHOT_LIFE { return false }
    sh.vel.y -= SHOT_GRAVITY[sh.kind] * world_scale * dt
    step := sh.vel * dt
    n := max(1, int(math.ceil(la.length(step) / 0.4)))
    for _ in 0 ..< n {
        sh.pos += step / f32(n)
        if solid_at(w, int(math.floor(sh.pos.x)), int(math.floor(sh.pos.y)), int(math.floor(sh.pos.z))) { return false }
    }
    return true
}

// Every shot in flight, server side: what it hits.
shots_update :: proc(sim: ^Sim, dt: f32) {
    if dt <= 0 { return }
    for &sh in sim.shots.list {
        if !sh.alive { continue }
        if !shot_fly(sim.world, &sh, dt) { sh.alive = false; continue }
        for &p, pi in sim.players {
            if !p.active { continue }
            PAD :: f32(0.15)
            lo := p.pos - {PLAYER_HALF_W + PAD, PLAYER_EYE_HEIGHT, PLAYER_HALF_W + PAD}
            hi := p.pos + {PLAYER_HALF_W + PAD, PLAYER_HEAD_ABOVE + PAD, PLAYER_HALF_W + PAD}
            if sh.pos.x < lo.x || sh.pos.y < lo.y || sh.pos.z < lo.z || sh.pos.x > hi.x || sh.pos.y > hi.y || sh.pos.z > hi.z { continue }
            dir := la.normalize0(sh.vel)
            knock := (dir * 4 + {0, 2, 0}) * world_scale
            // From where it came, so a guard can take it; rolled through, it flies on.
            if player_hurt(sim, pi, sh.damage, knock, sh.pos - dir * 2 * world_scale) == .Missed { continue }
            sh.alive = false
            break
        }
    }
}

// ─── The clients' copies ────────────────────────────────────────────────────

// A shot heard of: flown here to be drawn.
shot_fx_add :: proc(gs: ^Game_State, kind: Shot_Kind, pos, vel: [3]f32) {
    shot_add(&gs.shot_fx, {kind = kind, pos = pos, vel = vel})
    play_at(.Sword_Swing, pos, 0.5, (kind == .Arrow ? 1.6 : 1.2) * vary(0.06), 18) // the release: a twang, a whirr
}

// The copies fly on; one that hits the ground thuds; one at the local
// player when it was struck is spent (shot_fx_spent).
shots_fx_update :: proc(gs: ^Game_State, dt: f32) {
    if dt <= 0 { return }
    for &sh in gs.shot_fx.list {
        if !sh.alive { continue }
        if !shot_fly(gs, &sh, dt) {
            sh.alive = false
            if sh.age < SHOT_LIFE { play_at(sh.kind == .Arrow ? .Place : step_sound(.Stone), sh.pos, 0.35, (sh.kind == .Arrow ? 1.5 : 1) * vary(0.08), 12) }
        }
    }
}

// The local player was struck (or guarded, or parried): the copy flying
// at them goes too.
shot_fx_spent :: proc(gs: ^Game_State) {
    eye := gs.camera.pos
    best, at := f32(3 * world_scale), -1
    for &sh, i in gs.shot_fx.list {
        if !sh.alive { continue }
        if d := la.length(sh.pos - (eye - {0, PLAYER_EYE_HEIGHT * 0.5, 0})); d < best { best, at = d, i }
    }
    if at >= 0 { gs.shot_fx.list[at].alive = false }
}

shots_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    if !ent_begin(f) { return }
    for sh in gs.shot_fx.list {
        if !sh.alive { continue }
        z := la.normalize0(sh.vel)
        if z == 0 { z = {0, 0, 1} }
        x := la.normalize0(la.cross([3]f32{0, 1, 0}, z))
        if x == 0 { x = {1, 0, 0} }
        rot := basis_from_axes(x, la.cross(z, x), z)
        s := world_scale
        if sh.kind == .Stone { rot = basis_yaw(sh.age * 20) * basis_rot_x(sh.age * 13) } // tumbling
        ent_part(f, sh.kind == .Arrow ? .Arrow : .Pebble, sh.pos, rot, {s, s, s})
    }
    ent_end(f)
}

// ─── Models: the arrow, the stone, the bow and the sling ───────────────────

// Along +z, its middle at the origin: an iron head, a wooden shaft, pale
// fletching at the back.
@(private="file")
shape_arrow :: proc(p: [3]f32, voxel: f32) -> Pal {
    r := la.length(p.xy)
    switch {
    case p.z > 0.3:  if r < 0.03 * (0.4 - p.z) / 0.1 + 0.005 { return .Iron }
    case p.z > -0.28: if r < 0.012 { return .Wood }
    case:            if (abs(p.x) < 0.006 && abs(p.y) < 0.04) || (abs(p.y) < 0.006 && abs(p.x) < 0.04) { return .Feather_White }
                     if r < 0.012 { return .Wood }
    }
    return .Empty
}

@(private="file")
shape_pebble :: proc(p: [3]f32, voxel: f32) -> Pal {
    if la.length(p / [3]f32{1, 0.8, 1.1}) < 0.06 { return p.y > 0.02 ? .Bone_Shadow : .Iron }
    return .Empty
}

// Held at the grip (the origin), limbs along z, curving back toward the
// archer (+y, once in the hand: enemies.odin), the string across their tips.
@(private="file")
shape_bow :: proc(p: [3]f32, voxel: f32) -> Pal {
    if abs(p.z) > 0.52 || abs(p.x) > 0.02 { return .Empty }
    k := p.z / 0.52
    limb_y := 0.13 * k * k
    if abs(p.y - limb_y) < (abs(p.z) < 0.07 ? 0.03 : 0.018) { return abs(p.z) < 0.07 ? .Leather_Dark : .Wood_Dark }
    if abs(p.y - 0.135) < 0.006 && abs(p.x) < 0.006 { return .Bone }
    return .Empty
}

// A leather strap from the hand along z, the pouch at its end.
@(private="file")
shape_sling :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, 0}, {0, 0, 0.32}, 0.012) < 0 { return .Leather }
    if la.length(p - {0, 0, 0.36}) < 0.045 { return .Leather_Dark }
    return .Empty
}

shots_models_bake :: proc() {
    V :: 1.0 / 40
    ent_models[.Arrow]  = model_bake({-0.05, -0.05, -0.4}, {0.05, 0.05, 0.42}, V, shape_arrow)
    ent_models[.Pebble] = model_bake({-0.08, -0.08, -0.08}, {0.08, 0.08, 0.08}, V, shape_pebble)
    ent_models[.Bow]    = model_bake({-0.03, -0.05, -0.55}, {0.03, 0.17, 0.55}, V, shape_bow)
    ent_models[.Sling]  = model_bake({-0.06, -0.06, -0.03}, {0.06, 0.06, 0.42}, V, shape_sling)
}
