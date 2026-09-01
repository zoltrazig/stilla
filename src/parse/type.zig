//! Pass: type parsing (Grammar `type`, `type-path`).
//! In:  `*Parser` over a token stream.
//! Out: `ast.Type` nodes.

const std = @import("std");
const ast = @import("stilla").ast;
const lex = @import("stilla").lex;
const parser = @import("stilla").parser;
const ParseError = parser.ParseError;

/// `type` (Grammar `type`). Nesting-depth guard: nested type constructors
/// (`list[box[list[..]]]`) recurse through `parseType`; cap the depth like
/// `parseExpression`.
pub fn parseType(self: *parser.Parser) ParseError!ast.Type {
    const start = self.mark();
    if (self.depth >= 512) {
        return self.fail(self.cur().span, "type nesting too deep (more than {d} levels)", .{512});
    }
    self.depth += 1;
    defer self.depth -= 1;
    return parseTypeInner(self, start);
}

pub fn parseTypeInner(self: *parser.Parser, start: usize) ParseError!ast.Type {
    return switch (self.cur().kind) {
        .kw_any => primitive(self, start, .any),
        .kw_byte => primitive(self, start, .byte),
        .kw_int32 => primitive(self, start, .int32),
        .kw_int64 => primitive(self, start, .int64),
        .kw_uint64 => primitive(self, start, .uint64),
        .kw_uint32 => primitive(self, start, .uint32),
        .kw_float32 => primitive(self, start, .float32),
        .kw_float64 => primitive(self, start, .float64),
        .kw_hostdata => primitive(self, start, .hostdata),
        .kw_bool => primitive(self, start, .bool),
        .kw_str => primitive(self, start, .str),
        .kw_void => primitive(self, start, .void),
        .kw_never => primitive(self, start, .never),
        .kw_list => blk: {
            _ = self.advance();
            try self.expectAdvance(.lbracket, "'['");
            const elem = try parseType(self);
            try self.expectAdvance(.rbracket, "']'");
            break :blk .{ .list = .{ .span = self.spanFrom(start), .elem = try self.newType(elem) } };
        },
        .kw_box => blk: {
            _ = self.advance();
            try self.expectAdvance(.lbracket, "'['");
            const inner = try parseType(self);
            try self.expectAdvance(.rbracket, "']'");
            break :blk .{ .box = .{ .span = self.spanFrom(start), .inner = try self.newType(inner) } };
        },
        .kw_tuple => blk: {
            _ = self.advance();
            try self.expectAdvance(.lbracket, "'['");
            var elems = std.ArrayList(ast.Type).empty;
            while (true) {
                try elems.append(self.arena.allocator(), try parseType(self));
                if (!self.eat(.comma)) break;
            }
            try self.expectAdvance(.rbracket, "']'");
            break :blk .{ .tuple = .{ .span = self.spanFrom(start), .elems = try self.arena.allocator().dupe(ast.Type, elems.items) } };
        },
        .kw_fn => parseFunctionType(self, start),
        .ident => blk: {
            const path = try parseTypePath(self);
            var type_args: ?[]ast.Type = null;
            if (self.at(.lbracket)) type_args = try self.parseTypeArgs();
            break :blk .{ .named = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args } };
        },
        else => self.fail(self.cur().span, "expected a type, found {s}", .{self.describe(self.cur())}),
    };
}

pub fn primitive(self: *parser.Parser, start: usize, kind: ast.PrimitiveKind) ParseError!ast.Type {
    const tok = self.advance();
    _ = start;
    return .{ .primitive = .{ .span = tok.span, .kind = kind } };
}

pub fn parseFunctionType(self: *parser.Parser, start: usize) ParseError!ast.Type {
    _ = self.advance(); // kw_fn
    try self.expectAdvance(.lparen, "'('");
    var params = std.ArrayList(ast.FunctionParamType).empty;
    if (!self.at(.rparen)) {
        while (true) {
            const pstart = self.mark();
            const mode = self.takeMode();
            const type_ = try parseType(self);
            try params.append(self.arena.allocator(), .{ .span = self.spanFrom(pstart), .mode = mode, .type_ = try self.newType(type_) });
            if (!self.eat(.comma)) break;
        }
    }
    try self.expectAdvance(.rparen, "')'");
    try self.expectAdvance(.arrow, "'->'");
    const ret = try parseType(self);
    return .{ .function = .{ .span = self.spanFrom(start), .params = try self.arena.allocator().dupe(ast.FunctionParamType, params.items), .ret = try self.newType(ret) } };
}

/// `name ( . name )*` (Grammar `type-path`). Each segment may be an
/// identifier or a reserved word, so that paths such as `builtin.str`
/// and `builtin.Option` parse (Grammar note, Core §2.8). `builtin` is
/// an ordinary imported module, not a reserved word (Core §3).
pub fn parseTypePath(self: *parser.Parser) ![]ast.Ident {
    var path = std.ArrayList(ast.Ident).empty;
    try path.append(self.arena.allocator(), try self.expectPathSegment());
    while (self.eat(.dot)) try path.append(self.arena.allocator(), try self.expectPathSegment());
    return self.arena.allocator().dupe(ast.Ident, path.items);
}
