//! Test file: `builtin` — the required `builtin` interface (Runtime §4).
//!
//! White-box tests of `src/builtin.zig`'s own internals stay in that
//! module's file; this file aggregates them so they are analyzed and run.

const std = @import("std");
const testing = std.testing;

test {
    // White-box tests of the module file in this slice.
    _ = @import("builtin.zig");
}
