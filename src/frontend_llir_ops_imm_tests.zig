//! Test file: `frontend LLIR ops, immediates` — LLIR lowering stages
//! 2.14–2.15 (const+op fusion to immediate variants, shift/bitwise
//! fusion, compaction, unsigned compares, multiply-accumulate, corpus
//! fusion metrics). Split out of `frontend_llir_ops_tests.zig`;
//! `isImmediateFamily` and `retRecord` are local to this file.
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
const llir_fuse_lc = @import("passes/llir_fuse_lifecycle.zig");
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

/// The v9 immediate families (the 2.14 acceptance): the integer-4
/// `addi`/`subi`/`muli`/`divi`/`remi`/`maddi`, `shli`/`shri`,
/// `andi`/`ori`/`xori` (mask semantics), and C-Type comparisons
/// `slti`/`sgti`/`seqi`/`snei`. The rep-suffixed names make
/// the families non-contiguous, so the check is on the name prefix.
fn isImmediateFamily(op: llir.Opcode) bool {
    const name = llir.opInfo(op).name;
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const base = if (dot) |d| name[0..d] else name;
    const fams = [_][]const u8{ "addi", "subi", "muli", "divi", "remi", "maddi", "shli", "shri", "andi", "ori", "xori", "slti", "sltiu", "sgti", "sgtiu", "seqi", "snei" };
    for (fams) |fam| {
        if (std.mem.eql(u8, base, fam)) return true;
    }
    return false;
}

test "2.14 LLIR lowering: compiled const+op folds to immediate variants" {
    // Source-level literals lower to `const` instructions (the printer
    // may re-inline them, but the records exist), and the peephole folds
    // each const+op pair: `a + 2` → R-Type `addi`, `3 < a` → C-Type
    // `sgti`. f32 has no
    // immediate forms (Instruction Set §7) — `a * 2.5` stays a
    // `const` + `mul_f32` pair, the constant reading its slot.
    // (uint32 has no source literals — `7` is always int32,
    // and `a * 7` with `a: uint32` is a checker-level mismatch — so the
    // u32 immediate forms are exercised by the text-AIR test below.)
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f(a: int32) -> int32 { a + 2 }
            \\fn g(a: int32) -> int32 { if (3 < a) { 1 } else { 0 } }
            \\fn k(a: float32) -> float32 { a * 2.5 }
            \\fn main() -> void {
            \\    let _ = f(1);
            \\    let _ = g(2);
            \\    let _ = k(4.0);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // The arithmetic fused variants appear; their constants' records are
    // gone (single-use consts folded), so the code table shrank.
    try testing.expect(b.last_fusion.after_instrs < b.last_fusion.before_instrs);
    var n_addi: usize = 0;
    var n_gti: usize = 0;
    var n_f32_mul: usize = 0;
    for (image.instructions) |rec| {
        const op = llir.decode(rec).?.op;
        switch (op) {
            .addi_i32 => {
                n_addi += 1;
                try testing.expectEqual(@as(u32, 2), llir.decode(rec).?.c); // imm 2
            },
            .sgti => {
                n_gti += 1;
                try testing.expectEqual(@as(u32, 3), llir.decode(rec).?.b);
                try testing.expectEqual(llir.Format.c, llir.decode(rec).?.format);
            },
            .mul_f32 => n_f32_mul += 1, // no f32 immediate forms — the const reads its slot
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), n_addi);
    try testing.expectEqual(@as(usize, 1), n_gti);
    try testing.expectEqual(@as(usize, 1), n_f32_mul);

    // The fused constants' instructions left no records (`isFusedConst`),
    // and the surviving records pass the schema check.
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (b.isFusedConst(ins)) {
                    try testing.expect(ins.op == .const_);
                    continue;
                }
            }
        }
    }
}

test "2.14 LLIR lowering: shifts lower to the unified family and fuse counts" {
    // The unified shift family (Instruction Set §5): `shl` shared by
    // int32/uint32 (left shift is bit-identical), `shr` arithmetic (i32,
    // sign-filling) and `shru` logical (u32, zero-filling). A constant
    // count fuses to the immediate form (`shli`/`shri`/`shrui`, the raw
    // 16-bit pattern zero-extended and masked mod 32 at decode); a
    // register count stays a 3-address register form. Shifts are not
    // commutative — a constant on the left never fuses. uint32 has no
    // source literal, so the u32 register form (`a >> b`) comes from the
    // compiled program and the u32 immediate form (`shrui`) from the
    // text-AIR fixture below.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f(a: int32) -> int32 { a << 2 }
            \\fn g(a: int32) -> int32 { a >> 3 }
            \\fn j(a: int32, b: int32) -> int32 { a << b }
            \\fn k(a: uint32, b: uint32) -> uint32 { a >> b }
            \\fn m(a: int32) -> int32 { 2 << a }
            \\fn main() -> void {
            \\    let _ = f(1);
            \\    let _ = g(2);
            \\    let _ = j(4, 5);
            \\    let _ = k(6 as uint32, 7 as uint32);
            \\    let _ = m(8);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var n_shli: usize = 0;
    var n_shri: usize = 0;
    var n_shl: usize = 0;
    var n_shru: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec).?;
        switch (d.op) {
            .shli_i32 => {
                n_shli += 1;
                try testing.expectEqual(@as(u32, 2), d.c); // `a << 2`
            },
            .shri_i32 => {
                n_shri += 1;
                try testing.expectEqual(@as(u32, 3), d.c); // `a >> 3`
            },
            .shl_i32 => {
                n_shl += 1;
                // `a << b` (register count) and `2 << a` (constant on
                // the left — never fused, shifts are not commutative):
                // `c` carries the count's slot index.
            },
            .shr_u32 => {
                n_shru += 1; // `a >> b` (u32), count in `c`
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), n_shli);
    try testing.expectEqual(@as(usize, 1), n_shri);
    try testing.expectEqual(@as(usize, 2), n_shl);
    try testing.expectEqual(@as(usize, 1), n_shru);

    // The u32 immediate form: text-AIR `shr` with a u32 const count
    // fuses to `shriu` (the count is zero-extended raw-pattern).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @h(a: uint32) -> uint32 {
        \\entry:
        \\    %1: uint32 = const 1
        \\    %2: uint32 = shr %0, %1
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    var b2 = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image2 = try b2.lowerLlir();
    var n_shrui: usize = 0;
    for (image2.instructions) |rec| {
        const d = llir.decode(rec).?;
        if (d.op == .shri_u32) {
            n_shrui += 1;
            try testing.expectEqual(@as(u32, 1), d.c);
        }
    }
    try testing.expectEqual(@as(usize, 1), n_shrui);
}

test "2.14 LLIR lowering: u32 div/rem by a const fuses to the typed immediate form" {
    // The typed `div.u32` register form lowers as one record (§4), and
    // the fusion pass (2.14) rewrites it to `divi.u32` — the immediate
    // reads the dividend's canonical cell directly; no staging record
    // exists in v10. The fused constant's record is dropped by the
    // compaction.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @h(a: uint32) -> uint32 {
        \\entry:
        \\    %1: uint32 = const 7
        \\    %2: uint32 = div %0, %1
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();

    const dividend_slot = b.slotOf(t.program.funcs[0].values[0]);
    var n_diviu: usize = 0;
    var n_divu: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec).?;
        switch (d.op) {
            .divi_u32 => {
                n_diviu += 1;
                try testing.expectEqual(@as(u32, 7), d.c);
                // The source is the dividend's own slot — the canonical
                // cell needs no widening.
                try testing.expectEqual(dividend_slot, d.b);
            },
            .div_u32 => n_divu += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), n_diviu);
    try testing.expectEqual(@as(usize, 0), n_divu);

    // The fused constant's record is gone (the use-count reached 0).
    for (b.ordered_funcs.items, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            for (b.ordered_blocks.items[bi].instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (b.isFusedConst(ins)) {
                    try testing.expectEqual(cfg.OpTag.const_, std.meta.activeTag(ins.op));
                }
            }
        }
    }
}

test "2.14 LLIR lowering: bitwise ops lower to the unified family and fuse" {
    // The unified bitwise family (Instruction Set §5): `and`/`or`/`xor`
    // are bit-identical on int32/uint32 (no signedness distinction). A
    // constant in the second operand position fuses to the immediate
    // form (`andi`/`ori`/`xori`, the raw 16-bit pattern zero-extended —
    // mask semantics). Bitwise ops are commutative, so a constant on
    // the left commutes and fuses too; a negative int32 constant (a
    // pattern with high bits set) never fuses and materializes.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f(a: int32) -> int32 { a & 63 }
            \\fn g(a: int32) -> int32 { a | 3 }
            \\fn h(a: int32, b: int32) -> int32 { a ^ b }
            \\fn k(a: int32) -> int32 { 1 | a }
            \\fn m(a: uint32, b: uint32) -> uint32 { a ^ b }
            \\fn n(a: int32) -> int32 { a & -2 }
            \\fn main() -> void {
            \\    let _ = f(1);
            \\    let _ = g(2);
            \\    let _ = h(4, 5);
            \\    let _ = k(6);
            \\    let _ = m(8 as uint32, 9 as uint32);
            \\    let _ = n(9);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var n_andi: usize = 0;
    var n_ori: usize = 0;
    var n_xor: usize = 0;
    var n_and_: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec).?;
        switch (d.op) {
            .andi => {
                n_andi += 1;
                // v9: the mask window is [0, 127] (zero-extended) —
                // `a & 63` fuses with imm 63; a mask with high bits
                // set (e.g. 255) never fuses.
                try testing.expectEqual(@as(u32, 63), d.c); // `a & 63`
            },
            .ori => {
                n_ori += 1;
                // `a | 3` and `1 | a` (constant on the left commutes).
            },
            .xor => {
                n_xor += 1; // `a ^ b` (register forms: h and m)
            },
            .and_ => {
                n_and_ += 1; // `a & -2`: the constant has high bits set, never fuses — stays a register form
            },
            else => {},
        }
    }
    // f: andi; g: ori; h: xor; k: ori (commuted); m: xor (register);
    // n: and_ (register — the constant has high bits set, never fuses).
    try testing.expectEqual(@as(usize, 1), n_andi);
    try testing.expectEqual(@as(usize, 2), n_ori);
    try testing.expectEqual(@as(usize, 2), n_xor);
    try testing.expectEqual(@as(usize, 1), n_and_);

    // The u32 immediate forms: text-AIR `bitor`/`bitxor` with a u32
    // const on the right fuse to `ori`/`xor` (the pattern is
    // zero-extended).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @h(a: uint32) -> uint32 {
        \\entry:
        \\    %1: uint32 = const 1
        \\    %2: uint32 = bitor %0, %1
        \\    ret %2
        \\}
        \\func @j(a: uint32) -> uint32 {
        \\entry:
        \\    %1: uint32 = const 1
        \\    %2: uint32 = bitxor %0, %1
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    var b2 = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image2 = try b2.lowerLlir();
    var n_ori2: usize = 0;
    var n_xori2: usize = 0;
    for (image2.instructions) |rec| {
        const d = llir.decode(rec).?;
        switch (d.op) {
            .ori => {
                n_ori2 += 1;
                try testing.expectEqual(@as(u32, 1), d.c);
            },
            .xori => {
                n_xori2 += 1;
                try testing.expectEqual(@as(u32, 1), d.c);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), n_ori2);
    try testing.expectEqual(@as(usize, 1), n_xori2);
}

test "2.14 LLIR lowering: shift constants fold at construction" {
    // On-the-fly folding (cfg_lower_emit.zig): a shift over constants
    // folds to the constant — `6 << 2` is 24 and `-16 >> 2` is -4
    // (arithmetic, sign-filling); the count is masked mod 32
    // (WebAssembly semantics), so `1 << 33` folds to `1 << 1` = 2 and
    // `-1 << -1` to `-1 << 31`.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f() -> int32 { 6 << 2 }
            \\fn g() -> int32 { -16 >> 2 }
            \\fn h() -> int32 { 1 << 33 }
            \\fn k() -> int32 { -1 << -1 }
            \\fn main() -> void {
            \\    let _ = f();
            \\    let _ = g();
            \\    let _ = h();
            \\    let _ = k();
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };

    const ir = try irText(&program);
    defer testing.allocator.free(ir);
    try testing.expect(std.mem.indexOf(u8, ir, "= const 24") != null); // 6 << 2
    try testing.expect(std.mem.indexOf(u8, ir, "= const -4") != null); // -16 >> 2 (arithmetic)
    try testing.expect(std.mem.indexOf(u8, ir, "= const 2") != null); // 1 << 33 → 1 << (33 & 31)
    try testing.expect(std.mem.indexOf(u8, ir, "= const -2147483648") != null); // -1 << -1 → -1 << 31
}

test "2.14 LLIR lowering: fused const in a phi-bearing block keeps its own record" {
    // Regression: the peephole's pass-1 record positions must skip phis
    // (which occupy no record). The old walk advanced the index over phis,
    // so a fully-fused const after a phi got its *neighbor's* record
    // deleted — the fused `add` vanished from the image and the const
    // survived. The block here is a loop header: a phi first, then a
    // fusible `const` whose only use is the `add` below it.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(n: int32) -> int32 {
        \\entry:
        \\    %1: int32 = const 0
        \\    j loop
        \\loop:
        \\    %2: int32 = phi [%1, entry], [%4, loop]
        \\    %3: int32 = const 1
        \\    %4: int32 = add %2, %3
        \\    %5: bool = lt %4, %0
        \\    br %5 ? loop : exit
        \\exit:
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();

    const f = t.program.funcs[0];
    var loop_blk: ?*const cfg.BasicBlock = null;
    var exit_blk: ?*const cfg.BasicBlock = null;
    for (f.blocks) |blk| {
        if (std.mem.eql(u8, blk.name, "loop")) loop_blk = blk;
        if (std.mem.eql(u8, blk.name, "exit")) exit_blk = blk;
    }
    const loop = loop_blk.?;
    const exit = exit_blk.?;

    // The const's only use is the add, so it fuses to `addi` and its
    // own record is deleted — exactly one record gone from the image.
    try testing.expectEqual(@as(u32, b.last_fusion.before_instrs - 1), b.last_fusion.after_instrs);
    var n_addi: usize = 0;
    var n_const: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec).?;
        switch (d.op) {
            .addi_i32 => {
                n_addi += 1;
                try testing.expectEqual(@as(u32, 1), d.c); // imm 1
            },
            .const_ => n_const += 1,
            else => {},
        }
    }
    // The fused `add` survives as `addi` — the fix's point: under the
    // old misalignment the phi's presence made pass 3 delete THIS record
    // instead of the const's.
    try testing.expectEqual(@as(usize, 1), n_addi);
    // One const record remains: `%1` (still read by the phi edge copy);
    // `%4`'s record was fused away.
    try testing.expectEqual(@as(usize, 1), n_const);

    // The loop block's records are, in order: [addi, slt,
    // copy dst, cond, blt, j] — the fused const left no record; the
    // compare-and-branch (`lt %4, %0` fused) is the two-record form
    // (stage 7): the back-edge carries a phi copy, so it routes through
    // the LLIR-only edge block, and the trailing `j` carries the exit
    // (which has no effects and is reached directly). The 2.7 phi copy
    // now lives in the edge block, not inline.
    const bid = b.block_ids.get(loop).?;
    const d = image.blocks[bid];
    const width = b.non_phi_counts.items[bid] + b.edge_copy_counts.items[bid] + b.terminatorRecordCount(loop);
    try testing.expectEqual(@as(u32, width), d.end_pc - d.start_pc);
    const blt = llir.decode(image.instructions[d.end_pc - 2]).?;
    try testing.expectEqual(llir.Opcode.blt, blt.op);
    // The branch carries the loop back-edge's edge block.
    const edge_block = b.targetForEdge(loop, loop);
    try testing.expectEqual(b.pcOf(edge_block), llir.bTypeTarget(d.end_pc - 2, blt.offs10));
    // The trailing `j` carries the exit.
    const j = llir.decode(image.instructions[d.end_pc - 1]).?;
    try testing.expectEqual(llir.Opcode.j, j.op);
    try testing.expectEqual(b.pcOf(exit), d.end_pc - 1 +% @as(u32, @bitCast(j.imm20)));
    // The edge block holds the phi copy `%2 = phi [%4, loop]` and jumps
    // back to the loop header.
    const ebid = b.block_ids.get(edge_block).?;
    const ed = image.blocks[ebid];
    try testing.expectEqual(b.pcOf(loop), ed.end_pc - 1 +% @as(u32, @bitCast(llir.decode(image.instructions[ed.end_pc - 1]).?.imm20)));
}

test "2.14 LLIR lowering: immediate semantics — raw bit patterns, commute, swap+flip, no-fuse cases" {
    // Text-AIR gives precise control: -2's 7-bit pattern (0x7e,
    // sign-extended at decode), byte immediates in range, integer
    // eq/mul commuting, ordering swap+flip, and the no-fuse cases (an
    // f32 constant — no f32 immediate forms exist, so 2.5 and 3.5 keep
    // their records and the ops read the slots; non-commutative sub
    // with a left constant; a constant still used by the terminator;
    // and u32 max — 4294967295 does not fit the 7-bit field, so that
    // add stays a `const` + register form).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @f(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const -2
        \\        %2: int32 = add %0, %1
        \\        %3: int32 = const 3
        \\        %4: int32 = mul %3, %2
        \\        %5: int32 = const 3
        \\        %6: bool = lt %5, %4
        \\        ret %6
        \\    }
        \\    func @g(a: float32) -> float32 {
        \\    entry:
        \\        %1: float32 = const 2.5
        \\        %2: float32 = add %0, %1
        \\        %3: float32 = const 3.5
        \\        %4: float32 = mul %3, %2
        \\        ret %4
        \\    }
        \\    func @h(a: byte) -> bool {
        \\    entry:
        \\        %1: byte = const 7
        \\        %2: bool = eq %0, %1
        \\        %3: byte = const 9
        \\        %4: bool = ge %3, %0
        \\        %5: bool = eq %3, %3
        \\        ret %5
        \\    }
        \\    func @m(a: uint32) -> uint32 {
        \\    entry:
        \\        %1: uint32 = const 4294967295
        \\        %2: uint32 = add %0, %1
        \\        %3: uint32 = const 8
        \\        %4: uint32 = mul %2, %3
        \\        %5: uint32 = add %4, %3
        \\        ret %1
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var n_addi: usize = 0;
    var n_addiu: usize = 0;
    var n_muli: usize = 0;
    var n_muliu: usize = 0;
    var n_gti: usize = 0;
    var n_f32_add: usize = 0;
    var n_f32_mul: usize = 0;
    var n_eqi: usize = 0;
    var n_sltu: usize = 0;
    var n_not: usize = 0;
    var n_add: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec).?;
        switch (d.op) {
            .addi_i32 => {
                n_addi += 1;
                // `%0 + -2` carries -2's 7-bit pattern (0x7e — an
                // ordinary immediate, never a register; sign-extended
                // to i32 at decode).
                try testing.expectEqual(@as(u32, 0x7e), d.c);
            },
            .addi_u32 => {
                n_addiu += 1;
                // `%4 + 8` (u32): a uint32 constant must sit in
                // [0, 127] for the zero-extending addiu.
                try testing.expectEqual(@as(u32, 8), d.c);
            },
            .muli_i32 => {
                n_muli += 1;
                // `3 * %2` commuted to `%2 * 3`.
                try testing.expectEqual(@as(u32, 3), d.c);
            },
            .muli_u32 => {
                n_muliu += 1;
                // `%2 * 8` (u32) fused with imm 8.
                try testing.expectEqual(@as(u32, 8), d.c);
            },
            .sgti => {
                n_gti += 1;
                try testing.expectEqual(@as(u32, 3), d.b);
                try testing.expectEqual(llir.Format.c, d.format);
            },
            // The f32 constants never fuse — `2.5 + %0` and `3.5 * %2`
            // read the constant slots (no f32 immediate forms,
            // Instruction Set §7).
            .add_f32 => n_f32_add += 1,
            .mul_f32 => n_f32_mul += 1,
            .seqi => {
                n_eqi += 1;
                try testing.expect(d.b <= 0x7f);
                try testing.expectEqual(llir.Format.c, d.format);
            },
            // `9 >= %0` (byte, constant on the left) does not fuse —
            // integer le/ge have no immediate forms — so the `ge` record
            // synthesizes `not(sltu %9, %0)` (with the const 9 still
            // read from its slot), followed by the `copy dst, cond`
            // materialization.
            .sltu => n_sltu += 1,
            .not => n_not += 1,
            // `%0 + %1` (u32 max, 4294967295) does not fit the 7-bit
            // field, so it stays a register-form `add.u32` reading the
            // const's slot.
            .add_u32 => n_add += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), n_addi); // the i32 -2
    try testing.expectEqual(@as(usize, 1), n_addiu); // the u32 8
    try testing.expectEqual(@as(usize, 1), n_muli); // the i32 3
    try testing.expectEqual(@as(usize, 1), n_muliu); // the u32 8
    try testing.expectEqual(@as(usize, 1), n_gti);
    try testing.expectEqual(@as(usize, 1), n_f32_add);
    try testing.expectEqual(@as(usize, 1), n_f32_mul);
    try testing.expectEqual(@as(usize, 2), n_eqi);
    try testing.expectEqual(@as(usize, 1), n_sltu); // the `9 >= %0` ge lowers as sltu + not
    try testing.expectEqual(@as(usize, 1), n_not);
    try testing.expectEqual(@as(usize, 1), n_add);

    // In @m the `%1` const (4294967295) is read by the final `ret` and
    // by the register-form `add` (its value does not fit the 7-bit
    // immediate field), so its record survives. The `%3` const (8) has
    // only fused uses and is gone.
    var seen_u32_const_max = false;
    var seen_u32_const_8 = false;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f) orelse continue;
        const range = b.block_ranges.items[fid];
        for (0..range.len) |k| {
            const blk = b.ordered_blocks.items[range.start + k];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (b.isFusedConst(ins)) continue; // no record at its old PC
                switch (ins.op) {
                    .const_ => |cv| if (cv == .int) {
                        const d = llir.decode(image.instructions[pc]).?;
                        if (cv.int == 4294967295) {
                            try testing.expectEqual(llir.Opcode.const_, d.op);
                            seen_u32_const_max = true;
                        } else if (cv.int == 8) {
                            seen_u32_const_8 = true;
                        }
                    } else {},
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expect(seen_u32_const_max);
    try testing.expect(!seen_u32_const_8);

    // Fused constants' instructions are reported fused and carry no record.
    var n_fused: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f) orelse continue;
        const range = b.block_ranges.items[fid];
        for (0..range.len) |k| {
            const blk = b.ordered_blocks.items[range.start + k];
            for (blk.instrs) |ins| {
                if (b.isFusedConst(ins)) n_fused += 1;
            }
        }
    }
    // @f: 3, @h: 1, @m: 1 = 5 — @g's f32 constants never fuse (no f32
    // immediate forms, Instruction Set §7). In @h the `eq %3, %3`
    // instruction references %3 twice: one operand fuses, the other
    // still reads the slot, so %3's record survives.
    try testing.expectEqual(@as(usize, 5), n_fused);
}

test "2.14 LLIR lowering: compaction re-backfills every absolute-PC reference" {
    // Deleting a fused const shifts every later record; the pass must
    // re-backfill the block/function ranges, entry_pc, and the br/j
    // targets. @q's entry fuses its only const, so the `then`/`else`
    // block start PCs shift by one.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @q(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 5
        \\        %2: int32 = add %0, %1
        \\        %3: bool = gt %2, %0
        \\        br %3 ? then : else
        \\    then:
        \\        ret %2
        \\    else:
        \\        ret %0
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const q = program.funcs[0];
    const qid = b.func_ids.get(q).?;
    const fd = image.functions[qid];
    const entry = findBlock(q.blocks, "entry");
    const then = findBlock(q.blocks, "then");
    const else_ = findBlock(q.blocks, "else");
    const e_pc = b.pcOf(entry);
    const then_pc = b.pcOf(then);
    const else_pc = b.pcOf(else_);

    // Entry's records after fusion: addi, slt, copy dst, cond, ble —
    // the const is gone (the fused `addi` reads the immediate) and the
    // typed `add.i32` is a single record, so entry is one record
    // shorter per fusion than in v9; the `gt %2, %0`
    // condition fuses to a compare-and-branch (`a > b` ⟺ `b < a` →
    // slt, operands swapped, then `copy dst, cond` materializes the
    // bool), and the trailing-j elimination inverts it (`blt` → `ble`,
    // operands exchanged — `!(%0 < %2) ≡ %0 >= %2 ≡ ble %2, %0`): the
    // then block is the next in the layout, so it falls through and
    // the branch carries the else target — no `j` remains.
    try testing.expectEqual(llir.Opcode.addi_i32, llir.decode(image.instructions[e_pc]).?.op);
    try testing.expectEqual(llir.Opcode.slt, llir.decode(image.instructions[e_pc + 1]).?.op);
    try testing.expectEqual(llir.Opcode.copy, llir.decode(image.instructions[e_pc + 2]).?.op);
    const blt_rec = llir.decode(image.instructions[e_pc + 3]).?;
    try testing.expectEqual(llir.Opcode.ble, blt_rec.op);
    // The targets were re-based: then/else starts after the shift,
    // encoded as signed offsets from the branch's own pc.
    try testing.expectEqual(else_pc, llir.bTypeTarget(e_pc + 3, blt_rec.offs10));
    try testing.expectEqual(e_pc + 4, then_pc); // the deleted const's record nets one record less
    // Block and function ranges agree with the compacted image.
    try testing.expectEqual(fd.code_start, e_pc);
    try testing.expectEqual(fd.entry_pc, e_pc);
    try testing.expectEqual(@as(u32, @intCast(image.instructions.len)), fd.code_end);
    try testing.expectEqual(then_pc, image.blocks[b.block_ids.get(then).?].start_pc);
    try testing.expectEqual(else_pc, image.blocks[b.block_ids.get(else_).?].start_pc);
    // Every record passes the schema check against the frame's slot count.
    const slots = fd.f_count + fd.x_count + fd.window_count;
    for (image.instructions) |rec| {
        try testing.expectEqual(@as(?llir.Issue, null), llir.checkInstr(rec, slots));
    }
}

test "2.14 LLIR lowering: unsigned comparisons fuse to bltu/bleu" {
    // A `u32` ordering comparison feeding a `br` fuses to the
    // unsigned compare-and-branch (`bltu`/`bleu`), mirroring the
    // signed `blt`/`ble` fusion — the operand order carries the
    // polarity, and the comparison record stays for the dead-code pass
    // (Instruction Set §6).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @lt(a: uint32, b: uint32) -> uint32 {
        \\    entry:
        \\        %2: bool = lt %0, %1
        \\        br %2 ? then : else
        \\    then:
        \\        ret %0
        \\    else:
        \\        ret %1
        \\    }
        \\    func @le(a: uint32, b: uint32) -> uint32 {
        \\    entry:
        \\        %2: bool = le %0, %1
        \\        br %2 ? then : else
        \\    then:
        \\        ret %0
        \\    else:
        \\        ret %1
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // `lt %0, %1` fuses to `bltu %0, %1` (operands in order); the
    // `sltu` comparison record and its `copy dst, cond`
    // materialization remain. The then block is the next in the layout,
    // so the trailing-j elimination inverts the branch (`bltu` →
    // `bleu`, operands exchanged — `!(%0 < %1) ≡ bleu %1, %0`) and it
    // carries the else target, `then` falling through.
    const lt = program.funcs[0];
    const lt_pc = b.pcOf(findBlock(lt.blocks, "entry"));
    try testing.expectEqual(llir.Opcode.sltu, llir.decode(image.instructions[lt_pc]).?.op);
    try testing.expectEqual(llir.Opcode.copy, llir.decode(image.instructions[lt_pc + 1]).?.op);
    const bltu = llir.decode(image.instructions[lt_pc + 2]).?;
    try testing.expectEqual(llir.Opcode.bleu, bltu.op);
    try testing.expectEqual(b.slotOf(lt.values[1]), bltu.a);
    try testing.expectEqual(b.slotOf(lt.values[0]), bltu.b);
    try testing.expectEqual(b.pcOf(findBlock(lt.blocks, "else")), llir.bTypeTarget(lt_pc + 2, bltu.offs10));
    // `then` falls through: the branch block ends where then begins.
    try testing.expectEqual(b.pcOf(findBlock(lt.blocks, "then")), image.blocks[b.block_ids.get(findBlock(lt.blocks, "entry")).?].end_pc);

    // `le %0, %1` (u32) synthesizes `not(sltu)`: `sltu %1, %0` (the
    // swapped operands — integer le has no comparison opcode,
    // Instruction Set §7)
    // plus `not cond` and `copy dst, cond`; the fused branch is
    // `bleu %0, %1` and the trailing-j elimination inverts it
    // (`bleu` → `bltu`, operands exchanged) so the branch carries the
    // else target and `then` falls through.
    const le = program.funcs[1];
    const le_pc = b.pcOf(findBlock(le.blocks, "entry"));
    const slt_rec = llir.decode(image.instructions[le_pc]).?;
    try testing.expectEqual(llir.Opcode.sltu, slt_rec.op);
    try testing.expectEqual(b.slotOf(le.values[1]), slt_rec.a);
    try testing.expectEqual(b.slotOf(le.values[0]), slt_rec.b);
    const nrec = llir.decode(image.instructions[le_pc + 1]).?;
    try testing.expectEqual(llir.Opcode.not, nrec.op);
    const ncopy = llir.decode(image.instructions[le_pc + 2]).?;
    try testing.expectEqual(llir.Opcode.copy, ncopy.op);
    try testing.expectEqual(b.slotOf(le.values[2]), ncopy.a); // dst = the bool result
    try testing.expectEqual(llir.cond_reg, ncopy.b);
    const le_blt = llir.decode(image.instructions[le_pc + 3]).?;
    try testing.expectEqual(llir.Opcode.bltu, le_blt.op);
    try testing.expectEqual(b.slotOf(le.values[1]), le_blt.a);
    try testing.expectEqual(b.slotOf(le.values[0]), le_blt.b);
    try testing.expectEqual(b.pcOf(findBlock(le.blocks, "else")), llir.bTypeTarget(le_pc + 3, le_blt.offs10));
}

test "2.14 LLIR lowering: corpus fusion metric" {
    // Compiles each example, lowers it, and measures the fusion density
    // (Instruction Set §5): the code table never grows, every record
    // passes the schema check, and the immediate families appear at
    // least once across the corpus (the 2.14 acceptance).
    const corpus = [_][]const u8{
        "examples/fib.st",
        "examples/fib_tail_call.st",
        "examples/minmax.st",
        "examples/nest.st",
        "examples/ownership.st",
        "examples/match.st",
        "examples/strings.st",
        "examples/floats.st",
        "examples/fold.st",
        "examples/box.st",
        "examples/maps.st",
        "examples/arrays.st",
        "examples/generics.st",
    };
    const io = std.testing.io;
    var fused_any = false;
    for (corpus) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(src);
        var c = try compileText("app", &.{.{ "app", src }});
        defer c.deinit();
        const program = &c.program.?;

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
        const image = try b.lowerLlir();

        // The peephole never grows the image.
        try testing.expect(b.last_fusion.after_instrs <= b.last_fusion.before_instrs);
        for (program.funcs) |f| {
            const fid = b.func_ids.get(f) orelse continue;
            const fd = image.functions[fid];
            const slots = fd.f_count + fd.x_count + fd.window_count;
            for (image.instructions[fd.code_start..fd.code_end]) |rec| {
                try testing.expectEqual(@as(?llir.Issue, null), llir.checkInstr(rec, slots));
                const op = llir.decode(rec).?.op;
                if (isImmediateFamily(op)) fused_any = true;
            }
        }
        if (std.Io.File.stderr().isTty(std.testing.io) catch false) {
            std.log.info(
                "2.14 {s}: {d} -> {d} instrs ({d} bytes -> {d} bytes)",
                .{ path, b.last_fusion.before_instrs, b.last_fusion.after_instrs, b.last_fusion.before_bytes, b.last_fusion.after_bytes },
            );
        }
    }
    try testing.expect(fused_any);
}

test "2.15 LLIR lowering: compiled mul+add folds to madd/maddi, literal list read to read_indexi" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const lists = import("list");
            \\fn poly(x: int32, y: int32, c: int32) -> int32 { x * y + c }
            \\fn sink(v: int32) -> int32 { v }
            \\fn via_call(x: int32, y: int32, c: int32) -> int32 { sink(x * y + c) }
            \\fn scale(x: int32, c: int32) -> int32 { x * 2 + c }
            \\fn acc(c: float32, x: float32, y: float32) -> float32 { c + x * y }
            \\fn first(xs: list[int32]) -> int32 {
            \\    match (xs) {
            \\        [] => 0,
            \\        [h, ..t] => h,
            \\    }
            \\}
            \\fn main() -> void {
            \\    let _ = poly(3, 4, 1);
            \\    let _ = via_call(3, 4, 1);
            \\    let _ = scale(5, 1);
            \\    let _ = acc(1.0, 2.0, 3.0);
            \\    let _ = first(lists.range(0, 3));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // The four fused sites, each 8 bytes vs its expansion; the
    // constants and muls are gone, so the image shrank.
    try testing.expect(b.last_fusion.after_instrs < b.last_fusion.before_instrs);
    var n_madd: usize = 0;
    var n_maddi: usize = 0;
    var n_f32_madd: usize = 0;
    var n_read_indexi: usize = 0;
    var n_mul: usize = 0;
    var n_read_index: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f) orelse continue;
        const fd = image.functions[fid];
        const slots = fd.f_count + fd.x_count + fd.window_count;
        for (image.instructions[fd.code_start..fd.code_end]) |rec| {
            try testing.expectEqual(@as(?llir.Issue, null), llir.checkInstr(rec, slots));
            const d = llir.decode(rec).?;
            switch (d.op) {
                .madd_i32 => {
                    n_madd += 1;
                    // `x * y + c`: accumulator = c's slot (r2), product
                    // operands x/y in their original order (r0, r1).
                    try testing.expectEqual(llir.frameReg(2), d.a);
                    try testing.expectEqual(llir.frameReg(0), d.b);
                    try testing.expectEqual(llir.frameReg(1), d.c);
                },
                .maddi_i32 => {
                    n_maddi += 1;
                    // `x * 2 + c`: accumulator = c's slot (r1), imm = 2.
                    try testing.expectEqual(llir.frameReg(1), d.a);
                    try testing.expectEqual(llir.frameReg(0), d.b);
                    try testing.expectEqual(@as(u32, 2), d.c);
                },
                .madd_f32 => {
                    n_f32_madd += 1;
                    // `c + x * y`: the accumulator is already first — no
                    // reordering, imm-free.
                    try testing.expectEqual(llir.frameReg(0), d.a);
                    try testing.expectEqual(llir.frameReg(1), d.b);
                    try testing.expectEqual(llir.frameReg(2), d.c);
                },
                .read_indexi => {
                    n_read_indexi += 1;
                    try testing.expectEqual(@as(u32, 0), d.c); // imm 0
                },
                .mul_f32 => n_mul += 1,
                .read_index => n_read_index += 1,
                else => {},
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), n_madd);
    try testing.expectEqual(@as(usize, 1), n_maddi);
    try testing.expectEqual(@as(usize, 1), n_f32_madd);
    try testing.expectEqual(@as(usize, 1), n_read_indexi);
    try testing.expectEqual(@as(usize, 0), n_mul);
    try testing.expectEqual(@as(usize, 0), n_read_index);

    // The madd results live in their accumulators' physical slots.
    const poly = findFunc(program, "app.poly");
    const scale = findFunc(program, "app.scale");
    const poly_ret = retRecord(&b, image, poly).?;
    const scale_ret = retRecord(&b, image, scale).?;
    try testing.expectEqual(b.slotOf(poly.values[2]), poly_ret.a);
    try testing.expectEqual(b.slotOf(scale.values[1]), scale_ret.a);

    // A fused madd result passed as a call argument travels through the
    // window: the argument move (or the elided home) reads the fused
    // result's already-coalesced physical slot, not its SSA id.
    const via = findFunc(program, "app.via_call");
    const sink = b.func_ids.get(findFunc(program, "app.sink")).?;
    var via_add: ?*const cfg.Value = null;
    for (via.blocks) |blk| for (blk.instrs) |ins| {
        if (std.meta.activeTag(ins.op) == .add) via_add = ins.results[0];
    };
    const add_value = via_add orelse return error.TestUnexpectedResult;
    var checked_call_arg = false;
    for (via.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (std.meta.activeTag(ins.op) != .call) continue;
            const cl = ins.op.call;
            if (cl.callee != .direct) continue;
            if (b.func_name_ids.get(cl.callee.direct.name) != sink) continue;
            const moves = try b.callArgMoves(blk, ins);
            try testing.expect(moves.len <= 1); // the single arg is moved or homed
            if (moves.len == 1) {
                try testing.expectEqual(b.slotOf(add_value), moves[0].dst); // v9: a = the source register
            }
            checked_call_arg = true;
        }
    }
    try testing.expect(checked_call_arg);
}

test "2.15 LLIR lowering: madd semantics — preconditions, f32 rules, slot rewrite, read_indexi" {
    // Text-AIR control: the fused record sits at the add's PC with the
    // accumulator slot as dst; the mul record is deleted (compaction);
    // a later use of the result reads the accumulator's slot (rewrite).
    // The no-fuse cases stay as mul+add: a multi-use mul result, a
    // multi-use accumulator, an f32 add with the mul result first (no
    // reorder), and an f32 mul with the constant on the left (a plain
    // madd reads the constant's slot instead of folding an immediate).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @f(a: int32, b: int32, z: int32) -> int32 {
        \\    entry:
        \\        %3: int32 = mul %0, %1
        \\        %4: int32 = add %2, %3
        \\        %5: int32 = mul %4, %0
        \\        ret %5
        \\    }
        \\    func @g(a: int32, z: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = const 3
        \\        %3: int32 = mul %0, %2
        \\        %4: int32 = add %1, %3
        \\        ret %4
        \\    }
        \\    func @h(a: float32, b: float32, z: float32) -> float32 {
        \\    entry:
        \\        %3: float32 = mul %0, %1
        \\        %4: float32 = add %3, %2
        \\        ret %4
        \\    }
        \\    func @j(a: float32, b: float32, z: float32) -> float32 {
        \\    entry:
        \\        %3: float32 = const 2.0
        \\        %4: float32 = mul %3, %0
        \\        %5: float32 = add %2, %4
        \\        ret %5
        \\    }
        \\    func @k(a: int32, b: int32, z: int32) -> int32 {
        \\    entry:
        \\        %3: int32 = mul %0, %1
        \\        %4: int32 = add %2, %3
        \\        %5: int32 = neg %3
        \\        ret %5
        \\    }
        \\    func @m(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = mul %0, %1
        \\        %3: int32 = add %2, %0
        \\        ret %3
        \\    }
        \\    func @r(xs: list[int32]) -> int32 {
        \\    entry:
        \\        %1: int32 = const 4
        \\        %2: int32 = read_index %0, %1
        \\        %3: int32 = const 9
        \\        %4: int32 = read_index %0, %3
        \\        ret %4
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var n_i32_madd: usize = 0;
    var n_i32_maddi: usize = 0;
    var n_f32_madd: usize = 0;
    var n_f32_mul: usize = 0;
    var n_f32_add: usize = 0;
    var n_i32_mul: usize = 0;
    var n_i32_add: usize = 0;
    var n_neg: usize = 0;
    var n_read_indexi: usize = 0;
    var n_read_index: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f) orelse continue;
        const fd = image.functions[fid];
        for (image.instructions[fd.code_start..fd.code_end]) |rec| {
            const d = llir.decode(rec).?;
            switch (d.op) {
                .madd_i32 => {
                    n_i32_madd += 1;
                    // @f: `add %2, %3` → dst = the accumulator (r2),
                    // product operands in order (r0, r1).
                    try testing.expectEqual(b.slotOf(f.values[2]), d.a);
                    try testing.expectEqual(b.slotOf(f.values[0]), d.b);
                    try testing.expectEqual(b.slotOf(f.values[1]), d.c);
                },
                .maddi_i32 => {
                    n_i32_maddi += 1;
                    // @g: `mul %0, 3` + `add %1, %m`.
                    try testing.expectEqual(b.slotOf(f.values[1]), d.a);
                    try testing.expectEqual(b.slotOf(f.values[0]), d.b);
                    try testing.expectEqual(@as(u32, 3), d.c);
                },
                .madd_f32 => {
                    n_f32_madd += 1;
                    // @j: the f32 const multiplier stays on the left — a
                    // plain madd reads the constant's slot (r3), never an
                    // immediate (mul operand order preserved).
                    try testing.expectEqual(b.slotOf(f.values[2]), d.a);
                    try testing.expectEqual(b.slotOf(f.values[3]), d.b);
                    try testing.expectEqual(b.slotOf(f.values[0]), d.c);
                },
                .mul_f32 => n_f32_mul += 1, // @h: no reorder, no fusion
                .add_f32 => n_f32_add += 1,
                .mul_i32 => n_i32_mul += 1, // @k (multi-use product), @m (multi-use accumulator)
                .add_i32 => n_i32_add += 1,
                .neg_i32 => n_neg += 1,
                .read_indexi => {
                    n_read_indexi += 1;
                    // @r: two literal-index reads, c = 4 and c = 9.
                    if (n_read_indexi == 1) {
                        try testing.expectEqual(@as(u32, 4), d.c);
                    } else {
                        try testing.expectEqual(@as(u32, 9), d.c);
                    }
                },
                .read_index => n_read_index += 1,
                else => {},
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), n_i32_madd);
    try testing.expectEqual(@as(usize, 1), n_i32_maddi);
    try testing.expectEqual(@as(usize, 1), n_f32_madd);
    try testing.expectEqual(@as(usize, 1), n_f32_mul);
    try testing.expectEqual(@as(usize, 1), n_f32_add);
    try testing.expectEqual(@as(usize, 3), n_i32_mul); // @f's second mul, @k, @m
    try testing.expectEqual(@as(usize, 2), n_i32_add); // @k, @m
    try testing.expectEqual(@as(usize, 1), n_neg);
    try testing.expectEqual(@as(usize, 2), n_read_indexi);
    try testing.expectEqual(@as(usize, 0), n_read_index);

    // The slot rewrite: @f's second mul reads the madd result, which
    // now lives in the accumulator's slot (r2) — its `b` is 2, not 4.
    // The fused mul left no record, so the surviving mul is the
    // consumer; scan the function's compacted record range directly.
    const f = findFunc(program, "f");
    const f_fi = b.func_ids.get(f).?;
    const f_fd = image.functions[f_fi];
    var found_rewritten = false;
    for (image.instructions[f_fd.code_start..f_fd.code_end]) |rec| {
        const d = llir.decode(rec).?;
        if (d.op == .mul_i32) {
            try testing.expectEqual(llir.frameReg(2), d.b); // reads the remapped result slot
            found_rewritten = true;
        }
    }
    try testing.expect(found_rewritten);

    // @g's const 3 was inlined into the maddi and deleted; the madd's
    // mul record was deleted too — compaction shrank the image.
    try testing.expect(b.last_fusion.after_instrs < b.last_fusion.before_instrs);
}

test "2.15 LLIR lowering: corpus fused multiply-accumulate and immediate-index metric" {
    const corpus = [_][]const u8{
        "examples/fib.st",
        "examples/fib_tail_call.st",
        "examples/minmax.st",
        "examples/nest.st",
        "examples/ownership.st",
        "examples/match.st",
        "examples/strings.st",
        "examples/floats.st",
        "examples/fold.st",
        "examples/box.st",
        "examples/maps.st",
        "examples/arrays.st",
        "examples/generics.st",
        "examples/madd.st",
    };
    const io = std.testing.io;
    var n_madd: usize = 0;
    var n_maddi: usize = 0;
    var n_read_indexi: usize = 0;
    for (corpus) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(src);
        var c = try compileText("app", &.{.{ "app", src }});
        defer c.deinit();
        const program = &c.program.?;

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
        const image = try b.lowerLlir();

        try testing.expect(b.last_fusion.after_instrs <= b.last_fusion.before_instrs);
        for (program.funcs) |f| {
            const fid = b.func_ids.get(f) orelse continue;
            const fd = image.functions[fid];
            const slots = fd.f_count + fd.x_count + fd.window_count;
            for (image.instructions[fd.code_start..fd.code_end]) |rec| {
                try testing.expectEqual(@as(?llir.Issue, null), llir.checkInstr(rec, slots));
                const op = llir.decode(rec).?.op;
                switch (op) {
                    .madd_f32, .madd_f64 => n_madd += 1,
                    .maddi_i32, .maddi_u32 => n_maddi += 1,
                    .read_indexi => n_read_indexi += 1,
                    else => {},
                }
            }
        }
        if (std.Io.File.stderr().isTty(std.testing.io) catch false) {
            std.log.info(
                "2.15 {s}: {d} -> {d} instrs ({d} bytes -> {d} bytes)",
                .{ path, b.last_fusion.before_instrs, b.last_fusion.after_instrs, b.last_fusion.before_bytes, b.last_fusion.after_bytes },
            );
        }
    }
    // Each fused family appears at least once across the corpus (the
    // acceptance): madd.st contributes all three.
    try testing.expect(n_madd >= 1);
    try testing.expect(n_maddi >= 1);
    try testing.expect(n_read_indexi >= 1);
}

fn retRecord(b: *cfg_lower_llir.Builder, image: llir.LlirProgram, f: *const cfg.IrFunc) ?llir.Decoded {
    const fid = b.func_ids.get(f).?;
    const range = b.block_ranges.items[fid];
    for (0..range.len) |k| {
        const blk = b.ordered_blocks.items[range.start + k];
        if (blk.terminator == .ret) {
            // The terminator is the block's last record — after the
            // non-phi area (argument moves included) and the edge copies.
            const bd = image.blocks[b.block_ids.get(blk).?];
            return llir.decode(image.instructions[bd.end_pc - 1]);
        }
    }
    return null;
}

test "2.15 LLIR lowering: lifecycle fusion requires release src == move dst" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var program = std.mem.zeroes(cfg.IrProgram);
    var blk = cfg.BasicBlock{
        .id = 0,
        .span = ast.Span.init(0, 0, 0),
        .name = "blk",
        .instrs = &.{},
        .terminator = .{ .ret = null },
        .preds = &.{},
    };
    var b = cfg_lower_llir.Builder.init(arena, &program);
    try b.ordered_blocks.append(arena, &blk);
    try b.ordered_blocks.append(arena, &blk); // two blocks: one per case
    try b.edge_copy_counts.append(arena, 0);
    try b.edge_copy_counts.append(arena, 0);
    try b.non_phi_counts.append(arena, 2);
    try b.non_phi_counts.append(arena, 2);

    // Mismatched pair: release F0; move F1, F2 — the F0 release must
    // survive and the move must stay a plain move (no replace_move).
    var recs = std.ArrayList(llir.Instr).empty;
    try recs.append(arena, llir.instrE(.release, 0, 0));
    try recs.append(arena, llir.instrE(.move, 1, 2));
    try b.block_records.append(arena, recs);
    _ = try llir_fuse_lc.fuseLifecycle(&b);
    try testing.expectEqual(@as(usize, 2), b.block_records.items[0].items.len);
    try testing.expectEqual(llir.Opcode.release, llir.decode(b.block_records.items[0].items[0]).?.op);
    try testing.expectEqual(llir.Opcode.move, llir.decode(b.block_records.items[0].items[1]).?.op);

    // Same-slot pair: release F0; move F0, F2 — fuses to replace_move.
    var recs2 = std.ArrayList(llir.Instr).empty;
    try recs2.append(arena, llir.instrE(.release, 0, 0));
    try recs2.append(arena, llir.instrE(.move, 0, 2));
    try b.block_records.append(arena, recs2);
    _ = try llir_fuse_lc.fuseLifecycle(&b);
    try testing.expectEqual(@as(usize, 1), b.block_records.items[1].items.len);
    try testing.expectEqual(llir.Opcode.replace_move, llir.decode(b.block_records.items[1].items[0]).?.op);
}
