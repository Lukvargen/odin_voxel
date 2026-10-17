package main

import "core:fmt"
import la "core:math/linalg"

// `bench torch [hour=h] [dir]`: shadows from placed torches (torch.odin), in
// a sealed stone room on a flat pad: one torch on the floor, a pillar and a
// table between it and the walls, and the same room with three torches.
// Each view with the shadows off and on, with the GPU time.
bench_torch: bool

bench_torch_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    gs.camera.fly_mode = true
    x, z, found := bench_find_biome(.Plains)
    if !found { fmt.println("torch: no plains found"); return }
    // Well above the room: blocks aren't placed inside the player.
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 30, f32(z) + 0.5})
    g := surface_height_at(x, z)
    base := [3]int{x, g, z}
    pad :: proc(gs: ^Game_State, base, lo, hi: [3]int, b: Block_Type) {
        build_apply(gs, Edit_Region{lo = base + lo, hi = base + hi}, b, .All)
    }
    pad(gs, base, {-20, 1, -20}, {20, 20, 20}, .Air)
    pad(gs, base, {-20, -4, -20}, {20, 0, 20}, .Grass)
    // Room: inside 13 x 6 x 13, walls and roof of stone.
    pad(gs, base, {-7, 0, -7}, {7, 7, 7}, .Stone)
    pad(gs, base, {-6, 1, -6}, {6, 6, 6}, .Air)
    pad(gs, base, {0, 1, 0}, {0, 1, 0}, .Torch)
    pad(gs, base, {2, 1, 2}, {2, 5, 2}, .Stone)         // pillar
    pad(gs, base, {-4, 1, 1}, {-2, 1, 3}, .Stone)       // table
    pad(gs, base, {-1, 1, -4}, {1, 3, -4}, .Stone)      // short wall
    b := la.to_f32(base)
    bench_torch_view(gs, b + {-5, 3.6, -5.5}, b + {3, 1.5, 4}, "torch_room")
    bench_torch_view(gs, b + {5.5, 3.6, -5.5}, b + {-3, 1.5, 3}, "torch_room2")
    bench_torch_view(gs, b + {0.5, 4.5, -5.5}, b + {0.5, 1, 4}, "torch_wall")
    pad(gs, base, {-5, 1, 5}, {-5, 1, 5}, .Torch)
    pad(gs, base, {5, 1, -2}, {5, 1, -2}, .Torch)
    bench_torch_view(gs, b + {-5, 3.6, -5.5}, b + {3, 1.5, 4}, "torch_room3")
}

@(private="file")
bench_torch_view :: proc(gs: ^Game_State, from, at: [3]f32, name: string) {
    d := la.normalize(at - from)
    gs.camera.pos = from
    gs.camera.yaw = la.to_degrees(la.atan2(d.x, d.z))
    gs.camera.pitch = la.to_degrees(la.asin(d.y))
    gs.player_chunk = {floor_div(int(from.x), CHUNK_VOXELS), floor_div(int(from.y), CHUNK_VOXELS), floor_div(int(from.z), CHUNK_VOXELS)}
    fmt.printf("torch: %-12s", name)
    for on in ([2]bool{false, true}) {
        gs.torch.enabled = on
        gs.torch.dirty = true
        ms := bench_measure(gs)
        fmt.printf("  %s %.2f ms", on ? "on" : "off", ms)
        if bench_shot_dir != "" { bench_screenshot(gs, fmt.tprintf("%s/%s_%s.bmp", bench_shot_dir, name, on ? "on" : "off")) }
    }
    fmt.println()
    gs.torch.enabled = true
}
