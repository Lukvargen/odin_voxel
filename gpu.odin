package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:time"
import SDL "vendor:sdl3"

TEX_W :: 800
TEX_H :: 800

// Default internal render scale (divisor of the window resolution). The scene
// is ray traced into a (TEX_W/scale)×(TEX_H/scale) texture and upscaled to the
// window. scale > 1 trades resolution for a large primary-ray-cost saving (and
// a deliberate pixel-art look with nearest-neighbor display). The live value is
// gs.render_scale, changeable at runtime via gpu_set_render_scale (1/2/4 only,
// so render_w stays a multiple of the 16-wide threadgroup).
RENDER_SCALE :: 1

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
    entity_count:   i32,   // active SDF entities uploaded this frame (entities.odin)
    time:           f32,   // seconds: cloud drift, flicker
    exposure:       f32,   // pre-tonemap multiplier
    fog_density:    f32,   // base distance-fog density
    cave_factor:    f32,   // 0 surface .. 1 deep underground (CPU-smoothed)
    sun_intensity:  f32,   // sun direct-light multiplier
    far_enabled:    i32,
    _pad5:          [2]f32,
    near_box:       [4]i32, // voxel XZ box of the near (voxel) region: min x, min z, max x, max z
}

// (Re)create the scene color, depth, and half-res volumetric textures at the
// current internal render resolution (gs.render_w/h). The caller owns the
// lifetime of any previous textures (release them first, or use
// gpu_set_render_scale which does). Buffers and pipelines are untouched.
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

// Switch the internal render resolution at runtime. `scale` must be 1/2/4 so
// render_w stays a multiple of the 16-wide threadgroup. Waits for the GPU to
// idle, releases the old scene textures + the wrapped SDL texture, recreates
// them at the new size, and rebuilds the UI texture wrap. No-op if unchanged.
gpu_set_render_scale :: proc(gs: ^Game_State, scale: i32) {
    if scale == gs.render_scale { return }
    if scale != 1 && scale != 2 && scale != 4 { return }

    _ = SDL.WaitForGPUIdle(gs.gpu_device)

    SDL.ReleaseGPUTexture(gs.gpu_device, gs.out_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.depth_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.vol_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.bloom_texture[0])
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.bloom_texture[1])

    gs.render_scale = scale
    gs.render_w     = TEX_W / scale
    gs.render_h     = TEX_H / scale

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

    // SPIR-V embedded at compile time — no runtime file dependency
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
        num_readonly_storage_buffers   = 8, // voxel_chunk (t0), chunk_index + region counts (t1), chunk_owner (t2), voxel_mask (t3), light_index (t4), light_pool (t5), sdf_entities (t6), far_data (t7)
        num_readwrite_storage_textures = 2, // img_output (u0), depth_output (u1)
        num_uniform_buffers            = 1, // CameraUniforms (b0)
        threadcount_x                  = 16,
        threadcount_y                  = 16,
        threadcount_z                  = 1,
    }
    gs.pipeline = SDL.CreateGPUComputePipeline(gs.gpu_device, pipeline_info)
    assert(gs.pipeline != nil, "Failed to create compute pipeline")

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

    // SDF entity list (entities.odin). Tiny; re-uploaded whenever entities exist.
    gs.entity_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = ENTITY_BUF_SIZE,
    })
    assert(gs.entity_buf != nil, "Failed to create entity buffer")

    // Scene color/depth/volumetric textures, sized to the current internal
    // render resolution (gs.render_w/h). Recreated on render-scale change.
    gpu_create_scene_textures(gs)

    // GPU buffers for voxel data (read-only in compute). The voxel pool is
    // 1 byte/voxel, read by the shader as StructuredBuffer<uint> (4 voxels
    // per uint); the mask pool is 16 uints (512 occupancy bits) per brick.
    // Both are filled per brick by flush_gpu_uploads.
    voxel_buf_size := u32(MAX_RESIDENT_BRICKS * VOXELS_PER_BRICK)
    mask_buf_size  := u32(MAX_RESIDENT_BRICKS * MASK_U32_PER_BRICK * size_of(u32))
    index_buf_size := u32(len(gs.gpu_index)  * size_of(i32))
    region_bytes   := u32(REGION_COUNT * size_of(u32)) // after the index (see pipeline above)

    gs.voxel_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = voxel_buf_size,
    })
    assert(gs.voxel_buf != nil, "Failed to create voxel buffer")

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
    gs.light_pool_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = MAX_LIGHT_BRICKS * VOXELS_PER_BRICK,
    })
    assert(gs.light_pool_buf != nil, "Failed to create light pool buffer")

    gs.mask_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = mask_buf_size,
    })
    assert(gs.mask_buf != nil, "Failed to create mask buffer")

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

gpu_upload_buffer_range :: proc(gs: ^Game_State, dst: ^SDL.GPUBuffer, data: rawptr, size: int, dst_offset: int) {
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

// Flush all dirty chunk slots accumulated this frame in a single GPU
// submission: each mixed chunk's voxels plus its occupancy mask (built here
// from the voxels), and the slot tables if they changed. Upload cost is
// dominated by the NUMBER of UploadToGPUBuffer calls (~6.7µs/call driver
// overhead), not bytes, so the transfer buffer is packed in destination
// order and emitted as a few coalesced uploads over contiguous runs.
flush_gpu_uploads :: proc(gs: ^Game_State) {
    flush_light_uploads(gs)
    flush_far_uploads(gs)
    if len(gs.dirty_slots) == 0 && !gs.index_dirty && !gs.owner_dirty && !gs.region_dirty { return }
    t_up := time.tick_now()
    defer profile_add(.GPU_Upload, t_up)

    mask_bytes  :: MASK_U32_PER_BRICK * size_of(u32)
    index_bytes := len(gs.gpu_index) * size_of(i32)
    owner_bytes := len(gs.gpu_chunk_owner) * size_of([2]i32)
    region_bytes := REGION_COUNT * size_of(u32)

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
    owner_off := index_off + (gs.index_dirty ? index_bytes : 0)
    region_off := owner_off + (gs.owner_dirty ? owner_bytes : 0)
    total      := region_off + (gs.region_dirty ? region_bytes : 0)
    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, SDL.GPUTransferBufferCreateInfo{
        usage = .UPLOAD,
        size  = u32(total),
    })
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)

    base := uintptr(SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false))
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
    if gs.index_dirty { mem.copy(rawptr(base + uintptr(index_off)), raw_data(gs.gpu_index), index_bytes) }
    if gs.owner_dirty { mem.copy(rawptr(base + uintptr(owner_off)), raw_data(gs.gpu_chunk_owner), owner_bytes) }
    if gs.region_dirty { mem.copy(rawptr(base + uintptr(region_off)), raw_data(gs.region_count), region_bytes) }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    copy_pass := SDL.BeginGPUCopyPass(cmd)
    upload_runs(copy_pass, transfer, gs.voxel_buf, pids, VOXELS_PER_BRICK, 0)
    upload_runs(copy_pass, transfer, gs.mask_buf,  pids, mask_bytes, mask_off)
    // Slot tables: single wholesale uploads. Per-slot was measured WORSE
    // (many tiny calls); one 4 MB copy is one call.
    if gs.index_dirty {
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(index_off)},
            SDL.GPUBufferRegion{buffer = gs.index_buf, offset = 0, size = u32(index_bytes)},
            false)
    }
    if gs.owner_dirty {
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(owner_off)},
            SDL.GPUBufferRegion{buffer = gs.owner_buf, offset = 0, size = u32(owner_bytes)},
            false)
    }
    if gs.region_dirty {
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(region_off)},
            SDL.GPUBufferRegion{buffer = gs.index_buf, offset = u32(index_bytes), size = u32(region_bytes)},
            false)
    }
    SDL.EndGPUCopyPass(copy_pass)
    _ = SDL.SubmitGPUCommandBuffer(cmd)

    gs.index_dirty  = false
    gs.owner_dirty  = false
    gs.region_dirty = false
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
// pool brick holding its 512 bytes. Same coalesced upload as the voxels.
flush_light_uploads :: proc(gs: ^Game_State) {
    if len(gs.light_dirty) == 0 { return }

    seen: map[int]bool
    defer delete(seen)
    Light_Upload :: struct { pid: int, light: ^[VOXELS_PER_BRICK]u8 }
    ups: [dynamic]Light_Upload
    defer delete(ups)
    for slot in gs.light_dirty {
        if slot in seen { continue }
        seen[slot] = true
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
                    fmt.eprintln("WARNING: light pool exhausted; raise MAX_LIGHT_BRICKS.")
                }
                gs.gpu_light_index[slot] = light_index_uniform(LIGHT_SKY)
                continue
            }
            gs.gpu_light_index[slot] = lid
        }
        append(&ups, Light_Upload{int(lid), chunk.light})
    }
    clear(&gs.light_dirty)
    slice.sort_by(ups[:], proc(a, b: Light_Upload) -> bool { return a.pid < b.pid })

    index_bytes := len(gs.gpu_light_index) * size_of(i32)
    index_off   := len(ups) * VOXELS_PER_BRICK
    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, SDL.GPUTransferBufferCreateInfo{
        usage = .UPLOAD,
        size  = u32(index_off + index_bytes),
    })
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)
    base := uintptr(SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false))
    pids := make([]int, len(ups))
    defer delete(pids)
    for u, i in ups {
        mem.copy(rawptr(base + uintptr(i * VOXELS_PER_BRICK)), u.light, VOXELS_PER_BRICK)
        pids[i] = u.pid
    }
    mem.copy(rawptr(base + uintptr(index_off)), raw_data(gs.gpu_light_index), index_bytes)
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    copy_pass := SDL.BeginGPUCopyPass(cmd)
    upload_runs(copy_pass, transfer, gs.light_pool_buf, pids, VOXELS_PER_BRICK, 0)
    SDL.UploadToGPUBuffer(copy_pass,
        SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(index_off)},
        SDL.GPUBufferRegion{buffer = gs.light_index_buf, offset = 0, size = u32(index_bytes)},
        false)
    SDL.EndGPUCopyPass(copy_pass)
    _ = SDL.SubmitGPUCommandBuffer(cmd)
}

gpu_upload_buffer :: proc(gs: ^Game_State, dst: ^SDL.GPUBuffer, data: rawptr, size: int) {
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
        SDL.GPUBufferRegion{buffer = dst, offset = 0, size = u32(size)},
        false)
    SDL.EndGPUCopyPass(copy_pass)
    _ = SDL.SubmitGPUCommandBuffer(cmd)
}

// want_fence: return a fence for the submission (bench mode times the GPU
// with it); the caller must release it. Otherwise returns nil.
gpu_render :: proc(gs: ^Game_State, want_fence := false) -> ^SDL.GPUFence {
    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    if cmd == nil { return nil }

    fwd, right, up := camera_basis(gs.camera)
    render_pos := gs.camera.pos
    render_pos.y += gs.camera.step_visual_offset
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
        exposure       = gs.exposure,
        fog_density    = gs.fog_density,
        cave_factor    = gs.cave_factor,
        sun_intensity  = gs.sun_intensity,
        far_enabled    = gs.far_enabled ? 1 : 0,
        near_box       = {
            i32((gs.player_chunk.x - near_r) * CHUNK_VOXELS),
            i32((gs.player_chunk.z - near_r) * CHUNK_VOXELS),
            i32((gs.player_chunk.x + near_r + 1) * CHUNK_VOXELS),
            i32((gs.player_chunk.z + near_r + 1) * CHUNK_VOXELS),
        },
    }
    SDL.PushGPUComputeUniformData(cmd, 0, &uniform, size_of(uniform))

    ro_bufs := [4]^SDL.GPUBuffer{gs.voxel_buf, gs.index_buf, gs.owner_buf, gs.mask_buf}
    // The tracer additionally reads the voxel light (t4, t5) and the SDF
    // entity list (t6).
    ro_bufs_tracer := [8]^SDL.GPUBuffer{gs.voxel_buf, gs.index_buf, gs.owner_buf, gs.mask_buf, gs.light_index_buf, gs.light_pool_buf, gs.entity_buf, gs.far_buf}

    // Threadgroup counts at the current render resolution (ceil-divide by the
    // 16×16 group; shaders guard out-of-range threads so over-dispatch is safe).
    groups_x  := u32((gs.render_w + 15) / 16)
    groups_y  := u32((gs.render_h + 15) / 16)
    hgroups_x := u32((gs.render_w/2 + 15) / 16)
    hgroups_y := u32((gs.render_h/2 + 15) / 16)

    // --- Pass 1: main raytrace → out_texture (+ depth_texture) ---
    rw_main := [2]SDL.GPUStorageTextureReadWriteBinding{
        { texture = gs.out_texture,   cycle = true },
        { texture = gs.depth_texture, cycle = true },
    }

    p1 := SDL.BeginGPUComputePass(cmd, raw_data(rw_main[:]), 2, nil, 0)
    SDL.BindGPUComputePipeline(p1, gs.pipeline)
    SDL.BindGPUComputeStorageBuffers(p1, 0, raw_data(ro_bufs_tracer[:]), 8)
    SDL.DispatchGPUCompute(p1, groups_x, groups_y, 1)
    SDL.EndGPUComputePass(p1)

    // --- Pass 2: half-res volumetric march → vol_texture ---
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

    // --- Pass 2b-d: bloom (half-res) — prefilter → blur H → blur V ---------
    // prefilter: scene → bloom[0]; H: bloom[0] → bloom[1]; V: bloom[1] → bloom[0].
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

    // --- Pass 3: composite (vol upscale + bloom add + tonemap) → out_texture ---
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
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.out_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.depth_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.vol_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.bloom_texture[0])
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.bloom_texture[1])
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.voxel_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.index_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.owner_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.mask_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.far_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.light_index_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.light_pool_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.entity_buf)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.vol_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.comp_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.bloom_pre_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.bloom_h_pipeline)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.bloom_v_pipeline)
    SDL.ReleaseWindowFromGPUDevice(gs.gpu_device, gs.window)
    SDL.DestroyGPUDevice(gs.gpu_device)
}
