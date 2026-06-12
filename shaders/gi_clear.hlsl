// GI cache invalidation: zero all cells in a WORLD-cell box (max exclusive).
// The shader maps world cells to toroidal slots itself, so the CPU never has
// to split a wrapped slab into runs. Dispatched over the box dimensions at
// init (full volume) and whenever the clipmap origin moves (entering slabs).
// Has its OWN tiny cbuffer — pushed per dispatch, independent of the shared
// CameraUniforms layout.
RWStructuredBuffer<uint> gi_cache : register(u0, space1);

cbuffer ClearBox : register(b0, space2) {
    int4 box_min; // world cell coords, xyz
    int4 box_max; // exclusive
};

#define GI_GRID_N     128
#define GI_CELL_UINTS 7

[numthreads(4, 4, 4)]
void main(uint3 id : SV_DispatchThreadID) {
    int3 cell = box_min.xyz + int3(id);
    if (any(cell >= box_max.xyz)) return;

    int3 s = ((cell % GI_GRID_N) + GI_GRID_N) % GI_GRID_N;
    int base = (s.x + s.y * GI_GRID_N + s.z * GI_GRID_N * GI_GRID_N) * GI_CELL_UINTS;
    [unroll]
    for (int i = 0; i < GI_CELL_UINTS; i++) gi_cache[base + i] = 0u;
}
