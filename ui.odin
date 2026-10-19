package main

// Clay UI over the ray-traced frame, kept clean and out of the way (the look
// of the gamejam project): flat dark panels with a hairline border, rounded
// corners, one accent colour; no gradients, glows or shadows.
//
// While playing there's little on screen: the crosshair and target outline,
// the hotbar (the weapon bar while fighting), toasts, the biome's name for a
// moment when you enter one, health only while hurt, and damage numbers over
// what you hit. Gliding, nothing but where you're steering while looking
// around (the flight shows in the world). The controls card on H, the debug
// panel on F3; F1 hides it all.
// Screens: the pause menu (Esc) with graphics / sound / controls tabs, the
// block picker (E), and in the entity sandbox its panel (Tab, sandbox.odin).
// Before a world is open, the main menu (main_menu.odin).

import "core:c"
import "core:fmt"
import "core:math"
import la "core:math/linalg"
import "core:strings"
import "base:runtime"
import SDL "vendor:sdl3"
import TTF "vendor:sdl3/ttf"
import clay "thirdparty/clay-odin"

FONT_ID_BODY  :: 0
FONT_ID_TITLE :: 1

HELP_STARTUP_SECONDS :: 8  // "H for controls" shows this long at startup
BIOME_SECONDS        :: 3.5 // a biome's name shows this long on entering it
TOAST_SECONDS        :: 1.8
BLOCK_NAME_SECONDS   :: 1.6

Ui_Screen :: enum u8 { None, Pause, Inventory, Sandbox, Character, Sounds } // Sandbox: its panel (sandbox.odin); Character: character_screen.odin; Sounds: sound_board.odin
Menu_Tab  :: enum u8 { Graphics, Sound, Controls, Multiplayer }

// A one-line text box's contents (text_field).
Text_Field :: struct {
    buf:    [TEXT_MAX]u8,
    len:    int,
    submit: bool, // Enter was pressed in it
}

UI_State :: struct {
    renderer_data: Clay_SDL3RendererData,
    out_tex:       ^SDL.Texture,
    clay_memory:   [^]u8,
    initialized:   bool,

    screen:         Ui_Screen,
    menu_tab:       Menu_Tab,
    quit_requested: bool, // "Save and quit" in the menu
    menu_requested: bool, // "Main menu": the same, then the game starts again at the main menu (main_menu.odin)
    menu_note:      string, // ...saying why, there (a game joined from the menu ended)
    typing:         ^Text_Field, // the text box keys go to, nil if none
    field_hovered:  bool,        // a text box is under the pointer this frame
    join_field:     Text_Field,  // Multiplayer tab: address to join...
    port_field:     Text_Field,  // ...port to host on...
    name_field:     Text_Field,  // ...and what you're called (client_name)
    portrait:       Portrait,    // the Character screen's view (character_screen.odin)
    chat_field:     Text_Field,  // the chat line being typed (Enter)
    debug_open:     bool, // F3
    hud_hidden:     bool, // F1
    help_open:      bool, // H
    help_t:         f32,  // seconds left of the startup "H for controls" hint

    // Pointer state, fed to Clay each frame.
    mouse_pos:          [2]f32,
    mouse_left_down:    bool,
    mouse_left_pressed: bool, // single-frame edge
    dragging:           u32,  // id of the slider (or scrollbar) being dragged, 0 if none
    drag_grab:          f32,  // where on the scrollbar's thumb it was taken
    wheel:              f32,  // this frame's mouse wheel, while the pointer is free (scrolls)

    toast_buf:    [96]u8,
    toast_len:    int,
    toast_t:      f32,
    block_name_t: f32,
    prev_block:   Block_Type,
    prev_slot:    int,
    weapon_name_t: f32, // the weapon in hand's name over the weapon bar, as for blocks
    prev_weapon:  Weapon,
    biome:        Biome,
    biome_timer:  f32,
    biome_shown:  Biome, // the name on screen...
    biome_t:      f32,   // ...for this much longer
    biome_seen:   bool,

    screen_w, screen_h: f32, // this frame's layout size

    // FPS smoothing (rolling 60-frame avg).
    frame_times: [60]f32,
    frame_idx:   int,
    fps:         f32,
    frame_ms:    f32,
}

// ─── Theme ─────────────────────────────────────────────────────────────────

// Colors are 0..255 floats: the Clay SDL3 renderer divides by 255.
// The world's own: dark warm stone and wood for panels, parchment text,
// late-afternoon sunlight for the accent, leaf green and ember red.
// Shapes are blocky to match (UI_RADIUS), buttons bevelled like a block's
// lit top edge (bevel).
COLOR_TEXT       :: clay.Color{238, 230, 212, 255}
COLOR_TEXT_DIM   :: clay.Color{178, 168, 150, 255}
COLOR_TEXT_FAINT :: clay.Color{178, 168, 150, 150}
COLOR_ACCENT     :: clay.Color{244, 196, 98, 255}
COLOR_ACCENT_2   :: clay.Color{236, 140, 76, 255}
COLOR_ON_ACCENT  :: clay.Color{34, 26, 16, 255}
COLOR_GOOD       :: clay.Color{150, 204, 110, 255}
COLOR_BAD        :: clay.Color{232, 100, 82, 255}
COLOR_SKY        :: clay.Color{124, 182, 236, 255}
COLOR_BAR_BG     :: clay.Color{44, 39, 34, 255}
COLOR_RULE       :: clay.Color{92, 82, 68, 255}

COLOR_PANEL        :: clay.Color{27, 24, 21, 228}
COLOR_PANEL_SOFT   :: clay.Color{27, 24, 21, 176}
COLOR_PANEL_BORDER :: clay.Color{78, 69, 58, 255}
COLOR_BUTTON       :: clay.Color{56, 50, 44, 255}
COLOR_BUTTON_HOVER :: clay.Color{82, 73, 62, 255}
COLOR_SLOT         :: clay.Color{14, 12, 10, 160}
COLOR_SHADE        :: clay.Color{14, 12, 10, 255} // dark backing for HUD labels and bars (fade its alpha)

UI_RADIUS :: f32(3) // corners: no rounder than this, whatever's asked

// Clay's complaints, the first few: one that repeats every frame (or in a
// loop) would otherwise fill the disk through a tester's log.txt.
CLAY_ERRORS_SHOWN :: 20

@(private="file")
clay_errors: int

ui_error_handler :: proc "c" (errorData: clay.ErrorData) {
    context = runtime.default_context()
    clay_errors += 1
    if clay_errors > CLAY_ERRORS_SHOWN { return }
    msg := string(errorData.errorText.chars[:errorData.errorText.length])
    fmt.println("Clay error:", errorData.errorType, msg)
    if clay_errors == CLAY_ERRORS_SHOWN { fmt.println("Clay error: (no more of these)") }
}

ui_measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, userData: rawptr) -> clay.Dimensions {
    fonts := (^[dynamic]^TTF.Font)(userData)
    if fonts == nil || int(config.fontId) >= len(fonts^) { return {} }
    font := fonts^[config.fontId]
    if font == nil { return {} }
    w, h: i32
    TTF.SetFontSize(font, f32(config.fontSize))
    if !TTF.GetStringSize(font, text.chars, uint(text.length), &w, &h) {
        return {}
    }
    return clay.Dimensions{f32(w), f32(h)}
}

ui_load_font :: proc(ui: ^UI_State, fontId: u16, fontSize: u16, path: cstring) {
    assign_at(&ui.renderer_data.fonts, fontId, TTF.OpenFont(path, f32(fontSize)))
}

ui_init :: proc(gs: ^Game_State) {
    ui := &gs.ui
    gs_ui_left_pressed_state = ui
    assert(TTF.Init(), "TTF.Init failed")

    ui.renderer_data.renderer = SDL.CreateGPURenderer(gs.gpu_device, gs.window)
    if ui.renderer_data.renderer == nil {
        fmt.eprintln("CreateGPURenderer failed:", SDL.GetError())
        return
    }
    SDL.SetRenderVSync(ui.renderer_data.renderer, 1)

    ui.renderer_data.textEngine = TTF.CreateRendererTextEngine(ui.renderer_data.renderer)
    assert(ui.renderer_data.textEngine != nil, "TTF.CreateRendererTextEngine failed")

    ui_load_font(ui, FONT_ID_BODY,  16, "resources/Roboto.ttf")
    ui_load_font(ui, FONT_ID_TITLE, 22, "resources/Roboto.ttf")
    if f := ui.renderer_data.fonts[FONT_ID_TITLE]; f != nil { TTF.SetFontStyle(f, {.BOLD}) }

    // Wrap the compute-output GPU texture as an SDL.Texture so the Renderer
    // can sample it as a fullscreen quad each frame. Lives in its own proc so
    // gpu_fit_render_size can rebuild it when the render resolution changes.
    ui_rewrap_out_texture(gs)

    clay.SetMaxElementCount(8192)
    sz: c.size_t = c.size_t(clay.MinMemorySize())
    ui.clay_memory = make([^]u8, sz)
    arena := clay.CreateArenaWithCapacityAndMemory(sz, ui.clay_memory)

    w, h: i32
    SDL.GetWindowSize(gs.window, &w, &h)
    clay.Initialize(arena, {f32(w), f32(h)}, {handler = ui_error_handler})
    clay.SetMeasureTextFunction(ui_measure_text, &ui.renderer_data.fonts)

    ui.help_t = HELP_STARTUP_SECONDS
    ui.prev_block, ui.prev_slot = gs.selected_block, gs.hotbar_slot
    ui.biome = terrain_at(int(gs.camera.pos.x), int(gs.camera.pos.z)).biome
    ui.initialized = true
}

// (Re)wrap the GPU out_texture as an SDL.Texture sized to the current render
// resolution, upscaled nearest-neighbor (crisp pixel-art look) or linearly
// (gs.upscale_smooth). Destroys any previous wrap first, so this is safe to
// call after gpu_fit_render_size recreates out_texture.
ui_rewrap_out_texture :: proc(gs: ^Game_State) {
    ui := &gs.ui
    if ui.out_tex != nil {
        SDL.DestroyTexture(ui.out_tex)
        ui.out_tex = nil
    }
    if gs.out_texture == nil { return } // the main menu: nothing traced yet
    props := SDL.CreateProperties()
    SDL.SetPointerProperty(props, SDL.PROP_TEXTURE_CREATE_GPU_TEXTURE_POINTER, gs.out_texture)
    SDL.SetNumberProperty(props, SDL.PROP_TEXTURE_CREATE_ACCESS_NUMBER, i64(SDL.TextureAccess.STATIC))
    SDL.SetNumberProperty(props, SDL.PROP_TEXTURE_CREATE_WIDTH_NUMBER,  i64(gs.render_w))
    SDL.SetNumberProperty(props, SDL.PROP_TEXTURE_CREATE_HEIGHT_NUMBER, i64(gs.render_h))
    ui.out_tex = SDL.CreateTextureWithProperties(ui.renderer_data.renderer, props)
    SDL.DestroyProperties(props)
    if ui.out_tex == nil {
        fmt.eprintln("CreateTextureWithProperties(gpu_texture) failed:", SDL.GetError())
    } else {
        SDL.SetTextureScaleMode(ui.out_tex, gs.upscale_smooth ? .LINEAR : .NEAREST)
    }
}

ui_shutdown :: proc(gs: ^Game_State) {
    ui := &gs.ui
    if !ui.initialized { return }
    if ui.out_tex != nil { SDL.DestroyTexture(ui.out_tex) }
    for f in ui.renderer_data.fonts { if f != nil { TTF.CloseFont(f) } }
    delete(ui.renderer_data.fonts)
    if ui.renderer_data.textEngine != nil { TTF.DestroyRendererTextEngine(ui.renderer_data.textEngine) }
    if ui.renderer_data.renderer != nil { SDL.DestroyRenderer(ui.renderer_data.renderer) }
    TTF.Quit()
}

// A short message in the middle of the screen ("Brush: radius 3", "Sound muted", ...).
ui_toast :: proc(gs: ^Game_State, text: string, seconds: f32 = TOAST_SECONDS) {
    ui := &gs.ui
    ui.toast_len = copy(ui.toast_buf[:], text)
    ui.toast_t = seconds
}

// Shows a screen (.None = back to playing); the mouse is free on screens.
ui_open :: proc(gs: ^Game_State, screen: Ui_Screen) {
    ui_type_into(gs, nil)
    if gs.ui.screen == .Character && screen != .Character { character_closed(gs) }
    gs.ui.screen = screen
    gs.ui.dragging = 0
    gs.mouse_locked = screen == .None
    gs.left_held, gs.right_held = false, false
    _ = SDL.SetWindowRelativeMouseMode(gs.window, gs.mouse_locked)
}

// Typing goes to text box f (nil: back to keys doing their usual things).
ui_type_into :: proc(gs: ^Game_State, f: ^Text_Field) {
    if gs.ui.typing == f { return }
    gs.ui.typing = f
    if f != nil { _ = SDL.StartTextInput(gs.window) } else { _ = SDL.StopTextInput(gs.window) }
}

// Typed text for the text box being typed in: printable ASCII only (it's
// for addresses and numbers), as much as fits.
ui_type_text :: proc(gs: ^Game_State, s: string) {
    f := gs.ui.typing
    if f == nil { return }
    for c in transmute([]u8)s {
        if c < 0x20 || c > 0x7e || f.len >= len(f.buf) { continue }
        f.buf[f.len] = c
        f.len += 1
    }
}

// A key while typing: Backspace, Enter (submit), Esc (stop typing), Ctrl+V.
// Every other key is the text box's too, so none reaches the game.
ui_type_key :: proc(gs: ^Game_State, key: SDL.Keycode, mods: Mods) {
    f := gs.ui.typing
    switch key {
    case SDL.K_BACKSPACE:
        if .Ctrl in mods { f.len = 0 } else { f.len = max(f.len - 1, 0) }
    case SDL.K_RETURN, SDL.K_KP_ENTER:
        f.submit = true
    case SDL.K_ESCAPE:
        ui_type_into(gs, nil)
    case SDL.K_V:
        if .Ctrl in mods {
            if clip := SDL.GetClipboardText(); clip != nil {
                ui_type_text(gs, string(cstring(clip)))
                SDL.free(clip)
            }
        }
    }
}

// Enter while playing: type a chat line (chat_layout sends it).
ui_open_chat :: proc(gs: ^Game_State) {
    gs.ui.chat_field.len = 0
    ui_type_into(gs, &gs.ui.chat_field)
}

// Esc: open the pause menu, or close whatever screen is open (the
// Character screen back to the menu it was opened from).
ui_back :: proc(gs: ^Game_State) {
    #partial switch gs.ui.screen {
    case .None:      ui_open(gs, .Pause)
    case .Character: ui_open(gs, .Pause)
    case .Sounds:    sound_board_toggle(gs)
    case:            ui_open(gs, .None)
    }
}

ui_build_and_render :: proc(gs: ^Game_State, dt: f32) {
    ui := &gs.ui
    if !ui.initialized || ui.renderer_data.renderer == nil { return }
    ui_draw(gs, dt)
    SDL.RenderPresent(ui.renderer_data.renderer)
}

// Lays out and draws the frame and the UI to the current render target.
ui_draw :: proc(gs: ^Game_State, dt: f32) {
    ui := &gs.ui

    // Smoothed FPS / frame time.
    ui.frame_times[ui.frame_idx] = dt
    ui.frame_idx = (ui.frame_idx + 1) % len(ui.frame_times)
    sum: f32 = 0
    for v in ui.frame_times { sum += v }
    avg := max(sum / f32(len(ui.frame_times)), 0.0001)
    ui.fps      = 1.0 / avg
    ui.frame_ms = avg * 1000.0

    // Timers.
    ui.toast_t      = max(ui.toast_t - dt, 0)
    ui.block_name_t = max(ui.block_name_t - dt, 0)
    ui.weapon_name_t = max(ui.weapon_name_t - dt, 0)
    if gs.combat.weapon != ui.prev_weapon {
        ui.prev_weapon = gs.combat.weapon
        ui.weapon_name_t = BLOCK_NAME_SECONDS
    }
    ui.help_t       = max(ui.help_t - dt, 0)
    if gs.selected_block != ui.prev_block || gs.hotbar_slot != ui.prev_slot {
        ui.prev_block, ui.prev_slot = gs.selected_block, gs.hotbar_slot
        ui.block_name_t = BLOCK_NAME_SECONDS
    }
    ui.biome_timer -= dt
    if ui.biome_timer <= 0 {
        ui.biome = terrain_at(int(math.floor(gs.camera.pos.x)), int(math.floor(gs.camera.pos.z))).biome
        ui.biome_timer = 0.5
        if !ui.biome_seen || ui.biome != ui.biome_shown {
            ui.biome_shown, ui.biome_seen = ui.biome, true
            ui.biome_t = BIOME_SECONDS
        }
    }
    ui.biome_t = max(ui.biome_t - dt, 0)

    w, h: i32
    SDL.GetWindowSize(gs.window, &w, &h)
    if target, ok := SDL.GetRenderTarget(ui.renderer_data.renderer).?; ok && target != nil {
        // Offscreen (bench ui): lay out for the target's size.
        tw, th: f32
        _ = SDL.GetTextureSize(target, &tw, &th)
        w, h = i32(tw), i32(th)
    }
    fw, fh := f32(w), f32(h)
    ui.screen_w, ui.screen_h = fw, fh
    clay.SetLayoutDimensions({fw, fh})
    clay.SetPointerState(transmute(clay.Vector2)ui.mouse_pos, ui.mouse_left_down)
    clay.UpdateScrollContainers(false, {0, ui.wheel * 40}, dt)
    ui.wheel = 0

    clay.BeginLayout()
    if (!ui.hud_hidden || ui.screen != .None) && ui.screen != .Character {
        hud_layout(gs, fw, fh)
        glider_hud_layout(gs, fw, fh)
    }
    switch ui.screen {
    case .None:
    case .Pause:     menu_layout(gs)
    case .Inventory: inventory_layout(gs)
    case .Sandbox:   // drawn by sandbox_layout
    case .Character: character_layout(gs)
    case .Sounds:    sound_board_layout(gs, dt)
    }
    if gs.sandbox.on { sandbox_layout(gs, fw, fh) }
    cmds := clay.EndLayout()

    r := ui.renderer_data.renderer
    SDL.SetRenderDrawColor(r, 0, 0, 0, 255)
    SDL.RenderClear(r)
    if ui.out_tex != nil {
        SDL.RenderTexture(r, ui.out_tex, nil, nil)
    }
    if ui.screen == .None && !ui.hud_hidden && !gs.combat.fighting { draw_target_outline(gs, fw, fh) }
    SDL_Clay_RenderClayCommands(&ui.renderer_data, &cmds)

    // Consume single-frame edges.
    ui.mouse_left_pressed = false
}

// ─── Drawing the theme (custom elements) ───────────────────────────────────

// What a custom element draws behind its children (ui_draw_custom).
Ui_Deco :: enum u8 {
    Block_Icon,
    Weapon_Icon,  // a weapon, or fists (.None), as a little picture
    Glass,        // a panel: flat, a hairline border
    Glass_Soft,   // the same, more see-through (HUD cards)
    Button, Button_Hover, Button_On, Button_On_Hover,
    Slot, Slot_Hover, Slot_On,
    Tooltip,
    Shape_Icon, Shape_Icon_On, // a building shape's outline (build HUD)
    Backdrop,                  // the main menu's views of the world (main_menu.odin)
    Menu_Item, Menu_Item_Hover, Menu_Item_On, // the main menu's buttons and rows
}

Ui_Custom :: struct {
    deco:   Ui_Deco,
    block:  Block_Type,
    weapon: Weapon,
    radius: f32,
    alpha:  f32, // fades the whole thing
    shape:  Build_Shape,
}

deco :: proc(d: Ui_Deco, block := Block_Type.Air, radius: f32 = 8, alpha: f32 = 1, shape := Build_Shape.Sphere, weapon := Weapon.None) -> clay.CustomElementConfig {
    p := new(Ui_Custom, context.temp_allocator)
    p^ = {deco = d, block = block, weapon = weapon, radius = radius, alpha = alpha, shape = shape}
    return {customData = p}
}

@(private="file")
fcol :: proc(col: clay.Color, a: f32 = 1) -> SDL.FColor {
    return {col.r / 255, col.g / 255, col.b / 255, col.a / 255 * a}
}

// A filled rounded rectangle: a triangle fan from the centre round the
// corners (top and bottom colours blend by height; the theme passes one).
@(private="file")
round_rect :: proc(r: ^SDL.Renderer, rect: SDL.FRect, radius: f32, top, bottom: SDL.FColor) {
    SEG :: 6
    rad := max(min(radius, rect.w / 2, rect.h / 2), 0)
    verts: [2 + 4 * (SEG + 1)]SDL.Vertex
    idx: [3 * 4 * (SEG + 1)]c.int
    color_at :: proc(y: f32, rect: SDL.FRect, top, bottom: SDL.FColor) -> SDL.FColor {
        t := clamp((y - rect.y) / max(rect.h, 1), 0, 1)
        return {
            top.r + (bottom.r - top.r) * t, top.g + (bottom.g - top.g) * t,
            top.b + (bottom.b - top.b) * t, top.a + (bottom.a - top.a) * t,
        }
    }
    centre := [2]f32{rect.x + rect.w / 2, rect.y + rect.h / 2}
    verts[0] = {position = {centre.x, centre.y}, color = color_at(centre.y, rect, top, bottom)}
    n := 1
    corners := [4][2]f32{
        {rect.x + rect.w - rad, rect.y + rect.h - rad}, // bottom right, angles 0..90
        {rect.x + rad, rect.y + rect.h - rad},          // bottom left
        {rect.x + rad, rect.y + rad},                   // top left
        {rect.x + rect.w - rad, rect.y + rad},          // top right
    }
    for k in 0 ..< 4 {
        for s in 0 ..= SEG {
            a := (f32(k) + f32(s) / SEG) * math.PI / 2
            p := corners[k] + [2]f32{math.cos(a), math.sin(a)} * rad
            verts[n] = {position = {p.x, p.y}, color = color_at(p.y, rect, top, bottom)}
            n += 1
        }
    }
    verts[n] = verts[1] // close the fan
    n += 1
    ni := 0
    for i in 1 ..< n - 1 {
        idx[ni], idx[ni + 1], idx[ni + 2] = 0, c.int(i), c.int(i + 1)
        ni += 3
    }
    SDL.RenderGeometry(r, nil, &verts[0], c.int(n), &idx[0], c.int(ni))
}

@(private="file")
inset :: proc(rect: SDL.FRect, d: f32) -> SDL.FRect {
    return {rect.x + d, rect.y + d, rect.w - 2 * d, rect.h - 2 * d}
}

// Flat fill inside a border `width` thick (0: no border).
@(private="file")
flat :: proc(r: ^SDL.Renderer, rect: SDL.FRect, radius: f32, fill, border: clay.Color, width: f32, a: f32 = 1) {
    radius := min(radius, UI_RADIUS)
    if width > 0 {
        b := fcol(border, a)
        round_rect(r, rect, radius, b, b)
    }
    f := fcol(fill, a)
    round_rect(r, inset(rect, width), radius - width, f, f)
}

// A block face's edges inside rect: lit along the top, shaded along the
// bottom (raised), or the other way round (sunk, as a slot).
@(private="file")
bevel :: proc(r: ^SDL.Renderer, rect: SDL.FRect, inset_by: f32, sunk := false, a: f32 = 1) {
    in_ := inset(rect, inset_by)
    if in_.w <= 4 || in_.h <= 4 { return }
    lit := SDL.FColor{1, 0.94, 0.80, 0.10 * a}
    dark := SDL.FColor{0, 0, 0, 0.30 * a}
    hi, lo := lit, dark
    if sunk { hi, lo = dark, lit }
    top := SDL.FRect{in_.x + 1, in_.y, in_.w - 2, sunk ? 2 : 1}
    bot := SDL.FRect{in_.x + 1, in_.y + in_.h - (sunk ? 1 : 2), in_.w - 2, sunk ? 1 : 2}
    SDL.SetRenderDrawColorFloat(r, hi.r, hi.g, hi.b, hi.a)
    SDL.RenderFillRect(r, &top)
    SDL.SetRenderDrawColorFloat(r, lo.r, lo.g, lo.b, lo.a)
    SDL.RenderFillRect(r, &bot)
}

// Draws a custom element (called by the Clay renderer).
ui_draw_custom :: proc(rd: ^Clay_SDL3RendererData, rect: SDL.FRect, data: rawptr) {
    if data == nil { return }
    d := (^Ui_Custom)(data)
    r := rd.renderer
    a := d.alpha
    SDL.SetRenderDrawBlendMode(r, {.BLEND})
    switch d.deco {
    case .Block_Icon:
        draw_block_icon(r, rect, d.block)
    case .Weapon_Icon:
        draw_weapon_icon(r, rect, d.weapon, a)
    case .Glass, .Tooltip:
        flat(r, rect, d.radius, COLOR_PANEL, COLOR_PANEL_BORDER, 1, a)
        bevel(r, rect, 1, a = a * 0.6)
    case .Glass_Soft:
        flat(r, rect, d.radius, COLOR_PANEL_SOFT, COLOR_PANEL_BORDER, 1, a * 0.85)
    case .Button:
        flat(r, rect, d.radius, COLOR_BUTTON, {}, 0)
        bevel(r, rect, 0)
    case .Button_Hover:
        flat(r, rect, d.radius, COLOR_BUTTON_HOVER, {}, 0)
        bevel(r, rect, 0)
    case .Button_On, .Button_On_Hover:
        // Selected: the button framed in the accent.
        flat(r, rect, d.radius, d.deco == .Button_On_Hover ? COLOR_BUTTON_HOVER : COLOR_BUTTON, COLOR_ACCENT, 2)
        bevel(r, rect, 2)
    case .Slot:
        flat(r, rect, d.radius, COLOR_SLOT, {}, 0)
        bevel(r, rect, 0, sunk = true)
    case .Slot_Hover:
        flat(r, rect, d.radius, COLOR_BUTTON_HOVER, {}, 0)
        bevel(r, rect, 0)
    case .Slot_On:
        flat(r, rect, d.radius, COLOR_SLOT, COLOR_ACCENT, 2)
        bevel(r, rect, 2, sunk = true)
    case .Shape_Icon:
        draw_shape_icon(r, rect, d.shape, COLOR_TEXT_DIM)
    case .Shape_Icon_On:
        flat(r, rect, d.radius, COLOR_BUTTON, COLOR_ACCENT, 1)
        draw_shape_icon(r, rect, d.shape, COLOR_ACCENT)
    case .Backdrop:
        menu_backdrop(r, rect)
    case .Menu_Item:
        flat(r, rect, d.radius, {COLOR_PANEL.r, COLOR_PANEL.g, COLOR_PANEL.b, 205}, COLOR_PANEL_BORDER, 1)
        bevel(r, rect, 1)
    case .Menu_Item_Hover, .Menu_Item_On:
        // Lit: brighter, an accent block at the left edge (and a frame when picked).
        on := d.deco == .Menu_Item_On
        flat(r, rect, d.radius, {COLOR_BUTTON.r, COLOR_BUTTON.g, COLOR_BUTTON.b, 238}, on ? COLOR_ACCENT : COLOR_PANEL_BORDER, on ? 2 : 1)
        bevel(r, rect, on ? 2 : 1)
        bar := SDL.FRect{rect.x + 7, rect.y + rect.h * 0.3, 4, rect.h * 0.4}
        c := fcol(COLOR_ACCENT)
        round_rect(r, bar, 0, c, c)
    }
}

// A building shape as a little line drawing, seen from the side and a bit
// above.
@(private="file")
draw_shape_icon :: proc(r: ^SDL.Renderer, rect: SDL.FRect, shape: Build_Shape, col: clay.Color) {
    m := rect.w * 0.17
    box := SDL.FRect{rect.x + m, rect.y + m, rect.w - 2 * m, rect.h - 2 * m}
    at :: proc(box: SDL.FRect, x, y: f32) -> SDL.FPoint { return {box.x + x * box.w, box.y + y * box.h} }
    pts: [64]SDL.FPoint
    line :: proc(r: ^SDL.Renderer, box: SDL.FRect, xy: ..[2]f32) {
        pts: [16]SDL.FPoint
        for p, i in xy { pts[i] = at(box, p.x, p.y) }
        SDL.RenderLines(r, &pts[0], i32(len(xy)))
    }
    // An ellipse arc around (cx, cy) from angle t0 to t1 (y down).
    arc :: proc(r: ^SDL.Renderer, box: SDL.FRect, pts: ^[64]SDL.FPoint, cx, cy, rx, ry: f32, t0: f32 = 0, t1: f32 = 2 * math.PI) {
        N :: 28
        for i in 0 ..= N {
            t := t0 + (t1 - t0) * f32(i) / N
            pts[i] = at(box, cx + rx * math.cos(t), cy + ry * math.sin(t))
        }
        SDL.RenderLines(r, &pts[0], N + 1)
    }
    SDL.SetRenderDrawColorFloat(r, col.r / 255, col.g / 255, col.b / 255, col.a / 255)
    switch shape {
    case .Sphere:
        arc(r, box, &pts, 0.5, 0.5, 0.5, 0.5)
        arc(r, box, &pts, 0.5, 0.5, 0.5, 0.16, 0, math.PI)
    case .Box:
        line(r, box, {0, 0.3}, {0.7, 0.3}, {0.7, 1}, {0, 1}, {0, 0.3}, {0.3, 0}, {1, 0}, {0.7, 0.3})
        line(r, box, {1, 0}, {1, 0.7}, {0.7, 1})
    case .Cylinder:
        arc(r, box, &pts, 0.5, 0.14, 0.5, 0.14)
        arc(r, box, &pts, 0.5, 0.86, 0.5, 0.14, 0, math.PI)
        line(r, box, {0, 0.14}, {0, 0.86})
        line(r, box, {1, 0.14}, {1, 0.86})
    case .Cone:
        arc(r, box, &pts, 0.5, 0.86, 0.5, 0.14, 0, math.PI)
        line(r, box, {0, 0.86}, {0.5, 0}, {1, 0.86})
    case .Pyramid:
        line(r, box, {0, 0.78}, {0.62, 1}, {1, 0.72}, {0.5, 0}, {0, 0.78})
        line(r, box, {0.5, 0}, {0.62, 1})
    case .Torus:
        arc(r, box, &pts, 0.5, 0.55, 0.5, 0.32)
        arc(r, box, &pts, 0.5, 0.55, 0.2, 0.09)
    case .Dome:
        arc(r, box, &pts, 0.5, 0.86, 0.5, 0.78, math.PI, 2 * math.PI)
        arc(r, box, &pts, 0.5, 0.86, 0.5, 0.14)
    }
}

// ─── Small pieces ──────────────────────────────────────────────────────────

text :: proc(s: string, color := COLOR_TEXT, size: u16 = 16, font: u16 = FONT_ID_BODY) {
    clay.TextDynamic(s, clay.TextConfig({textColor = color, fontId = font, fontSize = size}))
}

// Fades a color's alpha; quantized so fading text doesn't flood the text cache.
fade :: proc(col: clay.Color, a: f32) -> clay.Color {
    q := math.round(clamp(a, 0, 1) * 16) / 16
    return {col.r, col.g, col.b, col.a * q}
}

spacer :: proc() {
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {}
}

// A scrollbar beside the scroll container `id` (a sibling after it in a
// row): a thumb to drag, shown only while its content doesn't fit. Laid out
// from last frame's sizes.
scrollbar :: proc(gs: ^Game_State, id: clay.ElementId) {
    ui := &gs.ui
    sc := clay.GetScrollContainerData(id)
    view, full := sc.scrollContainerDimensions.height, sc.contentDimensions.height
    if !sc.found || full <= view + 1 || view <= 0 { return }
    track := clay.ID("ScrollTrack", id.id)
    thumb := clay.ID("ScrollThumb", id.id)
    thumb_h := max(view * view / full, 28)
    room := max(view - thumb_h, 1)
    hovered := clay.PointerOver(thumb)
    if ui.mouse_left_pressed && hovered {
        ui.dragging = thumb.id
        ui.drag_grab = ui.mouse_pos.y - clay.GetElementData(thumb).boundingBox.y
    } else if ui.mouse_left_pressed && clay.PointerOver(track) {
        // A click on the track: the thumb's middle jumps there.
        ui.dragging = thumb.id
        ui.drag_grab = thumb_h / 2
    }
    active := ui.dragging == thumb.id
    if active {
        if !ui.mouse_left_down {
            ui.dragging = 0
        } else if bb := clay.GetElementData(track).boundingBox; bb.height > 0 {
            k := clamp((ui.mouse_pos.y - ui.drag_grab - bb.y) / room, 0, 1)
            sc.scrollPosition.y = -k * (full - view)
        }
    }
    top := clamp(-sc.scrollPosition.y / (full - view), 0, 1) * room
    if clay.UI(track)({
        layout = {sizing = {clay.SizingFixed(6), clay.SizingGrow()}},
        backgroundColor = COLOR_BAR_BG, cornerRadius = clay.CornerRadiusAll(3),
    }) {
        // Floating: sized from last frame, it mustn't hold the track (and
        // so the view) open.
        if clay.UI(thumb)({
            layout = {sizing = {clay.SizingFixed(6), clay.SizingFixed(thumb_h)}},
            floating = {attachTo = .Parent, clipTo = .AttachedParent, offset = {0, top}, zIndex = 21, attachment = {.LeftTop, .LeftTop}},
            backgroundColor = active || hovered ? COLOR_ACCENT : COLOR_TEXT_FAINT, cornerRadius = clay.CornerRadiusAll(3),
        }) {}
    }
}

// A thin rule that fades out to both ends.
divider :: proc() {
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}}}) {
        for a in ([3]f32{0.3, 1, 0.3}) {
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                backgroundColor = fade(COLOR_RULE, a)}) {}
        }
    }
}

// Floating at an anchor of the screen, not taking the pointer.
anchored :: proc(at: clay.FloatingAttachPointType, offset: [2]f32, z: i16 = 10) -> clay.FloatingElementConfig {
    return {
        attachTo = .Root, offset = transmute(clay.Vector2)offset, zIndex = z,
        attachment = {element = at, parent = at},
        pointerCaptureMode = .Passthrough,
    }
}

// A section heading: an amber tick, then the words.
heading :: proc(s: string, a: f32 = 1) {
    if clay.UI()({layout = {childGap = 7, childAlignment = {y = .Center}}}) {
        if clay.UI()({layout = {sizing = {clay.SizingFixed(3), clay.SizingFixed(13)}},
            backgroundColor = fade(COLOR_ACCENT, a), cornerRadius = clay.CornerRadiusAll(1.5)}) {}
        text(s, fade(COLOR_ACCENT, a), 13, FONT_ID_TITLE)
    }
}

// "Red_Sand" -> "Red sand".
block_name :: proc(b: Block_Type) -> string {
    if block_is_door(u8(b)) { return "Door" }
    s, _ := strings.replace_all(fmt.tprint(b), "_", " ", context.temp_allocator)
    if len(s) < 2 { return s }
    return strings.concatenate({s[:1], strings.to_lower(s[1:], context.temp_allocator)}, context.temp_allocator)
}

@(private="file")
biome_name :: proc(b: Biome) -> string {
    switch b {
    case .Ocean:     return "Ocean"
    case .Beach:     return "Beach"
    case .River:     return "River"
    case .Plains:    return "Plains"
    case .Forest:    return "Forest"
    case .Taiga:     return "Taiga"
    case .Snowy:     return "Snowy tundra"
    case .Desert:    return "Desert"
    case .Badlands:  return "Badlands"
    case .Savanna:   return "Savanna"
    case .Mountains: return "Mountains"
    case .Peaks:     return "Peaks"
    }
    return ""
}

// ─── HUD ───────────────────────────────────────────────────────────────────

hud_layout :: proc(gs: ^Game_State, w, h: f32) {
    ui := &gs.ui
    gliding := gs.glider.deployed
    playing := ui.screen == .None

    // Crosshair: a thin plus with a dark edge so it reads on snow and sky alike.
    if playing && !gliding {
        crosshair_bar :: proc(id: string, x, y, bw, bh: f32) {
            if clay.UI(clay.ID(id))({
                layout = {sizing = {clay.SizingFixed(bw + 2), clay.SizingFixed(bh + 2)}},
                floating = {attachTo = .Root, offset = {x - 1, y - 1}, zIndex = 4, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
                backgroundColor = {0, 0, 0, 110},
            }) {
                if clay.UI()({
                    layout = {sizing = {clay.SizingFixed(bw), clay.SizingFixed(bh)}},
                    floating = {attachTo = .Parent, offset = {1, 1}, zIndex = 5, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
                    backgroundColor = {255, 255, 255, 225},
                }) {}
            }
        }
        cx, cy := math.floor(w / 2), math.floor(h / 2)
        crosshair_bar("CrossH", cx - 9, cy - 1, 18, 2)
        crosshair_bar("CrossV", cx - 1, cy - 9, 2, 18)
        // A box being dragged out: how big, under the crosshair (build_drag.odin).
        if drag_showing(gs) {
            label, too_big := drag_label(gs)
            if clay.UI(clay.ID("DragLabel"))({
                layout = {padding = {8, 8, 4, 5}},
                floating = {attachTo = .Root, offset = {cx, cy + 26}, zIndex = 6, attachment = {.CenterTop, .LeftTop}, pointerCaptureMode = .Passthrough},
                custom = deco(.Tooltip, radius = 6),
            }) {
                text(label, too_big ? COLOR_ACCENT_2 : COLOR_TEXT, 13, FONT_ID_TITLE)
            }
            if clay.UI(clay.ID("DragHint"))({
                layout = {padding = {7, 7, 3, 4}},
                floating = {attachTo = .Root, offset = {cx, cy + 58}, zIndex = 6, attachment = {.CenterTop, .LeftTop}, pointerCaptureMode = .Passthrough},
                custom = deco(.Tooltip, radius = 5, alpha = 0.6),
            }) {
                hint := "wheel or Ctrl + mouse: depth   Tab: floor / wall   let go to set it right"
                if gs.build.drag.pending { hint = "click: apply   other button: cancel   wheel: push the lit face   Shift+wheel: move   Tab: floor / wall" }
                text(hint, COLOR_TEXT_DIM, 11)
            }
        } else if gs.build.box && (gs.survival || gs.build.tool == .Block || gs.build.tool == .Magic) {
            // The box brush, before a click: how a drag decides its lie.
            if clay.UI(clay.ID("BoxHint"))({
                layout = {padding = {7, 7, 3, 4}},
                floating = {attachTo = .Root, offset = {cx, cy + 70}, zIndex = 6, attachment = {.CenterTop, .LeftTop}, pointerCaptureMode = .Passthrough},
                custom = deco(.Tooltip, radius = 5, alpha = 0.6),
            }) {
                lie, _ := drag_view_lie(camera_forward(gs.camera))
                text(lie == .Flat ? "box: a floor   (Tab once dragging: a wall)" : "box: a wall   (Tab once dragging: a floor)", COLOR_TEXT_DIM, 11)
            }
        }
    }

    // Entering a biome: its name for a moment. At startup, where the
    // controls are.
    if ui.biome_t > 0 || ui.help_t > 0 {
        a := min(max(ui.biome_t, ui.help_t) / 0.8, 1)
        if clay.UI(clay.ID("Location"))({
            layout = {layoutDirection = .TopToBottom, padding = {12, 12, 8, 9}, childGap = 3},
            floating = anchored(.LeftTop, {14, 14}),
            custom = deco(.Glass_Soft, radius = 6, alpha = a),
        }) {
            text(biome_name(ui.biome_shown), fade(COLOR_TEXT, min(ui.biome_t / 0.8, 1)), 16, FONT_ID_TITLE)
            if ui.help_t > 0 { text("H controls   Esc menu", fade(COLOR_TEXT_DIM, min(ui.help_t / 0.8, 1)), 12) }
        }
    }
    if ui.debug_open { debug_layout(gs) }

    if !gliding && ui.screen != .Inventory && !gs.combat.fighting {
        hotbar_layout(gs)
        if playing && !gs.survival { build_hud_layout(gs, w) } // survival has no tools: magic (magic.odin)
    } else if !gliding && ui.screen != .Inventory {
        weapon_bar_layout(gs) // fighting: the weapon bar in the hotbar's place (R)
    }
    if playing { combat_hud_layout(gs, w, h) }
    name_tags_layout(gs, w, h)
    chat_layout(gs, h)
    box := gs.build.drag.on || gs.build.drag.pending // Tab turns a box then (build_drag.odin)
    if playing && ui.typing == nil && !box && SDL.GetKeyboardState(nil)[SDL.Scancode.TAB] { player_list_layout(gs) }

    // Toast.
    if ui.toast_t > 0 {
        a := min(ui.toast_t / 0.4, 1)
        if clay.UI(clay.ID("Toast"))({layout = {padding = {18, 18, 9, 10}}, floating = anchored(.CenterCenter, {0, -h * 0.22}, 30),
            custom = deco(.Glass, alpha = a)}) {
            text(string(ui.toast_buf[:ui.toast_len]), fade(COLOR_TEXT, a), 17, FONT_ID_TITLE)
        }
    }

    if ui.help_open { help_card(gs, 1) }
}

// Tab: who's playing here, and how far away their connections are.
@(private="file")
player_list_layout :: proc(gs: ^Game_State) {
    n := &gs.net
    row :: proc(id: u32, name: string, tint: [3]f32, info: string, info_col: clay.Color) {
        if clay.UI(clay.ID("PlayerRow", id))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 10, childAlignment = {y = .Center}}}) {
            if clay.UI()({layout = {sizing = {clay.SizingFixed(10), clay.SizingFixed(10)}},
                backgroundColor = {tint.r * 255, tint.g * 255, tint.b * 255, 255}, cornerRadius = clay.CornerRadiusAll(5)}) {}
            text(name, COLOR_TEXT, 15)
            spacer()
            text(info, info_col, 13)
        }
    }
    ping_text :: proc(ms: int) -> (string, clay.Color) {
        col := ms < 80 ? COLOR_ACCENT : (ms < 200 ? COLOR_TEXT_DIM : COLOR_BAD)
        return fmt.tprintf("%d ms", ms), col
    }
    others := 0
    for o in n.others { if o.active { others += 1 } }
    title := "Playing alone"
    if client_joined(gs) {
        title = fmt.tprintf("On %s: %d player%s", string(n.address[:n.address_len]), others + 1, others == 0 ? "" : "s")
    } else if session_hosting(gs) {
        title = fmt.tprintf("Your world, open: %d player%s", others + 1, others == 0 ? "" : "s")
    }
    if clay.UI(clay.ID("PlayerList"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(14), childGap = 7, sizing = {clay.SizingFixed(320), clay.SizingFit()}},
        floating = anchored(.CenterTop, {0, 40}, 25),
        custom = deco(.Glass, radius = 10),
    }) {
        text(title, COLOR_ACCENT, 15, FONT_ID_TITLE)
        divider()
        me := n.slot
        if client_joined(gs) {
            info := "connecting"
            col := COLOR_TEXT_DIM
            if n.welcomed && n.peer != nil { info, col = ping_text(int(n.peer.roundTripTime)) }
            row(u32(me), fmt.tprintf("%s (you)", client_name(gs)), player_tint(gs, me), info, col)
        } else {
            row(u32(me), fmt.tprintf("%s (you)", client_name(gs)), player_tint(gs, me), session_hosting(gs) ? "host" : "", COLOR_TEXT_DIM)
        }
        for &o, slot in n.others {
            if !o.active { continue }
            info, col := ping_text(o.ping)
            if slot == 0 && client_joined(gs) { info, col = "host", COLOR_TEXT_DIM } // its own game: no connection to time
            row(u32(slot), client_player_name(gs, slot), player_tint(gs, slot), info, col)
        }
    }
}

// Other players' names over their heads, fading with distance.
@(private="file")
name_tags_layout :: proc(gs: ^Game_State, w, h: f32) {
    cam := gs.camera
    eye := camera_view_eye(cam)
    for &o, slot in gs.net.others {
        if !o.active { continue }
        over := o.pos + {0, o.latest.gliding ? 1.9 : 0.75, 0}
        d := over - eye
        dist := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        if dist > 64 { continue }
        x, y, ok := glider_project(cam, d, w, h)
        if !ok { continue }
        a := clamp((64 - dist) / 16, 0, 1)
        tint := player_tint(gs, slot)
        if clay.UI(clay.ID("NameTag", u32(slot)))({
            layout = {padding = {7, 7, 3, 4}},
            floating = {attachTo = .Root, offset = {x, y}, zIndex = 6, attachment = {.CenterBottom, .LeftTop}, pointerCaptureMode = .Passthrough},
            backgroundColor = fade({COLOR_SHADE.r, COLOR_SHADE.g, COLOR_SHADE.b, 170}, a),
            cornerRadius = clay.CornerRadiusAll(4),
        }) {
            text(client_player_name(gs, slot), fade({min(tint.r * 255 + 90, 255), min(tint.g * 255 + 90, 255), min(tint.b * 255 + 90, 255), 255}, a), 13, FONT_ID_TITLE)
        }
    }
}

// The chat: recent lines fading out at the bottom left, all of them and
// the line being typed while chatting (Enter sends, Esc drops it).
@(private="file")
chat_layout :: proc(gs: ^Game_State, h: f32) {
    ui := &gs.ui
    typing := ui.typing == &ui.chat_field
    if ui.chat_field.submit {
        ui.chat_field.submit = false
        line := text_set(string(ui.chat_field.buf[:ui.chat_field.len]))
        if line.len > 0 { client_send(gs, .Say, line) }
        ui_type_into(gs, nil)
        typing = false
    }
    any := typing
    for e in gs.net.chat { if e.len > 0 && e.t > 0 { any = true } }
    if !any { return }
    if clay.UI(clay.ID("Chat"))({
        layout = {layoutDirection = .TopToBottom, childGap = 3, sizing = {clay.SizingFixed(420), clay.SizingFit()}},
        floating = anchored(.LeftBottom, {14, -150}),
    }) {
        for &e, i in gs.net.chat {
            if e.len == 0 || (!typing && e.t <= 0) { continue }
            a := typing ? 1 : clamp(e.t / 1.5, 0, 1)
            col := e.slot == SERVER_SLOT ? COLOR_ACCENT : COLOR_TEXT
            if clay.UI(clay.ID("ChatLine", u32(i)))({
                layout = {padding = {8, 8, 3, 4}},
                backgroundColor = fade({COLOR_SHADE.r, COLOR_SHADE.g, COLOR_SHADE.b, 150}, a),
                cornerRadius = clay.CornerRadiusAll(4),
            }) {
                text(string(e.text[:e.len]), fade(col, a), 14)
            }
        }
        if typing {
            f := &ui.chat_field
            caret := (SDL.GetTicks() / 500) % 2 == 0
            if clay.UI(clay.ID("ChatInput"))({
                layout = {padding = {8, 8, 5, 6}, sizing = {clay.SizingGrow(), clay.SizingFit()}},
                custom = deco(.Button_On, radius = 6),
            }) {
                s := string(f.buf[:f.len])
                text(fmt.tprintf("> %s%s", s, caret ? "|" : ""), COLOR_TEXT, 14)
            }
        }
    }
}

// Nine slots along the bottom, the selected block's name over them.
@(private="file")
hotbar_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui
    if clay.UI(clay.ID("HotbarWrap"))({
        layout = {layoutDirection = .TopToBottom, childGap = 7, childAlignment = {x = .Center}},
        floating = anchored(.CenterBottom, {0, -14}),
    }) {
        if ui.block_name_t > 0 {
            a := min(ui.block_name_t / 0.5, 1)
            text(block_name(gs.selected_block), fade(COLOR_TEXT, a), 16, FONT_ID_TITLE)
        }
        if clay.UI(clay.ID("Hotbar"))({
            layout = {padding = clay.PaddingAll(7), childGap = 5, childAlignment = {y = .Center}},
            custom = deco(.Glass_Soft, radius = 10),
        }) {
            hotbar_slots(gs, false)
        }
    }
}

// Fighting: the weapon bar where the hotbar was, the weapon in hand's name
// over it for a moment.
@(private="file")
weapon_bar_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui
    if clay.UI(clay.ID("WeaponWrap"))({
        layout = {layoutDirection = .TopToBottom, childGap = 7, childAlignment = {x = .Center}},
        floating = anchored(.CenterBottom, {0, -14}),
    }) {
        if ui.weapon_name_t > 0 {
            a := min(ui.weapon_name_t / 0.5, 1)
            text(WEAPONS[gs.combat.weapon].name, fade(COLOR_TEXT, a), 16, FONT_ID_TITLE)
        }
        if clay.UI(clay.ID("WeaponBar"))({
            layout = {padding = clay.PaddingAll(7), childGap = 5, childAlignment = {y = .Center}},
            custom = deco(.Glass_Soft, radius = 10),
        }) {
            weapon_slots(gs, false)
        }
    }
}

// The weapon bar's slots: what's in each (an empty one is fists, drawn
// faint), the one in hand framed. clickable: in the inventory, a click
// picks the slot.
@(private="file")
weapon_slots :: proc(gs: ^Game_State, clickable: bool) {
    SLOT :: 46
    for w, i in gs.weapon_bar {
        on := i == gs.weapon_slot
        id := clay.ID(clickable ? "InvWeapon" : "Weapon", u32(i))
        hovered := clickable && clay.PointerOver(id)
        owned := weapon_owned(gs, w)
        if clay.UI(id)({
            layout = {sizing = {clay.SizingFixed(SLOT), clay.SizingFixed(SLOT)}, childAlignment = {.Center, .Center}},
            custom = deco(on ? .Slot_On : (hovered ? .Slot_Hover : .Slot), radius = 6),
        }) {
            shown := owned ? w : .None
            if clay.UI()({layout = {sizing = {clay.SizingFixed(SLOT - 10), clay.SizingFixed(SLOT - 10)}},
                custom = deco(.Weapon_Icon, weapon = shown, alpha = shown == .None ? 0.35 : 1)}) {}
            if clay.UI(clay.ID(clickable ? "InvWeaponKey" : "WeaponKey", u32(i)))({
                floating = {attachTo = .Parent, offset = {5, 3}, zIndex = 12, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
            }) {
                text(fmt.tprintf("%d", i + 1), on ? COLOR_ACCENT : COLOR_TEXT_FAINT, 10, FONT_ID_TITLE)
            }
        }
        if hovered && gs_ui_left_pressed() {
            weapon_select(gs, i)
            play(.Click, 0.4)
        }
    }
}

// A monster's level over it (at `over`, world) while it's near, its health
// beside that while `bar` > 0 (after a hit). The level's colour says how
// tough it is: pale, then amber, then red.
@(private="file")
monster_tag :: proc(gs: ^Game_State, id: clay.ElementId, over: [3]f32, frac: f32, level: u8, bar: f32, w, h: f32) {
    TAG_RANGE :: f32(28) // voxels
    cam := gs.camera
    eye := camera_view_eye(cam)
    d := over - eye
    dist := la.length(d)
    if dist > TAG_RANGE && bar <= 0 { return }
    x, y, ok := glider_project(cam, d, w, h)
    if !ok { return }
    a := max(clamp((TAG_RANGE - dist) / 6, 0, 1), clamp(bar * 2, 0, 1))
    if a <= 0 { return }
    col := level >= 8 ? COLOR_BAD : (level >= 4 ? COLOR_ACCENT : COLOR_TEXT)
    BW :: f32(54)
    if clay.UI(id)({
        layout = {childGap = 4, childAlignment = {y = .Center}},
        floating = {attachTo = .Root, offset = {x, y}, zIndex = 6, attachment = {.CenterCenter, .LeftTop}, pointerCaptureMode = .Passthrough},
    }) {
        if clay.UI()({
            layout = {padding = {4, 4, 1, 2}},
            backgroundColor = fade({COLOR_SHADE.r, COLOR_SHADE.g, COLOR_SHADE.b, 170}, a),
            cornerRadius = clay.CornerRadiusAll(3),
        }) {
            text(fmt.tprintf("%d", level), fade(col, a), 11, FONT_ID_TITLE)
        }
        if bar > 0 {
            ba := clamp(bar * 2, 0, 1)
            if clay.UI()({
                layout = {sizing = {clay.SizingFixed(BW), clay.SizingFixed(6)}, padding = {1, 1, 1, 1}},
                backgroundColor = fade({COLOR_SHADE.r, COLOR_SHADE.g, COLOR_SHADE.b, 200}, ba),
            }) {
                if clay.UI()({
                    layout = {sizing = {clay.SizingFixed((BW - 2) * clamp(frac, 0, 1)), clay.SizingGrow({})}},
                    backgroundColor = fade({214, 72, 56, 255}, ba),
                }) {}
            }
        }
    }
}

// Health, only while hurt: a thin bar over where the hotbar sits.
@(private="file")
health_bar :: proc(gs: ^Game_State, w, h: f32) {
    c := &gs.combat
    W :: f32(220)
    a := clamp((PLAYER_MAX_HP - c.hp) / 4, 0, 1) // fades out as it fills up
    if a <= 0 { return }
    if clay.UI(clay.ID("Health"))({
        layout = {sizing = {clay.SizingFixed(W), clay.SizingFixed(6)}},
        floating = anchored(.CenterBottom, {0, -86}),
        backgroundColor = fade(COLOR_BAR_BG, a), cornerRadius = clay.CornerRadiusAll(3),
    }) {
        fill := clamp(c.hp / PLAYER_MAX_HP, 0, 1)
        col := c.hurt_flash > 0.6 ? clay.Color{255, 244, 236, 255} : COLOR_BAD
        if clay.UI()({layout = {sizing = {clay.SizingFixed(W * fill), clay.SizingGrow()}}, backgroundColor = fade(col, a), cornerRadius = clay.CornerRadiusAll(3)}) {}
    }
}

// Survival: mana while it isn't full, over where health shows; it flashes
// when a spell wants more than there is.
@(private="file")
mana_bar :: proc(gs: ^Game_State) {
    m := &gs.magic
    W :: f32(220)
    a := clamp(m.mana_spent / 4, 0, 1) // fades out as it fills up
    if m.starved_t > 0 { a = 1 }
    if a <= 0 { return }
    if clay.UI(clay.ID("Mana"))({
        layout = {sizing = {clay.SizingFixed(W), clay.SizingFixed(6)}},
        floating = anchored(.CenterBottom, {0, -112}), // over the held block's (or weapon's) name
        backgroundColor = fade(COLOR_BAR_BG, a), cornerRadius = clay.CornerRadiusAll(3),
    }) {
        fill := clamp(magic_mana(m) / MANA_MAX, 0, 1)
        col := clay.Color{90, 160, 255, 255}
        if m.starved_t > 0 && int(m.starved_t * 10) % 2 == 0 { col = {235, 245, 255, 255} }
        if clay.UI()({layout = {sizing = {clay.SizingFixed(W * fill), clay.SizingGrow()}}, backgroundColor = fade(col, a), cornerRadius = clay.CornerRadiusAll(3)}) {}
    }
}

// Fighting: health while hurt, red at the screen edges when hit, and damage
// numbers popping up over what you hit. Nothing else: the hits, flashes and
// shakes say the rest.
@(private="file")
combat_hud_layout :: proc(gs: ^Game_State, w, h: f32) {
    c := &gs.combat
    fx := &gs.fx
    cam := gs.camera
    eye := camera_view_eye(cam)

    health_bar(gs, w, h)
    if gs.survival { mana_bar(gs) }

    // Over a monster near enough to size up, its level; once it's hit, a
    // thin health bar beside it for a while (levels.odin).
    for &en, i in gs.enemies.list {
        if !en.alive || en.state == .Dead { continue }
        sp := ENEMY_SPECS[en.kind]
        monster_tag(gs, clay.ID("EnBar", u32(i)), en.pos + {0, sp.height + 0.35, 0}, en.hp / enemy_max_hp(&en), en.level, en.bar, w, h)
    }
    for &sl, i in gs.slimes.list {
        if !sl.alive { continue }
        monster_tag(gs, clay.ID("SlBar", u32(i)), sl.pos + {0, SLIME_KINDS[sl.size].width * 0.9 + 0.3, 0}, sl.hp / slime_max_hp(&sl), sl.level, sl.bar, w, h)
    }

    for n, i in fx.numbers {
        if n.life <= 0 { continue }
        x, y, ok := glider_project(cam, n.pos - eye, w, h)
        if !ok { continue }
        t := 1 - n.life / 0.9
        pop := max(0.2 - t, 0) * 5 // pops in big, then settles
        size := u16(math.round(((n.big ? f32(28) : 22) + 12 * pop) / 2) * 2)
        a := clamp(n.life * 4, 0, 1)
        col := n.boosted ? COLOR_ACCENT_2 : (n.big ? COLOR_ACCENT : COLOR_TEXT)
        label := fmt.tprintf("%d", n.value)
        for layer in 0 ..< 2 {
            off := layer == 0 ? f32(2) : 0
            if clay.UI(clay.ID(layer == 0 ? "DmgShadow" : "Dmg", u32(i)))({
                floating = {attachTo = .Root, offset = {x + off, y + off}, zIndex = i16(7 + layer), attachment = {.CenterCenter, .LeftTop}, pointerCaptureMode = .Passthrough},
            }) {
                text(label, layer == 0 ? fade({COLOR_SHADE.r, COLOR_SHADE.g, COLOR_SHADE.b, 220}, a) : fade(col, a), size, FONT_ID_TITLE)
            }
        }
    }

    // Hit: red creeping in from the edges, in a few soft bands.
    if c.hurt_flash > 0.02 {
        for band in 0 ..< 4 {
            d := f32(band + 1) * min(w, h) * 0.02
            col := clay.Color{200, 24, 20, c.hurt_flash * 40}
            edges := [4][4]f32{{0, 0, w, d}, {0, h - d, w, d}, {0, d, d, h - 2 * d}, {w - d, d, d, h - 2 * d}}
            for e, j in edges {
                if clay.UI(clay.ID("Hurt", u32(band * 4 + j)))({
                    layout = {sizing = {clay.SizingFixed(e[2]), clay.SizingFixed(e[3])}},
                    floating = {attachTo = .Root, offset = {e[0], e[1]}, zIndex = 3, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
                    backgroundColor = col,
                }) {}
            }
        }
    }
}

// The nine hotbar slots; in the block picker they're clickable (select one).
@(private="file")
hotbar_slots :: proc(gs: ^Game_State, clickable: bool) {
    SLOT :: 46
    for b, i in gs.hotbar {
        on := i == gs.hotbar_slot
        id := clay.ID(clickable ? "InvHot" : "Hot", u32(i))
        hovered := clickable && clay.PointerOver(id)
        if clay.UI(id)({
            layout = {sizing = {clay.SizingFixed(SLOT), clay.SizingFixed(SLOT)}, childAlignment = {.Center, .Center}},
            custom = deco(on ? .Slot_On : (hovered ? .Slot_Hover : .Slot), radius = 6),
        }) {
            if b != .Air {
                if clay.UI()({layout = {sizing = {clay.SizingFixed(SLOT - 6), clay.SizingFixed(SLOT - 6)}}, custom = deco(.Block_Icon, b)}) {}
            }
            if clay.UI(clay.ID(clickable ? "InvHotKey" : "HotKey", u32(i)))({
                floating = {attachTo = .Parent, offset = {5, 3}, zIndex = 12, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
            }) {
                text(fmt.tprintf("%d", i + 1), on ? COLOR_ACCENT : COLOR_TEXT_FAINT, 10, FONT_ID_TITLE)
            }
            if gs.survival && b != .Air { item_count(gs, clay.ID(clickable ? "InvHotCount" : "HotCount", u32(i)), items_shown(gs, b), on && gs.magic.empty_t > 0) }
        }
        if hovered && gs_ui_left_pressed() {
            hotbar_select(gs, i)
            play(.Click, 0.4)
        }
    }
}

// How many of a block you carry, in a slot's corner (survival).
@(private="file")
item_count :: proc(gs: ^Game_State, id: clay.ElementId, n: u32, blink := false) {
    if clay.UI(id)({
        floating = {attachTo = .Parent, offset = {-4, -2}, zIndex = 12, attachment = {.RightBottom, .RightBottom}, pointerCaptureMode = .Passthrough},
    }) {
        label := n >= 10_000 ? fmt.tprintf("%dk", n / 1000) : fmt.tprintf("%d", n)
        col := n == 0 ? COLOR_BAD : COLOR_TEXT
        if blink && int(gs.magic.empty_t * 10) % 2 == 0 { col = {255, 236, 228, 255} } // just ran out: it blinks
        text(label, col, blink ? 15 : 12, FONT_ID_TITLE)
    }
}

// sRGB face colours for the icons: top, side.
icon_colors :: proc(b: Block_Type) -> (top, side: [3]f32) {
    #partial switch b {
    case .Grass:      return {0.38, 0.60, 0.24}, {0.47, 0.33, 0.22}
    case .Dirt:       return {0.47, 0.33, 0.22}, {0.47, 0.33, 0.22}
    case .Sand:       return {0.87, 0.80, 0.61}, {0.85, 0.77, 0.58}
    case .Red_Sand:   return {0.78, 0.47, 0.27}, {0.76, 0.45, 0.26}
    case .Sandstone:  return {0.86, 0.78, 0.59}, {0.82, 0.73, 0.54}
    case .Log:        return {0.68, 0.53, 0.34}, {0.40, 0.29, 0.18}
    case .Spruce_Log: return {0.55, 0.42, 0.27}, {0.30, 0.21, 0.13}
    case .Leaves:     return {0.25, 0.48, 0.18}, {0.22, 0.43, 0.16}
    case .Spruce_Leaves: return {0.17, 0.36, 0.23}, {0.15, 0.32, 0.20}
    case .Birch_Log:     return {0.80, 0.72, 0.56}, {0.88, 0.87, 0.82}
    case .Birch_Leaves:  return {0.42, 0.62, 0.22}, {0.38, 0.57, 0.20}
    case .Autumn_Leaves: return {0.90, 0.48, 0.14}, {0.80, 0.36, 0.12}
    case .Acacia_Log:    return {0.72, 0.45, 0.28}, {0.45, 0.40, 0.35}
    case .Acacia_Leaves: return {0.40, 0.50, 0.18}, {0.36, 0.45, 0.16}
    case .Willow_Leaves: return {0.48, 0.62, 0.26}, {0.44, 0.58, 0.24}
    case .Dry_Grass:     return {0.70, 0.64, 0.30}, {0.47, 0.33, 0.22}
    case .Tall_Grass:    return {0.38, 0.62, 0.24}, {0.32, 0.55, 0.20}
    case .Fern:          return {0.20, 0.45, 0.18}, {0.18, 0.40, 0.16}
    case .Flower:        return {0.95, 0.80, 0.25}, {0.30, 0.55, 0.20}
    case .Dry_Bush:      return {0.55, 0.42, 0.25}, {0.48, 0.36, 0.22}
    case .Mushroom:      return {0.80, 0.18, 0.12}, {0.90, 0.88, 0.80}
    case .Moss:          return {0.30, 0.52, 0.16}, {0.26, 0.45, 0.14}
    case .Dripstone:     return {0.66, 0.55, 0.42}, {0.60, 0.50, 0.38}
    case .Roots:         return {0.50, 0.38, 0.24}, {0.45, 0.34, 0.22}
    case .Glow_Mushroom: return {0.40, 0.95, 0.95}, {0.70, 0.75, 0.70}
    case .Glow_Moss:     return {0.35, 0.85, 0.70}, {0.25, 0.55, 0.45}
    case .Sapling:       return {0.28, 0.58, 0.20}, {0.40, 0.28, 0.16}
    case .Snow:       return {0.93, 0.95, 0.98}, {0.90, 0.92, 0.96}
    case .Ice:        return {0.68, 0.80, 0.93}, {0.62, 0.75, 0.90}
    case .Terracotta: return {0.70, 0.40, 0.27}, {0.70, 0.40, 0.27}
    case .Gravel:     return {0.55, 0.53, 0.50}, {0.53, 0.51, 0.48}
    case .Cactus:     return {0.36, 0.60, 0.27}, {0.30, 0.54, 0.22}
    case .Weathered_Stone: return {0.45, 0.52, 0.36}, {0.50, 0.50, 0.50}
    case .Stone_Bricks:    return {0.58, 0.57, 0.55}, {0.52, 0.51, 0.50}
    case .Workbench:       return {0.68, 0.50, 0.30}, {0.50, 0.35, 0.20}
    case .Crystal:         return {1.00, 0.80, 0.42}, {0.95, 0.62, 0.25}
    case .Kelp:            return {0.30, 0.42, 0.14}, {0.26, 0.38, 0.12}
    case .Seagrass:        return {0.30, 0.55, 0.22}, {0.26, 0.50, 0.19}
    case .Coral:           return {0.95, 0.42, 0.52}, {0.85, 0.34, 0.45}
    case .Sea_Pickle:      return {0.75, 0.95, 0.45}, {0.55, 0.80, 0.30}
    }
    return {0.56, 0.56, 0.58}, {0.52, 0.52, 0.55}
}

@(private="file")
icon_hash :: proc(a, b, c: int) -> f32 {
    h := u32(a * 73856093) ~ u32(b * 19349663) ~ u32(c * 83492791)
    h = (h ~ (h >> 13)) * 0x5bd1e995
    h ~= h >> 15
    return f32(h & 0xffff) / 65535
}

// A little isometric cube: three faces of 4x4 texels, lit from the top left,
// with the block's own touches (grass edge, log rings, terracotta bands, ...).
@(private="file")
draw_block_icon :: proc(r: ^SDL.Renderer, rect: SDL.FRect, b: Block_Type) {
    N :: 4
    cx, cy := rect.x + rect.w / 2, rect.y + rect.h / 2 + 1
    hw := rect.w * 0.38
    if b == .Torch {
        // A stick with a glowing tip instead of a cube.
        u := rect.w / 16
        stick := SDL.FRect{cx - u, cy - 3 * u, 2 * u, 9 * u}
        SDL.SetRenderDrawColor(r, 110, 78, 44, 255)
        SDL.RenderFillRect(r, &stick)
        glow := SDL.FRect{cx - 2 * u, cy - 6 * u, 4 * u, 4 * u}
        SDL.SetRenderDrawColor(r, 255, 170, 60, 255)
        SDL.RenderFillRect(r, &glow)
        core := SDL.FRect{cx - u, cy - 5 * u, 2 * u, 2 * u}
        SDL.SetRenderDrawColor(r, 255, 240, 170, 255)
        SDL.RenderFillRect(r, &core)
        return
    }
    if b == .Door {
        // A plank door: frame, two window panes up top, a knob.
        u := rect.w / 16
        fill :: proc(r: ^SDL.Renderer, x, y, w, h: f32, col: [3]u8) {
            q := SDL.FRect{x, y, w, h}
            SDL.SetRenderDrawColor(r, col.r, col.g, col.b, 255)
            SDL.RenderFillRect(r, &q)
        }
        x0, y0 := cx - 4 * u, cy - 7.5 * u
        fill(r, x0, y0, 8 * u, 14 * u, {92, 62, 34})
        fill(r, x0 + u, y0 + u, 6 * u, 12 * u, {150, 106, 60})
        fill(r, x0 + 1.5 * u, y0 + 1.5 * u, 2.2 * u, 3.5 * u, {150, 196, 220})
        fill(r, x0 + 4.3 * u, y0 + 1.5 * u, 2.2 * u, 3.5 * u, {150, 196, 220})
        fill(r, x0 + 1.5 * u, y0 + 7 * u, 5 * u, 0.6 * u, {112, 78, 44})
        fill(r, x0 + 5.6 * u, y0 + 7.8 * u, 0.9 * u, 0.9 * u, {40, 36, 32})
        return
    }
    top, side := icon_colors(b)
    // Face corners: origin and the two edge vectors spanning it.
    T := [2]f32{cx, cy - hw}
    L := [2]f32{cx - hw, cy - hw * 0.5}
    C := [2]f32{cx, cy}
    faces := [3]struct { o, u, v: [2]f32, shade: f32 }{
        {L, T - L, C - L, 1.0},                                  // top
        {L, C - L, {0, hw}, 0.78},                               // left
        {C, ([2]f32{cx + hw, cy - hw * 0.5}) - C, {0, hw}, 0.6}, // right
    }
    verts: [3 * N * N * 4]SDL.Vertex
    idx: [3 * N * N * 6]c.int
    nv, ni := 0, 0
    for f, fi in faces {
        for j in 0 ..< N {
            for i in 0 ..< N {
                col := fi == 0 ? top : side
                // Per-block details.
                #partial switch b {
                case .Grass, .Dry_Grass:
                    if fi > 0 && j == 0 { col = top }
                    if fi > 0 && j == 1 && icon_hash(i, j, fi) < 0.4 { col = top }
                case .Log, .Spruce_Log, .Birch_Log, .Acacia_Log:
                    if fi == 0 && (i == 0 || i == N - 1 || j == 0 || j == N - 1) { col = side }
                    if b == .Birch_Log && fi > 0 && icon_hash(i, j, fi + 11) < 0.22 { col = {0.18, 0.17, 0.16} }
                case .Terracotta:
                    if fi > 0 && j % 2 == 1 { col *= {1.12, 1.25, 1.2} }
                case .Coal_Ore, .Iron_Ore, .Gold_Ore:
                    if icon_hash(i, j, fi + 7) < 0.25 {
                        col = b == .Coal_Ore ? {0.15, 0.15, 0.16} : (b == .Iron_Ore ? {0.80, 0.62, 0.48} : {0.95, 0.80, 0.30})
                    }
                case .Leaves, .Spruce_Leaves, .Birch_Leaves, .Autumn_Leaves, .Acacia_Leaves, .Willow_Leaves:
                    if icon_hash(i, j, fi + 3) < 0.25 { col *= 0.7 }
                    if b == .Autumn_Leaves && icon_hash(i, j, fi + 9) < 0.3 { col = {0.85, 0.22, 0.10} }
                case .Weathered_Stone:
                    if fi > 0 && j == 0 && icon_hash(i, j, fi) < 0.6 { col = top }
                case .Stone_Bricks:
                    if j % 2 == 1 || (i + (j / 2) * 2) % 4 == 0 { col *= 0.72 }
                case .Workbench:
                    // A rim round the top, a saw on it; legs at the sides' corners.
                    if fi == 0 && (i == 0 || i == N - 1 || j == 0 || j == N - 1) { col *= 0.7 }
                    if fi == 0 && j == 1 && i >= 1 && i <= 2 { col = {0.72, 0.74, 0.76} }
                    if fi > 0 && (i == 0 || i == N - 1) { col *= 0.72 }
                    if fi > 0 && j == 0 { col *= 1.12 }
                }
                n := 0.9 + 0.2 * icon_hash(i, j, fi + int(b) * 5)
                lit := col * f.shade * n
                fc := SDL.FColor{min(lit.x, 1), min(lit.y, 1), min(lit.z, 1), 1}
                p00 := f.o + f.u * (f32(i) / N) + f.v * (f32(j) / N)
                du, dv := f.u / N, f.v / N
                base := c.int(nv)
                for p in ([4][2]f32{p00, p00 + du, p00 + du + dv, p00 + dv}) {
                    verts[nv] = {position = {p.x, p.y}, color = fc}
                    nv += 1
                }
                for k in ([6]c.int{0, 1, 2, 0, 2, 3}) {
                    idx[ni] = base + k
                    ni += 1
                }
            }
        }
    }
    SDL.RenderGeometry(r, nil, &verts[0], c.int(nv), &idx[0], c.int(ni))
}

// A world-space line (p, q relative to the eye) onto the screen, clipped
// against a near plane; o shifts it (a shadow line under a light one).
@(private="file")
view_line :: proc(r: ^SDL.Renderer, p, q: [3]f32, fwd, right, up: [3]f32, w, h: f32, o: f32 = 0, thick := false) {
    NEAR :: 0.05
    project :: proc(p: [3]f32, fwd, right, up: [3]f32, w, h: f32) -> [2]f32 {
        d := la.dot(p, fwd)
        nx := la.dot(p, right) / d / la.length2(right)
        ny := la.dot(p, up) / d / la.length2(up)
        return {(nx + 1) * 0.5 * w, (1 - ny) * 0.5 * h}
    }
    p, q := p, q
    dp, dq := la.dot(p, fwd), la.dot(q, fwd)
    if dp < NEAR && dq < NEAR { return }
    if dp < NEAR { p = la.lerp(p, q, (NEAR - dp) / (dq - dp)) }
    if dq < NEAR { q = la.lerp(q, p, (NEAR - dq) / (dp - dq)) }
    s, e := project(p, fwd, right, up, w, h), project(q, fwd, right, up, w, h)
    SDL.RenderLine(r, s.x + o, s.y + o, e.x + o, e.y + o)
    if thick { SDL.RenderLine(r, s.x + 0.5, s.y + 0.5, e.x + 0.5, e.y + 0.5) }
}

// What a click would edit, outlined: the voxel you point at (and the brush),
// the area being dragged out, or the shape (build_tools.odin). Fills are
// light, clears red, and anything too big to apply amber.
@(private="file")
draw_target_outline :: proc(gs: ^Game_State, w, h: f32) {
    if !gs.mouse_locked || gs.glider.deployed { return }
    pv := build_preview(gs)
    if len(pv.segs) == 0 { return }
    CLEAR_COL :: [3]u8{255, 110, 95}
    eye := camera_view_eye(gs.camera)
    fwd, right, up := camera_view_basis(gs.camera, w / h)
    lo, hi := pv.segs[0][0], pv.segs[0][0]
    for sg in pv.segs { lo, hi = la.min(lo, sg[0], sg[1]), la.max(hi, sg[0], sg[1]) }
    dist := la.length(la.clamp(eye, lo, hi) - eye)
    alpha := u8(clamp(200 - dist * 2, 70, 200))
    col := [3]u8{255, 250, 240}
    if gs.build.tool != .Block || drag_showing(gs) {
        col = pv.fill ? [3]u8{255, 250, 240} : CLEAR_COL
        if pv.too_big { col = {255, 180, 60} }
        alpha = max(alpha, 150)
    }
    r := gs.ui.renderer_data.renderer
    SDL.SetRenderDrawBlendMode(r, {.BLEND})
    // The faint carve and cursor outlines first, then the main one (a dark
    // line under a light one), then the area's pushed face.
    for pass in 0 ..< 5 {
        segs: [dynamic][2][3]f32
        switch pass {
        case 0:
            segs = pv.carve
            SDL.SetRenderDrawColor(r, CLEAR_COL.r, CLEAR_COL.g, CLEAR_COL.b, u8(f32(alpha) * 0.6))
        case 1:
            segs = pv.cursor
            SDL.SetRenderDrawColor(r, 255, 250, 240, u8(f32(alpha) * 0.5))
        case 2:
            segs = pv.segs
            SDL.SetRenderDrawColor(r, 0, 0, 0, alpha / 2)
        case 3:
            segs = pv.segs
            SDL.SetRenderDrawColor(r, col.r, col.g, col.b, alpha)
        case 4:
            segs = pv.face
            SDL.SetRenderDrawColor(r, u8(COLOR_ACCENT.r), u8(COLOR_ACCENT.g), u8(COLOR_ACCENT.b), alpha)
        }
        for sg in segs {
            view_line(r, sg[0] - eye, sg[1] - eye, fwd, right, up, w, h, pass == 2 ? 1 : 0, pass >= 3)
        }
    }
}

// ─── Building tools (build_tools.odin) ─────────────────────────────────────

// The tool panel, bottom left: the three tools (T), the shape (Q), and each
// setting with the key that changes it. The row the wheel changes right now,
// by the modifiers held, is lit; with a combo that does nothing, none is.
@(private="file")
build_hud_layout :: proc(gs: ^Game_State, w: f32) {
    b := &gs.build
    live := wheel_target(b.tool, held_mods())
    walls := b.wall == 0 ? "solid" : fmt.tprintf("%d thick", b.wall)
    lift: f32 = w < 1240 ? -86 : -14 // over the hotbar when they'd overlap
    if clay.UI(clay.ID("BuildTool"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(9), childGap = 5, sizing = {clay.SizingFixed(232), clay.SizingFit()}},
        floating = anchored(.LeftBottom, {14, lift}),
        custom = deco(.Glass_Soft, radius = 10),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 3, childAlignment = {y = .Center}}}) {
            for t in Build_Tool { tool_tab(build_tool_name(t), t == b.tool) }
            spacer()
            keycap("T")
        }
        switch b.tool {
        case .Block:
            param_row("Brush", b.box ? "box" : gs.brush_radius == 0 ? "1 block" : fmt.tprintf("radius %d", gs.brush_radius), "B", live == .Brush)
            if b.box { hint("hold and drag: a box (floor, wall)") }
        case .Magic:
            s := magic_spell_size(gs)
            param_row("Spell", b.box ? "box" : s == 0 ? "1 block" : fmt.tprintf("radius %d", s), "B", live == .Brush)
            hint("hold left: unweave   right: conjure")
            if b.box { hint("hold and drag: a box (floor, wall)") }
        case .Area:
            param_row("Cursor", build_cursor_name(b.cursor), "C", false)
            if b.cursor == .Air { param_row("Reach", fmt.tprintf("%d", b.air_dist), "Alt", live == .Distance) }
            if b.selected {
                r := area_region(b)
                d := r.hi - r.lo + 1
                vol := region_volume(r)
                param_row("Size", fmt.tprintf("%d × %d × %d", d.x, d.y, d.z), "Wheel", live == .Push)
                if vol > MAX_EDIT_VOXELS {
                    hint(fmt.tprintf("too big: %s of %s blocks", thousands(vol), thousands(MAX_EDIT_VOXELS)))
                } else {
                    hint(fmt.tprintf("%s blocks; wheel pushes the lit face", thousands(vol)))
                }
                param_row("Move", "via lit face", "Shift", live == .Move)
            }
            param_row("Walls", walls, "Ctrl", live == .Walls)
            param_row("Fill", build_mask_name(b.mask), "V", false)
            if b.selected {
                if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {4, 0, 2, 0}, childGap = 5, childAlignment = {y = .Center}}}) {
                    keycap("F")
                    text("fill", COLOR_TEXT_DIM, 11)
                    keycap("X")
                    text("clear", COLOR_TEXT_DIM, 11)
                    spacer()
                    keycap("Bksp")
                    text("drop", COLOR_TEXT_DIM, 11)
                }
            } else {
                hint("L / R click: set the box's two corners")
            }
        case .Shape:
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 2, childAlignment = {y = .Center}}}) {
                for sh in Build_Shape {
                    if clay.UI()({layout = {sizing = {clay.SizingFixed(25), clay.SizingFixed(25)}},
                        custom = deco(sh == b.shape ? .Shape_Icon_On : .Shape_Icon, radius = 5, shape = sh)}) {}
                }
                spacer()
                keycap("Q")
            }
            param_row("Shape", build_shape_name(b.shape), "", false)
            param_row("Size", fmt.tprintf("%d", 2 * b.size + 1), "Wheel", live == .Size)
            param_row("Height", fmt.tprintf("%d", 2 * b.height + 1), "Shift", live == .Height)
            param_row("Walls", walls, "Ctrl", live == .Walls)
            param_row("Turn", fmt.tprintf("%d°", b.yaw), "Alt", live == .Turn)
            param_row("Fill", build_mask_name(b.mask), "V", false)
            hint("L carve (hold to drill), R place")
        }
        if len(b.undo) > 0 || len(b.redo) > 0 {
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {4, 0, 2, 0}, childGap = 5, childAlignment = {y = .Center}}}) {
                keycap("Ctrl Z")
                text(fmt.tprintf("undo %d", len(b.undo)), len(b.undo) > 0 ? COLOR_TEXT_DIM : COLOR_TEXT_FAINT, 11)
                spacer()
                keycap("Ctrl Y")
                text(fmt.tprintf("redo %d", len(b.redo)), len(b.redo) > 0 ? COLOR_TEXT_DIM : COLOR_TEXT_FAINT, 11)
            }
        }
    }
}

// 1234567 -> "1,234,567".
thousands :: proc(n: int) -> string {
    s := fmt.tprintf("%d", abs(n))
    out := make([dynamic]u8, 0, len(s) + len(s) / 3 + 1, context.temp_allocator)
    if n < 0 { append(&out, '-') }
    for i in 0 ..< len(s) {
        if i > 0 && (len(s) - i) % 3 == 0 { append(&out, ',') }
        append(&out, s[i])
    }
    return string(out[:])
}

// A key as a small cap: "Ctrl", "Wheel", "T". Lit while it's what the wheel uses.
keycap :: proc(label: string, hot := false) {
    if label == "" { return }
    if clay.UI()({
        layout = {padding = {5, 5, 2, 3}, sizing = {clay.SizingFit({min = 18}), clay.SizingFit()}, childAlignment = {x = .Center}},
        backgroundColor = hot ? {COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 56} : {255, 255, 255, 10},
        cornerRadius = clay.CornerRadiusAll(4),
        border = {hot ? COLOR_ACCENT : {COLOR_TEXT_DIM.r, COLOR_TEXT_DIM.g, COLOR_TEXT_DIM.b, 80}, clay.BorderOutside(1)},
    }) {
        text(label, hot ? COLOR_ACCENT : COLOR_TEXT_DIM, 10, FONT_ID_TITLE)
    }
}

// One setting: name, value, and the key that changes it; lit while it's live.
@(private="file")
param_row :: proc(name, value, key: string, live: bool) {
    if clay.UI()({
        layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(23)}, padding = {6, 3, 0, 0}, childGap = 7, childAlignment = {y = .Center}},
        backgroundColor = live ? {COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 30} : {},
        cornerRadius = clay.CornerRadiusAll(5),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingFixed(2), clay.SizingFixed(12)}},
            backgroundColor = live ? COLOR_ACCENT : {}, cornerRadius = clay.CornerRadiusAll(1)}) {}
        if clay.UI()({layout = {sizing = {clay.SizingFixed(46), clay.SizingFit()}}}) {
            text(name, live ? COLOR_TEXT : COLOR_TEXT_DIM, 12)
        }
        text(value, live ? COLOR_ACCENT : COLOR_TEXT, 13, FONT_ID_TITLE)
        spacer()
        keycap(key, live)
    }
}

@(private="file")
tool_tab :: proc(label: string, on: bool) {
    if clay.UI()({
        layout = {padding = {9, 9, 4, 5}},
        backgroundColor = on ? COLOR_BUTTON : {},
        cornerRadius = clay.CornerRadiusAll(5),
        border = on ? {COLOR_ACCENT, clay.BorderOutside(1)} : {},
    }) {
        text(label, on ? COLOR_ACCENT : COLOR_TEXT_DIM, 12, FONT_ID_TITLE)
    }
}

hint :: proc(s: string) {
    if clay.UI()({layout = {padding = {6, 0, 1, 0}}}) { text(s, COLOR_TEXT_FAINT, 11) }
}

// Key, then what it does.
key_row :: proc(key, what: string, a: f32 = 1, key_width: f32 = 92) {
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8, childAlignment = {y = .Center}}}) {
        if clay.UI()({layout = {sizing = {clay.SizingFixed(key_width), clay.SizingFit()}}}) {
            text(key, fade(COLOR_TEXT, a), 13, FONT_ID_TITLE)
        }
        text(what, fade(COLOR_TEXT_DIM, a), 13)
    }
}

// The controls card (H), on the right.
@(private="file")
help_card :: proc(gs: ^Game_State, a: f32) {
    if clay.UI(clay.ID("Help"))({
        layout = {layoutDirection = .TopToBottom, padding = {16, 16, 14, 14}, childGap = 4, sizing = {clay.SizingFixed(262), clay.SizingFit()}},
        floating = anchored(.RightCenter, {-14, 0}),
        custom = deco(.Glass_Soft, alpha = a),
    }) {
        heading("Controls", a)
        key_row("WASD", "move", a)
        key_row("Ctrl / W W", "sprint", a)
        key_row("Shift", "sneak", a)
        if gs.survival {
            key_row("Space", "jump", a)
            key_row("Hold left", "unweave a block", a)
            key_row("Right click", "conjure a block", a)
            key_row("Middle click", "pick block", a)
            key_row("1-9, wheel", "hotbar", a)
            key_row("E", "what you carry, crafting", a)
            key_row("B", "box: drag many at once", a)
        } else {
            key_row("Space", "jump; twice to fly", a)
            key_row("Left click", "break", a)
            key_row("Right click", "place", a)
            key_row("Middle click", "pick block", a)
            key_row("1-9, wheel", "hotbar", a)
            key_row("E", "all blocks", a)
            key_row("T", "block / magic / area / shape", a)
            key_row("B", "brush: one / box / size", a)
            key_row("Ctrl Z / Y", "undo / redo", a)
        }
        key_row("G", "hang glider", a)
        key_row("R", gs.survival ? "fight: fists, or what you've made" : "fight: weapon bar", a)
        key_row("F5", "camera", a)
        key_row("F1 / F3", "hide HUD / debug", a)
        key_row("F2", "screenshot", a)
        key_row("M", "mute", a)
        key_row("Esc", "menu", a)
        text(gs.ui.help_open ? "H to hide" : "H shows this again", fade(COLOR_TEXT_FAINT, a), 12)
    }
}

@(private="file")
debug_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui
    if clay.UI(clay.ID("Debug"))({
        layout = {layoutDirection = .TopToBottom, padding = {14, 14, 12, 12}, childGap = 2},
        floating = anchored(.RightTop, {-14, 14}),
        custom = deco(.Glass_Soft),
    }) {
        line :: proc(k, v: string) {
            if clay.UI()({layout = {childGap = 8}}) {
                if clay.UI()({layout = {sizing = {clay.SizingFixed(74), clay.SizingFit()}}}) { text(k, COLOR_TEXT_DIM, 13) }
                text(v, COLOR_TEXT, 13)
            }
        }
        heading("Debug (F3)")
        line("fps", fmt.tprintf("%.1f  (%.2f ms)", ui.fps, ui.frame_ms))
        // Ray tracing alone, and its share of a 60 fps frame: the headroom.
        line("gpu", gs.gpu_ms > 0 ? fmt.tprintf("%.2f ms  (%.0f%% of 60 fps)", gs.gpu_ms, gs.gpu_ms / (1000.0 / 60.0) * 100) : "...")
        p := gs.camera.pos
        line("pos", fmt.tprintf("%.1f  %.1f  %.1f", p.x, p.y, p.z))
        line("look", fmt.tprintf("yaw %.0f  pitch %.0f", gs.camera.yaw, gs.camera.pitch))
        line("chunk", fmt.tprintf("%d  %d  %d", gs.player_chunk.x, gs.player_chunk.y, gs.player_chunk.z))
        if hit, nrm, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), REACH); ok {
            b := Block_Type(u8(get_voxel(gs, hit.x, hit.y, hit.z)))
            line("target", fmt.tprintf("%s  %d %d %d", block_name(b), hit.x, hit.y, hit.z))
            // The light in front of the face looked at, as the CPU holds it
            // and as the GPU will read it (light.odin light_probe).
            if pr, pok := light_probe(gs, hit + nrm); pok {
                line("light", fmt.tprintf("sky %d  block %d  %s%s", pr.sky, pr.blk, pr.per_voxel ? "per voxel" : "one value",
                    pr.queued ? "  UNSTITCHED" : ""))
                mismatch := !pr.gpu_brick && (pr.per_voxel || pr.gpu_sky != pr.sky)
                line("gpu light", fmt.tprintf("%s%s%s%s", pr.gpu_brick ? "brick" : fmt.tprintf("one value, sky %d", pr.gpu_sky),
                    pr.gpu_owned ? "" : "  NOT OWNED", pr.dirty ? "  upload pending" : "", mismatch ? "  MISMATCH" : ""))
            }
        }
        near := 0
        for k in gs.stitch_queue {
            d := k - gs.player_chunk.xz
            if d.x * d.x + d.y * d.y <= LIGHT_STITCH_NEAR * LIGHT_STITCH_NEAR { near += 1 }
        }
        line("stitch", fmt.tprintf("%d queued, %d near   F9 relight here", len(gs.stitch_queue), near))
        pool_line :: proc(name: string, p: Brick_Pool, waiting, brick_bytes: int) {
            cap := len(p.free_ids)
            used := cap - p.free_top
            line(name, fmt.tprintf("%d of %d (%.0f%%, %d MB)%s", used, cap, 100 * f32(used) / f32(max(cap, 1)), cap * brick_bytes >> 20,
                waiting > 0 ? fmt.tprintf("  %d WAITING", waiting) : ""))
        }
        pool_line("voxel mem", gs.brick_pool, len(gs.brick_starved), VOXELS_PER_BRICK + MASK_U32_PER_BRICK * 4)
        pool_line("light mem", gs.light_pool, len(gs.light_starved), LIGHT_BRICK_BYTES)
        line("columns", fmt.tprintf("%d loaded, %d pending", len(gs.columns), worker_pool_pending_count(&gs.pool)))
        line("entities", fmt.tprintf("%d drawn", gs.entity_count))
        if !gs.gi.enabled {
            line("bounce", "off")
        } else {
            gi := &gs.gi
            waiting := 0
            for s in gi.queue { waiting += int(gi.pending[s]) }
            line("bounce", fmt.tprintf("probes %.2f ms, %d + %d a frame, %d waiting, %.0f%% buried",
                gi.ms, GI_PER_FRAME, gi.listed, waiting, 100 * gi.buried))
        }
        line("torches", gs.torch.enabled ? fmt.tprintf("%d casting shadows%s", gs.torch.count,
            gs.torch.found > gs.torch.count ? fmt.tprintf(" (nearest of %d)", gs.torch.found) : "") : "shadows off")
        line("render", fmt.tprintf("%dx%d (%.0f%%)  aa%d  %s", gs.render_w, gs.render_h, gs.render_scale * 100, gs.aa_samples, gs.shadow_rays == 1 ? "hard" : "soft"))
        line("cave", fmt.tprintf("%.2f", gs.cave_factor))
        alive := 0
        for sl in gs.slimes.list { if sl.alive { alive += 1 } }
        line("slimes", fmt.tprintf("%d   F6 spawn, F7 clear", alive))
        en_alive := 0
        for e in gs.enemies.list { if e.alive { en_alive += 1 } }
        line("enemies", fmt.tprintf("%d   F8 spawn", en_alive))
    }
}

// ─── Hang glider ───────────────────────────────────────────────────────────

// A small marker floating at screen position (x, y).
@(private="file")
hud_marker :: proc(id: string, x, y, size: f32, color: clay.Color, filled: bool) {
    if clay.UI(clay.ID(id))({
        layout   = {sizing = {clay.SizingFixed(size), clay.SizingFixed(size)}},
        floating = {
            attachTo = .Root, offset = {x - size * 0.5, y - size * 0.5}, zIndex = 5,
            attachment = {element = .LeftTop, parent = .LeftTop},
            pointerCaptureMode = .Passthrough,
        },
        backgroundColor = filled ? color : {},
        cornerRadius    = clay.CornerRadiusAll(size * 0.5),
        border          = filled ? {} : {color = color, width = {2, 2, 2, 2, 0}},
    }) {}
}

// Hang glider: no instruments; the flight shows in the world (the wind's
// rush and the FOV for speed, the buffet and the cloth's flutter for a
// stall, the seat's kick for lift, the wing lifting toward a thermal). Only
// while Ctrl looks around: a ring where the glider is being steered.
glider_hud_layout :: proc(gs: ^Game_State, w, h: f32) {
    g := &gs.glider
    if !g.deployed || abs(g.look_yaw) + abs(g.look_pitch) < 3 { return }
    aim := camera_forward(Camera{yaw = g.aim_yaw, pitch = g.aim_pitch})
    if x, y, ok := glider_project(gs.camera, aim, w, h); ok {
        hud_marker("GliderAim", x, y, 18, {255, 250, 240, 200}, false)
    }
}

// ─── Pause menu ────────────────────────────────────────────────────────────

button :: proc(id: clay.ElementId, label: string, selected := false, width: f32 = 0, danger := false, height: f32 = 32) -> (clicked: bool) {
    hovered := clay.PointerOver(id)
    d: Ui_Deco = selected ? (hovered ? .Button_On_Hover : .Button_On) : (hovered ? .Button_Hover : .Button)
    if clay.UI(id)({
        layout = {
            sizing = {width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(), clay.SizingFixed(height)},
            padding = {10, 10, 0, 0},
            childAlignment = {x = .Center, y = .Center},
        },
        custom = deco(d, radius = 7),
    }) {
        col := selected ? COLOR_ACCENT : (danger ? COLOR_BAD : COLOR_TEXT)
        text(label, col, 14, FONT_ID_TITLE)
    }
    clicked = hovered && gs_ui_left_pressed()
    if clicked { play(.Click, 0.4) }
    return
}

// A settings row: `if clay.UI()(setting_row()) { row_label("..."); control }`.
setting_row :: proc() -> clay.ElementDeclaration {
    return {layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 12, childAlignment = {y = .Center}}}
}

row_label :: proc(label: string) {
    if clay.UI()({layout = {sizing = {clay.SizingFixed(130), clay.SizingFit()}}}) {
        text(label, COLOR_TEXT, 15)
    }
}

// A row of buttons, one selected. Returns the clicked index or -1.
segmented :: proc(id: string, labels: []string, selected: int) -> int {
    clicked := -1
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
        for l, i in labels {
            if button(clay.ID(id, u32(i)), l, i == selected) { clicked = i }
        }
    }
    return clicked
}

toggle :: proc(id: string, value: ^bool) {
    if i := segmented(id, {"On", "Off"}, value^ ? 0 : 1); i >= 0 { value^ = i == 0 }
}

// A one-line text box: click it to type; true when Enter is pressed in it.
text_field :: proc(gs: ^Game_State, id: clay.ElementId, f: ^Text_Field, placeholder: string, width: f32 = 0, height: f32 = 32) -> (submitted: bool) {
    ui := &gs.ui
    hovered := clay.PointerOver(id)
    if hovered { ui.field_hovered = true }
    if hovered && ui.mouse_left_pressed { ui_type_into(gs, f) }
    focused := ui.typing == f
    d: Ui_Deco = focused ? .Button_On : (hovered ? .Button_Hover : .Button)
    if clay.UI(id)({
        layout = {
            sizing = {width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(), clay.SizingFixed(height)},
            padding = {10, 10, 0, 0},
            childAlignment = {y = .Center},
        },
        custom = deco(d, radius = 7),
    }) {
        s := string(f.buf[:f.len])
        caret := focused && (SDL.GetTicks() / 500) % 2 == 0
        if f.len == 0 && !focused {
            text(placeholder, COLOR_TEXT_FAINT, 14)
        } else {
            text(caret ? fmt.tprintf("%s|", s) : fmt.tprintf("%s ", s), COLOR_TEXT, 14)
        }
    }
    submitted = f.submit
    f.submit = false
    return
}

// A draggable slider; t is value's 0..1 position. Returns whether it changed.
slider :: proc(gs: ^Game_State, id: clay.ElementId, t: ^f32, label: string) -> (changed: bool) {
    ui := &gs.ui
    knob_id := clay.ID("Knob", id.id)
    hovered := clay.PointerOver(id) || clay.PointerOver(knob_id)
    if ui.mouse_left_pressed && hovered { ui.dragging = id.id }
    active := ui.dragging == id.id
    if active {
        if !ui.mouse_left_down {
            ui.dragging = 0
        } else if bb := clay.GetElementData(id).boundingBox; bb.width > 0 {
            v := clamp((ui.mouse_pos.x - bb.x) / bb.width, 0, 1)
            changed = v != t^
            t^ = v
        }
    }
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 10, childAlignment = {y = .Center}}}) {
        if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(26)}, childAlignment = {y = .Center}}}) {
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(6)}}, backgroundColor = COLOR_BAR_BG, cornerRadius = clay.CornerRadiusAll(3)}) {
                if clay.UI()({layout = {sizing = {clay.SizingPercent(clamp(t^, 0, 1)), clay.SizingGrow()}},
                    backgroundColor = COLOR_ACCENT, cornerRadius = clay.CornerRadiusAll(3)}) {
                    hot := active || hovered
                    k: f32 = hot ? 18 : 15
                    if clay.UI(knob_id)({
                        layout = {sizing = {clay.SizingFixed(k), clay.SizingFixed(k)}},
                        floating = {attachTo = .Parent, clipTo = .AttachedParent, zIndex = 25, attachment = {element = .CenterCenter, parent = .RightCenter}}, // hidden with its row when the menu scrolls it away
                        custom = deco(hot ? .Button_On_Hover : .Button_On, radius = k / 2),
                    }) {}
                }
            }
        }
        if clay.UI()({layout = {sizing = {clay.SizingFixed(56), clay.SizingFit()}, childAlignment = {x = .Right}}}) {
            text(label, COLOR_TEXT_DIM, 14)
        }
    }
    return
}

// A full-screen layer that dims the world and takes the pointer.
shade :: proc(id: string, a: f32 = 130) {
    if clay.UI(clay.ID(id))({
        layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
        floating = {attachTo = .Root, zIndex = 15, pointerCaptureMode = .Capture},
        backgroundColor = {8, 10, 16, a},
    }) {}
}

menu_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui
    // A click anywhere but a text box stops typing (last frame's layout
    // says what was under the pointer).
    if ui.mouse_left_pressed && !ui.field_hovered { ui_type_into(gs, nil) }
    ui.field_hovered = false
    shade("MenuShade")
    if clay.UI(clay.ID("Menu"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(22), childGap = 12, sizing = {clay.SizingFixed(menu_width(gs)), clay.SizingFit({max = max(ui.screen_h - 32, 200)})}},
        floating = {attachTo = .Root, zIndex = 20, attachment = {.CenterCenter, .CenterCenter}, pointerCaptureMode = .Capture},
        custom = deco(.Glass, radius = 12),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Bottom}}}) {
            text(game_paused(gs) ? "Paused" : "Menu", COLOR_ACCENT, 28, FONT_ID_TITLE)
            spacer()
            p := gs.camera.pos
            text(fmt.tprintf("%s   %d m", biome_name(ui.biome), int(p.y - PLAYER_EYE_HEIGHT)), COLOR_TEXT_DIM, 14)
        }
        if i := segmented("Tab", {"Graphics", "Sound", "Controls", "Multiplayer"}, int(ui.menu_tab)); i >= 0 {
            ui.menu_tab = Menu_Tab(i)
        }
        divider()

        // The tab's settings scroll when the window is too short for them.
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8}}) {
            body := clay.ID("MenuBody")
            if clay.UI(body)({
                layout = {layoutDirection = .TopToBottom, childGap = 12, sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                clip = {vertical = true, childOffset = clay.GetScrollOffset()},
            }) {
                switch ui.menu_tab {
                case .Graphics: menu_graphics(gs)
                case .Sound:    menu_sound(gs)
                case .Controls: menu_controls(gs)
                case .Multiplayer: menu_multiplayer(gs)
                }
            }
            scrollbar(gs, body)
        }

        divider()
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8}}) {
            if button(clay.ID("Resume"), "Resume") { ui_open(gs, .None) }
            if button(clay.ID("Character"), "Character") { character_open(gs) }
            if button(clay.ID("MainMenu"), "Main menu") { ui.menu_requested = true }
            if button(clay.ID("Quit"), gs.sandbox.on ? "Quit" : "Save and quit", danger = true) { ui.quit_requested = true }
        }
    }
}

@(private="file")
menu_graphics :: proc(gs: ^Game_State) {
    if clay.UI()(setting_row()) {
        row_label("Render scale")
        scales := [?]f32{1, 0.75, 0.5, 0.33, 0.25}
        cur := 0
        for s, i in scales { if abs(s - gs.render_scale) < 0.01 { cur = i } }
        if i := segmented("Rs", {"100%", "75%", "50%", "33%", "25%"}, cur); i >= 0 {
            gs.render_scale = scales[i] // applied next frame (gpu_fit_render_size)
        }
    }
    if clay.UI()(setting_row()) {
        row_label("Upscaling")
        if i := segmented("Up", {"Sharp", "Smooth"}, gs.upscale_smooth ? 1 : 0); i >= 0 {
            gs.upscale_smooth = i == 1
            if gs.ui.out_tex != nil { SDL.SetTextureScaleMode(gs.ui.out_tex, gs.upscale_smooth ? .LINEAR : .NEAREST) }
        }
    }
    if clay.UI()(setting_row()) {
        row_label("Field of view")
        fovs := [?]f32{60, 70, 80, 90}
        cur := 1
        for f, i in fovs { if gs.camera.fov == f { cur = i } }
        if i := segmented("Fov", {"60", "70", "80", "90"}, cur); i >= 0 { gs.camera.fov = fovs[i] }
    }
    if clay.UI()(setting_row()) {
        row_label("Anti-aliasing")
        if i := segmented("AA", {"1x", "2x", "4x"}, gs.aa_samples == 1 ? 0 : (gs.aa_samples == 2 ? 1 : 2)); i >= 0 {
            gs.aa_samples = i32(1) << uint(i)
        }
    }
    if clay.UI()(setting_row()) {
        row_label("Shadows")
        if i := segmented("Sh", {"Hard", "Soft"}, gs.shadow_rays == 1 ? 0 : 1); i >= 0 { gs.shadow_rays = i == 0 ? 1 : 3 }
    }
    if clay.UI()(setting_row()) {
        row_label("God rays")
        toggle("Vol", &gs.vol_enabled)
    }
    if gs.vol_enabled {
        if clay.UI()(setting_row()) {
            row_label("God ray steps")
            if i := segmented("Vs", {"16", "24", "32"}, int(gs.vol_steps / 8) - 2); i >= 0 { gs.vol_steps = i32(16 + 8 * i) }
        }
    }
    if clay.UI()(setting_row()) {
        row_label("Bounce light")
        toggle("GI", &gs.gi.enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("Torch shadows")
        toggle("TSh", &gs.torch.enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("Thermal clouds")
        toggle("Cloud", &gs.clouds_enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("Creatures")
        toggle("Ent", &gs.entities_enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("View distance")
        radii := VIEW_RADII
        cur := 2
        for r, i in radii { if view_radius == r { cur = i } }
        if i := segmented("View", {"Short", "Medium", "Far"}, cur); i >= 0 { set_view_radius(gs, radii[i]) }
    }
    if clay.UI()(setting_row()) {
        row_label("Far terrain")
        toggle("Far", &gs.far_enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("Reflections")
        if i := segmented("Bnc", {"1", "2", "3", "4", "5"}, int(gs.reflect_amount) - 1); i >= 0 { gs.reflect_amount = i32(i + 1) }
    }
    // Time of day: dragging sets the clock; the toggle runs or stops it.
    // The clock is the host's: a guest's server ignores both.
    if !client_joined(gs) {
        if clay.UI()(setting_row()) {
            row_label("Time of day")
            t := gs.day.hour / 24
            hh, mm := day_clock(gs.day.hour)
            if slider(gs, clay.ID("Hour"), &t, fmt.tprintf("%02d:%02d", hh, mm)) {
                client_send(gs, .Set_Hour, clamp(t, 0, 0.999) * 24)
            }
        }
        if clay.UI()(setting_row()) {
            row_label("Day cycle")
            running := !gs.day.paused
            toggle("Day", &running)
            if running == gs.day.paused { client_send(gs, .Set_Paused, !running) }
        }
    }
    // Exposure 0.25..4 and haze (fog density 0.0003..0.006), both on log scales.
    if clay.UI()(setting_row()) {
        row_label("Exposure")
        t := math.ln(gs.exposure / 0.25) / math.ln(f32(16))
        if slider(gs, clay.ID("Exposure"), &t, fmt.tprintf("%.2f", gs.exposure)) { gs.exposure = 0.25 * math.pow(16, t) }
    }
    if clay.UI()(setting_row()) {
        row_label("Haze")
        t := math.ln(gs.fog_density / 0.0003) / math.ln(f32(20))
        if slider(gs, clay.ID("Fog"), &t, fmt.tprintf("%.0f%%", t * 100)) { gs.fog_density = 0.0003 * math.pow(20, t) }
    }
}

@(private="file")
menu_sound :: proc(gs: ^Game_State) {
    if clay.UI()(setting_row()) {
        row_label("Effects")
        if slider(gs, clay.ID("Effects"), &audio.effects, fmt.tprintf("%d%%", int(audio.effects * 100 + 0.5))) {
            // A taste of the new level, not too often while dragging.
            @(static) last: u64
            if now := SDL.GetTicks(); now - last > 90 {
                last = now
                play(.Step_Grass, 0.6, vary())
            }
        }
    }
    if clay.UI()(setting_row()) {
        row_label("Ambience")
        slider(gs, clay.ID("Ambience"), &audio.ambience, fmt.tprintf("%d%%", int(audio.ambience * 100 + 0.5)))
    }
    if clay.UI()(setting_row()) {
        row_label("Sound")
        on := !audio.muted
        toggle("Snd", &on)
        audio.muted = !on
    }
    if audio_missing() { text("No audio device found.", COLOR_BAD, 13) }
}

// Open this game to others, or join someone else's (session.odin).
@(private="file")
menu_multiplayer :: proc(gs: ^Game_State) {
    ui := &gs.ui
    n := &gs.net
    if clay.UI()(setting_row()) {
        row_label("Your name")
        text_field(gs, clay.ID("Name"), &ui.name_field, "Player")
    }
    divider()
    if client_joined(gs) {
        address := string(n.address[:n.address_len])
        if n.welcomed {
            text(fmt.tprintf("Playing on %s as player %d", address, n.slot), COLOR_TEXT, 15)
            others := 0
            for o in n.others { if o.active { others += 1 } }
            text(others == 0 ? "Nobody else here right now." : fmt.tprintf("%d other player%s here.", others, others == 1 ? "" : "s"), COLOR_TEXT_DIM, 13)
        } else if n.host != nil {
            text(fmt.tprintf("Connecting to %s...", address), COLOR_TEXT, 15)
        } else {
            text(fmt.tprintf("Not connected to %s.", address), COLOR_BAD, 15)
        }
        if n.no_build { text("The host has turned off building for visitors.", COLOR_TEXT_DIM, 13) }
        if n.away {
            if button(clay.ID("Leave"), "Leave: back to the main menu") { ui.menu_requested = true }
        } else if button(clay.ID("Leave"), "Leave: back to your own world") { session_leave(gs) }
        return
    }

    // Host.
    hosting := session_hosting(gs)
    heading("Host")
    if clay.UI()(setting_row()) {
        row_label("Port")
        if hosting {
            text(fmt.tprintf("%d", int(gs.server.host.address.port)), COLOR_TEXT, 15)
            spacer()
            if button(clay.ID("Close"), "Close to others", width = 160) { session_stop_hosting(gs) }
        } else {
            text_field(gs, clay.ID("Port"), &ui.port_field, "47100", width = 90)
            if button(clay.ID("Open"), "Open to others", width = 160) {
                port := ui.port_field.len == 0 ? NET_PORT : 0
                for c in ui.port_field.buf[:ui.port_field.len] {
                    if c < '0' || c > '9' || port > 65535 { port = -1; break }
                    port = port * 10 + int(c - '0')
                }
                if port <= 0 || port > 65535 {
                    ui_toast(gs, "The port is a number from 1 to 65535", 3)
                } else if !session_host(gs, port) {
                    ui_toast(gs, fmt.tprintf("Couldn't open port %d", port), 3)
                }
            }
        }
    }
    if session_hosting(gs) { // (not `hosting`: Close may have just shut it)
        joined := 0
        for p, slot in gs.players { if p.active && slot != gs.server.local_player { joined += 1 } }
        text(joined == 0 ? "Open. Nobody has joined yet." : fmt.tprintf("Open. %d player%s joined.", joined, joined == 1 ? "" : "s"), COLOR_ACCENT, 13)
        text(fmt.tprintf("Friends join with your public IP address: forward UDP port %d on your router to this PC.", int(gs.server.host.address.port)), COLOR_TEXT_FAINT, 12)
        if clay.UI()(setting_row()) {
            row_label("Visitors build")
            build := gs.server.guests_build
            toggle("GuestBuild", &build)
            server_set_guests_build(&gs.server, build)
        }
        // Whoever's here, each with a way to send them off.
        for p, slot in gs.players {
            if !p.active || slot == gs.server.local_player { continue }
            if clay.UI(clay.ID("Visitor", u32(slot)))(setting_row()) {
                if clay.UI()({layout = {sizing = {clay.SizingFixed(10), clay.SizingFixed(10)}},
                    backgroundColor = {player_tint(gs, slot).r * 255, player_tint(gs, slot).g * 255, player_tint(gs, slot).b * 255, 255}, cornerRadius = clay.CornerRadiusAll(5)}) {}
                text(client_player_name(gs, slot), COLOR_TEXT, 15)
                spacer()
                if gs.server.kicked[slot] {
                    text("leaving...", COLOR_TEXT_DIM, 13)
                } else if button(clay.ID("Kick", u32(slot)), "Remove", width = 100, danger = true) {
                    server_kick(&gs.server, slot)
                }
            }
        }
    }

    divider()
    // Join.
    heading("Join")
    if clay.UI()(setting_row()) {
        row_label("Address")
        submit := text_field(gs, clay.ID("Address"), &ui.join_field, "203.0.113.7 or host:47100")
        if button(clay.ID("Join"), "Join", width = 90) || submit {
            address := string(ui.join_field.buf[:ui.join_field.len])
            if len(address) == 0 {
                ui_toast(gs, "Type the address to join first", 3)
            } else if session_join(gs, address) {
                ui_open(gs, .None)
            } else {
                ui_toast(gs, fmt.tprintf("Couldn't join %s", address), 3)
            }
        }
    }
}

// The menu is wider on the controls tab: its key lists sit in columns.
@(private="file")
menu_width :: proc(gs: ^Game_State) -> f32 {
    if gs.ui.menu_tab != .Controls { return 500 }
    return controls_columns(gs) == 3 ? 980 : 760
}

@(private="file")
controls_columns :: proc(gs: ^Game_State) -> int { return gs.ui.screen_w >= 1040 ? 3 : 2 }

@(private="file")
menu_controls :: proc(gs: ^Game_State) {
    Group :: struct { title: string, keys: []string }
    group :: proc(g: Group) {
        if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 3}}) {
            heading(g.title)
            for i := 0; i + 1 < len(g.keys); i += 2 {
                key_row(g.keys[i], g.keys[i + 1], 1, 108)
            }
        }
    }
    moving   := Group{"Moving", {"WASD", "move", "Ctrl  or  W W", "sprint", "Shift", "sneak: quiet, hard to spot, won't fall off", "Space", "jump; hold to swim up", "Space twice", "fly: Shift down, Alt fast"}}
    building := Group{"Building", {"L / R click", "break / place; hold repeats", "Middle click", "pick the block you look at", "1-9, wheel", "hotbar", "E", gs.survival ? "inventory, crafting" : "all blocks", "B, Ctrl+wheel", "brush: one block, box (drag), size", "T", "tool: block / area / shape", "Ctrl Z / Ctrl Y", "undo / redo"}}
    tools    := Group{"Area and shape", {"Area: L / R", "the box's two corners", "Area: F / X", "fill / clear the box", "C", "area cursor: block / face / air", "Shape: L / R", "carve (hold: drill) / place", "Q", "next shape", "Wheel", "push lit face; shape size", "Shift+wheel", "move box; shape height", "Alt+wheel", "air reach; turn shape", "Ctrl+wheel", "walls (0 = solid)", "V", "fill: all / air / paint", "Shift+T, Q, V, C", "cycle back"}}
    fighting := Group{"Fighting", {"R", "weapon bar / back to building", "1-4, wheel", "weapon (empty: fists)", "L click (hold)", "combo; juggle in the air", "Look down + L", "plunge, from up high", "R click", "rising slash, uppercut", "Shift", "dodge roll", "F (hold)", "guard; parry just in time"}}
    gliding  := Group{"Gliding", {"G", "equip the glider", "Space in the air", "open / let go", "W/S, A/D", "speed, lean", "Ctrl", "look around"}}
    other    := Group{"Other", {"Enter", "chat", "Tab (hold)", "players", "F5", "camera view", "F1 / F3", "hide HUD / debug", "F2", "screenshot", "H", "controls card", "M", "mute", "L (hold)", "sun follows your view", "F6 / F8 / F7", "slime / enemy / clear (debug)", "F4", "sound board (debug)"}}
    cols := controls_columns(gs) == 3 ? [][]Group{{moving, building}, {tools, gliding}, {fighting, other}} : [][]Group{{moving, building, fighting}, {tools, gliding, other}}
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 22}}) {
        for col in cols {
            if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 12}}) {
                for g in col { group(g) }
            }
        }
    }
}

// ─── Inventory (E) ─────────────────────────────────────────────────────────

// Creative: every block and weapon, the hotbar and the weapon bar under
// them. Click a block (a weapon) to put it in the selected hotbar (weapon)
// slot; click a slot to select it. Survival's is its own (survival_inventory).
inventory_layout :: proc(gs: ^Game_State) {
    if gs.survival {
        survival_inventory(gs)
        return
    }
    ui := &gs.ui
    shade("InvShade", 100)
    hovered_block := Block_Type.Air
    hovered_weapon: Maybe(Weapon)
    SLOT :: 46
    if clay.UI(clay.ID("Inventory"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 10},
        floating = {attachTo = .Root, zIndex = 20, attachment = {.CenterCenter, .CenterCenter}, pointerCaptureMode = .Capture},
        custom = deco(.Glass, radius = 12),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Bottom}}}) {
            text(gs.survival ? "Carried" : "Blocks", COLOR_ACCENT, 24, FONT_ID_TITLE)
        }
        carried := 0
        for _, b in gs.items { if items_shown(gs, b) > 0 { carried += 1 } }
        if gs.survival && carried == 0 { text("Nothing yet: hold left on a block to unweave it", COLOR_TEXT_DIM, 14) }
        n := 0
        if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 5}}) {
            for n < len(Block_Type) {
                if clay.UI()({layout = {childGap = 5}}) {
                    for col := 0; col < 9 && n < len(Block_Type); n += 1 {
                        b := Block_Type(n)
                        if b == .Air || b == .Water || (gs.survival && items_shown(gs, b) == 0) { continue }
                        id := clay.ID("Inv", u32(n))
                        hov := clay.PointerOver(id)
                        if hov { hovered_block = b }
                        in_hand := b == gs.selected_block
                        if clay.UI(id)({
                            layout = {sizing = {clay.SizingFixed(SLOT), clay.SizingFixed(SLOT)}, childAlignment = {.Center, .Center}},
                            custom = deco(hov ? .Slot_Hover : (in_hand ? .Slot_On : .Slot), radius = 6),
                        }) {
                            if clay.UI()({layout = {sizing = {clay.SizingFixed(SLOT - 6), clay.SizingFixed(SLOT - 6)}}, custom = deco(.Block_Icon, b)}) {}
                            if gs.survival { item_count(gs, clay.ID("InvCount", u32(n)), items_shown(gs, b)) }
                        }
                        if hov && gs_ui_left_pressed() {
                            gs.hotbar[gs.hotbar_slot] = b
                            hotbar_select(gs, gs.hotbar_slot)
                            play(.Click, 0.4)
                        }
                        col += 1
                    }
                }
            }
        }
        heading("Weapons")
        if clay.UI()({layout = {childGap = 5}}) {
            for w in Weapon { // fists too: an empty slot
                id := clay.ID("InvWeaponPick", u32(w))
                hov := clay.PointerOver(id)
                if clay.UI(id)({
                    layout = {sizing = {clay.SizingFixed(SLOT), clay.SizingFixed(SLOT)}, childAlignment = {.Center, .Center}},
                    custom = deco(hov ? .Slot_Hover : (w == gs.weapon_bar[gs.weapon_slot] ? .Slot_On : .Slot), radius = 6),
                }) {
                    if clay.UI()({layout = {sizing = {clay.SizingFixed(SLOT - 10), clay.SizingFixed(SLOT - 10)}}, custom = deco(.Weapon_Icon, weapon = w)}) {}
                }
                if hov { hovered_weapon = w }
                if hov && gs_ui_left_pressed() { weapon_put(gs, w) }
            }
        }
        divider()
        if clay.UI()({layout = {childGap = 24}}) {
            if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 8}}) {
                heading("Hotbar")
                if clay.UI()({layout = {childGap = 5}}) { hotbar_slots(gs, true) }
            }
            if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 8}}) {
                heading("Weapon bar (R)")
                if clay.UI()({layout = {childGap = 5}}) { weapon_slots(gs, true) }
            }
        }
    }
    // Tooltip by the pointer.
    w, on_weapon := hovered_weapon.?
    if hovered_block != .Air || on_weapon {
        if clay.UI(clay.ID("Tooltip"))({
            layout = {padding = {10, 10, 6, 8}},
            floating = {attachTo = .Root, offset = {ui.mouse_pos.x + 16, ui.mouse_pos.y - 30}, zIndex = 40,
                        attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
            custom = deco(.Tooltip, radius = 6),
        }) {
            text(on_weapon ? WEAPONS[w].name : block_name(hovered_block), COLOR_TEXT, 14, FONT_ID_TITLE)
        }
    }
}

// Weapon w (or fists) into the selected weapon slot; it's off any other.
@(private="file")
weapon_put :: proc(gs: ^Game_State, w: Weapon) {
    for &h, i in gs.weapon_bar { if h == w && i != gs.weapon_slot && w != .None { h = .None } }
    gs.weapon_bar[gs.weapon_slot] = w
    gs.combat.weapon = max(Weapon) // (so weapon_select takes it up even if it's the same)
    weapon_select(gs, gs.weapon_slot)
    play(.Click, 0.4)
}

// Survival's inventory: on the left what you carry, a list (not a grid):
// each block with its count, the weapons you've made and your fists; a
// click puts one in the selected slot. On the right everything you can
// make, by where it's made (by hand, at a workbench close by), what each
// takes and how much of it you have; Make makes one (crafting.odin). The
// hotbar and the weapon bar under both.
@(private="file")
survival_inventory :: proc(gs: ^Game_State) {
    ui := &gs.ui
    shade("InvShade", 100)
    ROW    :: 38
    LIST_W :: 300
    CRAFT_W :: 420
    list_h := clamp(ui.screen_h - 250, 140, 420)
    near := stations_near(gs)
    if clay.UI(clay.ID("Inventory"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12},
        floating = {attachTo = .Root, zIndex = 20, attachment = {.CenterCenter, .CenterCenter}, pointerCaptureMode = .Capture},
        custom = deco(.Glass, radius = 12),
    }) {
        if clay.UI()({layout = {childGap = 20}}) {
            // What you carry.
            if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 8, sizing = {clay.SizingFixed(LIST_W), clay.SizingFit()}}}) {
                text("Carried", COLOR_ACCENT, 22, FONT_ID_TITLE)
                if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 6}}) {
                    body := clay.ID("CarriedList")
                    if clay.UI(body)({
                        layout = {layoutDirection = .TopToBottom, childGap = 3, sizing = {clay.SizingGrow(), clay.SizingFit({max = list_h})}},
                        clip = {vertical = true, childOffset = clay.GetScrollOffset()},
                    }) {
                        any := false
                        for b in Block_Type {
                            n := items_shown(gs, b)
                            if n == 0 || b == .Air { continue }
                            any = true
                            on_bar := -1
                            for h, i in gs.hotbar { if h == b { on_bar = i } }
                            id := clay.ID("CarriedRow", u32(b))
                            list_row(id, ROW, b == gs.selected_block, on_bar, block_name(b), fmt.tprintf("%d", n), deco(.Block_Icon, b))
                            if clay.PointerOver(id) && gs_ui_left_pressed() {
                                gs.hotbar[gs.hotbar_slot] = b
                                hotbar_select(gs, gs.hotbar_slot)
                                play(.Click, 0.4)
                            }
                        }
                        if !any { text("Nothing yet: hold left on a block to unweave it", COLOR_TEXT_DIM, 13) }
                        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(4)}}}) {}
                        heading("Weapons")
                        for w in Weapon {
                            if !weapon_owned(gs, w) { continue }
                            on_bar := -1
                            for h, i in gs.weapon_bar { if h == w && w != .None { on_bar = i } }
                            id := clay.ID("WeaponRow", u32(w))
                            count := w != .None && gs.weapons[w] > 1 ? fmt.tprintf("%d", gs.weapons[w]) : ""
                            list_row(id, ROW, w == gs.weapon_bar[gs.weapon_slot], on_bar, WEAPONS[w].name, count,
                                deco(.Weapon_Icon, weapon = w, alpha = w == .None ? 0.7 : 1))
                            if clay.PointerOver(id) && gs_ui_left_pressed() { weapon_put(gs, w) }
                        }
                    }
                    scrollbar(gs, body)
                }
            }
            // What you can make.
            if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 8, sizing = {clay.SizingFixed(CRAFT_W), clay.SizingFit()}}}) {
                if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Bottom}}}) {
                    text("Crafting", COLOR_ACCENT, 22, FONT_ID_TITLE)
                    spacer()
                    if near[.Workbench] { text("at a workbench", COLOR_GOOD, 13) } else { text("by hand", COLOR_TEXT_DIM, 13) }
                }
                if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 6}}) {
                    body := clay.ID("CraftList")
                    if clay.UI(body)({
                        layout = {layoutDirection = .TopToBottom, childGap = 3, sizing = {clay.SizingGrow(), clay.SizingFit({max = list_h})}},
                        clip = {vertical = true, childOffset = clay.GetScrollOffset()},
                    }) {
                        for s in Station {
                            heading(s == .Hand ? "By hand" : "At a workbench")
                            if !near[s] { text("Stand near a workbench to make these", COLOR_TEXT_FAINT, 12) }
                            for r, i in RECIPES {
                                if r.station == s { recipe_row(gs, i, near[s]) }
                            }
                            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(4)}}}) {}
                        }
                    }
                    scrollbar(gs, body)
                }
            }
        }
        divider()
        if clay.UI()({layout = {childGap = 24}}) {
            if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 8}}) {
                heading("Hotbar")
                if clay.UI()({layout = {childGap = 5}}) { hotbar_slots(gs, true) }
            }
            if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 8}}) {
                heading("Weapon bar (R)")
                if clay.UI()({layout = {childGap = 5}}) { weapon_slots(gs, true) }
            }
        }
        text("Click something carried to put it in the selected slot", COLOR_TEXT_FAINT, 12)
    }
}

// A row of the carried list: an icon in a slot, the name, which bar slot
// it's on (if any), how many. on: it's the selected slot's.
@(private="file")
list_row :: proc(id: clay.ElementId, h: f32, on: bool, on_bar: int, name, count: string, icon: clay.CustomElementConfig) {
    hov := clay.PointerOver(id)
    if clay.UI(id)({
        layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(h)}, padding = {4, 10, 2, 2}, childGap = 10, childAlignment = {y = .Center}},
        custom = deco(hov ? .Slot_Hover : (on ? .Slot_On : .Slot), radius = 5),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingFixed(h - 6), clay.SizingFixed(h - 6)}}, custom = icon}) {}
        text(name, COLOR_TEXT, 15)
        spacer()
        if on_bar >= 0 { text(fmt.tprintf("[%d]", on_bar + 1), COLOR_TEXT_FAINT, 12, FONT_ID_TITLE) }
        text(count, COLOR_TEXT, 15, FONT_ID_TITLE)
    }
}

// A recipe: what it makes and how many, what it takes (each in green if
// you have enough, red if not, with how many you have), and Make, lit only
// if you can make it here and now.
@(private="file")
recipe_row :: proc(gs: ^Game_State, i: int, here: bool) {
    r := RECIPES[i]
    can := here && recipe_affordable(&gs.items, r)
    a: f32 = here ? 1 : 0.45
    id := clay.ID("Recipe", u32(i))
    if clay.UI(id)({
        layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {4, 6, 4, 4}, childGap = 10, childAlignment = {y = .Center}},
        custom = deco(.Slot, radius = 5, alpha = a),
    }) {
        icon := r.weapon != .None ? deco(.Weapon_Icon, weapon = r.weapon, alpha = a) : deco(.Block_Icon, r.block, alpha = a)
        if clay.UI()({layout = {sizing = {clay.SizingFixed(34), clay.SizingFixed(34)}}, custom = icon}) {}
        if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 3, sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {
            title := r.count > 1 ? fmt.tprintf("%s  x%d", recipe_name(r), r.count) : recipe_name(r)
            text(title, fade(COLOR_TEXT, a), 15, FONT_ID_TITLE)
            if clay.UI()({layout = {childGap = 10}}) {
                for ing in r.needs {
                    have := ingredient_have(&gs.items, ing)
                    col := have >= ing.n ? COLOR_GOOD : COLOR_BAD
                    text(fmt.tprintf("%d %s (%d)", ing.n, ing.name, have), fade(col, a), 12)
                }
            }
        }
        if can {
            if button(clay.ID("Make", u32(i)), "Make", width = 64, height = 28) {
                if craft(gs, i) { play(.Pickup, 0.3, 1.2) } // it shows up in the list, and on a bar
            }
        } else {
            if clay.UI()({layout = {sizing = {clay.SizingFixed(64), clay.SizingFixed(28)}, childAlignment = {.Center, .Center}}}) {
                text(here ? "need more" : "", COLOR_TEXT_FAINT, 11)
            }
        }
    }
}

// A weapon, or fists, as a little picture: 12x12 cells from a pattern, a
// sword lying corner to corner tip up, in its own wood, stone or steel.
@(private="file")
draw_weapon_icon :: proc(r: ^SDL.Renderer, rect: SDL.FRect, w: Weapon, alpha: f32) {
    SWORD :: [12]string{
        "...........E",
        "..........BE",
        ".........BE.",
        "........BE..",
        ".......BE...",
        "..G...BE....",
        "...G.BE.....",
        "....G.......",
        "...H.G......",
        "..H...G.....",
        ".H..........",
        "P...........",
    }
    FIST :: [12]string{
        "............",
        "............",
        "...KKKKKK...",
        "..KkkkkkkK..",
        "..KkLkLkkK..",
        "..KkkkkkkKT.",
        "..KkkkkkkKT.",
        "..KkkkkkkKT.",
        "...KkkkkKT..",
        "....KKKK....",
        "....CCCC....",
        "............",
    }
    col :: proc(w: Weapon, ch: u8) -> (c: [3]u8, ok: bool) {
        switch w {
        case .None:
            switch ch {
            case 'K': return {70, 42, 26}, true
            case 'k': return {116, 72, 42}, true
            case 'L', 'T': return {156, 104, 62}, true
            case 'C': return {214, 162, 58}, true
            }
        case .Wooden_Sword:
            switch ch {
            case 'B': return {170, 126, 78}, true
            case 'E': return {116, 80, 48}, true
            case 'G', 'P': return {72, 48, 30}, true
            case 'H': return {104, 70, 44}, true
            }
        case .Stone_Sword:
            switch ch {
            case 'B': return {120, 122, 126}, true
            case 'E': return {170, 172, 176}, true
            case 'G': return {62, 42, 28}, true
            case 'H', 'P': return {116, 80, 48}, true
            }
        case .Steel_Sword:
            switch ch {
            case 'B': return {196, 204, 216}, true
            case 'E': return {240, 244, 250}, true
            case 'G': return {214, 162, 58}, true
            case 'H': return {92, 54, 32}, true
            case 'P': return {90, 200, 255}, true
            }
        }
        return
    }
    rows := w == .None ? FIST : SWORD
    side := min(rect.w, rect.h)
    u := side / 12
    x0, y0 := rect.x + (rect.w - side) / 2, rect.y + (rect.h - side) / 2
    for row, y in rows {
        for i in 0 ..< 12 {
            c, ok := col(w, row[i])
            if !ok { continue }
            q := SDL.FRect{x0 + f32(i) * u, y0 + f32(y) * u, u + 0.5, u + 0.5}
            SDL.SetRenderDrawColor(r, c.r, c.g, c.b, u8(255 * clamp(alpha, 0, 1)))
            SDL.RenderFillRect(r, &q)
        }
    }
}

// ─── Pointer edge plumbing ─────────────────────────────────────────────────

// For widgets, which don't get the game state: whether the left button went
// down this frame (UI_State.mouse_left_pressed). Set by ui_init.
gs_ui_left_pressed_state: ^UI_State

gs_ui_left_pressed :: proc() -> bool {
    if gs_ui_left_pressed_state == nil { return false }
    return gs_ui_left_pressed_state.mouse_left_pressed
}
