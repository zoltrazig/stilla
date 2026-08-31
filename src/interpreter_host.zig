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
const HeapErr = vm_types.HeapErr;
const Termination = types.Termination;
const RunError = types.RunError;
const HostResult = types.HostResult;
const ModuleLoader = loader_mod.ModuleLoader;
const HostDisposer = types.HostDisposer;

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
// decode/encode); ownership-sensitive members (move/borrow, list/union/
// box/opaque cells, type-dependent decode, the panic path) are
// raw-shaped fns. The `host_module` handler structs (`DefaultHostCall`,
// `MathHostCall`, `StringHostCall`, `ListHostCall`) remain the
// implementations; the members forward to them.
// ---------------------------------------------------------------------------

/// The `builtin` module (Runtime §4): `print` binds typed; the rest
/// need type-dependent decode, box mechanics, or the panic path
/// (raw-shaped fns below).
const builtin_module = struct {
    pub const symbol = "builtin";

    pub fn print(ctx: ?*anyopaque, message: host_bind.Str) void {
        host_module.defaultHostCall.print(ctx, message.bytes);
    }
    pub const str = hostBuiltinStr;
    pub const box = hostBuiltinBox;
    pub const unbox = hostBuiltinUnbox;
    pub const panic = hostBuiltinPanic;
    pub const assert = hostBuiltinAssert;
    pub const hash = hostBuiltinHash;
};

/// The `math` module (StdLib §4): all twenty members are plain
/// `float32` functions — typed bindings around the `MathHostCall` table.
const math_module = struct {
    pub const symbol = "math";

    pub fn sqrt(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.sqrt(ctx, x);
    }
    pub fn pow(ctx: ?*anyopaque, x: f32, y: f32) f32 {
        return host_module.mathHostCall.pow(ctx, x, y);
    }
    pub fn exp(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.exp(ctx, x);
    }
    pub fn ln(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.ln(ctx, x);
    }
    pub fn log2(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.log2(ctx, x);
    }
    pub fn log10(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.log10(ctx, x);
    }
    pub fn sin(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.sin(ctx, x);
    }
    pub fn cos(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.cos(ctx, x);
    }
    pub fn tan(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.tan(ctx, x);
    }
    pub fn asin(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.asin(ctx, x);
    }
    pub fn acos(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.acos(ctx, x);
    }
    pub fn atan(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.atan(ctx, x);
    }
    pub fn atan2(ctx: ?*anyopaque, y: f32, x: f32) f32 {
        return host_module.mathHostCall.atan2(ctx, y, x); // y first, matching IEEE 754
    }
    pub fn floor(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.floor(ctx, x);
    }
    pub fn ceil(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.ceil(ctx, x);
    }
    pub fn round(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.round(ctx, x);
    }
    pub fn trunc(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.trunc(ctx, x);
    }
    pub fn abs(ctx: ?*anyopaque, x: f32) f32 {
        return host_module.mathHostCall.abs(ctx, x);
    }
    pub fn min(ctx: ?*anyopaque, a: f32, b: f32) f32 {
        return host_module.mathHostCall.min(ctx, a, b);
    }
    pub fn max(ctx: ?*anyopaque, a: f32, b: f32) f32 {
        return host_module.mathHostCall.max(ctx, a, b);
    }
};

/// The `string` module (StdLib §5): the four pure predicates bind typed;
/// the rest error or allocate through scratch buffers (raw-shaped fns
/// below).
const string_module = struct {
    pub const symbol = "string";

    pub fn is_empty(ctx: ?*anyopaque, s: host_bind.Str) bool {
        return host_module.stringHostCall.is_empty(ctx, s.bytes);
    }
    pub fn contains(ctx: ?*anyopaque, haystack: host_bind.Str, needle: host_bind.Str) bool {
        return host_module.stringHostCall.contains(ctx, haystack.bytes, needle.bytes);
    }
    pub fn starts_with(ctx: ?*anyopaque, s: host_bind.Str, prefix: host_bind.Str) bool {
        return host_module.stringHostCall.starts_with(ctx, s.bytes, prefix.bytes);
    }
    pub fn ends_with(ctx: ?*anyopaque, s: host_bind.Str, suffix: host_bind.Str) bool {
        return host_module.stringHostCall.ends_with(ctx, s.bytes, suffix.bytes);
    }
    pub const len = hostStringLen;
    pub const concat = hostStringConcat;
    pub const index_of = hostStringIndexOf;
    pub const substring = hostStringSubstring;
    pub const split = hostStringSplit;
    pub const join = hostStringJoin;
    pub const trim = hostStringTrim;
    pub const lower = hostStringLower;
    pub const upper = hostStringUpper;
    pub const replace = hostStringReplace;
    pub const repeat = hostStringRepeat;
    pub const to_utf8 = hostStringToUtf8;
    pub const from_utf8 = hostStringFromUtf8;
    pub const to_codepoints = hostStringToCodepoints;
    pub const from_codepoints = hostStringFromCodepoints;
};

/// The `list` module (Runtime §4.3–§4.4): both members need heap
/// mechanics (borrowed-list deref, cons-chain materialization).
const list_module = struct {
    pub const symbol = "list";

    pub const len = hostListLen;
    pub const range = hostListRange;
};

/// The `array` module (StdLib §2): opaque payloads and retain/release
/// mechanics — raw-shaped fns.
const array_module = struct {
    pub const symbol = "array";

    pub const make = hostArrayMake;
    pub const len = hostArrayLen;
    pub const get = hostArrayGet;
    pub const set = hostArraySet;
    pub const clone = hostArrayClone;
};

/// The `hashmap` module (StdLib §3): opaque payloads, key-type checks,
/// and retain/release mechanics — raw-shaped fns.
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

/// `builtin.str` — Runtime §4.2: decode by the declared parameter type,
/// format the scalar into the stack buffer, allocate the str object.
fn hostBuiltinStr(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    if (args.len < 1 or sig.desc.params_len < 1) return .{ .panic = "builtin.str: expected 1 argument" };
    const image = vm.curImage();
    const params = image.params[sig.desc.params_start..][0..sig.desc.params_len];
    const pt = image.types[params[0].type_];
    const pid: llir.PrimitiveId = if (pt.kind == .primitive) @enumFromInt(pt.a) else .hostdata;
    if (pid == .hostdata) return .{ .panic = "builtin.str: unsupported value" };
    const view = vm_types.decodeScalar(&vm.runtime.heap, pid, args[0]) catch return .{ .panic = "builtin.str: unsupported value" };
    var buf: [64]u8 = undefined;
    const text = host_module.defaultHostCall.str(userdata, view, &buf) catch return .{ .panic = "builtin.str: unsupported value" };
    const cell = vm.runtime.heap.newStr(sig.desc.ret, text) catch return .{ .panic = "builtin.str: out of memory" };
    return .{ .value = cell };
}

/// `builtin.box` — Runtime §4.5: allocate the box shell around the payload.
fn hostBuiltinBox(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    if (args.len < 1) return .{ .panic = "builtin.box: expected 1 argument" };
    const h = vm.runtime.heap.allocObject(.box_, sig.desc.ret, 1, 0) catch return .{ .panic = "builtin.box: out of memory" };
    h.setCell(0, host_module.defaultHostCall.box(userdata, args[0]));
    return .{ .value = @intFromPtr(h) };
}

/// `builtin.unbox` — Runtime §4.6: consume the box and return the payload;
/// a *Copy* `box[T]` call without `move` reads the payload and leaves the
/// shell usable (the mode rides on the signature's first parameter).
fn hostBuiltinUnbox(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
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
    return .{ .value = host_module.defaultHostCall.unbox(userdata, payload) };
}

/// `builtin.panic` — Runtime §4.7: terminate with the message.
fn hostBuiltinPanic(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = sig;
    if (args.len < 1) return .{ .panic = "builtin.panic: expected 1 argument" };
    const msg = vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "builtin.panic: not a str" };
    return .{ .panic = host_module.defaultHostCall.panic(userdata, msg) };
}

/// `builtin.assert` — Runtime §4.8: panic with the message on the false path.
fn hostBuiltinAssert(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = sig;
    if (args.len < 2) return .{ .panic = "builtin.assert: expected 2 arguments" };
    if (args[0] == 0) {
        const msg = vm.runtime.heap.strSliceOf(args[1]) orelse return .{ .panic = "builtin.assert: message not a str" };
        return .{ .panic = host_module.defaultHostCall.assert(userdata, msg) };
    }
    return .{ .value = 0 };
}

/// `builtin.hash` — Runtime §4.9: hash str contents when the first
/// parameter is a str, else the raw scalar cell.
fn hostBuiltinHash(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    if (args.len < 1) return .{ .panic = "builtin.hash: expected 1 argument" };
    // The declared param type decides the hash input: str contents when
    // the first parameter is a str, else the raw scalar cell.
    const str_bytes = if (sig.paramCount() != 0 and sig.param(0).ty == .str) vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "builtin.hash: not a str" } else null;
    var scalar = args[0];
    return .{ .value = host_module.defaultHostCall.hash(userdata, str_bytes orelse std.mem.asBytes(&scalar)) };
}

/// `string.len` — StdLib §5: lengths are in code points, never bytes.
fn hostStringLen(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = sig;
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.len: expected a str argument" };
    const n = host_module.stringHostCall.len(userdata, a) catch |e| return stringErr(vm, e, "len");
    return .{ .value = ValueCodec.encodeInt32(n) };
}

/// `string.concat` — StdLib §5.
fn hostStringConcat(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.concat: expected 2 str arguments" };
    const b = strArg(vm, args, 1) orelse return .{ .panic = "string.concat: expected 2 str arguments" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.concat(userdata, a, b, &out) catch |e| return stringErr(vm, e, "concat");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.index_of` — StdLib §5: code-point index of the first
/// occurrence, or `Option::None`.
fn hostStringIndexOf(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.index_of: expected 2 str arguments" };
    const b = strArg(vm, args, 1) orelse return .{ .panic = "string.index_of: expected 2 str arguments" };
    const found = host_module.stringHostCall.index_of(userdata, a, b) catch |e| return stringErr(vm, e, "index_of");
    const cell = if (found) |idx|
        optionCell(vm, sig.desc.ret, true, ValueCodec.encodeInt32(idx)) catch return oomPanic(
            vm,
        )
    else
        optionCell(vm, sig.desc.ret, false, 0) catch return oomPanic(
            vm,
        );
    return .{ .value = cell };
}

/// `string.substring` — StdLib §5: half-open interval [start, end).
fn hostStringSubstring(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.substring: expected a str argument" };
    const start = intArg(vm, args, 1) orelse return .{ .panic = "string.substring: expected int32 offsets" };
    const end = intArg(vm, args, 2) orelse return .{ .panic = "string.substring: expected int32 offsets" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.substring(userdata, a, start, end, &out) catch |e| return stringErr(vm, e, "substring");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.split` — StdLib §5: pieces as fresh str objects in a list.
fn hostStringSplit(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.split: expected 2 str arguments" };
    const sep = strArg(vm, args, 1) orelse return .{ .panic = "string.split: expected 2 str arguments" };
    var pieces = std.array_list.Managed([]const u8).init(vm.allocator);
    defer pieces.deinit();
    host_module.stringHostCall.split(userdata, a, sep, &pieces) catch |e| return stringErr(vm, e, "split");
    // Copy each piece (a slice into the input str) into a fresh str
    // object; the list chain owns them (no retain).
    const elem_ty = vm.curImage().types[sig.desc.ret].a;
    var cells = std.ArrayList(Value).empty;
    defer cells.deinit(vm.allocator);
    for (pieces.items) |p| {
        const c = vm.runtime.heap.newStr(elem_ty, p) catch return oomPanic(
            vm,
        );
        cells.append(vm.allocator, c) catch return oomPanic(
            vm,
        );
    }
    const cell = newListCells(vm, sig.desc.ret, cells.items) catch return oomPanic(
        vm,
    );
    return .{ .value = cell };
}

/// `string.join` — StdLib §5.
fn hostStringJoin(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    if (args.len < 2) return .{ .panic = "string.join: expected 2 arguments" };
    const sep = strArg(vm, args, 1) orelse return .{ .panic = "string.join: separator not a str" };
    var elems = std.ArrayList(Value).empty;
    defer elems.deinit(vm.allocator);
    walkList(vm, args[0], &elems) catch return .{ .panic = "string.join: not a list" };
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(vm.allocator);
    for (elems.items) |c| {
        parts.append(vm.allocator, vm.runtime.heap.strSliceOf(c) orelse return .{ .panic = "string.join: element not a str" }) catch return oomPanic(
            vm,
        );
    }
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.join(userdata, parts.items, sep, &out) catch |e| return stringErr(vm, e, "join");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.trim` — StdLib §5: removes leading and trailing Unicode
/// whitespace.
fn hostStringTrim(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.trim: expected a str argument" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.trim(userdata, a, &out) catch |e| return stringErr(vm, e, "trim");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.lower` — StdLib §5: full Unicode default case conversion.
fn hostStringLower(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.lower: expected a str argument" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.lower(userdata, a, &out) catch |e| return stringErr(vm, e, "lower");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.upper` — StdLib §5: full Unicode default case conversion.
fn hostStringUpper(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.upper: expected a str argument" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.upper(userdata, a, &out) catch |e| return stringErr(vm, e, "upper");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.replace` — StdLib §5.
fn hostStringReplace(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.replace: expected 3 str arguments" };
    const from = strArg(vm, args, 1) orelse return .{ .panic = "string.replace: expected 3 str arguments" };
    const to = strArg(vm, args, 2) orelse return .{ .panic = "string.replace: expected 3 str arguments" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.replace(userdata, a, from, to, &out) catch |e| return stringErr(vm, e, "replace");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.repeat` — StdLib §5; a negative count traps.
fn hostStringRepeat(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.repeat: expected a str argument" };
    const count = intArg(vm, args, 1) orelse return .{ .panic = "string.repeat: expected an int32 count" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.repeat(userdata, a, count, &out) catch |e| return stringErr(vm, e, "repeat");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.to_utf8` — StdLib §5: the bytes of the str as a `list[byte]`.
fn hostStringToUtf8(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.to_utf8: expected a str argument" };
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.to_utf8(userdata, a, &out) catch |e| return stringErr(vm, e, "to_utf8");
    var cells = std.ArrayList(Value).empty;
    defer cells.deinit(vm.allocator);
    for (out.items) |b| cells.append(vm.allocator, @as(Value, b)) catch return oomPanic(
        vm,
    );
    const cell = newListCells(vm, sig.desc.ret, cells.items) catch return oomPanic(
        vm,
    );
    return .{ .value = cell };
}

/// `string.from_utf8` — StdLib §5; invalid UTF-8 traps.
fn hostStringFromUtf8(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    if (args.len < 1) return .{ .panic = "string.from_utf8: expected 1 argument" };
    var elems = std.ArrayList(Value).empty;
    defer elems.deinit(vm.allocator);
    walkList(vm, args[0], &elems) catch return .{ .panic = "string.from_utf8: not a list" };
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(vm.allocator);
    for (elems.items) |c| bytes.append(vm.allocator, @truncate(c)) catch return oomPanic(
        vm,
    );
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.from_utf8(userdata, bytes.items, &out) catch |e| return stringErr(vm, e, "from_utf8");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `string.to_codepoints` — StdLib §5: the code points as a
/// `list[uint32]`.
fn hostStringToCodepoints(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const a = strArg(vm, args, 0) orelse return .{ .panic = "string.to_codepoints: expected a str argument" };
    var out = std.array_list.Managed(u32).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.to_codepoints(userdata, a, &out) catch |e| return stringErr(vm, e, "to_codepoints");
    var cells = std.ArrayList(Value).empty;
    defer cells.deinit(vm.allocator);
    for (out.items) |cp| cells.append(vm.allocator, ValueCodec.encodeUint32(cp)) catch return oomPanic(
        vm,
    );
    const cell = newListCells(vm, sig.desc.ret, cells.items) catch return oomPanic(
        vm,
    );
    return .{ .value = cell };
}

/// `string.from_codepoints` — StdLib §5; non-scalar code points trap.
fn hostStringFromCodepoints(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    if (args.len < 1) return .{ .panic = "string.from_codepoints: expected 1 argument" };
    var elems = std.ArrayList(Value).empty;
    defer elems.deinit(vm.allocator);
    walkList(vm, args[0], &elems) catch return .{ .panic = "string.from_codepoints: not a list" };
    var cps = std.ArrayList(u32).empty;
    defer cps.deinit(vm.allocator);
    for (elems.items) |c| cps.append(vm.allocator, ValueCodec.decodeUint32(c) orelse return .{ .panic = "string.from_codepoints: element not a uint32" }) catch return oomPanic(
        vm,
    );
    var out = std.array_list.Managed(u8).init(vm.allocator);
    defer out.deinit();
    host_module.stringHostCall.from_codepoints(userdata, cps.items, &out) catch |e| return stringErr(vm, e, "from_codepoints");
    return newStrCell(vm, sig.desc.ret, out.items);
}

/// `list.len` — Runtime §4.3: the head cons node's stored suffix length
/// (O(1)).
fn hostListLen(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = sig;
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
    return .{ .value = ValueCodec.encodeInt32(host_module.listHostCall.len(userdata, count)) };
}

/// `list.range` — Runtime §4.4: the inclusive [start, end] integer range
/// as a `list[int32]` cons chain.
fn hostListRange(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    const start = intArg(vm, args, 0) orelse return .{ .panic = "list.range: expected 2 int32 arguments" };
    const end = intArg(vm, args, 1) orelse return .{ .panic = "list.range: expected 2 int32 arguments" };
    var vals = std.array_list.Managed(i32).init(vm.allocator);
    defer vals.deinit();
    host_module.listHostCall.range(userdata, start, end, &vals) catch return oomPanic(
        vm,
    );
    var cells = std.ArrayList(Value).empty;
    defer cells.deinit(vm.allocator);
    for (vals.items) |v| cells.append(vm.allocator, ValueCodec.encodeInt32(v)) catch return oomPanic(
        vm,
    );
    const cell = newListCells(vm, sig.desc.ret, cells.items) catch return oomPanic(
        vm,
    );
    return .{ .value = cell };
}

// --- adapter helpers (M2): decode canonical cells, walk lists, and
// --- allocate VM objects for the per-module adapters above -----------

/// One str argument decoded from the canonical cells; null when absent
/// or not a live str object.
fn strArg(self: *VmCtx, args: []const Value, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    return self.runtime.heap.strSliceOf(args[i]);
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
    const slice = std.fmt.bufPrint(&self.runtime.panic_buf, "string.{s}: {s}", .{ member, msg }) catch return oomPanic(
        self,
    );
    return .{ .panic = slice };
}

/// Allocate a str object holding `bytes`; OOM is a panic.
fn newStrCell(self: *VmCtx, ty: u32, bytes: []const u8) HostResult {
    const cell = self.runtime.heap.newStr(ty, bytes) catch return oomPanic(
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
        const h = try self.runtime.heap.allocObjectIn(.list_cons, self.curModIdx(), ty, 2, 0);
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
    const h = try self.runtime.heap.allocObject(.union_, ty, 1 + @as(usize, @intFromBool(some)), 0);
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
        const node = try self.runtime.heap.deref(cur);
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

/// `array.make` — StdLib §2: allocate the buffer, retain `init` per slot.
fn hostArrayMake(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 2) return .{ .panic = "array.make: expected 2 arguments" };
    const n = intArg(vm, args, 0) orelse return .{ .panic = "array.make: expected an int32 length" };
    if (n < 0) return panicFmt(vm, "array.make: negative length ({d})", .{n});
    const obj = host_module.ArrayObject.make(vm.allocator, n, args[1]) catch return oomPanic(vm);
    // Copy semantics: `make(2, s)` holds one reference per slot.
    var i: usize = 0;
    while (i < obj.cells.len) : (i += 1) {
        vm_dispatch.retainCell(vm, obj.cells[i]) catch {
            obj.deinit();
            return oomPanic(vm);
        };
    }
    return wrapOpaque(vm, sig.desc.ret, obj, arrayDisposer);
}

/// `array.len` — StdLib §2: the element count.
fn hostArrayLen(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = sig;
    if (args.len < 1) return .{ .panic = "array.len: expected 1 argument" };
    const obj = arrayPayload(vm, args[0]) orelse return panicFmt(vm, "array.len: not an array", .{});
    return .{ .value = ValueCodec.encodeInt32(@intCast(obj.len)) };
}

/// `array.get` — StdLib §2: the element by value; the returned copy
/// establishes a new owner.
fn hostArrayGet(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = sig;
    if (args.len < 2) return .{ .panic = "array.get: expected 2 arguments" };
    const obj = arrayPayload(vm, args[0]) orelse return panicFmt(vm, "array.get: not an array", .{});
    const idx = intArg(vm, args, 1) orelse return .{ .panic = "array.get: expected an int32 index" };
    const v = obj.get(idx) catch return panicFmt(
        vm,
        "array.get: index {d} out of range (len {d})",
        .{ idx, obj.len },
    );
    // The returned element is a copy: establish the new owner.
    vm_dispatch.retainCell(vm, v) catch return oomPanic(vm);
    return .{ .value = v };
}

/// `array.set` — StdLib §2: in-place mutation; the same shell moves on.
fn hostArraySet(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = sig;
    if (args.len < 3) return .{ .panic = "array.set: expected 3 arguments" };
    const obj = arrayPayload(vm, args[0]) orelse return panicFmt(vm, "array.set: not an array", .{});
    const idx = intArg(vm, args, 1) orelse return .{ .panic = "array.set: expected an int32 index" };
    if (idx < 0 or idx >= obj.len) return panicFmt(
        vm,
        "array.set: index {d} out of range (len {d})",
        .{ idx, obj.len },
    );
    vm_dispatch.retainCell(vm, args[2]) catch return oomPanic(vm);
    const old = obj.set(idx, args[2]) catch return oomPanic(vm);
    // Unreachable: `releaseCellIfCounted` checked registry + counted.
    releaseCellIfCounted(vm, old) catch {};
    // In-place mutation (StdLib §2): the same shell moves on.
    return .{ .value = args[0] };
}

/// `array.clone` — StdLib §2: a fresh buffer retaining every element.
fn hostArrayClone(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 1) return .{ .panic = "array.clone: expected 1 argument" };
    const obj = arrayPayload(vm, args[0]) orelse return panicFmt(vm, "array.clone: not an array", .{});
    const copy = obj.clone() catch return oomPanic(vm);
    for (copy.cells) |c| {
        vm_dispatch.retainCell(vm, c) catch {
            copy.deinit();
            return oomPanic(vm);
        };
    }
    return wrapOpaque(vm, sig.desc.ret, copy, arrayDisposer);
}

/// `hashmap.empty` — StdLib §3: a fresh empty table.
fn hostHashMapEmpty(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    _ = args;
    if (!checkHashableKey(vm, sig.desc.ret)) return panicFmt(vm, "hashmap.empty: unsupported key type", .{});
    const obj = host_module.HashMapObject.empty(vm.allocator, vm, hashmapKeyHash, hashmapKeyEq) catch return oomPanic(vm);
    return wrapOpaque(vm, sig.desc.ret, obj, hashmapDisposer);
}

/// `hashmap.insert` — StdLib §3: in-place mutation; the same shell moves on.
fn hostHashMapInsert(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 3) return .{ .panic = "hashmap.insert: expected 3 arguments" };
    if (!checkHashableKey(vm, sig.desc.ret)) return panicFmt(vm, "hashmap.insert: unsupported key type", .{});
    const obj = mapPayload(vm, args[0]) orelse return panicFmt(vm, "hashmap.insert: not a hashmap", .{});
    vm_dispatch.retainCell(vm, args[1]) catch return oomPanic(vm); // the map owns a key reference
    vm_dispatch.retainCell(vm, args[2]) catch return oomPanic(vm); // and a value reference
    const old = obj.insert(args[1], args[2]) catch return oomPanic(vm);
    if (old) |d| {
        releaseCellIfCounted(vm, d.key) catch {};
        releaseCellIfCounted(vm, d.val) catch {};
    }
    // In-place mutation (StdLib §3): the same shell moves on.
    return .{ .value = args[0] };
}

/// `hashmap.get` — StdLib §3: `Option[V]`; the returned value is a copy
/// that establishes a new owner.
fn hostHashMapGet(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 2) return .{ .panic = "hashmap.get: expected 2 arguments" };
    if (!checkHashableKey(vm, vm.curImage().params[sig.desc.params_start].type_)) return panicFmt(vm, "hashmap.get: unsupported key type", .{});
    const obj = mapPayload(vm, args[0]) orelse return panicFmt(vm, "hashmap.get: not a hashmap", .{});
    const shell = if (obj.get(args[1])) |v| blk: {
        // The returned value is a copy: establish the new owner.
        vm_dispatch.retainCell(vm, v) catch return oomPanic(vm);
        break :blk optionCell(vm, sig.desc.ret, true, v) catch return oomPanic(vm);
    } else optionCell(vm, sig.desc.ret, false, 0) catch return oomPanic(vm);
    return .{ .value = shell };
}

/// `hashmap.contains` — StdLib §3.
fn hostHashMapContains(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 2) return .{ .panic = "hashmap.contains: expected 2 arguments" };
    if (!checkHashableKey(vm, vm.curImage().params[sig.desc.params_start].type_)) return panicFmt(vm, "hashmap.contains: unsupported key type", .{});
    const obj = mapPayload(vm, args[0]) orelse return panicFmt(vm, "hashmap.contains: not a hashmap", .{});
    return .{ .value = ValueCodec.encodeBool(obj.contains(args[1])) };
}

/// `hashmap.remove` — StdLib §3: `tuple[HashMap[K, V], Option[V]]`; the
/// value transfers into the Option (the map's reference moves).
fn hostHashMapRemove(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 2) return .{ .panic = "hashmap.remove: expected 2 arguments" };
    const row = vm.curImage().types[sig.desc.ret];
    if (row.kind != .tuple) return .{ .panic = "hashmap.remove: unexpected result type" };
    const map_ty = row.a; // tuple[HashMap[K, V], Option[V]]: element 0
    if (!checkHashableKey(vm, map_ty)) return panicFmt(vm, "hashmap.remove: unsupported key type", .{});
    const obj = mapPayload(vm, args[0]) orelse return panicFmt(vm, "hashmap.remove: not a hashmap", .{});
    const opt_ty = row.a + 1;
    const option = if (obj.remove(args[1])) |e| blk: {
        // The map drops its key reference; the value transfers
        // into the Option (the map's reference moves).
        releaseCellIfCounted(vm, e.key) catch {};
        break :blk optionCell(vm, opt_ty, true, e.val) catch return oomPanic(vm);
    } else optionCell(vm, opt_ty, false, 0) catch return oomPanic(vm);
    const tuple = vm.runtime.heap.allocObject(.tuple_, sig.desc.ret, 2, 0) catch return oomPanic(vm);
    // No retains: the moved map shell and the fresh union shell
    // are unique (matching the non-retaining tuple convention).
    tuple.setCell(0, args[0]);
    tuple.setCell(1, option);
    return .{ .value = @intFromPtr(tuple) };
}

/// `hashmap.len` — StdLib §3: the entry count.
fn hostHashMapLen(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 1) return .{ .panic = "hashmap.len: expected 1 argument" };
    if (!checkHashableKey(vm, vm.metaImage().params[sig.desc.params_start].type_)) return panicFmt(vm, "hashmap.len: unsupported key type", .{});
    const obj = mapPayload(vm, args[0]) orelse return panicFmt(vm, "hashmap.len: not a hashmap", .{});
    return .{ .value = ValueCodec.encodeInt32(obj.len()) };
}

/// `hashmap.clone` — StdLib §3: a fresh table retaining every entry.
fn hostHashMapClone(vm: *VmCtx, userdata: ?*anyopaque, sig: types.HostSignature, args: []const Value) HostResult {
    _ = userdata;
    if (args.len < 1) return .{ .panic = "hashmap.clone: expected 1 argument" };
    if (!checkHashableKey(vm, sig.desc.ret)) return panicFmt(vm, "hashmap.clone: unsupported key type", .{});
    const obj = mapPayload(vm, args[0]) orelse return panicFmt(vm, "hashmap.clone: not a hashmap", .{});
    const copy = obj.clone() catch return oomPanic(vm);
    for (copy.entries) |slot| {
        if (slot.state != .used) continue;
        vm_dispatch.retainCell(vm, slot.key) catch {
            copy.deinit();
            return oomPanic(vm);
        };
        vm_dispatch.retainCell(vm, slot.val) catch {
            copy.deinit();
            return oomPanic(vm);
        };
    }
    return wrapOpaque(vm, sig.desc.ret, copy, hashmapDisposer);
}

/// Register a freshly built host object behind an opaque shell. On
/// registration failure the shell is freed before the panic commits
/// (docs/interpreter-vm.md §6.4: uncommitted-result disposal).
fn wrapOpaque(self: *VmCtx, ty: u32, obj: *anyopaque, disposer: HostDisposer) HostResult {
    const row = self.metaImage().types[ty];
    if (row.kind != .named) return .{ .panic = "host object: unexpected result type" };
    const host_type_id = self.metaImage().type_decls[row.a].a;
    _ = &host_type_id;
    const h = self.runtime.heap.allocObject(.opaque_, ty, 1, 0) catch return oomPanic(self);
    h.setCell(0, @intFromPtr(obj));
    self.registerHostResource(host_type_id, @intFromPtr(h), disposer, self) catch {
        self.runtime.heap.freeShell(h);
        return oomPanic(self);
    };
    return .{ .value = @intFromPtr(h) };
}

/// Borrowed deterministic panic message (adapter trap paths): formatted
/// into the VM's scratch buffer, which `sitePrefixed` copies into the
/// owned Termination message before the buffer is reused.
fn panicFmt(self: *VmCtx, comptime fmt: []const u8, args: anytype) HostResult {
    const slice = std.fmt.bufPrint(&self.runtime.panic_buf, fmt, args) catch return oomPanic(self);
    return .{ .panic = slice };
}

/// Resolve an opaque argument's host object; callers turn a null into
/// their deterministic "not an <what>" trap. Unreachable in validated
/// programs.
fn arrayPayload(self: *VmCtx, v: Value) ?*host_module.ArrayObject {
    const h = self.runtime.heap.deref(v) catch return null;
    if (h.kind != .opaque_) return null;
    return @ptrFromInt(@as(usize, @intCast(h.cell(0))));
}

fn mapPayload(self: *VmCtx, v: Value) ?*host_module.HashMapObject {
    const h = self.runtime.heap.deref(v) catch return null;
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
    if (self.runtime.heap.strSliceOf(key)) |bytes| return std.hash.Wyhash.hash(0, bytes);
    var v = key;
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&v));
}

/// Str content equality (mirroring `==`, `str_eq`) for str keys; raw
/// cell equality for scalars.
fn hashmapKeyEq(ctx: ?*anyopaque, a: Value, b: Value) bool {
    const self: *VmCtx = @ptrCast(@alignCast(ctx.?));
    if (self.runtime.heap.strSliceOf(a) != null) return vm_dispatch.strEqual(self, a, b) catch false;
    return a == b;
}

/// Release one stored/displaced cell if it is a counted shell; scalars
/// and unique (non-counted) Copy shells have no reference to drop.
fn releaseCellIfCounted(self: *VmCtx, addr: Value) HeapErr!void {
    if (addr == 0) return;
    const h = self.runtime.heap.registry.get(addr) orelse return; // scalar cell
    if (!h.isCounted()) return;
    try vm_dispatch.releaseCounted(self, addr);
}

/// `Array[T]` disposal: release every stored element once, then free
/// the host object. The shell itself is freed by the destruction
/// machinery (the disposer must not free it).
fn arrayDisposer(user: ?*anyopaque, payload: u64) void {
    const self: *VmCtx = @ptrCast(@alignCast(user orelse return));
    const h = self.runtime.heap.registry.get(payload) orelse return;
    const obj: *host_module.ArrayObject = @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    for (obj.cells) |c| releaseCellIfCounted(self, c) catch {};
    obj.deinit();
}

/// `HashMap[K, V]` disposal: release every entry's key and value once,
/// then free the host object.
fn hashmapDisposer(user: ?*anyopaque, payload: u64) void {
    const self: *VmCtx = @ptrCast(@alignCast(user orelse return));
    const h = self.runtime.heap.registry.get(payload) orelse return;
    const obj: *host_module.HashMapObject = @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    for (obj.entries) |slot| {
        if (slot.state != .used) continue;
        releaseCellIfCounted(self, slot.key) catch {};
        releaseCellIfCounted(self, slot.val) catch {};
    }
    obj.deinit();
}
