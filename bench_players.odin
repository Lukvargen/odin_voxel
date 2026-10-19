package main

import "core:fmt"
import "core:math"

// `bench players [dir]`: other players as this client draws them (as if
// heard from over the network), a few steps ahead on open plains: one
// standing, one walking with its sword drawn, one mid-swing, one gliding
// toward the camera; each tinted by its slot. Writes players.bmp.
bench_players: bool

bench_players_run :: proc(gs: ^Game_State) {
    cam := &gs.camera
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = int(cam.pos.x), int(cam.pos.z) }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5})
    x, z = bench_open_ground(gs, x, z)
    eye_at :: proc(gs: ^Game_State, x, z: int) -> [3]f32 {
        return {f32(x) + 0.5, f32(bench_ground(gs, x, z)) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5}
    }
    cam.pos = eye_at(gs, x, z)
    cam.fly_mode, cam.velocity, cam.yaw, cam.pitch = true, {}, 0, 8 // looking +z, a little up

    others := &gs.net.others
    others^ = {}
    put :: proc(o: ^Other_Player, p: Player) {
        o^ = {active = true, latest = p, pos = p.pos, anim = {body_yaw = -math.to_radians(p.yaw)}, pose = p.sword_pose}
    }
    // Standing, facing the camera, just struck (flashing red).
    put(&others[1], {active = true, pos = eye_at(gs, x - 2, z + 6), yaw = 180, on_ground = true})
    others[1].hurt = 0.8
    // Walking across, sword drawn and carried, mid-stride.
    put(&others[2], {active = true, pos = eye_at(gs, x + 2, z + 7), yaw = 270, velocity = {-4, 0, 0}, on_ground = true,
        sword = true, sword_pose = gs.combat.pose}) // the carry pose, as combat_init leaves it
    others[2].anim.amp, others[2].anim.walk_phase = 0.9, 1.2
    // Mid-swing (a finisher, posed by the combat code itself), facing the camera.
    c := &gs.combat
    saved := c^
    c.sword, c.attack = true, .Finisher
    c.attack_time = ATTACKS[.Finisher].windup + ATTACKS[.Finisher].strike * 0.5
    swing := sword_pose(gs, 0)
    c^ = saved
    put(&others[4], {active = true, pos = eye_at(gs, x + 4, z + 5), yaw = 200, on_ground = true, sword = true, sword_pose = swing})
    // Gliding in toward the camera, banking.
    glide := cam.pos + {0, 4, 10}
    put(&others[3], {active = true, pos = glide, yaw = 180, velocity = {0, -1, -9},
        gliding = true, glide_heading = 180, glide_pitch = -0.08, glide_bank = 0.35, glide_unfold = 1})

    bench_measure(gs)
    path := fmt.tprintf("%s/players.bmp", bench_shot_dir)
    bench_screenshot(gs, path)
    fmt.printf("bench players: wrote %s\n", path)

    // At night, the standing one holding a torch: it lights the ground
    // around it here too (gpu.odin hand_lights).
    hour := gs.day.hour
    day_set_hour(gs, 22, settle = true)
    others[1].latest.torch, others[1].hurt = true, 0
    ms := bench_measure(gs)
    path = fmt.tprintf("%s/players_torch.bmp", bench_shot_dir)
    bench_screenshot(gs, path)
    fmt.printf("bench players: %.2f ms with a torch in another's hand; wrote %s\n", ms, path)
    day_set_hour(gs, hour, settle = true)

    // Their hands (Body_Act), sent over the wire and back (player_pack):
    // one unweaving a block beside it, beam and all; one pulling up onto a
    // ledge, hands on the lip.
    others^ = {}
    wire :: proc(p: Player) -> Player { return player_unpack(player_pack(p)) }
    caster := eye_at(gs, x - 2, z + 6)
    put(&others[1], wire({active = true, pos = caster, yaw = 120, on_ground = true,
        channeling = true, raise = 1, reach = caster + {-3.5, -1, 1.5}, reach_k = 0.6}))
    climber := eye_at(gs, x + 3, z + 6) + {0, 0.6, 0}
    put(&others[2], wire({active = true, pos = climber, yaw = 180, climbing = true,
        reach = climber + {0, 0.4, -0.7}, reach_k = 0.35}))
    ok := others[1].latest.channeling && others[2].latest.climbing && abs(others[1].latest.reach_k - 0.6) < 0.01
    fmt.printf("bench players: casting and climbing come over the wire: %v\n", ok)
    for _ in 0 ..< 10 { entities_update(gs, 1.0 / 60.0) } // the beam's palms are found as the body is drawn
    bench_measure(gs)
    path = fmt.tprintf("%s/players_hands.bmp", bench_shot_dir)
    bench_screenshot(gs, path)
    fmt.printf("bench players: wrote %s\n", path)

    // Eye to eye: another player on the same ground, 2.5 m ahead, looking
    // back level; our view level too. Their eyes should be on the screen's
    // middle row (the body's eyes are at the camera's height).
    others^ = {}
    ahead := 2.5 * world_scale
    cam.pos = eye_at(gs, x, z)
    them := cam.pos + {0, 0, ahead}
    put(&others[1], {active = true, pos = them, yaw = 180, on_ground = true})
    cam.yaw, cam.pitch = 0, 0
    for _ in 0 ..< 10 { entities_update(gs, 1.0 / 60.0) }
    bench_measure(gs)
    path = fmt.tprintf("%s/players_eyes.bmp", bench_shot_dir)
    bench_screenshot(gs, path)
    fmt.printf("bench players: wrote %s (the middle row through their eyes)\n", path)

    // Our own hands, raised to cast, in first person (magic_add_parts).
    others^ = {}
    gs.magic.raise, gs.magic.aim = 1, cam.pos + {0, -1, 3}
    for _ in 0 ..< 10 { entities_update(gs, 1.0 / 60.0) }
    bench_measure(gs)
    path = fmt.tprintf("%s/players_cast_first.bmp", bench_shot_dir)
    bench_screenshot(gs, path)
    fmt.printf("bench players: wrote %s\n", path)
    gs.magic.raise = 0
}
