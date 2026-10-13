package main

import "core:fmt"
import "core:math"
import "core:math/noise"
import "core:slice"
import "core:time"

CHUNK_VOXELS :: 8
CHUNKS_W     :: 128   // ring width in chunks (MUST match shader CHUNK_COUNT_WIDTH)
CHUNKS_H     :: 64    // total Y chunks resident in the ring

// Per-brick occupancy bitmask: 8^3 = 512 voxels = 512 bits = 16 u32.
MASK_U32_PER_BRICK :: (CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS) / 32

VOXELS_PER_BRICK :: CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS // 512

// Sparse voxel brick pool on the GPU. gpu_index[slot] is a pool id in
// [0, MAX_RESIDENT_BRICKS) for a chunk with mixed contents, or encodes a
// uniform chunk with no storage: -1 = all air, -2 - b = all block b (see
// chunk_index_uniform). Most of the world is uniform (open air, deep rock),
// so only the surface, caves and trees use bricks: ~190k at LOAD_RADIUS_XZ.
MAX_RESIDENT_BRICKS :: 3 << 17 // 393k bricks: 192 MiB voxels + 24 MiB masks

chunk_index_uniform :: #force_inline proc(b: u8) -> i32 { return b == 0 ? -1 : -2 - i32(b) }

// Coarse occupancy for empty-space skipping in the shader: the ring is split
// into regions of REGION_CHUNKS^3 chunk slots, each counting its non-air
// slots (region_count). Rays skip regions with a count of zero.
REGION_CHUNKS :: 4
REGION_COUNT  :: (CHUNKS_W / REGION_CHUNKS) * (CHUNKS_H / REGION_CHUNKS) * (CHUNKS_W / REGION_CHUNKS)

slot_region :: proc(slot: int) -> int {
    sx := slot % CHUNKS_W
    iy := (slot / CHUNKS_W) % CHUNKS_H
    sz := slot / (CHUNKS_W * CHUNKS_H)
    RW :: CHUNKS_W / REGION_CHUNKS
    RH :: CHUNKS_H / REGION_CHUNKS
    return sx / REGION_CHUNKS + (iy / REGION_CHUNKS) * RW + (sz / REGION_CHUNKS) * RW * RH
}

// Every write to gpu_index goes through here, keeping region_count in step.
set_slot_index :: proc(gs: ^Game_State, slot: int, idx: i32) {
    old := gs.gpu_index[slot]
    if old == idx { return }
    if old == -1 || idx == -1 {
        r := slot_region(slot)
        if old == -1 { gs.region_count[r] += 1 } else { gs.region_count[r] -= 1 }
        gs.region_dirty = true
    }
    gs.gpu_index[slot] = idx
    gs.index_dirty = true
}

// Light bricks (512 bytes each) exist only for chunks whose light varies:
// mostly the terrain surface, tree canopies, cave mouths and around torches.
// gpu_light_index[slot] is a light pool id, or light_index_uniform(v) for a
// chunk whose every voxel has light v.
MAX_LIGHT_BRICKS :: 1 << 17

light_index_uniform :: #force_inline proc(v: u8) -> i32 { return -1 - i32(v) }

// Free-list allocator: a stack of free pool ids. free_top is the count of
// ids available in free_ids[0:free_top]. alloc = pop, free = push. O(1),
// no fragmentation, deterministic.
Brick_Pool :: struct {
    free_ids: []i32,
    free_top: int,
}

pool_init :: proc(p: ^Brick_Pool, n: int) {
    p.free_ids = make([]i32, n)
    for i in 0 ..< n {
        p.free_ids[i] = i32(n - 1 - i) // pop order hands out 0,1,2...
    }
    p.free_top = n
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
    Air           = 0,
    Grass         = 1,
    Stone         = 2,
    Log           = 3,
    Leaves        = 4,
    Torch         = 5,   // emissive: block light source (light.odin)
    Dirt          = 6,
    Sand          = 7,
    Sandstone     = 8,
    Snow          = 9,
    Ice           = 10,
    Water         = 11,  // not solid; seen through (shaders), lets sky light in
    Gravel        = 12,
    Terracotta    = 13,  // banded by height in the shader
    Red_Sand      = 14,
    Coal_Ore      = 15,
    Iron_Ore      = 16,
    Gold_Ore      = 17,
    Spruce_Log    = 18,
    Spruce_Leaves = 19,
    Cactus        = 20,
    // Must stay below 32: the far LOD stores block ids in 5 bits.
}

// Blocks the player and entities collide with.
block_solid :: #force_inline proc(b: u8) -> bool {
    return b != u8(Block_Type.Air) && b != u8(Block_Type.Water)
}

block_is_leaves :: #force_inline proc(b: u8) -> bool {
    return b == u8(Block_Type.Leaves) || b == u8(Block_Type.Spruce_Leaves)
}

// One 8x8x8 chunk. Uniform chunks (all air, all stone) keep no voxel array.
Chunk :: struct {
    voxels:     ^[VOXELS_PER_BRICK]u8, // nil = every voxel is `fill`
    fill:       u8,
    light:      ^[VOXELS_PER_BRICK]u8, // nil = all light_fill (light.odin)
    light_fill: u8,
}

// All CHUNKS_H chunks of one 8x8 footprint: the unit of generation,
// streaming and saving. gs.columns holds exactly the resident columns.
Column :: struct {
    chunks:   [CHUNKS_H]Chunk,
    modified: bool, // edited by the player: saved to disk when unloaded (save.odin)
}

chunk_voxel :: #force_inline proc(c: ^Chunk, vi: int) -> u8 {
    return c.voxels == nil ? c.fill : c.voxels[vi]
}

// Returns true if the voxel changed.
chunk_set_voxel :: proc(c: ^Chunk, vi: int, v: u8) -> bool {
    if c.voxels == nil {
        if v == c.fill { return false }
        c.voxels = new([VOXELS_PER_BRICK]u8)
        for &x in c.voxels { x = c.fill }
    }
    if c.voxels[vi] == v { return false }
    c.voxels[vi] = v
    return true
}

// Drop the voxel array of a chunk that became uniform. Only air, water and
// plain opaque blocks can be uniform: the shader treats a uniform chunk as
// one solid box (rays inside water skip it whole), which would be wrong for
// see-through leaves or emitters.
chunk_compact :: proc(c: ^Chunk) {
    if c.voxels == nil { return }
    first := c.voxels[0]
    if first != 0 && first != u8(Block_Type.Water) && (!block_opaque(first) || block_emission(first) > 0) { return }
    for v in c.voxels { if v != first { return } }
    free(c.voxels)
    c.voxels = nil
    c.fill = first
}

column_free :: proc(col: ^Column) {
    for &c in col.chunks {
        if c.voxels != nil { free(c.voxels) }
        chunk_free_light(&c)
    }
    free(col)
}

// The resident chunk at a world chunk coordinate, or nil.
world_chunk :: proc(gs: ^Game_State, key: [3]int) -> ^Chunk {
    iy := chunk_y_index(key.y)
    if iy < 0 { return nil }
    col := gs.columns[{key.x, key.z}]
    return col == nil ? nil : &col.chunks[iy]
}

// The resident chunk a ring slot currently holds, or nil.
slot_chunk :: proc(gs: ^Game_State, slot: int) -> ^Chunk {
    owner := gs.gpu_chunk_owner[slot]
    if owner[0] == 0x7fffffff { return nil }
    return world_chunk(gs, {int(owner[0]), (slot / CHUNKS_W) % CHUNKS_H + WORLD_CHUNK_Y_MIN, int(owner[1])})
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
CAVE_CEIL_Y     :: 110          // mountains are solid above this (ravines still cut in)
CAVE_TOP_MARGIN :: 6            // keep caves this far below the surface
CAVE_THRESHOLD  :: 0.32         // higher = fewer/smaller caves

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
// Chunks are complete (terrain + trees) the moment generate_column_at returns,
// so there is no separate tree pass and no cross-chunk bookkeeping.
generate_world :: proc(gs: ^Game_State) {
    t0 := time.now()

    total := CHUNKS_W * CHUNKS_H * CHUNKS_W
    gs.columns         = make(map[[2]int]^Column)
    // Indexed by ring slot.
    gs.gpu_index       = make([]i32,    total)
    gs.gpu_chunk_owner = make([][2]i32, total)
    gs.gpu_light_index = make([]i32,    total)
    gs.region_count    = make([]u32,    REGION_COUNT)

    far_init(gs)
    pool_init(&gs.brick_pool, MAX_RESIDENT_BRICKS)
    pool_init(&gs.light_pool, MAX_LIGHT_BRICKS)

    for i in 0 ..< total {
        gs.gpu_index[i]       = -1
        gs.gpu_chunk_owner[i] = {0x7fffffff, 0x7fffffff}
        gs.gpu_light_index[i] = light_index_uniform(LIGHT_SKY)
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
        stitch_pending_columns(gs)
        if streaming_idle(gs) { break }
    }

    elapsed := time.duration_seconds(time.since(t0))
    fmt.printf("World gen (startup radius %d): %.3f s\n", STARTUP_RADIUS_XZ, elapsed)
    profile_dump("startup")
}

// Radius (in chunks) loaded synchronously before the window opens. The full
// LOAD_RADIUS_XZ streams in during gameplay via the per-frame enqueue.
STARTUP_RADIUS_XZ :: 10

// Enqueue all XZ columns within a circle of `radius` around the player (a
// square's corners are farther than anything straight ahead: 21% more
// columns for terrain mostly lost in fog). The whole vertical column (all
// CHUNKS_H Y chunks) is generated as one job.
enqueue_radius :: proc(gs: ^Game_State, radius: int) {
    pcx := gs.player_chunk[0]
    pcz := gs.player_chunk[2]
    for dcz in -radius ..= radius {
        for dcx in -radius ..= radius {
            if dcx*dcx + dcz*dcz > radius*radius { continue }
            wcx := pcx + dcx; wcz := pcz + dcz
            key := [2]int{wcx, wcz}
            if key in gs.columns { continue }
            worker_pool_enqueue(&gs.pool, key, key in gs.saved_columns)
        }
    }
}

enqueue_chunks :: proc(gs: ^Game_State) {
    enqueue_radius(gs, LOAD_RADIUS_XZ)
}

// Point a ring slot's GPU index at the chunk it holds: a uniform chunk is
// encoded in the index, a mixed one gets a pool brick and is queued for
// voxel upload. Call after the slot's chunk was loaded or edited.
gpu_sync_slot :: proc(gs: ^Game_State, slot: int) {
    old := gs.gpu_index[slot]
    c := slot_chunk(gs, slot)
    if c != nil { chunk_compact(c) }
    idx := i32(-1)
    if c != nil && c.voxels == nil {
        idx = chunk_index_uniform(c.fill)
    } else if c != nil {
        idx = old
        if idx < 0 {
            idx = pool_alloc(&gs.brick_pool)
            if idx < 0 { pool_exhaustion_warn() } // renders as air, no leak
        }
        if idx >= 0 { append(&gs.dirty_slots, slot) }
    }
    if old >= 0 && idx != old { pool_free(&gs.brick_pool, old) }
    set_slot_index(gs, slot, idx)
}

// Make a freshly loaded column resident: evict whatever column held its ring
// position, then point the ring slots at it.
integrate_column :: proc(gs: ^Game_State, key: [2]int, col: ^Column) {
    owner := gs.gpu_chunk_owner[ring_slot(key.x, WORLD_CHUNK_Y_MIN, key.y)]
    if owner[0] != 0x7fffffff && (int(owner[0]) != key.x || int(owner[1]) != key.y) {
        unload_column(gs, {int(owner[0]), int(owner[1])})
    }
    gs.columns[key] = col
    for iy in 0 ..< CHUNKS_H {
        slot := ring_slot(key.x, iy + WORLD_CHUNK_Y_MIN, key.y)
        gs.gpu_chunk_owner[slot] = {i32(key.x), i32(key.y)}
        gpu_sync_slot(gs, slot)
        append(&gs.light_dirty, slot)
    }
    gs.owner_dirty = true
    append(&gs.stitch_queue, key)
    far_update_column(gs, key)
}

// Drop a resident column (saving it first if the player edited it) and free
// its GPU bricks. Unedited columns are simply regenerated if needed again.
unload_column :: proc(gs: ^Game_State, key: [2]int) {
    col := gs.columns[key]
    if col == nil { return }
    if col.modified { save_column(gs, key, col) }
    for iy in 0 ..< CHUNKS_H {
        slot := ring_slot(key.x, iy + WORLD_CHUNK_Y_MIN, key.y)
        pool_free(&gs.brick_pool, gs.gpu_index[slot])
        pool_free(&gs.light_pool, gs.gpu_light_index[slot])
        set_slot_index(gs, slot, -1)
        gs.gpu_light_index[slot] = light_index_uniform(LIGHT_SKY)
        gs.gpu_chunk_owner[slot] = {0x7fffffff, 0x7fffffff}
    }
    gs.owner_dirty = true
    delete_key(&gs.columns, key)
    worker_pool_unqueue(&gs.pool, key)
    column_free(col)
}

// Drain finished columns from the worker pool and integrate them. Each
// column arrives complete (terrain, trees, its own sky light), so this is
// pool bookkeeping plus queueing uploads.
INTEGRATE_BUDGET_PER_FRAME :: 24

integrate_ready_chunks :: proc(gs: ^Game_State) {
    results := worker_pool_drain_budget(&gs.pool, INTEGRATE_BUDGET_PER_FRAME)
    defer delete(results)
    if len(results) == 0 { return }
    t_int := time.tick_now()
    for r in results {
        if r.key in gs.columns {
            column_free(r.column) // already resident: discard the duplicate
            continue
        }
        integrate_column(gs, r.key, r.column)
    }
    profile_add(.Integrate, t_int)
}

// Main-thread time per frame for stitching light between columns. New
// columns stream in far from the player, so a few frames of unstitched
// light at their borders is never seen; a spike in frame time would be.
LIGHT_STITCH_BUDGET :: 1500 * time.Microsecond

stitch_pending_columns :: proc(gs: ^Game_State) {
    start := time.tick_now()
    n := 0
    for n < len(gs.stitch_queue) && time.tick_since(start) < LIGHT_STITCH_BUDGET {
        c := gs.stitch_queue[n]
        light_stitch_column(gs, c[0], c[1])
        n += 1
    }
    remove_range(&gs.stitch_queue, 0, n)
}

// No columns generating, waiting to integrate, or waiting for light stitching.
streaming_idle :: proc(gs: ^Game_State) -> bool {
    return worker_pool_idle(&gs.pool) && len(gs.stitch_queue) == 0
}

// Generate an entire XZ column: all CHUNKS_H Y chunks at world chunk coord
// (wcx, *, wcz). Terrain (terrain.odin) is sampled once per voxel column, so
// the vertical fill is table lookups plus cave noise; chunks that are all
// air, all water or all stone skip the per-voxel fill entirely.
generate_column_at :: proc(wcx, wcz: int) -> ^Column {
    column := new(Column)

    gx := wcx * CHUNK_VOXELS
    gz := wcz * CHUNK_VOXELS

    // Terrain for the footprint plus a 1-voxel border (for slopes).
    t_noise := time.tick_now()
    G :: CHUNK_VOXELS + 2
    samples: [G * G]Terrain_Sample
    terrain_grid(gx - 1, gz - 1, G, G, samples[:])
    N :: CHUNK_VOXELS * CHUNK_VOXELS
    height: [N]int
    layers: [N]Surface_Layers
    surf_min, surf_max, deep_min := max(int), min(int), max(int)
    for z in 0 ..< CHUNK_VOXELS {
        for x in 0 ..< CHUNK_VOXELS {
            si := (x + 1) + (z + 1) * G
            s := samples[si]
            slope := terrain_slope(s.height, samples[si - 1].height, samples[si + 1].height,
                                   samples[si - G].height, samples[si + G].height)
            i := x + z * CHUNK_VOXELS
            height[i] = s.height
            layers[i] = surface_layers(s, slope)
            surf_min = min(surf_min, s.height)
            surf_max = max(surf_max, s.height)
            deep_min = min(deep_min, s.height - layers[i].filler_depth)
        }
    }
    top_max := surf_min < SEA_LEVEL ? max(surf_max, SEA_LEVEL) : surf_max
    profile_add(.Terrain_Noise, t_noise)

    t_fill := time.tick_now()
    for iy in 0 ..< CHUNKS_H {
        chunk := &column.chunks[iy]
        gy  := (iy + WORLD_CHUNK_Y_MIN) * CHUNK_VOXELS // world voxel Y of this chunk's base
        gy1 := gy + CHUNK_VOXELS                       // exclusive top

        // Uniform chunks: all air above everything, all water between the
        // highest ground and the (maybe frozen) top layer of the sea, all
        // stone below the surface layers where no caves are carved.
        if gy >= top_max { continue }
        if gy >= surf_max && gy1 <= SEA_LEVEL - 1 {
            chunk.fill = u8(Block_Type.Water)
            continue
        }
        if gy1 <= deep_min && (gy1 <= CAVE_FLOOR_Y || gy >= CAVE_CEIL_Y) {
            chunk.fill = u8(Block_Type.Stone)
            continue
        }
        chunk.voxels = new([VOXELS_PER_BRICK]u8)

        for z in 0 ..< CHUNK_VOXELS {
            for x in 0 ..< CHUNK_VOXELS {
                ci := x + z * CHUNK_VOXELS
                h  := height[ci]
                l  := layers[ci]
                cave_top := min(h - CAVE_TOP_MARGIN, CAVE_CEIL_Y)
                for y in 0 ..< CHUNK_VOXELS {
                    wy := gy + y
                    b: Block_Type
                    switch {
                    case wy >= h:
                        if wy < SEA_LEVEL {
                            b = l.frozen && wy == SEA_LEVEL - 1 ? .Ice : .Water
                        }
                    case wy > CAVE_FLOOR_Y && wy < cave_top &&
                         noise.noise_3d_improve_xy(7, {f64(gx + x) * 0.04, f64(wy) * 0.05, f64(gz + z) * 0.04}) > CAVE_THRESHOLD:
                        // cave: air
                    case wy == h - 1:
                        b = l.top
                    case wy >= h - l.filler_depth:
                        b = l.filler
                    case wy > CAVE_FLOOR_Y && wy < CAVE_CEIL_Y:
                        b = ore_at(gx + x, wy, gz + z)
                    case:
                        b = .Stone
                    }
                    chunk.voxels[x + y * CHUNK_VOXELS + z * CHUNK_VOXELS * CHUNK_VOXELS] = u8(b)
                }
            }
        }
    }
    profile_add(.Terrain_Fill, t_fill)

    // One tree scan for the whole column. Trees write into whichever Y chunk
    // their voxels land in via set_voxel_world.
    tgt := Tree_Target{col = column, ox = gx, oz = gz, size = CHUNK_VOXELS}
    t_scan := time.tick_now()
    lat := tree_lattice(gx, gz, CHUNK_VOXELS)
    for wz in gz - TREE_VOXEL_REACH ..< gz + CHUNK_VOXELS + TREE_VOXEL_REACH {
        for wx in gx - TREE_VOXEL_REACH ..< gx + CHUNK_VOXELS + TREE_VOXEL_REACH {
            kind, base := tree_at(&lat, wx, wz)
            if kind == .None { continue }
            t_gen := time.tick_now()
            generate_tree_kind(&tgt, kind, wx, base, wz)
            profile_add(.Tree_Generate, t_gen)
        }
    }
    profile_add(.Tree_Scan, t_scan)
    for &c in column.chunks { chunk_compact(&c) }
    return column
}

TREE_MAX_HEIGHT :: 60 // big oak: trunk + branch + crown reach above the base

// Where generate_tree writes: a full XZ column being generated (all CHUNKS_H
// Y chunks share one tree scan, writes clipped to the column's 8-voxel
// footprint), or a far-field summary (far != nil: writes only raise the
// recorded top surface, footprint FAR_TILE voxels). A tree is regenerated by
// every footprint it overlaps, so edges stay seamless with no shared state.
Tree_Target :: struct {
    col:      ^Column,
    far:      ^Far_Summary,
    ox, oz:   int,     // world voxel coord of local (0, *, 0)
    size:     int,     // footprint width in voxels
}

// Max horizontal voxel reach of a tree from its base (trunk wander + branch +
// crown): branch_len 18 + sub_len 10 + crown radius 16 ≈ 44. Round up.
TREE_VOXEL_REACH :: 48

set_voxel_world :: proc(t: ^Tree_Target, wx, wy, wz: int, block: Block_Type) {
    lx := wx - t.ox; lz := wz - t.oz
    if lx < 0 || lx >= t.size { return }
    if lz < 0 || lz >= t.size { return }
    if t.far != nil { far_record(t.far, lx, wy, lz, u8(block)); return }
    wcy := floor_div(wy, CHUNK_VOXELS)
    iy  := chunk_y_index(wcy)
    if iy < 0 { return }
    ly := wy - wcy * CHUNK_VOXELS
    chunk_set_voxel(&t.col.chunks[iy], lx + ly*CHUNK_VOXELS + lz*CHUNK_VOXELS*CHUNK_VOXELS, u8(block))
}

// True if a world-space AABB [lo, hi] (inclusive) overlaps this column's XZ
// footprint. Y is unbounded within the column (all 16 chunks present), so only
// XZ matters for rejecting whole trees/branches/crowns.
@(require_results)
aabb_hits_chunk :: proc(t: ^Tree_Target, lox, loy, loz, hix, hiy, hiz: int) -> bool {
    if hix < t.ox || lox >= t.ox + t.size { return false }
    if hiz < t.oz || loz >= t.oz + t.size { return false }
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

// Place leaves only into air or other leaves, never over logs or ground.
// Clipped to the footprint.
place_leaves :: proc(t: ^Tree_Target, wx, wy, wz: int, block := Block_Type.Leaves) {
    lx := wx - t.ox; lz := wz - t.oz
    if lx < 0 || lx >= t.size { return }
    if lz < 0 || lz >= t.size { return }
    if t.far != nil { far_record(t.far, lx, wy, lz, u8(block)); return }
    wcy := floor_div(wy, CHUNK_VOXELS)
    iy  := chunk_y_index(wcy)
    if iy < 0 { return }
    ly := wy - wcy * CHUNK_VOXELS
    vi := lx + ly*CHUNK_VOXELS + lz*CHUNK_VOXELS*CHUNK_VOXELS
    if v := chunk_voxel(&t.col.chunks[iy], vi); v == 0 || block_is_leaves(v) {
        chunk_set_voxel(&t.col.chunks[iy], vi, u8(block))
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

generate_tree_kind :: proc(tgt: ^Tree_Target, kind: Tree_Kind, bx, by, bz: int) {
    seed := bx * 1000 + bz
    switch kind {
    case .None:
    case .Oak:       generate_tree(tgt, bx, by, bz, seed)
    case .Small_Oak: generate_small_oak(tgt, bx, by, bz, seed)
    case .Bush:      generate_bush(tgt, bx, by, bz, seed)
    case .Spruce:    generate_spruce(tgt, bx, by, bz, seed)
    case .Cactus:    generate_cactus(tgt, bx, by, bz, seed)
    }
}

@(private="file")
tree_rand :: proc(rng: ^int, lo, hi: f64) -> f64 {
    rng^ += 1
    return lo + tree_hash(rng^, rng^ * 7, 13) * (hi - lo)
}

// A Minecraft-sized oak: a one-voxel trunk and a lumpy round crown.
generate_small_oak :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 6, by, bz - 6, bx + 6, by + 16, bz + 6) { return }
    rng := seed
    h := int(tree_rand(&rng, 5, 9))
    for y in 0 ..< h { set_voxel_world(tgt, bx, by + y, bz, .Log) }
    r := tree_rand(&rng, 2.6, 3.6)
    place_crown(tgt, f64(bx), f64(by + h), f64(bz), r, r * 0.8, r, seed + 5)
    place_crown(tgt, f64(bx) + tree_rand(&rng, -1.5, 1.5), f64(by + h) - 1.5, f64(bz) + tree_rand(&rng, -1.5, 1.5),
                r * 0.8, r * 0.6, r * 0.8, seed + 6)
}

// A low leafy clump around a stub of trunk.
generate_bush :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 4, by, bz - 4, bx + 4, by + 4, bz + 4) { return }
    rng := seed
    set_voxel_world(tgt, bx, by, bz, .Log)
    r := tree_rand(&rng, 1.6, 2.4)
    place_crown(tgt, f64(bx), f64(by) + 0.8, f64(bz), r, r * 0.65, r, seed + 3)
}

// Spruce: a straight trunk (2x2 when tall) under tiers of needles that
// narrow toward a pointed top.
generate_spruce :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 7, by, bz - 7, bx + 8, by + 30, bz + 8) { return }
    rng := seed
    h := int(tree_rand(&rng, 9, 24))
    thick := h >= 17
    for y in 0 ..< h {
        set_voxel_world(tgt, bx, by + y, bz, .Spruce_Log)
        if thick {
            set_voxel_world(tgt, bx + 1, by + y, bz, .Spruce_Log)
            set_voxel_world(tgt, bx, by + y, bz + 1, .Spruce_Log)
            set_voxel_world(tgt, bx + 1, by + y, bz + 1, .Spruce_Log)
        }
    }
    cx := f64(bx) + (thick ? 1.0 : 0.5)
    cz := f64(bz) + (thick ? 1.0 : 0.5)
    y0   := by + int(tree_rand(&rng, 2, 4))
    top  := by + h + 1
    rmax := tree_rand(&rng, 3.2, 4.2) + (thick ? 1.5 : 0)
    tier := tree_rand(&rng, 2.6, 3.6)
    for y in y0 ..= top {
        f := f64(y - y0) / f64(top - y0)   // 0 at the lowest tier .. 1 at the tip
        k := f64(top - y) / tier
        in_tier := k - math.floor(k)       // 0 at a tier's top .. 1 at its flared base
        r  := rmax * (1 - f) * (0.55 + 0.45 * in_tier) + (thick ? 1.1 : 0.6)
        ir := int(math.ceil(r)) + 1
        for dz in -ir ..= ir {
            for dx in -ir ..= ir {
                wx := int(math.floor(cx)) + dx
                wz := int(math.floor(cz)) + dz
                ddx := f64(wx) + 0.5 - cx
                ddz := f64(wz) + 0.5 - cz
                rr := r + tree_hash(wx, wz, seed + y) * 0.9 - 0.3
                if ddx*ddx + ddz*ddz <= rr * rr {
                    place_leaves(tgt, wx, y, wz, .Spruce_Leaves)
                }
            }
        }
    }
    place_leaves(tgt, int(math.floor(cx)), top + 1, int(math.floor(cz)), .Spruce_Leaves)
}

// Cactus: a green column, sometimes with an arm or two.
generate_cactus :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 3, by, bz - 3, bx + 3, by + 8, bz + 3) { return }
    rng := seed
    h := int(tree_rand(&rng, 3, 7))
    for y in 0 ..< h { set_voxel_world(tgt, bx, by + y, bz, .Cactus) }
    DIRS :: [4][2]int{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
    dirs := DIRS
    first := int(tree_rand(&rng, 0, 4))
    for a in 0 ..< 2 {
        if h < 4 || tree_rand(&rng, 0, 1) < 0.5 { continue }
        d := dirs[(first + a * 2) & 3] // arms on opposite sides
        ay := by + int(tree_rand(&rng, 1, f64(h - 2)))
        set_voxel_world(tgt, bx + d.x, ay, bz + d.y, .Cactus)
        arm := int(tree_rand(&rng, 1, 3))
        for y in 0 ..= arm { set_voxel_world(tgt, bx + 2*d.x, ay + y, bz + 2*d.y, .Cactus) }
    }
}

// True if the voxel blocks movement (water does not).
solid_at :: proc(gs: ^Game_State, wx, wy, wz: int) -> bool {
    return block_solid(u8(get_voxel(gs, wx, wy, wz)))
}

get_voxel :: proc(gs: ^Game_State, wx, wy, wz: int) -> u32 {
    c := world_chunk(gs, {wx >> 3, wy >> 3, wz >> 3}) // CHUNK_VOXELS == 8
    if c == nil { return 0 }
    return u32(chunk_voxel(c, (wx & 7) + (wy & 7) * CHUNK_VOXELS + (wz & 7) * CHUNK_VOXELS * CHUNK_VOXELS))
}

// CPU-side DDA raycast — mirrors the shader's two-level traversal.
// Returns the integer world position of the hit voxel and the surface normal.
raycast_voxel :: proc(gs: ^Game_State, origin, dir: [3]f32, max_dist: f32) -> (hit_pos: [3]int, normal: [3]int, ok: bool) {
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
        if block_solid(u8(get_voxel(gs, xi, yi, zi))) {
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
// chunk slot in `dirty` (the caller then runs gpu_sync_slot on each) and
// appends every voxel that changed to `changed` (relit by light_on_edit).
edit_sphere :: proc(gs: ^Game_State, center: [3]int, block: Block_Type, dirty: ^map[int]bool, changed: ^[dynamic][3]int, radius := BRUSH_RADIUS) {
    r := radius
    for dz in -r ..= r {
        for dy in -r ..= r {
            for dx in -r ..= r {
                if dx*dx + dy*dy + dz*dz > r*r { continue }
                wx := center[0] + dx
                wy := center[1] + dy
                wz := center[2] + dz
                cx := wx >> 3; cy := wy >> 3; cz := wz >> 3 // CHUNK_VOXELS == 8
                iy := chunk_y_index(cy)
                if iy < 0 { continue }
                col := gs.columns[{cx, cz}]
                if col == nil { continue }
                vi := (wx & 7) + (wy & 7) * CHUNK_VOXELS + (wz & 7) * CHUNK_VOXELS * CHUNK_VOXELS
                if !chunk_set_voxel(&col.chunks[iy], vi, u8(block)) { continue }
                col.modified = true
                dirty[ring_slot(cx, cy, cz)] = true
                append(changed, [3]int{wx, wy, wz})
            }
        }
    }
    if block == .Air { fill_dug_water(gs, changed[:]) }
}

// Dug-out voxels touching water (from the side or above) fill with it, so
// digging into a lake or the seabed doesn't leave an air pocket. Only the
// dug voxels fill, never existing caves: water doesn't flow. Every voxel in
// `dug` is already in the caller's changed list and dirty slots.
fill_dug_water :: proc(gs: ^Game_State, dug: [][3]int) {
    FEEDS :: [5][3]int{{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, 1, 0}}
    feeds := FEEDS
    water := u32(Block_Type.Water)
    for filled := true; filled; {
        filled = false
        for p in dug {
            if get_voxel(gs, p.x, p.y, p.z) != 0 { continue }
            for d in feeds {
                q := p + d
                if get_voxel(gs, q.x, q.y, q.z) != water { continue }
                col := gs.columns[{p.x >> 3, p.z >> 3}] // CHUNK_VOXELS == 8
                chunk_set_voxel(&col.chunks[chunk_y_index(p.y >> 3)],
                                (p.x & 7) + (p.y & 7) * CHUNK_VOXELS + (p.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS, u8(water))
                filled = true
                break
            }
        }
    }
}

// Column offsets within LOAD_RADIUS_XZ, nearest first (built once).
@(private="file")
g_load_offsets: [dynamic][2]int

// Radius (in columns) of the circle around the player's column inside which
// every column is loaded. Columns stream in nearest-first, so this grows as a
// solid disc; past it the far terrain stands in.
loaded_radius :: proc(gs: ^Game_State) -> int {
    if len(g_load_offsets) == 0 {
        R :: LOAD_RADIUS_XZ
        for dz in -R ..= R {
            for dx in -R ..= R {
                if dx*dx + dz*dz <= R*R { append(&g_load_offsets, [2]int{dx, dz}) }
            }
        }
        slice.sort_by(g_load_offsets[:], proc(a, b: [2]int) -> bool {
            return a.x*a.x + a.y*a.y < b.x*b.x + b.y*b.y
        })
    }
    pc := [2]int{gs.player_chunk.x, gs.player_chunk.z}
    for o in g_load_offsets {
        x, z := pc.x + o.x, pc.y + o.y
        owner := gs.gpu_chunk_owner[ring_slot(x, WORLD_CHUNK_Y_MIN, z)]
        if int(owner[0]) != x || int(owner[1]) != z {
            // Largest whole radius strictly inside the first missing column.
            return max(int(math.ceil(math.sqrt(f64(o.x*o.x + o.y*o.y)))) - 1, 0)
        }
    }
    return LOAD_RADIUS_XZ
}
