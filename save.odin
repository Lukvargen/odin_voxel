package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Player edits are kept by saving every edited column to its own file under
// save_dir. Unedited columns are never saved: generation is deterministic, so
// they are simply regenerated. A column with a save file is loaded from it
// instead (worker side), so edits survive both unloading and restarts.
//
// File format: "VXC1", then run-length encoded voxels (block u8, count u16
// little endian) covering all CHUNKS_H chunks in order, 512 voxels each.
// Light is not saved; it is recomputed on load.

// saves/<world name> (the world= argument); set before the first load.
save_dir          := "saves/world"
SAVE_MAGIC        :: "VXC2" // VXC1 saves predate biome terrain and are ignored
AUTOSAVE_INTERVAL :: 30 * time.Second
COLUMN_VOXELS     :: CHUNKS_H * VOXELS_PER_BRICK

@(private="file")
column_path :: proc(buf: []u8, key: [2]int) -> string {
    return fmt.bprintf(buf, "%s/c.%d.%d.bin", save_dir, key.x, key.y)
}

// Note which columns have save files. Call before the first enqueue.
save_init :: proc(gs: ^Game_State) {
    gs.save_enabled = true
    files, err := os.read_all_directory_by_path(save_dir, context.temp_allocator)
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
        fmt.printf("Save: %d edited columns in %s\n", len(gs.saved_columns), save_dir)
    }
}

save_column :: proc(w: ^World, key: [2]int, col: ^Column) {
    if !w.save_enabled { return }
    out := make([dynamic]u8, 0, 4096)
    defer delete(out)
    append(&out, SAVE_MAGIC)
    column_encode(col, &out)

    _ = os.make_directory_all(save_dir)
    buf: [256]u8
    if err := os.write_entire_file(column_path(buf[:], key), out[:]); err != nil {
        fmt.eprintln("Save: failed to write column", key, err)
        return
    }
    w.saved_columns[key] = true
    col.modified = false
}

// A column's voxels, run-length encoded (block u8, count u16 little
// endian), appended to out: a save file's body, and what the server sends
// of an edited column.
column_encode :: proc(col: ^Column, out: ^[dynamic]u8) {
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
            flush(out, run_v, run_n)
            run_v, run_n = v, 1
        }
    }
    flush(out, run_v, run_n)
}

// A column from column_encode's bytes, or nil if they don't make one
// (unknown blocks, wrong length). No light yet.
column_decode :: proc(rle: []u8) -> ^Column {
    voxels := make([]u8, COLUMN_VOXELS)
    defer delete(voxels)
    n := 0
    for i := 0; i + 3 <= len(rle); i += 3 {
        count := int(endian.unchecked_get_u16le(rle[i + 1:]))
        if n + count > COLUMN_VOXELS || int(rle[i]) >= len(Block_Type) { return nil }
        for &v in voxels[n:][:count] { v = rle[i] }
        n += count
    }
    if n != COLUMN_VOXELS { return nil }

    col := new(Column)
    for &c, iy in col.chunks {
        c.voxels = new([VOXELS_PER_BRICK]u8)
        copy(c.voxels[:], voxels[iy * VOXELS_PER_BRICK:][:VOXELS_PER_BRICK])
        chunk_compact(&c)
    }
    return col
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
    return column_decode(data[len(SAVE_MAGIC):])
}
