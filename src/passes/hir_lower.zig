//! Pass: HIR → CFG AIR lowering (docs/hir.md §9; PROGRESS S5). In:
//! Lowerer + a built HIR program (`hir_build.buildProgram`). Out: the
//! same `cfg.IrProgram` the direct annotated-AST lowering produces —
//! byte-identical `cfg.print` text over the corpus is the §10.3 gate.
//!
//! Split per the cfg convention: this file drives module/function
//! lowering; `hir_lower_expr.zig` lowers expressions, `hir_lower_control.zig`
//! the `if`/`and`/`or`/`match` diamonds, `hir_lower_call.zig` the call
//! forms, and `hir_lower_pattern.zig` pattern binding and tests. The
//! AST-free machinery of the cfg passes (emit bookkeeping, `newFuncState`,
//! `coerceRet`, `emitVoid`/`emitConst`, `lowerCallArg`/`emitCall`/
//! `emitSyscall`/`emitHostCall`, `makeJoinPhi`, `finishFunc`, the
//! intrinsic tables) is reused unchanged, so both paths share one
//! emission discipline.
//!
//! Scope rule (PROGRESS S5 设计定案): a HIR root whose op is `let`/`seq`
//! was an AST block with bindings/statements — the direct lowering pushed
//! a destruction scope for it; every other root (empty or single-result
//! block, bare region) binds nothing and gets no scope. Full-expression
//! boundaries (dropCreatedRange) fire around every lowered operand —
//! exactly where the direct path lowers a sub-expression.
//!
//! M1a limits (recorded): HIR nodes carry no source spans (S4 kept only
//! function-declaration spans), so lowering diagnostics use the zero
//! span; S5's gate is textual equality, and spans never print (air.md §9).

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_func = @import("cfg_lower_func.zig");
const cfg_lower_call = @import("cfg_lower_call.zig");
const cfg_lower_module = @import("cfg_lower_module.zig");
const cfg_lower_program = @import("cfg_lower_program.zig");
const cfg_lower_validate = @import("cfg_lower_validate.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");
const hir_lower_expr = @import("hir_lower_expr.zig");
const hir_lower_control = @import("hir_lower_control.zig");
const hir_lower_call = @import("hir_lower_call.zig");
const hir_lower_pattern = @import("hir_lower_pattern.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// The zero span: HIR nodes carry no source spans in M1a (see header).
pub const no_span = ast.Span.init(0, 0, 0);

/// Per-function lowering context: the built program plus the binder →
/// local map. The cfg `FuncState` stays the single source of emission
/// bookkeeping; `binds` is the only HIR-side extra.
pub const Ctx = struct {
    self: *Lowerer,
    built: *hir.BuiltProgram,
    /// BinderId → lowered local (per function, reset by the driver).
    binds: std.AutoHashMapUnmanaged(hir.BinderId, *lower.Local) = .empty,

    /// The op name of a node (registry identity → registry name).
    pub fn opName(c: *const Ctx, id: hir.ExprId) []const u8 {
        return hir.registry.get(c.built.program.node(id).op).name;
    }

    pub fn node(c: *const Ctx, id: hir.ExprId) hir.ExprNode {
        return c.built.program.node(id);
    }

    pub fn operands(c: *const Ctx, id: hir.ExprId) []hir.ExprId {
        return c.built.program.operands(id);
    }

    pub fn regionsOf(c: *const Ctx, id: hir.ExprId) []hir.RegionId {
        return c.built.program.regionsOf(id);
    }

    /// The binder a `local` node reads.
    pub fn binder(c: *const Ctx, id: hir.ExprId) hir.BinderId {
        return c.node(id).payload.binder;
    }

    /// A lowered local for a binder, or null (internal error — the
    /// builder guarantees every referenced binder is bound).
    pub fn localOf(c: *const Ctx, bid: hir.BinderId) ?*lower.Local {
        return c.binds.get(bid);
    }
};

/// Bind one binder id to a value: a `Local` under a synthetic name
/// (names never print; lookups go through `binds`, not `lookupLocal`).
pub fn bindBinder(c: *Ctx, fs: *FuncState, bid: hir.BinderId, v: *cfg.Value, owns_unique: bool) LowerError!void {
    const name = try std.fmt.allocPrint(c.self.arena, "b{d}", .{bid});
    try cfg_lower_emit.bindLocal(c.self, fs, name, v, owns_unique);
    const local = fs.scopes.items[fs.scopes.items.len - 1].locals.items[
        fs.scopes.items[fs.scopes.items.len - 1].locals.items.len - 1
    ];
    try c.binds.put(c.self.arena, bid, local);
}

/// Lower a whole built program: one `cfg.IrModule` per module record,
/// the flat function list, the type environment, and the host-selected
/// entry — the direct lowering's `lowerProgram` walk, same output shape.
pub fn lowerProgram(self: *Lowerer, built: *hir.BuiltProgram) LowerError!cfg.IrProgram {
    var ir_modules = std.ArrayList(*cfg.IrModule).empty;
    var ir_funcs = std.ArrayList(*cfg.IrFunc).empty;
    for (built.modules.items, 0..) |*bm, mi| {
        const m = try lowerModuleHir(self, built, bm, self.graph.modules[mi]);
        try ir_modules.append(self.arena, m);
        for (m.funcs) |f| try ir_funcs.append(self.arena, f);
    }
    var program = cfg.IrProgram{
        .modules = try self.arena.dupe(*cfg.IrModule, ir_modules.items),
        .funcs = try self.arena.dupe(*cfg.IrFunc, ir_funcs.items),
        .types = try cfg_lower_program.collectTypeEnv(self),
        .entry = null,
    };
    // Host-selected entry: the entry module's function named by
    // `entry_fn` (Runtime §3.3) — the direct lowering's rule verbatim.
    if (self.entry_fn) |want| {
        const qualified = try cfg_lower_program.qualifiedName(self, self.graph.entry.specifier, want);
        for (program.funcs) |f| {
            if (std.mem.eql(u8, f.name.text, qualified)) {
                program.entry = f;
                break;
            }
        }
        if (program.entry == null and self.entry_fn_explicit) {
            return self.fail(no_span, "entry function '{s}' not found in module '{s}'", .{ want, self.graph.entry.specifier });
        }
    }
    return program;
}

/// Lower one module: `@init`, every function record in cfg emission
/// order (the record table *is* that order — see hir_build's
/// `buildModuleFuncs`), then slots and the member table, mirroring
/// the direct `lowerModule` rules row for row.
fn lowerModuleHir(self: *Lowerer, built: *hir.BuiltProgram, bm: *const hir.BuiltModule, info: *moduleinfo.ModuleInfo) LowerError!*cfg.IrModule {
    const m = try self.arena.create(cfg.IrModule);
    var funcs = std.ArrayList(*cfg.IrFunc).empty;
    var init_func: ?*cfg.IrFunc = null;

    // @init — same rule as the direct lowering: every source /
    // standard-library module except `builtin` (air.md §11).
    const has_init = info.kind != .host and !std.mem.eql(u8, info.specifier, "builtin");
    if (has_init) {
        init_func = try lowerInitHir(self, built, info, bm);
        try funcs.append(self.arena, init_func.?);
    }
    for (built.funcs.items[bm.funcs.start..][0..bm.funcs.len]) |*rec| {
        if (rec.kind == .init) continue; // lowered above (or absent)
        try funcs.append(self.arena, try lowerFuncRecord(self, built, info, rec));
    }

    // Storage layout: slot-bearing constants in declaration order.
    var slots = std.ArrayList(cfg.SlotMeta).empty;
    for (info.values) |*vm| {
        if (cfg_lower_module.constSlot(info, vm) != null) {
            try slots.append(self.arena, .{ .type_ = vm.type_ });
        }
    }
    // Member table: one row per runtime value member, intrinsics
    // excluded (air.md §5.6, §7).
    var members = std.ArrayList(cfg.ModuleMember).empty;
    for (info.values) |*vm| {
        if (info.isIntrinsic(vm)) continue;
        const kind: cfg.MemberKind = switch (vm.decl) {
            .func => |f| blk: {
                if (vm.host) break :blk .host_binding;
                if (f.type_params.len != 0) break :blk .{ .function = null };
                const qname = try cfg_lower_program.qualifiedName(self, info.specifier, vm.name.text);
                break :blk .{ .function = findFunc(funcs.items, qname) };
            },
            .const_ => blk: {
                if (vm.module_spec) |spec| break :blk .{ .module_ref = spec };
                break :blk .{ .const_slot = cfg_lower_module.constSlot(info, vm) };
            },
        };
        try members.append(self.arena, .{ .name = vm.name.text, .type_ = vm.type_, .kind = kind });
    }
    m.* = .{
        .span = no_span,
        .name = info.specifier,
        .init = init_func,
        .funcs = try self.arena.dupe(*cfg.IrFunc, funcs.items),
        .members = try self.arena.dupe(cfg.ModuleMember, members.items),
        .slots = try self.arena.dupe(cfg.SlotMeta, slots.items),
    };
    return m;
}

fn findFunc(funcs: []*cfg.IrFunc, name: []const u8) ?*cfg.IrFunc {
    for (funcs) |f| {
        if (std.mem.eql(u8, f.name.text, name)) return f;
    }
    return null;
}

/// The module init: evaluate each slot-bearing constant's HIR tree in
/// declaration order and `store_member` it — the direct `lowerInit`
/// walk over the const records (`buildInitBody` stores no tree on the
/// init record itself; the initializers live on the const records).
fn lowerInitHir(self: *Lowerer, built: *hir.BuiltProgram, info: *moduleinfo.ModuleInfo, bm: *const hir.BuiltModule) LowerError!*cfg.IrFunc {
    var fs = try cfg_lower_func.newFuncState(self, info, .{ .span = no_span, .text = "init" }, &.{}, .{ .primitive = .void });
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    var c = Ctx{ .self = self, .built = built };
    for (built.consts.items[bm.consts.start..][0..bm.consts.len]) |*rec| {
        // Module-valued members resolve statically; never stored.
        if (rec.module_spec != null) continue;
        const root = rec.init orelse continue;
        const v = (try hir_lower_expr.expr(&c, &fs, root)) orelse break; // unreachable init: @init traps there
        if (cfg_lower_emit.isVoid(v.type_)) continue; // no observable value, nothing stored
        const slot = rec.slot orelse continue;
        _ = try cfg_lower_emit.emit(self, &fs, no_span, .{ .store_member = .{ .slot = slot, .value = v } }, null);
    }
    try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
    return cfg_lower_validate.finishFunc(self, &fs);
}

/// True when a HIR root is block-shaped (the direct lowering pushed a
/// destruction scope around it): `let` chains and statement sequences.
pub fn rootIsBlockShaped(c: *const Ctx, id: hir.ExprId) bool {
    const name = c.opName(id);
    return std.mem.eql(u8, name, "let") or std.mem.eql(u8, name, "seq");
}

/// Lower one function record to a finalized `cfg.IrFunc`. The record's
/// root is a `lambda` node whose region params are the function's
/// params and whose region root is the body — the same shape a source
/// `λ` lowers to, so member functions, instances, hooks, hoisted
/// lambdas, and intrinsic wrappers share this one path.
fn lowerFuncRecord(self: *Lowerer, built: *hir.BuiltProgram, info: *moduleinfo.ModuleInfo, rec: *const hir.FuncRecord) LowerError!*cfg.IrFunc {
    var fs = try cfg_lower_func.newFuncState(self, info, .{ .span = no_span, .text = rec.name }, rec.params, rec.ret);
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    var c = Ctx{ .self = self, .built = built };

    std.debug.assert(std.mem.eql(u8, c.opName(rec.root), "lambda"));
    const rid = c.regionsOf(rec.root)[0];
    const region = built.program.region(rid);
    const binder_ids = built.program.params(rid);

    if (rec.kind == .intrinsic) {
        // A first-class intrinsic wrapper (intrinsic plan, phase 3):
        // the body forwards the parameters raw to the host syscall —
        // no arg lowering, no effective modes, no ownership scopes
        // (the moved-in arguments transfer at the call boundary; the
        // direct `synthIntrinsicFunc` binds no locals either). The
        // syscall signature is the wrapper's own (specialized) one.
        for (binder_ids, 0..) |bid, i| {
            try bindBinder(&c, &fs, bid, fs.values.items[i], false);
        }
        const call_id = region.root;
        const call_ops = c.operands(call_id);
        const callee_id = call_ops[0];
        const callee = c.node(callee_id);
        const hid = callee.payload.func.host;
        const host = built.hosts.items[hid];
        const hinfo = self.graph.modules[host.module];
        var args = std.ArrayList(*cfg.Value).empty;
        for (call_ops[1..]) |arg_id| {
            const arg_node = c.node(arg_id);
            const bid = arg_node.payload.binder;
            const local = c.localOf(bid) orelse return self.fail(no_span, "wrapper parameter not bound", .{});
            if (cfg_lower_emit.isVoid(local.value.type_)) continue;
            try args.append(self.arena, local.value);
        }
        const sig = cfg.FunctionType{ .params = rec.params, .ret = dupType(self, rec.ret) };
        // The str/hash supported-type constraint applies to the wrapper
        // too — mirror `cfg_lower_intrinsic.intrinsicFnRef`, which checks
        // before synthesizing (Runtime §4.2/§4.9): a wrapper would carry
        // a signature the host cannot serve.
        if (cfg_lower_intrinsic.isConstrainedMember(hinfo.specifier, host.name)) {
            try cfg_lower_intrinsic.checkStrHashSignature(self, no_span, host.name, sig);
        }
        const result = try cfg_lower_call.emitSyscall(self, &fs, no_span, try cfg_lower_intrinsic.syscallTarget(self, no_span, hinfo.specifier, host.name), args.items, sig);
        // Return shape mirrors the direct `synthIntrinsicFunc`: the
        // syscall result is returned (a wrapper carries the concrete
        // specialized signature — no any coercion, no scope), a void
        // result falls through to a bare ret, and a never-returning
        // expansion (e.g. `panic`) traps inside the wrapper.
        if (result) |r| {
            if (cfg_lower_emit.isVoid(r.type_)) {
                try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
            } else {
                cfg_lower_emit.markConsumed(self, &fs, r);
                try cfg_lower_emit.cleanupDisable(self, &fs, r.span, r);
                try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = r });
            }
        } else if (fs.cur != null) {
            try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
        }
        return cfg_lower_validate.finishFunc(self, &fs);
    }

    // Params scope: bound exactly like the direct lowering (borrow-mode
    // params arrive borrowed; unique params are owned by the binding).
    try fs.scopes.append(self.arena, .{});
    for (binder_ids, 0..) |bid, i| {
        const p = rec.params[i];
        const v = fs.values.items[i];
        try bindBinder(&c, &fs, bid, v, p.mode != .borrow and cfg_lower_emit.isUnique(self, &fs, v.type_));
    }
    // Body scope: block-shaped roots (let/seq) were AST blocks with
    // bindings; everything else binds nothing and needs no scope.
    const body = region.root;
    const push_body = rootIsBlockShaped(&c, body);
    if (push_body) try fs.scopes.append(self.arena, .{});
    const result = try hir_lower_expr.expr(&c, &fs, body);
    if (push_body) try cfg_lower_emit.exitScope(self, &fs, result);
    try cfg_lower_emit.exitScope(self, &fs, result);

    if (rec.kind == .drop_hook) {
        // A hook is a void sequence (Core §9.1): a trailing non-void
        // value is discarded (borrowed views skip the drop rules), then
        // a bare ret — the direct `lowerDropHook` tail, not the
        // function tail (which would `ret` the value).
        if (result) |r| {
            if (!cfg_lower_emit.isVoid(r.type_)) try cfg_lower_expr.discardValue(self, &fs, r);
        }
        if (fs.cur != null) try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
    } else if (result) |r| {
        if (cfg_lower_emit.isVoid(r.type_)) {
            try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
        } else {
            // The `T → any` return coercion (Core §11.6, air.md §4.4).
            const rv = try cfg_lower_func.coerceRet(self, &fs, r);
            cfg_lower_emit.markConsumed(self, &fs, rv);
            try cfg_lower_emit.cleanupDisable(self, &fs, rv.span, rv);
            try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = rv });
        }
    } else {
        // The body terminated (trap); a trailing unterminated block
        // gets a bare ret to keep the CFG well-formed.
        if (fs.cur != null) try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
    }
    return cfg_lower_validate.finishFunc(self, &fs);
}

/// An arena copy of a type (syscall signatures own their ret pointer).
fn dupType(self: *Lowerer, t: cfg.Type) *cfg.Type {
    const p = self.arena.create(cfg.Type) catch unreachable;
    p.* = t;
    return p;
}
