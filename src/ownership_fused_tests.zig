//! Test file: the ownership fused oracle (PLAN item 5) — one corpus
//! program per ownership behavior, each asserted at all four layers:
//!
//!   (a) the checker's final `BindingState`s (phase 2);
//!   (b) `cfg_validate`'s ownership dataflow verdict on the lowered
//!       program (Available / Consumed / MaybeConsumed — boundary A:
//!       the checker's `maybe` and the CFG's `MaybeConsumed` merge rule
//!       must agree, so every checker-accepted program must validate);
//!   (c) the LLIR image's exact release/drop records per function
//!       (the frontend_llir_* infrastructure, asserted here directly);
//!   (d) the interpreter's observed destruction order/count (host print
//!       hooks, interpreter_lifecycle_tests style).
//!
//! The corpus covers: copy, borrow, move, conditional release (the
//! checker's `maybe` resolved into unconditional drops on non-consuming
//! branch edges — v1 has no cleanup cells, Instruction Set §4), explicit
//! drops, counted edge kills, tailcall leftover kills, and self-loop
//! back edges. Any future change to checker_ownership, cfg_lower_drop,
//! cfg_lower_lifecycle, cfg_validate, or the interpreter's destroy
//! walker that breaks the agreement fails this suite.
//!
//! Boundary B (CFG ↔ LLIR): the LLIR is validated structurally
//! (`llir_validate`), and `cfg_validate` re-checks the built program;
//! the release-exactly-once invariant is guaranteed by construction —
//! the lifecycle planner (cfg_lower_lifecycle.plan) places every
//! counted owner's release exactly once per path and the frontend
//! resolves conditional unique destruction before LLIR — and is
//! observed at runtime by (d) for every corpus case (a counted value
//! released twice or never traps or leaks, which the heap-registry
//! assertions catch).
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interpreter = @import("interpreter.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg = @import("cfg.zig");
const lower = @import("lower.zig");
const checker = @import("passes/checker.zig");
const cfg_validate = @import("passes/cfg_validate.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");

const testing = std.testing;
const Value = vm_types.Value;

/// Compile one corpus program and hold every layer the oracle asserts:
/// the compilation (program + graph), a re-run checker's annotation,
/// the validated LLIR image, and the per-function lookup tables.
const Fused = struct {
    arena: std.heap.ArenaAllocator,
    compilation: frontend.Compilation,
    ann: checker.Annotation,
    /// The "app" module's annotation (view a).
    mod_ann: *checker.ModuleAnnotation,
    /// The program `cfg_validate` ran on (view b), post-optimization
    /// when `optimize` was set.
    program: *cfg.IrProgram,
    /// The validated LLIR image (view c) and its builder.
    image: llir.LlirProgram,
    bld: cfg_lower_llir.Builder,
    /// Ordered FunctionId by trailing source name.
    fids: std.StringArrayHashMapUnmanaged(llir.FunctionId) = .empty,

    fn init(allocator: std.mem.Allocator, src: []const u8, optimize: bool) !Fused {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var sources = moduleinfo.Sources{};
        var smap = std.StringHashMapUnmanaged([]const u8).empty;
        try smap.put(arena.allocator(), "app", src);
        sources.source = smap;
        var compilation = try frontend.compile(allocator, .{
            .entry = "app",
            .sources = sources,
            .entry_fn = "main",
            .optimize = optimize,
        });
        errdefer compilation.deinit();
        const program = &(compilation.program orelse {
            if (compilation.diag) |d| std.log.err("FUSED COMPILE DIAG: {s}", .{d.message});
            return error.TestUnexpectedResult;
        });
        const graph = compilation.graph.?;

        // Re-run phase 2 for the annotation (the compilation's own
        // checker is internal): the side tables are per-module and the
        // graph is phase-1 data, so this is deterministic and
        // idempotent. The annotation lives in a child arena of `arena`
        // and is freed with it (the checkText pattern) — never deinit
        // it separately.
        var ck = checker.Checker.init(arena.allocator());
        var ann = try ck.check(graph);
        const mod_ann = ann.per_module.get("app") orelse return error.TestUnexpectedResult;

        // View (b): the ownership dataflow verdict on the final program.
        // The message is arena-owned (the validator allocated it from
        // `arena.allocator()`) — the arena frees it.
        if (try cfg_validate.validate(program, arena.allocator())) |m| {
            std.log.err("FUSED CFG VALIDATION: {s}", .{m});
            return error.TestUnexpectedResult;
        }

        // View (c): the LLIR image, structurally validated.
        var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
        const image = try b.lowerLlir();
        if (try llir_validate.validate(&image, allocator)) |m| {
            defer allocator.free(m);
            std.log.err("FUSED LLIR REJECT: {s}", .{m});
            return error.TestUnexpectedResult;
        }

        var fids = std.StringArrayHashMapUnmanaged(llir.FunctionId).empty;
        errdefer fids.deinit(allocator);
        var it = b.func_ids.iterator();
        while (it.next()) |kv| {
            const full = kv.key_ptr.*.name.text;
            const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse 0;
            const short = if (dot < full.len - 1) full[dot + 1 ..] else full;
            try fids.put(allocator, short, kv.value_ptr.*);
        }
        return .{
            .arena = arena,
            .compilation = compilation,
            .ann = ann,
            .mod_ann = mod_ann,
            .program = program,
            .image = image,
            .bld = b,
            .fids = fids,
        };
    }

    fn deinit(self: *Fused) void {
        self.fids.deinit(testing.allocator);
        self.compilation.deinit();
        self.arena.deinit();
    }

    fn fid(self: *const Fused, name: []const u8) !llir.FunctionId {
        return self.fids.get(name) orelse error.TestUnexpectedResult;
    }

    // --- view (a): checker binding states --------------------------------

    /// Count the module's bindings whose final state is `want` — the
    /// checker-test convention (`countBindingsWithState`); each corpus
    /// case keeps the interesting state unique so a count of 1 pins the
    /// exact binding.
    fn countBindingsWithState(self: *const Fused, want: checker.BindingState) usize {
        var count: usize = 0;
        var it = self.mod_ann.bindings.valueIterator();
        while (it.next()) |state| {
            if (state.* == want) count += 1;
        }
        return count;
    }

    // --- view (c): LLIR record scanning ----------------------------------

    /// One function's destroy-relevant record counts over the decoded
    /// LLIR instruction stream (instructions plus terminator).
    const FuncScan = struct {
        drops: usize = 0,
        releases: usize = 0,
        tailcall: usize = 0,
        /// The record offset of the terminator (`pcOf(blk) + non_phi +
        /// edge_copy`), when the terminator is a tailcall.
        tailcall_at: ?u32 = null,

        fn count(self: *FuncScan, op: llir.Opcode) void {
            switch (op) {
                .drop => self.drops += 1,
                .release => self.releases += 1,
                .tailcall_self => self.tailcall += 1,
                else => {},
            }
        }
    };

    fn scanFunc(self: *Fused, f: llir.FunctionId) !FuncScan {
        const b = &self.bld;
        const frange = b.block_ranges.items[f];
        var s = FuncScan{};
        for (0..frange.len) |k| {
            const blk = b.ordered_blocks.items[frange.start + k];
            const bi = b.block_ids.get(blk).?;
            var pc = b.pcOf(blk);
            // Instruction records at the head of the block's stream.
            for (blk.instrs) |ins| {
                if (b.isRecordElided(ins)) continue;
                const d = llir.decode(self.image.instructions[pc]).?;
                s.count(d.op);
                pc += try b.recordCount(blk, ins);
            }
            // The edge-effect section (phi copies + lifecycle kills +
            // tailcall slot prep and leftover kills) sits between the
            // instructions and the terminator.
            const edge_start = b.pcOf(blk) + b.non_phi_counts.items[bi];
            const edge_end = edge_start + b.edge_copy_counts.items[bi];
            var ep = edge_start;
            while (ep < edge_end) : (ep += 1) {
                const d = llir.decode(self.image.instructions[ep]).?;
                s.count(d.op);
            }
            // The terminator is the block's last record.
            const t = llir.decode(self.image.instructions[edge_end]).?;
            if (t.op == .tailcall_self) {
                s.tailcall += 1;
                s.tailcall_at = edge_end;
            }
        }
        return s;
    }

    /// The decoded instructions of one function, for exact-record
    /// assertions (the records after the tailcall's slot prep are its
    /// leftover-owner kills).
    fn funcRecords(self: *Fused, f: llir.FunctionId) !std.ArrayList(llir.Decoded) {
        var out = std.ArrayList(llir.Decoded).empty;
        const b = &self.bld;
        const frange = b.block_ranges.items[f];
        for (0..frange.len) |k| {
            const blk = b.ordered_blocks.items[frange.start + k];
            const bi = b.block_ids.get(blk).?;
            var pc = b.pcOf(blk);
            for (blk.instrs) |ins| {
                if (b.isRecordElided(ins)) continue;
                try out.append(testing.allocator, llir.decode(self.image.instructions[pc]).?);
                pc += try b.recordCount(blk, ins);
            }
            const edge_start = b.pcOf(blk) + b.non_phi_counts.items[bi];
            const edge_end = edge_start + b.edge_copy_counts.items[bi];
            var ep = edge_start;
            while (ep < edge_end) : (ep += 1) {
                try out.append(testing.allocator, llir.decode(self.image.instructions[ep]).?);
            }
            try out.append(testing.allocator, llir.decode(self.image.instructions[edge_end]).?);
        }
        return out;
    }

    // --- view (d): runtime -----------------------------------------------

    /// Run `main` with the given host adapter, returning the normal
    /// result value.
    fn run(self: *Fused, host: interpreter.HostCall) !Value {
        var term = try interpreter.runWithEntry(testing.allocator, &self.image, try self.fid("main"), host);
        defer term.deinit(testing.allocator);
        switch (term) {
            .normal => |v| return v,
            .panic => |m| {
                std.log.err("FUSED PANIC: {s}", .{m});
                return error.TestUnexpectedResult;
            },
        }
    }

    /// Run `main` and assert the heap registry (live counted objects)
    /// is empty afterwards — a release/drop that runs twice or never
    /// leaks or double-frees and fails this check. The default host
    /// writes `builtin.print` to real stdout (host.zig), which corrupts
    /// the test-runner's `--listen` protocol pipe, so a capturing host
    /// adapter must be used whenever a corpus program prints.
    fn runExpectClean(self: *Fused) !Value {
        return self.runExpectCleanHost(.{});
    }

    fn runExpectCleanHost(self: *Fused, host: interpreter.HostCall) !Value {
        var vm = interpreter.VmCtx{ .allocator = testing.allocator, .host = host, .runtime = .{ .heap = .{ .allocator = testing.allocator } } };
        defer vm.deinit();
        try vm.setupRootArtifact(&self.image, try self.fid("main"));
        var result: ?Value = null;
        while (!vm.runtime.terminated) {
            if (try interpreter_dispatch_step(&vm)) |t| {
                switch (t) {
                    .normal => |v| result = v,
                    .panic => return error.TestUnexpectedResult,
                }
                break;
            }
            try vm.drainDestroyWork();
        }
        vm.finishCleanup();
        try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count());
        return result orelse error.TestUnexpectedResult;
    }
};

const vm_dispatch = @import("interpreter_dispatch.zig");
fn interpreter_dispatch_step(vm: *interpreter.VmCtx) !?interpreter.Termination {
    return vm_dispatch.step(vm);
}

// ---------------------------------------------------------------------------
// The corpus — one test per ownership behavior, all four views asserted.
// ---------------------------------------------------------------------------

/// A host adapter that records every `builtin.print` string in order
/// (the drop hooks print their payload id), delegating everything else
/// to the default host.
const PrintRecorder = struct {
    buffer: [4096]u8 = undefined,
    len: usize = 0,

    fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: interpreter.HostSignature, args: []const vm_types.Value) interpreter.HostResult {
        if (std.mem.eql(u8, member, "print") and args.len > 0) {
            const r: *PrintRecorder = @ptrCast(@alignCast(@constCast(userdata.?)));
            const bytes = vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "print: not a str" };
            if (r.len + bytes.len > r.buffer.len) return .{ .panic = "capture overflow" };
            @memcpy(r.buffer[r.len..][0..bytes.len], bytes);
            r.len += bytes.len;
            return .{ .value = 0 };
        }
        return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
    }
};

test "fused oracle: copy — no destruction records, nothing tracked" {
    var t = try Fused.init(testing.allocator,
        \\struct C { x: int32; }
        \\fn main() -> int32 {
        \\    let a = C{ x: 1 };
        \\    let b = a;
        \\    let c = a;
        \\    b.x + c.x
        \\}
    , false);
    defer t.deinit();
    // (a) copies are never consumed.
    try testing.expectEqual(@as(usize, 0), t.countBindingsWithState(.consumed));
    // (b) the lowered program satisfies the ownership dataflow.
    // (accepted in Fused.init)
    // (c) no destroy records anywhere in main.
    const s = try t.scanFunc(try t.fid("main"));
    try testing.expectEqual(@as(usize, 0), s.drops);
    try testing.expectEqual(@as(usize, 0), s.releases);
    // (d) nothing counted at runtime.
    _ = try t.runExpectClean();
}

test "fused oracle: borrow — the view is never destroyed by the callee" {
    var t = try Fused.init(testing.allocator,
        \\const builtin = import("builtin");
        \\struct B { fd: int32; drop(b) { builtin.print(builtin.str(b.fd)); } }
        \\fn peek(borrow b: B) -> int32 { b.fd }
        \\fn main() -> int32 {
        \\    let b = B{ fd: 7 };
        \\    let g = peek(b);
        \\    g
        \\}
    , false);
    defer t.deinit();
    // (a) the borrow parameter is a non-owning binding (the count is
    // two: the parameter and the drop hook's own borrowed view).
    try testing.expect(t.countBindingsWithState(.borrowed) >= 1);
    // (c) the callee emits no destruction of the view; main destroys its
    // owner exactly once at scope end.
    const peek_scan = try t.scanFunc(try t.fid("peek"));
    try testing.expectEqual(@as(usize, 0), peek_scan.drops);
    try testing.expectEqual(@as(usize, 0), peek_scan.releases);
    const main_scan = try t.scanFunc(try t.fid("main"));
    try testing.expectEqual(@as(usize, 1), main_scan.drops);
    // (d) the owner's drop hook runs exactly once (at main's scope end)
    // and prints the payload.
    var rec = PrintRecorder{};
    _ = try t.run(.{ .userdata = &rec, .invoke = PrintRecorder.invoke });
    try testing.expectEqual(@as(usize, 1), rec.len);
    try testing.expectEqualStrings("7", rec.buffer[0..rec.len]);
}

test "fused oracle: move — ownership transfers, the callee destroys" {
    var t = try Fused.init(testing.allocator,
        \\const builtin = import("builtin");
        \\struct M { fd: int32; drop(m) { builtin.print(builtin.str(m.fd)); } }
        \\fn consume(move m: M) -> void {}
        \\fn main() -> void {
        \\    let m = M{ fd: 1 };
        \\    consume(move m);
        \\}
    , false);
    defer t.deinit();
    // (a) the moved binding is consumed.
    try testing.expectEqual(@as(usize, 1), t.countBindingsWithState(.consumed));
    // (c) the caller emits no destruction after the transfer; the
    // callee destroys its move parameter at scope end.
    const main_scan = try t.scanFunc(try t.fid("main"));
    try testing.expectEqual(@as(usize, 0), main_scan.drops);
    const consume_scan = try t.scanFunc(try t.fid("consume"));
    try testing.expectEqual(@as(usize, 1), consume_scan.drops);
    // (d) the hook runs exactly once, in the callee.
    var rec = PrintRecorder{};
    _ = try t.run(.{ .userdata = &rec, .invoke = PrintRecorder.invoke });
    try testing.expectEqual(@as(usize, 1), rec.len);
}

test "fused oracle: conditional release — checker maybe, edge drop, once both ways" {
    // The checker's `maybe` (released on some but not all paths) is
    // resolved by the lowerer into an unconditional destruction on the
    // non-consuming branch edge — boundary A: the checker's merge rule
    // and the CFG's MaybeConsumed verdict agree (the program validates).
    var t = try Fused.init(testing.allocator,
        \\const builtin = import("builtin");
        \\struct F { fd: int32; drop(f) { builtin.print(builtin.str(f.fd)); } }
        \\fn consume(move f: F) -> void {}
        \\fn f(c: bool) -> void {
        \\    let f = F{ fd: 1 };
        \\    if (c) { consume(move f); } else {}
        \\}
        \\fn main() -> void { f(true) }
    , false);
    defer t.deinit();
    // (a) the conditional owner is maybe.
    try testing.expectEqual(@as(usize, 1), t.countBindingsWithState(.maybe));
    // (c) exactly one destruction of the owner in `f` (the edge drop on
    // the non-consuming path).
    const f_scan = try t.scanFunc(try t.fid("f"));
    try testing.expectEqual(@as(usize, 1), f_scan.drops);
    // (d) the hook runs exactly once on each path.
    {
        var rec = PrintRecorder{};
        _ = try t.run(.{ .userdata = &rec, .invoke = PrintRecorder.invoke });
        try testing.expectEqual(@as(usize, 1), rec.len);
    }
    {
        var t2 = try Fused.init(testing.allocator,
            \\const builtin = import("builtin");
            \\struct F { fd: int32; drop(f) { builtin.print(builtin.str(f.fd)); } }
            \\fn consume(move f: F) -> void {}
            \\fn f(c: bool) -> void {
            \\    let f = F{ fd: 1 };
            \\    if (c) { consume(move f); } else {}
            \\}
            \\fn main() -> void { f(false) }
        , false);
        defer t2.deinit();
        var rec = PrintRecorder{};
        _ = try t2.run(.{ .userdata = &rec, .invoke = PrintRecorder.invoke });
        try testing.expectEqual(@as(usize, 1), rec.len);
    }
}

test "fused oracle: explicit drop — placement before scope end, in order" {
    // Two owners; the first is dropped explicitly, the second dies at
    // scope end. The observed destruction order pins the drop placement.
    var t = try Fused.init(testing.allocator,
        \\const builtin = import("builtin");
        \\struct D { fd: int32; drop(d) { builtin.print(builtin.str(d.fd)); } }
        \\fn main() -> void {
        \\    let d1 = D{ fd: 1 };
        \\    let d2 = D{ fd: 2 };
        \\    drop d1;
        \\}
    , false);
    defer t.deinit();
    // (a) the explicitly dropped binding is consumed.
    try testing.expectEqual(@as(usize, 1), t.countBindingsWithState(.consumed));
    // (c) exactly two destructions in main (the explicit drop and the
    // scope-end drop).
    const main_scan = try t.scanFunc(try t.fid("main"));
    try testing.expectEqual(@as(usize, 2), main_scan.drops);
    // (d) d1's hook runs before d2's.
    var rec = PrintRecorder{};
    _ = try t.run(.{ .userdata = &rec, .invoke = PrintRecorder.invoke });
    try testing.expectEqualStrings("12", rec.buffer[0..rec.len]);
}

test "fused oracle: edge kill — a counted value read on one branch releases on its edge" {
    // `s` (a counted `str`) is read only on the then path; on the else
    // path it dies at the merge, so the release rides the else edge.
    // (d) runs both paths and asserts no leak (release exactly once).
    var t = try Fused.init(testing.allocator,
        \\const builtin = import("builtin");
        \\fn pick(b: bool) -> int32 {
        \\    let s = builtin.str(42);
        \\    if (b) { builtin.print(s); 1 } else { 100 }
        \\}
        \\fn main() -> int32 { pick(false) }
    , true);
    defer t.deinit();
    // (c) the counted owner releases exactly once in `pick` (either
    // trailing in the then block or on the else edge — the count is
    // one, and it never reads a released cell because the image
    // validated and (d) runs clean).
    const pick_scan = try t.scanFunc(try t.fid("pick"));
    try testing.expectEqual(@as(usize, 1), pick_scan.releases);
    // (d) both paths: no leak, correct result, and the print is captured
    // (never written to real stdout — that would corrupt the test
    // runner's `--listen` protocol pipe).
    {
        var rec = PrintRecorder{};
        try testing.expectEqual(@as(Value, 100), try t.runExpectCleanHost(.{ .userdata = &rec, .invoke = PrintRecorder.invoke }));
    }
    var t2 = try Fused.init(testing.allocator,
        \\const builtin = import("builtin");
        \\fn pick(b: bool) -> int32 {
        \\    let s = builtin.str(42);
        \\    if (b) { builtin.print(s); 1 } else { 100 }
        \\}
        \\fn main() -> int32 { pick(true) }
    , true);
    defer t2.deinit();
    {
        var rec = PrintRecorder{};
        try testing.expectEqual(@as(Value, 1), try t2.runExpectCleanHost(.{ .userdata = &rec, .invoke = PrintRecorder.invoke }));
        try testing.expectEqualStrings("42", rec.buffer[0..rec.len]);
    }
}

test "fused oracle: tailcall leftover kills — owners live at the terminator release after the slot prep" {
    // A move-mode unique accumulator forces the frame-reusing tailcall
    // terminator. The matched `xs` dies mid-block (trailing release),
    // but the pass-through `ys` is an owner still alive at the
    // terminator — its reference must be released after the `slot_*`
    // preparation, the leftover kill (Instruction Set §5.5), and `xs`
    // must not be released twice.
    var t = try Fused.init(testing.allocator,
        \\struct R { v: int32; drop(r) {} }
        \\fn fold(xs: list[int32], ys: list[int32], move acc: R) -> R {
        \\    match (xs) {
        \\        [] => acc,
        \\        [h, ..t] => fold(t, ys, move acc),
        \\    }
        \\}
        \\fn main() -> int32 {
        \\    let r = fold([1, 2, 3], [9], R{ v: 0 });
        \\    r.v
        \\}
    , true);
    defer t.deinit();
    // (c) the fold's tailcall block emits a leftover `release` after its
    // `slot_*` preparation and before the `tailcall_self` terminator.
    const fold_scan = try t.scanFunc(try t.fid("fold"));
    try testing.expectEqual(@as(usize, 1), fold_scan.tailcall);
    var records = try t.funcRecords(try t.fid("fold"));
    defer records.deinit(testing.allocator);
    // funcRecords is compressed (elided records skipped), so find the
    // tailcall there and check the record immediately before it
    // releases (the leftover kill of the still-alive `ys`).
    var ti: usize = records.items.len;
    for (records.items, 0..) |rec, i| {
        if (rec.op == .tailcall_self) {
            ti = i;
            break;
        }
    }
    try testing.expect(ti > 0);
    try testing.expectEqual(llir.Opcode.release, records.items[ti - 1].op);
    // (d) the loop runs clean: every iteration's references are
    // released, the result is the folded value.
    try testing.expectEqual(@as(Value, 0), try t.runExpectClean());
}

test "fused oracle: self-loop back edge — recursion becomes a loop that still destroys exactly once" {
    // A tail-recursive list sum with a counted carrier: the optimizer
    // rewrites the self-call into a loop whose back edge flows the tail
    // around, and the counted values release exactly once per path.
    var t = try Fused.init(testing.allocator,
        \\fn sum(xs: list[int32], acc: int32) -> int32 {
        \\    match (xs) {
        \\        [] => acc,
        \\        [h, ..t] => sum(t, acc + h),
        \\    }
        \\}
        \\fn main() -> int32 { sum([1, 2, 3], 0) }
    , true);
    defer t.deinit();
    // (c) the optimized loop carries the count down the back edge.
    const sum_scan = try t.scanFunc(try t.fid("sum"));
    try testing.expect(sum_scan.releases >= 1);
    // (d) no leak, correct result.
    try testing.expectEqual(@as(Value, 6), try t.runExpectClean());
}
