package main

import "core:fmt"
import "core:mem"
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
    _pad5:            f32,
}

gpu_init :: proc(gs: ^Game_State) {
    // SDL3 GPU device (SPIR-V shaders, debug mode on)
    gs.gpu_device = SDL.CreateGPUDevice({.SPIRV}, true, nil)
    assert(gs.gpu_device != nil, "Failed to create GPU device")
    fmt.println("GPU driver:", SDL.GetGPUDeviceDriver(gs.gpu_device))

    ok := SDL.ClaimWindowForGPUDevice(gs.gpu_device, gs.window)
    assert(ok, "Failed to claim window for GPU device")

    // SPIR-V embedded at compile time — no runtime file dependency
    shader_bytes := #load("shaders/voxel_tracer.spv")

    pipeline_info := SDL.GPUComputePipelineCreateInfo{
        code                         = raw_data(shader_bytes),
        code_size                    = len(shader_bytes),
        entrypoint                   = "main",
        format                       = {.SPIRV},
        num_readonly_storage_buffers = 4, // voxel_chunk (t0), chunk_index (t1), chunk_owner (t2), voxel_mask (t3)
        num_readwrite_storage_textures = 1, // img_output (u0)
        num_uniform_buffers          = 1, // CameraUniforms (b0)
        threadcount_x                = 16,
        threadcount_y                = 16,
        threadcount_z                = 1,
    }
    gs.pipeline = SDL.CreateGPUComputePipeline(gs.gpu_device, pipeline_info)
    assert(gs.pipeline != nil, "Failed to create compute pipeline")

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

// Flush all dirty chunk slots accumulated this frame in a single GPU submission.
// Call once per frame before gpu_render.
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

    total_transfer := len(unique) * (voxel_chunk_bytes + mask_chunk_bytes + owner_slot_bytes)
    if gs.index_dirty { total_transfer += index_buf_bytes }

    transfer := SDL.CreateGPUTransferBuffer(gs.gpu_device, SDL.GPUTransferBufferCreateInfo{
        usage = .UPLOAD,
        size  = u32(total_transfer),
    })
    defer SDL.ReleaseGPUTransferBuffer(gs.gpu_device, transfer)

    base_ptr := SDL.MapGPUTransferBuffer(gs.gpu_device, transfer, false)

    write_off := 0
    // Voxel data per dirty slot, addressed by its POOL ID. Air slots
    // (gpu_index == -1) have no pool storage; their state reaches the GPU
    // via the wholesale index_buf upload, so skip them here.
    for s in unique {
        pid := gs.gpu_index[s]
        if pid < 0 { continue }
        voxel_base := int(pid) * voxels_per_chunk
        dst_ptr := uintptr(base_ptr) + uintptr(write_off)
        mem.copy(rawptr(dst_ptr), raw_data(gs.gpu_voxels[voxel_base:]), voxel_chunk_bytes)
        write_off += voxel_chunk_bytes
    }
    // Occupancy mask per dirty slot, addressed by its POOL ID.
    mask_write_off := write_off
    for s in unique {
        pid := gs.gpu_index[s]
        if pid < 0 { continue }
        mask_base := int(pid) * MASK_U32_PER_BRICK
        dst_ptr := uintptr(base_ptr) + uintptr(write_off)
        mem.copy(rawptr(dst_ptr), raw_data(gs.gpu_voxel_mask[mask_base:]), mask_chunk_bytes)
        write_off += mask_chunk_bytes
    }
    // Write owner data for each unique dirty slot
    owner_write_off := write_off
    for s in unique {
        dst_ptr := uintptr(base_ptr) + uintptr(write_off)
        mem.copy(rawptr(dst_ptr), &gs.gpu_chunk_owner[s], owner_slot_bytes)
        write_off += owner_slot_bytes
    }
    // Write full index buffer if dirty
    index_write_off := write_off
    if gs.index_dirty {
        dst_ptr := uintptr(base_ptr) + uintptr(write_off)
        mem.copy(rawptr(dst_ptr), raw_data(gs.gpu_index), index_buf_bytes)
        write_off += index_buf_bytes
    }

    SDL.UnmapGPUTransferBuffer(gs.gpu_device, transfer)

    cmd := SDL.AcquireGPUCommandBuffer(gs.gpu_device)
    copy_pass := SDL.BeginGPUCopyPass(cmd)

    // Upload voxel chunks to their POOL ID region (skip air slots).
    voxel_transfer_off := 0
    for s in unique {
        pid := gs.gpu_index[s]
        if pid < 0 { continue }
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(voxel_transfer_off)},
            SDL.GPUBufferRegion{buffer = gs.voxel_buf, offset = u32(int(pid) * voxel_chunk_bytes), size = u32(voxel_chunk_bytes)},
            false)
        voxel_transfer_off += voxel_chunk_bytes
    }
    // Upload occupancy masks to their POOL ID region (skip air slots).
    mask_transfer_off := mask_write_off
    for s in unique {
        pid := gs.gpu_index[s]
        if pid < 0 { continue }
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(mask_transfer_off)},
            SDL.GPUBufferRegion{buffer = gs.mask_buf, offset = u32(int(pid) * mask_chunk_bytes), size = u32(mask_chunk_bytes)},
            false)
        mask_transfer_off += mask_chunk_bytes
    }
    // Upload owner slots
    owner_transfer_off := owner_write_off
    for s in unique {
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(owner_transfer_off)},
            SDL.GPUBufferRegion{buffer = gs.owner_buf, offset = u32(s * owner_slot_bytes), size = u32(owner_slot_bytes)},
            false)
        owner_transfer_off += owner_slot_bytes
    }
    // Upload index buffer
    if gs.index_dirty {
        SDL.UploadToGPUBuffer(copy_pass,
            SDL.GPUTransferBufferLocation{transfer_buffer = transfer, offset = u32(index_write_off)},
            SDL.GPUBufferRegion{buffer = gs.index_buf, offset = 0, size = u32(index_buf_bytes)},
            false)
    }

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
    }
    SDL.PushGPUComputeUniformData(cmd, 0, &uniform, size_of(uniform))

    // Compute pass: raytrace into out_texture
    rw_tex_binding := SDL.GPUStorageTextureReadWriteBinding{
        texture = gs.out_texture,
        cycle   = true,
    }
    compute_pass := SDL.BeginGPUComputePass(cmd, &rw_tex_binding, 1, nil, 0)

    SDL.BindGPUComputePipeline(compute_pass, gs.pipeline)

    // Bind readonly storage buffers: voxel_chunk (t0), chunk_index (t1), chunk_owner (t2), voxel_mask (t3)
    ro_bufs := [4]^SDL.GPUBuffer{gs.voxel_buf, gs.index_buf, gs.owner_buf, gs.mask_buf}
    SDL.BindGPUComputeStorageBuffers(compute_pass, 0, raw_data(ro_bufs[:]), 4)

    SDL.DispatchGPUCompute(compute_pass, TEX_W / 16, TEX_H / 16, 1)
    SDL.EndGPUComputePass(compute_pass)

    // Acquire swapchain and blit out_texture onto it
    swapchain_tex: ^SDL.GPUTexture
    sw_w, sw_h: u32
    if !SDL.WaitAndAcquireGPUSwapchainTexture(cmd, gs.window, &swapchain_tex, &sw_w, &sw_h) {
        _ = SDL.CancelGPUCommandBuffer(cmd)
        return
    }
    if swapchain_tex == nil {
        _ = SDL.CancelGPUCommandBuffer(cmd)
        return
    }

    SDL.BlitGPUTexture(cmd, SDL.GPUBlitInfo{
        source = SDL.GPUBlitRegion{
            texture = gs.out_texture,
            w = TEX_W, h = TEX_H,
        },
        destination = SDL.GPUBlitRegion{
            texture = swapchain_tex,
            w = sw_w, h = sw_h,
        },
        load_op = .DONT_CARE,
        filter  = .NEAREST,
    })

    _ = SDL.SubmitGPUCommandBuffer(cmd)
}

gpu_destroy :: proc(gs: ^Game_State) {
    _ = SDL.WaitForGPUIdle(gs.gpu_device)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.out_texture)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.voxel_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.index_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.owner_buf)
    SDL.ReleaseGPUBuffer(gs.gpu_device, gs.mask_buf)
    SDL.ReleaseGPUComputePipeline(gs.gpu_device, gs.pipeline)
    SDL.ReleaseWindowFromGPUDevice(gs.gpu_device, gs.window)
    SDL.DestroyGPUDevice(gs.gpu_device)
}
