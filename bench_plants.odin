package main

import "core:fmt"

// `bench plants [dir]`: up in the air on a grass floor, a row of each
// plant to look at close (by day, and at night for the glowing ones), then
// a meadow packed with them, timed from a low look across it (rays crossing
// many plant voxels: their worst case) and from above. With a dir, shots.
bench_plants: bool

bench_plants_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    day_set_hour(gs, 15, settle = true)
    cam := &gs.camera
    cam.fly_mode = true
    held := gs.selected_block
    ox, sz := int(cam.pos.x), int(cam.pos.z)
    fy := surface_height_at(ox, sz) + 40 // where plants stand

    // A grass floor with open air over it; `plant(x, z)` decides what grows.
    lay :: proc(gs: ^Game_State, ox, sz, fy, w, d: int, plant: proc(x, z: int) -> Block_Type) {
        dirty: map[int]bool
        changed: [dynamic][3]int
        for x in ox - w ..= ox + w {
            for z in sz - 4 ..= sz + d {
                for y in fy - 1 ..< fy + 8 {
                    b := Block_Type.Air
                    if y < fy { b = .Grass }
                    if y == fy { b = plant(x - ox, z - sz) }
                    edit_sphere(gs, {x, y, z}, b, &dirty, &changed, 0)
                }
            }
        }
        light_on_edit(gs, changed[:])
        for slot in dirty { gpu_sync_slot(gs, slot) }
        delete(dirty)
        delete(changed)
    }
    shot :: proc(gs: ^Game_State, name: string) {
        if bench_shot_dir == "" { return }
        entities_update(gs, 0)
        flush_gpu_uploads(gs)
        for _ in 0 ..< 3 { gpu_render(gs) }
        bench_screenshot(gs, fmt.tprintf("%s/plants_%s.bmp", bench_shot_dir, name))
    }

    // Close: a row of each kind, two apart, three deep.
    KINDS :: [5]Block_Type{.Mushroom, .Glow_Mushroom, .Flower, .Fern, .Tall_Grass}
    lay(gs, ox, sz, fy, 8, 10, proc(x, z: int) -> Block_Type {
        kinds := KINDS
        k := (x + 5) / 2
        if (x + 5) % 2 != 0 || k < 0 || k >= len(kinds) || z < 2 || z > 4 { return .Air }
        return kinds[k]
    })
    cam.pos = {f32(ox) + 0.5, f32(fy) + 1.4, f32(sz) + 0.3}
    cam.yaw, cam.pitch = 0, -24
    shot(gs, "close")
    day_set_hour(gs, 23, settle = true)
    shot(gs, "close_night")
    // A torch in hand among them: shadows the plants' shapes, not blocks.
    gs.selected_block = .Torch
    cam.pos = {f32(ox) + 0.5, f32(fy) + 1.3, f32(sz) + 1.6}
    shot(gs, "torch")
    gs.selected_block = held
    day_set_hour(gs, 15, settle = true)
    // Right up to a mushroom (the first row's), for its edges.
    cam.pos = {f32(ox) - 4.5, f32(fy) + 0.9, f32(sz) + 1.2}
    cam.yaw, cam.pitch = 0, -25
    shot(gs, "mushroom")
    // Closer still, on the mushrooms and the flowers.
    cam.pos = {f32(ox) - 1.5, f32(fy) + 1.0, f32(sz) + 1.0}
    cam.yaw, cam.pitch = 0, -30
    shot(gs, "closer")

    // A torch in hand over a thick patch of grass and ferns: the torch's
    // rays to the ground cross several plant voxels (which used to shade
    // as whole blocks, darkening the ground in block-shaped wedges).
    lay(gs, ox, sz, fy, 10, 14, proc(x, z: int) -> Block_Type {
        h := u32(x * 73856093) ~ u32(z * 19349663)
        h = (h ~ (h >> 13)) * 0x5bd1e995
        if z < 1 || (h >> 9) % 10 < 4 { return .Air }
        return (h >> 5) % 3 == 0 ? .Fern : .Tall_Grass
    })
    day_set_hour(gs, 23, settle = true)
    gs.selected_block = .Torch
    cam.pos = {f32(ox) + 0.5, f32(fy) + PLAYER_EYE_HEIGHT, f32(sz) - 0.5}
    cam.yaw, cam.pitch = 0, -35
    shot(gs, "torch_field")
    gs.selected_block = held
    day_set_hour(gs, 15, settle = true)

    // The meadow: every voxel a plant, a mix of the four kinds.
    W, D :: 40, 80
    lay(gs, ox, sz, fy, W, D, proc(x, z: int) -> Block_Type {
        h := u32(x * 73856093) ~ u32(z * 19349663)
        h = (h ~ (h >> 13)) * 0x5bd1e995
        kinds := [4]Block_Type{.Flower, .Fern, .Mushroom, .Glow_Mushroom}
        return kinds[(h >> 7) % 4]
    })
    cam.pos = {f32(ox) + 0.5, f32(fy) + 1.2, f32(sz) - 3}
    cam.yaw, cam.pitch = 0, -6
    fmt.printf("plants: meadow, low across  %6.2f ms\n", bench_measure(gs))
    shot(gs, "meadow_low")
    cam.pos.y = f32(fy) + 25
    cam.pitch = -50
    fmt.printf("plants: meadow, from above  %6.2f ms\n", bench_measure(gs))
    shot(gs, "meadow_above")
}
