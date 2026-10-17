package main

import "core:fmt"

// `bench doors [dir]`: up in the air, a stone brick wall with a doorway two
// wide; a door goes in each half (door_place, as a right click would), which
// makes a double door. Walks at it shut and open, swings it, breaks one half,
// and prints what happened; with a dir, shots of it shut, open and from
// behind.
bench_doors: bool

bench_doors_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    day_set_hour(gs, 15, settle = true)
    cam := &gs.camera
    ox, sz := int(cam.pos.x), int(cam.pos.z)
    fy := surface_height_at(ox, sz) + 30 // the floor's top voxel + 1: where feet stand
    wall_z := sz + 4

    // A floor with open air over it, and the wall across it.
    {
        dirty: map[int]bool
        changed: [dynamic][3]int
        for x in ox - 7 ..= ox + 8 {
            for z in sz - 6 ..= sz + 12 {
                for y in fy - 1 ..< fy + 10 {
                    b := Block_Type.Air
                    if y < fy { b = .Stone }
                    if z == wall_z && y < fy + DOOR_PARTS + 2 && !(y < fy + DOOR_PARTS && (x == ox || x == ox + 1)) { b = .Stone_Bricks }
                    edit_sphere(gs, {x, y, z}, b, &dirty, &changed, 0)
                }
            }
        }
        light_on_edit(gs, changed[:])
        for slot in dirty { gpu_sync_slot(gs, slot) }
        delete(dirty)
        delete(changed)
    }

    ok_all := true
    check :: proc(ok_all: ^bool, what: string, ok: bool) {
        fmt.printf("doors: %-44s %s\n", what, ok ? "ok" : "FAILED")
        if !ok { ok_all^ = false }
    }
    door_of :: proc(gs: ^Game_State, p: [3]int) -> (Door, bool) {
        _, d, ok := door_at(gs, p)
        return d, ok
    }
    stand :: proc(cam: ^Camera, x, fy, z: f32, yaw: f32) {
        cam.fly_mode = false
        cam.pos = {x, fy + PLAYER_EYE_HEIGHT + 0.01, z}
        cam.velocity, cam.yaw, cam.pitch, cam.climbing, cam.on_ground = {}, yaw, 0, false, true
    }
    // Walks forward for `secs`; returns where the eye ended up.
    walk :: proc(gs: ^Game_State, secs: f32) -> [3]f32 {
        for _ in 0 ..< int(secs * 60) {
            camera_update(&gs.camera, gs, 0, 0, 1.0 / 60, true, false, false, false, false, false, false, false)
        }
        return gs.camera.pos
    }
    shot :: proc(gs: ^Game_State, name: string) {
        if bench_shot_dir == "" { return }
        entities_update(gs, 0)
        flush_gpu_uploads(gs)
        for _ in 0 ..< 3 { gpu_render(gs) }
        bench_screenshot(gs, fmt.tprintf("%s/doors_%s.bmp", bench_shot_dir, name))
    }

    // Place both doors from in front of the wall, looking at it (+z).
    gs.selected_block = .Door
    a, b := [3]int{ox, fy, wall_z}, [3]int{ox + 1, fy, wall_z}
    stand(cam, f32(ox) + 1, f32(fy), f32(sz) + 0.5, 0)
    door_place(gs, a - {0, 1, 0}, {0, 1, 0})
    door_place(gs, b - {0, 1, 0}, {0, 1, 0})
    da, oka := door_of(gs, a)
    db, okb := door_of(gs, b)
    check(&ok_all, "both doors placed, whole", oka && okb)
    check(&ok_all, "they face the wall, hinged apart (double door)", oka && okb && da.facing == 2 && db.facing == 2 && da.right != db.right)
    fmt.printf("doors: left door hinge right=%v, right door hinge right=%v\n", da.right, db.right)
    check(&ok_all, "shut doors are walls to monsters", solid_at(gs, a.x, a.y, a.z) && solid_at(gs, b.x, b.y + 2, b.z))

    stand(cam, f32(ox) + 1, f32(fy), f32(sz) + 0.5, 0)
    cam.pitch = -8
    shot(gs, "shut")

    // What right click would swing: the door under the crosshair, close by.
    stand(cam, f32(ox) + 1.5, f32(fy), f32(wall_z) - 2, 0)
    _, aimed := door_aimed(gs)
    stand(cam, f32(ox) + 1.5, f32(fy), f32(wall_z) - 30, 0)
    _, aimed_far := door_aimed(gs)
    check(&ok_all, "right click reaches a door near, not far", aimed && !aimed_far)

    // Walk into the shut door: stopped at its panel (toward us, z = wall_z).
    stand(cam, f32(ox) + 1, f32(fy), f32(wall_z) - 2.5, 0)
    p := walk(gs, 2)
    check(&ok_all, fmt.tprintf("walking into it shut stops at it (z %.2f)", p.z - f32(wall_z)),
        p.z + PLAYER_HALF_W <= f32(wall_z) + 0.01 && p.z + PLAYER_HALF_W > f32(wall_z) - 0.3)

    // Right click: both swing open.
    door_toggle(gs, a + {0, DOOR_PARTS - 1, 0}) // the top works too
    da, _ = door_of(gs, a)
    db, _ = door_of(gs, b)
    check(&ok_all, "a click opens both doors, every part", da.open && db.open)
    check(&ok_all, "open doors are a way through for monsters", !solid_at(gs, a.x, a.y, a.z))

    // The crosshair through the open doorway's middle passes the doors.
    _, _, hit_door := raycast_voxel(gs, {f32(ox) + 1, f32(fy) + 1.5, f32(wall_z) - 2}, {0, 0, 1}, 4)
    check(&ok_all, "aiming through the open doorway misses the doors", !hit_door)

    stand(cam, f32(ox) + 1, f32(fy), f32(sz) + 0.5, 0)
    cam.pitch = -8
    shot(gs, "open")

    // Walk through.
    stand(cam, f32(ox) + 1, f32(fy), f32(wall_z) - 2.5, 0)
    p = walk(gs, 2)
    check(&ok_all, fmt.tprintf("walking through it open gets past (z %.2f)", p.z - f32(wall_z)), p.z > f32(wall_z) + 2)

    // From behind, and shut again from there.
    stand(cam, f32(ox) + 1, f32(fy), f32(wall_z) + 5.5, 180)
    cam.pitch = -8
    shot(gs, "open_behind")
    door_toggle(gs, b)
    da, _ = door_of(gs, a)
    check(&ok_all, "a click shuts both again", !da.open)
    shot(gs, "shut_behind")

    // Close up of the window, the sun behind the door.
    stand(cam, f32(ox) + 0.5, f32(fy), f32(wall_z) - 1.2, 0)
    cam.pitch = 18
    shot(gs, "close")

    // Breaking the middle takes the whole door.
    build_apply(gs, sphere_region(a + {0, 1, 0}, 0), .Air, .All)
    gone := true
    for k in 0 ..< DOOR_PARTS { if block_is_door(u8(get_voxel(gs, a.x, a.y + k, a.z))) { gone = false } }
    check(&ok_all, "breaking a part takes the rest", gone)
    _, other := door_of(gs, b)
    check(&ok_all, "...and leaves the door beside it", other)

    fmt.println(ok_all ? "doors: all ok" : "doors: SOME FAILED")
    cam.fly_mode = true
}
