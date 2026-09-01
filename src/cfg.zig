//! AIR data structures — air.md §11 (frontend Phase 3/4).
//!
//! `cfg` owns the in-memory control-flow-graph structures of air.md §11 —
//! `IrProgram`, `IrModule`, `IrFunc`, `BasicBlock`, `Instr`, `Value`,
//! `Terminator` — the AIR-native resolved `Type`, and the ownership/state
//! tags values carry. The two *algorithms* that act on these structures
//! live in `src/passes/` and are re-exported here so the public surface
//! (`cfg.Parser`, `cfg.print`) is unchanged:
//!
//! - `src/passes/cfg_parse.zig` — the `Parser` that turns the textual
//!   form of air.md §9 into these structures;
//! - `src/passes/cfg_print.zig` — the canonical `print` back to text for
//!   AIR dumps, tests, and golden files (round-trip contract, air.md §13).
//!
//! Scope. The text form is *self-contained*: no dependency on the type
//! checker or the module graph. Where air.md §11 names frontend artifacts,
//! this file substitutes AIR-native equivalents so the parser stays
//! testable in isolation:
//!
//! - the checker's resolved-type annotation → `Type` (AIR-native resolved
//!   type, §4.2);
//! - `checker.FuncInstance`, `ast.FuncDef` → omitted from `IrFunc` (the
//!   frontend lowering populates them when it builds the CFG from AST);
//! - `ModuleInfo` → module / member **names** (`module_ref`, syscall
//!   targets);
//! - `Call.callee.direct` → `DirectCallee { name, func }` — a direct
//!   reference may name a function defined later in the text, resolved by
//!   `resolveDirectCalls` after the whole program is parsed.
//!
//! Text format (air.md §9). The format is line-oriented: one label,
//! instruction, or terminator per line; `;` starts a line comment.
//!
//! ```text
//! module "app" {
//!     func @add(a: int32, b: int32) -> int32 {
//!     entry:
//!         %r: int32 = add %a, %b
//!         ret %r
//!     }
//! }
//! ```
//!
//! - values are `%name` or `%N` (`%0..%k-1` are the parameters, in
//!   definition order);
//! - instructions are `%name: type = op operands`;
//! - pure effects are `drop %v` and `store_member #slot, %v`;
//! - terminators are `ret`, `j`, `br` (`br %c ? a : b`), `switch`,
//!   and `trap`;
//! - constant literals may appear inline where a value operand is expected
//!   (they are materialized as `const` instructions in memory);
//! - `#N` is a statically known index or union tag;
//! - syscall targets are `builtin#member` or `module#member`.

const std = @import("std");
const ast = @import("ast.zig");

/// Ownership classification of a value type (Core §10.1–§10.3).
/// `Copy` values may be implicitly copied; `unique` values may be
/// used at most once and must be destroyed exactly once.
pub const Ownership = enum {
    copy,
    unique,
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// An AIR-native resolved type (air.md §4.2, §11). The AIR text carries no
/// type declarations, so `named` types defer ownership to their
/// declaration, mirroring the checker's `null`-means-deferred convention.
pub const TypeId = u32;

pub const Type = union(enum) {
    primitive: ast.PrimitiveKind,
    /// A named struct or union reference: the declaration's `TypeId` plus
    /// the type arguments of this instantiation (empty for non-generic
    /// types). Canonical identity is the declaration `TypeId` together with
    /// the arguments (`Named`); the declaration name strings are for
    /// printing and diagnostics only.
    named: Named,
    /// A generic type parameter of an enclosing declaration, e.g. the
    /// `T` of `fn foo[T](x: T) -> T` (Core §12). `null` ownership
    /// (deferred) until a monomorphic substitution fixes it. Distinct
    /// from `named` so a type parameter is never confused with a
    /// nominal struct/union reference.
    param: []const u8,
    /// The static module type of `module_ref` values (Core §2.3).
    module,
    list: *Type,
    box: *Type,
    tuple: []Type,
    function: FunctionType,
    /// The type of a cleanup token (air.md §6.4): a compiler-only value
    /// that schedules the conditional destruction of a maybe-unique
    /// owner. Not a Core type — no source expression, parameter, or
    /// binding ever has this type; only `cleanup_arm` produces it and
    /// only `cleanup_disarm` / `cleanup_drop` consume it. Classified
    /// Copy so ordinary scope-end machinery never drops it.
    cleanup,

    /// A named struct or union reference with its type arguments: the
    /// declaration `TypeId` and the instantiation's arguments, in the
    /// declaration's parameter order.
    pub const Named = struct {
        id: TypeId,
        args: []Type,
    };

    /// Structural ownership (air.md §6.1): primitives are Copy except
    /// the top type `any` and the opaque payload type `hostdata`, which are
    /// unique (Core §11.6, §11.7); function values and module values are
    /// Copy; containers join their components; cleanup tokens are
    /// scheduler-only values; named types defer (`null`).
    pub fn ownership(self: Type) ?Ownership {
        return switch (self) {
            .primitive => |k| if (k == .any or k == .hostdata) Ownership.unique else Ownership.copy,
            .module, .cleanup => Ownership.copy,
            .named, .param => null,
            .list, .box => |inner| inner.ownership(),
            .tuple => |elems| blk: {
                var acc: ?Ownership = Ownership.copy;
                for (elems) |e| {
                    const ow = e.ownership() orelse break :blk null;
                    if (ow == .unique) acc = Ownership.unique;
                }
                break :blk acc;
            },
            .function => Ownership.copy,
        };
    }

    /// Whether two named references denote the same instantiation: the
    /// same declaration with structurally equal type arguments.
    fn namedEql(a: Named, b: Named) bool {
        if (a.id != b.id) return false;
        if (a.args.len != b.args.len) return false;
        for (a.args, b.args) |x, y| {
            if (!eql(x, y)) return false;
        }
        return true;
    }

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .primitive => |ka| switch (b) {
                .primitive => |kb| ka == kb,
                else => false,
            },
            .module => b == .module,
            .named => |na| switch (b) {
                .named => |nb| namedEql(na, nb),
                else => false,
            },
            .param => |pa| switch (b) {
                .param => |pb| std.mem.eql(u8, pa, pb),
                else => false,
            },
            .list => |la| switch (b) {
                .list => |lb| eql(la.*, lb.*),
                else => false,
            },
            .box => |la| switch (b) {
                .box => |lb| eql(la.*, lb.*),
                else => false,
            },
            .tuple => |ta| switch (b) {
                .tuple => |tb| tupleEql(ta, tb),
                else => false,
            },
            .function => |fa| switch (b) {
                .function => |fb| funcEql(fa, fb),
                else => false,
            },
            .cleanup => b == .cleanup,
        };
    }

    fn tupleEql(a: []Type, b: []Type) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!eql(x, y)) return false;
        return true;
    }

    fn funcEql(a: FunctionType, b: FunctionType) bool {
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |x, y| {
            if (x.mode != y.mode or !eql(x.type_, y.type_)) return false;
        }
        return eql(a.ret.*, b.ret.*);
    }
};

/// One parameter: `[borrow|move] name: type` (air.md §11). In function
/// *types* the name is empty.
pub const Param = struct {
    span: ast.Span,
    name: ast.Ident,
    mode: ast.ParamMode,
    type_: Type,
};

/// A synthetic parameter for a syscall signature the frontend itself
/// constructs (the list `len` in list patterns, `unbox` in drop
/// lowering): no written name.
pub fn syntheticParam(span: ast.Span, mode: ast.ParamMode, type_: Type) Param {
    return .{ .span = span, .name = .{ .span = span, .text = "" }, .mode = mode, .type_ = type_ };
}

pub const FunctionType = struct {
    params: []Param,
    ret: *Type,
};

// ---------------------------------------------------------------------------
// Type environment (air.md §9.1)
// ---------------------------------------------------------------------------

/// One nominal type declaration behind a `TypeId` (air.md §9.1): the
/// concrete layout, declared ownership, and destruction information a
/// backend needs to interpret `construct` / `unpack_*` / `drop` over a
/// named type — without reference to the source module graph. The
/// frontend lowering fills these from the module graph; the AIR text
/// parser interns only `.unknown` names (the text form carries no type
/// declarations, air.md §10), so a text-parsed program's layout queries
/// return null.
pub const TypeDecl = union(enum) {
    struct_: StructDecl,
    union_: UnionDecl,
    opaque_: OpaqueDecl,
    /// A name interned by the AIR text parser (air.md §10): the text form
    /// carries no type declarations, so the layout is unknown. The
    /// frontend never emits this form.
    unknown: []const u8,

    /// The written declaration name (printing and diagnostics only;
    /// canonical identity is the `TypeId`, air.md §9.1).
    pub fn name(self: TypeDecl) []const u8 {
        return switch (self) {
            .struct_ => |d| d.name,
            .union_ => |d| d.name,
            .opaque_ => |d| d.name,
            .unknown => |n| n,
        };
    }
};

/// A struct declaration (air.md §9.1 `StructDecl`): fields in declaration
/// order, the declared ownership, and the hidden drop-hook function.
pub const StructDecl = struct {
    /// Written declaration name (printing/diagnostics only).
    name: []const u8,
    /// The declaring module's resolved specifier.
    module: []const u8,
    /// Declaration type-parameter names, in declaration order (empty for
    /// non-generic structs). Field types reference them as `Type.param`;
    /// an instantiation's concrete layout substitutes the arguments.
    type_params: []const []const u8,
    /// The declared ownership class, concrete for non-generic structs.
    /// Null when the struct is generic: the class of an instantiation
    /// depends on its type arguments (`Option[int32]` is Copy,
    /// `Option[File]` is unique) — resolve via `IrProgram.namedOwnership`.
    ownership: ?Ownership,
    /// The hidden drop-hook function name (`{module}.{Type}.drop`, air.md
    /// §6.4), when the struct declares a hook (Core §9.1); null otherwise.
    /// A struct with a hook is unique by declaration.
    drop: ?[]const u8,
    /// Fields in declaration order.
    fields: []FieldDecl,
};

/// One struct field: the written name and the resolved field type (a
/// generic declaration's field types may reference its type parameters
/// as `Type.param`).
pub const FieldDecl = struct {
    name: []const u8,
    type_: Type,
};

/// A union declaration (air.md §9.1 `UnionDecl`): variants in declaration
/// order, the declared ownership, and the discriminant layout.
pub const UnionDecl = struct {
    name: []const u8,
    /// The declaring module's resolved specifier.
    module: []const u8,
    /// Declaration type-parameter names, in declaration order (see
    /// `StructDecl.type_params`; null ownership when generic).
    type_params: []const []const u8,
    ownership: ?Ownership,
    /// Variants in declaration order; the discriminant of a variant is
    /// its position.
    variants: []VariantDecl,
};

/// One union variant: the written name and its payload types in
/// declaration order (empty for a payload-less variant).
pub const VariantDecl = struct {
    name: []const u8,
    payloads: []Type,
};

/// A host-backed opaque nominal type declaration (air.md §9.1
/// `OpaqueDecl`, Core §11.8): no fields, no variants, unique by
/// declaration; the host type implementation is named by `host_id`.
pub const OpaqueDecl = struct {
    name: []const u8,
    /// The declaring module's resolved specifier.
    module: []const u8,
    /// Unique by declaration (Core §11.8): opaque types never take type
    /// arguments that change their ownership.
    ownership: Ownership,
    /// The host type implementation behind the opaque type (Runtime
    /// §3.1): the declaring module's specifier plus the type's written
    /// name — a stable (host_module, type_name) pair.
    host_id: HostTypeId,
};

/// The host identity of an opaque nominal type (air.md §9.1 `HostTypeId`):
/// names the host type implementation of the declaring module.
pub const HostTypeId = struct {
    host_module: []const u8,
    type_name: []const u8,
};

// ---------------------------------------------------------------------------
// CFG data structures (air.md §11)
// ---------------------------------------------------------------------------

/// The *created* state of a value (air.md §6.1): owned (the defining op
/// produces an owner) or borrowed (a non-owning view of some base). This
/// is a definition-time property of the value, fixed by its defining op.
/// Whether a value is still *available* at a program point — alive,
/// consumed, or consumed on some paths only — is not a value property:
/// it is an edge-sensitive dataflow property computed by the validator
/// (air.md §13) and the lowering's consumption bookkeeping.
pub const ValueState = enum { owned, borrowed };

/// Where a borrowed value's lifetime is anchored (air.md §6.5): the root
/// whose availability the validator checks at every use of the view.
pub const BorrowOrigin = union(enum) {
    /// The immediate base the view derives from; resolved transitively
    /// through view chains to the ultimate root — an owned value in the
    /// current function or the `call` lifetime.
    root: *Value,
    /// A borrow-mode parameter: the root is the caller's argument, which
    /// the callee cannot consume — valid for the whole call (Core §10.7).
    call,
};

pub const ConstValue = union(enum) {
    int: i64, // int32 / uint32 payload; sign per type
    float: f64, // float32 payloads narrow into the low word at interning
    bool: bool,
    string: []const u8,
    void,
};

/// One SSA value: the result of exactly one instruction (air.md §4.1).
/// Parameter values have no defining instruction (`def == null`).
pub const Value = struct {
    /// SSA name — per function, in definition order (`%0..%k-1` params).
    id: u32,
    span: ast.Span,
    type_: Type,
    /// Ownership class from the type (Copy / unique), `null` when
    /// deferred by a named type.
    ownership: ?Ownership,
    /// Created state (owned / borrowed); dead-marking is downstream.
    state: ValueState,
    /// For a `borrowed` value, the origin anchoring its lifetime (§6.5);
    /// `null` iff the state is `owned`.
    origin: ?BorrowOrigin,
    /// The defining instruction, or null for parameters.
    def: ?*Instr,
};

/// One instruction: defines `results` (one value for single-result ops,
/// several for the atomic destructure ops `unpack_struct` / `unpack_tuple` /
/// `unpack_variant` / `split_list` and the non-consuming `borrow_variant`,
/// air.md §5.3) unless it is a pure effect
/// (`drop`, `store_member`, `cleanup_disarm`, `cleanup_drop`, or a
/// `void`/effect `call` / `syscall`).
///
/// `synth` marks constants materialized from inline literals in operand
/// position (air.md §9): the printer re-inlines them so their ids never
/// leak into the text form.
pub const Instr = struct {
    span: ast.Span,
    results: []*Value,
    op: Op,
    synth: bool = false,
};

/// The 3-address op set of air.md §5: at most two operands, except the
/// documented n-ary forms (`construct`, `call`, `syscall`, `phi`).
pub const Op = union(enum) {
    // constants, modules (§5.1) — parameters are SSA roots, not ops
    const_: ConstValue,
    module_ref: []const u8, // module specifier (air.md §11: *const ModuleInfo)

    // function values (§5.5)
    fn_ref: []const u8, // qualified IrFunc name (a lambda or named function)

    // unary (§5.2)
    neg: *Value,
    /// Absolute value: `%d = abs %a` — `int32` wraps on the minimum
    /// (modulo 2³², never traps), `float32` is IEEE (clears the sign
    /// bit). `uint32` has no `abs` (the identity).
    abs: *Value,
    not_: *Value,
    /// Count leading zeros in the 32-bit pattern (`clz(0) = 32`); the
    /// result is the operand type. Unified over int32/uint32 — like the
    /// shifts, the ops are bit-identical patterns.
    clz: *Value,
    /// Population count: set bits in the 32-bit pattern; the result is
    /// the operand type. Unified over int32/uint32.
    popcount: *Value,
    /// The Core §16.3 numeric conversions over the seven conversion types
    /// {byte, int32, uint32, int64, uint64, float32, float64}. Never traps: integer casts are
    /// bit-pattern operations and float→int truncates toward zero and
    /// saturates, NaN becoming zero (Runtime §7.2).
    num_cast: *Value,

    // typed recovery and top-type conversion (§5.2, §4.4)
    type_is: TypeIs,
    /// `T → any` of a Copy source: copies the payload into the
    /// `any`; the source stays owned (Core §11.6).
    any_pack_copy: *Value,
    /// `T → any` of an unique source: moves the payload into the `any`;
    /// the source is consumed (Core §11.6).
    any_pack_move: *Value,
    /// `any as T` with a Copy target: copies the payload out; the
    /// source `any` stays owned (Core §11.6.1).
    any_unpack_copy: *Value,
    /// `(move any) as T`: consumes the whole `any`; payload ownership
    /// transfers to the result (Core §11.6.1).
    any_unpack_move: *Value,

    // binary (§5.2)
    add: Bin,
    sub: Bin,
    mul: Bin,
    div: Bin,
    rem: Bin,
    /// Signed/unsigned/IEEE min: `%d = min %a, %b` — int32/uint32
    /// compare as 32-bit patterns with the opcode's signedness,
    /// float32 follows IEEE 754 `fmin` (NaN propagates, `fmin(-0,+0) =
    /// -0`); never traps.
    min: Bin,
    /// Signed/unsigned/IEEE max: `%d = max %a, %b` — int32/uint32
    /// compare as 32-bit patterns, float32 follows IEEE 754 `fmax`
    /// (NaN propagates, `fmax(-0,+0) = +0`); never traps.
    max: Bin,
    shl: Bin,
    shr: Bin,
    bitand: Bin,
    bitor: Bin,
    bitxor: Bin,
    concat: Bin,
    eq: Bin,
    ne: Bin,
    lt: Bin,
    le: Bin,
    gt: Bin,
    ge: Bin,

    // ternary (§5.2)
    /// Branchless select: `%d = select %cond, %a, %b` — `%a` when
    /// `%cond`, else `%b`. Pure and total: the if-conversion replaces a
    /// branch diamond whose arms are single pure producers with this one
    /// op (the lowered LLIR image is `copy cond_reg, %cond` + `cmov`).
    /// No commutativity — the then/else positions carry the semantics.
    select: Select,

    // ownership (§5.4)
    copy: *Value,
    borrow: *Value,
    move_: *Value,
    drop_: *Value, // effect; no result
    /// Creates a cleanup token scheduling `v`'s conditional destruction
    /// (air.md §6.4). Produces a `Type.cleanup` value usable only by
    /// `cleanup_disarm` and `cleanup_drop`.
    cleanup_arm: *Value,
    /// Disarms a cleanup token without destroying the payload: emitted on
    /// the paths where the owner was consumed (moved, taken, transferred).
    cleanup_disarm: *Value, // effect; no result
    /// The scope-end conditional destruction: destroys the owner iff its
    /// token is still armed, then disarms it. Effect; no result.
    cleanup_drop: *Value,

    // memory (§5.6)
    load_member: LoadMember,
    store_member: StoreMember, // effect; @init only

    // aggregates and projections (§5.3)
    construct: Construct, // n-ary
    read_field: Proj,
    read_tuple: Proj,
    read_index: Index,
    /// `[head, ..tail]`: a borrowed sublist view (Core §14.5).
    tail: *Value,
    /// Atomic consuming destructures (§5.3): one op consumes the base as
    /// a whole and defines all of its parts (multi-result). No
    /// half-consumed base states exist.
    unpack_struct: *Value, // struct pattern: all field values
    unpack_tuple: *Value, // tuple pattern: all element values
    unpack_variant: UnpackVariant, // union arm: the variant's payload values
    split_list: *Value, // list pattern: item values, then the rest
    read_tag: *Value,
    read_payload: *Value,
    /// Non-consuming multi-result variant projection (air.md §5.3): a
    /// borrowed-match payload read, symmetric with `unpack_variant`. The
    /// base is never consumed; a Copy payload is copied out (owned), an
    /// unique payload is a borrowed view rooted at the base.
    borrow_variant: BorrowVariant,

    // calls (§8)
    call: Call, // n-ary
    syscall: SysCall, // n-ary

    // SSA (§4.3)
    phi: Phi, // n-ary
};

pub const Bin = struct { a: *Value, b: *Value };
/// The branchless select's operands: the boolean condition and the
/// then/else values (`%d = select %cond, %a, %b`).
pub const Select = struct { cond: *Value, a: *Value, b: *Value };
pub const Proj = struct { base: *Value, index: u32 };
pub const Index = struct { base: *Value, index: *Value };
pub const UnpackVariant = struct { base: *Value, tag: u32 };
pub const BorrowVariant = struct { base: *Value, tag: u32 };

// ---------------------------------------------------------------------------
// Op schema (air.md §5, §13) — the single machine-readable contract
// ---------------------------------------------------------------------------

/// Value-operand arity. `zero`/`one`/`two`/`three` are the 3-address
/// forms (select is the sole ternary); the n-ary exceptions
/// (`construct`, `call`, `syscall`, `phi`) are exactly the ops with a
/// statically typed, fixed-shape operand list (air.md §4.2).
pub const Arity = enum { zero, one, two, three, nary };

/// Which value operands this op *consumes* (air.md §6.2): the operand's
/// ownership transfers into the instruction (or the value is destroyed by
/// it) and the operand is dead afterwards. Ops whose consumption depends
/// on operand types or a callee signature (`call`, `syscall`, `construct`,
/// `arg`-mode parameters) declare `.none`; the validator resolves those
/// from the types/signature.
pub const Consumes = enum { none, op0, op1, both, all };

/// The created state of the result (air.md §6.1); `.operand` means the
/// state derives from an operand (borrow-mode `arg`, projections of an
/// unique base), `.none` for pure effects.
pub const Created = enum { owned, borrowed, operand, none };

/// One row of the op schema: everything the validator, parser, printer,
/// and optimizer need to know about an op without hand-rolled switches.
/// `opInfo` is an exhaustive comptime switch over the `Op` tags, so the
/// schema is the single source of truth — a new op must be added here or
/// the compiler rejects the switch, and the text spelling the printer and
/// parser use comes from `OpInfo.text` alone.
pub const OpInfo = struct {
    /// Canonical text spelling (air.md §9).
    text: []const u8,
    /// Value-operand count (the 3-address property, air.md §4.2).
    arity: Arity,
    /// Ownership effect on the fixed operands.
    consumes: Consumes,
    /// Created state of the result.
    created: Created,
    /// May trap at runtime (Runtime §7.2): division/remainder by zero
    /// (and the `int32_min / -1` signed-division overflow), index bounds,
    /// and invalid `any` recovery.
    /// Integer arithmetic wraps modulo 2³² and never traps (WebAssembly
    /// semantics); casts never trap — out-of-range values truncate
    /// (Runtime §7.2). An op that may
    /// trap must never be hoisted onto a path that could skip it (PRE).
    may_trap: bool,
    /// Has observable side effects beyond producing its result (calls,
    /// syscalls, drops, store_member, cleanup_disarm): such ops are
    /// never CSE'd, moved, or elided.
    effects: bool,
    /// True when the op defines more than one result value (the atomic
    /// destructure ops). The text form prints a comma-separated lhs and
    /// the parser/validator accept any count ≥ 1; single-result ops have
    /// exactly 0 or 1 results per `created`.
    multi: bool = false,

    /// True when the op is a candidate for pure-computation rewriting
    /// (CSE within a block is safe for may-trap ops; PRE is not).
    pub fn pure(self: OpInfo) bool {
        return !self.effects and !self.may_trap;
    }
};

/// The schema row for every op. The switch is exhaustive over `Op`'s
/// tags, so `Op` and the schema can never drift — adding an op to the
/// union without a row here is a compile error.
pub fn opInfo(tag: OpTag) OpInfo {
    return switch (tag) {
        // constants, modules (§5.1)
        .const_ => .{ .text = "const", .arity = .zero, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .module_ref => .{ .text = "module_ref", .arity = .zero, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },

        // function values (§5.5)
        .fn_ref => .{ .text = "fn_ref", .arity = .zero, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },

        // unary (§5.2): integer negation wraps modulo 2³² (`int32_min`
        // negated is `int32_min`); float negation is IEEE — never traps.
        // `abs` wraps the same way on `int32_min` (WebAssembly
        // semantics); `clz`/`popcount` are total bit-pattern counts
        // (unified over int32/uint32)
        .neg => .{ .text = "neg", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .abs => .{ .text = "abs", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .clz => .{ .text = "clz", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .popcount => .{ .text = "popcount", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .not_ => .{ .text = "not", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .num_cast => .{ .text = "num_cast", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },

        // typed recovery and top-type conversion (§5.2, §4.4)
        .type_is => .{ .text = "type_is", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .any_pack_copy => .{ .text = "any_pack_copy", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .any_pack_move => .{ .text = "any_pack_move", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false },
        .any_unpack_copy => .{ .text = "any_unpack_copy", .arity = .one, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .any_unpack_move => .{ .text = "any_unpack_move", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = true, .effects = false },

        // binary (§5.2): int add/sub/mul wrap modulo 2³² and never trap
        // (WebAssembly semantics); div/rem trap on a zero divisor, and the
        // int32 div form also on int32_min / -1; comparisons and concat
        // are total
        .add => .{ .text = "add", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .sub => .{ .text = "sub", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .mul => .{ .text = "mul", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .div => .{ .text = "div", .arity = .two, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .rem => .{ .text = "rem", .arity = .two, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        // min/max are total: the int32/uint32 forms compare as 32-bit
        // patterns (signedness fixed by the opcode), f32 follows IEEE
        // 754 fmin/fmax — never trap for any operand.
        .min => .{ .text = "min", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .max => .{ .text = "max", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        // Shifts never trap: the count is masked to its low 5 bits (mod
        // 32, WebAssembly semantics) — total for every count value.
        .shl => .{ .text = "shl", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .shr => .{ .text = "shr", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        // Bitwise and/or/xor operate on the raw 32-bit patterns and
        // never trap — total for every operand.
        .bitand => .{ .text = "bitand", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .bitor => .{ .text = "bitor", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .bitxor => .{ .text = "bitxor", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .concat => .{ .text = "concat", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .eq => .{ .text = "eq", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .ne => .{ .text = "ne", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .lt => .{ .text = "lt", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .le => .{ .text = "le", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .gt => .{ .text = "gt", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .ge => .{ .text = "ge", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        // Branchless select: pure and total, the then/else positions are
        // not interchangeable (no commutativity), and the result is the
        // selected value's type (air.md §5.2, §12).
        .select => .{ .text = "select", .arity = .three, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },

        // ownership (§5.4)
        .copy => .{ .text = "copy", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .borrow => .{ .text = "borrow", .arity = .one, .consumes = .none, .created = .borrowed, .may_trap = false, .effects = false },
        .move_ => .{ .text = "move", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false },
        .drop_ => .{ .text = "drop", .arity = .one, .consumes = .op0, .created = .none, .may_trap = false, .effects = true },
        .cleanup_arm => .{ .text = "cleanup_arm", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .cleanup_disarm => .{ .text = "cleanup_disarm", .arity = .one, .consumes = .none, .created = .none, .may_trap = false, .effects = true },
        .cleanup_drop => .{ .text = "cleanup_drop", .arity = .one, .consumes = .none, .created = .none, .may_trap = false, .effects = true },

        // memory (§5.6)
        .load_member => .{ .text = "load_member", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .store_member => .{ .text = "store_member", .arity = .one, .consumes = .op0, .created = .none, .may_trap = false, .effects = true },

        // aggregates and projections (§5.3)
        .construct => .{ .text = "construct", .arity = .nary, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .read_field => .{ .text = "read_field", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        .read_tuple => .{ .text = "read_tuple", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        .read_index => .{ .text = "read_index", .arity = .two, .consumes = .none, .created = .operand, .may_trap = true, .effects = false },
        // A `tail` view's created state follows the *base*'s ownership
        // (`.operand`): a Copy list's view is a Copy value,
        // an unique list's view is borrowed (matches read_*).
        .tail => .{ .text = "tail", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        // Atomic consuming destructures (§5.3): one op, base consumed as
        // a whole, all parts defined at once (multi-result).
        .unpack_struct => .{ .text = "unpack_struct", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false, .multi = true },
        .unpack_tuple => .{ .text = "unpack_tuple", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false, .multi = true },
        .unpack_variant => .{ .text = "unpack_variant", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false, .multi = true },
        .split_list => .{ .text = "split_list", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = true, .effects = false, .multi = true },
        .read_tag => .{ .text = "read_tag", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .read_payload => .{ .text = "read_payload", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        // `borrow_variant` mirrors `read_payload` but multi-result: the
        // base is not consumed (`.consumes = .none`); each result's state
        // follows its payload type (Copy -> owned copy, unique -> borrowed)
        // via `.created = .operand`.
        .borrow_variant => .{ .text = "borrow_variant", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false, .multi = true },

        // calls (§8)
        .call => .{ .text = "call", .arity = .nary, .consumes = .none, .created = .owned, .may_trap = true, .effects = true },
        .syscall => .{ .text = "syscall", .arity = .nary, .consumes = .none, .created = .owned, .may_trap = true, .effects = true },

        // SSA (§4.3)
        .phi => .{ .text = "phi", .arity = .nary, .consumes = .all, .created = .owned, .may_trap = false, .effects = false },
    };
}

/// The borrow origin of a borrowed result (air.md §6.5): the root whose
/// availability gates every use of the view. `borrow %a` roots at the
/// base value; a projection (`read_*` / `tail`) of an unique base roots
/// at the base; `load_member` of an unique constant member roots at the
/// module value (module storage is immutable after `@init`, Core §5).
/// Returns `null` for `owned` results and for borrows without a tracked
/// local root.
pub fn originOf(op: Op) ?BorrowOrigin {
    return switch (op) {
        .borrow => |a| .{ .root = a },
        .read_field, .read_tuple => |p| .{ .root = p.base },
        .read_index => |p| .{ .root = p.base },
        .read_payload => |p| .{ .root = p },
        .borrow_variant => |b| .{ .root = b.base },
        .tail => |v| .{ .root = v },
        .load_member => |lm| .{ .root = lm.module },
        else => null,
    };
}

/// One row of the op table: the op's tag plus its schema row.
pub const OpRow = struct { tag: OpTag, info: OpInfo };

/// Every op, with its schema row, in `Op` tag order — the comptime table
/// the parser's op-name map and the drift tests iterate.
pub const op_table: []const OpRow = &op_table_data;
const op_table_data: [std.meta.tags(OpTag).len]OpRow = blk: {
    var table: [std.meta.tags(OpTag).len]OpRow = undefined;
    for (std.meta.tags(OpTag), 0..) |tag, i| table[i] = .{ .tag = tag, .info = opInfo(tag) };
    break :blk table;
};

/// The tag type of the `Op` union.
pub const OpTag = std.meta.Tag(Op);

/// Structural equality of two computations (air.md §5): same opcode, same
/// operands in the same position. No commutativity — floating-point and
/// NaN behavior must be unchanged. Shared by the construction-time CSE
/// (cfg_lower_emit.zig, braun13cc.pdf §3.1) and the partial redundancy
/// elimination pass (cfg_pre.zig), which match computations across
/// blocks.
pub fn identical(a: Op, b: Op) bool {
    return switch (a) {
        .neg => |x| b == .neg and x == b.neg,
        .abs => |x| b == .abs and x == b.abs,
        .clz => |x| b == .clz and x == b.clz,
        .popcount => |x| b == .popcount and x == b.popcount,
        .not_ => |x| b == .not_ and x == b.not_,
        .num_cast => |x| b == .num_cast and x == b.num_cast,
        .tail => |x| b == .tail and x == b.tail,
        .read_tag => |x| b == .read_tag and x == b.read_tag,
        .read_payload => |x| b == .read_payload and x == b.read_payload,
        .add => |x| b == .add and eqBin(x, b.add),
        .sub => |x| b == .sub and eqBin(x, b.sub),
        .mul => |x| b == .mul and eqBin(x, b.mul),
        .div => |x| b == .div and eqBin(x, b.div),
        .rem => |x| b == .rem and eqBin(x, b.rem),
        .min => |x| b == .min and eqBin(x, b.min),
        .max => |x| b == .max and eqBin(x, b.max),
        .shl => |x| b == .shl and eqBin(x, b.shl),
        .shr => |x| b == .shr and eqBin(x, b.shr),
        .bitand => |x| b == .bitand and eqBin(x, b.bitand),
        .bitor => |x| b == .bitor and eqBin(x, b.bitor),
        .bitxor => |x| b == .bitxor and eqBin(x, b.bitxor),
        .concat => |x| b == .concat and eqBin(x, b.concat),
        .eq => |x| b == .eq and eqBin(x, b.eq),
        .ne => |x| b == .ne and eqBin(x, b.ne),
        .lt => |x| b == .lt and eqBin(x, b.lt),
        .le => |x| b == .le and eqBin(x, b.le),
        .gt => |x| b == .gt and eqBin(x, b.gt),
        .ge => |x| b == .ge and eqBin(x, b.ge),
        .select => |x| b == .select and eqSelect(x, b.select),
        .type_is => |x| b == .type_is and x.value == b.type_is.value and Type.eql(x.type_, b.type_is.type_),
        .read_field => |x| b == .read_field and eqProj(x, b.read_field),
        .read_tuple => |x| b == .read_tuple and eqProj(x, b.read_tuple),
        .read_index => |x| b == .read_index and eqIndex(x, b.read_index),
        else => false,
    };
}

fn eqBin(x: Bin, y: Bin) bool {
    return x.a == y.a and x.b == y.b;
}

fn eqSelect(x: Select, y: Select) bool {
    return x.cond == y.cond and x.a == y.a and x.b == y.b;
}

fn eqProj(x: Proj, y: Proj) bool {
    return x.base == y.base and x.index == y.index;
}

fn eqIndex(x: Index, y: Index) bool {
    return x.base == y.base and x.index == y.index;
}

/// Tests whether an `any` value's runtime tag matches a concrete type
/// (Core §11.6.2 type-test patterns, Grammar `type-test-pattern`). The
/// result is a `bool`; the payload is recovered by an `any_unpack_copy`
/// / `any_unpack_move` in the matching arm (Core §11.6.1).
pub const TypeIs = struct { value: *Value, type_: Type };

/// struct / tuple / list / union-variant construction (Core §8, §11).
pub const Construct = struct {
    /// Union variants carry a discriminant; others use null.
    tag: ?u32,
    args: []*Value,
};

pub const LoadMember = struct {
    module: *Value, // a module_ref value
    /// Member index: the member's position in the module's value-member
    /// declaration order (air.md §7). The member table that resolves this
    /// index is runtime-facing and not modeled in the AIR.
    member: u32,
};

pub const StoreMember = struct {
    slot: u32, // SlotId: constant members only (§7)
    value: *Value,
};

/// A direct call target. The text format allows naming a function defined
/// later in the program; `func` is filled by `IrProgram.resolveDirectCalls`
/// once every module is parsed.
pub const DirectCallee = struct {
    name: []const u8,
    func: ?*IrFunc = null,
};

pub const Callee = union(enum) {
    direct: DirectCallee,
    value: *Value, // a function value
};

pub const Call = struct {
    callee: Callee,
    args: []*Value,
};

/// The required `builtin` members (Runtime §4) — the syscall dispatch
/// names of the standard `builtin` module (Core §3). This mirrors
/// `std/builtin.st` exactly: the list operations `len` and `range` are
/// not builtins — they live in the `list` module and dispatch as
/// `list#len` / `list#range` host-module syscalls (Runtime §4.3, §4.4).
pub const BuiltinId = enum {
    print,
    str,
    box,
    unbox,
    panic,
    assert,
    hash,
};

pub const SysCallTarget = union(enum) {
    builtin: BuiltinId,
    host_module: struct { module: []const u8, member: []const u8 },
};

pub const SysCall = struct {
    span: ast.Span,
    target: SysCallTarget,
    args: []*Value,
    /// The host binding's specialized concrete signature (air.md §8.2,
    /// §9.3): parameter modes and types plus the result type. Generic
    /// builtins (`box`, `unbox`, `str`, `hash`) were specialized
    /// in phase 2, so the call site carries the resolved signature;
    /// `sig.ret` is `never` for panicking bindings. Null only for
    /// text-form-parsed AIR (the text form carries no parameter modes,
    /// air.md §10); the frontend always writes the signature.
    sig: ?FunctionType,
};

pub const Phi = struct {
    /// One (incoming value, predecessor block) per in-edge, in the same
    /// order as `BasicBlock.preds`.
    incoming: []PhiIn,
};
pub const PhiIn = struct { value: *Value, pred: *BasicBlock };

pub const Terminator = union(enum) {
    ret: ?*Value,
    j: *BasicBlock,
    br: struct { cond: *Value, then_: *BasicBlock, else_: *BasicBlock },
    @"switch": Switch,
    /// Frame-reusing direct self-call (air.md §14.7.1): the move/unique
    /// form of a direct self-recursive tail call. Arguments are
    /// transferred into the reused frame's parameter slots and the frame
    /// is jumped to, so the block is an **exit** (no out-edge, like `ret` /
    /// `trap`) — there is no result to return.
    tailcall: TailCall,
    trap,
};

pub const TailCall = struct {
    /// Target function name (text form). A `tailcall` is always a direct
    /// self-call; `func` resolves to the enclosing `IrFunc`.
    name: []const u8,
    func: ?*IrFunc = null,
    args: []*Value,
};

pub const Switch = struct {
    disc: *Value, // a read_tag result
    arms: []SwitchArm, // tag -> block; implicit trap default
};
pub const SwitchArm = struct { tag: u32, block: *BasicBlock };

pub const BasicBlock = struct {
    id: u32,
    span: ast.Span,
    /// Text-form label; layout order is `IrFunc.blocks` order.
    name: []const u8,
    instrs: []*Instr,
    terminator: Terminator,
    /// In-edges, in phi order (air.md §3, §4.3).
    preds: []*BasicBlock,
};

pub const IrFunc = struct {
    id: u32,
    span: ast.Span,
    name: ast.Ident,
    params: []Param,
    ret: Type,
    entry: *BasicBlock,
    blocks: []*BasicBlock,
    /// Per-function value table, in definition order (`%0, %1, …`).
    values: []*Value,
    /// Resolved specifier of the module that defines this function; set by
    /// the frontend lowering (air.md §11 omits it — the text form has no
    /// module-qualified names, so the parser leaves it null).
    module_spec: ?[]const u8 = null,
};

/// A block-finalization diagnostic: the offending span and a pre-formatted
/// message (allocated from the caller's arena).
pub const FinalizeDiag = struct {
    span: ast.Span,
    message: []const u8,
};

/// Finalize a function's blocks (air.md §3, §4.3): dupe each block's
/// instruction slice from the parallel builder list, compute predecessor
/// lists in edge order, check the entry block has no predecessors, and
/// validate every phi's incoming list against the block's in-edges.
///
/// When `phi_lists` is present, phi incoming lists are materialized from
/// the deferred builders first (the frontend lowering's pattern); the AIR
/// text parser sets `phi.incoming` directly and passes `null`. On a
/// structural error returns a `FinalizeDiag`; otherwise `null`.
pub fn finalizeBlocks(
    allocator: std.mem.Allocator,
    blocks: []*BasicBlock,
    block_instrs: []const []const *Instr,
    phi_lists: ?*const std.AutoHashMapUnmanaged(*Instr, *std.ArrayList(PhiIn)),
) error{OutOfMemory}!?FinalizeDiag {
    for (blocks, 0..) |b, i| {
        b.instrs = try allocator.dupe(*Instr, block_instrs[i]);
    }
    // Predecessors in edge order (air.md §3).
    var preds = std.ArrayList(std.ArrayList(*BasicBlock)).empty;
    for (blocks) |_| try preds.append(allocator, .empty);
    for (blocks) |b| {
        switch (b.terminator) {
            .ret, .tailcall, .trap => {},
            .j => |tgt| try preds.items[tgt.id].append(allocator, b),
            .br => |bc| {
                try preds.items[bc.then_.id].append(allocator, b);
                try preds.items[bc.else_.id].append(allocator, b);
            },
            .@"switch" => |s| {
                for (s.arms) |arm| try preds.items[arm.block.id].append(allocator, b);
            },
        }
    }
    for (blocks, 0..) |b, i| {
        b.preds = try allocator.dupe(*BasicBlock, preds.items[i].items);
    }
    if (blocks[0].preds.len != 0) {
        return .{
            .span = blocks[0].span,
            .message = try std.fmt.allocPrint(allocator, "entry block '{s}' has predecessors", .{blocks[0].name}),
        };
    }
    // Phi incoming lists: materialize the deferred builders (when given)
    // and check they match the block's in-edges, in order (air.md §4.3).
    for (blocks) |b| {
        for (b.instrs) |instr| {
            switch (instr.op) {
                .phi => |*phi| {
                    if (phi_lists) |lists| {
                        const builder = lists.get(instr) orelse continue;
                        phi.incoming = try allocator.dupe(PhiIn, builder.items);
                    }
                    if (phi.incoming.len != b.preds.len) {
                        return .{
                            .span = instr.span,
                            .message = try std.fmt.allocPrint(allocator, "phi in block '{s}' has {d} incoming values but {d} predecessors", .{ b.name, phi.incoming.len, b.preds.len }),
                        };
                    }
                    for (phi.incoming, b.preds) |inc, p| {
                        if (inc.pred != p) {
                            return .{
                                .span = instr.span,
                                .message = try std.fmt.allocPrint(allocator, "phi incoming order does not match predecessors in block '{s}'", .{b.name}),
                            };
                        }
                    }
                },
                else => {},
            }
        }
    }
    return null;
}

/// The canonical block order for printing and renumbering (cfg_print.zig,
/// shared by the CFG passes): the entry block first, then ascending
/// minimum defined-value id, value-less blocks last by creation id.
pub const BlockOrder = struct {
    entry: *const BasicBlock,

    pub fn lessThan(ctx: BlockOrder, a: *const BasicBlock, b: *const BasicBlock) bool {
        if (a == ctx.entry) return b != ctx.entry;
        if (b == ctx.entry) return false;
        const am = minValueId(a) orelse std.math.maxInt(u32);
        const bm = minValueId(b) orelse std.math.maxInt(u32);
        if (am != bm) return am < bm;
        // Value-less blocks (bare `j` joins) keep creation order.
        return a.id < b.id;
    }
};

/// The smallest defined-value id in a block; null when the block defines
/// no values (only a terminator). Multi-result instructions anchor on
/// their first result.
pub fn minValueId(b: *const BasicBlock) ?u32 {
    var min: ?u32 = null;
    for (b.instrs) |instr| {
        if (instr.results.len > 0) {
            const r = instr.results[0];
            if (min == null or r.id < min.?) min = r.id;
        }
    }
    return min;
}

/// Renumber `f`'s values in the canonical print order (air.md §4.1, §13):
/// parameters first (`%0..%k-1`), then each block in print order, each
/// instruction's results in instruction order — and rebuild the per-function
/// value table to match. Idempotent; call after a pass adds or removes
/// values so ids and the table stay in text order.
pub fn renumberValues(f: *IrFunc, allocator: std.mem.Allocator) !void {
    const order = try allocator.alloc(*BasicBlock, f.blocks.len);
    defer allocator.free(order);
    for (f.blocks, 0..) |b, i| order[i] = b;
    std.mem.sort(*BasicBlock, order, BlockOrder{ .entry = f.entry }, BlockOrder.lessThan);

    var values = std.ArrayList(*Value).empty;
    for (f.values[0..f.params.len]) |v| try values.append(allocator, v);
    var next: u32 = @intCast(f.params.len);
    for (order) |b| {
        for (b.instrs) |instr| {
            for (instr.results) |v| {
                v.id = next;
                next += 1;
                try values.append(allocator, v);
            }
        }
    }
    f.values = try values.toOwnedSlice(allocator);
}

/// Rewrite every operand of every instruction and terminator in `f` that
/// is `from` to `to` — phi incomings and `drop` operands included. The
/// defining instruction of `from` is left in place (the caller removes it
/// separately). Sound when `to` is available wherever `from` was: every
/// use of `from` is dominated by its definition, so replacing `from` with
/// a value defined earlier in the same block (the rewrite passes' common
/// case) is always safe.
pub fn rewriteUses(f: *IrFunc, from: *Value, to: *Value) void {
    for (f.blocks) |b| {
        for (b.instrs) |instr| switch (instr.op) {
            .neg, .abs, .clz, .popcount, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .cleanup_disarm, .cleanup_drop, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |*v| {
                if (v.* == from) v.* = to;
            },
            .unpack_variant => |*uv| {
                if (uv.base == from) uv.base = to;
            },
            .borrow_variant => |*bv| {
                if (bv.base == from) bv.base = to;
            },
            .type_is => |*x| {
                if (x.value == from) x.value = to;
            },
            .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .concat, .eq, .ne, .lt, .le, .gt, .ge => |*x| {
                if (x.a == from) x.a = to;
                if (x.b == from) x.b = to;
            },
            .select => |*x| {
                if (x.cond == from) x.cond = to;
                if (x.a == from) x.a = to;
                if (x.b == from) x.b = to;
            },
            .load_member => |*x| {
                if (x.module == from) x.module = to;
            },
            .store_member => |*x| {
                if (x.value == from) x.value = to;
            },
            .construct => |*x| {
                for (x.args) |*a| {
                    if (a.* == from) a.* = to;
                }
            },
            .read_field, .read_tuple => |*x| {
                if (x.base == from) x.base = to;
            },
            .read_index => |*x| {
                if (x.base == from) x.base = to;
                if (x.index == from) x.index = to;
            },
            .call => |*x| {
                if (x.callee == .value and x.callee.value == from) x.callee.value = to;
                for (x.args) |*a| {
                    if (a.* == from) a.* = to;
                }
            },
            .syscall => |*x| {
                for (x.args) |*a| {
                    if (a.* == from) a.* = to;
                }
            },
            .phi => |*x| {
                for (x.incoming) |*inc| {
                    if (inc.value == from) inc.value = to;
                }
            },
            .const_, .module_ref, .fn_ref => {},
        };
        switch (b.terminator) {
            .ret => |v| {
                if (v) |val| {
                    if (val == from) b.terminator.ret = to;
                }
            },
            .j => {},
            .br => |*bc| {
                if (bc.cond == from) bc.cond = to;
            },
            .@"switch" => |*s| {
                if (s.disc == from) s.disc = to;
            },
            .tailcall => |*tc| {
                for (tc.args) |*a| {
                    if (a.* == from) a.* = to;
                }
            },
            .trap => {},
        }
    }
}

pub const SlotMeta = struct {
    type_: Type,
};

/// One row of a module's member table (air.md §9.6 `ModuleMember`): a
/// runtime value member in declaration order, with its kind and type.
pub const ModuleMember = struct {
    /// Written member name (diagnostics only).
    name: []const u8,
    /// The member's resolved type: the constant's type, the function's
    /// monomorphic signature, or the module type of a module value.
    type_: Type,
    kind: MemberKind,
};

/// The four member kinds (air.md §7, §9.6 `MemberKind`). Only `const_slot`
/// members occupy runtime storage.
pub const MemberKind = union(enum) {
    /// A runtime constant: occupies storage slot `slot` (an index into
    /// `IrModule.slots` — a *distinct index space* from member indices,
    /// air.md §7). A void-typed constant occupies no storage and carries
    /// null. A host constant (a `const` declaration without an
    /// initializer) is a const slot `@init` never writes and no
    /// `store_member` targets.
    const_slot: ?u32,
    /// A function declaration: a direct reference to its `IrFunc`
    /// (null for a generic template — templates are never lowered, each
    /// used specialization is a separate `IrFunc`, air.md §11).
    function: ?*IrFunc,
    /// A module-valued constant: a static reference to the resolved
    /// module specifier.
    module_ref: []const u8,
    /// A declaration without a Stilla body: a syscall target. The
    /// runtime dispatches on (module, member name) — the row's index is
    /// the AIR member index (air.md §7), not the dispatch key
    /// (Intrinsics Specification §4; the embedded bundle's intrinsic
    /// rows are gone entirely, air.md §5.6).
    host_binding,
};

pub const IrModule = struct {
    span: ast.Span,
    /// Resolved specifier of the module.
    name: []const u8,
    /// The module init function (a `func @init`), when one is defined.
    init: ?*IrFunc,
    funcs: []*IrFunc,
    /// The member table (air.md §7, §9.6): every runtime value member in
    /// declaration order, exactly one row per member index — the
    /// `load_member` operand space. Null only for text-form-parsed AIR
    /// (the text form carries no member declarations, air.md §10); the
    /// frontend always materializes it, possibly empty.
    members: ?[]ModuleMember,
    /// Module storage layout: the constant members only, derived from
    /// `@init`'s `store_member` ops (Runtime §2.2). Stored in slot order.
    slots: []SlotMeta,
};

pub const IrProgram = struct {
    modules: []*IrModule, // text order
    funcs: []*IrFunc, // all functions, in module order
    /// The type environment (air.md §9.1): one `TypeDecl` per nominal type
    /// in use, indexed by the `TypeId` that `Type.named` carries.
    /// Populated by the frontend lowering (concrete layout — struct
    /// fields, union variants, ownership, drop hooks, opaque `host_id`)
    /// and, for text-form-parsed programs, by the parser as it interns
    /// each first-seen name (`TypeDecl.unknown` — the text form carries
    /// no type declarations, air.md §10).
    types: []TypeDecl,
    entry: ?*IrFunc, // host-selected entry, when present

    /// The declaration behind a `TypeId`, or null when the id is out of
    /// range (a `Type.named` referencing an interned name always has a
    /// row; null is the defensive answer for a corrupt id).
    pub fn typeDecl(self: *const IrProgram, id: TypeId) ?TypeDecl {
        if (id >= self.types.len) return null;
        return self.types[id];
    }

    /// The declared ownership class of a named instantiation (air.md
    /// §9.1): opaque types and drop-hooked structs are unique by
    /// declaration; a struct or union is Copy iff every owned component
    /// is Copy. Resolved structurally through the declarations with the
    /// instantiation's type arguments substituted, without reference to
    /// the source module graph. `null` when the declaration is unknown
    /// (text-form-parsed AIR) or a type argument stays unresolved.
    pub fn namedOwnership(self: *const IrProgram, allocator: std.mem.Allocator, n: Type.Named) ?Ownership {
        var visited = std.ArrayList(Type.Named).empty;
        return ownershipNamed(self, allocator, n, &visited);
    }

    /// Resolve the module a value refers to — the module identity the
    /// value's `module_ref` / module-valued `load_member` chain names
    /// (air.md §7: chained library paths lower to a chain of
    /// `load_member` ops) — or null when the value is not a statically
    /// known module reference. A phi over module values resolves when
    /// every incoming names the same module.
    pub fn moduleOf(self: *const IrProgram, v: *const Value) ?*const IrModule {
        return moduleIdentity(self, v);
    }

    pub fn resolveDirectCalls(self: *IrProgram, allocator: std.mem.Allocator) !void {
        var map = std.StringHashMap(*IrFunc).init(allocator);
        for (self.funcs) |f| {
            if (!map.contains(f.name.text)) try map.put(f.name.text, f);
        }
        for (self.funcs) |f| {
            for (f.blocks) |b| {
                for (b.instrs) |instr| {
                    switch (instr.op) {
                        .call => |*c| switch (c.callee) {
                            .direct => |*d| if (d.func == null) {
                                d.func = map.get(d.name);
                            },
                            else => {},
                        },
                        else => {},
                    }
                }
                switch (b.terminator) {
                    .tailcall => |*tc| if (tc.func == null) {
                        tc.func = map.get(tc.name);
                    },
                    else => {},
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Type environment queries (air.md §9.1) — ownership and module identity
// resolved from the program alone, without the source module graph.
// ---------------------------------------------------------------------------

/// Least-fixpoint ownership of a named instantiation (Core §10.3): a
/// back-edge to a named type currently being classified — a recursive
/// occurrence reached through an owned component — is unique; a cycle
/// that passes only through function types is Copy. The ancestor stack is
/// a path set, not a grow-only seen set: sibling instantiations of one
/// declaration (`Option[int32]` and `Option[str]`) are distinct types.
fn ownershipNamed(self: *const IrProgram, allocator: std.mem.Allocator, n: Type.Named, visited: *std.ArrayList(Type.Named)) ?Ownership {
    const decl = self.typeDecl(n.id) orelse return null;
    return switch (decl) {
        .unknown => return null, // text-form AIR: layout unknown
        .opaque_ => return .unique, // unique by declaration (Core §11.8)
        .struct_ => |s| blk: {
            if (s.drop != null) break :blk .unique; // a hook implies unique
            if (s.ownership) |ow| break :blk ow; // non-generic: declared class
            // Generic: substitute the instantiation's arguments and walk
            // the fields (the fixpoint guard must see the instantiated
            // form, not the raw declaration).
            for (visited.items) |anc| if (Type.namedEql(n, anc)) break :blk .unique;
            visited.append(allocator, n) catch break :blk null;
            defer _ = visited.pop();
            var acc: ?Ownership = .copy;
            for (s.fields) |f| {
                const ft = substParams(allocator, s.type_params, n.args, f.type_);
                const ow = ownershipType(self, allocator, ft, visited) orelse {
                    acc = .unique;
                    break;
                };
                if (ow == .unique) acc = .unique;
            }
            break :blk acc;
        },
        .union_ => |u| blk: {
            if (u.ownership) |ow| break :blk ow;
            for (visited.items) |anc| if (Type.namedEql(n, anc)) break :blk .unique;
            visited.append(allocator, n) catch break :blk null;
            defer _ = visited.pop();
            var acc: ?Ownership = .copy;
            for (u.variants) |v| for (v.payloads) |pt| {
                const pt_sub = substParams(allocator, u.type_params, n.args, pt);
                const ow = ownershipType(self, allocator, pt_sub, visited) orelse {
                    acc = .unique;
                    break;
                };
                if (ow == .unique) acc = .unique;
            };
            break :blk acc;
        },
    };
}

/// Structural ownership of an arbitrary type (air.md §6.1): primitives
/// are Copy except `any` / `hostdata`; function and module values are
/// Copy; containers join their components; named types resolve through
/// the declarations; `null` for a deferred type parameter.
fn ownershipType(self: *const IrProgram, allocator: std.mem.Allocator, t: Type, visited: *std.ArrayList(Type.Named)) ?Ownership {
    return switch (t) {
        .primitive => |k| if (k == .any or k == .hostdata) .unique else .copy,
        .module, .function, .cleanup => .copy,
        .param => null,
        .list, .box => |inner| ownershipType(self, allocator, inner.*, visited),
        .tuple => |elems| blk: {
            var acc: ?Ownership = .copy;
            for (elems) |e| {
                const ow = ownershipType(self, allocator, e, visited) orelse break :blk null;
                if (ow == .unique) acc = .unique;
            }
            break :blk acc;
        },
        .named => |nn| ownershipNamed(self, allocator, nn, visited),
    };
}

/// Substitute a type's `.param` occurrences with the instantiation's
/// type arguments (air.md §9.1): a generic struct/union declaration's
/// fields and payloads reference the declaration's type parameters, and
/// resolving an instantiation replaces each `.param` with its argument
/// (`Option[int32]`'s `Some` payload becomes `int32`). Parameters with
/// no matching argument are left unresolved. Best-effort allocation: on
/// OOM the original type is returned unchanged (the queries run in
/// arena contexts where OOM is not recoverable anyway).
pub fn substParams(allocator: std.mem.Allocator, params: []const []const u8, args: []const Type, t: Type) Type {
    return switch (t) {
        .param => |p| blk: {
            // `args` may be shorter than `params` for a wildcard
            // instantiation; parameters past the provided arguments are
            // left unresolved rather than crashing the zip.
            for (params, 0..) |prm, i| {
                if (i >= args.len) break;
                if (std.mem.eql(u8, p, prm)) break :blk args[i];
            }
            break :blk t;
        },
        .named => |n| blk: {
            if (n.args.len == 0) break :blk t;
            const out = allocator.alloc(Type, n.args.len) catch break :blk t;
            for (n.args, 0..) |a, i| out[i] = substParams(allocator, params, args, a);
            break :blk .{ .named = .{ .id = n.id, .args = out } };
        },
        .list => |inner| blk: {
            const sub = substParams(allocator, params, args, inner.*);
            if (Type.eql(sub, inner.*)) break :blk t;
            const ptr = allocator.create(Type) catch break :blk t;
            ptr.* = sub;
            break :blk .{ .list = ptr };
        },
        .box => |inner| blk: {
            const sub = substParams(allocator, params, args, inner.*);
            if (Type.eql(sub, inner.*)) break :blk t;
            const ptr = allocator.create(Type) catch break :blk t;
            ptr.* = sub;
            break :blk .{ .box = ptr };
        },
        .tuple => |elems| blk: {
            var changed = false;
            const out = allocator.alloc(Type, elems.len) catch break :blk t;
            for (elems, 0..) |e, i| {
                out[i] = substParams(allocator, params, args, e);
                if (!Type.eql(out[i], e)) changed = true;
            }
            break :blk if (changed) .{ .tuple = out } else t;
        },
        .function => |f| blk: {
            var changed = false;
            const params_out = allocator.alloc(Param, f.params.len) catch break :blk t;
            for (f.params, 0..) |*p, i| {
                params_out[i] = .{
                    .span = p.span,
                    .name = p.name,
                    .mode = p.mode,
                    .type_ = substParams(allocator, params, args, p.type_),
                };
                if (!Type.eql(params_out[i].type_, p.type_)) changed = true;
            }
            const ret_ptr = allocator.create(Type) catch break :blk t;
            ret_ptr.* = substParams(allocator, params, args, f.ret.*);
            if (!Type.eql(ret_ptr.*, f.ret.*)) changed = true;
            if (!changed) break :blk t;
            break :blk .{ .function = .{ .params = params_out, .ret = ret_ptr } };
        },
        .primitive, .module, .cleanup => t,
    };
}

/// The module a value refers to (air.md §7): a `module_ref` names its
/// module directly; a module-valued `load_member` names the member's
/// resolved module. The def chain is acyclic by SSA construction. A phi
/// over module values resolves only when every incoming names the same
/// module.
fn moduleIdentity(self: *const IrProgram, v: *const Value) ?*const IrModule {
    const def = v.def orelse return null;
    switch (def.op) {
        .module_ref => |spec| return moduleByName(self, spec),
        .load_member => |lm| {
            const parent = moduleIdentity(self, lm.module) orelse return null;
            const members = parent.members orelse return null;
            if (lm.member >= members.len) return null;
            switch (members[lm.member].kind) {
                .module_ref => |spec| return moduleByName(self, spec),
                else => return null,
            }
        },
        .phi => |p| {
            var resolved: ?*const IrModule = null;
            for (p.incoming) |inc| {
                const m = moduleIdentity(self, inc.value) orelse return null;
                if (resolved) |r| {
                    if (r != m) return null;
                } else {
                    resolved = m;
                }
            }
            return resolved;
        },
        else => return null,
    }
}

/// The module with a resolved specifier, or null when not loaded.
pub fn moduleByName(self: *const IrProgram, spec: []const u8) ?*const IrModule {
    for (self.modules) |m| {
        if (std.mem.eql(u8, m.name, spec)) return m;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Text form: lexer, parser, and canonical printer — implemented in
// src/passes/ (cfg_lex.zig, cfg_parse.zig, cfg_print.zig); re-exported
// here so `cfg.Parser`, `cfg.Diag`, and `cfg.print` keep working for
// tests, golden files, and the CLI (air.md §9).
// ---------------------------------------------------------------------------

pub const Diag = @import("passes/cfg_parse.zig").Diag;
pub const Parser = @import("passes/cfg_parse.zig").Parser;
// pi-lens-ignore: zls:unknown
pub const print = @import("passes/cfg_print.zig").print;
