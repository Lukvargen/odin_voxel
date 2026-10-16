package main

import "core:mem"
import "core:strings"
import enet "vendor:ENet"

// Messages between a client and the server, and the link that carries them.
//
// A message is a kind byte and a fixed-size body copied as raw memory: both
// ends run the same build (the handshake checks: net_fingerprint), so the
// layouts agree. Bodies are self-delimiting, so a
// stream of them needs no framing: one packet is any number of messages
// back to back.
//
// Anything read from a remote peer is untrusted: the server checks indices
// and kinds before using them (server_handle).
//
// Over ENet a peer has two channels: reliable and in order for hits,
// requests and events, and unreliable for player states, where only the
// newest matters (msg_reliable). A remote client first says Hello with its
// protocol fingerprint; the server answers Welcome (with its player slot)
// or Refuse.

NET_PORT    :: 47100
NET_VERSION :: u32(1) // bump when messages change meaning without changing size

// Changes whenever a message layout does, so mismatched builds refuse each
// other instead of misreading bytes.
net_fingerprint :: proc() -> u32 {
    h := NET_VERSION * 2654435761
    for n in ([]int{size_of(Player), size_of(Sim_Event), size_of(Msg_Hit), size_of(Msg_Spawn), size_of(Msg_Player_View), size_of(Msg_Clock), size_of(Msg_Welcome), size_of(Msg_Voxels), size_of(Msg_Chunk_Voxels), size_of(Msg_Edited), size_of(Msg_Column_Data), size_of(Msg_Monsters), size_of(Msg_Slime_View), size_of(Msg_Enemy_View), size_of(Msg_Text), size_of(Msg_Player_Name), size_of(Msg_Chat_Line), size_of(Msg_Restore), size_of(Player_Kept), size_of(Msg_Rules), len(Msg_Kind), len(Sim_Event_Kind)}) {
        h = (h ~ u32(n)) * 16777619
    }
    return h
}

Msg_Kind :: enum u8 {
    // client → server
    Hello,        // u32: its net_fingerprint, before anything else
    Player_State, // Player: where this client's player is and how it stands
    Hit,          // Msg_Hit: its sword struck something
    Scatter,      // [3]f32: knocked out here: everything about is flung away
    Set_Hour,     // f32: the clock set (options)
    Set_Paused,   // bool: the clock stopped or running
    Set_Monsters, // bool: slimes and enemies on or off (options)
    Spawn,        // Msg_Spawn: debug F6 / F8
    Clear,        // no body: every slime and enemy gone (debug F7)
    Set_Name,     // Msg_Text: what this client's player is called
    Say,          // Msg_Text: a chat line
    Column_Request, // [2]i32: an edited column (Edited), please
    Keep,         // Player_Kept: what this client's player carries, when it changes (player_save.odin)
    // both ways: blocks a player changed (client → server → the others)
    Voxels,       // Msg_Voxels
    Chunk_Voxels, // Msg_Chunk_Voxels: a whole chunk, when an edit changed much of it
    // server → client
    Welcome,      // Msg_Welcome: your player slot, and where to appear
    Refuse,       // Refuse_Reason
    Player_View,  // Msg_Player_View: another player, as its client last said
    Player_Gone,  // u8: that player's slot is empty now
    Clock,        // Msg_Clock
    Event,        // Sim_Event
    Monsters,     // Msg_Monsters: which slime and enemy slots near you are taken (the rest are gone)
    Slime_View,   // Msg_Slime_View: one of them, as it is now
    Enemy_View,   // Msg_Enemy_View
    Edited,       // Msg_Edited: columns that differ from the generated world (ask for them)
    Column_Data,  // Msg_Column_Data, then `size` bytes: the column, run-length (column_encode)
    Player_Name,  // Msg_Player_Name: what a player is called
    Restore,      // Msg_Restore: your character here: carry on as you were, or start fresh
    Chat_Line,    // Msg_Chat_Line: a chat line, or the server's news (someone joined, left)
    Rules,        // Msg_Rules: what the host lets visitors do
}

TEXT_MAX    :: 96   // bytes of a chat line
NAME_MAX    :: 20   // bytes of a name
SERVER_SLOT :: 0xff // Chat_Line from the server itself

// A short piece of text: printable ASCII only (text_set), so it draws.
Msg_Text :: struct {
    len:  u8,
    text: [TEXT_MAX]u8,
}

Msg_Restore :: struct {
    known:  bool, // been here before: record is how they left; else start fresh
    move:   bool, // to record.pos (not when told where to start: at=)
    record: Player_Record,
}

Msg_Rules :: struct {
    guests_build: bool, // players other than the host may change blocks
}

Msg_Player_Name :: struct {
    slot: u8,
    name: Msg_Text,
}

Msg_Chat_Line :: struct {
    slot: u8, // who said it, or SERVER_SLOT
    line: Msg_Text,
}

// s as a Msg_Text, at most max bytes, unprintable bytes dropped and the
// ends trimmed.
text_set :: proc(s: string, max := TEXT_MAX) -> (t: Msg_Text) {
    for c in transmute([]u8)s {
        if c < 0x20 || c > 0x7e || int(t.len) >= min(max, TEXT_MAX) { continue }
        if c == ' ' && t.len == 0 { continue }
        t.text[t.len] = c
        t.len += 1
    }
    for t.len > 0 && t.text[t.len - 1] == ' ' { t.len -= 1 }
    return
}

// A received Msg_Text, checked: its length in bounds, printable only.
text_of :: proc(t: ^Msg_Text) -> string {
    t^ = text_set(string(t.text[:min(int(t.len), TEXT_MAX)]))
    return string(t.text[:t.len])
}

VOXEL_BATCH :: 32 // single voxels per Voxels message; a chunk with more goes whole

Msg_Voxel :: struct {
    pos:   [3]i32,
    block: u8,
}

Msg_Voxels :: struct {
    count: u8,
    items: [VOXEL_BATCH]Msg_Voxel,
}

Msg_Chunk_Voxels :: struct {
    key:    [3]i32, // world chunk coordinate
    voxels: [VOXELS_PER_BRICK]u8,
}

Msg_Edited :: struct {
    count: u8,
    keys:  [64][2]i32,
}

Msg_Column_Data :: struct {
    key:  [2]i32,
    size: u32, // 0: not edited after all, generate it
}

MAX_COLUMN_BYTES :: COLUMN_VOXELS * 3 // the most a column's run-length bytes can be

// A message whose fixed body is followed by `bytes` (Column_Data).
outbox_put_bytes :: proc(o: ^Outbox, kind: Msg_Kind, body: $T, bytes: []u8) {
    outbox_put(o, kind, body)
    append(msg_reliable(kind) ? &o.reliable : &o.unreliable, ..bytes)
}

// The n bytes following a message's fixed body.
msg_get_bytes :: proc(r: ^Msg_Reader, n: int) -> (b: []u8, ok: bool) {
    if n < 0 || r.at + n > len(r.data) {
        r.at = len(r.data)
        return
    }
    b = r.data[r.at:][:n]
    r.at += n
    return b, true
}

Refuse_Reason :: enum u8 { Version, Full, Kicked }

Msg_Welcome :: struct {
    slot: u8,
    pos:  [3]f32, // eye; zero: wherever the client would start anyway
    yaw:  f32,
}

Msg_Player_View :: struct {
    slot:   u8,
    ping:   u16, // ms, its connection's round trip (0: the server's own player)
    player: Player,
}

Msg_Clock :: struct {
    hour:   f32,
    paused: bool,
    time:   f64, // seconds the server has run: the views after it in its packet are of this moment (replica.odin)
}

// Whether a kind goes on the reliable channel; only states go unreliable.
msg_reliable :: proc(kind: Msg_Kind) -> bool {
    #partial switch kind {
    case .Player_State, .Player_View, .Clock, .Monsters, .Slime_View, .Enemy_View: return false
    }
    return true
}

// Slimes and enemies a client sees, sent VIEW_RATE times a second: what
// they look like and where they're going, for drawing, hitting and being
// shoved by (client.odin keeps them as replicas).
MONSTER_VIEW_RANGE :: ENTITY_CULL_RADIUS
#assert(MAX_SLIMES <= 64 && MAX_ENEMIES <= 32)

Msg_Monsters :: struct {
    slimes:  u64, // bit i: slime slot i is taken
    enemies: u32,
}

Msg_Slime_View :: struct {
    index:     u8,
    size:      Slime_Size,
    state:     Slime_State,
    on_ground: bool,
    uid:       u32,
    pos, vel:  [3]f32,
    color:     [3]f32,
    yaw, squash, flash, freeze, bar, hp, age: f32,
}

Msg_Enemy_View :: struct {
    index:     u8,
    kind:      Enemy_Kind,
    state:     Enemy_State,
    swing:     Swing,
    on_ground: bool,
    uid:       u32,
    pos, vel:  [3]f32,
    tint:      [3]f32,
    yaw, timer, flash, freeze, bar, hp, death, rising, walk_phase, speed, age: f32,
}

NET_RELIABLE   :: u8(0)
NET_UNRELIABLE :: u8(1)
NET_CHANNELS   :: 2

// Messages to one peer, gathered over a step and sent as one packet per channel.
Outbox :: struct {
    reliable:   [dynamic]u8,
    unreliable: [dynamic]u8,
}

outbox_put :: proc(o: ^Outbox, kind: Msg_Kind, body: $T) {
    msg_put(msg_reliable(kind) ? &o.reliable : &o.unreliable, kind, body)
}

outbox_put_empty :: proc(o: ^Outbox, kind: Msg_Kind) {
    msg_put_empty(msg_reliable(kind) ? &o.reliable : &o.unreliable, kind)
}

// Send what's gathered to an ENet peer and empty the box.
outbox_send :: proc(o: ^Outbox, peer: ^enet.Peer) {
    send :: proc(peer: ^enet.Peer, buf: ^[dynamic]u8, channel: u8, flags: enet.PacketFlags) {
        if len(buf) == 0 { return }
        if packet := enet.packet_create(raw_data(buf^), uint(len(buf)), flags); packet != nil {
            if enet.peer_send(peer, channel, packet) != 0 { enet.packet_destroy(packet) }
        }
        clear(buf)
    }
    send(peer, &o.reliable, NET_RELIABLE, {.RELIABLE})
    send(peer, &o.unreliable, NET_UNRELIABLE, {})
}

// Hand what's gathered to an in-process peer's inbox and empty the box.
outbox_move :: proc(o: ^Outbox, inbox: ^[dynamic]u8) {
    append(inbox, ..o.reliable[:])
    append(inbox, ..o.unreliable[:])
    clear(&o.reliable)
    clear(&o.unreliable)
}

// "host", "host:port", or an IP: an ENet address (the port defaults to NET_PORT).
net_address :: proc(text: string) -> (addr: enet.Address, ok: bool) {
    host, port := text, NET_PORT
    for i := len(text) - 1; i >= 0; i -= 1 {
        if text[i] != ':' { continue }
        p := 0
        for c in text[i + 1:] {
            if c < '0' || c > '9' { return }
            p = p * 10 + int(c - '0')
        }
        if p <= 0 || p > 65535 { return }
        host, port = text[:i], p
        break
    }
    cs := strings.clone_to_cstring(host, context.temp_allocator)
    if enet.address_set_host(&addr, cs) != 0 { return }
    addr.port = u16(port)
    return addr, true
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
