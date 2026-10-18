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

// The player, Cube World style: a big round head in a deep hood, a compact
// body in a robe flaring to the ground, and the hands and feet apart from
// it (no arms or legs): leather gloves with gold cuffs, as the first-person
// hands (magic.odin), and soft boots. The robe is the part's tint (Shirt;
// Shirt_Trim and Robe_Dark its shades), trimmed in gold; a belt with a
// glowing stone; a short cape. Pivots: the head at the neck, the body at
// the hips, a hand at its wrist, a foot at its ankle.
@(private="file")
shape_hum_torso :: proc(p: [3]f32, voxel: f32) -> Pal {
    t := clamp(-p.y / 0.34, 0, 1) // down the skirt
    chest := vm_round_box(p, {0, 0.17, 0}, {0.23, 0.23, 0.17}, 0.11)
    skirt := vm_round_box(p, {0, -0.16, 0}, {0.21 + 0.07 * t, 0.18, 0.16 + 0.05 * t}, 0.06) // to above the boots
    mantle := vm_round_box(p, {0, 0.36, -0.005}, {0.26, 0.07, 0.18}, 0.06)
    if mantle < 0 && p.y > 0.29 {
        return p.y < 0.31 ? .Guard : .Shirt_Trim // a shoulder mantle, gold at its edge
    }
    if min(chest, skirt) > 0 {
        if vm_round_box(p, {-0.24, -0.06, 0.03}, {0.045, 0.07, 0.06}, 0.025) < 0 { return .Leather } // a pouch
        return .Empty
    }
    if p.y > -0.04 && p.y < 0.03 {
        if p.z > 0.1 && abs(p.x) < 0.03 { return .Pommel_Gem } // the belt's stone
        return .Leather_Dark
    }
    if p.y < -0.3 { return .Guard } // the hem's gold
    if p.z > 0.08 && abs(p.x) < 0.03 { return .Robe_Dark } // the robe's opening
    if p.y < -0.25 { return .Shirt_Trim }
    return .Shirt
}

@(private="file")
shape_hum_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    head := vm_round_box(p, {0, 0.29, 0.02}, {0.25, 0.26, 0.24}, 0.12)
    hood := vm_round_box(p, {0, 0.31, -0.02}, {0.3, 0.31, 0.29}, 0.15)
    tail := vm_capsule(p, {0, 0.5, -0.2}, {0, 0.36, -0.46}, 0.06) // its point, drooping behind
    open := p.z > 0.06 && q.x < 0.2 && p.y > 0.06 && p.y < 0.44 // where the face looks out
    if (hood < 0 && head > -0.03 && !open) || tail < 0 {
        if p.z > 0.1 && q.x < 0.24 && p.y > 0.03 && p.y < 0.48 { return .Robe_Dark } // the lining round the face
        return .Shirt_Trim
    }
    if head > 0 {
        if vm_round_box(p, {0, 0.24, 0.27}, {0.025, 0.035, 0.03}, 0.015) < 0 { return .Skin } // the nose
        return .Empty
    }
    if p.z > 0.18 {
        // Eyes: dark, a glint in the upper inside corner; brows above.
        if abs(q.x - 0.1) < 0.035 && abs(p.y - 0.28) < 0.05 {
            return q.x < 0.09 && p.y > 0.3 ? .Eye_White : .Eye
        }
        if abs(q.x - 0.11) < 0.05 && p.y > 0.35 && p.y < 0.38 { return .Hair }
    }
    if p.y > 0.4 { return .Hair } // under the hood
    return .Skin
}

// A gloved fist below the wrist, the gold cuff above it; knuckles forward.
@(private="file")
shape_hum_hand :: proc(p: [3]f32, voxel: f32) -> Pal {
    if p.y > -0.035 {
        return vm_round_box(p, {0, -0.01, 0}, {0.08, 0.025, 0.08}, 0.02) < 0 ? .Guard : .Empty
    }
    if vm_round_box(p, {0, -0.1, 0.005}, {0.072, 0.07, 0.07}, 0.035) > 0 {
        if vm_capsule(p, {0.07, -0.08, 0.04}, {0.08, -0.12, 0.06}, 0.025) < 0 { return .Glove } // the thumb
        return .Empty
    }
    if p.z > 0.04 && p.y < -0.06 { return .Glove_Dark } // knuckles
    return .Glove
}

// A soft boot, toe forward, the ankle at the top, its top turned down.
@(private="file")
shape_hum_foot :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.07, 0.03}, {0.075, 0.07, 0.12}, 0.045) > 0 { return .Empty }
    if p.y > -0.035 { return .Leather }
    if p.y < -0.12 { return .Leather_Dark } // the sole
    return .Boot
}

// A short cape from the shoulders (its pivot, behind the neck), hanging
// along -y, the outside toward -z; gold at the ragged hem.
@(private="file")
shape_hum_cape :: proc(p: [3]f32, voxel: f32) -> Pal {
    if p.y > 0 || p.z > 0 || p.z < -0.08 { return .Empty }
    half := 0.19 + 0.08 * clamp(-p.y / 0.6, 0, 1) // wider toward the hem
    if abs(p.x) > half { return .Empty }
    hem := -0.6 - 0.03 * math.sin(p.x * 31)
    if p.y < hem { return .Empty }
    if p.y < hem + 0.04 { return .Guard }
    if p.y < hem + 0.09 { return .Shirt_Trim }
    return .Robe_Dark
}

creature_models_bake :: proc() {
    ent_models[.Fox_Body]  = model_bake({-0.2, -0.18, -0.34}, {0.2, 0.18, 0.34}, 1.0 / 16, shape_fox_body)
    ent_models[.Fox_Head]  = model_bake({-0.19, -0.04, -0.1}, {0.19, 0.45, 0.35}, 1.0 / 20, shape_fox_head)
    ent_models[.Fox_Leg]   = model_bake({-0.07, -0.33, -0.07}, {0.07, 0.02, 0.07}, 1.0 / 16, shape_fox_leg)
    ent_models[.Fox_Tail]  = model_bake({-0.14, -0.2, -0.5}, {0.14, 0.14, 0.04}, 1.0 / 16, shape_fox_tail)
    ent_models[.Bird_Body] = model_bake({-0.14, -0.13, -0.5}, {0.14, 0.15, 0.46}, 1.0 / 16, shape_bird_body)
    ent_models[.Bird_Wing] = model_bake({-0.02, -0.05, -0.24}, {1.02, 0.08, 0.12}, 1.0 / 16, shape_bird_wing)
    // Finer than the creatures: round enough to read as Cube World's.
    ent_models[.Hum_Torso] = model_bake({-0.3, -0.44, -0.22}, {0.3, 0.45, 0.22}, 1.0 / 28, shape_hum_torso)
    ent_models[.Hum_Head]  = model_bake({-0.32, -0.02, -0.54}, {0.32, 0.64, 0.32}, 1.0 / 28, shape_hum_head)
    ent_models[.Hum_Hand]  = model_bake({-0.1, -0.18, -0.1}, {0.11, 0.02, 0.1}, 1.0 / 40, shape_hum_hand)
    ent_models[.Hum_Foot]  = model_bake({-0.09, -0.15, -0.1}, {0.09, 0.01, 0.16}, 1.0 / 40, shape_hum_foot)
    ent_models[.Hum_Cape]  = model_bake({-0.29, -0.65, -0.09}, {0.29, 0.01, 0.01}, 1.0 / 28, shape_hum_cape)
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

BIRD_SPEED       : f32 = f32(10.0)
BIRD_CULL_RADIUS :: f32(420.0)

// Pose an eagle: soaring with a slight dihedral, the odd burst of flaps
// (or flapping all the while: the entity sandbox's).
bird_add :: proc(f: ^Ent_Frame, e: Entity, t: f32, flap := false) {
    rot := basis_yaw(e.yaw) * basis_rot_z(-e.bank)
    s := e.scale
    flapping := flap || math.sin(t * 0.35 + e.phase * 3) > 0.8
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

PLAYER_TINT :: [3]f32{0.17, 0.26, 0.52} // the robe: a deep blue, as the spell's light

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
    } else if sp > 0.6 * world_scale {
        target := math.atan2(-v.x, v.z)
        d := math.mod(target - a.body_yaw + 3 * math.PI, 2 * math.PI) - math.PI
        a.body_yaw += d * min(dt * 10, 1)
    }
    sp /= world_scale // strides as long as the legs
    a.walk_phase += sp * dt * 2.4
    a.amp += (clamp(sp / 5, 0, 1.3) - a.amp) * min(dt * 8, 1)
    air: f32 = grounded ? 0 : 1
    a.air += (air - a.air) * min(dt * 8, 1)
}

// Standing / walking / jumping player at its feet, for the chase view. In
// first person the body is only a shadow (the view starts inside its head),
// and none in fly mode: a free camera (and the benches') has no body under it.
player_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    a := &gs.player_anim
    first := gs.glider.chase_dist < 1.0
    if gs.glider.deployed || (first && gs.camera.fly_mode) || !ent_begin(f, seen = !first) { return }
    feet := gs.camera.pos - [3]f32{0, PLAYER_EYE_HEIGHT, 0}
    feet.y += gs.camera.step_visual_offset
    ent_scale_about(f, feet, world_scale)
    sword := gs.combat.sword
    act := local_body_act(gs)
    if sword { act.raise = 0 }
    hips := humanoid_add_parts(f, feet, a, gs.camera.yaw, gs.camera.pitch, PLAYER_TINT, right_arm = !sword, act = &act)
    if sword && !first { // in first person combat_add_parts draws it, seen and with a shadow
        // The sword arm reaches for the grip, posed as in first person from
        // a viewpoint at the eyes.
        fwd, right, up := camera_basis(gs.camera)
        eye := feet + [3]f32{0, 1.5, 0} + fwd * 0.15
        shoulder := feet + basis_yaw(a.body_yaw) * [3]f32{-HUM_SHOULDER.x, HUM_SHOULDER.y, HUM_SHOULDER.z}
        grip, blade, edge, flat := sword_world(gs, eye, fwd, right, up, shoulder)
        sword_arm_parts(f, shoulder, grip, blade, edge, flat, right * 0.6 - up - fwd * 0.4, arm = false)
    }
    ent_end(f)
}

// What a body's hands are doing besides walking: pulling up onto a ledge
// (camera.odin's mantle), or casting (magic.odin), both hands toward what
// the spell works on. The same for every player's body, ours or another's.
Body_Act :: struct {
    climbing: bool,
    raise:    f32,    // casting: the hands up, 0..1
    at:       [3]f32, // world: the ledge's lip between the hands, or the spell's block
    k:        f32,    // climbing: 0..1 through the pull-up; casting: how far the spell is along
    t:        f32,    // a clock, for the trembling hands
    palms:    [2][3]f32, // out (world): where a casting body's palms are, right then left
}

// Where the body's parts sit (body space, design metres, feet at the
// origin): the hips (the body's pivot), the neck, and the hands at rest
// and the shoulders they hang from.
HUM_HIPS     :: [3]f32{0, 0.55, 0}
HUM_NECK     :: [3]f32{0, 0.99, 0}
HUM_SHOULDER :: [3]f32{0.25, 0.92, 0} // the left one; x mirrored for the right
HUM_HAND     :: [3]f32{0.33, 0.6, 0.03}

// A player's body at its feet, posed by its animation (and act, if given),
// the head turned toward where it looks (degrees, camera convention); the
// right hand too unless the caller poses it (the sword's). Returns the
// hips, in body space.
humanoid_add_parts :: proc(f: ^Ent_Frame, feet: [3]f32, a: ^Player_Anim, look_yaw, look_pitch: f32, tint: [3]f32, right_arm: bool, act: ^Body_Act = nil) -> (hips: [3]f32) {
    climb := act != nil && act.climbing
    raised := act != nil && !climb && act.raise > 0.01 ? act.raise : 0
    // Parts are given at design size about the feet (ent_scale_about): the
    // act's world points come back to that size.
    design :: proc(feet, w: [3]f32) -> [3]f32 { return feet + (w - feet) / world_scale }
    body_yaw := a.body_yaw
    if climb {
        d := act.at - feet
        if d.x * d.x + d.z * d.z > 1e-4 { body_yaw = math.atan2(-d.x, d.z) } // facing the ledge
    }
    rot := basis_yaw(body_yaw)
    inv := la.transpose(rot)
    ph := a.walk_phase
    amp := min(a.amp, 1.2)
    ground := 1 - a.air
    bob := 0.035 * amp * math.abs(math.cos(ph)) * ground
    lean := 0.07 * amp * ground - 0.05 * a.air
    if climb { lean = 0.3 * math.sin(clamp(act.k, 0, 1) * math.PI) } // over the lip

    // Feet: little steps, each lifted as it swings through; tucked in the air.
    for side in ([2]f32{1, -1}) {
        sp := ph + (side > 0 ? 0 : math.PI)
        z := 0.17 * amp * math.sin(sp) * ground
        lift := 0.08 * amp * max(math.cos(sp), 0) * ground + 0.1 * a.air
        tilt := -0.35 * amp * math.cos(sp) * ground + 0.3 * a.air
        if climb {
            // Up the face: one knee in to it, the other pushing off.
            u := clamp(act.k, 0, 1)
            k := side > 0 ? math.sin(clamp(u * 1.6, 0, 1) * math.PI) : math.sin(clamp(u * 1.6 - 0.4, 0, 1) * math.PI)
            z, lift, tilt = 0.12 * k, 0.3 * k, -0.4 * k
        }
        attach(f, .Hum_Foot, feet, rot, 1, {0.11 * side, 0.15 + lift, z - 0.02}, basis_rot_x(tilt), tint)
    }
    hips = HUM_HIPS + {0, bob, 0}
    attach(f, .Hum_Torso, feet, rot, 1, hips, basis_rot_x(lean), tint)
    // The cape swings back with the pace and in the air, and stirs.
    flap := 0.05 + 0.25 * amp + 0.45 * a.air + 0.04 * amp * math.sin(ph * 2 + 0.7)
    attach(f, .Hum_Cape, feet, rot, 1, hips + {0, 0.38, -0.17}, basis_rot_x(max(flap, lean + 0.06)), tint)

    // Hands: swinging against the feet, or on what the act is about.
    target: [3]f32 // body space
    if act != nil { target = inv * (design(feet, act.at) - feet) }
    for side in ([2]f32{1, -1}) { // left (+x), right
        if side < 0 && !right_arm { continue }
        sp := ph + (side > 0 ? math.PI : 0)
        rest := [3]f32{HUM_HAND.x * side + 0.06 * a.air * side, HUM_HAND.y + bob + 0.18 * a.air, HUM_HAND.z}
        rest.z += 0.15 * amp * math.sin(sp) * ground
        rest.y += 0.03 * amp * math.abs(math.sin(sp)) * ground
        swing := basis_rot_x(-0.5 * amp * math.sin(sp) * ground)
        shoulder := [3]f32{HUM_SHOULDER.x * side, HUM_SHOULDER.y, HUM_SHOULDER.z}
        switch {
        case climb:
            // Gripping the lip a shoulder's width apart, reached for as the
            // pull-up starts (MANTLE_GRAB).
            reach := min(act.k / 0.16, 1)
            grip := target + {0.2 * side, 0.08, 0}
            if d := grip - shoulder; la.length(d) > 0.6 { grip = shoulder + la.normalize(d) * 0.6 } // no farther than an arm would go
            attach(f, .Hum_Hand, feet, rot, 1, la.lerp(shoulder + {0, 0.3, 0.2}, grip, reach), basis_rot_x(-1.2), tint)
        case raised > 0:
            // Out toward the block, a little apart, trembling as the spell
            // takes hold; the gloves open, palms to it.
            aim := la.normalize0(target - shoulder)
            if aim == 0 { aim = {0, 0, 1} }
            out := shoulder + la.normalize(aim + {-0.2 * side, 0.1, 0}) * 0.45
            if act.k > 0 {
                w := act.t * 31 + side
                out += [3]f32{math.sin(w), math.cos(w * 1.3), 0} * 0.006 * (1 + act.k)
            }
            hand := la.lerp(rest, out, raised)
            if raised < 0.3 {
                attach(f, .Hum_Hand, feet, rot, 1, hand, swing, tint)
                continue
            }
            dir := la.normalize0(hand - shoulder)
            if dir == 0 { dir = {0, 0, 1} }
            pn := la.normalize0(target - hand)
            pn = la.normalize0(pn - dir * la.dot(pn, dir))
            if pn == 0 { pn = {0, 0, 1} }
            fingers := la.normalize(dir + {0, 0.5, 0}) // up a little, as if pushing on the air
            fingers = la.normalize0(fingers - pn * la.dot(fingers, pn))
            if fingers == 0 { fingers = dir }
            y := -pn
            glove := basis_from_axes(la.cross(y, fingers), y, fingers)
            rune := MAGIC_TINT * ((0.5 + 0.9 * act.k) * (0.9 + 0.1 * math.sin(act.t * 9)))
            wrist := hand - fingers * 0.08
            ent_part(f, side > 0 ? .Glove_L : .Glove_R, feet + rot * wrist, rot * glove, {1.4, 1.4, 1.4}, rune) // as big as the fists
            palm := wrist + fingers * 0.09 + pn * 0.04
            act.palms[side > 0 ? 1 : 0] = feet + rot * palm * world_scale
        case:
            attach(f, .Hum_Hand, feet, rot, 1, rest, swing, tint)
        }
    }
    // Head follows the look a little.
    yaw := -math.to_radians(look_yaw)
    look := clamp(math.mod(yaw - body_yaw + 3 * math.PI, 2 * math.PI) - math.PI, -0.9, 0.9)
    pitch := clamp(-math.to_radians(look_pitch) * 0.5, -0.4, 0.4)
    if climb { look, pitch = 0, 0.3 } // down at the hands
    neck := HUM_NECK + {0, bob, 0.35 * lean} // riding the body's lean
    attach(f, .Hum_Head, feet, rot, 1, neck, basis_yaw(look) * basis_rot_x(pitch), tint)
    return
}

// The pilot lying prone under the glider (body frame rot at the eye `p`),
// hands on the base bar. Third person only (in first person, without the
// arms, only as a shadow).
pilot_add_parts :: proc(f: ^Ent_Frame, p: [3]f32, rot: Basis, tint := PLAYER_TINT, grip := [3]f32{0.48, -0.42, 0.72}, arms := true) {
    prone := rot * basis_rot_x(math.PI / 2) // humanoid up -> glider forward, face -> down
    feet := p + rot * [3]f32{0, 0.22, -1.5}
    attach(f, .Hum_Foot, feet, prone, 1, {0.11, 0.12, -0.02}, basis_rot_x(0.6), tint)
    attach(f, .Hum_Foot, feet, prone, 1, {-0.11, 0.12, -0.02}, basis_rot_x(0.5), tint)
    attach(f, .Hum_Torso, feet, prone, 1, HUM_HIPS, IDENTITY, tint)
    attach(f, .Hum_Cape, feet, prone, 1, HUM_HIPS + {0, 0.38, -0.17}, basis_rot_x(0.05), tint)
    attach(f, .Hum_Head, feet, prone, 1, HUM_NECK, basis_rot_x(-0.9), tint)
    if !arms { return } // drawn by the caller
    for side in ([2]f32{1, -1}) {
        hand := p + rot * [3]f32{grip.x * side, grip.y, grip.z}
        ent_part(f, .Hum_Hand, hand + rot * [3]f32{0, 0.08, 0}, rot, {1, 1, 1}, tint) // round the bar
    }
}
