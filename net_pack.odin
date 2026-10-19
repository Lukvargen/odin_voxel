package main

import "core:math"
import la "core:math/linalg"

// The states sent many times a second (players, monsters), packed for the
// wire: flags as bits, angles, speeds and timers as f16, and a monster's
// position as a small offset from the player it's sent to
// (Msg_Monsters.origin). About half the size of the structs they come from;
// what's lost is far below what anyone could see.

Net_Player_Flag :: enum u8 { Active, On_Ground, Fly_Mode, Sneaking, Sprinting, Sword, Gliding, Blocking, Torch, Climbing, Channeling, Conjuring }

Net_Player :: struct #packed {
    flags:      bit_set[Net_Player_Flag; u16],
    pos:        [3]f32, // anywhere in the world: kept whole
    velocity:   [3]f16,
    yaw, pitch: f16,    // yaw wrapped to 0..360
    sword_pose: [9]f16, // grip, blade, back
    swing_id:   u8,     // only ever compared for a change
    weapon:     Weapon,
    glide_heading, glide_pitch, glide_bank, glide_unfold: f16,
    invuln, block_time: f16,
    reach:      [3]f16, // offset from pos (a lip or a block within reach)
    reach_k, raise: f16,
}

// Monster offsets: 1/256 of a block, up to 128 blocks from the origin
// (MONSTER_VIEW_RANGE is less).
MONSTER_POS_SCALE :: 256
#assert(MONSTER_VIEW_RANGE * MONSTER_POS_SCALE < 32767)

Net_Slime :: struct #packed {
    index:     u8,
    size:      Slime_Size,
    state:     Slime_State,
    on_ground: bool,
    uid:       u32,
    pos:       [3]i16,
    vel:       [3]f16,
    color:     [3]f16,
    yaw, squash, flash, freeze, bar, hp: f16,
    age:       f32, // grows for good: kept whole
    level:     u8,
}

Net_Enemy :: struct #packed {
    index:     u8,
    kind:      Enemy_Kind,
    state:     Enemy_State,
    swing:     Swing,
    on_ground: bool,
    uid:       u32,
    pos:       [3]i16,
    vel:       [3]f16,
    tint:      [3]f16,
    yaw, timer, flash, freeze, bar, hp, death, rising, speed: f16,
    walk_phase, age: f32, // grow for good: kept whole
    level:     u8,
}

player_pack :: proc(p: Player) -> (n: Net_Player) {
    if p.active    { n.flags += {.Active} }
    if p.on_ground { n.flags += {.On_Ground} }
    if p.fly_mode  { n.flags += {.Fly_Mode} }
    if p.sneaking  { n.flags += {.Sneaking} }
    if p.sprinting { n.flags += {.Sprinting} }
    if p.sword     { n.flags += {.Sword} }
    if p.gliding   { n.flags += {.Gliding} }
    if p.blocking  { n.flags += {.Blocking} }
    if p.torch     { n.flags += {.Torch} }
    if p.climbing  { n.flags += {.Climbing} }
    if p.channeling { n.flags += {.Channeling} }
    if p.conjuring { n.flags += {.Conjuring} }
    n.reach = la.array_cast(p.reach - p.pos, f16)
    n.reach_k, n.raise = f16(p.reach_k), f16(p.raise)
    n.pos = p.pos
    n.velocity = la.array_cast(p.velocity, f16)
    n.yaw, n.pitch = f16(wrap_angle(p.yaw, 360)), f16(p.pitch)
    for v, i in ([3][3]f32{p.sword_pose.grip, p.sword_pose.blade, p.sword_pose.back}) {
        for c, j in v { n.sword_pose[i * 3 + j] = f16(c) }
    }
    n.swing_id = u8(p.swing_id)
    n.weapon = p.weapon
    n.glide_heading, n.glide_pitch = f16(wrap_angle(p.glide_heading, 360)), f16(p.glide_pitch)
    n.glide_bank, n.glide_unfold = f16(p.glide_bank), f16(p.glide_unfold)
    n.invuln, n.block_time = f16(p.invuln), f16(min(p.block_time, 60000))
    return
}

player_unpack :: proc(n: Net_Player) -> (p: Player) {
    p.active, p.on_ground, p.fly_mode = .Active in n.flags, .On_Ground in n.flags, .Fly_Mode in n.flags
    p.sneaking, p.sprinting, p.sword = .Sneaking in n.flags, .Sprinting in n.flags, .Sword in n.flags
    p.gliding, p.blocking, p.torch = .Gliding in n.flags, .Blocking in n.flags, .Torch in n.flags
    p.climbing, p.channeling, p.conjuring = .Climbing in n.flags, .Channeling in n.flags, .Conjuring in n.flags
    p.reach = n.pos + la.array_cast(n.reach, f32)
    p.reach_k, p.raise = f32(n.reach_k), f32(n.raise)
    p.pos = n.pos
    p.velocity = la.array_cast(n.velocity, f32)
    p.yaw, p.pitch = f32(n.yaw), f32(n.pitch)
    sp := n.sword_pose
    p.sword_pose = {
        grip  = {f32(sp[0]), f32(sp[1]), f32(sp[2])},
        blade = {f32(sp[3]), f32(sp[4]), f32(sp[5])},
        back  = {f32(sp[6]), f32(sp[7]), f32(sp[8])},
    }
    p.swing_id = u32(n.swing_id)
    p.weapon = n.weapon <= max(Weapon) ? n.weapon : .None // (untrusted)
    p.glide_heading, p.glide_pitch, p.glide_bank, p.glide_unfold = f32(n.glide_heading), f32(n.glide_pitch), f32(n.glide_bank), f32(n.glide_unfold)
    p.invuln, p.block_time = f32(n.invuln), f32(n.block_time)
    return
}

// A monster's feet, as an offset from `origin`.
@(private="file")
offset_pack :: proc(pos: [3]f32, origin: [3]i32) -> (o: [3]i16) {
    for c, i in pos {
        o[i] = i16(clamp(math.round((c - f32(origin[i])) * MONSTER_POS_SCALE), -32767, 32767))
    }
    return
}

@(private="file")
offset_unpack :: proc(o: [3]i16, origin: [3]i32) -> [3]f32 {
    return la.array_cast(origin, f32) + la.array_cast(o, f32) / MONSTER_POS_SCALE
}

slime_pack :: proc(index: int, sl: ^Slime, origin: [3]i32) -> Net_Slime {
    return {
        index = u8(index), size = sl.size, state = sl.state, on_ground = sl.on_ground, uid = sl.uid,
        pos = offset_pack(sl.pos, origin), vel = la.array_cast(sl.vel, f16), color = la.array_cast(sl.color, f16),
        yaw = f16(wrap_angle(sl.yaw, 2 * math.PI)), squash = f16(sl.squash), flash = f16(sl.flash),
        freeze = f16(sl.freeze), bar = f16(sl.bar), hp = f16(sl.hp), age = sl.age, level = sl.level,
    }
}

slime_unpack :: proc(n: Net_Slime, origin: [3]i32) -> Msg_Slime_View {
    return {
        index = n.index, size = n.size, state = n.state, on_ground = n.on_ground, uid = n.uid,
        pos = offset_unpack(n.pos, origin), vel = la.array_cast(n.vel, f32), color = la.array_cast(n.color, f32),
        yaw = f32(n.yaw), squash = f32(n.squash), flash = f32(n.flash), freeze = f32(n.freeze),
        bar = f32(n.bar), hp = f32(n.hp), age = n.age, level = n.level,
    }
}

enemy_pack :: proc(index: int, e: ^Enemy, origin: [3]i32) -> Net_Enemy {
    return {
        index = u8(index), kind = e.kind, state = e.state, swing = e.swing, on_ground = e.on_ground, uid = e.uid,
        pos = offset_pack(e.pos, origin), vel = la.array_cast(e.vel, f16), tint = la.array_cast(e.tint, f16),
        yaw = f16(wrap_angle(e.yaw, 2 * math.PI)), timer = f16(e.timer), flash = f16(e.flash), freeze = f16(e.freeze),
        bar = f16(e.bar), hp = f16(e.hp), death = f16(e.death), rising = f16(e.rising), speed = f16(e.speed),
        walk_phase = e.walk_phase, age = e.age, level = e.level,
    }
}

enemy_unpack :: proc(n: Net_Enemy, origin: [3]i32) -> Msg_Enemy_View {
    return {
        index = n.index, kind = n.kind, state = n.state, swing = n.swing, on_ground = n.on_ground, uid = n.uid,
        pos = offset_unpack(n.pos, origin), vel = la.array_cast(n.vel, f32), tint = la.array_cast(n.tint, f32),
        yaw = f32(n.yaw), timer = f32(n.timer), flash = f32(n.flash), freeze = f32(n.freeze), bar = f32(n.bar),
        hp = f32(n.hp), death = f32(n.death), rising = f32(n.rising), speed = f32(n.speed),
        walk_phase = n.walk_phase, age = n.age, level = n.level,
    }
}

// a in [0, turn).
@(private="file")
wrap_angle :: proc(a, turn: f32) -> f32 {
    r := math.mod(a, turn)
    return r < 0 ? r + turn : r
}
