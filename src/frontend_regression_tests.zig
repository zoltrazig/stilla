//! Test file: `frontend regression` — the P0/P1 regression suite:
//! join-phi ownership, short-circuit never operands, op emission, and
//! ownership-transfer lowering (nested joins, nested short-circuit,
//! all-trap branches). Split out of the former
//! `src/frontend_lowering_tests.zig`.
//!
//! Shared helpers (compilation drivers, fixture reader, and string/CFG
//! lookups) are aliased from `src/frontend_test_support.zig` below. The
//! whole-program fixtures live in `probes/cases/*.st` and are read at test
//! time rather than constructed inline.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const funcBody = helpers.funcBody;

// ---------------------------------------------------------------------------
// P0/P1 regressions: join-phi ownership, short-circuit never operands, op
// emission, and ownership-transfer lowering.
// ---------------------------------------------------------------------------

test "frontend join phis own their unique inputs (if, return case)" {
    // air.md §6.3-§6.4: an unique value listed as a phi input is *not*
    // destroyed at the end of its producing block; the phi result is the
    // single owner. A regression: the branch values %2/%4 were dropped in
    // the join block and then the phi result %5 was returned — a triple
    // destruction / use-after-return. Now the choose body must contain no
    // drop at all: inputs consumed by the phi, result transferred by ret.
    const src = try helpers.probeSource("probes/cases", "join_phi_if");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.choose");
    try testing.expect(std.mem.indexOf(u8, body, "phi") != null);
    try testing.expect(std.mem.indexOf(u8, body, "drop ") == null);
}

test "frontend join phis own their unique inputs (match, return case)" {
    // Same rule through a union match: the arm values feed the join phi
    // and the scrutinee is the only value dropped (it was not moved). The
    // phi result is returned, and no phi input is destroyed.
    const src = try helpers.probeSource("probes/cases", "join_phi_match");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.pick");
    try testing.expect(std.mem.indexOf(u8, body, "phi") != null);
    // v1: no cleanup tokens. The scrutinee (%0) is destroyed at scope
    // end; the phi inputs are transferred by the join, never dropped.
    try testing.expect(std.mem.indexOf(u8, body, " drop %2") == null);
    try testing.expect(std.mem.indexOf(u8, body, " drop %4") == null);
    try testing.expect(std.mem.indexOf(u8, body, " drop %5") == null);
    try testing.expect(std.mem.indexOf(u8, body, "cleanup_drop") == null);
    try testing.expect(std.mem.indexOf(u8, body, " drop %0") != null);
}

test "frontend join phis own their unique inputs (let case: one drop)" {
    // `let f = if (c) { … } else { … }`: the phi result is the owned
    // binding, so it receives exactly one scope-end drop; the phi inputs
    // (%2, %4) are consumed by the join and must not be dropped.
    const src = try helpers.probeSource("probes/cases", "join_phi_let");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.main");
    // Exactly one drop (the phi result); none of the phi inputs.
    var drops: usize = 0;
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, " drop %") != null) drops += 1;
    }
    try testing.expectEqual(@as(usize, 1), drops);
    try testing.expect(std.mem.indexOf(u8, body, " drop %2") == null);
    try testing.expect(std.mem.indexOf(u8, body, " drop %4") == null);
}

test "frontend lowers a and die() and a or die() without a crash" {
    // A never right operand traps inside the rhs block: the rhs side then
    // contributes no phi input and no edge to the join, and the join still
    // receives the const arm. Regression: the compiler segfaulted on an
    // unterminated rhs-eval block (exit 134).
    const src = try helpers.probeSource("probes/cases", "short_circuit_and_or_die");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // The rhs block ends in trap and the join phi carries only the const
    // arm (a single incoming value from the false_/true_ block).
    const and_body = funcBody(out, "func @app.f");
    try testing.expect(std.mem.indexOf(u8, and_body, "trap") != null);
    try testing.expect(std.mem.indexOf(u8, and_body, "phi") != null);
    try testing.expect(std.mem.indexOf(u8, and_body, "const false") != null);
    const or_body = funcBody(out, "func @app.g");
    try testing.expect(std.mem.indexOf(u8, or_body, "trap") != null);
    try testing.expect(std.mem.indexOf(u8, or_body, "phi") != null);
    try testing.expect(std.mem.indexOf(u8, or_body, "const true") != null);
}

test "frontend keeps never-lhs short-circuit operands trapping" {
    // `die() and a` / `die() or a`: the left operand never returns, so the
    // whole expression is unreachable and the entry block ends in trap —
    // no rhs block, no join, no phi.
    const src = try helpers.probeSource("probes/cases", "short_circuit_never_lhs");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const and_body = funcBody(out, "func @app.f");
    try testing.expect(std.mem.indexOf(u8, and_body, "trap") != null);
    try testing.expect(std.mem.indexOf(u8, and_body, "phi") == null);
    const or_body = funcBody(out, "func @app.g");
    try testing.expect(std.mem.indexOf(u8, or_body, "trap") != null);
    try testing.expect(std.mem.indexOf(u8, or_body, "phi") == null);
}

test "frontend lowers nested short-circuit joins" {
    // A phi input's predecessor is the block that *actually* branches to
    // the join. For a nested rhs (`a and (b and c)`, `a and (b or die())`)
    // that is the inner join block, not the rhs entry block. Regression:
    // the outer phi listed the branch-entry block as pred, so the join's
    // in-edges (built in block-id order, air.md §4.3) never matched and the
    // compiler rejected the program with "phi incoming order does not
    // match predecessors" (and the never variants segfaulted).
    const src = try helpers.probeSource("probes/cases", "nested_short_circuit_joins");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const f_body = funcBody(out, "func @app.f");
    // The outer join (join_1) receives a phi input from the inner join
    // (join) — the pred is the bare block named `join`, never the rhs
    // entry block. `, join]` matches `phi [%v, join]` only; `, join_1]`
    // does not contain it.
    try testing.expect(std.mem.indexOf(u8, f_body, ", join]") != null);
    try testing.expect(std.mem.indexOf(u8, f_body, "phi") != null);
    const g_body = funcBody(out, "func @app.g");
    try testing.expect(std.mem.indexOf(u8, g_body, ", join]") != null);
    try testing.expect(std.mem.indexOf(u8, g_body, "trap") != null);
}

test "frontend lowers nested if joins" {
    // Same phi-pred rule for if/else: when a branch body is itself an
    // `if`, the join receives its phi input from the inner join block.
    const src = try helpers.probeSource("probes/cases", "nested_if_joins");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.pick");
    try testing.expect(std.mem.indexOf(u8, body, ", join_1]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "phi") != null);
}

test "frontend lowers nested match arm joins" {
    // Same phi-pred rule for match arms: when an arm body is itself an
    // `if`, the match join receives its phi input from that arm's inner
    // join block.
    const src = try helpers.probeSource("probes/cases", "nested_match_joins");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.pick");
    // The match join's phi inputs come from the two inner join blocks.
    try testing.expect(std.mem.indexOf(u8, body, ", join_1]") != null);
    try testing.expect(std.mem.indexOf(u8, body, ", join_2]") != null);
}

test "frontend emits unary and comparison ops" {
    // Core §16.3 / air.md §5: neg, not, and the six comparisons are
    // instructions in the AIR; the frontend emits them but no test pinned
    // the opcodes before.
    const src = try helpers.probeSource("probes/cases", "unary_comparison_ops");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = neg %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = not %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = lt %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = le %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = gt %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = ge %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = ne %") != null);
}

test "frontend lowers ownership-transfer destructures" {
    // Core §14.6 / air.md §5.4: a consuming destructure is one atomic
    // multi-result op per kind — `unpack_variant` (tag-carrying),
    // `unpack_struct`, `unpack_tuple`, `split_list` — and a non-consuming
    // list pattern's rest binds a borrowed `tail` view (Core §14.5).
    const src = try helpers.probeSource("probes/cases", "ownership_destructures");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = unpack_variant %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = unpack_struct %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = unpack_tuple %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = tail %") != null);
}

test "frontend lowers nested all-trap branches without a crash" {
    // Regression (round 3): when every branch/arm traps, the join is
    // unreachable. It used to be removed by popping "the last block",
    // which is wrong once a nested trapped branch created blocks after
    // the join — the join survived with an undefined terminator and
    // finishFunc aborted (index out of bounds). The join and the trapped
    // subtree are now kept as trap-terminated dead blocks.
    const src = try helpers.probeSource("probes/cases", "nested_all_trap_branches");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    const f_body = funcBody(out, "func @app.f");
    try testing.expect(std.mem.indexOf(u8, f_body, "trap") != null);
    // The dead joins are trap-terminated: `join:` / `join_1:` end in trap.
    try testing.expect(std.mem.indexOf(u8, f_body, "join:\n        trap") != null);
}
