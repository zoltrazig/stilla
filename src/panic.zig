//! Termination and traps — Runtime §7.
//!
//! Stilla v1.3 defines **no exception-style or destructor-style unwinding**
//! for panic or runtime traps (Runtime §7.1). Once a panic or trap occurs:
//!
//! - no enclosing Stilla statements resume;
//! - no pending automatic destruction of live locals or temporaries runs;
//! - no pending module teardown runs;
//! - no additional user `drop` hook is invoked as a consequence.
//!
//! Control returns immediately to the embedding host, which is responsible
//! for disposing of the terminated execution context.

const std = @import("std");

/// A Stilla panic or runtime trap (Runtime §7.1, §7.2).
pub const Panic = struct {
    /// Message supplied to `builtin.panic`, or a runtime-generated trap
    /// description (overflow, division by zero, invalid indexing, invalid
    /// conversion — Runtime §7.2).
    message: []const u8,

    // TODO(runtime): record the trap site (module / function) once the
    // interpreter exists.
};

/// How control returns from a context to the embedding host (Runtime §3.4).
pub const Termination = union(enum) {
    /// Normal termination, after module teardown in reverse initialization
    /// order (Runtime §2.5).
    normal,
    /// Termination by panic or runtime trap; the host must dispose of the
    /// terminated context (Runtime §7.1).
    panic: Panic,
};

test "Panic.Termination normal variant" {
    const t: Termination = .normal;
    try std.testing.expect(std.meta.eql(t, Termination.normal));
}

test "Panic.Termination panic variant carries a message" {
    const t: Termination = .{ .panic = .{ .message = "boom" } };
    try std.testing.expect(t == .panic);
    try std.testing.expectEqualStrings("boom", t.panic.message);
}
