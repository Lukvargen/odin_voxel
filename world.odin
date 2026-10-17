package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import "core:slice"
import "core:sync"
import "core:time"

CHUNK_VOXELS :: 8
CHUNKS_W     :: 128   // ring width in chunks (MUST match shader CHUNK_COUNT_WIDTH)
CHUNKS_H     :: 80    // total Y chunks resident in the ring (MUST match shader GPU_CHUNKS_HEIGHT)

// Per-brick occupancy bitmask: 8^3 = 512 voxels = 512 bits = 16 u32.
MASK_U32_PER_BRICK :: (CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS) / 32

VOXELS_PER_BRICK :: CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS // 512

// Sparse voxel brick pool on the GPU. gpu_index[slot] is a pool id in
// [0, MAX_RESIDENT_BRICKS) for a chunk with mixed contents, or encodes a
// uniform chunk with no storage: -1 = all air, -2 - b = all block b (see
// chunk_index_uniform). Most of the world is uniform (open air, deep rock),
// so only the surface, caves and trees use bricks: ~190k at LOAD_RADIUS_XZ.
MAX_RESIDENT_BRICKS :: 3 << 17 // 393k bricks: 192 MiB voxels + 24 MiB masks (at the Far view distance)

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
    gs.index_planes[slot / PLANE_SLOTS] = true
}

// Light bricks (1 KB each: a u16 per voxel) exist only for chunks whose light varies:
// mostly the terrain surface, tree canopies, cave mouths and around torches.
// gpu_light_index[slot] is a light pool id, or light_index_uniform(v) for a
// chunk whose every voxel has light v.
MAX_LIGHT_BRICKS :: 5 << 16 // 320k (320 MB) at the Far view distance: sky light 31 deep varies in many chunks; mountains peaked ~234k (bench relight)

// The brick pools hold what's loaded, so they're sized for the view
// distance: the MAX_ sizes at Far, scaled by the loaded area (columns kept
// out to the radius + 2, and some headroom) below it. Short needs about a
// fifth of Far's GPU memory.
pool_scale :: proc(radius: int) -> f32 {
    s := f32(radius + 6) / f32(LOAD_RADIUS_XZ + 6)
    return min(s * s, 1)
}
brick_cap_for :: proc(radius: int) -> int { return (int(f32(MAX_RESIDENT_BRICKS) * pool_scale(radius)) + 1023) &~ 1023 }
light_cap_for :: proc(radius: int) -> int { return (int(f32(MAX_LIGHT_BRICKS) * pool_scale(radius)) + 1023) &~ 1023 }
LIGHT_BRICK_BYTES :: VOXELS_PER_BRICK * size_of(u16)

light_index_uniform :: #force_inline proc(v: u16) -> i32 { return -1 - i32(v) }

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

// Returns a pool id in [0, the pool's size) or -1 if exhausted.
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
        fmt.eprintln("WARNING: brick pool exhausted; bricks wait as air until some free. Raise MAX_RESIDENT_BRICKS.")
    }
}

// World chunk-Y range. wcy (world chunk Y) is valid in
// [WORLD_CHUNK_Y_MIN, WORLD_CHUNK_Y_MIN + CHUNKS_H). It maps to a ring Y
// index in [0, CHUNKS_H) by subtracting WORLD_CHUNK_Y_MIN. World voxel Y
// thus spans [WORLD_CHUNK_Y_MIN*8, (WORLD_CHUNK_Y_MIN+CHUNKS_H)*8) = [-128, +512):
// below the caves it's solid stone, so the room goes to the mountains.
WORLD_CHUNK_Y_MIN :: -16 // (MUST match the shader's)
WORLD_Y_MIN       :: WORLD_CHUNK_Y_MIN * CHUNK_VOXELS                 // -128
WORLD_Y_MAX       :: (WORLD_CHUNK_Y_MIN + CHUNKS_H) * CHUNK_VOXELS    // +512

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
    Weathered_Stone = 21, // natural surface rock: moss low down, ledge snow up high (shader)
    Stone_Bricks  = 22,  // ruins (landmarks.odin)
    Crystal       = 23,  // glowing amber crystal: caves, altars; a light source
    // Sea life (decorate_ocean). Kelp, seagrass and sea pickles are plants:
    // drawn as two crossed cutout planes in their voxel (shaders), and
    // otherwise water: you swim through them, light and sound pass.
    Kelp          = 24,
    Seagrass      = 25,
    Coral         = 26,  // solid reef block, coloured per reef head (shader)
    Sea_Pickle    = 27,  // glowing plant: a dim light source on warm reefs
    Birch_Log     = 28,  // white bark, dark marks
    Birch_Leaves  = 29,
    Autumn_Leaves = 30,  // oaks and birches in autumn patches of forest
    // Land plants: drawn like the sea's, crossed cutout planes; you walk
    // through them, light passes, they go when the ground under them does.
    Tall_Grass    = 31,
    Flower        = 32,  // petals coloured per flower (shader)
    Fern          = 33,
    Dry_Bush      = 34,
    Acacia_Log    = 35,
    Acacia_Leaves = 36,
    Willow_Leaves = 37,
    Dry_Grass     = 38,  // savanna ground: grass gone yellow
    Mushroom      = 39,  // a land plant too: red with white spots, or brown
    // Caves (caves.odin).
    Moss          = 40,
    Dripstone     = 41,
    Roots         = 42,  // hanging from cave ceilings: a plant (cutout)
    Glow_Mushroom = 43,  // a plant, and a dim light
    Glow_Moss     = 44,  // on cave ceilings: a dim light
    // Doors (door.odin): 48 ids from here, one per state (facing, hinge,
    // open, which part). Door itself is the one in hand and in the
    // inventory; the rest only appear placed, so this stays the last name.
    Door          = 45,
}

// Every block id there is: the named ones and the doors' states.
BLOCK_IDS :: int(Block_Type.Door) + 48

// Plants that live in water and count as water for everything but drawing.
block_is_water_plant :: #force_inline proc(b: u8) -> bool {
    return b == u8(Block_Type.Kelp) || b == u8(Block_Type.Seagrass) || b == u8(Block_Type.Sea_Pickle)
}

// Grass tufts, flowers, ferns, dry bushes.
block_is_land_plant :: #force_inline proc(b: u8) -> bool {
    return b >= u8(Block_Type.Tall_Grass) && b <= u8(Block_Type.Dry_Bush) || b == u8(Block_Type.Mushroom) ||
           b == u8(Block_Type.Roots) || b == u8(Block_Type.Glow_Mushroom)
}

// Water, or a plant standing in it: swimming, buoyancy, underwater sound.
block_is_watery :: #force_inline proc(b: u8) -> bool {
    return b == u8(Block_Type.Water) || block_is_water_plant(b)
}

// Blocks the player and entities collide with. A door is a wall closed and
// a way through open; the player meets its actual panel (aabb_solid).
block_solid :: #force_inline proc(b: u8) -> bool {
    return b != u8(Block_Type.Air) && !block_is_watery(b) && !block_is_land_plant(b) && !door_is_open(b)
}

block_is_leaves :: #force_inline proc(b: u8) -> bool {
    return b == u8(Block_Type.Leaves) || b == u8(Block_Type.Spruce_Leaves) || b == u8(Block_Type.Birch_Leaves) || b == u8(Block_Type.Autumn_Leaves) ||
           b == u8(Block_Type.Acacia_Leaves) || b == u8(Block_Type.Willow_Leaves)
}

block_is_log :: #force_inline proc(b: u8) -> bool {
    return b == u8(Block_Type.Log) || b == u8(Block_Type.Spruce_Log) || b == u8(Block_Type.Birch_Log) || b == u8(Block_Type.Acacia_Log)
}

// The voxel world: the resident columns, and which have edits saved. Only
// voxels, nothing of the GPU. The server keeps one around its players
// (server_world.odin), saved; each client one around itself, binding its
// columns to ring slots (gpu_chunk_owner), never saved. Game_State embeds
// the client's (`using voxels`), so a ^Game_State passes as a ^World.
World :: struct {
    columns:       map[[2]int]^Column,
    saved_columns: map[[2]int]bool, // columns with a save file (save.odin)
    save_enabled:  bool,            // edits are saved: only the server's world, and not in benches
}

// One 8x8x8 chunk. Uniform chunks (all air, all stone) keep no voxel array.
Chunk :: struct {
    voxels:     ^[VOXELS_PER_BRICK]u8, // nil = every voxel is `fill`
    fill:       u8,
    light:      ^[VOXELS_PER_BRICK]u16, // nil = all light_fill (light.odin)
    light_fill: u16,
}

// All CHUNKS_H chunks of one 8x8 footprint: the unit of generation,
// streaming and saving. World.columns holds exactly the resident columns.
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
world_chunk :: proc(w: ^World, key: [3]int) -> ^Chunk {
    iy := chunk_y_index(key.y)
    if iy < 0 { return nil }
    col := w.columns[{key.x, key.z}]
    return col == nil ? nil : &col.chunks[iy]
}

// The resident chunk a ring slot currently holds, or nil.
slot_chunk :: proc(gs: ^Game_State, slot: int) -> ^Chunk {
    owner := gs.gpu_chunk_owner[slot]
    if owner[0] == 0x7fffffff { return nil }
    return world_chunk(gs, {int(owner[0]), (slot / CHUNKS_W) % CHUNKS_H + WORLD_CHUNK_Y_MIN, int(owner[1])})
}

LOAD_RADIUS_XZ  :: 56   // must stay < CHUNKS_W/2 (=64) so a chunk and its ring-twin never coexist

// Columns loaded around the player (the options' view distance), at most
// LOAD_RADIUS_XZ; the far terrain stands in past it. Read by the workers.
view_radius: int = LOAD_RADIUS_XZ
VIEW_RADII :: [3]int{24, 40, LOAD_RADIUS_XZ} // Short, Medium, Far

// A new view distance: what's now beyond it goes (with a margin, so turning
// it down doesn't stutter on the edge), what's within comes in.
set_view_radius :: proc(gs: ^Game_State, r: int) {
    r := clamp(r, 8, LOAD_RADIUS_XZ)
    if r == view_radius { return }
    sync.atomic_store(&view_radius, r)
    enqueue_chunks(gs)
    gpu_resize_pools(gs) // after what's now too far was dropped
}

// Cave band. Below CAVE_FLOOR_Y everything is solid stone via the no-noise
// fast path. Caves are carved by a 3D noise lobe only between CAVE_FLOOR_Y
// and (surface - CAVE_TOP_MARGIN). Keeping the floor shallow (-64 vs the old
// -224) is the dominant generation-cost lever: the proven ~92%-of-fill cave
// 3D-noise now runs over a ~160-voxel band instead of ~320, ~halving it,
// with zero new control flow / streaming risk. Deep digging hits solid stone
// below -64 (acceptable; deeper caves would need on-demand vertical gen).
CAVE_FLOOR_Y    :: -104         // = world_h(-61)
CAVE_CEIL_Y     :: 153          // = world_h(110): mountains are solid above this (ravines still cut in)
CAVE_TOP_MARGIN :: 9            // keep caves this far below the surface

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
PLANE_SLOTS :: CHUNKS_W * CHUNKS_H // ring slots per Z-plane (slot / PLANE_SLOTS = sz)

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
    pool_init(&gs.brick_pool, brick_cap_for(view_radius))
    pool_init(&gs.light_pool, light_cap_for(view_radius))

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
        client_pump(gs) // edited columns come from the server
        integrate_ready_chunks(gs)
        stitch_pending_columns(gs)
        if streaming_idle(gs) && len(gs.net.requested) == 0 { break }
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
            if key in gs.net.edited {
                client_request_column(gs, key) // the server's, not generated
                continue
            }
            worker_pool_enqueue(&gs.pool, key, key in gs.saved_columns) // saved: a bench given world= (the game's server loads its own)
        }
    }
}

enqueue_chunks :: proc(gs: ^Game_State) {
    r := view_radius
    enqueue_radius(gs, r)
    if r < LOAD_RADIUS_XZ {
        // Shorter than the ring holds: what's fallen behind goes (with a
        // margin, so moving about the edge doesn't load and drop columns).
        drop := make([dynamic][2]int, context.temp_allocator)
        pc := [2]int{gs.player_chunk.x, gs.player_chunk.z}
        for key in gs.columns {
            d := key - pc
            if d.x * d.x + d.y * d.y > (r + 2) * (r + 2) { append(&drop, key) }
        }
        for key in drop { unload_column(gs, key) }
    }
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
            if idx < 0 { // renders as air until a brick frees up (flush_voxel_uploads retries)
                pool_exhaustion_warn()
                append(&gs.brick_starved, slot)
            }
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
    gs.owner_planes[ring_slot(key.x, WORLD_CHUNK_Y_MIN, key.y) / PLANE_SLOTS] = true
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
    plane := ring_slot(key.x, WORLD_CHUNK_Y_MIN, key.y) / PLANE_SLOTS
    gs.owner_planes[plane] = true
    gs.light_planes[plane] = true
    delete_key(&gs.columns, key)
    worker_pool_unqueue(&gs.pool, key)
    // Gone, so nothing to stitch: it's queued again if it comes back
    // (left in, the queue only grew as you flew).
    for k, i in gs.stitch_queue {
        if k == key { unordered_remove(&gs.stitch_queue, i); break }
    }
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
        if r.key in gs.net.edited {
            // Edited on the server while it generated: the server's it is.
            column_free(r.column)
            client_request_column(gs, r.key)
            continue
        }
        integrate_column(gs, r.key, r.column)
    }
    profile_add(.Integrate, t_int)
}

// Main-thread time per frame for stitching light between columns; a spike in
// frame time would be seen.
LIGHT_STITCH_BUDGET :: 1500 * time.Microsecond
LIGHT_STITCH_NEAR_BUDGET :: 4000 * time.Microsecond // while columns this near are waiting
LIGHT_STITCH_NEAR :: 10 // chunk columns (~50 m)

// Nearest the player first. Flying fast queues columns faster than the
// budget stitches them (over a minute's backlog), and in arrival order the
// ground underfoot came last: light that should cross a column border
// (into a cave or a ravine wall) was missing there for a long time, dark
// patches that only a reload fixed. Stitching only adds light, so the order
// doesn't change the result.
stitch_pending_columns :: proc(gs: ^Game_State) {
    start := time.tick_now()
    me := [2]int{gs.player_chunk.x, gs.player_chunk.z}
    for len(gs.stitch_queue) > 0 {
        best, best_d := 0, max(int)
        for k, i in gs.stitch_queue {
            d := k - me
            if dd := d.x * d.x + d.y * d.y; dd < best_d { best, best_d = i, dd }
        }
        // Columns around the player get more of the frame (what's in view
        // up close); the rest wait for the plain budget.
        budget := best_d <= LIGHT_STITCH_NEAR * LIGHT_STITCH_NEAR ? LIGHT_STITCH_NEAR_BUDGET : LIGHT_STITCH_BUDGET
        if time.tick_since(start) >= budget { break }
        c := gs.stitch_queue[best]
        unordered_remove(&gs.stitch_queue, best)
        light_stitch_column(gs, c[0], c[1])
    }
}

// Stitch now any queued columns touching the chunk-column box [lo, hi]
// (grown by one): an edit relights against its neighbours, so they must be
// settled first.
stitch_columns_near :: proc(gs: ^Game_State, lo, hi: [2]int) {
    for i := len(gs.stitch_queue) - 1; i >= 0; i -= 1 {
        k := gs.stitch_queue[i]
        if k.x < lo.x - 1 || k.x > hi.x + 1 || k.y < lo.y - 1 || k.y > hi.y + 1 { continue }
        unordered_remove(&gs.stitch_queue, i)
        light_stitch_column(gs, k.x, k.y)
    }
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
    seas: [N]Sea_Kind
    plants: [N]Block_Type
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
            seas[i] = sea_kind(s)
            plants[i] = ground_plant(s, layers[i].top, gx + x, gz + z)
            surf_min = min(surf_min, s.height)
            surf_max = max(surf_max, s.height)
            deep_min = min(deep_min, s.height - layers[i].filler_depth)
        }
    }
    top_max := (surf_min < SEA_LEVEL ? max(surf_max, SEA_LEVEL) : surf_max) + 1 // and the plants on top
    // Caves: where tunnels may come up to the surface, and the noise over
    // the column's cave band (caves.odin).
    entrance: [N]bool
    cave_hi := CAVE_FLOOR_Y
    any_entrance := false
    for i in 0 ..< N {
        h := height[i]
        entrance[i] = cave_entrance(gx + i % CHUNK_VOXELS, gz + i / CHUNK_VOXELS, h)
        any_entrance ||= entrance[i]
        cave_hi = max(cave_hi, entrance[i] ? h : min(h - CAVE_TOP_MARGIN, CAVE_CEIL_Y))
    }
    caves := new(Cave_Field, context.temp_allocator)
    cave_field_make(caves, gx, gz, CAVE_FLOOR_Y, cave_hi)
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
        if gy1 <= deep_min && (gy1 <= CAVE_FLOOR_Y || gy >= CAVE_CEIL_Y && !any_entrance) {
            chunk.fill = u8(Block_Type.Stone)
            continue
        }
        chunk.voxels = new([VOXELS_PER_BRICK]u8)
        hollow := !cave_chunk_closed(caves, gy) // else no cave reaches into this chunk

        for z in 0 ..< CHUNK_VOXELS {
            for x in 0 ..< CHUNK_VOXELS {
                ci := x + z * CHUNK_VOXELS
                h  := height[ci]
                l  := layers[ci]
                cave_top := min(h - CAVE_TOP_MARGIN, CAVE_CEIL_Y)
                open_to := entrance[ci] ? h : cave_top // tunnels up to here
                for y in 0 ..< CHUNK_VOXELS {
                    wy := gy + y
                    b: Block_Type
                    switch {
                    case wy >= h:
                        if wy < SEA_LEVEL {
                            b = l.frozen && wy == SEA_LEVEL - 1 ? .Ice : .Water
                        } else if wy == h && !(entrance[ci] && cave_open(caves, x, h - 1, z, true)) {
                            b = plants[ci]
                        }
                    case hollow && wy > CAVE_FLOOR_Y && wy < open_to && cave_open(caves, x, wy, z, wy >= cave_top):
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
    decorate_caves(column, gx, gz, height[:])
    decorate_cave_life(column, gx, gz, height[:])
    decorate_ocean(column, gx, gz, height[:], seas[:])
    generate_landmarks(&tgt)
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
    design:   ^Landmark_Design, // or a landmark being built at its design size (landmarks.odin)
}

// Max horizontal voxel reach of a tree from its base (trunk wander + branch +
// crown): branch_len 18 + sub_len 10 + crown radius 16 ≈ 44. Round up.
TREE_VOXEL_REACH :: 48

set_voxel_world :: proc(t: ^Tree_Target, wx, wy, wz: int, block: Block_Type) {
    if t.design != nil { design_put(t.design, wx, wy, wz, block); return }
    lx := wx - t.ox; lz := wz - t.oz
    if lx < 0 || lx >= t.size || lz < 0 || lz >= t.size { return }
    if t.far != nil { far_record(t.far, lx, wy, lz, u8(block)); return }
    if c, vi, ok := column_voxel(t.col, lx, wy, lz); ok { chunk_set_voxel(c, vi, u8(block)) }
}

// The chunk of a column holding voxel (lx, wy, lz), and its index there:
// false above or below the world.
column_voxel :: proc(col: ^Column, lx, wy, lz: int) -> (c: ^Chunk, vi: int, ok: bool) {
    wcy := floor_div(wy, CHUNK_VOXELS)
    iy  := chunk_y_index(wcy)
    if iy < 0 { return }
    ly := wy - wcy * CHUNK_VOXELS
    return &col.chunks[iy], lx + ly*CHUNK_VOXELS + lz*CHUNK_VOXELS*CHUNK_VOXELS, true
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
    if lx < 0 || lx >= t.size || lz < 0 || lz >= t.size { return }
    if t.far != nil { far_record(t.far, lx, wy, lz, u8(block)); return }
    c, vi, ok := column_voxel(t.col, lx, wy, lz)
    if !ok { return }
    if v := chunk_voxel(c, vi); v == 0 || block_is_leaves(v) { chunk_set_voxel(c, vi, u8(block)) }
}

// Fill a filled circle of logs at height wy, centred on (cx, cz) with given radius.
// noise_amt adds per-voxel hash-based edge roughness.
fill_trunk_slice :: proc(t: ^Tree_Target, cx, cz: f64, wy: int, radius: f64, seed: int, log := Block_Type.Log) {
    ir := int(math.ceil(radius)) + 1
    for dz in -ir ..= ir {
        for dx in -ir ..= ir {
            wx := int(math.round(cx)) + dx
            wz := int(math.round(cz)) + dz
            // Wobble the boundary with a per-voxel hash so the edge is ragged.
            wobble := tree_hash(wx, wz, seed) * 1.2 - 0.2
            r2 := f64(dx*dx + dz*dz)
            if r2 <= (radius + wobble) * (radius + wobble) {
                set_voxel_world(t, wx, wy, wz, log)
            }
        }
    }
}

// Draw a thick branch as a series of circular slices between two points.
// start_r and end_r are the radius at each endpoint.
draw_thick_segment :: proc(tgt: ^Tree_Target,
    ax, ay, az, bx, by, bz: f64,
    start_r, end_r: f64, seed: int, log := Block_Type.Log) {
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
        fill_trunk_slice(tgt, px, pz, wy, r, seed + i, log)
    }
}

// Place an ellipsoidal crown of leaves centred at (cx, cy, cz).
// rx, ry, rz are the radii on each axis.
place_crown :: proc(tgt: ^Tree_Target, cx, cy, cz: f64, rx, ry, rz: f64, seed: int, leaves := Block_Type.Leaves) {
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
                        int(math.round(cz)) + dz, leaves)
                }
            }
        }
    }
}

generate_tree :: proc(tgt: ^Tree_Target, bx, by, bz: int, rng_seed: int) {
    leaves := tree_leaves(bx, bz, .Leaves)
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
                rng_seed + b*111 + s*55, leaves)
        }
    }

    // Main crown: large ellipsoid centred above the trunk tip.
    tip_x := spine_x[2]; tip_y := spine_y[2]; tip_z := spine_z[2]
    crown_r  := next(&rng, 10, 16)
    crown_ry := next(&rng, 7, 11)
    place_crown(tgt, tip_x, tip_y, tip_z, crown_r, crown_ry, crown_r, rng_seed + 9999, leaves)
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
    case .Medium_Oak: generate_medium_oak(tgt, bx, by, bz, seed)
    case .Birch:     generate_birch(tgt, bx, by, bz, seed)
    case .Dead:      generate_dead_tree(tgt, bx, by, bz, seed)
    case .Fallen_Log: generate_fallen_log(tgt, bx, by, bz, seed)
    case .Acacia:    generate_acacia(tgt, bx, by, bz, seed)
    case .Boulder:   generate_boulder(tgt, bx, by, bz, seed)
    case .Willow:    generate_willow(tgt, bx, by, bz, seed)
    }
}

// Acacia: a leaning trunk that forks into two or three limbs, each under a
// flat, wide umbrella of leaves.
generate_acacia :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 22, by, bz - 22, bx + 23, by + 26, bz + 23) { return }
    rng := seed
    h := tree_rand(&rng, 6, 9)
    lean := tree_rand(&rng, 0, math.TAU)
    cx, cz := f64(bx) + 0.5, f64(bz) + 0.5
    fx, fz := cx + math.cos(lean) * 2, cz + math.sin(lean) * 2
    draw_thick_segment(tgt, cx, f64(by), cz, fx, f64(by) + h, fz, 1.0, 0.8, seed, .Acacia_Log)
    // Limbs reach out wide and end about level, so their canopies join into
    // one flat top with the trunk standing clear under it.
    top := f64(by) + h + tree_rand(&rng, 3, 5)
    n := tree_rand(&rng, 0, 1) < 0.5 ? 2 : 3
    for i in 0 ..< n {
        a := lean + f64(i) / f64(n) * math.TAU + tree_rand(&rng, -0.5, 0.5)
        l := tree_rand(&rng, 5, 8)
        ex, ey, ez := fx + math.cos(a) * l, top + tree_rand(&rng, -1, 1), fz + math.sin(a) * l
        draw_thick_segment(tgt, fx, f64(by) + h, fz, ex, ey, ez, 0.7, 0.45, seed + 3 + i, .Acacia_Log)
        r := tree_rand(&rng, 5, 7)
        place_crown(tgt, ex, ey + 1, ez, r, tree_rand(&rng, 1.2, 1.6), r, seed + 9 + i, .Acacia_Leaves)
    }
    place_crown(tgt, fx, top + 1.5, fz, tree_rand(&rng, 6, 8), 1.4, tree_rand(&rng, 6, 8), seed + 2, .Acacia_Leaves)
}

// A boulder: a lumpy rock half sunk in the ground (weathered stone, so the
// shader mosses its lower sides), now and then with a smaller one leaning
// on it.
generate_boulder :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 9, by - 4, bz - 9, bx + 10, by + 10, bz + 10) { return }
    rng := seed
    n := tree_rand(&rng, 0, 1) < 0.3 ? 2 : 1
    for k in 0 ..< n {
        r := tree_rand(&rng, 1.8, 4.2) * (k > 0 ? 0.6 : 1)
        cx := f64(bx) + 0.5 + (k > 0 ? tree_rand(&rng, -1, 1) * r * 2.2 : 0)
        cz := f64(bz) + 0.5 + (k > 0 ? tree_rand(&rng, -1, 1) * r * 2.2 : 0)
        cy := f64(by) + r * 0.25
        sx, sy := tree_rand(&rng, 0.8, 1.3), tree_rand(&rng, 0.6, 0.9)
        ir := int(math.ceil(r * 1.4)) + 1
        for dy in -ir ..= ir {
            for dz in -ir ..= ir {
                for dx in -ir ..= ir {
                    x, y, z := int(math.floor(cx)) + dx, int(math.floor(cy)) + dy, int(math.floor(cz)) + dz
                    fx := (f64(x) + 0.5 - cx) / (r * sx)
                    fy := (f64(y) + 0.5 - cy) / (r * sy)
                    fz := (f64(z) + 0.5 - cz) / r
                    lump := tree_hash(x, z + y * 31, seed + 7) * 0.35
                    if fx * fx + fy * fy + fz * fz <= 1 + lump - 0.15 { set_voxel_world(tgt, x, y, z, .Weathered_Stone) }
                }
            }
        }
    }
}

// Willow, by the water: a stout trunk, limbs spreading under a broad crown,
// and long strands of leaves hanging from it almost to the ground.
generate_willow :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 20, by - 2, bz - 20, bx + 21, by + 26, bz + 21) { return }
    rng := seed
    h := tree_rand(&rng, 6, 9)
    cx, cz := f64(bx) + 1, f64(bz) + 1
    draw_thick_segment(tgt, cx, f64(by), cz, cx, f64(by) + h, cz, 1.7, 1.2, seed)
    n := int(tree_rand(&rng, 4, 7))
    a0 := tree_rand(&rng, 0, math.TAU)
    for i in 0 ..< n {
        a := a0 + f64(i) / f64(n) * math.TAU + tree_rand(&rng, -0.3, 0.3)
        l := tree_rand(&rng, 5, 8)
        ex, ey, ez := cx + math.cos(a) * l, f64(by) + h + l * tree_rand(&rng, 0.5, 0.9), cz + math.sin(a) * l
        draw_thick_segment(tgt, cx, f64(by) + h - 1, cz, ex, ey, ez, 1.0, 0.5, seed + 5 + i)
        r := tree_rand(&rng, 4, 5.5)
        place_crown(tgt, ex, ey + 1, ez, r, r * 0.6, r, seed + 15 + i, .Willow_Leaves)
        // Strands down from the crown's underside and rim.
        for k in 0 ..< 14 {
            sa := tree_rand(&rng, 0, math.TAU)
            sr := r * math.sqrt(tree_rand(&rng, 0.3, 1.0))
            sx := int(math.floor(ex + math.cos(sa) * sr))
            sz := int(math.floor(ez + math.sin(sa) * sr))
            top := int(math.floor(ey + 1 - r * 0.45))
            for y in 0 ..< int(tree_rand(&rng, 5, 12)) { place_leaves(tgt, sx, top - y, sz, .Willow_Leaves) }
            _ = k
        }
    }
    place_crown(tgt, cx, f64(by) + h + 3, cz, 4.5, 3, 4.5, seed + 2, .Willow_Leaves)
}

// What grows on the ground at (wx, wz): grass tufts, ferns, flowers in
// patches, dry bushes in the desert; nothing on bare or frozen ground.
ground_plant :: proc(s: Terrain_Sample, top: Block_Type, wx, wz: int) -> Block_Type {
    if s.height < SEA_LEVEL + 1 { return .Air }
    h := tree_hash(wx, wz, 71)
    if top == .Sand || top == .Red_Sand {
        return (s.biome == .Desert || s.biome == .Badlands) && h < 0.012 ? .Dry_Bush : .Air
    }
    if top != .Grass && top != .Dry_Grass { return .Air }
    p := [2]f64{f64(wx), f64(wz)}
    flowers := n2(72, p / (40 * TERRAIN_SCALE)) > 0.45 ? 0.22 : 0.012 // meadows in patches
    #partial switch s.biome {
    case .Plains:
        if h < flowers { return .Flower }
        if h < flowers + 0.30 { return .Tall_Grass }
    case .Savanna:
        if h < 0.006 { return .Dry_Bush }
        if h < 0.38 { return .Tall_Grass }
    case .Forest:
        if h < flowers * 0.4 { return .Flower }
        if h < flowers * 0.4 + 0.012 { return .Mushroom }
        if h < 0.10 { return .Fern }
        if h < 0.22 { return .Tall_Grass }
    case .Taiga:
        if h < 0.01 { return .Mushroom }
        if h < 0.12 { return .Fern }
        if h < 0.17 { return .Tall_Grass }
    case .Mountains:
        if h < flowers * 0.5 { return .Flower }
        if h < 0.12 { return .Tall_Grass }
    }
    return .Air
}

// Broadleaf trees in an autumn patch of forest turn: most of them, so a
// patch reads as a whole but isn't uniform.
@(private="file")
tree_leaves :: proc(bx, bz: int, green: Block_Type) -> Block_Type {
    p := [2]f64{f64(bx), f64(bz)} / (420 * TERRAIN_SCALE)
    if n2(61, p) > 0.32 && tree_hash(bx, bz, 62) < 0.85 { return .Autumn_Leaves }
    return green
}

// Between the small oak and the giant: a short thick trunk forking into a
// few limbs under a crown of several lumps.
generate_medium_oak :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 16, by, bz - 16, bx + 17, by + 32, bz + 17) { return }
    rng := seed
    leaves := tree_leaves(bx, bz, .Leaves)
    h := tree_rand(&rng, 9, 15)
    cx, cz := f64(bx) + 1, f64(bz) + 1
    lean := [2]f64{tree_rand(&rng, -1.5, 1.5), tree_rand(&rng, -1.5, 1.5)}
    draw_thick_segment(tgt, cx, f64(by), cz, cx + lean.x, f64(by) + h, cz + lean.y, 1.6, 1.0, seed)
    top := [3]f64{cx + lean.x, f64(by) + h, cz + lean.y}
    // The crown's lumps sit on the ends of the limbs and over the top.
    place_crown(tgt, top.x, top.y + 2, top.z, tree_rand(&rng, 4.5, 6), tree_rand(&rng, 3.5, 4.5), tree_rand(&rng, 4.5, 6), seed + 1, leaves)
    n := int(tree_rand(&rng, 3, 6))
    a0 := tree_rand(&rng, 0, math.TAU)
    for i in 0 ..< n {
        a := a0 + f64(i) / f64(n) * math.TAU + tree_rand(&rng, -0.4, 0.4)
        from := tree_rand(&rng, 0.55, 0.85) * h
        l := tree_rand(&rng, 5, 9)
        sx, sy, sz := cx + lean.x * from / h, f64(by) + from, cz + lean.y * from / h
        ex, ey, ez := sx + math.cos(a) * l, sy + l * tree_rand(&rng, 0.4, 0.8), sz + math.sin(a) * l
        draw_thick_segment(tgt, sx, sy, sz, ex, ey, ez, 0.9, 0.5, seed + 10 + i)
        r := tree_rand(&rng, 3.5, 5)
        place_crown(tgt, ex, ey + 1, ez, r, r * 0.75, r, seed + 20 + i, leaves)
    }
}

// Birch: a tall thin white trunk under a narrow crown; often in twos or
// threes from one spot.
generate_birch :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 9, by, bz - 9, bx + 10, by + 34, bz + 10) { return }
    rng := seed
    leaves := tree_leaves(bx, bz, .Birch_Leaves)
    stems := tree_rand(&rng, 0, 1) < 0.35 ? int(tree_rand(&rng, 2, 4)) : 1
    for k in 0 ..< stems {
        ox, oz := 0, 0
        if k > 0 { ox, oz = int(tree_rand(&rng, -3, 4)), int(tree_rand(&rng, -3, 4)) }
        h := int(tree_rand(&rng, 14, 24) * (k > 0 ? 0.8 : 1))
        x, z := bx + ox, bz + oz
        for y in 0 ..< h { set_voxel_world(tgt, x, by + y, z, .Birch_Log) }
        // A twig or two sticking out of the bark.
        for _ in 0 ..< 2 {
            ty := by + int(tree_rand(&rng, 0.4, 0.7) * f64(h))
            d := int(tree_rand(&rng, 0, 4))
            DX :: [4]int{1, -1, 0, 0}
            DZ :: [4]int{0, 0, 1, -1}
            dxs, dzs := DX, DZ
            dx, dz := dxs[d], dzs[d]
            set_voxel_world(tgt, x + dx, ty, z + dz, .Birch_Log)
        }
        r := tree_rand(&rng, 2.6, 3.6)
        ry := tree_rand(&rng, 5, 7)
        place_crown(tgt, f64(x), f64(by + h) - ry * 0.45, f64(z), r, ry, r, seed + 31 + k, leaves)
        place_crown(tgt, f64(x) + tree_rand(&rng, -1.5, 1.5), f64(by + h) - ry * 1.1, f64(z) + tree_rand(&rng, -1.5, 1.5), r * 0.8, ry * 0.45, r * 0.8, seed + 41 + k, leaves)
    }
}

// A dead tree: a bare grey-brown trunk with a few broken limbs.
generate_dead_tree :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 9, by, bz - 9, bx + 10, by + 24, bz + 10) { return }
    rng := seed
    h := tree_rand(&rng, 7, 15)
    cx, cz := f64(bx) + 0.5, f64(bz) + 0.5
    lean := [2]f64{tree_rand(&rng, -2, 2), tree_rand(&rng, -2, 2)}
    draw_thick_segment(tgt, cx, f64(by), cz, cx + lean.x, f64(by) + h, cz + lean.y, h > 11 ? 1.0 : 0.6, 0.45, seed)
    for i in 0 ..< int(tree_rand(&rng, 2, 4)) {
        a := tree_rand(&rng, 0, math.TAU)
        from := tree_rand(&rng, 0.45, 0.9) * h
        l := tree_rand(&rng, 3, 7)
        sx, sy, sz := cx + lean.x * from / h, f64(by) + from, cz + lean.y * from / h
        draw_thick_segment(tgt, sx, sy, sz, sx + math.cos(a) * l, sy + l * tree_rand(&rng, 0.3, 0.9), sz + math.sin(a) * l, 0.45, 0.3, seed + 5 + i)
    }
}

// A trunk lying on the forest floor, its root end a broken stump.
generate_fallen_log :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 15, by, bz - 15, bx + 16, by + 4, bz + 16) { return }
    rng := seed
    a := tree_rand(&rng, 0, math.TAU)
    l := tree_rand(&rng, 7, 14)
    thick := tree_rand(&rng, 0, 1) < 0.4
    log: Block_Type = tree_rand(&rng, 0, 1) < 0.3 ? .Birch_Log : .Log
    dx, dz := math.cos(a), math.sin(a)
    for i in 0 ..= int(l * 2) {
        s := f64(i) * 0.5 + 2
        x := int(math.floor(f64(bx) + 0.5 + dx * s))
        z := int(math.floor(f64(bz) + 0.5 + dz * s))
        g := surface_height_at(x, z)
        if abs(g - by) > 2 { break } // over an edge: it broke off here
        set_voxel_world(tgt, x, g, z, log)
        if thick {
            set_voxel_world(tgt, x, g + 1, z, log)
            set_voxel_world(tgt, x + int(math.round(-dz)), g, z + int(math.round(dx)), log)
        }
    }
    for y in 0 ..< (thick ? 3 : 2) { set_voxel_world(tgt, bx, by + y, bz, log) }
}

@(private="file")
tree_rand :: proc(rng: ^int, lo, hi: f64) -> f64 {
    rng^ += 1
    return lo + tree_hash(rng^, rng^ * 7, 13) * (hi - lo)
}

// A small oak: a thin trunk and a lumpy round crown.
generate_small_oak :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 9, by, bz - 9, bx + 9, by + 24, bz + 9) { return }
    rng := seed
    h := int(tree_rand(&rng, 8, 14))
    thick := tree_rand(&rng, 0, 1) < 0.5
    for y in 0 ..< h {
        set_voxel_world(tgt, bx, by + y, bz, .Log)
        if thick && y < h - 2 { set_voxel_world(tgt, bx + 1, by + y, bz, .Log); set_voxel_world(tgt, bx, by + y, bz + 1, .Log); set_voxel_world(tgt, bx + 1, by + y, bz + 1, .Log) }
    }
    r := tree_rand(&rng, 3.9, 5.4)
    leaves := tree_leaves(bx, bz, .Leaves)
    place_crown(tgt, f64(bx), f64(by + h), f64(bz), r, r * 0.8, r, seed + 5, leaves)
    place_crown(tgt, f64(bx) + tree_rand(&rng, -2.2, 2.2), f64(by + h) - 2.2, f64(bz) + tree_rand(&rng, -2.2, 2.2),
                r * 0.8, r * 0.6, r * 0.8, seed + 6, leaves)
}

// A low leafy clump around a stub of trunk.
generate_bush :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 6, by, bz - 6, bx + 6, by + 6, bz + 6) { return }
    rng := seed
    set_voxel_world(tgt, bx, by, bz, .Log)
    r := tree_rand(&rng, 2.4, 3.6)
    place_crown(tgt, f64(bx), f64(by) + 1.2, f64(bz), r, r * 0.65, r, seed + 3)
}

// Spruce: a straight trunk (2x2 when tall) under tiers of needles that
// narrow toward a pointed top.
generate_spruce :: proc(tgt: ^Tree_Target, bx, by, bz: int, seed: int) {
    if !aabb_hits_chunk(tgt, bx - 10, by, bz - 10, bx + 11, by + 42, bz + 11) { return }
    rng := seed
    h := int(tree_rand(&rng, 13, 36))
    thick := h >= 22
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
    y0   := by + int(tree_rand(&rng, 3, 6))
    top  := by + h + 1
    rmax := tree_rand(&rng, 4.8, 6.3) + (thick ? 2.0 : 0)
    tier := tree_rand(&rng, 3.9, 5.4)
    for y in y0 ..= top {
        f := f64(y - y0) / f64(top - y0)   // 0 at the lowest tier .. 1 at the tip
        k := f64(top - y) / tier
        in_tier := k - math.floor(k)       // 0 at a tier's top .. 1 at its flared base
        r  := rmax * (1 - f) * (0.55 + 0.45 * in_tier) + (thick ? 1.4 : 0.9)
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
    if !aabb_hits_chunk(tgt, bx - 4, by, bz - 4, bx + 4, by + 12, bz + 4) { return }
    rng := seed
    h := int(tree_rand(&rng, 5, 11))
    for y in 0 ..< h { set_voxel_world(tgt, bx, by + y, bz, .Cactus) }
    DIRS :: [4][2]int{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
    dirs := DIRS
    first := int(tree_rand(&rng, 0, 4))
    for a in 0 ..< 2 {
        if h < 4 || tree_rand(&rng, 0, 1) < 0.5 { continue }
        d := dirs[(first + a * 2) & 3] // arms on opposite sides
        ay := by + int(tree_rand(&rng, 1, f64(h - 2)))
        set_voxel_world(tgt, bx + d.x, ay, bz + d.y, .Cactus)
        arm := int(tree_rand(&rng, 2, 5))
        for y in 0 ..= arm { set_voxel_world(tgt, bx + 2*d.x, ay + y, bz + 2*d.y, .Cactus) }
    }
}

// True if the voxel blocks movement (water does not).
solid_at :: proc(w: ^World, wx, wy, wz: int) -> bool {
    return block_solid(u8(get_voxel(w, wx, wy, wz)))
}

// The block at a point (the voxel it lies in).
voxel_at :: proc(w: ^World, p: [3]f32) -> Block_Type {
    return Block_Type(u8(get_voxel(w, int(math.floor(p.x)), int(math.floor(p.y)), int(math.floor(p.z)))))
}

get_voxel :: proc(w: ^World, wx, wy, wz: int) -> u32 {
    c := world_chunk(w, {wx >> 3, wy >> 3, wz >> 3}) // CHUNK_VOXELS == 8
    if c == nil { return 0 }
    return u32(chunk_voxel(c, (wx & 7) + (wy & 7) * CHUNK_VOXELS + (wz & 7) * CHUNK_VOXELS * CHUNK_VOXELS))
}

// CPU-side DDA raycast — mirrors the shader's two-level traversal.
// Returns the integer world position of the hit voxel and the surface normal.
// plants: stop at grass, flowers and such too (aiming the block tool at one).
raycast_voxel :: proc(w: ^World, origin, dir: [3]f32, max_dist: f32, plants := false) -> (hit_pos: [3]int, normal: [3]int, ok: bool) {
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
        v := u8(get_voxel(w, xi, yi, zi))
        if block_is_door(v) {
            // Only its panel: an open door's way through is open.
            q0 := [3]f32{f32(ox - f64(xi) + f64(dx) * t), f32(oy - f64(yi) + f64(dy) * t), f32(oz - f64(zi) + f64(dz) * t)}
            span := f32(min(t_max_x, t_max_y, t_max_z) - t)
            if _, n, ok := door_ray(v, q0, dir, span); ok {
                return {xi, yi, zi}, n == {} ? [3]int{nx, ny, nz} : n, true
            }
        } else if block_solid(v) || plants && block_is_land_plant(v) {
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
    // Flood from the dug voxels water already touches; most edits have none.
    queue := make([dynamic][3]int, context.temp_allocator)
    for p in dug {
        if get_voxel(gs, p.x, p.y, p.z) != 0 { continue }
        for d in feeds {
            q := p + d
            if get_voxel(gs, q.x, q.y, q.z) == water { append(&queue, p); break }
        }
    }
    if len(queue) == 0 { return }
    // Which voxels were dug: a bit per voxel of their bounding box.
    lo, hi := dug[0], dug[0]
    for p in dug { lo, hi = la.min(lo, p), la.max(hi, p) }
    size := hi - lo + 1
    bits := make([]u64, (size.x * size.y * size.z + 63) / 64, context.temp_allocator)
    bit :: #force_inline proc(q, lo, size: [3]int) -> int {
        o := q - lo
        if o.x < 0 || o.y < 0 || o.z < 0 || o.x >= size.x || o.y >= size.y || o.z >= size.z { return -1 }
        return o.x + (o.y + o.z * size.y) * size.x
    }
    for p in dug { k := bit(p, lo, size); bits[k >> 6] |= 1 << uint(k & 63) }
    // Water spreads sideways and down, so from p into p - feed.
    for i := 0; i < len(queue); i += 1 {
        p := queue[i]
        if get_voxel(gs, p.x, p.y, p.z) != 0 { continue }
        col := gs.columns[{p.x >> 3, p.z >> 3}] // CHUNK_VOXELS == 8
        chunk_set_voxel(&col.chunks[chunk_y_index(p.y >> 3)],
                        (p.x & 7) + (p.y & 7) * CHUNK_VOXELS + (p.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS, u8(water))
        for d in feeds {
            q := p - d
            k := bit(q, lo, size)
            if k >= 0 && bits[k >> 6] & (1 << uint(k & 63)) != 0 && get_voxel(gs, q.x, q.y, q.z) == 0 { append(&queue, q) }
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
    r := view_radius
    for o in g_load_offsets {
        if o.x * o.x + o.y * o.y > r * r { return r }
        x, z := pc.x + o.x, pc.y + o.y
        owner := gs.gpu_chunk_owner[ring_slot(x, WORLD_CHUNK_Y_MIN, z)]
        if int(owner[0]) != x || int(owner[1]) != z {
            // Largest whole radius strictly inside the first missing column.
            return max(int(math.ceil(math.sqrt(f64(o.x*o.x + o.y*o.y)))) - 1, 0)
        }
    }
    return LOAD_RADIUS_XZ
}
