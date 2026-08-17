//! Standalone IR text parser — ir.md §9 (the `cfg` text form).
//!
//! Turns the token stream produced by `src/passes/cfg_lex.zig` into the
//! in-memory CFG structures of `cfg.zig`. Self-contained: no dependency
//! on the module graph or the type checker; where ir.md §11 names
//! frontend artifacts, `cfg.zig` substitutes IR-native equivalents (see
//! `cfg.zig`'s header). The parser works over the `cfg` structures
//! directly, so the names are aliased here under the bare identifiers the
//! single-file code used.
//!
//! `src/cfg.zig` re-exports `Parser` and `Diag`, so `cfg.Parser` keeps
//! working for tests, golden files, and round-trip checks.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");

// IR structures (cfg.zig), brought into scope under the bare names the
// parser uses.
const Type = cfg.Type;
const TypeId = cfg.TypeId;
const Param = cfg.Param;
const ValueState = cfg.ValueState;
const ConstValue = cfg.ConstValue;
const Value = cfg.Value;
const Instr = cfg.Instr;
const Op = cfg.Op;
const Bin = cfg.Bin;
const Proj = cfg.Proj;
const Index = cfg.Index;
const Construct = cfg.Construct;
const LoadMember = cfg.LoadMember;
const StoreMember = cfg.StoreMember;
const DirectCallee = cfg.DirectCallee;
const Callee = cfg.Callee;
const Call = cfg.Call;
const BuiltinId = cfg.BuiltinId;
const SysCallTarget = cfg.SysCallTarget;
const SysCall = cfg.SysCall;
const Phi = cfg.Phi;
const PhiIn = cfg.PhiIn;
const BorrowOrigin = cfg.BorrowOrigin;
const Terminator = cfg.Terminator;
const Switch = cfg.Switch;
const SwitchArm = cfg.SwitchArm;
const BasicBlock = cfg.BasicBlock;
const IrFunc = cfg.IrFunc;
const SlotMeta = cfg.SlotMeta;
const IrModule = cfg.IrModule;
const IrProgram = cfg.IrProgram;

const cfg_lex = @import("cfg_lex.zig");

// Lexical layer (cfg_lex.zig), brought into scope under the bare names
// the parser uses; the tokenizer itself lives there as `Lexer`.
const TokKind = cfg_lex.TokKind;
const Token = cfg_lex.Token;
pub const Diag = cfg_lex.Diag;
const describe = cfg_lex.describe;

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const ParseError = error{ Syntax, OutOfMemory };

const OpName = enum {
    const_,
    module_ref,
    fn_ref,
    neg,
    not_,
    num_cast,
    type_is,
    any_pack_copy,
    any_pack_move,
    any_unpack_copy,
    any_unpack_move,
    cleanup_owner,
    add,
    sub,
    mul,
    div,
    rem,
    concat,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    copy,
    borrow,
    move_,
    tail,
    load_member,
    store_member,
    construct,
    read_field,
    read_tuple,
    read_index,
    unpack_struct,
    unpack_tuple,
    unpack_variant,
    split_list,
    read_tag,
    read_payload,
    borrow_variant,
    call,
    syscall,
    phi,
};

/// The defining-op name map, generated from the op schema (ir.md §5,
/// cfg.opInfo): each `OpName` member whose name matches an `Op` tag gets
/// the schema's canonical spelling, so the parser and the printer can
/// never disagree about an op's text. Effects (`drop`, `store_member`,
/// `cleanup_disable`, `drop_cleanup`) are parsed as bare statements and
/// are not in the map.
const op_names = blk: {
    @setEvalBranchQuota(100_000);
    const tags = std.meta.tags(OpName);
    var entries: [tags.len]struct { []const u8, OpName } = undefined;
    var n: usize = 0;
    for (cfg.op_table) |e| {
        if (std.meta.stringToEnum(OpName, @tagName(e.tag))) |tag| {
            entries[n] = .{ e.info.text, tag };
            n += 1;
        }
    }
    break :blk std.StaticStringMap(OpName).initComptime(entries[0..n]);
};

const primitive_names = std.StaticStringMap(ast.PrimitiveKind).initComptime(.{
    .{ "any", .any },
    .{ "byte", .byte },
    .{ "hostdata", .hostdata },
    .{ "int32", .int32 },
    .{ "uint32", .uint32 },
    .{ "float32", .float32 },
    .{ "bool", .bool },
    .{ "str", .str },
    .{ "void", .void },
    .{ "never", .never },
});

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,
    lex: cfg_lex.Lexer,
    text: []const u8 = "",
    tokens: []const Token = &.{},
    pos: usize = 0,
    /// The first error, when parsing failed.
    diag: ?Diag = null,

    // Per-function state, re-initialized in parseFunc.
    f_name: []const u8 = "",
    f_ret: Type = .{ .primitive = .void },
    f_params: []Param = &.{},
    f_values: std.ArrayList(*Value) = .empty,
    f_symbols: std.StringHashMap(*Value) = undefined,
    f_blocks: std.ArrayList(*BasicBlock) = .empty,
    f_block_instrs: std.ArrayList(std.ArrayList(*Instr)) = .empty,
    f_block_names: std.StringHashMap(u32) = undefined,
    f_cur: ?*BasicBlock = null,
    /// Closing brace token of the current function, for error spans.
    f_brace: Token = undefined,
    next_func_id: u32 = 0,

    // Program-level type environment (ir.md §11): the text form names
    // structs/unions by string, so the parser interns each first-seen
    // name into a stable `TypeId` and records the written name so
    // printing round-trips it (ir.md §11; the text form carries no
    // struct/union decls).
    type_ids: std.StringHashMap(u32) = undefined,
    types: std.ArrayList([]const u8) = .empty,
    type_ids_ready: bool = false,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .lex = cfg_lex.Lexer.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        // All working memory (bulk + every managed container) is
        // arena-owned; one `arena.deinit` frees it all.
        self.arena.deinit();
        self.lex.deinit();
    }

    /// Parse one IR text program.
    pub fn parse(self: *Parser, text: []const u8) ParseError!IrProgram {
        // The managed containers live on the parser arena, address-stable
        // only once the parser is placed; initialize them here on first
        // parse so a single `arena.deinit` frees everything.
        if (!self.type_ids_ready) {
            self.type_ids = std.StringHashMap(u32).init(self.arena.allocator());
            self.type_ids_ready = true;
        }
        self.text = text;
        self.tokens = self.lex.tokenize(text) catch |err| {
            // A lexical error surfaces through the parser's diag, as
            // before the lexer was split out.
            if (self.lex.diag) |d| self.diag = d;
            return err;
        };
        self.pos = 0;
        return self.parseProgram();
    }

    // -----------------------------------------------------------------
    // Token cursor helpers
    // -----------------------------------------------------------------

    fn cur(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn at(self: *Parser, kind: TokKind) bool {
        return self.tokens[self.pos].kind == kind;
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (t.kind != .eof) self.pos += 1;
        return t;
    }

    fn eat(self: *Parser, kind: TokKind) bool {
        if (self.at(kind)) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.at(.newline)) self.pos += 1;
    }

    fn expect(self: *Parser, kind: TokKind, what: []const u8) ParseError!void {
        if (!self.at(kind)) {
            return self.fail(self.cur(), "expected {s}, found '{s}'", .{ what, describe(self.cur()) });
        }
        self.pos += 1;
    }

    fn fail(self: *Parser, tok: Token, comptime fmt: []const u8, args: anytype) ParseError {
        return self.failAt(tok.span, fmt, args);
    }

    fn failAt(self: *Parser, span: ast.Span, comptime fmt: []const u8, args: anytype) ParseError {
        const pos = cfg_lex.lineCol(self.text, span.start);
        const msg = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch "out of memory";
        self.diag = .{ .line = pos.line, .column = pos.column, .message = msg };
        return error.Syntax;
    }

    // -----------------------------------------------------------------
    // Program structure
    // -----------------------------------------------------------------

    fn parseProgram(self: *Parser) ParseError!IrProgram {
        var modules = std.ArrayList(*IrModule).empty;
        var funcs = std.ArrayList(*IrFunc).empty;
        while (true) {
            self.skipNewlines();
            if (self.at(.eof)) break;
            const t = self.cur();
            if (t.kind != .ident or !std.mem.eql(u8, t.text, "module")) {
                return self.fail(t, "expected 'module', found '{s}'", .{describe(t)});
            }
            _ = self.advance();
            const spec = try self.expectString("module specifier");
            try self.expect(.lbrace, "'{'");
            var mfuncs = std.ArrayList(*IrFunc).empty;
            while (true) {
                self.skipNewlines();
                if (self.at(.rbrace)) {
                    _ = self.advance();
                    break;
                }
                if (self.at(.eof)) return self.fail(self.cur(), "unterminated module '{s}'", .{spec});
                const ft = self.cur();
                if (ft.kind != .ident or !std.mem.eql(u8, ft.text, "func")) {
                    return self.fail(ft, "expected 'func' or '}}', found '{s}'", .{describe(ft)});
                }
                const f = try self.parseFunc();
                try mfuncs.append(self.arena.allocator(), f);
                try funcs.append(self.arena.allocator(), f);
            }
            const m = try self.arena.allocator().create(IrModule);
            var init_func: ?*IrFunc = null;
            for (mfuncs.items) |f| {
                if (std.mem.eql(u8, f.name.text, "init")) {
                    init_func = f;
                    break;
                }
            }
            const slots = try self.collectSlots(init_func);
            m.* = .{
                .span = t.span,
                .name = spec,
                .init = init_func,
                .funcs = try self.arena.allocator().dupe(*IrFunc, mfuncs.items),
                .slots = slots,
            };
            try modules.append(self.arena.allocator(), m);
        }
        const program = try self.arena.allocator().create(IrProgram);
        program.* = .{
            .modules = try self.arena.allocator().dupe(*IrModule, modules.items),
            .funcs = try self.arena.allocator().dupe(*IrFunc, funcs.items),
            // The text form carries no type declarations; typed names are
            // interned into the name table as they are parsed (ir.md §11).
            .types = try self.arena.allocator().dupe([]const u8, self.types.items),
            .entry = null,
        };
        try program.resolveDirectCalls(self.arena.allocator());
        return program.*;
    }

    /// Module storage layout: the `store_member` ops of `@init`, in
    /// instruction order (declaration order, Core §5).
    fn collectSlots(self: *Parser, init_func: ?*IrFunc) ParseError![]SlotMeta {
        if (init_func == null) return &.{};
        var slots = std.ArrayList(SlotMeta).empty;
        for (init_func.?.blocks) |b| {
            for (b.instrs) |instr| {
                switch (instr.op) {
                    .store_member => |sm| {
                        try slots.append(self.arena.allocator(), .{
                            .type_ = sm.value.type_,
                            .init_order = @intCast(slots.items.len),
                        });
                    },
                    else => {},
                }
            }
        }
        return self.arena.allocator().dupe(SlotMeta, slots.items);
    }

    // -----------------------------------------------------------------
    // Functions
    // -----------------------------------------------------------------

    fn parseFunc(self: *Parser) ParseError!*IrFunc {
        const start_tok = self.cur(); // 'func'
        _ = self.advance();
        const name_tok = self.cur();
        if (name_tok.kind != .func_ref) {
            return self.fail(name_tok, "expected a function name after 'func', found '{s}'", .{describe(name_tok)});
        }
        _ = self.advance();
        try self.expect(.lparen, "'('");
        var params = std.ArrayList(Param).empty;
        while (!self.at(.rparen)) {
            const pspan = self.cur().span;
            var mode: ast.ParamMode = .plain;
            if (self.at(.ident)) {
                const it = self.cur();
                if (std.mem.eql(u8, it.text, "borrow")) {
                    mode = .borrow;
                    _ = self.advance();
                } else if (std.mem.eql(u8, it.text, "move")) {
                    mode = .move;
                    _ = self.advance();
                }
            }
            const pname = self.cur();
            if (pname.kind != .ident) {
                return self.fail(pname, "expected a parameter name, found '{s}'", .{describe(pname)});
            }
            _ = self.advance();
            try self.expect(.colon, "':'");
            const ptype = try self.parseType();
            try params.append(self.arena.allocator(), .{
                .span = pspan,
                .name = .{ .span = pname.span, .text = pname.text },
                .mode = mode,
                .type_ = ptype,
            });
            if (!self.eat(.comma)) break;
        }
        try self.expect(.rparen, "')'");
        var ret: Type = .{ .primitive = .void };
        if (self.eat(.arrow)) ret = try self.parseType();
        try self.expect(.lbrace, "'{'");

        // Reset per-function state and seed parameter values (%0..%k-1).
        self.f_name = name_tok.text;
        self.f_ret = ret;
        self.f_params = try self.arena.allocator().dupe(Param, params.items);
        self.f_values = std.ArrayList(*Value).empty;
        self.f_symbols = std.StringHashMap(*Value).init(self.arena.allocator());
        self.f_blocks = std.ArrayList(*BasicBlock).empty;
        self.f_block_instrs = std.ArrayList(std.ArrayList(*Instr)).empty;
        self.f_block_names = std.StringHashMap(u32).init(self.arena.allocator());
        self.f_cur = null;

        for (self.f_params, 0..) |p, idx| {
            const v = try self.newValue(p.span, p.type_, if (p.mode == .borrow) .borrowed else .owned);
            if (p.mode == .borrow) v.origin = .call;
            try self.f_symbols.put(p.name.text, v);
            _ = idx;
        }

        // Body token range: up to the matching '}' (depth counts the
        // braces of `switch` terminators, the only inline braces).
        const body_start = self.pos;
        var depth: usize = 0;
        var body_end = body_start;
        while (body_end < self.tokens.len) {
            switch (self.tokens[body_end].kind) {
                .lbrace => depth += 1,
                .rbrace => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                else => {},
            }
            body_end += 1;
        }
        if (body_end >= self.tokens.len) {
            return self.fail(name_tok, "unterminated body of function '@{s}'", .{self.f_name});
        }
        self.f_brace = self.tokens[body_end];

        try self.scanLabels(body_start, body_end);
        // Pre-register every `%name:` definition: SSA phis may reference a
        // value defined later in the text (a loop back edge), so named
        // forward references must resolve after the whole body is known.
        try self.registerValueNames(body_start, body_end);
        try self.parseBlockStatements(body_end);

        if (self.f_cur) |open| {
            return self.fail(self.f_brace, "block '{s}' is missing a terminator", .{open.name});
        }
        self.pos = body_end + 1; // consume '}'

        return self.finishFunc(start_tok, name_tok, ret);
    }

    /// Pre-register every value definition site (`%name:` in the body) as
    /// a placeholder, so phi operands may reference values defined later
    /// in the text (ir.md §4.3: a loop back edge). Placeholder ids are
    /// assigned in text order, which is definition order.
    fn registerValueNames(self: *Parser, start: usize, end: usize) ParseError!void {
        var i = start;
        while (i + 1 < end) {
            const t = self.tokens[i];
            if (t.kind == .value_ref and self.tokens[i + 1].kind == .colon) {
                if (isAllDigits(t.text)) {
                    const n = std.fmt.parseInt(u32, t.text, 10) catch
                        return self.fail(t, "invalid value id '%{s}'", .{t.text});
                    if (n != self.f_values.items.len) {
                        return self.fail(t, "value %{s} defined out of order (expected %{d})", .{ t.text, self.f_values.items.len });
                    }
                } else if (self.f_symbols.contains(t.text)) {
                    return self.fail(t, "duplicate value name '%{s}' (SSA: each value is defined once)", .{t.text});
                }
                const v = try self.arena.allocator().create(Value);
                v.* = .{
                    .id = @intCast(self.f_values.items.len),
                    .span = t.span,
                    .type_ = undefined,
                    .ownership = null,
                    .state = .owned,
                    .origin = null,
                    .def = null,
                };
                try self.f_values.append(self.arena.allocator(), v);
                if (!isAllDigits(t.text)) try self.f_symbols.put(t.text, v);
            }
            i += 1;
        }
    }

    /// Pass 1 over the body: register `label:` names before any statement
    /// is parsed, so forward references in terminators and phis resolve.
    fn scanLabels(self: *Parser, start: usize, end: usize) ParseError!void {
        var stmt_start = true;
        var i = start;
        while (i < end) {
            const tk = self.tokens[i];
            switch (tk.kind) {
                .newline => stmt_start = true,
                else => {
                    if (stmt_start and tk.kind == .ident and i + 1 < end and self.tokens[i + 1].kind == .colon) {
                        if (self.f_block_names.contains(tk.text)) {
                            return self.fail(tk, "duplicate block label '{s}'", .{tk.text});
                        }
                        const b = try self.arena.allocator().create(BasicBlock);
                        b.* = .{
                            .id = @intCast(self.f_blocks.items.len),
                            .span = tk.span,
                            .name = tk.text,
                            .instrs = &.{},
                            .terminator = undefined,
                            .preds = &.{},
                        };
                        try self.f_block_names.put(tk.text, b.id);
                        try self.f_blocks.append(self.arena.allocator(), b);
                        try self.f_block_instrs.append(self.arena.allocator(), std.ArrayList(*Instr).empty);
                    }
                    stmt_start = false;
                },
            }
            i += 1;
        }
    }

    /// Pass 2 over the body: build blocks, instructions, and terminators.
    fn parseBlockStatements(self: *Parser, end: usize) ParseError!void {
        while (self.pos < end) {
            while (self.pos < end and self.at(.newline)) self.pos += 1;
            if (self.pos >= end) break;
            const tok = self.tokens[self.pos];
            if (tok.kind == .ident and self.tokens[self.pos + 1].kind == .colon) {
                if (self.f_cur) |open| {
                    return self.fail(tok, "block '{s}' is missing a terminator before label '{s}'", .{ open.name, tok.text });
                }
                const idx = self.f_block_names.get(tok.text) orelse unreachable;
                self.f_cur = self.f_blocks.items[idx];
                self.pos += 2; // consume label and ':'
                continue;
            }
            switch (tok.kind) {
                .value_ref => try self.parseDefiningInstr(),
                .ident => try self.parseIdentStatement(),
                else => return self.fail(tok, "expected a label, instruction, or terminator, found '{s}'", .{describe(tok)}),
            }
            // Each statement ends at a newline (or the body's closing
            // brace); stray tokens are an error.
            const after = self.cur();
            if (after.kind != .newline and after.kind != .rbrace and after.kind != .eof) {
                return self.fail(after, "unexpected '{s}' after statement", .{describe(after)});
            }
        }
    }

    fn finishFunc(self: *Parser, start_tok: Token, name_tok: Token, ret: Type) ParseError!*IrFunc {
        if (self.f_blocks.items.len == 0) {
            return self.fail(self.f_brace, "function '@{s}' has no blocks", .{self.f_name});
        }
        const blocks = try self.arena.allocator().dupe(*BasicBlock, self.f_blocks.items);
        const instr_lists = try self.arena.allocator().alloc([]const *Instr, self.f_block_instrs.items.len);
        for (self.f_block_instrs.items, 0..) |list, i| instr_lists[i] = list.items;
        if (try cfg.finalizeBlocks(self.arena.allocator(), blocks, instr_lists, null)) |d| {
            return self.failAt(d.span, "{s}", .{d.message});
        }
        const f = try self.arena.allocator().create(IrFunc);
        f.* = .{
            .id = self.next_func_id,
            .span = ast.Span.merge(start_tok.span, self.f_brace.span),
            .name = .{ .span = name_tok.span, .text = name_tok.text },
            .params = self.f_params,
            .ret = ret,
            .entry = blocks[0],
            .blocks = blocks,
            .values = try self.arena.allocator().dupe(*Value, self.f_values.items),
        };
        self.next_func_id += 1;
        return f;
    }

    // -----------------------------------------------------------------
    // Statements and instructions
    // -----------------------------------------------------------------

    fn parseDefiningInstr(self: *Parser) ParseError!void {
        if (self.f_cur == null) {
            return self.fail(self.cur(), "instruction appears after the block's terminator", .{});
        }
        // The lhs: one or more `%name: type` pairs. The op's schema row
        // decides whether multiple results are legal (`OpInfo.multi`,
        // ir.md §5.3 — only the atomic destructure ops define more than
        // one value).
        var name_toks = std.ArrayList(Token).empty;
        var types = std.ArrayList(Type).empty;
        while (true) {
            const name_tok = self.advance(); // %name
            try self.expect(.colon, "':'");
            try types.append(self.arena.allocator(), try self.parseType());
            try name_toks.append(self.arena.allocator(), name_tok);
            if (!self.eat(.comma)) break;
        }
        try self.expect(.equals, "'='");
        const op_tok = self.cur();
        if (op_tok.kind != .ident) {
            return self.fail(op_tok, "expected an instruction name, found '{s}'", .{describe(op_tok)});
        }
        const opname = op_names.get(op_tok.text) orelse {
            if (std.mem.eql(u8, op_tok.text, "drop") or std.mem.eql(u8, op_tok.text, "store_member") or std.mem.eql(u8, op_tok.text, "cleanup_disable") or std.mem.eql(u8, op_tok.text, "drop_cleanup")) {
                return self.fail(op_tok, "'{s}' produces no value; write it as a bare statement", .{op_tok.text});
            }
            return self.fail(op_tok, "unknown instruction '{s}'", .{op_tok.text});
        };
        _ = self.advance();
        const info = cfg.opInfo(std.meta.stringToEnum(cfg.OpTag, @tagName(opname)).?);
        if (name_toks.items.len != 1 and !info.multi) {
            return self.fail(op_tok, "'{s}' defines {d} results; only the atomic destructure ops define more than one", .{ info.text, name_toks.items.len });
        }
        var op = try self.parseOpOperands(opname);
        if (std.meta.activeTag(op) == .syscall) op.syscall.ret = types.items[0];
        // Resolve the pre-registered placeholders: numeric def names are
        // positional (validated to equal the running id at registration),
        // symbolic names via the symbol table.
        const results = try self.arena.allocator().alloc(*Value, name_toks.items.len);
        for (name_toks.items, types.items, 0..) |name_tok, type_, i| {
            const v = if (isAllDigits(name_tok.text))
                self.f_values.items[@intCast(std.fmt.parseInt(u32, name_tok.text, 10) catch unreachable)]
            else
                self.f_symbols.get(name_tok.text) orelse unreachable;
            v.span = name_tok.span;
            v.type_ = type_;
            v.ownership = type_.ownership();
            v.state = createdState(op, type_);
            if (v.state == .borrowed) v.origin = cfg.originOf(op);
            results[i] = v;
        }
        _ = try self.emit(name_toks.items[0].span, op, results);
    }

    /// Statement starting with a bare identifier: an effect instruction or
    /// a terminator.
    fn parseIdentStatement(self: *Parser) ParseError!void {
        const t = self.cur();
        const text = t.text;
        if (std.mem.eql(u8, text, "drop")) {
            _ = self.advance();
            if (self.f_cur == null) return self.fail(t, "instruction appears after the block's terminator", .{});
            const v = try self.parseOperand();
            _ = try self.emit(t.span, .{ .drop_ = v }, &.{});
            return;
        }
        if (std.mem.eql(u8, text, "cleanup_disable")) {
            _ = self.advance();
            if (self.f_cur == null) return self.fail(t, "instruction appears after the block's terminator", .{});
            const v = try self.parseOperand();
            _ = try self.emit(t.span, .{ .cleanup_disable = v }, &.{});
            return;
        }
        if (std.mem.eql(u8, text, "drop_cleanup")) {
            _ = self.advance();
            if (self.f_cur == null) return self.fail(t, "instruction appears after the block's terminator", .{});
            const v = try self.parseOperand();
            _ = try self.emit(t.span, .{ .drop_cleanup = v }, &.{});
            return;
        }
        if (std.mem.eql(u8, text, "store_member")) {
            _ = self.advance();
            if (self.f_cur == null) return self.fail(t, "instruction appears after the block's terminator", .{});
            if (!std.mem.eql(u8, self.f_name, "init")) {
                return self.fail(t, "store_member is only legal inside @init (ir.md §5.6)", .{});
            }
            const slot = try self.parseTagNumber();
            try self.expectComma();
            const v = try self.parseOperand();
            _ = try self.emit(t.span, .{ .store_member = .{ .slot = slot, .value = v } }, &.{});
            return;
        }
        if (std.mem.eql(u8, text, "syscall")) {
            _ = self.advance();
            if (self.f_cur == null) return self.fail(t, "instruction appears after the block's terminator", .{});
            var sc = try self.parseSyscall();
            sc.ret = .{ .primitive = .void };
            _ = try self.emit(t.span, .{ .syscall = sc }, &.{});
            return;
        }
        if (std.mem.eql(u8, text, "call")) {
            _ = self.advance();
            if (self.f_cur == null) return self.fail(t, "instruction appears after the block's terminator", .{});
            const c = try self.parseCall();
            _ = try self.emit(t.span, .{ .call = c }, &.{});
            return;
        }
        if (std.mem.eql(u8, text, "ret")) {
            _ = self.advance();
            var v: ?*Value = null;
            if (!self.at(.newline) and !self.at(.rbrace) and !self.at(.eof)) {
                v = try self.parseOperand();
            }
            try self.setTerminator(.{ .ret = v });
            return;
        }
        if (std.mem.eql(u8, text, "br")) {
            _ = self.advance();
            if (self.at(.value_ref)) {
                const cond = try self.parseOperand();
                try self.expect(.question, "'?'");
                const then_ = try self.expectLabel();
                try self.expect(.colon, "':'");
                const else_ = try self.expectLabel();
                try self.setTerminator(.{ .branch_cond = .{ .cond = cond, .then_ = then_, .else_ = else_ } });
            } else {
                const target = try self.expectLabel();
                try self.setTerminator(.{ .branch = target });
            }
            return;
        }
        if (std.mem.eql(u8, text, "switch")) {
            _ = self.advance();
            const disc = try self.parseOperand();
            try self.expect(.lbrace, "'{'");
            var arms = std.ArrayList(SwitchArm).empty;
            while (!self.at(.rbrace)) {
                const tag = try self.parseTagNumber();
                try self.expect(.arrow, "'->'");
                const b = try self.expectLabel();
                try arms.append(self.arena.allocator(), .{ .tag = tag, .block = b });
                if (!self.eat(.comma)) break;
            }
            try self.expect(.rbrace, "'}'");
            try self.setTerminator(.{ .@"switch" = .{ .disc = disc, .arms = try self.arena.allocator().dupe(SwitchArm, arms.items) } });
            return;
        }
        if (std.mem.eql(u8, text, "trap")) {
            _ = self.advance();
            try self.setTerminator(.trap);
            return;
        }
        if (std.mem.eql(u8, text, "tailcall")) {
            _ = self.advance();
            const ft = self.cur();
            if (ft.kind != .func_ref) return self.fail(ft, "expected a function reference for tailcall, found '{s}'", .{describe(ft)});
            _ = self.advance();
            const args = try self.parseCommaOperandList();
            try self.setTerminator(.{ .tailcall = .{ .name = ft.text, .func = null, .args = args } });
            return;
        }
        return self.fail(t, "expected an instruction or terminator, found identifier '{s}'", .{text});
    }

    fn setTerminator(self: *Parser, term: Terminator) ParseError!void {
        const cb = self.f_cur orelse return self.fail(self.cur(), "terminator appears after another terminator", .{});
        cb.terminator = term;
        self.f_cur = null;
    }

    /// The created state of a defined value (ir.md §6.1): from the op
    /// schema for static cases, or derived from the result for the
    /// `.operand` ops (projections — a Copy member read is a copy,
    /// an unique member read a borrowed view). Parameters are SSA roots
    /// (ir.md §5.1), so their state is not computed here.
    fn createdState(op: Op, result_type: Type) ValueState {
        return switch (cfg.opInfo(std.meta.activeTag(op)).created) {
            .owned => .owned,
            .borrowed => .borrowed,
            .none => .owned, // effects produce no value; unreachable here
            .operand => switch (op) {
                .read_field, .read_tuple, .read_index, .read_payload, .borrow_variant => readState(result_type),
                .tail => |v| readState(v.type_),
                else => unreachable,
            },
        };
    }

    fn readState(t: Type) ValueState {
        const ow = t.ownership();
        return if (ow == null or ow.? == .unique) .borrowed else .owned;
    }

    fn parseOpOperands(self: *Parser, name: OpName) ParseError!Op {
        switch (name) {
            .const_ => return .{ .const_ = try self.parseConst() },
            .module_ref => return .{ .module_ref = try self.expectString("module specifier") },
            .fn_ref => {
                const t = self.cur();
                if (t.kind != .func_ref) {
                    return self.fail(t, "expected a function reference '@name', found '{s}'", .{describe(t)});
                }
                _ = self.advance();
                return .{ .fn_ref = t.text };
            },
            .neg => return .{ .neg = try self.parseOperand() },
            .not_ => return .{ .not_ = try self.parseOperand() },
            .num_cast => return .{ .num_cast = try self.parseOperand() },
            .any_pack_copy => return .{ .any_pack_copy = try self.parseOperand() },
            .any_pack_move => return .{ .any_pack_move = try self.parseOperand() },
            .any_unpack_copy => return .{ .any_unpack_copy = try self.parseOperand() },
            .any_unpack_move => return .{ .any_unpack_move = try self.parseOperand() },
            .cleanup_owner => return .{ .cleanup_owner = try self.parseOperand() },
            .type_is => {
                const v = try self.parseOperand();
                try self.expectComma();
                const t = try self.parseType();
                return .{ .type_is = .{ .value = v, .type_ = t } };
            },
            .copy => return .{ .copy = try self.parseOperand() },
            .borrow => return .{ .borrow = try self.parseOperand() },
            .move_ => return .{ .move_ = try self.parseOperand() },
            .tail => return .{ .tail = try self.parseOperand() },
            .unpack_struct => return .{ .unpack_struct = try self.parseOperand() },
            .unpack_tuple => return .{ .unpack_tuple = try self.parseOperand() },
            .unpack_variant => {
                const base = try self.parseOperand();
                try self.expectComma();
                const tag = try self.parseTagNumber();
                return .{ .unpack_variant = .{ .base = base, .tag = tag } };
            },
            .split_list => return .{ .split_list = try self.parseOperand() },
            .read_tag => return .{ .read_tag = try self.parseOperand() },
            .read_payload => return .{ .read_payload = try self.parseOperand() },
            .borrow_variant => {
                const base = try self.parseOperand();
                try self.expectComma();
                const tag = try self.parseTagNumber();
                return .{ .borrow_variant = .{ .base = base, .tag = tag } };
            },
            .add => return .{ .add = try self.parseBin() },
            .sub => return .{ .sub = try self.parseBin() },
            .mul => return .{ .mul = try self.parseBin() },
            .div => return .{ .div = try self.parseBin() },
            .rem => return .{ .rem = try self.parseBin() },
            .concat => return .{ .concat = try self.parseBin() },
            .eq => return .{ .eq = try self.parseBin() },
            .ne => return .{ .ne = try self.parseBin() },
            .lt => return .{ .lt = try self.parseBin() },
            .le => return .{ .le = try self.parseBin() },
            .gt => return .{ .gt = try self.parseBin() },
            .ge => return .{ .ge = try self.parseBin() },
            .load_member => {
                const m = try self.parseOperand();
                try self.expectComma();
                const slot = try self.parseTagNumber();
                return .{ .load_member = .{ .module = m, .member = slot } };
            },
            .store_member => return self.fail(self.cur(), "'store_member' produces no value; write it as a bare statement", .{}),
            .construct => {
                var tag: ?u32 = null;
                if (self.at(.hash)) {
                    _ = self.advance();
                    tag = try self.parseTagValue();
                }
                var args = std.ArrayList(*Value).empty;
                while (true) {
                    if (self.at(.newline) or self.at(.rbrace) or self.at(.eof)) break;
                    try args.append(self.arena.allocator(), try self.parseOperand());
                    if (!self.eat(.comma)) break;
                }
                return .{ .construct = .{ .tag = tag, .args = try self.arena.allocator().dupe(*Value, args.items) } };
            },
            .read_field => return .{ .read_field = try self.parseProj() },
            .read_tuple => return .{ .read_tuple = try self.parseProj() },
            .read_index => return .{ .read_index = try self.parseIndex() },
            .call => return .{ .call = try self.parseCall() },
            .syscall => return .{ .syscall = try self.parseSyscall() },
            .phi => return .{ .phi = try self.parsePhi() },
        }
    }

    fn parseBin(self: *Parser) ParseError!Bin {
        const a = try self.parseOperand();
        try self.expectComma();
        const b = try self.parseOperand();
        return .{ .a = a, .b = b };
    }

    fn parseProj(self: *Parser) ParseError!Proj {
        const base = try self.parseOperand();
        try self.expectComma();
        const idx = try self.parseTagNumber();
        return .{ .base = base, .index = idx };
    }

    fn parseIndex(self: *Parser) ParseError!Index {
        const base = try self.parseOperand();
        try self.expectComma();
        const idx = try self.parseOperand();
        return .{ .base = base, .index = idx };
    }

    fn parseCall(self: *Parser) ParseError!Call {
        const t = self.cur();
        var callee: Callee = undefined;
        switch (t.kind) {
            .func_ref => {
                _ = self.advance();
                callee = .{ .direct = .{ .name = t.text } };
            },
            .value_ref => {
                _ = self.advance();
                callee = .{ .value = try self.resolveValueRef(t, false) };
            },
            else => return self.fail(t, "expected a function reference or function value, found '{s}'", .{describe(t)}),
        }
        const args = try self.parseCommaOperandList();
        return .{ .callee = callee, .args = args };
    }

    fn parseSyscall(self: *Parser) ParseError!SysCall {
        const mod_tok = self.cur();
        if (mod_tok.kind != .ident) {
            return self.fail(mod_tok, "expected a module name, found '{s}'", .{describe(mod_tok)});
        }
        _ = self.advance();
        try self.expect(.hash, "'#'");
        const member_tok = self.cur();
        if (member_tok.kind != .ident) {
            return self.fail(member_tok, "expected a member name after '#', found '{s}'", .{describe(member_tok)});
        }
        _ = self.advance();
        var target: SysCallTarget = undefined;
        if (std.mem.eql(u8, mod_tok.text, "builtin")) {
            const id = std.meta.stringToEnum(BuiltinId, member_tok.text) orelse
                return self.fail(member_tok, "unknown builtin member '{s}'", .{member_tok.text});
            target = .{ .builtin = id };
        } else {
            target = .{ .host_module = .{ .module = mod_tok.text, .member = member_tok.text } };
        }
        return .{
            .span = ast.Span.merge(mod_tok.span, member_tok.span),
            .target = target,
            .args = try self.parseCommaOperandList(),
            .ret = undefined,
        };
    }

    fn parsePhi(self: *Parser) ParseError!Phi {
        var incoming = std.ArrayList(PhiIn).empty;
        while (true) {
            try self.expect(.lbracket, "'['");
            // Phi operands may name values defined later in the text (a
            // loop back edge); resolve against the pre-registered names.
            const v = try self.parsePhiOperand();
            try self.expect(.comma, "','");
            const pred = try self.expectLabel();
            try self.expect(.rbracket, "']'");
            try incoming.append(self.arena.allocator(), .{ .value = v, .pred = pred });
            if (!self.eat(.comma)) break;
        }
        return .{ .incoming = try self.arena.allocator().dupe(PhiIn, incoming.items) };
    }

    fn parsePhiOperand(self: *Parser) ParseError!*Value {
        const t = self.cur();
        switch (t.kind) {
            .value_ref => {
                _ = self.advance();
                return self.resolveValueRef(t, true);
            },
            else => return self.fail(t, "expected an operand, found '{s}'", .{describe(t)}),
        }
    }

    /// Comma-separated operands with no leading comma (`construct`).
    fn parseOperandList(self: *Parser) ParseError![]*Value {
        var args = std.ArrayList(*Value).empty;
        while (true) {
            if (self.at(.newline) or self.at(.rbrace) or self.at(.eof)) break;
            try args.append(self.arena.allocator(), try self.parseOperand());
            if (!self.eat(.comma)) break;
        }
        return self.arena.allocator().dupe(*Value, args.items);
    }

    /// Comma-separated operands after a leading comma, as written after a
    /// `call` callee or `syscall` target (`call @f, %a, %b`).
    fn parseCommaOperandList(self: *Parser) ParseError![]*Value {
        _ = self.eat(.comma);
        return self.parseOperandList();
    }

    fn expectComma(self: *Parser) ParseError!void {
        _ = try self.expect(.comma, "','");
    }

    fn expectLabel(self: *Parser) ParseError!*BasicBlock {
        const t = self.cur();
        if (t.kind != .ident) {
            return self.fail(t, "expected a block label, found '{s}'", .{describe(t)});
        }
        _ = self.advance();
        const idx = self.f_block_names.get(t.text) orelse
            return self.fail(t, "undefined block label '{s}'", .{t.text});
        return self.f_blocks.items[idx];
    }

    fn expectString(self: *Parser, what: []const u8) ParseError![]const u8 {
        const t = self.cur();
        if (t.kind != .string) {
            return self.fail(t, "expected {s} (a string), found '{s}'", .{ what, describe(t) });
        }
        _ = self.advance();
        // String tokens are lex-arena-owned (freed with the lexer); dupe
        // into the parser arena so the program outlives the token stream.
        return self.arena.allocator().dupe(u8, t.text) catch unreachable;
    }

    /// `#N` — a statically known index or union tag.
    fn parseTagNumber(self: *Parser) ParseError!u32 {
        try self.expect(.hash, "'#'");
        return self.parseTagValue();
    }

    fn parseTagValue(self: *Parser) ParseError!u32 {
        const t = self.cur();
        if (t.kind != .number) {
            return self.fail(t, "expected an index after '#', found '{s}'", .{describe(t)});
        }
        _ = self.advance();
        return std.fmt.parseInt(u32, t.text, 10) catch
            return self.fail(t, "invalid index '{s}'", .{t.text});
    }

    /// An operand: a value reference, or an inline constant literal that
    /// is materialized as a `const` instruction in the current block.
    fn parseOperand(self: *Parser) ParseError!*Value {
        const t = self.cur();
        switch (t.kind) {
            .value_ref => {
                _ = self.advance();
                return self.resolveValueRef(t, false);
            },
            .number => {
                _ = self.advance();
                return self.synthConstNumber(t);
            },
            .string => {
                _ = self.advance();
                return self.synthConstString(t);
            },
            .ident => {
                if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false")) {
                    _ = self.advance();
                    return self.synthConstBool(t);
                }
                return self.fail(t, "expected an operand, found identifier '{s}'", .{t.text});
            },
            else => return self.fail(t, "expected an operand, found '{s}'", .{describe(t)}),
        }
    }

    fn resolveValueRef(self: *Parser, t: Token, allow_forward: bool) ParseError!*Value {
        const text = t.text;
        var v: *Value = undefined;
        if (isAllDigits(text)) {
            const id = std.fmt.parseInt(u32, text, 10) catch
                return self.fail(t, "invalid value id '%{s}'", .{text});
            if (id >= self.f_values.items.len) {
                return self.fail(t, "undefined value %{d}", .{id});
            }
            v = self.f_values.items[id];
        } else {
            v = self.f_symbols.get(text) orelse
                return self.fail(t, "undefined value '%{s}'", .{text});
        }
        // Placeholders are filled at their definition; a non-phi use of an
        // unfilled placeholder is a forward reference outside SSA rules.
        if (!allow_forward and v.id >= self.f_params.len and v.def == null) {
            return self.fail(t, "value '%{s}' is not yet defined", .{text});
        }
        return v;
    }

    fn isAllDigits(text: []const u8) bool {
        for (text) |c| if (!std.ascii.isDigit(c)) return false;
        return text.len > 0;
    }

    // -----------------------------------------------------------------
    // Value and instruction construction
    // -----------------------------------------------------------------

    fn newValue(self: *Parser, span: ast.Span, type_: Type, state: ValueState) ParseError!*Value {
        const v = try self.arena.allocator().create(Value);
        v.* = .{
            .id = @intCast(self.f_values.items.len),
            .span = span,
            .type_ = type_,
            .ownership = type_.ownership(),
            .state = state,
            .origin = null,
            .def = null,
        };
        try self.f_values.append(self.arena.allocator(), v);
        return v;
    }

    fn emit(self: *Parser, span: ast.Span, op: Op, results: []*Value) ParseError!*Instr {
        const blk = self.f_cur orelse unreachable;
        const instr = try self.arena.allocator().create(Instr);
        instr.* = .{ .span = span, .results = results, .op = op };
        try self.f_block_instrs.items[blk.id].append(self.arena.allocator(), instr);
        for (results) |v| v.def = instr;
        return instr;
    }

    fn synthConstNumber(self: *Parser, t: Token) ParseError!*Value {
        const is_float = std.mem.indexOfScalar(u8, t.text, '.') != null;
        var type_: Type = undefined;
        var c: ConstValue = undefined;
        if (is_float) {
            type_ = .{ .primitive = .float32 };
            c = .{ .float = std.fmt.parseFloat(f32, t.text) catch
                return self.fail(t, "invalid float literal '{s}'", .{t.text}) };
        } else {
            type_ = .{ .primitive = .int32 };
            c = .{ .int = std.fmt.parseInt(i64, t.text, 10) catch
                return self.fail(t, "invalid integer literal '{s}'", .{t.text}) };
        }
        const v = try self.newValue(t.span, type_, .owned);
        var one = [_]*Value{v};
        const instr = try self.emit(t.span, .{ .const_ = c }, &one);
        instr.synth = true;
        return v;
    }

    fn synthConstString(self: *Parser, t: Token) ParseError!*Value {
        const v = try self.newValue(t.span, .{ .primitive = .str }, .owned);
        var one = [_]*Value{v};
        const s = self.arena.allocator().dupe(u8, t.text) catch unreachable;
        const instr = try self.emit(t.span, .{ .const_ = .{ .string = s } }, &one);
        instr.synth = true;
        return v;
    }

    fn synthConstBool(self: *Parser, t: Token) ParseError!*Value {
        const v = try self.newValue(t.span, .{ .primitive = .bool }, .owned);
        var one = [_]*Value{v};
        const instr = try self.emit(t.span, .{ .const_ = .{ .bool = std.mem.eql(u8, t.text, "true") } }, &one);
        instr.synth = true;
        return v;
    }

    fn parseConst(self: *Parser) ParseError!ConstValue {
        const t = self.cur();
        switch (t.kind) {
            .number => {
                _ = self.advance();
                if (std.mem.indexOfScalar(u8, t.text, '.') != null) {
                    return .{ .float = std.fmt.parseFloat(f32, t.text) catch
                        return self.fail(t, "invalid float literal '{s}'", .{t.text}) };
                }
                return .{ .int = std.fmt.parseInt(i64, t.text, 10) catch
                    return self.fail(t, "invalid integer literal '{s}'", .{t.text}) };
            },
            .string => {
                _ = self.advance();
                // Dupe into the parser arena: the token buffer is transient
                // (freed after parse), but the program keeps its literals.
                const s = try self.arena.allocator().dupe(u8, t.text);
                return .{ .string = s };
            },
            .ident => {
                if (std.mem.eql(u8, t.text, "true")) {
                    _ = self.advance();
                    return .{ .bool = true };
                }
                if (std.mem.eql(u8, t.text, "false")) {
                    _ = self.advance();
                    return .{ .bool = false };
                }
                if (std.mem.eql(u8, t.text, "void")) {
                    _ = self.advance();
                    return .void;
                }
                return self.fail(t, "expected a constant, found identifier '{s}'", .{t.text});
            },
            else => return self.fail(t, "expected a constant, found '{s}'", .{describe(t)}),
        }
    }

    // -----------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------

    fn allocType(self: *Parser, t: Type) ParseError!*Type {
        const p = try self.arena.allocator().create(Type);
        p.* = t;
        return p;
    }

    /// Intern a named struct/union from IR text: returns its stable `TypeId`,
    /// recording the written name on first sight (ir.md §11; the text form
    /// carries no fields/ownership, so the entry is name-only and prints
    /// back identically).
    fn internTypeName(self: *Parser, text: []const u8) TypeId {
        if (self.type_ids.get(text)) |id| return id;
        const id: TypeId = @intCast(self.types.items.len);
        self.type_ids.put(text, id) catch return 0;
        self.types.append(self.arena.allocator(), text) catch return 0;
        return id;
    }

    fn parseType(self: *Parser) ParseError!Type {
        const t = self.cur();
        if (t.kind != .ident) {
            return self.fail(t, "expected a type, found '{s}'", .{describe(t)});
        }
        _ = self.advance();
        const text = t.text;
        if (std.mem.eql(u8, text, "module")) return .module;
        if (std.mem.eql(u8, text, "cleanup")) return .cleanup;
        if (primitive_names.get(text)) |k| return .{ .primitive = k };
        if (std.mem.eql(u8, text, "list")) {
            try self.expect(.lbracket, "'['");
            const inner = try self.allocType(try self.parseType());
            try self.expect(.rbracket, "']'");
            return .{ .list = inner };
        }
        if (std.mem.eql(u8, text, "box")) {
            try self.expect(.lbracket, "'['");
            const inner = try self.allocType(try self.parseType());
            try self.expect(.rbracket, "']'");
            return .{ .box = inner };
        }
        if (std.mem.eql(u8, text, "tuple")) {
            try self.expect(.lbracket, "'['");
            var elems = std.ArrayList(Type).empty;
            while (!self.at(.rbracket)) {
                try elems.append(self.arena.allocator(), try self.parseType());
                if (!self.eat(.comma)) break;
            }
            try self.expect(.rbracket, "']'");
            return .{ .tuple = try self.arena.allocator().dupe(Type, elems.items) };
        }
        if (std.mem.eql(u8, text, "fn")) {
            try self.expect(.lparen, "'('");
            var params = std.ArrayList(Param).empty;
            while (!self.at(.rparen)) {
                const pspan = self.cur().span;
                var mode: ast.ParamMode = .plain;
                if (self.at(.ident)) {
                    const it = self.cur();
                    if (std.mem.eql(u8, it.text, "borrow")) {
                        mode = .borrow;
                        _ = self.advance();
                    } else if (std.mem.eql(u8, it.text, "move")) {
                        mode = .move;
                        _ = self.advance();
                    }
                }
                const ptype = try self.parseType();
                try params.append(self.arena.allocator(), .{
                    .span = pspan,
                    .name = .{ .span = pspan, .text = "" },
                    .mode = mode,
                    .type_ = ptype,
                });
                if (!self.eat(.comma)) break;
            }
            try self.expect(.rparen, "')'");
            try self.expect(.arrow, "'->'");
            const ret = try self.allocType(try self.parseType());
            return .{ .function = .{
                .params = try self.arena.allocator().dupe(Param, params.items),
                .ret = ret,
            } };
        }
        // Any other identifier (possibly dotted) is a named struct/union
        // reference; ownership defers to its declaration. The text form
        // carries no decls, so intern the name and record it so
        // `types[id]` round-trips (ir.md §11). A trailing `[...]` is the
        // instantiation's type arguments (`Option[int32]`).
        var args: []Type = &.{};
        if (self.at(.lbracket)) {
            var arg_list = std.ArrayList(Type).empty;
            try self.expect(.lbracket, "'['");
            while (!self.at(.rbracket)) {
                try arg_list.append(self.arena.allocator(), try self.parseType());
                if (!self.eat(.comma)) break;
            }
            try self.expect(.rbracket, "]'");
            args = try self.arena.allocator().dupe(Type, arg_list.items);
        }
        return .{ .named = .{ .id = self.internTypeName(text), .args = args } };
    }
};
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Parse one IR text program for tests. `pub` because the printer's
/// round-trip white-box tests (`src/passes/cfg_print.zig`) parse what
/// they print.
pub fn parseText(text: []const u8) !struct { arena: std.heap.ArenaAllocator, program: IrProgram } {
    // One arena owns the parser memory (including the interned types and
    // type_ids); the caller frees it via arena.deinit. The Parser is not
    // deinit-ed here so its arena is handed back to the caller, exactly
    // as the program it produced.
    var p = Parser.init(std.testing.allocator);
    errdefer p.deinit();
    const program = try p.parse(text);
    // Release the transient token buffer; literals were duped into the
    // parser arena, and identifiers point back into the source `text`.
    p.lex.deinit();
    return .{ .arena = p.arena, .program = program };
}

test "cfg parses a straight-line function" {
    var t = try parseText(
        \\module "test" {
        \\func @add(a: int32, b: int32) -> int32 {
        \\entry:
        \\    %r: int32 = add %a, %b
        \\    ret %r
        \\}
        \\}
    );
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 1), t.program.funcs.len);
    const f = t.program.funcs[0];
    try std.testing.expectEqualStrings("add", f.name.text);
    try std.testing.expectEqual(@as(usize, 2), f.params.len);
    try std.testing.expectEqual(@as(usize, 1), f.blocks.len);
    try std.testing.expectEqualStrings("entry", f.entry.name);

    const bin = switch (f.blocks[0].instrs[0].op) {
        .add => |b| b,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(u32, 2), f.blocks[0].instrs[0].results[0].id);
    try std.testing.expect(bin.a == f.values[0]);
    try std.testing.expect(bin.b == f.values[1]);
    const ret = switch (f.blocks[0].terminator) {
        .ret => |r| r,
        else => unreachable,
    };
    try std.testing.expect(ret.? == f.blocks[0].instrs[0].results[0]);
}
test "cfg parses a conditional branch with a phi join" {
    var t = try parseText(
        \\module "test" {
        \\func @sign(value: int32) -> int32 {
        \\entry:
        \\    %z: int32 = const 0
        \\    %c: bool = ge %value, %z
        \\    br %c ? pos : neg
        \\pos:
        \\    %one: int32 = const 1
        \\    br join
        \\neg:
        \\    %mone: int32 = const -1
        \\    br join
        \\join:
        \\    %sign: int32 = phi [%one, pos], [%mone, neg]
        \\    ret %sign
        \\}
        \\}
    );
    defer t.arena.deinit();

    const f = t.program.funcs[0];
    try std.testing.expectEqual(@as(usize, 4), f.blocks.len);

    // Entry: conditional branch to pos/neg; no predecessors.
    const bc = switch (f.entry.terminator) {
        .branch_cond => |b| b,
        else => unreachable,
    };
    try std.testing.expectEqualStrings("pos", bc.then_.name);
    try std.testing.expectEqualStrings("neg", bc.else_.name);
    try std.testing.expectEqual(@as(usize, 0), f.entry.preds.len);

    // Join: phi incoming order matches the predecessor order.
    const join = f.blocks[3];
    try std.testing.expectEqualStrings("join", join.name);
    try std.testing.expectEqual(@as(usize, 2), join.preds.len);
    const phi = switch (join.instrs[0].op) {
        .phi => |p| p,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(usize, 2), phi.incoming.len);
    try std.testing.expect(phi.incoming[0].pred == join.preds[0]);
    try std.testing.expect(phi.incoming[1].pred == join.preds[1]);
    try std.testing.expectEqualStrings("pos", phi.incoming[0].pred.name);
    try std.testing.expectEqualStrings("neg", phi.incoming[1].pred.name);
    const ret = switch (join.terminator) {
        .ret => |r| r,
        else => unreachable,
    };
    try std.testing.expect(ret.? == join.instrs[0].results[0]);
}
test "cfg parses a loop header phi with a back edge" {
    var t = try parseText(
        \\module "test" {
        \\func @dump(values: list[str]) -> void {
        \\entry:
        \\    %n: int32 = syscall builtin#len, %values
        \\    %z: int32 = const 0
        \\    br header
        \\header:
        \\    %i: int32 = phi [%z, entry], [%i2, body]
        \\    %done: bool = ge %i, %n
        \\    br %done ? exit : body
        \\body:
        \\    %item: str = read_index %values, %i
        \\    syscall builtin#print, %item
        \\    %one: int32 = const 1
        \\    %i2: int32 = add %i, %one
        \\    br header
        \\exit:
        \\    ret
        \\}
        \\}
    );
    defer t.arena.deinit();

    const f = t.program.funcs[0];
    try std.testing.expectEqual(@as(usize, 4), f.blocks.len);

    const sc = switch (f.entry.instrs[0].op) {
        .syscall => |s| s,
        else => unreachable,
    };
    try std.testing.expectEqual(BuiltinId.len, sc.target.builtin);

    const header = f.blocks[1];
    const phi = switch (header.instrs[0].op) {
        .phi => |p| p,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(usize, 2), phi.incoming.len);
    try std.testing.expectEqualStrings("entry", phi.incoming[0].pred.name);
    try std.testing.expectEqualStrings("body", phi.incoming[1].pred.name);

    // The body's back edge targets the header.
    const body = f.blocks[2];
    const be = switch (body.terminator) {
        .branch => |b| b,
        else => unreachable,
    };
    try std.testing.expect(be == header);
    try std.testing.expectEqual(@as(usize, 2), header.preds.len);
}
test "cfg resolves direct calls and builtin syscalls" {
    var t = try parseText(
        \\module "test" {
        \\func @inspect(borrow file: File) -> void {
        \\entry:
        \\    ret
        \\}
        \\func @main() -> void {
        \\entry:
        \\    %a: File = syscall os#open_file, "a.txt"
        \\    call @inspect, %a
        \\    %n: int32 = syscall builtin#len, %a
        \\    ret
        \\}
        \\}
    );
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.program.funcs.len);
    const inspect = t.program.funcs[0];
    const main = t.program.funcs[1];

    // Borrow-mode parameter arrives borrowed; its type is a named File.
    try std.testing.expectEqual(ast.ParamMode.borrow, inspect.params[0].mode);
    try std.testing.expectEqual(ValueState.borrowed, inspect.values[0].state);
    try std.testing.expect(inspect.values[0].ownership == null); // deferred

    // instrs: [0] synth const "a.txt", [1] syscall, [2] call, [3] syscall.
    // Direct call resolved to the actual IrFunc.
    const call_instr = main.blocks[0].instrs[2];
    const direct = switch (switch (call_instr.op) {
        .call => |c| c.callee,
        else => unreachable,
    }) {
        .direct => |d| d,
        else => unreachable,
    };
    try std.testing.expect(direct.func.? == inspect);

    // Inline string operand was materialized as a synthesized const.
    const first = main.blocks[0].instrs[0];
    try std.testing.expect(first.synth);
    const arg = switch (first.op) {
        .const_ => |c| c.string,
        else => unreachable,
    };
    try std.testing.expectEqualStrings("a.txt", arg);
}
test "cfg derives module storage slots from @init" {
    var t = try parseText(
        \\module "app" {
        \\    func @init() -> void {
        \\    entry:
        \\        %g: str = const "hello"
        \\        store_member #0, %g
        \\        %c: module = module_ref "calc"
        \\        store_member #1, %c
        \\        ret
        \\    }
        \\    func @add(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %r: int32 = add %a, %b
        \\        ret %r
        \\    }
        \\}
    );
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 1), t.program.modules.len);
    const m = t.program.modules[0];
    try std.testing.expectEqualStrings("app", m.name);
    try std.testing.expectEqualStrings("init", m.init.?.name.text);
    try std.testing.expectEqual(@as(usize, 2), m.slots.len);
    try std.testing.expect(Type.eql(.{ .primitive = .str }, m.slots[0].type_));
    try std.testing.expect(Type.eql(.module, m.slots[1].type_));
    try std.testing.expectEqual(@as(u32, 0), m.slots[0].init_order);
    try std.testing.expectEqual(@as(u32, 1), m.slots[1].init_order);
}
test "cfg parses constructs, projections, and a switch" {
    var t = try parseText(
        \\module "use" {
        \\    func @msg(result: Result) -> str {
        \\    entry:
        \\        %tag: u32 = read_tag %result
        \\        switch %tag { #0 -> arm_ok, #1 -> arm_err }
        \\    arm_ok:
        \\        %v: str = read_payload %result
        \\        %r1: str = construct %v
        \\        br join
        \\    arm_err:
        \\        %e: str = read_payload %result
        \\        %r2: str = concat %e, %e
        \\        br join
        \\    join:
        \\        %m: str = phi [%r1, arm_ok], [%r2, arm_err]
        \\        ret %m
        \\    }
        \\}
    );
    defer t.arena.deinit();

    const f = t.program.funcs[0];
    const sw = switch (f.entry.terminator) {
        .@"switch" => |s| s,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(usize, 2), sw.arms.len);
    try std.testing.expectEqual(@as(u32, 0), sw.arms[0].tag);
    try std.testing.expectEqualStrings("arm_ok", sw.arms[0].block.name);
    try std.testing.expectEqualStrings("arm_err", sw.arms[1].block.name);

    const cons = switch (f.blocks[1].instrs[1].op) {
        .construct => |c| c,
        else => unreachable,
    };
    try std.testing.expect(cons.tag == null);
    try std.testing.expectEqual(@as(usize, 1), cons.args.len);
}
test "cfg parses type_is tests and hostdata primitives" {
    // `type_is` tests an `any` value's runtime tag against a concrete type
    // (Core §11.6.2); `hostdata` is a primitive type in the IR text
    // (Core §11.7).
    var t = try parseText(
        \\module "app" {
        \\func @use(a: any, h: hostdata) -> bool {
        \\entry:
        \\    %t: bool = type_is %a, list[int32]
        \\    br %t ? arm : done
        \\arm:
        \\    %p: list[int32] = any_unpack_copy %a
        \\    %u: bool = type_is %a, str
        \\    ret %u
        \\done:
        \\    %f: bool = const false
        \\    ret %f
        \\}
        \\}
    );
    defer t.arena.deinit();

    const f = t.program.funcs[0];
    try std.testing.expectEqual(@as(usize, 2), f.params.len);
    try std.testing.expectEqual(ast.PrimitiveKind.any, f.params[0].type_.primitive);
    try std.testing.expectEqual(ast.PrimitiveKind.hostdata, f.params[1].type_.primitive);
    const ti = switch (f.blocks[0].instrs[0].op) {
        .type_is => |ti| ti,
        else => unreachable,
    };
    try std.testing.expect(ti.value == f.values[0]);
    try std.testing.expectEqual(ast.PrimitiveKind.int32, ti.type_.list.primitive);
    const c = switch (f.blocks[1].instrs[0].op) {
        .any_unpack_copy => |c| c,
        else => unreachable,
    };
    try std.testing.expect(c == f.values[0]);
}
test "cfg reports undefined values" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const res = p.parse(
        \\module "test" {
        \\func @f() -> void {
        \\entry:
        \\    %r: int32 = add %x, %y
        \\    ret
        \\}
        \\}
    );
    try std.testing.expectError(error.Syntax, res);
    try std.testing.expect(p.diag != null);
    try std.testing.expect(std.mem.indexOf(u8, p.diag.?.message, "undefined value") != null);
}
test "cfg rejects a block without a terminator" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const res = p.parse(
        \\module "test" {
        \\func @f() -> void {
        \\entry:
        \\    %z: int32 = const 0
        \\}
        \\}
    );
    try std.testing.expectError(error.Syntax, res);
    try std.testing.expect(std.mem.indexOf(u8, p.diag.?.message, "missing a terminator") != null);
}
test "cfg rejects a phi whose incoming order mismatches predecessors" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const res = p.parse(
        \\module "test" {
        \\func @f() -> int32 {
        \\entry:
        \\    %a: int32 = const 1
        \\    br %a ? l : r
        \\l:
        \\    %b: int32 = const 2
        \\    br join
        \\r:
        \\    %c: int32 = const 3
        \\    br join
        \\join:
        \\    %m: int32 = phi [%b, r], [%c, l]
        \\    ret %m
        \\}
        \\}
    );
    try std.testing.expectError(error.Syntax, res);
    try std.testing.expect(std.mem.indexOf(u8, p.diag.?.message, "does not match predecessors") != null);
}
test "cfg rejects store_member outside @init" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const res = p.parse(
        \\module "test" {
        \\func @f() -> void {
        \\entry:
        \\    %z: int32 = const 0
        \\    store_member #0, %z
        \\    ret
        \\}
        \\}
    );
    try std.testing.expectError(error.Syntax, res);
    try std.testing.expect(std.mem.indexOf(u8, p.diag.?.message, "only legal inside @init") != null);
}
test "cfg parses copy, borrow, move, and drop ownership ops" {
    var t = try parseText(
        \\module "m" {
        \\    func @init() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @m.f(x: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = copy %0
        \\        %2: int32 = borrow %1
        \\        %3: int32 = move %1
        \\        drop %1
        \\        ret %3
        \\    }
        \\}
    );
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.program.funcs.len);
    const f = t.program.funcs[1];
    try std.testing.expectEqual(@as(usize, 1), f.blocks.len);
    const b = f.blocks[0];
    // copy, borrow, move are defining ops; drop is an effect (no result).
    try std.testing.expectEqual(@as(usize, 4), b.instrs.len);
    try std.testing.expect(b.instrs[0].op == .copy);
    try std.testing.expect(b.instrs[1].op == .borrow);
    try std.testing.expect(b.instrs[2].op == .move_);
    try std.testing.expect(b.instrs[3].op == .drop_);
    try std.testing.expect(b.instrs[3].results.len == 0);
}
test "cfg parses module_ref and member loads" {
    var t = try parseText(
        \\module "builtin" {
        \\}
        \\module "app" {
        \\    func @init() -> void {
        \\    entry:
        \\        %0: module = module_ref "builtin"
        \\        store_member #1, %0
        \\        ret
        \\    }
        \\    func @app.main() -> void {
        \\    entry:
        \\        %0: module = module_ref "app"
        \\        %1: fn (int32) -> int32 = load_member %0, #0
        \\        ret
        \\    }
        \\}
    );
    defer t.arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), t.program.modules.len);
    const init = t.program.funcs[0];
    try std.testing.expect(init.blocks[0].instrs[0].op == .module_ref);
    try std.testing.expect(init.blocks[0].instrs[1].op == .store_member);
}
test "cfg parses an undefined-value report" {
    var t = try parseText(
        \\module "m" {
        \\    func @init() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @m.f() -> void {
        \\    entry:
        \\        %0: void = const void
        \\        ret %0
        \\    }
        \\}
    );
    defer t.arena.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.program.funcs.len);
}
test "cfg rejects an unknown opcode" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const text =
        \\module "m" {
        \\    func @m.f() -> void {
        \\    entry:
        \\        %0: int32 = frobnicate
        \\        ret
        \\    }
        \\}
    ;
    const result = p.parse(text);
    try std.testing.expectError(error.Syntax, result);
}
test "cfg rejects an undefined operand" {
    // Values must be defined before use; %9 is never defined.
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const text =
        \\module "m" {
        \\    func @m.f() -> void {
        \\    entry:
        \\        %9: int32 = copy %1
        \\        ret
        \\    }
        \\}
    ;
    const result = p.parse(text);
    try std.testing.expectError(error.Syntax, result);
}
test "cfg rejects a missing func terminator" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const text =
        \\module "m" {
        \\    func @m.f() -> void {
        \\    entry:
        \\        %0: int32 = const 1
        \\}
    ;
    const result = p.parse(text);
    try std.testing.expectError(error.Syntax, result);
}
