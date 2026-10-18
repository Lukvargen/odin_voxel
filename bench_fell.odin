package main

import "core:fmt"
import "core:math"
import "core:os"
import la "core:math/linalg"
import "core:time"
import SDL "vendor:sdl3"

// `bench fell [dir]`: survival magic out on the plains. Unweaves a block of
// ground (holding left, as a player would), conjures it back, then fells the
// nearest tree: channels its trunk, watches it fall and burst, and checks
// every voxel it was came home as an item. With a dir, shots along the way
// (from where you stand, and one from the side as it falls).
bench_fell: bool
bench_fell_forest: bool // `forest`: a big tree in a forest instead (crowded, slower to find)

bench_fell_run :: proc(gs: ^Game_State) {
    ui_init(gs)
    defer ui_shutdown(gs)
    dir := bench_shot_dir
    gs.entities_enabled = false
    day_set_hour(gs, 14, settle = true)
    x, z, found := bench_find_biome(bench_fell_forest ? .Forest : .Plains) // plains: trees standing alone, room to fall and to see it
    if !found { x, z = int(gs.camera.pos.x), int(gs.camera.pos.z) }
    bench_teleport(gs, {f32(x) + 0.5, f32(surface_height_at(x, z)) + 30, f32(z) + 0.5})

    // The nearest trunk: a log on the ground with logs above it.
    trunk: [3]int
    have := false
    search: for r in 4 ..< 80 {
        for dz in -r ..= r { for dx in -r ..= r {
            if max(abs(dx), abs(dz)) != r { continue }
            g := surface_height_at(x + dx, z + dz)
            for y in g - 3 ..= g + 3 {
                p := [3]int{x + dx, y, z + dz}
                if !block_is_log(u8(get_voxel(gs, p.x, p.y, p.z))) || block_is_log(u8(get_voxel(gs, p.x, p.y - 1, p.z))) { continue }
                if !block_is_log(u8(get_voxel(gs, p.x, p.y + 5, p.z))) { continue }
                if felling_trunk_logs(gs, p) == 0 { continue }
                trunk, have = p, true
                break search
            }
        } }
    }
    if !have {
        fmt.println("bench fell: no tree found near", x, z)
        return
    }

    // Stand a few steps off, looking at the trunk a little above the cut.
    gs.survival = true
    gs.mouse_locked = true
    clear(&gs.net.item_guesses) // carrying nothing: what's counted is the server's word and our guesses since (items.odin)
    gs.net.items_base = {}
    client_items_sum(gs)
    gs.hotbar = {}
    hotbar_select(gs, 0)
    cam := &gs.camera
    stand_x, stand_z := trunk.x - 9, trunk.z - 3
    ground := ground_top(gs, stand_x, stand_z)
    cam.fly_mode = true // stays put while the bench runs
    cam.pos = {f32(stand_x) + 0.5, f32(ground) + 1 + PLAYER_EYE_HEIGHT, f32(stand_z) + 0.5}
    look_at :: proc(cam: ^Camera, p: [3]f32) {
        d := p - cam.pos
        cam.yaw = math.to_degrees(math.atan2(d.x, d.z))
        cam.pitch = math.to_degrees(math.atan2(d.y, la.length(d.xz)))
    }
    t0 := time.tick_now()
    n_logs := felling_trunk_logs(gs, trunk)
    fmt.printf("bench fell: tree at %v (%d logs, found in %.1f ms), standing at %v\n", trunk, n_logs, time.duration_milliseconds(time.tick_since(t0)), cam.pos)

    DT :: f32(1.0 / 60)
    step :: proc(gs: ^Game_State, left, right: bool) {
        gs.left_pressed  = left && !gs.left_held
        gs.right_pressed = right && !gs.right_held
        gs.left_held, gs.right_held = left, right
        build_update(gs, DT)
        magic_update(gs, DT)
        felling_update(gs, DT)
        fx_update(gs, DT)
        flush_gpu_uploads(gs)
    }
    shot :: proc(gs: ^Game_State, dir, name: string) {
        if dir == "" { return }
        entities_update(gs, 0)
        bench_hud_shot(gs, fmt.tprintf("%s/fell_%s.bmp", dir, name))
    }
    ok_all := true
    check :: proc(ok_all: ^bool, what: string, ok: bool) {
        fmt.printf("bench fell: %-46s %s\n", what, ok ? "ok" : "FAILED")
        if !ok { ok_all^ = false }
    }

    // A block of ground first: hold left on it, then put it back.
    // The ground three steps ahead: whatever the crosshair finds there.
    aim_at := [3]int{stand_x + 3, ground_top(gs, stand_x + 3, stand_z), stand_z}
    world_clear(gs, {aim_at + {0, 1, 0}}) // a tuft of grass would catch the beam
    look_at(cam, block_center(aim_at))
    dirt, _, aimed := raycast_voxel(gs, camera_aim_eye(cam^), camera_forward(cam^), MAGIC_REACH, plants = true)
    if !aimed { dirt = aim_at }
    around :: proc(gs: ^Game_State, c: [3]int) -> (h: u64) {
        for dz in -3 ..= 3 { for dy in -3 ..= 3 { for dx in -3 ..= 3 { h = h * 31 + u64(get_voxel(gs, c.x + dx, c.y + dy, c.z + dz)) } } }
        return
    }
    was := Block_Type(u8(get_voxel(gs, dirt.x, dirt.y, dirt.z)))
    for i in 0 ..< int(unweave_time(was) / DT * 0.6) {
        step(gs, true, false)
        if i == 10 { shot(gs, dir, "unweave") }
    }
    check(&ok_all, "a block holds while it's being unwoven", Block_Type(u8(get_voxel(gs, dirt.x, dirt.y, dirt.z))) == was)
    for i := 0; i < 60 && get_voxel(gs, dirt.x, dirt.y, dirt.z) != 0; i += 1 { step(gs, true, false) }
    check(&ok_all, "and comes apart", get_voxel(gs, dirt.x, dirt.y, dirt.z) == 0)
    step(gs, false, false)
    for _ in 0 ..< 90 { step(gs, false, false) }
    check(&ok_all, fmt.tprintf("its mote brought it home (%d %v)", gs.items[was], was), gs.items[was] == 1 && gs.hotbar[0] == was)
    // The same aim: into the hole it left, or the ground behind it.
    h, nrm, _ := raycast_voxel(gs, camera_aim_eye(cam^), camera_forward(cam^), MAGIC_REACH, plants = true)
    put := h + nrm
    step(gs, false, true)
    shot(gs, dir, "conjure")
    step(gs, false, false)
    check(&ok_all, "right conjures it back from what you carry", Block_Type(u8(get_voxel(gs, put.x, put.y, put.z))) == was && gs.items[was] == 0)
    dirt = put
    restored := around(gs, dirt)
    step(gs, false, true)
    step(gs, false, false)
    check(&ok_all, "and with none left, nothing", around(gs, dirt) == restored)

    // Mana: spent by all that; with none, the spell holds; it comes back.
    check(&ok_all, fmt.tprintf("casting spends mana (%.1f left)", magic_mana(&gs.magic)), magic_mana(&gs.magic) < MANA_MAX)
    for _ in 0 ..< 200 { step(gs, false, false) }
    check(&ok_all, "...and it comes back", magic_mana(&gs.magic) == MANA_MAX)
    gs.magic.mana_spent = MANA_MAX
    look_at(cam, block_center(dirt))
    aim2, _, _ := raycast_voxel(gs, camera_aim_eye(cam^), camera_forward(cam^), MAGIC_REACH, plants = true)
    held := u8(get_voxel(gs, aim2.x, aim2.y, aim2.z))
    for _ in 0 ..< 60 { step(gs, true, false) }
    check(&ok_all, "with no mana the spell holds", u8(get_voxel(gs, aim2.x, aim2.y, aim2.z)) == held && gs.magic.starved)
    for i := 0; i < 400 && get_voxel(gs, aim2.x, aim2.y, aim2.z) != 0; i += 1 {
        step(gs, i % 120 > 80, false) // let go now and then: it comes back while resting
    }
    check(&ok_all, "...and goes on once it's back", get_voxel(gs, aim2.x, aim2.y, aim2.z) == 0)
    for _ in 0 ..< 200 { step(gs, false, false) }

    // The tree.
    target := block_center(trunk + {0, 1, 0})
    look_at(cam, target)
    count_tree :: proc(gs: ^Game_State, c: [3]int) -> (n: int) {
        for dz in -56 ..= 56 { for dx in -56 ..= 56 { for dy in 0 ..< 90 {
            v := u8(get_voxel(gs, c.x + dx, c.y + dy, c.z + dz))
            if block_is_log(v) || block_is_leaves(v) { n += 1 }
        }}}
        return
    }
    before := count_tree(gs, trunk)

    // Felled by someone else first (Msg_Fell from the server): it falls here
    // too, its voxels left to their edits, and its motes fly to them.
    {
        other := &gs.net.others[1]
        other.active, other.pos = true, block_center(trunk) + {-14, 4, 6}
        carried := gs.items
        felling_heard(gs, Msg_Fell{slot = 1, cut = {i32(trunk.x), i32(trunk.y + 1), i32(trunk.z)}, dir = {1, 0, 0}})
        theirs := &gs.felling.trees[0]
        check(&ok_all, "another's tree falls here too, theirs", theirs.active && theirs.owner == 2)
        check(&ok_all, "...leaving the voxels to their edits", count_tree(gs, trunk) == before)
        for i := 0; i < 900 && (theirs.active || motes_out(gs)); i += 1 { step(gs, false, false) }
        check(&ok_all, "...and its motes went to them, not to us", !theirs.active && !motes_out(gs) && gs.items == carried)
        other.active = false
    }
    motes_out :: proc(gs: ^Game_State) -> bool {
        for mo in gs.magic.motes { if mo.size > 0 { return true } }
        return false
    }

    clear(&gs.net.item_guesses) // carrying nothing: what's counted is the server's word and our guesses since (items.odin)
    gs.net.items_base = {}
    client_items_sum(gs)
    t := 0
    for !gs.felling.trees[0].active && t < 400 {
        t1 := time.tick_now()
        step(gs, true, false)
        if gs.felling.trees[0].active { fmt.printf("bench fell: the frame it came down took %.1f ms\n", time.duration_milliseconds(time.tick_since(t1))) }
        if t == 40 { shot(gs, dir, "channel") }
        t += 1
    }
    fmt.printf("bench fell: channelled %.2f s\n", f32(t) * DT)
    tree := &gs.felling.trees[0]
    check(&ok_all, "the tree comes down", tree.active)
    if !tree.active { return }
    drops := 0
    for n in tree.drops { drops += int(n) }
    after := count_tree(gs, trunk)
    fmt.printf("bench fell: %d voxels taken (%d logs and leaves before, %d left about: the stump and other trees), giving %d (%d saplings)\n", tree.taken, before, after, drops, tree.drops[.Sapling])
    check(&ok_all, "its voxels left the world", before - after == tree.taken)
    check(&ok_all, "fewer leaves come back than it had, and saplings", drops < tree.taken && tree.drops[.Sapling] > 0)
    step(gs, false, false)
    shot(gs, dir, "fall_0")
    for i in 0 ..< 600 {
        if !tree.active { break }
        step(gs, false, false)
        if i == 40 { shot(gs, dir, "fall_1") }
        if i == 25 {
            // From the side.
            keep, yaw, pitch := cam.pos, cam.yaw, cam.pitch
            side := la.normalize(la.cross(tree.axis, [3]f32{0, 1, 0}))
            cam.pos = tree.pivot - tree.axis * 45 + {0, 22, 0} + side * 10
            look_at(cam, tree.pivot + side * 10 + {0, 8, 0})
            shot(gs, dir, "fall_side")
            cam.pos, cam.yaw, cam.pitch = keep, yaw, pitch
        }
        if tree.down >= 0 && tree.down < DT * 0.5 {
            fmt.printf("bench fell: hit the ground after %.2f s at %.0f degrees\n", f32(i) * DT, math.to_degrees(tree.angle))
            shot(gs, dir, "landed")
        }
    }
    check(&ok_all, "it lands and bursts", !tree.active)
    for i in 0 ..< 600 {
        step(gs, false, false)
        if i == 20 { shot(gs, dir, "motes") }
    }
    got := 0
    for n in gs.items { got += int(n) }
    left := 0
    for mo in gs.magic.motes { if mo.size > 0 { left += int(mo.count) } }
    fmt.printf("bench fell: carried %d (motes still out with %d)\n", got, left)
    check(&ok_all, "everything it was came home", got == drops)
    shot(gs, dir, "after")

    // One of its saplings, planted where it stood.
    for b, i in gs.hotbar { if b == .Sapling { hotbar_select(gs, i) } }
    if gs.selected_block == .Sapling {
        stump := trunk + {2, 0, -2}
        ground := ground_top(gs, stump.x, stump.z)
        world_clear(gs, {{stump.x, ground + 1, stump.z}})
        look_at(cam, block_center({stump.x, ground, stump.z}) + {0, 0.49, 0})
        step(gs, false, true)
        step(gs, false, false)
        check(&ok_all, "a sapling from it goes into the grass", Block_Type(u8(get_voxel(gs, stump.x, ground + 1, stump.z))) == .Sapling)
        for _ in 0 ..< 60 { step(gs, false, false) } // the sparks die down
        cam.pos = block_center({stump.x, ground, stump.z}) + {-2.2, 2.2, -1.2}
        look_at(cam, block_center({stump.x, ground + 1, stump.z}))
        shot(gs, dir, "sapling")
    }
    // Creative's Magic tool, a bigger spell: a ball of ground unwoven (and
    // undone), a disc of blocks conjured.
    {
        gs.survival = false
        gs.build.tool, gs.brush_radius = .Magic, 2
        for _ in 0 ..< 120 { step(gs, false, false) }
        spot := [3]int{trunk.x - 4, 0, trunk.z - 8}
        spot.y = ground_top(gs, spot.x, spot.z)
        cam.pos = block_center(spot) + {-7, 6, -2}
        look_at(cam, block_center(spot))
        aim, _, _ := raycast_voxel(gs, camera_aim_eye(cam^), camera_forward(cam^), MAGIC_REACH, plants = true)
        ball := len(spell_take_targets(gs, aim, 2))
        solid_near :: proc(gs: ^Game_State, c: [3]int) -> (n: int) {
            for dz in -4 ..= 4 { for dy in -4 ..= 4 { for dx in -4 ..= 4 {
                v := u8(get_voxel(gs, c.x + dx, c.y + dy, c.z + dz))
                if v != 0 && !block_is_watery(v) { n += 1 }
            } } }
            return
        }
        before_ball := solid_near(gs, aim)
        t0 := 0
        for i := 0; i < 600 && solid_near(gs, aim) == before_ball; i += 1 {
            step(gs, true, false)
            if i == 30 { shot(gs, dir, "spell_ball") }
            t0 = i
        }
        step(gs, false, false)
        gone := before_ball - solid_near(gs, aim)
        fmt.printf("bench fell: a radius 2 spell took %d blocks (of %d in its ball) in %.2f s\n", gone, ball, f32(t0) * DT)
        check(&ok_all, "creative: a bigger spell takes the ball", gone >= ball && ball > 10)
        build_key(gs, SDL.K_Z, {.Ctrl})
        check(&ok_all, "creative: ...and Ctrl+Z puts it back", solid_near(gs, aim) == before_ball)
        h, nrm, _ := raycast_voxel(gs, camera_aim_eye(cam^), camera_forward(cam^), MAGIC_REACH, plants = true)
        before_disc := solid_near(gs, h + nrm)
        hotbar_select(gs, 0)
        if gs.selected_block == .Air || gs.selected_block == .Sapling { gs.hotbar[0] = .Stone; hotbar_select(gs, 0) }
        step(gs, false, true)
        step(gs, false, false)
        placed := solid_near(gs, h + nrm) - before_disc
        check(&ok_all, fmt.tprintf("creative: right conjures a disc (%d blocks)", placed), placed >= 8)
        for _ in 0 ..< 10 { step(gs, false, false) }
        shot(gs, dir, "spell_disc")
        gs.build.tool, gs.brush_radius = .Block, 0
        gs.survival = true
    }

    bench_fell_server(&ok_all, trunk)

    // A save from before saplings: its doors come back as doors.
    {
        col := generate_column_at(0, 0)
        defer column_free(col)
        c := &col.chunks[chunk_y_index(2)]
        old_door := u8(Block_Type.Door) - 1 // where doors started then
        chunk_set_voxel(c, 5, old_door)
        out := make([dynamic]u8, context.temp_allocator)
        append(&out, SAVE_MAGIC_V2)
        column_encode(col, &out)
        keep := save_dir
        save_dir = bench_shot_dir != "" ? bench_shot_dir : "."
        path := fmt.tprintf("%s/c.%d.%d.bin", save_dir, 999999, 999999)
        _ = os.write_entire_file(path, out[:])
        back := load_column({999999, 999999})
        _ = os.remove(path)
        save_dir = keep
        ok := back != nil && chunk_voxel(&back.chunks[chunk_y_index(2)], 5) == u8(Block_Type.Door) && back.modified
        check(&ok_all, "an old save's door loads as a door, to be saved anew", ok)
        if back != nil { column_free(back) }
    }
    fmt.println(ok_all ? "bench fell: all ok" : "bench fell: FAILED")
}

// A server of its own in a survival world: it counts what a player's edits
// take and turns down a block put down that the player doesn't have.
@(private="file")
bench_fell_server :: proc(ok_all: ^bool, at: [3]int) {
    check :: proc(ok_all: ^bool, what: string, ok: bool) {
        fmt.printf("bench fell: %-46s %s\n", what, ok ? "ok" : "FAILED")
        if !ok { ok_all^ = false }
    }
    sim: Sim
    link: Loopback
    srv: Server
    server_init(&srv, &sim, &link)
    srv.survival = true
    sim.players[LOCAL_PLAYER].active = true
    p := [3]int{at.x + 30, 0, at.z}
    key := [2]int{p.x >> 3, p.z >> 3}
    srv.world.columns[key] = generate_column_at(key.x, key.y) // loaded, as around a player
    for p.y = 200; p.y > WORLD_Y_MIN && !solid_at(&srv.world, p.x, p.y, p.z); p.y -= 1 {}
    top := u8(get_voxel(&srv.world, p.x, p.y, p.z))
    sim.players[LOCAL_PLAYER].pos = block_center(p) + {3, 4, 0} // standing by it
    // One voxel edit from the local player; what the server told it back.
    send :: proc(srv: ^Server, seq: u32, p: [3]int, block: u8) -> (heard: Msg_Items, sent_back: bool) {
        m := Msg_Voxels{seq = seq, count = 1}
        m.items[0] = {pos = {i32(p.x), i32(p.y), i32(p.z)}, block = block}
        o: Outbox
        outbox_put(&o, .Voxels, m)
        clear(&srv.local_out.reliable)
        srv.link.to_server = o.reliable
        server_receive(srv) // takes the local client's bytes, then tells it the count
        o.reliable = srv.link.to_server
        delete(o.reliable)
        srv.link.to_server = {}
        r := Msg_Reader{data = srv.local_out.reliable[:]}
        for kind in msg_next(&r) {
            #partial switch kind {
            case .Items:  heard, _ = msg_get(&r, Msg_Items)
            case .Voxels: _, _ = msg_get(&r, Msg_Voxels); sent_back = true
            case:         r.at = len(r.data)
            }
        }
        return
    }
    h1, _ := send(&srv, 1, p, 0)
    check(ok_all, fmt.tprintf("server: taking a block counts it (%v)", Block_Type(top)), get_voxel(&srv.world, p.x, p.y, p.z) == 0 && srv.items[LOCAL_PLAYER][voxel_item(top)] == 1)
    check(ok_all, "server: and says so, answering that edit", h1.seq == 1 && h1.items[voxel_item(top)] == 1)
    stone := voxel_item(top) == .Stone ? u8(Block_Type.Sand) : u8(Block_Type.Stone)
    h2, back := send(&srv, 2, p, stone)
    check(ok_all, "server: a block you don't have is turned down", get_voxel(&srv.world, p.x, p.y, p.z) == 0 && back && h2.seq == 2)
    _, back3 := send(&srv, 3, p, top)
    check(ok_all, "server: one you have goes in, and is spent", u8(get_voxel(&srv.world, p.x, p.y, p.z)) == top && !back3 && srv.items[LOCAL_PLAYER][voxel_item(top)] == 0)
    deep := p - {0, 30, 0}
    deep_was := get_voxel(&srv.world, deep.x, deep.y, deep.z)
    _, back4 := send(&srv, 4, deep, 0)
    check(ok_all, "server: out of reach, nothing goes", get_voxel(&srv.world, deep.x, deep.y, deep.z) == deep_was && back4)

    // A tree: its top log, from far off, only once it's being felled.
    tkey := [2]int{at.x >> 3, at.z >> 3}
    if tkey not_in srv.world.columns { srv.world.columns[tkey] = generate_column_at(tkey.x, tkey.y) }
    high := at
    for block_is_log(u8(get_voxel(&srv.world, high.x, high.y + 1, high.z))) { high.y += 1 }
    sim.players[LOCAL_PLAYER].pos = block_center(at) + {-40, 4, 0}
    _, back5 := send(&srv, 5, high, 0)
    check(ok_all, "server: a far tree's log can't be taken", block_is_log(u8(get_voxel(&srv.world, high.x, high.y, high.z))) && back5)
    cut := Msg_Fell{cut = {i32(at.x), i32(at.y), i32(at.z)}, dir = {1, 0, 0}}
    check(ok_all, "server: nor felled from far off", !server_fell(&srv, LOCAL_PLAYER, cut))
    sim.players[LOCAL_PLAYER].pos = block_center(at) + {-8, 4, 0}
    check(ok_all, "server: felled from near, it may come down", server_fell(&srv, LOCAL_PLAYER, cut))
    sim.players[LOCAL_PLAYER].pos = block_center(at) + {-40, 4, 0} // walked off: its voxels still go
    _, back6 := send(&srv, 6, high, 0)
    check(ok_all, "server: ...all of it, out of reach as it is", get_voxel(&srv.world, high.x, high.y, high.z) == 0 && !back6)
    _, back7 := send(&srv, 7, deep, 0)
    check(ok_all, "server: but not the ground under it", get_voxel(&srv.world, deep.x, deep.y, deep.z) == deep_was && back7)

    // A sapling planted in grass grows into a tree, and the player's told.
    g := at + {12, 0, 9}
    for dz in -4 ..= 4 { for dx in -4 ..= 4 {
        k := [2]int{(g.x >> 3) + dx, (g.z >> 3) + dz}
        if k not_in srv.world.columns { srv.world.columns[k] = generate_column_at(k.x, k.y) }
    } }
    for g.y = 200; g.y > WORLD_Y_MIN && !solid_at(&srv.world, g.x, g.y, g.z); g.y -= 1 {}
    server_write(&srv, g, u8(Block_Type.Grass))
    for y in g.y + 1 ..< g.y + 40 { server_write(&srv, {g.x, y, g.z}, 0) } // room to grow
    srv.items[LOCAL_PLAYER][.Sapling] = 1
    sim.players[LOCAL_PLAYER].pos = block_center(g) + {-3, 4, 0}
    _, back8 := send(&srv, 8, g + {0, 1, 0}, u8(Block_Type.Sapling))
    check(ok_all, "server: a sapling planted is kept growing", !back8 && len(srv.saplings) == 1 && srv.items[LOCAL_PLAYER][.Sapling] == 0)
    fmt.printf("bench fell: it'll grow into a %v\n", sapling_kind(g + {0, 1, 0}))
    clear(&srv.local_out.reliable)
    srv.saplings[0].left = 0
    server_saplings_update(&srv, 0.1)
    told := 0
    {
        r := Msg_Reader{data = srv.local_out.reliable[:]}
        for kind in msg_next(&r) {
            if kind != .Voxels { r.at = len(r.data); break }
            m, _ := msg_get(&r, Msg_Voxels)
            told += int(m.count)
        }
    }
    trunk_up := 0
    for y in g.y + 1 ..< g.y + 6 { if block_is_log(u8(get_voxel(&srv.world, g.x, y, g.z))) || block_is_log(u8(get_voxel(&srv.world, g.x + 1, y, g.z))) { trunk_up += 1 } }
    check(ok_all, fmt.tprintf("server: ...into a tree (%d blocks, all sent)", told), len(srv.saplings) == 0 && trunk_up >= 3 && told > 20)
    // Mana: the server draws it too, and won't let a spell by without it.
    sim.players[LOCAL_PLAYER].pos = block_center(p) + {3, 4, 0}
    srv.mana_spent[LOCAL_PLAYER], srv.mana_at[LOCAL_PLAYER] = MANA_MAX, time.tick_now()
    server_write(&srv, p, u8(Block_Type.Stone)) // dearer than the slack it allows
    was := u8(get_voxel(&srv.world, p.x, p.y, p.z))
    _, back9 := send(&srv, 9, p, 0)
    check(ok_all, "server: with no mana, nothing's unwoven", u8(get_voxel(&srv.world, p.x, p.y, p.z)) == was && back9)
    sim.players[LOCAL_PLAYER].pos = block_center(at) + {-8, 4, 0}
    check(ok_all, "server: nor felled", !server_fell(&srv, LOCAL_PLAYER, cut))
    sim.players[LOCAL_PLAYER].pos = block_center(p) + {3, 4, 0}
    srv.mana_at[LOCAL_PLAYER] = time.tick_add(time.tick_now(), -10 * time.Second) // a rest
    _, back10 := send(&srv, 10, p, 0)
    check(ok_all, fmt.tprintf("server: rested, it is (mana %.0f after)", server_mana(&srv, LOCAL_PLAYER)), get_voxel(&srv.world, p.x, p.y, p.z) == 0 && !back10)
    delete(srv.saplings)
    delete(srv.local_out.reliable)
}

// The ground's top voxel at (x, z), under any canopy.
@(private="file")
ground_top :: proc(gs: ^Game_State, x, z: int) -> int {
    for y := surface_height_at(x, z) + 6; y > WORLD_Y_MIN; y -= 1 {
        v := u8(get_voxel(gs, x, y, z))
        if block_solid(v) && !block_is_leaves(v) && !block_is_log(v) { return y }
    }
    return 0
}
