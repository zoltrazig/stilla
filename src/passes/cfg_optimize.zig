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
//! ordered pass by default — no iteration to fixpoint (optimizer.md);
//! `optimizeAggressive` (same driver, same validator) loops it to a
//! bounded fixpoint for embedders who opt in (§8.9).
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
    try optimizeOnce(program, allocator, true);
}

/// One full iteration of the Pass 7–8 sequence: `optimize` with the
/// inliner enabled, and the aggressive fixpoint loop's later iterations
/// with it disabled. The inliner is explicitly one-shot (cfg_inline.zig:
/// "the spliced body's own call sites are not re-scanned this round,
/// keeping the pass one shot"); re-running it on a spliced recursive
/// callee would keep finding new sites inside its own copies and grow
/// the CFG without bound (fib.st measures 26 → 138 non-phi instructions
/// over four iterations) instead of converging to a fixpoint, so only
/// iteration 1 inlines. The remaining passes re-run over the same
/// fixed order with the same validator after every rewrite; whether a
/// later iteration shrinks, reshapes (PRE inserts edge computations,
/// if-conversion trades phis for selects), or leaves a program alone is
/// program-dependent — "aggressive never worse than the default" is
/// enforced empirically over the example corpus, not by construction
/// (optimizer.md §8.9).
fn optimizeOnce(program: *cfg.IrProgram, allocator: std.mem.Allocator, do_inline: bool) !void {
    try check(program, allocator, "lowering");
    try tailCall(program, allocator);
    try check(program, allocator, "tail call");
    if (do_inline) {
        try inlineCalls(program, allocator);
        try check(program, allocator, "inlining");
    }
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

/// Bounded iteration cap for the aggressive (fixpoint) mode
/// (optimizer.md, §8.9): the Pass 7–8 sequence loops at most this many
/// times. The demonstrating optimizer test asserts a second iteration
/// changes a crafted program, so lowering this below 2 silently defeats
/// it — the cap stays ≥ 2 by contract (comptime-guarded in the tests).
pub const aggressive_max_iters: u32 = 4;

/// Run the Pass 7–8 sequence repeatedly (optimizer.md, §8.9): iteration
/// 1 is the full sequence (inliner included — `optimize`); each later
/// iteration is the same fixed order with the one-shot inliner skipped
/// (re-running it on spliced recursive callees would grow the CFG
/// without bound instead of converging). The loop stops when a full
/// iteration produces a byte-identical printed text form (no rewrite
/// changed anything) or `max_iters` iterations have run — it always
/// terminates at equality or the cap.
/// `optimizeAggressive(…, 1)` is exactly the default single pass, so
/// the two modes share the near-linear cost model at the cap's lower
/// bound and differ only in the bounded extra iterations. The input
/// must be in valid print order (post-lowering or post-`optimize`): the
/// comparison is over the canonical text form, which the frontend
/// guarantees at both points. `allocator` is the program's backing
/// allocator (the arena).
pub fn optimizeAggressive(program: *cfg.IrProgram, allocator: std.mem.Allocator, max_iters: u32) !void {
    var iters: u32 = 0;
    var first = true;
    while (iters < max_iters) : (iters += 1) {
        const before = try cfg.print(program, allocator);
        try optimizeOnce(program, allocator, first);
        first = false;
        const after = try cfg.print(program, allocator);
        if (std.mem.eql(u8, before, after)) return; // fixpoint
    }
}
