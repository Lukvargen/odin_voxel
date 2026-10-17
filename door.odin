package main

import la "core:math/linalg"

// Doors, as in Minecraft: a thin panel that right click swings open and
// shut, 2 m tall: DOOR_PARTS blocks at 1.5 blocks a metre (scale.odin). A
// voxel is one byte, so each state of each part is its own block id:
//   Block_Type.Door + ((facing * 2 + hinge_right) * 2 + open) * DOOR_PARTS + part
//   facing: the way whoever placed it was looking (DOOR_DIRS). Closed, the
//           panel lies against the side of the block toward them, and it
//           opens away from them, turning about the hinge corner.
//   hinge:  left or right of the facing. Two doors side by side with their
//           hinges on the outer sides make a double door; they open together.
//   part:   0 at the bottom.
// The shaders decode the ids the same way (voxel_common.hlsl, door_shape).
// Light passes doors (the panel's own voxel holds the light it's lit by);
// closed they're walls to monsters, open a way through (block_solid).

DOOR_PARTS :: 3
DOOR_FIRST :: u8(Block_Type.Door)
DOOR_LAST  :: DOOR_FIRST + 4 * 2 * 2 * DOOR_PARTS - 1
DOOR_THICK :: f32(3.0 / 16.0) // the panel, in blocks
DOOR_DIRS  :: [4][2]int{{0, -1}, {1, 0}, {0, 1}, {-1, 0}} // facing -> x, z
DOOR_REACH :: f32(6) // design blocks: doors aren't opened from across the valley

#assert(BLOCK_IDS == int(DOOR_LAST) + 1)
#assert(len(Block_Type) == int(Block_Type.Door) + 1) // the inventory lists ids up to Door

Door :: struct {
    facing: int,
    right:  bool, // hinge on the right of the facing
    open:   bool,
    part:   int,  // 0 at the bottom
}

block_is_door :: #force_inline proc(b: u8) -> bool { return b >= DOOR_FIRST && b <= DOOR_LAST }
door_is_open  :: #force_inline proc(b: u8) -> bool { return block_is_door(b) && (b - DOOR_FIRST) / DOOR_PARTS & 1 != 0 }

door_decode :: proc(b: u8) -> Door {
    k := int(b - DOOR_FIRST)
    s := k / DOOR_PARTS
    return {s >> 2, s & 2 != 0, s & 1 != 0, k % DOOR_PARTS}
}

door_encode :: proc(d: Door) -> u8 {
    s := (d.facing & 3) << 2 | (d.right ? 2 : 0) | (d.open ? 1 : 0)
    return DOOR_FIRST + u8(s * DOOR_PARTS + d.part)
}

// Whether b is a opened or shut a, and nothing else changed.
door_swung :: proc(a, b: u8) -> bool {
    if !block_is_door(a) || !block_is_door(b) { return false }
    da, db := door_decode(a), door_decode(b)
    db.open = !db.open
    return da == db
}

// Right of facing f, as camera_flat_right is of the view.
@(private="file")
door_right :: proc(f: int) -> [2]int {
    dirs := DOOR_DIRS
    d := dirs[f & 3]
    return {-d.y, d.x}
}

// The side of its block the panel lies against (x, z): toward the placer
// closed, on the hinge side open.
door_side :: proc(d: Door) -> [2]int {
    dirs := DOOR_DIRS
    if !d.open { return -dirs[d.facing] }
    r := door_right(d.facing)
    return d.right ? r : -r
}

// The panel's box within its voxel, 0..1.
door_box :: proc(b: u8) -> (lo, hi: [3]f32) {
    s := door_side(door_decode(b))
    lo, hi = {0, 0, 0}, {1, 1, 1}
    for a in 0 ..< 2 {
        i := a * 2 // x, then z
        if s[a] > 0 { lo[i] = 1 - DOOR_THICK }
        if s[a] < 0 { hi[i] = DOOR_THICK }
    }
    return
}

// Where a ray from q0 (relative to the door voxel's min corner) meets the
// panel, if it does before `span`: the distance and the face's normal.
door_ray :: proc(b: u8, q0, dir: [3]f32, span: f32) -> (t: f32, n: [3]int, ok: bool) {
    lo, hi := door_box(b)
    t0, t1 := f32(0), span
    for i in 0 ..< 3 {
        if abs(dir[i]) < 1e-8 {
            if q0[i] < lo[i] || q0[i] > hi[i] { return }
            continue
        }
        a, c := (lo[i] - q0[i]) / dir[i], (hi[i] - q0[i]) / dir[i]
        if a > c { a, c = c, a }
        if a > t0 {
            t0 = a
            n = {}
            n[i] = dir[i] > 0 ? -1 : 1
        }
        t1 = min(t1, c)
        if t0 > t1 { return }
    }
    return t0, n, true
}

// Whether the box [lo, hi] (world) overlaps the panel of door b at voxel v.
door_overlaps :: proc(b: u8, v: [3]int, lo, hi: [3]f32) -> bool {
    plo, phi := door_box(b)
    o := [3]f32{f32(v.x), f32(v.y), f32(v.z)}
    plo, phi = plo + o, phi + o
    return lo.x < phi.x && hi.x > plo.x && lo.y < phi.y && hi.y > plo.y && lo.z < phi.z && hi.z > plo.z
}

// The whole door that p is part of: its bottom voxel and its state. Not ok
// if p isn't a door, or any of its parts is missing.
door_at :: proc(w: ^World, p: [3]int) -> (base: [3]int, d: Door, ok: bool) {
    b := u8(get_voxel(w, p.x, p.y, p.z))
    if !block_is_door(b) { return }
    d = door_decode(b)
    base = p - {0, d.part, 0}
    for k in 0 ..< DOOR_PARTS {
        q := base + {0, k, 0}
        pb := u8(get_voxel(w, q.x, q.y, q.z))
        want := d
        want.part = k
        if pb != door_encode(want) { return }
    }
    d.part = 0
    return base, d, true
}

// The door d's parts from base up, into pos / blocks at n.
@(private="file")
door_parts :: proc(pos: [][3]int, blocks: []u8, n: ^int, base: [3]int, d: Door) {
    for k in 0 ..< DOOR_PARTS {
        p := d
        p.part = k
        pos[n^], blocks[n^] = base + {0, k, 0}, door_encode(p)
        n^ += 1
    }
}

// Right click on the door at p: it and the other door of a double door
// swing open or shut. True if there was a door to open.
door_toggle :: proc(gs: ^Game_State, p: [3]int) -> bool {
    base, d, ok := door_at(gs, p)
    if !ok { return false }
    pos:    [2 * DOOR_PARTS][3]int
    blocks: [2 * DOOR_PARTS]u8
    n := 0
    sw := d
    sw.open = !d.open
    door_parts(pos[:], blocks[:], &n, base, sw)
    // Its pair: beside it on the side away from the hinge, facing the same
    // way, hinged the other way, open or shut the same.
    r := door_right(d.facing)
    away := d.right ? -r : r
    pb := base + {away.x, 0, away.y}
    if pbase, pd, pok := door_at(gs, pb); pok && pbase == pb && pd.facing == d.facing && pd.right != d.right && pd.open == d.open {
        pd.open = !pd.open
        door_parts(pos[:], blocks[:], &n, pb, pd)
    }
    build_set(gs, pos[:n], blocks[:n], undo = false)
    audio_door(base, sw.open)
    return true
}

// Places a door on the face the crosshair hit (hit + nrm), facing the way
// the player looks. Needs DOOR_PARTS blocks of room on solid ground.
door_place :: proc(gs: ^Game_State, hit, nrm: [3]int) {
    if !client_may_build(gs) {
        ui_toast(gs, "The host has turned off building for visitors", 1.5)
        return
    }
    base := hit
    if !block_is_land_plant(u8(get_voxel(gs, hit.x, hit.y, hit.z))) { base = hit + nrm }
    if !solid_at(gs, base.x, base.y - 1, base.z) || base.y + DOOR_PARTS > WORLD_Y_MAX { return }
    for k in 0 ..< DOOR_PARTS {
        v := base + {0, k, 0}
        b := u8(get_voxel(gs, v.x, v.y, v.z))
        if !(b == 0 || block_is_land_plant(b)) || aabb_hits_voxel(gs.camera.pos, v) { return }
    }

    fwd := camera_flat_forward(gs.camera)
    facing := abs(fwd.x) > abs(fwd.z) ? (fwd.x > 0 ? 1 : 3) : (fwd.z > 0 ? 2 : 0)
    d := Door{facing = facing}
    d.right = door_hinge(gs, base, facing)
    pos:    [DOOR_PARTS][3]int
    blocks: [DOOR_PARTS]u8
    n := 0
    door_parts(pos[:], blocks[:], &n, base, d)
    if build_set(gs, pos[:], blocks[:], undo = true) > 0 {
        audio_edit(base, .Door, .Air, 0)
    }
}

// Which side a new door at base hinges on: mirrored to a door beside it (a
// double door), else toward the wall it's set in (the side with more solid
// blocks), else the half of the block the crosshair is on.
@(private="file")
door_hinge :: proc(gs: ^Game_State, base: [3]int, facing: int) -> bool {
    r := door_right(facing)
    rv := [3]int{r.x, 0, r.y}
    if _, d, ok := door_at(gs, base - rv); ok && d.facing == facing && !d.right { return true }
    if _, d, ok := door_at(gs, base + rv); ok && d.facing == facing && d.right { return false }
    solid :: proc(gs: ^Game_State, v: [3]int) -> (n: int) {
        for k in 0 ..< DOOR_PARTS { n += int(solid_at(gs, v.x, v.y + k, v.z)) }
        return
    }
    left, right := solid(gs, base - rv), solid(gs, base + rv)
    if left != right { return right > left }
    // The crosshair's side of the door's middle.
    eye, dir := camera_aim_eye(gs.camera), camera_forward(gs.camera)
    centre := [3]f32{f32(base.x) + 0.5, f32(base.y) + 0.5, f32(base.z) + 0.5}
    along := la.dot(eye + dir * la.length(centre - eye) - centre, [3]f32{f32(r.x), 0, f32(r.y)})
    return along > 0
}

// After voxels changed: what's left of a door missing a part goes too, and
// so does a door whose ground went. Appends what to clear to `out`.
door_orphans :: proc(gs: ^Game_State, changed: [][3]int, out: ^[dynamic][3]int) {
    for p in changed {
        for dy in -DOOR_PARTS + 1 ..= DOOR_PARTS {
            q := p + {0, dy, 0}
            if !block_is_door(u8(get_voxel(gs, q.x, q.y, q.z))) { continue }
            base, _, whole := door_at(gs, q)
            if whole && solid_at(gs, base.x, base.y - 1, base.z) { continue }
            append(out, q)
        }
    }
}

// The door the crosshair is on, if right click should swing it.
door_aimed :: proc(gs: ^Game_State) -> (p: [3]int, ok: bool) {
    hit, _, hok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), DOOR_REACH * world_scale, plants = true)
    if !hok || !block_is_door(u8(get_voxel(gs, hit.x, hit.y, hit.z))) { return }
    return hit, true
}
