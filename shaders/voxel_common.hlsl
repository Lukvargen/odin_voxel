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

#define LEAF_TRANSMIT 0.35

#define GI_DIRS 128
#define PI      3.14159265359

// i-th cosine-weighted hemisphere direction around +Y (Fibonacci spiral).
// Transform to world space via TBN: dir.x*T + dir.y*N + dir.z*B
float3 fibonacci_hemisphere(uint i, uint N) {
    float phi       = 2.0 * PI * frac(float(i) * 0.6180339887);
    float cos_theta = 1.0 - (float(i) + 0.5) / float(N);
    float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
    return float3(cos(phi) * sin_theta, cos_theta, sin(phi) * sin_theta);
}

void build_tbn(float3 N, out float3 T, out float3 B) {
    float3 up = abs(N.y) < 0.9 ? float3(0,1,0) : float3(1,0,0);
    T = normalize(cross(up, N));
    B = cross(N, T);
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

// Walks toward the light accumulating transmittance. Leaves attenuate by
// LEAF_TRANSMIT per voxel; any other solid = fully occluded.
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

#endif // VOXEL_COMMON_HLSL
