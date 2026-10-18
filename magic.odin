package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import la "core:math/linalg"

// Survival building is magic (gs.survival; a creative world keeps the build
// tools). Hold left on a block and a beam of sparks reaches out from the
// wand in your hand: the block unravels, in a time that goes by how hard it
// is (unweave_time), then comes apart into motes that fly to you and into
// what you carry (gs.items). Right conjures the block in hand out of what
// you carry. One block at a time, within MAGIC_REACH. A tree's trunk brings
// the whole tree down (felling.odin).

MAGIC_REACH :: f32(12) // voxels: 8 m
MAX_MOTES   :: 192
MAX_SPARKS  :: 96
MAGIC_TINT  :: [3]f32{0.10, 0.28, 0.75} // the spell's sparks (they glow: ×4 in the shader)

// A piece of something unwoven, on its way to you.
Mote :: struct {
    pos, vel: [3]f32,
    age:      f32, // seconds out; below 0 still waiting to go (a tree's go in a stream)
    block:    Block_Type,
    count:    u32, // blocks it brings (0: only sparkle)
    tint:     [3]f32,
    size:     f32, // 0: a free slot
    home:     u8,  // who it flies to: 0 you, else that player's slot + 1 (their tree: no count)
}

// A spark of the spell: flies, slows, goes out.
Spark :: struct {
    pos, vel:  [3]f32,
    life, max: f32,
    tint:      [3]f32,
}

Magic :: struct {
    // Unweaving: the block under the beam and how far along it is.
    channeling: bool,
    target:     [3]int,
    block:      Block_Type,
    progress:   f32, // seconds on this block
    need:       f32, // seconds it takes
    tree_logs:  int, // > 0: a tree's trunk; this many logs come down with it
    chip_timer: f32,
    hum_timer:  f32,
    // The hand: raised while casting, lowered after.
    raise:      f32, // 0 down .. 1 up
    conjure:    f32, // > 0: a block was just conjured; the beam shows this long
    conjure_at: [3]f32,
    t:          f32,
    motes:      [MAX_MOTES]Mote,
    next_mote:  int,
    sparks:     [MAX_SPARKS]Spark,
    next_spark: int,
    pickup_gap: f32, // since a mote last arrived: a quick run of them rises in pitch
    pickup_run: int,
}

// Seconds of channelling to unweave a block.
unweave_time :: proc(b: Block_Type) -> f32 {
    v := u8(b)
    switch {
    case block_is_land_plant(v) || block_is_water_plant(v): return 0.08
    case block_is_door(v):   return 0.5
    case block_is_leaves(v): return 0.15
    case block_is_log(v):    return 0.55
    }
    #partial switch b {
    case .Torch:                        return 0.08
    case .Snow:                         return 0.25
    case .Glow_Moss, .Moss:             return 0.3
    case .Grass, .Dry_Grass, .Dirt, .Sand, .Red_Sand, .Gravel: return 0.35
    case .Cactus:                       return 0.4
    case .Ice:                          return 0.5
    case .Stone, .Weathered_Stone, .Sandstone, .Terracotta, .Dripstone, .Coral: return 0.8
    case .Stone_Bricks, .Coal_Ore:      return 1.0
    case .Iron_Ore:                     return 1.2
    case .Gold_Ore:                     return 1.3
    case .Crystal:                      return 1.4
    }
    return 0.6
}

// A block's colour as a linear tint (from the icons' sRGB).
block_color :: proc(b: Block_Type) -> [3]f32 {
    top, side := icon_colors(b)
    c := block_is_log(u8(b)) ? side : top
    return {math.pow(c.x, 2.2), math.pow(c.y, 2.2), math.pow(c.z, 2.2)}
}

block_center :: proc(p: [3]int) -> [3]f32 { return la.array_cast(p, f32) + 0.5 }

// A mote's glow: the block's colour, brightened toward a common level so
// dark blocks still shine, with a touch of the spell.
mote_tint :: proc(b: Block_Type) -> [3]f32 {
    c := block_color(b)
    return c / max(max(c.x, c.y), max(c.z, 0.05)) * 0.35 + MAGIC_TINT * 0.1
}

@(private="file")
rand_dir :: proc() -> [3]f32 {
    for {
        v := [3]f32{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)}
        if l := la.length(v); l > 0.05 && l <= 1 { return v / l }
    }
}

// ─── Casting ───────────────────────────────────────────────────────────────

// The clicks, in survival (build_update: the mouse locked, no sword out, not
// gliding). Left held unweaves the block aimed at; right conjures, again
// every EDIT_REPEAT while held.
magic_build_update :: proc(gs: ^Game_State, dt: f32) {
    m := &gs.magic
    hit, nrm, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), MAGIC_REACH, plants = true)
    if gs.left_held && ok {
        b := Block_Type(u8(get_voxel(gs, hit.x, hit.y, hit.z)))
        if !m.channeling || hit != m.target || b != m.block {
            m.channeling, m.target, m.block, m.progress = true, hit, b, 0
            m.need, m.tree_logs = unweave_time(b), 0
            if block_is_log(u8(b)) {
                m.tree_logs = felling_trunk_logs(gs, hit)
                if m.tree_logs > 0 { m.need = fell_time(m.tree_logs) }
            }
        }
        m.progress += dt
        if m.progress >= m.need {
            magic_unweave(gs, hit)
            m.channeling = false
        }
    } else {
        m.channeling = false
    }
    placing := gs.right_pressed || (gs.right_held && gs.edit_timer <= 0)
    if placing && !gs.left_held {
        gs.edit_timer = EDIT_REPEAT
        if ok { magic_conjure(gs, hit, nrm) }
    }
}

// The block at p comes apart (or, a tree's trunk, the tree comes down).
@(private="file")
magic_unweave :: proc(gs: ^Game_State, p: [3]int) {
    m := &gs.magic
    if m.tree_logs > 0 && felling_start(gs, p) { return }
    b := m.block
    if build_apply(gs, sphere_region(p, 0), .Air, .All) == 0 { return }
    drop := block_is_door(u8(b)) ? Block_Type.Door : b
    c := block_center(p)
    sparks_burst(gs, c, MAGIC_TINT, 10, 5)
    for i in 0 ..< 3 {
        mote_add(gs, {pos = c + rand_dir() * 0.25, vel = rand_dir() * 4 + {0, 3, 0}, block = drop,
            count = i == 0 ? 1 : 0, tint = mote_tint(drop), size = i == 0 ? 0.9 : 0.5})
    }
    play_at(.Magic_Break, c, 0.45, vary(0.1))
}

// The block in hand, out of what you carry, on the face aimed at (in a
// plant's place, as the block tool does).
@(private="file")
magic_conjure :: proc(gs: ^Game_State, hit, nrm: [3]int) {
    b := gs.selected_block
    if b == .Air { return }
    if items_shown(gs, b) == 0 {
        ui_toast(gs, fmt.tprintf("No %s left", block_name(b)), 1.2)
        return
    }
    target := hit
    if !block_is_land_plant(u8(get_voxel(gs, hit.x, hit.y, hit.z))) { target = hit + nrm }
    placed := b == .Door ? door_place(gs, hit, nrm) : build_apply(gs, sphere_region(target, 0), b, .All) > 0
    if !placed { return } // (spent as the edit is counted: items.odin)
    m := &gs.magic
    m.conjure, m.conjure_at = 0.2, block_center(target)
    sparks_burst(gs, m.conjure_at, mote_tint(b), 8, 3)
    play_at(.Magic_Place, m.conjure_at, 0.45, vary(0.06))
}

// A mote brought blocks home (they were counted when the edit was made:
// items.odin): a block that had no hotbar slot gets the first empty one.
magic_collect :: proc(gs: ^Game_State, b: Block_Type, n: u32) {
    if n == 0 || b == .Air { return }
    for h in gs.hotbar { if h == b { return } }
    for h, i in gs.hotbar {
        if h != .Air { continue }
        gs.hotbar[i] = b
        if i == gs.hotbar_slot { hotbar_select(gs, i) }
        return
    }
}

mote_add :: proc(gs: ^Game_State, mo: Mote) {
    m := &gs.magic
    old := &m.motes[m.next_mote]
    if old.size > 0 { magic_collect(gs, old.block, old.count) } // all slots busy: that one's here already
    old^ = mo
    m.next_mote = (m.next_mote + 1) % MAX_MOTES
}

sparks_burst :: proc(gs: ^Game_State, c, tint: [3]f32, n: int, speed: f32) {
    m := &gs.magic
    for _ in 0 ..< n {
        life := rand.float32_range(0.25, 0.55)
        m.sparks[m.next_spark] = {pos = c + rand_dir() * 0.3, vel = rand_dir() * speed * rand.float32_range(0.5, 1.2), life = life, max = life, tint = tint}
        m.next_spark = (m.next_spark + 1) % MAX_SPARKS
    }
}

// ─── Every frame ───────────────────────────────────────────────────────────

// The spell's effects and the motes flying home; every frame, after
// build_update.
magic_update :: proc(gs: ^Game_State, dt: f32) {
    m := &gs.magic
    if dt <= 0 { return }
    m.t += dt
    m.conjure -= dt
    if !gs.survival || !gs.mouse_locked || gs.combat.sword || gs.glider.deployed { m.channeling = false }
    up := m.channeling || m.conjure > 0
    m.raise = clamp(m.raise + (up ? dt * 6 : -dt * 2.5), 0, 1)

    if m.channeling {
        c := block_center(m.target)
        frac := clamp(m.progress / m.need, 0, 1)
        // Bits of the block flake off toward you as it unravels.
        m.chip_timer -= dt
        if m.chip_timer <= 0 {
            m.chip_timer = 0.07
            toward := la.normalize0(gs.camera.pos - c)
            add_goo(&gs.fx, {pos = c + rand_dir() * 0.5, vel = toward * rand.float32_range(2, 5) + rand_dir() * 1.5 + {0, 2, 0},
                life = 0.5, max = 0.5, size = rand.float32_range(0.08, 0.16), color = block_color(m.block) * 1.4, floor = c.y - 3})
        }
        m.hum_timer -= dt
        if m.hum_timer <= 0 {
            m.hum_timer = 0.24
            play_at(.Magic_Channel, c, 0.22 + 0.2 * frac, 0.85 + 0.5 * frac, 10)
        }
    } else {
        m.hum_timer = 0
    }

    for &s in m.sparks {
        if s.life <= 0 { continue }
        s.life -= dt
        s.pos += s.vel * dt
        s.vel *= 1 - min(1, dt * 3)
    }

    // Motes: thrown out, then drawn in ever faster.
    m.pickup_gap += dt
    for &mo in m.motes {
        if mo.size == 0 { continue }
        mo.age += dt
        if mo.age < 0 { continue }
        eye := gs.camera.pos
        if mo.home > 0 {
            o := &gs.net.others[mo.home - 1]
            if !o.active { mo.size = 0; continue } // gone: so are its motes
            eye = o.pos
        }
        to := eye - {0, PLAYER_EYE_HEIGHT * 0.45, 0} - mo.pos
        d := la.length(to)
        if mo.age > 0.25 {
            k := mo.age - 0.25
            want := to / max(d, 0.001) * (6 + 60 * k)
            mo.vel += (want - mo.vel) * min(1, dt * (3 + 12 * k))
        } else {
            mo.vel *= 1 - min(1, dt * 4)
        }
        step := mo.vel * dt
        if d < 1.2 || (mo.age > 0.25 && la.length(step) >= d) || mo.age > 6 {
            mote_arrive(gs, &mo)
            continue
        }
        mo.pos += step
    }
}

@(private="file")
mote_arrive :: proc(gs: ^Game_State, mo: ^Mote) {
    m := &gs.magic
    if mo.count > 0 && mo.home == 0 {
        magic_collect(gs, mo.block, mo.count)
        if m.pickup_gap > 0.035 {
            m.pickup_run = m.pickup_gap < 0.4 ? min(m.pickup_run + 1, 14) : 0
            play(.Pickup, 0.3, 1 + f32(m.pickup_run) * 0.045)
            m.pickup_gap = 0
        }
    }
    mo.size = 0
}

// ─── Drawing ───────────────────────────────────────────────────────────────

// The wand's tip, in first person (world), and the arm holding it.
@(private="file")
wand_pose :: proc(gs: ^Game_State) -> (shoulder, elbow, wrist, tip: [3]f32, rot: Basis) {
    m := &gs.magic
    cam := gs.camera
    fwd, right, up := camera_view_basis(cam, 1)
    right, up = la.normalize(right), la.normalize(up)
    eye := camera_view_eye(cam)
    r := 1 - (1 - m.raise) * (1 - m.raise)
    // Design metres about the eye (drawn world_scale times as big).
    shoulder = eye + right * 0.22 - up * 0.3 - fwd * 0.05
    hand := eye + right * 0.24 - up * 0.27 + fwd * 0.34 - up * (1 - r) * 0.4
    if m.channeling {
        w := m.t * 31
        hand += (right * math.sin(w) + up * math.cos(w * 1.3)) * 0.004 * (1 + m.progress / max(m.need, 0.01))
    }
    pole := right * 0.7 - up - fwd * 0.2
    elbow, wrist = two_bone_ik(shoulder, hand, pole, UPPER_ARM_LEN, FOREARM_LEN)
    // The wand rises from the corner of the view toward the middle.
    aim := la.normalize(fwd - right * 0.45 + up * 0.75)
    x := la.normalize(la.cross(up, aim))
    rot = basis_from_axes(x, la.cross(aim, x), aim)
    tip = wrist + aim * 0.27
    // To world: about the eye, scaled.
    world :: proc(eye, p: [3]f32) -> [3]f32 { return eye + (p - eye) * world_scale }
    tip = world(eye, tip)
    return
}

magic_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    m := &gs.magic
    first := !gs.camera.climbing && !gs.glider.deployed && gs.glider.chase_dist <= 1.5 && !gs.combat.sword
    tip: [3]f32
    if first && m.raise > 0.01 && ent_begin(f) {
        eye := camera_view_eye(gs.camera)
        shoulder, elbow, wrist, t, rot := wand_pose(gs)
        tip = t
        ent_scale_about(f, eye, world_scale)
        pole := la.normalize(elbow - shoulder)
        ent_segment(f, .Arm_Upper, shoulder, elbow, pole, PLAYER_TINT)
        ent_segment(f, .Arm_Fore, elbow, wrist, pole, PLAYER_TINT)
        aim := [3]f32{rot[0, 2], rot[1, 2], rot[2, 2]}
        ent_part(f, .Fist, wrist, rot)
        ent_part(f, .Rod, wrist - aim * 0.04, rot, {0.5, 0.5, 0.31})
        ent_end(f)
    }

    if !ent_begin(f, false) { return }
    // The beam, from the wand's tip to the block: sparks flowing in (toward
    // you while unweaving, out while conjuring), weaving about the line.
    beam := first && m.raise > 0.5 && (m.channeling || m.conjure > 0)
    if beam {
        c := m.channeling ? block_center(m.target) : m.conjure_at
        frac := m.channeling ? clamp(m.progress / m.need, 0, 1) : 1
        d := c - tip
        l := la.length(d)
        dir := d / max(l, 0.001)
        s1 := la.normalize0(la.cross(dir, [3]f32{0, 1, 0}))
        if s1 == 0 { s1 = {1, 0, 0} }
        s2 := la.cross(dir, s1)
        n := clamp(int(l * 2.2), 6, 30)
        flow := m.channeling ? -m.t * 1.4 : m.t * 3
        for i in 0 ..< n {
            u := (f32(i) + 0.5) / f32(n) + flow
            u -= math.floor(u)
            bulge := math.sin(u * math.PI)
            p := tip + d * u + (s1 * math.sin(m.t * 9 + u * 13) + s2 * math.cos(m.t * 7 + u * 10)) * bulge * (0.25 + 0.2 * frac)
            k := (0.3 + 0.35 * bulge) * clamp(la.length(p - tip) / 3 + 0.25, 0.25, 1) // small by the wand, where they're near the eye
            ent_part(f, .Spark, p, IDENTITY, {k, k, k}, MAGIC_TINT * (0.5 + 0.5 * bulge))
        }
        // An orb at the tip.
        for j in 0 ..< 3 {
            a := m.t * 8 + f32(j) * math.TAU / 3
            p := tip + (s1 * math.cos(a) + s2 * math.sin(a)) * 0.05
            ent_part(f, .Spark, p, IDENTITY, {0.12, 0.12, 0.12}, MAGIC_TINT * 0.9)
        }
        // Round the block, a ring closing in and quickening as it comes undone.
        if m.channeling {
            ring := m.tree_logs > 0 ? f32(1.6) : 0.85
            k := 4 + int(frac * 10)
            tint := la.lerp(MAGIC_TINT, mote_tint(m.block), frac)
            for j in 0 ..< k {
                a := m.t * (2 + 7 * frac) + f32(j) * math.TAU / f32(k)
                r := ring * (1 - 0.35 * frac)
                p := c + {math.cos(a) * r, math.sin(m.t * 3 + f32(j)) * 0.35, math.sin(a) * r}
                ent_part(f, .Spark, p, IDENTITY, {0.6, 0.6, 0.6}, tint)
            }
        }
    }
    for s in m.sparks {
        if s.life <= 0 { continue }
        k := 0.6 * math.sqrt(s.life / s.max)
        ent_part(f, .Spark, s.pos, IDENTITY, {k, k, k}, s.tint)
    }
    chest := gs.camera.pos - {0, PLAYER_EYE_HEIGHT * 0.45, 0}
    for mo in m.motes {
        if mo.size == 0 || mo.age < 0 { continue }
        // Smaller as they reach you, so none fills the view going by.
        near := clamp(la.length(chest - mo.pos) / 4, 0.35, 1)
        k := mo.size * near * (0.85 + 0.15 * math.sin(m.t * 14 + mo.pos.x))
        ent_part(f, .Spark, mo.pos, IDENTITY, {k, k, k}, mo.tint)
    }
    ent_end(f)
}
