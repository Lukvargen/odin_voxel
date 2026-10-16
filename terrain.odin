package main

import "core:math"
import "core:math/noise"

// Terrain shape and biomes: a pure function of (x, z), shared by column
// generation (world.odin), the far LOD (far.odin), tree placement and spawn.
//
// Height = continent base (ocean floor .. inland plains)
//        + hills (amplitude varies region to region)
//        + ridged mountains (masked to mountain regions)
//        then badlands mesas (terraced), river valleys cut to below sea
//        level and ravines cut 30-55 voxels down with near-vertical walls.
// Biomes come from temperature (cooler with altitude) and moisture, plus
// height (ocean, beach, snow line) and slope (cliffs are bare rock).
//
// The shapes are designed in "design blocks" and built TERRAIN_SCALE times
// finer: a point samples the fields at its position / TERRAIN_SCALE, and
// heights stretch by TERRAIN_SCALE about the sea (world_height). Slopes
// come out the same per block; the design's height thresholds (biomes) stay
// in design blocks, the ones on world heights are converted.
//
// Fields that vary over hundreds of voxels are evaluated on a world-aligned
// lattice of COARSE voxels and bilinearly interpolated (Coarse_Grid): a
// column needs 9 lattice points instead of 100 full evaluations. The same
// lattice and weights are used everywhere, so a column, a far tile and a
// single-point query agree exactly.

SEA_LEVEL     :: 24  // open space below this y is water
TERRAIN_SCALE :: 1.5 // world blocks per design block (the player is ~2.8 blocks tall)
SNOW_LINE     :: 168 // design blocks: surface at or above this is snow-capped
TERRAIN_MAX   :: 470 // world height cap: the highest peaks stay below WORLD_Y_MAX
COARSE        :: 8   // coarse lattice spacing in voxels

// A design height (blocks, absolute) in world blocks.
world_height :: #force_inline proc "contextless" (h: f64) -> f64 {
    return f64(SEA_LEVEL) + (h - f64(SEA_LEVEL)) * TERRAIN_SCALE
}

// The same for integer thresholds.
world_h :: #force_inline proc "contextless" (h: int) -> int {
    return SEA_LEVEL + int(math.floor(f64(h - SEA_LEVEL) * TERRAIN_SCALE))
}

Biome :: enum u8 {
    Ocean, Beach, River, Plains, Forest, Taiga, Snowy, Desert, Badlands, Mountains, Peaks, Savanna,
}

// The slowly varying fields at one point.
Coarse_Fields :: struct {
    cont:     f64, // continentalness: < ~-0.1 ocean, > 0 land (lattice only, see continent_at)
    temp:     f64, // -1 cold .. 1 hot (before altitude cooling)
    moist:    f64, // -1 dry .. 1 wet
    hill_amp: f64, // hill amplitude in voxels
    mountain: f64, // 0..1 mountain mask
    badlands: f64, // 0..1 mesa weight
    ravines:  f64, // 0..1 ravine mask
    warp:     [2]f64, // domain warp for rivers/ravines
}

Terrain_Sample :: struct {
    height:   int, // surface y: the top solid voxel is height - 1
    biome:    Biome,
    temp:     f64, // altitude-adjusted
    moist:    f64,
    mountain: f64,
    detail:   f64, // small-scale noise in [-1, 1], for ragged borders
    wet:      f64, // 1 on a river's bank, fading to 0 away from it
}

n2 :: #force_inline proc(seed: i64, p: [2]f64) -> f64 {
    return f64(noise.noise_2d(seed, p))
}

@(private="file")
fbm :: proc(seed: i64, p: [2]f64, octaves: int) -> f64 {
    sum, amp, norm := 0.0, 1.0, 0.0
    q := p
    for o in 0 ..< octaves {
        sum  += n2(seed + i64(o), q) * amp
        norm += amp
        amp  *= 0.5
        q    *= 2.03
    }
    return sum / norm
}

// 1 on ridge lines, falling to 0 between them; sharper octaves add crags.
@(private="file")
ridged :: proc(seed: i64, p: [2]f64, octaves: int) -> f64 {
    sum, amp, norm := 0.0, 1.0, 0.0
    q := p
    for o in 0 ..< octaves {
        r := 1 - abs(n2(seed + i64(o), q))
        sum  += r * r * amp
        norm += amp
        amp  *= 0.5
        q    *= 2.1
    }
    return sum / norm
}

@(private="file")
smooth :: #force_inline proc(e0, e1, x: f64) -> f64 {
    t := clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}

// Continentalness and the warped position the climate fields use. Computed
// per voxel for the height (it sets the slope of lowlands, where kinks from
// interpolating it show as zigzag terrace edges), on the lattice otherwise.
@(private="file")
continent_at :: proc(p: [2]f64) -> (cont: f64, wp: [2]f64) {
    wp = p + 140 * [2]f64{n2(30, p / 900), n2(31, p / 900)}
    return fbm(10, wp / 3200, 3) * 1.3 + 0.1, wp
}

coarse_fields :: proc(lx, lz: int) -> Coarse_Fields {
    p := [2]f64{f64(lx * COARSE), f64(lz * COARSE)} / TERRAIN_SCALE // design blocks
    c: Coarse_Fields
    wp: [2]f64
    c.cont, wp = continent_at(p)
    c.temp     = fbm(20, wp / 4800, 2) * 1.9
    c.moist    = fbm(22, wp / 3600, 2) * 1.9
    c.hill_amp = 4 + 22 * smooth(-0.3, 0.5, fbm(23, p / 900, 2))
    land      := smooth(-0.05, 0.12, c.cont)
    c.mountain = smooth(-0.08, 0.3, fbm(12, wp / 2400, 2)) * land
    c.badlands = smooth(0.35, 0.55, c.temp) * smooth(-0.2, -0.4, c.moist) * land * (1 - c.mountain)
    c.ravines  = smooth(0.15, 0.35, n2(17, p / 1300)) * land
    c.warp     = 60 * [2]f64{n2(32, p / 380), n2(33, p / 380)}
    return c
}

// Height above sea level from continentalness, by linear segments.
@(private="file")
continent_base :: proc(c: f64) -> f64 {
    PTS :: [?][2]f64{{-1.0, -44}, {-0.35, -30}, {-0.12, -9}, {-0.04, 1}, {0.06, 6}, {0.35, 20}, {1.0, 40}}
    pts := PTS
    if c <= pts[0].x { return pts[0].y }
    for i in 1 ..< len(pts) {
        if c <= pts[i].x {
            t := (c - pts[i-1].x) / (pts[i].x - pts[i-1].x)
            return pts[i-1].y + (pts[i].y - pts[i-1].y) * t
        }
    }
    return pts[len(pts) - 1].y
}

// The four lattice points around a voxel, plus its bilinear weights.
Coarse_Cell :: struct {
    c: [4]Coarse_Fields, // (x0,z0) (x1,z0) (x0,z1) (x1,z1)
}

@(private="file")
coarse_lerp :: proc(cell: ^Coarse_Cell, fx, fz: f64) -> Coarse_Fields {
    w := [4]f64{(1 - fx) * (1 - fz), fx * (1 - fz), (1 - fx) * fz, fx * fz}
    r: Coarse_Fields
    for k in 0 ..< 4 {
        c := &cell.c[k]
        r.cont     += c.cont * w[k]
        r.temp     += c.temp * w[k]
        r.moist    += c.moist * w[k]
        r.hill_amp += c.hill_amp * w[k]
        r.mountain += c.mountain * w[k]
        r.badlands += c.badlands * w[k]
        r.ravines  += c.ravines * w[k]
        r.warp     += c.warp * w[k]
    }
    return r
}

// Full terrain at (wx, wz), given the lattice cell that contains it.
terrain_from_cell :: proc(cell: ^Coarse_Cell, wx, wz: int) -> Terrain_Sample {
    lx := wx >> 3; lz := wz >> 3 // COARSE == 8
    f := coarse_lerp(cell, f64(wx - lx * COARSE) / COARSE, f64(wz - lz * COARSE) / COARSE)
    p := [2]f64{f64(wx), f64(wz)} / TERRAIN_SCALE // design blocks

    cont, _ := continent_at(p)
    land   := smooth(-0.05, 0.12, cont)
    detail := n2(14, p / 24)
    h := f64(SEA_LEVEL) + continent_base(cont)
    h += fbm(11, p / 230, 3) * f.hill_amp * (0.35 + 0.65 * land)
    if f.mountain > 0.001 {
        // A broad uplift under ridged peaks, so ranges are massifs rather
        // than a web of thin ridges.
        r := ridged(13, p / 700, 4)
        h += f.mountain * (55 * f.mountain + r * r * 200)
    }
    h += detail * 1.2
    // Soft cap: the highest peaks are compressed instead of flattened.
    if h > 200 { h = 200 + (h - 200) * 0.8 }

    // Badlands: flat-topped mesas with steep terraced sides.
    if f.badlands > 0.001 {
        lift := h + (14 + 26 * smooth(-0.1, 0.4, n2(24, p / 300))) * f.badlands
        STEP :: 8.0
        k := lift / STEP
        fl := math.floor(k)
        terr := (fl + smooth(0.55, 0.8, k - fl)) * STEP
        h = h + (terr - h) * f.badlands
    }

    // Rivers: winding valleys whose beds sit just below sea level.
    wp := p + f.warp
    rv := abs(n2(15, wp / 1150))
    river := 1 - smooth(0.012, 0.05, rv)
    bed := f64(SEA_LEVEL) - 3 - 2 * (1 - smooth(0.0, 0.012, rv))
    if river > 0 && h > bed { h = h + (bed - h) * river }

    // Ravines: narrow, deep cuts with near-vertical walls, only on high ground.
    if f.ravines > 0.001 {
        rw := 0.022 + 0.01 * n2(19, p / 500)
        ra := abs(n2(16, wp / 430))
        if ra < rw {
            high  := smooth(f64(SEA_LEVEL) + 12, f64(SEA_LEVEL) + 40, h)
            depth := (38 + 16 * n2(18, p / 90)) * f.ravines * high * smooth(rw, rw * 0.6, ra)
            h -= depth
        }
    }

    s := Terrain_Sample{
        height   = clamp(int(math.floor(world_height(h))), WORLD_Y_MIN + 8, TERRAIN_MAX),
        moist    = f.moist + detail * 0.04,
        mountain = f.mountain,
        detail   = detail,
        wet      = 1 - smooth(0.03, 0.09, rv),
    }
    s.temp = f.temp + detail * 0.04 - max(0, h - f64(SEA_LEVEL) - 50) / 160

    // Biome, by the design height.
    dh := int(math.floor(h))
    switch {
    case s.height < SEA_LEVEL - 1:
        s.biome = river > 0.5 && land > 0.5 ? .River : .Ocean
    case dh <= SEA_LEVEL + 1 && f.mountain < 0.3:
        s.biome = river > 0.5 ? .River : .Beach
    case dh >= SNOW_LINE + int(detail * 6):
        s.biome = .Peaks
    case f.mountain > 0.45 && dh > 118:
        s.biome = .Mountains
    case s.temp < -0.45:
        s.biome = .Snowy
    case s.temp < -0.12:
        s.biome = .Taiga
    case f.badlands > 0.5:
        s.biome = .Badlands
    case s.temp > 0.3 && s.moist < 0.0:
        s.biome = .Desert
    case s.temp > 0.22 && s.moist < 0.12:
        s.biome = .Savanna
    case s.moist > 0.12:
        s.biome = .Forest
    case:
        s.biome = .Plains
    }
    return s
}

coarse_cell_at :: proc(wx, wz: int) -> Coarse_Cell {
    lx := wx >> 3; lz := wz >> 3 // COARSE == 8
    return {c = {coarse_fields(lx, lz), coarse_fields(lx + 1, lz), coarse_fields(lx, lz + 1), coarse_fields(lx + 1, lz + 1)}}
}

// Single-point query (trees, spawn, cave darkness). A grid of samples is
// much cheaper through terrain_grid.
terrain_at :: proc(wx, wz: int) -> Terrain_Sample {
    cell := coarse_cell_at(wx, wz)
    return terrain_from_cell(&cell, wx, wz)
}

surface_height_at :: proc(wx, wz: int) -> int {
    return terrain_at(wx, wz).height
}

// Samples for the w x d voxels starting at (ox, oz), row-major into out.
terrain_grid :: proc(ox, oz, w, d: int, out: []Terrain_Sample) {
    assert(len(out) >= w * d)
    lat := terrain_lattice(ox, oz, w, d)
    for z in 0 ..< d {
        for x in 0 ..< w { out[x + z * w] = lattice_sample(&lat, ox + x, oz + z) }
    }
}

// The coarse fields covering a w x d voxel area from (ox, oz), so many
// samples in it (a grid, or scattered tree spots) share lattice points.
Terrain_Lattice :: struct {
    lx0, lz0, lw, ld: int,
    fields: []Coarse_Fields, // temp allocated
}

terrain_lattice :: proc(ox, oz, w, d: int) -> Terrain_Lattice {
    l := Terrain_Lattice{lx0 = ox >> 3, lz0 = oz >> 3} // COARSE == 8
    l.lw = ((ox + w - 1) >> 3) - l.lx0 + 2
    l.ld = ((oz + d - 1) >> 3) - l.lz0 + 2
    l.fields = make([]Coarse_Fields, l.lw * l.ld, context.temp_allocator)
    for z in 0 ..< l.ld {
        for x in 0 ..< l.lw { l.fields[x + z * l.lw] = coarse_fields(l.lx0 + x, l.lz0 + z) }
    }
    return l
}

// Terrain at (wx, wz), which must lie inside the lattice's area.
lattice_sample :: proc(l: ^Terrain_Lattice, wx, wz: int) -> Terrain_Sample {
    ix := (wx >> 3) - l.lx0; iz := (wz >> 3) - l.lz0
    f := l.fields
    cell := Coarse_Cell{c = {
        f[ix + iz * l.lw],       f[ix + 1 + iz * l.lw],
        f[ix + (iz + 1) * l.lw], f[ix + 1 + (iz + 1) * l.lw],
    }}
    return terrain_from_cell(&cell, wx, wz)
}

// Steepness at a sample: the largest height step to a 4-neighbour.
terrain_slope :: proc(c, xn, xp, zn, zp: int) -> int {
    return max(abs(c - xn), abs(c - xp), abs(c - zn), abs(c - zp))
}

// What a surface column is made of: `top` on the surface voxel, `filler`
// for the next filler_depth - 1 voxels, then stone.
Surface_Layers :: struct {
    top, filler:  Block_Type,
    filler_depth: int,
    frozen:       bool, // water here freezes over at the surface
}

CLIFF_SLOPE :: 3 // height step at which a slope shows bare rock

surface_layers :: proc(s: Terrain_Sample, slope: int) -> Surface_Layers {
    l := surface_layers_design(s, slope)
    if l.filler_depth > 1 { l.filler_depth = int(math.round(f64(l.filler_depth) * TERRAIN_SCALE)) }
    return l
}

// The layers in design blocks.
@(private="file")
surface_layers_design :: proc(s: Terrain_Sample, slope: int) -> Surface_Layers {
    frozen := s.temp < -0.75
    cliff := slope >= CLIFF_SLOPE
    #partial switch s.biome {
    case .Ocean, .River:
        if s.height >= world_h(SEA_LEVEL - 6) || s.biome == .River {
            return {top = frozen ? .Gravel : .Sand, filler = .Sand, filler_depth = 3, frozen = frozen}
        }
        return {top = s.detail > 0.1 ? .Sand : .Gravel, filler = .Gravel, filler_depth = 2, frozen = frozen}
    case .Beach:
        if frozen { return {top = .Gravel, filler = .Gravel, filler_depth = 3} }
        return {top = .Sand, filler = .Sand, filler_depth = 4}
    case .Peaks:
        if slope >= 5 { return {top = .Weathered_Stone, filler = .Stone, filler_depth = 1} }
        return {top = .Snow, filler = .Stone, filler_depth = 1}
    case .Mountains:
        if cliff || s.height > world_h(145) { return {top = .Weathered_Stone, filler = .Stone, filler_depth = 1} }
        if s.detail > 0.35 { return {top = .Gravel, filler = .Stone, filler_depth = 1} }
        return {top = .Grass, filler = .Dirt, filler_depth = 2}
    case .Badlands:
        return {top = cliff ? .Terracotta : .Red_Sand, filler = .Terracotta, filler_depth = 48}
    case .Desert:
        return {top = cliff ? .Sandstone : .Sand, filler = .Sandstone, filler_depth = 10}
    case .Savanna:
        if cliff { return {top = .Weathered_Stone, filler = .Stone, filler_depth = 1} }
        return {top = .Dry_Grass, filler = .Dirt, filler_depth = 3}
    case .Snowy:
        if cliff { return {top = .Weathered_Stone, filler = .Stone, filler_depth = 1, frozen = true} }
        return {top = .Snow, filler = .Dirt, filler_depth = 3, frozen = true}
    }
    // Plains, forest, taiga.
    if cliff { return {top = .Weathered_Stone, filler = .Stone, filler_depth = 1} }
    return {top = .Grass, filler = .Dirt, filler_depth = 4}
}

// ---- Trees ---------------------------------------------------------------

Tree_Kind :: enum u8 { None, Oak, Medium_Oak, Small_Oak, Bush, Spruce, Cactus, Birch, Dead, Fallen_Log, Acacia, Willow }

// Tree densities (trees per voxel of ground) by biome. A candidate spot is
// rejected by its hash against the densest biome before any terrain is
// sampled, so sparse biomes cost almost nothing.
TREE_MAX_DENSITY :: 1.0 / 50.0 / (TERRAIN_SCALE * TERRAIN_SCALE) // per world block

@(private="file")
Tree_Rate :: struct { kind: Tree_Kind, density: f64 }

// Per design block of ground; together at most TREE_MAX_DENSITY. Cooler
// forests are birch woods; a few dead trees and fallen logs about.
@(private="file")
biome_trees :: proc(s: Terrain_Sample) -> [6]Tree_Rate {
    // River banks: willows lean over the water.
    if s.wet > 0.4 && (s.biome == .Plains || s.biome == .Forest || s.biome == .Savanna) {
        return {{.Willow, 1.0 / 160}, {.Bush, 1.0 / 300}, {.Small_Oak, 1.0 / 900}, {}, {}, {}}
    }
    #partial switch s.biome {
    case .Forest:
        if s.temp < 0 {
            return {{.Birch, 1.0 / 90}, {.Medium_Oak, 1.0 / 900}, {.Small_Oak, 1.0 / 600}, {.Bush, 1.0 / 700}, {.Oak, 1.0 / 3000}, {.Fallen_Log, 1.0 / 1500}}
        }
        return {{.Small_Oak, 1.0 / 200}, {.Medium_Oak, 1.0 / 300}, {.Birch, 1.0 / 300}, {.Bush, 1.0 / 500}, {.Oak, 1.0 / 900}, {.Fallen_Log, 1.0 / 1500}}
    case .Plains:
        return {{.Bush, 1.0 / 350}, {.Small_Oak, 1.0 / 900}, {.Medium_Oak, 1.0 / 1800}, {.Oak, 1.0 / 4000}, {s.temp < 0 ? .Birch : .None, 1.0 / 2500}, {.Dead, 1.0 / 6000}}
    case .Taiga:     return {{.Spruce, 1.0 / 66}, {.Birch, 1.0 / 900}, {.Fallen_Log, 1.0 / 1500}, {.Dead, 1.0 / 3000}, {}, {}}
    case .Snowy:     return {{.Spruce, 1.0 / 260}, {.Dead, 1.0 / 4000}, {}, {}, {}, {}}
    case .Mountains: if s.height < world_h(150) { return {{.Spruce, 1.0 / 140}, {.Dead, 1.0 / 5000}, {}, {}, {}, {}} }
    case .Savanna:   return {{.Acacia, 1.0 / 1100}, {.Bush, 1.0 / 700}, {.Dead, 1.0 / 4000}, {}, {}, {}}
    case .Desert:    return {{.Cactus, 1.0 / 380}, {.Dead, 1.0 / 5000}, {}, {}, {}, {}}
    case .Badlands:  return {{.Cactus, 1.0 / 1600}, {.Dead, 1.0 / 2500}, {}, {}, {}, {}}
    }
    return {}
}

// The tree rooted at (wx, wz), if any, and its base y (the surface). lat
// must cover (wx .. wx + 2, wz); tree_lattice builds one for a scan area.
tree_at :: proc(lat: ^Terrain_Lattice, wx, wz: int) -> (kind: Tree_Kind, base_y: int) {
    h := tree_hash(wx, wz, 42)
    if h >= TREE_MAX_DENSITY { return .None, 0 }
    s := lattice_sample(lat, wx, wz)
    if s.height < SEA_LEVEL + 1 { return .None, 0 }
    acc := 0.0
    for r in biome_trees(s) {
        acc += r.density / (TERRAIN_SCALE * TERRAIN_SCALE) // designed per design block of ground
        if h < acc {
            // No trees on cliffs (a probe 2 voxels out is enough).
            if r.kind == .None { return .None, 0 }
            if r.kind != .Cactus && abs(lattice_sample(lat, wx + 3, wz).height - s.height) >= CLIFF_SLOPE + 2 { return .None, 0 }
            return r.kind, s.height
        }
    }
    return .None, 0
}

// Lattice for tree_at over every tree base that can reach the size x size
// footprint at (ox, oz).
tree_lattice :: proc(ox, oz, size: int) -> Terrain_Lattice {
    return terrain_lattice(ox - TREE_VOXEL_REACH, oz - TREE_VOXEL_REACH,
                           size + 2 * TREE_VOXEL_REACH + 2, size + 2 * TREE_VOXEL_REACH)
}

// ---- Ores ----------------------------------------------------------------

// Small ore blobs in the stone of the cave band: each 4^3 cell may hold one
// blob, chosen by an integer hash (no noise).
ore_at :: proc(wx, wy, wz: int) -> Block_Type {
    cx, cy, cz := wx >> 2, wy >> 2, wz >> 2
    h := u64(cx * 73856093 ~ cy * 19349663 ~ cz * 83492791 ~ 0x5bd1e995)
    h = h ~ (h >> 29); h *= 0xbf58476d1ce4e5b9
    h = h ~ (h >> 32)
    r := f64(h & 0xFFFF) / 65536.0
    kind: Block_Type
    switch {
    case r < 0.045 && wy < world_h(140): kind = .Coal_Ore
    case r < 0.062 && wy < world_h(40):  kind = .Iron_Ore
    case r < 0.068 && wy < world_h(-8):  kind = .Gold_Ore
    case: return .Stone
    }
    // Blob centre inside the cell, radius^2 2..3.
    dx := (wx & 3) - int((h >> 16) & 3)
    dy := (wy & 3) - int((h >> 18) & 3)
    dz := (wz & 3) - int((h >> 20) & 3)
    if dx*dx + dy*dy + dz*dz <= 2 + int((h >> 22) & 1) { return kind }
    return .Stone
}

// ---- Spawn ---------------------------------------------------------------

// A dry spot near the origin, searched outward in rings.
find_spawn :: proc() -> [3]f32 {
    for r := 0; r < 6000; r += 48 {
        steps := max(1, r / 16)
        for i in 0 ..< steps {
            a := f64(i) / f64(steps) * math.TAU
            x := int(math.cos(a) * f64(r)); z := int(math.sin(a) * f64(r))
            s := terrain_at(x, z)
            if s.height > SEA_LEVEL + 3 && s.height < world_h(110) && s.biome != .Beach {
                return {f32(x) + 0.5, f32(s.height) + 3, f32(z) + 0.5}
            }
        }
    }
    return {0.5, f32(surface_height_at(0, 0)) + 3, 0.5}
}
