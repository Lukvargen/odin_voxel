// Bounce-light probe update (gi_common.hlsl has the layout). One group of
// GI_RAYS threads per probe. Each frame renews first the u_gi_frame.w slots
// listed in gi_list (probes new to the grid, probes around an edit: gi.odin
// lists them a few frames running, so they settle quickly and smoothly),
// then the grid's slots from u_gi_frame.x on, in turn. Per probe:
//  1. the open voxels of its 8x8x8 box (light passes where light.odin's
//     flood fill does) and the open voxel nearest its centre, where it
//     stands (a buried probe moves out of the rock);
//  2. the box voxels reachable from there through open voxels: the reach
//     mask shading tests so light doesn't blend through walls;
//  3. GI_RAYS short rays; each hit is lit as shading lights it (sun with a
//     shadow ray, sky light, block light) plus the probes' own light there
//     (so light bounces on over the frames), times the block's colour;
//  4. the rays summed into six directions and blended into the old value.
StructuredBuffer<uint>  voxel_chunk : register(t0, space0);
StructuredBuffer<int>   chunk_index : register(t1, space0);
StructuredBuffer<int2>  chunk_owner : register(t2, space0);
StructuredBuffer<uint>  voxel_mask  : register(t3, space0);
StructuredBuffer<int>   light_index : register(t4, space0);
StructuredBuffer<uint>  light_pool  : register(t5, space0);
StructuredBuffer<uint>  gi_list     : register(t6, space0); // slots renewed first

[[vk::image_format("rgba16f")]] RWTexture2D<float4> gi_irr : register(u0, space1);
[[vk::image_format("r32ui")]]   RWTexture2D<uint>   gi_vis : register(u1, space1);
RWStructuredBuffer<uint> gi_stats : register(u2, space1); // probes renewed, of them buried (F3 panel)

#include "camera_uniforms.hlsl"

#define HAS_VOXEL_LIGHT
#include "voxel_common.hlsl"
#include "gi_common.hlsl"

#define GI_RAYS      64
#define GI_RAY_LEN   96.0
#define GI_BLEND     0.25 // share of a new update in a settled probe's light
#define GI_BOUNCE    0.85 // light carried into further bounces (keeps snow caves from running away)

// Light does not pass (light.odin block_opaque).
bool gi_opaque(uint b) {
    return b != 0u && !block_is_leaves(b) && !block_is_watery(b) && !block_is_land_plant(b) && !block_is_door(b);
}

// A block's colour on average: what light bouncing off it takes on.
float3 gi_albedo(uint id, float3 n, float y) {
    bool top = n.y > 0.5;
    float3 dirt = float3(0.36, 0.25, 0.15);
    float3 rock = float3(0.47, 0.47, 0.48);
    float3 snow = float3(0.82, 0.86, 0.93);
    if (id == BLOCK_GRASS)         return top ? float3(0.22, 0.35, 0.10) : float3(0.31, 0.27, 0.14);
    if (id == BLOCK_DRY_GRASS)     return top ? float3(0.38, 0.34, 0.14) : dirt;
    if (id == BLOCK_SNOW)          return top ? snow : float3(0.60, 0.61, 0.64);
    if (id == BLOCK_WEATHERED_STONE) return top ? lerp(rock, snow, smoothstep(165.0, 240.0, y)) : rock;
    if (id == BLOCK_DIRT)          return dirt;
    if (id == BLOCK_SAND)          return float3(0.645, 0.552, 0.377);
    if (id == BLOCK_RED_SAND)      return float3(0.570, 0.285, 0.138);
    if (id == BLOCK_SANDSTONE)     return float3(0.675, 0.575, 0.392);
    if (id == BLOCK_TERRACOTTA)    return float3(0.63, 0.41, 0.26);
    if (id == BLOCK_GRAVEL)        return float3(0.50, 0.48, 0.44);
    if (id == BLOCK_ICE)           return float3(0.47, 0.62, 0.80);
    if (id == BLOCK_CACTUS)        return float3(0.22, 0.45, 0.15);
    if (id == BLOCK_LOG)           return top ? float3(0.52, 0.40, 0.24) : float3(0.30, 0.20, 0.10);
    if (id == BLOCK_SPRUCE_LOG)    return top ? float3(0.46, 0.35, 0.21) : float3(0.20, 0.13, 0.07);
    if (id == BLOCK_BIRCH_LOG)     return float3(0.75, 0.74, 0.69);
    if (id == BLOCK_ACACIA_LOG)    return float3(0.31, 0.28, 0.25);
    if (id == BLOCK_LEAVES)        return float3(0.14, 0.30, 0.08);
    if (id == BLOCK_SPRUCE_LEAVES) return float3(0.07, 0.19, 0.10);
    if (id == BLOCK_BIRCH_LEAVES)  return float3(0.22, 0.39, 0.09);
    if (id == BLOCK_AUTUMN_LEAVES) return float3(0.50, 0.19, 0.05);
    if (id == BLOCK_ACACIA_LEAVES) return float3(0.18, 0.25, 0.06);
    if (id == BLOCK_WILLOW_LEAVES) return float3(0.25, 0.38, 0.12);
    if (id == BLOCK_MOSS)          return float3(0.17, 0.32, 0.08);
    if (id == BLOCK_GLOW_MOSS)     return float3(0.20, 0.40, 0.25);
    if (id == BLOCK_DRIPSTONE)     return float3(0.48, 0.40, 0.31);
    if (id == BLOCK_STONE_BRICKS)  return float3(0.44, 0.44, 0.40);
    if (id == BLOCK_WORKBENCH)     return float3(0.48, 0.34, 0.19);
    if (id == BLOCK_CRYSTAL)       return float3(0.95, 0.65, 0.25);
    if (id == BLOCK_TORCH)         return float3(0.45, 0.26, 0.10);
    if (id == BLOCK_CORAL)         return float3(0.80, 0.42, 0.45);
    if (id == BLOCK_WATER)         return float3(0.03, 0.08, 0.10);
    if (block_is_door(id))         return float3(0.45, 0.31, 0.17);
    if (block_is_cutout(id))       return float3(0.20, 0.33, 0.10);
    return rock; // stone, ores
}

uint gi_hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}
float gi_rand(inout uint s) { s = gi_hash(s); return float(s & 0xFFFFFFu) / 16777216.0; }

// Ray i of GI_RAYS: an even spread over the sphere (spherical Fibonacci),
// turned by this update's random rotation so updates cover new directions.
float3 gi_ray_dir(uint i, float3x3 rot) {
    float z = 1.0 - (2.0 * float(i) + 1.0) / float(GI_RAYS);
    float r = sqrt(saturate(1.0 - z * z));
    float a = float(i) * 2.39996323;
    return mul(rot, float3(r * cos(a), r * sin(a), z));
}

float3x3 gi_random_rotation(inout uint s) {
    // Random axis and angle (Rodrigues).
    float u = gi_rand(s) * 2.0 - 1.0, phi = gi_rand(s) * 6.2831853, ang = gi_rand(s) * 6.2831853;
    float rr = sqrt(saturate(1.0 - u * u));
    float3 k = float3(rr * cos(phi), rr * sin(phi), u);
    float c = cos(ang), sn = sin(ang), t = 1.0 - c;
    return float3x3(
        t * k.x * k.x + c,       t * k.x * k.y - sn * k.z, t * k.x * k.z + sn * k.y,
        t * k.x * k.y + sn * k.z, t * k.y * k.y + c,       t * k.y * k.z - sn * k.x,
        t * k.x * k.z - sn * k.y, t * k.y * k.z + sn * k.x, t * k.z * k.z + c);
}

groupshared uint   g_open[16];   // open voxels of the box (bit layout: gi_common)
groupshared uint   g_reach[16];  // ...reachable from the probe's spot
groupshared uint   g_start;      // rank << 24 | distance^2 << 16 | box index of that spot
groupshared uint   g_old_owner;
groupshared float3 g_ray_light[GI_RAYS];
groupshared float3 g_ray_dir[GI_RAYS];

// Grow the reached set by one voxel in every direction, within the open
// voxels; false once it stops growing.
bool gi_reach_step(inout uint r[16]) {
    uint n[16];
    bool grew = false;
    [unroll]
    for (int z = 0; z < 8; z++) {
        uint a = r[z * 2], b = r[z * 2 + 1]; // rows y 0..3, 4..7 (a byte a row)
        uint na = a | ((a << 1) & 0xFEFEFEFEu) | ((a >> 1) & 0x7F7F7F7Fu) | (a << 8) | (a >> 8) | (b << 24);
        uint nb = b | ((b << 1) & 0xFEFEFEFEu) | ((b >> 1) & 0x7F7F7F7Fu) | (b << 8) | (b >> 8) | (a >> 24);
        if (z > 0) { na |= r[z * 2 - 2]; nb |= r[z * 2 - 1]; }
        if (z < 7) { na |= r[z * 2 + 2]; nb |= r[z * 2 + 3]; }
        n[z * 2] = na; n[z * 2 + 1] = nb;
    }
    [unroll]
    for (int w = 0; w < 16; w++) {
        uint v = n[w] & g_open[w];
        grew = grew || v != r[w];
        r[w] = v;
    }
    return grew;
}

[numthreads(GI_RAYS, 1, 1)]
void main(uint3 gid : SV_GroupID, uint tid : SV_GroupIndex) {
    const int total = GI_DIMS.x * GI_DIMS.y * GI_DIMS.z;
    uint listed = uint(u_gi_frame.w);
    int s = gid.x < listed ? int(gi_list[gid.x]) : int((uint(u_gi_frame.x) + gid.x - listed) % uint(total));
    int3 sc = int3(s % GI_DIMS.x, (s / GI_DIMS.x) % GI_DIMS.y, s / (GI_DIMS.x * GI_DIMS.y));
    // The probe of the current grid that lives in slot s.
    int3 org = u_gi_origin.xyz;
    int3 pw = org + (sc - org - gi_floor_div3(sc - org, GI_DIMS) * GI_DIMS);
    int3 box = pw * GI_SPACING - 4; // world voxel of box index 0

    if (tid < 16) g_open[tid] = 0u;
    if (tid == 0) {
        g_start = 0xFFFFFFFFu;
        g_old_owner = gi_vis[gi_vis_texel(s, GI_OWNER_WORD)];
    }
    GroupMemoryBarrierWithGroupSync();

    // 1. Open voxels: a row of 8 along x per thread.
    {
        int y = int(tid & 7u), z = int(tid >> 3);
        uint row = 0u;
        uint best = 0xFFFFFFFFu;
        for (int x = 0; x < 8; x++) {
            int3 v = box + int3(x, y, z);
            uint b = sample_voxel(float3(v) + 0.5);
            if (gi_opaque(b)) continue;
            row |= 1u << uint(x);
            // The spot: empty air if there is any (rays from inside a leaf
            // or under water would only see that block), else a plant or
            // door's voxel, then water, then leaves; nearest the centre.
            uint rank = b == 0u ? 0u : (block_is_shaped(b) && !block_is_watery(b) ? 1u : (block_is_watery(b) ? 2u : 3u));
            int3 d = int3(x, y, z) - 4;
            best = min(best, (rank << 24) | (uint(dot(d, d)) << 16) | uint(x + y * 8 + z * 64));
        }
        InterlockedOr(g_open[(y >> 2) + z * 2], row << uint((y & 3) * 8));
        InterlockedMin(g_start, best);
    }
    GroupMemoryBarrierWithGroupSync();

    uint owner = gi_owner(pw);
    if (tid == 0) InterlockedAdd(gi_stats[0], 1u);
    if (g_start == 0xFFFFFFFFu) {
        // Solid all through: nothing to light, nothing it reaches.
        if (tid == 0) InterlockedAdd(gi_stats[1], 1u);
        if (tid < 6) gi_irr[gi_irr_texel(s, int(tid))] = float4(0, 0, 0, 0);
        if (tid < 16) gi_vis[gi_vis_texel(s, int(tid))] = 0u;
        if (tid == 16) gi_vis[gi_vis_texel(s, GI_OWNER_WORD)] = owner;
        return;
    }
    uint start_i = g_start & 0xFFFFu;
    int3 start = int3(start_i & 7u, (start_i >> 3) & 7u, start_i >> 6);

    // 2. Reach mask, grown from the probe's spot (one thread: it's bit ops
    // on 16 words; winding paths take a few dozen steps at most).
    if (tid == 0) {
        uint r[16];
        [unroll] for (int w = 0; w < 16; w++) r[w] = 0u;
        r[(start.y >> 2) + start.z * 2] = 1u << uint(start.x + (start.y & 3) * 8);
        for (int it = 0; it < 48; it++) {
            if (!gi_reach_step(r)) break;
        }
        [unroll] for (int w2 = 0; w2 < 16; w2++) g_reach[w2] = r[w2];
    }

    // 3. One ray per thread.
    uint seed = gi_hash(uint(s) * 9781u + uint(u_gi_frame.y) * 6271u);
    float3x3 rot = gi_random_rotation(seed); // the same in every thread of the group
    float3 dir = gi_ray_dir(tid, rot);
    float3 o = float3(box + start) + 0.5;
    float3 l = normalize(u_light_dir_raw);
    float3 radiance = float3(0, 0, 0);
    // Under water the rays go through it to what's around.
    uint skip = ((g_start >> 24) == 2u) ? BLOCK_WATER : 0u;
    HitInfo h = trace_ray_chunk(o, dir, false, RAY_ITERATIONS, GI_RAY_LEN, skip);
    if (h.block_id != 0u) {
        float3 n = h.normal;
        bool shaped = block_is_shaped(h.block_id);
        int3 fv = shaped ? h.vkey : h.vkey + int3(round(n));
        uint lv = sample_light(fv);
        float sky = float(light_sky(lv));
        float3 lit = sky_ambient() * light_curve(sky) * face_shade(n) + block_radiance(lv, 1.0);
        float ndl = dot(n, l);
        if (ndl > 0.0 && sky > 0.0) {
            lit += sun_tint_d(l) * (ndl * u_sun_intensity * trace_shadow_transmittance(h.hit_pos + n * 0.01, l));
        }
        float3 more;
        float  fd;
        if (gi_sample(fv, h.hit_pos + n * 0.5, n, float3(0, 0, 0), more, fd)) lit += more * (fd * GI_BOUNCE);
        radiance = gi_albedo(h.block_id, n, h.hit_pos.y) * lit;
    }
    g_ray_light[tid] = radiance;
    g_ray_dir[tid] = dir;
    GroupMemoryBarrierWithGroupSync();

    // 4. Six directions; the reach mask and owner.
    if (tid < 6) {
        float3 axis = float3(0, 0, 0);
        axis[tid >> 1] = (tid & 1u) != 0u ? -1.0 : 1.0;
        float3 sum = float3(0, 0, 0);
        for (int i = 0; i < GI_RAYS; i++) sum += g_ray_light[i] * max(dot(g_ray_dir[i], axis), 0.0);
        // E/pi over the hemisphere, as shading's "lighting" (albedo times it).
        float3 e = sum * (4.0 / float(GI_RAYS));
        int2 t = gi_irr_texel(s, int(tid));
        float4 old = gi_irr[t];
        // Updates so far: the first ones average evenly (each a share of
        // 1/n), then each new one counts for GI_BLEND.
        float n = (g_old_owner == owner && all(isfinite(old))) ? min(old.a + 1.0, GI_SETTLED) : 1.0;
        gi_irr[t] = float4(lerp(old.rgb, e, max(1.0 / n, GI_BLEND)), n);
    } else if (tid < 22) {
        gi_vis[gi_vis_texel(s, int(tid) - 6)] = g_reach[tid - 6];
    } else if (tid == 22) {
        gi_vis[gi_vis_texel(s, GI_OWNER_WORD)] = owner;
    }
}
