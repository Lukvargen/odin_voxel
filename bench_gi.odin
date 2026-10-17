package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"

// `bench gi [hour=h] [dir]`: the bounce-light probes (gi.odin) on scenes
// built on a flat pad: a sealed stone room on sunlit ground (must stay as
// black inside as without them), the same room with a doorway toward the
// sun, a stone roof over bright sand, and a tunnel into a stone block,
// looked out of and into. Each is drawn with the probes off, on, and the
// bounce light alone, with the frame's mean brightness and GPU time.
bench_gi: bool
// `bench gimove [hour=h]`: the same pad, but how the probes settle as
// things change instead of the shots: a doorway opened in the sealed room
// (the picture frame to frame) and a glide toward the tunnel block (how far
// from settled it is on the way), each with the listed updates (gi.odin) on
// and off.
bench_gi_move: bool

bench_gi_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    x, z, found := bench_find_biome(.Plains)
    if !found { fmt.println("gi: no plains found"); return }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 10, f32(z) + 0.5})
    g := surface_height_at(x, z)
    base := [3]int{x, g, z}
    pad :: proc(gs: ^Game_State, base, lo, hi: [3]int, b: Block_Type) {
        build_apply(gs, Edit_Region{lo = base + lo, hi = base + hi}, b, .All)
    }
    pad(gs, base, {-60, 1, -60}, {60, 40, 70}, .Air)
    pad(gs, base, {-60, -4, -60}, {60, 0, 70}, .Grass)

    // Room: walls and roof a block thick, inside 7 x 6 x 7.
    pad(gs, base, {-24, 1, -4}, {-16, 7, 4}, .Stone)
    pad(gs, base, {-23, 1, -3}, {-17, 6, 3}, .Air)
    if !bench_gi_move { bench_gi_view(gs, base, {-20.5, 1 + PLAYER_EYE_HEIGHT, -2}, {-20, 2, 3}, "room_sealed") }
    // A doorway in the wall facing the sun most.
    l := gs.light_dir
    door_lo, door_hi: [3]int
    if abs(l.x) > abs(l.z) {
        wx := l.x > 0 ? -16 : -24
        door_lo, door_hi = {wx, 1, -1}, {wx, 4, 1}
    } else {
        wz := l.z > 0 ? 4 : -4
        door_lo, door_hi = {-21, 1, wz}, {-19, 4, wz}
    }
    if bench_gi_move {
        gs.gi.show = 1
        b := la.to_f32(base)
        bench_gi_aim(gs, b + {-20.5, 1 + PLAYER_EYE_HEIGHT, -0.5}, b + {-20, 3.5, 0})
        for no_list in ([2]bool{false, true}) {
            gs.gi.no_list = no_list
            pad(gs, base, door_lo, door_hi, .Stone)
            bench_measure(gs)
            pad(gs, base, door_lo, door_hi, .Air)
            bench_gi_settle_series(gs, no_list ? "door, round only" : "door, listed")
        }
        gs.gi.no_list = false
    }
    pad(gs, base, door_lo, door_hi, .Air)
    door_c := la.to_f32(base + (door_lo + door_hi) / 2)
    room_c := la.to_f32(base + {-20, 2, 0})
    away := room_c + (room_c - door_c) * 0.7
    if !bench_gi_move {
        bench_gi_aim(gs, {away.x + 0.5, room_c.y + 0.8, away.z + 0.5}, door_c + {0.5, -0.5, 0.5})
        bench_gi_shots(gs, "room_door_out")
        bench_gi_view(gs, base, {-20.5, 1 + PLAYER_EYE_HEIGHT, -0.5}, {-20, 3.5, 0}, "room_door_up")
    }

    // A stone roof over bright sand.
    pad(gs, base, {6, 0, -16}, {40, 0, 16}, .Sand)
    pad(gs, base, {14, 6, -8}, {30, 7, 8}, .Stone)
    if !bench_gi_move { bench_gi_view(gs, base, {22.5, 2.5, -17}, {22, 4, 0}, "overhang") }

    // A tunnel into a stone block, its mouth toward -z.
    pad(gs, base, {-12, 1, 26}, {12, 20, 60}, .Stone)
    pad(gs, base, {-2, 1, 26}, {1, 4, 54}, .Air)
    if bench_gi_move {
        // Glide at 30 voxels a second (0.5 a frame at 60 fps) toward the
        // block's face from 76 voxels off (outside the grid), past it on
        // one side. At each check: the bounce light then against the same
        // view settled, flown afresh each time.
        b := la.to_f32(base)
        gs.gi.show = 1
        for no_list in ([2]bool{false, true}) {
            gs.gi.no_list = no_list
            fmt.printf("gi: glide, %-12s off settled at", no_list ? "round only" : "listed")
            for check in ([3]int{60, 100, 140}) {
                start := b + {-14, 6, -50}
                bench_gi_aim(gs, start, start + {0.3, -0.1, 1})
                bench_measure(gs)
                for _ in 0 ..< check {
                    gs.camera.pos.z += 0.5
                    flush_gpu_uploads(gs)
                    gpu_render(gs)
                }
                fly := bench_frame_pixels(gs)
                bench_measure(gs)
                still := bench_frame_pixels(gs)
                diff, worst: f64
                for i in 0 ..< len(fly) {
                    if i % 4 == 3 { continue }
                    d := abs(f64(fly[i]) - f64(still[i]))
                    diff += d
                    worst = max(worst, d)
                }
                fmt.printf("  %d voxels: %.2f (max %.0f)", check / 2, diff / f64(len(fly) / 4 * 3), worst)
                delete(fly); delete(still)
            }
            fmt.println()
        }
        gs.gi.no_list, gs.gi.show = false, 0
        return
    }
    bench_gi_view(gs, base, {-0.5, 2.6, 50}, {-0.5, 2.2, 26}, "tunnel_out")
    bench_gi_view(gs, base, {-0.5, 3.5, 16}, {-0.5, 2.5, 40}, "tunnel_in")
}

// Frames right after an edit: how the picture moves toward where it
// settles, frame by frame (mean change of a pixel, 0..255).
@(private="file")
bench_gi_settle_series :: proc(gs: ^Game_State, name: string) {
    FRAMES :: 48
    frames: [FRAMES][]u8
    for i in 0 ..< FRAMES {
        flush_gpu_uploads(gs)
        gpu_render(gs)
        frames[i] = bench_frame_pixels(gs)
    }
    bench_measure(gs)
    final := bench_frame_pixels(gs)
    mean_diff :: proc(a, b: []u8) -> f64 {
        d: f64
        for i in 0 ..< len(a) { if i % 4 != 3 { d += abs(f64(a[i]) - f64(b[i])) } }
        return d / f64(len(a) / 4 * 3)
    }
    total := mean_diff(frames[0], final)
    worst := 0.0
    near := -1
    for i in 1 ..< FRAMES {
        worst = max(worst, mean_diff(frames[i - 1], frames[i]))
        if near < 0 && mean_diff(frames[i], final) < total * 0.1 { near = i }
    }
    fmt.printf("gi: %-18s start %.1f from settled, biggest step frame to frame %.2f, within 10%% after %d frames\n", name, total, worst, near)
    fmt.printf("gi:   off settled by frame:")
    for i := 0; i < FRAMES; i += 4 { fmt.printf(" %.1f", mean_diff(frames[i], final)) }
    fmt.println()
    for f in frames { delete(f) }
    delete(final)
}

// Camera at base + from looking at base + at, then the shots.
@(private="file")
bench_gi_view :: proc(gs: ^Game_State, base: [3]int, from, at: [3]f32, name: string) {
    b := la.to_f32(base)
    bench_gi_aim(gs, b + from, b + at)
    bench_gi_shots(gs, name)
}

@(private="file")
bench_gi_aim :: proc(gs: ^Game_State, from, at: [3]f32) {
    cam := &gs.camera
    cam.pos = from
    d := la.normalize(at - from)
    cam.yaw   = math.to_degrees(math.atan2(d.x, d.z))
    cam.pitch = math.to_degrees(math.asin(d.y))
    gs.player_chunk = {floor_div(int(from.x), CHUNK_VOXELS), floor_div(int(from.y), CHUNK_VOXELS), floor_div(int(from.z), CHUNK_VOXELS)}
}

@(private="file")
bench_gi_shots :: proc(gs: ^Game_State, name: string) {
    Shot :: struct { tag: string, on: bool, show: int }
    shots := []Shot{{"off", false, 0}, {"on", true, 0}, {"gi", true, 1}, {"raw", true, 2}}
    fmt.printf("gi: %-14s", name)
    for s in shots {
        gs.gi.enabled, gs.gi.show = s.on, s.show
        ms := bench_measure(gs)
        px := bench_frame_pixels(gs)
        sum: f64
        for i := 0; i < len(px); i += 4 { sum += f64(px[i]) + f64(px[i + 1]) + f64(px[i + 2]) }
        fmt.printf("  %s %5.1f (%.2f ms)", s.tag, sum / f64(len(px) / 4 * 3), ms)
        if s.tag == "on" {
            // Flicker: how much the picture changes over half a probe cycle
            // (nothing moves; only the probes' noise does).
            for _ in 0 ..< GI_PROBES / GI_PER_FRAME / 2 { gpu_render(gs) }
            px2 := bench_frame_pixels(gs)
            diff, worst: f64
            for i in 0 ..< len(px) {
                if i % 4 == 3 { continue }
                d := abs(f64(px[i]) - f64(px2[i]))
                diff += d
                worst = max(worst, d)
            }
            fmt.printf(" [flicker %.2f, max %.0f]", diff / f64(len(px) / 4 * 3), worst)
            delete(px2)
        }
        delete(px)
        if bench_shot_dir != "" { bench_screenshot(gs, fmt.tprintf("%s/%s_%s.bmp", bench_shot_dir, name, s.tag)) }
    }
    fmt.println()
    gs.gi.enabled, gs.gi.show = true, 0
}
