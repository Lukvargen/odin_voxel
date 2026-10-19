package main

import la "core:math/linalg"
import "core:math/rand"

// Monster levels. A slime or an enemy gets its level where it spawns
// (monster_level): it rises slowly with the distance from the middle of
// the world (where you start), and each biome adds its own (the plains and
// the forest are gentle, the mountains and the peaks hard), with a little
// chance on top; the night and a landmark's guards add more (their spawns).
// The level scales its health and its blows (level_hp, level_damage). The
// player doesn't scale them: what you make (better weapons) is what lets
// you go further. All of it goes through monster_level, to be tuned there.

MONSTER_LEVEL_MAX :: 40
POISE_RESET       :: f32(2.5) // seconds without a blow and a monster's poise is whole again
LEVEL_DISTANCE    :: f32(600) // voxels (400 m) out from the middle per level

// What a biome adds to the level of what lives there.
biome_level :: proc(b: Biome) -> int {
    switch b {
    case .Ocean, .Beach, .River, .Plains, .Forest: return 0
    case .Savanna, .Taiga, .Desert:                return 1
    case .Snowy, .Badlands, .Mountains:            return 2
    case .Peaks:                                   return 3
    }
    return 0
}

// The level of a monster spawning at pos (extra: the night, a guard).
monster_level :: proc(pos: [3]f32, extra := 0) -> u8 {
    b := terrain_at(int(pos.x), int(pos.z)).biome
    lv := 1 + int(la.length(pos.xz) / LEVEL_DISTANCE) + biome_level(b) + extra
    if rand.float32() < 0.3 { lv += 1 } // now and then one a little tougher
    return u8(clamp(lv, 1, MONSTER_LEVEL_MAX))
}

// How much tougher and harder-hitting a level is than level 1.
level_hp     :: proc(lv: u8) -> f32 { return 1 + 0.3 * f32(max(lv, 1) - 1) }
level_damage :: proc(lv: u8) -> f32 { return 1 + 0.12 * f32(max(lv, 1) - 1) }

slime_max_hp :: proc(sl: ^Slime) -> f32 { return SLIME_KINDS[sl.size].hp * level_hp(sl.level) }
enemy_max_hp :: proc(e: ^Enemy) -> f32 { return ENEMY_SPECS[e.kind].hp * level_hp(e.level) }

// Sets a fresh monster's level, at full health for it.
slime_set_level :: proc(sl: ^Slime, lv: u8) {
    sl.level = lv
    sl.hp = slime_max_hp(sl)
}

enemy_set_level :: proc(e: ^Enemy, lv: u8) {
    e.level = lv
    e.hp = enemy_max_hp(e)
}
