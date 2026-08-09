//! Pass: mid-level CFG optimizer driver (optimizer.md, Pass 7–8). In: the
//! lowered `cfg.IrProgram` (already optimized on-the-fly during
//! construction — constant folding, arithmetic simplification, common
//! subexpression elimination, and copy propagation happen at each emit
//! site, braun13cc.pdf §3.1 / optimizer.md, On-the-fly optimizations). Out: the same program,
//! rewritten in place by the optimization sub-passes in order — 7 tail
//! call elimination, 8.0 function inlining, 8.4 module/member CSE, 8.4
//! copy propagation, 8.3 partial redundancy elimination, 8.8 if-conversion
//! (branchless select), 8.3 dead block
//! elimination, 8.4 drop elision, 8.4 dead-instruction elimination, 8.6
//! jump threading, 8.5 phi simplification. The sequence runs as a single
//! ordered pass — no iteration to fixpoint (optimizer.md).
const std = @import("std");
const cfg = @import("stilla").cfg;
const cfg_validate = @import("cfg_validate.zig");
const cfg_tail_call = @import("cfg_tail_call.zig");
const cfg_cse = @import("cfg_cse.zig");
const cfg_copy_prop = @import("cfg_copy_prop.zig");
const cfg_pre = @import("cfg_pre.zig");
const cfg_select = @import("cfg_select.zig");
const cfg_dead_block = @import("cfg_dead_block.zig");
const cfg_drop_elide = @import("cfg_drop_elide.zig");
const cfg_dead_instr = @import("cfg_dead_instr.zig");
const cfg_jump_thread = @import("cfg_jump_thread.zig");
const cfg_phi_simplify = @import("cfg_phi_simplify.zig");
const cfg_inline = @import("cfg_inline.zig");

pub const tailCall = cfg_tail_call.tailCall;
pub const inlineCalls = cfg_inline.inlineCalls;
pub const cse = cfg_cse.cse;
pub const copyProp = cfg_copy_prop.copyProp;
pub const pre = cfg_pre.pre;
pub const ifConvert = cfg_select.ifConvert;
pub const deadBlock = cfg_dead_block.deadBlock;
pub const dropElide = cfg_drop_elide.dropElide;
pub const deadInstr = cfg_dead_instr.deadInstr;
pub const jumpThread = cfg_jump_thread.jumpThread;
pub const phiSimplify = cfg_phi_simplify.phiSimplify;
pub const validate = cfg_validate.validate;

/// The optimizer's invariant contract (air.md §13): after every rewrite
/// the program must satisfy the full validator, or the pass is a bug.
fn check(program: *cfg.IrProgram, allocator: std.mem.Allocator, pass: []const u8) !void {
    if (try cfg_validate.validate(program, allocator)) |m| {
        std.log.err("AIR validation failed after {s}: {s}", .{ pass, m });
        return error.ValidationFailed;
    }
}

/// Run every enabled optimization pass in fixed order, exactly once
/// (no fixpoint — compile time stays near-linear; optimizer.md).
/// `allocator` is the program's backing allocator (the arena). The
/// air.md §13 validator runs before the sequence and after every pass:
/// an optimizer bug that violates structure, SSA, typing, or the
/// ownership dataflow surfaces as an error here, not at the runtime
/// consumer.
pub fn optimize(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    try check(program, allocator, "lowering");
    try tailCall(program, allocator);
    try check(program, allocator, "tail call");
    try inlineCalls(program, allocator);
    try check(program, allocator, "inlining");
    try cse(program, allocator);
    try check(program, allocator, "module/member CSE");
    try copyProp(program, allocator);
    try check(program, allocator, "copy propagation");
    try pre(program, allocator);
    try check(program, allocator, "PRE");
    try ifConvert(program, allocator);
    try check(program, allocator, "if-conversion");
    try deadBlock(program, allocator);
    try check(program, allocator, "dead-block elimination");
    try dropElide(program, allocator);
    try check(program, allocator, "drop elision");
    try deadInstr(program, allocator);
    try check(program, allocator, "dead-instruction elimination");
    try jumpThread(program, allocator);
    try check(program, allocator, "jump threading");
    try phiSimplify(program, allocator);
    try check(program, allocator, "phi simplification");
    // The text form (air.md §13) requires the print order to be a valid
    // SSA order — every non-phi operand defined in an earlier-printing
    // block — but the rewrite passes (copyProp, phiSimplify) substitute
    // values across blocks, and `cfg.renumberValues` preserves the
    // pre-existing relative print order, so a substitution can leave a
    // forward reference (e.g. phiSimplify folding a single-incoming
    // return phi into a use in the inliner's continuation). Re-establish
    // the invariant with one final topological renumber, then validate
    // the renumbered program like any other rewrite.
    for (program.funcs) |f| try cfg_inline.renumberPrintOrder(f, allocator);
    try check(program, allocator, "print-order normalization");
}
