package main

import "core:math"
import "core:math/rand"
import la "core:math/linalg"

// Creatures built from rigid voxel parts (voxel_models.odin): foxes that
// wander and flee, eagles that circle in thermals (so a glider pilot can
// spot rising air), and the player's own body for the third-person view.
// Each creature's shapes are baked once; the *_add procs pose the parts for
// this frame from the creature's state.

// ─── Shapes ─────────────────────────────────────────────────────────────────

// Fox body, pivot at the body centre; chest and belly pale.
@(private="file")
shape_fox_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, 0, 0}, {0.16, 0.14, 0.30}, 0.07) > 0 { return .Empty }
    if p.y < -0.04 && p.z > -0.05 { return .Fur_Light }
    if p.z > 0.2 && p.y < 0.06 { return .Fur_Light }
    return .Fur
}

// Fox head, pivot at the neck: round skull with pale cheeks, a muzzle that
// tapers to a small black nose, dark eyes with a glint, and big pointed ears
// with dark tips and pale insides.
@(private="file")
shape_fox_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Ears: triangles rising from the top of the skull, tilted outward.
    if q.y > 0.18 && q.y < 0.43 {
        k := (q.y - 0.18) / 0.25            // 0 at the base .. 1 at the tip
        cx := 0.095 + 0.03 * k               // leans outward
        half := 0.075 * (1 - k) + 0.008
        if abs(q.x - cx) < half && abs(p.z - 0.04) < 0.03 {
            if k > 0.68 { return .Fur_Dark }
            if p.z > 0.05 && abs(q.x - cx) < half * 0.55 && k < 0.6 { return .Fur_Light } // inner ear
            return .Fur
        }
    }
    // Muzzle: narrows and drops toward the nose.
    if p.z > 0.13 && p.z < 0.33 {
        k := (p.z - 0.13) / 0.2
        hw := 0.085 - 0.04 * k
        top := 0.115 - 0.045 * k
        if q.x < hw && p.y > 0.0 && p.y < top {
            if p.z > 0.29 && p.y > top - 0.05 { return .Nose }
            return p.y < 0.05 ? .Fur_Light : .Fur
        }
    }
    // Skull.
    if vm_round_box(p, {0, 0.11, 0.05}, {0.15, 0.13, 0.13}, 0.06) < 0 {
        // Eyes on the front face, a little tall, with a glint.
        if p.z > 0.13 && abs(q.x - 0.075) < 0.024 && abs(p.y - 0.135) < 0.036 {
            return q.x < 0.07 && p.y > 0.15 ? .Eye_White : .Eye
        }
        if p.y < 0.07 && q.x > 0.055 { return .Fur_Light } // cheeks
        return .Fur
    }
    return .Empty
}

// Fox leg, pivot at the hip, dark paw.
@(private="file")
shape_fox_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.15, 0}, {0.045, 0.16, 0.05}, 0.02) > 0 { return .Empty }
    return p.y < -0.22 ? .Fur_Dark : .Fur
}

// Bushy tail along -z from its base, white tip.
@(private="file")
shape_fox_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    a, b := [3]f32{0, 0, 0}, [3]f32{0, -0.06, -0.42}
    ba := b - a
    t := clamp(la.dot(p - a, ba) / la.dot(ba, ba), 0, 1)
    r := 0.05 + 0.07 * math.sin(t * math.PI * 0.85)
    if la.length(p - (a + ba * t)) > r { return .Empty }
    return t > 0.78 ? .Fur_Light : .Fur
}

// Eagle body along +z: brown body, white head, yellow beak, white tail fan.
@(private="file")
shape_bird_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    if la.length(q - [3]f32{0.045, 0.08, 0.32}) < 0.022 { return .Eye }
    // Hooked beak.
    if p.z > 0.33 && p.z < 0.45 && abs(p.x) < 0.03 {
        k := (p.z - 0.33) / 0.12
        if p.y < 0.06 - k * 0.04 && p.y > -0.0 - k * 0.04 { return .Beak }
    }
    if la.length(p - [3]f32{0, 0.05, 0.28}) < 0.085 { return .Feather_White }
    if vm_capsule(p, {0, 0, -0.2}, {0, 0.02, 0.2}, 0.1) < 0 { return .Feather }
    // Tail fan, widening toward the end.
    if p.z < -0.22 && p.z > -0.48 && abs(p.y + 0.01) < 0.02 {
        if abs(p.x) < 0.05 + (-0.22 - p.z) * 0.45 { return .Feather_White }
    }
    return .Empty
}

// Left eagle wing along +x from the shoulder: broad, slightly swept, dark
// fingered tips. The right wing is this one mirrored.
@(private="file")
shape_bird_wing :: proc(p: [3]f32, voxel: f32) -> Pal {
    x := p.x
    if x < 0 || x > 1.0 { return .Empty }
    lead := 0.09 - 0.07 * x
    trail := -0.2 + 0.06 * x
    // Rounded tip, split into "fingers".
    if x > 0.8 {
        k := (x - 0.8) / 0.2
        lead  -= k * k * 0.12
        trail += k * k * 0.08
        if math.mod(p.z * 40 + 100, 2) < 0.7 { return .Empty }
    }
    if p.z > lead || p.z < trail { return .Empty }
    if abs(p.y - 0.03 * x) > max(0.025 * (1 - x * 0.6), voxel * 0.55) { return .Empty }
    if x > 0.72 { return .Feather_Dark }
    return p.z < trail + 0.06 ? .Feather_Dark : .Feather
}

// The player, built as the skeleton is (enemies.odin): a person's
// proportions, rounded parts at the joints, fine voxels. Dressed for magic:
// a hooded robe in the part's tint (Shirt; Shirt_Trim and Robe_Dark its
// shades) to mid-thigh, trimmed in gold; a belt with a glowing stone and a
// pouch; sleeves to gold cuffs and the leather gloves of the first-person
// hands (magic.odin); trousers and boots; a short cape. The eyes sit at
// the camera's height (HUM_HIPS_Y + HUM_NECK.y + HUM_EYE = PLAYER_EYE_HEIGHT),
// so looking at another player is looking them in the eye.
@(private="file")
shape_hum_torso :: proc(p: [3]f32, voxel: f32) -> Pal {
    t := clamp(-p.y / 0.26, 0, 1) // down the skirt
    chest := la.length((p - {0, 0.36, 0}) / [3]f32{0.2, 0.24, 0.12}) - 1
    waist := vm_round_box(p, {0, 0.1, 0}, {0.16, 0.14, 0.1}, 0.06)
    skirt := vm_round_box(p, {0, -0.1, 0}, {0.17 + 0.05 * t, 0.15, 0.11 + 0.03 * t}, 0.04)
    collar := vm_capsule(p, {-0.2, 0.55, -0.02}, {0.2, 0.55, -0.02}, 0.065) // the hood laid back over the shoulders
    body := min(vm_smin(chest * 0.12, waist, 0.06), skirt)
    if collar < 0 && p.y > 0.5 { return p.z > 0.02 && abs(p.x) < 0.08 ? .Robe_Dark : .Shirt_Trim }
    if body > 0 {
        if vm_round_box(p, {-0.19, -0.03, 0.03}, {0.035, 0.055, 0.05}, 0.02) < 0 { return .Leather } // a pouch
        return .Empty
    }
    if p.y > 0.02 && p.y < 0.08 {
        if p.z > 0.06 && abs(p.x) < 0.025 { return .Pommel_Gem } // the belt's stone
        return .Leather_Dark
    }
    if p.y < -0.22 { return .Guard } // the hem's gold
    if p.z > 0.05 && abs(p.x) < 0.022 { return .Robe_Dark } // the robe's opening
    if p.y < -0.18 { return .Shirt_Trim }
    return .Shirt
}

// The head from the neck up; eyes HUM_EYE above it, looking along +z
// (finer voxels than the rest). A face: a jaw narrowing to the chin, a nose
// with a bridge, eyes with whites either side of the iris under shaded
// lids, thin brows, a mouth, the shade under the lip and chin; a fringe and
// sideburns. Over it a roomy cowl: an arched opening rimmed in gold, a
// brim shading the brow, dark lining within, soft folds down the sides,
// draping onto the shoulders, its point hanging behind.
@(private="file")
shape_hum_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    skull := la.length((p - {0, 0.255, 0}) / [3]f32{1, 1.08, 1.05}) - 0.148
    chin := clamp((0.16 - p.y) / 0.1, 0, 1)
    jaw := vm_round_box(p, {0, 0.14, 0.045}, {0.088 - 0.03 * chin, 0.06, 0.085}, 0.04)
    neck := vm_capsule(p, {0, -0.02, -0.015}, {0, 0.1, -0.015}, 0.052)
    face := min(vm_smin(skull, jaw, 0.04), neck)
    bridge := vm_capsule(p, {0, HUM_EYE - 0.01, 0.146}, {0, 0.196, 0.168}, 0.013)
    tip := vm_round_box(p, {0, 0.193, 0.163}, {0.021, 0.014, 0.015}, 0.01)
    nose := min(bridge, tip)
    head := min(face, nose)

    // The cowl round it.
    c := p - {0, 0.27, -0.02}
    hood := la.length(c / [3]f32{0.2, 0.215, 0.228}) - 1
    inner := la.length(c / [3]f32{0.168, 0.182, 0.196}) - 1
    oval := (p.x / 0.128) * (p.x / 0.128) + ((p.y - 0.2) / 0.163) * ((p.y - 0.2) / 0.163) // the opening, arched round the face
    open := p.z > 0 && oval < 1
    drape := vm_round_box(p, {0, 0.05, -0.05}, {0.17, 0.08, 0.13}, 0.06)
    tail := vm_capsule(p, {0, 0.44, -0.1}, {0, 0.2, -0.36}, 0.04 - 0.015 * clamp((0.44 - p.y) / 0.24, 0, 1))
    if ((hood < 0 && inner > 0 && p.y > 0.03) || (drape < 0 && head > 0)) && !open || tail < 0 {
        if p.z > 0.12 && oval < 1.22 { return .Guard_Dark } // the rim: a band of old gold
        if p.z > -0.02 && oval < 1.7 { return .Robe_Dark } // the lining, seen within
        a := math.atan2(p.x, -p.z)
        if p.y < 0.32 && p.y > 0.06 && q.x > 0.1 && abs(math.sin(a * 6)) > 0.97 { return .Robe_Dark } // folds down the sides
        return .Shirt_Trim
    }
    if head > 0 { return .Empty }
    if nose < 0 && face > 0 {
        return p.y < 0.184 && q.x < 0.014 ? .Skin_Shade : .Skin // nostrils under it
    }
    e := HUM_EYE
    if p.z > 0.09 {
        if abs(p.y - e) < 0.013 && q.x > 0.03 && q.x < 0.1 {
            return abs(q.x - 0.064) < 0.013 ? .Eye : .Eye_White // iris toward the middle
        }
        if p.y >= e + 0.013 && p.y < e + 0.03 && q.x > 0.028 && q.x < 0.104 { return .Skin_Shade } // lids, under the brow
        if p.y >= e + 0.03 && p.y < e + 0.044 && q.x > 0.03 && q.x < 0.1 - 0.15 * max(q.x - 0.07, 0) { return .Leather_Dark } // brows
        if abs(p.y - 0.136) < 0.009 && q.x < 0.036 { return .Rust } // the mouth
        if p.y < 0.127 && p.y > 0.112 && q.x < 0.026 { return .Skin_Shade } // under the lip
    }
    if p.y < 0.095 || (q.x > 0.085 && p.y < 0.15 && p.z > 0) { return .Skin_Shade } // the jaw's line, the neck in its shade
    if p.y > 0.315 || (q.x > 0.12 && p.y > 0.19 && p.z < 0.1) { return .Hair } // a fringe, sideburns
    return .Skin
}

// The arm in three, as a person's bends: the upper arm from the shoulder
// to the elbow, the forearm (its sleeve widening to a gold cuff) to the
// wrist, the gloved hand below it. Each along -y from its joint.
@(private="file")
shape_hum_arm :: proc(p: [3]f32, voxel: f32) -> Pal {
    upper := vm_capsule(p, {0, -0.01, 0}, {0, -HUM_UPPER_LEN + 0.02, 0}, 0.058)
    elbow := la.length(p - {0, -HUM_UPPER_LEN, 0}) - 0.06
    return min(upper, elbow) < 0 ? .Shirt : .Empty
}

@(private="file")
shape_hum_fore :: proc(p: [3]f32, voxel: f32) -> Pal {
    t := clamp(-p.y / HUM_FORE_LEN, 0, 1)
    if p.y < -HUM_FORE_LEN + 0.04 { // the cuff: a band, ending at the wrist (an open glove goes on from there)
        return p.y > -HUM_FORE_LEN && la.length(p.xz - {0, 0.005}) < 0.062 ? .Guard : .Empty
    }
    return vm_capsule(p, {0, 0, 0}, {0, -HUM_FORE_LEN + 0.04, 0.005}, 0.052 + 0.014 * t) < 0 ? .Shirt : .Empty
}

@(private="file")
shape_hum_hand :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.065, 0.008}, {0.047, 0.06, 0.042}, 0.02) < 0 { return p.y < -0.095 ? .Glove_Dark : .Glove }
    if vm_capsule(p, {0.042, -0.03, 0.03}, {0.05, -0.08, 0.045}, 0.017) < 0 { return .Glove } // the thumb
    return .Empty
}

// Hip down along -y: the trousers, a knee, the boot with its top turned down.
@(private="file")
shape_hum_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    boot := vm_round_box(p, {0, -0.77, 0.035}, {0.06, 0.07, 0.105}, 0.03)
    shin := vm_capsule(p, {0, -0.44, 0.01}, {0, -0.74, 0.01}, 0.058)
    if boot < 0 || (shin < 0 && p.y < -0.6) {
        if p.y < -0.82 { return .Leather_Dark } // the sole
        return .Boot
    }
    if p.y < -0.56 && p.y > -0.62 && vm_capsule(p, {0, -0.56, 0.01}, {0, -0.62, 0.01}, 0.072) < 0 { return .Leather } // the turned top
    thigh := vm_capsule(p, {0, -0.02, 0}, {0, -0.4, 0.01}, 0.07)
    knee := la.length(p - {0, -0.42, 0.015}) - 0.068
    return min(thigh, knee, shin) < 0 ? .Trousers : .Empty
}

// A short cape from the shoulders (its pivot, behind the neck), hanging
// along -y, the outside toward -z; gold at the ragged hem.
@(private="file")
shape_hum_cape :: proc(p: [3]f32, voxel: f32) -> Pal {
    if p.y > 0 || p.z > 0 || p.z < -0.06 { return .Empty }
    half := 0.16 + 0.07 * clamp(-p.y / 0.7, 0, 1) // wider toward the hem
    if abs(p.x) > half { return .Empty }
    hem := -0.7 - 0.03 * math.sin(p.x * 37)
    if p.y < hem { return .Empty }
    if p.y < hem + 0.04 { return .Guard }
    if p.y < hem + 0.09 { return .Shirt_Trim }
    return .Robe_Dark
}

creature_models_bake :: proc() {
    ent_models[.Fox_Body]  = model_bake({-0.2, -0.18, -0.34}, {0.2, 0.18, 0.34}, 1.0 / 16, shape_fox_body)
    ent_models[.Fox_Head]  = model_bake({-0.19, -0.04, -0.1}, {0.19, 0.45, 0.35}, 1.0 / 20, shape_fox_head)
    ent_models[.Fox_Leg]   = model_bake({-0.07, -0.33, -0.07}, {0.07, 0.02, 0.07}, 1.0 / 16, shape_fox_leg)
    ent_models[.Fox_Tail]  = model_bake({-0.14, -0.2, -0.5}, {0.14, 0.14, 0.04}, 1.0 / 16, shape_fox_tail)
    ent_models[.Bird_Body] = model_bake({-0.14, -0.13, -0.5}, {0.14, 0.15, 0.46}, 1.0 / 16, shape_bird_body)
    ent_models[.Bird_Wing] = model_bake({-0.02, -0.05, -0.24}, {1.02, 0.08, 0.12}, 1.0 / 16, shape_bird_wing)
    // As fine as the skeleton's.
    ent_models[.Hum_Torso] = model_bake({-0.27, -0.27, -0.16}, {0.27, 0.63, 0.16}, 1.0 / 24, shape_hum_torso)
    ent_models[.Hum_Head]  = model_bake({-0.22, -0.04, -0.42}, {0.22, 0.5, 0.24}, 1.0 / 40, shape_hum_head) // finer: a face
    ent_models[.Hum_Arm]   = model_bake({-0.07, -0.36, -0.07}, {0.07, 0.06, 0.07}, 1.0 / 24, shape_hum_arm)
    ent_models[.Hum_Fore]  = model_bake({-0.08, -0.29, -0.08}, {0.08, 0.06, 0.08}, 1.0 / 24, shape_hum_fore)
    ent_models[.Hum_Hand]  = model_bake({-0.06, -0.14, -0.05}, {0.08, 0.01, 0.07}, 1.0 / 32, shape_hum_hand)
    ent_models[.Hum_Leg]   = model_bake({-0.09, -0.86, -0.09}, {0.09, 0.05, 0.16}, 1.0 / 24, shape_hum_leg)
    ent_models[.Hum_Cape]  = model_bake({-0.25, -0.74, -0.07}, {0.25, 0.01, 0.01}, 1.0 / 24, shape_hum_cape)
}

// ─── Posing helpers ─────────────────────────────────────────────────────────

basis_rot_z :: proc(a: f32) -> Basis {
    c, s := math.cos(a), math.sin(a)
    return basis_from_axes({c, s, 0}, {-s, c, 0}, {0, 0, 1})
}

// A part attached at `offset` in a parent frame (pos, rot, uniform scale s).
@(private="file")
attach :: proc(f: ^Ent_Frame, model: Model_Id, pos: [3]f32, rot: Basis, s: f32,
               offset: [3]f32, local: Basis, tint: [3]f32 = {1, 1, 1}, mirror := false) {
    sc := [3]f32{mirror ? -s : s, s, s}
    ent_part(f, model, pos + rot * (offset * s), rot * local, sc, tint)
}

IDENTITY :: Basis(1)

// ─── Fox ────────────────────────────────────────────────────────────────────

FOX_TINTS := [?][3]f32{
    {0.95, 0.48, 0.18}, // red fox
    {0.78, 0.36, 0.16}, // dark red
    {0.62, 0.62, 0.64}, // grey
    {0.92, 0.9, 0.86},  // arctic
}

// Pose a fox: trot from the walk phase, scaled by how fast it's moving;
// idle foxes look around and wag.
fox_add :: proc(f: ^Ent_Frame, e: Entity, t: f32) {
    rot := basis_yaw(e.yaw)
    s := e.scale
    run := clamp(e.speed / 2.0, 0, 1.6)
    ph := e.walk_phase
    bob := 0.025 * run * math.abs(math.sin(ph))
    body := e.pos + [3]f32{0, (0.42 + bob) * s, 0}
    lean := basis_rot_x(-0.08 * clamp(e.speed / 5, 0, 1))
    brot := rot * lean
    attach(f, .Fox_Body, body, brot, s, {0, 0, 0}, IDENTITY, e.color)
    // Head: idle foxes glance around; running foxes look ahead.
    look := (1 - clamp(run, 0, 1)) * 0.6 * math.sin(t * 0.7 + e.phase)
    attach(f, .Fox_Head, body, brot, s, {0, 0.1, 0.27}, basis_yaw(look) * basis_rot_x(0.05 * math.sin(ph * 2)), e.color)
    // Legs: diagonal pairs in phase (trot).
    for i in 0 ..< 4 {
        sx: f32 = i & 1 != 0 ? 1 : -1
        sz: f32 = i & 2 != 0 ? 1 : -1
        swing := 0.55 * min(run, 1.2) * math.sin(ph + (sx * sz > 0 ? 0 : math.PI))
        attach(f, .Fox_Leg, body, brot, s, {0.1 * sx, -0.08, 0.2 * sz}, basis_rot_x(swing), e.color)
    }
    wag := (0.35 - 0.25 * clamp(run, 0, 1)) * math.sin(t * 5 + e.phase)
    attach(f, .Fox_Tail, body, brot, s, {0, 0.06, -0.28}, basis_yaw(wag) * basis_rot_x(0.35 - 0.2 * clamp(run, 0, 1)), e.color)
}

// ─── Eagles in thermals ─────────────────────────────────────────────────────

BIRD_SPEED       : f32 = f32(10.0)
BIRD_CULL_RADIUS :: f32(420.0)

// Pose an eagle: soaring with a slight dihedral, the odd burst of flaps
// (or flapping all the while: the entity sandbox's).
bird_add :: proc(f: ^Ent_Frame, e: Entity, t: f32, flap := false) {
    rot := basis_yaw(e.yaw) * basis_rot_z(-e.bank)
    s := e.scale
    flapping := flap || math.sin(t * 0.35 + e.phase * 3) > 0.8
    wing := 0.14 + (flapping ? 0.55 * math.sin(t * 12 + e.phase) : 0.03 * math.sin(t * 1.3 + e.phase))
    attach(f, .Bird_Body, e.pos, rot, s, {0, 0, 0}, IDENTITY)
    attach(f, .Bird_Wing, e.pos, rot, s, {0.07, 0.03, 0.02}, basis_rot_z(wing))
    attach(f, .Bird_Wing, e.pos, rot, s, {-0.07, 0.03, 0.02}, basis_rot_z(-wing), mirror = true)
}

// Keep a couple of eagles circling in every strong thermal near the player
// and drop the ones whose thermal is far away. Called about once a second.
birds_manage :: proc(gs: ^Game_State) {
    p := gs.camera.pos
    cx := int(math.floor(p.x / THERMAL_CELL))
    cz := int(math.floor(p.z / THERMAL_CELL))
    // Drop birds far from the player.
    for i := len(gs.entities) - 1; i >= 0; i -= 1 {
        e := gs.entities[i]
        if e.kind != .Bird { continue }
        if abs(int(e.cell.x) - cx) > 3 || abs(int(e.cell.y) - cz) > 3 { unordered_remove(&gs.entities, i) }
    }
    for dz in -2 ..= 2 {
        for dx in -2 ..= 2 {
            gx, gz := cx + dx, cz + dz
            th, ok := thermal_cell(gx, gz)
            if !ok || th.strength < 4.5 { continue }
            have := 0
            for e in gs.entities { if e.kind == .Bird && e.cell == {i32(gx), i32(gz)} { have += 1 } }
            if have >= 2 { continue }
            // Fly above the highest ground anywhere under the circle (and the
            // downwind lean), not just above the thermal's centre.
            ground := max(f32(surface_height_at(int(th.centre.x), int(th.centre.y))), SEA_LEVEL)
            ring := ground
            for i in 0 ..< 12 {
                a := f32(i) / 12 * 2 * math.PI
                r := th.radius + 14
                ring = max(ring, f32(surface_height_at(int(th.centre.x + math.cos(a) * r), int(th.centre.y + math.sin(a) * r))))
            }
            for k in have ..< 2 {
                alt := max(ground + min(th.top * 0.7, 28 + 26 * f32(k) + rand.float32_range(0, 10)), ring + 18 + 12 * f32(k))
                append(&gs.entities, Entity{
                    kind  = .Bird,
                    scale = rand.float32_range(1.5, 1.8),
                    phase = rand.float32_range(0, 2 * math.PI),
                    cell  = {i32(gx), i32(gz)},
                    orbit = {th.centre.x, th.centre.y, th.radius * rand.float32_range(0.55, 0.85), alt},
                    orbit_angle = rand.float32_range(0, 2 * math.PI),
                    orbit_dir   = rand.float32() < 0.5 ? 1 : -1,
                })
            }
        }
    }
}

// Circle the thermal: the centre leans downwind with height like the air
// does, the altitude breathes slowly, and the bank matches the turn.
bird_update :: proc(gs: ^Game_State, e: ^Entity, dt, t: f32) {
    r := max(e.orbit[2], 6)
    e.orbit_angle += e.orbit_dir * BIRD_SPEED / r * dt
    // Thermals lean ~0.08 m downwind per metre of height; birds sit ~40 up.
    lean := glider_wind(gs.glider.wind_time) * (40 * 0.08)
    c, s := math.cos(e.orbit_angle), math.sin(e.orbit_angle)
    alt := e.orbit[3] + 4 * math.sin(t * 0.05 + e.phase)
    e.pos = {e.orbit[0] + lean.x + c * r, alt, e.orbit[1] + lean.z + s * r}
    // Velocity direction is the tangent of the circle.
    vx, vz := -s * e.orbit_dir, c * e.orbit_dir
    e.yaw = math.atan2(-vx, vz)
    e.bank = -e.orbit_dir * math.atan(BIRD_SPEED * BIRD_SPEED / (9.8 * r))
}

// ─── Player body ────────────────────────────────────────────────────────────

PLAYER_TINT :: [3]f32{0.17, 0.26, 0.52} // the robe: a deep blue, as the spell's light

Player_Anim :: struct {
    body_yaw:   f32, // entity-yaw convention (radians)
    walk_phase: f32,
    amp:        f32, // smoothed stride amplitude
    air:        f32, // 0 grounded .. 1 airborne, smoothed
    climbing:   bool, // pulling up onto a ledge (anim_climb)...
    climb_yaw:  f32,  // ... facing it, as when the hands caught the lip
}

player_anim_update :: proc(gs: ^Game_State, dt: f32) {
    cam := &gs.camera
    anim_step(&gs.player_anim, cam.velocity, cam.yaw, gs.combat.sword, cam.on_ground || cam.fly_mode, dt)
    anim_climb(&gs.player_anim, cam.climbing, cam.mantle.hands, cam.pos)
}

// A pull-up faces the ledge throughout: the way to the lip as the hands
// catch it, held (later the body passes over the lip, and the way to it
// turns round). The body is left facing that way, to walk on from.
anim_climb :: proc(a: ^Player_Anim, climbing: bool, lip, pos: [3]f32) {
    if climbing && !a.climbing {
        d := lip - pos
        a.climb_yaw = d.x * d.x + d.z * d.z > 1e-4 ? math.atan2(-d.x, d.z) : a.body_yaw
    }
    a.climbing = climbing
    if climbing { a.body_yaw = a.climb_yaw }
}

// A walking body's turn, stride and airborne tuck, for velocity v and the
// look yaw (degrees, camera convention).
anim_step :: proc(a: ^Player_Anim, v: [3]f32, look_yaw: f32, sword, grounded: bool, dt: f32) {
    sp := math.sqrt(v.x * v.x + v.z * v.z)
    if sword {
        // Sword drawn: squared up to where you look, strafing.
        target := -math.to_radians(look_yaw)
        d := math.mod(target - a.body_yaw + 3 * math.PI, 2 * math.PI) - math.PI
        a.body_yaw += d * min(dt * 14, 1)
    } else if sp > 0.6 * world_scale {
        target := math.atan2(-v.x, v.z)
        d := math.mod(target - a.body_yaw + 3 * math.PI, 2 * math.PI) - math.PI
        a.body_yaw += d * min(dt * 10, 1)
    } else {
        // Standing: the head turns to look (humanoid_add_parts), the body
        // follows once it's turned as far as a neck goes.
        target := -math.to_radians(look_yaw)
        d := math.mod(target - a.body_yaw + 3 * math.PI, 2 * math.PI) - math.PI
        if excess := abs(d) - 0.9; excess > 0 { a.body_yaw += math.sign(d) * excess * min(dt * 8, 1) }
    }
    sp /= world_scale // strides as long as the legs
    a.walk_phase += sp * dt * 2.4
    a.amp += (clamp(sp / 5, 0, 1.3) - a.amp) * min(dt * 8, 1)
    air: f32 = grounded ? 0 : 1
    a.air += (air - a.air) * min(dt * 8, 1)
}

// Standing / walking / jumping player at its feet, for the chase view. In
// first person the body is only a shadow (the view starts inside its head),
// and none in fly mode: a free camera (and the benches') has no body under it.
player_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    a := &gs.player_anim
    first := gs.glider.chase_dist < 1.0
    if gs.glider.deployed || (first && gs.camera.fly_mode) || !ent_begin(f, seen = !first) { return }
    feet := gs.camera.pos - [3]f32{0, PLAYER_EYE_HEIGHT, 0}
    feet.y += gs.camera.step_visual_offset
    ent_scale_about(f, feet, world_scale)
    sword := gs.combat.sword
    act := local_body_act(gs)
    if sword { act.raise = 0 }
    hips := humanoid_add_parts(f, feet, a, gs.camera.yaw, gs.camera.pitch, PLAYER_TINT, right_arm = !sword, act = &act)
    if sword && !first { // in first person combat_add_parts draws it, seen and with a shadow
        // The sword arm reaches for the grip, posed as in first person from
        // a viewpoint at the eyes.
        fwd, right, up := camera_basis(gs.camera)
        eye := feet + [3]f32{0, HUM_HIPS_Y + 0.6 + HUM_EYE, 0} + fwd * 0.15
        shoulder := feet + basis_yaw(a.body_yaw) * [3]f32{-HUM_ARM_X, HUM_HIPS_Y + HUM_ARM_Y, 0}
        grip, blade, edge, flat := sword_world(gs, eye, fwd, right, up, shoulder)
        sword_arm_parts(f, shoulder, grip, blade, edge, flat, right * 0.6 - up - fwd * 0.4)
    }
    ent_end(f)
}

// What a body's hands are doing besides walking: pulling up onto a ledge
// (camera.odin's mantle), or casting (magic.odin), both hands toward what
// the spell works on. The same for every player's body, ours or another's.
Body_Act :: struct {
    climbing: bool,
    raise:    f32,    // casting: the hands up, 0..1
    at:       [3]f32, // world: the ledge's lip between the hands, or the spell's block
    k:        f32,    // climbing: 0..1 through the pull-up; casting: how far the spell is along
    t:        f32,    // a clock, for the trembling hands
    palms:    [2][3]f32, // out (world): where a casting body's palms are, right then left
}

// The player's joints (design metres; as Enemy_Rig): the hips above the
// feet; the legs apart; the shoulders and the neck above the hips; the eyes
// above the neck, which puts them at the camera's height.
HUM_HIPS_Y  :: f32(0.86)
HUM_LEG_X   :: f32(0.1)
HUM_ARM_X   :: f32(0.245)
HUM_ARM_Y   :: f32(0.54)
HUM_NECK    :: [3]f32{0, 0.6, -0.04} // a little back: the face over the feet
HUM_EYE     :: f32(1.7) - HUM_HIPS_Y - 0.6 // PLAYER_EYE_HEIGHT, design
HUM_UPPER_LEN :: f32(0.28) // shoulder to elbow
HUM_FORE_LEN  :: f32(0.26) // elbow to wrist
HUM_GLOVE_SCALE :: [3]f32{1.3, 1.6, 0.85} // magic.odin's open glove at the size of the body's hand (Hum_Hand)

// A basis whose -y axis points along d (limbs hang along -y).
basis_hang_along :: proc(d, ref: [3]f32) -> Basis {
    y := -la.normalize(d)
    x := la.cross(y, ref)
    if la.length2(x) < 1e-6 { x = la.cross(y, [3]f32{0, 0, 1}) }
    x = la.normalize(x)
    return basis_from_axes(x, y, la.cross(x, y))
}

// A player's body at its feet, posed by its animation (and act, if given),
// the head turned to where it looks (degrees, camera convention): the eyes
// are where the camera is, so it looks where the player does. The right
// arm too unless the caller poses it (the sword's). Returns the hips, in
// body space.
humanoid_add_parts :: proc(f: ^Ent_Frame, feet: [3]f32, a: ^Player_Anim, look_yaw, look_pitch: f32, tint: [3]f32, right_arm: bool, act: ^Body_Act = nil) -> (hips: [3]f32) {
    climb := act != nil && act.climbing
    raised := act != nil && !climb && act.raise > 0.01 ? act.raise : 0
    // Parts are given at design size about the feet (ent_scale_about): the
    // act's world points come back to that size.
    design :: proc(feet, w: [3]f32) -> [3]f32 { return feet + (w - feet) / world_scale }
    body_yaw := a.body_yaw
    if climb && !a.climbing { // no anim_climb (the sandbox): toward the lip
        d := act.at - feet
        if d.x * d.x + d.z * d.z > 1e-4 { body_yaw = math.atan2(-d.x, d.z) } // facing the ledge
    }
    rot := basis_yaw(body_yaw)
    ph := a.walk_phase
    sw := 0.7 * a.amp * math.sin(ph)
    bob := 0.04 * a.amp * math.abs(math.cos(ph))
    // In the air: legs tuck, arms lift.
    leg_l := sw * (1 - a.air) - 0.5 * a.air
    leg_r := -sw * (1 - a.air) + 0.25 * a.air
    arm_out := 0.1 + 0.5 * a.air
    lean := 0.05 * a.amp
    if climb {
        // Up the face: a knee comes up to it, the other foot pushes off,
        // leaning in over the lip as it goes over.
        u := act.k
        leg_l = -1.1 * math.sin(clamp(u * 1.6, 0, 1) * math.PI)
        leg_r = -0.4 * math.sin(clamp(u * 1.6 - 0.4, 0, 1) * math.PI)
        lean = 0.35 * math.sin(clamp(u, 0, 1) * math.PI)
    }
    hips = {0, HUM_HIPS_Y + bob, 0}
    attach(f, .Hum_Leg, feet, rot, 1, hips + {HUM_LEG_X, 0, 0}, basis_rot_x(leg_l), tint)
    attach(f, .Hum_Leg, feet, rot, 1, hips + {-HUM_LEG_X, 0, 0}, basis_rot_x(leg_r), tint)
    // The rest rides the torso, as an enemy's does (enemy_pose).
    torso := rot * basis_rot_x(lean)
    base := feet + rot * hips
    ent_part(f, .Hum_Torso, base, torso, {1, 1, 1}, tint)
    // The cape swings back with the pace and in the air, and stirs.
    flap := 0.06 + 0.3 * a.amp + 0.45 * a.air + 0.04 * a.amp * math.sin(ph * 2 + 0.7)
    ent_part(f, .Hum_Cape, base + torso * [3]f32{0, HUM_ARM_Y + 0.03, -0.12}, torso * basis_rot_x(max(flap, 0.04)), {1, 1, 1}, tint)

    // Arms: hanging and swinging, elbows a little bent; or reaching for
    // what the act is about (the wrist placed, the elbow found: two_bone_ik).
    target: [3]f32 // torso space
    if act != nil { target = la.transpose(torso) * (design(feet, act.at) - base) }
    for side in ([2]f32{1, -1}) { // left (+x), right
        if side < 0 && !right_arm { continue }
        shoulder := [3]f32{HUM_ARM_X * side, HUM_ARM_Y, 0}
        pole := [3]f32{0.5 * side, -1, -0.4} // elbows down, out and back
        elbow, wrist: [3]f32
        open := false // the glove open, palm to the spell
        palm_n: [3]f32
        switch {
        case climb:
            // Both hands on the lip, a shoulder's width apart, reached for
            // as the pull-up starts (MANTLE_GRAB).
            grip := target + {0.17 * side, 0.02, 0}
            reach := min(act.k / 0.16, 1)
            want := la.lerp(shoulder + {0.05 * side, 0.35, 0.3}, grip, reach)
            elbow, wrist = two_bone_ik(shoulder, want, pole, HUM_UPPER_LEN, HUM_FORE_LEN)
        case raised > 0:
            // Pushed out toward the block, elbows bent, the hands a little
            // apart; a tremble as the spell takes hold.
            aim := la.normalize0(target - shoulder)
            if aim == 0 { aim = {0, 0, 1} }
            out := shoulder + la.normalize(aim + {-0.3 * side, 0.05, 0}) * 0.42
            if act.k > 0 {
                w := act.t * 31 + side
                out += [3]f32{math.sin(w), math.cos(w * 1.3), 0} * 0.006 * (1 + act.k)
            }
            down := shoulder + {0.06 * side, -0.5, 0.08}
            elbow, wrist = two_bone_ik(shoulder, la.lerp(down, out, raised), pole, HUM_UPPER_LEN, HUM_FORE_LEN)
            if raised > 0.3 {
                open = true
                palm_n = la.normalize0(target - wrist)
                if palm_n == 0 { palm_n = {0, 0, 1} }
            }
        case:
            // Swinging against the legs, the forearm bending forward on the
            // way out.
            s_ := -0.8 * sw * side
            up_rot := basis_rot_z(arm_out * side) * basis_rot_x(s_)
            elbow = shoulder + up_rot * [3]f32{0, -HUM_UPPER_LEN, 0}
            wrist = elbow + up_rot * basis_rot_x(-0.3 - 0.4 * max(-s_, 0) - 0.6 * a.air) * [3]f32{0, -HUM_FORE_LEN, 0}
        }
        fore := basis_hang_along(wrist - elbow, {0, 0, 1})
        ent_part(f, .Hum_Arm, base + torso * shoulder, torso * basis_hang_along(elbow - shoulder, {0, 0, 1}), {1, 1, 1}, tint)
        ent_part(f, .Hum_Fore, base + torso * elbow, torso * fore, {1, 1, 1}, tint)
        if !open {
            ent_part(f, .Hum_Hand, base + torso * wrist, torso * fore, {1, 1, 1}, tint)
            continue
        }
        // The open glove in the fist's place, as big as it (the fist is
        // broad: the glove's palm widened and thickened to match, its
        // fingers a little shorter), its cuff under the forearm's; fingers
        // on from the forearm and up a little, palm to the block.
        dir := la.normalize(wrist - elbow)
        fingers := la.normalize(dir + {0, 0.45, 0})
        pn := la.normalize0(palm_n - fingers * la.dot(palm_n, fingers))
        if pn == 0 { pn = {0, 0, 1} }
        y := -pn
        glove := basis_from_axes(la.cross(y, fingers), y, fingers)
        rune := MAGIC_TINT * ((0.5 + 0.9 * act.k) * (0.9 + 0.1 * math.sin(act.t * 9)))
        ent_part(f, side > 0 ? .Glove_L : .Glove_R, base + torso * wrist, torso * glove, HUM_GLOVE_SCALE, rune)
        palm := wrist + fingers * 0.05 + pn * 0.04
        act.palms[side > 0 ? 1 : 0] = feet + (base + torso * palm - feet) * world_scale
    }
    // The head: turned and tipped to where the player looks.
    yaw := -math.to_radians(look_yaw)
    look := clamp(math.mod(yaw - body_yaw + 3 * math.PI, 2 * math.PI) - math.PI, -1.2, 1.2)
    pitch := clamp(-math.to_radians(look_pitch), -1.1, 1.1) - lean
    if climb { look, pitch = 0, 0.3 } // down at the hands
    ent_part(f, .Hum_Head, base + torso * HUM_NECK, torso * basis_yaw(look) * basis_rot_x(pitch), {1, 1, 1}, tint)
    return
}

// The pilot lying prone under the glider (body frame rot at the eye `p`),
// hands on the base bar. Third person only (in first person, without the
// arms, only as a shadow).
pilot_add_parts :: proc(f: ^Ent_Frame, p: [3]f32, rot: Basis, tint := PLAYER_TINT, grip := [3]f32{0.48, -0.42, 0.72}, arms := true) {
    prone := rot * basis_rot_x(math.PI / 2) // humanoid up -> glider forward, face -> down
    feet := p + rot * [3]f32{0, 0.22, -1.62}
    hips := [3]f32{0, HUM_HIPS_Y, 0}
    attach(f, .Hum_Leg, feet, prone, 1, hips + {HUM_LEG_X, 0, 0}, basis_rot_x(0.05), tint)
    attach(f, .Hum_Leg, feet, prone, 1, hips + {-HUM_LEG_X, 0, 0}, basis_rot_x(-0.05), tint)
    attach(f, .Hum_Torso, feet, prone, 1, hips, IDENTITY, tint)
    attach(f, .Hum_Cape, feet, prone, 1, hips + {0, HUM_ARM_Y + 0.03, -0.12}, basis_rot_x(0.05), tint)
    attach(f, .Hum_Head, feet, prone, 1, hips + HUM_NECK, basis_rot_x(-0.9), tint)
    if !arms { return } // drawn by the caller
    up := rot * [3]f32{0, 1, 0}
    for side in ([2]f32{1, -1}) {
        shoulder := feet + prone * (hips + [3]f32{HUM_ARM_X * side, HUM_ARM_Y, 0})
        hand := p + rot * [3]f32{grip.x * side, grip.y, grip.z}
        elbow, wrist := two_bone_ik(shoulder, hand, rot * [3]f32{0.6 * side, 0.3, -0.5}, HUM_UPPER_LEN, HUM_FORE_LEN)
        fore := basis_hang_along(wrist - elbow, up)
        ent_part(f, .Hum_Arm, shoulder, basis_hang_along(elbow - shoulder, up), {1, 1, 1}, tint)
        ent_part(f, .Hum_Fore, elbow, fore, {1, 1, 1}, tint)
        ent_part(f, .Hum_Hand, wrist, fore, {1, 1, 1}, tint)
    }
}
