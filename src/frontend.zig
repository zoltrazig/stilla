//! Frontend pipeline driver — frontend.md §1–§3, §5.
//!
//! `compile` runs the whole frontend in one call: load and parse the
//! transitive closure of modules reachable from the entry point (phase 1,
//! `moduleinfo`), build the module graph with module-level annotation,
//! annotate and check every module (phase 2, `checker`), and lower every
//! module to the CFG IR (phase 3, `lower`). The output is a
//! `Compilation`: an arena owning everything, the phase-1 `ModuleGraph`,
//! and the phase-3 `cfg.IrProgram`.
//!
//! Diagnostics follow the first-error-wins convention: on failure the
//! error is `error.Diagnostic` and `Compilation.diag` holds the span and
//! message.

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const lower = @import("lower.zig");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const cfg_parse = @import("passes/cfg_parse.zig");

pub const CompileError = error{ OutOfMemory, Diagnostic };

/// Frontend inputs (frontend.md §2): the entry module and the resolution
/// policy. The embedded `std/` bundle is always available; `sources`
/// extends it.
pub const Options = struct {
    /// Written specifier of the entry module.
    entry: []const u8,
    /// Resolution policy: source modules, extra standard-library
    /// modules, and host-provided module specifiers. Caller-owned.
    sources: moduleinfo.Sources = .{},
    /// Optional host-selected entry function (the runtime convention is
    /// `main`, Runtime §3.3); when null the program has no entry.
    entry_fn: ?[]const u8 = null,
    /// True when `entry_fn` was explicitly requested by the user (vs. the
    /// `main` default): a missing explicitly-named entry is a diagnostic.
    entry_fn_explicit: bool = false,
    /// The embedding's Io, used to read source modules located through
    /// `sources.search_dirs`; null in embeddings that supply every module
    /// as in-memory text.
    io: ?std.Io = null,
    /// Run the mid-level optimizer (Passes 7–8) over the lowered CFG
    /// before returning (frontend.md §6): tail call elimination, constant
    /// folding, CSE, PRE, copy propagation, dead-block elimination, jump
    /// threading, phi simplification, and drop elision. Default off —
    /// embedders and tests keep the faithful raw CFG; the `stilla`
    /// executable enables it. The toggle is code-only (no CLI flag).
    optimize: bool = false,
};

/// The frontend's output: the arena, the phase-1 graph, and the phase-3
/// IR. On failure (`error.Diagnostic`) `graph`/`program` are null and
/// `diag` holds the first error.
pub const Compilation = struct {
    arena: std.heap.ArenaAllocator,
    graph: ?*moduleinfo.ModuleGraph,
    program: ?cfg.IrProgram = null,
    diag: ?moduleinfo.Diag = null,
    /// Every source loaded during phase 1, in creation order. Present
    /// even when `graph` is null (a parse failure): diagnostics can
    /// resolve their span against it for a file:line:col report.
    sources: []const *const ast.Source = &.{},

    pub fn deinit(self: *Compilation) void {
        // Everything is arena-owned; the arena frees it all at once.
        self.arena.deinit();
    }
};

/// Compile a program: entry module → IR (frontend.md §1, §5.7).
pub fn compile(allocator: std.mem.Allocator, options: Options) CompileError!Compilation {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // Phase 1: module graph (load, parse, annotate, sort).
    var builder = moduleinfo.Builder.init(arena_alloc, options.sources);
    builder.io = options.io;
    const graph = builder.build(options.entry) catch |err| switch (err) {
        error.Diagnostic, error.Syntax => {
            // Parse and module-graph errors carry a diagnostic.
            return Compilation{
                .arena = arena,
                .graph = null,
                .diag = builder.diag,
                .sources = builder.loaded_sources.items,
            };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Phase 2: annotation and checks (frontend §4).
    var ck = checker.Checker.init(arena_alloc);
    _ = ck.check(graph) catch |err| switch (err) {
        error.Diagnostic => {
            return Compilation{
                .arena = arena,
                .graph = graph,
                .diag = ck.diag,
                .sources = builder.loaded_sources.items,
            };
        },
        else => return err,
    };

    // Phase 3: CFG lowering.
    var lowerer = lower.Lowerer.init(arena_alloc, graph, options.entry_fn, options.entry_fn_explicit);
    var program = lower.lowerProgram(&lowerer) catch |err| switch (err) {
        error.Diagnostic => {
            return Compilation{
                .arena = arena,
                .graph = graph,
                .diag = lowerer.diag,
                .sources = builder.loaded_sources.items,
            };
        },
        else => return err,
    };

    // The ir.md §13 validator runs on every lowered program (Pass 6.1):
    // a lowering bug that violates structure, SSA, typing, or the
    // ownership dataflow surfaces as a diagnostic here rather than at the
    // runtime consumer. The optimizer re-runs it before and after every
    // rewrite (cfg_optimize.zig).
    if (lower.validate(&program, arena_alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    }) |msg| {
        return Compilation{
            .arena = arena,
            .graph = graph,
            .diag = .{
                .span = ast.Span.init(0, 0, 0),
                .message = msg,
            },
            .sources = builder.loaded_sources.items,
        };
    }

    // Mid-level optimizer (Passes 7–8, frontend.md §6): a single ordered
    // pass over the lowered CFG. The lowering validator already ran inside
    // lowerProgram (before the sequence); afterwards the optimized program
    // is re-validated structurally by round-tripping it through the
    // canonical text form and its parser (ir.md §13), so an optimizer bug
    // surfaces as a diagnostic here rather than at the runtime consumer.
    if (options.optimize) {
        lower.optimize(&program, arena_alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValidationFailed => {
                // The ir.md §13 validator rejected the program after a
                // rewrite: an optimizer invariant violation.
                return Compilation{
                    .arena = arena,
                    .graph = graph,
                    .diag = .{
                        .span = ast.Span.init(0, 0, 0),
                        .message = "internal error: optimized IR failed validation (optimizer invariant violation)",
                    },
                    .sources = builder.loaded_sources.items,
                };
            },
        };
        const text = try cfg.print(&program, arena_alloc);
        var validator = cfg_parse.Parser.init(arena_alloc);
        defer validator.deinit();
        _ = validator.parse(text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                // The optimized program failed its structural
                // re-validation: an optimizer invariant violation.
                return Compilation{
                    .arena = arena,
                    .graph = graph,
                    .diag = .{
                        .span = ast.Span.init(0, 0, 0),
                        .message = "internal error: optimized IR failed to re-parse (optimizer invariant violation)",
                    },
                    .sources = builder.loaded_sources.items,
                };
            },
        };
    }

    return Compilation{
        .arena = arena,
        .graph = graph,
        .program = program,
        .sources = builder.loaded_sources.items,
    };
}
