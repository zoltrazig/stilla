//! Pass: CFG → LLIR preparation — dense ID allocation. In: the
//! read-only input CFG. Out: every function/block holds a dense
//! `FunctionId`/`BlockId`, the ordered function/block tables and the
//! per-function `block_ranges` rows are built, and one zeroed
//! `FunctionDesc` row per function exists (the code-range fields
//! `code_start`/`code_end`/`entry_pc` come from linearization, the
//! rest from the later stages). The ID order is fixed from here on;
//! nothing in the input CFG is rewritten (Stilla LLIR Specification
//! §1).

const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

/// Allocate dense `FunctionId`/`BlockId`, the module/function name maps,
/// and the zeroed `FunctionDesc` rows. Functions iterate
/// `IrProgram.funcs` (module order); blocks
/// iterate each function's surviving blocks in `cfg.BlockOrder` — the
/// canonical order shared with the printer, entry first then ascending
/// minimum defined-value id. Dead-block elimination removes
/// unreachable blocks without renumbering the survivors, so
/// `BasicBlock.id` has holes; the surviving-list iteration simply
/// never sees them, and the LLIR IDs come out dense from 0. Nothing in
/// the input CFG is rewritten.
pub fn run(bld: *Builder) error{OutOfMemory}!void {
    // Name maps (module specifiers, qualified function names). They are
    // filled here — before allocation and lifecycle planning — so the
    // lifecycle pass's `calleeParamList` name lookup resolves
    // name-only direct calls during planning (the interning pass
    // reuses the same ids later). `func_name_ids` values are the dense
    // `FunctionId`s just allocated below; the map is **module-scope**:
    // with a `module_scope` set, only that module's functions resolve,
    // and any other name lowers to a symbolic cross-module import.
    for (bld.program.funcs) |f| {
        if (!bld.inScope(f)) continue;
        try bld.func_ids.put(bld.arena, f, @intCast(bld.ordered_funcs.items.len));
        try bld.ordered_funcs.append(bld.arena, f);
    }
    for (bld.ordered_funcs.items, 0..) |f, i| {
        try bld.func_name_ids.put(bld.arena, f.name.text, @intCast(i));
    }
    for (bld.program.funcs) |f| {
        if (!bld.inScope(f)) continue;
        const ordered = try bld.arena.alloc(*const cfg.BasicBlock, f.blocks.len);
        for (f.blocks, 0..) |b, i| ordered[i] = b;
        std.mem.sort(*const cfg.BasicBlock, ordered, cfg.BlockOrder{ .entry = f.entry }, cfg.BlockOrder.lessThan);
        const range = lower.BlockRange{
            .start = @intCast(bld.ordered_blocks.items.len),
            .len = @intCast(ordered.len),
        };
        for (ordered) |b| {
            try bld.block_ids.put(bld.arena, b, @intCast(bld.ordered_blocks.items.len));
            try bld.ordered_blocks.append(bld.arena, b);
        }
        try bld.block_ranges.append(bld.arena, range);
    }
    for (bld.ordered_funcs.items) |_| {
        try bld.func_descs.append(bld.arena, std.mem.zeroes(llir.FunctionDesc));
    }
}
