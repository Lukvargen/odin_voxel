package main

import "core:math"
import "core:math/noise"

// Caves: where the ground is hollow, and what lives there.
//
// Three shapes, all in design blocks like the terrain (TERRAIN_SCALE):
//  - tunnels, winding tubes where two noise fields are both near zero;
//    in some places (entrance zones) they reach up through the surface;
//  - pockets, the blobs of one noise above a threshold;
//  - caverns, halls of a slow noise, only well below the sea.
// The noises are taken every CAVE_STEP blocks over a column (Cave_Field)
// and blended in between: a fraction of the cost of one noise per block.
//
// Decoration by zone (2D noise): lush caves (moss floors, ferns, hanging
// roots, glowing moss and mushrooms), dripstone caves (stalactites and
// stalagmites), and elsewhere a mushroom or a glow here and there; crystal
// grottos (landmarks.odin) anywhere.

CAVE_STEP       :: 4
CAVE_GRID_XZ    :: CHUNK_VOXELS / CAVE_STEP + 1
CAVE_GRID_ROWS  :: (WORLD_Y_MAX - WORLD_Y_MIN) / CAVE_STEP + 2
CAVE_TUBE_W     :: 0.2   // tunnel radius, in noise units
CAVE_POCKET     :: 0.6   // pocket noise above this is hollow
CAVE_CAVERN     :: 0.6   // cavern noise above this is hollow...
CAVE_CAVERN_TOP :: SEA_LEVEL - 12 // ...below this height

Cave_Field :: struct {
    y0:   int, // world y of row 0
    rows: int,
    v:    [CAVE_GRID_XZ * CAVE_GRID_ROWS * CAVE_GRID_XZ][4]f32, // pocket, tube a, tube b, cavern
}

// The cave noises over column (gx, gz) from y_lo to y_hi.
cave_field_make :: proc(f: ^Cave_Field, gx, gz, y_lo, y_hi: int) {
    f.y0 = floor_div(y_lo, CAVE_STEP) * CAVE_STEP
    f.rows = min((y_hi - f.y0) / CAVE_STEP + 2, CAVE_GRID_ROWS)
    for k in 0 ..< CAVE_GRID_XZ {
        for j in 0 ..< f.rows {
            for i in 0 ..< CAVE_GRID_XZ {
                p := [3]f64{f64(gx + i * CAVE_STEP), f64(f.y0 + j * CAVE_STEP), f64(gz + k * CAVE_STEP)} / TERRAIN_SCALE
                f.v[i + j * CAVE_GRID_XZ + k * CAVE_GRID_XZ * CAVE_GRID_ROWS] = {
                    noise.noise_3d_improve_xy(7, p * {0.026, 0.032, 0.026}),
                    noise.noise_3d_improve_xy(21, p * {0.018, 0.026, 0.018}),
                    noise.noise_3d_improve_xy(22, p * {0.018, 0.026, 0.018}),
                    noise.noise_3d_improve_xy(23, p * {0.009, 0.017, 0.009}),
                }
            }
        }
    }
}

// Whether block (lx, wy, lz) of the column is hollow; only tunnels count
// when tubes_only (the stretch up to the surface at an entrance).
cave_open :: proc(f: ^Cave_Field, lx, wy, lz: int, tubes_only: bool) -> bool {
    r := wy - f.y0
    j := r / CAVE_STEP
    if r < 0 || j + 1 >= f.rows { return false }
    i, k := lx / CAVE_STEP, lz / CAVE_STEP
    tx := f32(lx % CAVE_STEP) / CAVE_STEP
    ty := f32(r % CAVE_STEP) / CAVE_STEP
    tz := f32(lz % CAVE_STEP) / CAVE_STEP
    at :: #force_inline proc(f: ^Cave_Field, i, j, k: int) -> [4]f32 { return f.v[i + j * CAVE_GRID_XZ + k * CAVE_GRID_XZ * CAVE_GRID_ROWS] }
    x00 := math.lerp(at(f, i, j, k), at(f, i + 1, j, k), tx)
    x10 := math.lerp(at(f, i, j + 1, k), at(f, i + 1, j + 1, k), tx)
    x01 := math.lerp(at(f, i, j, k + 1), at(f, i + 1, j, k + 1), tx)
    x11 := math.lerp(at(f, i, j + 1, k + 1), at(f, i + 1, j + 1, k + 1), tx)
    v := math.lerp(math.lerp(x00, x10, ty), math.lerp(x01, x11, ty), tz)
    if v[1] * v[1] + v[2] * v[2] < CAVE_TUBE_W * CAVE_TUBE_W { return true }
    if tubes_only { return false }
    return v[0] > CAVE_POCKET || (wy < CAVE_CAVERN_TOP && v[3] > CAVE_CAVERN)
}

// Whether no block of the chunk from y gy up can be hollow: the corners of
// its cells say so for certain (blending never leaves the corners' range:
// pockets and caverns under their thresholds at every corner, or a tunnel
// noise clear of zero on one side at every corner).
cave_chunk_closed :: proc(f: ^Cave_Field, gy: int) -> bool {
    j0 := floor_div(gy - f.y0, CAVE_STEP)
    if j0 < 0 || j0 + CHUNK_VOXELS / CAVE_STEP >= f.rows { return j0 >= f.rows || j0 + CHUNK_VOXELS / CAVE_STEP < 0 }
    lo, hi := [4]f32{1e9, 1e9, 1e9, 1e9}, [4]f32{-1e9, -1e9, -1e9, -1e9}
    for k in 0 ..< CAVE_GRID_XZ {
        for j in j0 ..= j0 + CHUNK_VOXELS / CAVE_STEP {
            for i in 0 ..< CAVE_GRID_XZ {
                v := f.v[i + j * CAVE_GRID_XZ + k * CAVE_GRID_XZ * CAVE_GRID_ROWS]
                lo, hi = linalg_min(lo, v), linalg_max(hi, v)
            }
        }
    }
    if hi[0] > CAVE_POCKET { return false }
    if gy < CAVE_CAVERN_TOP && hi[3] > CAVE_CAVERN { return false }
    tube_a := lo[1] > CAVE_TUBE_W || hi[1] < -CAVE_TUBE_W
    tube_b := lo[2] > CAVE_TUBE_W || hi[2] < -CAVE_TUBE_W
    return tube_a || tube_b
}

@(private="file")
linalg_min :: #force_inline proc(a, b: [4]f32) -> [4]f32 { return {min(a[0], b[0]), min(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])} }
@(private="file")
linalg_max :: #force_inline proc(a, b: [4]f32) -> [4]f32 { return {max(a[0], b[0]), max(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])} }

// Whether a cave may open to the sky at (wx, wz): in scattered zones, on
// dry land.
cave_entrance :: proc(wx, wz, height: int) -> bool {
    if height < SEA_LEVEL + 3 { return false }
    return n2(91, [2]f64{f64(wx), f64(wz)} / (90 * TERRAIN_SCALE)) > 0.7
}

Cave_Zone :: enum u8 { Plain, Lush, Dripstone }

cave_zone :: proc(wx, wz: int) -> Cave_Zone {
    p := [2]f64{f64(wx), f64(wz)} / (180 * TERRAIN_SCALE)
    if n2(95, p) > 0.3 { return .Lush }
    if n2(96, p) > 0.35 { return .Dripstone }
    return .Plain
}

// Life on the walls, floors and ceilings of the column's caves.
decorate_cave_life :: proc(col: ^Column, gx, gz: int, height: []int) {
    tgt := Tree_Target{col = col, ox = gx, oz = gz, size = CHUNK_VOXELS}
    stone :: proc(b: u8) -> bool {
        return b == u8(Block_Type.Stone) || b == u8(Block_Type.Coal_Ore) || b == u8(Block_Type.Iron_Ore) ||
               b == u8(Block_Type.Gold_Ore) || b == u8(Block_Type.Dirt) || b == u8(Block_Type.Gravel)
    }
    for lz in 0 ..< CHUNK_VOXELS {
        for lx in 0 ..< CHUNK_VOXELS {
            wx, wz := gx + lx, gz + lz
            zone := cave_zone(wx, wz)
            top := min(height[lx + lz * CHUNK_VOXELS] - 3, CAVE_CEIL_Y)
            for wy := CAVE_FLOOR_Y + 1; wy < top; wy += 1 {
                if col_voxel(col, lx, wy, lz) != 0 { continue }
                below := col_voxel(col, lx, wy - 1, lz)
                above := col_voxel(col, lx, wy + 1, lz)
                floor, ceil := stone(below), stone(above)
                if !floor && !ceil { continue }
                h := tree_hash(wx * 7 + wy, wz * 13 - wy * 5, 600)
                h2 := tree_hash(wx * 3 - wy, wz * 17 + wy, 601)
                switch zone {
                case .Lush:
                    if floor {
                        set_voxel_world(&tgt, wx, wy - 1, wz, .Moss)
                        switch {
                        case h < 0.015: set_voxel_world(&tgt, wx, wy, wz, .Glow_Mushroom)
                        case h < 0.12:  set_voxel_world(&tgt, wx, wy, wz, .Fern)
                        case h < 0.30:  set_voxel_world(&tgt, wx, wy, wz, .Tall_Grass)
                        }
                    } else if ceil {
                        if h < 0.025 {
                            set_voxel_world(&tgt, wx, wy + 1, wz, .Glow_Moss)
                        } else if h < 0.16 {
                            for i in 0 ..< 1 + int(h2 * 5) {
                                if col_voxel(col, lx, wy - i, lz) != 0 { break }
                                set_voxel_world(&tgt, wx, wy - i, wz, .Roots)
                            }
                        } else if h2 < 0.45 {
                            set_voxel_world(&tgt, wx, wy + 1, wz, .Moss)
                        }
                    }
                case .Dripstone:
                    if floor {
                        if h2 < 0.5 { set_voxel_world(&tgt, wx, wy - 1, wz, .Dripstone) }
                        if h < 0.03 {
                            for i in 0 ..< 1 + int(h2 * 4) {
                                if col_voxel(col, lx, wy + i, lz) != 0 { break }
                                set_voxel_world(&tgt, wx, wy + i, wz, .Dripstone)
                            }
                        }
                    } else if ceil {
                        if h2 < 0.5 { set_voxel_world(&tgt, wx, wy + 1, wz, .Dripstone) }
                        if h < 0.06 {
                            for i in 0 ..< 1 + int(h2 * 6) {
                                if col_voxel(col, lx, wy - i, lz) != 0 { break }
                                set_voxel_world(&tgt, wx, wy - i, wz, .Dripstone)
                            }
                        }
                    }
                case .Plain:
                    if floor {
                        switch {
                        case h < 0.004: set_voxel_world(&tgt, wx, wy, wz, .Glow_Mushroom)
                        case h < 0.010: set_voxel_world(&tgt, wx, wy, wz, .Mushroom)
                        }
                    } else if ceil && h < 0.004 {
                        set_voxel_world(&tgt, wx, wy + 1, wz, .Glow_Moss)
                    }
                }
            }
        }
    }
}
