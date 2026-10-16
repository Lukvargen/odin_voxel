package main

import "core:math"
import "core:time"

// Things the server moves (the other players; for a joined client, the
// monsters), drawn a little in the past: each keeps its last few views,
// stamped with the server's time (Msg_Clock.time), and is drawn at
// REPLICA_DELAY behind the server's latest, between the two views around
// that moment. A late or lost packet then doesn't show; the views it has
// cover it. Only past the newest view does it guess ahead, by its speed.

REPLICA_SAMPLES :: 6
REPLICA_DELAY   :: f64(0.1) // seconds behind the server: three views at 30 Hz
REPLICA_AHEAD   :: f64(0.15) // at most this far past the newest view, then it waits there

Replica :: struct($V: typeid) {
    views: [REPLICA_SAMPLES]V, // oldest first
    times: [REPLICA_SAMPLES]f64,
    count: int,
    age:   f32, // seconds since the newest arrived
}

// The server's clock as this client sees it: the offset from ours,
// following the stamps as they come in.
Replica_Clock :: struct {
    epoch:  time.Tick,
    offset: f64,  // server time - ours
    set:    bool,
    stamp:  f64,  // the batch being read: its views are of this moment
    now:    f64,  // draw the replicas as they were at this server time
}

// A Clock arrived, stamped `server_time`.
replica_clock_stamp :: proc(c: ^Replica_Clock, server_time: f64) {
    if c.epoch == {} { c.epoch = time.tick_now() }
    c.stamp = server_time
    sample := server_time - time.duration_seconds(time.tick_since(c.epoch))
    // Packets that took longer say less about the clock: follow early ones
    // at once, late ones only slowly (and a big jump, a new server, at once).
    if !c.set || abs(sample - c.offset) > 0.5 {
        c.offset, c.set = sample, true
    } else if sample > c.offset {
        c.offset += (sample - c.offset) * 0.3
    } else {
        c.offset += (sample - c.offset) * 0.03
    }
}

// Each frame, before drawing: the moment to show.
replica_clock_tick :: proc(c: ^Replica_Clock) {
    if c.epoch == {} { c.epoch = time.tick_now() }
    c.now = time.duration_seconds(time.tick_since(c.epoch)) + c.offset - REPLICA_DELAY
}

replica_push :: proc(r: ^Replica($V), v: V, t: f64) {
    r.age = 0
    if r.count > 0 && t <= r.times[r.count - 1] {
        if t == r.times[r.count - 1] { r.views[r.count - 1] = v } // the same moment again
        return // older than what we have: late
    }
    if r.count == REPLICA_SAMPLES {
        copy(r.views[:], r.views[1:])
        copy(r.times[:], r.times[1:])
        r.count -= 1
    }
    r.views[r.count], r.times[r.count] = v, t
    r.count += 1
}

// The views either side of server time t, and how far from a to b (0..1);
// past the newest, a = b = it and `ahead` says by how long.
replica_at :: proc(r: ^Replica($V), t: f64) -> (a, b: ^V, k: f32, ahead: f32) {
    if r.count == 0 { return }
    last := r.count - 1
    if t >= r.times[last] {
        return &r.views[last], &r.views[last], 0, f32(min(t - r.times[last], REPLICA_AHEAD))
    }
    for i := last - 1; i >= 0; i -= 1 {
        if t >= r.times[i] {
            return &r.views[i], &r.views[i + 1], f32((t - r.times[i]) / (r.times[i + 1] - r.times[i])), 0
        }
    }
    return &r.views[0], &r.views[0], 0, 0 // before them all: the oldest
}

// Where between two positions; a jump (a teleport, a respawn) isn't flown across.
replica_lerp_pos :: proc(a, b: [3]f32, k: f32) -> [3]f32 {
    d := b - a
    if d.x * d.x + d.y * d.y + d.z * d.z > 16 { return k < 0.5 ? a : b }
    return a + d * k
}

// The shorter way round from angle a to b, `turn` to a full circle.
replica_lerp_angle :: proc(a, b, k: f32, turn: f32 = 2 * math.PI) -> f32 {
    d := math.mod(b - a, turn)
    if d > turn / 2 { d -= turn } else if d < -turn / 2 { d += turn }
    return a + d * k
}
