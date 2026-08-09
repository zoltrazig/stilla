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
    const t = try tokenizeText(text);
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
    const t = try tokenizeText(text);
    defer t.arena.deinit();

    // The identifier `greeting` starts at byte 6.
    try testing.expectEqualStrings("greeting", text[t.tokens[1].span.start..t.tokens[1].span.end]);
    // The string token covers the quotes; its text is the decoded value.
    try testing.expectEqualStrings("hi", t.tokens[5].text);
    try testing.expectEqualStrings("\"hi\"", text[t.tokens[5].span.start..t.tokens[5].span.end]);
}

test "lex black-box: two-character operators are single tokens" {
    const text = "a == b; a != b; a <= b; a >= b; a -> b; a => b; A::B; a..b";
    const t = try tokenizeText(text);
    defer t.arena.deinit();

    const want = [_]lex.TokenKind{ .ident, .eq_eq, .ident, .semicolon, .ident, .ne, .ident, .semicolon, .ident, .le, .ident, .semicolon, .ident, .ge, .ident, .semicolon, .ident, .arrow, .ident, .semicolon, .ident, .fat_arrow, .ident, .semicolon, .ident, .dcolon, .ident, .semicolon, .ident, .ellipsis, .ident, .eof };
    try testing.expectEqual(want.len, t.tokens.len);
    for (want, 0..) |kind, i| try testing.expectEqual(kind, t.tokens[i].kind);
    // Each two-character operator's span covers exactly two bytes.
    try testing.expectEqual(@as(u32, 2), t.tokens[1].span.len());
    try testing.expectEqualStrings("==", text[t.tokens[1].span.start..t.tokens[1].span.end]);
}

test "lex black-box: and and or are reserved words" {
    const t = try tokenizeText("and or xor");
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
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, "let x = ~y;");
    var lx = lex.Lexer.init(arena.allocator(), source);

    try testing.expectError(error.Syntax, lx.tokenize());
    try testing.expect(lx.diag != null);
    try testing.expectEqual(@as(u32, 8), lx.diag.?.span.start);
    try testing.expect(std.mem.indexOf(u8, lx.diag.?.message, "unexpected character '~'") != null);
}

test "lex black-box: every lexical error in a file surfaces in one run" {
    // Lexical recovery: each error is recorded, the lexer skips to the
    // next token boundary, and the rest of the file still lexes — so a
    // whole file's lexical errors surface in one `tokenize` run, in
    // source order, with `diag` naming the first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, "a ~ b\nconst s = \"bad\\q\";\n1 + @");
    var lx = lex.Lexer.init(arena.allocator(), source);

    try testing.expectError(error.Syntax, lx.tokenize());
    try testing.expectEqual(@as(usize, 3), lx.diags.items.len);
    try testing.expectEqualStrings("unexpected character '~'", lx.diags.items[0].message);
    try testing.expectEqualStrings("invalid escape sequence '\\q'", lx.diags.items[1].message);
    try testing.expectEqualStrings("unexpected character '@'", lx.diags.items[2].message);
    try testing.expectEqualStrings("unexpected character '~'", lx.diag.?.message);
}

test "lex black-box: an unterminated string does not hide later errors" {
    // Recovery: a raw newline (a missing closing quote) ends the string
    // scan at the end of the line, so errors after it still surface in
    // the same run.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, "\"abc\nconst x = 1; @");
    var lx = lex.Lexer.init(arena.allocator(), source);

    try testing.expectError(error.Syntax, lx.tokenize());
    try testing.expectEqual(@as(usize, 2), lx.diags.items.len);
    try testing.expectEqualStrings("control character in string literal", lx.diags.items[0].message);
    try testing.expectEqualStrings("unexpected character '@'", lx.diags.items[1].message);
}

test "lex black-box: \\u string escapes decode to UTF-8 scalar values" {
    // Grammar "unicode-escape": `\u{hex}` (one to six hex digits). The
    // escape is explicit, so it may produce scalars the raw string-char
    // rule rejects (control characters).
    {
        const t = try tokenizeText("\"A\\u{e9}B\"");
        defer t.arena.deinit();
        try testing.expectEqualStrings("A\u{e9}B", t.tokens[0].text);
    }
    {
        const t = try tokenizeText("\"\\u{41}\\u{1F600}\"");
        defer t.arena.deinit();
        try testing.expectEqualStrings("A\u{1f600}", t.tokens[0].text);
    }
    {
        const t = try tokenizeText("\"\\u{7}\"");
        defer t.arena.deinit();
        try testing.expectEqualStrings("\x07", t.tokens[0].text);
    }
    {
        // Adjacent escapes and raw text mix freely.
        const t = try tokenizeText("\"\\u{39a}\\u{3b1}\\u{3b9}\"");
        defer t.arena.deinit();
        try testing.expectEqualStrings("Και", t.tokens[0].text);
    }
}

test "lex black-box: invalid \\u escapes are lexical errors" {
    const bad = [_][]const u8{
        "\"\\u{d800}\"", // surrogate
        "\"\\u{dfff}\"", // low surrogate edge
        "\"\\u{110000}\"", // above 10FFFF
        "\"\\u{1234567}\"", // more than six digits
        "\"\\u{}\"", // no digits
        "\"\\u{zz}\"", // not hex
        "\"\\u{41\"", // unterminated brace
        "\"\\u12\"", // missing '{'
        "\"\\uzzzz\"", // missing '{'
    };
    for (bad) |text| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const source = try arena.allocator().create(ast.Source);
        source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
        var lx = lex.Lexer.init(arena.allocator(), source);
        try testing.expectError(error.Syntax, lx.tokenize());
        try testing.expect(lx.diag != null);
    }
}

test "lex black-box: identifiers are Unicode XID sequences" {
    // UAX #31: XID_Start begins, XID_Continue continues; ASCII `_` is
    // allowed in both positions. Keywords stay ASCII, so a non-ASCII
    // identifier can never collide with a reserved word.
    {
        const t = try tokenizeText("let μαθ_2 = cafe\u{301};");
        defer t.arena.deinit();
        try testing.expectEqual(.kw_let, t.tokens[0].kind);
        try testing.expectEqual(.ident, t.tokens[1].kind);
        try testing.expectEqualStrings("μαθ_2", t.tokens[1].text);
        try testing.expectEqual(.ident, t.tokens[3].kind);
        try testing.expectEqualStrings("cafe\u{301}", t.tokens[3].text); // NFD form: e + combining acute
    }
    {
        // `_κ` is an identifier (underscore then XID_Continue); a lone
        // `_` is still the wildcard token.
        const t = try tokenizeText("_κ _");
        defer t.arena.deinit();
        try testing.expectEqual(.ident, t.tokens[0].kind);
        try testing.expectEqualStrings("_κ", t.tokens[0].text);
        try testing.expectEqual(.wildcard, t.tokens[1].kind);
    }
    {
        // Combining marks may continue but not start an identifier.
        const t = try tokenizeText("e\u{301} = 1");
        defer t.arena.deinit();
        try testing.expectEqual(.ident, t.tokens[0].kind);
    }
}

test "lex black-box: invalid UTF-8 in an identifier is a lexical error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, "let x = ab\xff;");
    var lx = lex.Lexer.init(arena.allocator(), source);

    try testing.expectError(error.Syntax, lx.tokenize());
    try testing.expect(lx.diag != null);
    try testing.expect(std.mem.indexOf(u8, lx.diag.?.message, "invalid UTF-8 in identifier") != null);
}
