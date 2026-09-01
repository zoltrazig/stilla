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
const host_bind = @import("host_bind.zig");
const VmCtx = interpreter.VmCtx;
const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;
const Termination = types.Termination;
const RunError = types.RunError;
const HostResult = types.HostResult;
const ModuleLoader = loader_mod.ModuleLoader;

pub const HostCall = struct {
    userdata: ?*anyopaque = null,
    /// The default dispatch: a member-table registry (docs/host-bindings.md
    /// §3.3). The stdlib modules are pre-registered (`defaultHostRegistry`);
    /// an embedding adds modules by providing its own registry.
    registry: host_bind.HostRegistry = defaultHostRegistry,
    /// Opt-out for dynamic hosts: when set, every syscall dispatches
    /// through this function and `registry` is bypassed — the pre-registry
    /// adapter contract (docs/host-bindings.md §3.3).
    invoke: ?*const fn (vm: *VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: types.HostSignature, args: []const Value) HostResult = null,
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
    var vm = VmCtx{ .allocator = allocator, .host = host, .provider = loader, .runtime = .{ .heap = .{ .allocator = allocator } } };
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
    while (!self.runtime.terminated) {
        // Run mode dispatches a whole instruction segment per iteration
        // (the tail chain runs until a termination, an error, or a
        // drop-hook continuation resumes — no per-instruction
        // call/return back into this loop).
        self.runtime.result = null;
        self.runtime.pending_err = null;
        self.runtime.popped_hook_cont = false;
        vm_dispatch.dispatch(self, std.math.maxInt(u32));
        if (self.runtime.pending_err) |e| return e;
        if (self.runtime.result) |t| {
            if (t == .normal) {
                self.runtime.terminated = false;
                try self.teardownModules();
                while (self.hookActive()) {
                    if (try vm_dispatch.step(self)) |tt| {
                        self.finishCleanup();
                        return tt;
                    }
                    try self.drainDestroyWork();
                }
                self.runtime.terminated = true;
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

// ---------------------------------------------------------------------------
// The opt-out adapter contract (docs/host-bindings.md §3.3)
// ---------------------------------------------------------------------------

/// The pre-registry adapter contract, retained as the opt-out path for
/// dynamic hosts: dispatch a `(module_symbol, member)` pair through the
/// default stdlib registry. The default `HostCall` uses the registry
/// directly; an embedding's `invoke` overrider that intercepts some
/// members delegates the rest through this function.
pub fn defaultHostCall(vm: *VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: types.HostSignature, args: []const Value) HostResult {
    if (defaultHostRegistry.lookup(module_symbol, member)) |l| {
        return l.thunk(vm, @constCast(userdata), sig, args);
    }
    return .{ .not_implemented = {} };
}

// ---------------------------------------------------------------------------
// The stdlib registry (docs/host-bindings.md §7): the six stdlib modules
// are module structs registered through `host_bind.register`. Members
// with a plain scalar/str signature bind typed (signature-checked
// decode/encode); error-returning and scratch-building members bind
// typed with a hidden `*HostCtx`; list/union-returning members bind
// typed-args with a `HostResult` body. The `host_module` plain fns
// (host.zig) remain the implementations; the members call them. Only
// the ownership-sensitive members (move/borrow modes, list/opaque
// parameters) stay raw-shaped.
// ---------------------------------------------------------------------------

/// The `builtin` module (Runtime §4): `print`/`assert`/`panic` bind
/// typed; `str`/`hash` bind typed-args with a hidden ctx (type-dependent
/// decode); `box`/`unbox` stay raw (move mode).
const builtin_module = struct {
    pub const symbol = "builtin";

    pub fn print(message: host_bind.Str) void {
        host_module.hostPrint(message.bytes);
    }
    pub fn assert(cond: bool, message: host_bind.Str) HostResult {
        if (cond) return .{ .value = 0 };
        return .{ .panic = host_module.hostAssert(message.bytes) };
    }
    pub fn panic(message: host_bind.Str) HostResult {
        return .{ .panic = host_module.hostPanic(message.bytes) };
    }
    pub fn hash(ctx: *host_bind.HostCtx, v: host_bind.RawValue) HostResult {
        // The declared param type decides the hash input: str contents
        // when the argument is a str, else the raw scalar cell.
        const bytes = if (ctx.vm.runtime.heap.strSliceOf(v.value)) |b| b else std.mem.asBytes(&v.value);
        return .{ .value = host_module.hostHash(bytes) };
    }
    pub fn str(ctx: *host_bind.HostCtx, v: host_bind.RawValue) HostResult {
        // Decode by the declared parameter type, format the scalar into
        // the stack buffer, allocate the str object.
        const image = ctx.vm.curImage();
        const params = image.params[ctx.sig.desc.params_start..][0..ctx.sig.desc.params_len];
        const pt = image.types[params[0].type_];
        const pid: llir.PrimitiveId = if (pt.kind == .primitive) @enumFromInt(pt.a) else .hostdata;
        if (pid == .hostdata) return .{ .panic = "builtin.str: unsupported value" };
        const view = vm_types.decodeScalar(&ctx.vm.runtime.heap, pid, v.value) catch return .{ .panic = "builtin.str: unsupported value" };
        var buf: [64]u8 = undefined;
        const text = host_module.hostStr(view, &buf) catch return .{ .panic = "builtin.str: unsupported value" };
        const cell = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, text) catch return .{ .panic = "builtin.str: out of memory" };
        return .{ .value = cell };
    }
    pub const box = hostBuiltinBox;
    pub const unbox = hostBuiltinUnbox;
};

/// The `math` module (StdLib §4): all twenty members are plain
/// `float32` functions — typed bindings, the impls inlined.
const math_module = struct {
    pub const symbol = "math";

    pub fn sqrt(x: f32) f32 {
        return std.math.sqrt(x);
    }
    pub fn pow(x: f32, y: f32) f32 {
        return std.math.pow(f32, x, y);
    }
    pub fn exp(x: f32) f32 {
        return @exp(x);
    }
    pub fn ln(x: f32) f32 {
        return @log(x);
    }
    pub fn log2(x: f32) f32 {
        return @log2(x);
    }
    pub fn log10(x: f32) f32 {
        return @log10(x);
    }
    pub fn sin(x: f32) f32 {
        return @sin(x);
    }
    pub fn cos(x: f32) f32 {
        return @cos(x);
    }
    pub fn tan(x: f32) f32 {
        return @tan(x);
    }
    pub fn asin(x: f32) f32 {
        return std.math.asin(x);
    }
    pub fn acos(x: f32) f32 {
        return std.math.acos(x);
    }
    pub fn atan(x: f32) f32 {
        return std.math.atan(x);
    }
    pub fn atan2(y: f32, x: f32) f32 {
        return std.math.atan2(y, x); // y first, matching IEEE 754
    }
    pub fn floor(x: f32) f32 {
        return @floor(x);
    }
    pub fn ceil(x: f32) f32 {
        return @ceil(x);
    }
    pub fn round(x: f32) f32 {
        return std.math.round(x); // ties away from zero
    }
    pub fn trunc(x: f32) f32 {
        return @trunc(x);
    }
    pub fn abs(x: f32) f32 {
        return @abs(x);
    }
    pub fn min(a: f32, b: f32) f32 {
        return vm_types.fminIeee(f32, a, b); // IEEE fmin
    }
    pub fn max(a: f32, b: f32) f32 {
        return vm_types.fmaxIeee(f32, a, b); // IEEE fmax
    }
};

/// The `string` module (StdLib §5): pure predicates bind typed; the
/// error-returning/scratch-building members bind typed with a hidden
/// `HostCtx` (results built in the per-syscall scratch, host-bindings.md
/// §6); the list-returning members bind typed-args with a `HostResult`
/// body; the list-parameter members (`join`, `from_utf8`,
/// `from_codepoints`) stay raw.
const string_module = struct {
    pub const symbol = "string";

    pub fn is_empty(s: host_bind.Str) bool {
        return host_module.stringIsEmpty(s.bytes);
    }
    pub fn contains(haystack: host_bind.Str, needle: host_bind.Str) bool {
        return host_module.stringContains(haystack.bytes, needle.bytes);
    }
    pub fn starts_with(s: host_bind.Str, prefix: host_bind.Str) bool {
        return host_module.stringStartsWith(s.bytes, prefix.bytes);
    }
    pub fn ends_with(s: host_bind.Str, suffix: host_bind.Str) bool {
        return host_module.stringEndsWith(s.bytes, suffix.bytes);
    }
    pub fn len(s: host_bind.Str) host_module.StringErr!i32 {
        return host_module.stringLen(s.bytes);
    }
    pub fn concat(ctx: *host_bind.HostCtx, a: host_bind.Str, b: host_bind.Str) host_module.StringErr!host_bind.RawValue {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        try host_module.stringConcat(a.bytes, b.bytes, &out);
        return .{ .value = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, out.items) catch return error.OutOfMemory };
    }
    pub fn substring(ctx: *host_bind.HostCtx, s: host_bind.Str, start: i32, end: i32) host_module.StringErr!host_bind.RawValue {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        try host_module.stringSubstring(s.bytes, start, end, &out);
        return .{ .value = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, out.items) catch return error.OutOfMemory };
    }
    pub fn trim(ctx: *host_bind.HostCtx, s: host_bind.Str) host_module.StringErr!host_bind.RawValue {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        try host_module.stringTrim(s.bytes, &out);
        return .{ .value = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, out.items) catch return error.OutOfMemory };
    }
    pub fn lower(ctx: *host_bind.HostCtx, s: host_bind.Str) host_module.StringErr!host_bind.RawValue {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        try host_module.stringLower(s.bytes, &out);
        return .{ .value = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, out.items) catch return error.OutOfMemory };
    }
    pub fn upper(ctx: *host_bind.HostCtx, s: host_bind.Str) host_module.StringErr!host_bind.RawValue {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        try host_module.stringUpper(s.bytes, &out);
        return .{ .value = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, out.items) catch return error.OutOfMemory };
    }
    pub fn replace(ctx: *host_bind.HostCtx, s: host_bind.Str, from: host_bind.Str, to: host_bind.Str) host_module.StringErr!host_bind.RawValue {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        try host_module.stringReplace(s.bytes, from.bytes, to.bytes, &out);
        return .{ .value = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, out.items) catch return error.OutOfMemory };
    }
    pub fn repeat(ctx: *host_bind.HostCtx, s: host_bind.Str, count: i32) host_module.StringErr!host_bind.RawValue {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        try host_module.stringRepeat(s.bytes, count, &out);
        return .{ .value = ctx.vm.runtime.heap.newStr(ctx.sig.desc.ret, out.items) catch return error.OutOfMemory };
    }
    pub fn index_of(ctx: *host_bind.HostCtx, haystack: host_bind.Str, needle: host_bind.Str) HostResult {
        const found = host_module.stringIndexOf(haystack.bytes, needle.bytes) catch |e| return ctx.stringErr(e, "index_of");
        const cell = if (found) |idx|
            ctx.optionCell(ctx.sig.desc.ret, true, ValueCodec.encodeInt32(idx)) catch return ctx.oomPanic()
        else
            ctx.optionCell(ctx.sig.desc.ret, false, 0) catch return ctx.oomPanic();
        return .{ .value = cell };
    }
    pub fn split(ctx: *host_bind.HostCtx, s: host_bind.Str, sep: host_bind.Str) HostResult {
        var pieces = std.array_list.Managed([]const u8).init(ctx.vm.allocator);
        defer pieces.deinit();
        host_module.stringSplit(s.bytes, sep.bytes, &pieces) catch |e| return ctx.stringErr(e, "split");
        // Copy each piece (a slice into the input str) into a fresh str
        // object; the list chain owns them (no retain).
        const elem_ty = ctx.vm.curImage().types[ctx.sig.desc.ret].a;
        var cells = std.ArrayList(Value).empty;
        defer cells.deinit(ctx.vm.allocator);
        for (pieces.items) |p| {
            const c = ctx.vm.runtime.heap.newStr(elem_ty, p) catch return ctx.oomPanic();
            cells.append(ctx.vm.allocator, c) catch return ctx.oomPanic();
        }
        const cell = ctx.newListCells(ctx.sig.desc.ret, cells.items) catch return ctx.oomPanic();
        return .{ .value = cell };
    }
    pub fn to_utf8(ctx: *host_bind.HostCtx, s: host_bind.Str) HostResult {
        var out = std.array_list.Managed(u8).init(ctx.vm.allocator);
        defer out.deinit();
        host_module.stringToUtf8(s.bytes, &out) catch |e| return ctx.stringErr(e, "to_utf8");
        var cells = std.ArrayList(Value).empty;
        defer cells.deinit(ctx.vm.allocator);
        for (out.items) |b| cells.append(ctx.vm.allocator, @as(Value, b)) catch return ctx.oomPanic();
        const cell = ctx.newListCells(ctx.sig.desc.ret, cells.items) catch return ctx.oomPanic();
        return .{ .value = cell };
    }
    pub fn to_codepoints(ctx: *host_bind.HostCtx, s: host_bind.Str) HostResult {
        var out = std.array_list.Managed(u32).init(ctx.vm.allocator);
        defer out.deinit();
        host_module.stringToCodepoints(s.bytes, &out) catch |e| return ctx.stringErr(e, "to_codepoints");
        var cells = std.ArrayList(Value).empty;
        defer cells.deinit(ctx.vm.allocator);
        for (out.items) |cp| cells.append(ctx.vm.allocator, ValueCodec.encodeUint32(cp)) catch return ctx.oomPanic();
        const cell = ctx.newListCells(ctx.sig.desc.ret, cells.items) catch return ctx.oomPanic();
        return .{ .value = cell };
    }
    pub const join = hostStringJoin;
    pub const from_utf8 = hostStringFromUtf8;
    pub const from_codepoints = hostStringFromCodepoints;
};

/// The `list` module (Runtime §4.3–§4.4): `range` binds typed-args with
/// a hidden ctx (cons-chain materialization); `len` stays raw (borrow).
const list_module = struct {
    pub const symbol = "list";

    pub fn range(ctx: *host_bind.HostCtx, start: i32, end: i32) HostResult {
        var vals = std.array_list.Managed(i32).init(ctx.vm.allocator);
        defer vals.deinit();
        host_module.listRange(start, end, &vals) catch return ctx.oomPanic();
        var cells = std.ArrayList(Value).empty;
        defer cells.deinit(ctx.vm.allocator);
        for (vals.items) |v| cells.append(ctx.vm.allocator, ValueCodec.encodeInt32(v)) catch return ctx.oomPanic();
        const cell = ctx.newListCells(ctx.sig.desc.ret, cells.items) catch return ctx.oomPanic();
        return .{ .value = cell };
    }
    pub const len = hostListLen;
};

/// The `array` module (StdLib §2): opaque payloads and retain/release
/// mechanics — raw-shaped fns (borrow/move modes).
const array_module = struct {
    pub const symbol = "array";

    pub const make = hostArrayMake;
    pub const len = hostArrayLen;
    pub const get = hostArrayGet;
    pub const set = hostArraySet;
    pub const clone = hostArrayClone;
};

/// The `hashmap` module (StdLib §3): opaque payloads, key-type checks,
/// and retain/release mechanics — raw-shaped fns (borrow/move modes).
const hashmap_module = struct {
    pub const symbol = "hashmap";

    pub const empty = hostHashMapEmpty;
    pub const insert = hostHashMapInsert;
    pub const get = hostHashMapGet;
    pub const contains = hostHashMapContains;
    pub const remove = hostHashMapRemove;
    pub const len = hostHashMapLen;
    pub const clone = hostHashMapClone;
};

const builtinModule: host_bind.ModuleDesc = host_bind.register(builtin_module);
const mathModule: host_bind.ModuleDesc = host_bind.register(math_module);
const stringModule: host_bind.ModuleDesc = host_bind.register(string_module);
const listModule: host_bind.ModuleDesc = host_bind.register(list_module);
const arrayModule: host_bind.ModuleDesc = host_bind.register(array_module);
const hashmapModule: host_bind.ModuleDesc = host_bind.register(hashmap_module);

/// The default registry: the stdlib modules, sorted by symbol.
pub const defaultHostRegistry: host_bind.HostRegistry = blk: {
    const modules = [_]host_bind.RegisteredModule{
        .{ .desc = &arrayModule },
        .{ .desc = &builtinModule },
        .{ .desc = &hashmapModule },
        .{ .desc = &listModule },
        .{ .desc = &mathModule },
        .{ .desc = &stringModule },
    };
    break :blk .{ .modules = &modules };
};

/// `builtin.box` — Runtime §4.5: allocate the box shell around the payload.
fn hostBuiltinBox(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 1) return .{ .panic = "builtin.box: expected 1 argument" };
    const h = vm.runtime.heap.allocObject(.box_, sig.desc.ret, 1, 0) catch return .{ .panic = "builtin.box: out of memory" };
    h.setCell(0, host_module.hostBox(args[0]));
    return .{ .value = @intFromPtr(h) };
}

/// `builtin.unbox` — Runtime §4.6: consume the box and return the payload;
/// a *Copy* `box[T]` call without `move` reads the payload and leaves the
/// shell usable (the mode rides on the signature's first parameter).
fn hostBuiltinUnbox(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 1) return .{ .panic = "builtin.unbox: expected 1 argument" };
    const h = vm.runtime.heap.deref(args[0]) catch return .{ .panic = "builtin.unbox: not a box" };
    if (h.kind != .box_) return .{ .panic = "builtin.unbox: not a box" };
    const payload = h.cell(0);
    // The shell dies only on a consuming `unbox(move b)` (Runtime §4.5):
    // a *Copy*-payload box is itself Copy, so `unbox(b)` reads the
    // payload and leaves the box usable — freeing the shell here would
    // leave the caller's box value dangling and the second read would
    // deref freed memory. The mode rides on the specialized signature's
    // first parameter.
    if (vm.curImage().params[sig.desc.params_start].mode == .move) {
        h.setCell(0, 0);
        vm.runtime.heap.freeShell(h);
    }
    return .{ .value = host_module.hostUnbox(payload) };
}

/// `string.join` — StdLib §5.
fn hostStringJoin(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = host_bind.HostCtx{ .vm = vm };
    if (args.len < 2) return .{ .panic = "string.join: expected 2 arguments" };
    const sep = ctx.strArg(args, 1) orelse return .{ .panic = "string.join: separator not a str" };
    var elems = std.ArrayList(Value).empty;
    defer elems.deinit(vm.allocator);
    ctx.walkList(args[0], &elems) catch return .{ .panic = "string.join: not a list" };
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(vm.allocator);
    for (elems.items) |c| {
        parts.append(vm.allocator, vm.runtime.heap.strSliceOf(c) orelse return .{ .panic = "string.join: element not a str" }) catch return ctx.oomPanic();
    }
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringJoin(parts.items, sep, &out) catch |e| return ctx.stringErr(e, "join");
    return ctx.newStrCell(sig.desc.ret, out.items);
}

/// `string.from_utf8` — StdLib §5; invalid UTF-8 traps.
fn hostStringFromUtf8(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = host_bind.HostCtx{ .vm = vm };
    if (args.len < 1) return .{ .panic = "string.from_utf8: expected 1 argument" };
    var elems = std.ArrayList(Value).empty;
    defer elems.deinit(vm.allocator);
    ctx.walkList(args[0], &elems) catch return .{ .panic = "string.from_utf8: not a list" };
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(vm.allocator);
    for (elems.items) |c| bytes.append(vm.allocator, @truncate(c)) catch return ctx.oomPanic();
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringFromUtf8(bytes.items, &out) catch |e| return ctx.stringErr(e, "from_utf8");
    return ctx.newStrCell(sig.desc.ret, out.items);
}

/// `string.from_codepoints` — StdLib §5; non-scalar code points trap.
fn hostStringFromCodepoints(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = host_bind.HostCtx{ .vm = vm };
    if (args.len < 1) return .{ .panic = "string.from_codepoints: expected 1 argument" };
    var elems = std.ArrayList(Value).empty;
    defer elems.deinit(vm.allocator);
    ctx.walkList(args[0], &elems) catch return .{ .panic = "string.from_codepoints: not a list" };
    var cps = std.ArrayList(u32).empty;
    defer cps.deinit(vm.allocator);
    for (elems.items) |c| cps.append(vm.allocator, ValueCodec.decodeUint32(c) orelse return .{ .panic = "string.from_codepoints: element not a uint32" }) catch return ctx.oomPanic();
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringFromCodepoints(cps.items, &out) catch |e| return ctx.stringErr(e, "from_codepoints");
    return ctx.newStrCell(sig.desc.ret, out.items);
}

/// `list.len` — Runtime §4.3: the head cons node's stored suffix length
/// (O(1)).
fn hostListLen(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = sig;
    _ = userdata;
    if (args.len < 1) return .{ .panic = "list.len: expected 1 argument" };

    var count: i32 = 0;
    if (args[0] != 0) {
        const head = vm.runtime.heap.deref(args[0]) catch {
            return .{ .panic = "list.len: not a list" };
        };
        if (head.kind != .list_cons) {
            return .{ .panic = "list.len: not a list" };
        }
        count = @intCast(head.len);
    }
    return .{ .value = ValueCodec.encodeInt32(host_module.listLen(count)) };
}

/// The adapter context lives in the binding layer (host_bind.zig §3.2);
/// this alias keeps the raw-shaped members' `const ctx = HostCtx{ .vm = vm };`
/// spelling. The typed members receive it as a hidden leading parameter.
const HostCtx = host_bind.HostCtx;

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

/// `array.make` — StdLib §2: allocate the buffer, retain `init` per slot.
fn hostArrayMake(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 2) return .{ .panic = "array.make: expected 2 arguments" };
    const n = ctx.intArg(args, 0) orelse return .{ .panic = "array.make: expected an int32 length" };
    if (n < 0) return ctx.panicFmt("array.make: negative length ({d})", .{n});
    const obj = host_module.ArrayObject.make(vm.allocator, n, args[1]) catch return ctx.oomPanic();
    // Copy semantics: `make(2, s)` holds one reference per slot.
    var i: usize = 0;
    while (i < obj.cells.len) : (i += 1) {
        vm_dispatch.retainCell(vm, obj.cells[i]) catch {
            obj.deinit();
            return ctx.oomPanic();
        };
    }
    return ctx.wrapOpaque(sig.desc.ret, obj, arrayDisposer);
}

/// `array.len` — StdLib §2: the element count.
fn hostArrayLen(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = sig;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 1) return .{ .panic = "array.len: expected 1 argument" };
    const obj = ctx.arrayPayload(args[0]) orelse return ctx.panicFmt("array.len: not an array", .{});
    return .{ .value = ValueCodec.encodeInt32(@intCast(obj.len)) };
}

/// `array.get` — StdLib §2: the element by value; the returned copy
/// establishes a new owner.
fn hostArrayGet(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = sig;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 2) return .{ .panic = "array.get: expected 2 arguments" };
    const obj = ctx.arrayPayload(args[0]) orelse return ctx.panicFmt("array.get: not an array", .{});
    const idx = ctx.intArg(args, 1) orelse return .{ .panic = "array.get: expected an int32 index" };
    const v = obj.get(idx) catch return ctx.panicFmt(
        "array.get: index {d} out of range (len {d})",
        .{ idx, obj.len },
    );
    // The returned element is a copy: establish the new owner.
    vm_dispatch.retainCell(vm, v) catch return ctx.oomPanic();
    return .{ .value = v };
}

/// `array.set` — StdLib §2: in-place mutation; the same shell moves on.
fn hostArraySet(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = sig;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 3) return .{ .panic = "array.set: expected 3 arguments" };
    const obj = ctx.arrayPayload(args[0]) orelse return ctx.panicFmt("array.set: not an array", .{});
    const idx = ctx.intArg(args, 1) orelse return .{ .panic = "array.set: expected an int32 index" };
    if (idx < 0 or idx >= obj.len) return ctx.panicFmt(
        "array.set: index {d} out of range (len {d})",
        .{ idx, obj.len },
    );
    vm_dispatch.retainCell(vm, args[2]) catch return ctx.oomPanic();
    const old = obj.set(idx, args[2]) catch return ctx.oomPanic();
    // Unreachable: `releaseCellIfCounted` checked registry + counted.
    ctx.releaseCellIfCounted(old) catch {};
    // In-place mutation (StdLib §2): the same shell moves on.
    return .{ .value = args[0] };
}

/// `array.clone` — StdLib §2: a fresh buffer retaining every element.
fn hostArrayClone(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 1) return .{ .panic = "array.clone: expected 1 argument" };
    const obj = ctx.arrayPayload(args[0]) orelse return ctx.panicFmt("array.clone: not an array", .{});
    const copy = obj.clone() catch return ctx.oomPanic();
    for (copy.cells) |c| {
        vm_dispatch.retainCell(vm, c) catch {
            copy.deinit();
            return ctx.oomPanic();
        };
    }
    return ctx.wrapOpaque(sig.desc.ret, copy, arrayDisposer);
}

/// `hashmap.empty` — StdLib §3: a fresh empty table.
fn hostHashMapEmpty(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = args;
    const ctx = HostCtx{ .vm = vm };
    if (!ctx.checkHashableKey(sig.desc.ret)) return ctx.panicFmt("hashmap.empty: unsupported key type", .{});
    const obj = host_module.HashMapObject.empty(vm.allocator, vm, hashmapKeyHash, hashmapKeyEq) catch return ctx.oomPanic();
    return ctx.wrapOpaque(sig.desc.ret, obj, hashmapDisposer);
}

/// `hashmap.insert` — StdLib §3: in-place mutation; the same shell moves on.
fn hostHashMapInsert(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 3) return .{ .panic = "hashmap.insert: expected 3 arguments" };
    if (!ctx.checkHashableKey(sig.desc.ret)) return ctx.panicFmt("hashmap.insert: unsupported key type", .{});
    const obj = ctx.mapPayload(args[0]) orelse return ctx.panicFmt("hashmap.insert: not a hashmap", .{});
    vm_dispatch.retainCell(vm, args[1]) catch return ctx.oomPanic(); // the map owns a key reference
    vm_dispatch.retainCell(vm, args[2]) catch return ctx.oomPanic(); // and a value reference
    const old = obj.insert(args[1], args[2]) catch return ctx.oomPanic();
    if (old) |d| {
        ctx.releaseCellIfCounted(d.key) catch {};
        ctx.releaseCellIfCounted(d.val) catch {};
    }
    // In-place mutation (StdLib §3): the same shell moves on.
    return .{ .value = args[0] };
}

/// `hashmap.get` — StdLib §3: `Option[V]`; the returned value is a copy
/// that establishes a new owner.
fn hostHashMapGet(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 2) return .{ .panic = "hashmap.get: expected 2 arguments" };
    if (!ctx.checkHashableKey(vm.curImage().params[sig.desc.params_start].type_)) return ctx.panicFmt("hashmap.get: unsupported key type", .{});
    const obj = ctx.mapPayload(args[0]) orelse return ctx.panicFmt("hashmap.get: not a hashmap", .{});
    const shell = if (obj.get(args[1])) |v| blk: {
        // The returned value is a copy: establish the new owner.
        vm_dispatch.retainCell(vm, v) catch return ctx.oomPanic();
        break :blk ctx.optionCell(sig.desc.ret, true, v) catch return ctx.oomPanic();
    } else ctx.optionCell(sig.desc.ret, false, 0) catch return ctx.oomPanic();
    return .{ .value = shell };
}

/// `hashmap.contains` — StdLib §3.
fn hostHashMapContains(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 2) return .{ .panic = "hashmap.contains: expected 2 arguments" };
    if (!ctx.checkHashableKey(vm.curImage().params[sig.desc.params_start].type_)) return ctx.panicFmt("hashmap.contains: unsupported key type", .{});
    const obj = ctx.mapPayload(args[0]) orelse return ctx.panicFmt("hashmap.contains: not a hashmap", .{});
    return .{ .value = ValueCodec.encodeBool(obj.contains(args[1])) };
}

/// `hashmap.remove` — StdLib §3: `tuple[HashMap[K, V], Option[V]]`; the
/// value transfers into the Option (the map's reference moves).
fn hostHashMapRemove(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 2) return .{ .panic = "hashmap.remove: expected 2 arguments" };
    const row = vm.curImage().types[sig.desc.ret];
    if (row.kind != .tuple) return .{ .panic = "hashmap.remove: unexpected result type" };
    const map_ty = row.a; // tuple[HashMap[K, V], Option[V]]: element 0
    if (!ctx.checkHashableKey(map_ty)) return ctx.panicFmt("hashmap.remove: unsupported key type", .{});
    const obj = ctx.mapPayload(args[0]) orelse return ctx.panicFmt("hashmap.remove: not a hashmap", .{});
    const opt_ty = row.a + 1;
    const option = if (obj.remove(args[1])) |e| blk: {
        // The map drops its key reference; the value transfers
        // into the Option (the map's reference moves).
        ctx.releaseCellIfCounted(e.key) catch {};
        break :blk ctx.optionCell(opt_ty, true, e.val) catch return ctx.oomPanic();
    } else ctx.optionCell(opt_ty, false, 0) catch return ctx.oomPanic();
    const tuple = vm.runtime.heap.allocObject(.tuple_, sig.desc.ret, 2, 0) catch return ctx.oomPanic();
    // No retains: the moved map shell and the fresh union shell
    // are unique (matching the non-retaining tuple convention).
    tuple.setCell(0, args[0]);
    tuple.setCell(1, option);
    return .{ .value = @intFromPtr(tuple) };
}

/// `hashmap.len` — StdLib §3: the entry count.
fn hostHashMapLen(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 1) return .{ .panic = "hashmap.len: expected 1 argument" };
    if (!ctx.checkHashableKey(vm.metaImage().params[sig.desc.params_start].type_)) return ctx.panicFmt("hashmap.len: unsupported key type", .{});
    const obj = ctx.mapPayload(args[0]) orelse return ctx.panicFmt("hashmap.len: not a hashmap", .{});
    return .{ .value = ValueCodec.encodeInt32(obj.len()) };
}

/// `hashmap.clone` — StdLib §3: a fresh table retaining every entry.
fn hostHashMapClone(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    const ctx = HostCtx{ .vm = vm };
    if (args.len < 1) return .{ .panic = "hashmap.clone: expected 1 argument" };
    if (!ctx.checkHashableKey(sig.desc.ret)) return ctx.panicFmt("hashmap.clone: unsupported key type", .{});
    const obj = ctx.mapPayload(args[0]) orelse return ctx.panicFmt("hashmap.clone: not a hashmap", .{});
    const copy = obj.clone() catch return ctx.oomPanic();
    for (copy.entries) |slot| {
        if (slot.state != .used) continue;
        vm_dispatch.retainCell(vm, slot.key) catch {
            copy.deinit();
            return ctx.oomPanic();
        };
        vm_dispatch.retainCell(vm, slot.val) catch {
            copy.deinit();
            return ctx.oomPanic();
        };
    }
    return ctx.wrapOpaque(sig.desc.ret, copy, hashmapDisposer);
}

/// Wyhash / equality callbacks for `HashMapObject` (fn-pointer shape):
/// the map's opaque ctx is the VM — reconstruct the wrapper per call.
fn hashmapKeyHash(ctx: ?*anyopaque, key: Value) u64 {
    const self: *VmCtx = @ptrCast(@alignCast(ctx.?));
    const hctx = HostCtx{ .vm = self };
    return hctx.keyHash(key);
}

fn hashmapKeyEq(ctx: ?*anyopaque, a: Value, b: Value) bool {
    const self: *VmCtx = @ptrCast(@alignCast(ctx.?));
    const hctx = HostCtx{ .vm = self };
    return hctx.keyEq(a, b);
}

/// `Array[T]` disposal: release every stored element once, then free
/// the host object. The shell itself is freed by the destruction
/// machinery (the disposer must not free it).
fn arrayDisposer(user: ?*anyopaque, payload: u64) void {
    const self: *VmCtx = @ptrCast(@alignCast(user orelse return));
    const ctx = HostCtx{ .vm = self };
    const h = self.runtime.heap.registry.get(payload) orelse return;
    const obj: *host_module.ArrayObject = @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    for (obj.cells) |c| ctx.releaseCellIfCounted(c) catch {};
    obj.deinit();
}

/// `HashMap[K, V]` disposal: release every entry's key and value once,
/// then free the host object.
fn hashmapDisposer(user: ?*anyopaque, payload: u64) void {
    const self: *VmCtx = @ptrCast(@alignCast(user orelse return));
    const ctx = HostCtx{ .vm = self };
    const h = self.runtime.heap.registry.get(payload) orelse return;
    const obj: *host_module.HashMapObject = @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    for (obj.entries) |slot| {
        if (slot.state != .used) continue;
        ctx.releaseCellIfCounted(slot.key) catch {};
        ctx.releaseCellIfCounted(slot.val) catch {};
    }
    obj.deinit();
}
