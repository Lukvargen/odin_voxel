package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import SDL "vendor:sdl3"

// Bounce light: irradiance probes every GI_SPACING voxels in a box around
// the camera, renewed a share at a time by a compute pass ahead of the ray
// tracer, which samples them in place of a guess (shaders/gi_common.hlsl
// has the layout and the leak guard, gi_probes.hlsl the update). The grid
// wraps: as the camera moves, only the probes along the edge it moves
// toward are new. Beyond the box shading keeps its stand-in bounce.
//
// Besides the round of all probes in turn, probes that just came into the
// grid and probes around an edit are listed for updates on several frames
// running (gi_plan, gi_on_edit): their light settles in a few frames, a
// little each frame, where the round alone would step it once every
// GI_PROBES / GI_PER_FRAME frames in visible jumps.

GI_SPACING :: 4
GI_DIMS    :: [3]int{48, 24, 48} // 192 x 96 x 192 voxels (as gi_common.hlsl)
GI_PROBES  :: GI_DIMS.x * GI_DIMS.y * GI_DIMS.z
GI_ROW     :: 128                 // probes per texture row
GI_VIS_WORDS :: 17                // reach mask words + owner
GI_BELOW   :: 14                  // probe layers below the camera's (the ground is mostly below)
GI_PER_FRAME :: 1024              // probes renewed per frame: the whole grid every GI_PROBES / GI_PER_FRAME frames
GI_LIST_MAX  :: 2048              // listed probes renewed per frame, on top
GI_NEW_UPDATES  :: 4              // frames running a probe new to the grid is renewed (until it settles: gi_common GI_SETTLED)
GI_EDIT_UPDATES :: 16             // ... and one near an edit (each takes a quarter of the way; light bouncing on into a room takes a while longer)
GI_EDIT_REACH   :: 16             // voxels around an edit whose probes are renewed (light changes there)

GI :: struct {
    enabled:  bool,
    show:     int,  // bench: draw the bounce light alone (1), the probes' alone (2: magenta where none reach)
    pipeline: ^SDL.GPUComputePipeline,
    irr:      ^SDL.GPUTexture, // rgba16f: light per probe and direction
    vis:      ^SDL.GPUTexture, // r32ui: reach mask and owner per probe
    frame:    int,
    list_buf: ^SDL.GPUBuffer,         // this frame's listed slots
    list_up:  ^SDL.GPUTransferBuffer,
    pending:  []u8,                   // per slot: listed updates still to come
    queue:    [dynamic]i32,           // slots with updates pending, nearest the camera first
    listed:   int,                    // slots staged in list_up this frame
    origin:   [3]i32,                 // the grid's min corner last frame
    placed:   bool,                   // ... once there was a last frame
    no_list:  bool,                   // bench: the round alone, nothing listed
    // F3 panel (gi_time): the probe pass timed alone now and then.
    uniform:  Camera_Uniform,         // this frame's, to run the pass again
    stats:    ^SDL.GPUBuffer,         // [0] probes renewed, [1] of them buried in rock
    stats_up, stats_down: ^SDL.GPUTransferBuffer,
    ms:       f32,                    // GPU time of the probe pass, smoothed
    buried:   f32,                    // share of probes solid all through (skipped), smoothed over timed passes
}

gi_init :: proc(gs: ^Game_State) {
    bytes := #load("shaders/gi_probes.spv")
    gs.gi.pipeline = SDL.CreateGPUComputePipeline(gs.gpu_device, SDL.GPUComputePipelineCreateInfo{
        code                           = raw_data(bytes),
        code_size                      = len(bytes),
        entrypoint                     = "main",
        format                         = {.SPIRV},
        num_readonly_storage_buffers   = 7, // voxel_chunk, chunk_index, chunk_owner, voxel_mask, light_index, light_pool, gi_list
        num_readwrite_storage_textures = 2, // gi_irr (u0), gi_vis (u1)
        num_readwrite_storage_buffers  = 1, // gi_stats (u2)
        num_uniform_buffers            = 1,
        threadcount_x = 64, threadcount_y = 1, threadcount_z = 1,
    })
    assert(gs.gi.pipeline != nil, "Failed to create GI probe pipeline")

    rows := u32(GI_PROBES / GI_ROW)
    make_tex :: proc(gs: ^Game_State, format: SDL.GPUTextureFormat, w, h: u32) -> ^SDL.GPUTexture {
        t := SDL.CreateGPUTexture(gs.gpu_device, SDL.GPUTextureCreateInfo{
            type = .D2, format = format,
            usage = {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE, .COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE},
            width = w, height = h, layer_count_or_depth = 1, num_levels = 1,
        })
        fmt.assertf(t != nil, "Failed to create a GI texture: %s", SDL.GetError())
        return t
    }
    gs.gi.irr = make_tex(gs, .R16G16B16A16_FLOAT, GI_ROW * 6, rows)
    gs.gi.vis = make_tex(gs, .R32_UINT, GI_ROW * GI_VIS_WORDS, rows)
    // Zeroed: an owner of 0 is no probe, so nothing is sampled before its
    // first update.
    gi_clear_texture(gs, gs.gi.irr, GI_ROW * 6, rows, 8)
    gi_clear_texture(gs, gs.gi.vis, GI_ROW * GI_VIS_WORDS, rows, 4)
    gs.gi.list_buf = SDL.CreateGPUBuffer(gs.gpu_device, {usage = {.COMPUTE_STORAGE_READ}, size = GI_LIST_MAX * 4})
    gs.gi.list_up = SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .UPLOAD, size = GI_LIST_MAX * 4})
    assert(gs.gi.list_buf != nil && gs.gi.list_up != nil, "Failed to create the GI list buffers")
    gs.gi.pending = make([]u8, GI_PROBES)
    gs.gi.stats = SDL.CreateGPUBuffer(gs.gpu_device, {usage = {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}, size = 8})
    gs.gi.stats_up = SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .UPLOAD, size = 8})
    gs.gi.stats_down = SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .DOWNLOAD, size = 8})
    assert(gs.gi.stats != nil && gs.gi.stats_up != nil && gs.gi.stats_down != nil, "Failed to create the GI stats buffers")
    z := ([^]u32)(SDL.MapGPUTransferBuffer(gs.gpu_device, gs.gi.stats_up, false))
    z[0], z[1] = 0, 0
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, gs.gi.stats_up)
}

@(private="file")
gi_clear_texture :: proc(gs: ^Game_State, tex: ^SDL.GPUTexture, w, h, texel: u32) {
    size := w * h * texel
    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .UPLOAD, size = size})
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)
    p := ([^]u8)(SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false))
    for i in 0 ..< int(size) { p[i] = 0 }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)
    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    cp := SDL.BeginGPUCopyPass(cmd)
    SDL.UploadToGPUTexture(cp, {transfer_buffer = transfer}, {texture = tex, w = w, h = h, d = 1}, false)
    SDL.EndGPUCopyPass(cp)
    _ = SDL.SubmitGPUCommandBuffer(cmd)
}

gi_destroy :: proc(gs: ^Game_State) {
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.gi.irr)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.gi.vis)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.gi.pipeline)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.gi.list_buf)
    SDL.ReleaseGPUTransferBuffer(gs.gpu_device, gs.gi.list_up)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.gi.stats)
    SDL.ReleaseGPUTransferBuffer(gs.gpu_device, gs.gi.stats_up)
    SDL.ReleaseGPUTransferBuffer(gs.gpu_device, gs.gi.stats_down)
    delete(gs.gi.pending)
    delete(gs.gi.queue)
}

@(private="file")
gi_mod :: proc(a, b: int) -> int { return a - floor_div(a, b) * b }

// Storage slot of the probe at probe coords pw (gi_common.hlsl gi_slot).
gi_slot :: proc(pw: [3]i32) -> i32 {
    m := [3]int{gi_mod(int(pw.x), GI_DIMS.x), gi_mod(int(pw.y), GI_DIMS.y), gi_mod(int(pw.z), GI_DIMS.z)}
    return i32(m.x + m.y * GI_DIMS.x + m.z * GI_DIMS.x * GI_DIMS.y)
}

// The probe of the grid at origin that lives in slot s.
gi_slot_probe :: proc(origin: [3]i32, s: i32) -> [3]i32 {
    sc := [3]int{int(s) % GI_DIMS.x, (int(s) / GI_DIMS.x) % GI_DIMS.y, int(s) / (GI_DIMS.x * GI_DIMS.y)}
    return {
        origin.x + i32(gi_mod(sc.x - int(origin.x), GI_DIMS.x)),
        origin.y + i32(gi_mod(sc.y - int(origin.y), GI_DIMS.y)),
        origin.z + i32(gi_mod(sc.z - int(origin.z), GI_DIMS.z)),
    }
}

@(private="file")
gi_enqueue :: proc(gi: ^GI, s: i32, updates: u8) {
    if gi.no_list { return }
    if gi.pending[s] == 0 { append(&gi.queue, s) }
    gi.pending[s] = max(gi.pending[s], updates)
}

// Nearest the camera first, so what's around you settles first when more
// is listed than a frame renews.
@(private="file")
gi_sort_queue :: proc(gi: ^GI) {
    Key :: struct { d: i32, s: i32 }
    keys := make([]Key, len(gi.queue), context.temp_allocator)
    centre := gi.origin + {i32(GI_DIMS.x / 2), GI_BELOW, i32(GI_DIMS.z / 2)}
    for s, i in gi.queue {
        d := gi_slot_probe(gi.origin, s) - centre
        keys[i] = {d.x * d.x + d.y * d.y + d.z * d.z, s}
    }
    slice.sort_by(keys, proc(a, b: Key) -> bool { return a.d < b.d })
    for k, i in keys { gi.queue[i] = k.s }
}

// Blocks changed (light.odin light_on_edit): the probes around them are
// renewed over the next frames, so the light there settles smoothly.
gi_on_edit :: proc(gs: ^Game_State, changed: [][3]int) {
    gi := &gs.gi
    if !gi.enabled || !gi.placed || len(changed) == 0 { return }
    lo, hi := changed[0], changed[0]
    for p in changed {
        lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
        hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
    }
    probe :: proc(v: int) -> i32 { return i32(floor_div(v, GI_SPACING)) }
    top := gi.origin + {i32(GI_DIMS.x), i32(GI_DIMS.y), i32(GI_DIMS.z)} - 1
    plo := [3]i32{max(probe(lo.x - GI_EDIT_REACH), gi.origin.x), max(probe(lo.y - GI_EDIT_REACH), gi.origin.y), max(probe(lo.z - GI_EDIT_REACH), gi.origin.z)}
    phi := [3]i32{min(probe(hi.x + GI_EDIT_REACH), top.x), min(probe(hi.y + GI_EDIT_REACH), top.y), min(probe(hi.z + GI_EDIT_REACH), top.z)}
    for z in plo.z ..= phi.z { for y in plo.y ..= phi.y { for x in plo.x ..= phi.x {
        gi_enqueue(gi, gi_slot({x, y, z}), GI_EDIT_UPDATES)
    }}}
    gi_sort_queue(gi)
}

// List the probes that came into the grid (it moved with the camera from
// gi.origin to origin), then stage this frame's listed slots.
@(private="file")
gi_plan :: proc(gs: ^Game_State, origin: [3]i32) {
    gi := &gs.gi
    if !gi.placed || origin != gi.origin {
        old, had := gi.origin, gi.placed
        gi.origin, gi.placed = origin, true
        top := old + {i32(GI_DIMS.x), i32(GI_DIMS.y), i32(GI_DIMS.z)}
        for z in origin.z ..< origin.z + i32(GI_DIMS.z) { for y in origin.y ..< origin.y + i32(GI_DIMS.y) { for x in origin.x ..< origin.x + i32(GI_DIMS.x) {
            if had && x >= old.x && x < top.x && y >= old.y && y < top.y && z >= old.z && z < top.z { continue }
            gi_enqueue(gi, gi_slot({x, y, z}), GI_NEW_UPDATES)
        }}}
        gi_sort_queue(gi)
    }
    gi.listed = min(len(gi.queue), GI_LIST_MAX)
    if gi.listed == 0 { return }
    dst := ([^]u32)(SDL.MapGPUTransferBuffer(gs.gpu_device, gi.list_up, true))
    for i in 0 ..< gi.listed {
        s := gi.queue[i]
        dst[i] = u32(s)
        gi.pending[s] -= 1
    }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, gi.list_up)
    // Drop the slots done with, keeping the order.
    n := 0
    for s in gi.queue {
        if gi.pending[s] > 0 { gi.queue[n] = s; n += 1 }
    }
    resize(&gi.queue, n)
}

// The grid's min corner in probe coords around eye, and the slots renewed
// this frame, for Camera_Uniform.
gi_uniforms :: proc(gs: ^Game_State, eye: [3]f32) -> (origin, frame: [4]i32) {
    c := [3]i32{
        i32(math.floor(eye.x / GI_SPACING)),
        i32(math.floor(eye.y / GI_SPACING)),
        i32(math.floor(eye.z / GI_SPACING)),
    }
    origin = {c.x - i32(GI_DIMS.x / 2), c.y - GI_BELOW, c.z - i32(GI_DIMS.z / 2), gs.gi.enabled ? 1 : 0}
    gs.gi.listed = 0
    if gs.gi.enabled {
        gi_plan(gs, origin.xyz)
    } else if gs.gi.placed {
        // Off: forget the list; switched on again, every probe is new.
        for s in gs.gi.queue { gs.gi.pending[s] = 0 }
        clear(&gs.gi.queue)
        gs.gi.placed = false
    }
    frame = {i32((gs.gi.frame * GI_PER_FRAME) % GI_PROBES), i32(gs.gi.frame), i32(gs.gi.show), i32(gs.gi.listed)}
    return
}

// The probe update, recorded into cmd ahead of the ray tracer (the uniforms
// are already pushed).
gi_dispatch :: proc(gs: ^Game_State, cmd: ^SDL.GPUCommandBuffer) {
    if !gs.gi.enabled { return }
    if gs.gi.listed > 0 {
        cp := SDL.BeginGPUCopyPass(cmd)
        SDL.UploadToGPUBuffer(cp, {transfer_buffer = gs.gi.list_up}, {buffer = gs.gi.list_buf, size = u32(gs.gi.listed * 4)}, true)
        SDL.EndGPUCopyPass(cp)
    }
    rw := [2]SDL.GPUStorageTextureReadWriteBinding{
        {texture = gs.gi.irr, cycle = false},
        {texture = gs.gi.vis, cycle = false},
    }
    rw_buf := SDL.GPUStorageBufferReadWriteBinding{buffer = gs.gi.stats, cycle = false}
    p := SDL.BeginGPUComputePass(cmd, raw_data(rw[:]), 2, &rw_buf, 1)
    SDL.BindGPUComputePipeline(p, gs.gi.pipeline)
    bufs := [7]^SDL.GPUBuffer{gs.voxel_buf, gs.index_buf, gs.owner_buf, gs.mask_buf, gs.light_index_buf, gs.light_pool_buf, gs.gi.list_buf}
    SDL.BindGPUComputeStorageBuffers(p, 0, raw_data(bufs[:]), 7)
    SDL.DispatchGPUCompute(p, u32(GI_PER_FRAME + gs.gi.listed), 1, 1)
    SDL.EndGPUComputePass(p)
    gs.gi.frame += 1
}

// For the F3 panel (gpu_render_timed, on an idle GPU after a timed frame):
// the probe pass once more on its own, timed, with how many probes it
// renewed and how many of those were buried in rock (solid all through,
// skipped after the open-voxel scan). An extra round of updates, harmless.
gi_time :: proc(gs: ^Game_State) {
    gi := &gs.gi
    if !gi.enabled { gi.ms, gi.buried = 0, 0; return }
    // Two submissions timed alike: zeroing the counters alone, then the
    // pass and reading them back. The first is the cost of a submit and its
    // fence, taken off the second.
    run :: proc(gs: ^Game_State, with_pass: bool) -> (ms: f32, ok: bool) {
        gi := &gs.gi
        cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
        if cmd == nil { return }
        t := time.tick_now()
        cp := SDL.BeginGPUCopyPass(cmd)
        if with_pass {
            SDL.EndGPUCopyPass(cp)
            SDL.PushGPUComputeUniformData(cmd, 0, &gi.uniform, size_of(gi.uniform))
            gi_dispatch(gs, cmd)
            cp = SDL.BeginGPUCopyPass(cmd)
            SDL.DownloadFromGPUBuffer(cp, {buffer = gi.stats, size = 8}, {transfer_buffer = gi.stats_down})
        } else {
            SDL.UploadToGPUBuffer(cp, {transfer_buffer = gi.stats_up}, {buffer = gi.stats, size = 8}, false)
        }
        SDL.EndGPUCopyPass(cp)
        fence := SDL.SubmitGPUCommandBufferAndAcquireFence(cmd)
        if fence == nil { return }
        _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
        SDL.ReleaseGPUFence(gs.gpu_device, fence)
        return f32(time.duration_milliseconds(time.tick_since(t))), true
    }
    base, ok0 := run(gs, false)
    full, ok1 := run(gs, true)
    if !ok0 || !ok1 { return }
    ms := max(full - base, 0)
    gi.ms = gi.ms == 0 ? ms : gi.ms + (ms - gi.ms) * 0.3
    c := ([^]u32)(SDL.MapGPUTransferBuffer(gs.gpu_device, gi.stats_down, false))
    // Each pass renews a different stretch of the grid: smoothed, the share
    // covers it all.
    share := f32(c[1]) / f32(max(c[0], 1))
    gi.buried = gi.buried == 0 ? share : gi.buried + (share - gi.buried) * 0.15
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, gi.stats_down)
}
