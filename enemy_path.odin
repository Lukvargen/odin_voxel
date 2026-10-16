package main

import "core:math"
import la "core:math/linalg"

// How enemies get about: short-range A* over standing spots (a column of
// air tall enough for the enemy on top of a solid block), so they walk
// around walls, up stairs a block at a time, and down drops of a few
// blocks, instead of pressing into whatever is in the way. And what they
// can see: a ray from their eyes to the player's, through which leaves and
// walls hide you.

PATH_MAX        :: 48   // waypoints kept
PATH_EXPAND_MAX :: 700  // search effort per path
PATH_RADIUS     :: 30   // the search stays this close to the enemy
PATH_STEP_UP    :: 1
PATH_DROP       :: 3
PATHS_PER_FRAME :: 2    // all enemies together

@(private="file")
Path_Node :: struct {
    p:      [3]i32,
    g, f:   f32,
    parent: i32,
    closed: bool,
}

// Can something `clear` blocks tall stand with its feet in voxel (x, y, z)?
@(private="file")
standable :: proc(w: ^World, x, y, z, clear: int) -> bool {
    if !solid_at(w, x, y - 1, z) { return false }
    for k in 0 ..< clear { if solid_at(w, x, y + k, z) { return false } }
    return true
}

// The standing spot in column (x, z) reachable from feet height y: the same
// level, one up, or a few down.
@(private="file")
stand_from :: proc(w: ^World, x, z, y, clear: int) -> (int, bool) {
    if standable(w, x, y, z, clear) { return y, true }
    // Up a step needs head room above where it stands now.
    if standable(w, x, y + PATH_STEP_UP, z, clear) { return y + PATH_STEP_UP, true }
    // Over an edge: open at this height, then down to the first floor.
    for k in 0 ..< clear { if solid_at(w, x, y + k, z) { return 0, false } }
    for d in 1 ..= PATH_DROP {
        if standable(w, x, y - d, z, clear) { return y - d, true }
    }
    return 0, false
}

// Waypoints (feet voxels) from `from` toward `to`, written to out; the
// count, and whether it reaches the goal (else it ends at the reachable
// spot nearest to it).
find_path :: proc(w: ^World, from, to: [3]int, clear: int, out: ^[PATH_MAX][3]i32) -> (n: int, reached: bool) {
    nodes := make([dynamic]Path_Node, 0, 256, context.temp_allocator)
    index := make(map[[2]i32]i32, 256, context.temp_allocator)
    heap := make([dynamic]i32, 0, 256, context.temp_allocator)

    h :: proc(p, to: [3]int) -> f32 {
        d := la.array_cast(to - p, f32)
        return math.sqrt(d.x * d.x + d.z * d.z) + abs(d.y) * 0.5
    }
    heap_push :: proc(heap: ^[dynamic]i32, nodes: []Path_Node, i: i32) {
        append(heap, i)
        k := len(heap) - 1
        for k > 0 {
            parent := (k - 1) / 2
            if nodes[heap[parent]].f <= nodes[heap[k]].f { break }
            heap[parent], heap[k] = heap[k], heap[parent]
            k = parent
        }
    }
    heap_pop :: proc(heap: ^[dynamic]i32, nodes: []Path_Node) -> i32 {
        top := heap[0]
        last := pop(heap)
        if len(heap) > 0 {
            heap[0] = last
            k := 0
            for {
                l, r := 2 * k + 1, 2 * k + 2
                m := k
                if l < len(heap) && nodes[heap[l]].f < nodes[heap[m]].f { m = l }
                if r < len(heap) && nodes[heap[r]].f < nodes[heap[m]].f { m = r }
                if m == k { break }
                heap[m], heap[k] = heap[k], heap[m]
                k = m
            }
        }
        return top
    }

    start := [3]i32{i32(from.x), i32(from.y), i32(from.z)}
    append(&nodes, Path_Node{p = start, g = 0, f = h(from, to), parent = -1})
    index[start.xz] = 0
    heap_push(&heap, nodes[:], 0)
    best, best_h := i32(0), h(from, to)
    goal := i32(-1)

    DIRS :: [8][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
    expanded := 0
    for len(heap) > 0 && expanded < PATH_EXPAND_MAX {
        ci := heap_pop(&heap, nodes[:])
        if nodes[ci].closed { continue }
        nodes[ci].closed = true
        expanded += 1
        cp := la.array_cast(nodes[ci].p, int)
        if hc := h(cp, to); hc < best_h { best, best_h = ci, hc }
        if abs(cp.x - to.x) <= 1 && abs(cp.z - to.z) <= 1 && abs(cp.y - to.y) <= 2 { goal = ci; break }
        for d, di in DIRS {
            nx, nz := cp.x + d.x, cp.z + d.y
            if abs(nx - from.x) > PATH_RADIUS || abs(nz - from.z) > PATH_RADIUS { continue }
            ny, ok := stand_from(w, nx, nz, cp.y, clear)
            if !ok { continue }
            if di >= 4 {
                // Diagonals only where both sides are open: no corner cutting.
                _, ok1 := stand_from(w, cp.x + d.x, cp.z, cp.y, clear)
                _, ok2 := stand_from(w, cp.x, cp.z + d.y, cp.y, clear)
                if !ok1 || !ok2 { continue }
            }
            cost: f32 = di >= 4 ? 1.414 : 1
            if ny > cp.y { cost += 0.6 }
            if get_voxel(w, nx, ny, nz) == u32(Block_Type.Water) { cost += 3 }
            g := nodes[ci].g + cost
            key := [2]i32{i32(nx), i32(nz)}
            if ni, seen := index[key]; seen {
                if nodes[ni].closed || g >= nodes[ni].g { continue }
                nodes[ni].g, nodes[ni].parent = g, ci
                nodes[ni].p.y = i32(ny)
                nodes[ni].f = g + h({nx, ny, nz}, to)
                heap_push(&heap, nodes[:], ni)
            } else {
                append(&nodes, Path_Node{p = {i32(nx), i32(ny), i32(nz)}, g = g, f = g + h({nx, ny, nz}, to), parent = ci})
                ni := i32(len(nodes) - 1)
                index[key] = ni
                heap_push(&heap, nodes[:], ni)
            }
        }
    }
    end := goal >= 0 ? goal : best
    // Walk back from the end, then keep the first PATH_MAX steps.
    chain := make([dynamic][3]i32, 0, 64, context.temp_allocator)
    for i := end; i >= 0; i = nodes[i].parent { append(&chain, nodes[i].p) }
    for k := len(chain) - 2; k >= 0 && n < PATH_MAX; k -= 1 { // skip the start node
        out[n] = chain[k]
        n += 1
    }
    return n, goal >= 0
}

// A clear line from the enemy's eyes to its prey's head or chest.
enemy_sees_player :: proc(sim: ^Sim, e: ^Enemy) -> bool {
    eye := e.pos + {0, ENEMY_SPECS[e.kind].height * 0.9, 0}
    head := sim.players[e.prey].pos
    for target in ([2][3]f32{head, head - {0, 0.7, 0}}) {
        d := target - eye
        l := la.length(d)
        if l < 0.5 { return true }
        if l > 64 { return false }
        _, _, hit := raycast_voxel(sim.world, eye, d / l, l - 0.3)
        if !hit { return true }
    }
    return false
}

// Path-following: the point to head for on the way to `goal` (feet). Plans
// a new path now and then (shared budget per frame); straight at the goal
// when close and in plain view.
@(private="file")
paths_left: int

enemy_paths_frame :: proc() { paths_left = PATHS_PER_FRAME }

enemy_steer :: proc(sim: ^Sim, e: ^Enemy, goal: [3]f32, dt: f32) -> [3]f32 {
    sp := ENEMY_SPECS[e.kind]
    e.repath -= dt
    // Stuck: hardly moved for a while while trying to — plan again now.
    if la.length((e.pos - e.stuck_pos).xz) > 0.6 {
        e.stuck_pos, e.stuck_t = e.pos, 0
    } else {
        e.stuck_t += dt
        if e.stuck_t > 1.2 { e.repath, e.stuck_t = 0, 0 }
    }
    to_goal := goal - e.pos
    if la.length(to_goal.xz) < 2.5 && abs(to_goal.y) < 1.2 && e.stuck_t < 0.5 { return goal }
    if e.repath <= 0 && paths_left > 0 {
        paths_left -= 1
        e.repath = 0.6 + 0.3 * f32(e.age - math.floor(e.age)) // spread them out
        clear := int(math.ceil(sp.height * 0.92))
        from := [3]int{int(math.floor(e.pos.x)), int(math.floor(e.pos.y + 0.05)), int(math.floor(e.pos.z))}
        to := [3]int{int(math.floor(goal.x)), int(math.floor(goal.y + 0.05)), int(math.floor(goal.z))}
        e.path_len, _ = find_path(sim.world, from, to, clear, &e.path)
        e.path_i = 0
    }
    // Next waypoint not yet reached.
    for e.path_i < e.path_len {
        w := la.array_cast(e.path[e.path_i], f32) + {0.5, 0, 0.5}
        if la.length((w - e.pos).xz) > 0.45 { return w }
        e.path_i += 1
    }
    return goal
}
