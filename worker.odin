package main

import "core:sync"
import "core:thread"

WORKER_COUNT :: 12

Chunk_Job :: struct {
    key: [2]int, // world column coord (wcx, wcz)
}

Chunk_Result :: struct {
    key:    [2]int,             // world column coord (wcx, wcz)
    column: [CHUNKS_H]^Chunk,   // one chunk per Y layer
    // Precomputed on the worker so the main-thread integrate avoids the
    // 64×(512-voxel scan + conditional mask build) that was the streaming
    // wall (~520µs/column → backlog while flying). empty[iy] true ⇒ layer
    // is all air (no pool block). mask[iy] is the packed 512-bit occupancy
    // the GPU consumes; main thread just mem.copy's it into the pool slot.
    empty:  [CHUNKS_H]bool,
    mask:   [CHUNKS_H][MASK_U32_PER_BRICK]u32,
}

Worker_Pool :: struct {
    mu_pending:  sync.Mutex,
    pending:     [dynamic]Chunk_Job,

    mu_ready:    sync.Mutex,
    ready:       [dynamic]Chunk_Result,

    // Tracks columns that are either pending or already done,
    // so we don't enqueue the same column twice.
    mu_queued:   sync.Mutex,
    queued:      map[[2]int]bool,

    // Number of jobs popped but not yet pushed to ready (in-flight).
    in_flight:   int,

    threads:     [WORKER_COUNT]^thread.Thread,
    running:     bool,

    // Player column, atomically mirrored from the main thread on every
    // boundary cross. Workers read it to pop the nearest pending job first
    // and to drop jobs that drifted out of LOAD_RADIUS_XZ before a worker
    // got to them — so fast flight spends worker time on what the player
    // will actually see, not the stale far frontier. Avoids racing
    // gs.player_chunk directly.
    player_cx:   int,
    player_cz:   int,
}

// Called from the main thread on startup and every chunk-boundary cross.
worker_pool_set_player :: proc(pool: ^Worker_Pool, cx, cz: int) {
    sync.atomic_store(&pool.player_cx, cx)
    sync.atomic_store(&pool.player_cz, cz)
}

// True when there is no pending work, nothing being generated, AND nothing
// waiting in the ready queue. The ready check matters because the budgeted
// drain can leave completed columns un-integrated; the startup blocking loop
// must not exit while any remain.
worker_pool_idle :: proc(pool: ^Worker_Pool) -> bool {
    sync.mutex_lock(&pool.mu_pending)
    pending := len(pool.pending)
    sync.mutex_unlock(&pool.mu_pending)
    if pending != 0 || sync.atomic_load(&pool.in_flight) != 0 { return false }
    sync.mutex_lock(&pool.mu_ready)
    ready := len(pool.ready)
    sync.mutex_unlock(&pool.mu_ready)
    return ready == 0
}

worker_pool_start :: proc(pool: ^Worker_Pool) {
    pool.pending = make([dynamic]Chunk_Job)
    pool.ready   = make([dynamic]Chunk_Result)
    pool.queued  = make(map[[2]int]bool)
    pool.running = true
    for i in 0 ..< WORKER_COUNT {
        pool.threads[i] = thread.create_and_start_with_data(pool, worker_proc)
    }
}

worker_pool_stop :: proc(pool: ^Worker_Pool) {
    pool.running = false
    for i in 0 ..< WORKER_COUNT {
        thread.join(pool.threads[i])
        thread.destroy(pool.threads[i])
    }
    delete(pool.pending)
    delete(pool.ready)
    delete(pool.queued)
}

worker_pool_enqueue :: proc(pool: ^Worker_Pool, key: [2]int) {
    sync.mutex_lock(&pool.mu_queued)
    already := pool.queued[key]
    if !already { pool.queued[key] = true }
    sync.mutex_unlock(&pool.mu_queued)
    if already { return }

    sync.mutex_lock(&pool.mu_pending)
    append(&pool.pending, Chunk_Job{key = key})
    sync.mutex_unlock(&pool.mu_pending)
}

// Remove a key from the queued set so it can be re-enqueued later.
worker_pool_unqueue :: proc(pool: ^Worker_Pool, key: [2]int) {
    sync.mutex_lock(&pool.mu_queued)
    delete_key(&pool.queued, key)
    sync.mutex_unlock(&pool.mu_queued)
}

// Drain all finished chunks. Caller owns integrating them into the world.
worker_pool_drain :: proc(pool: ^Worker_Pool) -> []Chunk_Result {
    sync.mutex_lock(&pool.mu_ready)
    results := make([]Chunk_Result, len(pool.ready))
    copy(results, pool.ready[:])
    clear(&pool.ready)
    sync.mutex_unlock(&pool.mu_ready)
    return results
}

// Drain at most max_n finished columns; the rest stay queued for next frame.
// Bounds per-frame main-thread integration cost so a burst of completed
// columns can't spike the frame. max_n <= 0 means unbounded (drain all).
worker_pool_drain_budget :: proc(pool: ^Worker_Pool, max_n: int) -> []Chunk_Result {
    sync.mutex_lock(&pool.mu_ready)
    avail := len(pool.ready)
    take  := avail
    if max_n > 0 && take > max_n { take = max_n }
    results := make([]Chunk_Result, take)
    copy(results, pool.ready[:take])
    if take == avail {
        clear(&pool.ready)
    } else {
        // Shift the untaken tail down to the front, keep it for next frame.
        remaining := avail - take
        copy(pool.ready[:remaining], pool.ready[take:avail])
        resize(&pool.ready, remaining)
    }
    sync.mutex_unlock(&pool.mu_ready)
    return results
}

worker_proc :: proc(data: rawptr) {
    pool := (^Worker_Pool)(data)
    for pool.running {
        // Pop the pending job NEAREST the player. While scanning, drop any
        // job that has drifted outside LOAD_RADIUS_XZ — the player moved on
        // before a worker reached it, so generating it now is wasted work
        // (it would integrate behind the player, or churn out before being
        // seen). Dropped jobs are un-queued so they re-enqueue if the player
        // returns. This linear scan is trivial next to the ~4 ms column gen
        // and is what keeps fast flight spending workers on visible terrain.
        pcx := sync.atomic_load(&pool.player_cx)
        pcz := sync.atomic_load(&pool.player_cz)

        job_ok := false
        job: Chunk_Job
        sync.mutex_lock(&pool.mu_pending)
        best_i    := -1
        best_dist := max(int)
        i := 0
        for i < len(pool.pending) {
            k := pool.pending[i].key
            ddx := k[0] - pcx
            ddz := k[1] - pcz
            if abs(ddx) > LOAD_RADIUS_XZ || abs(ddz) > LOAD_RADIUS_XZ {
                worker_pool_unqueue(pool, k)        // stale: re-enqueueable later
                n := len(pool.pending)
                pool.pending[i] = pool.pending[n-1] // swap-remove
                pop(&pool.pending)
                continue                            // re-test swapped-in elem
            }
            d := ddx*ddx + ddz*ddz
            if d < best_dist { best_dist = d; best_i = i }
            i += 1
        }
        if best_i >= 0 {
            job = pool.pending[best_i]
            n := len(pool.pending)
            pool.pending[best_i] = pool.pending[n-1] // swap-remove
            pop(&pool.pending)
            job_ok = true
            sync.atomic_add(&pool.in_flight, 1)
        }
        sync.mutex_unlock(&pool.mu_pending)

        if !job_ok {
            thread.yield()
            continue
        }

        column := generate_column_at(job.key[0], job.key[1])

        // Precompute emptiness + occupancy mask here (worker side) so the
        // main-thread integrate is just pool-alloc + two mem.copy. This is
        // the work that was the streaming wall.
        res := Chunk_Result{key = job.key, column = column}
        for iy in 0 ..< CHUNKS_H {
            voxels := &column[iy].voxels
            any := false
            for vi in 0 ..< VOXELS_PER_BRICK {
                v := voxels[vi]
                if v != 0 {
                    any = true
                    res.mask[iy][vi >> 5] |= u32(1) << u32(vi & 31)
                }
            }
            res.empty[iy] = !any
        }

        sync.mutex_lock(&pool.mu_ready)
        append(&pool.ready, res)
        sync.mutex_unlock(&pool.mu_ready)
        sync.atomic_sub(&pool.in_flight, 1)
    }
}
