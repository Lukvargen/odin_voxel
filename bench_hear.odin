package main

import "core:fmt"

// `bench hear`: what we hear of another player, with the sounds counted
// (audio is off in benches: bench_heard). On a stone floor up in the air,
// another player walks past, jumps and lands, draws its sword and opens
// its glider; then edits arrive from it as from the server: a block
// placed near us, one broken, a door swung (its own sound: none here), one
// far off (not heard). Prints what was heard of each.
bench_hear: bool

bench_hear_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    sx, sz := int(cam.pos.x), int(cam.pos.z)
    fy := surface_height_at(sx, sz) + 30 // where feet stand
    {
        dirty: map[int]bool
        changed: [dynamic][3]int
        for x in sx - 12 ..= sx + 12 {
            for z in sz - 4 ..= sz + 30 {
                for y in fy - 1 ..< fy + 8 {
                    edit_sphere(gs, {x, y, z}, y < fy ? .Stone : .Air, &dirty, &changed, 0)
                }
            }
        }
        light_on_edit(gs, changed[:])
        for slot in dirty { gpu_sync_slot(gs, slot) }
        delete(dirty)
        delete(changed)
    }
    cam.fly_mode = true
    cam.pos = {f32(sx) + 0.5, f32(fy) + PLAYER_EYE_HEIGHT, f32(sz) + 0.5}
    audio.ear_pos = cam.pos

    heard: [Sound]int
    bench_heard = &heard
    defer bench_heard = nil
    ok_all := true
    check :: proc(ok_all: ^bool, what: string, ok: bool) {
        fmt.printf("hear: %-46s %s\n", what, ok ? "ok" : "FAILED")
        if !ok { ok_all^ = false }
    }
    steps :: proc(h: ^[Sound]int) -> (n: int) {
        for s in Sound.Step_Grass ..= Sound.Step_Ice { n += h[s] }
        return
    }

    // Another player, as the client draws it (o.latest), stepped a frame
    // at a time.
    DT :: f32(1.0 / 60)
    o := &gs.net.others[1]
    o^ = {active = true}
    p := &o.latest
    p^ = {active = true, pos = {f32(sx) + 3.5, f32(fy) + PLAYER_EYE_HEIGHT, f32(sz) + 2}, on_ground = true}
    frame :: proc(gs: ^Game_State, p: ^Player) {
        p.pos += p.velocity * DT
        gs.net.others[1].pos = p.pos
        others_sounds(gs, DT)
    }

    // Walking 3 s at walking speed.
    p.velocity = {0, 0, WALK_SPEED}
    for _ in 0 ..< 180 { frame(gs, p) }
    n := steps(&heard)
    check(&ok_all, fmt.tprintf("walking 3 s: footsteps (%d)", n), n >= 5 && n <= 14)
    heard = {}

    // A jump: off the ground going up, then down onto it hard.
    p.on_ground, p.velocity = false, {0, JUMP_SPEED, 0}
    frame(gs, p)
    check(&ok_all, "a jump pushes off", heard[.Jump] == 1)
    p.velocity = {0, -15, 0}
    for _ in 0 ..< 5 { frame(gs, p) }
    p.on_ground, p.velocity = true, {}
    frame(gs, p)
    check(&ok_all, "...and lands", heard[.Land] == 1)
    heard = {}

    // Standing still: nothing. Then the sword out, the glider open.
    for _ in 0 ..< 60 { frame(gs, p) }
    check(&ok_all, "standing still is quiet", steps(&heard) == 0 && heard[.Land] == 0)
    p.sword = true
    frame(gs, p)
    check(&ok_all, "drawing its sword", heard[.Sword_Draw] == 1)
    p.gliding, p.on_ground = true, false
    frame(gs, p)
    check(&ok_all, "opening its glider", heard[.Glider_Open] == 1)
    heard = {}

    // Gone and back far away (a teleport, a rejoin): no landing, no steps.
    o.active = false
    frame(gs, p)
    o.active = true
    p.gliding, p.on_ground = false, true
    p.pos += {200, 0, 0}
    frame(gs, p)
    check(&ok_all, "coming back far off makes no sound", steps(&heard) == 0 && heard[.Land] == 0 && heard[.Glider_Close] == 0)
    o^ = {}

    // Our own footsteps (the same body sounds, played in the head).
    heard = {}
    cam.fly_mode, cam.on_ground, cam.velocity, cam.yaw = false, true, {}, 0
    for _ in 0 ..< 180 {
        camera_update(cam, gs, 0, 0, DT, true, false, false, false, false, false, false, false)
        player_sounds(gs, DT)
    }
    n = steps(&heard)
    check(&ok_all, fmt.tprintf("our own walking 3 s: footsteps (%d)", n), n >= 5 && n <= 14)
    cam.fly_mode = true
    cam.pos = {f32(sx) + 0.5, f32(fy) + PLAYER_EYE_HEIGHT, f32(sz) + 0.5}

    // Edits from another player, as the server passes them on.
    edit :: proc(gs: ^Game_State, heard: ^[Sound]int, items: []Msg_Voxel) -> int {
        m: Msg_Voxels
        for v in items {
            m.items[m.count] = v
            m.count += 1
        }
        heard^ = {}
        audio.last_edit = -1 // our own last edit long ago
        clear(&gs.loop.to_client)
        msg_put(&gs.loop.to_client, .Voxels, m)
        client_receive(gs, 0)
        n := 0
        for c in heard { n += c }
        return n
    }
    near := [3]i32{i32(sx) + 2, i32(fy), i32(sz) + 3}
    n = edit(gs, &heard, {{pos = near, block = u8(Block_Type.Stone)}})
    check(&ok_all, "a block placed near us is heard", n > 0 && heard[.Place] == 1)
    n = edit(gs, &heard, {{pos = near, block = 0}})
    check(&ok_all, "...and broken", n > 0 && heard[.Dig_Stone] == 1)
    d := Door{facing = 2}
    _ = edit(gs, &heard, {{pos = near, block = door_encode(d)}})
    d.open = true
    n = edit(gs, &heard, {{pos = near, block = door_encode(d)}})
    check(&ok_all, "a door swung isn't an edit's sound (Door_Swing is)", n == 0)
    far := [3]i32{i32(sx) + 100, i32(fy), i32(sz)}
    n = edit(gs, &heard, {{pos = far, block = u8(Block_Type.Stone)}})
    check(&ok_all, "an edit far off isn't heard", n == 0)

    fmt.println(ok_all ? "hear: all ok" : "hear: SOME FAILED")
}
