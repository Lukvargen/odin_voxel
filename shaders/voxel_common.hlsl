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

// Coarse occupancy: one counter per 4x4x4 chunks (32^3 voxels) of the ring,
// non-zero if any chunk inside is not air (world.odin, region_count). Rays
// cross empty regions without reading chunk data. Stored after the slots in
// chunk_index, at REGION_BASE.
#define REGION_CHUNKS       4
#define REGION_W            (CHUNK_COUNT_WIDTH / REGION_CHUNKS)   // 32
#define REGION_H            (GPU_CHUNKS_HEIGHT / REGION_CHUNKS)   // 16
#define REGION_BASE         (CHUNK_COUNT_WIDTH * GPU_CHUNKS_HEIGHT * CHUNK_COUNT_WIDTH)

int region_of(int rx, int ry, int rz) {
    return (rx >> 2) + (ry >> 2) * REGION_W + (rz >> 2) * REGION_W * REGION_H;
}

// One step of the chunk-level DDA (shared by the primary and shadow walks).
#define CHUNK_DDA_STEP                                              \
    if (t_max_x < t_max_y && t_max_x < t_max_z) {                   \
        x_i += step_x; t = t_max_x; t_max_x += t_delta_x; axis = 0; \
    } else if (t_max_y < t_max_z) {                                 \
        y_i += step_y; t = t_max_y; t_max_y += t_delta_y; axis = 1; \
    } else {                                                        \
        z_i += step_z; t = t_max_z; t_max_z += t_delta_z; axis = 2; \
    }

// Step out of the current (empty) region without touching memory. Leaving
// a 4^3 box takes at most 10 steps.
#define SKIP_EMPTY_REGION                                           \
    {                                                               \
        int3 rc = int3(x_i, y_i, z_i) >> 2;                         \
        [loop] for (int k = 0; k < 12; k++) {                       \
            CHUNK_DDA_STEP                                          \
            if (any((int3(x_i, y_i, z_i) >> 2) != rc)) break;       \
        }                                                           \
    }
#define RAY_ITERATIONS      3000

#define BLOCK_AIR    0u
#define BLOCK_GRASS  1u
#define BLOCK_STONE  2u
#define BLOCK_LOG    3u
#define BLOCK_LEAVES 4u
#define BLOCK_TORCH  5u
#define BLOCK_DIRT          6u
#define BLOCK_SAND          7u
#define BLOCK_SANDSTONE     8u
#define BLOCK_SNOW          9u
#define BLOCK_ICE           10u
#define BLOCK_WATER         11u
#define BLOCK_GRAVEL        12u
#define BLOCK_TERRACOTTA    13u
#define BLOCK_RED_SAND      14u
#define BLOCK_COAL_ORE      15u
#define BLOCK_IRON_ORE      16u
#define BLOCK_GOLD_ORE      17u
#define BLOCK_SPRUCE_LOG    18u
#define BLOCK_SPRUCE_LEAVES 19u
#define BLOCK_CACTUS        20u
#define BLOCK_WEATHERED_STONE 21u // terrain surface rock (moss / ledge snow)

bool block_is_leaves(uint id) { return id == BLOCK_LEAVES || id == BLOCK_SPRUCE_LEAVES; }

// Radiance a block's surface emits on its own (0 = not emissive). Added to
// shading UNLIT (not multiplied by lighting/AO). Their light on the world
// comes from block light (light.odin).
// Bright enough to pass BLOOM_THRESHOLD so emissive blocks glow. Future
// emissive blocks (lava, glowstone) slot in here.
float3 block_emission(uint id) {
    if (id == BLOCK_TORCH) return float3(1.0, 0.62, 0.40) * 7.0; // times albedo^2 in shading
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

// Colour of the light along Ln (the sun by day, the moon at night: see
// u_sun_true). Sun: orange at the horizon, golden through the afternoon, near
// white only high overhead. Moon: cool silver-blue.
float3 sun_tint_d(float3 Ln) {
    float elev = clamp(Ln.y, 0.0, 1.0);
    float3 c = lerp(float3(1.0, 0.42, 0.10), float3(1.0, 0.85, 0.66), smoothstep(0.0, 0.30, elev));
    c = lerp(c, float3(1.0, 0.96, 0.90), smoothstep(0.45, 0.95, elev));
    return lerp(c, float3(0.55, 0.68, 1.0), u_sun_true.w);
}

// Colour of the real sun (for the sky), whatever lights the world.
float3 true_sun_tint() {
    float elev = clamp(u_sun_true.y, 0.0, 1.0);
    float3 c = lerp(float3(1.0, 0.42, 0.10), float3(1.0, 0.85, 0.66), smoothstep(0.0, 0.30, elev));
    return lerp(c, float3(1.0, 0.96, 0.90), smoothstep(0.45, 0.95, elev));
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
    if (ci < -1) return uint(-ci - 2); // uniform chunk

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
            if (block_emission(bid).x > 0.0 || bid == BLOCK_WATER) {
                // emissive / water: transparent to shadow rays (water
                // darkens what's under it through absorption instead)
            } else if (block_is_leaves(bid)) {
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
    int axis = 0;

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
            if (chunk_index[REGION_BASE + region_of(rx, ry, rz)] == 0) {
                SKIP_EMPTY_REGION
                continue;
            }
            int slot_i = rx + ry * ring_w + rz * ring_w * GPU_CHUNKS_HEIGHT;
            int ci = chunk_index[slot_i];
            if (ci != -1) {
                int2 owner = chunk_owner[slot_i];
                if (owner.x != x_i || owner.y != z_i) ci = -1;
            }
            if (ci == -2 - int(BLOCK_WATER)) ci = -1; // open water: see above
            if (ci < -1) return 0.0; // other uniform chunks are opaque
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

        CHUNK_DDA_STEP
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

float vnoise3(float3 p) {
    float3 i = floor(p);
    float3 f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    int3 ip = int3(i);
    float a = hash31i(ip);
    float b = hash31i(ip + int3(1, 0, 0));
    float c = hash31i(ip + int3(0, 1, 0));
    float d = hash31i(ip + int3(1, 1, 0));
    float e = hash31i(ip + int3(0, 0, 1));
    float g = hash31i(ip + int3(1, 0, 1));
    float h = hash31i(ip + int3(0, 1, 1));
    float k = hash31i(ip + int3(1, 1, 1));
    return lerp(lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y),
                lerp(lerp(e, g, f.x), lerp(h, k, f.x), f.y), f.z);
}

#define CLOUD_SCALE  1.6    // sky-plane uv scale (smaller = bigger clouds)
#define CLOUD_COVER  0.50   // fbm threshold (higher = fewer clouds)
#define CLOUD_DRIFT  float2(0.004, 0.0015) // uv/sec

// Stars: one candidate per cell of a 3D grid over the unit sphere, so they
// are fixed to directions. A faint milky band crosses the sky. The sky turns
// slowly with the clock.
float3 night_sky(float3 dir) {
    float a = u_time * 0.004;
    float ca = cos(a), sa = sin(a);
    float3 d = float3(dir.x * ca - dir.z * sa, dir.y, dir.x * sa + dir.z * ca);
    float3 p = d * 260.0;
    int3   c = int3(floor(p));
    float  h = hash31i(c + int3(11, 23, 5));
    float3 col = float3(0, 0, 0);
    if (h > 0.985) {
        float3 sp = float3(c) + 0.5 + (hash33i(c) - 0.5) * 0.5;
        float  r  = length(p - sp);
        float  b  = (h - 0.985) / 0.015;               // 0..1, few bright ones
        float  tw = 0.75 + 0.25 * sin(u_time * (2.0 + 5.0 * hash31i(c)) + h * 40.0);
        float3 tint = lerp(float3(1.0, 0.82, 0.65), float3(0.70, 0.82, 1.0), hash31i(c + 99));
        col += tint * (0.25 + 2.6 * b * b) * tw * smoothstep(0.55, 0.0, r);
    }
    // Milky way: a band of soft fbm around a tilted great circle.
    // 3D noise on the direction: seamless and unstretched on the sphere.
    float off  = dot(d, normalize(float3(0.35, 0.55, -0.76)));
    float band = exp(-pow(off * 3.2, 2.0));
    float neb  = 0.0;
    if (band > 0.02) {
        float3 q = d * 7.0 + 31.0;
        neb = vnoise3(q) * 0.55 + vnoise3(q * 2.1) * 0.30 + vnoise3(q * 4.3) * 0.15;
    }
    col += float3(0.10, 0.11, 0.16) * band * smoothstep(0.35, 0.8, neb) * 0.9;
    return col * smoothstep(0.0, 0.25, dir.y);
}

float3 sky_color_impl(float3 dir, float3 Ln, float disc_amt, float glow_amt, bool clouds) {
    float3 S = u_sun_true.xyz;          // the real sun (Ln is the moon at night)
    float  night = u_sun_true.w;
    float  t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    float  elev = clamp(S.y, 0.0, 1.0);
    // Low sun (and the twilight after it sets): warm horizon, deep zenith.
    float  golden = 1.0 - smoothstep(0.0, 0.32, S.y);
    float3 horizon = lerp(float3(0.70, 0.80, 0.92), float3(0.98, 0.56, 0.30), golden);
    float3 zenith  = lerp(float3(0.10, 0.30, 0.68), float3(0.12, 0.22, 0.48), golden);
    // Night: deep blue-black, horizon a touch lighter (airglow).
    horizon = lerp(horizon, float3(0.022, 0.034, 0.064), night);
    zenith  = lerp(zenith,  float3(0.004, 0.008, 0.024), night);
    float3 sky = lerp(horizon, zenith, pow(t, 0.55));

    // Sunset band: the sky low over the sun's side blazes orange-pink, the
    // opposite horizon turns dusky violet (the earth's shadow).
    float2 hd = dir.xz / max(length(dir.xz), 1e-4);
    float2 hs = S.xz / max(length(S.xz), 1e-4);
    float  side = dot(hd, hs) * 0.5 + 0.5;
    float  low  = exp(-abs(dir.y) * 5.0);
    float  dusk = golden * (1.0 - smoothstep(-0.05, 0.18, -S.y));
    sky += float3(1.00, 0.36, 0.10) * low * pow(side, 3.0) * dusk * 0.55;
    sky  = lerp(sky, sky * float3(0.80, 0.76, 0.95), low * (1.0 - side) * dusk * 0.5);

    float sun_dot  = dot(normalize(dir), S);
    float sun_vis  = smoothstep(-0.03, 0.01, S.y);
    float sun_disc = smoothstep(0.9985, 0.9995, sun_dot) * disc_amt * sun_vis;
    float sun_glow = smoothstep(0.960,  0.9985, sun_dot) * 0.4 * glow_amt * sun_vis;
    float3 st = true_sun_tint();
    sky = lerp(sky, st, sun_disc + sun_glow * 0.6);
    // The disc itself is far brighter than the sky: it blooms, and still
    // shows as a bright patch through thin cloud.
    sky += st * sun_disc * 6.0;
    // Wide forward-scatter halo: the sky around the sun and the haze toward
    // it brighten and warm, the opposite sky stays deep blue.
    float halo = pow(saturate(sun_dot * 0.5 + 0.5), 6.0);
    sky += st * float3(0.30, 0.22, 0.12) * halo * glow_amt * (1.0 - t * 0.5) * smoothstep(-0.15, 0.05, S.y);

    // Night: stars, and the moon opposite the sun with a soft halo.
    if (night > 0.0) {
        float3 M = -S;
        float  md = dot(normalize(dir), M);
        float3 nsky = disc_amt > 0.0 ? night_sky(dir) * disc_amt : float3(0, 0, 0); // fog colour: no stars
        float  moon = smoothstep(0.99955, 0.99975, md) * disc_amt;
        if (moon > 0.0) {
            // Maria: darker patches on the disc.
            float3 off = normalize(dir) - M;
            float  mar = vnoise2(off.xz * 900.0 + 3.0) * 0.6 + vnoise2(off.xy * 2100.0) * 0.4;
            nsky = lerp(nsky, float3(0.95, 0.96, 1.0) * (1.5 - 0.6 * smoothstep(0.45, 0.7, mar)), moon);
        }
        nsky += float3(0.10, 0.13, 0.20) * pow(saturate(md), 400.0) * glow_amt;
        nsky += float3(0.05, 0.06, 0.10) * pow(saturate(md * 0.5 + 0.5), 8.0) * glow_amt;
        sky += nsky * night * smoothstep(0.0, 0.05, M.y + 0.05);
    }

    // Cloud layer, drawn over the disc (sun behind cloud = dimmed). Project
    // the ray onto a flat sky plane; fade out at the horizon (projection
    // blows up) so distant haze stays clean.
    if (clouds && dir.y > 0.02) {
        float2 uv  = dir.xz / (dir.y + 0.15) * CLOUD_SCALE + u_time * CLOUD_DRIFT;
        float  den = smoothstep(CLOUD_COVER, CLOUD_COVER + 0.32, fbm2(uv));
        den *= smoothstep(0.02, 0.18, dir.y);
        // Sunlit tops vs grey-blue undersides by density. Near sunset the
        // clouds catch the light: gold toward the sun, rose away from it.
        float3 glow  = lerp(float3(1.0, 0.55, 0.45), float3(1.15, 0.62, 0.28), side);
        float3 lit   = lerp(float3(1.04, 1.02, 0.98), glow, golden * 0.75);
        float3 shade = lerp(float3(0.62, 0.67, 0.78), float3(0.62, 0.54, 0.58), golden);
        float3 ccol  = lerp(lit, shade, den * 0.7);
        // After dusk: dark silhouettes against the stars, faintly moonlit.
        ccol = lerp(ccol, float3(0.035, 0.045, 0.07), night);
        sky = lerp(sky, ccol, den * 0.9);
    }
    return sky;
}

// Sky as seen directly (miss rays): full sun disc + glow.
float3 sky_color_d(float3 dir, float3 Ln) {
    return sky_color_impl(dir, Ln, 1.0, 1.0, true);
}

// Sky as a FOG color (blended onto hit geometry): the sharp disc would read
// as the sun rendering in front of fogged mountains, so drop it and halve
// the broad glow (forward-scatter halo through haze is plausible; a hard
// circle is not). No clouds either: they are far behind any geometry, and
// fogging toward them painted a faint drifting cloud pattern onto voxels.
float3 sky_color_fog_d(float3 dir, float3 Ln) {
    return sky_color_impl(dir, Ln, 0.0, 0.5, false);
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
// uniform_id: non-zero for a uniform chunk (no brick): every voxel is that
//   block, so the entry voxel is the hit.
HitInfo trace_ray_chunk_voxels(float3 world_origin, float3 local_entry,
                                float3 dir, int3 chunk_ic,
                                int chunk_i, uint uniform_id, float3 entry_normal,
                                uint skip_id) {
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
        if (uniform_id != 0u) hit_block_id = uniform_id;
        else if (voxel_solid(chunk_i, lvi)) hit_block_id = load_voxel(global_chunk_i + lvi);
        if (hit_block_id == skip_id) hit_block_id = 0u;
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
        if (voxel_solid(chunk_i, lvi2)) {
            uint b = load_voxel(global_chunk_i + lvi2);
            if (b != skip_id) hit_block_id = b;
        }
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

// max_len: stop after this distance (the primary view ray stops where the
// near voxel region ends; far_field.hlsl takes over from there).
// skip_id: a block the ray passes through (BLOCK_WATER for rays already
// under water), 0 = none.
HitInfo trace_ray_chunk(float3 origin, float3 dir, bool is_light, int max_iters = RAY_ITERATIONS,
                        float max_len = RAY_MAX_LENGTH, uint skip_id = 0u) {
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
    int    axis = -1;             // axis of the last chunk step (-1: none yet)

    int ring_w = CHUNK_COUNT_WIDTH;

    while (i < max_iters) {
        i++;
        if (t > max_len / float(BRICK_CHUNK_SIZE)) break;

        // Y is not wrapped — hard bounds against the resident world-Y range.
        int ry = y_i - WORLD_CHUNK_Y_MIN;
        if (ry < 0 || ry >= GPU_CHUNKS_HEIGHT) {
            if (is_light) break;
        } else {
            // Wrap X and Z into ring buffer space [0, ring_w).
            int rx = x_i & (ring_w - 1); // ring_w is a power of two
            int rz = z_i & (ring_w - 1); // ring_w is a power of two
            if (chunk_index[REGION_BASE + region_of(rx, ry, rz)] == 0) {
                SKIP_EMPTY_REGION
                continue;
            }
            int slot_i = rx + ry * ring_w + rz * ring_w * GPU_CHUNKS_HEIGHT;
            int ci = chunk_index[slot_i];
            if (ci != -1) {
                // Ghost rejection: the slot's owner must match the world coords we're visiting.
                int2 owner = chunk_owner[slot_i];
                if (owner.x != x_i || owner.y != z_i) ci = -1;
            }
            if (skip_id != 0u && ci == -2 - int(skip_id)) ci = -1;
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
                float3 chunk_entry_normal = float3(0, 0, 0);
                if (axis == 0) chunk_entry_normal.x = -(float)step_x;
                if (axis == 1) chunk_entry_normal.y = -(float)step_y;
                if (axis == 2) chunk_entry_normal.z = -(float)step_z;
                HitInfo vhit = trace_ray_chunk_voxels(entry_pos, local_entry, dir,
                                                      chunk_ic, max(ci, 0),
                                                      ci < -1 ? uint(-ci - 2) : 0u,
                                                      chunk_entry_normal, skip_id);
                if (vhit.block_id != 0u) {
                    hit_block_id = vhit.block_id;
                    t += vhit.t / float(BRICK_CHUNK_SIZE);
                    hit_side = vhit.normal;
                    hit_vkey = vhit.vkey;
                    break;
                }
            }
        }

        CHUNK_DDA_STEP
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
