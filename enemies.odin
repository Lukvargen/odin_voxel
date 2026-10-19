package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import la "core:math/linalg"

// Hostile humanoids, Valheim style: what you meet depends on the land and
// the hour, and ruins and camps hold more of them.
//
//  - Skeletons: the taiga, the snow and the mountains; at night they claw
//    up out of the ground anywhere on land (and crumble at dawn). They guard
//    the old towers, shrines and stone circles.
//  - Goblins: small and quick with a club, in packs on the plains and in
//    the forests. They keep camps (landmarks.odin) with an orc or two.
//  - Orcs: big and slow with an axe, a long tell and a heavy hit; the
//    desert and the badlands.
//
// Each is a box swept through the world like the slimes (stepping up single
// blocks, jumping higher ones), drawn as rigid voxel-model parts on a shared
// humanoid rig (Enemy_Rig). They wander, notice the player, close in, wind
// up a swing (the tell: the weapon goes up), strike, and recover (the
// opening). A hit staggers them; killed, they topple over (skeletons
// collapse into a heap of bones) and sink away.
//
// Guards belong to a site (a landmark): they keep near it, are spawned when
// the player comes close, and the site stays empty for a while once cleared.

MAX_ENEMIES      :: 24
ENEMY_DESPAWN    :: f32(110) // roamers counted within this of a player, and forgotten beyond it (guards: their site's spawn is undone)
ROAM_SPAWN_NEAR  :: f32(40)  // roamers appear between these (design blocks) from a player: out
ROAM_SPAWN_FAR   :: f32(60)  // there, to be come upon, never at your back
ROAM_DAY         :: 2        // roamers kept about a player by day...
ROAM_NIGHT       :: 4        // ...and at night
ROAM_CHECK       :: f32(10)  // seconds between looks for a place to put one
ROAM_GAP_MIN     :: f32(60)  // after one spawns, at least this long before the next...
ROAM_GAP_MAX     :: f32(120) // ...and at most this
ENEMY_GRAVITY    : f32 = f32(26)
ENEMY_JUMP       : f32 = f32(8.5)
SITE_NOTICE      :: f32(80)  // a site's guards appear when the player is this close
SITE_RESPAWN     :: f32(600) // seconds before a cleared site fills again
GUARD_LEASH      :: f32(20)  // guards give up a chase this far from home

Enemy_Kind :: enum u8 { Skeleton, Goblin, Orc }

Enemy_Spec :: struct {
    scale:    f32, // of the rig (1 = the player's size)
    radius:   f32, // collision half width
    height:   f32,
    hp:       f32,
    damage:   f32,
    walk:     f32,
    run:      f32,
    weight:   f32, // knockback is divided by this
    reach:    f32, // from its feet to the player's, horizontally
    windup:   f32, // the tell...
    strike:   f32, // ...the swing (hurts during it)...
    recover:  f32, // ...the opening after it
    aggro:    f32,
    knock:    [2]f32, // away, up
    gore:     [3]f32, // what flies off when hit
}

ENEMY_SPECS := [Enemy_Kind]Enemy_Spec{
    .Skeleton = {scale = 1.12, radius = 0.34, height = 2.0, hp = 45, damage = 13, walk = 1.5, run = 4.2, weight = 1,
                 reach = 2.1, windup = 0.5,  strike = 0.16, recover = 0.55, aggro = 20, knock = {7, 4},
                 gore = {0.82, 0.78, 0.68}},
    .Goblin   = {scale = 0.95, radius = 0.32, height = 1.7, hp = 32, damage = 9,  walk = 2.0, run = 5.2, weight = 0.8,
                 reach = 1.9, windup = 0.38, strike = 0.13, recover = 0.45, aggro = 18, knock = {6, 4},
                 gore = {0.40, 0.08, 0.06}},
    .Orc      = {scale = 1.4,  radius = 0.5,  height = 2.55, hp = 130, damage = 28, walk = 1.4, run = 3.7, weight = 2.6,
                 reach = 2.7, windup = 0.8,  strike = 0.2,  recover = 0.85, aggro = 22, knock = {13, 6},
                 gore = {0.40, 0.08, 0.06}},
}

// Where the parts go, in rig units (scaled by the spec's scale).
Enemy_Rig :: struct {
    head, torso, arm, leg, weapon: Model_Id,
    hips, leg_x, arm_x, arm_y, neck: f32,
    arm_len: f32, // shoulder to the grip
}

ENEMY_RIGS := [Enemy_Kind]Enemy_Rig{
    .Skeleton = {head = .Skel_Skull, torso = .Skel_Torso, arm = .Skel_Arm, leg = .Skel_Leg, weapon = .Old_Sword, hips = 0.78, leg_x = 0.1, arm_x = 0.27, arm_y = 0.54, neck = 0.6, arm_len = 0.52},
    .Goblin   = {head = .Gob_Head, torso = .Gob_Torso, arm = .Gob_Arm, leg = .Gob_Leg, weapon = .Club, hips = 0.74, leg_x = 0.11, arm_x = 0.3, arm_y = 0.48, neck = 0.55, arm_len = 0.5},
    .Orc      = {head = .Orc_Head, torso = .Orc_Torso, arm = .Gob_Arm, leg = .Gob_Leg, weapon = .Axe, hips = 0.74, leg_x = 0.13, arm_x = 0.38, arm_y = 0.52, neck = 0.6, arm_len = 0.5},
}

Enemy_State :: enum u8 { Idle, Wander, Chase, Windup, Strike, Recover, Stagger, Dead }

// Two attacks: an overhead chop (weapon raised high behind the head, brought
// straight down) and a slash (cocked out to the right side, swept across
// the front to the left). Poses of the weapon arm: yaw about the body's up
// axis, pitch about its side axis (0 hanging, pi straight up, -pi/2 straight
// ahead), and the weapon's tilt from the forearm (pi/2: in line with it).
Swing :: enum u8 { Overhead, Slash }

Arm_Key :: struct { yaw, pitch, tilt, twist: f32 } // twist: the torso turning into it

ARM_REST :: Arm_Key{0, 0, 0.55, 0}
SWING_KEYS := [Swing][2]Arm_Key{
    .Overhead = {{0.2, 2.9, 0.35, 0.15}, {0.05, -1.05, 1.1, -0.05}},
    .Slash    = {{1.55, -1.25, 1.4, 0.55}, {-1.25, -1.8, 1.45, -0.45}},
}

// How likely each kind is to chop rather than slash.
OVERHEAD_CHANCE := [Enemy_Kind]f32{.Skeleton = 0.35, .Goblin = 0.55, .Orc = 0.8}

Enemy :: struct {
    alive:      bool,
    kind:       Enemy_Kind,
    state:      Enemy_State,
    pos:        [3]f32, // feet
    vel:        [3]f32,
    yaw:        f32,    // entity convention: faces {-sin, 0, cos}
    on_ground:  bool,
    hp:         f32,
    timer:      f32,
    target:     [3]f32, // wander goal
    tint:       [3]f32, // skin
    hit_id:     u32,
    flash:      f32,
    freeze:     f32,    // stuck on the sword (hit stop)
    bar:        f32,    // health bar shows while > 0
    level:      u8,     // levels.odin: its health and blows scale with it
    age:        f32,
    walk_phase: f32,
    speed:      f32,    // smoothed ground speed (drives the gait)
    struck:     bool,   // this swing already landed
    swing:      Swing,  // which attack this one is
    death:      f32,    // seconds since it died
    rising:     f32,    // 1 while clawing up out of the ground, to 0
    nocturnal:  bool,   // crumbles at dawn
    // Senses and getting about (enemy_path.odin)
    prey:       int,    // the player it watches and goes after (sim.odin)
    uid:        u32,    // which enemy this slot holds (a hit names it: Msg_Hit)
    sees:       bool,   // the player, last time it looked
    see_timer:  f32,    // until it looks again
    last_seen:  [3]f32, // where the player's feet were
    seen_ago:   f32,
    path:       [PATH_MAX][3]i32,
    path_len:   int,
    path_i:     int,
    repath:     f32,
    stuck_t:    f32,
    stuck_pos:  [3]f32,
    // Guards
    home:       [3]f32,
    guard:      bool,
    site:       [2]int,
}

Site :: struct {
    spawned:    bool,
    alive:      int,
    cleared_at: f32, // seconds (audio-free game clock), 0 = never
}

Enemies :: struct {
    list:        [MAX_ENEMIES]Enemy,
    spawn_timer: f32,
    site_timer:  f32,
    time:        f32,
    last_uid:    u32,
    landmarks:   map[[2]int]Landmark, // cell -> its landmark (cached)
    sites:       map[[2]int]Site,
}

enemy_center :: proc(e: ^Enemy) -> [3]f32 {
    return e.pos + {0, ENEMY_SPECS[e.kind].height * 0.55, 0}
}

enemy_hit_radius :: proc(e: ^Enemy) -> f32 {
    sp := ENEMY_SPECS[e.kind]
    return max(sp.radius + 0.15, sp.height * 0.32)
}

enemy_spawn :: proc(sim: ^Sim, kind: Enemy_Kind, pos: [3]f32) -> ^Enemy {
    s := &sim.enemies
    for &e in s.list {
        if e.alive { continue }
        tint := enemy_skin(kind, rand.float32())
        e = {
            alive = true, kind = kind, state = .Idle, pos = pos, home = pos, target = pos,
            yaw = rand.float32_range(0, 2 * math.PI),
            timer = rand.float32_range(0.5, 3), tint = tint, walk_phase = rand.float32_range(0, 6),
        }
        enemy_set_level(&e, monster_level(pos))
        s.last_uid += 1
        e.uid = s.last_uid
        return &e
    }
    return nil
}

// A kind's skin colour, k (0..1) along its range.
enemy_skin :: proc(kind: Enemy_Kind, k: f32) -> [3]f32 {
    switch kind {
    case .Skeleton:
    case .Goblin: return la.lerp([3]f32{0.42, 0.56, 0.26}, [3]f32{0.52, 0.56, 0.30}, k)
    case .Orc:    return la.lerp([3]f32{0.36, 0.44, 0.32}, [3]f32{0.50, 0.46, 0.34}, k)
    }
    return {1, 1, 1}
}

// ─── Update ─────────────────────────────────────────────────────────────────

enemies_update :: proc(sim: ^Sim, dt: f32) {
    s := &sim.enemies
    if dt <= 0 { return }
    s.time += dt
    sim.time += dt
    enemy_paths_frame()
    night := sim.day.night

    // Drop the ones far from every player.
    for &e in s.list {
        if !e.alive { continue }
        _, d := nearest_player(sim, e.pos)
        if d > ENEMY_DESPAWN || e.pos.y < -100 {
            e.alive = false
            if e.guard { site_forget(s, e.site) }
        }
    }

    // Each player on foot keeps a roaming population about them, and wakes
    // the guards of the landmarks they come near.
    if sim.monsters {
        s.spawn_timer -= dt
        s.site_timer -= dt
        spawn, sites := s.spawn_timer <= 0, s.site_timer <= 0
        if spawn { s.spawn_timer = ROAM_CHECK }
        if sites { s.site_timer = 1 }
        for &p in sim.players {
            if !player_hunted(&p) || p.fly_mode { continue }
            feet := player_feet(&p)
            if spawn {
                roaming := 0
                for &e in s.list {
                    if e.alive && !e.guard && la.length((e.pos - feet).xz) < ENEMY_DESPAWN { roaming += 1 }
                }
                if want := ROAM_DAY + int(math.round(f32(ROAM_NIGHT - ROAM_DAY) * night)); roaming < want {
                    if enemy_try_spawn(sim, feet, night) { s.spawn_timer = rand.float32_range(ROAM_GAP_MIN, ROAM_GAP_MAX) }
                }
            }
            if sites { sites_update(sim, feet) }
        }
    }

    steps := max(1, int(math.ceil(dt * 120)))
    h := dt / f32(steps)
    for &e in s.list {
        if !e.alive { continue }
        e.flash = max(e.flash - dt * 7, 0)
        e.bar = max(e.bar - dt, 0)
        if e.freeze > 0 { e.freeze -= dt; continue }
        e.age += dt
        e.timer -= dt
        e.rising = max(e.rising - dt * 0.9, 0)
        enemy_think(sim, &e, dt)
        if !e.alive { continue }
        for _ in 0 ..< steps { enemy_move(sim, &e, h) }
        sp := la.length(e.vel.xz)
        e.speed += (sp - e.speed) * min(dt * 10, 1)
        e.walk_phase += e.speed * dt * 2.6 / ENEMY_SPECS[e.kind].scale
    }

    // Keep apart.
    for i in 0 ..< MAX_ENEMIES {
        a := &s.list[i]
        if !a.alive || a.state == .Dead { continue }
        for j in i + 1 ..< MAX_ENEMIES {
            b := &s.list[j]
            if !b.alive || b.state == .Dead { continue }
            d := (b.pos - a.pos).xz
            l := la.length(d)
            min_d := ENEMY_SPECS[a.kind].radius + ENEMY_SPECS[b.kind].radius + 0.2 * world_scale
            if l < min_d && abs(b.pos.y - a.pos.y) < 1.5 * world_scale {
                n := l > 0.001 ? d / l : [2]f32{1, 0}
                push := (min_d - l) * 20 * dt
                a.vel.xz -= n * push
                b.vel.xz += n * push
            }
        }
    }
}

@(private="file")
enemy_think :: proc(sim: ^Sim, e: ^Enemy, dt: f32) {
    sp := ENEMY_SPECS[e.kind]
    // Unbothered, it keeps an eye on whoever is nearest; once after
    // someone, it sticks with them.
    if e.state == .Idle || e.state == .Wander || !player_hunted(&sim.players[e.prey]) {
        if i, _ := nearest_player(sim, e.pos); i >= 0 { e.prey = i }
    }
    p := &sim.players[e.prey]
    feet := player_feet(p)
    to_player := feet - e.pos
    dist := la.length(to_player.xz)
    dir := dist > 0.01 ? to_player.xz / dist : [2]f32{-math.sin(e.yaw), math.cos(e.yaw)}
    hunting := player_hunted(p) && !p.fly_mode && sim.monsters
    accel: [2]f32 // wanted ground velocity
    want_speed: f32

    // Day breaks: the night's dead crumble unless they're at your throat.
    if e.nocturnal && sim.day.night < 0.15 && e.state != .Dead && (dist > 10 * world_scale || e.state == .Idle || e.state == .Wander) {
        enemy_crumble(sim, e)
        return
    }

    // Look for the player now and then (a ray from the eyes).
    e.see_timer -= dt
    if e.see_timer <= 0 {
        e.see_timer = 0.25
        e.sees = dist < 64 * world_scale && enemy_sees_player(sim, e)
    }
    sight := sp.aggro * (p.sneaking ? 0.55 : 1)
    hear := (p.sneaking ? 1.5 : (p.sprinting ? 8 : 4)) * world_scale

    switch e.state {
    case .Idle, .Wander:
        if e.rising > 0 { break }
        if hunting && abs(to_player.y) < 8 * world_scale && ((e.sees && dist < sight) || dist < hear) {
            e.state, e.timer = .Chase, 0
            e.last_seen, e.seen_ago = feet, 0
            e.repath = 0
            enemy_voice(sim, e, 0.7)
            break
        }
        if e.state == .Idle {
            if e.timer <= 0 {
                // Wander about home (guards) or where it stands.
                a := rand.float32_range(0, 2 * math.PI)
                r := rand.float32_range(2, e.guard ? 7 : 10) * world_scale
                c := e.guard ? e.home : e.pos
                e.target = c + {math.cos(a) * r, 0, math.sin(a) * r}
                e.state, e.timer = .Wander, rand.float32_range(3, 6)
            }
        } else {
            d := (e.target - e.pos).xz
            l := la.length(d)
            if l < 0.6 * world_scale || e.timer <= 0 {
                e.state, e.timer = .Idle, rand.float32_range(1.5, 5)
            } else {
                // Guards heading home find their way round things.
                goal := e.target
                if e.guard && la.length((e.home - e.pos).xz) > 6 * world_scale { goal = enemy_steer(sim, e, e.target, dt) }
                w := la.normalize0((goal - e.pos).xz)
                if w != 0 {
                    turn_towards(&e.yaw, w, dt * 3)
                    want_speed = sp.walk
                    accel = w
                }
            }
        }
    case .Chase:
        // Keep track of where the player is, or was last seen.
        if e.sees || dist < 2.5 * world_scale { e.last_seen, e.seen_ago = feet, 0 } else { e.seen_ago += dt }
        lost := e.seen_ago > 5 || dist > sp.aggro * 1.8 || !hunting || (e.guard && la.length((e.pos - e.home).xz) > GUARD_LEASH * world_scale && dist > 4 * world_scale)
        if lost {
            e.state, e.timer = .Wander, 6
            e.target = e.guard ? e.home : e.last_seen
        } else if dist < sp.reach && abs(to_player.y) < 2 * world_scale && e.on_ground && e.sees {
            turn_towards(&e.yaw, dir, dt * 7)
            e.state, e.timer, e.struck = .Windup, sp.windup, false
            e.swing = rand.float32() < OVERHEAD_CHANCE[e.kind] ? .Overhead : .Slash
            enemy_voice(sim, e, 0.9)
        } else {
            // Where they last saw you, by a path round what's in the way.
            goal := e.sees ? feet : e.last_seen
            wp := enemy_steer(sim, e, goal, dt)
            w := la.normalize0((wp - e.pos).xz)
            if !e.sees && la.length((e.last_seen - e.pos).xz) < 1 * world_scale {
                e.state, e.timer = .Idle, rand.float32_range(1, 3) // nobody here
            } else if w != 0 {
                turn_towards(&e.yaw, dist < 4 * world_scale && e.sees ? dir : w, dt * 7)
                want_speed = sp.run
                accel = w
            }
        }
    case .Windup:
        turn_towards(&e.yaw, dir, dt * 5)
        if e.timer <= 0 { e.state, e.timer = .Strike, sp.strike; sim_emit(sim, {kind = .Enemy_Swing, enemy = e.kind, pos = enemy_center(e)}) }
    case .Strike:
        // Lunges a step into the swing; hurts once if the player is in front.
        fwd := [2]f32{-math.sin(e.yaw), math.cos(e.yaw)}
        want_speed, accel = sp.run * 0.8, fwd
        if !e.struck && dist < sp.reach + 0.5 * world_scale && to_player.y > -1.2 * world_scale && to_player.y < sp.height &&
           la.dot(dir, fwd) > (e.swing == .Slash ? -0.1 : 0.45) {
            e.struck = true
            knock := [3]f32{dir.x * sp.knock[0], sp.knock[1], dir.y * sp.knock[0]}
            switch player_hurt(sim, e.prey, sp.damage * level_damage(e.level), knock, enemy_center(e)) {
            case .Hit:
                sim_emit(sim, {kind = .Enemy_Struck, enemy = e.kind, pos = feet + {0, world_scale, 0}})
            case .Blocked:
                e.vel.xz -= dir * (3 * world_scale / sp.weight)
                e.timer = sp.strike * 0.5 // the swing's spent
            case .Parried:
                // Thrown off balance: reeling, wide open.
                e.state, e.timer = .Stagger, 1.3
                e.vel = {-dir.x * 5 / sp.weight, 3, -dir.y * 5 / sp.weight} * world_scale
                e.on_ground = false
                e.flash = 1
                enemy_voice(sim, e, 1)
                return
            case .Missed:
            }
        }
        if e.timer <= 0 { e.state, e.timer = .Recover, sp.recover }
    case .Recover:
        if e.timer <= 0 { e.state = .Chase }
    case .Stagger:
        if e.timer <= 0 && e.on_ground { e.state, e.timer = .Chase, 0 }
    case .Dead:
        e.death += dt
        if e.death > 4 { e.alive = false }
        return
    }

    // Steer the ground velocity toward the wanted one.
    if e.on_ground && e.state != .Stagger {
        goal := accel * want_speed
        k := min(dt * 10, 1)
        e.vel.x += (goal.x - e.vel.x) * k
        e.vel.z += (goal.y - e.vel.z) * k
    }

    // The player can't walk through them: it gives way a little (the
    // player's client steps itself out: monsters_push_player).
    if over, ok := enemy_overlap(e, p.pos); ok {
        e.vel.xz -= dir * over * 30 * dt / sp.weight
    }
}

// How far a player with the eye at `eye` stands inside enemy e's body, if
// it does: along the ground, from the enemy to the player.
enemy_overlap :: proc(e: ^Enemy, eye: [3]f32) -> (over: f32, ok: bool) {
    sp := ENEMY_SPECS[e.kind]
    to_player := eye - {0, PLAYER_EYE_HEIGHT, 0} - e.pos
    r := sp.radius + PLAYER_HALF_W
    dist := la.length(to_player.xz)
    if dist < r && to_player.y > -sp.height && to_player.y < PLAYER_EYE_HEIGHT { return r - dist, true }
    return 0, false
}

// Grunts and rattles: noticing the player, winding up.
@(private="file")
enemy_voice :: proc(sim: ^Sim, e: ^Enemy, volume: f32) {
    sim_emit(sim, {kind = .Enemy_Voice, enemy = e.kind, pos = enemy_center(e), amount = volume})
}

@(private="file")
enemy_move :: proc(sim: ^Sim, e: ^Enemy, dt: f32) {
    sp := ENEMY_SPECS[e.kind]
    hw, h := sp.radius, sp.height * 0.92
    if e.rising > 0 { e.vel = {}; return }

    centre := e.pos + {0, h * 0.5, 0}
    in_water := block_is_watery(u8(voxel_at(sim.world, centre)))
    if in_water {
        e.vel *= max(1 - 2.5 * dt, 0)
        e.vel.y += 9 * world_scale * dt
    }
    if !e.on_ground { e.vel.y = max(e.vel.y - ENEMY_GRAVITY * dt, -40 * world_scale) }
    if e.state == .Dead { e.vel.xz *= math.exp(-6 * dt) }

    d := e.vel * dt
    p := e.pos
    blocked := false
    for axis in ([2]int{0, 2}) {
        if d[axis] == 0 { continue }
        q := p
        q[axis] += d[axis]
        if !box_solid(sim.world, q, hw, h) { p = q; continue }
        // A single block: step up onto it.
        if e.on_ground && !box_solid(sim.world, q + {0, 1.01, 0}, hw, h) && e.state != .Dead {
            p = q + {0, 1.01, 0}
            continue
        }
        blocked = true
        e.vel[axis] = 0
    }
    if d.y != 0 {
        if box_solid(sim.world, p + {0, d.y, 0}, hw, h) {
            if d.y < 0 {
                top := math.floor(p.y + d.y) + 1
                if top <= p.y && !box_solid(sim.world, {p.x, top, p.z}, hw, h) { p.y = top }
            }
            e.vel.y = 0
        } else {
            p.y += d.y
        }
    }
    if box_solid(sim.world, p, hw, h) { p.y = math.floor(p.y) + 1 }
    e.pos = p
    e.on_ground = e.vel.y <= 0.01 && box_solid(sim.world, p - {0, 0.03, 0}, hw, h)
    // Higher than a step in the way while chasing: jump it.
    if blocked && e.on_ground && (e.state == .Chase || e.state == .Wander) {
        e.vel.y = ENEMY_JUMP
        e.on_ground = false
    }
}

// Damage and knock it about; player `by` struck it, and has its attention.
// True if it died.
enemy_damage :: proc(sim: ^Sim, e: ^Enemy, damage: f32, knock: [3]f32, boosted: bool, by := LOCAL_PLAYER) -> bool {
    sp := ENEMY_SPECS[e.kind]
    if e.state == .Dead { return false }
    e.hp -= damage
    e.flash = 1
    e.bar = 4
    e.vel = knock / sp.weight
    e.vel.y = knock.y / math.sqrt(sp.weight)
    e.on_ground = false
    e.rising = 0
    e.prey = by
    e.last_seen, e.seen_ago = player_feet(&sim.players[by]), 0
    c := enemy_center(e)
    sim_emit(sim, {kind = .Enemy_Hit, enemy = e.kind, pos = c, vec = knock, amount = damage, boosted = boosted})
    // Heavy ones shrug off the light hits mid-swing.
    if e.kind != .Orc || damage >= 20 || (e.state != .Windup && e.state != .Strike) {
        e.state, e.timer = .Stagger, 0.45 / math.sqrt(sp.weight)
    }
    if e.hp > 0 { return false }
    enemy_die(sim, e, knock)
    return true
}

@(private="file")
enemy_die :: proc(sim: ^Sim, e: ^Enemy, knock: [3]f32) {
    e.state, e.death = .Dead, 0
    e.bar = 0
    sim_emit(sim, {kind = .Enemy_Die, enemy = e.kind, pos = enemy_center(e), vec = knock})
    if e.guard { site_lost_one(&sim.enemies, e.site) }
    calm_mark(sim, e.pos)
}

// Skeletons of the night at dawn: a puff of bone dust, gone.
@(private="file")
enemy_crumble :: proc(sim: ^Sim, e: ^Enemy) {
    sim_emit(sim, {kind = .Enemy_Crumble, enemy = e.kind, pos = enemy_center(e)})
    e.alive = false
}

// ─── Spawning ───────────────────────────────────────────────────────────────

// Top of the loaded ground at (x, z) with room to stand, searched down from y.
stand_y :: proc(sim: ^Sim, x, z, from_y: int) -> (y: int, ok: bool) {
    for yy := from_y; yy > from_y - 40; yy -= 1 {
        if solid_at(sim.world, x, yy, z) {
            if !solid_at(sim.world, x, yy + 1, z) && !solid_at(sim.world, x, yy + 2, z) && !solid_at(sim.world, x, yy + 3, z) &&
               !block_is_watery(u8(get_voxel(sim.world, x, yy + 1, z))) { return yy + 1, true }
            return 0, false
        }
    }
    return 0, false
}

// What roams biome b, by day or (night) by night.
@(private="file")
roamer_for :: proc(b: Biome, night: f32) -> (kind: Enemy_Kind, pack: int, ok: bool) {
    if night > 0.6 && rand.float32() < 0.6 { return .Skeleton, 1 + rand.int_max(2), true }
    #partial switch b {
    case .Plains, .Forest:   return .Goblin, 2 + rand.int_max(2), true
    case .Desert, .Badlands, .Savanna: return rand.float32() < 0.5 ? .Orc : .Goblin, rand.float32() < 0.5 ? 1 : 2, true
    case .Taiga, .Snowy, .Mountains, .Peaks: return .Skeleton, 1 + rand.int_max(2), true
    }
    return .Goblin, 0, false
}

// A pack somewhere out from the player (not where it's calm); whether one came.
@(private="file")
enemy_try_spawn :: proc(sim: ^Sim, feet: [3]f32, night: f32) -> bool {
    for _ in 0 ..< 8 {
        a := rand.float32_range(0, 2 * math.PI)
        r := rand.float32_range(ROAM_SPAWN_NEAR, ROAM_SPAWN_FAR) * world_scale
        x := int(math.floor(feet.x + math.cos(a) * r))
        z := int(math.floor(feet.z + math.sin(a) * r))
        if calm_at(sim, f32(x), f32(z)) { continue }
        g := surface_height_at(x, z)
        if g <= SEA_LEVEL { continue }
        y, ok := stand_y(sim, x, z, g + 2)
        if !ok { continue }
        kind, pack, any := roamer_for(terrain_at(x, z).biome, night)
        if !any { return false }
        for i in 0 ..< pack {
            px, pz := x + rand.int_max(5) - 2, z + rand.int_max(5) - 2
            py, ok2 := stand_y(sim, px, pz, y + 3)
            if !ok2 { continue }
            e := enemy_spawn(sim, i == 0 ? kind : (kind == .Orc ? .Goblin : kind), {f32(px) + 0.5, f32(py), f32(pz) + 0.5})
            if e == nil { return true }
            if night > 0.5 { enemy_set_level(e, monster_level(e.pos, 1)) } // tougher by night
            if kind == .Skeleton && night > 0.6 {
                e.nocturnal = true
                e.rising = 1 // claws up out of the ground
                sim_emit(sim, {kind = .Enemy_Rise, enemy = e.kind, pos = e.pos})
            }
        }
        return true
    }
    return false
}

// Landmarks near the player get their guards; cleared ones refill after a while.
@(private="file")
sites_update :: proc(sim: ^Sim, feet: [3]f32) {
    s := &sim.enemies
    pcx := floor_div(int(feet.x), LANDMARK_CELL)
    pcz := floor_div(int(feet.z), LANDMARK_CELL)
    for cz in pcz - 1 ..= pcz + 1 {
        for cx in pcx - 1 ..= pcx + 1 {
            key := [2]int{cx, cz}
            lm, cached := s.landmarks[key]
            if !cached {
                lm = landmark_in_cell(cx, cz)
                s.landmarks[key] = lm
            }
            if lm.kind == .None { continue }
            centre := [3]f32{f32(lm.x) + 0.5, f32(lm.base), f32(lm.z) + 0.5}
            if la.length((centre - feet).xz) > SITE_NOTICE * world_scale { continue }
            site := s.sites[key]
            if site.spawned { continue }
            if site.cleared_at > 0 && s.time - site.cleared_at < SITE_RESPAWN { continue }
            n := site_spawn(sim, lm, key, sim.day.night)
            if n > 0 { s.sites[key] = {spawned = true, alive = n} }
        }
    }
}

// The guards of a landmark; how many were placed.
@(private="file")
site_spawn :: proc(sim: ^Sim, lm: Landmark, key: [2]int, night: f32) -> int {
    kinds: [6]Enemy_Kind
    n := 0
    add :: proc(k: ^[6]Enemy_Kind, n: ^int, kind: Enemy_Kind, count: int) {
        for _ in 0 ..< count { if n^ < len(k) { k[n^] = kind; n^ += 1 } }
    }
    ring := f32(6 * TERRAIN_SCALE)
    switch lm.kind {
    case .None:
    case .Tower:  add(&kinds, &n, .Skeleton, 3)
    case .Shrine: add(&kinds, &n, .Skeleton, 2); ring = 5 * TERRAIN_SCALE
    case .Stones: add(&kinds, &n, .Skeleton, night > 0.5 ? 4 : 2); ring = 4 * TERRAIN_SCALE
    case .Camp:
        b := terrain_at(lm.x, lm.z).biome
        orcs := (b == .Desert || b == .Badlands) ? 2 : 1
        add(&kinds, &n, .Orc, orcs)
        add(&kinds, &n, .Goblin, 4 - orcs + 1)
    }
    placed := 0
    for i in 0 ..< n {
        for _ in 0 ..< 6 {
            a := rand.float32_range(0, 2 * math.PI)
            r := rand.float32_range(ring * 0.5, ring * 1.3)
            x := lm.x + int(math.floor(math.cos(a) * r))
            z := lm.z + int(math.floor(math.sin(a) * r))
            y, ok := stand_y(sim, x, z, lm.base + 9)
            if !ok { continue }
            e := enemy_spawn(sim, kinds[i], {f32(x) + 0.5, f32(y), f32(z) + 0.5})
            if e == nil { return placed }
            e.guard, e.site = true, key
            enemy_set_level(e, monster_level(e.pos, 2)) // a landmark's guards are the tougher ones
            placed += 1
            break
        }
    }
    return placed
}

@(private="file")
site_forget :: proc(s: ^Enemies, key: [2]int) {
    if site, ok := &s.sites[key]; ok {
        site.alive -= 1
        if site.alive <= 0 && site.cleared_at == 0 { site.spawned = false }
    }
}

@(private="file")
site_lost_one :: proc(s: ^Enemies, key: [2]int) {
    if site, ok := &s.sites[key]; ok {
        site.alive -= 1
        if site.alive <= 0 {
            site.cleared_at = s.time
            site.spawned = false
        }
    }
}

// Knocked out: everything close backs off and calms down.
enemies_scatter :: proc(sim: ^Sim, pos: [3]f32) {
    for &e in sim.enemies.list {
        if !e.alive || e.state == .Dead { continue }
        d := e.pos - pos
        d.y = 0
        if la.length(d) < 16 * world_scale {
            e.vel = (la.normalize0(d) * 9 + {0, 5, 0}) * world_scale
            e.on_ground = false
            e.state, e.timer = .Wander, 8
            e.target = e.guard ? e.home : e.pos + la.normalize0(d) * 12 * world_scale
        }
    }
}

// Debug (F8): an enemy a few steps ahead, each press the next kind.
@(private="file")
debug_next_kind: Enemy_Kind

enemy_debug_spawn :: proc(gs: ^Game_State) {
    feet := gs.camera.pos - {0, PLAYER_EYE_HEIGHT, 0}
    at := feet + camera_flat_forward(gs.camera) * 5 * world_scale + {0, 0.5, 0}
    kind := debug_next_kind
    debug_next_kind = Enemy_Kind((int(kind) + 1) % len(Enemy_Kind))
    yaw := -math.to_radians(gs.camera.yaw) + math.PI
    client_send(gs, .Spawn, Msg_Spawn{target = .Enemy, kind = u8(kind), pos = at, yaw = yaw})
    ui_toast(gs, fmt.tprintf("Spawned a %v", kind))
}

enemies_clear :: proc(sim: ^Sim) {
    for &e in sim.enemies.list { e.alive = false }
    clear(&sim.enemies.sites)
    sim.enemies.spawn_timer = 30
}

// ─── Drawing ────────────────────────────────────────────────────────────────

@(private="file")
attach_part :: proc(f: ^Ent_Frame, model: Model_Id, pos: [3]f32, rot: Basis, s: f32, offset: [3]f32, local: Basis, tint: [3]f32, mirror := false) {
    sc := [3]f32{mirror ? -s : s, s, s}
    ent_part(f, model, pos + rot * (offset * s), rot * local, sc, tint)
}

@(private="file")
ease_out :: proc(t: f32) -> f32 { return 1 - (1 - t) * (1 - t) }

@(private="file")
arm_lerp :: proc(a, b: Arm_Key, t: f32) -> Arm_Key {
    return {math.lerp(a.yaw, b.yaw, t), math.lerp(a.pitch, b.pitch, t), math.lerp(a.tilt, b.tilt, t), math.lerp(a.twist, b.twist, t)}
}

enemies_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    eye := gs.camera.pos
    for &e in gs.enemies.list {
        if !e.alive || la.length(e.pos - eye) > ENTITY_CULL_RADIUS { continue }
        if !ent_begin(f) { return }
        enemy_pose(f, &e)
        ent_end(f)
    }
}

// Also the entity sandbox's (sandbox.odin), on enemies it poses itself.
enemy_pose :: proc(f: ^Ent_Frame, e: ^Enemy) {
    sp := ENEMY_SPECS[e.kind]
    rig := ENEMY_RIGS[e.kind]
    s := sp.scale
    feet := e.pos
    feet.y -= e.rising * sp.height * 0.9
    tint := la.lerp(e.tint, [3]f32{2.6, 2.6, 2.6}, e.flash * 0.7)
    bone_tint := la.lerp([3]f32{1, 1, 1}, [3]f32{2.4, 2.4, 2.4}, e.flash * 0.7)
    if e.kind == .Skeleton { tint = bone_tint }
    if e.freeze > 0 { feet += [3]f32{rand.float32_range(-1, 1), 0, rand.float32_range(-1, 1)} * 0.03 }

    // Dead: falls over backwards about its feet; skeletons fall apart.
    body := basis_yaw(e.yaw)
    if e.state == .Dead {
        if e.kind == .Skeleton { skeleton_heap(f, e, feet, tint); return }
        fall := ease_out(min(e.death * 2.2, 1))
        body = body * basis_rot_x(-fall * math.PI * 0.48)
        feet.y -= max(e.death - 2.5, 0) * 0.6 // sinks away
    }

    amp := clamp(e.speed / sp.run, 0, 1.2)
    sw := 0.75 * amp * math.sin(e.walk_phase)
    bob := 0.05 * amp * abs(math.cos(e.walk_phase))
    hips := [3]f32{0, rig.hips + bob, 0}
    air: f32 = e.on_ground ? 0 : 1

    // Weapon arm (right, -x): resting with the walk, or through a swing's
    // keys: winding up to the first, striking to the second, recovering.
    key := ARM_REST
    key.pitch = -0.6 * sw
    lean: f32 = 0.06 * amp
    keys := SWING_KEYS[e.swing]
    switch e.state {
    case .Windup:
        t := ease_out(1 - max(e.timer, 0) / sp.windup)
        key = arm_lerp(key, keys[0], t)
        lean = e.swing == .Overhead ? -0.15 * t : 0
    case .Strike:
        t := ease_out(1 - max(e.timer, 0) / sp.strike)
        key = arm_lerp(keys[0], keys[1], t)
        lean = e.swing == .Overhead ? -0.15 + 0.4 * t : 0.1 * t
    case .Recover:
        t := 1 - max(e.timer, 0) / sp.recover
        key = arm_lerp(keys[1], ARM_REST, t * t)
        lean = (e.swing == .Overhead ? 0.25 : 0.1) * (1 - t)
    case .Stagger:
        lean = -0.3
        key.pitch = 0.6
    case .Idle, .Wander, .Chase, .Dead:
    }
    if e.rising > 0 { key.pitch = 2.4 * e.rising; lean = 0.3 * e.rising }

    leg_l := sw * (1 - air) - 0.4 * air
    leg_r := -sw * (1 - air) + 0.2 * air
    attach_part(f, rig.leg, feet, body, s, hips + {rig.leg_x, 0, 0}, basis_rot_x(leg_l), tint)
    attach_part(f, rig.leg, feet, body, s, hips + {-rig.leg_x, 0, 0}, basis_rot_x(leg_r), tint)
    torso := body * basis_yaw(key.twist) * basis_rot_x(lean)
    attach_part(f, rig.torso, feet + body * (hips * s), torso, s, {}, IDENTITY, tint)
    // Off arm swings with the walk; in an attack it braces forward.
    off := 0.6 * sw
    if e.state == .Windup || e.state == .Strike { off = e.swing == .Overhead ? 0.3 : -0.7 }
    attach_part(f, rig.arm, feet + body * (hips * s), torso, s, {rig.arm_x, rig.arm_y, 0}, basis_rot_z(0.12) * basis_rot_x(off), tint)
    arm_rot := basis_yaw(key.yaw) * basis_rot_x(key.pitch) * basis_rot_z(-0.1)
    attach_part(f, rig.arm, feet + body * (hips * s), torso, s, {-rig.arm_x, rig.arm_y, 0}, arm_rot, tint)
    // The weapon in that hand, tilted from the forearm by the key.
    shoulder := [3]f32{-rig.arm_x, rig.arm_y, 0}
    grip := shoulder + arm_rot * [3]f32{0, -rig.arm_len, 0}
    attach_part(f, rig.weapon, feet + body * (hips * s), torso, s, grip, arm_rot * basis_rot_x(key.tilt), {1, 1, 1})
    // Head: looks about when idle.
    look: f32 = e.state == .Idle ? 0.5 * math.sin(e.age * 0.7 + f32(e.walk_phase)) : 0
    attach_part(f, rig.head, feet + body * (hips * s), torso, s, {0, rig.neck, 0}, basis_yaw(look), tint)
}

// A skeleton that's just been destroyed: the parts drop into a heap and
// scatter a little, then sink.
@(private="file")
skeleton_heap :: proc(f: ^Ent_Frame, e: ^Enemy, feet: [3]f32, tint: [3]f32) {
    t := min(e.death * 2.5, 1)
    sink := max(e.death - 2.5, 0) * 0.5
    body := basis_yaw(e.yaw)
    k := ease_out(t)
    drop :: proc(from_y: f32, k: f32) -> f32 { return from_y * (1 - k) + 0.08 * k }
    g := feet - {0, sink, 0}
    attach_part(f, .Skel_Skull, g, body, 1, {0.25 * k, drop(1.38, k), 0.3 * k}, basis_rot_z(1.4 * k) * basis_rot_x(0.6 * k), tint)
    attach_part(f, .Skel_Torso, g, body, 1, {0, drop(0.78, k) - 0.05 * k, -0.2 * k}, basis_rot_x(-1.5 * k), tint)
    attach_part(f, .Skel_Arm, g, body, 1, {0.4 * k + 0.23 * (1 - k), drop(1.3, k), 0.1}, basis_rot_z(1.5 * k), tint)
    attach_part(f, .Skel_Arm, g, body, 1, {-0.3 * k - 0.23 * (1 - k), drop(1.3, k), -0.25 * k}, basis_rot_x(1.5 * k) * basis_rot_z(-0.4 * k), tint)
    attach_part(f, .Skel_Leg, g, body, 1, {0.1, drop(0.78, k), -0.3 * k}, basis_rot_x(1.5 * k), tint)
    attach_part(f, .Skel_Leg, g, body, 1, {-0.2 * k - 0.09, drop(0.78, k), 0.2 * k}, basis_rot_x(1.3 * k) * basis_rot_z(-0.5 * k), tint)
    attach_part(f, .Old_Sword, g, body, 1, {0.5 * k, 0.05, 0.3 * k}, basis_yaw(1.2) * basis_rot_x(-math.PI / 2 * k + 0.0), {1, 1, 1})
}

// ─── Shapes ─────────────────────────────────────────────────────────────────

@(private="file")
shape_skel_skull :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Eye sockets with an ember deep inside, nose hole.
    if la.length(q - {0.065, 0.22, 0.14}) < 0.05 {
        return la.length(q - {0.06, 0.22, 0.12}) < 0.02 ? .Eye_Glow : .Eye
    }
    if abs(p.x) < 0.022 && p.y > 0.14 && p.y < 0.19 && p.z > 0.12 { return .Eye }
    cranium := la.length((p - {0, 0.25, 0}) / [3]f32{1, 0.95, 1.1}) - 0.165
    jaw := vm_round_box(p, {0, 0.11, 0.05}, {0.095, 0.05, 0.085}, 0.025)
    neck := vm_capsule(p, {0, 0, -0.02}, {0, 0.09, -0.02}, 0.045)
    d := min(min(vm_smin(cranium, jaw, 0.04), neck), 1)
    if d > 0 { return .Empty }
    // Teeth: a row with gaps.
    if p.z > 0.1 && abs(p.y - 0.13) < 0.02 { return int(math.floor(p.x / voxel)) % 2 == 0 ? .Bone : .Bone_Shadow }
    if p.y < 0.09 && p.z < 0 { return .Bone_Shadow }
    return .Bone
}

@(private="file")
shape_skel_torso :: proc(p: [3]f32, voxel: f32) -> Pal {
    pelvis := vm_round_box(p, {0, 0.04, -0.01}, {0.17, 0.07, 0.09}, 0.03)
    spine := vm_capsule(p, {0, 0.05, -0.06}, {0, 0.6, -0.06}, 0.048)
    collar := vm_capsule(p, {-0.24, 0.56, -0.01}, {0.24, 0.56, -0.01}, 0.042)
    if min(pelvis, spine, collar) < 0 { return pelvis < 0 && p.y < 0.02 ? .Bone_Shadow : .Bone }
    // Ribs: bands of a hollow cage.
    cage := la.length((p - {0, 0.38, 0}) / [3]f32{0.21, 0.2, 0.14}) - 1
    if cage < 0 && cage > -0.4 && p.y > 0.2 && p.y < 0.54 {
        band := int(math.floor(p.y / voxel)) % 2 == 0
        if p.z > 0.07 && abs(p.x) < 0.04 { return .Bone } // sternum
        if band && !(p.z > 0.06 && abs(p.x) < 0.07 && p.y < 0.3) { return .Bone }
    }
    return .Empty
}

@(private="file")
shape_skel_arm :: proc(p: [3]f32, voxel: f32) -> Pal {
    if la.length(p - {0, -0.27, 0}) < 0.058 { return .Bone } // elbow
    if vm_capsule(p, {0, -0.01, 0}, {0, -0.26, 0}, 0.046) < 0 { return .Bone }
    if vm_capsule(p, {0, -0.28, 0}, {0, -0.47, 0.01}, 0.04) < 0 { return .Bone }
    if vm_round_box(p, {0, -0.52, 0.01}, {0.045, 0.05, 0.04}, 0.015) < 0 { return .Bone_Shadow } // hand
    return .Empty
}

@(private="file")
shape_skel_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if la.length(p - {0, -0.38, 0.01}) < 0.066 { return .Bone } // knee
    if vm_capsule(p, {0, -0.02, 0}, {0, -0.36, 0.01}, 0.054) < 0 { return .Bone }
    if vm_capsule(p, {0, -0.4, 0.01}, {0, -0.72, 0}, 0.046) < 0 { return .Bone }
    if vm_round_box(p, {0, -0.76, 0.05}, {0.06, 0.03, 0.1}, 0.015) < 0 { return .Bone_Shadow }
    return .Empty
}

@(private="file")
shape_gob_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Long ears swept out and back.
    {
        a, b := [3]f32{0.17, 0.26, -0.02}, [3]f32{0.44, 0.34, -0.1}
        ba := b - a
        t := clamp(la.dot(q - a, ba) / la.dot(ba, ba), 0, 1)
        r := 0.07 * (1 - t) + 0.01
        c := a + ba * t
        if abs(q.x - c.x) < max(r, 0.04) && abs(p.y - c.y) < max(r, 0.03) && abs(p.z - c.z) < 0.04 {
            return t > 0.2 && t < 0.8 && p.z > c.z ? .Hide_Dark : .Hide
        }
    }
    // Hooked nose.
    if vm_capsule(p, {0, 0.22, 0.17}, {0, 0.13, 0.27}, 0.035) < 0 { return .Hide_Dark }
    head := vm_round_box(p, {0, 0.22, 0.02}, {0.18, 0.18, 0.17}, 0.08)
    if head > 0 { return .Empty }
    if p.z > 0.12 {
        if la.length(q - {0.085, 0.26, 0.17}) < 0.04 {
            return la.length(q - {0.085, 0.26, 0.2}) < 0.018 ? .Eye : .Eye_Yellow
        }
        if abs(p.y - 0.31) < 0.025 && q.x < 0.15 { return .Hide_Dark } // brow
        if abs(p.y - 0.1) < 0.018 && q.x < 0.09 { return q.x > 0.05 && q.x < 0.07 ? .Tusk : .Mouth }
    }
    if p.y > 0.36 && p.z < 0.05 { return .Hide_Dark } // scalp
    return .Hide
}

@(private="file")
shape_gob_torso :: proc(p: [3]f32, voxel: f32) -> Pal {
    body := vm_round_box(p, {0, 0.28, 0}, {0.22, 0.28, 0.15}, 0.07)
    belly := la.length(p - {0, 0.2, 0.06}) - 0.19
    if min(body, belly) > 0 { return .Empty }
    if p.y < 0.1 { return p.z > 0.02 && abs(p.x) < 0.1 && p.y < 0.06 ? .Leather_Dark : .Leather } // loincloth
    if p.y < 0.14 { return .Leather_Dark } // belt
    if abs(p.x + (p.y - 0.35) * 0.7) < 0.035 { return .Leather_Dark } // strap
    return .Hide
}

@(private="file")
shape_gob_arm :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.25, 0}, {0.09, 0.26, 0.09}, 0.035) > 0 { return .Empty }
    if p.y < -0.42 { return .Hide_Dark }
    if p.y < -0.34 { return .Leather } // wrist wrap
    return .Hide
}

@(private="file")
shape_gob_leg :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_round_box(p, {0, -0.69, 0.04}, {0.1, 0.06, 0.14}, 0.03) < 0 { return .Hide_Dark } // bare foot
    if vm_round_box(p, {0, -0.34, 0}, {0.105, 0.35, 0.11}, 0.035) > 0 { return .Empty }
    if p.y < -0.42 && p.y > -0.6 { return int(math.floor(p.y / voxel)) % 3 == 0 ? .Leather_Dark : .Leather }
    return .Hide
}

@(private="file")
shape_orc_head :: proc(p: [3]f32, voxel: f32) -> Pal {
    q := [3]f32{abs(p.x), p.y, p.z}
    // Tusks jutting up from the jaw.
    if vm_capsule(q, {0.09, 0.09, 0.2}, {0.11, 0.19, 0.22}, 0.024) < 0 { return .Tusk }
    // Topknot.
    if vm_capsule(p, {0, 0.38, -0.06}, {0, 0.5, -0.14}, 0.05) < 0 { return .Hair }
    skull := vm_round_box(p, {0, 0.22, 0.01}, {0.18, 0.18, 0.17}, 0.06)
    jaw := vm_round_box(p, {0, 0.08, 0.08}, {0.16, 0.07, 0.12}, 0.04)
    if min(skull, jaw) > 0 { return .Empty }
    if p.z > 0.12 {
        if la.length(q - {0.08, 0.24, 0.18}) < 0.028 { return .Eye_Red }
        if abs(p.y - 0.29) < 0.03 && q.x < 0.16 { return .Hide_Dark } // heavy brow
        if abs(p.y - 0.1) < 0.015 && q.x < 0.11 { return .Mouth }
    }
    if q.x > 0.16 && abs(p.y - 0.22) < 0.05 && abs(p.z) < 0.04 { return .Hide_Dark } // ears
    return .Hide
}

@(private="file")
shape_orc_torso :: proc(p: [3]f32, voxel: f32) -> Pal {
    body := vm_round_box(p, {0, 0.3, 0}, {0.3, 0.3, 0.19}, 0.07)
    pads := vm_round_box([3]f32{abs(p.x), p.y, p.z}, {0.29, 0.57, 0}, {0.12, 0.07, 0.15}, 0.04)
    if min(body, pads) > 0 { return .Empty }
    if pads < 0 { return int(math.floor(p.z / voxel)) % 3 == 0 ? .Rust : .Iron } // shoulder plates
    if p.y < 0.06 { return abs(p.x) < 0.12 && p.z > 0 ? .Cloth : .Leather_Dark }
    if p.y < 0.13 { return .Leather_Dark } // belt
    if p.y > 0.45 && abs(p.x) < 0.08 && p.z > 0 { return .Hide } // the throat
    if abs(p.x) < 0.2 && p.y > 0.2 && p.y < 0.45 && p.z > 0.1 {
        return int(math.floor(p.y / voxel)) % 3 == 0 ? .Leather_Dark : .Leather // laced front
    }
    return .Leather
}

@(private="file")
shape_club :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, -0.08}, {0, 0, 0.28}, 0.03) < 0 { return p.z < 0.06 ? .Leather_Dark : .Wood }
    head := la.length((p - {0, 0, 0.44}) / [3]f32{1, 1, 1.9}) - 0.075
    if head < 0 { return int(math.floor(p.z / voxel)) % 4 == 0 ? .Wood_Dark : .Wood }
    // A few nails through it.
    if abs(p.z - 0.47) < 0.02 && (abs(p.x) < 0.012 || abs(p.y) < 0.012) && la.length(p.xy) < 0.11 { return .Iron }
    return .Empty
}

@(private="file")
shape_old_sword :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, -0.07}, {0, 0, 0.06}, 0.03) < 0 { return .Leather_Dark }
    if abs(p.z - 0.08) < 0.025 && abs(p.x) < 0.11 && abs(p.y) < 0.035 { return .Rust }
    if p.z > 0.09 && p.z < 0.72 {
        w := 0.055 * (1 - max(p.z - 0.62, 0) / 0.14)
        if abs(p.x) < w && abs(p.y) < 0.025 {
            n := math.sin(p.z * 61) * math.sin(p.x * 97 + p.z * 23)
            return n > 0.3 ? .Rust : .Iron
        }
    }
    return .Empty
}

@(private="file")
shape_axe :: proc(p: [3]f32, voxel: f32) -> Pal {
    if vm_capsule(p, {0, 0, -0.1}, {0, 0, 0.78}, 0.03) < 0 { return p.z < 0.08 ? .Leather_Dark : .Wood }
    // A bearded blade to one side near the top.
    if p.z > 0.52 && p.z < 0.82 && p.x > 0 && p.x < 0.24 && abs(p.y) < 0.02 {
        c := p.z - 0.67
        reach := 0.13 + 0.11 * (1 - (c * c) / (0.15 * 0.15))
        if p.x < reach { return p.x > reach - 0.03 ? .Blade_Edge : .Iron }
    }
    return .Empty
}

enemy_models_bake :: proc() {
    ent_models[.Skel_Skull] = model_bake({-0.2, -0.03, -0.2}, {0.2, 0.45, 0.22}, 1.0 / 24, shape_skel_skull)
    ent_models[.Skel_Torso] = model_bake({-0.3, -0.05, -0.16}, {0.3, 0.66, 0.16}, 1.0 / 24, shape_skel_torso)
    ent_models[.Skel_Arm]   = model_bake({-0.07, -0.6, -0.06}, {0.07, 0.06, 0.07}, 1.0 / 24, shape_skel_arm)
    ent_models[.Skel_Leg]   = model_bake({-0.08, -0.81, -0.08}, {0.08, 0.06, 0.17}, 1.0 / 24, shape_skel_leg)
    ent_models[.Gob_Head]   = model_bake({-0.46, -0.02, -0.2}, {0.46, 0.45, 0.3}, 1.0 / 20, shape_gob_head)
    ent_models[.Gob_Torso]  = model_bake({-0.26, -0.02, -0.2}, {0.26, 0.6, 0.28}, 1.0 / 20, shape_gob_torso)
    ent_models[.Gob_Arm]    = model_bake({-0.1, -0.53, -0.1}, {0.1, 0.03, 0.1}, 1.0 / 20, shape_gob_arm)
    ent_models[.Gob_Leg]    = model_bake({-0.12, -0.75, -0.12}, {0.12, 0.02, 0.2}, 1.0 / 20, shape_gob_leg)
    ent_models[.Orc_Head]   = model_bake({-0.22, -0.02, -0.2}, {0.22, 0.52, 0.26}, 1.0 / 20, shape_orc_head)
    ent_models[.Orc_Torso]  = model_bake({-0.42, -0.02, -0.23}, {0.42, 0.66, 0.23}, 1.0 / 20, shape_orc_torso)
    ent_models[.Club]       = model_bake({-0.1, -0.1, -0.1}, {0.1, 0.1, 0.6}, 1.0 / 24, shape_club)
    ent_models[.Old_Sword]  = model_bake({-0.12, -0.05, -0.1}, {0.12, 0.05, 0.78}, 1.0 / 24, shape_old_sword)
    ent_models[.Axe]        = model_bake({-0.04, -0.04, -0.12}, {0.26, 0.04, 0.84}, 1.0 / 24, shape_axe)
}
