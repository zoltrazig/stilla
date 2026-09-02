//! Pass: block and statement parsing (Grammar `block`, `let-statement`,
//! `drop-statement`).
//! In:  `*Parser` over a token stream.
//! Out: `ast.Block` / `ast.Stmt` nodes.

const std = @import("std");
const ast = @import("stilla").ast;
const lex = @import("stilla").lex;
const parser = @import("stilla").parser;
const parse_type = @import("type.zig");
const parse_pattern = @import("pattern.zig");
const parse_expr = @import("expr.zig");
const ParseError = parser.ParseError;

pub fn parseBlockRef(self: *parser.Parser) ParseError!*ast.Block {
    return self.newBlock(try parseBlock(self));
}

/// `{ statement* [expression] }` (Grammar `block`). Parser rule (parser
/// note 1): after an expression, `;` makes it an expression statement;
/// `}` makes it the final expression, ending the block. A statement that
/// fails to parse is dropped (its diagnostic recorded) and the block
/// resynchronizes at the next statement boundary, so a whole function
/// body's independent errors surface in one run.
pub fn parseBlock(self: *parser.Parser) ParseError!ast.Block {
    const start = self.mark();
    try self.expectAdvance(.lbrace, "'{'");
    var stmts = std.ArrayList(ast.Stmt).empty;
    var result: ?ast.Expr = null;
    // The brace depth this block opened at: statement recovery stops at
    // `;` / statement starts only at this depth, and leaves the `}` that
    // closes this block to the loop.
    const loop_depth = self.brace_depth;
    while (true) {
        // Recovery safety: an unterminated block ends at EOF instead of
        // looping (the terminal diagnostic was already recorded).
        if (self.at(.eof)) break;
        if (self.eat(.rbrace)) break;
        if (self.at(.semicolon)) {
            try stmts.append(self.arena.allocator(), .{ .empty = .{ .span = self.advance().span } });
            continue;
        }
        if (self.at(.kw_let)) {
            const s = parseLetStmt(self) catch |err| switch (err) {
                error.Syntax => blk: {
                    self.recoverStmt(loop_depth);
                    break :blk null;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (s) |v| try stmts.append(self.arena.allocator(), .{ .let = v });
            continue;
        }
        if (self.at(.kw_drop)) {
            const s = parseDropStmt(self) catch |err| switch (err) {
                error.Syntax => blk: {
                    self.recoverStmt(loop_depth);
                    break :blk null;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (s) |v| try stmts.append(self.arena.allocator(), .{ .drop = v });
            continue;
        }
        if (self.at(.kw_using)) {
            const s = self.parseUsingDecl() catch |err| switch (err) {
                error.Syntax => blk: {
                    self.recoverStmt(loop_depth);
                    break :blk null;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (s) |v| try stmts.append(self.arena.allocator(), .{ .using = v });
            continue;
        }
        const expr = parse_expr.parseExpression(self) catch |err| switch (err) {
            error.Syntax => blk: {
                self.recoverStmt(loop_depth);
                break :blk null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (expr) |e| {
            if (self.eat(.semicolon)) {
                try stmts.append(self.arena.allocator(), .{ .expr = .{ .span = e.span(), .expr = e.* } });
            } else if (self.at(.rbrace)) {
                result = e.*;
                _ = self.advance();
                break;
            } else {
                // A statement without its terminator (the diagnostic is
                // recorded); recover and continue with the next statement.
                self.fail(self.cur().span, "expected ';' or '}}' after expression, found {s}", .{self.describe(self.cur())}) catch {};
                self.recoverStmt(loop_depth);
            }
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
