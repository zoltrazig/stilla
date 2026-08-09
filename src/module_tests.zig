//! Test file: `module` — module instantiation and storage (Runtime §2).
//!
//! White-box tests of `src/module.zig`'s own internals stay in that
//! module's file; this file aggregates them so they are analyzed and run.

const std = @import("std");
const testing = std.testing;

test {
    // White-box tests of the module file in this slice.
    _ = @import("module.zig");
}
