//! Part of the AST→HIR builder (hir.md §5.4; driver:
//! `hir_build.zig`): AST pattern → `hir.Pattern` trees, one binder
//! per binding leaf, and the source-name binding of those leaves.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const type_resolve = @import("type_resolve.zig");
const hir_build = @import("hir_build.zig");
const hir_build_block = @import("hir_build_block.zig");
const hir_build_path = @import("hir_build_path.zig");

/// Convert one AST pattern into a `hir.Pattern` arena tree, allocating
/// one binder per binding leaf (types derived from the scrutinee type
/// and the pattern shape) and appending leaves in source order.
pub fn buildPattern(
    b: *hir_build.Builder,
    info: *moduleinfo.ModuleInfo,
    p: *const ast.Pattern,
    scrut_ty: cfg.Type,
    consuming: bool,
    leaves: *std.ArrayList(hir.BinderId),
) hir_build.BuildError!hir.PatternId {
    switch (p.*) {
        .wildcard => return b.built.program.addPattern(.wildcard),
        .literal => |lp| {
            const value: cfg.ConstValue = switch (lp.value) {
                .int => |i| .{ .int = @intCast(i) },
                .neg_int => |i| .{ .int = -@as(i64, @intCast(i)) },
                .float => |f| .{ .float = try narrowFloat(b, lp.span, f) },
                .neg_float => |f| .{ .float = -(try narrowFloat(b, lp.span, f)) },
                .string => |st| .{ .string = st },
                .bool => |bv| .{ .bool = bv },
            };
            return b.built.program.addPattern(.{ .literal = value });
        },
        .type_test => |tt| {
            const test_ty = try b.resolveType(info, &tt.type_);
            if (tt.binding != null) {
                if (!consuming and hir_build_block.typeIsUnique(b, info, test_ty)) {
                    return b.fail(tt.span, "cannot recover an unique payload from a borrowed 'any'; use match (move scrutinee)", .{});
                }
                const bid = try b.built.program.addBinder(test_ty, leafMode(b, info, test_ty, consuming));
                try leaves.append(b.arena, bid);
                return b.built.program.addPattern(.{ .type_test = .{ .ty = test_ty, .bind = bid } });
            }
            return b.built.program.addPattern(.{ .type_test = .{ .ty = test_ty, .bind = no_binder } });
        },
        .path => |pp| switch (pp.tail) {
            .none => {
                // Identifier pattern binds the whole scrutinee.
                const bid = try b.built.program.addBinder(scrut_ty, leafMode(b, info, scrut_ty, consuming));
                try leaves.append(b.arena, bid);
                try b.pat_names.put(b.arena, bid, pp.path[pp.path.len - 1].text);
                return b.built.program.addPattern(.{ .bind = bid });
            },
            .struct_ => |sp| {
                const name = try hir_build_path.joinPath(b, pp.path);
                const sd = moduleinfo.structDecl(b.resolve, info, name) orelse
                    return b.fail(sp.span, "unknown struct type '{s}'", .{name});
                const args = switch (scrut_ty) {
                    .named => |n| n.args,
                    else => &.{},
                };
                var fields = std.ArrayList(hir.Pattern.FieldPattern).empty;
                for (sp.fields) |*fp| {
                    const idx = moduleinfo.fieldIndex(sd, fp.name.text) orelse
                        return b.fail(fp.name.span, "struct '{s}' has no field '{s}'", .{ name, fp.name.text });
                    const field_ty = type_resolve.substParams(b.arena, sd.type_params, args, moduleinfo.resolveType(b.resolve, info, &sd.fields[idx].type_) orelse
                        return b.fail(fp.name.span, "cannot resolve field type", .{}));
                    if (fp.pattern) |*sub| {
                        try fields.append(b.arena, .{ .field = @intCast(idx), .pat = try buildPattern(b, info, sub, field_ty, consuming, leaves) });
                    } else {
                        const bid = try b.built.program.addBinder(field_ty, leafMode(b, info, field_ty, consuming));
                        try leaves.append(b.arena, bid);
                        try b.pat_names.put(b.arena, bid, fp.name.text);
                        try fields.append(b.arena, .{ .field = @intCast(idx), .pat = try b.built.program.addPattern(.{ .bind = bid }) });
                    }
                }
                return b.built.program.addPattern(.{ .struct_ = .{ .fields = try fields.toOwnedSlice(b.arena) } });
            },
            .variant => |vp| {
                const ud = moduleinfo.unionDecl(b.resolve, info, try hir_build_path.joinPath(b, pp.path)) orelse
                    return b.fail(vp.span, "unknown union type", .{});
                const tag = moduleinfo.variantIndex(ud, vp.name.text) orelse
                    return b.fail(vp.name.span, "union has no variant '{s}'", .{vp.name.text});
                const args = switch (scrut_ty) {
                    .named => |n| n.args,
                    else => return b.fail(vp.span, "variant pattern requires a named scrutinee", .{}),
                };
                const types = ud.variants[tag].types;
                if (vp.args) |argpats| {
                    var payload_ids = std.ArrayList(hir.PatternId).empty;
                    var idx2: usize = 0;
                    while (idx2 < argpats.len) : (idx2 += 1) {
                        const payload_ty = if (types != null and types.?.len == 1)
                            type_resolve.substParams(b.arena, ud.type_params, args, moduleinfo.resolveType(b.resolve, info, &types.?[0]) orelse
                                return b.fail(vp.span, "cannot resolve payload type", .{}))
                        else if (types) |ts| blk: {
                            const pt = moduleinfo.resolveType(b.resolve, info, &ts[idx2]) orelse
                                return b.fail(vp.span, "cannot resolve payload type", .{});
                            break :blk type_resolve.substParams(b.arena, ud.type_params, args, pt);
                        } else return b.fail(vp.span, "variant has no payload", .{});
                        try payload_ids.append(b.arena, try buildPattern(b, info, &argpats[idx2], payload_ty, consuming, leaves));
                    }
                    const payload: ?hir.PatternId = if (payload_ids.items.len == 1)
                        payload_ids.items[0]
                    else if (payload_ids.items.len > 1)
                        try b.built.program.addPattern(.{ .tuple = try payload_ids.toOwnedSlice(b.arena) })
                    else
                        null;
                    return b.built.program.addPattern(.{ .variant = .{ .tag = tag, .payload = payload } });
                }
                return b.built.program.addPattern(.{ .variant = .{ .tag = tag, .payload = null } });
            },
        },
        .tuple => |tp| {
            const elems = switch (scrut_ty) {
                .tuple => |es| es,
                else => return b.fail(tp.span, "tuple pattern requires a tuple value", .{}),
            };
            if (tp.elems.len > elems.len) return b.fail(tp.span, "tuple pattern has too many elements", .{});
            var kids = std.ArrayList(hir.PatternId).empty;
            for (tp.elems, 0..) |*el, k| {
                try kids.append(b.arena, try buildPattern(b, info, el, elems[k], consuming, leaves));
            }
            return b.built.program.addPattern(.{ .tuple = try kids.toOwnedSlice(b.arena) });
        },
        .list => |lp| {
            const elem_ty = switch (scrut_ty) {
                .list => |inner| inner.*,
                else => return b.fail(lp.span, "list pattern requires a list value", .{}),
            };
            var elems = std.ArrayList(hir.PatternId).empty;
            for (lp.items) |*it| {
                try elems.append(b.arena, try buildPattern(b, info, it, elem_ty, consuming, leaves));
            }
            var rest: ?hir.PatternId = null;
            if (lp.rest) |rest_name| {
                const tail_ty = try b.arena.create(cfg.Type);
                tail_ty.* = .{ .list = try b.arena.create(cfg.Type) };
                tail_ty.list.* = elem_ty;
                const bid = try b.built.program.addBinder(tail_ty.*, leafMode(b, info, tail_ty.*, consuming));
                try leaves.append(b.arena, bid);
                try b.pat_names.put(b.arena, bid, rest_name.text);
                rest = try b.built.program.addPattern(.{ .bind = bid });
            }
            return b.built.program.addPattern(.{ .list = .{ .elems = try elems.toOwnedSlice(b.arena), .rest = rest } });
        },
    }
}

/// The binder mode of one pattern leaf: Copy leaves bind as ordinary
/// values; unique leaves of a consuming destructure are `.move`, of a
/// non-consuming one `.borrow` (view).
fn leafMode(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, ty: cfg.Type, consuming: bool) hir.BinderMode {
    if (!hir_build_block.typeIsUnique(b, info, ty)) return .value;
    return if (consuming) .move else .borrow;
}

fn narrowFloat(b: *hir_build.Builder, span: ast.Span, v: f64) hir_build.BuildError!f64 {
    const f: f32 = @floatCast(v);
    if (!std.math.isFinite(f)) {
        return b.fail(span, "float literal out of range for float32", .{});
    }
    return f;
}

/// Bind the names of an AST pattern's leaves (source order) to the
/// binder ids created by `buildPattern`.
pub fn bindPatternLeaves(b: *hir_build.Builder, p: *const ast.Pattern, leaves: []const hir.BinderId) hir_build.BuildError!void {
    var names = std.ArrayList([]const u8).empty;
    try collectLeafNames(b, p, &names);
    if (names.items.len != leaves.len) return b.fail(p.span(), "internal: pattern leaf mismatch", .{});
    for (names.items, leaves) |nm, bid| {
        if (b.pat_names.get(bid)) |n2| {
            try b.bindName(n2, bid);
        } else {
            try b.bindName(nm, bid);
        }
    }
}

/// The source binding names of a pattern's leaves, left to right.
fn collectLeafNames(b: *hir_build.Builder, p: *const ast.Pattern, out: *std.ArrayList([]const u8)) hir_build.BuildError!void {
    switch (p.*) {
        .wildcard, .literal => {},
        .type_test => |tt| if (tt.binding) |bg| try out.append(b.arena, bg.text),
        .path => |pp| switch (pp.tail) {
            .none => try out.append(b.arena, pp.path[pp.path.len - 1].text),
            .struct_ => |sp| for (sp.fields) |*fp| {
                if (fp.pattern) |*sub| try collectLeafNames(b, sub, out) else try out.append(b.arena, fp.name.text);
            },
            .variant => |vp| if (vp.args) |args| for (args) |*a| try collectLeafNames(b, a, out),
        },
        .tuple => |tp| for (tp.elems) |*el| try collectLeafNames(b, el, out),
        .list => |lp| {
            for (lp.items) |*it| try collectLeafNames(b, it, out);
            if (lp.rest) |r| try out.append(b.arena, r.text);
        },
    }
}

/// Sentinel for a binding-less type-test pattern (matches an `any` by
/// tag without binding a name).
const no_binder: hir.BinderId = std.math.maxInt(hir.BinderId);
