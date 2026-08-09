//! Host boundary and public running API for the Stilla interpreter VM
//! (docs/interpreter-vm.md §11): the `run` family, the default host
//! adapter (`builtin`/`math`/`string`/`list`/`array`/`hashmap`), and the
//! result/helper adapters. Loaded as a submodule of `interpreter`.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const host_module = @import("host.zig");
const validate = @import("passes/llir_validate.zig");
const interpreter = @import("interpreter.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const types = @import("interpreter_types.zig");
const loader_mod = @import("interpreter_loader.zig");
const VmCtx = interpreter.VmCtx;
const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;
const HeapErr = vm_types.HeapErr;
const Termination = types.Termination;
const RunError = types.RunError;
const HostResult = types.HostResult;
const ModuleLoader = loader_mod.ModuleLoader;
const HostDisposer = types.HostDisposer;

pub const HostCall = struct {
    userdata: ?*const anyopaque = null,

    /// Invoke one host binding. `module_symbol` is the canonical host
    /// module's symbol (hosts identify their modules by symbol, the
    /// same identity resolution dispatches by — Runtime §2.6).
    /// `member` is the binding's member symbol; `sig` is the
    /// specialized signature (parameter types/modes + return type,
    /// readable through the executing module's artifact via `vm`);
    /// `args` holds one canonical cell per parameter, in order.
    invoke: *const fn (vm: *VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: llir.SignatureId, args: []const Value) HostResult = defaultHostCall,
};

// ---------------------------------------------------------------------------
// Public loading + running (docs/interpreter-vm.md §11)
// ---------------------------------------------------------------------------

/// The shared run path: construct the VM, set up the root (symbolic
/// entry, or an explicit module-local `FunctionId` when `entry` is
/// non-null), and run the loop. `loader` is borrowed for the run.
fn runSetup(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
    entry: ?llir.FunctionId,
    host: HostCall,
    loader: ModuleLoader,
) RunError!Termination {
    var vm = VmCtx{ .allocator = allocator, .host = host, .provider = loader, .heap = .{ .allocator = allocator } };
    defer vm.deinit();
    if (entry) |e| try vm.setupRootArtifact(image, e) else try vm.setupRootSymbolic(image);
    return runLoop(&vm);
}

/// Run one validated image's symbolic entry (Runtime §3.3): the
/// entry export recorded in the artifact resolves through the module's
/// export table; the returned panic message (if any) is owned — free
/// it with `allocator`.
pub fn run(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
) RunError!Termination {
    return runWithHost(allocator, image, .{});
}

/// `run` with an explicit host adapter (phase 6): the default adapter
/// implements the required `builtin` interface; an embedding replaces it
/// to provide its own host modules.
pub fn runWithHost(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
    host: HostCall,
) RunError!Termination {
    return runSetup(allocator, image, null, host, .{});
}

/// Run a borrowed artifact from an explicit module-local entry
/// `FunctionId` (the single-artifact convenience for tests and
/// embedders that build images programmatically).
pub fn runWithEntry(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
    entry: llir.FunctionId,
    host: HostCall,
) RunError!Termination {
    return runSetup(allocator, image, entry, host, .{});
}

/// `runWithEntry` with a `ModuleLoader`: cross-module references resolve
/// through `loader` (a whole-program artifact bundle or an embedding's
/// provider) instead of the no-op default. `loader` is borrowed for the
/// duration of the run.
pub fn runWithEntryAndLoader(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
    entry: llir.FunctionId,
    host: HostCall,
    loader: ModuleLoader,
) RunError!Termination {
    return runSetup(allocator, image, entry, host, loader);
}

/// `runWithHost` (the symbolic root path) with a `ModuleLoader`.
pub fn runWithHostAndLoader(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
    host: HostCall,
    loader: ModuleLoader,
) RunError!Termination {
    return runSetup(allocator, image, null, host, loader);
}

/// The shared execution loop: step until a termination, then — for a
/// normal root return — tear the module tree down in reverse
/// initialization order before finishing cleanup.
pub fn runLoop(self: *VmCtx) RunError!Termination {
    while (!self.core.terminated) {
        // Run mode dispatches a whole instruction segment per iteration
        // (the tail chain runs until a termination, an error, or a
        // drop-hook continuation resumes — no per-instruction
        // call/return back into this loop).
        self.core.result = null;
        self.core.pending_err = null;
        self.core.popped_hook_cont = false;
        vm_dispatch.dispatch(self, std.math.maxInt(u32));
        if (self.core.pending_err) |e| return e;
        if (self.core.result) |t| {
            if (t == .normal) {
                self.core.terminated = false;
                try self.teardownModules();
                while (self.hookActive()) {
                    if (try vm_dispatch.step(self)) |tt| {
                        self.finishCleanup();
                        return tt;
                    }
                    try self.drainDestroyWork();
                }
                self.core.terminated = true;
            }
            self.finishCleanup();
            return t;
        }
        // The chain stopped without a termination: destruction work
        // (releases, drop-hook continuations) drains between dispatch
        // segments; a running hook pauses it until its frame returns.
        try self.drainDestroyWork();
    }
    self.finishCleanup();
    return Termination{ .normal = 0 };
}

/// Convenience over `run`: structurally validate the artifact, then
/// run it — `validate(image)` runs first and the interpreter runs the
/// identical image.
pub fn runValidated(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
) RunError!Termination {
    return runValidatedWithEntry(allocator, image, null, .{});
}

/// `runValidated` from an optional explicit module-local entry
/// `FunctionId` (null = the symbolic root entry), with an explicit host
/// adapter.
pub fn runValidatedWithEntry(
    allocator: std.mem.Allocator,
    image: *llir.LlirProgram,
    entry: ?llir.FunctionId,
    host: HostCall,
) RunError!Termination {
    const msg = (try validate.validate(image, allocator)) orelse {
        return runSetup(allocator, image, entry, host, .{});
    };
    allocator.free(msg);
    return error.InvalidImage;
}

/// The default host adapter: resolves the declaring module's specifier
/// through the image, then dispatches the `(specifier, member)` pair to
/// the per-module adapter (`builtin`/`math`/`string`/`list`; D2). Each
/// adapter verifies the signature and argument cells, performs the VM
/// heap mechanics (str/list/union allocation, list walks, box/unbox
/// object layout), and dispatches the verified call to the standalone
/// handler structs in `host_module` (`DefaultHostCall`/
/// `MathHostCall`/`StringHostCall`/`ListHostCall`), which never see the
/// VM; the `array`/`hashmap` opaque objects (M3) build their storage in
/// `host_module` and the adapters own the retain/release and
/// exactly-once disposal contract. A module or member without a handler
/// reports `not_implemented`; hosts that provide their own modules
/// install a custom `HostCall`.
pub fn defaultHostCall(vm: *VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: llir.SignatureId, args: []const Value) HostResult {
    const image = vm.curImage();
    if (sig >= image.signatures.len) return .{ .panic = "syscall: signature out of range" };
    // Same member names in different modules dispatch to different
    // handler tables: identity is the (module symbol, member) pair (D2).
    if (std.mem.eql(u8, module_symbol, "builtin")) return hostBuiltin(vm, userdata, member, sig, args);
    if (std.mem.eql(u8, module_symbol, "math")) return hostMath(userdata, member, args);
    if (std.mem.eql(u8, module_symbol, "string")) return hostString(vm, userdata, member, sig, args);
    if (std.mem.eql(u8, module_symbol, "list")) return hostList(vm, userdata, member, sig, args);
    if (std.mem.eql(u8, module_symbol, "array")) return hostArray(vm, userdata, member, sig, args);
    if (std.mem.eql(u8, module_symbol, "hashmap")) return hostHashMap(vm, userdata, member, sig, args);
    return .{ .not_implemented = {} };
}

/// The `builtin` module adapter (Runtime §4): re-keyed from the
/// pre-M2 member-only dispatch, unchanged in behavior — the adapter
/// verifies each call and performs the VM heap mechanics, then
/// dispatches the verified call to `host_module.defaultHostCall`.
fn hostBuiltin(self: *VmCtx, userdata: ?*const anyopaque, member: []const u8, sig: llir.SignatureId, args: []const Value) HostResult {
    const image = self.curImage();
    const s = image.signatures[sig];
    const host = host_module.defaultHostCall;
    if (std.mem.eql(u8, member, "print")) {
        if (args.len < 1) return .{ .panic = "builtin.print: expected 1 argument" };
        host.print(userdata, self.heap.strSliceOf(args[0]) orelse return .{ .panic = "builtin.print: not a str" });
        return .{ .value = 0 };
    }
    if (std.mem.eql(u8, member, "str")) {
        if (args.len < 1 or s.params_len < 1) return .{ .panic = "builtin.str: expected 1 argument" };
        const params = image.params[s.params_start..][0..s.params_len];
        const pt = image.types[params[0].type_];
        const pid: llir.PrimitiveId = if (pt.kind == .primitive) @enumFromInt(pt.a) else .hostdata;
        if (pid == .hostdata) return .{ .panic = "builtin.str: unsupported value" };
        const view = vm_types.decodeScalar(&self.heap, pid, args[0]) catch return .{ .panic = "builtin.str: unsupported value" };
        var buf: [64]u8 = undefined;
        const text = host.str(userdata, view, &buf) catch return .{ .panic = "builtin.str: unsupported value" };
        const cell = self.heap.newStr(s.ret, text) catch return .{ .panic = "builtin.str: out of memory" };
        return .{ .value = cell };
    }
    if (std.mem.eql(u8, member, "box")) {
        if (args.len < 1) return .{ .panic = "builtin.box: expected 1 argument" };
        const h = self.heap.allocObject(.box_, s.ret, 1, 0) catch return .{ .panic = "builtin.box: out of memory" };
        h.setCell(0, host.box(userdata, args[0]));
        return .{ .value = @intFromPtr(h) };
    }
    if (std.mem.eql(u8, member, "unbox")) {
        if (args.len < 1) return .{ .panic = "builtin.unbox: expected 1 argument" };
        const h = self.heap.deref(args[0]) catch return .{ .panic = "builtin.unbox: not a box" };
        if (h.kind != .box_) return .{ .panic = "builtin.unbox: not a box" };
        const payload = h.cell(0);
        // The shell dies only on a consuming `unbox(move b)` (Runtime
        // §4.5): a *Copy*-payload box is itself Copy, so `unbox(b)`
        // reads the payload and leaves the box usable — freeing the
        // shell here would leave the caller's box value dangling and
        // the second read would deref freed memory. The mode rides on
        // the specialized signature's first parameter.
        if (image.params[s.params_start].mode == .move) {
            h.setCell(0, 0);
            self.heap.freeShell(h);
        }
        return .{ .value = host.unbox(userdata, payload) };
    }
    if (std.mem.eql(u8, member, "panic")) {
        if (args.len < 1) return .{ .panic = "builtin.panic: expected 1 argument" };
        const msg = self.heap.strSliceOf(args[0]) orelse return .{ .panic = "builtin.panic: not a str" };
        return .{ .panic = host.panic(userdata, msg) };
    }
    if (std.mem.eql(u8, member, "assert")) {
        if (args.len < 2) return .{ .panic = "builtin.assert: expected 2 arguments" };
        if (args[0] == 0) {
            const msg = self.heap.strSliceOf(args[1]) orelse return .{ .panic = "builtin.assert: message not a str" };
            return .{ .panic = host.assert(userdata, msg) };
        }
        return .{ .value = 0 };
    }
    if (std.mem.eql(u8, member, "hash")) {
        if (args.len < 1) return .{ .panic = "builtin.hash: expected 1 argument" };
        const params = image.params[s.params_start..][0..s.params_len];
        const str_bytes = if (params.len != 0 and image.types[params[0].type_].kind == .primitive and image.types[params[0].type_].a == @intFromEnum(llir.PrimitiveId.str)) self.heap.strSliceOf(args[0]) orelse return .{ .panic = "builtin.hash: not a str" } else null;
        var scalar = args[0];
        return .{ .value = host.hash(userdata, str_bytes orelse std.mem.asBytes(&scalar)) };
    }
    return .{ .not_implemented = {} };
}

/// The `math` module adapter (StdLib §4): decode the canonical f32
/// cells, dispatch the `(member, args)` pair to `MathHostCall`, encode
/// the f32 result. `hostdata` rejection stays in the `builtin` adapter.
fn hostMath(userdata: ?*const anyopaque, member: []const u8, args: []const Value) HostResult {
    const m = std.meta.stringToEnum(host_module.MathMember, member) orelse return .{ .not_implemented = {} };
    if (args.len < 1 or args.len > 2) return .{ .panic = "math: wrong argument count" };
    const x = ValueCodec.decodeFloat32(args[0]) orelse return .{ .panic = "math: non-canonical float32 argument" };
    const y: f32 = if (args.len == 2) ValueCodec.decodeFloat32(args[1]) orelse return .{ .panic = "math: non-canonical float32 argument" } else 0;
    const h = host_module.mathHostCall;
    const r: f32 = switch (m) {
        .sqrt => h.sqrt(userdata, x),
        .pow => h.pow(userdata, x, y),
        .exp => h.exp(userdata, x),
        .ln => h.ln(userdata, x),
        .log2 => h.log2(userdata, x),
        .log10 => h.log10(userdata, x),
        .sin => h.sin(userdata, x),
        .cos => h.cos(userdata, x),
        .tan => h.tan(userdata, x),
        .asin => h.asin(userdata, x),
        .acos => h.acos(userdata, x),
        .atan => h.atan(userdata, x),
        .atan2 => h.atan2(userdata, y, x), // y first, matching IEEE 754
        .floor => h.floor(userdata, x),
        .ceil => h.ceil(userdata, x),
        .round => h.round(userdata, x),
        .trunc => h.trunc(userdata, x),
        .abs => h.abs(userdata, x),
        .min => h.min(userdata, x, y),
        .max => h.max(userdata, x, y),
    };
    return .{ .value = ValueCodec.encodeFloat32(r) };
}

/// The `string` module adapter (StdLib §5): decode the canonical
/// argument cells, walk list arguments, run the verified handler,
/// allocate the result str/list/union objects, and map handler errors
/// to owned deterministic trap messages. All text processing operates
/// on code points (StdLib §5); byte offsets are never exposed.
fn hostString(self: *VmCtx, userdata: ?*const anyopaque, member: []const u8, sig: llir.SignatureId, args: []const Value) HostResult {
    const m = std.meta.stringToEnum(host_module.StringMember, member) orelse return .{ .not_implemented = {} };
    const s = self.curImage().signatures[sig];
    const h = host_module.stringHostCall;
    switch (m) {
        .len => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.len: expected a str argument" };
            const n = h.len(userdata, a) catch |e| return stringErr(self, e, member);
            return .{ .value = ValueCodec.encodeInt32(n) };
        },
        .is_empty => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.is_empty: expected a str argument" };
            return .{ .value = ValueCodec.encodeBool(h.is_empty(userdata, a)) };
        },
        .concat => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.concat: expected 2 str arguments" };
            const b = strArg(self, args, 1) orelse return .{ .panic = "string.concat: expected 2 str arguments" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.concat(userdata, a, b, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .contains => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.contains: expected 2 str arguments" };
            const b = strArg(self, args, 1) orelse return .{ .panic = "string.contains: expected 2 str arguments" };
            return .{ .value = ValueCodec.encodeBool(h.contains(userdata, a, b)) };
        },
        .starts_with => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.starts_with: expected 2 str arguments" };
            const b = strArg(self, args, 1) orelse return .{ .panic = "string.starts_with: expected 2 str arguments" };
            return .{ .value = ValueCodec.encodeBool(h.starts_with(userdata, a, b)) };
        },
        .ends_with => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.ends_with: expected 2 str arguments" };
            const b = strArg(self, args, 1) orelse return .{ .panic = "string.ends_with: expected 2 str arguments" };
            return .{ .value = ValueCodec.encodeBool(h.ends_with(userdata, a, b)) };
        },
        .index_of => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.index_of: expected 2 str arguments" };
            const b = strArg(self, args, 1) orelse return .{ .panic = "string.index_of: expected 2 str arguments" };
            const found = h.index_of(userdata, a, b) catch |e| return stringErr(self, e, member);
            const cell = if (found) |idx|
                optionCell(self, s.ret, true, ValueCodec.encodeInt32(idx)) catch return oomPanic(
                    self,
                )
            else
                optionCell(self, s.ret, false, 0) catch return oomPanic(
                    self,
                );
            return .{ .value = cell };
        },
        .substring => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.substring: expected a str argument" };
            const start = intArg(self, args, 1) orelse return .{ .panic = "string.substring: expected int32 offsets" };
            const end = intArg(self, args, 2) orelse return .{ .panic = "string.substring: expected int32 offsets" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.substring(userdata, a, start, end, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .split => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.split: expected 2 str arguments" };
            const sep = strArg(self, args, 1) orelse return .{ .panic = "string.split: expected 2 str arguments" };
            var pieces = std.array_list.Managed([]const u8).init(self.allocator);
            defer pieces.deinit();
            h.split(userdata, a, sep, &pieces) catch |e| return stringErr(self, e, member);
            // Copy each piece (a slice into the input str) into a fresh
            // str object; the list chain owns them (no retain).
            const elem_ty = self.curImage().types[s.ret].a;
            var cells = std.ArrayList(Value).empty;
            defer cells.deinit(self.allocator);
            for (pieces.items) |p| {
                const c = self.heap.newStr(elem_ty, p) catch return oomPanic(
                    self,
                );
                cells.append(self.allocator, c) catch return oomPanic(
                    self,
                );
            }
            const cell = newListCells(self, s.ret, cells.items) catch return oomPanic(
                self,
            );
            return .{ .value = cell };
        },
        .join => {
            if (args.len < 2) return .{ .panic = "string.join: expected 2 arguments" };
            const sep = strArg(self, args, 1) orelse return .{ .panic = "string.join: separator not a str" };
            var elems = std.ArrayList(Value).empty;
            defer elems.deinit(self.allocator);
            walkList(self, args[0], &elems) catch return .{ .panic = "string.join: not a list" };
            var parts = std.ArrayList([]const u8).empty;
            defer parts.deinit(self.allocator);
            for (elems.items) |c| {
                parts.append(self.allocator, self.heap.strSliceOf(c) orelse return .{ .panic = "string.join: element not a str" }) catch return oomPanic(
                    self,
                );
            }
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.join(userdata, parts.items, sep, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .trim => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.trim: expected a str argument" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.trim(userdata, a, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .lower => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.lower: expected a str argument" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.lower(userdata, a, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .upper => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.upper: expected a str argument" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.upper(userdata, a, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .replace => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.replace: expected 3 str arguments" };
            const from = strArg(self, args, 1) orelse return .{ .panic = "string.replace: expected 3 str arguments" };
            const to = strArg(self, args, 2) orelse return .{ .panic = "string.replace: expected 3 str arguments" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.replace(userdata, a, from, to, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .repeat => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.repeat: expected a str argument" };
            const count = intArg(self, args, 1) orelse return .{ .panic = "string.repeat: expected an int32 count" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.repeat(userdata, a, count, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .to_utf8 => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.to_utf8: expected a str argument" };
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.to_utf8(userdata, a, &out) catch |e| return stringErr(self, e, member);
            var cells = std.ArrayList(Value).empty;
            defer cells.deinit(self.allocator);
            for (out.items) |b| cells.append(self.allocator, @as(Value, b)) catch return oomPanic(
                self,
            );
            const cell = newListCells(self, s.ret, cells.items) catch return oomPanic(
                self,
            );
            return .{ .value = cell };
        },
        .from_utf8 => {
            if (args.len < 1) return .{ .panic = "string.from_utf8: expected 1 argument" };
            var elems = std.ArrayList(Value).empty;
            defer elems.deinit(self.allocator);
            walkList(self, args[0], &elems) catch return .{ .panic = "string.from_utf8: not a list" };
            var bytes = std.ArrayList(u8).empty;
            defer bytes.deinit(self.allocator);
            for (elems.items) |c| bytes.append(self.allocator, @truncate(c)) catch return oomPanic(
                self,
            );
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.from_utf8(userdata, bytes.items, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
        .to_codepoints => {
            const a = strArg(self, args, 0) orelse return .{ .panic = "string.to_codepoints: expected a str argument" };
            var out = std.array_list.Managed(u32).init(self.allocator);
            defer out.deinit();
            h.to_codepoints(userdata, a, &out) catch |e| return stringErr(self, e, member);
            var cells = std.ArrayList(Value).empty;
            defer cells.deinit(self.allocator);
            for (out.items) |cp| cells.append(self.allocator, ValueCodec.encodeUint32(cp)) catch return oomPanic(
                self,
            );
            const cell = newListCells(self, s.ret, cells.items) catch return oomPanic(
                self,
            );
            return .{ .value = cell };
        },
        .from_codepoints => {
            if (args.len < 1) return .{ .panic = "string.from_codepoints: expected 1 argument" };
            var elems = std.ArrayList(Value).empty;
            defer elems.deinit(self.allocator);
            walkList(self, args[0], &elems) catch return .{ .panic = "string.from_codepoints: not a list" };
            var cps = std.ArrayList(u32).empty;
            defer cps.deinit(self.allocator);
            for (elems.items) |c| cps.append(self.allocator, ValueCodec.decodeUint32(c) orelse return .{ .panic = "string.from_codepoints: element not a uint32" }) catch return oomPanic(
                self,
            );
            var out = std.array_list.Managed(u8).init(self.allocator);
            defer out.deinit();
            h.from_codepoints(userdata, cps.items, &out) catch |e| return stringErr(self, e, member);
            return newStrCell(self, s.ret, out.items);
        },
    }
}

/// The `list` module adapter (Runtime §4.3–§4.4): `len` reads the head
/// cons node's stored suffix length (O(1)); `range` generates the
/// inclusive integer range through the handler and materializes the
/// `list[int32]` cons chain.
fn hostList(self: *VmCtx, userdata: ?*const anyopaque, member: []const u8, sig: llir.SignatureId, args: []const Value) HostResult {
    const h = host_module.listHostCall;
    if (std.mem.eql(u8, member, "len")) {
        if (args.len < 1) return .{ .panic = "list.len: expected 1 argument" };

        var count: i32 = 0;
        if (args[0] != 0) {
            const head = self.heap.deref(args[0]) catch {
                return .{ .panic = "list.len: not a list" };
            };
            if (head.kind != .list_cons) {
                return .{ .panic = "list.len: not a list" };
            }
            count = @intCast(head.len);
        }
        return .{ .value = ValueCodec.encodeInt32(h.len(userdata, count)) };
    }
    if (std.mem.eql(u8, member, "range")) {
        const start = intArg(self, args, 0) orelse return .{ .panic = "list.range: expected 2 int32 arguments" };
        const end = intArg(self, args, 1) orelse return .{ .panic = "list.range: expected 2 int32 arguments" };
        var vals = std.array_list.Managed(i32).init(self.allocator);
        defer vals.deinit();
        h.range(userdata, start, end, &vals) catch return oomPanic(
            self,
        );
        var cells = std.ArrayList(Value).empty;
        defer cells.deinit(self.allocator);
        for (vals.items) |v| cells.append(self.allocator, ValueCodec.encodeInt32(v)) catch return oomPanic(
            self,
        );
        const cell = newListCells(self, self.curImage().signatures[sig].ret, cells.items) catch return oomPanic(
            self,
        );
        return .{ .value = cell };
    }
    return .{ .not_implemented = {} };
}

// --- adapter helpers (M2): decode canonical cells, walk lists, and
// --- allocate VM objects for the per-module adapters above -----------

/// One str argument decoded from the canonical cells; null when absent
/// or not a live str object.
fn strArg(self: *VmCtx, args: []const Value, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    return self.heap.strSliceOf(args[i]);
}

/// One canonical int32 argument; null when absent or non-canonical.
fn intArg(self: *VmCtx, args: []const Value, i: usize) ?i32 {
    _ = self;
    if (i >= args.len) return null;
    return ValueCodec.decodeInt32(args[i]);
}

/// Owned panic message for an adapter-side allocation failure (reachable
/// trap paths, e.g. a huge `list.range` — never a static string).
fn oomPanic(self: *VmCtx) HostResult {
    _ = self;
    return .{ .panic = "out of memory" };
}

/// Map a string-handler error to an owned deterministic trap message
/// (StdLib §5, Runtime §7.2).
fn stringErr(self: *VmCtx, e: host_module.StringErr, member: []const u8) HostResult {
    const msg = switch (e) {
        error.InvalidUtf8 => "invalid UTF-8",
        error.Range => "index out of range",
        error.BadCodepoint => "not a Unicode scalar value",
        error.OutOfMemory => return oomPanic(
            self,
        ),
    };
    const slice = std.fmt.bufPrint(&self.panic_buf, "string.{s}: {s}", .{ member, msg }) catch return oomPanic(
        self,
    );
    return .{ .panic = slice };
}

/// Allocate a str object holding `bytes`; OOM is a panic.
fn newStrCell(self: *VmCtx, ty: u32, bytes: []const u8) HostResult {
    const cell = self.heap.newStr(ty, bytes) catch return oomPanic(
        self,
    );
    return .{ .value = cell };
}

/// Build a list cons chain from element cells, right to left, with each
/// node's suffix length recorded (the head's `len` is the element
/// count — the O(1) read `list#len` and `read_index` rely on). The
/// element cells are NOT retained: they are freshly-owned objects or
/// scalars the chain takes over.
fn newListCells(self: *VmCtx, ty: u32, elems: []const Value) HeapErr!Value {
    var next: Value = 0;
    var suffix_len: u32 = 0;
    var k = elems.len;
    while (k > 0) {
        k -= 1;
        const h = try self.heap.allocObjectIn(.list_cons, self.curModIdx(), ty, 2, 0);
        h.setCell(0, elems[k]);
        h.setCell(1, next);
        h.len = suffix_len + 1;
        suffix_len += 1;
        next = @intFromPtr(h);
    }
    return next;
}

/// The builtin `Option[T]` union in the image's union layout: `Some` is
/// variant tag 0 with the payload in cell 1, `None` variant tag 1
/// (std/builtin.st declaration order; `read_tag`/`read_payload` and the
/// destruction walker read the same cells).
fn optionCell(self: *VmCtx, ty: u32, some: bool, payload: Value) HeapErr!Value {
    const h = try self.heap.allocObject(.union_, ty, 1 + @as(usize, @intFromBool(some)), 0);
    h.setCell(0, if (some) 0 else 1);
    if (some) h.setCell(1, payload);
    return @intFromPtr(h);
}

/// Walk a list cons chain, appending each element cell to `out`. The
/// element cells are not retained — callers convert them into fresh
/// scalar cells or copy the referenced objects immediately.
fn walkList(self: *VmCtx, cell: Value, out: *std.ArrayList(Value)) HeapErr!void {
    var cur = cell;
    while (cur != 0) {
        const node = try self.heap.deref(cur);
        if (node.kind != .list_cons) return error.TypeMismatch;
        try out.append(self.allocator, node.cell(0));
        cur = node.cell(1);
    }
}

// ---------------------------------------------------------------------------
// The `array` and `hashmap` adapters (StdLib §2, §3) — M3. Each opaque
// value is a heap shell (`allocObject(.opaque_, ...)`) whose payload
// cell 0 holds the host object pointer; the shell is registered in
// `host_resources` (keyed by its address) so `drop` and panic teardown
// run the module disposer exactly once. The adapters own the heap
// mechanics: elements are retained on store, displaced cells are
// released on overwrite, `get` retains the returned copy, `remove`
// transfers the value into the result `Option`, and disposal releases
// every stored cell. Release goes through `releaseCellIfCounted` —
// non-counted Copy shells (e.g. `Option[int32]` elements) and scalars
// must not reach `releaseCounted` (which traps on them).
// ---------------------------------------------------------------------------

/// The `array` module adapter (StdLib §2).
fn hostArray(self: *VmCtx, userdata: ?*const anyopaque, member: []const u8, sig: llir.SignatureId, args: []const Value) HostResult {
    _ = userdata;
    const m = std.meta.stringToEnum(host_module.ArrayMember, member) orelse return .{ .not_implemented = {} };
    const s = self.curImage().signatures[sig];
    switch (m) {
        .make => {
            if (args.len < 2) return .{ .panic = "array.make: expected 2 arguments" };
            const n = intArg(self, args, 0) orelse return .{ .panic = "array.make: expected an int32 length" };
            if (n < 0) return panicFmt(self, "array.make: negative length ({d})", .{n});
            const obj = host_module.ArrayObject.make(self.allocator, n, args[1]) catch return oomPanic(self);
            // Copy semantics: `make(2, s)` holds one reference per slot.
            var i: usize = 0;
            while (i < obj.cells.len) : (i += 1) {
                vm_dispatch.retainCell(self, obj.cells[i]) catch {
                    obj.deinit();
                    return oomPanic(self);
                };
            }
            return wrapOpaque(self, s.ret, obj, arrayDisposer);
        },
        .len => {
            if (args.len < 1) return .{ .panic = "array.len: expected 1 argument" };
            const obj = arrayPayload(self, args[0]) orelse return panicFmt(self, "{s}: not an array", .{member});
            return .{ .value = ValueCodec.encodeInt32(@intCast(obj.len)) };
        },
        .get => {
            if (args.len < 2) return .{ .panic = "array.get: expected 2 arguments" };
            const obj = arrayPayload(self, args[0]) orelse return panicFmt(self, "{s}: not an array", .{member});
            const idx = intArg(self, args, 1) orelse return .{ .panic = "array.get: expected an int32 index" };
            const v = obj.get(idx) catch return panicFmt(
                self,
                "array.get: index {d} out of range (len {d})",
                .{ idx, obj.len },
            );
            // The returned element is a copy: establish the new owner.
            vm_dispatch.retainCell(self, v) catch return oomPanic(self);
            return .{ .value = v };
        },
        .set => {
            if (args.len < 3) return .{ .panic = "array.set: expected 3 arguments" };
            const obj = arrayPayload(self, args[0]) orelse return panicFmt(self, "{s}: not an array", .{member});
            const idx = intArg(self, args, 1) orelse return .{ .panic = "array.set: expected an int32 index" };
            if (idx < 0 or idx >= obj.len) return panicFmt(
                self,
                "array.set: index {d} out of range (len {d})",
                .{ idx, obj.len },
            );
            vm_dispatch.retainCell(self, args[2]) catch return oomPanic(self);
            const old = obj.set(idx, args[2]) catch return oomPanic(self);
            // Unreachable: `releaseCellIfCounted` checked registry + counted.
            releaseCellIfCounted(self, old) catch {};
            // In-place mutation (StdLib §2): the same shell moves on.
            return .{ .value = args[0] };
        },
        .clone => {
            if (args.len < 1) return .{ .panic = "array.clone: expected 1 argument" };
            const obj = arrayPayload(self, args[0]) orelse return panicFmt(self, "{s}: not an array", .{member});
            const copy = obj.clone() catch return oomPanic(self);
            for (copy.cells) |c| {
                vm_dispatch.retainCell(self, c) catch {
                    copy.deinit();
                    return oomPanic(self);
                };
            }
            return wrapOpaque(self, s.ret, copy, arrayDisposer);
        },
    }
}

/// The `hashmap` module adapter (StdLib §3). Key hashing/equality
/// mirror `builtin.hash` (Wyhash, seed 0) and `==` (str content
/// equality), so identical-content str keys hit one entry. Note: like
/// `builtin.hash`, float keys hash their raw cell, so `-0.0` and `+0.0`
/// are distinct keys despite comparing equal.
fn hostHashMap(self: *VmCtx, userdata: ?*const anyopaque, member: []const u8, sig: llir.SignatureId, args: []const Value) HostResult {
    _ = userdata;
    const m = std.meta.stringToEnum(host_module.HashMapMember, member) orelse return .{ .not_implemented = {} };
    const s = self.curImage().signatures[sig];
    switch (m) {
        .empty => {
            if (!checkHashableKey(self, s.ret)) return panicFmt(self, "{s}: unsupported key type", .{member});
            const obj = host_module.HashMapObject.empty(self.allocator, self, hashmapKeyHash, hashmapKeyEq) catch return oomPanic(self);
            return wrapOpaque(self, s.ret, obj, hashmapDisposer);
        },
        .insert => {
            if (args.len < 3) return .{ .panic = "hashmap.insert: expected 3 arguments" };
            if (!checkHashableKey(self, s.ret)) return panicFmt(self, "{s}: unsupported key type", .{member});
            const obj = mapPayload(self, args[0]) orelse return panicFmt(self, "{s}: not a hashmap", .{member});
            vm_dispatch.retainCell(self, args[1]) catch return oomPanic(self); // the map owns a key reference
            vm_dispatch.retainCell(self, args[2]) catch return oomPanic(self); // and a value reference
            const old = obj.insert(args[1], args[2]) catch return oomPanic(self);
            if (old) |d| {
                releaseCellIfCounted(self, d.key) catch {};
                releaseCellIfCounted(self, d.val) catch {};
            }
            // In-place mutation (StdLib §3): the same shell moves on.
            return .{ .value = args[0] };
        },
        .get => {
            if (args.len < 2) return .{ .panic = "hashmap.get: expected 2 arguments" };
            if (!checkHashableKey(self, self.curImage().params[s.params_start].type_)) return panicFmt(self, "{s}: unsupported key type", .{member});
            const obj = mapPayload(self, args[0]) orelse return panicFmt(self, "{s}: not a hashmap", .{member});
            const shell = if (obj.get(args[1])) |v| blk: {
                // The returned value is a copy: establish the new owner.
                vm_dispatch.retainCell(self, v) catch return oomPanic(self);
                break :blk optionCell(self, s.ret, true, v) catch return oomPanic(self);
            } else optionCell(self, s.ret, false, 0) catch return oomPanic(self);
            return .{ .value = shell };
        },
        .contains => {
            if (args.len < 2) return .{ .panic = "hashmap.contains: expected 2 arguments" };
            if (!checkHashableKey(self, self.curImage().params[s.params_start].type_)) return panicFmt(self, "{s}: unsupported key type", .{member});
            const obj = mapPayload(self, args[0]) orelse return panicFmt(self, "{s}: not a hashmap", .{member});
            return .{ .value = ValueCodec.encodeBool(obj.contains(args[1])) };
        },
        .remove => {
            if (args.len < 2) return .{ .panic = "hashmap.remove: expected 2 arguments" };
            const row = self.curImage().types[s.ret];
            if (row.kind != .tuple) return .{ .panic = "hashmap.remove: unexpected result type" };
            const map_ty = row.a; // tuple[HashMap[K, V], Option[V]]: element 0
            if (!checkHashableKey(self, map_ty)) return panicFmt(self, "{s}: unsupported key type", .{member});
            const obj = mapPayload(self, args[0]) orelse return panicFmt(self, "{s}: not a hashmap", .{member});
            const opt_ty = row.a + 1;
            const option = if (obj.remove(args[1])) |e| blk: {
                // The map drops its key reference; the value transfers
                // into the Option (the map's reference moves).
                releaseCellIfCounted(self, e.key) catch {};
                break :blk optionCell(self, opt_ty, true, e.val) catch return oomPanic(self);
            } else optionCell(self, opt_ty, false, 0) catch return oomPanic(self);
            const tuple = self.heap.allocObject(.tuple_, s.ret, 2, 0) catch return oomPanic(self);
            // No retains: the moved map shell and the fresh union shell
            // are unique (matching the non-retaining tuple convention).
            tuple.setCell(0, args[0]);
            tuple.setCell(1, option);
            return .{ .value = @intFromPtr(tuple) };
        },
        .len => {
            if (args.len < 1) return .{ .panic = "hashmap.len: expected 1 argument" };
            if (!checkHashableKey(self, self.metaImage().params[s.params_start].type_)) return panicFmt(self, "{s}: unsupported key type", .{member});
            const obj = mapPayload(self, args[0]) orelse return panicFmt(self, "{s}: not a hashmap", .{member});
            return .{ .value = ValueCodec.encodeInt32(obj.len()) };
        },
        .clone => {
            if (args.len < 1) return .{ .panic = "hashmap.clone: expected 1 argument" };
            if (!checkHashableKey(self, s.ret)) return panicFmt(self, "{s}: unsupported key type", .{member});
            const obj = mapPayload(self, args[0]) orelse return panicFmt(self, "{s}: not a hashmap", .{member});
            const copy = obj.clone() catch return oomPanic(self);
            for (copy.entries) |slot| {
                if (slot.state != .used) continue;
                vm_dispatch.retainCell(self, slot.key) catch {
                    copy.deinit();
                    return oomPanic(self);
                };
                vm_dispatch.retainCell(self, slot.val) catch {
                    copy.deinit();
                    return oomPanic(self);
                };
            }
            return wrapOpaque(self, s.ret, copy, hashmapDisposer);
        },
    }
}

/// Register a freshly built host object behind an opaque shell. On
/// registration failure the shell is freed before the panic commits
/// (docs/interpreter-vm.md §6.4: uncommitted-result disposal).
fn wrapOpaque(self: *VmCtx, ty: u32, obj: *anyopaque, disposer: HostDisposer) HostResult {
    const row = self.metaImage().types[ty];
    if (row.kind != .named) return .{ .panic = "host object: unexpected result type" };
    const host_type_id = self.metaImage().type_decls[row.a].a;
    _ = &host_type_id;
    const h = self.heap.allocObject(.opaque_, ty, 1, 0) catch return oomPanic(self);
    h.setCell(0, @intFromPtr(obj));
    self.registerHostResource(host_type_id, @intFromPtr(h), disposer, self) catch {
        self.heap.freeShell(h);
        return oomPanic(self);
    };
    return .{ .value = @intFromPtr(h) };
}

/// Borrowed deterministic panic message (adapter trap paths): formatted
/// into the VM's scratch buffer, which `sitePrefixed` copies into the
/// owned Termination message before the buffer is reused.
fn panicFmt(self: *VmCtx, comptime fmt: []const u8, args: anytype) HostResult {
    const slice = std.fmt.bufPrint(&self.panic_buf, fmt, args) catch return oomPanic(self);
    return .{ .panic = slice };
}

/// Resolve an opaque argument's host object; callers turn a null into
/// their deterministic "not an <what>" trap. Unreachable in validated
/// programs.
fn arrayPayload(self: *VmCtx, v: Value) ?*host_module.ArrayObject {
    const h = self.heap.deref(v) catch return null;
    if (h.kind != .opaque_) return null;
    return @ptrFromInt(@as(usize, @intCast(h.cell(0))));
}

fn mapPayload(self: *VmCtx, v: Value) ?*host_module.HashMapObject {
    const h = self.heap.deref(v) catch return null;
    if (h.kind != .opaque_) return null;
    return @ptrFromInt(@as(usize, @intCast(h.cell(0))));
}

/// StdLib §3: key type `K` must be hashable. `builtin.hash` covers the
/// primitive scalar types and str; anything else (e.g. a list key,
/// which the frontend does not reject today) is a deterministic trap
/// before any mutation.
fn checkHashableKey(self: *VmCtx, map_ty: u32) bool {
    const row = self.metaImage().types[map_ty];
    // The `named` arg range is `{ b = start, c = len }`.
    if (row.kind != .named or row.c == 0) return false;
    const k = self.metaImage().types[row.b];
    return k.kind == .primitive and switch (@as(llir.PrimitiveId, @enumFromInt(k.a))) {
        .byte, .bool, .int32, .uint32, .float32, .str => true,
        else => false,
    };
}

/// Wyhash (seed 0) over str contents or the raw scalar cell —
/// bit-identical to `builtin.hash` (Runtime §4.9).
fn hashmapKeyHash(ctx: ?*anyopaque, key: Value) u64 {
    const self: *VmCtx = @ptrCast(@alignCast(ctx.?));
    if (self.heap.strSliceOf(key)) |bytes| return std.hash.Wyhash.hash(0, bytes);
    var v = key;
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&v));
}

/// Str content equality (mirroring `==`, `str_eq`) for str keys; raw
/// cell equality for scalars.
fn hashmapKeyEq(ctx: ?*anyopaque, a: Value, b: Value) bool {
    const self: *VmCtx = @ptrCast(@alignCast(ctx.?));
    if (self.heap.strSliceOf(a) != null) return vm_dispatch.strEqual(self, a, b) catch false;
    return a == b;
}

/// Release one stored/displaced cell if it is a counted shell; scalars
/// and unique (non-counted) Copy shells have no reference to drop.
fn releaseCellIfCounted(self: *VmCtx, addr: Value) HeapErr!void {
    if (addr == 0) return;
    const h = self.heap.registry.get(addr) orelse return; // scalar cell
    if (!h.isCounted()) return;
    try vm_dispatch.releaseCounted(self, addr);
}

/// `Array[T]` disposal: release every stored element once, then free
/// the host object. The shell itself is freed by the destruction
/// machinery (the disposer must not free it).
fn arrayDisposer(user: ?*anyopaque, payload: u64) void {
    const self: *VmCtx = @ptrCast(@alignCast(user orelse return));
    const h = self.heap.registry.get(payload) orelse return;
    const obj: *host_module.ArrayObject = @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    for (obj.cells) |c| releaseCellIfCounted(self, c) catch {};
    obj.deinit();
}

/// `HashMap[K, V]` disposal: release every entry's key and value once,
/// then free the host object.
fn hashmapDisposer(user: ?*anyopaque, payload: u64) void {
    const self: *VmCtx = @ptrCast(@alignCast(user orelse return));
    const h = self.heap.registry.get(payload) orelse return;
    const obj: *host_module.HashMapObject = @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    for (obj.entries) |slot| {
        if (slot.state != .used) continue;
        releaseCellIfCounted(self, slot.key) catch {};
        releaseCellIfCounted(self, slot.val) catch {};
    }
    obj.deinit();
}
