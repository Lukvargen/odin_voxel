package main

import "core:math"
import "core:slice"
import "core:time"
import SDL "vendor:sdl3"

// Far terrain: a coarse LOD drawn beyond the voxel world, out to
// FAR_RADIUS_TILES * FAR_TILE voxels (~1900). Each cell summarises a 4x4
// voxel footprint as solid ground up to a height (with its top block) plus
// an optional canopy slab for tree crowns. The shader traces it as blocky
// cells wherever a ray leaves the loaded voxels (see loaded_radius).
//
// Cells come from the real voxels wherever those exist: every resident
// column is summarised when it loads and after every edit, and columns with
// a save file are summarised from the save. Never-visited areas are
// summarised from the terrain noise and the real tree generator (run in a
// mode that only records the top surface), so far terrain matches what
// loads in when you get there.
//
// Storage is a toroidal ring of FAR_RING^2 tiles (8x8 cells, 32 voxels),
// like the chunk ring: tile slot = tile coord & (FAR_RING-1), with the
// owning tile coord stored per slot.

FAR_CELL           :: 4                            // voxels per cell side
FAR_TILE_CELLS     :: 8                            // cells per tile side
FAR_TILE           :: FAR_CELL * FAR_TILE_CELLS    // 32 voxels per tile side
FAR_CELLS_PER_TILE :: FAR_TILE_CELLS * FAR_TILE_CELLS
FAR_RING           :: 128                          // tiles per ring side (power of two)
FAR_RADIUS_TILES   :: 60                           // must stay < FAR_RING/2
FAR_TILE_COLUMNS   :: FAR_TILE / CHUNK_VOXELS      // 4 columns per tile side
FAR_INTEGRATE_BUDGET :: 64                         // tiles integrated per frame
FAR_NO_TILE        :: max(i32)
FAR_TABLE_BYTES    :: FAR_RING * FAR_RING * size_of([4]i32) // far_buf: tile table, then cells

// Per-cell summary of one tile while it is being built. A cell is drawn as
// ground (solid from below up to ground_top) plus an optional canopy slab of
// leaves, so rays can pass under far tree crowns the way they do near ones.
Far_Summary :: struct {
    ground_top: [FAR_CELLS_PER_TILE]int, // top surface (y + 1) of the highest ground block
    ground_mat: [FAR_CELLS_PER_TILE]u8,
    leaves_lo:  [FAR_CELLS_PER_TILE]int, // lowest / highest leaves voxel y
    leaves_hi:  [FAR_CELLS_PER_TILE]int,
    log_lo:     [FAR_CELLS_PER_TILE]int, // lowest / highest log voxel y
    log_hi:     [FAR_CELLS_PER_TILE]int,
    canopy:     [FAR_CELLS_PER_TILE]u8,   // the canopy's leaf block (0: none seen)
}

Far_Job :: struct {
    key:   [2]int, // tile coord
    saved: u16,    // bit c (cx + cz*4): column c of the tile has a save file
}

Far_Result :: struct {
    key:   [2]int,
    cells: [FAR_CELLS_PER_TILE]u32, // far_pack_cell
}

far_summary_init :: proc(s: ^Far_Summary) {
    for i in 0 ..< FAR_CELLS_PER_TILE {
        s.ground_top[i] = min(int)
        s.leaves_lo[i], s.leaves_hi[i] = max(int), min(int)
        s.log_lo[i], s.log_hi[i] = max(int), min(int)
    }
}

// Add a block at (lx, wy, lz), lx/lz local to the tile.
far_record :: proc(s: ^Far_Summary, lx, wy, lz: int, b: u8) {
    ci := lx / FAR_CELL + (lz / FAR_CELL) * FAR_TILE_CELLS
    switch b {
    case u8(Block_Type.Air), u8(Block_Type.Cactus), u8(Block_Type.Tall_Grass), u8(Block_Type.Flower), u8(Block_Type.Fern), u8(Block_Type.Dry_Bush), u8(Block_Type.Mushroom),
         u8(Block_Type.Roots), u8(Block_Type.Glow_Mushroom):
        // cacti and plants are too thin to show
    case u8(Block_Type.Leaves), u8(Block_Type.Spruce_Leaves), u8(Block_Type.Birch_Leaves), u8(Block_Type.Autumn_Leaves),
         u8(Block_Type.Acacia_Leaves), u8(Block_Type.Willow_Leaves):
        s.leaves_lo[ci] = min(s.leaves_lo[ci], wy)
        s.leaves_hi[ci] = max(s.leaves_hi[ci], wy)
        s.canopy[ci] = b
    case u8(Block_Type.Log), u8(Block_Type.Spruce_Log), u8(Block_Type.Birch_Log), u8(Block_Type.Acacia_Log):
        s.log_lo[ci] = min(s.log_lo[ci], wy)
        s.log_hi[ci] = max(s.log_hi[ci], wy)
    case:
        // A beacon fire or crystal on top of its cell wins a tie, so it
        // still glows on the far terrain.
        emissive := b == u8(Block_Type.Torch) || b == u8(Block_Type.Crystal)
        if wy + 1 > s.ground_top[ci] || (emissive && wy + 1 == s.ground_top[ci]) {
            s.ground_top[ci] = wy + 1
            s.ground_mat[ci] = b
        }
    }
}

// GPU cell: ground top (10 bits, above WORLD_Y_MIN), ground block (8),
// canopy bottom above the ground (6), canopy height (6, 0 = no canopy),
// canopy kind (2: far_canopy_kind).
far_pack_cell :: proc(s: ^Far_Summary, ci: int) -> u32 {
    g, gm := s.ground_top[ci], s.ground_mat[ci]
    if g == min(int) { g, gm = WORLD_Y_MIN, u8(Block_Type.Stone) }
    has_canopy := s.leaves_hi[ci] != min(int)
    lo, hi := s.leaves_lo[ci], s.leaves_hi[ci] + 1
    // A trunk standing on the ground: a log column up to the crown (branch
    // logs elsewhere are hidden inside the canopy and ignored).
    leaves := s.canopy[ci] != 0 ? s.canopy[ci] : u8(Block_Type.Leaves)
    if s.log_hi[ci] != min(int) && s.log_lo[ci] <= g + 1 {
        top := s.log_hi[ci] + 1
        if has_canopy { top = min(top, lo) }
        if top > g { g, gm = top, u8(Block_Type.Log) }
    }
    // Leaves down to the ground (a low crown on a slope) are just taller ground.
    if has_canopy && lo <= g {
        if hi > g { g, gm = hi, leaves }
        has_canopy = false
    }
    enc :: proc(y: int) -> u32 { return u32(clamp(y - WORLD_Y_MIN, 0, 1023)) }
    cell := enc(g) | u32(gm) << 10
    if has_canopy {
        cell |= u32(clamp(lo - g, 0, 63)) << 18 | u32(clamp(hi - lo, 1, 63)) << 24 | far_canopy_kind(leaves) << 30
    }
    return cell
}

// Which leaves a canopy is, in two bits (the far shader's FAR_CANOPY).
@(private="file")
far_canopy_kind :: proc(leaves: u8) -> u32 {
    switch leaves {
    case u8(Block_Type.Spruce_Leaves): return 1
    case u8(Block_Type.Birch_Leaves), u8(Block_Type.Willow_Leaves): return 2
    case u8(Block_Type.Autumn_Leaves): return 3
    }
    return 0
}

// Highest surface of a packed cell (for the tile's max height).
far_cell_top :: proc(cell: u32) -> int {
    g := int(cell & 0x3FF) + WORLD_Y_MIN
    if ch := (cell >> 24) & 63; ch != 0 { g = max(g, g + int((cell >> 18) & 63) + int(ch)) }
    return g
}

far_tile_slot :: proc(key: [2]int) -> int {
    return (key.x & (FAR_RING - 1)) + (key.y & (FAR_RING - 1)) * FAR_RING
}

// Record every block of a column into the summary; cx, cz = column within the tile.
far_record_column :: proc(s: ^Far_Summary, cx, cz: int, col: ^Column) {
    for &c, iy in col.chunks {
        y0 := (iy + WORLD_CHUNK_Y_MIN) * CHUNK_VOXELS
        if c.voxels == nil {
            if c.fill == 0 { continue }
            // Uniform: only the top layer can matter.
            for z in 0 ..< CHUNK_VOXELS {
                for x in 0 ..< CHUNK_VOXELS {
                    far_record(s, cx * CHUNK_VOXELS + x, y0 + CHUNK_VOXELS - 1, cz * CHUNK_VOXELS + z, c.fill)
                }
            }
            continue
        }
        for vi in 0 ..< VOXELS_PER_BRICK {
            if v := c.voxels[vi]; v != 0 {
                far_record(s, cx * CHUNK_VOXELS + (vi & 7), y0 + ((vi >> 3) & 7), cz * CHUNK_VOXELS + (vi >> 6), v)
            }
        }
    }
}

// ---- Worker -----------------------------------------------------------------

// Summarise one tile from terrain noise + trees, or from save files for its
// edited columns.
far_tile_compute :: proc(job: Far_Job) -> Far_Result {
    t := time.tick_now()
    defer profile_add(.Far_Tile, t)

    s: Far_Summary
    far_summary_init(&s)
    ox := job.key.x * FAR_TILE
    oz := job.key.y * FAR_TILE

    // Terrain: the highest surface voxel in each cell (water counts as
    // ground at sea level), and its top block. Samples include a 1-voxel
    // border for slopes, as in generation.
    G :: FAR_TILE + 2
    samples := make([]Terrain_Sample, G * G, context.temp_allocator)
    terrain_grid(ox - 1, oz - 1, G, G, samples)
    for z in 0 ..< FAR_TILE {
        for x in 0 ..< FAR_TILE {
            si := (x + 1) + (z + 1) * G
            t := samples[si]
            y, mat := t.height, u8(0)
            if y < SEA_LEVEL {
                y = SEA_LEVEL
                mat = u8(surface_layers(t, 0).frozen ? Block_Type.Ice : Block_Type.Water)
            }
            ci := x / FAR_CELL + (z / FAR_CELL) * FAR_TILE_CELLS
            if y <= s.ground_top[ci] { continue }
            if mat == 0 {
                slope := terrain_slope(t.height, samples[si - 1].height, samples[si + 1].height,
                                       samples[si - G].height, samples[si + G].height)
                mat = u8(surface_layers(t, slope).top)
            }
            s.ground_top[ci] = y
            s.ground_mat[ci] = mat
        }
    }

    // Trees, through the real generators in summary mode.
    tgt := Tree_Target{far = &s, ox = ox, oz = oz, size = FAR_TILE}
    lat := tree_lattice(ox, oz, FAR_TILE)
    for wz in oz - TREE_VOXEL_REACH ..< oz + FAR_TILE + TREE_VOXEL_REACH {
        for wx in ox - TREE_VOXEL_REACH ..< ox + FAR_TILE + TREE_VOXEL_REACH {
            kind, base := tree_at(&lat, wx, wz)
            if kind != .None { generate_tree_kind(&tgt, kind, wx, base, wz) }
        }
    }
    generate_landmarks(&tgt)

    res := Far_Result{key = job.key}
    for ci in 0 ..< FAR_CELLS_PER_TILE { res.cells[ci] = far_pack_cell(&s, ci) }

    // Edited columns: summarise the saved voxels instead.
    for c in 0 ..< FAR_TILE_COLUMNS * FAR_TILE_COLUMNS {
        if job.saved & (1 << u16(c)) == 0 { continue }
        cx, cz := c % FAR_TILE_COLUMNS, c / FAR_TILE_COLUMNS
        col := load_column({job.key.x * FAR_TILE_COLUMNS + cx, job.key.y * FAR_TILE_COLUMNS + cz})
        if col == nil { continue }
        far_write_column_cells(res.cells[:], cx, cz, col)
        column_free(col)
    }
    return res
}

// Write a column's 2x2 cells into a tile's 64 cells; cx, cz = column within the tile.
far_write_column_cells :: proc(cells: []u32, cx, cz: int, col: ^Column) {
    s: Far_Summary
    far_summary_init(&s)
    far_record_column(&s, cx, cz, col)
    for k in 0 ..< 4 {
        ci := (cx * 2 + (k & 1)) + (cz * 2 + (k >> 1)) * FAR_TILE_CELLS
        cells[ci] = far_pack_cell(&s, ci)
    }
}

// ---- Main thread ----------------------------------------------------------------

far_init :: proc(gs: ^Game_State) {
    gs.far_cells = make([]u32, FAR_RING * FAR_RING * FAR_CELLS_PER_TILE)
    gs.far_tiles = make([][4]i32, FAR_RING * FAR_RING)
    for &t in gs.far_tiles { t = {FAR_NO_TILE, FAR_NO_TILE, 0, 0} }
    gs.far_player_tile = {max(int), max(int)}
}

// Queue every missing tile within a circle of FAR_RADIUS_TILES. Cheap
// enough to run on every tile-boundary crossing.
far_enqueue :: proc(gs: ^Game_State) {
    pt := [2]int{int(math.floor(gs.camera.pos.x)) >> 5, int(math.floor(gs.camera.pos.z)) >> 5} // FAR_TILE == 32
    if pt == gs.far_player_tile { return }
    gs.far_player_tile = pt
    jobs := make([dynamic]Far_Job, context.temp_allocator)
    for dz in -FAR_RADIUS_TILES ..= FAR_RADIUS_TILES {
        for dx in -FAR_RADIUS_TILES ..= FAR_RADIUS_TILES {
            if dx*dx + dz*dz > FAR_RADIUS_TILES * FAR_RADIUS_TILES { continue }
            key := pt + {dx, dz}
            t := gs.far_tiles[far_tile_slot(key)]
            if int(t.x) == key.x && int(t.y) == key.y { continue }
            job := Far_Job{key = key}
            for c in 0 ..< FAR_TILE_COLUMNS * FAR_TILE_COLUMNS {
                ck := key * FAR_TILE_COLUMNS + {c % FAR_TILE_COLUMNS, c / FAR_TILE_COLUMNS}
                // Edited columns far off: from our own server's saves (a
                // joined client sees them unedited until near).
                if !client_joined(gs) && ck in gs.net.edited { job.saved |= 1 << u16(c) }
            }
            append(&jobs, job)
        }
    }
    worker_pool_enqueue_far(&gs.pool, jobs[:], pt)
}

// Re-summarise a resident column into the far grid (after it loads or is
// edited). No-op if its tile isn't in the ring yet; integrating the tile
// re-summarises resident columns then.
far_update_column :: proc(gs: ^Game_State, key: [2]int) {
    col := gs.columns[key]
    if col == nil { return }
    tile := [2]int{key.x >> 2, key.y >> 2} // FAR_TILE_COLUMNS == 4
    slot := far_tile_slot(tile)
    if int(gs.far_tiles[slot].x) != tile.x || int(gs.far_tiles[slot].y) != tile.y { return }
    cells := gs.far_cells[slot * FAR_CELLS_PER_TILE:][:FAR_CELLS_PER_TILE]
    far_write_column_cells(cells, key.x & 3, key.y & 3, col)
    far_refresh_tile_max(gs, slot)
    append(&gs.far_dirty, slot)
}

// Re-summarise every column touched by an edit.
far_update_edited :: proc(gs: ^Game_State, changed: [][3]int) {
    done := make(map[[2]int]bool, context.temp_allocator)
    for p in changed {
        key := [2]int{p.x >> 3, p.z >> 3} // CHUNK_VOXELS == 8
        if key in done { continue }
        done[key] = true
        far_update_column(gs, key)
    }
}

@(private="file")
far_refresh_tile_max :: proc(gs: ^Game_State, slot: int) {
    m := min(int)
    for c in gs.far_cells[slot * FAR_CELLS_PER_TILE:][:FAR_CELLS_PER_TILE] {
        m = max(m, far_cell_top(c))
    }
    gs.far_tiles[slot].z = m == min(int) ? i32(WORLD_Y_MIN) : i32(m)
    gs.far_tiles_dirty = true
}

integrate_far_tiles :: proc(gs: ^Game_State) {
    results := worker_pool_drain_far(&gs.pool, FAR_INTEGRATE_BUDGET)
    defer delete(results)
    for &r in results {
        slot := far_tile_slot(r.key)
        copy(gs.far_cells[slot * FAR_CELLS_PER_TILE:][:FAR_CELLS_PER_TILE], r.cells[:])
        gs.far_tiles[slot].x = i32(r.key.x)
        gs.far_tiles[slot].y = i32(r.key.y)
        far_refresh_tile_max(gs, slot)
        append(&gs.far_dirty, slot)
        // Resident columns are newer than any save or the noise: use them.
        for c in 0 ..< FAR_TILE_COLUMNS * FAR_TILE_COLUMNS {
            far_update_column(gs, r.key * FAR_TILE_COLUMNS + {c % FAR_TILE_COLUMNS, c / FAR_TILE_COLUMNS})
        }
    }
}

// Upload dirty tiles' cells (coalesced by slot) and the tile table.
flush_far_uploads :: proc(gs: ^Game_State) {
    if len(gs.far_dirty) == 0 && !gs.far_tiles_dirty { return }
    slots := make([dynamic]int, context.temp_allocator)
    seen := make(map[int]bool, context.temp_allocator)
    for s in gs.far_dirty {
        if s in seen { continue }
        seen[s] = true
        append(&slots, s)
    }
    clear(&gs.far_dirty)
    slice.sort(slots[:])

    tile_bytes  :: FAR_CELLS_PER_TILE * size_of(u32)
    table_bytes := len(gs.far_tiles) * size_of([4]i32)
    table_off   := len(slots) * tile_bytes
    total       := table_off + (gs.far_tiles_dirty ? table_bytes : 0)
    base := ([^]u8)(staging_map(gs, &gs.stage_far, total))
    transfer := gs.stage_far.buf
    for s, i in slots {
        copy(base[i * tile_bytes:][:tile_bytes], slice.to_bytes(gs.far_cells[s * FAR_CELLS_PER_TILE:][:FAR_CELLS_PER_TILE]))
    }
    if gs.far_tiles_dirty { copy(base[table_off:][:table_bytes], slice.to_bytes(gs.far_tiles)) }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    copy_pass := SDL.BeginGPUCopyPass(upload_cmd(gs))
    upload_runs(copy_pass, transfer, gs.far_buf, slots[:], tile_bytes, 0, FAR_TABLE_BYTES)
    if gs.far_tiles_dirty {
        SDL.UploadToGPUBuffer(copy_pass,
            {transfer_buffer = transfer, offset = u32(table_off)},
            {buffer = gs.far_buf, offset = 0, size = u32(table_bytes)},
            false)
    }
    SDL.EndGPUCopyPass(copy_pass)
    gs.far_tiles_dirty = false
}
