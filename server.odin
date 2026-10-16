package main

import "core:fmt"
import "core:math"
import "core:time"
import la "core:math/linalg"
import enet "vendor:ENet"

// The server: runs the simulation (sim.odin) for its players. Clients only
// talk to it in messages (net.odin): their player's state, their sword's
// hits, requests; it answers with what happened (Sim_Events) and where the
// other players are. In singleplayer it runs in-process with one client
// over a Loopback; hosting (server_host) also lets players elsewhere join
// over ENet, each taking a free player slot.
//
// Each step: take in what the clients sent (server_receive), run the world
// (server_simulate), send out what happened (server_flush).
//
// The world's edits: a player's client changes blocks itself and sends the
// results (Voxels, Chunk_Voxels); the server writes them into its World,
// where a column it doesn't have loaded is changed in its save file, and
// passes them on to every other client. A joining client gets the list of
// edited columns (Edited) and asks for those it needs (Column_Request)
// instead of generating them.

VIEW_RATE :: 30 // player views and the clock sent this many times a second

Server :: struct {
    world:        World,     // around every player (server_world.odin); the simulation plays in it
    loader:       Server_Loader,
    stream_timer: f32,
    last_autosave: time.Tick,
    sim:          ^Sim,
    link:         ^Loopback, // the local client
    local_player: int,       // its player slot
    host:         ^enet.Host, // open to players elsewhere; nil when not hosting
    remotes:      [MAX_PLAYERS]Remote, // by player slot
    view_timer:   f32,
    local_out:    Outbox,    // to the local client, moved to link.to_client at the flush
    away:         map[[2]int]^Column, // columns edited this step that aren't loaded: saved, then freed
}

// A player connected over ENet.
Remote :: struct {
    peer: ^enet.Peer, // nil: slot not taken by a remote player
    out:  Outbox,
}

server_init :: proc(srv: ^Server, sim: ^Sim, link: ^Loopback) {
    srv^ = {sim = sim, link = link, local_player = LOCAL_PLAYER}
    sim.world = &srv.world
}

// Open the server to players elsewhere, on UDP `port`. ENet must be
// initialized.
server_host :: proc(srv: ^Server, port: int) -> bool {
    addr := enet.Address{host = enet.HOST_ANY, port = u16(port)}
    srv.host = enet.host_create(&addr, MAX_PLAYERS, NET_CHANNELS, 0, 0)
    if srv.host == nil {
        fmt.eprintln("Host: can't open UDP port", port)
        return false
    }
    fmt.println("Host: open for players on UDP port", port)
    return true
}

server_shutdown :: proc(srv: ^Server) {
    if srv.host == nil { return }
    for &r in srv.remotes { if r.peer != nil { enet.peer_disconnect(r.peer, 0) } }
    enet.host_flush(srv.host)
    enet.host_destroy(srv.host)
    srv.host = nil
}

server_step :: proc(srv: ^Server, dt: f32) {
    server_receive(srv)
    server_stream(srv, dt)
    server_simulate(srv, dt)
    server_flush(srv, dt)
}

server_simulate :: proc(srv: ^Server, dt: f32) {
    day_tick(srv.sim, dt)
    slimes_update(srv.sim, dt)
    enemies_update(srv.sim, dt)
}

// Take in what the clients sent since the last step: the local one's
// bytes, and the network's connections, departures and packets.
server_receive :: proc(srv: ^Server) {
    defer server_save_away(srv)
    server_handle(srv, srv.local_player, srv.link.to_server[:])
    clear(&srv.link.to_server)
    if srv.host == nil { return }
    ev: enet.Event
    for enet.host_service(srv.host, &ev, 0) > 0 {
        switch ev.type {
        case .NONE, .CONNECT: // a slot once it says Hello
        case .RECEIVE:
            data := ev.packet.data[:ev.packet.dataLength]
            if slot := peer_slot(ev.peer); slot >= 0 {
                server_handle(srv, slot, data)
            } else {
                server_greet(srv, ev.peer, data)
            }
            enet.packet_destroy(ev.packet)
        case .DISCONNECT:
            if slot := peer_slot(ev.peer); slot >= 0 { server_drop(srv, slot) }
        }
    }
}

// The player slot an ENet peer holds, or -1 before its Hello.
@(private="file")
peer_slot :: proc(peer: ^enet.Peer) -> int { return int(uintptr(peer.data)) - 1 }

// A new connection's first packet must be a Hello from the same build; it
// then takes a free player slot.
@(private="file")
server_greet :: proc(srv: ^Server, peer: ^enet.Peer, data: []u8) {
    r := Msg_Reader{data = data}
    refuse :: proc(peer: ^enet.Peer, why: Refuse_Reason) {
        o: Outbox
        defer { delete(o.reliable); delete(o.unreliable) }
        outbox_put(&o, .Refuse, why)
        outbox_send(&o, peer)
        enet.peer_disconnect_later(peer, 0)
    }
    if kind, ok := msg_next(&r); !ok || kind != .Hello {
        enet.peer_disconnect(peer, 0)
        return
    }
    if fp, ok := msg_get(&r, u32); !ok || fp != net_fingerprint() {
        refuse(peer, .Version)
        return
    }
    for &rem, slot in srv.remotes {
        if slot == srv.local_player || rem.peer != nil || srv.sim.players[slot].active { continue }
        rem.peer = peer
        peer.data = rawptr(uintptr(slot + 1))
        pos, yaw := arrival_point(srv)
        outbox_put(&rem.out, .Welcome, Msg_Welcome{slot = u8(slot), pos = pos, yaw = yaw})
        server_send_edited(srv, &rem.out)
        fmt.printf("Host: player %d joined from %v\n", slot, peer.address)
        return
    }
    refuse(peer, .Full)
}

// Where a new player appears: a few steps in front of the host, facing it,
// so friends arrive together; zero (the client's own start) if there is no
// open ground there.
@(private="file")
arrival_point :: proc(srv: ^Server) -> (pos: [3]f32, yaw: f32) {
    host := &srv.sim.players[srv.local_player]
    if !host.active { return }
    at := player_feet(host) + player_flat_forward(host) * 4
    x, z := int(math.floor(at.x)), int(math.floor(at.z))
    // The ground near the host's height, with room to stand.
    for y := int(at.y) + 3; y > int(at.y) - 6; y -= 1 {
        if solid_at(srv.sim.world, x, y - 1, z) && !solid_at(srv.sim.world, x, y, z) && !solid_at(srv.sim.world, x, y + 1, z) {
            return {f32(x) + 0.5, f32(y) + PLAYER_EYE_HEIGHT, f32(z) + 0.5}, host.yaw + 180
        }
    }
    return
}

// A remote player left (or timed out): its slot empties.
@(private="file")
server_drop :: proc(srv: ^Server, slot: int) {
    rem := &srv.remotes[slot]
    rem.peer.data = nil
    rem.peer = nil
    clear(&rem.out.reliable)
    clear(&rem.out.unreliable)
    srv.sim.players[slot].active = false
    server_broadcast(srv, .Player_Gone, u8(slot))
    fmt.printf("Host: player %d left\n", slot)
}

// Messages for every client.
server_broadcast :: proc(srv: ^Server, kind: Msg_Kind, body: $T) {
    outbox_put(&srv.local_out, kind, body)
    for &rem in srv.remotes { if rem.peer != nil { outbox_put(&rem.out, kind, body) } }
}

// Messages for every client but player `from`'s.
server_forward :: proc(srv: ^Server, from: int, kind: Msg_Kind, body: $T) {
    if from != srv.local_player { outbox_put(&srv.local_out, kind, body) }
    for &rem, slot in srv.remotes { if rem.peer != nil && slot != from { outbox_put(&rem.out, kind, body) } }
}

// Player `player`'s client's outbox.
@(private="file")
server_outbox :: proc(srv: ^Server, player: int) -> ^Outbox {
    return player == srv.local_player ? &srv.local_out : &srv.remotes[player].out
}

// Apply what player `player`'s client sent. The local player is the host:
// only it may set the clock, toggle monsters, spawn and clear.
server_handle :: proc(srv: ^Server, player: int, data: []u8) {
    sim := srv.sim
    admin := player == srv.local_player
    r := Msg_Reader{data = data}
    for kind in msg_next(&r) {
        switch kind {
        case .Player_State:
            p := msg_get(&r, Player) or_break
            p.active = true
            sim.players[player] = p
        case .Hit:
            h := msg_get(&r, Msg_Hit) or_break
            server_hit(srv, player, h)
        case .Scatter:
            pos := msg_get(&r, [3]f32) or_break
            slimes_scatter(sim, pos)
            enemies_scatter(sim, pos)
        case .Set_Hour:
            h := msg_get(&r, f32) or_break
            if admin && h >= 0 && h < 24 {
                sim.day.hour = h
                day_tick(sim, 0)
            }
        case .Set_Paused:
            paused := msg_get(&r, bool) or_break
            if admin { sim.day.paused = paused }
        case .Set_Monsters:
            on := msg_get(&r, bool) or_break
            if admin { sim.monsters = on }
        case .Spawn:
            s := msg_get(&r, Msg_Spawn) or_break
            if admin { server_spawn(srv, s) }
        case .Clear:
            if admin {
                slimes_clear(sim)
                enemies_clear(sim)
            }
        case .Voxels:
            m := msg_get(&r, Msg_Voxels) or_break
            m.count = min(m.count, VOXEL_BATCH)
            for v in m.items[:m.count] { server_write(srv, la.array_cast(v.pos, int), v.block) }
            server_forward(srv, player, .Voxels, m)
        case .Chunk_Voxels:
            m := msg_get(&r, Msg_Chunk_Voxels) or_break
            if chunk_y_index(int(m.key.y)) < 0 { break }
            base := la.array_cast(m.key, int) * CHUNK_VOXELS
            for v, vi in m.voxels {
                server_write(srv, base + {vi & 7, (vi >> 3) & 7, vi >> 6}, v)
            }
            server_forward(srv, player, .Chunk_Voxels, m)
        case .Column_Request:
            key := msg_get(&r, [2]i32) or_break
            server_send_column(srv, server_outbox(srv, player), {int(key.x), int(key.y)})
        case .Hello, .Welcome, .Refuse, .Player_View, .Player_Gone, .Clock, .Event, .Edited, .Column_Data, .Monsters, .Slime_View, .Enemy_View:
            r.at = len(r.data) // not a connected client's to send: drop the rest
        }
    }
}

// Player `by`'s sword struck slime or enemy `index`; if it is still the one
// it struck, it takes the blow, and unless that kills it, sticks on the
// blade a moment (hit stop).
@(private="file")
server_hit :: proc(srv: ^Server, by: int, h: Msg_Hit) {
    sim := srv.sim
    switch h.target {
    case .Slime:
        if int(h.index) >= MAX_SLIMES { return }
        sl := &sim.slimes.list[h.index]
        if !sl.alive || sl.uid != h.uid { return }
        if !slime_damage(sim, sl, h.damage, h.knock, h.boosted) { sl.freeze = h.freeze }
    case .Enemy:
        if int(h.index) >= MAX_ENEMIES { return }
        e := &sim.enemies.list[h.index]
        if !e.alive || e.uid != h.uid || e.state == .Dead { return }
        if !enemy_damage(sim, e, h.damage, h.knock, h.boosted, by) { e.freeze = h.freeze }
    }
}

// One block a player changed, into the world: its loaded column, or the
// column's save (server_save_away).
@(private="file")
server_write :: proc(srv: ^Server, p: [3]int, block: u8) {
    if p.y < WORLD_Y_MIN || p.y >= WORLD_Y_MAX || int(block) >= len(Block_Type) { return }
    w := srv.sim.world
    key := [2]int{p.x >> 3, p.z >> 3} // CHUNK_VOXELS == 8
    col := w.columns[key]
    if col == nil {
        col = srv.away[key]
        if col == nil {
            col = key in w.saved_columns ? load_column(key) : nil
            if col == nil { col = generate_column_at(key.x, key.y) }
            srv.away[key] = col
        }
    }
    vi := (p.x & 7) + (p.y & 7) * CHUNK_VOXELS + (p.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS
    if chunk_set_voxel(&col.chunks[chunk_y_index(p.y >> 3)], vi, block) { col.modified = true }
}

// The columns edited out of the loaded world this step go to their saves.
@(private="file")
server_save_away :: proc(srv: ^Server) {
    for key, col in srv.away {
        save_column(srv.sim.world, key, col)
        column_free(col)
    }
    clear(&srv.away)
}

// Every column that differs from the generated world: saved, or edited
// since the last save.
server_send_edited :: proc(srv: ^Server, o: ^Outbox) {
    w := srv.sim.world
    m: Msg_Edited
    add :: proc(o: ^Outbox, m: ^Msg_Edited, key: [2]int) {
        m.keys[m.count] = {i32(key.x), i32(key.y)}
        m.count += 1
        if int(m.count) == len(m.keys) {
            outbox_put(o, .Edited, m^)
            m.count = 0
        }
    }
    for key in w.saved_columns { add(o, &m, key) }
    for key, col in w.columns { if col.modified && !(key in w.saved_columns) { add(o, &m, key) } }
    if m.count > 0 { outbox_put(o, .Edited, m) }
}

// A column, as the server has it: loaded (with its latest edits), saved,
// or (size 0) neither, so the client generates it itself.
@(private="file")
server_send_column :: proc(srv: ^Server, o: ^Outbox, key: [2]int) {
    w := srv.sim.world
    bytes := make([dynamic]u8, 0, 4096, context.temp_allocator)
    if col := w.columns[key]; col != nil {
        column_encode(col, &bytes)
    } else if key in w.saved_columns {
        if col := load_column(key); col != nil {
            column_encode(col, &bytes)
            column_free(col)
        }
    }
    outbox_put_bytes(o, .Column_Data, Msg_Column_Data{key = {i32(key.x), i32(key.y)}, size = u32(len(bytes))}, bytes[:])
}

// The slimes and enemies within view of `eye`, and which slots are taken.
@(private="file")
server_send_monsters :: proc(srv: ^Server, o: ^Outbox, eye: [3]f32) {
    sim := srv.sim
    near :: proc(p, eye: [3]f32) -> bool {
        d := p - eye
        return d.x * d.x + d.y * d.y + d.z * d.z < MONSTER_VIEW_RANGE * MONSTER_VIEW_RANGE
    }
    m: Msg_Monsters
    for &sl, i in sim.slimes.list {
        if !sl.alive || !near(sl.pos, eye) { continue }
        m.slimes |= 1 << u64(i)
    }
    for &e, i in sim.enemies.list {
        if !e.alive || !near(e.pos, eye) { continue }
        m.enemies |= 1 << u32(i)
    }
    outbox_put(o, .Monsters, m)
    for &sl, i in sim.slimes.list {
        if m.slimes & (1 << u64(i)) == 0 { continue }
        outbox_put(o, .Slime_View, Msg_Slime_View{
            index = u8(i), size = sl.size, state = sl.state, on_ground = sl.on_ground, uid = sl.uid,
            pos = sl.pos, vel = sl.vel, color = sl.color,
            yaw = sl.yaw, squash = sl.squash, flash = sl.flash, freeze = sl.freeze, bar = sl.bar, hp = sl.hp, age = sl.age,
        })
    }
    for &e, i in sim.enemies.list {
        if m.enemies & (1 << u32(i)) == 0 { continue }
        outbox_put(o, .Enemy_View, Msg_Enemy_View{
            index = u8(i), kind = e.kind, state = e.state, swing = e.swing, on_ground = e.on_ground, uid = e.uid,
            pos = e.pos, vel = e.vel, tint = e.tint,
            yaw = e.yaw, timer = e.timer, flash = e.flash, freeze = e.freeze, bar = e.bar, hp = e.hp,
            death = e.death, rising = e.rising, walk_phase = e.walk_phase, speed = e.speed, age = e.age,
        })
    }
}

@(private="file")
server_spawn :: proc(srv: ^Server, s: Msg_Spawn) {
    sim := srv.sim
    switch s.target {
    case .Slime:
        if int(s.kind) >= len(Slime_Size) { return }
        color := slime_color_for(terrain_at(int(s.pos.x), int(s.pos.z)).biome)
        if sl := slime_spawn(&sim.slimes, Slime_Size(s.kind), s.pos, {}, color); sl != nil { sl.yaw = s.yaw }
    case .Enemy:
        if int(s.kind) >= len(Enemy_Kind) { return }
        if e := enemy_spawn(sim, Enemy_Kind(s.kind), s.pos); e != nil { e.yaw = s.yaw }
    }
}

// Send what happened this step to the clients; VIEW_RATE times a second
// also where each player is (to all but itself) and the clock.
server_flush :: proc(srv: ^Server, dt: f32) {
    sim := srv.sim
    for ev in sim.events { server_broadcast(srv, .Event, ev) }
    clear(&sim.events)

    srv.view_timer -= dt
    if srv.view_timer <= 0 {
        srv.view_timer = 1.0 / VIEW_RATE
        server_broadcast(srv, .Clock, Msg_Clock{hour = sim.day.hour, paused = sim.day.paused})
        for &p, slot in sim.players {
            if !p.active { continue }
            view := Msg_Player_View{slot = u8(slot), player = p}
            if slot != srv.local_player { outbox_put(&srv.local_out, .Player_View, view) }
            for &rem, rs in srv.remotes {
                if rem.peer != nil && rs != slot { outbox_put(&rem.out, .Player_View, view) }
            }
        }
        // The local client shares the simulation; the others see its monsters.
        for &rem, rs in srv.remotes {
            if rem.peer != nil && sim.players[rs].active { server_send_monsters(srv, &rem.out, sim.players[rs].pos) }
        }
    }

    outbox_move(&srv.local_out, &srv.link.to_client)
    if srv.host == nil { return }
    for &rem in srv.remotes { if rem.peer != nil { outbox_send(&rem.out, rem.peer) } }
    enet.host_flush(srv.host)
}
