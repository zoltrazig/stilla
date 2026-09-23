//! Part of the AST→HIR builder (hir.md §5.2; driver:
//! `hir_build.zig`): expression dispatch and the scalar/aggregate
//! forms — literals, unary/binary, cast/move, and the field-read
//! chain used by both plain paths and local-base member chains.

const std = @import("std");
const ast = @import("stilla").ast;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const type_resolve = @import("type_resolve.zig");
const hir_build = @import("hir_build.zig");
const hir_build_block = @import("hir_build_block.zig");
const hir_build_path = @import("hir_build_path.zig");
const hir_build_call = @import("hir_build_call.zig");
const hir_build_control = @import("hir_build_control.zig");

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// The void literal. `span` is the written `void` literal's span, or
/// null for the synthesized ones (module init body, empty block tail).
pub fn voidLiteral(b: *hir_build.Builder, span: ?meta.Span) hir_build.BuildError!hir.ExprId {
    return b.built.program.addExpr(.{ .op = try b.op(span orelse meta.Span.init(0, 0, 0), "const"), .ty = try b.internTy(.{ .primitive = .void }), .payload = .{ .const_value = .void }, .origin = if (span) |s| try b.origin(s) else hir.no_origin });
}

pub fn buildExpr(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr) hir_build.BuildError!hir.ExprId {
    return switch (e.*) {
        .int => |*lit| buildInt(b, lit),
        .float => |*lit| buildFloat(b, lit),
        .string => |lit| b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = try b.internTy(.{ .primitive = .str }), .payload = .{ .const_value = .{ .string = lit.value } }, .origin = try b.origin(lit.span) }),
        .bool => |lit| b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = try b.internTy(.{ .primitive = .bool }), .payload = .{ .const_value = .{ .bool = lit.value } }, .origin = try b.origin(lit.span) }),
        .void => |lit| voidLiteral(b, lit.span),
        .path => |*p| hir_build_path.buildPath(b, info, e, p),
        .paren => |p| buildExpr(b, info, p.inner),
        .tuple => |*t| buildTuple(b, info, e, t),
        .list => |*l| buildList(b, info, e, l),
        .lambda => |*lam| hir_build_call.buildLambda(b, info, lam),
        .if_ => |*i| hir_build_control.buildIf(b, info, i),
        .match => |*m| hir_build_control.buildMatch(b, info, e, m),
        .import => |imp| b.fail(imp.span, "import(...) is only valid as a module constant initializer", .{}),
        .block => |bx| hir_build_block.buildBlock(b, info, bx.block),
        .unary => |*u| buildUnary(b, info, u),
        .binary => |*bin| buildBinary(b, info, bin),
        .move => |*m| buildMove(b, info, m),
        .cast => |*c| buildCast(b, info, c),
        .member => |*m| buildMember(b, info, e, m),
        .call => |*c| hir_build_call.buildCall(b, info, e, c),
        .specialize => |*s| hir_build_call.buildSpecialize(b, info, s),
    };
}

fn buildInt(b: *hir_build.Builder, lit: *const ast.IntLiteral) hir_build.BuildError!hir.ExprId {
    var ty: meta.Type = .{ .primitive = .int32 };
    if (b.ann.int_widths.get(lit)) |k| ty = .{ .primitive = k };
    const bits: i64 = @bitCast(lit.value);
    return b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = try b.internTy(ty), .payload = .{ .const_value = .{ .int = bits } }, .origin = try b.origin(lit.span) });
}

fn buildFloat(b: *hir_build.Builder, lit: *const ast.FloatLiteral) hir_build.BuildError!hir.ExprId {
    var ty: meta.Type = .{ .primitive = .float32 };
    var v: f64 = lit.value;
    if (b.ann.float_widths.get(lit) != null) ty = .{ .primitive = .float64 };
    if (!(ty == .primitive and ty.primitive == .float64)) {
        const f: f32 = @floatCast(v);
        if (!std.math.isFinite(f)) {
            return b.fail(lit.span, "float literal out of range for float32", .{});
        }
        v = f;
    }
    return b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = try b.internTy(ty), .payload = .{ .const_value = .{ .float = v } }, .origin = try b.origin(lit.span) });
}

fn buildTuple(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, t: *const ast.TupleExpr) hir_build.BuildError!hir.ExprId {
    var ids = std.ArrayList(hir.ExprId).empty;
    var elems = std.ArrayList(meta.Type).empty;
    for (t.elems) |*el| {
        const v = try buildExpr(b, info, el);
        try ids.append(b.arena, v);
        try elems.append(b.arena, b.built.program.typeOf(b.built.program.node(v).ty));
    }
    const ops = try b.built.program.addOperands(ids.items);
    const ty: meta.Type = b.annotatedType(info, e) orelse .{ .tuple = try elems.toOwnedSlice(b.arena) };
    return b.built.program.addExpr(.{ .op = try b.op(t.span, "tuple_make"), .ty = try b.internTy(ty), .operands = ops, .origin = try b.origin(t.span) });
}

fn buildList(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, l: *const ast.ListExpr) hir_build.BuildError!hir.ExprId {
    var ids = std.ArrayList(hir.ExprId).empty;
    var elem_type: meta.Type = .{ .primitive = .int32 };
    for (l.elems) |*el| {
        const v = try buildExpr(b, info, el);
        if (ids.items.len == 0) elem_type = b.built.program.typeOf(b.built.program.node(v).ty);
        try ids.append(b.arena, v);
    }
    const ops = try b.built.program.addOperands(ids.items);
    const inner = try b.arena.create(meta.Type);
    inner.* = elem_type;
    const ty: meta.Type = b.annotatedType(info, e) orelse .{ .list = inner };
    return b.built.program.addExpr(.{ .op = try b.op(l.span, "list_make"), .ty = try b.internTy(ty), .operands = ops, .origin = try b.origin(l.span) });
}

/// Scalar-rep suffix for a primitive type (typed-op naming).
fn repSuffix(t: meta.Type) ?[]const u8 {
    return switch (t) {
        .primitive => |k| switch (k) {
            .byte => "byte",
            .int32 => "i32",
            .uint32 => "u32",
            .int64 => "i64",
            .uint64 => "u64",
            .float32 => "f32",
            .float64 => "f64",
            .bool => "bool",
            .str => "str",
            else => null,
        },
        else => null,
    };
}

fn buildUnary(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, u: *const ast.Unary) hir_build.BuildError!hir.ExprId {
    const v = try buildExpr(b, info, u.operand);
    const vt = b.built.program.typeOf(b.built.program.node(v).ty);
    const name = switch (u.op) {
        .neg => blk: {
            const rep = repSuffix(vt) orelse return b.fail(u.span, "cannot negate a '{s}' value", .{tyName(b, vt)});
            if (std.mem.eql(u8, rep, "bool") or std.mem.eql(u8, rep, "str")) {
                return b.fail(u.span, "cannot negate a '{s}' value", .{tyName(b, vt)});
            }
            break :blk try std.fmt.allocPrint(b.arena, "neg.{s}", .{rep});
        },
        .not => "not.bool",
    };
    const ops = try b.built.program.addOperands(&.{v});
    const ty: meta.Type = if (u.op == .neg) vt else .{ .primitive = .bool };
    return b.built.program.addExpr(.{ .op = try b.op(u.span, name), .ty = try b.internTy(ty), .operands = ops, .origin = try b.origin(u.span) });
}

fn tyName(b: *hir_build.Builder, t: meta.Type) []const u8 {
    var buf = std.ArrayList(u8).empty;
    appendTyName(b, &buf, t) catch return "?";
    return buf.items;
}

fn appendTyName(b: *hir_build.Builder, buf: *std.ArrayList(u8), t: meta.Type) !void {
    switch (t) {
        .primitive => |k| try buf.appendSlice(b.arena, @tagName(k)),
        .named => |n| {
            if (hir_build.typeNameOf(b, n.id)) |nm| try buf.appendSlice(b.arena, nm) else try buf.appendSlice(b.arena, "type");
            if (n.args.len > 0) {
                try buf.appendSlice(b.arena, "[");
                for (n.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(b.arena, ", ");
                    try appendTyName(b, buf, a);
                }
                try buf.appendSlice(b.arena, "]");
            }
        },
        .param => |p| try buf.appendSlice(b.arena, p),
        .module => try buf.appendSlice(b.arena, "module"),
        .cleanup => try buf.appendSlice(b.arena, "cleanup"),
        .list => |inner| {
            try buf.appendSlice(b.arena, "list[");
            try appendTyName(b, buf, inner.*);
            try buf.appendSlice(b.arena, "]");
        },
        .box => |inner| {
            try buf.appendSlice(b.arena, "box[");
            try appendTyName(b, buf, inner.*);
            try buf.appendSlice(b.arena, "]");
        },
        .tuple => |elems| {
            try buf.appendSlice(b.arena, "tuple[");
            for (elems, 0..) |el, i| {
                if (i > 0) try buf.appendSlice(b.arena, ", ");
                try appendTyName(b, buf, el);
            }
            try buf.appendSlice(b.arena, "]");
        },
        .function => try buf.appendSlice(b.arena, "fn"),
    }
}

fn buildBinary(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, bin: *const ast.Binary) hir_build.BuildError!hir.ExprId {
    if (bin.op == .and_) {
        const lhs = try buildExpr(b, info, bin.lhs);
        const rhs = try buildExpr(b, info, bin.rhs);
        const f = try b.built.program.addExpr(.{ .op = try b.op(bin.span, "const"), .ty = try b.internTy(.{ .primitive = .bool }), .payload = .{ .const_value = .{ .bool = false } }, .origin = try b.origin(bin.span) });
        return hir_build_control.controlNode(b, bin.span, "and", lhs, rhs, f);
    }
    if (bin.op == .or_) {
        const lhs = try buildExpr(b, info, bin.lhs);
        const rhs = try buildExpr(b, info, bin.rhs);
        const t = try b.built.program.addExpr(.{ .op = try b.op(bin.span, "const"), .ty = try b.internTy(.{ .primitive = .bool }), .payload = .{ .const_value = .{ .bool = true } }, .origin = try b.origin(bin.span) });
        return hir_build_control.controlNode(b, bin.span, "or", lhs, t, rhs);
    }
    const lhs = try buildExpr(b, info, bin.lhs);
    const rhs = try buildExpr(b, info, bin.rhs);
    const lt = b.built.program.typeOf(b.built.program.node(lhs).ty);
    const rt = b.built.program.typeOf(b.built.program.node(rhs).ty);
    const rep = repSuffix(lt) orelse return b.fail(bin.span, "binary op on non-scalar operand", .{});
    if (std.mem.eql(u8, rep, "bool") or std.mem.eql(u8, rep, "str")) {
        switch (bin.op) {
            .eq, .ne => {},
            .add => if (std.mem.eql(u8, rep, "str")) {} else return b.fail(bin.span, "unsupported operator for '{s}'", .{rep}),
            else => return b.fail(bin.span, "unsupported operator for '{s}'", .{rep}),
        }
    }
    const base: []const u8 = switch (bin.op) {
        .eq => "eq",
        .ne => "ne",
        .lt => "lt",
        .le => "le",
        .gt => "gt",
        .ge => "ge",
        .add => if (std.mem.eql(u8, rep, "str")) "concat" else "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .rem => "rem",
        .shl => "shl",
        .shr => "shr",
        .bitand => "band",
        .bitor => "bor",
        .bitxor => "bxor",
        .and_, .or_ => unreachable,
    };
    if ((std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr") or std.mem.eql(u8, base, "band") or std.mem.eql(u8, base, "bor") or std.mem.eql(u8, base, "bxor")) and (std.mem.eql(u8, rep, "f32") or std.mem.eql(u8, rep, "f64"))) {
        return b.fail(bin.span, "bitwise/shift ops are not defined for floats", .{});
    }
    const name = try std.fmt.allocPrint(b.arena, "{s}.{s}", .{ base, rep });
    const ops = try b.built.program.addOperands(&.{ lhs, rhs });
    const ty: meta.Type = switch (bin.op) {
        .eq, .ne, .lt, .le, .gt, .ge => .{ .primitive = .bool },
        else => lt,
    };
    _ = rt;
    return b.built.program.addExpr(.{ .op = try b.op(bin.span, name), .ty = try b.internTy(ty), .operands = ops, .origin = try b.origin(bin.span) });
}

fn buildMove(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, m: *const ast.MoveExpr) hir_build.BuildError!hir.ExprId {
    const bind = b.lookup(m.name.text) orelse
        return b.fail(m.span, "move of unknown binding '{s}'", .{m.name.text});
    const mode = b.built.program.binders.items[bind].mode;
    if (mode == .borrow) {
        return b.fail(m.span, "cannot move borrowed binding '{s}'", .{m.name.text});
    }
    const local = try hir_build_block.localNode(b, info, bind, m.name.span);
    const ty = b.built.program.typeOf(b.built.program.binders.items[bind].ty);
    // Always wrap: the lowering distinguishes unique (`move_`) from
    // Copy (`copy`) by the binder's type, and the syntactic `move`
    // matters even for Copy binders — `(move c) as T` on an `any`-typed
    // Copy unpacks with `any_unpack_move`, and a Copy-typed scrutinee
    // of `match (move c)` destructures atomically. Dropping the wrapper
    // here would lose that distinction (S5 amendment).
    const ops = try b.built.program.addOperands(&.{local});
    return b.built.program.addExpr(.{ .op = try b.op(m.span, "move"), .ty = try b.internTy(ty), .operands = ops, .origin = try b.origin(m.span) });
}

fn buildCast(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, c: *const ast.Cast) hir_build.BuildError!hir.ExprId {
    const v = try buildExpr(b, info, c.operand);
    const src = b.built.program.typeOf(b.built.program.node(v).ty);
    const target = try b.resolveType(info, &c.target);
    const ops = try b.built.program.addOperands(&.{v});
    const op_name: []const u8 = if (src == .primitive and src.primitive == .any) "any_cast" else "num_cast";
    return b.built.program.addExpr(.{ .op = try b.op(c.span, op_name), .ty = try b.internTy(target), .operands = ops, .origin = try b.origin(c.span) });
}

fn buildMember(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, m: *const ast.Member) hir_build.BuildError!hir.ExprId {
    if (resolveModuleChain(b, info, m.object)) |spec| {
        const mod = b.graph.module(spec) orelse return b.fail(m.span, "module '{s}' is not loaded", .{spec});
        return hir_build_call.memberLeaf(b, info, mod.specifier, m.name.text, m.span, true);
    }
    const base = try buildExpr(b, info, m.object);
    const bt = b.built.program.typeOf(b.built.program.node(base).ty);
    return fieldRead(b, info, e, m.span, base, bt, m.name.text);
}

/// Resolve an expression that is a module path to its specifier, or null.
fn resolveModuleChain(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, ex: *const ast.Expr) ?[]const u8 {
    var exx = ex;
    while (exx.* == .paren) exx = exx.paren.inner;
    if (exx.* != .path) return null;
    const p = &exx.path;
    var mod: ?*moduleinfo.ModuleInfo = null;
    var k: usize = 0;
    if (info.module_values.get(p.path[0].text)) |s0| {
        mod = b.graph.module(s0);
        k = 1;
    } else if (b.aliasModule(p.path[0].text)) |s0| {
        mod = b.graph.module(s0);
        k = 1;
    } else if (info.valueMember(p.path[0].text)) |vm| {
        if (vm.module_spec) |s0| {
            mod = b.graph.module(s0);
            k = 1;
        }
    }
    if (mod == null) return null;
    while (k < p.path.len - 1) : (k += 1) {
        const vm = mod.?.valueMember(p.path[k].text) orelse return null;
        if (vm.module_spec) |s1| mod = b.graph.module(s1) else return null;
    }
    return mod.?.specifier;
}

/// One field/element read: index by declaration (struct) or position
/// (tuple); S5 dispatches on the base type.
pub fn fieldRead(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: ?*const ast.Expr, span: meta.Span, base: hir.ExprId, bt: meta.Type, name: []const u8) hir_build.BuildError!hir.ExprId {
    const ops = try b.built.program.addOperands(&.{base});
    switch (bt) {
        .named => |td| {
            const type_name = hir_build.typeNameOf(b, td.id) orelse
                return b.fail(span, "cannot resolve member '{s}'", .{name});
            const sd = moduleinfo.structDecl(b.resolve, info, type_name) orelse
                return b.fail(span, "'{s}' is not a struct type", .{type_name});
            const idx = moduleinfo.fieldIndex(sd, name) orelse
                return b.fail(span, "struct '{s}' has no field '{s}'", .{ type_name, name });
            const resolved = moduleinfo.resolveType(b.resolve, info, &sd.fields[idx].type_) orelse
                return b.fail(span, "cannot resolve field type", .{});
            const field_type = type_resolve.substParams(b.arena, sd.type_params, td.args, resolved);
            // The path expression's annotation describes only the final
            // read of a chain (the whole path's type); an intermediate
            // read derives its type from the field declaration, exactly
            // like the direct member chain (cfg_lower_path.memberLoad; the direct path was removed in S6b, this is the historical oracle).
            const ty = if (e) |ex| b.annotatedType(info, ex) orelse field_type else field_type;
            return b.built.program.addExpr(.{ .op = try b.op(span, "field_get"), .ty = try b.internTy(ty), .operands = ops, .payload = .{ .field = @intCast(idx) }, .origin = try b.origin(span) });
        },
        .tuple => |elems| {
            const idx = std.fmt.parseInt(usize, name, 10) catch
                return b.fail(span, "tuple elements are indexed numerically", .{});
            if (idx >= elems.len) return b.fail(span, "tuple element #{d} out of range", .{idx});
            const ty = if (e) |ex| b.annotatedType(info, ex) orelse elems[idx] else elems[idx];
            return b.built.program.addExpr(.{ .op = try b.op(span, "field_get"), .ty = try b.internTy(ty), .operands = ops, .payload = .{ .field = @intCast(idx) }, .origin = try b.origin(span) });
        },
        else => return b.fail(span, "cannot access a member of this value", .{}),
    }
}
