// Voxel raytracer compute shader — ported from voxel_tracer.glsl
// Two-level DDA: chunk-grid traversal, then per-chunk voxel traversal.

// ---- Bindings ---------------------------------------------------------------
// SDL3 GPU SPIR-V binding layout for compute shaders:
//   set 0: samplers, read-only storage textures, read-only storage buffers
//   set 1: read-write storage textures, read-write storage buffers
//   set 2: uniform buffers

// set 0, binding 0..2: read-only storage buffers
StructuredBuffer<uint>     voxel_chunk : register(t0, space0); // voxel data per chunk
StructuredBuffer<int>      chunk_index : register(t1, space0); // pool id, -1 = air (no storage)
StructuredBuffer<int2>     chunk_owner : register(t2, space0); // (world_cx, world_cz) owner per ring slot
StructuredBuffer<uint>     voxel_mask  : register(t3, space0); // 16 u32 (512-bit occupancy) per slot

// set 1, binding 0: read-write storage texture
RWTexture2D<float4>        img_output  : register(u0, space1);

// set 2, binding 0: uniform buffer
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
    int    u_quality;   // packed: AA = /10 (1..4), shadow_rays = %10 (1 or 3)
};

// ---- Constants --------------------------------------------------------------

#define BRICK_CHUNK_SIZE     8
#define CHUNK_COUNT_WIDTH   128   // MUST match world.odin CHUNKS_W
#define GPU_CHUNKS_HEIGHT   64
// World chunk-Y range: wcy in [WORLD_CHUNK_Y_MIN, WORLD_CHUNK_Y_MIN+GPU_CHUNKS_HEIGHT).
// Ring Y index = wcy - WORLD_CHUNK_Y_MIN. Must match world.odin.
#define WORLD_CHUNK_Y_MIN  (-32)
#define RAY_MAX_LENGTH      1024.0
#define RAY_ITERATIONS      3000

#define BLOCK_AIR    0u
#define BLOCK_GRASS  1u
#define BLOCK_STONE  2u
#define BLOCK_LOG    3u
#define BLOCK_LEAVES 4u

// voxel_chunk packs 4 voxels (1 byte each) per uint. idx = global per-voxel
// index; returns the block id in [0,255].
uint load_voxel(int idx) {
    uint word = voxel_chunk[idx >> 2];
    return (word >> ((uint(idx) & 3u) * 8u)) & 0xFFu;
}

// Occupancy test: brick = chunk slot id, lvi = local voxel index [0,512).
// 16 u32 per brick, bit lvi&31 of word lvi>>5. Avoids a material fetch for
// air voxels (the common case along a ray).
bool voxel_solid(int brick, int lvi) {
    uint w = voxel_mask[brick * 16 + (lvi >> 5)];
    return ((w >> (uint(lvi) & 31u)) & 1u) != 0u;
}

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

uint sample_voxel(float3 world_pos) {
    int3 chunk_coord = int3(floor(world_pos / float(BRICK_CHUNK_SIZE)));
    int ry = chunk_coord.y - WORLD_CHUNK_Y_MIN;            // ring Y index
    if (ry < 0 || ry >= GPU_CHUNKS_HEIGHT) return 0u;

    int ring_w = CHUNK_COUNT_WIDTH;
    int rx = ((chunk_coord.x % ring_w) + ring_w) % ring_w;
    int rz = ((chunk_coord.z % ring_w) + ring_w) % ring_w;
    int slot = rx + ry * ring_w + rz * ring_w * GPU_CHUNKS_HEIGHT;

    int2 owner = chunk_owner[slot];
    if (owner.x != chunk_coord.x || owner.y != chunk_coord.z) return 0u;

    int ci = chunk_index[slot];
    if (ci == -1) return 0u;

    int3 local = int3(floor(world_pos)) - chunk_coord * BRICK_CHUNK_SIZE;
    local = clamp(local, int3(0,0,0), int3(BRICK_CHUNK_SIZE-1, BRICK_CHUNK_SIZE-1, BRICK_CHUNK_SIZE-1));
    int lvi  = local.x + local.y*BRICK_CHUNK_SIZE + local.z*BRICK_CHUNK_SIZE*BRICK_CHUNK_SIZE;
    if (!voxel_solid(ci, lvi)) return 0u;
    int base = ci * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE;
    return load_voxel(base + lvi);
}

// ---- Voxel-level DDA --------------------------------------------------------

HitInfo trace_ray_chunk_voxels(float3 origin, float3 dir, float3 chunk_pos,
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

    float3 world_chunk_pos = chunk_pos * BRICK_CHUNK_SIZE;

    int x_i = (int)floor(origin.x) - (int)world_chunk_pos.x;
    int y_i = (int)floor(origin.y) - (int)world_chunk_pos.y;
    int z_i = (int)floor(origin.z) - (int)world_chunk_pos.z;

    float t_max_x = ((x_i + dir_x) - (origin.x - world_chunk_pos.x)) / dir.x;
    float t_max_y = ((y_i + dir_y) - (origin.y - world_chunk_pos.y)) / dir.y;
    float t_max_z = ((z_i + dir_z) - (origin.z - world_chunk_pos.z)) / dir.z;

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

    float3 hit_pos = origin + dir * t;
    HitInfo info;
    info.block_id  = hit_block_id;
    info.iterations = i;
    info.t         = t;
    info.normal    = hit_side;
    info.hit_pos   = hit_pos;
    // Precision-safe voxel key: integer chunk coord (magnitude = world/8, so
    // exact ~8x farther than a voxel-scale float) * 8 + exact local coords
    // (0..7). Never reconstructs a giant voxel-scale float, so the per-voxel
    // hash stays unique far from spawn instead of collapsing to one color.
    int3 chunk_i3 = int3(floor(chunk_pos));
    info.vkey      = chunk_i3 * BRICK_CHUNK_SIZE + int3(x_i, y_i, z_i);
    return info;
}

// ---- Chunk-level DDA --------------------------------------------------------

HitInfo trace_ray_chunk(float3 origin, float3 dir, bool is_light) {
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

    while (i < RAY_ITERATIONS) {
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
                HitInfo vhit = trace_ray_chunk_voxels(entry_pos, dir,
                                                      float3(x_i, y_i, z_i),
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

// ---- Shadow transmittance ray -----------------------------------------------
// Walks toward the light, accumulating transmittance.
// Leaves (block_id==4) attenuate by LEAF_TRANSMIT each voxel crossed.
// Any other solid block = fully occluded.

#define LEAF_TRANSMIT 0.35

float trace_shadow_transmittance(float3 origin, float3 dir) {
    float t_delta_x = abs(1.0 / dir.x);
    float t_delta_y = abs(1.0 / dir.y);
    float t_delta_z = abs(1.0 / dir.z);

    int step_x = (int)sign(dir.x);
    int step_y = (int)sign(dir.y);
    int step_z = (int)sign(dir.z);

    int dir_x = step_x > 0 ? 1 : 0;
    int dir_y = step_y > 0 ? 1 : 0;
    int dir_z = step_z > 0 ? 1 : 0;

    int xi = (int)floor(origin.x);
    int yi = (int)floor(origin.y);
    int zi = (int)floor(origin.z);

    float t_max_x = ((xi + dir_x) - origin.x) / dir.x;
    float t_max_y = ((yi + dir_y) - origin.y) / dir.y;
    float t_max_z = ((zi + dir_z) - origin.z) / dir.z;

    float transmittance = 1.0;
    float t = 0.0;

    for (int iter = 0; iter < RAY_ITERATIONS && t < RAY_MAX_LENGTH; iter++) {
        uint bid = sample_voxel(float3(xi, yi, zi) + 0.5);
        if (bid == BLOCK_LEAVES) {
            transmittance *= LEAF_TRANSMIT;
            if (transmittance < 0.01) return 0.0;
        } else if (bid != 0u) {
            return 0.0;
        }

        if (t_max_x < t_max_y && t_max_x < t_max_z) {
            xi += step_x; t = t_max_x; t_max_x += t_delta_x;
        } else if (t_max_y < t_max_z) {
            yi += step_y; t = t_max_y; t_max_y += t_delta_y;
        } else {
            zi += step_z; t = t_max_z; t_max_z += t_delta_z;
        }

        if (yi < WORLD_CHUNK_Y_MIN * BRICK_CHUNK_SIZE ||
            yi >= (WORLD_CHUNK_Y_MIN + GPU_CHUNKS_HEIGHT) * BRICK_CHUNK_SIZE) break;
    }
    return transmittance;
}

// ---- Lighting / AO ----------------------------------------------------------

float compute_ao(float3 p, float3 nrm) {
    float3 up      = abs(nrm.y) < 0.9 ? float3(0,1,0) : float3(1,0,0);
    float3 tangent = normalize(cross(up, nrm));
    float3 bitang  = cross(nrm, tangent);

    float3 d0 = normalize(nrm + tangent);
    float3 d1 = normalize(nrm - tangent);
    float3 d2 = normalize(nrm + bitang);
    float3 d3 = normalize(nrm - bitang);

    int hits = 0;
    if (sample_voxel(p + d0) != 0u) hits++;
    if (sample_voxel(p + d1) != 0u) hits++;
    if (sample_voxel(p + d2) != 0u) hits++;
    if (sample_voxel(p + d3) != 0u) hits++;
    return 1.0 - (float(hits) / 4.0) * 0.35;
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

float4 trace_pixel(float2 pixel, float2 dims) {
    float3 origin = u_cam_pos;
    float nx = (pixel.x * 2.0 - dims.x) / dims.x;
    float ny = -(pixel.y * 2.0 - dims.y) / dims.y;
    float3 dir = normalize(u_cam_fwd + nx * u_cam_right + ny * u_cam_up);

    float4 pixel_color = sky_color(normalize(dir));
    float reflection_amount = 1.0;

    for (int i = 0; i < u_reflect_amount; i++) {
        HitInfo hit = trace_ray_chunk(origin, dir, false);
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
                // 3-ray soft shadow only when enabled (u_quality%10==3) AND
                // near (fog hides far penumbra anyway). Else 1 hard ray.
                if ((u_quality % 10) == 3 && hit.t < 150.0) {
                    float t1 = trace_shadow_transmittance(shadow_origin, normalize(l + (0.707 * tangent)   * 1.5));
                    float t2 = trace_shadow_transmittance(shadow_origin, normalize(l + (0.707 * bitangent) * 1.5));
                    shadow_factor = (t0 + t1 + t2) / 3.0;
                } else {
                    shadow_factor = t0;
                }
                float n_dot_l = dot(surf_normal, l);
                lighting = 0.35 + (n_dot_l > 0.0 ? n_dot_l * shadow_factor : 0.0);
            }

            // Leaf backlit glow: when sun is behind leaves, tint toward warm yellow-green
            if (hit.block_id == BLOCK_LEAVES) {
                float back_light = clamp(-dot(surf_normal, light_dir_normalized), 0.0, 1.0);
                float3 transmitted = trace_shadow_transmittance(hit_point - surf_normal * epsilon, -light_dir_normalized)
                                     * float3(0.6, 0.9, 0.2) * 0.5;
                hit_color.rgb += transmitted * back_light * sun_tint();
            }

            float ao = (i == 0) ? compute_ao(hit_point + surf_normal * epsilon, surf_normal) : 1.0;
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
    float2 pixel = float2(id.xy);

    // u_quality packs quality settings: AA = u_quality/10 (1..4),
    // shadow ray count handled in trace_pixel via u_quality%10.
    int aa = clamp(u_quality / 10, 1, AA_SAMPLES);
    float4 color = float4(0, 0, 0, 0);
    for (int s = 0; s < aa; s++) {
        color += trace_pixel(pixel + aa_offsets[s], dims);
    }
    img_output[int2(id.xy)] = color / float(aa);
}
