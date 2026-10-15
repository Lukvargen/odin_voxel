package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"

// `bench water [hour=h] [dir]`: GPU cost of world reflections in water and of
// cumulus shadows on the ground. Each view is measured with the effect off
// (ent_debug 8 / 16) and on, alternating twice so clock swings hit both;
// screenshots of both go to dir. Entities off so shots compare across builds.
bench_water: bool

bench_water_run :: proc(gs: ^Game_State) {
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true

    // Both effects at spawn, as the plain bench sees it (little water).
    spawn := cam.pos
    surf := f32(surface_height_at(int(spawn.x), int(spawn.z)))
    for v in ([]struct { name: string, height, pitch: f32 }{{"horizon", 2, -5}, {"vista", 45, -25}}) {
        cam.pos = {spawn.x, surf + v.height, spawn.z}
        cam.yaw, cam.pitch = 30, v.pitch
        bench_water_ab(gs, fmt.tprintf("both, spawn %s", v.name), 8 | 16, "")
    }

    // On open water, facing high ground across it.
    if wx, wz, lx, lz, ok := bench_find_shore(int(cam.pos.x), int(cam.pos.z)); ok {
        bench_teleport(gs, {f32(wx) + 0.5, SEA_LEVEL + 2.5, f32(wz) + 0.5})
        d := la.normalize([2]f32{f32(lx - wx), f32(lz - wz)})
        cam.yaw, cam.pitch = math.to_degrees(math.atan2(d.x, d.y)), -4
        fmt.printf("water: on the water at %d,%d, land at %d,%d\n", wx, wz, lx, lz)
        bench_water_ab(gs, "reflections", 8, "water")
        cam.pos.y += 30
        cam.pitch = -20
        bench_water_ab(gs, "reflections, above", 8, "water_high")
        // Toward the sun from the water: the glitter path.
        cam.pos.y -= 30
        sun := la.normalize(gs.light_dir)
        cam.yaw, cam.pitch = math.to_degrees(math.atan2(sun.x, sun.z)), -8
        bench_water_ab(gs, "reflections, sunward", 8, "water_sun")
        // From a hilltop: far water past the near region, sun glare on it.
        cam.pos.y += 60
        cam.pitch = -14
        bench_water_ab(gs, "reflections, sunward high", 8, "water_sun_high")
        cam.pos.y -= 60
    } else {
        fmt.println("water: no shore found")
    }

    // The ground under the nearest cumulus, from above and to the side.
    sky_thermals_update(gs)
    l := la.normalize(gs.light_dir)
    if gs.sky_thermal_count == 0 || l.y < 0.1 {
        fmt.println("water: no cumulus nearby or sun too low for cloud shadows")
        return
    }
    best := 0
    for th, i in gs.sky_thermals[:gs.sky_thermal_count] {
        if la.length(th.centre - cam.pos.xz) < la.length(gs.sky_thermals[best].centre - cam.pos.xz) { best = i }
    }
    th := gs.sky_thermals[best]
    // Where the shadow falls: the cloud centre (leaned downwind, as gpu.odin
    // uploads it) pushed away from the sun down to the ground.
    c := th.centre + glider_wind(gs.glider.wind_time).xz * ((CUMULUS_BASE - th.ground) * 0.08)
    s := c - l.xz / l.y * (CUMULUS_BASE + th.cloud_r * 0.6 - th.ground)
    ground := [3]f32{s.x, f32(max(surface_height_at(int(s.x), int(s.y)), SEA_LEVEL)), s.y}
    ex, ez := s.x - th.cloud_r * 2.5, s.y - th.cloud_r * 2.5
    eye := [3]f32{ex, f32(max(surface_height_at(int(ex), int(ez)), SEA_LEVEL)) + 70, ez}
    eye.y = max(eye.y, ground.y + 70)
    bench_teleport(gs, eye)
    bench_clear_view(gs)
    eye = cam.pos
    d := la.normalize(ground - eye)
    cam.yaw   = math.to_degrees(math.atan2(d.x, d.z))
    cam.pitch = math.to_degrees(math.asin(d.y))
    fmt.printf("water: cloud shadow at %.0f,%.0f (cloud r %.0f), eye %.0f %.0f %.0f\n", s.x, s.y, th.cloud_r, eye.x, eye.y, eye.z)
    bench_water_ab(gs, "cloud shadows", 16, "cloud_shadow")
}

// Off/on GPU time with ent_debug bit `bit` disabling the effect.
bench_water_ab :: proc(gs: ^Game_State, what: string, bit: int, shot: string) {
    off, on := max(f64), max(f64)
    for _ in 0 ..< 2 {
        gs.ent_debug = bit
        off = min(off, bench_measure(gs))
        gs.ent_debug = 0
        on = min(on, bench_measure(gs))
    }
    fmt.printf("  %-22s off %5.2f ms   on %5.2f ms   (%+.2f ms)\n", what, off, on, on - off)
    if bench_shot_dir == "" || shot == "" { return }
    bench_screenshot(gs, fmt.tprintf("%s/%s.bmp", bench_shot_dir, shot))
    gs.ent_debug = bit
    gpu_render(gs)
    bench_screenshot(gs, fmt.tprintf("%s/%s_off.bmp", bench_shot_dir, shot))
    gs.ent_debug = 0
}

// Deep water near (x0, z0) with at least 30 voxels of it ahead and high
// ground (15+ above the sea) within 140 of it in that direction.
bench_find_shore :: proc(x0, z0: int) -> (wx, wz, lx, lz: int, ok: bool) {
    for r := 0; r < 6000; r += 32 {
        steps := max(1, r / 16)
        for i in 0 ..< steps {
            a := f64(i) / f64(steps) * math.TAU
            px := x0 + int(math.cos(a) * f64(r)); pz := z0 + int(math.sin(a) * f64(r))
            if surface_height_at(px, pz) >= SEA_LEVEL - 4 { continue }
            for k in 0 ..< 8 {
                b := f64(k) / 8 * math.TAU
                dx, dz := math.cos(b), math.sin(b)
                found := true
                for t := 5; t <= 30; t += 5 {
                    if surface_height_at(px + int(dx * f64(t)), pz + int(dz * f64(t))) >= SEA_LEVEL - 3 { found = false; break }
                }
                if !found { continue }
                for t := 40; t <= 140; t += 10 {
                    qx, qz := px + int(dx * f64(t)), pz + int(dz * f64(t))
                    if surface_height_at(qx, qz) > SEA_LEVEL + 15 { return px, pz, qx, qz, true }
                }
            }
        }
    }
    return
}
