//! Test file: `frontend lowering` — black-box whole-pipeline tests of
//! the frontend lowering pipeline (phase 1 module graph → phase 2 check →
//! phase 3 CFG lowering): whole-program compilation and imports,
//! ownership/move/drop emission, drop hooks and cleanup tokens, type
//! tests and any casts, hostdata bindings, op emission, tailcall
//! emission, stdlib-bundle compilation, and move discipline. The
//! spec-example conformance programs and the P0/P1 regressions were
//! split into `src/frontend_spec_tests.zig` and
//! `src/frontend_regression_tests.zig`.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const lower = @import("lower.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const compileOpt = helpers.compileOpt;
const funcBody = helpers.funcBody;
// ---------------------------------------------------------------------------
// frontend — black-box: whole programs compiled through the pipeline
// (phase 1 module graph → phase 2 check → phase 3 CFG lowering → printer).
// ---------------------------------------------------------------------------

test "frontend compiles a single module to AIR" {
    const src = try helpers.probeSource("probes/cases", "lowering_single_module_to_air");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program.?;
    // Two modules in phase-1 topological order: `app` and the `builtin`
    // stdbundle module it imports, which is loaded like any source module
    // (module-graph.md, Data structures; air.md §11).
    try testing.expectEqual(@as(usize, 2), program.modules.len);
    // app's @init plus its two function definitions; builtin contributes no
    // funcs because its init is null (nothing to evaluate, air.md §11).
    try testing.expectEqual(@as(usize, 3), program.funcs.len);
    try testing.expect(program.entry != null);
    try testing.expectEqualStrings("app.main", program.entry.?.name.text);

    const out = try irText(&program);
    defer testing.allocator.free(out);
    // The module init stores the constant (the only stored const, so
    // slot #0 — member and slot indices are distinct, air.md §7); main
    // loads it and syscalls print.
    try testing.expect(std.mem.indexOf(u8, out, "func @init") != null);
    try testing.expect(std.mem.indexOf(u8, out, "store_member #0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "load_member") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#print") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.add") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.main") != null);
}

test "frontend resolves imports, dependencies first" {
    const calc_src = try helpers.probeSource("probes/cases", "lowering_resolves_imports_calc");
    defer testing.allocator.free(calc_src);
    const use_src = try helpers.probeSource("probes/cases", "lowering_resolves_imports_use");
    defer testing.allocator.free(use_src);
    var c = try compileText("use", &.{ .{ "calc", calc_src }, .{ "use", use_src } });
    defer c.deinit();

    const graph = c.graph.?;
    try testing.expectEqualStrings("calc", graph.modules[0].specifier);
    try testing.expectEqualStrings("use", graph.modules[1].specifier);

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "module \"calc\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "call @calc.add") != null);
    // The imported module value is a static ModuleRef member: it is never
    // stored, so neither module occupies storage and nothing is written
    // by @init (air.md §7).
    try testing.expect(std.mem.indexOf(u8, out, "store_member") == null);
}

test "frontend rejects an import cycle" {
    const a_src = try helpers.probeSource("probes/cases", "lowering_import_cycle_a");
    defer testing.allocator.free(a_src);
    const b_src = try helpers.probeSource("probes/cases", "lowering_import_cycle_b");
    defer testing.allocator.free(b_src);
    var c = try compileText("a", &.{ .{ "a", a_src }, .{ "b", b_src } });
    defer c.deinit();

    try testing.expect(c.graph == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "import cycle") != null);
    // Pass 6.2: the diagnostic names the full cycle, not just one module.
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "a imports b imports a") != null);
    // The cycle diagnostic points at the re-entering import expression, not
    // the module start (regression: it used to be span 0, the entry 1:1).
    try testing.expect(c.diag.?.span.start != 0);
}

test "frontend rejects an unresolved import" {
    const src = try helpers.probeSource("probes/cases", "lowering_unresolved_import");
    defer testing.allocator.free(src);
    var c = try compileText("a", &.{.{ "a", src }});
    defer c.deinit();

    try testing.expect(c.graph == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unresolved import") != null);
    // Regression: the diagnostic used to be reported at span 0 (the entry
    // module's 1:1) instead of the import expression.
    try testing.expect(c.diag.?.span.start != 0);
}

test "frontend collects every independent error in one compile, in order" {
    // The plan's acceptance: `stilla bad.st` with N independent errors
    // reports all N in one run, each span-correct, in source order.
    // Parse errors recover at statement/item boundaries; checker errors
    // continue per module item. Here a parse-error file and a
    // semantic-error file each report every diagnostic.
    {
        const src = try helpers.probeSource("probes/cases", "lowering_collect_errors_parse");
        defer testing.allocator.free(src);
        var c = try compileText("a", &.{.{ "a", src }});
        defer c.deinit();
        try testing.expect(c.program == null);
        try testing.expectEqual(@as(usize, 4), c.diags.len);
        for (c.diags) |d| try testing.expect(std.mem.indexOf(u8, d.message, "expected an expression, found ';'") != null);
        // In source order, each with a real span (not span 0).
        try testing.expect(c.diags[1].span.start > c.diags[0].span.start);
        try testing.expect(c.diags[3].span.start > c.diags[2].span.start);
        try testing.expect(c.diags[0].span.start != 0);
        // The single-diagnostic accessor names the first.
        try testing.expect(c.diag != null);
        try testing.expectEqual(c.diags[0].span.start, c.diag.?.span.start);
    }
    {
        // Checker collection: independent semantic errors across module
        // items all surface (the validate phase runs after a clean
        // annotation pass).
        const src = try helpers.probeSource("probes/cases", "lowering_collect_errors_check");
        defer testing.allocator.free(src);
        var c = try compileText("a", &.{.{ "a", src }});
        defer c.deinit();
        try testing.expect(c.program == null);
        try testing.expectEqual(@as(usize, 4), c.diags.len);
        try testing.expect(std.mem.indexOf(u8, c.diags[0].message, "constant type mismatch") != null);
        try testing.expect(std.mem.indexOf(u8, c.diags[1].message, "constant type mismatch") != null);
        try testing.expect(std.mem.indexOf(u8, c.diags[2].message, "return type mismatch") != null);
        try testing.expect(std.mem.indexOf(u8, c.diags[3].message, "constant type mismatch") != null);
        // In source order.
        try testing.expect(c.diags[1].span.start > c.diags[0].span.start);
        try testing.expect(c.diags[3].span.start > c.diags[2].span.start);
    }
}

test "frontend single-error diagnostics match the pre-collection rendering" {
    // Regression guard: a one-error program renders byte-identically to
    // the first-error-wins behavior — the first diagnostic, with its
    // span, is unchanged by collection.
    const src = try helpers.probeSource("probes/cases", "lowering_single_error_diag");
    defer testing.allocator.free(src);
    var c = try compileText("a", &.{.{ "a", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expectEqual(@as(usize, 1), c.diags.len);
    try testing.expectEqualStrings("expected an expression, found ';'", c.diags[0].message);
    try testing.expectEqual(@as(u32, 13), c.diags[0].span.start);
    try testing.expectEqual(@as(u32, 14), c.diags[0].span.end);
    try testing.expectEqual(c.diags[0].span.start, c.diag.?.span.start);
}

test "frontend rejects an explicit --entry-fn that does not exist" {
    // lowerProgram: an explicitly named entry function that is absent is a
    // diagnostic; the implicit `main` default stays silent for library
    // modules (checked by the other entry tests).
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    const src = try helpers.probeSource("probes/cases", "lowering_missing_entry_fn");
    defer testing.allocator.free(src);
    try source_map.put(testing.allocator, "app", src);
    sources.source = source_map;

    var c = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "nope",
        .entry_fn_explicit = true,
    });
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "entry function 'nope' not found") != null);
}

test "frontend lowers if/else joins and short-circuit and" {
    const src = try helpers.probeSource("probes/cases", "lowering_if_else_joins");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // Conditional branches print in the canonical ternary form
    // `br %c ? then : else` (air.md §9), reusing the `br` mnemonic.
    try testing.expect(std.mem.indexOf(u8, out, " ? ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "phi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "br %") != null);
    // The `and` short-circuit diamond (lowerAnd) creates a `false_` block
    // for the left-operand-is-false exit; the if/else lowering above only
    // ever names blocks `then`/`else`/`join`, so this pins that `a and b`
    // itself lowers to a short-circuit branch (a regression to a plain
    // eager `and` would drop the `false_` block).
    try testing.expect(std.mem.indexOf(u8, out, "false_") != null);
}

test "frontend lowers a union match to a switch" {
    const src = try helpers.probeSource("probes/cases", "lowering_union_match_switch");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_tag") != null);
    try testing.expect(std.mem.indexOf(u8, out, "switch") != null);
    try testing.expect(std.mem.indexOf(u8, out, "read_payload") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#str") != null);
}

test "frontend lowers ownership: move, borrow, drop" {
    const src = try helpers.probeSource("probes/cases", "lowering_ownership_move_borrow_drop");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        // Surface the frontend diagnostic instead of crashing on the
        // unwrap when the source fails to frontend.compile.
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    // An unique owner is moved before a move-param call; the borrow calls
    // pass it through unchanged.
    try testing.expect(std.mem.indexOf(u8, out, "move ") != null);
    // The drop hook makes File unique, so `consume(move a)` emits a real
    // `move` instruction (`%x: File = move %y`) — not merely the
    // `consume(move file: File)` signature text (which is what a
    // Copy File would leave us matching).
    try testing.expect(std.mem.indexOf(u8, out, " = move %") != null);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.inspect") != null);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.consume") != null);
    try testing.expect(std.mem.indexOf(u8, out, "construct") != null);
}

test "frontend drops a plain-let fresh unique value at scope end" {
    // Core §10.5: `let a = open_file(...)` binds fresh ownership even
    // without `move`, so the local is dropped at scope end when it is
    // never consumed.
    const src = try helpers.probeSource("probes/cases", "lowering_plain_let_drop");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "drop ") != null);
}

test "frontend lowers struct drop hooks as destruction-view functions" {
    // Core §9.1-§9.2: a struct's `drop` hook body is compiled as a hidden
    // per-type function whose parameter is the borrowed destruction view;
    // `drop %v` of the struct stays one unexpanded instruction (air.md
    // §6.4), so the body's code is typechecked and lowered here.
    const src = try helpers.probeSource("probes/cases", "lowering_struct_drop_hook");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    // The hook is compiled as a hidden function with the destruction view
    // arriving as a borrow-mode parameter.
    try testing.expect(std.mem.indexOf(u8, out, "func @app.File.drop") != null);
    try testing.expect(std.mem.indexOf(u8, out, "borrow file: File") != null);
    // The body is actually lowered: the syscall and the field read both
    // live in the hook function (main itself only constructs File).
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#print") != null);
    try testing.expect(std.mem.indexOf(u8, out, "read_field") != null);
}

test "frontend rejects moving the destruction view inside a drop hook" {
    // Core §9.2: the destruction view may not be moved.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_move_destruction_view");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "cannot move borrowed") != null);
}

test "frontend rejects explicitly dropping the destruction view inside a drop hook" {
    // Core §9.2: the destruction view may not be explicitly dropped.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_drop_destruction_view");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "cannot drop borrowed") != null);
}

test "frontend does not auto-drop a binding released by every branch" {
    // Core §10.10: a definitely-released binding was already destroyed by
    // the release on every normal path, so it is not destroyed again at
    // scope end (no maybe-unique flag is needed).
    const src = try helpers.probeSource("probes/cases", "lowering_no_autodrop_all_branches");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    // `f` is dead on every path of the if; the scope-end drop in main is
    // elided. (`consume` itself still drops its moved-in parameter, so the
    // check is scoped to main's body.)
    const body = funcBody(out, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "drop ") == null);
    try testing.expect(std.mem.indexOf(u8, body, "move %") != null);
}

test "frontend lowers a partially released binding to a cleanup token" {
    // Core §10.10: a binding released on some but not all normal paths
    // becomes maybe-unique. The v0.2 AIR represents this with a cleanup
    // token (air.md §6.4): `cleanup_arm` arms the token at the
    // construct's entry, the consuming path disarms it (`cleanup_disarm`
    // alongside the `move`), and the scope-end destruction is a
    // `cleanup_drop` of the token — conditional on the per-path armed bit.
    // The maybe-unique value itself is never referenced after the join.
    const src = try helpers.probeSource("probes/cases", "lowering_partial_release_cleanup");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.main");
    // v1 (Instruction Set §4): cleanup tokens are gone. The consuming branch
    // transfers the file (a `move`), and the non-consuming branch ends
    // with an unconditional destruction of the owner before the merge —
    // the explicit-cleanup form.
    try testing.expect(std.mem.indexOf(u8, body, "move %") != null);
    try testing.expect(std.mem.indexOf(u8, body, " drop %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "cleanup_") == null);
}

test "frontend emits no drop for a Copy value" {
    // Core §10.1: dropping a Copy value does nothing, so the frontend
    // emits no `drop` at all.
    const src = try helpers.probeSource("probes/cases", "lowering_no_drop_copy");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "drop ") == null);
}

test "frontend lowers panicking calls to traps" {
    const src = try helpers.probeSource("probes/cases", "lowering_panic_trap");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#panic") != null);
    try testing.expect(std.mem.indexOf(u8, out, "trap") != null);
}

test "frontend lowers a type-test match over any to type_is + any_unpack" {
    // Core §11.6.2, §14.7: a `match` over an `any` value tests each arm's
    // type with `type_is` and recovers the payload with `any_unpack_copy`
    // in the selected arm; a wildcard arm is required.
    const src = try helpers.probeSource("probes/cases", "lowering_any_type_test_match");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // A tag test per type-test arm, then a payload unpack in the arm.
    try testing.expect(std.mem.indexOf(u8, out, "type_is") != null);
    try testing.expect(std.mem.indexOf(u8, out, "any_unpack") != null);
    try testing.expect(std.mem.indexOf(u8, out, "type_is %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = any_unpack_copy %") != null);
    // The arm bodies are lowered (syscall for list.len).
    try testing.expect(std.mem.indexOf(u8, out, "syscall list#len") != null);
}

test "frontend rejects a type-test match without a wildcard arm" {
    // Core §11.6.2: the tag space is open, so a match over an `any` with
    // type-test patterns must include a wildcard arm.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_any_match_no_wildcard");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "wildcard") != null);
}

test "frontend rejects a type-test pattern on a non-any scrutinee" {
    // Core §14.7: type-test patterns are accepted only for a scrutinee of
    // type `any`.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_type_test_non_any");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "'any' scrutinee") != null);
}

test "frontend allows unique type-test recovery from a consuming match" {
    // Core §11.6.2: `match (move a)` transfers the complete `any`, so an
    // unique arm binding owns the extracted payload.
    const src = try helpers.probeSource("probes/cases", "lowering_any_match_move_recovery");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "move %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = any_unpack_move %") != null);
}

test "frontend rejects an unique any cast without a move" {
    // Core §11.6.1: `a as T` for unique `T` requires `(move a) as T`; a
    // plain cast would copy an unique payload out of the `any`.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_any_cast_no_move");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unique payload") != null);
}

test "frontend allows a moved unique any cast" {
    // `(move a) as T` transfers ownership of the complete `any` (Core
    // §11.6.1).
    const src = try helpers.probeSource("probes/cases", "lowering_any_cast_move");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "move %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = any_unpack_move %") != null);
}

test "frontend rejects an unique type-test recovery from a borrowed any" {
    // Core §11.6.2: a unique payload can be recovered only from a moved
    // `any` (`match (move a)`); a non-consuming match over `any` binds
    // only Copy payload types.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_any_match_borrowed");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unique payload") != null);
}

test "frontend rejects a type-test pattern nested in another pattern" {
    // Core §14.7: a type-test pattern is the concrete type name with an
    // optional binding; nested inside a tuple/struct/list pattern it would
    // recover a payload without a `type_is` test.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_nested_type_test");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "whole arm") != null);
}

test "frontend rejects type-test patterns in let" {
    // Core §14: type-test patterns are refutable and may appear only in
    // `match`; `let` accepts only irrefutable patterns.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_type_test_let");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "refutable") != null);
}

test "frontend lowers hostdata host bindings and unique ownership" {
    // Core §11.7: `hostdata` is a primitive type created only by host
    // bindings; its values are unique, so a plain let is destroyed at
    // scope end.
    const os_src = try helpers.probeSource("probes/cases", "lowering_hostdata_os");
    defer testing.allocator.free(os_src);
    const app_src = try helpers.probeSource("probes/cases", "lowering_hostdata_app");
    defer testing.allocator.free(app_src);
    var c = try compileText("app", &.{ .{ "os", os_src }, .{ "app", app_src } });
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "hostdata") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall os#get_handle") != null);
    // hostdata is unique: the fresh local is destroyed at scope end.
    try testing.expect(std.mem.indexOf(u8, out, "drop ") != null);
}

test "frontend lowers a non-consuming multi-payload match to borrow_variant" {
    // air.md §5.3: a non-consuming `match` over a multi-payload variant has
    // no single-result `read_payload` to project all payloads, so the
    // lowering emits the multi-result `borrow_variant %u, #tag` (symmetric
    // with `unpack_variant`, but the base is never consumed). Each payload
    // is copied out when Copy and a borrowed view when unique.
    const src = try helpers.probeSource("probes/cases", "lowering_multi_payload_borrow_variant");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    // The multi-payload non-consuming arm projects all three payloads with
    // one borrow_variant (tag-carrying), not a read_payload+read_tuple hack.
    try testing.expect(std.mem.indexOf(u8, text, "= borrow_variant %") != null);
    try testing.expect(std.mem.indexOf(u8, text, ", #1") != null);
    // Single-payload / consuming arms keep their ops.
    // The standalone parser round-trips the printed text.
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    try testing.expect(prog.funcs.len > 0);
    const text2 = try cfg.print(&prog, testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 7 emits tailcall for a move/unique self-recursive fold" {
    // air.md §14.7.1: a direct self-recursive tail call carrying move/unique
    // loop-carried state (the iter.fold_with shape) is rewritten by Pass 7
    // into the frame-reusing `tailcall` terminator instead of an ordinary
    // `call`+`ret`, so recursion over a unique accumulator does not grow the
    // stack. The optimizer (which validates after every pass, incl. tail
    // call) must accept the emitted AIR, and the base-case `ret` survives via
    // the join's other predecessor.
    // Build with the optimizer on (Passes 7–8), as the `stilla` executable
    // does — Pass 7's tailcall emission runs inside the optimizer.
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    const src = try helpers.probeSource("probes/cases", "lowering_pass7_tailcall_fold");
    defer testing.allocator.free(src);
    try source_map.put(testing.allocator, "app", src);
    sources.source = source_map;
    var c = try frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "main", .optimize = true });
    defer c.deinit();

    const program = c.program.?;
    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.fold_files");
    // The recursive arm is a tailcall; the base-case ret survives.
    try testing.expect(std.mem.indexOf(u8, body, "tailcall @app.fold_files") != null);
    try testing.expect(std.mem.indexOf(u8, body, "ret %") != null);
    // No ordinary self `call` remains ('= call @…' — 'tailcall @…' also
    // contains the substring 'call @', so the defining form must be sought).
    try testing.expect(std.mem.indexOf(u8, body, "= call @app.fold_files") == null);
}

test "iter.fold with a unique accumulator compiles and fold_with tailcalls" {
    // The StdLib move gap (Core §18): fold/fold_with used to omit `move` when
    // re-passing a move-mode parameter, so a unique accumulator type could not
    // instantiate them. Now a unique S instantiates, and (with the Pass 7
    // emission) the embedded fold_with runs the unique accumulator across a
    // frame-reusing `tailcall`, not a growing stack.
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    const src = try helpers.probeSource("probes/cases", "lowering_iter_fold_unique_acc");
    defer testing.allocator.free(src);
    try source_map.put(testing.allocator, "app", src);
    sources.source = source_map;
    var c = try frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "main", .optimize = true });
    defer c.deinit();

    const program = c.program.?;
    const text = try irText(&program);
    defer testing.allocator.free(text);
    // The embedded monomorphized fold_with carries the unique accumulator
    // through a tailcall.
    try testing.expect(std.mem.indexOf(u8, text, "tailcall @iter.fold_with.1") != null);
}

test "iter.try_fold is Stilla source and short-circuits on Break" {
    // try_fold/try_fold_with were host bindings because the frontend could
    // not substitute the generic union payloads of Result[S,R]. With
    // expected-type-aware construction (Core §11) they are ordinary Stilla
    // source: the embedded code compiles, and a step that returns Break
    // stops iteration.
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    const src = try helpers.probeSource("probes/cases", "lowering_iter_try_fold");
    defer testing.allocator.free(src);
    try source_map.put(testing.allocator, "app", src);
    sources.source = source_map;
    var c = try frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "main", .optimize = true });
    defer c.deinit();

    const program = c.program.?;
    const text = try irText(&program);
    defer testing.allocator.free(text);
    // The stdlib try_fold monomorphizes and continues/breaks via the
    // Result union (a construct with the substituted payload types).
    try testing.expect(std.mem.indexOf(u8, text, "func @iter.try_fold") != null);
    try testing.expect(std.mem.indexOf(u8, text, "construct #0") != null); // Complete
    try testing.expect(std.mem.indexOf(u8, text, "construct #1") != null); // Break
}

test "iter.try_fold_with with an inline step lambda and a void context compiles" {
    // Two regressions in one: an inline lambda with a declared return type
    // uses it as its body's goal (Core §11) — `Result::Complete`/`Break`
    // inside the step fill their unbound type argument from it instead of
    // collapsing to a wildcard `Result<>` (which crashed `substParams`) —
    // and a `()` void argument carries no observable value, so the call
    // emits no operand for it (the phantom id `%4294967295` never reaches
    // the text form and the optimized AIR round-trips).
    const src = try helpers.probeSource("probes/cases", "lowering_iter_try_fold_with_void");
    defer testing.allocator.free(src);
    var c = try compileOpt("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program.?;
    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "func @iter.try_fold_with") != null);
    // The void context emits no operand: the phantom id must never print.
    try testing.expect(std.mem.indexOf(u8, text, "%4294967295") == null);
}

test "calling a function with a void parameter emits no operand" {
    // A `()` argument to a void-typed parameter produces no instruction
    // operand (cfg-lowering.md, Lowering rules): the call's operand list carries one
    // entry per non-void parameter, so the optimized AIR round-trips.
    const src = try helpers.probeSource("probes/cases", "lowering_void_param_no_operand");
    defer testing.allocator.free(src);
    var c = try compileOpt("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program.?;
    const text = try irText(&program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "%4294967295") == null);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.g") != null);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.mid") != null);
}

test "frontend compiles the standard-library bundle as host bindings" {
    // The whole embedded std/ bundle must load through the pipeline:
    // every member is a host binding, and builtin's generic signatures
    // resolve for syscalls.
    const src = try helpers.probeSource("probes/cases", "lowering_stdlib_bundle_host_bindings");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.graph != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall list#len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall math#sqrt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall string#len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall list#range") != null);
}

test "frontend compiles the StdLib array/hashmap container examples" {
    // StdLib §2 / §3: the container examples must compile as written —
    // unique opaque nominal types, borrow/move parameters, explicit
    // `::[...]` specialization where the type argument is not carried by
    // an argument expression (Core §12.2, §12.3), and in-place consuming
    // updates (move in, updated value out).
    const src = try helpers.probeSource("probes/cases", "lowering_stdlib_array_hashmap");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.graph != null);
    try testing.expect(c.program != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // Host binding calls lower to syscalls; no container value is ever
    // a hostdata payload (StdLib §1, §6).
    try testing.expect(std.mem.indexOf(u8, out, "syscall array#make") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall array#get") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall array#set") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall array#clone") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall hashmap#empty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall hashmap#insert") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall hashmap#remove") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall hashmap#clone") != null);
    // The containers are unique by declaration (Core §11.8), so scope-end
    // destruction emits `drop` for each live container — a Copy token
    // would schedule none.
    try testing.expect(std.mem.indexOf(u8, out, "drop %") != null);
}

test "frontend rejects every hostdata/any coercion and cast" {
    // Core §11.6, §11.6.1, §11.7: `hostdata` does not coerce to `any`
    // and no cast is defined from or to it. Each of these must be a
    // compile-time error, not a silent pack or an `any_unpack`.
    const src1 = try helpers.probeSource("probes/cases", "lowering_reject_hostdata_cast");
    defer testing.allocator.free(src1);
    var c1 = try compileText("app", &.{.{ "app", src1 }});
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "has no cast") != null);

    const src2 = try helpers.probeSource("probes/cases", "lowering_reject_hostdata_return");
    defer testing.allocator.free(src2);
    var c2 = try compileText("app", &.{.{ "app", src2 }});
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "return type mismatch") != null);

    const src3 = try helpers.probeSource("probes/cases", "lowering_reject_hostdata_let");
    defer testing.allocator.free(src3);
    var c3 = try compileText("app", &.{.{ "app", src3 }});
    defer c3.deinit();
    try testing.expect(c3.program == null);
    try testing.expect(std.mem.indexOf(u8, c3.diag.?.message, "let type mismatch") != null);

    const src4 = try helpers.probeSource("probes/cases", "lowering_reject_hostdata_coerce");
    defer testing.allocator.free(src4);
    var c4 = try compileText("app", &.{.{ "app", src4 }});
    defer c4.deinit();
    try testing.expect(c4.program == null);
    try testing.expect(std.mem.indexOf(u8, c4.diag.?.message, "does not coerce to 'any'") != null);
}

test "frontend rejects the empty tuple type" {
    // Core §11.4: `tuple[]` is not a type — the empty tuple `()` is the
    // unique `void` value; a tuple type has at least one element.
    const src = try helpers.probeSource("probes/cases", "lowering_reject_empty_tuple");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "expected a type") != null);
}

test "frontend accepts the integer-family as conversions" {
    // Core §16.3: int32 ↔ float32, int32 ↔ byte, int32 ↔ uint32,
    // byte ↔ int32, uint32 ↔ int32. They lower to `num_cast`.
    const src = try helpers.probeSource("probes/cases", "lowering_integer_family_casts");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.count(u8, out, "num_cast") == 4);
}

test "frontend rejects casts outside the uniform conversion family" {
    // Identity casts and any cast touching hostdata are compile errors;
    // `a as T` on an `any` scrutinee still routes to `any_unpack` and
    // is unaffected. The 64-bit integer casts (`i64 as int32`, …) are
    // part of the family and compile.
    const src1 = try helpers.probeSource("probes/cases", "lowering_reject_identity_cast");
    defer testing.allocator.free(src1);
    var c1 = try compileText("app", &.{.{ "app", src1 }});
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "invalid cast") != null);

    const src2 = try helpers.probeSource("probes/cases", "lowering_accept_i64_to_i32_cast");
    defer testing.allocator.free(src2);
    var c2 = try compileText("app", &.{.{ "app", src2 }});
    defer c2.deinit();
    try testing.expect(c2.program != null);

    const src3 = try helpers.probeSource("probes/cases", "lowering_reject_bool_cast");
    defer testing.allocator.free(src3);
    var c3 = try compileText("app", &.{.{ "app", src3 }});
    defer c3.deinit();
    try testing.expect(c3.program == null);
    try testing.expect(std.mem.indexOf(u8, c3.diag.?.message, "invalid cast") != null);
}

test "frontend compiles the StdLib §5 string example with explicit conversions" {
    // StdLib §5: byte sequences are written with explicit `as byte`
    // conversions (Core §16.3); the example must compile as written.
    const src = try helpers.probeSource("probes/cases", "lowering_stdlib_string_example");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    try testing.expect(c.graph != null);
    try testing.expect(c.program != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall string#from_utf8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "num_cast") != null);
}

test "frontend accepts uint32 arithmetic and two's-complement negation" {
    // Core §16.3 / Runtime §7.2: uint32 arithmetic wraps modulo 2^32 and
    // never traps; unary minus is two's-complement. byte arithmetic does
    // not exist and stays rejected.
    const src = try helpers.probeSource("probes/cases", "lowering_uint32_arithmetic");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.count(u8, out, "uint32 = ") >= 1);

    const src2 = try helpers.probeSource("probes/cases", "lowering_reject_byte_arithmetic");
    defer testing.allocator.free(src2);
    var c2 = try compileText("app", &.{.{ "app", src2 }});
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "type mismatch") != null);
}

test "frontend requires move for existing unique owners in consuming positions" {
    // Core §10.11: an existing unique local owner must be moved with
    // explicit `move` before being stored into a struct field, a list or
    // tuple element, or a let binding; fresh values transfer implicitly.
    const src1 = try helpers.probeSource("probes/cases", "lowering_reject_move_field");
    defer testing.allocator.free(src1);
    var c1 = try compileText("app", &.{.{ "app", src1 }});
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "owning field") != null);

    const src2 = try helpers.probeSource("probes/cases", "lowering_reject_move_element");
    defer testing.allocator.free(src2);
    var c2 = try compileText("app", &.{.{ "app", src2 }});
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "owning element") != null);

    const src3 = try helpers.probeSource("probes/cases", "lowering_reject_move_binding");
    defer testing.allocator.free(src3);
    var c3 = try compileText("app", &.{.{ "app", src3 }});
    defer c3.deinit();
    try testing.expect(c3.program == null);
    try testing.expect(std.mem.indexOf(u8, c3.diag.?.message, "owning binding") != null);
}

test "frontend applies the any-parameter exception with move discipline" {
    // Core §10.6 / §18 *Parameters*: a plain `any` parameter is the sole
    // exception to Copy-only plain parameters — a fresh unique value
    // transfers implicitly, an existing owner must be moved, and
    // hostdata never coerces to any (Core §11.6).
    const src1 = try helpers.probeSource("probes/cases", "lowering_any_param_move_ok");
    defer testing.allocator.free(src1);
    var c1 = try compileText("app", &.{.{ "app", src1 }});
    defer c1.deinit();
    try testing.expect(c1.program != null);

    const src2 = try helpers.probeSource("probes/cases", "lowering_any_param_move_required");
    defer testing.allocator.free(src2);
    var c2 = try compileText("app", &.{.{ "app", src2 }});
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "'any' parameter") != null);
}
