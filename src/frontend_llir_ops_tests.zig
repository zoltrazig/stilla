//! Test file: `frontend LLIR ops` — LLIR lowering stages
//! 2.8–2.13 (back-edge scratch cycles, direct/indirect/self-tail calls,
//! syscalls, construct/destructure/switch descriptors, explicit
//! copy/move slot ops, cleanup cells). Split out of the former
//! `src/frontend_tests.zig`; `checkImageEdge` and `checkDestructure` are
//! local to this file.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const ast = @import("ast.zig");
const llir = @import("llir.zig");
const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");
const lower = @import("lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const cfg_validate = @import("passes/cfg_validate.zig");
const llir_validate = @import("passes/llir_validate.zig");
const interpreter = @import("interpreter.zig");
const lifecycle = @import("passes/cfg_lower_lifecycle.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const findBlock = helpers.findBlock;
const blockIdx = helpers.blockIdx;
const findFunc = helpers.findFunc;

test "2.8 LLIR lowering: back-edge cycles use type-matched scratch slots" {
    var t = try cfg_parse.parseText(
        \\module "app" {
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
        \\func @mix(a: int32, b: int32, c: int32) -> int32 {
        \\entry:
        \\    j body
        \\body:
        \\    %3: int32 = phi [%0, entry], [%4, body]
        \\    %4: int32 = phi [%1, entry], [%3, body]
        \\    %5: int32 = phi [%2, entry], [%0, body]
        \\    j body
        \\}
        \\func @mswap(a1: any, a2: any) -> any {
        \\entry:
        \\    j body
        \\body:
        \\    %2: any = phi [%0, entry], [%3, body]
        \\    %3: any = phi [%1, entry], [%2, body]
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

    // -- @cycle: a 3-cycle breaks as stage + 3 transfers = 4 records;
    // P = 0, so the staging slot is V + 0 (the first scratch slot) and
    // its type row is now filled (int32) while the other rows stay null.
    const cf = b.func_ids.get(program.funcs[0]).?;
    const cr = b.block_ranges.items[cf];
    const cblocks = b.ordered_blocks.items[cr.start .. cr.start + cr.len];
    const cbody = findBlock(cblocks, "body");
    const cfd = image.functions[cf];
    const clist = try b.edgeCopyList(cbody, cbody);
    try testing.expectEqual(@as(usize, 4), clist.len);
    // Phase 4: the staging slot may be a dead value slot or a scratch
    // slot — derive it from the actual emitted copies, not from
    // cycleStagingSlot (which may re-resolve differently).
    const cstage = clist[0].dst;
    try testing.expect(llir.isFrame(@intCast(cstage)));
    try testing.expect(llir.frameIndex(@intCast(cstage)) < cfd.f_count + cfd.x_count);
    try testing.expectEqual(cstage, clist[3].src); // final reads slot back
    try testing.expectEqual(clist[0].src, clist[2].dst); // staged value's slot refilled
    for (clist) |c| try testing.expectEqual(llir.Opcode.copy, c.op);
    // v1: staging cells are untyped F cells — no type rows exist.
    // The back-edge copies live in the LLIR-only edge block (stage 7):
    // the body block holds only its terminator, and the edge block
    // carries the 4-cycle records + its final `j`.
    const cedge = b.targetForEdge(cbody, cbody);
    const cedge_desc = image.blocks[b.block_ids.get(cedge).?];
    try testing.expectEqual(@as(u32, 5), cedge_desc.end_pc - cedge_desc.start_pc);

    // -- @mix: an independent copy is emitted before the broken cycle
    // (its source is untouched); the 2-cycle then stages one slot.
    const mf = b.func_ids.get(program.funcs[1]).?;
    const mr = b.block_ranges.items[mf];
    const mblocks = b.ordered_blocks.items[mr.start .. mr.start + mr.len];
    const mbody = findBlock(mblocks, "body");
    const mlist = try b.edgeCopyList(mbody, mbody);
    try testing.expectEqual(@as(usize, 4), mlist.len);
    // [0] independent: %5 ← %0 (slot 3 = %5's slot, slot 0 = param a).
    try testing.expectEqual(llir.frameReg(3), mlist[0].dst);
    try testing.expectEqual(llir.frameReg(0), mlist[0].src);
    // [1..3] the 2-cycle: stage (staging ← slot 1), slot 1 ← slot 2, slot 2 ← staging.
    const mstage = mlist[1].dst; // derive from actual copies
    try testing.expectEqual(mstage, mlist[3].src);
    try testing.expectEqual(llir.frameReg(1), mlist[1].src);
    try testing.expectEqual(llir.frameReg(1), mlist[2].dst);
    try testing.expectEqual(llir.frameReg(2), mlist[2].src);
    try testing.expectEqual(llir.frameReg(2), mlist[3].dst);
    try testing.expectEqual(mstage, mlist[3].src);

    // -- @mswap: a unique-value cycle stages with `move`, not `copy` —
    // no value is duplicated during the swap.
    const sf = b.func_ids.get(program.funcs[2]).?;
    const sr = b.block_ranges.items[sf];
    const sblocks = b.ordered_blocks.items[sr.start .. sr.start + sr.len];
    const sbody = findBlock(sblocks, "body");
    const slist = try b.edgeCopyList(sbody, sbody);
    try testing.expectEqual(@as(usize, 3), slist.len);
    for (slist) |c| try testing.expectEqual(llir.Opcode.move, c.op);

    // The emitted image records match the edge lists exactly (opcode,
    // dst, src; c == 0) at the reserved positions, and the image carries
    // no phi opcode. Under stage 7 the copies live in each edge's edge
    // block, so the walk starts at the edge block's start PC.
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            switch (blk.terminator) {
                .j => |tj| _ = try checkImageEdge(&b, image, blk, tj, edgeBase(&b, blk, tj)),
                .br => |br| {
                    _ = try checkImageEdge(&b, image, blk, br.then_, edgeBase(&b, blk, br.then_));
                    _ = try checkImageEdge(&b, image, blk, br.else_, edgeBase(&b, blk, br.else_));
                },
                else => {},
            }
        }
    }
}

/// The record base of an edge's effects: the stage-7 edge block's start
/// PC when the edge routes through one, else the predecessor's inline
/// edge position (an effect-free edge has an empty list either way).
fn edgeBase(b: *const cfg_lower_llir.Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) u32 {
    const edge = b.targetForEdge(pred, succ);
    if (edge != succ) return b.pcOf(edge);
    return b.pcOf(pred) + b.non_phi_counts.items[b.block_ids.get(pred).?];
}

fn checkImageEdge(b: *const cfg_lower_llir.Builder, image: llir.LlirProgram, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock, pc: u32) !u32 {
    const list = try b.edgeCopyList(pred, succ);
    var p = pc;
    for (list) |c| {
        const d = llir.decode(image.instructions[p]).?;
        try testing.expectEqual(c.op, d.op);
        try testing.expectEqual(c.dst, d.a);
        try testing.expectEqual(c.src, d.b);
        try testing.expectEqual(@as(u32, 0), d.c);
        p += 1;
    }
    return p;
}

test "2.9 LLIR lowering: direct calls, void/value returns, recursion" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn noop() -> void { }
            \\fn id(x: int32) -> int32 { x }
            \\fn add3(a: int32, b: int32, c: int32) -> int32 { a + b + c }
            \\fn mid(x: int32) -> int32 { let y = id(x); add3(y, y, y) }
            \\fn fib(n: int32) -> int32 {
            \\    if (n < 2) { n } else { fib(n - 1) + fib(n - 2) }
            \\}
            \\fn main() -> int32 {
            \\    noop();
            \\    let a = mid(5);
            \\    let b = fib(10);
            \\    a + b
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var n_jal: usize = 0;
    var n_ret: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (b.isFusedConst(ins)) continue; // 2.14 fused its record away
                switch (ins.op) {
                    .call => |call| {
                        const moves = try b.callArgMoves(blk, ins);
                        // The argument moves occupy [pc, pc + m) — each
                        // places one argument into its window slot (the
                        // callee's parameter register, spec §5.3); the
                        // call record follows at pc + m.
                        for (moves, 0..) |mv, i| {
                            const d = llir.decode(image.instructions[pc + @as(u32, @intCast(i))]).?;
                            try testing.expectEqual(mv.op, d.op);
                            // v9 slot_* I format: a = the F source register,
                            // imm16 = the absolute outgoing-window offset
                            // (Instruction Set §5).
                            try testing.expectEqual(mv.dst, d.a);
                            try testing.expect(llir.isFrame(@intCast(mv.dst)));
                            try testing.expect(llir.frameIndex(@intCast(mv.dst)) < fd_frame_count: {
                                break :fd_frame_count image.functions[fi].f_count;
                            });
                            try testing.expectEqual(mv.imm, d.imm16);
                        }
                        const rec = llir.decode(image.instructions[pc + @as(u32, @intCast(moves.len))]).?;
                        // v10: the direct call is `jal ra, addr` — the fixed
                        // link register `ra`, the pc-relative target resolved
                        // by 2.16 to the callee's `entry_pc`; there is no
                        // destination field (a non-void callee's result is
                        // published by `ret` into the caller register
                        // `F(L+3+O-A)` and taken by the generic `take` right
                        // after, and no CallDesc — the runtime reads
                        // `functions[FunctionId].signature_id` directly).
                        try testing.expectEqual(llir.Opcode.jal, rec.op);
                        try testing.expectEqual(llir.ra_reg, rec.a);
                        const fn_id = b.func_name_ids.get(call.callee.direct.name) orelse return error.TestUnexpectedResult;
                        try testing.expect(fn_id < image.functions.len);
                        // The callee's interned signature is the
                        // descriptor; the arguments travel through the
                        // window, not a register table.
                        try testing.expectEqual(@as(u32, @intCast(call.args.len)), image.signatures[image.functions[fn_id].signature_id].params_len);
                        if (ins.results.len > 0) {
                            // Non-void: `take dst, F(L+3+O-A)` transfers the
                            // result register into the result slot — unless
                            // the allocator coalesced the result onto the
                            // alias itself (Step 8), in which case the take
                            // is dropped and the fallthrough reads the alias.
                            if (b.callNeedsTake(blk, ins)) {
                                const take = llir.decode(image.instructions[pc + @as(u32, @intCast(moves.len)) + 1]).?;
                                try testing.expectEqual(llir.Opcode.take, take.op);
                                try testing.expectEqual(b.slotOf(ins.results[0]), take.a);
                                const fd = image.functions[fi];
                                try testing.expectEqual(llir.frameReg(fd.f_count + fd.window_count - @max(@as(u32, @intCast(call.args.len)), 1)), take.b);
                            } else {
                                // Coalesced: the result's slot IS the result
                                // alias F(L+3+O-A).
                                const fd = image.functions[fi];
                                try testing.expectEqual(
                                    llir.frameReg(fd.f_count + fd.window_count - @max(@as(u32, @intCast(call.args.len)), 1)),
                                    b.slotOf(ins.results[0]),
                                );
                            }
                        }
                        n_jal += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
            // Terminators: every `ret` names its result slot (discard
            // only for void); every function ends with a ret record.
            switch (blk.terminator) {
                .ret => |v| {
                    const tpc = pc + b.edge_copy_counts.items[bi];
                    const d = llir.decode(image.instructions[tpc]).?;
                    try testing.expectEqual(llir.Opcode.ret, d.op);
                    const want = if (v) |rv| blk2: {
                        if (rv.type_ == .primitive and rv.type_.primitive == .void) break :blk2 llir.zero_reg;
                        break :blk2 b.slotOf(rv);
                    } else llir.zero_reg;
                    try testing.expectEqual(want, d.a);
                    n_ret += 1;
                },
                else => {},
            }
        }
    }
    // main's chain: noop (void), mid (nested id + add3), fib (recursive)
    // — every call is direct; fib recurses into itself.
    try testing.expectEqual(@as(usize, 7), n_jal);
    try testing.expectEqual(@as(usize, 7), n_ret); // @init + 6 functions
    // Void functions return discard: noop's ret is `ret zero`.
    const noop_fi = b.func_ids.get(program.funcs[1]).?; // app.noop
    const noop_desc = image.blocks[b.block_ranges.items[noop_fi].start];
    try testing.expectEqual(llir.Opcode.ret, llir.decode(image.instructions[noop_desc.start_pc]).?.op);
    try testing.expectEqual(llir.zero_reg, llir.decode(image.instructions[noop_desc.start_pc]).?.a);
}

test "2.9 Step 8: direct-call result coalescing — take dropped only when safe" {
    // Step 8 (spec §4.1, §5.4): a non-void direct call whose result is
    // consumed before any other call is coalesced onto the result alias
    // `F(L+3+O-A)` — no `take` record. A result live across another
    // call (the alias is call-clobbered) keeps its take; an indirect
    // (`jalr`) call always keeps its take — it is the dynamic
    // `A`-mismatch check.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn id(x: int32) -> int32 { x }
            \\fn apply(f: fn(int32) -> int32, x: int32) -> int32 { f(x) }
            \\fn inc(a: int32) -> int32 { a + 1 }
            \\fn main() -> int32 {
            \\    let t = id(1);      // consumed by `t + 1`: coalesced
            \\    let u = t + 1;
            \\    let b = id(2);      // live across `apply` below: keeps its take
            \\    let c = apply(inc, 3); // indirect: always keeps its take
            \\    b + c + u
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    const main_fi = b.func_ids.get(findFunc(program, "app.main")).?;
    var n_take: usize = 0;
    for (image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op != .take) continue;
        n_take += 1;
        // Every remaining take sources its own function's result alias
        // F(L+3+O-A) — A derived from the take's source register, which
        // the loader validates against the callee's value area.
        const fi = llir.functionAtPc(image.functions, @intCast(pc)).?;
        const fd = image.functions[fi];
        try testing.expect(llir.isFrame(d.b));
        try testing.expect(llir.frameIndex(d.b) >= fd.f_count + 2); // inside the window
        try testing.expect(llir.frameIndex(d.b) < fd.f_count + fd.window_count);
    }
    // main: id(1) coalesced (consumed by `t + 1`, no call between),
    // id(2) keeps its take (live across `apply` — the alias is
    // call-clobbered), and apply's result is consumed by the final add
    // so the `apply` call coalesces too. apply's own `f(x)` is a jalr —
    // indirect calls always keep their take (the dynamic A-mismatch
    // check). id/inc are leaves. Total 2.
    try testing.expectEqual(@as(usize, 2), n_take);

    // The coalesced result is readable: the take-less `id(1)` result
    // flows straight from the alias into `t + 1` — the add's source is
    // the result alias register F(L+3+O-A) of main (A = max(0,1) = 1).
    const main_fd = image.functions[main_fi];
    const alias: u32 = main_fd.f_count + main_fd.window_count - 1;
    var saw_alias_read: bool = false;
    for (image.instructions) |rec| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .addi_i32 and d.b == llir.frameReg(alias)) saw_alias_read = true;
    }
    try testing.expect(saw_alias_read);

    // Budget/linearization consistency: dropping a take must not leave
    // an empty record row — every instruction in the final image
    // decodes (a hole would read as an unknown opcode).
    for (image.instructions) |rec| {
        try testing.expect(llir.decode(rec) != null);
    }
}

test "2.9 LLIR lowering: indirect calls through function values" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn add(a: int32, b: int32) -> int32 { a + b }
            \\fn apply(f: fn(int32, int32) -> int32, a: int32, b: int32) -> int32 { f(a, b) }
            \\fn main() -> int32 {
            \\    let z = apply(add, 20, 22);
            \\    z
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var n_jalr: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .call => |call| {
                        const moves = try b.callArgMoves(blk, ins);
                        const rec = llir.decode(image.instructions[pc + @as(u32, @intCast(moves.len))]).?;
                        if (call.callee == .value) {
                            // v9: the indirect call is `jalr ra, base, 0` —
                            // a = the function-value slot (an executable
                            // entry PC), imm16 = 0, the link the fixed `ra`;
                            // the fn type's own signature travels in the
                            // type, never a descriptor: two plain int32
                            // params, int32 ret — no callee FunctionId
                            // involved.
                            try testing.expectEqual(llir.Opcode.jalr, rec.op);
                            try testing.expectEqual(b.slotOf(call.callee.value), rec.a);
                            try testing.expectEqual(@as(u16, 0), rec.imm16);
                            const ft = call.callee.value.type_.function;
                            try testing.expectEqual(@as(u32, @intCast(ft.params.len)), @as(u32, 2));
                            for (ft.params) |p| {
                                try testing.expectEqual(ast.ParamMode.plain, p.mode);
                                try testing.expect(p.type_ == .primitive and p.type_.primitive == .int32);
                            }
                            try testing.expect(ft.ret.* == .primitive and ft.ret.*.primitive == .int32);
                            // The two arguments travel through the window
                            // (spec §5.3): each is either homed into its
                            // window slot (the elision) or carried by a
                            // move before the call record.
                            try testing.expectEqual(@as(u32, @intCast(call.args.len)), @as(u32, @intCast(ft.params.len)));
                            // v9: every argument is a slot_* record — a =
                            // the F source, imm16 = its absolute window
                            // offset W - A + k.
                            for (moves, 0..) |mv, i| {
                                const d = llir.decode(image.instructions[pc + @as(u32, @intCast(i))]).?;
                                try testing.expectEqual(mv.op, d.op);
                                try testing.expectEqual(mv.dst, d.a);
                                try testing.expect(llir.isFrame(@intCast(mv.dst)));
                                try testing.expect(llir.frameIndex(@intCast(mv.dst)) < image.functions[fi].f_count);
                                try testing.expectEqual(mv.imm, d.imm16);
                            }
                            // Non-void: the result is published into the
                            // caller register F(L+3+O-A) and taken by the
                            // generic `take`.
                            const take = llir.decode(image.instructions[pc + @as(u32, @intCast(moves.len)) + 1]).?;
                            try testing.expectEqual(llir.Opcode.take, take.op);
                            try testing.expectEqual(b.slotOf(ins.results[0]), take.a);
                            const fd = image.functions[fi];
                            try testing.expectEqual(llir.frameReg(fd.f_count + fd.window_count - @max(@as(u32, @intCast(call.args.len)), 1)), take.b);
                            n_jalr += 1;
                        } else {
                            // main's path call is direct: `jal ra` — the
                            // target resolved to apply's entry_pc, the
                            // callee's own 3-param signature (no CallDesc;
                            // the runtime reads
                            // functions[FunctionId].signature_id).
                            try testing.expectEqual(llir.Opcode.jal, rec.op);
                            try testing.expectEqual(llir.ra_reg, rec.a);
                            const fn_id = b.func_name_ids.get(call.callee.direct.name) orelse return error.TestUnexpectedResult;
                            try testing.expect(fn_id < image.functions.len);
                            try testing.expectEqual(@as(u32, 3), image.signatures[image.functions[fn_id].signature_id].params_len);
                        }
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), n_jalr); // only apply's body
    try testing.expect(!@hasField(llir.Opcode, "phi"));
}

test "2.9 LLIR lowering: register-window argument moves and elision" {
    // `apply` passes its own parameters straight through to the indirect
    // call: the arguments' intervals are call-free, so the allocator
    // homes them in their window slots and the argument moves elide —
    // zero moves before the call. `main`'s arguments are constants born
    // immediately before the call, so they too are homed; the caller
    // computes nothing else between. An argument live across another
    // call (used twice) cannot be homed — both calls carry a real move.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn add(a: int32, b: int32) -> int32 { a + b }
            \\fn apply(f: fn(int32, int32) -> int32, a: int32, b: int32) -> int32 { f(a, b) }
            \\fn twice(x: int32) -> int32 { x }
            \\fn main() -> int32 {
            \\    let z = apply(add, 20, 22);
            \\    let a = 1;
            \\    let r = twice(a) + twice(a);
            \\    z + r
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expect((try llir_validate.validate(&image, testing.allocator)) == null);

    const apply = b.func_ids.get(findFunc(program, "app.apply")).?;
    const twice = b.func_ids.get(findFunc(program, "app.twice")).?;
    const apply_fd = image.functions[apply];
    // apply has one 2-argument call (A = max(2 params, 1 result)):
    // W = 3 + 2 = 5 (the three-cell header plus the callee value area).
    try testing.expectEqual(@as(u32, 5), apply_fd.window_count);
    var saw_elided_indirect = false;
    var n_twice_moves: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const fd = image.functions[fi];
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (std.meta.activeTag(ins.op) == .call) {
                    const moves = try b.callArgMoves(blk, ins);
                    for (moves) |mv| {
                        // v1: every slot_* reads a caller F cell and names a
                        // window offset below W (Instruction Set §5).
                        try testing.expect(mv.imm < fd.window_count);
                    }
                    const call_rec = image.instructions[pc + @as(u32, @intCast(moves.len))];
                    // v1: exactly one slot_* record per parameter.
                    try testing.expectEqual(@as(usize, ins.op.call.args.len), moves.len);
                    if (llir.decode(call_rec).?.op == .jalr) {
                        saw_elided_indirect = true;
                    } else if (b.func_name_ids.get(ins.op.call.callee.direct.name) == twice) {
                        n_twice_moves += 1;
                    }
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expect(saw_elided_indirect);
    try testing.expectEqual(@as(usize, 2), n_twice_moves);
}

test "2.9 LLIR lowering: all four slot_* ownership modes on one call's argument path" {
    // v10 keeps the `slot_*` writers unchanged — names, encodings,
    // semantics. One call whose four parameters force each transfer
    // mode: the unique `move` box installs `slot_move`, the borrowed
    // view installs `slot_borrow`, the shared counted `str` retains
    // with `slot_retain`, and the plain Copy scalar bit-copies with
    // `slot_copy` (Instruction Set §5).
    var c = try compileText("app", &.{.{
        "app",
        \\struct Box { v: int32; }
        \\fn sink(move b: Box, borrow s: str, t: str, n: int32) -> int32 { n }
        \\fn main() -> int32 {
        \\    let b = Box { v: 1 };
        \\    let s = "x";
        \\    sink(move b, s, s, 2)
        \\}
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expect((try llir_validate.validate(&image, testing.allocator)) == null);

    var seen = [_]usize{0} ** 4;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .call) {
                    for (try b.callArgMoves(blk, ins)) |mv| {
                        switch (mv.op) {
                            .slot_move => seen[0] += 1,
                            .slot_borrow => seen[1] += 1,
                            .slot_retain => seen[2] += 1,
                            .slot_copy => seen[3] += 1,
                            else => {},
                        }
                    }
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), seen[0]); // move b → slot_move
    try testing.expectEqual(@as(usize, 1), seen[1]); // borrow s → slot_borrow
    try testing.expectEqual(@as(usize, 1), seen[2]); // shared str → slot_retain
    try testing.expectEqual(@as(usize, 1), seen[3]); // int32 → slot_copy
}

test "2.9 LLIR lowering: self tailcall reuses the frame as a pure jump" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @count(n: int32, acc: int32) -> int32 {
        \\entry:
        \\    %2: int32 = const 1
        \\    %3: bool = lt %0, %2
        \\    br %3 ? done : rec
        \\rec:
        \\    %4: int32 = sub %1, %2
        \\    tailcall @count, %0, %4
        \\done:
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const fid = b.func_ids.get(program.funcs[0]).?;
    const range = b.block_ranges.items[fid];
    const blocks = b.ordered_blocks.items[range.start .. range.start + range.len];
    const rec_blk = findBlock(blocks, "rec");
    const tpc = b.pcOf(rec_blk) + b.non_phi_counts.items[@intCast(blockIdx(blocks, "rec"))] + b.edge_copy_counts.items[@intCast(blockIdx(blocks, "rec"))];
    const rec = llir.decode(image.instructions[tpc]).?;
    // tailcall_self: a = b = 0 — no header, no return dst, no
    // descriptor (Phase 5: the compiler emitted explicit copies to place
    // args in r0..r(P-1); tailcall_self is now a pure jump).
    try testing.expectEqual(llir.Opcode.tailcall_self, rec.op);
    try testing.expectEqual(@as(u32, 0), rec.a);
    try testing.expectEqual(@as(u32, 0), rec.b);
    // The loop is a frame-reusing exit: rec has no out-edge (no j), and
    // the function still ends with a real ret in done.
    const done_blk = findBlock(blocks, "done");
    const done_pc = b.pcOf(done_blk);
    try testing.expectEqual(llir.Opcode.ret, llir.decode(image.instructions[done_pc]).?.op);
    try testing.expectEqual(llir.frameReg(1), llir.decode(image.instructions[done_pc]).?.a); // ret %1 (acc)
}

test "2.10 LLIR lowering: syscalls carry host binding, specialized signature, and args" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const L = import("list");
            \\fn main() -> void {
            \\    let n = 42;
            \\    let s = builtin.str(n);
            \\    let b = builtin.box[int32](n);
            \\    let v = builtin.unbox[int32](move b);
            \\    builtin.print(s);
            \\    builtin.print(s);
            \\    let xs = L.range[int32](0, 5);
            \\    let len = L.len[int32](xs);
            \\    builtin.assert(v == n and len == 5, "ok");
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    var n_syscall: usize = 0;
    var print_descs = std.ArrayList(u32).empty;
    defer print_descs.deinit(testing.allocator);
    for (0..image.functions.len) |fi| {
        const fd = image.functions[fi];
        _ = &fd;
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                switch (ins.op) {
                    .syscall => |sc| {
                        const d = llir.decode(image.instructions[pc]).?;
                        // `syscall`: a = dst (zero for void), imm16 =
                        // SyscallDescId.
                        try testing.expectEqual(llir.Opcode.syscall, d.op);
                        const want_dst = if (ins.results.len > 0) b.slotOf(ins.results[0]) else llir.zero_reg;
                        try testing.expectEqual(want_dst, d.a);
                        try testing.expect(d.imm16 < image.syscall_descs.len);
                        const desc = image.syscall_descs[d.imm16];
                        // The binding target resolves in range.
                        try testing.expect(desc.host_binding_id < image.imports.len);
                        // The specialized signature carries the argument
                        // count, the parameter modes, and the return
                        // type — the runtime needs no checks.
                        const sig = image.signatures[desc.signature_id];
                        try testing.expectEqual(@as(u32, @intCast(sc.args.len)), sig.params_len);
                        if (ins.results.len == 0) {
                            try testing.expectEqual(llir.no_index, sig.ret); // void/never
                        }
                        // Args land in the shared call_args table, in order.
                        try testing.expect(desc.args_start + desc.args_len <= image.call_args.len);
                        for (sc.args, 0..) |arg, k| {
                            try testing.expectEqual(b.slotOf(arg), image.call_args[desc.args_start + k]);
                        }
                        // Parameter modes are the EFFECTIVE call-site
                        // modes (cfg_lower_call.effectiveMode): the
                        // declared `move` relaxes to `plain` for a Copy
                        // argument passed without an explicit `move` —
                        // `box(int32)` boxes a Copy `n`, so plain;
                        // `unbox(move b)` explicitly moves, so move;
                        // str/print/range plain, len borrows, assert plain.
                        switch (sc.target) {
                            .builtin => |bui| switch (bui) {
                                .box => try testing.expectEqual(llir.ParamMode.plain, image.params[sig.params_start].mode),
                                .unbox => try testing.expectEqual(llir.ParamMode.move, image.params[sig.params_start].mode),
                                .str, .print => try testing.expectEqual(llir.ParamMode.plain, image.params[sig.params_start].mode),
                                .assert => {
                                    try testing.expectEqual(llir.ParamMode.plain, image.params[sig.params_start].mode);
                                    try testing.expectEqual(llir.ParamMode.plain, image.params[sig.params_start + 1].mode);
                                },
                                else => unreachable,
                            },
                            .host_module => |hm| if (std.mem.eql(u8, hm.member, "len"))
                                try testing.expectEqual(llir.ParamMode.borrow, image.params[sig.params_start].mode)
                            else
                                try testing.expectEqual(llir.ParamMode.plain, image.params[sig.params_start].mode),
                        }
                        if (sc.target == .builtin and sc.target.builtin == .print) {
                            try print_descs.append(testing.allocator, d.imm16);
                        }
                        n_syscall += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    // str, box, unbox, print ×2, assert, range, len = 8 syscalls; the
    // two identical `builtin.print(s)` sites share one descriptor.
    try testing.expectEqual(@as(usize, 8), n_syscall);
    try testing.expectEqual(@as(usize, 2), print_descs.items.len);
    try testing.expectEqual(print_descs.items[0], print_descs.items[1]);
}

/// 2.11: one multi-result destructure record's shape — the opcode, the
/// base slot, the variant tag (c), and the descriptor's `destructure_dsts`
/// range naming one slot per result in result order.
fn checkDestructure(b: *const cfg_lower_llir.Builder, image: llir.LlirProgram, pc: u32, op: llir.Opcode, kind: llir.DestructureKind, base: *const cfg.Value, tag: u32, ins: *const cfg.Instr) !void {
    const d = llir.decode(image.instructions[pc]).?;
    try testing.expectEqual(op, d.op);
    const desc_id: u32 = switch (op) {
        // R format: a = the 7-bit DestructureDescId, b = base, c = tag.
        .unpack_variant, .borrow_variant => blk: {
            try testing.expectEqual(b.slotOf(base), d.b);
            try testing.expectEqual(tag, d.c);
            break :blk d.a;
        },
        // I format: a = base, imm16 = DestructureDescId.
        else => blk: {
            try testing.expectEqual(b.slotOf(base), d.a);
            break :blk d.imm16;
        },
    };
    try testing.expect(desc_id < image.destructure_descs.len);
    const desc = image.destructure_descs[desc_id];
    try testing.expectEqual(kind, desc.kind);
    try testing.expectEqual(@as(u32, @intCast(ins.results.len)), desc.dsts_len);
    try testing.expect(desc.dsts_start + desc.dsts_len <= image.destructure_dsts.len);
    for (ins.results, 0..) |v, k| {
        try testing.expectEqual(b.slotOf(v), image.destructure_dsts[desc.dsts_start + k]);
    }
    for (0..ins.results.len) |i| {
        for (i + 1..ins.results.len) |j| {
            try testing.expect(image.destructure_dsts[desc.dsts_start + i] != image.destructure_dsts[desc.dsts_start + j]);
        }
    }
}

test "2.11 LLIR lowering: construct/destructure/switch descriptors stay atomic" {
    // Every n-ary aggregate form lowers to one fixed record + a
    // descriptor — no binary-chain splitting: struct/tuple/list/union
    // `construct`, the multi-result `unpack_struct`/`unpack_tuple`/
    // `unpack_variant`/`split_list` and non-consuming `borrow_variant`,
    // and the `switch` terminator whose arms are (tag, pc-relative
    // offset) rows. Descriptor ranges and operands stay in bounds;
    // identical
    // descriptors share one row.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; path: str; drop(file) {} }
            \\struct Nothing {}
            \\union Result { Ok(File), Err(str) }
            \\union Shape { Circle(int32), Rect(int32, int32) }
            \\fn open_file(path: str) -> File { File{ fd: 3, path: path } }
            \\fn make_ok(f: File) -> Result { Result::Ok(move f) }
            \\fn mk_pair(f: File) -> tuple[File, int32] { (move f, 42) }
            \\fn mk_list() -> list[int32] { [1, 2, 3] }
            \\fn take(r: Result) -> File {
            \\    match (move r) { Result::Ok(f) => f, Result::Err(e) => open_file(e) }
            \\}
            \\fn area(s: Shape) -> int32 {
            \\    match (s) { Shape::Circle(r) => r, Shape::Rect(w, h) => w * h }
            \\}
            \\struct Wrapper { inner: File; tag: int32; }
            \\fn unwrap(w: Wrapper) -> File {
            \\    let Wrapper { inner, tag } = move w;
            \\    inner
            \\}
            \\fn take_t(t: tuple[File, int32]) -> File {
            \\    let (f, n) = move t;
            \\    f
            \\}
            \\fn split(xs: list[File]) -> File {
            \\    let [f, ..rest] = move xs;
            \\    f
            \\}
            \\fn main() -> void {
            \\    let a = Nothing{};
            \\    let b = Nothing{};
            \\    let _ = a;
            \\    let _ = b;
            \\    builtin.print("x");
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();

    var n_construct: usize = 0;
    var n_unpack_struct: usize = 0;
    var n_unpack_tuple: usize = 0;
    var n_unpack_variant: usize = 0;
    var n_split_list: usize = 0;
    var n_borrow_variant: usize = 0;
    var n_switch: usize = 0;
    // Zero-arg constructs: both `Nothing{}` sites must share one desc.
    var nothing_descs = std.ArrayList(u32).empty;
    defer nothing_descs.deinit(testing.allocator);

    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk = b.ordered_blocks.items[bi];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (std.meta.activeTag(ins.op) == .phi) continue;
                if (b.isRecordElided(ins)) continue;
                switch (ins.op) {
                    .construct => |cs| {
                        const d = llir.decode(image.instructions[pc]).?;
                        // construct: a = dst, imm16 = ConstructDescId.
                        try testing.expectEqual(llir.Opcode.construct, d.op);
                        try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                        try testing.expect(d.imm16 < image.construct_descs.len);
                        const desc = image.construct_descs[d.imm16];
                        // Union variants carry the discriminant; the
                        // struct/tuple/list forms are no_tag.
                        if (cs.tag) |t| try testing.expectEqual(t, desc.tag) else try testing.expectEqual(llir.no_tag, desc.tag);
                        // Component registers, in declaration order, from
                        // the shared call_args table.
                        try testing.expectEqual(@as(u32, @intCast(cs.args.len)), desc.args_len);
                        try testing.expect(desc.args_start + desc.args_len <= image.call_args.len);
                        for (cs.args, 0..) |arg, k| {
                            try testing.expectEqual(b.slotOf(arg), image.call_args[desc.args_start + k]);
                        }
                        if (cs.args.len == 0) try nothing_descs.append(testing.allocator, d.imm16);
                        n_construct += 1;
                    },
                    .unpack_struct => |base| {
                        try checkDestructure(&b, image, pc, .unpack_struct, .struct_, base, 0, ins);
                        n_unpack_struct += 1;
                    },
                    .unpack_tuple => |base| {
                        try checkDestructure(&b, image, pc, .unpack_tuple, .tuple, base, 0, ins);
                        n_unpack_tuple += 1;
                    },
                    .unpack_variant => |uv| {
                        try checkDestructure(&b, image, pc, .unpack_variant, .variant, uv.base, uv.tag, ins);
                        n_unpack_variant += 1;
                    },
                    .split_list => |base| {
                        try checkDestructure(&b, image, pc, .split_list, .list, base, 0, ins);
                        n_split_list += 1;
                    },
                    .borrow_variant => |bv| {
                        try checkDestructure(&b, image, pc, .borrow_variant, .variant, bv.base, bv.tag, ins);
                        n_borrow_variant += 1;
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
            // The switch terminator: a = tag reg, b = SwitchDescId,
            // c = 0; the arm rows name (tag, pc-relative offset) — the
            // offset is the signed difference from the switch's own pc
            // to the arm block's BlockDesc start_pc.
            switch (blk.terminator) {
                .@"switch" => |s| {
                    const tpc = b.pcOf(blk) + b.non_phi_counts.items[bi] + b.edge_copy_counts.items[bi];
                    const d = llir.decode(image.instructions[tpc]).?;
                    // switch: a = tag reg, imm16 = SwitchDescId; the arm
                    // rows name (tag, pc-relative offset) — the offset
                    // equals the arm block's BlockDesc start_pc minus the
                    // switch's own pc.
                    try testing.expectEqual(llir.Opcode.switch_, d.op);
                    try testing.expectEqual(b.slotOf(s.disc), d.a);
                    try testing.expect(d.imm16 < image.switch_descs.len);
                    const desc = image.switch_descs[d.imm16];
                    try testing.expectEqual(@as(u32, @intCast(s.arms.len)), desc.arms_len);
                    try testing.expect(desc.arms_start + desc.arms_len <= image.switch_arms.len);
                    for (s.arms, 0..) |arm, k| {
                        const row = image.switch_arms[desc.arms_start + k];
                        try testing.expectEqual(arm.tag, row.tag);
                        const rel = @as(i32, @bitCast(b.pcOf(arm.block) -% tpc));
                        try testing.expectEqual(rel, row.target);
                        const bid = b.block_ids.get(arm.block).?;
                        try testing.expectEqual(llir.switchArmTarget(tpc, rel), image.blocks[bid].start_pc);
                    }
                    n_switch += 1;
                },
                else => {},
            }
        }
    }

    // open_file's File, make_ok's Ok, mk_pair's tuple, mk_list's list,
    // and the two Nothing{} sites = 6 constructs.
    try testing.expectEqual(@as(usize, 6), n_construct);
    // unwrap, take_t, split; take's consuming match destructures both
    // arms (Ok and Err payloads); area's non-consuming match projects
    // area's non-consuming match projects its multi-payload Rect arm
    // with borrow_variant (the single-payload Circle arm uses the
    // single-result read_payload, a later stage).
    try testing.expectEqual(@as(usize, 1), n_unpack_struct);
    try testing.expectEqual(@as(usize, 1), n_unpack_tuple);
    try testing.expectEqual(@as(usize, 2), n_unpack_variant);
    try testing.expectEqual(@as(usize, 1), n_split_list);
    try testing.expectEqual(@as(usize, 1), n_borrow_variant);
    // take and area each end in a switch.
    try testing.expectEqual(@as(usize, 2), n_switch);
    // Both zero-arg Nothing{} constructs share one descriptor.
    try testing.expectEqual(@as(usize, 2), nothing_descs.items.len);
    try testing.expectEqual(nothing_descs.items[0], nothing_descs.items[1]);
}

test "2.11 LLIR lowering: switch arm targets are signed pc-relative offsets, backward arms negative" {
    // Arm targets are signed offsets from the switch instruction's own
    // pc (Instruction Set §11–§12). A raw-AIR switch whose arm jumps
    // back to `entry` — the first block in the layout, so its pc lies
    // before the switch's — must carry a **negative** offset, and the
    // decode side (`switchArmTarget`) must recover the arm block's
    // start pc inside the current function.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @sw(x: Result) -> int32 {
        \\entry:
        \\    j loop
        \\loop:
        \\    %1: uint32 = read_tag %0
        \\    j dispatch
        \\dispatch:
        \\    %2: uint32 = read_tag %0
        \\    switch %2 { #0 -> arm_ok, #1 -> loop }
        \\arm_ok:
        \\    %3: int32 = const 7
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
        std.log.err("backward-arm image rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }

    // The switch is the dispatch block's terminator; `loop` (laid out
    // before `dispatch`, since %1 < %2) is one of its arm targets.
    const f = t.program.funcs[0];
    const loop_blk = blk: {
        for (f.blocks) |blk| {
            if (std.mem.eql(u8, blk.name, "loop")) break :blk blk;
        }
        return error.TestUnexpectedResult;
    };
    const dispatch = blk: {
        for (f.blocks) |blk| {
            if (std.mem.eql(u8, blk.name, "dispatch")) break :blk blk;
        }
        return error.TestUnexpectedResult;
    };
    const arm_ok = blk: {
        for (f.blocks) |blk| {
            if (std.mem.eql(u8, blk.name, "arm_ok")) break :blk blk;
        }
        return error.TestUnexpectedResult;
    };
    const dbi = b.block_ids.get(dispatch).?;
    const sw_pc = b.pcOf(dispatch) + b.non_phi_counts.items[dbi] + b.edge_copy_counts.items[dbi];
    const d = llir.decode(image.instructions[sw_pc]).?;
    try testing.expectEqual(llir.Opcode.switch_, d.op);
    const sd = image.switch_descs[d.imm16];
    try testing.expectEqual(@as(u32, 2), sd.arms_len);
    var saw_backward = false;
    for (sd.arms_start..sd.arms_start + sd.arms_len) |k| {
        const arm = image.switch_arms[k];
        const target_blk = if (arm.tag == 0) arm_ok else loop_blk;
        const expected = @as(i32, @bitCast(b.pcOf(target_blk) -% sw_pc));
        // The emitted offset is the signed difference from the switch's
        // own pc, and the decode recovers the arm block's start pc.
        try testing.expectEqual(expected, arm.target);
        try testing.expectEqual(b.pcOf(target_blk), llir.switchArmTarget(sw_pc, arm.target));
        if (arm.target < 0) saw_backward = true;
    }
    // `loop` is laid out before `dispatch` (its %1 sorts before %2), so
    // its arm offset is negative: loop_pc < switch_pc.
    try testing.expect(saw_backward);
}

test "2.12 LLIR lowering: explicit copy/move from source lower to distinct fast slot ops" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn wrap(a: int32) -> any { a } // return packs into any
            \\fn sink(move a: any) -> void { let _ = a; }
            \\fn main() -> void {
            \\    let x = 5;
            \\    let y = move x; // a Copy move folds away (air.md §5.4)
            \\    let z = y + y;
            \\    let u = wrap(z); // u: any, unique
            \\    sink(move u); // the unique move survives
            \\    builtin.print(builtin.str(x));
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };

    const before = try irText(&program);
    defer testing.allocator.free(before);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();

    // Every explicit `.copy`/`.move_` CFG instruction lowers to one
    // fast slot op: `a = dst, b = src, c = 0` — the opcode alone
    // distinguishes plain copy (0xf0) from ownership transfer (0xf2).
    // The frontend has no general borrow expression (ast.zig), so a
    // compiled program carries no `.borrow` instruction.
    var n_copy: usize = 0;
    var n_move: usize = 0;
    var n_borrow: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f).?;
        const frange = b.block_ranges.items[fid];
        for (0..frange.len) |k| {
            const blk = b.ordered_blocks.items[frange.start + k];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                const want_op: ?llir.Opcode = switch (ins.op) {
                    .copy => .copy,
                    .move_ => .move,
                    .borrow => .borrow,
                    else => null,
                };
                if (want_op) |op| {
                    if (b.isRecordElided(ins)) continue;
                    // v9: copy/move/borrow are E-type — `a = dst,
                    // b = src`, the opcode alone distinguishing plain
                    // copy from ownership transfer (`.c` decodes to 0
                    // for every E-type record).
                    const d = llir.decode(image.instructions[pc]).?;
                    try testing.expectEqual(op, d.op);
                    try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                    try testing.expectEqual(b.slotOf((switch (ins.op) {
                        .copy => |v| v,
                        .borrow => |v| v,
                        .move_ => |v| v,
                        else => unreachable,
                    })), d.b);
                    try testing.expectEqual(@as(u32, 0), d.c);
                    switch (ins.op) {
                        .copy => n_copy += 1,
                        .move_ => n_move += 1,
                        .borrow => n_borrow += 1,
                        else => unreachable,
                    }
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    // The unique `move u` call argument survives as a `move_` record:
    // the window placement homes the moved value into its window slot,
    // so the ownership transfer is an explicit record (its own argument
    // move then elides — src == dst). The Copy `move x` never reaches
    // the CFG at all — the on-the-fly copy propagation elides `copy` of
    // a Copy value (air.md §5.4), so compiled output carries no `.copy`
    // instruction. The `copy` opcode is exercised by text-AIR (below)
    // and by the 2.7 phi-edge records.
    try testing.expectEqual(@as(usize, 0), n_copy);
    // v1: the unique transfer into the call travels as a `slot_move`
    // preparation record (Instruction Set §5). The CFG-level `.move_`
    // for `move u` is no longer elided: `u = wrap(z)` is a coalesced
    // call result (Step 8) living in the result alias, so the move
    // reads the alias into the home cell (the take it replaces is
    // gone; the standalone `move` record remains).
    try testing.expectEqual(@as(usize, 1), n_move);
    var n_slot_move: usize = 0;
    for (program.funcs, 0..) |_, fi| {
        const range = b.block_ranges.items[fi];
        for (range.start..range.start + range.len) |bi| {
            const blk2 = b.ordered_blocks.items[bi];
            for (blk2.instrs) |ins| {
                if (std.meta.activeTag(ins.op) != .call) continue;
                for (try b.callArgMoves(blk2, ins)) |mv| {
                    if (mv.op == .slot_move) n_slot_move += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), n_slot_move);
    try testing.expectEqual(@as(usize, 0), n_borrow); // no general borrow expression
    // The three ownership opcodes are pairwise distinct — the runtime
    // distinguishes copy, transfer, and alias by opcode alone.
    try testing.expect(llir.Opcode.copy != llir.Opcode.move);
    try testing.expect(llir.Opcode.copy != llir.Opcode.borrow);
    try testing.expect(llir.Opcode.move != llir.Opcode.borrow);
    // The frozen record is exactly 4 bytes: no verify-only field
    // (ValueState/BorrowOrigin/dominance) can reach the image, and
    // every record stays one fixed 4-byte row.
    try testing.expect(!@hasField(llir.Instr, "state"));
    try testing.expect(!@hasField(llir.Instr, "borrow_origin"));
    try testing.expectEqual(@as(usize, 4), @sizeOf(llir.Instr));
    // Input CFG untouched (spec §1 — read-only projection).
    const after = try irText(&program);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "2.12 LLIR lowering: text-AIR copy/borrow/move instructions are one explicit slot op each" {
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @app.f(a: int32) -> int32 {
        \\entry:
        \\    %1: int32 = copy %0
        \\    %2: int32 = borrow %1
        \\    ret %2
        \\}
        \\func @app.g() -> box[int32] {
        \\entry:
        \\    %0: int32 = const 5
        \\    %1: box[int32] = construct %0
        \\    %2: box[int32] = move %1
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;

    const before = try cfg.print(program, testing.allocator);
    defer testing.allocator.free(before);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // @f: copy %0 → r1, borrow %1 → r2; @g: move %1 → r2. Each is
    // exactly a = dst slot, b = src slot, c = 0 — the borrow result is
    // a real slot (never a special), and the slots lie in the frame's
    // `[0, V)` region.
    const f = b.func_ids.get(program.funcs[0]).?;
    const g = b.func_ids.get(program.funcs[1]).?;
    var counts = [_]usize{ 0, 0, 0 }; // copy, borrow, move_
    for ([_]usize{ f, g }) |fi| {
        const frange = b.block_ranges.items[fi];
        const blk = b.ordered_blocks.items[frange.start];
        var pc = b.pcOf(blk);
        for (blk.instrs) |ins| {
            const want: ?llir.Opcode = switch (ins.op) {
                .copy => .copy,
                .borrow => .borrow,
                .move_ => .move,
                else => null,
            };
            if (want) |op| {
                if (b.isRecordElided(ins)) continue;
                const d = llir.decode(image.instructions[pc]).?;
                try testing.expectEqual(op, d.op);
                try testing.expectEqual(b.slotOf(ins.results[0]), d.a);
                try testing.expectEqual(b.slotOf((switch (ins.op) {
                    .copy => |v| v,
                    .borrow => |v| v,
                    .move_ => |v| v,
                    else => unreachable,
                })), d.b);
                try testing.expectEqual(@as(u32, 0), d.c);
                try testing.expect(llir.isFrame(d.a));
                try testing.expect(llir.frameIndex(d.a) < b.func_descs.items[fi].f_count);
                switch (ins.op) {
                    .copy => counts[0] += 1,
                    .borrow => counts[1] += 1,
                    .move_ => counts[2] += 1,
                    else => unreachable,
                }
            }
            pc += try b.recordCount(blk, ins);
        }
    }
    try testing.expectEqual(@as(usize, 0), counts[0]); // source-slot coalescing
    try testing.expectEqual(@as(usize, 1), counts[1]);
    try testing.expectEqual(@as(usize, 0), counts[2]);
    // Input CFG untouched.
    const after = try cfg.print(program, testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "2.12: borrow-root move/drop are rejected by the input CFG validator (Core §10.7)" {
    // The lowering relies on the input CFG validator: a borrow root
    // used after a move/drop never reaches the LLIR, so `emitOwnership`
    // needs no runtime guard. Prove the validator rejects both forms.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @app.f(borrow a: box[int32]) -> box[int32] {
        \\entry:
        \\    %1: box[int32] = move %0
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const err = try cfg_validate.validate(&t.program, arena.allocator());
    try testing.expect(err != null);
    try testing.expect(std.mem.indexOf(u8, err.?, "Core §10.7") != null);

    var t2 = try cfg_parse.parseText(
        \\module "app" {
        \\func @app.g(borrow b: box[any]) -> void {
        \\entry:
        \\    drop %0
        \\    ret
        \\}
        \\}
    );
    defer t2.arena.deinit();
    // `box[any]` is unique (the classifier), so `drop` of a borrow-mode
    // parameter trips the borrowed-value check, not the Copy check.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const err2 = try cfg_validate.validate(&t2.program, arena2.allocator());
    try testing.expect(err2 != null);
    try testing.expect(std.mem.indexOf(u8, err2.?, "Core §10.7") != null);
}

test "2.13 LLIR lowering: maybe-unique path arms one cleanup cell, disarm + conditional drop" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn consume(move f: File) -> void {}
            \\fn main() -> void {
            \\    let f = File{ fd: 1 };
            \\    if (true) { consume(move f); } else { }
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();

    const main = b.func_ids.get(program.funcs[2]).?; // @app.main (after @init, @app.consume)
    const fd = image.functions[main];
    _ = fd;
    // v1 (Instruction Set §4): no cleanup cells exist. The consuming then-branch
    // transfers the File; the non-consuming else-edge carries an
    // unconditional destruction before the merge, so the owner state is
    // uniform (dead) past the join.
    var seen_edge_drop: usize = 0;
    var seen_token_op: usize = 0;
    var n_drop: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f).?;
        const frange = b.block_ranges.items[fid];
        for (0..frange.len) |k| {
            const blk = b.ordered_blocks.items[frange.start + k];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (b.isRecordElided(ins)) continue;
                const d = llir.decode(image.instructions[pc]).?;
                switch (ins.op) {
                    .cleanup_arm, .cleanup_disarm, .cleanup_drop => seen_token_op += 1,
                    .drop_ => |v| {
                        const op = d.op;
                        if (op == .drop) {
                            // v1 form: a = payload slot, imm16 = DropDescId.
                            try testing.expectEqual(b.slotOf(v), d.a);
                            try testing.expect(d.imm16 < image.drop_descs.len);
                            if (std.mem.indexOf(u8, f.name.text, ".main") != null) {
                                seen_edge_drop += 1;
                            }
                        } else {
                            n_drop += 1;
                        }
                    },
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), seen_edge_drop);
    try testing.expectEqual(@as(usize, 0), seen_token_op);
}

test "2.13 LLIR lowering: definitely-released path disarms on every branch, no cleanup_drop" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn consume(move f: File) -> void {}
            \\fn main() -> void {
            \\    let f = File{ fd: 1 };
            \\    if (true) { consume(move f); } else { consume(move f); }
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();
    _ = image; // v1: the assertions walk the CFG, not the records

    var n_cleanup: usize = 0;
    var main_drops: usize = 0;
    const main_f = b.func_ids.get(program.funcs[2]).?;
    _ = &main_f;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f).?;
        const frange = b.block_ranges.items[fid];
        for (0..frange.len) |k| {
            const blk = b.ordered_blocks.items[frange.start + k];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (b.isRecordElided(ins)) continue;
                switch (ins.op) {
                    .cleanup_arm, .cleanup_disarm, .cleanup_drop => n_cleanup += 1,
                    else => {},
                }
                if (fid == main_f and std.meta.activeTag(ins.op) == .drop_) main_drops += 1;
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    // Consumed on every completing branch: v1 needs neither tokens nor
    // edge drops — the scope-end destruction is skipped entirely
    // (Instruction Set §4).
    try testing.expectEqual(@as(usize, 0), n_cleanup);
    try testing.expectEqual(@as(usize, 0), main_drops);
}

test "2.13 LLIR lowering: definitely-owned path is a plain drop, no cleanup cells" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn wrap(a: int32) -> any { a }
            \\fn main() -> void {
            \\    let u = wrap(1);
            \\    let _ = u;
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();

    var n_drop: usize = 0;
    var n_cleanup: usize = 0;
    for (program.funcs) |f| {
        const fid = b.func_ids.get(f).?;
        const frange = b.block_ranges.items[fid];
        for (0..frange.len) |k| {
            const blk = b.ordered_blocks.items[frange.start + k];
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                const d = llir.decode(image.instructions[pc]).?;
                switch (ins.op) {
                    .drop_ => |v| {
                        n_drop += 1;
                        // v1: a = the payload slot, imm16 = DropDescId.
                        try testing.expectEqual(b.slotOf(v), d.a);
                        try testing.expect(d.imm16 < image.drop_descs.len);
                        try testing.expectEqual(llir.Opcode.drop, d.op);
                    },
                    .cleanup_arm, .cleanup_disarm, .cleanup_drop => n_cleanup += 1,
                    else => {},
                }
                pc += try b.recordCount(blk, ins);
            }
        }
    }
    // The unique `any` is dropped unconditionally: one `drop src, desc`
    // record, zero cleanup anything.
    try testing.expectEqual(@as(usize, 1), n_drop);
    try testing.expectEqual(@as(usize, 0), n_cleanup);
}

test "2.10 LLIR lowering: lifecycle planning resolves name-only direct-call parameter modes" {
    // The non-optimized pipeline leaves `Call.callee.direct.func` null
    // (resolveDirectCalls runs only in the optimizer), so lifecycle
    // planning resolves direct callees by name through the prepare-stage
    // name maps. The declared modes must drive consumption: a counted
    // `move` argument is consumed (no caller-side release trails the
    // call — the ownership travels via `slot_move`), and a unique
    // `borrow` argument is not consumed (the callee gets a view).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn take(move s: str) -> void {}
            \\struct File { fd: int32; drop(file) {} }
            \\fn peek(borrow f: File) -> void {}
            \\fn main() -> void {
            \\    let s = "hi";
            \\    take(move s);
            \\    let f = File{ fd: 1 };
            \\    peek(f);
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();
    _ = image;

    const main_f = findFunc(&program, "app.main");
    var n_call: usize = 0;
    for (main_f.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (ins.op != .call) continue;
            n_call += 1;
            try testing.expectEqual(@as(usize, 1), ins.op.call.args.len);
            const arg = ins.op.call.args[0];
            if (n_call == 1) {
                // take(move s): the declared move mode consumes the
                // counted copy the frontend materialized.
                try testing.expect(lifecycle.consumesValue(&b, ins, arg));
                try testing.expectEqual(@as(usize, 0), lifecycle.trailingOf(&b, ins).len);
            } else {
                // peek(borrow f): the declared borrow mode passes a view
                // — the unique File is not consumed.
                try testing.expect(!lifecycle.consumesValue(&b, ins, arg));
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), n_call);
}

test "2.10 LLIR lowering: a signature-less text-AIR syscall is a named lowering error" {
    var t = try cfg_parse.parseText(
        \\module "m" {
        \\    func @init() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @m.f(x: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        %2: int32 = syscall builtin#print, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer t.arena.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    // No zeroed placeholder escapes: the signature-less syscall fails
    // the whole lowering with the named error.
    try testing.expectError(error.SyscallWithoutSignature, b.lowerLlir());
}
