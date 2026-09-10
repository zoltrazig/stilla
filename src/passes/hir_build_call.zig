//! Part of the AST→HIR builder (hir.md §7–§8; driver:
//! `hir_build.zig`): member leaves (`fn_ref` / `module_const` /
//! materialized intrinsic constants), λ hoisting, calls and
//! specialization, and the first-class intrinsic wrapper records.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const checker = @import("stilla").checker;
const hir_build = @import("hir_build.zig");
const hir_build_block = @import("hir_build_block.zig");
const hir_build_expr = @import("hir_build_expr.zig");

/// The value leaf of a module member: a function → `fn_ref` (member
/// record or host binding); a const → `module_const` (or materialized
/// intrinsic constant). Module-valued members have no runtime value.
/// `value_pos` distinguishes *value-position* uses (a bare intrinsic
/// function member synthesizes its first-class wrapper, mirroring
/// `cfg_lower_intrinsic.intrinsicFnRef`) from *call-position* leaves
/// (the call lowers to the inline expansion — syscall — at S5; the
/// leaf stays a host fn_ref).
pub fn memberLeaf(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, specifier: []const u8, name: []const u8, span: ast.Span, value_pos: bool) hir_build.BuildError!hir.ExprId {
    const owner = b.graph.module(specifier) orelse
        return b.fail(span, "module '{s}' is not loaded", .{specifier});
    const vm = owner.valueMember(name) orelse
        return b.fail(span, "module '{s}' has no member '{s}'", .{ specifier, name });
    switch (vm.decl) {
        .const_ => {
            if (owner.isIntrinsic(vm)) {
                const bits = cfgIntrinsicConstBits(specifier, name) orelse
                    return b.fail(span, "intrinsic '{s}.{s}' has no expansion", .{ specifier, name });
                const v: f32 = @bitCast(bits);
                return b.built.program.addExpr(.{ .op = try b.op(span, "const"), .ty = vm.type_, .payload = .{ .const_value = .{ .float = v } } });
            }
            const key = try b.qualified(specifier, name);
            const cid = b.const_ids.get(key) orelse
                return b.fail(span, "constant '{s}' has no record", .{key});
            return b.built.program.addExpr(.{ .op = try b.op(span, "module_const"), .ty = vm.type_, .payload = .{ .module_const = cid } });
        },
        .func => |f| {
            if (f.body != null and f.type_params.len == 0) {
                const key = try b.qualified(specifier, name);
                const fid = b.func_ids.get(key) orelse
                    return b.fail(span, "function '{s}' has no record", .{key});
                const rec = b.built.funcs.items[fid];
                return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = try b.funcType(rec.params, rec.ret), .payload = .{ .func = .{ .func = fid } } });
            }
            // Bodyless member: a host binding or a bundle intrinsic.
            // A *bare value use* of an intrinsic function member
            // synthesizes the first-class wrapper (the direct path's
            // `intrinsicFnRef`); call-position leaves keep the host
            // fn_ref (S5 lowers the call to the inline expansion).
            if (owner.isIntrinsic(vm) and value_pos) {
                return intrinsicWrapperFnRef(b, info, span, owner, vm, null);
            }
            const key = try b.qualified(specifier, name);
            const hid = b.host_ids.get(key) orelse
                return b.fail(span, "host binding '{s}' has no record", .{key});
            return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = vm.type_, .payload = .{ .func = .{ .host = hid } } });
        },
    }
}

/// Materializable intrinsic const bit patterns (mirror cfg's table).
fn cfgIntrinsicConstBits(module_spec: []const u8, member: []const u8) ?u32 {
    if (std.mem.eql(u8, module_spec, "math")) {
        if (std.mem.eql(u8, member, "pi")) return 0x40490FDB;
        if (std.mem.eql(u8, member, "e")) return 0x402DF854;
        if (std.mem.eql(u8, member, "tau")) return 0x40C90FDB;
        if (std.mem.eql(u8, member, "inf")) return 0x7F800000;
        if (std.mem.eql(u8, member, "nan")) return 0x7FC00000;
    }
    return null;
}

// ---------------------------------------------------------------------------
// λ hoisting, calls, specialization
// ---------------------------------------------------------------------------

pub fn buildLambda(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, lam: *const ast.Lambda) hir_build.BuildError!hir.ExprId {
    const name = try std.fmt.allocPrint(b.arena, "{s}.lambda{d}", .{ b.fn_name, b.next_lambda_id });
    b.next_lambda_id += 1;
    const params = try b.arena.alloc(cfg.Param, lam.params.len);
    for (lam.params, 0..) |*p, i| {
        params[i] = .{ .span = p.span, .name = p.name, .mode = p.mode, .type_ = try b.resolveType(info, &p.type_) };
    }
    const ret = try b.resolveType(info, &lam.ret);
    const fid = try hir_build.predeclare(b, hir.FuncKind.lambda, info, name, params, ret, lam.span, lam.body);
    try hir_build.buildFuncBody(b, fid);
    // Completion order: the record joins the module's pending list only
    // after its body is fully built (its own nested λs appended first).
    // Fallible — an OOM here must propagate, not be swallowed.
    try b.pending_lambdas.append(b.arena, fid);
    return b.built.program.addExpr(.{ .op = try b.op(lam.span, "fn_ref"), .ty = try b.funcType(params, ret), .payload = .{ .func = .{ .func = fid } } });
}
pub fn buildCall(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, c: *const ast.Call) hir_build.BuildError!hir.ExprId {
    const ann_inst = if (b.ann.per_module.get(info.specifier)) |ma| ma.call_of.get(c) else null;
    var callee_ty: ?cfg.Type = null;
    var callee: hir.ExprId = undefined;
    if (ann_inst) |inst| {
        if (inst.mono != null) {
            const key = try std.fmt.allocPrint(b.arena, "{s}.{s}.{d}", .{ inst.module.specifier, inst.decl.name.text, inst.id });
            const fid = b.func_ids.get(key) orelse
                return b.fail(c.span, "instance '{s}' has no record", .{key});
            const rec = b.built.funcs.items[fid];
            callee_ty = try b.funcType(rec.params, rec.ret);
            callee = try b.built.program.addExpr(.{ .op = try b.op(c.span, "fn_ref"), .ty = callee_ty.?, .payload = .{ .func = .{ .func = fid } } });
        } else {
            const key = try b.qualified(inst.module.specifier, inst.decl.name.text);
            const hid = b.host_ids.get(key) orelse
                return b.fail(c.span, "host binding '{s}' has no record", .{key});
            callee_ty = inst.signature;
            callee = try b.built.program.addExpr(.{ .op = try b.op(c.span, "fn_ref"), .ty = callee_ty.?, .payload = .{ .func = .{ .host = hid } } });
        }
    } else {
        // The callee is built first (mirrors the reference lowerer's
        // traversal, so lambda/wrapper discovery order matches).
        var ex = c.callee;
        while (ex.* == .paren) ex = ex.paren.inner;
        if (ex.* == .specialize) {
            callee = try specializeCalleeLeaf(b, info, &ex.specialize, c.span);
        } else if (ex.* == .path) {
            callee = try resolvePathCallee(b, info, ex, c.span, &callee_ty);
        } else {
            callee = try hir_build_expr.buildExpr(b, info, c.callee);
        }
    }
    var ids = std.ArrayList(hir.ExprId).empty;
    try ids.append(b.arena, callee);
    for (c.args) |*arg| {
        try ids.append(b.arena, try hir_build_expr.buildExpr(b, info, arg));
    }
    const ops = try b.built.program.addOperands(ids.items);
    var ty: cfg.Type = undefined;
    if (b.annotatedType(info, e)) |at| {
        ty = at;
    } else if (callee_ty) |ct| {
        ty = switch (ct) {
            .function => |f| f.ret.*,
            else => .{ .primitive = .any },
        };
    } else {
        ty = .{ .primitive = .void };
    }
    return b.built.program.addExpr(.{ .op = try b.op(c.span, "call"), .ty = ty, .operands = ops });
}

/// The callee leaf of a bare path in call position: a module-member
/// function (non-generic member / host / intrinsic → `memberLeaf`; a
/// bodyful generic must be instance-keyed by the annotation's
/// `call_of`), or a function-value callee (local / alias).
fn resolvePathCallee(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, span: ast.Span, callee_ty: *?cfg.Type) hir_build.BuildError!hir.ExprId {
    const p: *const ast.PathExpr = &e.path;
    const path = p.path;
    var owner = info;
    if (b.lookup(path[0].text) != null) {
        if (path.len == 1) return localCallee(b, info, path[0]);
        // A member chain on a local base (Core 6.1: `counter.next(...)`
        // — a function-valued struct field called through its holder):
        // a value callee built exactly like `buildPathValue`'s local
        // chain (annotations on the original callee expression). The
        // lowering emits the member load then an indirect call.
        var cur = try hir_build_block.localNode(b, info, b.lookup(path[0].text).?);
        var cur_ty = b.built.program.node(cur).ty;
        for (path[1..], 0..) |seg, i| {
            // Only the final read of the chain carries the path's
            // annotation (see fieldRead).
            const ann_e: ?*const ast.Expr = if (i == path.len - 2) e else null;
            cur = try hir_build_expr.fieldRead(b, info, ann_e, seg.span, cur, cur_ty, seg.text);
            cur_ty = b.built.program.node(cur).ty;
        }
        callee_ty.* = cur_ty;
        return cur;
    }
    if (path.len > 1) {
        const spec = info.module_values.get(path[0].text) orelse b.aliasModule(path[0].text) orelse
            return b.fail(path[0].span, "'{s}' does not name a module", .{path[0].text});
        owner = b.graph.module(spec) orelse
            return b.fail(path[0].span, "module '{s}' is not loaded", .{spec});
        var k: usize = 1;
        while (k < path.len - 1) : (k += 1) {
            const vm = owner.valueMember(path[k].text) orelse
                return b.fail(path[k].span, "module '{s}' has no member '{s}'", .{ owner.specifier, path[k].text });
            if (vm.module_spec) |mspec| {
                owner = b.graph.module(mspec) orelse
                    return b.fail(path[k].span, "module '{s}' is not loaded", .{mspec});
            } else {
                return b.fail(path[k].span, "'{s}' is not a module value", .{path[k].text});
            }
        }
    } else if (info.valueMember(path[0].text) == null) {
        return localCallee(b, info, path[path.len - 1]);
    }
    const tail = path[path.len - 1];
    const vm = owner.valueMember(tail.text) orelse
        return b.fail(tail.span, "module '{s}' has no member '{s}'", .{ owner.specifier, tail.text });
    switch (vm.decl) {
        .func => |f| {
            if (f.body == null or f.type_params.len == 0) {
                const leaf = try memberLeaf(b, info, owner.specifier, tail.text, span, false);
                callee_ty.* = vm.type_;
                return leaf;
            }
            return b.fail(tail.span, "generic function '{s}.{s}' call is not annotated (missing call_of)", .{ owner.specifier, tail.text });
        },
        .const_ => return b.fail(tail.span, "cannot call a constant", .{}),
    }
}

/// A single-name callee that is not a module member: a local binding
/// (fn-typed value) or a module-level alias.
fn localCallee(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, id: ast.Ident) hir_build.BuildError!hir.ExprId {
    if (b.lookup(id.text)) |bind| return hir_build_block.localNode(b, info, bind);
    if (info.alias(id.text)) |a| {
        switch (a.target) {
            .value => |mr| return memberLeaf(b, info, mr.module, mr.name, id.span, false),
            .module => {},
            .type => {},
        }
    }
    return b.fail(id.span, "unknown name '{s}'", .{id.text});
}

pub fn buildSpecialize(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, s: *const ast.Specialize) hir_build.BuildError!hir.ExprId {
    const ma = b.ann.per_module.get(info.specifier) orelse return b.fail(s.span, "no annotation", .{});
    const inst = ma.spec_of.get(s) orelse
        return b.fail(s.span, "an unspecialized generic cannot be used as a value (Core §12.4)", .{});
    if (inst.mono != null) {
        const key = try std.fmt.allocPrint(b.arena, "{s}.{s}.{d}", .{ inst.module.specifier, inst.decl.name.text, inst.id });
        const fid = b.func_ids.get(key) orelse
            return b.fail(s.span, "instance '{s}' has no record", .{key});
        const rec = b.built.funcs.items[fid];
        return b.built.program.addExpr(.{ .op = try b.op(s.span, "fn_ref"), .ty = try b.funcType(rec.params, rec.ret), .payload = .{ .func = .{ .func = fid } } });
    }
    const vm = inst.module.valueMember(inst.decl.name.text) orelse
        return b.fail(s.span, "member not found", .{});
    if (!inst.module.isIntrinsic(vm)) {
        return b.fail(s.span, "unsupported specialization of a host binding", .{});
    }
    return intrinsicWrapperFnRef(b, info, s.span, inst.module, vm, inst);
}

/// The callee leaf of a `::[…]`-specialized call whose callee is a
/// bodyless (host/intrinsic) member: a host fn_ref (the concrete
/// signature is derived at S5 from the arguments). Bodyful generic
/// specializations are keyed in `call_of` and handled earlier.
fn specializeCalleeLeaf(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, s: *const ast.Specialize, span: ast.Span) hir_build.BuildError!hir.ExprId {
    var operand = s.operand;
    while (operand.* == .paren) operand = operand.paren.inner;
    if (operand.* != .path) return b.fail(s.span, "cannot specialize a non-path callee", .{});
    const p = &operand.path;
    const spec = info.module_values.get(p.path[0].text) orelse
        b.aliasModule(p.path[0].text) orelse
        return b.fail(p.path[0].span, "'{s}' does not name a module", .{p.path[0].text});
    var mod = b.graph.module(spec) orelse
        return b.fail(p.path[0].span, "module '{s}' is not loaded", .{spec});
    var k: usize = 1;
    while (k < p.path.len - 1) : (k += 1) {
        const vm = mod.valueMember(p.path[k].text) orelse
            return b.fail(p.path[k].span, "module '{s}' has no member '{s}'", .{ mod.specifier, p.path[k].text });
        if (vm.module_spec) |mspec| mod = b.graph.module(mspec) orelse
            return b.fail(p.path[k].span, "module '{s}' is not loaded", .{mspec});
    }
    const tail = p.path[p.path.len - 1];
    const vm2 = mod.valueMember(tail.text) orelse
        return b.fail(tail.span, "module '{s}' has no member '{s}'", .{ mod.specifier, tail.text });
    switch (vm2.decl) {
        .func => |f| if (f.body != null) {
            return b.fail(s.span, "an unspecialized generic cannot be used as a value (Core §12.4)", .{});
        },
        .const_ => return b.fail(s.span, "cannot specialize a constant", .{}),
    }
    return memberLeaf(b, info, mod.specifier, tail.text, span, false);
}

fn intrinsicWrapperFnRef(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, span: ast.Span, owner: *moduleinfo.ModuleInfo, vm: *const moduleinfo.ValueMember, spec: ?*checker.FuncInstance) hir_build.BuildError!hir.ExprId {
    const sig = if (spec) |s| s.signature else vm.type_;
    const key = hir_build.WrapperKey{
        .owner = try b.modIdx(owner.specifier),
        .slot = vm.slot,
        .spec = if (spec) |s| s.id else std.math.maxInt(u32),
    };
    if (b.wrapper_cache.get(key)) |fid| {
        const rec = b.built.funcs.items[fid];
        return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = try b.funcType(rec.params, rec.ret), .payload = .{ .func = .{ .func = fid } } });
    }
    const name = try std.fmt.allocPrint(b.arena, "{s}.{s}.intrinsic.{d}", .{ info.specifier, vm.name.text, b.next_intrinsic_id });
    b.next_intrinsic_id += 1;
    const ft = switch (sig) {
        .function => |f| f,
        else => return b.fail(span, "intrinsic '{s}.{s}' is not a function", .{ owner.specifier, vm.name.text }),
    };
    const params = try b.arena.alloc(cfg.Param, ft.params.len);
    for (ft.params, 0..) |*p, i| {
        params[i] = .{ .span = p.span, .name = .{ .span = p.span, .text = try std.fmt.allocPrint(b.arena, "p{d}", .{i}) }, .mode = p.mode, .type_ = p.type_ };
    }
    const fid = try hir_build.predeclare(b, hir.FuncKind.intrinsic, info, name, params, ft.ret.*, span, null);
    try b.wrapper_cache.put(b.arena, key, fid);
    try b.pending_wrappers.append(b.arena, fid);
    // The wrapper's body forwards its parameters into the (module,
    // member) syscall target: `call(host-leaf, params…)`. The record's
    // body is a `lambda` region like every other function. The host
    // leaf is the intrinsic member's own host record — passed by id,
    // never recovered from the generated name.
    const hid = b.host_ids.get(try b.qualified(owner.specifier, vm.name.text)) orelse
        return b.fail(span, "intrinsic '{s}.{s}' has no host record", .{ owner.specifier, vm.name.text });
    b.built.funcs.items[fid].root = try synthIntrinsicRoot(b, fid, hid);
    return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = sig, .payload = .{ .func = .{ .func = fid } } });
}

/// The forwarding body of a first-class intrinsic wrapper: parameters
/// bound by mode, then a `call` of the intrinsic's (module, member)
/// syscall target with each parameter as an argument (mirror
/// `cfg_lower_intrinsic.synthIntrinsicFunc`; S5 emits the syscall).
fn synthIntrinsicRoot(b: *hir_build.Builder, fid: hir.FuncId, hid: hir.HostBindingId) hir_build.BuildError!hir.ExprId {
    const rec = b.built.funcs.items[fid];
    const info = b.graph.modules[rec.module];
    const host_rec = b.built.hosts.items[hid];
    var binder_ids = std.ArrayList(hir.BinderId).empty;
    var args = std.ArrayList(hir.ExprId).empty;
    try b.pushScope();
    for (rec.params) |prm| {
        const bind = try b.built.program.addBinder(prm.type_, switch (prm.mode) {
            .plain => .value,
            .borrow => .borrow,
            .move => .move,
        });
        try binder_ids.append(b.arena, bind);
        try b.bindName(prm.name.text, bind);
        if (hir_build.isVoid(prm.type_)) continue;
        try args.append(b.arena, try hir_build_block.localNode(b, info, bind));
    }
    const callee_leaf = try b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "fn_ref"), .ty = host_rec.signature, .payload = .{ .func = .{ .host = hid } } });
    var all = std.ArrayList(hir.ExprId).empty;
    try all.append(b.arena, callee_leaf);
    for (args.items) |a| try all.append(b.arena, a);
    const ops = try b.built.program.addOperands(all.items);
    const body = try b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "call"), .ty = rec.ret, .operands = ops });
    b.popScope();
    const rid = try b.built.program.addRegion(binder_ids.items, body, null);
    const regs = try b.built.program.addRegions(&.{rid});
    return b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "lambda"), .ty = try b.funcType(rec.params, rec.ret), .regions = regs });
}
