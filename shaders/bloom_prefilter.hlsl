// Bloom pass 1/3: downsample the full-res linear-HDR scene to half res and
// keep only the energy above BLOOM_THRESHOLD (normalized so the kept color
// keeps its hue). Output feeds the separable gaussian (bloom_blur.hlsl);
// composite adds the result back before tone mapping.
Texture2D<float4>   scene_input : register(t0, space0); // full-res linear HDR
RWTexture2D<float4> bloom_out   : register(u0, space1); // half-res

#define BLOOM_THRESHOLD 1.1

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint w, h;
    bloom_out.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;

    int2 fp = int2(id.xy) * 2;
    float3 c = 0.25 * (scene_input.Load(int3(fp,             0)).rgb +
                       scene_input.Load(int3(fp + int2(1,0), 0)).rgb +
                       scene_input.Load(int3(fp + int2(0,1), 0)).rgb +
                       scene_input.Load(int3(fp + int2(1,1), 0)).rgb);

    float l = max(c.r, max(c.g, c.b));
    float contrib = max(0.0, l - BLOOM_THRESHOLD) / max(l, 1e-4);
    bloom_out[int2(id.xy)] = float4(c * contrib, 1.0);
}
