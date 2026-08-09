//! Host environment — Runtime §3.
//!
//! The embedding host:
//!
//! - creates the execution context (§3);
//! - registers host-provided modules (§3.1);
//! - provides the required `builtin` interface (§3.2, §4) that programs
//!   reach by importing the standard-library `builtin` module (Core §3);
//! - invokes entry points (§3.3);
//! - receives control back on normal termination or panic (§3.4) and
//!   disposes of the terminated context and any host-owned resources.
//!
//! Host cleanup is outside Stilla source semantics and must not be
//! described as execution of Stilla `drop` hooks (Runtime §3.4).

const std = @import("std");
const builtin = @import("builtin.zig");
const panic = @import("panic.zig");

/// The embedding-host contract (Runtime §3).
pub const Host = struct {
    /// Allocator the runtime uses for context-owned storage.
    allocator: std.mem.Allocator,

    /// Required `builtin` interface implementation (Runtime §3.2, §4).
    builtin: builtin.VTable = .{},

    /// Opaque host state passed to every builtin call.
    userdata: *const anyopaque = undefined,

    // TODO(runtime): host-provided module registry (§3.1) and the
    // load-time resolution process (Runtime §2.6, Core §2.4): a specifier
    // resolves to exactly one of a Stilla source module, a standard-library
    // module, or a host-provided module.
    //
    // TODO(runtime): entry-point convention (Runtime §3.3) — a standalone
    // runtime conventionally loads an entry module and invokes
    // `entry.main()`; an embedding host may directly invoke any exposed
    // module function.
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "host.Host carries an allocator and a default builtin vtable" {
    // Runtime §3: the embedding host creates the execution context and
    // provides the required `builtin` interface (§3.2, §4).
    const host: Host = .{ .allocator = testing.allocator };
    try testing.expect(host.allocator.ptr == testing.allocator.ptr);
    // The vtable defaults are always present (Runtime §4).
    _ = host.builtin.print;
    _ = host.builtin.len;
    _ = host.builtin.panic;
}

test "host.Host forwards userdata to builtin calls" {
    // Runtime §3.4: control returns to the host; userdata reaches every
    // builtin call so the host can reach its own state.
    const marker: u8 = 42;
    var host: Host = .{ .allocator = testing.allocator, .userdata = &marker };
    try testing.expect(@intFromPtr(host.userdata) == @intFromPtr(&marker));

    // The default builtin implementations accept any userdata.
    const len = host.builtin.len(host.userdata, 7, 4);
    try testing.expectEqual(@as(i64, 7), len);
}

test "host.Host lets an embedding replace the panic handler" {
    // Runtime §3.4: the host receives control back on panic; a custom
    // handler observes the message and the host state.
    const State = struct {
        message: [64]u8 = undefined,
        len: usize = 0,
        saw_userdata: bool = false,
    };
    var state = State{};
    const panic_fn = struct {
        fn handler(userdata: *const anyopaque, message: []const u8) panic.Termination {
            const s: *State = @ptrCast(@alignCast(@constCast(userdata)));
            @memcpy(s.message[0..message.len], message);
            s.len = message.len;
            s.saw_userdata = true;
            return .{ .panic = .{ .message = message } };
        }
    }.handler;

    var host: Host = .{ .allocator = testing.allocator, .userdata = &state };
    host.builtin.panic = panic_fn;

    const t = host.builtin.panic(&state, "boom");
    try testing.expectEqualStrings("boom", state.message[0..state.len]);
    try testing.expect(state.saw_userdata);
    try testing.expectEqualStrings("boom", t.panic.message);
}

test "host.Host print sink writes through userdata" {
    // Runtime §3.2: builtin.print is the required output surface; an
    // embedding may capture it instead of writing to a real terminal.
    const Capture = struct {
        buf: [32]u8 = undefined,
        len: usize = 0,
    };
    var cap = Capture{};
    const print_fn = struct {
        fn print(userdata: *const anyopaque, message: []const u8) void {
            const c: *Capture = @ptrCast(@alignCast(@constCast(userdata)));
            @memcpy(c.buf[c.len..][0..message.len], message);
            c.len += message.len;
        }
    }.print;

    var host: Host = .{ .allocator = testing.allocator, .userdata = &cap };
    host.builtin.print = print_fn;
    host.builtin.print(&cap, "hi");
    host.builtin.print(&cap, " there");
    try testing.expectEqualStrings("hi there", cap.buf[0..cap.len]);
}
