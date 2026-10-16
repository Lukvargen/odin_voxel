package main

import "core:math"
import la "core:math/linalg"

// Melee with a sword, Cube World style: fast combos, a dodge roll, and hits
// that feel heavy. R draws and sheathes it (1-9 or the wheel go back to
// building); while it's out:
//
// - Left click: a three hit combo on the ground (slash, backhand slash,
//   overhead finisher); click per swing or hold. A click during a swing is
//   remembered and the next starts as soon as this one has struck and
//   followed through a little. After the finisher, a short breath
//   (COMBO_COOLDOWN) before the next combo. In the air: up to AIR_ATTACKS_MAX alternating air slashes,
//   each hit holding you up a little (juggling a slime), then you come down.
//   Looking down steeply from high enough: a plunge, slamming down with a
//   shockwave, or bouncing off a slime hit on the way down.
// - Right click: a rising slash that launches what it hits, and you with it
//   (once per jump).
// - Shift: a dodge roll the way you're moving (backwards standing still),
//   briefly untouchable; cancels a swing; once per jump in the air.
// - F (hold): guard. Hits from in front land as a fraction of themselves
//   with little knockback; raised just before a hit lands (PARRY_WINDOW) it
//   is a parry: nothing gets through and the attacker is left reeling. You
//   move slowly and can't swing while guarding.
//
// A hit stops the sword in what it hit for a few hundredths of a second
// while the slime shudders in place (hit stop), and the rest of the world
// carries on, so it reads as weight, not lag; kills and heavy hits also slow
// the world a moment, easing back (combat_dt). Hits shake
// the view, knock slimes about, flash and squash them, splatter goo and pop a
// damage number. Every hit adds to a counter that raises damage, as does
// hitting while moving fast.
//
// The sword is drawn as voxel-model parts (combat_add_parts, and in the
// chase view on the body: player_add_parts). Swings are arcs in view space:
// the blade sweeps around a pivot in front of the chest from one angle to
// another, and the hand holds its grip.

SLOWMO_SCALE       :: f32(0.3) // the world's speed at the start of a slow-down...
SLOWMO_HEAVY       :: f32(0.14) // ...lasting this long after a heavy hit...
SLOWMO_KILL        :: f32(0.22) // ...or a kill

PLAYER_MAX_HP      :: f32(100)
REGEN_DELAY        :: f32(4)    // seconds after being hurt before health comes back...
REGEN_RATE         :: f32(10)   // ...at this many points a second
HURT_INVULN        :: f32(0.5)

COMBO_TIMEOUT      :: f32(2.5)  // the counter resets this long after the last hit
COMBO_DAMAGE_STEP  :: f32(0.02) // damage bonus per hit in the counter...
COMBO_DAMAGE_MAX   :: f32(1.0)  // ...up to double at 50
SPEED_DAMAGE_FROM  := f32(5.0 * SPRINT_FACTOR) // = WALK_SPEED * SPRINT_FACTOR (world_scale_apply) // horizontal speed where the speed bonus starts...
SPEED_DAMAGE_MAX   :: f32(0.6)  // ...reaching this at twice that
CHAIN_WINDOW       :: f32(0.35) // after a swing ends, a press this soon still continues the chain

LUNGE_SPEED        : f32 = f32(6)    // voxels/s toward the slime in front when a ground swing starts...
LUNGE_RANGE        : f32 = f32(5)    // ...if one is this close...
LUNGE_STOP         : f32 = f32(1.3)  // ...to end up about this far from its side
AIR_HIT_HOVER      : f32 = f32(3.5)  // a hit in the air: upward speed, at least
AIR_ATTACKS_MAX    :: 3         // air slashes per jump: then you have to come down
COMBO_COOLDOWN     :: f32(0.15) // a breath after a finisher or an air string (clicks wait it out)
RISE_SPEED         : f32 = f32(13)   // the rising slash takes you up with what it launches

PLUNGE_MIN_PITCH   :: f32(-40)  // degrees: looking down further than this...
PLUNGE_MIN_HEIGHT  : f32 = f32(2.5)  // ...this high up, an air attack is a plunge
PLUNGE_SPEED       : f32 = f32(42)
PLUNGE_RADIUS      :: f32(5)    // the landing's shockwave
PLUNGE_BOUNCE      : f32 = f32(14)   // bouncing off a slime hit on the way down

DODGE_SPEED        : f32 = f32(16)   // at least this fast the dodge's way...
DODGE_TIME         :: f32(0.24) // ...for this long
DODGE_INVULN       :: f32(0.32)
DODGE_COOLDOWN     :: f32(0.45)

BLOCK_CHIP         :: f32(0.2)  // share of a blocked hit that gets through...
BLOCK_CHIP_HEAVY   :: f32(0.35) // ...of a heavy one (HEAVY_HIT or more)
HEAVY_HIT          :: f32(20)
BLOCK_KNOCK        :: f32(0.35) // knockback kept when blocked
BLOCK_ARC          :: f32(0.3)  // cos of the half angle in front a guard covers (~73 deg)
BLOCK_SPEED        :: f32(0.5)  // of walking speed, guarding
PARRY_WINDOW       :: f32(0.22) // a guard this fresh parries
PARRY_INVULN       :: f32(0.2)  // a parried blow's follow-up can't land this long

SWING_PIVOT        :: [3]f32{0.06, -0.24, 0.45} // view space: swings circle around it...
SWING_RADIUS       :: f32(0.36) // ...the grip this far out
SWORD_SHOULDER     :: [3]f32{0.3, -0.5, 0.12}  // first person, view space

Attack_Kind :: enum u8 {
    None,
    Slash_1, Slash_2, Finisher,
    Air_Slash_1, Air_Slash_2,
    Rise,
    Plunge, Plunge_Land,
}

// One swing. Times in seconds: winding up, the strike (when it hits),
// following through, then recovering (a chained swing starts in it).
// The blade points along u*cos(a) + v*sin(a) (view space: x right, y up,
// z ahead), a0 to a1 during the strike, the grip on a circle around pivot.
Attack_Info :: struct {
    windup, strike, follow, recover: f32,
    damage:   f32,
    knock:    [2]f32, // away and up, voxels/s
    arc:      f32,    // half angle in front it hits in, radians
    reach:    f32,    // from the eye, voxels
    hitstop:  f32,    // the sword sticks in what it hits this long
    shake:    f32,
    u, v:     [3]f32,
    a0, a1:   f32,
    pivot:    [3]f32, // SWING_PIVOT if zero
    backhand: bool,   // the back of the hand leads
}

DEG :: math.RAD_PER_DEG

ATTACKS := [Attack_Kind]Attack_Info{
    .None = {},
    // Upper right to lower left.
    .Slash_1 = {windup = 0.1, strike = 0.1, follow = 0.13, recover = 0.17, damage = 10, knock = {6, 4}, arc = 75 * DEG, reach = 3.2,
        hitstop = 0.06, shake = 0.35, u = {0, 0.25, 1}, v = {1, 0.4, 0}, a0 = 115 * DEG, a1 = -100 * DEG},
    // Lower left to upper right, backhand.
    .Slash_2 = {windup = 0.09, strike = 0.1, follow = 0.13, recover = 0.17, damage = 12, knock = {6, 4.5}, arc = 75 * DEG, reach = 3.2,
        hitstop = 0.06, shake = 0.35, u = {0, 0.25, 1}, v = {-1, -0.3, 0}, a0 = 105 * DEG, a1 = -110 * DEG, backhand = true},
    // Overhead, straight down.
    .Finisher = {windup = 0.18, strike = 0.11, follow = 0.18, recover = 0.26, damage = 26, knock = {15, 7}, arc = 45 * DEG, reach = 3.5,
        hitstop = 0.1, shake = 0.9, u = {0, 0, 1}, v = {0.3, 1, 0}, a0 = 110 * DEG, a1 = -75 * DEG, pivot = {0.16, -0.14, 0.55}},
    .Air_Slash_1 = {windup = 0.07, strike = 0.09, follow = 0.1, recover = 0.13, damage = 9, knock = {3, 8}, arc = 75 * DEG, reach = 3.3,
        hitstop = 0.05, shake = 0.3, u = {0, 0.2, 1}, v = {1, 0.15, 0}, a0 = 110 * DEG, a1 = -100 * DEG},
    .Air_Slash_2 = {windup = 0.07, strike = 0.09, follow = 0.1, recover = 0.13, damage = 9, knock = {3, 8}, arc = 75 * DEG, reach = 3.3,
        hitstop = 0.05, shake = 0.3, u = {0, 0.2, 1}, v = {-1, 0.1, 0}, a0 = 105 * DEG, a1 = -105 * DEG, backhand = true},
    // From low in front up over the head.
    .Rise = {windup = 0.1, strike = 0.1, follow = 0.14, recover = 0.18, damage = 14, knock = {2, 15}, arc = 50 * DEG, reach = 3.3,
        hitstop = 0.08, shake = 0.7, u = {0, 0, 1}, v = {-0.15, -1, 0}, a0 = 75 * DEG, a1 = -110 * DEG, pivot = {0.08, -0.2, 0.5}, backhand = true},
    // Held point down until landing or hitting something: the strike is the fall.
    .Plunge = {windup = 0.06, strike = 10, damage = 30, knock = {8, 10}, arc = math.PI, hitstop = 0.1, shake = 1,
        u = {0, 0, 1}, v = {0, -1, 0}, a0 = 55 * DEG, a1 = 70 * DEG},
    // The landing's shockwave.
    .Plunge_Land = {strike = 0.02, follow = 0.1, recover = 0.18, damage = 20, knock = {13, 9}, arc = math.PI, reach = PLUNGE_RADIUS,
        hitstop = 0.11, shake = 1.2, u = {0, 0, 1}, v = {0, -1, 0}, a0 = 70 * DEG, a1 = 75 * DEG},
}

// Where the sword is, in view space: the middle of the grip, which way the
// blade points, and which way the back of the hand holding it faces.
Sword_Pose :: struct { grip, blade, back: [3]f32 }

Combat_Input :: struct {
    attack, attack_held, special, dodge: bool,
    block: bool, // held
    move: [2]f32, // x right, y forward: the dodge's direction
}

Combat :: struct {
    sword:       bool, // drawn (R)
    hp:          f32,
    since_hurt:  f32,
    invuln:      f32,
    hurt_flash:  f32, // 1 when hurt, fading

    attack:      Attack_Kind,
    attack_time: f32,
    attack_id:   u32, // each swing hits each slime once
    attack_hit:  bool,
    queued:      Attack_Kind, // pressed during a swing: starts after it
    chain:       Attack_Kind, // the last swing of the chain...
    chain_timer: f32,         // ...continued if the next comes this soon
    rise_used:   bool,        // in this jump
    air_attacks: int,         // air slashes in this jump
    cooldown:    f32,         // no new swing until this runs out
    swing_from:  Sword_Pose,  // where the hand was when the swing started
    pose:        Sword_Pose,  // this frame's
    sway:        [3]f32,      // the hand lagging behind turns and bouncing on landings (view space)...
    sway_vel:    [3]f32,      // ...on a loose spring
    last_look:   [2]f32,      // yaw, pitch last frame
    last_vy:     f32,
    time:        f32,

    blocking:    bool,
    block_time:  f32, // since the guard went up
    guard:       f32, // 0..1, the sword easing into the guard pose

    dodge_time:     f32, // since the dodge started
    dodge_dir:      [3]f32,
    dodge_cooldown: f32,
    air_dodge_used: bool,

    combo:       int,
    combo_timer: f32,
    combo_pop:   f32, // 1 on a hit, fading: the counter bumps
    best_combo:  int,
    kills:       int,

    hitstop:     f32, // the swing stays stuck in what it hit this much longer
    slowmo:      f32, // the world is slowed this much longer...
    slowmo_len:  f32, // ...of a slow-down this long
}

combat_init :: proc(c: ^Combat) {
    c^ = {hp = PLAYER_MAX_HP, dodge_time = 10, pose = sword_carry(0, 0, 0)}
}

combat_toggle_sword :: proc(gs: ^Game_State) {
    c := &gs.combat
    c.sword = !c.sword
    c.attack, c.queued = .None, .None
    // No toast: the sword in your hand (and the hotbar going away) says it.
    play(.Sword_Draw, c.sword ? 0.7 : 0.5, (c.sword ? 1 : 0.8) * vary(0.05))
}

// The world's dt this frame: slowed for a moment after a kill or a heavy
// hit, easing back to full speed. Never stopped: a full stop with the view
// still turning reads as the game hitching.
combat_fx_dt :: proc(gs: ^Game_State, dt: f32) -> f32 {
    c := &gs.combat
    c.hitstop = max(c.hitstop - dt, 0)
    if c.slowmo <= 0 { return dt }
    c.slowmo = max(c.slowmo - dt, 0)
    k := math.smoothstep(f32(0), 1, c.slowmo / c.slowmo_len)
    return dt * math.lerp(f32(1), SLOWMO_SCALE, k)
}

@(private="file")
slow_down :: proc(c: ^Combat, length: f32) {
    if length > c.slowmo { c.slowmo, c.slowmo_len = length, length }
}

combat_dodging :: proc(c: ^Combat) -> bool { return c.dodge_time < DODGE_TIME }

attack_duration :: proc(kind: Attack_Kind) -> f32 {
    a := ATTACKS[kind]
    return a.windup + a.strike + a.follow + a.recover
}

@(private="file")
chain_point :: proc(kind: Attack_Kind) -> f32 {
    a := ATTACKS[kind]
    return a.windup + a.strike + a.follow * 0.6
}

@(private="file")
grounded :: proc(gs: ^Game_State) -> bool { return gs.camera.on_ground || gs.camera.fly_mode }

// Before the movement: starts swings and dodges, and pushes the player for them.
combat_pre_update :: proc(gs: ^Game_State, in_: Combat_Input, dt: f32) {
    c := &gs.combat
    cam := &gs.camera
    if grounded(gs) {
        c.air_dodge_used = false
        c.rise_used = false
        c.air_attacks = 0
    }
    if dt <= 0 { return }
    c.dodge_cooldown = max(c.dodge_cooldown - dt, 0)
    c.cooldown = max(c.cooldown - dt, 0)
    c.chain_timer = max(c.chain_timer - dt, 0)
    if !c.sword || gs.glider.deployed { c.attack, c.blocking = .None, false; return }

    // Dodge: cancels the swing.
    if in_.dodge && c.dodge_cooldown == 0 && (grounded(gs) || !c.air_dodge_used) {
        fwd, right := camera_flat_forward(cam^), camera_flat_right(cam^)
        dir := la.normalize0(fwd * in_.move.y + right * in_.move.x)
        if dir == 0 { dir = -fwd }
        c.dodge_dir = dir
        c.dodge_time = 0
        c.dodge_cooldown = DODGE_COOLDOWN
        c.invuln = max(c.invuln, DODGE_INVULN)
        if !grounded(gs) {
            c.air_dodge_used = true
            cam.velocity.y = max(cam.velocity.y, 3) // a little lift, so it carries
        }
        if c.attack != .Plunge { c.attack, c.queued = .None, .None }
        play(.Dodge, 0.6, vary(0.08))
    }
    if combat_dodging(c) {
        // At least the dodge's speed its way, easing off at the end; speed
        // beyond that and sideways is kept, so it never slows you down.
        t := c.dodge_time / DODGE_TIME
        target := DODGE_SPEED * (1 - t * t * 0.5)
        along := cam.velocity.x * c.dodge_dir.x + cam.velocity.z * c.dodge_dir.z
        if along < target {
            cam.velocity.x += c.dodge_dir.x * (target - along)
            cam.velocity.z += c.dodge_dir.z * (target - along)
        }
    }
    c.dodge_time = min(c.dodge_time + dt, 10)

    // Guard: up when asked for, unless mid-swing past the wind-up (it comes
    // up as soon as the swing is done) or rolling.
    if in_.block && !combat_dodging(c) {
        can := c.attack == .None || (c.attack != .Plunge && c.attack_time < ATTACKS[c.attack].windup)
        if !c.blocking && can {
            c.blocking, c.block_time = true, 0
            c.attack, c.queued = .None, .None
        }
    } else {
        c.blocking = false
    }
    if c.blocking {
        c.block_time += dt
        // Slow, braced steps.
        if grounded(gs) {
            limit := WALK_SPEED * BLOCK_SPEED
            if sp := la.length(cam.velocity.xz); sp > limit { cam.velocity.xz *= limit / sp }
        }
        return
    }

    // Queue or start swings, on a click or while held. No click is lost: one
    // made during a swing (or the breath after a combo) is remembered and the
    // swing starts the moment it can.
    want := Attack_Kind.None
    if in_.special && !(c.rise_used && !grounded(gs)) {
        want = .Rise
    } else if in_.attack || in_.attack_held {
        want = next_in_chain(gs)
    }
    busy := c.attack == .Plunge || c.attack == .Plunge_Land
    if want != .None && !busy {
        if (c.attack == .None || c.attack_time >= chain_point(c.attack)) && c.cooldown == 0 {
            start_attack(gs, want)
        } else if c.queued == .None || in_.special {
            c.queued = want
        }
    }
    if c.attack == .None && c.queued != .None && c.cooldown == 0 {
        start_attack(gs, c.queued)
    }

    // Plunging: a hang at the top, then straight down, fast.
    if c.attack == .Plunge {
        if c.attack_time >= ATTACKS[.Plunge].windup {
            cam.velocity.y = min(cam.velocity.y, -PLUNGE_SPEED)
            cam.velocity.xz *= math.exp(-2 * dt)
        } else {
            cam.velocity.y = max(cam.velocity.y, 0)
        }
    }
}

// After the movement: health, then advance the swing, hit what it reaches,
// land plunges.
combat_post_update :: proc(gs: ^Game_State, dt: f32) {
    c := &gs.combat
    cam := &gs.camera
    if dt <= 0 { return }
    c.invuln = max(c.invuln - dt, 0)
    c.since_hurt += dt
    if c.since_hurt > REGEN_DELAY { c.hp = min(c.hp + REGEN_RATE * dt, PLAYER_MAX_HP) }
    c.combo_timer = max(c.combo_timer - dt, 0)
    if c.combo_timer == 0 { c.combo = 0 }
    if c.attack == .None { return }

    // Stuck in what it hit: the swing waits (a plunge keeps falling).
    step := c.hitstop > 0 && c.attack != .Plunge ? 0 : dt
    c.attack_time += step
    a := ATTACKS[c.attack]

    #partial switch c.attack {
    case .Plunge:
        if c.attack_time < a.windup { break }
        // Bounce off something below.
        feet := cam.pos - {0, PLAYER_EYE_HEIGHT, 0}
        for t in combat_targets(gs) {
            if t.hit_id^ == c.attack_id { continue }
            d := t.center - (feet + {0, 0.3 * world_scale, 0})
            if la.length(d.xz) < t.radius + PLAYER_HALF_W + 0.4 * world_scale && d.y > -t.radius - 1.6 * world_scale && d.y < t.radius + 0.8 * world_scale {
                hit_target(gs, t, .Plunge)
                cam.velocity.y = PLUNGE_BOUNCE
                cam.on_ground = false
                c.attack, c.chain = .None, .None
                c.rise_used, c.air_dodge_used = false, false
                return
            }
        }
        if grounded(gs) || c.attack_time > 4 {
            start_attack(gs, .Plunge_Land)
            fx_shockwave(&gs.fx, feet)
            play(.Slam, 1, vary(0.06))
            for t in combat_targets(gs) {
                if la.length(t.center - feet) < ATTACKS[.Plunge_Land].reach + t.radius { hit_target(gs, t, .Plunge_Land) }
            }
            slow_down(c, SLOWMO_HEAVY)
            gs.glider.shake = min(gs.glider.shake + ATTACKS[.Plunge_Land].shake, 1.5)
        }
        return
    case .Plunge_Land:
    case:
        if c.attack_time >= a.windup && c.attack_time - step < a.windup + a.strike {
            if c.attack_time - step < a.windup { play(.Sword_Swing, 0.8, (c.attack == .Finisher ? 0.85 : 1) * vary(0.06)) }
            eye := cam.pos
            fwd := camera_flat_forward(cam^)
            for t in combat_targets(gs) {
                if t.hit_id^ == c.attack_id { continue }
                if sword_reaches(t.center, t.radius, eye, fwd, cam.pitch * DEG, a) { hit_target(gs, t, c.attack) }
            }
        }
    }

    if c.attack_time >= chain_point(c.attack) && c.queued != .None && c.attack != .Finisher && c.cooldown == 0 {
        start_attack(gs, c.queued)
    } else if c.attack_time >= attack_duration(c.attack) {
        // The end of a string: a breath before the next.
        if c.attack == .Finisher || (c.attack == .Air_Slash_2 || c.air_attacks >= AIR_ATTACKS_MAX) && !grounded(gs) {
            c.cooldown = COMBO_COOLDOWN
        }
        c.attack = .None // a queued swing starts after the breath (combat_pre_update)
        c.chain_timer = CHAIN_WINDOW
    }
}

@(private="file")
next_in_chain :: proc(gs: ^Game_State) -> Attack_Kind {
    c := &gs.combat
    last := c.attack != .None ? c.attack : (c.chain_timer > 0 ? c.chain : .None)
    if !grounded(gs) {
        if gs.camera.pitch < PLUNGE_MIN_PITCH && height_above_ground(gs) > PLUNGE_MIN_HEIGHT { return .Plunge }
        if c.air_attacks >= AIR_ATTACKS_MAX { return .None } // land first
        return last == .Air_Slash_1 ? .Air_Slash_2 : .Air_Slash_1
    }
    #partial switch last {
    case .Slash_1: return .Slash_2
    case .Slash_2: return .Finisher
    }
    return .Slash_1
}

@(private="file")
start_attack :: proc(gs: ^Game_State, kind: Attack_Kind) {
    c := &gs.combat
    c.attack = kind
    c.attack_time = 0
    c.attack_id += 1
    c.attack_hit = false
    c.queued = .None
    c.chain = kind
    c.swing_from = c.pose
    if kind == .Rise && !grounded(gs) { c.rise_used = true }
    if kind == .Air_Slash_1 || kind == .Air_Slash_2 { c.air_attacks += 1 }
    #partial switch kind {
    case .Slash_1, .Slash_2, .Finisher, .Rise:
        lunge(gs)
    }
}

@(private="file")
height_above_ground :: proc(gs: ^Game_State) -> f32 {
    feet := gs.camera.pos - {0, PLAYER_EYE_HEIGHT - 0.05, 0}
    hit, _, ok := raycast_voxel(gs, feet, {0, -1, 0}, 60 * world_scale)
    if !ok { return 60 * world_scale }
    return feet.y - f32(hit.y + 1)
}

// A ground swing starting with something just ahead steps toward it,
// stopping short of it.
@(private="file")
lunge :: proc(gs: ^Game_State) {
    cam := &gs.camera
    if !cam.on_ground { return }
    fwd := camera_flat_forward(cam^)
    best := LUNGE_RANGE
    dir: [3]f32
    for t in combat_targets(gs) {
        d := t.center - cam.pos
        d.y = 0
        dist := la.length(d) - t.radius
        if dist < best && la.dot(la.normalize0(d), fwd) > 0.75 { best, dir = dist, la.normalize0(d) }
    }
    want := min((best - LUNGE_STOP) * 6, LUNGE_SPEED)
    if dir != 0 && want > 0 {
        along := cam.velocity.x * dir.x + cam.velocity.z * dir.z
        add := max(want - along, 0)
        cam.velocity.x += dir.x * add
        cam.velocity.z += dir.z * add
    }
}

// Close enough, within the arc ahead, and not far above or below the view.
@(private="file")
sword_reaches :: proc(c: [3]f32, r: f32, eye, fwd: [3]f32, pitch: f32, a: Attack_Info) -> bool {
    d := c - eye
    dist := la.length(d)
    if dist - r > a.reach { return false }
    if dist < r + 0.6 * world_scale { return true }
    flat := la.length(d.xz)
    widen := math.atan2(r, max(flat, 0.01)) // its width widens the angle it's hit in
    if flat > 0.01 && (d.x * fwd.x + d.z * fwd.z) / flat < math.cos(min(a.arc + widen, math.PI)) { return false }
    return abs(math.atan2(d.y, flat) - pitch) < 65 * DEG + widen
}

// How hard a swing of `kind` lands on something centred at `at`: damage
// with the combo and speed bonuses, and the knock away from the player.
@(private="file")
hit_amount :: proc(gs: ^Game_State, kind: Attack_Kind, at: [3]f32) -> (damage: f32, knock: [3]f32, boosted: bool) {
    c := &gs.combat
    cam := &gs.camera
    a := ATTACKS[kind]
    speed := la.length(cam.velocity.xz)
    speed_bonus := clamp((speed - SPEED_DAMAGE_FROM) / SPEED_DAMAGE_FROM, 0, 1) * SPEED_DAMAGE_MAX
    combo_bonus := min(f32(c.combo) * COMBO_DAMAGE_STEP, COMBO_DAMAGE_MAX)
    damage = a.damage * (1 + combo_bonus + speed_bonus)

    away := at - cam.pos
    away.y = 0
    away = la.normalize0(away)
    if away == 0 { away = camera_flat_forward(cam^) }
    knock = away * a.knock[0] + {0, a.knock[1], 0}
    knock.xz += cam.velocity.xz * 0.35 // moving fast carries into the hit
    return damage, knock, speed_bonus > 0.2
}

// What a landed hit does to the swing and the view: combo, hit stop,
// slow-down, shake, and the lift of an air or rising slash.
@(private="file")
hit_feedback :: proc(gs: ^Game_State, kind: Attack_Kind, killed: bool) {
    c := &gs.combat
    cam := &gs.camera
    a := ATTACKS[kind]
    c.combo += 1
    c.best_combo = max(c.best_combo, c.combo)
    c.combo_timer = COMBO_TIMEOUT
    c.combo_pop = 1
    c.hitstop = max(c.hitstop, a.hitstop)
    if killed {
        slow_down(c, SLOWMO_KILL)
    } else if a.hitstop >= 0.08 {
        slow_down(c, SLOWMO_HEAVY)
    }
    gs.glider.shake = min(gs.glider.shake + a.shake + (killed ? 0.3 : 0), 1.5)
    if killed { c.kills += 1 }

    if !c.attack_hit {
        c.attack_hit = true
        #partial switch kind {
        case .Air_Slash_1, .Air_Slash_2:
            cam.velocity.y = max(cam.velocity.y, AIR_HIT_HOVER)
        case .Rise:
            cam.velocity.y = max(cam.velocity.y, cam.on_ground ? RISE_SPEED : RISE_SPEED * 0.7)
            cam.on_ground = false
            c.rise_used = true
        }
    }
}

// Anything a swing can hit: where it is, how big, which swing last hit it
// (each swing hits each target once), and what it is. A new kind of
// target is added in combat_targets and hit_target.
Target :: struct {
    center: [3]f32,
    radius: f32,
    hit_id: ^u32,
    index:  int, // in its list
    slime:  ^Slime,
    enemy:  ^Enemy,
}

// This moment's targets (temp allocator).
@(private="file")
combat_targets :: proc(gs: ^Game_State) -> []Target {
    out := make([dynamic]Target, 0, MAX_SLIMES + MAX_ENEMIES, context.temp_allocator)
    for &sl, i in gs.slimes.list {
        if sl.alive { append(&out, Target{center = slime_center(&sl), radius = slime_radius(sl.size), hit_id = &sl.hit_id, index = i, slime = &sl}) }
    }
    for &en, i in gs.enemies.list {
        if en.alive && en.state != .Dead { append(&out, Target{center = enemy_center(&en), radius = enemy_hit_radius(&en), hit_id = &en.hit_id, index = i, enemy = &en}) }
    }
    return out[:]
}

@(private="file")
hit_target :: proc(gs: ^Game_State, t: Target, kind: Attack_Kind) {
    t.hit_id^ = gs.combat.attack_id
    damage, knock, boosted := hit_amount(gs, kind, t.center)
    // The server deals the blow (server_hit); whether it kills, this client
    // judges for itself, since the swing's feel can't wait for the answer.
    msg := Msg_Hit{damage = damage, knock = knock, boosted = boosted, index = u16(t.index)}
    killed: bool
    if t.slime != nil {
        msg.target, msg.uid = .Slime, t.slime.uid
        killed = t.slime.hp - damage <= 0
    } else {
        msg.target, msg.uid = .Enemy, t.enemy.uid
        killed = t.enemy.hp - damage <= 0
    }
    if !killed { msg.freeze = ATTACKS[kind].hitstop + 0.02 } // shudders on the blade, then flies
    client_send(gs, .Hit, msg)
    hit_feedback(gs, kind, killed)
}

Hurt_Result :: enum u8 { Missed, Hit, Blocked, Parried }

// The local player takes a blow the simulation found landed (hurt_outcome):
// a parry's clang and flash, a block's chip and shove, or the hurt itself.
combat_take_hurt :: proc(gs: ^Game_State, result: Hurt_Result, damage: f32, knock: [3]f32) {
    c := &gs.combat
    cam := &gs.camera
    contact := cam.pos + camera_flat_forward(cam^) * 0.7 + {0, -0.3, 0}
    switch result {
    case .Missed:
        return
    case .Parried:
        splat(&gs.fx, contact, {1.9, 1.6, 0.9}, -knock, 14, 0.9)
        play(.Clang, 1, 1.25 * vary(0.04))
        slow_down(c, SLOWMO_KILL)
        gs.glider.shake = min(gs.glider.shake + 0.5, 1.5)
        c.invuln = PARRY_INVULN
        return
    case .Blocked:
        chip := damage >= HEAVY_HIT ? BLOCK_CHIP_HEAVY : BLOCK_CHIP
        c.hp = max(c.hp - damage * chip, 1)
        c.since_hurt = 0
        c.invuln = HURT_INVULN * 0.6
        cam.velocity += knock * BLOCK_KNOCK
        splat(&gs.fx, contact, {1.6, 1.3, 0.8}, -knock, 6, 0.6)
        play(.Clang, 0.8, (damage >= HEAVY_HIT ? 0.8 : 1) * vary(0.06))
        gs.glider.shake = min(gs.glider.shake + (damage >= HEAVY_HIT ? 0.6 : 0.3), 1.5)
        return
    case .Hit:
    }
    c.hp -= damage
    c.since_hurt = 0
    c.invuln = HURT_INVULN
    c.hurt_flash = 1
    c.combo = 0
    gs.glider.shake = min(gs.glider.shake + 0.8, 1.5)
    cam.velocity += knock
    if knock.y > 0 { cam.on_ground = false }
    if c.attack == .Plunge { c.attack = .None }
    play(.Hurt, 0.9, vary(0.06))
    if c.hp <= 0 {
        // Knocked out: back on your feet at full health, everything about
        // scattered and calmed down.
        c.hp = PLAYER_MAX_HP
        c.invuln = 2
        client_send(gs, .Scatter, cam.pos)
        ui_toast(gs, "Knocked out! Back on your feet...", 2.5)
    }
}

// Per frame in real time: feedback that keeps fading during hit stop, the
// dodge's dip, and this frame's sword pose. After glider_view_update.
combat_view_update :: proc(gs: ^Game_State, dt: f32) {
    c := &gs.combat
    cam := &gs.camera
    c.hurt_flash = max(c.hurt_flash - 2.5 * dt, 0)
    c.guard += ((c.blocking ? f32(1) : 0) - c.guard) * min(dt * 18, 1)
    c.combo_pop = max(c.combo_pop - 5 * dt, 0)
    if combat_dodging(c) && c.sword {
        t := c.dodge_time / DODGE_TIME
        cam.view_offset.y -= 0.35 * math.sin(t * math.PI) // ducking into the roll
    }
    run := clamp(la.length(cam.velocity.xz) / (WALK_SPEED * SPRINT_FACTOR), 0, 1)
    c.pose = sword_pose(gs, run)

    // The hand isn't welded to the view: it lags behind turning, bobs when
    // landing, breathes standing still. A loose spring, so it overshoots a
    // little and settles.
    if dt > 0 {
        c.time += dt
        yaw_rate := (math.mod(cam.yaw - c.last_look.x + 540, 360) - 180) / dt
        pitch_rate := (cam.pitch - c.last_look.y) / dt
        target := [3]f32{clamp(yaw_rate * 0.0003, -0.07, 0.07), clamp(-pitch_rate * 0.0003, -0.06, 0.06), 0}
        if cam.on_ground && c.last_vy < -4 {
            c.sway_vel.y += clamp(c.last_vy * 0.06, -1.2, 0) // landing
        }
        K :: (6 * 2 * math.PI) * (6 * 2 * math.PI)
        D :: 2 * 0.45 * 6 * 2 * math.PI
        c.sway_vel += ((target - c.sway) * K - c.sway_vel * D) * dt
        c.sway += c.sway_vel * dt
    }
    c.last_look = {cam.yaw, cam.pitch}
    c.last_vy = cam.velocity.y
    breath := (1 - run) * (c.attack == .None ? 1 : 0)
    c.pose.grip += c.sway + [3]f32{0, 0.007 * breath * math.sin(c.time * 1.7), 0}
    c.pose.blade += [3]f32{0.03 * breath * math.sin(c.time * 1.1), 0, 0} - c.sway * 0.8 // the tip lags further
}

// ─── The sword's pose ──────────────────────────────────────────────────────

// Carried in the lower right, the blade up and forward, bobbing with the stride.
@(private="file")
sword_carry :: proc(run, phase, air: f32) -> Sword_Pose {
    p := Sword_Pose{grip = {0.34, -0.4, 0.6}, blade = {0.06, 1, 0.22}, back = {1, -0.2, -0.4}}
    p.grip += {0.02 * math.sin(phase) * run, -0.03 * run * abs(math.cos(phase)) + 0.04 * air, 0}
    p.blade += {0, 0, 0.3 * run}
    return p
}

@(private="file")
swing_at :: proc(a: Attack_Info, angle: f32) -> Sword_Pose {
    u := la.normalize(a.u)
    v := la.normalize(a.v - u * la.dot(a.v, u))
    blade := u * math.cos(angle) + v * math.sin(angle)
    motion := (-u * math.sin(angle) + v * math.cos(angle)) * math.sign(a.a1 - a.a0)
    pivot := a.pivot != 0 ? a.pivot : SWING_PIVOT
    return {grip = pivot + blade * SWING_RADIUS, blade = blade, back = a.backhand ? motion : -motion}
}

@(private="file")
blend_sword :: proc(a, b: Sword_Pose, t: f32) -> Sword_Pose {
    blade := la.normalize0(la.lerp(la.normalize0(a.blade), la.normalize0(b.blade), t))
    if blade == 0 { blade = b.blade }
    return {grip = la.lerp(a.grip, b.grip, t), blade = blade, back = la.lerp(la.normalize0(a.back), la.normalize0(b.back), t)}
}

@(private="file")
// The guard: the blade held level across the body, edge out.
SWORD_GUARD :: Sword_Pose{grip = {0.16, -0.28, 0.5}, blade = {-1, 0.22, 0.12}, back = {0.1, 0.3, 1}}

sword_pose :: proc(gs: ^Game_State, run: f32) -> Sword_Pose {
    c := &gs.combat
    air: f32 = grounded(gs) ? 0 : 1
    carry := sword_carry(run, gs.player_anim.walk_phase, air)
    if c.guard > 0.001 && c.attack == .None {
        g := c.guard * c.guard * (3 - 2 * c.guard)
        return blend_sword(carry, SWORD_GUARD, g)
    }
    if c.attack == .None { return carry }
    a := ATTACKS[c.attack]
    t := c.attack_time
    switch {
    case t < a.windup:
        f := t / a.windup
        return blend_sword(c.swing_from, swing_at(a, a.a0), 1 - (1 - f) * (1 - f))
    case t < a.windup + a.strike:
        f := (t - a.windup) / a.strike // fast out of the wind up, slowing at the end
        return swing_at(a, math.lerp(a.a0, a.a1, 1 - (1 - f) * (1 - f) * (1 - f)))
    }
    follow := min((t - a.windup - a.strike) / max(a.follow, 0.001), 1)
    end := swing_at(a, a.a1 + (a.a1 - a.a0) * 0.06 * (1 - (1 - follow) * (1 - follow)))
    if a.recover <= 0 { return end }
    r := clamp((t - a.windup - a.strike - a.follow) / a.recover, 0, 1)
    return blend_sword(end, carry, r * r * (3 - 2 * r))
}

// The sword in the world for this frame's pose, seen from `eye` with the
// view axes: grip, blade direction, and the axes across it. The hand holds
// it with the wrist toward the shoulder, so edge (the knuckles' way) points
// away from the shoulder and flat is the back of the hand.
sword_world :: proc(gs: ^Game_State, eye, fwd, right, up, shoulder: [3]f32) -> (grip, blade, edge, flat: [3]f32) {
    return sword_place(gs.combat.pose, eye, fwd, right, up, shoulder)
}

// A sword pose (view space) in the world, for a viewpoint at `eye` looking
// along fwd, with the sword arm's shoulder there: the grip, the blade's
// direction, and the hand's edge and flat axes.
sword_place :: proc(p: Sword_Pose, eye, fwd, right, up, shoulder: [3]f32) -> (grip, blade, edge, flat: [3]f32) {
    to_world :: proc(v, fwd, right, up: [3]f32) -> [3]f32 { return right * v.x + up * v.y + fwd * v.z }
    grip = eye + to_world(p.grip, fwd, right, up)
    blade = la.normalize0(to_world(p.blade, fwd, right, up))
    // A fist holds the grip across it: the wrist bends, so the blade never
    // runs along the forearm (which would lay the arm over the grip).
    MIN_WRIST :: 65 * DEG
    arm := la.normalize0(grip - shoulder)
    if cosa := la.dot(blade, arm); cosa > math.cos(f32(MIN_WRIST)) {
        side := la.normalize0(blade - arm * cosa)
        if side == 0 { side = up }
        blade = arm * math.cos(f32(MIN_WRIST)) + side * math.sin(f32(MIN_WRIST))
    }
    out := grip - shoulder
    edge = la.normalize0(out - blade * la.dot(out, blade))
    if edge == 0 { edge = la.normalize0(la.cross(blade, [3]f32{0, 1, 0})) }
    flat = la.cross(blade, edge)
    return
}

UPPER_ARM_LEN :: f32(0.3)
FOREARM_LEN   :: f32(0.29)

// The elbow for reaching from the shoulder toward target, bending toward
// pole, and where the wrist ends up (pulled in if out of reach).
@(private="file")
two_bone_ik :: proc(shoulder, target, pole: [3]f32, upper, lower: f32) -> (elbow, wrist: [3]f32) {
    to := target - shoulder
    dist := clamp(la.length(to), abs(upper - lower) + 0.001, upper + lower - 0.001)
    dir := la.normalize0(to)
    if dir == 0 { dir = {0, -1, 0} }
    wrist = shoulder + dir * dist
    along := (upper * upper - lower * lower + dist * dist) / (2 * dist)
    height := math.sqrt(max(upper * upper - along * along, 0))
    bend := la.normalize0(pole - dir * la.dot(pole, dir))
    elbow = shoulder + dir * along + bend * height
    return
}

// The sword in a fist at the end of an arm from `shoulder`: upper arm and
// forearm meeting at an elbow bent toward `pole`. Out of reach, hand and
// sword come back to where the straight arm ends.
sword_arm_parts :: proc(f: ^Ent_Frame, shoulder, grip, blade, edge, flat, pole: [3]f32, scale: f32 = 1, tint := PLAYER_TINT) {
    wrist := grip - edge * 0.075 * scale - blade * 0.012 * scale
    elbow, w := two_bone_ik(shoulder, wrist, pole, UPPER_ARM_LEN * scale, FOREARM_LEN * scale)
    g := grip + (w - wrist)
    ent_segment(f, .Arm_Upper, shoulder, elbow, pole, tint)
    ent_segment(f, .Arm_Fore, elbow, w, pole, tint)
    rot := basis_from_axes(edge, flat, blade)
    ent_part(f, .Fist, g, rot, {scale, scale, scale})
    ent_part(f, .Sword, g, rot)
}

// The sword and the arm holding it, in first person.
combat_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    c := &gs.combat
    if !c.sword || gs.glider.deployed || gs.glider.chase_dist > 1.5 || !ent_begin(f) { return }
    cam := gs.camera
    fwd, right, up := camera_view_basis(cam, 1)
    right, up = la.normalize(right), la.normalize(up)
    eye := cam.pos + cam.view_offset + [3]f32{0, cam.step_visual_offset, 0}
    ent_scale_about(f, eye, world_scale)
    shoulder := eye + right * SWORD_SHOULDER.x + up * SWORD_SHOULDER.y + fwd * SWORD_SHOULDER.z
    grip, blade, edge, flat := sword_world(gs, eye, fwd, right, up, shoulder)
    // The elbow hangs down and out to the side.
    sword_arm_parts(f, shoulder, grip, blade, edge, flat, right * 0.7 - up - fwd * 0.3)
    ent_end(f)
}

// ─── Models: the sword, the fist holding it, the arm ───────────────────────
// Chunky, Cube World style: one voxel size (HAND_VOXEL, about the creatures'),
// designed voxel by voxel. Model space is in metres; vox() turns a point into
// voxel indices (the bakes put voxel centres on whole multiples).

HAND_VOXEL :: f32(0.05)

@(private="file")
vox :: proc(p: [3]f32) -> [3]int {
    return {int(math.round(p.x / HAND_VOXEL)), int(math.round(p.y / HAND_VOXEL)), int(math.round(p.z / HAND_VOXEL))}
}

// Grip at the origin (where the hand closes), blade along +z, edges along x,
// flats facing y. Pommel with a gem, a wrapped one-voxel grip, a crossguard
// with tips turned up and a gem at its heart, then a blade three voxels wide
// (an edge each side of a darker fuller) narrowing to a point.
shape_sword :: proc(p: [3]f32, voxel: f32) -> Pal {
    v := vox(p)
    x, y, z := abs(v.x), abs(v.y), v.z
    switch {
    case z == -3: // pommel
        if x <= 1 && y <= 1 { return x == 0 ? .Pommel_Gem : .Guard }
    case z >= -2 && z <= 2: // grip, wrapped
        if x == 0 && y == 0 { return z % 2 == 0 ? .Grip_Wrap : .Grip }
    case z == 3: // crossguard
        if x <= 1 && y <= 1 { return x == 0 && y == 1 ? .Pommel_Gem : .Guard }
        if x <= 3 && y == 0 { return x == 3 ? .Guard_Dark : .Guard }
    case z == 4: // the quillons' tips turn up toward the blade
        if x == 3 && y == 0 { return .Guard_Dark }
        if x <= 1 && y == 0 { return .Blade_Fuller }
    case z >= 5 && z <= 16:
        if y != 0 || x > 1 { break }
        if x == 1 { return .Blade_Edge }
        return z <= 13 ? .Blade_Fuller : .Blade
    case z == 17:
        if y == 0 && x == 0 { return .Blade_Edge }
    }
    return .Empty
}

// A gloved hand: a 3x3x3 block the grip passes through, Cube World style.
// In the sword's frame: knuckles toward +x (the edge), wrist toward -x.
shape_fist :: proc(p: [3]f32, voxel: f32) -> Pal {
    v := vox(p)
    if abs(v.x) > 1 || abs(v.y) > 1 || abs(v.z) > 1 { return .Empty }
    if v.x == 1 && v.z >= 0 { return .Glove_Light } // knuckles
    if v.x == -1 && v.z < 0 { return .Glove_Dark }  // under the wrist
    return .Glove
}

// Upper arm along +z, 1 long (scaled to the length): a square sleeve,
// three voxels across.
shape_arm_upper :: proc(p: [3]f32, voxel: f32) -> Pal {
    v := vox({p.x, p.y, 0})
    if abs(v.x) > 1 || abs(v.y) > 1 { return .Empty }
    return .Shirt
}

// Forearm along +z from the elbow, 1 long: the sleeve, a cuff standing out
// a voxel, then the leather gauntlet.
shape_arm_fore :: proc(p: [3]f32, voxel: f32) -> Pal {
    v := vox({p.x, p.y, 0})
    w := max(abs(v.x), abs(v.y))
    cuff := p.z > 0.6 && p.z < 0.72
    if w > (cuff ? 2 : 1) { return .Empty }
    if cuff { return .Glove_Dark }
    return p.z < 0.6 ? .Shirt : .Glove
}
