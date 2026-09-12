//! HIR data structures — hir.md §3 core (M1a structure + M1b effects).
//!
//! This module owns the *in-memory shape* of the canonical monomorphic HIR
//! the seam between the checker and CFG lowering is built around
//! (docs/hir.md): an arena + dense-handle tree of small `ExprNode`s whose
//! operands and regions are ranges into flat buffers, a registry of op
//! descriptors, and the container the AST→HIR builder appends into.
//!
//! Staging. M1a (S0–S6) landed the whole seam — data structures, the
//! canonical text printer/parser, the structural validator, the AST→HIR
//! builder, and the HIR→CFG lowering (re-exported below); it is the only
//! frontend lowering path. M1b adds the effect infrastructure: the
//! `OpDescriptor` semantics rows (`uses` / `own_effect` / `transfer`),
//! `SemanticInfo.effect` with its interned summaries and the `Program`
//! interner, and the analysis/validation pass in `passes/hir_effects.zig`
//! (model: `effects.zig`). Annotations are additive metadata — they do
//! not change the canonical text or the lowered AIR.
//!
//! M1b notes (hir.md §11, effects.md §14). A fresh node's effect is
//! `pending`, never "proved pure": `Bottom` and `Pure` share a lattice
//! value, so "not yet derived" is carried by the `State` machine. The
//! registry's completeness gates (hir.md §10.1 `validateRegistry`) check
//! identity/shape and the M1b typed-op effect rows at comptime; lowering
//! and printer/parser symmetry are exercised by their own suites.
//!
//! Documented layout choices where the target schema (hir.md §3) leaves a
//! degree of freedom:
//!
//! - **Types are `meta.Type` values, inline** (`ExprNode.ty`, `Binder.ty`).
//!   The thin canonical `HIRTypeId` table of hir.md §3.8 is a *Target*
//!   form (SEG needs O(1) type equality) and is deliberately absent in
//!   M1a — no second type world (meta.Type stays the ground truth that
//!   emits to AIR/LLIR). `meta.TypeId` remains only the nominal-declaration
//!   id inside `meta.Type.named`.
//! - **Op-specific data rides a typed `ExprNode.payload`** (constants,
//!   `local` binder ids, resolved `fn_ref`/`module_const` references,
//!   field indices, variant tags). `ExprNode` stays a generic node — this
//!   is not a recursive `ExprKind` union.
//! - **Arm regions carry an optional `pattern`** (`Region.pattern`):
//!   hir.md §5.4 binds arm patterns to their region, so the pattern arena
//!   entry hangs off the arm's region. Binding *identity* always goes
//!   through the region's `params`; pattern leaves reference those params
//!   by `BinderId` (no implicit positional mapping).
//! - **Attributes are a sentinel** (`attr_empty` = 0, no interner):
//!   hir.md §3.2 allows an empty v1 placeholder.
//! - **Source origins are deferred**: nodes carry `SourceOriginId` (0 =
//!   none); the span side table arrives with the AST builder (S4).

const std = @import("std");
const meta = @import("meta.zig");
/// The effect-semantics model (docs/effects.md §5) — M1b. The HIR owns
/// the *interned* summaries (`Program`); the model itself is pass-free.
pub const effects = @import("effects.zig");

// ---------------------------------------------------------------------------
// Handles — dense ids into their owning arena (hir.md §3.1)
// ---------------------------------------------------------------------------

pub const ExprId = u32;
pub const RegionId = u32;
pub const BinderId = u32;
pub const PatternId = u32;
pub const ScopeId = u32;
pub const FullExprId = u32;
pub const SemanticInfoId = u32;
pub const SourceOriginId = u32;
pub const AttrSetId = u32;
pub const OpId = u32;

/// No attributes (hir.md §3.2: v1 attrs may be an empty placeholder).
pub const attr_empty: AttrSetId = 0;
/// No source span attached.
pub const no_origin: SourceOriginId = 0;

/// A slice of ids into one of the Program's flat buffers (hir.md §3.2):
/// `{ start, len }`, never a node-arena interval. Ranges survive buffer
/// growth because they address positions, not pointers.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,
};

/// Resolved call-target identities (hir.md §3.5, category 3 — module
/// members and host bindings are *not* ops). The numeric space is the
/// module graph's / checker's own; the builder (S4) maps instances in.
pub const FuncId = u32;
pub const HostBindingId = u32;
pub const ConstId = u32;

/// A resolved `fn_ref` target: a monomorphic function or a host binding
/// (both print as `fnref`, hir.md §4.2 — `Fk` vs `Hk` are print-local).
pub const FuncRef = union(enum) {
    func: FuncId,
    host: HostBindingId,
};

// ---------------------------------------------------------------------------
// Ownership view (hir.md §3.6) — SemanticInfo carries this only in M1a
// ---------------------------------------------------------------------------

/// The value/view state of a node's result (runtime-visible).
pub const OwnershipView = enum {
    owned,
    borrowed,
    /// A scheduler-only view of a maybe-unique owner under conditional
    /// destruction (hir.md §3.6).
    destruction_view,
};

/// M1b additive extension of hir.md §3.6: the interned effect summary
/// joins the ownership view. A fresh node is `pending` — effect
/// analysis has not run, so no query may read it as "proved pure"
/// (docs/effects.md §8.2/§10.5). The effects pass (`hir_effects.zig`)
/// resolves every reachable node to `ready`; the validator rejects a
/// reachable node that is still pending.
pub const SemanticInfo = struct {
    ownership_view: OwnershipView = .owned,
    effect: effects.State = .pending,
};

/// Per-operand value use (docs/effects.md §4, hir.md §6.1): the
/// occurrence-level fact for one operand position. `operand_uses` are
/// resolved from the descriptor's `UsePolicy` (never stored as a fourth
/// variant such as "dynamic").
pub const OperandUse = effects.OperandUse;

// ---------------------------------------------------------------------------
// Binder, Region, ExprNode (hir.md §3.3–§3.4)
// ---------------------------------------------------------------------------

/// Source-level parameter / binder contract (Types & Ownership).
pub const BinderMode = enum {
    value, // Copy or fresh Unique binding
    move, // move parameter / consuming pattern binding
    borrow, // borrow parameter / non-consuming match view
};

pub const Binder = struct {
    ty: meta.Type,
    mode: BinderMode = .value,
    // hir.md §3.4 `source` (diagnostic binding ref) arrives with the
    // AST builder.
};

pub const Region = struct {
    /// Params are a range into the binder buffer, in source order. The
    /// region's params are visible through `root` and to nested regions
    /// up to the nearest function/λ boundary (hir.md §5.3).
    params: Range = .{},
    root: ExprId,
    /// Match *arm* regions and destructuring `let` regions only: the
    /// destructuring pattern whose binding leaves reference this
    /// region's params (hir.md §5.4; destructuring lets carry
    /// *irrefutable* patterns only, §5.2 amendment). Null for every
    /// other region kind (plain identifier let continuation, λ body,
    /// if branches).
    pattern: ?PatternId = null,
};

pub const ExprNode = struct {
    op: OpId,
    /// The monomorphic result type — an inline `meta.Type` (see header:
    /// no HIR type interner in M1a, hir.md §3.8).
    ty: meta.Type,
    /// Operands: range into the expr buffer, source order (LTR).
    operands: Range = .{},
    /// Child regions: range into the region buffer.
    regions: Range = .{},
    attrs: AttrSetId = attr_empty,
    /// Ownership view — index into `semantic_infos` (0 = the seeded
    /// default `.owned` entry).
    sema: SemanticInfoId = 0,
    /// Full-expression membership (hir.md §5.6 fence identity); 0 = the
    /// seeded default full expression.
    full_expr: FullExprId = 0,
    origin: SourceOriginId = no_origin,
    payload: Payload = .none,
    /// Resolved access path for a value leaf reached through a dotted
    /// module chain with module-valued members (e.g. `lib.math.sqrt`):
    /// the ordered *intermediate* module-valued members, each as its
    /// owning module index (into the graph's module list) and member
    /// name. The first hop's module is the module the base `module_ref`
    /// names; the final member stays in the payload (fn_ref /
    /// module_const / const). Only value-position leaves under a ≥1-hop
    /// dotted module path carry hops; everything else stays empty
    /// (hir.md §7.4). Lowering replays the chain as a `module_ref` plus
    /// per-hop `load_member`s exactly like the direct
    /// `cfg_lower_path.lowerPathValue` (module identity flows through
    /// the loaded values).
    access_hops: []const AccessHop = &.{},
};

/// One hop of a resolved module access path (see `ExprNode.access_hops`).
pub const AccessHop = struct {
    /// The hop member's owning module (index into the built module list).
    module: u32,
    /// The module-valued member name within that module.
    name: []const u8,
};

/// Op-specific data for ops whose identity is not carried by operands
/// alone (hir.md §4.4). Exactly one variant is meaningful per opcode;
/// the structural validator (S3) checks the pairing.
pub const Payload = union(enum) {
    none,
    /// `const` — typed literal (reuses `meta.ConstValue`, so no second
    /// literal representation; strings are arena-owned).
    const_value: meta.ConstValue,
    /// `local` — the referenced binder.
    binder: BinderId,
    /// `fn_ref` — resolved function / host-binding target.
    func: FuncRef,
    /// `module_const` — resolved module-level constant.
    module_const: ConstId,
    /// `field_get` — struct field index.
    field: u32,
    /// `variant_make` — union variant tag.
    tag: u32,
};

// ---------------------------------------------------------------------------
// Lexical scopes and full expressions (hir.md §5.3, §5.6)
// ---------------------------------------------------------------------------

/// A lexical destruction scope: local owner bindings are destroyed when
/// their scope ends. *Distinct from binder visibility* — regions define
/// visibility; scopes define destruction points (hir.md §5.3). Binding →
/// scope association and the containing-function identity arrive with the
/// builder/lowering layout (S4/S5); no cleanup is planned here.
pub const Scope = struct {
    parent: ?ScopeId = null,
};

/// A full-expression boundary (hir.md §5.6): temporary destruction runs
/// at the FE end, reverse creation order. S1 records identity only — every
/// node carries `full_expr`, and S4 assigns boundaries at construction.
/// Entry/exit and cleanup-registration metadata land with the lowering
/// layout; this is never an executable destruction plan.
pub const FullExpr = struct {};

// ---------------------------------------------------------------------------
// Patterns (hir.md §4.3, §5.4) — shape lives here, bindings in region params
// ---------------------------------------------------------------------------

/// One destructuring pattern. Binding leaves (`bind`, `type_test.bind`)
/// name a param of the owning arm region; the shape is recorded here.
/// Child patterns are referenced by `PatternId` (arena entries of their
/// own) — same dense-id philosophy as exprs/regions, and it keeps the
/// union free of value recursion.
pub const Pattern = union(enum) {
    wildcard,
    /// Binding leaf: references one of the arm region's `params`
    /// (hir.md §5.4 — binding identity always goes through params).
    bind: BinderId,
    literal: meta.ConstValue,
    tuple: []PatternId,
    list: ListPattern,
    struct_: StructPattern,
    variant: VariantPattern,
    /// Core type-test `ty Binder`.
    type_test: TypeTestPattern,

    pub const ListPattern = struct {
        elems: []PatternId,
        rest: ?PatternId = null,
    };

    pub const StructPattern = struct {
        /// One field: decl member index (names stay in the side table)
        /// plus its sub-pattern.
        fields: []FieldPattern,
    };

    pub const FieldPattern = struct {
        field: u32,
        pat: PatternId,
    };

    pub const VariantPattern = struct {
        tag: u32,
        payload: ?PatternId = null,
    };

    pub const TypeTestPattern = struct {
        ty: meta.Type,
        bind: BinderId,
    };
};

// ---------------------------------------------------------------------------
// Op registry (hir.md §3.5, §7.1) — one identity table: identity/shape
// plus the M1b semantics facets (`uses` / `own_effect` / `transfer`).
// ---------------------------------------------------------------------------

/// The scalar rep of a typed (rep-parameterized) opcode (hir.md §7.2):
/// written as the opcode suffix (`add.i32`), same short names as LLIR.
pub const ScalarRep = enum {
    byte,
    i32,
    i64,
    u32,
    u64,
    f32,
    f64,
    bool,
    str,

    pub fn toCfgType(self: ScalarRep) meta.Type {
        return .{ .primitive = switch (self) {
            .byte => .byte,
            .i32 => .int32,
            .i64 => .int64,
            .u32 => .uint32,
            .u64 => .uint64,
            .f32 => .float32,
            .f64 => .float64,
            .bool => .bool,
            .str => .str,
        } };
    }
};

/// The v1 core opcode categories (hir.md §7.1, 类别 column).
pub const OpClass = enum {
    atom,
    binding,
    seq,
    function,
    control,
    aggregate,
    ownership,
    dynamic,
    conversion,
    runtime,
    /// Typed (rep-parameterized) instances such as `add.i32`. hir.md §7.1
    /// lists no numeric category (its table carries the semantic core
    /// only); the full arithmetic family lands with the builder (S4), so
    /// this category is provisional until then.
    numeric,
};

/// Operand shape per op (hir.md §4.4 / §5.5): how many eager operands the
/// node carries.
pub const OperandShape = enum {
    none,
    one,
    two,
    /// `call`: first operand is the callee, the rest are arguments.
    callee_and_args,
    list,
};

/// Region shape per op.
pub const RegionShape = enum {
    none,
    one,
    two,
    /// `match`: one arm region per arm.
    arms,
};

/// Evaluation policy (hir.md §5.5) — *language semantics*, carried on the
/// descriptor, never derived from effects. Operands of an eager op are
/// evaluated exactly once, left to right; lazy branches evaluate at most
/// the selected region.
pub const EvalPolicy = enum {
    strict_ltr,
    short_circuit,
    branch, // `if`: cond first, at most one region
    match, // `match`: scrutinee first, at most one arm region
    /// Region policy is op-self-declared (hir.md §5.5): `let`'s region is
    /// a *continuation* (always runs, after the init), `lambda`'s region
    /// is a *deferred body* (runs only when the value is called). The
    /// two are not both "eager" — the builder and validator distinguish
    /// them by op.
    region,
};

/// How an op's operand-use facts are obtained (docs/effects.md §4).
/// `static_list` reads `OpDescriptor.operand_uses`; the other policies
/// are resolved per occurrence by the effect analysis from the callee
/// signature, the operand's capability/view, or the op's contract.
pub const UsePolicy = enum {
    /// No operands.
    none,
    /// Every operand is `Read`.
    all_read,
    /// Every operand is consumed (assignment-style ownership transfer).
    all_consume,
    /// `call`: the callee operand is `Read`; each argument's use comes
    /// from the callee parameter mode (borrow → Borrow, move → Consume,
    /// value → Consume for a Unique value else Read).
    callee_params,
    /// `let`/aggregates/match scrutinee: `Consume` for a Unique operand
    /// (ownership transfer into the binding/aggregate), `Borrow` for a
    /// borrowed view, `Read` otherwise.
    operand_capability,
    /// The explicit slice in `OpDescriptor.operand_uses`.
    static_list,
};

/// How a descriptor's own effect combines with its operands and regions
/// to produce the node's `EffectSummary` (docs/hir.md §6.1). The
/// dispatch lives in `hir_effects.transfer`; this tag is descriptor
/// data so a new op states its composition explicitly.
pub const TransferKind = enum {
    /// `own_effect` only (no operands/regions).
    atom,
    /// `own_effect ;` each operand's effect, left to right.
    strict_ltr,
    /// `own_effect ; effects(init) ; effects(region root)`.
    let_,
    /// `own_effect ; effects(cond) ; (then ⊔ else)` (if/and/or).
    branch,
    /// `own_effect ; effects(scrutinee) ; ⨆ effects(arm bodies)`.
    match,
    /// `own_effect ; effects(callee) ; seq(args) ; effect_bound(callee)`.
    call,
    /// λ value creation: `own_effect` only (no capture, no body run).
    /// The body summary becomes the callable's `effect_bound`.
    lambda,
    /// Explicit destruction: `drop_effect(operand type) ; effects(operand)`.
    drop_effect,
    /// `Read(ModuleConst(payload const))`.
    module_const,
    /// `field_get`: `own_effect` (base-type dependent — a list index may
    /// trap) `;` the base's effect.
    field_get,
};

/// SEG term-encoding kind (hir.md §3.5 `seg`, §8.2): the registry facet
/// saying an op takes part in the v1 SEG projection and which term shape
/// it encodes to. `null` is a hard island boundary — `encode` returns
/// `None` (hir.md §8.2). The kind is the small "SEG type contract"
/// `validateRegistry` cross-checks against the op's class: a typed
/// (rep-parameterized) row encodes as `.numeric`; `.atom`/`.slot`
/// require an atom; `.binder` a binding/function op; `.app` the call;
/// `.branch` a control op; `.construct`/`.project` aggregates.
pub const SegEncoding = enum {
    /// Compile-time literal (const).
    atom,
    /// Binder reference — projects to a SLOT (local).
    slot,
    /// Binding term (let continuation region / lambda).
    binder,
    /// Application (call).
    app,
    /// Conditional term (if / and / or).
    branch,
    /// Aggregate construction (struct_make).
    construct,
    /// Field projection (field_get).
    project,
    /// Typed (rep-parameterized) numeric instance (`add.i32`, …).
    numeric,
};

/// One registry entry. Facets beyond identity/shape — `verify` (S3),
/// `print`/parser symmetry (S2), `lower_to_air` (S5), constant folding —
/// attach to this row as their passes land; no no-op callbacks or
/// fabricated fields are added to fake completeness.
pub const OpDescriptor = struct {
    /// SEG encoding, when this op is in the v1 island set (hir.md §8.1,
    /// §11 M2a). Default `null` = the operation forms an island boundary.
    seg: ?SegEncoding = null,
    name: []const u8,
    class: OpClass,
    operands: OperandShape,
    regions: RegionShape,
    policy: EvalPolicy,
    /// True for typed (rep-parameterized) instances: the name carries a
    /// `.rep` suffix and the row is a registry entry of its own.
    typed: bool = false,
    rep: ?ScalarRep = null,

    // --- M1b semantics (docs/effects.md §4, hir.md §3.5/§6.2) ---
    // These three are required (no defaults): a new opcode must state
    // its operand-use policy, its own effect, and its composition rule.
    // A silently defaulted `pure` is exactly the drift the registry
    // exists to prevent.

    /// Operand-use resolution policy.
    uses: UsePolicy,
    /// Static operand uses when `uses == .static_list`.
    operand_uses: []const OperandUse = &.{},
    /// The op's own interaction with state outside the expression
    /// (docs/hir.md §6.2). Typed numeric rows refine the coarse CFG
    /// `may_trap` bit (effects.md §15); the two are explicitly layered,
    /// not required to be bit-identical (CFG deliberately over-
    /// approximates float division).
    own_effect: effects.Summary,
    /// How `own_effect` combines with operands/regions.
    transfer: TransferKind,
};

/// The v1 core opcodes (hir.md §7.1). Rows carry the structural metadata
/// the §7.1 table fixes: category, operand/region shape (from §4.4 text
/// forms), and §5.5 evaluation policy.
const core_descriptors = [_]OpDescriptor{
    .{ .name = "const", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr, .uses = .none, .own_effect = effects.pure, .transfer = .atom, .seg = .atom },
    .{ .name = "local", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr, .uses = .none, .own_effect = effects.pure, .transfer = .atom, .seg = .slot },
    .{ .name = "fn_ref", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr, .uses = .none, .own_effect = effects.pure, .transfer = .atom },
    .{ .name = "module_const", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr, .uses = .none, .own_effect = effects.pure, .transfer = .module_const },
    .{ .name = "let", .class = .binding, .operands = .one, .regions = .one, .policy = .region, .uses = .operand_capability, .own_effect = effects.pure, .transfer = .let_, .seg = .binder },
    .{ .name = "seq", .class = .seq, .operands = .list, .regions = .none, .policy = .strict_ltr, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "lambda", .class = .function, .operands = .none, .regions = .one, .policy = .region, .uses = .none, .own_effect = effects.pure, .transfer = .lambda, .seg = .binder },
    .{ .name = "call", .class = .function, .operands = .callee_and_args, .regions = .none, .policy = .strict_ltr, .uses = .callee_params, .own_effect = effects.pure, .transfer = .call, .seg = .app },
    .{ .name = "if", .class = .control, .operands = .one, .regions = .two, .policy = .branch, .uses = .all_read, .own_effect = effects.pure, .transfer = .branch, .seg = .branch },
    .{ .name = "and", .class = .control, .operands = .one, .regions = .two, .policy = .short_circuit, .uses = .all_read, .own_effect = effects.pure, .transfer = .branch, .seg = .branch },
    .{ .name = "or", .class = .control, .operands = .one, .regions = .two, .policy = .short_circuit, .uses = .all_read, .own_effect = effects.pure, .transfer = .branch, .seg = .branch },
    .{ .name = "match", .class = .control, .operands = .one, .regions = .arms, .policy = .match, .uses = .operand_capability, .own_effect = effects.pure, .transfer = .match },
    .{ .name = "struct_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr, .uses = .operand_capability, .own_effect = effects.pure, .transfer = .strict_ltr, .seg = .construct },
    .{ .name = "field_get", .class = .aggregate, .operands = .one, .regions = .none, .policy = .strict_ltr, .uses = .all_read, .own_effect = effects.pure, .transfer = .field_get, .seg = .project },
    .{ .name = "variant_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr, .uses = .operand_capability, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "tuple_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr, .uses = .operand_capability, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "list_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr, .uses = .operand_capability, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "move", .class = .ownership, .operands = .one, .regions = .none, .policy = .strict_ltr, .uses = .static_list, .own_effect = effects.pure, .transfer = .strict_ltr, .operand_uses = &[_]OperandUse{.consume} },
    .{ .name = "borrow", .class = .ownership, .operands = .one, .regions = .none, .policy = .strict_ltr, .uses = .static_list, .own_effect = effects.pure, .transfer = .strict_ltr, .operand_uses = &[_]OperandUse{.borrow} },
    .{ .name = "drop", .class = .ownership, .operands = .one, .regions = .none, .policy = .strict_ltr, .uses = .static_list, .own_effect = effects.pure, .transfer = .drop_effect, .operand_uses = &[_]OperandUse{.consume} },
    .{ .name = "any_pack", .class = .dynamic, .operands = .one, .regions = .none, .policy = .strict_ltr, .uses = .operand_capability, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "any_cast", .class = .dynamic, .operands = .one, .regions = .none, .policy = .strict_ltr, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "num_cast", .class = .conversion, .operands = .one, .regions = .none, .policy = .strict_ltr, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "panic", .class = .runtime, .operands = .none, .regions = .none, .policy = .strict_ltr, .uses = .none, .own_effect = effects.may_trap, .transfer = .atom },
};

/// Typed instances registered to make the rep-parameterized mechanism
/// concrete — the sample rows of hir.md §7.2. The full arithmetic family
/// (and every other typed opcode) registers here as the builder (S4)
/// needs it; adding a row is a data edit.
const typed_descriptors = [_]OpDescriptor{
    .{ .name = "add.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "add.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "add.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "add.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "div.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "div.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "mul.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "add.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "add.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "sub.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "sub.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "sub.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "sub.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "sub.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "sub.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "mul.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "mul.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "mul.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "mul.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "mul.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "div.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "div.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "div.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "div.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "rem.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "rem.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "rem.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "rem.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.may_trap, .transfer = .strict_ltr },
    .{ .name = "rem.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "rem.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "min.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "min.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "min.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "min.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "max.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "max.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "max.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "max.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shl.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shl.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shl.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shl.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shr.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shr.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shr.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "shr.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "band.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "band.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "band.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "band.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bor.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bor.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bor.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bor.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bxor.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bxor.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bxor.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "bxor.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    // `byte` has no arithmetic (checker-rejected); its only numeric ops
    // are the comparisons, which lower through the u32 family at the
    // typed stage (the byte value occupies one host cell).
    .{ .name = "lt.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "le.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "gt.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ge.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.bool", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .bool, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "eq.str", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .str, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.bool", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .bool, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ne.str", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .str, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "lt.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "lt.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "lt.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "lt.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "lt.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "lt.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "le.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "le.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "le.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "le.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "le.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "le.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "gt.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "gt.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "gt.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "gt.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "gt.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "gt.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ge.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ge.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ge.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ge.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ge.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "ge.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "neg.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "neg.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "neg.i64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "neg.u64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "neg.f32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "neg.f64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "abs.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "abs.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "abs.f32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "abs.f64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "clz.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "clz.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "popcount.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "popcount.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "concat.str", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .str, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
    .{ .name = "not.bool", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .bool, .uses = .all_read, .own_effect = effects.pure, .transfer = .strict_ltr },
};

/// Every typed (numeric) row is a SEG island member (hir.md §11 M2a:
/// "+ numeric ops"); stamp the encoding here instead of repeating it on
/// each of the ~110 rows.
const typed_seg_descriptors = blk: {
    var rows = typed_descriptors;
    for (&rows) |*r| r.seg = .numeric;
    break :blk rows;
};

/// The single identity table (hir.md §3.5): core and typed entries share
/// one OpId space.
pub const op_descriptors: []const OpDescriptor = &(core_descriptors ++ typed_seg_descriptors);

pub const OpRegistry = struct {
    entries: []const OpDescriptor,

    pub fn id(self: OpRegistry, name: []const u8) ?OpId {
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn get(self: OpRegistry, op_id: OpId) OpDescriptor {
        std.debug.assert(op_id < self.entries.len);
        return self.entries[op_id];
    }

    /// Identity/shape + M1b effect-row consistency of the table — the
    /// part of hir.md §10.1 `validateRegistry` that is comptime-checkable
    /// here (lowering presence and printer/parser symmetry are exercised
    /// by their own suites instead of a table field).
    pub fn validate(self: OpRegistry) void {
        for (self.entries, 0..) |e, i| {
            // Unique names: identity is the row, not a name prefix.
            for (self.entries[0..i]) |prev| {
                std.debug.assert(!std.mem.eql(u8, prev.name, e.name));
            }
            // Typed rows carry one `.rep` suffix; core rows carry none.
            const has_dot = std.mem.indexOfScalar(u8, e.name, '.') != null;
            std.debug.assert(has_dot == e.typed);
            if (e.typed) {
                std.debug.assert(e.rep != null);
                const rep_name = @tagName(e.rep.?);
                std.debug.assert(std.mem.endsWith(u8, e.name, rep_name));
            } else {
                std.debug.assert(e.rep == null);
            }

            // M1b effect-row completeness (hir.md §3.5/§10.1).
            // Registry rows carry no static resource access: every
            // resource read/write is dynamic (module_const, drop,
            // host metadata) and lives on the analysis. A row that
            // needs accesses would have to say so explicitly.
            std.debug.assert(e.own_effect.accesses.isEmpty());
            // A `static_list` row must supply exactly its eager-operand
            // uses (shape is free of operands that are not uses only
            // for `call`, which is never static).
            if (e.uses == .static_list) {
                const want: usize = switch (e.operands) {
                    .none => 0,
                    .one => 1,
                    .two => 2,
                    .list, .callee_and_args => e.operand_uses.len,
                };
                std.debug.assert(e.operand_uses.len == want);
            } else {
                std.debug.assert(e.operand_uses.len == 0);
            }
            // Typed-opcode base effect rows (hir.md §6.2, effects.md
            // §6.3): integer div/rem may trap (divisor zero, and for
            // i64 also `min / -1`); float div/rem are IEEE and never
            // trap; every other typed op is total. This refines — and
            // is deliberately *not* asserted equal to — the coarse CFG
            // `may_trap` bit (effects.md §15: CFG over-approximates
            // float division).
            if (e.typed) {
                const traps = (std.mem.startsWith(u8, e.name, "div.") or
                    std.mem.startsWith(u8, e.name, "rem.")) and
                    e.rep.? != .f32 and e.rep.? != .f64;
                std.debug.assert(e.own_effect.may_trap == traps);
            }
            // Core rows are total or explicitly trapping (panic,
            // any_cast); no core row diverges or is nondeterministic by
            // declaration.
            std.debug.assert(!e.own_effect.may_diverge);
            std.debug.assert(!e.own_effect.nondeterministic);

            // SEG encoding contract (hir.md §3.5/§8.2, §11 M2a): typed
            // rows encode as `.numeric` and only they do; every other
            // encoding kind pairs with the op class it belongs to. A row
            // outside the v1 island set carries no encoding at all.
            if (e.typed) {
                std.debug.assert(e.seg == .numeric);
            } else if (e.seg) |enc| {
                std.debug.assert(switch (enc) {
                    .atom, .slot => e.class == .atom,
                    .binder => e.class == .binding or e.class == .function,
                    .app => e.class == .function,
                    .branch => e.class == .control,
                    .construct, .project => e.class == .aggregate,
                    .numeric => false, // typed-only, handled above
                });
            }
        }
    }
};

pub const registry: OpRegistry = .{ .entries = op_descriptors };

comptime {
    // The identity/shape checks unroll over the entry table; raise the
    // comptime branch quota accordingly.
    @setEvalBranchQuota(100_000);
    registry.validate();
}

/// Look up an op id by name (registry identity).
pub fn opId(name: []const u8) ?OpId {
    return registry.id(name);
}

// ---------------------------------------------------------------------------
// Serialization context (hir.md §4.8 refs dictionary, §4.5 nominal types)
// ---------------------------------------------------------------------------
//
// The canonical text form needs name/decl side tables that the IR itself
// deliberately does not carry (names stay out of IR structures, §1.3).
// These tables live here, keyed by the *checker's* numeric id spaces
// (FuncId / ConstId / HostBindingId / cfg TypeId): the arrays are
// index-by-id lookups. S2 tests build fixture contexts; S4/S5 wire the
// real module tables in (same shape).

pub const SerCtx = struct {
    /// Nominal type declarations, indexed by `meta.Type.Named.id`. The
    /// printer renders `.named` decl ids through this table (written
    /// name + type arguments); the parser resolves nominal type names
    /// and derives pattern-binder types through it.
    types: []const meta.TypeDecl = &.{},
    /// Function targets, indexed by FuncId: stable semantic key (hir.md
    /// §4.8) and the function's monomorphic type (for `call` result
    /// types through a `fnref` callee).
    funcs: []const FuncDecl = &.{},
    /// Module-level constants, indexed by ConstId.
    consts: []const ConstDecl = &.{},
    /// Host bindings, indexed by HostBindingId.
    hosts: []const HostDecl = &.{},

    pub const FuncDecl = struct { key: []const u8, type_: meta.Type };
    pub const ConstDecl = struct { key: []const u8, type_: meta.Type };
    pub const HostDecl = struct { key: []const u8, type_: meta.Type };
};

// ---------------------------------------------------------------------------
// Program — the low-level container (hir.md §3.2)
// ---------------------------------------------------------------------------
//
// One arena-backed container: each entity has its own dense arena, and
// ordered lists (node operands, node regions, region params) live in
// flat id buffers addressed by `Range`. Module tables, function lifting,
// and the type environment stay in the builder/lowering layers (S4/S5);
// this is the append surface they grow on.

pub const Program = struct {
    arena: std.mem.Allocator,

    // Entity arenas (identity = index).
    exprs: std.ArrayListUnmanaged(ExprNode) = .empty,
    regions: std.ArrayListUnmanaged(Region) = .empty,
    binders: std.ArrayListUnmanaged(Binder) = .empty,
    patterns: std.ArrayListUnmanaged(Pattern) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    full_exprs: std.ArrayListUnmanaged(FullExpr) = .empty,
    semantic_infos: std.ArrayListUnmanaged(SemanticInfo) = .empty,

    // Flat id buffers (addressed by Range, hir.md §3.2).
    expr_buffer: std.ArrayListUnmanaged(ExprId) = .empty,
    region_buffer: std.ArrayListUnmanaged(RegionId) = .empty,
    binder_buffer: std.ArrayListUnmanaged(BinderId) = .empty,

    /// Interned effect summaries (docs/effects.md §5, hir.md §3.6):
    /// `SemanticInfo.effect` ids index this table.
    effect_interner: effects.Interner,
    /// Dedupe map for `(ownership_view, effect state)` pairs so nodes
    /// with equal annotations share one SemanticInfoId.
    sema_map: std.HashMapUnmanaged(SemaKey, SemanticInfoId, SemaKeyCtx, std.hash_map.default_max_load_percentage) = .empty,

    pub const SemaKey = struct {
        view: OwnershipView,
        state: effects.State,
    };

    const SemaKeyCtx = struct {
        pub fn hash(_: SemaKeyCtx, k: SemaKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&k.view));
            switch (k.state) {
                .pending => h.update(&[_]u8{0}),
                .ready => |id| {
                    h.update(&[_]u8{1});
                    h.update(std.mem.asBytes(&id));
                },
            }
            return h.final();
        }
        pub fn eql(_: SemaKeyCtx, a: SemaKey, b: SemaKey) bool {
            if (a.view != b.view) return false;
            return switch (a.state) {
                .pending => b.state == .pending,
                .ready => |id| switch (b.state) {
                    .ready => |bid| id == bid,
                    .pending => false,
                },
            };
        }
    };

    /// Seed the default entries so id 0 is always valid: the default
    /// (owned, pending) semantic info and the default full expression.
    /// Nodes built without explicit annotation therefore belong to FE 0
    /// with view `.owned` and a *pending* effect — never a claim of
    /// purity, which only the effects pass may make.
    pub fn init(arena: std.mem.Allocator) !Program {
        var p = Program{ .arena = arena, .effect_interner = try effects.Interner.init(arena) };
        const default_sema: SemanticInfoId = @intCast(p.semantic_infos.items.len);
        try p.semantic_infos.append(arena, .{});
        try p.full_exprs.append(arena, .{});
        // The seeded default is the canonical `(owned, pending)` entry.
        try p.sema_map.put(arena, .{ .view = .owned, .state = .pending }, default_sema);
        return p;
    }

    // No deinit: everything is arena-owned.

    /// Append helpers — each returns a fresh dense id or a Range into the
    /// corresponding flat buffer. Ids survive any later growth; borrowed
    /// pointers/slices into the buffers do not (re-derive via the
    /// accessors below after each append burst).
    pub fn addExpr(self: *Program, expr: ExprNode) !ExprId {
        try self.exprs.append(self.arena, expr);
        return @intCast(self.exprs.items.len - 1);
    }

    pub fn addRegion(self: *Program, binder_ids: []const BinderId, root: ExprId, arm_pattern: ?PatternId) !RegionId {
        const start: u32 = @intCast(self.binder_buffer.items.len);
        try self.binder_buffer.appendSlice(self.arena, binder_ids);
        try self.regions.append(self.arena, .{
            .params = .{ .start = start, .len = @intCast(binder_ids.len) },
            .root = root,
            .pattern = arm_pattern,
        });
        return @intCast(self.regions.items.len - 1);
    }

    pub fn addBinder(self: *Program, ty: meta.Type, mode: BinderMode) !BinderId {
        try self.binders.append(self.arena, .{ .ty = ty, .mode = mode });
        return @intCast(self.binders.items.len - 1);
    }

    pub fn addPattern(self: *Program, pat: Pattern) !PatternId {
        try self.patterns.append(self.arena, pat);
        return @intCast(self.patterns.items.len - 1);
    }

    pub fn addScope(self: *Program, parent: ?ScopeId) !ScopeId {
        try self.scopes.append(self.arena, .{ .parent = parent });
        return @intCast(self.scopes.items.len - 1);
    }

    /// Append a full-expression boundary (id 0 is the seeded default).
    pub fn addFullExpr(self: *Program) !FullExprId {
        try self.full_exprs.append(self.arena, .{});
        return @intCast(self.full_exprs.items.len - 1);
    }

    /// Append a semantic info (id 0 is the seeded default `.owned`).
    pub fn addSemanticInfo(self: *Program, info: SemanticInfo) !SemanticInfoId {
        try self.semantic_infos.append(self.arena, info);
        return @intCast(self.semantic_infos.items.len - 1);
    }

    /// Intern `(view, effect state)` so annotation sharing is stable.
    pub fn internSema(self: *Program, view: OwnershipView, state: effects.State) !SemanticInfoId {
        const key = SemaKey{ .view = view, .state = state };
        const gop = try self.sema_map.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try self.addSemanticInfo(.{ .ownership_view = view, .effect = state });
        }
        return gop.value_ptr.*;
    }

    /// Append operands (in evaluation order) to the expr buffer.
    pub fn addOperands(self: *Program, ids: []const ExprId) !Range {
        const start: u32 = @intCast(self.expr_buffer.items.len);
        try self.expr_buffer.appendSlice(self.arena, ids);
        return .{ .start = start, .len = @intCast(ids.len) };
    }

    /// Append child-region ids to the region buffer (the slice an
    /// `ExprNode.regions` range addresses — see `addRegion`).
    pub fn addRegions(self: *Program, ids: []const RegionId) !Range {
        const start: u32 = @intCast(self.region_buffer.items.len);
        try self.region_buffer.appendSlice(self.arena, ids);
        return .{ .start = start, .len = @intCast(ids.len) };
    }

    /// Accessors — always re-derived from the live buffers.
    pub fn node(self: *const Program, id: ExprId) ExprNode {
        return self.exprs.items[id];
    }

    /// Set the resolved module access path on an already-added leaf
    /// (fn_ref / module_const / const reached through module-valued
    /// member chains).
    pub fn setAccessHops(self: *Program, id: ExprId, hops: []const AccessHop) void {
        self.exprs.items[id].access_hops = hops;
    }

    pub fn region(self: *const Program, id: RegionId) Region {
        return self.regions.items[id];
    }

    pub fn binder(self: *const Program, id: BinderId) Binder {
        return self.binders.items[id];
    }

    pub fn pattern(self: *const Program, id: PatternId) Pattern {
        return self.patterns.items[id];
    }

    /// The operand slice of one expr node (a range into the expr buffer).
    pub fn operands(self: *const Program, id: ExprId) []ExprId {
        const n = self.exprs.items[id];
        return self.expr_buffer.items[n.operands.start..][0..n.operands.len];
    }

    /// The region slice of one expr node (a range into the region buffer).
    pub fn regionsOf(self: *const Program, id: ExprId) []RegionId {
        const n = self.exprs.items[id];
        return self.region_buffer.items[n.regions.start..][0..n.regions.len];
    }

    /// The params of one region (a range into the binder buffer).
    pub fn params(self: *const Program, rid: RegionId) []BinderId {
        const r = self.regions.items[rid];
        return self.binder_buffer.items[r.params.start..][0..r.params.len];
    }

    /// The ownership view of one expr node (0 = default `.owned`).
    pub fn viewOf(self: *const Program, id: ExprId) OwnershipView {
        const n = self.exprs.items[id];
        return self.semantic_infos.items[n.sema].ownership_view;
    }

    /// The effect state of one expr node (default = pending).
    pub fn effectOf(self: *const Program, id: ExprId) effects.State {
        const n = self.exprs.items[id];
        return self.semantic_infos.items[n.sema].effect;
    }

    /// Resolve a node's effect state to a summary id, or null while the
    /// analysis has not published one (a legality query must fail closed
    /// on null — docs/effects.md §10.5).
    pub fn effectIdOf(self: *const Program, id: ExprId) ?effects.SummaryId {
        return self.effectOf(id).readyId();
    }

    /// Record a node's effect state, preserving its ownership view. The
    /// effects pass uses this to publish `ready` summaries; nothing else
    /// should widen or narrow an annotation.
    pub fn setEffect(self: *Program, id: ExprId, state: effects.State) !void {
        const view = self.viewOf(id);
        self.exprs.items[id].sema = try self.internSema(view, state);
    }
};

// ---------------------------------------------------------------------------
// Built-program container (hir.md §3.2 container role for a whole compile)
// ---------------------------------------------------------------------------
//
// The AST→HIR builder (S4, `passes/hir_build.zig`) consumes the module
// graph + checker annotation and produces one `BuiltProgram`: a single
// node store (`Program`, shared by every module of the compile) plus
// program-level record tables for the function inventory, module
// constants, and host bindings, ordered exactly like the current CFG
// lowering's per-module function list (`cfg_lower_module.lowerModule`:
// init?, non-generic function members, used instances, drop hooks, then
// hoisted lambdas in creation order, then intrinsic wrappers). Function
// bodies live as `lambda`-shaped region trees: `FuncRecord.root` is a
// `lambda` node whose region carries the function's params and whose
// root is the body — the same shape the canonical text form prints as
// `fn (B0..) => …`, so every binder reference in a body resolves
// through its own region (no capture is structural).
//
// Numeric ids (FuncId / ConstId / HostBindingId) are *this table's*
// dense indices — the "module graph's / checker's own" spaces of
// hir.md §3.5, assigned by the builder so a forward or recursive
// reference resolves before the referencing body is built. Reference
// ids are independent of cfg emission order; the emission-order
// contract lives in the record order itself.

/// What kind of function a `FuncRecord` is (drives cfg emission later;
/// also documented naming conventions, see hir_build.zig).
/// init: the module init (`{spec}.init` record; cfg emits it per
/// module even when empty, except host modules and `builtin`).
pub const FuncKind = enum {
    init,
    member, // {spec}.{fn}
    instance, // {spec}.{fn}.{id}
    drop_hook, // {spec}.{Type}.drop
    lambda, // {spec}.{fn}[.lambda{outer}].lambda{N} (chain of the enclosing name)
    intrinsic, // {using-spec}.{member}.intrinsic.{N}
};

/// One built function: its qualified cfg-style name, kind, owning
/// module (index into `BuiltProgram.modules`), signature, body root,
/// and source span of the declaration.
pub const FuncRecord = struct {
    name: []const u8,
    kind: FuncKind,
    module: u32,
    /// Function type: params (name/mode/type) + return type. Types are
    /// resolved `meta.Type`s; names are the written param names (used by
    /// the builder for lookup only).
    params: []meta.Param,
    ret: meta.Type,
    /// The body: a `lambda` node whose region params are the function's
    /// params (id 0.. are dense in this program).
    root: ExprId,
    /// The source span of the declaration (function name / λ / drop
    /// decl); kept as raw `u32` offsets rather than `meta.Span` — keep span
    /// light.
    span_start: u32 = 0,
    span_end: u32 = 0,
    /// Emission position within the owning module: the index in the
    /// cfg-order function list (init, members, instances, hooks, then
    /// hoisted lambdas in completion order, then intrinsic wrappers).
    /// The `funcs` table itself is append-ordered (predeclared records
    /// first, hoisted records as discovered), so S5 re-orders a
    /// module's records by this field to match the direct lowering.
    order: u32 = 0,
};

/// One module constant member: identity (name, owning module), resolved
/// type, whether it carries an initializer (host bindings / module
/// values have none or are static), and the module it resolves to when
/// module-valued (`import` / alias of one).
pub const ConstRecord = struct {
    name: []const u8,
    module: u32,
    type_: meta.Type,
    /// Index of this module's const in `BuiltProgram.consts` (dense).
    key: []const u8, // stable key for the text refs dictionary
    /// Non-null when the const has a Stilla initializer expression
    /// (its HIR root lives in the shared node store). Null for
    /// bodyless consts and module-valued consts.
    init: ?ExprId,
    /// Resolved specifier when module-valued (import or alias).
    module_spec: ?[]const u8 = null,
    /// Whether this const occupies a module storage slot (mirrors
    /// `cfg_lower_module.constSlot`: not intrinsic, not module-valued,
    /// not void).
    slot: ?u32 = null,
};

/// One module's built form: its specifier and the ranges of its
/// functions/constants in the program-wide tables.
pub const BuiltModule = struct {
    specifier: []const u8,
    /// Range into `BuiltProgram.funcs` (the records this module owns,
    /// in cfg emission order — init first when present).
    funcs: Range = .{},
    /// Range into `BuiltProgram.consts`.
    consts: Range = .{},
    /// Index of the module-init record in `funcs`, when one exists.
    init_func: ?FuncId = null,
};

/// The builder's output for one whole compile: one shared node store
/// plus the record tables and the per-module inventory.
pub const BuiltProgram = struct {
    arena: std.mem.Allocator,
    program: Program,
    modules: std.ArrayListUnmanaged(BuiltModule) = .empty,
    funcs: std.ArrayListUnmanaged(FuncRecord) = .empty,
    consts: std.ArrayListUnmanaged(ConstRecord) = .empty,
    hosts: std.ArrayListUnmanaged(HostRecord) = .empty,
    /// meta.TypeDecl layout table indexed by meta.TypeId — the real
    /// nominal-type side table (same shape the SerCtx printer/parser
    /// consume; meta.TypeId is the ground truth for `.named` types).
    types: []meta.TypeDecl = &.{},

    /// Convenience: the serialization context over this built program's
    /// real tables. Call only after the build is complete (no further
    /// `funcs` appends): entries reference arena-allocated copies of
    /// each record's return type, and `consts`/`hosts`/`types` come from
    /// the frozen tables.
    pub fn serCtx(self: *const BuiltProgram) !SerCtx {
        const rets = try self.arena.alloc(meta.Type, self.funcs.items.len);
        for (self.funcs.items, 0..) |f, i| rets[i] = f.ret;
        var funcs = std.ArrayList(SerCtx.FuncDecl).empty;
        for (self.funcs.items, 0..) |f, i| {
            try funcs.append(self.arena, .{ .key = f.name, .type_ = .{ .function = .{ .params = f.params, .ret = &rets[i] } } });
        }
        var consts = std.ArrayList(SerCtx.ConstDecl).empty;
        for (self.consts.items) |c| {
            try consts.append(self.arena, .{ .key = c.key, .type_ = c.type_ });
        }
        var hosts = std.ArrayList(SerCtx.HostDecl).empty;
        for (self.hosts.items) |h| {
            try hosts.append(self.arena, .{ .key = h.key, .type_ = h.signature });
        }
        return .{
            .types = self.types,
            .funcs = funcs.items,
            .consts = consts.items,
            .hosts = hosts.items,
        };
    }
};

/// One host binding (bodyless declaration outside the embedded bundle):
/// the (module, member) pair that names the syscall target and the
/// declared signature. Indexed by HostBindingId.
pub const HostRecord = struct {
    module: u32,
    name: []const u8,
    signature: meta.Type,
    key: []const u8,
};

// ---------------------------------------------------------------------------
// Text form: canonical printer and parser — implemented in src/passes/
// (hir_parse.zig, hir_print.zig); re-exported here so `hir.print` and
// `hir.parseText` keep working for tests and dumps (hir.md §4).
// ---------------------------------------------------------------------------
pub const ParseError = @import("passes/hir_parse.zig").ParseError;
pub const Diag = @import("passes/hir_parse.zig").Diag;
pub const Parser = @import("passes/hir_parse.zig").Parser;
pub const parseText = @import("passes/hir_parse.zig").parseText;
// pi-lens-ignore: zls:unknown
pub const print = @import("passes/hir_print.zig").print;
// pi-lens-ignore: zls:unknown
pub const validate = @import("passes/hir_validate.zig").validate;

// ---------------------------------------------------------------------------
// White-box tests (hir.md §10.2: owning module `test {}`)
// ---------------------------------------------------------------------------
//
// S1 covers the structural layer only: fresh ids, flat-range ordering and
// stability across growth, concrete payloads, let init-vs-body structure,
// pattern→arm-param association, ownership views, and registry
// identity/shape. Whole-tree rejections (capture, DAGs, scope violations)
// are the structural validator's job in S3, not S1's.

const t = std.testing;

fn program() !Program {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    return Program.init(arena.allocator());
}

const ty_int = meta.Type{ .primitive = .int32 };
const ty_bool = meta.Type{ .primitive = .bool };

test "handles are fresh and flat ranges stay ordered across growth" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = try Program.init(arena.allocator());

    // Two operand ranges, interleaved with enough appends to force
    // ArrayList reallocation several times over.
    const a0 = try p.addExpr(.{ .op = opId("const").?, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } });
    const a1 = try p.addExpr(.{ .op = opId("const").?, .ty = ty_int, .payload = .{ .const_value = .{ .int = 2 } } });
    const r_a = try p.addOperands(&.{ a0, a1 });
    try t.expectEqual(@as(usize, 2), r_a.len);

    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const c = try p.addExpr(.{ .op = opId("const").?, .ty = ty_int, .payload = .{ .const_value = .{ .int = 0 } } });
        _ = try p.addOperands(&.{c});
    }

    const b0 = try p.addExpr(.{ .op = opId("const").?, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = true } } });
    const r_b = try p.addOperands(&.{b0});
    try t.expectEqual(@as(usize, 1), r_b.len);

    // Ids are dense and sequential within the expr arena.
    try t.expectEqual(@as(usize, 2 + 60 + 1), p.exprs.items.len);
    // Ranges still address the right ids after growth, in order, and
    // never overlap.
    const buf = p.expr_buffer.items;
    try t.expectEqual(a0, buf[r_a.start]);
    try t.expectEqual(a1, buf[r_a.start + 1]);
    try t.expectEqual(b0, buf[r_b.start]);
    try t.expect(r_a.start + r_a.len <= r_b.start);
    // The accessor re-derives the same slice after growth, through a
    // node whose `operands` range addresses r_a.
    const seq_id = try p.addExpr(.{ .op = opId("seq").?, .ty = ty_int, .operands = r_a });
    const ops_a = p.operands(seq_id);
    try t.expectEqual(@as(usize, 2), ops_a.len);
    try t.expectEqual(a0, ops_a[0]);
    try t.expectEqual(a1, ops_a[1]);
}

test "let keeps its init outside the binder region" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = try Program.init(arena.allocator());

    // `let x = <init> in x` (hir.md §5.2): init is an eager operand of
    // the let node; the region carries x as its only param and the body
    // as root.
    const b_x = try p.addBinder(ty_int, .value);
    const init = try p.addExpr(.{ .op = opId("const").?, .ty = ty_int, .payload = .{ .const_value = .{ .int = 42 } } });
    const body = try p.addExpr(.{ .op = opId("local").?, .ty = ty_int, .payload = .{ .binder = b_x } });
    const r_let = try p.addRegion(&.{b_x}, body, null);
    const region_range = try p.addRegions(&.{r_let});
    const operands = try p.addOperands(&.{init});
    const let_id = try p.addExpr(.{
        .op = opId("let").?,
        .ty = ty_int,
        .operands = operands,
        .regions = region_range,
    });

    // Shape: one init operand, one region whose param is x.
    const ops = p.operands(let_id);
    try t.expectEqual(@as(usize, 1), ops.len);
    try t.expectEqual(init, ops[0]);
    const regs = p.regionsOf(let_id);
    try t.expectEqual(@as(usize, 1), regs.len);
    const params = p.params(regs[0]);
    try t.expectEqual(@as(usize, 1), params.len);
    try t.expectEqual(b_x, params[0]);
    try t.expectEqual(body, p.region(regs[0]).root);
    try t.expectEqual(BinderMode.value, p.binder(b_x).mode);
    // Structural mirror of the init-exclusion rule (hir.md §5.3): the
    // init's operand list never references x — here it is a literal, and
    // the binder's only in-region use is the body root.
    const init_ops = p.operands(init);
    try t.expectEqual(@as(usize, 0), init_ops.len);
    try t.expectEqual(.owned, p.viewOf(let_id));
}

test "payloads: literal, local binder, resolved fn_ref and module_const" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = try Program.init(arena.allocator());

    const lit = try p.addExpr(.{ .op = opId("const").?, .ty = ty_int, .payload = .{ .const_value = .{ .int = -7 } } });
    try t.expectEqual(@as(i64, -7), p.node(lit).payload.const_value.int);

    const b0 = try p.addBinder(ty_int, .value);
    const local = try p.addExpr(.{ .op = opId("local").?, .ty = ty_int, .payload = .{ .binder = b0 } });
    try t.expectEqual(b0, p.node(local).payload.binder);

    const f = try p.addExpr(.{ .op = opId("fn_ref").?, .ty = ty_int, .payload = .{ .func = .{ .func = 7 } } });
    try t.expectEqual(@as(FuncId, 7), p.node(f).payload.func.func);

    const h = try p.addExpr(.{ .op = opId("fn_ref").?, .ty = ty_int, .payload = .{ .func = .{ .host = 3 } } });
    try t.expectEqual(@as(HostBindingId, 3), p.node(h).payload.func.host);

    const mc = try p.addExpr(.{ .op = opId("module_const").?, .ty = ty_int, .payload = .{ .module_const = 9 } });
    try t.expectEqual(@as(ConstId, 9), p.node(mc).payload.module_const);
}

test "pattern binding leaves reference their arm region's params" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = try Program.init(arena.allocator());

    // Arm `Option::Some(v) => …` (hir.md §5.4): v is the arm region's
    // param; the pattern records the variant tag and a payload leaf that
    // names that param.
    const b_v = try p.addBinder(ty_int, .value);
    const payload = try p.addPattern(.{ .bind = b_v });
    const some = try p.addPattern(.{ .variant = .{ .tag = 0, .payload = payload } });
    const body = try p.addExpr(.{ .op = opId("local").?, .ty = ty_int, .payload = .{ .binder = b_v } });
    const arm = try p.addRegion(&.{b_v}, body, some);

    const params = p.params(arm);
    try t.expectEqual(@as(usize, 1), params.len);
    try t.expectEqual(b_v, params[0]);
    const pat = p.pattern(p.region(arm).pattern.?);
    try t.expectEqual(@as(u32, 0), pat.variant.tag);
    try t.expectEqual(b_v, p.pattern(pat.variant.payload.?).bind);
}

test "semantic infos default to owned; each view is recorded" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = try Program.init(arena.allocator());

    // Id 0 is the seeded default owned entry.
    const b = try p.addBinder(ty_int, .value);
    const borrowed = try p.addSemanticInfo(.{ .ownership_view = .borrowed });
    const destruction = try p.addSemanticInfo(.{ .ownership_view = .destruction_view });

    const plain = try p.addExpr(.{ .op = opId("local").?, .ty = ty_int, .payload = .{ .binder = b } });
    try t.expectEqual(.owned, p.viewOf(plain));

    const br = try p.addExpr(.{ .op = opId("local").?, .ty = ty_int, .payload = .{ .binder = b }, .sema = borrowed });
    try t.expectEqual(.borrowed, p.viewOf(br));

    const dv = try p.addExpr(.{ .op = opId("local").?, .ty = ty_int, .payload = .{ .binder = b }, .sema = destruction });
    try t.expectEqual(.destruction_view, p.viewOf(dv));

    try t.expect(borrowed != destruction and plain != br);
    // Full-expression ids work the same way: 0 is the seeded default.
    const fe = try p.addFullExpr();
    try t.expectEqual(@as(usize, 2), p.full_exprs.items.len);
    const in_fe = try p.addExpr(.{ .op = opId("local").?, .ty = ty_int, .payload = .{ .binder = b }, .full_expr = fe });
    try t.expectEqual(fe, p.node(in_fe).full_expr);
    try t.expectEqual(@as(FullExprId, 0), p.node(plain).full_expr);

    // Scope records are present as arena entries with a parent chain.
    const s0 = try p.addScope(null);
    const s1 = try p.addScope(s0);
    try t.expectEqual(s0, p.scopes.items[s1].parent);
}

test "registry: every v1 core opcode is registered once, with shape" {
    // The §7.1 inventory, in order of the spec table's categories.
    const core = [_][]const u8{
        "const",        "local",      "fn_ref",    "module_const", "let",         "seq",
        "lambda",       "call",       "if",        "match",        "struct_make", "field_get",
        "variant_make", "tuple_make", "list_make", "move",         "borrow",      "drop",
        "any_pack",     "any_cast",   "num_cast",  "panic",
    };
    var seen: [22]OpId = undefined;
    for (core, 0..) |name, i| {
        const id = registry.id(name) orelse return error.TestUnexpectedResult;
        seen[i] = id;
    }
    // Distinct ids.
    for (seen, 0..) |a, i| {
        for (seen[0..i]) |b| try t.expect(a != b);
    }
    // Unknown name is not an op.
    try t.expect(registry.id("no_such_op") == null);

    // Shape spot-checks (structural metadata only).
    const let_op = registry.get(seen[4]);
    try t.expectEqual(OpClass.binding, let_op.class);
    try t.expectEqual(OperandShape.one, let_op.operands);
    try t.expectEqual(RegionShape.one, let_op.regions);

    const if_op = registry.get(seen[8]);
    try t.expectEqual(EvalPolicy.branch, if_op.policy);
    try t.expectEqual(RegionShape.two, if_op.regions);

    const lambda_op = registry.get(seen[6]);
    try t.expectEqual(EvalPolicy.region, lambda_op.policy);
    try t.expectEqual(RegionShape.one, lambda_op.regions);

    const call_op = registry.get(seen[7]);
    try t.expectEqual(OperandShape.callee_and_args, call_op.operands);
    try t.expectEqual(RegionShape.none, call_op.regions);

    const match_op = registry.get(seen[9]);
    try t.expectEqual(EvalPolicy.match, match_op.policy);
    try t.expectEqual(RegionShape.arms, match_op.regions);

    const move_op = registry.get(seen[15]);
    try t.expectEqual(OpClass.ownership, move_op.class);
    try t.expectEqual(OperandShape.one, move_op.operands);
}

test "registry: typed instances carry their scalar rep" {
    // The §7.2 sample rows: one registry entry per `opcode.rep`, typed.
    for ([_][]const u8{ "add.i32", "add.u32", "add.i64", "add.u64", "div.i32", "div.u64", "add.f32", "add.f64" }) |name| {
        const id = registry.id(name) orelse return error.TestUnexpectedResult;
        const op = registry.get(id);
        try t.expect(op.typed);
        try t.expect(op.rep != null);
    }
    // Distinct from core space and from each other.
    try t.expect(registry.id("add.i32").? != registry.id("add.u32").?);
    // The rep maps to the meta.Type the node will carry.
    try t.expectEqual(meta.Type{ .primitive = .uint64 }, ScalarRep.u64.toCfgType());
}

test "registry: the M2a SEG island set carries `seg`, nothing else does" {
    // hir.md §11 M2a: `const / local / let / lambda / call / if /
    // struct_make / field_get` + numeric ops.
    const encoded = [_]struct { []const u8, SegEncoding }{
        .{ "const", .atom },
        .{ "local", .slot },
        .{ "let", .binder },
        .{ "lambda", .binder },
        .{ "call", .app },
        .{ "if", .branch },
        .{ "struct_make", .construct },
        .{ "field_get", .project },
        .{ "add.i32", .numeric },
        .{ "div.i64", .numeric },
        .{ "eq.str", .numeric },
    };
    for (encoded) |pair| {
        const op = registry.get(registry.id(pair[0]) orelse return error.TestUnexpectedResult);
        try t.expect(op.seg != null);
        try t.expectEqual(pair[1], op.seg.?);
    }
    // Hard island boundaries (hir.md §8.2 `encode` → None).
    for ([_][]const u8{ "fn_ref", "module_const", "seq", "match", "tuple_make", "list_make", "variant_make", "move", "borrow", "drop", "any_pack", "num_cast", "panic" }) |name| {
        const op = registry.get(registry.id(name) orelse return error.TestUnexpectedResult);
        try t.expect(op.seg == null);
    }
}

test "text passes are analyzed (forces hir_print/hir_parse analysis in test builds)" {
    const parse_text = @import("passes/hir_parse.zig").parseText;
    const print_text = @import("passes/hir_print.zig").print;
    const validate_text = @import("passes/hir_validate.zig").validate;
    var p = try parse_text("fn (B0: i32) => mul.i32(%B0, 2i32)", .{});
    defer p.arena.deinit();
    const out = try print_text(&p.program, p.root, p.arena.allocator(), .{});
    try std.testing.expectEqualStrings("fn (B0: i32) => mul.i32(%B0, 2i32)", out);
    // The parsed tree is structurally valid; hir_validate's own tests
    // below only run because this reference forces the file's analysis.
    try std.testing.expect((try validate_text(&p.program, p.root, p.arena.allocator())) == null);
}
