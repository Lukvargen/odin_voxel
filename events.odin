package main

import "core:math"

// Client side of the simulation's events (sim.odin): this frame's hops,
// hits and deaths become goo, damage numbers and sounds. Once per frame,
// after the simulation has run.
sim_events_play :: proc(gs: ^Game_State) {
    fx := &gs.fx
    for ev in gs.events {
        c := ev.pos
        switch ev.kind {
        case .Slime_Hop:
            w := SLIME_KINDS[ev.slime].width
            switch int(ev.amount) {
            case 0: play_at(.Slime_Hop, c, 0.35, vary(0.1) / math.sqrt(w), 10)
            case 1: play_at(.Slime_Hop, c, 0.45, vary(0.1) / math.sqrt(w), 12)
            case:   play_at(.Slime_Hop, c, 0.8, 0.8 * vary(0.05) / math.sqrt(w), 14)
            }
        case .Slime_Hit:
            add_number(fx, c + {0, slime_radius(ev.slime) + 0.4, 0}, ev.amount, ev.boosted)
            splat(fx, c, ev.color, ev.vec, 5, 0.6)
            play_at(.Slime_Hit, c, 1, vary(0.08) / math.pow(SLIME_KINDS[ev.slime].width, 0.3), 16)
        case .Slime_Pop:
            splat(fx, c, ev.color, ev.vec, 16, 1.2)
            play_at(.Slime_Pop, c, 1, vary(0.08) / math.pow(SLIME_KINDS[ev.slime].width, 0.4), 18)

        case .Enemy_Voice:
            switch ev.enemy {
            case .Skeleton: play_at(.Bone_Rattle, c, ev.amount * 0.6, vary(0.08), 16)
            case .Goblin:   play_at(.Hurt, c, ev.amount * 0.45, 1.7 * vary(0.08), 16)
            case .Orc:      play_at(.Hurt, c, ev.amount * 0.7, 0.55 * vary(0.06), 22)
            }
        case .Enemy_Swing:
            play_at(.Sword_Swing, c, 0.55, 0.75 / ENEMY_SPECS[ev.enemy].scale * vary(0.06), 14)
        case .Enemy_Struck:
            play_at(ev.enemy == .Skeleton ? .Bone_Hit : .Slam, c, 0.5, 1.3 * vary(0.06), 10)
        case .Enemy_Hit:
            sp := ENEMY_SPECS[ev.enemy]
            add_number(fx, c + {0, sp.height * 0.5, 0}, ev.amount, ev.boosted)
            splat(fx, c, sp.gore, ev.vec, 5, 0.5)
            if ev.enemy == .Skeleton {
                play_at(.Bone_Hit, c, 0.9, vary(0.08), 16)
            } else {
                play_at(.Slime_Hit, c, 0.5, 0.6 * vary(0.08), 14)
                play_at(.Hurt, c, 0.5, (ev.enemy == .Goblin ? 1.6 : 0.6) * vary(0.06), 16)
            }
        case .Enemy_Die:
            splat(fx, c, ENEMY_SPECS[ev.enemy].gore, ev.vec, 14, 1)
            if ev.enemy == .Skeleton {
                play_at(.Bone_Break, c, 1, vary(0.06), 18)
            } else {
                play_at(.Hurt, c, 0.8, (ev.enemy == .Goblin ? 1.3 : 0.45) * vary(0.05), 20)
                play_at(.Land, c, 0.7, 0.8, 14)
            }
        case .Enemy_Crumble:
            splat(fx, c, {0.7, 0.66, 0.58}, {0, 1, 0}, 10, 0.5)
            play_at(.Bone_Break, c, 0.5, 0.8, 14)
        case .Enemy_Rise:
            splat(fx, c + {0, 0.2, 0}, {0.36, 0.27, 0.18}, {0, 1, 0}, 8, 0.4)
        }
    }
    clear(&gs.events)
}
