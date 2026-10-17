package main

import "core:math"
import "core:slice"
import SDL "vendor:sdl3"

// Shadows from placed torches and crystals. Their light is the flood-filled
// block light (light.odin), which spreads around corners as if nothing were
// in the way; shading darkens it where the emitter itself is hidden, with
// shadow rays to the few emitters nearest (voxel_tracer.hlsl torch_shadow).
// Here the CPU lists the emitters in a box of TORCH_CELLS chunks around the
// camera and, per chunk ("cell"), the TORCH_PER_CELL whose light reaches it
// most, for the shader to read from two small textures. Dim glows (moss,
// mushrooms, sea pickles) stay unshadowed: many, faint and spread out.

TORCH_CELLS    :: [3]int{12, 8, 12}  // chunks: 96 x 64 x 96 voxels around the camera
TORCH_MAX      :: 512                // emitters listed at most
TORCH_PER_CELL :: 4

Torch_Shadows :: struct {
    enabled:  bool,
    floor:    f32,               // share of an emitter's light left in its shadow (the options' Soft / Strong)
    emit_tex: ^SDL.GPUTexture,   // rgba32f, TORCH_MAX x 1: voxel centre, level + 32 x light height (TORCH_LIFT)
    cell_tex: ^SDL.GPUTexture,   // rgba16ui, (cells x * z) x cells y: emitter index + 1 per slot, 0 = none
    upload:   ^SDL.GPUTransferBuffer,
    origin:   [3]int,            // the box's min chunk
    count:    int,               // emitters listed
    found:    int,               // ... of those in the box (the nearest TORCH_MAX are listed)
    dirty:    bool,              // rescan before the next frame
    staged:   bool,              // a scan waits in `upload`
}

@(private="file") EMIT_BYTES :: TORCH_MAX * 16

// Where an emitter's shadows are cast from, above its voxel's centre: up
// in its flame or glow when there's open space above it (a torch on rough
// ground would otherwise hide behind every step of the floor around it),
// else its top. Indexed by how many open voxels are above, up to 2.
TORCH_LIFT :: [3]f32{0.45, 1.0, 1.5}
@(private="file") CELL_BYTES :: TORCH_CELLS.x * TORCH_CELLS.z * TORCH_CELLS.y * TORCH_PER_CELL * 2

torch_init :: proc(gs: ^Game_State) {
    t := &gs.torch
    tex :: proc(gs: ^Game_State, f: SDL.GPUTextureFormat, w, h: int) -> ^SDL.GPUTexture {
        r := SDL.CreateGPUTexture(gs.gpu_device, {type = .D2, format = f, usage = {.COMPUTE_STORAGE_READ},
            width = u32(w), height = u32(h), layer_count_or_depth = 1, num_levels = 1})
        assert(r != nil, "Failed to create a torch shadow texture")
        return r
    }
    t.emit_tex = tex(gs, .R32G32B32A32_FLOAT, TORCH_MAX, 1)
    t.cell_tex = tex(gs, .R16G16B16A16_UINT, TORCH_CELLS.x * TORCH_CELLS.z, TORCH_CELLS.y)
    t.upload = SDL.CreateGPUTransferBuffer(gs.gpu_device, {usage = .UPLOAD, size = u32(EMIT_BYTES + CELL_BYTES)})
    assert(t.upload != nil, "Failed to create the torch shadow upload buffer")
    t.dirty = true
    // Empty to start with (the first scan fills them).
    p := ([^]u8)(SDL.MapGPUTransferBuffer(gs.gpu_device, t.upload, false))
    slice.zero(p[:EMIT_BYTES + CELL_BYTES])
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, t.upload)
    t.staged = true
}

torch_destroy :: proc(gs: ^Game_State) {
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.torch.emit_tex)
    SDL.ReleaseGPUTexture(gs.gpu_device, gs.torch.cell_tex)
    SDL.ReleaseGPUTransferBuffer(gs.gpu_device, gs.torch.upload)
}

// Blocks were edited (light.odin light_on_edit): an emitter may have come or gone.
torch_on_edit :: proc(gs: ^Game_State) { gs.torch.dirty = true }

// A column came in (world.odin integrate_column): rescan if it brings
// emitters into the box.
torch_on_column :: proc(gs: ^Game_State, key: [2]int, col: ^Column) {
    t := &gs.torch
    if key.x < t.origin.x || key.x >= t.origin.x + TORCH_CELLS.x || key.y < t.origin.z || key.y >= t.origin.z + TORCH_CELLS.z { return }
    for &c in col.chunks { if c.casters > 0 { t.dirty = true; return } }
}

// Emitters that cast shadows (dim glows don't).
block_casts_shadow :: #force_inline proc(b: u8) -> bool {
    return b == u8(Block_Type.Torch) || b == u8(Block_Type.Crystal)
}

// Chunk.casters for a chunk just made (generated or loaded); edits keep it
// (chunk_set_voxel), so the scan looks only in chunks that have some.
chunk_count_casters :: proc(c: ^Chunk) {
    c.casters = 0
    if c.voxels == nil { return }
    for v in c.voxels { if block_casts_shadow(v) { c.casters += 1 } }
}

// For Camera_Uniform: the box's min chunk, and how many emitters (0: none,
// or shadows off). Rescans the box first when it moved or something changed.
torch_uniform :: proc(gs: ^Game_State, eye: [3]f32) -> [4]i32 {
    t := &gs.torch
    if !t.enabled { return {} }
    c := [3]int{int(math.floor(eye.x / CHUNK_VOXELS)), int(math.floor(eye.y / CHUNK_VOXELS)), int(math.floor(eye.z / CHUNK_VOXELS))}
    origin := c - TORCH_CELLS / 2
    if origin != t.origin || t.dirty {
        t.origin = origin
        torch_scan(gs)
    }
    return {i32(t.origin.x), i32(t.origin.y), i32(t.origin.z), i32(t.count)}
}

// List the casting emitters in the box and, per cell, the strongest few at
// its centre, into the upload buffer (copied by torch_copy).
@(private="file")
torch_scan :: proc(gs: ^Game_State) {
    t := &gs.torch
    t.dirty = false
    Emitter :: struct { p: [3]f32, level: f32, lift: int }
    emitters := make([dynamic]Emitter, 0, 64, context.temp_allocator)
    for cz in 0 ..< TORCH_CELLS.z { for cy in 0 ..< TORCH_CELLS.y { for cx in 0 ..< TORCH_CELLS.x {
        key := t.origin + {cx, cy, cz}
        ch := world_chunk(gs, key)
        if ch == nil || ch.casters == 0 { continue }
        for vi in 0 ..< VOXELS_PER_BRICK {
            b := ch.voxels[vi]
            if !block_casts_shadow(b) { continue }
            p := key * CHUNK_VOXELS + {vi & 7, (vi >> 3) & 7, vi >> 6}
            lift := 0
            for lift < 2 && !block_opaque(u8(get_voxel(gs, p.x, p.y + lift + 1, p.z))) { lift += 1 }
            append(&emitters, Emitter{{f32(p.x) + 0.5, f32(p.y) + 0.5, f32(p.z) + 0.5}, f32(block_emission(b)), lift})
        }
    }}}
    // A crystal cave can hold more than fit: keep the nearest to the camera
    // (the box's centre), which light what's in view.
    t.found = len(emitters)
    if len(emitters) > TORCH_MAX {
        centre := [3]f32{f32((t.origin.x + TORCH_CELLS.x / 2) * CHUNK_VOXELS), f32((t.origin.y + TORCH_CELLS.y / 2) * CHUNK_VOXELS), f32((t.origin.z + TORCH_CELLS.z / 2) * CHUNK_VOXELS)}
        context.user_ptr = &centre
        slice.sort_by(emitters[:], proc(a, b: Emitter) -> bool {
            c := (^[3]f32)(context.user_ptr)^
            da, db := a.p - c, b.p - c
            return da.x * da.x + da.y * da.y + da.z * da.z < db.x * db.x + db.y * db.y + db.z * db.z
        })
        resize(&emitters, TORCH_MAX)
    }
    t.count = len(emitters)

    base := uintptr(SDL.MapGPUTransferBuffer(gs.gpu_device, t.upload, true))
    emit := ([^][4]f32)(rawptr(base))
    for e, i in emitters { emit[i] = {e.p.x, e.p.y, e.p.z, e.level + 32 * f32(e.lift)} }
    // Per cell, the strongest few by the light each leaves at the cell's
    // nearest point (as the shader weighs them: level less distance). Each
    // emitter visits only the cells its light reaches.
    N :: TORCH_CELLS.x * TORCH_CELLS.y * TORCH_CELLS.z
    cells := ([^][TORCH_PER_CELL]u16)(rawptr(base + EMIT_BYTES))
    score := make([][TORCH_PER_CELL]f32, N, context.temp_allocator)
    for i in 0 ..< N { cells[i] = {} }
    for e, i in emitters {
        r := int(e.level)
        dims := TORCH_CELLS
        lo, hi: [3]int
        for a in 0 ..< 3 {
            lo[a] = max(int(math.floor((e.p[a] - f32(r)) / CHUNK_VOXELS)) - t.origin[a], 0)
            hi[a] = min(int(math.floor((e.p[a] + f32(r)) / CHUNK_VOXELS)) - t.origin[a], dims[a] - 1)
        }
        for cz in lo.z ..= hi.z { for cy in lo.y ..= hi.y { for cx in lo.x ..= hi.x {
            cmin := [3]f32{f32((t.origin.x + cx) * CHUNK_VOXELS), f32((t.origin.y + cy) * CHUNK_VOXELS), f32((t.origin.z + cz) * CHUNK_VOXELS)}
            q := [3]f32{clamp(e.p.x, cmin.x, cmin.x + CHUNK_VOXELS), clamp(e.p.y, cmin.y, cmin.y + CHUNK_VOXELS), clamp(e.p.z, cmin.z, cmin.z + CHUNK_VOXELS)}
            d := q - e.p
            s := e.level - math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
            if s <= 0 { continue }
            ci := cx + cz * TORCH_CELLS.x + cy * TORCH_CELLS.x * TORCH_CELLS.z
            best, sc := &cells[ci], &score[ci]
            // Insert into the top few, strongest first.
            for k in 0 ..< TORCH_PER_CELL {
                if best[k] != 0 && sc[k] >= s { continue }
                for m := TORCH_PER_CELL - 1; m > k; m -= 1 { best[m], sc[m] = best[m - 1], sc[m - 1] }
                best[k], sc[k] = u16(i + 1), s
                break
            }
        }}}
    }
    SDL.UnmapGPUTransferBuffer(gs.gpu_device, t.upload)
    t.staged = true
}

// The staged lists into their textures, in this frame's command buffer.
torch_copy :: proc(gs: ^Game_State, cmd: ^SDL.GPUCommandBuffer) {
    t := &gs.torch
    if !t.staged { return }
    t.staged = false
    cp := SDL.BeginGPUCopyPass(cmd)
    SDL.UploadToGPUTexture(cp, {transfer_buffer = t.upload, offset = 0},
        {texture = t.emit_tex, w = TORCH_MAX, h = 1, d = 1}, true)
    SDL.UploadToGPUTexture(cp, {transfer_buffer = t.upload, offset = EMIT_BYTES},
        {texture = t.cell_tex, w = u32(TORCH_CELLS.x * TORCH_CELLS.z), h = u32(TORCH_CELLS.y), d = 1}, true)
    SDL.EndGPUCopyPass(cp)
}
