//! Simple-mode test runner for `zig build test`.
//!
//! The build system's default runner drives a test binary through the
//! `std.zig.Server` protocol so it can render a progress tree and aggregate
//! results. That protocol carries no timing, so this runner instead uses
//! `.mode = .simple`: it runs every test to completion and reports on
//! stderr, then communicates pass/fail through its exit code.
//!
//! The per-test environment — the testing allocator, testing I/O,
//! environment, log level, `error.SkipZigTest` handling, leak detection,
//! and error-log counting — mirrors the default terminal runner
//! (`lib/compiler/test_runner.zig`). The runner intentionally diverges in
//! output handling: it always prints a full line per test, never a
//! progress tree, and has no fuzz or server paths; it adds the per-test
//! wall-clock line and the slowest-tests table.

const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

const runner_io: Io = Io.Threaded.global_single_threaded.io();

/// One finished test's wall-clock sample. `index` disambiguates equal
/// durations so the slowest-tests table is deterministic.
const Timing = struct {
    index: usize,
    name: []const u8,
    ns: i96,
};

/// How many rows the slowest-tests table reports.
const max_reported: usize = 20;

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    mainTerminal(init);
}

fn mainTerminal(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;

    const timings = std.heap.page_allocator.alloc(Timing, test_fn_list.len) catch
        @panic("unable to allocate the test timing table");
    defer std.heap.page_allocator.free(timings);

    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) leaks += 1;
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        // Time only the test body: setup, teardown, and leak checks are
        // deliberately outside the measured interval.
        const t0 = Io.Clock.Timestamp.now(runner_io, .awake);
        const result = test_fn.func();
        const t1 = Io.Clock.Timestamp.now(runner_io, .awake);
        const ns: i96 = t0.durationTo(t1).raw.nanoseconds;
        timings[i] = .{ .index = i, .name = test_fn.name, .ns = ns };
        const ms = nanosecondsToMilliseconds(ns);

        if (result) |_| {
            ok_count += 1;
            std.debug.print("[{d}/{d}] {s} ... OK ({d:.2} ms)\n", .{
                i + 1, test_fn_list.len, test_fn.name, ms,
            });
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                std.debug.print("[{d}/{d}] {s} ... SKIP ({d:.2} ms)\n", .{
                    i + 1, test_fn_list.len, test_fn.name, ms,
                });
            },
            else => {
                fail_count += 1;
                std.debug.print("[{d}/{d}] {s} ... FAIL ({t}) ({d:.2} ms)\n", .{
                    i + 1, test_fn_list.len, test_fn.name, err, ms,
                });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }
    }

    if (ok_count == test_fn_list.len) {
        std.debug.print("All {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }

    printSlowest(timings);

    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

fn nanosecondsToMilliseconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn printSlowest(timings: []const Timing) void {
    if (timings.len == 0) return;
    const order = std.heap.page_allocator.alloc(usize, timings.len) catch
        @panic("unable to allocate the slowest-tests sort order");
    defer std.heap.page_allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, timings, slowerFirst);

    std.debug.print("slowest tests:\n", .{});
    for (order[0..@min(order.len, max_reported)]) |i| {
        const t = timings[i];
        std.debug.print("{d:.2} ms  {s}\n", .{ nanosecondsToMilliseconds(t.ns), t.name });
    }

    var total_ns: i96 = 0;
    for (timings) |t| total_ns += t.ns;
    std.debug.print("total measured test time {d:.2} ms\n", .{nanosecondsToMilliseconds(total_ns)});
}

fn slowerFirst(timings: []const Timing, a: usize, b: usize) bool {
    const ta = timings[a];
    const tb = timings[b];
    if (ta.ns != tb.ns) return ta.ns > tb.ns;
    return ta.index < tb.index;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
