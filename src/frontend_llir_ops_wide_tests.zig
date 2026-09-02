//! Test file: `frontend LLIR ops, wide & casts` — LLIR lowering post-stage-2
//! specialization: the 2.6 branchless select, the A2 frame-limit and
//! long-branch expansions, Phase 5 64-bit/f64/wide ops, and 3.1 directed
//! casts and comparisons. Split out of `frontend_llir_ops_tests.zig`;
//! no file-local helpers.
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

test "2.6 LLIR lowering: a select emits copy cond_reg + cmov" {
    // The branchless select (air.md §5.2) lowers to two records:
    // `copy cond_reg, %cond` loads the bool condition into the
    // condition register, then `cmov dst, %a, %b` moves the selected
    // 32-bit scalar pattern (dst = cond_reg ? a : b) — the
    // if-conversion's whole point, replacing the compare-and-branch
    // plus two edge copies.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @pick(c: bool, a: int32, b: int32) -> int32 {
        \\entry:
        \\    %3: int32 = select %0, %1, %2
        \\    ret %3
        \\}
        \\func @main() -> void {
        \\entry:
        \\    ret
        \\}
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const asm_text = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm_text);
    // F0 prints as its raw encoding r19 (frame_base = 0x13).
    try testing.expect(std.mem.indexOf(u8, asm_text, "copy cond, r19") != null);
    try testing.expect(std.mem.indexOf(u8, asm_text, "cmov r") != null);
    // The block is two records + the j: no branch records remain.
    const pf = b.func_ids.get(program.funcs[0]).?;
    const r = b.block_ranges.items[pf];
    const entry_pc = image.blocks[r.start].start_pc;
    const ret_pc = image.blocks[r.start + 1].start_pc;
    try testing.expectEqual(@as(u32, 3), ret_pc - entry_pc); // copy cond, cmov, j
}

// ---------------------------------------------------------------------------
// shorten-intr.md A2 acceptance: the 32-bit emission layer's limits.
// ---------------------------------------------------------------------------

test "A2 LLIR lowering: a frame over frame_count_max fails with ProgramTooLarge" {
    // A function whose parameters alone exceed the 224-slot frame cap
    // (shorten-intr.md §4: F0–F223). The allocator's checked limit —
    // never a silent truncation — fails the lowering with
    // `error.ProgramTooLarge`.
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "module \"app\" {\n    func @big(");
    for (0..230) |i| {
        if (i > 0) try src.appendSlice(testing.allocator, ", ");
        const param = try std.fmt.allocPrint(testing.allocator, "a{d}: int32", .{i});
        defer testing.allocator.free(param);
        try src.appendSlice(testing.allocator, param);
    }
    try src.appendSlice(testing.allocator, ") -> int32 {\n    entry:\n        ret %0\n    }\n}\n");
    var t = try cfg_parse.parseText(src.items);
    defer t.arena.deinit();
    var b = cfg_lower_llir.Builder.init(t.arena.allocator(), &t.program);
    try testing.expectError(error.ProgramTooLarge, b.lowerLlir());
    // The input CFG is untouched (the read-only invariant), and the
    // image never escaped the Builder.
    try testing.expectEqual(@as(usize, 230), t.program.funcs[0].params.len);
}

test "A2 LLIR lowering: long-branch expansion — inverted branch + j, iterated to convergence" {
    // A branch whose target lies beyond the compare-and-branch's ±512
    // reach expands to `b<inverted> a, b, +2` followed by a link-less `j`
    // (the Instruction Set §11.1 safety net). The layout below forces
    // two expansion rounds: `br1` sits at exactly the 512-instruction
    // boundary, so round 1 expands only `br2` — the inserted `j`
    // shifts `t1` one record further, pushing `br1` out of reach and
    // expanding it in round 2; round 3 converges with no expansions
    // left. (Each typed `add` is exactly one record — §4 —
    // so m1's 508 adds span exactly 508 records.)
    //
    // Block order (cfg.BlockOrder, ascending minimum def id): entry,
    // m1 (%3..%510 + copy %511), t1 (%512), m2 (%513..), t2 (def-less,
    // last). Round 1 layout: br1 at pc 0, t1 at pc 511 (in reach);
    // br2 at pc 510, t2 at pc 1531 (distance 1021 — far).
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator,
        \\module "app" {
        \\    func @far(c1: bool, c2: bool, a: int32) -> int32 {
        \\    entry:
        \\        br %0 ? t1 : m1
        \\    m1:
        \\
    );
    for (3..511) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: int32 = add %2, %2\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        %511: bool = copy %1
        \\        br %511 ? t2 : m2
        \\    t1:
        \\        %512: int32 = add %2, %2
        \\        ret %512
        \\    m2:
        \\
    );
    for (513..1021) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "        %{d}: int32 = add %2, %2\n", .{i});
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator,
        \\        ret %2
        \\    t2:
        \\        ret %2
        \\    }
        \\}
    );
    var t = try cfg_parse.parseText(src.items);
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // The expansion converged over three rounds (round 1: br2, round
    // 2: br1, round 3: no expansions).
    try testing.expectEqual(@as(u32, 3), b.expansion_rounds);
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        defer testing.allocator.free(msg);
        std.log.err("A2 expanded image rejected: {s}", .{msg});
        return error.TestUnexpectedResult;
    }

    // Find the blocks and the two branch records.
    const t1 = findBlock(program.funcs[0].blocks, "t1");
    const t2 = findBlock(program.funcs[0].blocks, "t2");
    const m1 = findBlock(program.funcs[0].blocks, "m1");
    const m2 = findBlock(program.funcs[0].blocks, "m2");
    const t1_pc = b.pcOf(t1);
    const t2_pc = b.pcOf(t2);
    const m1_pc = b.pcOf(m1);
    const m2_pc = b.pcOf(m2);

    // br1 (in entry): inverted to `beq cond, zero` with the +2 skip,
    // and the inserted `j` right after it carries t1. The pair is
    // entry's last two records, immediately before m1.
    const br1_pc = m1_pc - 2;
    const br1 = llir.decode(image.instructions[br1_pc]).?;
    try testing.expectEqual(llir.Opcode.beq, br1.op); // bne inverted
    try testing.expectEqual(@as(i16, 2), br1.offs10); // skip the inserted j
    const j1 = llir.decode(image.instructions[br1_pc + 1]).?;
    try testing.expectEqual(llir.Opcode.j, j1.op);
    // The register field carries `zero`, j's no-link mark — a `ra`
    // there would make the very same word a call.
    try testing.expectEqual(llir.zero_reg, j1.a);
    try testing.expectEqual(@as(u32, t1_pc), llir.jalTarget(br1_pc + 1, j1.imm20));
    // The +2 skip's fall-through lands on m1 (the else path).
    try testing.expectEqual(m1_pc, br1_pc + 2);

    // br2 (in m1, a two-record `br` whose else is m2): the expansion
    // inserted its `j` between the branch and the trailing `j`,
    // so the records are [beq +2, j t2, j m2] — the
    // last three before t1.
    const br2_pc = t1_pc - 3;
    const br2 = llir.decode(image.instructions[br2_pc]).?;
    try testing.expectEqual(llir.Opcode.beq, br2.op);
    try testing.expectEqual(@as(i16, 2), br2.offs10);
    const j2 = llir.decode(image.instructions[br2_pc + 1]).?;
    try testing.expectEqual(llir.Opcode.j, j2.op);
    try testing.expectEqual(@as(u32, t2_pc), llir.jalTarget(br2_pc + 1, j2.imm20));
    // The trailing jal (the two-record form's else carrier) survives at
    // br2_pc + 2 and still targets m2.
    const j2b = llir.decode(image.instructions[br2_pc + 2]).?;
    try testing.expectEqual(llir.Opcode.j, j2b.op);
    try testing.expectEqual(@as(u32, m2_pc), llir.jalTarget(br2_pc + 2, j2b.imm20));
}

// ---------------------------------------------------------------------------
// Phase 5 — 64-bit widths in frontend lowering (TODO.md 阶段 5)
// ---------------------------------------------------------------------------

test "Phase 5 LLIR lowering: 64-bit integer and f64 ops specialize by type" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn iadd(a: int64, b: int64) -> int64 { a + b }
            \\fn usub(a: uint64, b: uint64) -> uint64 { a - b }
            \\fn imul(a: int64, b: int64) -> int64 { a * b }
            \\fn idiv(a: int64, b: int64) -> int64 { a / b }
            \\fn udiv(a: uint64, b: uint64) -> uint64 { a / b }
            \\fn irem(a: int64, b: int64) -> int64 { a % b }
            \\fn urem(a: uint64, b: uint64) -> uint64 { a % b }
            \\fn ineg(a: int64) -> int64 { -a }
            \\fn fadd(a: float64, b: float64) -> float64 { a + b }
            \\fn fsub(a: float64, b: float64) -> float64 { a - b }
            \\fn fmul(a: float64, b: float64) -> float64 { a * b }
            \\fn fdiv(a: float64, b: float64) -> float64 { a / b }
            \\fn frem(a: float64, b: float64) -> float64 { a % b }
            \\fn fneg(a: float64) -> float64 { -a }
            \\fn ishl(a: int64, b: int64) -> int64 { a << b }
            \\fn ushr(a: uint64, b: uint64) -> uint64 { a >> b }
            \\fn ishr(a: int64, b: int64) -> int64 { a >> b }
            \\fn iand(a: int64, b: int64) -> int64 { a & b }
            \\fn uor(a: uint64, b: uint64) -> uint64 { a | b }
            \\fn uxor(a: uint64, b: uint64) -> uint64 { a ^ b }
            \\fn ilt(a: int64, b: int64) -> bool { a < b }
            \\fn ult(a: uint64, b: uint64) -> bool { a < b }
            \\fn ule(a: uint64, b: uint64) -> bool { a <= b }
            \\fn ige(a: int64, b: int64) -> bool { a >= b }
            \\fn ugt(a: uint64, b: uint64) -> bool { a > b }
            \\fn igt(a: int64, b: int64) -> bool { a > b }
            \\fn ieq(a: int64, b: int64) -> bool { a == b }
            \\fn une(a: uint64, b: uint64) -> bool { a != b }
            \\fn flt(a: float64, b: float64) -> bool { a < b }
            \\fn fle(a: float64, b: float64) -> bool { a <= b }
            \\fn fge(a: float64, b: float64) -> bool { a >= b }
            \\fn fgt(a: float64, b: float64) -> bool { a > b }
            \\fn feq(a: float64, b: float64) -> bool { a == b }
            \\fn fne(a: float64, b: float64) -> bool { a != b }
            \\fn main() -> void {
            \\    let a: int64 = 1; let b: int64 = 2;
            \\    let c: uint64 = 1; let d: uint64 = 2;
            \\    let e: float64 = 1.0; let f: float64 = 2.0;
            \\    iadd(a, b); usub(c, d); imul(a, b); idiv(a, b); udiv(c, d); irem(a, b); urem(c, d);
            \\    ineg(a); fadd(e, f); fsub(e, f); fmul(e, f); fdiv(e, f); frem(e, f); fneg(e);
            \\    ishl(a, b); ushr(c, d); ishr(a, b); iand(a, b); uor(c, d); uxor(c, d);
            \\    ilt(a, b); ult(c, d); ule(c, d); ige(a, b); ugt(c, d); igt(a, b); ieq(a, b); une(c, d);
            \\    flt(e, f); fle(e, f); fge(e, f); fgt(e, f); feq(e, f); fne(e, f);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // Walk every non-phi instruction and check its record against the
    // phase-4/5 matrix: i64/u64 get the typed integer opcodes (the
    // `u` rep split for div/rem/ordering), f64 its own opcode block,
    // and every comparison is a C-Type family member writing the
    // implicit `cond`, materialized by `copy dst, cond` (le/gt are the
    // operand-swap aliases — no `gtu`+`not` synthesis exists in v9).
    var seen = std.StaticBitSet(512).initEmpty();
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                const prim = ins.results[0].type_.primitive;
                const tag = std.meta.activeTag(ins.op);
                switch (tag) {
                    .add, .sub, .mul, .div, .rem, .neg => {
                        const want: llir.Opcode = llir.typedOpcode(llir.lower(tag).typed, ins.results[0].type_, undefined) orelse unreachable;
                        const d = llir.decode(image.instructions[pc]).?;
                        try testing.expectEqual(want, d.op);
                        seen.set(@intFromEnum(want));
                    },
                    .shl, .shr => {
                        const want: llir.Opcode = llir.typedOpcode(llir.lower(tag).typed, ins.results[0].type_, undefined) orelse unreachable;
                        const d = llir.decode(image.instructions[pc]).?;
                        try testing.expectEqual(want, d.op);
                        seen.set(@intFromEnum(want));
                    },
                    .bitand, .bitor, .bitxor => {
                        const want: llir.Opcode = switch (prim) {
                            .int64 => switch (tag) {
                                .bitand => .and_,
                                .bitor => .or_,
                                .bitxor => .xor,
                                else => unreachable,
                            },
                            .uint64 => switch (tag) {
                                .bitand => .and_,
                                .bitor => .or_,
                                .bitxor => .xor,
                                else => unreachable,
                            },
                            else => unreachable,
                        };
                        const d = llir.decode(image.instructions[pc]).?;
                        try testing.expectEqual(want, d.op);
                        seen.set(@intFromEnum(want));
                    },
                    .eq, .ne, .lt, .le, .gt, .ge => {
                        // The comparison's signedness comes from the
                        // operand type (`bin.a`), never the bool result.
                        const bin: cfg.Bin = switch (ins.op) {
                            .eq, .ne, .lt, .le, .gt, .ge => |bb| bb,
                            else => unreachable,
                        };
                        const oprim = bin.a.type_.primitive;
                        // v9: the C-Type families — `gt` and float
                        // `ge` lower through the operand-swap aliases
                        // (`a > b` ≡ `slt b, a`, `a >= b` ≡ `sle b, a`;
                        // the swap preserves every predicate's NaN
                        // behavior).
                        const want: llir.Opcode = switch (oprim) {
                            .int64 => switch (tag) {
                                .eq => .seq,
                                .ne => .sne,
                                .lt => .slt,
                                .gt => .slt,
                                .le => .slt,
                                .ge => .slt,
                                else => unreachable,
                            },
                            .uint64 => switch (tag) {
                                .eq => .seq,
                                .ne => .sne,
                                .lt => .sltu,
                                .gt => .sltu,
                                .le => .sltu,
                                .ge => .sltu,
                                else => unreachable,
                            },
                            .float64 => switch (tag) {
                                .eq => .seq_f64,
                                .ne => .sne_f64,
                                .lt => .slt_f64,
                                .gt => .slt_f64,
                                .le => .sle_f64,
                                .ge => .sle_f64,
                                else => unreachable,
                            },
                            else => unreachable,
                        };
                        const d = llir.decode(image.instructions[pc]).?;
                        try testing.expectEqual(want, d.op);
                        seen.set(@intFromEnum(want));
                        // Every C-Type comparison writes the implicit
                        // `cond`; the SSA bool result is materialized by
                        // `copy dst, cond` right after.
                        var nd = llir.decode(image.instructions[pc + 1]).?;
                        if (nd.op == .not) nd = llir.decode(image.instructions[pc + 2]).?;
                        try testing.expectEqual(llir.Opcode.copy, nd.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), nd.a);
                        try testing.expectEqual(llir.cond_reg, nd.b);
                        seen.set(@intFromEnum(llir.Opcode.copy));
                    },
                    else => {}, // main's calls + ret
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    // Every distinct opcode of the phase-5 matrix was selected at
    // least once (the count varies with inlining, so coverage is the
    // assertion, not the total).
    // The exact set the phase-5 source emits: the typed members carry
    // the operand rep — `iadd` is `add.i64`, `usub` `sub.u64`, `udiv`
    // `div.u64`, `ineg` `neg.i64`, `ishl` `shl.i64`, `ushr` `shr.u64`
    // — the bitwise ops stay widthless, and every comparison is a
    // C-Type family member (integer `le`/`ge` synthesize `not(slt)`).
    const want_seen = [_]llir.Opcode{
        .add_i64,
        .sub_u64,
        .mul_i64,
        .div_i64,
        .div_u64,
        .rem_i64,
        .rem_u64,
        .neg_i64,
        .add_f64,
        .sub_f64,
        .mul_f64,
        .div_f64,
        .rem_f64,
        .neg_f64,
        .shl_i64,
        .shr_i64,
        .shr_u64,
        .and_,
        .or_,
        .xor,
        .seq,
        .seq_f64,
        .sne,
        .sne_f64,
        .slt,
        .sltu,
        .slt_f64,
        .sle_f64,
        .copy,
    };
    for (want_seen) |op| try testing.expect(seen.isSet(@intFromEnum(op)));
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }
}

test "Phase 5 LLIR lowering: f64 conversions carry the explicit cvt opcode" {
    // The eight directed pairs involving f64 (the phase-5 additions to
    // the five-type conversion matrix): v9 spells each pair as its own
    // C-Type opcode `cvt.<src>.<dst>` (a = dst, b = src) — no
    // `c` discriminator rides in the record.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f2i(a: float64) -> int32 { a as int32 }
            \\fn f2u(a: float64) -> uint32 { a as uint32 }
            \\fn f2b(a: float64) -> byte { a as byte }
            \\fn f2f(a: float64) -> float32 { a as float32 }
            \\fn i2f(a: int32) -> float64 { a as float64 }
            \\fn u2f(a: uint32) -> float64 { a as float64 }
            \\fn b2f(a: byte) -> float64 { a as float64 }
            \\fn f2f32(a: float32) -> float64 { a as float64 }
            \\fn main() -> void {
            \\    let a: float64 = 1.0;
            \\    f2i(a); f2u(a); f2b(a); f2f(a); i2f(1); u2f(1 as uint32);
            \\    b2f(1 as byte); f2f32(1.0);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // (src, dst) → expected opcode.
    const cases = [_]struct { src: llir.PrimitiveId, dst: llir.PrimitiveId, want_op: llir.Opcode }{
        .{ .src = .float64, .dst = .int32, .want_op = .cvt_f64_i32 },
        .{ .src = .float64, .dst = .uint32, .want_op = .cvt_f64_u32 },
        .{ .src = .float64, .dst = .float32, .want_op = .cvt_f64_f32 },
        .{ .src = .float64, .dst = .byte, .want_op = .cvt_f64_b },
        .{ .src = .int32, .dst = .float64, .want_op = .cvt_i32_f64 },
        .{ .src = .uint32, .dst = .float64, .want_op = .cvt_u32_f64 },
        .{ .src = .byte, .dst = .float64, .want_op = .cvt_b_f64 },
        .{ .src = .float32, .dst = .float64, .want_op = .cvt_f32_f64 },
    };
    // Walk only the eight cast functions (main's argument casts,
    // e.g. `1 as byte`, are the 32-bit pairs, not part of this matrix).
    const cast_funcs = [_][]const u8{ "app.f2i", "app.f2u", "app.f2b", "app.f2f", "app.i2f", "app.u2f", "app.b2f", "app.f2f32" };
    var found: usize = 0;
    for (cast_funcs) |fname| {
        const fi = b.func_ids.get(findFunc(program, fname)).?;
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (std.meta.activeTag(ins.op) == .num_cast) {
                    const src: llir.PrimitiveId = switch (ins.op.num_cast.type_.primitive) {
                        .float64 => .float64,
                        .int32 => .int32,
                        .uint32 => .uint32,
                        .byte => .byte,
                        .float32 => .float32,
                        else => unreachable,
                    };
                    const dst: llir.PrimitiveId = switch (ins.results[0].type_.primitive) {
                        .float64 => .float64,
                        .int32 => .int32,
                        .uint32 => .uint32,
                        .byte => .byte,
                        .float32 => .float32,
                        else => unreachable,
                    };
                    const want = blk: {
                        for (cases) |case_| {
                            if (case_.src == src and case_.dst == dst) break :blk case_;
                        }
                        unreachable; // every cast in the source is one of the eight pairs
                    };
                    const d = llir.decode(image.instructions[pc]).?;
                    try testing.expectEqual(want.want_op, d.op);
                    try testing.expectEqual(b.slotOf(ins.results[0]), d.a); // a = the result slot
                    try testing.expectEqual(b.slotOf(ins.op.num_cast), d.b); // b = the source
                    found += 1;
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 8), found);
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }
}

test "Phase 5 LLIR lowering: 64-bit comparison branches test the full cell" {
    // `a < b` with a = 2^32, b = 5: false at 64 bits, but a low-word
    // compare (0 < 5) would take the branch. The branch record must be
    // a bool test (`beq`/`bne cond, zero` — 64-bit comparisons never
    // fuse into the 32-bit blt/bltu family), and the interpreter must
    // run the else arm.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn pick(a: uint64, b: uint64) -> uint64 {
            \\    if (a < b) { 1 } else { 2 }
            \\}
            \\fn main() -> uint64 { pick(4294967296, 5) }
            ,
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    var image = try b.lowerLlir();

    // The comparison lowers to `sltu` (C-Type, implicit cond) plus
    // `copy dst, cond`; the branch fuses the u64 operands into a typed
    // compare-and-branch — `bltu`/`bleu` by layout polarity —
    // never the 32-bit family (`blt`/`ble`), so the full cell
    // is tested (a low-word compare would take the wrong arm). Walk
    // `pick` for both.
    const f = findFunc(program, "app.pick");
    const fid = b.func_ids.get(f).?;
    const range = b.block_ranges.items[fid];
    var saw_slt = false;
    var saw_branch = false;
    for (range.start..range.start + range.len) |bi| {
        const blk = b.ordered_blocks.items[bi];
        var pc = b.pcOf(blk);
        const recs = b.non_phi_counts.items[bi] + b.edge_copy_counts.items[bi] + b.terminatorRecordCount(blk);
        for (0..recs) |k| {
            const d = llir.decode(image.instructions[pc + k]).?;
            const op = d.op;
            if (op == .sltu) saw_slt = true;
            if (op == .bltu or op == .bleu) saw_branch = true;
        }
        pc += recs;
    }
    try testing.expect(saw_slt and saw_branch);

    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }
    const main_fid = b.func_ids.get(findFunc(program, "app.main")).?;
    var term = try interpreter.runValidatedWithEntry(testing.allocator, &image, main_fid, .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(u64, 2), v),
        .panic => return error.TestUnexpectedResult,
    }
}

test "Phase 5: i64/u64 integer casts lower to the 64-bit cvt opcodes" {
    // The conversion family includes `i64`/`u64` destinations — the
    // 64-bit milestone — so `i64 as int32` and `u64 as f64` lower to
    // their explicit `cvt.<src>.<dst>` records and validate.
    var c1 = try compileText("app", &.{
        .{ "app", "fn main() -> int32 { let x: int64 = 1; x as int32 }" },
    });
    defer c1.deinit();
    const program = &c1.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));
    const asm1 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm1);
    try testing.expect(std.mem.indexOf(u8, asm1, "cvt.i64.i32") != null);

    var c2 = try compileText("app", &.{
        .{ "app", "fn main() -> float64 { let x: uint64 = 1; x as float64 }" },
    });
    defer c2.deinit();
    const program2 = &c2.program.?;

    var b2 = cfg_lower_llir.Builder.init(arena.allocator(), program2);
    const image2 = try b2.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image2, testing.allocator));
    const asm2 = try lower.llirAsm(&b2, image2, testing.allocator);
    defer testing.allocator.free(asm2);
    try testing.expect(std.mem.indexOf(u8, asm2, "cvt.u64.f64") != null);
}

test "Phase 5 LLIR lowering: u64 constants materialize through move-wide sequences" {
    // Each u64 constant lowers to 1–4 move-wide records (the
    // deterministic starter + movwk fixes), writes no ConstRecord row,
    // and the validator + interpreter agree with the source bit
    // pattern. i64/f64 constants keep the typed `const` path.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn zero() -> uint64 { 0 }
            \\fn low() -> uint64 { 65535 }
            \\fn hi() -> uint64 { 4294901760 }
            \\fn max() -> uint64 { 18446744073709551615 }
            \\fn single() -> uint64 { 4294967296 }
            \\fn four() -> uint64 { 81985529216486895 }
            \\fn tie() -> uint64 { 18446462603027742720 }
            \\fn iconst() -> int64 { 9223372036854775807 }
            \\fn fconst() -> float64 { 1.5 }
            \\fn main() -> uint64 { zero() + low() }
            ,
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    var image = try b.lowerLlir();

    const cases = [_]struct { name: []const u8, pattern: u64 }{
        .{ .name = "app.zero", .pattern = 0 },
        .{ .name = "app.low", .pattern = 0xffff },
        .{ .name = "app.hi", .pattern = 0xffff0000 },
        .{ .name = "app.max", .pattern = 0xffff_ffff_ffff_ffff },
        .{ .name = "app.single", .pattern = 0x1_0000_0000 }, // lane 2 only
        .{ .name = "app.four", .pattern = 0x0123_4567_89ab_cdef },
        .{ .name = "app.tie", .pattern = 0xffff_0000_ffff_0000 }, // ties → movwn0 + movwk2
    };
    for (cases) |case_| {
        const f = findFunc(program, case_.name);
        const fid = b.func_ids.get(f).?;
        const range = b.block_ranges.items[fid];
        var consts_seen: usize = 0;
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (std.meta.activeTag(ins.op) == .const_) {
                    consts_seen += 1;
                    const recs = try b.recordCount(blk, ins);
                    try testing.expect(recs >= 1 and recs <= 4);
                    // Reconstruct the pattern from the emitted records.
                    var acc: u64 = 0;
                    var have: bool = false;
                    for (0..recs) |k| {
                        const d = llir.decode(image.instructions[pc + k]).?;
                        const op = d.op;
                        const imm: u16 = d.imm16;
                        const n: u2 = switch (op) {
                            .movwn1, .movwz1, .movwk1 => 1,
                            .movwn2, .movwz2, .movwk2 => 2,
                            .movwn3, .movwz3, .movwk3 => 3,
                            else => 0,
                        };
                        switch (op) {
                            .movwn0, .movwn1, .movwn2, .movwn3 => {
                                try testing.expect(!have); // the starter comes first
                                acc = llir.movwnValue(n, imm);
                                have = true;
                            },
                            .movwz0, .movwz1, .movwz2, .movwz3 => {
                                try testing.expect(!have); // the starter comes first
                                acc = llir.movwzValue(n, imm);
                                have = true;
                            },
                            .movwk0, .movwk1, .movwk2, .movwk3 => {
                                try testing.expect(have); // a fix needs the starter's pattern
                                acc = llir.movwkValue(n, imm, acc);
                            },
                            else => return error.TestUnexpectedResult,
                        }
                    }
                    try testing.expect(have);
                    try testing.expectEqual(case_.pattern, acc);
                }
                pc += try b.recordCount(blk, ins);
            }
        }
        try testing.expectEqual(@as(usize, 1), consts_seen);
    }

    // The deterministic starter rule, locked on the well-known cases:
    // 0xffff0000 is a single movwz1 (lane 1); the four-lane mixed value
    // starts movwz0 then fixes lanes 1→3; the 0xffff0000ffff0000 tie
    // picks movwn0 (smallest N) then fixes lane 2.
    const hi_f = findFunc(program, "app.hi");
    const hi_fid = b.func_ids.get(hi_f).?;
    const hi_br = b.block_ranges.items[hi_fid];
    const hi_blk = b.ordered_blocks.items[hi_br.start];
    var hi_pc = b.pcOf(hi_blk);
    for (hi_blk.instrs) |ins| {
        if (std.meta.activeTag(ins.op) == .phi) continue;
        if (std.meta.activeTag(ins.op) == .const_) {
            try testing.expectEqual(llir.Opcode.movwz1, llir.decode(image.instructions[hi_pc]).?.op);
        }
        hi_pc += try b.recordCount(hi_blk, ins);
    }
    const four_f = findFunc(program, "app.four");
    const four_fid = b.func_ids.get(four_f).?;
    const four_br = b.block_ranges.items[four_fid];
    const four_blk = b.ordered_blocks.items[four_br.start];
    var four_pc = b.pcOf(four_blk);
    for (four_blk.instrs) |ins| {
        if (std.meta.activeTag(ins.op) == .phi) continue;
        if (std.meta.activeTag(ins.op) == .const_) {
            try testing.expectEqual(llir.Opcode.movwz0, llir.decode(image.instructions[four_pc]).?.op);
            try testing.expectEqual(llir.Opcode.movwk1, llir.decode(image.instructions[four_pc + 1]).?.op);
            try testing.expectEqual(llir.Opcode.movwk2, llir.decode(image.instructions[four_pc + 2]).?.op);
            try testing.expectEqual(llir.Opcode.movwk3, llir.decode(image.instructions[four_pc + 3]).?.op);
        }
        four_pc += try b.recordCount(four_blk, ins);
    }
    const tie_f = findFunc(program, "app.tie");
    const tie_fid = b.func_ids.get(tie_f).?;
    const tie_br = b.block_ranges.items[tie_fid];
    const tie_blk = b.ordered_blocks.items[tie_br.start];
    var tie_pc = b.pcOf(tie_blk);
    for (tie_blk.instrs) |ins| {
        if (std.meta.activeTag(ins.op) == .phi) continue;
        if (std.meta.activeTag(ins.op) == .const_) {
            try testing.expectEqual(llir.Opcode.movwn0, llir.decode(image.instructions[tie_pc]).?.op);
            try testing.expectEqual(llir.Opcode.movwk2, llir.decode(image.instructions[tie_pc + 1]).?.op);
        }
        tie_pc += try b.recordCount(tie_blk, ins);
    }

    // No u64 constant writes a ConstRecord row (the constants side
    // table holds only the non-move-wide constants; i64/f64 keep the
    // typed `const` path — covered by the phase-4 tests).
    var u64_ty: ?u32 = null;
    for (image.types, 0..) |row, i| {
        if (row.kind == .primitive and row.a == @intFromEnum(llir.PrimitiveId.uint64)) u64_ty = @intCast(i);
    }
    try testing.expect(u64_ty != null); // the type row exists (signatures)
    for (image.constants) |cr| {
        try testing.expect(cr.type_ != u64_ty.?);
    }

    // i64/f64 constants keep the typed `const` path — a single
    // `const` record, never move-wide (the move-wide family carries
    // plain u64 patterns only; no reverse type inference).
    const iconst_f = findFunc(program, "app.iconst");
    const iconst_fid = b.func_ids.get(iconst_f).?;
    const iconst_br = b.block_ranges.items[iconst_fid];
    const iconst_blk = b.ordered_blocks.items[iconst_br.start];
    var iconst_pc = b.pcOf(iconst_blk);
    for (iconst_blk.instrs) |ins| {
        if (std.meta.activeTag(ins.op) == .phi) continue;
        if (std.meta.activeTag(ins.op) == .const_) {
            try testing.expectEqual(llir.Opcode.const_, llir.decode(image.instructions[iconst_pc]).?.op);
            try testing.expectEqual(@as(u32, 1), try b.recordCount(iconst_blk, ins));
        }
        iconst_pc += try b.recordCount(iconst_blk, ins);
    }
    const fconst_f = findFunc(program, "app.fconst");
    const fconst_fid = b.func_ids.get(fconst_f).?;
    const fconst_br = b.block_ranges.items[fconst_fid];
    const fconst_blk = b.ordered_blocks.items[fconst_br.start];
    var fconst_pc = b.pcOf(fconst_blk);
    for (fconst_blk.instrs) |ins| {
        if (std.meta.activeTag(ins.op) == .phi) continue;
        if (std.meta.activeTag(ins.op) == .const_) {
            try testing.expectEqual(llir.Opcode.const_, llir.decode(image.instructions[fconst_pc]).?.op);
            try testing.expectEqual(@as(u32, 1), try b.recordCount(fconst_blk, ins));
        }
        fconst_pc += try b.recordCount(fconst_blk, ins);
    }

    // Validator and interpreter agree with the source bit patterns.
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }
    for (cases) |case_| {
        const f = findFunc(program, case_.name);
        const fid = b.func_ids.get(f).?;
        var term = try interpreter.runValidatedWithEntry(testing.allocator, &image, fid, .{});
        defer term.deinit(testing.allocator);
        switch (term) {
            .normal => |v| try testing.expectEqual(case_.pattern, v),
            .panic => return error.TestUnexpectedResult,
        }
    }
}

// ---------------------------------------------------------------------------
// 3.1 — typed lowering: the 20-cast matrix, the 6-rep comparison
// families, the le/gt swap aliases, the byte→u32 comparison variant,
// and the `copy dst, cond` bool materialization.
// ---------------------------------------------------------------------------

test "3.1 LLIR lowering: all 20 directed casts carry the explicit cvt opcode" {
    // The Core §16.3 five-type conversion matrix (b, i32, u32, f32, f64)
    // minus the identities: every directed pair spells its own C-Type
    // opcode `cvt.<src>.<dst>` (a = dst, b = src) — no `c` discriminator
    // rides in the record.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn b_i(a: byte) -> int32 { a as int32 }
            \\fn b_u(a: byte) -> uint32 { a as uint32 }
            \\fn b_f(a: byte) -> float32 { a as float32 }
            \\fn b_d(a: byte) -> float64 { a as float64 }
            \\fn i_b(a: int32) -> byte { a as byte }
            \\fn i_u(a: int32) -> uint32 { a as uint32 }
            \\fn i_f(a: int32) -> float32 { a as float32 }
            \\fn i_d(a: int32) -> float64 { a as float64 }
            \\fn u_b(a: uint32) -> byte { a as byte }
            \\fn u_i(a: uint32) -> int32 { a as int32 }
            \\fn u_f(a: uint32) -> float32 { a as float32 }
            \\fn u_d(a: uint32) -> float64 { a as float64 }
            \\fn f_b(a: float32) -> byte { a as byte }
            \\fn f_i(a: float32) -> int32 { a as int32 }
            \\fn f_u(a: float32) -> uint32 { a as uint32 }
            \\fn f_d(a: float32) -> float64 { a as float64 }
            \\fn d_b(a: float64) -> byte { a as byte }
            \\fn d_i(a: float64) -> int32 { a as int32 }
            \\fn d_u(a: float64) -> uint32 { a as uint32 }
            \\fn d_f(a: float64) -> float32 { a as float32 }
            \\fn main() -> void {
            \\    let a: byte = 1 as byte; let b: int32 = 1; let c: uint32 = 1 as uint32;
            \\    let d: float32 = 1.0; let e: float64 = 1.0;
            \\    b_i(a); b_u(a); b_f(a); b_d(a); i_b(b); i_u(b); i_f(b); i_d(b);
            \\    u_b(c); u_i(c); u_f(c); u_d(c); f_b(d); f_i(d); f_u(d); f_d(d);
            \\    d_b(e); d_i(e); d_u(e); d_f(e);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const cases = [_]struct { name: []const u8, want: llir.Opcode }{
        .{ .name = "app.b_i", .want = .cvt_b_i32 },
        .{ .name = "app.b_u", .want = .cvt_b_u32 },
        .{ .name = "app.b_f", .want = .cvt_b_f32 },
        .{ .name = "app.b_d", .want = .cvt_b_f64 },
        .{ .name = "app.i_b", .want = .cvt_i32_b },
        .{ .name = "app.i_u", .want = .cvt_i32_u32 },
        .{ .name = "app.i_f", .want = .cvt_i32_f32 },
        .{ .name = "app.i_d", .want = .cvt_i32_f64 },
        .{ .name = "app.u_b", .want = .cvt_u32_b },
        .{ .name = "app.u_i", .want = .cvt_u32_i32 },
        .{ .name = "app.u_f", .want = .cvt_u32_f32 },
        .{ .name = "app.u_d", .want = .cvt_u32_f64 },
        .{ .name = "app.f_b", .want = .cvt_f32_b },
        .{ .name = "app.f_i", .want = .cvt_f32_i32 },
        .{ .name = "app.f_u", .want = .cvt_f32_u32 },
        .{ .name = "app.f_d", .want = .cvt_f32_f64 },
        .{ .name = "app.d_b", .want = .cvt_f64_b },
        .{ .name = "app.d_i", .want = .cvt_f64_i32 },
        .{ .name = "app.d_u", .want = .cvt_f64_u32 },
        .{ .name = "app.d_f", .want = .cvt_f64_f32 },
    };
    var n_cast: usize = 0;
    for (cases) |case_| {
        const fi = b.func_ids.get(findFunc(program, case_.name)).?;
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (std.meta.activeTag(ins.op) == .num_cast) {
                    const d = llir.decode(image.instructions[pc]).?;
                    try testing.expectEqual(case_.want, d.op);
                    try testing.expectEqual(b.slotOf(ins.results[0]), d.a); // a = the result slot
                    try testing.expectEqual(b.slotOf(ins.op.num_cast), d.b); // b = the source
                    n_cast += 1;
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 20), n_cast);
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }
}

test "3.1 LLIR lowering: seq/sne/slt/sle over all six reps write cond, then copy dst, cond" {
    // The C-Type comparison families: `seq`/`sne`/`slt`/`sle` over the
    // six reps (i32, u32, i64, u64, f32, f64) — 24 opcodes. Each
    // comparison writes the implicit `cond` and the lowering materializes
    // the SSA bool result with `copy dst, cond` immediately after. The
    // 64-bit reps need Stilla source (the AIR text form names no 64-bit
    // primitives).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn i32eq(a: int32, b: int32) -> bool { a == b }
            \\fn i32ne(a: int32, b: int32) -> bool { a != b }
            \\fn i32lt(a: int32, b: int32) -> bool { a < b }
            \\fn i32ge(a: int32, b: int32) -> bool { a >= b }
            \\fn u32eq(a: uint32, b: uint32) -> bool { a == b }
            \\fn u32ne(a: uint32, b: uint32) -> bool { a != b }
            \\fn u32lt(a: uint32, b: uint32) -> bool { a < b }
            \\fn u32ge(a: uint32, b: uint32) -> bool { a >= b }
            \\fn i64eq(a: int64, b: int64) -> bool { a == b }
            \\fn i64ne(a: int64, b: int64) -> bool { a != b }
            \\fn i64lt(a: int64, b: int64) -> bool { a < b }
            \\fn i64ge(a: int64, b: int64) -> bool { a >= b }
            \\fn u64eq(a: uint64, b: uint64) -> bool { a == b }
            \\fn u64ne(a: uint64, b: uint64) -> bool { a != b }
            \\fn u64lt(a: uint64, b: uint64) -> bool { a < b }
            \\fn u64ge(a: uint64, b: uint64) -> bool { a >= b }
            \\fn f32eq(a: float32, b: float32) -> bool { a == b }
            \\fn f32ne(a: float32, b: float32) -> bool { a != b }
            \\fn f32lt(a: float32, b: float32) -> bool { a < b }
            \\fn f32ge(a: float32, b: float32) -> bool { a >= b }
            \\fn f64eq(a: float64, b: float64) -> bool { a == b }
            \\fn f64ne(a: float64, b: float64) -> bool { a != b }
            \\fn f64lt(a: float64, b: float64) -> bool { a < b }
            \\fn f64ge(a: float64, b: float64) -> bool { a >= b }
            \\fn main() -> void {
            \\    let a: int32 = 1; let b: uint32 = 1 as uint32; let c: int64 = 1; let d: uint64 = 1;
            \\    let e: float32 = 1.0; let f: float64 = 1.0;
            \\    i32eq(a, a); i32ne(a, a); i32lt(a, a); i32ge(a, a);
            \\    u32eq(b, b); u32ne(b, b); u32lt(b, b); u32ge(b, b);
            \\    i64eq(c, c); i64ne(c, c); i64lt(c, c); i64ge(c, c);
            \\    u64eq(d, d); u64ne(d, d); u64lt(d, d); u64ge(d, d);
            \\    f32eq(e, e); f32ne(e, e); f32lt(e, e); f32ge(e, e);
            \\    f64eq(f, f); f64ne(f, f); f64lt(f, f); f64ge(f, f);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const cases = [_]struct { name: []const u8, want: llir.Opcode, swapped: bool }{
        .{ .name = "app.i32eq", .want = .seq, .swapped = false },     .{ .name = "app.i32ne", .want = .sne, .swapped = false },
        .{ .name = "app.i32lt", .want = .slt, .swapped = false },     .{ .name = "app.i32ge", .want = .slt, .swapped = false },
        .{ .name = "app.u32eq", .want = .seq, .swapped = false },     .{ .name = "app.u32ne", .want = .sne, .swapped = false },
        .{ .name = "app.u32lt", .want = .sltu, .swapped = false },    .{ .name = "app.u32ge", .want = .sltu, .swapped = false },
        .{ .name = "app.i64eq", .want = .seq, .swapped = false },     .{ .name = "app.i64ne", .want = .sne, .swapped = false },
        .{ .name = "app.i64lt", .want = .slt, .swapped = false },     .{ .name = "app.i64ge", .want = .slt, .swapped = false },
        .{ .name = "app.u64eq", .want = .seq, .swapped = false },     .{ .name = "app.u64ne", .want = .sne, .swapped = false },
        .{ .name = "app.u64lt", .want = .sltu, .swapped = false },    .{ .name = "app.u64ge", .want = .sltu, .swapped = false },
        .{ .name = "app.f32eq", .want = .seq_f32, .swapped = false }, .{ .name = "app.f32ne", .want = .sne_f32, .swapped = false },
        .{ .name = "app.f32lt", .want = .slt_f32, .swapped = false }, .{ .name = "app.f32ge", .want = .sle_f32, .swapped = true },
        .{ .name = "app.f64eq", .want = .seq_f64, .swapped = false }, .{ .name = "app.f64ne", .want = .sne_f64, .swapped = false },
        .{ .name = "app.f64lt", .want = .slt_f64, .swapped = false }, .{ .name = "app.f64ge", .want = .sle_f64, .swapped = true },
    };
    var n_cmp: usize = 0;
    for (cases) |case_| {
        const f = findFunc(program, case_.name);
        const fi = b.func_ids.get(f).?;
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .eq, .ne, .lt, .ge => |bin| {
                        // The comparison: C-Type, a = lhs slot, b = rhs
                        // slot, implicit `cond` destination.
                        const d = llir.decode(image.instructions[pc]).?;
                        try testing.expectEqual(case_.want, d.op);
                        try testing.expectEqual(llir.Format.c, llir.opInfo(d.op).format);
                        const a_slot = b.slotOf(if (case_.swapped) bin.b else bin.a);
                        const b_slot = b.slotOf(if (case_.swapped) bin.a else bin.b);
                        try testing.expectEqual(a_slot, d.a);
                        try testing.expectEqual(b_slot, d.b);
                        // The materialization record right after:
                        // `copy dst, cond`.
                        var cp = llir.decode(image.instructions[pc + 1]).?;
                        if (cp.op == .not) cp = llir.decode(image.instructions[pc + 2]).?;
                        try testing.expectEqual(llir.Opcode.copy, cp.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), cp.a);
                        try testing.expectEqual(llir.cond_reg, cp.b);
                        n_cmp += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 24), n_cmp);
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }
}

test "3.1 LLIR lowering: gt and integer le swap operands; float le is the direct sle" {
    // `a > b` ≡ `slt b, a`; integer `le` synthesizes `not(slt b, a)`;
    // float `le` is the direct `sle a, b` primitive (no `sge` opcode —
    // `a >= b` ≡ `sle b, a`). The operand swaps preserve the NaN
    // behavior of every predicate. Checked across an integer rep (i32)
    // and a float rep (f64), where the ordering is observable in the
    // record.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn i32gt(a: int32, b: int32) -> bool { a > b }
            \\fn i32le(a: int32, b: int32) -> bool { a <= b }
            \\fn f64gt(a: float64, b: float64) -> bool { a > b }
            \\fn f64le(a: float64, b: float64) -> bool { a <= b }
            \\fn main() -> void {
            \\    let a: int32 = 1; let e: float64 = 1.0;
            \\    i32gt(a, a); i32le(a, a); f64gt(e, e); f64le(e, e);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const cases = [_]struct { name: []const u8, want: llir.Opcode, swapped: bool }{
        .{ .name = "app.i32gt", .want = .slt, .swapped = true },
        .{ .name = "app.i32le", .want = .slt, .swapped = true },
        .{ .name = "app.f64gt", .want = .slt_f64, .swapped = true },
        .{ .name = "app.f64le", .want = .sle_f64, .swapped = false },
    };
    var n_cmp: usize = 0;
    for (cases) |case_| {
        const f = findFunc(program, case_.name);
        const fi = b.func_ids.get(f).?;
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .gt, .le => |bin| {
                        const d = llir.decode(image.instructions[pc]).?;
                        try testing.expectEqual(case_.want, d.op);
                        // `gt` and integer `le` swap operands (a = rhs,
                        // b = lhs); float `le` is the direct `sle a, b`.
                        const a_slot = b.slotOf(if (case_.swapped) bin.b else bin.a);
                        const b_slot = b.slotOf(if (case_.swapped) bin.a else bin.b);
                        try testing.expectEqual(a_slot, d.a);
                        try testing.expectEqual(b_slot, d.b);
                        n_cmp += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), n_cmp);
}

test "3.1 LLIR lowering: byte comparisons lower through the u32 variants" {
    // `byte` has no comparison rep of its own: every byte predicate is
    // the corresponding `u32` family member (the byte value occupies one
    // host cell).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn beq(a: byte, b: byte) -> bool { a == b }
            \\fn bne(a: byte, b: byte) -> bool { a != b }
            \\fn blt(a: byte, b: byte) -> bool { a < b }
            \\fn bge(a: byte, b: byte) -> bool { a >= b }
            \\fn main() -> void {
            \\    let a: byte = 1 as byte; let b: byte = 2 as byte;
            \\    beq(a, b); bne(a, b); blt(a, b); bge(a, b);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const cases = [_]struct { name: []const u8, want: llir.Opcode }{
        .{ .name = "app.beq", .want = .seq },
        .{ .name = "app.bne", .want = .sne },
        .{ .name = "app.blt", .want = .sltu },
        .{ .name = "app.bge", .want = .sltu },
    };
    var n_cmp: usize = 0;
    for (cases) |case_| {
        const f = findFunc(program, case_.name);
        const fi = b.func_ids.get(f).?;
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .eq, .ne, .lt, .ge => |bin| {
                        const d = llir.decode(image.instructions[pc]).?;
                        try testing.expectEqual(case_.want, d.op);
                        try testing.expectEqual(b.slotOf(bin.a), d.a);
                        try testing.expectEqual(b.slotOf(bin.b), d.b);
                        n_cmp += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), n_cmp);
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }
}
