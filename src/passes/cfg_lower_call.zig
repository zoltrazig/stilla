//! Pass: call lowering — `call-expression` (Core §12). In: Lowerer +
//! FuncState + ast.Call + resolved callee. Out: a `call` or `syscall`
//! instruction (with parameter modes applied at the call site).
const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const lower = @import("../lower.zig");
const cfg_lower_program = @import("cfg_lower_program.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// A call expression: resolve the callee, lower the arguments with their
/// parameter modes, and emit a direct, value, or host call.
pub fn lowerCall(self: *Lowerer, fs: *FuncState, e: *const ast.Call) LowerError!?*cfg.Value {
    // Peel `::[...]` specialization wrappers (Core §12.3); the
    // specialization is applied to the callee's signature below.
    var callee = e.callee;
    while (true) switch (callee.*) {
        .specialize => |s| callee = s.operand,
        else => break,
    };
    switch (callee.*) {
        .path => |p| {
            if (p.tail == .none) {
                if (moduleinfo.resolvePathTarget(self.resolve, fs.module, p.path)) |target| {
                    switch (target.vm.decl) {
                        .func => |f| {
                            if (f.body == null) {
                                // Host binding: a system call, never
                                // an in-IR call (frontend §5.6).
                                return try lowerHostCall(self, fs, e, target);
                            }
                            return try lowerDirectCall(self, fs, e, target);
                        },
                        .const_ => {},
                    }
                }
            }
            // A function value in callee position.
            const fv = (try cfg_lower_expr.lowerExpr(self, fs, callee)) orelse return null;
            return try lowerValueCall(self, fs, e, fv);
        },
        else => {
            const fv = (try cfg_lower_expr.lowerExpr(self, fs, callee)) orelse return null;
            return try lowerValueCall(self, fs, e, fv);
        },
    }
}

/// A call to a Stilla function member: a direct call to the
/// function's `IrFunc` (qualified name; resolved by
/// `IrProgram.resolveDirectCalls`).
pub fn lowerDirectCall(self: *Lowerer, fs: *FuncState, e: *const ast.Call, target: moduleinfo.PathTarget) LowerError!?*cfg.Value {
    const vm = target.vm;
    const sig = vm.type_.function;
    var args = std.ArrayListUnmanaged(*cfg.Value).empty;
    var arg_types = std.ArrayListUnmanaged(cfg.Type).empty;
    for (e.args, 0..) |*arg, i| {
        const av = (try cfg_lower_expr.lowerExpr(self, fs, arg)) orelse return null;
        const mode = if (i < sig.params.len) sig.params[i].mode else .plain;
        const expected = if (i < sig.params.len) sig.params[i].type_ else cfg.Type{ .primitive = .any };
        const a2 = try lowerCallArg(self, fs, av, mode, expected);
        try args.append(self.arena, a2);
        try arg_types.append(self.arena, a2.type_);
    }
    // Generic signatures are specialized from the argument types
    // (frontend §4.4) — or, for a generic call, taken from the checker's
    // recorded `FuncInstance` signature, which honors explicit `::[...]`
    // arguments the argument types alone cannot express.
    const ret = try specializedRet(self, fs, e, vm.type_, arg_types.items);
    // A generic call targets the used specialization's monomorphic
    // function (`{module}.{fn}.{id}`); a non-generic call targets the
    // function directly (ir.md §11).
    const qname = blk: {
        if (self.ann) |a| {
            if (a.per_module.get(fs.module.specifier)) |ma| {
                if (ma.call_of.get(e)) |inst| {
                    break :blk try instanceName(self, target.module.specifier, vm.name.text, inst.id);
                }
            }
        }
        break :blk try cfg_lower_program.qualifiedName(self, target.module.specifier, vm.name.text);
    };
    return try emitCall(self, fs, e.span, .{ .direct = .{ .name = qname } }, args.items, ret);
}

/// The IR name of a generic function's used specialization: the
/// declaration's qualified name with the instance's id suffix
/// (`iter.fold_with.3`). Deterministic and unique per program — the id is
/// the instance's index in the checker's `Annotation.instances` (ir.md
/// §11).
pub fn instanceName(self: *Lowerer, module_spec: []const u8, fn_name: []const u8, id: u32) LowerError![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}.{d}", .{ try cfg_lower_program.qualifiedName(self, module_spec, fn_name), id });
}

/// A call through a function value (a `load_member`d function, a
/// function-typed local, or a parameter).
pub fn lowerValueCall(self: *Lowerer, fs: *FuncState, e: *const ast.Call, fv: *cfg.Value) LowerError!?*cfg.Value {
    const ft = switch (fv.type_) {
        .function => |ft| ft,
        else => return self.fail(e.span, "calling a non-function value", .{}),
    };
    var args = std.ArrayListUnmanaged(*cfg.Value).empty;
    var arg_types = std.ArrayListUnmanaged(cfg.Type).empty;
    for (e.args, 0..) |*arg, i| {
        const av = (try cfg_lower_expr.lowerExpr(self, fs, arg)) orelse return null;
        const mode = if (i < ft.params.len) ft.params[i].mode else .plain;
        const expected = if (i < ft.params.len) ft.params[i].type_ else cfg.Type{ .primitive = .any };
        const a2 = try lowerCallArg(self, fs, av, mode, expected);
        try args.append(self.arena, a2);
        try arg_types.append(self.arena, a2.type_);
    }
    const specialized = moduleinfo.specializeSignature(self.resolve, fs.module, ft, arg_types.items);
    const ret = switch (specialized) {
        .function => |sft| sft.ret.*,
        else => return self.fail(e.span, "callee is not a function", .{}),
    };
    return try emitCall(self, fs, e.span, .{ .value = fv }, args.items, ret);
}

/// The concrete return type of a call: the checker's recorded
/// `FuncInstance` signature when the call is a generic specialization
/// (explicit or inferred, Core §12.2/§12.3), otherwise the signature
/// specialized from the argument types.
pub fn specializedRet(self: *Lowerer, fs: *FuncState, e: *const ast.Call, sig: cfg.Type, arg_types: []const cfg.Type) LowerError!cfg.Type {
    if (self.ann) |a| {
        if (a.per_module.get(fs.module.specifier)) |ma| {
            if (ma.call_of.get(e)) |inst| {
                if (inst.signature == .function) return inst.signature.function.ret.*;
            }
        }
    }
    const specialized = moduleinfo.specializeSignature(self.resolve, fs.module, sig.function, arg_types);
    return switch (specialized) {
        .function => |sft| sft.ret.*,
        else => self.fail(e.span, "callee is not a function", .{}),
    };
}

/// A call to a host binding: a `syscall` instruction carrying the
/// resolved concrete signature (frontend §5.6, ir.md §8.2).
pub fn lowerHostCall(self: *Lowerer, fs: *FuncState, e: *const ast.Call, target: moduleinfo.PathTarget) LowerError!?*cfg.Value {
    const vm = target.vm;
    const sig = vm.type_.function;
    var args = std.ArrayListUnmanaged(*cfg.Value).empty;
    var arg_types = std.ArrayListUnmanaged(cfg.Type).empty;
    for (e.args, 0..) |*arg, i| {
        const av = (try cfg_lower_expr.lowerExpr(self, fs, arg)) orelse return null;
        const mode = if (i < sig.params.len) sig.params[i].mode else .plain;
        const expected = if (i < sig.params.len) sig.params[i].type_ else cfg.Type{ .primitive = .any };
        const a2 = try lowerCallArg(self, fs, av, mode, expected);
        try args.append(self.arena, a2);
        try arg_types.append(self.arena, a2.type_);
    }
    const ret = try specializedRet(self, fs, e, vm.type_, arg_types.items);
    // The syscall target dispatches on (module, member) — stable,
    // because module member layout is static (Core §2.1).
    const call_target: cfg.SysCallTarget = if (std.mem.eql(u8, target.module.specifier, "builtin"))
        .{ .builtin = std.meta.stringToEnum(cfg.BuiltinId, vm.name.text) orelse
            return self.fail(e.span, "unknown builtin member '{s}'", .{vm.name.text}) }
    else
        .{ .host_module = .{ .module = target.module.specifier, .member = vm.name.text } };
    return try emitSyscall(self, fs, e.span, call_target, args.items, ret);
}

/// Emit a `call` instruction, trapping when the callee is `never`.
pub fn emitCall(self: *Lowerer, fs: *FuncState, span: ast.Span, callee: cfg.Callee, args: []*cfg.Value, ret: cfg.Type) LowerError!?*cfg.Value {
    if (cfg_lower_emit.isNever(ret)) {
        _ = try cfg_lower_emit.emit(self, fs, span, .{ .call = .{ .callee = callee, .args = args } }, null);
        try cfg_lower_emit.setTerminator(self, fs, .trap);
        return null;
    }
    if (cfg_lower_emit.isVoid(ret)) {
        _ = try cfg_lower_emit.emit(self, fs, span, .{ .call = .{ .callee = callee, .args = args } }, null);
        return try cfg_lower_expr.emitVoid(self, fs, span);
    }
    return try cfg_lower_emit.emit(self, fs, span, .{ .call = .{ .callee = callee, .args = args } }, ret);
}

/// Emit a `syscall` instruction, trapping when the host binding is
/// `never` (no destruction runs after it — Runtime §7.1, ir.md §8.3).
pub fn emitSyscall(self: *Lowerer, fs: *FuncState, span: ast.Span, target: cfg.SysCallTarget, args: []*cfg.Value, ret: cfg.Type) LowerError!?*cfg.Value {
    if (cfg_lower_emit.isNever(ret)) {
        // `builtin.panic` and friends: the call is followed by a trap,
        // and no destruction runs after it (Runtime §7.1, ir.md §8.3).
        _ = try cfg_lower_emit.emit(self, fs, span, .{ .syscall = .{ .span = span, .target = target, .args = args, .ret = ret } }, null);
        try cfg_lower_emit.setTerminator(self, fs, .trap);
        return null;
    }
    if (cfg_lower_emit.isVoid(ret)) {
        _ = try cfg_lower_emit.emit(self, fs, span, .{ .syscall = .{ .span = span, .target = target, .args = args, .ret = ret } }, null);
        return try cfg_lower_expr.emitVoid(self, fs, span);
    }
    return try cfg_lower_emit.emit(self, fs, span, .{ .syscall = .{ .span = span, .target = target, .args = args, .ret = ret } }, ret);
}

/// Apply a parameter mode at a call site (Core §10.6, ir.md §8.1), after
/// materializing the `T → any` coercion when the parameter is typed
/// `any` and the argument is not (Core §11.6, ir.md §4.4): a Copy
/// source is `any_pack_copy`'d into the `any` (the source stays owned);
/// an unique source is `any_pack_move`'d, consuming it. The packed `any`
/// is itself unique — a plain or `move` parameter takes ownership of it,
/// a `borrow` parameter borrows the temporary. Then:
/// plain/borrow pass the value (the callee's `arg` arrives borrowed for
/// borrow params); move transfers ownership — an existing unique owner
/// arrives as `move %a`, a fresh unique value directly, and a Copy
/// value as a `copy`.
pub fn lowerCallArg(self: *Lowerer, fs: *FuncState, v: *cfg.Value, mode: ast.ParamMode, expected: cfg.Type) LowerError!*cfg.Value {
    if (isAny(expected) and !cfg.Type.eql(v.type_, expected)) {
        const span = v.span;
        if (v.ownership == .unique) {
            if (v.state == .borrowed) {
                return self.fail(span, "cannot move a borrowed value into an 'any'", .{});
            }
            const packed_v = (try cfg_lower_emit.emit(self, fs, span, .{ .any_pack_move = v }, expected)).?;
            cfg_lower_emit.markConsumed(self, fs, v);
            try cfg_lower_emit.cleanupDisable(self, fs, span, v);
            if (mode != .borrow) cfg_lower_emit.markConsumed(self, fs, packed_v);
            return packed_v;
        }
        const packed_v = (try cfg_lower_emit.emit(self, fs, span, .{ .any_pack_copy = v }, expected)).?;
        if (mode != .borrow) cfg_lower_emit.markConsumed(self, fs, packed_v);
        return packed_v;
    }
    return switch (mode) {
        .plain, .borrow => v,
        .move => blk: {
            if (v.ownership == .unique) {
                if (v.state == .borrowed) {
                    return self.fail(v.span, "cannot move a borrowed value", .{});
                }
                if (fs.local_values.contains(v)) {
                    const m = (try cfg_lower_emit.emit(self, fs, v.span, .{ .move_ = v }, v.type_)).?;
                    cfg_lower_emit.markConsumed(self, fs, v);
                    try cfg_lower_emit.cleanupDisable(self, fs, v.span, v);
                    break :blk m;
                }
                // A fresh unique value transfers directly (Core §10.5).
                cfg_lower_emit.markConsumed(self, fs, v);
                break :blk v;
            }
            // A Copy `move` is semantically a copy (ir.md §5.4).
            break :blk (try cfg_lower_emit.emit(self, fs, v.span, .{ .copy = v }, v.type_)).?;
        },
    };
}

fn isAny(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .any;
}
