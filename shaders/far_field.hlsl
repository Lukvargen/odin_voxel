// Far terrain (far.odin): an LOD of blocky 4x4-voxel cells, each solid
// ground up to a height plus an optional floating canopy slab (tree crowns),
// traced once a ray leaves the near voxel region. Two-level 2D DDA: tiles of
// 8x8 cells (skipped when the ray stays above the tile's highest surface),
// then cells. Requires `far_data` (StructuredBuffer<uint>: per tile slot 4 uints
// owner tile x, z, max height, unused; then FAR_TILE_CELLS^2 cells per tile
// slot), plus the CameraUniforms and voxel_common.hlsl.
#ifndef FAR_FIELD_HLSL
#define FAR_FIELD_HLSL

#define FAR_CELL        4
#define FAR_TILE_CELLS  8
#define FAR_TILE        (FAR_CELL * FAR_TILE_CELLS)
#define FAR_RING        128
#define FAR_MAX_T       2800.0
#define FAR_CELLS_BASE  (FAR_RING * FAR_RING * 4)
#define FAR_MAX_Y       float((WORLD_CHUNK_Y_MIN + GPU_CHUNKS_HEIGHT) * BRICK_CHUNK_SIZE)

struct FarHit {
    bool   hit;
    float  t;
    float3 normal;
    float3 hit_pos;
    uint   block_id;
    int2   cell;     // world cell coord
    bool   under_canopy; // ground hit below this cell's canopy (shaded)
};

// Where a ray segment over one cell (heights ya at t0, yb at t1) first
// enters the solid span [lo, hi]. Returns t (or 1e30 for a miss) and the
// face normal: side (side_n), top, or bottom.
float far_span_hit(float3 o, float3 d, float t0, float t1, float ya, float yb,
                   float lo, float hi, float3 side_n, out float3 n) {
    n = side_n;
    if (max(ya, yb) <= lo || min(ya, yb) >= hi) return 1e30;
    if (ya > lo && ya < hi) return t0;       // entered through the side
    if (ya >= hi) { n = float3(0, 1, 0);  return (hi - o.y) / d.y; }
    n = float3(0, -1, 0);                    // from below: canopy underside
    return (lo - o.y) / d.y;
}

// Distance along the ray to where it leaves the near voxel region (a
// circle in XZ around the player), and the axis it mostly leaves along
// (0 = x, 1 = z; the normal of a far side hit right at the edge).
float near_exit_t(float3 o, float3 d, out int axis) {
    axis = abs(d.x) > abs(d.z) ? 0 : 1;
    float2 p = o.xz - u_near_circle.xy;
    float  r = u_near_circle.z;
    float  a = dot(d.xz, d.xz);
    float  c = dot(p, p) - r * r;
    if (c >= 0.0) return 0.0;                 // outside: no near region ahead
    if (a < 1e-8) return RAY_MAX_LENGTH;      // straight up/down: never leaves
    float b = dot(p, d.xz);
    return (-b + sqrt(b * b - a * c)) / a;
}

// Cells of one tile between t_in and t_out. axis_in: axis of the step that
// entered the tile (the normal of a side hit on its first cell).
bool far_trace_tile(float3 o, float3 d, int slot, int2 tile, float t_in, float t_out,
                    int axis_in, inout FarHit h) {
    int2 st   = int2(d.x > 0.0 ? 1 : -1, d.z > 0.0 ? 1 : -1);
    int2 base = tile * FAR_TILE_CELLS;
    float3 p  = o + d * (t_in + 1e-3);
    int2 c    = clamp(int2(floor(p.xz / FAR_CELL)), base, base + FAR_TILE_CELLS - 1);
    float2 tdelta = abs(FAR_CELL / d.xz);
    float2 tmax   = (float2((c + int2(st.x > 0 ? 1 : 0, st.y > 0 ? 1 : 0)) * FAR_CELL) - o.xz) / d.xz;
    float t_enter = t_in;
    int axis = axis_in;
    [loop] for (int k = 0; k < 2 * FAR_TILE_CELLS; k++) {
        float t_exit = min(min(tmax.x, tmax.y), t_out);
        int2 l = c - base;
        // Cell: ground top (10 bits) | block (8) | canopy bottom above the
        // ground (6) | canopy height (6, 0 = none) | canopy kind (2).
        uint cell = far_data[FAR_CELLS_BASE + slot * FAR_TILE_CELLS * FAR_TILE_CELLS + l.x + l.y * FAR_TILE_CELLS];
        float y0     = float(WORLD_CHUNK_Y_MIN * BRICK_CHUNK_SIZE);
        float ground = float(cell & 0x3FFu) + y0;
        uint  clo    = (cell >> 18) & 0x3Fu; // canopy bottom, above the ground
        uint  chi    = (cell >> 24) & 0x3Fu; // canopy height
        float ya = o.y + d.y * t_enter;
        float yb = o.y + d.y * t_exit;
        float3 side_n = axis == 0 ? float3(-(float)st.x, 0, 0) : float3(0, 0, -(float)st.y);
        float3 ng, nc;
        float tg = far_span_hit(o, d, t_enter, t_exit, ya, yb, -1e30, ground, side_n, ng);
        float tc = chi != 0u
            ? far_span_hit(o, d, t_enter, t_exit, ya, yb, float(clo) + ground, float(clo + chi) + ground, side_n, nc)
            : 1e30;
        if (min(tg, tc) < 1e29) {
            h.hit  = true;
            h.cell = c;
            if (tc < tg) {
                h.t = tc; h.normal = nc;
                uint kind = (cell >> 30) & 3u;
                h.block_id = kind == 1u ? BLOCK_SPRUCE_LEAVES : kind == 2u ? BLOCK_BIRCH_LEAVES : kind == 3u ? BLOCK_AUTUMN_LEAVES : BLOCK_LEAVES;
            } else {
                h.t = tg; h.normal = ng; h.block_id = (cell >> 10) & 255u;
                h.under_canopy = chi != 0u;
            }
            h.hit_pos = o + d * h.t;
            return true;
        }
        if (t_exit >= t_out) break;
        if (tmax.x < tmax.y) { c.x += st.x; t_enter = tmax.x; tmax.x += tdelta.x; axis = 0; }
        else                 { c.y += st.y; t_enter = tmax.y; tmax.y += tdelta.y; axis = 1; }
        int2 nl = c - base;
        if (nl.x < 0 || nl.y < 0 || nl.x >= FAR_TILE_CELLS || nl.y >= FAR_TILE_CELLS) break;
    }
    return false;
}

// Trace the far terrain from t0 (where the ray left the near region).
FarHit far_trace(float3 o, float3 d, float t0, int axis0) {
    FarHit h;
    h.hit = false; h.t = 0.0; h.normal = float3(0, 0, 0); h.hit_pos = float3(0, 0, 0);
    h.block_id = 0u; h.cell = int2(0, 0); h.under_canopy = false;
    d = safe_dir(d);

    int2 st = int2(d.x > 0.0 ? 1 : -1, d.z > 0.0 ? 1 : -1);
    float3 p = o + d * (t0 + 1e-3);
    int2 ti = int2(floor(p.xz / FAR_TILE));
    float2 tdelta = abs(FAR_TILE / d.xz);
    float2 tmax   = (float2((ti + int2(st.x > 0 ? 1 : 0, st.y > 0 ? 1 : 0)) * FAR_TILE) - o.xz) / d.xz;
    float t_enter = t0;
    int axis = axis0;
    [loop] for (int i = 0; i < 400; i++) {
        if (t_enter > FAR_MAX_T) break;
        float t_exit = min(tmax.x, tmax.y);
        int2 rs  = ti & (FAR_RING - 1);
        int slot = rs.x + rs.y * FAR_RING;
        int4 tile = int4(far_data[slot * 4], far_data[slot * 4 + 1], far_data[slot * 4 + 2], 0);
        if (tile.x == ti.x && tile.y == ti.y) {
            float ya = o.y + d.y * t_enter;
            float yb = o.y + d.y * t_exit;
            if (min(ya, yb) < float(tile.z) &&
                far_trace_tile(o, d, slot, ti, t_enter, t_exit, axis, h)) return h;
        }
        if (d.y > 0.0 && o.y + d.y * t_exit > FAR_MAX_Y) break; // above everything, climbing
        if (tmax.x < tmax.y) { ti.x += st.x; t_enter = tmax.x; tmax.x += tdelta.x; axis = 0; }
        else                 { ti.y += st.y; t_enter = tmax.y; tmax.y += tdelta.y; axis = 1; }
    }
    return h;
}

#endif // FAR_FIELD_HLSL
