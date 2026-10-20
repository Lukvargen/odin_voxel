// Bounce light (one bounce and more, over frames) from irradiance probes in
// world space: a grid of probes every GI_SPACING voxels in a box around the
// camera (gi.odin places it), each holding the light arriving from six
// directions (an ambient cube), made by gi_probes.hlsl from short rays and
// sampled here by shading. Only light off surfaces goes in: the open sky is
// the voxel sky light's (light.odin), so it isn't counted twice.
//
// Leaks: probes sit every 4 voxels, so blending the 8 around a point would
// pull light through 1-block walls. Each probe instead keeps a mask of the
// voxels of its 8x8x8 box it reaches through open voxels (from where it
// stands, or the nearest open voxel if it's buried), and only probes that
// reach the voxel being shaded count.
//
// Bindings, declared by the including shader: gi_irr (float4: rgb light per
// probe and direction) and gi_vis (uint: 16 reach-mask words, then the
// probe's owner), as Texture2D or RWTexture2D.
#ifndef GI_COMMON_HLSL
#define GI_COMMON_HLSL

#define GI_SPACING   4
#define GI_DIMS      int3(48, 24, 48) // gi.odin GI_DIMS
#define GI_ROW       128              // probes per texture row (gi.odin GI_ROW)
#define GI_VIS_WORDS 17               // reach mask (16), owner
#define GI_OWNER_WORD 16

int gi_floor_div(int a, int b) { return a >= 0 ? a / b : -((b - 1 - a) / b); }
int3 gi_floor_div3(int3 a, int3 b) { return int3(gi_floor_div(a.x, b.x), gi_floor_div(a.y, b.y), gi_floor_div(a.z, b.z)); }

// Storage slot of the probe at probe coords pw: the grid wraps, so moving the
// camera only renews the probes along the edge it moves toward.
int gi_slot(int3 pw) {
    int3 m = pw - gi_floor_div3(pw, GI_DIMS) * GI_DIMS;
    return m.x + m.y * GI_DIMS.x + m.z * GI_DIMS.x * GI_DIMS.y;
}

// Which of the probes sharing a slot is in it (never 0: unwritten slots).
// g: which copy of the grid pw is in (gi_floor_div3(pw, GI_DIMS)).
uint gi_owner_of(int3 g) {
    return (uint(g.x) & 0x1FFFu) | ((uint(g.z) & 0x1FFFu) << 13) | ((uint(g.y) & 0xFu) << 26) | 0x80000000u;
}
uint gi_owner(int3 pw) { return gi_owner_of(gi_floor_div3(pw, GI_DIMS)); }

// Directions: 0 +x, 1 -x, 2 +y, 3 -y, 4 +z, 5 -z.
// (Unsigned: slots are never negative, and a signed % and / cost more.)
int2 gi_irr_texel(int s, int dir) { return int2(int(uint(s) % GI_ROW) * 6 + dir, int(uint(s) / GI_ROW)); }
int2 gi_vis_texel(int s, int w)   { return int2(int(uint(s) % GI_ROW) * GI_VIS_WORDS + w, int(uint(s) / GI_ROW)); }

// A probe's updates so far (alpha of its light, 1..GI_SETTLED): a new
// probe's first few are noisy, so shading eases from its stand-in to the
// probe's light over them instead of popping (gi_sample).
#define GI_SETTLED 4.0

// Light arriving at a surface facing n, from the probe in slot s; how far
// it has settled (0..1) in `settled`.
float3 gi_probe_light(int s, float3 n, out float settled) {
    float3 n2 = n * n;
    float4 e = float4(0, 0, 0, 0);
    if (n2.x > 0.01) e += n2.x * gi_irr[gi_irr_texel(s, n.x > 0.0 ? 0 : 1)];
    if (n2.y > 0.01) e += n2.y * gi_irr[gi_irr_texel(s, n.y > 0.0 ? 2 : 3)];
    if (n2.z > 0.01) e += n2.z * gi_irr[gi_irr_texel(s, n.z > 0.0 ? 4 : 5)];
    settled = saturate(e.a / GI_SETTLED);
    return e.rgb;
}

// Where the probes' light gives way to the stand-in: a circle around the
// camera (a square's edge shows as a straight seam across the ground)
// inside the grid's 96-voxel half width, and the grid's top and bottom.
#define GI_FADE_FULL 70.0
#define GI_FADE_END  88.0

// Bounce light at point p (just off a surface facing n) in open voxel f:
// the probes around it that reach f, weighted trilinearly; probes not
// updated yet, and new ones in part, stand in with `guess`. fade: 1 near
// the camera, falling to 0 toward the grid's edge (beyond, the caller keeps
// its stand-in). False if no probe reaches f.
bool gi_sample(int3 f, float3 p, float3 n, float3 guess, out float3 light, out float fade) {
    light = float3(0, 0, 0);
    fade = 0.0;
    if (u_gi_origin.w == 0) return false;
    float3 g = p / float(GI_SPACING);
    // Probe coords of the corner probe: f's own cell, so f lies in every
    // one of the 8 probes' boxes (offsets -4..3).
    int3 b = f >> 2; // floor(f / GI_SPACING), GI_SPACING being 4
    float3 fr = saturate(g - float3(b));
    float my = min(g.y - float(u_gi_origin.y), float(u_gi_origin.y + GI_DIMS.y - 1) - g.y);
    fade = saturate((GI_FADE_END - length(p.xz - u_cam_pos.xz)) / (GI_FADE_END - GI_FADE_FULL))
         * saturate((my - 0.5) / 3.0);
    if (fade <= 0.0) return false;

    // The corner probe's place in the wrapped grid, once: the other seven
    // are a step from it, wrapping at most once per axis (gi_slot and
    // gi_owner divide, eight times over, otherwise).
    int3 g0 = gi_floor_div3(b, GI_DIMS);
    int3 m0 = b - g0 * GI_DIMS;
    float  wsum = 0.0;
    float3 acc = float3(0, 0, 0);
    [unroll]
    for (int k = 0; k < 8; k++) {
        int3 o = int3(k & 1, (k >> 1) & 1, k >> 2);
        int3 pw = b + o;
        float3 tw = lerp(1.0 - fr, fr, float3(o));
        float  w = tw.x * tw.y * tw.z;
        if (w < 1e-4) continue;
        int3 wrap = int3(m0 + o >= GI_DIMS);
        int3 m = m0 + o - wrap * GI_DIMS;
        int3 g = g0 + wrap;
        int s = m.x + m.y * GI_DIMS.x + m.z * GI_DIMS.x * GI_DIMS.y;
        if (gi_vis[gi_vis_texel(s, GI_OWNER_WORD)] != gi_owner_of(g)) {
            acc  += w * guess; // not updated since it entered the grid
            wsum += w;
            continue;
        }
        int3 l = clamp(f - pw * GI_SPACING + 4, 0, 7);
        int  bit = l.x + l.y * 8 + l.z * 64;
        if (((gi_vis[gi_vis_texel(s, bit >> 5)] >> uint(bit & 31)) & 1u) == 0u) continue;
        float settled;
        float3 e = gi_probe_light(s, n, settled);
        acc  += w * lerp(guess, e, settled);
        wsum += w;
    }
    if (wsum < 1e-3) return false;
    light = acc / wsum;
    return true;
}

#endif // GI_COMMON_HLSL
