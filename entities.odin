package main

import "core:math"
import "core:math/rand"
import SDL "vendor:sdl3"

// Entities (blob critters, hovering crystals). The CPU owns the canonical
// list and runs the cheap wander "AI"; each frame the nearest MAX_ENTITIES
// within ENTITY_CULL_RADIUS of the camera are turned into rigid voxel-model
// parts (voxel_models.odin) — animation is just where those parts are put —
// and uploaded for the tracer (shaders/entity_voxel.hlsl).

MAX_ENTITIES        :: 64
ENTITY_CULL_RADIUS  :: f32(96.0)  // gather range around camera
ENTITY_WALK_SPEED   :: f32(1.5)   // voxels/s
ENTITY_TURN_RATE    :: f32(3.0)   // rad/s toward wander_yaw
ENTITY_GRAVITY      :: f32(24.0)  // voxels/s^2 (blobs; crystals levitate)
ENTITY_MAX_FALL     :: f32(30.0)  // terminal fall speed, voxels/s

Entity_Kind :: enum u8 {
    Blob,
    Crystal,
}

Entity :: struct {
    pos:   [3]f32, // anchor = ground point under the entity (world voxels)
    yaw:   f32,    // current facing (radians)
    kind:  Entity_Kind,
    seed:  f32,    // 0..1, perturbs proportions in the shader
    phase: f32,    // per-entity animation offset
    scale: f32,
    color: [3]f32,
    // wander/physics state
    wander_yaw: f32,
    next_think: f32, // seconds timestamp for the next direction change
    vel_y:      f32, // vertical velocity (gravity; blobs only)
}

Ent_Candidate :: struct { idx: int, d2: f32 }

// Spawn a handful of test entities on the terrain around the player.
entities_init :: proc(gs: ^Game_State) {
    for i in 0 ..< 10 {
        x := gs.camera.pos.x + rand.float32_range(-24, 24)
        z := gs.camera.pos.z + rand.float32_range(-24, 24)
        ground := f32(surface_height_at(int(x), int(z))) + 1.0
        kind := i % 3 == 2 ? Entity_Kind.Crystal : Entity_Kind.Blob
        color := [3]f32{0.45, 0.75, 1.0} // crystal: icy blue
        if kind == .Blob {
            color = {rand.float32_range(0.5, 0.9), rand.float32_range(0.35, 0.7), rand.float32_range(0.2, 0.5)}
        }
        append(&gs.entities, Entity{
            pos        = {x, ground, z},
            yaw        = rand.float32_range(0, 2 * math.PI),
            kind       = kind,
            seed       = rand.float32(),
            phase      = rand.float32_range(0, 2 * math.PI),
            scale      = kind == .Crystal ? 1.0 : rand.float32_range(0.8, 1.3),
            color      = color,
            wander_yaw = rand.float32_range(0, 2 * math.PI),
        })
    }
}

// Per-frame: wander + ground-follow, then cull/pack/upload.
// Called once per frame before gpu_render.
entities_update :: proc(gs: ^Game_State, dt: f32) {
    t := f32(SDL.GetTicks()) / 1000.0
    if !gs.entities_enabled {
        entities_upload(gs, {}, t)
        return
    }

    for &e in gs.entities {
        if e.kind == .Crystal { continue } // hovers in place; motion is in-shader

        if t >= e.next_think {
            e.wander_yaw = rand.float32_range(0, 2 * math.PI)
            e.next_think = t + rand.float32_range(1.0, 3.0)
        }
        // Steer away from the player: walking through the camera puts the
        // camera inside a model (renders wrong) and feels bad anyway.
        to_cam := gs.camera.pos - e.pos
        if to_cam.x*to_cam.x + to_cam.z*to_cam.z < 4.0 * 4.0 {
            // dir = {-sin(yaw), 0, cos(yaw)}; solve for dir = -to_cam.
            e.wander_yaw = math.atan2(to_cam.x, -to_cam.z)
            e.next_think = t + 1.0
        }
        // Turn smoothly toward the wander heading (shortest way around).
        dyaw := math.mod(e.wander_yaw - e.yaw + 3 * math.PI, 2 * math.PI) - math.PI
        e.yaw += clamp(dyaw, -ENTITY_TURN_RATE * dt, ENTITY_TURN_RATE * dt)

        ix := int(math.floor(e.pos.x))
        iz := int(math.floor(e.pos.z))
        feet := int(math.floor(e.pos.y + 0.01))

        // Buried (a block was just placed into the blob): pop up one voxel
        // per frame until clear — same feel as placing a block under a mob.
        if solid_at(gs, ix, feet, iz) {
            e.pos.y = f32(feet + 1)
            e.vel_y = 0
            continue
        }

        // Walk only while standing on something; in the air gravity owns it.
        supported := solid_at(gs, ix, feet - 1, iz) && e.pos.y - f32(feet) < 0.05
        if supported {
            // Local forward is +z; matches basis_yaw in voxel_models.odin.
            dir := [3]f32{-math.sin(e.yaw), 0, math.cos(e.yaw)}
            np := e.pos + dir * (ENTITY_WALK_SPEED * dt)
            nx := int(math.floor(np.x))
            nz := int(math.floor(np.z))
            if solid_at(gs, nx, feet, nz) {
                // Solid at feet height ahead: step up one voxel if there's
                // headroom on both columns, else it's a wall — turn around.
                if !solid_at(gs, nx, feet+1, nz) && !solid_at(gs, nx, feet+2, nz) &&
                   !solid_at(gs, ix, feet+1, iz) {
                    np.y = f32(feet + 1)
                    e.pos = np
                } else {
                    e.wander_yaw = e.yaw + math.PI
                    e.next_think = t + rand.float32_range(0.5, 1.5)
                }
            } else if solid_at(gs, nx, feet+1, nz) {
                // Head-height block: wall.
                e.wander_yaw = e.yaw + math.PI
                e.next_think = t + rand.float32_range(0.5, 1.5)
            } else {
                e.pos = np // drops (ledges, mined ground) are gravity's job
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

    // Distance-sorted top-MAX_ENTITIES within the cull radius.
    cands: [MAX_ENTITIES]Ent_Candidate
    n := 0
    cam := gs.camera.pos
    for e, idx in gs.entities {
        d := e.pos - cam
        d2 := d.x*d.x + d.y*d.y + d.z*d.z
        if d2 > ENTITY_CULL_RADIUS * ENTITY_CULL_RADIUS { continue }
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

    entities_upload(gs, cands[:n], t)
}

// Build the part instances for the culled entities (+ the glider) and upload.
@(private="file")
entities_upload :: proc(gs: ^Game_State, cands: []Ent_Candidate, t: f32) {
    frame := new(Ent_Frame, context.temp_allocator)
    glider_add_parts(gs, frame) // first, so a full list never drops it
    for c in cands {
        e := gs.entities[c.idx]
        if !ent_begin(frame) { break }
        rot := basis_yaw(e.yaw)
        s := e.scale
        switch e.kind {
        case .Blob:
            tt  := t * 4 + e.phase
            bob := 0.08 * math.sin(tt)
            tint := e.color * (0.92 + 0.16 * e.seed)
            ent_part(frame, .Blob_Body, e.pos + rot * [3]f32{0, bob * s, 0}, rot, {s, s, s}, tint)
            // Diagonal leg pairs swing in opposite phase.
            for i in 0 ..< 4 {
                sx: f32 = i & 1 != 0 ? 1 : -1
                sz: f32 = i & 2 != 0 ? 1 : -1
                swing := 0.5 * math.sin(tt + (sx * sz > 0 ? 0 : math.PI))
                hip := [3]f32{0.22 * sx, 0.35 + bob, 0.16 * sz} * s
                ent_part(frame, .Blob_Leg, e.pos + rot * hip, rot * basis_rot_x(swing), {s, s, s}, tint)
            }
        case .Crystal:
            hover := 0.15 * math.sin(t * 2 + e.phase)
            spin := basis_yaw(e.yaw + t * 0.8 + e.phase)
            ent_part(frame, .Crystal, e.pos + [3]f32{0, (0.75 + hover) * s, 0}, spin, {s, s, s})
        }
        ent_end(frame)
    }
    gs.entity_count = i32(frame.n_ents)
    if frame.n_ents == 0 { return }
    ent_build_bvh(frame)
    // Entity records and BVH at their fixed slot ranges, parts right after.
    size := int(offset_of(Ent_Frame, parts)) + frame.n_parts * size_of(Part_Gpu)
    #assert(offset_of(Ent_Frame, nodes) == MAX_ENTITIES * size_of(Ent_Gpu))
    #assert(offset_of(Ent_Frame, parts) == 3 * MAX_ENTITIES * size_of(Ent_Gpu))
    gpu_upload_buffer(gs, gs.entity_buf, frame, size, gs.ent_dyn_base * 16)
}
