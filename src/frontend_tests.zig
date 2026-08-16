//! Test file: `frontend` — the whole pipeline from entry module to printed
//! CFG IR, plus the CFG IR text form.
//!
//! White-box tests of `src/frontend.zig` and `src/cfg.zig`'s own internals
//! stay in those module files; this file aggregates them (with the split
//! passes in `src/passes/` — `cfg_lex`, `cfg_parse`, `cfg_print`, and the
//! `cfg_lower_*` lowering passes) so they are analyzed and run, and adds
//! black-box tests of whole-pipeline compilation (entry module → printed
//! IR) and the IR text-form round trip through the standalone `cfg.Parser`.
//!
//! Run this file via `zig build test` (it pulls in `frontend.zig`, whose
//! `stilla_std_sources` anonymous import is only wired up by the build
//! system; `--dep` cannot attach to the main module from the CLI).

const std = @import("std");
const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const lower = @import("lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");
const cfg_lower_emit = @import("passes/cfg_lower_emit.zig");
const testing = std.testing;

test {
    // White-box tests of the module files in this slice: the IR
    // structures, the text-form lexer/parser/printer (all split out into
    // src/passes/), and the CFG-lowering passes.
    _ = @import("frontend.zig");
    _ = @import("cfg.zig");
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
    _ = @import("passes/cfg_lower_validate.zig");
    _ = @import("passes/cfg_dead_block.zig");
    _ = @import("passes/cfg_optimize.zig");
    _ = @import("passes/cfg_pre.zig");
    _ = @import("passes/cfg_tail_call.zig");
    _ = @import("passes/cfg_drop_elide.zig");
    _ = @import("passes/cfg_jump_thread.zig");
    _ = @import("passes/cfg_phi_simplify.zig");
}

// ---------------------------------------------------------------------------
// frontend — black-box: whole programs compiled through the pipeline
// (phase 1 module graph → phase 2 check → phase 3 CFG lowering → printer).
// ---------------------------------------------------------------------------

fn compileText(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !frontend.Compilation {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    for (texts) |pair| {
        try source_map.put(testing.allocator, pair[0], pair[1]);
    }
    sources.source = source_map;
    return frontend.compile(testing.allocator, .{ .entry = entry, .sources = sources, .entry_fn = "main" });
}

fn irText(program: *const cfg.IrProgram) ![]u8 {
    return cfg.print(program, testing.allocator);
}

/// Test-only driver for the construction-time constant folding
/// (frontend.md §4.3): applies the same `tryFoldOp` that every `emit`
/// site uses to a parsed program, so the fold math (IEEE float
/// semantics, trap preservation) can be tested without the lowering.
/// Not a pipeline pass — the frontend has no folding pass.
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

test "frontend compiles a single module to IR" {
    var c = try compileText("app", &.{
        .{ "app", "const builtin = import(\"builtin\");\nconst greeting: str = \"hello\";\nfn add(a: int32, b: int32) -> int32 { a + b }\nfn main() -> void { builtin.print(greeting); }" },
    });
    defer c.deinit();

    const program = c.program.?;
    // Two modules in phase-1 topological order: `app` and the `builtin`
    // stdbundle module it imports, which is loaded like any source module
    // (frontend.md §3.1; ir.md §11).
    try testing.expectEqual(@as(usize, 2), program.modules.len);
    // app's @init plus its two function definitions; builtin contributes no
    // funcs because its init is null (nothing to evaluate, ir.md §11).
    try testing.expectEqual(@as(usize, 3), program.funcs.len);
    try testing.expect(program.entry != null);
    try testing.expectEqualStrings("app.main", program.entry.?.name.text);

    const out = try irText(&program);
    defer testing.allocator.free(out);
    // The module init stores the constant (the only stored const, so
    // slot #0 — member and slot indices are distinct, ir.md §7); main
    // loads it and syscalls print.
    try testing.expect(std.mem.indexOf(u8, out, "func @init") != null);
    try testing.expect(std.mem.indexOf(u8, out, "store_member #0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "load_member") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#print") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.add") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.main") != null);
}

test "frontend resolves imports, dependencies first" {
    var c = try compileText("use", &.{
        .{ "calc", "fn add(a: int32, b: int32) -> int32 { a + b }" },
        .{ "use", "const calc = import(\"calc\");\nfn main() -> int32 { calc.add(1, 2) }" },
    });
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
    // by @init (ir.md §7).
    try testing.expect(std.mem.indexOf(u8, out, "store_member") == null);
}

test "frontend rejects an import cycle" {
    var c = try compileText("a", &.{
        .{ "a", "const b = import(\"b\");\n" },
        .{ "b", "const a = import(\"a\");\n" },
    });
    defer c.deinit();

    try testing.expect(c.graph == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "import cycle") != null);
    // The cycle diagnostic points at the re-entering import expression, not
    // the module start (regression: it used to be span 0, the entry 1:1).
    try testing.expect(c.diag.?.span.start != 0);
}

test "frontend rejects an unresolved import" {
    var c = try compileText("a", &.{
        .{ "a", "const missing = import(\"nope\");\n" },
    });
    defer c.deinit();

    try testing.expect(c.graph == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unresolved import") != null);
    // Regression: the diagnostic used to be reported at span 0 (the entry
    // module's 1:1) instead of the import expression.
    try testing.expect(c.diag.?.span.start != 0);
}

test "frontend rejects an explicit --entry-fn that does not exist" {
    // lowerProgram: an explicitly named entry function that is absent is a
    // diagnostic; the implicit `main` default stays silent for library
    // modules (checked by the other entry tests).
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", "fn helper() -> void {}\n");
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn sign(value: int32) -> int32 {
            \\    if (value >= 0) {
            \\        1
            \\    } else {
            \\        -1
            \\    }
            \\}
            \\fn ok(a: bool, b: bool) -> bool { a and b }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // Conditional branches print in the canonical ternary form
    // `br %c ? then : else` (ir.md §9), not as a `br_cond` opcode.
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\union Result { Ok(int32), Err(str) }
            \\fn describe(r: Result) -> str {
            \\    match (r) {
            \\        Result::Ok(v) => builtin.str(v),
            \\        Result::Err(e) => e
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_tag") != null);
    try testing.expect(std.mem.indexOf(u8, out, "switch") != null);
    try testing.expect(std.mem.indexOf(u8, out, "read_payload") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#str") != null);
}

test "frontend lowers ownership: move, borrow, drop" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\fn open_file(path: str) -> File { File{ fd: 3, path: path } }
            \\fn inspect(borrow file: File) -> void {}
            \\fn consume(move file: File) -> void {}
            \\fn main() -> void {
            \\    let a = open_file("a.txt");
            \\    inspect(a);
            \\    inspect(a);
            \\    consume(move a);
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        // Surface the frontend diagnostic instead of crashing on the
        // unwrap when the source fails to frontend.compile.
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\fn open_file(path: str) -> File { File{ fd: 3, path: path } }
            \\fn inspect(borrow file: File) -> void {}
            \\fn main() -> void {
            \\    let a = open_file("a.txt");
            \\    inspect(a);
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "drop ") != null);
}

test "frontend lowers struct drop hooks as destruction-view functions" {
    // Core §9.1-§9.2: a struct's `drop` hook body is compiled as a hidden
    // per-type function whose parameter is the borrowed destruction view;
    // `drop %v` of the struct stays one unexpanded instruction (ir.md
    // §6.4), so the body's code is typechecked and lowered here.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File {
            \\    fd: int32;
            \\    path: str;
            \\    drop(file) {
            \\        builtin.print(file.path);
            \\    }
            \\}
            \\fn main() -> void {
            \\    let f = File{ fd: 3, path: "x" };
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) { let y = move file; } }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "cannot move borrowed") != null);
}

test "frontend rejects explicitly dropping the destruction view inside a drop hook" {
    // Core §9.2: the destruction view may not be explicitly dropped.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) { drop file; } }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "cannot drop borrowed") != null);
}

test "frontend does not auto-drop a binding released by every branch" {
    // Core §10.10: a definitely-released binding was already destroyed by
    // the release on every normal path, so it is not destroyed again at
    // scope end (no maybe-unique flag is needed).
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn consume(move f: File) -> void {}
            \\fn main() -> void {
            \\    let f = File{ fd: 1 };
            \\    if (true) { consume(move f); } else { consume(move f); }
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
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
    // becomes maybe-unique. The v0.2 IR represents this with a cleanup
    // token (ir.md §6.4): `cleanup_owner` arms the token at the
    // construct's entry, the consuming path disarms it (`cleanup_disable`
    // alongside the `move`), and the scope-end destruction is a
    // `drop_cleanup` of the token — conditional on the per-path armed bit.
    // The maybe-unique value itself is never referenced after the join.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn consume(move f: File) -> void {}
            \\fn main() -> void {
            \\    let f = File{ fd: 1 };
            \\    if (true) { consume(move f); } else { }
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "cleanup_owner") != null);
    try testing.expect(std.mem.indexOf(u8, body, "cleanup_disable") != null);
    try testing.expect(std.mem.indexOf(u8, body, "drop_cleanup") != null);
    try testing.expect(std.mem.indexOf(u8, body, "move %") != null);
    // The release is conditional: the destruction is a token disarm /
    // drop_cleanup pair, never a plain unconditional `drop` of the file.
    try testing.expect(std.mem.indexOf(u8, body, " drop %") == null);
}

test "frontend emits no drop for a Copy value" {
    // Core §10.1: dropping a Copy value does nothing, so the frontend
    // emits no `drop` at all.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn main() -> void {
            \\    let x = 1;
            \\    drop x;
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "drop ") == null);
}

test "frontend lowers panicking calls to traps" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    builtin.panic("boom");
            \\}
        },
    });
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn describe(a: any) -> int32 {
            \\    match (a) {
            \\        int32 n => n,
            \\        str s => builtin.len(["x"]),
            \\        _ => -1
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // A tag test per type-test arm, then a payload unpack in the arm.
    try testing.expect(std.mem.indexOf(u8, out, "type_is") != null);
    try testing.expect(std.mem.indexOf(u8, out, "any_unpack") != null);
    try testing.expect(std.mem.indexOf(u8, out, "type_is %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = any_unpack_copy %") != null);
    // The arm bodies are lowered (syscall for builtin.len).
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#len") != null);
}

test "frontend rejects a type-test match without a wildcard arm" {
    // Core §11.6.2: the tag space is open, so a match over an `any` with
    // type-test patterns must include a wildcard arm.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn describe(a: any) -> int32 {
            \\    match (a) { int32 n => n }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "wildcard") != null);
}

test "frontend rejects a type-test pattern on a non-any scrutinee" {
    // Core §14.7: type-test patterns are accepted only for a scrutinee of
    // type `any`.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn describe(x: int32) -> int32 {
            \\    match (x) { int32 n => n, _ => -1 }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "'any' scrutinee") != null);
}

test "frontend allows unique type-test recovery from a consuming match" {
    // Core §11.6.2: `match (move a)` transfers the complete `any`, so an
    // unique arm binding owns the extracted payload.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn describe(a: any) -> int32 {
            \\    match (move a) { File f => f.fd, _ => 0 }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn use(a: any) -> File { a as File }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unique payload") != null);
}

test "frontend allows a moved unique any cast" {
    // `(move a) as T` transfers ownership of the complete `any` (Core
    // §11.6.1).
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn use(a: any) -> File { (move a) as File }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "move %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = any_unpack_move %") != null);
}

test "frontend rejects an unique type-test recovery from a borrowed any" {
    // Core §11.6.1: an unique payload may be recovered only from a moved
    // `any` (`match (move a)`); a borrowed `any` yields only borrows.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn describe(a: any) -> int32 {
            \\    match (a) { File f => 1, _ => 0 }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unique payload") != null);
}

test "frontend rejects a type-test pattern nested in another pattern" {
    // Core §14.7: a type-test pattern is the concrete type name with an
    // optional binding; nested inside a tuple/struct/list pattern it would
    // recover a payload without a `type_is` test.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn describe(a: any) -> int32 {
            \\    match (a) { (int32 n, str s) => 1, _ => 0 }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "whole arm") != null);
}

test "frontend rejects type-test patterns in let" {
    // Core §14: type-test patterns are refutable and may appear only in
    // `match`; `let` accepts only irrefutable patterns.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(a: any) -> int32 {
            \\    let int32 n = a;
            \\    n
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "refutable") != null);
}

test "frontend lowers hostdata host bindings and unique ownership" {
    // Core §11.7: `hostdata` is a primitive type created only by host
    // bindings; its values are unique, so a plain let is destroyed at
    // scope end.
    var c = try compileText("app", &.{
        .{ "os", "fn get_handle() -> hostdata;" },
        .{
            "app",
            \\const os = import("os");
            \\fn main() -> void {
            \\    let h = os.get_handle();
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "hostdata") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall os#get_handle") != null);
    // hostdata is unique: the fresh local is destroyed at scope end.
    try testing.expect(std.mem.indexOf(u8, out, "drop ") != null);
}

test "frontend IR round-trips through the standalone cfg parser" {
    // The printed IR (ir.md §9) is the contract with the runtime side: the
    // standalone cfg.Parser must re-parse everything the frontend prints.
    // This is also the SSA-id regression test — before `newValue` appended
    // to the per-function value table, every non-parameter value in a
    // function printed the same id, and a re-parse would have rejected the
    // text (value %N defined out of order) or silently mis-resolved it.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\union Result { Ok(int32), Err(str) }
            \\fn sign(v: int32) -> int32 { if (v >= 0) { 1 } else { -1 } }
            \\fn describe(r: Result) -> str {
            \\    match (r) { Result::Ok(x) => builtin.str(x), Result::Err(e) => e }
            \\}
            \\fn dump(xs: list[int32]) -> void { let n = builtin.len(xs); builtin.print(builtin.str(n)); }
            \\fn main() -> void { dump(builtin.range(0, 2)); }
        },
    });
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    try testing.expectEqual(@as(usize, 2), prog.modules.len);
    try testing.expectEqual(@as(usize, 5), prog.funcs.len);
    // The parser leaves the entry unselected; every function and block
    // survives, and the unique ids round-trip in order.
    for (prog.funcs) |f| {
        try testing.expect(f.blocks.len > 0);
        // An empty function (e.g. an `@init` with nothing to store) has
        // no values; otherwise the unique ids round-trip in order.
        if (f.values.len > 0) try testing.expectEqual(f.values.len, f.values[f.values.len - 1].id + 1);
    }
}

test "frontend IR round-trips multi-result destructures and zero-arg construct" {
    // ir.md §5.3/§10: `unpack_variant` of a multi-payload variant defines
    // one result per payload (comma-separated in the text form), and
    // `construct` of an empty struct takes zero values. The printed IR
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
    // unchanged (ir.md §10: parse -> print -> parse round-trips exactly).
    const text2 = try cfg.print(&prog, testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "frontend IR round-trips with duplicate-block-producing constructs" {
    // Block labels must be unique in the printed IR (ir.md §9): the
    // standalone cfg parser rejects duplicate labels. Repeated control
    // flow (three `if`s) and multi-test matches (three literal arms,
    // type-test chains) must re-parse.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn classify(n: int32) -> str {
            \\    match (n) { 0 => "zero", 1 => "one", 2 => "two", _ => "other" }
            \\}
            \\fn sign2(a: bool, b: bool, c: bool) -> int32 {
            \\    let x = if (a) { 1 } else { 0 };
            \\    let y = if (b) { 2 } else { 3 };
            \\    if (c) { x } else { y }
            \\}
            \\fn sum2(a: list[int32], b: list[int32]) -> int32 {
            \\    if (builtin.len(a) > 0) { builtin.print("a"); } else { builtin.print("b"); };
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

test "frontend compiles the standard-library bundle as host bindings" {
    // The whole embedded std/ bundle must load through the pipeline:
    // every member is a host binding, and builtin's generic signatures
    // resolve for syscalls.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const m = import("math");
            \\const s = import("string");
            \\fn main() -> int32 {
            \\    builtin.len(builtin.range(0, 10)) + m.sqrt(2.0) as int32 + s.len("hi")
            \\}
        },
    });
    defer c.deinit();

    try testing.expect(c.graph != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall math#sqrt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall string#len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#range") != null);
}

test "frontend compiles the StdLib array/hashmap container examples" {
    // StdLib §2 / §3: the container examples must compile as written —
    // Copy token types, plain parameters, and explicit `::[...]`
    // specialization where the type argument is not carried by an
    // argument expression (Core §12.2, §12.3).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const array = import("array");
            \\const hashmap = import("hashmap");
            \\const builtin = import("builtin");
            \\using builtin.Option;
            \\fn main() -> void {
            \\    let a = array.make(4, 0);
            \\    let x = array.get::[int32](a, 2);
            \\    let n = array.len::[int32](a);
            \\    let m = hashmap.empty::[str, int32]();
            \\    let m = hashmap.insert(m, "a", 1);
            \\    let m = hashmap.insert(m, "b", 2);
            \\    match (hashmap.get::[str, int32](m, "a")) {
            \\        Option::Some(value) => builtin.print(builtin.str(value)),
            \\        Option::None => builtin.print("missing")
            \\    };
            \\}
        },
    });
    defer c.deinit();

    try testing.expect(c.graph != null);
    try testing.expect(c.program != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // Host binding calls lower to syscalls; no container value is ever
    // a hostdata payload (StdLib §1, §6).
    try testing.expect(std.mem.indexOf(u8, out, "syscall array#make") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall array#get") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall hashmap#empty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall hashmap#insert") != null);
}

test "frontend rejects every hostdata/any coercion and cast" {
    // Core §11.6, §11.6.1, §11.7: `hostdata` does not coerce to `any`
    // and no cast is defined from or to it. Each of these must be a
    // compile-time error, not a silent pack or an `any_unpack`.
    var c1 = try compileText("app", &.{
        .{ "app", "fn f(a: any) -> hostdata { (move a) as hostdata }\nfn main() -> void {}" },
    });
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "has no cast") != null);

    var c2 = try compileText("app", &.{
        .{ "app", "fn make_hd() -> hostdata;\nfn g() -> any { make_hd() }\nfn main() -> void {}" },
    });
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "return type mismatch") != null);

    var c3 = try compileText("app", &.{
        .{ "app", "fn make_hd() -> hostdata;\nfn main() -> void { let a: any = make_hd(); }" },
    });
    defer c3.deinit();
    try testing.expect(c3.program == null);
    try testing.expect(std.mem.indexOf(u8, c3.diag.?.message, "let type mismatch") != null);

    var c4 = try compileText("app", &.{
        .{ "app", "fn make_hd() -> hostdata;\nfn pick(c: bool, h: hostdata) -> any { if (c) { h } else { \"hi\" } }\nfn main() -> void {}" },
    });
    defer c4.deinit();
    try testing.expect(c4.program == null);
    try testing.expect(std.mem.indexOf(u8, c4.diag.?.message, "does not coerce to 'any'") != null);
}

test "frontend rejects the empty tuple type" {
    // Core §11.4: `tuple[]` is not a type — the empty tuple `()` is the
    // unique `void` value; a tuple type has at least one element.
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { let t: tuple[] = (); }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "expected a type") != null);
}

test "frontend accepts the integer-family as conversions" {
    // Core §16.3: int32 ↔ float32, int32 ↔ byte, int32 ↔ uint32,
    // byte ↔ int32, uint32 ↔ int32. They lower to `num_cast`.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn main() -> int32 {
            \\    let b = 104 as byte;
            \\    let u = 7 as uint32;
            \\    (b as int32) + (u as int32)
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.count(u8, out, "num_cast") == 4);
}

test "frontend rejects casts outside the Core §16.3 list" {
    // Identity casts, byte/uint32 to float, and any cast touching
    // hostdata are compile errors; `a as T` on an `any` scrutinee still
    // routes to `any_unpack` and is unaffected.
    var c1 = try compileText("app", &.{
        .{ "app", "fn main() -> void { let a = 42 as int32; }" },
    });
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "invalid cast") != null);

    var c2 = try compileText("app", &.{
        .{ "app", "fn main() -> void { let b = 104 as byte; let a = b as float32; }" },
    });
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "invalid cast") != null);
}

test "frontend compiles the StdLib §5 string example with explicit conversions" {
    // StdLib §5: byte sequences are written with explicit `as byte`
    // conversions (Core §16.3); the example must compile as written.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const string = import("string");
            \\fn main() -> void {
            \\    let s = string.from_utf8([104 as byte, 101 as byte, 108 as byte, 108 as byte, 111 as byte]);
            \\    let parts = string.split(s, "l");
            \\    let joined = string.join(parts, "-");
            \\    let bytes = string.to_utf8(s);
            \\    let cps = string.to_codepoints(s);
            \\    let upper = string.upper(s);
            \\}
        },
    });
    defer c.deinit();

    try testing.expect(c.graph != null);
    try testing.expect(c.program != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall string#from_utf8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "num_cast") != null);
}

test "frontend rejects missing, duplicate, and unknown struct fields" {
    // Core §8.1: all fields must be supplied exactly once; unknown fields
    // and duplicate fields are frontend.compile-time errors.
    var c1 = try compileText("app", &.{
        .{ "app", "struct P { x: int32; y: int32; }\nfn main() -> void { let p = P{ x: 1 }; }" },
    });
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "missing field") != null);

    var c2 = try compileText("app", &.{
        .{ "app", "struct P { x: int32; y: int32; }\nfn main() -> void { let p = P{ x: 1, x: 2 }; }" },
    });
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "duplicate field") != null);

    var c3 = try compileText("app", &.{
        .{ "app", "struct P { x: int32; }\nfn main() -> void { let p = P{ q: 1 }; }" },
    });
    defer c3.deinit();
    try testing.expect(c3.program == null);
    try testing.expect(std.mem.indexOf(u8, c3.diag.?.message, "has no field") != null);
}

test "frontend rejects import outside a module constant initializer" {
    // Core §2.2 / Grammar `import-expression`: `import(...)` may appear
    // only as the initializer of a module-level `const` binding.
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { let b = import(\"builtin\"); }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "module constant initializer") != null);
}

test "frontend lowers arithmetic, comparison, and string concat operators" {
    // Core §16.3: int32 arithmetic; str + str concatenation.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn ops(a: int32, b: int32) -> int32 { (a + b) * 2 - a / b % 2 }
            \\fn greet(name: str) -> str { "hi " + name }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = add ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = mul ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = sub ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = div ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = rem ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = concat ") != null);
}

test "frontend lowers as casts" {
    // Core §16.3: `float32 as int32` and `int32 as float32` are core
    // conversions; the IR emits a `num_cast` op.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn cvt(x: float32) -> int32 { x as int32 }
            \\fn widen(x: int32) -> float32 { x as float32 }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = num_cast ") != null);
}

test "frontend lowers shadowing with the previous binding read first" {
    // Core §4: `let x = x + 1;` — the right-hand `x` refers to the
    // previous binding.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f() -> int32 { let x = 10; let x = x + 1; x }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // 10 + 1 folds at construction (frontend.md §4.3) to the constant.
    try testing.expect(std.mem.indexOf(u8, out, " = const 11") != null);
}

test "frontend lowers mutual recursion with declared return types" {
    // Core §6.5: functions are order-independent; mutual recursion is
    // permitted when every participant declares its return type.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn is_even(n: int32) -> bool { if (n == 0) { true } else { is_odd(n - 1) } }
            \\fn is_odd(n: int32) -> bool { if (n == 0) { false } else { is_even(n - 1) } }
            \\fn main() -> void { let r = is_even(4); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.is_odd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.is_even") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.is_odd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.is_even") != null);
}

test "frontend lowers tuple destructuring to read_tuple projections" {
    // Core §14.2 / §14.6: tuple patterns project elements; the whole
    // tuple is consumed as one value.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn f(t: tuple[int32, str]) -> int32 { let (a, b) = t; builtin.len(["x"]) }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_tuple") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#1") != null);
}

test "frontend lowers list indexing with read_index" {
    // Core §11.5: indexing uses `@[...]` and does not mutate.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(xs: list[int32]) -> int32 { xs@[0] }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_index") != null);
}

test "frontend lowers consuming list-pattern destructuring with split_list" {
    // Core §18 (whole-owner rule): destructuring an owned list with
    // `let [head, ..rest] = move xs` consumes the collection as a whole;
    // one atomic `split_list` defines the item and the owned rest (ir.md
    // §5.3) — each unique element becomes an owner.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn consume(move f: File) -> void {}
            \\fn main() -> void {
            \\    let xs = [File{ fd: 1 }];
            \\    let [f, ..rest] = move xs;
            \\    consume(move f);
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = split_list %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = move %") != null);
}

test "frontend lowers box, peek, and unbox to syscalls" {
    // Core §10.8 / Runtime §4.7–§4.8: box/peek/unbox are host bindings;
    // peek borrows without consuming, unbox(move b) transfers ownership.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    let b = builtin.box(42);
            \\    let x = builtin.peek(b);
            \\    let y = builtin.unbox(move b);
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#box") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#peek") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#unbox") != null);
    // `unbox(move b)` on a Copy box[int32] lowers `move` to nothing
    // (Core §10.6: a copy of a Copy value is the value itself), so
    // no copy instruction is emitted — the unbox takes the box directly.
    try testing.expect(std.mem.indexOf(u8, out, "copy") == null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#unbox, %1") != null);
}

test "frontend rejects an unspecialized generic used as a value" {
    // Core §12.4: an unspecialized generic function is a compile-time
    // template, not a runtime function value; `let f = identity` references
    // the template itself and is rejected. A specialization (`identity::[int32]`)
    // is a valid monomorphic function value.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn identity[T](move value: T) -> T { move value }
            \\fn main() -> void { let f = identity; }
        },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unspecialized generic") != null);
}

test "frontend accepts an explicitly specialized generic as a value" {
    // Core §12.4: `identity::[int32]` is a first-class monomorphic function
    // value of type `fn(move int32) -> int32`; the checker accepts it and
    // records a specialization. Lowering a specialized value is Pass 5.4
    // (future work), so the frontend still stops in the lowerer — but the
    // diagnostic must NOT come from the checker's unspecialized-generic rule.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn identity[T](move value: T) -> T { move value }
            \\fn main() -> void { let f = identity::[int32]; }
        },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "cannot be used as a value") != null);
}

test "frontend lowers an explicitly specialized generic call" {
    // Core §12.3: `identity::[int32](42)` is frontend.compile-time specialization
    // syntax; the call lowers to the concrete monomorphic function.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn identity[T](move value: T) -> T { move value }
            \\fn main() -> void { let x = identity::[int32](42); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.identity") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.identity") != null);
}

test "frontend rejects moving an unknown binding" {
    // Core §10.4: `move` names a complete local binding.
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { let x = move nope; }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "move of unknown binding") != null);
}

test "frontend rejects dropping an unknown binding" {
    // Core §9.4: explicit drop applies only to an owning unique local.
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { drop nope; }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "drop of unknown binding") != null);
}

test "frontend lowers builtin.range and builtin.len with generics" {
    // Core §12.2: inferred specialization resolves `len[T]` against the
    // concrete `list[int32]` from `range` (Runtime §4.3–§4.4).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    let n = builtin.len(builtin.range(0, 5));
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#range") != null);
}

test "frontend lowers a never-returning call to a trap path" {
    // Core §13.2 / Runtime §7.1: `never` coerces to any type; a panic
    // call terminates the block (trap), so the if/else join type-checks.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn die() -> never { builtin.panic("x") }
            \\fn main() -> void {
            \\    let r = if (true) { 1 } else { die() };
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#panic") != null);
    try testing.expect(std.mem.indexOf(u8, out, "trap") != null);
}

test "frontend rejects indexing a non-list" {
    // Core §11.5: indexing applies to lists.
    var c = try compileText("app", &.{
        .{ "app", "fn f(x: int32) -> int32 { x@[0] }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "indexing requires a list") != null);
}

test "frontend rejects calling a non-function value" {
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { let x = 42; x(); }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "calling a non-function") != null);
}

test "frontend rejects an unknown module member" {
    var c = try compileText("app", &.{
        .{ "calc", "fn add(a: int32, b: int32) -> int32 { a + b }" },
        .{ "app", "const calc = import(\"calc\");\nfn main() -> void { let x = calc.sub(1, 2); }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "no member") != null);
}

test "frontend resolves chained module-valued member calls" {
    // Core §2.7: `std.math.sqrt` is chained value-member access through
    // nested module-valued consts.
    var c = try compileText("app", &.{
        .{ "std", "const math = import(\"math\");\n" },
        .{
            "app",
            \\const std = import("std");
            \\fn main() -> void { let x = std.math.sqrt(16.0); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall math#sqrt") != null);
}

// ---------------------------------------------------------------------------
// P0/P1 regressions: join-phi ownership, short-circuit never operands, op
// emission, and ownership-transfer lowering.
// ---------------------------------------------------------------------------

/// The printed body of one function (after its `func @…` header, before
/// the closing brace), or "" when the header is absent.
fn funcBody(out: []const u8, header: []const u8) []const u8 {
    const hs = std.mem.indexOf(u8, out, header) orelse return "";
    const brace = std.mem.indexOfScalar(u8, out[hs..], '{').? + hs;
    const body_start = brace + 1;
    const body_end = std.mem.indexOf(u8, out[body_start..], "\n    }").? + body_start;
    return out[body_start..body_end];
}

/// The number of non-overlapping occurrences of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        n += 1;
        rest = rest[i + needle.len ..];
    }
    return n;
}

test "frontend join phis own their unique inputs (if, return case)" {
    // ir.md §6.3-§6.4: an unique value listed as a phi input is *not*
    // destroyed at the end of its producing block; the phi result is the
    // single owner. A regression: the branch values %2/%4 were dropped in
    // the join block and then the phi result %5 was returned — a triple
    // destruction / use-after-return. Now the choose body must contain no
    // drop at all: inputs consumed by the phi, result transferred by ret.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\fn open_file(path: str) -> File { File{ fd: 3, path: path } }
            \\fn choose(c: bool) -> File {
            \\    if (c) { open_file("a") } else { open_file("b") }
            \\}
            \\fn main() -> void {}
        },
    });
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\fn open_file(path: str) -> File { File{ fd: 3, path: path } }
            \\union MaybeFile { Some(File), None }
            \\fn pick(m: MaybeFile) -> File {
            \\    match (m) {
            \\        MaybeFile::Some(f) => f,
            \\        MaybeFile::None => open_file("x")
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.pick");
    try testing.expect(std.mem.indexOf(u8, body, "phi") != null);
    // The only destruction in pick is the non-moved scrutinee %0 at scope
    // end — as a conditional-release candidate it is destroyed through its
    // cleanup token (ir.md §6.4), never by a plain drop of a phi input.
    try testing.expect(std.mem.indexOf(u8, body, "drop %2") == null);
    try testing.expect(std.mem.indexOf(u8, body, "drop %4") == null);
    try testing.expect(std.mem.indexOf(u8, body, "drop %5") == null);
    try testing.expect(std.mem.indexOf(u8, body, "drop_cleanup") != null);
}

test "frontend join phis own their unique inputs (let case: one drop)" {
    // `let f = if (c) { … } else { … }`: the phi result is the owned
    // binding, so it receives exactly one scope-end drop; the phi inputs
    // (%2, %4) are consumed by the join and must not be dropped.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\fn open_file(path: str) -> File { File{ fd: 3, path: path } }
            \\fn main() -> void {
            \\    let c = true;
            \\    let f = if (c) { open_file("a") } else { open_file("b") };
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.main");
    // Exactly one drop (the phi result); none of the phi inputs.
    var drops: usize = 0;
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "drop %") != null) drops += 1;
    }
    try testing.expectEqual(@as(usize, 1), drops);
    try testing.expect(std.mem.indexOf(u8, body, "drop %2") == null);
    try testing.expect(std.mem.indexOf(u8, body, "drop %4") == null);
}

test "frontend lowers a and die() and a or die() without a crash" {
    // A never right operand traps inside the rhs block: the rhs side then
    // contributes no phi input and no edge to the join, and the join still
    // receives the const arm. Regression: the compiler segfaulted on an
    // unterminated rhs-eval block (exit 134).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn die() -> never { builtin.panic("x") }
            \\fn f(a: bool) -> bool { a and die() }
            \\fn g(a: bool) -> bool { a or die() }
            \\fn main() -> void {}
        },
    });
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn die() -> never { builtin.panic("x") }
            \\fn f(a: bool) -> bool { die() and a }
            \\fn g(a: bool) -> bool { die() or a }
            \\fn main() -> void {}
        },
    });
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
    // in-edges (built in block-id order, ir.md §4.3) never matched and the
    // compiler rejected the program with "phi incoming order does not
    // match predecessors" (and the never variants segfaulted).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn die() -> never { builtin.panic("x") }
            \\fn f(a: bool, b: bool, c: bool) -> bool { a and (b and c) }
            \\fn g(a: bool, b: bool) -> bool { a and (b or die()) }
            \\fn main() -> void {}
        },
    });
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn pick(a: bool, b: bool, x: int32, y: int32, z: int32) -> int32 {
            \\    if (a) { if (b) { x } else { y } } else { z }
            \\}
            \\fn main() -> void {}
        },
    });
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
    var c = try compileText("app", &.{
        .{
            "app",
            \\union U { A(int32), B(bool) }
            \\fn pick(u: U, d: int32) -> int32 {
            \\    match (u) {
            \\        U::A(n) => if (n > 0) { n } else { d },
            \\        U::B(b) => if (b) { 1 } else { 0 }
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.pick");
    // The match join's phi inputs come from the two inner join blocks.
    try testing.expect(std.mem.indexOf(u8, body, ", join_1]") != null);
    try testing.expect(std.mem.indexOf(u8, body, ", join_2]") != null);
}

test "frontend emits unary and comparison ops" {
    // Core §16.3 / ir.md §5: neg, not, and the six comparisons are
    // instructions in the IR; the frontend emits them but no test pinned
    // the opcodes before.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn neg_(a: int32) -> int32 { -a }
            \\fn not_(a: bool) -> bool { !a }
            \\fn lt(a: int32, b: int32) -> bool { a < b }
            \\fn le(a: int32, b: int32) -> bool { a <= b }
            \\fn gt(a: int32, b: int32) -> bool { a > b }
            \\fn ge(a: int32, b: int32) -> bool { a >= b }
            \\fn ne(a: int32, b: int32) -> bool { a != b }
            \\fn main() -> void {}
        },
    });
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
    // Core §14.6 / ir.md §5.4: a consuming destructure is one atomic
    // multi-result op per kind — `unpack_variant` (tag-carrying),
    // `unpack_struct`, `unpack_tuple`, `split_list` — and a non-consuming
    // list pattern's rest binds a borrowed `tail` view (Core §14.5).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\fn open_file(path: str) -> File { File{ fd: 3, path: path } }
            \\union Result { Ok(File), Err(str) }
            \\fn take(r: Result) -> File {
            \\    match (move r) { Result::Ok(f) => f, Result::Err(e) => open_file(e) }
            \\}
            \\struct Wrapper { inner: File; tag: int32; }
            \\fn unwrap(w: Wrapper) -> File {
            \\    let Wrapper { inner, tag } = move w;
            \\    inner
            \\}
            \\fn take_t(t: tuple[File, int32]) -> File {
            \\    let (f, n) = move t;
            \\    f
            \\}
            \\fn tail(xs: list[int32]) -> list[int32] {
            \\    let [h ..rest] = xs;
            \\    rest
            \\}
            \\fn main() -> void { builtin.print("x"); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = unpack_variant %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = unpack_struct %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = unpack_tuple %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = tail %") != null);
}

test "frontend IR round-trips nested joins and fib-style control flow" {
    // Regression (round 3): makeJoinPhi orders phi inputs by block
    // *creation* id, but the printer orders blocks by min-value-id with
    // value-less blocks last, so a printed phi could list its inputs in a
    // different order than its pred blocks appear in the text — the
    // standalone parser recomputes predecessors in text order and
    // rejected the re-parse with "phi incoming order does not match
    // predecessors". Covers the nested short-circuit / nested if / nested
    // match shapes plus a fib-style function whose `then` block is
    // value-less (bare `br join`) and therefore prints last.
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

test "frontend lowers nested all-trap branches without a crash" {
    // Regression (round 3): when every branch/arm traps, the join is
    // unreachable. It used to be removed by popping "the last block",
    // which is wrong once a nested trapped branch created blocks after
    // the join — the join survived with an undefined terminator and
    // finishFunc aborted (index out of bounds). The join and the trapped
    // subtree are now kept as trap-terminated dead blocks.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn die() -> never { builtin.panic("x") }
            \\fn f(c: bool, d: bool) -> void {
            \\    if (c) { if (d) { die() } else { die() } } else { die() }
            \\}
            \\fn g(c: bool) -> void { if (c) { die() } else { die() } }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.debug.print("frontend.compile failed: {any}\n", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    const f_body = funcBody(out, "func @app.f");
    try testing.expect(std.mem.indexOf(u8, f_body, "trap") != null);
    // The dead joins are trap-terminated: `join:` / `join_1:` end in trap.
    try testing.expect(std.mem.indexOf(u8, f_body, "join:\n        trap") != null);
}

// ---------------------------------------------------------------------------
// Pass 7 — tail call elimination (frontend.md §7)
// ---------------------------------------------------------------------------

test "Pass 7 rewrites a self-recursive tail call into a loop" {
    // `countdown` calls itself in tail position: the else arm's call is the
    // last instruction before the join, and its result flows through the
    // join's single phi straight into the `ret` (§7.1). TCO turns the call
    // into a branch back to the entry, which becomes a loop header with a
    // param phi merging the entry value and the loop-back argument; a
    // no-pred trampoline forwards the entry so the text form's first block
    // keeps no predecessors (ir.md §13). Values are renumbered in text
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
    try testing.expect(std.mem.indexOf(u8, text, "    entry:\n        br header") != null);
    // ...which opens with the param phi merging the entry value (%0) and
    // the loop-back argument...
    try testing.expect(std.mem.indexOf(u8, text, "        %1: int32 = phi [%0, entry], [") != null);
    // ...and the recursive call is gone: the tail block branches back.
    try testing.expect(std.mem.indexOf(u8, text, "call @app.countdown") == null);
    try testing.expect(std.mem.indexOf(u8, text, "br header") != null);

    // The rewritten text round-trips through the standalone cfg parser
    // (ir.md §13): the header phi has one incoming per predecessor.
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
    try testing.expect(std.mem.indexOf(u8, text, "    entry:\n        br header") != null);
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
    try testing.expect(std.mem.indexOf(u8, text, "br header") == null);

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
    try testing.expect(std.mem.indexOf(u8, ftext, "ret %11") != null);
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
    try testing.expect(std.mem.indexOf(u8, text, "br header") == null);
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
    try testing.expect(std.mem.indexOf(u8, text, "br header") == null);
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
    try testing.expect(std.mem.indexOf(u8, text, "br header") == null);
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
    try testing.expect(std.mem.indexOf(u8, text, "br header") == null);
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
    try testing.expect(std.mem.indexOf(u8, text, "br header") == null);
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
    try testing.expect(std.mem.indexOf(u8, text, "br header") == null);
}

test "Pass 7 runs before the Pass 8 pipeline" {
    // frontend.md §8: the optimizer runs Pass 7 before Pass 8. `optimize`
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
    try testing.expect(std.mem.indexOf(u8, text, "    entry:\n        br header") != null);
    try testing.expect(std.mem.indexOf(u8, text, "call @app.countdown") == null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

// ---------------------------------------------------------------------------
// Pass 8.1 — constant folding (frontend.md §8.1)
// ---------------------------------------------------------------------------

test "Pass 8.1 folds constant arithmetic, comparison, and logic" {
    // 3 * 2 = 6, 6 + 5 = 11, 11 > 2 = true, !true = false — each rewritten
    // to a const instruction in place; ids and block structure are
    // unchanged (frontend.md §8.1).
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

test "Pass 8.1 leaves trap-preserving expressions unfolded" {
    // Runtime §7.2: folding must never turn a runtime trap into a value.
    // Division/remainder by zero, int32/uint32 overflow, neg of minInt,
    // minInt div/rem -1, and uint32 negation (whose trap behavior the
    // specs do not pin down) all stay as ops.
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
    try testing.expect(instrs[2].op == .div);
    try testing.expect(instrs[4].op == .rem);
    try testing.expect(instrs[6].op == .add);
    try testing.expect(instrs[8].op == .neg);
    try testing.expect(instrs[9].op == .sub);
    try testing.expect(instrs[10].op == .mul);
    try testing.expect(instrs[12].op == .div);
    try testing.expect(instrs[13].op == .rem);
    try testing.expect(instrs[15].op == .add);
    try testing.expect(instrs[17].op == .neg);
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
    // int32 and float32 neg fold; neg of minInt and of uint32 do not.
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

test "Pass 8.1 leaves trap-preserving num_casts unfolded" {
    // Only int32 as float32 and float32 as int32 are core conversions
    // (Core §16.3). Casting a float to int32 traps on infinity and NaN
    // (Runtime §7.2) — even when the float is itself a folded division —
    // and on values at or beyond 2^31, so all of those stay unfolded.
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
    // The casts of ±inf, NaN, and 2^31 stay unfolded (they would trap).
    try testing.expect(instrs[3].op == .num_cast);
    try testing.expect(instrs[6].op == .num_cast);
    try testing.expect(instrs[8].op == .num_cast);
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

test "Pass 8.1 folded IR round-trips through the standalone cfg parser" {
    // Folding rewrites ops in place (no new values, no id gaps), so the
    // printed text still re-parses and re-prints identically (ir.md §13).
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
// On-the-fly common subexpression elimination at construction (frontend.md
// §4.3) — the frontend has no separate CSE pass (braun13cc.pdf §3.1): an
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
    // `read_index` or `cast` in the same block is computed once.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(xs: list[int32], i: int32) -> float32 {
            \\    let a = xs@[i];
            \\    let b = xs@[i];
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
    // One read_index and one cast, each reused.
    try testing.expect(std.mem.count(u8, out, "read_index %0, %1") == 1);
    try testing.expect(std.mem.count(u8, out, "cast %2") == 1);
    try testing.expect(std.mem.indexOf(u8, out, "add %3, %3") != null);
}

test "frontend does not CSE unique results" {
    // Reusing an unique value twice would change the destruction
    // schedule (ir.md §6.4): `h.file` (result type File, unique) is
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

test "construction-time optimized IR round-trips through the standalone cfg parser" {
    // The on-the-fly rewrites happen at construction; the printed text
    // re-parses and re-prints identically (ir.md §13).
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

// Pass 8.3 — partial redundancy elimination (frontend.md §8.3)
// ---------------------------------------------------------------------------

test "Pass 8.3 hoists a partially redundant comparison into a join phi" {
    // `lt %0, %1` runs on the `neg` edge but not on `pos`, so the join's
    // copy is partially redundant: PRE inserts the computation at the end
    // of `pos` and turns the join's computation into a phi (frontend.md
    // §8.3).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    br join
        \\neg:
        \\    %3: bool = lt %0, %1
        \\    br join
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
        \\    br join
        \\neg:
        \\    %4: bool = lt %0, %1
        \\    br join
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
        \\    br join
        \\neg:
        \\    br join
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
        \\    br join
        \\b2:
        \\    br join
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
    // `mul` can overflow (Runtime §7.2); moving it onto a path that never
    // ran it would change observable behavior, so PRE never hoists it.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    %3: int32 = mul %0, %1
        \\    br join
        \\neg:
        \\    br join
        \\join:
        \\    %4: int32 = mul %0, %1
        \\    ret %4
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.pre(&t.program, t.arena.allocator());

    const blocks = t.program.funcs[0].blocks;
    try testing.expectEqual(@as(usize, 0), blocks[2].instrs.len);
    try testing.expectEqual(@as(usize, 1), blocks[3].instrs.len);
    try testing.expect(blocks[3].instrs[0].op == .mul);
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
        \\    %2: int32 = syscall builtin#peek, %0
        \\    br join
        \\neg:
        \\    br join
        \\join:
        \\    %3: int32 = syscall builtin#peek, %0
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
        \\    br njoin
        \\nneg:
        \\    br njoin
        \\njoin:
        \\    %4: bool = not %1
        \\    br %4 ? tpos : tneg
        \\tpos:
        \\    %5: bool = type_is %2, int32
        \\    br tjoin
        \\tneg:
        \\    br tjoin
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

test "Pass 8.3 optimized IR round-trips through the standalone cfg parser" {
    // PRE adds values and phis, so the pass renumbers the function's values
    // in text order; the printed text must still re-parse and re-print
    // identically (ir.md §13).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> bool {
        \\entry:
        \\    br %2 ? pos : neg
        \\pos:
        \\    br join
        \\neg:
        \\    %3: bool = lt %0, %1
        \\    br join
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
    // arm already computed and the else arm did not: the compiled IR is
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
// On-the-fly copy elision at construction (frontend.md §4.3) — the frontend
// has no separate copy-propagation pass (braun13cc.pdf §3.1): a `move` of a
// Copy value lowers directly to the value itself (a copy of a
// Copy value is the value, ir.md §5.4), so no `copy` instructions
// reach the IR from the frontend.
// ---------------------------------------------------------------------------

test "frontend emits no copies for Copy moves, keeps move_ for unique" {
    // `consume(move a)` on an int32 is the value itself; `move` of an
    // unique owner still emits `move_` (ownership transfer, ir.md §5.4).
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

// Pass 8.5 — dead-block elimination (frontend.md §8.5)
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
    // keeping incoming order aligned with the survivors (ir.md §4.3).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    br live
        \\live:
        \\    %2: int32 = add %0, %1
        \\    br join
        \\dead:
        \\    %3: int32 = const 42
        \\    br join
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
        \\    br live
        \\live:
        \\    ret %0
        \\dead:
        \\    br deeper
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
    try testing.expect(f.blocks[1] == f.blocks[0].terminator.branch);
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
        \\    br join
        \\neg:
        \\    %4: int32 = sub %0, %1
        \\    br join
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

test "Pass 8.5 optimized IR round-trips through the standalone cfg parser" {
    // Removing blocks removes their values, so the pass renumbers the
    // survivors in text order; the printed text must still re-parse and
    // re-print identically (ir.md §13), with the dead block gone.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    br live
        \\live:
        \\    %2: int32 = add %0, %1
        \\    br join
        \\dead:
        \\    %3: int32 = const 42
        \\    br join
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
    // the printed IR round-tripping through the standalone parser.
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

// ---------------------------------------------------------------------------
// Pass 8.6/8.7/8.8 — the new optimizer passes: drop elision, phi
// simplification, jump threading — plus the Pass 8.9 measurement harness
// over the example corpus.
// ---------------------------------------------------------------------------

fn countInstrs(program: *const cfg.IrProgram) usize {
    var n: usize = 0;
    for (program.funcs) |f| {
        for (f.blocks) |b| n += b.instrs.len;
    }
    return n;
}

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

test "Pass 8.8 jump threading removes an empty forwarding block" {
    // `then:` is a forwarding block (no instructions, `br join`); its
    // edge is redirected to `join` and the join phi's `then` entry is
    // re-keyed to `entry`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    %3: bool = lt %0, %1
        \\    br %3 ? then : else
        \\then:
        \\    br join
        \\else:
        \\    %4: int32 = const 1
        \\    br join
        \\join:
        \\    %5: int32 = phi [%0, then], [%4, else]
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.jumpThread(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "then") == null);
    try testing.expect(std.mem.indexOf(u8, text, "br %3 ? join : else") != null);
    try testing.expect(std.mem.indexOf(u8, text, "phi [%0, entry]") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.8 jump threading skips a candidate with a duplicate-edge risk" {
    // `then:` forwards to `join`, but `entry` already branches to `join`
    // directly; threading would give `entry` two edges to `join`, which
    // the printer's phi ordering cannot distinguish. The skip rule keeps
    // `then` in place, and the program still round-trips.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    %3: bool = lt %0, %1
        \\    %4: int32 = const 1
        \\    br %3 ? then : join
        \\then:
        \\    br join
        \\join:
        \\    %5: int32 = phi [%4, entry], [%0, then]
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.jumpThread(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "then") != null);
    // `entry` already branches to `join`, so threading `then` was
    // skipped: no duplicate predecessor edges were created.
    try testing.expect(std.mem.indexOf(u8, text, "br %3 ? then : join") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification removes single-incoming phis" {
    // `join` has one predecessor, so `%2` is interchangeable with `%1`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32) -> int32 {
        \\entry:
        \\    br join
        \\join:
        \\    %1: int32 = phi [%0, entry]
        \\    %2: int32 = add %1, %1
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "add %0, %0") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification collapses identical-incoming phis" {
    // Both predecessors feed the same value, so `%2` is `%0` everywhere.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    br left
        \\left:
        \\    br join
        \\right:
        \\    br join
        \\join:
        \\    %2: int32 = phi [%0, left], [%0, right]
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %0") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification removes self-referential trivial phis" {
    // braun13cc.pdf Algorithm 3: a phi that references only itself and
    // one other value (a loop-carried value whose back edge passes the
    // header phi through unchanged) is interchangeable with that value.
    // `%2` joins `%1` (entry path) and itself (back edge) → `%1`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    br left
        \\left:
        \\    br join
        \\right:
        \\    br join
        \\join:
        \\    %2: int32 = phi [%1, left], [%2, right]
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %1") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification resolves chains of trivial phis" {
    // The paper's recursive user walk in map form: `%2` is single-
    // incoming and forwards to `%3`; only once that lands does `%3`
    // become trivial (`φ(%1, %3)`), so the pass must iterate. Both phis
    // collapse to `%1`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    br left
        \\left:
        \\    br join
        \\right:
        \\    br inner
        \\inner:
        \\    %2: int32 = phi [%3, right]
        \\    br join
        \\join:
        \\    %3: int32 = phi [%1, left], [%2, inner]
        \\    ret %3
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %1") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification keeps all-self phis" {
    // `φ(vφ, vφ)` is unreachable or in the start block; the IR has no
    // undefined value to forward it to (braun13cc.pdf Algorithm 3's Undef
    // case), so it is kept — forwarding to nothing would change its type.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    br left
        \\left:
        \\    br join
        \\right:
        \\    br join
        \\join:
        \\    %2: int32 = phi [%2, left], [%2, right]
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %2") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.6 drop elision removes Copy drops, keeps unique drops" {
    // A `drop` of a Copy value does nothing and can never run a
    // user hook (type_shape classifies hook-bearing structs unique), so
    // it is elided. A `drop` of an unique value (`hostdata`, `any`) may
    // run a user hook or hand a payload to the host, so it is kept even
    // though nothing observes it (ir.md §14 — the print-hook guard).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: hostdata) -> void {
        \\entry:
        \\    drop %0
        \\    drop %1
        \\    ret
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.dropElide(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    // `a: int32` is Copy: its drop does nothing and is elided.
    try testing.expect(std.mem.indexOf(u8, text, "drop %0") == null);
    // `b: hostdata` is unique: its drop may run a user hook, kept.
    try testing.expect(std.mem.indexOf(u8, text, "drop %1") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.4 module/member CSE reuses identical loads in a block" {
    // `m.pi` lowers to `module_ref "math"` + `load_member`, and the
    // on-the-fly CSE never shared them (module ops are not candidates at
    // emit time), so two reads of the same member in one block stay as
    // two loads until this pass. The module handle is a pure constant
    // and module storage is written only by `store_member` inside @init
    // (cfg_validate rejects stores elsewhere), so both fold to one.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const m = import("math");
            \\fn f() -> float32 {
            \\    let a = m.pi;
            \\    let b = m.pi;
            \\    a + b
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.cse(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.f");
    try testing.expect(countOccurrences(body, "module_ref \"math\"") == 1);
    try testing.expect(countOccurrences(body, "load_member") == 1);
}

test "Pass 8.4 copy propagation collapses copies of Copy values" {
    // The checker emits an explicit `copy` of the move parameter before
    // the ret; for a Copy type `move` is semantically an ordinary copy
    // (Core §10.2), so the copy is a no-op and the parameter is returned
    // directly.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn id(move x: T) -> T { x }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.copyProp(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.id");
    try testing.expect(std.mem.indexOf(u8, body, "copy %") == null);
    try testing.expect(std.mem.indexOf(u8, body, "ret %0") != null);
}

test "Pass 8.4 copy propagation collapses box round-trip copies" {
    // The checker's state tracking emits explicit `copy` instructions on
    // the `move t` of a box whose payload is a plain struct (a Copy
    // type): `copy %b; copy %copy; unbox`. The mid-level pass collapses
    // the chain into a direct `unbox` of the box (Core §10.2 — `move` of
    // a Copy value is an ordinary copy and may be omitted).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct Token { id: int32; }
            \\fn main() -> void {
            \\    let b = builtin.box::[int32](42);
            \\    let view = builtin.peek::[int32](b);
            \\    builtin.assert(view == 42, "peek");
            \\    let v = builtin.unbox::[int32](move b);
            \\    builtin.assert(v == 42, "unbox");
            \\    let t = builtin.box::[Token](Token { id: 7 });
            \\    let t2 = builtin.unbox::[Token](move t);
            \\    builtin.assert(t2.id == 7, "round-trip");
            \\}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    const before = try irText(&program);
    defer testing.allocator.free(before);
    try testing.expect(std.mem.indexOf(u8, funcBody(before, "func @app.main"), "copy %") != null);

    try lower.copyProp(&program, c.arena.allocator());
    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "copy %") == null);
    try testing.expect(std.mem.indexOf(u8, body, "builtin#unbox") != null);
}

test "Pass 8.4 dead-instruction elimination drops unused match payloads" {
    // A `match` arm that binds the payload but returns a constant reads
    // the payload without using it: the `read_payload` is dead. It is a
    // guarded projection (the lowering emits it only after the tag
    // switch) with a Copy result, so the pass removes it.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\using builtin.Option;
            \\fn is_some(o: Option[int32]) -> bool {
            \\    match (o) {
            \\        Option::Some(v) => true,
            \\        Option::None => false,
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    const before = try irText(&program);
    defer testing.allocator.free(before);
    const before_body = funcBody(before, "func @app.is_some");
    try testing.expect(std.mem.indexOf(u8, before_body, "read_payload") != null);

    try lower.deadInstr(&program, c.arena.allocator());
    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.is_some");
    try testing.expect(std.mem.indexOf(u8, body, "read_payload") == null);
}

test "Pass 8.9 optimization harness: corpus compile, optimize, and measure" {
    // Compiles each example in the optimizer corpus once without and once
    // with the optimizer, printing instruction / block / text-byte counts
    // (frontend.md §8.9). The optimizer must never grow the CFG, and the
    // optimized IR must re-parse and re-print identically (ir.md §13).
    const corpus = [_][]const u8{
        "examples/fib.st",
        "examples/fib_tail_call.st",
        "examples/ownership.st",
        "examples/match.st",
        "examples/strings.st",
        "examples/floats.st",
        "examples/fold.st",
        "examples/box.st",
        "examples/maps.st",
        "examples/generics.st",
    };
    const io = std.testing.io;
    for (corpus) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(src);

        var raw = try compileText("app", &.{.{ "app", src }});
        defer raw.deinit();
        const raw_text = try irText(&raw.program.?);
        defer testing.allocator.free(raw_text);

        var opt = try compileText("app", &.{.{ "app", src }});
        defer opt.deinit();
        try lower.optimize(&opt.program.?, opt.arena.allocator());
        const opt_text = try irText(&opt.program.?);
        defer testing.allocator.free(opt_text);

        const before_instrs = countInstrs(&raw.program.?);
        const before_nonphi = countNonPhi(&raw.program.?);
        const before_blocks = countBlocks(&raw.program.?);
        const after_instrs = countInstrs(&opt.program.?);
        const after_nonphi = countNonPhi(&opt.program.?);
        const after_blocks = countBlocks(&opt.program.?);
        // Report the measurement only when stderr reaches a human: under
        // `zig build test` stderr is a captured pipe, and the build runner
        // replays any run-step stderr as an error (a spurious "failed
        // command:" line), so the report is gated on stderr being a TTY.
        if (std.Io.File.stderr().isTty(std.testing.io) catch false) {
            std.debug.print(
                "harness {s}: {d} instr ({d} non-phi) {d} blocks {d} bytes -> {d} instr ({d} non-phi) {d} blocks {d} bytes\n",
                .{ path, before_instrs, before_nonphi, before_blocks, raw_text.len, after_instrs, after_nonphi, after_blocks, opt_text.len },
            );
        }

        // TCO legitimately trades a tail call for a loop with parameter
        // phis, so the invariant is on non-phi instructions. Blocks may
        // grow by exactly one: a consuming empty-case arm (the `[]` split
        // of a moved list) cannot fold into the loop header, which the
        // header's addition makes reachable as a separate block.
        try testing.expect(after_nonphi <= before_nonphi);
        try testing.expect(after_blocks <= before_blocks + 1);

        var p = cfg.Parser.init(testing.allocator);
        defer p.deinit();
        const reparsed = try p.parse(opt_text);
        const text2 = try irText(&reparsed);
        defer testing.allocator.free(text2);
        try testing.expectEqualStrings(opt_text, text2);
    }
}

test "frontend dispatches a two-arm list match on an emptiness test" {
    // Core §14.5: `[]` matches only the empty list, so a `match (xs) {
    // [] => A, [_, ..tail] => B }` must test emptiness and dispatch —
    // the `[]` arm is refutable, never an unconditional fallthrough.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn count_list(xs: list[int32]) -> int32 {
            \\    match (xs) {
            \\        [] => 0,
            \\        [_, ..tail] => 1 + count_list(tail),
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.count_list");
    // The emptiness test: `builtin#len` of the scrutinee == 0, then a
    // conditional dispatch — the `[]` arm must not be reachable
    // unconditionally.
    try testing.expect(std.mem.indexOf(u8, body, "syscall builtin#len") != null);
    try testing.expect(std.mem.indexOf(u8, body, "br %") != null);
    try testing.expect(std.mem.indexOf(u8, body, " ? ") != null);
}
