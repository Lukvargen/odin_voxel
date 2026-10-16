package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import SDL "vendor:sdl3"

// Building tools. T cycles three (Shift+T back):
//   Block - Minecraft style: left breaks, right places, held repeats. B or
//           Ctrl+wheel sizes a round brush.
//   Area  - hold left (clear) or right (fill), look across to drag a box out
//           over the face you pressed on, let go to apply. The wheel sets how
//           many layers it rises off that face (or digs into it).
//   Shape - left carves (hold to keep carving: a drill), right stamps a shape
//           (an SDF: sphere, box, cylinder, cone, pyramid, torus, dome). Q
//           picks the shape; the wheel sizes it, Shift+wheel its height,
//           Alt+wheel turns it.
// In Area and Shape, Ctrl+wheel sets a wall thickness (hollow; 0 is solid), V
// what a fill may overwrite (anything / only air / only solid blocks: paint),
// and the wheel works the tool, not the hotbar. Ctrl+Z undoes any edit (a
// held stroke is one edit), Ctrl+Y or Ctrl+Shift+Z redoes.
//
// Modifiers are strict: a Ctrl or Alt combo does only what it's bound to,
// never the plain key's action (Ctrl+wheel is not the hotbar). Shift is also
// sneak, so keys and wheel actions with no Shift binding ignore it.

Build_Tool  :: enum u8 { Block, Area, Shape }
Build_Shape :: enum u8 { Sphere, Box, Cylinder, Cone, Pyramid, Torus, Dome }
Build_Mask  :: enum u8 { All, Air, Solid } // what a fill may replace

Build :: struct {
    tool:   Build_Tool,
    shape:  Build_Shape,
    mask:   Build_Mask,
    size:   int, // shape: horizontal half extent (voxels past the center)
    height: int, // shape: vertical half extent
    wall:   int, // shell thickness, 0 = solid (area and shape)
    yaw:    int, // shape: degrees, in YAW_STEP steps
    layers: int, // area: extra layers off the pressed face (fill) or into it (clear)

    // Area drag, while a button is held.
    dragging:   bool,
    drag_fill:  bool,   // right button: fill; left: clear
    drag_a:     [3]int, // corner under the press
    drag_b:     [3]int, // corner under the crosshair, on the pressed face's plane
    drag_n:     [3]int, // the pressed face's normal

    undo, redo:  [dynamic]Edit_Record,
    undo_voxels: int,  // voxel changes held in `undo`, for the budget
    stroke:      bool, // the last undo record is the held stroke's: repeats join it
}

// Old values of the voxels one edit changed; undoing writes them back.
Edit_Record :: struct { changes: [dynamic]Voxel_Change }
Voxel_Change :: struct { pos: [3]i32, old: u8 }

MAX_EDIT_VOXELS     :: 4_000_000 // an edit's bounding box, at most (~160^3)
UNDO_VOXEL_BUDGET   :: 6_000_000 // voxel changes kept for undo (16 B each)
UNDO_STEPS          :: 64
MAX_SHAPE_SIZE      :: 80
MAX_AREA_LAYERS     :: 120
YAW_STEP            :: 15

// Which voxels an edit covers: every voxel of [lo, hi] (thinned to a shell of
// `wall` if non-zero), or with `shape` set only those inside the shape.
Edit_Region :: struct {
    lo, hi:   [3]int, // inclusive
    is_shape: bool,
    kind:     Build_Shape,
    center:   [3]int,
    size:     int,
    height:   int,
    wall:     int,
    cos_yaw, sin_yaw: f32,
}

build_init :: proc(b: ^Build) {
    b.size, b.height = 4, 4
}

build_destroy :: proc(b: ^Build) {
    for &r in b.undo { delete(r.changes) }
    for &r in b.redo { delete(r.changes) }
    delete(b.undo)
    delete(b.redo)
}

build_tool_name :: proc(t: Build_Tool) -> string {
    switch t {
    case .Block: return "Block"
    case .Area:  return "Area"
    case .Shape: return "Shape"
    }
    return ""
}

build_shape_name :: proc(s: Build_Shape) -> string {
    switch s {
    case .Sphere:   return "Sphere"
    case .Box:      return "Box"
    case .Cylinder: return "Cylinder"
    case .Cone:     return "Cone"
    case .Pyramid:  return "Pyramid"
    case .Torus:    return "Torus"
    case .Dome:     return "Dome"
    }
    return ""
}

build_mask_name :: proc(m: Build_Mask) -> string {
    switch m {
    case .All:   return "replace all"
    case .Air:   return "only air"
    case .Solid: return "paint solid"
    }
    return ""
}

// ─── Input ──────────────────────────────────────────────────────────────────

Mod  :: enum u8 { Ctrl, Shift, Alt }
Mods :: bit_set[Mod]

// Bench screenshots: the modifiers the HUD shows as held.
bench_hud_mods: Maybe(Mods)

// The modifiers held right now.
held_mods :: proc() -> Mods {
    if m, ok := bench_hud_mods.?; ok { return m }
    return key_mods(SDL.GetModState())
}

key_mods :: proc(m: SDL.Keymod) -> (r: Mods) {
    if m & SDL.KMOD_CTRL  != {} { r += {.Ctrl} }
    if m & SDL.KMOD_SHIFT != {} { r += {.Shift} }
    if m & SDL.KMOD_ALT   != {} { r += {.Alt} }
    return
}

// What the wheel changes for a tool under the held modifiers.
Wheel_Target :: enum u8 { None, Hotbar, Brush, Layers, Size, Height, Walls, Turn }

wheel_target :: proc(tool: Build_Tool, mods: Mods) -> Wheel_Target {
    switch tool {
    case .Block:
        switch mods - {.Shift} {
        case {}:      return .Hotbar
        case {.Ctrl}: return .Brush
        }
    case .Area:
        switch mods - {.Shift} {
        case {}:      return .Layers
        case {.Ctrl}: return .Walls
        }
    case .Shape:
        switch mods {
        case {}:       return .Size
        case {.Shift}: return .Height
        case {.Ctrl}:  return .Walls
        case {.Alt}:   return .Turn
        }
    }
    return .None
}

// Brush radii for big edits; 0 is one block.
BRUSHES :: [6]int{0, 1, 2, 3, 5, 8}

@(private="file")
cycle :: proc(i, n, step: int) -> int { return ((i + step) % n + n) % n }

// Keys for the tools; main calls this on key down while playing. True if the
// key was used (main then does nothing else with it).
build_key :: proc(gs: ^Game_State, key: SDL.Keycode, mods: Mods) -> bool {
    b := &gs.build
    // T, Q, V, B: plain cycles forward, Shift back; with Ctrl or Alt, nothing.
    step := .Shift in mods ? -1 : 1
    plain := mods & {.Ctrl, .Alt} == {}
    switch key {
    case SDL.K_T:
        if !plain { return false }
        b.tool = Build_Tool(cycle(int(b.tool), len(Build_Tool), step))
        b.dragging = false
        if gs.combat.sword { combat_toggle_sword(gs) }
    case SDL.K_Q:
        if !plain || b.tool != .Shape { return false }
        b.shape = Build_Shape(cycle(int(b.shape), len(Build_Shape), step))
    case SDL.K_V:
        if !plain || b.tool == .Block { return false }
        b.mask = Build_Mask(cycle(int(b.mask), len(Build_Mask), step))
    case SDL.K_B:
        if !plain { return false }
        brush_step(gs, step)
    case SDL.K_Z:
        switch mods {
        case {.Ctrl}:         build_undo(gs, &b.undo, &b.redo, "Undo")
        case {.Ctrl, .Shift}: build_undo(gs, &b.redo, &b.undo, "Redo")
        case:                 return false
        }
    case SDL.K_Y:
        if mods != {.Ctrl} { return false }
        build_undo(gs, &b.redo, &b.undo, "Redo")
    case:
        return false
    }
    return true
}

@(private="file")
brush_step :: proc(gs: ^Game_State, step: int) {
    brushes := BRUSHES
    at := 0
    for r, i in brushes { if r <= gs.brush_radius { at = i } }
    gs.brush_radius = brushes[clamp(at + step, 0, len(brushes) - 1)]
}

// The mouse wheel while playing (up = +1): the hotbar, or sizes the current
// tool, by wheel_target.
build_wheel :: proc(gs: ^Game_State, steps: int, mods: Mods) {
    b := &gs.build
    if steps == 0 { return }
    switch wheel_target(b.tool, mods) {
    case .None:
    case .Hotbar: hotbar_select(gs, cycle(gs.hotbar_slot, HOTBAR_SLOTS, -steps)) // down = next
    case .Brush:  brush_step(gs, steps)
    case .Layers: b.layers = clamp(b.layers + steps, 0, MAX_AREA_LAYERS)
    case .Walls:  b.wall = clamp(b.wall + steps, 0, 32)
    case .Turn:   b.yaw = cycle(b.yaw, 360, steps * YAW_STEP)
    case .Height: b.height = clamp(b.height + steps, 0, MAX_SHAPE_SIZE)
    case .Size:
        // Size and height together, so a sphere stays round.
        b.size   = clamp(b.size + steps, 0, MAX_SHAPE_SIZE)
        b.height = clamp(b.height + steps, 0, MAX_SHAPE_SIZE)
    }
}

// Once a frame, after the player moved: the clicks of the current tool.
build_update :: proc(gs: ^Game_State, dt: f32) {
    b := &gs.build
    active := gs.mouse_locked && !gs.glider.deployed && !gs.combat.sword
    if !active {
        b.dragging = false
        return
    }
    gs.edit_timer -= dt
    switch b.tool {
    case .Block: build_block_update(gs)
    case .Area:  build_area_update(gs)
    case .Shape: build_shape_update(gs)
    }
}

// Left breaks, right places; a click edits at once, holding repeats every
// EDIT_REPEAT seconds (one undo for the whole stroke). The brush radius
// applies to both; torches are always one block.
@(private="file")
build_block_update :: proc(gs: ^Game_State) {
    breaking := gs.left_pressed  || (gs.left_held  && gs.edit_timer <= 0)
    placing  := gs.right_pressed || (gs.right_held && gs.edit_timer <= 0)
    if !breaking && !placing { return }
    gs.edit_timer = EDIT_REPEAT
    hit, nrm, ok := raycast_voxel(gs, gs.camera.pos, camera_forward(gs.camera), REACH)
    if !ok { return }
    target := hit
    block  := Block_Type.Air
    if !breaking {
        target = hit + nrm
        block  = gs.selected_block
    }
    radius := block == .Torch ? 0 : gs.brush_radius
    stroke := !gs.left_pressed && !gs.right_pressed
    build_apply(gs, sphere_region(target, radius), block, .All, merge = stroke)
}

// Right stamps the shape once; left carves it, and held keeps carving where
// the crosshair goes (deeper and deeper if it stays put: a drill), as one
// undo.
@(private="file")
build_shape_update :: proc(gs: ^Game_State) {
    b := &gs.build
    carving := gs.left_pressed || (gs.left_held && gs.edit_timer <= 0)
    if !carving && !gs.right_pressed { return }
    gs.edit_timer = EDIT_REPEAT
    place := !carving
    if r, ok := build_shape_target(gs, place); ok {
        build_apply(gs, r, place ? gs.selected_block : .Air, b.mask, merge = carving && !gs.left_pressed)
    }
}

// Press: the corner under the crosshair. Held: the far corner follows the
// crosshair across the pressed face's plane. Release: apply. The other
// button cancels.
@(private="file")
build_area_update :: proc(gs: ^Game_State) {
    b := &gs.build
    if !b.dragging {
        if !gs.left_pressed && !gs.right_pressed { return }
        hit, nrm, ok := raycast_voxel(gs, gs.camera.pos, camera_forward(gs.camera), REACH)
        if !ok { return }
        b.dragging  = true
        b.drag_fill = gs.right_pressed
        b.drag_n    = nrm
        b.drag_a    = b.drag_fill ? hit + nrm : hit
        b.drag_b    = b.drag_a
        return
    }
    if (b.drag_fill && gs.left_pressed) || (!b.drag_fill && gs.right_pressed) {
        b.dragging = false
        ui_toast(gs, "Cancelled", 0.8)
        return
    }
    b.drag_b = area_drag_corner(gs)
    if b.drag_fill ? gs.right_held : gs.left_held { return }
    b.dragging = false
    build_apply(gs, area_region(b), b.drag_fill ? gs.selected_block : .Air, b.mask)
}

// Where the crosshair ray meets the plane through the drag's first corner,
// across its face; the old corner if it doesn't (looking away, or too far).
@(private="file")
area_drag_corner :: proc(gs: ^Game_State) -> [3]int {
    b := &gs.build
    n := [3]f32{f32(b.drag_n.x), f32(b.drag_n.y), f32(b.drag_n.z)}
    a := b.drag_a
    plane := [3]f32{f32(a.x), f32(a.y), f32(a.z)} + 0.5
    eye, fwd := gs.camera.pos, camera_forward(gs.camera)
    denom := la.dot(fwd, n)
    if abs(denom) < 1e-4 { return b.drag_b }
    t := la.dot(plane - eye, n) / denom
    if t <= 0 || t > REACH * 2 { return b.drag_b }
    p := eye + fwd * t
    c := [3]int{int(math.floor(p.x)), int(math.floor(p.y)), int(math.floor(p.z))}
    for i in 0 ..< 3 { if b.drag_n[i] != 0 { c[i] = a[i] } }
    return c
}

// The drag's box, grown `layers` along the face normal: off the face for a
// fill, into it for a clear.
area_region :: proc(b: ^Build) -> Edit_Region {
    r := Edit_Region{lo = la.min(b.drag_a, b.drag_b), hi = la.max(b.drag_a, b.drag_b), wall = b.wall}
    for i in 0 ..< 3 {
        d := b.drag_n[i] * (b.drag_fill ? 1 : -1)
        if d > 0 { r.hi[i] += b.layers }
        if d < 0 { r.lo[i] -= b.layers }
    }
    return r
}

// The shape under the crosshair. Placing, it sits on the face you look at;
// carving, it's centered on the voxel.
build_shape_target :: proc(gs: ^Game_State, place: bool) -> (Edit_Region, bool) {
    b := &gs.build
    hit, nrm, ok := raycast_voxel(gs, gs.camera.pos, camera_forward(gs.camera), REACH)
    if !ok { return {}, false }
    center := hit
    if place {
        ext := [3]int{b.size, b.height, b.size}
        center = hit + nrm + nrm * ext
    }
    return shape_region(b.shape, center, b.size, b.height, b.wall, f32(b.yaw)), true
}

shape_region :: proc(kind: Build_Shape, center: [3]int, size, height, wall: int, yaw_deg: f32) -> Edit_Region {
    r := Edit_Region{is_shape = true, kind = kind, center = center, size = size, height = height, wall = wall}
    rad := yaw_deg * math.PI / 180
    r.cos_yaw, r.sin_yaw = math.cos(rad), math.sin(rad)
    // Square shapes turned reach out to the corners.
    xz := size
    if (kind == .Box || kind == .Pyramid) && yaw_deg != 0 { xz = int(math.ceil(f32(size) * math.SQRT_TWO)) }
    r.lo = center - {xz, height, xz}
    r.hi = center + {xz, height, xz}
    return r
}

sphere_region :: proc(center: [3]int, radius: int) -> Edit_Region {
    return shape_region(.Sphere, center, radius, radius, 0, 0)
}

region_volume :: proc(r: Edit_Region) -> int {
    d := r.hi - r.lo + 1
    return d.x * d.y * d.z
}

// ─── SDFs ───────────────────────────────────────────────────────────────────

// Signed distance (in voxels, negative inside) from shape-local point p
// (relative to the center voxel, already turned into the shape's frame) to
// the surface. Some are approximations, close enough to cut shells by.
shape_sdf :: proc(kind: Build_Shape, p: [3]f32, size, height: int) -> f32 {
    s := max(f32(size), 0.5)
    h := max(f32(height), 0.5)
    switch kind {
    case .Sphere:
        return ellipsoid_sdf(p, {s, h, s})
    case .Box:
        q := la.abs(p) - [3]f32{s, h, s}
        return max(q.x, q.y, q.z)
    case .Cylinder:
        return max(la.length(p.xz) - s, abs(p.y) - h)
    case .Cone, .Pyramid:
        // Base 2s wide at y = -h narrowing to a point at y = +h.
        q := kind == .Cone ? la.length(p.xz) : max(abs(p.x), abs(p.z))
        rad := s * (h - p.y) / (2 * h)
        side := (q - rad) * (2 * h) / math.sqrt(4 * h * h + s * s)
        return max(side, abs(p.y) - h)
    case .Torus:
        // Tube radius h, reaching out to s.
        major := max(s - h, 0)
        return la.length([2]f32{la.length(p.xz) - major, p.y}) - h
    case .Dome:
        // Half an ellipsoid on its base at y = -h, 2h tall.
        q := p + {0, h, 0}
        return max(ellipsoid_sdf(q, {s, 2 * h, s}), -q.y)
    }
    return 1
}

@(private="file")
ellipsoid_sdf :: proc(p, r: [3]f32) -> f32 {
    k0 := la.length(p / r)
    k1 := la.length(p / (r * r))
    if k1 == 0 { return -min(r.x, r.y, r.z) }
    return k0 * (k0 - 1) / k1
}

region_contains :: proc(r: ^Edit_Region, v: [3]int) -> bool {
    if !r.is_shape {
        if r.wall <= 0 { return true }
        d := min(la.min(v - r.lo), la.min(r.hi - v))
        return d < r.wall
    }
    o := v - r.center
    p := [3]f32{f32(o.x), f32(o.y), f32(o.z)}
    p.x, p.z = p.x * r.cos_yaw + p.z * r.sin_yaw, -p.x * r.sin_yaw + p.z * r.cos_yaw
    d := shape_sdf(r.kind, p, r.size, r.height)
    if d > 1e-3 { return false }
    return r.wall <= 0 || d > -f32(r.wall)
}

// ─── Applying and undoing ───────────────────────────────────────────────────

// Sets every voxel of `r` that `mask` allows to `block` (.Air clears, and
// then ignores the mask), never into the player. Records the edit for undo.
// Returns how many voxels changed.
build_apply :: proc(gs: ^Game_State, r: Edit_Region, block: Block_Type, mask: Build_Mask, merge := false) -> int {
    r := r
    b := &gs.build
    if !merge { b.stroke = false }
    if !client_may_build(gs) {
        ui_toast(gs, "The host has turned off building for visitors", 1.5)
        return 0
    }
    if region_volume(r) > MAX_EDIT_VOXELS {
        ui_toast(gs, "Too big: make it smaller")
        return 0
    }
    rec: Edit_Record
    changed := make([dynamic][3]int)
    defer delete(changed)
    dirty := make(map[int]bool)
    defer delete(dirty)

    eye := gs.camera.pos
    blk := u8(block)
    into_player := !block_solid(blk) // may overlap the player
    water := u8(Block_Type.Water)
    first_old := Block_Type.Air
    y_lo, y_hi := max(r.lo.y, WORLD_Y_MIN), min(r.hi.y, WORLD_Y_MAX - 1)
    for z in r.lo.z ..= r.hi.z {
        for x in r.lo.x ..= r.hi.x {
            col := gs.columns[{x >> 3, z >> 3}] // CHUNK_VOXELS == 8
            if col == nil { continue }
            last_slot := -1
            for y in y_lo ..= y_hi {
                p := [3]int{x, y, z}
                if !region_contains(&r, p) { continue }
                c := &col.chunks[chunk_y_index(y >> 3)]
                vi := (x & 7) + (y & 7) * CHUNK_VOXELS + (z & 7) * CHUNK_VOXELS * CHUNK_VOXELS
                cur := chunk_voxel(c, vi)
                if block != .Air {
                    if mask == .Air && cur != 0 && cur != water { continue }
                    if mask == .Solid && !block_solid(cur) { continue }
                }
                if !into_player && aabb_hits_voxel(eye, p) { continue }
                if !chunk_set_voxel(c, vi, blk) { continue }
                col.modified = true
                if slot := ring_slot(x >> 3, y >> 3, z >> 3); slot != last_slot {
                    dirty[slot] = true
                    last_slot = slot
                }
                if len(changed) == 0 { first_old = Block_Type(cur) }
                append(&changed, p)
                append(&rec.changes, Voxel_Change{{i32(x), i32(y), i32(z)}, cur})
            }
        }
    }
    if len(changed) == 0 {
        delete(rec.changes)
        return 0
    }
    if block == .Air { fill_dug_water(gs, changed[:]) }
    build_commit(gs, changed[:], dirty)
    radius := r.is_shape ? max(r.size, r.height) : la.max(r.hi - r.lo) / 2
    audio_edit(r.is_shape ? r.center : (r.lo + r.hi) / 2, block, first_old, min(radius, 8))

    for &x in b.redo { delete(x.changes) }
    clear(&b.redo)
    if merge && b.stroke && len(b.undo) > 0 {
        // Same stroke: undone together with what came before it.
        last := &b.undo[len(b.undo) - 1]
        append(&last.changes, ..rec.changes[:])
        b.undo_voxels += len(rec.changes)
        delete(rec.changes)
        trim_undo(b)
    } else {
        push_record(b, &b.undo, rec)
    }
    b.stroke = true
    return len(changed)
}

// Relight, re-upload and re-summarise after voxels changed, and tell the
// server (which passes the change on to the other players).
@(private="file")
build_commit :: proc(gs: ^Game_State, changed: [][3]int, dirty: map[int]bool) {
    light_on_edit(gs, changed)
    for slot in dirty { gpu_sync_slot(gs, slot) }
    far_update_edited(gs, changed)
    client_send_voxels(gs, changed)
}

// Relight, re-upload and re-summarise after another player changed voxels.
world_refresh :: proc(gs: ^Game_State, changed: [][3]int) {
    if len(changed) == 0 { return }
    dirty := make(map[int]bool, 16, context.temp_allocator)
    for p in changed { dirty[ring_slot(p.x >> 3, p.y >> 3, p.z >> 3)] = true }
    light_on_edit(gs, changed)
    for slot in dirty { gpu_sync_slot(gs, slot) }
    far_update_edited(gs, changed)
}

// Pushes onto the undo (or redo) stack, dropping the oldest edits past the
// step and voxel budgets. An edit bigger than the whole budget isn't kept.
@(private="file")
push_record :: proc(b: ^Build, stack: ^[dynamic]Edit_Record, rec: Edit_Record) {
    n := len(rec.changes)
    if n > UNDO_VOXEL_BUDGET {
        delete(rec.changes)
        return
    }
    append(stack, rec)
    if stack != &b.undo { return }
    b.undo_voxels += n
    trim_undo(b)
}

@(private="file")
trim_undo :: proc(b: ^Build) {
    for len(b.undo) > 1 && (len(b.undo) > UNDO_STEPS || b.undo_voxels > UNDO_VOXEL_BUDGET) {
        b.undo_voxels -= len(b.undo[0].changes)
        delete(b.undo[0].changes)
        ordered_remove(&b.undo, 0)
    }
}

// Pops an edit off `from`, writes its old voxels back, and pushes what they
// were onto `to` (undo -> redo, or redo -> undo).
@(private="file")
build_undo :: proc(gs: ^Game_State, from, to: ^[dynamic]Edit_Record, verb: string) {
    b := &gs.build
    if !client_may_build(gs) {
        ui_toast(gs, "The host has turned off building for visitors", 1.5)
        return
    }
    if len(from) == 0 {
        ui_toast(gs, fmt.tprintf("Nothing to %s", verb == "Undo" ? "undo" : "redo"), 0.8)
        return
    }
    b.stroke = false
    rec := pop(from)
    if from == &b.undo { b.undo_voxels -= len(rec.changes) }
    defer delete(rec.changes)
    back: Edit_Record
    changed := make([dynamic][3]int)
    defer delete(changed)
    dirty := make(map[int]bool)
    defer delete(dirty)
    #reverse for ch in rec.changes {
        p := [3]int{int(ch.pos.x), int(ch.pos.y), int(ch.pos.z)}
        col := gs.columns[{p.x >> 3, p.z >> 3}]
        if col == nil { continue } // streamed out since
        c := &col.chunks[chunk_y_index(p.y >> 3)]
        vi := (p.x & 7) + (p.y & 7) * CHUNK_VOXELS + (p.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS
        cur := chunk_voxel(c, vi)
        if !chunk_set_voxel(c, vi, ch.old) { continue }
        col.modified = true
        dirty[ring_slot(p.x >> 3, p.y >> 3, p.z >> 3)] = true
        append(&changed, p)
        append(&back.changes, Voxel_Change{ch.pos, cur})
    }
    if len(changed) > 0 { build_commit(gs, changed[:], dirty) }
    push_record(b, to, back)
    ui_toast(gs, fmt.tprintf("%s: %s blocks", verb, thousands(len(changed))), 1)
}

// ─── Preview ────────────────────────────────────────────────────────────────

// Line segments outlining what a click would do (world space), and whether
// it's a fill (else a clear). Empty if nothing is targeted.
Build_Preview :: struct {
    segs:     [dynamic][2][3]f32,
    carve:    [dynamic][2][3]f32, // shape: where a left click would carve, drawn faint
    fill:     bool,
    too_big:  bool,
    dims:     [3]int, // area: the box's size
    has_dims: bool,
}

// Built in the temp allocator.
build_preview :: proc(gs: ^Game_State) -> (pv: Build_Preview) {
    pv.segs = make([dynamic][2][3]f32, context.temp_allocator)
    pv.carve = make([dynamic][2][3]f32, context.temp_allocator)
    b := &gs.build
    eye := gs.camera.pos
    switch b.tool {
    case .Block:
        hit, _, ok := raycast_voxel(gs, gs.camera.pos, camera_forward(gs.camera), REACH)
        if !ok { return }
        lo := [3]f32{f32(hit.x), f32(hit.y), f32(hit.z)}
        wire_box(&pv.segs, lo + 0.5, {0.502, 0.502, 0.502}, 1, 0)
        if gs.brush_radius > 0 {
            r := f32(gs.brush_radius) + 0.5
            wire_shape(&pv.segs, .Sphere, lo + 0.5, r, r, 1, 0, eye)
        }
    case .Area:
        r: Edit_Region
        if b.dragging {
            r = area_region(b)
            pv.fill = b.drag_fill
        } else {
            hit, _, ok := raycast_voxel(gs, gs.camera.pos, camera_forward(gs.camera), REACH)
            if !ok { return }
            r = {lo = hit, hi = hit}
        }
        pv.dims, pv.has_dims = r.hi - r.lo + 1, b.dragging
        pv.too_big = region_volume(r) > MAX_EDIT_VOXELS
        lo := [3]f32{f32(r.lo.x), f32(r.lo.y), f32(r.lo.z)}
        hi := [3]f32{f32(r.hi.x), f32(r.hi.y), f32(r.hi.z)} + 1
        wire_box(&pv.segs, (lo + hi) / 2, (hi - lo) / 2 + 0.002, 1, 0)
        if b.wall > 0 && b.dragging {
            inner := (hi - lo) / 2 - f32(b.wall)
            if inner.x > 0 && inner.y > 0 && inner.z > 0 { wire_box(&pv.segs, (lo + hi) / 2, inner, 1, 0) }
        }
    case .Shape:
        // Right places: the shape sitting on the face looked at. Left
        // carves: the same shape around the voxel, faint.
        r, ok := build_shape_target(gs, true)
        if !ok { return }
        pv.fill = true
        pv.too_big = region_volume(r) > MAX_EDIT_VOXELS
        s, h := f32(b.size) + 0.5, f32(b.height) + 0.5
        c := [3]f32{f32(r.center.x), f32(r.center.y), f32(r.center.z)} + 0.5
        wire_shape(&pv.segs, b.shape, c, s, h, r.cos_yaw, r.sin_yaw, eye)
        if k, ok2 := build_shape_target(gs, false); ok2 {
            c = [3]f32{f32(k.center.x), f32(k.center.y), f32(k.center.z)} + 0.5
            wire_shape(&pv.carve, b.shape, c, s, h, k.cos_yaw, k.sin_yaw, eye)
        }
    }
    return
}

@(private="file")
wire_box :: proc(segs: ^[dynamic][2][3]f32, c, half: [3]f32, cy, sy: f32) {
    ax := [3]f32{cy, 0, sy} * half.x
    az := [3]f32{-sy, 0, cy} * half.z
    ay := [3]f32{0, half.y, 0}
    corner :: proc(c, ax, ay, az: [3]f32, k: int) -> [3]f32 {
        return c + (k & 1 != 0 ? ax : -ax) + (k & 2 != 0 ? ay : -ay) + (k & 4 != 0 ? az : -az)
    }
    for a in 0 ..< 8 {
        for bit in ([3]int{1, 2, 4}) {
            if a & bit != 0 { continue }
            append(segs, [2][3]f32{corner(c, ax, ay, az, a), corner(c, ax, ay, az, a | bit)})
        }
    }
}

// An ellipse arc c + cos(t) u + sin(t) v for t in [t0, t1].
@(private="file")
wire_arc :: proc(segs: ^[dynamic][2][3]f32, c, u, v: [3]f32, t0: f32 = 0, t1: f32 = 2 * math.PI) {
    N :: 40
    prev := c + u * math.cos(t0) + v * math.sin(t0)
    for i in 1 ..= N {
        t := t0 + (t1 - t0) * f32(i) / N
        p := c + u * math.cos(t) + v * math.sin(t)
        append(segs, [2][3]f32{prev, p})
        prev = p
    }
}

// The outline of a shape centered at c, s across and h up from the center.
@(private="file")
wire_shape :: proc(segs: ^[dynamic][2][3]f32, kind: Build_Shape, c: [3]f32, s, h: f32, cy, sy: f32, eye: [3]f32) {
    X := [3]f32{cy, 0, sy}
    Z := [3]f32{-sy, 0, cy}
    Y := [3]f32{0, 1, 0}
    // Round shapes: their outline as the eye sees it, a ring across the view
    // (side to side, and up through the top), not rings seen edge-on.
    view := c - eye
    across := la.normalize0([3]f32{-view.z, 0, view.x})
    if across == {} { across = X }
    up := la.normalize0(la.cross(across, view))
    if up.y < 0 { up = -up }
    switch kind {
    case .Sphere:
        wire_arc(segs, c, X * s, Z * s)
        wire_arc(segs, c, across * s, [3]f32{up.x * s, up.y * h, up.z * s})
    case .Box:
        wire_box(segs, c, {s, h, s}, cy, sy)
    case .Cylinder:
        wire_arc(segs, c - Y * h, X * s, Z * s)
        wire_arc(segs, c + Y * h, X * s, Z * s)
        for d in ([4][3]f32{X, -X, Z, -Z}) { append(segs, [2][3]f32{c - Y * h + d * s, c + Y * h + d * s}) }
    case .Cone:
        wire_arc(segs, c - Y * h, X * s, Z * s)
        for d in ([4][3]f32{X, -X, Z, -Z}) { append(segs, [2][3]f32{c - Y * h + d * s, c + Y * h}) }
    case .Pyramid:
        base := c - Y * h
        corners := [4][3]f32{base + (X + Z) * s, base + (X - Z) * s, base + (-X - Z) * s, base + (-X + Z) * s}
        for i in 0 ..< 4 {
            append(segs, [2][3]f32{corners[i], corners[(i + 1) % 4]})
            append(segs, [2][3]f32{corners[i], c + Y * h})
        }
    case .Torus:
        major := max(s - h, 0)
        wire_arc(segs, c, X * s, Z * s)
        if major - h > 0 { wire_arc(segs, c, X * (major - h), Z * (major - h)) }
        wire_arc(segs, c + Y * h, X * major, Z * major)
        wire_arc(segs, c - Y * h, X * major, Z * major)
    case .Dome:
        base := c - Y * h
        wire_arc(segs, base, X * s, Z * s)
        wire_arc(segs, base, across * s, Y * 2 * h, 0, math.PI)
    }
}
