package main

import "core:math"

// Landmarks: ruins scattered over the land to give the eye somewhere to go.
// At most one per LANDMARK_CELL square, at a hashed spot, so they are a pure
// function of position like the trees: every column (and far tile) a
// landmark overlaps regenerates its share of it through Tree_Target.
//
//  - Watchtower: a ruined round tower with a spiral stair around a central
//    pillar, broken battlements, windows, and a beacon fire on top that is
//    seen from far off at night.
//  - Stone circle: standing stones (some fallen) around an altar with a
//    glowing crystal.
//  - Shrine: a pillared platform under a half-fallen roof, crystal inside.
//  - Camp: a goblin camp, a ring of sharpened stakes around a fire pit and
//    lean-to huts of branches. Its goblins and orcs are spawned by
//    enemies.odin, as are the skeletons that guard the ruins.
//
// They're designed in design blocks, like the terrain: each is built into a
// Landmark_Design at that size around its site, then stretched
// TERRAIN_SCALE times into the world (landmark_place), doorways and all.

LANDMARK_CELL   :: 336 // world blocks (224 design)
LANDMARK_MARGIN :: 48  // keep sites this far inside their cell
LANDMARK_REACH  :: 28  // world blocks: max horizontal reach from the site centre...
LANDMARK_DESIGN_REACH :: 18 // ...18 design blocks

Landmark_Kind :: enum u8 { None, Tower, Stones, Shrine, Camp }

Landmark :: struct {
    kind:    Landmark_Kind,
    x, z:    int, // site centre
    base:    int, // floor level (top of the foundation)
    seed:    int,
}

@(private="file")
lm_hash :: #force_inline proc(a, b, seed: int) -> f64 { return tree_hash(a, b, seed) }

// The landmark of cell (cx, cz), if any.
landmark_in_cell :: proc(cx, cz: int) -> Landmark {
    h := lm_hash(cx, cz, 7717)
    if h > 0.6 { return {} }
    // The highest of a few spots in the cell: ruins stand on hilltops,
    // where they are seen from afar and have a view.
    span := LANDMARK_CELL - 2 * LANDMARK_MARGIN
    x, z: int
    s: Terrain_Sample
    s.height = min(int)
    for i in 0 ..< 6 {
        px := cx * LANDMARK_CELL + LANDMARK_MARGIN + int(lm_hash(cx + i * 101, cz, 31) * f64(span))
        pz := cz * LANDMARK_CELL + LANDMARK_MARGIN + int(lm_hash(cx, cz + i * 101, 37) * f64(span))
        ps := terrain_at(px, pz)
        if ps.height > s.height && ps.height < world_h(SNOW_LINE - 10) { x, z, s = px, pz, ps }
    }
    if s.height < SEA_LEVEL + 3 { return {} }

    kind: Landmark_Kind
    k := lm_hash(cx, cz, 41)
    #partial switch s.biome {
    case .Plains, .Savanna:
        kind = k < 0.35 ? .Tower : (k < 0.55 ? .Stones : (k < 0.7 ? .Shrine : .Camp))
    case .Taiga, .Snowy, .Mountains:
        kind = k < 0.45 ? .Tower : (k < 0.7 ? .Stones : (k < 0.85 ? .Shrine : .Camp))
    case .Forest: // giant oaks would hide a tower
        kind = k < 0.4 ? .Stones : (k < 0.65 ? .Shrine : .Camp)
    case .Desert, .Badlands:
        kind = k < 0.25 ? .Tower : (k < 0.4 ? .Stones : (k < 0.5 ? .Shrine : .Camp))
    case: return {}
    }

    // Needs fairly level ground: sample the rim.
    r := kind == .Stones || kind == .Camp ? 14 : 9
    lo, hi := s.height, s.height
    for d in ([4][2]int{{r, 0}, {-r, 0}, {0, r}, {0, -r}}) {
        hh := surface_height_at(x + d.x, z + d.y)
        if hh < SEA_LEVEL + 1 { return {} }
        lo, hi = min(lo, hh), max(hi, hh)
    }
    if hi - lo > (kind == .Stones || kind == .Camp ? 8 : 12) { return {} }
    return {kind, x, z, kind == .Stones || kind == .Camp ? s.height : hi, int(h * 1e6) + cx * 31 + cz * 17}
}

// Generate every landmark that reaches tgt's footprint.
generate_landmarks :: proc(tgt: ^Tree_Target) {
    c0x := floor_div(tgt.ox - LANDMARK_REACH, LANDMARK_CELL)
    c1x := floor_div(tgt.ox + tgt.size + LANDMARK_REACH, LANDMARK_CELL)
    c0z := floor_div(tgt.oz - LANDMARK_REACH, LANDMARK_CELL)
    c1z := floor_div(tgt.oz + tgt.size + LANDMARK_REACH, LANDMARK_CELL)
    for cz in c0z ..= c1z {
        for cx in c0x ..= c1x {
            // Cheap reject before any terrain is sampled: the site is
            // somewhere in the cell's inner square.
            ix0 := cx * LANDMARK_CELL + LANDMARK_MARGIN - LANDMARK_REACH
            iz0 := cz * LANDMARK_CELL + LANDMARK_MARGIN - LANDMARK_REACH
            ix1 := (cx + 1) * LANDMARK_CELL - LANDMARK_MARGIN + LANDMARK_REACH
            iz1 := (cz + 1) * LANDMARK_CELL - LANDMARK_MARGIN + LANDMARK_REACH
            if !aabb_hits_chunk(tgt, ix0, 0, iz0, ix1, 0, iz1) { continue }
            if lm_hash(cx, cz, 7717) > 0.6 { continue }
            lm := landmark_in_cell(cx, cz)
            if lm.kind == .None { continue }
            if !aabb_hits_chunk(tgt, lm.x - LANDMARK_REACH, 0, lm.z - LANDMARK_REACH,
                                lm.x + LANDMARK_REACH, 0, lm.z + LANDMARK_REACH) { continue }
            landmark_place(tgt, lm)
        }
    }
}

// A landmark at its design size, around its site: (x, base, z) is the same
// point in both, and a design block is TERRAIN_SCALE world blocks.
Landmark_Design :: struct {
    lm:        Landmark,
    voxels:    [LD_W * LD_H * LD_W]u8, // LD_UNSET where the design leaves the world as it is
    clear_r:   int, // the glade cleared of trees (design blocks), up to clear_top
    clear_top: int,
}

@(private="file") LD_W     :: 2 * LANDMARK_DESIGN_REACH + 3
@(private="file") LD_H     :: 80 // design blocks, from LD_BELOW under the base
@(private="file") LD_BELOW :: 28
@(private="file") LD_UNSET :: 0xff

// Build lm's design, then stretch it into tgt.
@(private="file")
landmark_place :: proc(tgt: ^Tree_Target, lm: Landmark) {
    d := new(Landmark_Design)
    defer free(d)
    d.lm = lm
    for &v in d.voxels { v = LD_UNSET }
    dt := Tree_Target{design = d}
    switch lm.kind {
    case .None:
    case .Tower:  generate_tower(&dt, lm)
    case .Stones: generate_stone_circle(&dt, lm)
    case .Shrine: generate_shrine(&dt, lm)
    case .Camp:   generate_camp(&dt, lm)
    }
    if d.clear_r > 0 {
        clear_vegetation(tgt, lm, int(f64(d.clear_r) * TERRAIN_SCALE), lm.base + int(f64(d.clear_top - lm.base) * TERRAIN_SCALE))
    }
    // Every world voxel of the footprint near the site takes the design
    // voxel its centre falls in.
    y0 := lm.base - int(f64(LD_BELOW) * TERRAIN_SCALE)
    y1 := lm.base + int(f64(LD_H - LD_BELOW) * TERRAIN_SCALE)
    for wz in max(lm.z - LANDMARK_REACH, tgt.oz) ..< min(lm.z + LANDMARK_REACH + 1, tgt.oz + tgt.size) {
        for wx in max(lm.x - LANDMARK_REACH, tgt.ox) ..< min(lm.x + LANDMARK_REACH + 1, tgt.ox + tgt.size) {
            for wy in y0 ..< y1 {
                if v := design_voxel_at_world(d, wx, wy, wz); v != LD_UNSET { set_voxel_world(tgt, wx, wy, wz, Block_Type(v)) }
            }
        }
    }
}

// The design point a world block's centre lies in.
@(private="file")
design_of_world :: #force_inline proc(lm: Landmark, wx, wy, wz: int) -> [3]int {
    return {
        lm.x + int(math.floor((f64(wx - lm.x) + 0.5) / TERRAIN_SCALE)),
        lm.base + int(math.floor((f64(wy - lm.base) + 0.5) / TERRAIN_SCALE)),
        lm.z + int(math.floor((f64(wz - lm.z) + 0.5) / TERRAIN_SCALE)),
    }
}

@(private="file")
design_index :: #force_inline proc(d: ^Landmark_Design, p: [3]int) -> (int, bool) {
    x := p.x - d.lm.x + LANDMARK_DESIGN_REACH + 1
    y := p.y - d.lm.base + LD_BELOW
    z := p.z - d.lm.z + LANDMARK_DESIGN_REACH + 1
    if x < 0 || x >= LD_W || y < 0 || y >= LD_H || z < 0 || z >= LD_W { return 0, false }
    return x + y * LD_W + z * LD_W * LD_H, true
}

@(private="file")
design_voxel_at_world :: proc(d: ^Landmark_Design, wx, wy, wz: int) -> u8 {
    i, ok := design_index(d, design_of_world(d.lm, wx, wy, wz))
    return ok ? d.voxels[i] : LD_UNSET
}

// A design voxel, written by a generator through set_voxel_world.
design_put :: proc(d: ^Landmark_Design, x, y, z: int, b: Block_Type) {
    if i, ok := design_index(d, {x, y, z}); ok { d.voxels[i] = u8(b) }
}

// The ground under design point (x, z), in design blocks.
@(private="file")
lm_ground :: proc(t: ^Tree_Target, x, z: int) -> int {
    d := t.design
    if d == nil { return surface_height_at(x, z) }
    wx := d.lm.x + int(math.floor(f64(x - d.lm.x) * TERRAIN_SCALE))
    wz := d.lm.z + int(math.floor(f64(z - d.lm.z) * TERRAIN_SCALE))
    g := surface_height_at(wx, wz)
    return d.lm.base + int(math.floor(f64(g - d.lm.base) / TERRAIN_SCALE + 0.5))
}

// A glade: remove tree logs and leaves within radius r of the site, up to y1
// (in a far summary there is nothing to remove; trees there are only tops).
@(private="file")
clear_vegetation :: proc(t: ^Tree_Target, lm: Landmark, r: int, y1: int) {
    if t.design != nil { t.design.clear_r, t.design.clear_top = r, y1; return } // done in the world after
    if t.col == nil { return }
    for wz in lm.z - r ..= lm.z + r {
        for wx in lm.x - r ..= lm.x + r {
            if !in_footprint(t, wx, wz) { continue }
            dx, dz := wx - lm.x, wz - lm.z
            if dx * dx + dz * dz > r * r { continue }
            for y in surface_height_at(wx, wz) ..< y1 {
                b := col_voxel(t.col, wx - t.ox, y, wz - t.oz)
                if block_is_leaves(b) || block_is_log(b) {
                    set_voxel_world(t, wx, y, wz, .Air)
                }
            }
        }
    }
}

@(private="file")
in_footprint :: #force_inline proc(t: ^Tree_Target, wx, wz: int) -> bool {
    if t.design != nil { return true } // the whole design is built
    lx, lz := wx - t.ox, wz - t.oz
    return lx >= 0 && lx < t.size && lz >= 0 && lz < t.size
}

// Fill from the ground up to (and including) top - 1 at (wx, wz).
@(private="file")
foundation :: proc(t: ^Tree_Target, wx, wz, top: int, b: Block_Type) {
    g := lm_ground(t, wx, wz)
    for y in min(g - 2, top - 1) ..< top { set_voxel_world(t, wx, y, wz, b) }
}

// Mostly bricks, some cracked into plain stone or rubble, by position.
@(private="file")
ruin_block :: proc(wx, wy, wz, seed: int) -> Block_Type {
    h := lm_hash(wx * 7 + wy, wz * 3 - wy, seed)
    if h < 0.06 { return .Stone }
    if h < 0.10 { return .Gravel }
    return .Stone_Bricks
}

generate_tower :: proc(t: ^Tree_Target, lm: Landmark) {
    R     :: 4.6  // outer radius
    INNER :: 3.4  // hollow inside the wall
    NEWEL :: 1.0  // central pillar radius
    STEP  :: 0.42 // stair angle per level (radians)
    seed := lm.seed
    height := 26 + int(lm_hash(seed, 1, 3) * 12)
    rot := lm_hash(seed, 2, 5) * math.TAU
    top := lm.base + height

    clear_vegetation(t, lm, 9, top + 6)
    for wz in lm.z - 6 ..= lm.z + 6 {
        for wx in lm.x - 6 ..= lm.x + 6 {
            if !in_footprint(t, wx, wz) { continue }
            dx, dz := f64(wx - lm.x) + 0.5, f64(wz - lm.z) + 0.5
            r := math.sqrt(dx * dx + dz * dz)
            if r >= R { continue }
            a := math.atan2(dz, dx) - rot
            for a < 0 { a += math.TAU }
            for a >= math.TAU { a -= math.TAU }
            foundation(t, wx, wz, lm.base, .Stone_Bricks)

            if r < NEWEL + 0.5 {
                // Central pillar up to the beacon.
                for y in lm.base ..< top { set_voxel_world(t, wx, y, wz, .Stone_Bricks) }
                set_voxel_world(t, wx, top, wz, .Torch) // the 2x2 beacon fire
                continue
            }
            if r < INNER {
                // Stair: level k covers the angles [k*STEP, k*STEP + 1.3*STEP);
                // the ring of steps is clear above (one turn = 15 levels).
                for y in lm.base + 1 ..< top {
                    k := f64(y - lm.base)
                    d := a - math.mod(k * STEP, math.TAU)
                    if d < 0 { d += math.TAU }
                    b: Block_Type = d < STEP * 1.3 ? .Stone_Bricks : .Air
                    set_voxel_world(t, wx, y, wz, b)
                }
                for y in top ..< top + 4 { set_voxel_world(t, wx, y, wz, .Air) }
                continue
            }
            // Wall, ruined: its top dips in a few broad bites.
            bite := math.sin(a * 2 + lm_hash(seed, 3, 7) * 6) * 0.5 + math.sin(a * 5 + 1.3) * 0.5
            wall_top := top + 2 - int(max(bite, 0) * 9)
            if wall_top >= top + 1 && int(a * 6) % 2 == 0 { wall_top = top + 1 } // crenels
            for y in lm.base ..< wall_top {
                lvl := y - lm.base
                door := lvl >= 1 && lvl <= 3 && (a < 0.32 || a > math.TAU - 0.32)
                window := lvl > 4 && lvl % 6 == 0 && math.mod(a + f64(lvl) * 0.7, 1.57) < 0.22
                if door || window {
                    set_voxel_world(t, wx, y, wz, .Air)
                } else {
                    set_voxel_world(t, wx, y, wz, ruin_block(wx, y, wz, seed))
                }
            }
            for y in max(wall_top, lm.base + 1) ..< top + 4 { set_voxel_world(t, wx, y, wz, .Air) }
        }
    }
    // Rubble fallen from the broken top.
    for i in 0 ..< 14 {
        a := lm_hash(seed, i, 11) * math.TAU
        d := R + 0.5 + lm_hash(seed, i, 13) * 5
        wx := lm.x + int(math.floor(math.cos(a) * d))
        wz := lm.z + int(math.floor(math.sin(a) * d))
        if !in_footprint(t, wx, wz) { continue }
        g := lm_ground(t, wx, wz)
        if g < SEA_LEVEL { continue }
        set_voxel_world(t, wx, g, wz, ruin_block(wx, g, wz, seed + 1))
    }
}

generate_stone_circle :: proc(t: ^Tree_Target, lm: Landmark) {
    seed := lm.seed
    n := 7 + int(lm_hash(seed, 1, 3) * 4)
    ring := 7.5 + lm_hash(seed, 2, 3) * 2
    rot := lm_hash(seed, 3, 3) * math.TAU
    clear_vegetation(t, lm, 13, lm.base + 40)
    for i in 0 ..< n {
        a := rot + f64(i) / f64(n) * math.TAU
        sx := lm.x + int(math.floor(math.cos(a) * ring))
        sz := lm.z + int(math.floor(math.sin(a) * ring))
        fallen := lm_hash(seed, i, 5) < 0.3
        h := 3 + int(lm_hash(seed, i, 7) * 4)
        if fallen {
            // Lying along the ring's tangent, half sunk.
            tx, tz := -math.sin(a), math.cos(a)
            for s in 0 ..< h {
                wx := sx + int(math.round(tx * f64(s)))
                wz := sz + int(math.round(tz * f64(s)))
                if !in_footprint(t, wx, wz) { continue }
                g := lm_ground(t, wx, wz)
                set_voxel_world(t, wx, g, wz, .Stone)
            }
            continue
        }
        // Upright: 2x1 (rotated by the ring) slab of rock, slightly leaning.
        ox, oz := (abs(math.cos(a)) < 0.7) ? 1 : 0, (abs(math.cos(a)) < 0.7) ? 0 : 1
        for p in 0 ..< 2 {
            wx, wz := sx + ox * p, sz + oz * p
            if !in_footprint(t, wx, wz) { continue }
            g := lm_ground(t, wx, wz)
            for y in g - 2 ..< g + h - p { set_voxel_world(t, wx, y, wz, .Stone) }
        }
    }
    // Altar: a 3x3 block of bricks, a crystal glowing on top.
    for dz in -1 ..= 1 {
        for dx in -1 ..= 1 {
            wx, wz := lm.x + dx, lm.z + dz
            if !in_footprint(t, wx, wz) { continue }
            foundation(t, wx, wz, lm.base + 1, .Stone_Bricks)
            for y in lm.base + 1 ..< lm.base + 5 { set_voxel_world(t, wx, y, wz, .Air) }
        }
    }
    if in_footprint(t, lm.x, lm.z) {
        set_voxel_world(t, lm.x, lm.base + 1, lm.z, .Crystal)
        set_voxel_world(t, lm.x, lm.base + 2, lm.z, .Crystal)
    }
}

generate_shrine :: proc(t: ^Tree_Target, lm: Landmark) {
    seed := lm.seed
    floor_top := lm.base + 1
    clear_vegetation(t, lm, 10, lm.base + 40)
    for dz in -3 ..= 3 {
        for dx in -3 ..= 3 {
            wx, wz := lm.x + dx, lm.z + dz
            if !in_footprint(t, wx, wz) { continue }
            foundation(t, wx, wz, floor_top, .Stone_Bricks)
            edge := abs(dx) == 3 || abs(dz) == 3
            corner := abs(dx) == 3 && abs(dz) == 3
            for y in floor_top ..< floor_top + 6 {
                lvl := y - floor_top
                b := Block_Type.Air
                if corner && lvl < 5 {
                    b = ruin_block(wx, y, wz, seed)
                } else if lvl == 5 && lm_hash(wx, wz, seed + 9) > 0.35 + 0.08 * f64(abs(dx) + abs(dz)) {
                    // Roof slab, fallen in from the edges.
                    b = .Stone_Bricks
                } else if edge && lvl == 4 && lm_hash(wx, wz, seed + 4) < 0.6 {
                    b = .Stone_Bricks // lintel
                }
                set_voxel_world(t, wx, y, wz, b)
            }
        }
    }
    if in_footprint(t, lm.x, lm.z) {
        set_voxel_world(t, lm.x, floor_top, lm.z, .Stone_Bricks)
        set_voxel_world(t, lm.x, floor_top + 1, lm.z, .Crystal)
    }
}

generate_camp :: proc(t: ^Tree_Target, lm: Landmark) {
    seed := lm.seed
    rot := lm_hash(seed, 1, 3) * math.TAU
    clear_vegetation(t, lm, 13, lm.base + 40)
    // Palisade: sharpened spruce stakes on a ring, a gate on two sides, a
    // few fallen out.
    RING :: 9.5
    for wz in lm.z - 11 ..= lm.z + 11 {
        for wx in lm.x - 11 ..= lm.x + 11 {
            if !in_footprint(t, wx, wz) { continue }
            dx, dz := f64(wx - lm.x) + 0.5, f64(wz - lm.z) + 0.5
            r := math.sqrt(dx * dx + dz * dz)
            if abs(r - RING) > 0.55 { continue }
            a := math.atan2(dz, dx) - rot
            for a < 0 { a += math.TAU }
            gate := a < 0.32 || abs(a - math.PI) < 0.32
            if gate || lm_hash(wx, wz, seed + 3) < 0.12 { continue }
            g := lm_ground(t, wx, wz)
            h := 3 + int(lm_hash(wx, wz, seed + 5) * 2.5)
            for y in g - 1 ..< g + h { set_voxel_world(t, wx, y, wz, .Spruce_Log) }
        }
    }
    // Fire pit: a ring of stones around the fire.
    for dz in -1 ..= 1 {
        for dx in -1 ..= 1 {
            wx, wz := lm.x + dx, lm.z + dz
            if !in_footprint(t, wx, wz) { continue }
            g := lm_ground(t, wx, wz)
            set_voxel_world(t, wx, g - 1, wz, dx == 0 && dz == 0 ? .Gravel : .Stone)
            if dx == 0 && dz == 0 { set_voxel_world(t, wx, g, wz, .Torch) }
        }
    }
    // Log benches by the fire, lean-to huts of branches toward the stakes.
    for i in 0 ..< 3 {
        a := rot + math.PI * 0.5 + f64(i) * math.TAU / 3 + 0.3
        ca, sa := math.cos(a), math.sin(a)
        // Bench: three logs lying across the radius at distance 3.
        for k in -1 ..= 1 {
            wx := lm.x + int(math.round(ca * 3 - sa * f64(k)))
            wz := lm.z + int(math.round(sa * 3 + ca * f64(k)))
            if in_footprint(t, wx, wz) { set_voxel_world(t, wx, lm_ground(t, wx, wz), wz, .Log) }
        }
        // Hut: a sloped roof of leaves on a log ridge, open toward the fire.
        hx, hz := f64(lm.x) + ca * 6.5, f64(lm.z) + sa * 6.5
        for u in -2 ..= 2 {   // along the ridge (across the radius)
            for v in 0 ..= 3 { // from the front (toward the fire) back
                wx := int(math.round(hx - sa * f64(u) + ca * f64(v - 1)))
                wz := int(math.round(hz + ca * f64(u) + sa * f64(v - 1)))
                if !in_footprint(t, wx, wz) { continue }
                g := lm_ground(t, wx, wz)
                roof := 3 - v
                if v == 0 && abs(u) == 2 { for y in g ..< g + 3 { set_voxel_world(t, wx, y, wz, .Log) } }
                if roof >= 0 { set_voxel_world(t, wx, g + roof, wz, v == 0 ? .Log : .Spruce_Leaves) }
                if v == 3 { set_voxel_world(t, wx, g, wz, .Spruce_Leaves) }
            }
        }
    }
}

// ---- Cave crystals ----------------------------------------------------------

// Clusters of glowing crystal on the floors and ceilings of some caves:
// grottos are picked per 24^3 cell, then single floor/ceiling voxels by hash.
CRYSTAL_GROTTO :: 24

col_voxel :: #force_inline proc(col: ^Column, lx, wy, lz: int) -> u8 {
    iy := chunk_y_index(floor_div(wy, CHUNK_VOXELS))
    if iy < 0 { return 0 }
    c := &col.chunks[iy]
    ly := wy - floor_div(wy, CHUNK_VOXELS) * CHUNK_VOXELS
    return chunk_voxel(c, lx + ly * CHUNK_VOXELS + lz * CHUNK_VOXELS * CHUNK_VOXELS)
}

decorate_caves :: proc(col: ^Column, gx, gz: int, height: []int) {
    tgt := Tree_Target{col = col, ox = gx, oz = gz, size = CHUNK_VOXELS}
    for lz in 0 ..< CHUNK_VOXELS {
        for lx in 0 ..< CHUNK_VOXELS {
            wx, wz := gx + lx, gz + lz
            top := min(height[lx + lz * CHUNK_VOXELS] - CAVE_TOP_MARGIN - 4, CAVE_CEIL_Y)
            for wy := CAVE_FLOOR_Y + 1; wy < top; wy += 1 {
                if col_voxel(col, lx, wy, lz) != 0 { continue }
                below := col_voxel(col, lx, wy - 1, lz)
                above := col_voxel(col, lx, wy + 1, lz)
                floor := below == u8(Block_Type.Stone)
                ceil := above == u8(Block_Type.Stone)
                if !floor && !ceil { continue }
                gcell := tree_hash(floor_div(wx, CRYSTAL_GROTTO) * 3 + floor_div(wy, CRYSTAL_GROTTO),
                                   floor_div(wz, CRYSTAL_GROTTO), 555)
                if gcell > 0.08 { continue }
                h := tree_hash(wx * 5 + wy, wz * 11 - wy * 3, 556)
                if h > 0.02 { continue }
                n := 1 + int(tree_hash(wx, wz + wy, 557) * 3)
                for i in 0 ..< n {
                    y := floor ? wy + i : wy - i
                    if col_voxel(col, lx, y, lz) != 0 { break }
                    set_voxel_world(&tgt, wx, y, wz, .Crystal)
                }
            }
        }
    }
}
