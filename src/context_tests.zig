//! Test file: `context` — the execution context (Runtime §1.3, §2, §8).
//!
//! White-box tests of `src/context.zig`'s own internals stay in that
//! module's file; this file aggregates them so they are analyzed and run.

const std = @import("std");
const testing = std.testing;

test {
    // White-box tests of the module file in this slice.
    _ = @import("context.zig");
}
