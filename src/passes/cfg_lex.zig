//! AIR text form lexer — air.md §9 (the `cfg` text form).
//!
//! Turns the line-oriented AIR text into the `Token` stream the parser
//! (`src/passes/cfg_parse.zig`) consumes: identifiers and dotted type
//! paths, numbers (including negative literals), `%`value and `@`func
//! references, decoded string literals, `#` indexes, punctuation, and
//! the `newline`/`eof` structure the line-oriented grammar is built on.
//! Whitespace and `;` comments separate tokens; lexical errors carry a
//! `Diag` (message + 1-based line/column) and stop the lexer.
//!
//! `describe` and `lineCol` are shared with the parser, which reports its
//! own diagnostics in the same shape.

const std = @import("std");
const ast = @import("stilla").ast;

pub const TokKind = enum {
    ident,
    number,
    string,
    value_ref, // %name or %N
    func_ref, // @name
    hash, // #
    colon,
    comma,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    equals,
    question,
    arrow, // ->
    newline,
    eof,
};

pub const Token = struct {
    kind: TokKind,
    span: ast.Span,
    text: []const u8,
};

/// One parse or lexical error: a message plus a 1-based line/column
/// position in the AIR text.
pub const Diag = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

pub const LexError = error{ Syntax, OutOfMemory };

/// Human-readable description of a token, for parser diagnostics
/// (`expected X, found '<description>'`).
pub fn describe(tok: Token) []const u8 {
    return switch (tok.kind) {
        .ident, .number, .string, .value_ref, .func_ref => tok.text,
        .newline => "end of line",
        .eof => "end of file",
        .hash => "'#'",
        .colon => "':'",
        .comma => "','",
        .lparen => "'('",
        .rparen => "')'",
        .lbrace => "'{'",
        .rbrace => "'}'",
        .lbracket => "'['",
        .rbracket => "']'",
        .equals => "'='",
        .question => "'?'",
        .arrow => "'->'",
    };
}

/// 1-based line/column of `offset` in `text`, for diagnostics.
pub fn lineCol(text: []const u8, offset: u32) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var last: u32 = 0;
    const n = @min(@as(usize, offset), text.len);
    for (text[0..n], 0..) |c, idx| {
        if (c == '\n') {
            line += 1;
            last = @intCast(idx + 1);
        }
    }
    return .{ .line = line, .column = offset - last + 1 };
}

pub const Lexer = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8 = "",
    /// The first lexical error, when tokenizing failed.
    diag: ?Diag = null,

    pub fn init(allocator: std.mem.Allocator) Lexer {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Lexer) void {
        self.arena.deinit();
    }

    /// Tokenize `text` into the token stream the parser consumes. On
    /// failure (`error.Syntax`) `diag` holds the first error and the
    /// returned slice is incomplete.
    pub fn tokenize(self: *Lexer, text: []const u8) LexError![]const Token {
        self.text = text;
        var list = std.ArrayList(Token).empty;
        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i];
            switch (ch) {
                ' ', '\t', '\r' => {
                    i += 1;
                    continue;
                },
                ';' => {
                    while (i < text.len and text[i] != '\n') i += 1;
                    continue;
                },
                '\n' => {
                    try list.append(self.arena.allocator(), .{ .kind = .newline, .span = sp(i, i + 1), .text = "" });
                    i += 1;
                    continue;
                },
                else => {},
            }
            const start = i;

            // -> arrow
            if (ch == '-' and i + 1 < text.len and text[i + 1] == '>') {
                i += 2;
                try list.append(self.arena.allocator(), .{ .kind = .arrow, .span = sp(start, i), .text = "" });
                continue;
            }
            // the negative non-finite float literal `-inf` (the positive
            // forms `inf`/`nan` lex as identifiers and are accepted by
            // the parser's const readers)
            if (ch == '-' and i + 4 <= text.len and std.mem.eql(u8, text[i + 1 .. i + 4], "inf")) {
                i += 4;
                try list.append(self.arena.allocator(), .{ .kind = .number, .span = sp(start, i), .text = "-inf" });
                continue;
            }
            // numbers, including negative literals
            if (isDigit(ch) or (ch == '-' and i + 1 < text.len and isDigit(text[i + 1]))) {
                i += 1;
                while (i < text.len and (isDigit(text[i]) or text[i] == '.')) i += 1;
                try list.append(self.arena.allocator(), .{ .kind = .number, .span = sp(start, i), .text = text[start..i] });
                continue;
            }
            // identifiers, keywords, and dotted type paths
            if (isIdentStart(ch)) {
                i += 1;
                while (i < text.len and isIdentCont(text[i])) i += 1;
                try list.append(self.arena.allocator(), .{ .kind = .ident, .span = sp(start, i), .text = text[start..i] });
                continue;
            }
            // value references: %name or %N
            if (ch == '%') {
                i += 1;
                while (i < text.len and (isIdentCont(text[i]) or isDigit(text[i]))) i += 1;
                if (i == start + 1) return self.lexFail(start, i, "expected a value name after '%'");
                try list.append(self.arena.allocator(), .{ .kind = .value_ref, .span = sp(start, i), .text = text[start + 1 .. i] });
                continue;
            }
            // function references: @name
            if (ch == '@') {
                i += 1;
                while (i < text.len and (isIdentCont(text[i]) or isDigit(text[i]))) i += 1;
                if (i == start + 1) return self.lexFail(start, i, "expected a function name after '@'");
                try list.append(self.arena.allocator(), .{ .kind = .func_ref, .span = sp(start, i), .text = text[start + 1 .. i] });
                continue;
            }
            // string literals, decoded
            if (ch == '"') {
                i += 1;
                var value = std.ArrayList(u8).empty;
                var closed = false;
                while (i < text.len) {
                    const c = text[i];
                    if (c == '"') {
                        i += 1;
                        closed = true;
                        break;
                    }
                    if (c == '\\') {
                        i += 1;
                        if (i >= text.len) break;
                        const e = text[i];
                        i += 1;
                        switch (e) {
                            'n' => try value.append(self.arena.allocator(), '\n'),
                            't' => try value.append(self.arena.allocator(), '\t'),
                            '"' => try value.append(self.arena.allocator(), '"'),
                            '\\' => try value.append(self.arena.allocator(), '\\'),
                            else => return self.lexFail(start, i, "unsupported escape sequence in string"),
                        }
                        continue;
                    }
                    try value.append(self.arena.allocator(), c);
                    i += 1;
                }
                if (!closed) return self.lexFail(start, i, "unterminated string literal");
                try list.append(self.arena.allocator(), .{ .kind = .string, .span = sp(start, i), .text = try value.toOwnedSlice(self.arena.allocator()) });
                continue;
            }
            if (ch == '#') {
                i += 1;
                try list.append(self.arena.allocator(), .{ .kind = .hash, .span = sp(start, i), .text = "" });
                continue;
            }
            const kind: TokKind = switch (ch) {
                ':' => .colon,
                ',' => .comma,
                '(' => .lparen,
                ')' => .rparen,
                '{' => .lbrace,
                '}' => .rbrace,
                '[' => .lbracket,
                ']' => .rbracket,
                '=' => .equals,
                '?' => .question,
                else => return self.lexFail(start, i, "unexpected character in AIR text"),
            };
            i += 1;
            try list.append(self.arena.allocator(), .{ .kind = kind, .span = sp(start, i), .text = "" });
        }
        const len = text.len;
        try list.append(self.arena.allocator(), .{ .kind = .eof, .span = sp(len, len), .text = "" });
        return list.toOwnedSlice(self.arena.allocator());
    }

    fn lexFail(self: *Lexer, start: usize, end: usize, message: []const u8) LexError {
        const pos = lineCol(self.text, @intCast(start));
        self.diag = .{ .line = pos.line, .column = pos.column, .message = message };
        _ = end;
        return error.Syntax;
    }
};

fn sp(start: usize, end: usize) ast.Span {
    return ast.Span.init(0, @intCast(start), @intCast(end));
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn isDigit(c: u8) bool {
    return std.ascii.isDigit(c);
}

test "cfg lexer tokenizes an instruction line" {
    const testing = std.testing;
    var lex = Lexer.init(testing.allocator);
    defer lex.deinit();
    const tokens = try lex.tokenize("%r: int32 = add %a, %b\n");
    // value_ref, colon, ident, equals, ident, value_ref, comma, value_ref, newline, eof
    try testing.expectEqual(@as(usize, 10), tokens.len);
    try testing.expectEqual(TokKind.value_ref, tokens[0].kind);
    try testing.expectEqualStrings("r", tokens[0].text);
    try testing.expectEqual(TokKind.colon, tokens[1].kind);
    try testing.expectEqual(TokKind.ident, tokens[2].kind);
    try testing.expectEqualStrings("int32", tokens[2].text);
    try testing.expectEqual(TokKind.equals, tokens[3].kind);
    try testing.expectEqual(TokKind.ident, tokens[4].kind);
    try testing.expectEqualStrings("add", tokens[4].text);
    try testing.expectEqual(TokKind.value_ref, tokens[5].kind);
    try testing.expectEqualStrings("a", tokens[5].text);
    try testing.expectEqual(TokKind.comma, tokens[6].kind);
    try testing.expectEqual(TokKind.value_ref, tokens[7].kind);
    try testing.expectEqualStrings("b", tokens[7].text);
    try testing.expectEqual(TokKind.newline, tokens[8].kind);
    try testing.expectEqual(TokKind.eof, tokens[9].kind);
}

test "cfg lexer decodes strings and comments and reports errors" {
    const testing = std.testing;
    var lex = Lexer.init(testing.allocator);
    defer lex.deinit();

    // String decoding + a `;` comment and a negative number. The
    // comment skip stops at (but does not consume) the `\n`, so a
    // newline token separates the string from the number.
    const tokens = try lex.tokenize("\"a\\nb\"; comment\n-5\n");
    try testing.expectEqualStrings("a\nb", tokens[0].text);
    try testing.expectEqual(TokKind.string, tokens[0].kind);
    try testing.expectEqual(TokKind.newline, tokens[1].kind);
    try testing.expectEqual(TokKind.number, tokens[2].kind);
    try testing.expectEqualStrings("-5", tokens[2].text);

    // An unterminated string is a lexical error with a diag.
    var lex2 = Lexer.init(testing.allocator);
    defer lex2.deinit();
    try testing.expectError(error.Syntax, lex2.tokenize("\"oops"));
    try testing.expect(lex2.diag != null);
    try testing.expect(std.mem.indexOf(u8, lex2.diag.?.message, "unterminated string") != null);
}
