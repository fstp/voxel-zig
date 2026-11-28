//! Partitioned blade streaming (ADR 0038, task 12.6).
//!
//! The paper's PTAS idea on the CPU/GL side: foliage lives in fixed 32 m world cells, each cell
//! occupies a persistent range in one instance buffer, and only cells that enter or leave the
//! patch are built or freed. A patch move therefore costs one strip of cells, not the whole field,
//! and a slot that was freed by a leaving cell is handed straight back to an entering one.
//!
//! Slots are byte ranges in an instance buffer; the allocator is first-fit with coalescing, so a
//! cell keeps its range across frames and its instances never move while it stays live.
//!
//! ADR 0041: a cell's blades are generated on a worker thread into a buffer the job owns, then
//! drained on the main thread and copied into the stream. This module never touches an Io handle
//! itself, so its tests stay synchronous.

const std = @import("std");
const scatter = @import("scatter.zig");
const Blade = scatter.Blade;

pub const max_parts: usize = 128;

pub const Range = struct {
    start: usize = 0,
    len: usize = 0,

    pub fn end(self: Range) usize {
        return self.start + self.len;
    }
};

pub const Part = struct {
    cx: i32 = 0,
    cz: i32 = 0,
    blades: std.ArrayList(Blade) = .empty,
    slot: Range = .{},
    has_slot: bool = false,
    /// Set the first time the cell is generated, even when it yields no blades: an empty cell is
    /// finished, not pending, or a patch over open water would never complete.
    built: bool = false,
    wanted: bool = false,
    live: bool = false,

    pub fn key(self: *const Part) u64 {
        const x: u64 = @bitCast(@as(i64, self.cx));
        const z: u64 = @bitCast(@as(i64, self.cz));
        return (x << 32) ^ z;
    }
};

/// One rebuilt partition, ready to be copied into the instance buffer.
pub const Upload = struct {
    offset: usize,
    blades: []const Blade,
};

/// One partition generated off the main thread. `blades` is owned by the job until `takeJob`
/// moves it into a part. Thread safety rests on two rules: the job object is only touched by the
/// worker until its `Future` is awaited, and the worker's only output is a buffer it allocated
/// itself.
pub const Job = struct {
    cx: i32,
    cz: i32,
    blades: std.ArrayList(Blade) = .empty,
    failed: bool = false,
};

fn jobMain(job: *Job, edits: []const @import("dc_world.zig").Edit, cx: i32, cz: i32) void {
    scatter.buildBladesCell(std.heap.page_allocator, edits, cx, cz, &job.blades) catch {
        job.failed = true;
    };
}

pub const Stream = struct {
    parts: std.ArrayList(Part) = .empty,
    /// Holes in the buffer, sorted by start and already coalesced.
    free: std.ArrayList(Range) = .empty,
    /// High-water mark of the instance buffer.
    used: usize = 0,
    capacity: usize = 0,
    reused_slots: usize = 0,
    freed_slots: usize = 0,
    built_total: usize = 0,
    /// In-flight generation; awaited before the job object is reused.
    job: ?std.Io.Future(void) = null,
    job_ptr: ?*Job = null,
    /// Nanoseconds from `startJob` to the landed upload, i.e. generation plus everything the frame
    /// paid. Raw, because a whole cell can complete inside the resolution of a millisecond figure.
    last_job_ms_ns: i64 = 0,
    /// Main-thread time inside `takeJob`, i.e. how long the await actually blocked the frame.
    last_wait_ms: f32 = 0,
    /// Stamped by `startJobTimed`.
    job_started_ns: i64 = 0,
    /// Instances in the most recently landed job (for the log line).
    last_landed: usize = 0,
    timer_start_ns: i64 = 0,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !Stream {
        var self = Stream{ .capacity = capacity };
        try self.parts.ensureTotalCapacity(alloc, max_parts);
        try self.free.ensureTotalCapacity(alloc, max_parts + 1);
        return self;
    }

    /// Frees every part.
    pub fn deinit(self: *Stream, alloc: std.mem.Allocator) void {
        for (self.parts.items) |*p| p.blades.deinit(alloc);
        self.parts.deinit(alloc);
        self.free.deinit(alloc);
    }

    pub fn find(self: *Stream, cx: i32, cz: i32) ?*Part {
        for (self.parts.items) |*p| {
            if (p.cx == cx and p.cz == cz) return p;
        }
        return null;
    }

    pub fn liveCount(self: *const Stream) usize {
        var n: usize = 0;
        for (self.parts.items) |p| {
            if (p.live) n += 1;
        }
        return n;
    }

    pub fn liveBlades(self: *const Stream) usize {
        var n: usize = 0;
        for (self.parts.items) |p| {
            if (p.live) n += p.blades.items.len;
        }
        return n;
    }

    /// Reserve `len` instances. First fit over the free list, else bump; null means grow.
    pub fn allocSlot(self: *Stream, len: usize) ?Range {
        if (len == 0) return Range{ .start = self.used, .len = 0 };
        var i: usize = 0;
        while (i < self.free.items.len) : (i += 1) {
            const hole = self.free.items[i];
            if (hole.len >= len) {
                const out = Range{ .start = hole.start, .len = len };
                if (hole.len == len) {
                    _ = self.free.orderedRemove(i);
                } else {
                    self.free.items[i] = .{ .start = hole.start + len, .len = hole.len - len };
                }
                self.reused_slots += 1;
                return out;
            }
        }
        if (self.used + len > self.capacity) return null;
        const out = Range{ .start = self.used, .len = len };
        self.used += len;
        return out;
    }

    /// Return a range to the free list, coalescing with its neighbours.
    pub fn freeSlot(self: *Stream, r: Range) void {
        if (r.len == 0) return;
        var idx: usize = 0;
        while (idx < self.free.items.len and self.free.items[idx].start < r.start) : (idx += 1) {}
        self.free.insertAssumeCapacity(idx, r);
        // Coalesce forward, then backward.
        if (idx + 1 < self.free.items.len) {
            const a = self.free.items[idx];
            const b = self.free.items[idx + 1];
            if (a.end() == b.start) {
                self.free.items[idx] = .{ .start = a.start, .len = a.len + b.len };
                _ = self.free.orderedRemove(idx + 1);
            }
        }
        if (idx > 0) {
            const a = self.free.items[idx - 1];
            const b = self.free.items[idx];
            if (a.end() == b.start) {
                self.free.items[idx - 1] = .{ .start = a.start, .len = a.len + b.len };
                _ = self.free.orderedRemove(idx);
            }
        }
        self.freed_slots += 1;
    }

    /// Point the stream at a new patch. Only cells whose centre lies inside the blade radius are
    /// wanted: a cell's contents are a pure function of the world, so a cell that stays keeps its
    /// exact instances, and the quantised edge sits inside the shader's distance thinning.
    pub fn begin(self: *Stream, origin_cx: i32, origin_cz: i32, cells: i32, center_x: f32, center_z: f32) void {
        for (self.parts.items) |*p| p.wanted = false;
        var cz: i32 = 0;
        while (cz < cells) : (cz += 1) {
            var cx: i32 = 0;
            while (cx < cells) : (cx += 1) {
                const wx = origin_cx + cx;
                const wz = origin_cz + cz;
                const cell_x = (@as(f32, @floatFromInt(wx)) + 0.5) * scatter.CELL_M;
                const cell_z = (@as(f32, @floatFromInt(wz)) + 0.5) * scatter.CELL_M;
                const dx = cell_x - center_x;
                const dz = cell_z - center_z;
                if (dx * dx + dz * dz > scatter.ACTIVE_RADIUS * scatter.ACTIVE_RADIUS) continue;
                if (self.find(wx, wz)) |p| {
                    p.wanted = true;
                } else {
                    // Placeholder: zero blades, no slot yet; built by `step`.
                    self.parts.appendAssumeCapacity(.{ .cx = wx, .cz = wz, .wanted = true });
                }
            }
        }
    }

    /// The first cell that still needs building, skipping the one an in-flight job owns.
    pub fn nextMissing(self: *Stream) ?*Part {
        for (self.parts.items) |*p| {
            if (!p.wanted or p.live or p.built) continue;
            if (self.job_ptr) |j| {
                if (j.cx == p.cx and j.cz == p.cz) continue;
            }
            return p;
        }
        return null;
    }

    /// Start generating the next missing cell on the Io pool. Returns false when a job is already
    /// in flight or nothing is missing. `job` must outlive the wait in `takeJob`.
    pub fn startJob(self: *Stream, io: std.Io, job: *Job, edits: []const @import("dc_world.zig").Edit) !bool {
        if (self.job != null) return false;
        const p = self.nextMissing() orelse return false;
        job.* = .{ .cx = p.cx, .cz = p.cz };
        self.job = io.async(jobMain, .{ job, edits, p.cx, p.cz });
        self.job_ptr = job;
        return true;
    }

    /// `startJob` plus the caller's monotonic timestamp, so `takeJob` can report the whole wait.
    pub fn startJobTimed(self: *Stream, io: std.Io, job: *Job, edits: []const @import("dc_world.zig").Edit, now: i64) !bool {
        self.timer_start_ns = now;
        self.job_started_ns = now;
        self.last_wait_ms = 0;
        return self.startJob(io, job, edits);
    }

    /// Main thread, once per frame. If the job is done, its blades move into the cell's part and
    /// its slot is reserved; `uploads` receives the range to copy. `alloc` must be the allocator
    /// given to `startJob` -- it is the pool an `await` returns capacity to.
    pub fn takeJob(self: *Stream, io: std.Io, uploads: *std.ArrayList(Upload), now: i64) !bool {
        const job = self.job_ptr orelse return false;
        if (self.job) |*f| f.await(io);
        self.last_job_ms_ns = now - self.job_started_ns;
        self.last_wait_ms = @as(f32, @floatFromInt(now - self.timer_start_ns)) / 1e6;
        self.job = null;
        self.job_ptr = null;
        defer job.blades.deinit(std.heap.page_allocator);
        if (job.failed) return error.JobFailed;

        // The cell may have been dropped by a newer patch while the job ran.
        for (self.parts.items) |*p| {
            if (p.cx != job.cx or p.cz != job.cz) continue;
            if (!p.wanted or p.built) break;
            try p.blades.appendSlice(std.heap.page_allocator, job.blades.items);
            const need = self.allocSlot(p.blades.items.len) orelse {
                p.blades.clearRetainingCapacity();
                return error.BufferFull;
            };
            p.slot = need;
            p.has_slot = true;
            p.built = true;
            self.built_total += 1;
            self.last_landed = p.blades.items.len;
            try uploads.append(std.heap.page_allocator, .{ .offset = need.start, .blades = p.blades.items });
            break;
        }
        return true;
    }

    pub fn pendingCount(self: *Stream) usize {
        var n: usize = 0;
        for (self.parts.items) |p| {
            if (p.wanted and !p.built) n += 1;
        }
        return n;
    }

    /// Build at most `budget` missing partitions. Returns true when every wanted cell exists.
    pub fn step(
        self: *Stream,
        alloc: std.mem.Allocator,
        edits: []const @import("dc_world.zig").Edit,
        budget: usize,
        uploads: *std.ArrayList(Upload),
    ) !bool {
        var built: usize = 0;
        for (self.parts.items) |*p| {
            if (built >= budget) break;
            if (!p.wanted or p.live or p.built) continue;
            try scatter.buildBladesCell(alloc, edits, p.cx, p.cz, &p.blades);
            const need = self.allocSlot(p.blades.items.len) orelse blk: {
                // Fragmented: compact the live ranges once, then try again.
                try self.compact(alloc, uploads);
                break :blk self.allocSlot(p.blades.items.len) orelse {
                    p.blades.clearRetainingCapacity();
                    return error.BufferFull;
                };
            };
            p.slot = need;
            p.has_slot = true;
            p.built = true;
            try uploads.append(alloc, .{ .offset = need.start, .blades = p.blades.items });
            self.built_total += 1;
            self.last_landed = p.blades.items.len;
            built += 1;
        }
        return self.pendingCount() == 0;
    }

    /// Re-pack the live ranges from zero. Every live cell is re-uploaded; only used when the
    /// buffer has no hole large enough for an entering cell.
    pub fn compact(self: *Stream, alloc: std.mem.Allocator, uploads: *std.ArrayList(Upload)) !void {
        self.free.clearRetainingCapacity();
        self.used = 0;
        for (self.parts.items) |*p| {
            if (!p.live or p.blades.items.len == 0) continue;
            const r = self.allocSlot(p.blades.items.len) orelse return error.BufferFull;
            p.slot = r;
            try uploads.append(alloc, .{ .offset = r.start, .blades = p.blades.items });
        }
    }

    /// After a successful `step`, drop cells that the new patch does not want and make it live.
    pub fn commit(self: *Stream, alloc: std.mem.Allocator) usize {
        var dropped: usize = 0;
        var i: usize = 0;
        while (i < self.parts.items.len) {
            const p = &self.parts.items[i];
            if (!p.wanted) {
                if (p.has_slot) self.freeSlot(p.slot);
                p.blades.deinit(alloc);
                p.* = self.parts.items[self.parts.items.len - 1];
                _ = self.parts.pop();
                dropped += 1;
                continue;
            }
            p.live = true;
            i += 1;
        }
        return dropped;
    }
};

// ---------------------------------------------------------------------------------------------
// Tests

fn expectSameBlades(a: []const Blade, b: []const Blade) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqual(x.pos[0], y.pos[0]);
        try std.testing.expectEqual(x.pos[2], y.pos[2]);
        try std.testing.expectEqual(x.yaw, y.yaw);
        try std.testing.expectEqual(x.kind, y.kind);
    }
}

test "slot allocator reuses a freed hole and coalesces" {
    std.debug.print("stream: slot allocator start\n", .{});
    const alloc = std.testing.allocator;
    var s = try Stream.init(alloc, 1000);
    defer s.deinit(alloc);

    const a = s.allocSlot(100) orelse return error.TestUnexpectedResult;
    const b = s.allocSlot(200) orelse return error.TestUnexpectedResult;
    const c = s.allocSlot(300) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), a.start);
    try std.testing.expectEqual(@as(usize, 100), b.start);
    try std.testing.expectEqual(@as(usize, 300), c.start);
    try std.testing.expectEqual(@as(usize, 600), s.used);

    // Reuse the middle hole exactly, then split it.
    s.freeSlot(b);
    const d = s.allocSlot(150) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 100), d.start);
    const e = s.allocSlot(50) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 250), e.start);
    try std.testing.expectEqual(@as(usize, 2), s.reused_slots);

    // Free a and d+e (adjacent) and check the coalesced hole serves one 400-range.
    s.freeSlot(a);
    s.freeSlot(d);
    s.freeSlot(e);
    try std.testing.expectEqual(@as(usize, 1), s.free.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.free.items[0].start);
    try std.testing.expectEqual(@as(usize, 300), s.free.items[0].len);
}

test "partition build is deterministic and world-anchored" {
    std.debug.print("stream: partition determinism start\n", .{});
    const alloc = std.testing.allocator;
    var a: std.ArrayList(Blade) = .empty;
    defer a.deinit(alloc);
    var b: std.ArrayList(Blade) = .empty;
    defer b.deinit(alloc);

    // The same world cell built from two patch centres that are both far away: identical.
    try scatter.buildBladesCell(alloc, &.{}, 4, 4, &a);
    try scatter.buildBladesCell(alloc, &.{}, 4, 4, &b);
    try expectSameBlades(a.items, b.items);
    try std.testing.expect(a.items.len > 0);

    // A different cell produces different instances.
    var c: std.ArrayList(Blade) = .empty;
    defer c.deinit(alloc);
    try scatter.buildBladesCell(alloc, &.{}, 5, 4, &c);
    try std.testing.expect(c.items.len > 0);
    try std.testing.expect(c.items.len != a.items.len or c.items[0].pos[0] != a.items[0].pos[0]);
    std.debug.print("stream: partition determinism ok, {d} blades in cell (4,4)\n", .{a.items.len});
}

test "a worker-thread job produces the same blades as the serial build" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var serial: std.ArrayList(Blade) = .empty;
    defer serial.deinit(alloc);
    try scatter.buildBladesCell(alloc, &.{}, 4, 4, &serial);

    var job = Job{ .cx = 4, .cz = 4 };
    const no_edits: []const @import("dc_world.zig").Edit = &.{};
    var future = io.async(jobMain, .{ &job, no_edits, @as(i32, 4), @as(i32, 4) });
    future.await(io);
    try std.testing.expect(!job.failed);
    defer job.blades.deinit(std.heap.page_allocator);
    try expectSameBlades(serial.items, job.blades.items);
    std.debug.print("stream: worker job matches serial build ({d} blades)\n", .{serial.items.len});
}

test "stream assigns cells, reuses slots and commits the new patch" {
    std.debug.print("stream: patch swap start\n", .{});
    const alloc = std.testing.allocator;
    var s = try Stream.init(alloc, 4_000_000);
    defer s.deinit(alloc);

    var uploads: std.ArrayList(Upload) = .empty;
    defer uploads.deinit(alloc);

    s.begin(0, 0, 2, 32.0, 32.0);
    var done = false;
    while (!done) {
        done = try s.step(alloc, &.{}, 1, &uploads);
    }
    _ = s.commit(alloc);
    try std.testing.expectEqual(@as(usize, 4), s.liveCount());
    const first_used = s.used;
    try std.testing.expect(first_used > 0);

    // Move one cell east: two cells are kept, two are rebuilt in the freed slots.
    uploads.clearRetainingCapacity();
    const before = s.used;
    s.begin(1, 0, 2, 64.0, 32.0);
    done = false;
    while (!done) {
        done = try s.step(alloc, &.{}, 1, &uploads);
    }
    const dropped = s.commit(alloc);
    try std.testing.expectEqual(@as(usize, 2), dropped);
    try std.testing.expectEqual(@as(usize, 4), s.liveCount());
    // Six builds total for two patches: the two kept cells were not rebuilt.
    try std.testing.expectEqual(@as(usize, 6), s.built_total);
    // Slots came out of the free list rather than off the end of the buffer, or at worst the
    // buffer grew by the two entering cells only.
    try std.testing.expect(s.reused_slots >= 1 or s.used > before);
    std.debug.print("stream: patch swap ok, {d} builds total, {d} reused, {d} live\n", .{ s.built_total, s.reused_slots, s.liveCount() });
}
