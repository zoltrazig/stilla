//! Test support for the `interpreter` black-box suite
//! (`src/interpreter_*_tests.zig`): the whole-pipeline load driver
//! (`Loaded`/`load`), the hand-built image runners (`runHand*`,
//! `primType`), and the `CaptureAdapter` used by the host-adapter tests.
//! No tests live here — each split file imports this module and aliases
//! the helpers locally so its test bodies are unchanged.
//!
//! Not wired into `src/root.zig` (it has no test blocks); the split files
//! import it by same-directory relative path, like their other module
//! imports.

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

/// Compile Stilla source through the whole pipeline and hand back a
/// structurally validated LLIR image (the public load path: validate,
/// then run the same image in place).
pub const Loaded = struct {
    compilation: frontend.Compilation,
    arena: std.heap.ArenaAllocator,
    /// Arena-stable image: the interpreter references it directly, so
    /// it outlives the load call.
    image: *llir.LlirProgram,
    /// Ordered FunctionId by trailing source name ("main", "add", …).
    fids: std.StringArrayHashMapUnmanaged(llir.FunctionId) = .empty,

    pub fn deinit(self: *Loaded) void {
        self.fids.deinit(testing.allocator);
        self.arena.deinit();
        self.compilation.deinit();
    }

    pub fn fid(self: *const Loaded, name: []const u8) !llir.FunctionId {
        return self.fids.get(name) orelse error.TestUnexpectedResult;
    }
};

pub fn load(text: []const u8, optimize: bool) !Loaded {
    var sources = moduleinfo.Sources{};
    var smap = std.StringHashMapUnmanaged([]const u8).empty;
    try smap.put(testing.allocator, "app", text);
    defer smap.deinit(testing.allocator);
    sources.source = smap;
    var compilation = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .optimize = optimize,
    });
    errdefer compilation.deinit();
    const program = &(compilation.program orelse {
        if (compilation.diag) |d| std.log.err("COMPILE DIAG: {s}", .{d.message});
        return error.TestUnexpectedResult;
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try arena.allocator().create(llir.LlirProgram);
    image.* = try b.lowerLlir();
    // The v9 pipeline: structural validation, then the interpreter runs
    // the same image in place — no derived stream (docs/interpreter-vm.md
    // §11).
    const reject = try llir_validate.validate(image, testing.allocator);
    if (reject) |m| {
        std.log.err("LOAD REJECT: {s}", .{m});
        testing.allocator.free(m);
        return error.TestUnexpectedResult;
    }
    // Record each source function's ordered FunctionId keyed by
    // its trailing name ("app.main" → "main").
    var fids = std.StringArrayHashMapUnmanaged(llir.FunctionId).empty;
    errdefer fids.deinit(testing.allocator);
    var it = b.func_ids.iterator();
    while (it.next()) |kv| {
        const full = kv.key_ptr.*.name.text;
        const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse 0;
        const short = if (dot < full.len - 1) full[dot + 1 ..] else full;
        try fids.put(testing.allocator, short, kv.value_ptr.*);
    }
    return .{
        .compilation = compilation,
        .arena = arena,
        .image = image,
        .fids = fids,
    };
}

/// A capturing print adapter shared by the M2 module tests: intercepts
/// `builtin.print` into a buffer, delegates everything else to the
/// default host (fd 1 is the build runner's `--listen` pipe, so stdout
/// sinks are probed as subprocesses, never in-process — build.zig).
pub const CaptureAdapter = struct {
    buffer: [2048]u8 = undefined,
    len: usize = 0,

    pub fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: u32, args: []const vm_types.Value) interpreter.HostResult {
        if (std.mem.eql(u8, member, "print") and args.len > 0) {
            const c: *CaptureAdapter = @ptrCast(@alignCast(@constCast(userdata.?)));
            const bytes = vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "print: not a str" };
            if (c.len + bytes.len + 1 > c.buffer.len) return .{ .panic = "capture buffer overflow" };
            @memcpy(c.buffer[c.len..][0..bytes.len], bytes);
            c.len += bytes.len;
            c.buffer[c.len] = '\n';
            c.len += 1;
            return .{ .value = 0 };
        }
        return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
    }
};

/// Run one hand-built single-function, single-block image through the
/// load pipeline (validate + run) to completion, returning the
/// root result. The image borrows `instrs`/`types`/`constants` (the
/// caller's frame) for the duration of the run. `ret_type` indexes
/// `types`.
pub fn runHand(instrs: []const llir.Instr, types: []const llir.TypeDesc, ret_type: u32, constants: []const llir.ConstRecord) !Value {
    return runHandBlocks(instrs, types, ret_type, constants, &.{.{
        .start_pc = 0,
        .end_pc = @intCast(instrs.len),
    }});
}

/// `runHand` over an explicit block layout — branch and `j` targets
/// must land on block starts (LLIR Specification §4.1).
pub fn runHandBlocks(instrs: []const llir.Instr, types: []const llir.TypeDesc, ret_type: u32, constants: []const llir.ConstRecord, blocks: []const llir.BlockDesc) !Value {
    return runHandImage(instrs, types, ret_type, constants, blocks, .{
        .code_start = 0,
        .code_end = @intCast(instrs.len),
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 8,
        .x_count = 0,
        .window_count = 0,
    });
}

/// `runHandBlocks` under a caller-supplied function descriptor — for
/// the O-alias tests, which need a nonzero window and X gap.
pub fn runHandImage(instrs: []const llir.Instr, types: []const llir.TypeDesc, ret_type: u32, constants: []const llir.ConstRecord, blocks: []const llir.BlockDesc, fn_desc: llir.FunctionDesc) !Value {
    var image: llir.LlirProgram = undefined;
    image.instructions = instrs;
    image.functions = &.{fn_desc};
    image.blocks = blocks;
    image.signatures = &.{.{ .params_start = 0, .params_len = 0, .ret = ret_type }};
    image.types = types;
    image.constants = constants;
    image.type_decls = &.{};
    image.type_decl_fields = &.{};
    image.union_variants = &.{};
    image.union_payloads = &.{};
    image.host_types = &.{};
    image.self_symbol = llir.no_index; // anonymous single-function module
    image.init = llir.no_index;
    image.entry_member = llir.no_index;
    image.symbols = &.{};
    image.imports = &.{};
    image.exports = &.{};
    image.module_slots = &.{};
    image.params = &.{};
    image.call_args = &.{};
    image.syscall_descs = &.{};
    image.construct_descs = &.{};
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
    var term = try interpreter.runWithEntry(testing.allocator, &image, 0, .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |r| return r,
        .panic => |m| {
            std.log.err("hand image panicked: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

pub fn primType(id: llir.PrimitiveId) llir.TypeDesc {
    return .{ .kind = .primitive, .a = @intFromEnum(id), .b = 0, .c = 0 };
}

/// Drain the root module's eager initializer: step until the requested
/// entry function (the caller recorded in the `.entry` continuation) is
/// the current frame, so a white-box test that mutates frame registers
/// or captures fp/sp lands in the entry function's frame. Root modules
/// initialize eagerly (Runtime §3.3); `setupRootArtifact`/`Symbolic`
/// leave the VM inside the initializer's frame.
pub fn drainRootInit(vm: *interpreter.VmCtx, entry: llir.FunctionId) !void {
    var steps: usize = 0;
    while (vm.runtime.current_fn != entry and !vm.runtime.terminated) {
        if (try vm_dispatch.step(vm)) |t| {
            switch (t) {
                .normal => return error.TestUnexpectedResult,
                .panic => |m| {
                    testing.allocator.free(m);
                    return error.TestUnexpectedResult;
                },
            }
        }
        try vm.drainDestroyWork();
        steps += 1;
        if (steps > 100_000) return error.TestUnexpectedResult;
    }
    if (vm.runtime.terminated) return error.TestUnexpectedResult;
}
