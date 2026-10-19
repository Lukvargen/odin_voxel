package main

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

// How a player looks: what they wear and their colouring, picked on the
// Character screen (ui.odin), kept in LOOK_FILE for every world, and told
// to the server (Set_Look) so the others see it. The models are in
// player_model.odin; every part of the body carries the look's four
// colours (Paint), each voxel taking the one its palette entry names.

LOOK_FILE :: "saves/look.txt"

Look_Outfit :: enum u8 {
    Robe,   // to mid-calf, split for the stride; wide sleeves; a sash
    Tunic,  // to mid-thigh, belted; a leather jerkin; bracers
    Coat,   // to the knee, open over a shirt; a high collar, turned cuffs
    Padded, // a quilted jack; leather at the shoulders and cuffs
}

Look_Back :: enum u8 { None, Cape, Cloak, Scarf }

Look_Headwear :: enum u8 { Hood, Bare, Wizard_Hat, Wide_Hat, Circlet }

Look_Hair :: enum u8 { Short, Swept, Long, Tied, Braid, Bun, Shaved }

// The build: the feminine narrower at the shoulders and waist, wider at
// the hips, its face finer. The same height (the eyes are the camera's).
Look_Body :: enum u8 { Masculine, Feminine }

Look_Beard :: enum u8 { None, Stubble, Short, Full }

Look :: struct {
    body:     Look_Body,
    outfit:   Look_Outfit,
    back:     Look_Back,
    headwear: Look_Headwear,
    hair:     Look_Hair,
    beard:    Look_Beard,
    cloth:    u8, // DYES: the outfit (and the hood, the hat)
    accent:   u8, // DYES: the second cloth (trousers, sash, cloak, scarf, the hat's band)
    skin:     u8, // SKINS
    hair_col: u8, // HAIR_COLORS (brows and beard too)
}

// Natural dyes, muted as wool takes them: nothing bright, so a player sits
// in the world's colours (the sunlit view brightens them a good deal).
Dye :: struct { name: string, rgb: [3]f32 }

DYES := [?]Dye{
    {"Woad",     {0.18, 0.22, 0.32}},
    {"Indigo",   {0.11, 0.12, 0.21}},
    {"Madder",   {0.42, 0.16, 0.13}},
    {"Wine",     {0.22, 0.10, 0.11}},
    {"Moss",     {0.23, 0.28, 0.18}},
    {"Forest",   {0.13, 0.19, 0.14}},
    {"Ochre",    {0.49, 0.38, 0.23}},
    {"Rust",     {0.34, 0.21, 0.14}},
    {"Plum",     {0.25, 0.16, 0.24}},
    {"Teal",     {0.14, 0.26, 0.26}},
    {"Wool",     {0.58, 0.55, 0.48}},
    {"Ash",      {0.35, 0.35, 0.35}},
    {"Charcoal", {0.12, 0.12, 0.13}},
    {"Hide",     {0.30, 0.22, 0.16}},
}

SKINS := [?][3]f32{
    {0.80, 0.63, 0.52},
    {0.76, 0.56, 0.43},
    {0.71, 0.51, 0.38},
    {0.60, 0.43, 0.30},
    {0.45, 0.30, 0.20},
    {0.29, 0.19, 0.13},
}

HAIR_COLORS := [?][3]f32{
    {0.09, 0.08, 0.08}, // black
    {0.22, 0.14, 0.09}, // dark brown
    {0.34, 0.21, 0.12}, // brown
    {0.50, 0.21, 0.10}, // auburn
    {0.74, 0.58, 0.33}, // fair
    {0.58, 0.57, 0.55}, // grey
    {0.86, 0.85, 0.81}, // white
}

// Ready-made looks: the Character screen's starting points, and what a
// player looks like before picking (the first). On a feminine body, the
// hair the preset wears there (and no beard).
Look_Preset :: struct { name: string, look: Look, fem_hair: Look_Hair }

LOOK_PRESETS := [?]Look_Preset{
    {"Hedge mage",  {outfit = .Robe,   back = .Cape,  headwear = .Hood,       hair = .Short,  beard = .None,    cloth = 0,  accent = 1,  skin = 2, hair_col = 2}, .Long},
    {"Wanderer",    {outfit = .Robe,   back = .Cloak, headwear = .Wizard_Hat, hair = .Long,   beard = .Full,    cloth = 11, accent = 12, skin = 1, hair_col = 5}, .Long},
    {"Ranger",      {outfit = .Tunic,  back = .Cloak, headwear = .Bare,       hair = .Tied,   beard = .Stubble, cloth = 4,  accent = 13, skin = 3, hair_col = 1}, .Braid},
    {"Scholar",     {outfit = .Coat,   back = .None,  headwear = .Circlet,    hair = .Swept,  beard = .None,    cloth = 8,  accent = 6,  skin = 0, hair_col = 4}, .Bun},
    {"Pilgrim",     {outfit = .Tunic,  back = .Scarf, headwear = .Wide_Hat,   hair = .Braid,  beard = .None,    cloth = 10, accent = 2,  skin = 4, hair_col = 0}, .Braid},
    {"Sellsword",   {outfit = .Padded, back = .Cape,  headwear = .Bare,       hair = .Shaved, beard = .Short,   cloth = 7,  accent = 12, skin = 5, hair_col = 1}, .Tied},
    {"Tidecaller",  {outfit = .Coat,   back = .Scarf, headwear = .Hood,       hair = .Long,   beard = .None,    cloth = 9,  accent = 10, skin = 2, hair_col = 3}, .Long},
    {"Hearthkeep",  {outfit = .Padded, back = .None,  headwear = .Wide_Hat,   hair = .Short,  beard = .Full,    cloth = 3,  accent = 6,  skin = 1, hair_col = 3}, .Bun},
}

// A preset put on: what it wears and its colouring, on your own body.
look_apply_preset :: proc(cur: Look, preset: Look_Preset) -> Look {
    l := preset.look
    l.body = cur.body
    if l.body == .Feminine { l.hair, l.beard = preset.fem_hair, .None }
    return l
}

DEFAULT_LOOK :: Look{outfit = .Robe, back = .Cape, headwear = .Hood, hair = .Short, beard = .None, cloth = 0, accent = 1, skin = 2, hair_col = 2}

// A look as received: every field in range, so a bad one draws something.
look_clean :: proc(l: Look) -> Look {
    l := l
    if int(l.body) >= len(Look_Body) { l.body = .Masculine }
    if int(l.outfit) >= len(Look_Outfit) { l.outfit = .Robe }
    if int(l.back) >= len(Look_Back) { l.back = .None }
    if int(l.headwear) >= len(Look_Headwear) { l.headwear = .Bare }
    if int(l.hair) >= len(Look_Hair) { l.hair = .Short }
    if int(l.beard) >= len(Look_Beard) { l.beard = .None }
    l.cloth = u8(min(int(l.cloth), len(DYES) - 1))
    l.accent = u8(min(int(l.accent), len(DYES) - 1))
    l.skin = u8(min(int(l.skin), len(SKINS) - 1))
    l.hair_col = u8(min(int(l.hair_col), len(HAIR_COLORS) - 1))
    return l
}

// The look's four colours, as a body's parts carry them (ent_paint).
Paint :: struct {
    cloth, accent, skin, hair: [3]f32,
}

look_paint :: proc(l: Look) -> Paint {
    l := look_clean(l)
    return {DYES[l.cloth].rgb, DYES[l.accent].rgb, SKINS[l.skin], HAIR_COLORS[l.hair_col]}
}

// Every colour toward c by k (a struck body's red flash).
paint_flash :: proc(p: Paint, c: [3]f32, k: f32) -> Paint {
    if k <= 0 { return p }
    mix :: proc(a, b: [3]f32, k: f32) -> [3]f32 { return a + (b - a) * k }
    return {mix(p.cloth, c, k), mix(p.accent, c, k), mix(p.skin, c, k), mix(p.hair, c, k)}
}

// ─── Keeping it ─────────────────────────────────────────────────────────────

// The look as text: one `field=Name` per line (colours by their names).
look_text :: proc(l: Look) -> string {
    l := look_clean(l)
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b, "body=%v\n", l.body)
    fmt.sbprintf(&b, "outfit=%v\nback=%v\nheadwear=%v\nhair=%v\nbeard=%v\n", l.outfit, l.back, l.headwear, l.hair, l.beard)
    fmt.sbprintf(&b, "cloth=%s\naccent=%s\nskin=%d\nhair_color=%d\n", DYES[l.cloth].name, DYES[l.accent].name, l.skin, l.hair_col)
    return strings.to_string(b)
}

// The look a text says, from `base` (fields it doesn't name stay as there).
look_parse :: proc(s: string, base := DEFAULT_LOOK) -> (l: Look) {
    l = base
    enum_of :: proc(v: string, $E: typeid) -> (E, bool) { return reflect.enum_from_name(E, v) }
    dye_of :: proc(v: string) -> (u8, bool) {
        for d, i in DYES { if strings.equal_fold(d.name, v) { return u8(i), true } }
        return 0, false
    }
    for line in strings.split_lines(s, context.temp_allocator) {
        eq := strings.index_byte(line, '=')
        if eq < 0 { continue }
        key, v := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
        switch key {
        case "body":       if e, ok := enum_of(v, Look_Body); ok { l.body = e }
        case "outfit":     if e, ok := enum_of(v, Look_Outfit); ok { l.outfit = e }
        case "back":       if e, ok := enum_of(v, Look_Back); ok { l.back = e }
        case "headwear":   if e, ok := enum_of(v, Look_Headwear); ok { l.headwear = e }
        case "hair":       if e, ok := enum_of(v, Look_Hair); ok { l.hair = e }
        case "beard":      if e, ok := enum_of(v, Look_Beard); ok { l.beard = e }
        case "cloth":      if d, ok := dye_of(v); ok { l.cloth = d }
        case "accent":     if d, ok := dye_of(v); ok { l.accent = d }
        case "skin":       l.skin = u8(parse_small(v))
        case "hair_color": l.hair_col = u8(parse_small(v))
        }
    }
    return look_clean(l)
}

@(private="file")
parse_small :: proc(s: string) -> int {
    n := 0
    for c in transmute([]u8)s {
        if c < '0' || c > '9' || n > 99 { break }
        n = n * 10 + int(c - '0')
    }
    return n
}

look_load :: proc() -> Look {
    data, err := os.read_entire_file(LOOK_FILE, context.temp_allocator)
    if err != nil { return DEFAULT_LOOK }
    return look_parse(string(data))
}

// False in benches: the look picked is never kept.
look_keep := true

look_save :: proc(l: Look) {
    if !look_keep { return }
    s := look_text(l)
    _ = os.make_directory_all("saves")
    if err := os.write_entire_file(LOOK_FILE, transmute([]u8)s); err != nil { fmt.eprintln("Can't save the look:", err) }
}

// `look=<preset>` (on your body), `look.<field>=<value>` or
// `body=feminine|masculine`: the look
// for this run, not kept. Whether `a` was one of them. Give the body first:
// a preset put on a feminine body wears its hair for one.
look_arg :: proc(gs: ^Game_State, a: string) -> bool {
    switch {
    case strings.has_prefix(a, "look="):
        if p, ok := look_preset_by_name(a[5:]); ok { gs.look = look_apply_preset(gs.look, p) } else { fmt.eprintln("No look called", a[5:]) }
    case strings.has_prefix(a, "look."): // one field, as LOOK_FILE says it: look.back=None
        gs.look = look_parse(a[5:], gs.look)
    case a == "body=feminine":  gs.look.body = .Feminine
    case a == "body=masculine": gs.look.body = .Masculine
    case: return false
    }
    return true
}

// A preset by its name, any case, spaces as they are or as _ or none
// (`look=hedge_mage`).
look_preset_by_name :: proc(name: string) -> (Look_Preset, bool) {
    plain :: proc(s: string) -> string {
        b := strings.builder_make(context.temp_allocator)
        for c in transmute([]u8)s {
            if c == ' ' || c == '_' { continue }
            strings.write_byte(&b, c >= 'A' && c <= 'Z' ? c + 32 : c)
        }
        return strings.to_string(b)
    }
    for p in LOOK_PRESETS {
        if plain(p.name) == plain(name) { return p, true }
    }
    return {}, false
}
