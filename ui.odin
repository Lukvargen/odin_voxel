package main

import "core:c"
import "core:fmt"
import "base:runtime"
import SDL "vendor:sdl3"
import TTF "vendor:sdl3/ttf"
import clay "thirdparty/clay-odin"

FONT_ID_BODY  :: 0
FONT_ID_TITLE :: 1

UI_State :: struct {
    renderer_data: Clay_SDL3RendererData,
    out_tex:       ^SDL.Texture,
    clay_memory:   [^]u8,
    initialized:   bool,

    // Toggleable options panel.
    options_open: bool,

    // Pointer state, fed to Clay each frame.
    mouse_pos:           [2]f32,
    mouse_left_down:     bool,
    mouse_left_pressed:  bool, // single-frame edge

    // FPS smoothing (rolling 60-frame avg).
    frame_times: [60]f32,
    frame_idx:   int,
    fps:         f32,
    frame_ms:    f32,
}

// Colors are 0..255 floats — the Clay SDL3 renderer divides by 255 when it
// hands them to SDL_SetRenderDrawColor.
HUD_TEXT_COLOR   :: clay.Color{220, 230, 255, 255}
PANEL_BG_COLOR   :: clay.Color{20,  24,  32,  220}
PANEL_TITLE_COL  :: clay.Color{255, 220, 120, 255}
BTN_COLOR        :: clay.Color{50,  60,  80,  255}
BTN_HOVER_COLOR  :: clay.Color{90,  110, 150, 255}
BTN_TEXT_COLOR   :: clay.Color{240, 240, 240, 255}
BTN_OFF_COLOR    :: clay.Color{60,  60,  60,  255}

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

ui_build_and_render :: proc(gs: ^Game_State, dt: f32) {
    ui := &gs.ui
    if !ui.initialized || ui.renderer_data.renderer == nil { return }

    // Smoothed FPS / frame time.
    ui.frame_times[ui.frame_idx] = dt
    ui.frame_idx = (ui.frame_idx + 1) % len(ui.frame_times)
    sum: f32 = 0
    for v in ui.frame_times { sum += v }
    avg := sum / f32(len(ui.frame_times))
    if avg < 0.0001 { avg = 0.0001 }
    ui.fps      = 1.0 / avg
    ui.frame_ms = avg * 1000.0

    w, h: i32
    SDL.GetWindowSize(gs.window, &w, &h)
    clay.SetLayoutDimensions({f32(w), f32(h)})
    clay.SetPointerState(transmute(clay.Vector2)ui.mouse_pos, ui.mouse_left_down)
    clay.UpdateScrollContainers(false, {}, dt)

    clay.BeginLayout()
    hud_layout(gs)
    if ui.options_open { options_panel_layout(gs) }
    cmds := clay.EndLayout()

    SDL.SetRenderDrawColor(ui.renderer_data.renderer, 0, 0, 0, 255)
    SDL.RenderClear(ui.renderer_data.renderer)
    if ui.out_tex != nil {
        SDL.RenderTexture(ui.renderer_data.renderer, ui.out_tex, nil, nil)
    }
    SDL_Clay_RenderClayCommands(&ui.renderer_data, &cmds)
    SDL.RenderPresent(ui.renderer_data.renderer)

    // Consume single-frame edges.
    ui.mouse_left_pressed = false
}

// ─── Layouts ───────────────────────────────────────────────────────────────

@(private="file")
hud_text :: proc(text: string) {
    clay.TextDynamic(text, clay.TextConfig({
        textColor = HUD_TEXT_COLOR,
        fontId    = FONT_ID_BODY,
        fontSize  = 16,
    }))
}

hud_layout :: proc(gs: ^Game_State) {
    ui := &gs.ui

    if clay.UI(clay.ID("HudRoot"))({
        layout = {
            layoutDirection = .TopToBottom,
            padding         = {8, 8, 8, 8},
            childGap        = 2,
            sizing          = { clay.SizingFit(), clay.SizingFit() },
        },
        floating = {
            attachTo   = .Root,
            offset     = {8, 8},
            zIndex     = 10,
            attachment = {element = .LeftTop, parent = .LeftTop},
            pointerCaptureMode = .Passthrough,
        },
        backgroundColor = {0, 0, 0, 130},
        cornerRadius    = {6, 6, 6, 6},
    }) {
        hud_text(fmt.tprintf("FPS:    %.1f", ui.fps))
        hud_text(fmt.tprintf("frame:  %.2f ms", ui.frame_ms))
        p := gs.camera.pos
        hud_text(fmt.tprintf("pos:    %.1f %.1f %.1f", p.x, p.y, p.z))

        pending := worker_pool_pending_count(&gs.pool)
        hud_text(fmt.tprintf("columns: %d loaded / %d pending", len(gs.columns), pending))
        hud_text(fmt.tprintf("block:  %v (keys 1-0)", gs.selected_block))
        hud_text(fmt.tprintf("brush:  %d (ctrl+scroll, ctrl+click = single)", gs.brush_radius))

        if !ui.options_open {
            hud_text("press O for options")
        }
    }
}

// Button used in the options panel. Returns true on click.
@(private="file")
opt_button :: proc(id: string, label: string, active: bool) -> bool {
    clicked: bool
    if clay.UI(clay.ID(id))({
        layout = {
            sizing  = { clay.SizingFixed(70), clay.SizingFixed(28) },
            childAlignment = { x = .Center, y = .Center },
        },
        backgroundColor = clay.Hovered() ? BTN_HOVER_COLOR : (active ? BTN_COLOR : BTN_OFF_COLOR),
        cornerRadius    = {4, 4, 4, 4},
    }) {
        clicked = clay.Hovered() && gs_ui_left_pressed()
        clay.TextDynamic(label, clay.TextConfig({
            textColor = BTN_TEXT_COLOR,
            fontId    = FONT_ID_BODY,
            fontSize  = 16,
        }))
    }
    return clicked
}

@(private="file")
opt_row :: proc(label: string) {
    clay.TextDynamic(label, clay.TextConfig({
        textColor = HUD_TEXT_COLOR,
        fontId    = FONT_ID_BODY,
        fontSize  = 16,
    }))
}

options_panel_layout :: proc(gs: ^Game_State) {
    if clay.UI(clay.ID("OptionsPanel"))({
        layout = {
            layoutDirection = .TopToBottom,
            padding         = {14, 14, 14, 14},
            childGap        = 10,
            sizing          = { clay.SizingFixed(360), clay.SizingFit() },
        },
        floating = {
            attachTo   = .Root,
            offset     = {0, 0},
            zIndex     = 20,
            attachment = {element = .CenterCenter, parent = .CenterCenter},
            pointerCaptureMode = .Capture,
        },
        backgroundColor = PANEL_BG_COLOR,
        cornerRadius    = {8, 8, 8, 8},
        border          = { color = {120, 140, 180, 255}, width = {1, 1, 1, 1, 0} },
    }) {
        clay.Text("Options", clay.TextConfig({
            textColor = PANEL_TITLE_COL,
            fontId    = FONT_ID_TITLE,
            fontSize  = 22,
        }))

        // AA samples row
        if clay.UI(clay.ID("RowAA"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("AA samples: %d", gs.aa_samples))
            if clay.UI(clay.ID("AASpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("AA1", "1", gs.aa_samples == 1) { gs.aa_samples = 1 }
            if opt_button("AA2", "2", gs.aa_samples == 2) { gs.aa_samples = 2 }
            if opt_button("AA4", "4", gs.aa_samples == 4) { gs.aa_samples = 4 }
        }

        // Shadow rays row
        if clay.UI(clay.ID("RowShadow"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Shadow rays: %d", gs.shadow_rays))
            if clay.UI(clay.ID("ShSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("Sh1", "hard", gs.shadow_rays == 1) { gs.shadow_rays = 1 }
            if opt_button("Sh3", "soft", gs.shadow_rays == 3) { gs.shadow_rays = 3 }
        }

        // Volumetric enable row
        if clay.UI(clay.ID("RowVolOn"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Volumetric: %v", gs.vol_enabled))
            if clay.UI(clay.ID("VolSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("VolOn",  "on",  gs.vol_enabled)  { gs.vol_enabled = true  }
            if opt_button("VolOff", "off", !gs.vol_enabled) { gs.vol_enabled = false }
        }

        // SDF entities row
        if clay.UI(clay.ID("RowEntities"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Entities: %v", gs.entities_enabled))
            if clay.UI(clay.ID("EntSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("EntOn",  "on",  gs.entities_enabled)  { gs.entities_enabled = true  }
            if opt_button("EntOff", "off", !gs.entities_enabled) { gs.entities_enabled = false }
        }

        // Volumetric steps row
        if clay.UI(clay.ID("RowVolSteps"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Vol steps: %d", gs.vol_steps))
            if clay.UI(clay.ID("VsSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("Vs16", "16", gs.vol_steps == 16) { gs.vol_steps = 16 }
            if opt_button("Vs24", "24", gs.vol_steps == 24) { gs.vol_steps = 24 }
            if opt_button("Vs32", "32", gs.vol_steps == 32) { gs.vol_steps = 32 }
        }

        // Render scale row — internal resolution / pixel-art look. Changing
        // it recreates the scene textures (gpu_set_render_scale).
        if clay.UI(clay.ID("RowScale"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Render scale: %dx (%dx%d)", gs.render_scale, gs.render_w, gs.render_h))
            if clay.UI(clay.ID("RsSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("Rs1", "1x", gs.render_scale == 1) { gpu_set_render_scale(gs, 1) }
            if opt_button("Rs2", "2x", gs.render_scale == 2) { gpu_set_render_scale(gs, 2) }
            if opt_button("Rs4", "4x", gs.render_scale == 4) { gpu_set_render_scale(gs, 4) }
        }

        // Exposure row — pre-tonemap brightness multiplier
        if clay.UI(clay.ID("RowExposure"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Exposure: %.2f", gs.exposure))
            if clay.UI(clay.ID("ExpSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("ExpDn", "-", true) { gs.exposure = max(gs.exposure / 1.12, 0.25) }
            if opt_button("ExpUp", "+", true) { gs.exposure = min(gs.exposure * 1.12, 4.0) }
        }

        // Fog density row — base distance-fog density
        if clay.UI(clay.ID("RowFog"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Fog: %.4f", gs.fog_density))
            if clay.UI(clay.ID("FogSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("FogDn", "-", true) { gs.fog_density = max(gs.fog_density / 1.3, 0.0003) }
            if opt_button("FogUp", "+", true) { gs.fog_density = min(gs.fog_density * 1.3, 0.006) }
        }

        // Reflection bounces row (moved off keys 1-5, which are now the hotbar)
        if clay.UI(clay.ID("RowBounces"))({
            layout = { childGap = 8, childAlignment = {y = .Center},
                       sizing = { clay.SizingGrow(), clay.SizingFit() } },
        }) {
            opt_row(fmt.tprintf("Bounces: %d", gs.reflect_amount))
            if clay.UI(clay.ID("BncSpacer"))({ layout = { sizing = { clay.SizingGrow(), clay.SizingFit() } } }) {}
            if opt_button("BncDn", "-", true) { gs.reflect_amount = max(gs.reflect_amount - 1, 1) }
            if opt_button("BncUp", "+", true) { gs.reflect_amount = min(gs.reflect_amount + 1, 5) }
        }

        clay.TextDynamic("press O to close", clay.TextConfig({
            textColor = {180, 180, 180, 255},
            fontId    = FONT_ID_BODY,
            fontSize  = 14,
        }))
    }
}

// ─── Pointer edge plumbing ─────────────────────────────────────────────────

// Set by main when the panel is open and a left-click event arrives. The
// flag is cleared after layout each frame in ui_build_and_render.
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
