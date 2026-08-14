//! Pass: mid-level CFG optimizer driver (frontend.md §7, §8). In: the
//! lowered `cfg.IrProgram` (already optimized on-the-fly during
//! construction — constant folding, arithmetic simplification, common
//! subexpression elimination, and copy propagation happen at each emit
//! site, braun13cc.pdf §3.1 / frontend.md §4.3). Out: the same program,
//! rewritten in place by the optimization sub-passes in order — 7 tail
//! call elimination, 8.4 module/member CSE, 8.4 copy propagation, 8.3
//! partial redundancy elimination, 8.5 dead block elimination, 8.6 drop
//! elision, 8.4 dead-instruction elimination, 8.8 jump threading, 8.7
//! phi simplification. The sequence runs as a single ordered pass — no
//! iteration to fixpoint (frontend.md §6).
const std = @import("std");
const cfg = @import("../cfg.zig");
const cfg_validate = @import("cfg_validate.zig");
const cfg_tail_call = @import("cfg_tail_call.zig");
const cfg_cse = @import("cfg_cse.zig");
const cfg_copy_prop = @import("cfg_copy_prop.zig");
const cfg_pre = @import("cfg_pre.zig");
const cfg_dead_block = @import("cfg_dead_block.zig");
const cfg_drop_elide = @import("cfg_drop_elide.zig");
const cfg_dead_instr = @import("cfg_dead_instr.zig");
const cfg_jump_thread = @import("cfg_jump_thread.zig");
const cfg_phi_simplify = @import("cfg_phi_simplify.zig");

pub const tailCall = cfg_tail_call.tailCall;
pub const cse = cfg_cse.cse;
pub const copyProp = cfg_copy_prop.copyProp;
pub const pre = cfg_pre.pre;
pub const deadBlock = cfg_dead_block.deadBlock;
pub const dropElide = cfg_drop_elide.dropElide;
pub const deadInstr = cfg_dead_instr.deadInstr;
pub const jumpThread = cfg_jump_thread.jumpThread;
pub const phiSimplify = cfg_phi_simplify.phiSimplify;
pub const validate = cfg_validate.validate;

/// The optimizer's invariant contract (ir.md §13): after every rewrite
/// the program must satisfy the full validator, or the pass is a bug.
fn check(program: *cfg.IrProgram, allocator: std.mem.Allocator, pass: []const u8) !void {
    if (try cfg_validate.validate(program, allocator)) |m| {
        std.debug.print("IR validation failed after {s}: {s}\n", .{ pass, m });
        return error.ValidationFailed;
    }
}

/// Run every enabled optimization pass in fixed order, exactly once
/// (no fixpoint — compile time stays near-linear; frontend.md §6).
/// `allocator` is the program's backing allocator (the arena). The
/// ir.md §13 validator runs before the sequence and after every pass:
/// an optimizer bug that violates structure, SSA, typing, or the
/// ownership dataflow surfaces as an error here, not at the runtime
/// consumer.
pub fn optimize(program: *cfg.IrProgram, allocator: std.mem.Allocator) !void {
    try check(program, allocator, "lowering");
    try tailCall(program, allocator);
    try check(program, allocator, "tail call");
    try cse(program, allocator);
    try check(program, allocator, "module/member CSE");
    try copyProp(program, allocator);
    try check(program, allocator, "copy propagation");
    try pre(program, allocator);
    try check(program, allocator, "PRE");
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
}
