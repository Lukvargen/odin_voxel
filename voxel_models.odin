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
}

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
//   [dyn_base..]              per frame: header (BVH roots), MAX_ENTITIES entity
//                             records, the entity BVHs (2 * MAX_ENTITIES nodes), parts
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

MAX_ENT_PARTS :: 256

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

// Matches the 2-uint4 BVH node: interior nodes have their left child right
// after them and `a` = right child; leaves have `a` = entity index.
Bvh_Node_Gpu :: struct #packed {
    bmin: [3]f32, a:    u32,
    bmax: [3]f32, leaf: u32,
}

ENT_NO_ROOT :: 0xffffffff

Ent_Frame :: struct {
    // Roots of the two BVHs: shadow casters, and entities only seen
    // directly (far birds — shadow rays never walk that tree).
    root_caster, root_view: u32,
    _hdr_pad:   [2]u32,
    ents:   [MAX_ENTITIES]Ent_Gpu,
    nodes:  [2 * MAX_ENTITIES]Bvh_Node_Gpu,
    parts:  [MAX_ENT_PARTS]Part_Gpu,
    n_ents, n_parts, n_nodes: int,
    no_shadow: [MAX_ENTITIES]bool,
}

// BVH over the entity boxes, so a ray far from every entity costs one box
// test instead of one per entity. Rebuilt every frame (<= 64 leaves).
ent_build_bvh :: proc(f: ^Ent_Frame) {
    f.n_nodes = 0
    f.root_caster, f.root_view = ENT_NO_ROOT, ENT_NO_ROOT
    // Casters first, view-only entities after.
    ids: [MAX_ENTITIES]int
    nc := 0
    for i in 0 ..< f.n_ents { if !f.no_shadow[i] { ids[nc] = i; nc += 1 } }
    nv := nc
    for i in 0 ..< f.n_ents { if f.no_shadow[i] { ids[nv] = i; nv += 1 } }
    build :: proc(f: ^Ent_Frame, ids: []int) -> u32 {
        node := f.n_nodes
        f.n_nodes += 1
        mn := [3]f32{1e9, 1e9, 1e9}
        mx := [3]f32{-1e9, -1e9, -1e9}
        for i in ids {
            mn = la.min(mn, f.ents[i].aabb_min)
            mx = la.max(mx, f.ents[i].aabb_max)
        }
        if len(ids) == 1 {
            f.nodes[node] = {bmin = mn, a = u32(ids[0]), bmax = mx, leaf = 1}
            return u32(node)
        }
        // Split at the median centre along the longest axis.
        ext := mx - mn
        axis := ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
        centre :: proc(f: ^Ent_Frame, i, axis: int) -> f32 { return f.ents[i].aabb_min[axis] + f.ents[i].aabb_max[axis] }
        for i in 1 ..< len(ids) {
            for j := i; j > 0 && centre(f, ids[j], axis) < centre(f, ids[j - 1], axis); j -= 1 {
                ids[j], ids[j - 1] = ids[j - 1], ids[j]
            }
        }
        mid := len(ids) / 2
        build(f, ids[:mid]) // left child = node + 1
        right := build(f, ids[mid:])
        f.nodes[node] = {bmin = mn, a = right, bmax = mx, leaf = 0}
        return u32(node)
    }
    if nc > 0 { f.root_caster = build(f, ids[:nc]) }
    if nv > nc { f.root_view = build(f, ids[nc:nv]) }
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

ent_end :: proc(f: ^Ent_Frame) {
    e := &f.ents[f.n_ents]
    e.part_count = u32(f.n_parts) - e.first_part
    if e.part_count > 0 { f.n_ents += 1 }
}

// Add a part to the open entity: the model's origin goes to `pos`, its axes
// rotated by `rot` and scaled per axis by `scale`.
ent_part :: proc(f: ^Ent_Frame, model: Model_Id, pos: [3]f32, rot: Basis, scale: [3]f32 = {1, 1, 1}, tint: [3]f32 = {1, 1, 1}) {
    if f.n_parts >= MAX_ENT_PARTS { return }
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
