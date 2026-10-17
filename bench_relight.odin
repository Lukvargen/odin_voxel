package main

import "core:fmt"
import "core:time"
import "core:math"
import SDL "vendor:sdl3"

// `bench relight`: fly fast over new ground the way the game loop streams it
// (a frame of integration and stitching per step, never waiting for idle),
// stop, dig with a big area edit, and check the sky light around it is a
// settled flood fill: no open voxel darker than a neighbour lights it.
// Voxels that are tell where light went stale (dark patches until reload).
bench_relight: bool
bench_peak_bricks: int

bench_relight_run :: proc(gs: ^Game_State) {
    cam := &gs.camera
    cam.fly_mode = true
    // Into mountains (cliffs, overhangs, caves: light crossing column
    // borders) from 1200 voxels off, ~60 voxels a second at 60 frames.
    mx, mz, found := bench_find_biome(.Mountains)
    if !found { mx, mz = int(cam.pos.x) + 1200, int(cam.pos.z) }
    target := [3]f32{f32(mx), f32(surface_height_at(mx, mz)) + 20, f32(mz)}
    start := target - {1200, 0, 0}
    bench_teleport(gs, start)
    for i in 0 ..< 1200 {
        cam.pos = start + (target - start) * f32(i + 1) / 1200
        stream_frame(gs)
    }
    fmt.printf("relight: flew to %.0f,%.0f; stitch queue %d\n", cam.pos.x, cam.pos.z, len(gs.stitch_queue))
    { // the check itself: one open voxel darkened on purpose must show
        q := [3]int{int(cam.pos.x), surface_height_at(int(cam.pos.x), int(cam.pos.z)) + 3, int(cam.pos.z)}
        ch, vi := chunk_at(gs, q)
        old := chunk_light(ch, vi)
        chunk_set_light(ch, vi, chan_set(old, .Sky, 0))
        report(gs, "self-test (1 voxel zeroed)", {f32(q.x), f32(q.y), f32(q.z)}, 8)
        chunk_set_light(ch, vi, old)
    }
    report(gs, "arrived (still streaming)", {cam.pos.x, f32(surface_height_at(int(cam.pos.x), int(cam.pos.z))), cam.pos.z}, 64)

    // Dig right away, then keep the frames going a moment.
    x, z := int(cam.pos.x), int(cam.pos.z)
    g := surface_height_at(x, z)
    build_apply(gs, Edit_Region{lo = {x - 12, g - 14, z - 12}, hi = {x + 12, g + 2, z + 12}}, .Air, .All)
    build_apply(gs, Edit_Region{lo = {x - 12, g - 30, z + 13}, hi = {x + 12, g - 6, z + 40}}, .Air, .All)
    report(gs, "dug while streaming", {f32(x), f32(g), f32(z)}, 64)
    for _ in 0 ..< 600 { stream_frame(gs) }
    report(gs, "10 s later", {f32(x), f32(g), f32(z)}, 64)

    t0 := time.now()
    for !streaming_idle(gs) && time.duration_seconds(time.since(t0)) < 60 { stream_frame(gs) }
    report(gs, "streaming idle", {f32(x), f32(g), f32(z)}, 64)
    t1 := time.tick_now()
    n := light_relight_near(gs, 6)
    fmt.printf("relight: F9 relit %d columns in %.1f ms\n", n, time.duration_milliseconds(time.tick_since(t1)))
    report(gs, "after F9 relight", {f32(x), f32(g), f32(z)}, 64)
    fmt.printf("relight: light bricks peak %d of %d so far\n", bench_peak_bricks, len(gs.light_pool.free_ids))
    gpu_check(gs, "after the flight")

    // A long wander, as when exploring: the column ring fills and wraps,
    // slots and light bricks are reused over and over.
    pos := cam.pos
    for i in 0 ..< 6000 {
        t := f32(i) / 6000
        cam.pos = pos + {6000 * t, 0, 2500 * math.sin(t * 9)}
        stream_frame(gs)
    }
    fmt.printf("relight: wandered to %.0f,%.0f; %d columns loaded, light bricks %d of %d used\n",
        cam.pos.x, cam.pos.z, len(gs.columns), len(gs.light_pool.free_ids) - gs.light_pool.free_top, len(gs.light_pool.free_ids))
    gpu_check(gs, "after the wander (streaming)")
    t0 = time.now()
    for !streaming_idle(gs) && time.duration_seconds(time.since(t0)) < 120 { stream_frame(gs) }
    gpu_check(gs, "after the wander (idle)")
    fmt.printf("relight: light bricks peak %d of %d overall\n", bench_peak_bricks, len(gs.light_pool.free_ids))

    // A shorter view distance and back: pools and buffers made again at the
    // new size, everything loaded re-sent.
    for radius in ([2]int{VIEW_RADII[0], VIEW_RADII[2]}) {
        t2 := time.tick_now()
        set_view_radius(gs, radius)
        stream_frame(gs)
        ms := time.duration_milliseconds(time.tick_since(t2))
        for !streaming_idle(gs) && time.duration_seconds(time.since(t0)) < 600 { stream_frame(gs) }
        fmt.printf("relight: view radius %d: switch frame %.0f ms; pools %d voxel + %d light bricks; %d columns\n",
            radius, ms, len(gs.brick_pool.free_ids), len(gs.light_pool.free_ids), len(gs.columns))
        gpu_check(gs, fmt.tprintf("view radius %d", radius))
    }

    stream_frame :: proc(gs: ^Game_State) {
        new_pc := [3]int{
            floor_div(int(gs.camera.pos.x), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.y), CHUNK_VOXELS),
            floor_div(int(gs.camera.pos.z), CHUNK_VOXELS),
        }
        if new_pc != gs.player_chunk {
            gs.player_chunk = new_pc
            worker_pool_set_player(&gs.pool, new_pc[0], new_pc[2])
            enqueue_chunks(gs)
        }
        integrate_ready_chunks(gs)
        stitch_pending_columns(gs)
        flush_gpu_uploads(gs)
        bench_peak_bricks = max(bench_peak_bricks, len(gs.light_pool.free_ids) - gs.light_pool.free_top)
        free_all(context.temp_allocator)
        time.sleep(time.Millisecond * 2)
    }

    // Open voxels within r of c whose sky light is below what a neighbour
    // gives them (lower than a settled flood fill allows).
    report :: proc(gs: ^Game_State, what: string, c: [3]f32, r: int) {
        bad, checked := 0, 0
        worst := 0
        first: [3]int
        ci := [3]int{int(c.x), int(c.y), int(c.z)}
        for dz in -r ..= r { for dx in -r ..= r { for dy in -r ..= r / 2 {
            p := ci + {dx, dy, dz}
            ch, vi := chunk_at(gs, p)
            if ch == nil || block_opaque(chunk_voxel(ch, vi)) { continue }
            l := int(chan_get(chunk_light(ch, vi), .Sky))
            checked += 1
            want := 0
            for d, di in NEIGHBOURS {
                nc, nvi := chunk_at(gs, p - d) // the neighbour that would light p by moving +d
                if nc == nil { continue }
                nl := chan_get(chunk_light(nc, nvi), .Sky)
                if block_opaque(chunk_voxel(nc, nvi)) { continue }
                want = max(want, int(spread_level(nl, .Sky, di, chunk_voxel(ch, vi))))
            }
            if want > l {
                if bad == 0 { first = p }
                bad += 1
                worst = max(worst, want - l)
            }
        }}}
        uniq := make(map[[2]int]bool, context.temp_allocator)
        for k in gs.stitch_queue { uniq[k] = true }
        fmt.printf("relight: %-26s %6d of %7d open voxels too dark (worst by %d levels); stitch queue %d (%d distinct)", what, bad, checked, worst, len(gs.stitch_queue), len(uniq))
        if bad > 0 { fmt.printf(", e.g. at %v", first) }
        fmt.println()
    }

    chunk_at :: proc(gs: ^Game_State, p: [3]int) -> (^Chunk, int) {
        c := world_chunk(gs, {p.x >> 3, p.y >> 3, p.z >> 3})
        l := p & 7
        return c, l.x + l.y * 8 + l.z * 64
    }
}

// Download the GPU's light (slot index + bricks) and compare it with the CPU
// light of every resident chunk: what the shader reads against what it should.
@(private="file")
gpu_check :: proc(gs: ^Game_State, what: string) {
    flush_gpu_uploads(gs)
    idx_bytes := len(gs.gpu_light_index) * size_of(i32)
    pool_bytes := len(gs.light_pool.free_ids) * LIGHT_BRICK_BYTES
    vox_bytes := len(gs.brick_pool.free_ids) * VOXELS_PER_BRICK
    xfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .DOWNLOAD, size = u32(idx_bytes + pool_bytes + vox_bytes)})
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, xfer)
    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    cp := SDL.BeginGPUCopyPass(cmd)
    SDL.DownloadFromGPUBuffer(cp, {buffer = gs.light_index_buf, offset = 0, size = u32(idx_bytes)}, {transfer_buffer = xfer, offset = 0})
    SDL.DownloadFromGPUBuffer(cp, {buffer = gs.light_pool_buf, offset = 0, size = u32(pool_bytes)}, {transfer_buffer = xfer, offset = u32(idx_bytes)})
    SDL.DownloadFromGPUBuffer(cp, {buffer = gs.voxel_buf, offset = 0, size = u32(vox_bytes)}, {transfer_buffer = xfer, offset = u32(idx_bytes + pool_bytes)})
    SDL.EndGPUCopyPass(cp)
    fence := SDL.SubmitGPUCommandBufferAndAcquireFence(cmd)
    _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
    SDL.ReleaseGPUFence(gs.gpu_device, fence)
    base := uintptr(SDL.MapGPUTransferBuffer(gs.gpu_device, xfer, false))
    defer SDL.UnmapGPUTransferBuffer(gs.gpu_device, xfer)
    gidx := ([^]i32)(rawptr(base))
    gpool := ([^]u16)(rawptr(base + uintptr(idx_bytes)))
    gvox := ([^]u8)(rawptr(base + uintptr(idx_bytes + pool_bytes)))

    chunks, index_wrong, brick_wrong, voxels_wrong := 0, 0, 0, 0
    vox_wrong, vox_missing := 0, 0
    shared := 0
    owners := make(map[i32]int, context.temp_allocator) // light brick -> slot using it
    first: string
    for slot in 0 ..< len(gs.gpu_light_index) {
        owner := gs.gpu_chunk_owner[slot]
        if owner[0] == 0x7fffffff { continue }
        key := [3]int{int(owner[0]), (slot / CHUNKS_W) % CHUNKS_H + WORLD_CHUNK_Y_MIN, int(owner[1])}
        c := world_chunk(gs, key)
        if c == nil { continue }
        chunks += 1
        if vi := gs.gpu_index[slot]; vi >= 0 && c.voxels != nil {
            for k in 0 ..< VOXELS_PER_BRICK {
                if gvox[int(vi) * VOXELS_PER_BRICK + k] != c.voxels[k] { vox_wrong += 1; break }
            }
        } else if c.voxels != nil && vi < 0 {
            vox_missing += 1
        }
        g := gidx[slot]
        if g != gs.gpu_light_index[slot] {
            index_wrong += 1
            if first == "" { first = fmt.tprintf("slot %d chunk %v: GPU index %d, CPU index %d", slot, key, g, gs.gpu_light_index[slot]) }
            continue
        }
        if g < 0 {
            if c.light != nil || u16(-1 - g) != c.light_fill {
                index_wrong += 1
                if first == "" { first = fmt.tprintf("slot %d chunk %v: one value %x on the GPU, CPU %s", slot, key, -1 - g, c.light != nil ? "per voxel" : fmt.tprintf("one value %x", c.light_fill)) }
            }
            continue
        }
        if other, used := owners[g]; used {
            shared += 1
            if first == "" { first = fmt.tprintf("light brick %d used by slots %d and %d", g, other, slot) }
        }
        owners[g] = slot
        bad := 0
        for vi in 0 ..< VOXELS_PER_BRICK {
            if gpool[int(g) * VOXELS_PER_BRICK + vi] != chunk_light(c, vi) { bad += 1 }
        }
        if bad > 0 {
            brick_wrong += 1
            voxels_wrong += bad
            if first == "" { first = fmt.tprintf("slot %d chunk %v brick %d: %d of 512 voxels differ", slot, key, g, bad) }
        }
    }
    fmt.printf("relight: GPU check %-28s %d chunks: %d wrong index, %d stale bricks (%d voxels), %d bricks shared\n",
        what, chunks, index_wrong, brick_wrong, voxels_wrong, shared)
    fmt.printf("relight:   voxels: %d bricks differ from the CPU, %d mixed chunks without a brick\n", vox_wrong, vox_missing)
    if first != "" { fmt.println("relight:   first:", first) }
}
