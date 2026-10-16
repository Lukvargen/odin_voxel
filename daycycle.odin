package main

import "core:math"
import la "core:math/linalg"

// Day/night cycle. The clock drives the sun across the sky (rising in the
// east, setting in the west, tilted south so it is never overhead). At night
// the light source switches to the moon, opposite the sun: the shaders keep
// one light direction for shadows, and read the true sun direction and a
// night factor to paint twilight, stars and the moon (camera_uniforms.hlsl).
//
// Two halves: the clock is the simulation's (Sim.day: a server keeps the
// time and its night brings out the skeletons); the sky is the client's
// (Game_State.sky: light, mist, eye adaptation, and L aiming the sun by
// hand, which changes only what this client sees).

DAY_START_HOUR   :: 16.8   // late afternoon: long shadows, golden light
DAY_LENGTH_MIN   :: 24.0   // real minutes per game day
SUN_TILT         :: 0.62   // radians the sun's path leans south (max elevation ~54 deg)
SUN_PEAK         :: 1.5    // sun_intensity at full day
MOON_PEAK        :: 0.24   // moonlight intensity
NIGHT_EXPOSURE   :: 2.8    // eye adaptation at night: lifts moonlit shapes out of black

Day_Clock :: struct {
    hour:   f32,  // 0..24
    paused: bool, // clock stopped (options panel, or L)
    night:  f32,  // 0 day .. 1 full night, by the clock
}

Sky :: struct {
    manual:   bool, // L aimed the sun by hand: light_dir is left alone
    sun_true: [3]f32,
    night:    f32,  // 0 day .. 1 full night, as seen (follows a hand-aimed sun)
    mist:     f32,  // valley mist amount, thickest at dawn
    eye:      f32,  // smoothed exposure multiplier (eye adaptation)
}

day_init :: proc(gs: ^Game_State) {
    day_set_hour(gs, DAY_START_HOUR, settle = true)
}

// Set the clock (options, the hour= argument, benches) and bring the sky
// along; settle snaps the eye adaptation instead of easing into it. Over a
// network this is a request to the server.
day_set_hour :: proc(gs: ^Game_State, h: f32, settle := false) {
    gs.day.hour = h
    gs.sky.manual = false
    day_tick(gs, 0)
    sky_update(gs, 0)
    if settle { gs.sky.eye = day_target_eye(gs.sky.night, gs.sky.sun_true.y) }
}

// Direction toward the sun at hour h.
sun_dir_at :: proc(h: f32) -> [3]f32 {
    a := (h - 6) / 24 * math.TAU // 0 at sunrise, pi/2 at noon
    up    := [3]f32{0, math.cos(f32(SUN_TILT)), -math.sin(f32(SUN_TILT))}
    east  := [3]f32{1, 0, 0}
    return la.normalize(east * math.cos(a) + up * math.sin(a))
}

// 0 by day .. 1 at full night, for a sun at height sun_y.
night_for :: proc(sun_y: f32) -> f32 { return 1 - math.smoothstep(f32(-0.20), 0.04, sun_y) }

@(private="file")
bump :: proc(x, centre, width: f32) -> f32 {
    d := (x - centre) / width
    return math.exp(-d * d)
}

// Exposure: a little lift with the sun low (long shadows cover most of the
// view), much more by moonlight.
day_target_eye :: proc(night: f32, sun_y: f32 = 1) -> f32 {
    low := (1 - math.smoothstep(f32(0.04), 0.30, sun_y)) * (1 - night)
    return 1 + 0.45 * low + (NIGHT_EXPOSURE - 1) * night
}

// The simulation's clock.
day_tick :: proc(sim: ^Sim, dt: f32) {
    d := &sim.day
    if !d.paused {
        d.hour += dt * 24 / (DAY_LENGTH_MIN * 60)
        for d.hour >= 24 { d.hour -= 24 }
    }
    d.night = night_for(sun_dir_at(d.hour).y)
}

// The client's sky for the clock's hour: sun or moon light, mist, eyes.
sky_update :: proc(gs: ^Game_State, dt: f32) {
    s := &gs.sky
    sun := sun_dir_at(gs.day.hour)
    s.sun_true = sun
    s.night = gs.day.night

    if !s.manual {
        // The sun lights the world until just below the horizon, then the
        // moon (opposite) takes over; both intensities are ~0 at the switch.
        if sun.y > -0.06 {
            gs.light_dir = sun
            gs.sun_intensity = SUN_PEAK * math.smoothstep(f32(-0.06), 0.16, sun.y)
        } else {
            moon := -sun
            gs.light_dir = moon
            gs.sun_intensity = MOON_PEAK * math.smoothstep(f32(0.04), 0.18, moon.y)
        }
    } else {
        // Manual sun (L): the true sun is wherever the light points.
        s.sun_true = la.normalize(gs.light_dir)
        s.night = night_for(s.sun_true.y)
    }

    // Mist pools in the valleys at dawn, lingers a little at dusk and at night.
    h := gs.day.hour
    s.mist = 0.12 + 0.95 * bump(h, 6.6, 1.8) + 0.30 * bump(h, 20.0, 2.5) + 0.25 * s.night

    // Eye adaptation, a few seconds to settle (time skips settle as fast).
    target := day_target_eye(s.night, s.sun_true.y)
    s.eye += (target - s.eye) * min(1.0, dt * 0.8)
}

// Clock text for the HUD / options, e.g. "16:48".
day_clock :: proc(h: f32) -> (hh, mm: int) {
    total := int(h * 60)
    return (total / 60) % 24, total % 60
}
