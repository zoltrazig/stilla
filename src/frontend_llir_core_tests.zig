//! Test file: `frontend LLIR core` — the phase-1 frozen LLIR
//! model (spec/Stilla LLIR Specification.md) exercised through its
//! public API over a hand-built toy image, plus LLIR lowering stages
//! 2.1–2.7 (dense-id skeleton, code ranges, slot mapping, interning,
//! type specialization, phi edge copies). Split out of the former
//! `src/frontend_tests.zig`; `checkEdgeCopies` is local to this file.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const llir = @import("llir.zig");
const cfg = @import("cfg.zig");
const lower = @import("lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const compileOpt = helpers.compileOpt;
const irText = helpers.irText;
const findBlock = helpers.findBlock;
const blockIdx = helpers.blockIdx;
// ---------------------------------------------------------------------------
// LLIR — black-box: the phase-1 frozen model (spec/Stilla LLIR
// Specification.md) exercised through its public API over a hand-built toy
// image. The real CFG → LLIR lowering is phase 2; these tests pin the
// model contracts (instruction size, pc→function resolution, frame/header
// arithmetic for nested calls, tailcall fp reuse, schema checks) that the
// lowering and the interpreter will rely on.
// ---------------------------------------------------------------------------

test "LLIR model: nested call/ret frame contract over a toy image" {
    // Two functions sharing the global instruction array. `caller` calls
    // `callee`; the code ranges partition the pc space.
    const caller = llir.FunctionDesc{
        .code_start = 0,
        .code_end = 8,
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 2,
        .x_count = 0,
        .window_count = 3, // the callee takes one argument and returns one: 2 + max(1, 1) window cells
    };
    const callee = llir.FunctionDesc{
        .code_start = 8,
        .code_end = 12,
        .entry_pc = 8,
        .signature_id = 1,
        .f_count = 1,
        .x_count = 0,
        .window_count = 0,
    };
    const functions = [_]llir.FunctionDesc{ caller, callee };
    const program = llir.LlirProgram{
        .instructions = &.{
            llir.instrR(.add, llir.frame_base + 2, llir.frame_base + 0, llir.frame_base + 1),
            llir.instrI(.const_, llir.frame_base + 3, 1), // direct-call fallthrough: slot-0 result materialized
            llir.instrE(.ret, llir.frame_base + 3, 0),
            llir.instrR(.add, llir.frame_base + 0, llir.frame_base + 0, llir.frame_base + 1),
            llir.instrE(.ret, llir.frame_base + 0, 0),
            llir.instrR(.madd, llir.frame_base + 3, llir.frame_base + 0, llir.frame_base + 0),
            llir.instrE(.trap, 0, 0),
            llir.instrE(.trap, 0, 0),
            llir.instrE(.ret, 0, 0),
            llir.instrE(.trap, 0, 0),
            llir.instrE(.trap, 0, 0),
            llir.instrE(.trap, 0, 0),
        },
        .functions = &functions,
        .blocks = &.{},
        .constants = &.{},
        .types = &.{},
        .type_decls = &.{},
        .type_decl_fields = &.{},
        .union_variants = &.{},
        .union_payloads = &.{},
        .host_types = &.{},
        .self_symbol = 0,
        .init = llir.no_index,
        .entry_member = llir.no_index,
        .symbols = &.{},
        .imports = &.{},
        .exports = &.{},
        .module_slots = &.{},
        .signatures = &.{},
        .params = &.{},
        .destructure_dst_types = &.{},
        .call_args = &.{},
        .syscall_descs = &.{},
        .construct_descs = &.{},
        .destructure_dsts = &.{},
        .destructure_descs = &.{},
        .switch_arms = &.{},
        .switch_descs = &.{},
        .member_descs = &.{},
        .drop_descs = &.{},
        .strings = &.{},
    };

    // Every instruction in the image passes the field-level schema check
    // under the largest slot count — the caller's whole frame register
    // count (6 = 2 value + 0 scratch + 3 window cells) — the fused
    // multiply-accumulate included (a pure 3-operand register form, no
    // descriptor).
    for (program.instructions) |instr| {
        try testing.expect(llir.checkInstr(instr, 6) == null);
    }

    // The call-family record is exactly 8 bytes (spec §2).
    try testing.expectEqual(@as(usize, 4), @sizeOf(llir.Instr));

    // pc → function: entry, middle, and end of each range resolve to the
    // containing function; outside every range resolves to none.
    try testing.expectEqual(@as(?llir.FunctionId, 0), llir.functionAtPc(program.functions, 0));
    try testing.expectEqual(@as(?llir.FunctionId, 0), llir.functionAtPc(program.functions, 7));
    try testing.expectEqual(@as(?llir.FunctionId, 1), llir.functionAtPc(program.functions, 8));
    try testing.expectEqual(@as(?llir.FunctionId, 1), llir.functionAtPc(program.functions, 11));
    try testing.expectEqual(@as(?llir.FunctionId, null), llir.functionAtPc(program.functions, 12));

    // Nested call (spec §5.3): the callee's fp = caller sp - P (its
    // parameter register aliases the caller's window); the header lands
    // at [fp - 3, fp), inside the caller's reserved window region; the
    // callee frame ends at its own layout end. With caller sp = 100 and
    // a one-argument callee: fp = 99, header at [96, 99), callee frame
    // ends at 99 + 1 + 1 = 101.
    const caller_sp: u32 = 100;
    const call_pc: u32 = 1;
    const return_dst: llir.ValueReg = llir.frame_base + 3;
    // The fixed three-cell header (spec §4.3): caller's saved frame base
    // and function index, and the callee's saved return address.
    const header = llir.CallHeader{ .saved_fp = 40, .saved_fn = 7, .saved_ra = call_pc + 1 };
    try testing.expectEqual(@as(u32, 99), llir.calleeFrameStart(caller_sp, 1));
    // v9 frame math: callee fp = sp - A = 99, f_count = 1, x = 0, W = 0.
    try testing.expectEqual(@as(u32, 100), llir.calleeFrameEnd(caller_sp, callee, 1));
    // ret (spec §5.4): restore sp = header_base + 3 + A (the caller's
    // frame end), fp = previous_fp, pc = saved_ra, and write the result
    // register.
    const callee_fp = llir.calleeFrameStart(caller_sp, 1);
    try testing.expectEqual(@as(u32, 96), llir.headerBase(callee_fp));
    try testing.expectEqual(@as(u32, caller_sp), llir.headerBase(callee_fp) + 3 + 1);
    try testing.expectEqual(@as(u32, 40), header.saved_fp);
    try testing.expectEqual(@as(u32, 7), header.saved_fn);
    try testing.expectEqual(@as(u32, 2), header.saved_ra);
    // The caller's `ret` names the same result register the header math
    // reserved (the ret record's `a` is the result source).
    try testing.expectEqual(return_dst, llir.decode(program.instructions[2]).?.a);

    // tailcall_self: same fp, sp resets to the frame end
    // (call_base = fp + F + X; W = 3 here).
    try testing.expectEqual(@as(u32, 105), llir.frameEnd(100, caller));
}

// ---------------------------------------------------------------------------
// Phase 2 — LLIR normalization: the CFG → `llir.LlirProgram`
// projection (Stilla LLIR Specification §1). 2.1 — the lowering
// skeleton: dense `FunctionId`/`BlockId` allocation in module/function
// order and `cfg.BlockOrder`, skipping the block-id holes the optimizer
// leaves; the input CFG is never modified.
// ---------------------------------------------------------------------------

test "2.1 LLIR lowering skeleton: dense function/block ids, entry-first order, CFG unmodified" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn pick(a: int32, b: int32) -> int32 {
            \\    if (a < b) { a } else { b }
            \\}
            \\fn main() -> void {
            \\    let x = pick(1, 2);
            \\    builtin.print(builtin.str(x));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    // The input CFG is not modified: the canonical text is identical
    // before and after the lowering (spec §1 — LLIR is a read-only
    // projection; the `*const` input enforces it, the text check proves it).
    const before = try irText(program);
    defer testing.allocator.free(before);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    try b.prepare();

    // Dense FunctionIds: one row per function, 0..N-1, in module order.
    try testing.expectEqual(program.funcs.len, b.ordered_funcs.items.len);
    for (program.funcs, 0..) |f, i| {
        try testing.expectEqual(@as(llir.FunctionId, @intCast(i)), b.func_ids.get(f).?);
    }

    // Dense BlockIds: every block maps to a distinct id in 0..M-1.
    var total: usize = 0;
    for (program.funcs) |f| total += f.blocks.len;
    try testing.expectEqual(total, b.ordered_blocks.items.len);
    var seen = std.AutoHashMapUnmanaged(llir.BlockId, void).empty;
    for (program.funcs) |f| for (f.blocks) |blk| {
        const id = b.block_ids.get(blk) orelse return error.TestUnexpectedResult;
        try testing.expect(id < total);
        try seen.put(arena.allocator(), id, {});
    };
    try testing.expectEqual(total, seen.count());

    // The per-function block ranges partition the global table, each
    // function's first block is its entry (`cfg.BlockOrder`), and the
    // ranges concatenate to the full block table.
    var offset: u32 = 0;
    for (program.funcs, 0..) |f, fi| {
        const r = b.block_ranges.items[fi];
        try testing.expectEqual(offset, r.start);
        try testing.expectEqual(@as(u32, @intCast(f.blocks.len)), r.len);
        offset += r.len;
        try testing.expect(f.entry == b.ordered_blocks.items[r.start]);
    }
    try testing.expectEqual(offset, b.ordered_blocks.items.len);

    // Still unmodified after the lowering.
    const after = try irText(program);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "2.1 LLIR lowering skeleton: optimizer block id holes never reach the LLIR" {
    // A dead block between two live blocks: dead-block elimination prunes
    // it without renumbering the survivors, so the input `BasicBlock.id`
    // space has a hole. The lowering iterates the surviving blocks in
    // `cfg.BlockOrder` and assigns dense ids from 0.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    br %2 ? then : else
        \\dead:
        \\    %3: int32 = const 1
        \\    ret %3
        \\then:
        \\    ret %0
        \\else:
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.deadBlock(&t.program, t.arena.allocator());

    // The input really has the hole this stage must skip: `dead` (id 1)
    // was pruned, so the surviving ids {0, 2, 3} are not dense.
    const f = t.program.funcs[0];
    var max_id: u32 = 0;
    for (f.blocks) |blk| max_id = @max(max_id, blk.id);
    try testing.expect(max_id >= f.blocks.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    try b.prepare();

    // Dense: exactly the surviving blocks, ids 0..M-1, one range row.
    try testing.expectEqual(f.blocks.len, b.ordered_blocks.items.len);
    var seen = std.AutoHashMapUnmanaged(llir.BlockId, void).empty;
    for (f.blocks) |blk| {
        const id = b.block_ids.get(blk) orelse return error.TestUnexpectedResult;
        try testing.expect(id < f.blocks.len);
        try seen.put(arena.allocator(), id, {});
    }
    try testing.expectEqual(f.blocks.len, seen.count());
    try testing.expectEqual(@as(usize, 1), b.block_ranges.items.len);
    try testing.expectEqual(@as(u32, 0), b.block_ranges.items[0].start);
    try testing.expectEqual(@as(u32, @intCast(f.blocks.len)), b.block_ranges.items[0].len);
}

test "2.2 LLIR lowering: function code ranges ordered, non-overlapping, covering the image" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn pick(a: int32, b: int32) -> int32 {
            \\    if (a < b) { a } else { b }
            \\}
            \\fn main() -> void {
            \\    let x = pick(1, 2);
            \\    builtin.print(builtin.str(x));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // One FunctionDesc per function, with non-empty code ranges.
    try testing.expectEqual(program.funcs.len, image.functions.len);
    for (image.functions) |f| try testing.expect(f.code_start < f.code_end);

    // Ranges are ordered, non-overlapping, and contiguous — they tile the
    // whole instruction space (spec §2: any valid pc recovers a unique
    // function).
    try testing.expectEqual(@as(u32, 0), image.functions[0].code_start);
    try testing.expectEqual(image.instructions.len, image.functions[image.functions.len - 1].code_end);
    for (image.functions, 0..) |f, i| {
        if (i + 1 < image.functions.len) {
            try testing.expectEqual(f.code_end, image.functions[i + 1].code_start);
        }
        try testing.expect(f.entry_pc >= f.code_start and f.entry_pc < f.code_end);
        var pc = f.code_start;
        while (pc < f.code_end) : (pc += 1) {
            try testing.expectEqual(@as(llir.FunctionId, @intCast(i)), llir.functionAtPc(image.functions, pc).?);
        }
    }

    // BlockDesc rows tile each function's range; a block's width is its
    // budget (non-phi instructions + the terminator), and its last record
    // is the control-flow terminator (2.2 emits those). Stage-7 edge
    // blocks are part of the expanded block order, so the total counts
    // both the CFG blocks and the LLIR-only edge blocks.
    var total_blocks: usize = 0;
    for (program.funcs) |f| total_blocks += f.blocks.len;
    try testing.expectEqual(total_blocks + b.edge_block_srcs.count(), image.blocks.len);
    var bi: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f).?;
        const frange = b.block_ranges.items[fid];
        var block_start: u32 = undefined;
        for (0..frange.len) |k| {
            const blk = b.ordered_blocks.items[frange.start + k]; // BlockOrder, not f.blocks order
            const d = image.blocks[bi];
            if (k == 0) {
                block_start = image.functions[fid].code_start;
            } else {
                try testing.expectEqual(block_start, d.start_pc);
            }
            try testing.expect(d.start_pc < d.end_pc);
            try testing.expect(d.start_pc >= image.functions[fid].code_start and d.end_pc <= image.functions[fid].code_end);

            const copies: u32 = switch (blk.terminator) {
                .j => |t| blk: {
                    const l = try b.edgeCopyList(blk, t);
                    break :blk @intCast(l.len);
                },
                .br => |br| blk: {
                    var n: u32 = 0;
                    n += @intCast((try b.edgeCopyList(blk, br.then_)).len);
                    n += @intCast((try b.edgeCopyList(blk, br.else_)).len);
                    break :blk n;
                },
                .@"switch" => |s| blk: {
                    var n: u32 = 0;
                    for (s.arms) |arm| n += @intCast((try b.edgeCopyList(blk, arm.block)).len);
                    break :blk n;
                },
                else => 0,
            };
            // Width == budget: non-phi instrs + 2.7 edge copies +
            // terminator records (a `br` lowers to one when a target
            // is the next block in the layout — the trailing-j
            // elimination — else to the compare-and-branch + `j` pair,
            // Instruction Set §6).
            _ = copies;
            // v1: the final width is the block's own record-list length —
            // emission appends `slot_*` preparation and lifecycle trailing
            // records beyond the one-per-instruction base, and the §5.2
            // ownership fusion compacts pairs away again. The image layout
            // and the per-block lists must agree exactly.
            try testing.expectEqual(@as(u32, @intCast(b.block_records.items[b.block_ids.get(blk).?].items.len)), d.end_pc - d.start_pc);
            // The last record of the block is its terminator — a
            // control opcode (ret/jal/switch/tailcall/trap) or, for the
            // one-record `br` form, the compare-and-branch whose
            // fall-through is the next block (any B-type branch).
            const top = llir.decode(image.instructions[d.end_pc - 1]).?.op;
            try testing.expect(switch (top) {
                .ret,
                .release_ret,
                .jal,
                .j,
                .switch_,
                .tailcall_self,
                .trap,
                => true,
                else => llir.formatOf(top) == .b,
            });
            block_start = d.end_pc;
            bi += 1;
        }
        try testing.expectEqual(block_start, image.functions[fid].code_end);
    }
    try testing.expectEqual(image.blocks.len, bi);
}

test "2.2 LLIR lowering: branch and jump targets are signed offsets to block starts in range" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    br %2 ? then : else
        \\then:
        \\    ret %0
        \\else:
        \\    ret %1
        \\}
        \\func @g() -> void {
        \\entry:
        \\    j skip
        \\skip:
        \\    ret
        \\}
        \\}
    );
    defer t.arena.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();

    const f = t.program.funcs[0];
    const g = t.program.funcs[1];
    const f_entry = f.entry;
    const g_entry = g.entry;
    var f_then: ?*const cfg.BasicBlock = null;
    var f_else: ?*const cfg.BasicBlock = null;
    var g_skip: ?*const cfg.BasicBlock = null;
    for (f.blocks) |blk| {
        if (std.mem.eql(u8, blk.name, "then")) f_then = blk;
        if (std.mem.eql(u8, blk.name, "else")) f_else = blk;
    }
    for (g.blocks) |blk| {
        if (std.mem.eql(u8, blk.name, "skip")) g_skip = blk;
    }
    const then_blk = f_then.?;
    const else_blk = f_else.?;
    const skip_blk = g_skip.?;

    // A branch target is a signed offset from the branch's own pc
    // (target = pc + signExtend(offset), Instruction Set §6): the
    // compare-and-branch carries a signed 10-bit offset, `jal` a signed
    // 20-bit offset. The decoded target is the target block's start,
    // inside the current function.
    const checkTarget = struct {
        fn inRange(fns: []const llir.FunctionDesc, target: u32, fid: llir.FunctionId) !void {
            try testing.expect(llir.functionAtPc(fns, target).? == fid);
            const fd = fns[fid];
            try testing.expect(target >= fd.code_start and target < fd.code_end);
        }
    }.inRange;
    const f_id = b.func_ids.get(f).?;
    const g_id = b.func_ids.get(g).?;

    // f's br lowers to `ble %1, %0, $else` — the condition is a
    // two-operand i32 comparison (`lt %0, %1`), so the branch reads the
    // compared operands directly, with the polarity flipped and the
    // operands swapped: the then
    // block is the next block in the layout, so the trailing-jal
    // elimination inverts the condition (`blt` → `ble`, exchanging the
    // operands — `!(%0 < %1) ≡ %0 >= %1 ≡ ble %1, %0`) and the
    // branch carries the else target, `then` falling through. The two
    // comparison records themselves stay (dead: `slt` + the `copy
    // %2, cond` materialization).
    const br_pc = b.pcOf(f_entry) + 2; // the slt + copy pair sits before it
    const br = image.instructions[br_pc];
    const brd = llir.decode(br).?;
    try testing.expectEqual(llir.Opcode.ble, brd.op);
    try testing.expectEqual(b.slotOf(t.program.funcs[0].values[1]), brd.a);
    try testing.expectEqual(b.slotOf(t.program.funcs[0].values[0]), brd.b);
    try testing.expectEqual(b.pcOf(else_blk), llir.bTypeTarget(br_pc, brd.offs10));
    try testing.expectEqual(b.pcOf(else_blk), image.blocks[b.block_ids.get(else_blk).?].start_pc);
    try checkTarget(image.functions, llir.bTypeTarget(br_pc, brd.offs10), f_id);
    // The then block falls through: the branch block ends where then
    // begins, and no `jal` follows the branch.
    try testing.expectEqual(image.blocks[b.block_ids.get(then_blk).?].start_pc, image.blocks[b.block_ids.get(f_entry).?].end_pc);

    // g's j: the offs20 immediate is the skip offset from the jump's own
    // pc — a signed 20-bit value (Instruction Set §9.1).
    const j_pc = b.pcOf(g_entry); // no non-phi instrs: terminator at block start
    const j = image.instructions[j_pc];
    const jd = llir.decode(j).?;
    try testing.expectEqual(llir.Opcode.j, jd.op);
    try testing.expectEqual(b.pcOf(skip_blk), llir.jalTarget(j_pc, jd.imm20));
    try testing.expectEqual(b.pcOf(skip_blk), image.blocks[b.block_ids.get(skip_blk).?].start_pc);
    try checkTarget(image.functions, llir.jalTarget(j_pc, jd.imm20), g_id);

    // entry_pc of each function is its entry block's start PC.
    try testing.expectEqual(b.pcOf(f_entry), image.functions[f_id].entry_pc);
    try testing.expectEqual(b.pcOf(g_entry), image.functions[g_id].entry_pc);

    // g's void ret carries zero as its result register (spec §5).
    const ret_pc = b.pcOf(skip_blk);
    const ret = image.instructions[ret_pc];
    const retd = llir.decode(ret).?;
    try testing.expectEqual(llir.Opcode.ret, retd.op);
    try testing.expectEqual(llir.zero_reg, retd.a);

    // The lowering never touched the input CFG.
    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "j skip") != null);
    try testing.expect(std.mem.indexOf(u8, text, "br %2 ? then : else") != null);
}

test "2.2 LLIR lowering: trailing-j elimination — fall-through else, inverted then, and the pair fallback" {
    // A CFG `br` lowers to a compare-and-branch + `jal` pair unless one
    // target is the next block in the layout: then the trailing `jal` is
    // redundant and the lowering emits the branch alone — with the
    // else target falling through (Case A), or, when the then body is
    // the next block and the else target is within the branch's ±512
    // reach, with the condition inverted so the branch carries else and
    // the then body falls through (Case B). With neither target next,
    // the pair stays.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @a(x: int32, y: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    br %2 ? then : else
        \\then:
        \\    ret %0
        \\else:
        \\    %3: int32 = const 1
        \\    %4: int32 = add %1, %3
        \\    ret %4
        \\}
        \\func @b(c: bool, x: int32) -> int32 {
        \\entry:
        \\    br %0 ? then : else
        \\then:
        \\    ret %1
        \\else:
        \\    ret %1
        \\}
        \\func @c(a: int32, b: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    br %2 ? then : else
        \\x:
        \\    %3: int32 = const 7
        \\    ret %3
        \\then:
        \\    ret %0
        \\else:
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();

    const f_a = t.program.funcs[0];
    const f_b = t.program.funcs[1];
    const f_c = t.program.funcs[2];

    // @a: the else block (value-ful) sorts before the value-less then
    // block, so else is the fall-through — one record, branch to then.
    const a_entry = f_a.entry;
    try testing.expectEqual(@as(u32, 1), b.terminatorRecordCount(a_entry));
    const a_pc = b.pcOf(a_entry);
    const a_br = image.instructions[a_pc + 2]; // after the lt + copy pair
    const abd = llir.decode(a_br).?;
    try testing.expectEqual(llir.Opcode.blt, abd.op);
    try testing.expectEqual(b.pcOf(findBlock(f_a.blocks, "then")), llir.bTypeTarget(a_pc + 2, abd.offs10));
    try testing.expectEqual(b.pcOf(findBlock(f_a.blocks, "else")), image.blocks[b.block_ids.get(a_entry).?].end_pc);

    // @b: the then block is the fall-through and else is adjacent —
    // one record, condition inverted (`bne cond, zero` → `beq
    // cond, zero`), branch to else.
    const b_entry = f_b.entry;
    try testing.expectEqual(@as(u32, 1), b.terminatorRecordCount(b_entry));
    const b_pc = b.pcOf(b_entry);
    const b_br = image.instructions[b_pc];
    const bbd = llir.decode(b_br).?;
    try testing.expectEqual(llir.Opcode.beq, bbd.op);
    try testing.expectEqual(b.slotOf(f_b.values[0]), bbd.a);
    try testing.expectEqual(llir.zero_reg, bbd.b);
    try testing.expectEqual(b.pcOf(findBlock(f_b.blocks, "else")), llir.bTypeTarget(b_pc, bbd.offs10));
    try testing.expectEqual(b.pcOf(findBlock(f_b.blocks, "then")), image.blocks[b.block_ids.get(b_entry).?].end_pc);

    // @c: the dead `x` block (min value id %3) sorts right after
    // entry, so the successor is neither target — the pair survives:
    // compare-and-branch to then, `j` to else.
    const c_entry = f_c.entry;
    try testing.expectEqual(@as(u32, 2), b.terminatorRecordCount(c_entry));
    const c_pc = b.pcOf(c_entry);
    const c_br = image.instructions[c_pc + 2];
    const cbd = llir.decode(c_br).?;
    try testing.expectEqual(llir.Opcode.blt, cbd.op);
    try testing.expectEqual(b.pcOf(findBlock(f_c.blocks, "then")), llir.bTypeTarget(c_pc + 2, cbd.offs10));
    const c_j = image.instructions[c_pc + 3];
    const cjd = llir.decode(c_j).?;
    try testing.expectEqual(llir.Opcode.j, cjd.op);
    try testing.expectEqual(b.pcOf(findBlock(f_c.blocks, "else")), llir.jalTarget(c_pc + 3, cjd.imm20));

    // The one-record forms are structurally valid images.
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));
}

test "2.3 LLIR lowering: physical slot mapping and frame layout" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn pick(a: int32, b: int32) -> int32 {
            \\    if (a < b) { a } else { b }
            \\}
            \\fn dead(a: int32) -> int32 { 7 }
            \\fn main() -> void {
            \\    let x = pick(1, 2);
            \\    builtin.print(builtin.str(x));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var saw_reuse = false;
    for (program.funcs, 0..) |f, fi| {
        const fd = image.functions[fi];

        // Linear scan reuses expired cells; parameters retain the ABI
        // cells F0..F(P-1). v1: f_count covers values plus phi-cycle
        // staging cells; reuse shows as fewer cells than values when any
        // function reuses.
        try testing.expect(fd.f_count >= @as(u32, @intCast(f.params.len)));
        if (fd.f_count < f.values.len) saw_reuse = true;
        for (f.values[0..f.params.len]) |v| try testing.expect(v.def == null);

        // v1 frame arithmetic: F + X + W is statically reserved and
        // bounded by the register bank.
        const total = @as(u32, fd.f_count) + fd.x_count + fd.window_count;
        try testing.expect(total <= llir.frame_count_max);
    }
    try testing.expect(saw_reuse);
    for (program.funcs) |f| {
        if (std.mem.endsWith(u8, f.name.text, ".dead")) {
            try testing.expectEqual(llir.frameReg(0), b.slotOf(f.values[f.params.len]));
        }
    }
}

test "2.3 LLIR lowering: scratch budget covers phi swap-cycle staging" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @join(a: int32, b: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    br %2 ? then : else
        \\then:
        \\    %3: int32 = const 1
        \\    j join
        \\else:
        \\    %4: int32 = const 2
        \\    j join
        \\join:
        \\    %5: int32 = phi [%0, then], [%4, else]
        \\    ret %5
        \\}
        \\func @swap(x: int32, y: int32) -> int32 {
        \\entry:
        \\    j body
        \\body:
        \\    %2: int32 = phi [%0, entry], [%3, body]
        \\    %3: int32 = phi [%1, entry], [%2, body]
        \\    j body
        \\}
        \\func @cycle() -> int32 {
        \\entry:
        \\    %0: int32 = const 0
        \\    j body
        \\body:
        \\    %1: int32 = phi [%0, entry], [%2, body]
        \\    %2: int32 = phi [%0, entry], [%3, body]
        \\    %3: int32 = phi [%0, entry], [%1, body]
        \\    j body
        \\}
        \\func @mixed(x: int32, y: bool) -> int32 {
        \\entry:
        \\    j body
        \\body:
        \\    %2: int32 = phi [%0, entry], [%3, body]
        \\    %3: int32 = phi [%0, entry], [%2, body]
        \\    %4: bool = phi [%1, entry], [%5, body]
        \\    %5: bool = phi [%1, entry], [%4, body]
        \\    j body
        \\}
        \\}
    );
    defer t.arena.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();

    // @join: no back-edge cycles → no staging cells beyond the values.
    const jf = t.program.funcs[0];
    const jfd = image.functions[b.func_ids.get(jf).?];
    try testing.expect(jfd.f_count <= @as(u32, @intCast(jf.values.len)));
    for (jf.values[0..jf.params.len]) |v| try testing.expect(v.def == null);

    // v1: staging cells are plain F cells past the value cells — one per
    // distinct cycle type. The mixed-type cycle uses two staging cells,
    // one per parameter type.
    const mf = t.program.funcs[3];
    const mfd = image.functions[b.func_ids.get(mf).?];
    try testing.expect(mfd.f_count >= @as(u32, @intCast(mf.params.len)));
    try testing.expectEqual(@as(usize, 2), b.scratch_cycle_types.items[b.func_ids.get(mf).?].items.len);
    const mbody = mf.blocks[blockIdx(mf.blocks, "body")];
    const mlist = try b.edgeCopyList(mbody, mbody);
    // v1: a cycle may stage through a dead value cell OR the dedicated
    // staging cell — assert that whatever cells the emitted copies use,
    // the two staging TYPES are tracked and every staged record carries
    // its source's type.
    var saw_int_stage = false;
    var saw_bool_stage = false;
    for (mlist) |copy| {
        if (copy.src_type) |st| {
            if (cfg.Type.eql(st.*, mf.params[0].type_)) saw_int_stage = true;
            if (cfg.Type.eql(st.*, mf.params[1].type_)) saw_bool_stage = true;
        }
    }
    try testing.expect(saw_int_stage);
    try testing.expect(saw_bool_stage);
    try testing.expect(cfg.Type.eql(b.scratch_cycle_types.items[b.func_ids.get(mf).?].items[0].*, mf.params[0].type_));
    try testing.expect(cfg.Type.eql(b.scratch_cycle_types.items[b.func_ids.get(mf).?].items[1].*, mf.params[1].type_));
}

// ---------------------------------------------------------------------------
// Stage 7 — path-specific edge effects (TODO.md 阶段 7)
// ---------------------------------------------------------------------------

test "stage 7.1: br arms with different phi copies route through per-arm edge blocks" {
    // A `br` whose two arms are both phi-bearing blocks with DIFFERENT
    // incoming sources. Under the pre-stage-7 inline model both arms'
    // copies ran unconditionally in the predecessor — the last write won
    // even on the untaken path. Stage 7 routes each arm through an
    // LLIR-only edge block that executes only its own edge's ordered
    // copies.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @direct(x: int32, y: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    br %2 ? a : b
        \\a:
        \\    %3: int32 = phi [%0, entry]
        \\    j c
        \\b:
        \\    %4: int32 = phi [%1, entry]
        \\    j c
        \\c:
        \\    %5: int32 = phi [%3, a], [%4, b]
        \\    %6: int32 = add %5, %0
        \\    %7: int32 = add %6, %1
        \\    ret %7
        \\}
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("stage7 br image rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
    const f = t.program.funcs[0];
    const entry = f.blocks[blockIdx(f.blocks, "entry")];
    const a = f.blocks[blockIdx(f.blocks, "a")];
    const bb = f.blocks[blockIdx(f.blocks, "b")];
    // Both arms route through an edge block.
    const ea = b.targetForEdge(entry, a);
    const eb = b.targetForEdge(entry, bb);
    try testing.expect(b.isEdgeBlock(ea));
    try testing.expect(b.isEdgeBlock(eb));
    // The predecessor emits no inline edge copies (they live in the edge
    // blocks).
    try testing.expectEqual(@as(u32, 0), b.edge_copy_counts.items[b.block_ids.get(entry).?]);
    // The a-edge block: exactly the %0→slot(%3) copy, then `j a`.
    const ea_recs = b.block_records.items[b.block_ids.get(ea).?];
    try testing.expectEqual(@as(usize, 2), ea_recs.items.len);
    const a_copy = llir.decode(ea_recs.items[0]).?;
    try testing.expectEqual(b.slotOf(f.values[3]), a_copy.a); // dst = slot(%3)
    try testing.expectEqual(b.slotOf(f.values[0]), a_copy.b); // src = %0
    try testing.expectEqual(llir.Opcode.j, llir.decode(ea_recs.items[1]).?.op);
    // The b-edge block: exactly the %1→slot(%4) copy, then `j b`.
    const eb_recs = b.block_records.items[b.block_ids.get(eb).?];
    try testing.expectEqual(@as(usize, 2), eb_recs.items.len);
    const b_copy = llir.decode(eb_recs.items[0]).?;
    try testing.expectEqual(b.slotOf(f.values[4]), b_copy.a); // dst = slot(%4)
    try testing.expectEqual(b.slotOf(f.values[1]), b_copy.b); // src = %1
    try testing.expectEqual(llir.Opcode.j, llir.decode(eb_recs.items[1]).?.op);
}

test "stage 7: a br back-edge phi swap-cycle stages inside the edge block" {
    // A loop whose back-edge is a `br` arm carrying a phi swap-cycle
    // (`%3 ↔ %4`). The cycle staging lives in the LLIR-only edge block
    // (not inline in the loop header), and the header emits no inline
    // back-edge copies. This exercises the stage-7 edge-block path for
    // cycle staging (TODO.md 7.4).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @swp(x: int32, y: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    j loop
        \\loop:
        \\    %3: int32 = phi [%0, entry], [%4, loop]
        \\    %4: int32 = phi [%1, entry], [%3, loop]
        \\    %5: bool = lt %3, %4
        \\    br %5 ? loop : done
        \\done:
        \\    ret %3
        \\}
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("stage7 cycle image rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
    const f = t.program.funcs[0];
    const loop = f.blocks[blockIdx(f.blocks, "loop")];
    // The loop back-edge routes through an edge block carrying the staged
    // cycle.
    const edge = b.targetForEdge(loop, loop);
    try testing.expect(b.isEdgeBlock(edge));
    // The header emits no inline back-edge copies.
    try testing.expectEqual(@as(u32, 0), b.edge_copy_counts.items[b.block_ids.get(loop).?]);
    // The edge block's records are exactly its staged copies plus the
    // final `j` back to the loop header; the two-cycle stages through a
    // scratch cell, so it emits 3 records (stage + 2 transfers) + `j`.
    const recs = b.block_records.items[b.block_ids.get(edge).?];
    try testing.expectEqual(@as(usize, 4), recs.items.len);
    try testing.expectEqual(llir.Opcode.j, llir.decode(recs.items[recs.items.len - 1]).?.op);
}

test "stage 7.3: a counted value read only by the switch terminator releases on its edge blocks" {
    // A counted `list[int32]` parameter read ONLY by the `switch`
    // discriminant (a defensive-lowering shape — a real source program
    // rarely switches on a counted value, but the lifecycle must still
    // release it exactly once without reading it after the release). It
    // is live through the terminator and dead on every outgoing edge, so
    // the release must run in the per-arm edge blocks AFTER the switch —
    // never inline before the terminator (which would read a released
    // cell), never leaking. This is a text-AIR structural regression for
    // that mechanism; the executable lifecycle release path is covered by
    // the stage-7.2 interpreter test.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @g(x: list[int32]) -> int32 {
        \\entry:
        \\    switch %0 { #0 -> a, #1 -> b }
        \\a:
        \\    %1: int32 = const 1
        \\    ret %1
        \\b:
        \\    %2: int32 = const 2
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    if (try llir_validate.validate(&image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("stage7 switch image rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
    const f = t.program.funcs[0];
    const entry = f.blocks[blockIdx(f.blocks, "entry")];
    const a = f.blocks[blockIdx(f.blocks, "a")];
    const bb = f.blocks[blockIdx(f.blocks, "b")];
    const x = f.values[0];
    // The counted owner is released on both outgoing edges, each in its
    // own edge block.
    const ea = b.targetForEdge(entry, a);
    const eb = b.targetForEdge(entry, bb);
    try testing.expect(b.isEdgeBlock(ea));
    try testing.expect(b.isEdgeBlock(eb));
    const releases = struct {
        fn check(bld: *const cfg_lower_llir.Builder, eb_: *const cfg.BasicBlock, slot: u32) !void {
            const recs = bld.block_records.items[bld.block_ids.get(eb_).?];
            // One `release` of `x`, then the final `j` to the successor.
            try testing.expectEqual(@as(usize, 2), recs.items.len);
            const rel = llir.decode(recs.items[0]).?;
            try testing.expectEqual(llir.Opcode.release, rel.op);
            try testing.expectEqual(slot, rel.a);
            const j = llir.decode(recs.items[1]).?;
            try testing.expectEqual(llir.Opcode.j, j.op);
        }
    }.check;
    try releases(&b, ea, b.slotOf(x));
    try releases(&b, eb, b.slotOf(x));
    // The entry block's switch is its terminator and holds no inline
    // release (no record between the switch and the edge hand-off).
    try testing.expectEqual(@as(u32, 0), b.edge_copy_counts.items[b.block_ids.get(entry).?]);
}

/// The number of SSA values of `f` — the v1 lower bound for its F cells
/// before staging (each value occupies at most one cell).
fn valueCellCount(f: *const cfg.IrFunc) u32 {
    return @intCast(f.values.len);
}

test "2.4 LLIR lowering: constants and ID-operand records are interned integers" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn pick(a: int32, b: int32) -> int32 {
            \\    if (a < b) { a } else { b }
            \\}
            \\fn main() -> void {
            \\    let x = pick(1, 2);
            \\    builtin.print(builtin.str(x));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // Constants intern by value: exactly one row for 1, one for 2.
    var int1: usize = 0;
    var int2: usize = 0;
    for (image.constants) |cr| {
        if (cr.kind == .int and cr.a == 1) int1 += 1;
        if (cr.kind == .int and cr.a == 2) int2 += 1;
    }
    try testing.expectEqual(@as(usize, 1), int1);
    try testing.expectEqual(@as(usize, 1), int2);

    // The `int32` type appears in every value slot and both signatures —
    // the types table holds exactly one row for it (spec §2: equal
    // entities share one row).
    var int32_rows: usize = 0;
    for (image.types) |td| {
        if (td.kind == .primitive and td.a == @intFromEnum(llir.PrimitiveId.int32)) int32_rows += 1;
    }
    try testing.expectEqual(@as(usize, 1), int32_rows);

    // Every function: signature and declaring module resolve; the
    // signature's ret is the serialized ret type (no_index for void).
    for (program.funcs, 0..) |f, fi| {
        const fd = image.functions[fi];
        const sig = image.signatures[fd.signature_id];
        try testing.expectEqual(@as(u32, @intCast(f.params.len)), sig.params_len);
        for (f.params, 0..) |p, i| {
            const pr = image.params[sig.params_start + i];
            try testing.expectEqual(@as(u32, @intFromEnum(p.mode)), @intFromEnum(pr.mode));
        }
        // Declaring-module identity now lives in the artifact's symbol,
        // not per-function rows; nothing per-function to assert here.
        if (std.mem.endsWith(u8, f.name.text, ".pick")) {
            try testing.expectEqual(llir.TypeKind.primitive, image.types[sig.ret].kind);
            try testing.expectEqual(@intFromEnum(llir.PrimitiveId.int32), image.types[sig.ret].a);
        }
        if (std.mem.endsWith(u8, f.name.text, ".main")) {
            try testing.expectEqual(llir.no_index, sig.ret); // void ret has no TypeId
        }
        // v1: no slot-type rows — every primitive type the values use
        // must exist in the interned type table (dedup makes one row per
        // distinct type).
        for (f.values) |v| {
            if (v.type_ != .primitive) continue;
            const want_id: llir.PrimitiveId = switch (v.type_.primitive) {
                // A `bool` value is only ever a branch condition (cmp /
                // br) — no record carries its type, so no type row is
                // required (member-row signatures no longer intern it
                // either: intrinsic members occupy no row, air.md §5.6).
                .bool => continue,
                .byte => .byte,
                .i64 => .i64,
                .u64 => .u64,
                .f64 => .f64,
                .int32 => .int32,
                .uint32 => .uint32,
                .float32 => .float32,
                .str => .str,
                .any => .any,
                .hostdata => .hostdata,
                .void, .never => continue,
            };
            var found = false;
            for (image.types) |row| {
                if (row.kind == .primitive and row.a == @intFromEnum(want_id)) found = true;
            }
            try testing.expect(found);
        }
    }

    // Every `const` instruction's record: opcode, dst slot, and a
    // ConstId whose row carries the value (records contain integers, not
    // names or pointers).
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .const_ => |cv| {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(llir.Opcode.const_, d.op);
                        const want_a = if (ins.results.len > 0) b.slotOf(ins.results[0]) else llir.zero_reg;
                        try testing.expectEqual(want_a, d.a);
                        try testing.expect(d.imm16 < image.constants.len);
                        const cr = image.constants[d.imm16];
                        switch (cv) {
                            .int => |i| {
                                try testing.expectEqual(llir.ConstKind.int, cr.kind);
                                try testing.expectEqual(@as(u32, @truncate(@as(u64, @bitCast(i)))), cr.a);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }

    // Every syscall target's (module, member name) pair is a host
    // binding row, resolved by name (air.md §5.6 — intrinsic members
    // occupy no member row, so bindings dispatch by name, not by row
    // index). The `builtin` module's member table is empty.
    for (program.funcs) |f| {
        for (f.blocks) |blk| {
            for (blk.instrs) |ins| switch (ins.op) {
                .syscall => |sc| {
                    const mod_name: []const u8 = switch (sc.target) {
                        .builtin => "builtin",
                        .host_module => |hm| hm.module,
                    };
                    const mem_name: []const u8 = switch (sc.target) {
                        .builtin => |bb| @tagName(bb),
                        .host_module => |hm| hm.member,
                    };
                    var found = false;
                    for (image.imports) |imp| {
                        const mr = image.symbols[imp.module_sym];
                        const fr = image.symbols[imp.member_sym];
                        const nm = image.strings[mr.start..][0..mr.len];
                        const mb = image.strings[fr.start..][0..fr.len];
                        if (std.mem.eql(u8, nm, mod_name) and std.mem.eql(u8, mb, mem_name)) found = true;
                    }
                    try testing.expect(found);
                },
                else => {},
            };
        }
    }
    // air.md §5.6: every builtin member is an intrinsic — none occupies
    // a member row; the artifact records imports by symbol, not rows.
    try testing.expectEqual(@as(usize, 0), image.module_slots.len);
}

test "2.4 LLIR lowering: module_ref/load_member/fn_ref/type_is/store_member records and string dedup" {
    var t = try cfg_parse.parseText(
        \\module "builtin" {
        \\}
        \\module "app" {
        \\    func @init() -> void {
        \\    entry:
        \\        %0: int32 = const 7
        \\        store_member #0, %0
        \\        ret
        \\    }
        \\    func @helper(x: int32) -> int32 {
        \\    entry:
        \\        ret %0
        \\    }
        \\    func @main() -> void {
        \\    entry:
        \\        %0: str = const "hi"
        \\        %1: str = const "hi"
        \\        %2: bool = type_is %0, str
        \\        %3: module = module_ref "app"
        \\        %4: fn (int32) -> int32 = load_member %3, #0
        \\        %5: fn (int32) -> int32 = fn_ref @helper
        \\        %6: int32 = const 7
        \\        ret
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // The artifact header records the module's @init function id.
    try testing.expectEqual(b.func_ids.get(program.funcs[0]).?, image.init);

    // M1: the artifact's own symbol is its module specifier — the
    // identity a host dispatches host bindings by (Instruction Set §13).
    const self_range = image.symbols[image.self_symbol];
    try testing.expect(std.mem.eql(u8, "app", image.strings[self_range.start..][0..self_range.len]));

    // helper's FunctionDesc signature is shared with the `fn (int32) ->
    // int32` function *type* rows (one signature, one type row).
    const helper_fi: usize = 1;
    const helper_sig = image.signatures[image.functions[helper_fi].signature_id];
    try testing.expectEqual(@as(u32, 1), helper_sig.params_len);
    try testing.expectEqual(@intFromEnum(llir.PrimitiveId.int32), image.types[helper_sig.ret].a);
    var fn_type_rows: usize = 0;
    for (image.types) |td| {
        if (td.kind == .function) fn_type_rows += 1;
    }
    try testing.expectEqual(@as(usize, 1), fn_type_rows);
    for (image.types) |td| {
        if (td.kind == .function) try testing.expectEqual(helper_sig.params_start, image.signatures[td.a].params_start);
    }

    // main: void ret is no_index; string "hi" interned once, byte range
    // resolvable; the const 7 in @init and main share one ConstId.
    try testing.expectEqual(llir.no_index, image.signatures[image.functions[2].signature_id].ret);
    var hi_cid: ?llir.ConstId = null;
    var seven_cid: ?llir.ConstId = null;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (b.isRecordElided(ins)) continue; // fused/elided: no record
                switch (ins.op) {
                    .const_ => |cv| {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        const cr = image.constants[d.imm16];
                        switch (cv) {
                            .string => |s| {
                                try testing.expectEqual(@as(u32, @intCast(s.len)), cr.b);
                                try testing.expect(std.mem.eql(u8, s, image.strings[cr.a..][0..cr.b]));
                                if (hi_cid) |cid| try testing.expectEqual(cid, d.imm16) else hi_cid = d.imm16;
                            },
                            .int => |i| if (i == 7) {
                                if (seven_cid) |cid| try testing.expectEqual(cid, d.imm16) else seven_cid = d.imm16;
                            } else {},
                            else => {},
                        }
                    },
                    .type_is => |ti| {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(llir.Opcode.type_is, d.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                        try testing.expectEqual(b.slotOf(ti.value), d.b);
                        try testing.expectEqual(llir.TypeKind.primitive, image.types[d.c].kind);
                        try testing.expectEqual(@intFromEnum(llir.PrimitiveId.str), image.types[d.c].a);
                    },
                    .module_ref => |spec| {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(llir.Opcode.module_ref, d.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                        // The operand is the module's SymbolId: its bytes
                        // name the referenced module ("app").
                        const r = image.symbols[@truncate(d.imm16)];
                        try testing.expect(std.mem.eql(u8, spec, image.strings[r.start..][0..r.len]));
                    },
                    .load_member => |lm| {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(llir.Opcode.load_member, d.op);
                        try testing.expectEqual(b.slotOf(lm.module), d.b);
                        // c is the MemberDescId; its row carries
                        // the member reference.
                        const md = image.member_descs[d.c];
                        try testing.expectEqual(lm.member, md.ref);
                    },
                    .fn_ref => |name| {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(llir.Opcode.fn_ref, d.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                        try testing.expectEqual(b.func_name_ids.get(name).?, d.imm16);
                    },
                    .store_member => |sm| {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(llir.Opcode.store_member, d.op);
                        try testing.expectEqual(b.slotOf(sm.value), d.a);
                        // imm16 is the MemberDescId; its row carries
                        // the member reference.
                        const md = image.member_descs[d.imm16];
                        try testing.expectEqual(sm.slot, md.ref);
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expect(hi_cid != null);
    try testing.expect(seven_cid != null);
}

test "2.4 LLIR lowering: named instantiation interning and generic template decls" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct Option[T] {
            \\    val: T;
            \\}
            \\fn unwrap[T](o: Option[T]) -> T {
            \\    match (o) {
            \\        Option[T] { val } => val
            \\    }
            \\}
            \\fn main() -> void {
            \\    let o: Option[int32] = Option[int32] { val: 42 };
            \\    let v = unwrap[int32](o);
            \\    builtin.print(builtin.str(v));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // The `Option` template TypeId: the index of its declaration in both
    // program.types and image.type_decls (the shared index space of
    // TypeDesc.named.a, spec §8).
    const opt_id: cfg.TypeId = blk: {
        for (program.types, 0..) |decl, id| {
            if (decl == .struct_ and std.mem.eql(u8, decl.struct_.name, "Option")) break :blk @intCast(id);
        }
        unreachable;
    };
    // Template row: generic → deferred ownership (no_index), no drop
    // hook, one field whose type is the unsubstituted .param (no_index).
    const decl = image.type_decls[opt_id];
    try testing.expectEqual(llir.TypeDeclKind.struct_, decl.kind);
    try testing.expectEqual(llir.no_index, decl.a);
    try testing.expectEqual(llir.no_index, decl.b);
    try testing.expectEqual(@as(u32, 1), decl.d);
    try testing.expectEqual(llir.no_index, image.type_decl_fields[decl.c]);

    // Every `Option[int32]` slot (o, the constructed value, unwrap's
    // param) resolves to one shared named row: declaration id + one
    // int32 argument.
    var named_rows: usize = 0;
    for (image.types) |td| {
        if (td.kind == .named) named_rows += 1;
    }
    try testing.expectEqual(@as(usize, 1), named_rows);
    var checked_named = false;
    for (program.funcs) |f| {
        for (f.values) |v| {
            if (v.type_ == .named and v.type_.named.id == opt_id) {
                // v1: the named type is interned as a deduped `types` row
                // whose declaration id matches.
                var tid: ?usize = null;
                for (image.types, 0..) |row, ti| {
                    if (row.kind == .named and row.a == opt_id) tid = ti;
                }
                try testing.expect(tid != null);
                const row = image.types[tid.?];
                try testing.expectEqual(llir.TypeKind.named, row.kind);
                try testing.expectEqual(opt_id, row.a);
                try testing.expectEqual(@as(u32, 1), row.c);
                try testing.expectEqual(llir.TypeKind.primitive, image.types[row.b].kind);
                try testing.expectEqual(@intFromEnum(llir.PrimitiveId.int32), image.types[row.b].a);
                checked_named = true;
            }
        }
    }
    try testing.expect(checked_named);

    // unwrap's specialization is monomorphic: its signature parameter is
    // the same named instantiation.
    var saw_unwrap = false;
    for (program.funcs, 0..) |f, fi| {
        if (f.params.len == 1 and f.params[0].type_ == .named and f.params[0].type_.named.id == opt_id) {
            const sig = image.signatures[image.functions[fi].signature_id];
            try testing.expectEqual(@as(u32, 1), sig.params_len);
            try testing.expectEqual(llir.TypeKind.named, image.types[image.params[sig.params_start].type_].kind);
            saw_unwrap = true;
        }
    }
    try testing.expect(saw_unwrap);
}

test "2.5 LLIR lowering: generic arithmetic specializes by concrete type" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn iadd(a: int32, b: int32) -> int32 { a + b }
            \\fn uadd(a: uint32, b: uint32) -> uint32 { a + b }
            \\fn fadd(a: float32, b: float32) -> float32 { a + b }
            \\fn imul(a: int32, b: int32) -> int32 { a * b }
            \\fn umul(a: uint32, b: uint32) -> uint32 { a * b }
            \\fn fdiv(a: float32, b: float32) -> float32 { a / b }
            \\fn imod(a: int32, b: int32) -> int32 { a % b }
            \\fn umod(a: uint32, b: uint32) -> uint32 { a % b }
            \\fn ineg(a: int32) -> int32 { -a }
            \\fn uneg(a: uint32) -> uint32 { -a }
            \\fn fneg(a: float32) -> float32 { -a }
            \\fn lnot(a: bool) -> bool { !a }
            \\fn cat(a: str, b: str) -> str { a + b }
            \\fn main() -> void {
            \\    iadd(1, 2); uadd(1 as uint32, 2 as uint32); fadd(1.0, 2.0);
            \\    imul(1, 2); umul(1 as uint32, 2 as uint32); fdiv(1.0, 2.0);
            \\    imod(1, 2); umod(1 as uint32, 2 as uint32);
            \\    ineg(1); uneg(1 as uint32); fneg(1.0); lnot(true); cat("a", "b");
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // Walk every non-phi instruction and check its record against the
    // specialization the dispatch must never re-derive from a type:
    // each generic op maps to exactly one concrete opcode, chosen by the
    // operand type alone (spec §5 — i32/u32 wrap modulo 2³², f32 is IEEE;
    // the opcode discriminates).
    var n_arith: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .add, .sub, .mul, .div, .rem, .neg => {
                        const want: llir.Opcode = switch (ins.op) {
                            .add => switch (ins.results[0].type_.primitive) {
                                .int32 => .add,
                                .uint32 => .add,
                                .float32 => .add_f32,
                                else => unreachable,
                            },
                            .sub => switch (ins.results[0].type_.primitive) {
                                .int32 => .sub,
                                .uint32 => .sub,
                                .float32 => .sub_f32,
                                else => unreachable,
                            },
                            .mul => switch (ins.results[0].type_.primitive) {
                                .int32 => .mul,
                                .uint32 => .mul,
                                .float32 => .mul_f32,
                                else => unreachable,
                            },
                            .div => switch (ins.results[0].type_.primitive) {
                                .int32 => .div,
                                .uint32 => .divu,
                                .float32 => .div_f32,
                                else => unreachable,
                            },
                            .rem => switch (ins.results[0].type_.primitive) {
                                .int32 => .rem,
                                .uint32 => .remu,
                                .float32 => unreachable,
                                else => unreachable,
                            },
                            .neg => switch (ins.results[0].type_.primitive) {
                                .int32 => .neg,
                                .uint32 => .neg,
                                .float32 => .neg_f32,
                                else => unreachable,
                            },
                            else => unreachable,
                        };
                        const recs = image.instructions[pc .. pc + try b.recordCount(blk, ins)];
                        // Locate the primary record — staged 32-bit
                        // sequences carry `zext32`/`sext32` around it.
                        var primary: ?llir.Decoded = null;
                        for (recs) |rec| {
                            const d = llir.decode(rec).?;
                            if (d.op == want) primary = d;
                        }
                        try testing.expect(primary != null);
                        try testing.expectEqual(b.slotOf(ins.results[0]), primary.?.a);
                        n_arith += 1;
                    },
                    .not_ => {
                        const rec = image.instructions[pc];
                        try testing.expectEqual(llir.Opcode.not, llir.decode(rec).?.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), llir.decode(rec).?.a);
                    },
                    .concat => {
                        const rec = image.instructions[pc];
                        try testing.expectEqual(llir.Opcode.concat, llir.decode(rec).?.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), llir.decode(rec).?.a);
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    // The whole i32/u32/f32 arithmetic surface was exercised:
    // 3 adds + 2 muls + 1 div + 2 rems + 3 negs = 11 records (plus
    // not/concat below).
    try testing.expectEqual(@as(usize, 11), n_arith);
    // The typed families carry the numeric regime in the opcode: the
    // signed/unsigned/i32/f32 `add` differ by rep suffix — one dispatch
    // table, no result-type reads.
    try testing.expect(@intFromEnum(llir.Opcode.add) != @intFromEnum(llir.Opcode.add_f32));
}

test "2.5 LLIR lowering: hand-written arithmetic records carry dst/src slots and the full opcode table" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @arith32(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        %3: int32 = sub %0, %1
        \\        %4: int32 = mul %0, %1
        \\        %5: int32 = div %0, %1
        \\        %6: int32 = rem %0, %1
        \\        %7: int32 = neg %0
        \\        ret %7
        \\    }
        \\    func @arithu(a: uint32, b: uint32) -> uint32 {
        \\    entry:
        \\        %2: uint32 = add %0, %1
        \\        %3: uint32 = sub %0, %1
        \\        %4: uint32 = mul %0, %1
        \\        %5: uint32 = div %0, %1
        \\        %6: uint32 = rem %0, %1
        \\        %7: uint32 = neg %0
        \\        ret %7
        \\    }
        \\    func @arithf(a: float32, b: float32) -> float32 {
        \\    entry:
        \\        %2: float32 = add %0, %1
        \\        %3: float32 = sub %0, %1
        \\        %4: float32 = mul %0, %1
        \\        %5: float32 = div %0, %1
        \\        %6: float32 = rem %0, %1
        \\        %7: float32 = neg %0
        \\        ret %7
        \\    }
        \\    func @logic(a: bool) -> bool {
        \\    entry:
        \\        %1: bool = not %0
        \\        ret %1
        \\    }
        \\    func @cat(a: str, b: str) -> str {
        \\    entry:
        \\        %2: str = concat %0, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const want = [_]llir.Opcode{
        .add,     .sub,     .mul,     .div,     .rem,     .neg,
        .add,     .sub,     .mul,     .divu,    .remu,    .neg,
        .add_f32, .sub_f32, .mul_f32, .div_f32, .rem_f32, .neg_f32,
        .not,     .concat,
    };
    // Re-derive each expected record from the CFG (a = dst slot, b = a,
    // c = b — or 0 for the unary neg/not) and assert the primary
    // opcode is the exact specialized one; also assert every table
    // opcode is exercised exactly once. The widthless 32-bit ops emit
    // canonicalization staging around the primary record (Instruction
    // Set §4): `mul`/`div`/`rem` on int32/uint32 truncate the 64-bit
    // result (`sext32 dst, dst`), and the u32 `div`/`rem` zero-extend
    // both operands first (`zext32` staging on T15 and the result
    // slot).
    var seen = std.StaticBitSet(0x10000).initEmpty(); // full u16 opcode space
    var count: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .add, .sub, .mul, .div, .rem, .neg, .not_, .concat => {
                        const n = try b.recordCount(blk, ins);
                        const recs = image.instructions[pc .. pc + n];
                        // The widthless 32-bit ops emit staging around
                        // the primary record: `mul`/`div`/`rem` on
                        // int32/uint32 truncate the 64-bit result
                        // (`sext32 dst, dst`), and the u32 `div`/`rem`
                        // zero-extend both operands first (`zext32` on
                        // the T15 staging slot and the result slot).
                        try testing.expect(count < want.len);
                        var found_want = false;
                        for (recs) |rec| {
                            const d = llir.decode(rec).?;
                            if (d.op == want[count]) found_want = true;
                            switch (d.op) {
                                .sext32 => {
                                    try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                                    try testing.expectEqual(b.slotOf(ins.results[0]), d.b);
                                },
                                .zext32 => try testing.expect(
                                    d.a == llir.temp_base + 15 or d.a == b.slotOf(ins.results[0]),
                                ),
                                else => {},
                            }
                        }
                        try testing.expect(found_want);
                        seen.set(@intFromEnum(want[count]));
                        count += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(want.len, count);
    // `rem_f32` is emitted for float32 `%` (Core §16.3) and follows IEEE
    // binary32 — the specialized table stays total.
    try testing.expect(seen.isSet(@intFromEnum(llir.Opcode.rem_f32)));
}

test "2.5 LLIR lowering: abs/min/max/clz/popcount specialize by type and carry dst/src slots" {
    // The extended numeric families (Instruction Set §5): `abs` wraps on
    // int32_min (modulo 2³², never traps) and clears the sign bit on
    // f32; the signed/unsigned/IEEE `min`/`max`; and the unified
    // `clz`/`popcount` over the 32-bit patterns (one op serves
    // int32/uint32 — the result is the operand type). uint32 has no
    // abs (the identity) and byte no arithmetic, so neither lowers.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @exi(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = abs %0
        \\        %3: int32 = min %0, %1
        \\        %4: int32 = max %0, %1
        \\        %5: int32 = clz %0
        \\        %6: int32 = popcount %0
        \\        ret %6
        \\    }
        \\    func @exu(a: uint32, b: uint32) -> uint32 {
        \\    entry:
        \\        %2: uint32 = min %0, %1
        \\        %3: uint32 = max %0, %1
        \\        %4: uint32 = clz %0
        \\        %5: uint32 = popcount %0
        \\        ret %5
        \\    }
        \\    func @exf(a: float32, b: float32) -> float32 {
        \\    entry:
        \\        %2: float32 = abs %0
        \\        %3: float32 = min %0, %1
        \\        %4: float32 = max %0, %1
        \\        ret %4
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const want = [_]llir.Opcode{
        .abs_i32, .min,     .max,     .clz_i32,      .popcount_i32,
        .minu,    .maxu,    .clz_i32, .popcount_i32, .abs_f32,
        .min_f32, .max_f32,
    };
    // Re-derive each expected record from the CFG (a = dst slot, b = a,
    // c = b — or 0 for the unary abs/clz/popcount) and assert the
    // opcode is the exact specialized one; every table opcode is
    // exercised exactly once.
    var count: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .abs, .min, .max, .clz, .popcount => {
                        const recs = image.instructions[pc .. pc + try b.recordCount(blk, ins)];
                        try testing.expect(count < want.len);
                        // Locate the primary record — the u32 min/max
                        // stage both operands (`zext32`) before it.
                        var primary: ?llir.Decoded = null;
                        for (recs) |rec| {
                            const d = llir.decode(rec).?;
                            if (d.op == want[count]) primary = d;
                        }
                        try testing.expect(primary != null);
                        const d = primary.?;
                        try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                        switch (ins.op) {
                            .abs, .clz, .popcount => |v| {
                                // Unary E-type: a = dst, b = the operand, c = 0.
                                try testing.expectEqual(b.slotOf(v), d.b);
                                try testing.expectEqual(@as(u32, 0), d.c);
                            },
                            .min, .max => |bin| {
                                if (ins.results[0].type_ == .primitive and ins.results[0].type_.primitive == .uint32) {
                                    // Full-cell unsigned compare over the
                                    // zero-extended operands: b = the T15
                                    // staging slot, c = the zero-extended
                                    // second operand (the result slot).
                                    try testing.expectEqual(llir.temp_base + 15, d.b);
                                    try testing.expectEqual(b.slotOf(ins.results[0]), d.c);
                                } else {
                                    try testing.expectEqual(b.slotOf(bin.a), d.b);
                                    try testing.expectEqual(b.slotOf(bin.b), d.c);
                                }
                            },
                            else => unreachable,
                        }
                        try testing.expectEqual(want[count], d.op);
                        count += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(want.len, count);
}

test "2.6 LLIR lowering: generic comparisons and casts specialize by type" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn eqi(a: int32, b: int32) -> bool { a == b }
            \\fn neu(a: uint32, b: uint32) -> bool { a != b }
            \\fn ltf(a: float32, b: float32) -> bool { a < b }
            \\fn geu(a: uint32, b: uint32) -> bool { a >= b }
            \\fn eqb(a: byte, b: byte) -> bool { a == b }
            \\fn eqbl(a: bool, b: bool) -> bool { a == b }
            \\fn eqs(a: str, b: str) -> bool { a == b }
            \\fn f2i(a: float32) -> int32 { a as int32 }
            \\fn i2f(a: int32) -> float32 { a as float32 }
            \\fn i2b(a: int32) -> byte { a as byte }
            \\fn b2i(a: byte) -> int32 { a as int32 }
            \\fn i2u(a: int32) -> uint32 { a as uint32 }
            \\fn u2i(a: uint32) -> int32 { a as int32 }
            \\fn main() -> void {
            \\    eqi(1, 2); neu(1 as uint32, 2 as uint32); ltf(1.0, 2.0); geu(1 as uint32, 2 as uint32);
            \\    eqb(1 as byte, 2 as byte); eqbl(true, false); eqs("a", "b");
            \\    f2i(1.0); i2f(1); i2b(1); b2i(1 as byte); i2u(1); u2i(1 as uint32);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var seen_cmp = std.StaticBitSet(512).initEmpty();
    var seen_cast = std.StaticBitSet(512).initEmpty();
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .eq, .ne, .lt, .le, .gt, .ge => |bin| {
                        const tag = std.meta.activeTag(ins.op);
                        const prim = bin.a.type_.primitive;
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        if (prim == .bool or prim == .str) {
                            // The scalar comparisons (bool_eq/bool_ne/
                            // str_eq/str_ne) also write the implicit
                            // cond: `a = lhs, b = rhs, c = 0`
                            // (Instruction Set §4), followed by the
                            // `copy dst, cond` materialization.
                            const want: llir.Opcode = switch (prim) {
                                .bool => switch (tag) {
                                    .eq => .bool_eq,
                                    .ne => .bool_ne,
                                    else => unreachable,
                                },
                                .str => switch (tag) {
                                    .eq => .str_eq,
                                    .ne => .str_ne,
                                    else => unreachable,
                                },
                                else => unreachable,
                            };
                            try testing.expectEqual(want, d.op);
                            try testing.expectEqual(b.slotOf(bin.a), d.a);
                            try testing.expectEqual(b.slotOf(bin.b), d.b);
                            try testing.expectEqual(@as(u32, 0), d.c);
                            const nrec = image.instructions[pc + 1];
                            var nd = llir.decode(nrec).?;
                            if (nd.op == .not) nd = llir.decode(image.instructions[pc + 2]).?;
                            try testing.expectEqual(llir.Opcode.copy, nd.op);
                            try testing.expectEqual(b.slotOf(ins.results[0]), nd.a);
                            try testing.expectEqual(llir.cond_reg, nd.b);
                            seen_cmp.set(@intFromEnum(want));
                        } else {
                            // The C-Type comparison families (implicit
                            // cond): the record carries the two compared
                            // operands — `gt` and float `ge` swap them
                            // (a > b ≡ slt b, a; a >= b ≡ sle b, a) —
                            // and the result slot is materialized by
                            // `copy dst, cond` at pc + 1 (byte lowers
                            // through the u32 reps).
                            const want: llir.Opcode = switch (tag) {
                                .eq => switch (prim) {
                                    .int32 => .seq,
                                    .uint32, .byte => .seq,
                                    .float32 => .seq_f32,
                                    else => unreachable,
                                },
                                .ne => switch (prim) {
                                    .int32 => .sne,
                                    .uint32, .byte => .sne,
                                    .float32 => .sne_f32,
                                    else => unreachable,
                                },
                                .lt => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .slt_f32,
                                    else => unreachable,
                                },
                                .le => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .sle_f32,
                                    else => unreachable,
                                },
                                .gt => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .slt_f32,
                                    else => unreachable,
                                },
                                .ge => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .sle_f32,
                                    else => unreachable,
                                },
                                else => unreachable,
                            };
                            const swapped = (tag == .gt) or (tag == .le and prim != .float32) or (tag == .ge and prim == .float32);
                            const a_slot = b.slotOf(if (swapped) bin.b else bin.a);
                            const b_slot = b.slotOf(if (swapped) bin.a else bin.b);
                            try testing.expectEqual(want, d.op);
                            try testing.expectEqual(a_slot, d.a);
                            try testing.expectEqual(b_slot, d.b);
                            const nrec = image.instructions[pc + 1];
                            var nd = llir.decode(nrec).?;
                            if (nd.op == .not) nd = llir.decode(image.instructions[pc + 2]).?;
                            try testing.expectEqual(llir.Opcode.copy, nd.op);
                            try testing.expectEqual(b.slotOf(ins.results[0]), nd.a);
                            try testing.expectEqual(llir.cond_reg, nd.b);
                            seen_cmp.set(@intFromEnum(want));
                        }
                    },
                    .num_cast => |v| {
                        // The explicit cvt.<src>.<dst> C-type casts: the
                        // opcode names both the source and the
                        // destination; the record carries (a = dst slot,
                        // b = source slot).
                        const src_prim = v.type_.primitive;
                        const dst_prim = ins.results[0].type_.primitive;
                        const want: llir.Opcode = switch (src_prim) {
                            .int32 => switch (dst_prim) {
                                .float32 => .cvt_i32_f32,
                                .byte => .cvt_i32_b,
                                .uint32 => .cvt_i32_u32,
                                else => unreachable,
                            },
                            .float32 => switch (dst_prim) {
                                .int32 => .cvt_f32_i32,
                                else => unreachable,
                            },
                            .byte => switch (dst_prim) {
                                .int32 => .cvt_b_i32,
                                else => unreachable,
                            },
                            .uint32 => switch (dst_prim) {
                                .int32 => .cvt_u32_i32,
                                else => unreachable,
                            },
                            else => unreachable,
                        };
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(want, d.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                        try testing.expectEqual(b.slotOf(v), d.b);
                        seen_cast.set(@intFromEnum(want));
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    // Integer comparison opcodes carry signedness but no width; float
    // width and scalar bool/string equality remain distinct. The six Core
    // §16.3 cast pairs lower through the six explicit cvt.<src>.<dst>
    // opcodes exercised here.
    var n_cmp: usize = 0;
    for (0..512) |i| {
        if (seen_cmp.isSet(i)) n_cmp += 1;
    }
    var n_cast: usize = 0;
    for (0..512) |i| {
        if (seen_cast.isSet(i)) n_cast += 1;
    }
    try testing.expectEqual(@as(usize, 6), n_cmp);
    try testing.expectEqual(@as(usize, 6), n_cast);
    // NaN and wrap semantics live in the opcode alone: f32 eq/ordering
    // differ from the byte and str families, and the signedness of a
    // conversion is fixed by the (source, destination) pair.
    try testing.expect(@intFromEnum(llir.Opcode.seq_f32) != @intFromEnum(llir.Opcode.str_eq));
    try testing.expect(@intFromEnum(llir.Opcode.cvt_i32_u32) != @intFromEnum(llir.Opcode.cvt_u32_i32));
}

test "2.6 LLIR lowering: hand-written comparison and cast records, full opcode table" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @cmp32(a: int32, b: int32) -> bool {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        %3: bool = ne %0, %1
        \\        %4: bool = lt %0, %1
        \\        %5: bool = le %0, %1
        \\        %6: bool = gt %0, %1
        \\        %7: bool = ge %0, %1
        \\        ret %7
        \\    }
        \\    func @cmpu(a: uint32, b: uint32) -> bool {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        %3: bool = ne %0, %1
        \\        %4: bool = lt %0, %1
        \\        %5: bool = le %0, %1
        \\        %6: bool = gt %0, %1
        \\        %7: bool = ge %0, %1
        \\        ret %7
        \\    }
        \\    func @cmpf(a: float32, b: float32) -> bool {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        %3: bool = ne %0, %1
        \\        %4: bool = lt %0, %1
        \\        %5: bool = le %0, %1
        \\        %6: bool = gt %0, %1
        \\        %7: bool = ge %0, %1
        \\        ret %7
        \\    }
        \\    func @cmpb(a: byte, b: byte) -> bool {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        %3: bool = ne %0, %1
        \\        %4: bool = lt %0, %1
        \\        %5: bool = le %0, %1
        \\        %6: bool = gt %0, %1
        \\        %7: bool = ge %0, %1
        \\        ret %7
        \\    }
        \\    func @cmpbl(a: bool, b: bool) -> bool {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        %3: bool = ne %0, %1
        \\        ret %3
        \\    }
        \\    func @cmps(a: str, b: str) -> bool {
        \\    entry:
        \\        %2: bool = eq %0, %1
        \\        %3: bool = ne %0, %1
        \\        ret %3
        \\    }
        \\    func @casts(a: int32, b: float32, c: byte, d: uint32) -> void {
        \\    entry:
        \\        %4: float32 = num_cast %0
        \\        %5: int32 = num_cast %1
        \\        %6: byte = num_cast %0
        \\        %7: int32 = num_cast %2
        \\        %8: uint32 = num_cast %0
        \\        %9: int32 = num_cast %3
        \\        ret
        \\    }
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // The explicit cvt.<src>.<dst> C-type casts: the six Core §16.3
    // pairs each have their own opcode naming both the source and the
    // destination.
    const cast_want = [_]llir.Opcode{
        .cvt_i32_f32, // int32 → float32
        .cvt_f32_i32, // float32 → int32
        .cvt_i32_b, // int32 → byte
        .cvt_b_i32, // byte → int32
        .cvt_i32_u32, // int32 → uint32
        .cvt_u32_i32, // uint32 → int32
    };
    var n_cast: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .eq, .ne, .lt, .le, .gt, .ge => |bin| {
                        const tag = std.meta.activeTag(ins.op);
                        const prim = bin.a.type_.primitive;
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        if (prim == .bool or prim == .str) {
                            // The scalar comparisons (bool_eq/bool_ne/
                            // str_eq/str_ne) write the implicit cond:
                            // `a = lhs, b = rhs, c = 0` (Instruction
                            // Set §4), materialized by `copy dst, cond`
                            // at pc + 1.
                            const want: llir.Opcode = switch (prim) {
                                .bool => switch (tag) {
                                    .eq => .bool_eq,
                                    .ne => .bool_ne,
                                    else => unreachable,
                                },
                                .str => switch (tag) {
                                    .eq => .str_eq,
                                    .ne => .str_ne,
                                    else => unreachable,
                                },
                                else => unreachable,
                            };
                            try testing.expectEqual(want, d.op);
                            try testing.expectEqual(b.slotOf(bin.a), d.a);
                            try testing.expectEqual(b.slotOf(bin.b), d.b);
                            try testing.expectEqual(@as(u32, 0), d.c);
                            const nrec = image.instructions[pc + 1];
                            var nd = llir.decode(nrec).?;
                            if (nd.op == .not) nd = llir.decode(image.instructions[pc + 2]).?;
                            try testing.expectEqual(llir.Opcode.copy, nd.op);
                            try testing.expectEqual(b.slotOf(ins.results[0]), nd.a);
                            try testing.expectEqual(llir.cond_reg, nd.b);
                        } else {
                            // The C-Type families: the record carries the
                            // compared operands (`gt`, and float `ge`,
                            // swap them) and the result slot is
                            // materialized by `copy dst, cond` at pc + 1.
                            const want: llir.Opcode = switch (tag) {
                                .eq => switch (prim) {
                                    .int32 => .seq,
                                    .uint32, .byte => .seq,
                                    .float32 => .seq_f32,
                                    else => unreachable,
                                },
                                .ne => switch (prim) {
                                    .int32 => .sne,
                                    .uint32, .byte => .sne,
                                    .float32 => .sne_f32,
                                    else => unreachable,
                                },
                                .lt => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .slt_f32,
                                    else => unreachable,
                                },
                                .le => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .sle_f32,
                                    else => unreachable,
                                },
                                .gt => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .slt_f32,
                                    else => unreachable,
                                },
                                .ge => switch (prim) {
                                    .int32 => .slt,
                                    .uint32, .byte => .sltu,
                                    .float32 => .sle_f32,
                                    else => unreachable,
                                },
                                else => unreachable,
                            };
                            const swapped = (tag == .gt) or (tag == .le and prim != .float32) or (tag == .ge and prim == .float32);
                            const a_slot = b.slotOf(if (swapped) bin.b else bin.a);
                            const b_slot = b.slotOf(if (swapped) bin.a else bin.b);
                            try testing.expectEqual(want, d.op);
                            try testing.expectEqual(a_slot, d.a);
                            try testing.expectEqual(b_slot, d.b);
                            const nrec = image.instructions[pc + 1];
                            var nd = llir.decode(nrec).?;
                            if (nd.op == .not) nd = llir.decode(image.instructions[pc + 2]).?;
                            try testing.expectEqual(llir.Opcode.copy, nd.op);
                            try testing.expectEqual(b.slotOf(ins.results[0]), nd.a);
                            try testing.expectEqual(llir.cond_reg, nd.b);
                        }
                    },
                    .num_cast => {
                        const rec = image.instructions[pc];
                        const d = llir.decode(rec).?;
                        try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                        try testing.expect(n_cast < cast_want.len);
                        try testing.expectEqual(cast_want[n_cast], d.op);
                        n_cast += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(cast_want.len, n_cast);
    // `bool`/`str` have no ordering opcodes (Core §16.3: ordering is
    // numeric + byte only): assert the model and the emitted image carry
    // no bool_lt/str_lt family.
    try testing.expect(!@hasField(llir.Opcode, "bool_lt"));
    try testing.expect(!@hasField(llir.Opcode, "str_lt"));
}

test "2.7 LLIR lowering: phi elimination emits copy/borrow edge records, no phi opcode" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn pick(a: int32, b: int32) -> int32 {
            \\    if (a < b) { a } else { b }
            \\}
            \\struct P { x: int32; }
            \\fn pick_field(c: bool, borrow p1: P, borrow p2: P) -> int32 {
            \\    let v = if (c) { p1 } else { p2 };
            \\    v.x
            \\}
            \\fn main() -> void {
            \\    let x = pick(1, 2);
            \\    builtin.print(builtin.str(x));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // Verify every phi's edge elimination: on each predecessor edge, the
    // records of the edge's LLIR-only edge block (stage 7) must be
    // exactly `edgeCopyList(pred, succ)` — right opcode (`copy` for a
    // Copy source, `borrow` for a borrowed view), right dst/src slots,
    // ordered so sources are read before destinations are written.
    var n_phi: usize = 0;
    var n_copy: usize = 0;
    var n_borrow: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f).?;
        const frange = b.block_ranges.items[fid];
        for (0..frange.len) |k| {
            const bi = frange.start + k;
            const blk = b.ordered_blocks.items[bi];
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) n_phi += 1;
            }
            switch (blk.terminator) {
                .j => |t| try checkEdgeCopies(&b, image, blk, t, edgeBlockBase(&b, blk, t), &n_copy, &n_borrow),
                .br => |br| {
                    try checkEdgeCopies(&b, image, blk, br.then_, edgeBlockBase(&b, blk, br.then_), &n_copy, &n_borrow);
                    try checkEdgeCopies(&b, image, blk, br.else_, edgeBlockBase(&b, blk, br.else_), &n_copy, &n_borrow);
                },
                else => {},
            }
        }
    }
    // pick's diamond and pick_field's diamond both join with a phi; the
    // Copy join emits `copy` records, the borrowed-view join (two
    // borrow-mode params) emits `borrow` records.
    try testing.expect(n_phi >= 2);
    try testing.expect(n_copy >= 1);
    try testing.expect(n_borrow >= 1);
    // The image carries no phi opcode (there is none — elimination is
    // total by construction).
    try testing.expect(!@hasField(llir.Opcode, "phi"));
}

fn checkEdgeCopies(b: *const cfg_lower_llir.Builder, image: llir.LlirProgram, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock, base: u32, n_copy: *usize, n_borrow: *usize) !void {
    const list = try b.edgeCopyList(pred, succ);
    var pc = base;
    for (list) |c| {
        const rec = image.instructions[pc];
        const d = llir.decode(rec).?;
        try testing.expectEqual(c.op, d.op);
        try testing.expectEqual(c.dst, d.a);
        try testing.expectEqual(c.src, d.b);
        try testing.expectEqual(@as(u32, 0), d.c);
        if (c.op == .copy) n_copy.* += 1;
        if (c.op == .borrow) n_borrow.* += 1;
        pc += 1;
    }
}

/// The record base of an edge's effects: the stage-7 edge block's start
/// PC when the edge routes through one (its copies occupy its own list,
/// non_phi = 0), else the predecessor's inline edge position (an
/// effect-free edge has an empty list either way).
fn edgeBlockBase(b: *const cfg_lower_llir.Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) u32 {
    const edge = b.targetForEdge(pred, succ);
    if (edge != succ) return b.pcOf(edge);
    return b.pcOf(pred) + b.non_phi_counts.items[b.block_ids.get(pred).?];
}

test "2.3 LLIR lowering: a threaded join's phi keeps a slot its branch-edge copy cannot clobber" {
    // Jump threading re-keys a join's phi to the branching predecessor:
    // `if (c) { a } else { b }` with a trivial then lowers to a `br` that
    // targets the join directly, and the then-incoming's edge copy sits
    // in the branch block BEFORE the branch — it executes on both edges.
    // Coalescing the phi with the *other* (else) incoming's slot would
    // let that copy clobber the slot on the else path, whose own copy is
    // then a `src == dst` self-loop elision — the join would read the
    // then value on the else path. Regression: the phi coalesces with
    // the branch-side incoming's slot, and the else edge carries a real
    // copy into it.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn pick_str(c: bool, a: str, b: str) -> str {
            \\    if (c) { a } else { b }
            \\}
            \\fn main() -> void {
            \\    let s = pick_str(true, "x", "y");
            \\    builtin.print(s);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const f = helpers.findFunc(program, "app.pick_str");
    const br_blk = findBlock(f.blocks, "entry");
    const else_blk = findBlock(f.blocks, "else");
    const join_blk = findBlock(f.blocks, "join");
    // The threaded shape: the br targets the join directly.
    try testing.expect(br_blk.terminator.br.then_ == join_blk);
    // The join's phi and its two incomings, keyed by pred block.
    var phi: ?*const cfg.Value = null;
    var then_in: ?*const cfg.Value = null;
    var else_in: ?*const cfg.Value = null;
    for (join_blk.instrs) |ins| {
        if (ins.op != .phi) continue;
        phi = ins.results[0];
        for (ins.op.phi.incoming) |inc| {
            if (inc.pred == br_blk) then_in = inc.value;
            if (inc.pred == else_blk) else_in = inc.value;
        }
    }
    const phi_v = phi.?;
    const then_v = then_in.?;
    const else_v = else_in.?;
    // The phi coalesces with the branch-side incoming's slot — never the
    // else incoming's (whose edge copy would be a self-loop elision).
    try testing.expectEqual(b.slotOf(then_v), b.slotOf(phi_v));
    try testing.expect(b.slotOf(phi_v) != b.slotOf(else_v));
    // The else edge carries a real copy into the phi slot — now in the
    // LLIR-only edge block (stage 7) that routes the else→join edge.
    const eblk = b.targetForEdge(else_blk, join_blk);
    const bid = b.block_ids.get(eblk).?;
    const d = image.blocks[bid];
    var saw_copy = false;
    var pc = d.start_pc;
    while (pc < d.end_pc) : (pc += 1) {
        const rec = image.instructions[pc];
        const rd = llir.decode(rec).?;
        if ((rd.op == .copy or rd.op == .copy_retain) and rd.a == b.slotOf(phi_v) and rd.b == b.slotOf(else_v)) saw_copy = true;
    }
    try testing.expect(saw_copy);
}

test "2.7 LLIR lowering: hand-written edge copies — reverse-topo ordering, move joins, self-loop elision, scratch-staged swap" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @dep(a: int32, b: int32) -> int32 {
        \\entry:
        \\    %2: bool = lt %0, %1
        \\    br %2 ? then : else
        \\then:
        \\    j join
        \\else:
        \\    %3: int32 = const 2
        \\    j join
        \\join:
        \\    %4: int32 = phi [%0, then], [%3, else]
        \\    %5: int32 = phi [%4, then], [%0, else]
        \\    ret %5
        \\}
        \\func @uniq(c: bool, a1: any, a2: any) -> any {
        \\entry:
        \\    br %0 ? then : else
        \\then:
        \\    j join
        \\else:
        \\    j join
        \\join:
        \\    %3: any = phi [%1, then], [%2, else]
        \\    ret %3
        \\}
        \\func @selfloop(x: int32) -> int32 {
        \\entry:
        \\    j body
        \\body:
        \\    %1: int32 = phi [%0, entry], [%1, body]
        \\    j body
        \\}
        \\func @swap(x: int32, y: int32) -> int32 {
        \\entry:
        \\    j body
        \\body:
        \\    %2: int32 = phi [%0, entry], [%3, body]
        \\    %3: int32 = phi [%1, entry], [%2, body]
        \\    j body
        \\}
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // -- @dep: linear scan coalesces the two integer phi results with the
    // incoming slots, so this edge has no materialized copies.
    const dep = b.func_ids.get(program.funcs[0]).?;
    const dep_range = b.block_ranges.items[dep];
    const dep_blocks = b.ordered_blocks.items[dep_range.start .. dep_range.start + dep_range.len];
    const then_blk = findBlock(dep_blocks, "then");
    const join_blk = findBlock(dep_blocks, "join");
    const then_base = b.pcOf(then_blk) + b.non_phi_counts.items[dep_range.start + @as(u32, @intCast(blockIdx(dep_blocks, "then")))];
    const then_copies = try b.edgeCopyList(then_blk, join_blk);
    try testing.expectEqual(@as(usize, 0), then_copies.len);
    try testing.expectEqual(llir.Opcode.j, llir.decode(image.instructions[then_base]).?.op);

    // -- @uniq: an `any` join transfers ownership (any is unique per the
    // classifier) — `move` on each edge.
    const uniq = b.func_ids.get(program.funcs[1]).?;
    const uniq_range = b.block_ranges.items[uniq];
    const uniq_blocks = b.ordered_blocks.items[uniq_range.start .. uniq_range.start + uniq_range.len];
    const uniq_then = findBlock(uniq_blocks, "then");
    const uniq_join = findBlock(uniq_blocks, "join");
    const uniq_base = b.pcOf(uniq_then) + b.non_phi_counts.items[uniq_range.start + @as(u32, @intCast(blockIdx(uniq_blocks, "then")))];
    const uniq_copies = try b.edgeCopyList(uniq_then, uniq_join);
    try testing.expectEqual(@as(usize, 0), uniq_copies.len);
    _ = uniq_base; // no edge record remains after source-slot coalescing.

    // -- @selfloop: phi %1 merges with param %0 (same type, non-overlapping
    // liveness), so both edges have 0 copies.
    const sl = b.func_ids.get(program.funcs[2]).?;
    const sl_range = b.block_ranges.items[sl];
    const sl_blocks = b.ordered_blocks.items[sl_range.start .. sl_range.start + sl_range.len];
    const sl_entry = findBlock(sl_blocks, "entry");
    const sl_body = findBlock(sl_blocks, "body");
    try testing.expectEqual(@as(usize, 0), (try b.edgeCopyList(sl_entry, sl_body)).len);
    try testing.expectEqual(@as(usize, 0), (try b.edgeCopyList(sl_body, sl_body)).len); // self-loop elided
    // No edge copies at all: entry has just `j`, body has just `ret`.
    const sl_entry_desc = image.blocks[sl_range.start + @as(u32, @intCast(blockIdx(sl_blocks, "entry")))];
    try testing.expectEqual(@as(u32, 1), sl_entry_desc.end_pc - sl_entry_desc.start_pc);
    const sl_blocks_desc = image.blocks[sl_range.start + @as(u32, @intCast(blockIdx(sl_blocks, "body")))];
    try testing.expectEqual(@as(u32, 1), sl_blocks_desc.end_pc - sl_blocks_desc.start_pc);

    // -- @swap: the 2-cycle on the back edge breaks through one int32
    // scratch slot (2.8): stage y → scratch, x → y, scratch → x — 3 records; the
    // entry edge has 0 copies because phi merging reuses param slots.
    const sw = b.func_ids.get(program.funcs[3]).?;
    const sw_range = b.block_ranges.items[sw];
    const sw_blocks = b.ordered_blocks.items[sw_range.start .. sw_range.start + sw_range.len];
    const sw_body = findBlock(sw_blocks, "body");
    const sw_entry = findBlock(sw_blocks, "entry");
    try testing.expectEqual(@as(usize, 3), (try b.edgeCopyList(sw_body, sw_body)).len);
    try testing.expectEqual(@as(usize, 0), (try b.edgeCopyList(sw_entry, sw_body)).len);
    // The staging record writes the scratch slot; the final record reads
    // it back — the swap is serialized through exactly one int32 scratch slot.
    const sw_copies = try b.edgeCopyList(sw_body, sw_body);
    // Phase 4: derive the staging slot from the actual copies.
    const sw_staging = sw_copies[0].dst;
    try testing.expectEqual(sw_staging, sw_copies[2].src);
    try testing.expectEqual(sw_copies[1].dst, sw_copies[0].src); // the cycle copy refills the staged slot
    try testing.expectEqual(sw_copies[0].op, llir.Opcode.copy);
    try testing.expectEqual(sw_copies[1].op, llir.Opcode.copy);
    try testing.expectEqual(sw_copies[2].op, llir.Opcode.copy);
    // body's back-edge copies now live in the LLIR-only edge block (stage
    // 7): body holds just its `j`, and the edge block carries the 3-cycle
    // + its final `j`; entry has just `j`.
    const sw_entry_desc = image.blocks[sw_range.start + @as(u32, @intCast(blockIdx(sw_blocks, "entry")))];
    try testing.expectEqual(@as(u32, 1), sw_entry_desc.end_pc - sw_entry_desc.start_pc);
    const sw_edge = b.targetForEdge(sw_body, sw_body);
    const sw_edge_desc = image.blocks[b.block_ids.get(sw_edge).?];
    try testing.expectEqual(@as(u32, 4), sw_edge_desc.end_pc - sw_edge_desc.start_pc);
    const sw_body_desc = image.blocks[sw_range.start + @as(u32, @intCast(blockIdx(sw_blocks, "body")))];
    try testing.expectEqual(@as(u32, 1), sw_body_desc.end_pc - sw_body_desc.start_pc);
}

test "3.1 LLIR lowering: F-bank exhaustion spills the peak-live chain into X" {
    // A straight-line chain whose register demand exceeds the direct bank:
    // 115 constants %0..%114 are all live together when the add chain
    // starts (peak liveness = 115 cells > 109 F), so 115 - (109 - 1
    // staging) = 7 values must move to X cells. The spill selection is
    // peak-aware: only values occupying cells at the peak-liveness
    // position count as victims (a dead-at-end range would not reduce the
    // peak), and the survivors are remapped dense into 0..k-1 with the
    // reserved staging cell at f_count - 1.
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "module \"app\" {\nfunc @chain() -> int32 {\nentry:\n");
    for (0..115) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "    %{d}: int32 = const {d}\n", .{ i, i });
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    for (0..114) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "    %{d}: int32 = add %{d}, %{d}\n", .{ 115 + i, 114 + i, i + 1 });
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator, "    ret %228\n}\n}\n");
    var t = try cfg_parse.parseText(src.items);
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    var image = try b.lowerLlir();

    try testing.expect(!b.operand_overflow);
    try testing.expect(!b.id_overflow);
    const fi = b.func_ids.get(program.funcs[0]).?;
    const fd = image.functions[fi];
    try testing.expectEqual(@as(u32, 109), fd.f_count); // survivors + 1 spill staging
    try testing.expectEqual(@as(u32, 11), fd.x_count);
    try testing.expect(fd.f_count <= llir.frame_count_max);

    // Exactly 11 values map to the T-range sentinel bytes (0x02..0x11);
    // every other value maps to a frame encoding below frame_base + frame_count_max.
    var n_sentinel: usize = 0;
    for (program.funcs[0].values) |v| {
        const sl = b.slotOf(v);
        if (llir.isTemp(@intCast(sl))) {
            n_sentinel += 1;
            try testing.expect(sl < llir.temp_base + llir.temp_count);
            try testing.expect(b.spill_x.get(@intCast(sl)) != null);
        } else {
            try testing.expect(llir.isFrame(@intCast(sl)));
            try testing.expect(llir.frameIndex(@intCast(sl)) < llir.frame_count_max);
        }
    }
    try testing.expectEqual(@as(usize, 11), n_sentinel); // peak 119 cells: 119 - 11 + 1 staging = 109

    // The image validates: the sentinel-bearing records were expanded
    // into spill_take/spill_put sequences by expandSpills.
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }

    // End-to-end: the spilled chain executes and returns the expected
    // sum. %228 = %114 + %1 + %2 + ... + %114 = 114 + (1..114) = 6669.
    const interpreter = @import("interpreter.zig");
    var term = try interpreter.runValidatedWithEntry(testing.allocator, &image, fi, .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(u64, 6669), v),
        .panic => return error.TestUnexpectedResult,
    }
}

test "3.1 LLIR lowering: zero emission — void results write the zero register" {
    // A void expression in a register position lowers to a write of the
    // zero register (Instruction Set §5): the `ret` of a void function,
    // and the result of a void-typed const. The lowering never names a
    // void phantom's slot row.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @v() -> void {
        \\entry:
        \\    %0: void = const 0
        \\    ret %0
        \\}
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const fi = b.func_ids.get(program.funcs[0]).?;
    const range = b.block_ranges.items[fi];
    var saw_zero_const = false;
    var saw_zero_ret = false;
    for (range.start..range.start + range.len) |bi| {
        const blk = b.ordered_blocks.items[bi];
        var pc = b.pcOf(blk);
        for (blk.instrs) |ins| {
            if (std.meta.activeTag(ins.op) == .const_) {
                const d = llir.decode(image.instructions[pc]).?;
                try testing.expectEqual(llir.Opcode.const_, d.op);
                try testing.expectEqual(llir.zero_reg, d.a); // the void result discards into zero
                saw_zero_const = true;
            }
            pc += try b.recordCount(blk, ins);
        }
        const term = llir.decode(image.instructions[pc]).?;
        if (term.op == .ret) {
            try testing.expectEqual(llir.zero_reg, term.a); // void ret carries zero
            saw_zero_ret = true;
        }
    }
    try testing.expect(saw_zero_const);
    try testing.expect(saw_zero_ret);
}

test "3.1 LLIR lowering: inline member-desc IDs — 127 fits, 128 is IdOutOfRange" {
    // Member descriptors are inline dense IDs in the read_field record's
    // 7-bit field (Instruction Set §10). 128 distinct member references
    // intern descs 0..127 — the last fits — and the 129th (index 128)
    // overflows the field and surfaces as the fixed error.IdOutOfRange.
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "module \"app\" {\nfunc @fields(s: Point) -> void {\nentry:\n");
    for (0..128) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "    %{d}: int32 = read_field %0, #{d}\n", .{ i + 1, i });
        defer testing.allocator.free(line);
        try src.appendSlice(testing.allocator, line);
    }
    try src.appendSlice(testing.allocator, "    ret\n}\n}\n");
    var t = try cfg_parse.parseText(src.items);
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expect(!b.id_overflow);
    try testing.expectEqual(@as(usize, 128), b.member_descs.items.len);
    if (try llir_validate.validate(&image, testing.allocator)) |msg| {
        testing.allocator.free(msg);
        return error.TestUnexpectedResult;
    }

    // The 129th distinct member reference pushes desc id 128 — overflow.
    var src2 = std.ArrayList(u8).empty;
    defer src2.deinit(testing.allocator);
    try src2.appendSlice(testing.allocator, "module \"app\" {\nfunc @fields(s: Point) -> void {\nentry:\n");
    for (0..129) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "    %{d}: int32 = read_field %0, #{d}\n", .{ i + 1, i });
        defer testing.allocator.free(line);
        try src2.appendSlice(testing.allocator, line);
    }
    try src2.appendSlice(testing.allocator, "    ret\n}\n}\n");
    var t2 = try cfg_parse.parseText(src2.items);
    defer t2.arena.deinit();
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var b2 = cfg_lower_llir.Builder.init(arena2.allocator(), &t2.program);
    try testing.expectError(error.IdOutOfRange, b2.lowerLlir());
}
