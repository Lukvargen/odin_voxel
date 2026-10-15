package main

import "core:math"
import "core:math/rand"
import la "core:math/linalg"

// Short-lived effects shared by everything that fights: goo, blood, bone
// chips, sparks and dust (small tinted cubes that fly, fall and bounce),
// and the damage numbers the HUD draws over what was hit (ui.odin). Ring
// buffers: a new one takes the oldest slot.

MAX_GOO     :: 64
MAX_NUMBERS :: 24

Goo :: struct {
    pos, vel:  [3]f32,
    life, max: f32,
    size:      f32, // voxels
    color:     [3]f32,
    floor:     f32, // bounces here
}

Damage_Number :: struct {
    pos:     [3]f32,
    life:    f32,
    value:   int,
    boosted: bool, // the speed bonus was big: drawn hotter
    big:     bool,
}

Effects :: struct {
    goo:         [MAX_GOO]Goo,
    next_goo:    int,
    numbers:     [MAX_NUMBERS]Damage_Number,
    next_number: int,
}

// One frame of the effects. dt is 0 during hit stop.
fx_update :: proc(gs: ^Game_State, dt: f32) {
    fx := &gs.fx
    if dt <= 0 { return }
    for &g in fx.goo {
        if g.life <= 0 { continue }
        g.life -= dt
        g.vel.y -= 22 * dt
        g.pos += g.vel * dt
        if g.pos.y < g.floor {
            g.pos.y = g.floor
            g.vel.y = abs(g.vel.y) * 0.3
            g.vel.xz *= 0.55
        }
    }
    for &n in fx.numbers {
        if n.life <= 0 { continue }
        n.life -= dt
        n.pos.y += dt * 1.4
    }
}

// A ring of dust where a plunge lands.
fx_shockwave :: proc(fx: ^Effects, pos: [3]f32) {
    for i in 0 ..< 20 {
        a := f32(i) / 20 * 2 * math.PI
        dir := [3]f32{math.cos(a), 0, math.sin(a)}
        add_goo(fx, {pos = pos + dir * 0.6 + {0, 0.15, 0}, vel = dir * rand.float32_range(11, 15) + {0, rand.float32_range(1, 4), 0},
            life = 0.45, max = 0.45, size = 0.18, color = {0.8, 0.76, 0.68}, floor = pos.y})
    }
}

splat :: proc(fx: ^Effects, c, color, knock: [3]f32, count: int, force: f32) {
    dir := la.normalize0(knock)
    for _ in 0 ..< count {
        r := [3]f32{rand.float32_range(-1, 1), rand.float32_range(-0.2, 1), rand.float32_range(-1, 1)}
        life := rand.float32_range(0.4, 0.8)
        add_goo(fx, {pos = c + r * 0.25, vel = (dir * 5 + r * 5) * force + {0, 3, 0}, life = life, max = life,
            size = rand.float32_range(0.1, 0.2) * (0.7 + force * 0.3), color = color * rand.float32_range(0.8, 1.15), floor = c.y - 1})
    }
}

add_goo :: proc(fx: ^Effects, g: Goo) {
    fx.goo[fx.next_goo] = g
    fx.next_goo = (fx.next_goo + 1) % MAX_GOO
}

add_number :: proc(fx: ^Effects, pos: [3]f32, damage: f32, boosted: bool) {
    j := [3]f32{rand.float32_range(-0.3, 0.3), 0, rand.float32_range(-0.3, 0.3)}
    fx.numbers[fx.next_number] = {pos = pos + j, life = 0.9, value = int(math.round(damage)), boosted = boosted, big = damage >= 25}
    fx.next_number = (fx.next_number + 1) % MAX_NUMBERS
}

// The goo is one entity of small cubes (no shadows: specks).
fx_add_parts :: proc(gs: ^Game_State, f: ^Ent_Frame) {
    fx := &gs.fx
    any := false
    for g in fx.goo { if g.life > 0 { any = true; break } }
    if !any || !ent_begin(f, false) { return }
    for g in fx.goo {
        if g.life <= 0 { continue }
        k := g.size / 0.125 * math.sqrt(g.life / g.max)
        ent_part(f, .Goo, g.pos, IDENTITY, {k, k, k}, g.color)
    }
    ent_end(f)
}
