//! Required `builtin` interface — Runtime §4.
//!
//! Every execution context automatically provides a `builtin` module
//! (Runtime §3.2, Core §3). `builtin` is the only implicitly available
//! module binding and cannot be shadowed. The interface the host must
//! implement is defined in Runtime §4.
//!
//! The Stilla-level signatures below are normative; the Zig `VTable`
//! mirrors them for the primitives the runtime needs from the host. The
//! `userdata` pointer is passed through to every function so an embedding
//! host can reach its own state without global variables.

const std = @import("std");
const panic = @import("panic.zig");

/// Host implementation of the required `builtin` interface.
pub const VTable = struct {
    /// `builtin.print: fn(string) -> void` — Runtime §4.1.
    ///
    /// Outputs a line of text to the host's standard output.
    print: *const fn (userdata: *const anyopaque, message: []const u8) void = defaultPrint,

    /// `builtin.len[T]: fn(borrow list[T]) -> int64` — Runtime §4.3.
    ///
    /// The list is borrowed and never consumed. The `count` / `elem_size`
    /// pair describes the borrowed list storage.
    len: *const fn (userdata: *const anyopaque, count: usize, elem_size: usize) i64 = defaultLen,

    /// `builtin.panic: fn(string) -> never` — Runtime §4.9.
    ///
    /// Terminates the current execution context immediately; no unwinding
    /// (Runtime §7.1). The returned `panic.Termination` lets the
    /// interpreter propagate control back to the host.
    panic: *const fn (userdata: *const anyopaque, message: []const u8) panic.Termination = defaultPanic,

    // TODO(runtime): the remaining §4 interface — list construction and
    // access, box `peek` / `unbox` (Runtime §4.8), and the trap-raising
    // conversion primitives (Runtime §7.2).
};

fn defaultPrint(_: *const anyopaque, message: []const u8) void {
    std.debug.print("{s}\n", .{message});
}

fn defaultLen(_: *const anyopaque, count: usize, _: usize) i64 {
    return @intCast(count);
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
            const c: *Capture = @alignCast(@ptrCast(@constCast(userdata)));
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

    try std.testing.expect(vt.len(&userdata, 3, 8) == 3);

    const t = vt.panic(&userdata, "boom");
    try std.testing.expect(t == .panic);
    try std.testing.expectEqualStrings("boom", t.panic.message);
}
