//! Test file: `ast` — source spans, locations, and AST nodes.
//!
//! White-box tests of `src/ast.zig`'s own internals stay in that module's
//! file; this file aggregates them so they are analyzed and run, and adds
//! black-box tests of the public API: `Span` arithmetic, `Source` line
//! indexing, and (driven through the parser) the invariant that every node
//! span slices the original source text.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const testing = std.testing;

test {
    // White-box tests of the module file in this slice.
    _ = @import("ast.zig");
}

// ---------------------------------------------------------------------------
// black-box: the public API of `ast`, plus span-slicing invariants
// exercised through the parser (a program must parse before its nodes can
// be sliced).
// ---------------------------------------------------------------------------

fn parseProgram(text: []const u8) !struct { arena: std.heap.ArenaAllocator, source: *const ast.Source, program: ast.Program } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
    var p = parser.Parser.init(arena.allocator());
    const program = try p.parse(source);
    return .{ .arena = arena, .source = source, .program = program };
}

test "ast.Span measures and merges byte ranges" {
    var s = ast.Span.init(0, 3, 10);
    try testing.expectEqual(@as(u32, 7), s.len());
    const m = ast.Span.merge(ast.Span.init(0, 5, 12), ast.Span.init(0, 1, 8));
    try testing.expectEqual(@as(u32, 1), m.start);
    try testing.expectEqual(@as(u32, 12), m.end);
    try testing.expectEqual(@as(u32, 0), m.source);
}

test "ast.Source builds a line index and locOf maps byte offsets" {
    // `fn f() {\n  let x = 1;\n}`: line 1 is [0,9), line 2 [9,22),
    // line 3 [22,24).
    const text = "fn f() {\n  let x = 1;\n}";
    var src = try ast.Source.init(testing.allocator, "test.st", 0, text);
    defer src.deinit(testing.allocator);

    try testing.expectEqual(ast.Loc{ .line = 1, .column = 1 }, src.locOf(0));
    try testing.expectEqual(ast.Loc{ .line = 1, .column = 9 }, src.locOf(8));
    try testing.expectEqual(ast.Loc{ .line = 2, .column = 1 }, src.locOf(9));
    try testing.expectEqual(ast.Loc{ .line = 2, .column = 3 }, src.locOf(11));
    try testing.expectEqual(ast.Loc{ .line = 3, .column = 1 }, src.locOf(22));
    // An offset past the end of the text lands on the final line.
    try testing.expectEqual(ast.Loc{ .line = 3, .column = 2 }, src.locOf(23));
}

test "ast node spans slice the original source text (expr, type, pattern)" {
    const text =
        \\union Result { Ok(int32), Err(str) }
        \\fn describe(r: Result) -> str {
        \\    match (r) {
        \\        Result::Ok(v) => builtin.str(v),
        \\        Result::Err(e) => e
        \\    }
        \\}
    ;
    var t = try parseProgram(text);
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 2), t.program.items.len);

    // The function definition: name, return type, and body all slice the
    // original text.
    const func = switch (t.program.items[1]) {
        .func_def => |f| f,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("describe", text[func.name.span.start..func.name.span.end]);
    const ret = func.ret;
    try testing.expectEqualStrings("str", text[ret.span().start..ret.span().end]);

    // The body's result is the match expression; its span covers the whole
    // expression.
    const result = func.body.?.result.?;
    try testing.expectEqualStrings("match (r) {\n        Result::Ok(v) => builtin.str(v),\n        Result::Err(e) => e\n    }", text[result.span().start..result.span().end]);
    const match_expr = switch (result) {
        .match => |m| m,
        else => return error.TestUnexpectedResult,
    };
    // The first arm's variant pattern `Result::Ok(v)` slices too.
    const arm0 = match_expr.arms[0];
    try testing.expectEqualStrings("Result::Ok(v)", text[arm0.pattern.span().start..arm0.pattern.span().end]);
}
