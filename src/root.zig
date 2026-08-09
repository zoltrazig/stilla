//! Stilla runtime — a Zig implementation of the Stilla v1.2 execution
//! model, as defined by the *Stilla Runtime Specification - v1.2 Draft*
//! in `spec/`.
//!
//! Status: early skeleton. The module layout mirrors the Runtime
//! specification's sections so that the long-term work has a home:
//!
//! - `context` — execution context (Runtime §1.3, §2, §8)
//! - `module`  — module instantiation and storage (Runtime §2)
//! - `host`    — host environment contract (Runtime §3)
//! - `builtin` — required `builtin` interface (Runtime §4)
//! - `panic`   — termination and traps (Runtime §7)
//!
//! See README.md for the roadmap.

const std = @import("std");

pub const builtin = @import("builtin.zig");
pub const context = @import("context.zig");
pub const host = @import("host.zig");
pub const module = @import("module.zig");
pub const panic = @import("panic.zig");

/// Version of this library.
pub const version = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 1 };

test {
    // Reference every public declaration so tests are wired into the
    // library's test step.
    std.testing.refAllDecls(@This());
}
