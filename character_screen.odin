package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import clay "thirdparty/clay-odin"

// The Character screen (the pause menu's "Character"): what the player
// wears and their colouring (player_look.odin), picked while the view
// swings round in front of them to see it. Every change shows at once and
// goes to the server (others see it); the look is kept when the screen
// closes (LOOK_FILE). Drag the world to walk the view round them.

Portrait :: struct {
    k:          f32, // 0 the usual view .. 1 the portrait, eased
    orbit:      f32, // radians round from straight in front
    drag_x:     f32, // where a drag last was
    dragging:   bool,
    pitch:      f32, // the look's pitch before, given back after
    offset:     [3]f32, // the view's offset and turn at k = 1, as last worked out
    turn:       [2]f32,
}

PORTRAIT_ORBIT :: f32(0.5)  // the front quarter: the face, and the side
PORTRAIT_DIST  :: f32(2.8)  // design metres from the middle
PANEL_W        :: f32(430)

character_open :: proc(gs: ^Game_State) {
    p := &gs.ui.portrait
    if gs.ui.screen != .Character {
        p.pitch = gs.camera.pitch
        gs.camera.pitch = 0 // looking ahead: into the view
        p.orbit = PORTRAIT_ORBIT
    }
    ui_open(gs, .Character)
}

// Leaving the screen (ui_open): the look kept, the view given back.
character_closed :: proc(gs: ^Game_State) {
    gs.camera.pitch = gs.ui.portrait.pitch
    gs.ui.portrait.dragging = false
    look_save(gs.look)
}

// The view while the screen is open, and as it eases back: in front of
// the body, turned to look at it, the body to the right of the panel.
// After glider_view_update (it sets the usual view, which this blends from).
character_view_update :: proc(gs: ^Game_State, dt: f32) {
    p := &gs.ui.portrait
    open := gs.ui.screen == .Character
    p.k += ((open ? f32(1) : 0) - p.k) * min(dt * 6, 1)
    if !open && p.k < 0.002 {
        p.k = 0
        gs.camera.view_turn = {}
        return
    }
    cam := &gs.camera
    if open {
        gs.glider.chase_dist = max(gs.glider.chase_dist, 1.6) // the body seen, no first-person hands
        ws := world_scale
        yaw := gs.player_anim.body_yaw + p.orbit
        dir := [3]f32{-math.sin(yaw), 0, math.cos(yaw)}
        feet := cam.pos - [3]f32{0, PLAYER_EYE_HEIGHT, 0}
        target := feet + [3]f32{0, 1.0 * ws, 0}
        dist := PORTRAIT_DIST * ws
        if hit, _, ok := raycast_voxel(gs, target, la.normalize(dir + {0, 0.08, 0}), dist + 0.5); ok {
            c := [3]f32{f32(hit.x) + 0.5, f32(hit.y) + 0.5, f32(hit.z) + 0.5}
            dist = clamp(la.length(c - target) - 0.7, 0.6 * ws, dist)
        }
        eye := target + la.normalize(dir + {0, 0.08, 0}) * dist
        // Looking past the body to its left, so it stands clear of the panel.
        right := la.normalize(la.cross([3]f32{0, 1, 0}, -dir)) // the view's right, looking back at it
        look := la.normalize(target + right * (0.8 * ws) * (dist / (PORTRAIT_DIST * ws)) - eye)
        p.offset = eye - cam.pos - {0, cam.step_visual_offset, 0}
        p.turn = {
            wrap_degrees(math.to_degrees(math.atan2(look.x, look.z)) - cam.yaw),
            math.to_degrees(math.asin(clamp(look.y, -1, 1))) - cam.pitch,
        }
    }
    e := p.k * p.k * (3 - 2 * p.k)
    cam.view_offset = la.lerp(cam.view_offset, p.offset, e)
    cam.view_turn = p.turn * e
}

@(private="file")
wrap_degrees :: proc(a: f32) -> f32 {
    return math.mod(a + 540, 360) - 180
}

// ─── The panel ──────────────────────────────────────────────────────────────

character_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui
    p := &ui.portrait
    l := &gs.look
    before := l^
    panel := clay.ID("CharacterPanel")
    over_panel := clay.PointerOver(panel)
    // Dragging the world walks the view round.
    if ui.mouse_left_pressed && !over_panel { p.dragging, p.drag_x = true, ui.mouse_pos.x }
    if !ui.mouse_left_down { p.dragging = false }
    if p.dragging {
        p.orbit -= (ui.mouse_pos.x - p.drag_x) * 0.008
        p.drag_x = ui.mouse_pos.x
    }

    if clay.UI(panel)({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(18), childGap = 9, sizing = {clay.SizingFixed(PANEL_W), clay.SizingFit({max = max(ui.screen_h - 32, 200)})}},
        floating = {attachTo = .Root, offset = {16, 16}, zIndex = 20, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Capture},
        custom = deco(.Glass, radius = 12),
    }) {
        text("Character", COLOR_ACCENT, 26, FONT_ID_TITLE)
        body := clay.ID("CharacterBody")
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8}}) {
            if clay.UI(body)({
                layout = {layoutDirection = .TopToBottom, childGap = 9, sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                clip = {vertical = true, childOffset = clay.GetScrollOffset()},
            }) {
                // First: the presets keep it.
                pick_row("Body", "Body", {"Masculine", "Feminine"}, &l.body)
                heading("Start from")
                names: [len(LOOK_PRESETS)]string
                current := -1
                for preset, i in LOOK_PRESETS {
                    names[i] = preset.name
                    if look_apply_preset(l^, preset) == l^ { current = i }
                }
                if i := choice_grid("Preset", names[:], current, 4); i >= 0 { l^ = look_apply_preset(l^, LOOK_PRESETS[i]) }

                heading("Wearing")
                pick_row("Outfit", "Outfit", {"Robe", "Tunic", "Coat", "Padded"}, &l.outfit)
                pick_row("Back", "Over it", {"None", "Cape", "Cloak", "Scarf"}, &l.back)
                pick_row("Headwear", "On the head", {"Hood", "None", "Wizard", "Wide hat", "Circlet"}, &l.headwear)
                heading("Colours")
                dyes := dye_colors()
                swatch_row(gs, "Cloth", "Cloth", dyes[:], &l.cloth)
                swatch_row(gs, "Accent", "Accent", dyes[:], &l.accent)
                heading("You")
                pick_row("Hair", "Hair", {"Short", "Swept", "Long", "Tied", "Braid", "Bun", "Shaved"}, &l.hair)
                pick_row("Beard", "Beard", {"None", "Stubble", "Short", "Full"}, &l.beard)
                swatch_row(gs, "HairCol", "Hair colour", HAIR_COLORS[:], &l.hair_col)
                swatch_row(gs, "Skin", "Skin", SKINS[:], &l.skin)
            }
            scrollbar(gs, body)
        }
        divider()
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8, childAlignment = {y = .Center}}}) {
            text("Drag to look round", COLOR_TEXT_FAINT, 13)
            spacer()
            if button(clay.ID("CharacterDone"), "Done", width = 110) { ui_open(gs, .None) }
        }
    }
    if l^ != before { l^ = look_clean(l^) }
}

// Buttons in rows of `cols`, one selected; the clicked index or -1.
@(private="file")
choice_grid :: proc(id: string, labels: []string, selected, cols: int) -> int {
    clicked := -1
    if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
        for row := 0; row < len(labels); row += cols {
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
                for i in row ..< row + cols {
                    if i >= len(labels) {
                        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(28)}}}) {}
                    } else if button(clay.ID(id, u32(i)), labels[i], i == selected, height = 28) {
                        clicked = i
                    }
                }
            }
        }
    }
    return clicked
}

// A labelled row of choices for one of the look's enums (labels in its order).
@(private="file")
pick_row :: proc(id, label: string, labels: []string, value: ^$E) {
    if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 4}}) {
        text(label, COLOR_TEXT_DIM, 13)
        if i := choice_grid(id, labels, int(value^), len(labels) <= 4 ? 4 : 3); i >= 0 { value^ = E(i) }
    }
}

@(private="file")
dye_colors :: proc() -> (c: [len(DYES)][3]f32) {
    for d, i in DYES { c[i] = d.rgb }
    return
}

// A labelled row of colour squares, the chosen one framed.
@(private="file")
swatch_row :: proc(gs: ^Game_State, id, label: string, colors: [][3]f32, value: ^u8) {
    SIZE :: 34
    if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 4}}) {
        name := label
        if id == "Cloth" || id == "Accent" { name = fmt.tprintf("%s   %s", label, DYES[value^].name) }
        text(name, COLOR_TEXT_DIM, 13)
        per_row := 7
        for row := 0; row < len(colors); row += per_row {
            if clay.UI()({layout = {childGap = 5}}) {
                for i in row ..< min(row + per_row, len(colors)) {
                    sid := clay.ID(id, u32(i))
                    hov := clay.PointerOver(sid)
                    on := int(value^) == i
                    if clay.UI(sid)({
                        layout = {sizing = {clay.SizingFixed(SIZE), clay.SizingFixed(SIZE)}, childAlignment = {.Center, .Center}},
                        custom = deco(on ? .Slot_On : (hov ? .Slot_Hover : .Slot), radius = 5),
                    }) {
                        c := swatch_color(colors[i])
                        inner: f32 = on ? SIZE - 12 : SIZE - 8
                        if clay.UI()({layout = {sizing = {clay.SizingFixed(inner), clay.SizingFixed(inner)}}, backgroundColor = c, cornerRadius = clay.CornerRadiusAll(3)}) {}
                    }
                    if hov && gs_ui_left_pressed() {
                        value^ = u8(i)
                        play(.Click, 0.4)
                    }
                }
            }
        }
    }
}

// How a colour looks lit in the world (it shows brighter there than its
// albedo): what a swatch draws.
@(private="file")
swatch_color :: proc(c: [3]f32) -> clay.Color {
    k :: f32(1.45)
    return {min(c.r * k, 1) * 255, min(c.g * k, 1) * 255, min(c.b * k, 1) * 255, 255}
}
