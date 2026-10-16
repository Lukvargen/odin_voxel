package main

import "core:math"
import la "core:math/linalg"
import "core:slice"

// Entity voxel models. Every entity is drawn as one or more rigid parts, each
// a small voxel grid with its own voxel size (finer than the terrain) and its
// own transform, Cube World style: animation moves and rotates parts, the
// voxels themselves never change. Models are baked once at startup from the
// shape functions below and live in the static half of gs.entity_buf; the
// per-frame entity/part instance lists go in the dynamic half (entities.odin).
// The tracer side is shaders/entity_voxel.hlsl.

Model_Id :: enum u32 {
    Crystal,
    Glider_Wing,
    Rod,        // thin metal tube along +z, 1 m long: scale z to the length
    Arm,        // sleeve + hand along +z, 1 m long (first-person glider arms)
    // creatures.odin
    Fox_Body, Fox_Head, Fox_Leg, Fox_Tail,
    Bird_Body, Bird_Wing,
    Hum_Head, Hum_Torso, Hum_Arm, Hum_Leg,
    // combat.odin, slime.odin
    Sword,      // grip at the origin, blade along +z
    Slime,      // 1 m cube-ish blob standing on its origin, face toward +z
    Goo,        // a small cube: splatter, dust
    Fist,       // a right hand around the sword's grip, in the sword's frame
    Arm_Upper,  // sleeve along +z, 1 long: scale z to the length
    Arm_Fore,   // sleeve, cuff, wrist along +z, 1 long
    // enemies.odin: humanoid rigs, pivots at the joints (see Enemy_Rig)
    Skel_Skull, Skel_Torso, Skel_Arm, Skel_Leg,
    Gob_Head, Gob_Torso, Gob_Arm, Gob_Leg,
    Orc_Head, Orc_Torso,
    Club, Old_Sword, Axe, // grip at the origin, along +z
    // sea.odin
    Fish_Body, Fish_Body_Striped, Fish_Tail,
}

Voxel_Model :: struct {
    dims:  [3]int,  // multiples of 4 (the occupancy brick size)
    voxel: f32,     // model-space size of one voxel
    lo:    [3]f32,  // model-space position of the grid's min corner; model origin = pivot
    data:  []u8,    // palette index per voxel, 0 = empty; x fastest, then y, then z
}

// ─── Palette ────────────────────────────────────────────────────────────────

PAL_TINT :: 1 // colour is multiplied by the part's tint
PAL_EMIT :: 2 // glows on its own
PAL_THIN :: 4 // thin fabric: the sun shines through from behind

Pal :: enum u8 {
    Empty,
    Eye, Eye_White,
    Crystal, Crystal_Core,
    Sail, Sail_White, Sail_Navy,
    Metal,
    Fur, Fur_Light, Fur_Dark, Nose,
    Feather, Feather_Dark, Feather_White, Beak,
    Skin, Hair, Shirt, Shirt_Trim, Pants, Boot, Belt,
    Blade, Blade_Edge, Guard, Grip, Pommel_Gem,
    Blade_Fuller, Guard_Dark, Grip_Wrap, Glove, Glove_Dark, Glove_Light,
    Slime, Slime_Light, Slime_Core, Mouth,
    Bone, Bone_Shadow, Eye_Glow, Hide, Hide_Dark, Leather, Leather_Dark,
    Tusk, Iron, Rust, Wood, Wood_Dark, Cloth, Eye_Yellow, Eye_Red,
    Fish_Scale, Fish_Belly, Fish_Fin, Fish_Stripe,
}
#assert(len(Pal) <= 64) // ENT_PAL_BASE reserves 64 entries

@(private="file")
pal_entry :: proc(p: Pal) -> (rgb: [3]u8, flags: u8) {
    switch p {
    case .Empty:         return {0, 0, 0}, 0
    case .Eye:           return {16, 16, 22}, 0
    case .Eye_White:     return {240, 240, 235}, 0
    case .Crystal:       return {115, 190, 255}, PAL_EMIT
    case .Crystal_Core:  return {200, 240, 255}, PAL_EMIT
    case .Sail:          return {242, 92, 32}, PAL_THIN
    case .Sail_White:    return {235, 235, 225}, PAL_THIN
    case .Sail_Navy:     return {22, 42, 108}, PAL_THIN
    case .Metal:         return {158, 163, 173}, 0
    case .Fur:           return {255, 255, 255}, PAL_TINT
    case .Fur_Light:     return {240, 232, 220}, 0
    case .Fur_Dark:      return {40, 30, 26}, 0
    case .Nose:          return {22, 18, 18}, 0
    case .Feather:       return {110, 72, 40}, 0
    case .Feather_Dark:  return {52, 36, 26}, 0
    case .Feather_White: return {236, 232, 222}, 0
    case .Beak:          return {232, 178, 40}, 0
    case .Skin:          return {232, 184, 142}, 0
    case .Hair:          return {84, 52, 30}, 0
    case .Shirt:         return {255, 255, 255}, PAL_TINT
    case .Shirt_Trim:    return {205, 205, 205}, PAL_TINT
    case .Pants:         return {58, 66, 104}, 0
    case .Boot:          return {62, 42, 30}, 0
    case .Belt:          return {40, 30, 24}, 0
    case .Blade:         return {196, 204, 216}, 0
    case .Blade_Edge:    return {236, 242, 250}, 0
    case .Guard:         return {214, 162, 58}, 0
    case .Grip:          return {92, 54, 32}, 0
    case .Pommel_Gem:    return {90, 200, 255}, PAL_EMIT
    case .Blade_Fuller:  return {138, 146, 162}, 0
    case .Guard_Dark:    return {150, 104, 34}, 0
    case .Grip_Wrap:     return {160, 108, 60}, 0
    case .Glove:         return {116, 72, 42}, 0
    case .Glove_Dark:    return {70, 42, 26}, 0
    case .Glove_Light:   return {156, 104, 62}, 0
    case .Slime:         return {255, 255, 255}, PAL_TINT
    case .Slime_Light:   return {255, 255, 255}, PAL_TINT | PAL_THIN
    case .Slime_Core:    return {190, 190, 190}, PAL_TINT
    case .Mouth:         return {40, 22, 30}, 0
    case .Bone:          return {214, 205, 180}, 0
    case .Bone_Shadow:   return {128, 118, 98}, 0
    case .Eye_Glow:      return {255, 110, 50}, PAL_EMIT
    case .Hide:          return {255, 255, 255}, PAL_TINT
    case .Hide_Dark:     return {170, 170, 170}, PAL_TINT
    case .Leather:       return {104, 70, 44}, 0
    case .Leather_Dark:  return {62, 42, 28}, 0
    case .Tusk:          return {232, 222, 192}, 0
    case .Iron:          return {104, 108, 116}, 0
    case .Rust:          return {124, 72, 42}, 0
    case .Wood:          return {116, 80, 48}, 0
    case .Wood_Dark:     return {72, 48, 30}, 0
    case .Cloth:         return {128, 38, 30}, 0
    case .Eye_Yellow:    return {232, 204, 70}, 0
    case .Eye_Red:       return {196, 40, 28}, PAL_EMIT
    case .Fish_Scale:    return {255, 255, 255}, PAL_TINT
    case .Fish_Belly:    return {236, 232, 222}, 0
    case .Fish_Fin:      return {180, 180, 180}, PAL_TINT | PAL_THIN
    case .Fish_Stripe:   return {246, 244, 238}, 0
    }
    return {255, 0, 255}, 0
}

// ─── Shape helpers (model space, metres) ───────────────────────────────────

vm_capsule :: proc(p, a, b: [3]f32, r: f32) -> f32 {
    pa, ba := p - a, b - a
    h := clamp(la.dot(pa, ba) / la.dot(ba, ba), 0, 1)
    return la.length(pa - ba * h) - r
}

vm_smin :: proc(a, b, k: f32) -> f32 {
    h := clamp(0.5 + 0.5 * (b - a) / k, 0, 1)
    return math.lerp(b, a, h) - k * h * (1 - h)
}

// Unsigned distance to a triangle (Inigo Quilez).
@(private="file")
ud_triangle :: proc(p, a, b, c: [3]f32) -> f32 {
    dot2 :: proc(v: [3]f32) -> f32 { return la.dot(v, v) }
    ba, pa := b - a, p - a
    cb, pb := c - b, p - b
    ac, pc := a - c, p - c
    nor := la.cross(ba, ac)
    inside := math.sign(la.dot(la.cross(ba, nor), pa)) + math.sign(la.dot(la.cross(cb, nor), pb)) + math.sign(la.dot(la.cross(ac, nor), pc))
    if inside < 2 {
        return math.sqrt(min(
            dot2(ba * clamp(la.dot(ba, pa) / dot2(ba), 0, 1) - pa),
            dot2(cb * clamp(la.dot(cb, pb) / dot2(cb), 0, 1) - pb),
            dot2(ac * clamp(la.dot(ac, pc) / dot2(ac), 0, 1) - pc)))
    }
    d := la.dot(nor, pa)
    return math.sqrt(d * d / dot2(nor))
}

// A tube at least one voxel thick, so thin rods never break up.
vm_tube :: proc(p, a, b: [3]f32, r, voxel: f32) -> bool {
    return vm_capsule(p, a, b, 0) < max(r, voxel * 0.55)
}

// Rounded box centred at c with half size h and corner radius r.
vm_round_box :: proc(p, c, h: [3]f32, r: f32) -> f32 {
    q := la.abs(p - c) - (h - r)
    return la.length(la.max(q, 0)) + min(max(q.x, max(q.y, q.z)), 0) - r
}

// ─── Shapes ─────────────────────────────────────────────────────────────────
// Each returns the palette entry at model-space point p (a voxel centre).

// Crystal: stretched octahedron, pivot at its centre, brighter core.
@(private="file")
shape_crystal :: proc(p: [3]f32, voxel: f32) -> Pal {
    d := abs(p.x) / 0.26 + abs(p.y) / 0.5 + abs(p.z) / 0.26
    if d > 1 { return .Empty }
    return d < 0.45 ? .Crystal_Core : .Crystal
}

// Hang glider, body frame: origin at the pilot's eye, +z nose, +y up, +x the
// LEFT wing.
GLIDER_NOSE :: [3]f32{0, 1.25, 1.9}
GLIDER_TAIL :: [3]f32{0, 1.42, -1.6}
GLIDER_TIP  :: [3]f32{3.7, 1.08, -1.0} // left tip; the right one mirrors x

@(private="file")
shape_glider_wing :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z} // symmetric
    nose, tail, tip := GLIDER_NOSE, GLIDER_TAIL, GLIDER_TIP
    // Tubes: leading edge, keel, crossbar, king post.
    if vm_tube(q, nose, tip, 0.055, voxel) ||
       vm_tube(p, nose, {0, 1.32, -1.95}, 0.05, voxel) ||
       vm_tube(q, {0, 1.17, -0.2}, {1.9, 1.17, -0.2}, 0.04, voxel) ||
       vm_tube(p, {0, 1.3, 0.1}, {0, 1.95, 0.1}, 0.035, voxel) {
        return .Metal
    }
    // Sail, billowing up between tip and keel at the trailing edge.
    mid := la.lerp(tip, tail, f32(0.5)) + [3]f32{0, 0.12, 0.08}
    d := min(ud_triangle(q, nose, tip, mid), ud_triangle(q, nose, mid, tail))
    if d > voxel * 0.55 { return .Empty }
    // Chevrons sweeping back from the nose.
    v := q.z + q.x * 0.55
    v = (v * 0.42) - math.floor(v * 0.42)
    if v < 0.22 { return .Sail_White }
    if v < 0.34 { return .Sail_Navy }
    return .Sail
}

// Rods and arms are drawn as separate parts oriented along their length, so
// their boxes are tight: things right in front of the camera (the A-frame,
// the pilot's arms) would otherwise make every ray walk a mostly empty box.
@(private="file")
shape_rod :: proc(p: [3]f32, voxel: f32) -> Pal {
    return p.x * p.x + p.y * p.y < 0.035 * 0.035 ? .Metal : .Empty
}

@(private="file")
shape_arm :: proc(p: [3]f32, voxel: f32) -> Pal {
    r := math.sqrt(p.x * p.x + p.y * p.y)
    if p.z > 0.86 && r < 0.075 { return .Skin }
    return r < 0.06 ? .Shirt : .Empty
}

// ─── Baking and GPU packing ────────────────────────────────────────────────

ent_models: [Model_Id]Voxel_Model

model_bake :: proc(lo, hi: [3]f32, voxel: f32, shape: proc(p: [3]f32, voxel: f32) -> Pal) -> Voxel_Model {
    m := Voxel_Model{voxel = voxel, lo = lo}
    for a in 0 ..< 3 {
        n := int(math.ceil((hi[a] - lo[a]) / voxel))
        m.dims[a] = (n + 3) &~ 3
    }
    m.data = make([]u8, m.dims.x * m.dims.y * m.dims.z)
    for z in 0 ..< m.dims.z {
        for y in 0 ..< m.dims.y {
            for x in 0 ..< m.dims.x {
                p := lo + ([3]f32{f32(x), f32(y), f32(z)} + 0.5) * voxel
                m.data[x + m.dims.x * (y + m.dims.y * z)] = u8(shape(p, voxel))
            }
        }
    }
    return m
}

ent_models_bake :: proc() {
    creature_models_bake()
    combat_models_bake()
    enemy_models_bake()
    fish_models_bake()
    ent_models[.Crystal]      = model_bake({-0.3, -0.52, -0.3}, {0.3, 0.52, 0.3}, 1.0 / 16, shape_crystal)
    ent_models[.Glider_Wing]  = model_bake({-3.85, 0.95, -2.05}, {3.85, 2.05, 2.0}, 1.0 / 12, shape_glider_wing)
    ent_models[.Rod]          = model_bake({-0.05, -0.05, 0}, {0.05, 0.05, 1}, 1.0 / 24, shape_rod)
    ent_models[.Arm]          = model_bake({-0.08, -0.08, 0}, {0.08, 0.08, 1}, 1.0 / 24, shape_arm)
}

// GPU layout of gs.entity_buf, in uint4 units (shaders/entity_voxel.hlsl):
//   [0]                       header: dynamic base, 0, 0, 0
//   [ENT_PAL_BASE..+64)       palette, one u32 per entry: rgb | flags << 24
//   [ENT_MODEL_BASE..+2/model) model table: (dims, voxel word), (brick dims, brick word)
//   ...                       per model: voxel bytes, then one 64-bit occupancy
//                             mask per 4^3 brick (bit = x + 4y + 16z)
//   [dyn_base..]              per frame: Ent_Frame up to n_ents — header, entity
//                             records, parts, screen-tile masks, sun-grid masks
ENT_PAL_BASE   :: 1
ENT_MODEL_BASE :: ENT_PAL_BASE + 64
ENT_DATA_BASE  :: ENT_MODEL_BASE + 2 * len(Model_Id)

// The static part of the buffer as u32 words, and the uint4 index where
// the per-frame part starts.
ent_static_words :: proc() -> (words: []u32, dyn_base: int) {
    out := make([dynamic]u32, ENT_DATA_BASE * 4)
    for p in Pal {
        rgb, flags := pal_entry(p)
        out[ENT_PAL_BASE * 4 + int(p)] = u32(rgb[0]) | u32(rgb[1]) << 8 | u32(rgb[2]) << 16 | u32(flags) << 24
    }
    append_bytes :: proc(out: ^[dynamic]u32, bytes: []u8) -> u32 {
        start := u32(len(out))
        for i := 0; i < len(bytes); i += 4 {
            w: u32
            for k in 0 ..< 4 {
                if i + k < len(bytes) { w |= u32(bytes[i + k]) << (u32(k) * 8) }
            }
            append(out, w)
        }
        for len(out) % 4 != 0 { append(out, 0) }
        return start
    }
    for &m, id in ent_models {
        vword := append_bytes(&out, m.data)
        bd := m.dims / 4
        masks := make([]u64, bd.x * bd.y * bd.z, context.temp_allocator)
        for z in 0 ..< m.dims.z {
            for y in 0 ..< m.dims.y {
                for x in 0 ..< m.dims.x {
                    if m.data[x + m.dims.x * (y + m.dims.y * z)] != 0 {
                        masks[x / 4 + bd.x * (y / 4 + bd.y * (z / 4))] |= 1 << u64(x % 4 + 4 * (y % 4) + 16 * (z % 4))
                    }
                }
            }
        }
        bword := append_bytes(&out, slice.to_bytes(masks))
        t := (ENT_MODEL_BASE + 2 * int(id)) * 4
        out[t + 0], out[t + 1], out[t + 2], out[t + 3] = u32(m.dims.x), u32(m.dims.y), u32(m.dims.z), vword
        out[t + 4], out[t + 5], out[t + 6], out[t + 7] = u32(bd.x), u32(bd.y), u32(bd.z), bword
    }
    dyn_base = len(out) / 4
    out[0] = u32(dyn_base)
    return out[:], dyn_base
}

// ─── Instances ──────────────────────────────────────────────────────────────

MAX_ENT_PARTS :: 1024

// Matches the 2-uint4 entity record in entity_voxel.hlsl.
Ent_Gpu :: struct #packed {
    aabb_min: [3]f32, first_part: u32,
    aabb_max: [3]f32, part_count: u32,
}

// Matches the 6-uint4 part record: world -> model-grid affine rows (grid
// units are voxels), world box, model, tint.
Part_Gpu :: struct #packed {
    rows:     [3][4]f32,
    aabb_min: [3]f32, model: u32,
    aabb_max: [3]f32, flags: u32,
    tint:     [3]f32, _pad:  f32,
}

// Which entities a ray can possibly hit is answered by two bitmasks (bit i
// = entity i), built on the CPU each frame from the entity boxes:
//  - view rays: per 16x16-pixel screen tile, the entities whose projected
//    box overlaps it. A pixel loads one mask and is done if it's empty.
//  - sun shadow rays: per cell of a grid on a plane facing the sun (centred
//    on the camera), the shadow-casting entities whose box projects onto it
//    along the sun direction. Points outside the grid clamp to its edge,
//    and boxes are clamped the same way, so the edge cells stay conservative.
// Most pixels are nowhere near an entity, so they pay one load, not a
// traversal — that per-pixel cost was most of the entity GPU time.
ENT_TILE        :: 16
ENT_TILES_X     :: (MAX_RENDER_W + ENT_TILE - 1) / ENT_TILE
ENT_TILES_Y     :: (MAX_RENDER_H + ENT_TILE - 1) / ENT_TILE
ENT_SUN_GRID    :: 64
ENT_SUN_CELL    :: f32(4)

// Matches the 4-uint4 header of the per-frame data.
Ent_Header :: struct #packed {
    tiles_x, tiles_y: u32, _pad0: [2]u32,
    sun_u: [3]f32, u0: f32, // grid axes (perpendicular to the sun) and origins
    sun_v: [3]f32, v0: f32,
    _pad1: [4]u32,
}

// One bit per entity (MAX_ENTITIES): a uint4 on the GPU.
Ent_Mask :: [2]u64

Ent_Frame :: struct {
    hdr:    Ent_Header,
    ents:   [MAX_ENTITIES]Ent_Gpu,
    parts:  [MAX_ENT_PARTS]Part_Gpu,
    sun:    [ENT_SUN_GRID * ENT_SUN_GRID]Ent_Mask,
    tiles:  [ENT_TILES_X * ENT_TILES_Y]Ent_Mask, // last: only tiles_x * tiles_y are uploaded
    // CPU only below
    n_ents, n_parts: int,
    no_shadow: [MAX_ENTITIES]bool,
    // The open entity drawn `scale` times its size about `anchor`
    // (ent_scale_about; 0: as given). Bodies are posed at their design size.
    anchor:    [3]f32,
    scale:     f32,
    corners: [MAX_ENT_PARTS][8][3]f32, // oriented part boxes, for the screen masks
}

// Pixel rect (x0, y0, x1, y1) of part p's oriented box, or false when it's
// entirely behind the eye or off screen.
@(private="file")
part_screen_rect :: proc(f: ^Ent_Frame, p: int, eye, fwd, right, up: [3]f32, w, h: f32) -> (r: [4]f32, ok: bool) {
    NEAR :: f32(0.05)
    // Eye inside the box (in grid space, 0..dims): the whole screen.
    part := f.parts[p]
    dims := ent_models[Model_Id(part.model)].dims
    inside := true
    for a in 0 ..< 3 {
        g := la.dot(part.rows[a].xyz, eye) + part.rows[a].w
        if g < 0 || g > f32(dims[a]) { inside = false }
    }
    if inside { return {0, 0, w, h}, true }

    pts: [20][3]f32 // corners in front + edge crossings of the eye plane
    n := 0
    cs := &f.corners[p]
    zs: [8]f32
    for c in 0 ..< 8 {
        zs[c] = la.dot(cs[c] - eye, fwd)
        if zs[c] >= NEAR { pts[n] = cs[c]; n += 1 }
    }
    if n == 0 { return }
    for c in 0 ..< 8 {
        for bit in ([3]int{1, 2, 4}) {
            if c & bit != 0 { continue }
            d := c | bit
            if (zs[c] < NEAR) == (zs[d] < NEAR) { continue }
            k := (NEAR - zs[c]) / (zs[d] - zs[c])
            pts[n] = cs[c] + (cs[d] - cs[c]) * k
            n += 1
        }
    }
    r = {1e9, 1e9, -1e9, -1e9}
    for q in pts[:n] {
        dq := q - eye
        z := max(la.dot(dq, fwd), NEAR)
        nx := la.dot(dq, right) / z / la.length2(right)
        ny := la.dot(dq, up) / z / la.length2(up)
        px, py := (nx + 1) * 0.5 * w, (1 - ny) * 0.5 * h
        r = {min(r[0], px), min(r[1], py), max(r[2], px), max(r[3], py)}
    }
    if r[2] < -1 || r[3] < -1 || r[0] > w + 1 || r[1] > h + 1 { return }
    return r, true
}

// Fill the screen-tile and sun-grid masks for this frame's camera.
ent_build_masks :: proc(f: ^Ent_Frame, gs: ^Game_State) {
    cam := gs.camera
    w, h := f32(gs.render_w), f32(gs.render_h)
    fwd, right, up := camera_view_basis(cam, w / h)
    eye := camera_view_eye(cam)
    tx := (int(gs.render_w) + ENT_TILE - 1) / ENT_TILE
    ty := (int(gs.render_h) + ENT_TILE - 1) / ENT_TILE
    f.hdr.tiles_x, f.hdr.tiles_y = u32(tx), u32(ty)

    l := la.normalize(gs.light_dir)
    ref := abs(l.y) > 0.99 ? [3]f32{1, 0, 0} : [3]f32{0, 1, 0}
    su := la.normalize(la.cross(l, ref))
    sv := la.cross(l, su)
    half := ENT_SUN_GRID / 2 * ENT_SUN_CELL
    f.hdr.sun_u, f.hdr.u0 = su, la.dot(eye, su) - half
    f.hdr.sun_v, f.hdr.v0 = sv, la.dot(eye, sv) - half

    for i in 0 ..< f.n_ents {
        e := f.ents[i]
        word, bit := i >> 6, u64(1) << u64(i & 63)
        // Screen tiles: each part's oriented box, clipped at the eye plane.
        // Only a part whose box holds the eye covers the whole screen; the
        // glider's wing and frame otherwise claim just the tiles they span.
        for p in e.first_part ..< e.first_part + e.part_count {
            r, ok := part_screen_rect(f, int(p), eye, fwd, right, up, w, h)
            if !ok { continue }
            ax := clamp(int(math.floor((r[0] - 1) / ENT_TILE)), 0, tx - 1)
            bx := clamp(int(math.floor((r[2] + 1) / ENT_TILE)), 0, tx - 1)
            ay := clamp(int(math.floor((r[1] - 1) / ENT_TILE)), 0, ty - 1)
            by := clamp(int(math.floor((r[3] + 1) / ENT_TILE)), 0, ty - 1)
            for yy in ay ..= by { for xx in ax ..= bx { f.tiles[yy * tx + xx][word] |= bit } }
        }
        umin, vmin, umax, vmax := f32(1e9), f32(1e9), f32(-1e9), f32(-1e9)
        for c in 0 ..< 8 {
            q := [3]f32{c & 1 != 0 ? e.aabb_max.x : e.aabb_min.x, c & 2 != 0 ? e.aabb_max.y : e.aabb_min.y, c & 4 != 0 ? e.aabb_max.z : e.aabb_min.z}
            u, v := la.dot(q, su), la.dot(q, sv)
            umin, umax, vmin, vmax = min(umin, u), max(umax, u), min(vmin, v), max(vmax, v)
        }
        if f.no_shadow[i] { continue }
        cu0 := clamp(int(math.floor((umin - f.hdr.u0) / ENT_SUN_CELL)), 0, ENT_SUN_GRID - 1)
        cu1 := clamp(int(math.floor((umax - f.hdr.u0) / ENT_SUN_CELL)), 0, ENT_SUN_GRID - 1)
        cv0 := clamp(int(math.floor((vmin - f.hdr.v0) / ENT_SUN_CELL)), 0, ENT_SUN_GRID - 1)
        cv1 := clamp(int(math.floor((vmax - f.hdr.v0) / ENT_SUN_CELL)), 0, ENT_SUN_GRID - 1)
        for vv in cv0 ..= cv1 { for uu in cu0 ..= cu1 { f.sun[vv * ENT_SUN_GRID + uu][word] |= bit } }
    }
}

// A part stretched from a to b along its model +z (Rod, Arm); `up` picks
// the roll around the length.
ent_segment :: proc(f: ^Ent_Frame, model: Model_Id, a, b, up: [3]f32, tint: [3]f32 = {1, 1, 1}) {
    d := b - a
    l := la.length(d)
    if l < 1e-4 { return }
    z := d / l
    x := la.cross(up, z)
    if la.length2(x) < 1e-6 { x = la.cross([3]f32{1, 0, 0}, z) }
    x = la.normalize(x)
    ent_part(f, model, a, basis_from_axes(x, la.cross(z, x), z), {1, 1, l}, tint)
}

// Rotation (columns = model x, y, z axes in world space).
Basis :: matrix[3, 3]f32

basis_from_axes :: proc(x, y, z: [3]f32) -> (m: Basis) {
    for r in 0 ..< 3 { m[r, 0], m[r, 1], m[r, 2] = x[r], y[r], z[r] }
    return
}

// Entity-yaw convention: model +z faces {-sin(yaw), 0, cos(yaw)}.
basis_yaw :: proc(yaw: f32) -> Basis {
    c, s := math.cos(yaw), math.sin(yaw)
    return basis_from_axes({c, 0, s}, {0, 1, 0}, {-s, 0, c})
}

basis_rot_x :: proc(a: f32) -> Basis {
    c, s := math.cos(a), math.sin(a)
    return basis_from_axes({1, 0, 0}, {0, c, s}, {0, -s, c})
}

// casts_shadow = false: only seen directly, never in shadow rays.
ent_begin :: proc(f: ^Ent_Frame, casts_shadow := true) -> bool {
    if f.n_ents >= MAX_ENTITIES { return false }
    f.no_shadow[f.n_ents] = !casts_shadow
    f.ents[f.n_ents] = {
        aabb_min = {1e9, 1e9, 1e9}, aabb_max = {-1e9, -1e9, -1e9},
        first_part = u32(f.n_parts),
    }
    return true
}

// The rest of the open entity's parts, given at their design size about
// `anchor` (its feet, its eye), drawn `s` times as big.
ent_scale_about :: proc(f: ^Ent_Frame, anchor: [3]f32, s: f32) {
    f.anchor, f.scale = anchor, s
}

ent_end :: proc(f: ^Ent_Frame) {
    f.scale = 0
    e := &f.ents[f.n_ents]
    e.part_count = u32(f.n_parts) - e.first_part
    if e.part_count > 0 { f.n_ents += 1 }
}

// Add a part to the open entity: the model's origin goes to `pos`, its axes
// rotated by `rot` and scaled per axis by `scale`.
ent_part :: proc(f: ^Ent_Frame, model: Model_Id, pos: [3]f32, rot: Basis, scale: [3]f32 = {1, 1, 1}, tint: [3]f32 = {1, 1, 1}) {
    if f.n_parts >= MAX_ENT_PARTS { return }
    pos, scale := pos, scale
    if f.scale > 0 {
        pos = f.anchor + (pos - f.anchor) * f.scale
        scale *= f.scale
    }
    m := &ent_models[model]
    // world = pos + rot * (scale * local); grid = (local - lo) / voxel.
    // So grid_i = (dot(col_i, world - pos) / scale_i - lo_i) / voxel.
    p: Part_Gpu
    for i in 0 ..< 3 {
        col := [3]f32{rot[0, i], rot[1, i], rot[2, i]}
        k := 1 / (scale[i] * m.voxel)
        p.rows[i] = {col.x * k, col.y * k, col.z * k, -la.dot(col, pos) * k - m.lo[i] / m.voxel}
    }
    hi := m.lo + la.array_cast(m.dims, f32) * m.voxel
    mn := [3]f32{1e9, 1e9, 1e9}
    mx := [3]f32{-1e9, -1e9, -1e9}
    for c in 0 ..< 8 {
        corner := [3]f32{c & 1 != 0 ? hi.x : m.lo.x, c & 2 != 0 ? hi.y : m.lo.y, c & 4 != 0 ? hi.z : m.lo.z}
        w := pos + rot * (corner * scale)
        f.corners[f.n_parts][c] = w
        mn = la.min(mn, w)
        mx = la.max(mx, w)
    }
    p.aabb_min, p.aabb_max = mn, mx
    p.model = u32(model)
    p.tint = tint
    f.parts[f.n_parts] = p
    f.n_parts += 1
    e := &f.ents[f.n_ents]
    e.aabb_min = la.min(e.aabb_min, mn)
    e.aabb_max = la.max(e.aabb_max, mx)
}
