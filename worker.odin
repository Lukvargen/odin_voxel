package main

import "core:math"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

MAX_WORKERS :: 16

Chunk_Job :: struct {
    key:       [2]int, // world column coord (wcx, wcz)
    from_disk: bool,   // load the player-edited save instead of generating
}

Chunk_Result :: struct {
    key:       [2]int, // world column coord (wcx, wcz)
    column:    ^Column,
    from_disk: bool,   // asked for from the save (generated anyway if that was unreadable)
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

    // Far terrain tiles (far.odin), behind mu_pending / mu_ready. Pending is
    // sorted farthest-first so workers pop the nearest from the end; column
    // jobs always go first.
    far_pending: [dynamic]Far_Job,
    far_queued:  map[[2]int]bool,
    far_ready:   [dynamic]Far_Result,
    far_player:  [2]int, // player tile at the last enqueue

    threads:     [MAX_WORKERS]^thread.Thread,
    thread_count: int,
    running:     bool,

    // Player column, atomically mirrored from the main thread on every
    // boundary cross. Workers read it to pop the nearest pending job first
    // and to drop jobs that drifted out of LOAD_RADIUS_XZ before a worker
    // got to them — so fast flight spends worker time on what the player
    // will actually see, not the stale far frontier. Avoids racing
    // gs.player_chunk directly.
    player_cx:   int,
    player_cz:   int,
    // Flat view direction (x, z) * 1000, so jobs ahead of the camera go first.
    view_fx:     int,
    view_fz:     int,
}

// Called from the main thread every frame with the flat camera forward.
worker_pool_set_view :: proc(pool: ^Worker_Pool, fx, fz: f32) {
    sync.atomic_store(&pool.view_fx, int(fx * 1000))
    sync.atomic_store(&pool.view_fz, int(fz * 1000))
}

// Order in which a job at offset (dx, dz) from the player is built: by
// distance, with jobs behind the camera counted up to twice as far, so
// terrain fills in ahead of you first. fx, fz: view direction * 1000.
job_priority :: proc(dx, dz, fx, fz: int) -> f32 {
    d2 := f32(dx*dx + dz*dz)
    if d2 == 0 { return 0 }
    cos_a := f32(dx*fx + dz*fz) / (1000 * math.sqrt(d2))
    return d2 * (1.5 - 0.5 * cos_a)
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
    pending := len(pool.pending) + len(pool.far_pending)
    sync.mutex_unlock(&pool.mu_pending)
    if pending != 0 || sync.atomic_load(&pool.in_flight) != 0 { return false }
    sync.mutex_lock(&pool.mu_ready)
    ready := len(pool.ready) + len(pool.far_ready)
    sync.mutex_unlock(&pool.mu_ready)
    return ready == 0
}

worker_pool_start :: proc(pool: ^Worker_Pool) {
    pool.pending = make([dynamic]Chunk_Job)
    pool.ready   = make([dynamic]Chunk_Result)
    pool.queued  = make(map[[2]int]bool)
    pool.running = true
    // One core stays free for the main thread.
    pool.thread_count = clamp(os.get_processor_core_count() - 1, 1, MAX_WORKERS)
    for i in 0 ..< pool.thread_count {
        pool.threads[i] = thread.create_and_start_with_data(pool, worker_proc)
    }
}

worker_pool_stop :: proc(pool: ^Worker_Pool) {
    pool.running = false
    for i in 0 ..< pool.thread_count {
        thread.join(pool.threads[i])
        thread.destroy(pool.threads[i])
    }
    delete(pool.pending)
    delete(pool.ready)
    delete(pool.queued)
    delete(pool.far_pending)
    delete(pool.far_queued)
    delete(pool.far_ready)
}

worker_pool_enqueue :: proc(pool: ^Worker_Pool, key: [2]int, from_disk: bool) {
    sync.mutex_lock(&pool.mu_queued)
    already := pool.queued[key]
    if !already { pool.queued[key] = true }
    sync.mutex_unlock(&pool.mu_queued)
    if already { return }

    sync.mutex_lock(&pool.mu_pending)
    append(&pool.pending, Chunk_Job{key = key, from_disk = from_disk})
    sync.mutex_unlock(&pool.mu_pending)
}

// Queue far tiles not already queued, then re-sort the whole far queue by
// distance to the player tile (farthest first).
worker_pool_enqueue_far :: proc(pool: ^Worker_Pool, jobs: []Far_Job, player_tile: [2]int) {
    sync.mutex_lock(&pool.mu_pending)
    defer sync.mutex_unlock(&pool.mu_pending)
    pool.far_player = player_tile
    for j in jobs {
        if j.key in pool.far_queued { continue }
        pool.far_queued[j.key] = true
        append(&pool.far_pending, j)
    }
    // Farthest (lowest priority) first: workers pop the end.
    Sort_Ctx :: struct { p: [2]int, fx, fz: int }
    ctx := Sort_Ctx{player_tile, sync.atomic_load(&pool.view_fx), sync.atomic_load(&pool.view_fz)}
    context.user_ptr = &ctx
    slice.sort_by(pool.far_pending[:], proc(a, b: Far_Job) -> bool {
        c := (^Sort_Ctx)(context.user_ptr)
        da, db := a.key - c.p, b.key - c.p
        return job_priority(da.x, da.y, c.fx, c.fz) > job_priority(db.x, db.y, c.fx, c.fz)
    })
}

worker_pool_drain_far :: proc(pool: ^Worker_Pool, max_n: int) -> []Far_Result {
    sync.mutex_lock(&pool.mu_ready)
    defer sync.mutex_unlock(&pool.mu_ready)
    take := min(len(pool.far_ready), max_n)
    results := make([]Far_Result, take)
    copy(results, pool.far_ready[len(pool.far_ready) - take:])
    resize(&pool.far_ready, len(pool.far_ready) - take)
    return results
}

// Remove a key from the queued set so it can be re-enqueued later.
worker_pool_unqueue :: proc(pool: ^Worker_Pool, key: [2]int) {
    sync.mutex_lock(&pool.mu_queued)
    delete_key(&pool.queued, key)
    sync.mutex_unlock(&pool.mu_queued)
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
        // Generation scratch (terrain grids, lattices) lives in the temp
        // allocator for one job.
        free_all(context.temp_allocator)
        // Pop the pending job NEAREST the player. While scanning, drop any
        // job that has drifted outside LOAD_RADIUS_XZ — the player moved on
        // before a worker reached it, so generating it now is wasted work
        // (it would integrate behind the player, or churn out before being
        // seen). Dropped jobs are un-queued so they re-enqueue if the player
        // returns. This linear scan is trivial next to the ~4 ms column gen
        // and is what keeps fast flight spending workers on visible terrain.
        pcx := sync.atomic_load(&pool.player_cx)
        pcz := sync.atomic_load(&pool.player_cz)
        vfx := sync.atomic_load(&pool.view_fx)
        vfz := sync.atomic_load(&pool.view_fz)

        job_ok := false
        job: Chunk_Job
        sync.mutex_lock(&pool.mu_pending)
        best_i    := -1
        best_prio := max(f32)
        i := 0
        for i < len(pool.pending) {
            k := pool.pending[i].key
            ddx := k[0] - pcx
            ddz := k[1] - pcz
            r := sync.atomic_load(&view_radius)
            if ddx*ddx + ddz*ddz > r * r {
                worker_pool_unqueue(pool, k)        // stale: re-enqueueable later
                n := len(pool.pending)
                pool.pending[i] = pool.pending[n-1] // swap-remove
                pop(&pool.pending)
                continue                            // re-test swapped-in elem
            }
            if p := job_priority(ddx, ddz, vfx, vfz); p < best_prio { best_prio = p; best_i = i }
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
            if worker_far_job(pool) { continue }
            // Idle: sleep rather than spin, so idle workers don't take CPU
            // from the main thread.
            time.sleep(time.Millisecond)
            continue
        }

        column: ^Column
        if job.from_disk { column = load_column(job.key) }
        if column == nil { column = generate_column_at(job.key[0], job.key[1]) }
        t_light := time.tick_now()
        light_column_compute(column)
        profile_add(.Light_Column, t_light)
        res := Chunk_Result{key = job.key, column = column, from_disk = job.from_disk}

        sync.mutex_lock(&pool.mu_ready)
        append(&pool.ready, res)
        sync.mutex_unlock(&pool.mu_ready)
        sync.atomic_sub(&pool.in_flight, 1)
    }
}

// Pop and build the nearest far tile still in range. False if none.
@(private="file")
worker_far_job :: proc(pool: ^Worker_Pool) -> bool {
    job: Far_Job
    found := false
    sync.mutex_lock(&pool.mu_pending)
    for len(pool.far_pending) > 0 {
        j := pop(&pool.far_pending)
        d := j.key - pool.far_player
        if d.x*d.x + d.y*d.y > FAR_RADIUS_TILES * FAR_RADIUS_TILES {
            delete_key(&pool.far_queued, j.key) // stale: re-enqueueable later
            continue
        }
        job, found = j, true
        sync.atomic_add(&pool.in_flight, 1)
        break
    }
    sync.mutex_unlock(&pool.mu_pending)
    if !found { return false }

    res := far_tile_compute(job)

    sync.mutex_lock(&pool.mu_pending)
    delete_key(&pool.far_queued, job.key)
    sync.mutex_unlock(&pool.mu_pending)
    sync.mutex_lock(&pool.mu_ready)
    append(&pool.far_ready, res)
    sync.mutex_unlock(&pool.mu_ready)
    sync.atomic_sub(&pool.in_flight, 1)
    return true
}

// Columns still to come: being generated, plus queued.
worker_pool_pending_count :: proc(pool: ^Worker_Pool) -> int {
    n := int(pool.in_flight)
    // pending dynamic array is mutex-guarded; use atomic-free best-effort read.
    n += len(pool.pending)
    return n
}
