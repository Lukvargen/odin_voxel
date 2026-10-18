package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

// Saplings: a felled tree's leaves drop a few (item_change), and one planted
// in grass or dirt grows into a tree after a while: the kind that grows
// there (biome_trees). The server keeps the planted ones (Server.saplings),
// grows them while their ground is loaded (someone's about), tells everyone
// the new tree's blocks, and keeps the list with the world (saplings.txt).

SAPLING_GROW_MIN :: f32(150) // seconds from planting
SAPLING_GROW_MAX :: f32(300)
SAPLING_RETRY    :: f32(20)  // not loaded, or no room: looked at again after this

Sapling_Growing :: struct {
    pos:  [3]int,
    left: f32, // seconds until it grows
}

// A sapling went into the world at p (server_write).
server_sapling_planted :: proc(srv: ^Server, p: [3]int) {
    for s in srv.saplings { if s.pos == p { return } }
    append(&srv.saplings, Sapling_Growing{p, rand.float32_range(SAPLING_GROW_MIN, SAPLING_GROW_MAX)})
}

// Saplings grow, every step.
server_saplings_update :: proc(srv: ^Server, dt: f32) {
    w := srv.sim.world
    for i := 0; i < len(srv.saplings); {
        s := &srv.saplings[i]
        s.left -= dt
        if s.left > 0 { i += 1; continue }
        p := s.pos
        if ([2]int{p.x >> 3, p.z >> 3}) not_in w.columns { s.left = SAPLING_RETRY; i += 1; continue } // nobody about
        if Block_Type(u8(get_voxel(w, p.x, p.y, p.z))) != .Sapling { unordered_remove(&srv.saplings, i); continue } // taken
        if !sapling_ground(Block_Type(u8(get_voxel(w, p.x, p.y - 1, p.z)))) { unordered_remove(&srv.saplings, i); continue }
        sapling_grow(srv, p)
        unordered_remove(&srv.saplings, i)
    }
}

// What a sapling takes root in.
sapling_ground :: proc(b: Block_Type) -> bool {
    return b == .Grass || b == .Dirt || b == .Dry_Grass || b == .Moss || b == .Snow
}

// The tree a sapling at p grows into: one of those that grow there, by how
// common it is, picked by its spot (so it's the same for everyone).
sapling_kind :: proc(p: [3]int) -> Tree_Kind {
    rates := biome_trees(terrain_at(p.x, p.z))
    total := 0.0
    for r in rates { if sapling_grows_into(r.kind) { total += r.density } }
    if total <= 0 { return .Small_Oak }
    h := tree_hash(p.x, p.z + p.y * 7919, 33) * total
    for r in rates {
        if !sapling_grows_into(r.kind) { continue }
        h -= r.density
        if h < 0 { return r.kind }
    }
    return .Small_Oak
}

@(private="file")
sapling_grows_into :: proc(k: Tree_Kind) -> bool {
    #partial switch k {
    case .Oak, .Medium_Oak, .Small_Oak, .Spruce, .Birch, .Acacia, .Willow: return true
    }
    return false
}

// The tree goes up: generated as the world's trees are, a column at a time
// into scratch columns, then into the world wherever there's room (air, or
// plants; leaves only into air), and everyone's told.
sapling_grow :: proc(srv: ^Server, p: [3]int) {
    w := srv.sim.world
    kind := sapling_kind(p)
    reach := kind == .Oak ? TREE_VOXEL_REACH : 24
    m: Msg_Voxels
    flush :: proc(srv: ^Server, m: ^Msg_Voxels) {
        if m.count == 0 { return }
        server_forward(srv, -1, .Voxels, m^)
        m.count = 0
    }
    for cz := (p.z - reach) >> 3; cz <= (p.z + reach) >> 3; cz += 1 {
        for cx := (p.x - reach) >> 3; cx <= (p.x + reach) >> 3; cx += 1 {
            if ([2]int{cx, cz}) not_in w.columns { continue } // not loaded: that part of it doesn't grow
            scratch := new(Column)
            defer column_free(scratch)
            tgt := Tree_Target{col = scratch, ox = cx * CHUNK_VOXELS, oz = cz * CHUNK_VOXELS, size = CHUNK_VOXELS}
            generate_tree_kind(&tgt, kind, p.x, p.y - 1, p.z)
            for &c, iy in scratch.chunks {
                if c.voxels == nil { continue }
                for v, vi in c.voxels {
                    if v == 0 { continue }
                    q := [3]int{tgt.ox + vi & 7, (iy + WORLD_CHUNK_Y_MIN) * CHUNK_VOXELS + (vi >> 3) & 7, tgt.oz + vi >> 6}
                    cur := u8(get_voxel(w, q.x, q.y, q.z))
                    room := cur == 0 || (block_is_land_plant(cur) && !block_is_leaves(v))
                    if !room { continue }
                    server_write(srv, q, v)
                    m.items[m.count] = {pos = {i32(q.x), i32(q.y), i32(q.z)}, block = v}
                    m.count += 1
                    if m.count == VOXEL_BATCH { flush(srv, &m) }
                }
            }
        }
    }
    flush(srv, &m)
}

// The planted saplings, with the world: "x y z seconds" a line.
saplings_save :: proc(srv: ^Server) {
    if !srv.world.save_enabled { return }
    b := strings.builder_make(context.temp_allocator)
    for s in srv.saplings { fmt.sbprintf(&b, "%d %d %d %.0f\n", s.pos.x, s.pos.y, s.pos.z, s.left) }
    _ = os.make_directory_all(save_dir)
    _ = os.write_entire_file(fmt.tprintf("%s/saplings.txt", save_dir), transmute([]u8)strings.to_string(b))
}

saplings_load :: proc(srv: ^Server) {
    data, err := os.read_entire_file(fmt.tprintf("%s/saplings.txt", save_dir), context.temp_allocator)
    if err != nil { return }
    for line in strings.split_lines(string(data), context.temp_allocator) {
        f := strings.fields(line, context.temp_allocator)
        if len(f) != 4 { continue }
        x, ok1 := strconv.parse_int(f[0])
        y, ok2 := strconv.parse_int(f[1])
        z, ok3 := strconv.parse_int(f[2])
        left, ok4 := strconv.parse_f32(f[3])
        if ok1 && ok2 && ok3 && ok4 { append(&srv.saplings, Sapling_Growing{{x, y, z}, left}) }
    }
}
