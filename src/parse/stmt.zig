//! Pass: block and statement parsing (Grammar `block`, `let-statement`,
//! `drop-statement`).
//! In:  `*Parser` over a token stream.
//! Out: `ast.Block` / `ast.Stmt` nodes.

const std = @import("std");
const ast = @import("../ast.zig");
const lex = @import("../lex.zig");
const parser = @import("../parser.zig");
const parse_type = @import("type.zig");
const parse_pattern = @import("pattern.zig");
const parse_expr = @import("expr.zig");
const ParseError = parser.ParseError;

pub fn parseBlockRef(self: *parser.Parser) ParseError!*ast.Block {
    return self.newBlock(try parseBlock(self));
}

/// `{ statement* [expression] }` (Grammar `block`). Parser rule (LL(1)
/// note 1): after an expression, `;` makes it an expression statement;
/// `}` makes it the final expression, ending the block.
pub fn parseBlock(self: *parser.Parser) ParseError!ast.Block {
    const start = self.mark();
    try self.expectAdvance(.lbrace, "'{'");
    var stmts = std.ArrayList(ast.Stmt).empty;
    var result: ?ast.Expr = null;
    while (true) {
        if (self.eat(.rbrace)) break;
        if (self.at(.semicolon)) {
            try stmts.append(self.arena.allocator(), .{ .empty = .{ .span = self.advance().span } });
            continue;
        }
        if (self.at(.kw_let)) {
            try stmts.append(self.arena.allocator(), .{ .let = try parseLetStmt(self) });
            continue;
        }
        if (self.at(.kw_drop)) {
            try stmts.append(self.arena.allocator(), .{ .drop = try parseDropStmt(self) });
            continue;
        }
        if (self.at(.kw_using)) {
            try stmts.append(self.arena.allocator(), .{ .using = try self.parseUsingDecl() });
            continue;
        }
        const expr = try parse_expr.parseExpression(self);
        if (self.eat(.semicolon)) {
            try stmts.append(self.arena.allocator(), .{ .expr = .{ .span = expr.span(), .expr = expr.* } });
        } else if (self.at(.rbrace)) {
            result = expr.*;
            _ = self.advance();
            break;
        } else {
            return self.fail(self.cur().span, "expected ';' or '}}' after expression, found {s}", .{self.describe(self.cur())});
        }
    }
    return .{ .span = self.spanFrom(start), .stmts = try self.arena.allocator().dupe(ast.Stmt, stmts.items), .result = result };
}

pub fn parseLetStmt(self: *parser.Parser) ParseError!ast.LetStmt {
    const start = self.mark();
    _ = self.advance(); // kw_let
    const pattern = try parse_pattern.parsePattern(self);
    var type_: ?ast.Type = null;
    if (self.eat(.colon)) type_ = try parse_type.parseType(self);
    try self.expectAdvance(.equals, "'='");
    const init_expr = try parse_expr.parseExpression(self);
    try self.expectAdvance(.semicolon, "';'");
    return .{ .span = self.spanFrom(start), .pattern = pattern, .type_ = type_, .init = init_expr };
}

pub fn parseDropStmt(self: *parser.Parser) ParseError!ast.DropStmt {
    const start = self.mark();
    _ = self.advance(); // kw_drop
    const name = try self.expectIdent();
    try self.expectAdvance(.semicolon, "';'");
    return .{ .span = self.spanFrom(start), .name = name };
}
