package main

import "core:math"
import la "core:math/linalg"

// The player's body, built as the skeleton is (enemies.odin): a person's
// proportions, rounded parts at the joints, fine voxels. What it wears is
// the look's (player_look.odin): one torso and forearm per outfit, skirt
// panels for the long ones (each swinging with its leg, so a robe parts as
// it walks), what hangs at the back, the headwear, the hair and the beard,
// all posed by humanoid_add_parts (creatures.odin).
//
// Colours come from the part's paint: Shirt, Shirt_Trim and Robe_Dark are
// the cloth and its shades; Accent* the second cloth; Skin, Skin_Shade and
// Lip the skin; Hair_Own* the hair. Gold, leather and iron are fixed.
//
// The eyes sit at the camera's height (HUM_HIPS_Y + HUM_NECK.y + HUM_EYE =
// PLAYER_EYE_HEIGHT), so looking at another player is looking them in the eye.

// Which model each part of a look is.
Look_Parts :: struct {
    torso, fore, head, arm: Model_Id,
    arm_x:    f32, // the shoulders' joints this far either side (the build's)
    skirt:    Maybe(Model_Id), // a panel per leg, mirrored for the right
    back:     Maybe(Model_Id), // hanging from the shoulders, swinging
    wrap:     Maybe(Model_Id), // at the back's pivot, still with the torso (a cloak's mantle, a scarf)
    headwear: Maybe(Model_Id),
    hair:     Maybe(Model_Id),
    beard:    Maybe(Model_Id),
}

look_parts :: proc(l: Look) -> (p: Look_Parts) {
    l := look_clean(l)
    // The feminine build's models follow the masculine's in Model_Id.
    f := l.body == .Feminine
    built :: proc(m: Model_Id, f: bool) -> Model_Id { return f ? Model_Id(int(m) + BODY_MODELS) : m }
    switch l.outfit {
    case .Robe:   p.torso, p.fore = .Hum_Torso_Robe, .Hum_Fore_Robe
    case .Tunic:  p.torso, p.fore = .Hum_Torso_Tunic, .Hum_Fore_Tunic
    case .Coat:   p.torso, p.fore = .Hum_Torso_Coat, .Hum_Fore_Coat
    case .Padded: p.torso, p.fore = .Hum_Torso_Padded, .Hum_Fore_Padded
    }
    p.torso = built(p.torso, f)
    p.head = built(l.beard == .Stubble ? .Hum_Head_Stubble : .Hum_Head, f)
    p.arm = built(.Hum_Arm, f)
    p.arm_x = f ? HUM_ARM_X_F : HUM_ARM_X
    #partial switch l.outfit {
    case .Robe: p.skirt = built(.Hum_Skirt_Robe, f)
    case .Coat: p.skirt = built(.Hum_Skirt_Coat, f)
    }
    switch l.back {
    case .None:
    case .Cape:  p.back = .Hum_Cape
    case .Cloak: p.back, p.wrap = .Hum_Cloak, built(.Hum_Cloak_Mantle, f)
    case .Scarf: p.back, p.wrap = .Hum_Scarf_Tail, .Hum_Scarf
    }
    switch l.headwear {
    case .Hood:       p.headwear = .Hum_Hood
    case .Bare:
    case .Wizard_Hat: p.headwear = .Hum_Wizard_Hat
    case .Wide_Hat:   p.headwear = .Hum_Wide_Hat
    case .Circlet:    p.headwear = .Hum_Circlet
    }
    // Under a hood only the fringe shows (whatever's behind would come
    // through it).
    if l.headwear == .Hood {
        if l.hair != .Shaved { p.hair = .Hum_Hair_Fringe }
    } else {
        switch l.hair {
        case .Short:  p.hair = .Hum_Hair_Short
        case .Swept:  p.hair = .Hum_Hair_Swept
        case .Long:   p.hair = .Hum_Hair_Long
        case .Tied:   p.hair = .Hum_Hair_Tied
        case .Braid:  p.hair = .Hum_Hair_Braid
        case .Bun:    p.hair = .Hum_Hair_Bun
        case .Shaved:
        }
    }
    #partial switch l.beard {
    case .Short: p.beard = .Hum_Beard_Short
    case .Full:  p.beard = .Hum_Beard_Full
    }
    return
}

// A little per-voxel noise, 0..1, for weave and stubble.
@(private="file")
vhash :: proc(p: [3]f32, voxel: f32) -> f32 {
    i := [3]i32{i32(math.floor(p.x / voxel)), i32(math.floor(p.y / voxel)), i32(math.floor(p.z / voxel))}
    h := u32(i.x) * 73856093 ~ u32(i.y) * 19349663 ~ u32(i.z) * 83492791
    h ~= h >> 13
    h *= 0x5bd1e995
    h ~= h >> 15
    return f32(h & 0xffff) / 65535
}

// ─── The torso ──────────────────────────────────────────────────────────────

// The build being baked: player_models_bake bakes every part shaped by
// the body twice, the masculine then the feminine.
@(private="file")
fem: bool

// How much wider the hips are than the masculine build's, each side.
@(private="file")
hips_out :: proc() -> f32 { return fem ? 0.02 : 0 }

// How much higher a belt or sash sits: the feminine build's at its waist,
// above the hips, the masculine's on them.
@(private="file")
belt_up :: proc() -> f32 { return fem ? 0.075 : 0 }

// Chest, waist and the round of the shoulders, from the hips up (the arms
// hang from Look_Parts.arm_x, HUM_ARM_Y). The feminine: narrower in the
// shoulders and the waist, fuller at the hips, a bust.
@(private="file")
torso_core :: proc(p: [3]f32) -> f32 {
    q := [3]f32{abs(p.x), p.y, p.z}
    if fem {
        chest := (la.length((p - {0, 0.355, 0}) / [3]f32{0.178, 0.23, 0.112}) - 1) * 0.11
        bust := la.length((q - {0.068, 0.345, 0.07}) / [3]f32{1, 0.85, 1}) - 0.076
        waist := vm_round_box(p, {0, 0.13, 0}, {0.122, 0.11, 0.088}, 0.055)
        hips := vm_round_box(p, {0, 0.0, 0}, {0.178, 0.075, 0.114}, 0.055)
        shoulder := la.length(q - {0.165, 0.5, -0.005}) - 0.064
        body := vm_smin(vm_smin(vm_smin(vm_smin(chest, bust, 0.03), waist, 0.06), hips, 0.07), shoulder, 0.05)
        return vm_smin(body, neck_base(p), 0.04)
    }
    chest := (la.length((p - {0, 0.36, 0}) / [3]f32{0.2, 0.24, 0.125}) - 1) * 0.12
    waist := vm_round_box(p, {0, 0.1, 0}, {0.16, 0.14, 0.1}, 0.06)
    shoulder := la.length(q - {0.19, 0.5, -0.005}) - 0.075
    return vm_smin(vm_smin(vm_smin(chest, waist, 0.06), shoulder, 0.05), neck_base(p), 0.04)
}

// The base of the neck and the slope from it to the shoulders (the
// trapezius): up round the head's neck, so little of it shows between the
// chin and the collar.
@(private="file")
neck_base :: proc(p: [3]f32) -> f32 {
    w: f32 = fem ? 0.13 : 0.15
    r: f32 = fem ? 0.05 : 0.056
    trap := vm_capsule(p, {-w, 0.55, -0.025}, {w, 0.55, -0.025}, r)
    base := vm_capsule(p, {0, 0.54, -0.03}, {0, 0.6, -0.035}, fem ? 0.053 : 0.06)
    return vm_smin(trap, base, 0.03)
}

// Within the base of the neck, above the clothes: skin, in the chin's shade.
@(private="file")
bare_neck :: proc(p: [3]f32) -> bool {
    return p.y > 0.585 && la.length(p.xz - {0, -0.035}) < (fem ? 0.06 : 0.067)
}

// The hood laid back over the shoulders, a ring behind the neck.
@(private="file")
hood_down :: proc(p: [3]f32) -> f32 {
    return vm_capsule(p, {-0.17, 0.55, -0.03}, {0.17, 0.55, -0.03}, 0.065)
}

// The robe: a hooded robe to mid-calf (the skirt is the panels'), wide
// sleeves, a sash knotted at the side. Its opening a gold-edged V over the
// accent's under-robe.
@(private="file")
shape_torso_robe :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // The sash's knot and its two tails, out in front of the left hip.
    up := belt_up()
    in_ := fem ? f32(0.016) : 0 // the waist's front, further in
    knot := vm_round_box(p, {0.1, 0.035 + up, 0.115 - in_}, {0.03, 0.03, 0.025}, 0.015)
    // (From the feminine build's higher sash, over the hips' curve.)
    tz := fem ? f32(0.02) : 0
    tail := min(vm_capsule(p, {0.095, 0.02 + up, 0.125 - in_}, {0.085 + hips_out(), -0.2 + up, 0.15 + tz}, 0.018), vm_capsule(p, {0.11, 0.02 + up, 0.125 - in_}, {0.135 + hips_out(), -0.16 + up, 0.145 + tz}, 0.017))
    if knot < 0 { return .Accent_Dark }
    if tail < 0 { return p.y < -0.17 ? .Guard_Dark : .Accent } // gold-tipped
    skirt := vm_round_box(p, {0, -0.02, 0}, {0.18 + hips_out(), 0.1, 0.12}, 0.04)
    body := min(torso_core(p), skirt)
    if hood_down(p) < 0 && p.y > 0.5 && body > -0.01 { return p.z > 0 && q.x < 0.08 ? .Robe_Dark : .Shirt_Trim }
    if body > 0 { return .Empty }
    if bare_neck(p) { return .Skin_Shade }
    if p.y > 0.0 + up && p.y < 0.07 + up { return .Accent } // the sash
    if p.z > 0.04 {
        v := 0.016 + max(p.y - 0.3, 0) * 0.6 // the V widens to the collar
        if q.x < v - 0.016 { return .Accent_Shade }
        if q.x < v { return .Guard_Dark }
    }
    if q.x > 0.17 && p.y > 0.42 && p.y < 0.46 { return .Shirt_Trim } // the shoulder seam
    a := math.atan2(p.x, p.z)
    if p.y < 0.2 && math.sin(a * 7 + 0.4) > 0.86 { return .Shirt_Trim } // folds
    return .Shirt
}

// A tunic to mid-thigh, belted, with a laced leather jerkin over it.
@(private="file")
shape_torso_tunic :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    t := clamp(-p.y / 0.3, 0, 1)
    skirt := vm_round_box(p, {0, -0.1, 0}, {0.17 + 0.04 * t + hips_out(), 0.17, 0.11 + 0.025 * t}, 0.04)
    // A leather jerkin over the chest: the body a little fuller there, and
    // leather on top, open down the front where the tunic shows, laced.
    in_jerkin := p.y > 0.1 && p.y < 0.5 && q.x < 0.165
    core := torso_core(p) - (in_jerkin ? 0.012 : 0)
    body := min(core, skirt)
    if vm_round_box(p, {-0.17, -0.06, 0.04}, {0.035, 0.05, 0.045}, 0.018) < 0 && body > 0 { return .Leather } // a pouch
    collar := vm_capsule(p, {-0.08, 0.58, -0.035}, {0.08, 0.58, -0.035}, 0.04) // a rolled collar
    if collar < 0 && p.y > 0.55 && body > -0.02 { return .Shirt_Trim }
    if body > 0 { return .Empty }
    if bare_neck(p) { return .Skin_Shade }
    if in_jerkin {
        if p.z > 0.04 && q.x < 0.03 {
            if q.x < 0.008 + 0.012 * abs(math.sin(p.y * 75)) { return .Leather_Dark } // the lace, crossing
            return .Shirt
        }
        if p.y < 0.12 || q.x > 0.15 { return .Leather_Dark } // its edges
        return .Leather
    }
    if p.y > 0.03 + belt_up() && p.y < 0.085 + belt_up() { // the belt and its buckle
        if p.z > 0.06 && q.x < 0.026 { return .Iron }
        return .Leather_Dark
    }
    if p.y < -0.24 { return .Shirt_Trim } // the hem
    if p.y < 0 && math.sin(math.atan2(p.x, p.z) * 6) > 0.9 { return .Shirt_Trim }
    return .Shirt
}

// A coat open to the waist over the accent's shirt: a standing collar,
// gold buttons down either edge, a belt; its skirts are the panels'.
@(private="file")
shape_torso_coat :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    skirt := vm_round_box(p, {0, -0.02, 0}, {0.18 + hips_out(), 0.1, 0.12}, 0.04)
    body := min(torso_core(p), skirt)
    // The collar standing round the neck, open at the front.
    r := la.length(p.xz - {0, -0.03})
    if p.y > 0.53 && p.y < 0.66 && r < 0.13 && r > 0.085 && !(p.z > 0.06 && q.x < 0.05) {
        return p.y > 0.63 ? .Guard_Dark : .Robe_Dark
    }
    if body > 0 { return .Empty }
    if bare_neck(p) { return .Skin_Shade }
    if p.y > 0.02 + belt_up() && p.y < 0.07 + belt_up() {
        if p.z > 0.06 && q.x < 0.024 { return .Guard }
        return .Leather_Dark
    }
    if p.z > 0.04 {
        open := 0.03 + max(p.y - 0.3, 0) * 0.3 // wider toward the collar: lapels turned back
        if q.x < open { return .Accent }
        if q.x < open + 0.035 && p.y > 0.3 { return .Robe_Dark } // the lapel
        if q.x < open + 0.03 && math.mod(p.y * 1000, 70) < 22 && p.y < 0.4 { return .Guard } // buttons
        if q.x < open + 0.012 { return .Shirt_Trim }
    }
    if q.x > 0.17 && p.y > 0.42 && p.y < 0.46 { return .Shirt_Trim }
    return .Shirt
}

// A quilted jack: stitched in rows, leather on the shoulders, a broad belt.
@(private="file")
shape_torso_padded :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    t := clamp(-p.y / 0.24, 0, 1)
    skirt := vm_round_box(p, {0, -0.08, 0}, {0.18 + 0.03 * t + hips_out(), 0.15, 0.12 + 0.02 * t}, 0.045)
    // Padded out; leather caps on the shoulders, in overlapping bands.
    cap := la.length(q - {fem ? 0.182 : 0.2, 0.49, -0.005}) - (fem ? 0.096 : 0.105)
    core := torso_core(p) - 0.01
    body := min(core, skirt)
    if cap < 0 && core > -0.03 && core < 0.03 && p.y > 0.42 {
        band := la.length(q.xy - {0.2, 0.56})
        return math.mod(band * 1000, 40) < 9 ? .Leather_Dark : .Leather
    }
    collar := la.length(p.xz - {0, -0.03})
    if p.y > 0.53 && p.y < 0.62 && collar < 0.12 && collar > 0.075 { return .Shirt_Trim }
    if body > 0 { return .Empty }
    if bare_neck(p) { return .Skin_Shade }
    if p.y > 0.0 + belt_up() && p.y < 0.08 + belt_up() { // the broad belt
        if p.z > 0.06 && q.x < 0.03 { return p.y > 0.02 && p.y < 0.06 && q.x < 0.018 ? .Leather_Dark : .Iron }
        return .Leather_Dark
    }
    if p.z > 0.05 && q.x < 0.012 { return .Robe_Dark } // where it laces
    if math.mod(p.y * 1000 + 1000, 60) < 13 { return .Shirt_Trim } // the quilting's rows
    if p.y < -0.2 { return .Shirt_Trim }
    return .Shirt
}

// ─── The skirts ─────────────────────────────────────────────────────────────

// The left half of a long skirt (mirrored for the right), from its hip
// joint (HUM_LEG_X out from the middle) along -y: wide enough round to
// hide its leg, meeting the other at the middle. Each swings with its own
// leg, so the robe parts as it walks.
@(private="file")
// Also how near the outside it is (0 deep within .. 1 at it), and whether
// on its inner face, where the halves meet: seen when they part, in shade.
skirt_half :: proc(p: [3]f32, length, open: f32) -> (inside: bool, t, bx, rim: f32, within: bool) {
    if p.y > 0.02 || p.y < -length { return }
    t = clamp(-p.y / length, 0, 1)
    bx = p.x + HUM_LEG_X // across the body, from the middle
    w := 0.18 + 0.07 * t + hips_out()
    d := 0.12 + 0.05 * t
    edge := p.z > 0 ? max(open, -0.005) : -0.005
    if bx < edge { return }
    u, v := bx / w, p.z / d
    rim = u * u * u * u + v * v * v * v
    inside = rim < 1
    within = bx < edge + 0.04 && rim < 0.75
    return
}

@(private="file")
shape_skirt_robe :: proc(p: [3]f32, voxel: f32) -> Pal {
    LEN :: 0.62
    inside, t, bx, _, within := skirt_half(p, LEN, -1)
    if !inside { return .Empty }
    if p.y < -LEN + 0.035 { return .Guard }
    if within { return .Robe_Dark }
    if p.y < -LEN + 0.07 { return .Shirt_Trim }
    if p.z > 0 && bx < 0.016 { return .Guard_Dark } // the opening's edge, on down
    a := math.atan2(bx, p.z)
    if math.sin(a * 8 + 0.4) > 0.84 - 0.2 * t { return .Shirt_Trim } // folds, deeper toward the hem
    return .Shirt
}

@(private="file")
shape_skirt_coat :: proc(p: [3]f32, voxel: f32) -> Pal {
    LEN :: 0.48
    inside, _, bx, _, within := skirt_half(p, LEN, 0.035)
    if !inside { return .Empty }
    if p.y < -LEN + 0.03 || within { return .Robe_Dark }
    if p.z > 0 && bx < 0.06 { return .Shirt_Trim } // the front edge
    if p.z < 0 && bx < 0.012 { return .Robe_Dark } // the vent at the back
    return .Shirt
}

// ─── Arms and legs ──────────────────────────────────────────────────────────

// The arm in three, as a person's bends: the upper arm from the shoulder
// to the elbow, the forearm (the outfit's sleeve) to the wrist, the gloved
// hand below it. Each along -y from its joint.
@(private="file")
shape_hum_arm :: proc(p: [3]f32, voxel: f32) -> Pal {
    r: f32 = fem ? 0.053 : 0.06
    upper := vm_capsule(p, {0, -0.01, 0}, {0, -HUM_UPPER_LEN + 0.02, 0}, r)
    elbow := la.length(p - {0, -HUM_UPPER_LEN, 0}) - (r + 0.002)
    return min(upper, elbow) < 0 ? .Shirt : .Empty
}

// A wide sleeve, belling out to a gold edge at the wrist.
@(private="file")
shape_fore_robe :: proc(p: [3]f32, voxel: f32) -> Pal {
    t := clamp(-p.y / HUM_FORE_LEN, 0, 1)
    if p.y < -HUM_FORE_LEN + 0.01 { return .Empty }
    r := 0.056 + 0.05 * t * t
    if la.length(p.xz - {0, 0.01 * t}) > r { return .Empty }
    if t > 0.88 { return .Guard }
    if t > 0.8 { return .Shirt_Trim }
    return .Shirt
}

// Sleeve rolled to mid-forearm, then a laced leather bracer.
@(private="file")
shape_fore_tunic :: proc(p: [3]f32, voxel: f32) -> Pal {
    t := clamp(-p.y / HUM_FORE_LEN, 0, 1)
    if p.y < -HUM_FORE_LEN + 0.005 { return .Empty }
    r := la.length(p.xz)
    if t < 0.42 { return r < 0.056 ? .Shirt : .Empty }
    if t < 0.5 { return r < 0.064 ? .Shirt_Trim : .Empty } // rolled up
    if r > 0.056 { return .Empty }
    if p.z > 0.03 && math.mod(p.y * 1000 + 1000, 36) < 10 { return .Leather_Dark } // the lacing
    return .Leather
}

// A fitted sleeve with a deep turned-back cuff in the accent, a button on it.
@(private="file")
shape_fore_coat :: proc(p: [3]f32, voxel: f32) -> Pal {
    t := clamp(-p.y / HUM_FORE_LEN, 0, 1)
    if p.y < -HUM_FORE_LEN + 0.005 { return .Empty }
    r := la.length(p.xz)
    if t < 0.62 { return r < 0.055 ? .Shirt : .Empty }
    if r > 0.068 { return .Empty }
    if p.z < -0.05 && abs(p.x) < 0.015 && t > 0.7 && t < 0.8 { return .Guard }
    return t < 0.67 ? .Accent_Dark : .Accent
}

// A quilted sleeve, a leather cuff.
@(private="file")
shape_fore_padded :: proc(p: [3]f32, voxel: f32) -> Pal {
    t := clamp(-p.y / HUM_FORE_LEN, 0, 1)
    if p.y < -HUM_FORE_LEN + 0.005 { return .Empty }
    r := la.length(p.xz)
    if t > 0.78 { return r < 0.064 ? .Leather_Dark : .Empty }
    if r > 0.062 { return .Empty }
    return math.mod(p.y * 1000 + 1000, 55) < 12 ? .Shirt_Trim : .Shirt
}

@(private="file")
shape_hum_hand :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.065, 0.008}, {0.047, 0.06, 0.042}, 0.02) < 0 { return p.y < -0.095 ? .Glove_Dark : .Glove }
    if vm_capsule(p, {0.042, -0.03, 0.03}, {0.05, -0.08, 0.045}, 0.017) < 0 { return .Glove } // the thumb
    return .Empty
}

// Hip down along -y: the trousers (the accent's, darker), a knee, the boot
// with its top turned down.
@(private="file")
shape_hum_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    boot := vm_round_box(p, {0, -0.77, 0.035}, {0.062, 0.07, 0.105}, 0.03)
    shin := vm_capsule(p, {0, -0.44, 0.01}, {0, -0.74, 0.01}, 0.062)
    if boot < 0 || (shin < 0 && p.y < -0.6) {
        if p.y < -0.82 { return .Leather_Dark } // the sole
        return .Boot
    }
    if p.y < -0.56 && p.y > -0.62 && vm_capsule(p, {0, -0.56, 0.01}, {0, -0.62, 0.01}, 0.075) < 0 { return .Leather } // the turned top
    thigh := vm_capsule(p, {0, -0.02, 0}, {0, -0.4, 0.01}, 0.074)
    knee := la.length(p - {0, -0.42, 0.015}) - 0.07
    return min(thigh, knee, shin) < 0 ? .Trousers : .Empty
}

// ─── At the back ────────────────────────────────────────────────────────────

// Cape and cloak hang from their pivot behind the neck along -y, the
// outside toward -z, curving round the back; the accent's, lined darker.
// A sheet `length` long, `width` either side at the top and `flare` more at
// the hem (ragged): inside, how far down (0..1), whether on the lining's
// side, and how far above the hem.
@(private="file")
back_sheet :: proc(p: [3]f32, length, width, flare: f32) -> (inside: bool, t: f32, lining: bool, up: f32) {
    t = clamp(-p.y / length, 0, 1)
    half := width + flare * t
    if abs(p.x) > half || p.y > 0.02 { return }
    u := p.x / half
    z := 0.07 * u * u * (1 - 0.5 * t) // round the shoulders, flatter lower down
    if p.z > z || p.z < z - 0.056 { return }
    up = p.y + length + 0.025 * math.sin(p.x * 31)
    inside, lining = up > 0, p.z > z - 0.028 // two voxels thick (BACK_VOXEL): the inner one the lining
    return
}

@(private="file")
shape_hum_cape :: proc(p: [3]f32, voxel: f32) -> Pal {
    inside, _, lining, up := back_sheet(p, 0.68, 0.19, 0.06)
    if !inside { return .Empty }
    if up < 0.04 { return .Guard_Dark }
    if lining { return .Accent_Dark }
    return math.sin(p.x * 40) > 0.8 ? .Accent_Shade : .Accent
}

// Long, to the calves; its mantle (shape_cloak_mantle) on the shoulders.
@(private="file")
shape_hum_cloak :: proc(p: [3]f32, voxel: f32) -> Pal {
    inside, t, lining, up := back_sheet(p, 1.1, 0.23, 0.1)
    if !inside { return .Empty }
    if lining || up < 0.03 { return .Accent_Dark }
    if math.sin(p.x * 34 + t * 2) > 0.82 { return .Accent_Shade } // folds
    return .Accent
}

// The cloak's top, over the shoulders round to the collarbones, clasped at
// the front (with the torso, from the cloak's pivot behind the neck).
@(private="file")
shape_cloak_mantle :: proc(p: [3]f32, voxel: f32) -> Pal {
    b := p + HUM_BACK // body space
    q := [3]f32{abs(b.x), b.y, b.z}
    if la.length(q - {0.1, 0.5, 0.14}) < 0.022 { return .Guard } // the clasps
    // A layer over the shoulders, down to the collarbones in front.
    d := torso_core(b)
    edge := 0.42 - 0.3 * max(q.x - 0.16, 0) + 0.03 * math.sin(b.x * 40)
    if d < -0.012 || d > 0.04 || b.y < edge { return .Empty }
    if la.length(b.xz - {0, -0.04}) < 0.075 || (b.z > 0.05 && q.x < 0.09) { return .Empty } // round the neck, open at the front
    return b.y < edge + 0.025 ? .Accent_Dark : .Accent
}

// A scarf wound round the neck (with the torso, from the back's pivot
// behind the neck), striped; and its two tails (swinging from the pivot).
@(private="file")
shape_hum_scarf :: proc(p: [3]f32, voxel: f32) -> Pal {
    r := la.length(p.xz - {0, 0.085})
    ring := la.length([2]f32{r - 0.1, (p.y - 0.005) * 0.9}) - 0.045
    if ring > 0 { return .Empty }
    a := math.atan2(p.x, p.z)
    return math.sin(a * 5 + p.y * 40) > 0.6 ? .Accent_Shade : .Accent
}

@(private="file")
shape_hum_scarf_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    for side in ([2]f32{1, -1}) {
        x0 := 0.035 * side
        len_ := side > 0 ? f32(0.42) : 0.34
        if p.y < 0.01 && p.y > -len_ && abs(p.x - x0 - 0.01 * side * (-p.y)) < 0.032 && p.z < 0 && p.z > -0.03 {
            if p.y < -len_ + 0.05 { return math.mod(p.x * 1000 + 1000, 20) < 8 ? .Empty : .Accent_Dark } // fringed
            return math.mod(-p.y * 1000, 80) < 18 ? .Accent_Dark : .Accent
        }
    }
    return .Empty
}

// ─── The head ───────────────────────────────────────────────────────────────

// The head from the neck up; eyes HUM_EYE above it, looking along +z
// (finer voxels than the rest). A face: a jaw narrowing to the chin, a nose
// with a bridge, eyes with whites either side of the iris under shaded
// lids, brows, lips, the shade under the lip and chin, ears. The hair, the
// beard and what's worn on it are parts of their own.
@(private="file")
head_face :: proc(p: [3]f32, voxel: f32, stubble: bool) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    skull := la.length((p - {0, 0.255, 0}) / [3]f32{1, 1.08, 1.05}) - 0.148
    chin := clamp((0.16 - p.y) / 0.1, 0, 1)
    jaw := vm_round_box(p, {0, 0.14, 0.045}, {0.088 - 0.03 * chin, 0.06, 0.085}, 0.04)
    neck := vm_capsule(p, {0, -0.02, -0.015}, {0, 0.1, -0.015}, 0.054)
    ear := vm_round_box(q, {0.148, 0.225, -0.01}, {0.014, 0.034, 0.024}, 0.012)
    face := min(vm_smin(skull, jaw, 0.04), neck)
    bridge := vm_capsule(p, {0, HUM_EYE - 0.01, 0.146}, {0, 0.196, 0.168}, 0.013)
    tip := vm_round_box(p, {0, 0.193, 0.163}, {0.021, 0.014, 0.015}, 0.01)
    nose := min(bridge, tip)
    if min(face, nose) > 0 {
        return ear < 0 ? .Skin_Shade : .Empty
    }
    if nose < 0 && face > 0 {
        return p.y < 0.184 && q.x < 0.014 ? .Skin_Shade : .Skin // nostrils under it
    }
    e := HUM_EYE
    if p.z > 0.09 {
        if abs(p.y - e) < 0.013 && q.x > 0.03 && q.x < 0.1 {
            return abs(q.x - 0.064) < 0.013 ? .Eye : .Eye_White // iris toward the middle
        }
        if p.y >= e + 0.013 && p.y < e + 0.03 && q.x > 0.028 && q.x < 0.104 { return .Skin_Shade } // lids, under the brow
        if p.y >= e + 0.03 && p.y < e + 0.046 && q.x > 0.028 && q.x < 0.1 - 0.15 * max(q.x - 0.07, 0) { return .Hair_Own_Dark } // brows
        if abs(p.y - 0.136) < 0.009 && q.x < 0.036 { return .Lip }
        if p.y < 0.127 && p.y > 0.112 && q.x < 0.026 { return .Skin_Shade } // under the lip
    }
    if stubble && p.y < 0.168 && p.y > 0.06 && p.z > -0.02 && !(abs(p.y - 0.136) < 0.012 && q.x < 0.04) {
        if vhash(p, voxel) < 0.55 { return .Hair_Own_Dark }
        return .Skin_Shade
    }
    if p.y < 0.095 || (q.x > 0.085 && p.y < 0.15 && p.z > 0) { return .Skin_Shade } // the jaw's line, the neck in its shade
    return .Skin
}

// The feminine face: a smaller skull, a narrower jaw and a softer chin, a
// slimmer neck, a small nose. Finer voxels than the masculine head's
// (HEAD_F_VOXEL), drawn voxel by voxel on a grid laid on the eyes and either
// side of the middle (HEAD_F_LO): rows up and down from the eyes, columns
// out from the middle. Eyes two rows tall (white, iris, white) under a line
// of lashes that flicks out at the corner; a shaded lid, then brows that
// arch down at their ends; a small nose; small lips, two voxels across.
@(private="file")
head_face_fem :: proc(p: [3]f32, voxel: f32, stubble: bool) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    skull := la.length((p - {0, 0.255, 0}) / [3]f32{1, 1.08, 1.05}) - 0.145
    chin := clamp((0.16 - p.y) / 0.1, 0, 1)
    jaw := vm_round_box(p, {0, 0.148, 0.045}, {0.082 - 0.03 * chin, 0.058, 0.082}, 0.046)
    neck := vm_capsule(p, {0, -0.02, -0.015}, {0, 0.1, -0.015}, 0.047)
    ear := vm_round_box(q, {0.145, 0.225, -0.01}, {0.012, 0.03, 0.022}, 0.011)
    face := min(vm_smin(skull, jaw, 0.045), neck)
    bridge := vm_capsule(p, {0, HUM_EYE - 0.008, 0.142}, {0, 0.198, 0.156}, 0.011)
    tip := vm_round_box(p, {0, 0.19, 0.155}, {0.015, 0.009, 0.012}, 0.007)
    nose := min(bridge, tip)
    if min(face, nose) > 0 {
        return ear < 0 ? .Skin_Shade : .Empty
    }
    if nose < 0 && face > 0 { return .Skin }
    row := int(math.round((p.y - HUM_EYE) / voxel))
    col := int(math.floor(q.x / voxel))
    if p.z > 0.085 {
        switch row {
        case 3:  if col >= 2 && col <= 4 { return .Hair_Own_Dark } // the brows...
        case 2:
            if col >= 2 && col <= 4 { return .Skin_Shade }  // the lids
            if col == 5 { return .Hair_Own_Dark }           // ...arching down at their ends
        case 1:  if col >= 2 && col <= 5 { return .Eye }   // the lashes, flicking out
        case 0, -1:
            if col == 2 || col == 4 { return .Eye_White }
            if col == 3 { return .Eye }
        case -4: if col == 0 { return .Skin_Shade } // under the nose
        case -5:
            if col == 0 { return .Lip }
            if col == 1 { return .Skin_Shade } // the mouth's corners
        case -6: if col == 0 { return .Lip }
        case -7: if col == 0 { return .Skin_Shade } // under the lip
        }
    }
    if stubble && p.y < 0.168 && p.y > 0.06 && p.z > -0.02 && !(row <= -5 && row >= -6 && col <= 2) {
        if vhash(p, voxel) < 0.55 { return .Hair_Own_Dark }
        return .Skin_Shade
    }
    if p.y < 0.088 || (q.x > 0.095 && p.y < 0.135 && p.z > 0) { return .Skin_Shade } // under the jaw, the neck in its shade
    return .Skin
}

// The feminine head's grid: a voxel centre on the eyes' line, voxel
// boundaries down the middle, so the face is drawn the same either side.
HEAD_F_VOXEL :: f32(1.0 / 56)
HEAD_F_LO    :: [3]f32{-10 * HEAD_F_VOXEL, HUM_EYE - 15.5 * HEAD_F_VOXEL, -10 * HEAD_F_VOXEL}
HEAD_VOXEL   :: f32(1.0 / 40)

@(private="file")
shape_hum_head :: proc(p: [3]f32, voxel: f32) -> Pal { return fem ? head_face_fem(p, voxel, false) : head_face(p, voxel, false) }

@(private="file")
shape_hum_head_stubble :: proc(p: [3]f32, voxel: f32) -> Pal { return fem ? head_face_fem(p, voxel, true) : head_face(p, voxel, true) }

// ─── Hair ───────────────────────────────────────────────────────────────────

// A cap of hair over the skull, its line round the face: across the brow
// (a ragged fringe), past the temples to the ears, low at the nape.
@(private="file")
hair_cap :: proc(p: [3]f32, voxel: f32, top: f32 = 0, brow: f32 = 0.31) -> bool {
    q := [3]f32{abs(p.x), p.y, p.z}
    c := p - {0, 0.265 + top * 0.4, -0.012}
    if la.length(c / [3]f32{0.172, 0.18 + top, 0.178 + top * 0.3}) > 1 { return false }
    if p.z > 0.04 && p.y < brow + 0.012 * math.sin(p.x * 70) { return false }
    sideburn := q.x > 0.122 && p.z < 0.065 && p.y > 0.155
    if p.y < 0.2 && p.z > -0.045 && !sideburn { return false }
    return p.y > 0.09
}

// Strands: now and then the dark between locks, running the way the hair
// lies.
@(private="file")
strands :: proc(p: [3]f32, k: f32) -> Pal {
    a := math.atan2(p.x, -p.z)
    return math.sin(a * k + p.y * 25) > 0.88 ? .Hair_Own_Dark : .Hair_Own
}

// Hanging hair: the dark between locks, and a few strays.
@(private="file")
locks :: proc(p: [3]f32, voxel: f32) -> Pal {
    return math.sin(p.x * 55 + p.z * 10) > 0.86 || vhash(p, voxel) < 0.08 ? .Hair_Own_Dark : .Hair_Own
}

@(private="file")
shape_hair_short :: proc(p: [3]f32, voxel: f32) -> Pal {
    if !hair_cap(p, voxel) { return .Empty }
    return strands(p, 16)
}

// Swept back from a high brow, full on top.
@(private="file")
shape_hair_swept :: proc(p: [3]f32, voxel: f32) -> Pal {
    quiff := vm_capsule(p, {0, 0.4, 0.1}, {0, 0.43, -0.06}, 0.06)
    if !hair_cap(p, voxel, 0.02, 0.335) && !(quiff < 0 && p.z > -0.1 && p.y > 0.3) { return .Empty }
    return math.sin(p.x * 70) > 0.85 ? .Hair_Own_Dark : .Hair_Own // combed back
}

// To the shoulders: a curtain down the back, locks either side of the face.
@(private="file")
shape_hair_long :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    taper := clamp((0.2 - p.y) / 0.3, 0, 1) // narrower toward the ends
    back := vm_round_box(p, {0, 0.1, -0.1 - 0.02 * taper}, {0.15 - 0.045 * taper, 0.21, 0.065}, 0.06)
    lock := vm_capsule(q, {0.135, 0.26, 0.03}, {0.14, 0.0, 0.05}, 0.03 - 0.01 * taper)
    hang := (back < 0 && p.z < -0.02 && p.y > -0.1 + 0.025 * math.sin(p.x * 50)) || lock < 0
    if !hair_cap(p, voxel) && !hang { return .Empty }
    return locks(p, voxel)
}

// Drawn back into a tail at the nape, tied.
@(private="file")
shape_hair_tied :: proc(p: [3]f32, voxel: f32) -> Pal {
    tie := la.length(p - {0, 0.23, -0.19}) - 0.035
    tail := vm_capsule(p, {0, 0.22, -0.2}, {0, 0.0, -0.25}, 0.035 - 0.012 * clamp((0.22 - p.y) / 0.22, 0, 1))
    if tie < 0 { return .Leather_Dark }
    if tail < 0 { return locks(p, voxel) }
    if !hair_cap(p, voxel, 0, 0.32) { return .Empty }
    return math.sin(p.x * 70) > 0.85 ? .Hair_Own_Dark : .Hair_Own
}

// One long braid down the back, bound at the end.
@(private="file")
shape_hair_braid :: proc(p: [3]f32, voxel: f32) -> Pal {
    braid := vm_capsule(p, {0, 0.24, -0.19}, {0, -0.22, -0.22}, 0.034 - 0.01 * clamp((0.2 - p.y) / 0.4, 0, 1))
    if braid < 0 {
        if p.y < -0.17 && p.y > -0.2 { return .Leather }
        if p.y < -0.2 { return .Hair_Own }
        k := math.mod(p.y * 1000 + 1000, 50) // the plaits, crossing
        return (k < 25) == (p.x > 0) ? .Hair_Own_Dark : .Hair_Own
    }
    if !hair_cap(p, voxel, 0, 0.32) { return .Empty }
    return strands(p, 18)
}

// Gathered up into a bun at the back of the crown, tied round.
@(private="file")
shape_hair_bun :: proc(p: [3]f32, voxel: f32) -> Pal {
    bun := la.length((p - {0, 0.37, -0.165}) / [3]f32{1, 0.9, 1}) - 0.065
    if bun < 0 {
        if abs(la.length(p - {0, 0.37, -0.165}) - 0.062) < 0.012 && abs(p.y - 0.33) < 0.012 { return .Leather_Dark } // the tie
        a := math.atan2(p.x, p.y - 0.37)
        return math.sin(a * 5 + p.z * 60) > 0.75 ? .Hair_Own_Dark : .Hair_Own // wound round
    }
    if !hair_cap(p, voxel, 0, 0.325) { return .Empty }
    return math.sin(p.x * 70) > 0.85 ? .Hair_Own_Dark : .Hair_Own // drawn back
}

// What shows under a hood: the fringe and the sideburns.
@(private="file")
shape_hair_fringe :: proc(p: [3]f32, voxel: f32) -> Pal {
    if !hair_cap(p, voxel) || p.z < 0.03 { return .Empty }
    return strands(p, 16)
}

// ─── Beards ─────────────────────────────────────────────────────────────────

@(private="file")
beard_mouth :: proc(p: [3]f32) -> bool {
    return abs(p.y - 0.136) < 0.011 && abs(p.x) < 0.036 && p.z > 0.1
}

// Round the jaw and the chin, a moustache over the lip.
@(private="file")
shape_beard_short :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    chin := clamp((0.16 - p.y) / 0.12, 0, 1)
    jaw := vm_round_box(p, {0, 0.125, 0.05}, {0.098 - 0.03 * chin, 0.075, 0.098}, 0.05)
    tache := vm_capsule(q, {0, 0.153, 0.168}, {0.05, 0.14, 0.15}, 0.015)
    if tache < 0 { return .Hair_Own_Dark }
    if jaw > 0 || p.z < 0.0 || beard_mouth(p) { return .Empty }
    if p.y > 0.118 + 0.45 * max(q.x - 0.035, 0) || p.y > 0.168 { return .Empty } // its line, the sideburn down to the mouth's corner
    return math.sin(p.x * 80 + p.y * 30) > 0.8 ? .Hair_Own_Dark : .Hair_Own
}

// Long, to the chest, and the moustache over it.
@(private="file")
shape_beard_full :: proc(p: [3]f32, voxel: f32) -> Pal {
    if s := shape_beard_short(p, voxel); s != .Empty { return s }
    t := clamp((0.1 - p.y) / 0.24, 0, 1)
    long := vm_round_box(p, {0, -0.02, 0.105 + 0.02 * t}, {0.075 - 0.04 * t, 0.12, 0.045}, 0.035)
    if long > 0 || p.y > 0.11 { return .Empty }
    return locks(p, voxel)
}

// ─── Headwear ───────────────────────────────────────────────────────────────

// A roomy cowl: an arched opening rimmed in gold, a brim shading the brow,
// dark lining within, soft folds down the sides, draping onto the
// shoulders, its point hanging down behind.
@(private="file")
shape_hum_hood :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    c := p - {0, 0.27, -0.02}
    hood := la.length(c / [3]f32{0.2, 0.215, 0.228}) - 1
    inner := la.length(c / [3]f32{0.168, 0.182, 0.196}) - 1
    oval := (p.x / 0.128) * (p.x / 0.128) + ((p.y - 0.2) / 0.163) * ((p.y - 0.2) / 0.163) // the opening, arched round the face
    open := p.z > 0 && oval < 1
    drape := vm_round_box(p, {0, 0.05, -0.05}, {0.17, 0.08, 0.13}, 0.06)
    neck := vm_capsule(p, {0, -0.04, -0.015}, {0, 0.14, -0.015}, 0.075) // what the drape is round
    tip := vm_capsule(p, {0, 0.42, -0.16}, {0, 0.12, -0.27}, 0.045 - 0.025 * clamp((0.42 - p.y) / 0.3, 0, 1))
    if ((hood < 0 && inner > 0 && p.y > 0.03) || (drape < 0 && neck > 0 && inner > 0)) && !open || tip < 0 {
        if p.z > 0.12 && oval < 1.22 { return .Guard_Dark } // the rim: a band of old gold
        if p.z > -0.02 && oval < 1.7 { return .Robe_Dark } // the lining, seen within
        a := math.atan2(p.x, -p.z)
        if p.y < 0.32 && p.y > 0.06 && q.x > 0.1 && abs(math.sin(a * 6)) > 0.97 { return .Robe_Dark } // folds down the sides
        return .Shirt_Trim
    }
    return .Empty
}

// A wizard's hat: a wide brim, drooping a little, and a tall crown that
// bends back toward its tip; a band of the accent round it.
@(private="file")
shape_wizard_hat :: proc(p: [3]f32, voxel: f32) -> Pal {
    BASE :: 0.345
    r := la.length(p.xz - {0, -0.01})
    // The brim, thin, its edge drooping.
    brim_y := BASE - 0.06 * max(r - 0.17, 0) * max(r - 0.17, 0) / 0.01
    if r < 0.29 && r > 0.15 && abs(p.y - brim_y) < max(0.012, voxel * 0.6) { return r > 0.27 ? .Robe_Dark : .Shirt_Trim }
    // The crown: a cone, its axis leaning back as it rises.
    h := (p.y - BASE) / 0.48
    if h < 0 || h > 1 { return .Empty }
    axis := [2]f32{0, -0.01 - 0.17 * h * h * h}
    rad := 0.19 * (1 - h) + 0.012
    if la.length(p.xz - axis) > rad { return .Empty }
    if h < 0.1 { return h < 0.02 ? .Accent_Dark : .Accent } // the band
    if h > 0.1 && h < 0.13 && la.length(p.xz - axis - {0, rad - 0.01}) < 0.03 { return .Guard } // a buckle at the front
    return math.sin(math.atan2(p.x - axis.x, p.z - axis.y) * 5 + h * 4) > 0.85 ? .Robe_Dark : .Shirt
}

// A traveller's hat of brown felt: a broad flat brim, a low creased crown,
// a band of the accent.
@(private="file")
shape_wide_hat :: proc(p: [3]f32, voxel: f32) -> Pal {
    BASE :: 0.33
    r := la.length(p.xz - {0, -0.01})
    brim_y := BASE + 0.025 * (p.z < 0 ? max(r - 0.2, 0) / 0.1 : 0) - 0.02 * max(r - 0.2, 0) / 0.1 * (p.z > 0 ? 1 : 0)
    if r < 0.31 && r > 0.15 && abs(p.y - brim_y) < max(0.012, voxel * 0.6) { return r > 0.29 ? .Leather_Dark : .Leather }
    if p.y < BASE || p.y > BASE + 0.16 { return .Empty }
    rr := 0.188 - 0.02 * clamp((p.y - BASE - 0.08) / 0.08, 0, 1)
    if r > rr { return .Empty }
    if p.y > BASE + 0.13 && abs(p.x) < 0.035 { return .Empty } // the crease along the top
    if p.y < BASE + 0.04 { return .Accent }
    return .Leather
}

// A thin band of gold round the brow, a glowing stone at the front.
@(private="file")
shape_circlet :: proc(p: [3]f32, voxel: f32) -> Pal {
    c := p - {0, 0.31, -0.005}
    r := la.length(c.xz / [2]f32{1, 1.04})
    y := c.y + 0.03 * clamp(-c.z / 0.15, 0, 1) // lower at the back
    if la.length(p - {0, 0.315, 0.165}) < 0.015 { return .Pommel_Gem }
    if abs(y) < 0.012 && r > 0.153 && r < 0.172 { return .Guard }
    return .Empty
}

BACK_VOXEL :: f32(1.0 / 36) // cape and cloak: a lining a voxel thick inside

// The feminine build's model for each the masculine's is BODY_MODELS on.
BODY_MODELS :: int(Model_Id.Hum_Arm_F) - int(Model_Id.Hum_Arm)
#assert(int(Model_Id.Hum_Cloak_Mantle_F) - int(Model_Id.Hum_Cloak_Mantle) == BODY_MODELS)

player_models_bake :: proc() {
    // What the build shapes, for each build. As fine as the skeleton's;
    // the head finer still (a face).
    for f in ([2]bool{false, true}) {
        fem = f
        at :: proc(m: Model_Id) -> Model_Id { return fem ? Model_Id(int(m) + BODY_MODELS) : m }
        ent_models[at(.Hum_Torso_Robe)]   = model_bake({-0.27, -0.27, -0.17}, {0.27, 0.63, 0.17}, 1.0 / 24, shape_torso_robe)
        ent_models[at(.Hum_Torso_Tunic)]  = model_bake({-0.27, -0.3, -0.17}, {0.27, 0.63, 0.17}, 1.0 / 24, shape_torso_tunic)
        ent_models[at(.Hum_Torso_Coat)]   = model_bake({-0.27, -0.14, -0.17}, {0.27, 0.68, 0.17}, 1.0 / 24, shape_torso_coat)
        ent_models[at(.Hum_Torso_Padded)] = model_bake({-0.31, -0.27, -0.17}, {0.31, 0.63, 0.17}, 1.0 / 24, shape_torso_padded)
        ent_models[at(.Hum_Skirt_Robe)]   = model_bake({-0.11, -0.64, -0.18}, {0.19, 0.03, 0.18}, 1.0 / 24, shape_skirt_robe)
        ent_models[at(.Hum_Skirt_Coat)]   = model_bake({-0.11, -0.5, -0.17}, {0.18, 0.03, 0.17}, 1.0 / 24, shape_skirt_coat)
        ent_models[at(.Hum_Arm)]          = model_bake({-0.07, -0.36, -0.07}, {0.07, 0.06, 0.07}, 1.0 / 24, shape_hum_arm)
        ent_models[at(.Hum_Cloak_Mantle)] = model_bake({-0.3, -0.2, -0.1}, {0.3, 0.08, 0.34}, 1.0 / 32, shape_cloak_mantle)
        // The feminine face is drawn voxel by voxel: its grid laid on the eyes.
        head_lo, head_hi := fem ? HEAD_F_LO : [3]f32{-0.18, -0.04, -0.18}, [3]f32{0.18, 0.44, 0.22}
        head_voxel := fem ? HEAD_F_VOXEL : HEAD_VOXEL
        ent_models[at(.Hum_Head)]         = model_bake(head_lo, head_hi, head_voxel, shape_hum_head)
        ent_models[at(.Hum_Head_Stubble)] = model_bake(head_lo, head_hi, head_voxel, shape_hum_head_stubble)
    }
    fem = false
    ent_models[.Hum_Fore_Robe]    = model_bake({-0.12, -0.27, -0.12}, {0.12, 0.06, 0.12}, 1.0 / 24, shape_fore_robe)
    ent_models[.Hum_Fore_Tunic]   = model_bake({-0.08, -0.27, -0.08}, {0.08, 0.06, 0.08}, 1.0 / 24, shape_fore_tunic)
    ent_models[.Hum_Fore_Coat]    = model_bake({-0.08, -0.27, -0.08}, {0.08, 0.06, 0.08}, 1.0 / 24, shape_fore_coat)
    ent_models[.Hum_Fore_Padded]  = model_bake({-0.08, -0.27, -0.08}, {0.08, 0.06, 0.08}, 1.0 / 24, shape_fore_padded)
    ent_models[.Hum_Hand]         = model_bake({-0.06, -0.14, -0.05}, {0.08, 0.01, 0.07}, 1.0 / 32, shape_hum_hand)
    ent_models[.Hum_Leg]          = model_bake({-0.09, -0.86, -0.09}, {0.09, 0.05, 0.16}, 1.0 / 24, shape_hum_leg)
    ent_models[.Hum_Cape]         = model_bake({-0.26, -0.72, -0.07}, {0.26, 0.03, 0.08}, BACK_VOXEL, shape_hum_cape)
    ent_models[.Hum_Cloak]        = model_bake({-0.34, -1.15, -0.07}, {0.34, 0.03, 0.08}, BACK_VOXEL, shape_hum_cloak)
    ent_models[.Hum_Scarf]        = model_bake({-0.16, -0.06, -0.07}, {0.16, 0.07, 0.24}, 1.0 / 32, shape_hum_scarf)
    ent_models[.Hum_Scarf_Tail]   = model_bake({-0.1, -0.44, -0.04}, {0.1, 0.02, 0.01}, 1.0 / 32, shape_hum_scarf_tail)
    ent_models[.Hum_Hood]         = model_bake({-0.22, -0.04, -0.32}, {0.22, 0.5, 0.24}, 1.0 / 40, shape_hum_hood)
    ent_models[.Hum_Wizard_Hat]   = model_bake({-0.3, 0.26, -0.32}, {0.3, 0.84, 0.3}, 1.0 / 32, shape_wizard_hat)
    ent_models[.Hum_Wide_Hat]     = model_bake({-0.32, 0.29, -0.33}, {0.32, 0.5, 0.32}, 1.0 / 32, shape_wide_hat)
    ent_models[.Hum_Circlet]      = model_bake({-0.19, 0.27, -0.19}, {0.19, 0.35, 0.19}, 1.0 / 40, shape_circlet)
    ent_models[.Hum_Hair_Short]   = model_bake({-0.19, 0.08, -0.21}, {0.19, 0.46, 0.2}, 1.0 / 40, shape_hair_short)
    ent_models[.Hum_Hair_Swept]   = model_bake({-0.19, 0.08, -0.22}, {0.19, 0.5, 0.2}, 1.0 / 40, shape_hair_swept)
    ent_models[.Hum_Hair_Long]    = model_bake({-0.2, -0.14, -0.22}, {0.2, 0.46, 0.2}, 1.0 / 40, shape_hair_long)
    ent_models[.Hum_Hair_Tied]    = model_bake({-0.19, -0.04, -0.3}, {0.19, 0.46, 0.2}, 1.0 / 40, shape_hair_tied)
    ent_models[.Hum_Hair_Braid]   = model_bake({-0.19, -0.24, -0.27}, {0.19, 0.46, 0.2}, 1.0 / 40, shape_hair_braid)
    ent_models[.Hum_Hair_Bun]     = model_bake({-0.19, 0.08, -0.25}, {0.19, 0.46, 0.2}, 1.0 / 40, shape_hair_bun)
    ent_models[.Hum_Hair_Fringe]  = model_bake({-0.19, 0.08, 0.0}, {0.19, 0.46, 0.2}, 1.0 / 40, shape_hair_fringe)
    ent_models[.Hum_Beard_Short]  = model_bake({-0.16, 0.03, -0.04}, {0.16, 0.21, 0.2}, 1.0 / 40, shape_beard_short)
    ent_models[.Hum_Beard_Full]   = model_bake({-0.16, -0.18, -0.04}, {0.16, 0.21, 0.2}, 1.0 / 40, shape_beard_full)
}
