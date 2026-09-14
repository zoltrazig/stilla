//! Rewrite contract types (docs/effects.md §10.3–§10.4): the two-layer
//! rewrite interface the effect-driven consumers share, plus the legality
//! engine that discharges it.
//!
//! Three questions, deliberately separate (§10.3):
//!
//! - **applicability** — "may this rule's LHS match here at all". Typed
//!   opcode / algebraic semantics / value predicates. The rule-match layer
//!   answers it and may well know opcodes: `Applicability.typed_opcode` for
//!   the folding / algebra rules (`add.i32` vs `add.f32`), `.shape` for a
//!   structural match (β's `call(fn_ref→λ, args…)`, dead-let's single-param
//!   `let`). v1 keeps this layer in the rule functions; this module only
//!   *names* the kind each rule uses.
//! - **operational legality** — "is the rewrite admissible on this node".
//!   Discard / duplicate / reorder / effect / ownership / lifetime.
//!   `Requirement` is its whole vocabulary and `check` its engine: every
//!   branch calls a derived query (`isDiscardable` / `isDuplicable` /
//!   `canSwapOperands`). Its only `switch` is over the *declared
//!   requirement tag*, never over an opcode.
//! - **boundary-rewrite contract** (§10.4; docs/hir.md §8.4) — a rewrite
//!   that is not full-expression-preserving must additionally declare its
//!   effect guarantee and its scope / full-expression / cleanup mapping:
//!   `RewriteContract`. `checkCleanup` discharges the declared cleanup
//!   obligation through `checkCleanupProof`.
//!
//! `RewriteRule` ties the three together. The v1 instances are β
//! (`hir_seg.zig`), dead-let (`hir_simplify.zig`), the SEG `let` family's
//! three branches (`hir_seg.zig`'s `let_dead_rule` / `let_forward_rule` /
//! `let_atom_rule`), η (`hir_seg.zig`'s `eta_rule`) and selective ANF
//! (`hir_simplify.zig`'s `anf_rule`).
//!
//! Deviations from the §10.3 sketch, and why: `legality` is a list of
//! requirement *tags* — a rule declaration is a static value and cannot
//! carry the `ExprId`s a derived query needs, so the subjects are supplied
//! per call as a `Subjects` value. `match` / `build` are the
//! pass-local rule functions a `RewriteRule.name` names; v1 does not make
//! the driver table-driven, so they are not function-pointer fields.
//! `effect` is a bool-set struct: one rule may hold several guarantees at
//! once. The engine's white-box equivalence test (against the derived
//! queries directly) lives in `hir_simplify_tests.zig`, which owns the HIR
//! build fixture.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const hir_effects = @import("hir_effects.zig");

pub const Error = std.mem.Allocator.Error;

/// The operational-legality vocabulary (docs/effects.md §10.3). A rule
/// declares the tags it needs; the engine evaluates them on the subjects
/// the rule supplies.
pub const Requirement = enum {
    /// `isDiscardable(subject)` — dropping the subject's evaluation is
    /// unobservable (dead-let's init; never `10 / y`, whose trap is an
    /// effect).
    discardable,
    /// `isDuplicable(subject)` — the subject may be evaluated twice or
    /// shared (CSE, `x + x → 2 * x`).
    duplicable,
    /// `canSwapOperands(parent, lhs_slot, rhs_slot)` — reordering the two
    /// slots is unobservable. Needs `Subjects.swap`, not `Subjects.expr`.
    swap_operands,
    /// The rule's own structural certificate that every subexpression is
    /// still evaluated the same number of times (β→let: one nested `let`
    /// per parameter, LTR — nothing deleted, duplicated or reordered). The
    /// engine cannot verify this; it accepts the declaration, and the
    /// warrant is the rule's construction.
    evaluation_count_preserved,
    /// `canMaterializeOperand(parent, slot)` — the operand may be hoisted
    /// into a synthesized `let` initializer (selective ANF): the operands
    /// before it may be deferred past it, and the hoisted operand's
    /// destruction lands where the anonymous temporary's did (Copy, or a
    /// parent that already transfers / discards it in place). Needs
    /// `Subjects.hoist`.
    materializable,
};

/// The subject a `Requirement` is evaluated on. `expr` is the single
/// expression every non-hoist obligation is stated over; `swap` carries the
/// parent + slot pair `swap_operands` needs; `hoist` the parent + slot
/// `materializable` needs.
pub const Subjects = struct {
    expr: hir.ExprId = hir.no_expr,
    swap: ?SwapSlots = null,
    hoist: ?HoistSlot = null,

    pub const SwapSlots = struct {
        parent: hir.ExprId,
        lhs_slot: u16,
        rhs_slot: u16,
    };

    pub const HoistSlot = struct {
        parent: hir.ExprId,
        /// `Range.len` is `u32`, so an operand index always fits.
        slot: u32,
    };
};

/// Discharge a rule's declared legality obligations. Every arm is a derived
/// query (docs/effects.md §10.1); the tag switch never sees an opcode, so no
/// opcode can decide legality (§10.3).
pub fn check(an: *hir_effects.Analysis, requirements: []const Requirement, subjects: Subjects) Error!bool {
    for (requirements) |req| switch (req) {
        .discardable => {
            if (subjects.expr == hir.no_expr) return false;
            if (!try an.isDiscardable(subjects.expr)) return false;
        },
        .duplicable => {
            if (subjects.expr == hir.no_expr) return false;
            if (!try an.isDuplicable(subjects.expr)) return false;
        },
        .swap_operands => {
            const s = subjects.swap orelse return false;
            if (!try an.canSwapOperands(s.parent, s.lhs_slot, s.rhs_slot)) return false;
        },
        .evaluation_count_preserved => {},
        .materializable => {
            const s = subjects.hoist orelse return false;
            if (!try an.canMaterializeOperand(s.parent, s.slot)) return false;
        },
    };
    return true;
}

/// What a rule consults to decide its pattern matches (docs/effects.md
/// §10.3). `.typed_opcode` is the folding / algebra rule layer's (it reads
/// the typed opcode / rep); `.shape` is a structural match (a `let`, a call
/// to a `fn_ref`-to-λ).
pub const Applicability = enum {
    typed_opcode,
    shape,
};

/// A rule's declared effect-guarantee set (docs/effects.md §10.4), the
/// Σ-form the doc writes as `{ PreservesEvaluationCount | PreservesOrder
/// | … }`.
pub const Effect = struct {
    preserves_evaluation_count: bool = false,
    preserves_order: bool = false,
    may_duplicate: bool = false,
    may_discard: bool = false,
    may_reorder: bool = false,
};

/// The cleanup obligation a `RewriteContract` may declare (§10.4
/// `preserves_cleanup`). The instance form names the subject, which a static
/// rule declaration cannot.
pub const CleanupProof = union(CleanupProofKind) {
    /// The evaluated subtree is literally cleanup-free and passes the
    /// ownership gate — nothing is registered or dropped on either side of
    /// the rewrite (β's instance: the move is identity).
    cleanup_free_subtree: hir.ExprId,
    /// Removing the binding also removes its end-of-scope destructor, which
    /// is admissible only when that destruction is itself discardable (or
    /// the binder is Copy and has no destructor) — dead-let's instance.
    binder_destruction: meta.Type,
};

/// The kind of cleanup proof a contract declares (see `CleanupProof`).
pub const CleanupProofKind = enum {
    cleanup_free_subtree,
    binder_destruction,
};

/// Discharge one cleanup obligation. Derived queries only, no opcode.
pub fn checkCleanupProof(an: *hir_effects.Analysis, proof: CleanupProof) Error!bool {
    return switch (proof) {
        .cleanup_free_subtree => |id| blk: {
            if (!try an.cleanupFree(id)) break :blk false;
            break :blk try an.ownershipGate(id);
        },
        .binder_destruction => |ty| blk: {
            const cap = try an.capabilityOf(ty) orelse .unique;
            break :blk cap == .copy or try an.bindingCleanupDiscardable(ty);
        },
    };
}

/// The boundary-rewrite contract (docs/effects.md §10.4; docs/hir.md §8.4).
/// A rule that is not full-expression-preserving declares each of these
/// before admission.
pub const RewriteContract = struct {
    /// What the rewrite preserves / may do to evaluation.
    effect: Effect = .{},
    /// λ-body binders are remapped onto call-site fresh binders.
    maps_scope: bool = false,
    /// Moved nodes are stamped with the destination full expression.
    maps_full_expr: bool = false,
    /// Which cleanup obligation the rule must discharge, or null when the
    /// rewrite raises no cleanup question.
    preserves_cleanup: ?CleanupProofKind = null,
};

/// A rewrite rule (docs/effects.md §10.3): its identity, the applicability
/// kind its match layer uses, the legality tags its `check` call supplies,
/// and — for a boundary rewrite — its contract.
pub const RewriteRule = struct {
    name: []const u8,
    applicability: Applicability,
    legality: []const Requirement = &.{},
    contract: RewriteContract = .{},
};

/// Discharge the rule's declared cleanup obligation. A subject whose kind
/// disagrees with the declaration is refused, so a declaration that drifted
/// from its call site fails closed instead of silently checking a different
/// proof. A contract with no cleanup obligation passes.
pub fn checkCleanup(rule: RewriteRule, an: *hir_effects.Analysis, subject: CleanupProof) Error!bool {
    const declared = rule.contract.preserves_cleanup orelse return true;
    if (std.meta.activeTag(subject) != declared) return false;
    return checkCleanupProof(an, subject);
}
