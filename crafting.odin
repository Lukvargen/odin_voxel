package main

// Survival's things that aren't blocks, and making things, as in Terraria:
// the inventory (E) lists every recipe, the ones you can make now first.
// A few are made by hand; the rest need a workbench (or later, other
// stations) close by. What you make the server counts, as it counts blocks
// (items.odin): the client asks (Msg_Craft) and guesses the answer under
// the same edit number, so the inventory answers at once.

// Weapons: R swaps the hotbar for the weapon bar (WEAPON_SLOTS of them, keys
// 1-4); an empty slot is your fists (combat.odin).
Weapon :: enum u8 { None, Wooden_Sword, Stone_Sword, Steel_Sword }
WEAPON_SLOTS :: 4

Weapon_Info :: struct {
    name:   string,
    model:  Model_Id, // in the hand (combat.odin); fists: none drawn but the fist
    damage: f32,      // times the sword's swings (ATTACKS); fists have their own (FIST_ATTACKS)
    reach:  f32,      // times the sword's
}

WEAPONS := [Weapon]Weapon_Info{
    .None         = {name = "Fists"},
    .Wooden_Sword = {name = "Wooden sword", model = .Wood_Sword,  damage = 0.55, reach = 0.9},
    .Stone_Sword  = {name = "Stone sword",  model = .Stone_Sword, damage = 0.8,  reach = 0.95},
    .Steel_Sword  = {name = "Steel sword",  model = .Sword,       damage = 1,    reach = 1},
}

// Creative's weapon bar; survival's starts empty: fists.
DEFAULT_WEAPON_BAR :: [WEAPON_SLOTS]Weapon{.Steel_Sword, .Stone_Sword, .Wooden_Sword, .None}

// Where a recipe can be made: anywhere, or near one of these blocks.
Station :: enum u8 { Hand, Workbench }

STATION_BLOCK := [Station]Block_Type{.Hand = .Air, .Workbench = .Workbench}

// How near a station counts (voxels from the eye, each way; up and down less).
STATION_REACH   :: 6
STATION_REACH_Y :: 4

// Something a recipe takes: n of any of these blocks, the first you have
// first (any wood is wood).
Ingredient :: struct {
    name: string,
    of:   []Block_Type,
    n:    u32,
}

Recipe :: struct {
    block:   Block_Type, // what it makes: a block...
    weapon:  Weapon,     // ...or a weapon
    count:   u32,
    station: Station,
    needs:   []Ingredient,
}

WOOD  := []Block_Type{.Log, .Birch_Log, .Spruce_Log, .Acacia_Log}
STONE := []Block_Type{.Stone, .Weathered_Stone}
COAL  := []Block_Type{.Coal_Ore}

// Every recipe, by hand first, in the order the list shows them. Their
// index is what Msg_Craft carries: add new ones at the end of their station.
RECIPES := []Recipe{
    {block = .Workbench, count = 1, station = .Hand, needs = {{"Wood", WOOD, 10}}},
    {block = .Torch, count = 4, station = .Hand, needs = {{"Wood", WOOD, 1}, {"Coal ore", COAL, 1}}},
    {weapon = .Wooden_Sword, count = 1, station = .Workbench, needs = {{"Wood", WOOD, 8}}},
    {weapon = .Stone_Sword, count = 1, station = .Workbench, needs = {{"Wood", WOOD, 3}, {"Stone", STONE, 10}}},
    {block = .Door, count = 1, station = .Workbench, needs = {{"Wood", WOOD, 6}}},
    {block = .Stone_Bricks, count = 4, station = .Workbench, needs = {{"Stone", STONE, 4}}},
}

recipe_name :: proc(r: Recipe) -> string {
    return r.weapon != .None ? WEAPONS[r.weapon].name : block_name(r.block)
}

// How many of an ingredient there are among `items`.
ingredient_have :: proc(items: ^[Block_Type]u32, ing: Ingredient) -> (n: u32) {
    for b in ing.of { n += items[b] }
    return
}

// Whether `items` hold all a recipe takes.
recipe_affordable :: proc(items: ^[Block_Type]u32, r: Recipe) -> bool {
    for ing in r.needs { if ingredient_have(items, ing) < ing.n { return false } }
    return true
}

// What making recipe r once takes and gives, as a change to the counts;
// the same on the server and the client, so the guess comes out right.
recipe_delta :: proc(items: ^[Block_Type]u32, r: Recipe) -> (blocks: [Block_Type]i32, weapons: [Weapon]i32) {
    for ing in r.needs {
        left := ing.n
        for b in ing.of {
            take := min(left, items[b] - u32(max(-blocks[b], 0)))
            blocks[b] -= i32(take)
            left -= take
            if left == 0 { break }
        }
    }
    if r.weapon != .None { weapons[r.weapon] += i32(r.count) } else { blocks[r.block] += i32(r.count) }
    return
}

// Whether a station block is within reach of `eye` (any, for .Hand).
station_near :: proc(w: ^World, eye: [3]f32, s: Station, slack := 0) -> bool {
    if s == .Hand { return true }
    want := u8(STATION_BLOCK[s])
    c := [3]int{int(eye.x), int(eye.y), int(eye.z)}
    r, ry := STATION_REACH + slack, STATION_REACH_Y + slack
    for dy in -ry - 1 ..= ry { for dz in -r ..= r { for dx in -r ..= r {
        if u8(get_voxel(w, c.x + dx, c.y + dy, c.z + dz)) == want { return true }
    } } }
    return false
}

// The stations near the player now (the inventory's crafting list).
stations_near :: proc(gs: ^Game_State) -> (near: [Station]bool) {
    for s in Station { near[s] = station_near(gs, gs.camera.pos, s) }
    return
}

// ─── The client ────────────────────────────────────────────────────────────

Msg_Craft :: struct {
    seq:    u32, // the edit number it's counted under (Item_Guess)
    recipe: u16, // in RECIPES
}

// Makes recipe i once, if we can: counted now (a guess, as edits are) and
// asked of the server. A new weapon takes the first empty weapon slot.
craft :: proc(gs: ^Game_State, i: int) -> bool {
    if !gs.survival || i < 0 || i >= len(RECIPES) { return false }
    r := RECIPES[i]
    if !station_near(gs, gs.camera.pos, r.station) || !recipe_affordable(&gs.items, r) { return false }
    n := &gs.net
    n.edit_seq += 1
    g := Item_Guess{seq = n.edit_seq}
    g.delta, g.weapons = recipe_delta(&gs.items, r)
    append(&n.item_guesses, g)
    client_items_sum(gs)
    client_send(gs, .Craft, Msg_Craft{seq = n.edit_seq, recipe = u16(i)})
    if r.weapon != .None { weapon_collect(gs, r.weapon) }
    if r.block != .Air { magic_collect(gs, r.block, r.count) } // into the hotbar, as unwoven blocks go
    return true
}

// What weapons we have (survival; in creative, every one).
weapon_owned :: proc(gs: ^Game_State, w: Weapon) -> bool {
    return w == .None || !gs.survival || gs.weapons[w] > 0
}

// The weapon bar's slot `slot` in hand: what's in it, or fists if it's
// empty or not ours (any more).
weapon_select :: proc(gs: ^Game_State, slot: int) {
    gs.weapon_slot = clamp(slot, 0, WEAPON_SLOTS - 1)
    w := gs.weapon_bar[gs.weapon_slot]
    if !weapon_owned(gs, w) { w = .None }
    c := &gs.combat
    if c.weapon == w { return }
    c.weapon = w
    c.attack, c.queued = .None, .None
    if c.fighting && w != .None { play(.Sword_Draw, 0.6, vary(0.05)) }
}

// A weapon just made: into the first empty weapon slot, unless it's on the
// bar already.
@(private="file")
weapon_collect :: proc(gs: ^Game_State, w: Weapon) {
    for h in gs.weapon_bar { if h == w { return } }
    for h, i in gs.weapon_bar {
        if h != .None { continue }
        gs.weapon_bar[i] = w
        if i == gs.weapon_slot { weapon_select(gs, i) }
        return
    }
}

// ─── The server ────────────────────────────────────────────────────────────

// Player `slot` makes recipe m.recipe: if it's near what it takes and has
// the makings, counted. Either way the player hears its count, which
// answers its guess.
server_craft :: proc(srv: ^Server, slot: int, m: Msg_Craft) {
    if !srv.survival { return }
    srv.items_seq[slot], srv.items_due[slot] = m.seq, true
    if int(m.recipe) >= len(RECIPES) { return }
    r := RECIPES[m.recipe]
    pl := &srv.sim.players[slot]
    items := &srv.items[slot]
    if !pl.active || !station_near(srv.sim.world, pl.pos, r.station, slack = 2) || !recipe_affordable(items, r) { return }
    blocks, weapons := recipe_delta(items, r)
    for d, b in blocks { items[b] = u32(i64(items[b]) + i64(d)) }
    for d, w in weapons { srv.weapons[slot][w] = u32(i64(srv.weapons[slot][w]) + i64(d)) }
}
