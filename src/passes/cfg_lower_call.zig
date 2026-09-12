//! Pass: call lowering — `call-expression` (Core §12). In: Lowerer +
//! FuncState + ast.Call + resolved callee. Out: a `call` or `syscall`
//! instruction (with parameter modes applied at the call site).
const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_program = @import("cfg_lower_program.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// A call expression: resolve the callee, lower the arguments with their
/// parameter modes, and emit a direct, value, or host call.
/// The syscall emission tail of a host call: the target derivation
/// (`cfg_lower_intrinsic.syscallTarget` — (module, member) names the host
/// registry binding, air.md §8.2/§9.3) plus the syscall emission. Shared
/// with the intrinsic expansion path, which validates the specialized
/// signature before emitting.
pub fn emitHostCall(self: *Lowerer, fs: *FuncState, span: meta.Span, module_spec: []const u8, member: []const u8, args: []*cfg.Value, sig: meta.FunctionType) LowerError!?*cfg.Value {
    const call_target = try cfg_lower_intrinsic.syscallTarget(self, span, module_spec, member);
    return try emitSyscall(self, fs, span, call_target, args, sig);
}

/// Emit a `call` instruction, trapping when the callee is `never`.
pub fn emitCall(self: *Lowerer, fs: *FuncState, span: meta.Span, callee: cfg.Callee, args: []*cfg.Value, ret: meta.Type) LowerError!?*cfg.Value {
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
/// `never` (no destruction runs after it — Runtime §7.1, air.md §8.3).
pub fn emitSyscall(self: *Lowerer, fs: *FuncState, span: meta.Span, target: cfg.SysCallTarget, args: []*cfg.Value, sig: meta.FunctionType) LowerError!?*cfg.Value {
    const ret = sig.ret.*;
    if (cfg_lower_emit.isNever(ret)) {
        // `builtin.panic` and friends: the call is followed by a trap,
        // and no destruction runs after it (Runtime §7.1, air.md §8.3).
        _ = try cfg_lower_emit.emit(self, fs, span, .{ .syscall = .{ .span = span, .target = target, .args = args, .sig = sig } }, null);
        try cfg_lower_emit.setTerminator(self, fs, .trap);
        return null;
    }
    if (cfg_lower_emit.isVoid(ret)) {
        _ = try cfg_lower_emit.emit(self, fs, span, .{ .syscall = .{ .span = span, .target = target, .args = args, .sig = sig } }, null);
        return try cfg_lower_expr.emitVoid(self, fs, span);
    }
    return try cfg_lower_emit.emit(self, fs, span, .{ .syscall = .{ .span = span, .target = target, .args = args, .sig = sig } }, ret);
}

/// Apply a parameter mode at a call site (Core §10.6, air.md §8.1), after
/// materializing the `T → any` coercion when the parameter is typed
/// `any` and the argument is not (Core §11.6, air.md §4.4): a Copy
/// source is `any_pack_copy`'d into the `any` (the source stays owned);
/// an unique source is `any_pack_move`'d, consuming it. The packed `any`
/// is itself unique — a plain or `move` parameter takes ownership of it,
/// a `borrow` parameter borrows the temporary. Then:
/// plain/borrow pass the value (the callee's `arg` arrives borrowed for
/// borrow params); move transfers ownership — an existing unique owner
/// arrives as `move %a`, a fresh unique value directly, and a Copy
/// value as a `copy`.
pub fn lowerCallArg(self: *Lowerer, fs: *FuncState, v: *cfg.Value, mode: meta.ParamMode, expected: meta.Type) LowerError!*cfg.Value {
    if (isAny(expected) and !meta.Type.eql(v.type_, expected)) {
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
        .borrow => v,
        .plain => blk: {
            // A plain parameter takes ownership of a unique argument
            // (the `any` exception to Core §10.6 — the checker rejects
            // every other unique/plain combination): the caller's owner
            // transfers at the call, so it must be marked consumed or
            // the scope-end drop fires a second time — the callee
            // drops the parameter, and the caller's drop reads a
            // freed cell (or, after inlining, the validator reports
            // the double consumption).
            if (v.ownership == .unique) cfg_lower_emit.markConsumed(self, fs, v);
            break :blk v;
        },
        .move => blk: {
            if (v.ownership == .unique) {
                if (v.state == .borrowed) {
                    return self.fail(v.span, "cannot move a borrowed value", .{});
                }
                if (fs.local_values.contains(v)) {
                    const m = (try cfg_lower_emit.emit(self, fs, v.span, .{ .move_ = v }, v.type_)).?;
                    cfg_lower_emit.markConsumed(self, fs, v);
                    try cfg_lower_emit.cleanupDisable(self, fs, v.span, v);
                    // The moved value is the argument the callee owns:
                    // mark it consumed too, or the enclosing full-
                    // expression boundary drops a value already handed
                    // off (hir_simplify's synthesized `let` bindings make
                    // this path reachable).
                    cfg_lower_emit.markConsumed(self, fs, m);
                    break :blk m;
                }
                // A fresh unique value transfers directly (Core §10.5).
                cfg_lower_emit.markConsumed(self, fs, v);
                break :blk v;
            }
            // A Copy `move` is semantically a copy (air.md §5.4).
            break :blk (try cfg_lower_emit.emit(self, fs, v.span, .{ .copy = v }, v.type_)).?;
        },
    };
}

fn isAny(t: meta.Type) bool {
    return t == .primitive and t.primitive == .any;
}
