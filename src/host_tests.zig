//! Test file: `host` — the host environment contract (Runtime §3).

const std = @import("std");
const testing = std.testing;

const llir = @import("llir.zig");
const interpreter = @import("interpreter.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const vm_types = @import("vm_types.zig");
const llir_validate = @import("passes/llir_validate.zig");
const Value = vm_types.Value;

// ---------------------------------------------------------------------------
// Phase 6 — signature-driven host adapter (TODO.md 阶段 6)
// ---------------------------------------------------------------------------

test "host adapter: full-width 64-bit scalars reach the callback; owners transfer through the resource registry" {
    // A hand-built single-function image calls one `syscall` with an
    // (i64, u64, f64) signature. The custom adapter observes the raw
    // canonical cells (all 64 bits — a binary64 NaN payload and -0.0
    // pass unaltered), registers a host-owned payload in the VM's
    // resource registry, and returns a full-width result. No tag
    // namespace, no 48-bit adapter: the member name + signature are the
    // whole contract.
    const types = [_]llir.TypeDesc{
        .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.i64), .b = 0, .c = 0 },
        .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.u64), .b = 0, .c = 0 },
        .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.f64), .b = 0, .c = 0 },
    };
    const params = [_]llir.ParamDesc{
        .{ .mode = .plain, .type_ = 0 },
        .{ .mode = .plain, .type_ = 1 },
        .{ .mode = .plain, .type_ = 2 },
    };
    const signatures = [_]llir.SignatureDesc{
        .{ .params_start = 0, .params_len = 0, .ret = 1 }, // main
        .{ .params_start = 0, .params_len = 3, .ret = 1 }, // probe
    };
    const call_args = [_]llir.ValueReg{ llir.frame_base + 1, llir.frame_base + 2, llir.frame_base + 3 };
    const syscall_descs = [_]llir.SyscallDesc{.{ .host_binding_id = 0, .signature_id = 1, .args_start = 0, .args_len = 3 }};
    // Symbolic linkage: symbol 0 names the declaring module, symbol 1
    // the host member "probe" (bytes 0..5 of the strings blob).
    const symbols = [_]llir.SymRange{ .{ .start = 5, .len = 0 }, .{ .start = 0, .len = 5 } };
    const imports = [_]llir.ImportDesc{.{ .module_sym = 0, .member_sym = 1 }};
    const strings_blob = "probe"; // "probe" at [0,5); module symbol bytes at [5,5)
    const instructions = [_]llir.Instr{
        llir.instrI(.syscall, llir.frame_base + 4, 0),
        llir.instrE(.ret, llir.frame_base + 4, 0),
    };
    const functions = [_]llir.FunctionDesc{.{
        .code_start = 0,
        .code_end = 2,
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 8,
        .x_count = 0,
        .window_count = 3,
    }};
    const blocks = [_]llir.BlockDesc{.{ .start_pc = 0, .end_pc = 2 }};
    var image: llir.LlirProgram = undefined;
    image.instructions = &instructions;
    image.functions = &functions;
    image.blocks = &blocks;
    image.constants = &.{};
    image.types = &types;
    image.type_decls = &.{};
    image.type_decl_fields = &.{};
    image.union_variants = &.{};
    image.union_payloads = &.{};
    image.host_types = &.{};
    image.self_symbol = 0;
    image.init = llir.no_index;
    image.entry_member = llir.no_index;
    image.symbols = &symbols;
    image.imports = &imports;
    image.exports = &.{};
    image.module_slots = &.{};
    image.signatures = &signatures;
    image.params = &params;
    image.call_args = &call_args;
    image.syscall_descs = &syscall_descs;
    image.construct_descs = &.{};
    image.destructure_dsts = &.{};
    image.destructure_dst_types = &.{};
    image.destructure_descs = &.{};
    image.switch_arms = &.{};
    image.switch_descs = &.{};
    image.member_descs = &.{};
    image.drop_descs = &.{};
    image.strings = strings_blob;

    const State = struct {
        saw: [3]u64 = .{ 0, 0, 0 },
        disposed: usize = 0,
    };
    var state = State{};
    const Adapter = struct {
        fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: u32, args: []const vm_types.Value) interpreter.HostResult {
            _ = module_symbol;
            _ = sig;
            const st: *State = @ptrCast(@alignCast(@constCast(userdata.?)));
            if (!std.mem.eql(u8, member, "probe") or args.len != 3) return .{ .panic = "wrong binding" };
            st.saw = .{ args[0], args[1], args[2] };
            // The owner enters VM ownership by value; duplicates trap.
            vm.registerHostResource(0, 0x1234_5678_9abc_def0, disposer_fn, @constCast(userdata)) catch
                return .{ .panic = "duplicate registration" };
            return .{ .value = 0x8000_0000_0000_0001 };
        }
        fn disposer(user: ?*anyopaque, payload: u64) void {
            _ = payload;
            const st: *State = @ptrCast(@alignCast(user.?));
            st.disposed += 1;
        }
        const disposer_fn: interpreter.HostDisposer = disposer;
    };

    // The load pipeline: structural validation, then the interpreter
    // runs the same image directly — no derived stream (v9).
    const reject = (try llir_validate.validate(&image, testing.allocator)) orelse blk: {
        var vm = interpreter.VmCtx.init(testing.allocator);
        vm.host = .{ .userdata = &state, .invoke = Adapter.invoke };
        defer vm.deinit();
        try vm.setupRootArtifact(&image, 0);
        // i64 -1 (all bits), u64 high bit, f64 -0.0 — every cell bit matters.
        vm_dispatch.write(&vm, llir.frame_base + 1, 0xffff_ffff_ffff_ffff);
        vm_dispatch.write(&vm, llir.frame_base + 2, 0x8000_0000_0000_0000);
        vm_dispatch.write(&vm, llir.frame_base + 3, @as(u64, @bitCast(@as(f64, -0.0))));
        _ = try vm_dispatch.step(&vm); // syscall
        try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), state.saw[0]);
        try testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), state.saw[1]);
        try testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), state.saw[2]);
        // The owner is live in the registry mid-run, removable by the host.
        try testing.expect(vm.isHostResourceRegistered(0x1234_5678_9abc_def0));
        try testing.expect(vm.takeHostResource(0x1234_5678_9abc_def0) != null);
        try testing.expect(!vm.isHostResourceRegistered(0x1234_5678_9abc_def0));
        // A re-registration after the take succeeds (no duplicate).
        vm.registerHostResource(0, 0x1234_5678_9abc_def0, Adapter.disposer_fn, &state) catch
            return error.TestUnexpectedResult;
        const t = (try vm_dispatch.step(&vm)) orelse return error.TestUnexpectedResult; // ret → root
        try testing.expect(t == .normal);
        try testing.expectEqual(@as(Value, 0x8000_0000_0000_0001), t.normal);
        vm.finishCleanup();
        // finishCleanup disposes the registered owner exactly once.
        try testing.expectEqual(@as(usize, 1), state.disposed);
        break :blk null;
    };
    if (reject) |m| {
        std.log.err("LOAD REJECT: {s}", .{m});
        testing.allocator.free(m);
        return error.TestUnexpectedResult;
    }
}
