//! Standard-library bundle (phase1-module-graph.md, Loading, parsing, and deduplication): the `std/` host-binding
//! modules, embedded at compile time.
//!
//! The standard library is a set of ordinary importable modules (StdLib
//! §1). Resolution loads them like source modules *from the
//! implementation's standard-library bundle* (phase1-module-graph.md, Loading, parsing, and deduplication). These files
//! are declaration-only host-binding modules (phase3-cfg-lowering.md, System calls for host bindings): every
//! function member has a signature and no Stilla definition, every
//! constant has a declared type and no initializer, and the frontend
//! lowers calls to them as system calls. `builtin` is one of these modules
//! and is imported like any other (Core §3).
//!
//! The current checker does not yet instantiate the bundle into the module
//! graph; host bindings are flagged by the placeholder checker
//! (`src/passes/checker.zig`), mirroring the declarations here. The black-box
//! tests in `post_module_ast_tests.zig` guarantee the bundle stays
//! parseable and type-checks as host bindings.

/// The `std/*.st` sources, embedded by the `stilla_std_sources` leaf module
/// (see build.zig and std/bundle.zig).
const sources = @import("stilla_std_sources");

/// The standard-library bundle: resolved specifier → source text.
pub const Module = struct {
    /// The written specifier a program imports (StdLib §1).
    specifier: []const u8,
    source: []const u8,
};

pub const modules = [_]Module{
    .{ .specifier = "builtin", .source = sources.builtin },
    .{ .specifier = "math", .source = sources.math },
    .{ .specifier = "string", .source = sources.string },
    .{ .specifier = "array", .source = sources.array },
    .{ .specifier = "hashmap", .source = sources.hashmap },
    .{ .specifier = "iter", .source = sources.iter },
    .{ .specifier = "list", .source = sources.list },
};
