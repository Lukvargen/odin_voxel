package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

// Each player's character, kept by the server under their name: where they
// were and what they carried, so they carry on from there when they're
// back. Every world keeps its own players (joining a friend, you start
// fresh there; your own world's character waits at home).
//
// On disk: players/<name>.json in the world's folder, one file per player,
// written when they leave and with every autosave. JSON so it reads and
// grows easily: a field a file doesn't have keeps its default, a field the
// game doesn't know is ignored; `version` is for the day a change needs
// more than that.

PLAYER_FILE_VERSION :: 1

// What a player's client keeps of its own and reports when it changes
// (Msg_Kind.Keep): the sim doesn't need it every frame.
Player_Kept :: struct {
    hp:          f32,
    glider:      bool, // equipped
    hotbar:      [HOTBAR_SLOTS]Block_Type,
    hotbar_slot: u8,
    items:       [Block_Type]u32, // survival: the blocks carried, as the server counts them (items.odin); clients don't send it
}

// A whole character: the server's Player (where, how) and what it kept.
Player_Record :: struct {
    pos:      [3]f32, // eye
    yaw:      f32,
    pitch:    f32,
    fly_mode: bool,
    sword:    bool,   // drawn
    kept:     Player_Kept,
}

PLAYER_FRESH :: Player_Kept{hp = PLAYER_MAX_HP, hotbar = DEFAULT_HOTBAR}

// New in a survival world: empty hands but for a few torches.
survival_fresh :: proc() -> (k: Player_Kept) {
    k.hp = PLAYER_MAX_HP
    k.hotbar[HOTBAR_SLOTS - 1] = .Torch
    k.items[.Torch] = 8
    return
}

// The file's layout. Blocks by name, not number, so reordering Block_Type
// doesn't scramble anyone's hotbar.
@(private="file")
Player_File :: struct {
    version:     int,
    name:        string,
    pos:         [3]f32,
    yaw:         f32,
    pitch:       f32,
    health:      f32,
    flying:      bool,
    sword_drawn: bool,
    glider:      bool,
    hotbar:      []string,
    hotbar_slot: int,
    items:       map[string]int, // survival: how many of each block, by name
}

// Player `name`'s character: the server's own copy if it has one (they were
// here this session), else their file; ok false if they're new here.
player_record_find :: proc(srv: ^Server, name: string) -> (rec: Player_Record, ok: bool) {
    if rec, ok = srv.records[name]; ok { return }
    rec, ok = player_file_load(name)
    if ok { srv.records[strings.clone(name)] = rec }
    return
}

// Player `slot`'s character as it is now, under its name, and (`write`) to
// its file. Nothing for a player that hasn't said its name, or hasn't yet
// been told what it carries (a client only reports after Restore).
player_record_note :: proc(srv: ^Server, slot: int, write: bool) {
    p := &srv.sim.players[slot]
    n := &srv.names[slot]
    if !p.active || n.len == 0 || !srv.kept_known[slot] { return }
    name := string(n.text[:n.len])
    rec := Player_Record{pos = p.pos, yaw = p.yaw, pitch = p.pitch, fly_mode = p.fly_mode, sword = p.sword, kept = srv.kept[slot]}
    rec.kept.items = srv.items[slot] // the server's count, never the client's word (items.odin)
    if _, known := srv.records[name]; !known { name = strings.clone(name) }
    srv.records[name] = rec
    if write && srv.world.save_enabled { player_file_save(name, rec) }
}

// players/<name>.json; bytes a file name can't hold as %XX.
@(private="file")
player_file_path :: proc(name: string) -> string {
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b, "%s/players/", save_dir)
    for c in transmute([]u8)name {
        switch c {
        case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_': strings.write_byte(&b, c)
        case: fmt.sbprintf(&b, "%%%02X", c)
        }
    }
    strings.write_string(&b, ".json")
    return strings.to_string(b)
}

@(private="file")
player_file_load :: proc(name: string) -> (rec: Player_Record, ok: bool) {
    data, err := os.read_entire_file(player_file_path(name), context.temp_allocator)
    if err != nil { return }
    f := Player_File{health = PLAYER_MAX_HP}
    if uerr := json.unmarshal(data, &f, allocator = context.temp_allocator); uerr != nil {
        fmt.eprintln("Save: couldn't read", player_file_path(name), uerr)
        return
    }
    rec = {pos = f.pos, yaw = f.yaw, pitch = f.pitch, fly_mode = f.flying, sword = f.sword_drawn, kept = PLAYER_FRESH}
    rec.kept.hp = f.health > 0 ? min(f.health, PLAYER_MAX_HP) : PLAYER_MAX_HP
    rec.kept.glider = f.glider
    for s, i in f.hotbar {
        if i >= HOTBAR_SLOTS { break }
        if b, found := reflect.enum_from_name(Block_Type, s); found && b != .Air { rec.kept.hotbar[i] = b }
    }
    rec.kept.hotbar_slot = u8(clamp(f.hotbar_slot, 0, HOTBAR_SLOTS - 1))
    for s, n in f.items {
        if b, found := reflect.enum_from_name(Block_Type, s); found && b != .Air { rec.kept.items[b] = u32(clamp(n, 0, int(max(i32)))) }
    }
    return rec, true
}

@(private="file")
player_file_save :: proc(name: string, rec: Player_Record) {
    hotbar := make([]string, HOTBAR_SLOTS, context.temp_allocator)
    for b, i in rec.kept.hotbar { hotbar[i] = fmt.tprint(b) }
    items := make(map[string]int, allocator = context.temp_allocator)
    for n, b in rec.kept.items { if n > 0 { items[fmt.tprint(b)] = int(n) } }
    f := Player_File{
        version = PLAYER_FILE_VERSION, name = name,
        pos = rec.pos, yaw = rec.yaw, pitch = rec.pitch,
        health = rec.kept.hp, flying = rec.fly_mode, sword_drawn = rec.sword, glider = rec.kept.glider,
        hotbar = hotbar, hotbar_slot = int(rec.kept.hotbar_slot), items = items,
    }
    data, err := json.marshal(f, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
    if err != nil { return }
    _ = os.make_directory_all(fmt.tprintf("%s/players", save_dir))
    // Written aside, then over the old one: a crash mid-write loses nothing.
    path := player_file_path(name)
    tmp := fmt.tprintf("%s.tmp", path)
    if werr := os.write_entire_file(tmp, data); werr != nil {
        fmt.eprintln("Save: failed to write", tmp, werr)
        return
    }
    if rerr := os.rename(tmp, path); rerr != nil { fmt.eprintln("Save: failed to write", path, rerr) }
}
