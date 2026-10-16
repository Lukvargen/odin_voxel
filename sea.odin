package main

import "core:math"
import la "core:math/linalg"
import "core:math/rand"
import "core:time"

// Sea life. The ocean (and rivers) come in three kinds by temperature, each
// with its own floor life, placed per column at generation time
// (decorate_ocean):
//   warm:      coral reefs in the shallows (reef heads of many colours,
//              seagrass, glowing sea pickles), seagrass on the sand around
//   temperate: kelp forests wherever it's deep enough, seagrass meadows in
//              the shallows
//   cold:      grey gravel with a few kelp stalks
// Plants stop two voxels under the surface so the water surface stays whole.

Sea_Kind :: enum u8 { None, Warm, Temperate, Cold }

sea_kind :: proc(s: Terrain_Sample) -> Sea_Kind {
    if s.biome != .Ocean && s.biome != .River { return .None }
    if s.temp > 0.15  { return .Warm }
    if s.temp < -0.35 { return .Cold }
    return .Temperate
}

PLANT_TOP :: SEA_LEVEL - 2 // highest voxel a plant or reef may fill
KELP_MAX  :: 14             // tallest kelp stalk

// Floor life for one generated column. height: surface height per voxel
// column (the first water voxel), kinds: its sea kind.
decorate_ocean :: proc(col: ^Column, gx, gz: int, height: []int, kinds: []Sea_Kind) {
    tgt := Tree_Target{col = col, ox = gx, oz = gz, size = CHUNK_VOXELS}
    water := u8(Block_Type.Water)
    for lz in 0 ..< CHUNK_VOXELS {
        for lx in 0 ..< CHUNK_VOXELS {
            i := lx + lz * CHUNK_VOXELS
            kind := kinds[i]
            h := height[i]
            if kind == .None || h > PLANT_TOP { continue }
            if col_voxel(col, lx, h, lz) != water || !block_solid(col_voxel(col, lx, h - 1, lz)) { continue }
            wx, wz := gx + lx, gz + lz
            depth := SEA_LEVEL - h
            r := tree_hash(wx, wz, 700)
            p := [2]f64{f64(wx), f64(wz)}
            switch kind {
            case .None:
            case .Warm:
                reef := n2(41, p / 36) > -0.15 && depth <= 16
                if reef && r < 0.09 {
                    sea_coral_head(&tgt, col, lx, lz, wx, h, wz)
                } else if reef && r < 0.12 {
                    sea_column(&tgt, col, lx, lz, wx, h, wz, .Sea_Pickle, 1)
                } else if r < (reef ? 0.45 : 0.18) {
                    sea_column(&tgt, col, lx, lz, wx, h, wz, .Seagrass, r < 0.1 ? 2 : 1)
                }
            case .Temperate:
                forest := n2(42, p / 60) > -0.05 && depth >= 5
                if forest && r < 0.24 {
                    // Capped: every water chunk a kelp stalk crosses stops
                    // being uniform, which costs the rays that cross it.
                    r2 := tree_hash(wx, wz, 701)
                    sea_column(&tgt, col, lx, lz, wx, h, wz, .Kelp, clamp(int(f64(depth) * (0.45 + 0.5 * r2)), 2, KELP_MAX))
                } else if depth <= 14 && r < 0.3 {
                    sea_column(&tgt, col, lx, lz, wx, h, wz, .Seagrass, r < 0.06 ? 2 : 1)
                }
            case .Cold:
                if depth >= 6 && r < 0.035 {
                    sea_column(&tgt, col, lx, lz, wx, h, wz, .Kelp, max(2, int(f64(depth) * 0.5)))
                } else if r < 0.06 {
                    sea_column(&tgt, col, lx, lz, wx, h, wz, .Seagrass, 1)
                }
            }
        }
    }
}

// A stack of `block` up from the floor at y = h, through water only and
// never above PLANT_TOP.
@(private="file")
sea_column :: proc(tgt: ^Tree_Target, col: ^Column, lx, lz, wx, h, wz: int, block: Block_Type, n: int) {
    for y in h ..< min(h + n, PLANT_TOP + 1) {
        if col_voxel(col, lx, y, lz) != u8(Block_Type.Water) { break }
        set_voxel_world(tgt, wx, y, wz, block)
    }
}

// A reef head: a mound, a branching stand or a tall pillar of coral, with
// sea pickles nestled at its foot. Parts that would leave the column are
// clipped (set_voxel_world), so heads at a border just come out lopsided.
@(private="file")
sea_coral_head :: proc(tgt: ^Tree_Target, col: ^Column, lx, lz, wx, h, wz: int) {
    in_water :: proc(col: ^Column, lx, y, lz: int) -> bool {
        if lx < 0 || lz < 0 || lx >= CHUNK_VOXELS || lz >= CHUNK_VOXELS || y > PLANT_TOP { return false }
        return col_voxel(col, lx, y, lz) == u8(Block_Type.Water)
    }
    put :: proc(tgt: ^Tree_Target, col: ^Column, lx, lz, wx, y, wz: int, b: Block_Type) {
        if in_water(col, lx, y, lz) { set_voxel_world(tgt, wx, y, wz, b) }
    }
    SIDES :: [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
    shape := int(tree_hash(wx, wz, 710) * 3)
    tall := 1 + int(tree_hash(wx, wz, 711) * 4) // 1..4
    switch shape {
    case 0: // mound: a low dome three wide
        for d in SIDES { put(tgt, col, lx + d.x, lz + d.y, wx + d.x, h, wz + d.y, .Coral) }
        for y in 0 ..< min(tall, 2) { put(tgt, col, lx, lz, wx, h + y, wz, .Coral) }
    case 1: // branching: a trunk with arms that turn upward
        for y in 0 ..< tall + 1 { put(tgt, col, lx, lz, wx, h + y, wz, .Coral) }
        for d, k in SIDES {
            if tree_hash(wx + k, wz, 712) < 0.5 { continue }
            y0 := h + 1 + int(tree_hash(wx, wz + k, 713) * f64(tall))
            put(tgt, col, lx + d.x, lz + d.y, wx + d.x, y0, wz + d.y, .Coral)
            put(tgt, col, lx + d.x, lz + d.y, wx + d.x, y0 + 1, wz + d.y, .Coral)
        }
    case: // pillar
        for y in 0 ..< tall + 2 { put(tgt, col, lx, lz, wx, h + y, wz, .Coral) }
    }
    // Sea pickles at the foot.
    for d, k in SIDES {
        if tree_hash(wx - k, wz + k, 714) < 0.3 { put(tgt, col, lx + d.x, lz + d.y, wx + d.x, h, wz + d.y, .Sea_Pickle) }
    }
}

// ─── Fish ───────────────────────────────────────────────────────────────────
// Schools swim around the player in any sea: a school is a point that
// wanders through open water (turning back from the floor, the surface and
// walls) and every fish holds its own slot around it, slowly circling, so
// the school stays loose and shifting. Within FISH_FLEE_DIST of the player
// a school bolts away. Schools spawn in water around the player and are
// dropped once far away. Their look comes from the sea kind: small bright
// reef fish (some striped) in warm seas, silver shoals in temperate ones, a
// few big grey-brown fish in the cold.

MAX_FISH_SCHOOLS :: 6
FISH_SPAWN_MIN   :: f32(6)
FISH_SPAWN_MAX   :: f32(24)  // about how far you can see under water
FISH_DROP_DIST   :: f32(48)
FISH_FLEE_DIST   :: f32(5)
FISH_CRUISE      :: f32(1.4) // m/s
FISH_BOLT        :: f32(5.0) // m/s, fleeing

Fish_School :: struct {
    alive:     bool,
    kind:      Sea_Kind,
    pos:       [3]f32,
    heading:   f32, // yaw (entity convention)
    climb:     f32, // vertical drift, m/s
    next_turn: f32,
    flee:      f32, // seconds of bolting left
}

@(private="file")
fish_schools: [MAX_FISH_SCHOOLS]Fish_School
@(private="file")
fish_next_manage: f32

@(private="file")
fish_watery :: proc(gs: ^Game_State, p: [3]f32) -> bool {
    return block_is_watery(u8(get_voxel(gs, int(math.floor(p.x)), int(math.floor(p.y)), int(math.floor(p.z)))))
}

// Room to swim at p: water there and a little above and below it.
@(private="file")
fish_room :: proc(gs: ^Game_State, p: [3]f32) -> bool {
    return fish_watery(gs, p) && fish_watery(gs, p + {0, 0.7, 0}) && fish_watery(gs, p - {0, 0.6, 0})
}

TROPICAL_TINTS := [?][3]f32{
    {1.00, 0.45, 0.10}, {1.00, 0.84, 0.18}, {0.20, 0.45, 1.00},
    {0.62, 0.30, 0.92}, {0.95, 0.25, 0.28}, {0.20, 0.85, 0.75},
}

// Every frame: drop far schools and add new ones about once a second, then
// move the schools.
fish_schools_update :: proc(gs: ^Game_State, dt, t: f32) {
    if t >= fish_next_manage {
        t0 := time.tick_now()
        fish_manage(gs)
        profile_add(.Ent_Fish, t0)
        fish_next_manage = t + 1
    }
    cam := gs.camera.pos
    for &sc in fish_schools {
        if !sc.alive { continue }
        to := sc.pos - cam
        if la.length(to) < FISH_FLEE_DIST {
            sc.flee = 1.5
            sc.heading = math.atan2(-to.x, to.z)
            sc.climb = clamp(to.y, -1, 1) * 0.5
        }
        if t >= sc.next_turn && sc.flee <= 0 {
            sc.heading += rand.float32_range(-0.9, 0.9)
            sc.climb = rand.float32_range(-0.25, 0.25)
            sc.next_turn = t + rand.float32_range(2, 5)
        }
        sc.flee -= dt
        speed := sc.flee > 0 ? FISH_BOLT : FISH_CRUISE
        dir := [3]f32{-math.sin(sc.heading), 0, math.cos(sc.heading)}
        // Look ahead: turn away from what's in front, toward the open side.
        if !fish_room(gs, sc.pos + dir * 2.5) {
            a := sc.heading + 1.2
            left_blocked := !fish_room(gs, sc.pos + [3]f32{-math.sin(a), 0, math.cos(a)} * 2.5)
            sc.heading += (left_blocked ? -2.2 : 2.2) * dt
            speed *= 0.5
        }
        // Off the surface and the floor.
        if !fish_watery(gs, sc.pos + {0, 1.2, 0}) { sc.climb = -0.3 }
        if !fish_watery(gs, sc.pos - {0, 1.2, 0}) { sc.climb = 0.3 }
        np := sc.pos + dir * speed * dt + {0, sc.climb * dt, 0}
        if fish_room(gs, np) { sc.pos = np } else { sc.heading += math.PI * 0.6 * dt }
    }
}

fish_manage :: proc(gs: ^Game_State) {
    cam := gs.camera.pos
    for &sc in fish_schools {
        if sc.alive && la.length(sc.pos - cam) > FISH_DROP_DIST { sc.alive = false }
    }
    for i := len(gs.entities) - 1; i >= 0; i -= 1 {
        e := gs.entities[i]
        if e.kind == .Fish && !fish_schools[e.school].alive { unordered_remove(&gs.entities, i) }
    }
    for _ in 0 ..< 4 {
        slot := -1
        for sc, i in fish_schools { if !sc.alive { slot = i; break } }
        if slot < 0 { return }
        a := rand.float32_range(0, 2 * math.PI)
        r := rand.float32_range(FISH_SPAWN_MIN, FISH_SPAWN_MAX)
        x, z := cam.x + math.cos(a) * r, cam.z + math.sin(a) * r
        s := terrain_at(int(math.floor(x)), int(math.floor(z)))
        kind := sea_kind(s)
        depth := SEA_LEVEL - s.height
        if kind == .None || depth < 4 { continue }
        p := [3]f32{x, f32(s.height) + rand.float32_range(1.5, f32(depth) - 1.5), z}
        if !fish_room(gs, p) { continue }
        fish_schools[slot] = {alive = true, kind = kind, pos = p, heading = rand.float32_range(0, 2 * math.PI)}
        n: int
        tint: [3]f32
        scale: f32
        switch kind {
        case .None:
        case .Warm:      n, tint, scale = rand.int_max(5) + 3, TROPICAL_TINTS[rand.int_max(len(TROPICAL_TINTS))], 0.75
        case .Temperate: n, tint, scale = rand.int_max(6) + 5, {0.62, 0.72, 0.82}, 0.8
        case .Cold:      n, tint, scale = rand.int_max(4) + 3, {0.55, 0.50, 0.40}, 1.25
        }
        striped := kind == .Warm && rand.float32() < 0.5
        for _ in 0 ..< n {
            ang := rand.float32_range(0, 2 * math.PI)
            rad := rand.float32_range(0.4, 1.6) * (kind == .Temperate ? 1.3 : 1)
            off := [3]f32{math.cos(ang) * rad, rand.float32_range(-0.5, 0.5), math.sin(ang) * rad}
            append(&gs.entities, Entity{
                kind   = .Fish,
                pos    = p + off,
                yaw    = fish_schools[slot].heading,
                school = i32(slot),
                orbit  = {ang, rad, off.y, striped ? 1 : 0},
                phase  = rand.float32_range(0, 2 * math.PI),
                scale  = scale * rand.float32_range(0.85, 1.15),
                color  = tint * rand.float32_range(0.9, 1.1),
            })
        }
    }
}

// Hold the slot around the school (slowly circling it), steering by velocity.
fish_update :: proc(gs: ^Game_State, e: ^Entity, dt, t: f32) {
    sc := &fish_schools[e.school]
    if !sc.alive { return }
    a := e.orbit[0] + t * 0.25
    target := sc.pos + {math.cos(a) * e.orbit[1], e.orbit[2] + 0.25 * math.sin(t * 0.7 + e.phase), math.sin(a) * e.orbit[1]}
    top := (sc.flee > 0 ? FISH_BOLT : FISH_CRUISE) * 1.6 + 0.5
    want := (target - e.pos) * 1.5
    if l := la.length(want); l > top { want *= top / l }
    e.vel += (want - e.vel) * min(dt * 3, 1)
    np := e.pos + e.vel * dt
    if fish_watery(gs, np) { e.pos = np } else { e.vel *= -0.3 }
    if e.vel.x * e.vel.x + e.vel.z * e.vel.z > 0.01 {
        want_yaw := math.atan2(-e.vel.x, e.vel.z)
        dyaw := math.mod(want_yaw - e.yaw + 3 * math.PI, 2 * math.PI) - math.PI
        e.yaw += clamp(dyaw, -6 * dt, 6 * dt)
    }
    e.speed = la.length(e.vel)
    e.walk_phase += dt * (5 + e.speed * 7) // tail beat
}

fish_add :: proc(f: ^Ent_Frame, e: Entity, t: f32) {
    s := e.scale
    h := math.sqrt(e.vel.x * e.vel.x + e.vel.z * e.vel.z)
    pitch := clamp(math.atan2(e.vel.y, max(h, 0.2)), -0.6, 0.6)
    rot := basis_yaw(e.yaw) * basis_rot_x(-pitch)
    beat := (0.25 + 0.2 * clamp(e.speed / FISH_BOLT, 0, 1)) * math.sin(e.walk_phase)
    body := e.orbit[3] > 0.5 ? Model_Id.Fish_Body_Striped : Model_Id.Fish_Body
    // The body sways a little against the tail.
    ent_part(f, body, e.pos, rot * basis_yaw(-beat * 0.25), {s, s, s}, e.color)
    ent_part(f, .Fish_Tail, e.pos + rot * [3]f32{0, 0, -0.17 * s}, rot * basis_yaw(beat), {s, s, s}, e.color)
}

// Body: a deep, narrow fish with a dorsal fin, pale belly and dark eyes,
// nose toward +z. Striped: two white bands (reef fish).
@(private="file")
shape_fish :: proc(p: [3]f32, voxel: f32, striped: bool) -> Pal {
    q := [3]f32{p.x / 0.05, p.y / 0.085, (p.z - 0.01) / 0.19}
    if q.x * q.x + q.y * q.y + q.z * q.z >= 1 {
        // Dorsal fin: a thin sail along the back, tallest mid-body.
        if abs(p.x) < 0.012 && p.z > -0.1 && p.z < 0.07 && p.y > 0.05 {
            top := 0.07 + 0.07 * (1 - abs(p.z + 0.015) / 0.085)
            if p.y < top { return .Fish_Fin }
        }
        // Belly fin.
        if abs(p.x) < 0.012 && p.z > -0.08 && p.z < -0.02 && p.y < -0.06 && p.y > -0.11 { return .Fish_Fin }
        return .Empty
    }
    if p.z > 0.11 && p.z < 0.15 && abs(abs(p.x) - 0.035) < 0.017 && p.y > 0.0 && p.y < 0.035 { return .Eye }
    if striped && ((p.z > 0.06 && p.z < 0.09) || (p.z > -0.07 && p.z < -0.04)) { return .Fish_Stripe }
    if p.y < -0.03 { return .Fish_Belly }
    return .Fish_Scale
}

@(private="file")
shape_fish_plain :: proc(p: [3]f32, voxel: f32) -> Pal { return shape_fish(p, voxel, false) }
@(private="file")
shape_fish_striped :: proc(p: [3]f32, voxel: f32) -> Pal { return shape_fish(p, voxel, true) }

// Tail fin, pivot at its root, forked, along -z.
@(private="file")
shape_fish_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    if abs(p.x) > 0.012 || p.z > 0.02 || p.z < -0.15 { return .Empty }
    back := -p.z
    if abs(p.y) > 0.02 + back * 0.6 { return .Empty }
    if back > 0.1 && abs(p.y) < (back - 0.1) * 1.2 { return .Empty } // fork
    return back < 0.02 ? .Fish_Scale : .Fish_Fin
}

fish_models_bake :: proc() {
    ent_models[.Fish_Body]         = model_bake({-0.06, -0.12, -0.2}, {0.06, 0.15, 0.22}, 1.0 / 40, shape_fish_plain)
    ent_models[.Fish_Body_Striped] = model_bake({-0.06, -0.12, -0.2}, {0.06, 0.15, 0.22}, 1.0 / 40, shape_fish_striped)
    ent_models[.Fish_Tail]         = model_bake({-0.02, -0.12, -0.16}, {0.02, 0.12, 0.03}, 1.0 / 40, shape_fish_tail)
}
