package main

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:time"
import SDL "vendor:sdl3"

TEX_W :: 800
TEX_H :: 800

// Matches cbuffer CameraUniforms in voxel_tracer.hlsl.
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
    reflect_amount:   i32,
    player_chunk_x:   i32,
    player_chunk_z:   i32,
    quality:          i32,   // packed: AA*10 + shadow_rays
    vol:              i32,   // packed: enabled*100 + steps (0/16/24/32)
    _padq0:           f32,
    _padq1:           f32,
    _padq2:           f32,
}

gpu_init :: proc(gs: ^Game_State) {
    // SDL3 GPU device (SPIR-V shaders, debug mode on)
    gs.gpu_device = SDL.CreateGPUDevice({.SPIRV}, true, nil)
    assert(gs.gpu_device != nil, "Failed to create GPU device")
    fmt.println("GPU driver:", SDL.GetGPUDeviceDriver(gs.gpu_device))

    // Note: window is claimed by SDL.CreateGPURenderer in ui_init (which
    // shares this GPU device). Claiming it here would conflict.

    // SPIR-V embedded at compile time — no runtime file dependency
    shader_bytes := #load("shaders/voxel_tracer.spv")

    pipeline_info := SDL.GPUComputePipelineCreateInfo{
        code                         = raw_data(shader_bytes),
        code_size                    = len(shader_bytes),
        entrypoint                   = "main",
        format                       = {.SPIRV},
        num_readonly_storage_buffers = 4, // voxel_chunk (t0), chunk_index (t1), chunk_owner (t2), voxel_mask (t3)
        num_readwrite_storage_textures = 2, // img_output (u0), depth_output (u1)
        num_uniform_buffers          = 1, // CameraUniforms (b0)
        threadcount_x                = 16,
        threadcount_y                = 16,
        threadcount_z                = 1,
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
        num_readonly_storage_textures  = 2, // vol_input (t0), depth_input (t1)
        num_readwrite_storage_textures = 1, // img_output (u0)
        num_uniform_buffers            = 1,
        threadcount_x = 16, threadcount_y = 16, threadcount_z = 1,
    })
    assert(gs.comp_pipeline != nil, "Failed to create composite pipeline")

    // Output storage texture (compute writes here each frame)
    gs.out_texture = SDL.CreateGPUTexture(gs.gpu_device, SDL.GPUTextureCreateInfo{
        type                 = .D2,
        format               = .R32G32B32A32_FLOAT,
        usage                = {.COMPUTE_STORAGE_WRITE, .SAMPLER},
        width                = TEX_W,
        height               = TEX_H,
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
        width                = TEX_W,
        height               = TEX_H,
        layer_count_or_depth = 1,
        num_levels           = 1,
    })
    assert(gs.depth_texture != nil, "Failed to create depth texture")

    // Half-res volumetric inscatter. Written by the volumetric pass
    // (storage write), read by composite (RO storage texture / .SAMPLER).
    gs.vol_texture = SDL.CreateGPUTexture(gs.gpu_device, SDL.GPUTextureCreateInfo{
        type                 = .D2,
        format               = .R32G32B32A32_FLOAT,
        usage                = {.COMPUTE_STORAGE_WRITE, .SAMPLER},
        width                = TEX_W / 2,
        height               = TEX_H / 2,
        layer_count_or_depth = 1,
        num_levels           = 1,
    })
    assert(gs.vol_texture != nil, "Failed to create volumetric texture")

    // GPU buffers for voxel data (read-only in compute).
    // gpu_voxels is 1 byte/voxel; the shader reads it as StructuredBuffer<uint>
    // with 4 voxels packed per uint, so the buffer is the raw byte image rounded
    // up to a 4-byte multiple (total*512 is always /4, so this never pads).
    voxel_buf_size := u32((len(gs.gpu_voxels) + 3) / 4 * 4)
    index_buf_size := u32(len(gs.gpu_index)  * size_of(i32))

    gs.voxel_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = voxel_buf_size,
    })
    assert(gs.voxel_buf != nil, "Failed to create voxel buffer")

    gs.index_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = index_buf_size,
    })
    assert(gs.index_buf != nil, "Failed to create index buffer")

    owner_buf_size := u32(len(gs.gpu_chunk_owner) * size_of([2]i32))
    gs.owner_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = owner_buf_size,
    })
    assert(gs.owner_buf != nil, "Failed to create owner buffer")

    mask_buf_size := u32(len(gs.gpu_voxel_mask) * size_of(u32))
    gs.mask_buf = SDL.CreateGPUBuffer(gs.gpu_device, SDL.GPUBufferCreateInfo{
        usage = {.COMPUTE_STORAGE_READ},
        size  = mask_buf_size,
    })
    assert(gs.mask_buf != nil, "Failed to create mask buffer")

    // Pool-sized CPU arrays must match the pool buffers 1:1.
    assert(len(gs.gpu_voxels)     == MAX_RESIDENT_BRICKS * VOXELS_PER_BRICK)
    assert(len(gs.gpu_voxel_mask) == MAX_RESIDENT_BRICKS * MASK_U32_PER_BRICK)

    // Bulk-upload all CPU arrays that were populated by generate_world/stream_chunks
    gpu_upload_buffer(gs, gs.voxel_buf, raw_data(gs.gpu_voxels),      int(voxel_buf_size))
    gpu_upload_buffer(gs, gs.index_buf, raw_data(gs.gpu_index),       int(index_buf_size))
    gpu_upload_buffer(gs, gs.owner_buf, raw_data(gs.gpu_chunk_owner), int(owner_buf_size))
    gpu_upload_buffer(gs, gs.mask_buf,  raw_data(gs.gpu_voxel_mask),  int(mask_buf_size))
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

// Pool-aware single-slot voxel upload (currently unused; flush_gpu_uploads is
// the live path). Resolves the slot's pool id; air slots have no storage.
gpu_upload_chunk :: proc(gs: ^Game_State, slot: int) {
    pid := gs.gpu_index[slot]
    if pid < 0 { return }
    base := int(pid) * VOXELS_PER_BRICK
    // 1 byte/voxel; base and VOXELS_PER_BRICK (512) are both /4 so the SDL
    // copy region stays 4-aligned (required for the packed uint view).
    gpu_upload_buffer_range(gs, gs.voxel_buf, raw_data(gs.gpu_voxels[base:]), VOXELS_PER_BRICK, base)
}

gpu_upload_owner_slot :: proc(gs: ^Game_State, slot: int) {
    byte_off  := slot * size_of([2]i32)
    byte_size := size_of([2]i32)
    gpu_upload_buffer_range(gs, gs.owner_buf, &gs.gpu_chunk_owner[slot], byte_size, byte_off)
}

// Flush all dirty chunk slots accumulated this frame in a single GPU
// submission. GPU_Upload cost is dominated by the NUMBER of
// UploadToGPUBuffer calls (~6.7µs/call driver overhead), not bytes
// (measured: 5108 calls / 882 KiB ≈ 34 ms). So the transfer buffer is
// packed in destination order and emitted as a few large coalesced
// uploads over contiguous destination runs, instead of one call per slot.
flush_gpu_uploads :: proc(gs: ^Game_State) {
    if len(gs.dirty_slots) == 0 && !gs.index_dirty { return }
    t_up := time.tick_now()
    defer profile_add(.GPU_Upload, t_up)

    voxels_per_chunk :: CHUNK_VOXELS * CHUNK_VOXELS * CHUNK_VOXELS
    voxel_chunk_bytes :: voxels_per_chunk // 1 byte/voxel; 512 stays 4-aligned
    mask_chunk_bytes  :: MASK_U32_PER_BRICK * size_of(u32) // 64 bytes/brick
    owner_slot_bytes  :: size_of([2]i32)
    index_buf_bytes   :: CHUNKS_W * CHUNKS_H * CHUNKS_W * size_of(i32)

    n := len(gs.dirty_slots)

    // De-duplicate dirty_slots (a slot may appear multiple times in one frame)
    seen: map[int]bool
    defer delete(seen)
    unique: [dynamic]int
    defer delete(unique)
    for s in gs.dirty_slots {
        if !seen[s] { seen[s] = true; append(&unique, s) }
    }

    // Pool ids (voxel/mask destination) of the non-air dirty slots, sorted
    // ascending so contiguous pool ids coalesce into single uploads. The
    // free-list hands ids out roughly sequentially, so a freshly streamed
    // column's layers tend to land in near-consecutive ids → long runs.
    pids: [dynamic]int
    defer delete(pids)
    for s in unique {
        pid := gs.gpu_index[s]
        if pid >= 0 { append(&pids, int(pid)) }
    }
    slice.sort(pids[:])
    // Owner destination is the ring slot itself; sort slots ascending too.
    oslots := make([]int, len(unique))
    defer delete(oslots)
    copy(oslots, unique[:])
    slice.sort(oslots)

    total_transfer := len(pids) * (voxel_chunk_bytes + mask_chunk_bytes) +
                      len(oslots) * owner_slot_bytes + index_buf_bytes

    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, SDL.GPUTransferBufferCreateInfo{
        usage = .UPLOAD,
        size  = u32(total_transfer),
    })
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)

    base_ptr := SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false)
    write_off := 0

    // --- Pack transfer buffer in destination-sorted order ---
    voxel_write_off := write_off
    for pid in pids {
        mem.copy(rawptr(uintptr(base_ptr) + uintptr(write_off)),
            raw_data(gs.gpu_voxels[pid * voxels_per_chunk:]), voxel_chunk_bytes)
        write_off += voxel_chunk_bytes
    }
    mask_write_off := write_off
    for pid in pids {
        mem.copy(rawptr(uintptr(base_ptr) + uintptr(write_off)),
            raw_data(gs.gpu_voxel_mask[pid * MASK_U32_PER_BRICK:]), mask_chunk_bytes)
        write_off += mask_chunk_bytes
    }
    owner_write_off := write_off
    for s in oslots {
        mem.copy(rawptr(uintptr(base_ptr) + uintptr(write_off)),
            &gs.gpu_chunk_owner[s], owner_slot_bytes)
        write_off += owner_slot_bytes
    }
    index_write_off := write_off
    mem.copy(rawptr(uintptr(base_ptr) + uintptr(write_off)),
        raw_data(gs.gpu_index), index_buf_bytes)
    write_off += index_buf_bytes

    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    copy_pass := SDL.BeginGPUCopyPass(cmd)

    // Coalesce a destination-sorted index list into one UploadToGPUBuffer
    // per maximal contiguous run. `keys[i]` is the destination block index
    // of the i-th packed element; transfer bytes are contiguous in the same
    // order, so a run of consecutive keys is one copy.
    upload_runs :: proc(copy_pass: ^SDL.GPUCopyPass, transfer: ^SDL.GPUTransferBuffer,
        dst: ^SDL.GPUBuffer, keys: []int, block: int, base_xfer_off: int) {
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
                    offset = u32(keys[run_start] * block),
                    size   = u32(run_len * block)},
                false)
            i += 1
        }
    }

    upload_runs(copy_pass, transfer, gs.voxel_buf, pids[:], voxel_chunk_bytes, voxel_write_off)
    upload_runs(copy_pass, transfer, gs.mask_buf,  pids[:], mask_chunk_bytes,  mask_write_off)
    upload_runs(copy_pass, transfer, gs.owner_buf, oslots,  owner_slot_bytes,  owner_write_off)
    // Index: single wholesale upload. Per-slot was measured WORSE (added
    // ~1536 tiny calls); one 4 MB copy is one call and the GPU DMA is free
    // relative to call overhead.
    SDL.UploadToGPUBuffer(copy_pass,
        SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(index_write_off)},
        SDL.GPUBufferRegion{buffer = gs.index_buf, offset = 0, size = u32(index_buf_bytes)},
        false)

    SDL.EndGPUCopyPass(copy_pass)
    _ = SDL.SubmitGPUCommandBuffer(cmd)

    clear(&gs.dirty_slots)
    gs.index_dirty = false
    _ = n // suppress unused warning
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

gpu_render :: proc(gs: ^Game_State) {
    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    if cmd == nil { return }

    // Push per-frame uniform data (camera + light + reflect count)
    fwd, right, up := camera_basis(gs.camera)
    render_pos := gs.camera.pos
    render_pos.y += gs.camera.step_visual_offset
    uniform := Camera_Uniform{
        pos             = render_pos,
        fwd             = fwd,
        right           = right,
        up              = up,
        light_dir       = gs.light_dir,
        reflect_amount  = gs.reflect_amount,
        player_chunk_x  = i32(gs.player_chunk[0]),
        player_chunk_z  = i32(gs.player_chunk[2]),
        quality         = gs.aa_samples * 10 + gs.shadow_rays,
        vol             = (gs.vol_enabled ? 100 : 0) + gs.vol_steps,
    }
    SDL.PushGPUComputeUniformData(cmd, 0, &uniform, size_of(uniform))

    ro_bufs := [4]^SDL.GPUBuffer{gs.voxel_buf, gs.index_buf, gs.owner_buf, gs.mask_buf}

    // --- Pass 1: main raytrace → out_texture (+ depth_texture) ---
    rw_main := [2]SDL.GPUStorageTextureReadWriteBinding{
        { texture = gs.out_texture,   cycle = true },
        { texture = gs.depth_texture, cycle = true },
    }
    p1 := SDL.BeginGPUComputePass(cmd, raw_data(rw_main[:]), 2, nil, 0)
    SDL.BindGPUComputePipeline(p1, gs.pipeline)
    SDL.BindGPUComputeStorageBuffers(p1, 0, raw_data(ro_bufs[:]), 4)
    SDL.DispatchGPUCompute(p1, TEX_W / 16, TEX_H / 16, 1)
    SDL.EndGPUComputePass(p1)

    // --- Pass 2: half-res volumetric march → vol_texture ---
    // Reads depth (RO storage tex, t0) + voxel buffers (t1..t4).
    rw_vol := SDL.GPUStorageTextureReadWriteBinding{ texture = gs.vol_texture, cycle = true }
    p2 := SDL.BeginGPUComputePass(cmd, &rw_vol, 1, nil, 0)
    SDL.BindGPUComputePipeline(p2, gs.vol_pipeline)
    vol_ro_tex := [1]^SDL.GPUTexture{ gs.depth_texture }
    SDL.BindGPUComputeStorageTextures(p2, 0, raw_data(vol_ro_tex[:]), 1)
    SDL.BindGPUComputeStorageBuffers(p2, 0, raw_data(ro_bufs[:]), 4)
    SDL.DispatchGPUCompute(p2, (TEX_W/2 + 15) / 16, (TEX_H/2 + 15) / 16, 1)
    SDL.EndGPUComputePass(p2)

    // --- Pass 3: composite (bilateral upscale + add) → out_texture ---
    // Reads vol (t0) + depth (t1) as RO storage textures; RW out_texture.
    rw_comp := SDL.GPUStorageTextureReadWriteBinding{ texture = gs.out_texture, cycle = false }
    p3 := SDL.BeginGPUComputePass(cmd, &rw_comp, 1, nil, 0)
    SDL.BindGPUComputePipeline(p3, gs.comp_pipeline)
    comp_ro_tex := [2]^SDL.GPUTexture{ gs.vol_texture, gs.depth_texture }
    SDL.BindGPUComputeStorageTextures(p3, 0, raw_data(comp_ro_tex[:]), 2)
    SDL.DispatchGPUCompute(p3, TEX_W / 16, TEX_H / 16, 1)
    SDL.EndGPUComputePass(p3)

    // Swapchain presentation is owned by the SDL.Renderer in ui.odin
    // (see ui_build_and_render). It draws out_texture as a fullscreen quad,
    // then Clay UI on top, then calls SDL.RenderPresent.
    _ = SDL.SubmitGPUCommandBuffer(cmd)
}

gpu_destroy :: proc(gs: ^Game_State) {
    _ = SDL.WaitForGPUIdle(gs.gpu_device)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.out_texture)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.depth_texture)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.voxel_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.index_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.owner_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.mask_buf)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.pipeline)
    SDL.ReleaseWindowFromGPUDevice(gs.gpu_device, gs.window)
    SDL.DestroyGPUDevice(gs.gpu_device)
}
