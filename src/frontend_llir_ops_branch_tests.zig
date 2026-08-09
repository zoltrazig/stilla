//! Test file: `frontend LLIR ops, branch &amp; codec` — LLIR lowering stage
//! 3.3 (immediate &amp; branch relaxation): fused-arithmetic windows, B-type
//! windows, tbz/tbnz recognition, branch inversions and operand-swap
//! aliases, far-branch trampolines, and the offs10/imm20 codec windows.
//! Split out of `frontend_llir_ops_tests.zig`; the `branchOfFunc`,
//! `branch_pc_of`, and `check_trampoline` helpers are local to this file.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const ast = @import("ast.zig");
const llir = @import("llir.zig");
const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");
const lower = @import("lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const cfg_validate = @import("passes/cfg_validate.zig");
const llir_validate = @import("passes/llir_validate.zig");
const interpreter = @import("interpreter.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const findBlock = helpers.findBlock;
const blockIdx = helpers.blockIdx;
const findFunc = helpers.findFunc;

// ---------------------------------------------------------------------------
// 3.3 — immediate & branch relaxation (TODO.md §3.3). These tests pin the
// fused-immediate windows (R-type signed `[-64,63]` / unsigned `[0,127]`,
// B-type imm7 signed/unsigned), the `tbz`/`tbnz` bit-index recognition
// (0..63, sign-bit masks as raw cell bits), the operand-swap aliases and
// branch inversions (`beq↔bne` incl. float, `blt↔ble`/`bltu↔bleu` with
// operand exchange, `beqi↔bnei`, `tbz↔tbnz`), the signed offs10 ±512 and
// imm20 ±2¹⁹ windows, and the long-branch expansion — the inverted
// `+2`-skip form versus the non-inverting trampoline that f32/f64
// ordered `blt`/`ble` (NaN) and the complement-less `blti`/`bltiu` use.
// Everything decodes the lowered image directly. `expansion_rounds` on the
// Builder counts the relaxation rounds (1 = no branch grew a target).
// ---------------------------------------------------------------------------

/// The branch terminator of the named function: the first B-format record in
/// its blocks' code (each test function here has exactly one `br`).
fn branchOfFunc(
    program: *const cfg.IrProgram,
    b: *const cfg_lower_llir.Builder,
    image: llir.LlirProgram,
    fname: []const u8,
) llir.Decoded {
    const f = findFunc(program, fname);
    const fi = b.func_ids.get(f).?;
    const range = b.block_ranges.items[fi];
    for (range.start..range.start + range.len) |bi| {
        const blk = b.ordered_blocks.items[bi];
        var pc = b.pcOf(blk);
        const end = image.blocks[b.block_ids.get(blk).?].end_pc;
        while (pc < end) : (pc += 1) {
            const d = llir.decode(image.instructions[pc]).?;
            if (llir.formatOf(d.op) == .b) return d;
        }
    }
    unreachable;
}

/// The PC of a function's single B-type branch terminator (its first
/// B-format record, as `branchOfFunc` finds).
fn branch_pc_of(
    program: *const cfg.IrProgram,
    b: *const cfg_lower_llir.Builder,
    image: llir.LlirProgram,
    fname: []const u8,
) u32 {
    const f = findFunc(program, fname);
    const fi = b.func_ids.get(f).?;
    const range = b.block_ranges.items[fi];
    for (range.start..range.start + range.len) |bi| {
        const blk = b.ordered_blocks.items[bi];
        var pc = b.pcOf(blk);
        const end = image.blocks[b.block_ids.get(blk).?].end_pc;
        while (pc < end) : (pc += 1) {
            const d = llir.decode(image.instructions[pc]).?;
            if (llir.formatOf(d.op) == .b) return pc;
        }
    }
    unreachable;
}

/// The three-record non-inverting trampoline: `P lhs, rhs, +2` then
/// `j, +2` (the committed skip) then `j, far_target` — the
/// predicate, when true, skips the second `j` into the far jump; when
/// false, the second `j` skips the far jump. `far_pc` is the branch
/// target; the +2-skip must never be rewritten (its imm20 stays 2).
fn check_trampoline(
    image: llir.LlirProgram,
    br_pc: u32,
    predicate: llir.Opcode,
    far_target_pc: u32,
) !void {
    const br = llir.decode(image.instructions[br_pc]).?;
    try testing.expectEqual(predicate, br.op);
    try testing.expectEqual(@as(i16, 2), br.offs10);
    const skip = llir.decode(image.instructions[br_pc + 1]).?;
    try testing.expectEqual(llir.Opcode.j, skip.op);
    try testing.expectEqual(@as(i32, 2), skip.imm20); // the +2 skip stays final
    const far = llir.decode(image.instructions[br_pc + 2]).?;
    try testing.expectEqual(llir.Opcode.j, far.op);
    try testing.expectEqual(far_target_pc, llir.jalTarget(br_pc + 2, far.imm20));
}

test "3.3 LLIR lowering: fused arithmetic immediates pin the signed/unsigned windows" {
    // i32 `add`: -64 and 63 fuse to `addi` (raw imm7: -64 → 0x40);
    // -65 and 64 fall back to register-form `add`. u32 `add`: 127
    // fuses to `addiu`, 128 stays `add` (Instruction Set §3.3,
    // §10 — the sign-extended-decode forms carry `[-64, 63]`).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @s(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const -65
        \\        %2: int32 = add %0, %1
        \\        %3: int32 = const -64
        \\        %4: int32 = add %2, %3
        \\        %5: int32 = const 63
        \\        %6: int32 = add %4, %5
        \\        %7: int32 = const 64
        \\        %8: int32 = add %6, %7
        \\        ret %8
        \\    }
        \\    func @u(a: uint32) -> uint32 {
        \\    entry:
        \\        %1: uint32 = const 127
        \\        %2: uint32 = add %0, %1
        \\        %3: uint32 = const 128
        \\        %4: uint32 = add %2, %3
        \\        ret %4
        \\    }
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }

    var n: usize = 0;
    var n_reg: usize = 0;
    var n_u: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec).?;
        switch (d.op) {
            .addi => {
                n += 1;
                try testing.expect(d.c == 0x40 or d.c == 63); // -64 and 63
            },
            // `add` is widthless: the out-of-window constants (-65, 64,
            // 128) all stay the register form.
            .add => n_reg += 1,
            .addiu => {
                n_u += 1;
                try testing.expectEqual(@as(u8, 127), d.c);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), n); // -64 and 63 fuse
    try testing.expectEqual(@as(usize, 3), n_reg); // -65, 64, 128 do not
    try testing.expectEqual(@as(usize, 1), n_u); // 127 fuses
}

test "3.3 LLIR lowering: B-type immediate windows — signed [-64,63], unsigned [0,127]" {
    // `lt a, K` with K in the imm7 window fuses to `blti`/`bltiu`;
    // out-of-window constants fall back to the general bool test
    // (`beq`/`bne cond, zero` — never a register `blt`/`bltu`, which
    // requires both operands live). Raw imm7 patterns: -64 → 0x40,
    // 63 → 0x3f, 127 → 0x7f; the u32 `-1` and `128` and the i32
    // `-65`/`64` windows reject.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @neg65(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const -65
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @neg64(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const -64
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @c63(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 63
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @c64(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 64
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @u0(a: uint32) -> uint32 {
        \\    entry:
        \\        %1: uint32 = const 0
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @u127(a: uint32) -> uint32 {
        \\    entry:
        \\        %1: uint32 = const 127
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @u128(a: uint32) -> uint32 {
        \\    entry:
        \\        %1: uint32 = const 128
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @uneg1(a: uint32) -> uint32 {
        \\    entry:
        \\        %1: uint32 = const -1
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }

    // Signed fused: -64 and 63 are `blti` with the raw imm7.
    const neg64 = branchOfFunc(&t.program, &b, image, "neg64");
    try testing.expectEqual(llir.Opcode.blti, neg64.op);
    try testing.expectEqual(@as(u8, 0x40), neg64.b);
    const c63 = branchOfFunc(&t.program, &b, image, "c63");
    try testing.expectEqual(llir.Opcode.blti, c63.op);
    try testing.expectEqual(@as(u8, 63), c63.b);
    // Unsigned fused: 127 is `bltiu` (zero-extended window); 0 fuses on
    // the inclusive lower bound.
    const imm127 = branchOfFunc(&t.program, &b, image, "u127");
    try testing.expectEqual(llir.Opcode.bltiu, imm127.op);
    try testing.expectEqual(@as(u8, 127), imm127.b);
    const imm0 = branchOfFunc(&t.program, &b, image, "u0");
    try testing.expectEqual(llir.Opcode.bltiu, imm0.op);
    try testing.expectEqual(@as(u8, 0), imm0.b);

    // Out-of-window constants never produce a fused or register `blt`:
    // the branch degrades to the general bool test on the comparison's
    // materialized bool against zero.
    for ([_][]const u8{ "neg65", "c64", "u128", "uneg1" }) |fname| {
        const d = branchOfFunc(&t.program, &b, image, fname);
        try testing.expect(d.op == .beq or d.op == .bne);
        try testing.expectEqual(llir.zero_reg, d.b);
    }
}

test "3.3 LLIR lowering: tbz/tbnz bit-test recognition — 0, 30, 63; multi-bit masks fall back" {
    // `(x & 2^k) ==/!= 0` recognizes a single-bit mask as a bit-test
    // branch: bit 0 and bit 30 (int32 cell), and bit 63 on a u64 whose
    // sign-bit mask is a negative constant read as raw cell bits. A mask
    // with several bits (3) is not a bit-test and degrades to the general
    // bool test. Bit indices never exceed 63 — a single-bit 64-bit mask
    // cannot name bit 64.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @b0(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        %2: int32 = bitand %0, %1
        \\        %3: int32 = const 0
        \\        %4: bool = eq %2, %3
        \\        br %4 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @b30(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1073741824
        \\        %2: int32 = bitand %0, %1
        \\        %3: int32 = const 0
        \\        %4: bool = eq %2, %3
        \\        br %4 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @b63(a: uint64) -> int32 {
        \\    entry:
        \\        %1: uint64 = const -9223372036854775808
        \\        %2: uint64 = bitand %0, %1
        \\        %3: uint64 = const 0
        \\        %4: bool = eq %2, %3
        \\        br %4 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @bm (a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 3
        \\        %2: int32 = bitand %0, %1
        \\        %3: int32 = const 0
        \\        %4: bool = eq %2, %3
        \\        br %4 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }

    // `(x & 1) == 0` reads x in the tested slot with bit index 0.
    const b0 = branchOfFunc(&t.program, &b, image, "b0");
    try testing.expect(b0.op == .tbz or b0.op == .tbnz);
    try testing.expectEqual(@as(u8, 0), b0.b);
    const b30 = branchOfFunc(&t.program, &b, image, "b30");
    try testing.expect(b30.op == .tbz or b30.op == .tbnz);
    try testing.expectEqual(@as(u8, 30), b30.b);
    // The u64 sign-bit mask names bit 63.
    const b63 = branchOfFunc(&t.program, &b, image, "b63");
    try testing.expect(b63.op == .tbz or b63.op == .tbnz);
    try testing.expectEqual(@as(u8, 63), b63.b);
    // A multi-bit mask is not a bit-test: the `eq` still fuses its
    // constant-0 RHS to the equality immediate `beqi` (mask 3 is not one
    // bit), never a `tbz`/`tbnz`.
    const bm = branchOfFunc(&t.program, &b, image, "bm");
    try testing.expect(bm.op == .beqi or bm.op == .bnei); // the equality immediate, inverted-or-not
    try testing.expectEqual(@as(u8, 0), bm.b);
}

test "3.3 LLIR lowering: branch inversions and operand-swap aliases before expansion" {
    // The trailing-jal elimination inverts the branch when the then-block
    // is next in the layout (`beq↔bne` with no operand change; the integer
    // ordering `blt↔ble`/`bltu↔bleu` exchange operands — `!(a<b) ≡
    // ble b,a`), and the fused immediate/bit forms invert as `beqi↔bnei`
    // (imm7 preserved) and `tbz↔tbnz` (register and bit preserved). The
    // non-strict orderings are the operand-swap aliases of the strict ones
    // (`a>=b ≡ ble b,a`), resolved in lowering before any expansion.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @ilt(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @ige(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: bool = ge %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @ile(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: bool = le %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @ieq(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @ult(a: uint32, b: uint32) -> uint32 {
        \\    entry:
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @feq(a: float32, b: float32) -> int32 {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @flt(a: float32, b: float32) -> int32 {
        \\    entry:
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @fge(a: float32, b: float32) -> int32 {
        \\    entry:
        \\        %2: bool = ge %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @eqimm(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 5
        \\        %2: bool = eq %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @neimm(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 5
        \\        %2: bool = ne %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @bt(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        %2: int32 = bitand %0, %1
        \\        %3: int32 = const 0
        \\        %4: bool = ne %2, %3
        \\        br %4 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @igt(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: bool = gt %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\    func @feq4(a: float64, b: float64) -> int32 {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        br %2 ? t : e
        \\    t:
        \\        ret %0
        \\    e:
        \\        ret %0
        \\    }
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }

    // Integer `lt a,b`: predicate inverts to `ble b,a` (then-block next).
    const f_ilt = findFunc(&t.program, "ilt");
    const d_ilt = branchOfFunc(&t.program, &b, image, "ilt");
    try testing.expectEqual(llir.Opcode.ble, d_ilt.op);
    try testing.expectEqual(b.slotOf(f_ilt.values[1]), d_ilt.a);
    try testing.expectEqual(b.slotOf(f_ilt.values[0]), d_ilt.b);
    // `ge a,b` ≡ `ble b,a`; inverted → `blt a,b`.
    const f_ige = findFunc(&t.program, "ige");
    const d_ige = branchOfFunc(&t.program, &b, image, "ige");
    try testing.expectEqual(llir.Opcode.blt, d_ige.op);
    try testing.expectEqual(b.slotOf(f_ige.values[0]), d_ige.a);
    try testing.expectEqual(b.slotOf(f_ige.values[1]), d_ige.b);
    // `le a,b` ≡ `ble a,b`; inverted → `blt b,a`.
    const f_ile = findFunc(&t.program, "ile");
    const d_ile = branchOfFunc(&t.program, &b, image, "ile");
    try testing.expectEqual(llir.Opcode.blt, d_ile.op);
    try testing.expectEqual(b.slotOf(f_ile.values[1]), d_ile.a);
    try testing.expectEqual(b.slotOf(f_ile.values[0]), d_ile.b);
    // Integer equality inverts with no operand exchange.
    const f_ieq = findFunc(&t.program, "ieq");
    const d_ieq = branchOfFunc(&t.program, &b, image, "ieq");
    try testing.expect(d_ieq.op == .beq or d_ieq.op == .bne);
    try testing.expectEqual(b.slotOf(f_ieq.values[0]), d_ieq.a);
    try testing.expectEqual(b.slotOf(f_ieq.values[1]), d_ieq.b);
    // unsigned `lt` inverts to `bleu` with swapped operands.
    const f_ult = findFunc(&t.program, "ult");
    const d_ult = branchOfFunc(&t.program, &b, image, "ult");
    try testing.expectEqual(llir.Opcode.bleu, d_ult.op);
    try testing.expectEqual(b.slotOf(f_ult.values[1]), d_ult.a);
    try testing.expectEqual(b.slotOf(f_ult.values[0]), d_ult.b);
    // Float equality inverts to `bne` with operands unchanged.
    const f_feq = findFunc(&t.program, "feq");
    const d_feq = branchOfFunc(&t.program, &b, image, "feq");
    try testing.expectEqual(llir.Opcode.bne_f32, d_feq.op);
    try testing.expectEqual(b.slotOf(f_feq.values[0]), d_feq.a);
    try testing.expectEqual(b.slotOf(f_feq.values[1]), d_feq.b);
    // Float ordering (NaN-ordered, never inverted): the then block is the
    // branch's target, two-record form, operands in source order.
    const f_flt = findFunc(&t.program, "flt");
    const d_flt = branchOfFunc(&t.program, &b, image, "flt");
    try testing.expectEqual(llir.Opcode.blt_f32, d_flt.op);
    try testing.expectEqual(b.slotOf(f_flt.values[0]), d_flt.a);
    try testing.expectEqual(b.slotOf(f_flt.values[1]), d_flt.b);
    // `ge` float ≡ `ble b,a` (swap baked into cmpSel), not inverted.
    const f_fge = findFunc(&t.program, "fge");
    const d_fge = branchOfFunc(&t.program, &b, image, "fge");
    try testing.expectEqual(llir.Opcode.ble_f32, d_fge.op);
    try testing.expectEqual(b.slotOf(f_fge.values[1]), d_fge.a);
    try testing.expectEqual(b.slotOf(f_fge.values[0]), d_fge.b);
    // `a > b` is the operand-swap alias `blt b,a`; inverted (then next) it
    // carries else as `ble a,b`.
    const f_igt = findFunc(&t.program, "igt");
    const d_igt = branchOfFunc(&t.program, &b, image, "igt");
    try testing.expectEqual(llir.Opcode.ble, d_igt.op);
    try testing.expectEqual(b.slotOf(f_igt.values[0]), d_igt.a);
    try testing.expectEqual(b.slotOf(f_igt.values[1]), d_igt.b);
    // Float f64 equality inverts to `bne` with operands unchanged.
    const f_feq4 = findFunc(&t.program, "feq4");
    const d_feq4 = branchOfFunc(&t.program, &b, image, "feq4");
    try testing.expectEqual(llir.Opcode.bne_f64, d_feq4.op);
    try testing.expectEqual(b.slotOf(f_feq4.values[0]), d_feq4.a);
    try testing.expectEqual(b.slotOf(f_feq4.values[1]), d_feq4.b);
    // Equality immediates invert beqi↔bnei, imm7 preserved.
    const d_eqimm = branchOfFunc(&t.program, &b, image, "eqimm");
    try testing.expect(d_eqimm.op == .beqi or d_eqimm.op == .bnei);
    try testing.expectEqual(@as(u8, 5), d_eqimm.b);
    const d_neimm = branchOfFunc(&t.program, &b, image, "neimm");
    try testing.expect(d_neimm.op == .beqi or d_neimm.op == .bnei);
    try testing.expectEqual(@as(u8, 5), d_neimm.b);
    try testing.expect(d_eqimm.op != d_neimm.op); // the two polarities differ
    // `(x & 1) != 0` is a bit-test; its inversion keeps register and bit.
    const f_bt = findFunc(&t.program, "bt");
    const d_bt = branchOfFunc(&t.program, &b, image, "bt");
    try testing.expect(d_bt.op == .tbz or d_bt.op == .tbnz);
    try testing.expectEqual(b.slotOf(f_bt.values[0]), d_bt.a);
    try testing.expectEqual(@as(u8, 0), d_bt.b);
}

test "3.3 LLIR lowering: far branches — the non-inverting trampoline (float, blti-bltiu) and inverted +2-skip forms" {
    // A branch whose carried target lies beyond ±512 expands: the
    // invertible predicates (`beq`/`bne`, `tbz`/`tbnz`, integer ordering)
    // invert and gain a link-less `j` (`b<inverted> +2`); the complement-less
    // immediate branches (`blti`/`bltiu`) and the NaN-ordered float
    // `blt`/`ble` use the three-record trampoline. Each function below
    // branches to a `then` block placed after a large else-block, forcing
    // a far target. The image must pass the structural validator — which
    // proves the PC fixup rewrote the right far/else records (the bug
    // this tests: a rep-based fixup misclassified the `blti`/`bltiu`
    // trampoline and rewrote its committed +2 skip into a far jump).
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator,
        \\module "app" {
        \\    func @farblti(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 7
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : m
        \\    m:
    );
    for (3..1200) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: int32 = add %0, %0\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        ret %0
        \\    t:
        \\        ret %0
        \\    }
        \\    func @farbltiu(a: uint32) -> uint32 {
        \\    entry:
        \\        %1: uint32 = const 7
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : m
        \\    m:
    );
    for (3..1200) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: uint32 = add %0, %0\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        ret %0
        \\    t:
        \\        ret %0
        \\    }
        \\    func @farfloat(a: float32, b: float32) -> int32 {
        \\    entry:
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : m
        \\    m:
    );
    for (3..1200) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: int32 = add %0, %0\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        ret %0
        \\    t:
        \\        ret %0
        \\    }
        \\    func @farbeq(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        br %2 ? t : m
        \\    m:
    );
    for (3..1200) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: int32 = add %0, %0\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        ret %0
        \\    t:
        \\        ret %0
        \\    }
        \\    func @fartbz(a: int64) -> int32 {
        \\    entry:
        \\        %1: int64 = const 1
        \\        %2: int64 = bitand %0, %1
        \\        %3: int64 = const 0
        \\        %4: bool = eq %2, %3
        \\        br %4 ? t : m
        \\    m:
    );
    for (5..1200) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: int32 = add %0, %0\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        ret %0
        \\    t:
        \\        ret %0
        \\    }
        \\}
    );
    var t = try cfg_parse.parseText(src.items);
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();

    // The image is structurally valid: every far-jump target resolves to
    // a block start inside its function (this is exactly what the
    // rep-based fixup bug corrupts).
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        defer testing.allocator.free(msg);
        std.log.err("3.3 far-branch image rejected: {s}", .{msg});
        return error.TestUnexpectedResult;
    }
    try testing.expect(b.expansion_rounds > 1);

    const t_farblti = b.pcOf(findBlock(findFunc(&t.program, "farblti").blocks, "t"));
    const br_farblti = branch_pc_of(&t.program, &b, image, "farblti");
    try check_trampoline(image, br_farblti, .blti, t_farblti);

    const t_farbltiu = b.pcOf(findBlock(findFunc(&t.program, "farbltiu").blocks, "t"));
    const br_farbltiu = branch_pc_of(&t.program, &b, image, "farbltiu");
    try check_trampoline(image, br_farbltiu, .bltiu, t_farbltiu);

    const t_farfloat = b.pcOf(findBlock(findFunc(&t.program, "farfloat").blocks, "t"));
    const br_farfloat = branch_pc_of(&t.program, &b, image, "farfloat");
    try check_trampoline(image, br_farfloat, .blt_f32, t_farfloat);

    // The invertible predicates expand to the inverted `+2`-skip form: a
    // single link-less `j` right after the inverted branch carries the target.
    const t_farbeq = b.pcOf(findBlock(findFunc(&t.program, "farbeq").blocks, "t"));
    const br_farbeq = branch_pc_of(&t.program, &b, image, "farbeq");
    const inv_farbeq = llir.decode(image.instructions[br_farbeq]).?;
    try testing.expectEqual(llir.Opcode.bne, inv_farbeq.op); // beq inverted
    try testing.expectEqual(@as(i16, 2), inv_farbeq.offs10);
    const far_beq = llir.decode(image.instructions[br_farbeq + 1]).?;
    try testing.expectEqual(llir.Opcode.j, far_beq.op);
    try testing.expectEqual(t_farbeq, llir.jalTarget(br_farbeq + 1, far_beq.imm20));

    const t_fartbz = b.pcOf(findBlock(findFunc(&t.program, "fartbz").blocks, "t"));
    const br_fartbz = branch_pc_of(&t.program, &b, image, "fartbz");
    const inv_fartbz = llir.decode(image.instructions[br_fartbz]).?;
    try testing.expectEqual(llir.Opcode.tbnz, inv_fartbz.op); // tbz inverted
    try testing.expectEqual(@as(i16, 2), inv_fartbz.offs10);
    const far_tbz = llir.decode(image.instructions[br_fartbz + 1]).?;
    try testing.expectEqual(llir.Opcode.j, far_tbz.op);
    try testing.expectEqual(t_fartbz, llir.jalTarget(br_fartbz + 1, far_tbz.imm20));
}

test "3.3 LLIR lowering: offs10 and imm20 signed windows at the codec boundary" {
    // The lowering funnels every B-type branch through `fit10Signed` and
    // every `jal` through `fit20Signed`; the exact two's-complement ranges
    // are the contract (Instruction Set §11 / §9): offs10 ∈ [-512, 511],
    // imm20 ∈ [-524288, 524287]. The neighbors are rejected, and an
    // out-of-reach span in the lowering sets the Builder's overflow latch
    // (which `lowerLlir` reports as `error.ProgramTooLarge` — never a
    // silent truncation).
    try testing.expectEqual(@as(?i16, -512), llir.fit10Signed(0, 512)); // target - pc
    try testing.expectEqual(@as(?i16, 511), llir.fit10Signed(511, 0));
    try testing.expectEqual(@as(?i16, null), llir.fit10Signed(0, 513)); // -513
    try testing.expectEqual(@as(?i16, null), llir.fit10Signed(512, 0)); // +512
    try testing.expectEqual(@as(?i32, -524288), llir.fit20Signed(0, 524288));
    try testing.expectEqual(@as(?i32, 524287), llir.fit20Signed(524287, 0));
    try testing.expectEqual(@as(?i32, null), llir.fit20Signed(0, 524289)); // -524289
    try testing.expectEqual(@as(?i32, null), llir.fit20Signed(524288, 0)); // +524288

    // A branch whose target still lies inside ±512 stays a plain branch
    // (no relaxation round grows a skip), and a large-but-in-range `jal`
    // round-trips through the image. Out-of-reach fit calls latch the
    // overflow flag.
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator,
        \\module "app" {
        \\    func @near(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: bool = lt %0, %1
        \\        br %2 ? t : m
        \\    m:
    );
    // ~150 filler adds in `m` (two records each — opcode + `sext32`)
    // push `t` ~302 records past the branch.
    for (3..153) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: int32 = add %0, %0\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        ret %0
        \\    t:
        \\        ret %0
        \\    }
        \\    func @jmp(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = add %0, %0
        \\        %2: int32 = add %0, %0
        \\        %3: int32 = add %0, %0
        \\        j done
        \\    done:
        \\        ret %0
        \\    }
        \\}
    );
    var parsed = try cfg_parse.parseText(src.items);
    defer parsed.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &parsed.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }

    // @near's branch: within reach, so no expansion (exactly one relaxation
    // round) and its signed offs10 resolves back to the target block.
    try testing.expectEqual(@as(u32, 1), b.expansion_rounds);
    const br_pc = branch_pc_of(&parsed.program, &b, image, "near");
    const brd = llir.decode(image.instructions[br_pc]).?;
    try testing.expectEqual(llir.Opcode.blt, brd.op); // lt, else (m) next → no inversion
    const t_pc = b.pcOf(findBlock(findFunc(&parsed.program, "near").blocks, "t"));
    try testing.expectEqual(@as(i16, @intCast(t_pc - br_pc)), brd.offs10);
    try testing.expectEqual(t_pc, llir.bTypeTarget(br_pc, brd.offs10));

    // @jmp's block terminator is the link-less U-type `j`; its
    // pc-relative imm20 round-trips through the image to the done block.
    const jmp_f = findFunc(&parsed.program, "jmp");
    const j_entry = findBlock(jmp_f.blocks, "entry");
    const j_entry_row = image.blocks[b.block_ids.get(j_entry).?];
    const j_pc: u32 = j_entry_row.end_pc - 1; // `j done` is entry's last record
    const done_pc = b.pcOf(findBlock(jmp_f.blocks, "done"));
    const j_rec = llir.decode(image.instructions[j_pc]).?;
    try testing.expectEqual(llir.Opcode.j, j_rec.op);
    try testing.expectEqual(done_pc, llir.jalTarget(j_pc, j_rec.imm20));

    // The overflow latch: the Builder's fit helpers return 0 on an
    // out-of-window span and set the flag that `lowerLlir` turns into
    // `error.ProgramTooLarge` — never a silent truncation.
    try testing.expectEqual(@as(i16, 0), b.fit10Signed(600, 0));
    try testing.expect(b.operand_overflow);
    try testing.expectEqual(@as(i32, 0), b.fit20Signed(600000, 0));
    try testing.expect(b.operand_overflow);
}
