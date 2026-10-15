package main

import "core:time"

// Minecraft-style voxel light, computed on the CPU and sampled by the shader
// instead of tracing light rays. Every non-opaque voxel stores one byte:
// high nibble = sky light (0..15), low nibble = block light (0..15, torches).
//
// Sky light: 15 straight down through open air from the top of the world,
// then flood-filled sideways/down, losing 1 per voxel (leaves stop the
// straight-down rule, so canopies shade the ground below; water also lets
// sky light in, losing 1 per voxel of depth). Block light:
// flood-filled from emitters (torches = TORCH_LIGHT), losing 1 per voxel.
// Opaque blocks never hold light.
//
// Flow: the worker computes a column's light on its own (light_column_compute).
// The main thread then stitches it to already-loaded neighbour columns
// (light_stitch_column) and relights around block edits (light_on_edit).

LIGHT_MAX   :: 15
TORCH_LIGHT :: 14
CRYSTAL_LIGHT :: 9
LIGHT_SKY   :: u8(LIGHT_MAX << 4) // full sky, no block light

Light_Channel :: enum { Sky, Block }

block_opaque :: #force_inline proc(b: u8) -> bool {
    return b != u8(Block_Type.Air) && !block_is_leaves(b) && b != u8(Block_Type.Water)
}

block_emission :: #force_inline proc(b: u8) -> u8 {
    if b == u8(Block_Type.Torch)   { return TORCH_LIGHT }
    if b == u8(Block_Type.Crystal) { return CRYSTAL_LIGHT }
    return 0
}

chan_get :: #force_inline proc(v: u8, ch: Light_Channel) -> u8 {
    return ch == .Sky ? v >> 4 : v & 0x0F
}

chan_set :: #force_inline proc(v: u8, ch: Light_Channel, l: u8) -> u8 {
    return ch == .Sky ? (v & 0x0F) | (l << 4) : (v & 0xF0) | l
}

// Light of the voxel a light level `l` spreads into from direction `d`
// (index into NEIGHBOURS). Sky light keeps full strength going straight down
// through air.
spread_level :: #force_inline proc(l: u8, ch: Light_Channel, d: int, into: u8) -> u8 {
    if ch == .Sky && d == DIR_DOWN && l == LIGHT_MAX && into == u8(Block_Type.Air) {
        return LIGHT_MAX
    }
    return l > 0 ? l - 1 : 0
}

NEIGHBOURS := [6][3]int{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
DIR_DOWN :: 3

// ---- Chunk light storage ----------------------------------------------------
// Most chunks have uniform light (open air = full sky, solid rock = 0), so a
// chunk only allocates its 512-byte array once its light varies.

chunk_light :: #force_inline proc(c: ^Chunk, vi: int) -> u8 {
    return c.light == nil ? c.light_fill : c.light[vi]
}

// Returns true if the value changed.
chunk_set_light :: proc(c: ^Chunk, vi: int, v: u8) -> bool {
    if c.light == nil {
        if v == c.light_fill { return false }
        c.light = new([VOXELS_PER_BRICK]u8)
        for &x in c.light { x = c.light_fill }
    }
    if c.light[vi] == v { return false }
    c.light[vi] = v
    return true
}

chunk_free_light :: proc(c: ^Chunk) {
    if c.light != nil { free(c.light); c.light = nil }
}

// ---- Worker: one column, in isolation ----------------------------------------

COLUMN_H :: CHUNKS_H * CHUNK_VOXELS

// Column-local layout: index = x + y*8 + z*8*COLUMN_H, y from the world bottom.
// One chunk's 8 rows of one z-slice (lx + ly*8) are then 64 contiguous bytes.
@(private="file") COL_DY :: CHUNK_VOXELS
@(private="file") COL_DZ :: CHUNK_VOXELS * COLUMN_H
@(private="file") COL_N  :: CHUNK_VOXELS * COLUMN_H * CHUNK_VOXELS

// Neighbour step in column-local index space, in NEIGHBOURS order.
@(private="file")
COL_STEP := [6]int{1, -1, COL_DY, -COL_DY, COL_DZ, -COL_DZ}

// True if the step from column index i in direction d stays inside the column.
@(private="file")
col_step_ok :: #force_inline proc(i, d: int) -> bool {
    switch d {
    case 0: return i & 7 != 7
    case 1: return i & 7 != 0
    case 2: return (i / COL_DY) % COLUMN_H != COLUMN_H - 1
    case 3: return (i / COL_DY) % COLUMN_H != 0
    case 4: return i / COL_DZ != CHUNK_VOXELS - 1
    case:   return i / COL_DZ != 0
    }
}

// Spread one channel's light inside the column from every queued index.
@(private="file")
col_flood :: proc(level: []u8, blocks: []u8, queue: ^[dynamic]int, ch: Light_Channel) {
    for head := 0; head < len(queue); head += 1 {
        i := queue[head]
        l := level[i]
        for d in 0 ..< 6 {
            if !col_step_ok(i, d) { continue }
            ni := i + COL_STEP[d]
            if block_opaque(blocks[ni]) { continue }
            nl := spread_level(l, ch, d, blocks[ni])
            if nl > level[ni] {
                level[ni] = nl
                append(queue, ni)
            }
        }
    }
}

// Light for a freshly generated or loaded column, computed on its own: sky
// light, plus block light from any emitters (torches in a saved column).
// Light that would cross into neighbouring columns is left to
// light_stitch_column on the main thread.
light_column_compute :: proc(column: ^Column) {
    blocks := make([]u8, COL_N)
    sky    := make([]u8, COL_N)
    blk    := make([]u8, COL_N)
    defer delete(blocks)
    defer delete(sky)
    defer delete(blk)

    for iy in 0 ..< CHUNKS_H {
        c := &column.chunks[iy]
        for lz in 0 ..< CHUNK_VOXELS {
            dst := blocks[lz * COL_DZ + iy * 64:][:64]
            if c.voxels == nil {
                for &v in dst { v = c.fill }
            } else {
                copy(dst, c.voxels[lz * 64:][:64])
            }
        }
    }

    // Straight down from the sky until the first non-air block. Only rows
    // between the lowest and highest first-full-sky row can hold a full-sky
    // voxel next to a darker one, so the seed scan below is limited to them.
    lowest, highest := COLUMN_H, 0
    for z in 0 ..< CHUNK_VOXELS {
        for x in 0 ..< CHUNK_VOXELS {
            y := COLUMN_H - 1
            for ; y >= 0; y -= 1 {
                i := x + y * COL_DY + z * COL_DZ
                if blocks[i] != u8(Block_Type.Air) { break }
                sky[i] = LIGHT_MAX
            }
            lowest  = min(lowest, y + 1)
            highest = max(highest, y + 1)
        }
    }

    // Sky flood from every full-sky voxel next to a darker non-opaque one.
    queue := make([dynamic]int, 0, 1024)
    defer delete(queue)
    for z in 0 ..< CHUNK_VOXELS {
        for y in lowest ..< min(highest + 1, COLUMN_H) {
            for x in 0 ..< CHUNK_VOXELS {
                i := x + y * COL_DY + z * COL_DZ
                if sky[i] != LIGHT_MAX { continue }
                for d in 0 ..< 6 {
                    if !col_step_ok(i, d) { continue }
                    ni := i + COL_STEP[d]
                    if !block_opaque(blocks[ni]) && sky[ni] < LIGHT_MAX - 1 {
                        append(&queue, i)
                        break
                    }
                }
            }
        }
    }
    col_flood(sky, blocks, &queue, .Sky)

    // Block light from emitters. Generated terrain has none, so this only
    // scans chunks that hold voxel arrays (emitters are never uniform).
    clear(&queue)
    for iy in 0 ..< CHUNKS_H {
        if column.chunks[iy].voxels == nil { continue }
        for lz in 0 ..< CHUNK_VOXELS {
            base := lz * COL_DZ + iy * 64
            for k in 0 ..< 64 {
                if e := block_emission(blocks[base + k]); e > 0 {
                    blk[base + k] = e
                    append(&queue, base + k)
                }
            }
        }
    }
    col_flood(blk, blocks, &queue, .Block)

    // Store per chunk: uniform chunks keep no array.
    for iy in 0 ..< CHUNKS_H {
        c := &column.chunks[iy]
        first := sky[iy * 64] << 4 | blk[iy * 64]
        uniform := true
        check: for lz in 0 ..< CHUNK_VOXELS {
            base := lz * COL_DZ + iy * 64
            for k in 0 ..< 64 {
                if sky[base + k] << 4 | blk[base + k] != first { uniform = false; break check }
            }
        }
        c.light_fill = first
        if uniform { continue }
        c.light = new([VOXELS_PER_BRICK]u8)
        for lz in 0 ..< CHUNK_VOXELS {
            base := lz * COL_DZ + iy * 64
            for k in 0 ..< 64 { c.light[lz * 64 + k] = sky[base + k] << 4 | blk[base + k] }
        }
    }
}

// ---- Main thread: world-space flood fill ----------------------------------------

// World voxel access through gs.columns. Flood fills touch the same few chunks
// over and over, so lookups go through a small direct-mapped chunk cache.
@(private="file") LW_CACHE :: 64

@(private="file")
Light_World :: struct {
    gs:         ^Game_State,
    cache_key:  [LW_CACHE][3]int,
    cache_ptr:  [LW_CACHE]^Chunk,
    cache_used: [LW_CACHE]bool,
    changed:      map[[3]int]bool, // chunks whose light changed (for GPU upload)
    last_changed: [3]int,          // skips re-inserting the same chunk per voxel
    any_changed:  bool,
}

@(private="file")
lw_chunk :: proc(w: ^Light_World, p: [3]int) -> (c: ^Chunk, vi: int, key: [3]int) {
    if p.y < WORLD_Y_MIN || p.y >= WORLD_Y_MAX { return nil, 0, {} }
    key = {p.x >> 3, p.y >> 3, p.z >> 3} // CHUNK_VOXELS == 8; >> floors negatives
    h := (key.x * 7 + key.y * 3 + key.z * 13) & (LW_CACHE - 1)
    if !w.cache_used[h] || w.cache_key[h] != key {
        w.cache_ptr[h]  = world_chunk(w.gs, key) // nil if not resident
        w.cache_key[h]  = key
        w.cache_used[h] = true
    }
    l := p & 7
    return w.cache_ptr[h], l.x + l.y * CHUNK_VOXELS + l.z * CHUNK_VOXELS * CHUNK_VOXELS, key
}

@(private="file")
lw_set :: proc(w: ^Light_World, c: ^Chunk, vi: int, key: [3]int, ch: Light_Channel, l: u8) {
    old := chunk_light(c, vi)
    if chunk_set_light(c, vi, chan_set(old, ch, l)) && (!w.any_changed || key != w.last_changed) {
        w.changed[key] = true
        w.last_changed = key
        w.any_changed  = true
    }
}

// Spread light outward from every queued voxel (BFS; each voxel's current
// level is re-read when popped).
@(private="file")
lw_flood :: proc(w: ^Light_World, queue: ^[dynamic][3]int, ch: Light_Channel) {
    for head := 0; head < len(queue); head += 1 {
        p := queue[head]
        c, vi, _ := lw_chunk(w, p)
        if c == nil { continue }
        l := chan_get(chunk_light(c, vi), ch)
        if l <= 1 { continue }
        for d, di in NEIGHBOURS {
            n := p + d
            nc, nvi, nkey := lw_chunk(w, n)
            if nc == nil { continue }
            b := chunk_voxel(nc, nvi)
            if block_opaque(b) { continue }
            nl := spread_level(l, ch, di, b)
            if nl > chan_get(chunk_light(nc, nvi), ch) {
                lw_set(w, nc, nvi, nkey, ch, nl)
                append(queue, n)
            }
        }
    }
}

Light_Removal :: struct { p: [3]int, level: u8 }

// Darkness flood: zero every voxel whose light came from a removed source
// (it is dimmer than the source along the path), and queue the brighter
// voxels at the boundary to re-flood the hole afterwards.
@(private="file")
lw_unflood :: proc(w: ^Light_World, rem: ^[dynamic]Light_Removal, add: ^[dynamic][3]int, ch: Light_Channel) {
    for head := 0; head < len(rem); head += 1 {
        r := rem[head]
        for d, di in NEIGHBOURS {
            n := r.p + d
            nc, nvi, nkey := lw_chunk(w, n)
            if nc == nil { continue }
            nl := chan_get(chunk_light(nc, nvi), ch)
            if nl == 0 { continue }
            fed_by_r := nl < r.level ||
                (ch == .Sky && di == DIR_DOWN && r.level == LIGHT_MAX && nl == LIGHT_MAX)
            if fed_by_r && !(ch == .Block && block_emission(chunk_voxel(nc, nvi)) > 0) {
                lw_set(w, nc, nvi, nkey, ch, 0)
                append(rem, Light_Removal{n, nl})
            } else {
                append(add, n)
            }
        }
    }
}

@(private="file")
lw_finish :: proc(w: ^Light_World) {
    for key in w.changed { mark_light_dirty(w.gs, key) }
    delete(w.changed)
}

// Queue a chunk's GPU light for upload if it is resident in the ring.
mark_light_dirty :: proc(gs: ^Game_State, key: [3]int) {
    if chunk_y_index(key.y) < 0 { return }
    slot := ring_slot(key.x, key.y, key.z)
    owner := gs.gpu_chunk_owner[slot]
    if owner[0] != i32(key.x) || owner[1] != i32(key.z) { return }
    append(&gs.light_dirty, slot)
}

// Exchange light across the four side faces between a newly integrated
// column and its already-loaded neighbours.
light_stitch_column :: proc(gs: ^Game_State, wcx, wcz: int) {
    t := time.tick_now()
    defer profile_add(.Light_Stitch, t)

    w := Light_World{gs = gs}
    sky_q := make([dynamic][3]int)
    blk_q := make([dynamic][3]int)
    defer delete(sky_q)
    defer delete(blk_q)

    sides := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
    for s in sides {
        ncx, ncz := wcx + s[0], wcz + s[1]
        for iy in 0 ..< CHUNKS_H {
            wcy := iy + WORLD_CHUNK_Y_MIN
            a := world_chunk(gs, {wcx, wcy, wcz})
            b := world_chunk(gs, {ncx, wcy, ncz})
            if a == nil || b == nil { continue }
            // Uniform chunks within one level of each other can't exchange light.
            if a.light == nil && b.light == nil {
                da := int(a.light_fill >> 4) - int(b.light_fill >> 4)
                db := int(a.light_fill & 15) - int(b.light_fill & 15)
                if abs(da) <= 1 && abs(db) <= 1 { continue }
            }
            for ly in 0 ..< CHUNK_VOXELS {
                for k in 0 ..< CHUNK_VOXELS {
                    // a's voxel on the shared face, and b's voxel facing it.
                    ax, az, bx, bz: int
                    if s[0] != 0 {
                        ax = s[0] > 0 ? CHUNK_VOXELS - 1 : 0
                        bx = CHUNK_VOXELS - 1 - ax
                        az = k; bz = k
                    } else {
                        az = s[1] > 0 ? CHUNK_VOXELS - 1 : 0
                        bz = CHUNK_VOXELS - 1 - az
                        ax = k; bx = k
                    }
                    ai := ax + ly * CHUNK_VOXELS + az * CHUNK_VOXELS * CHUNK_VOXELS
                    bi := bx + ly * CHUNK_VOXELS + bz * CHUNK_VOXELS * CHUNK_VOXELS
                    if block_opaque(chunk_voxel(a, ai)) || block_opaque(chunk_voxel(b, bi)) { continue }
                    la, lb := chunk_light(a, ai), chunk_light(b, bi)
                    wy := wcy * CHUNK_VOXELS + ly
                    pa := [3]int{wcx * CHUNK_VOXELS + ax, wy, wcz * CHUNK_VOXELS + az}
                    pb := [3]int{ncx * CHUNK_VOXELS + bx, wy, ncz * CHUNK_VOXELS + bz}
                    if la >> 4 > (lb >> 4) + 1 { append(&sky_q, pa) }
                    if lb >> 4 > (la >> 4) + 1 { append(&sky_q, pb) }
                    if la & 15 > (lb & 15) + 1 { append(&blk_q, pa) }
                    if lb & 15 > (la & 15) + 1 { append(&blk_q, pb) }
                }
            }
        }
    }
    lw_flood(&w, &sky_q, .Sky)
    lw_flood(&w, &blk_q, .Block)
    lw_finish(&w)
}

// Relight after the blocks at `changed` were replaced: unflood the light they
// held or blocked, light new emitters, then re-flood from the boundary.
light_on_edit :: proc(gs: ^Game_State, changed: [][3]int) {
    w := Light_World{gs = gs}
    for ch in Light_Channel {
        rem := make([dynamic]Light_Removal)
        add := make([dynamic][3]int)
        defer delete(rem)
        defer delete(add)
        for p in changed {
            c, vi, key := lw_chunk(&w, p)
            if c == nil { continue }
            append(&rem, Light_Removal{p, chan_get(chunk_light(c, vi), ch)})
            lw_set(&w, c, vi, key, ch, 0)
        }
        lw_unflood(&w, &rem, &add, ch)
        if ch == .Block {
            for p in changed {
                c, vi, key := lw_chunk(&w, p)
                if c == nil { continue }
                if e := block_emission(chunk_voxel(c, vi)); e > 0 {
                    lw_set(&w, c, vi, key, .Block, e)
                    append(&add, p)
                }
            }
        }
        lw_flood(&w, &add, ch)
    }
    lw_finish(&w)
}
