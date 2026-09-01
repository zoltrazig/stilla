//! Host-embedding example (README, "Defining host functions"): the
//! embedder provides a `random` host module — one `pub fn` per member,
//! module state injected as the leading `*Rng` parameter — and a Stilla
//! program calls it through the ordinary `import("random")` path. Run
//! with `zig build embed`.
//!
//! The flow: the module struct (`host_bind.register` derives the
//! sorted, signature-checked member table at comptime; the typed
//! binding casts the registered userdata to `*Rng`, so members read
//! their state directly) + `host_bind.interfaceOf` derives the `.st`
//! interface text the frontend checks call sites against, and
//! `interpreter.buildProgram` compiles and lowers (merging the module
//! into the default host registry), then `interpreter.runProgram`
//! executes the built program.

const std = @import("std");
const stilla = @import("stilla");

const host_bind = stilla.interpreter.host_bind;

/// The module's state: injected as the leading `*Rng` parameter of
/// every member (never a Stilla parameter).
const Rng = struct {
    prng: std.Random.DefaultPrng,
    /// The embedding's Io, so `time()` can read the host clock.
    io: std.Io,
    draws: [2]i32 = undefined,
    count: usize = 0,
    /// Observed for the report: the clock value `time()` returned and
    /// the last seed the program pushed in.
    last_time: i32 = 0,
    last_seed: i32 = 0,

    fn record(self: *Rng, v: i32) void {
        if (self.count < self.draws.len) {
            self.draws[self.count] = v;
            self.count += 1;
        }
    }
};

/// The host module: `pub const symbol` names the module; every `pub fn`
/// is a member binding. Members take the module state as a leading
/// `*Rng` parameter (never a Stilla parameter).
const random = struct {
    pub const symbol = "random";

    /// Full-width i32 draw.
    pub fn next(rng: *Rng) i32 {
        const v = rng.prng.random().int(i32);
        rng.record(v);
        return v;
    }

    /// Uniform draw in [0, max).
    pub fn int(rng: *Rng, max: i32) i32 {
        const v = rng.prng.random().intRangeLessThan(i32, 0, max);
        rng.record(v);
        return v;
    }

    /// Reseed the module's PRNG — module state mutated from Stilla.
    pub fn seed(rng: *Rng, s: i32) void {
        rng.last_seed = s;
        rng.prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(@as(i64, s))));
    }

    /// Host time (seconds since the Unix epoch, truncated to i32):
    /// host-side information flowing into the program. The module reads
    /// the clock through the embedding's Io (std.Io.Clock.real).
    pub fn time(rng: *Rng) i32 {
        const ts = std.Io.Clock.now(.real, rng.io);
        const secs: i64 = @truncate(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
        rng.last_time = @truncate(secs);
        return rng.last_time;
    }
};
const random_desc: host_bind.ModuleDesc = host_bind.register(random);

/// The interface — the compile-time contract the frontend checks the
/// app's call sites against — derived from the module struct's Zig
/// signatures, so the two can't drift (host_bind.interfaceOf).
const random_iface = host_bind.interfaceOf(random, "");

/// The `builtin.print` output hook: `print` has no runtime default, so
/// the embedder supplies one. Here the program's output goes to this
/// process's stdout through the embedding's Io — message + line ending.
const PrintSink = struct { io: std.Io };
fn appPrint(userdata: ?*anyopaque, bytes: []const u8) void {
    const sink: *PrintSink = @ptrCast(@alignCast(userdata.?));
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), sink.io, "> ") catch return;
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), sink.io, bytes) catch return;
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), sink.io, "\n") catch {};
}

/// The Stilla side: `random` is an ordinary imported module; each call
/// lowers to a syscall dispatched through the registry. The program
/// prints each step through the host-supplied `builtin.print` hook.
const APP =
    \\const random = import("random");
    \\const builtin = import("builtin");
    \\fn main() -> int32 {
    \\    random.seed(random.time());
    \\    let a = random.next();
    \\    let b = random.int(6);
    \\    builtin.print("draw a");
    \\    builtin.print(builtin.str(a));
    \\    builtin.print("draw b");
    \\    builtin.print(builtin.str(b));
    \\    builtin.print("sum");
    \\    builtin.print(builtin.str(a + b));
    \\    a + b
    \\}
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var rng = Rng{ .prng = std.Random.DefaultPrng.init(0x5eed), .io = io };
    // The program's output sink (the `builtin.print` hook's userdata).
    var print_sink = PrintSink{ .io = io };

    // compile, lower, and run share one arena (the frontend's Compilation
    // owns its own arena; the artifact bundle and the merged registry
    // are released with the arena below — same shape as main.zig).
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The two-stage embed path: build once, run — source + interface +
    // module → compile, lower, and merge the host registry. On a
    // compile failure the failed compilation comes back through
    // `failed` for its diagnostic.
    var failed: stilla.frontend.Compilation = undefined;
    var built = stilla.interpreter.buildProgram(arena, .{
        .entry = "app",
        .sources = &.{.{ .specifier = "app", .text = APP }},
        .ifaces = &.{.{ .specifier = "random", .text = random_iface }},
        .modules = &.{.{ .desc = &random_desc, .userdata = &rng }},
        .entry_fn = "main",
        .print = .{ .userdata = &print_sink, .invoke = appPrint },
    }, &failed) catch |err| switch (err) {
        error.CompileFailed => {
            if (failed.diag) |d| {
                try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, d.message);
                try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "\n");
            }
            return error.CompileFailed;
        },
        else => return err,
    };

    const term = try stilla.interpreter.runProgram(arena, &built);

    // report: the clock value and seed the program used, the draws it
    // pulled from the host, and the value it computed (the round trip).
    switch (term) {
        .normal => |cell| {
            const sum = stilla.vm_types.ValueCodec.decodeInt32(cell) orelse 0;
            if (sum != rng.draws[0] + rng.draws[1]) return error.RoundTripMismatch;
            var buf: [192]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "embed: time() = {d}, seeded {d}; random.next() = {d}, random.int(6) = {d}; app returned {d}\n", .{ rng.last_time, rng.last_seed, rng.draws[0], rng.draws[1], sum });
            try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, line);
        },
        .panic => |m| {
            try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "panic: ");
            try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, m);
            try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "\n");
            return error.RunPanicked;
        },
    }
}
