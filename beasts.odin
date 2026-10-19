package main

import "core:math"
import la "core:math/linalg"

// Four-legged monsters and wildlife (Body.Beast in ENEMY_SPECS): they live
// as enemies do (enemies.odin: spawning, senses, paths, hits, levels and
// poise), but are drawn on a beast's rig: a body, a head on its neck, four
// legs that trot (diagonal pairs together) or gallop (front and back
// pairs), and a tail. Each kind's own way of going about it is in
// enemy_think (wolves circle and dart in, boars charge, deer bolt: see their
// specs).
//
// Shapes are in metres, facing +z, posed at the spec's scale, baked at
// the humanoid monsters' voxel (1/20 m: enemies.odin) so they look of a
// piece with them; thin parts are kept at least a voxel across (thin).

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
    .Boar = {body = .Boar_Body, head = .Boar_Head, leg = .Boar_Leg, tail = .Boar_Tail, body_y = 0.48,
        legs = {{0.14, -0.1, 0.27}, {-0.14, -0.1, 0.27}, {0.14, -0.1, -0.28}, {-0.14, -0.1, -0.28}},
        head_at = {0, 0.04, 0.42}, tail_at = {0, 0.12, -0.46}, gallop = true},
    .Deer = {body = .Deer_Body, head = .Deer_Head, leg = .Deer_Leg, tail = .Deer_Tail, body_y = 0.95,
        legs = {{0.1, -0.06, 0.3}, {-0.1, -0.06, 0.3}, {0.1, -0.06, -0.32}, {-0.1, -0.06, -0.32}},
        head_at = {0, 0.1, 0.4}, tail_at = {0, 0.12, -0.45}, gallop = true},
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
        // Grazing (deer) and rooting (boars): the head goes down now and then.
        if e.kind != .Wolf {
            graze := math.smoothstep(f32(0.2), f32(0.6), math.sin(e.age * 0.45 + ph * 0.1))
            head_pitch, head_yaw = (e.kind == .Deer ? 1.1 : 0.5) * graze, head_yaw * (1 - graze)
        }
    case .Wander, .Chase:
    case .Windup:
        // Low, coiled: the tell before the spring (a boar's head down,
        // pawing the ground).
        k := 1 - max(e.timer, 0) / max(sp.windup, 0.01)
        crouch, head_pitch, tail_lift = k, 0.25 * k, -0.3 * k
        if !sp.leaps { crouch, head_pitch, ph = 0.3 * k, 0.45 * k, e.age * 14 }
    case .Strike:
        pitch, head_pitch = -0.22, -0.3 // flying at you, jaws first
        if !sp.leaps { pitch, head_pitch, amp = 0.05, 0.4, 1.2 } // head down, tusks first
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

// A radius (or half width) no thinner than about a voxel, so a part
// doesn't fall between the voxel centres when baked: they needn't lie on
// its axis, and can be off it both ways (half a voxel's diagonal).
thin :: proc(r, voxel: f32) -> f32 { return max(r, voxel * 0.75) }

// Now and then a voxel (`share` of them, by where it is): flecks of a
// darker coat, grizzled fur.
fleck :: proc(p: [3]f32, voxel: f32, share: f32) -> bool {
    q := [3]f32{math.round(p.x / voxel), math.round(p.y / voxel), math.round(p.z / voxel)}
    h := math.sin(q.x * 12.9898 + q.y * 78.233 + q.z * 37.719) * 43758.5453
    return h - math.floor(h) < share
}

// A cheap shake for something stuck on a blade (hit stop).
@(private="file")
rand_jitter :: proc(t: f32) -> f32 { return math.sin(t) * 0.7 + math.sin(t * 2.3) * 0.3 }

// ─── Spider ─────────────────────────────────────────────────────────────────
// A body and eight legs about it, four a side, each walking a step behind
// the next; low and coiled before a leap; over on its back, legs curled,
// when dead.

@(private="file")
SPIDER_LEGS :: [4]f32{0.95, 0.35, -0.2, -0.8} // the right side's, yaw from straight out (front first)

spider_pose :: proc(f: ^Ent_Frame, e: ^Enemy) {
    sp := ENEMY_SPECS[e.kind]
    s := sp.scale
    feet := e.pos
    tint := la.lerp(e.tint, [3]f32{2.6, 2.6, 2.6}, e.flash * 0.7)
    if e.freeze > 0 { feet += [3]f32{rand_jitter(e.age * 91), 0, rand_jitter(e.age * 57)} * 0.03 }
    amp := clamp(e.speed / sp.run, 0, 1.2)
    ph := e.walk_phase * 1.6
    crouch, roll, curl, raise: f32
    #partial switch e.state {
    case .Windup:
        k := 1 - max(e.timer, 0) / max(sp.windup, 0.01)
        crouch, raise = k, k // the front legs up: the tell
    case .Strike:
        raise = 1
    case .Dead:
        k := ease_out(min(e.death * 2.5, 1))
        roll, curl, amp = k * math.PI * 0.95, k, 0
        feet.y -= max(e.death - 2.5, 0) * 0.4
    }
    yaw := basis_yaw(e.yaw)
    body := yaw * basis_rot_z(roll)
    center := feet + yaw * ([3]f32{0, 0.36 - 0.14 * crouch + (roll > 0 ? 0.1 : 0), 0} * s)
    ent_part(f, .Spider_Body, center, body, {s, s, s}, tint)
    for side in ([2]f32{1, -1}) {
        for a, i in SPIDER_LEGS {
            step := math.sin(ph + f32(i) * math.PI * 0.5 + (side > 0 ? 0 : math.PI))
            swing := step * 0.22 * min(amp, 1)
            lift := max(step, 0) * 0.35 * min(amp, 1) + (i == 0 ? 0.9 * raise : 0) + 1.2 * curl
            // Out to its side (+x the right), turned to its place, lifted.
            hip := [3]f32{side * 0.1, 0.02, 0.1 - 0.07 * f32(i)} * s
            rot := body * basis_yaw(side * (a + swing)) * basis_rot_z(side * lift)
            ent_part(f, .Spider_Leg, center + body * hip, rot, {side * s, s, s}, tint)
        }
    }
}

@(private="file")
shape_spider_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Eyes: a cluster on the front, glowing.
    if (la.length(q - {0.05, 0.08, 0.27}) < thin(0.03, voxel)) || (la.length(q - {0.1, 0.04, 0.24}) < thin(0.022, voxel)) { return .Eye_Glow }
    // Fangs.
    if vm_capsule(q, {0.04, -0.02, 0.28}, {0.035, -0.09, 0.31}, thin(0.018, voxel)) < 0 { return .Bone_Shadow }
    head := la.length((p - {0, 0.02, 0.15}) / [3]f32{1, 0.75, 1}) - 0.15
    abdomen := la.length((p - {0, 0.08, -0.2}) / [3]f32{1, 0.8, 1.15}) - 0.24
    if min(head, abdomen) > 0 { return .Empty }
    // A mark down the abdomen's back, faintly aglow.
    if abdomen < 0 && p.y > 0.2 && q.x < thin(0.035, voxel) && p.z < -0.12 && p.z > -0.32 { return .Eye_Red }
    return abdomen < 0 && p.y < -0.02 ? .Hide_Dark : .Hide
}

// Out along +x from the hip: up to the knee, then down to the foot.
@(private="file")
shape_spider_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, 0}, {0.3, 0.2, 0}, thin(0.028, voxel)) < 0 { return .Hide }
    if vm_capsule(p, {0.3, 0.2, 0}, {0.5, -0.34, 0}, thin(0.022, voxel)) < 0 { return p.y < -0.25 ? .Hide_Dark : .Hide }
    return .Empty
}

// ─── Wolf ───────────────────────────────────────────────────────────────────
// Grey (the tint) with a pale chest and belly, a dark saddle down the back.

@(private="file")
shape_wolf_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    trunk := vm_round_box(p, {0, 0, -0.06}, {0.15, 0.15, 0.36}, 0.09)
    ruff := la.length((p - {0, 0.04, 0.26}) / [3]f32{1.05, 1.05, 0.9}) - 0.22 // the thick fur over the shoulders
    haunch := la.length((p - {0, 0.02, -0.3}) / [3]f32{1, 1, 1.1}) - 0.16
    if min(trunk, ruff, haunch) > 0 { return .Empty }
    if p.y < -0.13 { return .Fur_Light }                     // belly
    if p.z > 0.3 && p.y < 0.02 { return .Fur_Light }         // the throat and chest
    if p.y > 0.12 && p.z > -0.36 && p.z < 0.3 {              // the saddle: dark, grizzled
        return fleck(p, voxel, 0.22) ? .Fur_Dark : (fleck(p + 7, voxel, 0.3) ? .Fur : .Hide_Dark)
    }
    if fleck(p, voxel, 0.12) { return .Hide_Dark }           // flecks down the flanks
    return .Fur
}

@(private="file")
shape_wolf_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Ears: upright, pointed, dark backs and pale insides.
    if q.y > 0.13 && q.y < 0.28 {
        k := (q.y - 0.13) / 0.15
        if abs(q.x - 0.075) < thin(0.045 * (1 - k) + 0.006, voxel) && abs(p.z - 0.01) < thin(0.03, voxel) {
            if k > 0.8 { return .Hide_Dark }
            return p.z > 0.02 && k < 0.6 ? .Fur_Light : .Fur
        }
    }
    // Muzzle: long and tapering, pale below, a black nose.
    if p.z > 0.1 && p.z < 0.35 {
        k := (p.z - 0.1) / 0.25
        hw := 0.075 - 0.028 * k
        top := 0.07 - 0.035 * k
        if q.x < hw && p.y > -0.07 && p.y < top {
            if p.z > 0.32 && p.y > 0.0 && q.x < 0.035 { return .Nose }
            return p.y < -0.02 ? .Fur_Light : .Fur
        }
    }
    if vm_round_box(p, {0, 0.05, 0.03}, {0.12, 0.1, 0.11}, 0.05) < 0 {
        if p.z > 0.1 && abs(q.x - 0.065) < voxel * 0.55 && abs(p.y - 0.09) < voxel * 0.55 { return .Eye_Yellow } // a voxel each
        if p.z > 0.08 && p.y > 0.11 && p.y < 0.14 { return .Hide_Dark } // the brow
        if p.y < 0.02 && q.x > 0.07 { return .Fur_Light }              // the cheek ruff
        return .Fur
    }
    return .Empty
}

@(private="file")
shape_wolf_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    // Thick at the top, slender below; a dark paw.
    t := clamp(-p.y / 0.5, 0, 1)
    if vm_capsule(p, {0, 0, 0}, {0, -0.47, 0.02}, thin(0.065 - 0.03 * t, voxel)) < 0 { return p.y < -0.42 ? .Hide_Dark : (p.z > 0.03 && t > 0.4 ? .Fur_Light : .Fur) }
    if vm_round_box(p, {0, -0.52, 0.04}, {0.05, 0.03, 0.065}, 0.02) < 0 { return .Hide_Dark }
    return .Empty
}

@(private="file")
shape_wolf_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    // Bushy, hanging down and back, dark along the top and at the tip.
    t := clamp(-p.z / 0.42, 0, 1)
    c := [3]f32{0, -0.2 * t * t - 0.05 * t, -0.42 * t}
    r := 0.05 + 0.045 * math.sin(t * math.PI)
    if la.length(p - c) < thin(r, voxel) && p.z <= 0.02 {
        if t > 0.85 { return .Hide_Dark }
        return p.y > c.y + r * 0.4 && fleck(p, voxel, 0.6) ? .Hide_Dark : .Fur
    }
    return .Empty
}

// ─── Boar ───────────────────────────────────────────────────────────────────
// Dark bristly hide (the tint), a hump at the shoulders with a crest of
// bristles, a long snout, tusks.

@(private="file")
shape_boar_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    trunk := vm_round_box(p, {0, 0, -0.04}, {0.2, 0.2, 0.4}, 0.12)
    hump := la.length((p - {0, 0.08, 0.2}) / [3]f32{1, 0.95, 1.1}) - 0.25
    if min(trunk, hump) > 0 { return .Empty }
    if p.y > 0.24 && abs(p.x) < 0.05 { return .Hide_Dark } // the crest
    if p.y < -0.17 { return .Hide_Dark }
    return .Hide
}

@(private="file")
shape_boar_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Tusks: curving up and out from the snout's sides.
    if la.length(q - {0.08, -0.02, 0.28}) < thin(0.022, voxel) || la.length(q - {0.1, 0.03, 0.27}) < thin(0.018, voxel) { return .Tusk }
    // Ears: small, up and back.
    if q.y > 0.1 && q.y < 0.2 && abs(q.x - 0.1) < thin(0.04 * (1 - (q.y - 0.1) / 0.1) + 0.01, voxel) && abs(p.z + 0.02) < thin(0.025, voxel) { return .Hide_Dark }
    // Snout: a long box with a flat, dark disc at the end.
    if p.z > 0.12 && p.z < 0.36 && q.x < 0.075 && p.y > -0.1 && p.y < 0.04 + 0.04 * (0.36 - p.z) / 0.24 {
        return p.z > 0.345 && q.x < 0.045 && p.y > -0.07 && p.y < 0.01 ? .Nose : .Hide
    }
    if vm_round_box(p, {0, 0, 0.06}, {0.13, 0.13, 0.12}, 0.05) < 0 {
        if p.z > 0.12 && abs(q.x - 0.09) < thin(0.018, voxel) && abs(p.y - 0.06) < thin(0.018, voxel) { return .Eye }
        return .Hide
    }
    return .Empty
}

@(private="file")
shape_boar_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, 0}, {0, -0.3, 0.01}, 0.055) < 0 { return .Hide }
    if vm_round_box(p, {0, -0.35, 0.02}, {0.045, 0.035, 0.05}, 0.015) < 0 { return .Fur_Dark } // hoof
    return .Empty
}

@(private="file")
shape_boar_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, 0}, {0, -0.12, -0.05}, thin(0.018, voxel)) < 0 { return .Hide }
    if la.length(p - {0, -0.14, -0.06}) < 0.035 { return .Hide_Dark } // the tuft
    return .Empty
}

// ─── Deer ───────────────────────────────────────────────────────────────────
// Tawny (the tint), pale belly and rump, a long neck, antlers.

@(private="file")
shape_deer_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    trunk := vm_round_box(p, {0, 0, -0.02}, {0.14, 0.15, 0.4}, 0.1)
    chest := la.length(p - {0, 0.02, 0.24}) - 0.19
    if min(trunk, chest) > 0 { return .Empty }
    if p.y < -0.13 { return .Fur_Light }
    if p.z < -0.38 && p.y > -0.06 { return .Fur_Light } // the rump patch
    return .Fur
}

@(private="file")
shape_deer_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Antlers: a beam each side, up and back, with tines.
    beam := vm_capsule(q, {0.04, 0.5, 0.16}, {0.13, 0.82, 0.06}, thin(0.017, voxel))
    tine1 := vm_capsule(q, {0.07, 0.62, 0.12}, {0.09, 0.74, 0.22}, thin(0.013, voxel))
    tine2 := vm_capsule(q, {0.11, 0.74, 0.08}, {0.2, 0.86, 0.12}, thin(0.013, voxel))
    if min(beam, tine1, tine2) < 0 { return .Antler }
    // Ears: out to the sides.
    if vm_round_box(q, {0.12, 0.5, 0.12}, {0.05, thin(0.022, voxel), thin(0.015, voxel)}, 0.01) < 0 { return .Fur }
    // Neck, rising from the shoulders.
    if vm_capsule(p, {0, 0, 0}, {0, 0.38, 0.12}, 0.07) < 0 { return p.z > 0.09 && p.y > 0.16 && p.y < 0.32 ? .Fur_Light : .Fur } // a pale throat
    // Muzzle, tapering to a dark nose.
    if p.z > 0.24 && p.z < 0.36 && q.x < 0.05 - 0.015 * (p.z - 0.24) / 0.12 && p.y > 0.37 && p.y < 0.46 {
        return p.z > 0.345 && p.y > 0.41 && q.x < 0.03 ? .Nose : .Fur
    }
    if vm_round_box(p, {0, 0.44, 0.18}, {0.06, 0.06, 0.08}, 0.03) < 0 {
        if p.z > 0.2 && abs(q.x - 0.06) < thin(0.016, voxel) && abs(p.y - 0.46) < thin(0.016, voxel) { return .Eye }
        return .Fur
    }
    return .Empty
}

@(private="file")
shape_deer_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, 0}, {0, -0.78, 0.01}, thin(0.032, voxel)) < 0 { return p.y < -0.74 ? .Fur_Dark : .Fur }
    if vm_round_box(p, {0, -0.84, 0.02}, {0.03, 0.03, 0.04}, 0.01) < 0 { return .Fur_Dark } // hoof
    return .Empty
}

@(private="file")
shape_deer_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.04, -0.02}, {0.035, 0.06, 0.02}, 0.015) < 0 { return .Fur_Light }
    return .Empty
}

beasts_models_bake :: proc() {
    V :: 1.0 / 20 // the humanoid monsters' (enemies.odin enemy_models_bake)
    ent_models[.Spider_Body] = model_bake({-0.3, -0.16, -0.5}, {0.3, 0.3, 0.36}, V, shape_spider_body)
    ent_models[.Spider_Leg]  = model_bake({-0.04, -0.4, -0.04}, {0.55, 0.25, 0.04}, V, shape_spider_leg)
    ent_models[.Wolf_Body] = model_bake({-0.24, -0.26, -0.5}, {0.24, 0.26, 0.5}, V, shape_wolf_body)
    ent_models[.Wolf_Head] = model_bake({-0.16, -0.1, -0.1}, {0.16, 0.28, 0.36}, V, shape_wolf_head)
    ent_models[.Wolf_Leg]  = model_bake({-0.07, -0.57, -0.06}, {0.07, 0.05, 0.12}, V, shape_wolf_leg)
    ent_models[.Wolf_Tail] = model_bake({-0.1, -0.35, -0.48}, {0.1, 0.1, 0.04}, V, shape_wolf_tail)
    ent_models[.Boar_Body] = model_bake({-0.34, -0.34, -0.58}, {0.34, 0.36, 0.5}, V, shape_boar_body)
    ent_models[.Boar_Head] = model_bake({-0.2, -0.14, -0.1}, {0.2, 0.22, 0.38}, V, shape_boar_head)
    ent_models[.Boar_Leg]  = model_bake({-0.07, -0.4, -0.06}, {0.07, 0.06, 0.09}, V, shape_boar_leg)
    ent_models[.Boar_Tail] = model_bake({-0.05, -0.2, -0.12}, {0.05, 0.03, 0.03}, V, shape_boar_tail)
    ent_models[.Deer_Body] = model_bake({-0.24, -0.26, -0.52}, {0.24, 0.24, 0.46}, V, shape_deer_body)
    ent_models[.Deer_Head] = model_bake({-0.24, -0.08, -0.08}, {0.24, 0.9, 0.38}, V, shape_deer_head)
    ent_models[.Deer_Leg]  = model_bake({-0.05, -0.88, -0.05}, {0.05, 0.04, 0.07}, V, shape_deer_leg)
    ent_models[.Deer_Tail] = model_bake({-0.05, -0.12, -0.05}, {0.05, 0.03, 0.02}, V, shape_deer_tail)
}
