package main

import "core:fmt"
import "core:math"
import la "core:math/linalg"

// `bench craft [dir]`: survival from nothing. A fresh character carries
// nothing; ten wood make a workbench by hand, and a sword only near one; the
// server counts all of it and turns down what it should. Fists punch (the
// jab with the left), swords by what they're made of; the spell leaves what
// is too hard for it yet, and trees too big. With a dir, shots of the
// inventory and of the fists and the wooden sword in hand.
bench_craft: bool

bench_craft_run :: proc(gs: ^Game_State) {
    ui_init(gs)
    defer ui_shutdown(gs)
    dir := bench_shot_dir
    day_set_hour(gs, 14, settle = true)
    x, z, found := bench_find_biome(.Plains)
    if !found { x, z = int(gs.camera.pos.x), int(gs.camera.pos.z) }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 3, f32(z) + 0.5})

    ok_all := true
    check :: proc(ok_all: ^bool, what: string, ok: bool) {
        fmt.printf("bench craft: %-52s %s\n", what, ok ? "ok" : "FAILED")
        if !ok { ok_all^ = false }
    }
    fresh := survival_fresh()
    nothing := fresh.hotbar == {} && fresh.weapon_bar == {}
    for n in fresh.items { if n > 0 { nothing = false } }
    for n in fresh.weapons { if n > 0 { nothing = false } }
    check(&ok_all, "a fresh survival character carries nothing", nothing)
    check(&ok_all, fmt.tprintf("a plains tree is fellable (26 logs: %.0f mana), a big one not (45: %.0f)", fell_mana(26), fell_mana(45)),
        fell_mana(26) <= MANA_MAX && fell_mana(45) > MANA_MAX + MANA_SLACK)

    bench_craft_server(&ok_all, {x, 0, z})

    // The client: standing on the plains with some wood and stone.
    gs.survival = true
    gs.mouse_locked = true
    cam := &gs.camera
    ground := ground_top(gs, x, z)
    cam.fly_mode = true // stays put
    cam.pos = {f32(x) + 0.5, f32(ground) + 1 + PLAYER_EYE_HEIGHT, f32(z) + 0.5}
    cam.yaw, cam.pitch = 90, -35
    clear(&gs.net.item_guesses)
    gs.net.items_base, gs.net.weapons_base = {}, {}
    gs.net.items_base[.Log] = 12
    gs.net.items_base[.Stone] = 14
    gs.net.items_base[.Coal_Ore] = 2
    gs.net.items_base[.Dirt] = 37
    client_items_sum(gs)
    gs.hotbar, gs.weapon_bar = {}, {}
    hotbar_select(gs, 0)
    weapon_select(gs, 0)
    heard :: proc(gs: ^Game_State) { // the server agrees with all we guessed
        client_items_heard(gs, Msg_Items{seq = gs.net.edit_seq, items = gs.items, weapons = gs.weapons})
    }
    recipe :: proc(b: Block_Type, w: Weapon) -> int {
        for r, i in RECIPES { if r.block == b && r.weapon == w { return i } }
        return -1
    }
    bench, wooden, stone := recipe(.Workbench, .None), recipe(.Air, .Wooden_Sword), recipe(.Air, .Stone_Sword)
    check(&ok_all, "no workbench near: only what's made by hand", !stations_near(gs)[.Workbench] && !craft(gs, wooden))
    check(&ok_all, "ten wood make a workbench, into the hotbar",
        craft(gs, bench) && gs.items[.Log] == 2 && gs.items[.Workbench] == 1 && gs.hotbar[0] == .Workbench)
    heard(gs)

    DT :: f32(1.0 / 60)
    step :: proc(gs: ^Game_State, left, right: bool) {
        gs.left_pressed  = left && !gs.left_held
        gs.right_pressed = right && !gs.right_held
        gs.left_held, gs.right_held = left, right
        build_update(gs, DT)
        magic_update(gs, DT)
        fx_update(gs, DT)
        flush_gpu_uploads(gs)
    }
    // Conjured onto the ground two steps ahead, as a player puts it down.
    hotbar_select(gs, 0)
    spot := [3]int{x + 2, ground_top(gs, x + 2, z), z}
    world_clear(gs, {spot + {0, 1, 0}, spot + {0, 2, 0}})
    d := block_center(spot + {0, 1, 0}) - [3]f32{0, 0.49, 0} - camera_aim_eye(cam^)
    cam.yaw = math.to_degrees(math.atan2(d.x, d.z))
    cam.pitch = math.to_degrees(math.atan2(d.y, la.length(d.xz)))
    // Where it goes: the face aimed at, or in place of a plant there.
    h, n, _ := raycast_voxel(gs, camera_aim_eye(cam^), camera_forward(cam^), MAGIC_REACH, plants = true)
    at := block_is_land_plant(u8(get_voxel(gs, h.x, h.y, h.z))) ? h : h + n
    step(gs, false, true)
    step(gs, false, false)
    put := Block_Type(u8(get_voxel(gs, at.x, at.y, at.z)))
    check(&ok_all, fmt.tprintf("conjured onto the ground (%v), it's near", put), put == .Workbench && stations_near(gs)[.Workbench] && gs.items[.Workbench] == 0)
    heard(gs)
    check(&ok_all, "with two wood left, no sword", !craft(gs, wooden))
    gs.net.items_base[.Log] += 10
    client_items_sum(gs)
    check(&ok_all, "near it, eight wood make a wooden sword, into the weapon bar",
        craft(gs, wooden) && gs.weapons[.Wooden_Sword] == 1 && gs.items[.Log] == 4 && gs.weapon_bar[0] == .Wooden_Sword)
    check(&ok_all, "...and three wood and ten stone a stone sword, beside it",
        craft(gs, stone) && gs.weapons[.Stone_Sword] == 1 && gs.items[.Stone] == 4 && gs.weapon_bar[1] == .Stone_Sword)
    heard(gs)

    // The weapon bar: R, then what's in each slot.
    combat_init(&gs.combat)
    gs.combat.weapon = .None
    weapon_select(gs, 0)
    combat_toggle(gs)
    c := &gs.combat
    check(&ok_all, "R: fighting, with the wooden sword from slot 1", c.fighting && c.weapon == .Wooden_Sword &&
        attack_info(c, .Slash_1).damage < ATTACKS[.Slash_1].damage)
    gs.weapon_bar[2] = .Steel_Sword
    weapon_select(gs, 2)
    check(&ok_all, "a sword we haven't made is fists", c.weapon == .None)
    weapon_select(gs, 3)
    check(&ok_all, "an empty slot is fists", c.weapon == .None && attack_info(c, .Slash_1).damage == FIST_ATTACKS[.Slash_1].damage)

    // A punch: the jab goes out with the left fist, the cross with the right.
    cam.pitch = 0
    reach: [2]f32
    punch :: proc(gs: ^Game_State, frames: int, reach: ^[2]f32, click := true) -> Attack_Kind {
        thrown := Attack_Kind.None
        for i in 0 ..< frames {
            combat_pre_update(gs, {attack = click && i == 0}, DT)
            combat_post_update(gs, DT)
            combat_view_update(gs, DT)
            if gs.combat.attack != .None && thrown == .None { thrown = gs.combat.attack }
            for f, k in gs.combat.fists { reach[k] = max(reach[k], f.grip.z) }
        }
        return thrown
    }
    for _ in 0 ..< 30 { combat_view_update(gs, DT) } // at rest
    rest := c.fists
    first := punch(gs, 9, &reach)
    if dir != "" {
        entities_update(gs, 0)
        bench_hud_shot(gs, fmt.tprintf("%s/craft_jab.bmp", dir))
    }
    first_reach := reach
    punch(gs, 20, &reach, click = false)
    reach = {}
    second := punch(gs, 12, &reach)
    check(&ok_all, fmt.tprintf("a click jabs with the left (%v: %.2f out)", first, first_reach[1] - rest[1].grip.z),
        first == .Slash_1 && first_reach[1] > rest[1].grip.z + 0.15 && first_reach[0] < rest[0].grip.z + 0.05)
    check(&ok_all, fmt.tprintf("the next, a cross with the right (%v: %.2f out)", second, reach[0] - rest[0].grip.z),
        second == .Slash_2 && reach[0] > rest[0].grip.z + 0.15)
    punch(gs, 60, &reach, click = false)
    if dir != "" {
        weapon_select(gs, 0)
        for _ in 0 ..< 30 { combat_view_update(gs, DT) }
        entities_update(gs, 0)
        bench_hud_shot(gs, fmt.tprintf("%s/craft_wooden_sword.bmp", dir))
        weapon_select(gs, 3)
    }
    combat_toggle(gs)

    // The spell: iron is too hard for it yet; stone isn't.
    ore := [3]int{x - 2, ground_top(gs, x - 2, z) + 1, z}
    gs.survival = false // put there by the bench, not paid for
    build_set(gs, {ore}, {u8(Block_Type.Iron_Ore)}, undo = false)
    gs.survival = true
    heard(gs)
    d = block_center(ore) - cam.pos
    cam.yaw = math.to_degrees(math.atan2(d.x, d.z))
    cam.pitch = math.to_degrees(math.atan2(d.y, la.length(d.xz)))
    hotbar_select(gs, 5)
    for _ in 0 ..< 150 { step(gs, true, false) }
    step(gs, false, false)
    check(&ok_all, "iron ore is too hard for the spell yet", Block_Type(u8(get_voxel(gs, ore.x, ore.y, ore.z))) == .Iron_Ore && !gs.magic.channeling)
    gs.survival = false
    build_set(gs, {ore}, {u8(Block_Type.Stone)}, undo = false)
    gs.survival = true
    heard(gs)
    for i := 0; i < 150 && get_voxel(gs, ore.x, ore.y, ore.z) != 0; i += 1 { step(gs, true, false) }
    step(gs, false, false)
    check(&ok_all, "stone isn't", get_voxel(gs, ore.x, ore.y, ore.z) == 0)

    if dir != "" {
        for _ in 0 ..< 120 { step(gs, false, false) } // the motes home
        gs.net.items_base[.Sand] = 9
        gs.net.items_base[.Birch_Log] = 3
        client_items_sum(gs)
        gs.mouse_locked = false
        ui_open(gs, .Inventory)
        gs.ui.mouse_pos = {0, 0}
        bench_hud_shot(gs, fmt.tprintf("%s/craft_inventory.bmp", dir))
        world_clear(gs, {at})
        bench_hud_shot(gs, fmt.tprintf("%s/craft_inventory_by_hand.bmp", dir))
        ui_open(gs, .None)
    }
    fmt.println(ok_all ? "bench craft: all ok" : "bench craft: FAILED")
}

// A server of its own in a survival world: what it makes of crafting, and
// of the spell on something too hard for it.
@(private="file")
bench_craft_server :: proc(ok_all: ^bool, at: [3]int) {
    check :: proc(ok_all: ^bool, what: string, ok: bool) {
        fmt.printf("bench craft: %-52s %s\n", what, ok ? "ok" : "FAILED")
        if !ok { ok_all^ = false }
    }
    sim: Sim
    link: Loopback
    srv: Server
    server_init(&srv, &sim, &link)
    srv.survival = true
    sim.players[LOCAL_PLAYER].active = true
    p := at
    for dz in -1 ..= 1 { for dx in -1 ..= 1 {
        k := [2]int{(p.x >> 3) + dx, (p.z >> 3) + dz}
        if k not_in srv.world.columns { srv.world.columns[k] = generate_column_at(k.x, k.y) }
    } }
    for p.y = 200; p.y > WORLD_Y_MIN && !solid_at(&srv.world, p.x, p.y, p.z); p.y -= 1 {}
    sim.players[LOCAL_PLAYER].pos = block_center(p) + {0, 3, 0}
    server_items_restore(&srv, LOCAL_PLAYER, {}, false)
    items := &srv.items[LOCAL_PLAYER]
    weapons := &srv.weapons[LOCAL_PLAYER]
    nothing := true
    for n in items { if n > 0 { nothing = false } }
    check(ok_all, "server: a new player there has nothing", nothing)

    // Something from the local client; what the server told it back.
    send :: proc(srv: ^Server, kind: Msg_Kind, body: $T) -> (heard: Msg_Items) {
        o: Outbox
        outbox_put(&o, kind, body)
        clear(&srv.local_out.reliable)
        srv.link.to_server = o.reliable
        server_receive(srv)
        o.reliable = srv.link.to_server
        delete(o.reliable)
        srv.link.to_server = {}
        r := Msg_Reader{data = srv.local_out.reliable[:]}
        for kind in msg_next(&r) {
            #partial switch kind {
            case .Items: heard, _ = msg_get(&r, Msg_Items)
            case:        r.at = len(r.data)
            }
        }
        return
    }
    recipe :: proc(b: Block_Type, w: Weapon) -> u16 {
        for r, i in RECIPES { if r.block == b && r.weapon == w { return u16(i) } }
        return 0xffff
    }
    items[.Log], items[.Birch_Log] = 7, 5
    h := send(&srv, .Craft, Msg_Craft{seq = 1, recipe = recipe(.Workbench, .None)})
    check(ok_all, fmt.tprintf("server: a workbench by hand, of any wood (%d oak, %d birch left)", items[.Log], items[.Birch_Log]),
        items[.Workbench] == 1 && items[.Log] == 0 && items[.Birch_Log] == 2 && h.seq == 1 && h.items[.Workbench] == 1)
    h = send(&srv, .Craft, Msg_Craft{seq = 2, recipe = recipe(.Air, .Wooden_Sword)})
    check(ok_all, "server: no sword with no workbench near", weapons[.Wooden_Sword] == 0 && h.seq == 2)
    server_write(&srv, p + {2, 1, 0}, u8(Block_Type.Workbench))
    items[.Log] = 5
    h = send(&srv, .Craft, Msg_Craft{seq = 3, recipe = recipe(.Air, .Wooden_Sword)})
    check(ok_all, "server: nor with too little wood", weapons[.Wooden_Sword] == 0 && items[.Log] == 5 && h.seq == 3)
    items[.Log] = 6
    h = send(&srv, .Craft, Msg_Craft{seq = 4, recipe = recipe(.Air, .Wooden_Sword)})
    check(ok_all, "server: near one, with enough, a wooden sword", weapons[.Wooden_Sword] == 1 && items[.Log] + items[.Birch_Log] == 0 && h.weapons[.Wooden_Sword] == 1)
    sim.players[LOCAL_PLAYER].pos = block_center(p) + {30, 3, 0}
    items[.Log] = 8
    send(&srv, .Craft, Msg_Craft{seq = 5, recipe = recipe(.Air, .Wooden_Sword)})
    check(ok_all, "server: walked off from it, no more", weapons[.Wooden_Sword] == 1 && items[.Log] == 8)
    sim.players[LOCAL_PLAYER].pos = block_center(p) + {0, 3, 0}
    h = send(&srv, .Craft, Msg_Craft{seq = 6, recipe = 999})
    check(ok_all, "server: a recipe that isn't, nothing", h.seq == 6 && items[.Log] == 8)

    // The spell on iron: turned down; on stone: taken.
    q := p + {-2, 1, 0}
    server_write(&srv, q, u8(Block_Type.Iron_Ore))
    edit := Msg_Voxels{seq = 7, count = 1}
    edit.items[0] = {pos = {i32(q.x), i32(q.y), i32(q.z)}, block = 0}
    send(&srv, .Voxels, edit)
    check(ok_all, "server: iron is too hard for the spell yet", Block_Type(u8(get_voxel(&srv.world, q.x, q.y, q.z))) == .Iron_Ore && items[.Iron_Ore] == 0)
    server_write(&srv, q, u8(Block_Type.Stone))
    edit.seq = 8
    send(&srv, .Voxels, edit)
    check(ok_all, "server: stone isn't", get_voxel(&srv.world, q.x, q.y, q.z) == 0 && items[.Stone] == 1)
}
