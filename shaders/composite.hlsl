// Composite pass (full resolution). Depth-aware ("bilateral") upscale of the
// half-res volumetric inscatter, added on top of the main color image, then
// ACES tone mapping — the inscatter add happens in linear HDR so bright sky
// + god rays roll off instead of clipping to white. The depth weighting stops
// god-ray light bleeding across object silhouettes (the reason the half-res
// buffer needs scene depth). Volumetric disabled → tone map only.
// Composite needs no voxel buffers/functions. space0: 2 RO storage textures
// (t0,t1), no buffers. RW: img_output (u0). Only u_vol from the cbuffer.
Texture2D<float4>   vol_input  : register(t0, space0); // half-res inscatter
Texture2D<float>    depth_input: register(t1, space0); // full-res primary dist
Texture2D<float4>   bloom_input: register(t2, space0); // half-res blurred highlights

RWTexture2D<float4> img_output : register(u0, space1); // full-res scene color (in/out)

#define BLOOM_INTENSITY   0.35
#define GRADE_SATURATION  1.05
#define GRADE_CONTRAST    1.06
#define VIGNETTE          0.30

#include "camera_uniforms.hlsl"

// ACES filmic tone mapping (approximation by Krzysztof Narkowicz)
float3 tone_map(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint w, h;
    img_output.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;

    int2 p = int2(id.xy);

    float3 inscatter = float3(0, 0, 0);
    if (u_vol >= 100) {
        float center_t = depth_input.Load(int3(p, 0));

        // Tight 2x2 bilinear + bilateral (depth) upscale — NO blur. A wide blur
        // smears any structured dither into a worse periodic smudge over smooth
        // sky; the grain is killed at the source instead (clamped sky march).
        float2 hcoord = float2(p) * 0.5;
        int2   hb     = int2(floor(hcoord - 0.5));
        float2 f      = (hcoord - 0.5) - float2(hb);

        float3 sum = float3(0,0,0);
        float  wsum = 0.0;
        [unroll]
        for (int dy = 0; dy < 2; dy++) {
            [unroll]
            for (int dx = 0; dx < 2; dx++) {
                int2 hc = hb + int2(dx, dy);
                float wx = (dx == 0) ? (1.0 - f.x) : f.x;
                float wy = (dy == 0) ? (1.0 - f.y) : f.y;
                float ws = wx * wy;
                float st = depth_input.Load(int3(hc * 2, 0));
                float dd = abs(st - center_t) / max(center_t, 1.0);
                float wd = exp(-dd * 12.0);
                float wgt = ws * wd + 1e-5;
                sum  += vol_input.Load(int3(hc, 0)).rgb * wgt;
                wsum += wgt;
            }
        }
        inscatter = sum / wsum;
    }

    // Bloom: plain 4-tap bilinear upsample of the half-res blurred highlights
    // (low-frequency by construction — no depth weighting needed).
    float3 bloom;
    {
        float2 hcoord = float2(p) * 0.5;
        int2   hb     = int2(floor(hcoord - 0.5));
        float2 f      = (hcoord - 0.5) - float2(hb);
        float3 b00 = bloom_input.Load(int3(hb,             0)).rgb;
        float3 b10 = bloom_input.Load(int3(hb + int2(1,0), 0)).rgb;
        float3 b01 = bloom_input.Load(int3(hb + int2(0,1), 0)).rgb;
        float3 b11 = bloom_input.Load(int3(hb + int2(1,1), 0)).rgb;
        bloom = lerp(lerp(b00, b10, f.x), lerp(b01, b11, f.x), f.y);
    }

    float4 c = img_output[p];
    float3 c2 = tone_map((c.rgb + inscatter + bloom * BLOOM_INTENSITY) * u_exposure);
    // Gentle grade: slight saturation push + contrast S-curve around mid-gray.
    float lum = dot(c2, float3(0.2126, 0.7152, 0.0722));
    c2 = lerp(lum.xxx, c2, GRADE_SATURATION);
    c2 = saturate((c2 - 0.5) * GRADE_CONTRAST + 0.5);
    // Night vision: colour fades and shifts blue in moonlight (scotopic),
    // except for bright things (torches keep their warmth).
    float night = u_sun_true.w * (1.0 - smoothstep(0.25, 0.7, lum));
    c2 = lerp(c2, lum * float3(0.80, 0.92, 1.18), night * 0.65);
    // Split toning: shadows lean cool, highlights warm (sunlit vs sky-lit).
    c2 *= lerp(float3(0.96, 0.99, 1.05), float3(1.03, 1.0, 0.95), smoothstep(0.1, 0.8, lum));
    // Vignette: corners ~15% darker, pulls the eye to the centre.
    float2 uv = (float2(p) + 0.5) / float2(w, h) - 0.5;
    c2 *= 1.0 - VIGNETTE * dot(uv, uv);
    // Dither to break 8-bit banding in the sky gradient and vignette.
    float dn = frac(52.9829189 * frac(dot(float2(p), float2(0.06711056, 0.00583715))));
    c2 = saturate(c2 + (dn - 0.5) / 255.0);
    img_output[p] = float4(c2, c.a);
}
