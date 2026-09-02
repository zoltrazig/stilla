//! Black-box object-lifecycle interpreter tests: heap pointers/provenance, string
//! equality/hash, list/box/union construction and consuming destructure, counted
//! release/copy_retain, drop hooks and module teardown, and the path-specific edge
//! effects (stage 7.1/7.2) and the host-resource registry.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interpreter = @import("interpreter.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const lower = @import("lower.zig");
const checker = @import("passes/checker.zig");
const stdbundle = @import("stdbundle.zig");
const host_module = @import("host.zig");
const artifact_bundle = @import("artifact_bundle.zig");
const llir_emit_bin = @import("passes/llir_emit_bin.zig");
const stilla_asm_printer = lower.llirAsm;
const testing = std.testing;

const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;

const support = @import("interpreter_test_support.zig");
const load = support.load;
const Loaded = support.Loaded;
const CaptureAdapter = support.CaptureAdapter;
const runHand = support.runHand;
const runHandBlocks = support.runHandBlocks;
const runHandImage = support.runHandImage;
const primType = support.primType;

// ---------------------------------------------------------------------------
// Phase 3 — full pointers, object provenance, lifecycle (TODO.md 阶段 3)
// ---------------------------------------------------------------------------

test "empty list: the all-zero cell is the only legal null" {
    var l = try load(
        \\fn nil() -> list[int32] { [] }
        \\fn main() -> list[int32] { nil() }
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        // The canonical empty list IS the all-zero cell.
        .normal => |v| try testing.expectEqual(@as(Value, 0), v),
        .panic => return error.TestUnexpectedResult,
    }
}

test "string equality and hash use UTF-8 contents, not object identity" {
    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> int32 {
        \\    let literal = "hello";
        \\    let joined = "hel" + "lo";
        \\    let empty = "" + "";
        \\    if (literal == joined and literal != "world" and empty == "" and builtin.hash(literal) == builtin.hash(joined)) { 1 } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    try testing.expectEqual(@as(Value, 1), term.normal);
}

test "run initializes the entry module before its function" {
    var l = try load(
        \\const answer = 40 + 2;
        \\fn main() -> int32 { answer }
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    try testing.expectEqual(@as(Value, 42), term.normal);
}

test "list lifecycle: construct, consume, and clean up to zero objects" {
    var l = try load(
        \\fn sum3(move xs: list[int32]) -> int32 {
        \\    let [a, b, c] = move xs;
        \\    a + b + c
        \\}
        \\fn main() -> int32 { sum3([1, 2, 3]) }
    , true);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| {
            std.log.info("SUM3 GOT: {d}", .{v});
            try testing.expectEqual(@as(Value, 6), v);
        },
        .panic => |m| {
            std.log.err("LIFECYCLE PANIC: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "normal termination cleans every object and string constant" {
    var l = try load(
        \\fn greet() -> str {
        \\    let greeting = "hello";
        \\    greeting
        \\}
        \\fn main() -> int32 {
        \\    let xs = [10, 20];
        \\    let [a, ..rest] = move xs;
        \\    a
        \\}
    , true);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |_| break;
        try vm.drainDestroyWork();
    }
    vm.finishCleanup();
    try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count());
}

test "trap path also cleans every object" {
    var l = try load(
        \\fn boom(move xs: list[int32]) -> int32 {
        \\    let [h, ..t] = move xs;
        \\    h / 0
        \\}
        \\fn main() -> int32 { boom([1, 2]) }
    , true);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => {}, // trapped mid-frame with a live list still owned
    }
}

test "module teardown runs a slot drop hook exactly once with no trap" {
    // A module-level `const` of a struct with a user drop hook: the
    // slot is destroyed during reverse-order module teardown, after the
    // root frame has returned. `startHookCall` must place the hook
    // frame above the root frame's sp (not below it, where the header
    // write would corrupt the root frame or underflow when the root
    // frame is small). The hook receives the doomed object's address as
    // its parameter and runs exactly once; termination stays normal.
    const Count = struct { hooks: usize = 0, main_ran: bool = false, saw_id: bool = false };
    var state = Count{};
    const Adapter = struct {
        fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: interpreter.HostSignature, args: []const vm_types.Value) interpreter.HostResult {
            if (std.mem.eql(u8, member, "print")) {
                const c: *Count = @ptrCast(@alignCast(@constCast(userdata.?)));
                const bytes = vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "print: not a str" };
                if (std.mem.eql(u8, bytes, "42")) {
                    c.hooks += 1;
                    c.saw_id = true;
                }
                if (std.mem.eql(u8, bytes, "MAIN")) c.main_ran = true;
                return .{ .value = 0 };
            }
            return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
        }
    };
    var l = try load(
        \\const builtin = import("builtin");
        \\struct Token {
        \\    id: int32;
        \\    drop(t) { builtin.print(builtin.str(t.id)); }
        \\}
        \\const GLOBAL = Token { id: 42 };
        \\fn main() -> void { builtin.print("MAIN"); }
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = Adapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expect(state.main_ran);
    try testing.expect(state.saw_id);
    try testing.expectEqual(@as(usize, 1), state.hooks);
}

test "mid-frame drop hook runs once through the hook continuation" {
    // A local struct with a user drop hook dies at scope end while the
    // root frame is live: the hook frame is placed above the running
    // frame's sp and returns through the `vm_internal_pc` continuation,
    // resuming destruction. The hook reads its parameter (the doomed
    // object) and runs exactly once.
    const Count = struct { hooks: usize = 0 };
    var state = Count{};
    const Adapter = struct {
        fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: interpreter.HostSignature, args: []const vm_types.Value) interpreter.HostResult {
            if (std.mem.eql(u8, member, "print")) {
                const c: *Count = @ptrCast(@alignCast(@constCast(userdata.?)));
                const bytes = vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "print: not a str" };
                if (std.mem.eql(u8, bytes, "7")) c.hooks += 1;
                return .{ .value = 0 };
            }
            return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
        }
    };
    var l = try load(
        \\const builtin = import("builtin");
        \\struct Token {
        \\    id: int32;
        \\    drop(t) { builtin.print(builtin.str(t.id)); }
        \\}
        \\fn main() -> int32 {
        \\    let t = Token { id: 7 };
        \\    3
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = Adapter.invoke },
    );
    defer term.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), state.hooks);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 3), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "release_ret fuses release+ret: the cleanup source dies with the frame" {
    // `release x; ret result` fuses to `release_ret result, x` (the
    // block-final pair, llir_fuse_lifecycle, Instruction Set §8:
    // `release_ret` = `release(b); return a`). Hand-built image: a
    // box[int32] is constructed (rc 1), then `release_ret F0, F2`
    // releases the box (rc 0 → destroyed) and returns the scalar 42.
    // The cleanup source must not survive the frame: zero live objects
    // after the run drains.
    const instrs = [_]llir.Instr{
        llir.instrI(.const_, llir.frame_base + 0, 0),
        llir.instrI(.construct, llir.frame_base + 2, 0),
        llir.instrE(.release_ret, llir.frame_base + 0, llir.frame_base + 2),
    };
    const types = [_]llir.TypeDesc{
        .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int32), .b = 0, .c = 0 },
        .{ .kind = .box, .a = 0, .b = 0, .c = 0 },
    };
    const constants = [_]llir.ConstRecord{.{ .kind = .int, .type_ = 0, .a = 42, .b = 0 }};
    var image: llir.LlirProgram = undefined;
    image.instructions = &instrs;
    image.functions = &.{.{ .code_start = 0, .code_end = 3, .entry_pc = 0, .signature_id = 0, .f_count = 6, .x_count = 0, .window_count = 0 }};
    image.blocks = &.{.{ .start_pc = 0, .end_pc = 3 }};
    image.signatures = &.{.{ .params_start = 0, .params_len = 0, .ret = 0 }};
    image.types = &types;
    image.constants = &constants;
    image.type_decls = &.{};
    image.type_decl_fields = &.{};
    image.union_variants = &.{};
    image.union_payloads = &.{};
    image.host_types = &.{};
    image.self_symbol = llir.no_index;
    image.init = llir.no_index;
    image.entry_member = llir.no_index;
    image.symbols = &.{};
    image.imports = &.{};
    image.exports = &.{};
    image.module_slots = &.{};
    image.params = &.{};
    image.call_args = &.{llir.frame_base + 0};
    image.syscall_descs = &.{};
    image.construct_descs = &.{.{ .tag = 0, .args_start = 0, .args_len = 1, .result_type = 1 }};
    image.destructure_dsts = &.{};
    image.destructure_dst_types = &.{};
    image.destructure_descs = &.{};
    image.switch_arms = &.{};
    image.switch_descs = &.{};
    image.member_descs = &.{};
    image.drop_descs = &.{};
    image.strings = "";
    const reject = try llir_validate.validate(&image, testing.allocator);
    if (reject) |m| {
        std.log.err("hand image rejected: {s}", .{m});
        testing.allocator.free(m);
        return error.TestUnexpectedResult;
    }
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(&image, 0);
    var result: ?Value = null;
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            switch (t) {
                .normal => |v| result = v,
                .panic => |m| {
                    std.log.err("release_ret panic: {s}", .{m});
                    testing.allocator.free(m);
                    return error.TestUnexpectedResult;
                },
            }
            break;
        }
        try vm.drainDestroyWork();
    }
    try vm.drainDestroyWork(); // drain whatever release_ret enqueued
    try testing.expectEqual(@as(Value, 42), result orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count());
}

// ---------------------------------------------------------------------------
// Stage 7 — path-specific edge effects (TODO.md 阶段 7)
// ---------------------------------------------------------------------------

test "stage 7.2: counted value released on one outgoing edge stays live on its sibling" {
    // `s` (a counted `str`) is read only on the then path (`print`). On
    // the else path it is never read, so it dies at the merge: the
    // release must ride the `br`→else edge — an LLIR-only edge block
    // that runs after the branch — and not before the terminator. Before
    // stage 7, per-edge kills were never emitted and `s` leaked. Run both
    // paths: else exercises the edge block; then the in-block trailing
    // release.
    const Sink = struct {
        fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: interpreter.HostSignature, args: []const vm_types.Value) interpreter.HostResult {
            if (std.mem.eql(u8, member, "print")) return .{ .value = 0 };
            return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
        }
    };
    const runMain = struct {
        fn run(main: []const u8) !u8 {
            var l = try load(main, true);
            defer l.deinit();
            var vm = interpreter.VmCtx.init(testing.allocator);
            defer vm.deinit();
            vm.host = .{ .invoke = Sink.invoke };
            try vm.setupRootArtifact(l.image, try l.fid("main"));
            var result: ?Value = null;
            while (!vm.runtime.terminated) {
                if (try vm_dispatch.step(&vm)) |t| {
                    switch (t) {
                        .normal => |v| result = v,
                        .panic => |m| {
                            std.log.err("stage7 panic: {s}", .{m});
                            testing.allocator.free(m);
                            return error.TestUnexpectedResult;
                        },
                    }
                    break;
                }
                try vm.drainDestroyWork();
            }
            vm.finishCleanup();
            try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count()); // no leak on either path
            return @intCast(result orelse return error.TestUnexpectedResult);
        }
    };
    // else path: `b = false`, so the else arm (edge-kill) runs and
    // returns 100.
    const v_else = try runMain.run(
        \\const builtin = import("builtin");
        \\fn pick(b: bool) -> int32 {
        \\    let s = builtin.str(42);
        \\    if (b) { builtin.print(s); 1 } else { 100 }
        \\}
        \\fn main() -> int32 { pick(false) }
    );
    try testing.expectEqual(@as(u8, 100), v_else);
    // then path: `b = true`, the then arm (trailing release) runs and
    // returns 1.
    const v_then = try runMain.run(
        \\const builtin = import("builtin");
        \\fn pick(b: bool) -> int32 {
        \\    let s = builtin.str(42);
        \\    if (b) { builtin.print(s); 1 } else { 100 }
        \\}
        \\fn main() -> int32 { pick(true) }
    );
    try testing.expectEqual(@as(u8, 1), v_then);
}

test "chained if-else str merges: an else arm returning the previous value" {
    // `let b = if (hp) { join2(a, ...) } else { a }` — the else arm
    // returns the existing `a` while the then arm produces a fresh str.
    // The merge phi's result shares `a`'s slot, so the edge copy is an
    // elided identity and the value flows through; the lifecycle pass
    // must NOT release it on that edge (it would destroy the reference
    // the phi result owns, and a second release down the chain traps on
    // the freed pointer). Regression: the whole chain traps in the VM's
    // forged-pointer check.
    const Sink = struct {
        fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: interpreter.HostSignature, args: []const vm_types.Value) interpreter.HostResult {
            if (std.mem.eql(u8, member, "print")) return .{ .value = 0 };
            return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
        }
    };
    var l = try load(
        \\fn join2(a: str, b: str) -> str {
        \\    if (a == "") { b } else { a + ", " + b }
        \\}
        \\fn main() -> int32 {
        \\    let hc = true;
        \\    let hp = true;
        \\    let hk = false;
        \\    let hs = false;
        \\    let a = if (hc) { "chest" } else { "" };
        \\    let b = if (hp) { join2(a, "potion") } else { a };
        \\    let c = if (hk) { join2(b, "key") } else { b };
        \\    let d = if (hs) { join2(c, "strange") } else { c };
        \\    let items = if (d == "") { "nothing" } else { d };
        \\    if (items == "chest, potion") { 1 } else { 0 }
        \\}
    , true);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    vm.host = .{ .invoke = Sink.invoke };
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    var result: ?Value = null;
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            switch (t) {
                .normal => |v| result = v,
                .panic => |m| {
                    std.log.err("chain panic: {s}", .{m});
                    testing.allocator.free(m);
                    return error.TestUnexpectedResult;
                },
            }
            break;
        }
        try vm.drainDestroyWork();
    }
    vm.finishCleanup();
    try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count()); // no leak, no double release
    try testing.expectEqual(@as(Value, 1), result orelse return error.TestUnexpectedResult);
}

test "stage 7.1: a switch executes only the selected arm's effects" {
    // A `match` lowers to a `switch` whose arms carry distinct effects.
    // Stage-7 edge blocks route each arm through its own LLIR-only block,
    // so selecting `R::A` runs only arm A's body and returns 1 — arm B's
    // effect (2) never executes. (Path-specific phi-copy separation itself
    // is pinned structurally in frontend_llir_core_tests stage 7.1, and
    // the lifecycle half at runtime by the stage-7.2 interpreter test.)
    var l = try load(
        \\union R { A, B }
        \\fn pick(r: R) -> int32 {
        \\    match (r) {
        \\        R::A => 1,
        \\        R::B => 2,
        \\    }
        \\}
        \\fn main() -> int32 { pick(R::A) }
    , true);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    var result: ?Value = null;
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            switch (t) {
                .normal => |v| result = v,
                .panic => |m| {
                    std.log.err("stage7 switch panic: {s}", .{m});
                    testing.allocator.free(m);
                    return error.TestUnexpectedResult;
                },
            }
            break;
        }
        try vm.drainDestroyWork();
    }
    vm.finishCleanup();
    try testing.expectEqual(@as(Value, 1), result.?);
    try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count());
}

test "host resource registry: duplicates reject; disposal runs exactly once" {
    var l = try load(
        \\fn main() -> int32 { 1 }
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();

    const H = struct {
        var disposed: usize = 0;
        fn dispose(_: ?*anyopaque, _: u64) void {
            disposed += 1;
        }
    };
    const payload: u64 = 0x0000_1234_5678_9abc; // a synthetic owner handle
    try vm.registerHostResource(3, payload, H.dispose, null);
    // The same un-released payload cannot register twice.
    try testing.expectError(error.DuplicateHostResource, vm.registerHostResource(3, payload, H.dispose, null));
    try testing.expect(vm.isHostResourceRegistered(payload));
    // Transfer out: ownership leaves the VM, registration disappears.
    _ = vm.takeHostResource(payload);
    try testing.expect(!vm.isHostResourceRegistered(payload));
    // Re-registration after transfer is legal (address reuse).
    try vm.registerHostResource(3, payload, H.dispose, null);
    vm.finishCleanup();
    try testing.expectEqual(@as(usize, 1), H.disposed);
    try testing.expectEqual(@as(usize, 0), vm.runtime.host_resources.count());
}

test "illegal null under a reference type traps before dereference" {
    // Zeroing the argument write hands the callee an empty-list cell
    // where its parameter contract says list[int32] — legal as the
    // empty list only for reads that tolerate it; consuming it traps.
    var l = try load(
        \\fn first(move xs: list[int32]) -> int32 {
        \\    let [h, ..t] = move xs;
        \\    h
        \\}
        \\fn main() -> int32 { first([5, 6]) }
    , true);
    defer l.deinit();
    const instrs = @constCast(l.image.instructions);
    for (instrs) |*rec| {
        if (llir.decode(rec.*)) |d| {
            if (d.op == .split_list) {
                rec.* = llir.instrI(.split_list, llir.zero_reg, d.imm16); // consuming the empty-list null
            }
        }
    }
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => {},
    }
}
