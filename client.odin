package main

// The client's half of the conversation with the server (server.odin): it
// tells the server about its player and asks for things in messages
// (net.odin), never by touching the simulation, and plays what the server
// reports back.
//
// In singleplayer the server runs in-process (gs.server, over gs.loop),
// and the client still reads the simulation's slimes and enemies directly
// to draw them, as it shares its World.

client_send :: proc(gs: ^Game_State, kind: Msg_Kind, body: $T) {
    msg_put(&gs.loop.to_server, kind, body)
}

client_send_empty :: proc(gs: ^Game_State, kind: Msg_Kind) {
    msg_put_empty(&gs.loop.to_server, kind)
}

// Each frame before the server steps: where this client's player is and
// how it stands (its defence decides blows: hurt_outcome), and whether
// monsters are on.
client_send_input :: proc(gs: ^Game_State) {
    cam := &gs.camera
    c := &gs.combat
    client_send(gs, .Player_State, Player{
        active = true, pos = cam.pos, velocity = cam.velocity, yaw = cam.yaw,
        fly_mode = cam.fly_mode, sneaking = cam.sneaking, sprinting = cam.sprinting,
        sword = c.sword, invuln = c.invuln, blocking = c.blocking, block_time = c.block_time,
    })
    client_send(gs, .Set_Monsters, gs.entities_enabled)
}

// After the server stepped: play what happened, then step the player out of
// any monster it walked into.
client_receive :: proc(gs: ^Game_State) {
    r := Msg_Reader{data = gs.loop.to_client[:]}
    for kind in msg_next(&r) {
        #partial switch kind {
        case .Event:
            ev := msg_get(&r, Sim_Event) or_break
            sim_event_play(gs, ev)
        case: // a client's kind: never sent to one
            r.at = len(r.data)
        }
    }
    clear(&gs.loop.to_client)
    monsters_push_player(gs)
}
