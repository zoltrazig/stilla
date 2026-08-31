//! Frontend pipeline driver — frontend.md §1–§3, phase3-cfg-lowering.md.
//!
//! `compile` runs the whole frontend in one call: load and parse the
//! transitive closure of modules reachable from the entry point (phase 1,
//! `moduleinfo`), build the module graph with module-level annotation,
//! annotate and check every module (phase 2, `checker`), and lower every
//! module to the AIR (phase 3, `lower`). The output is a
//! `Compilation`: an arena owning everything, the phase-1 `ModuleGraph`,
//! and the phase-3 `cfg.IrProgram`.
//!
//! Diagnostics follow the first-error-wins convention: on failure the
//! error is `error.Diagnostic` and `Compilation.diag` holds the span and
//! message.

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const frontend_cache = @import("frontend_cache.zig");
const lower = @import("lower.zig");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const cfg_optimize = @import("passes/cfg_optimize.zig");
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
    /// Optional per-module frontend cache (PLAN item 3): when set,
    /// repeated `compile` calls reuse each unchanged module's parsed
    /// `ast.Program`/`ast.Source` from the cache's arena, skipping
    /// lex/parse for them (validated by content hash + byte comparison).
    /// Member tables and all phase-2/3 side tables are still re-derived
    /// every compile. Null = today's fresh-compile behavior.
    cache: ?*frontend_cache.FrontendCache = null,
    /// Run the mid-level optimizer (Passes 7–8) over the lowered CFG
    /// before returning (optimizer.md): tail call elimination, constant
    /// folding, CSE, PRE, copy propagation, dead-block elimination, jump
    /// threading, phi simplification, and drop elision — followed by the
    /// post-optimization drop lowering, which expands every
    /// statically-expandable `drop` in the CFG (structs, tuples, boxes,
    /// unions), leaving only the drops that must reach the runtime
    /// (opaque host types, `hostdata`, `list[T]`, `any`). Default off —
    /// embedders and tests keep the faithful raw CFG; the `stilla`
    /// executable enables it. The toggle is code-only (no CLI flag).
    optimize: bool = false,
    /// When `optimize` is set, run the Pass 7–8 sequence to a bounded
    /// fixpoint instead of once (optimizer.md, §8.9): iteration 1 is the
    /// full sequence; each later iteration repeats the same fixed order
    /// with the one-shot inliner skipped (re-running it on spliced
    /// recursive callees would grow the CFG without bound), until a full
    /// iteration changes nothing or the compile-time cap
    /// `cfg_optimize.aggressive_max_iters` is reached, with the air.md
    /// §13 validator still guarding every rewrite inside each iteration.
    /// Code-only toggle (no CLI flag), like `optimize`; the default
    /// keeps the single ordered pass and its near-linear compile time.
    optimize_aggressive: bool = false,
};

/// The frontend's output: the arena, the phase-1 graph, and the phase-3
/// AIR. On failure (`error.Diagnostic`) `graph`/`program` are null (or
/// `graph` is set when the failure is phase 2/3) and `diags` holds every
/// diagnostic the failing phase collected, in order; `diag` names the
/// first for callers that only want one.
pub const Compilation = struct {
    /// The compile arena, owned by this compilation. The struct lives
    /// inside its own first chunk (see `compile`), so `Allocator`s
    /// derived from it — the module graph's, the type interner's, the
    /// checker's — stay valid for the compilation's lifetime even though
    /// the `Compilation` value itself moves across the return.
    arena: *std.heap.ArenaAllocator,
    graph: ?*moduleinfo.ModuleGraph,
    program: ?cfg.IrProgram = null,
    /// Every diagnostic the failing phase collected, in source order
    /// (arena-owned; present even when `graph` is null).
    diags: []const moduleinfo.Diag = &.{},
    /// The first diagnostic (a view of `diags[0]`), for callers that
    /// only want one.
    diag: ?moduleinfo.Diag = null,
    /// Every source loaded during phase 1, in creation order. Present
    /// even when `graph` is null (a parse failure): diagnostics can
    /// resolve their span against it for a file:line:col report.
    sources: []const *const ast.Source = &.{},

    /// The first diagnostic, when there is one.
    pub fn firstDiag(self: *const Compilation) ?moduleinfo.Diag {
        return self.diag;
    }

    pub fn deinit(self: *Compilation) void {
        // Everything is arena-owned; the arena frees it all at once.
        self.arena.deinit();
    }
};

/// Build a failed `Compilation`: the diagnostic list (arena-owned — the
/// phases allocated into this compile's arena, so their slices stay
/// valid), the graph (when the failure is phase 2/3), and the loaded
/// sources for span resolution. `diag` names the first diagnostic.
fn failed(
    arena: *std.heap.ArenaAllocator,
    diags: []const moduleinfo.Diag,
    graph: ?*moduleinfo.ModuleGraph,
    sources: []const *const ast.Source,
) CompileError!Compilation {
    return Compilation{
        .arena = arena,
        .graph = graph,
        .diags = diags,
        .diag = if (diags.len > 0) diags[0] else null,
        .sources = sources,
    };
}

/// Run the optimizer (optimizer.md): the default single ordered pass,
/// or the bounded fixpoint loop when `aggressive` — `optimizeAggressive`
/// with `max_iters = 1` is exactly the single pass, so the aggressive
/// mode is a pure extension of the same driver. The validator inside
/// `optimize`/`optimizeAggressive` guards every rewrite; a violation
/// surfaces as `error.ValidationFailed` here.
fn runOptimizer(program: *cfg.IrProgram, allocator: std.mem.Allocator, aggressive: bool) !void {
    if (aggressive) {
        try lower.optimizeAggressive(program, allocator, cfg_optimize.aggressive_max_iters);
    } else {
        try lower.optimize(program, allocator);
    }
}

/// Compile a program: entry module → AIR (frontend.md §1, §2).
pub fn compile(allocator: std.mem.Allocator, options: Options) CompileError!Compilation {
    // The arena struct is embedded in its own first chunk rather than
    // living on this stack frame: `Compilation` (and the `Allocator`s
    // derived from it, e.g. `ModuleGraph.arena` and the type interner's
    // arena) must stay valid after `compile` returns, and the caller's
    // copy of the struct would move. The chunk outlives `compile`, and
    // `Compilation.deinit` frees the struct together with the chunk.
    var arena0 = std.heap.ArenaAllocator.init(allocator);
    errdefer arena0.deinit();
    const arena = try arena0.allocator().create(std.heap.ArenaAllocator);
    arena.* = arena0;
    const arena_alloc = arena.allocator();

    // Phase 1: module graph (load, parse, annotate, sort).
    var builder = moduleinfo.Builder.init(arena_alloc, options.sources);
    builder.io = options.io;
    builder.cache = options.cache;
    const graph = builder.build(options.entry) catch |err| switch (err) {
        error.Diagnostic, error.Syntax => {
            // Parse and module-graph errors carry diagnostics (the
            // builder collects every one from the failing module's
            // lexer/parser run).
            return failed(arena, builder.diags.items, null, builder.loaded_sources.items);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Phase 2: annotation and checks (phase2-checker.md).
    var ck = checker.Checker.init(arena_alloc);
    _ = ck.check(graph) catch |err| switch (err) {
        error.Diagnostic => {
            return failed(arena, ck.diags.items, graph, builder.loaded_sources.items);
        },
        else => return err,
    };

    // Phase 3: CFG lowering.
    var lowerer = lower.Lowerer.init(arena_alloc, graph, options.entry_fn, options.entry_fn_explicit, &ck.annotation);
    var program = lower.lowerProgram(&lowerer) catch |err| switch (err) {
        error.Diagnostic => {
            // Lowering stays first-error (a lowering bug is one error);
            // wrap the single diagnostic in the collected form.
            const diag = lowerer.diag orelse return error.Diagnostic;
            return failed(arena, &.{diag}, graph, builder.loaded_sources.items);
        },
        else => return err,
    };

    // The air.md §13 validator runs on every lowered program (Pass 6.1):
    // a lowering bug that violates structure, SSA, typing, or the
    // ownership dataflow surfaces as a diagnostic here rather than at the
    // runtime consumer. The optimizer re-runs it before and after every
    // rewrite (cfg_optimize.zig).
    if (lower.validate(&program, arena_alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    }) |msg| {
        return failed(arena, &.{.{
            .span = ast.Span.init(0, 0, 0),
            .message = msg,
        }}, graph, builder.loaded_sources.items);
    }

    // Mid-level optimizer (Passes 7–8, optimizer.md): by default a
    // single ordered pass over the lowered CFG; `optimize_aggressive`
    // loops the same sequence to a bounded fixpoint. The lowering
    // validator already ran inside lowerProgram (before the sequence);
    // afterwards the optimized program is re-validated structurally by
    // round-tripping it through the canonical text form and its parser
    // (air.md §13), so an optimizer bug surfaces as a diagnostic here
    // rather than at the runtime consumer.
    if (options.optimize) {
        runOptimizer(&program, arena_alloc, options.optimize_aggressive) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValidationFailed => {
                // The air.md §13 validator rejected the program after a
                // rewrite: an optimizer invariant violation.
                return failed(arena, &.{.{
                    .span = ast.Span.init(0, 0, 0),
                    .message = "internal error: optimized AIR failed validation (optimizer invariant violation)",
                }}, graph, builder.loaded_sources.items);
            },
        };
        // Post-optimization drop lowering (air.md §6.4, §14): expand every
        // statically-expandable `drop` in the CFG — structs (hook call +
        // reverse-declaration-order field drops), tuples, boxes, and
        // unions — so the only drops reaching the runtime are the ones it
        // must dispatch dynamically (opaque host types, `hostdata`,
        // `list[T]`, `any`). It needs the phase-1 graph for field/variant
        // types and ownership; the result is re-validated like any other
        // rewrite.
        lower.lowerDrop(&program, graph, arena_alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (lower.validate(&program, arena_alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        }) |msg| {
            return failed(arena, &.{.{
                .span = ast.Span.init(0, 0, 0),
                .message = msg,
            }}, graph, builder.loaded_sources.items);
        }
        const text = try cfg.print(&program, arena_alloc);
        var validator = cfg_parse.Parser.init(arena_alloc);
        defer validator.deinit();
        _ = validator.parse(text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                // The optimized program failed its structural
                // re-validation: an optimizer invariant violation.
                return failed(arena, &.{.{
                    .span = ast.Span.init(0, 0, 0),
                    .message = "internal error: optimized AIR failed to re-parse (optimizer invariant violation)",
                }}, graph, builder.loaded_sources.items);
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
