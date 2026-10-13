package main

import "core:math"
import "core:math/rand"
import SDL "vendor:sdl3"

// Procedural SDF entities (blob critters, hovering crystals). The CPU owns
// the canonical list and runs the cheap wander "AI"; each frame the nearest
// MAX_ENTITIES within ENTITY_CULL_RADIUS of the camera are packed and
// uploaded to a small GPU buffer read by the tracer (primary rays + sun and
// point-light shadow occlusion). Shapes/animation are evaluated entirely in
// shaders/entity_sdf.hlsl — there is no model data, only these parameters.

MAX_ENTITIES        :: 64
ENTITY_CULL_RADIUS  :: f32(96.0)  // gather range around camera
ENTITY_WALK_SPEED   :: f32(1.5)   // voxels/s
ENTITY_TURN_RATE    :: f32(3.0)   // rad/s toward wander_yaw
ENTITY_GRAVITY      :: f32(24.0)  // voxels/s^2 (blobs; crystals levitate)
ENTITY_MAX_FALL     :: f32(30.0)  // terminal fall speed, voxels/s

// CPU AABB must contain the SDF at every animation phase: bounds below are
// the static local extents; ANIM_MARGIN covers bob/hover/leg-swing
// displacement. INVARIANT: any new animation term in entity_sdf.hlsl must
// stay inside this margin or the entity clips at its AABB edges.
ANIM_MARGIN :: f32(0.35)

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

// Matches the 5-float4 record in entity_sdf.hlsl (ENTITY_STRIDE).
Entity_Gpu :: struct #packed {
    pos:      [3]f32, yaw:        f32,
    aabb_min: [3]f32, kind:       f32,
    aabb_max: [3]f32, anim_phase: f32,
    color:    [3]f32, seed:       f32,
    scale:    f32,    params:     [3]f32,
}

ENTITY_BUF_SIZE :: MAX_ENTITIES * size_of(Entity_Gpu)

// Static local-space bounds per kind (xz half-extent, height), scaled and
// ANIM_MARGIN-padded when packing the GPU AABB.
@(private="file")
entity_kind_bounds :: proc(kind: Entity_Kind) -> (half_xz: f32, height: f32) {
    switch kind {
    case .Blob:    return 0.55, 1.25
    case .Crystal: return 0.60, 1.60
    }
    return 0.6, 1.5
}

// Blob vertical physics + walking collision. pos.y is the FEET height;
// a blob stands on cell c when pos.y == c + 1 and occupies the two cells
// above (it's ~1.2 voxels tall, but 2 cells of headroom reads better).

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
    if !gs.entities_enabled {
        gs.entity_count = 0
        return
    }
    t := f32(SDL.GetTicks()) / 1000.0

    for &e in gs.entities {
        if e.kind == .Crystal { continue } // hovers in place; motion is in-shader

        if t >= e.next_think {
            e.wander_yaw = rand.float32_range(0, 2 * math.PI)
            e.next_think = t + rand.float32_range(1.0, 3.0)
        }
        // Steer away from the player: walking through the camera puts the
        // ray origin inside the SDF (renders wrong) and feels bad anyway.
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
            // Local forward is +z; matches rot2(lp.xz, -yaw) in entity_sdf.hlsl.
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
    Candidate :: struct { idx: int, d2: f32 }
    cands: [MAX_ENTITIES]Candidate
    n := 0
    cam := gs.camera.pos
    for e, idx in gs.entities {
        d := e.pos - cam
        d2 := d.x*d.x + d.y*d.y + d.z*d.z
        if d2 > ENTITY_CULL_RADIUS * ENTITY_CULL_RADIUS { continue }
        c := Candidate{idx, d2}
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

    gs.entity_count = i32(n)
    if n == 0 { return }

    packed: [MAX_ENTITIES]Entity_Gpu
    for i in 0 ..< n {
        e := gs.entities[cands[i].idx]
        half_xz, height := entity_kind_bounds(e.kind)
        r := (half_xz + ANIM_MARGIN) * e.scale
        h := (height + ANIM_MARGIN) * e.scale
        packed[i] = {
            pos        = e.pos,
            yaw        = e.yaw,
            aabb_min   = {e.pos.x - r, e.pos.y - 0.2 * e.scale, e.pos.z - r},
            kind       = f32(e.kind),
            aabb_max   = {e.pos.x + r, e.pos.y + h, e.pos.z + r},
            anim_phase = e.phase,
            color      = e.color,
            seed       = e.seed,
            scale      = e.scale,
        }
    }
    gpu_upload_buffer(gs, gs.entity_buf, &packed, n * size_of(Entity_Gpu))
}
