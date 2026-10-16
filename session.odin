package main

import "core:fmt"
import enet "vendor:ENet"

// Multiplayer sessions: opening this game to others, joining someone
// else's, and coming back to your own world. Used by the pause menu's
// Multiplayer tab and the host / join= arguments.
//
// The client never saves: the world and its saves are the server's, ours
// or theirs. Switching server, the client forgets what it saw of the old
// one's (client_reset_world) and the new one sends its list of edited
// columns. Our own server rests while we're joined elsewhere.

@(private="file")
enet_ready: bool

// ENet, started the first time it's needed.
net_ready :: proc() -> bool {
    if !enet_ready {
        if enet.initialize() != 0 {
            fmt.eprintln("Network: ENet failed to start")
            return false
        }
        enet_ready = true
    }
    return true
}

session_hosting :: proc(gs: ^Game_State) -> bool { return gs.server.host != nil }

// Open our server to players elsewhere on UDP `port`.
session_host :: proc(gs: ^Game_State, port: int) -> bool {
    if client_joined(gs) || session_hosting(gs) || !net_ready() { return false }
    return server_host(&gs.server, port)
}

// Close our server to others; whoever joined is let go.
session_stop_hosting :: proc(gs: ^Game_State) {
    if !session_hosting(gs) { return }
    for slot in 0 ..< MAX_PLAYERS {
        if slot != gs.server.local_player { gs.players[slot].active = false }
    }
    server_shutdown(&gs.server)
    for &o in gs.net.others { o.active = false }
}

// Play on the server at `address` instead of our own.
session_join :: proc(gs: ^Game_State, address: string) -> bool {
    if client_joined(gs) || !net_ready() { return false }
    session_stop_hosting(gs)
    // Our own server rests while we're away (saved first): its world, its
    // monsters and its news are no longer what we see.
    server_save_all(&gs.server)
    sim_reset(&gs.sim)
    clear(&gs.loop.to_server)
    clear(&gs.loop.to_client)
    client_reset_world(gs)

    gs.net.home_pos, gs.net.home_yaw = gs.camera.pos, gs.camera.yaw
    gs.net.sent_name = {}
    gs.net.names = {}
    gs.net.restored, gs.net.sent_kept = false, {}
    if !client_join(gs, address) {
        server_greet_local(&gs.server, client_name(gs), resume = false) // still ours, then
        return false
    }
    return true
}

// Back from someone's server to our own world, where we left it.
session_leave :: proc(gs: ^Game_State) {
    if !client_joined(gs) { return }
    client_leave(gs)
    n := &gs.net
    home, yaw := n.home_pos, n.home_yaw
    n.remote, n.welcomed, n.slot, n.arriving = false, false, LOCAL_PLAYER, false
    n.home_pos = {}
    n.sent_name = {}
    n.names = {}
    n.restored, n.sent_kept = false, {}
    for &o in n.others { o.active = false }
    clear(&n.out.reliable)
    clear(&n.out.unreliable)
    clear(&gs.loop.to_server)
    clear(&gs.loop.to_client)
    sim_reset(&gs.sim)
    // Our own server's world again: what we saw of theirs goes, and ours
    // tells us what's edited.
    client_reset_world(gs)
    server_greet_local(&gs.server, client_name(gs), resume = true)
    if home != 0 { client_arrive(gs, home, yaw) }
    ui_toast(gs, "Back in your own world", 3)
}

// Close everything at exit.
session_shutdown :: proc(gs: ^Game_State) {
    client_leave(gs)
    server_shutdown(&gs.server)
    if enet_ready {
        enet.deinitialize()
        enet_ready = false
    }
}

// The simulation emptied: no monsters, no players, nothing pending.
sim_reset :: proc(s: ^Sim) {
    for &sl in s.slimes.list { sl.alive = false }
    for &e in s.enemies.list { e.alive = false }
    clear(&s.enemies.sites)
    for &p in s.players { p.active = false }
    clear(&s.events)
}
