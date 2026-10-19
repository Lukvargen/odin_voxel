package main

// The sound board (F4, debug): every one-shot on a button, played as the
// game would from a point in front of you (panned, through the cave's echo
// or the water around you), at a volume and pitch to taste; and the spell
// as it is heard unweaving a block: the whole sequence (loop, cracks, the
// break, the motes home) or its loop held at any point. The world goes on
// meanwhile; the panel sits to the side so it's still in view.

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import clay "thirdparty/clay-odin"

SOUND_BOARD_KINDS :: [5]Block_Type{.Leaves, .Dirt, .Log, .Stone, .Iron_Ore}

Sound_Board :: struct {
    volume, pitch, dist: f32, // the sliders, 0..1
    kind:  int,               // SOUND_BOARD_KINDS: what the spell works on
    size:  int,               // the spell's size
    prev:  Ui_Screen,         // the screen F4 came from (the sandbox's panel)
    // Holding the loop at a point.
    hold:  bool,
    frac:  f32,
    // Playing an unweave through: t seconds in of `need`; then the motes.
    run:        bool,
    t, need:    f32,
    next_crack: f32,
    stage:      int,
    motes:      int,  // still to arrive...
    next_mote:  f32,  // ...the next this many seconds after the break
    gap:        f32,
    pickup_run: int,
}

sound_board := Sound_Board{volume = 0.6, pitch = 0.5, dist = 0.2}

// F4: the board, and back to where it was opened from.
sound_board_toggle :: proc(gs: ^Game_State) {
    sb := &sound_board
    if gs.ui.screen == .Sounds {
        ui_open(gs, sb.prev)
        sb.hold, sb.run = false, false
    } else if gs.ui.screen == .None || gs.ui.screen == .Sandbox {
        sb.prev = gs.ui.screen
        ui_open(gs, .Sounds)
    }
}

// Where the board's sounds come from: `dist` voxels ahead (0: in your head).
@(private="file")
board_spot :: proc(gs: ^Game_State, at_least: f32 = 0) -> [3]f32 {
    return gs.camera.pos + camera_forward(gs.camera) * max(sound_board.dist * 30, at_least)
}

// The spell's sounds for this frame (the loop wants telling every frame:
// audio_spell). Called from the layout, once a frame while the board is open.
@(private="file")
board_update :: proc(gs: ^Game_State, dt: f32) {
    sb := &sound_board
    kinds := SOUND_BOARD_KINDS
    b := kinds[sb.kind]
    c := board_spot(gs, 4)
    if sb.hold { audio_spell(sb.frac, b, sb.size, false) }
    if sb.run {
        sb.t += dt
        if sb.t < sb.need {
            frac := sb.t / sb.need
            audio_spell(frac, b, sb.size, false)
            sb.next_crack -= dt
            if sb.next_crack <= 0 && spell_cracks(sb.need) { sb.next_crack = spell_crack(c, b, frac) }
            if st := crack_stage(frac); st > sb.stage {
                sb.stage = st
                if spell_cracks(sb.need) {
                    spell_crack_open(c, b, st)
                    sb.next_crack = max(sb.next_crack, 0.08)
                }
            }
        } else {
            sb.run = false
            p := la.array_cast(la.floor(c), int)
            audio.last_edit = -1 // not held back as a repeat (EDIT_SOUND_GAP)
            audio_edit(p, .Air, b, min(sb.size, 8))
            spell_break_sound(c, sb.size)
            // As magic_unweave's motes come home: up to 30, thrown out, then
            // drawn in over half a second or so.
            n := 1
            for dz in -sb.size ..= sb.size { for dy in -sb.size ..= sb.size { for dx in -sb.size ..= sb.size {
                if (dx != 0 || dy != 0 || dz != 0) && dx * dx + dy * dy + dz * dz <= sb.size * sb.size { n += 1 }
            } } }
            sb.motes, sb.next_mote = min(n, 30), 0.45
        }
    }
    sb.gap += dt
    if sb.motes > 0 {
        sb.next_mote -= dt
        if sb.next_mote <= 0 {
            pickup_sound(&sb.gap, &sb.pickup_run)
            sb.motes -= 1
            sb.next_mote = 0.055 * (1 + 0.6 * (1 - f32(sb.motes) / 30))
        }
    }
}

// Seconds unweaving takes, as magic_build_update reckons it: the hardest
// block sets the pace, more of them take longer.
@(private="file")
board_need :: proc(b: Block_Type, size: int) -> f32 {
    n := 0
    for dz in -size ..= size { for dy in -size ..= size { for dx in -size ..= size {
        if dx * dx + dy * dy + dz * dz <= size * size { n += 1 }
    } } }
    return unweave_time(b) * (1 + 0.45 * math.sqrt(f32(n - 1)))
}

sound_board_layout :: proc(gs: ^Game_State, dt: f32) {
    sb := &sound_board
    ui := &gs.ui
    board_update(gs, dt)
    if clay.UI(clay.ID("SoundBoard"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(16), childGap = 8,
            sizing = {clay.SizingFixed(min(600, ui.screen_w - 28)), clay.SizingFit({max = max(ui.screen_h - 28, 200)})}},
        floating = anchored(.RightCenter, {-14, 0}, 20),
        custom = deco(.Glass, radius = 12),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Bottom}}}) {
            text("Sound board", COLOR_ACCENT, 22, FONT_ID_TITLE)
            spacer()
            text(fmt.tprintf("F4 to close   echo %.2f  under water %.2f", audio.echo, audio.under), COLOR_TEXT_DIM, 13)
        }
        volume := sb.volume * 1.5
        pitch := math.pow(2, sb.pitch * 2 - 1)
        dist := sb.dist * 30
        if clay.UI()(setting_row()) {
            row_label("Volume")
            slider(gs, clay.ID("SbVolume"), &sb.volume, fmt.tprintf("%.2f", volume))
        }
        if clay.UI()(setting_row()) {
            row_label("Pitch")
            slider(gs, clay.ID("SbPitch"), &sb.pitch, fmt.tprintf("%.2f", pitch))
        }
        if clay.UI()(setting_row()) {
            row_label("Distance")
            slider(gs, clay.ID("SbDist"), &sb.dist, dist < 0.5 ? "head" : fmt.tprintf("%.0f", dist))
        }
        divider()

        // The spell.
        heading("Spell")
        kinds := SOUND_BOARD_KINDS
        if clay.UI()(setting_row()) {
            row_label("Block")
            names := make([]string, len(kinds), context.temp_allocator)
            for k, i in kinds { names[i] = block_name(k) }
            if i := segmented("SbKind", names, sb.kind); i >= 0 { sb.kind = i }
        }
        if clay.UI()(setting_row()) {
            row_label("Size")
            if i := segmented("SbSize", {"0", "1", "2", "3"}, sb.size); i >= 0 { sb.size = i }
        }
        if clay.UI()(setting_row()) {
            row_label("Progress")
            slider(gs, clay.ID("SbFrac"), &sb.frac, fmt.tprintf("%d%%", int(sb.frac * 100 + 0.5)))
        }
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 6}}) {
            need := board_need(kinds[sb.kind], sb.size)
            if button(clay.ID("SbUnweave"), sb.run ? "Unweaving..." : fmt.tprintf("Unweave (%.2f s)", need), sb.run) {
                sb.run, sb.t, sb.need, sb.next_crack, sb.stage, sb.hold, sb.motes = true, 0, need, 0.15, 0, false, 0
            }
            if button(clay.ID("SbHold"), "Hold the loop", sb.hold) { sb.hold, sb.run = !sb.hold, false }
            if button(clay.ID("SbPickups"), "Pickup run") { sb.motes, sb.next_mote = 8, 0 }
        }
        divider()

        // Every one-shot. They scroll when the window is too short for them.
        heading("One-shots")
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8}}) {
            body := clay.ID("SbBody")
            if clay.UI(body)({
                layout = {layoutDirection = .TopToBottom, childGap = 4, sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                clip = {vertical = true, childOffset = clay.GetScrollOffset()},
            }) {
                PER_ROW :: 4
                for row := 0; row * PER_ROW < len(Sound); row += 1 {
                    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 4}}) {
                        for i in row * PER_ROW ..< min((row + 1) * PER_ROW, len(Sound)) {
                            s := Sound(i)
                            if board_button(clay.ID("SbSound", u32(i)), fmt.tprintf("%v", s)) {
                                if dist < 0.5 {
                                    play(s, volume, pitch)
                                } else {
                                    play_at(s, board_spot(gs), volume, pitch)
                                }
                            }
                        }
                    }
                }
            }
            scrollbar(gs, body)
        }
    }
}

// A small button that doesn't click when pressed (the click would play over
// the sound being tried).
@(private="file")
board_button :: proc(id: clay.ElementId, label: string) -> bool {
    hovered := clay.PointerOver(id)
    if clay.UI(id)({
        layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(26)}, padding = {6, 6, 0, 0}, childAlignment = {x = .Center, y = .Center}},
        custom = deco(hovered ? .Button_Hover : .Button, radius = 6),
    }) {
        text(label, COLOR_TEXT, 13)
    }
    return hovered && gs_ui_left_pressed()
}
