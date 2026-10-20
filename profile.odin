package main

import "core:fmt"
import "core:sync"
import "core:time"

// Lightweight cross-thread profiler. Each zone accumulates total nanoseconds
// and a call count across all worker threads. Zero overhead when not timing.

Profile_Zone :: enum {
    Terrain_Noise,   // terrain samples for a column (terrain.odin)
    Terrain_Fill,    // 3D voxel fill + 3D stone noise
    Tree_Scan,       // tree_at scan loop
    Tree_Generate,   // generate_tree calls
    Integrate,       // main-thread column integrate (scan+pool+dirty mark)
    GPU_Upload,      // main-thread voxel brick + slot table staging (transfer + copy pass)
    Upload_All,      // whole flush_gpu_uploads incl. light, far and the submit
    Light_Column,    // worker: sky light flood fill for a new column
    Light_Stitch,    // main thread: light exchange with neighbour columns
    Far_Tile,        // worker: far terrain tile summary (far.odin)
    Ent_AI,          // entities_update: fox/bird movement
    Ent_Birds,       // birds_manage (about once a second)
    Ent_Fish,        // fish_manage (about once a second)
    Ent_Build,       // posing parts + BVH
    Ent_Upload,      // entity buffer upload
    Glider,          // glider_update (flight physics + air sampling)
}

@(private="file") prof_ns:    [Profile_Zone]i64
@(private="file") prof_count: [Profile_Zone]i64

profile_add :: proc(zone: Profile_Zone, start: time.Tick) {
    ns := time.tick_since(start)
    sync.atomic_add(&prof_ns[zone],    i64(ns))
    sync.atomic_add(&prof_count[zone], 1)
}

profile_reset :: proc() {
    for z in Profile_Zone {
        sync.atomic_store(&prof_ns[z], 0)
        sync.atomic_store(&prof_count[z], 0)
    }
}

profile_dump :: proc(label: string) {
    fmt.printf("=== Profile: %s ===\n", label)
    for z in Profile_Zone {
        ns := sync.atomic_load(&prof_ns[z])
        c  := sync.atomic_load(&prof_count[z])
        if c == 0 { continue }
        ms     := f64(ns) / 1_000_000.0
        avg_us := f64(ns) / f64(c) / 1_000.0
        fmt.printf("  %-16v  total %8.1f ms   calls %7d   avg %7.2f us\n",
            z, ms, c, avg_us)
    }
}

// Where a frame's time goes on the main thread: the F3 panel's "cpu" line,
// and every second on the terminal with the `perf` argument. Present waits
// for vsync and for the GPU to catch up, so it's slack, not work.
Frame_Phase :: enum {
    Input,    // events, the camera, combat
    Server,   // the server's step and what it sent back
    Fx,       // effects and views
    Stream,   // chunks, far tiles and light stitching taken in
    Edits,    // building, the spell, felling
    Upload,   // flush_gpu_uploads
    Entities, // posing and uploading the entities
    Audio,
    Render,   // the GPU passes recorded and submitted
    UI,       // the HUD laid out and drawn
    Present,
}

frame_phase_ms:    [Frame_Phase]f32 // average a frame over the last second
frame_phase_worst: [Frame_Phase]f32 // the worst frame in it
frame_cpu_worst:   f32              // the worst frame's work (all but Present)
frame_perf_print:  bool             // `perf`: print them each second

@(private="file") phase_t:      time.Tick
@(private="file") phase_frame0: time.Tick
@(private="file") phase_since:  time.Tick
@(private="file") phase_ns:     [Frame_Phase]i64
@(private="file") phase_max:    [Frame_Phase]i64
@(private="file") phase_cpu_max: i64
@(private="file") phase_frames: int
@(private="file") phase_wait:   i64 // this frame's Present

frame_phase_begin :: proc() {
    phase_t = time.tick_now()
    phase_frame0 = phase_t
    if phase_since == {} { phase_since = phase_t }
}

// The time since the last mark goes to phase p.
frame_phase :: proc(p: Frame_Phase) {
    now := time.tick_now()
    d := i64(time.tick_diff(phase_t, now))
    phase_ns[p] += d
    phase_max[p] = max(phase_max[p], d)
    if p == .Present { phase_wait = d }
    phase_t = now
}

frame_phase_end :: proc() {
    phase_cpu_max = max(phase_cpu_max, i64(time.tick_diff(phase_frame0, phase_t)) - phase_wait)
    phase_wait = 0
    phase_frames += 1
    if time.duration_seconds(time.tick_since(phase_since)) < 1 { return }
    n := f32(max(phase_frames, 1))
    for p in Frame_Phase {
        frame_phase_ms[p]    = f32(phase_ns[p]) / 1e6 / n
        frame_phase_worst[p] = f32(phase_max[p]) / 1e6
    }
    frame_cpu_worst = f32(phase_cpu_max) / 1e6
    if frame_perf_print {
        work: f32
        for p in Frame_Phase { if p != .Present { work += frame_phase_ms[p] } }
        fmt.printf("perf: %5.1f fps  work %5.2f ms (worst frame %5.2f)  present %5.2f |", n / f32(time.duration_seconds(time.tick_since(phase_since))),
            work, frame_cpu_worst, frame_phase_ms[.Present])
        for p in Frame_Phase {
            if p == .Present || frame_phase_worst[p] < 0.05 { continue }
            fmt.printf(" %v %.2f/%.2f", p, frame_phase_ms[p], frame_phase_worst[p])
        }
        fmt.println()
    }
    phase_ns, phase_max, phase_cpu_max, phase_frames = {}, {}, 0, 0
    phase_since = time.tick_now()
}
