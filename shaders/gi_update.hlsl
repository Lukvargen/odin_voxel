// GI irradiance-cache update pass. Progressively sweeps the world-anchored
// clipmap volume: each frame GI_UPDATE_BUDGET cells are re-estimated by firing
// GI_RAYS Fibonacci sphere directions (per-cell hash rotation decorrelates
// neighbours) and EMA-blended into the cache (u_gi_alpha; the CPU raises it
// toward 1 after light-direction changes so the cache rewrites instead of
// dragging). Misses gather desaturated sky; hits gather sun-lit bounce color
// plus a cache feedback term (GI_FEEDBACK) — i.e. multi-bounce that converges
// across sweeps like a radiosity iteration. Cells whose center voxel is solid
// store valid zeros (cheap, and gives natural contact darkening when sampled).
//
// SPIR-V/SDL3 bindings: RO storage bufs t0..t3 (voxel data); RW storage buf
// u0 (gi_cache); shared CameraUniforms b0.
StructuredBuffer<uint>     voxel_chunk  : register(t0, space0);
StructuredBuffer<int>      chunk_index  : register(t1, space0);
StructuredBuffer<int2>     chunk_owner  : register(t2, space0);
StructuredBuffer<uint>     voxel_mask   : register(t3, space0);
StructuredBuffer<float4>   point_lights : register(t4, space0); // 2 float4s/light (lights.odin)

RWStructuredBuffer<uint>   gi_cache    : register(u0, space1);

cbuffer CameraUniforms : register(b0, space2) {
    float3 u_cam_pos;
    float  _pad0;
    float3 u_cam_fwd;
    float  _pad1;
    float3 u_cam_right;
    float  _pad2;
    float3 u_cam_up;
    float  _pad3;
    float3 u_light_dir_raw;
    float  _pad4;
    int    u_reflect_amount;
    int    u_player_chunk_x;
    int    u_player_chunk_z;
    int    u_quality;
    int    u_vol;
    int    u_gi_frame_index;
    int    u_gi_enabled;
    float  u_gi_alpha;
    int3   u_gi_cache_origin;
    int    u_gi_epoch;     // completed-sweep counter (rotates ray sets)
    float  u_time;         // seconds — cloud drift
    int    u_light_count;
    float  u_exposure;
    float  u_fog_density;
    float  u_cave_factor;
    float  u_sun_intensity;
    float2 _pad7;
    int3   u_gi_region_min;
    int    u_gi_region_mode;
    int3   u_gi_region_dims;
    float  u_gi_region_alpha;
};

#define HAS_GI_CACHE
#define HAS_POINT_LIGHTS
#include "voxel_common.hlsl"

static const float3 face_axes[6] = {
    float3( 1, 0, 0), float3(-1, 0, 0),
    float3( 0, 1, 0), float3( 0,-1, 0),
    float3( 0, 0, 1), float3( 0, 0,-1),
};

// Incoming radiance along dir from this cell center.
float3 gi_ray_radiance(float3 origin, float3 dir, float3 Ln) {
    // 48 chunk steps = ~384 voxels reach; beyond that sky is a fine stand-in.
    HitInfo hit = trace_ray_chunk(origin, dir, false, 48);
    if (hit.block_id == 0u) {
        float3 sky = sky_color_d(dir, Ln);
        float  lum = dot(sky, float3(0.299, 0.587, 0.114));
        return lerp(sky, float3(lum, lum, lum), GI_SKY_DESAT);
    }
    // Emissive surface: the face radiates its own light — no albedo/sun
    // shading. This is what lets torch light bounce through the cache.
    float3 emis = block_emission(hit.block_id);
    if (emis.x > 0.0) return emis;

    float3 N      = hit.normal;
    float3 albedo = voxel_albedo(hit.block_id, hit.vkey);
    float  ndl    = max(0.0, dot(N, Ln));
    float  shad   = 0.0;
    if (ndl > 0.0) {
        float3 shad_origin = float3(hit.vkey) + float3(0.5, 0.5, 0.5) + N;
        shad = trace_shadow_transmittance(shad_origin, Ln);
    }
    // Multi-bounce: ambient at the hit surface from the cache itself
    // (GI_FEEDBACK = 0 disables). Reading cells while others are written is
    // benign — worst case slightly stale GI.
    float3 amb = sample_gi_cache(hit.hit_pos + N, N) * GI_FEEDBACK;
    // Deterministic point-light injection at the hit (unshadowed): 16
    // stochastic rays/cell would undersample a 1-voxel emitter and flicker
    // for seconds; this makes every cache ray that lands near a torch carry
    // its first bounce. Shadowing is skipped (bounce magnitude only — the
    // standard cheap-VPL compromise); direct light is properly shadowed in
    // the tracer.
    float3 torch = point_lights_unshadowed(hit.hit_pos + N * 0.5, N);
    return albedo * (ndl * shad * u_sun_intensity + amb + torch);
}

// Bijective scramble of the 21-bit cell index (128^3 = 2^21): odd-multiplier
// mul and masked xor-shift are each invertible on the domain, so every cell
// is still visited exactly once per sweep — but this frame's batch is
// scattered uniformly through the volume instead of forming a coherent slab
// (the old linear order made a visible "refresh front" marching through the
// world once per sweep).
uint gi_permute(uint i) {
    const uint M = (1u << 21) - 1u;
    i = (i * 0x9E3779B1u) & M;
    i ^= i >> 11;
    i = (i * 0x85EBCA77u) & M;
    i ^= i >> 13;
    return i & M;
}

[numthreads(256, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    int3 cell;
    int  base;
    if (u_gi_region_mode != 0) {
        // Priority region re-estimation (torch placed/removed): every frame
        // for a short burst, all cells in the box get a fresh estimate with a
        // raised blend floor — the lighting CROSSFADES old → new in ~0.2 s
        // instead of going dark (hard clear) or ghosting (EMA-only sweep).
        int3 dims  = u_gi_region_dims;
        int  count = dims.x * dims.y * dims.z;
        if (int(id.x) >= count) return;
        cell = u_gi_region_min + int3(int(id.x) % dims.x,
                                      (int(id.x) / dims.x) % dims.y,
                                      int(id.x) / (dims.x * dims.y));
        int3 rel = cell - u_gi_cache_origin;
        if (any(rel < 0) || any(rel >= GI_GRID_N)) return;
        base = gi_slot_index(cell) * GI_CELL_UINTS;
    } else {
        if (id.x >= GI_UPDATE_BUDGET) return;

        int total   = GI_GRID_N * GI_GRID_N * GI_GRID_N;
        int cell_li = int(gi_permute((uint(u_gi_frame_index) * GI_UPDATE_BUDGET + id.x) % uint(total)));
        int3 slot   = int3(cell_li % GI_GRID_N,
                           (cell_li / GI_GRID_N) % GI_GRID_N,
                           cell_li / (GI_GRID_N * GI_GRID_N));

        // Clipmap inverse: world cell of this slot under the current origin.
        // c = origin + mod(slot - mod(origin, N), N) per axis.
        int3 om   = ((u_gi_cache_origin % GI_GRID_N) + GI_GRID_N) % GI_GRID_N;
        cell = u_gi_cache_origin + ((slot - om) % GI_GRID_N + GI_GRID_N) % GI_GRID_N;
        base = (slot.x + slot.y * GI_GRID_N + slot.z * GI_GRID_N * GI_GRID_N) * GI_CELL_UINTS;
    }

    float3 center = (float3(cell) + 0.5) * float(GI_CELL_SIZE);

    // Solid cell: zeros + sentinel count, no rays. The sentinel lets sampling
    // down-weight in-rock cells so narrow caves keep their bounce light.
    if (sample_voxel(center) != 0u) {
        [unroll]
        for (int f = 0; f < 6; f++) gi_cache[base + f] = 0u;
        gi_cache[base + 6] = GI_SOLID_MARK;
        return;
    }

    float3 Ln = normalize(u_light_dir_raw);

    // Per-cell azimuthal rotation (decorrelates neighbours) + golden-angle
    // advance per sweep epoch, so successive visits integrate DIFFERENT
    // direction sets — the count-based blend below then averages them into a
    // progressively better estimate instead of re-baking one fixed pattern.
    // Region mode revisits every frame, so rotate per-frame there instead.
    float epoch_f = float(u_gi_epoch);
    if (u_gi_region_mode != 0) epoch_f += float(u_gi_frame_index);
    float ang = (hash31i(cell) + epoch_f * 0.6180339887) * 2.0 * PI;
    float cs = cos(ang), sn = sin(ang);

    float3 face_sum[6];
    float  face_w[6];
    [unroll]
    for (int f = 0; f < 6; f++) { face_sum[f] = float3(0,0,0); face_w[f] = 0.0; }

    // Region mode doubles the ray count: each frame's estimate lands with a
    // raised blend floor, so per-estimate variance shows as shimmer — halve
    // it at the source (the region is small, the extra rays are cheap).
    uint nrays = (u_gi_region_mode != 0) ? GI_RAYS * 2u : GI_RAYS;
    for (uint r = 0; r < nrays; r++) {
        float3 d = fibonacci_sphere(r, nrays);
        d = float3(d.x * cs - d.z * sn, d.y, d.x * sn + d.z * cs);
        float3 L = gi_ray_radiance(center, d, Ln);
        [unroll]
        for (int f = 0; f < 6; f++) {
            float w = max(0.0, dot(d, face_axes[f]));
            face_sum[f] += L * w;
            face_w[f]   += w;
        }
    }

    // Count-based progressive average: alpha = 1/(n+1) — first write lands
    // whole, later visits nudge by ever-smaller steps (floored at 1/32 so the
    // cache still tracks slow scene changes). u_gi_alpha is a FLOOR the CPU
    // raises (~0.6) after light-dir changes / edits so the cache re-converges
    // within a sweep instead of dragging for 32 of them.
    uint  cnt   = gi_cache[base + 6];
    if (cnt == GI_SOLID_MARK) cnt = 0u; // was rock, now air (dug out) — first real sample
    // Region mode uses ITS OWN floor — never the global boost. A break edit
    // raises u_gi_alpha to ~0.6 for a sweep; taking max() would snap the
    // region in ~2 frames and defeat the crossfade ("removal still pops").
    float floor_a = (u_gi_region_mode != 0) ? u_gi_region_alpha : u_gi_alpha;
    float alpha = max(1.0 / (float(min(cnt, 31u)) + 1.0), floor_a);
    [unroll]
    for (int f = 0; f < 6; f++) {
        float3 fresh = face_sum[f] / max(face_w[f], 1e-3);
        float3 old   = unpack_r11g11b10(gi_cache[base + f]);
        gi_cache[base + f] = pack_r11g11b10(lerp(old, fresh, alpha));
    }
    gi_cache[base + 6] = min(cnt + 1u, 255u);
}
