package main

import "core:fmt"
import "core:math"

// `bench climb [dir]`: on a stone floor up in the air, walk at a raised
// platform 1 to 5 blocks high, once holding Space (jumping and pulling up
// onto the ledge, ledge_climb) and once without it. Prints which get
// climbed, and how far an onlooker sees the body turn during and just after
// it (anim_climb: it should stay facing the ledge, 0 degrees); with a dir,
// shots of the 3-block pull-up along the way.
bench_climb: bool

bench_climb_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    sx, sz := int(cam.pos.x), int(cam.pos.z)
    floor_y := surface_height_at(sx, sz) + 30

    for h in 1 ..= 5 {
        for space in ([2]bool{true, false}) {
            // A floor, and past z0 + 4 a platform h blocks higher, with
            // open air over all of it.
            ox := sx + h * 16
            dirty: map[int]bool
            changed: [dynamic][3]int
            for x in ox - 3 ..= ox + 3 {
                for z in sz - 3 ..= sz + 12 {
                    top := z >= sz + 4 ? floor_y + h : floor_y
                    for y in floor_y - 1 ..< floor_y + h + 8 {
                        edit_sphere(gs, {x, y, z}, y < top ? .Stone : .Air, &dirty, &changed, 0)
                    }
                }
            }
            light_on_edit(gs, changed[:])
            for slot in dirty { gpu_sync_slot(gs, slot) }
            delete(dirty); delete(changed)

            cam.fly_mode = false
            cam.pos = {f32(ox) + 0.5, f32(floor_y) + PLAYER_EYE_HEIGHT + 0.01, f32(sz) + 0.5}
            cam.velocity, cam.yaw, cam.pitch, cam.climbing = {}, 0, -10, false
            goal := f32(floor_y + h)
            shots := bench_shot_dir != "" && h == 3 && space
            next_shot := 0
            seen := Player_Anim{} // as another player's view of it (client.odin)
            turn, old_turn: f32 = 0, 0
            after := 0
            t := 0
            for ; t < 60 * 4; t += 1 {
                going := after == 0 // up: then stand, watched
                cam.swim_up = space && going
                camera_update(cam, gs, 0, 0, 1.0 / 60, going, false, false, false, space && cam.on_ground && going, false, false, false)
                anim_step(&seen, cam.velocity, cam.yaw, false, cam.on_ground, 1.0 / 60)
                anim_climb(&seen, cam.climbing, cam.mantle.hands, cam.pos)
                turn = max(turn, abs(seen.body_yaw))
                if d := cam.mantle.hands - cam.pos; cam.climbing && d.x * d.x + d.z * d.z > 1e-4 {
                    old_turn = max(old_turn, abs(math.atan2(-d.x, d.z))) // facing the lip from where the body is
                }
                if shots && cam.climbing && next_shot < 4 && cam.mantle.t / cam.mantle.dur >= f32(next_shot) * 0.25 + 0.05 {
                    entities_update(gs, 0)
                    flush_gpu_uploads(gs)
                    for _ in 0 ..< 3 { gpu_render(gs) }
                    bench_screenshot(gs, fmt.tprintf("%s/climb_%d.bmp", bench_shot_dir, next_shot))
                    next_shot += 1
                }
                if cam.on_ground && cam.pos.y - PLAYER_EYE_HEIGHT >= goal - 0.01 { after += 1 }
                if after > 30 { break }
            }
            fmt.printf("climb: %d block%s %s Space: %s (%.2f s, feet %.2f over the floor, seen turning up to %.0f deg, %.0f facing the lip)\n",
                h, h == 1 ? " " : "s", space ? "with   " : "without",
                t < 60 * 4 ? "up" : "not up", f32(t - after) / 60, cam.pos.y - PLAYER_EYE_HEIGHT - f32(floor_y), math.to_degrees(turn), math.to_degrees(old_turn))
        }
    }
    cam.fly_mode = true
}
