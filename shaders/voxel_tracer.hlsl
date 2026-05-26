// Voxel raytracer compute shader — ported from voxel_tracer.glsl
// Two-level DDA: chunk-grid traversal, then per-chunk voxel traversal.

// ---- Bindings ---------------------------------------------------------------
// SPIR-V/SDL3 space0 order: (sampled tex) → RO storage tex → RO storage buf.
// RO storage tex (t0): gi_history_read. RO storage bufs (t1..t4): voxel data.
// RW textures (set 1): img_output (u0), depth_output (u1), gi_history_write (u2).
// Shared constants/functions come from voxel_common.hlsl AFTER these decls.
Texture2D<float4>          gi_history_read  : register(t0, space0);
StructuredBuffer<uint>     voxel_chunk      : register(t1, space0);
StructuredBuffer<int>      chunk_index      : register(t2, space0);
StructuredBuffer<int2>     chunk_owner      : register(t3, space0);
StructuredBuffer<uint>     voxel_mask       : register(t4, space0);

RWTexture2D<float4>        img_output        : register(u0, space1);
RWTexture2D<float>         depth_output      : register(u1, space1); // primary-hit dist, 1e30 = sky
RWTexture2D<float4>        gi_history_write  : register(u2, space1);

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
    float  _padq2;
};

#include "voxel_common.hlsl"

// ---- Structs ----------------------------------------------------------------

struct HitInfo {
    uint  block_id;
    int   iterations;
    float t;
    float3 normal;
    float3 hit_pos;
    int3   vkey;     // exact integer voxel coord (precision-safe, for hashing)
};

// ---- Helpers ----------------------------------------------------------------

static float3 light_dir_normalized;


float hash31(float3 p) {
    uint3 q = uint3(int3(floor(p)));
    q = q * uint3(1597334677u, 3812015801u, 2798796415u);
    uint n = (q.x ^ q.y ^ q.z) * 1376312589u;
    return float(n) * (1.0 / float(0xFFFFFFFFu));
}

float3 hash33(float3 p) {
    return float3(hash31(p),
                  hash31(p + float3(17.3, 0.0, 31.7)),
                  hash31(p + float3(0.0, 41.1, 7.9)));
}

// Integer-coordinate hash. Used for per-voxel color so it stays exact far
// from spawn (float floor() of a huge world coord collapses to one value;
// integer voxel coords never lose precision).
float hash31i(int3 v) {
    uint3 q = uint3(v); // two's-complement wrap for negatives is fine (hash)
    q = q * uint3(1597334677u, 3812015801u, 2798796415u);
    uint n = (q.x ^ q.y ^ q.z) * 1376312589u;
    return float(n) * (1.0 / float(0xFFFFFFFFu));
}

float3 hash33i(int3 v) {
    return float3(hash31i(v),
                  hash31i(v + int3(17, 0, 31)),
                  hash31i(v + int3(0, 41, 7)));
}

// Sun elevation in [0,1]: 0 = horizon, 1 = overhead.
// Used to tint sky/fog warm at low angles (sunrise/sunset).
float sun_elevation() {
    return clamp(light_dir_normalized.y, 0.0, 1.0);
}

float3 sun_tint() {
    float elev = sun_elevation();
    // Horizon: warm orange. Overhead: white.
    return lerp(float3(1.0, 0.45, 0.10), float3(1.0, 0.98, 0.92), smoothstep(0.0, 0.35, elev));
}

float4 sky_color(float3 dir) {
    float t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    // Sky gradient — horizon blue/orange, zenith deep blue
    float elev = sun_elevation();
    float3 horizon = lerp(float3(0.90, 0.55, 0.25), float3(0.75, 0.85, 1.0), smoothstep(0.0, 0.3, elev));
    float3 zenith  = lerp(float3(0.20, 0.10, 0.05), float3(0.10, 0.35, 0.80), smoothstep(0.0, 0.4, elev));
    float3 sky = lerp(horizon, zenith, pow(t, 0.6));
    float sun_dot  = dot(normalize(dir), light_dir_normalized);
    float sun_disc = smoothstep(0.9985, 0.9995, sun_dot);
    float sun_glow = smoothstep(0.960,  0.9985, sun_dot) * 0.4;
    sky = lerp(sky, sun_tint(), sun_disc + sun_glow * 0.6);
    return float4(sky, 1.0);
}

float4 apply_fog(float4 color, float dist, float3 ray_dir) {
    float fog_factor = clamp(exp(-pow(dist * 0.0012, 2.0)), 0.0, 1.0);
    // Fog color matches the horizon sky tint toward the ray direction
    float4 fog_color = sky_color(normalize(ray_dir));
    // Tint fog slightly warm near the sun
    float sun_dot = dot(normalize(ray_dir), light_dir_normalized);
    fog_color.rgb = lerp(fog_color.rgb, fog_color.rgb * sun_tint(), smoothstep(0.5, 1.0, sun_dot) * 0.5);
    return lerp(fog_color, color, fog_factor);
}

// ACES filmic tone mapping (approximation by Krzysztof Narkowicz)
float3 tone_map(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}


// ---- Voxel-level DDA --------------------------------------------------------

// world_origin: ray pos in WORLD units, used only for the final hit_pos
//   output (depth/shading) — its far-from-spawn drift is cosmetically
//   harmless there and pre-existing.
// local_entry: ray entry pos in VOXEL units within this chunk, [0,8) per
//   axis, computed precision-safe in the caller. Drives the index, t_max,
//   and vkey — the precision-critical path.
// chunk_ic: EXACT integer chunk coords (outer DDA integers, no float floor).
HitInfo trace_ray_chunk_voxels(float3 world_origin, float3 local_entry,
                                float3 dir, int3 chunk_ic,
                                int chunk_i, float3 entry_normal) {
    float t_delta_x = abs(1.0 / dir.x);
    float t_delta_y = abs(1.0 / dir.y);
    float t_delta_z = abs(1.0 / dir.z);

    int step_x = (int)sign(dir.x);
    int step_y = (int)sign(dir.y);
    int step_z = (int)sign(dir.z);

    int dir_x = step_x > 0 ? 1 : 0;
    int dir_y = step_y > 0 ? 1 : 0;
    int dir_z = step_z > 0 ? 1 : 0;

    // local_entry is already in [0,8) voxel units within the chunk and was
    // computed without ever forming a giant world float, so floor() is
    // exact at any distance from spawn. clamp guards a sub-ulp boundary
    // landing only (not masking drift — there is none here).
    int x_i = clamp((int)floor(local_entry.x), 0, BRICK_CHUNK_SIZE - 1);
    int y_i = clamp((int)floor(local_entry.y), 0, BRICK_CHUNK_SIZE - 1);
    int z_i = clamp((int)floor(local_entry.z), 0, BRICK_CHUNK_SIZE - 1);

    float t_max_x = ((x_i + dir_x) - local_entry.x) / dir.x;
    float t_max_y = ((y_i + dir_y) - local_entry.y) / dir.y;
    float t_max_z = ((z_i + dir_z) - local_entry.z) / dir.z;

    float t = 0.0;
    int i = 0;

    int global_chunk_i = chunk_i * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE;

    uint hit_block_id = 0u;
    float3 hit_side = entry_normal;

    if (x_i >= 0 && y_i >= 0 && z_i >= 0 &&
        x_i < BRICK_CHUNK_SIZE && y_i < BRICK_CHUNK_SIZE && z_i < BRICK_CHUNK_SIZE) {
        int lvi = x_i + y_i * BRICK_CHUNK_SIZE + z_i * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE;
        if (voxel_solid(chunk_i, lvi)) hit_block_id = load_voxel(global_chunk_i + lvi);
    }

    while (i < 23 && hit_block_id == 0u) {
        i++;
        if (t_max_x < t_max_y && t_max_x < t_max_z) {
            x_i += step_x; t = t_max_x; t_max_x += t_delta_x;
            hit_side = float3(-(float)step_x, 0.0, 0.0);
        } else if (t_max_y < t_max_z) {
            y_i += step_y; t = t_max_y; t_max_y += t_delta_y;
            hit_side = float3(0.0, -(float)step_y, 0.0);
        } else {
            z_i += step_z; t = t_max_z; t_max_z += t_delta_z;
            hit_side = float3(0.0, 0.0, -(float)step_z);
        }
        if (x_i < 0 || y_i < 0 || z_i < 0 ||
            x_i >= BRICK_CHUNK_SIZE || y_i >= BRICK_CHUNK_SIZE || z_i >= BRICK_CHUNK_SIZE)
            break;
        int lvi2 = x_i + y_i * BRICK_CHUNK_SIZE + z_i * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE;
        if (voxel_solid(chunk_i, lvi2)) hit_block_id = load_voxel(global_chunk_i + lvi2);
    }

    float3 hit_pos = world_origin + dir * t;
    HitInfo info;
    info.block_id  = hit_block_id;
    info.iterations = i;
    info.t         = t;
    info.normal    = hit_side;
    info.hit_pos   = hit_pos;
    // vkey = EXACT integer chunk coord (chunk_ic, from the outer DDA's
    // integer cell — never a float floor) * 8 + the precision-safe local
    // voxel index. No giant world float is ever reconstructed on this path,
    // so the per-voxel hash is stable across a face at ANY distance — fixes
    // the per-chunk colour seam far from spawn.
    info.vkey      = chunk_ic * BRICK_CHUNK_SIZE + int3(x_i, y_i, z_i);
    return info;
}

// ---- Chunk-level DDA --------------------------------------------------------

HitInfo trace_ray_chunk(float3 origin, float3 dir, bool is_light, int max_iters = RAY_ITERATIONS) {
    float t_delta_x = abs(1.0 / dir.x);
    float t_delta_y = abs(1.0 / dir.y);
    float t_delta_z = abs(1.0 / dir.z);

    int step_x = (int)sign(dir.x);
    int step_y = (int)sign(dir.y);
    int step_z = (int)sign(dir.z);

    int dir_x = step_x > 0 ? 1 : 0;
    int dir_y = step_y > 0 ? 1 : 0;
    int dir_z = step_z > 0 ? 1 : 0;

    float3 chunk_origin = origin / BRICK_CHUNK_SIZE;

    int x_i = (int)floor(chunk_origin.x);
    int y_i = (int)floor(chunk_origin.y);
    int z_i = (int)floor(chunk_origin.z);

    float t_max_x = ((x_i + dir_x) - chunk_origin.x) / dir.x;
    float t_max_y = ((y_i + dir_y) - chunk_origin.y) / dir.y;
    float t_max_z = ((z_i + dir_z) - chunk_origin.z) / dir.z;

    float t = 0.0;
    int i = 0;

    uint   hit_block_id      = 0u;
    float3 hit_side          = float3(0,0,0);
    int3   hit_vkey          = int3(0,0,0);
    float3 chunk_entry_normal = float3(0,0,0);

    int ring_w = CHUNK_COUNT_WIDTH;

    while (i < max_iters) {
        i++;
        if (t > RAY_MAX_LENGTH / float(BRICK_CHUNK_SIZE)) break;

        // Y is not wrapped — hard bounds against the resident world-Y range.
        int ry = y_i - WORLD_CHUNK_Y_MIN;
        if (ry < 0 || ry >= GPU_CHUNKS_HEIGHT) {
            if (is_light) break;
        } else {
            // Wrap X and Z into ring buffer space [0, ring_w).
            int rx = ((x_i % ring_w) + ring_w) % ring_w;
            int rz = ((z_i % ring_w) + ring_w) % ring_w;
            int slot_i = rx + ry * ring_w + rz * ring_w * GPU_CHUNKS_HEIGHT;
            int ci = chunk_index[slot_i];
            if (ci != -1) {
                // Ghost rejection: the slot's owner must match the world coords we're visiting.
                int2 owner = chunk_owner[slot_i];
                if (owner.x != x_i || owner.y != z_i) ci = -1;
            }
            if (ci != -1) {
                float3 entry_pos = chunk_origin * BRICK_CHUNK_SIZE + dir * t * BRICK_CHUNK_SIZE;
                // Precision-safe local entry: subtract the EXACT int chunk
                // coords from the ray pos IN CHUNK UNITS (small magnitude),
                // THEN scale to voxel units. Never reconstructs a giant
                // world float (entry_pos drifts a full voxel+ far from
                // spawn → wrong vkey → per-chunk colour seam). chunk_ic is
                // the outer DDA's exact integers — no float floor needed.
                int3   chunk_ic    = int3(x_i, y_i, z_i);
                float3 local_entry = ((chunk_origin + dir * t) - float3(chunk_ic))
                                     * float(BRICK_CHUNK_SIZE);   // [0,8) per axis
                HitInfo vhit = trace_ray_chunk_voxels(entry_pos, local_entry, dir,
                                                      chunk_ic,
                                                      ci, chunk_entry_normal);
                if (vhit.block_id != 0u) {
                    hit_block_id = vhit.block_id;
                    t += vhit.t / float(BRICK_CHUNK_SIZE);
                    hit_side = vhit.normal;
                    hit_vkey = vhit.vkey;
                    break;
                }
            }
        }

        if (t_max_x < t_max_y && t_max_x < t_max_z) {
            x_i += step_x; t = t_max_x; t_max_x += t_delta_x;
            chunk_entry_normal = float3(-(float)step_x, 0.0, 0.0);
        } else if (t_max_y < t_max_z) {
            y_i += step_y; t = t_max_y; t_max_y += t_delta_y;
            chunk_entry_normal = float3(0.0, -(float)step_y, 0.0);
        } else {
            z_i += step_z; t = t_max_z; t_max_z += t_delta_z;
            chunk_entry_normal = float3(0.0, 0.0, -(float)step_z);
        }
    }

    float3 hit_pos = origin + dir * t * BRICK_CHUNK_SIZE;
    HitInfo info;
    info.block_id   = hit_block_id;
    info.iterations = i;
    info.t          = t * BRICK_CHUNK_SIZE;
    info.normal     = hit_side;
    info.hit_pos    = hit_pos;
    info.vkey       = hit_vkey;
    return info;
}

// ---- Lighting / AO ----------------------------------------------------------

// Minecraft-style SMOOTH ambient occlusion. The old version point-sampled
// 4 neighbours and snapped AO to one of 5 discrete levels per face, so the
// result stepped hard mid-face where a sample crossed a voxel boundary
// (the "split shade on one face" artifact). Instead: compute an AO value
// at each of the face's 4 CORNERS from that corner's 3 touching neighbour
// cells (two edge-adjacent + the diagonal), then BILINEARLY interpolate
// across the face using the sub-voxel hit position → a continuous gradient,
// no steps. `p` is just inside the surface; sub-voxel pos uses frac(hit_pos)
// (the precision-safe convention proven this session).
//
// corner_ao(side1, side2, corner): standard MC rule — if both edge sides
// are solid the corner is fully occluded; else darken by the count.
float corner_ao(bool s1, bool s2, bool c) {
    if (s1 && s2) return 0.0;                       // both sides → max occlusion
    float n = (s1 ? 1.0 : 0.0) + (s2 ? 1.0 : 0.0) + (c ? 1.0 : 0.0);
    return 1.0 - n / 3.0;                            // 0..1, 1 = unoccluded
}

float compute_ao(float3 p, float3 nrm, float3 hit_pos) {
    float3 up      = abs(nrm.y) < 0.9 ? float3(0,1,0) : float3(1,0,0);
    float3 tangent = normalize(cross(up, nrm));
    float3 bitang  = cross(nrm, tangent);

    // Sub-voxel position within the face, in tangent/bitangent axes, [0,1).
    // frac(hit_pos) is the precision-safe sub-voxel coord (same convention
    // the grass-band shading uses). Project onto the (axis-aligned) frame.
    float3 fr = frac(hit_pos);
    float fu = saturate(dot(fr, abs(tangent)));
    float fv = saturate(dot(fr, abs(bitang)));

    // Neighbour occupancy around the hit voxel, on the face plane.
    // pT/nT = ±tangent edge, pB/nB = ±bitangent edge, c** = diagonals.
    bool pT = sample_voxel(p + tangent)            != 0u;
    bool nT = sample_voxel(p - tangent)            != 0u;
    bool pB = sample_voxel(p + bitang)             != 0u;
    bool nB = sample_voxel(p - bitang)             != 0u;
    bool pp = sample_voxel(p + tangent + bitang)   != 0u;
    bool pn = sample_voxel(p + tangent - bitang)   != 0u;
    bool np = sample_voxel(p - tangent + bitang)   != 0u;
    bool nn = sample_voxel(p - tangent - bitang)   != 0u;

    // AO at the 4 face corners (fu,fv ∈ {0,1}) from their 3 touching cells.
    float a00 = corner_ao(nT, nB, nn);   // (-t,-b)
    float a10 = corner_ao(pT, nB, pn);   // (+t,-b)
    float a01 = corner_ao(nT, pB, np);   // (-t,+b)
    float a11 = corner_ao(pT, pB, pp);   // (+t,+b)

    // Bilinear interpolate across the face → continuous, no mid-face step.
    float ao = lerp(lerp(a00, a10, fu), lerp(a01, a11, fu), fv);

    // Keep the original ~0.35 max darkening strength/feel.
    // Max darkening strength (subtle). 0.35 was near-invisible, 0.65 a bit
    // strong; 0.45 = present but understated soft corner shading.
    return 1.0 - (1.0 - ao) * 0.45;
}



// ---- GI ---------------------------------------------------------------------

float3 voxel_albedo(uint block_id, int3 vkey) {
    float3 jitter = hash33i(vkey) * 2.0 - 1.0;
    if      (block_id == BLOCK_GRASS)  return clamp(float3(0.13,0.55,0.08) + jitter*float3(0.04,0.08,0.03), 0.0, 1.0);
    else if (block_id == BLOCK_LOG)    return clamp(float3(0.38,0.22,0.09) + jitter*float3(0.06,0.05,0.03), 0.0, 1.0);
    else if (block_id == BLOCK_LEAVES) return clamp(float3(0.12,0.45,0.07) + jitter*float3(0.05,0.12,0.04), 0.0, 1.0);
    else                               return clamp(float3(0.55,0.55,0.55) + jitter*float3(0.07,0.06,0.06), 0.0, 1.0);
}

// Single GI ray: returns incoming radiance from gi_dir.
// If sky: return sky color. If surface: return that surface's lit color (shadow-tested).
float3 trace_gi_ray(float3 origin, float3 gi_dir) {
    HitInfo hit1 = trace_ray_chunk(origin, gi_dir, false, 32);
    if (hit1.block_id == 0u) return sky_color(gi_dir).rgb;

    float3 N1      = hit1.normal;
    float3 albedo1 = voxel_albedo(hit1.block_id, hit1.vkey);

    // Direct sun at bounce surface — use a proper shadow ray from the air voxel center.
    // This correctly returns 0 for occluded bounce surfaces (caves stay dark).
    float3 shad_origin = float3(hit1.vkey) + float3(0.5, 0.5, 0.5) + N1;
    float  ndl1        = max(0.0, dot(N1, light_dir_normalized));
    float  shad1       = trace_shadow_transmittance(shad_origin, light_dir_normalized);
    float3 radiance    = albedo1 * ndl1 * shad1 * 2.5;

    // Sky ambient at bounce: check if the bounce point can see sky straight up.
    // Using +Y avoids side-face normals immediately hitting adjacent geometry.
    float3 sky_up = float3(0, 1, 0);
    HitInfo hit2 = trace_ray_chunk(shad_origin, sky_up, false, 64);
    if (hit2.block_id == 0u)
        radiance += sky_color(sky_up).rgb * albedo1 * 0.5;

    return radiance;
}

// Fire GI_DIRS_USED fixed Fibonacci directions, return average cosine-weighted irradiance.
// origin: center of the first air voxel above surface = float3(hit_vkey) + 0.5 + normal.
// The checkerboard fix: all 8 directions are purely a function of the surface normal (N),
// not the voxel position — so adjacent voxels with the same normal get identical GI.
#define GI_DIRS_USED 8
float3 compute_gi(float3 origin, float3 N) {
    // TBN built from N only — same result for every voxel with the same face normal.
    // Because voxels only have 6 axis-aligned normals, TBN is identical per face direction.
    float3 T, B;
    build_tbn(N, T, B);
    float3 irr    = float3(0,0,0);
    float  weight = 0.0;
    for (int i = 0; i < GI_DIRS_USED; i++) {
        float3 local_dir = fibonacci_hemisphere(uint(i), GI_DIRS_USED);
        float3 world_dir = local_dir.x * T + local_dir.y * N + local_dir.z * B;
        float  cos_w     = local_dir.y; // cos(theta) in tangent space
        irr    += trace_gi_ray(origin, world_dir) * cos_w;
        weight += cos_w;
    }
    return irr / max(weight, 0.001);
}

// ---- Main -------------------------------------------------------------------

#define AA_SAMPLES 4

// 2x2 jittered sub-pixel offsets (in pixel units)
static const float2 aa_offsets[4] = {
    float2(-0.375, -0.125),
    float2( 0.125, -0.375),
    float2( 0.375,  0.125),
    float2(-0.125,  0.375),
};

float4 trace_pixel(float2 pixel, float2 dims, out float prim_depth, float3 gi_irr) {
    float3 origin = u_cam_pos;
    float nx = (pixel.x * 2.0 - dims.x) / dims.x;
    float ny = -(pixel.y * 2.0 - dims.y) / dims.y;
    float3 dir = normalize(u_cam_fwd + nx * u_cam_right + ny * u_cam_up);

    float4 pixel_color = sky_color(normalize(dir));
    float reflection_amount = 1.0;
    prim_depth = 1e30; // sky default

    for (int i = 0; i < u_reflect_amount; i++) {
        HitInfo hit = trace_ray_chunk(origin, dir, false);
        if (i == 0) prim_depth = (hit.block_id != 0u) ? hit.t : 1e30;
        if (hit.block_id != 0u) {
            float4 hit_color;
            float3 voxel_pos    = floor(hit.hit_pos - hit.normal * 0.5);
            // Per-voxel color uses the exact integer voxel key, not the
            // float hit_pos (which collapses to one value far from spawn).
            float3 color_jitter = hash33i(hit.vkey) * 2.0 - 1.0;
            if (hit.block_id == BLOCK_GRASS) {
                bool is_top = abs(hit.normal.y) > 0.5;
                float3 grass = float3(0.13, 0.55, 0.08);
                float3 dirt  = float3(0.42, 0.28, 0.12);
                float3 base;
                float3 jscale;
                if (is_top) {
                    base = grass; jscale = float3(0.04, 0.08, 0.03);
                } else {
                    // Check whether the voxel above this one is exposed to air
                    bool exposed = (sample_voxel(voxel_pos + float3(0, 1, 0) + 0.5) == 0u);
                    if (exposed) {
                        // Thin grass strip at top of face, dirt below.
                        // frac_y in [0,1] where 1 = top of voxel.
                        float frac_y = frac(hit.hit_pos.y - 0.001);
                        float grass_band = smoothstep(0.6, 0.85, frac_y);
                        base   = lerp(dirt, grass, grass_band);
                        jscale = lerp(float3(0.06, 0.05, 0.04), float3(0.04, 0.08, 0.03), grass_band);
                    } else {
                        base = dirt; jscale = float3(0.06, 0.05, 0.04);
                    }
                }
                hit_color = float4(clamp(base + color_jitter * jscale, 0.0, 1.0), 1.0);
            } else if (hit.block_id == BLOCK_LOG) {
                // Log — warm brown
                float3 base = float3(0.38, 0.22, 0.09);
                hit_color = float4(clamp(base + color_jitter * float3(0.06, 0.05, 0.03), 0.0, 1.0), 1.0);
            } else if (hit.block_id == BLOCK_LEAVES) {
                // Leaves — varied greens
                float3 base = float3(0.12, 0.45, 0.07);
                hit_color = float4(clamp(base + color_jitter * float3(0.05, 0.12, 0.04), 0.0, 1.0), 1.0);
            } else {
                // Stone
                float3 base = float3(0.55, 0.55, 0.55);
                hit_color = float4(clamp(base + color_jitter * float3(0.07, 0.06, 0.06), 0.0, 1.0), 1.0);
            }

            float3 hit_point   = hit.hit_pos;
            float3 surf_normal = hit.normal;
            float3 looking_dir = u_cam_fwd;
            float epsilon      = 0.01;

            // Distance-based shadow LOD: only 1 ray beyond 150 units (fog hides the difference)
            float lighting;
            {
                float3 l = light_dir_normalized;
                float3 shadow_origin = hit_point + surf_normal * epsilon;
                float3 tangent   = normalize(abs(l.x) > 0.9 ? float3(0,1,0) : float3(1,0,0));
                tangent          = normalize(cross(tangent, l));
                float3 bitangent = cross(l, tangent);
                float t0 = trace_shadow_transmittance(shadow_origin, normalize(l));
                float shadow_factor;
                // Soft shadow: 5-tap Poisson disc within a small sun cone (~3 deg radius).
                // spread = tan(3 deg) ~= 0.052. Only fires near penumbra edges (t0 in (0,1)).
                if ((u_quality % 10) == 3 && hit.t < 150.0 && t0 > 0.01 && t0 < 0.99) {
                    static const float2 disk[4] = {
                        float2( 0.0,    1.0),
                        float2( 0.866, -0.5),
                        float2(-0.866, -0.5),
                        float2( 0.0,   -0.3),
                    };
                    float spread = 0.052; // tan(3 deg)
                    float acc = t0;
                    for (int k = 0; k < 4; k++) {
                        float3 jitter = (disk[k].x * tangent + disk[k].y * bitangent) * spread;
                        acc += trace_shadow_transmittance(shadow_origin, normalize(l + jitter));
                    }
                    shadow_factor = acc / 5.0;
                } else {
                    shadow_factor = t0;
                }
                float n_dot_l = dot(surf_normal, l);
                // GI on:  use computed irradiance as ambient (caves dark, sky-lit surfaces bright)
                // GI off: no ambient (pure direct only) so you can see exactly what GI adds
                float ambient = (i == 0 && u_gi_enabled != 0)
                    ? dot(gi_irr, float3(0.299, 0.587, 0.114))
                    : 0.0;
                float sun_direct = n_dot_l > 0.0 ? n_dot_l * shadow_factor * 2.5 : 0.0;
                lighting = ambient + sun_direct;
            }

            // Leaf backlit glow: when sun is behind leaves, tint toward warm yellow-green
            if (hit.block_id == BLOCK_LEAVES) {
                float back_light = clamp(-dot(surf_normal, light_dir_normalized), 0.0, 1.0);
                float3 transmitted = trace_shadow_transmittance(hit_point - surf_normal * epsilon, -light_dir_normalized)
                                     * float3(0.6, 0.9, 0.2) * 0.5;
                hit_color.rgb += transmitted * back_light * sun_tint();
            }

            float ao = (i == 0) ? compute_ao(hit_point + surf_normal * epsilon, surf_normal, hit_point) : 1.0;
            hit_color.xyz *= lighting * ao;
            hit_color = apply_fog(hit_color, hit.t, dir);
            pixel_color = lerp(pixel_color, hit_color, reflection_amount);
            reflection_amount = 0.2;

            origin = hit_point + surf_normal * epsilon;
            dir    = dir - 2.0 * dot(dir, surf_normal) * surf_normal;
        } else {
            pixel_color = lerp(pixel_color, sky_color(normalize(dir)), reflection_amount);
            break;
        }
    }

    pixel_color.rgb = tone_map(pixel_color.rgb);
    return pixel_color;
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    light_dir_normalized = normalize(u_light_dir_raw);

    uint w, h;
    img_output.GetDimensions(w, h);
    float2 dims = float2(w, h);
    int2   ipix = int2(id.xy);
    if (id.x >= w || id.y >= h) return;

    // 1. Compute GI: fire all GI_DIRS_USED fixed Fibonacci directions this frame.
    // Deterministic per surface normal — no history, no noise, perfectly stable.
    float3 gi_irr = float3(0.35, 0.35, 0.35);
    if (u_gi_enabled != 0) {
        float2 pf  = float2(ipix);
        float  nx  = (pf.x * 2.0 - dims.x) / dims.x;
        float  ny  = -(pf.y * 2.0 - dims.y) / dims.y;
        float3 dir = normalize(u_cam_fwd + nx * u_cam_right + ny * u_cam_up);
        HitInfo primary = trace_ray_chunk(u_cam_pos, dir, false);
        if (primary.block_id != 0u) {
            // Push 1 full voxel along the normal from the exact hit point.
            // Using hit_pos (continuous) keeps the origin smooth across voxel boundaries,
            // preventing per-voxel checkerboard discontinuities.
            float3 gi_origin = primary.hit_pos + primary.normal * 1.0;
            gi_irr = compute_gi(gi_origin, primary.normal);
        }
    }

    // 2. AA loop — u_quality packs: AA = u_quality/10, shadow mode = u_quality%10
    int aa = clamp(u_quality / 10, 1, AA_SAMPLES);
    float4 color = float4(0, 0, 0, 0);
    float prim_depth = 1e30;
    for (int s = 0; s < aa; s++) {
        float d;
        color += trace_pixel(float2(ipix) + aa_offsets[s], dims, d, gi_irr);
        if (s == 0) prim_depth = d;
    }
    color /= float(aa);

    // History textures are still bound (pipeline requires them) but unused in this mode.
    img_output[ipix]        = color;
    depth_output[ipix]      = prim_depth;
    gi_history_write[ipix]  = float4(0,0,0,0);
}
