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
StructuredBuffer<uint4>    ent_data         : register(t6, space0); // entity voxel models + instances (voxel_models.odin)
StructuredBuffer<uint>     far_data         : register(t7, space0); // far terrain tile table, then cells (far.odin)

RWTexture2D<float4>        img_output        : register(u0, space1);
RWTexture2D<float>         depth_output      : register(u1, space1); // primary-hit dist, 1e30 = sky

#include "camera_uniforms.hlsl"

#define HAS_VOXEL_LIGHT
#include "entity_voxel.hlsl"
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

// Spatial fog: transmittance terms composed multiplicatively.
//  1) distance haze (squared-exponential, tunable via u_fog_density) times a
//     gentle exponential aerial perspective, so ridges fade into layers of
//     blue with distance instead of all reading at the same contrast
//  2) exponential HEIGHT fog — density falls off with altitude, integrated in
//     closed form along the ray → valleys collect haze, peaks stay clear
//  3) cave fog — short-range murk that scales with u_cave_factor so caves
//     feel enclosed; tinted near-black blue instead of sky color
//  4) valley mist — a thin dense layer just above sea level whose amount
//     follows the clock (u_atmos.x: thickest at dawn)
#define FOG_BASE_Y         10.0   // terrain minimum — height-fog reference plane
#define FOG_FALLOFF        40.0   // height-fog density e-fold distance (voxels)
#define FOG_HEIGHT_DENSITY 0.004  // height-fog density at FOG_BASE_Y
#define AERIAL_DENSITY     0.0003 // exponential aerial perspective per voxel
#define CAVE_FOG_DENSITY   0.025  // cave murk density at cave_factor = 1
#define MIST_BASE_Y        24.0   // sea level
#define MIST_FALLOFF       13.0
#define MIST_DENSITY       0.018

// Optical depth from the camera along rd for dist through a medium of
// density r0 * exp(-(y - cam_y) * k) (closed form, near-horizontal guarded).
float height_od(float r0, float k, float dist, float3 rd) {
    return (abs(rd.y) > 1e-3) ? r0 * (1.0 - exp(-dist * rd.y * k)) / (rd.y * k) : r0 * dist;
}

float4 apply_fog(float4 color, float dist, float3 ray_dir) {
    float3 rd = normalize(ray_dir);

    // 1) Distance haze + aerial perspective
    float t_dist = clamp(exp(-pow(dist * u_fog_density, 2.0)), 0.0, 1.0) * exp(-dist * AERIAL_DENSITY);

    // 2) Height fog: rho(y) = H * exp(-(y - BASE)/FALLOFF)
    float k  = 1.0 / FOG_FALLOFF;
    float t_height = exp(-max(height_od(FOG_HEIGHT_DENSITY * exp(-(u_cam_pos.y - FOG_BASE_Y) * k), k, dist, rd), 0.0));

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
    color = lerp(fog_color, color, transmit);

    // 4) Valley mist: a little brighter than the haze (it scatters the sun
    // it sits in), and none of it underground.
    float mist = u_atmos.x * (1.0 - u_cave_factor);
    if (mist > 0.001) {
        float km = 1.0 / MIST_FALLOFF;
        // Capped at the sea-level density: below it (caves, under water)
        // the exponential would keep growing.
        float od = min(height_od(MIST_DENSITY * mist * exp(-(u_cam_pos.y - MIST_BASE_Y) * km), km, dist, rd),
                       dist * MIST_DENSITY * mist);
        float3 mist_col = fog_color.rgb * 1.08 + sun_tint() * (u_sun_intensity * 0.05 * saturate(light_dir_normalized.y + 0.1));
        color.rgb = lerp(mist_col, color.rgb, exp(-max(od, 0.0)));
    }
    return color;
}

// ---- Light colors -------------------------------------------------------------

// Ambient light from the open sky at full sky light: blue by day, dusky
// lavender with the sun low (a cool fill against the warm low sun, so
// shadows read blue at golden hour), deep blue at night.
float3 sky_ambient() {
    float3 day = lerp(float3(0.27, 0.26, 0.34), float3(0.36, 0.46, 0.66),
                      smoothstep(0.0, 0.4, saturate(u_sun_true.y)));
    return lerp(day, float3(0.036, 0.052, 0.100), u_sun_true.w);
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

// Sun bounced off sunlit ground (mostly grass, rock, sand): reaches faces
// turned sideways or down. Scaled by the face's sky light by the caller.
float3 bounce_light(float3 n) {
    float facing = n.y > 0.5 ? 0.0 : (n.y < -0.5 ? 1.0 : 0.6);
    return sun_tint() * float3(0.85, 0.80, 0.62)
         * (u_sun_intensity * saturate(light_dir_normalized.y) * 0.09 * facing);
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
// Patterns are built in FACE texel space (fuv: the two texel axes of the face
// plane, continuous across neighbouring voxels), so clumps, cracks and
// ripples run across block borders instead of restarting in every voxel.
// Material variety lives at four frequencies: per-texel grain, texel-scale
// value noise (clumps, cracks), small per-voxel luminance, and an fbm area
// tint over tens of voxels.
// `detail` (1 near, 0 far) fades the per-texel grain toward its mean with
// distance: a texel is ~1 pixel at ~60 voxels, past that the grain only
// shimmers, and the far terrain LOD is flat colour anyway.
#define TEXELS 8

// Value noise over face texel coords (scale in texels per noise cell).
float tex_noise(float2 fuv, float scale, float seed) {
    return vnoise2(fuv / scale + seed);
}

// Meadow tint: deep green <-> warm olive over ~75 voxels. Shared with the
// far terrain LOD.
float3 grass_tint(float2 xz) {
    float m = fbm2(xz * 0.013);
    return lerp(float3(0.15, 0.33, 0.09), float3(0.30, 0.37, 0.12), m);
}

#define DIRT_COLOR float3(0.36, 0.25, 0.15)

float3 dirt_texture(float h, float n, float pebble, float detail) {
    float3 c = DIRT_COLOR * (0.80 + 0.30 * n + (h - 0.5) * 0.30 * detail);
    if (pebble < 0.05 * detail) c = lerp(c, float3(0.52, 0.47, 0.40), 0.75);
    return c;
}

// ---- Mountain rock ----
// Stone is coloured in WORLD space so a mountain reads as one rock mass
// rather than a pile of identical blocks: tilted sedimentary strata a few
// voxels thick (warped over hundreds of voxels) run straight through the
// stepped slopes, ledges hold snow that thickens with altitude, and low
// ledges grow moss. Shared by the near texture and the far terrain LOD.
#define STRATA_THICK 3.5
#define SNOW_DUST_LO 118.0 // ledge snow starts here...
#define SNOW_DUST_HI 168.0 // ...and covers everything here (terrain SNOW_LINE)

// Layer value 0..1 at p (voxel units); `edge` = position within the layer.
float stone_layer(float3 p, out float edge) {
    float warp = fbm2(p.xz * 0.011) * 16.0;
    float sv = (p.y + p.x * 0.21 - p.z * 0.13 + warp) / STRATA_THICK;
    edge = frac(sv);
    return hash31i(int3(int(floor(sv)), 913, 17));
}

// Rock colour of one stratum: mostly grey, some warm ochre bands, some dark
// slate bands.
float3 stratum_color(float lh) {
    float3 c = float3(0.50, 0.50, 0.51) * (0.78 + 0.36 * lh);
    if (lh > 0.80) c *= float3(1.08, 0.98, 0.86) * 0.94;
    if (lh < 0.22) c *= float3(0.80, 0.85, 0.94);
    return c;
}

// 0..1 share of a ledge top under snow at altitude y.
float snow_dust_cover(float3 p) {
    return smoothstep(SNOW_DUST_LO, SNOW_DUST_HI, p.y + (vnoise2(p.xz * 0.08) - 0.5) * 36.0);
}

#define SNOW_COLOR float3(0.84, 0.87, 0.93)

// Snow surface: soft drifts, wind ridges with bluish troughs, rare glints.
float3 snow_texture(float2 fuv, float h, float hd, float detail) {
    float drift = tex_noise(fuv, 7.0, 1.7) * 0.6 + tex_noise(fuv, 40.0, 6.3) * 0.4;
    float rip = sin((fuv.x * 0.45 - fuv.y * 0.3 + tex_noise(fuv, 16.0, 4.0) * 6.0) * 1.2);
    float3 c = lerp(float3(0.74, 0.80, 0.92), float3(0.88, 0.90, 0.94), saturate(drift * 1.1 - 0.05 + rip * 0.08 * detail));
    c *= 1.0 + (hd - 0.5) * 0.04;
    if (h > 0.985 && detail > 0.5) c = float3(1.0, 1.0, 1.0);
    return c;
}

// allow_dust: moss and ledge snow, only on weathered (terrain surface) rock:
// stone exposed by digging or placed by the player stays bare.
float3 stone_texture(int3 vkey, int3 tkey, int3 txl, float2 fuv, float3 nrm,
                     float h, float hd, float3 h3, float detail, bool allow_dust) {
    bool   top = abs(nrm.y) > 0.5;
    float3 p   = (float3(tkey) + 0.5) / float(TEXELS);
    float  edge;
    float  lh  = stone_layer(p, edge);
    float  blot = tex_noise(fuv, 3.0, 13.0);
    float3 c = stratum_color(lh) * (0.84 + 0.22 * blot + (hd - 0.5) * 0.16);
    c += h3 * 0.02;
    if (!top) {
        // Bedding planes: a thin dark seam at the bottom of each stratum.
        if (edge < 0.04) c *= lerp(1.0, 0.78, detail);
        // Weathering streaks: water-stained runs down cliff faces,
        // stretched vertically so they flow over several blocks.
        float st = vnoise2(float2(fuv.x / 1.6, p.y / 9.0) + 40.0);
        c *= 1.0 - 0.18 * smoothstep(0.62, 0.82, st);
    }
    float crack = abs(tex_noise(fuv, 7.0, 31.0) * 2.0 - 1.0);
    if (crack < 0.045) c *= lerp(1.0, 0.65, detail);

    if (allow_dust) {
        float cover = snow_dust_cover(p);
        if (top) {
            // Snow lying on the ledge, patchy at first; moss on low ledges.
            if (tex_noise(fuv, 2.5, 77.0) < cover * 1.25 - 0.12)
                return snow_texture(fuv, h, hd, detail);
            float moss = (1.0 - smoothstep(60.0, 125.0, p.y)) * smoothstep(0.55, 0.80, tex_noise(fuv, 4.0, 61.0));
            c = lerp(c, float3(0.20, 0.28, 0.11) * (0.85 + 0.3 * hd), moss);
        } else if (nrm.y == 0.0 && cover > 0.25 && txl.y >= TEXELS - 1 - int(cover * 2.0)) {
            // Lip of the ledge snow hanging over the top edge of the face.
            if (sample_voxel(float3(vkey) + float3(0.5, 1.5, 0.5)) == 0u &&
                hash31i(int3(tkey.x, 77, tkey.z)) < cover + 0.2)
                return snow_texture(fuv, h, hd, detail) * 0.97;
        }
    }
    return c;
}

float3 voxel_surface_color(uint block_id, int3 vkey, float3 hit_pos, float3 nrm, float dist) {
    // Sub-voxel texel coords: inset along the normal so the face plane floors
    // into THIS voxel, then quantize (frac convention per AO/grass band).
    float3 fr   = frac(hit_pos - nrm * 0.01);
    int3   txl  = clamp(int3(fr * TEXELS), 0, TEXELS - 1);
    int3   tkey = vkey * TEXELS + txl;
    bool   top  = abs(nrm.y) > 0.5;
    // Face-plane texel coords (texel centres), continuous across voxels.
    float2 fuv  = top ? float2(tkey.xz) : (abs(nrm.x) > 0.5 ? float2(tkey.zy) : float2(tkey.xy));
    fuv += 0.5;

    float  detail = 1.0 - smoothstep(24.0, 110.0, dist);
    float  h  = hash31i(tkey);          // per-texel value
    float  hd = lerp(0.5, h, detail);   // ...faded with distance
    float3 h3 = (hash33i(tkey) - 0.5) * detail; // per-texel hue offset
    float  vj = hash31i(vkey) - 0.5;    // small per-voxel luminance variety

    if (block_id == BLOCK_GRASS || block_id == BLOCK_SNOW) {
        bool snow = block_id == BLOCK_SNOW;
        bool on_top;
        if (nrm.y > 0.5) {
            on_top = true;
        } else if (nrm.y < -0.5) {
            on_top = false;
        } else {
            // Side: ragged HARD-EDGED band (no fade) — depth varies per
            // texel column, only where the voxel above is open air.
            // Snow drifts over the edge in a smooth wavy band instead.
            bool exposed = (sample_voxel(float3(vkey) + float3(0.5, 1.5, 0.5)) == 0u);
            int band = 0;
            if (exposed) {
                if (snow) {
                    float bn = vnoise2(float2(fuv.x / 3.0, float(vkey.y) * 3.7));
                    band = 2 + int(bn * 4.0);
                } else {
                    float ch = hash31i(int3(tkey.x, 4242, tkey.z)); // per texel column
                    band = 2 + int(ch * 3.0);
                }
            }
            on_top = (txl.y >= TEXELS - band);
        }

        if (!on_top) {
            // Snow on a mountain covers rock: show the rock (its strata line
            // up with the bare stone around). Elsewhere frozen soil.
            if (snow) {
                uint below = sample_voxel(float3(vkey) + float3(0.5, -0.5, 0.5));
                if (below == BLOCK_STONE || below == BLOCK_WEATHERED_STONE || below == BLOCK_SNOW)
                    return saturate(stone_texture(vkey, tkey, txl, fuv, nrm, h, hd, h3, detail, false)
                                    * float3(0.97, 0.99, 1.04));
            }
            float3 c = dirt_texture(h, tex_noise(fuv, 2.5, 3.1), hash31i((tkey >> 1) + 57), detail);
            // Frozen ground under snow: greyer and paler than meadow soil.
            if (snow) c = lerp(c, dot(c, float3(0.3, 0.5, 0.2)).xxx * float3(1.05, 1.0, 0.95), 0.6) * 1.15;
            return saturate(c * (1.0 + vj * 0.08));
        }
        if (snow) return snow_texture(fuv, h, hd, detail);
        // Clumps of blades a few texels wide, lighter tips, darker roots.
        float3 g = grass_tint(float2(vkey.xz));
        float  clump = tex_noise(fuv, 2.2, 5.3);
        float3 c = g * (0.80 + 0.36 * clump + (hd - 0.5) * 0.30);
        c += h3 * float3(0.02, 0.04, 0.01);
        if (!top) {
            // Overhang of the band: a little darker than the top.
            c *= 0.92;
        } else if (detail > 0.0) {
            // Wildflowers: voxels in some patches carry 1-texel blooms.
            float patchy = tex_noise(float2(vkey.xz), 9.0, 11.0);
            float fh = hash31i(tkey + int3(0, 991, 0));
            if (fh < 0.02 * smoothstep(0.55, 0.85, patchy) * detail) {
                uint kind = uint(hash31i(vkey + int3(5, 5, 5)) * 4.0);
                c = kind == 0u ? float3(0.95, 0.80, 0.18)
                  : kind == 1u ? float3(0.92, 0.92, 0.88)
                  : kind == 2u ? float3(0.62, 0.40, 0.85)
                  :              float3(0.85, 0.22, 0.18);
            }
        }
        return saturate(c * (1.0 + vj * 0.06));
    }

    if (block_id == BLOCK_LOG || block_id == BLOCK_SPRUCE_LOG) {
        bool spruce = block_id == BLOCK_SPRUCE_LOG;
        float3 c;
        if (top) {
            // Cut end: growth rings around the voxel centre, bark rim.
            float2 d = float2(txl.xz) - 3.5;
            float r = length(d);
            float ring = frac(r * 0.55 + hash31i(vkey) * 0.3);
            c = (spruce ? float3(0.50, 0.38, 0.23) : float3(0.58, 0.44, 0.26))
              * (0.86 + 0.14 * smoothstep(0.2, 0.6, ring) + (hd - 0.5) * 0.10);
            if (r > 3.6) c = spruce ? float3(0.20, 0.13, 0.07) : float3(0.30, 0.20, 0.10);
        } else {
            // Bark: vertical plates keyed on horizontal texel coords, so they
            // run up the trunk; deep furrows between plates.
            float col = hash31i(int3(tkey.x, 1717, tkey.z));
            float seg = hash31i(int3(tkey.x, tkey.y >> 2, tkey.z) + 33);
            c = (spruce ? float3(0.22, 0.14, 0.08) : float3(0.33, 0.22, 0.11))
              * (0.70 + 0.45 * col) * (0.90 + 0.20 * lerp(0.5, seg, detail));
            if (col < 0.18) c *= lerp(1.0, 0.55, detail);
        }
        return saturate(c * (1.0 + vj * 0.08));
    }

    if (block_is_leaves(block_id)) {
        // Leaf clusters with dark gaps between them for canopy depth.
        bool spruce = block_id == BLOCK_SPRUCE_LEAVES;
        float cl = tex_noise(fuv, 1.8, spruce ? 21.0 : 23.0);
        float3 dark  = spruce ? float3(0.04, 0.13, 0.07) : float3(0.08, 0.24, 0.06);
        float3 light = spruce ? float3(0.09, 0.24, 0.12) : float3(0.17, 0.38, 0.09);
        float3 c = lerp(dark, light, saturate(cl * 1.3 - 0.15 + (hd - 0.5) * 0.5));
        if (h < 0.06) c *= lerp(1.0, 0.6, detail);
        return saturate(c * (1.0 + vj * 0.20));
    }

    if (block_id == BLOCK_DIRT) {
        float3 c = dirt_texture(h, tex_noise(fuv, 2.5, 3.1), hash31i((tkey >> 1) + 57), detail);
        return saturate(c * (1.0 + vj * 0.08));
    }

    if (block_id == BLOCK_SAND || block_id == BLOCK_RED_SAND) {
        float3 base = block_id == BLOCK_SAND ? float3(0.70, 0.60, 0.41) : float3(0.62, 0.31, 0.15);
        float3 c = base * (0.92 + (hd - 0.5) * 0.16) + h3 * 0.025;
        if (top) {
            // Wind ripples: wavy crests every ~4 texels, warped by noise.
            float warp = tex_noise(fuv, 14.0, 2.0) * 7.0;
            float rip = sin((fuv.x * 0.85 + fuv.y * 0.35 + warp) * 1.55);
            c *= 1.0 + 0.06 * rip * detail;
        }
        return saturate(c * (1.0 + vj * 0.04));
    }

    if (block_id == BLOCK_SANDSTONE) {
        // Horizontal strata: brightness per texel row, smooth along the row.
        float layer = hash31i(int3(0, tkey.y, 77));
        float n = tex_noise(fuv, 4.0, 8.0);
        float3 c = float3(0.74, 0.63, 0.43)
                 * (top ? 0.95 : 0.86 + 0.16 * layer) * (0.92 + 0.10 * n + (hd - 0.5) * 0.08);
        return saturate(c * (1.0 + vj * 0.05));
    }

    if (block_id == BLOCK_TERRACOTTA) {
        // Badlands strata: one colour per 2-voxel band of world height.
        static const float3 bands[6] = {
            float3(0.60, 0.32, 0.18), float3(0.74, 0.53, 0.34), float3(0.53, 0.23, 0.15),
            float3(0.80, 0.70, 0.56), float3(0.66, 0.42, 0.20), float3(0.45, 0.28, 0.22),
        };
        uint bi = min(uint(hash31i(int3(7, vkey.y >> 1, 3)) * 6.0), 5u);
        float n = tex_noise(fuv, 3.0, 4.0);
        float3 c = bands[bi] * (0.90 + 0.10 * n + (hd - 0.5) * 0.10);
        return saturate(c * (1.0 + vj * 0.05));
    }

    if (block_id == BLOCK_GRAVEL) {
        // Pebbles: 2x2-texel stones of mixed tone, dark gaps.
        float  pb = lerp(0.5, hash31i(tkey >> 1), detail);
        float3 c = lerp(float3(0.40, 0.38, 0.36), float3(0.60, 0.57, 0.52), pb);
        if (h < 0.18 * detail) c *= 0.65;
        return saturate(c * (1.0 + vj * 0.06));
    }

    if (block_id == BLOCK_ICE) {
        float3 c = float3(0.46, 0.62, 0.80) * (0.94 + 0.08 * hd);
        // Long frost cracks: thin ridges of value noise.
        float r = abs(tex_noise(fuv, 6.0, 9.0) * 2.0 - 1.0);
        if (r < 0.06 * detail) c = float3(0.75, 0.85, 0.95);
        return saturate(c);
    }

    if (block_id == BLOCK_CACTUS) {
        // Vertical ribs on the sides, lighter crown on top, pale spines.
        float3 c = float3(0.22, 0.45, 0.15) * (0.88 + 0.18 * hd);
        if (!top) {
            int along = abs(nrm.x) > 0.5 ? txl.z : txl.x;
            if (along % 3 == 0) c *= 0.72;
            else if (h > 0.93 && detail > 0.3) c = float3(0.85, 0.82, 0.62);
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

    // Stone: world-space strata, streaks, ledge snow (stone_texture). Ores
    // add 2x2-texel specks of their mineral.
    float3 c = stone_texture(vkey, tkey, txl, fuv, nrm, h, hd, h3, detail, block_id == BLOCK_WEATHERED_STONE);
    if (block_id == BLOCK_COAL_ORE || block_id == BLOCK_IRON_ORE || block_id == BLOCK_GOLD_ORE) {
        if (hash31i((tkey >> 1) + 101) < 0.3) {
            float3 m = block_id == BLOCK_COAL_ORE ? float3(0.07, 0.07, 0.08)
                     : block_id == BLOCK_IRON_ORE ? float3(0.80, 0.58, 0.42)
                     :                              float3(0.98, 0.80, 0.22);
            c = m * (0.85 + 0.3 * h);
        }
    }
    return saturate(c * (1.0 + vj * 0.08));
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

// ---- Cumulus over thermals ---------------------------------------------------
// Every strong thermal near the player (u_thermals, filled by the CPU and
// leaned downwind) carries a cumulus: a volume with a flat base at
// CUMULUS_BASE and a domed top, roughened by 3D value noise into puffs. The
// centre ray of each pixel marches the clouds it crosses (box test first, so
// pixels nowhere near a cloud pay a few slab tests), lit by the sun through
// the cloud itself (two samples toward the sun) and by sky light that is
// dimmer toward the base. Composited in front of whatever the ray hit, so
// clouds also sit over terrain when gliding up near them.
#define CUMULUS_BASE 240.0
#define CLOUD_STEPS  20
#define CLOUD_TOP    (CUMULUS_BASE + 160.0) // above any tower (1.75 x the largest radius)
#define CLOUD_SIGMA  0.07   // extinction per metre at density 1

// Density of cloud ci (u_thermals[ci]: xz centre, radius, strength) at p,
// 0..1: a wide flat-bottomed base plus four towers (u_cloud_puffs), all as
// "1 - distance / radius" so they union with max, then eroded by noise.
float cloud_density(float3 p, int ci, bool detail = true) {
    float4 th = u_thermals[ci];
    float y = p.y - CUMULUS_BASE;
    if (y < 0.0) return 0.0;
    float3 rel = float3(p.x - th.x, y, p.z - th.y) / th.z;
    float shape = 1.0 - length(float3(rel.x, max(rel.y - 0.12, 0.0) * 2.2, rel.z));
    [unroll]
    for (int k = 0; k < 4; k++) {
        float4 pf = u_cloud_puffs[ci * 4 + k];
        shape = max(shape, 1.0 - length(rel - pf.xyz) / pf.w);
    }
    if (shape < -0.4) return 0.0;
    float3 q = p * 0.045 + float3(u_time * 0.02, -u_time * 0.01, u_time * 0.012);
    // Light samples only need the overall shape (self-shadowing follows the
    // towers); the noise matters at the visible edges.
    float n = detail ? vnoise3(q) * 0.62 + vnoise3(q * 2.37 + 11.3) * 0.38 : 0.52;
    float dens = shape + (n - 0.52) * 0.85;
    dens *= smoothstep(0.0, 5.0, y); // soft flat base
    return saturate(dens * 2.2);
}

struct CloudResult {
    float3 color;   // premultiplied in-scattered light
    float  trans;   // transmittance through the clouds
    float  t_entry; // distance of the first cloud sample, for haze
};

CloudResult march_clouds(float3 ro, float3 rd, float t_max, uint2 pix) {
    CloudResult r;
    r.color = float3(0, 0, 0); r.trans = 1.0; r.t_entry = 1e30;
    if (u_thermal_count.x == 0 || (u_ent_debug & 4) != 0) return r;
    // Rays that can't reach the cloud layer before hitting something (caves,
    // terrain below 240 m — most pixels) skip the per-cloud tests.
    float ty0 = (CUMULUS_BASE - ro.y) / rd.y, ty1 = (CLOUD_TOP - ro.y) / rd.y;
    if (abs(rd.y) < 1e-5) { ty0 = (ro.y >= CUMULUS_BASE && ro.y <= CLOUD_TOP) ? 0.0 : 1e30; ty1 = 1e30; }
    if (max(min(ty0, ty1), 0.0) >= min(max(ty0, ty1), t_max)) return r;

    // Clouds this ray crosses, nearest first (a ray rarely crosses more
    // than two, so keep four).
    float3 inv = 1.0 / ent_safe_dir(rd);
    int   ids[4];
    float t0s[4], t1s[4];
    int   n = 0;
    for (int i = 0; i < u_thermal_count.x && n < 4; i++) {
        float4 th = u_thermals[i];
        float R = th.z * 1.4;
        float3 bmin = float3(th.x - R, CUMULUS_BASE, th.y - R);
        float3 bmax = float3(th.x + R, CUMULUS_BASE + th.z * 1.75, th.y + R);
        float t0, t1;
        if (!ent_box(ro, inv, bmin, bmax, t0, t1)) continue;
        t0 = max(t0, 0.0);
        t1 = min(t1, t_max);
        if (t0 >= t1) continue;
        int k = n++;
        for (; k > 0 && t0s[k - 1] > t0; k--) { ids[k] = ids[k - 1]; t0s[k] = t0s[k - 1]; t1s[k] = t1s[k - 1]; }
        ids[k] = i; t0s[k] = t0; t1s[k] = t1;
    }
    if (n == 0) return r;

    float3 l = light_dir_normalized;
    float3 sun = sun_tint() * u_sun_intensity;
    float3 amb = sky_ambient();
    // Bright rim when looking toward the sun through thin cloud.
    float phase = 0.75 + 0.9 * pow(saturate(dot(rd, l)), 6.0);
    float jitter = frac(52.9829189 * frac(0.06711056 * float(pix.x) + 0.00583715 * float(pix.y)));

    for (int c = 0; c < n; c++) {
        int ci = ids[c];
        float H = u_thermals[ci].z * 1.4;
        float dt = (t1s[c] - t0s[c]) / CLOUD_STEPS;
        for (int s = 0; s < CLOUD_STEPS; s++) {
            float t = t0s[c] + (float(s) + jitter) * dt;
            float3 p = ro + rd * t;
            float dens = cloud_density(p, ci);
            if (dens < 0.002) continue;
            r.t_entry = min(r.t_entry, t);
            // Sun light reaching p through the cloud.
            float od = (cloud_density(p + l * 6.0, ci, false) * 6.0 + cloud_density(p + l * 20.0, ci, false) * 14.0) * CLOUD_SIGMA;
            float sun_vis = exp(-od);
            float hf = saturate((p.y - CUMULUS_BASE) / H);
            float3 Li = sun * sun_vis * phase * 0.9 + amb * lerp(0.55, 1.7, hf);
            float a = 1.0 - exp(-dens * CLOUD_SIGMA * dt);
            r.color += r.trans * a * Li;
            r.trans *= 1.0 - a;
            if (r.trans < 0.02) return r;
        }
    }
    return r;
}

// Shading for an entity voxel hit: direct sun (with entity occlusion) plus
// the voxel light at the entity's surface. Entities are terminal hits (no
// reflection bounce) so the caller breaks after compositing the result.
float4 shade_entity(EntityHit ehit, float3 dir) {
    float3 P = ehit.hit_pos;
    float3 N = ehit.normal;
    uint flags;
    float3 albedo = entity_albedo(ehit, flags);

    float3 l  = light_dir_normalized;
    // Entity voxels are ~6 cm: a small offset keeps shadow rays off the
    // face they start on without skipping the neighbouring voxels.
    float3 so = P + N * 0.02;

    // Sun: single hard tap.
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

    // Thin fabric (glider sail): lit from behind, the sun glows through it.
    if ((flags & PAL_THIN) != 0u && ndl < 0.0) {
        col += albedo * (-ndl) * 0.6 * u_sun_intensity * trace_shadow_transmittance(P - N * 0.1, l);
    }

    // Emissive voxels (crystals) glow on their own and trip bloom.
    if ((flags & PAL_EMIT) != 0u) {
        float pulse = 0.85 + 0.15 * sin(u_time * 3.0 + float(ehit.index));
        col += albedo * 4.0 * pulse;
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
    float3 dirt = DIRT_COLOR * 0.95;
    if (id == BLOCK_GRASS) {
        float3 grass = grass_tint(float2(cell * FAR_CELL)) * 0.97;
        return n.y > 0.5 ? grass : lerp(dirt, grass, 0.35);
    }
    // Calibrated against the voxel trees by rendering the same forest
    // both ways (bench config "far from 16 chunks"): a crown's self-shadow
    // makes it ~0.6x its leaf texture.
    if (id == BLOCK_LEAVES)        return float3(0.087, 0.178, 0.050);
    if (id == BLOCK_SPRUCE_LEAVES) return float3(0.043, 0.122, 0.063);
    if (id == BLOCK_LOG)           return float3(0.30, 0.20, 0.10);
    if (id == BLOCK_SPRUCE_LOG)    return float3(0.20, 0.13, 0.07);
    if (id == BLOCK_DIRT)          return dirt;
    if (id == BLOCK_SAND)          return float3(0.645, 0.552, 0.377);
    if (id == BLOCK_RED_SAND)      return float3(0.570, 0.285, 0.138);
    if (id == BLOCK_SANDSTONE)     return float3(0.675, 0.575, 0.392);
    if (id == BLOCK_SNOW)          return n.y > 0.5 ? float3(0.82, 0.86, 0.93) : float3(0.62, 0.63, 0.66);
    if (id == BLOCK_ICE)           return float3(0.47, 0.62, 0.80);
    if (id == BLOCK_GRAVEL)        return float3(0.50, 0.48, 0.44);
    if (id == BLOCK_CACTUS)        return float3(0.22, 0.45, 0.15);
    if (id == BLOCK_TERRACOTTA) {
        static const float3 bands[3] = { float3(0.62, 0.35, 0.20), float3(0.72, 0.51, 0.33), float3(0.54, 0.25, 0.17) };
        return n.y > 0.5 ? bands[0] : bands[uint(floor(y / 6.0)) % 3u];
    }
    // Stone: the same strata and ledge snow as the near texture.
    float3 p = float3(float(cell.x * FAR_CELL) + 2.0, y, float(cell.y * FAR_CELL) + 2.0);
    float edge;
    float3 rock = stratum_color(stone_layer(p, edge)) * 0.95;
    if (n.y > 0.5 && id == BLOCK_WEATHERED_STONE) {
        float cover = saturate(snow_dust_cover(p) * 1.25 - 0.12);
        float moss = (1.0 - smoothstep(60.0, 125.0, y)) * 0.2;
        rock = lerp(rock, float3(0.20, 0.28, 0.11), moss);
        return lerp(rock, SNOW_COLOR * 0.98, cover);
    }
    return rock * 0.96;
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
        if (i == 0 && u_entity_count > 0 && (u_ent_debug & 1) == 0) {
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
                voxel_surface_color(hit.block_id, hit.vkey, hit.hit_pos, hit.normal, hit.t + t_acc), 1.0);
            float3 albedo = hit_color.rgb;

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
                if (u_entity_count > 0 && shadow_factor > 0.0 && (u_ent_debug & 2) == 0) {
                    shadow_factor *= entity_shadow_transmittance(shadow_origin, l, RAY_MAX_LENGTH);
                }
                lighting += sun_tint() * (n_dot_l * shadow_factor * u_sun_intensity);
            }
            // Sunlight bounced off the ground fills faces that look sideways
            // or down, so shadowed walls and overhangs keep some warmth and
            // shape instead of flat sky blue.
            lighting += bounce_light(surf_normal) * light_curve(sky_level);

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
            // The texture shapes the glow: ember texels burn bright, the
            // charred wood between them only smoulders.
            float3 emis = block_emission(hit.block_id);
            if (emis.x > 0.0) {
                float fl = 0.92 + 0.08 * sin(u_time * 9.0 + hash31i(hit.vkey) * 6.2831853);
                hit_color.rgb += emis * albedo * albedo * fl;
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
    ent_set_pixel(uint2(ipix));
    HitInfo hit0 = trace_ray_chunk(u_cam_pos, cdir, false, RAY_ITERATIONS,
                                   g_cam_in_water ? WATER_VIEW_DIST : near_len,
                                   g_cam_in_water ? BLOCK_WATER : 0u);
    FarHit far0;
    far0.hit = false;
    if (hit0.block_id == 0u && u_far_enabled != 0 && !g_cam_in_water) far0 = far_trace(u_cam_pos, cdir, near_len, exit_axis);
    float hit0_t = hit0.block_id != 0u ? hit0.t : (far0.hit ? far0.t : 1e30);
    // Entities on the center ray: shared by AA sample 0 and merged into the
    // depth output (volumetric clamp + composite bilateral upscale read it).
    EntityHit ehit0 = trace_entities(u_cam_pos, cdir, (u_ent_debug & 1) != 0 ? 0.0 : min(hit0_t, RAY_MAX_LENGTH));
    float prim_depth = hit0_t;
    if (ehit0.index >= 0) prim_depth = min(prim_depth, ehit0.t);

    // 2. AA loop — u_quality packs: AA = u_quality/10, shadow mode = u_quality%10
    int aa = clamp(u_quality / 10, 1, AA_SAMPLES);
    float4 color = float4(0, 0, 0, 0);
    for (int s = 0; s < aa; s++) {
        color += trace_pixel(float2(ipix) + aa_offsets[s], dims, hit0, far0, ehit0, s == 0);
    }
    color /= float(aa);

    // Cumulus in front of whatever the centre ray hit (sky rays end at the
    // far side of the cloud boxes), hazed by its distance like geometry.
    if (!g_cam_in_water) {
        CloudResult cl = march_clouds(u_cam_pos, cdir, min(prim_depth, 6000.0), uint2(ipix));
        if (cl.trans < 0.999) {
            float a = 1.0 - cl.trans;
            float3 cc = apply_fog(float4(cl.color / a, 1.0), cl.t_entry, cdir).rgb;
            color.rgb = color.rgb * cl.trans + cc * a;
        }
    }

    img_output[ipix]   = color;
    depth_output[ipix] = prim_depth;
}
