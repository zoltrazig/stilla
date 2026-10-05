//! Pass: module-value emission helpers shared with the HIR seam. The
//! direct AST path lowering (`lowerPath`, `lowerPathValue`,
//! `lowerMember`, `memberLoad`, `lowerMemberLoad`,
//! `intrinsicMemberValue`, `joinPath`) was removed; the
//! HIR seam lowers value leaves and module access paths itself (see
//! hir_lower_expr.zig — `memberValueRef`, `hopChain`, `memberLoadHir`).
//! The two module-reference helpers both paths share survive here.

const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const lower = @import("stilla").lower;
const cfg_lower_emit = @import("cfg_lower_emit.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// The function's own module reference, created once per function.
pub fn selfModuleRef(self: *Lowerer, fs: *FuncState, span: meta.Span) LowerError!?*cfg.Value {
    if (fs.self_module) |v| return v;
    const v = try emitModuleRef(self, fs, span, fs.module.specifier);
    fs.self_module = v;
    return v;
}

/// `module_ref "spec"` with module identity recorded.
pub fn emitModuleRef(self: *Lowerer, fs: *FuncState, span: meta.Span, specifier: []const u8) LowerError!?*cfg.Value {
    const v = try cfg_lower_emit.emit(self, fs, span, .{ .module_ref = specifier }, .module);
    if (v) |vv| {
        if (self.graph.module(specifier)) |target| try self.module_of.put(self.arena, vv, target);
    }
    return v;
}
