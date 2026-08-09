//! Pass: module lowering — `module` (Core §2, air.md §11). In: Lowerer +
//! module info. Out: an `cfg.IrModule` with slots, an `@init` function that
//! stores module constants, and drop-hook functions for user `drop`
//! declarations.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_func = @import("cfg_lower_func.zig");
const cfg_lower_program = @import("cfg_lower_program.zig");
const cfg_lower_validate = @import("cfg_lower_validate.zig");
const cfg_lower_path = @import("cfg_lower_path.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

pub fn lowerModule(self: *Lowerer, info: *moduleinfo.ModuleInfo) LowerError!*cfg.IrModule {
    const m = try self.arena.create(cfg.IrModule);
    var funcs = std.ArrayList(*cfg.IrFunc).empty;
    self.lambda_funcs.clearRetainingCapacity();
    self.intrinsic_funcs.clearRetainingCapacity();
    var init_func: ?*cfg.IrFunc = null;
    // Every source / standard-library module has an @init, even when
    // empty — except `builtin`, whose members are all host bindings
    // with nothing to evaluate (air.md §11: init is null for host
    // modules and builtin; phase3-cfg-lowering.md, Module init functions).
    if (info.kind != .host and !std.mem.eql(u8, info.specifier, "builtin")) {
        init_func = try lowerInit(self, info);
        try funcs.append(self.arena, init_func.?);
    }
    // Lower every function member. Generic functions are compile-time
    // templates (Core §12.4): their templates are never lowered; each used
    // specialization is lowered below from its monomorphized body clone.
    for (info.values) |*vm| switch (vm.decl) {
        .func => |f| if (f.body != null and f.type_params.len == 0) {
            const ir = try cfg_lower_func.lowerFunc(self, info, vm);
            try funcs.append(self.arena, ir);
        },
        else => {},
    };
    // The used specializations of generic functions declared by this
    // module (phase2-checker.md, Generic expansion): each is a monomorphic function named
    // `{module}.{fn}.{id}` (air.md §11). Host bindings have no body
    // (`mono == null`) and are never lowered here.
    if (self.ann) |a| {
        for (a.instances.items) |inst| {
            if (inst.module != info) continue;
            if (inst.mono == null) continue;
            const ir = try cfg_lower_func.lowerInstance(self, info, inst);
            try funcs.append(self.arena, ir);
        }
    }
    // Drop hooks (Core §9.1): a struct's `drop(file) { … }` body is
    // compiled as a hidden per-type function so its code is typechecked
    // and lowered like any other function. `drop %v` of such a struct
    // stays a single unexpanded instruction (air.md §6.4); the runtime
    // invokes this function as part of the destruction sequence
    // (Runtime §6.2). Generic structs cannot carry hooks: phase 2
    // rejects them at the declaration (checker_annotate), because
    // monomorphize specializes function templates only and there is no
    // per-specialization hook to lower here.
    for (info.types) |*tm| {
        switch (tm.decl) {
            .struct_ => |s| if (s.drop) |d| {
                if (tm.generic) continue;
                const ir = try lowerDropHook(self, info, s, d);
                try funcs.append(self.arena, ir);
            },
            else => {},
        }
    }
    // Lambda literals hoisted during member/drop-hook lowering
    // (air.md §5.5) join the module's function list.
    for (self.lambda_funcs.items) |lf| try funcs.append(self.arena, lf);
    // First-class intrinsic wrappers synthesized while lowering this
    // module (intrinsic plan, phase 3) join it likewise — no member row.
    for (self.intrinsic_funcs.items) |wf| try funcs.append(self.arena, wf);
    // Module storage layout: the constant members only, in const
    // declaration order (air.md §7, Runtime §2.2). Function, module, and
    // host-binding members are static references and occupy no storage.
    // Intrinsic constants carry no storage slot either (air.md §5.6,
    // Intrinsics §3): they materialize at use sites, so `math`'s slots
    // are empty.
    var slots = std.ArrayList(cfg.SlotMeta).empty;
    for (info.values) |*vm| {
        if (constSlot(info, vm)) |slot| {
            try slots.append(self.arena, .{ .type_ = vm.*.type_, .init_order = slot });
        }
    }
    // The member table (air.md §7, §9.6): one row per runtime value
    // member in declaration order — the `load_member` operand space,
    // indexed by the compacted canonical index (`airMemberIndex`, not
    // the source-level `ValueMember.slot`). Function,
    // module-valued, and host-binding members are static references and
    // occupy no storage; a constant member's storage slot is a *distinct
    // index space* from its member index (air.md §7). Intrinsic members
    // occupy no row (air.md §5.6): constants materialize at use sites
    // and functions are direct syscalls or synthesized first-class
    // wrappers, so the member table holds the remaining members with
    // compacted indexes (`airMemberIndex`).
    var members = std.ArrayList(cfg.ModuleMember).empty;
    for (info.values) |*vm| {
        if (info.isIntrinsic(vm)) continue;
        const kind: cfg.MemberKind = switch (vm.decl) {
            .func => |f| blk: {
                if (vm.host) break :blk .host_binding;
                // A non-generic Stilla function member lowers to one
                // `IrFunc` named `{spec}.{fn}`; a generic template is
                // never lowered (each used specialization is a separate
                // `IrFunc`, air.md §11), so its row carries a null
                // function reference.
                if (f.type_params.len != 0) break :blk .{ .function = null };
                const qname = try cfg_lower_program.qualifiedName(self, info.specifier, vm.name.text);
                break :blk .{ .function = findFunc(funcs.items, qname) };
            },
            .const_ => |c| blk: {
                _ = c;
                // Module-valued members resolve statically (their
                // specifier); void-typed constants occupy no storage
                // (`constSlot` null).
                if (vm.module_spec) |spec| break :blk .{ .module_ref = spec };
                break :blk .{ .const_slot = constSlot(info, vm) };
            },
        };
        try members.append(self.arena, .{ .name = vm.name.text, .type_ = vm.type_, .kind = kind });
    }
    m.* = .{
        .span = ast.Span.init(0, 0, 0),
        .name = info.specifier,
        .init = init_func,
        .funcs = try self.arena.dupe(*cfg.IrFunc, funcs.items),
        .members = try self.arena.dupe(cfg.ModuleMember, members.items),
        .slots = try self.arena.dupe(cfg.SlotMeta, slots.items),
    };
    return m;
}

/// The lowered `IrFunc` of a qualified function name, or null when the
/// name is not among the module's lowered functions (a generic template).
fn findFunc(funcs: []*cfg.IrFunc, name: []const u8) ?*cfg.IrFunc {
    for (funcs) |f| {
        if (std.mem.eql(u8, f.name.text, name)) return f;
    }
    return null;
}

/// The storage slot of a constant member: its position among the
/// module's slot-bearing constant members (air.md §7). Module-valued
/// members (static references), void-typed constants, and intrinsic
/// constants (materialized at use sites, air.md §5.6) occupy no
/// storage; `null` when `vm` is not a slot-bearing const.
fn constSlot(info: *moduleinfo.ModuleInfo, vm: *const moduleinfo.ValueMember) ?u32 {
    var n: u32 = 0;
    for (info.values) |*v| {
        if (v == vm) {
            return switch (v.decl) {
                .const_ => |c| blk: {
                    _ = c;
                    if (info.isIntrinsic(v)) break :blk null;
                    if (v.module_spec == null and !cfg_lower_emit.isVoid(v.type_)) break :blk n else break :blk null;
                },
                .func => null,
            };
        }
        switch (v.decl) {
            .const_ => |c| {
                _ = c;
                if (info.isIntrinsic(v)) continue;
                if (v.module_spec == null and !cfg_lower_emit.isVoid(v.type_)) n += 1;
            },
            else => {},
        }
    }
    return null;
}

/// The module init function: evaluate module constants strictly in
/// declaration order and `store_member` each into its slot; module
/// values arrive as `module_ref` (air.md §7, Runtime §2.3).
pub fn lowerInit(self: *Lowerer, info: *moduleinfo.ModuleInfo) LowerError!*cfg.IrFunc {
    var fs = try cfg_lower_func.newFuncState(self, info, .{ .span = ast.Span.init(info.source.?.id, 0, 0), .text = "init" }, &.{}, .{ .primitive = .void });
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    for (info.values) |*vm| {
        switch (vm.*.decl) {
            .const_ => |c| if (c.init != null) {
                // Module-valued members resolve statically and are never
                // stored (air.md §7); they arrive at use sites as
                // `module_ref` through `load_member`.
                if (vm.*.module_spec != null) continue;
                const value = try cfg_lower_expr.lowerExpr(self, &fs, c.init.?);
                if (value) |v| {
                    // A void-typed constant has no observable value and
                    // its value is a phantom (no defining instruction);
                    // storing it would leave a dangling operand, so
                    // nothing is stored for it (phase3-cfg-lowering.md, Lowering rules).
                    if (cfg_lower_emit.isVoid(v.type_)) continue;
                    const slot = constSlot(info, vm) orelse continue;
                    _ = try cfg_lower_emit.emit(self, &fs, c.span, .{ .store_member = .{ .slot = slot, .value = v } }, null);
                } else {
                    // The constant's initializer is unreachable
                    // (e.g. `builtin.panic`); @init traps there.
                    break;
                }
            },
            else => {},
        }
    }
    try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
    return cfg_lower_validate.finishFunc(self, &fs);
}

/// Compile a struct's user `drop` hook (Core §9.1). The single
/// parameter arrives as a borrowed *destruction view* of the complete
/// object (Core §9.2): borrow-mode semantics make moving, explicitly
/// dropping, or returning the view a compile error, and projections of
/// an unique base arrive borrowed, so ownership cannot leave the hook.
/// The hook function is hidden (`<module>.<Type>.drop`); `drop %v` of
/// the struct stays one unexpanded instruction (air.md §6.4) and the
/// runtime calls this function during destruction (Runtime §6.2).
pub fn lowerDropHook(self: *Lowerer, info: *moduleinfo.ModuleInfo, s: *const ast.StructDef, d: *const ast.DropDecl) LowerError!*cfg.IrFunc {
    const qname = try std.fmt.allocPrint(self.arena, "{s}.{s}.drop", .{ info.specifier, s.name.text });
    const params = try self.arena.alloc(cfg.Param, 1);
    params[0] = .{
        .span = d.param.span,
        .name = d.param,
        .mode = .borrow,
        .type_ = .{ .named = .{ .id = (moduleinfo.resolveTypeId(self.resolve, info, s.name.text) orelse return self.fail(d.span, "drop hook type unresolved", .{})), .args = &.{} } },
    };
    var fs = try cfg_lower_func.newFuncState(self, info, .{ .span = d.span, .text = qname }, params, .{ .primitive = .void });
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    try fs.scopes.append(self.arena, .{});
    // The destruction view arrives borrowed: owns_unique=false so
    // scope-end destruction never drops the view itself.
    const view = fs.values.items[0];
    try cfg_lower_emit.bindLocal(self, &fs, d.param.text, view, false);
    const result = try cfg_lower_func.lowerBlock(self, &fs, d.body);
    try cfg_lower_emit.exitScope(self, &fs, result);
    // A hook is a void sequence; a trailing non-void value is
    // discarded (borrowed views are skipped by the drop rules).
    if (result) |r| {
        if (!cfg_lower_emit.isVoid(r.type_)) try cfg_lower_expr.discardValue(self, &fs, r);
    }
    if (fs.cur != null) try cfg_lower_emit.setTerminator(self, &fs, .{ .ret = null });
    return cfg_lower_validate.finishFunc(self, &fs);
}
