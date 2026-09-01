//! Pass: the typed lowering layer (Layer A of the CFG → LLIR
//! boundary). The current emitter reads a value's type only long
//! enough to pick an opcode and write its canonicalization records,
//! then discards it; the record stream that survives carries no type,
//! no bit-width, and no notion of a value's top-bits state. This
//! module is the replacement boundary: a value carries its `cfg.Type`
//! plus a small *value-form* (the top-bits state), and an arithmetic /
//! comparison / cast choice stays one typed SSA node until the
//! expander turns it into the widthless record stream.
//!
//! The value-form lattice (docs/frontend.md §Value forms;
//! docs/optimizer.md §CFG → LLIR boundary) is the single source of truth
//! for the pseudo-stage eliminator (B.0) and the expander's residual
//! elimination (B.1): three monotone states describing what the top 32
//! bits of a value's 64-bit canonical cell are known to be.
//!
//! Landed behind the existing emitter (no behavior change). The
//! pipeline still writes records directly; this module computes the
//! forms the overhaul's eliminator will consume.

const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const ast = @import("stilla").ast;

/// The value-form (top-bits) state of a value's 64-bit canonical cell.
pub const Form = enum {
    /// The top 32 bits equal bit 31 (a canonical signed-32 cell).
    sign_extended,
    /// The top 32 bits are all zero (a canonical unsigned-32 cell).
    zero_extended,
    /// Anything else, or a join whose inputs disagree.
    unknown,
};

/// Lattice meet at a join (phi / select / a call's agreed inputs).
/// Two different known states collapse to unknown; the identity on
/// unknown keeps a partially-known join at unknown (sound: a join is
/// precise only when *every* incoming value carries the same form).
pub fn meet(a: Form, b: Form) Form {
    if (a == b) return a;
    return .unknown;
}

/// A typed lowering op (Layer A): one arithmetic / comparison / cast
/// choice, still atomic (not its expanded record sequence). `type_` is
/// the operand type; `result_type` is the result type (only meaningful
/// for a cast, where the CFG's `num_cast` target differs from the
/// operand type). `b` is null for the unary arithmetic ops.
pub const TypedOp = struct {
    kind: llir.TypedKind,
    type_: cfg.Type,
    result_type: cfg.Type,
    a: *const cfg.Value,
    b: ?*const cfg.Value,
    result: *const cfg.Value,
};

/// The rep suffix of an arithmetic primitive type, or null for a
/// non-arithmetic type (the typed layer only carries arithmetic ops).
fn repName(t: cfg.Type) ?[]const u8 {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32 => "i32",
            .uint32 => "u32",
            .int64 => "i64",
            .uint64 => "u64",
            .float32 => "f32",
            .float64 => "f64",
            else => null,
        },
        else => null,
    };
}

/// The typed-layer spelling of a kind (the widthless integer family
/// names, the signed/unsigned compare names, and the cast family).
fn kindName(kind: llir.TypedKind) []const u8 {
    return switch (kind) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .rem => "rem",
        .shl => "shl",
        .shr => "shr",
        .bitand => "and",
        .bitor => "or",
        .bitxor => "xor",
        .eq => "eq",
        .ne => "ne",
        .lt => "lt",
        .le => "le",
        .gt => "gt",
        .ge => "ge",
        .neg => "neg",
        .cast => "cvt",
        .abs => "abs",
        .min => "min",
        .max => "max",
        .clz => "clz",
        .popcount => "popcount",
    };
}

/// Build the Layer A typed-op list for one function: the arithmetic,
/// comparison, and cast instructions, each as one atomic typed node
/// (not its expanded record sequence). Non-arithmetic instructions are
/// skipped — they are not part of the typed lowering boundary.
pub fn typedOps(allocator: std.mem.Allocator, func: *const cfg.IrFunc) error{OutOfMemory}![]TypedOp {
    var out = std.ArrayList(TypedOp).empty;
    for (func.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (ins.results.len == 0) continue;
            const kind: llir.TypedKind = switch (llir.lower(std.meta.activeTag(ins.op))) {
                .typed => |k| k,
                else => continue, // not an arithmetic/cmp/cast op
            };
            const result = ins.results[0];
            const a: *const cfg.Value = switch (ins.op) {
                .neg, .abs, .clz, .popcount, .num_cast => |v| v,
                .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .eq, .ne, .lt, .le, .gt, .ge => |bin| bin.a,
                else => unreachable,
            };
            const b: ?*const cfg.Value = switch (ins.op) {
                .neg, .abs, .clz, .popcount, .num_cast => null,
                .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .eq, .ne, .lt, .le, .gt, .ge => |bin| bin.b,
                else => unreachable,
            };
            try out.append(allocator, .{
                .kind = kind,
                .type_ = a.type_,
                .result_type = result.type_,
                .a = a,
                .b = b,
                .result = result,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Print one function's typed layer: one `%d: <type> = <op> <a>, <b>`
/// line per arithmetic/cmp/cast instruction. The op spelling carries the
/// type rep (`add.i32`, `cvt.i32.u32`), the typed form the widthless
/// opcode stream is expanded from. This is the typed-assembly printer:
/// it renders what Layer A sees, before the widthless expansion.
pub fn printTyped(allocator: std.mem.Allocator, func: *const cfg.IrFunc) error{OutOfMemory}![]u8 {
    const ops = try typedOps(allocator, func);
    defer allocator.free(ops);
    var out = std.ArrayList(u8).empty;
    for (ops) |op| {
        const srep = repName(op.type_) orelse "?";
        const drep = repName(op.result_type) orelse "?";
        const name = if (op.kind == .cast)
            try std.fmt.allocPrint(allocator, "cvt.{s}.{s}", .{ srep, drep })
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ kindName(op.kind), srep });
        defer allocator.free(name);
        var buf: [128]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "%{d}: {s} = {s} %{d}", .{ op.result.id, drep, name, op.a.id }) catch unreachable;
        try out.appendSlice(allocator, head);
        if (op.b) |b| {
            const tail = std.fmt.bufPrint(&buf, ", %{d}", .{b.id}) catch unreachable;
            try out.appendSlice(allocator, tail);
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// The form of a constant's stored cell: all-zero top bits →
/// zero-extended, all-one top bits → sign-extended, else unknown.
/// Matches the §4 rule "constants in [0, 2^32) → zero_extended" plus
/// the negative signed-32 constants, whose canonical cell is
/// sign-extended.
pub fn constForm(bits: i64) Form {
    const cell: u64 = @bitCast(bits);
    const top: u64 = cell >> 32;
    if (top == 0) return .zero_extended;
    if (top == 0xffff_ffff) return .sign_extended;
    return .unknown;
}

/// The `typed` lowering kind of a CFG op tag, or null for a tag that
/// lowers to a direct opcode or a composite (not part of the typed
/// arithmetic / comparison / cast layer). Centralizes the tag → kind
/// mapping for both the expander and the budget.
pub fn typedKindOf(tag: cfg.OpTag) ?llir.TypedKind {
    return switch (llir.lower(tag)) {
        .typed => |k| k,
        else => null,
    };
}

/// The §4 record-sequence length of one typed arithmetic op on operand
/// type `t`: the opcode plus the 32-bit canonicalization records the
/// expander emits (the widthless ops compute at 64 bits; 32-bit operand
/// types add `sext32`, the mod-32 shift-count mask, and `zext32` input
/// staging). The expander writes exactly this many records, and the
/// budget reads this length — the two stay in lockstep by construction.
/// This is the max-bound the budget derives from (it is exact for the
/// no-elimination emission; B.0 may later shorten it, and the budget
/// simply over-reserves).
pub fn arithSeqLen(kind: llir.TypedKind, t: cfg.Type) u32 {
    const sz = t == .primitive and (t.primitive == .int32 or t.primitive == .uint32);
    if (!sz) return 1;
    return switch (kind) {
        .add, .sub, .mul, .neg => 2,
        .bitand, .bitor, .bitxor => 1,
        .min, .max => if (t.primitive == .uint32) 4 else 1,
        .div, .rem => if (t.primitive == .uint32) 4 else if (kind == .div) 2 else 1,
        .shl => 3,
        .shr => if (t.primitive == .uint32) 4 else 2,
        else => 1,
    };
}

/// The B.0 extension-identity rules that make a `sext32` / `zext32`
/// record redundant, keyed on the operand's value-form
/// (docs/optimizer.md §CFG → LLIR boundary):
///
/// - `sext32 x` where `x.form == .sign_extended` → identity (drop).
/// - `zext32 x` where `x.form == .zero_extended` → identity (drop).
/// - `sext32 x` where `x.form == .zero_extended`, or `zext32 x` where
///   `x.form == .sign_extended` → **not** removable (bit-31 may be set /
///   re-sign-extend is required).
pub fn sextIsIdentity(form: Form) bool {
    return form == .sign_extended;
}

pub fn zextIsIdentity(form: Form) bool {
    return form == .zero_extended;
}

/// Whether the expander (B.1) may elide the **leading** `zext32` staging
/// record of an unsigned 32-bit binary op because the signed operand cell
/// is already zero-extended (its value-form is `.zero_extended`). This is
/// the single-op residual fall-out of the `zext32`-identity rule: without
/// the elision, the unsigned `div`/`rem`/`min`/`max`/`shr` sequence
/// re-zero-extends an already-zero cell. When the operand form is
/// `unknown` or `sign_extended`, the record stays.
pub fn elideLeadingZext(kind: llir.TypedKind, t: cfg.Type, form_a: Form) bool {
    if (form_a != .zero_extended) return false;
    if (!(t == .primitive and t.primitive == .uint32)) return false;
    return switch (kind) {
        .div, .rem, .min, .max, .shr => true,
        else => false,
    };
}

/// The fused immediate for a numeric constant at operand type `t`, or null
/// when the constant does not fit the 7-bit immediate window or the type has
/// no immediate form. Mirrors `llir_fusion.immOf` (now centralized here): the
/// arithmetic/comparison forms sign-extend on `i32`/`i64` and zero-extend on
/// `u32`/`u64`; the shift/mask forms always zero-extend; floats never fuse.
pub fn immOf(cv: cfg.ConstValue, kind: llir.TypedKind, t: cfg.Type) ?u8 {
    if (kind == .ge) return switch (cv) {
        .int => |i| if (i == std.math.minInt(i64)) null else immOf(.{ .int = i - 1 }, .gt, t),
        else => null,
    };
    return switch (cv) {
        .int => |i| switch (t) {
            .primitive => |k| switch (k) {
                .int32, .int64 => blk: {
                    if (kind == .shl or kind == .shr or kind == .bitand or kind == .bitor or kind == .bitxor) {
                        if (i < 0 or i > 127) break :blk null;
                        break :blk @intCast(i);
                    }
                    if (i < -64 or i > 63) break :blk null;
                    break :blk @intCast(@as(u8, @bitCast(@as(i8, @intCast(i)))) & 0x7f);
                },
                .uint32, .uint64, .byte => blk: {
                    if (i < 0 or i > 127) break :blk null;
                    break :blk @intCast(i);
                },
                else => null,
            },
            else => null,
        },
        .float => null,
        else => null,
    };
}

/// The fused shift count on a 32-bit type: the widthless shift masks the
/// count mod 64, but the 32-bit types demand mod 32 (Instruction Set §4, §10).
pub fn shiftImm(op: llir.Opcode, t: cfg.Type, imm: u8) u8 {
    if (op != .shli and op != .shri and op != .shriu) return imm;
    if (t == .primitive and (t.primitive == .int32 or t.primitive == .uint32)) return @intCast(imm % 32);
    return imm;
}

/// A fuse-eligible constant's immediate form: the immediate opcode and the
/// (possibly shift-masked) immediate field.
pub const FusedImm = struct {
    op: llir.Opcode,
    imm: u8,
};

/// The fused immediate for a **right** constant operand (`bin.b`) of a typed
/// arithmetic op, or null when the constant does not qualify (no immediate
/// form for the kind/type, or the value does not fit the 7-bit window).
/// Shared by the expander (emits the immediate form and omits the constant's
/// staging records) and the budget (derives the reduced record count), so the
/// two agree by construction.
pub fn fusedImmR(kind: llir.TypedKind, t: cfg.Type, cv: cfg.ConstValue) ?FusedImm {
    const op = llir.typedOpcodeImm(kind, t) orelse return null;
    const raw = immOf(cv, kind, t) orelse return null;
    return .{ .op = op, .imm = shiftImm(op, t, raw) };
}

/// The constant payload of a value whose defining instruction is a `const_`,
/// or null for every other value.
pub fn constOf(v: *const cfg.Value) ?cfg.ConstValue {
    const d = v.def orelse return null;
    return switch (d.op) {
        .const_ => |cv| cv,
        else => null,
    };
}

fn is32(t: cfg.Type) bool {
    return t == .primitive and (t.primitive == .int32 or t.primitive == .uint32);
}

fn formOf(forms: []const Form, v: *const cfg.Value) Form {
    return if (v.id < forms.len) forms[v.id] else .unknown;
}

/// The producer rule "known when `cond` holds, unknown otherwise" —
/// keeps the runtime `if` from hitting Zig's comptime-only enum-literal
/// inference by passing the chosen form as a typed `Form` value.
fn pick(known: Form, cond: bool) Form {
    return if (cond) known else .unknown;
}

/// Whether `v` is an integer constant whose stored cell has all-zero top
/// 32 bits — a mask that, used as a `bitand` operand, clears the result's
/// top half (the CFG form of the LLIR mod-32/canonical `andi`).
fn maskClearsTop(v: *const cfg.Value) bool {
    const d = v.def orelse return false;
    return switch (d.op) {
        .const_ => |cv| switch (cv) {
            .int => |i| (@as(u64, @bitCast(i)) >> 32) == 0,
            else => false,
        },
        else => false,
    };
}

/// A constant's form: `unknown` for a non-32-bit result, the cell form
/// otherwise.
fn constDef(forms: []const Form, cv: cfg.ConstValue, t: cfg.Type) Form {
    _ = forms;
    if (!is32(t)) return .unknown;
    const r: Form = switch (cv) {
        .int => |i| constForm(i),
        else => .unknown,
    };
    return r;
}

/// A shift's form: u32 shifts canonicalize (sign-extended); signed i32
/// shifts are canonical only when the operand cell is canonical.
fn shrDef(forms: []const Form, bin: cfg.Bin, t: cfg.Type) Form {
    if (!is32(t)) return .unknown;
    if (t.primitive == .uint32) return .sign_extended;
    return if (formOf(forms, bin.a) != .unknown) .sign_extended else .unknown;
}

/// A phi's form: the meet of its incoming values.
fn phiDef(forms: []const Form, p: cfg.Phi) Form {
    var f: Form = .unknown;
    var first = true;
    for (p.incoming) |inc| {
        const inc_form = formOf(forms, inc.value);
        if (first) {
            f = inc_form;
            first = false;
        } else {
            f = meet(f, inc_form);
        }
        if (f == .unknown) break;
    }
    return f;
}

/// The §4 producer classification for one value's defining
/// instruction, reading operand forms for the operand-form-dependent
/// cases (arithmetic `shr.i32`). `forms` is the running lattice indexed
/// by value id. Conservative: any producer the plan does not name as a
/// known-form producer returns `unknown`, which is sound in both
/// directions (it only ever keeps an extension the eliminator might
/// otherwise drop — never one it must keep).
fn classifyDef(ins: *const cfg.Instr, forms: []const Form) Form {
    if (ins.results.len == 0) return .unknown;
    const res = ins.results[0];
    const t = res.type_;
    const sz = is32(t);
    const r: Form = switch (ins.op) {
        .const_ => |cv| constDef(forms, cv, t),
        // The widthless integer ops compute at 64 bits; the 32-bit
        // operand types emit the trailing `sext32` canonicalization, so
        // every result is a canonical sign-extended cell (§4).
        .add, .sub, .mul, .neg, .div, .rem, .shl => pick(.sign_extended, sz),
        // `shr` sign-fills for i32 (canonical after an arithmetic shift
        // of a canonical cell) and zero-fills for u32 (whose trailing
        // `sext32` canonicalizes the result). The i32 case is only
        // known when the operand is a canonical cell.
        .shr => |bin| shrDef(forms, bin, t),
        // `abs.i32` self-canonicalizes in its single record (§4).
        .abs => pick(.sign_extended, t == .primitive and t.primitive == .int32),
        // A cast into `int32`/`uint32` writes an `extendInt32Bits`-canonical
        // cell (the C-type casts sign-extend the low bits into the top
        // half), so the result is sign_extended — not zero_extended, which
        // would let an unsigned op elide its leading `zext32` unsoundly
        // when bit 31 of the cast result is set.
        .num_cast => pick(.sign_extended, is32(t)),
        // Bitwise `or`/`xor` preserve the operand extension bit-for-bit
        // (§4) and are not statement of the top-bits state. An `and` with
        // a mask constant whose top half is zero clears the top 32 bits —
        // the "andi-provenance" case — so the result is zero-extended.
        .bitand => |bin| if (sz and (maskClearsTop(bin.a) or maskClearsTop(bin.b))) .zero_extended else .unknown,
        .bitor, .bitxor => .unknown,
        // A plain copy / move / borrow transfers the value bit-for-bit, so
        // the form is preserved (sound: the top-bits state is unchanged).
        .copy, .move_, .borrow => |v| formOf(forms, v),
        // A select is the join of its two non-cond operands.
        .select => |s| meet(formOf(forms, s.a), formOf(forms, s.b)),
        // A phi is the join of all its incoming values.
        .phi => |*p| phiDef(forms, p.*),
        // Everything else (params have no def; calls, syscalls, loads,
        // projections, lifetime ops) is unknown: sound, and never claims
        // an extension state the producer did not promise.
        else => .unknown,
    };
    return r;
}

/// Compute the value-form lattice for one function: a forward dataflow
/// over its blocks (in `BlockOrder`), iterated to a fixpoint. Every
/// value starts `unknown`; the producer rules refine it upward, and the
/// joins (`phi`/`select`) meet their incoming forms. The iteration
/// terminates because each value transitions at most once from
/// `unknown` to a known state (a join can only become precise once all
/// its inputs are known, never the reverse). Returns a slice parallel to
/// `func.values`, indexed by value id.
pub fn compute(allocator: std.mem.Allocator, func: *const cfg.IrFunc) error{OutOfMemory}![]Form {
    const forms = try allocator.alloc(Form, func.values.len);
    @memset(forms, .unknown);
    var changed = true;
    while (changed) {
        changed = false;
        for (func.blocks) |blk| {
            for (blk.instrs) |ins| {
                if (ins.results.len == 0) continue;
                const want = classifyDef(ins, forms);
                if (want == .unknown) continue;
                for (ins.results) |res| {
                    if (res.id < forms.len and forms[res.id] != want) {
                        forms[res.id] = want;
                        changed = true;
                    }
                }
            }
        }
    }
    return forms;
}

test "lattice meet collapses distinct knowns to unknown" {
    try std.testing.expectEqual(Form.sign_extended, meet(.sign_extended, .sign_extended));
    try std.testing.expectEqual(Form.zero_extended, meet(.zero_extended, .zero_extended));
    try std.testing.expectEqual(Form.unknown, meet(.sign_extended, .zero_extended));
    try std.testing.expectEqual(Form.unknown, meet(.sign_extended, .unknown));
    try std.testing.expectEqual(Form.unknown, meet(.unknown, .zero_extended));
}

test "lattice const cell classification" {
    // Positive small constants have a zero top half.
    try std.testing.expectEqual(Form.zero_extended, constForm(0));
    try std.testing.expectEqual(Form.zero_extended, constForm(5));
    // A u32 all-ones stored as a positive value: zero-extended.
    try std.testing.expectEqual(Form.zero_extended, constForm(0xffff_ffff));
    // A signed -1 stored sign-extended: sign-extended.
    try std.testing.expectEqual(Form.sign_extended, constForm(-1));
    try std.testing.expectEqual(Form.sign_extended, constForm(std.math.minInt(i32)));
    // A 64-bit value whose top half is neither: unknown.
    try std.testing.expectEqual(Form.unknown, constForm(0x0000_0001_0000_0000));
}

fn mkValue(id: u32, t: cfg.Type) cfg.Value {
    return .{
        .id = id,
        .span = .{ .source = 0, .start = 0, .end = 0 },
        .type_ = t,
        .ownership = null,
        .state = .owned,
        .origin = null,
        .def = null,
    };
}

test "lattice producer classification" {
    const ti32 = cfg.Type{ .primitive = .int32 };
    const tu32 = cfg.Type{ .primitive = .uint32 };

    // `const_` (u32, all-ones): zero-extended; `const_` (i32, -1): sign-extended.
    var cu = mkValue(0, tu32);
    var cu2 = mkValue(1, tu32);
    var cs = mkValue(2, ti32);
    var rk = [_]*cfg.Value{&cu};
    const konst = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rk[0..], .op = .{ .const_ = .{ .int = 0xffff_ffff } } };
    try std.testing.expectEqual(Form.zero_extended, classifyDef(&konst, &.{ .unknown, .unknown, .unknown }));
    var rn = [_]*cfg.Value{&cs};
    const kneg = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rn[0..], .op = .{ .const_ = .{ .int = -1 } } };
    try std.testing.expectEqual(Form.sign_extended, classifyDef(&kneg, &.{ .unknown, .unknown, .unknown }));

    // 32-bit add/sub/mul/neg/div/rem/shl results are sign-extended cells.
    var addres = mkValue(3, ti32);
    var ra = [_]*cfg.Value{&addres};
    const add = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = ra[0..], .op = .{ .add = .{ .a = &cu, .b = &cu2 } } };
    try std.testing.expectEqual(Form.sign_extended, classifyDef(&add, &.{ .unknown, .unknown, .unknown }));

    // A cast to u32 writes an extendInt32Bits-canonical (sign-extended)
    // cell.
    var castres = mkValue(4, tu32);
    var rc = [_]*cfg.Value{&castres};
    const cast = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rc[0..], .op = .{ .num_cast = &cu } };
    try std.testing.expectEqual(Form.sign_extended, classifyDef(&cast, &.{ .unknown, .unknown, .unknown }));

    // `shr.i32` of a canonical cell is sign-extended; of an unknown cell unknown.
    var shrres = mkValue(5, ti32);
    var rs = [_]*cfg.Value{&shrres};
    const shr_known = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rs[0..], .op = .{ .shr = .{ .a = &cu, .b = &cu2 } } };
    try std.testing.expectEqual(Form.sign_extended, classifyDef(&shr_known, &.{ .sign_extended, .zero_extended, .unknown }));
    try std.testing.expectEqual(Form.unknown, classifyDef(&shr_known, &.{ .unknown, .zero_extended, .unknown }));

    // `select` joins its two non-cond operands.
    var selres = mkValue(6, ti32);
    var rsel = [_]*cfg.Value{&selres};
    const sel = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rsel[0..], .op = .{ .select = .{ .cond = &cu, .a = &cu, .b = &cu2 } } };
    try std.testing.expectEqual(Form.unknown, classifyDef(&sel, &.{ .sign_extended, .unknown, .sign_extended }));
    var rsel2 = [_]*cfg.Value{&selres};
    const sel_same = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rsel2[0..], .op = .{ .select = .{ .cond = &cu, .a = &cu, .b = &cs } } };
    try std.testing.expectEqual(Form.sign_extended, classifyDef(&sel_same, &.{ .sign_extended, .unknown, .sign_extended }));

    // A non-arithmetic producer (bitand) is unknown.
    var bandres = mkValue(7, ti32);
    var rb = [_]*cfg.Value{&bandres};
    const band = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rb[0..], .op = .{ .bitand = .{ .a = &cu, .b = &cs } } };
    try std.testing.expectEqual(Form.unknown, classifyDef(&band, &.{ .unknown, .unknown, .unknown }));

    // "andi-provenance": a `bitand` with a low mask constant clears the
    // top 32 bits, so the result is zero-extended.
    var maskval = mkValue(30, tu32);
    var rmask = [_]*cfg.Value{&maskval};
    var maskdef = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rmask[0..], .op = .{ .const_ = .{ .int = 0xffff } } };
    maskval.def = &maskdef;
    var andres = mkValue(31, tu32);
    var rand = [_]*cfg.Value{&andres};
    const bmask = cfg.Instr{ .span = std.mem.zeroes(ast.Span), .results = rand[0..], .op = .{ .bitand = .{ .a = &cu, .b = &maskval } } };
    try std.testing.expectEqual(Form.zero_extended, classifyDef(&bmask, &.{ .unknown, .unknown, .unknown }));

    // A parameter (no def) is unknown: `classifyDef` is only called on defs,
    // so the lookup form for an unclassified id defaults to unknown.
    try std.testing.expectEqual(Form.unknown, formOf(&.{ .unknown, .unknown, .unknown }, &mkValue(99, ti32)));
}

test "B.0 extension-identity rules" {
    // `sext32` of a sign-extended value, `zext32` of a zero-extended one:
    // identity.
    try std.testing.expect(sextIsIdentity(.sign_extended));
    try std.testing.expect(!sextIsIdentity(.zero_extended));
    try std.testing.expect(!sextIsIdentity(.unknown));
    try std.testing.expect(zextIsIdentity(.zero_extended));
    try std.testing.expect(!zextIsIdentity(.sign_extended));
    try std.testing.expect(!zextIsIdentity(.unknown));
}

test "B.0 elides the leading zext32 of an unsigned 32-bit op when the operand is already zero-extended" {
    const tu32 = cfg.Type{ .primitive = .uint32 };
    const ti32 = cfg.Type{ .primitive = .int32 };

    // An unsigned div/rem/min/max/shr on a zero-extended operand: the
    // leading `zext32` staging record is redundant.
    for ([_]llir.TypedKind{ .div, .rem, .min, .max, .shr }) |kind| {
        try std.testing.expect(elideLeadingZext(kind, tu32, .zero_extended));
    }
    // Same ops on an unknown / sign-extended operand (or a signed type):
    // the record stays.
    for ([_]llir.TypedKind{ .div, .rem, .min, .max, .shr }) |kind| {
        try std.testing.expect(!elideLeadingZext(kind, tu32, .unknown));
        try std.testing.expect(!elideLeadingZext(kind, tu32, .sign_extended));
        try std.testing.expect(!elideLeadingZext(kind, ti32, .zero_extended));
    }
    // The widthless/masking ops never elide a leading zext.
    try std.testing.expect(!elideLeadingZext(.add, tu32, .zero_extended));
    try std.testing.expect(!elideLeadingZext(.shl, tu32, .zero_extended));
}
