package main

import "core:math"
import "core:math/rand"
import "core:mem"
import "core:time"
import SDL "vendor:sdl3"

// Entities (foxes, hovering crystals, eagles circling in thermals, fish). The CPU
// owns the canonical list and runs the cheap "AI"; each frame the nearest
// MAX_ENTITIES within their kind's cull radius are turned into rigid
// voxel-model parts (voxel_models.odin, creatures.odin) — animation is just
// where those parts are put — and uploaded for the tracer
// (shaders/entity_voxel.hlsl).

MAX_ENTITIES        :: 128 // one bit each in the 128-bit culling masks (voxel_models.odin)
ENTITY_CULL_RADIUS  :: f32(96.0)  // gather range around camera (birds: BIRD_CULL_RADIUS)
FOX_WALK_SPEED      : f32 = f32(1.6)   // voxels/s
FOX_FLEE_SPEED      : f32 = f32(5.5)
FOX_FLEE_DIST       : f32 = f32(7.0)   // the player closer than this sends a fox running
ENTITY_TURN_RATE    :: f32(3.0)   // rad/s toward wander_yaw
ENTITY_GRAVITY      : f32 = f32(24.0)  // voxels/s^2
ENTITY_MAX_FALL     : f32 = f32(30.0)  // terminal fall speed, voxels/s

Entity_Kind :: enum u8 {
    Fox,
    Crystal,
    Bird,
    Fish,
}

Fox_State :: enum u8 { Walk, Idle, Flee }

Entity :: struct {
    pos:   [3]f32, // anchor = ground point under the entity (birds: body centre)
    yaw:   f32,    // current facing (radians, model +z = {-sin, 0, cos})
    kind:  Entity_Kind,
    seed:  f32,    // 0..1
    phase: f32,    // per-entity animation offset
    scale: f32,
    color: [3]f32, // fur tint
    // walkers
    state:      Fox_State,
    wander_yaw: f32,
    next_think: f32, // seconds timestamp for the next decision
    vel_y:      f32, // vertical velocity (gravity)
    speed:      f32, // current ground speed, smoothed (drives the gait)
    walk_phase: f32, // advanced by distance walked
    // birds (creatures.odin)
    cell:        [2]i32, // thermal cell the bird belongs to
    orbit:       [4]f32, // centre x, z, radius, altitude
    orbit_angle: f32,
    orbit_dir:   f32,    // +1 / -1
    bank:        f32,
    // fish (sea.odin): orbit = slot in the school (angle, radius, height, striped)
    school:      i32,
    vel:         [3]f32,
}

Ent_Candidate :: struct { idx: int, d2: f32 }

@(private="file")
birds_next_manage: f32

// Spawn a handful of foxes and crystals on the terrain around the player.
entities_init :: proc(gs: ^Game_State) {
    for i in 0 ..< 10 {
        x := gs.camera.pos.x + rand.float32_range(-24, 24)
        z := gs.camera.pos.z + rand.float32_range(-24, 24)
        ground := f32(surface_height_at(int(x), int(z))) + 1.0
        kind := i % 3 == 2 ? Entity_Kind.Crystal : Entity_Kind.Fox
        append(&gs.entities, Entity{
            pos        = {x, ground, z},
            yaw        = rand.float32_range(0, 2 * math.PI),
            kind       = kind,
            seed       = rand.float32(),
            phase      = rand.float32_range(0, 2 * math.PI),
            scale      = kind == .Crystal ? 1.0 : rand.float32_range(0.85, 1.1),
            color      = FOX_TINTS[rand.int_max(len(FOX_TINTS))],
            wander_yaw = rand.float32_range(0, 2 * math.PI),
        })
    }
}

// Per-frame: AI + movement, then cull/pack/upload. Called once per frame
// before gpu_render.
entities_update :: proc(gs: ^Game_State, dt: f32) {
    t := f32(SDL.GetTicks()) / 1000.0
    player_anim_update(gs, dt)
    if !gs.entities_enabled {
        entities_upload(gs, {}, t)
        return
    }
    if t >= birds_next_manage {
        t0 := time.tick_now()
        birds_manage(gs)
        profile_add(.Ent_Birds, t0)
        birds_next_manage = t + 1
    }
    fish_schools_update(gs, dt, t)

    t_ai := time.tick_now()
    for &e in gs.entities {
        switch e.kind {
        case .Crystal: // hovers in place; motion is in the pose
        case .Bird:    bird_update(gs, &e, dt, t)
        case .Fish:    fish_update(gs, &e, dt, t)
        case .Fox:     fox_update(gs, &e, dt, t)
        }
    }

    // Distance-sorted top-MAX_ENTITIES within each kind's cull radius.
    cands: [MAX_ENTITIES]Ent_Candidate
    n := 0
    cam := gs.camera.pos
    for e, idx in gs.entities {
        d := e.pos - cam
        d2 := d.x*d.x + d.y*d.y + d.z*d.z
        r := e.kind == .Bird ? BIRD_CULL_RADIUS : ENTITY_CULL_RADIUS
        if d2 > r * r { continue }
        c := Ent_Candidate{idx, d2}
        if n < MAX_ENTITIES {
            cands[n] = c
            n += 1
            for i := n - 1; i > 0 && cands[i].d2 < cands[i-1].d2; i -= 1 {
                cands[i], cands[i-1] = cands[i-1], cands[i]
            }
        } else if c.d2 < cands[MAX_ENTITIES-1].d2 {
            cands[MAX_ENTITIES-1] = c
            for i := MAX_ENTITIES - 1; i > 0 && cands[i].d2 < cands[i-1].d2; i -= 1 {
                cands[i], cands[i-1] = cands[i-1], cands[i]
            }
        }
    }

    profile_add(.Ent_AI, t_ai)
    entities_upload(gs, cands[:n], t)
}

// Fox: wander, stop to look around now and then, bolt away from the player.
@(private="file")
fox_update :: proc(gs: ^Game_State, e: ^Entity, dt, t: f32) {
    to_cam := gs.camera.pos - e.pos
    near := to_cam.x*to_cam.x + to_cam.z*to_cam.z < FOX_FLEE_DIST * FOX_FLEE_DIST
    if near {
        // Run directly away. dir = {-sin(yaw), 0, cos(yaw)} = -to_cam.
        if e.state != .Flee { play_at(.Fox, e.pos + {0, 0.5, 0}, 0.5, vary(0.1), 10) }
        e.state = .Flee
        e.wander_yaw = math.atan2(to_cam.x, -to_cam.z)
        e.next_think = t + rand.float32_range(1.5, 2.5)
    } else if t >= e.next_think {
        if e.state != .Walk || rand.float32() < 0.6 {
            e.state = .Walk
            e.wander_yaw = e.yaw + rand.float32_range(-1.6, 1.6)
            e.next_think = t + rand.float32_range(2.0, 5.0)
        } else {
            e.state = .Idle
            e.next_think = t + rand.float32_range(2.0, 4.0)
        }
    }
    want: f32
    switch e.state {
    case .Walk: want = FOX_WALK_SPEED
    case .Flee: want = FOX_FLEE_SPEED
    case .Idle: want = 0
    }
    e.speed += (want - e.speed) * min(dt * 4, 1)
    turn := ENTITY_TURN_RATE * (e.state == .Flee ? 2 : 1)
    dyaw := math.mod(e.wander_yaw - e.yaw + 3 * math.PI, 2 * math.PI) - math.PI
    e.yaw += clamp(dyaw, -turn * dt, turn * dt)

    ix := int(math.floor(e.pos.x))
    iz := int(math.floor(e.pos.z))
    feet := int(math.floor(e.pos.y + 0.01))

    // Buried (a block was just placed into it): pop up one voxel per frame.
    if solid_at(gs, ix, feet, iz) {
        e.pos.y = f32(feet + 1)
        e.vel_y = 0
        return
    }

    // Walk only while standing on something; in the air gravity owns it.
    supported := solid_at(gs, ix, feet - 1, iz) && e.pos.y - f32(feet) < 0.05
    if supported && e.speed > 0.05 {
        dir := [3]f32{-math.sin(e.yaw), 0, math.cos(e.yaw)}
        step := e.speed * dt
        np := e.pos + dir * step
        nx := int(math.floor(np.x))
        nz := int(math.floor(np.z))
        moved := true
        if solid_at(gs, nx, feet, nz) {
            // Solid at feet height ahead: hop up one voxel if there's
            // headroom on both columns, else it's a wall — turn around.
            if !solid_at(gs, nx, feet+1, nz) && !solid_at(gs, nx, feet+2, nz) &&
               !solid_at(gs, ix, feet+1, iz) {
                np.y = f32(feet + 1)
                e.pos = np
            } else {
                moved = false
            }
        } else if solid_at(gs, nx, feet+1, nz) {
            moved = false // head-height block: wall
        } else if block_is_watery(u8(get_voxel(gs, nx, feet - 1, nz))) && !solid_at(gs, nx, feet - 1, nz) {
            moved = false // foxes don't swim
        } else {
            e.pos = np // drops (ledges, mined ground) are gravity's job
        }
        if moved {
            e.walk_phase += step * 5.5 / world_scale
        } else {
            e.wander_yaw = e.yaw + math.PI * rand.float32_range(0.6, 1.4)
            e.next_think = t + rand.float32_range(0.5, 1.5)
        }
        ix = int(math.floor(e.pos.x))
        iz = int(math.floor(e.pos.z))
    }

    // Gravity + landing sweep: scan candidate standing heights crossed
    // this frame (top-down) so fast falls can't tunnel through a floor.
    e.vel_y = max(e.vel_y - ENTITY_GRAVITY * dt, -ENTITY_MAX_FALL)
    ny := e.pos.y + e.vel_y * dt
    landed := false
    for tt := int(math.floor(e.pos.y)); tt >= int(math.floor(ny)); tt -= 1 {
        if f32(tt) > e.pos.y || f32(tt) < ny { continue }
        if solid_at(gs, ix, tt - 1, iz) {
            e.pos.y = f32(tt)
            e.vel_y = 0
            landed = true
            break
        }
    }
    if !landed {
        e.pos.y = ny
        if e.pos.y < -300 { e.pos.y = -300; e.vel_y = 0 } // fell out of the world
    }
}

// Build the part instances for the culled entities (+ glider, player) and upload.
@(private="file")
entities_upload :: proc(gs: ^Game_State, cands: []Ent_Candidate, t: f32) {
    t0 := time.tick_now()
    frame := new(Ent_Frame, context.temp_allocator)
    // Player things first, so a full list never drops them.
    glider_add_parts(gs, frame)
    player_add_parts(gs, frame)
    others_add_parts(gs, frame)
    combat_add_parts(gs, frame)
    slimes_add_parts(gs, frame)
    enemies_add_parts(gs, frame)
    fx_add_parts(gs, frame)
    for c in cands {
        e := gs.entities[c.idx]
        // Birds circle far overhead: their shadows would be specks, but
        // their spread-out boxes would cost every terrain shadow ray.
        // Fish are small and under water: not worth a shadow either.
        if !ent_begin(frame, e.kind != .Bird && e.kind != .Fish) { break }
        ent_scale_about(frame, e.pos, world_scale)
        switch e.kind {
        case .Fox:  fox_add(frame, e, t)
        case .Bird: bird_add(frame, e, t)
        case .Fish: fish_add(frame, e, t)
        case .Crystal:
            s := e.scale
            hover := 0.15 * math.sin(t * 2 + e.phase)
            spin := basis_yaw(e.yaw + t * 0.8 + e.phase)
            ent_part(frame, .Crystal, e.pos + [3]f32{0, (0.75 + hover) * s, 0}, spin, {s, s, s})
        }
        ent_end(frame)
    }
    gs.entity_count = i32(frame.n_ents)
    if frame.n_ents == 0 { return }
    ent_build_masks(frame, gs)
    profile_add(.Ent_Build, t0)
    t1 := time.tick_now()
    defer profile_add(.Ent_Upload, t1)
    // Fixed layout, mirrored by the ENT_*_OFS constants in entity_voxel.hlsl.
    size := int(offset_of(Ent_Frame, n_ents))
    #assert(offset_of(Ent_Frame, ents)  == 4 * 16)
    #assert(offset_of(Ent_Frame, parts) == (4 + MAX_ENTITIES * 2) * 16)
    #assert(offset_of(Ent_Frame, tiles) == (4 + MAX_ENTITIES * 2 + MAX_ENT_PARTS * 6) * 16)
    #assert(offset_of(Ent_Frame, sun)   == (4 + MAX_ENTITIES * 2 + MAX_ENT_PARTS * 6) * 16 + ENT_TILES_X * ENT_TILES_Y * 16)
    dst := SDL.MapGPUTransferBuffer(gs.gpu_device, gs.ent_transfer, true)
    mem.copy(dst, frame, size)
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, gs.ent_transfer)
    gs.ent_upload_size = size
}
