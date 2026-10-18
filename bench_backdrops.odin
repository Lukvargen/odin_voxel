package main

import "core:fmt"
import "core:os"
import "core:strings"
import SDL "vendor:sdl3"
import stbi "vendor:stb/image"

// `bench backdrops [dir]`: renders the main menu's backdrops, views of the
// game's own world at 1920x1080, as JPGs (default resources/menu/, where the
// menu loads them: menu_backdrops_load). Rerun it when the look changes.
bench_backdrops: bool
bench_backdrop_survey: bool // `survey`: candidate views of every biome instead

BACKDROP_W :: 1920
BACKDROP_H :: 1080

Backdrop_View :: struct {
    name:  string,
    biome: Biome,
    yaw, pitch: f32,
    back:  f32, // stood this far back from the biome's middle, looking at it
    up:    f32, // above the ground there (and most of what's between)
    hour:  f32,
}

BACKDROP_VIEWS :: [?]Backdrop_View{
    {"badlands", .Badlands,  270, -10, 70, 30, 16.8},
    {"savanna",  .Savanna,   90,  -10, 70, 30, 16.8},
    {"snowy",    .Snowy,     270, -10, 70, 30, 16.8},
    {"peaks",    .Peaks,     270, -10, 70, 30, 16.8},
    {"coast",    .Plains,    180, -10, 70, 30, 16.8},
}

bench_backdrops_run :: proc(gs: ^Game_State) {
    dir := bench_shot_dir != "" ? bench_shot_dir : "resources/menu"
    _ = os.make_directory_all(dir)
    _ = SDL.SetWindowSize(gs.window, BACKDROP_W, BACKDROP_H)
    _ = SDL.SyncWindow(gs.window)
    gpu_fit_render_size(gs)
    if gs.render_w != BACKDROP_W || gs.render_h != BACKDROP_H {
        fmt.printf("backdrops: rendering at %dx%d (the window wouldn't grow)\n", gs.render_w, gs.render_h)
    }
    gs.entities_enabled = false
    entities_update(gs, 0)
    cam := &gs.camera
    cam.fly_mode = true
    cam.fov = 70
    shoot :: proc(gs: ^Game_State, v: Backdrop_View, path: string) {
        cam := &gs.camera
        path := strings.clone(path) // bench_teleport frees the temp allocator
        defer delete(path)
        x, z, found := bench_find_biome(v.biome)
        if !found { fmt.printf("backdrops: no %v found\n", v.biome); return }
        // Stand back from the middle of the biome, looking at it, above
        // whatever is between.
        fwd := camera_forward(Camera{yaw = v.yaw, pitch = 0})
        at := [3]f32{f32(x) + 0.5, 0, f32(z) + 0.5} - fwd * v.back
        top := f32(surface_height_at(x, z))
        for k in 0 ..= 8 {
            q := at + fwd * v.back * f32(k) / 8
            top = max(top, f32(surface_height_at(int(q.x), int(q.z))))
        }
        at.y = max(f32(surface_height_at(int(at.x), int(at.z))), top * 0.6 + f32(surface_height_at(int(at.x), int(at.z))) * 0.4) + v.up
        bench_teleport(gs, at)
        bench_clear_view(gs)
        cam.yaw, cam.pitch = v.yaw, v.pitch
        day_set_hour(gs, v.hour, settle = true)
        bench_measure(gs) // many frames: the bounce light settles
        pixels := bench_frame_pixels(gs)
        defer delete(pixels)
        if stbi.write_jpg(strings.clone_to_cstring(path, context.temp_allocator), gs.render_w, gs.render_h, 4, raw_data(pixels), 88) == 0 {
            fmt.eprintln("backdrops: couldn't write", path)
        } else {
            fmt.printf("backdrops: %s (%v at %d,%d)\n", path, v.biome, x, z)
        }
        free_all(context.temp_allocator)
    }
    if bench_backdrop_survey {
        // Candidates: every biome worth a look, four ways.
        for b in ([]Biome{.Forest, .Mountains, .Peaks, .Beach, .Taiga, .Savanna, .Badlands, .Snowy, .Plains}) {
            for yaw in ([]f32{0, 90, 180, 270}) {
                shoot(gs, {biome = b, yaw = yaw, pitch = -10, back = 70, up = 30, hour = 16.8}, fmt.tprintf("%s/%v_%d.jpg", dir, b, int(yaw)))
            }
        }
        return
    }
    views := BACKDROP_VIEWS
    for v in views { shoot(gs, v, fmt.tprintf("%s/%s.jpg", dir, v.name)) }
}
