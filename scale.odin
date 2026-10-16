package main

// Prototype (scale=S on the command line): the player and the monsters S
// times their size against the same voxels, as if the world were built
// from blocks 1/S as big. Lengths, speeds and accelerations all scale by S
// and times stay, so everything moves the same, just bigger: a jump is S
// times as high and takes as long. The terrain doesn't change, so hills,
// trees and caves look 1/S as big too; only for trying how a player some
// three blocks tall feels. Playing alone only: the network doesn't carry it.

world_scale: f32 = 1

world_scale_apply :: proc(s: f32) {
    if s <= 0 || s == 1 { return }
    world_scale = s
    // Moving about (camera.odin).
    PLAYER_EYE_HEIGHT *= s
    PLAYER_HALF_W *= s
    PLAYER_HEAD_ABOVE *= s
    GRAVITY *= s
    JUMP_SPEED *= s
    WALK_SPEED *= s
    FLY_SPEED *= s
    TERMINAL_VEL *= s
    SWIM_ACCEL *= s
    SWIM_UP_ACCEL *= s
    SWIM_FLOAT_EYE *= s
    SWIM_HOP_SPEED *= s
    CLIMB_SPEED *= s
    CLIMB_REACH *= s
    // Gliding: lift goes with speed squared, so its constant takes 1/S for
    // the forces to come out S times (glider.odin).
    GLIDER_GRAVITY *= s
    GLIDER_LIFT_K /= s
    GLIDER_CRASH_SPEED *= s
    // The sword (combat.odin).
    SPEED_DAMAGE_FROM = WALK_SPEED * SPRINT_FACTOR
    LUNGE_SPEED *= s
    LUNGE_RANGE *= s
    LUNGE_STOP *= s
    AIR_HIT_HOVER *= s
    RISE_SPEED *= s
    PLUNGE_MIN_HEIGHT *= s
    PLUNGE_SPEED *= s
    PLUNGE_BOUNCE *= s
    DODGE_SPEED *= s
    for &a in ATTACKS {
        a.reach *= s
        a.knock *= s
    }
    // Monsters (enemies.odin, slime.odin).
    ENEMY_GRAVITY *= s
    ENEMY_JUMP *= s
    for &e in ENEMY_SPECS {
        e.scale *= s
        e.radius *= s
        e.height *= s
        e.walk *= s
        e.run *= s
        e.reach *= s
        e.aggro *= s
        e.knock *= s
    }
    SLIME_GRAVITY *= s
    SLIME_AGGRO *= s
    SLIME_FORGET *= s
    SLIME_LEAP_UP *= s
    SLIME_LEAP_MAX *= s
    for &k in SLIME_KINDS {
        k.width *= s
        k.hop_speed *= s
        k.hop_up *= s
        k.leap_range *= s
    }
}
