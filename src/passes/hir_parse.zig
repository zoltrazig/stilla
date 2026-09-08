//! Canonical HIR text parser — hir.md §4.
//!
//! Recursive-descent parser for the canonical text form defined by
//! hir.md §4.1–§4.5. Opcodes dispatch through `hir.registry` (§4.9); the
//! printer in `hir_print.zig` is the layout authority, so whitespace here
//! is free-form (comments and indentation are ignored).
//!
//! Text binder numbers are printer-local symbols (§4.1): the parser maps
//! each declared `Bk` to a fresh arena `BinderId`, keeps a scope stack of
//! text-number → BinderId, and resolves `%Bk` references against it
//! (§4.9). Scoping follows the lexical structure: a region's params are
//! visible from its body; `let` binds its name only in the continuation —
//! the init is parsed before the declaration goes live, so a reference to
//! the binder being defined inside its own init fails here (the §5.3
//! init-exclusion rule at text level). Function/lambda boundaries are not
//! enforced at parse time: capture-shaped references parse and are left
//! for the structural validator (S3) to reject.
//!
//! Reference resolution (`fnref Fk` / `fnref Hk` / `module Ck`) goes
//! through the `#refs:` dictionary line plus `hir.SerCtx` stable keys
//! (hir.md §4.8) — never by guessing numbers.
//!
//! S2 serialization boundaries (user-approved, PROGRESS.md): nominal
//! types resolve through the fixture `SerCtx` (S4 wires the module
//! tables); struct/field/variant ops whose §4.4 text form cannot carry
//! member/tag identity are *rejected here*, never silently degraded.

const std = @import("std");
const hir = @import("stilla").hir;
const cfg = @import("stilla").cfg;
const ast = @import("stilla").ast;

const ParseError = error{ Syntax, OutOfMemory };

/// A parse diagnostic (message + position). `parseText` reports only the
/// error; callers holding a `Parser` can read `diag` for the detail.
pub const Diag = struct {
    msg: []const u8,
    line: u32,
    col: u32,
};

const fake_span = ast.Span{ .source = 0, .start = 0, .end = 0 };

fn primByWord(word: []const u8) ?ast.PrimitiveKind {
    if (std.mem.eql(u8, word, "i32") or std.mem.eql(u8, word, "int32")) return .int32;
    if (std.mem.eql(u8, word, "i64") or std.mem.eql(u8, word, "int64")) return .int64;
    if (std.mem.eql(u8, word, "u32") or std.mem.eql(u8, word, "uint32")) return .uint32;
    if (std.mem.eql(u8, word, "u64") or std.mem.eql(u8, word, "uint64")) return .uint64;
    if (std.mem.eql(u8, word, "f32") or std.mem.eql(u8, word, "float32")) return .float32;
    if (std.mem.eql(u8, word, "f64") or std.mem.eql(u8, word, "float64")) return .float64;
    if (std.mem.eql(u8, word, "bool")) return .bool;
    if (std.mem.eql(u8, word, "byte")) return .byte;
    if (std.mem.eql(u8, word, "str")) return .str;
    if (std.mem.eql(u8, word, "any")) return .any;
    if (std.mem.eql(u8, word, "void")) return .void;
    if (std.mem.eql(u8, word, "never")) return .never;
    if (std.mem.eql(u8, word, "hostdata")) return .hostdata;
    return null;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

pub const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8 = "",
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    ctx: hir.SerCtx = .{},
    program: hir.Program = undefined,
    root: hir.ExprId = 0,
    diag: ?Diag = null,

    // Text binder scope: frames record the declaration count at each open
    // region; closing the region truncates to the frame mark.
    decls: std.ArrayListUnmanaged(Decl) = .empty,
    frames: std.ArrayListUnmanaged(usize) = .empty,

    // #refs dictionary: print number → stable key, per kind (§4.8).
    refs_f: std.ArrayListUnmanaged(RefEntry) = .empty,
    refs_h: std.ArrayListUnmanaged(RefEntry) = .empty,
    refs_c: std.ArrayListUnmanaged(RefEntry) = .empty,

    const Decl = struct { text_no: u32, binder: hir.BinderId };
    const RefEntry = struct { no: u32, key: []const u8 };

    pub fn init(arena: std.mem.Allocator) Parser {
        return .{ .arena = arena, .program = undefined };
    }

    // -- scanning -----------------------------------------------------------

    fn advance(self: *Parser) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn peek(self: *const Parser) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn peekAt(self: *const Parser, off: usize) u8 {
        return if (self.pos + off < self.src.len) self.src[self.pos + off] else 0;
    }

    fn fail(self: *Parser, msg: []const u8) ParseError {
        self.diag = .{ .msg = msg, .line = self.line, .col = self.col };
        return error.Syntax;
    }

    fn skipWs(self: *Parser) ParseError!void {
        while (self.pos < self.src.len) {
            const c = self.peek();
            if (std.ascii.isWhitespace(c)) {
                _ = self.advance();
            } else if (c == '/' and self.peekAt(1) == '/') {
                while (self.pos < self.src.len and self.peek() != '\n') _ = self.advance();
            } else if (c == '/' and self.peekAt(1) == '*') {
                _ = self.advance();
                _ = self.advance();
                var closed = false;
                while (self.pos < self.src.len) {
                    if (self.peek() == '*' and self.peekAt(1) == '/') {
                        _ = self.advance();
                        _ = self.advance();
                        closed = true;
                        break;
                    }
                    _ = self.advance();
                }
                if (!closed) return self.fail("unterminated block comment");
            } else {
                break;
            }
        }
    }

    /// The next word token: [A-Za-z0-9_]+ with `.`-separated segments
    /// (typed opcode suffixes / nominal paths). Segments stop before `..`
    /// and `::`. Null when the next token is not a word.
    fn wordToken(self: *Parser) ?[]const u8 {
        const start = self.pos;
        if (self.pos >= self.src.len) return null;
        if (!std.ascii.isAlphabetic(self.peek()) and self.peek() != '_') return null;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }
        while (self.pos < self.src.len and self.peek() == '.' and
            self.peekAt(1) != '.' and self.peekAt(1) != ':' and
            (std.ascii.isAlphabetic(self.peekAt(1)) or self.peekAt(1) == '_'))
        {
            _ = self.advance();
            while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
                _ = self.advance();
            }
        }
        return self.src[start..self.pos];
    }

    /// A single word token (no dots).
    fn simpleWord(self: *Parser) ?[]const u8 {
        const start = self.pos;
        if (self.pos >= self.src.len) return null;
        if (!std.ascii.isAlphabetic(self.peek()) and self.peek() != '_') return null;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }
        return self.src[start..self.pos];
    }

    fn expectByte(self: *Parser, b: u8) ParseError!void {
        try self.skipWs();
        if (self.pos >= self.src.len or self.peek() != b) return self.fail("expected a byte");
        _ = self.advance();
    }

    fn expectArrow(self: *Parser) ParseError!void {
        try self.skipWs();
        if (self.peek() != '=' or self.peekAt(1) != '>') return self.fail("expected `=>`");
        _ = self.advance();
        _ = self.advance();
    }

    fn expectColonColon(self: *Parser) ParseError!void {
        try self.skipWs();
        if (self.peek() != ':' or self.peekAt(1) != ':') return self.fail("expected `::`");
        _ = self.advance();
        _ = self.advance();
    }

    fn digitsValue(self: *Parser) ParseError!u32 {
        try self.skipWs();
        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.peek())) _ = self.advance();
        if (self.pos == start) return self.fail("expected digits");
        return std.fmt.parseInt(u32, self.src[start..self.pos], 10) catch
            return self.fail("number out of range");
    }

    /// A `B<digits>` word at the current position, without consuming.
    fn binderNoAt(self: *Parser) ParseError!?u32 {
        try self.skipWs();
        if (self.pos >= self.src.len or self.peek() != 'B') return null;
        const start = self.pos;
        const w = self.simpleWord() orelse return null;
        var ok = w.len >= 2;
        for (w[1..]) |c| {
            if (!std.ascii.isDigit(c)) ok = false;
        }
        if (!ok) {
            self.pos = start;
            return null;
        }
        return std.fmt.parseInt(u32, w[1..], 10) catch return self.fail("binder number out of range");
    }

    fn expectWord(self: *Parser, word: []const u8) ParseError!void {
        try self.skipWs();
        const start = self.pos;
        const w = self.simpleWord() orelse return self.fail("expected keyword");
        if (!std.mem.eql(u8, w, word)) {
            self.pos = start;
            return self.fail("expected keyword");
        }
    }

    fn atWord(self: *Parser, word: []const u8) ParseError!bool {
        try self.skipWs();
        const start = self.pos;
        const w = self.simpleWord() orelse return false;
        const hit = std.mem.eql(u8, w, word);
        self.pos = start;
        return hit;
    }

    fn atByte(self: *Parser, b: u8) ParseError!bool {
        try self.skipWs();
        return self.pos < self.src.len and self.peek() == b;
    }

    // -- binder scoping -----------------------------------------------------

    fn openRegion(self: *Parser) ParseError!void {
        try self.frames.append(self.arena, self.decls.items.len);
    }

    fn closeRegion(self: *Parser) ParseError!void {
        const mark = self.frames.pop().?;
        self.decls.shrinkRetainingCapacity(mark);
    }

    fn declare(self: *Parser, text_no: u32, binder: hir.BinderId) ParseError!void {
        try self.decls.append(self.arena, .{ .text_no = text_no, .binder = binder });
    }

    fn resolve(self: *const Parser, text_no: u32) ?hir.BinderId {
        var i = self.decls.items.len;
        while (i > 0) {
            i -= 1;
            if (self.decls.items[i].text_no == text_no) return self.decls.items[i].binder;
        }
        return null;
    }

    fn opId(self: *Parser, name: []const u8) ParseError!hir.OpId {
        return hir.registry.id(name) orelse return self.fail("unknown opcode");
    }

    // -- entry ---------------------------------------------------------------

    pub fn parse(self: *Parser, text: []const u8) ParseError!hir.Program {
        self.src = text;
        self.pos = 0;
        self.line = 1;
        self.col = 1;
        self.diag = null;
        self.decls.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
        self.refs_f.clearRetainingCapacity();
        self.refs_h.clearRetainingCapacity();
        self.refs_c.clearRetainingCapacity();
        self.program = try hir.Program.init(self.arena);
        try self.parseRefsDict();
        const root = try self.parseExpr();
        try self.skipWs();
        if (self.pos < self.src.len) return self.fail("trailing tokens after expression");
        self.root = root;
        return self.program;
    }

    // -- #refs dictionary (hir.md §4.8) --------------------------------------

    fn parseRefsDict(self: *Parser) !void {
        try self.skipWs();
        const prefix = "#refs:";
        if (self.pos + prefix.len > self.src.len) return;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + prefix.len], prefix)) return;
        self.pos += prefix.len;
        // The dictionary is one line: scan strictly inside it. Newlines
        // are whitespace to the general lexer but end the dictionary, so
        // skip only spaces/tabs here and leave the newline for the caller.
        while (true) {
            try self.skipInlineWs();
            if (self.pos >= self.src.len or self.peek() == '\n') break;
            const kind = self.peek();
            if (kind != 'F' and kind != 'H' and kind != 'C') return self.fail("bad #refs entry kind");
            _ = self.advance();
            const no = try self.digitsValue();
            try self.expectByte('=');
            try self.skipInlineWs();
            const key = self.wordToken() orelse return self.fail("bad #refs key");
            const list: *std.ArrayListUnmanaged(RefEntry) = switch (kind) {
                'F' => &self.refs_f,
                'H' => &self.refs_h,
                else => &self.refs_c,
            };
            try list.append(self.arena, .{ .no = no, .key = key });
            try self.skipInlineWs();
            if (self.pos >= self.src.len or self.peek() == '\n') break;
            try self.expectByte(',');
        }
        if (self.pos < self.src.len) _ = self.advance(); // consume the newline
        try self.skipWs();
    }

    /// Skip spaces and tabs only (never newlines).
    fn skipInlineWs(self: *Parser) !void {
        while (self.pos < self.src.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    /// #refs print number → stable key (or null when the dictionary does
    /// not mention this number — refs never resolve by guessing, §4.9).
    fn dictKey(list: []const RefEntry, no: u32) ?[]const u8 {
        for (list) |e| {
            if (e.no == no) return e.key;
        }
        return null;
    }

    // -- literals ------------------------------------------------------------

    const Literal = struct {
        value: cfg.ConstValue,
        ty: cfg.Type,
    };

    fn litConst(self: *Parser, value: cfg.ConstValue, kind: ast.PrimitiveKind) ParseError!hir.ExprId {
        return self.program.addExpr(.{
            .op = try self.opId("const"),
            .ty = cfg.Type{ .primitive = kind },
            .payload = .{ .const_value = value },
        });
    }

    /// A literal: string, bool, void, or a typed numeric.
    fn parseLiteral(self: *Parser) ParseError!Literal {
        try self.skipWs();
        const c = self.peek();
        if (c == '"') return self.parseStringLit();
        if (c == '-' or std.ascii.isDigit(c)) return self.parseNumeric(false);
        const start = self.pos;
        const w = self.wordToken() orelse return self.fail("bad literal");
        if (std.mem.eql(u8, w, "true")) return .{ .value = .{ .bool = true }, .ty = cfg.Type{ .primitive = .bool } };
        if (std.mem.eql(u8, w, "false")) return .{ .value = .{ .bool = false }, .ty = cfg.Type{ .primitive = .bool } };
        if (std.mem.eql(u8, w, "void")) return .{ .value = .void, .ty = cfg.Type{ .primitive = .void } };
        self.pos = start;
        return self.fail("bad literal");
    }

    fn parseStringLit(self: *Parser) ParseError!Literal {
        try self.skipWs();
        try self.expectByte('"');
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return self.fail("unterminated string");
            const ch = self.advance();
            if (ch == '"') break;
            if (ch == '\\') {
                if (self.pos >= self.src.len) return self.fail("unterminated string escape");
                const esc = self.advance();
                switch (esc) {
                    'n' => try buf.append(self.arena, '\n'),
                    't' => try buf.append(self.arena, '\t'),
                    'r' => try buf.append(self.arena, '\r'),
                    '"' => try buf.append(self.arena, '"'),
                    '\\' => try buf.append(self.arena, '\\'),
                    else => return self.fail("bad string escape"),
                }
            } else {
                try buf.append(self.arena, ch);
            }
        }
        return .{ .value = .{ .string = try buf.toOwnedSlice(self.arena) }, .ty = cfg.Type{ .primitive = .str } };
    }

    /// `[-]?digits[.digits](i32|i64|u32|u64|f32|f64)`, hex allowed. The
    /// canonical printer always emits the type suffix for *expression*
    /// literals; pattern literals print bare and parse back as the
    /// default rep (`allow_bare`, i64/f64 — patterns store the value
    /// only, hir.md §4.3 lit).
    fn parseNumeric(self: *Parser, allow_bare: bool) ParseError!Literal {
        var neg = false;
        if (self.peek() == '-') {
            neg = true;
            _ = self.advance();
        }
        var is_float = false;
        const core_start = self.pos;
        if (self.peek() == '0' and (self.peekAt(1) == 'x' or self.peekAt(1) == 'X')) {
            _ = self.advance();
            _ = self.advance();
            const h = self.pos;
            while (std.ascii.isHex(self.peek())) _ = self.advance();
            if (self.pos == h) return self.fail("bad hex literal");
        } else {
            if (self.peek() == '.') is_float = true;
            while (std.ascii.isDigit(self.peek())) _ = self.advance();
            if (self.peek() == '.') {
                is_float = true;
                _ = self.advance();
                while (std.ascii.isDigit(self.peek())) _ = self.advance();
            }
        }
        const core_end = self.pos;
        const sfx_start = self.pos;
        while (std.ascii.isAlphanumeric(self.peek())) _ = self.advance();
        const suffix = self.src[sfx_start..self.pos];
        if (suffix.len == 0) return self.fail("numeric literal missing type suffix");
        const core = self.src[core_start..core_end];
        if (is_float) {
            const f: f64 = std.fmt.parseFloat(f64, core) catch return self.fail("bad float literal");
            if (suffix.len == 0) {
                if (!allow_bare) return self.fail("numeric literal missing type suffix");
                return .{ .value = .{ .float = if (neg) -f else f }, .ty = cfg.Type{ .primitive = .float64 } };
            }
            const kind: ast.PrimitiveKind = if (std.mem.eql(u8, suffix, "f32"))
                .float32
            else if (std.mem.eql(u8, suffix, "f64"))
                .float64
            else
                return self.fail("bad float literal suffix");
            return .{ .value = .{ .float = if (neg) -f else f }, .ty = cfg.Type{ .primitive = kind } };
        }
        const magnitude = std.fmt.parseInt(u64, core, 0) catch return self.fail("bad integer literal");
        if (suffix.len == 0) {
            if (!allow_bare) return self.fail("numeric literal missing type suffix");
            if (neg) {
                if (magnitude > @as(u64, @bitCast(@as(i64, std.math.minInt(i64))))) {
                    return self.fail("integer literal out of range");
                }
                return .{ .value = .{ .int = -@as(i64, @intCast(magnitude)) }, .ty = cfg.Type{ .primitive = .int64 } };
            }
            if (magnitude > std.math.maxInt(i64)) return self.fail("integer literal out of range");
            return .{ .value = .{ .int = @intCast(magnitude) }, .ty = cfg.Type{ .primitive = .int64 } };
        }
        const kind: ast.PrimitiveKind = if (std.mem.eql(u8, suffix, "i32"))
            .int32
        else if (std.mem.eql(u8, suffix, "i64"))
            .int64
        else if (std.mem.eql(u8, suffix, "u32"))
            .uint32
        else if (std.mem.eql(u8, suffix, "u64"))
            .uint64
        else
            return self.fail("bad integer literal suffix");
        const signed = suffix[0] == 'i';
        if (signed) {
            if (neg) {
                if (magnitude > @as(u64, @bitCast(@as(i64, std.math.minInt(i64))))) {
                    return self.fail("integer literal out of range");
                }
                const v: i64 = -@as(i64, @intCast(magnitude));
                if (suffix[1] == '3' and (v < std.math.minInt(i32) or v > std.math.maxInt(i32))) {
                    return self.fail("integer literal out of range");
                }
                return .{ .value = .{ .int = v }, .ty = cfg.Type{ .primitive = kind } };
            }
            if (suffix[1] == '6') {
                if (magnitude > std.math.maxInt(i64)) return self.fail("integer literal out of range");
                return .{ .value = .{ .int = @intCast(magnitude) }, .ty = cfg.Type{ .primitive = kind } };
            }
            if (magnitude > std.math.maxInt(i32)) return self.fail("integer literal out of range");
            return .{ .value = .{ .int = @intCast(magnitude) }, .ty = cfg.Type{ .primitive = kind } };
        }
        // unsigned
        if (neg) return self.fail("negative unsigned literal");
        if (suffix[1] == '3') {
            if (magnitude > std.math.maxInt(u32)) return self.fail("integer literal out of range");
            return .{ .value = .{ .int = @intCast(magnitude) }, .ty = cfg.Type{ .primitive = kind } };
        }
        return .{ .value = .{ .int = @bitCast(magnitude) }, .ty = cfg.Type{ .primitive = kind } };
    }

    // -- types (hir.md §4.5) -------------------------------------------------

    fn parseType(self: *Parser) ParseError!cfg.Type {
        try self.skipWs();
        const c = self.peek();
        if (c == '(') {
            _ = self.advance();
            var elems: std.ArrayList(cfg.Type) = .empty;
            if (try self.atByte(')')) {
                _ = self.advance();
            } else {
                while (true) {
                    try elems.append(self.arena, try self.parseType());
                    if (try self.atByte(',')) {
                        _ = self.advance();
                        continue;
                    }
                    try self.expectByte(')');
                    break;
                }
            }
            return .{ .tuple = try elems.toOwnedSlice(self.arena) };
        }
        if (c == '[') {
            _ = self.advance();
            const inner = try self.parseType();
            try self.expectByte(']');
            const ptr = try self.arena.create(cfg.Type);
            ptr.* = inner;
            return .{ .list = ptr };
        }
        const start = self.pos;
        const w = self.wordToken() orelse return self.fail("expected type");
        if (std.mem.eql(u8, w, "fn")) {
            try self.expectByte('(');
            var params: std.ArrayList(cfg.Param) = .empty;
            if (!(try self.atByte(')'))) {
                while (true) {
                    const pt = try self.parseType();
                    try params.append(self.arena, cfg.syntheticParam(fake_span, .plain, pt));
                    if (try self.atByte(',')) {
                        _ = self.advance();
                        continue;
                    }
                    break;
                }
            }
            try self.expectByte(')');
            try self.expectWord("->");
            const ret = try self.parseType();
            const ret_ptr = try self.arena.create(cfg.Type);
            ret_ptr.* = ret;
            return .{ .function = .{ .params = try params.toOwnedSlice(self.arena), .ret = ret_ptr } };
        }
        if (primByWord(w)) |k| return cfg.Type{ .primitive = k };
        // Nominal type: resolve the dotted name through the SerCtx decls.
        self.pos = start;
        const path = self.wordToken() orelse return self.fail("expected nominal type");
        var id: usize = self.ctx.types.len;
        var type_params: []const []const u8 = &.{};
        for (self.ctx.types, 0..) |d, i| {
            if (std.mem.eql(u8, d.name(), path)) {
                id = i;
                type_params = switch (d) {
                    .struct_ => |sd| sd.type_params,
                    .union_ => |u| u.type_params,
                    .opaque_, .unknown => &.{},
                };
                break;
            }
        }
        if (id == self.ctx.types.len) return self.fail("unknown nominal type");
        var args: std.ArrayList(cfg.Type) = .empty;
        if (try self.atByte('[')) {
            _ = self.advance();
            if (!(try self.atByte(']'))) {
                while (true) {
                    try args.append(self.arena, try self.parseType());
                    if (try self.atByte(',')) {
                        _ = self.advance();
                        continue;
                    }
                    try self.expectByte(']');
                    break;
                }
            }
        }
        if (args.items.len != type_params.len) return self.fail("wrong number of type arguments");
        return .{ .named = .{ .id = @intCast(id), .args = try args.toOwnedSlice(self.arena) } };
    }

    // -- binders -------------------------------------------------------------

    const BinderDecl = struct {
        text_no: u32,
        ty: cfg.Type,
        mode: hir.BinderMode,
        binder: hir.BinderId,
    };

    /// `Bk: ty (@value|move|borrow)?` — adds the binder.
    fn parseBinderDecl(self: *Parser) ParseError!BinderDecl {
        const no = try self.expectBinderNo();
        try self.expectByte(':');
        const ty = try self.parseType();
        var mode: hir.BinderMode = .value;
        try self.skipWs();
        if (self.peek() == '@') {
            _ = self.advance();
            const m = self.simpleWord() orelse return self.fail("expected binder mode");
            if (std.mem.eql(u8, m, "value")) {
                mode = .value;
            } else if (std.mem.eql(u8, m, "move")) {
                mode = .move;
            } else if (std.mem.eql(u8, m, "borrow")) {
                mode = .borrow;
            } else return self.fail("bad binder mode");
        }
        const binder = try self.program.addBinder(ty, mode);
        return .{ .text_no = no, .ty = ty, .mode = mode, .binder = binder };
    }

    fn expectBinderNo(self: *Parser) ParseError!u32 {
        const no = (try self.binderNoAt()) orelse return self.fail("expected binder name (Bk)");
        return no;
    }

    // -- expressions (hir.md §4.3–§4.4) -------------------------------------

    fn parseExpr(self: *Parser) ParseError!hir.ExprId {
        try self.skipWs();
        const c = self.peek();
        if (c == '(') {
            _ = self.advance();
            const inner = try self.parseExpr();
            try self.expectByte(')');
            return inner;
        }
        if (c == '"' or c == '-' or std.ascii.isDigit(c)) {
            const lit = try self.parseLiteral();
            return self.litConst(lit.value, lit.ty.primitive);
        }
        if (c == '%') {
            _ = self.advance();
            const no = (try self.binderNoAt()) orelse return self.fail("bad binder reference");
            const bid = (self.resolve(no)) orelse return self.fail("reference to unknown binder");
            const b = self.program.binder(bid);
            return self.program.addExpr(.{ .op = try self.opId("local"), .ty = b.ty, .payload = .{ .binder = bid } });
        }
        const w = self.wordToken() orelse return self.fail("expected expression");
        if (std.mem.eql(u8, w, "let")) return self.parseLet();
        if (std.mem.eql(u8, w, "fn")) return self.parseLambda();
        if (std.mem.eql(u8, w, "if")) return self.parseIf();
        if (std.mem.eql(u8, w, "match")) return self.parseMatch();
        if (std.mem.eql(u8, w, "call")) return self.parseCall();
        if (std.mem.eql(u8, w, "panic")) {
            return self.program.addExpr(.{ .op = try self.opId("panic"), .ty = cfg.Type{ .primitive = .never } });
        }
        if (std.mem.eql(u8, w, "fnref")) return self.parseFnRef();
        if (std.mem.eql(u8, w, "module")) return self.parseModuleConst();
        if (std.mem.eql(u8, w, "true")) return self.litConst(.{ .bool = true }, .bool);
        if (std.mem.eql(u8, w, "false")) return self.litConst(.{ .bool = false }, .bool);
        if (std.mem.eql(u8, w, "void")) return self.litConst(.void, .void);
        // Generic opcode call form: op(e, e, …)
        const op = try self.opId(w);
        return self.parseOpForm(op);
    }

    /// Generic opcode form for eager (region-less) ops.
    fn parseOpForm(self: *Parser, op: hir.OpId) ParseError!hir.ExprId {
        const desc = hir.registry.get(op);
        if (desc.regions != .none) return self.fail("region op without a named text form");
        var ops: std.ArrayList(hir.ExprId) = .empty;
        try self.expectByte('(');
        if (!(try self.atByte(')'))) {
            while (true) {
                try ops.append(self.arena, try self.parseExpr());
                if (try self.atByte(',')) {
                    _ = self.advance();
                    continue;
                }
                try self.expectByte(')');
                break;
            }
        }
        const name = desc.name;
        // Arity check per descriptor.
        switch (desc.operands) {
            .none => if (ops.items.len != 0) return self.fail("op takes no operands"),
            .one => if (ops.items.len != 1) return self.fail("op takes one operand"),
            .two => if (ops.items.len != 2) return self.fail("op takes two operands"),
            .callee_and_args, .list => {},
        }
        // Deferred text forms: the §4.4 shorthand loses member/tag
        // identity, so these are rejected, never silently degraded.
        if (std.mem.eql(u8, name, "struct_make") or
            std.mem.eql(u8, name, "field_get") or
            std.mem.eql(u8, name, "variant_make"))
        {
            return self.fail("op text form deferred (member identity not serializable in S2)");
        }
        const annotated = std.mem.eql(u8, name, "num_cast") or
            std.mem.eql(u8, name, "any_cast") or
            (std.mem.eql(u8, name, "list_make") and ops.items.len == 0);
        var ty: cfg.Type = undefined;
        if (annotated) {
            try self.expectByte(':');
            ty = try self.parseType();
        } else {
            ty = try self.opResultType(name, desc, ops.items);
        }
        const operands = try self.program.addOperands(ops.items);
        return self.program.addExpr(.{ .op = op, .ty = ty, .operands = operands });
    }

    /// Result type derived from opcode + operands (used when the node is
    /// not type-annotated in text).
    fn opResultType(self: *Parser, name: []const u8, desc: hir.OpDescriptor, ops: []const hir.ExprId) ParseError!cfg.Type {
        const p = &self.program;
        if (desc.typed) return desc.rep.?.toCfgType();
        if (std.mem.eql(u8, name, "seq")) {
            if (ops.len == 0) return self.fail("seq needs at least one operand");
            return p.node(ops[ops.len - 1]).ty;
        }
        if (std.mem.eql(u8, name, "move") or std.mem.eql(u8, name, "borrow") or std.mem.eql(u8, name, "drop")) {
            return p.node(ops[0]).ty;
        }
        if (std.mem.eql(u8, name, "any_pack")) return cfg.Type{ .primitive = .any };
        if (std.mem.eql(u8, name, "tuple_make")) {
            const elems = try self.arena.alloc(cfg.Type, ops.len);
            for (ops, 0..) |o, i| elems[i] = p.node(o).ty;
            return .{ .tuple = elems };
        }
        if (std.mem.eql(u8, name, "list_make")) {
            const ptr = try self.arena.create(cfg.Type);
            ptr.* = p.node(ops[0]).ty;
            return .{ .list = ptr };
        }
        return self.fail("op needs a result-type annotation");
    }

    fn parseFnRef(self: *Parser) ParseError!hir.ExprId {
        try self.skipWs();
        const tag = self.peek();
        if (tag != 'F' and tag != 'H') return self.fail("bad fnref");
        _ = self.advance();
        const no = try self.digitsValue();
        if (tag == 'F') {
            const key = (dictKey(self.refs_f.items, no)) orelse
                return self.fail("fnref without #refs dictionary entry");
            var id: usize = self.ctx.funcs.len;
            for (self.ctx.funcs, 0..) |f, i| {
                if (std.mem.eql(u8, f.key, key)) id = i;
            }
            if (id == self.ctx.funcs.len) return self.fail("unknown function key");
            return self.program.addExpr(.{
                .op = try self.opId("fn_ref"),
                .ty = self.ctx.funcs[id].type_,
                .payload = .{ .func = .{ .func = @intCast(id) } },
            });
        }
        const key = (dictKey(self.refs_h.items, no)) orelse
            return self.fail("host ref without #refs dictionary entry");
        var id: usize = self.ctx.hosts.len;
        for (self.ctx.hosts, 0..) |h, i| {
            if (std.mem.eql(u8, h.key, key)) id = i;
        }
        if (id == self.ctx.hosts.len) return self.fail("unknown host key");
        return self.program.addExpr(.{
            .op = try self.opId("fn_ref"),
            .ty = self.ctx.hosts[id].type_,
            .payload = .{ .func = .{ .host = @intCast(id) } },
        });
    }

    fn parseModuleConst(self: *Parser) ParseError!hir.ExprId {
        try self.skipWs();
        if (self.peek() != 'C') return self.fail("bad module const reference");
        _ = self.advance();
        const no = try self.digitsValue();
        const key = (dictKey(self.refs_c.items, no)) orelse
            return self.fail("module const without #refs dictionary entry");
        var id: usize = self.ctx.consts.len;
        for (self.ctx.consts, 0..) |c, i| {
            if (std.mem.eql(u8, c.key, key)) id = i;
        }
        if (id == self.ctx.consts.len) return self.fail("unknown module const key");
        return self.program.addExpr(.{
            .op = try self.opId("module_const"),
            .ty = self.ctx.consts[id].type_,
            .payload = .{ .module_const = @intCast(id) },
        });
    }

    /// `let Bk: ty = <init> in <body>` — init is an eager operand outside
    /// the binder's region (§5.3 init exclusion: the declaration goes
    /// live only after the init is parsed).
    fn parseLet(self: *Parser) ParseError!hir.ExprId {
        const decl = try self.parseBinderDecl();
        try self.expectByte('=');
        const init_expr = try self.parseExpr();
        try self.expectWord("in");
        try self.openRegion();
        try self.declare(decl.text_no, decl.binder);
        const body = try self.parseExpr();
        try self.closeRegion();
        const region = try self.program.addRegion(&.{decl.binder}, body, null);
        const regions = try self.program.addRegions(&.{region});
        const operands = try self.program.addOperands(&.{init_expr});
        return self.program.addExpr(.{
            .op = try self.opId("let"),
            .ty = self.program.node(body).ty,
            .operands = operands,
            .regions = regions,
        });
    }

    /// `fn (params) => body` — a lambda value with one parameter region.
    fn parseLambda(self: *Parser) ParseError!hir.ExprId {
        try self.expectByte('(');
        var binds: std.ArrayList(BinderDecl) = .empty;
        if (!(try self.atByte(')'))) {
            while (true) {
                try binds.append(self.arena, try self.parseBinderDecl());
                if (try self.atByte(',')) {
                    _ = self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectByte(')');
        try self.expectArrow();
        try self.openRegion();
        var params: std.ArrayList(hir.BinderId) = .empty;
        var fn_params: std.ArrayList(cfg.Param) = .empty;
        for (binds.items) |b| {
            try self.declare(b.text_no, b.binder);
            try params.append(self.arena, b.binder);
            const mode: ast.ParamMode = switch (b.mode) {
                .value => .plain,
                .move => .move,
                .borrow => .borrow,
            };
            try fn_params.append(self.arena, cfg.syntheticParam(fake_span, mode, b.ty));
        }
        const body = try self.parseExpr();
        try self.closeRegion();
        const region = try self.program.addRegion(params.items, body, null);
        const regions = try self.program.addRegions(&.{region});
        const ret_ptr = try self.arena.create(cfg.Type);
        ret_ptr.* = self.program.node(body).ty;
        const fn_ty = cfg.Type{ .function = .{ .params = try fn_params.toOwnedSlice(self.arena), .ret = ret_ptr } };
        return self.program.addExpr(.{
            .op = try self.opId("lambda"),
            .ty = fn_ty,
            .regions = regions,
        });
    }

    /// `if c then t (else e)?` — cond operand + two no-param regions. A
    /// missing else is a void branch (synthesized const void root).
    fn parseIf(self: *Parser) ParseError!hir.ExprId {
        const cond = try self.parseExpr();
        try self.expectWord("then");
        const then_body = try self.parseExpr();
        var else_root: hir.ExprId = undefined;
        if (try self.atWord("else")) {
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
            else_root = try self.parseExpr();
        } else {
            else_root = try self.litConst(.void, .void);
        }
        const then_reg = try self.program.addRegion(&.{}, then_body, null);
        const else_reg = try self.program.addRegion(&.{}, else_root, null);
        const regions = try self.program.addRegions(&.{ then_reg, else_reg });
        const operands = try self.program.addOperands(&.{cond});
        return self.program.addExpr(.{
            .op = try self.opId("if"),
            .ty = self.program.node(then_body).ty,
            .operands = operands,
            .regions = regions,
        });
    }

    /// `match s { arm, … }` — scrutinee operand + one region per arm.
    fn parseMatch(self: *Parser) ParseError!hir.ExprId {
        const scrutinee = try self.parseExpr();
        const scrutinee_ty = self.program.node(scrutinee).ty;
        try self.expectByte('{');
        var arm_regions: std.ArrayList(hir.RegionId) = .empty;
        var first_body: ?hir.ExprId = null;
        while (true) {
            try self.skipWs();
            if (try self.atByte('}')) break;
            const arm = try self.parseArm(scrutinee_ty);
            try arm_regions.append(self.arena, arm.region);
            if (first_body == null) first_body = arm.body;
            try self.skipWs();
            if (self.pos < self.src.len and self.peek() == ',') {
                _ = self.advance();
                continue;
            }
        }
        try self.expectByte('}');
        if (arm_regions.items.len == 0) return self.fail("match needs at least one arm");
        const regions = try self.program.addRegions(arm_regions.items);
        const operands = try self.program.addOperands(&.{scrutinee});
        return self.program.addExpr(.{
            .op = try self.opId("match"),
            .ty = self.program.node(first_body.?).ty,
            .operands = operands,
            .regions = regions,
        });
    }

    const Arm = struct { region: hir.RegionId, body: hir.ExprId };

    fn parseArm(self: *Parser, scrutinee_ty: cfg.Type) ParseError!Arm {
        var params: std.ArrayList(hir.BinderId) = .empty;
        var pattern_id: ?hir.PatternId = null;
        var body: hir.ExprId = undefined;
        if (try self.armHasPattern()) {
            try self.openRegion();
            pattern_id = try self.parsePatternFor(scrutinee_ty, &params);
            try self.expectArrow();
            body = try self.parseExpr();
            try self.closeRegion();
        } else {
            body = try self.parseExpr();
        }
        const region = try self.program.addRegion(params.items, body, pattern_id);
        return .{ .region = region, .body = body };
    }

    /// Whether the arm at the current position starts with `pattern =>`.
    /// Scans forward (skipping comments/strings, tracking bracket depth)
    /// for a top-level `=>` before the arm ends at `,` or `}`.
    fn armHasPattern(self: *Parser) ParseError!bool {
        var i = self.pos;
        var depth: usize = 0;
        while (i < self.src.len) {
            const c = self.src[i];
            if (c == '/' and i + 1 < self.src.len) {
                if (self.src[i + 1] == '/') {
                    while (i < self.src.len and self.src[i] != '\n') i += 1;
                    continue;
                }
                if (self.src[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < self.src.len and !(self.src[i] == '*' and self.src[i + 1] == '/')) i += 1;
                    i += 2;
                    continue;
                }
            }
            if (c == '"') {
                i += 1;
                while (i < self.src.len and self.src[i] != '"') {
                    if (self.src[i] == '\\') i += 1;
                    i += 1;
                }
                i += 1;
                continue;
            }
            if (c == '(' or c == '[' or c == '{') {
                depth += 1;
                i += 1;
                continue;
            }
            if (c == ')' or c == ']' or c == '}') {
                if (depth == 0) return false;
                depth -= 1;
                i += 1;
                continue;
            }
            if (depth == 0) {
                if (c == '=' and i + 1 < self.src.len and self.src[i + 1] == '>') return true;
                if (c == ',' or c == '}') return false;
            }
            i += 1;
        }
        return false;
    }

    // -- patterns (hir.md §4.3, §5.4) ---------------------------------------

    /// Parse one arm pattern against the current scrutinee subtype. Binder
    /// leaves declare their text name (visible to the arm body — the arm
    /// is inside an open region frame) and append to `params` in text
    /// order: those are the arm region's params (§5.4).
    fn parsePatternFor(self: *Parser, sub_ty: cfg.Type, params: *std.ArrayList(hir.BinderId)) ParseError!hir.PatternId {
        try self.skipWs();
        const c = self.peek();
        if (c == '_') {
            _ = self.advance();
            return self.program.addPattern(.wildcard);
        }
        if (c == 'B') {
            const no = (try self.binderNoAt()) orelse return self.fail("bad pattern binder");
            const bid = try self.program.addBinder(sub_ty, .value);
            try self.declare(no, bid);
            try params.append(self.arena, bid);
            return self.program.addPattern(.{ .bind = bid });
        }
        if (c == '"') {
            const lit = try self.parseStringLit();
            return self.program.addPattern(.{ .literal = lit.value });
        }
        if (c == '-' or std.ascii.isDigit(c)) {
            const lit = try self.parseNumeric(true);
            return self.program.addPattern(.{ .literal = lit.value });
        }
        if (c == '(') {
            if (sub_ty != .tuple) return self.fail("tuple pattern on a non-tuple scrutinee");
            _ = self.advance();
            const elems_ty = sub_ty.tuple;
            var children: std.ArrayList(hir.PatternId) = .empty;
            var i: usize = 0;
            if (try self.atByte(')')) {
                _ = self.advance();
            } else {
                while (true) {
                    if (i >= elems_ty.len) return self.fail("tuple pattern has too many elements");
                    try children.append(self.arena, try self.parsePatternFor(elems_ty[i], params));
                    i += 1;
                    if (try self.atByte(',')) {
                        _ = self.advance();
                        continue;
                    }
                    try self.expectByte(')');
                    break;
                }
            }
            return self.program.addPattern(.{ .tuple = try children.toOwnedSlice(self.arena) });
        }
        if (c == '[') {
            if (sub_ty != .list) return self.fail("list pattern on a non-list scrutinee");
            _ = self.advance();
            const elem_ty = sub_ty.list.*;
            var children: std.ArrayList(hir.PatternId) = .empty;
            var rest: ?hir.PatternId = null;
            if (!(try self.atByte(']'))) {
                while (true) {
                    if (self.peek() == '.' and self.peekAt(1) == '.') {
                        _ = self.advance();
                        _ = self.advance();
                        rest = try self.parsePatternFor(elem_ty, params);
                        break;
                    }
                    try children.append(self.arena, try self.parsePatternFor(elem_ty, params));
                    if (try self.atByte(',')) {
                        _ = self.advance();
                        continue;
                    }
                    break;
                }
            }
            try self.expectByte(']');
            return self.program.addPattern(.{ .list = .{
                .elems = try children.toOwnedSlice(self.arena),
                .rest = rest,
            } });
        }
        // Words: literal words, then nominal path patterns or a type-test.
        const start = self.pos;
        const w = self.wordToken() orelse return self.fail("expected pattern");
        if (std.mem.eql(u8, w, "true")) return self.program.addPattern(.{ .literal = .{ .bool = true } });
        if (std.mem.eql(u8, w, "false")) return self.program.addPattern(.{ .literal = .{ .bool = false } });
        if (std.mem.eql(u8, w, "void")) return self.program.addPattern(.{ .literal = .void });
        // Variant path `Nom::Var`?
        if (self.peek() == ':' and self.peekAt(1) == ':') {
            if (sub_ty != .named) return self.fail("variant pattern on a non-nominal scrutinee");
            const named = sub_ty.named;
            const decl = self.ctxDecl(named.id) orelse return self.fail("nominal type outside serialization context");
            if (decl != .union_ or !std.mem.eql(u8, decl.name(), w)) {
                return self.fail("variant path does not match scrutinee type");
            }
            try self.expectColonColon();
            const vname = self.simpleWord() orelse return self.fail("expected variant name");
            const tag = try self.variantTag(named, vname);
            const payload_ty = try self.variantPayloadTy(named, tag, vname);
            var payload: ?hir.PatternId = null;
            if (try self.atByte('(')) {
                _ = self.advance();
                if (payload_ty == null) return self.fail("variant has no payload");
                payload = try self.parsePatternFor(payload_ty.?, params);
                try self.expectByte(')');
            } else if (payload_ty != null) {
                return self.fail("variant payload needs a pattern");
            }
            return self.program.addPattern(.{ .variant = .{ .tag = tag, .payload = payload } });
        }
        // Struct pattern `Nom { fields }`?
        if (self.peek() == '{') {
            if (sub_ty != .named) return self.fail("struct pattern on a non-nominal scrutinee");
            return self.parseStructPattern(sub_ty.named, params);
        }
        // Otherwise a type-test pattern `ty Bk`: rewind and parse a type.
        self.pos = start;
        const ty = try self.parseType();
        const no = (try self.binderNoAt()) orelse return self.fail("expected binder after type in pattern");
        const bid = try self.program.addBinder(ty, .value);
        try self.declare(no, bid);
        try params.append(self.arena, bid);
        return self.program.addPattern(.{ .type_test = .{ .ty = ty, .bind = bid } });
    }

    /// The discriminant (decl index) of variant `name` in a union decl.
    fn variantTag(self: *Parser, named: cfg.Type.Named, name: []const u8) ParseError!u32 {
        const decl = self.ctxDecl(named.id) orelse return self.fail("nominal type outside serialization context");
        if (decl != .union_) return self.fail("variant pattern on a non-union nominal type");
        for (decl.union_.variants, 0..) |v, i| {
            if (std.mem.eql(u8, v.name, name)) return @intCast(i);
        }
        return self.fail("unknown variant name");
    }

    /// The concrete payload subtype of variant `tag` of the scrutinee
    /// instantiation (type params substituted), or null for a payload-less
    /// variant.
    fn variantPayloadTy(self: *Parser, named: cfg.Type.Named, tag: u32, vname: []const u8) ParseError!?cfg.Type {
        const decl = (self.ctxDecl(named.id) orelse return self.fail("nominal type outside serialization context")).union_;
        if (tag >= decl.variants.len or !std.mem.eql(u8, decl.variants[tag].name, vname)) {
            return self.fail("variant index/name mismatch");
        }
        const payloads = decl.variants[tag].payloads;
        if (payloads.len == 0) return null;
        if (payloads.len == 1) {
            return cfg.substParams(self.arena, decl.type_params, named.args, payloads[0]);
        }
        const tys = try self.arena.alloc(cfg.Type, payloads.len);
        for (payloads, 0..) |pt, i| tys[i] = cfg.substParams(self.arena, decl.type_params, named.args, pt);
        return .{ .tuple = tys };
    }

    fn parseStructPattern(self: *Parser, named: cfg.Type.Named, params: *std.ArrayList(hir.BinderId)) ParseError!hir.PatternId {
        const decl = (self.ctxDecl(named.id) orelse return self.fail("nominal type outside serialization context")).struct_;
        try self.expectByte('{');
        var fields: std.ArrayList(hir.Pattern.FieldPattern) = .empty;
        if (!(try self.atByte('}'))) {
            while (true) {
                const fname = self.simpleWord() orelse return self.fail("expected field name");
                var index: ?usize = null;
                for (decl.fields, 0..) |f, i| {
                    if (std.mem.eql(u8, f.name, fname)) index = i;
                }
                if (index == null) return self.fail("unknown struct field");
                if (!(try self.atByte(':'))) {
                    return self.fail("struct field shorthand is not serializable; write `field: pattern`");
                }
                _ = self.advance();
                const field_ty = cfg.substParams(self.arena, decl.type_params, named.args, decl.fields[index.?].type_);
                const child = try self.parsePatternFor(field_ty, params);
                try fields.append(self.arena, .{ .field = @intCast(index.?), .pat = child });
                if (try self.atByte(',')) {
                    _ = self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectByte('}');
        return self.program.addPattern(.{ .struct_ = .{ .fields = try fields.toOwnedSlice(self.arena) } });
    }

    fn ctxDecl(self: *Parser, id: cfg.TypeId) ?cfg.TypeDecl {
        if (id >= self.ctx.types.len) return null;
        return self.ctx.types[id];
    }

    fn parseCall(self: *Parser) ParseError!hir.ExprId {
        try self.expectByte('(');
        const callee = try self.parseExpr();
        var args: std.ArrayList(hir.ExprId) = .empty;
        if (!(try self.atByte(')'))) {
            while (true) {
                try self.expectByte(',');
                try args.append(self.arena, try self.parseExpr());
                if (try self.atByte(',')) {
                    _ = self.advance();
                    continue;
                }
                try self.expectByte(')');
                break;
            }
        }
        var all: std.ArrayList(hir.ExprId) = .empty;
        try all.append(self.arena, callee);
        try all.appendSlice(self.arena, args.items);
        const callee_ty = self.program.node(callee).ty;
        if (callee_ty != .function) return self.fail("call callee is not a function");
        const operands = try self.program.addOperands(all.items);
        return self.program.addExpr(.{
            .op = try self.opId("call"),
            .ty = callee_ty.function.ret.*,
            .operands = operands,
        });
    }
};

/// Parse canonical text into a fresh arena-owned program. The caller owns
/// the arena. `ctx` supplies nominal decls and ref stable keys (§4.8);
/// pass `.{}` for refs- and nominal-free text.
pub fn parseText(text: []const u8, ctx: hir.SerCtx) ParseError!struct {
    arena: std.heap.ArenaAllocator,
    program: hir.Program,
    root: hir.ExprId,
} {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    var p = Parser.init(arena.allocator());
    p.ctx = ctx;
    const program = try p.parse(text);
    return .{ .arena = arena, .program = program, .root = p.root };
}
