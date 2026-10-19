package main

// Sound, all of it synthesized (no audio files), after the cat game's audio.odin.
//
// One-shots (footsteps per material, digging, splashes, the glider's wing, animal
// calls) are built at startup, a few takes each. The ambience (wind, rushing air,
// leaves, water, cave, insects) is generated live and kept a little ahead of
// playback; what's around the player sets each loop's volume.
//
// SDL mixes a pool of stereo audio streams bound to one device. A one-shot goes to a
// free voice with its pan, cave echo and underwater muffling baked in; each loop has
// its own stream. Bench runs never open the device (quiet test runs).

import "core:fmt"
import "core:math"
import la "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:sync"
import "core:thread"
import SDL "vendor:sdl3"

SAMPLE_RATE   :: 44100
VOICES        :: 24
VARIANTS      :: 3    // takes of each one-shot, picked at random
MASTER_VOLUME :: 0.8
LOOP_AHEAD    :: 0.1  // seconds of loop audio kept queued
ECHO_TAIL     :: 1.0  // seconds added to a one-shot played in a cave
EDIT_SOUND_GAP :: 0.11 // held mouse buttons edit every frame; sound at most this often

Material :: enum u8 { Grass, Dirt, Stone, Sand, Snow, Wood, Leaves, Gravel, Ice }

Sound :: enum u8 {
    // Footsteps, in Material order.
    Step_Grass, Step_Dirt, Step_Stone, Step_Sand, Step_Snow, Step_Wood, Step_Leaves, Step_Gravel, Step_Ice,
    // Breaking a block, in Material order.
    Dig_Grass, Dig_Dirt, Dig_Stone, Dig_Sand, Dig_Snow, Dig_Wood, Dig_Leaves, Dig_Gravel, Dig_Ice,
    Place, // a block set down: a dull thunk, played under the material's step
    Torch, // catching alight
    Jump,
    Land,
    Splash,
    Swim,
    Glider_Open,
    Glider_Close,
    Crash,
    Eagle,
    Fox,
    Drip, // water dripping in a cave
    Bird_Warble, Bird_Whistle, Bird_Trill, Bird_Chatter,
    Click,
    // combat.odin, slime.odin
    Sword_Draw, Sword_Swing, Dodge, Slam, Hurt,
    Slime_Hop, Slime_Hit, Slime_Pop,
    // enemies.odin
    Bone_Hit, Bone_Rattle, Bone_Break,
    Clang, // a blow caught on the blade
    // magic.odin, felling.odin
    Magic_Channel, Magic_Break, Magic_Place, Pickup,
    Spell_Crack, // a crack opening in a block being unwoven
    Tree_Creak, Tree_Fall,
}

Loop_Kind :: enum u8 { Wind, Rush, Leaves, Water, Underwater, Cave, Insects, Spell }

// A live loop. The filter/envelope fields mean different things per loop.
Loop :: struct {
    stream: ^SDL.AudioStream,
    t:      f32,
    lp:     [6][2]f32, // filter states, per channel
    env:    [2][2]f32, // burst envelopes, per channel
    phase:  [2][2]f32, // oscillator phases, per channel
    freq:   [2]f32,
    muffle: [2][2]f32, // underwater low-pass
}

Audio :: struct {
    ok, muted:         bool,
    effects, ambience: f32, // 0..1 volume settings (options panel)
    device:     SDL.AudioDeviceID,
    voices:     [VOICES]^SDL.AudioStream,
    next_voice: int,
    sounds:     [Sound][VARIANTS][]f32,
    synth:      ^thread.Thread, // making the sounds, at startup (audio_init)
    ready:      bool,           // ... done, ok or not (atomic): until then, quiet (audio_on)
    loops:      [Loop_Kind]Loop,
    mono:       [dynamic]f32,
    scratch:    [dynamic]f32,
    time:       f32,

    // The listener and its surroundings.
    ear_pos, ear_right: [3]f32,
    under: f32, // 0..1 head under water: muffles everything
    echo:  f32, // 0..1 cave echo on one-shots
    // Loop drivers, 0..1, smoothed.
    wind, wind_bright, rush, flutter, leaves, water, cave, crickets, cicadas: f32,
    // Random voxel samples around the player, as decaying tallies.
    leaf_hits, water_hits, samples: f32,
    agl:   f32, // eye height above the terrain (or the sea)
    biome: Biome,

    // Footsteps, landings and splashes: ours, and the other players'.
    me:         Body_Sounds,
    others:     [MAX_PLAYERS]Body_Sounds,
    prev_block: Block_Type,
    next_bird, next_eagle, next_drip, next_biome, last_edit: f32,

    spell: Spell_Sound,
}

// Our spell while it unweaves a block, as a loop (Loop_Kind.Spell; magic_update
// sets it every frame through audio_spell). A soft pad through a phaser whose
// sweep quickens and deepens as the block comes undone, the tone rising
// gently, the block crackling ever faster under it; the break (Magic_Break)
// resolves it.
SPELL_BASE_HZ :: 196 // G3; Magic_Break and Magic_Place are tuned to it

Spell_Sound :: struct {
    want:    bool, // cast this frame (audio_spell; audio_update clears it)
    frac:    f32,  // 0..1 how far the block has come undone
    low:     f32,  // pitch factor: bigger spells are lower
    grit:    f32,  // 0 soft (leaves, earth) .. 1 hard (stone, ore): the crackle
    starved: bool, // waiting for mana: it sags and goes quiet
    // Per sample, smoothed toward the above.
    on, amp, k, f, sweep: f32,
    phase: [6]f32,
    grain: [2]f32,
    lp:    [2][2]f32,
    ap:    [2][6]f32, // the phaser's all-passes, per channel
    fb:    [2]f32,
    soft:  [2]f32,    // the pad's low-pass
}

// The volume settings start at 70%, with room to turn them up.
audio := Audio{effects = 0.7, ambience = 0.7}

audio_init :: proc() {
    if !SDL.InitSubSystem({.AUDIO}) {
        fmt.eprintln("No audio:", SDL.GetError())
        return
    }
    // The rest on a thread, with the window still black meanwhile: opening
    // the device takes ~0.4 s, making the sounds ~1 s in a debug build.
    audio.synth = thread.create_and_start(proc() {
        defer sync.atomic_store(&audio.ready, true)
        spec := SDL.AudioSpec{format = .F32, channels = 2, freq = SAMPLE_RATE}
        audio.device = SDL.OpenAudioDevice(SDL.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec)
        if audio.device == 0 {
            fmt.eprintln("No audio device:", SDL.GetError())
            return
        }
        for &v in audio.voices { v = SDL.CreateAudioStream(&spec, nil) }
        _ = SDL.BindAudioStreams(audio.device, &audio.voices[0], VOICES)
        for &l in audio.loops {
            l.stream = SDL.CreateAudioStream(&spec, nil)
            _ = SDL.BindAudioStream(audio.device, l.stream)
        }
        generate_sounds()
        audio.ok = true
    })
}

// Sound to play: the device open and the sounds made (audio_init).
audio_on :: proc() -> bool {
    return sync.atomic_load(&audio.ready) && audio.ok
}

// No device to play on, it turned out.
audio_missing :: proc() -> bool {
    return sync.atomic_load(&audio.ready) && !audio.ok
}

audio_shutdown :: proc() {
    if audio.synth != nil {
        thread.join(audio.synth)
        thread.destroy(audio.synth)
    }
    if audio.device != 0 { SDL.CloseAudioDevice(audio.device) }
    for v in audio.voices { SDL.DestroyAudioStream(v) }
    for l in audio.loops { SDL.DestroyAudioStream(l.stream) }
    for takes in audio.sounds {
        for s in takes { delete(s) }
    }
    delete(audio.mono)
    delete(audio.scratch)
}

audio_toggle_mute :: proc() {
    audio.muted = !audio.muted
}

// Plays a one-shot. pitch also changes speed; pan is -1 left .. 1 right.
// Benches (where audio is off): every sound that would play, counted.
bench_heard: ^[Sound]int

play :: proc(sound: Sound, volume: f32 = 1, pitch: f32 = 1, pan: f32 = 0) {
    if bench_heard != nil { bench_heard[sound] += 1 }
    if !audio_on() || audio.muted || volume * audio.effects < 0.003 { return }
    src := audio.sounds[sound][rand.int_max(VARIANTS)]

    // Mono working copy: the cave echo needs room for its tail.
    echo := audio.echo > 0.05
    n := len(src) + (echo ? int(ECHO_TAIL * SAMPLE_RATE) : 0)
    resize(&audio.mono, n)
    copy(audio.mono[:], src)
    for &s in audio.mono[len(src):] { s = 0 }
    if echo { add_echo(audio.mono[:], audio.echo) }
    if audio.under > 0.05 { muffle(audio.mono[:], audio.under) }

    // Equal-power pan into interleaved stereo.
    a := (clamp(pan, -1, 1) + 1) * math.PI / 4
    gl, gr := math.cos(a) * 1.2, math.sin(a) * 1.2
    resize(&audio.scratch, n * 2)
    for s, i in audio.mono {
        audio.scratch[2 * i]     = s * gl
        audio.scratch[2 * i + 1] = s * gr
    }

    // A free voice, or else steal the next one in turn.
    voice: ^SDL.AudioStream
    for v in audio.voices {
        if SDL.GetAudioStreamQueued(v) == 0 { voice = v; break }
    }
    if voice == nil {
        voice = audio.voices[audio.next_voice]
        audio.next_voice = (audio.next_voice + 1) % VOICES
        _ = SDL.ClearAudioStream(voice)
    }
    _ = SDL.SetAudioStreamGain(voice, volume * MASTER_VOLUME * audio.effects)
    _ = SDL.SetAudioStreamFrequencyRatio(voice, pitch)
    _ = SDL.PutAudioStreamData(voice, raw_data(audio.scratch), i32(len(audio.scratch) * size_of(f32)))
}

// A one-shot from a point in the world: quieter with distance (half volume at
// `range`), panned by which side of the listener it's on.
play_at :: proc(sound: Sound, pos: [3]f32, volume: f32 = 1, pitch: f32 = 1, range: f32 = 12) {
    d := pos - audio.ear_pos
    dist := la.length(d)
    q := dist / range
    pan := dist > 0.01 ? la.dot(d, audio.ear_right) / dist : 0
    play(sound, volume / (1 + q * q), pitch, pan * 0.85)
}

// Random pitch variation so repeated sounds don't sound identical.
vary :: proc(amount: f32 = 0.08) -> f32 {
    return 1 + rand.float32_range(-amount, amount)
}

block_material :: proc(b: Block_Type) -> Material {
    if block_is_door(u8(b)) || b == .Workbench { return .Wood }
    #partial switch b {
    case .Grass, .Dry_Grass, .Moss:      return .Grass
    case .Dirt:                          return .Dirt
    case .Sand, .Red_Sand:               return .Sand
    case .Snow:                          return .Snow
    case .Ice:                           return .Ice
    case .Log, .Spruce_Log, .Birch_Log, .Acacia_Log, .Cactus, .Torch: return .Wood
    case .Leaves, .Spruce_Leaves, .Birch_Leaves, .Autumn_Leaves, .Acacia_Leaves, .Willow_Leaves: return .Leaves
    case .Gravel:                        return .Gravel
    }
    return .Stone
}

step_sound :: proc(m: Material) -> Sound { return Sound(int(Sound.Step_Grass) + int(m)) }
dig_sound  :: proc(m: Material) -> Sound { return Sound(int(Sound.Dig_Grass) + int(m)) }

// A block broken (block == .Air, old = what was there) or placed, from main's edit code.
audio_edit :: proc(pos: [3]int, block, old: Block_Type, radius: int) {
    if audio.time - audio.last_edit < EDIT_SOUND_GAP { return }
    audio.last_edit = audio.time
    p := [3]f32{f32(pos.x) + 0.5, f32(pos.y) + 0.5, f32(pos.z) + 0.5}
    big := f32(radius) / 8 // bigger brush: louder and lower
    switch {
    case block == .Air:
        if old == .Air || old == .Water { return }
        play_at(dig_sound(block_material(old)), p, 0.55 + 0.45 * big, vary(0.1) * (1 - 0.3 * big), 10)
    case block == .Torch:
        play_at(.Torch, p, 0.5, vary(), 10)
    case:
        play_at(.Place, p, 0.5 + 0.4 * big, vary(0.08) * (1 - 0.25 * big), 10)
        play_at(step_sound(block_material(block)), p, 0.45, vary(), 10)
    }
}

// The pitch the spell's sounds take for a spell of this size.
spell_pitch :: proc(size: int) -> f32 { return 1 - 0.07 * f32(min(size, 4)) }

// Our spell is unweaving a block, `frac` of the way: called every frame it is.
audio_spell :: proc(frac: f32, b: Block_Type, size: int, starved: bool) {
    s := &audio.spell
    s.want, s.frac, s.low, s.starved = true, frac, spell_pitch(size), starved
    s.grit = clamp((unweave_time(b) - 0.15) / 1.0, 0, 1)
}

// A door swinging open or banging shut: a wooden knock, lower shutting.
audio_door :: proc(pos: [3]int, opening: bool) {
    p := [3]f32{f32(pos.x) + 0.5, f32(pos.y) + 1, f32(pos.z) + 0.5}
    play_at(.Place, p, opening ? 0.35 : 0.6, vary(0.06) * (opening ? 1.15 : 0.8), 12)
    play_at(.Step_Wood, p, opening ? 0.5 : 0.7, vary(0.06) * (opening ? 1.1 : 0.85), 12)
}

// Once a frame, after the player and entities have moved.
audio_update :: proc(gs: ^Game_State, dt: f32) {
    if !audio_on() { return }
    audio.time += dt
    _, right, _ := camera_basis(gs.camera)
    audio.ear_pos, audio.ear_right = gs.camera.pos, right
    surroundings_update(gs, dt)
    player_sounds(gs, dt)
    others_sounds(gs, dt)
    ambient_calls(gs)
    audio.spell.on = audio.spell.want ? (audio.spell.starved ? 0.4 : 1) : 0
    audio.spell.want = false
    loops_update()
}

@(private="file")
ease :: proc(x: ^f32, target, rate, dt: f32) {
    x^ += (target - x^) * min(rate * dt, 1)
}

// Whether the water at p is frozen over: ice on top of its column. No
// waves there, so it makes no water sound (frozen seas and lakes).
@(private="file")
under_ice :: proc(gs: ^Game_State, p: [3]f32) -> bool {
    x, y, z := int(math.floor(p.x)), int(math.floor(p.y)), int(math.floor(p.z))
    for k in 1 ..= 32 {
        b := Block_Type(get_voxel(gs, x, y + k, z))
        if !block_is_watery(u8(b)) { return b == .Ice }
    }
    return false
}

// What's around the player, turned into the loops' drivers.
surroundings_update :: proc(gs: ^Game_State, dt: f32) {
    cam := &gs.camera
    p := cam.pos
    ease(&audio.under, block_is_watery(u8(voxel_at(gs, p))) ? 1 : 0, 10, dt)
    ease(&audio.echo, math.smoothstep(f32(0.25), 0.8, gs.cave_factor), 2, dt)
    ease(&audio.cave, gs.cave_factor, 1.5, dt)

    // Random voxels in a ball around the player, counted into tallies that forget
    // over a second or two: how much foliage and water is near.
    SAMPLES :: 40
    RADIUS  :: f32(16)
    keep := math.exp(-dt / 1.5)
    audio.leaf_hits *= keep
    audio.water_hits *= keep
    audio.samples *= keep
    for _ in 0 ..< SAMPLES {
        d := [3]f32{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)}
        if la.dot(d, d) > 1 { continue }
        q := p + d * RADIUS
        #partial switch voxel_at(gs, q) {
        case .Leaves, .Spruce_Leaves, .Birch_Leaves, .Autumn_Leaves, .Acacia_Leaves, .Willow_Leaves: audio.leaf_hits += 1
        case .Water, .Kelp, .Seagrass, .Sea_Pickle: if !under_ice(gs, q) { audio.water_hits += 1 }
        }
        audio.samples += 1
    }
    n := max(audio.samples, 1)
    ease(&audio.leaves, clamp(audio.leaf_hits / n * 6, 0, 1), 2, dt)
    ease(&audio.water, clamp(audio.water_hits / n * 4, 0, 1) * (1 - audio.under), 2, dt)

    x, z := int(math.floor(p.x)), int(math.floor(p.z))
    audio.agl = p.y - f32(max(surface_height_at(x, z), SEA_LEVEL))
    if audio.time >= audio.next_biome {
        audio.biome = terrain_at(x, z).biome
        audio.next_biome = audio.time + 1
    }
    outside := (1 - gs.cave_factor) * (1 - audio.under)

    // Wind: stronger and brighter the higher you are above the ground.
    high := math.smoothstep(f32(4), 90, audio.agl)
    ease(&audio.wind, (0.3 + 0.7 * high) * (1 - gs.cave_factor) * (1 - 0.7 * audio.under), 1, dt)
    ease(&audio.wind_bright, math.smoothstep(f32(10), 140, audio.agl), 1, dt)

    // Rushing air from moving fast (falling, gliding, flying); the wing luffs in a stall.
    moved := p - audio.me.prev_pos // last frame's: player_sounds runs after this
    speed := la.length(moved) / max(dt, 0.001)
    if speed > 300 && !cam.fly_mode { speed = 0 } // a teleport (spawn, bench), not motion
    ease(&audio.rush, math.smoothstep(f32(9), 45, speed) * (1 - 0.6 * audio.under), 4, dt)
    ease(&audio.flutter, gs.glider.deployed ? gs.glider.stall : 0, 6, dt)

    // Insects in the grass and the heat; quieter up high.
    crickets, cicadas: f32
    #partial switch audio.biome {
    case .Plains: crickets, cicadas = 0.7, 0.15
    case .Forest: crickets = 0.4
    case .River:  crickets = 0.45
    case .Beach:  crickets = 0.2
    case .Taiga:  crickets = 0.2
    case .Desert, .Badlands, .Savanna: cicadas = 1
    }
    low := 1 - math.smoothstep(f32(6), 30, audio.agl)
    ease(&audio.crickets, crickets * low * outside, 0.4, dt)
    ease(&audio.cicadas, cicadas * low * outside, 0.4, dt)
}

// Footsteps, jumps, landings, splashes and the glider's wing, from how the player moved.
@(private="file")
// A body's state last frame, for its footsteps, landings and splashes.
Body_Sounds :: struct {
    seen:               bool, // has a last frame (another player just come: not yet)
    prev_pos, prev_vel: [3]f32,
    prev_on_ground, prev_in_water, prev_gliding, prev_sword: bool,
    stride, stroke:     f32, // distance left to the next footstep / swim stroke
}

OTHER_STEP_VOLUME :: f32(0.8) // other players' body sounds, against our own: a crowd doesn't clatter

// Our own body's sounds, and the bits only we hear (the hotbar's click).
player_sounds :: proc(gs: ^Game_State, dt: f32) {
    cam := &gs.camera
    body_sounds(gs, &audio.me, cam.pos, cam.velocity, cam.on_ground, cam.fly_mode, gs.glider.deployed, dt, remote = false)
    if gs.selected_block != audio.prev_block && audio.prev_block != .Air {
        play(.Click, 0.35)
    }
    audio.prev_block = gs.selected_block
}

// The other players' bodies, where they are as we draw them (as heard from
// the server): footsteps, jumps, landings, splashes, the glider, the sword
// coming out. Their swings and hurts come with the views and events.
others_sounds :: proc(gs: ^Game_State, dt: f32) {
    for &o, i in gs.net.others {
        s := &audio.others[i]
        if !o.active || i == gs.net.slot {
            s.seen = false
            continue
        }
        p := &o.latest
        if s.seen && p.sword != s.prev_sword {
            play_at(.Sword_Draw, p.pos - {0, 0.5, 0}, (p.sword ? 0.7 : 0.5) * OTHER_STEP_VOLUME, (p.sword ? 1 : 0.8) * vary(0.05), 12)
        }
        s.prev_sword = p.sword
        body_sounds(gs, s, p.pos, p.velocity, p.on_ground, p.fly_mode, p.gliding, dt, remote = true)
    }
}

// One body's sounds from how it moved since last frame: p its eye. Ours
// play in the head; another player's (remote) where it is.
@(private="file")
body_sounds :: proc(gs: ^Game_State, s: ^Body_Sounds, p, vel: [3]f32, on_ground, fly, gliding: bool, dt: f32, remote: bool) {
    snd :: proc(remote: bool, at: [3]f32, sound: Sound, vol, pitch: f32) {
        if remote { play_at(sound, at, vol * OTHER_STEP_VOLUME, pitch, 12) } else { play(sound, vol, pitch) }
    }
    feet := p - {0, PLAYER_EYE_HEIGHT + 0.05, 0}
    in_water := block_is_watery(u8(voxel_at(gs, p - {0, PLAYER_EYE_HEIGHT * 0.5, 0})))
    walking := !fly && !gliding
    moved := p - s.prev_pos
    teleport := !s.seen || la.length(moved) > 40

    if !teleport {
        if walking && on_ground && !in_water {
            horiz := la.length(moved.xz)
            s.stride -= horiz
            if s.stride <= 0 {
                hspeed := horiz / max(dt, 0.001)
                s.stride = 1.9 + hspeed * 0.11 // longer strides when running
                vol := clamp(0.22 + 0.03 * hspeed, 0, 0.6)
                if block_is_watery(u8(voxel_at(gs, feet + {0, 0.3, 0}))) {
                    snd(remote, feet, .Swim, vol * 0.7, vary(0.15) * 1.2) // wading
                } else {
                    snd(remote, feet, step_sound(ground_material(gs, feet)), vol, vary())
                }
            }
        } else if !on_ground {
            s.stride = 0.6
        }

        // Pushing off for a jump.
        if walking && s.prev_on_ground && !on_ground && vel.y > JUMP_SPEED * 0.5 && !in_water {
            snd(remote, feet, .Jump, 0.3, vary())
            snd(remote, feet, step_sound(ground_material(gs, s.prev_pos - {0, PLAYER_EYE_HEIGHT + 0.05, 0})), 0.25, vary())
        }
        // Landing: harder falls land louder and lower.
        if !fly && !s.prev_on_ground && on_ground {
            impact := -s.prev_vel.y
            if impact > 5 {
                v := clamp((impact - 5) / 25, 0, 1)
                snd(remote, feet, .Land, 0.25 + 0.6 * v, vary(0.06) * (1.05 - 0.2 * v))
                snd(remote, feet, step_sound(ground_material(gs, feet)), 0.4 + 0.3 * v, vary())
                s.stride = 1.2
            }
        }

        // Into and out of water, and swim strokes.
        if in_water && !s.prev_in_water {
            impact := -s.prev_vel.y
            if impact > 4 {
                snd(remote, feet, .Splash, clamp(0.35 + impact / 30, 0, 1), vary() * (impact > 20 ? 0.85 : 1))
            } else {
                snd(remote, feet, .Swim, 0.4, vary(0.1))
            }
            s.stroke = 1.5
        } else if !in_water && s.prev_in_water {
            snd(remote, feet, .Swim, 0.3, vary(0.1))
        }
        if in_water && walking {
            speed := la.length(moved) / max(dt, 0.001)
            s.stroke -= la.length(moved)
            if s.stroke <= 0 {
                s.stroke = 2.4
                if speed > 0.8 { snd(remote, feet, .Swim, clamp(0.15 + speed * 0.05, 0, 0.45), vary(0.12)) }
            }
        }
    }

    if s.seen && gliding != s.prev_gliding {
        snd(remote, p, gliding ? .Glider_Open : .Glider_Close, 0.55, vary(0.05))
    }

    s.prev_pos, s.prev_vel = p, vel
    s.prev_on_ground, s.prev_in_water, s.prev_gliding = on_ground, in_water, gliding
    s.seen = true
}

// What's underfoot. Standing on an edge the voxel straight down can be air, so
// look at the neighbours under the player's box too.
@(private="file")
ground_material :: proc(gs: ^Game_State, feet: [3]f32) -> Material {
    b := voxel_at(gs, feet)
    if b == .Air {
        for o in ([4][2]f32{{-PLAYER_HALF_W, 0}, {PLAYER_HALF_W, 0}, {0, -PLAYER_HALF_W}, {0, PLAYER_HALF_W}}) {
            b = voxel_at(gs, feet + {o.x, 0, o.y})
            if b != .Air { break }
        }
    }
    if b == .Air || block_is_watery(u8(b)) { return .Dirt }
    return block_material(b)
}

// Songbirds in the trees, eagles over the thermals, drips in caves.
@(private="file")
ambient_calls :: proc(gs: ^Game_State) {
    t := audio.time
    outside := (1 - gs.cave_factor) * (1 - audio.under)

    if t >= audio.next_bird {
        audio.next_bird = t + rand.float32_range(0.8, 4.0)
        base: f32
        #partial switch audio.biome {
        case .Forest:    base = 0.5
        case .River:     base = 0.35
        case .Taiga:     base = 0.35
        case .Plains:    base = 0.3
        case .Mountains: base = 0.15
        case .Beach, .Snowy: base = 0.1
        case .Desert, .Badlands: base = 0.03
        }
        busy := clamp(base + audio.leaves * 1.2, 0, 1) * outside * (1 - math.smoothstep(f32(20), 60, audio.agl))
        if rand.float32() < busy {
            a := rand.float32_range(0, 2 * math.PI)
            d := rand.float32_range(6, 28)
            pos := audio.ear_pos + {math.cos(a) * d, rand.float32_range(2, 9), math.sin(a) * d}
            call := Sound(int(Sound.Bird_Warble) + rand.int_max(4))
            play_at(call, pos, rand.float32_range(0.25, 0.6), vary(0.1), 14)
        }
    }

    if t >= audio.next_eagle {
        audio.next_eagle = t + rand.float32_range(5, 12)
        if gs.entities_enabled && rand.float32() < 0.7 {
            // A random eagle within earshot.
            pick := -1
            seen := 0
            for e, i in gs.entities {
                if e.kind != .Bird || la.length(e.pos - audio.ear_pos) > 200 { continue }
                seen += 1
                if rand.int_max(seen) == 0 { pick = i }
            }
            if pick >= 0 { play_at(.Eagle, gs.entities[pick].pos, 0.6, vary(0.06), 45) }
        }
    }

    if t >= audio.next_drip {
        audio.next_drip = t + rand.float32_range(0.5, 3.0)
        if gs.cave_factor > 0.35 && audio.under < 0.5 {
            a := rand.float32_range(0, 2 * math.PI)
            d := rand.float32_range(3, 12)
            pos := audio.ear_pos + {math.cos(a) * d, rand.float32_range(-1, 3), math.sin(a) * d}
            play_at(.Drip, pos, rand.float32_range(0.25, 0.55) * gs.cave_factor, rand.float32_range(0.8, 1.3), 8)
        }
    }
}

// Sets each loop's volume from the drivers and keeps it fed.
@(private="file")
loops_update :: proc() {
    amb := MASTER_VOLUME * audio.ambience * (audio.muted ? 0 : 1)
    gains := [Loop_Kind]f32{
        .Wind       = 0.35 * audio.wind,
        .Rush       = 0.6 * audio.rush,
        .Leaves     = 0.25 * audio.leaves * (1 - audio.cave),
        .Water      = 0.45 * audio.water,
        .Underwater = 0.5 * audio.under,
        .Cave       = 0.4 * audio.cave,
        .Insects    = 0.09 * max(audio.crickets, audio.cicadas),
        .Spell      = 0.5, // its own envelope (spell_sample), at the effects' volume
    }
    for kind in Loop_Kind {
        l := &audio.loops[kind]
        g := gains[kind] * amb
        audible := g > 0.0005
        if kind == .Spell {
            sp := &audio.spell
            g = gains[kind] * MASTER_VOLUME * audio.effects * (audio.muted ? 0 : 1)
            audible = g > 0.0005 && (sp.on > 0 || sp.amp > 1e-4)
            // Starting: what's queued is silence, so drop it and sound at once.
            if audible && sp.on > 0 && sp.amp < 1e-4 { _ = SDL.ClearAudioStream(l.stream) }
        }
        _ = SDL.SetAudioStreamGain(l.stream, g)
        fill_loop(l, kind, audible)
    }
}

// Tops a loop's stream up to LOOP_AHEAD seconds. A silent loop gets zeros, which
// costs nothing to make.
@(private="file")
fill_loop :: proc(l: ^Loop, kind: Loop_Kind, audible: bool) {
    queued := int(SDL.GetAudioStreamQueued(l.stream)) / (2 * size_of(f32))
    ahead := kind == .Spell ? f32(0.05) : LOOP_AHEAD // the spell answers the mouse
    need := int(ahead * SAMPLE_RATE) - queued
    if need <= 0 { return }
    resize(&audio.scratch, need * 2)
    for i in 0 ..< need {
        s: [2]f32
        if audible { s = loop_sample(l, kind) }
        audio.scratch[2 * i], audio.scratch[2 * i + 1] = s[0], s[1]
        l.t += 1.0 / SAMPLE_RATE
    }
    _ = SDL.PutAudioStreamData(l.stream, raw_data(audio.scratch), i32(need * 2 * size_of(f32)))
}

@(private="file")
loop_sample :: proc(l: ^Loop, kind: Loop_Kind) -> [2]f32 {
    s: [2]f32
    switch kind {
    case .Wind:       s = wind_sample(l)
    case .Rush:       s = rush_sample(l)
    case .Leaves:     s = leaves_sample(l)
    case .Water:      s = water_sample(l)
    case .Underwater: s = underwater_sample(l)
    case .Cave:       s = cave_sample(l)
    case .Insects:    s = insects_sample(l)
    case .Spell:      s = spell_sample(l)
    }
    // Brings every loop to about 0.2 RMS at full drive (measured with `sounds`).
    LEVEL :: [Loop_Kind]f32{.Wind = 0.7, .Rush = 0.7, .Leaves = 1.4, .Water = 0.7, .Underwater = 0.28, .Cave = 0.28, .Insects = 1.5, .Spell = 1.4}
    level := LEVEL
    s *= level[kind]
    // Under water everything but the water itself is heard through it.
    if kind != .Underwater && audio.under > 0.01 {
        c := 1 - 0.95 * audio.under
        for ch in 0 ..< 2 {
            l.muffle[0][ch] += (s[ch] - l.muffle[0][ch]) * c
            l.muffle[1][ch] += (l.muffle[0][ch] - l.muffle[1][ch]) * c
            s[ch] = l.muffle[1][ch]
        }
    }
    return s
}

white :: #force_inline proc() -> f32 {
    return rand.float32() * 2 - 1
}

@(private="file")
fract :: #force_inline proc(x: f32) -> f32 {
    return x - math.floor(x)
}

// 0..1, slowly rising and falling: the wind's gusts. Leaves rustle with it.
@(private="file")
gust_at :: proc(t: f32) -> f32 {
    return clamp(0.5 + 0.5 * math.sin(t * 0.31) * math.sin(t * 0.17 + 2) + 0.15 * math.sin(t * 1.3), 0, 1)
}

// Doubly low-passed noise, a different draw per ear, with a wandering cutoff; up
// high it's brighter and gustier.
@(private="file")
wind_sample :: proc(l: ^Loop) -> (out: [2]f32) {
    gust := gust_at(l.t)
    bright := audio.wind_bright
    cutoff := 0.004 + 0.01 * bright + (0.008 + 0.025 * bright) * gust
    for ch in 0 ..< 2 {
        l.lp[0][ch] += (white() - l.lp[0][ch]) * cutoff
        l.lp[1][ch] += (l.lp[0][ch] - l.lp[1][ch]) * cutoff
        out[ch] = l.lp[1][ch] * 9 * (0.35 + 0.65 * gust)
    }
    return
}

// Air rushing past: band-passed noise that gets brighter with speed. When the
// glider stalls the cloth luffs, chopping it up.
@(private="file")
rush_sample :: proc(l: ^Loop) -> (out: [2]f32) {
    hi := 0.05 + 0.3 * audio.rush
    l.phase[0][0] = fract(l.phase[0][0] + 16.0 / SAMPLE_RATE)
    luff := 1 - audio.flutter * 0.7 * (0.5 + 0.5 * math.sin(l.phase[0][0] * math.TAU))
    for ch in 0 ..< 2 {
        n := white()
        l.lp[0][ch] += (n - l.lp[0][ch]) * hi
        l.lp[1][ch] += (n - l.lp[1][ch]) * 0.008
        l.lp[2][ch] += (l.lp[1][ch] - l.lp[2][ch]) * 0.02 // a low rumble under it
        out[ch] = ((l.lp[0][ch] - l.lp[1][ch]) * 0.9 + l.lp[2][ch] * 6) * luff
    }
    return
}

// Leaves: a bed of soft noise and rustling grains, busier in gusts. Each grain
// swells in over a few milliseconds (an instant attack on high noise is a
// click, and hundreds a second of them crackle), and they stay sparse.
@(private="file")
leaves_sample :: proc(l: ^Loop) -> (out: [2]f32) {
    gust := gust_at(l.t - 0.8) // the trees answer the wind a moment later
    rate := (30 + 220 * gust * gust) / SAMPLE_RATE
    for ch in 0 ..< 2 {
        if rand.float32() < rate { l.env[0][ch] = max(l.env[0][ch], rand.float32_range(0.2, 0.6)) }
        l.env[0][ch] *= 0.9985
        l.env[1][ch] += (l.env[0][ch] - l.env[1][ch]) * 0.01 // ~2 ms attack
        n := white()
        l.lp[0][ch] += (n - l.lp[0][ch]) * 0.35
        l.lp[1][ch] += ((n - l.lp[0][ch]) - l.lp[1][ch]) * 0.25 // high-passed, the top softened
        out[ch] = l.lp[1][ch] * (0.15 + l.env[1][ch]) * (0.3 + 0.7 * gust) * 1.1
    }
    return
}

// Water: slow swells that break and hiss back out, each ear on its own timing,
// and small waves lapping in between.
@(private="file")
water_sample :: proc(l: ^Loop) -> (out: [2]f32) {
    for ch in 0 ..< 2 {
        w := fract(l.t / 7.3 + f32(ch) * 0.37)
        swell := math.smoothstep(f32(0), 0.6, w) * (w < 0.6 ? 1 : math.exp(-(w - 0.6) * 5))
        cut := 0.008 + 0.07 * swell
        l.lp[0][ch] += (white() - l.lp[0][ch]) * cut
        l.lp[1][ch] += (l.lp[0][ch] - l.lp[1][ch]) * cut
        surf := l.lp[1][ch] * (0.25 + swell) * 5

        if rand.float32() < 3.0 / SAMPLE_RATE { l.env[0][ch] = rand.float32_range(0.3, 1) }
        l.env[0][ch] *= 0.9993
        n := white()
        l.lp[2][ch] += (n - l.lp[2][ch]) * 0.12
        l.lp[3][ch] += (l.lp[2][ch] - l.lp[3][ch]) * 0.03
        lap := (l.lp[2][ch] - l.lp[3][ch]) * l.env[0][ch] * 1.5
        out[ch] = surf + lap
    }
    return
}

// Under water: a deep, muffled rumble with bubbles rising now and then.
@(private="file")
underwater_sample :: proc(l: ^Loop) -> (out: [2]f32) {
    for ch in 0 ..< 2 {
        l.lp[0][ch] += (white() - l.lp[0][ch]) * 0.004
        l.lp[1][ch] += (l.lp[0][ch] - l.lp[1][ch]) * 0.004
        if l.env[0][ch] < 0.01 && rand.float32() < 1.5 / SAMPLE_RATE {
            l.env[0][ch] = rand.float32_range(0.2, 0.6)
            l.lp[5][ch] = rand.float32_range(250, 700) // the bubble's start pitch
        }
        l.env[0][ch] *= 0.9995
        l.lp[5][ch] *= 1.00003 // bubbles rise in pitch as they shrink
        l.phase[0][ch] = fract(l.phase[0][ch] + l.lp[5][ch] / SAMPLE_RATE)
        bubble := math.sin(l.phase[0][ch] * math.TAU) * l.env[0][ch]
        out[ch] = l.lp[1][ch] * 40 + bubble * 0.3
    }
    return
}

// A cave: a very low rumble, a faint beating hum and a distant moan of air.
@(private="file")
cave_sample :: proc(l: ^Loop) -> (out: [2]f32) {
    t := l.t
    hum := math.sin(t * 55 * math.TAU) * 0.25 + math.sin(t * 82.7 * math.TAU) * 0.15 * (0.6 + 0.4 * math.sin(t * 0.4))
    moan := 0.5 + 0.5 * math.sin(t * 0.13) * math.sin(t * 0.07 + 1)
    for ch in 0 ..< 2 {
        l.lp[0][ch] += (white() - l.lp[0][ch]) * 0.003
        l.lp[1][ch] += (l.lp[0][ch] - l.lp[1][ch]) * 0.003
        // The moan: noise through a resonant band-pass that drifts around 200 Hz.
        f := 2 * math.sin(math.PI * (170 + 60 * moan + f32(ch) * 15) / SAMPLE_RATE)
        l.lp[2][ch] += f * l.lp[3][ch]
        l.lp[3][ch] += f * (white() - l.lp[2][ch] - 0.04 * l.lp[3][ch])
        out[ch] = l.lp[1][ch] * 45 + hum * 0.4 + l.lp[3][ch] * 0.02 * moan
    }
    return
}

// Crickets (a pulsed chirp every so often, one per ear at its own pace) and, in the
// heat, cicadas: a buzzing hiss that swells and fades.
@(private="file")
insects_sample :: proc(l: ^Loop) -> (out: [2]f32) {
    t := l.t
    for ch in 0 ..< 2 {
        period := ch == 0 ? f32(0.83) : 0.71
        ct := math.mod(t + f32(ch) * 0.3, period)
        pt := math.mod(ct, f32(1.0 / 30))
        freq := ch == 0 ? f32(4400) : 4750
        l.phase[0][ch] = fract(l.phase[0][ch] + freq / SAMPLE_RATE)
        cricket: f32
        if ct < 4.0 / 30 && pt < 0.018 {
            cricket = math.sin(l.phase[0][ch] * math.TAU) * math.sin(pt / 0.018 * math.PI)
        }

        swell := 0.5 + 0.5 * math.sin(t * 0.5 + f32(ch) * 2)
        swell *= swell
        buzz := 0.5 + 0.5 * math.sin(t * 140 * math.TAU)
        n := white()
        l.lp[0][ch] += (n - l.lp[0][ch]) * 0.6
        l.phase[1][ch] = fract(l.phase[1][ch] + (5600 + f32(ch) * 210) / SAMPLE_RATE)
        cicada := (math.sin(l.phase[1][ch] * math.TAU) * 0.6 + (n - l.lp[0][ch]) * 0.5) * buzz * swell

        out[ch] = cricket * audio.crickets * 0.6 + cicada * audio.cicadas * 0.5
    }
    return
}

@(private="file")
spell_sample :: proc(l: ^Loop) -> [2]f32 { return spell_voice(&audio.spell) }

// The spell at work: a pad of root, fifth and octave, each two voices a few
// cents apart and split between the ears (a slow chorus), with a breath of
// air, through a stereo phaser. As the block gives the sweep quickens and
// deepens and the tone rises a fifth; under it the block crackles, sparse at
// first, thick as it is about to go, drier for harder stone. Fades in and out
// by itself (Spell_Sound.on).
@(private="file")
spell_voice :: proc(s: ^Spell_Sound) -> (out: [2]f32) {
    s.amp += (s.on - s.amp) * (s.on > s.amp ? 0.003 : 0.0012) // ~8 ms in, ~20 ms out
    s.k += (s.frac - s.k) * 0.002
    k := s.k
    want_f := f32(SPELL_BASE_HZ) * s.low * math.pow(f32(1.5), k) * (s.starved ? 0.94 : 1)
    if s.f == 0 { s.f = want_f }
    s.f += (want_f - s.f) * 0.0015
    if s.amp < 1e-5 { return }

    DET  :: [6]f32{1, 1.0035, 1.4985, 1.5025, 2.003, 1.997}
    GAIN :: [6]f32{0.5, 0.5, 0.3, 0.3, 0.16, 0.16}
    det, gain := DET, GAIN
    pad: [2]f32
    for i in 0 ..< 6 {
        s.phase[i] = fract(s.phase[i] + s.f * det[i] / SAMPLE_RATE)
        p := s.phase[i] * math.TAU
        pad[i & 1] += (math.sin(p) + 0.3 * math.sin(2 * p) + 0.12 * math.sin(3 * p)) * gain[i] // some body for the phaser to carve
    }

    // The phaser: six all-passes swept between ~250 Hz and ~2.5 kHz, a
    // quarter turn apart in each ear.
    s.sweep = fract(s.sweep + (0.22 + 1.6 * k * k) / SAMPLE_RATE)
    depth := 0.55 + 0.45 * k
    rate := (4 + 150 * k * k * k) * (s.starved ? 0.15 : 1) / SAMPLE_RATE
    hi := 0.1 + 0.45 * s.grit
    lo := 0.015 + 0.08 * s.grit
    for ch in 0 ..< 2 {
        n := white()
        s.lp[1][ch] += (n - s.lp[1][ch]) * lo
        breath := s.lp[1][ch] * 0.6
        lfo := 0.5 + 0.5 * math.sin((s.sweep + f32(ch) * 0.25) * math.TAU)
        fc := 250 * math.pow(f32(10), lfo * depth)
        tn := math.tan(math.PI * fc / SAMPLE_RATE)
        a := (tn - 1) / (tn + 1)
        x := pad[ch] + breath + s.fb[ch] * (0.35 + 0.3 * k)
        y := x
        for j in 0 ..< 6 {
            z := s.ap[ch][j]
            o := a * y + z
            s.ap[ch][j] = y - a * o
            y = o
        }
        s.fb[ch] = y
        wet := (pad[ch] + breath + y) * 0.5
        s.soft[ch] += (wet - s.soft[ch]) * 0.3 // nothing shrill: ~2.5 kHz and down

        if rand.float32() < rate { s.grain[ch] = rand.float32_range(0.3, 1) }
        s.grain[ch] *= 0.994 - 0.004 * s.grit // ~4 ms, shorter and drier in stone
        s.lp[0][ch] += (n - s.lp[0][ch]) * hi
        crackle := (s.lp[0][ch] - s.lp[1][ch]) * s.grain[ch] * (0.35 + 0.6 * k)
        out[ch] = (s.soft[ch] * 0.4 + crackle) * s.amp
    }
    return
}

// --- Effects on one-shots ---

// A cave's echo: four damped combs and two all-passes (a small Schroeder reverb),
// plus a slap back off a far wall.
@(private="file")
add_echo :: proc(buf: []f32, amount: f32) {
    COMB :: [4]int{1557, 1617, 1491, 1422}
    comb_len := COMB
    combs: [4][1617]f32
    ci: [4]int
    damp: [4]f32
    ap1: [225]f32
    ap2: [556]f32
    slap: [4851]f32 // 0.11 s
    a1, a2, si: int
    fade_from := len(buf) - SAMPLE_RATE / 10
    for &s, i in buf {
        x := s
        wet: f32
        for k in 0 ..< 4 {
            y := combs[k][ci[k]]
            damp[k] += (y - damp[k]) * 0.45 // the walls soak up the highs
            combs[k][ci[k]] = x + damp[k] * 0.8
            ci[k] = (ci[k] + 1) % comb_len[k]
            wet += y
        }
        wet *= 0.25
        y1 := ap1[a1]
        ap1[a1] = wet + y1 * 0.5
        wet = y1 - wet * 0.5
        a1 = (a1 + 1) % len(ap1)
        y2 := ap2[a2]
        ap2[a2] = wet + y2 * 0.5
        wet = y2 - wet * 0.5
        a2 = (a2 + 1) % len(ap2)
        sy := slap[si]
        slap[si] = x + sy * 0.4
        si = (si + 1) % len(slap)
        s = x + (wet * 0.9 + sy * 0.35) * amount
        if i > fade_from { s *= f32(len(buf) - i) / f32(len(buf) - fade_from) }
    }
}

// Heard through water: most of the top end gone.
@(private="file")
muffle :: proc(buf: []f32, amount: f32) {
    c := 1 - 0.93 * amount
    a, b: f32
    for &s in buf {
        a += (s - a) * c
        b += (a - b) * c
        s = b * (1 + 0.4 * amount) // what's left is the low end; keep it audible
    }
}

// --- Sound synthesis ---

// Attack linearly, then decay exponentially to ~1% over `decay` seconds.
@(private="file")
env :: proc(t, attack, decay: f32) -> f32 {
    if t < 0 { return 0 }
    if t < attack { return t / attack }
    return math.exp(-(t - attack) * 4.6 / decay)
}

// Exponential slide from a to b over `time` seconds, then holds b.
@(private="file")
slide :: proc(t, a, b, time: f32) -> f32 {
    return a * math.pow(b / a, clamp(t / time, 0, 1))
}

@(private="file")
osc :: proc(phase: ^f32, freq: f32) -> f32 {
    phase^ = fract(phase^ + freq / SAMPLE_RATE)
    return math.sin(phase^ * math.TAU)
}

@(private="file")
new_buf :: proc(seconds: f32) -> []f32 {
    return make([]f32, int(seconds * SAMPLE_RATE))
}

// Scales a sound so its loudest sample is `peak`.
@(private="file")
normalize :: proc(buf: []f32, peak: f32 = 0.9) {
    m: f32
    for s in buf { m = max(m, abs(s)) }
    if m > 0 {
        for &s in buf { s *= peak / m }
    }
}

@(private="file")
generate_sounds :: proc() {
    for sound in Sound {
        for v in 0 ..< VARIANTS {
            buf := synth(sound)
            normalize(buf)
            audio.sounds[sound][v] = buf
        }
    }
}

@(private="file")
synth :: proc(sound: Sound) -> []f32 {
    switch sound {
    // Footsteps: a soft heel knock under the material's texture.
    case .Step_Grass:  return crunch({length = 0.22, attack = 0.008, decay = 0.16, band = {0.05, 0.55}, hiss = 0.25, grains = 900, grain_len = 0.003, thump = 0.35, thump_hz = 70})
    case .Step_Dirt:   return crunch({length = 0.18, attack = 0.004, decay = 0.11, band = {0.01, 0.18}, hiss = 0.5, grains = 400, grain_len = 0.004, thump = 0.7, thump_hz = 80})
    case .Step_Stone:  return crunch({length = 0.14, attack = 0.001, decay = 0.05, band = {0.15, 0.7}, hiss = 0.5, grains = 200, grain_len = 0.002, thump = 0.5, thump_hz = 110, ring = 0.5, ring_hz = 2200, ring_q = 0.08})
    case .Step_Sand:   return crunch({length = 0.26, attack = 0.02, decay = 0.2, band = {0.08, 0.5}, hiss = 0.7, grains = 1500, grain_len = 0.002, thump = 0.2, thump_hz = 60})
    case .Step_Snow:   return crunch({length = 0.3, attack = 0.03, decay = 0.22, band = {0.03, 0.35}, hiss = 0.1, grains = 2500, grain_len = 0.0025, thump = 0.25, thump_hz = 60})
    case .Step_Wood:   return crunch({length = 0.16, attack = 0.001, decay = 0.07, band = {0.05, 0.4}, hiss = 0.3, grains = 100, grain_len = 0.002, thump = 0.5, thump_hz = 140, ring = 0.8, ring_hz = 420, ring_q = 0.1})
    case .Step_Leaves: return crunch({length = 0.3, attack = 0.015, decay = 0.22, band = {0.15, 0.8}, hiss = 0.1, grains = 1800, grain_len = 0.002, thump = 0.15, thump_hz = 70})
    case .Step_Gravel: return crunch({length = 0.22, attack = 0.003, decay = 0.16, band = {0.1, 0.6}, hiss = 0.15, grains = 1200, grain_len = 0.003, thump = 0.3, thump_hz = 80, ring = 0.2, ring_hz = 1800, ring_q = 0.2})
    case .Step_Ice:    return crunch({length = 0.14, attack = 0.001, decay = 0.06, band = {0.2, 0.8}, hiss = 0.3, grains = 150, grain_len = 0.002, thump = 0.3, thump_hz = 120, ring = 0.7, ring_hz = 3500, ring_q = 0.03})
    // Digging: longer, denser, a heavier knock.
    case .Dig_Grass:   return crunch({length = 0.4, attack = 0.005, decay = 0.3, band = {0.04, 0.5}, hiss = 0.4, grains = 1600, grain_len = 0.004, thump = 0.6, thump_hz = 60})
    case .Dig_Dirt:    return crunch({length = 0.38, attack = 0.003, decay = 0.28, band = {0.01, 0.2}, hiss = 0.6, grains = 900, grain_len = 0.006, thump = 0.9, thump_hz = 55})
    case .Dig_Stone:   return crunch({length = 0.45, attack = 0.001, decay = 0.3, band = {0.1, 0.75}, hiss = 0.5, grains = 700, grain_len = 0.005, thump = 1, thump_hz = 70, ring = 0.3, ring_hz = 1500, ring_q = 0.15})
    case .Dig_Sand:    return crunch({length = 0.45, attack = 0.02, decay = 0.35, band = {0.06, 0.45}, hiss = 0.9, grains = 2000, grain_len = 0.002, thump = 0.3, thump_hz = 50})
    case .Dig_Snow:    return crunch({length = 0.4, attack = 0.01, decay = 0.3, band = {0.02, 0.3}, hiss = 0.3, grains = 3000, grain_len = 0.003, thump = 0.4, thump_hz = 50})
    case .Dig_Wood:    return crunch({length = 0.4, attack = 0.001, decay = 0.25, band = {0.04, 0.5}, hiss = 0.3, grains = 600, grain_len = 0.004, thump = 0.8, thump_hz = 90, ring = 0.9, ring_hz = 320, ring_q = 0.06})
    case .Dig_Leaves:  return crunch({length = 0.45, attack = 0.01, decay = 0.35, band = {0.12, 0.8}, hiss = 0.2, grains = 2500, grain_len = 0.003, thump = 0.1, thump_hz = 60})
    case .Dig_Gravel:  return crunch({length = 0.45, attack = 0.003, decay = 0.35, band = {0.08, 0.6}, hiss = 0.2, grains = 2200, grain_len = 0.004, thump = 0.5, thump_hz = 60, ring = 0.3, ring_hz = 1600, ring_q = 0.2})
    case .Dig_Ice:     return synth_shatter()
    case .Place:       return synth_place()
    case .Torch:       return synth_torch()
    case .Jump:        return crunch({length = 0.2, attack = 0.03, decay = 0.12, band = {0.02, 0.15}, hiss = 1, grains = 0, grain_len = 0.001, thump = 0.15, thump_hz = 90})
    case .Land:        return synth_land()
    case .Splash:      return synth_splash(1.0, 0.25, 0.45, 16)
    case .Swim:        return synth_splash(0.5, 0.15, 0.2, 5)
    case .Glider_Open:  return synth_flutter(0.6, 38, 12, 0.35, 1)
    case .Glider_Close: return synth_flutter(0.45, 15, 30, 0.3, 0)
    case .Crash:       return synth_crash()
    case .Eagle:       return synth_eagle()
    case .Fox:         return synth_fox()
    case .Drip:        return synth_drip()
    case .Bird_Warble:  return synth_warble()
    case .Bird_Whistle: return synth_whistle()
    case .Bird_Trill:   return synth_trill()
    case .Bird_Chatter: return synth_chatter()
    case .Click:       return synth_click()
    case .Sword_Draw:  return synth_draw()
    case .Sword_Swing: return synth_whoosh(0.28, 0.06, 0.5)
    case .Dodge:       return synth_whoosh(0.3, 0.02, 0.18)
    case .Slam:        return crunch({length = 0.9, attack = 0.002, decay = 0.6, band = {0.01, 0.3}, hiss = 0.6, grains = 1800, grain_len = 0.006, thump = 1, thump_hz = 42})
    case .Hurt:        return synth_hurt()
    case .Slime_Hop:   return synth_boing()
    case .Slime_Hit:   return synth_squelch(0.35, 1)
    case .Slime_Pop:   return synth_squelch(0.6, 1.8)
    // Dry knocks of bone: a hard tick ringing hollow, a loose clatter, a collapse.
    // Metal on metal: a hard strike and a long bright ring.
    case .Clang:       return crunch({length = 0.7, attack = 0.001, decay = 0.35, band = {0.15, 0.9}, hiss = 0.25, grains = 300, grain_len = 0.002, thump = 0.4, thump_hz = 220, ring = 1.2, ring_hz = 2600, ring_q = 0.012})
    case .Bone_Hit:    return crunch({length = 0.25, attack = 0.001, decay = 0.07, band = {0.08, 0.6}, hiss = 0.1, grains = 900, grain_len = 0.002, thump = 0.5, thump_hz = 140, ring = 0.6, ring_hz = 1100, ring_q = 0.12})
    case .Bone_Rattle: return crunch({length = 0.5, attack = 0.02, decay = 0.25, band = {0.1, 0.55}, hiss = 0.02, grains = 140, grain_len = 0.003, thump_hz = 60, ring = 0.5, ring_hz = 900, ring_q = 0.15}) // thump_hz: the slide divides by it, even silent
    case .Bone_Break:  return crunch({length = 0.9, attack = 0.002, decay = 0.4, band = {0.05, 0.55}, hiss = 0.1, grains = 700, grain_len = 0.003, thump = 0.7, thump_hz = 90, ring = 0.4, ring_hz = 800, ring_q = 0.18})
    case .Magic_Channel: return synth_shimmer()
    case .Magic_Break:   return synth_unweave()
    case .Magic_Place:   return synth_conjure()
    case .Pickup:        return synth_pickup()
    case .Spell_Crack:   return synth_snap()
    case .Tree_Creak:    return synth_creak()
    // A tree hitting the ground: a deep thud, branches cracking, leaves thrashing.
    case .Tree_Fall:     return crunch({length = 1.8, attack = 0.004, decay = 0.9, band = {0.02, 0.6}, hiss = 0.5, grains = 2600, grain_len = 0.004, thump = 1.3, thump_hz = 38, ring = 0.5, ring_hz = 240, ring_q = 0.08})
    }
    return new_buf(0.01)
}

// Most physical sounds here are noise in a band, a scatter of tiny grains (crunch,
// crackle, rustle), sometimes a resonance the grains ring, and a low knock.
@(private="file")
Crunch :: struct {
    length:        f32,
    attack, decay: f32,    // the whole sound's envelope
    band:          [2]f32, // one-pole low-pass coefficients; the noise between them
    hiss:          f32,    // steady noise under the grains
    grains:        f32,    // grains per second (at full envelope)
    grain_len:     f32,    // seconds for a grain to die away
    thump, thump_hz:       f32, // the impact: a low sine knock
    ring, ring_hz, ring_q: f32, // a resonance (stone tick, hollow wood, ice ping)
}

@(private="file")
crunch :: proc(c: Crunch) -> []f32 {
    buf := new_buf(c.length)
    lo, hi, g, phase, b, l: f32
    gdecay := math.exp(-1 / (c.grain_len * SAMPLE_RATE))
    ring_f := 2 * math.sin(math.PI * c.ring_hz * rand.float32_range(0.9, 1.1) / SAMPLE_RATE)
    thump_hz := c.thump_hz * rand.float32_range(0.9, 1.1)
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        e := env(t, c.attack, c.decay)
        n := white()
        lo += (n - lo) * c.band[0]
        hi += (n - hi) * c.band[1]
        if rand.float32() < c.grains / SAMPLE_RATE * e { g = rand.float32_range(0.3, 1) }
        g *= gdecay
        x := (hi - lo) * (c.hiss + g)
        l += ring_f * b
        b += ring_f * (x - l - c.ring_q * b)
        phase = fract(phase + slide(t, thump_hz * 1.6, thump_hz, 0.03) / SAMPLE_RATE)
        out = x * e + b * c.ring * e * 0.3 + math.sin(phase * math.TAU) * env(t, 0.002, 0.07) * c.thump
    }
    return buf
}

// A block set down: a dull, short thunk and a click.
@(private="file")
synth_place :: proc() -> []f32 {
    buf := new_buf(0.2)
    phase, lp: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        lp += (n - lp) * 0.3
        out = osc(&phase, slide(t, 180, 70, 0.06)) * env(t, 0.001, 0.12) + lp * env(t, 0.0005, 0.015) * 0.6
    }
    return buf
}

// A torch catching: a rising whoosh of flame, a soft fwoomp, then crackles.
@(private="file")
synth_torch :: proc() -> []f32 {
    buf := new_buf(0.8)
    lo, hi, pop, phase: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        open := 0.04 + 0.4 * math.smoothstep(f32(0), 0.25, t) * math.exp(-max(t - 0.25, 0) * 3)
        hi += (n - hi) * open
        lo += (n - lo) * 0.01
        if t > 0.1 && rand.float32() < 25.0 / SAMPLE_RATE { pop = rand.float32_range(0.3, 1) }
        pop *= 0.993
        out = (hi - lo) * env(t, 0.08, 0.5) + (n - hi) * pop * 0.5 + osc(&phase, 90) * env(t, 0.03, 0.2) * 0.4
    }
    return buf
}

// Landing: a heavy, low thud with a puff of dust.
@(private="file")
synth_land :: proc() -> []f32 {
    buf := new_buf(0.35)
    phase, lp: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        lp += (white() - lp) * 0.06
        out = osc(&phase, slide(t, 95, 42, 0.08)) * env(t, 0.002, 0.2) + lp * env(t, 0.002, 0.1) * 2
    }
    return buf
}

// Little rising sine blips: bubbles.
@(private="file")
add_bubbles :: proc(buf: []f32, count: int, from, to, amp: f32) {
    for _ in 0 ..< count {
        start := int(rand.float32_range(from, to) * SAMPLE_RATE)
        f0 := rand.float32_range(350, 1100)
        dur := rand.float32_range(0.02, 0.06)
        a := amp * rand.float32_range(0.3, 1)
        phase: f32
        for j in 0 ..< int(dur * SAMPLE_RATE) {
            if start + j >= len(buf) { break }
            lt := f32(j) / SAMPLE_RATE
            phase = fract(phase + f0 * (1 + 1.5 * lt / dur) / SAMPLE_RATE)
            buf[start + j] += math.sin(phase * math.TAU) * a * math.sin(math.PI * lt / dur)
        }
    }
}

// Hitting water: a broad burst, spray hissing off, then bubbles.
@(private="file")
synth_splash :: proc(length, burst, spray: f32, bubbles: int) -> []f32 {
    buf := new_buf(length)
    lo, hi, top: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        lo += (n - lo) * 0.02
        hi += (n - hi) * 0.6
        top += (n - top) * 0.3
        out = (hi - lo) * env(t, 0.004, burst) + (n - top) * env(t, 0.01, spray) * 0.5
    }
    add_bubbles(buf, bubbles, 0.05, length * 0.8, 0.35)
    return buf
}

// Cloth catching air: band-passed noise chopped by a flapping rate that slides
// (fast to slow as the wing opens), with a fwump at the end as it fills.
@(private="file")
synth_flutter :: proc(length, f_from, f_to, decay, fwump: f32) -> []f32 {
    buf := new_buf(length)
    lo, hi, flap, phase: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        lo += (n - lo) * 0.03
        hi += (n - hi) * 0.4
        flap = fract(flap + slide(t, f_from, f_to, length * 0.8) / SAMPLE_RATE)
        am := 0.3 + 0.7 * abs(math.sin(flap * math.PI))
        out = (hi - lo) * am * env(t, 0.01, decay)
        if fwump > 0 {
            lt := t - length * 0.45
            if lt > 0 { out += osc(&phase, slide(lt, 110, 55, 0.08)) * env(lt, 0.003, 0.15) * fwump * 0.5 }
        }
    }
    return buf
}

// Hitting a wall on the glider: a hard thud, crumbling, and the wing crumpling.
@(private="file")
synth_crash :: proc() -> []f32 {
    buf := new_buf(0.8)
    dirt := crunch({length = 0.5, attack = 0.002, decay = 0.35, band = {0.02, 0.4}, hiss = 0.5, grains = 1500, grain_len = 0.005, thump = 1, thump_hz = 50})
    defer delete(dirt)
    cloth := synth_flutter(0.6, 30, 8, 0.4, 0)
    defer delete(cloth)
    normalize(dirt)
    normalize(cloth)
    for s, i in dirt { buf[i] += s }
    for s, i in cloth {
        if i + 2000 < len(buf) { buf[i + 2000] += s * 0.5 }
    }
    return buf
}

// Ice shattering: a crack and a shower of high glassy pings.
@(private="file")
synth_shatter :: proc() -> []f32 {
    buf := crunch({length = 0.5, attack = 0.001, decay = 0.08, band = {0.2, 0.8}, hiss = 0.6, grains = 600, grain_len = 0.002, thump = 0.4, thump_hz = 100})
    normalize(buf, 0.5)
    for _ in 0 ..< 14 {
        start := int(rand.float32_range(0, 0.25) * SAMPLE_RATE)
        f := rand.float32_range(2500, 6500)
        a := rand.float32_range(0.1, 0.3)
        for j in 0 ..< len(buf) - start {
            lt := f32(j) / SAMPLE_RATE
            buf[start + j] += math.sin(lt * f * math.TAU) * a * math.exp(-lt * 30)
        }
    }
    return buf
}

// An eagle's scream: a quick rise, then a long, rough "keee-arr" sliding down.
@(private="file")
synth_eagle :: proc() -> []f32 {
    LENGTH :: 1.25
    buf := new_buf(LENGTH)
    phase: f32
    top := rand.float32_range(2600, 3200)
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        x := t / LENGTH
        pitch := x < 0.08 ? math.lerp(top * 0.7, top, x / 0.08) : slide(t - 0.08 * LENGTH, top, top * 0.62, LENGTH * 0.9)
        pitch *= 1 + 0.015 * math.sin(t * 9 * math.TAU)
        phase = fract(phase + pitch / SAMPLE_RATE)
        p := phase * math.TAU
        voice := math.sin(p) + 0.45 * math.sin(2 * p) + 0.2 * math.sin(3 * p)
        rough := 0.65 + 0.35 * math.sin(t * 72 * math.TAU)
        amp := min(t / 0.04, 1) * (x < 0.7 ? 1 : (1 - x) / 0.3)
        out = (voice * rough + white() * 0.25) * amp * amp
    }
    return buf
}

// A fox's two quick yips: buzzy, falling, through a nasal formant.
@(private="file")
synth_fox :: proc() -> []f32 {
    buf := new_buf(0.45)
    gap := rand.float32_range(0.17, 0.23)
    top := rand.float32_range(1000, 1250)
    phase, b, l: f32
    f := 2 * math.sin(f32(math.PI * 1400.0 / SAMPLE_RATE))
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        lt := t < gap ? t : t - gap
        if lt > 0.13 { out = 0; continue }
        phase = fract(phase + slide(lt, top, top * 0.55, 0.13) / SAMPLE_RATE)
        voice := phase * 2 - 1
        l += f * b
        b += f * (voice - l - 0.25 * b)
        out = (b + voice * 0.3) * math.sin(math.PI * lt / 0.13)
    }
    return buf
}

// A drop of water: a plink rising fast, and a faint tick.
@(private="file")
synth_drip :: proc() -> []f32 {
    buf := new_buf(0.25)
    phase, lp: f32
    f0 := rand.float32_range(900, 1400)
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        lp += (n - lp) * 0.5
        out = osc(&phase, slide(t, f0, f0 * 2.4, 0.03)) * env(t, 0.001, 0.07) + (n - lp) * env(t, 0.0003, 0.004) * 0.3
    }
    return buf
}

// A bird's note: a sine gliding between two pitches, with a fast warble on it.
@(private="file")
note :: proc(buf: []f32, start, length, f0, f1, wobble, amp: f32) {
    phase: f32
    rate := rand.float32_range(25, 40)
    i0 := int(start * SAMPLE_RATE)
    for j in 0 ..< int(length * SAMPLE_RATE) {
        if i0 + j >= len(buf) { break }
        lt := f32(j) / SAMPLE_RATE
        f := slide(lt, f0, f1, length) + wobble * math.sin(lt * rate * math.TAU)
        phase = fract(phase + f / SAMPLE_RATE)
        buf[i0 + j] += math.sin(phase * math.TAU) * math.sin(math.PI * lt / length) * amp
    }
}

// Drawing the sword: a scrape off the scabbard ringing out into a bright shing.
@(private="file")
synth_draw :: proc() -> []f32 {
    buf := crunch({length = 0.6, attack = 0.06, decay = 0.4, band = {0.3, 0.9}, hiss = 0.4, grains = 900, grain_len = 0.001, thump = 0, thump_hz = 100, ring = 0.6, ring_hz = 3200, ring_q = 0.01})
    normalize(buf, 0.6)
    for f in ([3]f32{2650, 4180, 5900}) {
        p: f32
        for &s, i in buf {
            t := f32(i) / SAMPLE_RATE
            s += osc(&p, f * rand.float32_range(0.995, 1.005)) * env(t - 0.08, 0.005, 0.45) * 0.13
        }
    }
    return buf
}

// Air torn by a blade: noise through a band that sweeps up then down.
@(private="file")
synth_whoosh :: proc(length, attack, bright: f32) -> []f32 {
    buf := new_buf(length)
    lo, hi: f32
    for &s, i in buf {
        t := f32(i) / SAMPLE_RATE
        k := math.sin(math.PI * clamp(t / length, 0, 1))
        n := white()
        lo += (n - lo) * (0.01 + 0.05 * k * bright)
        hi += (n - hi) * (0.04 + 0.3 * k * bright)
        s = (hi - lo) * env(t, attack, length * 0.7)
    }
    return buf
}

// A wet slap into jelly: a low knock, a squelch, and a bloop sliding down.
@(private="file")
synth_squelch :: proc(length, size: f32) -> []f32 {
    buf := crunch({length = length, attack = 0.002, decay = length * 0.6, band = {0.02, 0.25}, hiss = 0.3, grains = 1400 * size, grain_len = 0.004, thump = 1, thump_hz = 70 / size})
    normalize(buf, 0.7)
    p: f32
    f0 := rand.float32_range(380, 460) / size
    for &s, i in buf {
        t := f32(i) / SAMPLE_RATE
        s += osc(&p, slide(t, f0, f0 * 0.45, 0.12) + 30 * math.sin(t * 140)) * env(t, 0.004, 0.16 * size) * 0.5
    }
    return buf
}

// A slime's hop: a soft boing rising, with a damp pat.
@(private="file")
synth_boing :: proc() -> []f32 {
    buf := crunch({length = 0.3, attack = 0.002, decay = 0.08, band = {0.03, 0.2}, hiss = 0.4, grains = 600, grain_len = 0.003, thump = 0.6, thump_hz = 90})
    normalize(buf, 0.4)
    p: f32
    f0 := rand.float32_range(170, 210)
    for &s, i in buf {
        t := f32(i) / SAMPLE_RATE
        s += osc(&p, slide(t, f0, f0 * 1.9, 0.18) + 18 * math.sin(t * 90)) * env(t, 0.006, 0.22) * 0.6
    }
    return buf
}

// Getting hit: a dull body thump and a short breathy grunt.
@(private="file")
synth_hurt :: proc() -> []f32 {
    buf := crunch({length = 0.4, attack = 0.001, decay = 0.2, band = {0.01, 0.12}, hiss = 0.5, grains = 300, grain_len = 0.004, thump = 1, thump_hz = 60})
    normalize(buf, 0.7)
    p, lp: f32
    for &s, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        lp += (n - lp) * 0.2
        voice := osc(&p, slide(t, 160, 110, 0.2))
        voice = voice * 0.6 + math.sign(voice) * 0.25 + lp * 0.4 // a little buzz and breath
        s += voice * env(t - 0.02, 0.02, 0.2) * 0.35
    }
    return buf
}

// A run of quick, wandering notes.
@(private="file")
synth_warble :: proc() -> []f32 {
    buf := new_buf(0.9)
    t: f32
    base := rand.float32_range(2600, 3800)
    for _ in 0 ..< 6 + rand.int_max(4) {
        length := rand.float32_range(0.05, 0.09)
        f := base * rand.float32_range(0.85, 1.35)
        note(buf, t, length, f, f * rand.float32_range(0.85, 1.2), 300, rand.float32_range(0.5, 1))
        t += length + rand.float32_range(0.01, 0.03)
    }
    return buf
}

// "Tee-oo": a high whistle, then one sliding down.
@(private="file")
synth_whistle :: proc() -> []f32 {
    buf := new_buf(0.5)
    f := rand.float32_range(3800, 4600)
    note(buf, 0, 0.16, f, f * 1.04, 20, 1)
    note(buf, 0.21, 0.22, f * 0.85, f * 0.65, 20, 0.9)
    return buf
}

// A trill: fast falling chirps, swelling and fading.
@(private="file")
synth_trill :: proc() -> []f32 {
    length := rand.float32_range(0.5, 0.9)
    buf := new_buf(length + 0.05)
    rate := rand.float32_range(18, 28)
    f := rand.float32_range(4000, 5500)
    for k in 0 ..< int(length * rate) {
        start := f32(k) / rate
        note(buf, start, 0.6 / rate, f * 1.2, f * 0.9, 0, math.sin(math.PI * start / length))
    }
    return buf
}

// "Chick-a-dee-dee": two short high notes and a few buzzy lower ones.
@(private="file")
synth_chatter :: proc() -> []f32 {
    buf := new_buf(0.75)
    f := rand.float32_range(3400, 4000)
    note(buf, 0, 0.05, f, f * 0.85, 0, 1)
    note(buf, 0.08, 0.05, f * 0.9, f * 0.75, 0, 0.9)
    tmp := new_buf(0.75)
    defer delete(tmp)
    for k in 0 ..< 2 + rand.int_max(2) {
        note(tmp, 0.18 + f32(k) * 0.16, 0.12, f * 0.6, f * 0.58, 30, 0.7)
    }
    for s, i in tmp { buf[i] += s * (0.6 + 0.4 * math.sin(f32(i) / SAMPLE_RATE * 120 * math.TAU)) }
    return buf
}

@(private="file")
synth_click :: proc() -> []f32 {
    buf := new_buf(0.03)
    phase: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        out = (osc(&phase, 1500) > 0 ? f32(1) : -1) * env(t, 0.001, 0.02) * 0.5
    }
    return buf
}

// --- Export ---

// `odin run . -- sounds [dir]`: writes every one-shot and 10 s of each loop (at full
// drive) as WAV files to listen to, and prints their levels. Opens no audio device.
audio_export :: proc(dir: string) {
    generate_sounds()
    _ = os.make_directory_all(dir)
    for sound in Sound {
        for v in 0 ..< VARIANTS {
            write_wav(fmt.tprintf("%s/%v_%d.wav", dir, sound, v), audio.sounds[sound][v], 1)
        }
    }
    // How a few of them sound in a cave and under water.
    for sound in ([3]Sound{.Step_Stone, .Drip, .Dig_Stone}) {
        src := audio.sounds[sound][0]
        buf := make([]f32, len(src) + int(ECHO_TAIL * SAMPLE_RATE))
        defer delete(buf)
        copy(buf, src)
        add_echo(buf, 1)
        write_wav(fmt.tprintf("%s/cave_%v.wav", dir, sound), buf, 1)
        muffle(buf[:len(src)], 1)
        write_wav(fmt.tprintf("%s/underwater_%v.wav", dir, sound), buf[:len(src)], 1)
    }
    audio.wind, audio.wind_bright, audio.rush, audio.flutter = 1, 0.5, 1, 0
    audio.crickets, audio.cicadas = 1, 1
    audio.spell.on, audio.spell.frac, audio.spell.low, audio.spell.grit = 1, 0.8, 1, 0.6
    for kind in Loop_Kind {
        l: Loop
        buf := make([]f32, 10 * SAMPLE_RATE * 2)
        defer delete(buf)
        for i in 0 ..< len(buf) / 2 {
            s := loop_sample(&l, kind)
            buf[2 * i], buf[2 * i + 1] = s[0], s[1]
            l.t += 1.0 / SAMPLE_RATE
        }
        sum, peak: f32
        for s in buf {
            sum += s * s
            peak = max(peak, abs(s))
        }
        fmt.printf("loop %-10v rms %.3f peak %.3f\n", kind, math.sqrt(sum / f32(len(buf))), peak)
        write_wav(fmt.tprintf("%s/loop_%v.wav", dir, kind), buf, 2)
    }
    spell_demo(fmt.tprintf("%s/demo_spell.wav", dir))
    fmt.println("wrote", dir)
}

// Stone unweaved as in the game, to listen to it all together: the Spell
// loop climbing with the cracks (magic_update), the break, then the motes
// coming home up their scale (mote_arrive). Mono, at the game's volumes.
@(private="file")
spell_demo :: proc(path: string) {
    NEED :: 0.8 // stone's unweave_time
    buf := new_buf(2.6)
    defer delete(buf)
    mix :: proc(buf: []f32, sound: Sound, at, vol, pitch: f32) {
        src := audio.sounds[sound][rand.int_max(VARIANTS)]
        i0 := int(at * SAMPLE_RATE)
        for j in 0 ..< len(buf) - i0 {
            x := f32(j) * pitch
            k := int(x)
            if k + 1 >= len(src) { break }
            buf[i0 + j] += math.lerp(src[k], src[k + 1], x - f32(k)) * vol
        }
    }
    l: Loop
    audio.spell = {low = 1, grit = clamp((NEED - 0.15) / 1.0, 0, 1)}
    for &s, i in buf {
        t := f32(i) / SAMPLE_RATE
        audio.spell.on = t > 0.1 && t < 0.1 + NEED ? 1 : 0
        audio.spell.frac = clamp((t - 0.1) / NEED, 0, 1)
        v := loop_sample(&l, .Spell)
        s += (v[0] + v[1]) * 0.5 * 0.5
    }
    for t := f32(0.25); t < 0.1 + NEED; {
        frac := (t - 0.1) / NEED
        mix(buf, .Step_Stone, t, 0.1 + 0.25 * frac, 1 + 0.2 * frac)
        t += math.lerp(f32(0.3), 0.11, frac)
    }
    for st in 1 ..= CRACK_STAGES { // the cracks opening (spell_crack_open)
        t := 0.1 + NEED * f32(st) / (CRACK_STAGES + 1)
        k := f32(st) / CRACK_STAGES
        mix(buf, .Spell_Crack, t, 0.3 + 0.35 * k, 1.1 - 0.25 * k)
        mix(buf, .Dig_Stone, t, 0.15 + 0.25 * k, 1.25 - 0.2 * k)
    }
    mix(buf, .Dig_Stone, 0.1 + NEED, 0.55, 1)
    mix(buf, .Magic_Break, 0.1 + NEED, 0.5, 1)
    SCALE :: [8]f32{0, 2, 4, 7, 9, 12, 14, 16}
    scale := SCALE
    for k in 0 ..< 6 { mix(buf, .Pickup, 1.45 + f32(k) * 0.09, 0.24, math.pow(2, scale[k] / 12)) }
    write_wav(path, buf, 1)
}

@(private="file")
write_wav :: proc(path: string, samples: []f32, channels: int) {
    data := make([dynamic]u8, 0, 44 + len(samples) * 2, context.temp_allocator)
    put32 :: proc(d: ^[dynamic]u8, v: u32) { append(d, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }
    put16 :: proc(d: ^[dynamic]u8, v: u16) { append(d, u8(v), u8(v >> 8)) }
    size := u32(len(samples) * 2)
    append(&data, "RIFF")
    put32(&data, 36 + size)
    append(&data, "WAVEfmt ")
    put32(&data, 16)
    put16(&data, 1)
    put16(&data, u16(channels))
    put32(&data, SAMPLE_RATE)
    put32(&data, u32(SAMPLE_RATE * channels * 2))
    put16(&data, u16(channels * 2))
    put16(&data, 16)
    append(&data, "data")
    put32(&data, size)
    for s in samples { put16(&data, u16(i16(clamp(s, -1, 1) * 32767))) }
    if err := os.write_entire_file(path, data[:]); err != nil {
        fmt.eprintln("couldn't write", path, err)
    }
}

// A soft bell: a sine struck at `start`, ringing away over `decay` seconds.
@(private="file")
bell :: proc(buf: []f32, start, f, decay, amp: f32) {
    phase: f32
    i0 := int(start * SAMPLE_RATE)
    for j in 0 ..< len(buf) - i0 {
        t := f32(j) / SAMPLE_RATE
        phase = fract(phase + f / SAMPLE_RATE)
        buf[i0 + j] += math.sin(phase * math.TAU) * env(t, 0.003, decay) * amp
    }
}

// Another's spell at work, retriggered while it lasts (client.odin): the
// Spell loop's voice, swelling in and out so the takes overlap smoothly.
@(private="file")
synth_shimmer :: proc() -> []f32 {
    LENGTH :: 0.5
    buf := new_buf(LENGTH)
    s := Spell_Sound{on = 1, amp = 1, low = 1, grit = 0.4, sweep = rand.float32()} // the climb: its pitch (client.odin)
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        v := spell_voice(&s)
        swell := math.sin(math.PI * t / LENGTH)
        out = (v[0] + v[1]) * 0.5 * swell * swell
    }
    return buf
}

// A block coming undone: the spell's climb resolved. A deep thump and a
// crisp pop, the octave and twelfth of the loop's root ringing out, and a
// scatter of bright sparkles flying off.
@(private="file")
synth_unweave :: proc() -> []f32 {
    buf := new_buf(1.0)
    f := f32(SPELL_BASE_HZ)
    phase, lo, hi: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        lo += (n - lo) * 0.08
        hi += (n - hi) * 0.5
        thump := osc(&phase, slide(t, 120, 48, 0.07)) * env(t, 0.002, 0.2) * 0.9
        pop := (hi - lo) * env(t, 0.0008, 0.035) * 1.2
        out = thump + pop
    }
    bell(buf, 0.006, f * 2, 0.75, 0.38)
    bell(buf, 0.012, f * 3, 0.5, 0.2)
    bell(buf, 0.02, f * 4.01, 0.3, 0.08)
    SPARKS :: [5]f32{5, 6, 8, 10, 12} // overtones of the root: they fit the chord
    sparks := SPARKS
    for _ in 0 ..< 7 {
        bell(buf, rand.float32_range(0.04, 0.32), f * sparks[rand.int_max(len(sparks))] * rand.float32_range(0.997, 1.003), 0.08, rand.float32_range(0.03, 0.07))
    }
    return buf
}

// A block conjured: air drawn in, then a soft fifth over the spell's root
// as it settles (the knock is the Place under it: audio_edit).
@(private="file")
synth_conjure :: proc() -> []f32 {
    buf := new_buf(0.55)
    lo, hi: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        hi += (n - hi) * (0.05 + 0.4 * math.smoothstep(f32(0), 0.05, t))
        lo += (n - lo) * 0.03
        swell := math.smoothstep(f32(0), 0.05, t) * math.exp(-max(t - 0.05, 0) * 40)
        out = (hi - lo) * swell * 0.5
    }
    f := f32(SPELL_BASE_HZ)
    bell(buf, 0.045, f * 1.5, 0.35, 0.3)
    bell(buf, 0.05, f * 2, 0.3, 0.22)
    bell(buf, 0.05, f * 3, 0.15, 0.05)
    return buf
}

// A mote reaching you: a small soft bell (mote_arrive walks a quick run of
// them up a scale).
@(private="file")
synth_pickup :: proc() -> []f32 {
    buf := new_buf(0.4)
    f := f32(SPELL_BASE_HZ * 2) // the spell's octave: they sit in its chord
    bell(buf, 0, f, 0.32, 0.6)
    bell(buf, 0, f * 1.5, 0.14, 0.12)
    bell(buf, 0, f * 2, 0.08, 0.06)
    return buf
}

// A crack opening under the spell: a dry snap, a short splintering
// rattle, and a soft low blow under them. Kept low and dull: no ring.
@(private="file")
synth_snap :: proc() -> []f32 {
    buf := new_buf(0.4)
    phase, lo, hi, g: f32
    for &out, i in buf {
        t := f32(i) / SAMPLE_RATE
        n := white()
        lo += (n - lo) * 0.04
        hi += (n - hi) * 0.35 // nothing much over ~3 kHz
        if t < 0.06 && rand.float32() < 900.0 / SAMPLE_RATE { g = rand.float32_range(0.3, 1) }
        g *= 0.996
        snap := (hi - lo) * (env(t, 0.0005, 0.02) * 1.4 + g * env(t, 0.002, 0.08) * 0.8)
        blow := osc(&phase, slide(t, 95, 50, 0.06)) * env(t, 0.003, 0.22)
        out = snap + blow * 0.8
    }
    return buf
}

// A trunk giving way: a long low groan of wood with cracks through it.
@(private="file")
synth_creak :: proc() -> []f32 {
    buf := crunch({length = 1.3, attack = 0.15, decay = 0.9, band = {0.03, 0.4}, hiss = 0.05, grains = 90, grain_len = 0.006, thump = 0, thump_hz = 100, ring = 1.0, ring_hz = 260, ring_q = 0.05})
    normalize(buf, 0.5)
    p, lp: f32
    f0 := rand.float32_range(70, 90)
    for &s, i in buf {
        t := f32(i) / SAMPLE_RATE
        // A bowed, stuttering tone: a buzz whose pitch sags and jitters.
        f := f0 * (1.25 - 0.3 * t) * (1 + 0.06 * math.sin(t * 23) + 0.03 * white())
        p = fract(p + f / SAMPLE_RATE)
        saw := 2 * p - 1
        lp += (saw - lp) * 0.08
        s += lp * env(t, 0.2, 0.8) * (0.6 + 0.4 * math.sin(t * 37)) * 0.8
    }
    return buf
}
