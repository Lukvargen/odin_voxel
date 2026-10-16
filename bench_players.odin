package main

import "core:fmt"
import "core:math"

// `bench players [dir]`: other players as this client draws them (as if
// heard from over the network), a few steps ahead on open plains: one
// standing, one walking with its sword drawn, one gliding toward the
// camera; each tinted by its slot. Writes players.bmp.
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
        o^ = {active = true, latest = p, pos = p.pos, anim = {body_yaw = -math.to_radians(p.yaw)}}
    }
    // Standing, facing the camera.
    put(&others[1], {active = true, pos = eye_at(gs, x - 2, z + 6), yaw = 180, on_ground = true})
    // Walking across, sword drawn, mid-stride.
    put(&others[2], {active = true, pos = eye_at(gs, x + 2, z + 7), yaw = 270, velocity = {-4, 0, 0}, on_ground = true, sword = true})
    others[2].anim.amp, others[2].anim.walk_phase = 0.9, 1.2
    // Gliding in toward the camera, banking.
    glide := cam.pos + {0, 4, 10}
    put(&others[3], {active = true, pos = glide, yaw = 180, velocity = {0, -1, -9},
        gliding = true, glide_heading = 180, glide_pitch = -0.08, glide_bank = 0.35, glide_unfold = 1})

    bench_measure(gs)
    path := fmt.tprintf("%s/players.bmp", bench_shot_dir)
    bench_screenshot(gs, path)
    fmt.printf("bench players: wrote %s\n", path)
    others^ = {}
}
