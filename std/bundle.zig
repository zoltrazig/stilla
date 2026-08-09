//! Embedded standard-library sources — the `std/*.st` host-binding
//! modules, made importable to the `stilla` package via the
//! `stilla_std_sources` module (build.zig). This file lives in `std/` so
//! that `@embedFile` can reach its siblings (they are outside the `src/`
//! package root). See `src/stdbundle.zig` for the bundle table and tests.

pub const builtin = @embedFile("builtin.st");
pub const math = @embedFile("math.st");
pub const string = @embedFile("string.st");
pub const array = @embedFile("array.st");
pub const hashmap = @embedFile("hashmap.st");
pub const iter = @embedFile("iter.st");
