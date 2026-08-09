//! Pass: pattern lowering — `pattern`, `type-test-pattern`,
//! `tuple-pattern`, `list-pattern`, `path-pattern` (Core §14). In:
//! Lowerer + FuncState + ast.Pattern + base value. Out: bindings for
//! pattern-introduced names (with ownership) and drops for discarded
//! affine values.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const lower = @import("../lower.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_path = @import("cfg_lower_path.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// A constant from a literal pattern (for `eq` tests).
pub fn lowerLiteralConst(self: *Lowerer, fs: *FuncState, lp: *const ast.LiteralPattern) LowerError!*cfg.Value {
    const v = switch (lp.value) {
        .int => |i| try cfg_lower_expr.emitConst(self, fs, lp.span, .{ .int = @intCast(i) }, .{ .primitive = .int32 }),
        .neg_int => |i| try cfg_lower_expr.emitConst(self, fs, lp.span, .{ .int = -@as(i64, @intCast(i)) }, .{ .primitive = .int32 }),
        .float => |f| try cfg_lower_expr.emitConst(self, fs, lp.span, .{ .float = @floatCast(f) }, .{ .primitive = .float32 }),
        .neg_float => |f| try cfg_lower_expr.emitConst(self, fs, lp.span, .{ .float = -@as(f32, @floatCast(f)) }, .{ .primitive = .float32 }),
        .string => |s| try cfg_lower_expr.emitConst(self, fs, lp.span, .{ .string = s }, .{ .primitive = .str }),
        .bool => |b| try cfg_lower_expr.emitConst(self, fs, lp.span, .{ .bool = b }, .{ .primitive = .bool }),
    };
    return v orelse unreachable;
}

/// True when a pattern contains a type-test pattern anywhere (Core
/// §14.7). Type-test patterns are refutable, so `let` and `for` — which
/// require irrefutable patterns — reject them (Core §14).
pub fn patternHasTypeTest(p: *const ast.Pattern) bool {
    return switch (p.*) {
        .type_test => true,
        .tuple => |tp| blk: {
            for (tp.elems) |*el| {
                if (patternHasTypeTest(el)) break :blk true;
            }
            break :blk false;
        },
        .list => |lp| blk: {
            for (lp.items) |*el| {
                if (patternHasTypeTest(el)) break :blk true;
            }
            break :blk false;
        },
        .path => |pp| switch (pp.tail) {
            .struct_ => |sp| blk: {
                for (sp.fields) |*f| {
                    if (f.pattern) |*fp| {
                        if (patternHasTypeTest(fp)) break :blk true;
                    }
                }
                break :blk false;
            },
            .variant => |vp| blk: {
                if (vp.args) |args| for (args) |*a| {
                    if (patternHasTypeTest(a)) break :blk true;
                };
                break :blk false;
            },
            .none => false,
        },
        .wildcard, .literal => false,
    };
}

/// Bind the names a pattern introduces. `base_owned` is true when the
/// destructure *takes* (`let p = move x`, `match (move s)`, a
/// consuming `for`): projections are `take_*` and the base is
/// consumed as a whole after its final projection (Core §14.6, §18
/// *Whole-owner rule*). Otherwise projections are `read_*` (borrowed
/// views of affine bases, ir.md §5.3).
pub fn bindPattern(self: *Lowerer, fs: *FuncState, pattern: *const ast.Pattern, base: *cfg.Value, base_owned: bool) LowerError!void {
    switch (pattern.*) {
        .wildcard => {
            // `let _ = expr`: the value is discarded.
            if (base.ownership == .affine and base.state == .owned and !cfg_lower_emit.isConsumed(fs, base)) {
                try cfg_lower_emit.emitDrop(self, fs, base.span, base);
            }
        },
        .literal => {}, // tested by the match's eq chain
        .type_test => |tp| {
            // A type-test pattern matches an `any` by runtime tag
            // (Core §14.7); the arm's `type_is` test verified the tag,
            // so the unpack extracts the payload without trapping (Core
            // §11.6.1, §11.6.2). A consuming match (`match (move a)`)
            // transfers the whole `any` and the payload ownership;
            // otherwise the payload is copied out of the borrowed `any`.
            if (base.type_ != .primitive or base.type_.primitive != .any) {
                return self.fail(tp.span, "a type-test pattern requires an 'any' scrutinee", .{});
            }
            const payload_type = try self.resolveType(fs, &tp.type_);
            if (tp.binding) |binding| {
                if (cfg_lower_emit.isAffine(self, fs, payload_type) and !base_owned) {
                    return self.fail(tp.span, "cannot recover an affine payload from a borrowed 'any'; use match (move scrutinee)", .{});
                }
                const payload = if (base_owned)
                    (try cfg_lower_emit.emit(self, fs, binding.span, .{ .any_unpack_move = base }, payload_type)) orelse return
                else
                    (try cfg_lower_emit.emit(self, fs, binding.span, .{ .any_unpack_copy = base }, payload_type)) orelse return;
                const owns = payload.state == .owned and (payload.ownership orelse .duplicable) == .affine;
                try cfg_lower_emit.bindLocal(self, fs, binding.text, payload, owns);
            }
        },
        .path => |pp| switch (pp.tail) {
            .none => {
                // A plain `let x = fresh()` binds fresh ownership (Core
                // §10.5): the binding owns an affine value in the owned
                // state even when no `move` was written, so the scope-end
                // drop is emitted.
                const name = pp.path[pp.path.len - 1].text;
                try cfg_lower_emit.bindLocal(self, fs, name, base, base.ownership == .affine and base.state == .owned);
            },
            .struct_ => |sp| try destructureStruct(self, fs, &pp, &sp, base, base_owned),
            .variant => |vp| try destructureVariant(self, fs, &pp, &vp, base, base_owned),
        },
        .tuple => |tp| try destructureTuple(self, fs, &tp, base, base_owned),
        .list => |lp| try destructureList(self, fs, &lp, base, base_owned),
    }
}

pub fn destructureStruct(self: *Lowerer, fs: *FuncState, pp: *const ast.PathPattern, sp: *const ast.StructPattern, base: *cfg.Value, base_owned: bool) LowerError!void {
    const name = try cfg_lower_path.joinPath(self, pp.path);
    const sd = moduleinfo.structDecl(self.resolve, fs.module, name) orelse
        return self.fail(sp.span, "unknown struct type '{s}'", .{name});
    for (sp.fields) |*fp| {
        const idx = moduleinfo.fieldIndex(sd, fp.name.text) orelse
            return self.fail(fp.name.span, "struct '{s}' has no field '{s}'", .{ name, fp.name.text });
        const field_type = try self.resolveType(fs, &sd.fields[idx].type_);
        const proj = (if (base_owned)
            try cfg_lower_emit.emit(self, fs, fp.name.span, .{ .take_field = .{ .base = base, .index = idx } }, field_type)
        else
            try cfg_lower_emit.emit(self, fs, fp.name.span, .{ .read_field = .{ .base = base, .index = idx } }, field_type)) orelse continue;
        if (fp.pattern) |*p2| {
            try bindPattern(self, fs, p2, proj, proj.state == .owned);
        } else {
            try cfg_lower_emit.bindLocal(self, fs, fp.name.text, proj, proj.state == .owned and proj.ownership == .affine);
        }
    }
    if (base_owned) {
        cfg_lower_emit.markConsumed(self, fs, base);
        try cfg_lower_emit.cleanupDisable(self, fs, base.span, base);
    }
}

pub fn destructureTuple(self: *Lowerer, fs: *FuncState, tp: *const ast.TuplePattern, base: *cfg.Value, base_owned: bool) LowerError!void {
    const elems = switch (base.type_) {
        .tuple => |elems| elems,
        else => return self.fail(tp.span, "tuple pattern requires a tuple value", .{}),
    };
    if (tp.elems.len > elems.len) return self.fail(tp.span, "tuple pattern has too many elements", .{});
    for (tp.elems, 0..) |*el, i| {
        const proj = (if (base_owned)
            try cfg_lower_emit.emit(self, fs, el.span(), .{ .take_tuple = .{ .base = base, .index = @intCast(i) } }, elems[i])
        else
            try cfg_lower_emit.emit(self, fs, el.span(), .{ .read_tuple = .{ .base = base, .index = @intCast(i) } }, elems[i])) orelse continue;
        try bindPattern(self, fs, el, proj, proj.state == .owned);
    }
    if (base_owned) {
        cfg_lower_emit.markConsumed(self, fs, base);
        try cfg_lower_emit.cleanupDisable(self, fs, base.span, base);
    }
}

pub fn destructureList(self: *Lowerer, fs: *FuncState, lp: *const ast.ListPattern, base: *cfg.Value, base_owned: bool) LowerError!void {
    const elem_type = switch (base.type_) {
        .list => |inner| inner.*,
        else => return self.fail(lp.span, "list pattern requires a list value", .{}),
    };
    for (lp.items, 0..) |*item, i| {
        const idx = (try cfg_lower_expr.emitConst(self, fs, item.span(), .{ .int = @intCast(i) }, .{ .primitive = .int32 })).?;
        const proj = (if (base_owned)
            try cfg_lower_emit.emit(self, fs, item.span(), .{ .take_index = .{ .base = base, .index = idx } }, elem_type)
        else
            try cfg_lower_emit.emit(self, fs, item.span(), .{ .read_index = .{ .base = base, .index = idx } }, elem_type)) orelse continue;
        try bindPattern(self, fs, item, proj, proj.state == .owned);
    }
    if (lp.rest) |rest| {
        // `..rest` binds the remaining list: a borrowed sublist view in a
        // non-consuming match, an owned remainder in a consuming one
        // (Core §14.5, §14.6).
        const inner = try self.arena.create(cfg.Type);
        inner.* = elem_type;
        const tail = (if (base_owned)
            try cfg_lower_emit.emit(self, fs, rest.span, .{ .take_tail = base }, .{ .list = inner })
        else
            try cfg_lower_emit.emit(self, fs, rest.span, .{ .tail = base }, .{ .list = inner })) orelse return;
        try cfg_lower_emit.bindLocal(self, fs, rest.text, tail, tail.state == .owned and tail.ownership == .affine);
    }
    if (base_owned) {
        cfg_lower_emit.markConsumed(self, fs, base);
        try cfg_lower_emit.cleanupDisable(self, fs, base.span, base);
    }
}

/// A variant pattern outside a union match needs its enclosing type
/// path; the current frontend only supports variant patterns inside a
/// union `match`.
pub fn destructureVariant(self: *Lowerer, _: *FuncState, _: *const ast.PathPattern, vp: *const ast.VariantPattern, _: *cfg.Value, _: bool) LowerError!void {
    return self.fail(vp.span, "variant patterns require a union match in this frontend", .{});
}
