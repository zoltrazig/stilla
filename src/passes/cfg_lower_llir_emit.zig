//! Pass: CFG → LLIR body emission (distinct from the CFG → AIR
//! `cfg_lower_emit.zig`). In: the `Builder` after slot
//! allocation, lifecycle planning, budgeting, and interning (value
//! slots, the trailing release records, the pre-sized block-local
//! record lists, and the side tables fixed). Out: one record per
//! non-phi instruction at its block-local index — the ID-operand
//! records, the type-specialized arithmetic/comparison/cast records,
//! the branchless select, the call/syscall records with their
//! `slot_*` preparation, the ownership slot ops, the residual drops
//! plus the lifecycle trailing releases, and the aggregate
//! construct/destructure records with their descriptors. The
//! instruction families share the same record walk (every stage
//! advances `blk.instrs` by `budget.recordCount` so sized and
//! emitted records agree), the same slot lookup, and the same budget
//! contract, so they stay in one pass (Stilla LLIR Specification
//! §1). Target-bearing records carry placeholder offsets — no PC
//! exists until linearization.

const std = @import("std");
const cfg = @import("stilla").cfg;
const ast = @import("stilla").ast;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");
const lifecycle = @import("cfg_lower_lifecycle.zig");
const budget = @import("cfg_lower_llir_budget.zig");
const intern = @import("cfg_lower_llir_intern.zig");
const edges = @import("cfg_lower_llir_edges.zig");
const typed = @import("cfg_lower_typed.zig");

const Builder = lower.Builder;

/// Emit every instruction family in the driver's fixed order: the
/// ID-operand records first, then the type-specialized arithmetic,
/// comparisons/casts, the select composite, calls/syscalls,
/// ownership ops, drops (with the lifecycle trailing releases), and
/// the aggregates. Each stage walks `blk.instrs` with the block-local
/// record index and advances by `budget.recordCount`, so the record
/// placement is identical to the budget's pre-sizing by construction.
pub fn run(bld: *Builder) error{ OutOfMemory, SyscallWithoutSignature }!void {
    try emitInterned(bld);
    try emitArith(bld);
    try emitCompare(bld);
    try emitSelect(bld);
    try emitCalls(bld);
    try emitOwnership(bld);
    try emitDrops(bld);
    try emitAggregates(bld);
}

/// Emit the records of the ID-operand slow-path ops with
/// integer references — `const` (ConstId), `fn_ref` (FunctionId),
/// `module_ref` (ModuleId), `type_is` (TypeId), `load_member`
/// (MemberId), `store_member` (SlotId). The
/// remaining record kinds come from their own stages. One record per
/// non-phi instruction at block-local index = the instruction's
/// non-phi ordinal; re-running after a later size revision re-emits
/// the same records (interning is idempotent).
fn emitInterned(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .const_ => |cv| {
                        // A void-typed result (hand-written AIR; the
                        // real frontend's `emitVoid` phantom has no
                        // value-table entry) writes `zero` — the
                        // singleton's value is discarded, never a slot
                        // row.
                        const void_result = ins.results.len > 0 and ins.results[0].type_ == .primitive and ins.results[0].type_.primitive == .void;
                        const dst = if (ins.results.len > 0 and !void_result) bld.slotOf(ins.results[0]) else llir.zero_reg;
                        if (budget.isMoveWideConst(bld, ins)) {
                            // A `u64` constant materializes
                            // through the move-wide sequence
                            // and writes no
                            // `ConstRecord` row; i64/f64 and every
                            // other constant keep the typed `const`
                            // path.
                            const plan = budget.u64ConstPlan(@bitCast(cv.int));
                            bld.setI(blk, idx, plan.init_op, dst, plan.init_imm);
                            var k: u32 = 1;
                            for (plan.wks) |wk| {
                                if (wk) |w| {
                                    bld.setI(blk, idx + k, budget.movwOp(.movwk0, w.n), dst, w.imm);
                                    k += 1;
                                }
                            }
                        } else {
                            bld.setI(blk, idx, .const_, dst, try intern.internConst(bld, cv, ins.results[0].type_));
                        }
                    },
                    .fn_ref => |name| {
                        // A scope-local function lowers to `fn_ref` — the
                        // runtime materializes the executable entry PC
                        // from the local `FunctionId`. Any other name
                        // (a cross-module function value, including a
                        // lowered generic specialization) lowers to the
                        // symbolic import path: `module_ref` (load and
                        // initialize the target module) plus
                        // `load_member` (the function's VM pc) through
                        // the staging T register.
                        if (bld.func_name_ids.get(name)) |local_fi| {
                            bld.setI(blk, idx, .fn_ref, bld.slotOf(ins.results[0]), local_fi);
                        } else {
                            const q = Builder.splitQualName(name) orelse unreachable;
                            const mod_sym = try bld.internSymbol(q.module);
                            const imp = try bld.importIndex(q.module, q.member);
                            const desc = try intern.internMemberDesc(bld, .{ .module = {} }, ins.results[0].type_, imp);
                            bld.setI(blk, idx, .module_ref, norm_stage, mod_sym);
                            bld.setR(blk, idx + 1, .load_member, bld.slotOf(ins.results[0]), norm_stage, desc);
                        }
                    },
                    // v10+: the operand is the module's `SymbolId` — the
                    // module's own symbol or an imported module's; the
                    // runtime loads and initializes the target before the
                    // record writes the module handle.
                    .module_ref => |spec| bld.setI(blk, idx, .module_ref, bld.slotOf(ins.results[0]), try bld.internSymbol(spec)),
                    .type_is => |ti| bld.setR(blk, idx, .type_is, bld.slotOf(ins.results[0]), bld.slotOf(ti.value), try intern.internType(bld, ti.type_)),
                    // v1: member accesses reference a
                    // MemberDesc row carrying the base/result TypeIds
                    // and the reference — a module-local slot/field
                    // index, or an `ImportDesc` index for the symbolic
                    // `load_member` (the `(module_symbol, member_symbol)`
                    // pair, resolved statically through the base value's
                    // module identity).
                    .load_member => |lm| {
                        const target = bld.program.moduleOf(lm.module) orelse unreachable;
                        // Resolve the member's name: the module's member
                        // table, or (text-form AIR has none) the module's
                        // function at that position as a lowering-test
                        // convenience — the import is a lowering artifact.
                        const member_name: []const u8 = if (target.members) |mems|
                            mems[lm.member].name
                        else if (lm.member < target.funcs.len)
                            target.funcs[lm.member].name.text
                        else
                            "?";
                        const imp = try bld.importIndex(target.name, member_name);
                        const desc = try intern.internMemberDesc(bld, .{ .module = {} }, ins.results[0].type_, imp);
                        bld.setR(blk, idx, .load_member, bld.slotOf(ins.results[0]), bld.slotOf(lm.module), desc);
                    },
                    .store_member => |sm| {
                        const desc = try intern.internMemberDesc(bld, null, sm.value.type_, sm.slot);
                        bld.setI(blk, idx, .store_member, bld.slotOf(sm.value), desc);
                    },
                    .read_field, .read_tuple => |pr| {
                        const tag2 = std.meta.activeTag(ins.op);
                        const op: llir.Opcode = if (tag2 == .read_field) .read_field else .read_tuple;
                        const desc = try intern.internMemberDesc(bld, pr.base.type_, ins.results[0].type_, pr.index);
                        bld.setR(blk, idx, op, bld.slotOf(ins.results[0]), bld.slotOf(pr.base), desc);
                    },
                    .read_payload => |v| {
                        const desc = try intern.internMemberDesc(bld, v.type_, ins.results[0].type_, 0);
                        bld.setR(blk, idx, .read_payload, bld.slotOf(ins.results[0]), bld.slotOf(v), desc);
                    },
                    else => {}, // later stages
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// The typed opcode for one typed lowering kind on a primitive type —
/// the v9 rep-suffix schema: `add.i32`/`add.f64`/`div.u32`/… — fixed by
/// the operand type alone, so an interpreter dispatch never reads a
/// result type. `byte` has no arithmetic and `bool`/`str`/`any`/
/// `hostdata` are not arithmetic — a miss here is a
/// lowering invariant violation.
fn arithOpcode(kind: llir.TypedKind, t: cfg.Type) llir.Opcode {
    return llir.typedOpcode(kind, t, undefined) orelse unreachable;
}

/// Build the typed lowering op for a binary CFG instruction.
fn makeBinOp(tag: cfg.OpTag, bin: cfg.Bin, result: *cfg.Value) typed.TypedOp {
    return .{
        .kind = typed.typedKindOf(tag) orelse unreachable,
        .type_ = bin.a.type_,
        .result_type = result.type_,
        .a = bin.a,
        .b = bin.b,
        .result = result,
    };
}

/// Build the typed lowering op for a unary CFG instruction.
fn makeUnOp(tag: cfg.OpTag, t: cfg.Type, a: *cfg.Value, result: *cfg.Value) typed.TypedOp {
    return .{
        .kind = typed.typedKindOf(tag) orelse unreachable,
        .type_ = t,
        .result_type = result.type_,
        .a = a,
        .b = null,
        .result = result,
    };
}

/// Emit the fast-path arithmetic records, specializing the
/// generic CFG ops to concrete opcodes by the operand type. `neg` is
/// unary (`c == 0`); the binary family and `not_`/`concat` are the
/// 3-address `a = dst, b = src, c = src` form. One record
/// per instruction at its block-local index; slots are the slot-allocation
/// mapping; records are disjoint from the ID-op rows.
///
/// The widthless integer ops compute at 64 bits on the canonical cells,
/// so the 32-bit operand types emit extra canonicalization records the
/// interpreter no longer performs: `sext32` after the width-sensitive
/// results (`add`, `sub`, `mul`, signed `div`, `shl`), `zext32` on
/// unsigned div/rem/min/max/shift inputs, and the mod-32 shift-count mask.
/// The sequence lengths are fixed by `budget.arithSeqCount`, so the sized
/// and emitted records agree by construction.
fn emitArith(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const f = bld.ordered_funcs.items[fi];
        const forms = bld.funcForms(f);
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    // The typed expander writes the whole §4 sequence at
                    // `idx`; the loop's `idx += recordCount` below advances
                    // past it (matching the budget).
                    .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor => |bin| {
                        _ = try emitBinArith(bld, blk, idx, makeBinOp(std.meta.activeTag(ins.op), bin, ins.results[0]), forms[bin.a.id], ins);
                    },
                    // `neg`, `abs`, `clz`, `popcount` go through the same
                    // typed expander (unary forms; `c == 0`).
                    .neg, .abs, .clz, .popcount => |v| {
                        _ = try emitBinArith(bld, blk, idx, makeUnOp(std.meta.activeTag(ins.op), v.type_, v, ins.results[0]), typed.Form.unknown, ins);
                    },
                    .not_ => |v| bld.setE(blk, idx, .not, bld.slotOf(ins.results[0]), bld.slotOf(v)),
                    .concat => |bin| bld.setR(blk, idx, .concat, bld.slotOf(ins.results[0]), bld.slotOf(bin.a), bld.slotOf(bin.b)),
                    else => {}, // interning rows above; the remaining records later
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// The 32-bit normalization staging register: the single T cell the
/// 32-bit arithmetic sequences stage through (the mod-32 shift-count
/// mask and the unsigned div/rem/shift zero-extension). T15 is never a
/// spill sentinel (`llir_alloc` caps the sentinels at `temp_count - 1`),
/// so the staging reference is always unambiguous, and every sequence
/// reads it back within the same block — no T value crosses a call.
const norm_stage: u32 = llir.temp_base + (llir.temp_count - 1);

/// Emit one widthless register-form arithmetic sequence: the opcode
/// plus the 32-bit canonicalization records the operand type demands
/// (Instruction Set §4). This is the typed expander (B.1): it consumes
/// the typed op and writes exactly the §4 record count — the same count
/// the budget derives, so sized and emitted records agree by construction.
/// For a fuse-eligible constant on the right (div/rem/shl/shr, step 6),
/// it emits the immediate form directly and never writes the constant's
/// staging record (`zext32`/`andi`).
fn emitBinArith(bld: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: typed.TypedOp, form_a: typed.Form, ins: *const cfg.Instr) error{OutOfMemory}!void {
    const t = op.type_;
    const dst = bld.slotOf(op.result);
    const sa = bld.slotOf(op.a);
    const sb = if (op.b) |b| bld.slotOf(b) else 0;
    const is32 = t == .primitive and (t.primitive == .int32 or t.primitive == .uint32);
    const fuse: ?typed.FusedImm = if (op.b) |bb| blk2: {
        if (typed.constOf(bb)) |cv| break :blk2 typed.fusedImmR(op.kind, t, cv);
        break :blk2 null;
    } else null;
    switch (op.kind) {
        // `neg` is widthless (two's complement is sign-agnostic): a
        // 32-bit operand type emits the trailing `sext32`.
        .neg => {
            bld.setE(blk, idx, arithOpcode(.neg, t), dst, sa);
            if (is32) bld.setE(blk, idx + 1, .sext32, dst, dst);
        },
        // `abs`, `clz`, `popcount` keep their widthful reps
        // (width-sensitive results) — one record, no canonicalization.
        .abs, .clz, .popcount => bld.setE(blk, idx, arithOpcode(op.kind, t), dst, sa),
        .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor => {
            if (!is32) {
                // The 64-bit integer types and the floats: one widthless/
                // rep record, no canonicalization.
                bld.setR(blk, idx, arithOpcode(op.kind, t), dst, sa, sb);
                return;
            }
            switch (op.kind) {
                .add, .sub => {
                    bld.setR(blk, idx, arithOpcode(op.kind, t), dst, sa, sb);
                    bld.setE(blk, idx + 1, .sext32, dst, dst);
                },
                .bitand, .bitor, .bitxor => {
                    // Bitwise operations preserve the canonical sign extension.
                    bld.setR(blk, idx, arithOpcode(op.kind, t), dst, sa, sb);
                },
                .min, .max => {
                    if (t.primitive == .uint32) {
                        const elide = typed.elideLeadingZext(op.kind, t, form_a);
                        if (elide) {
                            bld.setE(blk, idx, .zext32, dst, sb);
                            bld.setR(blk, idx + 1, arithOpcode(op.kind, t), dst, sa, dst);
                            bld.setE(blk, idx + 2, .sext32, dst, dst);
                        } else {
                            bld.setE(blk, idx, .zext32, norm_stage, sa);
                            bld.setE(blk, idx + 1, .zext32, dst, sb);
                            bld.setR(blk, idx + 2, arithOpcode(op.kind, t), dst, norm_stage, dst);
                            bld.setE(blk, idx + 3, .sext32, dst, dst);
                        }
                    } else {
                        bld.setR(blk, idx, arithOpcode(op.kind, t), dst, sa, sb);
                    }
                },
                .mul => {
                    bld.setR(blk, idx, .mul, dst, sa, sb);
                    bld.setE(blk, idx + 1, .sext32, dst, dst);
                },
                .div, .rem => {
                    if (t.primitive == .uint32) {
                        const elide = typed.elideLeadingZext(op.kind, t, form_a);
                        if (fuse) |f| {
                            // The fused unsigned immediate reads the
                            // zero-extended dividend: the already-zero
                            // operand form directly, or the `zext32`
                            // staging when it had to be widened.
                            if (elide) {
                                bld.setR(blk, idx, f.op, dst, sa, f.imm);
                                bld.setE(blk, idx + 1, .sext32, dst, dst);
                            } else {
                                bld.setE(blk, idx, .zext32, norm_stage, sa);
                                bld.setR(blk, idx + 1, f.op, dst, norm_stage, f.imm);
                                bld.setE(blk, idx + 2, .sext32, dst, dst);
                            }
                            try bld.fused_instrs.put(bld.arena, ins, {});
                        } else if (elide) {
                            bld.setE(blk, idx, .zext32, dst, sb);
                            bld.setR(blk, idx + 1, if (op.kind == .div) .divu else .remu, dst, sa, dst);
                            bld.setE(blk, idx + 2, .sext32, dst, dst);
                        } else {
                            // The sign-extended canonical cells must be
                            // zero-extended before the full-cell unsigned
                            // operation, and the result canonicalized.
                            bld.setE(blk, idx, .zext32, norm_stage, sa);
                            bld.setE(blk, idx + 1, .zext32, dst, sb);
                            bld.setR(blk, idx + 2, if (op.kind == .div) .divu else .remu, dst, norm_stage, dst);
                            bld.setE(blk, idx + 3, .sext32, dst, dst);
                        }
                    } else {
                        if (fuse) |f| {
                            bld.setR(blk, idx, f.op, dst, sa, f.imm);
                            if (op.kind == .div and is32) bld.setE(blk, idx + 1, .sext32, dst, dst);
                            try bld.fused_instrs.put(bld.arena, ins, {});
                        } else {
                            bld.setR(blk, idx, if (op.kind == .div) .div else .rem, dst, sa, sb);
                            if (op.kind == .div and is32) bld.setE(blk, idx + 1, .sext32, dst, dst);
                        }
                    }
                },
                .shl => {
                    if (fuse) |f| {
                        bld.setR(blk, idx, f.op, dst, sa, f.imm);
                        if (is32) bld.setE(blk, idx + 1, .sext32, dst, dst);
                        try bld.fused_instrs.put(bld.arena, ins, {});
                    } else {
                        // mod-32 count masking + the 64-bit shift + the
                        // canonicalization (the shift's low 32 bits are
                        // correct, the extension bits are not).
                        bld.setR(blk, idx, .andi, norm_stage, sb, 31);
                        bld.setR(blk, idx + 1, .shl, dst, sa, norm_stage);
                        bld.setE(blk, idx + 2, .sext32, dst, dst);
                    }
                },
                .shr => {
                    if (fuse) |f| {
                        if (t.primitive == .uint32) {
                            const elide = typed.elideLeadingZext(.shr, t, form_a);
                            if (elide) {
                                bld.setR(blk, idx, f.op, dst, sa, f.imm);
                                bld.setE(blk, idx + 1, .sext32, dst, dst);
                            } else {
                                bld.setE(blk, idx, .zext32, dst, sa);
                                bld.setR(blk, idx + 1, f.op, dst, dst, f.imm);
                                bld.setE(blk, idx + 2, .sext32, dst, dst);
                            }
                        } else {
                            bld.setR(blk, idx, f.op, dst, sa, f.imm);
                        }
                        try bld.fused_instrs.put(bld.arena, ins, {});
                    } else {
                        bld.setR(blk, idx, .andi, norm_stage, sb, 31);
                        if (t.primitive == .uint32) {
                            const elide = typed.elideLeadingZext(.shr, t, form_a);
                            if (elide) {
                                // The operand is already zero-extended; the shift
                                // reads it directly and the result canonicalizes.
                                bld.setR(blk, idx + 1, .shru, dst, sa, norm_stage);
                                bld.setE(blk, idx + 2, .sext32, dst, dst);
                            } else {
                                // The zero-fill shift needs a zero-extended operand;
                                // its result is canonicalized too.
                                bld.setE(blk, idx + 1, .zext32, dst, sa);
                                bld.setR(blk, idx + 2, .shru, dst, dst, norm_stage);
                                bld.setE(blk, idx + 3, .sext32, dst, dst);
                            }
                        } else {
                            // The arithmetic shift of a sign-extended cell is
                            // canonical — no truncation needed.
                            bld.setR(blk, idx + 1, .shr, dst, sa, norm_stage);
                        }
                    }
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

/// Emit the fast-path comparison and cast records — the v9
/// C-Type schema: a comparison writes the implicit `cond` and the
/// lowering materializes the SSA bool result with `copy dst, cond`
/// right after; `sle` is the float non-strict primitive (`a >= b`
/// ≡ `sle b, a`, `a > b` ≡ `slt b, a` — the swap preserves the NaN
/// behavior of every predicate). The
/// `cvt.<src>.<dst>` casts are the single-record C-Type forms.
fn emitCompare(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .eq, .ne, .lt, .le, .gt, .ge => |bin| {
                        const dst = bld.slotOf(ins.results[0]);
                        const sel = cmpSel(std.meta.activeTag(ins.op), bin);
                        bld.setC(blk, idx, sel.op, bld.slotOf(sel.a), bld.slotOf(sel.b));
                        if (sel.invert) {
                            bld.setE(blk, idx + 1, .not, llir.cond_reg, llir.cond_reg);
                            bld.setE(blk, idx + 2, .copy, dst, llir.cond_reg);
                        } else {
                            bld.setE(blk, idx + 1, .copy, dst, llir.cond_reg);
                        }
                    },
                    .num_cast => |v| {
                        const op = castOpcode(v.type_, ins.results[0].type_);
                        bld.setC(blk, idx, op, bld.slotOf(ins.results[0]), bld.slotOf(v));
                    },
                    else => {}, // earlier rows above; the remaining records later
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// The v9 cast opcode for the `(src, dst)` pair: the
/// explicit `cvt.<src>.<dst>` C-Type spellings over the seven cast
/// types `b, i32, u32, i64, u64, f32, f64`. The checker restricts
/// `num_cast` to exactly this set (Core §16.3); the identity entries
/// are unreachable here (the checker and the CFG validator reject
/// them).
fn castOpcode(src: cfg.Type, dst: cfg.Type) llir.Opcode {
    return llir.typedOpcode(.cast, src, dst) orelse unreachable;
}

/// Emit the branchless select records — the `select` composite
/// is two records: `copy cond, %cond` loads the bool condition
/// into the condition register, then `cmov dst, %a, %b` moves the
/// selected scalar pattern (dst = cond ? a : b). The
/// condition's defining record (a comparison, `not`, or a bool
/// value) is emitted by its own stage; this stage only reads its
/// slot.
fn emitSelect(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .select => |s| {
                        bld.setE(blk, idx, .copy, llir.cond_reg, bld.slotOf(s.cond));
                        bld.setR(blk, idx + 1, .cmov, bld.slotOf(ins.results[0]), bld.slotOf(s.a), bld.slotOf(s.b));
                    },
                    else => {}, // earlier rows above
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// The typed C-Type comparison selection for a CFG comparison.
/// `sle` is the float non-strict primitive (`a <= b` ≡ `sle a, b`,
/// `a >= b` ≡ `sle b, a` — the swap preserves the NaN behavior),
/// `gt` is the strict swap alias (`a > b` ≡ `slt b, a`), and
/// integer `le`/`ge` synthesize `not(slt)`.
/// `byte` comparisons lower through the `u32` reps.
/// Shared with the control pass's fused-branch recognition, which
/// derives the B-type branch form from the same selection.
pub const CmpSel = struct { op: llir.Opcode, a: *const cfg.Value, b: *const cfg.Value, invert: bool = false };
pub fn cmpSel(tag: cfg.OpTag, bin: cfg.Bin) CmpSel {
    return switch (tag) {
        .eq => .{ .op = llir.typedOpcode(.eq, bin.a.type_, undefined).?, .a = bin.a, .b = bin.b },
        .ne => .{ .op = llir.typedOpcode(.ne, bin.a.type_, undefined).?, .a = bin.a, .b = bin.b },
        .lt => .{ .op = llir.typedOpcode(.lt, bin.a.type_, undefined).?, .a = bin.a, .b = bin.b },
        .le => if (Builder.isInteger(bin.a.type_)) .{ .op = llir.typedOpcode(.lt, bin.a.type_, undefined).?, .a = bin.b, .b = bin.a, .invert = true } else .{ .op = llir.typedOpcode(.le, bin.a.type_, undefined).?, .a = bin.a, .b = bin.b },
        .gt => .{ .op = llir.typedOpcode(.lt, bin.a.type_, undefined).?, .a = bin.b, .b = bin.a },
        .ge => if (Builder.isInteger(bin.a.type_)) .{ .op = llir.typedOpcode(.lt, bin.a.type_, undefined).?, .a = bin.a, .b = bin.b, .invert = true } else .{ .op = llir.typedOpcode(.ge, bin.a.type_, undefined).?, .a = bin.b, .b = bin.a },
        else => unreachable,
    };
}

/// Emit the call and syscall records — direct calls are
/// `jal ra, addr`, indirect calls `jalr ra, base, 0`, and
/// `syscall` (a = the result register, `zero` for void/never) with
/// its descriptor. `ret` and `tailcall_self` are terminator
/// records — emitted by the control pass (the self-tailcall is a
/// pure jump; the direct call through the same function uses `jal ra`).
/// Each call's `slot_*` preparation records come first — one per
/// parameter at its absolute outgoing-window offset; the window's
/// `A = max(P, R)` cells overlap callee parameters with the result
/// result, and a non-void call ends with `take dst, F(L+3+O-A)` —
/// the result alias.
/// Direct callees resolve by name; the FunctionId/desc ids are dense
/// and the window lies in `[0, V)`.
fn emitCalls(bld: *Builder) error{ OutOfMemory, SyscallWithoutSignature }!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .call => |c| try emitCallInstr(bld, blk, idx, ins, c),
                    .syscall => |s| try emitSyscallInstr(bld, blk, idx, ins, s),
                    else => {}, // earlier rows above
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// The parameter list a call's callee declares — direct targets
/// resolve through their `IrFunc`, indirect ones through the function
/// value's type. Shared with the lifecycle pass's argument-mode
/// classification (`cfg_lower_lifecycle.plan` reads it through the
/// Builder shim).
pub fn calleeParamList(bld: *Builder, callee: cfg.Callee) []const cfg.Param {
    return switch (callee) {
        .direct => |d| blk: {
            if (d.func) |f| break :blk f.params;
            // Parameter *modes* are metadata, not references: the
            // program-wide lookup is read-only and also serves
            // cross-module callees, whose emitted reference is symbolic.
            if (bld.programFuncByName(d.name)) |f| break :blk f.params;
            break :blk &.{};
        },
        .value => |v| switch (v.type_) {
            .function => |ft| ft.params,
            else => &.{},
        },
    };
}

/// The `slot_*` preparation records of one call:
/// exactly one record per parameter — there is no window aliasing to
/// elide — writing each argument to its absolute outgoing-window
/// offset `W - A + k` (the value area is the window's top `A =
/// max(P, R)` cells; slot 0 is simultaneously argument 0 and the
/// result slot). The opcode is the argument's transfer mode:
/// borrowed views install `slot_borrow`, owned unique/move-mode
/// sources transfer with `slot_move`, counted sources retain with
/// `slot_retain`, everything else bit-copies with `slot_copy`.
/// Shared with the budgeting pass's argument-move count (read through
/// the Builder shim).
pub fn callArgMoves(bld: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) error{OutOfMemory}![]const edges.EdgeCopy {
    const c = ins.op.call;
    const fi = bld.funcIndexOfBlock(blk);
    const fd = bld.func_descs.items[fi];
    const params = calleeParamList(bld, c.callee);
    const p: u32 = @intCast(c.args.len);
    const r: u32 = if (ins.results.len > 0) 1 else 0;
    const a = @max(p, r);
    const base = fd.window_count - a;
    var out = std.ArrayList(edges.EdgeCopy).empty;
    for (c.args, 0..) |arg, k| {
        const mode: ast.ParamMode = if (k < params.len) params[k].mode else .plain;
        const op: llir.Opcode = if (mode == .borrow or (mode != .move and arg.state == .borrowed))
            .slot_borrow
        else if (mode == .move or (arg.ownership == .unique and arg.state == .owned))
            .slot_move
        else if (llir.modeOf(arg.type_) == .counted)
            .slot_retain
        else
            .slot_copy;
        try out.append(bld.arena, .{
            .op = op,
            .dst = bld.slotOf(arg),
            .src = 0,
            .src_type = &arg.type_,
            .imm = base + @as(u32, @intCast(k)),
        });
    }
    return out.items;
}

/// Whether a non-void call emits its post-call `take dst, F(L+3+O-A)`
/// record. False only when the allocator coalesced the result onto the
/// result alias itself (Step 8 — `slotOf(result)` equals the alias
/// register), so the take would be a self-move and is dropped.
/// Shared with the budgeting pass so sized and emitted records agree.
pub fn callNeedsTake(bld: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) bool {
    if (ins.results.len == 0) return false;
    const fi = bld.funcIndexOfBlock(blk);
    const fd = bld.func_descs.items[fi];
    const c = ins.op.call;
    const a: u32 = @max(@as(u32, @intCast(c.args.len)), 1);
    const src = llir.frameReg(fd.f_count + fd.window_count - a); // F(L+3+O-A)
    return bld.slotOf(ins.results[0]) != src;
}

/// One `call` instruction's records: the `slot_*`
/// preparation records first — one per parameter at its absolute
/// outgoing-window offset — then the `jal ra` (direct) or
/// `jalr ra, base, 0` (indirect) record itself, and for a non-void
/// call the `take dst, F(L+3+O-A)` that transfers the result
/// register. Direct callees
/// are resolved by name — the frontend's lowered `DirectCallee`
/// carries `func == null` until the optimizer runs
/// (`resolveDirectCalls`), and the LLIR lowering keeps the
/// input program read-only. The `jal ra`'s pc-relative offset is a
/// placeholder 0 — linearization derives and encodes it.
fn emitCallInstr(bld: *Builder, blk: *const cfg.BasicBlock, idx: u32, ins: *const cfg.Instr, call: cfg.Call) error{OutOfMemory}!void {
    const moves = try callArgMoves(bld, blk, ins);
    for (moves, 0..) |mv, i| {
        // I format: a = the F source register, imm16 = the absolute
        // outgoing-window offset.
        bld.setI(blk, idx + @as(u32, @intCast(i)), mv.op, mv.dst, mv.imm);
    }
    const call_idx = idx + @as(u32, @intCast(moves.len));
    // The instruction index where the post-call `take` (if any) lands:
    // one past the last call-path instruction (jal/jalr at `call_idx` for
    // the direct/value paths; `module_ref`/`load_member`/`jalr` occupy
    // `call_idx..call_idx+3` for a cross-module symbolic call).
    var take_idx = call_idx + 1;
    switch (call.callee) {
        .direct => |d| {
            if (bld.func_name_ids.contains(d.name)) {
                // Module-internal: the direct call is `jal ra, addr` —
                // a fixed link register, no destination field. The
                // result is published by the callee's `ret` into the
                // caller register `F(L+3+O-A)` and taken by the generic
                // `take` below. The pc-relative offset is a placeholder
                // 0 — linearization derives and encodes it.
                bld.setU(blk, call_idx, .jal, llir.ra_reg, 0);
            } else {
                // Cross-module: a symbolic import — `module_ref`
                // (load and initialize the target module) plus
                // `load_member` (the callee's VM pc, an importable
                // function symbol even when it is not a public member)
                // through the staging T register, then the indirect-call
                // path. The take contract is checked dynamically by
                // `enterCall` against the actual callee, so coalescing
                // never elides the take here (see the coalesce pass).
                const q = Builder.splitQualName(d.name) orelse unreachable;
                const mod_sym = try bld.internSymbol(q.module);
                const imp = try bld.importIndex(q.module, q.member);
                const desc = try intern.internMemberDesc(bld, .{ .module = {} }, null, imp);
                bld.setI(blk, call_idx, .module_ref, norm_stage, mod_sym);
                bld.setR(blk, call_idx + 1, .load_member, norm_stage, norm_stage, desc);
                bld.setI(blk, call_idx + 2, .jalr, norm_stage, 0);
                take_idx = call_idx + 3;
            }
        },
        .value => |v| {
            // v10: the function value is an executable entry PC in the
            // base register; `jalr ra, base, 0` calls it. The base
            // may be an F/T/zero source; the link is the fixed `ra`.
            bld.setI(blk, call_idx, .jalr, bld.slotOf(v), 0);
        },
    }
    if (bld.callNeedsTake(blk, ins)) {
        // Non-void: the fallthrough is `take dst, F(L+3+O-A)` —
        // unless the allocator coalesced the result onto the alias
        // itself (Step 8), in which case the take is a self-move and
        // is dropped. The source encoding is `L + W - A`, equivalently
        // `outReg(O - A)`, checked for static `jal` by the loader and
        // for `jalr` by `enterCall`. The result's home slot is a normal
        // F cell; the take transfers the window alias into it.
        const fd = bld.func_descs.items[bld.funcIndexOfBlock(blk)];
        const a: u32 = @max(@as(u32, @intCast(call.args.len)), 1);
        const src = llir.frameReg(fd.f_count + fd.window_count - a);
        bld.setE(blk, take_idx, .take, bld.slotOf(ins.results[0]), src);
    }
}

/// One `syscall` instruction's record: `a` = the result
/// register (`zero` for a void/never binding — writing `zero`
/// discards the result), `imm16` = the `SyscallDescId`. The
/// descriptor statically carries the dispatch target (`(module_id,
/// member_name)` → `HostBindingId`), the binding's specialized
/// signature, and the argument registers, so the runtime performs no
/// signature checks. A syscall never changes frames: args are read
/// from the current frame. Text-form AIR carries no signature
/// (`sc.sig == null`) — the lowering rejects it with
/// `error.SyscallWithoutSignature` rather than leaving its
/// pre-sized record zeroed; the frontend always sets `sig`.
fn emitSyscallInstr(bld: *Builder, blk: *const cfg.BasicBlock, idx: u32, ins: *const cfg.Instr, sc: cfg.SysCall) error{ OutOfMemory, SyscallWithoutSignature }!void {
    const sig = sc.sig orelse return error.SyscallWithoutSignature; // text-form AIR: no signature
    const mod_name: []const u8 = switch (sc.target) {
        .builtin => "builtin",
        .host_module => |hm| hm.module,
    };
    const member_name: []const u8 = switch (sc.target) {
        .builtin => |b| @tagName(b),
        .host_module => |hm| hm.member,
    };
    // The host dispatch pair is a symbolic import — a
    // `(module_symbol, member_symbol)` `ImportDesc` row the runtime
    // resolves through the registered host modules; no numeric module
    // id exists in the artifact.
    const binding = try bld.importIndex(mod_name, member_name);
    const desc = try intern.internSyscallDesc(bld, binding, sig, sc.args);
    const dst = if (ins.results.len > 0) bld.slotOf(ins.results[0]) else llir.zero_reg;
    bld.setI(blk, idx, .syscall, dst, desc);
}

/// Emit the explicit ownership-transfer records — the CFG's
/// `.copy`/`.borrow`/`.move_` instructions lower to the fast-path
/// `copy`/`borrow`/`move_` slot ops:
/// `a = dst, b = src, c = 0` — an explicit slot-to-slot operation
/// whose opcode alone distinguishes plain copy (0xf0), alias
/// (borrow view, 0xf1), and ownership transfer (0xf2); the
/// interpreter never reads a value's state. The verify-only
/// annotations that produced the instruction (the operand's
/// `ValueState`/`Ownership` classification, its `BorrowOrigin`) are
/// consumed by the frontend at lowering time and never copied into
/// the image — the frozen image types have no such fields, and the
/// borrow-root-use-after-move/drop cases are rejected by the input
/// CFG validator (cfg_validate), not re-checked here.
fn emitOwnership(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    // v1: a copy of a counted value
                    // retains — `copy_retain` establishes a new
                    // owner; plain values keep the bit-copy.
                    .copy => |v| {
                        const op: llir.Opcode = if (llir.modeOf(v.type_) == .counted) .copy_retain else .copy;
                        bld.setE(blk, idx, op, bld.slotOf(ins.results[0]), bld.slotOf(v));
                    },
                    .borrow => |v| bld.setE(blk, idx, .borrow, bld.slotOf(ins.results[0]), bld.slotOf(v)),
                    .move_ => |v| bld.setE(blk, idx, .move, bld.slotOf(ins.results[0]), bld.slotOf(v)),
                    else => {}, // earlier rows above; drops and releases later
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// The residual destruction records plus the lifecycle
/// stage's trailing releases. Cleanup tokens never
/// appear — the frontend resolved conditional ownership into
/// unconditional edge drops (cfg_lower_emit.joinMaybeFlags) — so
/// `cleanup_arm`/`cleanup_disarm`/`cleanup_drop` instructions
/// produce no record at all. A residual `.drop_` lowers by mode:
/// counted owners `release` (the RC header self-describes), unique/
/// host owners `drop src, DropDescId` with a descriptor naming the
/// destroyed type or host type.
fn emitDrops(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .drop_ => |v| {
                        const slot = bld.fit7(bld.slotOf(v));
                        if (llir.modeOf(v.type_) == .counted) {
                            bld.setE(blk, idx, .release, slot, 0);
                        } else {
                            const desc = try intern.internDropDesc(bld, v.type_);
                            bld.setI(blk, idx, .drop, slot, desc);
                        }
                    },
                    // Token ops are gone in v1: no records, no cells.
                    .cleanup_arm, .cleanup_disarm, .cleanup_drop => {},
                    else => {},
                }
                // The lifecycle pass's trailing records (counted
                // releases after a final use) occupy this
                // instruction's remaining budget slots.
                const main = try budget.mainRecordCount(bld, blk, ins);
                const trail = lifecycle.trailingOf(bld, ins);
                for (trail, 0..) |rec, ti| {
                    // Trailing records are counted releases — the
                    // E-Type `release src` form.
                    bld.setE(blk, idx + main + @as(u32, @intCast(ti)), rec.op, rec.a, rec.b);
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// Emit the aggregate-construction, multi-result destructure,
/// and `switch` records with their descriptors. The
/// n-ary forms stay atomic — one fixed 4-byte record per op, the
/// operand/result lists held by a descriptor, never split into a
/// binary chain. `construct` (a = dst, b = `ConstructDescId`, c = 0)
/// names its component registers via the descriptor's `call_args`
/// range; the destructure family (a = `DestructureDescId`, b = base,
/// c = the variant tag for `unpack_variant`/`borrow_variant`, else
/// 0) names its result slots via `destructure_dsts`; the `switch`
/// terminator (a = tag register, b = `SwitchDescId`, c = 0) names
/// its `(tag → symbolic BlockId)` arms via `switch_arms` (linearization
/// resolves the targets to signed offsets from the `switch`
/// instruction's own pc). The `switch` default is
/// an implicit trap — no explicit arm exists.
/// `construct`/destructure descriptors intern: identical
/// `(tag, args)` / `(kind, dsts)` rows share one descriptor; switch
/// descriptors are emitted one per `switch` (arm offsets are
/// pc-relative, so identical `(tag, target)` sequences at different
/// pcs cannot share).
fn emitAggregates(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const blk = bld.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .construct => |c| {
                        const desc = try intern.internConstructDesc(bld, c.tag, c.args, &ins.results[0].type_);
                        bld.setI(blk, idx, .construct, bld.slotOf(ins.results[0]), desc);
                    },
                    .unpack_struct => |base| try emitDestructure(bld, blk, idx, .unpack_struct, .struct_, base, 0, ins),
                    .unpack_tuple => |base| try emitDestructure(bld, blk, idx, .unpack_tuple, .tuple, base, 0, ins),
                    .unpack_variant => |uv| try emitDestructure(bld, blk, idx, .unpack_variant, .variant, uv.base, uv.tag, ins),
                    .split_list => |base| try emitDestructure(bld, blk, idx, .split_list, .list, base, 0, ins),
                    .borrow_variant => |bv| try emitDestructure(bld, blk, idx, .borrow_variant, .variant, bv.base, bv.tag, ins),
                    // Single-result projections whose schema is a
                    // plain register form.
                    .read_tag => |v| bld.setE(blk, idx, .read_tag, bld.slotOf(ins.results[0]), bld.slotOf(v)),
                    .tail => |v| bld.setR(blk, idx, .tail, bld.slotOf(ins.results[0]), bld.slotOf(v), 0),
                    // `any` instructions carry the payload
                    // TypeId in `c` — pack names the *source* type
                    // (the verifier proves it matches), unpack names
                    // the *recovery target* type, and the dynamic
                    // TypeId stored in the any object is compared
                    // against it at runtime (no cell tags).
                    .any_pack_copy => |v| bld.setR(blk, idx, .any_pack_copy, bld.slotOf(ins.results[0]), bld.slotOf(v), try intern.internType(bld, v.type_)),
                    .any_pack_move => |v| bld.setR(blk, idx, .any_pack_move, bld.slotOf(ins.results[0]), bld.slotOf(v), try intern.internType(bld, v.type_)),
                    .any_unpack_copy, .any_unpack_move => {
                        const expected = try intern.internType(bld, ins.results[0].type_);
                        const src = switch (ins.op) {
                            .any_unpack_copy => |v| v,
                            .any_unpack_move => |v| v,
                            else => unreachable,
                        };
                        bld.setR(blk, idx, if (std.meta.activeTag(ins.op) == .any_unpack_copy) .any_unpack_copy else .any_unpack_move, bld.slotOf(ins.results[0]), bld.slotOf(src), expected);
                    },
                    else => {}, // earlier rows above
                }
                idx += try bld.recordCount(blk, ins);
            }
        }
    }
}

/// One multi-result destructure record: `a` = the
/// `DestructureDescId`, `b` = the base slot, `c` = the variant tag
/// (0 for the struct/tuple/list forms). The descriptor names the
/// result slots in result order; the opcode/kind pairing is checked
/// by the phase-3 validator.
fn emitDestructure(bld: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: llir.Opcode, kind: llir.DestructureKind, base: *const cfg.Value, tag: u32, ins: *const cfg.Instr) error{OutOfMemory}!void {
    const desc = try intern.internDestructureDesc(bld, kind, base, ins.results);
    // `unpack_struct`/`unpack_tuple`/`split_list` are I format
    // (a = base, imm16 = DestructureDescId); `unpack_variant`/
    // `borrow_variant` are R format (a = 8-bit DestructureDescId,
    // b = base, c = tag).
    switch (op) {
        .unpack_variant, .borrow_variant => bld.setR(blk, idx, op, desc, bld.slotOf(base), tag),
        else => bld.setI(blk, idx, op, bld.slotOf(base), desc),
    }
}
