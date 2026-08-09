//! Pass: function finalization and CFG validation (ir.md §3, §4.3). In:
//! Lowerer + per-function FuncState (blocks built, drops placed). Out: the
//! finalized `cfg.IrFunc` with instruction slices, predecessor lists in
//! edge order, materialized phi incoming lists, and the value table.
const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const lower = @import("../lower.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// Materialize the final `IrFunc`: instruction slices, predecessor
/// lists, phi incoming lists, and the value table.
pub fn finishFunc(self: *Lowerer, fs: *FuncState) LowerError!*cfg.IrFunc {
    if (fs.blocks.items.len == 0) {
        return self.fail(ast.Span.init(0, 0, 0), "function '{s}' has no blocks", .{fs.name.text});
    }
    const blocks = try self.arena.dupe(*cfg.BasicBlock, fs.blocks.items);
    const instr_lists = try self.arena.alloc([]const *cfg.Instr, fs.block_instrs.items.len);
    for (fs.block_instrs.items, 0..) |list, i| instr_lists[i] = list.items;
    if (try cfg.finalizeBlocks(self.arena, blocks, instr_lists, &fs.phi_lists)) |d| {
        return self.fail(d.span, "{s}", .{d.message});
    }
    const ir = try self.arena.create(cfg.IrFunc);
    ir.* = .{
        .id = self.next_func_id,
        .span = fs.name.span,
        .name = fs.name,
        .params = fs.params,
        .ret = fs.ret,
        .entry = blocks[0],
        .blocks = blocks,
        .values = try self.arena.dupe(*cfg.Value, fs.values.items),
        .module_spec = fs.module.specifier,
    };
    self.next_func_id += 1;
    return ir;
}
