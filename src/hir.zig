//! HIR data structures — hir.md §3 core (structural-HIR skeleton, M1a).
//!
//! This module owns the *in-memory shape* of the canonical monomorphic HIR
//! the seam between the checker and CFG lowering is built around
//! (docs/hir.md): an arena + dense-handle tree of small `ExprNode`s whose
//! operands and regions are ranges into flat buffers, a registry of op
//! descriptors, and the container that S4's AST→HIR builder appends into.
//!
//! Staging (PROGRESS.md). This is **S1 — data structures only**. No HIR
//! compiler stage is wired: the printer/parser (S2), the structural
//! validator (S3), the AST→HIR builder (S4), and the HIR→CFG lowering
//! (S5) live in later phases and are re-exported here when they land
//! (mirroring `cfg` re-exporting `cfg_parse`/`cfg_print`). Until then the
//! checker's output still feeds the CFG lowering directly.
//!
//! M1a fences (hir.md §11). Effect analysis is disabled: `SemanticInfo`
//! carries the ownership view only — there is deliberately no effect
//! field and no `Top` interner, and no SEG field appears anywhere. The
//! registry's completeness gates (hir.md §10.1 `validateRegistry`:
//! lowering presence, printer/parser symmetry, effect rows) become
//! non-vacuous as the S2/S3/S5 facets land; this skeleton asserts
//! identity/shape only and documents that it is not yet registry-complete
//! for a milestone that hir.md measures by the §10.3 equivalence gate.
//!
//! Documented layout choices where the target schema (hir.md §3) leaves a
//! degree of freedom:
//!
//! - **Types are `cfg.Type` values, inline** (`ExprNode.ty`, `Binder.ty`).
//!   The thin canonical `HIRTypeId` table of hir.md §3.8 is a *Target*
//!   form (SEG needs O(1) type equality) and is deliberately absent in
//!   M1a — no second type world (cfg.Type stays the ground truth that
//!   emits to AIR/LLIR). `cfg.TypeId` remains only the nominal-declaration
//!   id inside `cfg.Type.named`.
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
const cfg = @import("cfg.zig");

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

/// hir.md §3.6 `effect` is deliberately absent in M1a: effect analysis
/// is disabled (§11). M1b extends this struct additively.
pub const SemanticInfo = struct {
    ownership_view: OwnershipView = .owned,
};

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
    ty: cfg.Type,
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
    /// The monomorphic result type — an inline `cfg.Type` (see header:
    /// no HIR type interner in M1a, hir.md §3.8).
    ty: cfg.Type,
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
};

/// Op-specific data for ops whose identity is not carried by operands
/// alone (hir.md §4.4). Exactly one variant is meaningful per opcode;
/// the structural validator (S3) checks the pairing.
pub const Payload = union(enum) {
    none,
    /// `const` — typed literal (reuses `cfg.ConstValue`, so no second
    /// literal representation; strings are arena-owned).
    const_value: cfg.ConstValue,
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
    literal: cfg.ConstValue,
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
        ty: cfg.Type,
        bind: BinderId,
    };
};

// ---------------------------------------------------------------------------
// Op registry (hir.md §3.5, §7.1) — one identity table, no effect/SEG facets
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

    pub fn toCfgType(self: ScalarRep) cfg.Type {
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

/// One registry entry. Facets beyond identity/shape — `verify` (S3),
/// `print`/parser symmetry (S2), `lower_to_air` (S5), constant folding —
/// attach to this row as their passes land; no no-op callbacks or
/// fabricated fields are added to fake completeness.
pub const OpDescriptor = struct {
    name: []const u8,
    class: OpClass,
    operands: OperandShape,
    regions: RegionShape,
    policy: EvalPolicy,
    /// True for typed (rep-parameterized) instances: the name carries a
    /// `.rep` suffix and the row is a registry entry of its own.
    typed: bool = false,
    rep: ?ScalarRep = null,
};

/// The v1 core opcodes (hir.md §7.1). Rows carry the structural metadata
/// the §7.1 table fixes: category, operand/region shape (from §4.4 text
/// forms), and §5.5 evaluation policy.
const core_descriptors = [_]OpDescriptor{
    .{ .name = "const", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr },
    .{ .name = "local", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr },
    .{ .name = "fn_ref", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr },
    .{ .name = "module_const", .class = .atom, .operands = .none, .regions = .none, .policy = .strict_ltr },
    .{ .name = "let", .class = .binding, .operands = .one, .regions = .one, .policy = .region },
    .{ .name = "seq", .class = .seq, .operands = .list, .regions = .none, .policy = .strict_ltr },
    .{ .name = "lambda", .class = .function, .operands = .none, .regions = .one, .policy = .region },
    .{ .name = "call", .class = .function, .operands = .callee_and_args, .regions = .none, .policy = .strict_ltr },
    .{ .name = "if", .class = .control, .operands = .one, .regions = .two, .policy = .branch },
    .{ .name = "and", .class = .control, .operands = .one, .regions = .two, .policy = .short_circuit },
    .{ .name = "or", .class = .control, .operands = .one, .regions = .two, .policy = .short_circuit },
    .{ .name = "match", .class = .control, .operands = .one, .regions = .arms, .policy = .match },
    .{ .name = "struct_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr },
    .{ .name = "field_get", .class = .aggregate, .operands = .one, .regions = .none, .policy = .strict_ltr },
    .{ .name = "variant_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr },
    .{ .name = "tuple_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr },
    .{ .name = "list_make", .class = .aggregate, .operands = .list, .regions = .none, .policy = .strict_ltr },
    .{ .name = "move", .class = .ownership, .operands = .one, .regions = .none, .policy = .strict_ltr },
    .{ .name = "borrow", .class = .ownership, .operands = .one, .regions = .none, .policy = .strict_ltr },
    .{ .name = "drop", .class = .ownership, .operands = .one, .regions = .none, .policy = .strict_ltr },
    .{ .name = "any_pack", .class = .dynamic, .operands = .one, .regions = .none, .policy = .strict_ltr },
    .{ .name = "any_cast", .class = .dynamic, .operands = .one, .regions = .none, .policy = .strict_ltr },
    .{ .name = "num_cast", .class = .conversion, .operands = .one, .regions = .none, .policy = .strict_ltr },
    .{ .name = "panic", .class = .runtime, .operands = .none, .regions = .none, .policy = .strict_ltr },
};

/// Typed instances registered to make the rep-parameterized mechanism
/// concrete — the sample rows of hir.md §7.2. The full arithmetic family
/// (and every other typed opcode) registers here as the builder (S4)
/// needs it; adding a row is a data edit.
const typed_descriptors = [_]OpDescriptor{
    .{ .name = "add.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "add.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "add.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "add.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "div.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "div.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "mul.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "add.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "add.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "sub.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "sub.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "sub.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "sub.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "sub.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "sub.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "mul.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "mul.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "mul.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "mul.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "mul.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "div.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "div.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "div.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "div.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "rem.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "rem.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "rem.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "rem.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "rem.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "rem.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "min.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "min.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "min.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "min.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "max.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "max.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "max.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "max.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "shl.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "shl.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "shl.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "shl.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "shr.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "shr.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "shr.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "shr.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "band.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "band.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "band.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "band.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "bor.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "bor.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "bor.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "bor.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "bxor.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "bxor.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "bxor.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "bxor.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "eq.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte },
    .{ .name = "ne.byte", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .byte },
    .{ .name = "eq.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "eq.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "eq.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "eq.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "eq.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "eq.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "eq.bool", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .bool },
    .{ .name = "eq.str", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .str },
    .{ .name = "ne.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "ne.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "ne.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "ne.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "ne.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "ne.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "ne.bool", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .bool },
    .{ .name = "ne.str", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .str },
    .{ .name = "lt.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "lt.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "lt.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "lt.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "lt.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "lt.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "le.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "le.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "le.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "le.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "le.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "le.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "gt.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "gt.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "gt.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "gt.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "gt.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "gt.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "ge.i32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "ge.u32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "ge.i64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "ge.u64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "ge.f32", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "ge.f64", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "neg.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "neg.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "neg.i64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i64 },
    .{ .name = "neg.u64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u64 },
    .{ .name = "neg.f32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "neg.f64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "abs.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "abs.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "abs.f32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f32 },
    .{ .name = "abs.f64", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .f64 },
    .{ .name = "clz.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "clz.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "popcount.i32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .i32 },
    .{ .name = "popcount.u32", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .u32 },
    .{ .name = "concat.str", .class = .numeric, .operands = .two, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .str },
    .{ .name = "not.bool", .class = .numeric, .operands = .one, .regions = .none, .policy = .strict_ltr, .typed = true, .rep = .bool },
};

/// The single identity table (hir.md §3.5): core and typed entries share
/// one OpId space.
pub const op_descriptors: []const OpDescriptor = &(core_descriptors ++ typed_descriptors);

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

    /// Identity/shape consistency of the table — the part of hir.md
    /// §10.1 `validateRegistry` that is non-vacuous from this skeleton
    /// onward. Completeness facets (lowering presence, printer/parser
    /// symmetry, effect rows) attach when their passes land (S2/S3/S5).
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
    /// Nominal type declarations, indexed by `cfg.Type.Named.id`. The
    /// printer renders `.named` decl ids through this table (written
    /// name + type arguments); the parser resolves nominal type names
    /// and derives pattern-binder types through it.
    types: []const cfg.TypeDecl = &.{},
    /// Function targets, indexed by FuncId: stable semantic key (hir.md
    /// §4.8) and the function's monomorphic type (for `call` result
    /// types through a `fnref` callee).
    funcs: []const FuncDecl = &.{},
    /// Module-level constants, indexed by ConstId.
    consts: []const ConstDecl = &.{},
    /// Host bindings, indexed by HostBindingId.
    hosts: []const HostDecl = &.{},

    pub const FuncDecl = struct { key: []const u8, type_: cfg.Type };
    pub const ConstDecl = struct { key: []const u8, type_: cfg.Type };
    pub const HostDecl = struct { key: []const u8, type_: cfg.Type };
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

    /// Seed the default entries so id 0 is always valid: the default
    /// (owned) semantic info and the default full expression. Nodes
    /// built without explicit annotation therefore belong to FE 0 with
    /// view `.owned`.
    pub fn init(arena: std.mem.Allocator) !Program {
        var p = Program{ .arena = arena };
        try p.semantic_infos.append(arena, .{});
        try p.full_exprs.append(arena, .{});
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

    pub fn addBinder(self: *Program, ty: cfg.Type, mode: BinderMode) !BinderId {
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
    /// resolved `cfg.Type`s; names are the written param names (used by
    /// the builder for lookup only).
    params: []cfg.Param,
    ret: cfg.Type,
    /// The body: a `lambda` node whose region params are the function's
    /// params (id 0.. are dense in this program).
    root: ExprId,
    /// The source span of the declaration (function name / λ / drop
    /// decl); `ast.Span` is imported via cfg.ast — keep span light.
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
    type_: cfg.Type,
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
    /// cfg.TypeDecl layout table indexed by cfg.TypeId — the real
    /// nominal-type side table (same shape the SerCtx printer/parser
    /// consume; cfg.TypeId is the ground truth for `.named` types).
    types: []cfg.TypeDecl = &.{},

    /// Convenience: the serialization context over this built program's
    /// real tables. Call only after the build is complete (no further
    /// `funcs` appends): entries reference arena-allocated copies of
    /// each record's return type, and `consts`/`hosts`/`types` come from
    /// the frozen tables.
    pub fn serCtx(self: *const BuiltProgram) !SerCtx {
        const rets = try self.arena.alloc(cfg.Type, self.funcs.items.len);
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
    signature: cfg.Type,
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

const ty_int = cfg.Type{ .primitive = .int32 };
const ty_bool = cfg.Type{ .primitive = .bool };

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
    // The rep maps to the cfg.Type the node will carry.
    try t.expectEqual(cfg.Type{ .primitive = .uint64 }, ScalarRep.u64.toCfgType());
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
