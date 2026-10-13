// Voxel raytracer compute shader.
// Two-level DDA traversal lives in voxel_common.hlsl; this pass does primary
// rays + shading. Ambient sky light and torch light come from the per-voxel
// light the CPU flood-fills (light.odin); the only lighting ray is the sun
// shadow ray.

// ---- Bindings ---------------------------------------------------------------
// SPIR-V/SDL3 space0 order: RO storage bufs (t0..t7): voxel data, voxel
// light, entities, far terrain. SDL allows at most 8 (see gpu.odin).
// RW textures (set 1): img_output (u0), depth_output (u1).
// Shared constants/functions come from voxel_common.hlsl AFTER these decls.
StructuredBuffer<uint>     voxel_chunk      : register(t0, space0);
StructuredBuffer<int>      chunk_index      : register(t1, space0);
StructuredBuffer<int2>     chunk_owner      : register(t2, space0);
StructuredBuffer<uint>     voxel_mask       : register(t3, space0);
StructuredBuffer<int>      light_index      : register(t4, space0); // per slot: light pool id, or -1-light if uniform
StructuredBuffer<uint>     light_pool       : register(t5, space0); // 512 light bytes per brick
StructuredBuffer<float4>   sdf_entities     : register(t6, space0); // ENTITY_STRIDE float4s/entity (entities.odin)
StructuredBuffer<uint>     far_data         : register(t7, space0); // far terrain tile table, then cells (far.odin)

RWTexture2D<float4>        img_output        : register(u0, space1);
RWTexture2D<float>         depth_output      : register(u1, space1); // primary-hit dist, 1e30 = sky

#include "camera_uniforms.hlsl"

#define HAS_VOXEL_LIGHT
#define HAS_SDF_ENTITIES
#include "entity_sdf.hlsl"
#include "voxel_common.hlsl"
#include "far_field.hlsl"

// ---- Helpers ----------------------------------------------------------------

static float3 light_dir_normalized;

// Sun elevation in [0,1]: 0 = horizon, 1 = overhead.
// Used to tint sky/fog warm at low angles (sunrise/sunset).
float sun_elevation() {
    return clamp(light_dir_normalized.y, 0.0, 1.0);
}

float3 sun_tint() {
    return sun_tint_d(light_dir_normalized);
}

float4 sky_color(float3 dir) {
    return float4(sky_color_d(dir, light_dir_normalized), 1.0);
}

// Spatial fog: three transmittance terms composed multiplicatively.
//  1) distance haze (squared-exponential, tunable via u_fog_density)
//  2) exponential HEIGHT fog — density falls off with altitude, integrated in
//     closed form along the ray → valleys collect haze, peaks stay clear
//  3) cave fog — short-range murk that scales with u_cave_factor so caves
//     feel enclosed; tinted near-black blue instead of sky color
#define FOG_BASE_Y         10.0   // terrain minimum — height-fog reference plane
#define FOG_FALLOFF        40.0   // height-fog density e-fold distance (voxels)
#define FOG_HEIGHT_DENSITY 0.004  // height-fog density at FOG_BASE_Y
#define CAVE_FOG_DENSITY   0.025  // cave murk density at cave_factor = 1

float4 apply_fog(float4 color, float dist, float3 ray_dir) {
    float3 rd = normalize(ray_dir);

    // 1) Distance haze
    float t_dist = clamp(exp(-pow(dist * u_fog_density, 2.0)), 0.0, 1.0);

    // 2) Height fog: rho(y) = H * exp(-(y - BASE)/FALLOFF); optical depth along
    // the ray has a closed form (guard near-horizontal rays).
    float k  = 1.0 / FOG_FALLOFF;
    float r0 = FOG_HEIGHT_DENSITY * exp(-(u_cam_pos.y - FOG_BASE_Y) * k);
    float od = (abs(rd.y) > 1e-3)
             ? r0 * (1.0 - exp(-dist * rd.y * k)) / (rd.y * k)
             : r0 * dist;
    float t_height = exp(-max(od, 0.0));

    // 3) Cave murk
    float t_cave = exp(-dist * CAVE_FOG_DENSITY * u_cave_factor);

    // Fog color: horizon sky tint (sun-warmed, disc-free — the disc would
    // draw the sun on top of fogged geometry) above ground, near-black blue
    // underground.
    float4 fog_color = float4(sky_color_fog_d(rd, light_dir_normalized), 1.0);
    float sun_dot = dot(rd, light_dir_normalized);
    fog_color.rgb = lerp(fog_color.rgb, fog_color.rgb * sun_tint(), smoothstep(0.5, 1.0, sun_dot) * 0.5);
    fog_color.rgb = lerp(fog_color.rgb, float3(0.010, 0.014, 0.022), u_cave_factor);

    float transmit = t_dist * t_height * t_cave;
    return lerp(fog_color, color, transmit);
}

// ---- Light colors -------------------------------------------------------------

// Ambient light from the open sky at full sky light: cool blue by day, warm
// and dim with the sun at the horizon.
float3 sky_ambient() {
    return lerp(float3(0.22, 0.16, 0.13), float3(0.42, 0.50, 0.64),
                smoothstep(0.0, 0.4, sun_elevation()));
}

#define TORCH_LIGHT_COLOR float3(1.6, 0.95, 0.45) // block light at level 15
#define MIN_AMBIENT       0.015                   // so pitch-black caves keep a hint of shape

// Fixed per-face dimming of the sky/torch light (as in Minecraft): tops get
// it all, sides less, undersides least, so blocks keep their shape where the
// sun doesn't reach.
float face_shade(float3 n) {
    if (n.y > 0.5)  return 1.0;
    if (n.y < -0.5) return 0.5;
    return abs(n.x) > 0.5 ? 0.8 : 0.65;
}

// Tone mapping lives in composite.hlsl — the LAST pass — so the volumetric
// inscatter is added in linear HDR and rolls off instead of clipping.

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

// Water doesn't darken the corners it fills.
bool ao_occludes(float3 p) {
    uint v = sample_voxel(p);
    return v != 0u && v != BLOCK_WATER;
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
    bool pT = ao_occludes(p + tangent)            ;
    bool nT = ao_occludes(p - tangent)            ;
    bool pB = ao_occludes(p + bitang)             ;
    bool nB = ao_occludes(p - bitang)             ;
    bool pp = ao_occludes(p + tangent + bitang)   ;
    bool pn = ao_occludes(p + tangent - bitang)   ;
    bool np = ao_occludes(p - tangent + bitang)   ;
    bool nn = ao_occludes(p - tangent - bitang)   ;

    // AO at the 4 face corners (fu,fv ∈ {0,1}) from their 3 touching cells.
    float a00 = corner_ao(nT, nB, nn);   // (-t,-b)
    float a10 = corner_ao(pT, nB, pn);   // (+t,-b)
    float a01 = corner_ao(nT, pB, np);   // (-t,+b)
    float a11 = corner_ao(pT, pB, pp);   // (+t,+b)

    // Bilinear interpolate across the face → continuous, no mid-face step.
    float ao = lerp(lerp(a00, a10, fu), lerp(a01, a11, fu), fv);

    // Max darkening strength (subtle). 0.35 was near-invisible, 0.65 a bit
    // strong; 0.45 = present but understated soft corner shading.
    return 1.0 - (1.0 - ao) * 0.45;
}

// ---- Procedural voxel texturing ----------------------------------------------
// Every face gets a TEXELS×TEXELS texel grid keyed on EXACT integer texel
// coords (vkey*TEXELS + sub-voxel texel) — hash-based "texture without
// textures", pixel-crisp (quantized, not smooth) and stable at any distance.
// Material variety lives at three frequencies: per-texel grain (high),
// small per-voxel luminance (mid), and an fbm meadow tint (low) so grass
// varies over tens of voxels instead of checkerboarding per voxel.
#define TEXELS 8

float3 voxel_surface_color(uint block_id, int3 vkey, float3 hit_pos, float3 nrm) {
    // Sub-voxel texel coords: inset along the normal so the face plane floors
    // into THIS voxel, then quantize (frac convention per AO/grass band).
    float3 fr   = frac(hit_pos - nrm * 0.01);
    int3   txl  = clamp(int3(fr * TEXELS), 0, TEXELS - 1);
    int3   tkey = vkey * TEXELS + txl;

    float  h  = hash31i(tkey);          // per-texel value
    float3 h3 = hash33i(tkey) - 0.5;    // per-texel hue offset
    float  vj = hash31i(vkey) - 0.5;    // small per-voxel luminance variety

    if (block_id == BLOCK_GRASS || block_id == BLOCK_SNOW) {
        // Meadow tint: deep green <-> warm yellow-green over ~75 voxels.
        // Snow uses the same top-and-ragged-band layout over dirt.
        float  m     = fbm2(float2(vkey.xz) * 0.013);
        float3 grass = block_id == BLOCK_SNOW
            ? float3(0.86, 0.89, 0.95) * (1.0 + 0.04 * m)
            : lerp(float3(0.13, 0.40, 0.10), float3(0.28, 0.42, 0.14), m);
        float3 dirt  = float3(0.40, 0.27, 0.13);

        bool on_grass;
        if (nrm.y > 0.5) {
            on_grass = true;
        } else if (nrm.y < -0.5) {
            on_grass = false;
        } else {
            // Side: ragged HARD-EDGED grass band (no fade) — depth varies per
            // texel column, only where the voxel above is open air.
            bool exposed = (sample_voxel(float3(vkey) + float3(0.5, 1.5, 0.5)) == 0u);
            int band = 0;
            if (exposed) {
                float ch = hash31i(int3(tkey.x, 4242, tkey.z)); // per texel column
                band = 2 + int(ch * 3.0);                       // 2..4 texels deep
            }
            on_grass = (txl.y >= TEXELS - band);
        }

        float grain = block_id == BLOCK_SNOW ? 0.10 : 0.28;
        float3 c = on_grass
            ? grass * (1.0 - grain * 0.57 + grain * h) + h3 * float3(0.02, 0.05, 0.02) * grain * 3.6
            : dirt  * (0.80 + 0.34 * h) + h3 * float3(0.05, 0.03, 0.02);
        return saturate(c * (1.0 + vj * 0.08));
    }

    if (block_id == BLOCK_LOG || block_id == BLOCK_SPRUCE_LOG) {
        bool spruce = block_id == BLOCK_SPRUCE_LOG;
        float3 c;
        if (abs(nrm.y) > 0.5) {
            // Cut end: lighter heartwood.
            c = (spruce ? float3(0.46, 0.34, 0.20) : float3(0.52, 0.40, 0.22)) * (0.85 + 0.25 * h);
        } else {
            // Bark: vertical striping — column brightness keyed on horizontal
            // texel coords only, so stripes run continuously up the trunk.
            float col = hash31i(int3(tkey.x, 1717, tkey.z));
            c = (spruce ? float3(0.24, 0.15, 0.08) : float3(0.36, 0.23, 0.10))
              * (0.62 + 0.55 * col) * (0.90 + 0.20 * h);
        }
        return saturate(c * (1.0 + vj * 0.08));
    }

    if (block_is_leaves(block_id)) {
        // Two-tone dapple + stronger per-voxel variety for canopy depth.
        float3 c = block_id == BLOCK_SPRUCE_LEAVES
            ? ((h < 0.45) ? float3(0.05, 0.17, 0.08) : float3(0.09, 0.25, 0.12))
            : ((h < 0.45) ? float3(0.10, 0.32, 0.07) : float3(0.17, 0.44, 0.11));
        c *= 0.90 + 0.20 * hash31i(tkey + 31);
        return saturate(c * (1.0 + vj * 0.20));
    }

    if (block_id == BLOCK_DIRT) {
        float3 c = float3(0.40, 0.27, 0.13) * (0.80 + 0.34 * h) + h3 * float3(0.05, 0.03, 0.02);
        return saturate(c * (1.0 + vj * 0.08));
    }

    if (block_id == BLOCK_SAND || block_id == BLOCK_RED_SAND) {
        float3 base = block_id == BLOCK_SAND ? float3(0.72, 0.63, 0.43) : float3(0.66, 0.33, 0.16);
        float3 c = base * (0.88 + 0.18 * h) + h3 * 0.03;
        return saturate(c * (1.0 + vj * 0.05));
    }

    if (block_id == BLOCK_SANDSTONE) {
        // Horizontal strata: brightness per texel row.
        float layer = hash31i(int3(0, tkey.y, 77));
        float3 c = float3(0.78, 0.67, 0.45) * (abs(nrm.y) > 0.5 ? 0.95 : 0.86 + 0.16 * layer) * (0.94 + 0.10 * h);
        return saturate(c * (1.0 + vj * 0.05));
    }

    if (block_id == BLOCK_TERRACOTTA) {
        // Badlands strata: one colour per 2-voxel band of world height.
        static const float3 bands[6] = {
            float3(0.62, 0.33, 0.18), float3(0.76, 0.54, 0.34), float3(0.55, 0.23, 0.15),
            float3(0.84, 0.73, 0.58), float3(0.68, 0.43, 0.20), float3(0.47, 0.29, 0.22),
        };
        uint bi = min(uint(hash31i(int3(7, vkey.y >> 1, 3)) * 6.0), 5u);
        float3 c = bands[bi] * (0.92 + 0.12 * h);
        return saturate(c * (1.0 + vj * 0.05));
    }

    if (block_id == BLOCK_GRAVEL) {
        // Pebbles: 2x2-texel stones of mixed tone, dark gaps.
        float  pb = hash31i(tkey >> 1);
        float3 c = lerp(float3(0.40, 0.38, 0.36), float3(0.60, 0.57, 0.52), pb);
        if (h < 0.18) c *= 0.65;
        return saturate(c * (1.0 + vj * 0.06));
    }

    if (block_id == BLOCK_ICE) {
        float3 c = float3(0.46, 0.62, 0.80) * (0.94 + 0.08 * h);
        if (hash31i(tkey + 5) < 0.05) c = float3(0.75, 0.85, 0.95); // frost cracks
        return saturate(c);
    }

    if (block_id == BLOCK_CACTUS) {
        // Vertical ribs on the sides, lighter crown on top.
        float3 c = float3(0.22, 0.47, 0.15) * (0.88 + 0.18 * h);
        if (abs(nrm.y) < 0.5) {
            int along = abs(nrm.x) > 0.5 ? txl.z : txl.x;
            if (along % 3 == 0) c *= 0.72;
        } else {
            c *= 1.12;
        }
        return saturate(c * (1.0 + vj * 0.05));
    }

    if (block_id == BLOCK_WATER) {
        return float3(0.10, 0.28, 0.36);
    }

    if (block_id == BLOCK_TORCH) {
        // Charred wood body with bright ember texels. The emission term is
        // added unlit in shading, so the albedo stays modest.
        float3 c = (h > 0.62) ? float3(1.0, 0.62, 0.25)
                              : float3(0.45, 0.26, 0.10) * (0.80 + 0.30 * h);
        return saturate(c * (1.0 + vj * 0.08));
    }

    // Stone: gray grain with scattered darker pits. Ores add 2x2-texel
    // specks of their mineral.
    float3 c = float3(0.55, 0.55, 0.56) * (0.82 + 0.30 * h) + h3 * 0.04;
    if (h < 0.07) c *= 0.78;
    if (block_id == BLOCK_COAL_ORE || block_id == BLOCK_IRON_ORE || block_id == BLOCK_GOLD_ORE) {
        if (hash31i((tkey >> 1) + 101) < 0.3) {
            float3 m = block_id == BLOCK_COAL_ORE ? float3(0.07, 0.07, 0.08)
                     : block_id == BLOCK_IRON_ORE ? float3(0.80, 0.58, 0.42)
                     :                              float3(0.98, 0.80, 0.22);
            c = m * (0.85 + 0.3 * h);
        }
    }
    return saturate(c * (1.0 + vj * 0.10));
}

// ---- Main -------------------------------------------------------------------

#define AA_SAMPLES 4

// Sub-pixel offsets (in pixel units). Sample 0 is the pixel CENTER so it can
// share the primary trace already done in main() for depth (see use_hit0).
static const float2 aa_offsets[4] = {
    float2( 0.0,    0.0  ),
    float2( 0.125, -0.375),
    float2( 0.375,  0.125),
    float2(-0.125,  0.375),
};

// Shading for an SDF entity hit: direct sun (with entity occlusion) plus the
// voxel light at the entity's surface. Entities are terminal hits in v1 (no
// reflection bounce) so the caller breaks after compositing the result.
float4 shade_entity(EntityHit ehit, float3 dir) {
    int    ei = ehit.index;
    float3 P  = ehit.hit_pos;
    float3 N  = sdf_entity_normal(ei, P);
    int    kind   = int(sdf_entities[ei * ENTITY_STRIDE + 1].w + 0.5);
    float  phase  = sdf_entities[ei * ENTITY_STRIDE + 2].w;
    float4 e3     = sdf_entities[ei * ENTITY_STRIDE + 3]; // color, seed
    float3 albedo = e3.rgb * (0.92 + 0.16 * e3.w);        // per-entity tone variety

    float3 l  = light_dir_normalized;
    // 0.05 offset vs the 0.01 shadow-trace epsilon: enough margin that
    // grazing self-shadow rays don't acne on the entity's own surface.
    float3 so = P + N * 0.05;

    // Sun: single hard tap (entities are small — soft-shadow taps not worth it).
    float ndl = dot(N, l);
    float sun = 0.0;
    if (ndl > 0.0) {
        sun = ndl * trace_shadow_transmittance(so, l)
                  * entity_shadow_transmittance(so, l, RAY_MAX_LENGTH)
                  * u_sun_intensity;
    }

    // Sky + torch light of the voxel just off the surface.
    uint   lv    = sample_light(int3(floor(P + N * 0.6)));
    float3 ambient = sky_ambient() * light_curve(float(lv >> 4)) + MIN_AMBIENT;
    float3 torch   = TORCH_LIGHT_COLOR * light_curve(float(lv & 15u));

    float3 col = albedo * (ambient + sun + torch);

    // Crystals glow on their own (unlit, like torch emission — trips bloom).
    if (kind == ENTITY_KIND_CRYSTAL) {
        float pulse = 0.85 + 0.15 * sin(u_time * 3.0 + phase);
        col += e3.rgb * 4.0 * pulse;
    }
    return apply_fog(float4(col, 1.0), ehit.t, dir);
}

// ---- Water ------------------------------------------------------------------
// Water is a medium, not a surface: a view ray reaching water takes a
// Fresnel share of the reflected sky, then carries on through the water
// (skipping water voxels). Whatever it reaches next fades toward the water
// colour with the distance travelled under water.
#define WATER_ABSORB    0.12 // per voxel: ~8 voxels down it's mostly water colour
#define WATER_VIEW_DIST 36.0 // past this under water, only water colour is left (exp(-4.3))

static bool g_cam_in_water;

float3 water_deep_color() {
    return float3(0.02, 0.085, 0.11) * (sky_ambient() + sun_tint() * (u_sun_intensity * 0.5 * sun_elevation()));
}

// Gentle animated ripples for the surface normal (reflection only).
float3 water_normal(float3 p) {
    float a = sin(p.x * 0.9 + u_time * 1.3) + sin(p.z * 1.7 - p.x * 0.4 - u_time * 1.7);
    float b = sin(p.z * 0.8 + p.x * 0.3 + u_time * 1.1) + sin(p.x * 1.5 - u_time * 1.4);
    return normalize(float3(a * 0.035, 1.0, b * 0.035));
}

float water_fresnel(float3 dir, float3 n) {
    float c = saturate(-dot(dir, n));
    return 0.02 + 0.98 * pow(1.0 - c, 5.0);
}

// col seen through d voxels of water under a surface t_surface from the
// camera, with reflection share F of refl.
float3 water_mix(float3 col, float d, float t_surface, float3 dir, float F, float3 refl) {
    float3 deep = apply_fog(float4(water_deep_color(), 1.0), t_surface, dir).rgb;
    col = lerp(deep, col, exp(-d * WATER_ABSORB));
    return lerp(col, refl, F);
}

// Far terrain: one flat color per cell (per-voxel texture detail would only
// alias at that distance), averaged from the near textures so the handover
// at the near-region edge stays quiet.
float3 far_block_color(uint id, int2 cell, float3 n, float y) {
    float3 dirt = float3(0.40, 0.27, 0.13) * 0.97;
    if (id == BLOCK_GRASS) {
        float  m     = fbm2(float2(cell * FAR_CELL) * 0.013);
        float3 grass = lerp(float3(0.13, 0.40, 0.10), float3(0.28, 0.42, 0.14), m) * 0.98;
        return n.y > 0.5 ? grass : lerp(dirt, grass, 0.35);
    }
    // Calibrated against the voxel trees by rendering the same forest
    // both ways (bench config "far from 16 chunks").
    if (id == BLOCK_LEAVES)        return float3(0.085, 0.198, 0.054);
    if (id == BLOCK_SPRUCE_LEAVES) return float3(0.045, 0.135, 0.065);
    if (id == BLOCK_LOG)           return float3(0.33, 0.21, 0.09);
    if (id == BLOCK_SPRUCE_LOG)    return float3(0.22, 0.14, 0.08);
    if (id == BLOCK_DIRT)          return dirt;
    if (id == BLOCK_SAND)          return float3(0.71, 0.62, 0.43);
    if (id == BLOCK_RED_SAND)      return float3(0.64, 0.32, 0.16);
    if (id == BLOCK_SANDSTONE)     return float3(0.76, 0.65, 0.44);
    if (id == BLOCK_SNOW)          return n.y > 0.5 ? float3(0.86, 0.89, 0.95) : float3(0.62, 0.62, 0.64);
    if (id == BLOCK_ICE)           return float3(0.47, 0.62, 0.80);
    if (id == BLOCK_GRAVEL)        return float3(0.50, 0.48, 0.44);
    if (id == BLOCK_CACTUS)        return float3(0.22, 0.47, 0.15);
    if (id == BLOCK_TERRACOTTA) {
        static const float3 bands[3] = { float3(0.64, 0.36, 0.20), float3(0.74, 0.52, 0.34), float3(0.56, 0.26, 0.17) };
        return n.y > 0.5 ? bands[0] : bands[uint(floor(y / 6.0)) % 3u];
    }
    return float3(0.55, 0.55, 0.56) * 0.97;
}

// Fully sky-lit, sun without shadows. t_off: distance already travelled
// before this ray segment (for fog).
float4 shade_far(FarHit h, float3 dir, float t_off) {
    if (h.block_id == BLOCK_WATER) {
        float3 n = h.normal.y > 0.5 ? water_normal(h.hit_pos) : h.normal;
        float3 refl = sky_color_d(reflect(dir, n), light_dir_normalized);
        return apply_fog(float4(lerp(water_deep_color(), refl, water_fresnel(dir, n)), 1.0), h.t + t_off, dir);
    }
    float  j = hash31i(int3(h.cell.x, 7, h.cell.y)) - 0.5;
    float3 c = far_block_color(h.block_id, h.cell, h.normal, h.hit_pos.y);
    c *= 1.0 + j * 0.08;
    // Ground under a canopy is in the crown's shade: no sun, little sky.
    float sky = h.under_canopy ? 0.3 : 1.0;
    float sun = h.under_canopy ? 0.0 : saturate(dot(h.normal, light_dir_normalized));
    float3 lighting = (sky_ambient() * sky + MIN_AMBIENT) * face_shade(h.normal)
                    + sun_tint() * sun * u_sun_intensity;
    if (block_is_leaves(h.block_id)) {
        // A crown is a rounded, self-shading clump, not the flat-roofed slab
        // the cell is: lit like flat faces, every height step between cells
        // shows as a bright stripe. Mostly use a direction-independent
        // light instead (sky + partial sun scattered through the leaves).
        float3 soft = (sky_ambient() + MIN_AMBIENT) * 0.85
                    + sun_tint() * (0.35 + 0.5 * saturate(light_dir_normalized.y)) * 0.6 * u_sun_intensity;
        lighting = lerp(lighting * float3(1, 1, 1), soft, 0.75);
    }
    return apply_fog(float4(c * lighting, 1.0), h.t + t_off, dir);
}

// Where the primary ray's voxel walk stops: the near region's edge when far
// terrain is on (it takes over from there), else the full ray length.
float primary_max_len(float3 o, float3 d, out int exit_axis) {
    float t = near_exit_t(o, d, exit_axis);
    return u_far_enabled != 0 ? t : RAY_MAX_LENGTH;
}

// hit0/far0/ehit0/use_hit0: precomputed primary voxel, far terrain and
// entity hits for the center ray — when set, the first bounce of this sample
// skips its traces entirely.
float4 trace_pixel(float2 pixel, float2 dims, HitInfo hit0, FarHit far0, EntityHit ehit0, bool use_hit0) {
    float3 origin = u_cam_pos;
    float nx = (pixel.x * 2.0 - dims.x) / dims.x;
    float ny = -(pixel.y * 2.0 - dims.y) / dims.y;
    float3 dir = normalize(u_cam_fwd + nx * u_cam_right + ny * u_cam_up);

    float4 pixel_color = sky_color(normalize(dir));
    float reflection_amount = 1.0;

    // Water state (see water_mix): set once the ray is under water.
    bool   in_water   = g_cam_in_water;
    float  water_F    = 0.0;
    float3 water_refl = float3(0, 0, 0);
    float  t_acc      = 0.0; // distance travelled before the current segment
    int    bounce     = 0;   // solid surfaces shaded so far

    // One extra pass for entering water, which isn't a bounce.
    for (int i = 0; i <= u_reflect_amount && bounce < u_reflect_amount; i++) {
        HitInfo hit;
        FarHit  far_hit;
        far_hit.hit = false;
        uint skip = in_water ? BLOCK_WATER : 0u;
        if (i == 0 && use_hit0) {
            hit     = hit0;
            far_hit = far0;
        } else if (in_water) {
            // Under water only the next few dozen voxels can show.
            hit = trace_ray_chunk(origin, dir, false, RAY_ITERATIONS, WATER_VIEW_DIST, skip);
        } else if (bounce == 0) {
            int exit_axis;
            float near_len = primary_max_len(origin, dir, exit_axis);
            hit = trace_ray_chunk(origin, dir, false, RAY_ITERATIONS, near_len, skip);
            if (hit.block_id == 0u && u_far_enabled != 0) far_hit = far_trace(origin, dir, near_len, exit_axis);
        } else {
            hit = trace_ray_chunk(origin, dir, false, RAY_ITERATIONS, RAY_MAX_LENGTH, skip);
        }
        float hit_t = hit.block_id != 0u ? hit.t : (far_hit.hit ? far_hit.t : RAY_MAX_LENGTH);

        // Entities compete with the voxel hit on the primary view ray. The
        // voxel hit caps the trace so occluded entities exit on the AABB test.
        if (i == 0 && u_entity_count > 0) {
            EntityHit ehit;
            if (use_hit0) ehit = ehit0;
            else          ehit = trace_entities(origin, dir, hit_t);
            if (ehit.index >= 0 && ehit.t < hit_t) {
                pixel_color = lerp(pixel_color, shade_entity(ehit, dir), reflection_amount);
                break; // terminal: entities don't spawn reflection bounces in v1
            }
        }

        if (hit.block_id == BLOCK_WATER) {
            // Into the water: keep the reflection, carry on underneath.
            float3 n   = hit.normal.y > 0.5 ? water_normal(hit.hit_pos) : hit.normal;
            water_F    = water_fresnel(dir, n);
            water_refl = apply_fog(sky_color(reflect(dir, n)), t_acc + hit.t, dir).rgb;
            in_water   = true;
            t_acc     += hit.t;
            origin     = hit.hit_pos + dir * 0.01;
            continue;
        }

        // Too deep under water to show through: skip shading it.
        if (in_water && hit.block_id != 0u && exp(-hit.t * WATER_ABSORB) < 0.03) {
            hit.block_id = 0u;
            far_hit.hit  = false;
        }

        if (hit.block_id != 0u) {
            float4 hit_color = float4(
                voxel_surface_color(hit.block_id, hit.vkey, hit.hit_pos, hit.normal), 1.0);

            float3 hit_point   = hit.hit_pos;
            float3 surf_normal = hit.normal;
            float3 looking_dir = u_cam_fwd;
            float epsilon      = 0.01;

            // Voxel light in front of this face: sky (ambient + whether the
            // sun can reach at all) and block light (torches).
            float2 lv = face_light(hit.vkey, surf_normal, hit_point);
            float  sky_level = lv.x;
            float3 lighting = (sky_ambient() * light_curve(sky_level) + MIN_AMBIENT
                            + TORCH_LIGHT_COLOR * light_curve(lv.y)) * face_shade(surf_normal);

            // Sun. No sky light means sealed off from the sky (caves), so the
            // shadow ray is skipped there.
            float3 l = light_dir_normalized;
            float n_dot_l = dot(surf_normal, l);
            if (n_dot_l > 0.0 && sky_level > 0.0) {
                float3 shadow_origin = hit_point + surf_normal * epsilon;
                float shadow_factor = trace_shadow_transmittance(shadow_origin, l);
                // Soft shadow: 5-tap disc within a small sun cone (~3 deg).
                // t0 is binary for solid occluders, so it can't detect
                // penumbra by itself; only taken near the camera.
                if ((u_quality % 10) == 3 && hit.t + t_acc < 150.0) {
                    static const float2 disk[4] = {
                        float2( 0.0,    1.0),
                        float2( 0.866, -0.5),
                        float2(-0.866, -0.5),
                        float2( 0.0,   -0.3),
                    };
                    float3 tangent   = normalize(cross(abs(l.x) > 0.9 ? float3(0,1,0) : float3(1,0,0), l));
                    float3 bitangent = cross(l, tangent);
                    float spread = 0.052; // tan(3 deg)
                    float acc = shadow_factor;
                    for (int k = 0; k < 4; k++) {
                        float3 jitter = (disk[k].x * tangent + disk[k].y * bitangent) * spread;
                        acc += trace_shadow_transmittance(shadow_origin, normalize(l + jitter));
                    }
                    shadow_factor = acc / 5.0;
                }
                // Entity occlusion: one tap (entity penumbra isn't worth 5x).
                if (u_entity_count > 0 && shadow_factor > 0.0) {
                    shadow_factor *= entity_shadow_transmittance(shadow_origin, l, RAY_MAX_LENGTH);
                }
                lighting += sun_tint() * (n_dot_l * shadow_factor * u_sun_intensity);
            }

            // Leaf backlit glow: sun behind the leaves tints them warm
            // yellow-green, scaled by how open to the sky they are.
            if (block_is_leaves(hit.block_id)) {
                float back_light = saturate(-n_dot_l);
                hit_color.rgb += float3(0.3, 0.45, 0.1) * back_light * light_curve(sky_level) * sun_tint();
            }

            float ao = (bounce == 0 && !in_water) ? compute_ao(hit_point + surf_normal * epsilon, surf_normal, hit_point) : 1.0;
            hit_color.xyz *= lighting * ao;
            // Emissive blocks radiate on their own — NOT multiplied by
            // lighting/AO/shadow. Bright enough to trip the bloom threshold.
            float3 emis = block_emission(hit.block_id);
            if (emis.x > 0.0) {
                float fl = 0.92 + 0.08 * sin(u_time * 9.0 + hash31i(hit.vkey) * 6.2831853);
                hit_color.rgb += emis * fl;
            }
            hit_color = apply_fog(hit_color, hit.t + t_acc, dir);
            if (in_water) hit_color.rgb = water_mix(hit_color.rgb, hit.t, t_acc, dir, water_F, water_refl);
            pixel_color = lerp(pixel_color, hit_color, reflection_amount);
            if (in_water) break; // no reflection bounces under water
            reflection_amount = 0.2;
            bounce += 1;
            t_acc  += hit.t;

            origin = hit_point + surf_normal * epsilon;
            dir    = dir - 2.0 * dot(dir, surf_normal) * surf_normal;
        } else if (far_hit.hit) {
            float4 c = shade_far(far_hit, dir, t_acc);
            if (in_water) c.rgb = water_mix(c.rgb, far_hit.t, t_acc, dir, water_F, water_refl);
            pixel_color = lerp(pixel_color, c, reflection_amount);
            break;
        } else {
            float4 c = sky_color(normalize(dir));
            if (in_water) c.rgb = water_mix(c.rgb, 1e4, t_acc, dir, water_F, water_refl);
            pixel_color = lerp(pixel_color, c, reflection_amount);
            break;
        }
    }

    // Linear HDR out — tone mapping happens in composite, after volumetrics.
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

    // 1. Trace the center primary ray ONCE — it feeds depth and AA sample 0
    // (whose offset is the pixel center).
    float2 pf  = float2(ipix);
    float  cnx = (pf.x * 2.0 - dims.x) / dims.x;
    float  cny = -(pf.y * 2.0 - dims.y) / dims.y;
    float3 cdir = normalize(u_cam_fwd + cnx * u_cam_right + cny * u_cam_up);
    int exit_axis;
    float near_len = primary_max_len(u_cam_pos, cdir, exit_axis);
    // Under water: pass through water, see only WATER_VIEW_DIST (as trace_pixel does).
    g_cam_in_water = sample_voxel(u_cam_pos) == BLOCK_WATER;
    HitInfo hit0 = trace_ray_chunk(u_cam_pos, cdir, false, RAY_ITERATIONS,
                                   g_cam_in_water ? WATER_VIEW_DIST : near_len,
                                   g_cam_in_water ? BLOCK_WATER : 0u);
    FarHit far0;
    far0.hit = false;
    if (hit0.block_id == 0u && u_far_enabled != 0 && !g_cam_in_water) far0 = far_trace(u_cam_pos, cdir, near_len, exit_axis);
    float hit0_t = hit0.block_id != 0u ? hit0.t : (far0.hit ? far0.t : 1e30);
    // Entities on the center ray: shared by AA sample 0 and merged into the
    // depth output (volumetric clamp + composite bilateral upscale read it).
    EntityHit ehit0 = trace_entities(u_cam_pos, cdir, min(hit0_t, RAY_MAX_LENGTH));
    float prim_depth = hit0_t;
    if (ehit0.index >= 0) prim_depth = min(prim_depth, ehit0.t);

    // 2. AA loop — u_quality packs: AA = u_quality/10, shadow mode = u_quality%10
    int aa = clamp(u_quality / 10, 1, AA_SAMPLES);
    float4 color = float4(0, 0, 0, 0);
    for (int s = 0; s < aa; s++) {
        color += trace_pixel(float2(ipix) + aa_offsets[s], dims, hit0, far0, ehit0, s == 0);
    }
    color /= float(aa);

    img_output[ipix]   = color;
    depth_output[ipix] = prim_depth;
}
