package main

import "core:mem"

// Messages between a client and the server, and the link that carries them.
//
// A message is a kind byte and a fixed-size body copied as raw memory: both
// ends run the same build (a handshake will check, once players connect
// from elsewhere), so the layouts agree. Bodies are self-delimiting, so a
// stream of them needs no framing: one packet is any number of messages
// back to back.
//
// Anything read from a remote peer is untrusted: the server checks indices
// and kinds before using them (server_receive).

Msg_Kind :: enum u8 {
    // client → server
    Player_State, // Player: where this client's player is and how it stands
    Hit,          // Msg_Hit: its sword struck something
    Scatter,      // [3]f32: knocked out here: everything about is flung away
    Set_Hour,     // f32: the clock set (options)
    Set_Paused,   // bool: the clock stopped or running
    Set_Monsters, // bool: slimes and enemies on or off (options)
    Spawn,        // Msg_Spawn: debug F6 / F8
    Clear,        // no body: every slime and enemy gone (debug F7)
    // server → client
    Event,        // Sim_Event
}

Target_Kind :: enum u8 { Slime, Enemy }

Msg_Hit :: struct {
    target:  Target_Kind,
    boosted: bool,
    index:   u16,    // in the slime or enemy list...
    uid:     u32,    // ...if it is still the one that was struck
    damage:  f32,
    knock:   [3]f32,
    freeze:  f32,    // stuck on the blade this long, unless it died
}

Msg_Spawn :: struct {
    target: Target_Kind,
    kind:   u8,     // Slime_Size or Enemy_Kind
    pos:    [3]f32,
    yaw:    f32,
}

msg_put :: proc(buf: ^[dynamic]u8, kind: Msg_Kind, body: $T) {
    body := body
    append(buf, u8(kind))
    append(buf, ..mem.ptr_to_bytes(&body))
}

msg_put_empty :: proc(buf: ^[dynamic]u8, kind: Msg_Kind) {
    append(buf, u8(kind))
}

Msg_Reader :: struct {
    data: []u8,
    at:   int,
}

// The next message's kind; false at the end, or on garbage (the rest is dropped).
msg_next :: proc(r: ^Msg_Reader) -> (kind: Msg_Kind, ok: bool) {
    if r.at >= len(r.data) { return }
    k := r.data[r.at]
    r.at += 1
    if k > u8(max(Msg_Kind)) {
        r.at = len(r.data)
        return
    }
    return Msg_Kind(k), true
}

// The body of the message msg_next just named.
msg_get :: proc(r: ^Msg_Reader, $T: typeid) -> (v: T, ok: bool) {
    if r.at + size_of(T) > len(r.data) {
        r.at = len(r.data)
        return
    }
    mem.copy(&v, &r.data[r.at], size_of(T))
    r.at += size_of(T)
    return v, true
}

// The in-process connection between this client and its own server
// (singleplayer, or the host's own player): the bytes each side has sent
// and the other not yet read. Players elsewhere connect over ENet instead.
Loopback :: struct {
    to_server: [dynamic]u8,
    to_client: [dynamic]u8,
}
