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

#define BLOOM_INTENSITY 0.35

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
    img_output[p] = float4(tone_map(c.rgb + inscatter + bloom * BLOOM_INTENSITY), c.a);
}
