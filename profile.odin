package main

import "core:fmt"
import "core:sync"
import "core:time"

// Lightweight cross-thread profiler. Each zone accumulates total nanoseconds
// and a call count across all worker threads. Zero overhead when not timing.

Profile_Zone :: enum {
    Terrain_Noise,   // grass_cache 2D noise loop
    Terrain_Fill,    // 3D voxel fill + 3D stone noise
    Tree_Scan,       // should_place_tree scan loop
    Tree_Generate,   // generate_tree calls
    Integrate,       // main-thread column integrate (scan+pool+dirty mark)
    GPU_Upload,      // main-thread flush_gpu_uploads (transfer + copy pass)
    Light_Column,    // worker: sky light flood fill for a new column
    Light_Stitch,    // main thread: light exchange with neighbour columns
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
