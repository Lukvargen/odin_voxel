package main

import "core:fmt"
import "core:strings"
import la "core:math/linalg"
import SDL "vendor:sdl3"

// `bench shade [dir]`: a check for shading that depends on which way a face
// points (as when ambient occlusion came out mirrored on faces looking +x,
// -z and down). A structure mirror-symmetric in x and z (platform, pillar,
// walls, inside corners, pits, arches) is lit only by things that are
// symmetric too: no sun, no bounce probes, no clouds, no textures. Seen
// along an axis of symmetry, each frame must then equal its own mirror
// image; the mean and largest difference are printed, and with a dir the
// frame and a heat map of where it differs are saved.
bench_shade: bool

bench_shade_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    gs.camera.fly_mode = true
    gs.no_textures = true
    gs.gi.enabled = false
    gs.clouds_enabled = false
    gs.torch.enabled = false
    x, z, found := bench_find_biome(.Plains)
    if !found { fmt.println("shade: no plains found"); return }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 10, f32(z) + 0.5})
    g := surface_height_at(x, z)
    c := [3]int{x, g, z}
    box :: proc(gs: ^Game_State, c, lo, hi: [3]int, b: Block_Type) {
        build_apply(gs, Edit_Region{lo = c + lo, hi = c + hi}, b, .All)
    }
    // Mirrored in x and z about the centre voxel: every piece given for
    // one quarter is placed in all four.
    quad :: proc(gs: ^Game_State, c, lo, hi: [3]int, b: Block_Type) {
        for sx in ([2]int{1, -1}) { for sz in ([2]int{1, -1}) {
            a := [3]int{lo.x * sx, lo.y, lo.z * sz}
            e := [3]int{hi.x * sx, hi.y, hi.z * sz}
            box(gs, c, {min(a.x, e.x), a.y, min(a.z, e.z)}, {max(a.x, e.x), e.y, max(a.z, e.z)}, b)
        }}
    }
    box(gs, c, {-40, 1, -40}, {40, 30, 40}, .Air)
    box(gs, c, {-40, -6, -40}, {40, 0, 40}, .Stone)
    box(gs, c, {-2, 1, -2}, {2, 1, 2}, .Stone)        // platform
    box(gs, c, {0, 2, 0}, {0, 5, 0}, .Stone)          // pillar
    quad(gs, c, {5, 1, -1}, {5, 3, 1}, .Stone)        // walls on +-x...
    quad(gs, c, {-1, 1, 5}, {1, 3, 5}, .Stone)        // ...and +-z
    quad(gs, c, {8, 1, 8}, {8, 3, 11}, .Stone)        // inside corners at the diagonals
    quad(gs, c, {8, 1, 11}, {11, 3, 11}, .Stone)
    quad(gs, c, {4, -1, 4}, {4, 0, 4}, .Air)          // pits
    quad(gs, c, {14, 1, -1}, {14, 3, -1}, .Stone)     // arches: posts...
    quad(gs, c, {14, 4, -1}, {18, 4, 1}, .Stone)      // ...and roof
    quad(gs, c, {18, 1, 1}, {18, 3, 1}, .Stone)
    quad(gs, c, {-1, 1, 14}, {-1, 3, 14}, .Stone)
    quad(gs, c, {-1, 4, 14}, {1, 4, 18}, .Stone)
    quad(gs, c, {1, 1, 18}, {1, 3, 18}, .Stone)
    quad(gs, c, {6, 4, 6}, {7, 4, 7}, .Stone)         // floating slabs (undersides)
    for _ in 0 ..< 30 { flush_gpu_uploads(gs) }

    saved_sun := gs.sun_intensity
    gs.sun_intensity = 0
    defer gs.sun_intensity = saved_sun
    b := la.to_f32(c) + {0.5, 0, 0.5}
    Shot :: struct { name: string, from: [3]f32, yaw, pitch: f32 }
    shots := []Shot{
        {"top",        b + {0, 40, 0},    0,   -89.9},
        {"from_-z",    b + {0, 7, -26},   0,   -12},
        {"from_+z",    b + {0, 7, 26},    180, -12},
        {"from_-x",    b + {-26, 7, 0},   90,  -12},
        {"from_+x",    b + {26, 7, 0},    270, -12},
        {"low_-z",     b + {0, 2.2, -24}, 0,   4},
    }
    worst_all := 0.0
    for s in shots {
        gs.camera.pos = s.from
        gs.camera.yaw, gs.camera.pitch = s.yaw, s.pitch
        gs.player_chunk = {floor_div(int(s.from.x), CHUNK_VOXELS), floor_div(int(s.from.y), CHUNK_VOXELS), floor_div(int(s.from.z), CHUNK_VOXELS)}
        bench_measure(gs)
        px := bench_frame_pixels(gs)
        depth := shade_depth(gs)
        w, h := int(gs.render_w), int(gs.render_h)
        heat := make([]u8, len(px))
        sum, worst: f64
        bad, n := 0, 0
        // Pixel x looks along -(its mirror's) horizontal offset at w - x
        // (the view spans pixel 0 to w, centre w/2); only what both hit on
        // the pad counts: the sky and the land around aren't symmetric.
        for y in 0 ..< h { for xx in 1 ..< w {
            i, j := (y * w + xx) * 4, (y * w + (w - xx)) * 4
            heat[i + 3] = 255
            if depth[y * w + xx] > 60 || depth[y * w + w - xx] > 60 { continue }
            n += 1
            d := 0.0
            for ch in 0 ..< 3 { d = max(d, abs(f64(px[i + ch]) - f64(px[j + ch]))) }
            sum += d
            worst = max(worst, d)
            if d > 6 { bad += 1 }
            v := u8(min(d * 8, 255))
            heat[i], heat[i + 1], heat[i + 2], heat[i + 3] = v, v / 3, 0, 255
        }}
        mean := sum / f64(max(n, 1))
        worst_all = max(worst_all, worst)
        fmt.printf("shade: %-8s mirror difference mean %.3f, max %.0f, %d pixels over 6\n", s.name, mean, worst, bad)
        if bench_shot_dir != "" {
            bench_screenshot(gs, fmt.tprintf("%s/shade_%s.bmp", bench_shot_dir, s.name))
            surf := SDL.CreateSurfaceFrom(gs.render_w, gs.render_h, .RGBA32, raw_data(heat), gs.render_w * 4)
            _ = SDL.SaveBMP(surf, strings.clone_to_cstring(fmt.tprintf("%s/shade_%s_diff.bmp", bench_shot_dir, s.name), context.temp_allocator))
            SDL.DestroySurface(surf)
        }
        delete(px)
        delete(heat)
        delete(depth)
    }
    fmt.printf("shade: worst mirror difference %.0f\n", worst_all)
}

// The last frame's primary hit distances (depth_texture), one f32 a pixel.
@(private="file")
shade_depth :: proc(gs: ^Game_State) -> []f32 {
    w, h := u32(gs.render_w), u32(gs.render_h)
    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .DOWNLOAD, size = w * h * 4})
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)
    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    cp := SDL.BeginGPUCopyPass(cmd)
    SDL.DownloadFromGPUTexture(cp, {texture = gs.depth_texture, w = w, h = h, d = 1}, {transfer_buffer = transfer})
    SDL.EndGPUCopyPass(cp)
    fence := SDL.SubmitGPUCommandBufferAndAcquireFence(cmd)
    _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
    SDL.ReleaseGPUFence(gs.gpu_device, fence)
    src := ([^]f32)(SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false))
    out := make([]f32, w * h)
    copy(out, src[:w * h])
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)
    return out
}
