//! Frontend pipeline driver — frontend.md §1–§3, cfg-lowering.md.
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
const meta = @import("meta.zig");
const cfg = @import("cfg.zig");
const frontend_cache = @import("frontend_cache.zig");
const lower = @import("lower.zig");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const hir = @import("hir.zig");
const hir_build = @import("passes/hir_build.zig");
const hir_effects = @import("passes/hir_effects.zig");
const effects = @import("effects.zig");
const hir_seg = @import("passes/hir_seg.zig");
const hir_simplify = @import("passes/hir_simplify.zig");
const hir_lower = @import("passes/hir_lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");

pub const OptimizeConfig = @import("passes/optimize_config.zig").OptimizeConfig;
pub const setOptimizeByName = @import("passes/optimize_config.zig").setByName;
pub const optimizeToggleNames = @import("passes/optimize_config.zig").names;

pub const CompileError = error{ OutOfMemory, Diagnostic, InvalidProvider, UnsupportedCleanupType };

/// Map an effect-engine failure onto the frontend's error set
/// (docs/effects.md §5.7: an invalid provider declaration is rejected,
/// never silently degraded).
fn engineError(err: effects.Engine.Error) CompileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProvider => error.InvalidProvider,
    };
}

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
    /// Host effect declarations, keyed by the binding's stable
    /// `<module>.<member>` symbol (effects.md §13). A binding with no
    /// declaration is the full `Top`. A declaration is honoured verbatim
    /// only when it attests `StillaExecution.forbidden`; a
    /// `StillaExecution.may_execute` declaration stays `Top` unless it
    /// carries an exhaustive callback contract (`HostDecl.callbacks`), in
    /// which case the call is bounded by the declared summary joined with
    /// the effect bounds of the callables it invokes synchronously. The
    /// embedding must be using the same contract at run time: these
    /// declarations are trusted, and `host_top` — the one value that omits
    /// `Read(ModuleConst)` — is only sound for a binding that really cannot
    /// execute Stilla code. Symbols that name no binding in this program
    /// are ignored (a declaration set describes an embedding, not one
    /// program). Caller-owned.
    host_decls: []const effects.HostDecl = &.{},
    /// Effect-domain registry declarations (docs/effects.md §5.5–§5.6):
    /// `stable` domains (deterministic reads) and explicit `disjoint`
    /// resource pairs. Undeclared distinct domains overlap conservatively.
    /// Caller-owned.
    resources: effects.ResourceRegistry = .{},
    /// The declared effect-domain inventory (docs/effects.md §5.2, §5.6):
    /// the domains the embedding has registered; `resources` carries the
    /// per-domain `stable` / `disjoint` facts. Feeds
    /// `EffectEnvironmentFingerprint` (like `host_registry_generation`) —
    /// it changes no conclusion by itself. Caller-owned.
    effect_domains: []const effects.EffectResource = &.{},
    /// The lattice provider (docs/effects.md §5.7): the instance's mode
    /// set and resource partial order. `compile` interns, validates, and
    /// freezes it once, then threads that one instance through effect
    /// analysis, the effect-driven consumers, SEG, and every re-validation. Null =
    /// the default `flat` instance over `resources`. Caller-owned.
    provider: ?*const effects.Provider = null,
    /// Host-semantics registry generation/version (docs/effects.md §13),
    /// bumped by the embedding whenever its host registry's *meaning*
    /// changes without the declaration set changing. It feeds
    /// `EffectEnvironmentFingerprint` only — it changes no conclusion by
    /// itself.
    host_registry_generation: u64 = 0,
    /// Optional per-module frontend cache (PLAN item 3): when set,
    /// repeated `compile` calls reuse each unchanged module's parsed
    /// `ast.Program`/`ast.Source` from the cache's arena, skipping
    /// lex/parse for them (validated by content hash + byte comparison).
    /// Member tables and all phase-2/3 side tables are still re-derived
    /// every compile. Null = today's fresh-compile behavior.
    cache: ?*frontend_cache.FrontendCache = null,
    /// Optimization toggles (`optimize_config.zig`, one bool per unit).
    /// Library default: every gate off. The `stilla` executable enables
    /// the `seg` and `cfg` gates; `--opt`/`--no-opt <name>` set fields.
    optimize: OptimizeConfig = .{},
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
    /// The canonical monomorphic HIR the checker's annotated output was
    /// built into before CFG lowering (hir.md §3, §11). Arena-owned by
    /// this compilation; null on a failed compile. The CLI's `--emit-hir`
    /// dump reads it through `hir.BuiltProgram.serCtx` + `hir.print`.
    hir: ?*hir.BuiltProgram = null,
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

/// Re-validate a rewritten HIR (docs/hir.md §2.4): structural checks on
/// every function and const root, then a fresh effect analysis whose
/// annotations must be `ready` and a sound over-approximation. Used after
/// an in-place HIR transform (effect-driven consumers, SEG). Returns null or the
/// diagnostic to report.
fn revalidateHir(arena_alloc: std.mem.Allocator, graph: *moduleinfo.ModuleGraph, built: *hir.BuiltProgram, host_decls: []const effects.HostDecl, resources: effects.ResourceRegistry, engine: *const effects.Engine, cache: *hir_effects.SummaryCache) CompileError!?moduleinfo.Diag {
    for (built.funcs.items) |rec| {
        if (hir.validate(&built.program, rec.root, arena_alloc) catch return error.OutOfMemory) |msg| {
            return moduleinfo.Diag{ .span = meta.Span.init(0, 0, 0), .message = msg };
        }
    }
    for (built.consts.items) |c| {
        const root = c.init orelse continue;
        if (hir.validate(&built.program, root, arena_alloc) catch return error.OutOfMemory) |msg| {
            return moduleinfo.Diag{ .span = meta.Span.init(0, 0, 0), .message = msg };
        }
    }
    var an = hir_effects.Analysis.init(arena_alloc, built, .{ .graph = graph, .host_decls = host_decls, .resources = resources, .engine = engine, .cache = cache }) catch return error.OutOfMemory;
    an.analyze() catch return error.OutOfMemory;
    if (an.validate(arena_alloc) catch return error.OutOfMemory) |msg| {
        return moduleinfo.Diag{ .span = meta.Span.init(0, 0, 0), .message = msg };
    }
    return null;
}

/// Run the optimizer (optimizer.md): the single ordered Pass 7–8
/// sequence, with `opt`'s per-pass toggles threaded into `cfg_optimize`.
/// The validator inside `optimize` guards every rewrite; a violation
/// surfaces as `error.ValidationFailed` here.
fn runOptimizer(program: *cfg.IrProgram, allocator: std.mem.Allocator, opt: OptimizeConfig) !void {
    try lower.optimize(program, allocator, .{
        .tail_call = opt.cfg_tail_call,
        .inline_calls = opt.cfg_inline,
        .cse = opt.cfg_cse,
        .copy_prop = opt.cfg_copy_prop,
        .pre = opt.cfg_pre,
        .if_convert = opt.cfg_if_convert,
        .dead_block = opt.cfg_dead_block,
        .drop_elide = opt.cfg_drop_elide,
        .dead_instr = opt.cfg_dead_instr,
        .jump_thread = opt.cfg_jump_thread,
        .phi_simplify = opt.cfg_phi_simplify,
    });
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

    // The session's lattice instance (docs/effects.md §5.7): interned
    // and validated once, here, then read-only for the rest of the
    // compile. Every consumer below (effect analysis, the effect consumers,
    // SEG, each re-validation) is handed this same instance, so no two
    // phases can disagree about the mode set or the resource order.
    const engine = effects.Engine.init(arena_alloc, options.provider, options.resources) catch |err| return engineError(err);

    // The effect-environment fingerprint (docs/effects.md §13): the
    // semantic half of a module cache key, the program text being the
    // other half. The parse cache is independent of it, so cached parses
    // stay valid across a change; stamping it is what lets a phase-2/3
    // cache invalidate on an environment change instead of reusing a
    // conclusion derived under a different contract. The lattice
    // descriptor is part of that environment (docs/effects.md §5.7).
    if (options.cache) |cache| {
        const fp = effects.EffectEnvironmentFingerprint.compute(arena_alloc, .{
            .registry_generation = options.host_registry_generation,
            .domains = options.effect_domains,
            .resources = options.resources,
            .provider = options.provider,
            .host_decls = options.host_decls,
        }) catch return error.OutOfMemory;
        _ = cache.noteEffectEnvironment(fp);
    }

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

    // Phase 2: annotation and checks (checker.md).
    var ck = checker.Checker.init(arena_alloc);
    _ = ck.check(graph) catch |err| switch (err) {
        error.Diagnostic => {
            return failed(arena, ck.diags.items, graph, builder.loaded_sources.items);
        },
        else => return err,
    };

    // Phase 3: CFG lowering through the HIR seam (docs/hir.md §11):
    // the checker output is built into the canonical monomorphic HIR
    // (`hir_build.buildProgramDiag`) and lowered from there. This removed
    // the direct annotated-AST lowering and the `hir_stage` toggle.
    var lowerer = lower.Lowerer.init(arena_alloc, graph, options.entry_fn, options.entry_fn_explicit, &ck.annotation);
    var built_hir: ?*hir.BuiltProgram = null;
    var program = blk: {
        var bdiag: moduleinfo.Diag = undefined;
        const built = hir_build.buildProgramDiag(arena_alloc, graph, &ck.annotation, &bdiag) catch |err| switch (err) {
            error.Diagnostic => {
                const diag = if (bdiag.message.len > 0) bdiag else moduleinfo.Diag{
                    .span = meta.Span.init(0, 0, 0),
                    .message = "HIR build failed",
                };
                return failed(arena, &.{diag}, graph, builder.loaded_sources.items);
            },
            else => return err,
        };
        built_hir = built;
        // The session's persistent summary cache (docs/effects.md §8.3):
        // owned by the compile arena so it outlives every short-lived
        // `Analysis` the pipeline constructs below. The initial analysis
        // arms it with a full solve; each effect-driven / SEG round and every
        // `revalidateHir` then reuse finalized summaries and re-solve only
        // the SCCs a rewriter marked dirty.
        const summary_cache = hir_effects.SummaryCache.init(arena_alloc) catch return error.OutOfMemory;
        // Seam order (docs/hir.md §2.3/§10.1): structural validation
        // first, then effect analysis and annotation validation. The
        // structural gate is what makes the effect walk safe on a
        // malformed arena; the effect annotations are additive metadata
        // and do not change the canonical HIR text or the lowered AIR.
        for (built.funcs.items) |rec| {
            if (hir.validate(&built.program, rec.root, arena_alloc) catch return error.OutOfMemory) |msg| {
                return failed(arena, &.{.{ .span = meta.Span.init(0, 0, 0), .message = msg }}, graph, builder.loaded_sources.items);
            }
        }
        for (built.consts.items) |c| {
            const root = c.init orelse continue;
            if (hir.validate(&built.program, root, arena_alloc) catch return error.OutOfMemory) |msg| {
                return failed(arena, &.{.{ .span = meta.Span.init(0, 0, 0), .message = msg }}, graph, builder.loaded_sources.items);
            }
        }
        var effect_analysis = hir_effects.Analysis.init(arena_alloc, built, .{ .graph = graph, .host_decls = options.host_decls, .resources = options.resources, .engine = &engine, .cache = summary_cache }) catch return error.OutOfMemory;
        effect_analysis.analyze() catch return error.OutOfMemory;
        if (effect_analysis.validate(arena_alloc) catch return error.OutOfMemory) |msg| {
            return failed(arena, &.{.{
                .span = meta.Span.init(0, 0, 0),
                .message = msg,
            }}, graph, builder.loaded_sources.items);
        }
        // Module-constant init/teardown dependency check (docs/effects.md
        // §7), driven by the just-computed summaries and the whole-chain
        // `drop_effect` — it replaces the checker's AST-level `InitOrder`
        // walk. It runs on the pre-transform form: HIR optimization may
        // not be used to launder a violating read (docs/effects.md §7.1).
        if (effect_analysis.checkModuleDependencies(arena_alloc) catch return error.OutOfMemory) |msg| {
            return failed(arena, &.{.{
                .span = meta.Span.init(0, 0, 0),
                .message = msg,
            }}, graph, builder.loaded_sources.items);
        }
        if (options.optimize.hir) {
            // Effect-driven consumers (hir.md §11): dead-let +
            // selective A-Normal Form, then re-validate structure and
            // effects on the rewritten program (hir.md §2.4).
            _ = hir_simplify.optimize(arena_alloc, built, .{
                .graph = graph,
                .host_decls = options.host_decls,
                .resources = options.resources,
                .engine = &engine,
                .cache = summary_cache,
                .dead_let = options.optimize.dead_let,
                .anf = options.optimize.anf,
                .never_suffix = options.optimize.never_suffix,
            }) catch return error.OutOfMemory;
            if (revalidateHir(arena_alloc, graph, built, options.host_decls, options.resources, &engine, summary_cache) catch return error.OutOfMemory) |diag| {
                return failed(arena, &.{diag}, graph, builder.loaded_sources.items);
            }
        }
        if (options.optimize.seg) {
            // SEG (hir.md §11): rewrite islands after the validated
            // effect analysis, then re-validate structure and effects on
            // the rewritten program (hir.md §2.4 — a transform may not
            // assume the pre-rewrite static conclusions still hold).
            _ = hir_seg.optimize(arena_alloc, built, .{
                .graph = graph,
                .host_decls = options.host_decls,
                .resources = options.resources,
                .engine = &engine,
                .cache = summary_cache,
                .beta = options.optimize.seg_beta,
                .eta = options.optimize.seg_eta,
                .let_dead = options.optimize.seg_let_dead,
                .let_forward = options.optimize.seg_let_forward,
                .let_atom = options.optimize.seg_let_atom,
                .match = options.optimize.seg_match,
                .reorder = options.optimize.seg_reorder,
                .egraph_fold = options.optimize.egraph_fold,
                .egraph_algebra = options.optimize.egraph_algebra,
                .egraph_cond = options.optimize.egraph_cond,
                .egraph_project = options.optimize.egraph_project,
                .egraph_cse = options.optimize.egraph_cse,
                .egraph_ac = options.optimize.egraph_ac,
            }) catch return error.OutOfMemory;
            if (revalidateHir(arena_alloc, graph, built, options.host_decls, options.resources, &engine, summary_cache) catch return error.OutOfMemory) |diag| {
                return failed(arena, &.{diag}, graph, builder.loaded_sources.items);
            }
        }
        break :blk hir_lower.lowerProgram(&lowerer, built) catch |err| switch (err) {
            error.Diagnostic => {
                // Lowering stays first-error; wrap the single diagnostic
                // in the collected form.
                const diag = lowerer.diag orelse return error.Diagnostic;
                return failed(arena, &.{diag}, graph, builder.loaded_sources.items);
            },
            else => return err,
        };
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
            .span = meta.Span.init(0, 0, 0),
            .message = msg,
        }}, graph, builder.loaded_sources.items);
    }

    // Mid-level optimizer (Passes 7–8, optimizer.md): a single ordered
    // pass over the lowered CFG, with `optimize`'s per-pass toggles. The
    // lowering validator already ran inside lowerProgram (before the
    // sequence); afterwards the optimized program is re-validated
    // structurally by round-tripping it through the canonical text form
    // and its parser (air.md §13), so an optimizer bug surfaces as a
    // diagnostic here rather than at the runtime consumer.
    if (options.optimize.cfg) {
        runOptimizer(&program, arena_alloc, options.optimize) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValidationFailed => {
                // The air.md §13 validator rejected the program after a
                // rewrite: an optimizer invariant violation.
                return failed(arena, &.{.{
                    .span = meta.Span.init(0, 0, 0),
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
                .span = meta.Span.init(0, 0, 0),
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
                    .span = meta.Span.init(0, 0, 0),
                    .message = "internal error: optimized AIR failed to re-parse (optimizer invariant violation)",
                }}, graph, builder.loaded_sources.items);
            },
        };
    }

    return Compilation{
        .arena = arena,
        .graph = graph,
        .program = program,
        .hir = built_hir,
        .sources = builder.loaded_sources.items,
    };
}
