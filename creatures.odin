package main

import "core:math"
import "core:math/rand"
import la "core:math/linalg"

// Creatures built from rigid voxel parts (voxel_models.odin): foxes that
// wander and flee, eagles that circle in thermals (so a glider pilot can
// spot rising air), and the player's own body for the third-person view.
// Each creature's shapes are baked once; the *_add procs pose the parts for
// this frame from the creature's state.

// ─── Shapes ─────────────────────────────────────────────────────────────────

// Fox body, pivot at the body centre; chest and belly pale.
@(private="file")
shape_fox_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, 0, 0}, {0.16, 0.14, 0.30}, 0.07) > 0 { return .Empty }
    if p.y < -0.04 && p.z > -0.05 { return .Fur_Light }
    if p.z > 0.2 && p.y < 0.06 { return .Fur_Light }
    return .Fur
}

// Fox head, pivot at the neck: round skull with pale cheeks, a muzzle that
// tapers to a small black nose, dark eyes with a glint, and big pointed ears
// with dark tips and pale insides.
@(private="file")
shape_fox_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Ears: triangles rising from the top of the skull, tilted outward.
    if q.y > 0.18 && q.y < 0.43 {
        k := (q.y - 0.18) / 0.25            // 0 at the base .. 1 at the tip
        cx := 0.095 + 0.03 * k               // leans outward
        half := 0.075 * (1 - k) + 0.008
        if abs(q.x - cx) < half && abs(p.z - 0.04) < 0.03 {
            if k > 0.68 { return .Fur_Dark }
            if p.z > 0.05 && abs(q.x - cx) < half * 0.55 && k < 0.6 { return .Fur_Light } // inner ear
            return .Fur
        }
    }
    // Muzzle: narrows and drops toward the nose.
    if p.z > 0.13 && p.z < 0.33 {
        k := (p.z - 0.13) / 0.2
        hw := 0.085 - 0.04 * k
        top := 0.115 - 0.045 * k
        if q.x < hw && p.y > 0.0 && p.y < top {
            if p.z > 0.29 && p.y > top - 0.05 { return .Nose }
            return p.y < 0.05 ? .Fur_Light : .Fur
        }
    }
    // Skull.
    if vm_round_box(p, {0, 0.11, 0.05}, {0.15, 0.13, 0.13}, 0.06) < 0 {
        // Eyes on the front face, a little tall, with a glint.
        if p.z > 0.13 && abs(q.x - 0.075) < 0.024 && abs(p.y - 0.135) < 0.036 {
            return q.x < 0.07 && p.y > 0.15 ? .Eye_White : .Eye
        }
        if p.y < 0.07 && q.x > 0.055 { return .Fur_Light } // cheeks
        return .Fur
    }
    return .Empty
}

// Fox leg, pivot at the hip, dark paw.
@(private="file")
shape_fox_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.15, 0}, {0.045, 0.16, 0.05}, 0.02) > 0 { return .Empty }
    return p.y < -0.22 ? .Fur_Dark : .Fur
}

// Bushy tail along -z from its base, white tip.
@(private="file")
shape_fox_tail :: proc(p: [3]f32, voxel: f32) -> Pal {
    a, b := [3]f32{0, 0, 0}, [3]f32{0, -0.06, -0.42}
    ba := b - a
    t := clamp(la.dot(p - a, ba) / la.dot(ba, ba), 0, 1)
    r := 0.05 + 0.07 * math.sin(t * math.PI * 0.85)
    if la.length(p - (a + ba * t)) > r { return .Empty }
    return t > 0.78 ? .Fur_Light : .Fur
}

// Eagle body along +z: brown body, white head, yellow beak, white tail fan.
@(private="file")
shape_bird_body :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    if la.length(q - [3]f32{0.045, 0.08, 0.32}) < 0.022 { return .Eye }
    // Hooked beak.
    if p.z > 0.33 && p.z < 0.45 && abs(p.x) < 0.03 {
        k := (p.z - 0.33) / 0.12
        if p.y < 0.06 - k * 0.04 && p.y > -0.0 - k * 0.04 { return .Beak }
    }
    if la.length(p - [3]f32{0, 0.05, 0.28}) < 0.085 { return .Feather_White }
    if vm_capsule(p, {0, 0, -0.2}, {0, 0.02, 0.2}, 0.1) < 0 { return .Feather }
    // Tail fan, widening toward the end.
    if p.z < -0.22 && p.z > -0.48 && abs(p.y + 0.01) < 0.02 {
        if abs(p.x) < 0.05 + (-0.22 - p.z) * 0.45 { return .Feather_White }
    }
    return .Empty
}

// Left eagle wing along +x from the shoulder: broad, slightly swept, dark
// fingered tips. The right wing is this one mirrored.
@(private="file")
shape_bird_wing :: proc(p: [3]f32, voxel: f32) -> Pal {
    x := p.x
    if x < 0 || x > 1.0 { return .Empty }
    lead := 0.09 - 0.07 * x
    trail := -0.2 + 0.06 * x
    // Rounded tip, split into "fingers".
    if x > 0.8 {
        k := (x - 0.8) / 0.2
        lead  -= k * k * 0.12
        trail += k * k * 0.08
        if math.mod(p.z * 40 + 100, 2) < 0.7 { return .Empty }
    }
    if p.z > lead || p.z < trail { return .Empty }
    if abs(p.y - 0.03 * x) > max(0.025 * (1 - x * 0.6), voxel * 0.55) { return .Empty }
    if x > 0.72 { return .Feather_Dark }
    return p.z < trail + 0.06 ? .Feather_Dark : .Feather
}

// Humanoid, Cube World proportions (big head). All pivots at joints.
@(private="file")
shape_hum_torso :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, 0.29, 0}, {0.2, 0.29, 0.12}, 0.05) > 0 { return .Empty }
    if p.y < 0.07 { return .Pants }
    if p.y < 0.12 { return .Belt }
    if p.y > 0.52 && abs(p.x) < 0.11 { return .Shirt_Trim }
    return .Shirt
}

@(private="file")
shape_hum_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, 0.24, 0}, {0.22, 0.22, 0.21}, 0.06) > 0 { return .Empty }
    q := [3]f32{abs(p.x), p.y, p.z}
    if p.z > 0.15 && abs(q.x - 0.085) < 0.035 && abs(p.y - 0.22) < 0.05 {
        return q.x > 0.095 && p.y > 0.22 ? .Eye_White : .Eye
    }
    if p.y > 0.38 || p.z < -0.1 || (p.y > 0.3 && q.x > 0.17) { return .Hair }
    return .Skin
}

@(private="file")
shape_hum_arm :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.25, 0}, {0.07, 0.26, 0.07}, 0.03) > 0 { return .Empty }
    return p.y > -0.24 ? .Shirt : .Skin
}

@(private="file")
shape_hum_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.68, 0.04}, {0.085, 0.065, 0.13}, 0.03) < 0 { return .Boot }
    if vm_round_box(p, {0, -0.34, 0}, {0.085, 0.35, 0.09}, 0.03) > 0 { return .Empty }
    return p.y < -0.58 ? .Boot : .Pants
}

creature_models_bake :: proc() {
    ent_models[.Fox_Body]  = model_bake({-0.2, -0.18, -0.34}, {0.2, 0.18, 0.34}, 1.0 / 16, shape_fox_body)
    ent_models[.Fox_Head]  = model_bake({-0.19, -0.04, -0.1}, {0.19, 0.45, 0.35}, 1.0 / 20, shape_fox_head)
    ent_models[.Fox_Leg]   = model_bake({-0.07, -0.33, -0.07}, {0.07, 0.02, 0.07}, 1.0 / 16, shape_fox_leg)
    ent_models[.Fox_Tail]  = model_bake({-0.14, -0.2, -0.5}, {0.14, 0.14, 0.04}, 1.0 / 16, shape_fox_tail)
    ent_models[.Bird_Body] = model_bake({-0.14, -0.13, -0.5}, {0.14, 0.15, 0.46}, 1.0 / 16, shape_bird_body)
    ent_models[.Bird_Wing] = model_bake({-0.02, -0.05, -0.24}, {1.02, 0.08, 0.12}, 1.0 / 16, shape_bird_wing)
    ent_models[.Hum_Torso] = model_bake({-0.22, -0.02, -0.14}, {0.22, 0.6, 0.14}, 1.0 / 16, shape_hum_torso)
    ent_models[.Hum_Head]  = model_bake({-0.24, -0.01, -0.23}, {0.24, 0.48, 0.23}, 1.0 / 16, shape_hum_head)
    ent_models[.Hum_Arm]   = model_bake({-0.09, -0.53, -0.09}, {0.09, 0.03, 0.09}, 1.0 / 16, shape_hum_arm)
    ent_models[.Hum_Leg]   = model_bake({-0.1, -0.75, -0.1}, {0.1, 0.02, 0.19}, 1.0 / 16, shape_hum_leg)
}

// ─── Posing helpers ─────────────────────────────────────────────────────────

basis_rot_z :: proc(a: f32) -> Basis {
    c, s := math.cos(a), math.sin(a)
    return basis_from_axes({c, s, 0}, {-s, c, 0}, {0, 0, 1})
}

// A part attached at `offset` in a parent frame (pos, rot, uniform scale s).
@(private="file")
attach :: proc(f: ^Ent_Frame, model: Model_Id, pos: [3]f32, rot: Basis, s: f32,
               offset: [3]f32, local: Basis, tint: [3]f32 = {1, 1, 1}, mirror := false) {
    sc := [3]f32{mirror ? -s : s, s, s}
    ent_part(f, model, pos + rot * (offset * s), rot * local, sc, tint)
}

IDENTITY :: Basis(1)

// ─── Fox ────────────────────────────────────────────────────────────────────

FOX_TINTS := [?][3]f32{
    {0.95, 0.48, 0.18}, // red fox
    {0.78, 0.36, 0.16}, // dark red
    {0.62, 0.62, 0.64}, // grey
    {0.92, 0.9, 0.86},  // arctic
}

// Pose a fox: trot from the walk phase, scaled by how fast it's moving;
// idle foxes look around and wag.
fox_add :: proc(f: ^Ent_Frame, e: Entity, t: f32) {
    rot := basis_yaw(e.yaw)
    s := e.scale
    run := clamp(e.speed / 2.0, 0, 1.6)
    ph := e.walk_phase
    bob := 0.025 * run * math.abs(math.sin(ph))
    body := e.pos + [3]f32{0, (0.42 + bob) * s, 0}
    lean := basis_rot_x(-0.08 * clamp(e.speed / 5, 0, 1))
    brot := rot * lean
    attach(f, .Fox_Body, body, brot, s, {0, 0, 0}, IDENTITY, e.color)
    // Head: idle foxes glance around; running foxes look ahead.
    look := (1 - clamp(run, 0, 1)) * 0.6 * math.sin(t * 0.7 + e.phase)
    attach(f, .Fox_Head, body, brot, s, {0, 0.1, 0.27}, basis_yaw(look) * basis_rot_x(0.05 * math.sin(ph * 2)), e.color)
    // Legs: diagonal pairs in phase (trot).
    for i in 0 ..< 4 {
        sx: f32 = i & 1 != 0 ? 1 : -1
        sz: f32 = i & 2 != 0 ? 1 : -1
        swing := 0.55 * min(run, 1.2) * math.sin(ph + (sx * sz > 0 ? 0 : math.PI))
        attach(f, .Fox_Leg, body, brot, s, {0.1 * sx, -0.08, 0.2 * sz}, basis_rot_x(swing), e.color)
    }
    wag := (0.35 - 0.25 * clamp(run, 0, 1)) * math.sin(t * 5 + e.phase)
    attach(f, .Fox_Tail, body, brot, s, {0, 0.06, -0.28}, basis_yaw(wag) * basis_rot_x(0.35 - 0.2 * clamp(run, 0, 1)), e.color)
}

// ─── Eagles in thermals ─────────────────────────────────────────────────────

BIRD_SPEED       :: f32(10.0)
BIRD_CULL_RADIUS :: f32(420.0)

// Pose an eagle: soaring with a slight dihedral, the odd burst of flaps.
bird_add :: proc(f: ^Ent_Frame, e: Entity, t: f32) {
    rot := basis_yaw(e.yaw) * basis_rot_z(-e.bank)
    s := e.scale
    flapping := math.sin(t * 0.35 + e.phase * 3) > 0.8
    wing := 0.14 + (flapping ? 0.55 * math.sin(t * 12 + e.phase) : 0.03 * math.sin(t * 1.3 + e.phase))
    attach(f, .Bird_Body, e.pos, rot, s, {0, 0, 0}, IDENTITY)
    attach(f, .Bird_Wing, e.pos, rot, s, {0.07, 0.03, 0.02}, basis_rot_z(wing))
    attach(f, .Bird_Wing, e.pos, rot, s, {-0.07, 0.03, 0.02}, basis_rot_z(-wing), mirror = true)
}

// Keep a couple of eagles circling in every strong thermal near the player
// and drop the ones whose thermal is far away. Called about once a second.
birds_manage :: proc(gs: ^Game_State) {
    p := gs.camera.pos
    cx := int(math.floor(p.x / THERMAL_CELL))
    cz := int(math.floor(p.z / THERMAL_CELL))
    // Drop birds far from the player.
    for i := len(gs.entities) - 1; i >= 0; i -= 1 {
        e := gs.entities[i]
        if e.kind != .Bird { continue }
        if abs(int(e.cell.x) - cx) > 3 || abs(int(e.cell.y) - cz) > 3 { unordered_remove(&gs.entities, i) }
    }
    for dz in -2 ..= 2 {
        for dx in -2 ..= 2 {
            gx, gz := cx + dx, cz + dz
            th, ok := thermal_cell(gx, gz)
            if !ok || th.strength < 4.5 { continue }
            have := 0
            for e in gs.entities { if e.kind == .Bird && e.cell == {i32(gx), i32(gz)} { have += 1 } }
            if have >= 2 { continue }
            // Fly above the highest ground anywhere under the circle (and the
            // downwind lean), not just above the thermal's centre.
            ground := max(f32(surface_height_at(int(th.centre.x), int(th.centre.y))), SEA_LEVEL)
            ring := ground
            for i in 0 ..< 12 {
                a := f32(i) / 12 * 2 * math.PI
                r := th.radius + 14
                ring = max(ring, f32(surface_height_at(int(th.centre.x + math.cos(a) * r), int(th.centre.y + math.sin(a) * r))))
            }
            for k in have ..< 2 {
                alt := max(ground + min(th.top * 0.7, 28 + 26 * f32(k) + rand.float32_range(0, 10)), ring + 18 + 12 * f32(k))
                append(&gs.entities, Entity{
                    kind  = .Bird,
                    scale = rand.float32_range(1.5, 1.8),
                    phase = rand.float32_range(0, 2 * math.PI),
                    cell  = {i32(gx), i32(gz)},
                    orbit = {th.centre.x, th.centre.y, th.radius * rand.float32_range(0.55, 0.85), alt},
                    orbit_angle = rand.float32_range(0, 2 * math.PI),
                    orbit_dir   = rand.float32() < 0.5 ? 1 : -1,
                })
            }
        }
    }
}

// Circle the thermal: the centre leans downwind with height like the air
// does, the altitude breathes slowly, and the bank matches the turn.
bird_update :: proc(gs: ^Game_State, e: ^Entity, dt, t: f32) {
    r := max(e.orbit[2], 6)
    e.orbit_angle += e.orbit_dir * BIRD_SPEED / r * dt
    // Thermals lean ~0.08 m downwind per metre of height; birds sit ~40 up.
    lean := glider_wind(gs.glider.wind_time) * (40 * 0.08)
    c, s := math.cos(e.orbit_angle), math.sin(e.orbit_angle)
    alt := e.orbit[3] + 4 * math.sin(t * 0.05 + e.phase)
    e.pos = {e.orbit[0] + lean.x + c * r, alt, e.orbit[1] + lean.z + s * r}
    // Velocity direction is the tangent of the circle.
    vx, vz := -s * e.orbit_dir, c * e.orbit_dir
    e.yaw = math.atan2(-vx, vz)
    e.bank = -e.orbit_dir * math.atan(BIRD_SPEED * BIRD_SPEED / (9.8 * r))
}

// ─── Player body ────────────────────────────────────────────────────────────

PLAYER_TINT :: [3]f32{0.22, 0.58, 0.62}

Player_Anim :: struct {
    body_yaw:   f32, // entity-yaw convention (radians)
    walk_phase: f32,
    amp:        f32, // smoothed stride amplitude
    air:        f32, // 0 grounded .. 1 airborne, smoothed
}

player_anim_update :: proc(gs: ^Game_State, dt: f32) {
    cam := &gs.camera
    anim_step(&gs.player_anim, cam.velocity, cam.yaw, gs.combat.sword, cam.on_ground || cam.fly_mode, dt)
}

// A walking body's turn, stride and airborne tuck, for velocity v and the
// look yaw (degrees, camera convention).
anim_step :: proc(a: ^Player_Anim, v: [3]f32, look_yaw: f32, sword, grounded: bool, dt: f32) {
    sp := math.sqrt(v.x * v.x + v.z * v.z)
    if sword {
        // Sword drawn: squared up to where you look, strafing.
        target := -math.to_radians(look_yaw)
        d := math.mod(target - a.body_yaw + 3 * math.PI, 2 * math.PI) - math.PI
        a.body_yaw += d * min(dt * 14, 1)
    } else if sp > 0.6 {
        target := math.atan2(-v.x, v.z)
        d := math.mod(target - a.body_yaw + 3 * math.PI, 2 * math.PI) - math.PI
        a.body_yaw += d * min(dt * 10, 1)
    }
    a.walk_phase += sp * dt * 2.4
    a.amp += (clamp(sp / 5, 0, 1.3) - a.amp) * min(dt * 8, 1)
    air: f32 = grounded ? 0 : 1
    a.air += (air - a.air) * min(dt * 8, 1)
}

// Standing / walking / jumping player at its feet, for the chase view.
player_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    a := &gs.player_anim
    if gs.glider.deployed || gs.glider.chase_dist < 1.0 || !ent_begin(f) { return }
    feet := gs.camera.pos - [3]f32{0, PLAYER_EYE_HEIGHT, 0}
    feet.y += gs.camera.step_visual_offset
    sword := gs.combat.sword
    hips := humanoid_add_parts(f, feet, a, gs.camera.yaw, gs.camera.pitch, PLAYER_TINT, right_arm = !sword)
    if sword {
        // The sword arm reaches for the grip, posed as in first person from
        // a viewpoint at the eyes.
        fwd, right, up := camera_basis(gs.camera)
        eye := feet + [3]f32{0, 1.5, 0} + fwd * 0.15
        shoulder := feet + basis_yaw(a.body_yaw) * (hips + [3]f32{-0.27, 0.52, 0})
        grip, blade, edge, flat := sword_world(gs, eye, fwd, right, up, shoulder)
        sword_arm_parts(f, shoulder, grip, blade, edge, flat, right * 0.6 - up - fwd * 0.4)
    }
    ent_end(f)
}

// A player's body at its feet, posed by its animation, the head turned
// toward where it looks (degrees, camera convention); the right arm too
// unless the caller poses it. Returns the hips, in body space.
humanoid_add_parts :: proc(f: ^Ent_Frame, feet: [3]f32, a: ^Player_Anim, look_yaw, look_pitch: f32, tint: [3]f32, right_arm: bool) -> (hips: [3]f32) {
    rot := basis_yaw(a.body_yaw)
    sw := 0.7 * a.amp * math.sin(a.walk_phase)
    bob := 0.04 * a.amp * math.abs(math.cos(a.walk_phase))
    // In the air: legs tuck, arms lift.
    leg_l := sw * (1 - a.air) - 0.5 * a.air
    leg_r := -sw * (1 - a.air) + 0.25 * a.air
    arm_out := 0.08 + 0.5 * a.air
    hips = {0, 0.74 + bob, 0}
    attach(f, .Hum_Leg, feet, rot, 1, hips + {0.1, 0, 0}, basis_rot_x(leg_l), tint)
    attach(f, .Hum_Leg, feet, rot, 1, hips + {-0.1, 0, 0}, basis_rot_x(leg_r), tint)
    attach(f, .Hum_Torso, feet, rot, 1, hips, basis_rot_x(-0.06 * a.amp), tint)
    attach(f, .Hum_Arm, feet, rot, 1, hips + {0.27, 0.52, 0}, basis_rot_z(arm_out) * basis_rot_x(-0.8 * sw), tint)
    if right_arm {
        attach(f, .Hum_Arm, feet, rot, 1, hips + {-0.27, 0.52, 0}, basis_rot_z(-arm_out) * basis_rot_x(0.8 * sw), tint)
    }
    // Head follows the look a little.
    yaw := -math.to_radians(look_yaw)
    look := clamp(math.mod(yaw - a.body_yaw + 3 * math.PI, 2 * math.PI) - math.PI, -0.9, 0.9)
    pitch := clamp(-math.to_radians(look_pitch) * 0.6, -0.5, 0.5)
    attach(f, .Hum_Head, feet, rot, 1, hips + {0, 0.58, 0}, basis_yaw(look) * basis_rot_x(pitch), tint)
    return
}

// A basis whose -y axis points along d (limbs hang along -y).
@(private="file")
basis_hang_along :: proc(d, ref: [3]f32) -> Basis {
    y := -la.normalize(d)
    x := la.cross(y, ref)
    if la.length2(x) < 1e-6 { x = la.cross(y, [3]f32{0, 0, 1}) }
    x = la.normalize(x)
    return basis_from_axes(x, y, la.cross(x, y))
}

// The pilot lying prone under the glider (body frame rot at the eye `p`),
// hands on the base bar. Third person only.
pilot_add_parts :: proc(f: ^Ent_Frame, p: [3]f32, rot: Basis) {
    prone := rot * basis_rot_x(math.PI / 2) // humanoid up -> glider forward, face -> down
    feet := p + rot * [3]f32{0, 0.22, -1.56}
    hips := [3]f32{0, 0.74, 0}
    attach(f, .Hum_Leg, feet, prone, 1, hips + {0.1, 0, 0}, basis_rot_x(0.05), PLAYER_TINT)
    attach(f, .Hum_Leg, feet, prone, 1, hips + {-0.1, 0, 0}, basis_rot_x(-0.05), PLAYER_TINT)
    attach(f, .Hum_Torso, feet, prone, 1, hips, IDENTITY, PLAYER_TINT)
    attach(f, .Hum_Head, feet, prone, 1, hips + {0, 0.58, 0}, basis_rot_x(-0.9), PLAYER_TINT)
    up := rot * [3]f32{0, 1, 0}
    for side in ([2]f32{1, -1}) {
        shoulder := feet + prone * (hips + [3]f32{0.27 * side, 0.52, 0})
        hand := p + rot * [3]f32{0.5 * side, -0.42, 0.72}
        d := hand - shoulder
        ent_part(f, .Hum_Arm, shoulder, basis_hang_along(d, up), {1, la.length(d) / 0.53, 1}, PLAYER_TINT)
    }
}
