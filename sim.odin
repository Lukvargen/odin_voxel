package main

import la "core:math/linalg"

// The simulation: what a server will own and run once there is one, apart
// from the voxel world, which still lives in Game_State (world.odin).
// Slimes and enemies think about players, never about the camera: each
// player is one of `players`, and slot LOCAL_PLAYER is the one at this
// keyboard, copied from the camera every frame (sim_sync_local_player).
//
// Game_State embeds it (`using sim`), so gs.enemies, gs.day... still read
// as before.

MAX_PLAYERS  :: 8
LOCAL_PLAYER :: 0

Player :: struct {
    active:    bool,
    pos:       [3]f32, // eye, as the camera's
    velocity:  [3]f32,
    yaw:       f32,    // degrees, camera convention
    fly_mode:  bool,   // nothing hunts a flying player
    sneaking:  bool,
    sprinting: bool,
    sword:     bool,   // drawn: slimes only come for an armed player
}

Sim :: struct {
    players: [MAX_PLAYERS]Player,
    slimes:  Slimes,    // (slime.odin)
    enemies: Enemies,   // skeletons, goblins, orcs; landmark guards (enemies.odin)
    day:     Day_Cycle, // time of day: sun, moon, night, mist (daycycle.odin)
    events:  [dynamic]Sim_Event, // this frame's happenings, for the client (events.odin)
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
}

Sim_Event :: struct {
    kind:    Sim_Event_Kind,
    boosted: bool,       // a boosted hit (the number shows it)
    slime:   Slime_Size, // Slime_* events
    enemy:   Enemy_Kind, // Enemy_* events
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

// The local player as the camera and sword have it this frame.
sim_sync_local_player :: proc(gs: ^Game_State) {
    cam := &gs.camera
    gs.players[LOCAL_PLAYER] = {
        active = true, pos = cam.pos, velocity = cam.velocity, yaw = cam.yaw,
        fly_mode = cam.fly_mode, sneaking = cam.sneaking, sprinting = cam.sprinting,
        sword = gs.combat.sword,
    }
}

// The active player nearest `pos` (ground distance), or -1 if there are none.
nearest_player :: proc(s: ^Sim, pos: [3]f32) -> (index: int, dist: f32) {
    index, dist = -1, max(f32)
    for &p, i in s.players {
        if !p.active { continue }
        if d := la.length((player_feet(&p) - pos).xz); d < dist { index, dist = i, d }
    }
    return
}

// Something struck player `pi`. The player at this keyboard takes it
// (guarding, parrying, dodging) through combat_hurt; another player's
// client will decide for itself once there is a network.
player_hurt :: proc(gs: ^Game_State, pi: int, damage: f32, knock: [3]f32, from: [3]f32) -> Hurt_Result {
    if pi != LOCAL_PLAYER { return .Missed }
    return combat_hurt(gs, damage, knock, from)
}

// A monster overlapping player `pi` by `over` along `dir` (ground plane,
// monster to player) shoves the player out by half of it; stop_into also
// cancels walking into the monster. The player at this keyboard moves its
// own camera; a remote one will push itself.
player_push :: proc(gs: ^Game_State, pi: int, dir: [2]f32, over: f32, stop_into := false) {
    if pi != LOCAL_PLAYER { return }
    cam := &gs.camera
    if stop_into {
        if into := -(cam.velocity.x * dir.x + cam.velocity.z * dir.y); into > 0 {
            cam.velocity.x += dir.x * into
            cam.velocity.z += dir.y * into
        }
    }
    cam.pos, _ = move_axis(gs, cam.pos, {dir.x * over * 0.5, 0, 0})
    cam.pos, _ = move_axis(gs, cam.pos, {0, 0, dir.y * over * 0.5})
}
