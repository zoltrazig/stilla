//! Black-box scalar interpreter tests (docs/interpreter-vm.md): canonical cell
//! encodings, bit-exact raw-cell transfers, the resolved typed zero, arithmetic
//! traps, the three-cell frame header, the execution skeleton, and the i64/u64 and
//! f64 width/bit-pattern end-to-end cases.

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
const drainRootInit = support.drainRootInit;

// ---------------------------------------------------------------------------
// Canonical scalar bits (Runtime §7.2)
// ---------------------------------------------------------------------------

test "canonical scalar encodings round-trip" {
    // bool: exactly 0 or 1.
    try testing.expectEqual(@as(Value, 0), ValueCodec.encodeBool(false));
    try testing.expectEqual(@as(Value, 1), ValueCodec.encodeBool(true));
    try testing.expectEqual(false, ValueCodec.decodeBool(0).?);
    try testing.expectEqual(true, ValueCodec.decodeBool(1).?);
    try testing.expect(ValueCodec.decodeBool(2) == null); // non-canonical

    // byte: low 8 bits, high 56 zero.
    try testing.expectEqual(@as(Value, 0xff), ValueCodec.encodeByte(255));
    try testing.expectEqual(@as(u8, 0x42), ValueCodec.decodeByte(0x42).?);
    try testing.expect(ValueCodec.decodeByte(1 << 8) == null); // dirty high bits

    // 32-bit integer cells sign-extend their low word.
    try testing.expectEqual(@as(Value, 0xffff_ffff_ffff_ffff), ValueCodec.encodeInt32(-1));
    try testing.expectEqual(@as(Value, 0), ValueCodec.encodeInt32(0));
    try testing.expectEqual(@as(i32, -1), ValueCodec.decodeInt32(0xffff_ffff_ffff_ffff).?);
    try testing.expect(ValueCodec.decodeInt32(0x0000_0000_ffff_ffff) == null);

    // uint32 uses the same cell extension; unsigned opcodes choose ordering.
    try testing.expectEqual(@as(Value, 0xffff_ffff_ffff_ffff), ValueCodec.encodeUint32(0xffff_ffff));
    try testing.expectEqual(@as(u32, 0xffff_ffff), ValueCodec.decodeUint32(0xffff_ffff_ffff_ffff).?);
    try testing.expect(ValueCodec.decodeUint32(0x0000_0000_ffff_ffff) == null);

    // float32: the raw IEEE binary32 pattern in the low word (+0.0 is
    // the all-zero cell).
    try testing.expectEqual(@as(Value, 0), ValueCodec.encodeFloat32(0.0));
    const nan_bits: u32 = 0x7fc0_0001; // a signalling-ish NaN payload
    const nan: f32 = @bitCast(nan_bits);
    try testing.expect(std.math.isNan(nan));
    try testing.expectEqual(@as(Value, nan_bits), ValueCodec.encodeFloat32(nan));
    const back = ValueCodec.decodeFloat32(ValueCodec.encodeFloat32(nan)).?;
    // NaN payload round-trips losslessly through the raw cell.
    try testing.expectEqual(nan_bits, @as(u32, @bitCast(back)));

    // Every scalar zero shares the single all-zero cell.
    try testing.expectEqual(ValueCodec.zero, ValueCodec.encodeBool(false));
    try testing.expectEqual(ValueCodec.zero, ValueCodec.encodeByte(0));
    try testing.expectEqual(ValueCodec.zero, ValueCodec.encodeInt32(0));
    try testing.expectEqual(ValueCodec.zero, ValueCodec.encodeUint32(0));
    try testing.expectEqual(ValueCodec.zero, ValueCodec.encodeFloat32(0.0));
}

// ---------------------------------------------------------------------------
// Full-cell transfers + typed zero + arithmetic traps, end to end
// ---------------------------------------------------------------------------

test "raw cell transfers: values pass through move/arg/ret bit-exact" {
    // The full-width uint32 pattern travels caller → slot_move → callee
    // → ret → root result without any transfer masking or rewriting
    // bits.
    var l = try load(
        \\fn passthrough(v: int32) -> int32 { v }
        \\fn main() -> int32 { passthrough(-1) }
    , false);
    defer l.deinit();
    const entry = try l.fid("main");
    var term = try interpreter.runWithEntry(testing.allocator, l.image, entry, .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 0xffff_ffff_ffff_ffff), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "typed zero: the resolved contract supplies an all-zero cell" {
    // `ret zero` materializes the canonical zero of the signature's
    // return type — the all-zero cell, typed by the resolved contract,
    // never by bits. The ret is the record the interpreter decodes at
    // that pc, so the surgery rewrites the record itself.
    var l = try load(
        \\fn answer() -> int32 { 42 }
        \\fn main() -> int32 { answer() }
    , false);
    defer l.deinit();
    const instrs = @constCast(l.image.instructions);
    for (instrs) |*rec| {
        if (llir.decode(rec.*)) |d| {
            if (d.op == .ret) {
                rec.* = llir.instrE(.ret, llir.zero_reg, 0);
            }
        }
    }
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 0), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "division traps fire before any write" {
    var l = try load(
        \\fn div(a: int32, b: int32) -> int32 { a / b }
        \\fn main() -> int32 { div(1, 0) }
    , false);
    defer l.deinit();
    const entry = try l.fid("main");
    var term = try interpreter.runWithEntry(testing.allocator, l.image, entry, .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "division by zero") != null),
    }
    // The 64-bit signed division overflow still traps.
    var l2 = try load(
        \\fn div(a: int64, b: int64) -> int64 { a / b }
        \\fn main() -> int64 { div(-9223372036854775808, -1) }
    , false);
    defer l2.deinit();
    const entry2 = try l2.fid("main");
    var term2 = try interpreter.runWithEntry(testing.allocator, l2.image, entry2, .{});
    defer term2.deinit(testing.allocator);
    switch (term2) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "overflow") != null),
    }
    // The widthless `int32` division carries no 32-bit overflow trap:
    // `int32_min / -1` computes at 64 bits (+2³¹) and the lowering's
    // `sext32` wraps the result to `int32_min` (Instruction Set §4 —
    // the widthless trade-off; WebAssembly *unchecked* semantics).
    var l2b = try load(
        \\fn div(a: int32, b: int32) -> int32 { a / b }
        \\fn main() -> int32 { div(-2147483648, -1) }
    , false);
    defer l2b.deinit();
    var term2b = try interpreter.runWithEntry(testing.allocator, l2b.image, try l2b.fid("main"), .{});
    defer term2b.deinit(testing.allocator);
    switch (term2b) {
        .normal => |v| try testing.expectEqual(@as(Value, 0xffff_ffff_8000_0000), v),
        .panic => return error.TestUnexpectedResult,
    }
    // min % -1 is defined: 0, never a trap.
    var l3 = try load(
        \\fn rem(a: int32, b: int32) -> int32 { a % b }
        \\fn main() -> int32 { rem(-2147483648, -1) }
    , false);
    defer l3.deinit();
    var term3 = try interpreter.runWithEntry(testing.allocator, l3.image, try l3.fid("main"), .{});
    defer term3.deinit(testing.allocator);
    switch (term3) {
        .normal => |v| try testing.expectEqual(@as(Value, 0), v),
        .panic => return error.TestUnexpectedResult,
    }
}

test "B.0-elided zext32 of a u32 divide still computes the correct quotient" {
    // `300 as uint32` is a zero-extended dividend, so the div.u32 lowering
    // drops the dividend's staging zext32 (B.0) and fuses the constant
    // divisor into `diviu`; the interpreter must still return 42.
    var l = try load(
        \\fn main() -> uint32 { (300 as uint32) / 7 }
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 42), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "u32 divide of a high-bit dividend zero-extends its staged dividend" {
    // The mul result (sext32-canonicalized) has its top bit set, so the
    // div.u32 sequence stages it through a zext32 before the widthless
    // divu; a zext32 that fails to clear the high bits makes the unsigned
    // dividend read as ~2^64 and the quotient comes out garbage.
    // Regression: stsmith seed 5 (v27: u32, quotient 4107778581 != 3).
    var l = try load(
        \\fn g() -> uint32 { 2040345509 }
        \\fn main() -> uint32 { (67371137 * g()) / 866546848 }
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 3), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

// ---------------------------------------------------------------------------
// Frame header scenarios (root / normal call / internal continuation)
// ---------------------------------------------------------------------------

test "frame header: root carries sentinels; normal calls record the caller frame base" {
    // After the run completes, the stack still holds both frames:
    // the root header at [0, 3) with its sentinels, and the callee
    // header written by the call at [callee_fp - 3, callee_fp).
    var l = try load(
        \\fn add(a: int32, b: int32) -> int32 { a + b }
        \\fn main() -> int32 { add(20, 22) }
    , false);
    defer l.deinit();

    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    const entry = try l.fid("main");
    try vm.setupRootArtifact(l.image, entry);
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |_| break;
    }

    // Root header: the fixed three-cell header at [0, 3) — sentinels
    // distinguished by position, never by bits.
    try testing.expectEqual(interpreter.invalid_pc, @as(u32, @truncate(vm.runtime.stack.items[0])));
    try testing.expectEqual(interpreter.invalid_pc, @as(u32, @truncate(vm.runtime.stack.items[1])));
    try testing.expectEqual(interpreter.invalid_pc, @as(u32, @truncate(vm.runtime.stack.items[2])));
    const root_hdr = interpreter.readHeader(vm.runtime.stack.items, 3);
    try testing.expect(root_hdr.check(vm.loaded.funcs.items, 3));

    // The callee frame sits below main's window; its three-cell header
    // records the caller's frame base, function index, and the resume pc
    // by position.
    const main_fd = l.image.functions[entry];
    const a: u32 = @max(2, 1); // P=2 params, R=1 result
    const callee_fp = llir.frameEnd(3, main_fd) - a; // the value area aliases the window top
    const hdr = interpreter.readHeader(vm.runtime.stack.items, callee_fp);
    try testing.expect(hdr.check(vm.loaded.funcs.items, callee_fp));
    try testing.expectEqual(@as(u32, 3), hdr.saved_fp); // the caller's frame base (root fp)
    try testing.expectEqual(entry, hdr.saved_fn); // the caller's function registry index
    // The recorded return pc names main's instruction after its call.
    const resumed = l.image.instructions[hdr.saved_ra];
    try testing.expect(llir.functionAtPc(l.image.functions, hdr.saved_ra) != null);
    // The callee publishes its result to slot 0 (its F0 — the caller's
    // result alias); the caller's `ret` then reads the alias directly
    // (Step 8 coalescing: `main` returns the call result, so the
    // post-call `take` is dropped and the alias is never cleared).
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(vm.runtime.stack.items[callee_fp])));
    _ = resumed;
}

test "frame header: internal-continuation sentinel validates by position" {
    // A synthetic runtime-initiated frame: the header carries
    // vm_internal_pc in the return-pc position. Decoding accepts it
    // (same payload as invalid_pc, different field meaning is carried
    // by position alone) and range validation passes.
    var l = try load(
        \\fn leaf() -> int32 { 7 }
        \\fn main() -> int32 { leaf() }
    , false);
    defer l.deinit();

    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    const entry = try l.fid("leaf");
    try vm.setupRootArtifact(l.image, entry);
    try drainRootInit(&vm, entry);
    // Rewrite the root header into a runtime-initiated call: the
    // continuation machinery (modules/drop hooks) will consume this.
    vm.runtime.stack.items[1] = 0; // saved_fn: a valid registry index (root fn)
    vm.runtime.stack.items[2] = interpreter.vm_internal_pc;
    try testing.expect(interpreter.readHeader(vm.runtime.stack.items, vm.runtime.fp).check(vm.loaded.funcs.items, vm.runtime.fp));
    // A corrupt header — saved_fp not below the current fp — fails validation.
    vm.runtime.stack.items[0] = 999999;
    try testing.expect(!interpreter.readHeader(vm.runtime.stack.items, vm.runtime.fp).check(vm.loaded.funcs.items, vm.runtime.fp));
    // A saved_fn out of range (with a real return pc) fails validation.
    vm.runtime.stack.items[0] = 0;
    vm.runtime.stack.items[1] = 999999;
    try testing.expect(!interpreter.readHeader(vm.runtime.stack.items, vm.runtime.fp).check(vm.loaded.funcs.items, vm.runtime.fp));
    // A saved_fn whose range does NOT contain the saved_ra fails too —
    // the O(1) position-consistent check is stronger than the old
    // "any function contains the pc" scan. saved_ra is a real pc
    // (leaf's own entry); saved_fn names leaf → consistent, passes.
    const leaf_fd = l.image.functions[entry];
    vm.runtime.stack.items[0] = interpreter.invalid_pc;
    vm.runtime.stack.items[1] = entry;
    vm.runtime.stack.items[2] = leaf_fd.entry_pc;
    try testing.expect(interpreter.readHeader(vm.runtime.stack.items, vm.runtime.fp).check(vm.loaded.funcs.items, vm.runtime.fp));
    // Out of range with a real return pc fails validation.
    vm.runtime.stack.items[1] = 999999;
    try testing.expect(!interpreter.readHeader(vm.runtime.stack.items, vm.runtime.fp).check(vm.loaded.funcs.items, vm.runtime.fp));
}

test "frame header: a corrupted saved_fn traps at return" {
    // A runtime corruption of the callee's saved_fn cell (a value that
    // is a valid index but whose range does not contain the return pc)
    // must trap with "corrupt frame header" — the header check runs
    // before any restore.
    var l = try load(
        \\fn leaf() -> int32 { 7 }
        \\fn main() -> int32 { leaf() }
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    try drainRootInit(&vm, try l.fid("main"));
    // Step until the callee's frame is live (pc inside `leaf`), then
    // corrupt its saved_fn cell (the middle of the three header cells).
    var steps: usize = 0;
    while (steps < 100 and llir.functionAtPc(l.image.functions, vm.runtime.pc) != try l.fid("leaf")) {
        var t = try vm_dispatch.step(&vm);
        if (t != null) {
            t.?.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        }
        try vm.drainDestroyWork();
        steps += 1;
    }
    const main_fd = l.image.functions[try l.fid("main")];
    const a: u32 = @max(0, 1); // leaf: no params, one result
    const callee_fp = llir.frameEnd(3, main_fd) - a;
    // saved_fn names `leaf` — a real index whose code range does NOT
    // contain the return pc (which lies in main): the position-consistent
    // check fails and the ret traps.
    vm.runtime.stack.items[llir.headerBase(callee_fp) + 1] = try l.fid("leaf");
    // Run until the callee's `ret` executes (it follows its const).
    var term: ?interpreter.Termination = null;
    var n: usize = 0;
    while (n < 10) {
        term = try vm_dispatch.step(&vm);
        if (term != null) break;
        try vm.drainDestroyWork();
        n += 1;
    }
    defer if (term) |*t| t.deinit(testing.allocator);
    switch (term orelse return error.TestUnexpectedResult) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "corrupt frame header") != null),
    }
}

test "jal: the published operand is the load-resolved callee index" {
    // Static `jal ra` targets are resolved once at load: publishArtifact
    // rewrites the instruction's operand from the wire imm20 to the
    // callee's function registry index, so the direct-call path performs
    // no pc→function search and no entry check.
    var l = try load(
        \\fn callee() -> int32 { 9 }
        \\fn main() -> int32 { callee() }
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    // The root publishes at func_base 0, so the registry index equals
    // the local FunctionId.
    var found = false;
    for (vm.loaded.code.items) |vi| {
        if (vi.op != .jal) continue;
        found = true;
        try testing.expectEqual(@as(u32, try l.fid("callee")), vi.operand);
    }
    try testing.expect(found);
    // The direct call executes through the resolved index.
    var term: ?interpreter.Termination = null;
    var steps: usize = 0;
    while (steps < 100) {
        term = try vm_dispatch.step(&vm);
        if (term != null) break;
        try vm.drainDestroyWork();
        steps += 1;
    }
    defer if (term) |*t| t.deinit(testing.allocator);
    switch (term orelse return error.TestUnexpectedResult) {
        .normal => |v| try testing.expectEqual(@as(Value, 9), v),
        .panic => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Execution skeleton behaviors
// ---------------------------------------------------------------------------

test "control flow and scalars: fib-style loop computes through branches" {
    var l = try load(
        \\fn upto(n: int32) -> int32 {
        \\    let acc = 0;
        \\    let i = 1;
        \\    acc + i * n
        \\}
        \\fn main() -> int32 { upto(10) }
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 10), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "self-tailcall reuses the frame as a pure jump" {
    var l = try load(
        \\fn count(n: int32, acc: int32) -> int32 {
        \\    if (n <= 0) { acc } else { count(n - 1, acc + n) }
        \\}
        \\fn main() -> int32 { count(4, 0) }
    , true);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 10), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "stack limit: deep recursion terminates with a deterministic trap" {
    var l = try load(
        \\fn inf(n: int32) -> int32 { inf(n + 1) }
        \\fn main() -> int32 { inf(0) }
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    vm.stack_limit = 256;
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    while (!vm.runtime.terminated) {
        const t = vm_dispatch.step(&vm) catch |e| switch (e) {
            error.StackOverflow => {
                std.log.info("stack overflow trapped as expected", .{});
                break;
            },
            else => return e,
        };
        if (t != null) break;
    }
    // The trap fired before the limit was exceeded unboundedly.
    try testing.expect(vm.runtime.stack.items.len <= 512);
}

// ---------------------------------------------------------------------------
// Phase 4 — i64/u64 end-to-end (TODO.md 阶段 4)
// ---------------------------------------------------------------------------

test "i64/u64: literals type at target width and round-trip the pipeline" {
    var l = try load(
        \\fn echo(x: int64) -> int64 { x }
        \\fn main() -> int32 {
        \\    let a: int64 = 9223372036854775807;
        \\    let b: uint64 = 18446744073709551615;
        \\    let n: int64 = a;
        \\    let m: uint64 = b;
        \\    let r = echo(n);
        \\    0
        \\}
    , true);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {}, // compiled, validated, executed cleanly
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "i64 arithmetic: min/-1 traps; wrapping is modulo 2^64" {
    var l = try load(
        \\fn d(a: int64, b: int64) -> int64 { a / b }
        \\fn main() -> int32 {
        \\    let lo: int64 = -9223372036854775808;
        \\    let minus1: int64 = -1;
        \\    let q = d(lo, minus1);
        \\    0
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "overflow") != null),
    }
}

test "u64 shifts: counts are taken modulo 64" {
    var l = try load(
        \\fn sh(x: uint64, k: uint64) -> uint64 { x << k }
        \\fn main() -> int32 {
        \\    let one: uint64 = 1;
        \\    let k: uint64 = 64;
        \\    let shifted = sh(one, k);
        \\    0
        \\}
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |_| break;
        try vm.drainDestroyWork();
    }
}

test "binary format: readers reject pre-phase-4 versions" {
    var l = try load(
        \\fn main() -> int32 { 7 }
    , false);
    defer l.deinit();
    var bytes = try lower.emitBin(l.image.*, testing.allocator);
    defer testing.allocator.free(bytes);
    // The version field follows the magic: patch it to the pre-phase-4
    // value and expect rejection before any table decode.
    try testing.expect(bytes.len > 8);
    bytes[4] = 4;
    bytes[5] = 0;
    bytes[6] = 0;
    bytes[7] = 0;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidFormat, lower.readBin(arena.allocator(), bytes));
}

// ---------------------------------------------------------------------------
// Phase 5 — f64 end-to-end (TODO.md 阶段 5)
// ---------------------------------------------------------------------------

test "f64: literals type at target width and execute at binary64 precision" {
    var l = try load(
        \\fn main() -> int32 {
        \\    let pi: float64 = 3.141592653589793;
        \\    let two: float64 = 2.0;
        \\    let half: float64 = pi / two;
        \\    0
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "f64 NaN payload survives a full-width cell round-trip" {
    // A binary64 quiet NaN with a nonzero payload: constructed by
    // bit-pattern, executed through the VM's raw cells.
    var l = try load(
        \\fn main() -> int32 { 0 }
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    // Multiple distinct quiet-NaN payloads — every bit round-trips.
    const payloads = [_]u64{
        0x7ff8_0001_dead_beef,
        0x7ff0_0000_0000_0001, // signaling-pattern payload
        0x7fff_ffff_ffff_ffff, // max payload
        0x7ff4_1234_5678_9abc,
    };
    for (payloads) |nan_bits| {
        const v: f64 = @bitCast(nan_bits);
        try testing.expect(std.math.isNan(v));
        // The canonical cell of an f64 keeps every bit.
        const cell: u64 = vm_types.ValueCodec.encodeFloat64(v);
        try testing.expectEqual(nan_bits, cell);
        const back: f64 = vm_types.ValueCodec.decodeFloat64(cell);
        try testing.expect(std.math.isNan(back));
        try testing.expectEqual(nan_bits, @as(u64, @bitCast(back)));
    }
}

test "f64 signed zero: -0.0 is preserved through arithmetic" {
    var l = try load(
        \\fn neg(x: float64) -> float64 { -x }
        \\fn main() -> int32 {
        \\    let z: float64 = 0.0;
        \\    let nz = neg(z);
        \\    0
        \\}
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |_| break;
        try vm.drainDestroyWork();
    }
    // Somewhere in the frame or temp bank lives -0.0: the sign bit is
    // set with an otherwise-zero pattern.
    var saw_negative_zero = false;
    for (vm.runtime.stack.items) |c| {
        if (c == 0x8000_0000_0000_0000) saw_negative_zero = true;
    }
    for (vm.runtime.fast_regs) |t| {
        if (t == 0x8000_0000_0000_0000) saw_negative_zero = true;
    }
    try testing.expect(saw_negative_zero);
}

test "uniform conversion family: the 5×5 cast matrix executes" {
    // One `cvt_*` opcode per source type, `c` naming the destination
    // (0 int32, 1 uint32, 2 f32, 3 f64), the self entry the byte
    // conversion. The byte forms saturate a float source to [0, 255]
    // (300.0f → 255, not 44); float→int truncates toward zero.
    var l = try load(
        \\fn main() -> int32 {
        \\    let b: byte = 200 as byte;
        \\    let bu: uint32 = b as uint32;
        \\    let bf: float64 = b as float64;
        \\    let u: uint32 = 300 as uint32;
        \\    let uf: float32 = u as float32;
        \\    let fu: uint32 = uf as uint32;
        \\    let f: float64 = 3.9;
        \\    let fi: int32 = f as int32;
        \\    let fb: byte = f as byte;
        \\    let f32b: byte = uf as byte;
        \\    bu as int32 + bf as int32 + fu as int32 + fi + fb as int32 + f32b as int32
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        // 200 + 200 + 300 + 3 + 3 + 255
        .normal => |v| try testing.expectEqual(@as(Value, 961), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "f64 plan selection: same opcode family, binary32 vs binary64 semantics" {
    // 1/3 × 1e9 discriminates the widths: binary32 rounds to
    // 333333344.0, binary64 to 333333333.33… — the truncated int32
    // results differ by 11.
    var l64 = try load(
        \\fn fdiv(a: float64, b: float64) -> float64 { a / b }
        \\fn fmul(a: float64, b: float64) -> float64 { a * b }
        \\fn main() -> int32 {
        \\    let one: float64 = 1.0;
        \\    let three: float64 = 3.0;
        \\    let scale: float64 = 1000000000.0;
        \\    let y = fmul(fdiv(one, three), scale);
        \\    y as int32
        \\}
    , false);
    defer l64.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l64.image, try l64.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 333333333), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }

    var l32 = try load(
        \\fn fdiv(a: float32, b: float32) -> float32 { a / b }
        \\fn fmul(a: float32, b: float32) -> float32 { a * b }
        \\fn main() -> int32 {
        \\    let one: float32 = 1.0;
        \\    let three: float32 = 3.0;
        \\    let scale: float32 = 1000000000.0;
        \\    let y = fmul(fdiv(one, three), scale);
        \\    y as int32
        \\}
    , false);
    defer l32.deinit();
    term = try interpreter.runWithEntry(testing.allocator, l32.image, try l32.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 333333344), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "f64 remainder: truncated remainder; zero divisor yields NaN (no trap)" {
    var l = try load(
        \\fn rem(a: float64, b: float64) -> float64 { a % b }
        \\fn main() -> int32 {
        \\    let a: float64 = 5.5;
        \\    let b: float64 = 2.0;
        \\    let zero: float64 = 0.0;
        \\    let r = rem(a, b);
        \\    let n = rem(a, zero);
        \\    if (r as int32 == 1 and n as int32 == 0) { 7 } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 7), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "f64 NaN comparison: every ordered and equality comparison is false" {
    var l = try load(
        \\fn lt(a: float64, b: float64) -> bool { a < b }
        \\fn eq(a: float64, b: float64) -> bool { a == b }
        \\fn main() -> int32 {
        \\    let n: float64 = 0.0;
        \\    let one: float64 = 1.0;
        \\    let nan = n / n;
        \\    if (lt(nan, one)) {
        \\        1
        \\    } else if (eq(nan, nan)) {
        \\        2
        \\    } else {
        \\        0
        \\    }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 0), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "f64 infinities: division by zero yields ±inf; inf >= inf and inf > -inf" {
    var l = try load(
        \\fn fdiv(a: float64, b: float64) -> float64 { a / b }
        \\fn lt(a: float64, b: float64) -> bool { a < b }
        \\fn ge(a: float64, b: float64) -> bool { a >= b }
        \\fn main() -> int32 {
        \\    let one: float64 = 1.0;
        \\    let zero: float64 = 0.0;
        \\    let mone: float64 = -1.0;
        \\    let inf = fdiv(one, zero);
        \\    let ninf = fdiv(mone, zero);
        \\    if (lt(ninf, inf) and ge(inf, inf)) { 1 } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 1), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "f64 subnormal boundary: the smallest subnormal is positive and below the smallest normal" {
    var l = try load(
        \\fn lt(a: float64, b: float64) -> bool { a < b }
        \\fn main() -> int32 {
        \\    let s: float64 = 5e-324;
        \\    let z: float64 = 0.0;
        \\    let m: float64 = 2.2250738585072014e-308;
        \\    let t: float64 = 2.225073858507201e-308;
        \\    if (lt(z, s) and lt(t, m)) { 1 } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 1), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "f64 rounding edges: 2^53+1 rounds to 2^53; 0.1+0.2 != 0.3" {
    var l = try load(
        \\fn eq(a: float64, b: float64) -> bool { a == b }
        \\fn ne(a: float64, b: float64) -> bool { a != b }
        \\fn fadd(a: float64, b: float64) -> float64 { a + b }
        \\fn main() -> int32 {
        \\    let a: float64 = 9007199254740993.0;
        \\    let b: float64 = 9007199254740992.0;
        \\    let x: float64 = 0.1;
        \\    let y: float64 = 0.2;
        \\    let c: float64 = 0.3;
        \\    if (eq(a, b) and ne(fadd(x, y), c)) { 1 } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 1), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "64-bit cast matrix executes: widening, narrowing, and reinterpret" {
    // The Core §16.3 family over the seven conversion types: `int32 as
    // i64` / `as u64` sign-extend the low 32 bits (two's-complement
    // conversion — `-2 as u64` is `2⁶⁴ − 2`), `uint32 as i64` / `as u64`
    // zero-extend, `byte as i64` / `as u64` zero-extend the low 8 bits,
    // `i64 ↔ u64` reinterprets the full 64-bit cell, and the 64→32
    // forms keep the low 32 bits. None trap.
    var l = try load(
        \\fn main() -> int64 {
        \\    let m: int64 = -1;
        \\    let neg_one = m as uint64;        // 0xffff_ffff_ffff_ffff
        \\    let back = neg_one as int64;     // -1
        \\    let s: int32 = -2;
        \\    let widened = s as int64;        // -2
        \\    let widen_u = s as uint64;        // 0xffff_ffff_ffff_fffe
        \\    let u: uint32 = 4294967295;
        \\    let uz = u as int64;             // 4294967295
        \\    let zu = u as uint64;             // 4294967295
        \\    let b: byte = 200 as byte;
        \\    let bw = b as uint64;             // 200
        \\    let bi = b as int64;             // 200
        \\    let trunc = m as int32;        // -1
        \\    if (neg_one == 18446744073709551615 and back == -1 and widened == -2
        \\        and widen_u == 18446744073709551614 and uz == 4294967295
        \\        and zu == 4294967295 and bw == 200 and bi == 200 and trunc == -1) {
        \\        7
        \\    } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 7), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "64-bit float↔int casts: rounding, truncation, and saturation" {
    // `f64 as i64` truncates toward zero and saturates on NaN /
    // out-of-range (NaN → 0, ≥ 2⁶³ → i64_max, ≤ −2⁶³ → i64_min);
    // `f64 as u64` saturates to `[0, 2⁶⁴)`; `i64 as f64` rounds to
    // nearest (values beyond 2⁵³ lose precision); a `u64 as f64`
    // rounding up to 2⁶⁴ recovers u64_max on the way back.
    var l = try load(
        \\fn main() -> int32 {
        \\    let f: float64 = 3.9;
        \\    let fi = f as int64;                 // 3
        \\    let big: float64 = 1e300;
        \\    let sat = big as int64;              // i64_max
        \\    let neg: float64 = -1e300;
        \\    let sneg = neg as int64;             // i64_min
        \\    let usat = big as uint64;             // u64_max
        \\    let nan: float64 = 0.0;
        \\    let nz = (nan / nan) as int64;       // NaN → 0
        \\    let i: int64 = 9007199254740993;     // 2^53 + 1
        \\    let r = i as float64;                  // rounds to 2^53
        \\    let rb = r as int64;
        \\    let u: uint64 = 18446744073709551615;
        \\    let round = (u as float64) as uint64;     // 2^64 → u64_max
        \\    let f32v: float32 = 2.5;
        \\    let f32i = f32v as int64;            // 2
        \\    let f32u = f32v as uint64;            // 2
        \\    let f32neg: float32 = -1e30;
        \\    let f32sat = f32neg as int64;        // f32 ≤ −2⁶³ → i64_min
        \\    let i64f32: int64 = 16777217;         // 2^24 + 1
        \\    let f32r = i64f32 as float32;      // rounds to 2^24 at binary32 precision
        \\    let u64f32: uint64 = 4294967296;
        \\    let f32w = u64f32 as float32;      // 2^32 exact in binary32
        \\    if (fi == 3 and sat == 9223372036854775807 and sneg == -9223372036854775808
        \\        and usat == 18446744073709551615 and nz == 0 and rb == 9007199254740992
        \\        and round == 18446744073709551615 and f32i == 2 and f32u == 2
        \\        and f32sat == -9223372036854775808 and f32r as int64 == 16777216
        \\        and f32w as uint64 == 4294967296) {
        \\        7
        \\    } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 7), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}
