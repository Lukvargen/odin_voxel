package main

import "core:math"
import la "core:math/linalg"

// Day/night cycle. The clock drives the sun across the sky (rising in the
// east, setting in the west, tilted south so it is never overhead). At night
// the light source switches to the moon, opposite the sun: the shaders keep
// one light direction for shadows, and read the true sun direction and a
// night factor to paint twilight, stars and the moon (camera_uniforms.hlsl).

DAY_START_HOUR   :: 16.8   // late afternoon: long shadows, golden light
DAY_LENGTH_MIN   :: 24.0   // real minutes per game day
SUN_TILT         :: 0.62   // radians the sun's path leans south (max elevation ~54 deg)
SUN_PEAK         :: 1.5    // sun_intensity at full day
MOON_PEAK        :: 0.24   // moonlight intensity
NIGHT_EXPOSURE   :: 2.8    // eye adaptation at night: lifts moonlit shapes out of black

Day_Cycle :: struct {
    hour:     f32,  // 0..24
    paused:   bool, // clock stopped (options panel, or L)
    manual:   bool, // L aimed the sun by hand: light_dir is left alone
    sun_true: [3]f32,
    night:    f32,  // 0 day .. 1 full night
    mist:     f32,  // valley mist amount, thickest at dawn
    eye:      f32,  // smoothed exposure multiplier (eye adaptation)
}

day_init :: proc(gs: ^Game_State) {
    gs.day.hour = DAY_START_HOUR
    gs.day.eye  = 1
    day_update(gs, 0)
    gs.day.eye  = day_target_eye(gs.day.night, gs.day.sun_true.y)
}

// Direction toward the sun at hour h.
sun_dir_at :: proc(h: f32) -> [3]f32 {
    a := (h - 6) / 24 * math.TAU // 0 at sunrise, pi/2 at noon
    up    := [3]f32{0, math.cos(f32(SUN_TILT)), -math.sin(f32(SUN_TILT))}
    east  := [3]f32{1, 0, 0}
    return la.normalize(east * math.cos(a) + up * math.sin(a))
}

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

day_update :: proc(gs: ^Game_State, dt: f32) {
    d := &gs.day
    if !d.paused {
        d.hour += dt * 24 / (DAY_LENGTH_MIN * 60)
        for d.hour >= 24 { d.hour -= 24 }
    }
    sun := sun_dir_at(d.hour)
    d.sun_true = sun
    d.night = 1 - math.smoothstep(f32(-0.20), 0.04, sun.y)

    if !d.manual {
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
        d.sun_true = la.normalize(gs.light_dir)
        d.night = 1 - math.smoothstep(f32(-0.20), 0.04, d.sun_true.y)
    }

    // Mist pools in the valleys at dawn, lingers a little at dusk and at night.
    h := d.hour
    d.mist = 0.12 + 0.95 * bump(h, 6.6, 1.8) + 0.30 * bump(h, 20.0, 2.5) + 0.25 * d.night

    // Eye adaptation, a few seconds to settle (time skips settle as fast).
    target := day_target_eye(d.night, d.sun_true.y)
    d.eye += (target - d.eye) * min(1.0, dt * 0.8)
}

// Clock text for the HUD / options, e.g. "16:48".
day_clock :: proc(h: f32) -> (hh, mm: int) {
    total := int(h * 60)
    return (total / 60) % 24, total % 60
}
