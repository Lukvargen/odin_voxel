package main

// The player, the monsters and the wildlife are designed in metres
// (design blocks) and live in a world built TERRAIN_SCALE blocks to the
// metre (terrain.odin): world_scale_apply turns every length, speed and
// acceleration that moves them into world blocks, at startup. Times stay,
// so everything moves as designed, just bigger: the player is some three
// blocks tall. Bodies are posed at their design size and drawn scaled
// (ent_scale_about). `scale=S` on the command line tries another size.

world_scale: f32 = 1 // world blocks per design block, once applied

world_scale_apply :: proc(s: f32) {
    if s <= 0 || world_scale != 1 { return } // once
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
    // Wildlife (entities.odin, creatures.odin, sea.odin).
    FOX_WALK_SPEED *= s
    FOX_FLEE_SPEED *= s
    FOX_FLEE_DIST *= s
    ENTITY_GRAVITY *= s
    ENTITY_MAX_FALL *= s
    BIRD_SPEED *= s
    FISH_SPAWN_MIN *= s
    FISH_SPAWN_MAX *= s
    FISH_FLEE_DIST *= s
    FISH_CRUISE *= s
    FISH_BOLT *= s
    for &k in SLIME_KINDS {
        k.width *= s
        k.hop_speed *= s
        k.hop_up *= s
        k.leap_range *= s
    }
}
