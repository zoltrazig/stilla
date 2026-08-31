//! Typed host-binding layer (docs/host-bindings.md): comptime glue that
//! turns a plain Zig/C function into a registry `Binding` — signature
//! checked against the artifact before decoding, arguments decoded from
//! canonical cells, result encoded back. `raw()` remains the escape hatch
//! for ownership-sensitive members.

const std = @import("std");
const vm_types = @import("vm_types.zig");
const interp_types = @import("interpreter_types.zig");
const interpreter = @import("interpreter.zig");

const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;
const HostResult = interp_types.HostResult;
const HostSignature = interp_types.HostSignature;
const HostType = interp_types.HostType;
const ExpectedSignature = interp_types.ExpectedSignature;
const VmCtx = interpreter.VmCtx;

// ---------------------------------------------------------------------------
// Value wrappers (docs/host-bindings.md §3.1)
// ---------------------------------------------------------------------------

/// A Stilla `str`: borrowed in (valid during the call only), owned out
/// (the VM allocates the str object).
pub const Str = struct { bytes: []const u8 };

/// An opaque value's host payload (`cell 0` of the `.opaque_` shell).
/// The id is the stable host identity, carried for future verification
/// against the shell's declared host type (Runtime §3).
pub fn Opaque(comptime id: []const u8) type {
    return struct {
        ptr: ?*anyopaque,
        pub const __host_id: []const u8 = id;
    };
}

/// Pass one canonical cell through unchanged (`any`, `hostdata`, or
/// anything a raw handler wants to see). A wrapper (not a `u64` alias)
/// so the type mapping can distinguish it from a scalar.
pub const RawValue = struct { value: Value };

fn isOpaque(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "__host_id"),
        else => false,
    };
}

fn hostTypeOf(comptime T: type) HostType {
    return switch (T) {
        i32, c_int => .int32,
        u32, c_uint => .uint32,
        i64 => .i64,
        u64 => .u64,
        f32 => .float32,
        f64 => .float64,
        bool => .bool,
        Str => .str,
        [*:0]const u8 => .str,
        RawValue => .wildcard,
        else => if (isOpaque(T))
            .opaque_
        else
            @compileError("host binding: unsupported parameter type '" ++ @typeName(T) ++ "' (use a scalar, host.Str, host.Opaque(\"...\"), host.RawValue, or a raw() handler)"),
    };
}

// ---------------------------------------------------------------------------
// Binding and the registry (docs/host-bindings.md §3.3)
// ---------------------------------------------------------------------------

pub const Binding = struct {
    name: []const u8,
    /// Comptime expected signature; null = raw handler (no check).
    expected: ?ExpectedSignature,
    /// `userdata` is the registered module's userdata (the embedding's
    /// context, never a Stilla parameter).
    thunk: *const fn (vm: *VmCtx, userdata: ?*anyopaque, sig: HostSignature, args: []const Value) HostResult,
};

pub const ModuleDesc = struct {
    symbol: []const u8,
    /// Sorted by name (binary search).
    members: []const Binding,
};

pub const RegisteredModule = struct {
    desc: *const ModuleDesc,
    /// Module-level context; null falls back to `HostCall.userdata`.
    userdata: ?*anyopaque = null,
};

pub const Lookup = struct {
    thunk: *const fn (vm: *VmCtx, userdata: ?*anyopaque, sig: HostSignature, args: []const Value) HostResult,
    userdata: ?*anyopaque,
};

pub const HostRegistry = struct {
    /// Sorted by symbol (binary search).
    modules: []const RegisteredModule,

    pub fn lookup(self: HostRegistry, symbol: []const u8, member: []const u8) ?Lookup {
        var lo: usize = 0;
        var hi: usize = self.modules.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const s = self.modules[mid].desc.symbol;
            switch (std.mem.order(u8, symbol, s)) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return lookupMember(self.modules[mid], member),
            }
        }
        return null;
    }
};

fn lookupMember(module: RegisteredModule, member: []const u8) ?Lookup {
    const members = module.desc.members;
    var lo: usize = 0;
    var hi: usize = members.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, member, members[mid].name)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return .{
                .thunk = members[mid].thunk,
                .userdata = module.userdata,
            },
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Comptime glue: module structs, raw, and the generated thunks
// ---------------------------------------------------------------------------

/// Hand-written escape hatch: no signature check, full `sig` + `args`
/// surface — the ownership-sensitive members' path.
pub fn raw(comptime name: []const u8, comptime thunk: anytype) Binding {
    return .{ .name = name, .expected = null, .thunk = thunk };
}

/// Register a host module defined as a **struct**: `pub const symbol`
/// names the module; every `pub fn` is a member binding. A member whose
/// signature is the raw thunk shape
/// `(vm: *VmCtx, userdata: ?*anyopaque, sig: HostSignature, args: []const Value) -> HostResult`
/// registers raw (no signature check); any other member is a typed
/// binding — its parameters are the Stilla signature (scalars, `Str`,
/// `Opaque("...")`, `RawValue`, `[*:0]const u8` for C functions, and an
/// optional leading `?*anyopaque` module-userdata injection point).
/// Evaluate at comptime (a top-level `const` or `comptime`); the derived
/// member table must back a global.
///
/// ```zig
/// const testdb = struct {
///     pub const symbol = "testdb";
///     pub fn query(s: host_bind.Str) i32 { return @intCast(s.bytes.len); }
///     pub fn cquery(s: [*:0]const u8) callconv(.c) c_int { ... }
/// };
/// const testdb_desc: host_bind.ModuleDesc = host_bind.register(testdb);
/// ```
pub fn register(comptime M: type) ModuleDesc {
    if (!@hasDecl(M, "symbol")) {
        @compileError("host_bind.register: module struct must declare `pub const symbol`");
    }
    const names = memberFns(M);
    const members = comptime blk: {
        var arr: [names.len]Binding = undefined;
        for (names, 0..) |name, i| {
            const f = @field(M, name);
            arr[i] = if (isRawThunk(@TypeOf(f)))
                raw(name, f)
            else
                makeBinding(name, f);
        }
        break :blk sortBindings(arr);
    };
    return .{ .symbol = @field(M, "symbol"), .members = &members };
}

/// The module struct's `pub fn` decl names (its members), excluding the
/// `symbol` const. Helpers belong outside the struct: every fn in the
/// module struct is a member.
fn memberFns(comptime M: type) []const []const u8 {
    const info = switch (@typeInfo(M)) {
        .@"struct" => |s| s,
        else => @compileError("host_bind.register: expected a module struct, got '" ++ @typeName(M) ++ "'"),
    };
    const decls = info.decls;
    comptime var count: usize = 0;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "symbol")) continue;
        if (isFn(M, d.name)) count += 1;
    }
    const names = comptime blk: {
        var arr: [count][]const u8 = undefined;
        var i: usize = 0;
        for (decls) |d| {
            if (std.mem.eql(u8, d.name, "symbol")) continue;
            if (isFn(M, d.name)) {
                arr[i] = d.name;
                i += 1;
            }
        }
        break :blk arr;
    };
    return &names;
}

fn isFn(comptime M: type, comptime name: []const u8) bool {
    return switch (@typeInfo(@TypeOf(@field(M, name)))) {
        .@"fn" => true,
        else => false,
    };
}

/// True when `F` is the raw thunk shape (vm, userdata, sig, args) -> HostResult.
fn isRawThunk(comptime F: type) bool {
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => return false,
    };
    if (info.params.len != 4) return false;
    const P = info.params;
    if (P[0].type.? != *VmCtx) return false;
    if (P[1].type.? != ?*anyopaque) return false;
    if (P[2].type.? != HostSignature) return false;
    if (P[3].type.? != []const Value) return false;
    if (info.return_type == null) return false;
    return info.return_type.? == HostResult;
}

/// Comptime insertion sort (members sorted by name for binary search).
/// Takes the array by value and returns the sorted copy — a comptime
/// array value, so it can back a global const.
pub fn sortBindings(comptime arr: anytype) @TypeOf(arr) {
    @setEvalBranchQuota(100_000);
    var out = arr;
    comptime var i: usize = 1;
    while (i < out.len) : (i += 1) {
        const key = out[i];
        comptime var j = i;
        while (j > 0 and std.mem.order(u8, out[j - 1].name, key.name) == .gt) : (j -= 1) {
            out[j] = out[j - 1];
        }
        out[j] = key;
    }
    return out;
}

fn fnInfo(comptime f: anytype) std.builtin.Type.Fn {
    return switch (@typeInfo(@TypeOf(f))) {
        .@"fn" => |info| info,
        else => @compileError("host binding: expected a function value, got '" ++ @typeName(@TypeOf(f)) ++ "'"),
    };
}

fn paramType(comptime p: std.builtin.Type.Fn.Param) type {
    return p.type orelse @compileError("generic host binding parameters are not supported");
}

fn injectsUserdata(comptime f: anytype) bool {
    const Fn = fnInfo(f);
    return Fn.params.len != 0 and paramType(Fn.params[0]) == ?*anyopaque;
}

/// The Stilla parameter types of `f` (excluding an injected userdata
/// first parameter of type `?*anyopaque`), as a comptime array value.
fn paramTypes(comptime f: anytype, comptime inject: bool) [fnInfo(f).params.len - @intFromBool(inject)]type {
    const Fn = fnInfo(f);
    comptime var ts: [Fn.params.len - @intFromBool(inject)]type = undefined;
    for (Fn.params[@intFromBool(inject)..], 0..) |p, i| ts[i] = paramType(p);
    return ts;
}

fn retHostType(comptime f: anytype) HostType {
    const Fn = fnInfo(f);
    const R = Fn.return_type orelse void;
    if (R == void) return .void;
    if (R == RawValue) return .wildcard;
    return hostTypeOf(R);
}

fn expectedOf(comptime f: anytype) ExpectedSignature {
    const inject = comptime injectsUserdata(f);
    const params = comptime blk: {
        var arr: [paramTypes(f, inject).len]interp_types.HostParam = undefined;
        for (paramTypes(f, inject), 0..) |T, i| {
            arr[i] = .{ .mode = .plain, .ty = hostTypeOf(T) };
        }
        break :blk arr;
    };
    return .{ .params = &params, .ret = retHostType(f) };
}

/// The bound function's full argument tuple type (userdata slot included
/// when injected).
fn CallArgs(comptime f: anytype) type {
    const Fn = fnInfo(f);
    comptime var ts: [Fn.params.len]type = undefined;
    inline for (Fn.params, 0..) |p, i| ts[i] = paramType(p);
    return std.meta.Tuple(&ts);
}

const ArgErr = error{ BadArg, OutOfMemory };

fn opaquePtr(vm: *VmCtx, cell: Value) ?*anyopaque {
    const h = vm.runtime.heap.deref(cell) catch return null;
    if (h.kind != .opaque_) return null;
    return @ptrFromInt(h.cell(0));
}

fn decodeArg(comptime T: type, vm: *VmCtx, cell: Value) ArgErr!T {
    return switch (T) {
        i32, c_int => ValueCodec.decodeInt32(cell) orelse error.BadArg,
        u32, c_uint => ValueCodec.decodeUint32(cell) orelse error.BadArg,
        i64 => @as(i64, @bitCast(cell)),
        u64 => cell,
        f32 => ValueCodec.decodeFloat32(cell) orelse error.BadArg,
        f64 => ValueCodec.decodeFloat64(cell),
        bool => ValueCodec.decodeBool(cell) orelse error.BadArg,
        Str => .{ .bytes = vm.runtime.heap.strSliceOf(cell) orelse return error.BadArg },
        [*:0]const u8 => blk: {
            // C strings are NUL-terminated through the reusable scratch
            // (docs/host-bindings.md §6): no per-call allocation, and an
            // embedded NUL is rejected deterministically.
            const src = vm.runtime.heap.strSliceOf(cell) orelse return error.BadArg;
            if (std.mem.indexOfScalar(u8, src, 0) != null) return error.BadArg;
            const scratch = &vm.runtime.host_scratch.bytes;
            const start = scratch.items.len;
            scratch.appendSlice(vm.allocator, src) catch return error.OutOfMemory;
            scratch.append(vm.allocator, 0) catch return error.OutOfMemory;
            break :blk @as([*:0]const u8, @ptrCast(scratch.items.ptr + start));
        },
        RawValue => .{ .value = cell },
        else => if (isOpaque(T))
            .{ .ptr = opaquePtr(vm, cell) orelse return error.BadArg }
        else
            @compileError("host binding: unsupported parameter type '" ++ @typeName(T) ++ "' (use a scalar, host.Str, host.Opaque(\"...\"), host.RawValue, or a raw() handler)"),
    };
}

fn callArgs(comptime f: anytype, comptime inject: bool, userdata: ?*anyopaque, dec: anytype) CallArgs(f) {
    const Fn = fnInfo(f);
    var t: CallArgs(f) = undefined;
    comptime var di: usize = 0;
    inline for (Fn.params, 0..) |_, i| {
        if (i == 0 and inject) {
            t[0] = userdata;
        } else {
            t[i] = dec[di];
            di += 1;
        }
    }
    return t;
}

fn encodeResult(comptime name: []const u8, vm: *VmCtx, sig: HostSignature, r: anytype) HostResult {
    const R = @TypeOf(r);
    return switch (R) {
        void => .{ .value = 0 },
        i32, c_int => .{ .value = ValueCodec.encodeInt32(r) },
        u32, c_uint => .{ .value = ValueCodec.encodeUint32(r) },
        i64 => .{ .value = @bitCast(r) },
        u64 => .{ .value = r },
        f32 => .{ .value = ValueCodec.encodeFloat32(r) },
        f64 => .{ .value = ValueCodec.encodeFloat64(r) },
        bool => .{ .value = ValueCodec.encodeBool(r) },
        Str => .{ .value = vm.runtime.heap.newStr(sig.desc.ret, r.bytes) catch return .{ .panic = comptime name ++ ": out of memory" } },
        RawValue => .{ .value = r.value },
        else => @compileError("host binding '" ++ name ++ "': unsupported return type '" ++ @typeName(R) ++ "' (use a scalar, host.Str, host.RawValue, or void)"),
    };
}

/// Generate one named `Binding` from a typed function: expected signature
/// at comptime, thunk that checks signature + arity, decodes, calls, and
/// encodes (docs/host-bindings.md §5).
fn makeBinding(comptime name: []const u8, comptime f: anytype) Binding {
    const inject = comptime injectsUserdata(f);
    const Fn = comptime fnInfo(f);
    const expected = comptime expectedOf(f);
    const want = comptime Fn.params.len - @intFromBool(inject);
    const sig_msg = comptime name ++ ": signature mismatch (interface and binding disagree)";
    const arity_msg = comptime name ++ ": wrong argument count";
    const bad_msg = comptime name ++ ": argument type mismatch";
    const oom_msg = comptime name ++ ": out of memory";
    return .{
        .name = name,
        .expected = expected,
        .thunk = &struct {
            fn thunk(vm: *VmCtx, userdata: ?*anyopaque, sig: HostSignature, args: []const Value) HostResult {
                if (!sig.matches(expected)) return .{ .panic = sig_msg };
                if (args.len != want) return .{ .panic = arity_msg };
                var dec: std.meta.Tuple(&paramTypes(f, inject)) = undefined;
                inline for (paramTypes(f, inject), 0..) |T, i| {
                    dec[i] = decodeArg(T, vm, args[i]) catch |e| return switch (e) {
                        error.BadArg => .{ .panic = bad_msg },
                        error.OutOfMemory => .{ .panic = oom_msg },
                    };
                }
                const r = @call(.auto, f, callArgs(f, inject, userdata, dec));
                return encodeResult(name, vm, sig, r);
            }
        }.thunk,
    };
}
