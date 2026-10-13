package main

import "core:math"
import la "core:math/linalg"

PLAYER_EYE_HEIGHT :: f32(1.7)
PLAYER_HALF_W     :: f32(0.3)
PLAYER_HEAD_ABOVE :: f32(0.3) // distance from eye to top of head

GRAVITY        :: f32(36.0)
JUMP_SPEED     :: f32(9.0)
WALK_SPEED     :: f32(5.0)
WALK_ACCEL     :: f32(14.0)
WALK_FRICTION  :: f32(12.0)
AIR_ACCEL      :: f32(2.5)
TERMINAL_VEL   :: f32(60.0)
SWIM_DRAG      :: f32(3.0)   // velocity lost per second in water (fraction)
SWIM_ACCEL     :: f32(18.0)
SWIM_UP_ACCEL  :: f32(26.0)  // holding jump in water

STEP_SMOOTH_SPEED :: f32(10.0) // how fast the visual offset catches up (units/sec)

Camera :: struct {
    pos:               [3]f32, // eye position (physics)
    yaw:               f32,
    pitch:             f32,
    velocity:          [3]f32,
    fly_mode:          bool,
    on_ground:         bool,
    swim_up:           bool,   // jump held: swim upward in water
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
aabb_solid :: proc(gs: ^Game_State, pos: [3]f32) -> bool {
    min_x := int(math.floor(pos.x - PLAYER_HALF_W))
    max_x := int(math.floor(pos.x + PLAYER_HALF_W))
    min_y := int(math.floor(pos.y - PLAYER_EYE_HEIGHT))
    max_y := int(math.floor(pos.y + PLAYER_HEAD_ABOVE))
    min_z := int(math.floor(pos.z - PLAYER_HALF_W))
    max_z := int(math.floor(pos.z + PLAYER_HALF_W))
    for iy in min_y ..= max_y {
        for ix in min_x ..= max_x {
            for iz in min_z ..= max_z {
                if solid_at(gs, ix, iy, iz) { return true }
            }
        }
    }
    return false
}

// Move along a single axis with collision. Returns new position and whether a collision occurred.
move_axis :: proc(gs: ^Game_State, pos: [3]f32, delta: [3]f32) -> (new_pos: [3]f32, collided: bool) {
    new_pos = pos + delta
    if aabb_solid(gs, new_pos) {
        // Binary search toward the nearest free position along this axis.
        // Simple approach: step back to old position on this axis.
        new_pos = pos
        collided = true
    }
    return
}

camera_update :: proc(cam: ^Camera, gs: ^Game_State, mouse_dx, mouse_dy, dt: f32,
                      move_fwd, move_back, move_left, move_right, jump: bool,
                      run_fast, run_ultra: bool) {
    // Mouse look
    cam.yaw   += mouse_dx * 0.1
    cam.pitch  = clamp(cam.pitch - mouse_dy * 0.1, -89, 89)

    if cam.fly_mode {
        _camera_update_fly(cam, dt, move_fwd, move_back, move_left, move_right, jump, run_fast, run_ultra)
    } else {
        _camera_update_walk(cam, gs, dt, move_fwd, move_back, move_left, move_right, jump, run_fast)
    }
}

_camera_update_fly :: proc(cam: ^Camera, dt: f32,
                            move_fwd, move_back, move_left, move_right, move_up: bool,
                            run_fast, run_ultra: bool) {
    speed: f32 = 10.0
    if run_fast  { speed *= 4.0 }
    if run_ultra { speed *= 40.0 }

    fwd, right, _ := camera_basis(cam^)
    dir: [3]f32
    if move_fwd   { dir += fwd }
    if move_back  { dir -= fwd }
    if move_right { dir += right }
    if move_left  { dir -= right }
    if move_up    { dir += [3]f32{0, 1, 0} }

    norm := la.length(dir)
    if norm > 0.0001 {
        cam.pos += (dir / norm) * speed * dt
    }
    cam.velocity  = {}
    cam.on_ground = false
}

_camera_update_walk :: proc(cam: ^Camera, gs: ^Game_State, dt: f32,
                             move_fwd, move_back, move_left, move_right, jump, run_fast: bool) {
    wish_speed: f32 = WALK_SPEED
    if run_fast { wish_speed *= 2.5 }

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

    // Swimming: body in water. Heavy drag, weak gravity, jump swims up.
    body := [3]int{int(math.floor(cam.pos.x)), int(math.floor(cam.pos.y - PLAYER_EYE_HEIGHT * 0.5)), int(math.floor(cam.pos.z))}
    if get_voxel(gs, body.x, body.y, body.z) == u32(Block_Type.Water) {
        drag := max(1 - SWIM_DRAG * dt, 0)
        cam.velocity *= drag
        if has_input {
            cam.velocity.x += wish_dir.x * SWIM_ACCEL * dt
            cam.velocity.z += wish_dir.z * SWIM_ACCEL * dt
        }
        cam.velocity.y -= GRAVITY * 0.15 * dt
        if jump || cam.swim_up { cam.velocity.y += SWIM_UP_ACCEL * dt }
        cam.on_ground = false
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
    if get_voxel(gs, body.x, body.y, body.z) != u32(Block_Type.Water) { cam.velocity.y -= GRAVITY * dt }
    if cam.velocity.y < -TERMINAL_VEL { cam.velocity.y = -TERMINAL_VEL }

    // Move and resolve collisions axis by axis.
    delta := cam.velocity * dt
    new_pos := cam.pos
    was_on_ground := cam.on_ground
    cam.on_ground = false

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
        if cam.velocity.y < 0 { cam.on_ground = true }
        cam.velocity.y = 0
    }

    // Advance visual step-up offset toward zero.
    if cam.step_visual_offset < 0 {
        cam.step_visual_offset += STEP_SMOOTH_SPEED * dt
        if cam.step_visual_offset > 0 { cam.step_visual_offset = 0 }
    }

    cam.pos = new_pos
}
