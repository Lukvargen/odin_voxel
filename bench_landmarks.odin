package main

import "core:fmt"
import "core:math"

// `bench landmarks [hour=h] [dir]`: the nearest landmark of each kind seen
// from ~30 voxels away, from eye level and from above, plus a cave crystal
// grotto, for judging the ruins in their light.
bench_landmarks: bool

bench_landmarks_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    for kind in Landmark_Kind.Tower ..= Landmark_Kind.Camp {
        lm, found := bench_find_landmark(kind)
        if !found { fmt.printf("landmarks: no %v found\n", kind); continue }
        fmt.printf("landmarks: %v at %d,%d (base %d)\n", kind, lm.x, lm.z, lm.base)
        for view in 0 ..< 2 {
            a := f32(lm.seed % 360)
            d: f32 = view == 0 ? 26 : 40
            p := [3]f32{f32(lm.x) + 0.5 + math.sin(math.to_radians(a)) * d, 0, f32(lm.z) + 0.5 + math.cos(math.to_radians(a)) * d}
            p.y = f32(max(surface_height_at(int(p.x), int(p.z)), lm.base)) + (view == 0 ? 6 : 34)
            bench_teleport(gs, p)
            bench_clear_view(gs)
            to := [3]f32{f32(lm.x) + 0.5, f32(lm.base) + 10, f32(lm.z) + 0.5} - cam.pos
            cam.yaw = math.to_degrees(math.atan2(to.x, to.z))
            cam.pitch = math.to_degrees(math.atan2(to.y, math.sqrt(to.x * to.x + to.z * to.z)))
            bench_measure(gs)
            bench_screenshot(gs, fmt.tprintf("%s/%v_%d.bmp", bench_shot_dir, kind, view))
        }
    }
    bench_crystal_shot(gs, 0, 0)
}

// A cave crystal near (cx, cz), seen from the nearest open spot a few
// voxels away.
bench_crystal_shot :: proc(gs: ^Game_State, cx, cz: int) {
    cam := &gs.camera
    bench_teleport(gs, {f32(cx), f32(surface_height_at(cx, cz)) + 3, f32(cz)})
    for r := 0; r < 160; r += 4 {
        for z in cz - r ..= cz + r {
            for x in cx - r ..= cx + r {
                if max(abs(x - cx), abs(z - cz)) != r { continue }
                for y in CAVE_FLOOR_Y ..< 100 {
                    if get_voxel(gs, x, y, z) != u32(Block_Type.Crystal) { continue }
                    for off in ([][3]int{{5, 2, 0}, {-5, 2, 0}, {0, 2, 5}, {0, 2, -5}, {3, 1, 3}, {-3, 1, -3}, {3, 1, -3}, {-3, 1, 3}}) {
                        p := [3]int{x, y, z} + off
                        if get_voxel(gs, p.x, p.y, p.z) != 0 || get_voxel(gs, p.x, p.y - 1, p.z) != 0 { continue }
                        cam.pos = {f32(p.x) + 0.5, f32(p.y) + 0.5, f32(p.z) + 0.5}
                        to := [3]f32{f32(x) + 0.5, f32(y) + 0.5, f32(z) + 0.5} - cam.pos
                        cam.yaw = math.to_degrees(math.atan2(to.x, to.z))
                        cam.pitch = math.to_degrees(math.atan2(to.y, math.sqrt(to.x * to.x + to.z * to.z)))
                        gs.cave_factor = cave_factor_target(gs)
                        fmt.printf("landmarks: crystal at %d,%d,%d\n", x, y, z)
                        bench_measure(gs)
                        bench_screenshot(gs, fmt.tprintf("%s/Crystal.bmp", bench_shot_dir))
                        return
                    }
                }
            }
        }
    }
    fmt.println("landmarks: no cave crystal found")
}

bench_find_landmark :: proc(kind: Landmark_Kind) -> (Landmark, bool) {
    for r in 0 ..< 40 {
        for cz in -r ..= r {
            for cx in -r ..= r {
                if max(abs(cx), abs(cz)) != r { continue }
                lm := landmark_in_cell(cx, cz)
                if lm.kind == kind { return lm, true }
            }
        }
    }
    return {}, false
}

