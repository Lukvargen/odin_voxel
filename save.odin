package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Player edits are kept by saving every edited column to its own file under
// SAVE_DIR. Unedited columns are never saved: generation is deterministic, so
// they are simply regenerated. A column with a save file is loaded from it
// instead (worker side), so edits survive both unloading and restarts.
//
// File format: "VXC1", then run-length encoded voxels (block u8, count u16
// little endian) covering all CHUNKS_H chunks in order, 512 voxels each.
// Light is not saved; it is recomputed on load.

SAVE_DIR          :: "saves/world"
SAVE_MAGIC        :: "VXC2" // VXC1 saves predate biome terrain and are ignored
AUTOSAVE_INTERVAL :: 30 * time.Second
COLUMN_VOXELS     :: CHUNKS_H * VOXELS_PER_BRICK

@(private="file")
column_path :: proc(buf: []u8, key: [2]int) -> string {
    return fmt.bprintf(buf, "%s/c.%d.%d.bin", SAVE_DIR, key.x, key.y)
}

// Note which columns have save files. Call before the first enqueue.
save_init :: proc(gs: ^Game_State) {
    gs.save_enabled = true
    files, err := os.read_all_directory_by_path(SAVE_DIR, context.temp_allocator)
    if err != nil { return } // no saves yet
    for f in files {
        // c.<x>.<z>.bin
        parts := strings.split(f.name, ".", context.temp_allocator)
        if len(parts) != 4 || parts[0] != "c" || parts[3] != "bin" { continue }
        x, okx := strconv.parse_int(parts[1])
        z, okz := strconv.parse_int(parts[2])
        if okx && okz { gs.saved_columns[{x, z}] = true }
    }
    if len(gs.saved_columns) > 0 {
        fmt.printf("Save: %d edited columns in %s\n", len(gs.saved_columns), SAVE_DIR)
    }
}

save_column :: proc(gs: ^Game_State, key: [2]int, col: ^Column) {
    if !gs.save_enabled { return }
    out := make([dynamic]u8, 0, 4096)
    defer delete(out)
    append(&out, SAVE_MAGIC)

    run_v, run_n := u8(0), 0
    flush :: proc(out: ^[dynamic]u8, v: u8, n: int) {
        n := n
        for n > 0 {
            c := min(n, 0xFFFF)
            buf: [2]u8
            endian.put_u16(buf[:], .Little, u16(c))
            append(out, v, buf[0], buf[1])
            n -= c
        }
    }
    for &c in col.chunks {
        for vi in 0 ..< VOXELS_PER_BRICK {
            v := chunk_voxel(&c, vi)
            if v == run_v { run_n += 1; continue }
            flush(&out, run_v, run_n)
            run_v, run_n = v, 1
        }
    }
    flush(&out, run_v, run_n)

    _ = os.make_directory_all(SAVE_DIR)
    buf: [256]u8
    if err := os.write_entire_file(column_path(buf[:], key), out[:]); err != nil {
        fmt.eprintln("Save: failed to write column", key, err)
        return
    }
    gs.saved_columns[key] = true
    col.modified = false
}

// Save every resident column with unsaved edits.
save_all_modified :: proc(gs: ^Game_State) {
    n := 0
    for key, col in gs.columns {
        if col.modified { save_column(gs, key, col); n += 1 }
    }
    gs.last_autosave = time.tick_now()
    if n > 0 { fmt.printf("Save: wrote %d columns\n", n) }
}

autosave_tick :: proc(gs: ^Game_State) {
    if gs.save_enabled && time.tick_since(gs.last_autosave) >= AUTOSAVE_INTERVAL {
        save_all_modified(gs)
    }
}

// Worker side: read a saved column, or nil if it is missing or corrupt (the
// caller then generates it).
load_column :: proc(key: [2]int) -> ^Column {
    buf: [256]u8
    data, err := os.read_entire_file(column_path(buf[:], key), context.allocator)
    if err != nil { return nil }
    defer delete(data)
    if len(data) < len(SAVE_MAGIC) || string(data[:len(SAVE_MAGIC)]) != SAVE_MAGIC { return nil }

    voxels := make([]u8, COLUMN_VOXELS)
    defer delete(voxels)
    n := 0
    for i := len(SAVE_MAGIC); i + 3 <= len(data); i += 3 {
        count := int(endian.unchecked_get_u16le(data[i + 1:]))
        if n + count > COLUMN_VOXELS { return nil }
        for &v in voxels[n:][:count] { v = data[i] }
        n += count
    }
    if n != COLUMN_VOXELS { return nil }

    col := new(Column)
    for &c, iy in col.chunks {
        c.voxels = new([VOXELS_PER_BRICK]u8)
        copy(c.voxels[:], voxels[iy * VOXELS_PER_BRICK:][:VOXELS_PER_BRICK])
        chunk_compact(&c)
    }
    col.modified = false
    return col
}
