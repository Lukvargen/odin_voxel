package main

import "core:fmt"
import "core:math"
import "core:math/noise"
import "core:mem"
import "core:time"

CHUNK_VOXELS :: 8
CHUNKS_W     :: 128   // ring width in chunks (MUST match shader CHUNK_COUNT_WIDTH)
CHUNKS_H     :: 64    // total Y chunks resident in the ring

// Per-brick occupancy bitmask: 8^3 = 512 voxels = 512 bits = 16 u32.
MASK_U32_PER_BRICK :: (CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS) / 32

VOXELS_PER_BRICK :: CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS // 512

// Stage 3 sparse brick pool. gpu_index[slot] is now a POOL ID in
// [0, MAX_RESIDENT_BRICKS) or -1 (air / no storage). The pool id indexes
// gpu_voxels (pool_id*512) and gpu_voxel_mask (pool_id*16). All-air bricks
// consume zero pool blocks. Block = 512 + 64 bytes.
//
// This 64-tall world is mostly solid stone (Y=-256 up to the surface), so the
// resident non-empty set is large. With LOAD_RADIUS_XZ=56 that's ~113x113
// columns * ~45 non-empty Y chunks ≈ 575k bricks worst case. 1<<20 = 1048576
// blocks (~576 MiB GPU + 576 MiB CPU mirror) covers it with margin. A
// uniform-stone sentinel (future) would let this shrink substantially.
MAX_RESIDENT_BRICKS :: 1 << 20

// Free-list allocator: a stack of free pool ids. free_top is the count of
// ids available in free_ids[0:free_top]. alloc = pop, free = push. O(1),
// no fragmentation, deterministic.
Brick_Pool :: struct {
    free_ids: []i32,
    free_top: int,
}

pool_init :: proc(p: ^Brick_Pool) {
    p.free_ids = make([]i32, MAX_RESIDENT_BRICKS)
    for i in 0 ..< MAX_RESIDENT_BRICKS {
        p.free_ids[i] = i32(MAX_RESIDENT_BRICKS - 1 - i) // pop order hands out 0,1,2...
    }
    p.free_top = MAX_RESIDENT_BRICKS
}

// Returns a pool id in [0, MAX_RESIDENT_BRICKS) or -1 if exhausted.
pool_alloc :: proc(p: ^Brick_Pool) -> i32 {
    if p.free_top == 0 { return -1 }
    p.free_top -= 1
    return p.free_ids[p.free_top]
}

// Returns a pool id to the free list. id must have been handed out by
// pool_alloc and not already freed; the caller enforces this by setting
// gpu_index[slot] = -1 immediately after freeing (pool_free(-1) is a no-op).
pool_free :: proc(p: ^Brick_Pool, id: i32) {
    if id < 0 { return }
    p.free_ids[p.free_top] = id
    p.free_top += 1
}

@(private="file")
g_pool_warned: bool
pool_exhaustion_warn :: proc() {
    if !g_pool_warned {
        g_pool_warned = true
        fmt.eprintln("WARNING: brick pool exhausted; bricks rendering as air. Raise MAX_RESIDENT_BRICKS.")
    }
}

// World chunk-Y range. wcy (world chunk Y) is valid in
// [WORLD_CHUNK_Y_MIN, WORLD_CHUNK_Y_MIN + CHUNKS_H). It maps to a ring Y
// index in [0, CHUNKS_H) by subtracting WORLD_CHUNK_Y_MIN. World voxel Y
// thus spans [WORLD_CHUNK_Y_MIN*8, (WORLD_CHUNK_Y_MIN+CHUNKS_H)*8) = [-256, +256).
WORLD_CHUNK_Y_MIN :: -32
WORLD_Y_MIN       :: WORLD_CHUNK_Y_MIN * CHUNK_VOXELS                 // -256
WORLD_Y_MAX       :: (WORLD_CHUNK_Y_MIN + CHUNKS_H) * CHUNK_VOXELS    // +256

Block_Type :: enum u8 {
    Air    = 0,
    Grass  = 1,
    Stone  = 2,
    Log    = 3,
    Leaves = 4,
    Torch  = 5,   // emissive — feeds the point-light list (lights.odin)
}

Chunk :: struct {
    voxels: [CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS]u8,
}

LOAD_RADIUS_XZ  :: 56   // must stay < CHUNKS_W/2 (=64) so a chunk and its ring-twin never coexist
LOAD_RADIUS_Y   :: 7

// Cave band. Below CAVE_FLOOR_Y everything is solid stone via the no-noise
// fast path. Caves are carved by a 3D noise lobe only between CAVE_FLOOR_Y
// and (surface - CAVE_TOP_MARGIN). Keeping the floor shallow (-64 vs the old
// -224) is the dominant generation-cost lever: the proven ~92%-of-fill cave
// 3D-noise now runs over a ~160-voxel band instead of ~320, ~halving it,
// with zero new control flow / streaming risk. Deep digging hits solid stone
// below -64 (acceptable; deeper caves would need on-demand vertical gen).
CAVE_FLOOR_Y    :: -64
CAVE_TOP_MARGIN :: 6            // keep caves this far below the surface
CAVE_THRESHOLD  :: 0.32         // higher = fewer/smaller caves

// The grass/stone speckle 3D-noise only affects the visible surface skin.
// Solid voxels deeper than this below the surface are unconditionally Stone
// (no noise) — they're only ever seen as a cave wall, which reads as stone
// anyway. Cave carving keeps full per-voxel noise (future ores live there).
SURFACE_SKIN :: 6

// Floor division — rounds toward -inf, unlike Odin's / which truncates toward zero.
floor_div :: proc(a, b: int) -> int {
    return a / b - (1 if a % b != 0 && (a ~ b) < 0 else 0)
}

// Maps a world chunk Y to its ring Y index in [0, CHUNKS_H), or -1 if the
// chunk is outside the resident vertical range.
chunk_y_index :: proc(wcy: int) -> int {
    iy := wcy - WORLD_CHUNK_Y_MIN
    if iy < 0 || iy >= CHUNKS_H { return -1 }
    return iy
}

// Returns the GPU ring-buffer slot for a world chunk coordinate. Caller must
// ensure wcy is in range (chunk_y_index >= 0).
ring_slot :: proc(wcx, wcy, wcz: int) -> int {
    sx := ((wcx % CHUNKS_W) + CHUNKS_W) % CHUNKS_W
    sz := ((wcz % CHUNKS_W) + CHUNKS_W) % CHUNKS_W
    iy := wcy - WORLD_CHUNK_Y_MIN
    return sx + iy * CHUNKS_W + sz * CHUNKS_W * CHUNKS_H
}

// Initialise flat CPU/GPU arrays, then block until the visible radius is loaded.
// Chunks are complete (terrain + trees) the moment generate_chunk_at returns,
// so there is no separate tree pass and no cross-chunk bookkeeping.
generate_world :: proc(gs: ^Game_State) {
    t0 := time.now()

    total := CHUNKS_W * CHUNKS_H * CHUNKS_W
    gs.chunk_map       = make(map[[3]int]^Chunk)
    gs.gpu_loaded      = make(map[[3]int]bool)
    // Pool-sized: indexed by pool id, NOT slot.
    gs.gpu_voxels      = make([]u8,  MAX_RESIDENT_BRICKS * VOXELS_PER_BRICK)
    gs.gpu_voxel_mask  = make([]u32, MAX_RESIDENT_BRICKS * MASK_U32_PER_BRICK)
    // Slot-sized: indexed by ring slot.
    gs.gpu_index       = make([]i32,    total)
    gs.gpu_chunk_owner = make([][2]i32, total)

    pool_init(&gs.brick_pool)

    for i in 0 ..< total {
        gs.gpu_index[i]       = -1
        gs.gpu_chunk_owner[i] = {0x7fffffff, 0x7fffffff}
    }

    gs.player_chunk = {
        floor_div(int(gs.camera.pos.x), CHUNK_VOXELS),
        floor_div(int(gs.camera.pos.y), CHUNK_VOXELS),
        floor_div(int(gs.camera.pos.z), CHUNK_VOXELS),
    }
    worker_pool_set_player(&gs.pool, gs.player_chunk[0], gs.player_chunk[2])

    // Block only on a small radius so the window appears fast; the game loop
    // streams the rest of LOAD_RADIUS_XZ in afterward.
    enqueue_radius(gs, STARTUP_RADIUS_XZ)
    for {
        integrate_ready_chunks(gs)
        if worker_pool_idle(&gs.pool) { break }
    }

    elapsed := time.duration_seconds(time.since(t0))
    fmt.printf("World gen (startup radius %d): %.3f s\n", STARTUP_RADIUS_XZ, elapsed)
    profile_dump("startup")
}

// Radius (in chunks) loaded synchronously before the window opens. The full
// LOAD_RADIUS_XZ streams in during gameplay via the per-frame enqueue.
STARTUP_RADIUS_XZ :: 10

// Enqueue all XZ columns within `radius` of the player. The whole vertical
// column (all CHUNKS_H Y chunks) is generated as one job.
enqueue_radius :: proc(gs: ^Game_State, radius: int) {
    pcx := gs.player_chunk[0]
    pcz := gs.player_chunk[2]
    for dcz in -radius ..= radius {
        for dcx in -radius ..= radius {
            wcx := pcx + dcx; wcz := pcz + dcz
            // Skip if the column is already fully loaded (check Y=0 as proxy;
            // columns are integrated atomically so this is sufficient).
            probe := [3]int{wcx, 0, wcz}
            if probe in gs.gpu_loaded { continue }
            worker_pool_enqueue(&gs.pool, [2]int{wcx, wcz})
        }
    }
}

enqueue_chunks :: proc(gs: ^Game_State) {
    enqueue_radius(gs, LOAD_RADIUS_XZ)
}

// Upload a chunk into the GPU ring. Called on main thread after chunk is
// fully built. `empty` and `mask` are precomputed on the worker (see
// Chunk_Result) so this does no per-voxel scanning — only pool bookkeeping
// and two mem.copy.
integrate_chunk :: proc(gs: ^Game_State, key: [3]int, chunk: ^Chunk, empty: bool, mask: ^[MASK_U32_PER_BRICK]u32, gpu_ready: bool) {
    wcx := key[0]; wcy := key[1]; wcz := key[2]
    if key in gs.gpu_loaded { return }

    slot := ring_slot(wcx, wcy, wcz)

    // Eviction: the slot is being reassigned. Drop the old owner, then free
    // any pool id this slot holds EXACTLY ONCE (set to -1 in the same breath
    // so a second free is structurally impossible). Covers implicit
    // eviction-by-owner, same-slot re-integration, and air slots (id == -1).
    old := gs.gpu_chunk_owner[slot]
    if old[0] != 0x7fffffff {
        old_key := [3]int{int(old[0]), wcy, int(old[1])}
        delete_key(&gs.gpu_loaded, old_key)
        worker_pool_unqueue(&gs.pool, [2]int{int(old[0]), int(old[1])})
    }
    old_id := gs.gpu_index[slot]
    if old_id >= 0 {
        pool_free(&gs.brick_pool, old_id)
        gs.gpu_index[slot] = -1
    }

    gs.gpu_loaded[key]       = true
    gs.gpu_chunk_owner[slot] = {i32(wcx), i32(wcz)}

    if empty {
        gs.gpu_index[slot] = -1 // air: zero pool blocks
    } else {
        pid := pool_alloc(&gs.brick_pool)
        if pid < 0 {
            pool_exhaustion_warn()
            gs.gpu_index[slot] = -1 // graceful: render as air, no leak
        } else {
            base      := int(pid) * VOXELS_PER_BRICK
            mask_base := int(pid) * MASK_U32_PER_BRICK
            // Bulk copies — the per-voxel scan/mask build already ran on the
            // worker. mem.copy is SIMD memcpy, ~tens of ns vs the old ~520µs
            // byte loop that was the streaming wall.
            mem.copy(&gs.gpu_voxels[base], &chunk.voxels[0], VOXELS_PER_BRICK)
            mem.copy(&gs.gpu_voxel_mask[mask_base], &mask[0], MASK_U32_PER_BRICK * size_of(u32))
            gs.gpu_index[slot] = pid
        }
    }

    if gpu_ready {
        append(&gs.dirty_slots, slot)
        gs.index_dirty = true
    }
}

// Drain finished columns from the worker pool and integrate them. Each column
// arrives complete (terrain + trees clipped per chunk), so this just uploads.
// Max columns integrated on the main thread per frame. The per-voxel scan +
// mask build now runs on the worker (see Chunk_Result), so a column is just
// 64×(pool alloc + 512B/64B mem.copy + map ops) — roughly an order of
// magnitude cheaper than the old ~520µs. Active flight enqueues ~19 cols/
// frame; 24 keeps the backlog (and the holes-when-moving) from growing while
// staying well under the old ~3 ms/frame integrate cost. Tune from the
// Integrate profile zone if needed.
INTEGRATE_BUDGET_PER_FRAME :: 24

integrate_ready_chunks :: proc(gs: ^Game_State) {
    results := worker_pool_drain_budget(&gs.pool, INTEGRATE_BUDGET_PER_FRAME)
    defer delete(results)
    if len(results) == 0 { return }
    t_int := time.tick_now()
    for &r in results {
        wcx := r.key[0]; wcz := r.key[1]
        probe := [3]int{wcx, 0, wcz}
        if probe in gs.gpu_loaded {
            // Column already present — discard the duplicate.
            for cy in 0 ..< CHUNKS_H { free(r.column[cy]) }
            continue
        }
        for iy in 0 ..< CHUNKS_H {
            wcy := iy + WORLD_CHUNK_Y_MIN
            key := [3]int{wcx, wcy, wcz}
            gs.chunk_map[key] = r.column[iy]
            integrate_chunk(gs, key, r.column[iy], r.empty[iy], &r.mask[iy], true)
        }
    }
    profile_add(.Integrate, t_int)
}

// Generate an entire XZ column: all CHUNKS_H Y chunks at world chunk coord
// (wcx, *, wcz). Terrain noise and the tree scan run once for the whole column
// instead of once per Y chunk — eliminating the 16× redundancy that dominated
// streaming cost.
generate_column_at :: proc(wcx, wcz: int) -> [CHUNKS_H]^Chunk {
    column: [CHUNKS_H]^Chunk
    for cy in 0 ..< CHUNKS_H { column[cy] = new(Chunk) }

    gx := wcx * CHUNK_VOXELS
    gz := wcz * CHUNK_VOXELS

    // Surface height for the 8×8 footprint — computed once, reused for all Y.
    // Track min/max so whole Y-chunks above the surface (all air) or far below
    // it (all solid stone, no caves) can be skipped without a voxel fill.
    t_noise := time.tick_now()
    grass_cache: [CHUNK_VOXELS * CHUNK_VOXELS]f64
    surf_min := f64(1e30)
    surf_max := f64(-1e30)
    for z in 0 ..< CHUNK_VOXELS {
        for x in 0 ..< CHUNK_VOXELS {
            wx := f64(gx + x)
            wz := f64(gz + z)
            n0 := f64(noise.noise_2d(2, {wx / 600.0, wz / 600.0})) * 0.5 + 0.5
            n1 := f64(noise.noise_2d(0, {wx / 280.0, wz / 280.0})) * 0.5 + 0.5
            n2 := f64(noise.noise_2d(1, {wx / 70.0,  wz / 70.0}))  * 0.5 + 0.5
            height := n0 * 0.45 + n1 * n0 * 0.45 + n2 * 0.10
            s := 10.0 + height * 90.0
            grass_cache[x + z * CHUNK_VOXELS] = s
            if s < surf_min { surf_min = s }
            if s > surf_max { surf_max = s }
        }
    }
    profile_add(.Terrain_Noise, t_noise)

    t_fill := time.tick_now()
    for iy in 0 ..< CHUNKS_H {
        chunk := column[iy]
        wcy := iy + WORLD_CHUNK_Y_MIN
        gy  := wcy * CHUNK_VOXELS         // world voxel Y of this chunk's base
        cy0 := f64(gy)
        cy1 := f64(gy + CHUNK_VOXELS)     // exclusive top

        // Fast path 1: chunk entirely above the highest surface → all Air.
        // new(Chunk) already zeroed voxels to Air, so nothing to write.
        if cy0 >= surf_max { continue }

        // Fast path 2: chunk entirely below the cave band → solid Stone fill,
        // no per-voxel noise needed.
        if cy1 <= f64(CAVE_FLOOR_Y) {
            for vi in 0 ..< CHUNK_VOXELS*CHUNK_VOXELS*CHUNK_VOXELS {
                chunk.voxels[vi] = u8(Block_Type.Stone)
            }
            continue
        }

        // Mixed chunk: per-voxel terrain + cave carve.
        for z in 0 ..< CHUNK_VOXELS {
            for y in 0 ..< CHUNK_VOXELS {
                for x in 0 ..< CHUNK_VOXELS {
                    wx := f64(gx + x)
                    wy := f64(gy + y)
                    wz := f64(gz + z)
                    grass_level := grass_cache[x + z * CHUNK_VOXELS]
                    i := x + y * CHUNK_VOXELS + z * CHUNK_VOXELS * CHUNK_VOXELS
                    if wy >= grass_level {
                        chunk.voxels[i] = u8(Block_Type.Air)
                        continue
                    }
                    // Solid. Carve caves with a 3D noise lobe inside the cave
                    // band (deep enough below the surface, above the floor).
                    if wy > f64(CAVE_FLOOR_Y) && wy < grass_level - CAVE_TOP_MARGIN {
                        cave := noise.noise_3d_improve_xy(7, {wx * 0.04, wy * 0.05, wz * 0.04})
                        if cave > CAVE_THRESHOLD {
                            chunk.voxels[i] = u8(Block_Type.Air)
                            continue
                        }
                    }
                    // Deeper than the surface skin: unconditionally Stone, no
                    // noise (only ever seen as a cave wall = stone anyway).
                    if wy < grass_level - SURFACE_SKIN {
                        chunk.voxels[i] = u8(Block_Type.Stone)
                        continue
                    }
                    // Surface skin: grass with the stone-speckle 3D-noise.
                    chunk.voxels[i] = u8(Block_Type.Grass)
                    if noise.noise_3d_improve_xy(0, {wx * 0.05, wy * 0.05, wz * 0.05}) > 0.4 {
                        chunk.voxels[i] = u8(Block_Type.Stone)
                    }
                }
            }
        }
    }
    profile_add(.Terrain_Fill, t_fill)

    // One tree scan for the whole column. Trees write into whichever Y chunk
    // their voxels land in via set_voxel_world.
    tgt := Tree_Target{chunks = column, ox = gx, oz = gz}
    t_scan := time.tick_now()
    for wz in gz - TREE_VOXEL_REACH ..< gz + CHUNK_VOXELS + TREE_VOXEL_REACH {
        for wx in gx - TREE_VOXEL_REACH ..< gx + CHUNK_VOXELS + TREE_VOXEL_REACH {
            if !should_place_tree(wx, wz) { continue }
            surface_y := surface_height_at(wx, wz) - 1 // top solid voxel
            t_gen := time.tick_now()
            generate_tree(&tgt, wx, surface_y + 1, wz, wx * 1000 + wz)
            profile_add(.Tree_Generate, t_gen)
        }
    }
    profile_add(.Tree_Scan, t_scan)
    return column
}

// Tree-band bounds derived from the height formula and tree dimensions.
TREE_MIN_SURFACE_Y :: 10                              // surface_height_at min
TREE_MAX_HEIGHT    :: 60                              // trunk + branch + crown reach
TREE_MAX_TOP_Y     :: 100 + TREE_MAX_HEIGHT           // surface max + tree reach

// Same height formula as generate_chunk_at — pure noise, no chunk lookup needed.
surface_height_at :: proc(wx, wz: int) -> int {
    fwx := f64(wx); fwz := f64(wz)
    n0 := f64(noise.noise_2d(2, {fwx / 600.0, fwz / 600.0})) * 0.5 + 0.5
    n1 := f64(noise.noise_2d(0, {fwx / 280.0, fwz / 280.0})) * 0.5 + 0.5
    n2 := f64(noise.noise_2d(1, {fwx / 70.0,  fwz / 70.0}))  * 0.5 + 0.5
    h  := n0 * 0.45 + n1 * n0 * 0.45 + n2 * 0.10
    return int(10.0 + h * 90.0)
}

// A full XZ column being generated: all CHUNKS_H Y chunks share one tree
// scan. Writes are clipped to the column's 8×(16·8)×8 box. A tree is still
// regenerated by every column it overlaps, so cross-column edges stay seamless
// with no shared state — but within a column the scan runs exactly once.
Tree_Target :: struct {
    chunks:   [CHUNKS_H]^Chunk, // one per Y chunk
    ox, oz:   int,              // world voxel coord of local (0, *, 0)
}

// Max horizontal voxel reach of a tree from its base (trunk wander + branch +
// crown): branch_len 18 + sub_len 10 + crown radius 16 ≈ 44. Round up.
TREE_VOXEL_REACH :: 48

set_voxel_world :: proc(t: ^Tree_Target, wx, wy, wz: int, block: Block_Type) {
    lx := wx - t.ox; lz := wz - t.oz
    if lx < 0 || lx >= CHUNK_VOXELS { return }
    if lz < 0 || lz >= CHUNK_VOXELS { return }
    wcy := floor_div(wy, CHUNK_VOXELS)
    iy  := chunk_y_index(wcy)
    if iy < 0 { return }
    ly := wy - wcy * CHUNK_VOXELS
    t.chunks[iy].voxels[lx + ly*CHUNK_VOXELS + lz*CHUNK_VOXELS*CHUNK_VOXELS] = u8(block)
}

// True if a world-space AABB [lo, hi] (inclusive) overlaps this column's XZ
// footprint. Y is unbounded within the column (all 16 chunks present), so only
// XZ matters for rejecting whole trees/branches/crowns.
@(require_results)
aabb_hits_chunk :: proc(t: ^Tree_Target, lox, loy, loz, hix, hiy, hiz: int) -> bool {
    if hix < t.ox || lox >= t.ox + CHUNK_VOXELS { return false }
    if hiz < t.oz || loz >= t.oz + CHUNK_VOXELS { return false }
    return true
}

// --- Tree generation ---

// Deterministic hash: world position + seed → float in [0, 1).
tree_hash :: proc(x, z, seed: int) -> f64 {
    h := u64(x * 73856093 ~ z * 19349663 ~ seed * 83492791)
    h = h ~ (h >> 30); h *= 0xbf58476d1ce4e5b9
    h = h ~ (h >> 27); h *= 0x94d049bb133111eb
    h = h ~ (h >> 31)
    return f64(h & 0xFFFFFF) / f64(0x1000000)
}

// Place leaves without overwriting logs. Clipped to the column footprint.
place_leaves :: proc(t: ^Tree_Target, wx, wy, wz: int) {
    lx := wx - t.ox; lz := wz - t.oz
    if lx < 0 || lx >= CHUNK_VOXELS { return }
    if lz < 0 || lz >= CHUNK_VOXELS { return }
    wcy := floor_div(wy, CHUNK_VOXELS)
    iy  := chunk_y_index(wcy)
    if iy < 0 { return }
    ly := wy - wcy * CHUNK_VOXELS
    vi := lx + ly*CHUNK_VOXELS + lz*CHUNK_VOXELS*CHUNK_VOXELS
    if t.chunks[iy].voxels[vi] != u8(Block_Type.Log) {
        t.chunks[iy].voxels[vi] = u8(Block_Type.Leaves)
    }
}

// Fill a filled circle of logs at height wy, centred on (cx, cz) with given radius.
// noise_amt adds per-voxel hash-based edge roughness.
fill_trunk_slice :: proc(t: ^Tree_Target, cx, cz: f64, wy: int, radius: f64, seed: int) {
    ir := int(math.ceil(radius)) + 1
    for dz in -ir ..= ir {
        for dx in -ir ..= ir {
            wx := int(math.round(cx)) + dx
            wz := int(math.round(cz)) + dz
            // Wobble the boundary with a per-voxel hash so the edge is ragged.
            wobble := tree_hash(wx, wz, seed) * 1.2 - 0.2
            r2 := f64(dx*dx + dz*dz)
            if r2 <= (radius + wobble) * (radius + wobble) {
                set_voxel_world(t, wx, wy, wz, .Log)
            }
        }
    }
}

// Draw a thick branch as a series of circular slices between two points.
// start_r and end_r are the radius at each endpoint.
draw_thick_segment :: proc(tgt: ^Tree_Target,
    ax, ay, az, bx, by, bz: f64,
    start_r, end_r: f64, seed: int) {
    // Reject the whole segment if its AABB misses this chunk. Pad by the
    // larger radius + wobble slack (fill_trunk_slice adds up to +1.0 wobble
    // and scans ceil(r)+1).
    pad := int(math.ceil(max(start_r, end_r))) + 2
    lox := int(math.floor(min(ax, bx))) - pad
    hix := int(math.ceil (max(ax, bx))) + pad
    loy := int(math.floor(min(ay, by))) - 1
    hiy := int(math.ceil (max(ay, by))) + 1
    loz := int(math.floor(min(az, bz))) - pad
    hiz := int(math.ceil (max(az, bz))) + pad
    if !aabb_hits_chunk(tgt, lox, loy, loz, hix, hiy, hiz) { return }

    dx := bx - ax; dy := by - ay; dz := bz - az
    length := math.sqrt(dx*dx + dy*dy + dz*dz)
    steps := max(int(math.ceil(length * 2)), 1)
    for i in 0 ..= steps {
        ts := f64(i) / f64(steps)
        px := ax + dx*ts; py := ay + dy*ts; pz := az + dz*ts
        r  := start_r + (end_r - start_r) * ts
        // Place a small filled circle perpendicular to the segment direction.
        // For simplicity, fill in XZ plane at each integer Y step.
        wy := int(math.round(py))
        fill_trunk_slice(tgt, px, pz, wy, r, seed + i)
    }
}

// Place an ellipsoidal crown of leaves centred at (cx, cy, cz).
// rx, ry, rz are the radii on each axis.
place_crown :: proc(tgt: ^Tree_Target, cx, cy, cz: f64, rx, ry, rz: f64, seed: int) {
    ix := int(math.ceil(rx)) + 1
    iy := int(math.ceil(ry)) + 1
    iz := int(math.ceil(rz)) + 1
    ccx := int(math.round(cx)); ccy := int(math.round(cy)); ccz := int(math.round(cz))
    if !aabb_hits_chunk(tgt, ccx-ix, ccy-iy, ccz-iz, ccx+ix, ccy+iy, ccz+iz) { return }
    for dy in -iy ..= iy {
        for dx in -ix ..= ix {
            for dz in -iz ..= iz {
                fx := f64(dx) / rx; fy := f64(dy) / ry; fz := f64(dz) / rz
                dist2 := fx*fx + fy*fy + fz*fz
                wobble := tree_hash(int(cx)+dx, int(cz)+dz, seed+dy) * 0.35
                if dist2 <= (1.0 + wobble) * (1.0 + wobble) {
                    place_leaves(tgt,
                        int(math.round(cx)) + dx,
                        int(math.round(cy)) + dy,
                        int(math.round(cz)) + dz)
                }
            }
        }
    }
}

generate_tree :: proc(tgt: ^Tree_Target, bx, by, bz: int, rng_seed: int) {
    // Whole-tree AABB reject. The RNG is seeded purely from position, so
    // bailing here is deterministic and identical across every chunk that
    // skips this tree. This is the dominant early-out for startup cost.
    if !aabb_hits_chunk(tgt,
        bx - TREE_VOXEL_REACH, by, bz - TREE_VOXEL_REACH,
        bx + TREE_VOXEL_REACH, by + TREE_MAX_HEIGHT, bz + TREE_VOXEL_REACH) {
        return
    }

    rng := rng_seed

    next :: proc(rng: ^int, lo, hi: f64) -> f64 {
        rng^ += 1
        return lo + tree_hash(rng^, rng^ * 7, 13) * (hi - lo)
    }

    // Trunk parameters.
    trunk_h    := int(next(&rng, 18, 28))    // total trunk height
    base_r     := next(&rng, 2.8, 4.0)       // radius at the base
    top_r      := next(&rng, 0.8, 1.4)       // radius at the top

    // The trunk wanders slightly as it grows — sample a few control points.
    cx := f64(bx) + 0.5
    cz := f64(bz) + 0.5

    // Control-point spine: base → mid → top, each offset by a small random drift.
    mid_ox := next(&rng, -2.0, 2.0)
    mid_oz := next(&rng, -2.0, 2.0)
    top_ox := next(&rng, -1.5, 1.5)
    top_oz := next(&rng, -1.5, 1.5)

    spine_x := [3]f64{cx, cx + mid_ox, cx + top_ox}
    spine_y := [3]f64{f64(by), f64(by + trunk_h/2), f64(by + trunk_h)}
    spine_z := [3]f64{cz, cz + mid_oz, cz + top_oz}

    // Draw trunk in two halves along the spine, tapering radius.
    for seg in 0 ..< 2 {
        t0 := f64(seg) / 2.0
        t1 := f64(seg + 1) / 2.0
        r0 := base_r + (top_r - base_r) * t0
        r1 := base_r + (top_r - base_r) * t1
        draw_thick_segment(tgt,
            spine_x[seg], spine_y[seg], spine_z[seg],
            spine_x[seg+1], spine_y[seg+1], spine_z[seg+1],
            r0, r1, rng_seed + seg * 1000)
    }

    // Branches: 5–8 main branches sprouting from the upper half of the trunk.
    n_branches := int(next(&rng, 5, 9))
    branch_start_frac := 0.45  // branches start at this fraction of trunk height

    for b in 0 ..< n_branches {
        // Position along spine where this branch starts (upper half).
        tf := branch_start_frac + next(&rng, 0, 1.0 - branch_start_frac)

        // Interpolate along the spine quadratically.
        // Use piecewise linear for simplicity.
        seg := int(tf * 2.0)
        if seg >= 2 { seg = 1 }
        local_t := tf * 2.0 - f64(seg)
        start_x := spine_x[seg] + (spine_x[seg+1] - spine_x[seg]) * local_t
        start_y := spine_y[seg] + (spine_y[seg+1] - spine_y[seg]) * local_t
        start_z := spine_z[seg] + (spine_z[seg+1] - spine_z[seg]) * local_t

        // Branch direction: mostly outward, angled up.
        angle := next(&rng, 0, math.PI * 2)
        horiz := next(&rng, 0.55, 0.85)  // sin of elevation angle
        vert  := math.sqrt(1.0 - horiz*horiz)
        dir_x := math.cos(angle) * horiz
        dir_z := math.sin(angle) * horiz
        dir_y := vert + next(&rng, -0.1, 0.15)

        branch_len  := next(&rng, 10, 18)
        branch_r0   := top_r * next(&rng, 0.5, 0.75)
        branch_r1   := 0.45

        end_x := start_x + dir_x * branch_len
        end_y := start_y + dir_y * branch_len
        end_z := start_z + dir_z * branch_len

        draw_thick_segment(tgt,
            start_x, start_y, start_z,
            end_x, end_y, end_z,
            branch_r0, branch_r1,
            rng_seed + b * 333)

        // Sub-branches at the tip.
        n_sub := int(next(&rng, 2, 4))
        for s in 0 ..< n_sub {
            sub_angle  := angle + next(&rng, -1.2, 1.2)
            sub_horiz  := next(&rng, 0.5, 0.9)
            sub_vert   := math.sqrt(1.0 - sub_horiz*sub_horiz) + next(&rng, 0.0, 0.2)
            sub_len    := next(&rng, 5, 10)
            sub_end_x  := end_x + math.cos(sub_angle)*sub_horiz * sub_len
            sub_end_y  := end_y + sub_vert * sub_len
            sub_end_z  := end_z + math.sin(sub_angle)*sub_horiz * sub_len
            draw_thick_segment(tgt,
                end_x, end_y, end_z,
                sub_end_x, sub_end_y, sub_end_z,
                branch_r1, 0.3,
                rng_seed + b*333 + s*77)
            // Leaf tuft at each sub-branch tip.
            place_crown(tgt, sub_end_x, sub_end_y, sub_end_z,
                next(&rng, 4, 7), next(&rng, 3, 5), next(&rng, 4, 7),
                rng_seed + b*111 + s*55)
        }
    }

    // Main crown: large ellipsoid centred above the trunk tip.
    tip_x := spine_x[2]; tip_y := spine_y[2]; tip_z := spine_z[2]
    crown_r  := next(&rng, 10, 16)
    crown_ry := next(&rng, 7, 11)
    place_crown(tgt, tip_x, tip_y, tip_z, crown_r, crown_ry, crown_r, rng_seed + 9999)
}

should_place_tree :: proc(wx, wz: int) -> bool {
    h := tree_hash(wx, wz, 42)
    // ~1 tree per 30×30 area on average
    return h < (1.0 / (30.0 * 30.0))
}

get_voxel :: proc(gs: ^Game_State, wx, wy, wz: int) -> u32 {
    cx := floor_div(wx, CHUNK_VOXELS); cy := floor_div(wy, CHUNK_VOXELS); cz := floor_div(wz, CHUNK_VOXELS)
    if chunk_y_index(cy) < 0 { return 0 }
    slot := ring_slot(cx, cy, cz)
    // Validate ring ownership
    owner := gs.gpu_chunk_owner[slot]
    if owner[0] != i32(cx) || owner[1] != i32(cz) { return 0 }
    pid := gs.gpu_index[slot]
    if pid == -1 { return 0 }
    lx := wx - cx * CHUNK_VOXELS; ly := wy - cy * CHUNK_VOXELS; lz := wz - cz * CHUNK_VOXELS
    base := int(pid) * VOXELS_PER_BRICK
    return u32(gs.gpu_voxels[base + lx + ly * CHUNK_VOXELS + lz * CHUNK_VOXELS * CHUNK_VOXELS])
}

// CPU-side DDA raycast — mirrors the shader's two-level traversal.
// Returns the integer world position of the hit voxel and the surface normal.
raycast_voxel :: proc(gs: ^Game_State, origin, dir: [3]f32, max_dist: f32) -> (hit_pos: [3]int, normal: [3]int, ok: bool) {
    sample :: proc(gs: ^Game_State, wx, wy, wz: int) -> u32 {
        cx := floor_div(wx, CHUNK_VOXELS); cy := floor_div(wy, CHUNK_VOXELS); cz := floor_div(wz, CHUNK_VOXELS)
        if chunk_y_index(cy) < 0 { return 0 }
        slot := ring_slot(cx, cy, cz)
        owner := gs.gpu_chunk_owner[slot]
        if owner[0] != i32(cx) || owner[1] != i32(cz) { return 0 }
        pid := gs.gpu_index[slot]
        if pid == -1 { return 0 }
        lx := wx - cx * CHUNK_VOXELS; ly := wy - cy * CHUNK_VOXELS; lz := wz - cz * CHUNK_VOXELS
        base := int(pid) * VOXELS_PER_BRICK
        return u32(gs.gpu_voxels[base + lx + ly * CHUNK_VOXELS + lz * CHUNK_VOXELS * CHUNK_VOXELS])
    }

    dx := dir[0]; dy := dir[1]; dz := dir[2]
    ox := f64(origin[0]); oy := f64(origin[1]); oz := f64(origin[2])

    step_x := dx >= 0 ? 1 : -1
    step_y := dy >= 0 ? 1 : -1
    step_z := dz >= 0 ? 1 : -1

    xi := int(math.floor(ox)); yi := int(math.floor(oy)); zi := int(math.floor(oz))

    t_delta_x := abs(1.0 / f64(dx)) if dx != 0 else 1e30
    t_delta_y := abs(1.0 / f64(dy)) if dy != 0 else 1e30
    t_delta_z := abs(1.0 / f64(dz)) if dz != 0 else 1e30

    dir_x := step_x > 0 ? 1 : 0
    dir_y := step_y > 0 ? 1 : 0
    dir_z := step_z > 0 ? 1 : 0

    t_max_x := (f64(xi + dir_x) - ox) / f64(dx) if dx != 0 else 1e30
    t_max_y := (f64(yi + dir_y) - oy) / f64(dy) if dy != 0 else 1e30
    t_max_z := (f64(zi + dir_z) - oz) / f64(dz) if dz != 0 else 1e30

    nx, ny, nz := 0, 0, 0

    for t := 0.0; t < f64(max_dist); {
        if sample(gs, xi, yi, zi) != 0 {
            return {xi, yi, zi}, {nx, ny, nz}, true
        }
        if t_max_x < t_max_y && t_max_x < t_max_z {
            t = t_max_x; t_max_x += t_delta_x
            xi += step_x; nx = -step_x; ny = 0; nz = 0
        } else if t_max_y < t_max_z {
            t = t_max_y; t_max_y += t_delta_y
            yi += step_y; nx = 0; ny = -step_y; nz = 0
        } else {
            t = t_max_z; t_max_z += t_delta_z
            zi += step_z; nx = 0; ny = 0; nz = -step_z
        }
    }
    return {}, {}, false
}

BRUSH_RADIUS :: 5

// Sets all voxels within a sphere of `radius` around center to `block`
// (radius 0 = single voxel, used for torch placement). Marks each affected
// chunk slot in `dirty`.
edit_sphere :: proc(gs: ^Game_State, center: [3]int, block: Block_Type, dirty: ^map[int]bool, radius := BRUSH_RADIUS) {
    r := radius
    for dz in -r ..= r {
        for dy in -r ..= r {
            for dx in -r ..= r {
                if dx*dx + dy*dy + dz*dz > r*r { continue }
                wx := center[0] + dx
                wy := center[1] + dy
                wz := center[2] + dz
                cx := floor_div(wx, CHUNK_VOXELS); cy := floor_div(wy, CHUNK_VOXELS); cz := floor_div(wz, CHUNK_VOXELS)
                if chunk_y_index(cy) < 0 { continue }
                key := [3]int{cx, cy, cz}
                slot := ring_slot(cx, cy, cz)
                // Only edit if this slot is owned by the expected chunk
                owner := gs.gpu_chunk_owner[slot]
                if owner[0] != i32(cx) || owner[1] != i32(cz) { continue }
                chunk := gs.chunk_map[key]
                if chunk == nil { continue }
                lx := wx - cx * CHUNK_VOXELS
                ly := wy - cy * CHUNK_VOXELS
                lz := wz - cz * CHUNK_VOXELS
                vi := lx + ly * CHUNK_VOXELS + lz * CHUNK_VOXELS * CHUNK_VOXELS
                // Write only the authoritative chunk; the pool-aware
                // refresh_chunk_index (called per dirty slot) syncs the
                // pool-id voxel + mask blocks, handling air<->solid.
                chunk.voxels[vi] = u8(block)
                dirty[slot] = true
            }
        }
    }
}

// Pool-aware re-sync of a slot after an edit. Reads the authoritative
// chunk.voxels, decides emptiness, allocates/frees the pool id as needed,
// rewrites the pool-id voxel + mask blocks. Returns true if gpu_index[slot]
// changed (caller must then set index_dirty).
refresh_chunk_index :: proc(gs: ^Game_State, slot: int) -> bool {
    owner := gs.gpu_chunk_owner[slot]
    if owner[0] == 0x7fffffff { return false }
    // Invert ring_slot: iy = (slot / CHUNKS_W) % CHUNKS_H, wcy = iy + WORLD_CHUNK_Y_MIN.
    key := [3]int{
        int(owner[0]),
        (slot / CHUNKS_W) % CHUNKS_H + WORLD_CHUNK_Y_MIN,
        int(owner[1]),
    }
    chunk := gs.chunk_map[key]
    if chunk == nil { return false }

    old_id := gs.gpu_index[slot]

    empty := true
    for vi in 0 ..< VOXELS_PER_BRICK {
        if chunk.voxels[vi] != 0 { empty = false; break }
    }

    if empty {
        if old_id >= 0 {
            pool_free(&gs.brick_pool, old_id)
            gs.gpu_index[slot] = -1
        }
        return gs.gpu_index[slot] != old_id
    }

    pid := old_id
    if pid < 0 {
        pid = pool_alloc(&gs.brick_pool)
        if pid < 0 {
            pool_exhaustion_warn()
            gs.gpu_index[slot] = -1
            return -1 != old_id
        }
        gs.gpu_index[slot] = pid
    }

    base      := int(pid) * VOXELS_PER_BRICK
    mask_base := int(pid) * MASK_U32_PER_BRICK
    for m in 0 ..< MASK_U32_PER_BRICK { gs.gpu_voxel_mask[mask_base + m] = 0 }
    for vi in 0 ..< VOXELS_PER_BRICK {
        v := chunk.voxels[vi]
        gs.gpu_voxels[base + vi] = v
        if v != 0 {
            gs.gpu_voxel_mask[mask_base + (vi >> 5)] |= u32(1) << u32(vi & 31)
        }
    }
    return gs.gpu_index[slot] != old_id
}

