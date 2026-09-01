//! Pass: pattern parsing (Grammar `pattern`, `type-test-pattern`,
//! `tuple-pattern`, `list-pattern`, `path-pattern`).
//! In:  `*Parser` over a token stream.
//! Out: `ast.Pattern` nodes.

const std = @import("std");
const ast = @import("stilla").ast;
const lex = @import("stilla").lex;
const parser = @import("stilla").parser;
const parse_type = @import("type.zig");
const ParseError = parser.ParseError;

pub fn parsePattern(self: *parser.Parser) ParseError!ast.Pattern {
    // Nesting-depth guard: tuple/list/struct patterns recurse through
    // parsePattern (parseTuplePattern/parseListPattern/parsePathPattern),
    // so count them against the same shared 512-level cap as
    // expressions and types (see parseExpression). Regression:
    // thousands of nested patterns overflowed the native stack.
    if (self.depth >= 512) {
        return self.fail(self.cur().span, "pattern nesting too deep (more than {d} levels)", .{512});
    }
    self.depth += 1;
    defer self.depth -= 1;
    const tok = self.cur();
    return switch (tok.kind) {
        .wildcard => blk: {
            _ = self.advance();
            break :blk .{ .wildcard = .{ .span = tok.span } };
        },
        .integer, .float, .string, .kw_true, .kw_false => literalPattern(self),
        .minus => negativeLiteralPattern(self),
        .lparen => parseTuplePattern(self),
        .lbracket => parseListPattern(self),
        // Keyword-led type-test patterns (Grammar `type-test-pattern`,
        // Core §14.7): a concrete type name, optionally followed by a
        // binding identifier. `any`, `never`, and `hostdata` are not
        // test types (Grammar note; Core §11.6, §11.7).
        .kw_byte, .kw_int32, .kw_uint32, .kw_int64, .kw_uint64, .kw_float32, .kw_float64, .kw_bool, .kw_str, .kw_list, .kw_box, .kw_tuple, .kw_fn => parseTypeTestPattern(self),
        .ident => parsePathPattern(self),
        else => self.fail(tok.span, "expected a pattern, found {s}", .{self.describe(tok)}),
    };
}

/// `type-test-type [identifier]` (Grammar `type-test-pattern`). The
/// type is parsed by `parseType` (`byte`, `int32`, `str`, `list[T]`,
/// `fn(...) -> T`, …); the optional binding names the recovered
/// payload (Core §14.7).
pub fn parseTypeTestPattern(self: *parser.Parser) ParseError!ast.Pattern {
    const start = self.mark();
    const type_ = try parse_type.parseType(self);
    var binding: ?ast.Ident = null;
    if (self.at(.ident)) binding = try self.expectIdent();
    return .{ .type_test = .{ .span = self.spanFrom(start), .type_ = type_, .binding = binding } };
}

pub fn literalPattern(self: *parser.Parser) ParseError!ast.Pattern {
    const tok = self.advance();
    const value: ast.LiteralValue = switch (tok.kind) {
        .integer => .{ .int = try self.intValue(tok) },
        .float => .{ .float = try self.floatValue(tok) },
        .string => .{ .string = tok.text },
        .kw_true => .{ .bool = true },
        .kw_false => .{ .bool = false },
        else => unreachable,
    };
    return .{ .literal = .{ .span = tok.span, .value = value } };
}

/// `- integer` / `- float` (Grammar `literal-pattern`). The sign is not
/// part of the number token, so a pattern starting with `-` must be
/// followed by a numeric literal.
pub fn negativeLiteralPattern(self: *parser.Parser) ParseError!ast.Pattern {
    const start = self.mark();
    _ = self.advance(); // '-'
    const tok = self.cur();
    const value: ast.LiteralValue = switch (tok.kind) {
        .integer => .{ .neg_int = try self.intValue(tok) },
        .float => .{ .neg_float = try self.floatValue(tok) },
        else => return self.fail(tok.span, "expected an integer or float after '-' in a pattern, found {s}", .{self.describe(tok)}),
    };
    _ = self.advance();
    return .{ .literal = .{ .span = self.spanFrom(start), .value = value } };
}

/// `( )` or `( pattern, ... )` (Grammar `tuple-pattern`). A single bare
/// `(p)` is not a pattern: at least one pattern followed by a comma is
/// required.
pub fn parseTuplePattern(self: *parser.Parser) ParseError!ast.Pattern {
    const start = self.mark();
    _ = self.advance(); // '('
    if (self.eat(.rparen)) return .{ .tuple = .{ .span = self.spanFrom(start), .elems = &.{} } };
    var elems = std.ArrayList(ast.Pattern).empty;
    try elems.append(self.arena.allocator(), try parsePattern(self));
    try self.expectAdvance(.comma, "','");
    if (!self.at(.rparen)) {
        while (true) {
            try elems.append(self.arena.allocator(), try parsePattern(self));
            if (!self.eat(.comma)) break;
        }
    }
    try self.expectAdvance(.rparen, "')'");
    return .{ .tuple = .{ .span = self.spanFrom(start), .elems = try self.arena.allocator().dupe(ast.Pattern, elems.items) } };
}

/// `[ pattern, ... [..rest] ]` or `[..rest]` (Grammar `list-pattern`,
/// `list-pattern-items`, `list-rest`).
pub fn parseListPattern(self: *parser.Parser) ParseError!ast.Pattern {
    const start = self.mark();
    _ = self.advance(); // '['
    var items = std.ArrayList(ast.Pattern).empty;
    var rest: ?ast.Ident = null;
    if (self.eat(.ellipsis)) {
        rest = try self.expectIdent();
    } else if (!self.at(.rbracket)) {
        try items.append(self.arena.allocator(), try parsePattern(self));
        while (self.eat(.comma)) {
            if (self.at(.ellipsis)) {
                _ = self.advance(); // '..'
                rest = try self.expectIdent();
                break;
            }
            try items.append(self.arena.allocator(), try parsePattern(self));
        }
        // `[a ..r]` — the comma before `..rest` is optional.
        if (self.at(.ellipsis)) {
            _ = self.advance(); // '..'
            rest = try self.expectIdent();
        }
    }
    try self.expectAdvance(.rbracket, "']'");
    return .{ .list = .{ .span = self.spanFrom(start), .items = try self.arena.allocator().dupe(ast.Pattern, items.items), .rest = rest } };
}

/// An identifier-leading pattern (Grammar `path-pattern`): the path,
/// optional type arguments (patterns have no indexing, so `[` after a
/// path in pattern position is always type arguments), then one of the
/// `pattern-tail` forms.
pub fn parsePathPattern(self: *parser.Parser) ParseError!ast.Pattern {
    const start = self.mark();
    const path = try parse_type.parseTypePath(self);
    var type_args: ?[]ast.Type = null;
    if (self.at(.lbracket)) type_args = try self.parseTypeArgs();
    switch (self.cur().kind) {
        .lbrace => {
            _ = self.advance();
            var fields = std.ArrayList(ast.FieldPattern).empty;
            if (!self.at(.rbrace)) {
                while (true) {
                    const fstart = self.mark();
                    const fname = try self.expectIdent();
                    var pattern: ?ast.Pattern = null;
                    if (self.eat(.colon)) pattern = try parsePattern(self);
                    try fields.append(self.arena.allocator(), .{ .span = self.spanFrom(fstart), .name = fname, .pattern = pattern });
                    if (!self.eat(.comma)) break;
                    if (self.at(.rbrace)) break;
                }
            }
            try self.expectAdvance(.rbrace, "'}'");
            const sp = ast.StructPattern{ .span = self.spanFrom(start), .fields = try self.arena.allocator().dupe(ast.FieldPattern, fields.items) };
            return .{ .path = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args, .tail = .{ .struct_ = sp } } };
        },
        .dcolon => {
            _ = self.advance();
            const name = try self.expectIdent();
            var args: ?[]ast.Pattern = null;
            if (self.eat(.lparen)) {
                // At least one pattern; no trailing comma.
                var ps = std.ArrayList(ast.Pattern).empty;
                try ps.append(self.arena.allocator(), try parsePattern(self));
                while (self.eat(.comma)) try ps.append(self.arena.allocator(), try parsePattern(self));
                try self.expectAdvance(.rparen, "')'");
                args = try self.arena.allocator().dupe(ast.Pattern, ps.items);
            }
            const vp = ast.VariantPattern{ .span = self.spanFrom(start), .name = name, .args = args };
            return .{ .path = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args, .tail = .{ .variant = vp } } };
        },
        // Parser rule (LL(1) note 3): an identifier immediately
        // following the type path (with optional type arguments) marks
        // a type-test pattern binding (`File f`, `Option[int32] o`,
        // Core §14.7). An identifier alone is an identifier-pattern.
        else => {
            if (self.at(.ident)) {
                const binding = try self.expectIdent();
                const test_type: ast.Type = .{ .named = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args } };
                return .{ .type_test = .{ .span = self.spanFrom(start), .type_ = test_type, .binding = binding } };
            }
            return .{ .path = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args, .tail = .none } };
        },
    }
}
