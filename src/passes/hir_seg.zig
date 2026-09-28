//! Pass: SEG (M2a rule subset): the island driver, plus the arena-based
//! union rules (docs/hir.md §8, §11 M2a; docs/effects.md §12.3). In: a
//! built HIR program whose every reachable node carries a *validated*
//! `ready` effect summary (`hir_effects.Analysis`). Out: the same program
//! with its admissible pure-Copy islands rewritten, iterated to a bounded
//! fixpoint, with every root still structurally valid and its annotations
//! re-derivable.
//!
//! **Two engines.** The *union* rules (constant folding, integer algebra,
//! constant `if` / `and` / `or`, aggregate projection, and the
//! α-equivalence / CSE sharing that falls out of them) run in the slotted
//! e-graph arena of `hir_egraph.zig`: this file admits each island, calls
//! `hir_egraph.optimizeIsland` at its root, aggregates the arena's `Stats`
//! and marks the sites it overwrote dirty. The *boundary* rewrites
//! (β-reduction → `let`, η-reduction, the three `let` folds) and the
//! known-variant `match` reduction stay here as in-place tree rewrites,
//! because they rewrite across an island boundary rather than to an
//! equivalent term.
//!
//! Scope (hir.md §11 M2a):
//!
//! - **Island set** — `const / local / let / lambda / call / if / match /
//!   struct_make / variant_make / tuple_make / list_make / field_get` plus
//!   every typed (numeric) opcode,
//!   exactly the registry rows carrying `OpDescriptor.seg` (hir.md §3.5). The
//!   real boundary is the *recursive* encodability predicate: a node is
//!   an island member only if its own encoding is registered, it is
//!   semantically `isSegSafe`, and every operand subtree / region body is
//!   itself an island member (hir.md §8.1–§8.2). Anything else keeps its
//!   original shape.
//! - **Rules** — β-reduction (→ let, the boundary rewrite with the
//!   §8.4 contract), η-reduction (a `fn_ref` value redirect, §8.5), let
//!   simplification (dead let, used-once forwarding, trivial-atom
//!   forwarding — also boundary rewrites, admitted by the `let_*`
//!   contracts of §8.7 rather than by island membership, since a
//!   source-level `let`'s initializer opens its own full expression),
//!   the known-variant `match` reduction to `let` (§8.6) — all in this
//!   driver — and, in the arena (`hir_egraph.zig`): aggregate projection
//!   (`field_get(C(…), i) → vi` for a known index when `C` is
//!   `struct_make` / `tuple_make` / `list_make`, §8.3), constant folding
//!   over the typed reps, integer algebra identities (the constant
//!   identities plus the class-equality congruence identities
//!   `x - x → 0` / `x ^ x → 0` / `x & x → x` / `x | x → x` and
//!   `0 - x → neg x`), integer commutativity canonicalization (AC-lite:
//!   operands swapped in place so congruence merges `a ⊕ b` / `b ⊕ a`; the
//!   swap is licensed by the island's `isSegSafe` admission — total,
//!   observable-effect-free, deterministic, `Copy` operands — so LTR
//!   evaluation order is unobservable and no `reorderable` query is
//!   consulted, docs/effects.md §12.3), and
//!   CSE-style
//!   sharing (an operand class used at least twice by one `strict_ltr`,
//!   region-free island node materializes into a synthesized `let` when its
//!   preferred e-node is not a trivial atom, and duplicates otherwise,
//!   §8.3). Tuple / list projection is IR-level only (Stilla has no
//!   element-read suffix); not in scope: non-sibling (cross-statement /
//!   cross-branch) sharing, associativity search, `move` /
//!   `drop` / borrow, host calls (§8.3).
//! - **Extraction cost and the termination contract** — the arena's
//!   extraction cost is the `hir_egraph.CostModel` minimum (per-opcode
//!   weights by registry class, default = node count), relaxed bottom-up
//!   over the class DAG; the tie-break is lowest cost, then the class's
//!   preferred e-node (0 = the class's `encode` original, 1 = a rule's
//!   choice), then the lowest e-node index (hir.md §8.2). The folding /
//!   algebra /
//!   aggregate-projection rules strictly reduce it; β (a boundary rewrite,
//!   not an e-class extraction) is admitted by its contract and the
//!   known-variant `match` reduction by its coverage / arity proof. Two
//!   rules may *add* nodes: the `match` rule splices one `let` per bound
//!   payload and CSE sharing materializes a shared subterm, so a wide
//!   constructor / a shared subtree can grow the tree. SEG therefore offers
//!   a **bounded-round contract, not a decreasing-measure one**: `optimize`
//!   runs at most `Config.max_iterations` analysis→rewrite rounds, and the
//!   same bound caps one island's e-graph saturation. `Stats.converged` and
//!   `Stats.egraph_converged` report which exit each engine took — `true`
//!   for a quiet round (a fixpoint of the current rule set), `false` for a
//!   bound hit. Stopping early is always safe: every admitted rewrite
//!   preserves semantics, so any round prefix is a correct program and a
//!   bound hit only forfeits further rewrites. The per-rule guards that keep
//!   the default bound sufficient in practice: each λ is inlined at most
//!   once (`beta_done`, so β fires at most once per λ record), each `match`
//!   node is consumed once, each CSE binding has at least two uses and a
//!   non-trivial init (no let rule can undo it), an arena union rule always
//!   moves a class or its preferred node (else it is the fixpoint), and
//!   every other rule strictly reduces the extraction cost.
//! - **Re-verification** — each iteration re-derives the effect analysis
//!   from scratch before rewriting; the caller re-validates structurally
//!   and by effects after the pass. No transform is allowed to rely on
//!   the pre-rewrite static conclusions (hir.md §2.4).
//! - **Default-on in the executable** — the `stilla` CLI enables this gate
//!   by default (`--no-opt seg` opts out); the library default stays off
//!   (`frontend.OptimizeConfig.seg`), matching the `hir` gate, so embedders
//!   and tests keep explicit control. The compile-time / round budget that
//!   justifies the default is recorded in docs/hir.md §11.
//!
//! The boundary rewrites stay deliberately in-place: HIR is an append-only
//! arena and every node has exactly one parent (§3.7), so mutating a node's
//! fields (or copying a rewritten child's fields into it) is a local,
//! tree-legal rewrite. A rule never *moves* a node it will keep
//! referencing; β and let-forwarding copy the surviving operand's fields
//! into the node being rewritten and leave the donor node unreachable. The
//! arena's extraction obeys the same discipline: it either walks the site
//! unchanged (identity) or writes a freshly materialized subtree into it.

const std = @import("std");
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const effects = @import("stilla").effects;
const hir_effects = @import("hir_effects.zig");
const hir_egraph = @import("hir_egraph.zig");
const rewrite_contract = @import("rewrite_contract.zig");

pub const Error = hir.Program.InternTypeError;

/// A `fn_ref` chain longer than this is a cycle or a pathological tower
/// and is refused rather than followed (hir.md §8.5).
const max_eta_chain: usize = 32;

/// β's declared rule + boundary-rewrite contract (docs/effects.md §10.3–
/// §10.4). The *match* layer stays inline in `tryBeta` — the λ shape, the
/// region / arity facts, the `isSegSafe(body)` + single-expression
/// precondition, and the `beta_done` consumption guard are structural
/// applicability. What is declared here is the contract the rewrite is
/// admitted by: evaluation count and LTR order preserved (β→let evaluates
/// each argument once, in order), binders remapped to fresh call-site
/// binders, cloned nodes stamped with the call-site FE, and the evaluated
/// call subtree literally cleanup-free under the ownership gate. The
/// legality tags and the cleanup proof are discharged by
/// `rewrite_contract.check` / `checkCleanup` through derived queries only.
const beta_rule = rewrite_contract.RewriteRule{
    .name = "beta",
    .applicability = .shape,
    .legality = &.{.evaluation_count_preserved},
    .contract = .{
        .effect = .{ .preserves_evaluation_count = true, .preserves_order = true },
        .maps_scope = true,
        .maps_full_expr = true,
        .preserves_cleanup = .cleanup_free_subtree,
    },
};

/// The `let` family's declared rules (docs/effects.md §10.3–§10.4,
/// docs/hir.md §8.3 / §8.7). A source-level `let`'s initializer opens its
/// own full expression (hir.md §5.6), so the `let` node is never an island
/// member; like β / η the rules are therefore **boundary rewrites**,
/// admitted by these contracts instead of by island membership. The
/// *match* layer (the single-parameter `let` shape and the use count) stays
/// inline in `ruleLet`.
///
/// dead-let discards the initializer's evaluation, and removing the binding
/// also removes its scope-end destructor — the `binder_destruction` proof.
const let_dead_rule = rewrite_contract.RewriteRule{
    .name = "let_dead",
    .applicability = .shape,
    .legality = &.{.discardable},
    .contract = .{
        .effect = .{ .may_discard = true },
        .preserves_cleanup = .binder_destruction,
    },
};

/// used-once forwarding relocates the initializer's single evaluation to
/// its use point. Nothing is deleted or duplicated, but the move crosses a
/// full-expression boundary, so the contract needs the
/// `cleanup_free_subtree` proof (no cleanup registration moves) and the
/// `maps_full_expr` declaration (the moved subtree is re-stamped onto the
/// destination). Island membership, which the proof re-checks, additionally
/// supplies Copy (no scope-end destructor to leave behind).
const let_forward_rule = rewrite_contract.RewriteRule{
    .name = "let_forward",
    .applicability = .shape,
    .legality = &.{.evaluation_count_preserved},
    .contract = .{
        .effect = .{ .preserves_evaluation_count = true, .may_reorder = true },
        .maps_full_expr = true,
        .preserves_cleanup = .cleanup_free_subtree,
    },
};

/// trivial-atom forwarding copies a `const` / `local` / `fn_ref`
/// initializer to every use. The atom has no evaluation to duplicate, but
/// its *value* must still be duplicable: a borrowed view fails the
/// ownership gate and a `Q` read the no-`Q` clause (`isDuplicable`), which
/// is the admission proof the v1 rule lacked.
const let_atom_rule = rewrite_contract.RewriteRule{
    .name = "let_atom",
    .applicability = .shape,
    .legality = &.{.duplicable},
    .contract = .{
        .effect = .{ .may_duplicate = true },
        .maps_full_expr = true,
    },
};

/// η's declared rule (docs/effects.md §10.3–§10.4, docs/hir.md §8.5). Like
/// β it is a boundary rewrite — a `fn_ref` carries no SEG encoding, so the
/// island gate never sees it. Its only operational obligation is the
/// evaluation-count certificate: the rewrite replaces a wrapper value with
/// the `fn_ref` it forwards to, so nothing is evaluated, discarded,
/// duplicated or reordered and no cleanup registration moves. The *match*
/// layer stays inline in `tryEta` — the `fn_ref` opcode, the λ / arity /
/// type shape, the totality gate and the chain bound are structural
/// applicability, not legality.
const eta_rule = rewrite_contract.RewriteRule{
    .name = "eta",
    .applicability = .shape,
    .legality = &.{.evaluation_count_preserved},
    .contract = .{
        .effect = .{ .preserves_evaluation_count = true },
    },
};

/// The operand-reorder rule (docs/effects.md §10.3–§10.5): the production
/// consumer of the `swap_operands` legality. It canonicalizes the operand
/// order of a `strict_ltr` parent under the *active lattice instance*:
/// two adjacent operands swap when `canSwapOperands` admits the move and
/// the pair is not already in canonical summary order. This is the rule
/// through which a second lattice instance produces *different* AIR — a
/// `hierarchy` provider that places two host domains as disjoint sibling
/// subtrees proves reads of them reorderable where the flat instance sees
/// a conflict. The canonical target order (`rowLess`) is instance-shaped:
/// it compares canonical access rows by (mode, resource), so an instance
/// that proves a pair disjoint simply allows the canonical move the flat
/// instance refused.
const reorder_rule = rewrite_contract.RewriteRule{
    .name = "reorder",
    .applicability = .shape,
    .legality = &.{.swap_operands},
    .contract = .{
        .effect = .{ .preserves_evaluation_count = true, .may_reorder = true },
    },
};

/// What one `optimize` call did — for tests and the compile-time budget.
pub const Stats = struct {
    /// Analysis→rewrite rounds this pass ran (each round re-derives the
    /// effect analysis before rewriting).
    iterations: u32 = 0,
    /// `true` when the last round was quiet — the pass reached a fixpoint of
    /// the current rule set within the bound. `false` when the
    /// `max_iterations` bound was hit first (pass header's termination
    /// contract; a bound hit is safe, only a missed optimization).
    converged: bool = false,
    /// Reachable nodes that passed recursive island admission.
    islands: usize = 0,
    /// β-reductions applied (a λ applied to its arguments becomes a `let`
    /// chain).
    beta: usize = 0,
    /// η-reductions applied (a wrapper `fn_ref` redirected to the function
    /// it forwards to).
    etas: usize = 0,
    /// Constant folds applied in the e-graph arena (the arena's applied
    /// half; the recognized redexes are `egraph_folds_matched`).
    folds: usize = 0,
    /// Integer-algebra identities applied in the e-graph arena (the
    /// applied half; recognized redexes are `egraph_algebra_matched`).
    algebra: usize = 0,
    /// `let`-family bounds applied (dead-let deletion / used-once
    /// forwarding / trivial-atom copying).
    lets: usize = 0,
    /// Constant-condition selections applied in the e-graph arena (the
    /// applied half; recognized redexes are `egraph_conds_matched`).
    conds: usize = 0,
    /// Known-variant `match` reductions to `let` applied.
    matches: usize = 0,
    /// Aggregate projections applied in the e-graph arena (the applied
    /// half; recognized redexes are `egraph_projects_matched`).
    projects: usize = 0,
    /// `let` bindings synthesized for shared operand classes during
    /// extraction (CSE sharing).
    shares: usize = 0,
    /// Adjacent operand pairs canonically reordered by the `reorder` rule
    /// (`swap_operands` legality; docs/effects.md §10.3–§10.5). Measures
    /// how much a provider's lattice gets to move (0 for the default flat
    /// instance over an empty registry).
    reorders: usize = 0,

    // --- the SEG arena's own facts (docs/todo.md 21 / 23) ---
    /// Islands that actually went through the e-graph engine (encode
    /// succeeded): an island whose root failed admission keeps its shape.
    egraph_islands: usize = 0,
    /// Saturation rounds summed over those islands.
    egraph_rounds: u64 = 0,
    /// Whether every island's saturation reached a quiet round inside the
    /// bound.
    egraph_converged: bool = true,
    /// Class merges from congruence / encode-time hash-consing (CSE).
    egraph_merges: usize = 0,
    /// Rule-driven class merges (folds / algebra / const-if / projection).
    egraph_unions: usize = 0,
    /// Fresh subtrees the extractor wrote (a redirected class or a site
    /// that is not a member of its class).
    egraph_copies: usize = 0,
    /// Total cost of the forms extraction selected across all islands, in
    /// the `hir_egraph.CostModel` units (item 22): each island's root
    /// class cost, summed.
    egraph_extract_cost: u64 = 0,
    /// Constant-fold redexes the arena recognized across all islands /
    /// rounds, summed (item 23's match half; `folds` is the applied half).
    /// Non-zero proves the fold rule actually fires — the arena is not an
    /// empty run.
    egraph_folds_matched: usize = 0,
    /// Integer-algebra redexes the arena recognized, summed (match half of
    /// `algebra`).
    egraph_algebra_matched: usize = 0,
    /// Constant-condition redexes the arena recognized, summed (match half
    /// of `conds`).
    egraph_conds_matched: usize = 0,
    /// Aggregate-projection redexes the arena recognized, summed (match
    /// half of `projects`).
    egraph_projects_matched: usize = 0,
    /// In-place commutativity canonicalization swaps performed, summed
    /// (the matched half; the applied half flows through `egraph_merges`).
    /// After the AC regroup superseded the in-place class-id swap for the
    /// associative ops this counts only the commutative-but-not-associative
    /// `eq` / `ne`; the associative ops (2-operand commutes included) are
    /// `egraph_assoc`.
    egraph_ac: usize = 0,
    /// AC regroup/canonicalization applications summed over all islands /
    /// rounds (the associativity half of the integer AC search), including
    /// plain 2-operand commutes; the `eq` / `ne` in-place swaps are
    /// `egraph_ac`.
    egraph_assoc: usize = 0,
};

pub const Config = struct {
    /// The module graph, for the ownership class of generic named types
    /// (same role as in `hir_effects.Config`).
    graph: ?*moduleinfo.ModuleGraph = null,
    /// Embedding host declarations (docs/effects.md §13), passed through
    /// to every internal `hir_effects.Analysis` so the rewrite rounds and
    /// the caller's final re-validation use one effect environment.
    host_decls: []const effects.HostDecl = &.{},
    /// Effect-domain registry (docs/effects.md §5.5–§5.6), passed through
    /// with `host_decls` so the rounds and the re-validation share one
    /// environment.
    resources: effects.ResourceRegistry = .{},
    /// The frozen lattice instance (docs/effects.md §5.7) handed to every
    /// internal `hir_effects.Analysis` so the rounds and the caller's
    /// final re-validation read one instance. Null = the default `flat`
    /// instance over `resources`.
    engine: ?*const effects.Engine = null,
    /// The session's persistent summary cache (docs/effects.md §8.3),
    /// passed through to every internal `hir_effects.Analysis` so the
    /// rounds reuse finalized summaries and re-solve only the SCCs a
    /// rewrite dirtied. Null = a private, never-armed cache (a full solve
    /// every round), leaving direct white-box callers unchanged.
    cache: ?*hir_effects.SummaryCache = null,
    /// Bound on analysis→rewrite rounds (each round re-derives effects).
    /// The same bound caps one island's e-graph saturation rounds.
    max_iterations: u32 = 8,
    // Boundary rewrites (driver-level, admitted by rewrite_contract).
    beta: bool = true,
    eta: bool = true,
    let_dead: bool = true,
    let_forward: bool = true,
    let_atom: bool = true,
    match: bool = true,
    reorder: bool = true,
    // E-graph arena rules (forwarded to hir_egraph.Config.rules).
    egraph_fold: bool = true,
    egraph_algebra: bool = true,
    egraph_cond: bool = true,
    egraph_project: bool = true,
    egraph_cse: bool = true,
    /// Integer commutativity for the arena (canonicalization + congruence
    /// identities + `0 - x → neg x`).
    egraph_ac: bool = true,
};

/// Rewrite every function body and constant initializer in place to the
/// SEG normal form, iterating analysis/rewrite to a bounded fixpoint. The
/// union rules run in the e-graph arena (`hir_egraph.zig`) at each island
/// root; the boundary rewrites (β / η / the `let` folds) and the
/// known-variant `match` reduction stay in this driver. The caller owns
/// `built` and the arena; on return every root is rewritten but not yet
/// re-validated (the caller runs `hir.validate` + a fresh
/// `Analysis.analyze`/`.validate`).
pub fn optimize(arena: std.mem.Allocator, built: *hir.BuiltProgram, config: Config) Error!Stats {
    var stats = Stats{};
    // A λ record is inlined at most once per compile: this bounds β
    // against recursive / mutually-recursive λ values (hir.md §8.4 does
    // not promise multi-site inlining) and keeps the fixpoint finite.
    var beta_done = std.AutoHashMapUnmanaged(hir.FuncId, void).empty;
    var iter: u32 = 0;
    while (iter < config.max_iterations) : (iter += 1) {
        var analysis = try hir_effects.Analysis.init(arena, built, .{ .graph = config.graph, .host_decls = config.host_decls, .resources = config.resources, .engine = config.engine, .cache = config.cache });
        try analysis.analyze();
        var rw = Rewriter{
            .arena = arena,
            .built = built,
            .analysis = &analysis,
            .beta_done = &beta_done,
            .max_egraph_rounds = config.max_iterations,
            .cfg = config,
        };
        const changed = try rw.run();
        stats.iterations += 1;
        stats.islands = @max(stats.islands, rw.island_count);
        stats.beta += rw.beta;
        stats.etas += rw.etas;
        stats.folds += rw.folds;
        stats.algebra += rw.algebra;
        stats.lets += rw.lets;
        stats.conds += rw.conds;
        stats.matches += rw.matches;
        stats.projects += rw.projects;
        stats.shares += rw.shares;
        stats.reorders += rw.reorders;
        stats.egraph_islands += rw.egraph_islands;
        stats.egraph_rounds += rw.egraph_rounds;
        stats.egraph_converged = stats.egraph_converged and rw.egraph_converged;
        stats.egraph_merges += rw.egraph_merges;
        stats.egraph_unions += rw.egraph_unions;
        stats.egraph_copies += rw.egraph_copies;
        stats.egraph_extract_cost += rw.egraph_extract_cost;
        stats.egraph_folds_matched += rw.egraph_folds_matched;
        stats.egraph_algebra_matched += rw.egraph_algebra_matched;
        stats.egraph_conds_matched += rw.egraph_conds_matched;
        stats.egraph_projects_matched += rw.egraph_projects_matched;
        stats.egraph_ac += rw.egraph_ac;
        stats.egraph_assoc += rw.egraph_assoc;
        if (!changed) {
            stats.converged = true;
            break;
        }
    }
    return stats;
}

// ---------------------------------------------------------------------------
// The rewriter
// ---------------------------------------------------------------------------

const Rewriter = struct {
    arena: std.mem.Allocator,
    built: *hir.BuiltProgram,
    analysis: *hir_effects.Analysis,
    beta_done: *std.AutoHashMapUnmanaged(hir.FuncId, void),

    /// Per-node island membership for the nodes present when the pass
    /// started. Nodes created by this pass (β clones) are admissible by
    /// construction and are not in this slice — `encOf` answers `true`
    /// for them.
    enc: []bool = &.{},
    /// The *maximal* island roots among `enc` members: a member whose
    /// parent is not a member (or which is a program root). Exactly these
    /// go through the e-graph; the rest of an island is reached by the
    /// extractor and then by the ordinary local walk.
    island_root: []bool = &.{},
    island_count: usize = 0,

    changed: bool = false,
    beta: usize = 0,
    etas: usize = 0,
    folds: usize = 0,
    algebra: usize = 0,
    lets: usize = 0,
    conds: usize = 0,
    matches: usize = 0,
    projects: usize = 0,
    shares: usize = 0,
    reorders: usize = 0,

    // SEG arena facts, accumulated from `hir_egraph` per island.
    egraph_islands: usize = 0,
    egraph_rounds: u64 = 0,
    egraph_converged: bool = true,
    egraph_merges: usize = 0,
    egraph_unions: usize = 0,
    egraph_copies: usize = 0,
    /// Total cost of the forms extraction selected across all islands, in
    /// the `hir_egraph.CostModel` units (item 22): each island's root
    /// class cost, summed.
    egraph_extract_cost: u64 = 0,
    /// Per-rule redexes the arena recognized (match half); the applied
    /// half is `folds` / `algebra` / `conds` / `projects` above.
    egraph_folds_matched: usize = 0,
    egraph_algebra_matched: usize = 0,
    egraph_conds_matched: usize = 0,
    egraph_projects_matched: usize = 0,
    egraph_ac: usize = 0,
    egraph_assoc: usize = 0,

    /// Node ids whose content this round has already overwritten in place.
    /// An island-membership or analysis verdict about such a node describes
    /// a shape that no longer exists, so no rule may consult it (the pass
    /// header's "no transform may rely on the pre-rewrite static
    /// conclusions"). Fresh per round (a new `Rewriter` is built each
    /// `optimize` iteration).
    dirty: std.AutoHashMapUnmanaged(hir.ExprId, void) = .empty,

    /// The full-expression id β maps every cloned λ-body node onto
    /// (hir.md §8.4 `maps_full_expr`): the call site's FE. Set per β
    /// rewrite from the call node; every node of the cloned body carries
    /// it, so the moved body's destruction boundary follows the call
    /// into its destination full expression.
    clone_fe: hir.FullExprId = 0,

    /// Saturation-round bound handed to the e-graph arena (mirrors
    /// `Config.max_iterations`).
    max_egraph_rounds: u32 = 8,

    /// Which rewrites this pass may apply (beta/eta/let/match/reorder and
    /// the e-graph arena's own rule toggles, forwarded per island).
    cfg: Config = .{},

    fn p(self: *Rewriter) *hir.Program {
        return &self.built.program;
    }

    fn run(self: *Rewriter) Error!bool {
        self.enc = try self.arena.alloc(bool, self.p().exprs.items.len);
        @memset(self.enc, false);
        try self.computeIslands();
        self.island_root = try self.arena.alloc(bool, self.enc.len);
        @memset(self.island_root, false);
        for (self.built.funcs.items) |rec| try self.markIslandRoots(rec.root);
        for (self.built.consts.items) |c| {
            if (c.init) |root| try self.markIslandRoots(root);
        }
        // Attribute each rewrite to its owning function and mark it stale
        // in the session cache so the next `Analysis.init` re-solves
        // exactly the SCCs whose summaries may have moved
        // (docs/effects.md §8.3). `self.changed` is a monotone round-level
        // flag for the return value, so it is reset per function: a single
        // cumulative flag would mark only the first function that changed
        // and silently skip every later one. The per-round `dirty`/island
        // scratch sets are not HIR content and never mark. Constant
        // initializers are not dependency-graph nodes, so they are not
        // marked.
        var any_changed = false;
        for (self.built.funcs.items, 0..) |rec, i| {
            self.changed = false;
            try self.rewrite(rec.root);
            if (self.changed) {
                any_changed = true;
                try self.analysis.cache.markFunctionDirty(@intCast(i));
            }
        }
        for (self.built.consts.items) |c| {
            self.changed = false;
            if (c.init) |root| try self.rewrite(root);
            if (self.changed) any_changed = true;
        }
        return any_changed;
    }

    /// Top-down: a member whose parent is not a member starts an island;
    /// everything below a member is a member, so the walk stops there.
    fn markIslandRoots(self: *Rewriter, id: hir.ExprId) Error!void {
        if (id < self.enc.len and self.enc[id]) {
            self.island_root[id] = true;
            return;
        }
        const pr = self.p();
        for (pr.operands(id)) |op| try self.markIslandRoots(op);
        for (pr.regionsOf(id)) |r| try self.markIslandRoots(pr.region(r).root);
    }

    /// `true` when `id` is inside an island. For nodes appended by this
    /// pass (the cloned body and the `let` chain β splices) that is a
    /// structural given, not a claim about stale annotations.
    fn encOf(self: *Rewriter, id: hir.ExprId) bool {
        if (id < self.enc.len) return self.enc[id];
        return true;
    }

    /// Record that `id`'s content was overwritten in place this round. Its
    /// cached island/effect verdict now describes a dead shape: `ruleLet`
    /// refuses a `let` whose initializer is so marked, and the next
    /// round's fresh `Analysis` re-derives everything else.
    fn markDirty(self: *Rewriter, id: hir.ExprId) Error!void {
        try self.dirty.put(self.arena, id, {});
    }

    /// A node's analysis annotation is only meaningful while the pass has
    /// not rewritten its *content*. `tryBeta` runs before any rewrite at
    /// that id (from `rewrite`); `ruleLet` guards its initializer with the
    /// dirty set instead.
    fn analysisValid(self: *Rewriter, id: hir.ExprId) bool {
        return id < self.enc.len;
    }

    /// Recursive island admission (hir.md §8.1): encoding registered,
    /// semantically seg-safe, and every operand / region body an island
    /// member. Computed once per pass over the pre-rewrite tree;
    /// bottom-up so each node's children are already classified.
    fn computeIslands(self: *Rewriter) Error!void {
        const pr = self.p();
        var order = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer order.deinit(self.arena);
        var stack = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer stack.deinit(self.arena);
        for (self.built.funcs.items) |rec| try stack.append(self.arena, rec.root);
        for (self.built.consts.items) |c| {
            if (c.init) |root| try stack.append(self.arena, root);
        }
        while (stack.pop()) |id| {
            try order.append(self.arena, id);
            for (pr.operands(id)) |op| try stack.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try stack.append(self.arena, pr.region(r).root);
        }
        var i = order.items.len;
        while (i > 0) {
            i -= 1;
            const id = order.items[i];
            const d = hir.registry.get(pr.node(id).op);
            var ok = d.seg != null and (try self.analysis.isSegSafe(id));
            if (ok) {
                for (pr.operands(id)) |op| {
                    if (!self.enc[op]) {
                        ok = false;
                        break;
                    }
                }
            }
            if (ok) {
                for (pr.regionsOf(id)) |r| {
                    if (!self.enc[pr.region(r).root]) {
                        ok = false;
                        break;
                    }
                }
            }
            self.enc[id] = ok;
            if (ok) self.island_count += 1;
        }
    }

    // -----------------------------------------------------------------
    // The SEG arena
    // -----------------------------------------------------------------

    /// Encode, saturate and extract the island rooted at `id` (hir.md
    /// §8.1–§8.2), writing the saturated form back into the tree. Run
    /// *before* the local walk over the island's interior, so encode sees
    /// the un-rewritten island and every `isSegSafe` verdict it consumes
    /// still describes the node it is looking at (the pass header's "no
    /// transform may rely on the pre-rewrite static conclusions" applies
    /// to nodes this round has already touched).
    ///
    /// The scratch arena is dropped on return: the arena's internal
    /// tables are per-island garbage, and only the sites it overwrote
    /// survive. They are reported back so the driver can mark them dirty.
    fn saturateIsland(self: *Rewriter, id: hir.ExprId) Error!void {
        var scratch = std.heap.ArenaAllocator.init(self.arena);
        defer scratch.deinit();
        const result = try hir_egraph.optimizeIsland(
            scratch.allocator(),
            self.p(),
            self.analysis,
            id,
            .{ .max_rounds = self.max_egraph_rounds, .rules = .{
                .fold = self.cfg.egraph_fold,
                .algebra = self.cfg.egraph_algebra,
                .cond = self.cfg.egraph_cond,
                .project = self.cfg.egraph_project,
                .cse = self.cfg.egraph_cse,
                .ac = self.cfg.egraph_ac,
            } },
        );
        if (result.stats.enodes == 0) return; // encode rejected the island
        self.egraph_islands += 1;
        self.egraph_rounds += result.stats.rounds;
        self.egraph_converged = self.egraph_converged and result.stats.converged;
        self.egraph_merges += result.stats.merges;
        self.egraph_unions += result.stats.unions;
        self.egraph_copies += result.stats.copied;
        self.egraph_extract_cost += result.stats.extract_cost;
        self.folds += result.stats.folds;
        self.algebra += result.stats.algebra;
        self.conds += result.stats.conds;
        self.projects += result.stats.projects;
        self.egraph_folds_matched += result.stats.folds_matched;
        self.egraph_algebra_matched += result.stats.algebra_matched;
        self.egraph_conds_matched += result.stats.conds_matched;
        self.egraph_projects_matched += result.stats.projects_matched;
        self.egraph_ac += result.stats.ac;
        self.egraph_assoc += result.stats.assoc;
        self.shares += result.stats.materialized;
        if (!result.changed) return;
        self.changed = true;
        for (result.written) |site| try self.markDirty(site);
    }

    // -----------------------------------------------------------------
    // Driver
    // -----------------------------------------------------------------

    fn rewrite(self: *Rewriter, id: hir.ExprId) Error!void {
        // β is a boundary rewrite (hir.md §8.4), not an island rewrite:
        // its callee is a `fn_ref`, which has no SEG encoding, so the
        // call is never an island member. It is admitted by its contract
        // inside `tryBeta` instead of by the island predicate. The same
        // holds for the `let` family (`applyRules` still tries it when the
        // node is not an island) and for η.
        if (self.analysisValid(id)) {
            if (self.cfg.beta and try self.tryBeta(id)) {
                self.changed = true;
                self.beta += 1;
                try self.markDirty(id);
                // The call node now holds a let chain; simplify it (and
                // recurse into the freshly cloned body). The result is
                // island-internal by construction, so rules are allowed
                // even though the original call id was not an island.
                try self.rewriteChildren(id);
                _ = try self.applyRules(id, true);
                return;
            }
            // η is the other boundary rewrite: its `fn_ref` operand has no
            // SEG encoding, so it is admitted by its own §8.5 contract
            // rather than by island membership (`encOf`).
            if (self.cfg.eta and try self.tryEta(id)) {
                self.changed = true;
                self.etas += 1;
                try self.markDirty(id);
            }
        }
        // A maximal island goes through the e-graph *before* the local walk
        // below: encode must see the island in its round-start shape, so
        // every `isSegSafe` verdict it consumes still describes the node it
        // is looking at. The local walk then runs over the extracted tree
        // (so a `match` whose scrutinee the arena just folded reduces in
        // the same round), and the interior of an island is reached there
        // rather than here (only maximal roots take this branch).
        if (id < self.enc.len and self.island_root[id]) {
            try self.saturateIsland(id);
        }
        try self.rewriteChildren(id);
        if (try self.applyRules(id, self.encOf(id))) self.changed = true;
    }

    /// Copy the operand/region/param id lists into arena-owned slices
    /// before any work that may append to the program's flat buffers.
    /// `Program.operands`/`regionsOf`/`params` return slices into
    /// `expr_buffer`/`region_buffer`/`binder_buffer`; an append (a rule
    /// materializing a new node, a β clone) can reallocate those buffers
    /// and move the memory out from under such a slice.
    fn dupOperands(self: *Rewriter, id: hir.ExprId) Error![]hir.ExprId {
        const src = self.p().operands(id);
        const out = try self.arena.alloc(hir.ExprId, src.len);
        @memcpy(out, src);
        return out;
    }

    fn dupRegions(self: *Rewriter, id: hir.ExprId) Error![]hir.RegionId {
        const src = self.p().regionsOf(id);
        const out = try self.arena.alloc(hir.RegionId, src.len);
        @memcpy(out, src);
        return out;
    }

    fn dupParams(self: *Rewriter, rid: hir.RegionId) Error![]hir.BinderId {
        const src = self.p().params(rid);
        const out = try self.arena.alloc(hir.BinderId, src.len);
        @memcpy(out, src);
        return out;
    }

    /// Recurse into the operands and region roots. Ids are stable across
    /// rewriting (rules mutate a node's fields, never its position), so
    /// no parent slot has to be updated.
    fn rewriteChildren(self: *Rewriter, id: hir.ExprId) Error!void {
        const pr = self.p();
        const ops = try self.dupOperands(id);
        for (ops) |op| try self.rewrite(op);
        const regs = try self.dupRegions(id);
        for (regs) |r| {
            const root = pr.region(r).root;
            try self.rewrite(root);
        }
    }

    // -----------------------------------------------------------------
    // β-reduction (hir.md §8.4) — the v1 boundary rewrite
    // -----------------------------------------------------------------

    /// `call(fn_ref-to-λ, args…)` → nested `let`s binding the λ params to
    /// the args, body = the cloned λ body. Contract (hir.md §8.4,
    /// docs/effects.md §10.4): the call result is Copy, the evaluated call
    /// subtree is literally cleanup-free and passes the ownership gate, the
    /// λ body is a seg-safe single expression (`isSegSafe`, not a `seq`
    /// root), and the λ is copied with fresh binders (scope mapping).
    /// Evaluation count and LTR order are structural: β→let evaluates each
    /// argument once, in order, and never deletes, duplicates, or reorders
    /// it — so an argument may carry traps, divergence, `Q`, or observable
    /// effects and is preserved verbatim. `preserves_cleanup` holds because
    /// both the evaluated call subtree (args; the body is deferred) and the
    /// body itself are cleanup-free, with the args staying Copy.
    fn tryBeta(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const n = pr.node(id);
        if (hir.registry.get(n.op).seg != .app) return false;
        const ops = try self.dupOperands(id);
        if (ops.len == 0) return false;

        const callee = ops[0];
        const cn = pr.node(callee);
        if (std.mem.indexOfScalar(u8, hir.registry.get(cn.op).name, '.') != null) return false; // typed op ≠ fn_ref
        if (!std.mem.eql(u8, hir.registry.get(cn.op).name, "fn_ref")) return false;
        const fid = switch (cn.payload) {
            .func => |fr| switch (fr) {
                .func => |f| f,
                .host => return false,
            },
            else => return false,
        };
        if (fid >= self.built.funcs.items.len) return false;
        const rec = self.built.funcs.items[fid];
        if (rec.kind != .lambda) return false;
        if (self.beta_done.contains(fid)) return false;

        // Contract: the argument-independent residue of the call-level
        // island predicate. `isSegSafe(id)` itself is deliberately not used
        // — it also demands the arguments be total and observable-effect-
        // free, which β does not need and would wrongly reject an effectful
        // argument (docs/effects.md §10.4).
        const result_cap = try self.analysis.capabilityOf(pr.typeOf(n.ty)) orelse return false;
        if (result_cap != .copy) return false;
        // The declared contract (`beta_rule`) goes through the legality
        // engine, which knows requirements, not opcodes: the
        // evaluation-count certificate (structural — the nested LTR lets
        // below) and the `cleanup_free_subtree` cleanup proof.
        if (!try rewrite_contract.check(self.analysis, beta_rule.legality, .{ .expr = id })) return false;
        if (!try rewrite_contract.checkCleanup(beta_rule, self.analysis, .{ .cleanup_free_subtree = id })) return false;

        const lambda = pr.node(rec.root);
        if (hir.registry.get(lambda.op).seg != .binder) return false;
        const lam_regs = try self.dupRegions(rec.root);
        if (lam_regs.len != 1) return false;
        const params = try self.dupParams(lam_regs[0]);
        if (ops.len - 1 != params.len) return false;
        const body = pr.region(lam_regs[0]).root;
        if (!try self.analysis.isSegSafe(body)) return false;
        // "single expression" (§8.4): no statement sequence.
        if (std.mem.eql(u8, hir.registry.get(pr.node(body).op).name, "seq")) return false;

        // Arguments stay Copy (a Unique / borrowed argument would change
        // ownership at the synthesized let); their effects are preserved
        // verbatim, so no purity is required. `cleanupFree(id)` inside the
        // contract's `cleanup_free_subtree` proof above already covers every
        // argument's cleanup and `ownershipGate(id)` its ownership (a
        // `move`/borrow argument leaves `callArgUse` at `.consume`/`.borrow`,
        // which the gate rejects). The explicit Copy checks are the
        // ownership half of that proof kept explicit: the gate short-
        // circuits `transfer == .lambda` nodes, so it does not by itself
        // rule out a non-Copy result or argument.
        var k: usize = 1;
        while (k < ops.len) : (k += 1) {
            const arg = ops[k];
            const cap = try self.analysis.capabilityOf(pr.typeOf(pr.node(arg).ty)) orelse return false;
            if (cap != .copy) return false;
        }

        // Fresh binders for the λ params (maps_scope), then clone the
        // body with every binder reference remapped; every cloned node is
        // stamped with the call site's FE (maps_full_expr).
        var map = std.AutoHashMapUnmanaged(hir.BinderId, hir.BinderId).empty;
        defer map.deinit(self.arena);
        const fresh = try self.arena.alloc(hir.BinderId, params.len);
        for (params, 0..) |pb, j| {
            const b = pr.binder(pb);
            fresh[j] = try pr.addBinder(pr.typeOf(b.ty), .value);
            try map.put(self.arena, pb, fresh[j]);
        }
        self.clone_fe = n.full_expr;
        const new_body = try self.cloneTree(body, &map);

        // Nested lets, outermost = first parameter (LTR).
        const let_op = hir.opId("let").?;
        var result = new_body;
        var j: usize = params.len;
        while (j > 0) {
            j -= 1;
            const rid = try pr.addRegion(&.{fresh[j]}, result, null);
            const regs = try pr.addRegions(&.{rid});
            const opr = try pr.addOperands(&.{ops[j + 1]});
            result = try pr.addExpr(.{
                .op = let_op,
                .ty = n.ty,
                .operands = opr,
                .regions = regs,
                .full_expr = n.full_expr,
                .sema = try pr.internSema(.owned, .pending),
            });
        }

        // Overwrite the call node in place with the outermost let.
        pr.exprs.items[id] = pr.node(result);
        try self.beta_done.put(self.arena, fid, {});
        return true;
    }

    // -----------------------------------------------------------------
    // η-reduction (hir.md §8.5)
    // -----------------------------------------------------------------

    /// `fn (B0: T) => call(fnref F, %B0)` is extensionally `fnref F`. The λ
    /// node itself is only ever a `FuncRecord.root` (the builder's
    /// `buildLambda` returns a `fn_ref` value), so the operational form of
    /// the rewrite is to redirect the `fn_ref` payload at each value
    /// position; mutating the record root would break the lowering's "a
    /// function root is a λ" invariant (`hir_lower.zig`).
    ///
    /// Like β this is a boundary rewrite, not an island rewrite: a
    /// `fn_ref` carries no SEG encoding (`encOf` is false), so island
    /// membership must not gate it. The §8.5 precondition list replaces
    /// that gate:
    ///
    /// - v1 only `callee = fn_ref` (a more general callee expression could
    ///   change evaluation after expansion);
    /// - the wrapper's function type equals the callee's, parameter modes
    ///   and arity included (O(1) canonical `HIRTypeId` equality);
    /// - the callee is applied to the wrapper's own parameters, once each,
    ///   in order — which is also the whole of the "`B0` not free in the
    ///   callee" / capture condition, since a `fn_ref` closes over no
    ///   binder;
    /// - the body is total and observable-effect-free (`isTotal` +
    ///   `observableEffectFree` on the body call; `callBound` is
    ///   argument-independent, so this is exactly the callee's summary or
    ///   host declaration).
    ///
    /// The redirect is idempotent and lattice-monotone: a chain
    /// `fid → F → G` resolves in one call, and once a `fn_ref` names a
    /// non-wrapper the loop breaks immediately. A chain at the
    /// `max_eta_chain` bound (a cycle, or a pathological tower) is
    /// refused, so the rule never oscillates across rounds.
    fn tryEta(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const n = pr.node(id);
        if (!std.mem.eql(u8, hir.registry.get(n.op).name, "fn_ref")) return false;
        // The declared contract (`eta_rule`): a value redirect that
        // evaluates nothing, so the evaluation-count certificate is the
        // whole operational obligation. Discharged through the legality
        // engine, which knows requirements, not opcodes.
        if (!try rewrite_contract.check(self.analysis, eta_rule.legality, .{ .expr = id })) return false;
        const start = n.payload.func;
        var target = start;
        var steps: usize = 0;
        while (steps < max_eta_chain) : (steps += 1) {
            const fid = switch (target) {
                .func => |f| f,
                .host => break,
            };
            if (fid >= self.built.funcs.items.len) break;
            const rec = self.built.funcs.items[fid];
            if (rec.kind != .lambda) break;
            const callee = self.etaRedexCallee(rec.root, n.ty) orelse break;
            if (!self.redexTotal(rec.root)) break;
            target = pr.node(callee).payload.func;
        }
        if (steps >= max_eta_chain) return false; // cycle / over-long chain: refuse
        if (std.meta.eql(target, start)) return false;
        pr.exprs.items[id].payload = .{ .func = target };
        return true;
    }

    /// The callee operand when `lam_root`'s body is exactly
    /// `call(fn_ref …, %B0, %B1, …)` forwarding its own parameters in
    /// order, and `wrapper_ty` equals the callee's function type; `null`
    /// otherwise. Pure structural predicate — the totality gate is
    /// `redexTotal`.
    fn etaRedexCallee(self: *Rewriter, lam_root: hir.ExprId, wrapper_ty: hir.HIRTypeId) ?hir.ExprId {
        const pr = self.p();
        if (!std.mem.eql(u8, hir.registry.get(pr.node(lam_root).op).name, "lambda")) return null;
        const regs = pr.regionsOf(lam_root);
        if (regs.len != 1) return null;
        const body = pr.region(regs[0]).root;
        if (!std.mem.eql(u8, hir.registry.get(pr.node(body).op).name, "call")) return null;
        const bops = pr.operands(body);
        if (bops.len == 0) return null;
        const callee = bops[0];
        if (!std.mem.eql(u8, hir.registry.get(pr.node(callee).op).name, "fn_ref")) return null;
        const params = pr.params(regs[0]);
        if (bops.len - 1 != params.len) return null;
        if (wrapper_ty != pr.node(callee).ty) return null;
        for (params, 0..) |param, i| {
            const arg = pr.node(bops[i + 1]);
            if (!std.mem.eql(u8, hir.registry.get(arg.op).name, "local")) return null;
            if (arg.payload.binder != param) return null;
        }
        return callee;
    }

    /// §8.5's "callee total (no effects, no trap)", read off the
    /// argument-independent body-call summary.
    fn redexTotal(self: *Rewriter, lam_root: hir.ExprId) bool {
        const pr = self.p();
        const regs = pr.regionsOf(lam_root);
        if (regs.len != 1) return false;
        const body = pr.region(regs[0]).root;
        if (!self.analysisValid(body)) return false;
        return self.analysis.isTotal(body) and self.analysis.observableEffectFree(body);
    }

    /// Deep-copy `id`, allocating fresh regions/binders and remapping
    /// every `local` reference through `map` (extended with the fresh
    /// params of each nested region). Used only by β.
    fn cloneTree(self: *Rewriter, id: hir.ExprId, map: *std.AutoHashMapUnmanaged(hir.BinderId, hir.BinderId)) Error!hir.ExprId {
        const pr = self.p();
        const n = pr.node(id);
        const src_ops = try self.dupOperands(id);
        const new_ops = try self.arena.alloc(hir.ExprId, src_ops.len);
        for (src_ops, 0..) |op, i| new_ops[i] = try self.cloneTree(op, map);

        const src_regs = try self.dupRegions(id);
        const new_regs = try self.arena.alloc(hir.RegionId, src_regs.len);
        for (src_regs, 0..) |rid, i| {
            const r = pr.region(rid);
            const src_params = try self.dupParams(rid);
            const new_params = try self.arena.alloc(hir.BinderId, src_params.len);
            for (src_params, 0..) |pb, k| {
                if (map.get(pb)) |mapped| {
                    new_params[k] = mapped;
                } else {
                    const b = pr.binder(pb);
                    new_params[k] = try pr.addBinder(pr.typeOf(b.ty), b.mode);
                    try map.put(self.arena, pb, new_params[k]);
                }
            }
            const new_root = try self.cloneTree(r.root, map);
            const new_pat: ?hir.PatternId = if (r.pattern) |pid| try self.clonePattern(pid, map) else null;
            new_regs[i] = try pr.addRegion(new_params, new_root, new_pat);
        }

        var nn = n;
        nn.operands = try pr.addOperands(new_ops);
        nn.regions = try pr.addRegions(new_regs);
        nn.full_expr = self.clone_fe;
        nn.sema = try pr.internSema(pr.viewOf(id), .pending);
        if (std.mem.eql(u8, hir.registry.get(n.op).name, "local")) {
            if (map.get(n.payload.binder)) |mapped| nn.payload = .{ .binder = mapped };
        }
        const new_id = try pr.addExpr(nn);
        // A cloned construct owns the same temporaries as its donor: move
        // any cleanup token that named the donor to the clone
        // (docs/effects.md §11.2). β's contract already requires the body
        // to be cleanup-free, so this is a no-op for admitted rewrites;
        // it keeps a token-bearing clone from silently pointing at the
        // unreachable donor.
        pr.remapCleanupOrigin(id, new_id);
        return new_id;
    }

    fn clonePattern(self: *Rewriter, id: hir.PatternId, map: *std.AutoHashMapUnmanaged(hir.BinderId, hir.BinderId)) Error!hir.PatternId {
        const pr = self.p();
        const pat = pr.pattern(id);
        const out: hir.Pattern = switch (pat) {
            .wildcard, .literal => pat,
            .bind => |b| .{ .bind = map.get(b) orelse b },
            .type_test => |tt| .{ .type_test = .{ .ty = tt.ty, .bind = map.get(tt.bind) orelse tt.bind } },
            .tuple => |elems| blk: {
                const new = try self.arena.alloc(hir.PatternId, elems.len);
                for (elems, 0..) |e, i| new[i] = try self.clonePattern(e, map);
                break :blk .{ .tuple = new };
            },
            .list => |lp| blk: {
                const new = try self.arena.alloc(hir.PatternId, lp.elems.len);
                for (lp.elems, 0..) |e, i| new[i] = try self.clonePattern(e, map);
                break :blk .{ .list = .{ .elems = new, .rest = if (lp.rest) |r| try self.clonePattern(r, map) else null } };
            },
            .struct_ => |sp| blk: {
                const new = try self.arena.alloc(hir.Pattern.FieldPattern, sp.fields.len);
                for (sp.fields, 0..) |f, i| new[i] = .{ .field = f.field, .pat = try self.clonePattern(f.pat, map) };
                break :blk .{ .struct_ = .{ .fields = new } };
            },
            .variant => |vp| .{ .variant = .{ .tag = vp.tag, .payload = if (vp.payload) |pld| try self.clonePattern(pld, map) else null } },
        };
        return pr.addPattern(out);
    }

    // -----------------------------------------------------------------
    // Ordinary local rules
    // -----------------------------------------------------------------

    /// Try the two *tree* rules left at `id` (one per visit): the `let`
    /// family and the known-variant `match` reduction. The union rules
    /// (constant folding, integer algebra, constant conditions, aggregate
    /// projection, CSE sharing) now live in the SEG arena
    /// (`hir_egraph.zig`) and run at the island root; `allowed` is the
    /// island gate, which only `match` needs (its arms must be island
    /// members).
    fn applyRules(self: *Rewriter, id: hir.ExprId, allowed: bool) Error!bool {
        if ((self.cfg.let_dead or self.cfg.let_forward or self.cfg.let_atom) and try self.ruleLet(id)) {
            self.lets += 1;
            try self.markDirty(id);
            return true;
        }
        if (self.cfg.match and allowed and std.mem.eql(u8, hir.registry.get(self.p().node(id).op).name, "match")) {
            if (try self.ruleMatch(id)) {
                self.matches += 1;
                try self.markDirty(id);
                return true;
            }
        }
        if (self.cfg.reorder and try self.tryReorder(id)) {
            self.reorders += 1;
            try self.markDirty(id);
            return true;
        }
        return false;
    }

    /// The reorder rule (docs/effects.md §10.3–§10.5): canonicalize the
    /// operand order of a `strict_ltr` parent by swapping an adjacent pair
    /// that is order-compatible under the active lattice instance and not
    /// already in canonical summary order. This is the production consumer
    /// of `rewrite_contract.swap_operands` — the rule through which a
    /// second lattice instance changes *AIR*, not just a legality verdict:
    /// a `hierarchy` provider that proves two sibling host reads disjoint
    /// admits the swap the flat instance refuses.
    ///
    /// Termination contract: `rowLess` is a strict total order on the rows
    /// the pair is compared by, so each swap moves that pair one step
    /// closer to the canonical order and the pass's `max_iterations` bound
    /// caps the loop — reordering, like the other rules, offers a
    /// bounded-round contract, not a decreasing-measure one. The only
    /// operands considered are effect-bearing (a non-empty canonical row),
    /// so a pure pair never churns under any instance.
    fn tryReorder(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const n = pr.node(id);
        if (hir.registry.get(n.op).policy != .strict_ltr) return false;
        const ops = try self.dupOperands(id);
        if (ops.len < 2) return false;
        for (0..ops.len - 1) |i| {
            const a = ops[i];
            const b = ops[i + 1];
            if (self.dirty.contains(a) or self.dirty.contains(b)) continue;
            const a_s = self.analysis.readySummary(a) orelse continue;
            const b_s = self.analysis.readySummary(b) orelse continue;
            // Only pairs that actually carry effects: a pure operand has an
            // empty canonical row, and swapping it past anything is the
            // flat instance's no-op (every numeric op would otherwise be a
            // candidate and the corpus would churn).
            if (a_s.accesses.isEmpty() or b_s.accesses.isEmpty()) continue;
            // Already in canonical order — nothing to do. Equal rows are
            // trivially canonical and `canSwapOperands` refuses them too.
            if (rowLess(a_s, b_s)) continue;
            if (!try rewrite_contract.check(
                self.analysis,
                reorder_rule.legality,
                .{ .swap = .{ .parent = id, .lhs_slot = @intCast(i), .rhs_slot = @intCast(i + 1) } },
            )) continue;
            // Swap the two operand slots in the live expr_buffer. `ops` is
            // a private copy; the node's operands are a contiguous Range
            // into `expr_buffer`, so swapping those two entries is the
            // whole tree mutation the rule needs.
            const range = n.operands;
            const lo = range.start + @as(u32, @intCast(i));
            std.mem.swap(hir.ExprId, &pr.expr_buffer.items[lo], &pr.expr_buffer.items[lo + 1]);
            return true;
        }
        return false;
    }

    /// Deterministic canonical ranking of two summaries, in the reorder
    /// rule's instance-shape: `a < b` when `a`'s canonical access row sorts
    /// before `b`'s (by all-mode bits, then (mode, resource) lexicographic,
    /// then row length), with the flag bits as the final tie-break. Rows
    /// are canonical (sorted, deduped), so this is a strict total order
    /// over the pairs the rule examines. The pair's *swappability* is the
    /// instance's verdict (`canSwapOperands`); this order only decides
    /// which direction "canonical" points.
    fn rowLess(a: effects.Summary, b: effects.Summary) bool {
        if (a.accesses.all != b.accesses.all) return a.accesses.all < b.accesses.all;
        const aa = a.accesses.accesses;
        const bb = b.accesses.accesses;
        const n = @min(aa.len, bb.len);
        for (0..n) |i| {
            const x = aa[i];
            const y = bb[i];
            if (x.mode != y.mode) return @intFromEnum(x.mode) < @intFromEnum(y.mode);
            if (x.resource.eql(y.resource)) continue;
            return x.resource.lessThan(y.resource);
        }
        if (aa.len != bb.len) return aa.len < bb.len;
        if (a.may_trap != b.may_trap) return !a.may_trap;
        if (a.may_diverge != b.may_diverge) return !a.may_diverge;
        return !a.nondeterministic and b.nondeterministic;
    }

    /// Known-variant `match` → `let` (hir.md §8.6). When the scrutinee is a
    /// `variant_make` with a statically known tag, dispatch is decided at
    /// compile time: the covering arm (the first variant arm for the tag,
    /// or the first catch-all before it — `hir_lower_control.unionMatch`
    /// coverage) replaces the match, with its pattern leaves bound to the
    /// constructor's payload operands as nested `let`s. Copy-only: the
    /// match reached this rule only as an island member, so `isSegSafe`
    /// already proved the Copy scrutinee, cleanup-free arms and
    /// observable-effect-free region bodies (a consuming/borrowed
    /// scrutinee or an effectful arm never becomes an island member). The
    /// arm's own region params become the new binders, so the body needs
    /// no substitution and no variant pattern is put on a synthesized
    /// `let` (hir.md §5.4).
    fn ruleMatch(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        const ops = try self.dupOperands(id);
        if (ops.len != 1) return false;
        const scrut = ops[0];
        const sn = pr.node(scrut);
        if (!std.mem.eql(u8, hir.registry.get(sn.op).name, "variant_make")) return false;
        // The scrutinee's union declaration fixes the tag range and the
        // constructor arity (the HIR validator checks neither).
        const named = switch (pr.typeOf(sn.ty)) {
            .named => |n| n,
            else => return false,
        };
        if (named.id >= self.built.types.len) return false;
        const ud = switch (self.built.types[named.id]) {
            .union_ => |u| u,
            else => return false,
        };
        const tag = sn.payload.tag;
        if (tag >= ud.variants.len) return false;
        const arity = ud.variants[tag].payloads.len;
        const payload_ops = try self.dupOperands(scrut);
        if (payload_ops.len != arity) return false;

        const regs = try self.dupRegions(id);
        for (regs) |rid| {
            const pat = pr.region(rid).pattern orelse return false;
            switch (pr.pattern(pat)) {
                .wildcard => return self.spliceCatchAll(id, rid, null),
                .bind => |b| return self.spliceCatchAll(id, rid, b),
                .variant => |vp| {
                    if (vp.tag >= ud.variants.len) return false;
                    if (vp.tag != tag) continue;
                    return self.spliceVariant(id, rid, vp, payload_ops);
                },
                // A union match admits only variant / catch-all patterns;
                // anything else is malformed and left alone.
                else => return false,
            }
        }
        return false;
    }

    /// A catch-all arm binds the whole scrutinee (`bind`) or discards it
    /// (`wildcard`).
    fn spliceCatchAll(self: *Rewriter, id: hir.ExprId, rid: hir.RegionId, binder: ?hir.BinderId) Error!bool {
        const pr = self.p();
        const params = try self.dupParams(rid);
        if (binder) |b| {
            if (params.len != 1 or params[0] != b) return false;
            const scrut = (try self.dupOperands(id))[0];
            try self.spliceArm(id, &.{b}, &.{scrut}, pr.region(rid).root);
        } else {
            if (params.len != 0) return false;
            pr.exprs.items[id] = pr.node(pr.region(rid).root);
        }
        return true;
    }

    /// A variant arm binds its payload leaves to the constructor's
    /// operands in order. Only `bind` / `wildcard` leaves are admitted —
    /// a nested or refutable pattern cannot be discharged by the outer
    /// tag alone — and an unbound operand is dropped, which island
    /// admission proved unobservable.
    fn spliceVariant(self: *Rewriter, id: hir.ExprId, rid: hir.RegionId, vp: hir.Pattern.VariantPattern, ops: []const hir.ExprId) Error!bool {
        const pr = self.p();
        const params = try self.dupParams(rid);
        const arity = ops.len;
        var binders = std.ArrayListUnmanaged(?hir.BinderId).empty;
        defer binders.deinit(self.arena);
        if (vp.payload) |pp| {
            if (arity == 1) {
                switch (pr.pattern(pp)) {
                    .bind => |b| try binders.append(self.arena, b),
                    .wildcard => try binders.append(self.arena, null),
                    else => return false,
                }
            } else {
                const elems = switch (pr.pattern(pp)) {
                    .tuple => |es| es,
                    else => return false,
                };
                if (elems.len != arity) return false;
                for (elems) |el| {
                    switch (pr.pattern(el)) {
                        .bind => |b| try binders.append(self.arena, b),
                        .wildcard => try binders.append(self.arena, null),
                        else => return false,
                    }
                }
            }
        } else if (arity != 0) {
            return false;
        }
        // The region's params are exactly the materialized binding leaves,
        // in order (the §10.1 leaf/param bijection).
        var k: usize = 0;
        for (binders.items) |b| {
            if (b) |bid| {
                if (k >= params.len or params[k] != bid) return false;
                k += 1;
            }
        }
        if (k != params.len) return false;
        try self.spliceArm(id, binders.items, ops, pr.region(rid).root);
        return true;
    }

    /// Replace the `match` node `id` with
    /// `let b0 = v0 in let b1 = v1 in … body`, skipping `null` binders
    /// (their values are island-safe — total and observable-effect-free —
    /// so dropping the evaluation is unobservable). Nesting is in payload
    /// order (outermost = first), preserving the scrutinee's left-to-right
    /// evaluation (hir.md §5.5).
    fn spliceArm(self: *Rewriter, id: hir.ExprId, binders: []const ?hir.BinderId, values: []const hir.ExprId, body: hir.ExprId) Error!void {
        const pr = self.p();
        std.debug.assert(binders.len == values.len);
        const ty = pr.node(id).ty;
        const fe = pr.node(id).full_expr;
        var result = body;
        var i = binders.len;
        while (i > 0) {
            i -= 1;
            const b = binders[i] orelse continue;
            const rid = try pr.addRegion(&.{b}, result, null);
            const regs = try pr.addRegions(&.{rid});
            const opr = try pr.addOperands(&.{values[i]});
            result = try pr.addExpr(.{
                .op = hir.opId("let").?,
                .ty = ty,
                .operands = opr,
                .regions = regs,
                .full_expr = fe,
                .sema = try pr.internSema(.owned, .pending),
            });
        }
        pr.exprs.items[id] = pr.node(result);
    }

    /// Plain `let` simplification (hir.md §8.3 / §8.7): dead let,
    /// used-once forwarding, and trivial-atom forwarding. All three
    /// strictly reduce the tree's node count.
    ///
    /// This is a **boundary rewrite** like β / η: a source-level `let`'s
    /// initializer opens its own full expression (hir.md §5.6), so the
    /// `let` node is never an island member and the island gate cannot
    /// admit it. The `let_*` contracts declared in this file replace that
    /// gate, one per branch:
    ///
    /// - **dead** (`uses == 0`): `isDiscardable(init)` — dropping the
    ///   initializer's evaluation must be unobservable (`10 / y` traps, a
    ///   host write is observable, a borrowed view fails the ownership
    ///   gate). The dropped initializer's own registered full-expression
    ///   temporaries go with it, which is licensed because
    ///   `isDiscardable` folds `discard_view(observed_effect)`. Removing
    ///   the binding also removes its scope-end destructor, which needs
    ///   the `binder_destruction` proof (Copy binder, or a discardable
    ///   destructor).
    /// - **used-once** (`uses == 1`): the initializer must be an island
    ///   member (`encOf`) — Copy, one full expression, literally
    ///   cleanup-free and ownership-gated — and unrewritten this round (a
    ///   rewritten node's cached verdict describes a dead shape; the fold
    ///   then waits for the next round's recomputed islands, which is how
    ///   the §8.7 example closes one round after its initializer stops
    ///   being a call). The `cleanup_free_subtree` proof re-checks that
    ///   verdict through the engine, so the move relocates no cleanup
    ///   registration, and Copy leaves no scope-end destructor behind.
    ///   The moved subtree is re-stamped onto the destination full
    ///   expression (`maps_full_expr`).
    /// - **trivial atom** (`uses >= 2`, hir.md §8.3): a `const` / `local` /
    ///   `fn_ref` initializer is copied to every use, which needs
    ///   `isDuplicable` — the admission proof the v1 rule lacked for a
    ///   borrowed (ownership gate) or nondeterministic (`Q`) atom.
    ///
    /// The *match* layer additionally refuses a `let` whose binder is read
    /// from a `move` / `drop` operand slot (those lower through the operand
    /// node's own binder payload, so only a `local` initializer may be
    /// forwarded there) and one whose binder type differs from the
    /// initializer's node type (an implicit coercion, which the substitution
    /// would erase).
    fn ruleLet(self: *Rewriter, id: hir.ExprId) Error!bool {
        const pr = self.p();
        if (!std.mem.eql(u8, hir.registry.get(pr.node(id).op).name, "let")) return false;
        const ops = pr.operands(id);
        const regs = pr.regionsOf(id);
        if (ops.len != 1 or regs.len != 1) return false;
        const region = pr.region(regs[0]);
        if (region.pattern != null) return false; // destructuring let: no rule
        const params = pr.params(regs[0]);
        if (params.len != 1) return false;
        const bind = params[0];
        const init = ops[0];
        const body = region.root;

        const scan = try self.scanUses(body, bind);
        const uses = scan.count;
        if (self.cfg.let_dead and uses == 0) {
            if (!try rewrite_contract.check(self.analysis, let_dead_rule.legality, .{ .expr = init })) return false;
            const bind_ty = pr.typeOf(pr.binder(bind).ty);
            if (!try rewrite_contract.checkCleanup(let_dead_rule, self.analysis, .{ .binder_destruction = bind_ty })) return false;
            pr.exprs.items[id] = pr.node(body);
            // The surviving reachable node is `id`; a cleanup token that
            // named the region root follows its value there
            // (docs/effects.md §11.2 origin remap). The removed binding's
            // end-of-scope destructor is gone with it: retire its token.
            pr.remapCleanupOrigin(body, id);
            pr.retireScopeTokens(bind);
            return true;
        }
        // Forwarding / duplication substitutes the initializer's *content*
        // into binder-reference slots, which keeps the slot's type only when
        // the initializer's node type is the binder's. A `let` may instead
        // carry an implicit coercion (`let b: any = %value`), and the
        // lowering dispatches on the operand node's own type (`any_cast`
        // packs vs unpacks) — such a `let` stays.
        if (pr.node(init).ty != pr.binder(bind).ty) return false;
        // `move` / `drop` lower their operand through the operand node's own
        // binder payload (`hir_lower_expr.moveNode`), so a forwarded
        // initializer may only land in such a slot when it is itself a
        // `local` node.
        if (scan.binder_operand and !std.mem.eql(u8, hir.registry.get(pr.node(init).op).name, "local")) return false;
        if (self.cfg.let_forward and uses == 1) {
            if (!self.encOf(init)) return false;
            // A node rewritten earlier this round has a dead shape behind
            // its cached island verdict; defer the fold to next round's
            // fresh analysis.
            // ponytail: one-round deferral (bounded by `max_iterations`), not
            // a mid-round island rebuild; revisit if a program ever needs the
            // fold inside the bound.
            if (init < self.enc.len and self.dirty.contains(init)) return false;
            if (!try rewrite_contract.check(self.analysis, let_forward_rule.legality, .{ .expr = init })) return false;
            if (!try rewrite_contract.checkCleanup(let_forward_rule, self.analysis, .{ .cleanup_free_subtree = init })) return false;
            const cap = try self.analysis.capabilityOf(pr.typeOf(pr.node(init).ty)) orelse return false;
            if (cap != .copy) return false;
            try self.substOnce(body, bind, init);
            pr.exprs.items[id] = pr.node(body);
            pr.remapCleanupOrigin(body, id);
            return true;
        }
        // The trivial-atom branch is the `uses >= 2` duplication case; a
        // disabled dead / used-once branch must not fall into it.
        if (uses < 2) return false;
        if (!self.cfg.let_atom or !isTrivialAtom(pr, init)) return false;
        if (!try rewrite_contract.check(self.analysis, let_atom_rule.legality, .{ .expr = init })) return false;
        try self.substAll(body, bind, init);
        pr.exprs.items[id] = pr.node(body);
        pr.remapCleanupOrigin(body, id);
        return true;
    }

    const UseScan = struct {
        count: usize = 0,
        /// Whether a use sits in a *binder-reference operand position*
        /// (`move` / `drop` operand 0), which the lowering reads through the
        /// operand node's own payload.
        binder_operand: bool = false,
    };

    fn scanUses(self: *Rewriter, root: hir.ExprId, bind: hir.BinderId) Error!UseScan {
        const pr = self.p();
        var scan = UseScan{};
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            const n = pr.node(id);
            const name = hir.registry.get(n.op).name;
            if (std.mem.eql(u8, name, "local") and n.payload.binder == bind) scan.count += 1;
            if (std.mem.eql(u8, name, "move") or std.mem.eql(u8, name, "drop")) {
                const ops = pr.operands(id);
                if (ops.len > 0) {
                    const arg = pr.node(ops[0]);
                    if (std.mem.eql(u8, hir.registry.get(arg.op).name, "local") and arg.payload.binder == bind) {
                        scan.binder_operand = true;
                    }
                }
            }
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
        return scan;
    }

    /// Replace the single `local bind` occurrence's *content* with the
    /// init's (a move — the init is only referenced by the let), re-stamping
    /// the moved subtree onto the use site's full expression. The island
    /// gate proved the initializer one full expression, so nothing inside it
    /// opens a nested boundary (hir.md §5.6); the re-stamp keeps the moved
    /// nodes from claiming a boundary that no longer encloses them
    /// (`maps_full_expr`). The let then becomes `let B = v in body'`; the
    /// caller drops the let.
    fn substOnce(self: *Rewriter, root: hir.ExprId, bind: hir.BinderId, init: hir.ExprId) Error!void {
        const pr = self.p();
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            const n = pr.node(id);
            if (std.mem.eql(u8, hir.registry.get(n.op).name, "local") and n.payload.binder == bind) {
                try self.restampFe(init, n.full_expr);
                pr.exprs.items[id] = pr.node(init);
                return;
            }
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }

    /// Duplicate a trivial atom (const / local / fn_ref — no regions, no
    /// evaluation) at every use of the binder, each copy carrying the use
    /// site's full expression (an atom has no subtree to re-stamp).
    fn substAll(self: *Rewriter, root: hir.ExprId, bind: hir.BinderId, init: hir.ExprId) Error!void {
        const pr = self.p();
        const atom = pr.node(init);
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            const n = pr.node(id);
            if (std.mem.eql(u8, hir.registry.get(n.op).name, "local") and n.payload.binder == bind) {
                pr.exprs.items[id] = atom;
                pr.exprs.items[id].full_expr = n.full_expr;
                continue;
            }
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }

    /// Move `root`'s subtree into full expression `fe`. λ bodies are
    /// deferred exactly as `ownershipGate` defers them (a `fn_ref` value has
    /// no λ node in it, so this is defensive).
    fn restampFe(self: *Rewriter, root: hir.ExprId, fe: hir.FullExprId) Error!void {
        const pr = self.p();
        var work = std.ArrayListUnmanaged(hir.ExprId).empty;
        defer work.deinit(self.arena);
        try work.append(self.arena, root);
        while (work.pop()) |id| {
            const n = pr.node(id);
            pr.exprs.items[id].full_expr = fe;
            if (hir.registry.get(n.op).transfer == .lambda) continue;
            for (pr.operands(id)) |op| try work.append(self.arena, op);
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        }
    }
};

fn isTrivialAtom(pr: *hir.Program, id: hir.ExprId) bool {
    const name = hir.registry.get(pr.node(id).op).name;
    return std.mem.eql(u8, name, "const") or std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "fn_ref");
}

// ---------------------------------------------------------------------------
// White-box tests (hir.md §10.2: owning module `test {}`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tuple projection fires end to end through island admission" {
    // No source construct reaches a tuple `field_get` (no element-read
    // suffix), so the program is the HIR text form: the pass must still
    // admit the read as an island and fold it.
    const parse_text = @import("hir_parse.zig").parseText;
    var p = try parse_text("fn () { field_get[0](tuple_make(10i32, 20i32)) : i32 }", .{});
    defer p.arena.deinit();
    // `parseText` returns its arena by value; re-seat the program's
    // allocator at the live copy before an appending transform touches it.
    p.program.arena = p.arena.allocator();
    const a = p.arena.allocator();
    var built = hir.BuiltProgram{ .arena = a, .program = p.program };
    try built.funcs.append(a, .{
        .name = "f",
        .kind = .member,
        .module = 0,
        .params = try a.alloc(hir.FuncParam, 0),
        .ret = try built.program.intern(.{ .primitive = .int32 }),
        .root = p.root,
    });
    const stats = try optimize(a, &built, .{});
    try testing.expect(stats.projects >= 1);
    // The lambda body is now the projected constant; the tuple_make and
    // the field_get are gone.
    const body = built.program.region(built.program.regionsOf(p.root)[0]).root;
    try testing.expectEqualStrings("const", hir.registry.get(built.program.node(body).op).name);
    try testing.expectEqual(@as(i64, 10), built.program.node(body).payload.const_value.int);
}
