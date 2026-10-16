package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The server's world (Server.world): the columns around every player, the
// same for each of them; no player is special, not even the one whose game
// the server runs in. Its own worker threads load them (from the save, or
// generated; no light: that's for clients to see by), server_stream keeps
// them around the players, and they're saved when they're dropped, every
// AUTOSAVE_INTERVAL and when the server stops. Each client keeps its own
// copy of the world it sees (world.odin), fed by the server's edits.

SERVER_RADIUS       :: 15 // columns kept around each player: monsters roam ENEMY_DESPAWN (110) out...
SERVER_UNLOAD       :: SERVER_RADIUS + 3 // ...and dropped this far from every player
SERVER_WORKERS      :: 2
SERVER_STREAM_EVERY :: f32(0.25) // seconds between looking at what to load and drop

Server_Loader :: struct {
    mu:       sync.Mutex,
    pending:  [dynamic]Chunk_Job,    // nearest last: popped first
    ready:    [dynamic]Chunk_Result,
    queued:   map[[2]int]bool,       // pending or being built (main thread only)
    threads:  [SERVER_WORKERS]^thread.Thread,
    running:  bool,
    started:  bool,
}

// Open the world in save_dir (its lock and saved columns: save.odin), or
// none (saves = false: benches), and start loading.
server_open :: proc(srv: ^Server, saves: bool) {
    w := &srv.world
    if saves {
        w.save_enabled = world_open(w)
        places_load(srv)
    }
    srv.last_autosave = time.tick_now()
    l := &srv.loader
    l.running, l.started = true, true
    for i in 0 ..< SERVER_WORKERS {
        l.threads[i] = thread.create_and_start_with_data(l, server_loader_proc)
    }
}

// Stop: let players go, save what changed, stop loading.
server_close :: proc(srv: ^Server) {
    server_shutdown(srv)
    server_save_all(srv)
    l := &srv.loader
    if !l.started { return }
    sync.atomic_store(&l.running, false)
    for t in l.threads {
        thread.join(t)
        thread.destroy(t)
    }
    for r in l.ready { column_free(r.column) }
    delete(l.ready)
    delete(l.pending)
    delete(l.queued)
    l.started = false
}

// Every column with unsaved edits, to its save, and where everyone is.
server_save_all :: proc(srv: ^Server) {
    save_all_modified(&srv.world)
    for slot in 0 ..< MAX_PLAYERS { server_note_place(srv, slot) }
    places_save(srv)
    srv.last_autosave = time.tick_now()
}

// Where player `slot` is now, under its name (if it has said one).
server_note_place :: proc(srv: ^Server, slot: int) {
    p := &srv.sim.players[slot]
    n := &srv.names[slot]
    if !p.active || n.len == 0 { return }
    name := string(n.text[:n.len])
    if _, known := srv.places[name]; !known { name = strings.clone(name) }
    srv.places[name] = {pos = p.pos, yaw = p.yaw}
}

// players.txt in the world's folder: a line per player, "x y z yaw name".
@(private="file")
places_path :: proc() -> string { return fmt.tprintf("%s/players.txt", save_dir) }

@(private="file")
places_load :: proc(srv: ^Server) {
    data, err := os.read_entire_file(places_path(), context.temp_allocator)
    if err != nil { return }
    for line in strings.split_lines(string(data), context.temp_allocator) {
        f := strings.split_n(strings.trim_space(line), " ", 5, context.temp_allocator)
        if len(f) != 5 { continue }
        x, okx := strconv.parse_f32(f[0])
        y, oky := strconv.parse_f32(f[1])
        z, okz := strconv.parse_f32(f[2])
        yaw, oka := strconv.parse_f32(f[3])
        name := text_set(f[4], NAME_MAX)
        if !(okx && oky && okz && oka) || name.len == 0 { continue }
        srv.places[strings.clone(string(name.text[:name.len]))] = {pos = {x, y, z}, yaw = yaw}
    }
}

@(private="file")
places_save :: proc(srv: ^Server) {
    if !srv.world.save_enabled || len(srv.places) == 0 { return }
    b := strings.builder_make(context.temp_allocator)
    for name, p in srv.places { fmt.sbprintf(&b, "%.2f %.2f %.2f %.1f %s\n", p.pos.x, p.pos.y, p.pos.z, p.yaw, name) }
    if err := os.write_entire_file(places_path(), transmute([]u8)strings.to_string(b)); err != nil {
        fmt.eprintln("Save: failed to write", places_path(), err)
    }
}

@(private="file")
server_loader_proc :: proc(data: rawptr) {
    l := (^Server_Loader)(data)
    for sync.atomic_load(&l.running) {
        free_all(context.temp_allocator)
        sync.mutex_lock(&l.mu)
        job, ok := pop_safe(&l.pending)
        sync.mutex_unlock(&l.mu)
        if !ok {
            time.sleep(2 * time.Millisecond)
            continue
        }
        col: ^Column
        if job.from_disk { col = load_column(job.key) }
        if col == nil { col = generate_column_at(job.key.x, job.key.y) }
        sync.mutex_lock(&l.mu)
        append(&l.ready, Chunk_Result{key = job.key, column = col, from_disk = job.from_disk})
        sync.mutex_unlock(&l.mu)
    }
}

// Each step: take in what was loaded; now and then, drop the columns far
// from every player and ask for the ones missing near any; and autosave.
server_stream :: proc(srv: ^Server, dt: f32) {
    w := &srv.world
    l := &srv.loader
    if !l.started { return }

    sync.mutex_lock(&l.mu)
    ready := slice.clone(l.ready[:], context.temp_allocator)
    clear(&l.ready)
    sync.mutex_unlock(&l.mu)
    for r in ready {
        delete_key(&l.queued, r.key)
        // Already here, saved (or no longer) while it loaded, or nobody
        // near it now: not wanted as it is.
        if r.key in w.columns || r.from_disk != (r.key in w.saved_columns) || !server_wants(srv, r.key, SERVER_UNLOAD) {
            column_free(r.column)
            continue
        }
        w.columns[r.key] = r.column
    }

    if w.save_enabled && time.tick_since(srv.last_autosave) >= AUTOSAVE_INTERVAL { server_save_all(srv) }

    srv.stream_timer -= dt
    if srv.stream_timer > 0 { return }
    srv.stream_timer = SERVER_STREAM_EVERY

    drop := make([dynamic][2]int, context.temp_allocator)
    for key in w.columns { if !server_wants(srv, key, SERVER_UNLOAD) { append(&drop, key) } }
    for key in drop {
        col := w.columns[key]
        if col.modified { save_column(w, key, col) }
        column_free(col)
        delete_key(&w.columns, key)
    }

    // What's missing near anyone, nearest first (popped from the end).
    want := make([dynamic]Chunk_Job, context.temp_allocator)
    dist := make(map[[2]int]int, 256, context.temp_allocator)
    for &p in srv.sim.players {
        if !p.active { continue }
        c := [2]int{floor_div(int(p.pos.x), CHUNK_VOXELS), floor_div(int(p.pos.z), CHUNK_VOXELS)}
        for dz in -SERVER_RADIUS ..= SERVER_RADIUS {
            for dx in -SERVER_RADIUS ..= SERVER_RADIUS {
                d := dx * dx + dz * dz
                if d > SERVER_RADIUS * SERVER_RADIUS { continue }
                key := c + {dx, dz}
                if key in w.columns { continue }
                if old, seen := dist[key]; seen && old <= d { continue }
                dist[key] = d
            }
        }
    }
    sync.mutex_lock(&l.mu)
    // Pending ones nobody is near any more go.
    for i := 0; i < len(l.pending); {
        if l.pending[i].key in dist { i += 1; continue }
        delete_key(&l.queued, l.pending[i].key)
        unordered_remove(&l.pending, i)
    }
    for key in dist {
        if key in l.queued { continue }
        l.queued[key] = true
        append(&want, Chunk_Job{key = key, from_disk = key in w.saved_columns})
    }
    append(&l.pending, ..want[:])
    context.user_ptr = &dist
    slice.sort_by(l.pending[:], proc(a, b: Chunk_Job) -> bool {
        m := (^map[[2]int]int)(context.user_ptr)
        return m[a.key] > m[b.key] // farthest first, so the nearest pops first
    })
    sync.mutex_unlock(&l.mu)
}

// Whether column `key` is within `radius` columns of any player.
@(private="file")
server_wants :: proc(srv: ^Server, key: [2]int, radius: int) -> bool {
    for &p in srv.sim.players {
        if !p.active { continue }
        c := [2]int{floor_div(int(p.pos.x), CHUNK_VOXELS), floor_div(int(p.pos.z), CHUNK_VOXELS)}
        d := key - c
        if d.x * d.x + d.y * d.y <= radius * radius { return true }
    }
    return false
}

// The local client's welcome: the columns that differ from the generated
// world, before it streams in its own (a remote one gets them with its
// Welcome); and, for a player called `name` who's been here (and `resume`),
// where they were.
server_greet_local :: proc(srv: ^Server, name := "", resume := false) {
    if place, ok := srv.places[name]; ok && resume {
        outbox_put(&srv.local_out, .Move_To, Msg_Move_To{pos = place.pos, yaw = place.yaw})
    }
    server_send_edited(srv, &srv.local_out)
    outbox_move(&srv.local_out, &srv.link.to_client)
    fmt.printf("Server: %d edited columns in the world\n", len(srv.world.saved_columns))
}
