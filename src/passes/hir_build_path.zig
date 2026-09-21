//! Part of the AST→HIR builder (hir.md §7.4; driver:
//! `hir_build.zig`): dotted module access paths (value leaves and
//! the recorded module-access hops), struct/tuple/list construction,
//! and variant construction.

const std = @import("std");
const ast = @import("stilla").ast;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const hir_build = @import("hir_build.zig");
const hir_build_block = @import("hir_build_block.zig");
const hir_build_expr = @import("hir_build_expr.zig");
const hir_build_call = @import("hir_build_call.zig");

// ---------------------------------------------------------------------------
// Paths, member leaves, constructions
// ---------------------------------------------------------------------------

pub fn buildPath(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr) hir_build.BuildError!hir.ExprId {
    switch (p.tail) {
        .construct => |*sc| return buildStructConstruct(b, info, e, p, sc),
        .variant => |*ve| return buildVariantConstruct(b, info, e, p, ve),
        .none => return buildPathValue(b, info, e, p),
    }
}

fn buildPathValue(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr) hir_build.BuildError!hir.ExprId {
    const path = p.path;
    if (path.len == 1) {
        const n = path[0].text;
        if (b.lookup(n)) |bind| return hir_build_block.localNode(b, info, bind, path[0].span);
        if (info.module_values.get(n) != null or b.aliasModule(n) != null) {
            return b.fail(path[0].span, "module value '{s}' has no runtime value", .{n});
        }
        if (info.valueMember(n) != null) {
            return hir_build_call.memberLeaf(b, info, info.specifier, n, path[0].span, true);
        }
        if (info.alias(n)) |a| {
            return switch (a.target) {
                .value => |mr| hir_build_call.memberLeaf(b, info, mr.module, mr.name, path[0].span, true),
                .module => b.fail(path[0].span, "module value '{s}' has no runtime value", .{n}),
                .type => b.fail(path[0].span, "'{s}' is a type, not a value", .{n}),
            };
        }
        return b.fail(path[0].span, "unknown name '{s}'", .{n});
    }
    if (b.lookup(path[0].text)) |bind| {
        const bind_ty = b.built.program.binders.items[bind].ty;
        var cur = try hir_build_block.localNode(b, info, bind, path[0].span);
        var cur_ty = bind_ty;
        for (path[1..], 0..) |seg, i| {
            // Only the final read of the chain carries the path's
            // annotation (see fieldRead).
            const ann_e: ?*const ast.Expr = if (i == path.len - 2) e else null;
            cur = try hir_build_expr.fieldRead(b, info, ann_e, seg.span, cur, cur_ty, seg.text);
            cur_ty = b.built.program.node(cur).ty;
        }
        return cur;
    }
    const spec = info.module_values.get(path[0].text) orelse b.aliasModule(path[0].text) orelse
        return b.fail(path[0].span, "'{s}' does not name a module", .{path[0].text});
    var mod = b.graph.module(spec) orelse
        return b.fail(path[0].span, "module '{s}' is not loaded", .{spec});
    // Intermediate segments chain through module-valued members; the
    // resolved path records each hop (owning module, member name) so
    // the lowering replays the chain as `module_ref` + per-hop
    // `load_member`s exactly like the direct `lowerPathValue` — module
    // identity flows through the AIR loads, never a static jump to the
    // final module.
    var hops = std.ArrayList(hir.AccessHop).empty;
    var k: usize = 1;
    while (k < path.len - 1) : (k += 1) {
        const vm = mod.valueMember(path[k].text) orelse
            return b.fail(path[k].span, "module '{s}' has no member '{s}'", .{ mod.specifier, path[k].text });
        if (vm.module_spec) |mspec| {
            try hops.append(b.arena, .{ .module = try b.modIdx(mod.specifier), .name = path[k].text });
            mod = b.graph.module(mspec) orelse
                return b.fail(path[k].span, "module '{s}' is not loaded", .{mspec});
        } else {
            return b.fail(path[k].span, "'{s}' is not a module value", .{path[k].text});
        }
    }
    const tail = path[path.len - 1];
    const leaf = try hir_build_call.memberLeaf(b, info, mod.specifier, tail.text, tail.span, true);
    if (hops.items.len > 0) b.built.program.setAccessHops(leaf, hops.items);
    return leaf;
}

pub fn joinPath(b: *hir_build.Builder, path: []const meta.Ident) hir_build.BuildError![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (path, 0..) |id, i| {
        if (i > 0) try buf.append(b.arena, '.');
        try buf.appendSlice(b.arena, id.text);
    }
    return buf.toOwnedSlice(b.arena);
}

fn buildStructConstruct(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr, sc: *const ast.StructConstruct) hir_build.BuildError!hir.ExprId {
    const name = try joinPath(b, p.path);
    // A host-backed opaque nominal type has no fields and no Stilla-side
    // construction (Core §11.8) — mirror cfg_lower_expr's rejection.
    if (moduleinfo.opaqueDecl(b.resolve, info, name) != null) {
        return b.fail(p.span, "opaque host type '{s}' cannot be constructed in source (Core §11.8)", .{name});
    }
    const sd = moduleinfo.structDecl(b.resolve, info, name) orelse
        return b.fail(p.span, "unknown struct type '{s}'", .{name});
    // Core §8.1: every declared field exactly once, in any order — the
    // the direct lowering's struct-construct rule (direct path removed in S6b);
    // the HIR seam must reject at build with the same diagnostics.
    const seen = try b.arena.alloc(bool, sd.fields.len);
    @memset(seen, false);
    // Evaluate field values in *written* order; the struct node carries
    // them in declaration order (member identity). When the written
    // order differs, the values are bound to temp binders first (a let
    // chain in written order) so the tree still evaluates left to right
    // in written order; the common decl-ordered case stays a plain node.
    var written = std.ArrayList(hir.ExprId).empty;
    var written_idx = std.ArrayList(u32).empty;
    for (sc.fields) |*f| {
        const idx = moduleinfo.fieldIndex(sd, f.name.text) orelse
            return b.fail(f.name.span, "struct '{s}' has no field '{s}'", .{ name, f.name.text });
        if (seen[idx]) return b.fail(f.name.span, "duplicate field '{s}'", .{f.name.text});
        seen[idx] = true;
        try written.append(b.arena, try hir_build_expr.buildExpr(b, info, f.value));
        try written_idx.append(b.arena, idx);
    }
    for (sd.fields, 0..) |f, i| {
        if (!seen[i]) return b.fail(p.span, "missing field '{s}' in '{s}'", .{ f.name.text, name });
    }
    var permuted = false;
    for (written_idx.items, 0..) |idx, wpos| {
        if (idx != wpos) {
            permuted = true;
            break;
        }
    }
    const decl_reads = try b.arena.alloc(hir.ExprId, sd.fields.len);
    var value_ty: meta.Type = undefined;
    if (b.annotatedType(info, e)) |at| {
        value_ty = at;
    } else {
        const tid = moduleinfo.resolveTypeId(b.resolve, info, name) orelse
            return b.fail(p.span, "unknown struct type '{s}'", .{name});
        value_ty = .{ .named = .{ .id = tid, .args = &.{} } };
    }
    var struct_node: hir.ExprId = undefined;
    if (!permuted) {
        for (written.items, written_idx.items) |v, idx| decl_reads[idx] = v;
        const ops = try b.built.program.addOperands(decl_reads);
        struct_node = try b.built.program.addExpr(.{ .op = try b.op(p.span, "struct_make"), .ty = value_ty, .operands = ops, .origin = try b.origin(p.span) });
    } else {
        const temps = try b.arena.alloc(hir.BinderId, written.items.len);
        for (written.items, 0..) |v, w| {
            temps[w] = try b.built.program.addBinder(b.built.program.node(v).ty, .value);
        }
        for (written_idx.items, 0..) |idx, wpos| {
            // The decl-order reads are synthesized (no source position).
            const read = try hir_build_block.localNode(b, info, temps[wpos], null);
            decl_reads[idx] = read;
        }
        const ops = try b.built.program.addOperands(decl_reads);
        struct_node = try b.built.program.addExpr(.{ .op = try b.op(p.span, "struct_make"), .ty = value_ty, .operands = ops, .origin = try b.origin(p.span) });
        // Wrap in temp-let regions, innermost bound last (written order
        // preserved: each temp's region contains the later-written ones).
        var wi: usize = written.items.len;
        while (wi > 0) {
            wi -= 1;
            struct_node = try hir_build_block.letNode(b, p.span, written.items[wi], &.{temps[wi]}, struct_node);
        }
    }
    return struct_node;
}

fn buildVariantConstruct(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr, ve: *const ast.VariantExpr) hir_build.BuildError!hir.ExprId {
    const name = try joinPath(b, p.path);
    const ud = moduleinfo.unionDecl(b.resolve, info, name) orelse
        return b.fail(p.span, "unknown union type '{s}'", .{name});
    const tag = moduleinfo.variantIndex(ud, ve.name.text) orelse
        return b.fail(ve.name.span, "union '{s}' has no variant '{s}'", .{ name, ve.name.text });
    var args = std.ArrayList(hir.ExprId).empty;
    if (ve.args) |exprs| for (exprs) |*arg| {
        try args.append(b.arena, try hir_build_expr.buildExpr(b, info, arg));
    };
    const ops = try b.built.program.addOperands(args.items);
    var result_ty: meta.Type = undefined;
    if (b.annotatedType(info, e)) |at| {
        result_ty = at;
    } else {
        const tid = moduleinfo.resolveTypeId(b.resolve, info, name) orelse
            return b.fail(p.span, "unknown union type '{s}'", .{name});
        result_ty = .{ .named = .{ .id = tid, .args = &.{} } };
    }
    return b.built.program.addExpr(.{ .op = try b.op(p.span, "variant_make"), .ty = result_ty, .operands = ops, .payload = .{ .tag = tag }, .origin = try b.origin(p.span) });
}
