package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import la "core:math/linalg"
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
    // Survival (items.odin): edits numbered as sent, the server's last count,
    // and our guesses for the edits it hasn't answered yet.
    edit_seq:     u32,
    items_base:   [Block_Type]u32,
    weapons_base: [Weapon]u32,
    item_guesses: [dynamic]Item_Guess,
    remote:   bool,       // joined a server elsewhere (for good: no own server if it drops)
    away:     bool,       // joined from the main menu: no world of our own to go back to (the menu instead)
    host:     ^enet.Host, // our end of it, while connected
    peer:     ^enet.Peer,
    slot:     int,        // our player slot
    welcomed: bool,       // the server took us in (until then nothing is sent)
    dropped:  bool,       // the connection ended this frame: back to our own world
    waiting:  f32,        // seconds since we asked to join, until welcomed (JOIN_TIMEOUT)
    refused:  string,     // why the server turned us away, if it did
    others:   [MAX_PLAYERS]Other_Player, // the other players, as the server last said
    address:  [64]u8,     // joined to (for the menu)
    address_len: int,
    home_pos: [3]f32,     // where we were in our own world before joining
    home_yaw: f32,
    // Teleported (joining, coming home): held in place until the ground
    // there has streamed in, rather than falling through.
    arriving:   bool,
    arrive_pos: [3]f32,
    arrive_yaw: f32,
    // The columns that differ from the generated world, which come from the
    // server (client_request_column), and those asked for. A client never
    // reads or writes saves: the world is the server's.
    edited:     map[[2]int]bool,
    requested:  map[[2]int]bool,
    // Joined: the server's slimes and enemies near us live in gs.slimes and
    // gs.enemies as replicas, easing toward where they were last seen.
    slime_seen: [MAX_SLIMES]Replica(Msg_Slime_View),
    enemy_seen: [MAX_ENEMIES]Replica(Msg_Enemy_View),
    clock:      Replica_Clock,
    monster_origin: [3]i32, // the monster views' positions are from here (Msg_Monsters) // the server's time, to draw what it moves a little in the past (replica.odin)
    // Names and chat.
    sent_name:  Msg_Text,                 // as last told the server (resent when it changes)
    // What we carry (Player_Kept), as last told the server: only once it
    // told us our character here (Restore), so it's never the last world's.
    restored:     bool,
    no_build:     bool, // the host doesn't let visitors change blocks (Msg_Rules)
    sent_kept:    Player_Kept,
    kept_sent_at: time.Tick,
    names:      [MAX_PLAYERS]Msg_Text,    // what the players are called, as the server says
    looks:      [MAX_PLAYERS]Maybe(Look), // how they look (player_look.odin), once the server's said
    sent_look:  Maybe(Look),              // ours, as last told the server (resent when it changes)
    chat:       [CHAT_LINES]Chat_Entry,   // the latest lines, oldest first
}

CHAT_LINES   :: 8
CHAT_SECONDS :: 12 // a chat line shows this long (all of them while typing)

Chat_Entry :: struct {
    text:   [TEXT_MAX + NAME_MAX + 2]u8,
    len:    int,
    slot:   int, // who said it, or SERVER_SLOT
    t:      f32, // seconds left to show
}

REPLICA_TIMEOUT :: 1 // seconds without word before a replicated monster is dropped

// Another player, drawn where its client said it was a moment ago.
Other_Player :: struct {
    active: bool,
    views:  Replica(Player), // as the server passed them on (replica.odin)
    latest: Player,  // as drawn now, between views
    pos:    [3]f32,  // drawn here (eye) = latest.pos
    anim:   Player_Anim,
    pose:   Sword_Pose, // drawn so, easing after latest.sword_pose
    ping:   int,        // ms, its connection's round trip, as the server measures it
    hurt:   f32,        // 1 when struck, fading: the body flashes red
    hum:    f32,        // till its spell's next hum
    palms:  [2][3]f32,  // its spell's palms (world), as last drawn...
    beam:   bool,       // ...and whether it's casting at all
    t:      f32,        // its own clock, for its spell's sparks
}

OTHER_TIMEOUT :: 3 // seconds without word before another player is no longer drawn
JOIN_TIMEOUT  :: 10 // seconds to wait for a server's welcome before giving up

client_joined :: proc(gs: ^Game_State) -> bool { return gs.net.remote }

// Whether we may change blocks: always in our own world; on someone
// else's unless the host turned that off.
client_may_build :: proc(gs: ^Game_State) -> bool { return !client_joined(gs) || !gs.net.no_build }

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
    gs.net.waiting = 0
    gs.net.address_len = copy(gs.net.address[:], address)
    fmt.println("Join: connecting to", address)
    return true
}

client_leave :: proc(gs: ^Game_State) {
    n := &gs.net
    if n.host == nil { return }
    if n.peer != nil {
        if n.welcomed {
            client_send_kept(gs, true) // the latest, to be saved
            outbox_send(&n.out, n.peer)
        }
        enet.peer_disconnect(n.peer, 0)
    }
    enet.host_flush(n.host)
    enet.host_destroy(n.host)
    n.host, n.peer = nil, nil
}

// What we carry, to the server when it changes: health at most once a
// second (unless `now`), as it ticks up regenerating.
@(private="file")
client_send_kept :: proc(gs: ^Game_State, now: bool) {
    n := &gs.net
    if !n.restored { return }
    k := Player_Kept{hp = gs.combat.hp, glider = gs.glider.equipped, hotbar = gs.hotbar, hotbar_slot = u8(gs.hotbar_slot),
        weapon_bar = gs.weapon_bar, weapon_slot = u8(gs.weapon_slot)}
    if k == n.sent_kept { return }
    rest := k
    rest.hp = n.sent_kept.hp
    if rest == n.sent_kept && !now && time.tick_since(n.kept_sent_at) < time.Second { return }
    client_send(gs, .Keep, k)
    n.sent_kept, n.kept_sent_at = k, time.tick_now()
}

// Our character on this server: as we left it, or a fresh one.
@(private="file")
client_restore :: proc(gs: ^Game_State, m: Msg_Restore) {
    rec := m.record
    k := m.known ? rec.kept : (gs.survival ? survival_fresh() : PLAYER_FRESH)
    if m.move {
        client_arrive(gs, rec.pos, rec.yaw)
        gs.camera.pitch = rec.pitch
    }
    gs.camera.fly_mode = m.known && rec.fly_mode && !k.glider && !gs.survival
    gs.combat.fighting = m.known && rec.sword
    gs.combat.hp = k.hp
    gs.glider.equipped = k.glider
    gs.hotbar = k.hotbar
    gs.weapon_bar = k.weapon_bar
    gs.net.items_base, gs.net.weapons_base = k.items, k.weapons // the server's Items says the same, right behind
    clear(&gs.net.item_guesses)
    client_items_sum(gs)
    if gs.survival { for &w in gs.weapon_bar { if !weapon_owned(gs, w) { w = .None } } } // (a bar from before there was crafting)
    hotbar_select(gs, int(k.hotbar_slot))
    weapon_select(gs, int(k.weapon_slot))
    gs.net.restored, gs.net.sent_kept = true, {} // and tell the server what we carry
}

// The server let us go, or never answered: back to our own world, saying why.
@(private="file")
client_dropped :: proc(gs: ^Game_State) {
    n := &gs.net
    address := string(n.address[:n.address_len])
    why := n.refused
    if why == "" {
        why = n.welcomed ? fmt.tprintf("Lost the connection to %s", address) : fmt.tprintf("Couldn't reach %s", address)
    }
    n.dropped, n.refused = false, ""
    if n.away {
        gs.ui.menu_note, gs.ui.menu_requested = strings.clone(why), true
        return
    }
    session_leave(gs)
    ui_toast(gs, why, 5)
    chat_add(gs, fmt.tprintf("%s. Back in your own world.", why), SERVER_SLOT)
}

// What this player is called: the Multiplayer tab's name box.
client_name :: proc(gs: ^Game_State) -> string {
    f := &gs.ui.name_field
    return string(f.buf[:f.len])
}

client_player_name :: proc(gs: ^Game_State, slot: int) -> string {
    n := &gs.net.names[slot]
    return n.len > 0 ? string(n.text[:n.len]) : fmt.tprintf("Player %d", slot)
}

// A line into the chat log, the oldest dropping off.
chat_add :: proc(gs: ^Game_State, s: string, slot: int) {
    log := &gs.net.chat
    copy(log[:], log[1:])
    e := &log[len(log) - 1]
    e^ = {slot = slot, t = CHAT_SECONDS}
    e.len = copy(e.text[:], s)
}

// What the startup loading waits on (generate_world): with our own server,
// a round trip over the loopback, so the edited columns asked for arrive.
client_pump :: proc(gs: ^Game_State) {
    if !client_joined(gs) {
        outbox_move(&gs.net.out, &gs.loop.to_server)
        server_receive(&gs.server)
        server_flush(&gs.server, 0)
    }
    client_receive(gs, 0)
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
    g := &gs.glider
    act := local_body_act(gs)
    client_send(gs, .Player_State, player_pack(Player{
        active = true, pos = cam.pos, velocity = cam.velocity, yaw = cam.yaw, pitch = cam.pitch,
        on_ground = cam.on_ground, fly_mode = cam.fly_mode, sneaking = cam.sneaking, sprinting = cam.sprinting,
        sword = c.fighting, weapon = c.weapon, sword_pose = c.pose, swing_id = c.attack_id, invuln = c.invuln, blocking = c.blocking, block_time = c.block_time,
        torch = holding_torch(gs),
        climbing = act.climbing, channeling = gs.magic.channeling, conjuring = gs.magic.conjure > 0,
        raise = act.raise, reach = act.at, reach_k = act.k,
        gliding = g.deployed, glide_heading = g.heading, glide_pitch = g.path_angle + g.aoa,
        glide_bank = g.bank, glide_unfold = g.deploy_t,
    }))
    client_send(gs, .Set_Monsters, gs.entities_enabled && !gs.sandbox.on) // the sandbox shows its own (sandbox.odin)

    n := &gs.net
    // Our name, when it changes (and to every new server: sent_name is
    // forgotten when we switch).
    name := text_set(client_name(gs), NAME_MAX)
    if name.len > 0 && name != n.sent_name && (!client_joined(gs) || n.welcomed) {
        client_send(gs, .Set_Name, name)
        n.sent_name = name
    }
    // Our look, the same way.
    if sent, ok := n.sent_look.?; (!ok || sent != gs.look) && (!client_joined(gs) || n.welcomed) {
        client_send(gs, .Set_Look, gs.look)
        n.sent_look = gs.look
    }
    client_send_kept(gs, false)

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
            p := player_unpack(v.player)
            if !o.active { o^ = {active = true, latest = p, pos = p.pos, anim = {body_yaw = -math.to_radians(p.yaw)}, pose = p.sword_pose} }
            replica_push(&o.views, p, gs.net.clock.stamp)
            o.ping = int(v.ping)
        case .Player_Gone:
            slot := msg_get(&r, u8) or_break
            if int(slot) < MAX_PLAYERS {
                gs.net.others[slot].active = false
                gs.net.names[slot], gs.net.looks[slot] = {}, nil
            }
        case .Restore:
            m := msg_get(&r, Msg_Restore) or_break
            client_restore(gs, m)
        case .Items:
            m := msg_get(&r, Msg_Items) or_break
            client_items_heard(gs, m)
        case .Fell:
            m := msg_get(&r, Msg_Fell) or_break
            felling_heard(gs, m)
        case .Player_Look:
            m := msg_get(&r, Msg_Player_Look) or_break
            if int(m.slot) < MAX_PLAYERS { gs.net.looks[m.slot] = look_clean(m.look) }
        case .Player_Name:
            m := msg_get(&r, Msg_Player_Name) or_break
            if int(m.slot) < MAX_PLAYERS {
                text_of(&m.name)
                gs.net.names[m.slot] = m.name
            }
        case .Chat_Line:
            m := msg_get(&r, Msg_Chat_Line) or_break
            line := text_of(&m.line)
            slot := int(m.slot)
            if slot == SERVER_SLOT {
                chat_add(gs, line, slot)
            } else if slot < MAX_PLAYERS {
                chat_add(gs, fmt.tprintf("%s: %s", client_player_name(gs, slot), line), slot)
            }
        case .Clock:
            c := msg_get(&r, Msg_Clock) or_break
            replica_clock_stamp(&gs.net.clock, c.time)
            if client_joined(gs) { // our own server's clock is ours already
                gs.day.hour, gs.day.paused, gs.day.sun = c.hour, c.paused, c.sun
                day_tick(&gs.sim, 0)
            }
        case .Welcome:
            w := msg_get(&r, Msg_Welcome) or_break
            gs.net.slot, gs.net.welcomed = int(w.slot), true
            if w.pos != 0 { client_arrive(gs, w.pos, w.yaw) }
            ui_toast(gs, fmt.tprintf("Joined as player %d", w.slot), 3)
        case .Refuse:
            why := msg_get(&r, Refuse_Reason) or_break
            switch why {
            case .Full:    gs.net.refused = "The server is full"
            case .Version: gs.net.refused = "The server runs a different version of the game"
            case .Kicked:  gs.net.refused = "The host removed you from the game"
            }
        case .Rules:
            m := msg_get(&r, Msg_Rules) or_break
            if client_joined(gs) { gs.net.no_build = !m.guests_build }
            gs.survival = m.survival
            if m.survival { gs.camera.fly_mode = false }
        case .Voxels:
            m := msg_get(&r, Msg_Voxels) or_break
            changed := make([dynamic][3]int, 0, VOXEL_BATCH, context.temp_allocator)
            heard: Heard_Edit
            for v in m.items[:min(m.count, VOXEL_BATCH)] {
                p := la.array_cast(v.pos, int)
                heard_note(gs, &heard, p, v.block)
                client_write(gs, p, v.block, &changed)
            }
            world_refresh(gs, changed[:])
            heard_play(heard)
        case .Chunk_Voxels:
            m := msg_get(&r, Msg_Chunk_Voxels) or_break
            if chunk_y_index(int(m.key.y)) < 0 { break }
            changed := make([dynamic][3]int, 0, VOXELS_PER_BRICK, context.temp_allocator)
            base := la.array_cast(m.key, int) * CHUNK_VOXELS
            heard: Heard_Edit
            for v, vi in m.voxels {
                p := base + {vi & 7, (vi >> 3) & 7, vi >> 6}
                heard_note(gs, &heard, p, v)
                client_write(gs, p, v, &changed)
            }
            world_refresh(gs, changed[:])
            heard_play(heard)
        case .Monsters:
            m := msg_get(&r, Msg_Monsters) or_break
            if !client_joined(gs) { break }
            gs.net.monster_origin = m.origin
            for &sl, i in gs.slimes.list { if m.slimes & (1 << u64(i)) == 0 { sl.alive = false } }
            for &e, i in gs.enemies.list { if m.enemies & (1 << u32(i)) == 0 { e.alive = false } }
        case .Slime_View:
            v := msg_get(&r, Net_Slime) or_break
            if client_joined(gs) && int(v.index) < MAX_SLIMES { client_slime_view(gs, slime_unpack(v, gs.net.monster_origin)) }
        case .Enemy_View:
            v := msg_get(&r, Net_Enemy) or_break
            if client_joined(gs) && int(v.index) < MAX_ENEMIES { client_enemy_view(gs, enemy_unpack(v, gs.net.monster_origin)) }
        case .Edited:
            m := msg_get(&r, Msg_Edited) or_break
            for k in m.keys[:min(int(m.count), len(m.keys))] {
                key := [2]int{int(k.x), int(k.y)}
                gs.net.edited[key] = true
                // Generated here before we knew: the server's instead.
                if col := gs.columns[key]; col != nil && !col.modified {
                    unload_column(gs, key)
                    client_request_column(gs, key)
                }
            }
        case .Column_Data:
            m := msg_get(&r, Msg_Column_Data) or_break
            bytes := msg_get_bytes(&r, int(min(m.size, MAX_COLUMN_BYTES))) or_break
            client_take_column(gs, {int(m.key.x), int(m.key.y)}, bytes)
        case: // a client's kind: never sent to one
            r.at = len(r.data)
        }
    }
    clear(&gs.loop.to_client)
    if n := &gs.net; n.remote && !n.welcomed && !n.dropped {
        n.waiting += dt
        if n.waiting > JOIN_TIMEOUT {
            client_leave(gs)
            n.dropped = true
        }
    }
    if gs.net.dropped { client_dropped(gs) }
    replica_clock_tick(&gs.net.clock)
    others_update(gs, dt)
    if client_joined(gs) { replicas_update(gs, dt) }
    for &e in gs.net.chat { e.t = max(e.t - dt, 0) }
    monsters_push_player(gs)
    client_hold_arrival(gs)
}

// A slime as the server saw it, kept for drawing a moment later
// (replicas_update). A new one (or another in its slot) starts there.
@(private="file")
client_slime_view :: proc(gs: ^Game_State, v: Msg_Slime_View) {
    sl := &gs.slimes.list[v.index]
    rep := &gs.net.slime_seen[v.index]
    if !sl.alive || sl.uid != v.uid {
        sl^ = {alive = true, uid = v.uid}
        rep.count = 0
    }
    replica_push(rep, v, gs.net.clock.stamp)
}

@(private="file")
client_enemy_view :: proc(gs: ^Game_State, v: Msg_Enemy_View) {
    e := &gs.enemies.list[v.index]
    rep := &gs.net.enemy_seen[v.index]
    if !e.alive || e.uid != v.uid {
        e^ = {alive = true, uid = v.uid}
        rep.count = 0
    }
    replica_push(rep, v, gs.net.clock.stamp)
}

// The replicated monsters as they were at the clock's moment, between the
// views either side (a walk strides smoothly, a hit flash fades), or a
// little past the newest by their speed; one not heard of in a while is
// gone.
@(private="file")
replicas_update :: proc(gs: ^Game_State, dt: f32) {
    t := gs.net.clock.now
    for &sl, i in gs.slimes.list {
        if !sl.alive { continue }
        rep := &gs.net.slime_seen[i]
        rep.age += dt
        if rep.age > REPLICA_TIMEOUT || rep.count == 0 { sl.alive = false; continue }
        a, b, k, ahead := replica_at(rep, t)
        sl.size, sl.state, sl.on_ground, sl.color, sl.hp, sl.freeze = a.size, a.state, a.on_ground, a.color, a.hp, a.freeze
        sl.pos = replica_lerp_pos(a.pos, b.pos, k) + a.vel * ahead
        sl.vel = math.lerp(a.vel, b.vel, k)
        sl.yaw = replica_lerp_angle(a.yaw, b.yaw, k)
        sl.squash = math.lerp(a.squash, b.squash, k)
        sl.flash = max(math.lerp(a.flash, b.flash, k) - ahead * 7, 0)
        sl.bar = max(math.lerp(a.bar, b.bar, k) - ahead, 0)
        sl.age = math.lerp(a.age, b.age, k) + ahead
    }
    for &e, i in gs.enemies.list {
        if !e.alive { continue }
        rep := &gs.net.enemy_seen[i]
        rep.age += dt
        if rep.age > REPLICA_TIMEOUT || rep.count == 0 { e.alive = false; continue }
        a, b, k, ahead := replica_at(rep, t)
        e.kind, e.state, e.swing, e.on_ground, e.tint, e.hp, e.freeze, e.speed = a.kind, a.state, a.swing, a.on_ground, a.tint, a.hp, a.freeze, a.speed
        e.pos = replica_lerp_pos(a.pos, b.pos, k) + a.vel * ahead
        e.vel = math.lerp(a.vel, b.vel, k)
        e.yaw = replica_lerp_angle(a.yaw, b.yaw, k)
        e.flash = max(math.lerp(a.flash, b.flash, k) - ahead * 7, 0)
        e.bar = max(math.lerp(a.bar, b.bar, k) - ahead, 0)
        // Clocks that only run forward: between the views, or on past the newest.
        same := a.state == b.state && a.swing == b.swing
        e.timer = (same ? math.lerp(a.timer, b.timer, k) : a.timer) - ahead
        e.death = (same ? math.lerp(a.death, b.death, k) : a.death) + (a.state == .Dead ? ahead : 0)
        e.rising = same ? math.lerp(a.rising, b.rising, k) : a.rising
        e.walk_phase = (b.walk_phase >= a.walk_phase ? math.lerp(a.walk_phase, b.walk_phase, k) : a.walk_phase) + a.speed * ahead * 2.6 / ENEMY_SPECS[a.kind].scale
        e.age = math.lerp(a.age, b.age, k) + ahead
    }
}

// Blocks this client just changed (build_commit), to the server, which
// passes them on: as they are now, a chunk at a time where an edit changed
// much of one.
client_send_voxels :: proc(gs: ^Game_State, changed: [][3]int, seq: u32) {
    per_chunk := make(map[[3]int]int, 16, context.temp_allocator)
    for p in changed {
        per_chunk[{p.x >> 3, p.y >> 3, p.z >> 3}] += 1
        gs.net.edited[{p.x >> 3, p.z >> 3}] = true // streamed out and back in, it comes from the server
    }
    m := Msg_Voxels{seq = seq}
    for p in changed {
        key := [3]int{p.x >> 3, p.y >> 3, p.z >> 3}
        n := per_chunk[key]
        if n < 0 { continue } // this chunk already went whole
        if n > VOXEL_BATCH {
            per_chunk[key] = -1
            whole := Msg_Chunk_Voxels{seq = seq, key = {i32(key.x), i32(key.y), i32(key.z)}}
            if c := world_chunk(gs, key); c != nil {
                for &v, vi in whole.voxels { v = chunk_voxel(c, vi) }
                client_send(gs, .Chunk_Voxels, whole)
            }
            continue
        }
        m.items[m.count] = {pos = {i32(p.x), i32(p.y), i32(p.z)}, block = u8(get_voxel(gs, p.x, p.y, p.z))}
        m.count += 1
        if m.count == VOXEL_BATCH {
            client_send(gs, .Voxels, m)
            m.count = 0
        }
    }
    if m.count > 0 { client_send(gs, .Voxels, m) }
}

// Another player's edit, for our ears: the first voxel it changed near us
// and how many it did. A door swinging isn't one (it has Door_Swing).
Heard_Edit :: struct {
    pos:        [3]int,
    block, old: Block_Type,
    n:          int,
}

HEAR_EDITS :: 64 // blocks: edits further off than this are not heard

@(private="file")
heard_note :: proc(gs: ^Game_State, h: ^Heard_Edit, p: [3]int, block: u8) {
    old := u8(get_voxel(gs, p.x, p.y, p.z))
    if old == block || door_swung(old, block) { return }
    if la.length([3]f32{f32(p.x), f32(p.y), f32(p.z)} - gs.camera.pos) > HEAR_EDITS { return }
    if h.n == 0 { h.pos, h.block, h.old = p, Block_Type(block), Block_Type(old) }
    h.n += 1
}

// Sounds as our own edit of that size would (audio_edit: bigger, lower).
@(private="file")
heard_play :: proc(h: Heard_Edit) {
    if h.n == 0 { return }
    audio_edit(h.pos, h.block, h.old, clamp(int(math.cbrt(f32(h.n)) * 0.6), 0, 8))
}

// A block another player changed, into our world if we have its column
// (noted in `changed` for world_refresh); either way the column now differs
// from the generated one.
@(private="file")
client_write :: proc(gs: ^Game_State, p: [3]int, block: u8, changed: ^[dynamic][3]int) {
    if p.y < WORLD_Y_MIN || p.y >= WORLD_Y_MAX || int(block) >= BLOCK_IDS { return }
    key := [2]int{p.x >> 3, p.z >> 3}
    gs.net.edited[key] = true
    col := gs.columns[key]
    if col == nil { return }
    vi := (p.x & 7) + (p.y & 7) * CHUNK_VOXELS + (p.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS
    chunk_set_voxel(&col.chunks[chunk_y_index(p.y >> 3)], vi, block) // already set if the server shares our world
    col.modified = true
    append(changed, p)
}

// Forget the server's world: the columns it sent and those changed here go
// (streaming generates or fetches them again), and so does the list of
// edited ones. Leaving or joining a server; the new one sends its own list.
client_reset_world :: proc(gs: ^Game_State) {
    drop := make([dynamic][2]int, context.temp_allocator)
    for key, col in gs.columns { if col.modified || key in gs.net.edited { append(&drop, key) } }
    for key in drop {
        gs.columns[key].modified = false
        unload_column(gs, key)
    }
    clear(&gs.net.edited)
    clear(&gs.net.requested)
    enqueue_chunks(gs)
}

// Ask the server for an edited column (once until it comes).
client_request_column :: proc(gs: ^Game_State, key: [2]int) {
    if key in gs.net.requested { return }
    gs.net.requested[key] = true
    client_send(gs, .Column_Request, [2]i32{i32(key.x), i32(key.y)})
}

// An edited column from the server: lit and made resident (and kept apart
// from our own world: modified, so leaving drops it). No bytes: it isn't
// edited after all, so generate it.
@(private="file")
client_take_column :: proc(gs: ^Game_State, key: [2]int, bytes: []u8) {
    n := &gs.net
    if !(key in n.requested) { return } // asked of a server we've since left
    delete_key(&n.requested, key)
    col := len(bytes) > 0 ? column_decode(bytes) : nil
    if col == nil {
        delete_key(&n.edited, key)
        if !(key in gs.columns) { worker_pool_enqueue(&gs.pool, key, false) }
        return
    }
    light_column_compute(col)
    col.modified = true
    if key in gs.columns { unload_column(gs, key) }
    integrate_column(gs, key, col)
}

// Go to `pos` (eye) facing `yaw`, held there until the ground has loaded.
client_arrive :: proc(gs: ^Game_State, pos: [3]f32, yaw: f32) {
    n := &gs.net
    n.arriving, n.arrive_pos, n.arrive_yaw = true, pos, yaw
    gs.camera.pos, gs.camera.yaw, gs.camera.velocity = pos, yaw, {}
}

@(private="file")
client_hold_arrival :: proc(gs: ^Game_State) {
    n := &gs.net
    if !n.arriving { return }
    p := n.arrive_pos
    key := [2]int{floor_div(int(math.floor(p.x)), CHUNK_VOXELS), floor_div(int(math.floor(p.z)), CHUNK_VOXELS)}
    if key in gs.columns {
        n.arriving = false
        return
    }
    gs.camera.pos, gs.camera.velocity = p, {}
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
            // What it said before going (a refusal) is still to be read:
            // client_receive takes us home after.
            n.dropped = true
            n.peer = nil
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
        o.views.age += dt
        o.hurt = max(o.hurt - dt * 2.5, 0)
        if o.views.age > OTHER_TIMEOUT {
            o.active = false
            continue
        }
        // As it was a moment ago, between the views either side.
        if o.views.count > 0 {
            a, b, k, ahead := replica_at(&o.views, gs.net.clock.now)
            was := o.latest
            o.latest = a^
            q := &o.latest
            q.pos = replica_lerp_pos(a.pos, b.pos, k) + a.velocity * ahead
            q.velocity = math.lerp(a.velocity, b.velocity, k)
            q.yaw = replica_lerp_angle(a.yaw, b.yaw, k, 360)
            q.pitch = math.lerp(a.pitch, b.pitch, k)
            if a.gliding && b.gliding {
                q.glide_heading = replica_lerp_angle(a.glide_heading, b.glide_heading, k, 360)
                q.glide_pitch = math.lerp(a.glide_pitch, b.glide_pitch, k)
                q.glide_bank = math.lerp(a.glide_bank, b.glide_bank, k)
            }
            q.glide_unfold = math.lerp(a.glide_unfold, b.glide_unfold, k)
            q.raise = math.lerp(a.raise, b.raise, k)
            if a.climbing == b.climbing && (a.channeling || a.conjuring) == (b.channeling || b.conjuring) {
                q.reach = replica_lerp_pos(a.reach, b.reach, k)
                q.reach_k = math.lerp(a.reach_k, b.reach_k, k)
            }
            if q.swing_id != was.swing_id && q.sword {
                swing_sound(q.weapon, .Slash_1, q.pos, 0.6) // another swing
            }
        }
        p := &o.latest
        o.pos = p.pos
        o.t += dt
        anim_step(&o.anim, p.velocity, p.yaw, p.sword, p.on_ground || p.fly_mode, dt)
        anim_climb(&o.anim, p.climbing, p.reach, p.pos)
        // Their spell hums where it works, as ours does.
        o.hum -= dt
        if p.channeling && o.hum <= 0 {
            o.hum = 0.3 // the takes overlap: a steady tone, climbing a fifth as ours does
            play_at(.Magic_Channel, p.reach, 0.16 + 0.12 * p.reach_k, math.pow(1.5, p.reach_k), 10)
        }
        // The sword swings smoothly between views (a swing is a few of them).
        k := min(dt * 30, 1)
        o.pose.grip += (p.sword_pose.grip - o.pose.grip) * k
        o.pose.blade += (p.sword_pose.blade - o.pose.blade) * k
        o.pose.back += (p.sword_pose.back - o.pose.back) * k
    }
}

// Each other player's body (creatures.odin), or glider and pilot
// (glider.odin), tinted by slot.
others_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    eye := gs.camera.pos
    for &o, slot in gs.net.others {
        if !o.active { continue }
        d := o.pos - eye
        if d.x * d.x + d.y * d.y + d.z * d.z > ENTITY_CULL_RADIUS * ENTITY_CULL_RADIUS { continue }
        if !ent_begin(f) { return }
        p := &o.latest
        look := other_look(gs, slot)
        paint := paint_flash(look_paint(look), {1, 0.25, 0.2}, o.hurt * 0.75) // struck: a red flash
        if p.gliding {
            ent_scale_about(f, o.pos, world_scale)
            glider_wing_parts(f, o.pos, p.glide_heading, p.glide_pitch, p.glide_bank, p.glide_unfold, look, paint, pilot = true)
        } else {
            feet := o.pos - {0, PLAYER_EYE_HEIGHT, 0}
            ent_scale_about(f, feet, world_scale)
            act := Body_Act{climbing = p.climbing, raise = p.sword ? 0 : p.raise, at = p.reach, k = p.reach_k, t = o.t}
            hips := humanoid_add_parts(f, feet, &o.anim, p.yaw, p.pitch, look, paint, right_arm = !p.sword, act = &act)
            beam := act.raise > 0.5 && (p.channeling || p.conjuring) && !p.climbing
            if beam { o.palms, o.beam = act.palms, true } else { o.beam = false }
            if p.sword {
                // As the player's own sword arm (creatures.odin), from its view.
                fwd, right, up := camera_basis(Camera{yaw = p.yaw, pitch = p.pitch})
                eye := feet + [3]f32{0, HUM_HIPS_Y + 0.6 + HUM_EYE, 0} + fwd * 0.15
                shoulder := feet + basis_yaw(o.anim.body_yaw) * [3]f32{-look_parts(look).arm_x, HUM_HIPS_Y + HUM_ARM_Y, 0}
                grip, blade, edge, flat := sword_place(o.pose, eye, fwd, right, up, shoulder)
                sword_arm_parts(f, shoulder, grip, blade, edge, flat, right * 0.6 - up - fwd * 0.4, p.weapon, tint = paint.cloth)
            }
        }
        ent_end(f)
    }
    // Their spells' beams: light, no shadow.
    if !ent_begin(f, false) { return }
    for &o in gs.net.others {
        if !o.active || !o.beam { continue }
        p := &o.latest
        spell_beam_parts(f, o.palms, p.reach, p.channeling, p.reach_k, o.t, 0.85, 0, MAGIC_TINT)
    }
    ent_end(f)
}

// How another player looks: as they said, or until they have, the first
// preset in a dye of their slot's.
other_look :: proc(gs: ^Game_State, slot: int) -> Look {
    if l, ok := gs.net.looks[slot].?; ok { return l }
    l := DEFAULT_LOOK
    l.cloth = u8(slot * 5 % len(DYES))
    return l
}

// A player's colour in the lists and over their heads: their cloth's.
player_tint :: proc(gs: ^Game_State, slot: int) -> [3]f32 {
    if slot == gs.net.slot { return look_paint(gs.look).cloth }
    if l, ok := gs.net.looks[slot].?; ok { return look_paint(l).cloth }
    h := f32(slot) * 0.61803 // spread round the colour wheel
    h -= math.floor(h)
    return {
        0.25 + 0.4 * (0.5 + 0.5 * math.cos(math.TAU * h)),
        0.25 + 0.4 * (0.5 + 0.5 * math.cos(math.TAU * (h - 0.333))),
        0.25 + 0.4 * (0.5 + 0.5 * math.cos(math.TAU * (h - 0.667))),
    }
}
