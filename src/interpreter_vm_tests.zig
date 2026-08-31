//! White-box tests for the Stilla interpreter VM (docs/interpreter-vm.md
//! §12 — "cell conversion, retain/release primitives, destruction
//! ordering"). These exercise `Vm` and its `VmHeap` directly, so they sit
//! beside the core (`interpreter.zig`) rather than in the black-box
//! `interpreter_tests.zig`.

const std = @import("std");
const testing = std.testing;
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interpreter = @import("interpreter.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const VmCtx = interpreter.VmCtx;
const Value = vm_types.Value;
const ObjectHeader = vm_types.ObjectHeader;

test "deref rejects forged scalars without dereferencing them" {
    var vm = VmCtx{
        .allocator = std.testing.allocator,
        .runtime = .{ .heap = .{ .allocator = std.testing.allocator } },
    };
    defer vm.runtime.heap.deinit();
    // A scalar bit pattern that happens to look like an address: the
    // registry has no such key, so membership fails BEFORE memory is
    // touched (no segfault even though the address is unmapped).
    try testing.expectError(error.ForgedPointer, vm.runtime.heap.deref(0xdead_beef_cafe_f00d));
}

test "registry keeps full-width synthetic keys and never dereferences them" {
    var vm = VmCtx{
        .allocator = std.testing.allocator,
        .runtime = .{ .heap = .{ .allocator = std.testing.allocator } },
    };
    defer vm.runtime.heap.deinit();
    // A test-owned header backing a synthetic key above the real host
    // address range: proves every address bit survives and the VM reads
    // the header through the registry mapping instead of the pointer.
    var cells = [_]Value{ 42, 0 };
    var h = ObjectHeader{
        .kind = .box_,
        .type_id = 1,
        .len = 0,
        .track = .{ .CopyValue = 1 },
        .total_cells = 1,
        .cells = &cells,
    };
    const synthetic: u64 = 0x0001_0000_0000_f1f1; // > 0x0000_ffff_ffff_ffff
    try vm.runtime.heap.registry.put(std.testing.allocator, synthetic, &h);
    // A minimal type table so the header cross-check has real rows:
    // t0 = byte(PrimitiveId 0), t1 = bool(1).
    var types = [_]llir.TypeDesc{
        .{ .kind = .primitive, .a = 0, .b = 0, .c = 0 },
        .{ .kind = .primitive, .a = 1, .b = 0, .c = 0 },
    };
    var image: llir.LlirProgram = undefined;
    image.types = &types;
    vm.loaded.meta_image = &image;
    const got = try vm.runtime.heap.deref(synthetic);
    try testing.expectEqual(@as(Value, 42), got.cell(0));
}

test "use-after-free: freed addresses leave the registry before their memory dies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = VmCtx{
        .allocator = arena.allocator(),
        .runtime = .{ .heap = .{ .allocator = arena.allocator() } },
    };
    const h = try vm.runtime.heap.allocObject(.box_, 3, 0, 1);
    h.setCell(0, 9);
    const addr = @intFromPtr(h);
    _ = try vm.runtime.heap.deref(addr); // membership + type checks pass while live
    vm.runtime.heap.freeShell(h);
    // Freed ⇒ deregistered ⇒ any later dereference traps safely instead
    // of reading the dead object.
    try testing.expectError(error.ForgedPointer, vm.runtime.heap.deref(addr));
}

test "release decrements and destroys at zero; retain shares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = VmCtx{
        .allocator = arena.allocator(),
        .runtime = .{ .heap = .{ .allocator = arena.allocator() } },
    };
    // A str type row so typed retains recognize the cell as a pointer.
    var types = [_]llir.TypeDesc{.{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.str), .b = 0, .c = 0 }};
    var image: llir.LlirProgram = undefined;
    image.types = &types;
    vm.loaded.meta_image = &image;
    const h = try vm.runtime.heap.allocObject(.str_, 0, 0, 4);
    @memcpy(@as([*]u8, @ptrCast(h.cells))[0..4], "abcd");
    const addr = @intFromPtr(h);
    try vm_dispatch.retainCell(&vm, addr);
    try testing.expectEqual(@as(u32, 2), h.track.CopyValue);
    try vm_dispatch.releaseCounted(&vm, addr); // rc 1: still alive
    try testing.expect(vm.runtime.heap.registry.contains(addr));
    try vm_dispatch.releaseCounted(&vm, addr); // rc 0: destruction enqueued
    try vm.drainDestroyWork();
    try testing.expect(!vm.runtime.heap.registry.contains(addr));
}

test "f64_min/f64_max: IEEE fmin/fmax — NaN propagates, -0 beats +0" {
    // White-box: the zero tie and NaN propagation live in the VM's
    // min/max execution (StdLib §4: `min`/`max` follow IEEE 754
    // `fmin`/`fmax`). A hand-built single-function image runs the two
    // records directly through the v9 decoder (no derived stream).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const instrs = [_]llir.Instr{
        llir.instrR(.min_f64, llir.cond_reg, llir.temp_base, llir.temp_base + 1),
        llir.instrR(.max_f64, llir.temp_base + 2, llir.temp_base, llir.temp_base + 1),
        llir.instrR(.min_f64, llir.temp_base + 3, llir.temp_base + 4, llir.temp_base + 5),
        llir.instrE(.ret, llir.cond_reg, 0),
    };
    const funcs = [_]llir.FunctionDesc{.{
        .code_start = 0,
        .code_end = 4,
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 8,
        .x_count = 0,
        .window_count = 3,
    }};
    const sigs = [_]llir.SignatureDesc{.{
        .params_start = 0,
        .params_len = 0,
        .ret = 0,
    }};
    const types = [_]llir.TypeDesc{.{
        .kind = .primitive,
        .a = @intFromEnum(llir.PrimitiveId.f64),
        .b = 0,
        .c = 0,
    }};
    var image: llir.LlirProgram = undefined;
    image.instructions = &instrs;
    image.functions = &funcs;
    image.signatures = &sigs;
    image.types = &types;
    image.blocks = &.{};
    image.constants = &.{};
    image.destructure_dsts = &.{};
    image.destructure_dst_types = &.{};
    image.destructure_descs = &.{};
    image.module_slots = &.{};
    image.strings = &.{};
    image.self_symbol = llir.no_index; // anonymous single-function image
    image.init = llir.no_index;
    image.entry_member = llir.no_index;
    image.symbols = &.{};
    image.imports = &.{};
    image.exports = &.{};
    image.params = &.{};
    image.type_decls = &.{};
    image.type_decl_fields = &.{};
    image.union_variants = &.{};
    image.union_payloads = &.{};
    image.host_types = &.{};
    image.call_args = &.{};
    image.syscall_descs = &.{};
    image.construct_descs = &.{};
    image.switch_arms = &.{};
    image.switch_descs = &.{};
    image.member_descs = &.{};
    image.drop_descs = &.{};

    // The v9 interpreter runs the image directly — no derived stream.
    var vm = VmCtx{ .allocator = a, .loaded = .{ .meta_image = &image }, .runtime = .{ .heap = .{ .allocator = a } } };
    defer vm.deinit();
    try vm.setupRootArtifact(&image, 0);
    // T0 = -0.0, T1 = +0.0, T4 = NaN, T5 = 1.0
    vm_dispatch.write(&vm, llir.temp_base, 0x8000_0000_0000_0000);
    vm_dispatch.write(&vm, llir.temp_base + 1, 0);
    vm_dispatch.write(&vm, llir.temp_base + 4, @as(u64, @bitCast(std.math.nan(f64))));
    vm_dispatch.write(&vm, llir.temp_base + 5, @as(u64, @bitCast(@as(f64, 1.0))));
    // min(-0, +0) = -0 (writes cond)
    _ = try vm_dispatch.step(&vm);
    try testing.expectEqual(@as(Value, 0x8000_0000_0000_0000), vm_dispatch.read(&vm, llir.cond_reg));
    // max(-0, +0) = +0 (writes T2)
    _ = try vm_dispatch.step(&vm);
    try testing.expectEqual(@as(Value, 0), vm_dispatch.read(&vm, llir.temp_base + 2));
    // min(nan, 1) = nan (NaN propagates; writes T3)
    _ = try vm_dispatch.step(&vm);
    try testing.expect(std.math.isNan(@as(f64, @bitCast(vm_dispatch.read(&vm, llir.temp_base + 3)))));
}

test "32-bit ordering sign-extends low words through the shared compare path" {
    const neg_one_with_dirty_high = @as(Value, 0x1234_5678_ffff_ffff);
    const zero_with_dirty_high = @as(Value, 0xabcd_ef01_0000_0000);
    try std.testing.expect(vm_dispatch.ordCmp(true, .i32, neg_one_with_dirty_high, zero_with_dirty_high));
    // The signed comparison is true for the sign-extended cell; the
    // unsigned comparison of the same low word is false.
    const u32_less = vm_dispatch.ordCmp(true, .u32, neg_one_with_dirty_high, zero_with_dirty_high);
    try std.testing.expect(!u32_less);
}
