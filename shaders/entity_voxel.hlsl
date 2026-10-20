// Voxel-model entities (voxel_models.odin). Include-only: the including pass
// must declare FIRST:
//   StructuredBuffer<uint4> ent_data;   // layout below
//   int u_entity_count;
// Every entity is a few rigid parts; each part is a small voxel grid with its
// own (finer than terrain) voxel size and a world -> grid affine transform.
// A ray tests the entities its screen tile / sun-grid cell lists (bitmasks
// built on the CPU), then their part boxes, then walks the part's
// grid with a two-level DDA: 4^3 bricks with a 64-bit occupancy mask (one
// load per brick), then bit tests per voxel — the palette byte is only
// fetched for the voxel that was hit.
#ifndef ENTITY_VOXEL_HLSL
#define ENTITY_VOXEL_HLSL

// ---- Buffer layout (uint4 units; must match voxel_models.odin) ---------------
//  [0]                    header: x = dynamic base
//  [ENT_PAL_BASE..]       palette, one uint per entry: rgb | flags << 24
//  [ENT_MODEL_BASE + 2m]  model m: (dims.xyz, voxel word), (brick dims.xyz, mask word)
//                         masks: 2 words per 4^3 brick, bit = x + 4y + 16z
//  dynamic base:          header (Ent_Header): (tiles x, tiles y, -, -), (sun u axis, u0), (sun v axis, v0), -
//  + ENT_ENTS_OFS:        MAX_ENTITIES x 2: (box min, first part), (box max, part count)
//  + ENT_PARTS_OFS:       parts, 7 each: 3 rows world->grid, (box min, model), (box max, flags), (tint, block),
//                         (block texture origin, scale)
//  + ENT_SUN_OFS:         128-bit shadow-caster mask per sun-grid cell (one uint4)
//  + ENT_TILES_OFS:       128-bit entity mask per 16x16 screen tile (one uint4)
// See ent_build_masks in voxel_models.odin for how the masks are built.
#define ENT_PAL_BASE    1
#define ENT_MODEL_BASE  65
#define ENT_MAX         128
#define ENT_PART_STRIDE 7
#define ENT_MAX_PARTS   1024
#define ENT_TILE        16
#define ENT_SUN_GRID    64
#define ENT_SUN_CELL    4.0
#define ENT_ENTS_OFS    4
#define ENT_PARTS_OFS   (ENT_ENTS_OFS + ENT_MAX * 2)
#define ENT_SUN_OFS     (ENT_PARTS_OFS + ENT_MAX_PARTS * ENT_PART_STRIDE)
#define ENT_TILES_OFS   (ENT_SUN_OFS + ENT_SUN_GRID * ENT_SUN_GRID) // tiles_x * tiles_y (header)

// This pixel's screen-tile mask; the tracer sets it before tracing view rays.
static uint4 g_ent_tile_mask;

#define PAL_TINT 1u
#define PAL_EMIT 2u
#define PAL_THIN 4u
#define PAL_BLOCK 8u      // textured as the part's block
#define PAL_TINT2 16u     // the part's second colour: tex.xyz (a part with no block voxels)
#define PAL_TINT3 32u     // its third: the block word, rgb8
#define PAL_TINT4 64u     // its fourth: the texture scale's word, rgb8
#define PAL_BLOCK_BYTE 0x80u // voxel byte 0x80 | block id: that block, textured

struct EntityHit {
    int    index;    // part index, -1 = miss
    float  t;        // world-space distance (1e30 on miss)
    float3 hit_pos;
    float3 normal;   // world space
    uint   pal;      // palette index of the hit voxel
    uint   vhash;    // per-voxel hash for a little colour variation
    float3 grid_pos; // hit point and normal in the part's grid (block texturing)
    float3 grid_n;
};

uint ent_dyn_base() { return ent_data[0].x; }

uint ent_word(uint w) {
    uint4 q = ent_data[w >> 2];
    uint k = w & 3u;
    return k == 0u ? q.x : (k == 1u ? q.y : (k == 2u ? q.z : q.w));
}

uint ent_byte(uint word_base, uint idx) {
    return (ent_word(word_base + (idx >> 2)) >> ((idx & 3u) * 8u)) & 0xffu;
}

uint2 ent_mask(uint word_base, uint brick) {
    uint w = word_base + brick * 2u; // even, so both words sit in one uint4
    uint4 q = ent_data[w >> 2];
    return (w & 2u) != 0u ? q.zw : q.xy;
}

uint ent_palette(uint pal) { return ent_word(ENT_PAL_BASE * 4u + pal); }

// Slab test against [bmin, bmax]; inv_rd must be finite.
bool ent_box(float3 ro, float3 inv_rd, float3 bmin, float3 bmax, out float t_enter, out float t_exit) {
    float3 ta = (bmin - ro) * inv_rd;
    float3 tb = (bmax - ro) * inv_rd;
    float3 tlo = min(ta, tb), thi = max(ta, tb);
    t_enter = max(max(tlo.x, tlo.y), tlo.z);
    t_exit  = min(min(thi.x, thi.y), thi.z);
    return t_exit >= max(t_enter, 0.0);
}

float3 ent_safe_dir(float3 d) {
    float3 s = float3(d.x >= 0.0 ? 1.0 : -1.0, d.y >= 0.0 ? 1.0 : -1.0, d.z >= 0.0 ? 1.0 : -1.0);
    return s * max(abs(d), 1e-6);
}

int ent_min_axis(float3 v) {
    return (v.x <= v.y && v.x <= v.z) ? 0 : (v.y <= v.z ? 1 : 2);
}

// Axis a as a 0/1 mask. The walks step with it rather than v[a]: a vector
// indexed by a variable is kept in memory, not registers.
int3 ent_axis(int a) { return int3(a == 0, a == 1, a == 2); }

// Walk part p's grid along a world ray within [0, t_max]. t stays in world
// units: the grid-space ray is the world ray pushed through the affine map
// without renormalising. Returns true on a hit (t, grid normal axis/sign,
// voxel, palette).
bool ent_trace_part(uint p, float3 ro_w, float3 rd_w, float t_max,
                    out float t_hit, out float3 n_grid, out int3 vox, out uint pal, out float3 grid_pos) {
    t_hit = 1e30; n_grid = float3(0, 1, 0); vox = int3(0, 0, 0); pal = 0u; grid_pos = float3(0, 0, 0);
    uint base = ent_dyn_base() + ENT_PARTS_OFS + p * ENT_PART_STRIDE;
    float4 r0 = asfloat(ent_data[base + 0]);
    float4 r1 = asfloat(ent_data[base + 1]);
    float4 r2 = asfloat(ent_data[base + 2]);
    uint model = ent_data[base + 3].w;
    uint4 m0 = ent_data[ENT_MODEL_BASE + model * 2u];
    uint4 m1 = ent_data[ENT_MODEL_BASE + model * 2u + 1u];
    int3 dims = int3(m0.xyz);
    int3 bdims = int3(m1.xyz);

    float3 ro = float3(dot(r0.xyz, ro_w) + r0.w, dot(r1.xyz, ro_w) + r1.w, dot(r2.xyz, ro_w) + r2.w);
    float3 rd = ent_safe_dir(float3(dot(r0.xyz, rd_w), dot(r1.xyz, rd_w), dot(r2.xyz, rd_w)));
    float3 inv = 1.0 / rd;
    float t0, t1;
    if (!ent_box(ro, inv, float3(0, 0, 0), float3(dims), t0, t1)) return false;
    t1 = min(t1, t_max);
    float t = max(t0, 0.0);
    if (t > t1) return false;

    int3 stp = int3(rd.x >= 0.0 ? 1 : -1, rd.y >= 0.0 ? 1 : -1, rd.z >= 0.0 ? 1 : -1);
    float3 stp_f = float3(stp);
    // Entry face normal (the slab that was entered last).
    float3 ta = (0.0 - ro) * inv, tb = (float3(dims) - ro) * inv;
    float3 tlo = min(ta, tb);
    int axis = tlo.x >= tlo.y && tlo.x >= tlo.z ? 0 : (tlo.y >= tlo.z ? 1 : 2);

    // Coarse DDA over 4^3 bricks.
    float3 pc = ro + rd * (t + 1e-4);
    int3 c = clamp(int3(floor(pc / 4.0)), int3(0, 0, 0), bdims - 1);
    float3 tdc = abs(4.0 * inv);
    float3 tmc = (float3(c * 4 + max(stp, int3(0, 0, 0)) * 4) - ro) * inv;
    for (int i = 0; i < 96; i++) {
        uint cidx = uint(c.x + bdims.x * (c.y + bdims.y * c.z));
        float t_brick_exit = min(min(tmc.x, tmc.y), tmc.z);
        uint2 mask = ent_mask(m1.w, cidx);
        if ((mask.x | mask.y) != 0u) {
            // Fine DDA inside this brick.
            float3 pf = ro + rd * (t + 1e-4);
            int3 lo = c * 4;
            int3 v = clamp(int3(floor(pf)), lo, lo + 3);
            float3 tmf = (float3(v + max(stp, int3(0, 0, 0))) - ro) * inv;
            float3 tdf = abs(inv);
            float tf = t;
            int fax = axis;
            for (int j = 0; j < 12; j++) {
                int3 lv = v - lo;
                uint bit = uint(lv.x + 4 * lv.y + 16 * lv.z);
                uint word = bit < 32u ? mask.x : mask.y;
                if ((word >> (bit & 31u)) & 1u) {
                    t_hit = tf; vox = v;
                    pal = ent_byte(m0.w, uint(v.x + dims.x * (v.y + dims.y * v.z)));
                    n_grid = -stp_f * float3(ent_axis(fax));
                    grid_pos = clamp(ro + rd * tf, float3(v), float3(v + 1));
                    return true;
                }
                fax = ent_min_axis(tmf);
                int3 e = ent_axis(fax);
                tf = min(tmf.x, min(tmf.y, tmf.z));
                if (tf > t_brick_exit || tf > t1) break;
                v += stp * e;
                tmf += tdf * float3(e);
                // Brick and voxel boundaries coincide, so a float tie can
                // step out of the brick: the mask bit would be someone else's.
                if (any(v < lo) || any(v > lo + 3)) break;
            }
        }
        axis = ent_min_axis(tmc);
        int3 ea = ent_axis(axis);
        t = min(tmc.x, min(tmc.y, tmc.z));
        if (t > t1) break;
        c += stp * ea;
        tmc += tdc * float3(ea);
        if (any(c < 0) || any(c >= bdims)) break;
    }
    return false;
}

// 128-bit entity mask k of the table at base (bit i = entity i).
uint4 ent_mask_at(uint base, uint k) {
    return ent_data[base + k];
}

// Mask of the 16x16 tile holding pixel `pix` (call once per pixel).
void ent_set_pixel(uint2 pix) {
    g_ent_tile_mask = uint4(0, 0, 0, 0);
    if (u_entity_count == 0) return; // masks weren't uploaded this frame
    uint dyn = ent_dyn_base();
    uint tiles_x = ent_data[dyn].x;
    g_ent_tile_mask = ent_mask_at(dyn + ENT_TILES_OFS, (pix.y / ENT_TILE) * tiles_x + pix.x / ENT_TILE);
}

// Trace the entities in `mask` (bit i = entity i). any_hit: stop at the
// first hit (shadow rays).
bool ent_trace_mask(uint4 mask, float3 ro, float3 rd, float t_max, bool any_hit, inout EntityHit hit) {
    float3 inv = 1.0 / ent_safe_dir(rd);
    uint dyn = ent_dyn_base();
    float best = t_max;
    bool found = false;
    [loop]
    while (any(mask != 0u)) {
        uint e;
        if      (mask.x != 0u) { e =       firstbitlow(mask.x); mask.x &= mask.x - 1u; }
        else if (mask.y != 0u) { e = 32u + firstbitlow(mask.y); mask.y &= mask.y - 1u; }
        else if (mask.z != 0u) { e = 64u + firstbitlow(mask.z); mask.z &= mask.z - 1u; }
        else                   { e = 96u + firstbitlow(mask.w); mask.w &= mask.w - 1u; }
        uint4 e0 = ent_data[dyn + ENT_ENTS_OFS + e * 2u];
        uint4 e1 = ent_data[dyn + ENT_ENTS_OFS + e * 2u + 1u];
        float t0, t1;
        if (!ent_box(ro, inv, asfloat(e0.xyz), asfloat(e1.xyz), t0, t1) || t0 > best) continue;
        for (uint p = e0.w; p < e0.w + e1.w; p++) {
            uint pb = dyn + ENT_PARTS_OFS + p * ENT_PART_STRIDE;
            if (!ent_box(ro, inv, asfloat(ent_data[pb + 3].xyz), asfloat(ent_data[pb + 4].xyz), t0, t1) || t0 > best) continue;
            float t; float3 ng; int3 v; uint pal; float3 gp;
            if (!ent_trace_part(p, ro, rd, best, t, ng, v, pal, gp)) continue;
            found = true;
            if (any_hit) return true;
            best = t;
            float4 r0 = asfloat(ent_data[pb + 0]);
            float4 r1 = asfloat(ent_data[pb + 1]);
            float4 r2 = asfloat(ent_data[pb + 2]);
            hit.index  = int(p);
            hit.t      = t;
            hit.normal = normalize(ng.x * r0.xyz + ng.y * r1.xyz + ng.z * r2.xyz);
            hit.pal    = pal;
            hit.grid_pos = gp;
            hit.grid_n   = ng;
            uint h = uint(v.x) * 73856093u ^ uint(v.y) * 19349663u ^ uint(v.z) * 83492791u ^ p * 2654435761u;
            hit.vhash  = (h ^ (h >> 13)) * 1274126177u;
        }
    }
    return found;
}

// Nearest entity hit closer than t_max along a view ray of the current
// pixel (ent_set_pixel).
EntityHit trace_entities(float3 ro, float3 rd, float t_max) {
    EntityHit hit;
    hit.index = -1; hit.t = 1e30; hit.hit_pos = float3(0, 0, 0);
    hit.normal = float3(0, 1, 0); hit.pal = 0u; hit.vhash = 0u; hit.grid_pos = float3(0, 0, 0); hit.grid_n = float3(0, 1, 0);
    if (u_entity_count > 0 && t_max > 0.0 && any(g_ent_tile_mask != 0u) &&
        ent_trace_mask(g_ent_tile_mask, ro, rd, t_max, false, hit)) hit.hit_pos = ro + rd * hit.t;
    return hit;
}

// Any-hit sun shadow test from ro (rd = the sun direction): 0 = blocked by
// an entity, 1 = clear. Only casters whose sun-grid cells cover ro are traced.
float entity_shadow_transmittance(float3 ro, float3 rd, float max_t) {
    if (u_entity_count == 0) return 1.0;
    uint dyn = ent_dyn_base();
    float4 hu = asfloat(ent_data[dyn + 1]);
    float4 hv = asfloat(ent_data[dyn + 2]);
    int cu = clamp(int(floor((dot(ro, hu.xyz) - hu.w) / ENT_SUN_CELL)), 0, ENT_SUN_GRID - 1);
    int cv = clamp(int(floor((dot(ro, hv.xyz) - hv.w) / ENT_SUN_CELL)), 0, ENT_SUN_GRID - 1);
    uint4 mask = ent_mask_at(dyn + ENT_SUN_OFS, uint(cv * ENT_SUN_GRID + cu));
    if (all(mask == 0u)) return 1.0;
    EntityHit h;
    h.index = -1; h.t = 1e30; h.hit_pos = float3(0, 0, 0);
    h.normal = float3(0, 1, 0); h.pal = 0u; h.vhash = 0u; h.grid_pos = float3(0, 0, 0); h.grid_n = float3(0, 1, 0);
    return ent_trace_mask(mask, ro, rd, max_t, true, h) ? 0.0 : 1.0;
}

// Surface colour and flags of a hit: palette colour (tinted when the entry
// asks), with a slight per-voxel brightness wobble.
// Block voxels (PAL_BLOCK) come back white: the tracer textures them
// (entity_block).
float3 entity_albedo(EntityHit h, out uint flags) {
    if (h.pal >= PAL_BLOCK_BYTE) { flags = PAL_BLOCK; return float3(1, 1, 1); }
    uint c = ent_palette(h.pal);
    flags = c >> 24;
    if (flags & PAL_BLOCK) return float3(1, 1, 1);
    float3 col = float3(c & 0xffu, (c >> 8) & 0xffu, (c >> 16) & 0xffu) / 255.0;
    if (flags & (PAL_TINT | PAL_TINT2 | PAL_TINT3 | PAL_TINT4)) {
        uint pb = ent_dyn_base() + ENT_PARTS_OFS + uint(h.index) * ENT_PART_STRIDE;
        if (flags & PAL_TINT) col *= asfloat(ent_data[pb + 5].xyz);
        else if (flags & PAL_TINT2) col *= asfloat(ent_data[pb + 6].xyz);
        else {
            uint c3 = (flags & PAL_TINT3) ? ent_data[pb + 5].w : ent_data[pb + 6].w;
            col *= float3(c3 & 0xffu, (c3 >> 8) & 0xffu, (c3 >> 16) & 0xffu) / 255.0;
        }
    }
    return col * (0.93 + 0.14 * float(h.vhash >> 24) / 255.0);
}

// A block voxel's block, and its hit point and normal in block-texture
// space (world voxel units: where it would be in the world).
uint entity_block(EntityHit h, out float3 pos, out float3 n) {
    uint pb = ent_dyn_base() + ENT_PARTS_OFS + uint(h.index) * ENT_PART_STRIDE;
    float4 tex = asfloat(ent_data[pb + 6]);
    pos = h.grid_pos * tex.w + tex.xyz;
    n = h.grid_n;
    return h.pal >= PAL_BLOCK_BYTE ? h.pal - PAL_BLOCK_BYTE : ent_data[pb + 5].w;
}

#endif // ENTITY_VOXEL_HLSL
