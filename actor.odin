package main

import "core:math"

// Helpers shared by the things that walk, hop and turn about the world
// (slimes, enemies).

// Does a box (feet at pos, half width hw, height h) overlap a solid voxel?
box_solid :: proc(gs: ^Game_State, pos: [3]f32, hw, h: f32) -> bool {
    E :: f32(0.001)
    for iy in int(math.floor(pos.y + E)) ..= int(math.floor(pos.y + h - E)) {
        for ix in int(math.floor(pos.x - hw + E)) ..= int(math.floor(pos.x + hw - E)) {
            for iz in int(math.floor(pos.z - hw + E)) ..= int(math.floor(pos.z + hw - E)) {
                if solid_at(gs, ix, iy, iz) { return true }
            }
        }
    }
    return false
}

// Turn yaw (entity convention: facing {-sin, 0, cos}) toward the flat
// direction dir by at most `amount` radians.
turn_towards :: proc(yaw: ^f32, dir: [2]f32, amount: f32) {
    target := math.atan2(-dir.x, dir.y) // entity convention
    d := math.mod(target - yaw^ + 3 * math.PI, 2 * math.PI) - math.PI
    yaw^ += clamp(d, -amount, amount)
}
