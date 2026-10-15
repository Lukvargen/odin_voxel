package main

// Clay UI over the ray-traced frame, kept clean and out of the way (the look
// of the gamejam project): flat dark panels with a hairline border, rounded
// corners, one accent colour; no gradients, glows or shadows.
//
// While playing there's little on screen: the crosshair and target outline,
// the hotbar (put away with the sword drawn), toasts, the biome's name for a
// moment when you enter one, health only while hurt, and damage numbers over
// what you hit. The glider's instruments while gliding, the controls card on
// H, the debug panel on F3; F1 hides it all.
// Screens: the pause menu (Esc) with graphics / sound / controls tabs, and the
// block picker (E).

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

Ui_Screen :: enum u8 { None, Pause, Inventory }
Menu_Tab  :: enum u8 { Graphics, Sound, Controls }

UI_State :: struct {
    renderer_data: Clay_SDL3RendererData,
    out_tex:       ^SDL.Texture,
    clay_memory:   [^]u8,
    initialized:   bool,

    screen:         Ui_Screen,
    menu_tab:       Menu_Tab,
    quit_requested: bool, // "Save and quit" in the menu
    debug_open:     bool, // F3
    hud_hidden:     bool, // F1
    help_open:      bool, // H
    help_t:         f32,  // seconds left of the startup "H for controls" hint

    // Pointer state, fed to Clay each frame.
    mouse_pos:          [2]f32,
    mouse_left_down:    bool,
    mouse_left_pressed: bool, // single-frame edge
    dragging:           u32,  // id of the slider being dragged, 0 if none

    toast_buf:    [96]u8,
    toast_len:    int,
    toast_t:      f32,
    block_name_t: f32,
    prev_block:   Block_Type,
    prev_slot:    int,
    biome:        Biome,
    biome_timer:  f32,
    biome_shown:  Biome, // the name on screen...
    biome_t:      f32,   // ...for this much longer
    biome_seen:   bool,

    // FPS smoothing (rolling 60-frame avg).
    frame_times: [60]f32,
    frame_idx:   int,
    fps:         f32,
    frame_ms:    f32,
}

// ─── Theme ─────────────────────────────────────────────────────────────────

// Colors are 0..255 floats: the Clay SDL3 renderer divides by 255. The
// gamejam project's palette.
COLOR_TEXT       :: clay.Color{205, 214, 244, 255}
COLOR_TEXT_DIM   :: clay.Color{147, 153, 178, 255}
COLOR_TEXT_FAINT :: clay.Color{147, 153, 178, 150}
COLOR_ACCENT     :: clay.Color{243, 139, 168, 255}
COLOR_ACCENT_2   :: clay.Color{250, 179, 135, 255}
COLOR_ON_ACCENT  :: clay.Color{24, 24, 37, 255}
COLOR_GOOD       :: clay.Color{166, 227, 161, 255}
COLOR_BAD        :: clay.Color{243, 110, 110, 255}
COLOR_SKY        :: clay.Color{137, 180, 250, 255}
COLOR_BAR_BG     :: clay.Color{40, 40, 58, 255}
COLOR_RULE       :: clay.Color{69, 71, 90, 255}

COLOR_PANEL        :: clay.Color{24, 24, 37, 220}
COLOR_PANEL_SOFT   :: clay.Color{24, 24, 37, 170}
COLOR_PANEL_BORDER :: clay.Color{69, 71, 90, 255}
COLOR_BUTTON       :: clay.Color{49, 50, 68, 255}
COLOR_BUTTON_HOVER :: clay.Color{88, 91, 112, 255}
COLOR_SLOT         :: clay.Color{17, 17, 27, 150}

ui_error_handler :: proc "c" (errorData: clay.ErrorData) {
    context = runtime.default_context()
    msg := string(errorData.errorText.chars[:errorData.errorText.length])
    fmt.println("Clay error:", errorData.errorType, msg)
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
    // gpu_set_render_scale can rebuild it when the render resolution changes.
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
// resolution, with nearest-neighbor upscale (crisp pixel-art look — switch to
// .LINEAR for a smoothed upscale). Destroys any previous wrap first, so this is
// safe to call after gpu_set_render_scale recreates out_texture.
ui_rewrap_out_texture :: proc(gs: ^Game_State) {
    ui := &gs.ui
    if ui.out_tex != nil {
        SDL.DestroyTexture(ui.out_tex)
        ui.out_tex = nil
    }
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
        SDL.SetTextureScaleMode(ui.out_tex, .NEAREST)
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
    gs.ui.screen = screen
    gs.ui.dragging = 0
    gs.mouse_locked = screen == .None
    gs.left_held, gs.right_held = false, false
    _ = SDL.SetWindowRelativeMouseMode(gs.window, gs.mouse_locked)
}

// Esc: open the pause menu, or close whatever screen is open.
ui_back :: proc(gs: ^Game_State) {
    ui_open(gs, gs.ui.screen == .None ? .Pause : .None)
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
    clay.SetLayoutDimensions({fw, fh})
    clay.SetPointerState(transmute(clay.Vector2)ui.mouse_pos, ui.mouse_left_down)
    clay.UpdateScrollContainers(false, {}, dt)

    clay.BeginLayout()
    if !ui.hud_hidden || ui.screen != .None {
        hud_layout(gs, fw, fh)
        glider_hud_layout(gs, fw, fh)
    }
    switch ui.screen {
    case .None:
    case .Pause:     menu_layout(gs)
    case .Inventory: inventory_layout(gs)
    }
    cmds := clay.EndLayout()

    r := ui.renderer_data.renderer
    SDL.SetRenderDrawColor(r, 0, 0, 0, 255)
    SDL.RenderClear(r)
    if ui.out_tex != nil {
        SDL.RenderTexture(r, ui.out_tex, nil, nil)
    }
    if ui.screen == .None && !ui.hud_hidden && !gs.combat.sword { draw_target_outline(gs, fw, fh) }
    SDL_Clay_RenderClayCommands(&ui.renderer_data, &cmds)

    // Consume single-frame edges.
    ui.mouse_left_pressed = false
}

// ─── Drawing the theme (custom elements) ───────────────────────────────────

// What a custom element draws behind its children (ui_draw_custom).
Ui_Deco :: enum u8 {
    Block_Icon,
    Glass,        // a panel: flat, a hairline border
    Glass_Soft,   // the same, more see-through (HUD cards)
    Button, Button_Hover, Button_On, Button_On_Hover,
    Slot, Slot_Hover, Slot_On,
    Tooltip,
}

Ui_Custom :: struct {
    deco:   Ui_Deco,
    block:  Block_Type,
    radius: f32,
    alpha:  f32, // fades the whole thing
}

@(private="file")
deco :: proc(d: Ui_Deco, block := Block_Type.Air, radius: f32 = 8, alpha: f32 = 1) -> clay.CustomElementConfig {
    p := new(Ui_Custom, context.temp_allocator)
    p^ = {deco = d, block = block, radius = radius, alpha = alpha}
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
    if width > 0 {
        b := fcol(border, a)
        round_rect(r, rect, radius, b, b)
    }
    f := fcol(fill, a)
    round_rect(r, inset(rect, width), radius - width, f, f)
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
    case .Glass, .Tooltip:
        flat(r, rect, d.radius, COLOR_PANEL, COLOR_PANEL_BORDER, 1, a)
    case .Glass_Soft:
        flat(r, rect, d.radius, COLOR_PANEL_SOFT, COLOR_PANEL_BORDER, 1, a * 0.85)
    case .Button:
        flat(r, rect, d.radius, COLOR_BUTTON, {}, 0)
    case .Button_Hover:
        flat(r, rect, d.radius, COLOR_BUTTON_HOVER, {}, 0)
    case .Button_On, .Button_On_Hover:
        // Selected: the button with an accent border, as in the gamejam menus.
        flat(r, rect, d.radius, d.deco == .Button_On_Hover ? COLOR_BUTTON_HOVER : COLOR_BUTTON, COLOR_ACCENT, 2)
    case .Slot:
        flat(r, rect, d.radius, COLOR_SLOT, {}, 0)
    case .Slot_Hover:
        flat(r, rect, d.radius, COLOR_BUTTON_HOVER, {}, 0)
    case .Slot_On:
        flat(r, rect, d.radius, COLOR_SLOT, COLOR_ACCENT, 2)
    }
}

// ─── Small pieces ──────────────────────────────────────────────────────────

@(private="file")
text :: proc(s: string, color := COLOR_TEXT, size: u16 = 16, font: u16 = FONT_ID_BODY) {
    clay.TextDynamic(s, clay.TextConfig({textColor = color, fontId = font, fontSize = size}))
}

// Fades a color's alpha; quantized so fading text doesn't flood the text cache.
@(private="file")
fade :: proc(col: clay.Color, a: f32) -> clay.Color {
    q := math.round(clamp(a, 0, 1) * 16) / 16
    return {col.r, col.g, col.b, col.a * q}
}

@(private="file")
spacer :: proc() {
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {}
}

// A thin rule that fades out to both ends.
@(private="file")
divider :: proc() {
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}}}) {
        for a in ([3]f32{0.3, 1, 0.3}) {
            if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                backgroundColor = fade(COLOR_RULE, a)}) {}
        }
    }
}

// Floating at an anchor of the screen, not taking the pointer.
@(private="file")
anchored :: proc(at: clay.FloatingAttachPointType, offset: [2]f32, z: i16 = 10) -> clay.FloatingElementConfig {
    return {
        attachTo = .Root, offset = transmute(clay.Vector2)offset, zIndex = z,
        attachment = {element = at, parent = at},
        pointerCaptureMode = .Passthrough,
    }
}

// A small rounded tag: "FLYING", "THERMAL", ...
@(private="file")
chip :: proc(label: string, color: clay.Color, filled := false) {
    if clay.UI()({
        layout = {padding = {7, 7, 3, 3}},
        backgroundColor = filled ? color : {color.r, color.g, color.b, 42},
        cornerRadius = clay.CornerRadiusAll(4),
        border = filled ? {} : {{color.r, color.g, color.b, 90}, clay.BorderOutside(1)},
    }) {
        text(label, filled ? COLOR_ON_ACCENT : color, 11, FONT_ID_TITLE)
    }
}

// A section heading: an amber tick, then the words.
@(private="file")
heading :: proc(s: string, a: f32 = 1) {
    if clay.UI()({layout = {childGap = 7, childAlignment = {y = .Center}}}) {
        if clay.UI()({layout = {sizing = {clay.SizingFixed(3), clay.SizingFixed(13)}},
            backgroundColor = fade(COLOR_ACCENT, a), cornerRadius = clay.CornerRadiusAll(1.5)}) {}
        text(s, fade(COLOR_ACCENT, a), 13, FONT_ID_TITLE)
    }
}

// "Red_Sand" -> "Red sand".
@(private="file")
block_name :: proc(b: Block_Type) -> string {
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
    case .Mountains: return "Mountains"
    case .Peaks:     return "Peaks"
    }
    return ""
}

player_swimming :: proc(gs: ^Game_State) -> bool {
    p := gs.camera.pos - {0, PLAYER_EYE_HEIGHT * 0.5, 0}
    return get_voxel(gs, int(math.floor(p.x)), int(math.floor(p.y)), int(math.floor(p.z))) == u32(Block_Type.Water)
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
    }

    // The compass only while gliding, when where you're heading matters.
    if gliding { compass_layout(gs) }

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

    if !gliding && ui.screen != .Inventory && !gs.combat.sword { hotbar_layout(gs) }
    if playing { combat_hud_layout(gs, w, h) }

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

// A ribbon along the top: the winds and ticks between, turning with you.
@(private="file")
compass_layout :: proc(gs: ^Game_State) {
    WIDTH :: f32(300)
    SPAN  :: f32(110) // degrees shown across the ribbon
    // Compass bearing: yaw 0 looks along +Z (south, 180), yaw 90 along +X (east, 90).
    yaw := gs.glider.deployed ? gs.glider.heading : gs.camera.yaw
    bearing := math.mod(math.mod(180 - yaw, 360) + 360, 360)
    if clay.UI(clay.ID("Compass"))({
        layout = {sizing = {clay.SizingFixed(WIDTH), clay.SizingFixed(26)}},
        floating = anchored(.CenterTop, {0, 14}),
        custom = deco(.Glass_Soft, radius = 13),
        clip = {horizontal = true},
    }) {
        LABELS :: [8]string{"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
        labels := LABELS
        for k in 0 ..< 24 {
            mark := f32(k) * 15
            d := math.mod(mark - bearing + 540, 360) - 180
            if abs(d) > SPAN / 2 { continue }
            x := WIDTH / 2 + d / SPAN * WIDTH
            edge := 1 - math.smoothstep(f32(0.55), 1, abs(d) / (SPAN / 2))
            if k % 3 == 0 {
                label := labels[k / 3]
                main_wind := len(label) == 1
                col := label == "N" ? COLOR_BAD : (main_wind ? COLOR_TEXT : COLOR_TEXT_DIM)
                if clay.UI(clay.ID("Wind", u32(k)))({
                    floating = {attachTo = .Parent, offset = {x, 13}, zIndex = 12, attachment = {.CenterCenter, .LeftTop}, pointerCaptureMode = .Passthrough},
                }) {
                    text(label, fade(col, edge), main_wind ? 14 : 11, FONT_ID_TITLE)
                }
            } else {
                if clay.UI(clay.ID("Tick", u32(k)))({
                    layout = {sizing = {clay.SizingFixed(1), clay.SizingFixed(6)}},
                    floating = {attachTo = .Parent, offset = {x, 13}, zIndex = 12, attachment = {.CenterCenter, .LeftTop}, pointerCaptureMode = .Passthrough},
                    backgroundColor = fade(COLOR_TEXT_DIM, edge * 0.8),
                }) {}
            }
        }
        // Where you're facing: a small amber notch.
        if clay.UI(clay.ID("CompassNotch"))({
            layout = {sizing = {clay.SizingFixed(2), clay.SizingFixed(5)}},
            floating = {attachTo = .Parent, offset = {WIDTH / 2, 0}, zIndex = 13, attachment = {.CenterTop, .LeftTop}, pointerCaptureMode = .Passthrough},
            backgroundColor = COLOR_ACCENT,
        }) {}
    }
}

// Nine slots along the bottom, the selected block's name over them, the brush
// beside them.
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
        } else if gs.glider.equipped {
            text("Glider ready: jump, then Space in the air", COLOR_ACCENT, 14, FONT_ID_TITLE)
        }
        if clay.UI(clay.ID("Hotbar"))({
            layout = {padding = clay.PaddingAll(7), childGap = 5, childAlignment = {y = .Center}},
            custom = deco(.Glass_Soft, radius = 10),
        }) {
            hotbar_slots(gs, false)
            // Brush: a ring that grows with the edit radius (one block: nothing).
            if gs.brush_radius > 0 do if clay.UI(clay.ID("Brush"))({
                layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFixed(52), clay.SizingFixed(46)},
                          childAlignment = {x = .Center, y = .Center}, childGap = 3},
            }) {
                d := 5 + f32(gs.brush_radius) * 2.2
                if clay.UI()({layout = {sizing = {clay.SizingFixed(d), clay.SizingFixed(d)}},
                    backgroundColor = {COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 50}, cornerRadius = clay.CornerRadiusAll(d / 2),
                    border = {COLOR_ACCENT, clay.BorderOutside(1)}}) {}
                text(fmt.tprintf("brush %d", gs.brush_radius), COLOR_TEXT_DIM, 11)
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
        floating = anchored(.CenterBottom, {0, gs.combat.sword ? -28 : -86}),
        backgroundColor = fade(COLOR_BAR_BG, a), cornerRadius = clay.CornerRadiusAll(3),
    }) {
        fill := clamp(c.hp / PLAYER_MAX_HP, 0, 1)
        col := c.hurt_flash > 0.6 ? clay.Color{255, 244, 236, 255} : COLOR_BAD
        if clay.UI()({layout = {sizing = {clay.SizingFixed(W * fill), clay.SizingGrow()}}, backgroundColor = fade(col, a), cornerRadius = clay.CornerRadiusAll(3)}) {}
    }
}

// Fighting: health while hurt, red at the screen edges when hit, and damage
// numbers popping up over what you hit. Nothing else: the hits, flashes and
// shakes say the rest.
@(private="file")
combat_hud_layout :: proc(gs: ^Game_State, w, h: f32) {
    c := &gs.combat
    s := &gs.slimes
    cam := gs.camera
    eye := cam.pos + cam.view_offset + [3]f32{0, cam.step_visual_offset, 0}

    health_bar(gs, w, h)

    for n, i in s.numbers {
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
                text(label, layer == 0 ? fade({17, 17, 27, 220}, a) : fade(col, a), size, FONT_ID_TITLE)
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
            if clay.UI()({layout = {sizing = {clay.SizingFixed(SLOT - 6), clay.SizingFixed(SLOT - 6)}}, custom = deco(.Block_Icon, b)}) {}
            if clay.UI(clay.ID(clickable ? "InvHotKey" : "HotKey", u32(i)))({
                floating = {attachTo = .Parent, offset = {5, 3}, zIndex = 12, attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
            }) {
                text(fmt.tprintf("%d", i + 1), on ? COLOR_ACCENT : COLOR_TEXT_FAINT, 10, FONT_ID_TITLE)
            }
        }
        if hovered && gs_ui_left_pressed() {
            hotbar_select(gs, i)
            play(.Click, 0.4)
        }
    }
}

// sRGB face colours for the icons: top, side.
@(private="file")
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
    case .Snow:       return {0.93, 0.95, 0.98}, {0.90, 0.92, 0.96}
    case .Ice:        return {0.68, 0.80, 0.93}, {0.62, 0.75, 0.90}
    case .Terracotta: return {0.70, 0.40, 0.27}, {0.70, 0.40, 0.27}
    case .Gravel:     return {0.55, 0.53, 0.50}, {0.53, 0.51, 0.48}
    case .Cactus:     return {0.36, 0.60, 0.27}, {0.30, 0.54, 0.22}
    case .Weathered_Stone: return {0.45, 0.52, 0.36}, {0.50, 0.50, 0.50}
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
                case .Grass:
                    if fi > 0 && j == 0 { col = top }
                    if fi > 0 && j == 1 && icon_hash(i, j, fi) < 0.4 { col = top }
                case .Log, .Spruce_Log:
                    if fi == 0 && (i == 0 || i == N - 1 || j == 0 || j == N - 1) { col = side }
                case .Terracotta:
                    if fi > 0 && j % 2 == 1 { col *= {1.12, 1.25, 1.2} }
                case .Coal_Ore, .Iron_Ore, .Gold_Ore:
                    if icon_hash(i, j, fi + 7) < 0.25 {
                        col = b == .Coal_Ore ? {0.15, 0.15, 0.16} : (b == .Iron_Ore ? {0.80, 0.62, 0.48} : {0.95, 0.80, 0.30})
                    }
                case .Leaves, .Spruce_Leaves:
                    if icon_hash(i, j, fi + 3) < 0.25 { col *= 0.7 }
                case .Weathered_Stone:
                    if fi > 0 && j == 0 && icon_hash(i, j, fi) < 0.6 { col = top }
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

// The voxel you're pointing at, outlined: what a click will break or build on.
@(private="file")
draw_target_outline :: proc(gs: ^Game_State, w, h: f32) {
    if !gs.mouse_locked || gs.glider.deployed { return }
    hit, _, ok := raycast_voxel(gs, gs.camera.pos, camera_forward(gs.camera), REACH)
    if !ok { return }
    eye := gs.camera.pos + gs.camera.view_offset
    eye.y += gs.camera.step_visual_offset
    fwd, right, up := camera_view_basis(gs.camera)
    lo := [3]f32{f32(hit.x), f32(hit.y), f32(hit.z)} - 0.002
    hi := lo + 1.004
    corner :: proc(lo, hi: [3]f32, k: int) -> [3]f32 {
        return {k & 1 != 0 ? hi.x : lo.x, k & 2 != 0 ? hi.y : lo.y, k & 4 != 0 ? hi.z : lo.z}
    }
    // Point -> pixels; the edge is clipped against a near plane first.
    project :: proc(p: [3]f32, fwd, right, up: [3]f32, w, h: f32) -> [2]f32 {
        d := la.dot(p, fwd)
        nx := la.dot(p, right) / d / la.length2(right)
        ny := la.dot(p, up) / d / la.length2(up)
        return {(nx + 1) * 0.5 * w, (1 - ny) * 0.5 * h}
    }
    dist := la.length((lo + 0.5) - eye)
    alpha := u8(clamp(200 - dist * 2, 70, 200))
    r := gs.ui.renderer_data.renderer
    SDL.SetRenderDrawBlendMode(r, {.BLEND})
    NEAR :: 0.05
    for pass in 0 ..< 2 {
        // A dark line under a light one.
        if pass == 0 { SDL.SetRenderDrawColor(r, 0, 0, 0, alpha / 2) } else { SDL.SetRenderDrawColor(r, 255, 250, 240, alpha) }
        for a in 0 ..< 8 {
            for bit in ([3]int{1, 2, 4}) {
                if a & bit != 0 { continue }
                p, q := corner(lo, hi, a) - eye, corner(lo, hi, a | bit) - eye
                dp, dq := la.dot(p, fwd), la.dot(q, fwd)
                if dp < NEAR && dq < NEAR { continue }
                if dp < NEAR { p = la.lerp(p, q, (NEAR - dp) / (dq - dp)) }
                if dq < NEAR { q = la.lerp(q, p, (NEAR - dq) / (dp - dq)) }
                s, e := project(p, fwd, right, up, w, h), project(q, fwd, right, up, w, h)
                o: f32 = pass == 0 ? 1 : 0
                SDL.RenderLine(r, s.x + o, s.y + o, e.x + o, e.y + o)
                if pass == 1 { SDL.RenderLine(r, s.x + 0.5, s.y + 0.5, e.x + 0.5, e.y + 0.5) }
            }
        }
    }
}

// Key, then what it does.
@(private="file")
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
        key_row("Space", "jump; twice to fly", a)
        key_row("Left click", "break", a)
        key_row("Right click", "place", a)
        key_row("Middle click", "pick block", a)
        key_row("1-9, wheel", "hotbar", a)
        key_row("E", "all blocks", a)
        key_row("B", "brush size", a)
        key_row("G", "hang glider", a)
        key_row("R", "sword", a)
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
        p := gs.camera.pos
        line("pos", fmt.tprintf("%.1f  %.1f  %.1f", p.x, p.y, p.z))
        line("look", fmt.tprintf("yaw %.0f  pitch %.0f", gs.camera.yaw, gs.camera.pitch))
        line("chunk", fmt.tprintf("%d  %d  %d", gs.player_chunk.x, gs.player_chunk.y, gs.player_chunk.z))
        if hit, _, ok := raycast_voxel(gs, p, camera_forward(gs.camera), REACH); ok {
            b := Block_Type(u8(get_voxel(gs, hit.x, hit.y, hit.z)))
            line("target", fmt.tprintf("%s  %d %d %d", block_name(b), hit.x, hit.y, hit.z))
        }
        line("columns", fmt.tprintf("%d loaded, %d pending", len(gs.columns), worker_pool_pending_count(&gs.pool)))
        line("entities", fmt.tprintf("%d drawn", gs.entity_count))
        line("render", fmt.tprintf("%dx%d  aa%d  %s", gs.render_w, gs.render_h, gs.aa_samples, gs.shadow_rays == 1 ? "hard" : "soft"))
        line("cave", fmt.tprintf("%.2f", gs.cave_factor))
        alive := 0
        for sl in gs.slimes.list { if sl.alive { alive += 1 } }
        line("slimes", fmt.tprintf("%d   F6 spawn, F7 clear", alive))
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

// One instrument: a big number over its unit and name.
@(private="file")
gauge :: proc(value, unit, name: string, color: clay.Color) {
    if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFixed(96), clay.SizingFit()}, childAlignment = {x = .Center}, childGap = 1}}) {
        if clay.UI()({layout = {childGap = 3, childAlignment = {y = .Bottom}}}) {
            text(value, color, 26, FONT_ID_TITLE)
            text(unit, COLOR_TEXT_DIM, 12)
        }
        text(name, COLOR_TEXT_FAINT, 10, FONT_ID_TITLE)
    }
}

// Hang glider: instruments, aim and flight-path markers, stall warning.
glider_hud_layout :: proc(gs: ^Game_State, w, h: f32) {
    g := &gs.glider
    if !g.deployed { return }

    // Where the mouse is steering (moves off-centre while free-looking),
    // and where the glider is actually going.
    aim := camera_forward(Camera{yaw = g.aim_yaw, pitch = g.aim_pitch})
    if x, y, ok := glider_project(gs.camera, aim, w, h); ok {
        hud_marker("GliderAim", x, y, 18, {255, 250, 240, 200}, false)
    }
    if v := gs.camera.velocity; v.x*v.x + v.y*v.y + v.z*v.z > 1 {
        if x, y, ok := glider_project(gs.camera, v, w, h); ok {
            hud_marker("GliderPath", x, y, 8, COLOR_GOOD, true)
        }
    }

    if g.stall > 0.25 {
        if clay.UI(clay.ID("Stall"))({layout = {padding = {16, 16, 7, 8}}, floating = anchored(.CenterCenter, {0, -70}, 20),
            backgroundColor = {196, 52, 40, 225}, cornerRadius = clay.CornerRadiusAll(7),
            border = {{255, 160, 140, 120}, clay.BorderOutside(1)}}) {
            text("STALL   push forward", COLOR_TEXT, 17, FONT_ID_TITLE)
        }
    }

    if clay.UI(clay.ID("GliderHud"))({
        layout = {layoutDirection = .TopToBottom, padding = {16, 16, 11, 11}, childGap = 8, childAlignment = {x = .Center}},
        floating = anchored(.CenterBottom, {0, -14}),
        custom = deco(.Glass_Soft, radius = 10),
    }) {
        if clay.UI()({layout = {childGap = 10, childAlignment = {y = .Center}}}) {
            gauge(fmt.tprintf("%.0f", g.airspeed * 3.6), "km/h", "AIRSPEED", COLOR_TEXT)
            // Vario: the number, and a bar filling up (climb) or down (sink) from the middle.
            vcol := COLOR_TEXT
            if g.vario >  0.3 { vcol = COLOR_GOOD }
            if g.vario < -2.5 { vcol = COLOR_BAD }
            if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFixed(10), clay.SizingFixed(52)}},
                backgroundColor = COLOR_BAR_BG, cornerRadius = clay.CornerRadiusAll(3)}) {
                if clay.UI(clay.ID("VarioTick"))({layout = {sizing = {clay.SizingFixed(16), clay.SizingFixed(2)}},
                    floating = {attachTo = .Parent, zIndex = 12, attachment = {.CenterCenter, .CenterCenter}, pointerCaptureMode = .Passthrough},
                    backgroundColor = {255, 255, 255, 160}}) {}
                t := clamp(g.vario / 5, -1, 1)
                up := max(t, 0) * 0.5
                down := max(-t, 0) * 0.5
                if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingPercent(0.5 - up)}}}) {}
                if up > 0.01 { if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingPercent(up)}}, backgroundColor = COLOR_GOOD, cornerRadius = clay.CornerRadiusAll(3)}) {} }
                if down > 0.01 { if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingPercent(down)}}, backgroundColor = COLOR_BAD, cornerRadius = clay.CornerRadiusAll(3)}) {} }
            }
            gauge(fmt.tprintf("%+.1f", g.vario), "m/s", "VARIO", vcol)
            gauge(fmt.tprintf("%.0f", max(g.agl, 0)), "m", "HEIGHT", COLOR_TEXT)
        }
        if clay.UI()({layout = {childGap = 8, childAlignment = {y = .Center}}}) {
            if g.lift_here > 0.8 { chip("THERMAL", COLOR_GOOD, true) }
            text("mouse steer   Ctrl look   W fast   S flare   A/D lean   F5 view   Space let go", COLOR_TEXT_FAINT, 12)
        }
    }
}

// ─── Pause menu ────────────────────────────────────────────────────────────

@(private="file")
button :: proc(id: clay.ElementId, label: string, selected := false, width: f32 = 0, danger := false) -> (clicked: bool) {
    hovered := clay.PointerOver(id)
    d: Ui_Deco = selected ? (hovered ? .Button_On_Hover : .Button_On) : (hovered ? .Button_Hover : .Button)
    if clay.UI(id)({
        layout = {
            sizing = {width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(), clay.SizingFixed(32)},
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
@(private="file")
setting_row :: proc() -> clay.ElementDeclaration {
    return {layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 12, childAlignment = {y = .Center}}}
}

@(private="file")
row_label :: proc(label: string) {
    if clay.UI()({layout = {sizing = {clay.SizingFixed(130), clay.SizingFit()}}}) {
        text(label, COLOR_TEXT, 15)
    }
}

// A row of buttons, one selected. Returns the clicked index or -1.
@(private="file")
segmented :: proc(id: string, labels: []string, selected: int) -> int {
    clicked := -1
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 5}}) {
        for l, i in labels {
            if button(clay.ID(id, u32(i)), l, i == selected) { clicked = i }
        }
    }
    return clicked
}

@(private="file")
toggle :: proc(id: string, value: ^bool) {
    if i := segmented(id, {"On", "Off"}, value^ ? 0 : 1); i >= 0 { value^ = i == 0 }
}

// A draggable slider; t is value's 0..1 position. Returns whether it changed.
@(private="file")
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
                        floating = {attachTo = .Parent, zIndex = 25, attachment = {element = .CenterCenter, parent = .RightCenter}},
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
@(private="file")
shade :: proc(id: string, a: f32 = 130) {
    if clay.UI(clay.ID(id))({
        layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
        floating = {attachTo = .Root, zIndex = 15, pointerCaptureMode = .Capture},
        backgroundColor = {8, 10, 16, a},
    }) {}
}

menu_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui
    shade("MenuShade")
    if clay.UI(clay.ID("Menu"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(22), childGap = 12, sizing = {clay.SizingFixed(500), clay.SizingFit()}},
        floating = {attachTo = .Root, zIndex = 20, attachment = {.CenterCenter, .CenterCenter}, pointerCaptureMode = .Capture},
        custom = deco(.Glass, radius = 12),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Bottom}}}) {
            text("Paused", COLOR_ACCENT, 28, FONT_ID_TITLE)
            spacer()
            p := gs.camera.pos
            text(fmt.tprintf("%s   %d m", biome_name(ui.biome), int(p.y - PLAYER_EYE_HEIGHT)), COLOR_TEXT_DIM, 14)
        }
        if i := segmented("Tab", {"Graphics", "Sound", "Controls"}, int(ui.menu_tab)); i >= 0 {
            ui.menu_tab = Menu_Tab(i)
        }
        divider()

        switch ui.menu_tab {
        case .Graphics: menu_graphics(gs)
        case .Sound:    menu_sound(gs)
        case .Controls: menu_controls()
        }

        divider()
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8}}) {
            if button(clay.ID("Resume"), "Resume") { ui_open(gs, .None) }
            if button(clay.ID("Quit"), "Save and quit", danger = true) { ui.quit_requested = true }
        }
        text("Esc resumes", COLOR_TEXT_FAINT, 12)
    }
}

@(private="file")
menu_graphics :: proc(gs: ^Game_State) {
    if clay.UI()(setting_row()) {
        row_label("Render scale")
        if i := segmented("Rs", {"Full", "1/2", "1/4"}, gs.render_scale == 1 ? 0 : (gs.render_scale == 2 ? 1 : 2)); i >= 0 {
            gpu_set_render_scale(gs, i32(1) << uint(i))
        }
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
        row_label("Thermal clouds")
        toggle("Cloud", &gs.clouds_enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("Creatures")
        toggle("Ent", &gs.entities_enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("Far terrain")
        toggle("Far", &gs.far_enabled)
    }
    if clay.UI()(setting_row()) {
        row_label("Reflections")
        if i := segmented("Bnc", {"1", "2", "3", "4", "5"}, int(gs.reflect_amount) - 1); i >= 0 { gs.reflect_amount = i32(i + 1) }
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
    if !audio.ok { text("No audio device found.", COLOR_BAD, 13) }
    text("M mutes at any time.", COLOR_TEXT_FAINT, 12)
}

@(private="file")
menu_controls :: proc() {
    group :: proc(title: string, keys: []string) {
        if clay.UI()({layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 3}}) {
            heading(title)
            for i := 0; i + 1 < len(keys); i += 2 {
                key_row(keys[i], keys[i + 1], 1, 150)
            }
        }
    }
    group("Moving", {"WASD", "move", "Ctrl  or  W W", "sprint", "Shift", "sneak (won't fall off edges)", "Space", "jump; hold to swim up", "Space twice", "fly: Space up, Shift down, Alt fast"})
    group("Building", {"Left / right click", "break / place (hold to repeat)", "Middle click", "pick the block you look at", "1-9, mouse wheel", "hotbar", "E", "all blocks", "B", "brush size"})
    group("Fighting", {"R", "draw / put away the sword", "Left click (hold)", "combo; in the air, juggle", "Look down + click", "plunge, from up high", "Right click", "rising slash", "Shift", "dodge roll"})
    group("Gliding", {"G", "equip the glider", "Space in the air", "open / let go", "Mouse, W/S, A/D", "steer, speed, lean", "Ctrl", "look around"})
    group("Other", {"F5", "camera view", "F6 / F7", "spawn / clear slimes (debug)", "F1 / F3", "hide HUD / debug", "F2", "screenshot", "H", "controls card", "M", "mute", "L (hold)", "sun follows your view"})
}

// ─── Block picker (E) ──────────────────────────────────────────────────────

// Every block, and the hotbar under them. Click a block to put it in the
// selected hotbar slot; click a hotbar slot to select it.
inventory_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui
    shade("InvShade", 100)
    hovered_block := Block_Type.Air
    SLOT :: 46
    if clay.UI(clay.ID("Inventory"))({
        layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 10},
        floating = {attachTo = .Root, zIndex = 20, attachment = {.CenterCenter, .CenterCenter}, pointerCaptureMode = .Capture},
        custom = deco(.Glass, radius = 12),
    }) {
        if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Bottom}}}) {
            text("Blocks", COLOR_ACCENT, 24, FONT_ID_TITLE)
            spacer()
            text("E or Esc to close", COLOR_TEXT_FAINT, 12)
        }
        n := 0
        if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 5}}) {
            for n < len(Block_Type) {
                if clay.UI()({layout = {childGap = 5}}) {
                    for col := 0; col < 9 && n < len(Block_Type); n += 1 {
                        b := Block_Type(n)
                        if b == .Air || b == .Water { continue }
                        id := clay.ID("Inv", u32(n))
                        hov := clay.PointerOver(id)
                        if hov { hovered_block = b }
                        in_hand := b == gs.selected_block
                        if clay.UI(id)({
                            layout = {sizing = {clay.SizingFixed(SLOT), clay.SizingFixed(SLOT)}, childAlignment = {.Center, .Center}},
                            custom = deco(hov ? .Slot_Hover : (in_hand ? .Slot_On : .Slot), radius = 6),
                        }) {
                            if clay.UI()({layout = {sizing = {clay.SizingFixed(SLOT - 6), clay.SizingFixed(SLOT - 6)}}, custom = deco(.Block_Icon, b)}) {}
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
        divider()
        heading("Hotbar")
        if clay.UI()({layout = {childGap = 5}}) {
            hotbar_slots(gs, true)
        }
        text("Click a block to put it in the selected slot.", COLOR_TEXT_DIM, 13)
    }
    // Tooltip by the pointer.
    if hovered_block != .Air {
        if clay.UI(clay.ID("Tooltip"))({
            layout = {padding = {10, 10, 6, 8}},
            floating = {attachTo = .Root, offset = {ui.mouse_pos.x + 16, ui.mouse_pos.y - 30}, zIndex = 40,
                        attachment = {.LeftTop, .LeftTop}, pointerCaptureMode = .Passthrough},
            custom = deco(.Tooltip, radius = 6),
        }) {
            text(block_name(hovered_block), COLOR_TEXT, 14, FONT_ID_TITLE)
        }
    }
}

// ─── Pointer edge plumbing ─────────────────────────────────────────────────

// Set by main when a screen is open and a left-click event arrives. The
// flag is cleared after layout each frame in ui_draw.
gs_ui_left_pressed_state: ^UI_State

gs_ui_left_pressed :: proc() -> bool {
    if gs_ui_left_pressed_state == nil { return false }
    return gs_ui_left_pressed_state.mouse_left_pressed
}

// Helper: pending = workers in flight + queued column count.
worker_pool_pending_count :: proc(pool: ^Worker_Pool) -> int {
    n := int(pool.in_flight)
    // pending dynamic array is mutex-guarded; use atomic-free best-effort read.
    n += len(pool.pending)
    return n
}
