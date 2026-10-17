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
StructuredBuffer<uint>     light_pool       : register(t5, space0); // 512 u16 light values per brick, two per uint
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
    float3 day = lerp(float3(0.32, 0.31, 0.40), float3(0.49, 0.60, 0.84),
                      smoothstep(0.0, 0.4, saturate(u_sun_true.y)));
    return lerp(day, float3(0.036, 0.052, 0.100), u_sun_true.w);
}

#define MIN_AMBIENT       0.015                   // so pitch-black caves keep a hint of shape

// Fixed per-face dimming of the sky/torch light (as in Minecraft): tops get
// it all, sides less, undersides least, so blocks keep their shape where the
// sun doesn't reach.
float face_shade(float3 n) {
    if (n.y > 0.5)  return 1.0;
    if (n.y < -0.5) return 0.5;
    return abs(n.x) > 0.5 ? 0.8 : 0.65;
}

// The torch in the player's hand (u_hand_light, gpu.odin): a point light
// that falls off with distance as block light does with levels, with a
// shadow ray so it doesn't shine through walls. two_sided: thin plant
// blades, lit from either side.
float3 hand_light(float3 p, float3 n, bool two_sided) {
    if (u_hand_light.w <= 0.0) return 0.0;
    float3 to = u_hand_light.xyz - p;
    float d = length(to);
    float level = u_hand_light.w - d;
    if (level <= 0.0) return 0.0;
    float3 l = to / max(d, 1e-4);
    float ndl = dot(n, l);
    if (two_sided) ndl = abs(ndl) * 0.7 + 0.3;
    if (ndl <= 0.0) return 0.0;
    // Plants shade by their shapes: so close, whole-voxel shading shows as
    // dark block-shaped wedges across the ground.
    float sh = trace_shadow_transmittance(p + n * 0.01, l, max(d - 0.3, 0.0), true);
    return TORCH_LIGHT_COLOR * (block_light_curve(level) * ndl * sh);
}

// Sun bounced off sunlit surfaces (grass, rock, sand): fills faces turned
// sideways or down, and some from the walls onto the floor. Not only off
// flat ground: a low sun lights walls and slopes square on, so a canyon or
// a cave mouth at golden hour fills with warm light off the bright rock
// beside it. Scaled by the face's sky light by the caller (how open it is).
float3 bounce_light(float3 n) {
    float facing = n.y > 0.5 ? 0.3 : (n.y < -0.5 ? 1.0 : 0.7);
    float up = saturate(light_dir_normalized.y);
    float lit = smoothstep(-0.02, 0.06, light_dir_normalized.y) * (0.5 + 0.5 * up);
    return sun_tint() * float3(0.85, 0.80, 0.62) * (u_sun_intensity * lit * 0.2 * facing);
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

// Water doesn't darken the corners it fills, nor a thin door panel.
bool ao_occludes(float3 p) {
    uint v = sample_voxel(p);
    return v != 0u && !block_is_watery(v) && !block_is_door(v);
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
    float m = fbm2(xz * (0.013 / TERRAIN_SCALE));
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
#define STRATA_THICK (3.5 * TERRAIN_SCALE)
#define SNOW_DUST_LO 165.0 // ledge snow starts here (118 design)...
#define SNOW_DUST_HI 240.0 // ...and covers everything here (terrain SNOW_LINE, 168 design)

// Layer value 0..1 at p (voxel units); `edge` = position within the layer.
float stone_layer(float3 p, out float edge) {
    float warp = fbm2(p.xz * (0.011 / TERRAIN_SCALE)) * 16.0 * TERRAIN_SCALE;
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
    return smoothstep(SNOW_DUST_LO, SNOW_DUST_HI, p.y + (vnoise2(p.xz * (0.08 / TERRAIN_SCALE)) - 0.5) * 36.0 * TERRAIN_SCALE);
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

    if (block_id == BLOCK_GRASS || block_id == BLOCK_SNOW || block_id == BLOCK_DRY_GRASS) {
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
            uint above = sample_voxel(float3(vkey) + float3(0.5, 1.5, 0.5));
            bool exposed = above == 0u || block_is_land_plant(above);
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
        if (block_id == BLOCK_DRY_GRASS) g = lerp(g, float3(0.40, 0.35, 0.13), 0.8);
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

    if (block_id == BLOCK_BIRCH_LOG) {
        float3 c;
        if (top) {
            float2 d = float2(txl.xz) - 3.5;
            float r = length(d);
            float ring = frac(r * 0.55 + hash31i(vkey) * 0.3);
            c = float3(0.72, 0.62, 0.44) * (0.88 + 0.12 * smoothstep(0.2, 0.6, ring));
            if (r > 3.6) c = float3(0.80, 0.78, 0.72);
        } else {
            // Papery white bark with dark horizontal marks here and there.
            float n = tex_noise(fuv, 3.0, 41.0);
            c = float3(0.80, 0.79, 0.74) * (0.90 + 0.12 * n + (hd - 0.5) * 0.08);
            float mark = hash31i(int3(tkey.x >> 1, tkey.y, tkey.z >> 1) + 91);
            if (mark < 0.13) c = lerp(c, float3(0.13, 0.12, 0.11), detail);
        }
        return saturate(c * (1.0 + vj * 0.06));
    }

    if (block_id == BLOCK_ACACIA_LOG) {
        // Grey bark, the cut showing orange wood.
        float3 c;
        if (top) {
            float2 d = float2(txl.xz) - 3.5;
            c = length(d) > 3.6 ? float3(0.32, 0.29, 0.26) : float3(0.62, 0.36, 0.18) * (0.9 + 0.1 * hd);
        } else {
            float col = hash31i(int3(tkey.x, 1919, tkey.z));
            float seg = hash31i(int3(tkey.x, tkey.y >> 1, tkey.z) + 71);
            c = float3(0.33, 0.30, 0.27) * (0.75 + 0.35 * col) * (0.9 + 0.2 * lerp(0.5, seg, detail));
        }
        return saturate(c * (1.0 + vj * 0.08));
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
        if (block_id == BLOCK_BIRCH_LEAVES) { dark = float3(0.13, 0.28, 0.06); light = float3(0.29, 0.47, 0.11); }
        if (block_id == BLOCK_ACACIA_LEAVES) { dark = float3(0.11, 0.17, 0.04); light = float3(0.25, 0.32, 0.08); }
        if (block_id == BLOCK_WILLOW_LEAVES) { dark = float3(0.16, 0.27, 0.08); light = float3(0.34, 0.47, 0.15); }
        if (block_id == BLOCK_AUTUMN_LEAVES) {
            // Each voxel leans orange, red or gold.
            float k = hash31i(vkey + 7);
            float3 hue = k < 0.45 ? float3(0.62, 0.22, 0.04) : k < 0.8 ? float3(0.56, 0.09, 0.04) : float3(0.62, 0.40, 0.05);
            dark = hue * 0.45; light = hue;
        }
        float3 c = lerp(dark, light, saturate(cl * 1.3 - 0.15 + (hd - 0.5) * 0.5));
        if (h < 0.06) c *= lerp(1.0, 0.6, detail);
        return saturate(c * (1.0 + vj * 0.20));
    }

    if (block_id == BLOCK_MOSS || block_id == BLOCK_GLOW_MOSS) {
        // Soft cushions: lumpy green; glowing moss is darker, with bright specks.
        float cl = tex_noise(fuv, 2.0, 61.0);
        float3 c = lerp(float3(0.10, 0.22, 0.05), float3(0.24, 0.42, 0.10), saturate(cl * 1.2 + (hd - 0.5) * 0.4));
        if (block_id == BLOCK_GLOW_MOSS) {
            // Glowing tips all over the cushion.
            c = lerp(c * 0.6, float3(0.45, 0.95, 0.75), smoothstep(0.55, 0.75, h));
        }
        return saturate(c * (1.0 + vj * 0.1));
    }

    if (block_id == BLOCK_DRIPSTONE) {
        // Tan rock streaked top to bottom by what dripped down it.
        float streak = hash31i(int3(tkey.x, 77, tkey.z));
        float n = tex_noise(fuv, 3.0, 63.0);
        float3 c = float3(0.52, 0.43, 0.33) * (0.80 + 0.25 * streak + 0.12 * n + (hd - 0.5) * 0.1);
        return saturate(c * (1.0 + vj * 0.06));
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

    if (block_is_door(block_id)) {
        // Oak planks running up the door in a darker frame; a middle rail,
        // two sunken panels below it, window panes above (see-through:
        // door_hit), an iron knob away from the hinge. Edges of the panel
        // are the frame's end grain.
        DoorShape ds = door_shape(block_id);
        int2  c  = door_texel(ds, hit_pos - nrm * 0.01 - float3(vkey));
        float th = hash31i(int3(vkey.x * 8 + c.x, c.y, vkey.z * 8 + c.x));
        float plank = hash31i(int3(vkey.x, c.x >> 1, vkey.z)); // two texels a plank
        float3 wood = float3(0.52, 0.36, 0.20) * (0.88 + 0.16 * plank) * (0.92 + 0.16 * lerp(0.5, th, detail));
        bool face = ds.along_x ? abs(nrm.z) > 0.5 : abs(nrm.x) > 0.5;
        if (!face) return saturate(wood * 0.8);
        bool frame = c.x == 0 || c.x == 7 || c.y == 0 || c.y == 23 || c.y == 11 || c.y == 12
                  || (c.y >= 13 && (c.x == 3 || c.x == 4));
        if (frame) wood *= 0.72;
        bool sunk = c.y >= 2 && c.y <= 9 && c.x >= 2 && c.x <= 5;
        if (sunk) wood *= 0.86;
        if (c.x == 6 && c.y == 12) return float3(0.10, 0.09, 0.09); // knob
        return saturate(wood * (1.0 + vj * 0.06));
    }

    if (block_is_micro(block_id)) {
        int3  mc = micro_hit_cell(vkey, hit_pos, nrm);
        float th = hash31i(vkey * MICRO + mc);
        if (block_id == BLOCK_FERN) {
            float3 c = lerp(float3(0.06, 0.20, 0.06), float3(0.16, 0.40, 0.11), float(mc.y) / 3.0);
            return saturate(c * (0.85 + 0.3 * lerp(0.5, th, detail)) * (1.0 + vj * 0.2));
        }
        if (block_id == BLOCK_FLOWER) {
            if (mc.y < 5) return float3(0.14, 0.34, 0.09) * (0.9 + 0.2 * th);
            if (mc.y == 6) return float3(0.40, 0.28, 0.05); // the eye
            // One colour per flower.
            uint k = uint(hash31i(vkey + int3(3, 7, 1)) * 6.0);
            float3 petal = k == 0u ? float3(0.85, 0.12, 0.10) : k == 1u ? float3(0.95, 0.80, 0.15)
                         : k == 2u ? float3(0.92, 0.92, 0.88) : k == 3u ? float3(0.55, 0.30, 0.85)
                         : k == 4u ? float3(0.30, 0.45, 0.95) : float3(0.95, 0.50, 0.70);
            return saturate(petal * (0.9 + 0.2 * th));
        }
        if (block_id == BLOCK_SEA_PICKLE) {
            // Pale lime capsules with brighter, glowing tips.
            return sea_pickle_tip(mc) ? float3(0.70, 0.95, 0.40) : float3(0.40, 0.62, 0.22) * (0.9 + 0.2 * th);
        }
        if (block_id == BLOCK_DRY_BUSH) {
            // Grey-brown twigs, paler toward their tips.
            return float3(0.36, 0.26, 0.15) * (0.8 + 0.4 * th) * lerp(0.85, 1.25, float(mc.y) / 5.0);
        }
        if (block_id == BLOCK_GLOW_MUSHROOM) {
            // Pale stems, caps that glow (block_emission does the glow).
            return glow_mushroom_stem(mc) ? float3(0.70, 0.75, 0.72) * (0.85 + 0.2 * th) : float3(0.55, 0.95, 1.0);
        }
        // Mushroom: a pale stem; a red cap with white spots, or a brown one.
        if (mc.y < 3) return float3(0.78, 0.75, 0.66) * (0.9 + 0.1 * th);
        bool red = hash31i(vkey + int3(9, 1, 4)) < 0.55;
        if (red) return th < 0.2 ? float3(0.92, 0.90, 0.84) : float3(0.62, 0.08, 0.05);
        return float3(0.42, 0.28, 0.16) * (0.85 + 0.3 * th);
    }

    if (block_is_cutout(block_id)) {
        // Plane texel (plant_texel): u along the plane = local x, v up.
        float3 lp = hit_pos - float3(vkey);
        int cu = clamp(int(lp.x * TEXELS), 0, TEXELS - 1);
        int cv = clamp(int(lp.y * TEXELS), 0, TEXELS - 1);
        float th = hash31i(int3(vkey.x * 8 + cu, vkey.y * 8 + cv, vkey.z));
        if (block_id == BLOCK_TALL_GRASS) {
            // The ground's own green (or straw on dry grass), lighter tips.
            float3 g = grass_tint(float2(vkey.xz));
            if (sample_voxel(float3(vkey) + float3(0.5, -0.5, 0.5)) == BLOCK_DRY_GRASS) g = lerp(g, float3(0.46, 0.40, 0.16), 0.85);
            float3 c = g * lerp(0.75, 1.25, float(cv) / 7.0);
            return saturate(c * (0.85 + 0.3 * lerp(0.5, th, detail)) * (1.0 + vj * 0.2));
        }
        if (block_id == BLOCK_ROOTS) {
            return float3(0.40, 0.30, 0.19) * (0.75 + 0.4 * th) * lerp(0.8, 1.1, float(cv) / 7.0);
        }
        if (block_id == BLOCK_KELP) {
            bool stalk = cu == 3 || cu == 4;
            float3 c = stalk ? float3(0.22, 0.24, 0.07) : float3(0.30, 0.38, 0.09);
            // Blades lighter toward their edge, a gas bladder now and then.
            if (!stalk && (cu == 0 || cu == 7)) c *= 1.2;
            if (stalk && th > 0.93) c = float3(0.45, 0.42, 0.12);
            return saturate(c * (0.85 + 0.3 * lerp(0.5, th, detail)) * (1.0 + vj * 0.15));
        }
        // Seagrass.
        float3 c = lerp(float3(0.10, 0.28, 0.08), float3(0.30, 0.55, 0.18), float(cv) / 7.0);
        return saturate(c * (0.85 + 0.3 * lerp(0.5, th, detail)) * (1.0 + vj * 0.2));
    }

    if (block_id == BLOCK_CORAL) {
        // One colour per reef head (smooth noise picks it, so a head is
        // mostly one colour), porous: polyp pits and bright tips.
        static const float3 coral_cols[6] = {
            float3(0.95, 0.36, 0.50), float3(0.98, 0.52, 0.20), float3(0.62, 0.30, 0.82),
            float3(0.96, 0.82, 0.28), float3(0.25, 0.58, 0.92), float3(0.92, 0.26, 0.24),
        };
        float  pick = vnoise2(float2(vkey.xz) * 0.31 + float(vkey.y) * 0.07 + 5.3);
        float3 c = coral_cols[min(int(pick * 6.0), 5)];
        float  pit = tex_noise(fuv, 1.5, 33.0);
        c *= lerp(1.0, pit < 0.35 ? 0.55 : (h > 0.85 ? 1.25 : 0.95), detail);
        if (top) c *= 1.1;
        return saturate(c * (1.0 + vj * 0.12));
    }

    if (block_id == BLOCK_STONE_BRICKS) {
        // Courses of bricks 8 texels long and 4 high (two courses per
        // voxel), staggered by half a brick, with dark mortar joints. Weathering by world position: moss creeps
        // over tops and the lower courses, lichen spots, soot-dark blocks.
        int3 bk = tkey;
        int  course = bk.y >> 2;
        int  along  = top ? bk.x : (abs(nrm.x) > 0.5 ? bk.z : bk.x);
        int  brick  = (along + (course & 1) * 4) >> 3;
        bool mortar = (bk.y & 3) == 0 || ((along + (course & 1) * 4) & 7) == 0;
        if (top) {
            int  row = bk.z >> 2;
            brick  = (bk.x + (row & 1) * 4) >> 3;
            mortar = (bk.z & 3) == 0 || ((bk.x + (row & 1) * 4) & 7) == 0;
            course = row;
        }
        float bh = hash31i(int3(brick, course, top ? 7 : (abs(nrm.x) > 0.5 ? bk.x : bk.z) >> 3));
        float3 c = float3(0.55, 0.54, 0.51) * (0.78 + 0.32 * bh) * (0.92 + (hd - 0.5) * 0.16);
        c *= lerp(float3(1, 1, 1), float3(1.06, 1.0, 0.90), step(0.8, bh)); // a few warm stones
        if (mortar) c = lerp(c, float3(0.30, 0.29, 0.27), detail * 0.85);
        float3 wp = (float3(tkey) + 0.5) / float(TEXELS);
        float moss = smoothstep(0.45, 0.75, tex_noise(fuv, 5.0, 19.0)) * (top ? 0.9 : 0.55);
        // Damp runs down the walls, vertically stretched like the rock streaks.
        if (!top) moss += 0.5 * smoothstep(0.62, 0.85, vnoise2(float2(fuv.x / 3.0, wp.y / 4.0) + 7.0));
        moss = saturate(moss);
        c = lerp(c, float3(0.20, 0.30, 0.10) * (0.8 + 0.4 * hd), moss * 0.85);
        if (h > 0.97 && detail > 0.3) c = lerp(c, float3(0.70, 0.72, 0.55), 0.6); // lichen
        return saturate(c * (1.0 + vj * 0.05));
    }

    if (block_id == BLOCK_CRYSTAL) {
        // Facets: bright veins on a deep amber body, a hot core per voxel.
        float facet = abs(tex_noise(fuv, 2.0, 71.0) * 2.0 - 1.0);
        float3 c = lerp(float3(0.95, 0.55, 0.16), float3(1.0, 0.88, 0.55), smoothstep(0.0, 0.25, 0.25 - facet));
        c *= 0.75 + 0.25 * hd;
        return saturate(c);
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
#define CLOUD_SHADOW_SCALE 1.0 // ground shadow vs. the cloud's own extinction: light scattered
                                 // through and around the cloud keeps its shadow from going black

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

// Sunlight left after the cumulus between p and the sun (1 = clear): the
// sun ray's optical depth through each cloud box it crosses, from a few
// shape-only density samples. The shape falls off smoothly toward the
// cloud edge, so the shadow edge is soft without extra taps. Most rays
// miss every box and only pay the box tests.
#define CLOUD_SHADOW_STEPS 4
float cloud_shadow(float3 p, float3 l) {
    if (u_thermal_count.x == 0 || (u_ent_debug & 20) != 0 || l.y < 0.02) return 1.0;
    float3 inv = 1.0 / ent_safe_dir(l);
    float od = 0.0;
    for (int i = 0; i < u_thermal_count.x; i++) {
        float4 th = u_thermals[i];
        float R = th.z * 1.4;
        float t0, t1;
        if (!ent_box(p, inv, float3(th.x - R, CUMULUS_BASE, th.y - R),
                     float3(th.x + R, CUMULUS_BASE + th.z * 1.75, th.y + R), t0, t1)) continue;
        t0 = max(t0, 0.0);
        if (t0 >= t1) continue;
        float dt = (t1 - t0) / CLOUD_SHADOW_STEPS;
        [unroll]
        for (int s = 0; s < CLOUD_SHADOW_STEPS; s++) {
            od += cloud_density(p + l * (t0 + (float(s) + 0.5) * dt), i, false) * dt;
        }
    }
    return exp(-od * CLOUD_SIGMA * CLOUD_SHADOW_SCALE);
}

// ---- Sunlight under water ------------------------------------------------------
// Sunlight reaching p under the sea: absorbed along its slanted path down
// from the surface, and focused by the waves into drifting caustic lines
// whose contrast fades with depth. 1 above water. All generated water tops
// out at SEA_LEVEL_Y, so the depth is taken from that; p must be in water
// (a watery voxel), which also keeps caves below sea level dry of it.
#define SUN_WATER_ABSORB 0.06 // per voxel of slanted path

// Bright net of lines (0..1) at sea-surface position xz.
float caustics(float2 xz) {
    float  t = u_time * 0.5;
    float2 q = xz * 0.45;
    [unroll]
    for (int i = 0; i < 2; i++) {
        q += float2(sin(q.y * 1.3 + t * (1.0 + 0.4 * i)), cos(q.x * 1.1 - t * (0.9 + 0.3 * i))) * 0.55;
    }
    float v = abs(sin(q.x) + sin(q.y)) * 0.5;
    return pow(1.0 - v, 6.0);
}

float underwater_sun(float3 p, float3 l) {
    if (p.y >= SEA_LEVEL_Y || !block_is_watery(sample_voxel(p))) return 1.0;
    float depth = SEA_LEVEL_Y - p.y;
    float ly    = max(l.y, 0.15);
    // Where this sunbeam crossed the surface (refraction steepens it).
    float2 at = p.xz + l.xz / ly * depth * 0.75;
    float  c  = lerp(1.0, 0.45 + 1.6 * caustics(at), exp(-depth * 0.05));
    return exp(-depth / ly * SUN_WATER_ABSORB) * c;
}

// Sky light under the sea: the voxel light lets it straight down through
// water at full strength, so it is darkened here instead, smoothly with
// depth, and turned blue-green (red goes first). 1 above water.
float3 underwater_light(float3 p) {
    if (p.y >= SEA_LEVEL_Y || !block_is_watery(sample_voxel(p))) return float3(1, 1, 1);
    float d = SEA_LEVEL_Y - p.y;
    return exp(-d * float3(0.075, 0.035, 0.028));
}

// Shading for an entity voxel hit: direct sun (with entity occlusion) plus
// the voxel light at the entity's surface. Entities are terminal hits (no
// reflection bounce) so the caller breaks after compositing the result.
float4 shade_entity(EntityHit ehit, float3 dir, float t_off) {
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
                  * cloud_shadow(so, l)
                  * underwater_sun(so, l)
                  * u_sun_intensity;
    }

    // Sky + torch light of the voxel just off the surface.
    uint   lv    = sample_light(int3(floor(P + N * 0.6)));
    float3 ambient = sky_ambient() * light_curve(float(light_sky(lv))) * underwater_light(P + N * 0.3) + MIN_AMBIENT;
    float3 torch   = block_radiance(lv, torch_flicker(P));

    float3 col = albedo * (ambient + sun + torch + hand_light(so, N, false));

    // Thin fabric (glider sail): lit from behind, the sun glows through it.
    if ((flags & PAL_THIN) != 0u && ndl < 0.0) {
        col += albedo * (-ndl) * 0.6 * u_sun_intensity * trace_shadow_transmittance(P - N * 0.1, l);
    }

    // Emissive voxels (crystals) glow on their own and trip bloom.
    if ((flags & PAL_EMIT) != 0u) {
        float pulse = 0.85 + 0.15 * sin(u_time * 3.0 + float(ehit.index));
        col += albedo * 4.0 * pulse;
    }
    return apply_fog(float4(col, 1.0), ehit.t + t_off, dir);
}

// ---- Water ------------------------------------------------------------------
// Water is a medium, not a surface: a view ray reaching water takes a
// Fresnel share of the reflected sky, then carries on through the water
// (skipping water voxels). Whatever it reaches next fades toward the water
// colour with the distance travelled under water.
#define WATER_ABSORB    0.075 // per voxel: ~13 voxels down it's mostly water colour
#define WATER_VIEW_DIST 56.0  // past this under water, only water colour is left (exp(-4.2))
#define WATER_HAZE_DIST 48.0  // seen from this far off, water is twice as murky

// Absorption per voxel under a surface t_surface from the camera. Far off,
// the glare and scatter at the surface hide what's under it: the water
// there reads as murkier, which also keeps the many far water pixels from
// walking deep into the sea (kelp forests make that slow).
float water_absorb(float t_surface) {
    return WATER_ABSORB * (1.0 + t_surface / WATER_HAZE_DIST);
}

static bool g_cam_in_water;

// The colour water fades to: lit from above, darker and bluer the deeper
// the camera is (seen from above, the surface's own).
float3 water_deep_color() {
    float3 c = float3(0.025, 0.11, 0.13) * (sky_ambient() + sun_tint() * (u_sun_intensity * 0.5 * sun_elevation()));
    if (g_cam_in_water) c *= exp(-max(SEA_LEVEL_Y - u_cam_pos.y, 0.0) * float3(0.06, 0.03, 0.025));
    return c;
}

// Wind waves for the surface normal: eight waves of different lengths and
// headings (spread around the wind, at angles that never line their crests
// up into a grid), each moving at its deep-water speed, so long swells roll
// slowly under fast short chop. A slow warp bends the crests, and drifting
// gust patches roughen some stretches while others lie nearly glassy.
// Normal from the analytic slope.
// Anti-aliasing: a wave smaller than a pixel's footprint on the water can't
// be shown, only flicker, so each wave fades out as the footprint along its
// heading reaches it (water_footprint) and its slope goes into `var`
// instead: the glint spreads by that much (water_reflection), as the many
// tiny waves inside one far pixel would spread it. var: slope variance
// (along the view, across it).
#define WAVE_SLOPE 0.11 // overall steepness
#define WAVE_COUNT 8
static const float4 g_waves[WAVE_COUNT] = { // heading (rad), wavelength (voxels), amplitude, phase
    float4( 0.10, 9.0, 0.30, 0.0),
    float4( 0.75, 5.3, 0.22, 1.7),
    float4(-0.55, 3.7, 0.16, 4.1),
    float4( 1.60, 2.3, 0.10, 2.3),
    float4(-1.20, 1.6, 0.07, 5.2),
    float4( 2.40, 1.1, 0.05, 0.9),
    float4(-2.05, 0.75, 0.035, 3.3), // chop: breaks the sun glint into glitter
    float4( 0.42, 0.5, 0.025, 1.1),
};

static float g_pix_angle; // radians per pixel, set in main

// Size (voxels) of a pixel on the water at p seen along dir, measured along
// wave heading d. Along the view it stretches by 1/sin(grazing angle), so
// far off even long swells running toward the camera are smaller than a
// pixel, while waves running across the view stay sharp.
float2 water_view_xz(float3 dir) {
    float l = length(dir.xz);
    return l > 1e-4 ? dir.xz / l : float2(1, 0);
}

float water_footprint(float3 p, float3 dir, float2 d) {
    float c = dot(d, water_view_xz(dir));
    float s = max(abs(dir.y), 0.03);
    return length(p - u_cam_pos) * g_pix_angle * sqrt(c * c / (s * s) + (1.0 - c * c));
}

// Share of a wave of wavelength lambda that can show: all of it from 1.5
// footprints per wave, none at 0.5. Waves just above a pixel still alias a
// little, but filtering them earlier leaves far water a flat mirror.
float wave_fade(float lambda, float fp) {
    return saturate(lambda / fp - 0.5);
}

float3 water_normal(float3 p, float3 dir, out float2 var) {
    float2 vh = water_view_xz(dir);
    float2 x = p.xz;
    x += (float2(vnoise2(x * 0.045 + u_time * 0.03), vnoise2(x * 0.045 + 31.7 - u_time * 0.025)) - 0.5) * 6.0;
    float2 g = float2(0, 0);
    float2 lost = float2(0, 0);
    [unroll]
    for (int i = 0; i < WAVE_COUNT; i++) {
        float4 w = g_waves[i];
        float2 d = float2(cos(w.x), sin(w.x));
        float  k = 6.2831853 / w.y;
        float  fade = wave_fade(w.y, water_footprint(p, dir, d));
        g += d * (w.z * k * fade * cos(dot(d, x) * k - sqrt(9.8 * k) * 0.6 * u_time + w.w));
        float  c = dot(d, vh);
        lost += float2(c * c, 1.0 - c * c) * (w.z * w.z * k * k * (1.0 - fade * fade));
    }
    float gust = lerp(0.35, 1.3, smoothstep(0.3, 0.7, vnoise2(p.xz * 0.02 + u_time * float2(0.04, 0.015))));
    g *= WAVE_SLOPE * gust;
    var = 0.5 * lost * (WAVE_SLOPE * gust) * (WAVE_SLOPE * gust); // mean of cos^2 = 1/2
    return normalize(float3(-g.x, 1.0, -g.y));
}

float water_fresnel(float3 dir, float3 n) {
    float c = saturate(-dot(dir, n));
    return 0.02 + 0.98 * pow(1.0 - c, 5.0);
}

// col seen through d voxels of water under a surface t_surface from the
// camera, with reflection share F of refl.
float3 water_mix(float3 col, float d, float t_surface, float3 dir, float F, float3 refl) {
    float3 deep = apply_fog(float4(water_deep_color(), 1.0), t_surface, dir).rgb;
    col = lerp(deep, col, exp(-d * water_absorb(t_surface)));
    return lerp(col, refl, F);
}

// Water reflects along a calmed normal: at grazing angles full ripples
// swirl the mirrored hills apart. Shared by near and far water.
#define REFL_RIPPLE 0.4

// Sun glint off the waves: the full ripple normal plus three fine crossing
// ripples (glint only), so the sun's reflection breaks into squiggly bright
// lines up close and a glittering path far off instead of one smooth blob.
// Shared by near and far water, so the glint carries on past the near
// region; shadow-tested (near only) where it shows.
#define GLINT_POWER 1500.0
#define GLINT_GAIN  25.0
#define GLINT_TILT  0.06  // fine ripple steepness

float3 water_glint(float3 p, float3 n, float2 wave_var, float3 dir, bool shadowed) {
    // Only the surface glints: a water cell's side faces (far tile steps,
    // falls) have no waves, and n.y = 0 would divide by zero below.
    if (n.y < 0.5) return float3(0, 0, 0);
    float3 l = light_dir_normalized;
    float2 tilt = float2(0, 0);
    float2 vh  = water_view_xz(dir);
    float2 var = wave_var;
    {
        static const float3 fine[3] = { float3(0.9, 0.62, 0.0), float3(-1.4, 0.43, 2.1), float3(2.6, 0.31, 4.4) }; // heading, wavelength, phase
        [unroll]
        for (int i = 0; i < 3; i++) {
            float2 d = float2(cos(fine[i].x), sin(fine[i].x));
            float  k = 6.2831853 / fine[i].y;
            float  fade = wave_fade(fine[i].y, water_footprint(p, dir, d));
            float  c = dot(d, vh);
            tilt += d * (fade * sin(dot(d, p.xz) * k - sqrt(9.8 * k) * 0.6 * u_time + fine[i].z));
            var  += float2(c * c, 1.0 - c * c) * (0.5 * GLINT_TILT * GLINT_TILT * (1.0 - fade * fade));
        }
    }
    float3 nf = normalize(n + float3(tilt.x, 0.0, tilt.y) * GLINT_TILT);
    // Lobe in normal space around the half vector: GLINT_POWER sets its base
    // width (cos^P of the reflected angle, which tilts twice as far as the
    // normal), widened along / across the view by the filtered-out wave
    // slopes, so a far glitter path stretches into a column. The peak drops
    // as the lobe widens to keep the same light.
    float3 hv = normalize(l - dir);
    float2 dn = hv.xz / max(hv.y, 0.05) - nf.xz / max(nf.y, 0.05); // slope offset to the facet that mirrors the sun
    float2 da = float2(dot(dn, vh), dot(dn, float2(-vh.y, vh.x)));
    float  s0 = 1.0 / (4.0 * GLINT_POWER);
    float2 sv = s0 + var;
    float  g = exp(-0.5 * (da.x * da.x / sv.x + da.y * da.y / sv.y)) * (s0 / sqrt(sv.x * sv.y))
             * GLINT_GAIN * u_sun_intensity * step(0.0, l.y);
    if (g < 0.01) return float3(0, 0, 0);
    // Far water has no voxels to shadow-test against.
    float3 o = p + float3(0.0, 0.01, 0.0);
    return sun_tint() * (g * (shadowed ? trace_shadow_transmittance(o, l) : 1.0) * cloud_shadow(o, l));
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
    if (id == BLOCK_BIRCH_LEAVES)  return float3(0.132, 0.233, 0.054);
    if (id == BLOCK_AUTUMN_LEAVES) return float3(0.300, 0.115, 0.030);
    if (id == BLOCK_BIRCH_LOG)     return float3(0.62, 0.60, 0.55);
    if (id == BLOCK_ACACIA_LOG)    return float3(0.30, 0.27, 0.24);
    if (id == BLOCK_ACACIA_LEAVES) return float3(0.110, 0.150, 0.040);
    if (id == BLOCK_WILLOW_LEAVES) return float3(0.150, 0.230, 0.070);
    if (id == BLOCK_DRY_GRASS)     return n.y > 0.5 ? float3(0.36, 0.32, 0.13) : DIRT_COLOR * 0.95;
    if (id == BLOCK_MOSS)          return float3(0.15, 0.30, 0.07);
    if (id == BLOCK_DRIPSTONE)     return float3(0.48, 0.40, 0.31);
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
    if (id == BLOCK_STONE_BRICKS)  return float3(0.40, 0.41, 0.36);
    if (id == BLOCK_TORCH)         return float3(0.45, 0.26, 0.10);
    if (id == BLOCK_CRYSTAL)       return float3(0.95, 0.65, 0.25);
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
        // As near water (water_reflection) minus the world reflection.
        float2 wv = float2(0, 0);
        float3 n = h.normal.y > 0.5 ? water_normal(h.hit_pos, dir, wv) : h.normal;
        float3 rd = reflect(dir, normalize(float3(n.x * REFL_RIPPLE, n.y, n.z * REFL_RIPPLE)));
        rd = normalize(float3(rd.x, max(rd.y, 0.01), rd.z));
        float3 refl = sky_color_impl(rd, light_dir_normalized, 0.0, 1.0, true) + water_glint(h.hit_pos, n, wv, dir, false);
        return apply_fog(float4(lerp(water_deep_color(), refl, water_fresnel(dir, n)), 1.0), h.t + t_off, dir);
    }
    float  j = hash31i(int3(h.cell.x, 7, h.cell.y)) - 0.5;
    float3 c = far_block_color(h.block_id, h.cell, h.normal, h.hit_pos.y);
    c *= 1.0 + j * 0.08;
    // Ground under a canopy is in the crown's shade: no sun, little sky.
    float sky = h.under_canopy ? 0.3 : 1.0;
    float sun = h.under_canopy ? 0.0 : saturate(dot(h.normal, light_dir_normalized));
    if (sun > 0.0) sun *= cloud_shadow(h.hit_pos, light_dir_normalized);
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
    float3 col = c * lighting;
    // A beacon fire or crystal on top of a far cell: a point of light that
    // carries across the valleys at night (faded less by haze than the
    // ground, as a bright light would be).
    if (h.normal.y > 0.5 && (h.block_id == BLOCK_TORCH || h.block_id == BLOCK_CRYSTAL)) {
        float fl = 0.85 + 0.15 * sin(u_time * 7.0 + float(h.cell.x * 13 + h.cell.y * 7));
        col += block_emission(h.block_id) * 0.5 * fl;
    }
    return apply_fog(float4(col, 1.0), h.t + t_off, dir);
}

// Where the primary ray's voxel walk stops: the near region's edge when far
// terrain is on (it takes over from there), else the full ray length.
float primary_max_len(float3 o, float3 d, out int exit_axis) {
    float t = near_exit_t(o, d, exit_axis);
    return u_far_enabled != 0 ? t : RAY_MAX_LENGTH;
}

// Shading for a voxel hit: voxel light (sky, torches), sun with its shadow
// ray, bounce light, emission, fog. t_acc: distance travelled before this
// ray segment. full_sun = shadow rays (soft when enabled, entities, clouds);
// the cheap path (reflections) has no AO and no shadow rays: the sun reaches
// whatever sees the open sky (full sky light).
float4 shade_voxel(HitInfo hit, float3 dir, float t_acc, bool ao_on, bool full_sun) {
    float4 hit_color = float4(
        voxel_surface_color(hit.block_id, hit.vkey, hit.hit_pos, hit.normal, hit.t + t_acc), 1.0);
    float3 albedo = hit_color.rgb;

    float3 hit_point   = hit.hit_pos;
    float3 surf_normal = hit.normal;
    float epsilon      = 0.01;

    // Voxel light in front of this face: sky (ambient + whether the
    // sun can reach at all) and block light (torches). A water plant's
    // planes cut through its own voxel, which holds the light.
    bool   plant = block_is_cutout(hit.block_id);
    bool   door  = block_is_door(hit.block_id); // its panel's lit by the light in its voxel too
    float  sky_level;
    float3 block_light;
    if (plant || door) {
        uint pl = sample_light(hit.vkey);
        sky_level   = float(light_sky(pl));
        block_light = block_radiance(pl, torch_flicker(hit_point));
    } else {
        sky_level = face_light(hit.vkey, surf_normal, hit_point, block_light);
    }
    float3 uw = underwater_light(hit_point + surf_normal * 0.05);
    float3 lighting = (sky_ambient() * light_curve(sky_level) * uw + MIN_AMBIENT
                    + block_light) * face_shade(surf_normal);

    // Sun. No sky light means sealed off from the sky (caves), so the
    // shadow ray is skipped there.
    float3 l = light_dir_normalized;
    float n_dot_l = dot(surf_normal, l);
    bool   blades = plant && !block_is_micro(hit.block_id); // small-voxel models have real faces
    if (blades) n_dot_l = abs(n_dot_l) * 0.7 + 0.3; // thin blades: lit from either side
    if (n_dot_l > 0.0 && sky_level > 0.0) {
        float3 shadow_origin = hit_point + surf_normal * epsilon;
        float shadow_factor = full_sun ? trace_shadow_transmittance(shadow_origin, l)
                                       : smoothstep(SKY_LIGHT_MAX - 3.0, SKY_LIGHT_MAX, sky_level);
        // Soft shadow: 5-tap disc within a small sun cone (~3 deg).
        // t0 is binary for solid occluders, so it can't detect
        // penumbra by itself; only taken near the camera.
        if (full_sun && (u_quality % 10) == 3 && hit.t + t_acc < 150.0) {
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
        if (full_sun && u_entity_count > 0 && shadow_factor > 0.0 && (u_ent_debug & 2) == 0) {
            shadow_factor *= entity_shadow_transmittance(shadow_origin, l, RAY_MAX_LENGTH);
        }
        if (full_sun && shadow_factor > 0.0) shadow_factor *= cloud_shadow(shadow_origin, l);
        if (shadow_factor > 0.0) shadow_factor *= underwater_sun(shadow_origin, l);
        lighting += sun_tint() * (n_dot_l * shadow_factor * u_sun_intensity);
    }
    // Sunlight bounced off the ground fills faces that look sideways
    // or down, so shadowed walls and overhangs keep some warmth and
    // shape instead of flat sky blue.
    lighting += bounce_light(surf_normal) * light_curve(sky_level) * uw;
    lighting += hand_light(hit_point + surf_normal * epsilon, surf_normal, blades);

    // Leaf backlit glow: sun behind the leaves tints them warm
    // yellow-green, scaled by how open to the sky they are.
    if (block_is_leaves(hit.block_id)) {
        float back_light = saturate(-n_dot_l);
        hit_color.rgb += float3(0.3, 0.45, 0.1) * back_light * light_curve(sky_level) * sun_tint();
    }

    float ao = (ao_on && !plant && !door) ? compute_ao(hit_point + surf_normal * epsilon, surf_normal, hit_point) : 1.0;
    hit_color.xyz *= lighting * ao;
    // Emissive blocks radiate on their own — NOT multiplied by
    // lighting/AO/shadow. Bright enough to trip the bloom threshold.
    // The texture shapes the glow: ember texels burn bright, the
    // charred wood between them only smoulders.
    float3 emis = block_emission(hit.block_id);
    if (hit.block_id == BLOCK_GLOW_MUSHROOM) {
        // Only the caps glow, and solid caps show far more surface than the
        // old crossed planes did: dimmer, or the bloom swallows them.
        emis *= glow_mushroom_stem(micro_hit_cell(hit.vkey, hit.hit_pos, hit.normal)) ? 0.0 : 0.3;
    } else if (hit.block_id == BLOCK_SEA_PICKLE) {
        // Solid too: the tips glow, the bodies only faintly.
        emis *= sea_pickle_tip(micro_hit_cell(hit.vkey, hit.hit_pos, hit.normal)) ? 0.45 : 0.1;
    }
    if (emis.x > 0.0) {
        float fl = 0.92 + 0.08 * sin(u_time * 9.0 + hash31i(hit.vkey) * 6.2831853);
        hit_color.rgb += emis * albedo * albedo * fl;
    }
    hit_color = apply_fog(hit_color, hit.t + t_acc, dir);
    return hit_color;
}

// What the water surface mirrors: one ray off it through the near voxels,
// then the far terrain, else the sky, shaded the cheap way (no AO, no shadow
// rays, no entities). Looking steeply down the Fresnel share is a few
// percent and the sky stands in, faded in over REFL_MIN_F..REFL_FULL_F (of
// the flat surface, so the cutoff doesn't flicker with the waves). A
// pixel's AA samples meet the same stretch of water, so the first sample's
// reflection is reused.
#define REFL_MIN_F  0.04
#define REFL_FULL_F 0.08
static bool   g_refl_cached;
static float3 g_refl;

float3 water_reflection(float3 p, float3 n, float2 wave_var, float3 dir, float t_surf, bool cacheable) {
    float3 o = p + float3(0.0, 0.01, 0.0);
    float3 glint = water_glint(p, n, wave_var, dir, true);

    if (cacheable && g_refl_cached) return g_refl + glint;
    float3 rd = reflect(dir, normalize(float3(n.x * REFL_RIPPLE, n.y, n.z * REFL_RIPPLE)));
    rd.y = max(rd.y, 0.01); // ripples can tip a grazing reflection under the surface
    rd = normalize(rd);
    // No sun (or moon) disc: through the calmed normal it mirrors as one
    // smooth blob; the glint stands in for it.
    float3 c = apply_fog(float4(sky_color_impl(rd, light_dir_normalized, 0.0, 1.0, true), 1.0), t_surf, dir).rgb;
    float  Ff = water_fresnel(dir, float3(0.0, 1.0, 0.0));
    if (Ff >= REFL_MIN_F && (u_ent_debug & 8) == 0) {
        int exit_axis;
        float near_len = primary_max_len(o, rd, exit_axis);
        HitInfo h = trace_ray_chunk(o, rd, false, RAY_ITERATIONS, near_len, BLOCK_WATER);
        float3 w = c;
        if (h.block_id != 0u) {
            w = shade_voxel(h, rd, t_surf, false, false).rgb;
        } else if (u_far_enabled != 0) {
            FarHit fh = far_trace(o, rd, near_len, exit_axis);
            if (fh.hit) w = shade_far(fh, rd, t_surf).rgb;
        }
        c = lerp(c, w, smoothstep(REFL_MIN_F, REFL_FULL_F, Ff));
    }
    if (cacheable) { g_refl = c; g_refl_cached = true; }
    return c + glint;
}

// ---- View rays ------------------------------------------------------------------
// A view ray from the camera. A water plant right at the eye (swimming
// through kelp) would fill the screen with one blade, so plants closer
// than PLANT_NEAR_CLIP are passed through like geometry in front of a
// near plane.
#define PLANT_NEAR_CLIP 0.6
HitInfo trace_view_ray(float3 o, float3 d, float max_len, uint skip) {
    HitInfo h = trace_ray_chunk(o, d, false, RAY_ITERATIONS, max_len, skip);
    float t0 = 0.0;
    for (int k = 0; k < 3 && block_is_cutout(h.block_id) && t0 + h.t < PLANT_NEAR_CLIP; k++) {
        t0 += h.t + 0.02;
        h = trace_ray_chunk(o + d * t0, d, false, RAY_ITERATIONS, max_len - t0, skip);
    }
    h.t += t0;
    return h;
}

// ---- The sea surface from below -------------------------------------------------
// Distance along a ray under water to the open sea surface above it (the
// air over SEA_LEVEL_Y), or 1e30 if it doesn't rise to one.
float water_surface_t(float3 o, float3 d) {
    if (d.y <= 0.0 || o.y >= SEA_LEVEL_Y) return 1e30;
    float ts = (SEA_LEVEL_Y - o.y) / d.y;
    float3 ps = o + d * ts;
    return sample_voxel(ps + float3(0.0, 0.5, 0.0)) == 0u ? ts : 1e30;
}

// The surface seen from below at ps. Inside Snell's window (within ~49
// degrees of straight up) the world above shows through, squeezed toward
// the zenith by refraction: the bent ray is traced and shaded the cheap
// way (no entities: the screen-tile entity lists only hold for straight
// rays). Outside it the surface is a mirror (total internal reflection)
// that shows the water, which at that range is mostly its own colour.
float3 water_surface_below(float3 ps, float3 dir, float t_surf) {
    float2 wv;
    float3 n  = water_normal(ps, dir, wv);
    float3 rr = refract(dir, -n, 1.333);
    float3 mirror = water_deep_color();
    if (dot(rr, rr) < 1e-4) return mirror;
    rr = normalize(rr);
    float F = 0.02 + 0.98 * pow(1.0 - saturate(dot(rr, n)), 5.0);
    float3 o = ps + float3(0.0, 0.02, 0.0);
    int exit_axis;
    float near_len = primary_max_len(o, rr, exit_axis);
    HitInfo h = trace_ray_chunk(o, rr, false, RAY_ITERATIONS, near_len, BLOCK_WATER);
    float3 c;
    if (h.block_id != 0u) {
        c = shade_voxel(h, rr, t_surf, false, false).rgb;
    } else {
        FarHit fh;
        fh.hit = false;
        if (u_far_enabled != 0) fh = far_trace(o, rr, near_len, exit_axis);
        c = fh.hit ? shade_far(fh, rr, t_surf).rgb : sky_color(rr).rgb;
    }
    return lerp(c, mirror, F);
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
            // From above only the (1 - F) let through the surface shows, so
            // stop where that has faded to 3% (at a grazing angle, soon).
            float view = WATER_VIEW_DIST;
            if (i > 0) view = min(view, log(max(1.0 - water_F, 0.03) / 0.03) / water_absorb(t_acc));
            if (i == 0) hit = trace_view_ray(origin, dir, view, skip);
            else        hit = trace_ray_chunk(origin, dir, false, RAY_ITERATIONS, view, skip);
        } else if (bounce == 0) {
            int exit_axis;
            float near_len = primary_max_len(origin, dir, exit_axis);
            if (i == 0) hit = trace_view_ray(origin, dir, near_len, skip);
            else        hit = trace_ray_chunk(origin, dir, false, RAY_ITERATIONS, near_len, skip);
            if (hit.block_id == 0u && u_far_enabled != 0) far_hit = far_trace(origin, dir, near_len, exit_axis);
        } else {
            hit = trace_ray_chunk(origin, dir, false, RAY_ITERATIONS, RAY_MAX_LENGTH, skip);
        }
        float hit_t = hit.block_id != 0u ? hit.t : (far_hit.hit ? far_hit.t : RAY_MAX_LENGTH);

        // Under water, rising to the open surface before hitting anything.
        float surf_t = in_water ? water_surface_t(origin, dir) : 1e30;
        if (surf_t < hit_t) hit_t = surf_t;

        // Entities compete with the voxel hit along the view ray, also past
        // the water surface (fish seen from the shore): the ray goes on
        // straight until a solid bounce, so the screen-tile entity lists
        // still hold. The voxel hit caps the trace so occluded entities exit
        // on the AABB test.
        if ((i == 0 || (in_water && bounce == 0)) && u_entity_count > 0 && (u_ent_debug & 1) == 0) {
            EntityHit ehit;
            if (i == 0 && use_hit0) ehit = ehit0;
            else                    ehit = trace_entities(origin, dir, hit_t);
            if (ehit.index >= 0 && ehit.t < hit_t) {
                float4 c = shade_entity(ehit, dir, t_acc);
                if (in_water) c.rgb = water_mix(c.rgb, ehit.t, t_acc, dir, water_F, water_refl);
                pixel_color = lerp(pixel_color, c, reflection_amount);
                break; // terminal: entities don't spawn reflection bounces in v1
            }
        }

        if (surf_t <= hit_t && surf_t < 1e29) {
            float3 c = water_surface_below(origin + dir * surf_t, dir, t_acc + surf_t);
            c = water_mix(c, surf_t, t_acc, dir, water_F, water_refl);
            pixel_color = lerp(pixel_color, float4(c, 1.0), reflection_amount);
            break;
        }

        if (hit.block_id == BLOCK_WATER) {
            // Into the water: keep the reflection, carry on underneath.
            float2 wave_var = float2(0, 0);
            float3 n   = hit.normal.y > 0.5 ? water_normal(hit.hit_pos, dir, wave_var) : hit.normal;
            water_F    = water_fresnel(dir, n);
            water_refl = water_reflection(hit.hit_pos, n, wave_var, dir, t_acc + hit.t, bounce == 0);
            in_water   = true;
            t_acc     += hit.t;
            origin     = hit.hit_pos + dir * 0.01;
            continue;
        }

        // Too deep under water to show through: skip shading it.
        if (in_water && hit.block_id != 0u && exp(-hit.t * water_absorb(t_acc)) < 0.03) {
            hit.block_id = 0u;
            far_hit.hit  = false;
        }

        if (hit.block_id != 0u) {
            float4 hit_color = shade_voxel(hit, dir, t_acc, bounce == 0 && !in_water, true);
            float3 hit_point   = hit.hit_pos;
            float3 surf_normal = hit.normal;
            float  epsilon     = 0.01;
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
    g_cam_in_water = block_is_watery(sample_voxel(u_cam_pos));
    g_refl_cached  = false;
    g_pix_angle    = 2.0 * length(u_cam_right) / dims.x;
    ent_set_pixel(uint2(ipix));
    HitInfo hit0 = trace_view_ray(u_cam_pos, cdir, g_cam_in_water ? WATER_VIEW_DIST : near_len,
                                  g_cam_in_water ? BLOCK_WATER : 0u);
    FarHit far0;
    far0.hit = false;
    if (hit0.block_id == 0u && u_far_enabled != 0 && !g_cam_in_water) far0 = far_trace(u_cam_pos, cdir, near_len, exit_axis);
    float hit0_t = hit0.block_id != 0u ? hit0.t : (far0.hit ? far0.t : 1e30);
    // Entities on the center ray: shared by AA sample 0 and merged into the
    // depth output (volumetric clamp + composite bilateral upscale read it).
    if (g_cam_in_water) hit0_t = min(hit0_t, water_surface_t(u_cam_pos, cdir));
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
