package main

// Dragging out a box: the Block tool and the spell, with the box brush (B).
// A click acts at once, on one block, as ever; holding the button and moving
// the crosshair to another block makes it a drag. Which way the box lies goes
// first by how you look (shown before the click: build_preview): down (or
// up) steeply, it's flat (a floor, a ceiling); more level, it stands up facing
// you (a wall), through the block clicked, and runs to the block aimed at.
// Tab (or Q) turns it the other way. The wheel (or Ctrl held and the mouse
// moved up and down, the view standing still) gives it depth: placing,
// toward you (a floor thickened upward); taking, away from you, into what
// it's cut from (a trench, a tunnel). Turned back past one layer it grows the
// other way instead (a wall reaching down past the ground it stands on, a
// slab dug up out of the floor).
// Letting go leaves it waiting, to look at from anywhere and set right: the
// wheel pushes the face you look at out or in, Shift+wheel moves the whole
// box, Tab turns it. A click of the button that made it applies it, the other
// button calls it off. Placing only fills what's empty (air, water, plants),
// so a floor doesn't eat the hill it runs into.

import "core:fmt"
import "core:math"
import la "core:math/linalg"

DRAG_MAX_SIDE      :: 64  // blocks along any edge
DRAG_MAX_SURVIVAL  :: 64  // blocks a spell can take or make at once, before upgrades (survival_spell_size)
DRAG_CTRL_PIXELS   :: 40  // Ctrl + mouse: this far up or down, a layer
DRAG_FLAT_SIN      :: 0.57 // looking down (or up) more steeply than ~35 degrees: the box lies flat

// How a box lies: flat (a floor or ceiling) or standing, facing you (a wall).
Drag_Lie :: enum u8 { Flat, Wall }

// The lie looking along `fwd`, and the box's thin way for it.
drag_view_lie :: proc(fwd: [3]f32) -> (lie: Drag_Lie, axis: int) {
    if abs(fwd.y) > DRAG_FLAT_SIN { return .Flat, 1 }
    return .Wall, abs(fwd.x) > abs(fwd.z) ? 0 : 2
}

Drag :: struct {
    on:      bool,
    place:   bool,   // right button: placing; left: taking
    start:   [3]int, // the first block (placing: the empty cell in front of the face)
    hit:     [3]int, // the block the click was on
    nrm:     [3]int, // that face's outward normal
    lie:     Drag_Lie,
    axis:    int,    // the box's thin way: 1 lying flat, 0 or 2 standing facing you
    dir:     int,    // +1 / -1 along `axis`: the way depth grows (placing: toward you; taking: away)
    plane:   f32,    // where the crosshair is read: the start's side the blocks rest on (placing) or you see (taking)
    end:     [3]int, // the far corner, in the start's layer
    depth:   int,    // layers along `dir` (1 is just the start's); negative: -depth layers the other way
    moved:   bool,   // the end has left the start: a drag, not a click
    pending: bool,   // let go: waiting to be set right and applied (or called off)
    rearm:   bool,   // start again where aimed while the button's still held (the spell, digging on)
    ctrl_dy: f32,    // Ctrl + mouse: pixels toward the next layer
}

Drag_Event :: enum u8 { None, Press, Held, Release, Confirm, Cancel }

// Once a frame from a tool: begins a drag on a click, follows the crosshair
// while it's held, and says when it's let go (waiting, if it was dragged),
// applied (a click on a waiting box) or called off.
drag_step :: proc(gs: ^Game_State, reach: f32) -> Drag_Event {
    d := &gs.build.drag
    if d.pending {
        mine  := d.place ? gs.right_pressed : gs.left_pressed
        other := d.place ? gs.left_pressed : gs.right_pressed
        if other {
            d.pending = false
            return .Cancel
        }
        if mine {
            d.pending = false
            return .Confirm
        }
        return .None
    }
    if d.on {
        held  := d.place ? gs.right_held : gs.left_held
        other := d.place ? gs.left_pressed : gs.right_pressed
        if other {
            d.on = false
            return .Cancel
        }
        drag_aim(gs, d, reach)
        if !held {
            d.on = false
            d.pending = d.moved
            return .Release
        }
        return .Held
    }
    rearmed := d.rearm && gs.left_held
    if !gs.left_held { d.rearm = false }
    if !gs.left_pressed && !gs.right_pressed && !rearmed { return .None }
    hit, nrm, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), reach, plants = true)
    if !ok { return .None }
    place := gs.right_pressed && !gs.left_pressed && !rearmed
    start := hit
    if place && !block_is_land_plant(u8(get_voxel(gs, hit.x, hit.y, hit.z))) { start = hit + nrm } // on a plant: in its place
    d^ = {on = true, place = place, start = start, hit = hit, nrm = nrm, end = start, depth = 1}
    // Its lie, by how you look now.
    fwd := camera_forward(gs.camera)
    lie, axis := drag_view_lie(fwd)
    drag_set_lie(d, lie, axis, fwd)
    return .Press
}

// Sets how the box lies: its thin way, the way depth grows (placing: toward
// you, taking: away), and the plane the crosshair is read on (the start's
// side the blocks rest on placing, the side you see taking).
@(private="file")
drag_set_lie :: proc(d: ^Drag, lie: Drag_Lie, axis: int, fwd: [3]f32) {
    d.lie, d.axis = lie, axis
    away := fwd[axis] > 0 ? 1 : -1
    d.dir = d.place ? -away : away
    near := f32(d.start[axis] + (away > 0 ? 0 : 1)) // the start's side toward you
    d.plane = d.place ? near + f32(away) : near
}

// Tab (or Q): a box being dragged or waiting turns the other way, about its
// first block: a floor's reach out from you becomes a wall's height (up
// placing, down into the ground taking), and back. True if there was one.
drag_turn :: proc(gs: ^Game_State) -> bool {
    d := &gs.build.drag
    if !d.on && !d.pending { return false }
    fwd := camera_forward(gs.camera)
    if d.lie == .Flat {
        face := abs(fwd.x) > abs(fwd.z) ? 0 : 2
        span := abs(d.end[face] - d.start[face])
        d.end[face] = d.start[face]
        d.end.y = d.start.y + (d.place ? span : -span)
        drag_set_lie(d, .Wall, face, fwd)
    } else {
        span := abs(d.end.y - d.start.y)
        away := fwd[d.axis] > 0 ? 1 : -1
        d.end.y = d.start.y
        d.end[d.axis] = d.start[d.axis] + span * away
        if fwd.y == 0 { fwd.y = -1 } // looking level: a floor, not a ceiling
        drag_set_lie(d, .Flat, 1, fwd)
    }
    d.moved = true
    return true
}

// The wheel on a waiting box: pushes the face you look at out (in when
// negative), never past the one opposite; with move, the whole box that way.
drag_push :: proc(gs: ^Game_State, steps: int, move: bool) {
    d := &gs.build.drag
    if !d.pending || steps == 0 { return }
    r := drag_region(d)
    lo, hi := r.lo, r.hi
    ax, side := box_face(gs, lo, hi)
    if move {
        lo[ax] += side * steps
        hi[ax] += side * steps
    } else if side > 0 {
        hi[ax] = clamp(hi[ax] + steps, lo[ax], lo[ax] + DRAG_MAX_SIDE - 1)
    } else {
        lo[ax] = clamp(lo[ax] - steps, hi[ax] - DRAG_MAX_SIDE + 1, hi[ax])
    }
    // Back into start, end and depth: the start at the corner nearest it was.
    for i in 0 ..< 3 {
        if i == d.axis { continue }
        near_lo := abs(d.start[i] - lo[i]) <= abs(d.start[i] - hi[i])
        d.start[i], d.end[i] = near_lo ? lo[i] : hi[i], near_lo ? hi[i] : lo[i]
    }
    layer := d.dir > 0 ? lo[d.axis] : hi[d.axis]
    d.start[d.axis], d.end[d.axis] = layer, layer
    d.depth = hi[d.axis] - lo[d.axis] + 1
}

// Ends the drag, and starts a new one where aimed next frame if the left
// button's still down (the spell, having unwoven a block, goes on to the next).
drag_rearm :: proc(gs: ^Game_State) {
    d := &gs.build.drag
    d.on, d.rearm = false, true
}

drag_cancel :: proc(gs: ^Game_State) {
    d := &gs.build.drag
    d.on, d.rearm, d.pending = false, false, false
}

// The far corner: where the crosshair meets the box's plane (missing it,
// the corner stays), at most DRAG_MAX_SIDE from the start.
@(private="file")
drag_aim :: proc(gs: ^Game_State, d: ^Drag, reach: f32) {
    ax := d.axis
    eye, fwd := camera_aim_eye(gs.camera), camera_forward(gs.camera)
    if abs(fwd[ax]) < 1e-4 { return }
    t := (d.plane - eye[ax]) / fwd[ax]
    if t <= 0 || t > reach * 2 { return }
    p := eye + fwd * t
    end := d.start
    for i in 0 ..< 3 {
        if i == ax { continue }
        end[i] = clamp(int(math.floor(p[i])), d.start[i] - DRAG_MAX_SIDE + 1, d.start[i] + DRAG_MAX_SIDE - 1)
    }
    d.end = end
    if end != d.start { d.moved = true }
}

// The box brush, before a click: a few cells lying the way a box begun here
// would (flat on the ground, or standing up from it), around the cell placing
// would start from; and which it is. Into `segs` (build_preview).
drag_hover_patch :: proc(gs: ^Game_State, segs: ^[dynamic][2][3]f32, hit, nrm: [3]int) -> Drag_Lie {
    lie, axis := drag_view_lie(camera_forward(gs.camera))
    c := la.array_cast(hit + nrm, f32) + 0.5
    if lie == .Flat {
        // 3 x 3 on the surface the blocks would rest on.
        y := f32(hit.y + nrm.y) + (nrm.y < 0 ? 1 : 0) // the cell's bottom (on a ceiling, its top)
        for i in 0 ..= 3 {
            k := f32(i) - 1.5
            append(segs, [2][3]f32{{c.x - 1.5, y, c.z + k}, {c.x + 1.5, y, c.z + k}})
            append(segs, [2][3]f32{{c.x + k, y, c.z - 1.5}, {c.x + k, y, c.z + 1.5}})
        }
    } else {
        // 3 wide and 3 up, standing on the cell, facing you.
        lat := 2 - axis
        for i in 0 ..= 3 {
            a, b, e, f: [3]f32 = c, c, c, c
            k := f32(i) - 1.5
            a[lat], a.y = c[lat] - 1.5, c.y - 0.5 + f32(i)
            b[lat], b.y = c[lat] + 1.5, c.y - 0.5 + f32(i)
            e[lat], e.y = c[lat] + k, c.y - 0.5
            f[lat], f.y = c[lat] + k, c.y + 2.5
            append(segs, [2][3]f32{a, b}, [2][3]f32{e, f})
        }
    }
    return lie
}

// Depth by `steps` layers (the wheel, or Ctrl + mouse).
drag_deepen :: proc(gs: ^Game_State, steps: int) {
    d := &gs.build.drag
    if !d.on { return }
    // 1, 2, 3 ... along `dir`; back past 1 it goes on the other way: -2, -3 ...
    // (both count the start's own layer: -2 is it and one beyond).
    for _ in 0 ..< abs(steps) {
        if steps > 0 {
            d.depth = d.depth == -2 ? 1 : d.depth + 1
        } else {
            d.depth = d.depth == 1 ? -2 : d.depth - 1
        }
    }
    d.depth = clamp(d.depth, -DRAG_MAX_SIDE, DRAG_MAX_SIDE)
    if steps != 0 { d.moved = true } // a click given depth is a drag too
}

// Ctrl held while dragging: the mouse's up and down give depth, and the
// view stands still (main). True if it took the mouse.
drag_mouse :: proc(gs: ^Game_State, ctrl: bool, dy: f32) -> bool {
    d := &gs.build.drag
    if !d.on || !ctrl {
        d.ctrl_dy = 0
        return false
    }
    d.ctrl_dy -= dy // up is more
    for d.ctrl_dy >= DRAG_CTRL_PIXELS { d.ctrl_dy -= DRAG_CTRL_PIXELS; drag_deepen(gs, 1) }
    for d.ctrl_dy <= -DRAG_CTRL_PIXELS { d.ctrl_dy += DRAG_CTRL_PIXELS; drag_deepen(gs, -1) }
    return true
}

// The box: start to end in the start's layer, `depth` layers along `dir`
// (or the other way).
drag_region :: proc(d: ^Drag) -> Edit_Region {
    far := d.end
    far[d.axis] = d.start[d.axis] + (d.depth > 0 ? d.dir * (d.depth - 1) : -d.dir * (-d.depth - 1))
    return {lo = la.min(d.start, far), hi = la.max(d.start, far)}
}

// The most a drag may cover: in survival, what the spell can handle.
drag_limit :: proc(gs: ^Game_State) -> int {
    if gs.survival { return DRAG_MAX_SURVIVAL * (1 + survival_spell_size) * (1 + survival_spell_size) }
    if magic_active(gs) { return 16 * 16 * 16 }
    return MAX_EDIT_VOXELS
}

// Whether there's a box to show: being dragged out, or waiting.
drag_showing :: proc(gs: ^Game_State) -> bool {
    d := &gs.build.drag
    return d.on && d.moved || d.pending
}

// What the box comes to, for beside the crosshair: which way it lies, its
// size, and what changes: the empty cells placing fills, the blocks taking
// takes. The spell adds what it costs (and in survival, if you're short of
// the block); a box too big to count just says how big.
drag_label :: proc(gs: ^Game_State) -> (s: string, too_big: bool) {
    d := &gs.build.drag
    r := drag_region(d)
    e := r.hi - r.lo + 1
    vol := region_volume(r)
    too_big = vol > drag_limit(gs)
    lie := d.lie == .Wall ? "wall" : (d.dir > 0) == d.place ? "floor" : "ceiling"
    dims := fmt.tprintf("%s  %d × %d × %d", lie, e.x, e.y, e.z)
    if too_big { return fmt.tprintf("%s: too big (at most %s)", dims, thousands(drag_limit(gs))), true }
    if vol > 16 * 16 * 16 { return fmt.tprintf("%s   %s blocks", dims, thousands(vol)), false }

    n := 0
    hardest, mana: f32
    for z in r.lo.z ..= r.hi.z { for y in r.lo.y ..= r.hi.y { for x in r.lo.x ..= r.hi.x {
        v := u8(get_voxel(gs, x, y, z))
        empty := v == 0 || block_is_watery(v) || block_is_land_plant(v)
        if d.place {
            if empty { n += 1 }
        } else if v != 0 && !block_is_watery(v) {
            n += 1
            t := unweave_time(Block_Type(v))
            hardest = max(hardest, t)
            mana += t * UNWEAVE_MANA
        }
    } } }
    verb := d.place ? "to fill" : "to take"
    if !magic_active(gs) { return fmt.tprintf("%s   %d %s", dims, n, verb), false }
    if d.place {
        if !gs.survival { return fmt.tprintf("%s   %d %s", dims, n, verb), false }
        have := int(items_shown(gs, gs.selected_block))
        short := have < n ? fmt.tprintf(", you have %d", have) : ""
        return fmt.tprintf("%s   %d %s, %d mana%s", dims, n, verb, int(f32(n) * CONJURE_MANA), short), false
    }
    secs := hardest * (1 + 0.45 * math.sqrt(f32(max(n - 1, 0)))) // as magic_begin reckons it
    if !gs.survival { return fmt.tprintf("%s   %d %s, %.1f s", dims, n, verb, secs), false }
    return fmt.tprintf("%s   %d %s, %.1f s, %d mana", dims, n, verb, secs, int(mana)), false
}
