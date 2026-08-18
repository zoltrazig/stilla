//! Required `builtin` interface — Runtime §4.
//!
//! `builtin` is an ordinary importable standard-library module (Core §3):
//! a program brings it into scope like any other module, e.g.
//! `const builtin = import("builtin");`. There is no implicit module
//! binding and no reserved word. The interface the host must implement is
//! defined in Runtime §4; the Stilla-level signatures live in
//! `std/builtin.st`.
//!
//! The Stilla-level signatures below are normative; the Zig `VTable`
//! mirrors them for the primitives the runtime needs from the host. The
//! `userdata` pointer is passed through to every function so an embedding
//! host can reach its own state without global variables.

const std = @import("std");
const panic = @import("panic.zig");

/// Host implementation of the required `builtin` interface.
pub const VTable = struct {
    /// `builtin.print: fn(str) -> void` — Runtime §4.1.
    ///
    /// Outputs a line of text to the host's standard output.
    print: *const fn (userdata: *const anyopaque, message: []const u8) void = defaultPrint,

    /// `builtin.panic: fn(str) -> never` — Runtime §4.9.
    ///
    /// Terminates the current execution context immediately; no unwinding
    /// (Runtime §7.1). The returned `panic.Termination` lets the
    /// interpreter propagate control back to the host.
    panic: *const fn (userdata: *const anyopaque, message: []const u8) panic.Termination = defaultPanic,

    // TODO(runtime): the remaining §4 interface — conversion `str`,
    // box `peek` / `unbox` (Runtime §4.8), `assert`, `hash`, and the
    // trap-raising conversion primitives (Runtime §7.2).
    // List length and integer range moved out of `builtin` into the
    // standard-library `list` module (`list.len` Runtime §4.3,
    // `list.range` Runtime §4.4): they dispatch as the `list#len` /
    // `list#range` host-module system calls, not through this vtable.
};

fn defaultPrint(_: *const anyopaque, message: []const u8) void {
    std.debug.print("{s}\n", .{message});
}

fn defaultPanic(_: *const anyopaque, message: []const u8) panic.Termination {
    return .{ .panic = .{ .message = message } };
}

test "builtin.VTable routes calls through userdata" {
    // Exercise the vtable indirection without touching real stdout (the Zig
    // 0.16 build runner mis-renders progress when a test writes to stderr).
    const Capture = struct {
        buffer: [16]u8 = undefined,
        len: usize = 0,
    };
    var state = Capture{};

    const capture_fn = struct {
        fn capture(userdata: *const anyopaque, message: []const u8) void {
            const c: *Capture = @ptrCast(@alignCast(@constCast(userdata)));
            @memcpy(c.buffer[c.len..][0..message.len], message);
            c.len += message.len;
        }
    }.capture;

    var vt: VTable = .{ .print = capture_fn };
    const userdata: *Capture = &state;

    vt.print(userdata, "captured");
    try std.testing.expectEqualStrings("captured", state.buffer[0..state.len]);
}

test "builtin.VTable supplies default implementations" {
    const vt: VTable = .{};
    var userdata: u8 = 0;

    const t = vt.panic(&userdata, "boom");
    try std.testing.expect(t == .panic);
    try std.testing.expectEqualStrings("boom", t.panic.message);
}

test "builtin.VTable defaultPanic returns the message" {
    const vt: VTable = .{};
    var userdata: u8 = 0;
    const t = vt.panic(&userdata, "kaboom");
    try std.testing.expect(t == .panic);
    try std.testing.expectEqualStrings("kaboom", t.panic.message);
}

test "builtin.VTable defaultPrint is overridable per host" {
    // Runtime §3.4: host cleanup/integration is per-embedding; the print
    // sink is replaceable.
    const Capture = struct {
        buffer: [32]u8 = undefined,
        len: usize = 0,
    };
    var state = Capture{};
    const capture_fn = struct {
        fn capture(userdata: *const anyopaque, message: []const u8) void {
            const c: *Capture = @ptrCast(@alignCast(@constCast(userdata)));
            @memcpy(c.buffer[c.len..][0..message.len], message);
            c.len += message.len;
        }
    }.capture;

    var vt: VTable = .{ .print = capture_fn };
    vt.print(&state, "hello");
    try std.testing.expectEqualStrings("hello", state.buffer[0..state.len]);
}
