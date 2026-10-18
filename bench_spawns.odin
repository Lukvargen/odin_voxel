package main

import "core:fmt"
import la "core:math/linalg"

// `bench spawns`: no pictures. A player stands on the plains for 15
// simulated minutes (monsters frozen where they appear, so nothing fights);
// logs each roamer and slime that turns up and how far out, and at 5
// minutes kills them all where they stand: the calm (sim.odin) should keep
// the place empty for CALM_SECONDS.
bench_spawns: bool

bench_spawns_run :: proc(gs: ^Game_State) {
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = 0, 0 }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    gs.camera.fly_mode = false
    gs.monsters = true
    day_set_hour(gs, 13)
    gs.enemies.site_timer = 1e9 // roamers only: guards have their own clock
    dt := f32(1.0 / 30.0)
    feet := gs.camera.pos - {0, PLAYER_EYE_HEIGHT, 0}
    seen_e: [MAX_ENEMIES]bool
    seen_s: [MAX_SLIMES]bool
    n_e, n_s, after_kill := 0, 0, 0
    nearest := f32(1e9)
    killed_at := f32(300)
    for step in 0 ..< int(900 / dt) {
        t := f32(step) * dt
        client_send_input(gs); server_receive(&gs.server)
        enemies_update(gs, dt)
        slimes_update(gs, dt)
        server_flush(&gs.server, dt); client_receive(gs, dt)
        for &e, i in gs.enemies.list {
            if !e.alive { seen_e[i] = false; continue }
            e.freeze = 1
            if seen_e[i] { continue }
            seen_e[i] = true
            d := la.length((e.pos - feet).xz)
            nearest = min(nearest, d)
            n_e += 1
            if t > killed_at { after_kill += 1 }
            fmt.printf("%5.0f s  %v  %.0f blocks out\n", t, e.kind, d)
        }
        for &sl, i in gs.slimes.list {
            if !sl.alive { seen_s[i] = false; continue }
            sl.freeze = 1
            if seen_s[i] { continue }
            seen_s[i] = true
            d := la.length((sl.pos - feet).xz)
            nearest = min(nearest, d)
            n_s += 1
            if t > killed_at { after_kill += 1 }
            fmt.printf("%5.0f s  slime %v  %.0f blocks out\n", t, sl.size, d)
        }
        if step == int(killed_at / dt) {
            for &e in gs.enemies.list { if e.alive { e.alive = false; calm_mark(gs, e.pos) } }
            for &sl in gs.slimes.list { if sl.alive { sl.alive = false; calm_mark(gs, sl.pos) } }
            fmt.printf("%5.0f s  -- killed everything --\n", t)
        }
    }
    fmt.printf("spawns: %d enemies, %d slimes in 15 min; nearest %.0f blocks; %d in the %.0f s after the kill\n",
        n_e, n_s, nearest, after_kill, 900 - killed_at)
}
