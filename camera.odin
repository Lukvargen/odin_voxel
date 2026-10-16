package main

import "core:math"
import la "core:math/linalg"

PLAYER_EYE_HEIGHT : f32 = f32(1.7)
PLAYER_HALF_W     : f32 = f32(0.3)
PLAYER_HEAD_ABOVE : f32 = f32(0.15) // distance from eye to top of head: 1.85 tall, fits a 2-block gap

GRAVITY        : f32 = f32(36.0)
JUMP_SPEED     : f32 = f32(9.0)
WALK_SPEED     : f32 = f32(5.0)
SPRINT_FACTOR  :: f32(1.6)   // Ctrl or double-tapped W
SNEAK_FACTOR   :: f32(0.3)   // Shift: slow, and never walks off an edge
FLY_SPEED      : f32 = f32(11.0)
WALK_ACCEL     :: f32(14.0)
WALK_FRICTION  :: f32(12.0)
AIR_ACCEL      :: f32(2.5)
TERMINAL_VEL   : f32 = f32(60.0)
SWIM_DRAG      :: f32(3.0)   // velocity lost per second in water (fraction)
SWIM_ACCEL     : f32 = f32(18.0)  // top speed SWIM_ACCEL / SWIM_DRAG
SWIM_SPRINT    :: f32(1.6)   // sprint factor under water
SWIM_UP_ACCEL  : f32 = f32(26.0)  // holding jump in water
SWIM_FLOAT_EYE : f32 = f32(0.35)  // floating: eye this far above the water surface
SWIM_HOP_SPEED : f32 = f32(6.5)   // Space at the surface: hop up out of the water
CLIMB_SPEED    : f32 = f32(5.5)   // pulling up onto a ledge out of the water
CLIMB_REACH    : f32 = f32(3.5)   // highest ledge top above the feet you can pull up onto
                             // (floating: a lip two blocks over the water)

STEP_SMOOTH_SPEED :: f32(10.0) // how fast the visual offset catches up (units/sec)

Camera :: struct {
    pos:               [3]f32, // eye position (physics)
    yaw:               f32,
    pitch:             f32,
    velocity:          [3]f32,
    fly_mode:          bool,
    on_ground:         bool,
    swim_up:           bool,   // jump held: swim upward in water
    swimming:          bool,   // body in water (for the view and sounds)
    submerged:         bool,   // eye under water
    climbing:          bool,   // pulling up out of the water onto a ledge
    sprinting:         bool,
    sneaking:          bool,
    crouch:            f32,    // 0..1 sneak pose, eased (lowers the view)
    step_visual_offset: f32,  // negative when stepping up, lerps back to 0

    // View-only effects (glider.odin): never affect physics or aiming.
    roll:        f32,    // radians, positive = rolled left
    fov_scale:   f32,    // 1 = default 90 degree view, >1 wider
    shake:       [2]f32, // yaw/pitch jitter, degrees
    view_offset: [3]f32, // render position offset (chase camera, landing dip)
}

camera_forward :: proc(cam: Camera) -> [3]f32 {
    p := math.to_radians(cam.pitch)
    y := math.to_radians(cam.yaw)
    return {
        math.cos(p) * math.sin(y),
        math.sin(p),
        math.cos(p) * math.cos(y),
    }
}

camera_basis :: proc(cam: Camera) -> (fwd, right, up: [3]f32) {
    fwd   = la.normalize(camera_forward(cam))
    right = la.normalize(la.cross(fwd, [3]f32{0, 1, 0}))
    up    = la.normalize(la.cross(right, fwd))
    return
}

// Basis the renderer uses: camera_basis plus shake, roll and FOV. right/up
// are scaled by the FOV (the shaders build rays as fwd + nx*right + ny*up).
camera_view_basis :: proc(cam: Camera) -> (fwd, right, up: [3]f32) {
    c := cam
    c.yaw  += cam.shake.x
    c.pitch = clamp(c.pitch + cam.shake.y, -89.9, 89.9)
    fwd, right, up = camera_basis(c)
    cr, sr := math.cos(cam.roll), math.sin(cam.roll)
    right, up = right * cr + up * sr, up * cr - right * sr
    s := cam.fov_scale > 0 ? cam.fov_scale : 1
    return fwd, right * s, up * s
}

// Flat forward (XZ only, for walk movement).
camera_flat_forward :: proc(cam: Camera) -> [3]f32 {
    y := math.to_radians(cam.yaw)
    return la.normalize([3]f32{math.sin(y), 0, math.cos(y)})
}

camera_flat_right :: proc(cam: Camera) -> [3]f32 {
    fwd := camera_flat_forward(cam)
    return la.normalize(la.cross(fwd, [3]f32{0, 1, 0}))
}

// Test if the player AABB at `pos` (eye position) overlaps any solid voxel.
aabb_solid :: proc(w: ^World, pos: [3]f32) -> bool {
    min_x := int(math.floor(pos.x - PLAYER_HALF_W))
    max_x := int(math.floor(pos.x + PLAYER_HALF_W))
    min_y := int(math.floor(pos.y - PLAYER_EYE_HEIGHT))
    max_y := int(math.floor(pos.y + PLAYER_HEAD_ABOVE))
    min_z := int(math.floor(pos.z - PLAYER_HALF_W))
    max_z := int(math.floor(pos.z + PLAYER_HALF_W))
    for iy in min_y ..= max_y {
        for ix in min_x ..= max_x {
            for iz in min_z ..= max_z {
                if solid_at(w, ix, iy, iz) { return true }
            }
        }
    }
    return false
}

// Move along a single axis with collision. Returns new position and whether a collision occurred.
move_axis :: proc(w: ^World, pos: [3]f32, delta: [3]f32) -> (new_pos: [3]f32, collided: bool) {
    new_pos = pos + delta
    if aabb_solid(w, new_pos) {
        // Binary search toward the nearest free position along this axis.
        // Simple approach: step back to old position on this axis.
        new_pos = pos
        collided = true
    }
    return
}

// sprint/sneak: Ctrl / Shift. Flying, jump/sneak are up/down and ultra (Alt)
// is for crossing the world.
camera_update :: proc(cam: ^Camera, gs: ^Game_State, mouse_dx, mouse_dy, dt: f32,
                      move_fwd, move_back, move_left, move_right, jump: bool,
                      sprint, sneak, ultra: bool) {
    // Mouse look
    cam.yaw   += mouse_dx * 0.1
    cam.pitch  = clamp(cam.pitch - mouse_dy * 0.1, -89, 89)

    cam.sprinting = sprint && move_fwd && !sneak
    cam.sneaking  = sneak && !cam.fly_mode
    cam.crouch += ((cam.sneaking ? f32(1) : 0) - cam.crouch) * min(dt * 12, 1)
    if cam.fly_mode {
        _camera_update_fly(cam, dt, move_fwd, move_back, move_left, move_right, jump, sneak, cam.sprinting, ultra)
    } else {
        _camera_update_walk(cam, gs, dt, move_fwd, move_back, move_left, move_right, jump, cam.sprinting, cam.sneaking)
    }
}

// Creative-style flight: WASD on the level, jump up, sneak down.
_camera_update_fly :: proc(cam: ^Camera, dt: f32,
                            move_fwd, move_back, move_left, move_right, move_up, move_down: bool,
                            sprint, ultra: bool) {
    speed := FLY_SPEED
    if sprint { speed *= 2.5 }
    if ultra  { speed *= 40.0 }

    fwd, right := camera_flat_forward(cam^), camera_flat_right(cam^)
    dir: [3]f32
    if move_fwd   { dir += fwd }
    if move_back  { dir -= fwd }
    if move_right { dir += right }
    if move_left  { dir -= right }
    if move_up    { dir += [3]f32{0, 1, 0} }
    if move_down  { dir -= [3]f32{0, 1, 0} }

    norm := la.length(dir)
    if norm > 0.0001 {
        cam.pos += (dir / norm) * speed * dt
    }
    cam.velocity  = {}
    cam.on_ground = false
}

_camera_update_walk :: proc(cam: ^Camera, gs: ^Game_State, dt: f32,
                             move_fwd, move_back, move_left, move_right, jump, sprint, sneak: bool) {
    wish_speed: f32 = WALK_SPEED
    if sprint { wish_speed *= SPRINT_FACTOR }
    if sneak  { wish_speed *= SNEAK_FACTOR }

    // Build XZ wish direction from input.
    flat_fwd   := camera_flat_forward(cam^)
    flat_right := camera_flat_right(cam^)
    wish_dir: [3]f32
    if move_fwd   { wish_dir += flat_fwd }
    if move_back  { wish_dir -= flat_fwd }
    if move_right { wish_dir += flat_right }
    if move_left  { wish_dir -= flat_right }
    wish_len := la.length(wish_dir)
    if wish_len > 0.0001 { wish_dir /= wish_len }

    has_input := wish_len > 0.0001

    // Swimming: body in water. Heavy drag. With the head under you swim
    // where you look; at the surface you float with the head out, Space
    // hops, and Space facing a ledge pulls you up onto it (swim_climb).
    watery :: proc(gs: ^Game_State, x, y, z: f32) -> bool {
        return block_is_watery(u8(get_voxel(gs, int(math.floor(x)), int(math.floor(y)), int(math.floor(z)))))
    }
    feet := cam.pos.y - PLAYER_EYE_HEIGHT
    in_water := watery(gs, cam.pos.x, cam.pos.y - PLAYER_EYE_HEIGHT * 0.5, cam.pos.z)
    cam.swimming  = in_water
    cam.submerged = watery(gs, cam.pos.x, cam.pos.y - 0.1, cam.pos.z)
    // A climb, once started from the water, carries on until over the top.
    near_water := in_water || watery(gs, cam.pos.x, feet - 0.5, cam.pos.z) || cam.climbing
    cam.climbing = false
    if near_water && cam.swim_up && swim_climb(gs, cam, has_input ? wish_dir : flat_fwd) {
        cam.climbing = true
    } else if in_water {
        drag := max(1 - SWIM_DRAG * dt, 0)
        cam.velocity *= drag
        speed := SWIM_ACCEL * (sprint ? SWIM_SPRINT : 1)
        // Top of the water over the body (a few voxels up at most).
        surface := math.floor(cam.pos.y - PLAYER_EYE_HEIGHT * 0.5)
        for _ in 0 ..< 3 {
            if !watery(gs, cam.pos.x, surface + 1, cam.pos.z) { break }
            surface += 1
        }
        surface += 1
        // Near the top and not diving down (Shift, or swimming on while
        // looking down): float there instead of swimming freely.
        diving := sneak || (move_fwd && cam.pitch < -20) || (move_back && cam.pitch > 20)
        at_top := cam.pos.y > surface - 1.0 && !diving && !cam.swim_up
        if cam.submerged && !at_top {
            // Free swimming: forward follows the view, up and down included.
            look := la.normalize(camera_forward(cam^))
            wish: [3]f32
            if move_fwd   { wish += look }
            if move_back  { wish -= look }
            if move_right { wish += flat_right }
            if move_left  { wish -= flat_right }
            if la.length(wish) > 0.0001 { cam.velocity += la.normalize(wish) * speed * dt }
            cam.velocity.y -= GRAVITY * 0.04 * dt // nearly neutral: a slow sink
            if cam.swim_up { cam.velocity.y += SWIM_UP_ACCEL * dt }
            if sneak       { cam.velocity.y -= SWIM_UP_ACCEL * 0.6 * dt }
        } else {
            // At the top: float with the eye SWIM_FLOAT_EYE above the water
            // (a damped spring), Space hops, Shift dives.
            if has_input {
                cam.velocity.x += wish_dir.x * speed * dt
                cam.velocity.z += wish_dir.z * speed * dt
            }
            if diving {
                cam.velocity.y -= SWIM_UP_ACCEL * dt
            } else {
                err := surface + SWIM_FLOAT_EYE - cam.pos.y
                cam.velocity.y += (err * 30 - cam.velocity.y * 6) * dt
                if jump || cam.swim_up { cam.velocity.y = max(cam.velocity.y, err * 4) }
                if jump && err > -0.2 { cam.velocity.y = SWIM_HOP_SPEED }
            }
        }
    } else if cam.on_ground {
        // Friction
        horiz_speed := la.length([3]f32{cam.velocity.x, 0, cam.velocity.z})
        if horiz_speed > 0.01 {
            drop := horiz_speed * WALK_FRICTION * dt
            scale := max(horiz_speed - drop, 0) / horiz_speed
            cam.velocity.x *= scale
            cam.velocity.z *= scale
        }

        // Ground acceleration
        if has_input {
            curr := cam.velocity.x * wish_dir.x + cam.velocity.z * wish_dir.z
            add  := wish_speed - curr
            if add > 0 {
                accel_speed := min(WALK_ACCEL * wish_speed * dt, add)
                cam.velocity.x += wish_dir.x * accel_speed
                cam.velocity.z += wish_dir.z * accel_speed
            }
        }

        // Jump
        if jump { cam.velocity.y = JUMP_SPEED; cam.on_ground = false }

    } else {
        // Air acceleration (Source-style reduced control)
        if has_input {
            curr := cam.velocity.x * wish_dir.x + cam.velocity.z * wish_dir.z
            add  := wish_speed - curr
            if add > 0 {
                accel_speed := min(AIR_ACCEL * wish_speed * dt, add)
                cam.velocity.x += wish_dir.x * accel_speed
                cam.velocity.z += wish_dir.z * accel_speed
            }
        }
    }

    // Gravity (water applies its own above)
    if !in_water && !cam.climbing { cam.velocity.y -= GRAVITY * dt }
    if cam.velocity.y < -TERMINAL_VEL { cam.velocity.y = -TERMINAL_VEL }

    // Move and resolve collisions axis by axis.
    delta := cam.velocity * dt
    new_pos := cam.pos
    was_on_ground := cam.on_ground
    cam.on_ground = false

    // Sneaking on the ground never steps off an edge: a move that would leave
    // nothing under the feet is dropped, axis by axis.
    guard := sneak && was_on_ground
    supported :: proc(gs: ^Game_State, p: [3]f32) -> bool {
        y := int(math.floor(p.y - PLAYER_EYE_HEIGHT - 0.1))
        for ix in int(math.floor(p.x - PLAYER_HALF_W)) ..= int(math.floor(p.x + PLAYER_HALF_W)) {
            for iz in int(math.floor(p.z - PLAYER_HALF_W)) ..= int(math.floor(p.z + PLAYER_HALF_W)) {
                if solid_at(gs, ix, y, iz) { return true }
            }
        }
        return false
    }
    if guard && !supported(gs, new_pos + {delta.x, 0, 0}) { delta.x = 0; cam.velocity.x = 0 }
    if guard && !supported(gs, new_pos + {delta.x, 0, delta.z}) { delta.z = 0; cam.velocity.z = 0 }

    // X axis
    moved_x: bool
    new_pos, moved_x = move_axis(gs, new_pos, {delta.x, 0, 0})
    if moved_x {
        lifted := new_pos + [3]f32{0, 1, 0}
        if was_on_ground && !aabb_solid(gs, lifted) && !aabb_solid(gs, lifted + [3]f32{delta.x, 0, 0}) {
            new_pos = lifted + [3]f32{delta.x, 0, 0}
            cam.step_visual_offset = -1.0
        } else {
            cam.velocity.x = 0
        }
    }

    // Z axis
    moved_z: bool
    new_pos, moved_z = move_axis(gs, new_pos, {0, 0, delta.z})
    if moved_z {
        lifted := new_pos + [3]f32{0, 1, 0}
        if was_on_ground && !aabb_solid(gs, lifted) && !aabb_solid(gs, lifted + [3]f32{0, 0, delta.z}) {
            new_pos = lifted + [3]f32{0, 0, delta.z}
            cam.step_visual_offset = -1.0
        } else {
            cam.velocity.z = 0
        }
    }

    // Y axis
    pre_y := new_pos.y
    new_pos, _ = move_axis(gs, new_pos, {0, delta.y, 0})
    if new_pos.y == pre_y {
        if cam.velocity.y < 0 {
            cam.on_ground = true
            // Settle the feet onto the block top: the blocked move leaves
            // them up to a frame's fall above it, which steals headroom.
            settled := new_pos
            settled.y = math.floor(new_pos.y - PLAYER_EYE_HEIGHT + 0.01) + PLAYER_EYE_HEIGHT + 0.001
            if settled.y <= new_pos.y && !aabb_solid(gs, settled) { new_pos = settled }
        }
        cam.velocity.y = 0
    }

    // Advance visual step-up offset toward zero.
    if cam.step_visual_offset < 0 {
        cam.step_visual_offset += STEP_SMOOTH_SPEED * dt
        if cam.step_visual_offset > 0 { cam.step_visual_offset = 0 }
    }

    cam.pos = new_pos
}

// Pulling up out of the water: a ledge in `facing` whose top is within
// CLIMB_REACH above the feet with room to stand on it. Sets the velocity to
// rise along the wall and, once the feet clear the top, step onto it.
swim_climb :: proc(gs: ^Game_State, cam: ^Camera, facing: [3]f32) -> bool {
    f := la.normalize([3]f32{facing.x, 0, facing.z})
    ahead := cam.pos + f * (PLAYER_HALF_W + 0.4 * world_scale)
    ax, az := int(math.floor(ahead.x)), int(math.floor(ahead.z))
    feet := cam.pos.y - PLAYER_EYE_HEIGHT
    y0 := int(math.floor(feet + 0.05))
    top := 0
    found := false
    for y in y0 ..= int(math.floor(feet + CLIMB_REACH)) {
        if solid_at(gs, ax, y, az) && !solid_at(gs, ax, y + 1, az) && !solid_at(gs, ax, y + 2, az) && !solid_at(gs, ax, y + 3, az) {
            top, found = y + 1, true
            break
        }
    }
    if !found || f32(top) - feet > CLIMB_REACH { return false }
    if feet < f32(top) + 0.05 {
        cam.velocity.y = CLIMB_SPEED
        cam.velocity.x, cam.velocity.z = f.x * 1.5 * world_scale, f.z * 1.5 * world_scale
    } else {
        cam.velocity.y = max(cam.velocity.y, world_scale)
        cam.velocity.x, cam.velocity.z = f.x * 3 * world_scale, f.z * 3 * world_scale
    }
    return true
}
