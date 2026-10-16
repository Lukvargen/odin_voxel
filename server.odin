package main

// The server: runs the simulation (sim.odin) for its players. Clients only
// talk to it in messages (net.odin): their player's state, their sword's
// hits, requests; it answers with what happened (Sim_Events). In
// singleplayer it runs in-process, over a Loopback; a host also opens it
// to players elsewhere.
//
// Each step: take in what the clients sent (server_receive), run the world
// (server_simulate), send out what happened (server_flush).

Server :: struct {
    sim:    ^Sim,
    link:   ^Loopback, // the local client
    player: int,       // the local client's player slot
}

server_init :: proc(srv: ^Server, sim: ^Sim, link: ^Loopback) {
    srv^ = {sim = sim, link = link, player = LOCAL_PLAYER}
}

server_step :: proc(srv: ^Server, dt: f32) {
    server_receive(srv)
    server_simulate(srv, dt)
    server_flush(srv)
}

server_simulate :: proc(srv: ^Server, dt: f32) {
    day_tick(srv.sim, dt)
    slimes_update(srv.sim, dt)
    enemies_update(srv.sim, dt)
}

// Apply what the local client sent since the last step.
server_receive :: proc(srv: ^Server) {
    sim := srv.sim
    r := Msg_Reader{data = srv.link.to_server[:]}
    defer clear(&srv.link.to_server)
    for kind in msg_next(&r) {
        switch kind {
        case .Player_State:
            p := msg_get(&r, Player) or_break
            p.active = true
            sim.players[srv.player] = p
        case .Hit:
            h := msg_get(&r, Msg_Hit) or_break
            server_hit(srv, h)
        case .Scatter:
            pos := msg_get(&r, [3]f32) or_break
            slimes_scatter(sim, pos)
            enemies_scatter(sim, pos)
        case .Set_Hour:
            h := msg_get(&r, f32) or_break
            if h >= 0 && h < 24 {
                sim.day.hour = h
                day_tick(sim, 0)
            }
        case .Set_Paused:
            sim.day.paused = msg_get(&r, bool) or_break
        case .Set_Monsters:
            sim.monsters = msg_get(&r, bool) or_break
        case .Spawn:
            s := msg_get(&r, Msg_Spawn) or_break
            server_spawn(srv, s)
        case .Clear:
            slimes_clear(sim)
            enemies_clear(sim)
        case .Event: // the server's own kind: a client never sends it
            r.at = len(r.data)
        }
    }
}

// A client's sword struck slime or enemy `index`; if it is still the one it
// struck, it takes the blow, and unless that kills it, sticks on the blade
// a moment (hit stop).
@(private="file")
server_hit :: proc(srv: ^Server, h: Msg_Hit) {
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
        if !enemy_damage(sim, e, h.damage, h.knock, h.boosted, srv.player) { e.freeze = h.freeze }
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

// Send what happened this step to the clients.
server_flush :: proc(srv: ^Server) {
    for ev in srv.sim.events { msg_put(&srv.link.to_client, .Event, ev) }
    clear(&srv.sim.events)
}
