//! Pass: function, block, and statement lowering — `function-definition`,
//! `block`, `let-statement`, `drop-statement` (Core §5, §9). In: Lowerer +
//! module info + function member / AST statement list. Out: a finalized
//! `cfg.IrFunc` with parameters bound, scoped drops, and explicit moves
//! (air.md §6.4).

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const checker = @import("checker.zig");
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_program = @import("cfg_lower_program.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_pattern = @import("cfg_lower_pattern.zig");
const cfg_lower_validate = @import("cfg_lower_validate.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_path = @import("cfg_lower_path.zig");
const type_resolve = @import("type_resolve.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// Lower one Stilla function member to a `cfg.IrFunc`.
pub fn lowerFunc(self: *Lowerer, info: *moduleinfo.ModuleInfo, vm: *const moduleinfo.ValueMember) LowerError!*cfg.IrFunc {
    const f = switch (vm.decl) {
        .func => |fd| fd,
        else => unreachable,
    };
    const sig = vm.type_.function;
    const qname = try cfg_lower_program.qualifiedName(self, info.specifier, f.name.text);
    var fs = try newFuncState(self, info, .{ .span = f.name.span, .text = qname }, sig.params, sig.ret.*);
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    try fs.scopes.append(self.arena, .{});
    // Bind parameters (the arg values %0..%k-1 were created in
    // newFuncState); borrow-mode params arrive borrowed (air.md §6.2).
    for (sig.params, 0..) |p, i| {
        const v = fs.values.items[i];
        try cfg_lower_emit.bindLocal(self, &fs, p.name.text, v, p.mode != .borrow and cfg_lower_emit.isUnique(self, &fs, v.type_));
    }
    const body = f.body.?;
    return try lowerFuncBody(self, &fs, body);
}

/// Lower one used specialization of a generic function: the monomorphized
/// body clone, annotated under the concrete substitution (phase2-checker.md, Generic expansion),
/// named `{module}.{fn}.{id}`. Generic templates are never lowered — the
/// AIR receives only specialized, monomorphic functions (Core §12, §12.4).
pub fn lowerInstance(self: *Lowerer, info: *moduleinfo.ModuleInfo, inst: *checker.FuncInstance) LowerError!*cfg.IrFunc {
    const mono = inst.mono orelse
        return self.fail(inst.decl.name.span, "host-binding generic has no body to lower", .{});
    const sig = inst.signature.function;
    const qname = try std.fmt.allocPrint(self.arena, "{s}.{d}", .{ try cfg_lower_program.qualifiedName(self, info.specifier, inst.decl.name.text), inst.id });
    var fs = try newFuncState(self, info, .{ .span = mono.name.span, .text = qname }, sig.params, sig.ret.*);
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    try fs.scopes.append(self.arena, .{});
    for (sig.params, 0..) |p, i| {
        const v = fs.values.items[i];
        try cfg_lower_emit.bindLocal(self, &fs, p.name.text, v, p.mode != .borrow and cfg_lower_emit.isUnique(self, &fs, v.type_));
    }
    return try lowerFuncBody(self, &fs, mono.body.?);
}

/// Lower a function body into a fresh FuncState and finish the function
/// (returns, the `T → any` return coercion, and terminators). Shared by
/// `lowerFunc` and `lowerInstance`.
fn lowerFuncBody(self: *Lowerer, fs: *FuncState, body: *const ast.Block) LowerError!*cfg.IrFunc {
    const result = try lowerBlock(self, fs, body);
    try cfg_lower_emit.exitScope(self, fs, result);
    if (result) |r| {
        if (cfg_lower_emit.isVoid(r.type_)) {
            try cfg_lower_emit.setTerminator(self, fs, .{ .ret = null });
        } else {
            // The `T → any` return coercion (Core §11.6, air.md §4.4): a
            // concrete result returned from an `any`-typed function is
            // packed on the return edge like any other call boundary.
            const rv = try coerceRet(self, fs, r);
            cfg_lower_emit.markConsumed(self, fs, rv);
            try cfg_lower_emit.cleanupDisable(self, fs, rv.span, rv);
            try cfg_lower_emit.setTerminator(self, fs, .{ .ret = rv });
        }
    } else {
        // The body terminated (trap); the last block's terminator
        // stands. If the body somehow ended without a terminator,
        // emit a bare ret to keep the CFG well-formed.
        if (fs.cur != null) try cfg_lower_emit.setTerminator(self, fs, .{ .ret = null });
    }
    return cfg_lower_validate.finishFunc(self, fs);
}

/// Pack a concrete return value into an `any`-typed function result
/// (Core §11.6, air.md §4.4): a Copy source is `any_pack_copy`'d, an
/// unique source `any_pack_move`'d (consumed, token disarmed). No-op when
/// the result type already matches the return type.
pub fn coerceRet(self: *Lowerer, fs: *FuncState, r: *cfg.Value) LowerError!*cfg.Value {
    if (!(fs.ret == .primitive and fs.ret.primitive == .any) or cfg.Type.eql(r.type_, fs.ret)) return r;
    if (r.ownership == .unique) {
        const p = (try cfg_lower_emit.emit(self, fs, r.span, .{ .any_pack_move = r }, fs.ret)).?;
        cfg_lower_emit.markConsumed(self, fs, r);
        try cfg_lower_emit.cleanupDisable(self, fs, r.span, r);
        return p;
    }
    return (try cfg_lower_emit.emit(self, fs, r.span, .{ .any_pack_copy = r }, fs.ret)).?;
}

/// Fresh per-function lowering state: blocks under construction, the value
/// table, and ownership bookkeeping (air.md §5.1).
pub fn newFuncState(
    self: *Lowerer,
    module: *moduleinfo.ModuleInfo,
    name: ast.Ident,
    params: []cfg.Param,
    ret: cfg.Type,
) LowerError!FuncState {
    var fs = FuncState{
        .module = module,
        .name = name,
        .params = params,
        .ret = ret,
        .values = .empty,
        .blocks = .empty,
        .block_instrs = .empty,
        .scopes = .empty,
        .local_values = .empty,
        .consumed = .empty,
        .created = .empty,
        .phi_lists = .empty,
    };
    // Parameter values: %0..%k-1, no defining instruction (air.md
    // §5.1); a borrow-mode parameter arrives borrowed with origin
    // `call` — its root is the caller's argument, valid for the whole
    // callee (air.md §6.5).
    for (params) |p| {
        const v = try cfg_lower_emit.newValue(self, &fs, p.span, p.type_, if (p.mode == .borrow) .borrowed else .owned);
        if (p.mode == .borrow) v.origin = .call;
    }
    return fs;
}

/// Lower a block: statements in order, then the optional result
/// expression; the block's scope ends here. Returns null when the
/// block terminated (trap / never) before producing a value.
pub fn lowerBlock(self: *Lowerer, fs: *FuncState, b: *const ast.Block) LowerError!?*cfg.Value {
    try fs.scopes.append(self.arena, .{});
    var result: ?*cfg.Value = null;
    for (b.stmts) |*stmt| {
        if (fs.cur == null) break; // unreachable code after a trap
        switch (stmt.*) {
            .let => |*ls| try lowerLet(self, fs, ls),
            .drop => |*ds| try lowerDrop(self, fs, ds),
            .expr => |*es| {
                const v = (try cfg_lower_expr.lowerExpr(self, fs, &es.expr)) orelse break;
                try cfg_lower_expr.discardValue(self, fs, v);
            },
            .empty => {},
            .using => |*u| try lowerUsing(self, fs, u),
        }
    }
    if (fs.cur != null) {
        if (b.result) |*r| {
            result = try cfg_lower_expr.lowerExpr(self, fs, r);
        } else {
            result = try cfg_lower_expr.emitVoid(self, fs, b.span);
        }
    }
    try cfg_lower_emit.exitScope(self, fs, result);
    return result;
}

/// Lower a `let` binding: reject refutable (type-test) patterns, evaluate
/// the initializer, and bind the pattern's names (Core §14).
pub fn lowerLet(self: *Lowerer, fs: *FuncState, ls: *const ast.LetStmt) LowerError!void {
    // Type-test patterns are refutable and may appear only in `match`
    // (Core §14: `let` and `for` accept only irrefutable patterns).
    if (cfg_lower_pattern.patternHasTypeTest(&ls.pattern)) {
        return self.fail(ls.span, "a type-test pattern is refutable and may appear only in a match", .{});
    }
    const moving = cfg_lower_expr.isMoveExpr(ls.init);
    const init_val = (try cfg_lower_expr.lowerExpr(self, fs, ls.init)) orelse return;
    // A declared `any` binding materializes the top-type coercion at the
    // let (Core §11.6): a Copy source is any_pack_copy'd, a unique source
    // any_pack_move'd — the same pack the call boundary emits (air.md §4.4).
    var bound = init_val;
    if (ls.type_) |*dt| {
        const declared = try self.resolveType(fs, dt);
        if (declared == .primitive and declared.primitive == .any and !cfg.Type.eql(init_val.type_, declared)) {
            const span = init_val.span;
            if (init_val.ownership == .unique) {
                cfg_lower_emit.markConsumed(self, fs, init_val);
                try cfg_lower_emit.cleanupDisable(self, fs, span, init_val);
                bound = (try cfg_lower_emit.emit(self, fs, span, .{ .any_pack_move = init_val }, declared)).?;
            } else {
                bound = (try cfg_lower_emit.emit(self, fs, span, .{ .any_pack_copy = init_val }, declared)).?;
            }
        }
    }
    try cfg_lower_pattern.bindPattern(self, fs, &ls.pattern, bound, moving);
}

/// Lower a block-level `using` alias (Core §2.8, §13.1): a scoped
/// compile-time binding of a module value or a value member (a type
/// alias binds nothing at runtime). The alias names the bound value for
/// the rest of the block; no storage is allocated. Unresolvable aliases
/// are silently skipped, matching the checker (`bindUsing`) and phase 1.
pub fn lowerUsing(self: *Lowerer, fs: *FuncState, u: *const ast.UsingDecl) LowerError!void {
    const alias = u.alias orelse return;
    const target = type_resolve.resolveAliasTarget(self.resolve, fs.module, u) orelse return;
    switch (target) {
        .module => |spec| {
            const v = (try cfg_lower_path.emitModuleRef(self, fs, u.span, spec)) orelse return;
            try cfg_lower_emit.bindLocal(self, fs, alias.text, v, false);
        },
        .value => |mr| {
            const m = self.graph.module(mr.module) orelse return;
            const vm = m.valueMember(mr.name) orelse return;
            const mod_ref = (try cfg_lower_path.emitModuleRef(self, fs, u.span, mr.module)) orelse return;
            const v = (try cfg_lower_path.lowerMemberLoad(self, fs, u.span, mod_ref, vm)) orelse return;
            try cfg_lower_emit.bindLocal(self, fs, alias.text, v, false);
        },
        .type => {},
    }
}

/// Lower a `drop` statement: look up the binding, reject borrowed values,
/// and emit the drop (Core §9).
pub fn lowerDrop(self: *Lowerer, fs: *FuncState, ds: *const ast.DropStmt) LowerError!void {
    const local = cfg_lower_emit.lookupLocal(fs, ds.name.text) orelse
        return self.fail(ds.span, "drop of unknown binding '{s}'", .{ds.name.text});
    if (local.value.state == .borrowed) {
        return self.fail(ds.span, "cannot drop borrowed binding '{s}'", .{ds.name.text});
    }
    try cfg_lower_emit.emitDrop(self, fs, ds.span, local.value);
    local.consumed = true;
}
