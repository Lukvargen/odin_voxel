// Shared voxel-world CONSTANTS + FUNCTIONS. Deliberately declares NO
// bindings or cbuffer: SPIR-V/SDL3 requires (space0) RO storage textures
// before RO storage buffers, and each pass has a different texture set, so
// the register layout differs per pass. Every shader therefore declares its
// own bindings + the CameraUniforms cbuffer FIRST, then #includes this.
// The functions below reference those globals by name (HLSL resolves them
// since they're declared before the include).
#ifndef VOXEL_COMMON_HLSL
#define VOXEL_COMMON_HLSL

// ---- World constants (must match world.odin) --------------------------------
#define BRICK_CHUNK_SIZE     8
#define CHUNK_COUNT_WIDTH   128
#define GPU_CHUNKS_HEIGHT   64
#define WORLD_CHUNK_Y_MIN  (-32)
#define RAY_MAX_LENGTH      1024.0
#define RAY_ITERATIONS      3000

#define BLOCK_AIR    0u
#define BLOCK_GRASS  1u
#define BLOCK_STONE  2u
#define BLOCK_LOG    3u
#define BLOCK_LEAVES 4u
#define BLOCK_TORCH  5u

// Radiance a block's surface emits on its own (0 = not emissive). Added to
// shading UNLIT (not multiplied by lighting/AO). Their light on the world
// comes from block light (light.odin).
// Bright enough to pass BLOOM_THRESHOLD so emissive blocks glow. Future
// emissive blocks (lava, glowstone) slot in here.
float3 block_emission(uint id) {
    if (id == BLOCK_TORCH) return float3(1.0, 0.55, 0.22) * 6.0;
    return float3(0.0, 0.0, 0.0);
}

#define LEAF_TRANSMIT 0.35

#define PI 3.14159265359

// Integer-coordinate hashes (exact at any distance from spawn).
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

// Required globals each including shader MUST declare before the include:
//   StructuredBuffer<uint> voxel_chunk;   StructuredBuffer<int>  chunk_index;
//   StructuredBuffer<int2> chunk_owner;   StructuredBuffer<uint> voxel_mask;
//   cbuffer CameraUniforms { ... u_light_dir_raw ... }  (only sun_tint_d uses it indirectly via arg)

// Sun tint by elevation (pass-agnostic; takes normalized light dir).
float3 sun_tint_d(float3 Ln) {
    float elev = clamp(Ln.y, 0.0, 1.0);
    return lerp(float3(1.0, 0.45, 0.10), float3(1.0, 0.98, 0.92),
                smoothstep(0.0, 0.35, elev));
}

// voxel_chunk packs 4 voxels (1 byte each) per uint.
uint load_voxel(int idx) {
    uint word = voxel_chunk[idx >> 2];
    return (word >> ((uint(idx) & 3u) * 8u)) & 0xFFu;
}

// Occupancy test: brick = chunk slot id, lvi = local voxel index [0,512).
bool voxel_solid(int brick, int lvi) {
    uint w = voxel_mask[brick * 16 + (lvi >> 5)];
    return ((w >> (uint(lvi) & 31u)) & 1u) != 0u;
}

uint sample_voxel(float3 world_pos) {
    int3 chunk_coord = int3(floor(world_pos / float(BRICK_CHUNK_SIZE)));
    int ry = chunk_coord.y - WORLD_CHUNK_Y_MIN;
    if (ry < 0 || ry >= GPU_CHUNKS_HEIGHT) return 0u;

    int ring_w = CHUNK_COUNT_WIDTH;
    int rx = chunk_coord.x & (ring_w - 1); // ring_w is a power of two
    int rz = chunk_coord.z & (ring_w - 1); // ring_w is a power of two
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

// Clamp each ray-dir component away from zero (sign-preserving) so the DDA
// 1/dir reciprocals never produce inf/NaN (axis-aligned rays, boundary spawn).
float3 safe_dir(float3 d) {
    float3 s = float3(d.x >= 0.0 ? 1.0 : -1.0,
                      d.y >= 0.0 ? 1.0 : -1.0,
                      d.z >= 0.0 ? 1.0 : -1.0);
    return s * max(abs(d), 1e-6);
}

// Per-voxel shadow walk through one occupied chunk. local_entry is the ray
// entry pos in voxel units within the chunk, [0,8) per axis. Returns the
// transmittance factor for this chunk (0 = fully blocked, leaves attenuate
// by LEAF_TRANSMIT per voxel crossed). max_len (voxel units from entry)
// stops the walk at a point-light's position — without it the walk overruns
// the chunk-level max_t check and reports occlusion from the light's own
// voxel or geometry behind it (chunk-alignment-dependent "lights only one
// direction" bug). Emissive voxels never occlude: they ARE the light, and
// stacked torches must not shadow each other.
float shadow_chunk_transmit(int chunk_i, float3 local_entry, float3 dir, float max_len = 1e30) {
    float t_delta_x = abs(1.0 / dir.x);
    float t_delta_y = abs(1.0 / dir.y);
    float t_delta_z = abs(1.0 / dir.z);

    int step_x = (int)sign(dir.x);
    int step_y = (int)sign(dir.y);
    int step_z = (int)sign(dir.z);

    int dir_x = step_x > 0 ? 1 : 0;
    int dir_y = step_y > 0 ? 1 : 0;
    int dir_z = step_z > 0 ? 1 : 0;

    int x_i = clamp((int)floor(local_entry.x), 0, BRICK_CHUNK_SIZE - 1);
    int y_i = clamp((int)floor(local_entry.y), 0, BRICK_CHUNK_SIZE - 1);
    int z_i = clamp((int)floor(local_entry.z), 0, BRICK_CHUNK_SIZE - 1);

    float t_max_x = ((x_i + dir_x) - local_entry.x) / dir.x;
    float t_max_y = ((y_i + dir_y) - local_entry.y) / dir.y;
    float t_max_z = ((z_i + dir_z) - local_entry.z) / dir.z;

    int base = chunk_i * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE;
    float factor = 1.0;

    // Entry voxel first, then step-and-test (each voxel tested exactly once:
    // the step that exits this chunk lands on the next chunk's entry voxel).
    for (int i = 0; i <= 23; i++) {
        if (i > 0) {
            float t_enter;
            if (t_max_x < t_max_y && t_max_x < t_max_z) {
                t_enter = t_max_x; x_i += step_x; t_max_x += t_delta_x;
            } else if (t_max_y < t_max_z) {
                t_enter = t_max_y; y_i += step_y; t_max_y += t_delta_y;
            } else {
                t_enter = t_max_z; z_i += step_z; t_max_z += t_delta_z;
            }
            if (t_enter > max_len) break;
            if (x_i < 0 || y_i < 0 || z_i < 0 ||
                x_i >= BRICK_CHUNK_SIZE || y_i >= BRICK_CHUNK_SIZE || z_i >= BRICK_CHUNK_SIZE)
                break;
        }
        int lvi = x_i + y_i * BRICK_CHUNK_SIZE + z_i * BRICK_CHUNK_SIZE * BRICK_CHUNK_SIZE;
        if (voxel_solid(chunk_i, lvi)) {
            uint bid = load_voxel(base + lvi);
            if (block_emission(bid).x > 0.0) {
                // emissive: transparent to shadow rays
            } else if (bid == BLOCK_LEAVES) {
                factor *= LEAF_TRANSMIT;
                if (factor < 0.01) return 0.0;
            } else {
                return 0.0;
            }
        }
    }
    return factor;
}

// Walks toward the light accumulating transmittance. Leaves attenuate by
// LEAF_TRANSMIT per voxel; any other solid = fully occluded.
// Two-level DDA: steps the 8x-coarser chunk grid and only descends to the
// per-voxel walk inside occupied (index != -1) chunks — empty air is skipped
// a whole chunk at a time instead of voxel-by-voxel.
// max_t (world units) lets point-light shadow rays stop short of the light —
// without it they'd march past the emitter and report occlusion from geometry
// BEHIND it (and hit the solid torch voxel itself). Default keeps the sun /
// volumetric call sites unchanged. The per-voxel walk inside the final chunk
// can overrun max_t slightly; callers stop ~0.9 short of the light so this
// is not visible.
float trace_shadow_transmittance(float3 origin, float3 dir, float max_t = RAY_MAX_LENGTH) {
    dir = safe_dir(dir);

    float t_delta_x = abs(1.0 / dir.x);
    float t_delta_y = abs(1.0 / dir.y);
    float t_delta_z = abs(1.0 / dir.z);

    int step_x = (int)sign(dir.x);
    int step_y = (int)sign(dir.y);
    int step_z = (int)sign(dir.z);

    int dir_x = step_x > 0 ? 1 : 0;
    int dir_y = step_y > 0 ? 1 : 0;
    int dir_z = step_z > 0 ? 1 : 0;

    float3 chunk_origin = origin / float(BRICK_CHUNK_SIZE);

    int x_i = (int)floor(chunk_origin.x);
    int y_i = (int)floor(chunk_origin.y);
    int z_i = (int)floor(chunk_origin.z);

    float t_max_x = ((x_i + dir_x) - chunk_origin.x) / dir.x;
    float t_max_y = ((y_i + dir_y) - chunk_origin.y) / dir.y;
    float t_max_z = ((z_i + dir_z) - chunk_origin.z) / dir.z;

    int ring_w = CHUNK_COUNT_WIDTH;
    float transmittance = 1.0;
    float t = 0.0; // in chunk units

    // Worst-case diagonal within RAY_MAX_LENGTH crosses ~3*128 chunks.
    for (int i = 0; i < 512; i++) {
        if (t > max_t / float(BRICK_CHUNK_SIZE)) break;

        int ry = y_i - WORLD_CHUNK_Y_MIN;
        if (ry < 0 || ry >= GPU_CHUNKS_HEIGHT) {
            // Outside the resident Y range and moving further out: the ray
            // can never re-enter, treat the rest as unoccluded (matches the
            // old voxel-level Y-bounds break).
            if ((ry < 0 && step_y <= 0) || (ry >= GPU_CHUNKS_HEIGHT && step_y >= 0)) break;
        } else {
            int rx = x_i & (ring_w - 1); // ring_w is a power of two
            int rz = z_i & (ring_w - 1); // ring_w is a power of two
            int slot_i = rx + ry * ring_w + rz * ring_w * GPU_CHUNKS_HEIGHT;
            int ci = chunk_index[slot_i];
            if (ci != -1) {
                int2 owner = chunk_owner[slot_i];
                if (owner.x != x_i || owner.y != z_i) ci = -1;
            }
            if (ci != -1) {
                // Precision-safe local entry, same pattern as the primary
                // tracer: subtract exact int chunk coords in chunk units,
                // then scale to voxel units.
                int3   chunk_ic    = int3(x_i, y_i, z_i);
                float3 local_entry = ((chunk_origin + dir * t) - float3(chunk_ic))
                                     * float(BRICK_CHUNK_SIZE);
                // Remaining ray budget in voxel units from this chunk's entry
                // (max_t is world==voxel units; t is in chunk units).
                transmittance *= shadow_chunk_transmit(ci, local_entry, dir,
                                                       max_t - t * float(BRICK_CHUNK_SIZE));
                if (transmittance < 0.01) return 0.0;
            }
        }

        if (t_max_x < t_max_y && t_max_x < t_max_z) {
            x_i += step_x; t = t_max_x; t_max_x += t_delta_x;
        } else if (t_max_y < t_max_z) {
            y_i += step_y; t = t_max_y; t_max_y += t_delta_y;
        } else {
            z_i += step_z; t = t_max_z; t_max_z += t_delta_z;
        }
    }
    return transmittance;
}

// ---- Sky / albedo (pass-agnostic: take normalized light dir as arg) ---------

// FBM clouds: value noise on integer lattice (hash31i — exact anywhere).
float vnoise2(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    int2 ip = int2(i);
    float a = hash31i(int3(ip,             7));
    float b = hash31i(int3(ip + int2(1,0), 7));
    float c = hash31i(int3(ip + int2(0,1), 7));
    float d = hash31i(int3(ip + int2(1,1), 7));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float fbm2(float2 p) {
    float v = 0.0, amp = 0.5;
    [unroll]
    for (int i = 0; i < 4; i++) {
        v   += vnoise2(p) * amp;
        p    = p * 2.03 + 17.31;
        amp *= 0.5;
    }
    return v; // ~[0,1]
}

#define CLOUD_SCALE  1.6    // sky-plane uv scale (smaller = bigger clouds)
#define CLOUD_COVER  0.48   // fbm threshold (higher = fewer clouds)
#define CLOUD_DRIFT  float2(0.004, 0.0015) // uv/sec

float3 sky_color_impl(float3 dir, float3 Ln, float disc_amt, float glow_amt) {
    float t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    float elev = clamp(Ln.y, 0.0, 1.0);
    float3 horizon = lerp(float3(0.90, 0.55, 0.25), float3(0.75, 0.85, 1.0), smoothstep(0.0, 0.3, elev));
    float3 zenith  = lerp(float3(0.20, 0.10, 0.05), float3(0.10, 0.35, 0.80), smoothstep(0.0, 0.4, elev));
    float3 sky = lerp(horizon, zenith, pow(t, 0.6));
    float sun_dot  = dot(normalize(dir), Ln);
    float sun_disc = smoothstep(0.9985, 0.9995, sun_dot) * disc_amt;
    float sun_glow = smoothstep(0.960,  0.9985, sun_dot) * 0.4 * glow_amt;
    sky = lerp(sky, sun_tint_d(Ln), sun_disc + sun_glow * 0.6);

    // Cloud layer, drawn over the disc (sun behind cloud = dimmed). Project
    // the ray onto a flat sky plane; fade out at the horizon (projection
    // blows up) so distant haze stays clean.
    if (dir.y > 0.02) {
        float2 uv  = dir.xz / (dir.y + 0.15) * CLOUD_SCALE + u_time * CLOUD_DRIFT;
        float  den = smoothstep(CLOUD_COVER, CLOUD_COVER + 0.32, fbm2(uv));
        den *= smoothstep(0.02, 0.18, dir.y);
        // Sunlit tops vs gray-blue underside by density; warm at low sun.
        float3 lit   = float3(1.04, 1.02, 0.98) * lerp(float3(1,1,1), sun_tint_d(Ln), 0.35);
        float3 shade = float3(0.62, 0.67, 0.78);
        float3 ccol  = lerp(lit, shade, den * 0.7);
        sky = lerp(sky, ccol, den * 0.9);
    }
    return sky;
}

// Sky as seen directly (miss rays): full sun disc + glow.
float3 sky_color_d(float3 dir, float3 Ln) {
    return sky_color_impl(dir, Ln, 1.0, 1.0);
}

// Sky as a FOG color (blended onto hit geometry): the sharp disc would read
// as the sun rendering in front of fogged mountains, so drop it and halve
// the broad glow (forward-scatter halo through haze is plausible; a hard
// circle is not).
float3 sky_color_fog_d(float3 dir, float3 Ln) {
    return sky_color_impl(dir, Ln, 0.0, 0.5);
}

float3 voxel_albedo(uint block_id, int3 vkey) {
    float3 jitter = hash33i(vkey) * 2.0 - 1.0;
    if      (block_id == BLOCK_GRASS)  return clamp(float3(0.16,0.42,0.10) + jitter*float3(0.04,0.06,0.03), 0.0, 1.0);
    else if (block_id == BLOCK_LOG)    return clamp(float3(0.38,0.22,0.09) + jitter*float3(0.06,0.05,0.03), 0.0, 1.0);
    else if (block_id == BLOCK_LEAVES) return clamp(float3(0.13,0.38,0.09) + jitter*float3(0.05,0.10,0.04), 0.0, 1.0);
    else                               return clamp(float3(0.55,0.55,0.55) + jitter*float3(0.07,0.06,0.06), 0.0, 1.0);
}

// ---- Two-level ray trace (chunk DDA -> voxel DDA) ----------------------------

struct HitInfo {
    uint  block_id;
    int   iterations;
    float t;
    float3 normal;
    float3 hit_pos;
    int3   vkey;     // exact integer voxel coord (precision-safe, for hashing)
};

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

HitInfo trace_ray_chunk(float3 origin, float3 dir, bool is_light, int max_iters = RAY_ITERATIONS) {
    dir = safe_dir(dir);

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
            int rx = x_i & (ring_w - 1); // ring_w is a power of two
            int rz = z_i & (ring_w - 1); // ring_w is a power of two
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

// ---- Voxel light (light.odin) ---------------------------------------------
// Only for shaders that declare `light_index` (StructuredBuffer<int>) and
// `light_pool` (StructuredBuffer<uint>) — define HAS_VOXEL_LIGHT first.
// One byte per voxel: sky light << 4 | block light, both 0..15.
#ifdef HAS_VOXEL_LIGHT

#define LIGHT_SKY_FULL 0xF0u

// Light byte of world voxel v. Outside the resident world reads as open sky,
// so the far edge of the loaded area never turns black.
uint sample_light(int3 v) {
    int3 cc = v >> 3; // arithmetic shift: floor division by 8
    int ry = cc.y - WORLD_CHUNK_Y_MIN;
    if (ry < 0) return 0u;
    if (ry >= GPU_CHUNKS_HEIGHT) return LIGHT_SKY_FULL;
    int rx = cc.x & (CHUNK_COUNT_WIDTH - 1);
    int rz = cc.z & (CHUNK_COUNT_WIDTH - 1);
    int slot = rx + ry * CHUNK_COUNT_WIDTH + rz * CHUNK_COUNT_WIDTH * GPU_CHUNKS_HEIGHT;
    int2 owner = chunk_owner[slot];
    if (owner.x != cc.x || owner.y != cc.z) return LIGHT_SKY_FULL;
    int li = light_index[slot];
    if (li < 0) return uint(-1 - li); // whole chunk has one light value
    int3 l  = v & 7;
    int idx = li * 512 + l.x + l.y * 8 + l.z * 64;
    return (light_pool[idx >> 2] >> ((uint(idx) & 3u) * 8u)) & 0xFFu;
}

// Smooth (sky, block) light, each 0..15, at hit_pos on the face of voxel
// vkey with normal nrm: bilinear over the four voxels in front of the face
// nearest the point. Unlit samples (solid blocks) are left out so a wall
// beside the face doesn't darken it (AO does contact shadow), and the
// diagonal is skipped when both edge samples are blocked so light can't leak
// around a corner.
float2 face_light(int3 vkey, float3 nrm, float3 hit_pos) {
    int3 n = int3(round(nrm));
    int3 f = vkey + n;
    int3 t = (n.x != 0) ? int3(0, 0, 1) : int3(1, 0, 0);
    int3 b = (n.y != 0) ? int3(0, 0, 1) : int3(0, 1, 0);
    float3 fr = frac(hit_pos);
    float fu = dot(fr, float3(t));
    float fv = dot(fr, float3(b));
    int3 du = (fu < 0.5 ? -1 : 1) * t;
    int3 dv = (fv < 0.5 ? -1 : 1) * b;
    float wu = abs(fu - 0.5);
    float wv = abs(fv - 0.5);

    uint l00 = sample_light(f);
    uint l10 = sample_light(f + du);
    uint l01 = sample_light(f + dv);
    uint l11 = (l10 != 0u || l01 != 0u) ? sample_light(f + du + dv) : 0u;

    float4 w = float4((1.0 - wu) * (1.0 - wv), wu * (1.0 - wv), (1.0 - wu) * wv, wu * wv);
    w *= float4(1.0, l10 != 0u ? 1.0 : 0.0, l01 != 0u ? 1.0 : 0.0, l11 != 0u ? 1.0 : 0.0);
    uint4 l = uint4(l00, l10, l01, l11);
    float inv = 1.0 / (w.x + w.y + w.z + w.w);
    return float2(dot(w, float4(l >> 4)), dot(w, float4(l & 15u))) * inv;
}

// Light level (0..15) to brightness: each level is 20% dimmer, as in
// Minecraft, so light falls off smoothly instead of linearly.
float light_curve(float level) {
    return level > 0.0 ? pow(0.8, 15.0 - level) : 0.0;
}

#endif // HAS_VOXEL_LIGHT

#endif // VOXEL_COMMON_HLSL
