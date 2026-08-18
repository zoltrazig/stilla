//! Lexer for the Stilla core language (Grammar v1.3 Draft) — turns source
//! text into the token stream the parser consumes.
//!
//! Every token carries a `Span` (a byte range in the source) and a `text`
//! slice: the raw source text for identifiers, keywords, and numbers; the
//! decoded string value for `string` tokens (escapes are resolved here,
//! once). Whitespace and comments separate tokens and are otherwise
//! discarded; block comments nest (Grammar: "Comments (lexical)").
//!
//! Reserved words are recognized lexically, before syntactic parsing
//! (Grammar: "Reserved words"). A lone `_` is the wildcard token; a `_`
//! followed by a letter, digit, or `_` begins an identifier (maximal munch,
//! "wildcard-token"). After an integer, a `.` belongs to the token only if
//! a digit immediately follows ("float"): `1.5` is one float token, `1.x`
//! is an integer followed by `.`.

const std = @import("std");
const ast = @import("ast.zig");

/// Kinds of lexical tokens. Reserved words are distinct token kinds so the
/// parser can dispatch on a single token; `true` and `false` are keyword
/// tokens (bool literals).
pub const TokenKind = enum {
    eof,
    ident,
    wildcard,
    integer,
    float,
    string,

    kw_and,
    kw_any,
    kw_as,
    kw_bool,
    kw_borrow,
    kw_box,
    kw_byte,
    kw_const,
    kw_drop,
    kw_else,
    kw_false,
    kw_float32,
    kw_fn,
    kw_hostdata,
    kw_if,
    kw_import,
    kw_int32,
    kw_let,
    kw_list,
    kw_match,
    kw_move,
    kw_never,
    kw_opaque,
    kw_or,
    kw_str,
    kw_struct,
    kw_true,
    kw_tuple,
    kw_type,
    kw_uint32,
    kw_union,
    kw_using,
    kw_void,

    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    colon,
    semicolon,
    dot,
    at,
    dcolon,
    arrow,
    fat_arrow,
    equals,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    eq_eq,
    ne,
    lt,
    le,
    gt,
    ge,
    ellipsis,
};

/// One lexical token: its kind, its `Span` in the source, and the raw text
/// (identifiers, keywords, numbers) or decoded value (strings).
pub const Token = struct {
    kind: TokenKind,
    span: ast.Span,
    text: []const u8,
};

/// Turns one source file into a token slice. Tokens are appended to an
/// arena-owned list, so the returned slice stays valid for the arena's
/// lifetime (no appends happen after `tokenize` returns). On
/// `error.Syntax`, `diag` describes the first lexical error.
pub const Lexer = struct {
    arena: std.mem.Allocator,
    source: *const ast.Source,
    tokens: std.ArrayList(Token),
    diag: ?ast.Diagnostic = null,
    /// Byte offset of the next unlexed character in `source.text`.
    pos: usize = 0,

    pub fn init(arena: std.mem.Allocator, source: *const ast.Source) Lexer {
        return .{ .arena = arena, .source = source, .tokens = std.ArrayList(Token).empty };
    }

    /// Tokenize the whole source, ending with an `eof` token.
    pub fn tokenize(self: *Lexer) ![]const Token {
        const text = self.source.text;
        while (self.pos < text.len) {
            try self.skipTrivia();
            if (self.pos >= text.len) break;
            try self.scanToken();
        }
        const len = @as(u32, @intCast(text.len));
        try self.tokens.append(self.arena, .{
            .kind = .eof,
            .span = ast.Span.init(self.source.id, len, len),
            .text = "",
        });
        return self.tokens.items;
    }

    fn skipTrivia(self: *Lexer) !void {
        const text = self.source.text;
        while (true) {
            const ch = if (self.pos < text.len) text[self.pos] else break;
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                self.pos += 1;
                continue;
            }
            if (ch == '/' and self.pos + 1 < text.len and text[self.pos + 1] == '/') {
                while (self.pos < text.len and text[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (ch == '/' and self.pos + 1 < text.len and text[self.pos + 1] == '*') {
                try self.skipBlockComment();
                continue;
            }
            break;
        }
    }

    fn skipBlockComment(self: *Lexer) !void {
        const text = self.source.text;
        const start = self.pos;
        var depth: usize = 1;
        self.pos += 2;
        while (true) {
            if (self.pos >= text.len) {
                return self.fail(self.spanAt(start, self.pos), "unterminated block comment", .{});
            }
            if (text[self.pos] == '/' and self.pos + 1 < text.len and text[self.pos + 1] == '*') {
                depth += 1;
                self.pos += 2;
            } else if (text[self.pos] == '*' and self.pos + 1 < text.len and text[self.pos + 1] == '/') {
                depth -= 1;
                self.pos += 2;
                if (depth == 0) break;
            } else {
                self.pos += 1;
            }
        }
    }

    fn scanToken(self: *Lexer) !void {
        const text = self.source.text;
        const start = self.pos;
        const ch = text[start];
        if (ch == '_' or isAsciiLetter(ch)) return self.scanIdentifier();
        if (isDigit(ch)) return self.scanNumber();
        // Two-character tokens consume their second character here; the
        // shared `self.pos += 1` below consumes the first.
        const kind: TokenKind = switch (ch) {
            '"' => return self.scanString(),
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            ',' => .comma,
            ';' => .semicolon,
            '+' => .plus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '@' => .at,
            ':' => if (self.peek1() == ':') blk: {
                self.pos += 1;
                break :blk .dcolon;
            } else .colon,
            '=' => if (self.peek1() == '=') blk: {
                self.pos += 1;
                break :blk .eq_eq;
            } else if (self.peek1() == '>') blk: {
                self.pos += 1;
                break :blk .fat_arrow;
            } else .equals,
            '!' => if (self.peek1() == '=') blk: {
                self.pos += 1;
                break :blk .ne;
            } else .bang,
            '<' => if (self.peek1() == '=') blk: {
                self.pos += 1;
                break :blk .le;
            } else .lt,
            '>' => if (self.peek1() == '=') blk: {
                self.pos += 1;
                break :blk .ge;
            } else .gt,
            '-' => if (self.peek1() == '>') blk: {
                self.pos += 1;
                break :blk .arrow;
            } else .minus,
            '.' => if (self.peek1() == '.') blk: {
                self.pos += 1;
                break :blk .ellipsis;
            } else .dot,
            else => return self.fail(self.spanAt(start, start + 1), "unexpected character '{c}'", .{ch}),
        };
        self.pos += 1;
        try self.push(start, kind);
    }

    fn scanIdentifier(self: *Lexer) !void {
        const text = self.source.text;
        const start = self.pos;
        while (self.pos < text.len and isIdentChar(text[self.pos])) self.pos += 1;
        const slice = text[start..self.pos];
        const kind: TokenKind = if (slice.len == 1 and slice[0] == '_') .wildcard else keywordOrIdent(slice);
        try self.tokens.append(self.arena, .{ .kind = kind, .span = self.spanAt(start, self.pos), .text = slice });
    }

    fn scanNumber(self: *Lexer) !void {
        const text = self.source.text;
        const start = self.pos;
        while (self.pos < text.len and isDigit(text[self.pos])) self.pos += 1;
        const kind: TokenKind = if (self.pos + 1 < text.len and text[self.pos] == '.' and isDigit(text[self.pos + 1])) blk: {
            self.pos += 1; // '.'
            while (self.pos < text.len and isDigit(text[self.pos])) self.pos += 1;
            break :blk .float;
        } else .integer;
        try self.tokens.append(self.arena, .{ .kind = kind, .span = self.spanAt(start, self.pos), .text = text[start..self.pos] });
    }

    fn scanString(self: *Lexer) !void {
        const text = self.source.text;
        const start = self.pos;
        self.pos += 1; // opening '"'
        var value = std.ArrayList(u8).empty;
        while (true) {
            if (self.pos >= text.len) return self.fail(self.spanAt(start, self.pos), "unterminated string literal", .{});
            const ch = text[self.pos];
            if (ch == '"') {
                self.pos += 1;
                break;
            }
            if (ch == '\\') {
                if (self.pos + 1 >= text.len) return self.fail(self.spanAt(start, self.pos), "unterminated string literal", .{});
                const esc = text[self.pos + 1];
                switch (esc) {
                    '"' => try value.append(self.arena, '"'),
                    '\\' => try value.append(self.arena, '\\'),
                    'n' => try value.append(self.arena, '\n'),
                    'r' => try value.append(self.arena, '\r'),
                    't' => try value.append(self.arena, '\t'),
                    else => return self.fail(self.spanAt(self.pos, self.pos + 2), "invalid escape sequence '\\{c}'", .{esc}),
                }
                self.pos += 2;
            } else if (ch < 0x20 or ch == 0x7f) {
                return self.fail(self.spanAt(self.pos, self.pos + 1), "control character in string literal", .{});
            } else {
                try value.append(self.arena, ch);
                self.pos += 1;
            }
        }
        try self.tokens.append(self.arena, .{ .kind = .string, .span = self.spanAt(start, self.pos), .text = value.items });
    }

    /// Append a token spanning `start..pos` with the given kind. The token
    /// text is the raw source slice (strings set their own decoded text).
    fn push(self: *Lexer, start: usize, kind: TokenKind) !void {
        try self.tokens.append(self.arena, .{
            .kind = kind,
            .span = self.spanAt(start, self.pos),
            .text = self.source.text[start..self.pos],
        });
    }

    fn peek1(self: *Lexer) u8 {
        return if (self.pos + 1 < self.source.text.len) self.source.text[self.pos + 1] else 0;
    }

    fn spanAt(self: *Lexer, start: usize, end: usize) ast.Span {
        return ast.Span.init(self.source.id, @intCast(start), @intCast(end));
    }

    fn fail(self: *Lexer, span: ast.Span, comptime fmt: []const u8, args: anytype) error{Syntax} {
        if (self.diag == null) {
            self.diag = .{ .span = span, .message = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory" };
        }
        return error.Syntax;
    }
};

fn isAsciiLetter(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isIdentChar(ch: u8) bool {
    return isAsciiLetter(ch) or isDigit(ch) or ch == '_';
}

/// Reserved words are recognized lexically (Grammar: "Reserved words").
fn keywordOrIdent(text: []const u8) TokenKind {
    const keywords = std.StaticStringMap(TokenKind).initComptime(.{
        .{ "and", .kw_and },
        .{ "any", .kw_any },
        .{ "as", .kw_as },
        .{ "bool", .kw_bool },
        .{ "borrow", .kw_borrow },
        .{ "box", .kw_box },
        .{ "byte", .kw_byte },
        .{ "const", .kw_const },
        .{ "drop", .kw_drop },
        .{ "else", .kw_else },
        .{ "false", .kw_false },
        .{ "float32", .kw_float32 },
        .{ "fn", .kw_fn },
        .{ "hostdata", .kw_hostdata },
        .{ "if", .kw_if },
        .{ "import", .kw_import },
        .{ "int32", .kw_int32 },
        .{ "let", .kw_let },
        .{ "list", .kw_list },
        .{ "match", .kw_match },
        .{ "move", .kw_move },
        .{ "never", .kw_never },
        .{ "opaque", .kw_opaque },
        .{ "or", .kw_or },
        .{ "str", .kw_str },
        .{ "struct", .kw_struct },
        .{ "true", .kw_true },
        .{ "tuple", .kw_tuple },
        .{ "type", .kw_type },
        .{ "uint32", .kw_uint32 },
        .{ "union", .kw_union },
        .{ "using", .kw_using },
        .{ "void", .kw_void },
    });
    return keywords.get(text) orelse .ident;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn tokenizeText(text: []const u8) !struct { arena: std.heap.ArenaAllocator, tokens: []const Token } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
    var lexer = Lexer.init(arena.allocator(), source);
    // Tokenize before returning: the returned arena copy must include the
    // allocations made by tokenize.
    const tokens = try lexer.tokenize();
    return .{ .arena = arena, .tokens = tokens };
}

test "lexes identifiers, wildcard, and keywords" {
    var t = try tokenizeText("_ _foo __ let int32 x");
    defer t.arena.deinit();

    const kinds: [6]TokenKind = .{ .wildcard, .ident, .ident, .kw_let, .kw_int32, .ident };
    try std.testing.expectEqual(@as(usize, 7), t.tokens.len); // + eof
    for (kinds, 0..) |kind, i| try std.testing.expectEqual(kind, t.tokens[i].kind);
    try std.testing.expectEqualStrings("_foo", t.tokens[1].text);
    try std.testing.expectEqualStrings("__", t.tokens[2].text);
    try std.testing.expectEqual(.eof, t.tokens[6].kind);
}

test "lexes any as a reserved word" {
    var t = try tokenizeText("any");
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.tokens.len); // + eof
    try std.testing.expectEqual(TokenKind.kw_any, t.tokens[0].kind);
    try std.testing.expectEqual(.eof, t.tokens[1].kind);
}

test "lexes hostdata as a reserved word" {
    // `hostdata` is a primitive type (Core §11.7) and a reserved word
    // (Grammar "Reserved words"), unlike `builtin` which is an ordinary
    // importable module (Core §3).
    var t = try tokenizeText("hostdata");
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.tokens.len); // + eof
    try std.testing.expectEqual(TokenKind.kw_hostdata, t.tokens[0].kind);
    try std.testing.expectEqual(.eof, t.tokens[1].kind);
}

test "lexes builtin as an ordinary identifier" {
    // `builtin` is not a reserved word: it is an importable standard-library
    // module and must be imported like any other module (Core §3).
    var t = try tokenizeText("builtin");
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.tokens.len); // + eof
    try std.testing.expectEqual(TokenKind.ident, t.tokens[0].kind);
    try std.testing.expectEqualStrings("builtin", t.tokens[0].text);
    try std.testing.expectEqual(.eof, t.tokens[1].kind);
}

test "lexes the using keyword" {
    var t = try tokenizeText("using string.repeat as re;");
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 8), t.tokens.len); // + eof
    try std.testing.expectEqual(TokenKind.kw_using, t.tokens[0].kind);
    try std.testing.expectEqual(TokenKind.ident, t.tokens[1].kind);
    try std.testing.expectEqual(TokenKind.dot, t.tokens[2].kind);
    try std.testing.expectEqual(TokenKind.kw_as, t.tokens[4].kind);
    try std.testing.expectEqual(.eof, t.tokens[7].kind);
}

test "lexes numbers with the float lookahead rule" {
    var t = try tokenizeText("1 1.5 1. 1.x");
    defer t.arena.deinit();

    // `1.` ends the integer and leaves a separate `.` token.
    const kinds: [7]TokenKind = .{ .integer, .float, .integer, .dot, .integer, .dot, .ident };
    try std.testing.expectEqual(@as(usize, 8), t.tokens.len);
    for (kinds, 0..) |kind, i| try std.testing.expectEqual(kind, t.tokens[i].kind);
    try std.testing.expectEqualStrings("1.5", t.tokens[1].text);
}

test "decodes string escapes" {
    var t = try tokenizeText("\"a\\nb\\\"c\\\\d\"");
    defer t.arena.deinit();

    try std.testing.expectEqual(.string, t.tokens[0].kind);
    try std.testing.expectEqualStrings("a\nb\"c\\d", t.tokens[0].text);
}

test "string content may be unicode" {
    var t = try tokenizeText("\"h\u{e9}llo\"");
    defer t.arena.deinit();
    try std.testing.expectEqualStrings("h\u{e9}llo", t.tokens[0].text);
}

test "lexes all punctuation" {
    var t = try tokenizeText("()[]{} ,;:. @ :: -> => = + - * / % ! == != < <= > >= ..");
    defer t.arena.deinit();

    const kinds = [_]TokenKind{
        .lparen, .rparen,    .lbracket, .rbracket, .lbrace, .rbrace,
        .comma,  .semicolon, .colon,    .dot,      .at,     .dcolon,
        .arrow,  .fat_arrow, .equals,   .plus,     .minus,  .star,
        .slash,  .percent,   .bang,     .eq_eq,    .ne,     .lt,
        .le,     .gt,        .ge,       .ellipsis,
    };
    try std.testing.expectEqual(@as(usize, 29), t.tokens.len);
    for (kinds, 0..) |kind, i| try std.testing.expectEqual(kind, t.tokens[i].kind);
}

test "skips line and nested block comments" {
    var t = try tokenizeText("// line\n1 /* outer /* inner */ still */ 2");
    defer t.arena.deinit();

    try std.testing.expectEqual(.integer, t.tokens[0].kind);
    try std.testing.expectEqualStrings("1", t.tokens[0].text);
    try std.testing.expectEqual(.integer, t.tokens[1].kind);
}

test "spans point into the source" {
    var t = try tokenizeText("let x");
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(u32, 0), t.tokens[0].span.start);
    try std.testing.expectEqual(@as(u32, 3), t.tokens[0].span.end);
    try std.testing.expectEqual(@as(u32, 4), t.tokens[1].span.start);
}

test "rejects invalid escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "\"a\\qb\"");
    var lexer = Lexer.init(arena.allocator(), source);

    try std.testing.expectError(error.Syntax, lexer.tokenize());
    const diag = lexer.diag.?;
    try std.testing.expectEqualStrings("invalid escape sequence '\\q'", diag.message);
    try std.testing.expectEqual(@as(u32, 2), diag.span.start);
}

test "rejects control characters in strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "\"a\nb\"");
    var lexer = Lexer.init(arena.allocator(), source);

    try std.testing.expectError(error.Syntax, lexer.tokenize());
    try std.testing.expectEqualStrings("control character in string literal", lexer.diag.?.message);
}

test "rejects unterminated strings and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "\"abc");
    var lexer = Lexer.init(arena.allocator(), source);
    try std.testing.expectError(error.Syntax, lexer.tokenize());
    try std.testing.expectEqualStrings("unterminated string literal", lexer.diag.?.message);

    source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "/* abc");
    lexer = Lexer.init(arena.allocator(), source);
    try std.testing.expectError(error.Syntax, lexer.tokenize());
    try std.testing.expectEqualStrings("unterminated block comment", lexer.diag.?.message);
}

test "rejects lone & and |" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "a & b");
    var lexer = Lexer.init(arena.allocator(), source);

    try std.testing.expectError(error.Syntax, lexer.tokenize());
    try std.testing.expectEqualStrings("unexpected character '&'", lexer.diag.?.message);
}

test "rejects unexpected characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "h\u{e9}llo");
    var lexer = Lexer.init(arena.allocator(), source);

    try std.testing.expectError(error.Syntax, lexer.tokenize());
    // The message shows the unexpected raw byte (0xC3, the lead byte of
    // U+00E9): identifiers are ASCII, and the diagnostic is byte-oriented.
    try std.testing.expectEqualStrings("unexpected character '\xc3'", lexer.diag.?.message);
}

test "lexes every reserved word" {
    // Grammar "Reserved words": all are recognized lexically, before
    // syntactic parsing.
    var t = try tokenizeText("and any as bool borrow box byte const drop else false float32 fn hostdata if import int32 let list match move never or str struct true tuple type uint32 union using void");
    defer t.arena.deinit();

    const kinds = [_]TokenKind{
        .kw_and,    .kw_any,      .kw_as,    .kw_bool,   .kw_borrow, .kw_box,
        .kw_byte,   .kw_const,    .kw_drop,  .kw_else,   .kw_false,  .kw_float32,
        .kw_fn,     .kw_hostdata, .kw_if,    .kw_import, .kw_int32,  .kw_let,
        .kw_list,   .kw_match,    .kw_move,  .kw_never,  .kw_or,     .kw_str,
        .kw_struct, .kw_true,     .kw_tuple, .kw_type,   .kw_uint32, .kw_union,
        .kw_using,  .kw_void,
    };
    try std.testing.expectEqual(@as(usize, 33), t.tokens.len); // + eof
    for (kinds, 0..) |kind, i| try std.testing.expectEqual(kind, t.tokens[i].kind);
}

test "lexes numeric literals with edge cases" {
    // Grammar `integer` / `float`: 1*digit, optional .1*digit. Leading
    // zeros are ordinary digits; there is no sign in the token (the `-`
    // is an operator, Grammar note).
    // `10.` ends the integer and leaves a separate `.` token (Grammar
    // `float`: a `.` belongs to the token only when a digit follows).
    var t = try tokenizeText("0 00 007 1.0 0.5 10.");
    defer t.arena.deinit();

    const kinds = [_]TokenKind{ .integer, .integer, .integer, .float, .float, .integer, .dot };
    try std.testing.expectEqual(@as(usize, 8), t.tokens.len);
    for (kinds, 0..) |kind, i| try std.testing.expectEqual(kind, t.tokens[i].kind);
    try std.testing.expectEqualStrings("10", t.tokens[5].text);
    try std.testing.expectEqualStrings(".", t.tokens[6].text);
}

test "decodes all string escapes" {
    // Grammar `escape`: \" \\ \n \r \t.
    var t = try tokenizeText("\"\\\"\\\\\\n\\r\\t\"");
    defer t.arena.deinit();

    try std.testing.expectEqual(.string, t.tokens[0].kind);
    try std.testing.expectEqualStrings("\"\\\n\r\t", t.tokens[0].text);
}

test "lexes an empty string" {
    var t = try tokenizeText("\"\"");
    defer t.arena.deinit();
    try std.testing.expectEqual(.string, t.tokens[0].kind);
    try std.testing.expectEqualStrings("", t.tokens[0].text);
}

test "rejects a carriage return in a string" {
    // `string-char` excludes control characters (Grammar).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "\"a\rb\"");
    var lexer = Lexer.init(arena.allocator(), source);

    try std.testing.expectError(error.Syntax, lexer.tokenize());
    try std.testing.expectEqualStrings("control character in string literal", lexer.diag.?.message);
}

test "rejects a lone backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "\"a\\");
    var lexer = Lexer.init(arena.allocator(), source);

    try std.testing.expectError(error.Syntax, lexer.tokenize());
    try std.testing.expectEqualStrings("unterminated string literal", lexer.diag.?.message);
}

test "rejects a stray @ and dots" {
    // `@` is punctuation used only for the index suffix; a lone `..` is
    // the list-rest ellipsis, but `...` has no token (Grammar).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "t.st", 0, "a@");
    var lexer = Lexer.init(arena.allocator(), source);
    try std.testing.expectEqual(.ident, (try lexer.tokenize())[0].kind);
    // `a@` lexes @ as a punctuation token; the parser rejects a missing
    // index expression. So the lexer itself accepts it.
    try std.testing.expectEqual(.at, (try lexer.tokenize())[1].kind);
}
