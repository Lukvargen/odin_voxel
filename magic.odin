package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import la "core:math/linalg"
import "core:slice"

// Survival building is magic (gs.survival; a creative world keeps the build
// tools). Hold left on a block and a beam of sparks reaches out from the
// wand in your hand: the block unravels, in a time that goes by how hard it
// is (unweave_time), then comes apart into motes that fly to you and into
// what you carry (gs.items). Right conjures the block in hand out of what
// you carry. One block at a time, within MAGIC_REACH. A tree's trunk brings
// the whole tree down (felling.odin), slowly, and only a tree the spell has
// the mana for. The hardest blocks (block_tier) are beyond it at first.

MAGIC_REACH :: f32(12) // voxels: 8 m

// Spells come in sizes: a radius about the block aimed at (0: just it). B or
// Ctrl+wheel sets it (gs.brush_radius) in creative's Magic tool; survival
// allows up to survival_spell_size, which upgrades are to raise.
MAGIC_MAX_SIZE      :: 3
survival_spell_size := 0

magic_spell_size :: proc(gs: ^Game_State) -> int {
    return min(gs.brush_radius, gs.survival ? survival_spell_size : MAGIC_MAX_SIZE)
}

// Whether the spell is in your hands: survival's only way to build, or
// creative's Magic tool.
magic_active :: proc(gs: ^Game_State) -> bool { return gs.survival || gs.build.tool == .Magic }
MAX_MOTES   :: 192
MAX_SPARKS  :: 96
MAGIC_TINT  :: [3]f32{0.10, 0.28, 0.75} // the spell's sparks (they glow: ×4 in the shader)

// Mana: unweaving draws it all the while (harder blocks take longer, so
// cost more; a tree, by its size), conjuring takes a little; it comes back
// once you stop. With too little, the spell holds where it is.
MANA_MAX         :: f32(100)
MANA_REGEN       :: f32(14)  // per second, after a rest
MANA_REST        :: f32(0.8) // seconds after casting before it comes back
UNWEAVE_MANA     :: f32(10)  // per second of unweaving
CONJURE_MANA     :: f32(2)

// What felling a tree of n logs takes, all told: a sapling's worth of tree
// is cheap, a big one more than a fresh spell holds (MANA_MAX), so it has to
// wait for a stronger one (or be cut higher up, where less comes down).
fell_mana :: proc(n: int) -> f32 { return 12 + f32(n) * 2.2 }

// How hard a block is for the spell: 1 soft (earth, plants, wood), 2 stone,
// 3 what a fresh spell can't undo (metal ores, crystal). Survival unweaves
// up to survival_magic_power; upgrades are to raise it.
survival_magic_power := 2

block_tier :: proc(b: Block_Type) -> int {
    #partial switch b {
    case .Iron_Ore, .Gold_Ore, .Crystal: return 3
    case .Stone, .Weathered_Stone, .Sandstone, .Terracotta, .Dripstone, .Coral, .Stone_Bricks, .Coal_Ore, .Ice: return 2
    }
    return 1
}

// Whether the spell can take a block (creative's takes anything).
spell_can_take :: proc(survival: bool, b: Block_Type) -> bool { return !survival || block_tier(b) <= survival_magic_power }

// A piece of something unwoven, on its way to you.
Mote :: struct {
    pos, vel: [3]f32,
    age:      f32, // seconds out; below 0 still waiting to go (a tree's go in a stream)
    block:    Block_Type,
    count:    u32, // blocks it brings (0: only sparkle)
    tint:     [3]f32,
    size:     f32, // 0: a free slot
    home:     u8,  // who it flies to: 0 you, else that player's slot + 1 (their tree: no count)
    tex:      [3]f32, // the world voxel it came from: its texture (mote_add); sent out, the middle of where it goes
    // Sent out (magic_send): flies from your hands to fill Magic.fill[first:][:n].
    out:      bool,
    first, n: i32,
}

// A cell a sent mote fills when it lands.
Fill :: struct {
    pos:   [3]int,
    block: Block_Type,
}
MAX_FILL   :: 16 * 16 * 16 // cells in flight at once (a creative box, at most)
SEND_MOTES :: 96           // motes a box is sent as, at most: past that each fills a few cells

// A spark of the spell: flies, slows, goes out.
Spark :: struct {
    pos, vel:  [3]f32,
    life, max: f32,
    tint:      [3]f32,
}

Magic :: struct {
    // Unweaving: the block under the beam and how far along it is.
    channeling: bool,
    target:     [3]int,
    block:      Block_Type,
    progress:   f32, // seconds on this block
    need:       f32, // seconds it takes
    size:       int, // how big it sounds and shows (the brush's radius; a box, by its size)
    region:     Edit_Region, // the blocks it takes: a ball about the target, or a dragged box
    center:     [3]f32,      // their middle, where the beam goes
    ring:       f32,         // the beam's ring round them
    casting:    bool,        // a dragged box: the spell goes on without the button held
    count:      int, // blocks it takes
    mana_total: f32, // mana it takes, all told
    tree_logs:  int, // > 0: a tree's trunk; this many logs come down with it
    whole:      bool, // it must be paid in one breath (a tree, a block too hard): run dry, it snaps (magic_snap)
    refused:    Maybe([3]int), // it snapped on this block: not again until the button's let go or the aim moves
    chip_timer: f32,
    stage:      int, // cracks: 0 .. CRACK_STAGES as it comes undone (crack_stage)
    hum_timer:  f32,
    // The hand: raised while casting, lowered after.
    raise:      f32, // 0 down .. 1 up
    conjure:    f32, // > 0: a block was just conjured; the beam shows this long
    conjure_at: [3]f32,
    aim:        [3]f32, // what the hands were last raised to (Body_Act: our body, as the others see it)
    t:          f32,
    motes:      [MAX_MOTES]Mote,
    next_mote:  int,
    sparks:     [MAX_SPARKS]Spark,
    next_spark: int,
    pickup_gap: f32, // since a mote last arrived: a quick run of them rises in pitch
    pickup_run: int,
    // Blocks sent out to a box (magic_send): the cells, and the motes still flying.
    fill:       [MAX_FILL]Fill,
    fill_len:   int,
    fill_out:   int, // motes in flight
    fill_done:  int, // cells of this send landed (the knocks rise as it fills)
    fill_gap:   f32, // since the last knock
    // Mana (zero: full).
    mana_spent: f32,
    mana_rest:  f32, // since mana was last drawn
    starved:    bool, // the spell is waiting for mana
    starved_t:  f32,  // > 0: the bar flashes
    empty_t:    f32,  // > 0: the block in hand ran out; its count on the hotbar blinks
}

magic_mana :: proc(m: ^Magic) -> f32 { return MANA_MAX - m.mana_spent }

// Draws `amount` of mana if there's that much.
@(private="file")
mana_draw :: proc(m: ^Magic, amount: f32) -> bool {
    if magic_mana(m) < amount {
        if !m.starved { m.starved_t = 0.6 }
        m.starved = true
        return false
    }
    m.mana_spent += amount
    m.mana_rest = 0
    m.starved = false
    return true
}

// Seconds of channelling to unweave a block.
unweave_time :: proc(b: Block_Type) -> f32 {
    v := u8(b)
    switch {
    case block_is_land_plant(v) || block_is_water_plant(v): return 0.08
    case block_is_door(v):   return 0.5
    case block_is_leaves(v): return 0.15
    case block_is_log(v):    return 0.55
    }
    #partial switch b {
    case .Torch:                        return 0.08
    case .Workbench:                    return 0.5
    case .Snow:                         return 0.25
    case .Glow_Moss, .Moss:             return 0.3
    case .Grass, .Dry_Grass, .Dirt, .Sand, .Red_Sand, .Gravel: return 0.35
    case .Cactus:                       return 0.4
    case .Ice:                          return 0.5
    case .Stone, .Weathered_Stone, .Sandstone, .Terracotta, .Dripstone, .Coral: return 0.8
    case .Stone_Bricks, .Coal_Ore:      return 1.0
    case .Iron_Ore:                     return 1.2
    case .Gold_Ore:                     return 1.3
    case .Crystal:                      return 1.4
    }
    return 0.6
}

// A block's colour as a linear tint (from the icons' sRGB).
block_color :: proc(b: Block_Type) -> [3]f32 {
    top, side := icon_colors(b)
    c := block_is_log(u8(b)) ? side : top
    return {math.pow(c.x, 2.2), math.pow(c.y, 2.2), math.pow(c.z, 2.2)}
}

block_center :: proc(p: [3]int) -> [3]f32 { return la.array_cast(p, f32) + 0.5 }

// A mote's glow: the block's colour, brightened toward a common level so
// dark blocks still shine, with a touch of the spell.
mote_tint :: proc(b: Block_Type) -> [3]f32 {
    c := block_color(b)
    return c / max(max(c.x, c.y), max(c.z, 0.05)) * 0.35 + MAGIC_TINT * 0.1
}

@(private="file")
rand_dir :: proc() -> [3]f32 {
    for {
        v := [3]f32{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)}
        if l := la.length(v); l > 0.05 && l <= 1 { return v / l }
    }
}

// ─── Casting ───────────────────────────────────────────────────────────────

// The clicks (build_update: the mouse locked, no sword out, not gliding).
// Left held unweaves the block aimed at (and the next, held on), right
// conjures one, again every EDIT_REPEAT while held; with the spell's size
// set, a ball about it (a disc, conjuring). With the box brush (B), holding
// and moving drags out a box instead (build_drag.odin), and a click on it
// once set right conjures it, or unweaves it by a cast that goes on by
// itself until done (a click calls it off).
magic_build_update :: proc(gs: ^Game_State, dt: f32) {
    m := &gs.magic
    if m.casting {
        if gs.left_pressed || gs.right_pressed { // called off; the click does only that
            m.casting, m.channeling = false, false
            drag_cancel(gs)
            return
        }
        if la.length(m.center - gs.camera.pos) > MAGIC_REACH * 1.5 { // walked away from it
            m.casting, m.channeling = false, false
            return
        }
        magic_channel(gs, dt)
        return
    }
    size := magic_spell_size(gs)
    if gs.build.box {
        d := &gs.build.drag
        switch drag_step(gs, MAGIC_REACH) {
        case .None:
        case .Press:
            if d.place {
                gs.build.stroke = false // the box's undo joins this block's, not an older edit
                magic_conjure(gs, d.hit, d.nrm)
                if gs.selected_block == .Door { drag_cancel(gs) } // doors go in one at a time
            } else {
                magic_begin(gs, d.hit, sphere_region(d.hit, 0), 0)
            }
        case .Held:
            if d.place { break }
            if d.moved {
                m.channeling = false // a box being dragged out: the cast waits for letting go
            } else if m.channeling {
                magic_channel(gs, dt)
                if !m.channeling { drag_rearm(gs) } // done: on to the next block aimed at
            }
        case .Release:
            m.channeling, m.starved = false, false // a dragged box waits for a click
        case .Confirm:
            r := drag_region(d)
            mid := (la.array_cast(r.lo, f32) + la.array_cast(r.hi, f32) + 1) / 2
            if magic_box_out_of_reach(gs, r) { // (drawn amber while it waits: build_preview)
                magic_fizzle(gs, nil)
                d.pending = true // still waiting
                break
            }
            if region_volume(r) > drag_limit(gs) {
                magic_fizzle(gs, nil)
                d.pending = true // still waiting, to be made smaller
                break
            }
            if d.place {
                magic_conjure_box(gs, r, d.start)
            } else {
                magic_begin(gs, d.hit, r, 0)
                m.casting = m.channeling
            }
        case .Cancel:
            m.channeling, m.starved = false, false
        }
        return
    }
    hit, nrm, ok := raycast_voxel(gs, camera_aim_eye(gs.camera), camera_forward(gs.camera), MAGIC_REACH, plants = true)
    if gs.left_held && ok {
        magic_begin(gs, hit, sphere_region(hit, size), size)
        magic_channel(gs, dt)
    } else {
        m.channeling = false
        m.starved = false
        m.refused = nil
    }
    placing := gs.right_pressed || (gs.right_held && gs.edit_timer <= 0)
    if placing && !gs.left_held {
        gs.edit_timer = EDIT_REPEAT
        if ok { magic_conjure(gs, hit, nrm) }
    }
}

// Sets the spell on the blocks of `r` (at: the block aimed at), unless
// that's what it's on already.
@(private="file")
magic_begin :: proc(gs: ^Game_State, at: [3]int, r: Edit_Region, size: int) {
    m := &gs.magic
    b := Block_Type(u8(get_voxel(gs, at.x, at.y, at.z)))
    if m.channeling && at == m.target && b == m.block && r.lo == m.region.lo && r.hi == m.region.hi && r.is_shape == m.region.is_shape { return }
    if no, ok := m.refused.?; ok && no == at && r.lo == r.hi { return } // it snapped here: let go first
    m.channeling, m.target, m.block, m.progress, m.size, m.stage, m.region = true, at, b, 0, size, 0, r
    lo, hi := la.array_cast(r.lo, f32), la.array_cast(r.hi, f32) + 1
    m.center = (lo + hi) / 2
    m.ring = 0.85 + f32(size)
    if !r.is_shape { m.ring = 0.35 + 0.5 * la.length((hi - lo).xz) } // a box: round its corners
    single := r.lo == r.hi
    m.whole = false
    m.tree_logs = single && block_is_log(u8(b)) ? felling_trunk_logs(gs, at) : 0
    if m.tree_logs > 0 {
        // A tree comes down in one breath: one too big for the spell drains
        // the mana dry on the way and snaps (no words needed: the bar says it).
        m.need, m.mana_total, m.count = fell_time(m.tree_logs), fell_mana(m.tree_logs), m.tree_logs
        m.ring = 1.6
        m.whole = true
        return
    }
    if single && !spell_can_take(gs.survival, voxel_item(u8(b))) {
        // Too hard for it yet: it cracks a little as the mana pours out, and snaps.
        m.need, m.mana_total, m.count = 2, MANA_MAX * 2.5, 1
        m.whole = true
        return
    }
    // The hardest block sets the pace; more of them, longer.
    hardest: f32
    m.count, m.mana_total = 0, 0
    for q in spell_take_targets(gs, r) {
        t := unweave_time(Block_Type(u8(get_voxel(gs, q.x, q.y, q.z))))
        hardest = max(hardest, t)
        m.count += 1
        m.mana_total += t * UNWEAVE_MANA
    }
    if m.count == 0 {
        m.channeling = false
        return
    }
    m.need = hardest * (1 + 0.45 * math.sqrt(f32(m.count - 1)))
    if !single { m.size = clamp(int(math.cbrt(f32(m.count))) - 1, 0, 4) } // a box sounds by how much it takes
}

// A frame of the spell at work (paying for it in survival); unweaves the
// blocks when it's done.
@(private="file")
magic_channel :: proc(gs: ^Game_State, dt: f32) {
    m := &gs.magic
    if !m.channeling { return }
    if !gs.survival || mana_draw(m, m.mana_total / max(m.need, 0.01) * dt) {
        m.progress += dt // creative: no mana
    } else if m.whole {
        magic_snap(gs)
        return
    }
    if m.progress >= m.need {
        magic_unweave(gs)
        m.channeling, m.casting = false, false
    }
}

// Run dry on something that had to be paid for in one breath: the weave
// snaps, the cracks close, sparks scatter dim off it, and it stays as it
// was. Holding on doesn't start it again: let go (or aim elsewhere) first.
@(private="file")
magic_snap :: proc(gs: ^Game_State) {
    m := &gs.magic
    sparks_burst(gs, m.center, MAGIC_TINT * 0.35, 14, 6)
    play_at(.Spell_Crack, m.center, 0.45, vary(0.04) * 0.6, 12) // a low snap
    play_at(dig_sound(block_material(m.block)), m.center, 0.2, vary(0.05) * 0.8, 10)
    m.starved_t = 0.8 // the empty bar flashes
    m.channeling, m.casting, m.starved = false, false, false
    m.refused = m.target
}

// The blocks of `r` a spell takes: what's solid or a plant (not air, not
// water). Temp.
spell_take_targets :: proc(gs: ^Game_State, r: Edit_Region) -> [dynamic][3]int {
    out := make([dynamic][3]int, context.temp_allocator)
    r := r
    for z in r.lo.z ..= r.hi.z { for y in r.lo.y ..= r.hi.y { for x in r.lo.x ..= r.hi.x {
        q := [3]int{x, y, z}
        if !region_contains(&r, q) { continue }
        v := u8(get_voxel(gs, q.x, q.y, q.z))
        if v == 0 || block_is_watery(v) || !spell_can_take(gs.survival, voxel_item(v)) { continue }
        append(&out, q)
    } } }
    return out
}

// The spell's blocks come apart (or, a tree's trunk, the tree comes down).
@(private="file")
magic_unweave :: proc(gs: ^Game_State) {
    m := &gs.magic
    if m.tree_logs > 0 && felling_start(gs, m.target) { return }
    // What they'll give, by kind, and where each kind is: for the motes.
    targets := spell_take_targets(gs, m.region)
    drops: [Block_Type]u32
    for q in targets { drops[voxel_item(u8(get_voxel(gs, q.x, q.y, q.z)))] += 1 }
    kinds := make([]Block_Type, len(targets), context.temp_allocator)
    for q, i in targets { kinds[i] = voxel_item(u8(get_voxel(gs, q.x, q.y, q.z))) }
    if build_apply(gs, m.region, .Air, .All, merge = false, spare_hard = gs.survival) == 0 { return }
    sparks_burst(gs, m.center, MAGIC_TINT, 10 + 4 * m.size, 5 + f32(m.size))
    motes_burst(gs, targets[:], kinds, drops)
    spell_break_sound(m.center, m.size)
}

// The spell's work done (with the material's dig: audio_edit). Also the sound board's.
spell_break_sound :: proc(c: [3]f32, size: int) {
    play_at(.Magic_Break, c, 0.5 + 0.1 * f32(size), vary(0.015) * spell_pitch(size)) // in tune with the loop it ends
}

// Motes from these spots (kinds[i] at spots[i]) bringing `drops`: each kind
// shared among its spots, at most a few dozen motes, and a little sparkle.
@(private="file")
motes_burst :: proc(gs: ^Game_State, spots: [][3]int, kinds: []Block_Type, drops: [Block_Type]u32) {
    MOTES :: 30
    stride := max(1, (len(spots) + MOTES - 1) / MOTES)
    of, given: [Block_Type]u32
    for i := 0; i < len(spots); i += stride { of[kinds[i]] += 1 }
    left := drops
    left[.Air] = 0
    for i := 0; i < len(spots); i += stride {
        b := kinds[i]
        if b == .Air { continue }
        given[b] += 1
        count := drops[b] / of[b]
        if given[b] == of[b] { count = left[b] } // the last of its kind takes the rest
        left[b] -= count
        mote_add(gs, {pos = block_center(spots[i]) + rand_dir() * 0.25, vel = rand_dir() * 4 + {0, 3, 0}, block = b,
            count = count, tint = mote_tint(b), size = 0.9})
        if len(spots) < 4 {
            mote_add(gs, {pos = block_center(spots[i]) + rand_dir() * 0.25, vel = rand_dir() * 4 + {0, 3, 0}, block = b, tint = mote_tint(b), size = 0.5})
        }
    }
}

// The block in hand, out of what you carry, on the face aimed at (in a
// plant's place, as the block tool does).
@(private="file")
magic_conjure :: proc(gs: ^Game_State, hit, nrm: [3]int) {
    b := gs.selected_block
    if b == .Air { return }
    if gs.survival && items_shown(gs, b) == 0 {
        magic_out_of(gs)
        return
    }
    m := &gs.magic
    if gs.survival && magic_mana(m) < CONJURE_MANA {
        m.starved_t = 0.6
        return
    }
    target := hit
    if !block_is_land_plant(u8(get_voxel(gs, hit.x, hit.y, hit.z))) { target = hit + nrm }
    if b == .Door {
        if !door_place(gs, hit, nrm) { return } // (spent as the edit is counted: items.odin)
        if gs.survival { mana_draw(m, CONJURE_MANA) }
    } else {
        // A disc of them on the face, the spell's size across, nearest the
        // middle first; in survival as many as you have and can pay for.
        size := magic_spell_size(gs)
        u, v := [3]int{nrm.y != 0 ? 1 : 0, nrm.y == 0 ? 1 : 0, 0}, [3]int{0, 0, 1}
        if nrm.z != 0 { v = {1, 0, 0} }
        cells := make([dynamic][3]int, context.temp_allocator)
        for ring in 0 ..= size * size { // round, as the brush's ball
            for j in -size ..= size { for i in -size ..= size {
                if i * i + j * j != ring { continue }
                q := target + u * i + v * j
                if conjure_fits(gs, b, q) { append(&cells, q) }
            } }
        }
        magic_conjure_cells(gs, cells[:], target, size)
        return
    }
    m.conjure, m.conjure_at = 0.2, block_center(target)
    sparks_burst(gs, m.conjure_at, mote_tint(b), 8, 3)
    play_at(.Magic_Place, m.conjure_at, 0.35, vary(0.02) * spell_pitch(magic_spell_size(gs)))
}

// The block in hand into the empty cells of a dragged-out box, nearest
// where the drag began first (so what you can't pay for is the far end).
@(private="file")
magic_conjure_box :: proc(gs: ^Game_State, r: Edit_Region, from: [3]int) {
    b := gs.selected_block
    if b == .Air || b == .Door { return }
    if gs.survival && items_shown(gs, b) == 0 {
        magic_out_of(gs)
        return
    }
    cells := make([dynamic][3]int, context.temp_allocator)
    for z in r.lo.z ..= r.hi.z { for y in r.lo.y ..= r.hi.y { for x in r.lo.x ..= r.hi.x {
        q := [3]int{x, y, z}
        if conjure_fits(gs, b, q) { append(&cells, q) }
    } } }
    if len(cells) == 0 { return }
    Near :: struct { p: [3]int, d: int }
    near := make([]Near, len(cells), context.temp_allocator)
    for q, i in cells { e := q - from; near[i] = {q, e.x * e.x + e.y * e.y + e.z * e.z} }
    slice.sort_by(near, proc(a, b: Near) -> bool { return a.d < b.d })
    for n, i in near { cells[i] = n.p }
    // As many as you have and can pay for, paid now; they fly out to land.
    m := &gs.magic
    n := len(cells)
    if gs.survival {
        n = min(n, int(items_shown(gs, b)), int(magic_mana(m) / CONJURE_MANA))
        if n == 0 { m.starved_t = 0.6; return }
        mana_draw(m, CONJURE_MANA * f32(n))
    }
    magic_send(gs, cells[:n], b)
}

// The block in hand sent out to `cells` (nearest first): motes leave your
// hands in a stream, each filling its cells as it lands (mote_land), the
// box building up in front of you. Unweaving the other way round.
@(private="file")
magic_send :: proc(gs: ^Game_State, cells: [][3]int, b: Block_Type) {
    m := &gs.magic
    if m.fill_out == 0 { m.fill_len = 0 }
    room := MAX_FILL - m.fill_len
    cells := cells[:min(len(cells), room)]
    if len(cells) == 0 { return }
    per := max(1, (len(cells) + SEND_MOTES - 1) / SEND_MOTES)
    groups := (len(cells) + per - 1) / per
    spread := clamp(f32(groups) * 0.03, 0.1, 1.0) // seconds from the first to leave to the last
    lo, hi := cells[0], cells[0]
    for c in cells { lo, hi = la.min(lo, c), la.max(hi, c) }
    for g in 0 ..< groups {
        first := m.fill_len
        for c in cells[g * per:min((g + 1) * per, len(cells))] {
            m.fill[m.fill_len] = {c, b}
            m.fill_len += 1
        }
        mote_add(gs, {pos = gs.camera.pos, age = -spread * f32(g) / f32(max(groups - 1, 1)) - 0.08, block = b, tint = mote_tint(b),
            size = 0.85, out = true, first = i32(first), n = i32(m.fill_len - first), tex = block_center(cells[g * per])})
        m.fill_out += 1
    }
    m.fill_done = 0
    m.conjure = spread + 0.5 // the hands stay up, the beam on the box, while they go
    m.conjure_at = (la.array_cast(lo, f32) + la.array_cast(hi, f32) + 1) / 2
    play(.Magic_Place, 0.3, vary(0.02) * 0.84) // a breath in as they go: a fourth under the landing's chime
}

// A sent mote reaching its box: its cells filled, if they're still empty
// and (in survival) you still have the block; a knock that climbs as the
// box fills, and the chime when the last lands.
@(private="file")
mote_land :: proc(gs: ^Game_State, mo: ^Mote) {
    m := &gs.magic
    mo.size = 0
    m.fill_out = max(m.fill_out - 1, 0)
    pos := make([dynamic][3]int, context.temp_allocator)
    blocks := make([dynamic]u8, context.temp_allocator)
    b := mo.block
    for f in m.fill[mo.first:][:mo.n] {
        if !conjure_fits(gs, f.block, f.pos) { continue }
        if gs.survival && int(items_shown(gs, f.block)) <= len(pos) { break }
        append(&pos, f.pos)
        append(&blocks, u8(f.block))
    }
    m.fill_done += int(mo.n)
    if len(pos) == 0 { return }
    build_set(gs, pos[:], blocks[:], undo = !gs.survival, merge = true) // one undo with the click's block (counted as spent: items.odin)
    c := block_center(pos[0])
    sparks_burst(gs, c, mote_tint(b), 3, 2)
    if m.fill_gap > 0.045 {
        m.fill_gap = 0
        k := clamp(f32(m.fill_done) / f32(max(m.fill_len, 1)), 0, 1)
        play_at(.Place, c, 0.3, vary(0.04) * (0.9 + 0.25 * k), 10)
        play_at(step_sound(block_material(b)), c, 0.22, vary(0.06) * (1 + 0.2 * k), 10)
    }
    if m.fill_out == 0 { play_at(.Magic_Place, c, 0.4, vary(0.015)) } // the last: the chime
}

// The spell comes to nothing: a puff of dim sparks, where it was cast at
// or else just before the hands, and a soft, falling breath.
magic_fizzle :: proc(gs: ^Game_State, at: Maybe([3]f32)) {
    cam := gs.camera
    p, ok := at.?
    if !ok { p = camera_aim_eye(cam) + camera_forward(cam) * (0.9 * world_scale) - [3]f32{0, 0.25 * world_scale, 0} }
    sparks_burst(gs, p, MAGIC_TINT * 0.3, 8, ok ? 2.5 : 1.2)
    play(.Magic_Place, 0.18, vary(0.03) * 0.6)
}

// Out of the block in hand: the spell fizzles and its count blinks.
@(private="file")
magic_out_of :: proc(gs: ^Game_State) {
    magic_fizzle(gs, nil)
    gs.magic.empty_t = 0.7
}

// A box too far off for the spell to reach from here (survival).
magic_box_out_of_reach :: proc(gs: ^Game_State, r: Edit_Region) -> bool {
    mid := (la.array_cast(r.lo, f32) + la.array_cast(r.hi, f32) + 1) / 2
    return la.length(mid - gs.camera.pos) > MAGIC_REACH * 1.5
}

// Whether block b may be conjured into q: it's empty (air, water, a plant),
// not where you stand, and a sapling has ground to root in.
@(private="file")
conjure_fits :: proc(gs: ^Game_State, b: Block_Type, q: [3]int) -> bool {
    cur := u8(get_voxel(gs, q.x, q.y, q.z))
    if !(cur == 0 || block_is_watery(cur) || block_is_land_plant(cur)) { return false }
    if block_solid(u8(b)) && aabb_hits_voxel(gs.camera.pos, q) { return false }
    if b == .Sapling && !sapling_ground(Block_Type(u8(get_voxel(gs, q.x, q.y - 1, q.z)))) { return false }
    return true
}

// Conjures the block in hand into `cells` (in order), in survival as many
// as you have and can pay for; the beam and sparks at `at`. size: how big
// it sounds. False if none went in.
@(private="file")
magic_conjure_cells :: proc(gs: ^Game_State, cells: [][3]int, at: [3]int, size: int) -> bool {
    m := &gs.magic
    b := gs.selected_block
    if len(cells) == 0 {
        if b == .Sapling { magic_fizzle(gs, block_center(at)) } // nothing to take root in
        return false
    }
    n := len(cells)
    if gs.survival {
        n = min(n, int(items_shown(gs, b)), int(magic_mana(m) / CONJURE_MANA))
        if n == 0 { m.starved_t = 0.6; return false }
    }
    blocks := make([]u8, n, context.temp_allocator)
    for &x in blocks { x = u8(b) }
    if build_set(gs, cells[:n], blocks, undo = !gs.survival) == 0 { return false } // (spent as the edit is counted: items.odin)
    audio_edit(at, b, .Air, min(size * 2, 8))
    if gs.survival { mana_draw(m, CONJURE_MANA * f32(n)) }
    m.conjure, m.conjure_at = 0.2, block_center(at)
    sparks_burst(gs, m.conjure_at, mote_tint(b), 8 + 2 * size, 3 + f32(size))
    play_at(.Magic_Place, m.conjure_at, 0.35 + 0.05 * f32(size), vary(0.02) * spell_pitch(size))
    return true
}

// A mote brought blocks home (they were counted when the edit was made:
// items.odin): a block that had no hotbar slot gets the first empty one.
magic_collect :: proc(gs: ^Game_State, b: Block_Type, n: u32) {
    if n == 0 || b == .Air || !gs.survival { return } // creative's hotbar is yours to set
    for h in gs.hotbar { if h == b { return } }
    for h, i in gs.hotbar {
        if h != .Air { continue }
        gs.hotbar[i] = b
        if i == gs.hotbar_slot { hotbar_select(gs, i) }
        return
    }
}

mote_add :: proc(gs: ^Game_State, mo: Mote) {
    m := &gs.magic
    old := &m.motes[m.next_mote]
    if old.size > 0 { // all slots busy: that one's there already
        if old.out { mote_land(gs, old) } else { magic_collect(gs, old.block, old.count) }
    }
    old^ = mo
    if !mo.out { old.tex = {math.floor(mo.pos.x), math.floor(mo.pos.y), math.floor(mo.pos.z)} }
    m.next_mote = (m.next_mote + 1) % MAX_MOTES
}

sparks_burst :: proc(gs: ^Game_State, c, tint: [3]f32, n: int, speed: f32) {
    m := &gs.magic
    for _ in 0 ..< n {
        life := rand.float32_range(0.25, 0.55)
        m.sparks[m.next_spark] = {pos = c + rand_dir() * 0.3, vel = rand_dir() * speed * rand.float32_range(0.5, 1.2), life = life, max = life, tint = tint}
        m.next_spark = (m.next_spark + 1) % MAX_SPARKS
    }
}

// ─── Every frame ───────────────────────────────────────────────────────────

// The spell's effects and the motes flying home; every frame, after
// build_update.
magic_update :: proc(gs: ^Game_State, dt: f32) {
    m := &gs.magic
    if dt <= 0 { return }
    m.t += dt
    m.conjure -= dt
    m.starved_t -= dt
    m.empty_t -= dt
    m.mana_rest += dt
    if m.mana_rest > MANA_REST { m.mana_spent = max(m.mana_spent - MANA_REGEN * dt, 0) }
    if !magic_active(gs) || !gs.mouse_locked || gs.combat.fighting || gs.glider.deployed { m.channeling, m.casting = false, false }
    up := m.channeling || m.conjure > 0
    m.raise = clamp(m.raise + (up ? dt * 6 : -dt * 2.5), 0, 1)
    if m.channeling { m.aim = m.center } else if m.conjure > 0 { m.aim = m.conjure_at }

    if m.channeling {
        c := m.center
        frac := clamp(m.progress / m.need, 0, 1)
        // Bits of the block flake off toward you as it unravels.
        m.chip_timer -= dt
        if m.chip_timer <= 0 {
            m.chip_timer = 0.07
            toward := la.normalize0(gs.camera.pos - c)
            add_goo(&gs.fx, {pos = c + rand_dir() * 0.5, vel = toward * rand.float32_range(2, 5) + rand_dir() * 1.5 + {0, 2, 0},
                life = 0.5, max = 0.5, size = rand.float32_range(0.08, 0.16), color = block_color(m.block) * 1.4, floor = c.y - 3})
        }
        // The spell's tone (audio's Spell loop), and the block cracking in
        // its own material, quicker and louder as it's about to give.
        audio_spell(frac, m.block, m.size, m.starved)
        m.hum_timer -= dt
        if m.hum_timer <= 0 && !m.starved && spell_cracks(m.need) {
            m.hum_timer = spell_crack(c, m.block, frac)
        }
        if st := crack_stage(frac); st > m.stage {
            m.stage = st
            if spell_cracks(m.need) {
                spell_crack_open(c, m.block, st)
                m.hum_timer = max(m.hum_timer, 0.08) // not a tick on top of the blow
            }
        }
    } else {
        m.hum_timer = 0.15 // the first crack a moment in, not as the beam lands
    }

    for &s in m.sparks {
        if s.life <= 0 { continue }
        s.life -= dt
        s.pos += s.vel * dt
        s.vel *= 1 - min(1, dt * 3)
    }

    // Motes: thrown out, then drawn in ever faster.
    m.pickup_gap += dt
    m.fill_gap += dt
    palms: [2][3]f32
    if m.fill_out > 0 { for h, i in cast_hands(gs) { palms[i] = h.palm } }
    for &mo in m.motes {
        if mo.size == 0 { continue }
        was := mo.age
        mo.age += dt
        if mo.age < 0 { continue }
        if mo.out {
            // Sent out: off a palm (as it goes, wherever you are by then),
            // flung a little wide, then homing in ever harder.
            if was < 0 {
                mo.pos = palms[mo.first & 1]
                to := mo.tex - mo.pos
                mo.vel = la.normalize0(to) * (5 + la.length(to) * 0.8) + rand_dir() * 2.5 + {0, 1.5, 0}
            }
            to := mo.tex - mo.pos
            d := la.length(to)
            want := to / max(d, 0.001) * (8 + 50 * mo.age)
            mo.vel += (want - mo.vel) * min(1, dt * (3 + 16 * mo.age))
            step := mo.vel * dt
            if d < 0.3 || la.length(step) >= d || mo.age > 4 {
                mote_land(gs, &mo)
                continue
            }
            mo.pos += step
            continue
        }
        eye := gs.camera.pos
        if mo.home > 0 {
            o := &gs.net.others[mo.home - 1]
            if !o.active { mo.size = 0; continue } // gone: so are its motes
            eye = o.pos
        }
        to := eye - {0, PLAYER_EYE_HEIGHT * 0.45, 0} - mo.pos
        d := la.length(to)
        if mo.age > 0.25 {
            k := mo.age - 0.25
            want := to / max(d, 0.001) * (6 + 60 * k)
            mo.vel += (want - mo.vel) * min(1, dt * (3 + 12 * k))
        } else {
            mo.vel *= 1 - min(1, dt * 4)
        }
        step := mo.vel * dt
        if d < 1.2 || (mo.age > 0.25 && la.length(step) >= d) || mo.age > 6 {
            mote_arrive(gs, &mo)
            continue
        }
        mo.pos += step
    }
}

@(private="file")
mote_arrive :: proc(gs: ^Game_State, mo: ^Mote) {
    m := &gs.magic
    if mo.count > 0 && mo.home == 0 {
        magic_collect(gs, mo.block, mo.count)
        pickup_sound(&m.pickup_gap, &m.pickup_run)
    }
    mo.size = 0
}

// A mote home (`gap` seconds since the last): a quick run of them climbs a
// pentatonic scale, and stays at its top. Also the sound board's.
pickup_sound :: proc(gap: ^f32, run: ^int) {
    SCALE :: [8]f32{0, 2, 4, 7, 9, 12, 14, 16} // semitones
    if gap^ <= 0.05 { return }
    run^ = gap^ < 0.4 ? min(run^ + 1, len(SCALE) - 1) : 0
    scale := SCALE
    play(.Pickup, 0.24, math.pow(2, scale[run^] / 12) * vary(0.004))
    gap^ = 0
}

// The block under the spell cracking in its own material, `frac` of the way
// undone: quicker and louder as it's about to give. Returns the seconds to
// the next crack. Also the sound board's.
spell_crack :: proc(c: [3]f32, b: Block_Type, frac: f32) -> f32 {
    play_at(step_sound(block_material(b)), c, 0.1 + 0.25 * frac, vary(0.06) * (1 + 0.2 * frac), 10)
    return math.lerp(f32(0.3), 0.11, frac) * rand.float32_range(0.85, 1.15)
}

// Whether unweaving takes long enough to crack as it goes (not plants, leaves).
spell_cracks :: proc(need: f32) -> bool { return need > 0.25 }

// The block splits in stages as it comes undone, each with a blow (the
// tracer draws the cracks: magic_crack_uniform).
CRACK_STAGES :: 5

crack_stage :: proc(frac: f32) -> int { return clamp(int(frac * (CRACK_STAGES + 1)), 0, CRACK_STAGES) }

// A new crack opening, stage 1..CRACK_STAGES: a snap and a thump, with the
// material's crunch; heavier and deeper as the block weakens. Also the sound board's.
spell_crack_open :: proc(c: [3]f32, b: Block_Type, stage: int) {
    k := f32(stage) / CRACK_STAGES
    play_at(.Spell_Crack, c, 0.3 + 0.35 * k, vary(0.04) * (1.1 - 0.25 * k), 12)
    play_at(dig_sound(block_material(b)), c, 0.15 + 0.25 * k, vary(0.05) * (1.25 - 0.2 * k), 10)
}

// For the tracer: the blocks being unwoven (a box, and within it a ball's
// radius if a ball) and how far they've cracked.
magic_crack_uniform :: proc(gs: ^Game_State) -> (lo, hi: [4]i32) {
    m := &gs.magic
    if !m.channeling || m.stage == 0 { return }
    r := m.region
    if m.tree_logs > 0 { r = sphere_region(m.target, 0) }
    lo = {i32(r.lo.x), i32(r.lo.y), i32(r.lo.z), i32(m.stage)}
    hi = {i32(r.hi.x), i32(r.hi.y), i32(r.hi.z), i32(r.is_shape ? r.size : 0)}
    return
}

// ─── Drawing ───────────────────────────────────────────────────────────────

// The hands, in first person: both come up when you cast, palms to the
// block. Each: the arm (design metres about the eye, drawn world_scale times
// as big), the glove's frame, and where its palm sends the spell from (world).
@(private="file")
Cast_Hand :: struct {
    shoulder, elbow, wrist: [3]f32,
    rot:  Basis,
    palm: [3]f32,
}

@(private="file")
cast_hands :: proc(gs: ^Game_State) -> (hands: [2]Cast_Hand) {
    m := &gs.magic
    cam := gs.camera
    fwd, right, up := camera_view_basis(cam, 1)
    right, up = la.normalize(right), la.normalize(up)
    eye := camera_view_eye(cam)
    r := 1 - (1 - m.raise) * (1 - m.raise)
    frac := m.channeling ? clamp(m.progress / max(m.need, 0.01), 0, 1) : 0
    for &h, i in hands {
        s := i == 0 ? f32(1) : -1 // right, left
        h.shoulder = eye + right * (0.2 * s) - up * 0.42 - fwd * 0.05
        // Out in front, pressing on as the block gives, trembling with it.
        wrist := eye + right * (0.16 * s) - up * 0.2 + fwd * (0.42 + 0.04 * frac) - up * (1 - r) * 0.45
        if m.channeling {
            w := m.t * 31 + f32(i) * 2
            wrist += (right * math.sin(w) + up * math.cos(w * 1.3)) * 0.003 * (1 + frac)
        }
        pole := right * (0.25 * s) - up - fwd * 0.4 // elbows hang down: the forearms rise from below the view
        h.elbow, h.wrist = two_bone_ik(h.shoulder, wrist, pole, UPPER_ARM_LEN, FOREARM_LEN)
        // Palm to the front and a little in, fingers up.
        palm_n := la.normalize(fwd - right * (0.22 * s) - up * 0.4)
        lean := up + fwd * 0.55
        fingers := la.normalize(lean - palm_n * la.dot(lean, palm_n))
        y := -palm_n
        h.rot = basis_from_axes(la.cross(y, fingers), y, fingers)
        palm := h.wrist + fingers * 0.05 + palm_n * 0.03
        h.palm = eye + (palm - eye) * world_scale
    }
    return
}

magic_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    m := &gs.magic
    first := !gs.camera.climbing && !gs.glider.deployed && gs.glider.chase_dist <= 1.5 && !gs.combat.fighting
    hands := cast_hands(gs)
    frac := m.channeling ? clamp(m.progress / m.need, 0, 1) : 1
    if first && m.raise > 0.01 && ent_begin(f) {
        ent_scale_about(f, camera_view_eye(gs.camera), world_scale)
        // The runes on the palms glow brighter as the spell takes hold.
        rune := MAGIC_TINT * ((m.channeling || m.conjure > 0 ? 0.7 + 0.8 * frac : 0.35) * (0.9 + 0.1 * math.sin(m.t * 9)))
        for h, i in hands {
            // The body's own sleeves (creatures.odin), as others see them:
            // stretched to these arms' lengths, slimmer, as they come right
            // past the eye; the gold cuff at the wrist, under the glove's.
            limb :: proc(f: ^Ent_Frame, model: Model_Id, a, b, ref: [3]f32, length, k: f32, paint: Paint) {
                d := b - a
                l := la.length(d)
                if l < 1e-4 { return }
                body_part(f, model, a, basis_hang_along(d, ref), paint, {k, l / length, k})
            }
            fwd := camera_forward(gs.camera)
            paint := look_paint(gs.look)
            limb(f, look_parts(gs.look).arm, h.shoulder, h.elbow, fwd, HUM_UPPER_LEN, 0.75, paint)
            limb(f, look_parts(gs.look).fore, h.elbow, h.wrist, fwd, HUM_FORE_LEN, 0.75, paint)
            ent_part(f, i == 0 ? .Glove_R : .Glove_L, h.wrist, h.rot, {1, 1, 1}, rune)
        }
        ent_end(f)
    }

    if !ent_begin(f, false) { return }
    if first && m.raise > 0.5 && (m.channeling || m.conjure > 0) {
        c := m.channeling ? m.center : m.conjure_at
        ring := m.ring
        spell_beam_parts(f, {hands[0].palm, hands[1].palm}, c, m.channeling, frac, m.t, ring, m.size, mote_tint(m.block))
    }
    for s in m.sparks {
        if s.life <= 0 { continue }
        k := 0.6 * math.sqrt(s.life / s.max)
        ent_part(f, .Spark, s.pos, IDENTITY, {k, k, k}, s.tint)
    }
    chest := gs.camera.pos - {0, PLAYER_EYE_HEIGHT * 0.45, 0}
    for mo in m.motes {
        if mo.size == 0 || mo.age < 0 { continue }
        // Smaller as they reach you, so none fills the view going by.
        near := clamp(la.length(chest - mo.pos) / 4, 0.35, 1)
        // A little block of what it brings, tumbling as it goes.
        k := mo.size * near * (0.9 + 0.1 * math.sin(m.t * 14 + mo.pos.x))
        spin := m.t * 5 + mo.tex.x * 1.3 + mo.tex.z * 0.7
        ent_part(f, .Mote, mo.pos, basis_yaw(spin) * basis_rot_x(spin * 0.6), {k, k, k})
        ent_texture(f, mo.block, mo.tex, 1.0 / 8)
    }
    ent_end(f)
}

// The beam, from the palms to the block c: two strands of sparks braided
// about the line, flowing in (toward the caster while unweaving, out while
// conjuring); a swirl at each palm, and while unweaving a ring round the
// block closing in and quickening as it comes undone (frac 0..1). Ours, or
// another player's (others_add_parts).
spell_beam_parts :: proc(f: ^Ent_Frame, palms: [2][3]f32, c: [3]f32, channeling: bool, frac, t, ring: f32, size: int, block_tint: [3]f32) {
    tip := (palms[0] + palms[1]) * 0.5
    d := c - tip
    l := la.length(d)
    dir := d / max(l, 0.001)
    s1 := la.normalize0(la.cross(dir, [3]f32{0, 1, 0}))
    if s1 == 0 { s1 = {1, 0, 0} }
    s2 := la.cross(dir, s1)
    n := clamp(int(l * 2.2), 6, 30)
    flow := channeling ? -t * 1.4 : t * 3
    for i in 0 ..< n {
        u := (f32(i) + 0.5) / f32(n) + flow
        u -= math.floor(u)
        bulge := math.sin(u * math.PI)
        // Each strand leaves its own palm and they meet at the block.
        from := palms[i & 1]
        ph := f32(i & 1) * math.PI
        p := from + (c - from) * u + (s1 * math.sin(t * 9 + u * 13 + ph) + s2 * math.cos(t * 7 + u * 10 + ph)) * bulge * (0.2 + 0.2 * frac)
        k := (0.3 + 0.35 * bulge) * clamp(la.length(p - from) / 3 + 0.25, 0.25, 1) // small by the hands, where they're near the eye
        ent_part(f, .Spark, p, IDENTITY, {k, k, k}, MAGIC_TINT * (0.5 + 0.5 * bulge))
    }
    for palm in palms {
        for j in 0 ..< 2 {
            a := t * 8 + f32(j) * math.PI
            p := palm + (s1 * math.cos(a) + s2 * math.sin(a)) * 0.06
            ent_part(f, .Spark, p, IDENTITY, {0.12, 0.12, 0.12}, MAGIC_TINT * 0.9)
        }
    }
    if channeling {
        k := 4 + int(frac * 10) + 4 * size
        tint := la.lerp(MAGIC_TINT, block_tint, frac)
        for j in 0 ..< k {
            a := t * (2 + 7 * frac) + f32(j) * math.TAU / f32(k)
            r := ring * (1 - 0.35 * frac)
            p := c + {math.cos(a) * r, math.sin(t * 3 + f32(j)) * 0.35, math.sin(a) * r}
            ent_part(f, .Spark, p, IDENTITY, {0.6, 0.6, 0.6}, tint)
        }
    }
}

// What our body's hands are doing, for drawing it (player_add_parts) and
// telling the others (client_send_input).
local_body_act :: proc(gs: ^Game_State) -> (act: Body_Act) {
    cam := &gs.camera
    m := &gs.magic
    act.t = m.t
    if cam.climbing {
        act.climbing, act.at = true, cam.mantle.hands
        act.k = cam.mantle.t / max(cam.mantle.dur, 0.01)
        return
    }
    act.raise, act.at = m.raise, m.aim
    if m.channeling { act.k = clamp(m.progress / max(m.need, 0.01), 0, 1) }
    return
}

// ─── The gloves ─────────────────────────────────────────────────────────────
// Open hands in leather gloves, the wrist at the origin, fingers along +z,
// the palm facing -y; a gold-trimmed cuff, and a rune on the palm and a stone
// on the back that glow in the part's tint (Pal.Magic).

GLOVE_VOXEL :: f32(0.01)

magic_models_bake :: proc() {
    ent_models[.Glove_R] = model_bake({-0.065, -0.04, -0.07}, {0.095, 0.04, 0.2}, GLOVE_VOXEL, proc(p: [3]f32, voxel: f32) -> Pal { return glove_shape(p) })
    ent_models[.Glove_L] = model_bake({-0.095, -0.04, -0.07}, {0.065, 0.04, 0.2}, GLOVE_VOXEL, proc(p: [3]f32, voxel: f32) -> Pal { return glove_shape({-p.x, p.y, p.z}) })
}

// A right glove (thumb toward +x: seen from behind, palm out, it's on the left).
@(private="file")
glove_shape :: proc(p: [3]f32) -> Pal {
    // The cuff, round the wrist, banded in gold where it meets the hand.
    if p.z < 0.004 && p.z > -0.04 {
        if vm_round_box(p, {0, 0, -0.018}, {0.04, 0.022, 0.02}, 0.008) < 0 {
            return p.z > -0.01 ? .Guard : .Leather_Dark
        }
        return .Empty
    }
    palm := vm_round_box(p, {0, 0, 0.05}, {0.043, 0.014, 0.05}, 0.007)
    if palm < 0 {
        if p.y < 0 {
            // The rune: a ring and a dot in the middle of the palm.
            r := la.length(p.xz - {0, 0.05})
            if (r > 0.012 && r < 0.02) || r < 0.006 { return .Magic }
        }
        if p.y > 0 {
            if abs(p.x) + abs(p.z - 0.048) < 0.018 { return .Magic } // the stone: a diamond
            if p.z > 0.086 { return .Glove_Light } // knuckles
        }
        return .Glove
    }
    // Fingers, a little curled toward the palm; index (nearest the thumb) first.
    XS   :: [4]f32{0.03, 0.01, -0.01, -0.03}
    LENS :: [4]f32{0.075, 0.085, 0.078, 0.062}
    xs, lens := XS, LENS
    for i in 0 ..< 4 {
        a := [3]f32{xs[i], 0, 0.092}
        b := [3]f32{xs[i], -0.014, 0.092 + lens[i]}
        if vm_capsule(p, a, b, 0.0095) < 0 { return p.z > b.z - 0.014 ? .Glove_Dark : .Glove }
    }
    if vm_capsule(p, {0.034, -0.006, 0.028}, {0.074, -0.02, 0.074}, 0.011) < 0 { return .Glove } // thumb
    return .Empty
}
