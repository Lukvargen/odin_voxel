package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:time"
import SDL "vendor:sdl3"

// The window opens at WINDOW_W x WINDOW_H and can be resized; the scene is
// ray traced at the window's size times gs.render_scale (gpu_fit_render_size),
// at most MAX_RENDER_W x MAX_RENDER_H, and upscaled to the window.
WINDOW_W :: 1280
WINDOW_H :: 720
BENCH_RENDER_W :: 800
BENCH_RENDER_H :: 800
MAX_RENDER_W :: 3840
MAX_RENDER_H :: 2400

// Matches cbuffer CameraUniforms in shaders/camera_uniforms.hlsl.
// Each float3 is padded to float4 (cbuffer std140 rules).
Camera_Uniform :: struct #packed {
    pos:            [3]f32,
    _pad0:          f32,
    fwd:            [3]f32,
    _pad1:          f32,
    right:          [3]f32,
    _pad2:          f32,
    up:             [3]f32,
    _pad3:          f32,
    light_dir:      [3]f32,
    _pad4:          f32,
    reflect_amount: i32,
    quality:        i32,   // packed: AA*10 + shadow_rays
    vol:            i32,   // packed: enabled*100 + steps (0/16/24/32)
    entity_count:   i32,   // entities uploaded this frame (entities.odin)
    time:           f32,   // seconds: cloud drift, flicker
    exposure:       f32,   // pre-tonemap multiplier
    fog_density:    f32,   // base distance-fog density
    cave_factor:    f32,   // 0 surface .. 1 deep underground (CPU-smoothed)
    sun_intensity:  f32,   // sun direct-light multiplier
    far_enabled:    i32,
    ent_debug:      i32,   // 1/2 = bench: skip entity view rays / shadows; 4 = no cumulus (bench or options); 8/16 = bench: sky-only water reflections / no cloud shadows; 32 = blocks plain grey (F10)
    _pad5:          f32,
    near_circle:    [4]f32, // near (voxel) region: XZ center, radius in voxels, unused
    sun_true:       [4]f32, // xyz = real sun direction (light_dir is the moon at night), w = night 0..1
    atmos:          [4]f32, // x = valley mist amount, yzw unused
    thermals:       [MAX_SKY_THERMALS][4]f32, // cumulus over thermals: XZ centre at cloud base, radius, strength
    thermal_count:  [4]i32, // x = count
    cloud_puffs:    [MAX_SKY_THERMALS * 4][4]f32, // per thermal 4 towers: offset (cloud radii), radius
    hand_light:     [4]f32, // torch in hand: xyz = position, w = light level (0 = none)
    gi_origin:      [4]i32, // bounce-light probe grid (gi.odin): min corner in probe coords, w = enabled
    gi_frame:       [4]i32, // x = first probe slot renewed this frame, y = frame counter
    torch:          [4]i32, // torch shadows (torch.odin): xyz = the box's min chunk, w = emitters listed (0 = off)
    torch_params:   [4]f32, // x = share of torch light left in its shadow
}

// A held torch lights the world around the player as a point light in the
// shader (it moves every frame, so it stays out of the CPU voxel light).
// It sits low and to the right of the eye, where the hand is, unless that
// is inside a block.
HAND_TORCH_LIGHT :: BLOCK_LIGHT_MAX // as bright as a placed torch, fading out ~24 blocks away

// Width over height of the scene (and the window, give or take a pixel).
render_aspect :: proc(gs: ^Game_State) -> f32 {
    return gs.render_h > 0 ? f32(gs.render_w) / f32(gs.render_h) : 1
}

hand_light :: proc(gs: ^Game_State, eye, fwd, right, up: [3]f32) -> [4]f32 {
    if gs.selected_block != .Torch || gs.combat.sword { return {} }
    p := eye + right * 0.35 - up * 0.3 + fwd * 0.3
    if block_solid(u8(voxel_at(gs, p))) { p = eye }
    t := f32(SDL.GetTicks()) / 1000.0
    flicker := 0.6 * math.sin(t * 9.3) + 0.4 * math.sin(t * 23.1 + 1.7)
    return {p.x, p.y, p.z, HAND_TORCH_LIGHT + flicker * 0.35}
}

// (Re)create the scene color, depth, and half-res volumetric textures at the
// current internal render resolution (gs.render_w/h). The caller owns the
// lifetime of any previous textures (release them first, or use
// gpu_fit_render_size which does). Buffers and pipelines are untouched.
gpu_create_scene_textures :: proc(gs: ^Game_State) {
    // Output storage texture (compute writes here each frame). Allocated at the
    // internal render resolution; the SDL renderer upscales it to the window.
    // RGBA16F: tone-mapped/HDR scene color fits comfortably, half the bandwidth.
    gs.out_texture = SDL.CreateGPUTexture(gs.gpu_device, SDL.GPUTextureCreateInfo{
        type                 = .D2,
        format               = .R16G16B16A16_FLOAT,
        usage                = {.COMPUTE_STORAGE_WRITE, .COMPUTE_STORAGE_READ, .SAMPLER}, // READ: bloom prefilter samples it
        width                = u32(gs.render_w),
        height               = u32(gs.render_h),
        layer_count_or_depth = 1,
        num_levels           = 1,
    })
    assert(gs.out_texture != nil, "Failed to create output texture")

    // Per-pixel primary-hit distance (R32F). Consumed by the volumetric
    // composite for depth-aware upscale and march-length clamping.
    gs.depth_texture = SDL.CreateGPUTexture(gs.gpu_device, SDL.GPUTextureCreateInfo{
        type                 = .D2,
        format               = .R32_FLOAT,
        usage                = {.COMPUTE_STORAGE_WRITE, .SAMPLER},
        width                = u32(gs.render_w),
        height               = u32(gs.render_h),
        layer_count_or_depth = 1,
        num_levels           = 1,
    })
    assert(gs.depth_texture != nil, "Failed to create depth texture")

    // Half-res volumetric inscatter. Written by the volumetric pass
    // (storage write), read by composite (RO storage texture / .SAMPLER).
    gs.vol_texture = SDL.CreateGPUTexture(gs.gpu_device, SDL.GPUTextureCreateInfo{
        type                 = .D2,
        format               = .R16G16B16A16_FLOAT,
        usage                = {.COMPUTE_STORAGE_WRITE, .SAMPLER},
        width                = u32(gs.render_w / 2),
        height               = u32(gs.render_h / 2),
        layer_count_or_depth = 1,
        num_levels           = 1,
    })
    assert(gs.vol_texture != nil, "Failed to create volumetric texture")

    // Half-res bloom ping-pong: prefilter -> a, blur H a -> b, blur V b -> a;
    // composite reads a.
    for i in 0..<2 {
        gs.bloom_texture[i] = SDL.CreateGPUTexture(gs.gpu_device, SDL.GPUTextureCreateInfo{
            type                 = .D2,
            format               = .R16G16B16A16_FLOAT,
            usage                = {.COMPUTE_STORAGE_WRITE, .COMPUTE_STORAGE_READ, .SAMPLER},
            width                = u32(gs.render_w / 2),
            height               = u32(gs.render_h / 2),
            layer_count_or_depth = 1,
            num_levels           = 1,
        })
        assert(gs.bloom_texture[i] != nil, "Failed to create bloom texture")
    }
}

// Scene texture size for the window's size in pixels and gs.render_scale:
// the window's aspect, shrunk to fit MAX_RENDER_W x MAX_RENDER_H.
render_size :: proc(gs: ^Game_State) -> (w, h: i32) {
    pw, ph: i32
    SDL.GetWindowSizeInPixels(gs.window, &pw, &ph)
    if pw <= 0 || ph <= 0 { return gs.render_w, gs.render_h } // minimized
    fw, fh := f32(pw) * gs.render_scale, f32(ph) * gs.render_scale
    k := min(1, f32(MAX_RENDER_W) / fw, f32(MAX_RENDER_H) / fh)
    return max(i32(fw * k + 0.5), 16), max(i32(fh * k + 0.5), 16)
}

// The textures gpu_create_scene_textures makes.
gpu_release_scene_textures :: proc(gs: ^Game_State) {
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.out_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.depth_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.vol_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.bloom_texture[0])
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.bloom_texture[1])
}

// Match the scene textures to the window (resized, or the render scale
// changed): waits for the GPU to idle, recreates the scene textures and
// re-points the UI's SDL texture at them. No-op if the size is unchanged.
gpu_fit_render_size :: proc(gs: ^Game_State) {
    w, h := render_size(gs)
    if w == gs.render_w && h == gs.render_h { return }

    _ = SDL.WaitForGPUIdle(gs.gpu_device)
    gpu_release_scene_textures(gs)
    gs.render_w, gs.render_h = w, h
    gpu_create_scene_textures(gs)
    ui_rewrap_out_texture(gs) // re-point the SDL texture at the new out_texture
}

gpu_init :: proc(gs: ^Game_State) {
    // SDL3 GPU device (SPIR-V shaders, debug mode on)
    gs.gpu_device = SDL.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil)
    assert(gs.gpu_device != nil, "Failed to create GPU device")
    fmt.println("GPU driver:", SDL.GetGPUDeviceDriver(gs.gpu_device))

    // Note: window is claimed by SDL.CreateGPURenderer in ui_init (which
    // shares this GPU device). Claiming it here would conflict.

    // SPIR-V embedded at compile time â€” no runtime file dependency
    shader_bytes := #load("shaders/voxel_tracer.spv")

    pipeline_info := SDL.GPUComputePipelineCreateInfo{
        code                           = raw_data(shader_bytes),
        code_size                      = len(shader_bytes),
        entrypoint                     = "main",
        format                         = {.SPIRV},
        // SDL GPU allows at most 8 storage buffers per stage (going over
        // put the driver on a ~2x slower path), hence the shared buffers:
        // region counts ride at the end of chunk_index, and the far tile
        // table and cells share one buffer.
        num_readonly_storage_textures  = 4, // GI probes: gi_irr (t0), gi_vis (t1); torch shadows: torch_emit (t2), torch_cells (t3)
        num_readonly_storage_buffers   = 8, // voxel_chunk (t4), chunk_index + region counts (t5), chunk_owner (t6), voxel_mask (t7), light_index (t8), light_pool (t9), ent_data (t10), far_data (t11)
        num_readwrite_storage_textures = 2, // img_output (u0), depth_output (u1)
        num_uniform_buffers            = 1, // CameraUniforms (b0)
        threadcount_x                  = 16,
        threadcount_y                  = 16,
        threadcount_z                  = 1,
    }
    gs.pipeline = SDL.CreateGPUComputePipeline(gs.gpu_device, pipeline_info)
    assert(gs.pipeline != nil, "Failed to create compute pipeline")
    gi_init(gs)
    torch_init(gs)

    // Volumetric pass: 1 RO storage texture (depth) + 4 RO storage buffers,
    // 1 RW storage texture (half-res inscatter).
    vol_bytes := #load("shaders/volumetric.spv")
    gs.vol_pipeline = SDL.CreateGPUComputePipeline(gs.gpu_device, SDL.GPUComputePipelineCreateInfo{
        code                           = raw_data(vol_bytes),
        code_size                      = len(vol_bytes),
        entrypoint                     = "main",
        format                         = {.SPIRV},
        num_readonly_storage_textures  = 1, // depth_input (t0)
        num_readonly_storage_buffers   = 4, // voxel buffers (t1..t4)
        num_readwrite_storage_textures = 1, // vol_output (u0)
        num_uniform_buffers            = 1,
        threadcount_x = 16, threadcount_y = 16, threadcount_z = 1,
    })
    assert(gs.vol_pipeline != nil, "Failed to create volumetric pipeline")

    // Composite pass: 2 RO storage textures (vol, depth), 1 RW (scene color).
    comp_bytes := #load("shaders/composite.spv")
    gs.comp_pipeline = SDL.CreateGPUComputePipeline(gs.gpu_device, SDL.GPUComputePipelineCreateInfo{
        code                           = raw_data(comp_bytes),
        code_size                      = len(comp_bytes),
        entrypoint                     = "main",
        format                         = {.SPIRV},
        num_readonly_storage_textures  = 3, // vol_input (t0), depth_input (t1), bloom_input (t2)
        num_readwrite_storage_textures = 1, // img_output (u0)
        num_uniform_buffers            = 1,
        threadcount_x = 16, threadcount_y = 16, threadcount_z = 1,
    })
    assert(gs.comp_pipeline != nil, "Failed to create composite pipeline")

    // Bloom passes: prefilter (scene -> half-res highlights), then the
    // separable gaussian compiled twice with the direction baked in.
    bloom_pipeline :: proc(gs: ^Game_State, bytes: []u8) -> ^SDL.GPUComputePipeline {
        return SDL.CreateGPUComputePipeline(gs.gpu_device, SDL.GPUComputePipelineCreateInfo{
            code                           = raw_data(bytes),
            code_size                      = len(bytes),
            entrypoint                     = "main",
            format                         = {.SPIRV},
            num_readonly_storage_textures  = 1, // source (t0)
            num_readwrite_storage_textures = 1, // dest (u0)
            threadcount_x = 16, threadcount_y = 16, threadcount_z = 1,
        })
    }
    gs.bloom_pre_pipeline = bloom_pipeline(gs, #load("shaders/bloom_prefilter.spv"))
    assert(gs.bloom_pre_pipeline != nil, "Failed to create bloom prefilter pipeline")
    gs.bloom_h_pipeline = bloom_pipeline(gs, #load("shaders/bloom_blur_h.spv"))
    assert(gs.bloom_h_pipeline != nil, "Failed to create bloom blur H pipeline")
    gs.bloom_v_pipeline = bloom_pipeline(gs, #load("shaders/bloom_blur_v.spv"))
    assert(gs.bloom_v_pipeline != nil, "Failed to create bloom blur V pipeline")

    // Entity voxel models (static, uploaded once) followed by the per-frame
    // entity/part instance lists (voxel_models.odin, entities.odin).
    {
        ent_models_bake()
        words, dyn_base := ent_static_words()
        defer delete(words)
        gs.ent_dyn_base = dyn_base
        dyn_size := int(offset_of(Ent_Frame, n_ents))
        gs.entity_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
            usage = {.COMPUTE_STORAGE_READ},
            size  = u32(len(words) * 4 + dyn_size),
        })
        assert(gs.entity_buf != nil, "Failed to create entity buffer")
        gpu_upload_buffer(gs, gs.entity_buf, raw_data(words), len(words) * 4)
        // Staging for the per-frame part, reused every frame (mapped with
        // cycling) and copied inside the frame's own command buffer: a
        // fresh transfer buffer + submit per frame cost ~0.3 ms of CPU.
        gs.ent_transfer = SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .UPLOAD, size = u32(dyn_size)})
        assert(gs.ent_transfer != nil, "Failed to create entity transfer buffer")
    }

    // Scene color/depth/volumetric textures, sized to the current internal
    // render resolution (gs.render_w/h). Recreated on render-scale change.
    gpu_create_scene_textures(gs)

    // GPU buffers for voxel data (read-only in compute). The voxel pool is
    // 1 byte/voxel, read by the shader as StructuredBuffer<uint> (4 voxels
    // per uint); the mask pool is 16 uints (512 occupancy bits) per brick.
    // Both are filled per brick by flush_gpu_uploads.
    index_buf_size := u32(len(gs.gpu_index)  * size_of(i32))
    region_bytes   := u32(REGION_COUNT * size_of(u32)) // after the index (see pipeline above)
    gpu_create_pool_buffers(gs)

    gs.index_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = index_buf_size + region_bytes,
    })
    assert(gs.index_buf != nil, "Failed to create index buffer")

    owner_buf_size := u32(len(gs.gpu_chunk_owner) * size_of([2]i32))
    gs.owner_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = owner_buf_size,
    })
    assert(gs.owner_buf != nil, "Failed to create owner buffer")

    // Voxel light (light.odin): per-slot light index + the light brick pool.
    light_index_size := u32(len(gs.gpu_light_index) * size_of(i32))
    gs.light_index_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = light_index_size,
    })
    assert(gs.light_index_buf != nil, "Failed to create light index buffer")

    gs.region_dirty = true

    gs.far_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = u32(FAR_TABLE_BYTES + len(gs.far_cells) * size_of(u32)),
    })
    assert(gs.far_buf != nil, "Failed to create far terrain buffer")
    gs.far_tiles_dirty = true

    // Slot tables from the startup world; the startup bricks are queued in
    // dirty_slots and go up with the first flush_gpu_uploads.
    gpu_upload_buffer(gs, gs.index_buf, raw_data(gs.gpu_index),       int(index_buf_size))
    gpu_upload_buffer(gs, gs.owner_buf, raw_data(gs.gpu_chunk_owner), int(owner_buf_size))
    gpu_upload_buffer(gs, gs.light_index_buf, raw_data(gs.gpu_light_index), int(light_index_size))
}

// Persistent upload staging: one per upload kind, grown by doubling and
// mapped with cycling, so a buffer the GPU may still be reading is never
// overwritten. Creating a transfer buffer per upload (and submitting a
// command buffer per kind) was mostly driver overhead while streaming.
Staging :: struct {
    buf:  ^SDL.GPUTransferBuffer,
    size: int,
}

// The buffers the brick pools fill, sized to the pools (world.odin
// brick_cap_for / light_cap_for): voxels at a byte a voxel, the shader
// reading them as StructuredBuffer<uint> (4 voxels per uint); occupancy
// masks, 16 uints (512 bits) a brick; light bricks, a u16 a voxel.
gpu_create_pool_buffers :: proc(gs: ^Game_State) {
    bricks := len(gs.brick_pool.free_ids)
    make_buf :: proc(gs: ^Game_State, size: int, what: string) -> ^SDL.GPUBuffer {
        b := SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{usage = {.COMPUTE_STORAGE_READ}, size = u32(size)})
        fmt.assertf(b != nil, "Failed to create the %s buffer", what)
        return b
    }
    gs.voxel_buf      = make_buf(gs, bricks * VOXELS_PER_BRICK, "voxel")
    gs.mask_buf       = make_buf(gs, bricks * MASK_U32_PER_BRICK * size_of(u32), "mask")
    gs.light_pool_buf = make_buf(gs, len(gs.light_pool.free_ids) * LIGHT_BRICK_BYTES, "light pool")
}

// A new view distance: the brick pools and their GPU buffers made again at
// its size, and every loaded chunk given bricks in them and re-sent (the
// next frames' uploads; a hitch of a moment, only when the setting
// changes). The old buffers go once the GPU is done with them.
gpu_resize_pools :: proc(gs: ^Game_State) {
    bricks, lights := brick_cap_for(view_radius), light_cap_for(view_radius)
    if bricks == len(gs.brick_pool.free_ids) && lights == len(gs.light_pool.free_ids) { return }
    for slot in 0 ..< len(gs.gpu_index) {
        if gs.gpu_index[slot] >= 0 { set_slot_index(gs, slot, -1) }
        if gs.gpu_light_index[slot] >= 0 { gs.gpu_light_index[slot] = light_index_uniform(LIGHT_SKY) }
    }
    delete(gs.brick_pool.free_ids)
    delete(gs.light_pool.free_ids)
    pool_init(&gs.brick_pool, bricks)
    pool_init(&gs.light_pool, lights)
    clear(&gs.brick_starved)
    clear(&gs.light_starved)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.voxel_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.mask_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.light_pool_buf)
    gpu_create_pool_buffers(gs)
    for slot in 0 ..< len(gs.gpu_index) {
        if gs.gpu_chunk_owner[slot][0] == 0x7fffffff { continue }
        gpu_sync_slot(gs, slot)
        append(&gs.light_dirty, slot)
    }
}

staging_map :: proc(gs: ^Game_State, st: ^Staging, size: int) -> rawptr {
    if size > st.size {
        if st.buf != nil { SDL.ReleaseGPUTransferBuffer(gs.gpu_device, st.buf) } // freed once the GPU is done with it
        n := max(st.size, 1 << 20)
        for n < size { n *= 2 }
        st.buf = SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .UPLOAD, size = u32(n)})
        st.size = n
        return SDL.MapGPUTransferBuffer(gs.gpu_device, st.buf, false)
    }
    return SDL.MapGPUTransferBuffer(gs.gpu_device, st.buf, true)
}

staging_release :: proc(gs: ^Game_State, st: ^Staging) {
    if st.buf != nil { SDL.ReleaseGPUTransferBuffer(gs.gpu_device, st.buf) }
    st^ = {}
}

// This frame's upload command buffer, shared by every flush (submitted
// once at the end of flush_gpu_uploads).
upload_cmd :: proc(gs: ^Game_State) -> ^SDL.GPUCommandBuffer {
    if gs.upload_cmd == nil { gs.upload_cmd = SDL.AcquireGPUCommandBuffer(gs.gpu_device) }
    return gs.upload_cmd
}

// Everything dirty this frame â€” light, far terrain, voxels + slot tables â€”
// staged and copied in one command buffer.
flush_gpu_uploads :: proc(gs: ^Game_State) {
    t0 := time.tick_now()
    flush_light_uploads(gs)
    flush_far_uploads(gs)
    flush_voxel_uploads(gs)
    if gs.upload_cmd != nil {
        _ = SDL.SubmitGPUCommandBuffer(gs.upload_cmd)
        gs.upload_cmd = nil
        profile_add(.Upload_All, t0)
    }
    // A big one-off upload (loading in, a new view distance) grew a staging
    // buffer far past what a frame needs: let it go (released once the GPU
    // is done with it) rather than keep hundreds of MB for good.
    for st in ([3]^Staging{&gs.stage_voxel, &gs.stage_light, &gs.stage_far}) {
        if st.size > STAGING_KEEP { staging_release(gs, st) }
    }
}

STAGING_KEEP :: 32 << 20

// Flush all dirty chunk slots accumulated this frame: each mixed chunk's voxels plus its occupancy mask (built here
// from the voxels), and the slot tables if they changed. Upload cost is
// dominated by the NUMBER of UploadToGPUBuffer calls (~6.7Âµs/call driver
// overhead), not bytes, so the transfer buffer is packed in destination
// order and emitted as a few coalesced uploads over contiguous runs.
flush_voxel_uploads :: proc(gs: ^Game_State) {
    // Chunks that found the voxel pool full (drawn as air) get bricks as
    // they come free.
    for len(gs.brick_starved) > 0 && gs.brick_pool.free_top > 0 {
        gpu_sync_slot(gs, pop(&gs.brick_starved))
    }
    if len(gs.dirty_slots) == 0 && !gs.index_dirty && !gs.owner_dirty && !gs.region_dirty { return }
    t_up := time.tick_now()
    defer profile_add(.GPU_Upload, t_up)

    mask_bytes  :: MASK_U32_PER_BRICK * size_of(u32)
    index_plane :: PLANE_SLOTS * size_of(i32)
    owner_plane :: PLANE_SLOTS * size_of([2]i32)
    region_bytes := REGION_COUNT * size_of(u32)
    index_planes := take_planes(&gs.index_planes)
    owner_planes := take_planes(&gs.owner_planes)
    index_bytes := len(index_planes) * index_plane
    owner_bytes := len(owner_planes) * owner_plane

    // Bricks to upload: the current pool id of each dirty slot that still
    // holds a mixed chunk, sorted so contiguous ids coalesce.
    Brick_Upload :: struct { pid: int, chunk: ^Chunk }
    seen: map[int]bool
    defer delete(seen)
    ups: [dynamic]Brick_Upload
    defer delete(ups)
    for s in gs.dirty_slots {
        if s in seen { continue }
        seen[s] = true
        pid := gs.gpu_index[s]
        c := slot_chunk(gs, s)
        if pid < 0 || c == nil || c.voxels == nil { continue }
        append(&ups, Brick_Upload{int(pid), c})
    }
    clear(&gs.dirty_slots)
    slice.sort_by(ups[:], proc(a, b: Brick_Upload) -> bool { return a.pid < b.pid })

    mask_off  := len(ups) * VOXELS_PER_BRICK
    index_off := mask_off + len(ups) * mask_bytes
    owner_off := index_off + index_bytes
    region_off := owner_off + owner_bytes
    total      := region_off + (gs.region_dirty ? region_bytes : 0)
    if total == 0 {
        gs.index_dirty, gs.owner_dirty, gs.region_dirty = false, false, false
        return
    }
    base := uintptr(staging_map(gs, &gs.stage_voxel, total))
    transfer := gs.stage_voxel.buf
    pids := make([]int, len(ups))
    defer delete(pids)
    for u, i in ups {
        pids[i] = u.pid
        mem.copy(rawptr(base + uintptr(i * VOXELS_PER_BRICK)), u.chunk.voxels, VOXELS_PER_BRICK)
        mask := ([^]u32)(rawptr(base + uintptr(mask_off + i * mask_bytes)))
        for w in 0 ..< MASK_U32_PER_BRICK {
            bits: u32
            for b in 0 ..< 32 {
                if u.chunk.voxels[w * 32 + b] != 0 { bits |= 1 << u32(b) }
            }
            mask[w] = bits
        }
    }
    stage_planes(base, index_off, slice.to_bytes(gs.gpu_index), index_planes, index_plane)
    stage_planes(base, owner_off, slice.to_bytes(gs.gpu_chunk_owner), owner_planes, owner_plane)
    if gs.region_dirty { mem.copy(rawptr(base + uintptr(region_off)), raw_data(gs.region_count), region_bytes) }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    copy_pass := SDL.BeginGPUCopyPass(upload_cmd(gs))
    upload_runs(copy_pass, transfer, gs.voxel_buf, pids, VOXELS_PER_BRICK, 0)
    upload_runs(copy_pass, transfer, gs.mask_buf,  pids, mask_bytes, mask_off)
    // Slot tables: only the changed ring planes, one upload per run of
    // adjacent planes (a column's slots all sit in one plane).
    upload_runs(copy_pass, transfer, gs.index_buf, index_planes, index_plane, index_off)
    upload_runs(copy_pass, transfer, gs.owner_buf, owner_planes, owner_plane, owner_off)
    if gs.region_dirty {
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(region_off)},
            SDL.GPUBufferRegion{buffer = gs.index_buf, offset = u32(len(gs.gpu_index) * size_of(i32)), size = u32(region_bytes)}, // tail of index_buf
            false)
    }
    SDL.EndGPUCopyPass(copy_pass)

    gs.index_dirty  = false
    gs.owner_dirty  = false
    gs.region_dirty = false
}

// The dirty planes of a slot table, cleared, in ascending order.
take_planes :: proc(planes: ^[CHUNKS_W]bool) -> []int {
    out := make([dynamic]int, context.temp_allocator)
    for &d, i in planes {
        if d { append(&out, i); d = false }
    }
    return out[:]
}

// Copy the listed planes of a slot table (plane_bytes each) into staging
// at `off`, packed in order for upload_runs.
stage_planes :: proc(base: uintptr, off: int, table: []u8, planes: []int, plane_bytes: int) {
    for p, i in planes {
        mem.copy(rawptr(base + uintptr(off + i * plane_bytes)), &table[p * plane_bytes], plane_bytes)
    }
}

// Coalesce a destination-sorted index list into one UploadToGPUBuffer
// per maximal contiguous run. `keys[i]` is the destination block index
// of the i-th packed element; transfer bytes are contiguous in the same
// order, so a run of consecutive keys is one copy.
upload_runs :: proc(copy_pass: ^SDL.GPUCopyPass, transfer: ^SDL.GPUTransferBuffer,
    dst: ^SDL.GPUBuffer, keys: []int, block: int, base_xfer_off: int, dst_base := 0) {
    i := 0
    for i < len(keys) {
        run_start := i
        for i+1 < len(keys) && keys[i+1] == keys[i]+1 { i += 1 }
        run_len := i - run_start + 1
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{
                transfer_buffer = transfer,
                offset = u32(base_xfer_off + run_start * block)},
            SDL.GPUBufferRegion{
                buffer = dst,
                offset = u32(dst_base + keys[run_start] * block),
                size   = u32(run_len * block)},
            false)
        i += 1
    }
}

@(private="file")
g_light_pool_warned: bool

// Sync the GPU light of every dirty ring slot. A chunk with uniform light is
// encoded straight into gpu_light_index; one whose light varies gets a light
// pool brick holding its 512 u16s. Same coalesced upload as the voxels.
flush_light_uploads :: proc(gs: ^Game_State) {
    // Chunks that found the pool full show full sky until they get a brick:
    // retried as bricks come free (columns unloading behind you), not only
    // when their light changes again, so an overflow heals as you move.
    if n := min(len(gs.light_starved), int(gs.light_pool.free_top)); n > 0 {
        append(&gs.light_dirty, ..gs.light_starved[len(gs.light_starved) - n:])
        resize(&gs.light_starved, len(gs.light_starved) - n)
    }
    if len(gs.light_dirty) == 0 { return }

    seen: map[int]bool
    defer delete(seen)
    Light_Upload :: struct { pid: int, light: ^[VOXELS_PER_BRICK]u16 }
    ups: [dynamic]Light_Upload
    defer delete(ups)
    for slot in gs.light_dirty {
        if slot in seen { continue }
        seen[slot] = true
        gs.light_planes[slot / PLANE_SLOTS] = true
        owner := gs.gpu_chunk_owner[slot]
        if owner[0] == 0x7fffffff { continue }
        key := [3]int{int(owner[0]), (slot / CHUNKS_W) % CHUNKS_H + WORLD_CHUNK_Y_MIN, int(owner[1])}
        chunk := world_chunk(gs, key)
        lid := gs.gpu_light_index[slot]
        if chunk == nil || chunk.light == nil {
            if lid >= 0 { pool_free(&gs.light_pool, lid) }
            gs.gpu_light_index[slot] = light_index_uniform(chunk == nil ? LIGHT_SKY : chunk.light_fill)
            continue
        }
        if lid < 0 {
            lid = pool_alloc(&gs.light_pool)
            if lid < 0 {
                if !g_light_pool_warned {
                    g_light_pool_warned = true
                    fmt.eprintln("WARNING: light pool exhausted (chunks wait as full sky); raise MAX_LIGHT_BRICKS.")
                    ui_toast(gs, "Light memory full: some places light wrong (try a shorter view distance)", 4)
                }
                gs.gpu_light_index[slot] = light_index_uniform(LIGHT_SKY)
                append(&gs.light_starved, slot)
                continue
            }
            gs.gpu_light_index[slot] = lid
        }
        append(&ups, Light_Upload{int(lid), chunk.light})
    }
    clear(&gs.light_dirty)
    slice.sort_by(ups[:], proc(a, b: Light_Upload) -> bool { return a.pid < b.pid })

    index_plane :: PLANE_SLOTS * size_of(i32)
    planes      := take_planes(&gs.light_planes)
    index_off   := len(ups) * LIGHT_BRICK_BYTES
    if index_off + len(planes) * index_plane == 0 { return }
    base := uintptr(staging_map(gs, &gs.stage_light, index_off + len(planes) * index_plane))
    transfer := gs.stage_light.buf
    pids := make([]int, len(ups))
    defer delete(pids)
    for u, i in ups {
        mem.copy(rawptr(base + uintptr(i * LIGHT_BRICK_BYTES)), u.light, LIGHT_BRICK_BYTES)
        pids[i] = u.pid
    }
    stage_planes(base, index_off, slice.to_bytes(gs.gpu_light_index), planes, index_plane)
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    copy_pass := SDL.BeginGPUCopyPass(upload_cmd(gs))
    upload_runs(copy_pass, transfer, gs.light_pool_buf, pids, LIGHT_BRICK_BYTES, 0)
    upload_runs(copy_pass, transfer, gs.light_index_buf, planes, index_plane, index_off)
    SDL.EndGPUCopyPass(copy_pass)
}

gpu_upload_buffer :: proc(gs: ^Game_State, dst: ^SDL.GPUBuffer, data: rawptr, size: int, dst_offset := 0) {
    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, SDL.GPUTransferBufferCreateInfo{
        usage = .UPLOAD,
        size  = u32(size),
    })
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)

    ptr := SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false)
    mem.copy(ptr, data, size)
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    copy_pass := SDL.BeginGPUCopyPass(cmd)
    SDL.UploadToGPUBuffer(copy_pass,
        SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = 0},
        SDL.GPUBufferRegion{buffer = dst, offset = u32(dst_offset), size = u32(size)},
        false)
    SDL.EndGPUCopyPass(copy_pass)
    _ = SDL.SubmitGPUCommandBuffer(cmd)
}

GPU_TIME_EVERY :: 15 // frames between timed frames while the debug panel is open

// gpu_render, timing the GPU now and then for the debug panel (F3). While it
// is open, every GPU_TIME_EVERY frames one frame runs on an idle GPU: wait
// for idle, submit, wait for its fence. Exact, where timing frames queued
// behind others would count their wait too; the stall shows as a slight
// dip in fps while the panel is open, and costs nothing when it's closed.
gpu_render_timed :: proc(gs: ^Game_State) {
    gs.gpu_time_wait -= 1
    if !gs.ui.debug_open || gs.gpu_time_wait > 0 { gpu_render(gs); return }
    gs.gpu_time_wait = GPU_TIME_EVERY
    _ = SDL.WaitForGPUIdle(gs.gpu_device)
    t := time.tick_now()
    fence := gpu_render(gs, want_fence = true)
    if fence == nil { return }
    _ = SDL.WaitForGPUFences(gs.gpu_device, true, &fence, 1)
    SDL.ReleaseGPUFence(gs.gpu_device, fence)
    ms := f32(time.duration_milliseconds(time.tick_since(t)))
    gs.gpu_ms = gs.gpu_ms == 0 ? ms : gs.gpu_ms + (ms - gs.gpu_ms) * 0.3
    gi_time(gs)
}

// want_fence: return a fence for the submission (bench mode times the GPU
// with it); the caller must release it. Otherwise returns nil.
gpu_render :: proc(gs: ^Game_State, want_fence := false) -> ^SDL.GPUFence {
    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    if cmd == nil { return nil }

    // This frame's entity instances (staged by entities_update).
    if gs.ent_upload_size > 0 {
        cp := SDL.BeginGPUCopyPass(cmd)
        SDL.UploadToGPUBuffer(cp,
            SDL.GPUTransferBufferLocation{transfer_buffer = gs.ent_transfer, offset = 0},
            SDL.GPUBufferRegion{buffer = gs.entity_buf, offset = u32(gs.ent_dyn_base * 16), size = u32(gs.ent_upload_size)},
            false)
        SDL.EndGPUCopyPass(cp)
        gs.ent_upload_size = 0
    }

    fwd, right, up := camera_view_basis(gs.camera, render_aspect(gs))
    render_pos := camera_view_eye(gs.camera)
    // Near region drawn as voxels: only as far out as columns are actually
    // loaded, so while streaming catches up (fast travel) the far terrain
    // fills in instead of empty space. The bench can shrink it further to
    // compare the far terrain against the voxels it stands in for.
    near_r := loaded_radius(gs)
    if gs.near_radius_override > 0 { near_r = min(near_r, gs.near_radius_override) }
    uniform := Camera_Uniform{
        pos            = render_pos,
        fwd            = fwd,
        right          = right,
        up             = up,
        light_dir      = gs.light_dir,
        reflect_amount = gs.reflect_amount,
        quality        = gs.aa_samples * 10 + gs.shadow_rays,
        vol            = (gs.vol_enabled ? 100 : 0) + gs.vol_steps,
        entity_count   = gs.entity_count,
        time           = f32(SDL.GetTicks()) / 1000.0,
        exposure       = gs.exposure * gs.sky.eye,
        fog_density    = gs.fog_density,
        cave_factor    = gs.cave_factor,
        sun_intensity  = gs.sun_intensity,
        far_enabled    = gs.far_enabled ? 1 : 0,
        ent_debug      = i32(gs.ent_debug) | (gs.clouds_enabled ? 0 : 4) | (gs.no_textures ? 32 : 0),
        // Columns whose centers lie within near_r of the player's column are
        // loaded; shrink by a column's half-diagonal so the circle only
        // covers loaded voxels.
        near_circle    = {
            f32(gs.player_chunk.x * CHUNK_VOXELS + CHUNK_VOXELS / 2),
            f32(gs.player_chunk.z * CHUNK_VOXELS + CHUNK_VOXELS / 2),
            max(f32(near_r * CHUNK_VOXELS) - 6, 0),
            0,
        },
        sun_true       = {gs.sky.sun_true.x, gs.sky.sun_true.y, gs.sky.sun_true.z, gs.sky.night},
        atmos          = {gs.sky.mist, 0, 0, 0},
    }
    sky_thermals_update(gs)
    // The cumulus shrink as the sun sinks and the thermals under them die,
    // and are gone by night.
    heat := thermal_heat(gs.day)
    clouds := 0
    if heat > 0.05 {
        for th in gs.sky_thermals[:gs.sky_thermal_count] {
            // The column leans downwind ~0.08 m per metre of height.
            c := th.centre + glider_wind(gs.glider.wind_time).xz * ((CUMULUS_BASE - th.ground) * 0.08)
            uniform.thermals[clouds] = {c.x, c.y, th.cloud_r * (0.4 + 0.6 * heat), th.strength}
            for k in 0 ..< 4 { uniform.cloud_puffs[clouds * 4 + k] = th.puffs[k] }
            clouds += 1
        }
    }
    uniform.thermal_count.x = i32(clouds)
    uniform.hand_light = hand_light(gs, render_pos, fwd, right, up)
    uniform.gi_origin, uniform.gi_frame = gi_uniforms(gs, render_pos)
    uniform.torch = torch_uniform(gs, render_pos)
    uniform.torch_params = {gs.torch.floor, 0, 0, 0}
    gs.gi.uniform = uniform // gi_time runs the probe pass again with it
    SDL.PushGPUComputeUniformData(cmd, 0, &uniform, size_of(uniform))

    // --- Pass 0: renew a share of the bounce-light probes (gi.odin); the
    // torch shadow lists if they changed (torch.odin) ---
    gi_dispatch(gs, cmd)
    torch_copy(gs, cmd)

    ro_bufs := [4]^SDL.GPUBuffer{gs.voxel_buf, gs.index_buf, gs.owner_buf, gs.mask_buf}
    // The tracer additionally reads the voxel light (t4, t5) and the
    // entity list (t6).
    ro_bufs_tracer := [8]^SDL.GPUBuffer{gs.voxel_buf, gs.index_buf, gs.owner_buf, gs.mask_buf, gs.light_index_buf, gs.light_pool_buf, gs.entity_buf, gs.far_buf}

    // Threadgroup counts at the current render resolution (ceil-divide by the
    // 16Ã—16 group; shaders guard out-of-range threads so over-dispatch is safe).
    groups_x  := u32((gs.render_w + 15) / 16)
    groups_y  := u32((gs.render_h + 15) / 16)
    hgroups_x := u32((gs.render_w/2 + 15) / 16)
    hgroups_y := u32((gs.render_h/2 + 15) / 16)

    // --- Pass 1: main raytrace â†’ out_texture (+ depth_texture) ---
    rw_main := [2]SDL.GPUStorageTextureReadWriteBinding{
        { texture = gs.out_texture,   cycle = true },
        { texture = gs.depth_texture, cycle = true },
    }

    p1 := SDL.BeginGPUComputePass(cmd, raw_data(rw_main[:]), 2, nil, 0)
    SDL.BindGPUComputePipeline(p1, gs.pipeline)
    ro_tex := [4]^SDL.GPUTexture{gs.gi.irr, gs.gi.vis, gs.torch.emit_tex, gs.torch.cell_tex}
    SDL.BindGPUComputeStorageTextures(p1, 0, raw_data(ro_tex[:]), 4)
    SDL.BindGPUComputeStorageBuffers(p1, 0, raw_data(ro_bufs_tracer[:]), 8)
    SDL.DispatchGPUCompute(p1, groups_x, groups_y, 1)
    SDL.EndGPUComputePass(p1)

    // --- Pass 2: half-res volumetric march â†’ vol_texture ---
    // Reads depth (RO storage tex, t0) + voxel buffers (t1..t4). Skipped when
    // off: composite then ignores vol_texture.
    if gs.vol_enabled {
        rw_vol := SDL.GPUStorageTextureReadWriteBinding{ texture = gs.vol_texture, cycle = true }
        p2 := SDL.BeginGPUComputePass(cmd, &rw_vol, 1, nil, 0)
        SDL.BindGPUComputePipeline(p2, gs.vol_pipeline)
        vol_ro_tex := [1]^SDL.GPUTexture{ gs.depth_texture }
        SDL.BindGPUComputeStorageTextures(p2, 0, raw_data(vol_ro_tex[:]), 1)
        SDL.BindGPUComputeStorageBuffers(p2, 0, raw_data(ro_bufs[:]), 4)
        SDL.DispatchGPUCompute(p2, hgroups_x, hgroups_y, 1)
        SDL.EndGPUComputePass(p2)
    }

    // --- Pass 2b-d: bloom (half-res) â€” prefilter â†’ blur H â†’ blur V ---------
    // prefilter: scene â†’ bloom[0]; H: bloom[0] â†’ bloom[1]; V: bloom[1] â†’ bloom[0].
    {
        bloom_pass :: proc(cmd: ^SDL.GPUCommandBuffer, pipeline: ^SDL.GPUComputePipeline,
            src: ^SDL.GPUTexture, dst: ^SDL.GPUTexture, gx, gy: u32) {
            rw := SDL.GPUStorageTextureReadWriteBinding{texture = dst, cycle = true}
            p := SDL.BeginGPUComputePass(cmd, &rw, 1, nil, 0)
            SDL.BindGPUComputePipeline(p, pipeline)
            ro := src
            SDL.BindGPUComputeStorageTextures(p, 0, &ro, 1)
            SDL.DispatchGPUCompute(p, gx, gy, 1)
            SDL.EndGPUComputePass(p)
        }
        bloom_pass(cmd, gs.bloom_pre_pipeline, gs.out_texture,      gs.bloom_texture[0], hgroups_x, hgroups_y)
        bloom_pass(cmd, gs.bloom_h_pipeline,   gs.bloom_texture[0], gs.bloom_texture[1], hgroups_x, hgroups_y)
        bloom_pass(cmd, gs.bloom_v_pipeline,   gs.bloom_texture[1], gs.bloom_texture[0], hgroups_x, hgroups_y)
    }

    // --- Pass 3: composite (vol upscale + bloom add + tonemap) â†’ out_texture ---
    // Reads vol (t0) + depth (t1) + bloom (t2) as RO storage textures; RW out_texture.
    rw_comp := SDL.GPUStorageTextureReadWriteBinding{ texture = gs.out_texture, cycle = false }
    p3 := SDL.BeginGPUComputePass(cmd, &rw_comp, 1, nil, 0)
    SDL.BindGPUComputePipeline(p3, gs.comp_pipeline)
    comp_ro_tex := [3]^SDL.GPUTexture{ gs.vol_texture, gs.depth_texture, gs.bloom_texture[0] }
    SDL.BindGPUComputeStorageTextures(p3, 0, raw_data(comp_ro_tex[:]), 3)
    SDL.DispatchGPUCompute(p3, groups_x, groups_y, 1)
    SDL.EndGPUComputePass(p3)

    // Swapchain presentation is owned by the SDL.Renderer in ui.odin
    // (see ui_build_and_render). It draws out_texture as a fullscreen quad,
    // then Clay UI on top, then calls SDL.RenderPresent.
    if want_fence { return SDL.SubmitGPUCommandBufferAndAcquireFence(cmd) }
    _ = SDL.SubmitGPUCommandBuffer(cmd)
    return nil
}

gpu_destroy :: proc(gs: ^Game_State) {
    _ = SDL.WaitForGPUIdle(gs.gpu_device)
    gpu_release_scene_textures(gs)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.voxel_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.index_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.owner_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.mask_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.far_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.light_index_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.light_pool_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.entity_buf)
    SDL.ReleaseGPUTransferBuffer(gs.gpu_device, gs.ent_transfer)
    gi_destroy(gs)
    torch_destroy(gs)
    staging_release(gs, &gs.stage_voxel)
    staging_release(gs, &gs.stage_light)
    staging_release(gs, &gs.stage_far)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.vol_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.comp_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.bloom_pre_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.bloom_h_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.bloom_v_pipeline)
    SDL.ReleaseWindowFromGPUDevice(gs.gpu_device, gs.window)
    SDL.DestroyGPUDevice(gs.gpu_device)
}
