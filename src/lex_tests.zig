//! Test file: `lex` — the lexer.
//!
//! White-box tests of `src/lex.zig`'s own internals stay in that module's
//! file; this file aggregates them so they are analyzed and run, and adds
//! black-box tests of the public `Lexer` API: whole-program token streams,
//! token spans slicing the source, two-character operator kinds, and
//! lexical diagnostics.

const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lex.zig");
const testing = std.testing;

test {
    // White-box tests of the module file in this slice.
    _ = @import("lex.zig");
}

// ---------------------------------------------------------------------------
// lex — black-box: the public `Lexer` API over whole source texts.
// ---------------------------------------------------------------------------

fn tokenizeText(text: []const u8) !struct { arena: std.heap.ArenaAllocator, source: *const ast.Source, tokens: []const lex.Token } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
    var lx = lex.Lexer.init(arena.allocator(), source);
    // Tokenize before returning: the returned arena copy must include the
    // allocations made by tokenize.
    const tokens = try lx.tokenize();
    return .{ .arena = arena, .source = source, .tokens = tokens };
}

test "lex black-box: a whole function tokenizes to the expected kinds" {
    const text = "fn add(a: int32, b: int32) -> int32 { a + b }";
    var t = try tokenizeText(text);
    defer t.arena.deinit();

    const kinds = [_]lex.TokenKind{
        .kw_fn, .ident, .lparen,   .ident,  .colon, .kw_int32, .comma,
        .ident, .colon, .kw_int32, .rparen, .arrow, .kw_int32, .lbrace,
        .ident, .plus,  .ident,    .rbrace, .eof,
    };
    try testing.expectEqual(kinds.len, t.tokens.len);
    for (kinds, 0..) |kind, i| try testing.expectEqual(kind, t.tokens[i].kind);
}

test "lex black-box: token spans slice the original source text" {
    const text = "const greeting: str = \"hi\";";
    var t = try tokenizeText(text);
    defer t.arena.deinit();

    // The identifier `greeting` starts at byte 6.
    try testing.expectEqualStrings("greeting", text[t.tokens[1].span.start..t.tokens[1].span.end]);
    // The string token covers the quotes; its text is the decoded value.
    try testing.expectEqualStrings("hi", t.tokens[5].text);
    try testing.expectEqualStrings("\"hi\"", text[t.tokens[5].span.start..t.tokens[5].span.end]);
}

test "lex black-box: two-character operators are single tokens" {
    const text = "a == b; a != b; a <= b; a >= b; a -> b; a => b; A::B; a..b";
    var t = try tokenizeText(text);
    defer t.arena.deinit();

    const want = [_]lex.TokenKind{ .ident, .eq_eq, .ident, .semicolon, .ident, .ne, .ident, .semicolon, .ident, .le, .ident, .semicolon, .ident, .ge, .ident, .semicolon, .ident, .arrow, .ident, .semicolon, .ident, .fat_arrow, .ident, .semicolon, .ident, .dcolon, .ident, .semicolon, .ident, .ellipsis, .ident, .eof };
    try testing.expectEqual(want.len, t.tokens.len);
    for (want, 0..) |kind, i| try testing.expectEqual(kind, t.tokens[i].kind);
    // Each two-character operator's span covers exactly two bytes.
    try testing.expectEqual(@as(u32, 2), t.tokens[1].span.len());
    try testing.expectEqualStrings("==", text[t.tokens[1].span.start..t.tokens[1].span.end]);
}

test "lex black-box: and and or are reserved words" {
    var t = try tokenizeText("and or xor");
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 4), t.tokens.len); // + eof
    try testing.expectEqual(lex.TokenKind.kw_and, t.tokens[0].kind);
    try testing.expectEqual(lex.TokenKind.kw_or, t.tokens[1].kind);
    try testing.expectEqual(lex.TokenKind.ident, t.tokens[2].kind); // `xor` is not reserved
    try testing.expectEqual(.eof, t.tokens[3].kind);
}

test "lex black-box: a lexical error reports a diagnostic span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, "let x = &y;");
    var lx = lex.Lexer.init(arena.allocator(), source);

    try testing.expectError(error.Syntax, lx.tokenize());
    try testing.expect(lx.diag != null);
    try testing.expectEqual(@as(u32, 8), lx.diag.?.span.start);
    try testing.expect(std.mem.indexOf(u8, lx.diag.?.message, "unexpected character '&'") != null);
}
