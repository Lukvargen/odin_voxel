// Voxel raytracer compute shader.
// Two-level DDA traversal lives in voxel_common.hlsl; this pass does primary
// rays + direct lighting + AO, and samples the world-space GI irradiance
// cache (filled by gi_update.hlsl) for ambient.

// ---- Bindings ---------------------------------------------------------------
// SPIR-V/SDL3 space0 order: RO storage bufs (t0..t4): voxel data + GI cache.
// RW textures (set 1): img_output (u0), depth_output (u1).
// Shared constants/functions come from voxel_common.hlsl AFTER these decls.
StructuredBuffer<uint>     voxel_chunk      : register(t0, space0);
StructuredBuffer<int>      chunk_index      : register(t1, space0);
StructuredBuffer<int2>     chunk_owner      : register(t2, space0);
StructuredBuffer<uint>     voxel_mask       : register(t3, space0);
StructuredBuffer<uint>     gi_cache         : register(t4, space0);

RWTexture2D<float4>        img_output        : register(u0, space1);
RWTexture2D<float>         depth_output      : register(u1, space1); // primary-hit dist, 1e30 = sky

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
    float  u_gi_alpha;
    int3   u_gi_cache_origin;
    int    u_gi_epoch;
    float  u_time;
    float3 _pad6;
};

#define HAS_GI_CACHE
#include "voxel_common.hlsl"

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

float4 apply_fog(float4 color, float dist, float3 ray_dir) {
    float fog_factor = clamp(exp(-pow(dist * 0.0012, 2.0)), 0.0, 1.0);
    // Fog color matches the horizon sky tint toward the ray direction
    float4 fog_color = sky_color(normalize(ray_dir));
    // Tint fog slightly warm near the sun
    float sun_dot = dot(normalize(ray_dir), light_dir_normalized);
    fog_color.rgb = lerp(fog_color.rgb, fog_color.rgb * sun_tint(), smoothstep(0.5, 1.0, sun_dot) * 0.5);
    return lerp(fog_color, color, fog_factor);
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

    if (block_id == BLOCK_GRASS) {
        // Meadow tint: deep green <-> warm yellow-green over ~75 voxels.
        float  m     = fbm2(float2(vkey.xz) * 0.013);
        float3 grass = lerp(float3(0.10, 0.48, 0.06), float3(0.27, 0.52, 0.09), m);
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

        float3 c = on_grass
            ? grass * (0.84 + 0.28 * h) + h3 * float3(0.02, 0.05, 0.02)
            : dirt  * (0.80 + 0.34 * h) + h3 * float3(0.05, 0.03, 0.02);
        return saturate(c * (1.0 + vj * 0.08));
    }

    if (block_id == BLOCK_LOG) {
        float3 c;
        if (abs(nrm.y) > 0.5) {
            // Cut end: lighter heartwood.
            c = float3(0.52, 0.40, 0.22) * (0.85 + 0.25 * h);
        } else {
            // Bark: vertical striping — column brightness keyed on horizontal
            // texel coords only, so stripes run continuously up the trunk.
            float col = hash31i(int3(tkey.x, 1717, tkey.z));
            c = float3(0.36, 0.23, 0.10) * (0.62 + 0.55 * col) * (0.90 + 0.20 * h);
        }
        return saturate(c * (1.0 + vj * 0.08));
    }

    if (block_id == BLOCK_LEAVES) {
        // Two-tone dapple + stronger per-voxel variety for canopy depth.
        float3 c = (h < 0.45) ? float3(0.09, 0.35, 0.05) : float3(0.16, 0.50, 0.08);
        c *= 0.90 + 0.20 * hash31i(tkey + 31);
        return saturate(c * (1.0 + vj * 0.20));
    }

    // Stone: gray grain with scattered darker pits.
    float3 c = float3(0.55, 0.55, 0.56) * (0.82 + 0.30 * h) + h3 * 0.04;
    if (h < 0.07) c *= 0.78;
    return saturate(c * (1.0 + vj * 0.10));
}

// ---- Main -------------------------------------------------------------------

#define AA_SAMPLES 4

// Sub-pixel offsets (in pixel units). Sample 0 is the pixel CENTER so it can
// share the primary trace already done in main() for GI/depth (see use_hit0).
static const float2 aa_offsets[4] = {
    float2( 0.0,    0.0  ),
    float2( 0.125, -0.375),
    float2( 0.375,  0.125),
    float2(-0.125,  0.375),
};

// hit0/use_hit0: precomputed primary hit for the center ray — when set, the
// first bounce of this sample skips its trace_ray_chunk entirely.
float4 trace_pixel(float2 pixel, float2 dims, float3 gi_irr, HitInfo hit0, bool use_hit0) {
    float3 origin = u_cam_pos;
    float nx = (pixel.x * 2.0 - dims.x) / dims.x;
    float ny = -(pixel.y * 2.0 - dims.y) / dims.y;
    float3 dir = normalize(u_cam_fwd + nx * u_cam_right + ny * u_cam_up);

    float4 pixel_color = sky_color(normalize(dir));
    float reflection_amount = 1.0;

    for (int i = 0; i < u_reflect_amount; i++) {
        HitInfo hit;
        if (i == 0 && use_hit0) hit = hit0;
        else                    hit = trace_ray_chunk(origin, dir, false);
        if (hit.block_id != 0u) {
            float4 hit_color = float4(
                voxel_surface_color(hit.block_id, hit.vkey, hit.hit_pos, hit.normal), 1.0);

            float3 hit_point   = hit.hit_pos;
            float3 surf_normal = hit.normal;
            float3 looking_dir = u_cam_fwd;
            float epsilon      = 0.01;

            // Distance-based shadow LOD: only 1 ray beyond 150 units (fog hides the difference)
            float3 lighting;
            {
                float3 l = light_dir_normalized;
                float3 shadow_origin = hit_point + surf_normal * epsilon;
                float3 tangent   = normalize(abs(l.x) > 0.9 ? float3(0,1,0) : float3(1,0,0));
                tangent          = normalize(cross(tangent, l));
                float3 bitangent = cross(l, tangent);
                float t0 = trace_shadow_transmittance(shadow_origin, normalize(l));
                float shadow_factor;
                // Soft shadow: 5-tap Poisson disc within a small sun cone (~3 deg radius).
                // spread = tan(3 deg) ~= 0.052. Always taken in soft mode within range —
                // t0 is binary for solid occluders, so it can't detect penumbra by itself.
                if ((u_quality % 10) == 3 && hit.t < 150.0) {
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
                // GI on:  ambient from the world-space irradiance cache, in full
                //         RGB (bounce light carries color). Primary hits use the
                //         precomputed gi_irr; reflection bounces sample directly.
                // GI off: no ambient (pure direct only) so you can see exactly what GI adds
                float3 ambient = float3(0.0, 0.0, 0.0);
                if (u_gi_enabled != 0) {
                    ambient = (i == 0 && use_hit0)
                        ? gi_irr
                        : sample_gi_cache(hit_point + surf_normal, surf_normal);
                }
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

    // 1. Trace the center primary ray ONCE — it feeds depth, the GI lookup,
    // and AA sample 0 (whose offset is the pixel center).
    float2 pf  = float2(ipix);
    float  cnx = (pf.x * 2.0 - dims.x) / dims.x;
    float  cny = -(pf.y * 2.0 - dims.y) / dims.y;
    float3 cdir = normalize(u_cam_fwd + cnx * u_cam_right + cny * u_cam_up);
    HitInfo hit0 = trace_ray_chunk(u_cam_pos, cdir, false);
    float prim_depth = (hit0.block_id != 0u) ? hit0.t : 1e30;

    // 2. Ambient for the primary surface from the world-space irradiance
    // cache (smooth trilinear gradient — no per-pixel GI rays).
    float3 gi_irr = float3(GI_FALLBACK, GI_FALLBACK, GI_FALLBACK);
    if (u_gi_enabled != 0 && hit0.block_id != 0u) {
        gi_irr = sample_gi_cache(hit0.hit_pos + hit0.normal * 1.0, hit0.normal);
    }

    // 3. AA loop — u_quality packs: AA = u_quality/10, shadow mode = u_quality%10
    int aa = clamp(u_quality / 10, 1, AA_SAMPLES);
    float4 color = float4(0, 0, 0, 0);
    for (int s = 0; s < aa; s++) {
        color += trace_pixel(float2(ipix) + aa_offsets[s], dims, gi_irr, hit0, s == 0);
    }
    color /= float(aa);

    img_output[ipix]   = color;
    depth_output[ipix] = prim_depth;
}
