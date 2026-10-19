package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import SDL "vendor:sdl3"
import stbi "vendor:stb/image"
import clay "thirdparty/clay-odin"

// The main menu, the game's first screen unless the arguments already say
// where to go (world=, join=, host, at=, sandbox): play a world (one of
// saves/, or a new one), or open the entity sandbox (sandbox.odin). It draws
// with the UI alone: nothing is generated until a world is chosen.
//
// The game runs one world per run, as it was built (the world, its server
// and the GPU's buffers are made once). "Main menu" in the pause menu ends
// this run and starts the game again here (main_relaunch).

Menu_Choice :: enum u8 { None, Quit, World, Sandbox, Join }

// Why the game is back at the main menu (note=, from main_menu_args): shown
// on the Worlds page, where you'd try again.
menu_note: string

@(private="file")
Menu_Page :: enum u8 { Title, Worlds }

@(private="file")
World_Entry :: struct {
    name:     string,
    columns:  int,       // edited columns saved
    played:   time.Time, // the newest file in it
    survival: bool,      // its game mode (save.odin)
}

@(private="file")
Main_Menu :: struct {
    page:     Menu_Page,
    worlds:   [dynamic]World_Entry,
    picked:   int, // in worlds, -1 none
    clicked:  u64, // when the picked one was last clicked (ms): a second click soon after plays it
    new_name: Text_Field,
    join_to:  Text_Field, // the address of someone's game
    note:     string, // why the new name won't do
    survival: bool,   // a new world's game mode
    choice:   Menu_Choice,
}

// Runs the menu until something is chosen; for .World, the world's folder
// name under saves/; for .Join, the address.
main_menu_run :: proc(gs: ^Game_State) -> (choice: Menu_Choice, world: string) {
    // On the heap: its name box is where the UI types (ui.typing) for a while.
    m := new_clone(Main_Menu{picked = -1})
    defer {
        for w in m.worlds { delete(w.name) }
        delete(m.worlds)
        free(m)
    }
    menu_scan_worlds(m)
    if menu_note != "" { m.note, m.page = menu_note, .Worlds }
    gs.mouse_locked = false
    _ = SDL.SetWindowRelativeMouseMode(gs.window, false)
    ui := &gs.ui
    last := SDL.GetTicks()
    for m.choice == .None {
        now := SDL.GetTicks()
        dt := f32(now - last) / 1000
        last = now
        wheel: f32
        ev: SDL.Event
        for SDL.PollEvent(&ev) {
            #partial switch ev.type {
            case .QUIT:
                m.choice = .Quit
            case .TEXT_INPUT:
                ui_type_text(gs, string(ev.text.text))
            case .KEY_DOWN:
                if ui.typing != nil {
                    ui_type_key(gs, ev.key.key, key_mods(ev.key.mod))
                } else if ev.key.key == SDL.K_ESCAPE && m.page == .Worlds {
                    m.page = .Title
                } else if (ev.key.key == SDL.K_RETURN || ev.key.key == SDL.K_KP_ENTER) && m.page == .Worlds && m.picked >= 0 {
                    m.choice = .World
                }
            case .MOUSE_MOTION:
                ui.mouse_pos = {ev.motion.x, ev.motion.y}
            case .MOUSE_BUTTON_DOWN:
                ui.mouse_pos = {ev.button.x, ev.button.y}
                if ev.button.button == 1 { ui.mouse_left_down, ui.mouse_left_pressed = true, true }
            case .MOUSE_BUTTON_UP:
                if ev.button.button == 1 { ui.mouse_left_down = false }
            case .MOUSE_WHEEL:
                wheel += ev.wheel.y
            }
        }
        menu_frame(gs, m, dt, wheel)
        free_all(context.temp_allocator)
    }
    ui_type_into(gs, nil)
    if m.choice == .World { world = strings.clone(m.worlds[m.picked].name) }
    if m.choice == .Join { world = strings.clone(strings.trim_space(string(m.join_to.buf[:m.join_to.len]))) }
    return m.choice, world
}

// One frame saying what's being loaded, shown while the world is made
// (generate_world blocks for a few seconds).
// shaders: still waiting on the GPU's shaders (gpu_pipelines_wait), slow
// the first time a new build runs.
main_menu_loading :: proc(gs: ^Game_State, what: string, shaders := false) {
    if !gs.ui.initialized { return }
    menu_begin(gs, 0, 0)
    left, width := menu_column(gs, false)
    if clay.UI(clay.ID("Loading"))({
        layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFixed(width), clay.SizingFit()}},
        floating = {attachTo = .Root, offset = {left, 0}, attachment = {.LeftCenter, .LeftCenter}},
    }) {
        menu_title(gs)
        text(fmt.tprintf("Loading %s...", what), COLOR_TEXT, 17, FONT_ID_TITLE)
        if shaders {
            text("Preparing the shaders. The first start after an update can take a minute.", COLOR_TEXT_DIM, 14)
        }
    }
    menu_end(gs)
    free_all(context.temp_allocator)
}

// Ends this run and starts the game again at the main menu, in the same
// place on the screen, under the same name. Called once everything has
// shut down (saves written, the world's lock let go).
main_relaunch :: proc(args: []string) {
    exe, err := os.get_executable_path(context.allocator)
    if err != nil { fmt.eprintln("Main menu: can't find the game's executable:", err); return }
    cmd := make([dynamic]string, context.temp_allocator)
    append(&cmd, exe)
    append(&cmd, ..args)
    if _, err := os.process_start({command = cmd[:], stdin = os.stdin, stdout = os.stdout, stderr = os.stderr}); err != nil {
        fmt.eprintln("Main menu: can't start the game again:", err)
    }
}

// The arguments that bring the next run back to the main menu, from this
// one's window and name. Kept past the shutdown: not temp allocated.
main_menu_args :: proc(gs: ^Game_State) -> []string {
    args := make([dynamic]string)
    append(&args, "menu")
    if name := client_name(gs); name != "" { append(&args, fmt.aprintf("name=%s", name)) }
    if gs.ui.menu_note != "" { append(&args, fmt.aprintf("note=%s", gs.ui.menu_note)) }
    if r, ok := window_rect(gs); ok { append(&args, fmt.aprintf("window=%d,%d,%d,%d", r[0], r[1], r[2], r[3])) }
    return args[:]
}

// Where the window is and how big (x, y, w, h); not when it's maximized
// or full screen, which the next run would get wrong.
window_rect :: proc(gs: ^Game_State) -> (r: [4]i32, ok: bool) {
    if gs.window == nil { return }
    if SDL.GetWindowFlags(gs.window) & {.MAXIMIZED, .FULLSCREEN, .MINIMIZED, .HIDDEN} != {} { return }
    _ = SDL.GetWindowPosition(gs.window, &r[0], &r[1])
    _ = SDL.GetWindowSize(gs.window, &r[2], &r[3])
    return r, r[2] > 0 && r[3] > 0
}

// ─── Layout ─────────────────────────────────────────────────────────────────

GAME_NAME :: "Endless Time Consuming Worlds"

// Lays out against the window, or the texture being drawn to (bench ui),
// with the backdrop under everything.
@(private="file")
menu_begin :: proc(gs: ^Game_State, dt, wheel: f32) {
    ui := &gs.ui
    w, h: i32
    SDL.GetWindowSize(gs.window, &w, &h)
    if target, ok := SDL.GetRenderTarget(ui.renderer_data.renderer).?; ok && target != nil {
        tw, th: f32
        _ = SDL.GetTextureSize(target, &tw, &th)
        w, h = i32(tw), i32(th)
    }
    ui.screen_w, ui.screen_h = f32(w), f32(h)
    clay.SetLayoutDimensions({f32(w), f32(h)})
    clay.SetPointerState(transmute(clay.Vector2)ui.mouse_pos, ui.mouse_left_down)
    clay.UpdateScrollContainers(true, {0, wheel * 40}, dt)
    clay.BeginLayout()
    if clay.UI(clay.ID("Backdrop"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, custom = deco(.Backdrop)}) {}
}

@(private="file")
menu_end :: proc(gs: ^Game_State) {
    ui := &gs.ui
    cmds := clay.EndLayout()
    r := ui.renderer_data.renderer
    SDL.SetRenderDrawColor(r, 0, 0, 0, 255)
    SDL.RenderClear(r)
    SDL_Clay_RenderClayCommands(&ui.renderer_data, &cmds)
    if target, ok := SDL.GetRenderTarget(r).?; !ok || target == nil { SDL.RenderPresent(r) }
    ui.mouse_left_pressed = false
}

// Where the menu's column sits: a margin in from the left, and how wide.
@(private="file")
menu_column :: proc(gs: ^Game_State, wide: bool) -> (left, width: f32) {
    w := gs.ui.screen_w
    left = clamp(w * 0.08, 24, 140)
    width = wide ? min(560, w - 2 * left) : min(480, w - 2 * left)
    return
}

// The game's name, on two lines.
@(private="file")
menu_title :: proc(gs: ^Game_State) {
    size := u16(clamp(min(gs.ui.screen_h / 15, gs.ui.screen_w / 17), 28, 56))
    if clay.UI()({layout = {layoutDirection = .TopToBottom, padding = {0, 0, 0, 26}}}) {
        text("Endless Time", COLOR_TEXT, size, FONT_ID_TITLE)
        text("Consuming Worlds", COLOR_ACCENT, size, FONT_ID_TITLE)
    }
}

// A main-menu button: big, the label on the left, lit when the pointer is
// on it (or when it's the one to press: `lit`).
@(private="file")
menu_button :: proc(id: clay.ElementId, label: string, width: f32 = 320, height: f32 = 48, lit := false, danger := false) -> (clicked: bool) {
    hovered := clay.PointerOver(id)
    d: Ui_Deco = lit ? .Menu_Item_On : (hovered ? .Menu_Item_Hover : .Menu_Item)
    if clay.UI(id)({
        layout = {sizing = {width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(), clay.SizingFixed(height)}, padding = {22, 16, 0, 0}, childAlignment = {y = .Center}},
        custom = deco(d, radius = 8),
    }) {
        col := danger ? COLOR_BAD : (hovered || lit ? COLOR_ACCENT : COLOR_TEXT)
        text(label, col, 17, FONT_ID_TITLE)
    }
    clicked = hovered && gs_ui_left_pressed()
    if clicked { play(.Click, 0.4) }
    return
}

@(private="file")
menu_frame :: proc(gs: ^Game_State, m: ^Main_Menu, dt, wheel: f32) {
    ui := &gs.ui
    // A click anywhere but a text box stops typing.
    if ui.mouse_left_pressed && !ui.field_hovered { ui_type_into(gs, nil) }
    ui.field_hovered = false
    menu_begin(gs, dt, wheel)
    left, width := menu_column(gs, m.page == .Worlds)
    if clay.UI(clay.ID("MainMenu"))({
        layout = {layoutDirection = .TopToBottom, childGap = 10, sizing = {clay.SizingFixed(width), clay.SizingFit()}},
        floating = {attachTo = .Root, offset = {left, 0}, attachment = {.LeftCenter, .LeftCenter}},
    }) {
        menu_title(gs)
        switch m.page {
        case .Title:
            if menu_button(clay.ID("MenuWorlds"), "Worlds") { m.page = .Worlds }
            if menu_button(clay.ID("MenuSandbox"), "Entity Sandbox") { m.choice = .Sandbox }
            if menu_button(clay.ID("MenuQuit"), "Quit", danger = true) { m.choice = .Quit }
        case .Worlds:
            menu_worlds(gs, m)
        }
    }
    // Which build this is, for bug reports (release.odin).
    if clay.UI(clay.ID("Version"))({layout = {padding = {0, 14, 0, 10}}, floating = {attachTo = .Root, attachment = {.RightBottom, .RightBottom}}}) {
        text(GAME_VERSION, COLOR_TEXT_FAINT, 12)
    }
    menu_end(gs)
}

@(private="file")
menu_worlds :: proc(gs: ^Game_State, m: ^Main_Menu) {
    // Not `len > 0 && clay.UI(...)`: the element's close is deferred to the
    // end of the if, and would run without the open (an empty list hung
    // Clay in a loop of errors).
    if len(m.worlds) > 0 {
        if clay.UI(clay.ID("WorldList"))({
            layout = {layoutDirection = .TopToBottom, childGap = 6, sizing = {clay.SizingGrow(), clay.SizingFit({max = 290})}},
            clip = {vertical = true, childOffset = clay.GetScrollOffset()},
        }) {
            now := time.now()
            for w, i in m.worlds {
                id := clay.ID("World", u32(i))
                hovered := clay.PointerOver(id)
                on := i == m.picked
                d: Ui_Deco = on ? .Menu_Item_On : (hovered ? .Menu_Item_Hover : .Menu_Item)
                if clay.UI(id)({
                    layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(52)}, padding = {22, 18, 0, 0}, childGap = 12, childAlignment = {y = .Center}},
                    custom = deco(d, radius = 8),
                }) {
                    text(w.name, on ? COLOR_ACCENT : COLOR_TEXT, 17, FONT_ID_TITLE)
                    spacer()
                    text(world_info(now, w), COLOR_TEXT_DIM, 13)
                }
                if hovered && gs_ui_left_pressed() {
                    now_ms := SDL.GetTicks()
                    if on && now_ms - m.clicked < 400 { m.choice = .World } // a double click plays it
                    m.picked, m.clicked = i, now_ms
                    play(.Click, 0.4)
                }
            }
        }
    }
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8, padding = {0, 0, 4, 0}}}) {
        submitted := text_field(gs, clay.ID("NewWorldName"), &m.new_name, "New world", height = 44)
        if menu_button(clay.ID("NewWorldMode"), m.survival ? "Survival" : "Creative", width = 120, height = 44, lit = m.survival) { m.survival = !m.survival }
        if menu_button(clay.ID("NewWorld"), "Create", width = 120, height = 44) || submitted { menu_new_world(m) }
    }
    // Someone else's game: its address (on this PC, 127.0.0.1).
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8}}) {
        submitted := text_field(gs, clay.ID("JoinAddress"), &m.join_to, "Join a game: its address", height = 44)
        if menu_button(clay.ID("Join"), "Join", width = 120, height = 44) || submitted {
            if strings.trim_space(string(m.join_to.buf[:m.join_to.len])) == "" {
                m.note = "Type the address of the game to join."
            } else {
                m.choice = .Join
            }
        }
    }
    if m.note != "" { text(m.note, COLOR_BAD, 13) }
    if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = 8, padding = {0, 0, 10, 0}}}) {
        if menu_button(clay.ID("WorldsBack"), "Back", width = 120) { m.page = .Title }
        spacer()
        if m.picked >= 0 && menu_button(clay.ID("WorldPlay"), "Play", width = 200, lit = true) { m.choice = .World }
    }
}

// "1,949 chunks edited  ·  38 min ago"
@(private="file")
world_info :: proc(now: time.Time, w: World_Entry) -> string {
    edits := w.columns == 0 ? "new" : fmt.tprintf("%s chunk%s edited", thousands(w.columns), w.columns == 1 ? "" : "s")
    if w.survival { edits = fmt.tprintf("Survival  ·  %s", edits) }
    if time.time_to_unix(w.played) <= 0 { return edits }
    s := time.duration_seconds(time.diff(w.played, now))
    ago: string
    switch {
    case s < 120:       ago = "just now"
    case s < 3600:      ago = fmt.tprintf("%d min ago", int(s / 60))
    case s < 2 * 86400: ago = fmt.tprintf("%d h ago", int(s / 3600))
    case:               ago = fmt.tprintf("%d days ago", int(s / 86400))
    }
    return fmt.tprintf("%s  ·  %s", edits, ago)
}

// The menu's backdrop: views of the world itself (bench backdrops renders
// them into resources/menu/), one at a time, slowly drifting closer, each
// fading into the next; darkened on the left, under the menu.
BACKDROP_HOLD :: f32(12)  // seconds each one shows
BACKDROP_FADE :: f32(2.5) // ...of which fading into the next

@(private="file")
Backdrops :: struct {
    tex:   [len(BACKDROP_VIEWS)]^SDL.Texture,
    tried: [len(BACKDROP_VIEWS)]bool, // loaded, or found missing
    first: int, // the one shown first: a different one each run
    t0:    u64, // ms, when the menu first drew
}

@(private="file")
backdrops: Backdrops

// Backdrop i, loaded the first time it's wanted (nil if its file is missing).
@(private="file")
backdrop_texture :: proc(r: ^SDL.Renderer, i: int) -> ^SDL.Texture {
    b := &backdrops
    if b.tried[i] { return b.tex[i] }
    b.tried[i] = true
    views := BACKDROP_VIEWS
    w, h, n: i32
    px := stbi.load(fmt.ctprintf("resources/menu/%s.jpg", views[i].name), &w, &h, &n, 4)
    if px == nil { return nil }
    defer stbi.image_free(px)
    t := SDL.CreateTexture(r, .RGBA32, .STATIC, w, h)
    if t == nil { return nil }
    _ = SDL.UpdateTexture(t, nil, px, w * 4)
    _ = SDL.SetTextureScaleMode(t, .LINEAR)
    _ = SDL.SetTextureBlendMode(t, {.BLEND})
    b.tex[i] = t
    return t
}

// Done with the menu (the world is up): its pictures go.
main_menu_free_backdrops :: proc() {
    for &t in backdrops.tex {
        if t != nil { SDL.DestroyTexture(t) }
        t = nil
    }
    backdrops.tried = {}
}

menu_backdrop :: proc(r: ^SDL.Renderer, rect: SDL.FRect) {
    b := &backdrops
    if b.t0 == 0 {
        b.t0 = max(SDL.GetTicks(), 1)
        b.first = rand.int_max(len(b.tex))
    }
    t := f32(SDL.GetTicks() - b.t0) / 1000
    k := int(t / BACKDROP_HOLD)
    n := len(b.tex)
    cur, next := (b.first + k) % n, (b.first + k + 1) % n
    tex := backdrop_texture(r, cur)
    if tex == nil {
        menu_backdrop_drawn(r, rect)
        return
    }
    // Image j of the run shows from (j * HOLD - FADE) to (j + 1) * HOLD,
    // zooming in a little and drifting, each its own way.
    show :: proc(r: ^SDL.Renderer, tex: ^SDL.Texture, rect: SDL.FRect, j: int, t, alpha: f32) {
        tw, th: f32
        _ = SDL.GetTextureSize(tex, &tw, &th)
        u := clamp((t - f32(j) * BACKDROP_HOLD + BACKDROP_FADE) / (BACKDROP_HOLD + BACKDROP_FADE), 0, 1)
        zoom := 1.04 + 0.08 * u
        // The largest part of the image with the screen's shape, made smaller by zoom.
        sw, sh := tw, tw * rect.h / rect.w
        if sh > th { sw, sh = th * rect.w / rect.h, th }
        sw, sh = sw / zoom, sh / zoom
        dir := j % 2 == 0 ? f32(1) : -1
        cx := tw / 2 + dir * (u - 0.5) * (tw - sw) * 0.6
        cy := th / 2 + (0.5 - u) * (th - sh) * 0.3
        src := SDL.FRect{clamp(cx - sw / 2, 0, tw - sw), clamp(cy - sh / 2, 0, th - sh), sw, sh}
        dst := rect
        _ = SDL.SetTextureAlphaModFloat(tex, alpha)
        _ = SDL.RenderTexture(r, tex, &src, &dst)
    }
    show(r, tex, rect, k, t, 1)
    phase := t - f32(k) * BACKDROP_HOLD
    if phase > 1 {
        // Loaded ahead (a stall of a few ms, now rather than mid-fade).
        if nt := backdrop_texture(r, next); nt != nil && phase > BACKDROP_HOLD - BACKDROP_FADE {
            a := (phase - (BACKDROP_HOLD - BACKDROP_FADE)) / BACKDROP_FADE
            show(r, nt, rect, k + 1, t, a * a * (3 - 2 * a))
        }
    }
    // Shade: a little all over, deep down the left where the menu is.
    // One mesh, columns of shade eased from the left edge to 0.7 of the way.
    STEPS :: 16
    verts: [2 * (STEPS + 2)]SDL.Vertex
    idx: [6 * (STEPS + 1)]i32
    for i in 0 ..= STEPS + 1 {
        x := i <= STEPS ? f32(i) / STEPS * 0.7 : 1
        a := 0.12 + 0.62 * math.pow(max(1 - x / 0.7, 0), 1.6)
        c := SDL.FColor{0.03, 0.03, 0.06, a}
        verts[2 * i] = {position = {rect.x + x * rect.w, rect.y}, color = c}
        verts[2 * i + 1] = {position = {rect.x + x * rect.w, rect.y + rect.h}, color = c}
        if i > 0 {
            k, v := 6 * (i - 1), i32(2 * i)
            idx[k], idx[k + 1], idx[k + 2], idx[k + 3], idx[k + 4], idx[k + 5] = v - 2, v - 1, v, v, v - 1, v + 1
        }
    }
    _ = SDL.SetRenderDrawBlendMode(r, {.BLEND})
    _ = SDL.RenderGeometry(r, nil, &verts[0], len(verts), &idx[0], len(idx))
}

// Without the pictures: a dusk sky with a blocky sun going down behind
// three layers of blocky hills drifting by, far to near. Plain rectangles.
@(private="file")
menu_backdrop_drawn :: proc(r: ^SDL.Renderer, rect: SDL.FRect) {
    t := f32(SDL.GetTicks()) / 1000
    w, h := rect.w, rect.h
    horizon := rect.y + h * 0.66
    fill :: proc(r: ^SDL.Renderer, x, y, w, h: f32, c: [3]f32, a: f32 = 1) {
        SDL.SetRenderDrawColorFloat(r, c.r / 255, c.g / 255, c.b / 255, a)
        b := SDL.FRect{x, y, w, h}
        SDL.RenderFillRect(r, &b)
    }
    hash :: proc(i, k: int) -> f32 {
        x := u32(i) * 374761393 + u32(k) * 668265263
        x = (x ~ (x >> 13)) * 1274126177
        x ~= x >> 16
        return f32(x & 0xffff) / 65535
    }

    // Sky: night above, a violet glow down at the horizon.
    SKY_TOP :: [3]f32{12, 12, 23}
    SKY_LOW :: [3]f32{74, 50, 88}
    BANDS :: 48
    band := (horizon - rect.y) / BANDS
    for i in 0 ..< BANDS {
        k := f32(i) / (BANDS - 1)
        fill(r, rect.x, rect.y + f32(i) * band, w, band + 1, SKY_TOP + (SKY_LOW - SKY_TOP) * k * k)
    }
    fill(r, rect.x, horizon, w, rect.y + h - horizon, SKY_LOW)

    // Stars, twinkling, fewer toward the horizon.
    px := max(1, math.round(h / 420))
    for i in 0 ..< 110 {
        hy := hash(i, 2)
        a := (0.2 + 0.45 * hash(i, 3)) * (0.65 + 0.35 * math.sin(t * (0.5 + 1.5 * hash(i, 4)) + f32(i))) * (1 - hy)
        s := hash(i, 5) > 0.9 ? 2 * px : px
        fill(r, rect.x + hash(i, 1) * w, rect.y + hy * hy * (horizon - rect.y) * 0.9, s, s, {232, 226, 255}, a)
    }

    // The sun: discs of blocks, a soft glow round it, sinking behind the hills.
    bs := max(2, math.round(h / 110))
    cx, cy := rect.x + w * 0.7, horizon - h * 0.05
    R := h * 0.1
    Disc :: struct { radius: f32, col: [3]f32, a: f32 }
    for d in ([3]Disc{{R * 2.1, {250, 179, 135}, 0.05}, {R * 1.5, {250, 179, 135}, 0.09}, {R, {252, 196, 152}, 1}}) {
        n := int(d.radius / bs)
        for row in -n ..< n {
            y := (f32(row) + 0.5) * bs
            half := math.floor(math.sqrt(max(d.radius * d.radius - y * y, 0)) / bs) * bs
            if half <= 0 { continue }
            col := d.col
            if d.a == 1 { col = la.lerp(d.col, [3]f32{243, 139, 168}, clamp(f32(row) / f32(n) * 0.8 + 0.2, 0, 1)) } // rose toward its foot
            fill(r, cx - half, cy + f32(row) * bs, 2 * half, bs, col, d.a)
        }
    }

    // Hills, far to near: each nearer layer darker, its blocks bigger, and
    // drifting faster.
    Layer :: struct { col, top: [3]f32 }
    layers := [3]Layer{
        {{56, 41, 80}, {70, 52, 97}},
        {{35, 29, 57}, {47, 38, 73}},
        {{20, 19, 35}, {30, 28, 50}},
    }
    for layer, li in layers {
        lf := f32(li)
        size := math.round(h * (0.014 + 0.012 * lf))
        off := t * h * (0.004 + 0.009 * lf)
        base := horizon + h * (0.03 + 0.13 * lf)
        amp := h * (0.14 + 0.03 * lf) // nearer, bigger
        c0 := int(math.floor(off / size)) - 1
        for c in c0 ..< c0 + int(w / size) + 3 {
            u := f32(c) * size / h + lf * 7.3
            hill := amp * (0.55 + 0.25 * math.sin(u * 3.7) + 0.13 * math.sin(u * 8.9 + 1.7) + 0.07 * math.sin(u * 19 + 0.4))
            top := base - math.round(hill / size) * size
            x := rect.x + f32(c) * size - off
            fill(r, x, top, size + 0.5, rect.y + h - top, layer.col)
            fill(r, x, top, size + 0.5, size, layer.top)
        }
    }
}

// `bench ui`: the main menu's two pages and the loading screen, drawn
// offscreen at each size, as <dir>/menu_<page>_<w>x<h>.bmp.
main_menu_bench :: proc(gs: ^Game_State, dir: string, sizes: [][2]i32) {
    m := new_clone(Main_Menu{picked = -1})
    defer {
        for w in m.worlds { delete(w.name) }
        delete(m.worlds)
        free(m)
    }
    menu_scan_worlds(m)
    none := new_clone(Main_Menu{picked = -1, page = .Worlds}) // a fresh install: no saves/ yet
    defer free(none)
    r := gs.ui.renderer_data.renderer
    for name in ([]string{"title", "worlds", "worlds_none", "loading"}) {
        for sz in sizes {
            target := SDL.CreateTexture(r, .RGBA32, .TARGET, sz.x, sz.y)
            _ = SDL.SetRenderTarget(r, target)
            gs.ui.mouse_pos = {f32(sz.x) * 0.12, f32(sz.y) * 0.5 + 40} // over a button: its hover look
            for _ in 0 ..< 2 { // Clay measures on the first layout, positions on the second
                switch name {
                case "title":   m.page = .Title; menu_frame(gs, m, 1.0 / 60, 0)
                case "worlds":  m.page = .Worlds; menu_frame(gs, m, 1.0 / 60, 0)
                case "worlds_none": menu_frame(gs, none, 1.0 / 60, 0)
                case "loading": main_menu_loading(gs, "world")
                }
            }
            surf := SDL.RenderReadPixels(r, nil)
            path := fmt.tprintf("%s/menu_%s_%dx%d.bmp", dir, name, sz.x, sz.y)
            if surf == nil || !SDL.SaveBMP(surf, strings.clone_to_cstring(path, context.temp_allocator)) {
                fmt.eprintln("bench ui: couldn't save", path, SDL.GetError())
            }
            SDL.DestroySurface(surf)
            _ = SDL.SetRenderTarget(r, nil)
            SDL.DestroyTexture(target)
            free_all(context.temp_allocator)
        }
    }
}

// The worlds in saves/, the last played first.
@(private="file")
menu_scan_worlds :: proc(m: ^Main_Menu) {
    dirs, err := os.read_all_directory_by_path("saves", context.temp_allocator)
    if err != nil { return }
    for d in dirs {
        if d.type != .Directory || strings.has_prefix(d.name, ".") { continue }
        w := World_Entry{name = strings.clone(d.name), played = d.modification_time, survival = world_survival_load(d.fullpath)}
        files, _ := os.read_all_directory_by_path(d.fullpath, context.temp_allocator)
        for f in files {
            if strings.has_prefix(f.name, "c.") { w.columns += 1 }
            if time.diff(w.played, f.modification_time) > 0 { w.played = f.modification_time }
        }
        append(&m.worlds, w)
    }
    slice.sort_by(m.worlds[:], proc(a, b: World_Entry) -> bool { return time.diff(a.played, b.played) < 0 })
    if len(m.worlds) > 0 { m.picked = 0 }
}

// A world under the name typed: picked, and played on Play. Its folder is
// made when it's opened (save.odin).
@(private="file")
menu_new_world :: proc(m: ^Main_Menu) {
    name := strings.trim_space(string(m.new_name.buf[:m.new_name.len]))
    m.note = ""
    switch {
    case name == "":
        m.note = "Type a name for it first."
        return
    case strings.has_prefix(name, "."):
        m.note = "A name can't start with a dot."
        return
    }
    for c in transmute([]u8)name {
        ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == ' ' || c == '-' || c == '_'
        if !ok { m.note = "Letters, digits, spaces, - and _ only."; return }
    }
    for w, i in m.worlds {
        if strings.equal_fold(w.name, name) { m.picked = i; m.note = "There's a world by that name already: picked it."; return }
    }
    inject_at(&m.worlds, 0, World_Entry{name = strings.clone(name), survival = m.survival})
    if m.survival { world_survival_save(fmt.tprintf("saves/%s", name), true) }
    m.picked = 0
    m.new_name.len = 0
    m.choice = .World
}
