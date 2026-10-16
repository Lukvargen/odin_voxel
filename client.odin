package main

import "core:fmt"
import "core:math"
import enet "vendor:ENet"

// The client's half of the conversation with the server (server.odin): it
// tells the server about its player and asks for things in messages
// (net.odin), never by touching the simulation, and plays what the server
// reports back.
//
// Either the server is its own, in-process (singleplayer, or hosting: the
// messages go over gs.loop, and the client draws the simulation's slimes
// and enemies straight from it, as it shares its World), or it joined one
// elsewhere over ENet (client_join): then it runs no simulation of its own.
//
// Each frame: client_send_input, then (with its own server) server_step,
// then client_receive.

Client_Net :: struct {
    out:      Outbox,
    remote:   bool,       // joined a server elsewhere (for good: no own server if it drops)
    host:     ^enet.Host, // our end of it, while connected
    peer:     ^enet.Peer,
    slot:     int,        // our player slot
    welcomed: bool,       // the server took us in (until then nothing is sent)
    others:   [MAX_PLAYERS]Other_Player, // the other players, as the server last said
}

// Another player, drawn where its client last said it was.
Other_Player :: struct {
    active: bool,
    latest: Player,  // as last heard
    age:    f32,     // seconds since
    pos:    [3]f32,  // drawn here (eye), easing after latest
    anim:   Player_Anim,
}

OTHER_TIMEOUT :: 3 // seconds without word before another player is no longer drawn

client_joined :: proc(gs: ^Game_State) -> bool { return gs.net.remote }

// Connect to a server elsewhere ("host[:port]"). ENet must be initialized.
client_join :: proc(gs: ^Game_State, address: string) -> bool {
    addr, ok := net_address(address)
    if !ok {
        fmt.eprintln("Join: can't resolve", address)
        return false
    }
    gs.net.host = enet.host_create(nil, 1, NET_CHANNELS, 0, 0)
    if gs.net.host == nil {
        fmt.eprintln("Join: can't open a UDP socket")
        return false
    }
    gs.net.peer = enet.host_connect(gs.net.host, &addr, NET_CHANNELS, 0)
    if gs.net.peer == nil {
        fmt.eprintln("Join: can't connect to", address)
        enet.host_destroy(gs.net.host)
        gs.net.host = nil
        return false
    }
    gs.net.remote = true
    fmt.println("Join: connecting to", address)
    return true
}

client_leave :: proc(gs: ^Game_State) {
    n := &gs.net
    if n.host == nil { return }
    if n.peer != nil { enet.peer_disconnect(n.peer, 0) }
    enet.host_flush(n.host)
    enet.host_destroy(n.host)
    n.host, n.peer = nil, nil
}

client_send :: proc(gs: ^Game_State, kind: Msg_Kind, body: $T) {
    outbox_put(&gs.net.out, kind, body)
}

client_send_empty :: proc(gs: ^Game_State, kind: Msg_Kind) {
    outbox_put_empty(&gs.net.out, kind)
}

// Each frame before the server steps: where this client's player is and
// how it stands (its defence decides blows: hurt_outcome), and whether
// monsters are on; then everything gathered goes out.
client_send_input :: proc(gs: ^Game_State) {
    cam := &gs.camera
    c := &gs.combat
    client_send(gs, .Player_State, Player{
        active = true, pos = cam.pos, velocity = cam.velocity, yaw = cam.yaw, pitch = cam.pitch,
        on_ground = cam.on_ground, fly_mode = cam.fly_mode, sneaking = cam.sneaking, sprinting = cam.sprinting,
        sword = c.sword, invuln = c.invuln, blocking = c.blocking, block_time = c.block_time,
    })
    client_send(gs, .Set_Monsters, gs.entities_enabled)

    n := &gs.net
    if !client_joined(gs) {
        outbox_move(&n.out, &gs.loop.to_server)
    } else if n.welcomed && n.peer != nil {
        outbox_send(&n.out, n.peer)
        enet.host_flush(n.host)
    } else {
        clear(&n.out.reliable) // not in yet: the first word must be the Hello
        clear(&n.out.unreliable)
    }
}

// After the server stepped: take in what it sent, play it, then step the
// player out of any monster it walked into.
client_receive :: proc(gs: ^Game_State, dt: f32) {
    client_poll(gs)
    r := Msg_Reader{data = gs.loop.to_client[:]}
    for kind in msg_next(&r) {
        #partial switch kind {
        case .Event:
            ev := msg_get(&r, Sim_Event) or_break
            sim_event_play(gs, ev)
        case .Player_View:
            v := msg_get(&r, Msg_Player_View) or_break
            if int(v.slot) >= MAX_PLAYERS || int(v.slot) == gs.net.slot { break }
            o := &gs.net.others[v.slot]
            if !o.active { o^ = {active = true, pos = v.player.pos, anim = {body_yaw = -math.to_radians(v.player.yaw)}} }
            o.latest, o.age = v.player, 0
        case .Player_Gone:
            slot := msg_get(&r, u8) or_break
            if int(slot) < MAX_PLAYERS && gs.net.others[slot].active {
                gs.net.others[slot].active = false
                ui_toast(gs, fmt.tprintf("Player %d left", slot))
            }
        case .Clock:
            c := msg_get(&r, Msg_Clock) or_break
            if client_joined(gs) { // our own server's clock is ours already
                gs.day.hour, gs.day.paused = c.hour, c.paused
                day_tick(&gs.sim, 0)
            }
        case .Welcome:
            w := msg_get(&r, Msg_Welcome) or_break
            gs.net.slot, gs.net.welcomed = int(w.slot), true
            if w.pos != 0 {
                gs.camera.pos, gs.camera.yaw, gs.camera.velocity = w.pos, w.yaw, {}
            }
            ui_toast(gs, fmt.tprintf("Joined as player %d", w.slot), 3)
        case .Refuse:
            why := msg_get(&r, Refuse_Reason) or_break
            ui_toast(gs, why == .Full ? "The server is full" : "The server runs a different version", 5)
        case: // a client's kind: never sent to one
            r.at = len(r.data)
        }
    }
    clear(&gs.loop.to_client)
    others_update(gs, dt)
    monsters_push_player(gs)
}

// The network's news for a joined client: connected (say Hello), packets
// (into the inbox), dropped.
@(private="file")
client_poll :: proc(gs: ^Game_State) {
    n := &gs.net
    ev: enet.Event
    for n.host != nil && enet.host_service(n.host, &ev, 0) > 0 {
        switch ev.type {
        case .NONE:
        case .CONNECT:
            hello: Outbox
            defer { delete(hello.reliable); delete(hello.unreliable) }
            outbox_put(&hello, .Hello, net_fingerprint())
            outbox_send(&hello, n.peer)
            enet.host_flush(n.host)
        case .RECEIVE:
            append(&gs.loop.to_client, ..ev.packet.data[:ev.packet.dataLength])
            enet.packet_destroy(ev.packet)
        case .DISCONNECT:
            ui_toast(gs, n.welcomed ? "Lost the connection to the server" : "Couldn't reach the server", 5)
            n.welcomed = false
            n.peer = nil
            for &o in n.others { o.active = false }
            enet.host_destroy(n.host)
            n.host = nil
            return
        }
    }
}

// The other players ease toward where they were last heard, a little ahead
// by their speed; one not heard from for a while is gone.
@(private="file")
others_update :: proc(gs: ^Game_State, dt: f32) {
    for &o in gs.net.others {
        if !o.active { continue }
        o.age += dt
        if o.age > OTHER_TIMEOUT {
            o.active = false
            continue
        }
        p := &o.latest
        target := p.pos + p.velocity * min(o.age, 0.2)
        if d := target - o.pos; d.x * d.x + d.y * d.y + d.z * d.z > 64 {
            o.pos = target // teleported or far behind: no gliding across the map
        } else {
            o.pos += d * min(dt * 12, 1)
        }
        anim_step(&o.anim, p.velocity, p.yaw, p.sword, p.on_ground || p.fly_mode, dt)
    }
}

// Each other player's body (creatures.odin), tinted by slot.
others_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    eye := gs.camera.pos
    for &o, slot in gs.net.others {
        if !o.active { continue }
        d := o.pos - eye
        if d.x * d.x + d.y * d.y + d.z * d.z > ENTITY_CULL_RADIUS * ENTITY_CULL_RADIUS { continue }
        if !ent_begin(f) { return }
        feet := o.pos - {0, PLAYER_EYE_HEIGHT, 0}
        humanoid_add_parts(f, feet, &o.anim, o.latest.yaw, o.latest.pitch, player_tint(slot), right_arm = true)
        ent_end(f)
    }
}

// Each player slot its own colour of tunic; slot 0 (the host) the usual.
player_tint :: proc(slot: int) -> [3]f32 {
    if slot == 0 { return PLAYER_TINT }
    h := f32(slot) * 0.61803 // spread round the colour wheel
    h -= math.floor(h)
    return {
        0.25 + 0.4 * (0.5 + 0.5 * math.cos(math.TAU * h)),
        0.25 + 0.4 * (0.5 + 0.5 * math.cos(math.TAU * (h - 0.333))),
        0.25 + 0.4 * (0.5 + 0.5 * math.cos(math.TAU * (h - 0.667))),
    }
}
