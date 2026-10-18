package main

import la "core:math/linalg"
import "core:time"

// What a survival player carries is the server's to keep (Server.items):
// it counts every block a player's edits change (item_change), turns down
// an edit that would put down a block the player doesn't have (sending the
// voxel back as it is), and tells the player its count (Msg_Items), saved
// with its character. The client counts the same way as it edits, so its
// hotbar answers at once (client_items_predict); the server's word replaces
// that guess as it comes, with the edits it hasn't seen yet counted on top.
// And what's still flying to you as motes (magic.odin) isn't shown yet.

// What a voxel is worth as an item: .Air for nothing (air, water, a door's
// upper parts: a door is one item, at its foot).
voxel_item :: proc(v: u8) -> Block_Type {
    if block_is_door(v) { return door_decode(v).part == 0 ? .Door : .Air }
    if block_is_watery(v) || int(v) >= len(Block_Type) { return .Air }
    return Block_Type(v)
}

// Of a felled tree's leaves, this share come back as leaves (by their spot,
// so the server and the client agree), and this many as saplings too.
FELLED_LEAF_SHARE :: 0.25
FELLED_SAPLINGS   :: 1.0 / 120

// One voxel at p changed from old to new: what the player gains (what was
// there, and with a felled tree's leaves now and then a sapling) and what
// it costs (what's there now); .Air for none. felled: it went with a tree
// coming down, and leaves give back only some.
item_change :: proc(old, new: u8, p: [3]int, felled: bool) -> (gain, extra, cost: Block_Type) {
    if old == new { return .Air, .Air, .Air }
    gain, cost = voxel_item(old), voxel_item(new)
    if felled && block_is_leaves(old) {
        if tree_hash(p.x, p.z + p.y * 7919, 91) >= FELLED_LEAF_SHARE { gain = .Air }
        if tree_hash(p.x, p.z + p.y * 7919, 92) < FELLED_SAPLINGS { extra = .Sapling }
    }
    return
}

// A survival player's edit of the voxel at p to `new`, as the server sees
// it: counted (what the player gains and spends), or false, and then it
// mustn't happen: out of the spell's reach, or a block the player doesn't
// have.
server_survival_edit :: proc(srv: ^Server, slot: int, p: [3]int, new: u8) -> bool {
    old := u8(get_voxel(srv.sim.world, p.x, p.y, p.z))
    if !server_in_reach(srv, slot, p, old, new) { return false }
    gain, extra, cost := item_change(old, new, p, block_is_leaves(old) && fell_granted(srv, slot, p))
    items := &srv.items[slot]
    if cost != .Air && items[cost] == 0 && gain != cost { return false }
    if gain != .Air { items[gain] += 1 }
    if extra != .Air { items[extra] += 1 }
    if cost != .Air { items[cost] -= 1 }
    return true
}

// Past MAGIC_REACH, still in reach: the player moved on a little since its
// client made the edit, and a plant goes with the ground under it.
SURVIVAL_REACH_SLACK :: f32(5)
FELL_GRANT_TIME      :: 3 * time.Second

// A tree a player is felling (Msg_Fell, checked): its wood and leaves may
// go, out of reach as they are, for a little while.
Fell_Grant :: struct {
    cut:   [3]int,
    until: time.Tick,
}

// Whether player `slot` may change the voxel at p from old to new: near
// enough its eye, or part of a tree it's felling (wood and leaves going,
// water flowing in where they were).
@(private="file")
server_in_reach :: proc(srv: ^Server, slot: int, p: [3]int, old, new: u8) -> bool {
    pl := &srv.sim.players[slot]
    if pl.active && la.length(block_center(p) - pl.pos) <= MAGIC_REACH + SURVIVAL_REACH_SLACK { return true }
    tree := (block_is_log(old) || block_is_leaves(old)) && (new == 0 || new == u8(Block_Type.Water))
    flood := old == 0 && new == u8(Block_Type.Water)
    return (tree || flood) && fell_granted(srv, slot, p)
}

// Whether p lies in a tree player `slot` is felling.
@(private="file")
fell_granted :: proc(srv: ^Server, slot: int, p: [3]int) -> bool {
    now := time.tick_now()
    for g in srv.fell_grants[slot] {
        if time.tick_diff(now, g.until) <= 0 { continue }
        d := p - g.cut
        if abs(d.x) <= FIND_R && abs(d.z) <= FIND_R && d.y >= -FIND_BELOW && d.y < FIND_H - FIND_BELOW { return true }
    }
    return false
}

// Player `slot` says it's felling the tree cut at m.cut: fine if it's a log
// in its reach. Then the tree's voxels may go, and the others see it fall.
server_fell :: proc(srv: ^Server, slot: int, m: Msg_Fell) -> bool {
    if !srv.survival { return false }
    p := la.array_cast(m.cut, int)
    pl := &srv.sim.players[slot]
    if !pl.active || la.length(block_center(p) - pl.pos) > MAGIC_REACH + SURVIVAL_REACH_SLACK { return false }
    if !block_is_log(u8(get_voxel(srv.sim.world, p.x, p.y, p.z))) { return false }
    // The older grant makes way.
    grants := &srv.fell_grants[slot]
    k := time.tick_diff(grants[0].until, grants[1].until) > 0 ? 0 : 1
    grants[k] = {cut = p, until = time.tick_add(time.tick_now(), FELL_GRANT_TIME)}
    return true
}

// A player's character arrived (Restore): its things as it left them, or a
// new one's.
server_items_restore :: proc(srv: ^Server, slot: int, rec: Player_Record, known: bool) {
    srv.items[slot] = known ? rec.kept.items : (srv.survival ? survival_fresh().items : {})
    srv.items_due[slot] = true
}

// The edits this client sent, not yet answered by the server's count: each
// commit's gains and costs, by its number.
Item_Guess :: struct {
    seq:   u32,
    delta: [Block_Type]i32,
}

// This client just changed `changed` (old values in `olds`; felled: a tree
// coming down): counted as the server will, under the number its messages
// carry. Survival only.
client_items_predict :: proc(gs: ^Game_State, changed: [][3]int, olds: []u8, felled: bool) -> (seq: u32) {
    n := &gs.net
    n.edit_seq += 1
    if !gs.survival || len(olds) != len(changed) { return n.edit_seq }
    g := Item_Guess{seq = n.edit_seq}
    any := false
    for p, i in changed {
        gain, extra, cost := item_change(olds[i], u8(get_voxel(gs, p.x, p.y, p.z)), p, felled)
        if gain != .Air { g.delta[gain] += 1; any = true }
        if extra != .Air { g.delta[extra] += 1; any = true }
        if cost != .Air { g.delta[cost] -= 1; any = true }
    }
    if any {
        append(&n.item_guesses, g)
        client_items_sum(gs)
    }
    return n.edit_seq
}

// The server's count, as of our edit `seq`.
client_items_heard :: proc(gs: ^Game_State, m: Msg_Items) {
    n := &gs.net
    n.items_base = m.items
    kept := 0
    for g in n.item_guesses {
        if g.seq <= m.seq { continue }
        n.item_guesses[kept] = g
        kept += 1
    }
    resize(&n.item_guesses, kept)
    client_items_sum(gs)
}

// gs.items: the server's count and our guesses since.
client_items_sum :: proc(gs: ^Game_State) {
    n := &gs.net
    for b in Block_Type {
        v := i64(n.items_base[b])
        for g in n.item_guesses { v += i64(g.delta[b]) }
        gs.items[b] = u32(max(v, 0))
    }
}

// What the hotbar shows and you may conjure: what you carry, less what's
// still on its way to you.
items_shown :: proc(gs: ^Game_State, b: Block_Type) -> u32 {
    flying: u32
    for mo in gs.magic.motes {
        if mo.size > 0 && mo.block == b { flying += mo.count }
    }
    return gs.items[b] - min(flying, gs.items[b])
}
