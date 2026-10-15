//! Pass: CFG → LLIR control emission. In: the `Builder` after the
//! body emission and edge-copy passes (every block's record list has
//! its instructions and edge copies, and the terminator position is
//! reserved by budget). Out: each block's terminator records at the
//! end of its list — `ret`, `j`, the fused `br` pair (or single
//! branch when a target falls through), `switch` with its descriptor,
//! `tailcall_self` with its `slot_*` preparation and leftover-owner
//! kills, and `trap`. Targets are **not stored in the records**: the
//! target is a pure function of the block's terminator and the
//! emission form, which the budget tables fix — linearization derives
//! each B-type/`jal` target from the CFG (and the +2 skip marker of a
//! long-branch-expanded branch) when it resolves the offsets, while
//! `switch_arms` rows hold symbolic `BlockId`s until then. This pass
//! also owns the fused-branch recognition (register/immediate/bit-test
//! forms), the inversion table, and the fall-through selection — the
//! branch queries the budgeting pass and the allocator share through
//! the Builder shims (Stilla LLIR Specification §1).

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");
const intern = @import("cfg_lower_llir_intern.zig");
const edges = @import("cfg_lower_llir_edges.zig");
const emit = @import("cfg_lower_llir_emit.zig");
const typed = @import("cfg_lower_typed.zig");

const Builder = lower.Builder;

/// Emit every block's terminator records at the end of its record
/// list, after the instructions and edge copies.
pub fn run(bld: *Builder) error{OutOfMemory}!void {
    for (bld.ordered_blocks.items) |blk| {
        const bi = bld.block_ids.get(blk).?;
        const idx = bld.non_phi_counts.items[bi] + bld.edge_copy_counts.items[bi];
        switch (blk.terminator) {
            .ret => |v| bld.setE(blk, idx, .ret, if (v) |rv| retSlot(bld, rv) else llir.zero_reg, 0),
            .j => bld.setJ(blk, idx, 0), // target derived at linearization
            .br => |b| {
                // A CFG `br` (one instruction, two targets) has no
                // single LLIR image: the record pair here is a
                // B-type compare-and-branch targeting the then-block
                // followed by the unconditional `j` targeting
                // the else-block. The branch
                // falls into the `j` when the condition is false,
                // and the 20-bit `j` carries the long reach.
                //
                // Trailing-j elimination: when one target is the
                // next block in the layout the pair collapses to a
                // single compare-and-branch whose fall-through
                // carries that target — the else target falls
                // through directly (loops, void-body guards), or
                // the condition inverts and the then body falls
                // through (if-else, if-without-else with a
                // value-ful body). `terminatorRecordCount` made the
                // same call during `budget`, so the reserved record
                // count matches what is emitted here. The inverted
                // form additionally requires an invertible branch
                // (never a float `blt`/`ble` — NaN-unsafe) and the
                // else target within the branch's ±512 reach
                // (checked against the conservative budget tables);
                // an out-of-reach branch is not a compile error
                // here — the long-branch expansion (inverted +
                // skip + `j`, or the float trampoline, the
                // safety net) covers it.
                //
                // Fused form: when the condition value is defined
                // by a comparison of the typed families, the branch
                // reads the two compared operands directly
                // (`beq`/`bne`/`blt`/`ble` per rep, `bltu`/`bleu` for
                // unsigned), selects an immediate branch
                // (`blti`/`bltiu`/`bgti`/`bgtiu`/`beqi`/`bnei`) when the
                // RHS is a fittable constant, or a bit-test branch
                // (`tbz`/`tbnz`) for `(x & 2^k) ==/!= 0`; otherwise
                // it tests the bool against the zero register
                // (`bne cond, zero`). The comparison record
                // itself stays in place — removing it is a dead-code
                // pass's job.
                // The target fields are written 0: linearization derives
                // them from the emission form.
                const fused = fusedBranchOperands(b.cond);
                if (bld.terminatorRecordCount(blk) == 1) {
                    // One record: the branch, whose fall-through is
                    // the other target.
                    const next = nextBlockOf(bld, bi).?;
                    emitBranch(bld, blk, idx, b.cond, fused, next == b.then_);
                } else {
                    emitBranch(bld, blk, idx, b.cond, fused, false);
                    bld.setJ(blk, idx + 1, 0); // trailing j: target derived at linearization
                }
            },
            .@"switch" => |s| {
                const desc = try intern.internSwitchDesc(bld, blk, s.arms);
                bld.setI(blk, idx, .switch_, bld.slotOf(s.disc), desc);
            },
            .tailcall => {
                // v1: `slot_*` preparation first (one per
                // parameter at its window offset), then the leftover-
                // owner kills, then the jump — same frame, header and
                // size preserved.
                const prep = try edges.tailcallPrepRecords(bld, blk);
                // edge_copy_counts already includes the overhead, so
                // the records go at [idx - prep.len, idx). The
                // `slot_*` preparation records are I-Type; the
                // leftover-owner kills are E-Type `release` records.
                const base = idx - @as(u32, @intCast(prep.len));
                for (prep, 0..) |rec, ri| {
                    if (llir.formatOf(rec.op) == .i) {
                        bld.setI(blk, base + @as(u32, @intCast(ri)), rec.op, rec.dst, rec.imm);
                    } else {
                        bld.setE(blk, base + @as(u32, @intCast(ri)), rec.op, rec.dst, rec.src);
                    }
                }
                bld.setE(blk, idx, .tailcall_self, 0, 0);
            },
            .trap => bld.setE(blk, idx, .trap, 0, 0),
        }
    }
}

/// The result register of a `ret`: the value's slot, or `zero` when
/// the function returns void (the CFG's void phantoms carry a
/// maxInt id and no slot row — never name one). Writing `zero`
/// discards the result.
fn retSlot(bld: *const Builder, v: *const cfg.Value) llir.SlotId {
    if (v.type_ == .primitive and v.type_.primitive == .void) return llir.zero_reg;
    return bld.slotOf(v);
}

/// Emit one compare-and-branch record: the fused register/immediate/
/// bit-test form, or the general bool test `bne/beq cond, zero`.
/// `inverted` flips the polarity (the trailing-jal elimination's
/// inverted one-record form — only reachable when
/// `terminatorRecordCount` verified the branch is invertible).
fn emitBranch(bld: *Builder, blk: *const cfg.BasicBlock, idx: u32, cond: *const cfg.Value, fused: ?FusedBranch, inverted: bool) void {
    if (fused) |f| {
        switch (f) {
            .reg => |r| if (inverted) blk: {
                const inv = invertBranch(r.op).?;
                // the integer ordering pairs swap their operands on
                // inversion (`!(a<b) ≡ ble b,a`)
                break :blk bld.setB(blk, idx, inv.op, if (inv.swap) bld.slotOf(r.rhs) else bld.slotOf(r.lhs), if (inv.swap) bld.slotOf(r.lhs) else bld.slotOf(r.rhs), 0);
            } else bld.setB(blk, idx, r.op, bld.slotOf(r.lhs), bld.slotOf(r.rhs), 0),
            .imm => |i| bld.setB(blk, idx, if (inverted) invertBranch(i.op).?.op else i.op, bld.slotOf(i.lhs), i.imm7, 0),
            .bit => |t| bld.setB(blk, idx, if (inverted) invertBranch(t.op).?.op else t.op, bld.slotOf(t.tested), t.bit, 0),
        }
    } else {
        bld.setB(blk, idx, if (inverted) .beq else .bne, bld.slotOf(cond), llir.zero_reg, 0);
    }
}

/// The next block in `ordered_blocks` when `bi` is not the last of
/// its function — the fall-through successor of `bi` in the final
/// linear layout. Null for a function's last block. Shared by the
/// trailing-j decision (`terminatorRecordCount`) and the branch-target
/// derivation (`llir_linearize.branchTargetOf`) through the Builder
/// shim.
pub fn nextBlockOf(bld: *const Builder, bi: u32) ?*const cfg.BasicBlock {
    const r = bld.block_ranges.items[bld.funcIndexOfBlock(bld.ordered_blocks.items[bi])];
    if (bi + 1 < r.start + r.len) return bld.ordered_blocks.items[bi + 1];
    return null;
}

/// The fused compare-and-branch for a condition value: when the
/// condition is defined by a comparison of the typed families
/// (`lt`/`le`/`gt`/`ge`/`eq`/`ne`) over live numeric operands, the
/// branch compares the two operands directly instead of testing the
/// bool against zero — the B-type register form (`beq`/`bne`/
/// `blt`/`ble` per rep, `bltu`/`bleu` for unsigned, the polarity and
/// operand order carrying `le`/`ge`), the immediate form
/// (`blti`/`bltiu`/`bgti`/`bgtiu`/`beqi`/`bnei`) when an integer
/// operand is a constant that fits the imm7 window, or the bit-test
/// form (`tbz`/`tbnz`) for `(x & 2^k) ==/!= 0`. Null otherwise — a
/// bool/str comparison, a float constant, or any other condition
/// — those stay `bne cond, zero`. The comparison may live in
/// any block (its operands dominate the branch by SSA); the check
/// that the const-folding peephole can
/// never strand this branch on a dead slot.
/// Shared with the budgeting pass (`terminatorRecordCount` reads
/// the fused branch's invertibility) and the allocator
/// (`fusedBranchReads`) through the Builder shims.
pub const FusedBranch = union(enum) {
    reg: struct { op: llir.Opcode, lhs: *const cfg.Value, rhs: *const cfg.Value },
    imm: struct { op: llir.Opcode, lhs: *const cfg.Value, imm7: u8 },
    bit: struct { op: llir.Opcode, tested: *const cfg.Value, bit: u8 },
};

pub fn fusedBranchOperands(cond: *const cfg.Value) ?FusedBranch {
    const d = cond.def orelse return null;
    const tag = std.meta.activeTag(d.op);
    if (tag != .lt and tag != .le and tag != .gt and tag != .ge and tag != .eq and tag != .ne) return null;
    const bin: cfg.Bin = switch (d.op) {
        .lt, .le, .gt, .ge, .eq, .ne => |b| b,
        else => unreachable,
    };
    // The bit-test form: `(x & 2^k) == 0` → `tbz x, k`,
    // `(x & 2^k) != 0` → `tbnz x, k`.
    if (tag == .eq or tag == .ne) {
        if (bitTestPattern(bin)) |bt| {
            return .{ .bit = .{ .op = if (tag == .eq) .tbz else .tbnz, .tested = bt.x, .bit = bt.bit } };
        }
    }
    // The immediate form: an integer comparison with a constant
    // operand that fits the imm7 window. A
    // constant on the left swaps and flips the operator.
    if (Builder.isInteger(bin.a.type_) or Builder.isInteger(bin.b.type_)) {
        if (constOf(bin.b)) |cv| {
            if (immBranchOf(tag, bin.a, cv, false)) |f| return f;
        } else if (constOf(bin.a)) |cv| {
            if (immBranchOf(tag, bin.b, cv, true)) |f| return f;
        }
    }
    // The register form: both operands are live numeric values. A
    // bool/str equality condition (`bool_eq`/`bool_ne`/`str_eq`/
    // `str_ne`, which `cmpSel` selects) has no numeric ordering
    // branch, so reject it here — the caller tests the condition
    // against zero (`bne cond, zero` / `beq cond, zero`) instead of
    // falling through to the unsigned-order branch family
    // (Instruction Set §5.1).
    const numeric = Builder.isInteger(bin.a.type_) or bin.a.type_.primitive == .float32 or bin.a.type_.primitive == .float64;
    if (!numeric) return null;
    if (isConstValue(bin.a) or isConstValue(bin.b)) return null;
    const sel = emit.cmpSel(tag, bin);
    if (!llir.opInfo(sel.op).writes_cond) return null;
    var op: llir.Opcode = undefined;
    if (typed.isNonStrictInt(tag, bin.a.type_)) {
        // Integer `le`/`ge` select the single non-strict `ble`/`bleu`.
        // `cmpSel` already put `ge`'s operands in the `ble`-natural
        // order (`a <= b` → `ble a, b`, `a >= b` → `ble b, a`), so no
        // further swap applies. There is no `bge` family.
        op = famOpName(if (bin.a.type_.primitive == .uint32 or bin.a.type_.primitive == .uint64 or bin.a.type_.primitive == .byte) "bleu" else "ble", null) orelse unreachable;
    } else if ((bin.a.type_.primitive == .float32 or bin.a.type_.primitive == .float64) and (tag == .le or tag == .ge)) {
        // Float `le`/`ge` share the single `sle` primitive; the
        // fused branch is the non-strict `ble`, the swap for `ge`
        // already baked into cmpSel (`a >= b` ≡ `ble b, a` — the
        // swap preserves the NaN behavior of every predicate,
        // No further swap here.
        op = famOpName("ble", llir.repOf(sel.op)) orelse unreachable;
    } else {
        op = branchOf(sel.op) orelse return null;
    }
    return .{ .reg = .{ .op = op, .lhs = sel.a, .rhs = sel.b } };
}

/// The values a fused compare-and-branch of `cond` reads at the
/// terminator (the register form reads both operands; the
/// immediate/bit-test forms read the tested value). The slot-allocation
/// allocator keeps these live to the terminator so the
/// comparison's `copy dst, cond` materialization cannot clobber
/// them before the branch reads them (llir_alloc.zig markTermUses).
pub const BranchReads = struct { a: *const cfg.Value, b: ?*const cfg.Value = null };
pub fn fusedBranchReads(cond: *const cfg.Value) ?BranchReads {
    const f = fusedBranchOperands(cond) orelse return null;
    return switch (f) {
        .reg => |r| .{ .a = r.lhs, .b = r.rhs },
        .imm => |i| .{ .a = i.lhs },
        .bit => |t| .{ .a = t.tested },
    };
}

/// The immediate-branch selection: `lhs op imm` with the constant on
/// the right fuses to `blti`/`bgti`/`beqi`/`bnei`. A constant on the
/// left swaps and flips the operator first (`k < a` ≡ `a > k`, the shared
/// `typed.swapRel`). The non-strict `le`/`ge` then fold to their strict
/// predecessor with the constant adjusted by ±1 at compile time through
/// the shared `typed.strictFold` (`a <= k` ≡ `a < k+1` → `blti a, k+1`;
/// `a >= k` ≡ `a > k-1` → `bgti a, k-1`) — the same immediate-only
/// transform the value form uses, which spares the register form's
/// materialized constant. The immediate window is the E-type
/// `typed.immOf` window: `blti`/`bgti` mirror `slti`/`sgti`
/// (sign-extend), `bltiu`/`bgtiu` `sltiu`/`sgtiu` (zero-extend), and
/// `beqi`/`bnei` `seqi`/`snei` (sign-extend on every integer type). The
/// immediate family is chosen by the value operand's type.
fn immBranchOf(tag: cfg.OpTag, value: *const cfg.Value, cv: meta.ConstValue, const_left: bool) ?FusedBranch {
    // Move the constant to the right operand position (`k op a` ≡
    // `a swapRel(op) k`); equality is symmetric.
    const moved: cfg.OpTag = if (const_left) typed.swapRel(tag) orelse tag else tag;
    // Fold the non-strict ordering to its strict predecessor, adjusting
    // the constant at compile time — the shared ±1 transform.
    const folded = typed.strictFold(moved, cv) orelse return null;
    const imm7 = typed.immOf(folded.cv, folded.tag, value.type_) orelse return null;
    const b: []const u8 = switch (folded.tag) {
        .lt => "blti",
        .gt => "bgti", // a > k
        .eq => "beqi",
        .ne => "bnei",
        else => return null,
    };
    const unsigned = value.type_.primitive == .uint32 or value.type_.primitive == .uint64 or value.type_.primitive == .byte;
    const name = if (unsigned and std.mem.eql(u8, b, "blti"))
        "bltiu"
    else if (unsigned and std.mem.eql(u8, b, "bgti"))
        "bgtiu"
    else
        b;
    return .{ .imm = .{ .op = famOpName(name, null) orelse return null, .lhs = value, .imm7 = imm7 } };
}

/// The `(x & 2^k) ==/!= 0` bit-test pattern: one operand is a
/// `bitand` with a power-of-two constant, the other the constant 0.
/// The mask is read as its raw 64-bit cell pattern, so a literal
/// with the sign bit set (a negative `i64`/`u64` constant, bit 63)
/// is still a valid single-bit test — the cell is 64 bits wide and
/// every bit 0..63 is a legal `tbz`/`tbnz` index. A mask that is
/// not one bit (zero or several) never forms a bit-test.
fn bitTestPattern(bin: cfg.Bin) ?struct { x: *const cfg.Value, bit: u8 } {
    const andv = if (isAndOfPow2(bin.a)) bin.a else if (isAndOfPow2(bin.b)) bin.b else return null;
    const other = if (andv == bin.a) bin.b else bin.a;
    const ocv = constOf(other) orelse return null;
    if (std.meta.activeTag(ocv) != .int or ocv.int != 0) return null;
    const av = andv.def.?.op.bitand;
    const maskv = constOf(av.b) orelse return null;
    if (std.meta.activeTag(maskv) != .int) return null;
    const raw: u64 = @bitCast(maskv.int);
    if (raw == 0 or (raw & (raw - 1)) != 0) return null; // not a single bit
    const k: u6 = @intCast(@ctz(raw));
    // A 64-bit single-bit mask names a bit index in 0..63, so the
    // structural validator's `tbz`/`tbnz` ≥64 rejection can never
    // fire on a lowering-produced image.
    return .{ .x = av.a, .bit = k };
}

fn isAndOfPow2(v: *const cfg.Value) bool {
    const d = v.def orelse return false;
    if (std.meta.activeTag(d.op) != .bitand) return false;
    const b = d.op.bitand;
    if (constOf(b.b)) |cv| {
        if (std.meta.activeTag(cv) != .int) return false;
        const raw: u64 = @bitCast(cv.int);
        return raw != 0 and (raw & (raw - 1)) == 0;
    }
    return false;
}

/// The E-type comparison → B-Type branch family (`seq`→`beq`,
/// `sne`→`bne`, `slt`→`blt`, `sltu`→`bltu`). Null for any other
/// family, so a new comparison family cannot silently become `bltu`
/// (Instruction Set §5.1): the float `sle` never reaches here — the
/// `le`/`ge` fusion selects `ble` in `fusedBranchOperands` — and a
/// bool/str equality never reaches here either, because the register
/// form rejects non-numeric operands before selecting it.
fn branchOf(op: llir.Opcode) ?llir.Opcode {
    const base = familyOf(op);
    const bbase: []const u8 = if (std.mem.eql(u8, base, "seq"))
        "beq"
    else if (std.mem.eql(u8, base, "sne"))
        "bne"
    else if (std.mem.eql(u8, base, "slt"))
        "blt"
    else if (std.mem.eql(u8, base, "sltu"))
        "bltu"
    else
        return null;
    return famOpName(bbase, llir.repOf(op));
}

/// The family prefix of an opcode name (the part before the `.` rep
/// suffix, or the whole name for untyped opcodes).
fn familyOf(op: llir.Opcode) []const u8 {
    const info = llir.opInfo(op);
    const dot = std.mem.indexOfScalar(u8, info.name, '.');
    return if (dot) |d| info.name[0..d] else info.name;
}

/// The branch opcode of family `base` at `rep` — comptime name
/// lookup over the canonical table, accepting both dotted and bare
/// names (`famOpName("tbz", null)` = `.tbz`).
fn famOpName(base: []const u8, rep: ?llir.Rep) ?llir.Opcode {
    inline for (std.meta.tags(llir.Opcode)) |op| {
        const info = llir.opInfo(op);
        if (info.rep == rep) {
            const dot = std.mem.indexOfScalar(u8, info.name, '.');
            if (dot) |d| {
                if (std.mem.eql(u8, info.name[0..d], base)) return op;
            } else {
                if (std.mem.eql(u8, info.name, base)) return op;
            }
        }
    }
    return null;
}

/// The inverse of a branch: a `(op, swap)` pair. `swap` is true for
/// the integer ordering pairs — `!(a < b) ≡ a >= b ≡ ble b, a`, so
/// `blt`/`bltu` must exchange their operands when inverted to
/// `ble`/`bleu`. `beq ↔ bne` (incl. the float equality forms),
/// `beqi ↔ bnei`, and `tbz ↔ tbnz` invert with no swap. Float
/// `blt`/`ble` (NaN-ordered — both false on NaN, so not
/// complementary) and the immediate `blti`/`bltiu`/`bgti`/`bgtiu`
/// (no `bgei`) have no inverse — null.
/// True when the branch's predicate may be inverted for the
/// long-branch expansion and the inverted one-record form.
pub const BranchInverse = struct { op: llir.Opcode, swap: bool = false };
/// Shared by the control emission (the inverted one-record form,
/// `terminatorRecordCount`) and the linearization (the long-branch
/// expansion in `llir_linearize.run`) through the Builder shim.
pub fn invertBranch(op: llir.Opcode) ?BranchInverse {
    const rep = llir.repOf(op);
    const base = familyOf(op);
    if (std.mem.eql(u8, base, "beq")) return .{ .op = famOpName("bne", rep).? };
    if (std.mem.eql(u8, base, "bne")) return .{ .op = famOpName("beq", rep).? };
    if (std.mem.eql(u8, base, "blt")) return if (rep == .f32 or rep == .f64) null else .{ .op = famOpName("ble", rep).?, .swap = true };
    if (std.mem.eql(u8, base, "ble")) return if (rep == .f32 or rep == .f64) null else .{ .op = famOpName("blt", rep).?, .swap = true };
    if (std.mem.eql(u8, base, "bltu")) return .{ .op = famOpName("bleu", rep).?, .swap = true };
    if (std.mem.eql(u8, base, "bleu")) return .{ .op = famOpName("bltu", rep).?, .swap = true };
    if (std.mem.eql(u8, base, "beqi")) return .{ .op = .bnei };
    if (std.mem.eql(u8, base, "bnei")) return .{ .op = .beqi };
    if (std.mem.eql(u8, base, "tbz")) return .{ .op = .tbnz };
    if (std.mem.eql(u8, base, "tbnz")) return .{ .op = .tbz };
    return null;
}

/// The constant payload of a value whose defining instruction is a
/// `const_`, or null for every other value.
fn constOf(v: *const cfg.Value) ?meta.ConstValue {
    const d = v.def orelse return null;
    return switch (d.op) {
        .const_ => |cv| cv,
        else => null,
    };
}

fn isConstValue(v: *const cfg.Value) bool {
    const d = v.def orelse return false;
    return std.meta.activeTag(d.op) == .const_;
}
