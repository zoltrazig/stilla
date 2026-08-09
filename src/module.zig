//! Module instantiation and storage — Runtime §2.
//!
//! A module is instantiated **at most once per execution context**
//! (Runtime §2.1). Module storage is immutable after initialization (§2.2)
//! and its lifetime extends until the execution context ends. Module
//! constants are initialized strictly in declaration order (§2.3); teardown
//! destroys module-owned affine constants in reverse initialization order
//! (§2.5).

const std = @import("std");

/// An import specifier as written in Stilla source, e.g. `"math"` or
/// `"./utils"` (Core §2.4). Resolution must be unambiguous before
/// execution (Runtime §2.6, Core §2.4).
pub const Specifier = []const u8;

/// Immutable storage of one instantiated module (Runtime §2.2).
pub const Module = struct {
    /// The resolved specifier that produced this module.
    specifier: Specifier,

    // TODO(runtime): module-scope constant storage. Module values follow
    // the same immutable record/member-access model as structs (Runtime
    // §2.2, Core §7, §15); there is no separate runtime `module` type.
    //
    // TODO(runtime): teardown of module-owned affine constants in reverse
    // initialization order (Runtime §2.5).
};

/// Instantiated modules of one execution context, keyed by specifier
/// (Runtime §2.1 — each specifier is instantiated at most once).
pub const Registry = std.StringArrayHashMapUnmanaged(Module);

test "module.Registry keys modules by specifier" {
    var reg: Registry = .{};
    defer reg.deinit(std.testing.allocator);

    try reg.put(std.testing.allocator, "math", .{ .specifier = "math" });
    try std.testing.expect(reg.contains("math"));
    try std.testing.expect(!reg.contains("text"));
}
