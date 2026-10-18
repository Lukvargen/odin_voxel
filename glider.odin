package main

import "base:runtime"
import "core:math"
import la "core:math/linalg"
import "core:time"

// Hang glider. G equips it; Space in mid-air opens the wing, Space again
// lets go. In flight the mouse moves an aim point and the pilot flies toward
// it the way a real pilot would — banking to turn and changing the wing's
// angle of attack to climb or dive — while lift, drag and gravity do the rest.
// So speed and height trade against each other: dive to go fast, pull up to
// bleed speed into height, fly too slow and the wing mushes and sinks.
// Ctrl holds the aim still and lets the mouse look around; the view eases
// back onto the aim when Ctrl is released.
//
// Air: a slowly turning wind, thermals (columns of rising air off the
// hottest ground, with sinking air around their edge, strong by day and gone
// at night) and ridge lift where the wind blows up a slope. Units are voxels
// ~ metres, seconds.

GLIDER_GRAVITY   : f32 = f32(16.0)  // lighter than walking (36) so flight is floaty
GLIDER_LIFT_K    : f32 = f32(0.14)  // 1/2 rho S / m, folded into one constant
GLIDER_CL_SLOPE  :: f32(5.5)   // lift per radian of angle of attack
GLIDER_CD0       :: f32(0.035) // parasitic drag
GLIDER_CD_INDUCED :: f32(0.11) // induced drag factor (Cd += k Cl^2); best glide ~8:1 at ~14 m/s
GLIDER_STALL_AOA :: f32(0.245) // ~14 degrees
GLIDER_MAX_AOA   :: f32(0.21)  // what the pilot will pull to without flaring
GLIDER_FLARE_AOA :: f32(0.45)  // S: flare/brake, deliberately past the stall
GLIDER_MIN_AOA   :: f32(-0.07)
GLIDER_BAR_AOA   :: f32(0.07)  // W, the bar pulled in all the way: no slower than ~26 m/s
GLIDER_BAR_SPEED :: f32(26)    // what the pilot dives for on the bar (trim is ~15), sinking faster
BAR_VIEW_DIP     :: f32(5)     // degrees the view tips down with the bar all the way in
GLIDER_MAX_G     :: f32(3.5)   // pilot won't pull more than this many g (in glider gravity)
GLIDER_MAX_BANK  :: f32(1.10)  // ~63 degrees
GLIDER_SUBSTEP   :: f32(1.0 / 240.0)
GLIDER_CRASH_SPEED : f32 = f32(14.0) // wall hit faster than this throws you off the glider

THERMAL_CELL  :: 168 // one possible thermal per CELL x CELL voxels (112 design)
WINGTIP_REACH :: f32(8) // where the wing feels a thermal, each side (wider than the wing: a usable cue)

Glider :: struct {
    equipped:  bool,
    deployed:  bool,
    deploy_t:  f32,  // 0 folded .. 1 fully open (wing unfold animation)

    aim_yaw, aim_pitch:   f32, // degrees, same convention as Camera.yaw/pitch
    look_yaw, look_pitch: f32, // Ctrl free-look offset from the aim (degrees)
    look_armed:           bool, // Ctrl let go since the wing opened (a sprint's Ctrl isn't a look)

    bank, bank_vel: f32, // radians, positive = left wing down (turning left)
    bar:            f32, // 0..1, how far the speed bar (W) is pulled in: eased, so the nose doesn't drop all at once
    turn_rate:      f32, // degrees/s, smoothed (damps the bank autopilot)
    aoa, aoa_vel:   f32, // angle of attack, radians
    heading:        f32, // degrees, direction of travel through the air
    path_angle:     f32, // radians, climb (+) / dive (-) angle of the air path

    third_person: bool,
    chase_dist:   f32, // smoothed chase-camera distance

    // For the HUD.
    airspeed:  f32,
    vario:     f32, // smoothed vertical speed
    agl:       f32, // height above whatever is below
    lift_here: f32, // updraft at the pilot (thermal + ridge)
    lift_side: f32, // thermal lift under the left wingtip less the right's, smoothed
    heat:      f32, // 0..1, how hard the sun drives the thermals now (0 at night)
    stall:     f32, // 0..1, how far past the stall

    // The thermals around the pilot (near_thermals_update), for the lift.
    near:      [MAX_NEAR_THERMALS]Near_Thermal,
    near_n:    int,
    near_cell: [2]int,
    near_ok:   bool,

    // Feel.
    shake:      f32, // buffet / turbulence amplitude, decays
    shake_time: f32,
    land_dip:   f32, // camera drops then springs back on touchdown
    kick, kick_vel: f32, // the seat's jolt flying into rising (up) or sinking air, springing back
    lift_prev:  f32,
    wind_time:  f32,
}

// ─── Air ───────────────────────────────────────────────────────────────────

glider_wind :: proc(t: f32) -> [3]f32 {
    // A breeze that slowly wanders in direction and strength.
    dir := 0.6 + 0.9 * math.sin(t * 0.013) + 0.3 * math.sin(t * 0.041)
    spd := 3.0 + 1.5 * math.sin(t * 0.027 + 1.3)
    return {math.cos(dir) * spd, 0, math.sin(dir) * spd}
}

@(private="file")
thermal_hash :: proc(x, z: int, salt: u32) -> f32 {
    h := u32(x) * 0x8da6b343 ~ u32(z) * 0xd8163841 ~ salt * 0xcb1ab31f
    h ~= h >> 13; h *= 0x5bd1e995; h ~= h >> 15
    return f32(h & 0xffffff) / f32(0x1000000)
}

Thermal :: struct {
    centre:   [2]f32, // at ground level; the column leans downwind with height
    radius:   f32,
    strength: f32,    // m/s of updraft in the core
    top:      f32,    // height above ground where it fades out
}

THERMAL_STRONG :: 4.5 * TERRAIN_SCALE // m/s: a cumulus over it, eagles in it

// The thermal of grid cell (gx, gz), if it has one: off the hottest ground
// in the cell, as a pilot would read the land. Worked out once per cell
// (it samples the terrain) and kept.
thermal_cell :: proc(gx, gz: int) -> (Thermal, bool) {
    key := [2]int{gx, gz}
    if c, hit := thermal_cache[key]; hit { return c.th, c.ok }
    if thermal_cache == nil { thermal_cache = make(map[[2]int]Cached_Thermal, 1024, runtime.heap_allocator()) }
    if len(thermal_cache) > 8192 { clear(&thermal_cache) }
    th, ok := thermal_from_terrain(gx, gz)
    thermal_cache[key] = {th, ok}
    return th, ok
}

@(private="file")
Cached_Thermal :: struct { th: Thermal, ok: bool }
@(private="file")
thermal_cache: map[[2]int]Cached_Thermal

// How well the ground heats in the sun: bare and dry best, forest and snow
// little, water not at all.
@(private="file")
ground_heat :: proc(t: Terrain_Sample) -> f32 {
    if t.height <= SEA_LEVEL { return 0 }
    switch t.biome {
    case .Ocean, .River: return 0
    case .Desert, .Badlands: return 1
    case .Savanna:   return 0.9
    case .Mountains: return 0.8
    case .Plains:    return 0.75
    case .Beach:     return 0.55
    case .Forest:    return 0.45
    case .Taiga:     return 0.4
    case .Peaks:     return 0.35
    case .Snowy:     return 0.3
    }
    return 0.5
}

// A 5 x 5 grid of terrain over the cell; each inner point scored by its
// ground (ground_heat), how square it faces the midday sun (south slopes
// bake, north ones stay cool) and how it stands above its neighbours (hot
// air breaks away off rises and crests). The best one, with some luck,
// makes a thermal if it's hot enough, stronger and taller the hotter.
@(private="file")
thermal_from_terrain :: proc(gx, gz: int) -> (th: Thermal, ok: bool) {
    N :: 5
    step := f32(THERMAL_CELL) * 0.8 / (N - 1)
    pos :: proc(gx, gz, i, j: int, step: f32) -> [2]f32 {
        return {f32(gx) * THERMAL_CELL + THERMAL_CELL * 0.1 + f32(i) * step, f32(gz) * THERMAL_CELL + THERMAL_CELL * 0.1 + f32(j) * step}
    }
    h, heat: [N][N]f32
    for j in 0 ..< N {
        for i in 0 ..< N {
            p := pos(gx, gz, i, j, step)
            t := terrain_at(int(p.x), int(p.y))
            h[j][i], heat[j][i] = f32(t.height), ground_heat(t)
        }
    }
    noon := sun_dir_at(12)
    best: f32 = 0
    bi, bj := 0, 0
    for j in 1 ..< N - 1 {
        for i in 1 ..< N - 1 {
            if heat[j][i] <= 0 { continue }
            slope := [2]f32{(h[j][i + 1] - h[j][i - 1]) / (2 * step), (h[j + 1][i] - h[j - 1][i]) / (2 * step)}
            n := la.normalize([3]f32{-slope.x, 1, -slope.y})
            sun := clamp(la.dot(n, noon) / noon.y, 0.4, 1.3)
            around: f32 = 0
            for dj in -1 ..= 1 { for di in -1 ..= 1 { around += h[j + dj][i + di] } }
            rise := h[j][i] - (around - h[j][i]) / 8
            trigger := 1 + 0.6 * clamp(rise / (20 * TERRAIN_SCALE), -0.5, 1)
            if score := heat[j][i] * sun * trigger; score > best { best, bi, bj = score, i, j }
        }
    }
    s := best * (0.5 + thermal_hash(gx, gz, 1))
    if s < 0.62 { return }
    hot := clamp((s - 0.62) / 0.6, 0, 1)
    jitter := [2]f32{thermal_hash(gx, gz, 2) - 0.5, thermal_hash(gx, gz, 3) - 0.5} * step * 0.6
    th.centre   = pos(gx, gz, bi, bj, step) + jitter
    th.radius   = (12 + 16 * thermal_hash(gx, gz, 4)) * TERRAIN_SCALE
    th.strength = (2.5 + 5 * hot) * TERRAIN_SCALE
    th.top      = (80 + 120 * hot) * TERRAIN_SCALE * (0.85 + 0.3 * thermal_hash(gx, gz, 6))
    return th, true
}

// How hard the sun drives the thermals: full from mid-morning, fading as it
// sinks, none at night.
thermal_heat :: proc(d: Day_Clock) -> f32 {
    return math.smoothstep(f32(0), 0.35, day_sun(d).y)
}

// Cumulus clouds mark strong thermals (the same ones the eagles circle).
CUMULUS_BASE     :: f32(348) // cloud base height (240 design): the highest peaks rise through
MAX_SKY_THERMALS :: 16

Sky_Thermal :: struct {
    centre:   [2]f32,
    ground:   f32,
    cloud_r:  f32,
    strength: f32,
    puffs:    [4][4]f32, // cumulus towers: offset from the base centre (in cloud radii), radius
}

// Strong thermals within two cells of the camera; recomputed only when the
// camera enters another thermal cell (it samples the terrain height).
sky_thermals_update :: proc(gs: ^Game_State) {
    p := gs.camera.pos
    cell := [2]int{int(math.floor(p.x / THERMAL_CELL)), int(math.floor(p.z / THERMAL_CELL))}
    if gs.sky_thermals_ok && cell == gs.sky_thermal_cell { return }
    gs.sky_thermal_cell, gs.sky_thermals_ok = cell, true
    gs.sky_thermal_count = 0
    for dz in -2 ..= 2 {
        for dx in -2 ..= 2 {
            th := thermal_cell(cell.x + dx, cell.y + dz) or_continue
            if th.strength < THERMAL_STRONG || gs.sky_thermal_count >= MAX_SKY_THERMALS { continue }
            ground := max(f32(surface_height_at(int(th.centre.x), int(th.centre.y))), SEA_LEVEL)
            st := Sky_Thermal{
                centre   = th.centre,
                ground   = ground,
                cloud_r  = 26 * TERRAIN_SCALE + th.radius * 1.2 + th.strength * 4,
                strength = th.strength,
            }
            // Cauliflower towers on top of the base, taller for stronger lift.
            gx, gz := cell.x + dx, cell.y + dz
            for k in 0 ..< 4 {
                h := proc(gx, gz, k, j: int) -> f32 { return thermal_hash(gx, gz, u32(20 + k * 4 + j)) }
                rise := 0.35 + 0.55 * h(gx, gz, k, 1) * (th.strength / (7.5 * TERRAIN_SCALE))
                st.puffs[k] = {(h(gx, gz, k, 0) - 0.5) * 0.9, rise, (h(gx, gz, k, 2) - 0.5) * 0.9, 0.42 + 0.22 * h(gx, gz, k, 3)}
            }
            gs.sky_thermals[gs.sky_thermal_count] = st
            gs.sky_thermal_count += 1
        }
    }
}

// Rising air at p from the thermals near the pilot: a soft-edged core with
// a ring of sinking air around it, the column leaning downwind as it rises
// and weakening toward its top, its height taken from its own ground (a
// thermal off a hilltop doesn't vanish over the valley beside it).
thermal_lift :: proc(g: ^Glider, p: [3]f32, wind: [3]f32) -> f32 {
    lift: f32 = 0
    for t in g.near[:g.near_n] {
        centre, core := thermal_core_at(t, p.y, wind)
        core *= g.heat
        if core <= 0 { continue }
        d := la.length(p.xz - centre) / t.radius
        if d < 1 {
            k := 1 - d * d
            lift += core * k * k
        } else if d < 1.8 {
            s := math.sin((d - 1) / 0.8 * math.PI)
            lift -= 0.9 * TERRAIN_SCALE * s * core / t.strength
        }
    }
    return lift
}

// A thermal and the ground under its foot: where its column is at any height.
Near_Thermal :: struct { using th: Thermal, ground: f32 }
MAX_NEAR_THERMALS :: 49 // the 7 x 7 cells around the pilot
NEAR_CELLS        :: 3

// The thermals of the cells around the pilot, with their ground; redone on
// entering another cell.
near_thermals_update :: proc(gs: ^Game_State) {
    g := &gs.glider
    p := gs.camera.pos
    cell := [2]int{int(math.floor(p.x / THERMAL_CELL)), int(math.floor(p.z / THERMAL_CELL))}
    if g.near_ok && cell == g.near_cell { return }
    g.near_cell, g.near_ok, g.near_n = cell, true, 0
    for dz in -NEAR_CELLS ..= NEAR_CELLS {
        for dx in -NEAR_CELLS ..= NEAR_CELLS {
            th := thermal_cell(cell.x + dx, cell.y + dz) or_continue
            ground := max(f32(surface_height_at(int(th.centre.x), int(th.centre.y))), SEA_LEVEL)
            g.near[g.near_n] = {th = th, ground = ground}
            g.near_n += 1
        }
    }
}

// Where a thermal's core is at height y, and how much it lifts there (the
// core's fade with height, as thermal_lift has it, times its strength).
thermal_core_at :: proc(t: Near_Thermal, y: f32, wind: [3]f32) -> (centre: [2]f32, lift: f32) {
    height := y - t.ground
    centre = t.centre + wind.xz * (max(height, 0) * 0.08)
    fade := clamp((t.top - height) / (30 * TERRAIN_SCALE), 0, 1) * clamp(height / (12 * TERRAIN_SCALE), 0, 1)
    return centre, t.strength * fade
}

// Ridge lift: wind blowing into rising ground is pushed upward. Strongest
// close to the slope, gone ~60 voxels above it.
@(private="file")
ridge_lift :: proc(p: [3]f32, wind: [3]f32) -> (lift, ground: f32) {
    ix, iz := int(math.floor(p.x)), int(math.floor(p.z))
    h0 := f32(surface_height_at(ix, iz))
    hx := f32(surface_height_at(ix + 9, iz))
    hz := f32(surface_height_at(ix, iz + 9))
    grad := [2]f32{(hx - h0) / 9, (hz - h0) / 9}
    ground = max(h0, SEA_LEVEL)
    upslope := wind.x * grad.x + wind.z * grad.y
    height := p.y - ground
    if upslope <= 0 || height > 90 { return 0, ground }
    return min(upslope * 1.6, 6) * TERRAIN_SCALE * clamp(1 - height / 90, 0, 1), ground
}

// ─── Aerodynamics ─────────────────────────────────────────────────────────

// Lift coefficient: linear up to the stall, then it falls away.
@(private="file")
lift_coeff :: proc(aoa: f32) -> f32 {
    a := abs(aoa)
    cl: f32
    if a <= GLIDER_STALL_AOA {
        cl = GLIDER_CL_SLOPE * a
    } else {
        peak := GLIDER_CL_SLOPE * GLIDER_STALL_AOA
        over := min((a - GLIDER_STALL_AOA) / 0.2, 1)
        cl = peak * (1 - 0.45 * over)
    }
    return aoa < 0 ? -cl : cl
}

// Body axes from heading (degrees), body pitch and bank (radians).
glider_axes :: proc(heading, pitch, bank: f32) -> (fwd, up: [3]f32) {
    y := math.to_radians(heading)
    fwd = {math.cos(pitch) * math.sin(y), math.sin(pitch), math.cos(pitch) * math.cos(y)}
    left := la.normalize(la.cross([3]f32{0, 1, 0}, fwd))
    up0  := la.cross(fwd, left)
    up = up0 * math.cos(bank) + left * math.sin(bank)
    return
}

@(private="file")
wrap_deg :: proc(a: f32) -> f32 {
    return math.mod(a + 540, 360) - 180
}

// Critically damped spring step (smooth, no overshoot).
@(private="file")
spring :: proc(x, v: ^f32, target, omega, dt: f32) {
    v^ += (omega * omega * (target - x^) - 2 * omega * v^) * dt
    x^ += v^ * dt
}

// ─── Control ───────────────────────────────────────────────────────────────

// The wing opens only in the air (not swimming) and can always be let go.
glider_can_toggle :: proc(gs: ^Game_State) -> bool {
    c := &gs.camera
    if gs.glider.deployed { return true }
    if c.fly_mode || c.on_ground { return false }
    x, y, z := int(math.floor(c.pos.x)), int(math.floor(c.pos.y - PLAYER_EYE_HEIGHT * 0.5)), int(math.floor(c.pos.z))
    return !block_is_watery(u8(get_voxel(gs, x, y, z)))
}

// Space in mid-air with the glider equipped.
glider_toggle_deploy :: proc(gs: ^Game_State) {
    g := &gs.glider
    cam := &gs.camera
    if g.deployed {
        g.deployed = false
        cam.yaw   = g.aim_yaw + g.look_yaw
        cam.pitch = clamp(g.aim_pitch + g.look_pitch, -89, 89)
        return
    }
    g.deployed  = true
    g.deploy_t  = 0
    g.aim_yaw   = cam.yaw
    g.aim_pitch = clamp(cam.pitch, -60, 30)
    g.look_yaw, g.look_pitch = 0, 0
    g.look_armed = false
    g.lift_side = 0
    g.lift_prev = 0
    // Launch where the pilot looks, through the air: whatever way they were
    // drifting (a strafe, the last flight's speed) turns that way, its speed
    // kept, and the wing catching air pushes it up to flying speed so a
    // deploy from a jump doesn't start deep in the stall. Starting off the
    // look, or measured over the ground instead of through the air (the
    // wind), the bank autopilot swerves to correct it.
    wind := glider_wind(g.wind_time)
    flat := camera_flat_forward(cam^)
    s := la.length((cam.velocity - wind).xz)
    if s < 11 { s += (11 - s) * 0.85 }
    cam.velocity.xz = flat.xz * s + wind.xz
    cam.velocity.y = max(cam.velocity.y * 0.5, -6) // the canopy bites
    v := cam.velocity - wind
    g.heading    = math.to_degrees(math.atan2(v.x, v.z))
    g.path_angle = math.asin(clamp(v.y / max(la.length(v), 0.01), -1, 1))
    g.aoa, g.aoa_vel   = 0.1, 0
    g.bank, g.bank_vel = 0, 0
    g.bar = 0
    g.turn_rate = 0
}

@(private="file")
glider_stow :: proc(gs: ^Game_State, landed: bool) {
    g := &gs.glider
    g.deployed = false
    gs.camera.yaw   = g.aim_yaw + g.look_yaw
    gs.camera.pitch = clamp(g.aim_pitch + g.look_pitch, -89, 89)
    if landed { g.land_dip = -clamp(-gs.camera.velocity.y * 0.06, 0.15, 0.7) }
}

// Mouse + keys while flying. mouse_dx is already negated like camera_update.
glider_update :: proc(gs: ^Game_State, mouse_dx, mouse_dy, dt: f32,
                      speed_bar, flare, roll_left, roll_right, free_look: bool) {
    g := &gs.glider
    cam := &gs.camera
    t0 := time.tick_now()
    defer profile_add(.Glider, t0)

    // Ctrl still held from a sprint off the cliff steers, until let go.
    if !free_look { g.look_armed = true }
    if free_look && g.look_armed {
        g.look_yaw   = clamp(g.look_yaw + mouse_dx * 0.1, -170, 170)
        g.look_pitch = clamp(g.look_pitch - mouse_dy * 0.1, -85, 85)
    } else {
        g.aim_yaw   += mouse_dx * 0.1
        g.aim_pitch  = clamp(g.aim_pitch - mouse_dy * 0.1, -80, 75)
        // Ease the view back onto the aim.
        k := 1 - math.exp(-9 * dt)
        g.look_yaw   -= g.look_yaw * k
        g.look_pitch -= g.look_pitch * k
    }
    g.deploy_t = min(g.deploy_t + dt * 2.2, 1)
    g.wind_time += dt

    // Air at the pilot, sampled once per frame.
    wind := glider_wind(g.wind_time)
    g.heat = thermal_heat(gs.day)
    near_thermals_update(gs)
    ridge, ground := ridge_lift(cam.pos, wind)
    g.lift_here = ridge + thermal_lift(g, cam.pos, wind)
    air := wind + [3]f32{0, g.lift_here, 0}
    // A thermal lifts the wingtip nearer its core first: the wing rolls
    // away from the lift (glider_step), and the HUD points to it. Turn
    // toward the lifted wing to centre.
    fwd, _ := glider_axes(g.heading, 0, 0)
    left := [3]f32{fwd.z, 0, -fwd.x} * WINGTIP_REACH
    side := thermal_lift(g, cam.pos + left, wind) - thermal_lift(g, cam.pos - left, wind)
    g.lift_side += (side - g.lift_side) * min(dt * 6, 1)
    // Felt through the seat: air rising faster shoves the pilot up, a sink
    // drops them (glider_view_update springs it back). The jolt's what tells
    // you you've hit a thermal, before the climb does.
    g.kick_vel += clamp(g.lift_here - g.lift_prev, -2, 2) * 0.5
    g.lift_prev = g.lift_here

    steps := clamp(int(math.ceil(dt / GLIDER_SUBSTEP)), 1, 32)
    h := dt / f32(steps)
    for _ in 0 ..< steps {
        if !glider_step(gs, h, air, speed_bar, flare, roll_left, roll_right) { break }
    }

    // ─ Camera: view = aim + free look, plus feel effects. The bar pulled in
    // tips the view nose-down a little, as the whole wing does. ─
    cam.yaw   = g.aim_yaw + g.look_yaw
    cam.pitch = clamp(g.aim_pitch + g.look_pitch - BAR_VIEW_DIP * math.smoothstep(f32(0), 1, g.bar), -89, 89)

    // Variometer and height above ground.
    g.vario += (cam.velocity.y - g.vario) * min(dt * 3, 1)
    if hit, _, ok := raycast_voxel(gs, cam.pos, {0, -1, 0}, 400); ok {
        g.agl = cam.pos.y - PLAYER_EYE_HEIGHT - f32(hit.y + 1)
    } else {
        g.agl = cam.pos.y - PLAYER_EYE_HEIGHT - ground
    }

    // Buffet near the stall, bumps in rising air.
    turb := g.stall * 0.9 + clamp(abs(g.lift_here) / 7, 0, 1) * 0.25
    g.shake += (turb - g.shake) * min(dt * 4, 1)
}

// One physics substep. Returns false once the flight is over (landed/crashed).
@(private="file")
glider_step :: proc(gs: ^Game_State, dt: f32, air: [3]f32,
                    speed_bar, flare, roll_left, roll_right: bool) -> bool {
    g := &gs.glider
    cam := &gs.camera

    v_air := cam.velocity - air
    V := max(la.length(v_air), 0.5)
    dir := v_air / V
    if abs(dir.x) + abs(dir.z) > 0.02 {
        h := math.to_degrees(math.atan2(dir.x, dir.z))
        rate := wrap_deg(h - g.heading) / dt
        g.turn_rate += (rate - g.turn_rate) * min(dt * 20, 1)
        g.heading = h
    }
    g.path_angle = math.asin(clamp(dir.y, -1, 1))

    // Bank toward the aim's heading (plus A/D for a direct lean). Leading
    // the error by the current turn rate rolls out before the aim, not after.
    err := wrap_deg(g.aim_yaw - g.heading) - g.turn_rate * 0.35
    target_bank := clamp(math.to_radians(err) * 1.3, -GLIDER_MAX_BANK, GLIDER_MAX_BANK)
    if roll_left  { target_bank += 0.45 }
    if roll_right { target_bank -= 0.45 }
    // The lifted wing rises (positive lift_side: the left; bank + is left down).
    target_bank -= clamp(g.lift_side * 0.09, -0.3, 0.3)
    target_bank = clamp(target_bank, -GLIDER_MAX_BANK, GLIDER_MAX_BANK)
    spring(&g.bank, &g.bank_vel, target_bank, 4.5, dt)

    // Angle of attack: enough lift to bend the flight path toward the aim's
    // pitch, within what the wing and the pilot can take.
    q := GLIDER_LIFT_K * V * V
    gamma_t := math.to_radians(clamp(g.aim_pitch, -75, 45))
    // The bar pulled in (W, eased in): the pilot dives below the aim until
    // up to bar speed, then holds it, the wing kept flat so it can't slow.
    // (Only flattening the wing drops the nose all at once and plunges.)
    g.bar = clamp(g.bar + (speed_bar ? dt : -dt) / 1.5, 0, 1)
    bar := math.smoothstep(f32(0), 1, g.bar)
    gamma_t -= bar * clamp((GLIDER_BAR_SPEED - V) * 0.04, 0, 0.45)
    gamma_rate := clamp((gamma_t - g.path_angle) * 2.2, -1.2, 1.2)
    want_lift := (GLIDER_GRAVITY * math.cos(g.path_angle) + V * gamma_rate) / max(math.cos(g.bank), 0.45)
    want_lift = clamp(want_lift, -0.5 * GLIDER_GRAVITY, GLIDER_MAX_G * GLIDER_GRAVITY)
    aoa_t := want_lift / (q * GLIDER_CL_SLOPE)
    max_aoa := GLIDER_MAX_AOA
    max_aoa = math.lerp(max_aoa, GLIDER_BAR_AOA, bar)
    aoa_t = clamp(aoa_t, GLIDER_MIN_AOA, max_aoa)
    if flare { aoa_t = GLIDER_FLARE_AOA }
    spring(&g.aoa, &g.aoa_vel, aoa_t, 6, dt)

    // Forces.
    cl := lift_coeff(g.aoa)
    cd := GLIDER_CD0 + GLIDER_CD_INDUCED * cl * cl
    if abs(g.aoa) > GLIDER_STALL_AOA {
        s := math.sin(abs(g.aoa))
        cd += 1.4 * s * s
    }
    if flare { cd += 0.12 } // pilot sits up into the wind
    _, body_up := glider_axes(g.heading, g.path_angle + g.aoa, g.bank)
    lift_dir := body_up - dir * la.dot(body_up, dir)
    if ll := la.length(lift_dir); ll > 1e-4 { lift_dir /= ll }
    unfold := g.deploy_t * g.deploy_t * (3 - 2 * g.deploy_t)
    acc := lift_dir * (q * cl * unfold) - dir * (q * cd * (0.3 + 0.7 * unfold))
    acc.y -= GLIDER_GRAVITY
    cam.velocity += acc * dt

    g.airspeed = V
    g.stall = clamp((abs(g.aoa) - GLIDER_STALL_AOA * 0.92) / 0.12, 0, 1)

    // Move with collision, axis by axis.
    delta := cam.velocity * dt
    pos := cam.pos
    hit: bool
    for axis in 0 ..< 3 {
        step: [3]f32
        step[axis] = delta[axis]
        pos, hit = move_axis(gs, pos, step)
        if !hit { continue }
        if axis == 1 {
            if cam.velocity.y < 0 { // touched down
                cam.pos = pos
                cam.velocity.y = 0
                cam.on_ground = true
                glider_stow(gs, true)
                return false
            }
            cam.velocity.y = 0
            continue
        }
        impact := abs(cam.velocity[axis])
        cam.velocity[axis] = 0
        if impact > GLIDER_CRASH_SPEED {
            cam.pos = pos
            cam.velocity *= 0.3
            g.shake = 2.5
            play(.Crash, 0.9)
            glider_stow(gs, false)
            return false
        }
        cam.velocity *= 0.92 // scraping along a wall
    }
    cam.pos = pos

    // Into water: let go.
    body := [3]int{int(math.floor(pos.x)), int(math.floor(pos.y - PLAYER_EYE_HEIGHT * 0.5)), int(math.floor(pos.z))}
    if block_is_watery(u8(get_voxel(gs, body.x, body.y, body.z))) {
        glider_stow(gs, false)
        return false
    }
    return true
}

// Every frame: view feel (roll, FOV, shake, chase camera), flying or not,
// so everything eases back to normal after landing. The chase camera (V)
// works on foot too (creatures.odin draws the player's body).
glider_view_update :: proc(gs: ^Game_State, dt: f32) {
    g := &gs.glider
    cam := &gs.camera

    target_roll: f32 = 0
    target_fov:  f32 = 1
    if g.deployed {
        target_roll = g.bank * 0.45
        target_fov  = 1 + clamp((g.airspeed - 13) / 22, 0, 1) * 0.28 // trim narrow, the bar's speed clearly wider
    } else if cam.sprinting {
        target_fov = 1.1 // the sprint FOV kick
    }
    cam.roll      += (target_roll - cam.roll) * min(dt * 5, 1)
    cam.fov_scale += (target_fov - cam.fov_scale) * min(dt * 3, 1)

    if !g.deployed { g.shake -= g.shake * min(dt * 3, 1) }
    g.shake_time += dt
    t := g.shake_time
    a := g.shake * g.shake * 0.9
    cam.shake = {
        a * (math.sin(t * 31) * 0.6 + math.sin(t * 57 + 1.7) * 0.4),
        a * (math.sin(t * 37 + 0.6) * 0.6 + math.sin(t * 71) * 0.4),
    }

    // Landing dip springs back, and the seat's kick (a little bounce).
    g.land_dip -= g.land_dip * min(dt * 6, 1)
    g.kick_vel += (-40 * g.kick - 7 * g.kick_vel) * dt
    g.kick += g.kick_vel * dt
    g.kick = clamp(g.kick, -0.5, 0.5)

    // Third-person chase camera, pulled in when terrain is in the way.
    want: f32 = 0
    if g.third_person { want = g.deployed ? 6.5 : 4.0 }
    view_fwd := camera_forward(cam^)
    back := -view_fwd
    if want > 0 {
        origin := cam.pos + [3]f32{0, 1.2, 0}
        if hit, _, ok := raycast_voxel(gs, origin, back, want + 1); ok {
            c := [3]f32{f32(hit.x) + 0.5, f32(hit.y) + 0.5, f32(hit.z) + 0.5}
            want = clamp(la.length(c - origin) - 1.2, 0, want)
        }
    }
    rate: f32 = want < g.chase_dist ? 12 : 4 // pull in fast, ease out slowly
    g.chase_dist += (want - g.chase_dist) * min(dt * rate, 1)
    cam.view_offset = {0, g.land_dip + g.kick - cam.crouch * CROUCH_VIEW_DROP, 0}
    if g.chase_dist > 0.05 {
        cam.view_offset += back * g.chase_dist + [3]f32{0, 1.2 * clamp(g.chase_dist / 3, 0, 1), 0}
    }
}

// The glider as one entity of voxel-model parts (voxel_models.odin), all in
// the body frame at the pilot's eye. The wing unfolds by scaling its span.
// The pilot's body only shows in the chase view — in first person it would
// sit around the camera, so there it's only a shadow — but the arms on the
// bar always do.
glider_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    g := &gs.glider
    if !g.deployed || !ent_begin(f) { return }
    ent_scale_about(f, gs.camera.pos, world_scale)
    // The whole pilot in the chase view; from the eyes, just the arms.
    pilot := g.chase_dist > 1.5
    rot, grip := glider_wing_parts(f, gs.camera.pos, g.heading, g.path_angle + g.aoa, g.bank, g.deploy_t, PLAYER_TINT, pilot = pilot, bar = g.bar)
    ent_end(f)
    if pilot || !ent_begin(f, seen = false) { return }
    ent_scale_about(f, gs.camera.pos, world_scale)
    pilot_add_parts(f, gs.camera.pos, rot, PLAYER_TINT, grip, arms = false)
    ent_end(f)
}

// A glider with its pilot at the eye p: heading (degrees), pitch and bank
// (radians), unfolded 0..1, the speed bar pulled in 0..1 (the base bar
// drawn in to the chest: what tells you W is held). Inside an ent_begin /
// ent_end.
glider_wing_parts :: proc(f: ^Ent_Frame, p: [3]f32, heading, pitch, bank, deploy_t: f32, tint: [3]f32, pilot: bool, bar: f32 = 0) -> (rot: Basis, grip: [3]f32) {
    fwd, up := glider_axes(heading, pitch, bank)
    left := la.cross(up, fwd)
    rot = basis_from_axes(left, up, fwd)
    unfold := 0.12 + 0.88 * math.smoothstep(f32(0), 1, deploy_t)
    ent_part(f, .Glider_Wing, p, rot, {unfold, 1, 1})
    // A-frame (two downtubes and the base bar) and the arms holding the bar.
    at := proc(p: [3]f32, rot: Basis, b: [3]f32) -> [3]f32 { return p + rot * b }
    apex := at(p, rot, {0, 1.25, 0.15})
    pull := math.smoothstep(f32(0), 1, bar)
    grip = [3]f32{0.46, -0.42 + 0.07 * pull, 0.72 - 0.24 * pull} // the right hand on the bar; the left mirrors it
    bar_l := at(p, rot, {0.75, grip.y - 0.03, grip.z + 0.03})
    bar_r := at(p, rot, {-0.75, grip.y - 0.03, grip.z + 0.03})
    ent_segment(f, .Rod, apex, bar_l, up)
    ent_segment(f, .Rod, apex, bar_r, up)
    ent_segment(f, .Rod, bar_l, bar_r, up)
    if pilot {
        pilot_add_parts(f, p, rot, tint, grip)
    } else {
        ent_segment(f, .Arm, at(p, rot, {0.2, -0.16, -0.05}), at(p, rot, grip), up, tint)
        ent_segment(f, .Arm, at(p, rot, {-0.2, -0.16, -0.05}), at(p, rot, grip * {-1, 1, 1}), up, tint)
    }
    return
}

// Screen position (pixels in a w x h window) of a world direction, or false
// when it's behind the view.
glider_project :: proc(cam: Camera, dir: [3]f32, w, h: f32) -> (x, y: f32, ok: bool) {
    fwd, right, up := camera_view_basis(cam, w / h)
    d := la.dot(dir, fwd)
    if d < 0.05 { return }
    nx := la.dot(dir, right) / d / la.length2(right)
    ny := la.dot(dir, up)    / d / la.length2(up)
    return (nx + 1) * 0.5 * w, (1 - ny) * 0.5 * h, true
}
