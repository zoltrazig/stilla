//! Execution context — Runtime §1.3, §2, §8.
//!
//! A Stilla program runs inside an **execution context**. The context:
//!
//! - is created by the embedding host (§3);
//! - owns all module storage (§2);
//! - instantiates standard-library modules — including `builtin` — on
//!   demand when a program imports them (Core §3);
//! - is the unit of panic termination (§7);
//! - is disposed of by the embedding host (§3.4).
//!
//! Whether multiple contexts may run concurrently is implementation-defined
//! (Runtime §1.3).

const std = @import("std");
const builtin = @import("builtin.zig");
const host = @import("host.zig");
const module = @import("module.zig");
const panic = @import("panic.zig");

/// A running Stilla program (Runtime §1.3).
pub const Context = struct {
    allocator: std.mem.Allocator,
    host: host.Host,
    modules: module.Registry = .{},

    pub fn init(allocator: std.mem.Allocator, host_env: host.Host) Context {
        return .{ .allocator = allocator, .host = host_env };
    }

    /// Dispose of the context and all module storage (Runtime §2.5, §3.4).
    pub fn deinit(self: *Context) void {
        self.modules.deinit(self.allocator);
    }

    // TODO(runtime): module instantiation (§2), entry-point invocation
    // (§3.3), deterministic evaluation order (§5), destruction at runtime
    // (§6), panic propagation (§7), and the core runtime model (§8).
};

test "context init and deinit" {
    var ctx = Context.init(std.testing.allocator, .{ .allocator = std.testing.allocator });
    defer ctx.deinit();

    try std.testing.expect(ctx.modules.count() == 0);
}

test "context owns module registry storage" {
    // Runtime §2.1: the registry is keyed by resolved specifier; storage
    // lives for the context lifetime (§2.2).
    var ctx = Context.init(std.testing.allocator, .{ .allocator = std.testing.allocator });
    defer ctx.deinit();

    try ctx.modules.put(std.testing.allocator, "math", .{ .specifier = "math" });
    try ctx.modules.put(std.testing.allocator, "string", .{ .specifier = "string" });
    try std.testing.expectEqual(@as(usize, 2), ctx.modules.count());
    // A second instantiation of the same specifier is the same storage
    // (Runtime §2.1: at most once per context).
    try std.testing.expect(ctx.modules.getPtr("math").?.specifier.len > 0);
}
