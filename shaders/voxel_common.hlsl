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
#define GPU_CHUNKS_HEIGHT   80
#define WORLD_CHUNK_Y_MIN  (-16)
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
#define BLOCK_STONE_BRICKS  22u // ruins
#define BLOCK_CRYSTAL       23u // glowing amber crystal
#define BLOCK_KELP          24u // water plants: crossed cutout planes (plant_hit)
#define BLOCK_SEAGRASS      25u
#define BLOCK_CORAL         26u // solid reef block
#define BLOCK_SEA_PICKLE    27u // glowing water plant
#define BLOCK_BIRCH_LOG     28u
#define BLOCK_BIRCH_LEAVES  29u
#define BLOCK_AUTUMN_LEAVES 30u
#define BLOCK_TALL_GRASS    31u // land plants: crossed cutout planes, like the sea's
#define BLOCK_FLOWER        32u
#define BLOCK_FERN          33u
#define BLOCK_DRY_BUSH      34u
#define BLOCK_ACACIA_LOG    35u
#define BLOCK_ACACIA_LEAVES 36u
#define BLOCK_WILLOW_LEAVES 37u
#define BLOCK_DRY_GRASS     38u // savanna ground
#define BLOCK_MUSHROOM      39u // a land plant
#define BLOCK_MOSS          40u // caves
#define BLOCK_DRIPSTONE     41u
#define BLOCK_ROOTS         42u // hanging plant
#define BLOCK_GLOW_MUSHROOM 43u // plant, emissive
#define BLOCK_GLOW_MOSS     44u // emissive
#define BLOCK_DOOR          45u // doors: 48 ids, one per state (door_shape)
#define BLOCK_DOOR_LAST     92u

// World blocks per design block (terrain.odin TERRAIN_SCALE): textures laid
// out over the world in design sizes use it.
#define TERRAIN_SCALE 1.5

#define SEA_LEVEL_Y 24.0 // top of the sea (terrain.odin SEA_LEVEL)

bool block_is_leaves(uint id) { return id == BLOCK_LEAVES || id == BLOCK_SPRUCE_LEAVES || id == BLOCK_BIRCH_LEAVES || id == BLOCK_AUTUMN_LEAVES || id == BLOCK_ACACIA_LEAVES || id == BLOCK_WILLOW_LEAVES; }
bool block_is_land_plant(uint id) { return (id >= BLOCK_TALL_GRASS && id <= BLOCK_DRY_BUSH) || id == BLOCK_MUSHROOM || id == BLOCK_ROOTS || id == BLOCK_GLOW_MUSHROOM; }
bool block_is_water_plant(uint id) { return id == BLOCK_KELP || id == BLOCK_SEAGRASS || id == BLOCK_SEA_PICKLE; }
// Water, or a plant standing in it (the camera is "in water" in either).
bool block_is_watery(uint id) { return id == BLOCK_WATER || block_is_water_plant(id); }
// Drawn as crossed cutout planes (plant_hit).
bool block_is_cutout(uint id) { return block_is_water_plant(id) || block_is_land_plant(id); }
// Small-voxel models (micro_hit): 8^3 cells inside their voxel. Still
// cutouts for everything else (light, shadows, walking through).
bool block_is_micro(uint id) {
    return id == BLOCK_MUSHROOM || id == BLOCK_GLOW_MUSHROOM || id == BLOCK_FLOWER || id == BLOCK_FERN ||
           id == BLOCK_SEA_PICKLE || id == BLOCK_DRY_BUSH;
}
// A thin panel in its voxel (door_hit).
bool block_is_door(uint id) { return id >= BLOCK_DOOR && id <= BLOCK_DOOR_LAST; }
// Not a whole cube: rays test the shape inside the voxel (shaped_hit).
bool block_is_shaped(uint id) { return block_is_cutout(id) || block_is_door(id); }

// Radiance a block's surface emits on its own (0 = not emissive). Added to
// shading UNLIT (not multiplied by lighting/AO). Their light on the world
// comes from block light (light.odin).
// Bright enough to pass BLOOM_THRESHOLD so emissive blocks glow. Future
// emissive blocks (lava, glowstone) slot in here.
float3 block_emission(uint id) {
    if (id == BLOCK_TORCH) return float3(1.0, 0.62, 0.40) * 7.0; // times albedo^2 in shading
    if (id == BLOCK_CRYSTAL) return float3(1.0, 0.85, 0.60) * 5.0;
    if (id == BLOCK_SEA_PICKLE) return float3(0.75, 1.0, 0.55) * 5.0;
    if (id == BLOCK_GLOW_MUSHROOM) return float3(0.45, 0.95, 1.0) * 9.0;
    if (id == BLOCK_GLOW_MOSS) return float3(0.40, 1.0, 0.75) * 6.0;
    return float3(0.0, 0.0, 0.0);
}

#define LEAF_TRANSMIT 0.35
#define PLANT_TRANSMIT 0.7  // a plant voxel crossed, as a whole (the sun's shadow rays)
#define BLADE_TRANSMIT 0.35 // light through a plant's blade where an exact shadow ray meets one


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
// u_sun_true). Sun: orange at the horizon, golden through the afternoon,
// still a warm cream high overhead (white noon light washes the world out).
// Moon: cool silver-blue.
float3 sun_tint_d(float3 Ln) {
    float elev = clamp(Ln.y, 0.0, 1.0);
    float3 c = lerp(float3(1.0, 0.42, 0.10), float3(1.0, 0.85, 0.66), smoothstep(0.0, 0.30, elev));
    c = lerp(c, float3(1.0, 0.92, 0.80), smoothstep(0.45, 0.95, elev));
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

// ---- Water plants -------------------------------------------------------------
// Kelp, seagrass and sea pickles are two crossed vertical planes through the
// voxel's centre (x = z and x + z = 1), each a cutout of PLANT_TEXELS^2
// texels: the ray only stops on an opaque texel, so you see between the
// blades. u runs along the plane (= local x), v up the voxel.
#define PLANT_TEXELS 8 // as the tracer's TEXELS

// Opaque texel of plant `id` at plane texel (cu, cv) of plane `pl`.
bool plant_texel(uint id, int3 vkey, int cu, int cv, int pl) {
    float h = hash31i(vkey * 2 + int3(pl, 0, 0));
    if (id == BLOCK_TALL_GRASS) {
        // Blades of random height, most of them reaching well up.
        float hb = hash31i(int3(vkey.x * 8 + cu, vkey.z * 2 + pl, vkey.y * 7 + 3));
        if (hb > 0.62) return false;
        return float(cv) < 2.0 + hb * 11.0;
    }
    if (id == BLOCK_ROOTS) {
        // Thin strands hanging from the top, of random lengths.
        float hb = hash31i(int3(vkey.x * 8 + cu, vkey.z * 2 + pl, vkey.y * 5 + 1));
        if (hb > 0.45) return false;
        return float(7 - cv) < 2.0 + hb * 14.0;
    }
    if (id == BLOCK_KELP) {
        // A stalk up the middle, and a leaf blade every few texels that
        // grows out to one side, widest at its base.
        if (cu == 3 || cu == 4) return pl == 0;
        int   k    = (cv + int(h * 8.0)) & 3;           // position within a blade
        bool  left = ((cv + int(h * 8.0)) >> 2 & 1) == pl; // blades alternate sides and planes
        int   reach = 3 - k;                            // 3 texels out at the base .. 0 at the tip
        return left ? (cu < 3 && cu >= 3 - reach) : (cu > 4 && cu <= 4 + reach);
    }
    // Seagrass: separate blades of random height, leaning a texel now and then.
    float hb = hash31i(int3(vkey.x * 8 + cu, vkey.z * 2 + pl, vkey.y * 7));
    if (hb > 0.5) return false;
    return float(cv) < 3.0 + hb * 10.0;
}

// Ray against the plant planes of the voxel it spans for s in [0, span]; q0
// is the ray position at s = 0 relative to the voxel's min corner. Returns
// the hit distance along the ray (or -1) and the plane normal facing the ray.
float plant_hit(uint id, int3 vkey, float3 q0, float3 dir, float span, out float3 n) {
    float best = -1.0;
    n = float3(0, 1, 0);
    [unroll]
    for (int pl = 0; pl < 2; pl++) {
        // Plane 0: x - z = 0. Plane 1: x + z - 1 = 0.
        float  dd  = pl == 0 ? dir.x - dir.z : dir.x + dir.z;
        float  d0  = pl == 0 ? q0.x - q0.z : q0.x + q0.z - 1.0;
        if (abs(dd) < 1e-6) continue;
        float  s = -d0 / dd;
        if (s < 0.0 || s > span || (best >= 0.0 && s >= best)) continue;
        float3 q = q0 + dir * s;
        int cu = clamp(int(q.x * PLANT_TEXELS), 0, PLANT_TEXELS - 1);
        int cv = clamp(int(q.y * PLANT_TEXELS), 0, PLANT_TEXELS - 1);
        if (!plant_texel(id, vkey, cu, cv, pl)) continue;
        best = s;
        float3 pn = pl == 0 ? float3(0.7071, 0, -0.7071) : float3(0.7071, 0, 0.7071);
        n = dot(pn, dir) > 0.0 ? -pn : pn;
    }
    return best;
}

// ---- Small-voxel plants ---------------------------------------------------------

// Mushrooms, glow mushrooms, flowers and ferns are models of MICRO^3 cells
// in their voxel, a cell the size of a texel (TEXELS), so they keep the
// world's pixel scale. The shapes are small functions of the model cell;
// each voxel turns and mirrors its model by a hash for variety. A ray
// first meets the model's bounding box (micro_box), then walks the cells
// inside it.
#define MICRO 8

// The model cell for voxel cell c: the voxel's own turn and mirror.
int3 micro_model_cell(int3 vkey, int3 c) {
    uint v = uint(hash31i(vkey + int3(5, 9, 2)) * 8.0);
    if ((v & 1u) != 0u) c.x = MICRO - 1 - c.x;
    if ((v & 2u) != 0u) c.z = MICRO - 1 - c.z;
    if ((v & 4u) != 0u) c.xz = c.zx;
    return c;
}

// The model cell a hit on its face is in (inset so the face floors into it).
int3 micro_hit_cell(int3 vkey, float3 hit_pos, float3 nrm) {
    return micro_model_cell(vkey, clamp(int3(floor((hit_pos - nrm * 0.01 - float3(vkey)) * MICRO)), 0, MICRO - 1));
}

// A glow mushroom's three little ones: x, cap height, z.
static const int3 GLOW_CAPS[3] = { int3(2, 3, 2), int3(5, 2, 3), int3(4, 1, 6) };

// The stem of one of them (pale, not glowing), at model cell c.
bool glow_mushroom_stem(int3 c) {
    [unroll] for (int k = 0; k < 3; k++) {
        if (all(c.xz == GLOW_CAPS[k].xz) && c.y < GLOW_CAPS[k].y) return true;
    }
    return false;
}

// A sea pickle's three capsules: x, z (their 2x2 cells' low corner), height.
static const int3 SEA_PICKLES[3] = { int3(1, 1, 4), int3(4, 2, 3), int3(2, 5, 2) };

// The top of one of them (the brighter, glowing tip), at model cell c.
bool sea_pickle_tip(int3 c) {
    [unroll] for (int k = 0; k < 3; k++) {
        int2 o = c.xz - SEA_PICKLES[k].xy;
        if (all(o >= 0) && all(o <= 1) && c.y == SEA_PICKLES[k].z - 1) return true;
    }
    return false;
}

// The cells the model fills lie in [lo, hi) of its own cells, and in its
// voxel (turned and mirrored as micro_model_cell has it) in the box this
// returns. Rays outside it skip the cell walk; most rays through a flower's
// voxel never come near the bloom.
void micro_box(uint id, int3 vkey, out int3 lo, out int3 hi) {
    if (id == BLOCK_FLOWER)        { lo = int3(2, 0, 2); hi = int3(6, 7, 5); }
    else if (id == BLOCK_MUSHROOM) { lo = int3(1, 0, 1); hi = int3(7, 6, 7); }
    else if (id == BLOCK_GLOW_MUSHROOM) { lo = int3(1, 0, 1); hi = int3(7, 5, 8); }
    else if (id == BLOCK_SEA_PICKLE)    { lo = int3(1, 0, 1); hi = int3(6, 4, 7); }
    else if (id == BLOCK_DRY_BUSH)      { lo = int3(0, 0, 0); hi = int3(8, 6, 8); }
    else                           { lo = int3(0, 0, 0); hi = int3(8, 4, 8); } // fern
    // Model to voxel: micro_model_cell's steps undone, last first.
    uint v = uint(hash31i(vkey + int3(5, 9, 2)) * 8.0);
    if ((v & 4u) != 0u) { lo.xz = lo.zx; hi.xz = hi.zx; }
    if ((v & 2u) != 0u) { int l = lo.z; lo.z = MICRO - hi.z; hi.z = MICRO - l; }
    if ((v & 1u) != 0u) { int l = lo.x; lo.x = MICRO - hi.x; hi.x = MICRO - l; }
}

// Whether model cell c of plant `id` is filled.
bool micro_cell(uint id, int3 c) {
    float2 d  = float2(c.xz) - 3.5;
    float  r2 = dot(d, d);
    if (id == BLOCK_MUSHROOM) {
        // A thick stem under a domed cap.
        if (c.y <= 2) return abs(d.x) < 1.0 && abs(d.y) < 1.0;
        if (c.y == 3) return r2 <= 8.5;
        if (c.y == 4) return r2 <= 6.5;
        return c.y == 5 && r2 <= 2.5;
    }
    if (id == BLOCK_GLOW_MUSHROOM) {
        // Three little ones of different heights: a thin stem, a cap of a
        // cross with a knob on top.
        [unroll] for (int k = 0; k < 3; k++) {
            int2 o = c.xz - GLOW_CAPS[k].xz;
            int  h = GLOW_CAPS[k].y;
            if (all(o == 0) && c.y <= h + 1) return true;
            if (c.y == h && abs(o.x) + abs(o.y) == 1) return true;
        }
        return false;
    }
    if (id == BLOCK_FLOWER) {
        // A stem with a leaf, and the bloom: a cross of petals, the eye on top.
        int2 o = c.xz - int2(3, 3);
        if (c.y <= 4) return all(o == 0) || (c.y == 2 && o.x == 1 && o.y == 0) || (c.y == 3 && o.x == 2 && o.y == 0);
        if (c.y == 5) return abs(o.x) + abs(o.y) <= 1;
        return c.y == 6 && all(o == 0);
    }
    if (id == BLOCK_SEA_PICKLE) {
        // Three capsules of 2x2 cells, short and shorter.
        [unroll] for (int k = 0; k < 3; k++) {
            int2 o = c.xz - SEA_PICKLES[k].xy;
            if (all(o >= 0) && all(o <= 1) && c.y < SEA_PICKLES[k].z) return true;
        }
        return false;
    }
    if (id == BLOCK_DRY_BUSH) {
        // Bare twigs from one stub, climbing out diagonally (two cells a step,
        // so they read as lines), of different lengths, one forking.
        int2 o = c.xz - int2(3, 3);
        if (all(o == 0)) return c.y <= 1;
        static const int3 twigs[4] = { int3(1, 1, 4), int3(-1, -1, 3), int3(1, -1, 3), int3(-1, 1, 2) }; // dx, dz, length
        [unroll] for (int k = 0; k < 4; k++) {
            int i = o.x * twigs[k].x; // steps out along it
            if (i < 1 || i > twigs[k].z || o.y != i * twigs[k].y) continue;
            if (c.y == i + 1 || c.y == i) return true;
        }
        // The fork: off the long twig, straight up from its second step.
        return all(o == int2(2, 2)) && c.y >= 3 && c.y <= 5;
    }
    // Fern: a tuft, and four fronds arching out (a pinwheel), each with a
    // leaflet beside it halfway.
    if (c.y <= 1) return abs(d.x) < 1.0 && abs(d.y) < 1.0;
    static const int2 dirs[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    static const int2 lanes[4] = { int2(0, 4), int2(0, 3), int2(3, 0), int2(4, 0) }; // the cell row each runs along
    [unroll] for (int k = 0; k < 4; k++) {
        int2 dir = dirs[k];
        int  along = dir.x != 0 ? c.x : c.z;
        int  across = dir.x != 0 ? c.z : c.x;
        int  lane = dir.x != 0 ? lanes[k].y : lanes[k].x;
        int  s = dir.x + dir.y > 0 ? along - 4 : 3 - along; // 1.. out from the tuft
        if (s < 1 || s > 3) continue;
        int  h = s == 2 ? 3 : 2; // up, then drooping
        if (c.y == h && across == lane) return true;
        if (s == 2 && c.y == 2 && abs(across - lane) == 1) return true;
    }
    return false;
}

// Ray against the model in the voxel it spans for s in [0, span]; q0 is
// the ray position at s = 0 relative to the voxel's min corner. Returns the
// hit distance (or -1) and the face normal of the cell it met.
float micro_hit(uint id, int3 vkey, float3 q0, float3 dir, float span, out float3 n) {
    n = float3(0, 1, 0);
    int3 clo, chi;
    micro_box(id, vkey, clo, chi);
    float3 lo  = float3(clo) / float(MICRO), hi = float3(chi) / float(MICRO);
    float3 inv = 1.0 / dir;
    float3 a = (lo - q0) * inv, b = (hi - q0) * inv;
    float3 tn = min(a, b), tf = max(a, b);
    float  t0 = max(max(tn.x, tn.y), max(tn.z, 0.0));
    float  t1 = min(min(tf.x, tf.y), min(tf.z, span));
    if (t0 > t1) return -1.0;
    if (tn.x >= tn.y && tn.x >= tn.z) n = float3(-sign(dir.x), 0, 0);
    else if (tn.y >= tn.z)            n = float3(0, -sign(dir.y), 0);
    else                              n = float3(0, 0, -sign(dir.z));

    // Cell walk, in cell units, from where the ray enters the box.
    float3 p    = (q0 + dir * t0) * float(MICRO);
    int3   cell = clamp(int3(floor(p)), clo, chi - 1);
    int3   stp  = int3(sign(dir));
    float3 dt   = abs(inv) / float(MICRO);
    float3 tm   = t0 + ((float3(cell) + float3(stp > 0)) - p) * inv / float(MICRO);
    [loop] for (int i = 0; i < 3 * MICRO; i++) {
        if (micro_cell(id, micro_model_cell(vkey, cell))) return t0;
        if (tm.x < tm.y && tm.x < tm.z) { t0 = tm.x; tm.x += dt.x; cell.x += stp.x; n = float3(-stp.x, 0, 0); }
        else if (tm.y < tm.z)           { t0 = tm.y; tm.y += dt.y; cell.y += stp.y; n = float3(0, -stp.y, 0); }
        else                            { t0 = tm.z; tm.z += dt.z; cell.z += stp.z; n = float3(0, 0, -stp.z); }
        if (t0 > t1 || any(cell < clo) || any(cell >= chi)) break;
    }
    return -1.0;
}

// ---- Doors ----------------------------------------------------------------------
// As door.odin: id = BLOCK_DOOR + ((facing * 2 + hinge_right) * 2 + open) *
// DOOR_PARTS + part. facing (0 -z, 1 +x, 2 +z, 3 -x) is the way the placer
// looked: closed, the panel lies against the side toward them; open, against
// the hinge side. A panel is 8 texels across (u, from the hinge) and 8 a
// part up the whole door (v), with two window panes up top that rays pass
// through.
#define DOOR_THICK 0.1875 // 3/16 of a block
#define DOOR_PARTS 3u     // blocks tall

struct DoorShape {
    float3 lo, hi;  // the panel's box in its voxel, 0..1
    float2 hinge;   // the hinge corner (x, z)
    bool   along_x; // the panel runs along x (else z)
    uint   part;    // 0 at the bottom
};

DoorShape door_shape(uint id) {
    uint   k = id - BLOCK_DOOR;
    uint   st = k / DOOR_PARTS;
    uint   f = st >> 2;
    float2 d = f == 0u ? float2(0, -1) : f == 1u ? float2(1, 0) : f == 2u ? float2(0, 1) : float2(-1, 0);
    float2 r = float2(-d.y, d.x); // right of the facing
    float2 hv = (st & 2u) != 0u ? r : -r;
    float2 s = (st & 1u) != 0u ? hv : -d; // the side the panel lies against
    DoorShape ds;
    ds.lo = float3(s.x > 0.5 ? 1.0 - DOOR_THICK : 0.0, 0.0, s.y > 0.5 ? 1.0 - DOOR_THICK : 0.0);
    ds.hi = float3(s.x < -0.5 ? DOOR_THICK : 1.0, 1.0, s.y < -0.5 ? DOOR_THICK : 1.0);
    ds.hinge = 0.5 + 0.5 * (hv - d);
    ds.along_x = abs(s.y) > 0.5;
    ds.part = k % DOOR_PARTS;
    return ds;
}

// Panel texel (u 0..7 from the hinge, v 0..23 up the door) at local point q.
int2 door_texel(DoorShape ds, float3 q) {
    float u = ds.along_x ? abs(q.x - ds.hinge.x) : abs(q.z - ds.hinge.y);
    return int2(clamp(int(u * 8.0), 0, 7), clamp(int((q.y + float(ds.part)) * 8.0), 0, int(DOOR_PARTS) * 8 - 1));
}

bool door_window(int2 c) { return c.y >= 15 && c.y <= 20 && c.x != 0 && c.x != 3 && c.x != 4 && c.x != 7; }

// Ray against the panel of the door voxel it spans for s in [0, span]; q0
// is the ray position at s = 0 relative to the voxel's min corner. Returns
// the hit distance (or -1: missed, or in through a window) and the normal
// of the face it entered.
float door_hit(uint id, float3 q0, float3 dir, float span, out float3 n) {
    DoorShape ds = door_shape(id);
    float3 inv = 1.0 / dir;
    float3 a = (ds.lo - q0) * inv, b = (ds.hi - q0) * inv;
    float3 tn = min(a, b), tf = max(a, b);
    float  t0 = max(max(tn.x, tn.y), max(tn.z, 0.0));
    float  t1 = min(min(tf.x, tf.y), min(tf.z, span));
    if (tn.x >= tn.y && tn.x >= tn.z) n = float3(-sign(dir.x), 0, 0);
    else if (tn.y >= tn.z)            n = float3(0, -sign(dir.y), 0);
    else                              n = float3(0, 0, -sign(dir.z));
    if (t0 > t1) return -1.0;
    if (door_window(door_texel(ds, q0 + dir * t0))) return -1.0;
    return t0;
}

// A shaped block's surface along the ray (plants, doors), as plant_hit.
float shaped_hit(uint id, int3 vkey, float3 q0, float3 dir, float span, out float3 n) {
    if (block_is_door(id)) return door_hit(id, q0, dir, span, n);
    if (block_is_micro(id)) return micro_hit(id, vkey, q0, dir, span, n);
    return plant_hit(id, vkey, q0, dir, span, n);
}

// Per-voxel shadow walk through one occupied chunk. local_entry is the ray
// entry pos in voxel units within the chunk, [0,8) per axis; chunk_ic its
// exact integer chunk coords (plants' shapes vary by voxel). Returns the
// transmittance factor for this chunk (0 = fully blocked, leaves attenuate
// by LEAF_TRANSMIT per voxel crossed). A door shades only where the ray
// meets its panel. Plants dim by PLANT_TRANSMIT per voxel crossed, unless
// `exact_plants`: then only where the ray meets their actual shape. The
// sun's rays are cheap that way, and from far off its whole-voxel shading
// evens out; a light close by (the held torch) would cast block-shaped
// shadows from them. max_len (voxel units from entry)
// stops the walk at a point-light's position — without it the walk overruns
// the chunk-level max_t check and reports occlusion from the light's own
// voxel or geometry behind it (chunk-alignment-dependent "lights only one
// direction" bug). Emissive voxels never occlude: they ARE the light, and
// stacked torches must not shadow each other.
float shadow_chunk_transmit(int chunk_i, int3 chunk_ic, float3 local_entry, float3 dir, float max_len, bool exact_plants) {
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
    float t_enter = 0.0;

    // Entry voxel first, then step-and-test (each voxel tested exactly once:
    // the step that exits this chunk lands on the next chunk's entry voxel).
    for (int i = 0; i <= 23; i++) {
        if (i > 0) {
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
            if ((block_emission(bid).x > 0.0 && bid != BLOCK_GLOW_MOSS) || bid == BLOCK_WATER) {
                // emissive / water: transparent to shadow rays (water
                // darkens what's under it through absorption instead)
            } else if (block_is_leaves(bid)) {
                factor *= LEAF_TRANSMIT;
                if (factor < 0.01) return 0.0;
            } else if (block_is_cutout(bid) && !exact_plants) {
                factor *= PLANT_TRANSMIT;
            } else if (block_is_shaped(bid)) {
                // Only its shape shades: a door's panel (not its windows),
                // a mushroom's cells, blades (a little light through them).
                float3 sn;
                float  span = min(t_max_x, min(t_max_y, t_max_z)) - t_enter;
                float3 q = local_entry + dir * t_enter - float3(x_i, y_i, z_i);
                // (Doors alone when not exact: the compiler then leaves the
                // plants' shape code out of the sun's shadow rays.)
                float  s = exact_plants ? shaped_hit(bid, chunk_ic * BRICK_CHUNK_SIZE + int3(x_i, y_i, z_i), q, dir, span, sn)
                                        : door_hit(bid, q, dir, span, sn);
                if (s >= 0.0) {
                    if (!block_is_cutout(bid) || block_is_micro(bid)) return 0.0;
                    factor *= BLADE_TRANSMIT;
                    if (factor < 0.01) return 0.0;
                }
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
float trace_shadow_transmittance(float3 origin, float3 dir, float max_t = RAY_MAX_LENGTH, bool exact_plants = false) {
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
                transmittance *= shadow_chunk_transmit(ci, chunk_ic, local_entry, dir,
                                                       max_t - t * float(BRICK_CHUNK_SIZE), exact_plants);
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
        if (block_is_shaped(hit_block_id)) {
            float3 pn;
            float  s = shaped_hit(hit_block_id, chunk_ic * BRICK_CHUNK_SIZE + int3(x_i, y_i, z_i),
                                 local_entry - float3(x_i, y_i, z_i), dir,
                                 min(t_max_x, min(t_max_y, t_max_z)), pn);
            if (s < 0.0) hit_block_id = 0u;
            else { t = s; hit_side = pn; }
        }
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
            if (block_is_shaped(b)) {
                float3 pn;
                float  s = shaped_hit(b, chunk_ic * BRICK_CHUNK_SIZE + int3(x_i, y_i, z_i),
                                     local_entry + dir * t - float3(x_i, y_i, z_i), dir,
                                     min(t_max_x, min(t_max_y, t_max_z)) - t, pn);
                if (s >= 0.0) { hit_block_id = b; t += s; hit_side = pn; }
            } else if (b != skip_id) hit_block_id = b;
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
// A u16 per voxel: block light tint << 12 | sky light (0..SKY_LIGHT_MAX)
// << 5 | block light (0..BLOCK_LIGHT_MAX), as light.odin packs it.
#ifdef HAS_VOXEL_LIGHT

#define SKY_LIGHT_MAX   31.0 // light.odin LIGHT_MAX
#define LIGHT_SKY_FULL  (31u << 5)
#define BLOCK_LIGHT_MAX 24.0 // light.odin

uint light_sky(uint l)   { return (l >> 5) & 31u; }
uint light_block(uint l) { return l & 31u; }
uint light_tint(uint l)  { return l >> 12; }

#define TORCH_LIGHT_COLOR float3(1.6, 0.95, 0.45) // block light at BLOCK_LIGHT_MAX

// Colour of block light by tint (Light_Tint in light.odin), at about the
// torch's brightness so a glow's level alone sets how bright it is.
float3 light_tint_color(uint tint) {
    if (tint == 1u) return float3(1.45, 1.10, 0.65); // crystal: pale amber
    if (tint == 2u) return float3(0.95, 1.35, 0.60); // sea pickle: lime
    if (tint == 3u) return float3(0.50, 1.10, 1.50); // glow mushroom: cyan
    if (tint == 4u) return float3(0.45, 1.35, 0.95); // glow moss: teal
    return TORCH_LIGHT_COLOR;
}

// Torch light wavers: slow value noise over space and time, so nearby
// voxels (lit by the same torch) brighten and dim together. p: world pos.
float torch_flicker(float3 p) {
    float n = vnoise3(p * 0.12 + float3(0.0, u_time * 3.1, 0.0)) * 0.65
            + vnoise3(p * 0.21 + float3(u_time * 7.3, 0.0, 0.0)) * 0.35;
    return 0.86 + 0.24 * n;
}

// Light value of world voxel v. Outside the resident world reads as open sky,
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
    return (light_pool[idx >> 1] >> ((uint(idx) & 1u) * 16u)) & 0xFFFFu;
}

// Sky light level (0..SKY_LIGHT_MAX) to brightness: a level is lost each
// voxel, so per metre (TERRAIN_SCALE voxels) it dims ~12%, gentler than
// Minecraft's 20% a block, so light reaching in under overhangs and down
// cave mouths stays visible a good way in. It eases out over the last ten
// levels (~7 m): dropping from a dim glow straight to black where the light
// runs out draws hard, blocky edges, and a tunnel seems to end in a wall
// of dark.
float light_curve(float level) {
    if (level <= 0.0) return 0.0;
    return pow(0.88, (SKY_LIGHT_MAX - level) / TERRAIN_SCALE) * smoothstep(0.0, 10.0, level);
}

// Block light (torches, glows) by level: it loses a level a block, so with
// blocks of 2/3 m (TERRAIN_SCALE) the falloff is per metre, ~15% dimmer
// each (a little gentler than Minecraft's 20%, so a torch fills more of a
// cave), easing out over the last few levels instead of stopping at a hard
// edge. Full brightness at the source is unchanged.
float block_light_curve(float level) {
    if (level <= 0.0) return 0.0;
    return pow(0.85, (BLOCK_LIGHT_MAX - level) / TERRAIN_SCALE) * smoothstep(0.0, 7.0, level);
}

// The block light of light value l, as colour; flicker: torch_flicker
// where it lands (only torch light wavers).
float3 block_radiance(uint l, float flicker) {
    uint level = light_block(l);
    if (level == 0u) return 0.0;
    uint tint = light_tint(l);
    float3 c = light_tint_color(tint) * block_light_curve(float(level));
    return tint == 0u ? c * flicker : c;
}

// Smooth light at hit_pos on the face of voxel vkey with normal nrm:
// returns the sky light level, and block light (coloured, flickering) in
// `block`. Bilinear over the four voxels in front of the face nearest the
// point; block light is blended as colour, so tints meet in a gradient.
// Unlit samples (solid blocks) are left out so a wall beside the face
// doesn't darken it (AO does contact shadow), and the diagonal is skipped
// when both edge samples are blocked so light can't leak around a corner.
float face_light(int3 vkey, float3 nrm, float3 hit_pos, out float3 block) {
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
    float fl = torch_flicker(hit_pos);
    block = (w.x * block_radiance(l00, fl) + w.y * block_radiance(l10, fl)
           + w.z * block_radiance(l01, fl) + w.w * block_radiance(l11, fl)) * inv;
    return dot(w, float4((l >> 5) & 31u)) * inv;
}

#endif // HAS_VOXEL_LIGHT

#endif // VOXEL_COMMON_HLSL
