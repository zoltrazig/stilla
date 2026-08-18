//! Pass: expression parsing (Grammar `expression`, `path-expression`,
//! `paren-or-tuple`, `list-literal`, `lambda`, `if-expression`,
//! `match-expression`, `import-expression`, `arg-list`).
//! In:  `*Parser` over a token stream.
//! Out: `ast.Expr` nodes.

const std = @import("std");
const ast = @import("../ast.zig");
const lex = @import("../lex.zig");
const parser = @import("../parser.zig");
const parse_type = @import("type.zig");
const parse_pattern = @import("pattern.zig");
const parse_stmt = @import("stmt.zig");
const ParseError = parser.ParseError;

// ---------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------

pub fn parseExpression(self: *parser.Parser) ParseError!*ast.Expr {
    // Nesting-depth guard: deeply nested expressions (e.g. thousands
    // of nested parens) must fail with a normal diagnostic instead of
    // exhausting the native stack. 512 nested frames is far beyond
    // anything real code writes, and each `parseExpression` frame is
    // one grammar level (parens, call args, if/match subexpressions,
    // blocks, ...). The counter tracks the current nesting depth and
    // resets as the recursion unwinds.
    if (self.depth >= 512) {
        return self.fail(self.cur().span, "expression nesting too deep (more than {d} levels)", .{512});
    }
    self.depth += 1;
    defer self.depth -= 1;
    return parseLogicOr(
        self,
    );
}

pub fn parseLogicOr(self: *parser.Parser) ParseError!*ast.Expr {
    var lhs = try parseLogicAnd(
        self,
    );
    while (self.eat(.kw_or)) {
        const rhs = try parseLogicAnd(
            self,
        );
        lhs = try binary(self, .or_, lhs, rhs);
    }
    return lhs;
}

pub fn parseLogicAnd(self: *parser.Parser) ParseError!*ast.Expr {
    var lhs = try parseComparison(
        self,
    );
    while (self.eat(.kw_and)) {
        const rhs = try parseComparison(
            self,
        );
        lhs = try binary(self, .and_, lhs, rhs);
    }
    return lhs;
}

/// `comparison` is non-associative: at most one comparison operator
/// (Grammar `comparison`, Core §16).
pub fn parseComparison(self: *parser.Parser) ParseError!*ast.Expr {
    const lhs = try parseAddition(
        self,
    );
    const op: ?ast.BinaryOp = switch (self.cur().kind) {
        .eq_eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        else => null,
    };
    const o = op orelse return lhs;
    _ = self.advance();
    const rhs = try parseAddition(
        self,
    );
    return binary(self, o, lhs, rhs);
}

pub fn parseAddition(self: *parser.Parser) ParseError!*ast.Expr {
    var lhs = try parseMultiply(
        self,
    );
    while (true) {
        const op: ?ast.BinaryOp = switch (self.cur().kind) {
            .plus => .add,
            .minus => .sub,
            else => null,
        };
        const o = op orelse break;
        _ = self.advance();
        const rhs = try parseMultiply(
            self,
        );
        lhs = try binary(self, o, lhs, rhs);
    }
    return lhs;
}

pub fn parseMultiply(self: *parser.Parser) ParseError!*ast.Expr {
    var lhs = try parseUnary(
        self,
    );
    while (true) {
        const op: ?ast.BinaryOp = switch (self.cur().kind) {
            .star => .mul,
            .slash => .div,
            .percent => .rem,
            else => null,
        };
        const o = op orelse break;
        _ = self.advance();
        const rhs = try parseUnary(
            self,
        );
        lhs = try binary(self, o, lhs, rhs);
    }
    return lhs;
}

pub fn parseUnary(self: *parser.Parser) ParseError!*ast.Expr {
    switch (self.cur().kind) {
        .minus, .bang => {
            // Nesting-depth guard: a unary chain (`!!!!x`, `---x`)
            // recurses through parseUnary without passing through
            // parseExpression, so it counts against the same shared
            // 512-level cap with the same diagnostic (see
            // parseExpression); the bound keeps both the parser and the
            // recursive unary lowering (lowerUnary) off the native-stack
            // edge for pathological input.
            if (self.depth >= 512) {
                return self.fail(self.cur().span, "expression nesting too deep (more than {d} levels)", .{512});
            }
            self.depth += 1;
            defer self.depth -= 1;
            const tok = self.advance();
            const operand = try parseUnary(
                self,
            );
            const op: ast.UnaryOp = if (tok.kind == .minus) .neg else .not;
            return self.newExpr(.{ .unary = .{ .span = ast.Span.merge(tok.span, operand.span()), .op = op, .operand = operand } });
        },
        .kw_move => {
            const tok = self.advance();
            const name = try self.expectIdent();
            return self.newExpr(.{ .move = .{ .span = ast.Span.merge(tok.span, name.span), .name = name } });
        },
        else => return parseCast(
            self,
        ),
    }
}

/// `postfix ( as type )*` (Grammar `cast`, Core §16). Casts chain:
/// `x as a as b` is a cast whose operand is the inner cast.
pub fn parseCast(self: *parser.Parser) ParseError!*ast.Expr {
    var operand = try parsePostfix(
        self,
    );
    while (self.at(.kw_as)) {
        _ = self.advance();
        const target = try parse_type.parseType(self);
        operand = try self.newExpr(.{ .cast = .{ .span = ast.Span.merge(operand.span(), target.span()), .operand = operand, .target = target } });
    }
    return operand;
}

pub fn parsePostfix(self: *parser.Parser) ParseError!*ast.Expr {
    var expr = try parsePrimary(
        self,
    );
    while (true) {
        switch (self.cur().kind) {
            .dot => {
                _ = self.advance();
                const name = try self.expectIdent();
                expr = try self.newExpr(.{ .member = .{ .span = ast.Span.merge(expr.span(), name.span), .object = expr, .name = name } });
            },
            .lparen => {
                _ = self.advance();
                const args = try parseArgListRest(
                    self,
                );
                expr = try self.newExpr(.{ .call = .{ .span = ast.Span.merge(expr.span(), self.prev().span), .callee = expr, .args = args } });
            },
            // `:: [types]` after a non-path primary (Grammar
            // `specialization-suffix`); a `::` immediately after a
            // type-path was consumed by `path-tail` (LL(1) note 2).
            .dcolon => {
                _ = self.advance();
                const type_args = try self.parseTypeArgs();
                expr = try self.newExpr(.{ .specialize = .{ .span = ast.Span.merge(expr.span(), self.prev().span), .operand = expr, .type_args = type_args } });
            },
            else => return expr,
        }
    }
}

pub fn parsePrimary(self: *parser.Parser) ParseError!*ast.Expr {
    const tok = self.cur();
    return switch (tok.kind) {
        .kw_true => blk: {
            const t = self.advance();
            break :blk self.newExpr(.{ .bool = .{ .span = t.span, .value = true } });
        },
        .kw_false => blk: {
            const t = self.advance();
            break :blk self.newExpr(.{ .bool = .{ .span = t.span, .value = false } });
        },
        .integer => blk: {
            const t = self.advance();
            break :blk self.newExpr(.{ .int = .{ .span = t.span, .value = try self.intValue(t) } });
        },
        .float => blk: {
            const t = self.advance();
            break :blk self.newExpr(.{ .float = .{ .span = t.span, .value = try self.floatValue(t) } });
        },
        .string => blk: {
            const t = self.advance();
            break :blk self.newExpr(.{ .string = .{ .span = t.span, .value = t.text } });
        },
        // The `builtin` module is an ordinary identifier path (Core §3):
        // programs import it like any other module, so it needs no
        // reserved-word handling here.
        .ident => parsePathExpr(
            self,
        ),
        .lparen => parseParenOrTuple(
            self,
        ),
        .lbracket => parseListLiteral(
            self,
        ),
        .kw_fn => parseLambda(
            self,
        ),
        .kw_if => parseIfExpr(
            self,
        ),
        .kw_match => parseMatchExpr(
            self,
        ),
        .kw_import => parseImportExpr(
            self,
        ),
        .lbrace => blk: {
            const b = try parse_stmt.parseBlock(self);
            break :blk self.newExpr(.{ .block = .{ .span = b.span, .block = try self.newBlock(b) } });
        },
        else => self.fail(tok.span, "expected an expression, found {s}", .{self.describe(tok)}),
    };
}

/// An identifier-leading expression (Grammar `path-expression`): the
/// path, optional type arguments, then one of the `path-tail` forms.
pub fn parsePathExpr(self: *parser.Parser) ParseError!*ast.Expr {
    const start = self.mark();
    const path = try parse_type.parseTypePath(self);
    var type_args: ?[]ast.Type = null;
    if (self.at(.lbracket)) type_args = try self.parseTypeArgs();
    switch (self.cur().kind) {
        .lbrace => {
            const cstart = self.mark();
            try self.expectAdvance(.lbrace, "'{'");
            var fields = std.ArrayList(ast.StructFieldInit).empty;
            if (!self.at(.rbrace)) {
                while (true) {
                    const fstart = self.mark();
                    const fname = try self.expectIdent();
                    try self.expectAdvance(.colon, "':'");
                    const value = try parseExpression(
                        self,
                    );
                    try fields.append(self.arena.allocator(), .{ .span = self.spanFrom(fstart), .name = fname, .value = value });
                    if (!self.eat(.comma)) break;
                    if (self.at(.rbrace)) break;
                }
            }
            try self.expectAdvance(.rbrace, "'}'");
            const construct = ast.StructConstruct{ .span = self.spanFrom(cstart), .fields = try self.arena.allocator().dupe(ast.StructFieldInit, fields.items) };
            return self.newExpr(.{ .path = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args, .tail = .{ .construct = construct } } });
        },
        .dcolon => {
            // Parser rule (LL(1) note 2): a `::` immediately following
            // a type-path always enters the `path-tail` branch.
            _ = self.advance();
            const vstart = self.mark();
            if (self.at(.ident)) {
                const name = try self.expectIdent();
                var args: ?[]ast.Expr = null;
                if (self.eat(.lparen)) args = try parseArgListRest(
                    self,
                );
                const variant = ast.VariantExpr{ .span = self.spanFrom(vstart), .name = name, .args = args };
                return self.newExpr(.{ .path = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args, .tail = .{ .variant = variant } } });
            }
            if (self.at(.lbracket)) {
                const tail_args = try self.parseTypeArgs();
                const base = try self.newExpr(.{ .path = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args, .tail = .none } });
                return self.newExpr(.{ .specialize = .{ .span = self.spanFrom(start), .operand = base, .type_args = tail_args } });
            }
            return self.fail(self.cur().span, "expected a variant name or type arguments after '::', found {s}", .{self.describe(self.cur())});
        },
        else => return self.newExpr(.{ .path = .{ .span = self.spanFrom(start), .path = path, .type_args = type_args, .tail = .none } }),
    }
}

/// `( )`, `( e )`, `( e, ... )`, `( e, )` (Grammar `paren-or-tuple`).
/// A single-element tuple is written `(e,)`; `(e)` is a parenthesized
/// expression.
pub fn parseParenOrTuple(self: *parser.Parser) ParseError!*ast.Expr {
    const start = self.mark();
    _ = self.advance(); // '('
    if (self.eat(.rparen)) return self.newExpr(.{ .void = .{ .span = self.spanFrom(start) } });
    const first = try parseExpression(
        self,
    );
    if (self.eat(.rparen)) return self.newExpr(.{ .paren = .{ .span = self.spanFrom(start), .inner = first } });
    try self.expectAdvance(.comma, "','");
    var elems = std.ArrayList(ast.Expr).empty;
    try elems.append(self.arena.allocator(), first.*);
    if (!self.at(.rparen)) {
        while (true) {
            try elems.append(self.arena.allocator(), (try parseExpression(
                self,
            )).*);
            if (!self.eat(.comma)) break;
        }
    }
    try self.expectAdvance(.rparen, "')'");
    return self.newExpr(.{ .tuple = .{ .span = self.spanFrom(start), .elems = try self.arena.allocator().dupe(ast.Expr, elems.items) } });
}

/// `[ e, ... ]` with optional trailing comma (Grammar `list-literal`).
pub fn parseListLiteral(self: *parser.Parser) ParseError!*ast.Expr {
    const start = self.mark();
    _ = self.advance(); // '['
    var elems = std.ArrayList(ast.Expr).empty;
    if (!self.at(.rbracket)) {
        while (true) {
            try elems.append(self.arena.allocator(), (try parseExpression(
                self,
            )).*);
            if (!self.eat(.comma)) break;
            if (self.at(.rbracket)) break;
        }
    }
    try self.expectAdvance(.rbracket, "']'");
    return self.newExpr(.{ .list = .{ .span = self.spanFrom(start), .elems = try self.arena.allocator().dupe(ast.Expr, elems.items) } });
}

pub fn parseLambda(self: *parser.Parser) ParseError!*ast.Expr {
    const start = self.mark();
    _ = self.advance(); // kw_fn
    try self.expectAdvance(.lparen, "'('");
    const params = try self.parseParamList();
    var ret: ?ast.Type = null;
    if (self.eat(.arrow)) ret = try parse_type.parseType(self);
    const body = try parse_stmt.parseBlockRef(self);
    return self.newExpr(.{ .lambda = .{ .span = self.spanFrom(start), .params = params, .ret = ret, .body = body } });
}

pub fn parseIfExpr(self: *parser.Parser) ParseError!*ast.Expr {
    const start = self.mark();
    _ = self.advance(); // kw_if
    try self.expectAdvance(.lparen, "'('");
    const cond = try parseExpression(
        self,
    );
    try self.expectAdvance(.rparen, "')'");
    const then = try parse_stmt.parseBlockRef(self);
    var else_: ?*ast.Expr = null;
    if (self.eat(.kw_else)) {
        switch (self.cur().kind) {
            .kw_if => else_ = try parseIfExpr(
                self,
            ),
            .lbrace => {
                const b = try parse_stmt.parseBlock(self);
                else_ = try self.newExpr(.{ .block = .{ .span = b.span, .block = try self.newBlock(b) } });
            },
            else => return self.fail(self.cur().span, "expected 'if' or a block after 'else', found {s}", .{self.describe(self.cur())}),
        }
    }
    return self.newExpr(.{ .if_ = .{ .span = self.spanFrom(start), .cond = cond, .then = then, .else_ = else_ } });
}

pub fn parseMatchExpr(self: *parser.Parser) ParseError!*ast.Expr {
    const start = self.mark();
    _ = self.advance(); // kw_match
    try self.expectAdvance(.lparen, "'('");
    const scrutinee = try parseExpression(
        self,
    );
    try self.expectAdvance(.rparen, "')'");
    try self.expectAdvance(.lbrace, "'{'");
    var arms = std.ArrayList(ast.MatchArm).empty;
    if (!self.at(.rbrace)) {
        while (true) {
            const astart = self.mark();
            const pattern = try parse_pattern.parsePattern(self);
            try self.expectAdvance(.fat_arrow, "'=>'");
            const body = try parseExpression(
                self,
            );
            try arms.append(self.arena.allocator(), .{ .span = self.spanFrom(astart), .pattern = pattern, .body = body });
            if (!self.eat(.comma)) break;
            if (self.at(.rbrace)) break;
        }
    }
    try self.expectAdvance(.rbrace, "'}'");
    return self.newExpr(.{ .match = .{ .span = self.spanFrom(start), .scrutinee = scrutinee, .arms = try self.arena.allocator().dupe(ast.MatchArm, arms.items) } });
}

pub fn parseImportExpr(self: *parser.Parser) ParseError!*ast.Expr {
    const start = self.mark();
    _ = self.advance(); // kw_import
    try self.expectAdvance(.lparen, "'('");
    const tok = self.cur();
    if (tok.kind != .string) return self.fail(tok.span, "expected a string literal in import, found {s}", .{self.describe(tok)});
    _ = self.advance();
    try self.expectAdvance(.rparen, "')'");
    return self.newExpr(.{ .import = .{ .span = self.spanFrom(start), .module = tok.text } });
}

/// `[ expression, ... ]` with the `(` already consumed; no trailing
/// comma (Grammar `arg-list`).
pub fn parseArgListRest(self: *parser.Parser) ![]ast.Expr {
    var args = std.ArrayList(ast.Expr).empty;
    if (!self.at(.rparen)) {
        while (true) {
            try args.append(self.arena.allocator(), (try parseExpression(
                self,
            )).*);
            if (!self.eat(.comma)) break;
        }
    }
    try self.expectAdvance(.rparen, "')'");
    return self.arena.allocator().dupe(ast.Expr, args.items);
}

pub fn binary(self: *parser.Parser, op: ast.BinaryOp, lhs: *ast.Expr, rhs: *ast.Expr) ParseError!*ast.Expr {
    return self.newExpr(.{ .binary = .{ .span = ast.Span.merge(lhs.span(), rhs.span()), .op = op, .lhs = lhs, .rhs = rhs } });
}
