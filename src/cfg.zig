//! CFG IR data structures — ir.md §11 (frontend Phase 3/4).
//!
//! `cfg` owns the in-memory control-flow-graph structures of ir.md §11 —
//! `IrProgram`, `IrModule`, `IrFunc`, `BasicBlock`, `Instr`, `Value`,
//! `Terminator` — the IR-native resolved `Type`, and the ownership/state
//! tags values carry. The two *algorithms* that act on these structures
//! live in `src/passes/` and are re-exported here so the public surface
//! (`cfg.Parser`, `cfg.print`) is unchanged:
//!
//! - `src/passes/cfg_parse.zig` — the `Parser` that turns the textual
//!   form of ir.md §9 into these structures;
//! - `src/passes/cfg_print.zig` — the canonical `print` back to text for
//!   IR dumps, tests, and golden files (round-trip contract, ir.md §13).
//!
//! Scope. The text form is *self-contained*: no dependency on the type
//! checker or the module graph. Where ir.md §11 names frontend artifacts,
//! this file substitutes IR-native equivalents so the parser stays
//! testable in isolation:
//!
//! - the checker's resolved-type annotation → `Type` (IR-native resolved
//!   type, §4.2);
//! - `checker.FuncInstance`, `ast.FuncDef` → omitted from `IrFunc` (the
//!   frontend lowering populates them when it builds the CFG from AST);
//! - `ModuleInfo` → module / member **names** (`module_ref`, syscall
//!   targets);
//! - `Call.callee.direct` → `DirectCallee { name, func }` — a direct
//!   reference may name a function defined later in the text, resolved by
//!   `resolveDirectCalls` after the whole program is parsed.
//!
//! Text format (ir.md §9). The format is line-oriented: one label,
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
//! - terminators are `ret`, `br`, `br_cond` (`br %c ? a : b`), `switch`,
//!   and `trap`;
//! - constant literals may appear inline where a value operand is expected
//!   (they are materialized as `const` instructions in memory);
//! - `#N` is a statically known index or union tag;
//! - syscall targets are `builtin#member` or `module#member`.

const std = @import("std");
const ast = @import("ast.zig");

/// Ownership classification of a value type (Core §10.1–§10.3).
/// `duplicable` values may be implicitly copied; `affine` values may be
/// used at most once and must be destroyed exactly once.
pub const Ownership = enum {
    duplicable,
    affine,
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// An IR-native resolved type (ir.md §4.2, §11). The IR text carries no
/// type declarations, so `named` types defer ownership to their
/// declaration, mirroring the checker's `null`-means-deferred convention.
pub const Type = union(enum) {
    primitive: ast.PrimitiveKind,
    /// A named struct or union reference, e.g. `File` or `os.File`.
    named: []const u8,
    /// The static module type of `module_ref` values (Core §2.3).
    module,
    list: *Type,
    box: *Type,
    tuple: []Type,
    function: FunctionType,
    /// The type of a cleanup token (ir.md §6.4): a compiler-only value
    /// that schedules the conditional destruction of a maybe-affine
    /// owner. Not a Core type — no source expression, parameter, or
    /// binding ever has this type; only `cleanup_owner` produces it and
    /// only `cleanup_disable` / `drop_cleanup` consume it. Classified
    /// duplicable so ordinary scope-end machinery never drops it.
    cleanup,

    /// Structural ownership (ir.md §6.1): primitives are duplicable except
    /// the top type `any` and the opaque payload type `hostdata`, which are
    /// affine (Core §11.6, §11.7); function values and module values are
    /// duplicable; containers join their components; cleanup tokens are
    /// scheduler-only values; named types defer (`null`).
    pub fn ownership(self: Type) ?Ownership {
        return switch (self) {
            .primitive => |k| if (k == .any or k == .hostdata) Ownership.affine else Ownership.duplicable,
            .module, .cleanup => Ownership.duplicable,
            .named => null,
            .list, .box => |inner| inner.ownership(),
            .tuple => |elems| blk: {
                var acc: ?Ownership = Ownership.duplicable;
                for (elems) |e| {
                    const ow = e.ownership() orelse break :blk null;
                    if (ow == .affine) acc = Ownership.affine;
                }
                break :blk acc;
            },
            .function => Ownership.duplicable,
        };
    }

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .primitive => |ka| switch (b) {
                .primitive => |kb| ka == kb,
                else => false,
            },
            .module => b == .module,
            .named => |na| switch (b) {
                .named => |nb| std.mem.eql(u8, na, nb),
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

/// One parameter: `[borrow|move] name: type` (ir.md §11). In function
/// *types* the name is empty.
pub const Param = struct {
    span: ast.Span,
    name: ast.Ident,
    mode: ast.ParamMode,
    type_: Type,
};

pub const FunctionType = struct {
    params: []Param,
    ret: *Type,
};

// ---------------------------------------------------------------------------
// CFG data structures (ir.md §11)
// ---------------------------------------------------------------------------

/// The *created* state of a value (ir.md §6.1): owned (the defining op
/// produces an owner) or borrowed (a non-owning view of some base). This
/// is a definition-time property of the value, fixed by its defining op.
/// Whether a value is still *available* at a program point — alive,
/// consumed, or consumed on some paths only — is not a value property:
/// it is an edge-sensitive dataflow property computed by the validator
/// (ir.md §13) and the lowering's consumption bookkeeping.
pub const ValueState = enum { owned, borrowed };

pub const ConstValue = union(enum) {
    int: i64, // int32 / uint32 payload; sign per type
    float: f32,
    bool: bool,
    string: []const u8,
    void,
};

/// One SSA value: the result of exactly one instruction (ir.md §4.1).
/// Parameter values have no defining instruction (`def == null`).
pub const Value = struct {
    /// SSA name — per function, in definition order (`%0..%k-1` params).
    id: u32,
    span: ast.Span,
    type_: Type,
    /// Ownership class from the type (duplicable / affine), `null` when
    /// deferred by a named type.
    ownership: ?Ownership,
    /// Created state (owned / borrowed); dead-marking is downstream.
    state: ValueState,
    /// The defining instruction, or null for parameters.
    def: ?*Instr,
};

/// One instruction: defines `results` (one value for single-result ops,
/// several for the atomic destructure ops `unpack_struct` / `unpack_tuple` /
/// `unpack_variant` / `split_list`, ir.md §5.3) unless it is a pure effect
/// (`drop`, `store_member`, `cleanup_disable`, `drop_cleanup`, or a
/// `void`/effect `call` / `syscall`).
///
/// `synth` marks constants materialized from inline literals in operand
/// position (ir.md §9): the printer re-inlines them so their ids never
/// leak into the text form.
pub const Instr = struct {
    span: ast.Span,
    results: []*Value,
    op: Op,
    synth: bool = false,
};

/// The 3-address op set of ir.md §5: at most two operands, except the
/// documented n-ary forms (`construct`, `call`, `syscall`, `phi`).
pub const Op = union(enum) {
    // constants, parameters, modules (§5.1)
    const_: ConstValue,
    arg: u32,
    module_ref: []const u8, // module specifier (ir.md §11: *const ModuleInfo)

    // function values (§5.5)
    fn_ref: []const u8, // qualified IrFunc name (a lambda or named function)

    // unary (§5.2)
    neg: *Value,
    not_: *Value,
    /// The Core §16.3 numeric conversions: `int32 as float32` and
    /// `float32 as int32` only. May trap: an out-of-range float traps at
    /// runtime (Runtime §7.2).
    num_cast: *Value,

    // typed recovery and top-type conversion (§5.2, §4.4)
    type_is: TypeIs,
    /// `T → any` of a duplicable source: copies the payload into the
    /// `any`; the source stays owned (Core §11.6).
    any_pack_copy: *Value,
    /// `T → any` of an affine source: moves the payload into the `any`;
    /// the source is consumed (Core §11.6).
    any_pack_move: *Value,
    /// `any as T` with a duplicable target: copies the payload out; the
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
    concat: Bin,
    eq: Bin,
    ne: Bin,
    lt: Bin,
    le: Bin,
    gt: Bin,
    ge: Bin,

    // ownership (§5.4)
    copy: *Value,
    borrow: *Value,
    move_: *Value,
    drop_: *Value, // effect; no result
    /// Creates a cleanup token scheduling `v`'s conditional destruction
    /// (ir.md §6.4). Produces a `Type.cleanup` value usable only by
    /// `cleanup_disable` and `drop_cleanup`.
    cleanup_owner: *Value,
    /// Disarms a cleanup token without destroying the payload: emitted on
    /// the paths where the owner was consumed (moved, taken, transferred).
    cleanup_disable: *Value, // effect; no result
    /// The scope-end conditional destruction: destroys the owner iff its
    /// token is still armed, then disarms it. Effect; no result.
    drop_cleanup: *Value,

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

    // calls (§8)
    call: Call, // n-ary
    syscall: SysCall, // n-ary

    // SSA (§4.3)
    phi: Phi, // n-ary
};

pub const Bin = struct { a: *Value, b: *Value };
pub const Proj = struct { base: *Value, index: u32 };
pub const Index = struct { base: *Value, index: *Value };
pub const UnpackVariant = struct { base: *Value, tag: u32 };

// ---------------------------------------------------------------------------
// Op schema (ir.md §5, §13) — the single machine-readable contract
// ---------------------------------------------------------------------------

/// Value-operand arity. `zero`/`one`/`two` are the 3-address forms; the
/// n-ary exceptions (`construct`, `call`, `syscall`, `phi`) are exactly
/// the ops with a statically typed, fixed-shape operand list (ir.md §4.2).
pub const Arity = enum { zero, one, two, nary };

/// Which value operands this op *consumes* (ir.md §6.2): the operand's
/// ownership transfers into the instruction (or the value is destroyed by
/// it) and the operand is dead afterwards. Ops whose consumption depends
/// on operand types or a callee signature (`call`, `syscall`, `construct`,
/// `arg`-mode parameters) declare `.none`; the validator resolves those
/// from the types/signature.
pub const Consumes = enum { none, op0, op1, both, all };

/// The created state of the result (ir.md §6.1); `.operand` means the
/// state derives from an operand (borrow-mode `arg`, projections of an
/// affine base), `.none` for pure effects.
pub const Created = enum { owned, borrowed, operand, none };

/// One row of the op schema: everything the validator, parser, printer,
/// and optimizer need to know about an op without hand-rolled switches.
/// `opInfo` is an exhaustive comptime switch over the `Op` tags, so the
/// schema is the single source of truth — a new op must be added here or
/// the compiler rejects the switch, and the text spelling the printer and
/// parser use comes from `OpInfo.text` alone.
pub const OpInfo = struct {
    /// Canonical text spelling (ir.md §9).
    text: []const u8,
    /// Value-operand count (the 3-address property, ir.md §4.2).
    arity: Arity,
    /// Ownership effect on the fixed operands.
    consumes: Consumes,
    /// Created state of the result.
    created: Created,
    /// May trap at runtime (Runtime §7.2): division/remainder by zero,
    /// integer overflow, negation of `minInt`, index bounds, invalid
    /// `any` recovery, and out-of-range float→int casts. An op that may
    /// trap must never be hoisted onto a path that could skip it (PRE).
    may_trap: bool,
    /// Has observable side effects beyond producing its result (calls,
    /// syscalls, drops, store_member, cleanup_disable): such ops are
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
        // constants, parameters, modules (§5.1)
        .const_ => .{ .text = "const", .arity = .zero, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .arg => .{ .text = "arg", .arity = .zero, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        .module_ref => .{ .text = "module_ref", .arity = .zero, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },

        // function values (§5.5)
        .fn_ref => .{ .text = "fn_ref", .arity = .zero, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },

        // unary (§5.2): `neg` of `minInt` traps; the other unary numeric
        // ops are total
        .neg => .{ .text = "neg", .arity = .one, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .not_ => .{ .text = "not", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .num_cast => .{ .text = "num_cast", .arity = .one, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },

        // typed recovery and top-type conversion (§5.2, §4.4)
        .type_is => .{ .text = "type_is", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .any_pack_copy => .{ .text = "any_pack_copy", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .any_pack_move => .{ .text = "any_pack_move", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false },
        .any_unpack_copy => .{ .text = "any_unpack_copy", .arity = .one, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .any_unpack_move => .{ .text = "any_unpack_move", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = true, .effects = false },

        // binary (§5.2): int add/sub/mul and div/rem trap on overflow /
        // by zero; comparisons and concat are total
        .add => .{ .text = "add", .arity = .two, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .sub => .{ .text = "sub", .arity = .two, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .mul => .{ .text = "mul", .arity = .two, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .div => .{ .text = "div", .arity = .two, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .rem => .{ .text = "rem", .arity = .two, .consumes = .none, .created = .owned, .may_trap = true, .effects = false },
        .concat => .{ .text = "concat", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .eq => .{ .text = "eq", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .ne => .{ .text = "ne", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .lt => .{ .text = "lt", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .le => .{ .text = "le", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .gt => .{ .text = "gt", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .ge => .{ .text = "ge", .arity = .two, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },

        // ownership (§5.4)
        .copy => .{ .text = "copy", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .borrow => .{ .text = "borrow", .arity = .one, .consumes = .none, .created = .borrowed, .may_trap = false, .effects = false },
        .move_ => .{ .text = "move", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false },
        .drop_ => .{ .text = "drop", .arity = .one, .consumes = .op0, .created = .none, .may_trap = false, .effects = true },
        .cleanup_owner => .{ .text = "cleanup_owner", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .cleanup_disable => .{ .text = "cleanup_disable", .arity = .one, .consumes = .none, .created = .none, .may_trap = false, .effects = true },
        .drop_cleanup => .{ .text = "drop_cleanup", .arity = .one, .consumes = .none, .created = .none, .may_trap = false, .effects = true },

        // memory (§5.6)
        .load_member => .{ .text = "load_member", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .store_member => .{ .text = "store_member", .arity = .one, .consumes = .op0, .created = .none, .may_trap = false, .effects = true },

        // aggregates and projections (§5.3)
        .construct => .{ .text = "construct", .arity = .nary, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .read_field => .{ .text = "read_field", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        .read_tuple => .{ .text = "read_tuple", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        .read_index => .{ .text = "read_index", .arity = .two, .consumes = .none, .created = .operand, .may_trap = true, .effects = false },
        // A `tail` view's created state follows the *base*'s ownership
        // (`.operand`): a duplicable list's view is a duplicable value,
        // an affine list's view is borrowed (matches read_*).
        .tail => .{ .text = "tail", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },
        // Atomic consuming destructures (§5.3): one op, base consumed as
        // a whole, all parts defined at once (multi-result).
        .unpack_struct => .{ .text = "unpack_struct", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false, .multi = true },
        .unpack_tuple => .{ .text = "unpack_tuple", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false, .multi = true },
        .unpack_variant => .{ .text = "unpack_variant", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = false, .effects = false, .multi = true },
        .split_list => .{ .text = "split_list", .arity = .one, .consumes = .op0, .created = .owned, .may_trap = true, .effects = false, .multi = true },
        .read_tag => .{ .text = "read_tag", .arity = .one, .consumes = .none, .created = .owned, .may_trap = false, .effects = false },
        .read_payload => .{ .text = "read_payload", .arity = .one, .consumes = .none, .created = .operand, .may_trap = false, .effects = false },

        // calls (§8)
        .call => .{ .text = "call", .arity = .nary, .consumes = .none, .created = .owned, .may_trap = true, .effects = true },
        .syscall => .{ .text = "syscall", .arity = .nary, .consumes = .none, .created = .owned, .may_trap = true, .effects = true },

        // SSA (§4.3)
        .phi => .{ .text = "phi", .arity = .nary, .consumes = .all, .created = .owned, .may_trap = false, .effects = false },
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

/// Structural equality of two computations (ir.md §5): same opcode, same
/// operands in the same position. No commutativity — floating-point and
/// NaN behavior must be unchanged. Shared by the construction-time CSE
/// (cfg_lower_emit.zig, braun13cc.pdf §3.1) and the partial redundancy
/// elimination pass (cfg_pre.zig), which match computations across
/// blocks.
pub fn identical(a: Op, b: Op) bool {
    return switch (a) {
        .neg => |x| b == .neg and x == b.neg,
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
        .concat => |x| b == .concat and eqBin(x, b.concat),
        .eq => |x| b == .eq and eqBin(x, b.eq),
        .ne => |x| b == .ne and eqBin(x, b.ne),
        .lt => |x| b == .lt and eqBin(x, b.lt),
        .le => |x| b == .le and eqBin(x, b.le),
        .gt => |x| b == .gt and eqBin(x, b.gt),
        .ge => |x| b == .ge and eqBin(x, b.ge),
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
    slot: u32,
};

pub const StoreMember = struct {
    slot: u32,
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
/// names of the standard `builtin` module (Core §3).
pub const BuiltinId = enum {
    print,
    str,
    len,
    range,
    map,
    fold,
    box,
    peek,
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
    ret: Type, // `never` for panicking bindings (Runtime §4.9)
};

pub const Phi = struct {
    /// One (incoming value, predecessor block) per in-edge, in the same
    /// order as `BasicBlock.preds`.
    incoming: []PhiIn,
};
pub const PhiIn = struct { value: *Value, pred: *BasicBlock };

pub const Terminator = union(enum) {
    ret: ?*Value,
    branch: *BasicBlock,
    branch_cond: struct { cond: *Value, then_: *BasicBlock, else_: *BasicBlock },
    @"switch": Switch,
    trap,
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
    /// In-edges, in phi order (ir.md §3, §4.3).
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
    /// the frontend lowering (ir.md §11 omits it — the text form has no
    /// module-qualified names, so the parser leaves it null).
    module_spec: ?[]const u8 = null,
};

/// A block-finalization diagnostic: the offending span and a pre-formatted
/// message (allocated from the caller's arena).
pub const FinalizeDiag = struct {
    span: ast.Span,
    message: []const u8,
};

/// Finalize a function's blocks (ir.md §3, §4.3): dupe each block's
/// instruction slice from the parallel builder list, compute predecessor
/// lists in edge order, check the entry block has no predecessors, and
/// validate every phi's incoming list against the block's in-edges.
///
/// When `phi_lists` is present, phi incoming lists are materialized from
/// the deferred builders first (the frontend lowering's pattern); the IR
/// text parser sets `phi.incoming` directly and passes `null`. On a
/// structural error returns a `FinalizeDiag`; otherwise `null`.
pub fn finalizeBlocks(
    allocator: std.mem.Allocator,
    blocks: []*BasicBlock,
    block_instrs: []const []const *Instr,
    phi_lists: ?*const std.AutoHashMapUnmanaged(*Instr, *std.ArrayListUnmanaged(PhiIn)),
) error{OutOfMemory}!?FinalizeDiag {
    for (blocks, 0..) |b, i| {
        b.instrs = try allocator.dupe(*Instr, block_instrs[i]);
    }
    // Predecessors in edge order (ir.md §3).
    var preds = std.ArrayListUnmanaged(std.ArrayListUnmanaged(*BasicBlock)).empty;
    for (blocks) |_| try preds.append(allocator, .empty);
    for (blocks) |b| {
        switch (b.terminator) {
            .ret, .trap => {},
            .branch => |tgt| try preds.items[tgt.id].append(allocator, b),
            .branch_cond => |bc| {
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
    // and check they match the block's in-edges, in order (ir.md §4.3).
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
        // Value-less blocks (bare `br` joins) keep creation order.
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

/// Renumber `f`'s values in the canonical print order (ir.md §4.1, §13):
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
            .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_owner, .cleanup_disable, .drop_cleanup, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload, .drop_ => |*v| {
                if (v.* == from) v.* = to;
            },
            .unpack_variant => |*uv| {
                if (uv.base == from) uv.base = to;
            },
            .type_is => |*x| {
                if (x.value == from) x.value = to;
            },
            .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => |*x| {
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
            .const_, .arg, .module_ref, .fn_ref => {},
        };
        switch (b.terminator) {
            .ret => |v| {
                if (v) |val| {
                    if (val == from) b.terminator.ret = to;
                }
            },
            .branch => {},
            .branch_cond => |*bc| {
                if (bc.cond == from) bc.cond = to;
            },
            .@"switch" => |*s| {
                if (s.disc == from) s.disc = to;
            },
            .trap => {},
        }
    }
}

pub const SlotMeta = struct {
    type_: Type,
    /// Rank in the module's declaration order (teardown destroys affine
    /// slots in reverse rank — Runtime §2.5).
    init_order: u32,
};

pub const IrModule = struct {
    span: ast.Span,
    /// Resolved specifier of the module.
    name: []const u8,
    /// The module init function (a `func @init`), when one is defined.
    init: ?*IrFunc,
    funcs: []*IrFunc,
    /// Module storage layout, derived from `@init`'s `store_member` ops
    /// (Runtime §2.2).
    slots: []SlotMeta,
};

pub const IrProgram = struct {
    modules: []*IrModule, // text order
    funcs: []*IrFunc, // all functions, in module order
    entry: ?*IrFunc, // host-selected entry, when present

    /// Resolve `Call.callee.direct` references (forward references in the
    /// text) against every parsed function. Same-module names win; the
    /// first definition of a duplicated name wins program-wide.
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
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Text form: lexer, parser, and canonical printer — implemented in
// src/passes/ (cfg_lex.zig, cfg_parse.zig, cfg_print.zig); re-exported
// here so `cfg.Parser`, `cfg.Diag`, and `cfg.print` keep working for
// tests, golden files, and the CLI (ir.md §9).
// ---------------------------------------------------------------------------

pub const Diag = @import("passes/cfg_parse.zig").Diag;
pub const Parser = @import("passes/cfg_parse.zig").Parser;
pub const print = @import("passes/cfg_print.zig").print;
