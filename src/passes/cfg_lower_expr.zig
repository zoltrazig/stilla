//! Pass: expression lowering — literals, constructs, unary/binary
//! operators, casts, and moves (`expression`, Core §6, §8, §11). In:
//! Lowerer + FuncState + ast.Expr / ast.Call, module graph. Out: the CFG
//! value of the expression, with affine temporaries dropped at the
//! full-expression boundary (ir.md §6.4).

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const lower = @import("../lower.zig");
const cfg_lower_call = @import("cfg_lower_call.zig");
const cfg_lower_control = @import("cfg_lower_control.zig");
const cfg_lower_func = @import("cfg_lower_func.zig");
const cfg_lower_path = @import("cfg_lower_path.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_validate = @import("cfg_lower_validate.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// Lower one expression, dropping its affine temporaries at the end
/// (full-expression boundary, Runtime §6.4). Returns null when the
/// expression terminated the block (never / trap).
pub fn lowerExpr(self: *Lowerer, fs: *FuncState, e: *const ast.Expr) LowerError!?*cfg.Value {
    if (fs.cur == null) return null;
    const start = fs.created.items.len;
    const result = try lowerExprInner(self, fs, e);
    try cfg_lower_emit.dropCreatedRange(self, fs, start, result);
    return result;
}

pub fn lowerExprInner(self: *Lowerer, fs: *FuncState, e: *const ast.Expr) LowerError!?*cfg.Value {
    return switch (e.*) {
        .int => |lit| try emitConst(self, fs, lit.span, .{ .int = @intCast(lit.value) }, .{ .primitive = .int32 }),
        .float => |lit| try emitConst(self, fs, lit.span, .{ .float = @floatCast(lit.value) }, .{ .primitive = .float32 }),
        .string => |lit| try emitConst(self, fs, lit.span, .{ .string = lit.value }, .{ .primitive = .str }),
        .bool => |lit| try emitConst(self, fs, lit.span, .{ .bool = lit.value }, .{ .primitive = .bool }),
        .void => |lit| try emitVoid(self, fs, lit.span),
        .path => |p| try cfg_lower_path.lowerPath(self, fs, &p),
        .paren => |p| try lowerExpr(self, fs, p.inner),
        .tuple => |t| try lowerTuple(self, fs, &t),
        .list => |l| try lowerList(self, fs, &l),
        .lambda => |lam| try lowerLambda(self, fs, &lam),
        .if_ => |i| try cfg_lower_control.lowerIf(self, fs, &i),
        .match => |m| try cfg_lower_control.lowerMatch(self, fs, &m),
        .import => |imp| self.fail(imp.span, "import(...) is only valid as a module constant initializer", .{}),
        .block => |b| try cfg_lower_func.lowerBlock(self, fs, b.block),
        .unary => |u| try lowerUnary(self, fs, &u),
        .binary => |b| try lowerBinary(self, fs, &b),
        .move => |m| try lowerMove(self, fs, &m),
        .cast => |c| try lowerCast(self, fs, &c),
        .member => |m| try cfg_lower_path.lowerMember(self, fs, &m),
        .index => |ix| try cfg_lower_path.lowerIndex(self, fs, &ix),
        .call => |c| try cfg_lower_call.lowerCall(self, fs, &c),
        .specialize => |s| self.fail(s.span, "an unspecialized generic cannot be used as a value (Core §12.4)", .{}),
    };
}

pub fn emitConst(self: *Lowerer, fs: *FuncState, span: ast.Span, value: cfg.ConstValue, type_: cfg.Type) LowerError!?*cfg.Value {
    return cfg_lower_emit.emit(self, fs, span, .{ .const_ = value }, type_);
}

/// A `void`-typed expression result. `void` is a singleton type with no
/// observable value (frontend.md §5.3, Pass 4.1): a void return is a bare
/// `ret`, a void join produces no phi, and the checker rejects void in
/// every typed operand position, so a void *value* is never an
/// instruction operand. The result is therefore a phantom — a value with
/// no defining instruction and no value-table entry — and the lowerer
/// emits no `const void` op for it. `emitDrop`/`exitScope`/`discardValue`
/// treat it as duplicable and skip it, so nothing downstream dereferences
/// the missing definition.
pub fn emitVoid(self: *Lowerer, fs: *FuncState, span: ast.Span) LowerError!?*cfg.Value {
    _ = fs;
    const v = try self.arena.create(cfg.Value);
    v.* = .{
        // maxInt: a phantom id is never printed or used as an operand; if
        // one ever leaked into the text form, the giant id would be
        // obviously broken rather than silently mis-numbered.
        .id = std.math.maxInt(u32),
        .span = span,
        .type_ = .{ .primitive = .void },
        .ownership = .duplicable,
        .state = .owned,
        .def = null,
    };
    return v;
}

/// Struct literal: fields are evaluated in *written* order
/// (Runtime §5) but the `construct` carries them in declaration order
/// (Core §8.1, ir.md §5.3).
pub fn lowerStructConstruct(self: *Lowerer, fs: *FuncState, p: *const ast.PathExpr, sc: *const ast.StructConstruct) LowerError!?*cfg.Value {
    const name = try cfg_lower_path.joinPath(self, p.path);
    const sd = moduleinfo.structDecl(self.resolve, fs.module, name) orelse
        return self.fail(p.span, "unknown struct type '{s}'", .{name});
    const args = try self.arena.alloc(*cfg.Value, sd.fields.len);
    @memset(args, undefined);
    var seen = try self.arena.alloc(bool, sd.fields.len);
    @memset(seen, false);
    for (sc.fields) |*f| {
        const idx = moduleinfo.fieldIndex(sd, f.name.text) orelse
            return self.fail(f.name.span, "struct '{s}' has no field '{s}'", .{ name, f.name.text });
        if (seen[idx]) return self.fail(f.name.span, "duplicate field '{s}'", .{f.name.text});
        seen[idx] = true;
        const v = (try lowerExpr(self, fs, f.value)) orelse return null;
        args[idx] = v;
    }
    for (sd.fields, 0..) |f, i| {
        if (!seen[i]) return self.fail(p.span, "missing field '{s}' in '{s}'", .{ f.name.text, name });
    }
    const result = try cfg_lower_emit.emit(self, fs, p.span, .{ .construct = .{ .tag = null, .args = args } }, .{ .named = name });
    // Affine field values move into the constructed value.
    for (args) |a| {
        if (a.ownership == .affine and !cfg_lower_emit.isConsumed(fs, a)) {
            cfg_lower_emit.markConsumed(self, fs, a);
            try cfg_lower_emit.cleanupDisable(self, fs, p.span, a);
        }
    }
    return result;
}

/// Union variant construction: `Result::Ok(value)` (Core §11).
pub fn lowerVariantConstruct(self: *Lowerer, fs: *FuncState, p: *const ast.PathExpr, ve: *const ast.VariantExpr) LowerError!?*cfg.Value {
    const name = try cfg_lower_path.joinPath(self, p.path);
    const ud = moduleinfo.unionDecl(self.resolve, fs.module, name) orelse
        return self.fail(p.span, "unknown union type '{s}'", .{name});
    const tag = moduleinfo.variantIndex(ud, ve.name.text) orelse
        return self.fail(ve.name.span, "union '{s}' has no variant '{s}'", .{ name, ve.name.text });
    var args = std.ArrayListUnmanaged(*cfg.Value).empty;
    if (ve.args) |exprs| {
        for (exprs) |*arg| {
            const v = (try lowerExpr(self, fs, arg)) orelse return null;
            try args.append(self.arena, v);
        }
    }
    const result = try cfg_lower_emit.emit(self, fs, p.span, .{ .construct = .{ .tag = tag, .args = args.items } }, .{ .named = name });
    for (args.items) |a| {
        if (a.ownership == .affine and !cfg_lower_emit.isConsumed(fs, a)) {
            cfg_lower_emit.markConsumed(self, fs, a);
            try cfg_lower_emit.cleanupDisable(self, fs, p.span, a);
        }
    }
    return result;
}

pub fn lowerTuple(self: *Lowerer, fs: *FuncState, t: *const ast.TupleExpr) LowerError!?*cfg.Value {
    var args = std.ArrayListUnmanaged(*cfg.Value).empty;
    var elems = std.ArrayListUnmanaged(cfg.Type).empty;
    for (t.elems) |*el| {
        const v = (try lowerExpr(self, fs, el)) orelse return null;
        try args.append(self.arena, v);
        try elems.append(self.arena, v.type_);
    }
    const result = try cfg_lower_emit.emit(self, fs, t.span, .{ .construct = .{ .tag = null, .args = args.items } }, .{ .tuple = elems.items });
    for (args.items) |a| {
        if (a.ownership == .affine and !cfg_lower_emit.isConsumed(fs, a)) {
            cfg_lower_emit.markConsumed(self, fs, a);
            try cfg_lower_emit.cleanupDisable(self, fs, t.span, a);
        }
    }
    return result;
}

pub fn lowerList(self: *Lowerer, fs: *FuncState, l: *const ast.ListExpr) LowerError!?*cfg.Value {
    var args = std.ArrayListUnmanaged(*cfg.Value).empty;
    var elem_type: cfg.Type = .{ .primitive = .int32 };
    for (l.elems) |*el| {
        const v = (try lowerExpr(self, fs, el)) orelse return null;
        if (args.items.len == 0) elem_type = v.type_;
        try args.append(self.arena, v);
    }
    const inner = try self.arena.create(cfg.Type);
    inner.* = elem_type;
    const result = try cfg_lower_emit.emit(self, fs, l.span, .{ .construct = .{ .tag = null, .args = args.items } }, .{ .list = inner });
    for (args.items) |a| {
        if (a.ownership == .affine and !cfg_lower_emit.isConsumed(fs, a)) {
            cfg_lower_emit.markConsumed(self, fs, a);
            try cfg_lower_emit.cleanupDisable(self, fs, l.span, a);
        }
    }
    return result;
}

pub fn lowerUnary(self: *Lowerer, fs: *FuncState, u: *const ast.Unary) LowerError!?*cfg.Value {
    const v = (try lowerExpr(self, fs, u.operand)) orelse return null;
    return switch (u.op) {
        .neg => cfg_lower_emit.emit(self, fs, u.span, .{ .neg = v }, v.type_),
        .not => cfg_lower_emit.emit(self, fs, u.span, .{ .not_ = v }, .{ .primitive = .bool }),
    };
}

pub fn lowerBinary(self: *Lowerer, fs: *FuncState, b: *const ast.Binary) LowerError!?*cfg.Value {
    // Short-circuit and / or are control flow, never instructions
    // (ir.md §10.3): the right operand is evaluated only when needed.
    switch (b.op) {
        .and_ => return cfg_lower_control.lowerAnd(self, fs, b),
        .or_ => return cfg_lower_control.lowerOr(self, fs, b),
        else => {},
    }
    const lhs = (try lowerExpr(self, fs, b.lhs)) orelse return null;
    const rhs = (try lowerExpr(self, fs, b.rhs)) orelse return null;
    const op: cfg.Op = switch (b.op) {
        .eq => .{ .eq = .{ .a = lhs, .b = rhs } },
        .ne => .{ .ne = .{ .a = lhs, .b = rhs } },
        .lt => .{ .lt = .{ .a = lhs, .b = rhs } },
        .le => .{ .le = .{ .a = lhs, .b = rhs } },
        .gt => .{ .gt = .{ .a = lhs, .b = rhs } },
        .ge => .{ .ge = .{ .a = lhs, .b = rhs } },
        .add => if (isStr(lhs.type_) or isStr(rhs.type_))
            .{ .concat = .{ .a = lhs, .b = rhs } }
        else
            .{ .add = .{ .a = lhs, .b = rhs } },
        .sub => .{ .sub = .{ .a = lhs, .b = rhs } },
        .mul => .{ .mul = .{ .a = lhs, .b = rhs } },
        .div => .{ .div = .{ .a = lhs, .b = rhs } },
        .rem => .{ .rem = .{ .a = lhs, .b = rhs } },
        else => unreachable,
    };
    const result_type: cfg.Type = switch (b.op) {
        .eq, .ne, .lt, .le, .gt, .ge => .{ .primitive = .bool },
        else => lhs.type_,
    };
    return cfg_lower_emit.emit(self, fs, b.span, op, result_type);
}

pub fn isStr(t: cfg.Type) bool {
    return switch (t) {
        .primitive => |k| k == .str,
        else => false,
    };
}

pub fn lowerMove(self: *Lowerer, fs: *FuncState, m: *const ast.MoveExpr) LowerError!?*cfg.Value {
    const local = cfg_lower_emit.lookupLocal(fs, m.name.text) orelse
        return self.fail(m.span, "move of unknown binding '{s}'", .{m.name.text});
    const v = local.value;
    if (v.state == .borrowed) {
        return self.fail(m.span, "cannot move borrowed binding '{s}'", .{m.name.text});
    }
    if (v.ownership == .affine) {
        const moved = (try cfg_lower_emit.emit(self, fs, m.span, .{ .move_ = v }, v.type_)).?;
        cfg_lower_emit.markConsumed(self, fs, v);
        try cfg_lower_emit.cleanupDisable(self, fs, m.span, v);
        local.consumed = true;
        return moved;
    }
    // Duplicable `move` lowers to a copy (ir.md §5.4).
    return try cfg_lower_emit.emit(self, fs, m.span, .{ .copy = v }, v.type_);
}

pub fn lowerCast(self: *Lowerer, fs: *FuncState, c: *const ast.Cast) LowerError!?*cfg.Value {
    const moving = isMoveExpr(c.operand);
    const v = (try lowerExpr(self, fs, c.operand)) orelse return null;
    const target = try self.resolveType(fs, &c.target);
    const src = v.type_;
    if (src == .primitive and src.primitive == .any) {
        // `any` recovery (Core §11.6.1): an affine target requires a
        // moved source; a duplicable target copies the payload out and
        // leaves the `any` owned. The source's `move` (when written) was
        // already lowered by `lowerExpr` on the operand — the unpack
        // consumes the *moved* `any`.
        if (cfg_lower_emit.isAffine(self, fs, target) and !moving) {
            return self.fail(c.span, "cannot recover an affine payload from an 'any' without moving it; write (move a) as T", .{});
        }
        const op: cfg.Op = if (moving) .{ .any_unpack_move = v } else .{ .any_unpack_copy = v };
        const r = try cfg_lower_emit.emit(self, fs, c.span, op, target);
        if (moving) {
            cfg_lower_emit.markConsumed(self, fs, v);
            try cfg_lower_emit.cleanupDisable(self, fs, c.span, v);
        }
        return r;
    }
    // The Core §16.3 numeric conversions only (`int32 as float32`,
    // `float32 as int32`); the checker rejects everything else.
    return try cfg_lower_emit.emit(self, fs, c.span, .{ .num_cast = v }, target);
}

/// A statement discards its value: affine-owned results are dropped
/// here (ir.md §6.4, temporaries of a full expression).
pub fn discardValue(self: *Lowerer, fs: *FuncState, v: *cfg.Value) LowerError!void {
    if (v.ownership == .affine and !cfg_lower_emit.isConsumed(fs, v)) {
        try cfg_lower_emit.emitDrop(self, fs, v.span, v);
    }
}

/// `move name` expressions appear where a whole owner transfers
/// (`match (move s)`, `for (x in move xs)`, `let p = move x`).
pub fn isMoveExpr(e: *const ast.Expr) bool {
    // Parentheses do not change ownership semantics: `match (move a)`
    // (Core §13.4) and `(move a) as T` (Core §11.6.1) consume the
    // scrutinee/operand just like the bare `move` forms.
    var ex = e;
    while (ex.* == .paren) ex = ex.paren.inner;
    return ex.* == .move;
}

/// Lower a lambda literal to a synthesized `IrFunc` plus a `fn_ref`
/// value (ir.md §5.5). Stilla lambdas are non-capturing (Core §18), so
/// a lambda is exactly a monomorphic function: its body is hoisted and
/// compiled like a named function's, and the value references the
/// synthesized `IrFunc`. The `IrFunc` is registered on
/// `Lowerer.lambda_funcs`; `cfg_lower_module.lowerModule` drains that
/// list into the owning module's `funcs` after the member functions.
fn lowerLambda(self: *Lowerer, fs: *FuncState, lam: *const ast.Lambda) LowerError!?*cfg.Value {
    var params = std.ArrayListUnmanaged(cfg.Param).empty;
    for (lam.params) |*p| {
        const t = try self.resolveType(fs, &p.type_);
        try params.append(self.arena, .{ .span = p.span, .name = p.name, .mode = p.mode, .type_ = t });
    }
    // The lambda's return type is inferred from its body when not
    // written (Grammar `lambda`: `[ "->" type ]`); the declared type is
    // the seed and the body's actual result type wins (phase 2 already
    // validated the two agree).
    var ret: cfg.Type = if (lam.ret) |*rt| try self.resolveType(fs, rt) else .{ .primitive = .void };
    const qname = try std.fmt.allocPrint(self.arena, "{s}.lambda{d}", .{ fs.name.text, self.next_lambda_id });
    self.next_lambda_id += 1;
    var lfs = try cfg_lower_func.newFuncState(self, fs.module, .{ .span = lam.span, .text = qname }, params.items, ret);
    const entry = try cfg_lower_emit.newBlock(self, &lfs, "entry");
    lfs.cur = entry;
    try lfs.scopes.append(self.arena, .{});
    for (lfs.params, 0..) |p, i| {
        const v = lfs.values.items[i];
        try cfg_lower_emit.bindLocal(self, &lfs, p.name.text, v, p.mode != .borrow and cfg_lower_emit.isAffine(self, &lfs, v.type_));
    }
    const result = try cfg_lower_func.lowerBlock(self, &lfs, lam.body);
    try cfg_lower_emit.exitScope(self, &lfs, result);
    if (result) |r| {
        ret = r.type_;
        if (cfg_lower_emit.isVoid(r.type_)) {
            try cfg_lower_emit.setTerminator(self, &lfs, .{ .ret = null });
        } else {
            // The `T → any` return coercion (Core §11.6, ir.md §4.4).
            const rv = try cfg_lower_func.coerceRet(self, &lfs, r);
            cfg_lower_emit.markConsumed(self, &lfs, rv);
            try cfg_lower_emit.cleanupDisable(self, &lfs, rv.span, rv);
            try cfg_lower_emit.setTerminator(self, &lfs, .{ .ret = rv });
        }
    } else if (lfs.cur != null) {
        try cfg_lower_emit.setTerminator(self, &lfs, .{ .ret = null });
    }
    lfs.ret = ret;
    const ir = try cfg_lower_validate.finishFunc(self, &lfs);
    try self.lambda_funcs.append(self.arena, ir);
    const ret_ptr = try self.arena.create(cfg.Type);
    ret_ptr.* = ret;
    return cfg_lower_emit.emit(self, fs, lam.span, .{ .fn_ref = ir.name.text }, .{ .function = .{ .params = params.items, .ret = ret_ptr } });
}
