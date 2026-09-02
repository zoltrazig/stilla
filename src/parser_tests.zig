//! Test file: `parser` — the recursive-descent parser.
//!
//! White-box tests of `src/parser.zig`'s own internals stay in that module's
//! file; this file aggregates them (with the split grammar passes under
//! `src/parse/`) so they are analyzed and run, and adds black-box tests of
//! the public `Parser` API: complete program shapes, host-binding
//! declarations, and error diagnostics.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const testing = std.testing;

test {
    // White-box tests of the module files in this slice.
    _ = @import("parser.zig");
    _ = @import("parse/type.zig");
    _ = @import("parse/expr.zig");
    _ = @import("parse/stmt.zig");
    _ = @import("parse/pattern.zig");
}

// ---------------------------------------------------------------------------
// parser — black-box: the public `Parser` API over whole source texts.
// ---------------------------------------------------------------------------

fn parseText(text: []const u8) !struct { arena: std.heap.ArenaAllocator, source: *const ast.Source, program: ast.Program } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
    var p = parser.Parser.init(arena.allocator());
    const program = try p.parse(source);
    return .{ .arena = arena, .source = source, .program = program };
}

fn parseError(text: []const u8) !struct { arena: std.heap.ArenaAllocator, diag: ast.Diagnostic } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
    var p = parser.Parser.init(arena.allocator());
    try testing.expectError(error.Syntax, p.parse(source));
    return .{ .arena = arena, .diag = p.diag.? };
}

test "parser black-box: parses every module-item kind in one program" {
    const text =
        \\const version: int32 = 1;
        \\type Size = int32;
        \\struct Point { x: int32; y: int32; }
        \\union Result { Ok(int32), Err(str) }
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn add(a: int32, b: int32) -> int32 { a + b }
        \\fn main() -> void {}
    ;
    var t = try parseText(text);
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 8), t.program.items.len);
    try testing.expect(t.program.items[0] == .const_def);
    try testing.expect(t.program.items[1] == .type_def);
    try testing.expect(t.program.items[2] == .struct_def);
    try testing.expect(t.program.items[3] == .union_def);
    try testing.expect(t.program.items[4] == .const_def);
    try testing.expect(t.program.items[5] == .using_decl);
    try testing.expect(t.program.items[6] == .func_def);
    try testing.expect(t.program.items[7] == .func_def);
}

test "parser black-box: host-binding declarations parse without bodies" {
    // A declaration without a body or initializer is a host binding (phase3-cfg-lowering.md, System calls for host bindings)
    // binding (`builtin.str[T]` etc., Runtime §4).
    const text = "fn str[T](value: T) -> str;\nconst max_int32: int32;\n";
    var t = try parseText(text);
    defer t.arena.deinit();

    const f = switch (t.program.items[0]) {
        .func_def => |f| f,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(f.body == null);
    try testing.expectEqual(@as(usize, 1), f.type_params.len);
    try testing.expectEqualStrings("T", f.type_params[0].text);
    const c = switch (t.program.items[1]) {
        .const_def => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(c.init == null);
    try testing.expect(c.type_ != null);
}

test "parser black-box: a reserved-word function name with a body is an error" {
    var t = try parseError("fn if() -> void {}");
    defer t.arena.deinit();
    try testing.expect(std.mem.indexOf(u8, t.diag.message, "reserved word") != null);
}

test "parser black-box: a syntax error reports a diagnostic with a real span" {
    var t = try parseError("fn main() -> void { let x = ; }");
    defer t.arena.deinit();
    // The diagnostic points into the source (not span 0, the module 1:1).
    try testing.expect(t.diag.span.start != 0);
    try testing.expect(t.diag.message.len > 0);
}

test "parser black-box: every independent error in a file surfaces in one run" {
    // Panic-mode recovery: a malformed statement/item is dropped (its
    // diagnostic recorded) and parsing resynchronizes at the next
    // statement/item boundary, so independent errors across a file —
    // including inside nested blocks — all surface in one run, in
    // source order, with the first-error accessor naming the first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(
        arena.allocator(),
        "test.st",
        0,
        \\fn f(x: int32) -> int32 {
        \\    let a = ;
        \\    if (x > 0) {
        \\        let b = 1 +;
        \\        x
        \\    } else {
        \\        let c = ;
        \\        -x
        \\    }
        \\}
        \\const d = ;
        ,
    );
    var p = parser.Parser.init(arena.allocator());
    try testing.expectError(error.Syntax, p.parse(source));
    try testing.expectEqual(@as(usize, 4), p.diags.items.len);
    for (p.diags.items) |d| try testing.expectEqualStrings("expected an expression, found ';'", d.message);
    try testing.expectEqualStrings("expected an expression, found ';'", p.diag.?.message);
    // Spans are source-exact (the failing `;` tokens, not the module 1:1).
    try testing.expect(p.diags.items[1].span.start != 0);
}

test "parser black-box: recovery does not unbalance the enclosing block" {
    // An error inside a nested block expression must not consume the
    // enclosing function body's brace: the statements after the failing
    // one still parse, and a clean tail stays clean.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(
        arena.allocator(),
        "test.st",
        0,
        \\fn f() -> void {
        \\    let a = { let b = ; };
        \\    let c = 1;
        \\}
        \\const d = ;
        ,
    );
    var p = parser.Parser.init(arena.allocator());
    try testing.expectError(error.Syntax, p.parse(source));
    try testing.expectEqual(@as(usize, 2), p.diags.items.len);
    try testing.expectEqualStrings("expected an expression, found ';'", p.diags.items[0].message);
    try testing.expectEqualStrings("expected an expression, found ';'", p.diags.items[1].message);
}

test "parser black-box: shifts sit between additive and comparison precedence" {
    // `a + b << c` parses as `(a + b) << c` and `a << b + c` as
    // `a << (b + c)` — additive binds tighter than shift, shift tighter
    // than comparison (like C and Zig; Core §16.3). The shift level is
    // left-associative, so `a << b << c` nests left.
    const text =
        \\fn f(a: int32, b: int32, c: int32) -> int32 { a + b << c }
        \\fn g(a: int32, b: int32, c: int32) -> int32 { a << b + c }
        \\fn h(a: int32, b: int32, c: int32) -> bool { a << b < c }
        \\fn k(a: int32, b: int32, c: int32) -> int32 { a << b << c }
        \\fn main() -> void {}
    ;
    var t = try parseText(text);
    defer t.arena.deinit();

    // f: shl(add(a,b), c)
    const f_body = t.program.items[0].func_def.body.?;
    const f_expr = f_body.result.?;
    try testing.expectEqual(ast.BinaryOp.shl, f_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.add, f_expr.binary.lhs.binary.op);

    // g: shl(a, add(b,c))
    const g_body = t.program.items[1].func_def.body.?;
    const g_expr = g_body.result.?;
    try testing.expectEqual(ast.BinaryOp.shl, g_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.add, g_expr.binary.rhs.binary.op);

    // h: lt(shl(a,b), c) — the comparison is non-associative and above
    // the shift level.
    const h_body = t.program.items[2].func_def.body.?;
    const h_expr = h_body.result.?;
    try testing.expectEqual(ast.BinaryOp.lt, h_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.shl, h_expr.binary.lhs.binary.op);

    // k: shl(shl(a,b), c) — left-associative.
    const k_body = t.program.items[3].func_def.body.?;
    const k_expr = k_body.result.?;
    try testing.expectEqual(ast.BinaryOp.shl, k_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.shl, k_expr.binary.lhs.binary.op);
}

test "parser black-box: bitwise ops sit between comparison and shift precedence" {
    // `a | b ^ c` parses as `a | (b ^ c)` and `a & b | c` as
    // `(a & b) | c` — `|` is the loosest of the three bitwise
    // operators, `&` the tightest (Core §16.1). All three sit between
    // comparison and shift: `a & b == c` is `(a & b) == c` (bitwise
    // binds tighter than comparison) and `a & b << c` is `a & (b << c)`
    // (shift binds tighter than bitwise).
    const text =
        \\fn f(a: int32, b: int32, c: int32) -> int32 { a | b ^ c }
        \\fn g(a: int32, b: int32, c: int32) -> int32 { a & b | c }
        \\fn h(a: int32, b: int32, c: int32) -> bool { a & b == c }
        \\fn k(a: int32, b: int32, c: int32) -> int32 { a & b << c }
        \\fn m(a: int32, b: int32, c: int32) -> int32 { a | b | c }
        \\fn main() -> void {}
    ;
    var t = try parseText(text);
    defer t.arena.deinit();

    // f: bitor(a, bitxor(b, c)) — `|` loosest, `^` middle.
    const f_body = t.program.items[0].func_def.body.?;
    const f_expr = f_body.result.?;
    try testing.expectEqual(ast.BinaryOp.bitor, f_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.bitxor, f_expr.binary.rhs.binary.op);

    // g: bitor(bitand(a,b), c) — `&` tighter than `|`.
    const g_body = t.program.items[1].func_def.body.?;
    const g_expr = g_body.result.?;
    try testing.expectEqual(ast.BinaryOp.bitor, g_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.bitand, g_expr.binary.lhs.binary.op);

    // h: eq(bitand(a,b), c) — bitwise tighter than comparison.
    const h_body = t.program.items[2].func_def.body.?;
    const h_expr = h_body.result.?;
    try testing.expectEqual(ast.BinaryOp.eq, h_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.bitand, h_expr.binary.lhs.binary.op);

    // k: bitand(a, shl(b,c)) — shift tighter than bitwise.
    const k_body = t.program.items[3].func_def.body.?;
    const k_expr = k_body.result.?;
    try testing.expectEqual(ast.BinaryOp.bitand, k_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.shl, k_expr.binary.rhs.binary.op);

    // m: bitor(bitor(a,b), c) — left-associative.
    const m_body = t.program.items[4].func_def.body.?;
    const m_expr = m_body.result.?;
    try testing.expectEqual(ast.BinaryOp.bitor, m_expr.binary.op);
    try testing.expectEqual(ast.BinaryOp.bitor, m_expr.binary.lhs.binary.op);
}
