// Procedural SDF entities. Include-only, like voxel_common.hlsl: the
// including pass must declare these globals FIRST:
//   StructuredBuffer<float4> sdf_entities;   // ENTITY_STRIDE float4s/entity
//   int   u_entity_count;
//   float u_time;
// Entities are fully procedural — each type is a hand-written SDF composed
// of primitives, animated in-shader from per-entity params. No models.
//
// v1 traversal is a brute-force loop over the CPU-culled list (<= 64) with a
// per-entity AABB pre-test. Per-chunk binning later only replaces the loop
// bodies of trace_entities / entity_shadow_transmittance; the eval/trace
// functions and EntityHit are the stable interface.
#ifndef ENTITY_SDF_HLSL
#define ENTITY_SDF_HLSL

// ---- Per-entity GPU record (must match Entity_Gpu in entities.odin) ---------
//  [0] pos.xyz       yaw
//  [1] aabb_min.xyz  kind (float-encoded small int)
//  [2] aabb_max.xyz  anim_phase
//  [3] color.rgb     seed
//  [4] scale         param0..2 (reserved per kind)
#define ENTITY_STRIDE 5

#define ENTITY_KIND_BLOB    0
#define ENTITY_KIND_CRYSTAL 1
#define ENTITY_KIND_GLIDER  2 // player's hang glider: pos = pilot eye, seed = unfold 0..1,
                              // params = body pitch, bank (radians), part flags
// Glider part flags: the glider is uploaded as two records (wing, and the
// control frame + pilot) so each gets a tight box and rays that miss a part
// never sphere-trace it.
#define GLIDER_WING  1
#define GLIDER_FRAME 2 // A-frame and the pilot's arms
#define GLIDER_BODY  4 // pilot's body and head (hidden in first person)

struct EntityHit {
    int    index;    // entity list index, -1 = miss
    float  t;        // world-space distance (1e30 on miss)
    float3 hit_pos;
    float3 normal;   // set for analytic hits (glider); SDF hits use sdf_entity_normal
    int    part;     // glider part, -1 for SDF entities
};

// ---- Primitives --------------------------------------------------------------

float sd_sphere(float3 p, float r) {
    return length(p) - r;
}

float sd_box(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sd_capsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Polynomial smooth min — blends parts organically instead of hard unions.
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float2 rot2(float2 v, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// ---- Per-type SDFs -------------------------------------------------------------
// Local space: entity anchor (pos) is the GROUND point under the entity,
// +z is the entity's facing after yaw, scale 1 ~= a 1-voxel-ish creature.
// IMPORTANT: keep every animated displacement inside ANIM_MARGIN (see
// entities.odin) or the entity clips against its CPU-computed AABB.
// Distance correctness: compose rigid-transformed primitives with offsets +
// smin only (Lipschitz <= 1); the sphere-trace 0.9 step factor covers the
// small smin underestimate. No non-uniform scaling in here.

// Blob critter: squashy body + 4 stubby walking legs + eye bumps.
float sdf_blob(float3 p, float phase, float seed) {
    float tt   = u_time * 4.0 + phase;
    float bob  = 0.08 * sin(tt);
    float chub = 0.9 + 0.2 * seed; // per-entity proportions

    // Body: sphere squashed by a wider lower sphere for a pear silhouette.
    float body = sd_sphere(p - float3(0.0, 0.62 + bob, 0.0), 0.42 * chub);
    float base = sd_sphere(p - float3(0.0, 0.42 + bob * 0.6, 0.0), 0.34 * chub);
    float d = smin(body, base, 0.18);

    // Legs: 4 capsules, diagonal pairs alternate in the walk cycle.
    [unroll]
    for (int i = 0; i < 4; i++) {
        float sx = (i & 1) ? 1.0 : -1.0;
        float sz = (i & 2) ? 1.0 : -1.0;
        float swing = sin(tt + ((sx * sz > 0.0) ? 0.0 : 3.14159));
        float3 hip  = float3(0.22 * sx, 0.35 + bob, 0.16 * sz);
        float3 foot = float3(0.26 * sx, max(0.10 * swing, 0.0) + 0.08, 0.16 * sz + 0.10 * swing);
        d = smin(d, sd_capsule(p, hip, foot, 0.09), 0.06);
    }

    // Eye bumps on the facing (+z) side.
    float eyes = min(
        sd_sphere(p - float3( 0.16, 0.72 + bob, 0.34 * chub), 0.07),
        sd_sphere(p - float3(-0.16, 0.72 + bob, 0.34 * chub), 0.07));
    return smin(d, eyes, 0.03);
}

// Crystal: stretched octahedron hovering + slowly spinning. Emissive in shading.
float sdf_crystal(float3 p, float phase, float seed) {
    float hover = 0.15 * sin(u_time * 2.0 + phase);
    float3 q = p - float3(0.0, 0.75 + hover, 0.0);
    q.xz = rot2(q.xz, u_time * 0.8 + phase);
    // Octahedron via a box rotated 45 deg on two axes, stretched vertically.
    q.xy = rot2(q.xy, 0.7854);
    q.yz = rot2(q.yz, 0.7854);
    return sd_box(q, float3(0.16, 0.40 + 0.1 * seed, 0.16));
}

// ---- Hang glider ----------------------------------------------------------------
// The glider is triangles, capsules and a sphere, so it is ray traced
// analytically instead of sphere traced: rays that graze the thin sail or
// pass close to the tubes would otherwise take dozens of steps.
// Body frame: origin at the pilot's eye, +z nose, +y up, +x the LEFT wing.

#define GLIDER_PART_SAIL  0
#define GLIDER_PART_TUBE  1
#define GLIDER_PART_PILOT 2

struct GliderHit {
    float  t;
    float3 n;    // body-space normal
    int    part;
};

// World point/direction -> glider body frame (yaw, then pitch, then bank).
float3 glider_to_body(int i, float3 v, bool is_point) {
    float4 e0 = sdf_entities[i * ENTITY_STRIDE + 0];
    float4 e4 = sdf_entities[i * ENTITY_STRIDE + 4];
    if (is_point) v -= e0.xyz;
    v.xz = rot2(v.xz, -e0.w);
    v.yz = rot2(v.yz, e4.y);
    v.xy = rot2(v.xy, e4.z);
    return v;
}

float3 glider_dir_to_world(int i, float3 v) {
    float4 e0 = sdf_entities[i * ENTITY_STRIDE + 0];
    float4 e4 = sdf_entities[i * ENTITY_STRIDE + 4];
    v.xy = rot2(v.xy, -e4.z);
    v.yz = rot2(v.yz, -e4.y);
    v.xz = rot2(v.xz, e0.w);
    return v;
}

void glider_tri(float3 ro, float3 rd, float3 a, float3 b, float3 c, inout GliderHit h) {
    float3 e1 = b - a, e2 = c - a;
    float3 pv = cross(rd, e2);
    float det = dot(e1, pv);
    if (abs(det) < 1e-7) return;
    float inv = 1.0 / det;
    float3 tv = ro - a;
    float u = dot(tv, pv) * inv;
    if (u < 0.0 || u > 1.0) return;
    float3 qv = cross(tv, e1);
    float v = dot(rd, qv) * inv;
    if (v < 0.0 || u + v > 1.0) return;
    float t = dot(e2, qv) * inv;
    if (t > 0.0 && t < h.t) {
        float3 n = normalize(cross(e1, e2));
        h.t = t; h.n = dot(n, rd) > 0.0 ? -n : n; h.part = GLIDER_PART_SAIL;
    }
}

void glider_capsule(float3 ro, float3 rd, float3 pa, float3 pb, float r, int part, inout GliderHit h) {
    float3 ba = pb - pa, oa = ro - pa;
    float baba = dot(ba, ba), bard = dot(ba, rd), baoa = dot(ba, oa);
    float rdoa = dot(rd, oa), oaoa = dot(oa, oa);
    float a = max(baba - bard * bard, 1e-8);
    float b = baba * rdoa - baoa * bard;
    float c = baba * oaoa - baoa * baoa - r * r * baba;
    float disc = b * b - a * c;
    if (disc < 0.0) return;
    float t = (-b - sqrt(disc)) / a;
    float y = baoa + t * bard;
    if (y <= 0.0 || y >= baba) {
        // End caps.
        float3 oc = y <= 0.0 ? oa : ro - pb;
        float cb = dot(rd, oc);
        float cc = dot(oc, oc) - r * r;
        float hc = cb * cb - cc;
        if (hc <= 0.0) return;
        t = -cb - sqrt(hc);
    }
    if (t > 0.0 && t < h.t) {
        float3 p = ro + rd * t - pa;
        h.t = t;
        h.n = (p - ba * clamp(dot(p, ba) / baba, 0.0, 1.0)) / r;
        h.part = part;
    }
}

void glider_sphere(float3 ro, float3 rd, float3 c, float r, int part, inout GliderHit h) {
    float3 oc = ro - c;
    float b = dot(oc, rd);
    float disc = b * b - (dot(oc, oc) - r * r);
    if (disc <= 0.0) return;
    float t = -b - sqrt(disc);
    if (t > 0.0 && t < h.t) {
        h.t = t; h.n = (oc + rd * t) / r; h.part = part;
    }
}

// Nearest glider hit in body space (rd unit length), closer than h.t.
void glider_intersect(float3 ro, float3 rd, float unfold_t, int flags, inout GliderHit h) {
    float u = lerp(0.12, 1.0, smoothstep(0.0, 1.0, unfold_t));
    float3 nose = float3(0.0, 1.25, 1.9);
    float3 tail = float3(0.0, 1.42, -1.6);
    if (flags & GLIDER_WING) {
        [unroll]
        for (int s = 0; s < 2; s++) {
            float side = s == 0 ? 1.0 : -1.0;
            float3 tip = float3(3.7 * u * side, 1.08, -1.0);
            // Billow: the trailing edge lifts between tip and keel.
            float3 mid = lerp(tip, tail, 0.5) + float3(0.0, 0.12, 0.08);
            glider_tri(ro, rd, nose, tip, mid, h);
            glider_tri(ro, rd, nose, mid, tail, h);
            glider_capsule(ro, rd, nose, tip, 0.055, GLIDER_PART_TUBE, h); // leading edge
        }
        glider_capsule(ro, rd, nose, float3(0.0, 1.32, -1.95), 0.05, GLIDER_PART_TUBE, h);                           // keel
        glider_capsule(ro, rd, float3(1.9 * u, 1.17, -0.2), float3(-1.9 * u, 1.17, -0.2), 0.04, GLIDER_PART_TUBE, h); // crossbar
        glider_capsule(ro, rd, float3(0.0, 1.3, 0.1), float3(0.0, 1.95, 0.1), 0.035, GLIDER_PART_TUBE, h);           // king post
    }
    if (flags & GLIDER_FRAME) {
        // A-frame: two downtubes and the base bar in front of the pilot,
        // and the pilot's arms reaching to it.
        float3 apex = float3(0.0, 1.25, 0.15);
        float3 barL = float3( 0.75, -0.45, 0.75);
        float3 barR = float3(-0.75, -0.45, 0.75);
        glider_capsule(ro, rd, apex, barL, 0.03, GLIDER_PART_TUBE, h);
        glider_capsule(ro, rd, apex, barR, 0.03, GLIDER_PART_TUBE, h);
        glider_capsule(ro, rd, barL, barR, 0.035, GLIDER_PART_TUBE, h);
        glider_capsule(ro, rd, float3( 0.2, -0.16, -0.05), float3( 0.48, -0.42, 0.72), 0.055, GLIDER_PART_PILOT, h);
        glider_capsule(ro, rd, float3(-0.2, -0.16, -0.05), float3(-0.48, -0.42, 0.72), 0.055, GLIDER_PART_PILOT, h);
    }
    if (flags & GLIDER_BODY) {
        glider_capsule(ro, rd, float3(0.0, -0.08, -0.05), float3(0.0, -0.3, -1.45), 0.21, GLIDER_PART_PILOT, h); // body, prone
        glider_sphere(ro, rd, float3(0.0, 0.02, 0.24), 0.15, GLIDER_PART_PILOT, h);                             // head
        glider_capsule(ro, rd, float3(0.0, 1.25, -0.2), float3(0.0, 0.0, -0.45), 0.02, GLIDER_PART_TUBE, h);    // hang strap
    }
}

// World-space trace of glider record i within (0, t_max): t or 1e30, with
// the world normal and part.
float glider_trace(int i, float3 ro, float3 rd, float t_max, out float3 n_world, out int part) {
    GliderHit h;
    h.t = t_max; h.n = float3(0, 1, 0); h.part = -1;
    float3 bro = glider_to_body(i, ro, true);
    float3 brd = glider_to_body(i, rd, false);
    float unfold_t = sdf_entities[i * ENTITY_STRIDE + 3].w;
    int flags = int(sdf_entities[i * ENTITY_STRIDE + 4].w + 0.5);
    glider_intersect(bro, brd, unfold_t, flags, h);
    n_world = glider_dir_to_world(i, h.n);
    part = h.part;
    return h.part >= 0 ? h.t : 1e30;
}

// Glider colour at world point wp: striped sail, metal tubes, pilot.
float3 glider_albedo(int i, float3 wp, int part) {
    if (part == GLIDER_PART_PILOT) return float3(0.10, 0.13, 0.22); // pilot suit
    if (part == GLIDER_PART_TUBE)  return float3(0.62, 0.64, 0.68); // aluminium
    float3 bp = glider_to_body(i, wp, true);
    // Sail: chevrons sweeping back from the nose.
    float v = frac((bp.z + abs(bp.x) * 0.55) * 0.42);
    if (v < 0.22) return float3(0.92, 0.92, 0.88);
    if (v < 0.34) return float3(0.08, 0.16, 0.42);
    return sdf_entities[i * ENTITY_STRIDE + 3].rgb;
}

// Per-type dispatch in entity-LOCAL space (caller handles pos/yaw/scale).
float sdf_entity_eval(int kind, float3 p, float phase, float seed, float3 params) {
    if (kind == ENTITY_KIND_CRYSTAL) return sdf_crystal(p, phase, seed);
    return sdf_blob(p, phase, seed);
}

// World-space distance to entity i.
float sdf_entity_world(int i, float3 wp) {
    float4 e0 = sdf_entities[i * ENTITY_STRIDE + 0]; // pos, yaw
    float4 e2 = sdf_entities[i * ENTITY_STRIDE + 2]; // aabb_max, phase
    float4 e3 = sdf_entities[i * ENTITY_STRIDE + 3]; // color, seed
    float4 e4 = sdf_entities[i * ENTITY_STRIDE + 4]; // scale, params
    int kind  = int(sdf_entities[i * ENTITY_STRIDE + 1].w + 0.5);
    float scale = max(e4.x, 1e-3);

    float3 lp = wp - e0.xyz;
    lp.xz = rot2(lp.xz, -e0.w);
    lp /= scale;
    return sdf_entity_eval(kind, lp, e2.w, e3.w, e4.yzw) * scale;
}

// Surface normal via tetrahedron gradient (4 evals).
float3 sdf_entity_normal(int i, float3 wp) {
    const float2 k = float2(1.0, -1.0);
    const float  h = 0.004;
    return normalize(
        k.xyy * sdf_entity_world(i, wp + k.xyy * h) +
        k.yyx * sdf_entity_world(i, wp + k.yyx * h) +
        k.yxy * sdf_entity_world(i, wp + k.yxy * h) +
        k.xxx * sdf_entity_world(i, wp + k.xxx * h));
}

// Slab test. inv_rd must be finite (caller clamps near-zero components).
bool ray_aabb(float3 ro, float3 inv_rd, float3 bmin, float3 bmax,
              out float t_enter, out float t_exit) {
    float3 ta = (bmin - ro) * inv_rd;
    float3 tb = (bmax - ro) * inv_rd;
    float3 tlo = min(ta, tb), thi = max(ta, tb);
    t_enter = max(max(tlo.x, tlo.y), tlo.z);
    t_exit  = min(min(thi.x, thi.y), thi.z);
    return t_exit >= max(t_enter, 0.0);
}

// Local copy of voxel_common's safe_dir (this file is included before it).
float3 esafe_dir(float3 d) {
    float3 s = float3(d.x >= 0.0 ? 1.0 : -1.0,
                      d.y >= 0.0 ? 1.0 : -1.0,
                      d.z >= 0.0 ? 1.0 : -1.0);
    return s * max(abs(d), 1e-6);
}

// Sphere-trace one entity within [t_start, t_end] (the AABB interval clipped
// by the current nearest hit). Returns hit t or 1e30.
float sdf_trace(float3 ro, float3 rd, float t_start, float t_end, int i) {
    float scale = max(sdf_entities[i * ENTITY_STRIDE + 4].x, 1e-3);
    float eps = 0.002 * scale;
    float t = max(t_start, 0.0);
    for (int s = 0; s < 48; s++) {
        float3 p = ro + rd * t;
        float d = sdf_entity_world(i, p);
        // Ray ORIGIN inside the SDF (camera inside an entity): don't render
        // it — a t=0 "hit" has a degenerate normal and blacks out the view.
        // The AABB's ANIM_MARGIN padding guarantees d >= margin at a real
        // box entry, so d < eps on the first sample only happens inside.
        if (s == 0 && d < eps) break;
        if (d < eps) return t;
        t += d * 0.9;
        if (t > t_end) break;
    }
    return 1e30;
}

// Nearest entity hit along the ray, or index -1. t_max lets the caller pass
// the voxel hit distance so occluded entities exit on the AABB test alone.
EntityHit trace_entities(float3 ro, float3 rd, float t_max) {
    EntityHit hit;
    hit.index   = -1;
    hit.t       = 1e30;
    hit.hit_pos = float3(0, 0, 0);
    hit.normal  = float3(0, 1, 0);
    hit.part    = -1;

    float3 urd = rd;
    rd = esafe_dir(rd);
    float3 inv_rd = 1.0 / rd;
    for (int i = 0; i < u_entity_count; i++) {
        float4 e1 = sdf_entities[i * ENTITY_STRIDE + 1];
        float3 bmax = sdf_entities[i * ENTITY_STRIDE + 2].xyz;
        float t0, t1;
        if (!ray_aabb(ro, inv_rd, e1.xyz, bmax, t0, t1)) continue;
        if (t0 > min(hit.t, t_max)) continue;
        if (int(e1.w + 0.5) == ENTITY_KIND_GLIDER) {
            float3 n; int part;
            float t = glider_trace(i, ro, urd, min(hit.t, t_max), n, part);
            if (t < hit.t) {
                hit.index = i; hit.t = t; hit.normal = n; hit.part = part;
            }
            continue;
        }
        float t = sdf_trace(ro, rd, t0, min(t1, min(hit.t, t_max)), i);
        if (t < hit.t) {
            hit.index = i;
            hit.t     = t;
            hit.part  = -1;
        }
    }
    if (hit.index >= 0) hit.hit_pos = ro + rd * hit.t;
    return hit;
}

// Any-hit shadow test: 0 = blocked by an entity, 1 = clear. Cheaper trace
// (fewer steps, coarse epsilon) and early-out on the first occluder.
float entity_shadow_transmittance(float3 ro, float3 rd, float max_t) {
    if (u_entity_count == 0) return 1.0;
    float3 urd = rd;
    rd = esafe_dir(rd);
    float3 inv_rd = 1.0 / rd;
    for (int i = 0; i < u_entity_count; i++) {
        float4 e1 = sdf_entities[i * ENTITY_STRIDE + 1];
        float3 bmax = sdf_entities[i * ENTITY_STRIDE + 2].xyz;
        float t0, t1;
        if (!ray_aabb(ro, inv_rd, e1.xyz, bmax, t0, t1)) continue;
        if (t0 > max_t) continue;
        if (int(e1.w + 0.5) == ENTITY_KIND_GLIDER) {
            float3 n; int part;
            if (glider_trace(i, ro, urd, max_t, n, part) < 1e29) return 0.0;
            continue;
        }
        float t = max(t0, 0.0);
        float t_end = min(t1, max_t);
        for (int s = 0; s < 24; s++) {
            float d = sdf_entity_world(i, ro + rd * t);
            if (d < 0.01) return 0.0;
            t += d * 0.9;
            if (t > t_end) break;
        }
    }
    return 1.0;
}

#endif // ENTITY_SDF_HLSL
