package main

import "core:math"
import "core:math/rand"
import la "core:math/linalg"

// Felling: unweave a log of a tree (magic.odin) and the whole tree above the
// cut comes down. tree_find walks the logs joined to the cut, none lower
// than it (what's below stays, a stump), and the leaves they hold. That it's
// a tree, not a log wall someone built, is in the leaves, or, bare, in its
// shape: a dead tree is tall on a thin foot. Its voxels leave the world at
// once and become an entity: two voxel models baked from them (wood and
// leaves, ent_model_upload) that topple about a hinge at the cut, away from
// you, quickening as they go, till the crown meets the ground. A moment
// later the tree bursts into motes that fly to you.

FELL_SLOTS      :: len(FELL_MODELS) / 2
FELL_MAX_LOGS   :: 30_000
FELL_MAX_LEAVES :: 80_000
FELL_LEAF_REACH :: 18   // steps through leaves from the tree's own wood
FELL_LINGER     :: f32(0.4) // seconds on the ground before it bursts
FELL_MOTES      :: 150

// The space tree_find searches, around the cut: as wide as the biggest
// tree (TREE_VOXEL_REACH), from a little below the cut (the stump, whose
// leaves aren't ours) to its tallest top.
FIND_R     :: 56
FIND_BELOW :: 12
FIND_H     :: FIND_BELOW + TREE_MAX_HEIGHT + 24

Felled_Tree :: struct {
    active:  bool,
    pivot:   [3]f32, // the hinge: the cut's edge on the side it falls to
    axis:    [3]f32, // it turns about this (level)
    angle, speed, pull: f32, // radians, rad/s; pull: rad/s² per sin(angle)
    down:    f32,    // seconds since it hit the ground (< 0: still falling)
    wood, leaves: Voxel_Model, // model space = world offset from the pivot
    wood_buf, leaf_buf: []u8,  // their voxels' room, kept for the next tree
    wood_tint, leaf_tint: [3]f32,
    leafy:   bool,
    owner:   u8, // who felled it: 0 us, else that player's slot + 1
    probes:  [dynamic][3]f32,    // high voxels (model space) checked against the ground
    spots:   [dynamic]Fell_Spot, // where its motes come from
    drops:   [Block_Type]u32, // what it gives (fewer leaves than it had; saplings)
    taken:   int,             // voxels it took from the world
}

Fell_Spot :: struct { p: [3]f32, block: Block_Type }

// A tree felled, from its feller to the server and on to everyone else.
Msg_Fell :: struct {
    slot: u8,     // who felled it (the server fills it in)
    cut:  [3]i32, // the log cut
    dir:  [3]f32, // the way it falls (level)
}

Felling :: struct {
    trees: [FELL_SLOTS]Felled_Tree,
    next:  int,
}

@(private="file")
Tree_Found :: struct {
    logs, leaves: [dynamic][3]int, // temp
    ok: bool,
}

// The tree whose trunk p is a log of: its logs from p's height up, and with
// `leaves` its leaves too. ok false if it isn't a tree.
@(private="file")
tree_find :: proc(gs: ^Game_State, p: [3]int, leaves: bool) -> (f: Tree_Found) {
    f.logs = make([dynamic][3]int, context.temp_allocator)
    f.leaves = make([dynamic][3]int, context.temp_allocator)
    lo := p - {FIND_R, FIND_BELOW, FIND_R}
    size := [3]int{2 * FIND_R + 1, FIND_H, 2 * FIND_R + 1}
    n := size.x * size.y * size.z
    index :: #force_inline proc(q, lo, size: [3]int) -> int {
        o := q - lo
        if o.x < 0 || o.y < 0 || o.z < 0 || o.x >= size.x || o.y >= size.y || o.z >= size.z { return -1 }
        return o.x + (o.y + o.z * size.y) * size.x
    }
    // What each voxel of the space is to the search: 0 not seen, 1 ours
    // (a log), 2 a log not ours, then 3 + steps from our wood for leaves.
    mark := make([]u8, n, context.temp_allocator)
    voxel :: #force_inline proc(gs: ^Game_State, q: [3]int) -> u8 { return u8(get_voxel(gs, q.x, q.y, q.z)) }

    if !block_is_log(voxel(gs, p)) { return }
    mark[index(p, lo, size)] = 1
    append(&f.logs, p)
    touching_leaves := 0
    for i := 0; i < len(f.logs); i += 1 {
        q := f.logs[i]
        for dz in -1 ..= 1 { for dy in -1 ..= 1 { for dx in -1 ..= 1 {
            r := q + {dx, dy, dz}
            if r.y < p.y { continue }
            k := index(r, lo, size)
            if k < 0 || mark[k] != 0 { continue }
            v := voxel(gs, r)
            if block_is_leaves(v) {
                if abs(dx) + abs(dy) + abs(dz) == 1 { touching_leaves += 1 }
                continue
            }
            if !block_is_log(v) { continue }
            mark[k] = 1
            append(&f.logs, r)
            if len(f.logs) > FELL_MAX_LOGS { return } // a log house, not a tree
        } } }
    }
    if touching_leaves < 6 {
        // Bare: a dead tree, tall on a thin foot, standing on the ground (or
        // its own stump).
        hi_y, foot := p.y, 0
        for q in f.logs {
            hi_y = max(hi_y, q.y)
            if q.y == p.y { foot += 1 }
        }
        under := Block_Type(voxel(gs, p - {0, 1, 0}))
        ground := block_is_log(u8(under)) || under == .Grass || under == .Dirt || under == .Dry_Grass || under == .Snow ||
                  under == .Sand || under == .Red_Sand || under == .Moss || under == .Gravel
        if hi_y - p.y < 4 || foot > 9 || !ground { return }
    }
    f.ok = true
    if !leaves { return }

    // Leaves within reach of our wood, through leaves. The logs of other
    // trees met on the way (and the stump) hold leaves too: a leaf nearer
    // one of those is theirs.
    others := make([dynamic][3]int, context.temp_allocator)
    queue := make([dynamic][3]int, context.temp_allocator)
    for q in f.logs { append(&queue, q) }
    for i := 0; i < len(queue); i += 1 {
        q := queue[i]
        kq := index(q, lo, size)
        steps := mark[kq] == 1 ? 0 : int(mark[kq]) - 3
        if steps >= FELL_LEAF_REACH { continue }
        for dz in -1 ..= 1 { for dy in -1 ..= 1 { for dx in -1 ..= 1 {
            r := q + {dx, dy, dz}
            k := index(r, lo, size)
            if k < 0 || mark[k] != 0 { continue }
            v := voxel(gs, r)
            if block_is_log(v) {
                mark[k] = 2
                append(&others, r)
            } else if block_is_leaves(v) && len(f.leaves) < FELL_MAX_LEAVES {
                mark[k] = u8(3 + steps + 1)
                append(&f.leaves, r)
                append(&queue, r)
            }
        } } }
    }
    if len(others) == 0 || len(f.leaves) == 0 { return }
    // From the other trees' wood through the same leaves: those they reach
    // first stay.
    theirs := make([]u8, n, context.temp_allocator)
    clear(&queue)
    for q in others {
        theirs[index(q, lo, size)] = 1
        append(&queue, q)
    }
    for i := 0; i < len(queue); i += 1 {
        q := queue[i]
        steps := int(theirs[index(q, lo, size)]) - 1
        for dz in -1 ..= 1 { for dy in -1 ..= 1 { for dx in -1 ..= 1 {
            r := q + {dx, dy, dz}
            k := index(r, lo, size)
            if k < 0 || mark[k] < 3 || theirs[k] != 0 { continue }
            if steps + 1 > int(mark[k]) - 3 { continue } // ours is as near: no further this way
            theirs[k] = u8(steps + 2)
            append(&queue, r)
        } } }
    }
    kept := 0
    for q in f.leaves {
        k := index(q, lo, size)
        if theirs[k] != 0 && int(theirs[k]) - 1 < int(mark[k]) - 3 { continue }
        f.leaves[kept] = q
        kept += 1
    }
    resize(&f.leaves, kept)
    return
}

// How many logs come down if p is cut (0: p isn't a tree's).
felling_trunk_logs :: proc(gs: ^Game_State, p: [3]int) -> int {
    f := tree_find(gs, p, false)
    return f.ok ? len(f.logs) : 0
}

// Seconds of channelling to fell a tree of n logs.
fell_time :: proc(n: int) -> f32 { return min(0.8 + f32(n) / 150, 3) }

// Turns about the unit axis a by th (radians).
@(private="file")
basis_about :: proc(a: [3]f32, th: f32) -> Basis {
    c, s := math.cos(th), math.sin(th)
    turn :: proc(v, a: [3]f32, c, s: f32) -> [3]f32 { return v * c + la.cross(a, v) * s + a * la.dot(a, v) * (1 - c) }
    return basis_from_axes(turn({1, 0, 0}, a, c, s), turn({0, 1, 0}, a, c, s), turn({0, 0, 1}, a, c, s))
}

@(private="file")
fell_basis :: proc(t: ^Felled_Tree) -> Basis {
    // Coming to rest: a little bounce back off the ground.
    back := t.down >= 0 && t.down < 0.3 ? 0.05 * math.sin(t.down / 0.3 * math.PI) : 0
    return basis_about(t.axis, t.angle - back)
}

// Fell the tree p is a log of. False if it isn't one (or building is off).
felling_start :: proc(gs: ^Game_State, p: [3]int) -> bool {
    if !client_may_build(gs) { return false }
    found := tree_find(gs, p, true)
    if !found.ok { return false }
    // It falls away from you.
    dir := block_center(p) - gs.camera.pos
    dir.y = 0
    dir = la.normalize0(dir)
    if dir == 0 { dir = {1, 0, 0} }
    // The others see it come down too (and the server lets its voxels go,
    // out of reach as they may be: items.odin); then they go.
    client_send(gs, .Fell, Msg_Fell{cut = {i32(p.x), i32(p.y), i32(p.z)}, dir = dir})
    fell_begin(gs, found, p, dir, 0)
    all := make([dynamic][3]int, 0, len(found.logs) + len(found.leaves), context.temp_allocator)
    append(&all, ..found.logs[:])
    append(&all, ..found.leaves[:])
    world_clear(gs, all[:])
    return true
}

// Another player felled a tree (Msg_Fell): it comes down here too, from our
// copy of the world, which is theirs (its voxels go with the Voxels that
// follow), and bursts into motes that fly to them.
felling_heard :: proc(gs: ^Game_State, m: Msg_Fell) {
    p := la.array_cast(m.cut, int)
    found := tree_find(gs, p, true)
    if !found.ok { return }
    fell_begin(gs, found, p, m.dir, m.slot + 1)
}

// The found tree, cut at p, as an entity falling toward dir. owner: 0 ours,
// else the felling player's slot + 1 (its motes go to them).
@(private="file")
fell_begin :: proc(gs: ^Game_State, found: Tree_Found, p: [3]int, dir: [3]f32, owner: u8) {
    fl := &gs.felling
    slot := -1
    for t, i in fl.trees { if !t.active { slot = i; break } }
    if slot < 0 {
        slot = fl.next
        fl.next = (fl.next + 1) % FELL_SLOTS
        fell_burst(gs, &fl.trees[slot])
    }
    t := &fl.trees[slot]
    t.owner = owner

    // Hinged at the cut's far edge.
    foot: [2]f32
    n_foot := 0
    for q in found.logs {
        if q.y != p.y { continue }
        foot += {f32(q.x), f32(q.z)} + 0.5
        n_foot += 1
    }
    foot /= f32(n_foot)
    radius := math.sqrt(f32(n_foot) / math.PI)
    pivot := [3]f32{foot.x, f32(p.y), foot.y} + dir * radius

    // The models' box: the tree's, no bigger than their room (around the trunk).
    bb_lo, bb_hi := p, p
    for q in found.logs { bb_lo, bb_hi = la.min(bb_lo, q), la.max(bb_hi, q) }
    for q in found.leaves { bb_lo, bb_hi = la.min(bb_lo, q), la.max(bb_hi, q) }
    centre := [3]int{int(math.floor(foot.x)), p.y, int(math.floor(foot.y))}
    room := FELL_DIMS
    lo := la.max(bb_lo, centre - {room.x / 2, 0, room.z / 2})
    lo.y = p.y
    hi := la.min(bb_hi, lo + room - 1)
    dims: [3]int
    for a in 0 ..< 3 { dims[a] = min((hi[a] - lo[a] + 1 + 3) &~ 3, room[a]) }

    if t.wood_buf == nil {
        t.wood_buf = make([]u8, room.x * room.y * room.z)
        t.leaf_buf = make([]u8, room.x * room.y * room.z)
    }
    cells := dims.x * dims.y * dims.z
    model_lo := la.array_cast(lo, f32) - pivot
    t.wood = {dims = dims, voxel = 1, lo = model_lo, data = t.wood_buf[:cells]}
    t.leaves = {dims = dims, voxel = 1, lo = model_lo, data = t.leaf_buf[:cells]}
    for &b in t.wood.data { b = 0 }
    for &b in t.leaves.data { b = 0 }
    t.drops = {}
    clear(&t.probes)
    clear(&t.spots)
    kinds: [Block_Type]int
    height_sum: f32
    top := f32(0)
    for q in found.logs { top = max(top, f32(q.y - p.y)) }
    for q in found.leaves { top = max(top, f32(q.y - p.y)) }
    seen := 0
    place :: proc(m: ^Voxel_Model, q, lo: [3]int, pal: Pal) {
        o := q - lo
        if o.x < 0 || o.y < 0 || o.z < 0 || o.x >= m.dims.x || o.y >= m.dims.y || o.z >= m.dims.z { return }
        m.data[o.x + m.dims.x * (o.y + m.dims.y * o.z)] = u8(pal)
    }
    note :: proc(t: ^Felled_Tree, q: [3]int, b: Block_Type, pivot: [3]f32, top: f32, seen: ^int, p_y: int) {
        // Reservoir samples: the motes' spots, and the probes (the upper
        // part of the tree: what meets the ground).
        seen^ += 1
        local := block_center(q) - pivot
        if len(t.spots) < FELL_MOTES * 2 {
            append(&t.spots, Fell_Spot{local, b})
        } else if k := rand.int_max(seen^); k < len(t.spots) {
            t.spots[k] = {local, b}
        }
        if f32(q.y - p_y) > top * 0.45 {
            if len(t.probes) < 160 {
                append(&t.probes, local)
            } else if k := rand.int_max(seen^); k < len(t.probes) {
                t.probes[k] = local
            }
        }
    }
    // What it gives, counted as the server will (item_change).
    drop :: proc(t: ^Felled_Tree, v: u8, q: [3]int) {
        gain, extra, _ := item_change(v, 0, q, true)
        t.drops[gain] += 1
        t.drops[extra] += 1
        t.drops[.Air] = 0
    }
    t.taken = len(found.logs) + len(found.leaves)
    for q in found.logs {
        b := Block_Type(u8(get_voxel(gs, q.x, q.y, q.z)))
        kinds[b] += 1
        drop(t, u8(b), q)
        height_sum += f32(q.y - p.y) + 0.5
        place(&t.wood, q, lo, rand.float32() < 0.3 ? .Fell_Dark : .Fell)
        note(t, q, b, pivot, top, &seen, p.y)
    }
    for q in found.leaves {
        b := Block_Type(u8(get_voxel(gs, q.x, q.y, q.z)))
        kinds[b] += 1
        drop(t, u8(b), q)
        height_sum += f32(q.y - p.y) + 0.5
        place(&t.leaves, q, lo, rand.float32() < 0.45 ? .Fell_Dark : .Fell)
        note(t, q, b, pivot, top, &seen, p.y)
    }
    // Tinted as the commonest wood and leaves in it.
    best_log, best_leaf := Block_Type.Log, Block_Type.Leaves
    for n, b in kinds {
        if block_is_log(u8(b)) && n > kinds[best_log] { best_log = b }
        if block_is_leaves(u8(b)) && n > kinds[best_leaf] { best_leaf = b }
    }
    t.wood_tint, t.leaf_tint = block_color(best_log) * 1.6, block_color(best_leaf) * 1.5 // flat colour reads darker than the textured blocks
    models := FELL_MODELS
    ent_model_upload(gs, models[2 * slot], t.wood)
    ent_model_upload(gs, models[2 * slot + 1], t.leaves)

    // A rod hinged at its foot: angular acceleration 3g/2L sin(angle), L
    // twice the height of its middle.
    mid := height_sum / f32(len(found.logs) + len(found.leaves))
    t.pull = clamp(0.75 * GRAVITY / max(mid, 1), 0.8, 8)
    t.pivot, t.axis = pivot, la.normalize(la.cross([3]f32{0, 1, 0}, dir))
    t.angle, t.speed, t.down = 0, 0.12, -1
    t.active, t.leafy = true, len(found.leaves) > 0
    c := pivot + {0, 2, 0}
    play_at(.Tree_Creak, c, 0.9, vary(0.08), 24)
    sparks_burst(gs, block_center(p), MAGIC_TINT, 16, 6)
}

// Falling trees, every frame.
felling_update :: proc(gs: ^Game_State, dt: f32) {
    if dt <= 0 { return }
    for &t in gs.felling.trees {
        if !t.active { continue }
        if t.down < 0 {
            // A push from the cut gets it going; then its weight takes it.
            t.speed += (t.pull * math.sin(t.angle) + 0.3) * dt
            t.angle += t.speed * dt
            if t.angle > 0.25 && (fell_touches(gs, &t) || t.angle > 2.3) {
                t.down = 0
                rot := fell_basis(&t)
                at := t.pivot
                if len(t.probes) > 0 { at = t.pivot + rot * t.probes[0] }
                play_at(.Tree_Fall, at, 1, vary(0.08), 40)
                // Dust and leaves thrown up along where it landed.
                for k in 0 ..< min(len(t.probes), 40) {
                    q := t.pivot + rot * t.probes[k]
                    add_goo(&gs.fx, {pos = q, vel = {rand.float32_range(-4, 4), rand.float32_range(3, 8), rand.float32_range(-4, 4)},
                        life = 0.7, max = 0.7, size = rand.float32_range(0.12, 0.25), color = k % 2 == 0 ? t.leaf_tint * 2 : {0.5, 0.45, 0.38}, floor = q.y - 4})
                }
            }
        } else {
            t.down += dt
            if t.down >= FELL_LINGER { fell_burst(gs, &t) }
        }
    }
}

// Whether the falling tree's upper part has met the ground (or a trunk: it
// crashes through other trees' leaves).
@(private="file")
fell_touches :: proc(gs: ^Game_State, t: ^Felled_Tree) -> bool {
    rot := fell_basis(t)
    for q in t.probes {
        w := t.pivot + rot * q
        v := u8(get_voxel(gs, int(math.floor(w.x)), int(math.floor(w.y)), int(math.floor(w.z))))
        if block_solid(v) && !block_is_leaves(v) { return true }
    }
    return false
}

// The tree comes apart: everything it was flies to you as motes.
@(private="file")
fell_burst :: proc(gs: ^Game_State, t: ^Felled_Tree) {
    if !t.active { return }
    t.active = false
    rot := fell_basis(t)
    // Each kind of block's count shared among the spots of that kind (a kind
    // the samples missed comes from the hinge).
    n := min(len(t.spots), FELL_MOTES)
    spots_of, given: [Block_Type]u32
    for s in t.spots[:n] { spots_of[s.block] += 1 }
    left := t.drops
    for s, i in t.spots[:n] {
        given[s.block] += 1
        count := t.drops[s.block] / spots_of[s.block]
        if given[s.block] == spots_of[s.block] { count = left[s.block] } // the last of its kind takes the rest
        left[s.block] -= count
        w := t.pivot + rot * s.p
        mote_add(gs, {pos = w, vel = la.normalize0([3]f32{rand.float32_range(-1, 1), rand.float32_range(0.2, 1), rand.float32_range(-1, 1)}) * rand.float32_range(3, 8),
            age = -rand.float32_range(0, 0.7), block = s.block, count = t.owner == 0 ? count : 0, home = t.owner,
            tint = mote_tint(s.block), size = count > 0 ? 0.9 : 0.5})
        if i % 4 == 0 {
            add_goo(&gs.fx, {pos = w, vel = {rand.float32_range(-5, 5), rand.float32_range(2, 7), rand.float32_range(-5, 5)},
                life = 0.6, max = 0.6, size = rand.float32_range(0.12, 0.22), color = block_color(s.block) * 1.5, floor = w.y - 4})
        }
    }
    for c, b in left {
        if c > 0 && b != .Air && t.owner == 0 { mote_add(gs, {pos = t.pivot + {0, 1, 0}, vel = {0, 4, 0}, block = b, count = c, tint = mote_tint(b), size = 0.9}) }
    }
    c := t.pivot + rot * [3]f32{0, 6, 0}
    sparks_burst(gs, c, MAGIC_TINT, 24, 8)
    play_at(.Magic_Break, c, 0.9, 0.7, 30)
}

felling_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    models := FELL_MODELS
    for &t, i in gs.felling.trees {
        if !t.active || !ent_begin(f) { continue }
        rot := fell_basis(&t)
        ent_part(f, models[2 * i], t.pivot, rot, {1, 1, 1}, t.wood_tint)
        if t.leafy { ent_part(f, models[2 * i + 1], t.pivot, rot, {1, 1, 1}, t.leaf_tint) }
        ent_end(f)
    }
}
