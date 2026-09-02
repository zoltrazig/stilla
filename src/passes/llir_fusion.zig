//! Pass: LLIR instruction fusion — the 2.14 const+op immediate fusion
//! and the 2.15 `read_indexi` / fused multiply-accumulate peepholes
//! (Stilla LLIR Instruction Set §5). In: the `Builder` after every
//! emission stage (2.1–2.13) — each block's record list fully written
//! (instructions, edge copies, terminator), PCs still deferred. Out:
//! the same lists compacted block-locally: fused sites folded to their
//! immediate variants (`*_i`, `read_indexi`, `*_madd`/`*_maddi`), dead
//! `const`/`mul` records deleted, and the `fused_consts` /
//! `consumed_instrs` marks plus the `last_fusion` density report
//! populated. The input CFG is never rewritten — only image records
//! change, and only within their own block, so no absolute-PC
//! reference ever needs a re-backfill (2.16 linearizes the compacted
//! lists afterward).
const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");
const patterns = @import("llir_patterns.zig");
const typed = @import("cfg_lower_typed.zig");

const Builder = lower.Builder;
const FusionMetrics = lower.FusionMetrics;

// --- 2.14 const+op fusion helpers ------------------------------------------

/// The binary op family of a CFG binary instruction, as a
/// `llir.TypedKind` (the operand-type index `typedOpcodeImm` keys
/// on). Only arithmetic/bitwise and comparison binary families fuse; everything else is
/// unreachable here.
fn typedKind(tag: cfg.OpTag) llir.TypedKind {
    return switch (tag) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .shl => .shl,
        .shr => .shr,
        .bitand => .bitand,
        .bitor => .bitor,
        .bitxor => .bitxor,
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        else => unreachable,
    };
}

fn flipCmp(tag: llir.TypedKind) ?llir.TypedKind {
    return switch (tag) {
        .lt => .gt,
        .le => .ge,
        .gt => .lt,
        .ge => .le,
        else => null,
    };
}

/// The integer commutativity rule (Instruction Set §5): `eq`/`ne`/`add`/`mul`
/// commute to place a constant in the second operand position —
/// never the `f32` forms (NaN-payload ordering is observable), and never
/// `sub`/`div`/`rem` (not commutative).
fn isCommutative(tag: llir.TypedKind) bool {
    return switch (tag) {
        // Bitwise and/or/xor are integer ops and commute too — a
        // constant on either side fuses to the immediate form.
        .add, .mul, .eq, .ne, .bitand, .bitor, .bitxor => true,
        else => false,
    };
}

/// The integer types that may commute.
/// The constant payload of a value whose defining instruction is a
/// `const_`, or null for every other value.
fn constOf(v: *const cfg.Value) ?cfg.ConstValue {
    const d = v.def orelse return null;
    return switch (d.op) {
        .const_ => |cv| cv,
        else => null,
    };
}

/// The fused immediate for a numeric constant at operand type `t`, or
/// null when the constant does not fit the v9 7-bit immediate
/// window — the site stays a `const` + register form
/// (Instruction Set §3.3, §10). The field is the raw 7-bit pattern,
/// and each opcode interprets it at decode: the rep-carrying
/// arithmetic forms sign-extend on the
/// `.i32`/`.i64` members (exact range
/// `[-64, 63]`) and zero-extend on the `.u32`/`.u64` members (exact range
/// `[0, 127]`); the shift counts (`shli`/`shri`) and the bitwise masks
/// (`andi`/`ori`/`xori`) always zero-extend (`[0, 127]`, mask semantics
/// — `andi.i32 F0, F1, 0x7f` masks with `0x0000007f`, never
/// sign-extended). The C-Type comparisons split: the signed ordering
/// (`slti`/`sgti`) and equality (`seqi`/`snei`) sign-extend (`[-64,
/// 63]` — equality has no unsigned variant, so an unsigned equality
/// constant only fuses inside that window), while the unsigned
/// ordering (`sltiu`/`sgtiu`) zero-extends (`[0, 127]`). There are
/// **no float immediate forms** — every float constant materializes
/// through `const`. Only numeric constants fuse
/// (`typedOpcodeImm` gates the operand type to the numeric
/// families first).
fn immOf(cv: cfg.ConstValue, kind: llir.TypedKind, t: cfg.Type) ?u8 {
    return typed.immOf(cv, kind, t);
}

/// Count one operand reference toward a value's use count. Every value
/// is tracked — the 2.15 multiply-accumulate preconditions (a mul
/// result and its accumulator must each be consumed by exactly the
/// fused `add`) need full counts, and the 2.14 const-deletion decision
/// only consults the entries of const values.
fn noteUse(uses: *std.AutoHashMapUnmanaged(*const cfg.Value, u32), arena: std.mem.Allocator, v: *const cfg.Value) error{OutOfMemory}!void {
    const gop = try uses.getOrPut(arena, v);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

/// Drop one fused use of `v`. The entry exists — pass 1 counted every
/// const operand — so a miss would be a peephole bug (defensive `if`
/// keeps a stray miss from trapping the compiler).
fn decrementUse(uses: *std.AutoHashMapUnmanaged(*const cfg.Value, u32), v: *const cfg.Value) void {
    if (uses.getPtr(v)) |p| p.* -= 1;
}

/// Count every constant operand referenced by an instruction, including
/// phi incoming values (the 2.7 edge copies read the incoming slot, so
/// a phi-fed constant keeps its record unless every edge use fused).
fn countOpUses(op: cfg.Op, uses: *std.AutoHashMapUnmanaged(*const cfg.Value, u32), arena: std.mem.Allocator) error{OutOfMemory}!void {
    return switch (op) {
        // no value operands
        .const_, .module_ref, .fn_ref => {},
        // single value operand
        .neg,
        .abs,
        .clz,
        .popcount,
        .not_,
        .num_cast,
        .any_pack_copy,
        .any_pack_move,
        .any_unpack_copy,
        .any_unpack_move,
        .copy,
        .borrow,
        .move_,
        .drop_,
        .cleanup_arm,
        .cleanup_disarm,
        .cleanup_drop,
        .tail,
        .unpack_struct,
        .unpack_tuple,
        .split_list,
        .read_tag,
        .read_payload,
        => |v| try noteUse(uses, arena, v),
        // binary
        .add, .sub, .mul, .div, .rem, .min, .max, .shl, .shr, .bitand, .bitor, .bitxor, .concat, .eq, .ne, .lt, .le, .gt, .ge => |b| {
            try noteUse(uses, arena, b.a);
            try noteUse(uses, arena, b.b);
        },
        // ternary
        .select => |s| {
            try noteUse(uses, arena, s.cond);
            try noteUse(uses, arena, s.a);
            try noteUse(uses, arena, s.b);
        },
        .type_is => |ti| try noteUse(uses, arena, ti.value),
        .read_field, .read_tuple => |p| try noteUse(uses, arena, p.base),
        .read_index => |ix| {
            try noteUse(uses, arena, ix.base);
            try noteUse(uses, arena, ix.index);
        },
        .unpack_variant => |uv| try noteUse(uses, arena, uv.base),
        .borrow_variant => |bv| try noteUse(uses, arena, bv.base),
        .load_member => |lm| try noteUse(uses, arena, lm.module),
        .store_member => |sm| try noteUse(uses, arena, sm.value),
        .construct => |c| {
            for (c.args) |a| try noteUse(uses, arena, a);
        },
        .call => |c| {
            switch (c.callee) {
                .direct => {},
                .value => |v| try noteUse(uses, arena, v),
            }
            for (c.args) |a| try noteUse(uses, arena, a);
        },
        .syscall => |s| {
            for (s.args) |a| try noteUse(uses, arena, a);
        },
        .phi => |p| {
            for (p.incoming) |in_| try noteUse(uses, arena, in_.value);
        },
    };
}

/// Count every constant operand referenced by a block terminator (the
/// `ret` result, `br` condition, `switch` discriminant, and `tailcall`
/// arguments all read their values from slots).
fn countTermUses(term: cfg.Terminator, uses: *std.AutoHashMapUnmanaged(*const cfg.Value, u32), arena: std.mem.Allocator) error{OutOfMemory}!void {
    return switch (term) {
        .ret => |v| {
            if (v) |rv| try noteUse(uses, arena, rv);
        },
        .j => {},
        .br => |b| try noteUse(uses, arena, b.cond),
        .@"switch" => |s| try noteUse(uses, arena, s.disc),
        .tailcall => |tc| {
            for (tc.args) |a| try noteUse(uses, arena, a);
        },
        .trap => {},
    };
}

/// 2.14: the const+op fusion peephole's before/after density report —
/// instruction counts and image bytes (4 per instruction record, spec
/// §2) of the emitted code table, before and after the pass compacts
/// away the fused `const` records (Instruction Set §5: a fused site is
/// 4 image bytes versus 8 for its `const` + op expansion).
/// 2.14: the const+op fusion peephole — an independent pass over the
/// emitted image, running after every emit stage and before `finish`
/// (Instruction Set §5, Immediate arithmetic/equality/ordering). It
/// folds a `const` + typed op pair into one immediate variant
/// (`dst = b op imm8` — the R-format `c` field carries the constant's
/// raw 8-bit pattern, each opcode interpreting it at decode:
/// sign-extended for the signed arithmetic and ordering forms
/// (`addi`/`subi`/`muli`/`maddi`/`divi`/`remi`, `lti`/`gti`),
/// zero-extended for the raw-pattern equality/unsigned forms
/// (`eqi`/`nei`/`ltiu`/`gtiu`/`diviu`/`remiu`), the shift counts, and
/// the bitwise masks, §3.3). The merged int family shares one set of
/// immediate opcodes: `addi/subi/muli/divi/diviu/remi/remiu/maddi`
/// and `eqi/nei/lti/ltiu/gti/gtiu`, plus `shli/shri/shrui` and
/// `andi/ori/xori` — integer `le`/`ge` have no immediate forms (they
/// synthesize to `not`(gt/lt)), and there are **no f32 immediate
/// forms**: a binary16 constant needs 16 bits, which the 8-bit field
/// cannot carry, so every f32 constant materializes through `const`
/// (Instruction Set §7). The fusion is a
/// pure projection: the input CFG is never rewritten — the pass reads
/// operand types and constant values from the CFG and only rewrites
/// image records.
///
/// Rules (the Instruction Set is normative; this is the operational
/// summary): a constant in the second operand position fuses directly;
/// the integer `eq`/`ne`/`add`/`mul` commute the operands to place it
/// there (never the `f32` forms — NaN payload ordering is observable);
/// an ordering comparison with the constant on the left swaps and
/// flips the operator (`k < b` → `b > k`); `byte_*i`
/// needs `imm <= 0xff`, which a byte constant satisfies by
/// construction; a constant that does not fit the 8-bit field (an
/// `i32` value outside the sign-extended `i8` range, a `u32` value
/// outside the zero-extended window of its opcode's decode, and every
/// f32 constant) is not fused — it stays a `const` + register form.
/// An imm operand is never a register — it is schema-disambiguated at
/// decode.
///
/// One record's position in the per-block lists: the block's dense
/// `BlockId` plus the block-local record index — the 2.14–2.15
/// peephole's delete target.
const RecPos = struct {
    bi: u32,
    idx: u32,
};

/// Density: a fused site is one record, and the `const` record is
/// deleted — but only when every use of the constant was folded. The
/// deletion is per-block: the pass marks dead records and retains
/// each block's survivors, so no record outside the block moves and
/// no PC, target, or range is ever re-backfilled (2.16 linearizes
/// the compacted lists afterward). `last_fusion` records the
/// before/after density report for the corpus metric.
pub fn peephole(b: *Builder) error{OutOfMemory}!FusionMetrics {
    var before: u32 = 0;
    for (b.block_records.items) |recs| before += @intCast(recs.items.len);
    // Per-block dead marks, parallel to `block_records`: sized to
    // each block's current list, written during pass 2a/3, consumed
    // by the compaction below. Allocations happen before any pass so
    // the sizes are stable.
    const dead = try b.arena.alloc([]bool, b.block_records.items.len);
    for (b.block_records.items, 0..) |recs, i| {
        dead[i] = try b.arena.alloc(bool, recs.items.len);
        @memset(dead[i], false);
    }

    for (b.ordered_funcs.items, 0..) |_, fi| {
        var uses = std.AutoHashMapUnmanaged(*const cfg.Value, u32).empty;
        defer uses.deinit(b.arena);
        var const_pos = std.AutoHashMapUnmanaged(*const cfg.Value, RecPos).empty;
        defer const_pos.deinit(b.arena);
        var def_pos = std.AutoHashMapUnmanaged(*const cfg.Value, RecPos).empty;
        defer def_pos.deinit(b.arena);
        const r = b.block_ranges.items[fi];

        // Pass 1: count every use of every value in the function, and
        // remember each const record's position and each value's
        // defining record's position — as block-local indices aligned
        // to the non-phi ordinals the emission stages used (phis
        // occupy no record, so they are skipped here too). Uses
        // inside phis and terminators count too (edge copies and the
        // terminator records read the value's slot, so the record
        // must survive unless every use fused).
        for (r.start..r.start + r.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) {
                    try countOpUses(ins.op, &uses, b.arena);
                    continue;
                }
                switch (ins.op) {
                    .const_ => try const_pos.put(b.arena, ins.results[0], .{ .bi = @intCast(bi), .idx = idx }),
                    else => {},
                }
                if (ins.results.len > 0) try def_pos.put(b.arena, ins.results[0], .{ .bi = @intCast(bi), .idx = idx });
                try countOpUses(ins.op, &uses, b.arena);
                // The expander emitted the immediate form for this
                // instruction (step 6), so it never reads the constant's
                // slot; drop that one use so a single-use constant is
                // still killed below.
                if (b.fused_instrs.contains(ins)) {
                    switch (ins.op) {
                        .div, .rem, .shl, .shr => |bin| decrementUse(&uses, bin.b),
                        else => {},
                    }
                }
                idx += try b.recordCount(blk, ins);
            }
            try countTermUses(blk.terminator, &uses, b.arena);
        }

        // Pass 2a (2.15): the multiply-accumulate and immediate-index
        // fusion. A `mul` followed by an `add` whose operand is the
        // mul result folds to `*_madd` (`dst = dst + b * c` — the
        // accumulator is read-modify-written in place, so it must be
        // consumed by the add and its slot becomes the result's); a
        // const multiplier folds to `*_maddi`. `const` + `read_index`
        // folds to `read_indexi`. The consumed instructions are
        // remembered so pass 2b never fuses them twice.
        for (r.start..r.start + r.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .add => |bin| try tryMadd(b, blk, idx, ins, bin, &uses, &def_pos, dead),
                    .read_index => |ri| {
                        if (constOf(ri.index)) |cv| {
                            // The literal index becomes the immediate
                            // when it fits the zero-extended 8-bit field
                            // (`read_indexi` zero-extends its imm — the
                            // same `[0, 127]` raw-pattern window the
                            // typed immediate helper gives unsigned
                            // ordering); a larger index stays a `const` +
                            // register read.
                            if (std.meta.activeTag(cv) == .int) {
                                const i = cv.int;
                                if (i >= 0 and i <= 127) {
                                    b.setR(blk, idx, .read_indexi, b.slotOf(ins.results[0]), b.slotOf(ri.base), @intCast(i));
                                    decrementUse(&uses, ri.index);
                                    try b.consumed_instrs.put(b.arena, ins, {});
                                }
                            }
                        }
                    },
                    else => {},
                }
                idx += try b.recordCount(blk, ins);
            }
        }

        // Pass 2b (2.14): the const+op immediate fusion. Instructions
        // consumed by pass 2a are skipped — their records were
        // deleted or rewritten already.
        for (r.start..r.start + r.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var idx: u32 = 0;
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (b.consumed_instrs.contains(ins) or b.fused_instrs.contains(ins)) {
                    idx += try b.recordCount(blk, ins);
                    continue;
                }
                switch (ins.op) {
                    .add, .sub, .mul, .div, .rem, .shl, .shr, .bitand, .bitor, .bitxor, .eq, .ne, .lt, .le, .gt, .ge => |bin| {
                        const tag = typedKind(std.meta.activeTag(ins.op));
                        const n = try b.recordCount(blk, ins);
                        if (try tryFuse(b, blk, @intCast(bi), idx, n, ins.results[0], tag, bin, dead)) |fused| {
                            decrementUse(&uses, fused);
                        }
                    },
                    else => {},
                }
                idx += try b.recordCount(blk, ins);
            }
        }

        // 2.15 results were coalesced during allocation, so all
        // instruction and descriptor operands already use the final
        // accumulator slot; no post-emission rewrite is needed.

        // Pass 3: a const record whose uses were all folded is dead —
        // the fused op reads its immediate, nothing reads the slot.
        // Only constants that had at least one use are candidates:
        // a never-used `const` (a text-AIR fixture) keeps its record —
        // eliminating dead records is not this pass's contract.
        var it = const_pos.iterator();
        while (it.next()) |e| {
            if (uses.getPtr(e.key_ptr.*)) |count| {
                if (count.* == 0) {
                    dead[e.value_ptr.*.bi][e.value_ptr.*.idx] = true;
                    try b.fused_consts.put(b.arena, e.key_ptr.*, {});
                }
            }
        }
    }

    // Compact each block's list in place: retain the records the
    // passes did not mark dead. Deletions only ever remove const or
    // mul records (never an edge copy or a terminator), and the
    // compaction is block-local — no record outside the block moves,
    // so no absolute-PC reference can go stale. 2.16 reads these
    // compacted lists.
    var after: u32 = 0;
    for (b.block_records.items, 0..) |*recs, bi| {
        const d = dead[bi];
        var kept = std.ArrayList(llir.Instr).empty;
        for (recs.items, 0..) |rec, i| {
            if (d[i]) continue;
            try kept.append(b.arena, rec);
        }
        recs.* = kept;
        const edge_len = b.edge_copy_counts.items[bi];
        const terms = b.terminatorRecordCount(b.ordered_blocks.items[bi]);
        b.non_phi_counts.items[bi] = @intCast(kept.items.len - edge_len - terms);
        after += @intCast(kept.items.len);
    }

    const metrics = FusionMetrics{
        .before_instrs = before,
        .after_instrs = after,
        .before_bytes = before * 4,
        .after_bytes = after * 4,
    };
    b.last_fusion = metrics;
    return metrics;
}

/// Fuse `bin` (a one-record arithmetic/comparison instruction at
/// block-local index `idx` of `blk`) with a constant operand.
/// Returns the fused constant's value, or null when no fusion applies.
/// The constant must sit in the second operand position, or be
/// reachable there: integer `eq`/`ne`/`add`/`mul` and bitwise operations commute;
/// ordering comparisons swap and flip.
/// `f32` never commutes; `sub`/`div`/`rem` are not
/// commutative at all. The immediate is the constant's raw bit
/// pattern; the type gates the variant via `typedOpcodeImm` (no
/// float immediate forms, no byte arithmetic, no bool/str forms). The
/// fused op replaces the instruction's register-form record; a fused
/// 32-bit shift count is pre-reduced mod 32 (the opcode masks it
/// again).
fn tryFuse(b: *Builder, blk: *const cfg.BasicBlock, bi: u32, idx: u32, n: u32, dst: *const cfg.Value, tag: llir.TypedKind, bin: cfg.Bin, dead: [][]bool) error{OutOfMemory}!?*const cfg.Value {
    // The primary record's position: the register-form opcode, when
    // the family has one (comparisons on integer `gt`/`le`/`ge` lower
    // through swapped aliases — their C-Type record is the base).
    const site: u32 = blk: {
        if (llir.typedOpcode(tag, bin.a.type_, undefined)) |reg| {
            for (idx..idx + n) |i| {
                const d = llir.decode(b.block_records.items[bi].items[i]) orelse continue;
                if (d.op == reg) break :blk @intCast(i);
            }
            return null;
        }
        break :blk idx;
    };
    if (constOf(bin.b)) |cv| {
        // Constant on the right: direct fusion when it fits the 8-bit
        // immediate field at the operand type.
        if (llir.typedOpcodeImm(tag, bin.a.type_)) |op| {
            if (immOf(cv, tag, bin.a.type_)) |imm| {
                const imm2 = typed.shiftImm(op, imm);
                if (llir.formatOf(op) == .c)
                    b.setC(blk, site, op, b.slotOf(bin.a), imm2)
                else
                    b.setR(blk, site, op, b.slotOf(dst), b.slotOf(bin.a), imm2);
                killFusedCmpNot(b, bi, site, tag, bin, dead);
                return bin.b;
            }
        }
        return null; // this type/op has no immediate form, or the constant does not fit
    }
    if (constOf(bin.a)) |cv| {
        if (flipCmp(tag)) |flipped| {
            if (llir.typedOpcodeImm(flipped, bin.b.type_)) |op| {
                if (immOf(cv, flipped, bin.b.type_)) |imm| {
                    b.setC(blk, site, op, b.slotOf(bin.b), imm);
                    killFusedCmpNot(b, bi, site, tag, bin, dead);
                    return bin.a;
                }
            }
            return null;
        }
        // Commute an integer `eq`/`ne`/`add`/`mul` (`k + b` →
        // `b + k`). Never the f32 forms — NaN-payload ordering is
        // observable and the AIR does not commute floats.
        if (isCommutative(tag) and Builder.isInteger(bin.b.type_)) {
            if (llir.typedOpcodeImm(tag, bin.b.type_)) |op| {
                if (immOf(cv, tag, bin.b.type_)) |imm| {
                    const imm2 = typed.shiftImm(op, imm);
                    if (llir.formatOf(op) == .c)
                        b.setC(blk, site, op, b.slotOf(bin.b), imm2)
                    else
                        b.setR(blk, site, op, b.slotOf(dst), b.slotOf(bin.b), imm2);
                    return bin.a;
                }
            }
        }
    }
    return null;
}

/// The integer `le`/`ge` comparisons emit as `not(slt)` — the
/// non-strict predicate is the negation of `lt` (emitCompare's
/// `cmpSel`, `invert = true`). Fusing such a comparison to its
/// immediate form leaves the trailing `not cond` behind: the fused op
/// (e.g. `sgti a, k-1` for `a >= k`) already carries the non-strict
/// polarity, so the `not` double-negates the result. Mark it dead.
fn killFusedCmpNot(b: *Builder, bi: u32, site: u32, tag: llir.TypedKind, bin: cfg.Bin, dead: [][]bool) void {
    const inverts = (tag == .le or tag == .ge) and
        (Builder.isInteger(bin.a.type_) or Builder.isInteger(bin.b.type_));
    if (!inverts) return;
    const nd = llir.decode(b.block_records.items[bi].items[site + 1]) orelse return;
    if (nd.op != .not) return; // defensive: the not always follows in the invert form
    dead[bi][site + 1] = true;
}

/// 2.15: fuse a `mul` + `add` pair into `*_madd`/`*_maddi` at the
/// add's block-local record index (Instruction Set §5, Fused
/// multiply-accumulate). The pattern: the add's operand that is a
/// `mul` result — its second operand, or its first when the add is
/// an integer `add` that may be commuted (the `f32` forms never
/// reorder the addition). Both the mul result and the accumulator
/// must be consumed by exactly this add: the fused record is
/// `dst = dst + b * c`, writing the accumulator's slot
/// read-modify-write, so the accumulator must have no other reader
/// and the result's slot is remapped to it. The product's operand
/// order is preserved (`b`, `c` = the mul's operands); a constant
/// multiplier folds to `*_maddi` (imm = the constant's raw bit
/// pattern — a left-hand constant only for integer `mul`, which is
/// commutative; an `f32` left-hand constant stays a plain `*_madd`
/// reading the constant's slot). The mul record is deleted
/// (per-block dead mark, consumed by the peephole compaction); both
/// instructions are recorded as consumed.
fn tryMadd(b: *Builder, blk: *const cfg.BasicBlock, idx: u32, ins: *const cfg.Instr, bin: cfg.Bin, uses: *std.AutoHashMapUnmanaged(*const cfg.Value, u32), def_pos: *const std.AutoHashMapUnmanaged(*const cfg.Value, RecPos), dead: [][]bool) error{OutOfMemory}!void {
    // The product operand: the add's second operand, or its first
    // when the add is an integer add (commuted). f32 never
    // reorders the addition.
    const product = blk: {
        if (patterns.isMulResult(bin.b)) break :blk bin.b;
        if (patterns.isMulResult(bin.a) and Builder.isInteger(bin.b.type_)) break :blk bin.a;
        return;
    };
    const acc = if (product == bin.b) bin.a else bin.b;
    if (product == acc) return; // `add %m, %m` — not a madd shape
    if ((uses.get(product) orelse 0) != 1) return; // mul result must be consumed here
    if ((uses.get(acc) orelse 0) != 1) return; // accumulator must be consumed here
    const product_pos = def_pos.get(product) orelse return;
    if (product_pos.bi != b.block_ids.get(blk).?) return;
    // The mul's record immediately precedes the add: the typed mul is
    // exactly one record (Instruction Set §4), no canonicalization in
    // between.
    if (product_pos.idx + 1 != idx) return;

    const mul = product.def.?.op.mul; // Bin{a, b} — the product's operand order
    const t = product.type_;
    const acc_slot = b.slotOf(acc);
    // The fused record replaces the add record. The fused record is
    // written at the add's index; the mul record is deleted.
    const fused_idx: u32 = idx;
    if (constOf(mul.b)) |cv| {
        // Constant multiplier on the right: `*_maddi` when the constant
        // fits the 8-bit immediate field (order preserved); otherwise
        // the site stays a plain `*_madd` reading the constant's slot.
        const op = llir.maddiOpcode(t) orelse return;
        if (immOf(cv, .mul, t)) |imm| {
            b.setR(blk, fused_idx, op, acc_slot, b.slotOf(mul.a), imm);
            decrementUse(uses, mul.b);
        } else {
            const mo = llir.maddOpcode(t) orelse return;
            b.setR(blk, fused_idx, mo, acc_slot, b.slotOf(mul.a), b.slotOf(mul.b));
        }
    } else if (constOf(mul.a)) |cv| {
        if (Builder.isInteger(t)) {
            // Integer `mul` commutes: `*_maddi` with the constant
            // multiplier as the immediate, when it fits; otherwise a
            // plain `*_madd` reading the constant's slot.
            const op = llir.maddiOpcode(t) orelse return;
            if (immOf(cv, .mul, t)) |imm| {
                b.setR(blk, fused_idx, op, acc_slot, b.slotOf(mul.b), imm);
                decrementUse(uses, mul.a);
            } else {
                const mo = llir.maddOpcode(t) orelse return;
                b.setR(blk, fused_idx, mo, acc_slot, b.slotOf(mul.b), b.slotOf(mul.a));
            }
        } else {
            // f32 preserves the mul operand order: a plain `*_madd`
            // reads the constant from its slot.
            const op = llir.maddOpcode(t) orelse return;
            b.setR(blk, fused_idx, op, acc_slot, b.slotOf(mul.a), b.slotOf(mul.b));
        }
    } else {
        const op = llir.maddOpcode(t) orelse return;
        b.setR(blk, fused_idx, op, acc_slot, b.slotOf(mul.a), b.slotOf(mul.b));
    }
    // Allocation already put the add result in the accumulator's slot.
    // Both instructions are consumed: the add record is deleted (the
    // fused record stands in its place) and the mul is deleted.
    try b.consumed_instrs.put(b.arena, ins, {});
    try b.consumed_instrs.put(b.arena, product.def.?, {});
    const pos = def_pos.get(product).?;
    dead[pos.bi][pos.idx] = true;
    // The product is computed internally, so the fused record reads
    // neither mul operand's product slot. The accumulator, however, is
    // the read-modify-write dst — the fused record reads the acc slot
    // (`dst = dst + b*c`), so the acc's defining record (a const that
    // loaded the slot) must survive: keep its use count.
    decrementUse(uses, product);
}

// Fused results are coalesced during allocation, so descriptors and
// later records already use the accumulator's physical slot.

// ---------------------------------------------------------------------------
// v1 ownership fusions (Instruction Set §4) — optional peepholes over the
// lifecycle records. Each rewrite is equivalent to its expansion in
// reference-count effect, execution order, trap behavior, and result:
//
//   release d; copy_retain d, s  =>  replace_copy d, s
//   release d; move_ d, s        =>  replace_move d, s   (counted source)
//   release x; ret result        =>  release_ret result, x
//
// Precondition note (Instruction Set §4): `replace_copy` forms only where the
// retain is infallible and the release has no observable user effect —
// true for every counted value this lowering emits (RC headers with
// saturating counts, no user hooks on counted release).
