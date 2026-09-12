//! Pass: function, block, and statement lowering — `function-definition`,
//! `block`, `let-statement`, `drop-statement` (Core §5, §9). In: Lowerer +
//! module info + function member / AST statement list. Out: a finalized
//! `cfg.IrFunc` with parameters bound, scoped drops, and explicit moves
//! (air.md §6.4).

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
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
/// the result type already matches the return type.
pub fn coerceRet(self: *Lowerer, fs: *FuncState, r: *cfg.Value) LowerError!*cfg.Value {
    if (!(fs.ret == .primitive and fs.ret.primitive == .any) or meta.Type.eql(r.type_, fs.ret)) return r;
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
    name: meta.Ident,
    params: []meta.Param,
    ret: meta.Type,
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
