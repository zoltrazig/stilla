//! Pass: module lowering — `module` (Core §2, ir.md §11). In: Lowerer +
//! module info. Out: an `cfg.IrModule` with slots, an `@init` function that
//! stores module constants, and drop-hook functions for user `drop`
//! declarations.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const lower = @import("../lower.zig");
const cfg_lower_func = @import("cfg_lower_func.zig");
const cfg_lower_validate = @import("cfg_lower_validate.zig");
const cfg_lower_path = @import("cfg_lower_path.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

pub fn lowerModule(self: *Lowerer, info: *moduleinfo.ModuleInfo) LowerError!*cfg.IrModule {
    const m = try self.arena.create(cfg.IrModule);
    var funcs = std.ArrayListUnmanaged(*cfg.IrFunc).empty;
    self.lambda_funcs.clearRetainingCapacity();
    var init_func: ?*cfg.IrFunc = null;
    // Every source / standard-library module has an @init, even when
    // empty — except `builtin`, whose members are all host bindings
    // with nothing to evaluate (ir.md §11: init is null for host
    // modules and builtin; frontend §5.5).
    if (info.kind != .host and !std.mem.eql(u8, info.specifier, "builtin")) {
        init_func = try lowerInit(self, info);
        try funcs.append(self.arena, init_func.?);
    }
    for (info.values) |*vm| switch (vm.decl) {
        .func => |f| if (f.body != null) {
            const ir = try cfg_lower_func.lowerFunc(self, info, vm);
            try funcs.append(self.arena, ir);
        },
        else => {},
    };
    // Drop hooks (Core §9.1): a struct's `drop(file) { … }` body is
    // compiled as a hidden per-type function so its code is typechecked
    // and lowered like any other function. `drop %v` of such a struct
    // stays a single unexpanded instruction (ir.md §6.4); the runtime
    // invokes this function as part of the destruction sequence
    // (Runtime §6.2). Generic templates are specialized (and their
    // hooks lowered) by phase 2 (Core §12).
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
    // (ir.md §5.5) join the module's function list.
    for (self.lambda_funcs.items) |lf| try funcs.append(self.arena, lf);
    // Module storage layout: one slot per value member, in
    // declaration order (Core §2.1, Runtime §2.2). Function slots are
    // metadata (the runtime fills them with function values); @init
    // stores the constant slots.
    var slots = std.ArrayListUnmanaged(cfg.SlotMeta).empty;
    for (info.values) |vm| {
        try slots.append(self.arena, .{ .type_ = vm.type_, .init_order = vm.slot });
    }
    m.* = .{
        .span = ast.Span.init(0, 0, 0),
        .name = info.specifier,
        .init = init_func,
        .funcs = try self.arena.dupe(*cfg.IrFunc, funcs.items),
        .slots = try self.arena.dupe(cfg.SlotMeta, slots.items),
    };
    return m;
}

/// The module init function: evaluate module constants strictly in
/// declaration order and `store_member` each into its slot; module
/// values arrive as `module_ref` (ir.md §7, Runtime §2.3).
pub fn lowerInit(self: *Lowerer, info: *moduleinfo.ModuleInfo) LowerError!*cfg.IrFunc {
    var fs = try cfg_lower_func.newFuncState(self, info, .{ .span = ast.Span.init(info.source.?.id, 0, 0), .text = "init" }, &.{}, .{ .primitive = .void });
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    for (info.values) |vm| {
        switch (vm.decl) {
            .const_ => |c| if (c.init != null) {
                var value: ?*cfg.Value = null;
                if (vm.module_spec) |spec| {
                    value = try cfg_lower_path.emitModuleRef(self, &fs, c.span, spec);
                } else {
                    value = try cfg_lower_expr.lowerExpr(self, &fs, c.init.?);
                }
                if (value) |v| {
                    // A void-typed constant has no observable value and
                    // its value is a phantom (no defining instruction);
                    // storing it would leave a dangling operand, so
                    // nothing is stored for it (frontend.md §4.1, §5.3).
                    if (cfg_lower_emit.isVoid(v.type_)) continue;
                    _ = try cfg_lower_emit.emit(self, &fs, c.span, .{ .store_member = .{ .slot = vm.slot, .value = v } }, null);
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
/// an affine base arrive borrowed, so ownership cannot leave the hook.
/// The hook function is hidden (`<module>.<Type>.drop`); `drop %v` of
/// the struct stays one unexpanded instruction (ir.md §6.4) and the
/// runtime calls this function during destruction (Runtime §6.2).
pub fn lowerDropHook(self: *Lowerer, info: *moduleinfo.ModuleInfo, s: *const ast.StructDef, d: *const ast.DropDecl) LowerError!*cfg.IrFunc {
    const qname = try std.fmt.allocPrint(self.arena, "{s}.{s}.drop", .{ info.specifier, s.name.text });
    const params = try self.arena.alloc(cfg.Param, 1);
    params[0] = .{
        .span = d.param.span,
        .name = d.param,
        .mode = .borrow,
        .type_ = .{ .named = s.name.text },
    };
    var fs = try cfg_lower_func.newFuncState(self, info, .{ .span = d.span, .text = qname }, params, .{ .primitive = .void });
    const entry = try cfg_lower_emit.newBlock(self, &fs, "entry");
    fs.cur = entry;
    try fs.scopes.append(self.arena, .{});
    // The destruction view arrives borrowed: owns_affine=false so
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
