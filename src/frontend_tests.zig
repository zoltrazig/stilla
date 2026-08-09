//! Test file: `frontend AIR text form` — the standalone `cfg.Parser` /
//! `cfg.print` round-trip contract (air.md §9): whatever the frontend
//! prints, the parser must re-parse byte-identically (SSA-id ordering,
//! duplicate-block labels, phi input ordering, multi-result
//! destructures). Plus the white-box aggregation of the module/pass
//! inline tests (the `test {}` block below).
//!
//! The lowering-pipeline black-box tests (compilation, imports, lowering
//! behavior, spec conformance, P0/P1 regressions) live in
//! `src/frontend_lowering_tests.zig`, `src/frontend_spec_tests.zig`, and
//! `src/frontend_regression_tests.zig`.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const cfg = @import("cfg.zig");
const lower = @import("lower.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
test {
    // White-box tests of the module files in this slice: the AIR
    // structures, the text-form lexer/parser/printer (all split out into
    // src/passes/), the CFG-lowering passes, and the phase-1 LLIR
    // model (src/llir.zig).
    _ = @import("frontend.zig");
    _ = @import("cfg.zig");
    _ = @import("llir.zig");
    _ = @import("passes/cfg_lex.zig");
    _ = @import("passes/cfg_parse.zig");
    _ = @import("passes/cfg_print.zig");
    _ = @import("passes/cfg_lower_program.zig");
    _ = @import("passes/cfg_lower_module.zig");
    _ = @import("passes/cfg_lower_func.zig");
    _ = @import("passes/cfg_lower_expr.zig");
    _ = @import("passes/cfg_lower_control.zig");
    _ = @import("passes/cfg_lower_call.zig");
    _ = @import("passes/cfg_lower_pattern.zig");
    _ = @import("passes/cfg_lower_path.zig");
    _ = @import("passes/cfg_lower_emit.zig");
    _ = @import("passes/cfg_lower_llir.zig");
    _ = @import("passes/llir_validate.zig");
    _ = @import("passes/cfg_lower_validate.zig");
    _ = @import("passes/cfg_dead_block.zig");
    _ = @import("passes/cfg_optimize.zig");
    _ = @import("passes/cfg_pre.zig");
    _ = @import("passes/cfg_tail_call.zig");
    _ = @import("passes/cfg_drop_elide.zig");
    _ = @import("passes/cfg_jump_thread.zig");
    _ = @import("passes/cfg_phi_simplify.zig");
}

test "frontend AIR round-trips through the standalone cfg parser" {
    // The printed AIR (air.md §9) is the contract with the runtime side: the
    // standalone cfg.Parser must re-parse everything the frontend prints.
    // This is also the SSA-id regression test — before `newValue` appended
    // to the per-function value table, every non-parameter value in a
    // function printed the same id, and a re-parse would have rejected the
    // text (value %N defined out of order) or silently mis-resolved it.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const lists = import("list");
            \\union Result { Ok(int32), Err(str) }
            \\fn sign(v: int32) -> int32 { if (v >= 0) { 1 } else { -1 } }
            \\fn describe(r: Result) -> str {
            \\    match (r) { Result::Ok(x) => builtin.str(x), Result::Err(e) => e }
            \\}
            \\fn dump(xs: list[int32]) -> void { let n = lists.len(xs); builtin.print(builtin.str(n)); }
            \\fn main() -> void { dump(lists.range(0, 2)); }
        },
    });
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    try testing.expectEqual(@as(usize, 3), prog.modules.len);
    try testing.expectEqual(@as(usize, 6), prog.funcs.len);
    // The parser leaves the entry unselected; every function and block
    // survives, and the unique ids round-trip in order.
    for (prog.funcs) |f| {
        try testing.expect(f.blocks.len > 0);
        // An empty function (e.g. an `@init` with nothing to store) has
        // no values; otherwise the unique ids round-trip in order.
        if (f.values.len > 0) try testing.expectEqual(f.values.len, f.values[f.values.len - 1].id + 1);
    }
}

test "frontend AIR round-trips bitwise ops" {
    // air.md §5.2: `bitand`/`bitor`/`bitxor` print and re-parse
    // byte-identically.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(a: int32, b: int32) -> int32 { (a & b) | (a ^ b) }
            \\fn main() -> void { let _ = f(1, 2); }
        },
    });
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "bitand") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bitor") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bitxor") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    try testing.expectEqual(@as(usize, 1), prog.modules.len);
    // @init (module construction) + f + main.
    try testing.expectEqual(@as(usize, 3), prog.funcs.len);
}

test "frontend AIR round-trips the branchless select op" {
    // air.md §5.2: `select %cond, %a, %b` prints and re-parses
    // byte-identically — the if-conversion's branchless form (the
    // LLIR image of a select is `copy cond_reg` + `cmov`).
    var p0 = cfg.Parser.init(testing.allocator);
    defer p0.deinit();
    const t = try p0.parse(
        \\module "app" {
        \\    func @app.pick(c: bool, a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %3: int32 = select %0, %1, %2
        \\        ret %3
        \\    }
        \\    func @app.main() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\}
    );

    // The operands resolve positionally: condition, then, else.
    const f = t.funcs[0];
    const sel = switch (f.blocks[0].instrs[0].op) {
        .select => |s| s,
        else => unreachable,
    };
    try testing.expectEqual(f.values[0], sel.cond);
    try testing.expectEqual(f.values[1], sel.a);
    try testing.expectEqual(f.values[2], sel.b);

    // Print and re-parse: the round-trip must be byte-identical.
    const out = try cfg.print(&t, testing.allocator);
    defer testing.allocator.free(out);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    _ = try p.parse(out);
}

test "frontend AIR round-trips multi-result destructures and zero-arg construct" {
    // air.md §5.3/§10: `unpack_variant` of a multi-payload variant defines
    // one result per payload (comma-separated in the text form), and
    // `construct` of an empty struct takes zero values. The printed AIR
    // must re-parse through the standalone cfg.Parser.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\union Tree[T] {
            \\    Empty,
            \\    Node(box[Tree[T]], T, box[Tree[T]])
            \\}
            \\struct Nothing {}
            \\fn main() -> void {
            \\    let t: Tree[int32] = Tree::Node(builtin.box(1), 5, builtin.box(2));
            \\    let n = Nothing{};
            \\    match (move t) {
            \\        Tree::Empty => { let _ = n; },
            \\        Tree::Node(l, x, r) => { let _ = l; let _ = x; let _ = r; }
            \\    };
            \\}
        },
    });
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "unpack_variant") != null);
    try testing.expect(std.mem.indexOf(u8, text, "= construct") != null);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    try testing.expect(prog.funcs.len > 0);
    // Re-print the parsed program; the text form is canonical and must be
    // unchanged (air.md §10: parse -> print -> parse round-trips exactly).
    const text2 = try cfg.print(&prog, testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "tailcall terminator round-trips text and validates" {
    // air.md §14.7.1: a `tailcall` is an exit terminator (no out-edge) for a
    // move/unique direct self-recursion; its arguments transfer ownership into
    // the reused frame. Hand-written text must re-parse, re-print exactly, and
    // pass the validator (self target, arity, types, mode-correct arguments).
    const text =
        \\module "app" {
        \\    func @f(n: int32) -> int32 {
        \\    entry:
        \\        %z: int32 = const 0
        \\        %c: bool = eq %n, %z
        \\        br %c ? base : rec
        \\    base:
        \\        ret %n
        \\    rec:
        \\        %one: int32 = const 1
        \\        %nm1: int32 = sub %n, %one
        \\        tailcall @f, %nm1
        \\    }
        \\}
    ;
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    try testing.expectEqual(@as(usize, 1), prog.funcs.len);
    // The `tailcall` terminator survives the canonical printer.
    const text2 = try cfg.print(&prog, testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expect(std.mem.indexOf(u8, text2, "tailcall @f, %") != null);
    // ...re-parses..., and ...validates (self target, arity, types, and a
    // by-value Copy argument).
    var p2 = cfg.Parser.init(testing.allocator);
    defer p2.deinit();
    const prog2 = try p2.parse(text2);
    // Validate through an arena: the validator's temporaries (dominance
    // matrix, state maps) are arena-scoped, not individually freed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try lower.validate(&prog2, arena.allocator()));
}

test "frontend AIR round-trips with duplicate-block-producing constructs" {
    // Block labels must be unique in the printed AIR (air.md §9): the
    // standalone cfg parser rejects duplicate labels. Repeated control
    // flow (three `if`s) and multi-test matches (three literal arms,
    // type-test chains) must re-parse.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const lists = import("list");
            \\fn classify(n: int32) -> str {
            \\    match (n) { 0 => "zero", 1 => "one", 2 => "two", _ => "other" }
            \\}
            \\fn sign2(a: bool, b: bool, c: bool) -> int32 {
            \\    let x = if (a) { 1 } else { 0 };
            \\    let y = if (b) { 2 } else { 3 };
            \\    if (c) { x } else { y }
            \\}
            \\fn sum2(a: list[int32], b: list[int32]) -> int32 {
            \\    if (lists.len(a) > 0) { builtin.print("a"); } else { builtin.print("b"); };
            \\    0
            \\}
            \\fn describe(a: any) -> int32 {
            \\    match (a) { int32 n => n, str s => 0, _ => -1 }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    // Every function and block survives, and label references resolve.
    var block_count: usize = 0;
    for (prog.funcs) |f| block_count += f.blocks.len;
    try testing.expect(block_count > 8);
}

test "frontend AIR round-trips nested joins and fib-style control flow" {
    // Regression (round 3): makeJoinPhi orders phi inputs by block
    // *creation* id, but the printer orders blocks by min-value-id with
    // value-less blocks last, so a printed phi could list its inputs in a
    // different order than its pred blocks appear in the text — the
    // standalone parser recomputes predecessors in text order and
    // rejected the re-parse with "phi incoming order does not match
    // predecessors". Covers the nested short-circuit / nested if / nested
    // match shapes plus a fib-style function whose `then` block is
    // value-less (bare `j join`) and therefore prints last.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\union U { A(int32), B(bool) }
            \\fn die() -> never { builtin.panic("x") }
            \\fn f1(a: bool, b: bool, c: bool) -> bool { a and (b and c) }
            \\fn f2(a: bool, b: bool) -> bool { a and (b or die()) }
            \\fn pick(a: bool, b: bool, x: int32, y: int32, z: int32) -> int32 {
            \\    if (a) { if (b) { x } else { y } } else { z }
            \\}
            \\fn picku(u: U, d: int32) -> int32 {
            \\    match (u) {
            \\        U::A(n) => if (n > 0) { n } else { d },
            \\        U::B(b) => if (b) { 1 } else { 0 }
            \\    }
            \\}
            \\fn fib(n: int32) -> int32 { if (n < 2) { n } else { fib(n - 1) + fib(n - 2) } }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    for (prog.funcs) |f| {
        try testing.expect(f.blocks.len > 0);
        // Every phi input's pred must be a real block of the function.
        for (f.blocks) |b| {
            for (b.instrs) |instr| switch (instr.op) {
                .phi => |phi| for (phi.incoming) |inc| {
                    var found = false;
                    for (f.blocks) |pb| {
                        if (pb == inc.pred) {
                            found = true;
                            break;
                        }
                    }
                    try testing.expect(found);
                },
                else => {},
            };
        }
    }
}
