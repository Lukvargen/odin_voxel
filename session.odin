package main

import "core:fmt"
import enet "vendor:ENet"

// Multiplayer sessions: opening this game to others, joining someone
// else's, and coming back to your own world. Used by the pause menu's
// Multiplayer tab and the host / join= arguments.
//
// Joined, the world is the server's: this client keeps no saves, and the
// columns that came from your own saves make way for freshly generated
// ones (the server's edits will come over the network). Leaving throws
// away whatever changed while away and brings your saved world back.

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
    if gs.save_enabled { save_all_modified(gs) }

    // Our own saved columns make way for the plain generated world.
    gs.save_enabled = false
    unload_columns(gs, gs.saved_columns)
    clear(&gs.saved_columns)
    enqueue_chunks(gs)

    // Our own server stops: its monsters and news are no longer ours.
    sim_reset(&gs.sim)
    clear(&gs.loop.to_server)
    clear(&gs.loop.to_client)

    gs.net.home_pos, gs.net.home_yaw = gs.camera.pos, gs.camera.yaw
    if !client_join(gs, address) {
        session_restore_world(gs)
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
    for &o in n.others { o.active = false }
    clear(&n.edited)
    clear(&n.requested)
    clear(&n.out.reliable)
    clear(&n.out.unreliable)
    clear(&gs.loop.to_server)
    clear(&gs.loop.to_client)
    sim_reset(&gs.sim)
    session_restore_world(gs)
    if home != 0 { client_arrive(gs, home, yaw) }
    ui_toast(gs, "Back in your own world", 3)
}

// Our saves again: what changed while joined goes, the saved columns come
// back from disk.
@(private="file")
session_restore_world :: proc(gs: ^Game_State) {
    gs.save_enabled = false
    unload_columns(gs, nil) // changed while away: never saved into our world
    save_init(gs)
    unload_columns(gs, gs.saved_columns)
    enqueue_chunks(gs)
}

// Unload the resident columns in `keys` (the modified ones if nil) without
// saving them; streaming fetches them again (enqueue_chunks).
@(private="file")
unload_columns :: proc(gs: ^Game_State, keys: map[[2]int]bool) {
    drop := make([dynamic][2]int, context.temp_allocator)
    for key, col in gs.columns {
        if keys == nil ? col.modified : key in keys { append(&drop, key) }
    }
    for key in drop {
        gs.columns[key].modified = false
        unload_column(gs, key)
    }
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
