// Volumetric god-ray pass. Runs at HALF resolution. For each half-res pixel:
// reconstruct the world ray, read scene depth (full-res, point-sampled) to
// clamp march length, march u_vol%100 dithered steps, and at each step add
// in-scattered sunlight weighted by a Henyey-Greenstein phase, using the
// shared trace_shadow_transmittance for per-step sun visibility (this is what
// carves the shafts where geometry/leaves block the sun). Output: half-res
// RGB inscatter, composited later by composite.hlsl. Teardown-style stack:
// half-res + low steps + dither + phase, additive over the existing fog.
// SPIR-V/SDL3 space0 order: RO storage TEXTURE first (t0), then the 4
// voxel RO storage buffers (t1..t4). RW: vol_output (u0). Shared
// constants/functions included AFTER these decls.
Texture2D<float>          depth_input : register(t0, space0); // full-res primary dist
StructuredBuffer<uint>    voxel_chunk  : register(t1, space0);
StructuredBuffer<int>     chunk_index  : register(t2, space0);
StructuredBuffer<int2>    chunk_owner  : register(t3, space0);
StructuredBuffer<uint>    voxel_mask   : register(t4, space0);

RWTexture2D<float4>       vol_output  : register(u0, space1); // half-res inscatter

#include "camera_uniforms.hlsl"

#include "voxel_common.hlsl"

// Henyey-Greenstein phase (forward scatter toward the sun).
float hg_phase(float cos_t, float g) {
    float g2 = g * g;
    float d  = 1.0 + g2 - 2.0 * g * cos_t;
    return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(d, 1e-4), 1.5));
}

// White-noise hash dither in [0,1). Random speckle (no repeating grid) is
// less objectionable than a structured pattern over smooth sky; the heavy
// variance is removed at the source by clamping the sky-ray march distance.
float dither(uint2 p) {
    uint n = (p.x * 1973u + p.y * 9277u) * 26699u;
    n = (n ^ (n >> 15u)) * 0x2c1b3c6du;
    n =  n ^ (n >> 12u);
    return float(n & 0xFFFFu) / 65536.0;
}

#define VOL_DENSITY     0.009   // uniform participating-media density (tuned down)
#define VOL_HG_G        0.62    // forward-scatter anisotropy
#define VOL_INTENSITY   1.0     // overall shaft brightness (tuned down from 1.35)

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    int steps = u_vol % 100;
    if (u_vol < 100 || steps <= 0) {           // disabled → emit nothing
        vol_output[int2(id.xy)] = float4(0,0,0,0);
        return;
    }

    uint hw, hh;
    vol_output.GetDimensions(hw, hh);
    if (id.x >= hw || id.y >= hh) return;

    // Reconstruct the world ray for this half-res pixel (full-res NDC).
    float2 dims = float2(hw, hh) * 2.0;
    float2 pixel = float2(id.xy) * 2.0 + 1.0;       // center of the 2x2 block
    float nx =  (pixel.x * 2.0 - dims.x) / dims.x;
    float ny = -(pixel.y * 2.0 - dims.y) / dims.y;
    float3 ro = u_cam_pos;
    float3 rd = normalize(u_cam_fwd + nx * u_cam_right + ny * u_cam_up);

    // Scene depth (full-res, point sampled at the block's top-left).
    // Clamp the march hard: for SKY pixels scene_t = 1e30, and marching the
    // full 1024 in ~16-24 steps makes the per-sample gap huge → severe
    // dither variance exactly where it's most visible. Distant inscatter is
    // hidden by fog anyway, so a much shorter cap costs ~nothing visually
    // and collapses the noise at its source.
    #define VOL_MARCH_MAX 320.0
    float scene_t = depth_input.Load(int3(int(pixel.x), int(pixel.y), 0));
    float march_len = min(scene_t, VOL_MARCH_MAX);
    if (march_len <= 0.0) { vol_output[int2(id.xy)] = float4(0,0,0,0); return; }

    float3 L      = normalize(u_light_dir_raw);
    float  cos_t  = dot(rd, L);
    float  phase  = hg_phase(cos_t, VOL_HG_G);

    float accum;
    bool  is_sky = (scene_t >= VOL_MARCH_MAX);

    if (is_sky) {
        // No occluder along the view ray → the inscatter integral over a
        // uniform fully-lit medium is CLOSED-FORM: ∫ρ·e^(−tρ)dt = 1−e^(−Lρ).
        // Zero march steps ⇒ zero step-banding, and nearly free. A single
        // mid-ray shadow sample broadly fades the glow where the sky column
        // sits behind the canopy edge (1 ray, so still no step pattern).
        float base = 1.0 - exp(-march_len * VOL_DENSITY);
        float vis  = trace_shadow_transmittance(ro + rd * (march_len * 0.5), L);
        accum = base * vis;
    } else {
        // Occluded view ray (canopy/terrain) → real god-ray structure here,
        // so march it (this is where the volumetric earns its cost and
        // looked good). Dither breaks the banding because the per-step
        // sun-visibility varies, decorrelating adjacent pixels.
        float seg    = march_len / float(steps);
        float jitter = dither(id.xy);
        float a = 0.0;
        [loop]
        for (int s = 0; s < steps; s++) {
            float t = (float(s) + jitter) * seg;
            float vis = trace_shadow_transmittance(ro + rd * t, L);
            if (vis > 0.0) a += vis * exp(-t * VOL_DENSITY) * VOL_DENSITY * seg;
        }
        accum = a;
    }

    float3 shaft = accum * phase * VOL_INTENSITY * sun_tint_d(L) * (u_sun_intensity / 1.9);
    // Damp sun shafts underground so the closed-form sky term can't glow
    // through cave ceilings near the surface.
    shaft *= lerp(1.0, 0.25, u_cave_factor);

    vol_output[int2(id.xy)] = float4(shaft, 1.0);
}
