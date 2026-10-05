//! Pass: expression emission helpers shared with the HIR seam. The
//! direct AST expression lowering (literals, constructs, unary/binary
//! operators, casts, moves — `lowerExpr` and its per-form functions)
//! was removed; the HIR seam lowers every expression
//! from `hir.ExprNode`s (see hir_lower_expr.zig) through the same
//! `cfg_lower_emit` emission discipline. The three AST-free helpers
//! both paths share survive here.

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const lower = @import("stilla").lower;
const cfg_lower_emit = @import("cfg_lower_emit.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// A typed literal: `const` ops carry a `meta.ConstValue` (strings are
/// arena-owned) and a type; a void-typed `()` never emits (see
/// `emitVoid`).
pub fn emitConst(self: *Lowerer, fs: *FuncState, span: meta.Span, value: meta.ConstValue, type_: meta.Type) LowerError!?*cfg.Value {
    return cfg_lower_emit.emit(self, fs, span, .{ .const_ = value }, type_);
}

/// A `void`-typed expression result. `void` is a singleton type with no
/// observable value (cfg-lowering.md, Lowering rules; Pass 4.1): a void
/// return is a bare `ret`, a void join produces no phi, and the checker
/// rejects void in every typed operand position, so a void *value* is
/// never an instruction operand. The result is therefore a phantom — a
/// value with no defining instruction and no value-table entry — and the
/// lowerer emits no `const void` op for it.
/// `emitDrop`/`exitScope`/`discardValue` treat it as Copy and skip it,
/// so nothing downstream dereferences the missing definition.
pub fn emitVoid(self: *Lowerer, fs: *FuncState, span: meta.Span) LowerError!?*cfg.Value {
    _ = fs;
    const v = try self.arena.create(cfg.Value);
    v.* = .{
        // maxInt: a phantom id is never printed or used as an operand;
        // if one ever leaked into the text form, the giant id would be
        // obviously broken rather than silently mis-numbered.
        .id = std.math.maxInt(u32),
        .span = span,
        .type_ = .{ .primitive = .void },
        .ownership = .copy,
        .state = .owned,
        .origin = null,
        .def = null,
    };
    return v;
}

/// A statement discards its value: unique-owned results are dropped
/// here (air.md §6.4, temporaries of a full expression).
pub fn discardValue(self: *Lowerer, fs: *FuncState, v: *cfg.Value) LowerError!void {
    if (v.ownership == .unique and !cfg_lower_emit.isConsumed(fs, v)) {
        try cfg_lower_emit.emitDrop(self, fs, v.span, v);
    }
}
