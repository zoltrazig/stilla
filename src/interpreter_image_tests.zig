//! Black-box hand-built-image interpreter tests: the loader-drawn scalar program,
//! move-wide/immediate/wide arithmetic, C-Type comparisons and the register
//! semantics (zero/cond/ra, T bank), `take`, `j`, `jal`/`jalr`, nested calls,
//! and the call-clobber contract.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interpreter = @import("interpreter.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const lower = @import("lower.zig");
const checker = @import("passes/checker.zig");
const stdbundle = @import("stdbundle.zig");
const host_module = @import("host.zig");
const artifact_bundle = @import("artifact_bundle.zig");
const llir_emit_bin = @import("passes/llir_emit_bin.zig");
const stilla_asm_printer = lower.llirAsm;
const testing = std.testing;

const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;

const support = @import("interpreter_test_support.zig");
const load = support.load;
const Loaded = support.Loaded;
const CaptureAdapter = support.CaptureAdapter;
const runHand = support.runHand;
const runHandBlocks = support.runHandBlocks;
const runHandImage = support.runHandImage;
const primType = support.primType;
const drainRootInit = support.drainRootInit;

// ---------------------------------------------------------------------------
// Phase 4 — image execution (TODO.md 阶段 4)
// ---------------------------------------------------------------------------

test "move-wide: all twelve suffixes execute; the mixed sequence builds 0x0123456789abcdef" {
    // Build 0x0123456789abcdef lane by lane: movwz0 defines lane 0,
    // movwk1..3 merge the rest over the old pattern.
    const seq = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0xcdef), // lane 0 = 0xcdef
        llir.instrI(.movwk1, llir.frame_base, 0x89ab), // lane 1 = 0x89ab
        llir.instrI(.movwk2, llir.frame_base, 0x4567), // lane 2 = 0x4567
        llir.instrI(.movwk3, llir.frame_base, 0x0123), // lane 3 = 0x0123
        llir.instrE(.ret, llir.frame_base, 0),
    };
    const u64_row = [_]llir.TypeDesc{primType(.u64)};
    try testing.expectEqual(@as(Value, 0x0123_4567_89ab_cdef), try runHand(&seq, &u64_row, 0, &.{}));

    // movwn complements the whole 64-bit pattern: movwn0 0x0000 = all
    // ones; movwn1 0xffff keeps every lane but lane 1 set.
    const comp0 = [_]llir.Instr{
        llir.instrI(.movwn0, llir.frame_base, 0x0),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 0xffff_ffff_ffff_ffff), try runHand(&comp0, &u64_row, 0, &.{}));
    const comp1 = [_]llir.Instr{
        llir.instrI(.movwn1, llir.frame_base, 0xffff),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 0xffff_ffff_0000_ffff), try runHand(&comp1, &u64_row, 0, &.{}));

    // movwz3 places the lane value in bits 63–48; movwz2 in 47–32.
    const z3 = [_]llir.Instr{
        llir.instrI(.movwz3, llir.frame_base, 0xffff),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 0xffff_0000_0000_0000), try runHand(&z3, &u64_row, 0, &.{}));
    const z2 = [_]llir.Instr{
        llir.instrI(.movwz2, llir.frame_base, 0xffff),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 0x0000_ffff_0000_0000), try runHand(&z2, &u64_row, 0, &.{}));

    // movwk0 keeps the old pattern's other three lanes: 0x0123456789abcdef
    // with lane 0 replaced by 0x1234.
    const k0 = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0xcdef),
        llir.instrI(.movwk1, llir.frame_base, 0x89ab),
        llir.instrI(.movwk2, llir.frame_base, 0x4567),
        llir.instrI(.movwk3, llir.frame_base, 0x123),
        llir.instrI(.movwk0, llir.frame_base, 0x1234),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 0x0123_4567_89ab_1234), try runHand(&k0, &u64_row, 0, &.{}));
}

test "i64 immediate forms sign-extend the 7-bit constant to 64 bits" {
    // subi c=0x80 (= -128 as i8): 10 - (-128) = 138 at 64 bits. A
    // 32-bit sign extension would add 0x00000000ffffff80 instead —
    // a different pattern entirely.
    const u64_row = [_]llir.TypeDesc{primType(.u64)};
    const instrs = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0xa), // %0 = 10
        llir.instrR(.subi, llir.frame_base + 1, llir.frame_base, 0x40), // %1 = 10 - (-64) — the v9 i64 imm7 window [-64, 63]
        llir.instrE(.ret, llir.frame_base + 1, 0),
    };
    try testing.expectEqual(@as(Value, 74), try runHand(&instrs, &u64_row, 0, &.{}));

    const cmp = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0xa),
        llir.instrC(.slti, llir.frame_base, 0x40),
        llir.instrE(.copy, llir.frame_base + 1, llir.cond_reg),
        llir.instrE(.ret, llir.frame_base + 1, 0),
    };
    const rows = [_]llir.TypeDesc{ primType(.u64), primType(.bool) };
    try testing.expectEqual(@as(Value, 0), try runHand(&cmp, &rows, 0, &.{}));
}

test "wide madd/msub wrap at the resolved 64-bit width" {
    // acc = 0xffff_ffff_ffff_ff00; madd acc += 2 * 0x100 — wraps
    // modulo 2^64 to 0x100.
    const u64_row = [_]llir.TypeDesc{primType(.u64)};
    const instrs = [_]llir.Instr{
        llir.instrI(.movwz3, llir.frame_base, 0xffff),
        llir.instrI(.movwk2, llir.frame_base, 0xffff),
        llir.instrI(.movwk1, llir.frame_base, 0xffff),
        llir.instrI(.movwk0, llir.frame_base, 0xff00), // %0 = 0xffff_ffff_ffff_ff00
        llir.instrI(.movwz0, llir.frame_base + 1, 0x2), // %1 = 2
        llir.instrI(.movwz0, llir.frame_base + 2, 0x100), // %2 = 0x100
        llir.instrR(.madd, llir.frame_base, llir.frame_base + 1, llir.frame_base + 2),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 0x100), try runHand(&instrs, &u64_row, 0, &.{}));

    // msub: 0x100 - 2 * 0x100 = -0x100 → 0xffff_ffff_ffff_ff00.
    const msub = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0x100), // %0 = 0x100
        llir.instrI(.movwz0, llir.frame_base + 1, 0x2), // %1 = 2
        llir.instrI(.movwz0, llir.frame_base + 2, 0x100), // %2 = 0x100
        llir.instrR(.msub, llir.frame_base, llir.frame_base + 1, llir.frame_base + 2),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 0xffff_ffff_ffff_ff00), try runHand(&msub, &u64_row, 0, &.{}));
}

test "maddi: the 8-bit immediate accumulates at the resolved 64-bit width" {
    const u64_row = [_]llir.TypeDesc{primType(.u64)};

    // acc 10 + b 7 * imm 3 = 31; the accumulator is read and rewritten.
    const acc = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0xa), // %0 = 10
        llir.instrI(.movwz0, llir.frame_base + 1, 0x7), // %1 = 7
        llir.instrI(.movwz0, llir.frame_base + 2, 0xa), // %2 = 10
        llir.instrR(.maddiu, llir.frame_base + 2, llir.frame_base + 1, 3),
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 31), try runHand(&acc, &u64_row, 0, &.{}));

    // max u64 + 2 * 1 wraps to 1 (mod 2^64).
    const wrap = [_]llir.Instr{
        llir.instrI(.movwz3, llir.frame_base, 0xffff),
        llir.instrI(.movwk2, llir.frame_base, 0xffff),
        llir.instrI(.movwk1, llir.frame_base, 0xffff),
        llir.instrI(.movwk0, llir.frame_base, 0xffff), // %0 = max u64
        llir.instrI(.movwz0, llir.frame_base + 1, 0x2), // %1 = 2
        llir.instrR(.maddiu, llir.frame_base, llir.frame_base + 1, 1),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    try testing.expectEqual(@as(Value, 1), try runHand(&wrap, &u64_row, 0, &.{}));

    // The 8-bit immediate sign-extends to the resolved width:
    // 0 + 1 * (-128) = -128, not the zero-extended 128.
    const sext = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0xa), // %0 = 10
        llir.instrI(.movwz0, llir.frame_base + 1, 0x1), // %1 = 1
        llir.instrR(.maddi, llir.frame_base + 2, llir.frame_base + 1, 0x40), // %2 = 0 + 1 * (-64) — the v9 i64 imm7 window
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 0xffff_ffff_ffff_ffc0), try runHand(&sext, &u64_row, 0, &.{}));
}

test "minu/maxu at 64-bit width compare the full unsigned cell" {
    const u64_row = [_]llir.TypeDesc{primType(.u64)};
    // 2^31 vs 1: the low words are 0 and 1, so a 32-bit-only handler
    // would still pick 1/2^31 — the width itself is what's under test
    // (the 64-bit cases must execute, not hit `unreachable`).
    const mn = [_]llir.Instr{
        llir.instrI(.movwz1, llir.frame_base, 0x8000), // %0 = 0x8000_0000
        llir.instrI(.movwz0, llir.frame_base + 1, 0x1), // %1 = 1
        llir.instrR(.minu, llir.frame_base + 2, llir.frame_base, llir.frame_base + 1),
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 1), try runHand(&mn, &u64_row, 0, &.{}));
    const mx = [_]llir.Instr{
        llir.instrI(.movwz1, llir.frame_base, 0x8000),
        llir.instrI(.movwz0, llir.frame_base + 1, 0x1),
        llir.instrR(.maxu, llir.frame_base + 2, llir.frame_base, llir.frame_base + 1),
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 0x8000_0000), try runHand(&mx, &u64_row, 0, &.{}));
}

test "i64 minInt edges: rem min/-1 is 0; abs(minInt) wraps to the minimum" {
    const rows = [_]llir.TypeDesc{ primType(.int32), primType(.i64) };
    const constants = [_]llir.ConstRecord{
        .{ .kind = .int, .type_ = 1, .a = 0, .b = 0x8000_0000 }, // i64 minInt
        .{ .kind = .int, .type_ = 1, .a = 0xffff_ffff, .b = 0xffff_ffff }, // i64 -1
    };
    // minInt % -1 == 0 — only a zero divisor traps.
    const rem = [_]llir.Instr{
        llir.instrI(.const_, llir.frame_base, 0x0),
        llir.instrI(.const_, llir.frame_base + 1, 0x1),
        llir.instrR(.rem, llir.frame_base + 2, llir.frame_base, llir.frame_base + 1),
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 0), try runHand(&rem, &rows, 1, &constants));
    // abs(minInt) wraps to the minimum bit pattern (never traps).
    const abs = [_]llir.Instr{
        llir.instrI(.const_, llir.frame_base, 0x0),
        llir.instrE(.abs_i64, llir.frame_base + 2, llir.frame_base),
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 0x8000_0000_0000_0000), try runHand(&abs, &rows, 1, &constants));
}

test "64-bit ordered branches compare the full cell, not the low word" {
    // a = 2^32, b = 5: `a < b` is false at 64 bits, but the low-word
    // compare (0 < 5) would take the branch. The fall-through must run
    // (r2 = 7), not the branch arm (r2 = 99).
    const u64_row = [_]llir.TypeDesc{primType(.u64)};
    const blocks = [_]llir.BlockDesc{
        .{ .start_pc = 0, .end_pc = 3 },
        .{ .start_pc = 3, .end_pc = 5 },
        .{ .start_pc = 5, .end_pc = 7 },
    };
    const bltu_instrs = [_]llir.Instr{
        llir.instrI(.movwz2, llir.frame_base, 0x1), // %0 = 2^32
        llir.instrI(.movwz0, llir.frame_base + 1, 0x5), // %1 = 5
        llir.instrB(.bltu, llir.frame_base, llir.frame_base + 1, 3), // not taken; taken → pc + 3
        llir.instrI(.movwz0, llir.frame_base + 2, 0x7), // %2 = 7
        llir.instrE(.ret, llir.frame_base + 2, 0),
        llir.instrI(.movwz0, llir.frame_base + 2, 0x63), // %2 = 99
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 7), try runHandBlocks(&bltu_instrs, &u64_row, 0, &.{}, &blocks));

    // The signed form needs i64-typed operands; `movwz*` defines plain
    // u64, so the constants carry the i64 type records.
    const rows = [_]llir.TypeDesc{ primType(.int32), primType(.i64) };
    const constants = [_]llir.ConstRecord{
        .{ .kind = .int, .type_ = 1, .a = 0, .b = 1 }, // i64 2^32
        .{ .kind = .int, .type_ = 1, .a = 5, .b = 0 }, // i64 5
        .{ .kind = .int, .type_ = 0, .a = 7, .b = 0 }, // int32 7
        .{ .kind = .int, .type_ = 0, .a = 99, .b = 0 }, // int32 99
    };
    const blt_instrs = [_]llir.Instr{
        llir.instrI(.const_, llir.frame_base, 0x0),
        llir.instrI(.const_, llir.frame_base + 1, 0x1),
        llir.instrB(.blt, llir.frame_base, llir.frame_base + 1, 3), // not taken; taken → pc + 3
        llir.instrI(.const_, llir.frame_base + 2, 0x2),
        llir.instrE(.ret, llir.frame_base + 2, 0),
        llir.instrI(.const_, llir.frame_base + 2, 0x3),
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    try testing.expectEqual(@as(Value, 7), try runHandBlocks(&blt_instrs, &rows, 0, &constants, &blocks));
}

test "f64 arithmetic: IEEE division, remainder, NaN equality — no traps" {
    var l = try load(
        \\fn half(x: f64) -> f64 { x / 2.0 }
        \\fn inv(x: f64) -> f64 { 0.0 / x }
        \\fn main() -> int32 {
        \\    let q: f64 = half(7.5);      // 3.75
        \\    let seven: f64 = 7.5;
        \\    let r: f64 = seven - q;      // 3.75
        \\    let s: f64 = q + r;          // 7.5
        \\    let n: f64 = inv(0.0);       // 0/0 = NaN — division by zero never traps
        \\    let eq_res: bool = n == n;   // NaN compares unequal to itself
        \\    if (eq_res) { 0 } else { (s as int32) }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 7), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

// ---------------------------------------------------------------------------
// Stage-3 (TODO.md 3.5) — interpreter & calling convention: zero/cond
// semantics, the C-Type comparison → cond matrix (integer + float, NaN),
// `jal` link/target ordering and `j` discarding no link, nested-call
// `ra` save/restore, `jalr` signed offset/overflow/non-entry handling,
// the dynamic take contract-mismatch failure atomicity, T0–T15
// call-clobber, and per-rep dispatch coverage.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Zero / cond register semantics
// ---------------------------------------------------------------------------

test "zero: read yields zero, write discards, copy cond,zero clears cond" {
    // `copy cond, zero`: reads the zero register (all-zero cell) into
    // cond. A following `cmov`/comparison reads cond as 0/false. The
    // zero destination write is a discard: no frame cell changes.
    const seq = [_]llir.Instr{
        llir.instrE(.copy, llir.cond_reg, llir.zero_reg), // cond = 0
        llir.instrE(.copy, llir.frame_base, llir.cond_reg), // F0 = cond (false)
        llir.instrE(.ret, llir.frame_base, 0),
    };
    const rows = [_]llir.TypeDesc{ primType(.bool), primType(.bool) };
    try testing.expectEqual(@as(Value, 0), try runHand(&seq, &rows, 0, &.{}));

    // Writing `zero` discards: a value written to zero leaves no cell.
    const disc = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0x7a), // F0 = 0x7a
        llir.instrE(.copy, llir.zero_reg, llir.frame_base), // write to zero → discard
        llir.instrE(.ret, llir.frame_base, 0),
    };
    const rows2 = [_]llir.TypeDesc{primType(.int32)};
    try testing.expectEqual(@as(Value, 0x7a), try runHand(&disc, &rows2, 0, &.{}));

    // `cmov` after a cleared cond picks the else arm.
    const cmov = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0x1), // F0 = 1
        llir.instrI(.movwz0, llir.frame_base + 1, 0x2), // F1 = 2
        llir.instrE(.copy, llir.cond_reg, llir.zero_reg), // cond = 0
        llir.instrR(.cmov, llir.frame_base + 2, llir.frame_base, llir.frame_base + 1), // F2 = cond ? F0 : F1 = 2
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    const rows3 = [_]llir.TypeDesc{primType(.int32)};
    try testing.expectEqual(@as(Value, 2), try runHand(&cmov, &rows3, 0, &.{}));
}

test "fast bank: zero/ra discard, cond and T are raw-index independent" {
    // The directly-indexed fast bank (Instruction Set §3.1.1): `zero` at
    // index 0 is permanently all-zero (a write discards), `ra` at index 2
    // is a reserved hole (writes discard — the link lives in the frame
    // header), `cond` at 1 and T0 at 3 are independently
    // readable/writable by their raw encodings — one bounds check, no
    // decode arithmetic.
    var l = try load(
        \\fn main() -> int32 { 0 }
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));

    // zero: writing a nonzero value leaves index 0 all-zero.
    vm_dispatch.write(&vm, llir.zero_reg, 0xdead_beef);
    try testing.expectEqual(@as(Value, 0), vm_dispatch.read(&vm, llir.zero_reg));
    try testing.expectEqual(@as(Value, 0), vm.core.fast_regs[llir.zero_reg]);

    // ra (index 2) is the reserved hole: a write discards.
    vm_dispatch.write(&vm, llir.ra_reg, 0xbaad_f00d);
    try testing.expectEqual(@as(Value, 0), vm.core.fast_regs[llir.ra_reg]);

    // cond and T0 are independent cells at their raw encodings (1 and 3).
    vm_dispatch.write(&vm, llir.cond_reg, 0x11);
    vm_dispatch.write(&vm, llir.temp_base, 0x22);
    try testing.expectEqual(@as(Value, 0x11), vm_dispatch.read(&vm, llir.cond_reg));
    try testing.expectEqual(@as(Value, 0x22), vm_dispatch.read(&vm, llir.temp_base));
    try testing.expectEqual(@as(Value, 0x11), vm.core.fast_regs[llir.cond_reg]);
    try testing.expectEqual(@as(Value, 0x22), vm.core.fast_regs[llir.temp_base]);
    try testing.expectEqual(@as(Value, 0), vm.core.fast_regs[llir.zero_reg]); // still zero after the cond/T writes
    try testing.expectEqual(@as(Value, 0), vm.core.fast_regs[llir.ra_reg]); // hole still dead
}

// ---------------------------------------------------------------------------
// Integer C-Type comparison → cond matrix
// ---------------------------------------------------------------------------

/// Run one comparison sequence: set F0/F1 from wide cells (movwz0 then
/// movwk1..3 to keep prior lanes), run `op` (a C-Type comparison that
/// writes cond), materialize cond into F2, return F2.
fn runIntCmp(op: llir.Opcode, a: Value, b: Value, rows: []const llir.TypeDesc) !Value {
    const instrs = [_]llir.Instr{
        // F0 = a: movwz0 zeroes; movwk1..3 preserve.
        llir.instrI(.movwz0, llir.frame_base, @truncate(a)),
        llir.instrI(.movwk1, llir.frame_base, @truncate(a >> 16)),
        llir.instrI(.movwk2, llir.frame_base, @truncate(a >> 32)),
        llir.instrI(.movwk3, llir.frame_base, @truncate(a >> 48)),
        // F1 = b.
        llir.instrI(.movwz0, llir.frame_base + 1, @truncate(b)),
        llir.instrI(.movwk1, llir.frame_base + 1, @truncate(b >> 16)),
        llir.instrI(.movwk2, llir.frame_base + 1, @truncate(b >> 32)),
        llir.instrI(.movwk3, llir.frame_base + 1, @truncate(b >> 48)), // F1 = b
        llir.instrC(op, llir.frame_base, llir.frame_base + 1), // cond = a op b
        llir.instrE(.copy, llir.frame_base + 2, llir.cond_reg),
        llir.instrE(.ret, llir.frame_base + 2, 0),
    };
    return runHand(&instrs, rows, 0, &.{});
}

test "integer C-Type comparisons write cond (signed/unsigned, 32/64-bit)" {
    // All four integer comparison opcodes, the only integer C-Type
    // comparison set. `slt` is signed; `sltu` unsigned. 32-bit operands
    // are sign-extended cells; 64-bit are full-width.
    const i32_rows = [_]llir.TypeDesc{ primType(.int32), primType(.int32), primType(.bool) };
    // -1 (as a sign-extended cell) < 0 → true
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.slt, 0xffff_ffff_ffff_ffff, 0, &i32_rows));
    // -1 > 0 signed? no. sltu: 0xffff..ffff is huge → false? unsigned -1 is max, so sltu(-1,0)=false.
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.sltu, 0xffff_ffff_ffff_ffff, 0, &i32_rows));
    // equality
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.seq, 0x1234, 0x1234, &i32_rows));
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.sne, 0x1234, 0x1234, &i32_rows));
    // 32-bit signed comparison: 0x80000000 is INT_MIN → less than 0.
    const neg: Value = 0xffff_ffff_8000_0000; // sign-extended INT_MIN
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.slt, neg, 0, &i32_rows));

    const i64_rows = [_]llir.TypeDesc{ primType(.i64), primType(.i64), primType(.bool) };
    // 1 << 63 is i64 min (signed) → less than 0; as unsigned it is huge.
    const min64: Value = 0x8000_0000_0000_0000;
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.slt, min64, 0, &i64_rows));
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.sltu, min64, 0, &i64_rows));
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.slt, 0, min64, &i64_rows));
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.sltu, 0, min64, &i64_rows));
}

// clz/popcount harness: load `a` into F0 (the 64-bit movw sequence), run
// the unary op into F1, ret F1. The opcode's rep fixes the counted width.
fn runBitCount(op: llir.Opcode, a: Value) !Value {
    const instrs = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, @truncate(a)),
        llir.instrI(.movwk1, llir.frame_base, @truncate(a >> 16)),
        llir.instrI(.movwk2, llir.frame_base, @truncate(a >> 32)),
        llir.instrI(.movwk3, llir.frame_base, @truncate(a >> 48)),
        llir.instrE(op, llir.frame_base + 1, llir.frame_base),
        llir.instrE(.ret, llir.frame_base + 1, 0),
    };
    return runHand(&instrs, &.{ primType(.int32), primType(.int32) }, 1, &.{});
}

test "clz/popcount runtime: the 32-bit forms count the low 32 bits, not the sign-extension" {
    // clz/popcount are sign-agnostic, so the unsigned types alias the
    // signed width selector (clz.u32 → clz.i32). The 32-bit forms must
    // count the low 32 bits: uint32 1 (cell 0x1) would be 63 on a
    // full-cell clz, but clz.i32 truncates and counts 31.
    try testing.expectEqual(@as(Value, 31), try runBitCount(.clz_i32, 0x0000_0000_0000_0001));
    // uint32 0x8000_0000 is stored sign-extended (0xffff_ffff_8000_0000):
    // a full-cell popcount would count 33, but popcount.i32 counts 1.
    try testing.expectEqual(@as(Value, 1), try runBitCount(.popcount_i32, 0xffff_ffff_8000_0000));
    // The 64-bit forms count the full cell.
    try testing.expectEqual(@as(Value, 63), try runBitCount(.clz_i64, 0x0000_0000_0000_0001));
    try testing.expectEqual(@as(Value, 1), try runBitCount(.popcount_i64, 0x8000_0000_0000_0000));
}

// ---------------------------------------------------------------------------
// Float C-Type comparison → cond matrix (incl. NaN)
// ---------------------------------------------------------------------------

// f32/f64 comparison harness: `(a OP b)` into cond then ret. NaN is
// encoded as a raw cell pattern so no reconstruction is needed. The
// operand setup is shared with the integer matrix (`runIntCmp`).
test "float C-Type comparisons write cond; NaN is ordered-false, ne-true" {
    const f32_nan: Value = 0x7fc0_0001;
    const f32_one: Value = vm_types.ValueCodec.encodeFloat32(1.0);
    const f32_two: Value = vm_types.ValueCodec.encodeFloat32(2.0);
    const f32_rows = [_]llir.TypeDesc{ primType(.float32), primType(.float32), primType(.bool) };
    // ordered comparisons false on NaN
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.slt_f32, f32_nan, f32_one, &f32_rows));
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.sle_f32, f32_nan, f32_one, &f32_rows));
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.seq_f32, f32_nan, f32_nan, &f32_rows)); // NaN != NaN
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.sne_f32, f32_nan, f32_nan, &f32_rows));
    // ordered pass
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.slt_f32, f32_one, f32_two, &f32_rows));
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.sle_f32, f32_two, f32_two, &f32_rows));

    const f64_nan: Value = 0x7ff8_0000_0000_0001;
    const f64_one: Value = vm_types.ValueCodec.encodeFloat64(1.0);
    const f64_two: Value = vm_types.ValueCodec.encodeFloat64(2.0);
    const f64_rows = [_]llir.TypeDesc{ primType(.f64), primType(.f64), primType(.bool) };
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.slt_f64, f64_nan, f64_one, &f64_rows));
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.sle_f64, f64_nan, f64_one, &f64_rows));
    try testing.expectEqual(@as(Value, 0), try runIntCmp(.seq_f64, f64_nan, f64_nan, &f64_rows));
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.sne_f64, f64_nan, f64_nan, &f64_rows));
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.slt_f64, f64_one, f64_two, &f64_rows));
    try testing.expectEqual(@as(Value, 1), try runIntCmp(.sle_f64, f64_two, f64_two, &f64_rows));
}

// ---------------------------------------------------------------------------
// Calling convention: `jal` ordering, `j` (no link), nested
// `ra` save/restore, `jalr` signed offsets, dynamic take-contract
// failure atomicity, T0–T15 call-clobber, and the generic take's
// alias-aware register transfer.
// ---------------------------------------------------------------------------

test "take: register transfer clears its source; O aliases resolve through the window" {
    // A caller with L = 6, X = 1, W = 7 (spec §4.1): regCount = 13,
    // O = 5. The output aliases F8..F12 sit after the three-cell header
    // reserve and resolve to `fp + x_count + reg` — the X cells are
    // never register-addressed, so the window base is fp + 7.
    const desc = llir.FunctionDesc{
        .code_start = 0,
        .code_end = 7,
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 6,
        .x_count = 1,
        .window_count = 7,
    };
    const u64_row = [_]llir.TypeDesc{primType(.u64)};
    const constants = [_]llir.ConstRecord{
        .{ .kind = .int, .type_ = 0, .a = 42, .b = 0 },
    };
    // const F0 = 42; move F10, F0 (a write through the O2 alias);
    // take F1, F10 (read + clear the alias); take zero, F10 (a zero
    // destination discards); take F2, F10 (the cleared alias reads 0);
    // F3 = F1 + F2; ret F3.
    const seq = [_]llir.Instr{
        llir.instrI(.const_, llir.frame_base, 0x0),
        llir.instrE(.move, llir.frame_base + 10, llir.frame_base), // F10 = O(2): physical fp + x_count + 10
        llir.instrE(.take, llir.frame_base + 1, llir.frame_base + 10), // F1 = F10; F10 cleared
        llir.instrE(.take, llir.zero_reg, llir.frame_base + 10), // zero dst discards; F10 stays cleared
        llir.instrE(.take, llir.frame_base + 2, llir.frame_base + 10), // F2 = 0 — the source was cleared
        llir.instrR(.add, llir.frame_base + 3, llir.frame_base + 1, llir.frame_base + 2),
        llir.instrE(.ret, llir.frame_base + 3, 0),
    };
    const v = try runHandImage(&seq, &u64_row, 0, &constants, &.{.{
        .start_pc = 0,
        .end_pc = @intCast(seq.len),
    }}, desc);
    // 42 transferred through the alias, 0 from the cleared alias — the
    // write, read, transfer, clear, and discard paths all resolve.
    try testing.expectEqual(@as(Value, 42), v);
}

test "O aliases are call-clobbered: the call's arg staging overwrites the caller's O register" {
    // All O registers are call-clobbered (spec §4.1, §5): main's window
    // W = 4 gives O = 1, so the single O alias F(L+3) is simultaneously
    // the arg-0 staging cell and the result alias. A stale value primed
    // there before the call is overwritten by the argument transfer.
    var l = try load(
        \\fn f(x: int32) -> int32 { x }
        \\fn main() -> int32 { f(1) }
    , false);
    defer l.deinit();
    const main_fd = l.image.functions[try l.fid("main")];
    try testing.expectEqual(@as(u32, 4), main_fd.window_count); // O = 1
    const o_alias: u8 = llir.frame_base + @as(u8, @intCast(main_fd.f_count + 3)); // F(L+3) = O(0)
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    try drainRootInit(&vm, try l.fid("main"));
    const main_fp = vm.core.fp;
    const alias_cell = llir.frameCell(main_fp, main_fd, o_alias);
    vm_dispatch.write(&vm, o_alias, 0xdead); // a stale value in the O alias
    try testing.expectEqual(@as(u32, 0xdead), @as(u32, @truncate(vm.core.stack.items[alias_cell])));
    const call_pc = blk: {
        for (l.image.instructions, 0..) |rec, pc| {
            const d = llir.decode(rec) orelse continue;
            if (d.op == .jal and d.a == llir.ra_reg) break :blk @as(u32, @intCast(pc));
        }
        unreachable;
    };
    // Stepping to the call runs the arg staging: the `slot_move` into
    // the window overwrites the O alias — the stale value is gone.
    try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(vm.core.stack.items[alias_cell])));
    // The call itself (the frame write) leaves the alias holding the
    // callee's r0.
    try testing.expectEqual(@as(?interpreter.Termination, null), try vm_dispatch.step(&vm));
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(vm.core.stack.items[alias_cell])));
    // The take moves the result out of the alias (clearing it) and
    // main returns it.
    const v = try runToEnd(&vm);
    try testing.expectEqual(@as(Value, 1), v);
}

/// Run a loaded program to completion with the VM, returning the root
/// result. The program is `load`-ed (validated) already; this drives the
/// instruction path and yields the normal cell.
fn runLoaded(image: *llir.LlirProgram, entry: llir.FunctionId) !Value {
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(image, entry);
    var steps: usize = 0;
    while (!vm.core.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            if (t == .panic) {
                testing.allocator.free(t.panic);
                return error.TestUnexpectedResult;
            }
            return t.normal;
        }
        try vm.drainDestroyWork();
        steps += 1;
        if (steps > 100_000) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

/// Step a VM until `pc == target` (or the VM terminates); returns the
/// termination if it ended first, null if it reached the target.
fn stepToPc(vm: *interpreter.VmCtx, target: u32) !?interpreter.Termination {
    var steps: usize = 0;
    while (vm.core.pc != target and !vm.core.terminated) {
        if (try vm_dispatch.step(vm)) |t| return t;
        try vm.drainDestroyWork();
        steps += 1;
        if (steps > 100_000) return error.TestUnexpectedResult;
    }
    if (vm.core.terminated) return error.TestUnexpectedResult;
    return null;
}

/// Step a VM to termination, returning the root result cell.
fn runToEnd(vm: *interpreter.VmCtx) !Value {
    var steps: usize = 0;
    while (!vm.core.terminated) {
        if (try vm_dispatch.step(vm)) |t| {
            if (t == .panic) {
                testing.allocator.free(t.panic);
                return error.TestUnexpectedResult;
            }
            return t.normal;
        }
        try vm.drainDestroyWork();
        steps += 1;
        if (steps > 100_000) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

test "j discards no link — an intra-function jump never switches frames" {
    // The frontend lowers a forward `j` to the link-less `j` opcode. Compile a
    // program with a straight-line tail the optimizer folds, then patch
    // the resulting `jal ra` (the direct call in main) into a
    // link-less `j` targeting the same pc: it must be a pure pc advance that
    // leaves fp/sp and the header untouched until the real call later.
    var l = try load(
        \\fn callee() -> int32 { 9 }
        \\fn main() -> int32 { callee() }
    , false);
    defer l.deinit();
    // Locate the `jal ra` call record inside main's code range.
    const main_fd = l.image.functions[try l.fid("main")];
    var call_pc: u32 = 0;
    for (l.image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .jal and d.a == llir.ra_reg and pc >= main_fd.code_start and pc < main_fd.code_end) {
            call_pc = @intCast(pc);
            break;
        }
    }
    try testing.expect(call_pc != 0);
    const instrs = @constCast(l.image.instructions);
    // Replace the static call with a `j` to the same target — a
    // pure pc jump with no link register.
    const orig = instrs[call_pc];
    const d0 = llir.decode(orig).?;
    instrs[call_pc] = llir.instrJ(d0.imm20);
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    try drainRootInit(&vm, try l.fid("main"));
    const fp0 = vm.core.fp;
    const sp0 = vm.core.sp;
    // Step to the jump record (the caller may have prologue records
    // before it).
    try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
    try testing.expectEqual(@as(?interpreter.Termination, null), try vm_dispatch.step(&vm));
    // The j moved pc only — fp/sp untouched (pure jump), and no
    // header/link cell was written (the jump does not enter a callee).
    try testing.expectEqual(fp0, vm.core.fp);
    try testing.expectEqual(sp0, vm.core.sp);
    const d1 = llir.decode(instrs[call_pc]).?;
    try testing.expect(d1.op == .j);
}

test "jal ra is a direct call: link/target ordering, three-cell header" {
    var l = try load(
        \\fn callee() -> int32 { 9 }
        \\fn main() -> int32 { callee() }
    , false);
    defer l.deinit();
    const main_fd = l.image.functions[try l.fid("main")];
    // Find the call pc and the callee entry (scoped to main).
    var call_pc: u32 = 0;
    var callee_entry: u32 = 0;
    for (l.image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .jal and d.a == llir.ra_reg and pc >= main_fd.code_start and pc < main_fd.code_end) {
            call_pc = @intCast(pc);
            callee_entry = llir.jalTarget(call_pc, d.imm20);
            break;
        }
    }
    try testing.expect(call_pc != 0);
    const sp_before_call = llir.frameEnd(3, main_fd);
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    // Step to the call record (arg moves precede it).
    try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
    const sp0 = vm.core.sp;
    try testing.expectEqual(sp_before_call, sp0);
    try testing.expectEqual(@as(?interpreter.Termination, null), try vm_dispatch.step(&vm));
    // Header recorded below the window at the callee's frame base.
    const a: u32 = 1;
    const new_fp = sp0 - a;
    try testing.expectEqual(callee_entry, vm.core.pc); // pc moved to callee
    try testing.expectEqual(new_fp, vm.core.fp); // frame switched
    try testing.expectEqual(@as(u32, 3), @as(u32, @truncate(vm.core.stack.items[llir.headerBase(new_fp)]))); // saved_fp = root base
    try testing.expectEqual(call_pc + 1, @as(u32, @truncate(vm.core.stack.items[llir.headerBase(new_fp) + 2]))); // saved_ra
    // The result flows back through the callee's F0 — the caller's
    // register `F(L+3+O-A)` — and the generic `take`. The
    // callee may have more than one record before its `ret`, so run to
    // the callee's first `ret` (this simple callee has a const + ret).
    var ret_pc: u32 = 0;
    for (callee_entry..l.image.functions[try l.fid("callee")].code_end) |pc| {
        const dd = llir.decode(l.image.instructions[pc]) orelse continue;
        if (dd.op == .ret) {
            ret_pc = @intCast(pc);
            break;
        }
    }
    try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, ret_pc));
    const t = try vm_dispatch.step(&vm); // callee ret (pc back, result published)
    try testing.expectEqual(@as(?interpreter.Termination, null), t);
    try testing.expectEqual(call_pc + 1, vm.core.pc);
    // Step 8 coalescing: `main` returns the call result directly, so the
    // post-call `take` is dropped — the result stays in the caller's
    // result alias `F(L+3+O-A)` and the fallthrough `ret` reads it.
    const d = llir.decode(l.image.instructions[call_pc + 1]).?;
    try testing.expectEqual(llir.Opcode.ret, d.op);
    try testing.expectEqual(llir.frameReg(main_fd.f_count + main_fd.window_count - a), @as(u32, d.a)); // F(L+3+O-A)
    const r = try vm_dispatch.step(&vm); // ret reads the alias
    try testing.expectEqual(@as(Value, 9), r.?.normal);
}

test "nested calls: an inner jal ra clobbers ra; the outer link is restored from headers" {
    // Three frames f0 → f1 → f2. f1's own call overwrites the live `ra`
    // register, but f0's link lives in f0's header cell, so completion
    // of f2 → f1 → f0 must return the value chain unbroken.
    var l = try load(
        \\fn leaf() -> int32 { 42 }
        \\fn mid() -> int32 { leaf() }
        \\fn main() -> int32 { mid() }
    , false);
    defer l.deinit();
    const v = try runLoaded(l.image, try l.fid("main"));
    try testing.expectEqual(@as(Value, 42), v);
}

test "jalr: positive and negative signed offsets reach the entry" {
    // `jalr ra, base, offs16` resolves `base + signExtend16(offs16)`.
    // Use the simple main→callee program, patch its static `jal ra` into
    // a `jalr` on a seeded base register, and prove a +1 / -1 offset
    // reaches the entry (`base + offs == entry`). `callee()`'s result is
    // live across the `zero()` call, so the call keeps its post-call
    // `take` and the dynamic jalr contract still applies.
    var l = try load(
        \\fn callee() -> int32 { 9 }
        \\fn zero() -> int32 { 0 }
        \\fn main() -> int32 { let t = callee(); let u = zero(); t + u }
    , false);
    defer l.deinit();
    const main_fd = l.image.functions[try l.fid("main")];
    var call_pc: u32 = 0;
    for (l.image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .jal and d.a == llir.ra_reg and pc >= main_fd.code_start and pc < main_fd.code_end) {
            call_pc = @intCast(pc);
            break;
        }
    }
    try testing.expect(call_pc != 0);
    const instrs = @constCast(l.image.instructions);
    const d0 = llir.decode(instrs[call_pc]).?;
    const callee_entry = llir.jalTarget(call_pc, d0.imm20);
    const base_reg: u8 = llir.frame_base + 2;

    // Positive offset: base = callee_entry - 1, offs = +1 → entry.
    instrs[call_pc] = llir.instrI(.jalr, base_reg, @bitCast(@as(i16, 1)));
    {
        var vm = interpreter.VmCtx.init(testing.allocator);
        defer vm.deinit();
        try vm.setupRootArtifact(l.image, try l.fid("main"));
        try drainRootInit(&vm, try l.fid("main"));
        vm_dispatch.write(&vm, base_reg, callee_entry - 1);
        try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
        // Re-seed after any prologue writes this register.
        vm_dispatch.write(&vm, base_reg, callee_entry - 1);
        const t = try vm_dispatch.step(&vm); // jalr
        try testing.expectEqual(@as(?interpreter.Termination, null), t);
        try testing.expectEqual(callee_entry, vm.core.pc);
        // Finish to root.
        try testing.expectEqual(@as(Value, 9), try runToEnd(&vm));
    }
    // Negative offset: base = callee_entry + 1, offs = -1 → entry.
    instrs[call_pc] = llir.instrI(.jalr, base_reg, @bitCast(@as(i16, -1)));
    {
        var vm = interpreter.VmCtx.init(testing.allocator);
        defer vm.deinit();
        try vm.setupRootArtifact(l.image, try l.fid("main"));
        try drainRootInit(&vm, try l.fid("main"));
        vm_dispatch.write(&vm, base_reg, callee_entry + 1);
        try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
        vm_dispatch.write(&vm, base_reg, callee_entry + 1);
        const t = try vm_dispatch.step(&vm); // jalr
        try testing.expectEqual(@as(?interpreter.Termination, null), t);
        try testing.expectEqual(callee_entry, vm.core.pc);
        try testing.expectEqual(@as(Value, 9), try runToEnd(&vm));
    }
}

test "jalr: base-plus-offset overflow and non-entry targets trap before any write" {
    var l = try load(
        \\fn callee() -> int32 { 9 }
        \\fn zero() -> int32 { 0 }
        \\fn main() -> int32 { let t = callee(); let u = zero(); t + u }
    , false);
    defer l.deinit();
    // Convert the static call into a `jalr` on a seeded base register.
    var call_pc: u32 = 0;
    for (l.image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .jal and d.a == llir.ra_reg) {
            call_pc = @intCast(pc);
            break;
        }
    }
    try testing.expect(call_pc != 0);
    const instrs = @constCast(l.image.instructions);
    const d0 = llir.decode(instrs[call_pc]).?;
    const callee_entry = llir.jalTarget(call_pc, d0.imm20);
    const base_reg: u8 = llir.frame_base + 2; // a fresh F slot for a seedable base.
    // Overflow: base = u64::max, offs = +1 → exceeds u32 → trap.
    instrs[call_pc] = llir.instrI(.jalr, base_reg, @bitCast(@as(i16, 1)));
    {
        var vm = interpreter.VmCtx.init(testing.allocator);
        defer vm.deinit();
        try vm.setupRootArtifact(l.image, try l.fid("main"));
        try drainRootInit(&vm, try l.fid("main"));
        vm_dispatch.write(&vm, base_reg, std.math.maxInt(u64));
        const fp0 = vm.core.fp;
        const sp0 = vm.core.sp;
        try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
        vm_dispatch.write(&vm, base_reg, std.math.maxInt(u64));
        const t = try vm_dispatch.step(&vm);
        try testing.expect(t != null);
        try testing.expect(std.mem.indexOf(u8, t.?.panic, "overflow") != null);
        testing.allocator.free(t.?.panic);
        // Failure atomicity: pc/fp/sp untouched.
        try testing.expectEqual(fp0, vm.core.fp);
        try testing.expectEqual(sp0, vm.core.sp);
    }
    // Non-entry target: base = callee_entry + 1 (interior of callee).
    instrs[call_pc] = llir.instrI(.jalr, base_reg, 0);
    {
        var vm = interpreter.VmCtx.init(testing.allocator);
        defer vm.deinit();
        try vm.setupRootArtifact(l.image, try l.fid("main"));
        try drainRootInit(&vm, try l.fid("main"));
        vm_dispatch.write(&vm, base_reg, callee_entry + 1);
        try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
        vm_dispatch.write(&vm, base_reg, callee_entry + 1);
        const t = try vm_dispatch.step(&vm);
        try testing.expect(t != null);
        try testing.expect(std.mem.indexOf(u8, t.?.panic, "not a function entry") != null);
        testing.allocator.free(t.?.panic);
    }
    // Valid: base = callee_entry, offs = 0 → entry. Completes with 9.
    {
        var vm = interpreter.VmCtx.init(testing.allocator);
        defer vm.deinit();
        try vm.setupRootArtifact(l.image, try l.fid("main"));
        try drainRootInit(&vm, try l.fid("main"));
        vm_dispatch.write(&vm, base_reg, callee_entry);
        try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
        vm_dispatch.write(&vm, base_reg, callee_entry);
        const t = try vm_dispatch.step(&vm); // jalr
        try testing.expectEqual(@as(?interpreter.Termination, null), t);
        try testing.expectEqual(callee_entry, vm.core.pc);
        try testing.expectEqual(@as(Value, 9), try runToEnd(&vm));
    }
}

test "dynamic take contract mismatch fails before ra/header/frame write" {
    var l = try load(
        \\fn callee() -> int32 { 5 }
        \\fn zero() -> int32 { 0 }
        \\fn main() -> int32 { let t = callee(); let u = zero(); t + u }
    , false);
    defer l.deinit();
    var call_pc: u32 = 0;
    var take_pc: u32 = 0;
    for (l.image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        // The first `jal ra` is `callee()`'s call — its result `t` is
        // live across the later `zero()` call, so it keeps its post-call
        // `take` (Step 8 coalescing is rejected across a call).
        if (d.op == .jal and d.a == llir.ra_reg and call_pc == 0) {
            call_pc = @intCast(pc);
            break;
        }
    }
    try testing.expect(call_pc != 0);
    take_pc = call_pc + 1;
    try testing.expect(take_pc != 0);
    const instrs = @constCast(l.image.instructions);
    const orig = instrs[take_pc];
    // Corrupt the take's source register so it no longer equals
    // F(L+3+O-A) (a different real register, not the result alias).
    instrs[take_pc] = llir.instrE(.take, 0, 0);
    // Also convert the call to jalr so the contract is re-checked
    // dynamically after resolving the actual callee.
    const call_d = llir.decode(instrs[call_pc]).?;
    const callee_entry = llir.jalTarget(call_pc, call_d.imm20);
    const base_reg: u8 = llir.frame_base + 2;
    instrs[call_pc] = llir.instrI(.jalr, base_reg, 0);
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    try drainRootInit(&vm, try l.fid("main"));
    vm_dispatch.write(&vm, base_reg, callee_entry);
    const fp0 = vm.core.fp;
    const sp0 = vm.core.sp;
    const pc0 = vm.core.pc;
    // Prospective header cells (below the window).
    const a: u32 = 1;
    const new_fp = sp0 - a;
    const hb = llir.headerBase(new_fp);
    const hdr0 = vm.core.stack.items[hb];
    const hdr1 = vm.core.stack.items[hb + 1];
    // Step to the call; re-seed base (a prologue record may not touch
    // base_reg F2, but re-seed for determinism).
    try testing.expectEqual(@as(?interpreter.Termination, null), try stepToPc(&vm, call_pc));
    vm_dispatch.write(&vm, base_reg, callee_entry);
    const t = try vm_dispatch.step(&vm);
    try testing.expect(t != null);
    try testing.expect(std.mem.indexOf(u8, t.?.panic, "take contract mismatch") != null);
    testing.allocator.free(t.?.panic);
    // Failure atomicity: nothing written.
    try testing.expectEqual(pc0, vm.core.pc);
    try testing.expectEqual(fp0, vm.core.fp);
    try testing.expectEqual(sp0, vm.core.sp);
    try testing.expectEqual(hdr0, vm.core.stack.items[hb]);
    try testing.expectEqual(hdr1, vm.core.stack.items[hb + 1]);
    // Restore and confirm a clean run takes the result.
    instrs[take_pc] = orig;
    instrs[call_pc] = llir.instrU(.jal, llir.ra_reg, call_d.imm20);
    const v = try runLoaded(l.image, try l.fid("main"));
    try testing.expectEqual(@as(Value, 5), v);
}

test "T0–T15 call-clobber: callee's T writes are never restored" {
    // T0–T15 are one VM-global volatile bank (docs/interpreter-vm.md
    // §5): a `jal ra`/`jalr` logically clobbers them, and the VM never
    // saves/restores them. Build a callee that writes T0, cross it, and
    // assert the caller's old T0 value is not restored.
    var l = try load(
        \\fn callee() -> int32 { 9 }
        \\fn main() -> int32 { callee() }
    , false);
    defer l.deinit();
    // Find the call and the callee entry; patch the callee to write a
    // T register before returning (rewrite its first record).
    var call_pc: u32 = 0;
    var callee_entry: u32 = 0;
    for (l.image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .jal and d.a == llir.ra_reg) {
            call_pc = @intCast(pc);
            callee_entry = llir.jalTarget(call_pc, d.imm20);
            break;
        }
    }
    try testing.expect(call_pc != 0);
    const instrs = @constCast(l.image.instructions);
    // The callee's entry instruction becomes a movwz0 into T0 (0x6f).
    // Overwriting it with a T-write changes the callee's returned value
    // but the callee still terminates; main completes (returning the
    // overwritten value) and the T bank holds the callee's write.
    instrs[callee_entry] = llir.instrI(.movwz0, llir.temp_base, 0xbeef);
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    const t0_before: Value = 0xdead_beef;
    vm.core.fast_regs[llir.temp_base] = t0_before;
    var completed = false;
    var steps: usize = 0;
    while (!vm.core.terminated and steps < 1000) {
        if (try vm_dispatch.step(&vm)) |r| {
            if (r == .panic) {
                testing.allocator.free(r.panic);
                return error.TestUnexpectedResult;
            }
            completed = true;
            break;
        }
        try vm.drainDestroyWork();
        steps += 1;
    }
    try testing.expect(completed);
    // The callee wrote 0xbeef into T0. The VM does not restore the
    // caller's 0xdead_beef across the call (docs/interpreter-vm.md §5:
    // T0–T15 are a global volatile bank the VM never saves/restores).
    try testing.expectEqual(@as(Value, 0xbeef), vm.core.fast_regs[llir.temp_base]);
}
