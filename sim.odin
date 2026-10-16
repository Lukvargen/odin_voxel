package main

import "core:math"
import la "core:math/linalg"

// The simulation, which the server runs (server.odin). It plays in a World
// (world.odin) it borrows: in singleplayer the client's. Slimes and enemies
// think about players, never about the camera: each player is one of
// `players`, as its client reports it every frame (client_send_input);
// slot LOCAL_PLAYER is the one at this keyboard. What happens that clients
// should see or hear goes out as events (events.odin), never as direct
// calls into effects, sound or the camera.
//
// Game_State embeds it (`using sim`), so gs.enemies, gs.day... still read
// as before, and a ^Game_State passes as a ^Sim.

MAX_PLAYERS  :: 8
LOCAL_PLAYER :: 0

Player :: struct {
    active:     bool,
    pos:        [3]f32, // eye, as the camera's
    velocity:   [3]f32,
    yaw:        f32,    // degrees, camera convention
    pitch:      f32,    // degrees, camera convention
    on_ground:  bool,
    fly_mode:   bool,   // nothing hunts a flying player
    sneaking:   bool,
    sprinting:  bool,
    sword:      bool,   // drawn: slimes only come for an armed player
    sword_pose: Sword_Pose, // where it is in the hand, view space (combat.odin), for the others to draw
    // Hang gliding (glider.odin): how the wing sits, for the others to draw.
    gliding:       bool,
    glide_heading: f32, // degrees
    glide_pitch:   f32, // radians
    glide_bank:    f32, // radians
    glide_unfold:  f32, // 0..1
    // Defence, as its client last reported it (hurt_outcome).
    invuln:     f32,    // dodging or just hurt: blows miss
    blocking:   bool,
    block_time: f32,    // since the guard went up
}

Sim :: struct {
    world:    ^World,    // the voxels it plays in (world.odin)
    monsters: bool,      // slimes and enemies spawn and hunt (the options' entities toggle)
    players:  [MAX_PLAYERS]Player,
    slimes:   Slimes,    // (slime.odin)
    enemies:  Enemies,   // skeletons, goblins, orcs; landmark guards (enemies.odin)
    day:      Day_Clock, // the time of day, and how much night (daycycle.odin)
    events:   [dynamic]Sim_Event, // this frame's happenings, for the client (events.odin)
}

// What the simulation tells the client about, which it can't see in the
// state alone: a hop, a hit, a death. The client makes them goo, numbers
// and sounds (events.odin); over a network they will be the messages.
Sim_Event_Kind :: enum u8 {
    Slime_Hop,     // pos: feet; amount: 0 an idle hop, 1 a chasing hop, 2 the leap
    Slime_Hit,     // pos: centre; vec: knock; amount: damage
    Slime_Pop,     // pos: centre; vec: knock
    Enemy_Voice,   // pos: centre; amount: volume (noticing you, winding up, reeling)
    Enemy_Swing,   // pos: centre: the strike starts
    Enemy_Struck,  // pos: the chest of the player its swing hurt
    Enemy_Hit,     // pos: centre; vec: knock; amount: damage
    Enemy_Die,     // pos: centre; vec: knock
    Enemy_Crumble, // pos: centre: a night skeleton gone at dawn
    Enemy_Rise,    // pos: feet: a skeleton clawing up out of the ground
    Player_Hurt,   // player was struck: result; pos: from; vec: knock; amount: damage
}

Sim_Event :: struct {
    kind:    Sim_Event_Kind,
    boosted: bool,       // a boosted hit (the number shows it)
    slime:   Slime_Size, // Slime_* events
    enemy:   Enemy_Kind, // Enemy_* events
    player:  u8,         // Player_* events
    result:  Hurt_Result,
    pos:     [3]f32,
    vec:     [3]f32,
    color:   [3]f32,     // the slime's
    amount:  f32,
}

MAX_SIM_EVENTS :: 1024 // more unplayed than this: the client isn't listening; drop them

sim_emit :: proc(s: ^Sim, ev: Sim_Event) {
    if len(s.events) < MAX_SIM_EVENTS { append(&s.events, ev) }
}

player_feet :: proc(p: ^Player) -> [3]f32 { return p.pos - {0, PLAYER_EYE_HEIGHT, 0} }

player_flat_forward :: proc(p: ^Player) -> [3]f32 {
    y := math.to_radians(p.yaw)
    return la.normalize([3]f32{math.sin(y), 0, math.cos(y)})
}

// Whether slimes and enemies are about this player: around it, after it.
player_hunted :: proc(p: ^Player) -> bool { return p.active }

// The hunted player nearest `pos` (ground distance), or -1 if there are none.
nearest_player :: proc(s: ^Sim, pos: [3]f32) -> (index: int, dist: f32) {
    index, dist = -1, max(f32)
    for &p, i in s.players {
        if !player_hunted(&p) { continue }
        if d := la.length((player_feet(&p) - pos).xz); d < dist { index, dist = i, d }
    }
    return
}

// Whether a blow from `from` (zero: from nowhere in particular, which a
// guard doesn't stop) lands on player p, by the defence its client last
// reported: Missed if it didn't (dodging, just hurt); Blocked or Parried if
// the guard took it. Notes the invulnerability that starts, so a second
// blow in the same frame misses; the client's own count replaces it next
// frame.
hurt_outcome :: proc(p: ^Player, from: [3]f32) -> Hurt_Result {
    if p.invuln > 0 { return .Missed }
    if p.blocking && from != 0 {
        to := la.normalize0((from - p.pos).xz)
        if la.dot(to, player_flat_forward(p).xz) > BLOCK_ARC {
            if p.block_time < PARRY_WINDOW {
                p.invuln = PARRY_INVULN
                return .Parried
            }
            p.invuln = HURT_INVULN * 0.6
            return .Blocked
        }
    }
    p.invuln = HURT_INVULN
    return .Hit
}

// Player `pi` is struck for `damage` from `from`. The outcome is decided
// here, so the attacker can reel from a parry at once; the player's client
// takes the hurt, knockback and clang from the event (combat_take_hurt).
player_hurt :: proc(s: ^Sim, pi: int, damage: f32, knock: [3]f32, from: [3]f32) -> Hurt_Result {
    r := hurt_outcome(&s.players[pi], from)
    if r != .Missed {
        sim_emit(s, {kind = .Player_Hurt, player = u8(pi), result = r, pos = from, vec = knock, amount = damage})
    }
    return r
}
