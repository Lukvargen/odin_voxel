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
CLIMB_REACH    : f32 = f32(3.5)   // highest ledge top above the feet you can pull up onto
                             // out of the water (floating: a lip two blocks over it)
MANTLE_REACH   : f32 = f32(1.5)   // the same in the air: hands over a ledge this far above
                             // the feet; a jump reaches a wall some 2.6 m high

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
    climbing:          bool,   // pulling up onto a ledge (out of the water, or mid-jump)
    mantle:            Mantle, // the pull-up, while climbing
    climb_tilt:        [2]f32, // view nod (pitch, degrees) and sway (roll, radians) of a pull-up
    sprinting:         bool,
    sneaking:          bool,
    crouch:            f32,    // 0..1 sneak pose, eased (lowers the view)
    step_visual_offset: f32,  // negative when stepping up, lerps back to 0

    // View-only effects (glider.odin): never affect physics or aiming.
    roll:        f32,    // radians, positive = rolled left
    fov:         f32,    // vertical field of view, degrees (options screen); 0 = DEFAULT_FOV
    fov_scale:   f32,    // 1 = the fov setting, >1 wider
    shake:       [2]f32, // yaw/pitch jitter, degrees
    view_offset: [3]f32, // render position offset (chase camera, landing dip)
}

CROUCH_VIEW_DROP :: f32(0.3) // how far sneaking lowers the view

// Where aiming (block targeting, picking) starts: the eye the first-person
// view is drawn from, so what's under the crosshair is what gets hit even
// while crouched or easing up a step. Not the chase camera's position: in
// third person you still aim from the player's own eye.
camera_aim_eye :: proc(cam: Camera) -> [3]f32 {
    return cam.pos + [3]f32{0, cam.step_visual_offset - cam.crouch * CROUCH_VIEW_DROP, 0}
}

// The eye the view is drawn from: the physics eye plus the view's own
// offsets (chase camera, landing dip, crouch, easing up a step).
camera_view_eye :: proc(cam: Camera) -> [3]f32 {
    return cam.pos + cam.view_offset + [3]f32{0, cam.step_visual_offset, 0}
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

DEFAULT_FOV :: 70

// Basis the renderer uses: camera_basis plus shake, roll and FOV. right/up
// are scaled by the FOV (the shaders build rays as fwd + nx*right + ny*up,
// nx and ny -1..1 across the screen): the vertical FOV is fixed and the
// horizontal one follows the screen's aspect (width / height).
camera_view_basis :: proc(cam: Camera, aspect: f32) -> (fwd, right, up: [3]f32) {
    c := cam
    c.yaw  += cam.shake.x
    c.pitch = clamp(c.pitch + cam.shake.y + cam.climb_tilt.x, -89.9, 89.9)
    fwd, right, up = camera_basis(c)
    roll := cam.roll + cam.climb_tilt.y
    cr, sr := math.cos(roll), math.sin(roll)
    right, up = right * cr + up * sr, up * cr - right * sr
    s := cam.fov_scale > 0 ? cam.fov_scale : 1
    s *= math.tan(math.to_radians(cam.fov > 0 ? cam.fov : DEFAULT_FOV) * 0.5)
    return fwd, right * (s * aspect), up * s
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
    if !cam.climbing { cam.climb_tilt -= cam.climb_tilt * min(dt * 10, 1) }
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
    // hops, and Space facing a ledge pulls you up onto it (ledge_climb).
    watery :: proc(gs: ^Game_State, x, y, z: f32) -> bool { return block_is_watery(u8(voxel_at(gs, {x, y, z}))) }
    feet := cam.pos.y - PLAYER_EYE_HEIGHT
    in_water := watery(gs, cam.pos.x, cam.pos.y - PLAYER_EYE_HEIGHT * 0.5, cam.pos.z)
    cam.swimming  = in_water
    cam.submerged = watery(gs, cam.pos.x, cam.pos.y - 0.1, cam.pos.z)
    // A pull-up, once started, plays out on its own (mantle_step). Out of
    // the water Space alone starts one (facing a ledge); on land it takes a
    // jump and pushing toward the ledge, so it doesn't catch you by surprise.
    if cam.climbing {
        mantle_step(gs, cam, dt)
        return
    }
    near_water := in_water || watery(gs, cam.pos.x, feet - 0.5, cam.pos.z)
    if near_water && cam.swim_up && ledge_climb(gs, cam, has_input ? wish_dir : flat_fwd, CLIMB_REACH) {
        return
    } else if !near_water && !cam.on_ground && cam.swim_up && has_input && ledge_climb(gs, cam, wish_dir, MANTLE_REACH) {
        return
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
    if !in_water { cam.velocity.y -= GRAVITY * dt }
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

// ---- Pulling up onto a ledge -------------------------------------------------
// Out of the water or mid-jump: hands on the lip, a short hang, a heave
// that's slow to start and quick through the middle, the hips over the lip,
// then a step forward onto the top. Scripted rather than physics, so it
// reads as a climb, not a float; the view nods down toward the hands and
// sways hand over hand (climb_tilt), and combat.odin draws the arms.

Mantle :: struct {
    t, dur: f32,
    from:   [3]f32, // eye where the hands caught the lip
    to:     [3]f32, // eye standing on the ledge
    lift:   f32,    // eye height at the top of the heave (hips over the lip)
    dir:    [3]f32, // flat, toward the ledge
    hands:  [3]f32, // the lip between the hands
}

MANTLE_TIME     :: f32(0.45) // seconds a pull-up takes, plus...
MANTLE_TIME_PER :: f32(0.22) // ... this much per metre climbed
MANTLE_GRAB :: f32(0.16) // fraction of the pull-up spent catching the lip
MANTLE_PULL :: f32(0.66) // ... by the end of the heave
MANTLE_OVER :: f32(0.56) // ... when the body starts forward over the top

// A ledge in `facing` whose top is within `reach` above the feet with room
// to stand on it: starts pulling up onto it.
ledge_climb :: proc(gs: ^Game_State, cam: ^Camera, facing: [3]f32, reach: f32) -> bool {
    f := la.normalize([3]f32{facing.x, 0, facing.z})
    ahead := cam.pos + f * (PLAYER_HALF_W + 0.4 * world_scale)
    ax, az := int(math.floor(ahead.x)), int(math.floor(ahead.z))
    feet := cam.pos.y - PLAYER_EYE_HEIGHT
    y0 := int(math.floor(feet + 0.05))
    top := 0
    found := false
    room := int(math.ceil(PLAYER_EYE_HEIGHT + PLAYER_HEAD_ABOVE)) // blocks to stand in
    scan: for y in y0 ..= int(math.floor(feet + reach)) {
        if !solid_at(gs, ax, y, az) { continue }
        for k in 1 ..= room { if solid_at(gs, ax, y + k, az) { continue scan } }
        top, found = y + 1, true
        break
    }
    if !found || f32(top) - feet > reach { return false }

    // Rise in place, then forward onto the middle of the ledge block: both
    // ends must be clear (the path between is checked as it goes).
    eye_top := f32(top) + PLAYER_EYE_HEIGHT + 0.001
    lift := eye_top + 0.1 * world_scale
    to := [3]f32{f32(ax) + 0.5, eye_top, f32(az) + 0.5}
    if aabb_solid(gs, {cam.pos.x, lift, cam.pos.z}) || aabb_solid(gs, to) { return false }

    rise := lift - cam.pos.y
    cam.climbing = true
    cam.velocity = {}
    cam.on_ground = false
    cam.mantle = {
        dur   = MANTLE_TIME + MANTLE_TIME_PER * max(rise, 0) / world_scale,
        from  = cam.pos,
        to    = to,
        lift  = lift,
        dir   = f,
        hands = {cam.pos.x + f.x * (PLAYER_HALF_W + 0.05), f32(top), cam.pos.z + f.z * (PLAYER_HALF_W + 0.05)},
    }
    // The hands slap onto the lip.
    m := block_material(Block_Type(u8(get_voxel(gs, ax, top - 1, az))))
    play(step_sound(m), 0.45, vary(0.08) * 0.9)
    play(.Land, 0.15, vary(0.06) * 1.3)
    return true
}

// Eye position `u` (0..1) of the way through a pull-up.
mantle_pos :: proc(m: Mantle, u: f32) -> [3]f32 {
    dip := 0.08 * world_scale // hanging off the hands for a moment
    y: f32
    switch {
    case u < MANTLE_GRAB:
        y = m.from.y - dip * math.smoothstep(f32(0), MANTLE_GRAB, u)
    case u < MANTLE_PULL:
        k := (u - MANTLE_GRAB) / (MANTLE_PULL - MANTLE_GRAB)
        e := k < 0.5 ? 4 * k * k * k : 1 - (2 - 2 * k) * (2 - 2 * k) * (2 - 2 * k) / 2 // ease in-out, cubic
        y = m.from.y - dip + (m.lift - m.from.y + dip) * e
    case:
        y = m.lift + (m.to.y - m.lift) * math.smoothstep(MANTLE_PULL, f32(1), u)
    }
    o := math.smoothstep(MANTLE_OVER, f32(1), u)
    return {m.from.x + (m.to.x - m.from.x) * o, y, m.from.z + (m.to.z - m.from.z) * o}
}

// One frame of a pull-up. Something in the way (a block placed, a slime)
// lets go: the walk physics takes over from there.
mantle_step :: proc(gs: ^Game_State, cam: ^Camera, dt: f32) {
    m := &cam.mantle
    m.t = min(m.t + dt, m.dur)
    u := m.t / m.dur
    p := mantle_pos(m^, u)
    if aabb_solid(gs, p) {
        p.x, p.z = cam.pos.x, cam.pos.z // hold back from the edge a moment
        if aabb_solid(gs, p) { cam.climbing = false; return }
    }
    cam.pos = p
    cam.velocity = {}
    // Nod down toward the hands through the heave, sway hand over hand.
    heave := math.sin(clamp(u / MANTLE_OVER, 0, 1) * math.PI)
    cam.climb_tilt = {-9 * heave, 0.035 * math.sin(u * 2 * math.PI) * (1 - u)}
    if u >= 1 {
        cam.climbing, cam.on_ground = false, true
        cam.velocity = m.dir * WALK_SPEED * 0.4 // walk on, not stop dead
        play(step_sound(block_material(voxel_at(gs, cam.pos - {0, PLAYER_EYE_HEIGHT + 0.05, 0}))), 0.35, vary())
    }
}
