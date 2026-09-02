//! Pass: expression parsing — the expression grammar of the Binding Power
//! Table document (Stilla Expression Binding Power Table.md): `expression`,
//! `path-expression`, `paren-or-tuple`, `list-literal`, `lambda`,
//! `if-expression`, `match-expression`, `import-expression`, `arg-list`.
//! In:  `*Parser` over a token stream.
//! Out: `ast.Expr` nodes.

const std = @import("std");
const ast = @import("stilla").ast;
const lex = @import("stilla").lex;
const parser = @import("stilla").parser;
const parse_type = @import("type.zig");
const parse_pattern = @import("pattern.zig");
const parse_stmt = @import("stmt.zig");
const ParseError = parser.ParseError;

// ---------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------

pub fn parseExpression(self: *parser.Parser) ParseError!*ast.Expr {
    return parseExpressionBp(self, 0);
}

/// One infix row of the binding power table (Stilla Expression Binding
/// Power Table.md): the AST operator, its left binding power, and
/// whether it is one of the non-chaining comparison operators. The
/// right binding power is always `lbp + 1` (left-associativity), so it
/// is not stored.
const InfixInfo = struct {
    op: ast.BinaryOp,
    lbp: u8,
    is_comparison: bool = false,
};

/// The infix levels, loosest to tightest:
/// `or < and < comparison < | < ^ < & < <<,>> < +,- < *,/,%`
/// (Binding Power Table document; Core §16). Every infix operator here
/// is left-associative except the comparisons, which are
/// non-associative and non-chaining (their right operand parses at
/// `lbp + 1`, so it stops before another comparison). `as` (power 10)
/// is not in this table:
/// its right side is a TYPE, so parseExpressionBp handles it directly.
fn infixInfo(kind: lex.TokenKind) ?InfixInfo {
    return switch (kind) {
        .kw_or => .{ .op = .or_, .lbp = 1 },
        .kw_and => .{ .op = .and_, .lbp = 2 },
        .eq_eq => .{ .op = .eq, .lbp = 3, .is_comparison = true },
        .ne => .{ .op = .ne, .lbp = 3, .is_comparison = true },
        .lt => .{ .op = .lt, .lbp = 3, .is_comparison = true },
        .le => .{ .op = .le, .lbp = 3, .is_comparison = true },
        .gt => .{ .op = .gt, .lbp = 3, .is_comparison = true },
        .ge => .{ .op = .ge, .lbp = 3, .is_comparison = true },
        .pipe => .{ .op = .bitor, .lbp = 4 },
        .caret => .{ .op = .bitxor, .lbp = 5 },
        .ampersand => .{ .op = .bitand, .lbp = 6 },
        .shl => .{ .op = .shl, .lbp = 7 },
        .shr => .{ .op = .shr, .lbp = 7 },
        .plus => .{ .op = .add, .lbp = 8 },
        .minus => .{ .op = .sub, .lbp = 8 },
        .star => .{ .op = .mul, .lbp = 9 },
        .slash => .{ .op = .div, .lbp = 9 },
        .percent => .{ .op = .rem, .lbp = 9 },
        else => null,
    };
}

/// The binding-power loop (`parse_expression(min_bp)` in the Binding
/// Power Table document's normative parser algorithm; top-level calls
/// use min_bp = 0).
fn parseExpressionBp(self: *parser.Parser, min_bp: u8) ParseError!*ast.Expr {
    // Nesting-depth guard: deeply nested expressions (e.g. thousands
    // of nested parens) must fail with a normal diagnostic instead of
    // exhausting the native stack. 512 nested frames is far beyond
    // anything real code writes, and each parseExpressionBp frame is
    // one binding-power recursion (parens, call args, if/match
    // subexpressions, blocks, prefix operands, comparison right
    // operands, ...). The counter tracks the current nesting depth and
    // resets as the recursion unwinds.
    if (self.depth >= 512) {
        return self.fail(self.cur().span, "expression nesting too deep (more than {d} levels)", .{512});
    }
    self.depth += 1;
    defer self.depth -= 1;

    var left = try parseNud(self);
    while (true) {
        // `as` sits at power 10 and its right side is a type, not an
        // expression (Binding Power Table document, `as` row; Core §16),
        // so it is handled before the infix table. Casts chain left:
        // `x as a as b` is a cast whose operand is the inner cast.
        if (self.at(.kw_as)) {
            if (10 < min_bp) return left;
            _ = self.advance();
            const target = try parse_type.parseType(self);
            left = try self.newExpr(.{ .cast = .{ .span = ast.Span.merge(left.span(), target.span()), .operand = left, .target = target } });
            continue;
        }
        const info = infixInfo(self.cur().kind) orelse return left;
        if (info.lbp < min_bp) return left;
        _ = self.advance();
        const rhs = try parseExpressionBp(self, info.lbp + 1);
        left = try binary(self, info.op, left, rhs);
        // Comparisons do not chain: `a < b < c` is an error, not
        // `(a < b) < c` (Binding Power Table document, parser
        // algorithm's comparison branch).
        if (info.is_comparison) {
            if (infixInfo(self.cur().kind)) |next| {
                if (next.is_comparison) return self.fail(self.cur().span, "comparisons do not chain", .{});
            }
        }
    }
}

/// The nud of the parser algorithm: a prefix operator, a `move`, or a
/// primary form whose own postfix chain (`.name`, call, `::[types]`)
/// is consumed here (parsePostfix). The chain never re-opens after an
/// infix operator or a cast — those tokens return to
/// parseExpressionBp instead.
fn parseNud(self: *parser.Parser) ParseError!*ast.Expr {
    switch (self.cur().kind) {
        .minus, .bang => {
            // Prefix `-`/`!` parse their operand at power 10 (the `as`
            // level): `-x as int32` is `-(x as int32)` and `-f().x` is
            // `-(f().x)` (Binding Power Table document, prefix row).
            // Prefix chains (`!!!!x`) recurse through parseExpressionBp,
            // so they count against the same shared 512-level cap with
            // the same diagnostic (see parseExpressionBp); the bound
            // keeps both the parser and the recursive unary lowering
            // (lowerUnary) off the native-stack edge.
            const tok = self.advance();
            const operand = try parseExpressionBp(self, 10);
            const op: ast.UnaryOp = if (tok.kind == .minus) .neg else .not;
            return self.newExpr(.{ .unary = .{ .span = ast.Span.merge(tok.span, operand.span()), .op = op, .operand = operand } });
        },
        .kw_move => {
            // `move` takes a complete binding name, not an expression —
            // there is no partial move (Core §13.4).
            const tok = self.advance();
            const name = try self.expectIdent();
            return self.newExpr(.{ .move = .{ .span = ast.Span.merge(tok.span, name.span), .name = name } });
        },
        else => return parsePostfix(self),
    }
}

pub fn parsePostfix(self: *parser.Parser) ParseError!*ast.Expr {
    var expr = try parsePrimary(
        self,
    );
    while (true) {
        switch (self.cur().kind) {
            .dot => {
                _ = self.advance();
                // The postfix chain (Binding Power Table document): the token after
                // "." is read as a member name even when it is a reserved word, so members
                // such as `f().str` and `(m).box` parse after any primary,
                // exactly as path segments already do (`builtin.str`).
                const name = try self.expectPathSegment();
                expr = try self.newExpr(.{ .member = .{ .span = ast.Span.merge(expr.span(), name.span), .object = expr, .name = name } });
            },
            .lparen => {
                _ = self.advance();
                const args = try parseArgListRest(
                    self,
                );
                expr = try self.newExpr(.{ .call = .{ .span = ast.Span.merge(expr.span(), self.prev().span), .callee = expr, .args = args } });
            },
            // `:: [types]` after a non-path primary is the postfix
            // specialization suffix (Binding Power Table document); a `::`
            // immediately after a type-path was already consumed by the
            // path-expression nud.
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

/// An identifier-leading expression (Binding Power Table document,
/// path-expression nud): the path, optional type arguments, then one of
/// the `path-tail` forms.
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
            // Binding Power Table document (path-expression nud): a `::`
            // immediately following a type-path always enters the
            // `path-tail` branch.
            _ = self.advance();
            const vstart = self.mark();
            // A variant name after `::` may be a reserved word, exactly
            // as a member name after `.` (Binding Power Table document,
            // postfix chain).
            if (self.atPathSegment()) {
                const name = try self.expectPathSegment();
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

/// `( )`, `( e )`, `( e, ... )`, `( e, )` (Binding Power Table document,
/// paren/tuple form).
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

/// `[ e, ... ]` with optional trailing comma (Binding Power Table
/// document, list-literal form).
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
    // The return type is required (Core §6.3, §6.4), as for a named
    // function; a lambda with no value declares `-> void`.
    if (!self.eat(.arrow)) {
        return self.fail(self.cur().span, "a lambda must declare its return type ('-> T'); write '-> void' when it returns nothing", .{});
    }
    const ret = try parse_type.parseType(self);
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
    // The `match` form (Binding Power Table document) requires at least
    // one arm (`match-arm *( "," match-arm ) [ "," ]`); the loop below
    // always parses one before its first comma test.
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
/// comma (Binding Power Table document, call suffix).
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
