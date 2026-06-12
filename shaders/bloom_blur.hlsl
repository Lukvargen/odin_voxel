// Bloom pass 2+3/3: separable 9-tap gaussian at half res. Compiled TWICE by
// build.bat — with -DHORIZONTAL=1 into bloom_blur_h.spv and without into
// bloom_blur_v.spv — so the direction is baked in and no per-dispatch uniform
// juggling is needed (the shared CameraUniforms push stays untouched).
Texture2D<float4>   blur_input  : register(t0, space0);
RWTexture2D<float4> blur_output : register(u0, space1);

static const float wgt[5] = { 0.227027, 0.194594, 0.121622, 0.054054, 0.016216 };

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint w, h;
    blur_output.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;

    int2 p  = int2(id.xy);
    int2 mx = int2(int(w) - 1, int(h) - 1);

    float3 acc = blur_input.Load(int3(p, 0)).rgb * wgt[0];
    [unroll]
    for (int i = 1; i < 5; i++) {
#ifdef HORIZONTAL
        int2 o = int2(i, 0);
#else
        int2 o = int2(0, i);
#endif
        acc += blur_input.Load(int3(clamp(p + o, int2(0,0), mx), 0)).rgb * wgt[i];
        acc += blur_input.Load(int3(clamp(p - o, int2(0,0), mx), 0)).rgb * wgt[i];
    }
    blur_output[p] = float4(acc, 1.0);
}
