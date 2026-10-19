package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import SDL "vendor:sdl3"

// Building tools. T cycles three (Shift+T back):
//   Block - Minecraft style: left breaks, right places, held repeats. B or
//           Ctrl+wheel sizes a round brush.
//   Area  - a box you select, then act on. Left sets one corner, right the
//           other (the first click of either starts a one-block box); C
//           picks where the cursor sits: on the block aimed at, in front of
//           its face, or in the air at a set distance (Alt+wheel). The
//           selection stays while you move: the wheel (or Up / Down) pushes
//           the face you look at out or in, Shift+wheel moves the whole box
//           that way. F fills it with the held block, X clears it, Backspace
//           drops it.
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

Build_Tool  :: enum u8 { Block, Magic, Area, Shape } // Magic: survival's spell, to try in creative (magic.odin)
Build_Shape :: enum u8 { Sphere, Box, Cylinder, Cone, Pyramid, Torus, Dome }
Build_Mask  :: enum u8 { All, Air, Solid } // what a fill may replace
Build_Cursor :: enum u8 { Block, Face, Air } // where an area corner goes

Build :: struct {
    tool:   Build_Tool,
    shape:  Build_Shape,
    mask:   Build_Mask,
    size:   int, // shape: horizontal half extent (voxels past the center)
    height: int, // shape: vertical half extent
    wall:   int, // shell thickness, 0 = solid (area and shape)
    yaw:    int, // shape: degrees, in YAW_STEP steps

    // Area selection: corners a (left click) and b (right), inclusive.
    selected:  bool,
    sel_a:     [3]int,
    sel_b:     [3]int,
    cursor:    Build_Cursor,
    air_dist:  int, // .Air cursor: voxels from the eye

    undo, redo:  [dynamic]Edit_Record,
    undo_voxels: int,  // voxel changes held in `undo`, for the budget
    stroke:      bool, // the last undo record is the held stroke's: repeats join it

    door_click:  bool, // right went down on a door: holding it doesn't build
    box:         bool, // the brush is a box: hold and drag one out (build_drag.odin); B or Ctrl+wheel
    drag:        Drag, // a box being dragged out
}

// Old values of the voxels one edit changed; undoing writes them back.
Edit_Record :: struct { changes: [dynamic]Voxel_Change }
Voxel_Change :: struct { pos: [3]i32, old: u8 }

MAX_EDIT_VOXELS     :: 4_000_000 // an edit's bounding box, at most (~160^3)
UNDO_VOXEL_BUDGET   :: 6_000_000 // voxel changes kept for undo (16 B each)
UNDO_STEPS          :: 64
MAX_SHAPE_SIZE      :: 80
MAX_AIR_DIST        :: 64
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
    b.air_dist = 8
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
    case .Magic: return "Magic"
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

build_cursor_name :: proc(c: Build_Cursor) -> string {
    switch c {
    case .Block: return "on block"
    case .Face:  return "on face"
    case .Air:   return "in the air"
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
Wheel_Target :: enum u8 { None, Hotbar, Brush, Push, Move, Distance, Size, Height, Walls, Turn }

wheel_target :: proc(tool: Build_Tool, mods: Mods) -> Wheel_Target {
    switch tool {
    case .Block, .Magic:
        switch mods - {.Shift} {
        case {}:      return .Hotbar
        case {.Ctrl}: return .Brush
        }
    case .Area:
        switch mods {
        case {}:       return .Push
        case {.Shift}: return .Move
        case {.Ctrl}:  return .Walls
        case {.Alt}:   return .Distance
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

cycle :: proc(i, n, step: int) -> int { return ((i + step) % n + n) % n }

// Keys for the tools; main calls this on key down while playing. True if the
// key was used (main then does nothing else with it).
build_key :: proc(gs: ^Game_State, key: SDL.Keycode, mods: Mods) -> bool {
    b := &gs.build
    // T, Q, V, B: plain cycles forward, Shift back; with Ctrl or Alt, nothing.
    step := .Shift in mods ? -1 : 1
    plain := mods & {.Ctrl, .Alt} == {}
    if (key == SDL.K_TAB || key == SDL.K_Q) && plain && drag_turn(gs) { return true } // a box: floor <-> wall
    if gs.survival { // magic, not tools (magic.odin); no undo either: it'd make blocks
        if key != SDL.K_B || !plain { return false }
        brush_step(gs, step, wrap = true)
        return true
    }
    switch key {
    case SDL.K_T:
        if !plain { return false }
        b.tool = Build_Tool(cycle(int(b.tool), len(Build_Tool), step))
        drag_cancel(gs)
        if gs.combat.fighting { combat_toggle(gs) }
    case SDL.K_Q:
        if !plain || b.tool != .Shape { return false }
        b.shape = Build_Shape(cycle(int(b.shape), len(Build_Shape), step))
    case SDL.K_V:
        if !plain || b.tool == .Block { return false }
        b.mask = Build_Mask(cycle(int(b.mask), len(Build_Mask), step))
    case SDL.K_B:
        if !plain { return false }
        brush_step(gs, step, wrap = true)
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
        return b.tool == .Area && area_key(gs, key, mods)
    }
    return true
}

// The Area tool's keys: the cursor, and what to do with the selection. Not
// with the sword out (F blocks then) or gliding.
@(private="file")
area_key :: proc(gs: ^Game_State, key: SDL.Keycode, mods: Mods) -> bool {
    b := &gs.build
    if gs.combat.fighting || gs.glider.deployed { return false }
    plain := mods & {.Ctrl, .Alt} == {}
    switch key {
    case SDL.K_C:
        if !plain { return false }
        b.cursor = Build_Cursor(cycle(int(b.cursor), len(Build_Cursor), .Shift in mods ? -1 : 1))
    case SDL.K_BACKSPACE:
        if !plain || !b.selected { return false }
        b.selected = false
    case SDL.K_UP, SDL.K_DOWN:
        if !plain || !b.selected { return false }
        steps := key == SDL.K_UP ? 1 : -1
        if .Shift in mods { area_move(gs, steps) } else { area_push(gs, steps) }
    case SDL.K_F, SDL.K_X:
        if !plain { return false }
        if !b.selected {
            ui_toast(gs, "Select an area first: left and right click its corners", 1.5)
            return true
        }
        fill := key == SDL.K_F
        n := build_apply(gs, area_region(b), fill ? gs.selected_block : .Air, b.mask)
        ui_toast(gs, n == 0 ? "Nothing to change" : fmt.tprintf("%s %s blocks", fill ? "Filled" : "Cleared", thousands(n)), 1)
    case:
        return false
    }
    return true
}

// B / Ctrl+wheel: one block, a box (dragged out: build_drag.odin), then the
// round brushes, BRUSHES[1:]. In survival only as big as the spell allows.
// wrap: past the last, back to the first (B; the wheel stops at the ends).
@(private="file")
brush_step :: proc(gs: ^Game_State, step: int, wrap := false) {
    b := &gs.build
    brushes := BRUSHES
    // Step k: 0 one block, 1 the box, k >= 2 a radius of brushes[k - 1].
    at := b.box ? 1 : 0
    for r, i in brushes { if i > 0 && r <= gs.brush_radius { at = i + 1 } }
    top := len(brushes)
    if gs.survival {
        top = 1
        for r, i in brushes { if i > 0 && r <= survival_spell_size { top = i + 1 } }
    }
    at = wrap ? cycle(at, top + 1, step) : clamp(at + step, 0, top)
    was_box := b.box
    b.box = at == 1
    gs.brush_radius = at <= 1 ? 0 : brushes[at - 1]
    if b.box != was_box { drag_cancel(gs) }
    if gs.survival { // creative shows it in the tool panel
        ui_toast(gs, b.box ? "Box: hold and drag to place or take many (B: one block)" : gs.brush_radius > 0 ? fmt.tprintf("Spell: radius %d", gs.brush_radius) : "One block at a time (B: box)", 1.6)
    }
}

// The mouse wheel while playing (up = +1): the hotbar, or sizes the current
// tool, by wheel_target.
build_wheel :: proc(gs: ^Game_State, steps: int, mods: Mods) {
    b := &gs.build
    if steps == 0 { return }
    if b.drag.on { // a box being dragged out: its depth, whatever's held
        drag_deepen(gs, steps)
        return
    }
    if b.drag.pending && mods - {.Shift} == {} { // a box waiting: push the face looked at, or move it
        drag_push(gs, steps, .Shift in mods)
        return
    }
    if gs.survival {
        if mods - {.Shift} == {} { hotbar_select(gs, cycle(gs.hotbar_slot, HOTBAR_SLOTS, -steps)) }
        return
    }
    switch wheel_target(b.tool, mods) {
    case .None:
    case .Hotbar: hotbar_select(gs, cycle(gs.hotbar_slot, HOTBAR_SLOTS, -steps)) // down = next
    case .Brush:  brush_step(gs, steps)
    case .Push:   area_push(gs, steps)
    case .Move:   area_move(gs, steps)
    case .Distance: b.air_dist = clamp(b.air_dist + steps, 2, MAX_AIR_DIST)
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
    active := gs.mouse_locked && !gs.glider.deployed && !gs.combat.fighting
    if !active {
        if b.drag.on { drag_cancel(gs) } // a box waiting stays (a look in the inventory)
        return
    }
    gs.edit_timer -= dt
    // Right click on a door swings it, whatever the tool (door.odin).
    if !gs.right_held { b.door_click = false }
    if gs.right_pressed {
        if p, ok := door_aimed(gs); ok {
            door_toggle(gs, p)
            b.door_click = true
        }
    }
    if b.door_click { return }
    if gs.survival {
        magic_build_update(gs, dt)
        return
    }
    switch b.tool {
    case .Magic: magic_build_update(gs, dt)
    case .Block: build_block_update(gs)
    case .Area:  build_area_update(gs)
    case .Shape: build_shape_update(gs)
    }
}

// Left breaks, right places, a block at a click (or the round brush, its
// radius set), holding repeating every EDIT_REPEAT seconds. With the box
// brush, holding and moving drags out a box instead, to set right and apply
// with another click (build_drag.odin). A stroke is one undo; torches are
// always one block.
@(private="file")
build_block_update :: proc(gs: ^Game_State) {
    if gs.build.box {
        d := &gs.build.drag
        switch drag_step(gs, REACH) {
        case .None, .Held, .Release, .Cancel:
        case .Press:
            if d.place && gs.selected_block == .Door {
                door_place(gs, d.hit, d.nrm) // doors go in one at a time (door.odin)
                drag_cancel(gs)
                return
            }
            build_apply(gs, sphere_region(d.start, 0), d.place ? gs.selected_block : .Air, .All)
        case .Confirm:
            if region_volume(drag_region(d)) > drag_limit(gs) {
                ui_toast(gs, "Too big: make it smaller", 1.2)
                return
            }
            // Placing fills only what's empty; one undo with the click's block.
            build_apply(gs, drag_region(d), d.place ? gs.selected_block : .Air, d.place ? .Air : .All, merge = true)
        }
        return
    }
    breaking := gs.left_pressed  || (gs.left_held  && gs.edit_timer <= 0)
    placing  := gs.right_pressed || (gs.right_held && gs.edit_timer <= 0)
    if !breaking && !placing { return }
    gs.edit_timer = EDIT_REPEAT
    hit, nrm, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), REACH, plants = true)
    if !ok { return }
    if !breaking && gs.selected_block == .Door {
        // Doors go in one at a time, on a click (door.odin).
        if gs.right_pressed { door_place(gs, hit, nrm) }
        return
    }
    target := hit
    block  := Block_Type.Air
    if !breaking {
        // On a plant: in its place, as on the ground it grows from.
        if !block_is_land_plant(u8(get_voxel(gs, hit.x, hit.y, hit.z))) { target = hit + nrm }
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

// A click sets a corner where the cursor is: left the first, right the
// other. With nothing selected either click starts a one-block box.
@(private="file")
build_area_update :: proc(gs: ^Game_State) {
    b := &gs.build
    if !gs.left_pressed && !gs.right_pressed { return }
    p, ok := area_cursor(gs)
    if !ok { return }
    if !b.selected {
        b.sel_a, b.sel_b, b.selected = p, p, true
    } else if gs.left_pressed {
        b.sel_a = p
    } else {
        b.sel_b = p
    }
}

// Where a corner would go: the block aimed at, the voxel in front of its
// face, or a point air_dist ahead (stopped in front of a nearer block).
area_cursor :: proc(gs: ^Game_State) -> ([3]int, bool) {
    b := &gs.build
    eye, fwd := camera_aim_eye(gs.camera), camera_forward(gs.camera)
    hit, nrm, ok := raycast_voxel(gs, eye, fwd, REACH)
    switch b.cursor {
    case .Block: return hit, ok
    case .Face:  return hit + nrm, ok
    case .Air:
        d := f32(b.air_dist)
        if ok && la.length([3]f32{f32(hit.x), f32(hit.y), f32(hit.z)} + 0.5 - eye) <= d { return hit + nrm, true }
        p := eye + fwd * d
        return {int(math.floor(p.x)), int(math.floor(p.y)), int(math.floor(p.z))}, true
    }
    return {}, false
}

// The selection's face the crosshair is on (box_face).
area_face :: proc(gs: ^Game_State) -> (axis, side: int) {
    r := area_region(&gs.build)
    return box_face(gs, r.lo, r.hi)
}

// The face of the box [lo_i, hi_i] the crosshair is on: the one the ray goes
// in by (from inside the box, out by); missing the box, the face toward the
// eye nearest the crosshair. Its axis, and side (+1 the high face, -1 the low).
box_face :: proc(gs: ^Game_State, lo_i, hi_i: [3]int) -> (axis, side: int) {
    lo := la.array_cast(lo_i, f32)
    hi := la.array_cast(hi_i, f32) + 1
    eye, fwd := camera_aim_eye(gs.camera), camera_forward(gs.camera)
    t_in, t_out := f32(-math.F32_MAX), f32(math.F32_MAX)
    ax_in, ax_out := 0, 0
    miss := false
    for i in 0 ..< 3 {
        if abs(fwd[i]) < 1e-6 {
            if eye[i] < lo[i] || eye[i] > hi[i] { miss = true }
            continue
        }
        t0, t1 := (lo[i] - eye[i]) / fwd[i], (hi[i] - eye[i]) / fwd[i]
        if t0 > t1 { t0, t1 = t1, t0 }
        if t0 > t_in  { t_in, ax_in = t0, i }
        if t1 < t_out { t_out, ax_out = t1, i }
    }
    if !miss && t_in <= t_out && t_out > 0 {
        if t_in > 0 { return ax_in, fwd[ax_in] > 0 ? -1 : 1 }
        return ax_out, fwd[ax_out] > 0 ? 1 : -1
    }
    best := -2 * f32(1)
    for i in 0 ..< 3 {
        for s in ([2]int{-1, 1}) {
            c := (lo + hi) / 2
            c[i] = s > 0 ? hi[i] : lo[i]
            if (eye[i] - c[i]) * f32(s) <= 0 { continue } // faces away
            if d := la.dot(la.normalize0(c - eye), fwd); d > best { best, axis, side = d, i, s }
        }
    }
    if best < -1 { axis, side = 1, 1 }
    return
}

// Pushes the face looked at out by `steps` (in when negative), never past
// the opposite face.
area_push :: proc(gs: ^Game_State, steps: int) {
    b := &gs.build
    if !b.selected { return }
    ax, side := area_face(gs)
    on_a := side > 0 ? b.sel_a[ax] > b.sel_b[ax] : b.sel_a[ax] < b.sel_b[ax]
    far, near := on_a ? &b.sel_a : &b.sel_b, on_a ? &b.sel_b : &b.sel_a
    far[ax] += side * steps
    far[ax] = side > 0 ? max(far[ax], near[ax]) : min(far[ax], near[ax])
}

// Moves the whole selection `steps` out through the face looked at.
area_move :: proc(gs: ^Game_State, steps: int) {
    b := &gs.build
    if !b.selected { return }
    ax, side := area_face(gs)
    b.sel_a[ax] += side * steps
    b.sel_b[ax] += side * steps
}

area_region :: proc(b: ^Build) -> Edit_Region {
    return {lo = la.min(b.sel_a, b.sel_b), hi = la.max(b.sel_a, b.sel_b), wall = b.wall}
}

// The shape under the crosshair. Placing, it sits on the face you look at;
// carving, it's centered on the voxel.
build_shape_target :: proc(gs: ^Game_State, place: bool) -> (Edit_Region, bool) {
    b := &gs.build
    hit, nrm, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), REACH)
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
// spare_hard: what the survival spell can't take yet stays (block_tier).
// Returns how many voxels changed.
build_apply :: proc(gs: ^Game_State, r: Edit_Region, block: Block_Type, mask: Build_Mask, merge := false, spare_hard := false) -> int {
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
    if block == .Door {
        ui_toast(gs, "Doors go in one at a time, with the Block tool", 1.5)
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
                    if mask == .Air && cur != 0 && cur != water && !block_is_land_plant(cur) { continue }
                    if mask == .Solid && !block_solid(cur) { continue }
                }
                if !into_player && aabb_hits_voxel(eye, p) { continue }
                if spare_hard && !spell_can_take(true, voxel_item(cur)) { continue } // survival's spell: too hard for it yet
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
    // A door goes whole, and with its ground (door.odin).
    orphans := make([dynamic][3]int, context.temp_allocator)
    door_orphans(gs, changed[:], &orphans)
    for q in orphans {
        col := gs.columns[{q.x >> 3, q.z >> 3}]
        if col == nil { continue }
        c := &col.chunks[chunk_y_index(q.y >> 3)]
        vi := (q.x & 7) + (q.y & 7) * CHUNK_VOXELS + (q.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS
        v := chunk_voxel(c, vi)
        if !block_is_door(v) || !chunk_set_voxel(c, vi, 0) { continue }
        dirty[ring_slot(q.x >> 3, q.y >> 3, q.z >> 3)] = true
        append(&changed, q)
        append(&rec.changes, Voxel_Change{{i32(q.x), i32(q.y), i32(q.z)}, v})
    }
    // Plants on ground that's gone go with it (roots with their ceiling).
    for i in 0 ..< len(changed) {
        p := changed[i]
        if block_solid(u8(get_voxel(gs, p.x, p.y, p.z))) { continue }
        q := p + {0, 1, 0}
        v := u8(get_voxel(gs, q.x, q.y, q.z))
        if v != u8(Block_Type.Roots) && u8(get_voxel(gs, p.x, p.y - 1, p.z)) == u8(Block_Type.Roots) {
            q, v = p - {0, 1, 0}, u8(Block_Type.Roots)
        }
        col := gs.columns[{q.x >> 3, q.z >> 3}]
        if !block_is_land_plant(v) || col == nil || q.y >= WORLD_Y_MAX { continue }
        c := &col.chunks[chunk_y_index(q.y >> 3)]
        if !chunk_set_voxel(c, (q.x & 7) + (q.y & 7) * CHUNK_VOXELS + (q.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS, 0) { continue }
        dirty[ring_slot(q.x >> 3, q.y >> 3, q.z >> 3)] = true
        append(&changed, q)
        append(&rec.changes, Voxel_Change{{i32(q.x), i32(q.y), i32(q.z)}, v})
    }
    if block == .Air { fill_dug_water(gs, changed[:]) }
    build_commit(gs, changed[:], dirty, change_olds(rec.changes[:]))
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

// Sets each of `pos` to its block of `blocks` (a door's two halves), and
// tells everyone. undo: kept for Ctrl+Z (placing a door); swinging one
// isn't. merge: one undo with the edit before (as build_apply's). Returns
// how many voxels changed.
build_set :: proc(gs: ^Game_State, pos: [][3]int, blocks: []u8, undo: bool, merge := false) -> int {
    rec: Edit_Record
    changed := make([dynamic][3]int, context.temp_allocator)
    olds := make([dynamic]u8, context.temp_allocator)
    dirty := make(map[int]bool, 4, context.temp_allocator)
    for p, i in pos {
        col := gs.columns[{p.x >> 3, p.z >> 3}]
        if col == nil || p.y < WORLD_Y_MIN || p.y >= WORLD_Y_MAX { continue }
        c := &col.chunks[chunk_y_index(p.y >> 3)]
        vi := (p.x & 7) + (p.y & 7) * CHUNK_VOXELS + (p.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS
        cur := chunk_voxel(c, vi)
        if !chunk_set_voxel(c, vi, blocks[i]) { continue }
        col.modified = true
        dirty[ring_slot(p.x >> 3, p.y >> 3, p.z >> 3)] = true
        append(&changed, p)
        append(&olds, cur)
        if undo { append(&rec.changes, Voxel_Change{{i32(p.x), i32(p.y), i32(p.z)}, cur}) }
    }
    if len(changed) == 0 { return 0 }
    build_commit(gs, changed[:], dirty, olds[:])
    if undo {
        b := &gs.build
        for &x in b.redo { delete(x.changes) }
        clear(&b.redo)
        if merge && b.stroke && len(b.undo) > 0 {
            last := &b.undo[len(b.undo) - 1]
            append(&last.changes, ..rec.changes[:])
            b.undo_voxels += len(rec.changes)
            delete(rec.changes)
            trim_undo(b)
        } else {
            push_record(b, &b.undo, rec)
        }
        b.stroke = true
    }
    return len(changed)
}

// Relight, re-upload and re-summarise after voxels changed, and tell the
// server (which passes the change on to the other players). olds: what each
// of `changed` was, for counting what's carried (items.odin).
@(private="file")
build_commit :: proc(gs: ^Game_State, changed: [][3]int, dirty: map[int]bool, olds: []u8, felled := false) {
    light_on_edit(gs, changed)
    for slot in dirty { gpu_sync_slot(gs, slot) }
    far_update_edited(gs, changed)
    client_send_voxels(gs, changed, client_items_predict(gs, changed, olds, felled))
}

// Clears every voxel of `pos` to air, as a felled tree leaves (no undo;
// counted as felled, items.odin):
// water beside them flows in, and everyone's told. How many changed.
world_clear :: proc(gs: ^Game_State, pos: [][3]int) -> int {
    changed := make([dynamic][3]int, 0, len(pos), context.temp_allocator)
    olds := make([dynamic]u8, 0, len(pos), context.temp_allocator)
    dirty := make(map[int]bool, 64, context.temp_allocator)
    for p in pos {
        col := gs.columns[{p.x >> 3, p.z >> 3}]
        if col == nil || p.y < WORLD_Y_MIN || p.y >= WORLD_Y_MAX { continue }
        c := &col.chunks[chunk_y_index(p.y >> 3)]
        vi := (p.x & 7) + (p.y & 7) * CHUNK_VOXELS + (p.z & 7) * CHUNK_VOXELS * CHUNK_VOXELS
        cur := chunk_voxel(c, vi)
        if !chunk_set_voxel(c, vi, 0) { continue }
        col.modified = true
        dirty[ring_slot(p.x >> 3, p.y >> 3, p.z >> 3)] = true
        append(&changed, p)
        append(&olds, cur)
    }
    if len(changed) == 0 { return 0 }
    fill_dug_water(gs, changed[:])
    build_commit(gs, changed[:], dirty, olds[:], felled = true)
    return len(changed)
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

// The old voxels of an edit record's changes, in order (temp).
@(private="file")
change_olds :: proc(changes: []Voxel_Change) -> []u8 {
    olds := make([]u8, len(changes), context.temp_allocator)
    for ch, i in changes { olds[i] = ch.old }
    return olds
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
    if len(changed) > 0 { build_commit(gs, changed[:], dirty, change_olds(back.changes[:])) }
    push_record(b, to, back)
    ui_toast(gs, fmt.tprintf("%s: %s blocks", verb, thousands(len(changed))), 1)
}

// ─── Preview ────────────────────────────────────────────────────────────────

// Line segments outlining what a click would do (world space), and whether
// it's a fill (else a clear). Empty if nothing is targeted.
Build_Preview :: struct {
    segs:     [dynamic][2][3]f32,
    carve:    [dynamic][2][3]f32, // shape: where a left click would carve, drawn faint
    cursor:   [dynamic][2][3]f32, // area: where a click would put a corner, faint
    face:     [dynamic][2][3]f32, // area: the face the wheel pushes, accented
    fill:     bool,
    too_big:  bool,
}

// Built in the temp allocator.
build_preview :: proc(gs: ^Game_State) -> (pv: Build_Preview) {
    pv.segs = make([dynamic][2][3]f32, context.temp_allocator)
    pv.carve = make([dynamic][2][3]f32, context.temp_allocator)
    pv.cursor = make([dynamic][2][3]f32, context.temp_allocator)
    pv.face = make([dynamic][2][3]f32, context.temp_allocator)
    b := &gs.build
    eye := gs.camera.pos
    switch gs.survival ? .Magic : b.tool {
    case .Magic, .Block:
        if !drag_showing(gs) {
            // The box brush, before a click: faintly, which way a box begun
            // here would lie (with the block outlined below).
            if b.box && !b.drag.on {
                reach := gs.survival || b.tool == .Magic ? MAGIC_REACH : REACH
                if hit, nrm, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), reach, plants = true); ok {
                    drag_hover_patch(gs, &pv.cursor, hit, nrm)
                }
            }
            break
        }
        // The box being dragged out.
        r := drag_region(&b.drag)
        lo := [3]f32{f32(r.lo.x), f32(r.lo.y), f32(r.lo.z)}
        hi := [3]f32{f32(r.hi.x), f32(r.hi.y), f32(r.hi.z)} + 1
        wire_box(&pv.segs, (lo + hi) / 2, (hi - lo) / 2 + 0.004, 1, 0)
        pv.fill = b.drag.place
        pv.too_big = region_volume(r) > drag_limit(gs) || (magic_active(gs) && gs.survival && magic_box_out_of_reach(gs, r)) // amber: the spell can't
        if b.drag.pending {
            ax, side := box_face(gs, r.lo, r.hi)
            face_marks(&pv.face, lo, hi, ax, side)
        }
        return
    case .Area, .Shape:
    }
    switch gs.survival ? .Magic : b.tool {
    case .Magic:
        // What the spell would take: the block, and the sphere round it.
        hit, _, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), MAGIC_REACH, plants = true)
        if !ok { return }
        lo := [3]f32{f32(hit.x), f32(hit.y), f32(hit.z)}
        wire_box(&pv.segs, lo + 0.5, {0.502, 0.502, 0.502}, 1, 0)
        if s := magic_spell_size(gs); s > 0 {
            r := f32(s) + 0.5
            wire_shape(&pv.segs, .Sphere, lo + 0.5, r, r, 1, 0, eye)
        }
    case .Block:
        hit, _, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), REACH, plants = true)
        if !ok { return }
        lo := [3]f32{f32(hit.x), f32(hit.y), f32(hit.z)}
        wire_box(&pv.segs, lo + 0.5, {0.502, 0.502, 0.502}, 1, 0)
        if gs.brush_radius > 0 {
            r := f32(gs.brush_radius) + 0.5
            wire_shape(&pv.segs, .Sphere, lo + 0.5, r, r, 1, 0, eye)
        }
    case .Area:
        // The selection, its walls and the face the wheel pushes; the cursor
        // faint beside it (on its own, it's the outline).
        pv.fill = true
        if c, ok := area_cursor(gs); ok {
            lo := [3]f32{f32(c.x), f32(c.y), f32(c.z)}
            wire_box(b.selected ? &pv.cursor : &pv.segs, lo + 0.5, {0.502, 0.502, 0.502}, 1, 0)
        }
        if !b.selected { return }
        r := area_region(b)
        pv.too_big = region_volume(r) > MAX_EDIT_VOXELS
        lo := [3]f32{f32(r.lo.x), f32(r.lo.y), f32(r.lo.z)}
        hi := [3]f32{f32(r.hi.x), f32(r.hi.y), f32(r.hi.z)} + 1
        wire_box(&pv.segs, (lo + hi) / 2, (hi - lo) / 2 + 0.002, 1, 0)
        if b.wall > 0 {
            inner := (hi - lo) / 2 - f32(b.wall)
            if inner.x > 0 && inner.y > 0 && inner.z > 0 { wire_box(&pv.segs, (lo + hi) / 2, inner, 1, 0) }
        }
        ax, side := area_face(gs)
        face_marks(&pv.face, lo, hi, ax, side)
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

// The face of box [lo, hi] (world, corners) the wheel pushes: a cross in an
// inset frame on it.
@(private="file")
face_marks :: proc(segs: ^[dynamic][2][3]f32, lo, hi: [3]f32, ax, side: int) {
    u, v := (ax + 1) % 3, (ax + 2) % 3
    inset := min(0.2, (hi[u] - lo[u]) / 4, (hi[v] - lo[v]) / 4)
    k: [4][3]f32
    for &q, i in k {
        q[ax] = (side > 0 ? hi[ax] : lo[ax]) + f32(side) * 0.01
        q[u] = (i == 1 || i == 2) ? hi[u] - inset : lo[u] + inset
        q[v] = i >= 2 ? hi[v] - inset : lo[v] + inset
    }
    for i in 0 ..< 4 { append(segs, [2][3]f32{k[i], k[(i + 1) % 4]}) }
    append(segs, [2][3]f32{k[0], k[2]}, [2][3]f32{k[1], k[3]})
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
