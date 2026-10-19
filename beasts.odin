package main

import "core:math"
import la "core:math/linalg"

// Four-legged monsters and wildlife (Body.Beast in ENEMY_SPECS): they live
// as enemies do (enemies.odin: spawning, senses, paths, hits, levels and
// poise), but are drawn on a beast's rig: a body, a head on its neck, four
// legs that trot (diagonal pairs together) or gallop (front and back
// pairs), and a tail. Each kind's own way of going about it is in
// enemy_think (wolves circle and dart in; see their spec).
//
// Shapes are in metres, facing +z, posed at the spec's scale.

Beast_Rig :: struct {
    body, head, leg, tail: Model_Id,
    body_y: f32,       // the body's pivot above the feet
    legs:   [4][3]f32, // hips from the body's pivot: front left, front right, back left, back right
    head_at, tail_at: [3]f32,
    gallop: bool,      // running, front and back pairs together (else a trot)
}

BEAST_RIGS := #partial [Enemy_Kind]Beast_Rig{
    .Wolf = {body = .Wolf_Body, head = .Wolf_Head, leg = .Wolf_Leg, tail = .Wolf_Tail, body_y = 0.6,
        legs = {{0.11, -0.04, 0.3}, {-0.11, -0.04, 0.3}, {0.11, -0.04, -0.3}, {-0.11, -0.04, -0.3}},
        head_at = {0, 0.12, 0.42}, tail_at = {0, 0.1, -0.42}, gallop = true},
}

// One beast, posed from its state; also the sandbox's.
beast_pose :: proc(f: ^Ent_Frame, e: ^Enemy) {
    sp := ENEMY_SPECS[e.kind]
    rig := BEAST_RIGS[e.kind]
    s := sp.scale
    feet := e.pos
    tint := la.lerp(e.tint, [3]f32{2.6, 2.6, 2.6}, e.flash * 0.7)
    if e.freeze > 0 { feet += [3]f32{rand_jitter(e.age * 91), 0, rand_jitter(e.age * 57)} * 0.03 }

    amp := clamp(e.speed / sp.run, 0, 1.2)
    ph := e.walk_phase
    bob := 0.035 * amp * abs(math.sin(ph))
    pitch, roll, crouch: f32
    head_pitch, head_yaw, tail_lift: f32
    switch e.state {
    case .Idle:
        head_yaw = 0.5 * math.sin(e.age * 0.7 + ph)
    case .Wander, .Chase:
    case .Windup:
        // Low, coiled: the tell before the spring.
        k := 1 - max(e.timer, 0) / max(sp.windup, 0.01)
        crouch, head_pitch, tail_lift = k, 0.25 * k, -0.3 * k
    case .Strike:
        pitch, head_pitch = -0.22, -0.3 // flying at you, jaws first
    case .Recover:
    case .Stagger:
        pitch, head_pitch = 0.15, -0.4
    case .Dead:
        roll = ease_out(min(e.death * 2.2, 1)) * math.PI * 0.5 // over on its side
        feet.y -= max(e.death - 2.5, 0) * 0.5 // and sinks away
        amp = 0
    }
    air: f32 = e.on_ground || e.state == .Dead ? 0 : 1
    body := basis_yaw(e.yaw) * basis_rot_z(roll) * basis_rot_x(pitch)
    center := feet + basis_yaw(e.yaw) * ([3]f32{0, rig.body_y - 0.12 * crouch + bob, 0} * s)
    ent_part(f, rig.body, center, body, {s, s, s}, tint)

    // Legs: a trot moves the diagonal pairs together, a gallop the front
    // pair and then the back; in the air they reach out front and back.
    gallop := rig.gallop && amp > 0.7
    for hip, i in rig.legs {
        front := i < 2
        right := i == 1 || i == 3
        phase: f32 = gallop ? (front ? 0 : math.PI * 0.8) + (right ? 0.35 : 0) : ((front == right) ? 0 : math.PI)
        swing := math.sin(ph + phase) * 0.65 * min(amp, 1)
        reach: f32 = front ? -0.7 : 0.6 // in the air: forelegs forward, hind legs back
        a := swing * (1 - air) + reach * air - 0.3 * crouch * (front ? -1 : 1)
        ent_part(f, rig.leg, center + body * (hip * s), body * basis_rot_x(a), {s, s, s}, tint)
    }
    ent_part(f, rig.head, center + body * (rig.head_at * s), body * basis_yaw(head_yaw) * basis_rot_x(head_pitch), {s, s, s}, tint)
    wag := 0.25 * math.sin(e.age * 6) * (e.state == .Idle ? 1 : 0.3)
    ent_part(f, rig.tail, center + body * (rig.tail_at * s), body * basis_yaw(wag) * basis_rot_x(tail_lift + 0.25 * amp), {s, s, s}, tint)
}

@(private="file")
ease_out :: proc(t: f32) -> f32 { return 1 - (1 - t) * (1 - t) }

// A cheap shake for something stuck on a blade (hit stop).
@(private="file")
rand_jitter :: proc(t: f32) -> f32 { return math.sin(t) * 0.7 + math.sin(t * 2.3) * 0.3 }

// ─── Wolf ───────────────────────────────────────────────────────────────────
// Grey (the tint) with a pale chest and belly, a dark saddle down the back.

@(private="file")
shape_wolf_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    trunk := vm_round_box(p, {0, 0, -0.04}, {0.15, 0.15, 0.38}, 0.09)
    chest := la.length((p - {0, -0.02, 0.24}) / [3]f32{1, 1.1, 1}) - 0.2
    if min(trunk, chest) > 0 { return .Empty }
    if p.y < -0.13 || (p.z > 0.36 && p.y < -0.02) { return .Fur_Light } // belly, throat
    if p.y > 0.15 && p.z > -0.3 && p.z < 0.22 { return .Hide_Dark }     // the saddle
    return .Fur
}

@(private="file")
shape_wolf_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Ears: short and pointed, upright.
    if q.y > 0.13 && q.y < 0.26 {
        k := (q.y - 0.13) / 0.13
        if abs(q.x - 0.07) < 0.04 * (1 - k) + 0.008 && abs(p.z - 0.02) < 0.025 { return k > 0.7 ? .Fur_Dark : .Fur }
    }
    // Muzzle: long, tapering, a black nose.
    if p.z > 0.1 && p.z < 0.34 {
        k := (p.z - 0.1) / 0.24
        hw := 0.07 - 0.025 * k
        if q.x < hw && p.y > -0.06 && p.y < 0.07 - 0.03 * k {
            if p.z > 0.31 && p.y > 0.0 { return .Nose }
            return p.y < -0.03 ? .Fur_Light : .Fur
        }
    }
    if vm_round_box(p, {0, 0.05, 0.03}, {0.11, 0.1, 0.11}, 0.05) < 0 {
        if p.z > 0.1 && abs(q.x - 0.06) < 0.02 && abs(p.y - 0.09) < 0.02 { return .Eye_Yellow }
        if p.y < -0.02 && q.x > 0.07 { return .Fur_Light } // cheeks
        return .Fur
    }
    return .Empty
}

@(private="file")
shape_wolf_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, 0}, {0, -0.47, 0.02}, 0.045) < 0 { return p.y < -0.4 ? .Fur_Dark : .Fur }
    if vm_round_box(p, {0, -0.52, 0.04}, {0.045, 0.03, 0.06}, 0.02) < 0 { return .Fur_Dark } // paw
    return .Empty
}

@(private="file")
shape_wolf_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    // Bushy, hanging down and back; the tip pale.
    t := clamp(-p.z / 0.4, 0, 1)
    c := [3]f32{0, -0.2 * t * t - 0.05 * t, -0.4 * t}
    r := 0.04 + 0.04 * math.sin(t * math.PI)
    if la.length(p - c) < r && p.z <= 0.02 { return t > 0.85 ? .Fur_Light : .Fur }
    return .Empty
}

beasts_models_bake :: proc() {
    V :: 1.0 / 32
    ent_models[.Wolf_Body] = model_bake({-0.24, -0.26, -0.5}, {0.24, 0.26, 0.5}, V, shape_wolf_body)
    ent_models[.Wolf_Head] = model_bake({-0.16, -0.1, -0.1}, {0.16, 0.28, 0.36}, V, shape_wolf_head)
    ent_models[.Wolf_Leg]  = model_bake({-0.07, -0.57, -0.06}, {0.07, 0.05, 0.12}, V, shape_wolf_leg)
    ent_models[.Wolf_Tail] = model_bake({-0.1, -0.35, -0.48}, {0.1, 0.1, 0.04}, V, shape_wolf_tail)
}
