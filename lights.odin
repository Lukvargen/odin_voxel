package main

import "core:math"
import SDL "vendor:sdl3"

// Point-light list for emissive blocks (torches). The CPU owns the canonical
// set (torch_voxels map, survives chunk streaming); each frame the nearest
// MAX_LIGHTS within LIGHT_CULL_RADIUS of the camera are uploaded to a small
// GPU buffer read by the tracer (direct light + shadow rays), gi_update
// (bounce injection) and the volumetric pass (fog glow).

MAX_LIGHTS        :: 32
LIGHT_RADIUS      :: f32(14.0)  // falloff window radius (voxels)
LIGHT_CULL_RADIUS :: f32(96.0)  // gather range around camera (well inside the resident ring)
LIGHT_INTENSITY   :: f32(28.0)  // premultiplied into color (HDR, inv-square falloff)
LIGHT_FADE_IN     :: f32(0.25)  // seconds: intensity ease-in on placement
LIGHT_FADE_OUT    :: f32(0.35)  // seconds: intensity ease-out after removal

// A removed torch lingers here while its light fades out — the direct light,
// GI injection, and fog halo all read the same list, so the whole lighting
// response eases out coherently instead of popping off in one frame.
Dying_Light :: struct {
    key:        [3]int,
    removed_at: f32, // seconds
}

// Matches PointLight in the shaders: two float4s per light.
Point_Light_Gpu :: struct #packed {
    pos:    [3]f32, // voxel center of the emissive block
    radius: f32,
    color:  [3]f32, // intensity-premultiplied linear HDR
    _pad:   f32,
}

LIGHT_BUF_SIZE :: MAX_LIGHTS * size_of(Point_Light_Gpu)

// Smooth per-torch flicker: two incommensurate sines with a hash-derived
// phase so neighbouring torches don't pulse in sync.
@(private="file")
light_flicker :: proc(key: [3]int, t: f32) -> f32 {
    h := u32(key[0]) * 73856093 ~ u32(key[1]) * 19349663 ~ u32(key[2]) * 83492791
    phase := f32(h & 1023) / 1024.0 * 6.2831853
    s := 0.5 + 0.5 * math.sin(t * 9.0 + phase) * math.sin(t * 5.3 + phase * 1.7)
    return 0.88 + 0.12 * s
}

// Gather the nearest torches, fill the GPU light list, upload it, and set
// gs.light_count for the frame's uniform. Called once per frame before
// gpu_render. Keeps a distance-sorted top-MAX_LIGHTS without allocating.
// Each light's intensity is scaled by a placement ease-in / removal ease-out
// so torch light never pops in a single frame.
lights_update :: proc(gs: ^Game_State) {
    Candidate :: struct { key: [3]int, d2: f32, fade: f32 }
    cands: [MAX_LIGHTS]Candidate
    n := 0
    t := f32(SDL.GetTicks()) / 1000.0

    insert_candidate :: proc(cands: ^[MAX_LIGHTS]Candidate, n: ^int, c: Candidate) {
        if n^ < MAX_LIGHTS {
            cands[n^] = c
            n^ += 1
            // bubble the new entry into place (list stays sorted by d2)
            for i := n^ - 1; i > 0 && cands[i].d2 < cands[i-1].d2; i -= 1 {
                cands[i], cands[i-1] = cands[i-1], cands[i]
            }
        } else if c.d2 < cands[MAX_LIGHTS-1].d2 {
            cands[MAX_LIGHTS-1] = c
            for i := MAX_LIGHTS - 1; i > 0 && cands[i].d2 < cands[i-1].d2; i -= 1 {
                cands[i], cands[i-1] = cands[i-1], cands[i]
            }
        }
    }

    cam := gs.camera.pos
    for key, placed_at in gs.torch_voxels {
        p := [3]f32{f32(key[0]) + 0.5, f32(key[1]) + 0.5, f32(key[2]) + 0.5}
        d := p - cam
        d2 := d.x*d.x + d.y*d.y + d.z*d.z
        if d2 > LIGHT_CULL_RADIUS * LIGHT_CULL_RADIUS { continue }
        fade := clamp((t - placed_at) / LIGHT_FADE_IN, 0.0, 1.0)
        fade = fade * fade * (3.0 - 2.0 * fade) // smoothstep ease-in
        insert_candidate(&cands, &n, {key, d2, fade})
    }

    // Dying lights: fade out, dropping entries once fully dark.
    for i := len(gs.dying_lights) - 1; i >= 0; i -= 1 {
        dl := gs.dying_lights[i]
        fade := 1.0 - (t - dl.removed_at) / LIGHT_FADE_OUT
        if fade <= 0.0 {
            unordered_remove(&gs.dying_lights, i)
            continue
        }
        fade = fade * fade * (3.0 - 2.0 * fade) // smoothstep ease-out
        p := [3]f32{f32(dl.key[0]) + 0.5, f32(dl.key[1]) + 0.5, f32(dl.key[2]) + 0.5}
        d := p - cam
        d2 := d.x*d.x + d.y*d.y + d.z*d.z
        if d2 > LIGHT_CULL_RADIUS * LIGHT_CULL_RADIUS { continue }
        insert_candidate(&cands, &n, {dl.key, d2, fade})
    }

    gs.light_count = i32(n)
    if n == 0 { return }

    lights: [MAX_LIGHTS]Point_Light_Gpu
    for i in 0 ..< n {
        key := cands[i].key
        fl := light_flicker(key, t) * cands[i].fade
        lights[i] = {
            pos    = {f32(key[0]) + 0.5, f32(key[1]) + 0.5, f32(key[2]) + 0.5},
            radius = LIGHT_RADIUS,
            color  = [3]f32{1.0, 0.55, 0.22} * (LIGHT_INTENSITY * fl),
        }
    }
    gpu_upload_buffer(gs, gs.light_buf, &lights, n * size_of(Point_Light_Gpu))
}

// Remove torch-map entries that an edit_sphere overwrite just destroyed:
// any torch voxel inside the edited sphere is gone regardless of what block
// replaced it (air break or solid place). Returns how many were removed so
// the caller can invalidate the GI cache region.
lights_remove_in_sphere :: proc(gs: ^Game_State, center: [3]int, radius: int) -> int {
    removed: [dynamic][3]int
    defer delete(removed)
    for key in gs.torch_voxels {
        dx := key[0] - center[0]
        dy := key[1] - center[1]
        dz := key[2] - center[2]
        if dx*dx + dy*dy + dz*dz <= radius*radius {
            append(&removed, key)
        }
    }
    t := f32(SDL.GetTicks()) / 1000.0
    for key in removed {
        delete_key(&gs.torch_voxels, key)
        append(&gs.dying_lights, Dying_Light{key = key, removed_at = t})
    }
    return len(removed)
}

// Register a freshly placed torch (timestamped for the intensity ease-in).
// A dying entry at the same voxel is dropped so the light isn't doubled.
lights_add :: proc(gs: ^Game_State, key: [3]int) {
    gs.torch_voxels[key] = f32(SDL.GetTicks()) / 1000.0
    for i := len(gs.dying_lights) - 1; i >= 0; i -= 1 {
        if gs.dying_lights[i].key == key {
            unordered_remove(&gs.dying_lights, i)
        }
    }
}

// Queue a priority GI re-estimation around a torch place/removal. Every cell
// in the box gets a fresh estimate EVERY frame for GI_REGION_FRAMES with a
// raised blend floor, so the lighting crossfades old → new in ~0.2 s — no
// ghost (EMA-only fade lingers for seconds) and no dark pop (a hard clear
// drops the region to the ambient fallback until the sweep returns).
lights_queue_gi_region :: proc(gs: ^Game_State, center: [3]int, edit_radius: int) {
    reach := int(LIGHT_RADIUS) + edit_radius + 2
    cmin := [3]i32{
        i32(floor_div(center[0] - reach, GI_CELL_SIZE)),
        i32(floor_div(center[1] - reach, GI_CELL_SIZE)),
        i32(floor_div(center[2] - reach, GI_CELL_SIZE)),
    }
    cmax := [3]i32{
        i32(floor_div(center[0] + reach, GI_CELL_SIZE)) + 1,
        i32(floor_div(center[1] + reach, GI_CELL_SIZE)) + 1,
        i32(floor_div(center[2] + reach, GI_CELL_SIZE)) + 1,
    }
    if gs.gi_region_frames > 0 {
        // Union with an already-active box (multiple edits close in time).
        for i in 0 ..< 3 {
            gs.gi_region_min[i] = min(gs.gi_region_min[i], cmin[i])
            gs.gi_region_max[i] = max(gs.gi_region_max[i], cmax[i])
        }
    } else {
        gs.gi_region_min = cmin
        gs.gi_region_max = cmax
    }
    gs.gi_region_frames = GI_REGION_FRAMES
}
