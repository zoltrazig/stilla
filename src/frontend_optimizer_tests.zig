//! Test file: `frontend optimizer` — Pass 7 tail call elimination and
//! the construction-time on-the-fly optimizations (constant folding,
//! common subexpression elimination, copy elision) plus Pass 8.1/8.3
//! partial redundancy elimination (optimizer.md), exercised over whole
//! programs compiled through the frontend pipeline. Split out of the
//! former `src/frontend_tests.zig`; `foldProgram` is local to this file.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");
const lower = @import("lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");
const cfg_lower_emit = @import("passes/cfg_lower_emit.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const compileOpt = helpers.compileOpt;
const compileAggressive = helpers.compileAggressive;
const irText = helpers.irText;
const funcBody = helpers.funcBody;
// ---------------------------------------------------------------------------
// Pass 7 — tail call elimination (optimizer.md, Pass 7)
// ---------------------------------------------------------------------------

/// Test-only driver for the construction-time constant folding
/// (optimizer.md, On-the-fly optimizations): applies the same `tryFoldOp` that every `emit`
/// site uses to a parsed program, so the fold math (IEEE float
/// semantics, trap preservation, integer wrapping) can be tested
/// without the lowering. Not a pipeline pass — the frontend has no folding pass.
fn foldProgram(program: *cfg.IrProgram) void {
    for (program.funcs) |f| {
        for (f.blocks) |b| {
            for (b.instrs) |instr| {
                if (instr.results.len == 0) continue;
                const rt = instr.results[0].type_;
                if (cfg_lower_emit.tryFoldOp(instr.op, rt)) |c| instr.op = .{ .const_ = c };
            }
        }
    }
}

test "Pass 7 rewrites a self-recursive tail call into a loop" {
    // `countdown` calls itself in tail position: the else arm's call is the
    // last instruction before the join, and its result flows through the
    // join's single phi straight into the `ret` (§7.1). TCO turns the call
    // into a branch back to the entry, which becomes a loop header with a
    // param phi merging the entry value and the loop-back argument; a
    // no-pred trampoline forwards the entry so the text form's first block
    // keeps no predecessors (air.md §13). Values are renumbered in text
    // order, so the header phi prints first.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn countdown(n: int32) -> int32 {
            \\    if (n == 0) {
            \\        0
            \\    } else {
            \\        countdown(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    // The trampoline forwards to the loop header...
    try testing.expect(std.mem.indexOf(u8, text, "    entry:\n        j header") != null);
    // ...which opens with the param phi merging the entry value (%0) and
    // the loop-back argument...
    try testing.expect(std.mem.indexOf(u8, text, "        %1: int32 = phi [%0, entry], [") != null);
    // ...and the recursive call is gone: the tail block branches back.
    try testing.expect(std.mem.indexOf(u8, text, "call @app.countdown") == null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") != null);

    // The rewritten text round-trips through the standalone cfg parser
    // (air.md §13): the header phi has one incoming per predecessor.
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 7 rewrites a void self-recursive tail call into a loop" {
    // `count` returns void; the else arm's call is followed only by the
    // lowerer's `const void` noise before the bare `ret`, so it is in tail
    // position and becomes a loop (§7.1).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn count(n: int32) -> void {
            \\    if (n == 0) {
            \\    } else {
            \\        count(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "    entry:\n        j header") != null);
    try testing.expect(std.mem.indexOf(u8, text, "        %1: int32 = phi [%0, entry], [") != null);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.count") == null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 7 skips a tail call whose chain merges another arm's value" {
    // The guarded recursion `if (n<=0) {0} else if (n==1) {1} else
    // {f(n-1)}` lowers the middle arm's value through a phi-only join
    // *before* the ret join. That join is an intermediate chain block
    // with two predecessors (then_1 and the recursive arm), so the
    // rewrite's chain-edge drop would strand the `1` — the ret block's
    // phi would reduce to only the `0` arm and the function would return
    // 0 for every n >= 1 (§7.2). The call must stay ordinary instead.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(n: int32) -> int32 {
            \\    if (n <= 0) {
            \\        0
            \\    } else if (n == 1) {
            \\        1
            \\    } else {
            \\        f(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    // The recursion is left as a call, and the join still receives the
    // middle arm's `1` through a phi.
    try testing.expect(std.mem.indexOf(u8, text, "call @app.f") != null);
    try testing.expect(std.mem.indexOf(u8, text, "phi [%6, then_1], [%9, else_1]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") == null);

    // The full pipeline keeps the result correct and validates.
    var full = try compileText("app", &.{
        .{
            "app",
            \\fn f(n: int32) -> int32 {
            \\    if (n <= 0) {
            \\        0
            \\    } else if (n == 1) {
            \\        1
            \\    } else {
            \\        f(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer full.deinit();
    var fprogram = full.program.?;
    try lower.optimize(&fprogram, full.arena.allocator());
    const ftext = try irText(&fprogram);
    defer testing.allocator.free(ftext);
    try testing.expect(std.mem.indexOf(u8, ftext, "call @app.f") != null);
    // The recursion stays a call and the ret is not void — the exact
    // result id is an implementation detail of the pass sequence.
    const fbody = funcBody(ftext, "func @app.f");
    try testing.expect(std.mem.indexOf(u8, fbody, "ret %") != null);
}

test "Pass 7 skips tail calls whose ret block would be orphaned" {
    // Both arms call `f` in tail position and both chains end at the
    // same ret block, whose every predecessor is one of the call blocks.
    // Rewriting both would leave the ret block with no predecessors and
    // dead-block elimination would delete the function's only `ret`
    // (§7.2); both calls must stay ordinary.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(n: int32) -> int32 {
            \\    if (n <= 0) {
            \\        f(n)
            \\    } else {
            \\        f(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.f") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %7") != null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") == null);
}

test "Pass 7 skips a void tail call whose chain merges another arm" {
    // The void guarded recursion `if (n<=0) {} else if (n==1) {} else
    // { log(n-1) }` lowers the middle arm through a noise-only join
    // before the ret join. That intermediate chain block has two
    // predecessors (then_1 and the recursive arm), so the rewrite's
    // chain-edge drop would strand the middle arm's edge and the
    // validator's forward-edge check would reject the result (§7.2); the
    // call must stay ordinary instead.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn log(n: int32) -> void {
            \\    if (n <= 0) {
            \\    } else if (n == 1) {
            \\    } else {
            \\        log(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.log") != null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") == null);
}

test "Pass 7 leaves a non-tail self-recursive call alone" {
    // The recursive call is an operand of `add`, not the last thing before
    // the join's ret, so it is not in tail position (§7.1).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(n: int32) -> int32 {
            \\    if (n == 0) {
            \\        0
            \\    } else {
            \\        1 + f(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.f") != null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") == null);
}

test "Pass 7 leaves a tail call to another function alone" {
    // The call is in tail position but targets `g`, not the enclosing
    // function, so only the enclosing function's own recursion is eligible
    // (§7.2, §7.3).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn g(n: int32) -> int32 { n }
            \\fn f(n: int32) -> int32 {
            \\    if (n == 0) {
            \\        0
            \\    } else {
            \\        g(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.g") != null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") == null);
}

test "Pass 7 leaves a value call alone" {
    // The callee is a function-typed parameter, so the target is not
    // statically known; only direct calls to a known IrFunc are candidates
    // (§7.3).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn apply(g: fn(int32) -> int32, n: int32) -> int32 {
            \\    g(n)
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "call %0, %1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") == null);
}

test "Pass 7 leaves a tail call with live unique state alone" {
    // The hostdata local is unique: its scope-end `drop` sits in the join,
    // so the join is not phi-only and the call's result does not reach the
    // `ret` through nothing but phis (§7.1). The rewrite must not reorder
    // the drop (§7.3).
    var c = try compileText("app", &.{
        .{ "os", "fn get_handle() -> hostdata;" },
        .{
            "app",
            \\const os = import("os");
            \\fn f(n: int32) -> int32 {
            \\    let h = os.get_handle();
            \\    if (n == 0) {
            \\        0
            \\    } else {
            \\        f(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.tailCall(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.f") != null);
    try testing.expect(std.mem.indexOf(u8, text, "j header") == null);
}

test "Pass 7 runs before the Pass 8 pipeline" {
    // optimizer.md: the optimizer runs Pass 7 before Pass 8. `optimize`
    // therefore rewrites the tail call into a loop first, and the later
    // passes (which keep the loop reachable) leave the rewrite intact.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn countdown(n: int32) -> int32 {
            \\    if (n == 0) {
            \\        0
            \\    } else {
            \\        countdown(n - 1)
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.optimize(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "    entry:\n        j header") != null);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.countdown") == null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

// ---------------------------------------------------------------------------
// On-the-fly constant folding (optimizer.md, On-the-fly optimizations)
// ---------------------------------------------------------------------------

test "Pass 8.1 folds constant arithmetic, comparison, and logic" {
    // 3 * 2 = 6, 6 + 5 = 11, 11 > 2 = true, !true = false — each rewritten
    // to a const instruction in place; ids and block structure are
    // unchanged (optimizer.md, On-the-fly optimizations).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> bool {
        \\entry:
        \\    %0: int32 = const 2
        \\    %1: int32 = const 3
        \\    %2: int32 = mul %0, %1
        \\    %3: int32 = const 5
        \\    %4: int32 = add %2, %3
        \\    %5: bool = gt %4, %0
        \\    %6: bool = not %5
        \\    ret %6
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[0].op == .const_);
    try testing.expectEqual(@as(i64, 2), instrs[0].op.const_.int);
    try testing.expect(instrs[2].op == .const_);
    try testing.expectEqual(@as(i64, 6), instrs[2].op.const_.int);
    try testing.expect(instrs[4].op == .const_);
    try testing.expectEqual(@as(i64, 11), instrs[4].op.const_.int);
    try testing.expect(instrs[5].op == .const_);
    try testing.expectEqual(true, instrs[5].op.const_.bool);
    try testing.expect(instrs[6].op == .const_);
    try testing.expectEqual(false, instrs[6].op.const_.bool);
}

test "Pass 8.1 folds constant bitwise ops" {
    // Bitwise ops are total and bit-identical on int32/uint32 (Runtime
    // §7.2): 5 & 3 = 1, 5 | 3 = 7, 5 ^ 3 = 6 — each folded to a const in
    // place.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> int32 {
        \\entry:
        \\    %0: int32 = const 5
        \\    %1: int32 = const 3
        \\    %2: int32 = bitand %0, %1
        \\    %3: int32 = bitor %0, %1
        \\    %4: int32 = bitxor %0, %1
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[2].op == .const_);
    try testing.expectEqual(@as(i64, 1), instrs[2].op.const_.int); // 5 & 3
    try testing.expect(instrs[3].op == .const_);
    try testing.expectEqual(@as(i64, 7), instrs[3].op.const_.int); // 5 | 3
    try testing.expect(instrs[4].op == .const_);
    try testing.expectEqual(@as(i64, 6), instrs[4].op.const_.int); // 5 ^ 3
}

test "Pass 8.1 simplifies bitwise identities at construction" {
    // Integer identities (braun13cc.pdf §3.1's arithmetic simplification)
    // fire at each emit site: `x | 0 -> x` and `0 ^ x -> x` reuse the
    // operand (no instruction), `x & 0 -> 0` folds to the zero constant —
    // with the zero on either side (bitwise ops commute).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f(a: int32) -> int32 { a | 0 }
            \\fn g(a: int32) -> int32 { 0 ^ a }
            \\fn h(a: int32) -> int32 { a & 0 }
            \\fn main() -> void {
            \\    let _ = f(1);
            \\    let _ = g(2);
            \\    let _ = h(3);
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    // No bitwise instruction survives: every site folded or reused.
    try testing.expect(std.mem.indexOf(u8, text, "bitor") == null);
    try testing.expect(std.mem.indexOf(u8, text, "bitxor") == null);
    try testing.expect(std.mem.indexOf(u8, text, "bitand") == null);
}

test "Pass 8.1 folds float arithmetic and comparisons" {
    // Float arithmetic is IEEE binary32 (Runtime §7.2): division by zero
    // never traps — 4.0/0.0 = +inf, -4.0/0.0 = -inf, and 0.0/0.0 = NaN
    // (NaN compares unequal to itself, so NaN == NaN folds to false).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> bool {
        \\entry:
        \\    %0: float32 = const 2.5
        \\    %1: float32 = const 4.0
        \\    %2: float32 = mul %0, %1
        \\    %3: float32 = const 0.0
        \\    %4: float32 = div %1, %3
        \\    %5: bool = gt %2, %0
        \\    %6: float32 = const -4.0
        \\    %7: float32 = div %6, %3
        \\    %8: float32 = div %3, %3
        \\    %9: bool = eq %4, %4
        \\    %10: bool = eq %8, %8
        \\    %11: bool = lt %7, %4
        \\    ret %11
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[2].op == .const_);
    try testing.expectEqual(@as(f32, 10.0), instrs[2].op.const_.float);
    // 4.0 / 0.0 = +inf.
    try testing.expect(instrs[4].op == .const_);
    try testing.expect(std.math.isInf(instrs[4].op.const_.float));
    try testing.expect(!std.math.signbit(instrs[4].op.const_.float));
    try testing.expect(instrs[5].op == .const_);
    try testing.expectEqual(true, instrs[5].op.const_.bool);
    // -4.0 / 0.0 = -inf.
    try testing.expect(instrs[7].op == .const_);
    try testing.expect(std.math.isInf(instrs[7].op.const_.float));
    try testing.expect(std.math.signbit(instrs[7].op.const_.float));
    // 0.0 / 0.0 = NaN.
    try testing.expect(instrs[8].op == .const_);
    try testing.expect(std.math.isNan(instrs[8].op.const_.float));
    // +inf == +inf folds to true; NaN == NaN folds to false; -inf < +inf.
    try testing.expect(instrs[9].op == .const_);
    try testing.expectEqual(true, instrs[9].op.const_.bool);
    try testing.expect(instrs[10].op == .const_);
    try testing.expectEqual(false, instrs[10].op.const_.bool);
    try testing.expect(instrs[11].op == .const_);
    try testing.expectEqual(true, instrs[11].op.const_.bool);
}

test "Pass 8.1 folds wrapping arithmetic, leaves division traps unfolded" {
    // WebAssembly semantics (Runtime §7.2): int32/uint32 arithmetic wraps
    // modulo 2³² — add/sub/mul overflow and neg of minInt fold to their
    // wrapped values, as does uint32 negation (two's-complement). Folding
    // must never turn a runtime trap into a value: div/rem by zero and the
    // int32_min div -1 division-overflow case stay as ops (int32_min rem
    // -1 is 0 and never traps, but is left unfolded too, conservatively).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> int32 {
        \\entry:
        \\    %0: int32 = const 7
        \\    %1: int32 = const 0
        \\    %2: int32 = div %0, %1
        \\    %3: int32 = const 1
        \\    %4: int32 = rem %3, %1
        \\    %5: int32 = const 2147483647
        \\    %6: int32 = add %5, %3
        \\    %7: int32 = const -2147483648
        \\    %8: int32 = neg %7
        \\    %9: int32 = sub %5, %7
        \\    %10: int32 = mul %5, %5
        \\    %11: int32 = const -1
        \\    %12: int32 = div %7, %11
        \\    %13: int32 = rem %7, %11
        \\    %14: uint32 = const 4000000000
        \\    %15: uint32 = add %14, %14
        \\    %16: uint32 = const 5
        \\    %17: uint32 = neg %16
        \\    ret %8
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[2].op == .div); // div by zero: traps, unfolded
    try testing.expect(instrs[4].op == .rem); // rem by zero: traps, unfolded
    try testing.expect(instrs[6].op == .const_);
    try testing.expectEqual(@as(i64, -2147483648), instrs[6].op.const_.int); // max + 1 wraps to min
    try testing.expect(instrs[8].op == .const_);
    try testing.expectEqual(@as(i64, -2147483648), instrs[8].op.const_.int); // neg(min) wraps to min
    try testing.expect(instrs[9].op == .const_);
    try testing.expectEqual(@as(i64, -1), instrs[9].op.const_.int); // max - min wraps to -1
    try testing.expect(instrs[10].op == .const_);
    try testing.expectEqual(@as(i64, 1), instrs[10].op.const_.int); // max * max wraps to 1
    try testing.expect(instrs[12].op == .div); // min div -1: traps, unfolded
    try testing.expect(instrs[13].op == .rem); // min rem -1: 0, never traps — left unfolded conservatively
    try testing.expect(instrs[15].op == .const_);
    try testing.expectEqual(@as(i64, 3705032704), instrs[15].op.const_.int); // uint32 add wraps
    try testing.expect(instrs[17].op == .const_);
    try testing.expectEqual(@as(i64, 4294967291), instrs[17].op.const_.int); // uint32 neg = 0 - 5 wraps
}

test "Pass 8.1 folds int32 division, remainder, and ordering" {
    // int32 div/rem truncate toward zero with the dividend's sign
    // (Runtime §7.2): 7 div 2 = 3, 7 rem 2 = 1, -7 div 2 = -3,
    // -7 rem 2 = -1. Every ordering op folds over int32.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> bool {
        \\entry:
        \\    %0: int32 = const 7
        \\    %1: int32 = const 2
        \\    %2: int32 = div %0, %1
        \\    %3: int32 = rem %0, %1
        \\    %4: int32 = const -7
        \\    %5: int32 = div %4, %1
        \\    %6: int32 = rem %4, %1
        \\    %7: bool = lt %0, %1
        \\    %8: bool = le %0, %0
        \\    %9: bool = gt %0, %1
        \\    %10: bool = ge %1, %0
        \\    %11: bool = eq %0, %0
        \\    %12: bool = ne %0, %1
        \\    ret %12
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[2].op == .const_);
    try testing.expectEqual(@as(i64, 3), instrs[2].op.const_.int);
    try testing.expect(instrs[3].op == .const_);
    try testing.expectEqual(@as(i64, 1), instrs[3].op.const_.int);
    try testing.expect(instrs[5].op == .const_);
    try testing.expectEqual(@as(i64, -3), instrs[5].op.const_.int);
    try testing.expect(instrs[6].op == .const_);
    try testing.expectEqual(@as(i64, -1), instrs[6].op.const_.int);
    try testing.expect(instrs[7].op == .const_);
    try testing.expectEqual(false, instrs[7].op.const_.bool);
    try testing.expect(instrs[8].op == .const_);
    try testing.expectEqual(true, instrs[8].op.const_.bool);
    try testing.expect(instrs[9].op == .const_);
    try testing.expectEqual(true, instrs[9].op.const_.bool);
    try testing.expect(instrs[10].op == .const_);
    try testing.expectEqual(false, instrs[10].op.const_.bool);
    try testing.expect(instrs[11].op == .const_);
    try testing.expectEqual(true, instrs[11].op.const_.bool);
    try testing.expect(instrs[12].op == .const_);
    try testing.expectEqual(true, instrs[12].op.const_.bool);
}

test "Pass 8.1 folds uint32 arithmetic and ordering" {
    // uint32 operands fold with unsigned wrap-avoidance: 3000000000 +
    // 1000000000 = 4000000000 stays in range; ordering compares unsigned.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> bool {
        \\entry:
        \\    %0: uint32 = const 3000000000
        \\    %1: uint32 = const 1000000000
        \\    %2: uint32 = add %0, %1
        \\    %3: uint32 = const 7
        \\    %4: uint32 = const 2
        \\    %5: uint32 = div %3, %4
        \\    %6: uint32 = rem %3, %4
        \\    %7: uint32 = mul %3, %4
        \\    %8: uint32 = sub %0, %1
        \\    %9: uint32 = const 2000000000
        \\    %10: bool = gt %0, %9
        \\    %11: bool = eq %3, %4
        \\    ret %11
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[2].op == .const_);
    try testing.expectEqual(@as(i64, 4000000000), instrs[2].op.const_.int);
    try testing.expect(instrs[5].op == .const_);
    try testing.expectEqual(@as(i64, 3), instrs[5].op.const_.int);
    try testing.expect(instrs[6].op == .const_);
    try testing.expectEqual(@as(i64, 1), instrs[6].op.const_.int);
    try testing.expect(instrs[7].op == .const_);
    try testing.expectEqual(@as(i64, 14), instrs[7].op.const_.int);
    try testing.expect(instrs[8].op == .const_);
    try testing.expectEqual(@as(i64, 2000000000), instrs[8].op.const_.int);
    try testing.expect(instrs[10].op == .const_);
    try testing.expectEqual(true, instrs[10].op.const_.bool);
    try testing.expect(instrs[11].op == .const_);
    try testing.expectEqual(false, instrs[11].op.const_.bool);
}

test "Pass 8.1 folds equality over byte, bool, and str" {
    // Core §16.3: ==/!= span byte, bool, and str; the ordering ops are
    // numeric-only, so `lt` on byte and str stays unfolded.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> bool {
        \\entry:
        \\    %0: byte = const 200
        \\    %1: byte = const 200
        \\    %2: bool = eq %0, %1
        \\    %3: byte = const 5
        \\    %4: bool = ne %0, %3
        \\    %5: bool = lt %0, %3
        \\    %6: bool = const true
        \\    %7: bool = eq %6, %6
        \\    %8: bool = ne %6, %6
        \\    %9: str = const "abc"
        \\    %10: str = const "abc"
        \\    %11: bool = eq %9, %10
        \\    %12: str = const "abd"
        \\    %13: bool = ne %9, %12
        \\    %14: bool = lt %9, %12
        \\    ret %13
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[2].op == .const_);
    try testing.expectEqual(true, instrs[2].op.const_.bool);
    try testing.expect(instrs[4].op == .const_);
    try testing.expectEqual(true, instrs[4].op.const_.bool);
    try testing.expect(instrs[5].op == .lt);
    try testing.expect(instrs[7].op == .const_);
    try testing.expectEqual(true, instrs[7].op.const_.bool);
    try testing.expect(instrs[8].op == .const_);
    try testing.expectEqual(false, instrs[8].op.const_.bool);
    try testing.expect(instrs[11].op == .const_);
    try testing.expectEqual(true, instrs[11].op.const_.bool);
    try testing.expect(instrs[13].op == .const_);
    try testing.expectEqual(true, instrs[13].op.const_.bool);
    try testing.expect(instrs[14].op == .lt);
}

test "Pass 8.1 folds unary negation" {
    // int32 and float32 neg fold; neg of minInt wraps to minInt and
    // uint32 neg computes 0 - x — both fold (see the wrapping-arithmetic
    // test).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> int32 {
        \\entry:
        \\    %0: int32 = const 5
        \\    %1: int32 = neg %0
        \\    %2: float32 = const 2.5
        \\    %3: float32 = neg %2
        \\    %4: float32 = const -2.5
        \\    %5: float32 = neg %4
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[1].op == .const_);
    try testing.expectEqual(@as(i64, -5), instrs[1].op.const_.int);
    try testing.expect(instrs[3].op == .const_);
    try testing.expectEqual(@as(f32, -2.5), instrs[3].op.const_.float);
    try testing.expect(instrs[5].op == .const_);
    try testing.expectEqual(@as(f32, 2.5), instrs[5].op.const_.float);
}

test "Pass 8.1 folds abs/min/max/clz/popcount" {
    // The extended numeric families are all total (never trap), so they
    // always fold when constant: i32_abs wraps on int32_min (modulo
    // 2³²), f32_abs clears the sign bit; min/max compare as 32-bit
    // patterns (signedness by opcode) and follow IEEE fmin/fmax on f32
    // (NaN propagates, fmin(-0,+0) = -0); clz(0) = 32 and popcount
    // counts set bits.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> int32 {
        \\entry:
        \\    %0: int32 = const -5
        \\    %1: int32 = abs %0
        \\    %2: int32 = const 3
        \\    %3: int32 = min %0, %2
        \\    %4: int32 = max %0, %2
        \\    %5: int32 = const 0
        \\    %6: int32 = clz %5
        \\    %7: int32 = popcount %0
        \\    ret %7
        \\}
        \\func @wrap() -> int32 {
        \\entry:
        \\    %0: int32 = const -2147483648
        \\    %1: int32 = abs %0
        \\    ret %1
        \\}
        \\func @g() -> uint32 {
        \\entry:
        \\    %0: uint32 = const 65535
        \\    %1: uint32 = clz %0
        \\    %2: uint32 = popcount %0
        \\    %3: uint32 = min %0, %1
        \\    %4: uint32 = max %0, %1
        \\    ret %4
        \\}
        \\func @h() -> float32 {
        \\entry:
        \\    %0: float32 = const -2.5
        \\    %1: float32 = abs %0
        \\    %2: float32 = const -0.0
        \\    %3: float32 = min %2, %1
        \\    %4: float32 = max %2, %1
        \\    %5: float32 = const 1.0
        \\    %6: float32 = min %5, %1
        \\    ret %6
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const fi = t.program.funcs[0].entry.instrs;
    try testing.expect(fi[1].op == .const_);
    try testing.expectEqual(@as(i64, 5), fi[1].op.const_.int); // abs(-5)
    try testing.expect(fi[3].op == .const_);
    try testing.expectEqual(@as(i64, -5), fi[3].op.const_.int); // min(-5, 3)
    try testing.expect(fi[4].op == .const_);
    try testing.expectEqual(@as(i64, 3), fi[4].op.const_.int); // max(-5, 3)
    try testing.expect(fi[6].op == .const_);
    try testing.expectEqual(@as(i64, 32), fi[6].op.const_.int); // clz(0)
    try testing.expect(fi[7].op == .const_);
    try testing.expectEqual(@as(i64, 31), fi[7].op.const_.int); // popcount(-5)

    // abs(int32_min) wraps to int32_min itself (modulo 2³² — negation
    // of the minimum wraps, WebAssembly semantics; never traps).
    const wi = t.program.funcs[1].entry.instrs;
    try testing.expect(wi[1].op == .const_);
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), wi[1].op.const_.int);

    const gi = t.program.funcs[2].entry.instrs;
    try testing.expect(gi[1].op == .const_);
    try testing.expectEqual(@as(i64, 16), gi[1].op.const_.int); // clz(0x0000ffff)
    try testing.expect(gi[2].op == .const_);
    try testing.expectEqual(@as(i64, 16), gi[2].op.const_.int); // popcount(0x0000ffff)
    try testing.expect(gi[3].op == .const_);
    try testing.expectEqual(@as(i64, 16), gi[3].op.const_.int); // min(0x0000ffff, 16)
    try testing.expect(gi[4].op == .const_);
    try testing.expectEqual(@as(i64, 65535), gi[4].op.const_.int); // max

    const hi = t.program.funcs[3].entry.instrs;
    try testing.expect(hi[1].op == .const_);
    try testing.expectEqual(@as(f32, 2.5), hi[1].op.const_.float); // abs(-2.5)
    try testing.expect(hi[3].op == .const_);
    // fmin(-0.0, 2.5) = -0.0 — IEEE fmin keeps the sign of the zero tie.
    try testing.expect(std.math.signbit(hi[3].op.const_.float));
    try testing.expect(hi[4].op == .const_);
    try testing.expectEqual(@as(f32, 2.5), hi[4].op.const_.float); // fmax(-0.0, 2.5)
    try testing.expect(hi[6].op == .const_);
    try testing.expectEqual(@as(f32, 1.0), hi[6].op.const_.float); // fmin(1.0, 2.5)
}

test "Pass 8.1 abs/min/max/clz/popcount AIR round-trips through the standalone cfg parser" {
    // The extended ops print through the schema spelling and re-parse
    // identically (air.md §13) — unary forms and the min/max binary
    // forms included.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    %2: int32 = abs %0
        \\    %3: int32 = clz %0
        \\    %4: int32 = popcount %0
        \\    %5: int32 = min %0, %1
        \\    %6: int32 = max %0, %1
        \\    ret %6
        \\}
        \\func @g(a: float32) -> float32 {
        \\entry:
        \\    %1: float32 = abs %0
        \\    %2: float32 = min %1, %0
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();

    const text = try irText(&t.program);
    defer testing.allocator.free(text);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.1 folds saturating num_casts" {
    // Only int32 as float32 and float32 as int32 are core conversions
    // (Core §16.3). Casts never trap (Runtime §7.2): casting the folded
    // +inf, NaN, and 2^31 constants saturates — +inf and 2^31 to the
    // int32 maximum, NaN to zero.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> int32 {
        \\entry:
        \\    %0: float32 = const 1.0
        \\    %1: float32 = const 0.0
        \\    %2: float32 = div %0, %1
        \\    %3: int32 = num_cast %2
        \\    %4: float32 = const 0.0
        \\    %5: float32 = div %4, %4
        \\    %6: int32 = num_cast %5
        \\    %7: float32 = const 2147483648.0
        \\    %8: int32 = num_cast %7
        \\    ret %8
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    // Sanity: the div-by-zero sources did fold to +inf and NaN.
    try testing.expect(instrs[2].op == .const_);
    try testing.expect(std.math.isInf(instrs[2].op.const_.float));
    try testing.expect(instrs[5].op == .const_);
    try testing.expect(std.math.isNan(instrs[5].op.const_.float));
    // The casts of +inf, NaN, and 2^31 fold to saturated int32 values:
    // +inf and 2^31 saturate to maxInt, NaN becomes zero.
    try testing.expect(instrs[3].op == .const_);
    try testing.expectEqual(@as(i64, std.math.maxInt(i32)), instrs[3].op.const_.int);
    try testing.expect(instrs[6].op == .const_);
    try testing.expectEqual(@as(i64, 0), instrs[6].op.const_.int);
    try testing.expect(instrs[8].op == .const_);
    try testing.expectEqual(@as(i64, std.math.maxInt(i32)), instrs[8].op.const_.int);
}

test "Pass 8.1 folds the core num_casts" {
    // Core §16.3: int32 as float32 and float32 as int32 are core
    // conversions; both fold (asserted in memory — an integral float
    // prints without a decimal point, which the parser reads back as an
    // int literal).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f() -> int32 {
        \\entry:
        \\    %0: int32 = const 3
        \\    %1: float32 = num_cast %0
        \\    %2: int32 = num_cast %1
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    foldProgram(&t.program);

    const instrs = t.program.funcs[0].entry.instrs;
    try testing.expect(instrs[1].op == .const_);
    try testing.expectEqual(@as(f32, 3.0), instrs[1].op.const_.float);
    try testing.expect(instrs[2].op == .const_);
    try testing.expectEqual(@as(i64, 3), instrs[2].op.const_.int);
}

test "Pass 8.1 folded AIR round-trips through the standalone cfg parser" {
    // Folding rewrites ops in place (no new values, no id gaps), so the
    // printed text still re-parses and re-prints identically (air.md §13).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f() -> int32 { 2 + 3 * 4 }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.optimize(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, " = const 14") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

// ---------------------------------------------------------------------------
// On-the-fly common subexpression elimination at construction
// (optimizer.md, On-the-fly optimizations) — the frontend has no
// separate CSE pass (braun13cc.pdf §3.1): an
// identical pure computation earlier in the same block is reused at its
// emit site, so no `copy` instructions are involved.
// ---------------------------------------------------------------------------

test "frontend reuses duplicate pure computations in a block" {
    // `a * b` computed twice in the same block is computed once; the
    // second occurrence uses the first result.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(a: int32, b: int32) -> int32 {
            \\    let x = a * b;
            \\    let y = a * b;
            \\    x + y
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // One mul, used by the single add of the two bindings.
    try testing.expect(std.mem.indexOf(u8, out, "mul %0, %1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "add %2, %2") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(out);
    const out2 = try irText(&reparsed);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings(out, out2);
}

test "frontend does not commute CSE operand order" {
    // `a * b` and `b * a` are different expressions: no commutativity
    // (floating-point and NaN behavior must be unchanged).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(a: int32, b: int32) -> int32 {
            \\    let x = a * b;
            \\    let y = b * a;
            \\    x + y
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "mul %0, %1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mul %1, %0") != null);
}

test "frontend reuses duplicate reads and casts" {
    // The CSE candidate set spans the pure projections: an identical
    // `read_field` or `cast` in the same block is computed once.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct S { x: int32; }
            \\fn f(s: S) -> float32 {
            \\    let a = s.x;
            \\    let b = s.x;
            \\    let c = a as float32;
            \\    let d = b as float32;
            \\    c + d
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // One read_field and one cast, each reused.
    try testing.expect(std.mem.count(u8, out, "read_field %0, #0") == 1);
    try testing.expect(std.mem.count(u8, out, "cast %1") == 1);
    try testing.expect(std.mem.indexOf(u8, out, "add %2, %2") != null);
}

test "frontend does not CSE unique results" {
    // Reusing an unique value twice would change the destruction
    // schedule (air.md §6.4): `h.file` (result type File, unique) is
    // computed twice, so the outer field reads see different bases and
    // all four `read_field`s stay.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\struct Holder { file: File; drop(h) {} }
            \\fn f(borrow h: Holder) -> int32 {
            \\    h.file.fd + h.file.fd
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.count(u8, out, "read_field") == 4);
}

test "frontend CSE is block-local" {
    // A computation in the entry block is not reused in the join after
    // an `if` — construction-time CSE only sees the current block.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(a: int32, b: int32, c: bool) -> int32 {
            \\    let x = a * b;
            \\    let y = if (c) { 1 } else { 2 };
            \\    let z = a * b;
            \\    x + y + z
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // Two muls: one in entry, one in the join.
    try testing.expect(std.mem.count(u8, out, "mul %0, %1") == 2);
}

test "construction-time optimized AIR round-trips through the standalone cfg parser" {
    // The on-the-fly rewrites happen at construction; the printed text
    // re-parses and re-prints identically (air.md §13).
    var c = try compileText("app", &.{
        .{ "app", "fn f(a: int32, b: int32) -> int32 { (a + b) * (a + b) }\nfn main() -> void {}" },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // `a + b` is computed once and reused by both muls.
    try testing.expect(std.mem.count(u8, out, "add %0, %1") == 1);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(out);
    const out2 = try irText(&reparsed);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings(out, out2);
}

// Pass 8.1 — partial redundancy elimination (optimizer.md, Pass 8.1)
// ---------------------------------------------------------------------------

test "Pass 8.3 hoists a partially redundant comparison into a join phi" {
    // `lt %0, %1` runs on the `neg` edge but not on `pos`, so the join's
    // copy is partially redundant: PRE inserts the computation at the end
    // of `pos` and turns the join's computation into a phi (optimizer.md,
    // Pass 8.1).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    j join
        \\neg:
        \\    %3: bool = lt %0, %1
        \\    j join
        \\join:
        \\    %4: bool = lt %0, %1
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    try testing.expectEqual(@as(usize, 4), blocks.len);
    const pos = blocks[1];
    const neg = blocks[2];
    const join = blocks[3];

    try testing.expectEqual(@as(usize, 1), pos.instrs.len);
    try testing.expect(pos.instrs[0].op == .lt);
    try testing.expectEqual(@as(usize, 1), neg.instrs.len);
    try testing.expect(neg.instrs[0].op == .lt);
    try testing.expectEqual(@as(usize, 1), join.instrs.len);
    const phi = switch (join.instrs[0].op) {
        .phi => |p| p,
        else => return error.UnexpectedOp,
    };
    try testing.expectEqual(@as(usize, 2), phi.incoming.len);
    try testing.expect(phi.incoming[0].pred == pos);
    try testing.expect(phi.incoming[0].value == pos.instrs[0].results[0]);
    try testing.expect(phi.incoming[1].pred == neg);
    try testing.expect(phi.incoming[1].value == neg.instrs[0].results[0]);
}

test "Pass 8.3 joins a fully redundant computation without inserting" {
    // Both edges already compute `lt %0, %1`, so the join's copy is fully
    // redundant: PRE replaces it with a phi and inserts nothing.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    %3: bool = lt %0, %1
        \\    j join
        \\neg:
        \\    %4: bool = lt %0, %1
        \\    j join
        \\join:
        \\    %5: bool = lt %0, %1
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    try testing.expectEqual(@as(usize, 1), blocks[1].instrs.len);
    try testing.expect(blocks[1].instrs[0].op == .lt);
    try testing.expectEqual(@as(usize, 1), blocks[2].instrs.len);
    try testing.expect(blocks[2].instrs[0].op == .lt);
    try testing.expectEqual(@as(usize, 1), blocks[3].instrs.len);
    const phi = switch (blocks[3].instrs[0].op) {
        .phi => |p| p,
        else => return error.UnexpectedOp,
    };
    try testing.expectEqual(@as(usize, 2), phi.incoming.len);
    try testing.expect(phi.incoming[0].value == blocks[1].instrs[0].results[0]);
    try testing.expect(phi.incoming[1].value == blocks[2].instrs[0].results[0]);
}

test "Pass 8.3 leaves a fully unavailable computation alone" {
    // Neither edge computes `lt %0, %1`: the join's copy is not redundant
    // on any path, so PRE must not insert anything and must leave the
    // computation in place.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    j join
        \\neg:
        \\    j join
        \\join:
        \\    %3: bool = lt %0, %1
        \\    ret %3
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    try testing.expectEqual(@as(usize, 0), blocks[1].instrs.len);
    try testing.expectEqual(@as(usize, 0), blocks[2].instrs.len);
    try testing.expectEqual(@as(usize, 1), blocks[3].instrs.len);
    try testing.expect(blocks[3].instrs[0].op == .lt);
}

test "Pass 8.3 skips a candidate with an operand from a predecessor" {
    // `lt %3, %0`'s operand `%3` is defined in `b1`, which does not
    // dominate the join — hoisting it would reference a value that is not
    // available on the `b2` edge, so the candidate is left alone even
    // though `b1` computes it.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? b1 : b2
        \\b1:
        \\    %3: int32 = add %0, %1
        \\    %4: bool = lt %3, %0
        \\    j join
        \\b2:
        \\    j join
        \\join:
        \\    %5: bool = lt %3, %0
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    try testing.expectEqual(@as(usize, 2), blocks[1].instrs.len);
    try testing.expectEqual(@as(usize, 1), blocks[3].instrs.len);
    try testing.expect(blocks[3].instrs[0].op == .lt);
}

test "Pass 8.3 leaves trapping arithmetic alone" {
    // `div` traps on a zero divisor and on `int32_min / -1` (Runtime §7.2);
    // moving it onto a path that never ran it would change observable
    // behavior, so PRE never hoists it. (Add/sub/mul wrap modulo 2³² and
    // are PRE candidates — see `cfg.opInfo`.)
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    %3: int32 = div %0, %1
        \\    j join
        \\neg:
        \\    j join
        \\join:
        \\    %4: int32 = div %0, %1
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    try testing.expectEqual(@as(usize, 0), blocks[2].instrs.len);
    try testing.expectEqual(@as(usize, 1), blocks[3].instrs.len);
    try testing.expect(blocks[3].instrs[0].op == .div);
}

test "Pass 8.3 leaves side-effecting ops alone" {
    // Two syntactically identical syscalls are not interchangeable: the
    // call may read mutable state or produce output.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(x: int32, c: bool) -> int32 {
        \\entry:
        \\    br %1 ? pos : neg
        \\pos:
        \\    %2: int32 = syscall builtin#print, %0
        \\    j join
        \\neg:
        \\    j join
        \\join:
        \\    %3: int32 = syscall builtin#print, %0
        \\    ret %3
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    try testing.expectEqual(@as(usize, 0), blocks[2].instrs.len);
    try testing.expectEqual(@as(usize, 1), blocks[3].instrs.len);
    try testing.expect(blocks[3].instrs[0].op == .syscall);
}

test "Pass 8.3 hoists unary non-trapping ops" {
    // `not_` (and the type test `type_is`) never trap, so both are valid
    // PRE candidates; the unary operand is available at the join head.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(c: bool, c2: bool, v: any) -> bool {
        \\entry:
        \\    br %0 ? npos : nneg
        \\npos:
        \\    %3: bool = not %1
        \\    j njoin
        \\nneg:
        \\    j njoin
        \\njoin:
        \\    %4: bool = not %1
        \\    br %4 ? tpos : tneg
        \\tpos:
        \\    %5: bool = type_is %2, int32
        \\    j tjoin
        \\tneg:
        \\    j tjoin
        \\tjoin:
        \\    %6: bool = type_is %2, int32
        \\    ret %6
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    // njoin: the `not_` becomes a phi; its value on the missing edge is
    // inserted at the end of `nneg`.
    const njoin = blocks[3];
    try testing.expectEqual(@as(usize, 1), njoin.instrs.len);
    const nphi = switch (njoin.instrs[0].op) {
        .phi => |p| p,
        else => return error.UnexpectedOp,
    };
    try testing.expectEqual(@as(usize, 2), nphi.incoming.len);
    try testing.expect(nphi.incoming[0].value == blocks[1].instrs[0].results[0]);
    try testing.expect(nphi.incoming[1].value == blocks[2].instrs[0].results[0]);

    // tjoin: the `type_is` becomes a phi too.
    const tjoin = blocks[6];
    try testing.expectEqual(@as(usize, 1), tjoin.instrs.len);
    const tphi = switch (tjoin.instrs[0].op) {
        .phi => |p| p,
        else => return error.UnexpectedOp,
    };
    try testing.expectEqual(@as(usize, 2), tphi.incoming.len);
    try testing.expect(tphi.incoming[0].value == blocks[4].instrs[0].results[0]);
    try testing.expect(tphi.incoming[1].value == blocks[5].instrs[0].results[0]);
}

test "Pass 8.3 handles a self-loop back edge" {
    // `body` reaches itself, so one incoming edge is the loop back edge.
    // The computation on the entry edge is reused; on the back edge a copy
    // is inserted at the end of `body` (which dominates nothing — the
    // exclusion of the candidate itself makes the loop unavailable).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(n: int32) -> int32 {
        \\entry:
        \\    %1: bool = lt %0, %0
        \\    br %1 ? body : exit
        \\body:
        \\    %2: bool = lt %0, %0
        \\    br %2 ? body : exit
        \\exit:
        \\    %3: int32 = const 0
        \\    ret %3
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    const body = blocks[1];
    try testing.expectEqual(@as(usize, 2), body.instrs.len);
    const phi = switch (body.instrs[0].op) {
        .phi => |p| p,
        else => return error.UnexpectedOp,
    };
    try testing.expectEqual(@as(usize, 2), phi.incoming.len);
    try testing.expect(phi.incoming[0].pred == blocks[0]);
    try testing.expect(phi.incoming[0].value == blocks[0].instrs[0].results[0]);
    try testing.expect(phi.incoming[1].pred == body);
    try testing.expect(body.instrs[1].op == .lt);
    try testing.expect(phi.incoming[1].value == body.instrs[1].results[0]);
}

test "Pass 8.3 optimized AIR round-trips through the standalone cfg parser" {
    // PRE adds values and phis, so the pass renumbers the function's values
    // in text order; the printed text must still re-parse and re-print
    // identically (air.md §13).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    j join
        \\neg:
        \\    %3: bool = lt %0, %1
        \\    j join
        \\join:
        \\    %4: bool = lt %0, %1
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const f = t.program.funcs[0];
    try testing.expectEqual(f.values[f.values.len - 1].id + 1, @as(u32, @intCast(f.values.len)));

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.3 lower.optimize on a full program round-trips through the standalone cfg parser" {
    // The if-statement's continuation recomputes `a < b`, which the then
    // arm already computed and the else arm did not: the compiled AIR is
    // genuinely partially redundant and the whole optimize pipeline
    // (fold, cse, pre) must still round-trip.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(a: int32, b: int32, c: bool) -> bool {
            \\    if (c) {
            \\        a < b
            \\    } else {
            \\        false
            \\    };
            \\    a < b
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.optimize(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// On-the-fly copy elision at construction (optimizer.md, On-the-fly optimizations) — the frontend
// has no separate copy-propagation pass (braun13cc.pdf §3.1): a `move` of a
// Copy value lowers directly to the value itself (a copy of a
// Copy value is the value, air.md §5.4), so no `copy` instructions
// reach the AIR from the frontend.
// ---------------------------------------------------------------------------

test "frontend emits no copies for Copy moves, keeps move_ for unique" {
    // `consume(move a)` on an int32 is the value itself; `move` of an
    // unique owner still emits `move_` (ownership transfer, air.md §5.4).
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\fn consume(move n: int32) -> void {}
            \\fn take(move file: File) -> void {}
            \\fn main() -> void {
            \\    let a = 5;
            \\    consume(move a);
            \\    let f = File{ fd: 1, path: "p" };
            \\    take(move f);
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "copy") == null);
    try testing.expect(std.mem.indexOf(u8, out, " = move %") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(out);
    const out2 = try irText(&reparsed);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings(out, out2);
}

// Pass 8.3 — dead-block elimination (optimizer.md, Pass 8.3)
// ---------------------------------------------------------------------------

test "Pass 8.5 removes a block unreachable from the entry" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32) -> int32 {
        \\entry:
        \\    ret %0
        \\dead:
        \\    %1: int32 = add %0, %0
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.deadBlock(&t.program, t.arena.allocator());

    const f = t.program.funcs[0];
    try testing.expectEqual(@as(usize, 1), f.blocks.len);
    try testing.expect(f.blocks[0] == f.entry);
    try testing.expectEqual(@as(usize, 0), f.entry.instrs.len);
    try testing.expect(f.entry.terminator.ret.? == f.values[0]);
    try testing.expectEqual(@as(usize, 1), f.values.len);
}

test "Pass 8.5 prunes phi incoming lists and predecessor sets" {
    // `dead` feeds the join phi on one incoming edge but nothing branches
    // to it; removing it must drop that phi entry and the predecessor,
    // keeping incoming order aligned with the survivors (air.md §4.3).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    j live
        \\live:
        \\    %2: int32 = add %0, %1
        \\    j join
        \\dead:
        \\    %3: int32 = const 42
        \\    j join
        \\join:
        \\    %4: int32 = phi [%2, live], [%3, dead]
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.deadBlock(&t.program, t.arena.allocator());

    const f = t.program.funcs[0];
    const blocks = f.blocks;
    try testing.expectEqual(@as(usize, 3), blocks.len);
    const join = blocks[2];
    try testing.expectEqual(@as(usize, 1), join.preds.len);
    try testing.expect(join.preds[0] == blocks[1]);
    const phi = switch (join.instrs[0].op) {
        .phi => |p| p,
        else => return error.UnexpectedOp,
    };
    try testing.expectEqual(@as(usize, 1), phi.incoming.len);
    try testing.expect(phi.incoming[0].pred == blocks[1]);
    try testing.expect(phi.incoming[0].value == blocks[1].instrs[0].results[0]);
    try testing.expect(join.terminator.ret.? == join.instrs[0].results[0]);
}

test "Pass 8.5 removes a whole unreachable chain" {
    // `dead` branches to `deeper`, which nothing else reaches; both are
    // removed even though `deeper` is not directly referenced by `entry`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32) -> int32 {
        \\entry:
        \\    j live
        \\live:
        \\    ret %0
        \\dead:
        \\    j deeper
        \\deeper:
        \\    %1: int32 = add %0, %0
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.deadBlock(&t.program, t.arena.allocator());

    const f = t.program.funcs[0];
    try testing.expectEqual(@as(usize, 2), f.blocks.len);
    try testing.expect(f.blocks[0] == f.entry);
    try testing.expect(f.blocks[1] == f.blocks[0].terminator.j);
    try testing.expectEqual(@as(usize, 1), f.values.len);
}

test "Pass 8.5 leaves a reachable diamond intact" {
    // Both branches are reachable from the entry, so nothing is removed.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    %3: int32 = add %0, %1
        \\    j join
        \\neg:
        \\    %4: int32 = sub %0, %1
        \\    j join
        \\join:
        \\    %5: int32 = phi [%3, pos], [%4, neg]
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.deadBlock(&t.program, t.arena.allocator());

    const f = t.program.funcs[0];
    try testing.expectEqual(@as(usize, 4), f.blocks.len);
    try testing.expectEqual(@as(usize, 2), f.blocks[3].preds.len);
    try testing.expectEqual(@as(usize, 2), f.blocks[3].instrs[0].op.phi.incoming.len);
    try testing.expectEqual(@as(usize, 6), f.values.len);
}

test "Pass 8.5 optimized AIR round-trips through the standalone cfg parser" {
    // Removing blocks removes their values, so the pass renumbers the
    // survivors in text order; the printed text must still re-parse and
    // re-print identically (air.md §13), with the dead block gone.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    j live
        \\live:
        \\    %2: int32 = add %0, %1
        \\    j join
        \\dead:
        \\    %3: int32 = const 42
        \\    j join
        \\join:
        \\    %4: int32 = phi [%2, live], [%3, dead]
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.deadBlock(&t.program, t.arena.allocator());

    const f = t.program.funcs[0];
    try testing.expectEqual(f.values[f.values.len - 1].id + 1, @as(u32, @intCast(f.values.len)));

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "dead") == null);
    try testing.expect(std.mem.indexOf(u8, text, "phi [%2, live]") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.5 lower.optimize on a program with a dead block round-trips" {
    // The whole pipeline (fold, cse, pre, copyProp, deadBlock) must keep
    // the printed AIR round-tripping through the standalone parser.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(a: int32, b: int32) -> int32 {
            \\    if (a < b) {
            \\        a
            \\    } else {
            \\        b
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.optimize(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.8 if-conversion turns a pure select diamond branchless" {
    // `sign`: `if (value >= 0) { 1 } else { -1 }` — pure const arms and
    // a join phi. The diamond collapses into one `select` (the LLIR
    // image: `copy cond_reg` + `cmov`), the phis and the dead arms are
    // eliminated, and the cond block falls through to the join.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\fn sign(value: int32) -> int32 {
            \\    if (value >= 0) { 1 } else { -1 }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "select ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, out, "br %") == null);
}

test "Pass 8.8 if-conversion leaves every hoisted instruction in one block" {
    // A nested `or`/`and` over inlined calls: if-conversion hoists the
    // inner diamond's arm instructions into its cond block. Regression:
    // the arms' own instruction lists were never emptied, so each hoisted
    // instruction lived in two blocks; the validator's defBlock scan
    // (first match over f.blocks) attributed the def to the arm when the
    // arm preceded the cond block in creation order, and the conversion
    // was rejected as "not dominated" (optimizer invariant violation) —
    // which stsmith hit with short-circuit `and`/`or` statements.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f1() -> int64 {
            \\    ((-250826282122) >> ((-196082829395) >> (-25495947749))) + (142791762226)
            \\}
            \\fn f4() -> uint64 {
            \\    ((257500157809) & (249363292281)) * ((123056492540) & (165846480652))
            \\}
            \\fn main() -> void {
            \\    let v1: uint32 = 9;
            \\    let v3: uint64 = 12;
            \\    let v45: int64 = f1();
            \\    let v49: bool = (((v45) << (v45)) > (v45)) or ((((f4()) >> (((v45 as uint64)) >> ((v3) << ((v3) & (f4()))))) > (v3)) and (((v1) + ((v45 as uint32))) >= ((v1) & (v1))));
            \\    builtin.assert(v49 == true, "x");
            \\}
        },
    });
    defer c.deinit();

    // The conversion completes (the compile validated after if-conversion),
    // and the short-circuit diamond became a branchless select.
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "select ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "select %") != null);
}

test "Pass 8.8 if-conversion absorbs short-circuit and/or second operands" {
    // `a > 0 and b > 0`: the short-circuit's else arm is `false`, the
    // then arm is the pure second comparison — the whole `and` becomes
    // one branchless select.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\fn both(a: int32, b: int32) -> bool { a > 0 and b > 0 }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "select ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, out, "br %") == null);
}

test "Pass 8.5 keeps diamonds with impure arms branchy" {
    // A side-effecting call in the then arm must stay on its path —
    // if-conversion must not hoist it. The diamond is not converted.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f(c: bool, a: int32, b: int32) -> int32 {
            \\    if (c) { builtin.print(builtin.str(a)); a } else { b }
            \\}
            \\fn main() -> void { let _ = f(true, 1, 2); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "select ") == null);
    try testing.expect(std.mem.indexOf(u8, out, "br %") != null);
}

// ---------------------------------------------------------------------------
// Pass 8.9 — optional optimizer fixpoint iteration (optimizer.md, §8.9)
// ---------------------------------------------------------------------------

// Compile-time regression guard for the aggressive loop cap: the
// demonstrating test below needs a second iteration to fire, so a cap
// below 2 would silently turn aggressive mode into the single pass and
// the test would stop demonstrating. The check fails at compile time,
// not at runtime.
comptime {
    if (lower.aggressive_max_iters < 2) {
        @compileError("optimizer aggressive_max_iters must be >= 2 (the demonstrating fixpoint test needs a second iteration)");
    }
}

test "Pass 8.3 PRE survives block-id gaps left by a prior dead-block pass" {
    // The aggressive fixpoint loop re-runs PRE (and every other pass)
    // over a program whose previous iteration's dead-block elimination
    // removed blocks without renumbering — block ids are creation
    // indices, not part of the text form (air.md §13), so a removed
    // block leaves a gap. PRE's dominator matrix must be sized by the
    // largest id, not the block count, or the re-run indexes out of
    // bounds (the single-pass driver never re-runs PRE on a mutated
    // program, which is why the bug was latent).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    j join
        \\neg:
        \\    %3: bool = lt %0, %1
        \\    j join
        \\dead:
        \\    %4: bool = lt %0, %1
        \\    j join
        \\join:
        \\    %5: bool = lt %0, %1
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.deadBlock(&t.program, t.arena.allocator());
    // `dead` is gone but its id slot is not reclaimed: the survivors are
    // ids 0, 1, 2, 4 — blocks.len (4) under-counts the live id space.
    try testing.expectEqual(@as(usize, 4), t.program.funcs[0].blocks.len);
    try lower.pre(&t.program, t.arena.allocator());
    // PRE still rewrites the join's partially redundant comparison (only
    // the `neg` edge computes it) into a join phi.
    const join = t.program.funcs[0].blocks[t.program.funcs[0].blocks.len - 1];
    try testing.expect(join.instrs[0].op == .phi);
}

test "Pass 8.9 a second iteration enables a further simplification" {
    // The inliner splices make/show/consume into `main`, and the splice
    // continuations form a forwarding chain. Iteration 1's jump threading
    // collapses most of it but leaves the chain's tail blocks behind —
    // the pass's own doc (cfg_jump_thread.zig): "a chain collapsed in one
    // pass may leave one forwarding block behind, which a later
    // optimization invocation removes". The aggressive loop's second
    // iteration re-runs threading and removes both leftovers, so the
    // edges jump straight to their targets and the blocks are gone. This
    // is the plan's "tail-call enabling a dead-block removal" family: a
    // late-pass leftover that only the next iteration's dead/forwarding
    // elimination reaches.
    const src = &.{
        .{
            "app",
            \\struct Token { id: int32; }
            \\fn make(id: int32) -> Token {
            \\    Token { id: id }
            \\}
            \\fn show(borrow t: Token) -> int32 {
            \\    t.id
            \\}
            \\fn consume(move t: Token) -> void {
            \\    drop t;
            \\}
            \\fn main() -> void {
            \\    let a = make(7);
            \\    let n = show(a);
            \\    consume(move a);
            \\}
            ,
        },
    };

    // Default single pass: the chain tail blocks survive as empty
    // forwarding blocks (`inline_join_1:` / `inline_join_2:`), each a
    // bare `j` to the next segment.
    var def = try compileOpt("app", src);
    defer def.deinit();
    const def_text = try irText(&def.program.?);
    defer testing.allocator.free(def_text);
    try testing.expect(std.mem.indexOf(u8, def_text, "inline_join_1:\n        j inline_join") != null);
    try testing.expect(std.mem.indexOf(u8, def_text, "inline_join_2:\n        j entry_2") != null);

    // Aggressive mode (bounded fixpoint): the second iteration's jump
    // threading removes both leftovers — the forwarding blocks are gone
    // and the edges go straight to their ultimate targets. The output is
    // strictly smaller.
    var agg = try compileAggressive("app", src);
    defer agg.deinit();
    const agg_text = try irText(&agg.program.?);
    defer testing.allocator.free(agg_text);
    try testing.expect(std.mem.indexOf(u8, agg_text, "inline_join_1:\n        j inline_join") == null);
    try testing.expect(std.mem.indexOf(u8, agg_text, "inline_join_2:\n        j entry_2") == null);
    try testing.expect(agg_text.len < def_text.len);
    try testing.expect(countBlocks(&agg.program.?) < countBlocks(&def.program.?));

    // The aggressive output is stable at the fixpoint: the same raw
    // program optimized with two iterations and with the full cap
    // produces the same text, so the loop stopped on "no change", not
    // on the cap.
    var agg_cap = try compileText("app", src);
    defer agg_cap.deinit();
    var agg_cap_prog = agg_cap.program.?;
    try lower.optimizeAggressive(&agg_cap_prog, agg_cap.arena.allocator(), lower.aggressive_max_iters);
    const agg_cap_text = try irText(&agg_cap_prog);
    defer testing.allocator.free(agg_cap_text);
    var agg_two = try compileText("app", src);
    defer agg_two.deinit();
    var agg_two_prog = agg_two.program.?;
    try lower.optimizeAggressive(&agg_two_prog, agg_two.arena.allocator(), 2);
    const agg_two_text = try irText(&agg_two_prog);
    defer testing.allocator.free(agg_two_text);
    try testing.expectEqualStrings(agg_two_text, agg_cap_text);
    // The two-iteration result is the full-pipeline aggressive output
    // (drop-lowered) modulo the drop expansion itself: the leftover
    // forwarding blocks are gone in both.
    try testing.expect(std.mem.indexOf(u8, agg_two_text, "inline_join_1:") == null);
    try testing.expect(std.mem.indexOf(u8, agg_two_text, "inline_join_2:") == null);

    // Default output is deterministic (two fresh compiles, byte-identical)
    // and the aggressive output re-parses to itself (air.md §13).
    var def2 = try compileOpt("app", src);
    defer def2.deinit();
    const def2_text = try irText(&def2.program.?);
    defer testing.allocator.free(def2_text);
    try testing.expectEqualStrings(def_text, def2_text);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(agg_text);
    const retext = try irText(&reparsed);
    defer testing.allocator.free(retext);
    try testing.expectEqualStrings(agg_text, retext);
}

test "Pass 8.9 aggressive mode is never worse than the default on the corpus" {
    // The whole existing optimizer corpus (the same examples the Pass 8.9
    // harness in frontend_cfg_passes_tests.zig measures): aggressive
    // output must be ≤ the default single-pass output in text bytes,
    // non-phi instructions, and blocks. The default is byte-identical
    // across two fresh compiles (determinism guard for "default output
    // byte-identical to today").
    const corpus = [_][]const u8{
        "examples/basics.st",
        "examples/fib.st",
        "examples/functions.st",
        "examples/structs.st",
        "examples/any.st",
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
    for (corpus) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(src);
        const texts = &.{.{ "app", src }};

        var def = try compileOpt("app", texts);
        defer def.deinit();
        const def_text = try irText(&def.program.?);
        defer testing.allocator.free(def_text);

        var def2 = try compileOpt("app", texts);
        defer def2.deinit();
        const def2_text = try irText(&def2.program.?);
        defer testing.allocator.free(def2_text);
        try testing.expectEqualStrings(def_text, def2_text);

        var agg = try compileAggressive("app", texts);
        defer agg.deinit();
        const agg_text = try irText(&agg.program.?);
        defer testing.allocator.free(agg_text);
        try testing.expect(agg_text.len <= def_text.len);
        try testing.expect(countNonPhi(&agg.program.?) <= countNonPhi(&def.program.?));
        try testing.expect(countBlocks(&agg.program.?) <= countBlocks(&def.program.?));

        var p = cfg.Parser.init(testing.allocator);
        defer p.deinit();
        const reparsed = try p.parse(agg_text);
        const retext = try irText(&reparsed);
        defer testing.allocator.free(retext);
        try testing.expectEqualStrings(agg_text, retext);
    }
}

/// The corpus measurements (optimizer.md, §8.9): instructions, non-phi
/// instructions, and blocks across the program.
fn countNonPhi(program: *const cfg.IrProgram) usize {
    var n: usize = 0;
    for (program.funcs) |f| {
        for (f.blocks) |b| {
            for (b.instrs) |instr| {
                if (instr.op != .phi) n += 1;
            }
        }
    }
    return n;
}

fn countBlocks(program: *const cfg.IrProgram) usize {
    var n: usize = 0;
    for (program.funcs) |f| n += f.blocks.len;
    return n;
}
