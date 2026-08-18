//! LL(k) parser for the Stilla core language (Grammar v1.3 Draft) — turns
//! a source file's token stream into an `ast.Program`.
//!
//! The grammar is designed to be LL(1)-parseable over the lexical token
//! stream ("LL(1) parsing notes"): every decision point is resolvable with
//! one token of lookahead, except two documented two-token points —
//! `path-tail` after `::`, and the block statement loop's `;` / `}` split.
//! The parser works over a pre-lexed token buffer (`lex.Lexer`), so it
//! provides arbitrary lookahead; k = 2 suffices for the whole grammar.
//!
//! All AST nodes are allocated in the parser's arena and live until
//! `deinit`. On `error.Syntax`, `diag` holds the first parse error with the
//! `Span` of the offending token; node spans let later stages (type
//! checking, code generation) point at the exact source text.

const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lex.zig");
const parse_type = @import("parse/type.zig");
const parse_pattern = @import("parse/pattern.zig");
const parse_stmt = @import("parse/stmt.zig");
const parse_expr = @import("parse/expr.zig");

/// Errors produced by parsing: `Syntax` carries a diagnostic in
/// `Parser.diag`; `OutOfMemory` propagates from arena allocation.
pub const ParseError = error{ Syntax, OutOfMemory };

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,
    tokens: []const lex.Token = &.{},
    /// The first syntax error, when parsing failed (or a lexer error).
    diag: ?ast.Diagnostic = null,
    /// Cursor into `tokens`.
    pos: usize = 0,
    /// Current expression/type nesting depth (see `parseExpression`):
    /// pathological input must produce a diagnostic, not a stack overflow.
    depth: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    /// Lex and parse one source file. The returned `ast.Program` (and the
    /// diagnostic message, on error) reference the arena, so both are valid
    /// only until `deinit`. The caller keeps `source` (and its text) alive
    /// for the program's lifetime.
    pub fn parse(self: *Parser, source: *const ast.Source) ParseError!ast.Program {
        var lexer = lex.Lexer.init(self.arena.allocator(), source);
        self.tokens = lexer.tokenize() catch |err| {
            self.diag = lexer.diag;
            return err;
        };
        self.pos = 0;
        return .{ .items = try self.parseModuleItems() };
    }

    // ---------------------------------------------------------------------
    // Program structure
    // ---------------------------------------------------------------------

    pub fn parseModuleItems(self: *Parser) ![]ast.ModuleItem {
        var items = std.ArrayList(ast.ModuleItem).empty;
        while (!self.at(.eof)) try items.append(self.arena.allocator(), try self.parseModuleItem());
        return self.arena.allocator().dupe(ast.ModuleItem, items.items);
    }

    pub fn parseModuleItem(self: *Parser) ParseError!ast.ModuleItem {
        return switch (self.cur().kind) {
            .kw_const => .{ .const_def = try self.parseConstDef() },
            .kw_fn => .{ .func_def = try self.parseFuncDef() },
            .kw_type => .{ .type_def = try self.parseTypeDef() },
            .kw_struct => .{ .struct_def = try self.parseStructDef() },
            .kw_union => .{ .union_def = try self.parseUnionDef() },
            .kw_opaque => .{ .opaque_def = try self.parseOpaqueDef() },
            .kw_using => .{ .using_decl = try self.parseUsingDecl() },
            else => self.fail(self.cur().span, "expected a module item ('const', 'fn', 'type', 'struct', 'union', 'opaque', or 'using'), found {s}", .{self.describe(self.cur())}),
        };
    }

    pub fn parseConstDef(self: *Parser) ParseError!ast.ConstDef {
        const start = self.mark();
        _ = self.advance(); // kw_const
        const name = try self.expectIdent();
        var type_: ?ast.Type = null;
        if (self.eat(.colon)) type_ = try parse_type.parseType(self);
        // Declaration-only (host binding — phase3-cfg-lowering.md, System calls for host bindings): `const name: type;`
        // has no initializer — the host provides the value.
        if (self.eat(.semicolon)) {
            return .{ .span = self.spanFrom(start), .name = name, .type_ = type_, .init = null };
        }
        try self.expectAdvance(.equals, "'='");
        const init_expr = try parse_expr.parseExpression(self);
        try self.expectAdvance(.semicolon, "';'");
        return .{ .span = self.spanFrom(start), .name = name, .type_ = type_, .init = init_expr };
    }

    pub fn parseFuncDef(self: *Parser) ParseError!ast.FuncDef {
        const start = self.mark();
        _ = self.advance(); // kw_fn
        // Host-binding declarations name members of implementation-provided
        // modules, which may collide with reserved words (`builtin.str`,
        // `builtin.box`, Runtime §4): accept a reserved word as the name,
        // exactly as path segments may (Grammar `type-path` note).
        const name_tok = self.cur();
        const name = try self.expectPathSegment();
        const name_is_reserved = name_tok.kind != .ident;
        const type_params = try self.parseOptionalTypeParams();
        try self.expectAdvance(.lparen, "'('");
        const params = try self.parseParamList();
        var ret: ?ast.Type = null;
        if (self.eat(.arrow)) ret = try parse_type.parseType(self);
        // Declaration-only (host binding — phase3-cfg-lowering.md, System calls for host bindings): `fn name(...) -> type;`
        // has no body — calls lower to system calls.
        if (self.eat(.semicolon)) {
            return .{ .span = self.spanFrom(start), .name = name, .type_params = type_params, .params = params, .ret = ret, .body = null };
        }
        const body = try parse_stmt.parseBlockRef(self);
        // A reserved word may name a host binding, but never a function with
        // a Stilla definition.
        if (name_is_reserved) {
            return self.fail(name.span, "function name '{s}' is a reserved word", .{name.text});
        }
        return .{ .span = self.spanFrom(start), .name = name, .type_params = type_params, .params = params, .ret = ret, .body = body };
    }

    pub fn parseTypeDef(self: *Parser) ParseError!ast.TypeDef {
        const start = self.mark();
        _ = self.advance(); // kw_type
        const name = try self.expectIdent();
        const type_params = try self.parseOptionalTypeParams();
        try self.expectAdvance(.equals, "'='");
        const target = try parse_type.parseType(self);
        try self.expectAdvance(.semicolon, "';'");
        return .{ .span = self.spanFrom(start), .name = name, .type_params = type_params, .target = target };
    }

    /// `opaque type name [params];` (Grammar `opaque-def`, Core §11.8) — a
    /// host-backed opaque nominal type. Legal only in a standard-library or
    /// host-provided module interface (enforced semantically in phase 2,
    /// not here); a source module declaring one is a checker diagnostic.
    pub fn parseOpaqueDef(self: *Parser) ParseError!ast.OpaqueDef {
        const start = self.mark();
        _ = self.advance(); // kw_opaque
        try self.expectAdvance(.kw_type, "'type' after 'opaque'");
        const name = try self.expectIdent();
        const type_params = try self.parseOptionalTypeParams();
        try self.expectAdvance(.semicolon, "';'");
        return .{ .span = self.spanFrom(start), .name = name, .type_params = type_params };
    }

    pub fn parseStructDef(self: *Parser) ParseError!ast.StructDef {
        const start = self.mark();
        _ = self.advance(); // kw_struct
        const name = try self.expectIdent();
        const type_params = try self.parseOptionalTypeParams();
        try self.expectAdvance(.lbrace, "'{'");
        var fields = std.ArrayList(ast.FieldDecl).empty;
        while (self.at(.ident)) {
            const fstart = self.mark();
            const fname = try self.expectIdent();
            try self.expectAdvance(.colon, "':'");
            const type_ = try parse_type.parseType(self);
            try self.expectAdvance(.semicolon, "';'");
            try fields.append(self.arena.allocator(), .{ .span = self.spanFrom(fstart), .name = fname, .type_ = type_ });
        }
        var drop: ?*ast.DropDecl = null;
        if (self.at(.kw_drop)) drop = try self.parseDropDecl();
        try self.expectAdvance(.rbrace, "'}'");
        return .{ .span = self.spanFrom(start), .name = name, .type_params = type_params, .fields = try self.arena.allocator().dupe(ast.FieldDecl, fields.items), .drop = drop };
    }

    /// `drop (name) block` (Grammar `drop-decl`).
    pub fn parseDropDecl(self: *Parser) ParseError!*ast.DropDecl {
        const start = self.mark();
        _ = self.advance(); // kw_drop
        try self.expectAdvance(.lparen, "'('");
        const param = try self.expectIdent();
        try self.expectAdvance(.rparen, "')'");
        const body = try parse_stmt.parseBlockRef(self);
        const decl = try self.arena.allocator().create(ast.DropDecl);
        decl.* = .{ .span = self.spanFrom(start), .param = param, .body = body };
        return decl;
    }

    pub fn parseUnionDef(self: *Parser) ParseError!ast.UnionDef {
        const start = self.mark();
        _ = self.advance(); // kw_union
        const name = try self.expectIdent();
        const type_params = try self.parseOptionalTypeParams();
        try self.expectAdvance(.lbrace, "'{'");
        var variants = std.ArrayList(ast.VariantDecl).empty;
        if (!self.at(.rbrace)) {
            while (true) {
                const vstart = self.mark();
                const vname = try self.expectIdent();
                var types: ?[]ast.Type = null;
                if (self.eat(.lparen)) {
                    var ts = std.ArrayList(ast.Type).empty;
                    try ts.append(self.arena.allocator(), try parse_type.parseType(self));
                    while (self.eat(.comma)) try ts.append(self.arena.allocator(), try parse_type.parseType(self));
                    try self.expectAdvance(.rparen, "')'");
                    types = try self.arena.allocator().dupe(ast.Type, ts.items);
                }
                try variants.append(self.arena.allocator(), .{ .span = self.spanFrom(vstart), .name = vname, .types = types });
                if (!self.eat(.comma)) break;
                if (self.at(.rbrace)) break;
            }
        }
        try self.expectAdvance(.rbrace, "'}'");
        return .{ .span = self.spanFrom(start), .name = name, .type_params = type_params, .variants = try self.arena.allocator().dupe(ast.VariantDecl, variants.items) };
    }

    /// `using path [as name];` (Grammar `using-decl`, Core §2.8).
    pub fn parseUsingDecl(self: *Parser) ParseError!ast.UsingDecl {
        const start = self.mark();
        _ = self.advance(); // kw_using
        const path = try self.parseUsingPath();
        var alias: ?ast.Ident = null;
        if (self.at(.kw_as)) {
            _ = self.advance();
            alias = try self.expectIdent();
        }
        try self.expectAdvance(.semicolon, "';'");
        return .{ .span = self.spanFrom(start), .path = path, .alias = alias };
    }

    /// `name ( . name )*` — like `type-path`, but each segment may be an
    /// identifier or a reserved word, so that paths such as `builtin.str`
    /// and `string.repeat` (Core §2.8) parse. `builtin` itself is an
    /// ordinary imported module, not a reserved word (Core §3).
    pub fn parseUsingPath(self: *Parser) ParseError![]ast.Ident {
        var path = std.ArrayList(ast.Ident).empty;
        try path.append(self.arena.allocator(), try self.expectPathSegment());
        while (self.eat(.dot)) try path.append(self.arena.allocator(), try self.expectPathSegment());
        return self.arena.allocator().dupe(ast.Ident, path.items);
    }

    pub fn expectPathSegment(self: *Parser) ParseError!ast.Ident {
        const tok = self.cur();
        switch (tok.kind) {
            .ident => {},
            .kw_any, .kw_as, .kw_bool, .kw_borrow, .kw_box, .kw_byte, .kw_const, .kw_drop, .kw_else, .kw_false, .kw_float32, .kw_fn, .kw_hostdata, .kw_if, .kw_import, .kw_int32, .kw_let, .kw_list, .kw_match, .kw_move, .kw_never, .kw_str, .kw_struct, .kw_true, .kw_tuple, .kw_type, .kw_uint32, .kw_union, .kw_using, .kw_void => {},
            else => return self.fail(tok.span, "expected a path segment, found {s}", .{self.describe(tok)}),
        }
        self.pos += 1;
        return .{ .span = tok.span, .text = tok.text };
    }

    // ---------------------------------------------------------------------
    // Generic parameters
    // ---------------------------------------------------------------------

    /// `[ name, ... ]` after a named declaration (Grammar `type-params`,
    /// Core §12); returns empty when absent.
    pub fn parseOptionalTypeParams(self: *Parser) ![]ast.Ident {
        if (!self.eat(.lbracket)) return &.{};
        var params = std.ArrayList(ast.Ident).empty;
        try params.append(self.arena.allocator(), try self.expectIdent());
        while (self.eat(.comma)) try params.append(self.arena.allocator(), try self.expectIdent());
        try self.expectAdvance(.rbracket, "']'");
        return self.arena.allocator().dupe(ast.Ident, params.items);
    }

    /// `[ type, ... ]` with the `[` already consumed (Grammar `type-args`).
    pub fn parseTypeArgsContents(self: *Parser) ![]ast.Type {
        var types = std.ArrayList(ast.Type).empty;
        try types.append(self.arena.allocator(), try parse_type.parseType(self));
        while (self.eat(.comma)) try types.append(self.arena.allocator(), try parse_type.parseType(self));
        try self.expectAdvance(.rbracket, "']'");
        return self.arena.allocator().dupe(ast.Type, types.items);
    }

    pub fn parseTypeArgs(self: *Parser) ![]ast.Type {
        try self.expectAdvance(.lbracket, "'['");
        return self.parseTypeArgsContents();
    }

    /// `[ [borrow|move] name: type, ... ]` with the `(` already consumed
    /// (Grammar `param-list`).
    pub fn parseParamList(self: *Parser) ![]ast.Param {
        var params = std.ArrayList(ast.Param).empty;
        if (!self.at(.rparen)) {
            while (true) {
                try params.append(self.arena.allocator(), try self.parseParam());
                if (!self.eat(.comma)) break;
            }
        }
        try self.expectAdvance(.rparen, "')'");
        return self.arena.allocator().dupe(ast.Param, params.items);
    }

    pub fn parseParam(self: *Parser) ParseError!ast.Param {
        const start = self.mark();
        const mode = self.takeMode();
        const name = try self.expectIdent();
        try self.expectAdvance(.colon, "':'");
        const type_ = try parse_type.parseType(self);
        return .{ .span = self.spanFrom(start), .mode = mode, .name = name, .type_ = type_ };
    }

    pub fn takeMode(self: *Parser) ast.ParamMode {
        return switch (self.cur().kind) {
            .kw_borrow => blk: {
                _ = self.advance();
                break :blk .borrow;
            },
            .kw_move => blk: {
                _ = self.advance();
                break :blk .move;
            },
            else => .plain,
        };
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    pub fn newExpr(self: *Parser, e: ast.Expr) ParseError!*ast.Expr {
        const p = try self.arena.allocator().create(ast.Expr);
        p.* = e;
        return p;
    }

    pub fn newType(self: *Parser, t: ast.Type) ParseError!*ast.Type {
        const p = try self.arena.allocator().create(ast.Type);
        p.* = t;
        return p;
    }

    pub fn newBlock(self: *Parser, b: ast.Block) ParseError!*ast.Block {
        const p = try self.arena.allocator().create(ast.Block);
        p.* = b;
        return p;
    }

    pub fn intValue(self: *Parser, tok: lex.Token) !u64 {
        return std.fmt.parseInt(u64, tok.text, 10) catch {
            return self.fail(tok.span, "integer literal out of range: {s}", .{tok.text});
        };
    }

    pub fn floatValue(self: *Parser, tok: lex.Token) !f64 {
        const f = std.fmt.parseFloat(f64, tok.text) catch {
            return self.fail(tok.span, "invalid float literal: {s}", .{tok.text});
        };
        // Zig's parseFloat saturates: an out-of-range literal becomes
        // ±inf instead of an error. Reject it here, mirroring
        // `intValue`'s out-of-range diagnostic.
        if (!std.math.isFinite(f)) {
            return self.fail(tok.span, "float literal out of range: {s}", .{tok.text});
        }
        return f;
    }

    pub fn mark(self: *Parser) usize {
        return self.pos;
    }

    pub fn spanFrom(self: *Parser, start: usize) ast.Span {
        return ast.Span.merge(self.tokens[start].span, self.tokens[self.pos - 1].span);
    }

    pub fn cur(self: *Parser) lex.Token {
        return self.tokens[self.pos];
    }

    pub fn prev(self: *Parser) lex.Token {
        return self.tokens[self.pos - 1];
    }

    pub fn at(self: *Parser, kind: lex.TokenKind) bool {
        return self.cur().kind == kind;
    }

    pub fn advance(self: *Parser) lex.Token {
        const t = self.tokens[self.pos];
        self.pos += 1;
        return t;
    }

    pub fn eat(self: *Parser, kind: lex.TokenKind) bool {
        if (!self.at(kind)) return false;
        self.pos += 1;
        return true;
    }

    pub fn expectAdvance(self: *Parser, kind: lex.TokenKind, what: []const u8) ParseError!void {
        if (!self.eat(kind)) {
            return self.fail(self.cur().span, "expected {s}, found {s}", .{ what, self.describe(self.cur()) });
        }
    }

    pub fn expectIdent(self: *Parser) ParseError!ast.Ident {
        const tok = self.cur();
        if (tok.kind != .ident) return self.fail(tok.span, "expected an identifier, found {s}", .{self.describe(tok)});
        self.pos += 1;
        return .{ .span = tok.span, .text = tok.text };
    }

    pub fn fail(self: *Parser, span: ast.Span, comptime fmt: []const u8, args: anytype) error{Syntax} {
        if (self.diag == null) {
            self.diag = .{ .span = span, .message = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch "out of memory" };
        }
        return error.Syntax;
    }

    pub fn describe(self: *Parser, tok: lex.Token) []const u8 {
        _ = self;
        return switch (tok.kind) {
            .eof => "end of file",
            .ident, .integer, .float, .string => tok.text,
            else => tokenName(tok.kind),
        };
    }
};

/// The written form of a token, for error messages.
fn tokenName(kind: lex.TokenKind) []const u8 {
    return switch (kind) {
        .eof, .ident, .integer, .float, .string => unreachable,
        .wildcard => "'_'",
        .kw_any => "'any'",
        .kw_and => "'and'",
        .kw_as => "'as'",
        .kw_bool => "'bool'",
        .kw_borrow => "'borrow'",
        .kw_box => "'box'",
        .kw_byte => "'byte'",
        .kw_const => "'const'",
        .kw_drop => "'drop'",
        .kw_else => "'else'",
        .kw_false => "'false'",
        .kw_float32 => "'float32'",
        .kw_fn => "'fn'",
        .kw_hostdata => "'hostdata'",
        .kw_if => "'if'",
        .kw_import => "'import'",
        .kw_int32 => "'int32'",
        .kw_let => "'let'",
        .kw_list => "'list'",
        .kw_match => "'match'",
        .kw_move => "'move'",
        .kw_never => "'never'",
        .kw_opaque => "'opaque'",
        .kw_or => "'or'",
        .kw_str => "'str'",
        .kw_struct => "'struct'",
        .kw_true => "'true'",
        .kw_tuple => "'tuple'",
        .kw_type => "'type'",
        .kw_uint32 => "'uint32'",
        .kw_union => "'union'",
        .kw_using => "'using'",
        .kw_void => "'void'",
        .lparen => "'('",
        .rparen => "')'",
        .lbracket => "'['",
        .rbracket => "']'",
        .lbrace => "'{'",
        .rbrace => "'}'",
        .comma => "','",
        .colon => "':'",
        .semicolon => "';'",
        .dot => "'.'",
        .dcolon => "'::'",
        .arrow => "'->'",
        .fat_arrow => "'=>'",
        .equals => "'='",
        .plus => "'+'",
        .minus => "'-'",
        .star => "'*'",
        .slash => "'/'",
        .percent => "'%'",
        .bang => "'!'",
        .eq_eq => "'=='",
        .ne => "'!='",
        .lt => "'<'",
        .le => "'<='",
        .gt => "'>'",
        .ge => "'>='",
        .ellipsis => "'..'",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TP = struct {
    source: *ast.Source,
    parser: Parser,

    pub fn init(text: []const u8) ParseError!TP {
        const source = try std.testing.allocator.create(ast.Source);
        source.* = try ast.Source.init(std.testing.allocator, "test.st", 0, text);
        return .{ .source = source, .parser = Parser.init(std.testing.allocator) };
    }

    pub fn deinit(self: *TP) void {
        self.parser.deinit();
        self.source.deinit(std.testing.allocator);
        std.testing.allocator.destroy(self.source);
    }

    pub fn parse(self: *TP) ParseError!ast.Program {
        return self.parser.parse(self.source);
    }
};

fn parseText(text: []const u8) !struct { tp: TP, program: ast.Program } {
    var tp = try TP.init(text);
    errdefer tp.deinit();
    // Parse before returning: the returned copy of the parser's arena must
    // include the allocations made by parse.
    const program = try tp.parse();
    return .{ .tp = tp, .program = program };
}

fn parseError(text: []const u8) !struct { tp: TP, diag: ast.Diagnostic } {
    var tp = try TP.init(text);
    errdefer tp.deinit();
    try std.testing.expectError(error.Syntax, tp.parse());
    return .{ .tp = tp, .diag = tp.parser.diag.? };
}

test "parses an empty program" {
    var t = try parseText("");
    defer t.tp.deinit();
    try std.testing.expectEqual(@as(usize, 0), t.program.items.len);
}

test "parses constants with and without type annotations" {
    var t = try parseText("const pi: float32 = 3.14; const answer = 42;");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.program.items.len);
    const first = t.program.items[0].const_def;
    try std.testing.expectEqualStrings("pi", first.name.text);
    try std.testing.expectEqual(ast.PrimitiveKind.float32, first.type_.?.primitive.kind);
    try std.testing.expectEqual(@as(f64, 3.14), first.init.?.float.value);
    const second = t.program.items[1].const_def;
    try std.testing.expect(second.type_ == null);
    try std.testing.expectEqual(@as(u64, 42), second.init.?.int.value);
}

test "parses the top type any" {
    // Value form: an initializer coerced into `any`.
    var t = try parseText("const handle: any = builtin.get_handle();");
    defer t.tp.deinit();

    const c = t.program.items[0].const_def;
    try std.testing.expectEqual(ast.PrimitiveKind.any, c.type_.?.primitive.kind);
    try std.testing.expect(c.init.?.* == .call);
}

test "parses hostdata as a primitive type" {
    // `hostdata` is a reserved word and a primitive type (Core §11.7): it
    // lexes to its own token and parses in every type position.
    var t = try parseText("const h: hostdata; fn get() -> hostdata; fn echo(x: hostdata) -> hostdata; type H = hostdata;");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 4), t.program.items.len);
    const c = t.program.items[0].const_def;
    try std.testing.expectEqual(ast.PrimitiveKind.hostdata, c.type_.?.primitive.kind);
    const f = t.program.items[1].func_def;
    try std.testing.expectEqual(ast.PrimitiveKind.hostdata, f.ret.?.primitive.kind);
    const g = t.program.items[2].func_def;
    try std.testing.expectEqual(ast.PrimitiveKind.hostdata, g.params[0].type_.primitive.kind);
    try std.testing.expectEqual(ast.PrimitiveKind.hostdata, g.ret.?.primitive.kind);
    const td = t.program.items[3].type_def;
    try std.testing.expectEqual(ast.PrimitiveKind.hostdata, td.target.primitive.kind);
}

test "rejects hostdata as a binding name" {
    // `hostdata` is reserved (Grammar "Reserved words"; Core §11.7).
    var t = try parseError("const hostdata: int32 = 1;");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an identifier, found 'hostdata'", t.diag.message);
}

test "parses any in host-binding declarations" {
    // Declaration-only (host binding — phase3-cfg-lowering.md, System calls for host bindings): `const name: type;`
    // and `fn name(...) -> type;` may use `any` for opaque payloads.
    var t = try parseText("const handle: any; fn echo(x: any) -> any;");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.program.items.len);
    const c = t.program.items[0].const_def;
    try std.testing.expectEqual(ast.PrimitiveKind.any, c.type_.?.primitive.kind);
    try std.testing.expect(c.init == null);
    const f = t.program.items[1].func_def;
    try std.testing.expectEqual(ast.PrimitiveKind.any, f.params[0].type_.primitive.kind);
    try std.testing.expectEqual(ast.PrimitiveKind.any, f.ret.?.primitive.kind);
    try std.testing.expect(f.body == null);
}

test "parses function definitions" {
    var t = try parseText("fn identity[T](x: T) -> T { x }");
    defer t.tp.deinit();

    const f = t.program.items[0].func_def;
    try std.testing.expectEqualStrings("identity", f.name.text);
    try std.testing.expectEqual(@as(usize, 1), f.type_params.len);
    try std.testing.expectEqualStrings("T", f.type_params[0].text);
    try std.testing.expectEqual(@as(usize, 1), f.params.len);
    try std.testing.expectEqual(ast.ParamMode.plain, f.params[0].mode);
    try std.testing.expectEqualStrings("x", f.params[0].name.text);
    try std.testing.expectEqualStrings("T", f.ret.?.named.path[0].text);
    try std.testing.expectEqual(@as(usize, 0), f.body.?.stmts.len);
    try std.testing.expectEqualStrings("x", f.body.?.result.?.path.path[0].text);
}

test "parses borrow and move parameters" {
    var t = try parseText("fn f(borrow a: int32, move b: str) {}");
    defer t.tp.deinit();

    const f = t.program.items[0].func_def;
    try std.testing.expectEqual(ast.ParamMode.borrow, f.params[0].mode);
    try std.testing.expectEqual(ast.ParamMode.move, f.params[1].mode);
    try std.testing.expectEqual(@as(usize, 0), f.body.?.stmts.len);
    try std.testing.expect(f.body.?.result == null);
}

test "parses struct definitions with drop declarations" {
    var t = try parseText("struct V { x: int32; y: bool; drop (v) { drop v; } }");
    defer t.tp.deinit();

    const s = t.program.items[0].struct_def;
    try std.testing.expectEqual(@as(usize, 2), s.fields.len);
    try std.testing.expectEqualStrings("x", s.fields[0].name.text);
    try std.testing.expectEqual(ast.PrimitiveKind.int32, s.fields[0].type_.primitive.kind);
    const d = s.drop.?;
    try std.testing.expectEqualStrings("v", d.param.text);
    try std.testing.expectEqual(@as(usize, 1), d.body.stmts.len);
}

test "parses opaque type declarations" {
    var t = try parseText("opaque type Array[T];");
    defer t.tp.deinit();

    const o = t.program.items[0].opaque_def;
    try std.testing.expectEqualStrings("Array", o.name.text);
    try std.testing.expectEqual(@as(usize, 1), o.type_params.len);
    try std.testing.expectEqualStrings("T", o.type_params[0].text);
}

test "parses opaque type declarations without parameters" {
    var t = try parseText("opaque type Handle;");
    defer t.tp.deinit();

    const o = t.program.items[0].opaque_def;
    try std.testing.expectEqualStrings("Handle", o.name.text);
    try std.testing.expectEqual(@as(usize, 0), o.type_params.len);
}

test "parses union definitions" {
    var t = try parseText("union Opt[T] { None, Some (T), }");
    defer t.tp.deinit();

    const u = t.program.items[0].union_def;
    try std.testing.expectEqual(@as(usize, 2), u.variants.len);
    try std.testing.expectEqualStrings("Opt", u.name.text);
    try std.testing.expectEqualStrings("None", u.variants[0].name.text);
    try std.testing.expect(u.variants[0].types == null);
    const some = u.variants[1];
    try std.testing.expectEqualStrings("Some", some.name.text);
    try std.testing.expectEqual(@as(usize, 1), some.types.?.len);
    try std.testing.expectEqualStrings("T", some.types.?[0].named.path[0].text);
}

test "parses using declarations at module level" {
    var t = try parseText("using builtin.Option; using string.repeat as re;");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.program.items.len);
    const a = t.program.items[0].using_decl;
    try std.testing.expectEqual(@as(usize, 2), a.path.len);
    try std.testing.expectEqualStrings("builtin", a.path[0].text);
    try std.testing.expectEqualStrings("Option", a.path[1].text);
    try std.testing.expect(a.alias == null);
    const b = t.program.items[1].using_decl;
    try std.testing.expectEqual(@as(usize, 2), b.path.len);
    try std.testing.expectEqualStrings("string", b.path[0].text);
    try std.testing.expectEqualStrings("repeat", b.path[1].text);
    try std.testing.expectEqualStrings("re", b.alias.?.text);
}

test "parses builtin as an ordinary imported module" {
    // `builtin` is not a reserved word (Core §3): programs import it like
    // any other module and may bind, alias, and shadow it like any other
    // identifier.
    var t = try parseText(
        \\const builtin = import("builtin");
        \\using builtin.print as p;
        \\fn main() { p("hi"); builtin.str(1) }
    );
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 3), t.program.items.len);
    const c = t.program.items[0].const_def;
    try std.testing.expectEqualStrings("builtin", c.name.text);
    try std.testing.expectEqualStrings("builtin", c.init.?.import.module);
    const u = t.program.items[1].using_decl;
    try std.testing.expectEqualStrings("builtin", u.path[0].text);
    const body = t.program.items[2].func_def.body.?;
    try std.testing.expectEqualStrings("p", body.stmts[0].expr.expr.call.callee.path.path[0].text);
    const call = body.result.?.call;
    try std.testing.expectEqualStrings("builtin", call.callee.path.path[0].text);
    try std.testing.expectEqualStrings("str", call.callee.path.path[1].text);
}

test "parses using declarations inside blocks" {
    var t = try parseText("fn f() { using string.upper as up; up(\"x\") }");
    defer t.tp.deinit();

    const body = t.program.items[0].func_def.body.?;
    try std.testing.expectEqual(@as(usize, 1), body.stmts.len);
    const u = body.stmts[0].using;
    try std.testing.expectEqual(@as(usize, 2), u.path.len);
    try std.testing.expectEqualStrings("string", u.path[0].text);
    try std.testing.expectEqualStrings("upper", u.path[1].text);
    try std.testing.expectEqualStrings("up", u.alias.?.text);
}

test "parses type aliases" {
    var t = try parseText("type A = int32; type B = list[box[tuple[int32, str]]]; type F = fn (borrow int32, move str) -> bool; type G = map.Key[int32];");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 4), t.program.items.len);
    const a = t.program.items[0].type_def;
    try std.testing.expectEqual(ast.PrimitiveKind.int32, a.target.primitive.kind);
    const b = t.program.items[1].type_def;
    try std.testing.expectEqual(@as(usize, 2), b.target.list.elem.box.inner.tuple.elems.len);
    try std.testing.expectEqual(ast.PrimitiveKind.int32, b.target.list.elem.box.inner.tuple.elems[0].primitive.kind);
    const f = t.program.items[2].type_def;
    try std.testing.expectEqual(@as(usize, 2), f.target.function.params.len);
    try std.testing.expectEqual(ast.ParamMode.borrow, f.target.function.params[0].mode);
    try std.testing.expectEqual(ast.ParamMode.move, f.target.function.params[1].mode);
    try std.testing.expectEqual(ast.PrimitiveKind.bool, f.target.function.ret.primitive.kind);
    const g = t.program.items[3].type_def;
    try std.testing.expectEqual(@as(usize, 2), g.target.named.path.len);
    try std.testing.expectEqualStrings("map", g.target.named.path[0].text);
    try std.testing.expectEqual(@as(usize, 1), g.target.named.type_args.?.len);
}

test "parses operators with precedence" {
    var t = try parseText("const x = 1 + 2 * 3; const y = a and b or c; const z = p < q;");
    defer t.tp.deinit();

    const x = t.program.items[0].const_def.init.?;
    try std.testing.expectEqual(ast.BinaryOp.add, x.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.mul, x.binary.rhs.binary.op);
    const y = t.program.items[1].const_def.init.?;
    try std.testing.expectEqual(ast.BinaryOp.or_, y.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.and_, y.binary.lhs.binary.op);
    const z = t.program.items[2].const_def.init.?;
    try std.testing.expectEqual(ast.BinaryOp.lt, z.binary.op);
}

test "parses unary, move, and cast expressions" {
    var t = try parseText("const a = -x + !b; const c = move v; const d = x as int32 as float32;");
    defer t.tp.deinit();

    const a = t.program.items[0].const_def.init.?;
    try std.testing.expectEqual(ast.BinaryOp.add, a.binary.op);
    try std.testing.expectEqual(ast.UnaryOp.neg, a.binary.lhs.unary.op);
    try std.testing.expectEqual(ast.UnaryOp.not, a.binary.rhs.unary.op);
    const c = t.program.items[1].const_def.init.?;
    try std.testing.expectEqualStrings("v", c.move.name.text);
    const d = t.program.items[2].const_def.init.?;
    try std.testing.expectEqual(ast.PrimitiveKind.float32, d.cast.target.primitive.kind);
    try std.testing.expectEqual(ast.PrimitiveKind.int32, d.cast.operand.cast.target.primitive.kind);
}

test "parses postfix chains" {
    var t = try parseText("const r = a.b(i + 1).c;");
    defer t.tp.deinit();

    // `a.b` is one dotted type-path; the trailing `.c` is a member access.
    const r = t.program.items[0].const_def.init.?;
    try std.testing.expectEqualStrings("c", r.member.name.text);
    const call = r.member.object.call;
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqual(ast.BinaryOp.add, call.args[0].binary.op);
    const path = call.callee.path;
    try std.testing.expectEqual(@as(usize, 2), path.path.len);
    try std.testing.expectEqualStrings("a", path.path[0].text);
    try std.testing.expectEqualStrings("b", path.path[1].text);
    try std.testing.expect(path.tail == .none);
}

test "parses struct construction, variants, and specialization" {
    var t = try parseText("const a = Point { x: 1, y: 2, }; const b = Result::Ok(42); const c = Result::Err; const d = Vec[int32]::[int32]; const e = f()::[int32];");
    defer t.tp.deinit();

    const a = t.program.items[0].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 2), a.path.tail.construct.fields.len);
    try std.testing.expectEqualStrings("Point", a.path.path[0].text);
    const b = t.program.items[1].const_def.init.?;
    try std.testing.expectEqualStrings("Ok", b.path.tail.variant.name.text);
    try std.testing.expectEqual(@as(usize, 1), b.path.tail.variant.args.?.len);
    const c = t.program.items[2].const_def.init.?;
    try std.testing.expectEqualStrings("Err", c.path.tail.variant.name.text);
    try std.testing.expect(c.path.tail.variant.args == null);
    const d = t.program.items[3].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 1), d.specialize.type_args.len);
    try std.testing.expectEqual(@as(usize, 1), d.specialize.operand.path.type_args.?.len);
    const e = t.program.items[4].const_def.init.?;
    try std.testing.expectEqual(ast.PrimitiveKind.int32, e.specialize.type_args[0].primitive.kind);
    try std.testing.expect(e.specialize.operand.call.args.len == 0);
}

test "parses if expressions with else chains" {
    var t = try parseText("const r = if (a) { 1 } else if (b) { 2 } else { 3 };");
    defer t.tp.deinit();

    const r = t.program.items[0].const_def.init.?;
    const outer = r.if_;
    try std.testing.expectEqual(@as(u64, 1), outer.then.result.?.int.value);
    const mid = outer.else_.?.if_;
    try std.testing.expectEqual(@as(u64, 2), mid.then.result.?.int.value);
    try std.testing.expectEqual(@as(u64, 3), mid.else_.?.block.block.result.?.int.value);
}

test "parses match expressions" {
    var t = try parseText("const r = match (x) { 0 => \"zero\", -1 => \"neg\", _ => \"other\", };");
    defer t.tp.deinit();

    const r = t.program.items[0].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 3), r.match.arms.len);
    try std.testing.expectEqual(@as(u64, 0), r.match.arms[0].pattern.literal.value.int);
    try std.testing.expectEqual(@as(u64, 1), r.match.arms[1].pattern.literal.value.neg_int);
    try std.testing.expectEqualStrings("neg", r.match.arms[1].body.string.value);
    try std.testing.expect(r.match.arms[2].pattern == .wildcard);
}

test "parses keyword-led type-test patterns" {
    // Grammar `type-test-pattern`, Core §14.7: a concrete type name
    // optionally followed by a binding identifier.
    var t = try parseText("const r = match (a) { int32 n => 1, str => 2, list[int32] xs => 3, tuple[int32, str] t => 4, fn(int32) -> int32 f => 5, _ => 0 };");
    defer t.tp.deinit();

    const r = t.program.items[0].const_def.init.?;
    const arms = r.match.arms;
    try std.testing.expectEqual(@as(usize, 6), arms.len);
    const a0 = arms[0].pattern.type_test;
    try std.testing.expectEqual(ast.PrimitiveKind.int32, a0.type_.primitive.kind);
    try std.testing.expectEqualStrings("n", a0.binding.?.text);
    const a1 = arms[1].pattern.type_test;
    try std.testing.expectEqual(ast.PrimitiveKind.str, a1.type_.primitive.kind);
    try std.testing.expect(a1.binding == null);
    const a2 = arms[2].pattern.type_test;
    try std.testing.expectEqual(ast.PrimitiveKind.int32, a2.type_.list.elem.primitive.kind);
    try std.testing.expectEqualStrings("xs", a2.binding.?.text);
    const a3 = arms[3].pattern.type_test;
    try std.testing.expectEqual(@as(usize, 2), a3.type_.tuple.elems.len);
    try std.testing.expectEqualStrings("t", a3.binding.?.text);
    const a4 = arms[4].pattern.type_test;
    try std.testing.expectEqual(@as(usize, 1), a4.type_.function.params.len);
    try std.testing.expectEqualStrings("f", a4.binding.?.text);
    try std.testing.expect(arms[5].pattern == .wildcard);
}

test "parses identifier-led type-test patterns" {
    // LL(1) note 3: an identifier immediately following the type path
    // marks a type-test binding (`File f`, `Option[int32] o`). A bare
    // identifier remains an identifier-pattern.
    var t = try parseText("const r = match (a) { File f => 1, builtin.Option[int32] o => 2, x => 3 };");
    defer t.tp.deinit();

    const r = t.program.items[0].const_def.init.?;
    const arms = r.match.arms;
    const a0 = arms[0].pattern.type_test;
    try std.testing.expectEqualStrings("File", a0.type_.named.path[0].text);
    try std.testing.expectEqualStrings("f", a0.binding.?.text);
    const a1 = arms[1].pattern.type_test;
    try std.testing.expectEqual(@as(usize, 2), a1.type_.named.path.len);
    try std.testing.expectEqual(@as(usize, 1), a1.type_.named.type_args.?.len);
    try std.testing.expectEqualStrings("o", a1.binding.?.text);
    try std.testing.expect(arms[2].pattern.path.tail == .none);
    try std.testing.expectEqualStrings("x", arms[2].pattern.path.path[0].text);
}

test "rejects any, never, and hostdata as type-test types" {
    // The static semantics reject `any`, `never`, and `hostdata` as test
    // types (Grammar `type-test-type` note; Core §11.6, §11.7); they are
    // not in `type-test-type`, so they fail to parse as patterns.
    var t = try parseError("const r = match (a) { any x => 1, _ => 0 };");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected a pattern, found 'any'", t.diag.message);

    var t2 = try parseError("const r = match (a) { hostdata h => 1, _ => 0 };");
    defer t2.tp.deinit();
    try std.testing.expectEqualStrings("expected a pattern, found 'hostdata'", t2.diag.message);
}

test "parses lambdas" {
    var t = try parseText("const f = fn (x: int32) -> int32 { x };");
    defer t.tp.deinit();

    const f = t.program.items[0].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 1), f.lambda.params.len);
    try std.testing.expectEqual(ast.PrimitiveKind.int32, f.lambda.ret.?.primitive.kind);
    try std.testing.expectEqualStrings("x", f.lambda.body.result.?.path.path[0].text);
}

test "parses parens, void, and tuples" {
    var t = try parseText("const a = (); const b = (1); const c = (1,); const d = (1, 2);");
    defer t.tp.deinit();

    try std.testing.expect(t.program.items[0].const_def.init.?.* == .void);
    try std.testing.expectEqual(@as(u64, 1), t.program.items[1].const_def.init.?.paren.inner.int.value);
    const c = t.program.items[2].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 1), c.tuple.elems.len);
    const d = t.program.items[3].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 2), d.tuple.elems.len);
}

test "parses list literals and blocks" {
    var t = try parseText("const a = [1, 2,]; const b = { { 1; }; 2 };");
    defer t.tp.deinit();

    const a = t.program.items[0].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 2), a.list.elems.len);
    const b = t.program.items[1].const_def.init.?;
    try std.testing.expectEqual(@as(usize, 1), b.block.block.stmts.len);
    try std.testing.expectEqual(@as(u64, 2), b.block.block.result.?.int.value);
}

test "parses patterns in let statements" {
    var t = try parseText("fn f(xs: list[int32]) { let (a, b) = p; let [head, ..tail] = xs; let Point { x, y: 0 } = q; let U::V(a, b) = w; }");
    defer t.tp.deinit();

    const body = t.program.items[0].func_def.body.?;
    try std.testing.expectEqual(@as(usize, 4), body.stmts.len);
    const tuple = body.stmts[0].let;
    try std.testing.expectEqual(@as(usize, 2), tuple.pattern.tuple.elems.len);
    try std.testing.expect(tuple.pattern.tuple.elems[0].path.tail == .none);
    const list = body.stmts[1].let;
    try std.testing.expectEqual(@as(usize, 1), list.pattern.list.items.len);
    try std.testing.expectEqualStrings("tail", list.pattern.list.rest.?.text);
    const sp = body.stmts[2].let.pattern.path.tail.struct_;
    try std.testing.expectEqual(@as(usize, 2), sp.fields.len);
    try std.testing.expect(sp.fields[0].pattern == null);
    try std.testing.expectEqual(@as(u64, 0), sp.fields[1].pattern.?.literal.value.int);
    const vp = body.stmts[3].let.pattern.path.tail.variant;
    try std.testing.expectEqualStrings("V", vp.name.text);
    try std.testing.expectEqual(@as(usize, 2), vp.args.?.len);
}

test "parses imports and decodes strings" {
    var t = try parseText("const s = \"a\\nb\\\"c\"; const m = import(\"math\");");
    defer t.tp.deinit();

    try std.testing.expectEqualStrings("a\nb\"c", t.program.items[0].const_def.init.?.string.value);
    const m = t.program.items[1].const_def.init.?;
    try std.testing.expectEqualStrings("math", m.import.module);
}

test "parses empty statements and empty blocks" {
    var t = try parseText("fn f() { ;; {}; }");
    defer t.tp.deinit();

    const body = t.program.items[0].func_def.body.?;
    try std.testing.expectEqual(@as(usize, 3), body.stmts.len);
    try std.testing.expect(body.stmts[0] == .empty);
    try std.testing.expect(body.stmts[1] == .empty);
    try std.testing.expectEqual(@as(usize, 0), body.stmts[2].expr.expr.block.block.stmts.len);
}

test "rejects a missing semicolon" {
    var t = try parseError("const x = 1");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected ';', found end of file", t.diag.message);
}

test "rejects let at module level" {
    var t = try parseError("let x = 1;");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected a module item ('const', 'fn', 'type', 'struct', 'union', 'opaque', or 'using'), found 'let'", t.diag.message);
}

test "rejects reserved words as identifiers" {
    var t = try parseError("const let = 1;");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an identifier, found 'let'", t.diag.message);
}

test "rejects wildcard in expression position" {
    var t = try parseError("const x = _;");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an expression, found '_'", t.diag.message);
}

test "rejects comparison chains" {
    var t = try parseError("const a = x < y < z;");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected ';', found '<'", t.diag.message);
}

test "rejects trailing commas in tuples and tuple patterns" {
    var t = try parseError("const x = (1, 2,);");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an expression, found ')'", t.diag.message);

    var t2 = try parseError("fn f() { let (a, b,) = p; }");
    defer t2.tp.deinit();
    try std.testing.expectEqualStrings("expected a pattern, found ')'", t2.diag.message);
}

test "rejects a bare pattern in parens" {
    var t = try parseError("fn f() { let (p) = q; }");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected ',', found ')'", t.diag.message);
}

test "rejects the old index syntax" {
    var t = try parseError("const x = a[0];");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected a type, found 0", t.diag.message);
}

test "rejects empty type arguments" {
    var t = try parseError("const x = Foo[];");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected a type, found ']'", t.diag.message);
}

test "rejects trailing comma in call arguments" {
    var t = try parseError("const x = f(a,);");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an expression, found ')'", t.diag.message);
}

test "rejects a stray else" {
    var t = try parseError("const x = else;");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an expression, found 'else'", t.diag.message);
}

test "reports the error span" {
    var t = try parseError("const x = 1 +;");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an expression, found ';'", t.diag.message);
    try std.testing.expectEqual(@as(u32, 13), t.diag.span.start);
    try std.testing.expectEqual(@as(u32, 14), t.diag.span.end);
}

test "rejects unterminated constructs" {
    var t = try parseError("fn f(");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected an identifier, found end of file", t.diag.message);

    var t2 = try parseError("struct S {");
    defer t2.tp.deinit();
    try std.testing.expectEqualStrings("expected '}', found end of file", t2.diag.message);
}

test "parses a complete program" {
    const src =
        \\const version: str = "1.0";
        \\const default_size = 1024;
        \\
        \\type Size = int32;
        \\
        \\union Opt[T] { None, Some (T) }
        \\
        \\struct Point { x: float32; y: float32; }
        \\
        \\fn add(a: int32, b: int32) -> int32 {
        \\    a + b
        \\}
        \\
        \\fn apply(f: fn (int32) -> int32, x: int32) -> int32 {
        \\    f(x)
        \\}
        \\
        \\fn classify(n: int32) -> str {
        \\    match (n) {
        \\        0 => "zero",
        \\        _ => "other",
        \\    }
        \\}
    ;
    var t = try parseText(src);
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 8), t.program.items.len);
    try std.testing.expectEqualStrings("version", t.program.items[0].const_def.name.text);
    try std.testing.expectEqualStrings("classify", t.program.items[7].func_def.name.text);
}

test "parses never as a primitive type" {
    // Core §13.2: `never` is the bottom type; it appears in return
    // positions of panicking functions.
    var t = try parseText("fn die() -> never { builtin.panic(\"x\") }");
    defer t.tp.deinit();

    const f = t.program.items[0].func_def;
    try std.testing.expectEqual(ast.PrimitiveKind.never, f.ret.?.primitive.kind);
}

test "parses empty structs and empty unions" {
    // Grammar `struct-def` / `union-def`: fields and variants are
    // optional.
    var t = try parseText("struct Empty { } union U { }");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.program.items.len);
    try std.testing.expectEqual(@as(usize, 0), t.program.items[0].struct_def.fields.len);
    try std.testing.expect(t.program.items[0].struct_def.drop == null);
    try std.testing.expectEqual(@as(usize, 0), t.program.items[1].union_def.variants.len);
}

test "parses generic structs, unions, and aliases with multiple parameters" {
    var t = try parseText("struct Pair[A, B] { first: A; second: B; } union Res[E, T] { Ok(T), Err(E) } type Dict[K, V] = list[tuple[K, V]];");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 3), t.program.items.len);
    const s = t.program.items[0].struct_def;
    try std.testing.expectEqual(@as(usize, 2), s.type_params.len);
    try std.testing.expectEqualStrings("A", s.type_params[0].text);
    try std.testing.expectEqualStrings("B", s.type_params[1].text);
    const u = t.program.items[1].union_def;
    try std.testing.expectEqual(@as(usize, 2), u.type_params.len);
    const td = t.program.items[2].type_def;
    try std.testing.expectEqual(@as(usize, 2), td.type_params.len);
    try std.testing.expect(td.target == .list);
}

test "parses function types in struct fields and parameters" {
    // Core §7: function fields are ordinary fields.
    var t = try parseText("struct Math { add: fn(int32, int32) -> int32; } fn apply(f: fn(move int32) -> int32, x: int32) -> int32 { f(x) }");
    defer t.tp.deinit();

    const s = t.program.items[0].struct_def;
    try std.testing.expectEqual(ast.PrimitiveKind.int32, s.fields[0].type_.function.ret.primitive.kind);
    try std.testing.expectEqual(@as(usize, 2), s.fields[0].type_.function.params.len);
    const f = t.program.items[1].func_def;
    try std.testing.expectEqual(ast.ParamMode.move, f.params[0].type_.function.params[0].mode);
}

test "parses void-returning and inferred-return functions" {
    var t = try parseText("fn f() {} fn g() -> void {} fn h() { 1 }");
    defer t.tp.deinit();

    try std.testing.expectEqual(@as(usize, 3), t.program.items.len);
    try std.testing.expect(t.program.items[0].func_def.ret == null);
    try std.testing.expectEqual(ast.PrimitiveKind.void, t.program.items[1].func_def.ret.?.primitive.kind);
    // `h` omits the return type: inferred from the body (Core §6.4).
    try std.testing.expect(t.program.items[2].func_def.ret == null);
}

test "rejects a second drop declaration" {
    // Grammar `struct-def`: at most one `drop-decl`, after all fields.
    var t = try parseError("struct S { x: int32; drop(s) {} drop(s) {} }");
    defer t.tp.deinit();
    try std.testing.expect(std.mem.indexOf(u8, t.diag.message, "expected '}'") != null);
}

test "rejects drop before fields" {
    // Grammar `struct-def`: the drop-decl must appear after all fields.
    var t = try parseError("struct S { drop(s) {} x: int32; }");
    defer t.tp.deinit();
    try std.testing.expect(std.mem.indexOf(u8, t.diag.message, "expected '}'") != null);
}

test "rejects an import with a non-literal argument" {
    // Core §2.4: the argument to import must be a string literal.
    var t = try parseError("const m = import(x);");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected a string literal in import, found x", t.diag.message);
}

test "rejects an empty type argument list" {
    var t = try parseError("type X = list[];");
    defer t.tp.deinit();
    try std.testing.expectEqualStrings("expected a type, found ']'", t.diag.message);
}

test "parses match with tuple and struct patterns" {
    var t = try parseText("const r = match (p) { Point{ x, y: 0 } => 1, (a, b) => 2, _ => 3 };");
    defer t.tp.deinit();

    const arms = t.program.items[0].const_def.init.?.match.arms;
    try std.testing.expectEqual(@as(usize, 3), arms.len);
    const sp = arms[0].pattern.path.tail.struct_;
    try std.testing.expectEqualStrings("x", sp.fields[0].name.text);
    try std.testing.expectEqual(@as(u64, 0), sp.fields[1].pattern.?.literal.value.int);
    const tp = arms[1].pattern.tuple;
    try std.testing.expectEqual(@as(usize, 2), tp.elems.len);
    try std.testing.expect(arms[2].pattern == .wildcard);
}

test "deeply nested expressions fail with a diagnostic, not a crash" {
    // Nesting-depth guard: thousands of nested parens must produce a
    // normal syntax diagnostic instead of exhausting the native stack.
    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "const x = ");
    for (0..2000) |_| try text.append(std.testing.allocator, '(');
    try text.append(std.testing.allocator, '1');
    for (0..2000) |_| try text.append(std.testing.allocator, ')');
    try text.appendSlice(std.testing.allocator, ";");
    const src = try text.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(src);
    try std.testing.expectError(error.Syntax, parseText(src));
}

test "deeply nested unary chains fail with a diagnostic, not a crash" {
    // Nesting-depth guard: `!!!!…` / `----…` chains recurse through
    // parseUnary without passing through parseExpression, so they count
    // against the same shared 512-level cap (see parseUnary). Regression:
    // a few thousand nested unary operators overflowed the native stack.
    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "const x = ");
    for (0..2000) |_| try text.append(std.testing.allocator, '!');
    try text.append(std.testing.allocator, '1');
    try text.append(std.testing.allocator, ';');
    const src = try text.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(src);
    try std.testing.expectError(error.Syntax, parseText(src));
}

test "deeply nested patterns fail with a diagnostic, not a crash" {
    // Nesting-depth guard: tuple/list/struct patterns recurse through
    // parsePattern (parseTuplePattern/parseListPattern/parsePathPattern),
    // so they count against the same shared 512-level cap. Regression:
    // thousands of nested patterns overflowed the native stack.
    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "let ");
    for (0..2000) |_| try text.append(std.testing.allocator, '(');
    try text.append(std.testing.allocator, '1');
    for (0..2000) |_| try text.append(std.testing.allocator, ')');
    try text.appendSlice(std.testing.allocator, " = 0;");
    const src = try text.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(src);
    try std.testing.expectError(error.Syntax, parseText(src));
}
