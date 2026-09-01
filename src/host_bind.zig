//! Typed host-binding layer (docs/host-bindings.md): comptime glue that
//! turns a plain Zig/C function into a registry `Binding` — signature
//! checked against the artifact before decoding, arguments decoded from
//! canonical cells, result encoded back. `raw()` remains the escape hatch
//! for ownership-sensitive members.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interp_types = @import("interpreter_types.zig");
const interpreter = @import("interpreter.zig");
const host_module = @import("host.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");

const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;
const HeapErr = vm_types.HeapErr;
const HostResult = interp_types.HostResult;
const HostSignature = interp_types.HostSignature;
const HostType = interp_types.HostType;
const HostDisposer = interp_types.HostDisposer;
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
// HostCtx — the adapter's VM-side context (docs/host-bindings.md §3.2)
// ---------------------------------------------------------------------------

/// Host-call-side VM mechanics (docs/interpreter-vm.md §9): a thin
/// wrapper around `VmCtx` exposing the decode, allocation, list-walk,
/// and trap helpers the stdlib module members share. A typed member
/// receives one as a hidden leading `*HostCtx` parameter (excluded from
/// the expected signature; `sig` is the current call's signature);
/// raw-shaped members construct one per call, and the callback-shaped
/// helpers (`hashmapKeyHash`/`hashmapKeyEq`, the disposers) reconstruct
/// it from their opaque `user` pointer.
pub const HostCtx = struct {
    vm: *VmCtx,
    /// The current syscall's signature (the typed thunk sets it when the
    /// member takes a hidden ctx; raw members read their `sig` parameter
    /// directly).
    sig: HostSignature = undefined,

    /// One str argument decoded from the canonical cells; null when
    /// absent or not a live str object.
    pub fn strArg(self: *const HostCtx, args: []const Value, i: usize) ?[]const u8 {
        if (i >= args.len) return null;
        return self.vm.runtime.heap.strSliceOf(args[i]);
    }

    /// One canonical int32 argument; null when absent or non-canonical.
    pub fn intArg(self: *const HostCtx, args: []const Value, i: usize) ?i32 {
        _ = self;
        if (i >= args.len) return null;
        return ValueCodec.decodeInt32(args[i]);
    }

    /// Owned panic message for an adapter-side allocation failure (reachable
    /// trap paths, e.g. a huge `list.range` — never a static string).
    pub fn oomPanic(self: *const HostCtx) HostResult {
        _ = self;
        return .{ .panic = "out of memory" };
    }

    /// Borrowed deterministic panic message (adapter trap paths): formatted
    /// into the VM's scratch buffer, which `sitePrefixed` copies into the
    /// owned Termination message before the buffer is reused.
    pub fn panicFmt(self: *const HostCtx, comptime fmt: []const u8, args: anytype) HostResult {
        const slice = std.fmt.bufPrint(&self.vm.runtime.panic_buf, fmt, args) catch return self.oomPanic();
        return .{ .panic = slice };
    }

    /// Map a string-handler error to an owned deterministic trap message
    /// (StdLib §5, Runtime §7.2): the shared `{member}: {spec message}`
    /// format (docs/host-bindings.md §5). OOM is a panic.
    pub fn stringErr(self: *const HostCtx, e: host_module.StringErr, member: []const u8) HostResult {
        if (e == error.OutOfMemory) return self.oomPanic();
        return errPanic(member, self.vm, e);
    }

    /// Allocate a str object holding `bytes`; OOM is a panic.
    pub fn newStrCell(self: *const HostCtx, ty: u32, bytes: []const u8) HostResult {
        const cell = self.vm.runtime.heap.newStr(ty, bytes) catch return self.oomPanic();
        return .{ .value = cell };
    }

    /// Build a list cons chain from element cells, right to left, with each
    /// node's suffix length recorded (the head's `len` is the element
    /// count — the O(1) read `list#len` and `read_index` rely on). The
    /// element cells are NOT retained: they are freshly-owned objects or
    /// scalars the chain takes over.
    pub fn newListCells(self: *const HostCtx, ty: u32, elems: []const Value) HeapErr!Value {
        var next: Value = 0;
        var suffix_len: u32 = 0;
        var k = elems.len;
        while (k > 0) {
            k -= 1;
            const h = try self.vm.runtime.heap.allocObjectIn(.list_cons, self.vm.curModIdx(), ty, 2, 0);
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
    pub fn optionCell(self: *const HostCtx, ty: u32, some: bool, payload: Value) HeapErr!Value {
        const h = try self.vm.runtime.heap.allocObject(.union_, ty, 1 + @as(usize, @intFromBool(some)), 0);
        h.setCell(0, if (some) 0 else 1);
        if (some) h.setCell(1, payload);
        return @intFromPtr(h);
    }

    /// Walk a list cons chain, appending each element cell to `out`. The
    /// element cells are not retained — callers convert them into fresh
    /// scalar cells or copy the referenced objects immediately.
    pub fn walkList(self: *const HostCtx, cell: Value, out: *std.ArrayList(Value)) HeapErr!void {
        var cur = cell;
        while (cur != 0) {
            const node = try self.vm.runtime.heap.deref(cur);
            if (node.kind != .list_cons) return error.TypeMismatch;
            try out.append(self.vm.allocator, node.cell(0));
            cur = node.cell(1);
        }
    }

    /// Resolve an opaque argument's host object; callers turn a null into
    /// their deterministic "not an <what>" trap. Unreachable in validated
    /// programs.
    pub fn arrayPayload(self: *const HostCtx, v: Value) ?*host_module.ArrayObject {
        const h = self.vm.runtime.heap.deref(v) catch return null;
        if (h.kind != .opaque_) return null;
        return @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    }

    pub fn mapPayload(self: *const HostCtx, v: Value) ?*host_module.HashMapObject {
        const h = self.vm.runtime.heap.deref(v) catch return null;
        if (h.kind != .opaque_) return null;
        return @ptrFromInt(@as(usize, @intCast(h.cell(0))));
    }

    /// StdLib §3: key type `K` must be hashable. `builtin.hash` covers the
    /// primitive scalar types and str; anything else (e.g. a list key,
    /// which the frontend does not reject today) is a deterministic trap
    /// before any mutation.
    pub fn checkHashableKey(self: *const HostCtx, map_ty: u32) bool {
        const row = self.vm.metaImage().types[map_ty];
        // The `named` arg range is `{ b = start, c = len }`.
        if (row.kind != .named or row.c == 0) return false;
        const k = self.vm.metaImage().types[row.b];
        return k.kind == .primitive and switch (@as(llir.PrimitiveId, @enumFromInt(k.a))) {
            .byte, .bool, .int32, .uint32, .float32, .str => true,
            else => false,
        };
    }

    /// Wyhash (seed 0) over str contents or the raw scalar cell —
    /// bit-identical to `builtin.hash` (Runtime §4.9).
    pub fn keyHash(self: *const HostCtx, key: Value) u64 {
        if (self.vm.runtime.heap.strSliceOf(key)) |bytes| return std.hash.Wyhash.hash(0, bytes);
        var v = key;
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&v));
    }

    /// Str content equality (mirroring `==`, `str_eq`) for str keys; raw
    /// cell equality for scalars.
    pub fn keyEq(self: *const HostCtx, a: Value, b: Value) bool {
        if (self.vm.runtime.heap.strSliceOf(a) != null) return vm_dispatch.strEqual(self.vm, a, b) catch false;
        return a == b;
    }

    /// Release one stored/displaced cell if it is a counted shell; scalars
    /// and unique (non-counted) Copy shells have no reference to drop.
    pub fn releaseCellIfCounted(self: *const HostCtx, addr: Value) HeapErr!void {
        if (addr == 0) return;
        const h = self.vm.runtime.heap.registry.get(addr) orelse return; // scalar cell
        if (!h.isCounted()) return;
        try vm_dispatch.releaseCounted(self.vm, addr);
    }

    /// Register a freshly built host object behind an opaque shell. On
    /// registration failure the shell is freed before the panic commits
    /// (docs/interpreter-vm.md §6.4: uncommitted-result disposal).
    pub fn wrapOpaque(self: *const HostCtx, ty: u32, obj: *anyopaque, disposer: HostDisposer) HostResult {
        const row = self.vm.metaImage().types[ty];
        if (row.kind != .named) return .{ .panic = "host object: unexpected result type" };
        const host_type_id = self.vm.metaImage().type_decls[row.a].a;
        const h = self.vm.runtime.heap.allocObject(.opaque_, ty, 1, 0) catch return self.oomPanic();
        h.setCell(0, @intFromPtr(obj));
        self.vm.registerHostResource(host_type_id, @intFromPtr(h), disposer, self.vm) catch {
            self.vm.runtime.heap.freeShell(h);
            return self.oomPanic();
        };
        return .{ .value = @intFromPtr(h) };
    }
};

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

fn lessBySymbol(_: void, a: RegisteredModule, b: RegisteredModule) bool {
    return std.mem.order(u8, a.desc.symbol, b.desc.symbol) == .lt;
}

/// Merge errors: `DuplicateModule` when two modules share a symbol.
pub const MergeError = error{ OutOfMemory, DuplicateModule };

/// Merge `extra` modules into `base` (e.g. `defaultHostRegistry`) into
/// a fresh array sorted by symbol — the binary-search invariant the
/// lookup relies on, enforced here instead of by the embedder. `extra`
/// may be unsorted; duplicate symbols (an embedder shadowing a stdlib
/// module, or two extras with the same symbol) are an error rather than
/// an ambiguous binary-search hit. The returned registry's `modules`
/// slice is allocated from `allocator`; the caller owns it.
pub fn mergeRegistry(
    allocator: std.mem.Allocator,
    base: HostRegistry,
    extra: []const RegisteredModule,
) MergeError!HostRegistry {
    const modules = try allocator.alloc(RegisteredModule, base.modules.len + extra.len);
    errdefer allocator.free(modules);
    @memcpy(modules[0..base.modules.len], base.modules);
    @memcpy(modules[base.modules.len..], extra);
    std.sort.insertion(RegisteredModule, modules, {}, lessBySymbol);
    for (modules[1..], 0..) |m, i| {
        if (std.mem.eql(u8, modules[i].desc.symbol, m.desc.symbol)) return error.DuplicateModule;
    }
    return .{ .modules = modules };
}

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
/// optional hidden leading parameter: `?*anyopaque` or `*T` module
/// userdata (the thunk casts the registered userdata to `*T` — no
/// per-member `@ptrCast` boilerplate) or `*HostCtx` adapter context).
/// Returns may be scalars, `void`, `Str`
/// (owned), `RawValue`, an error union over those (trapping with the
/// deterministic spec message, docs/host-bindings.md §5), or `HostResult`
/// verbatim (typed arguments, full raw body). Evaluate at comptime (a
/// top-level `const` or `comptime`); the derived member table must back a
/// global.
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

// ---------------------------------------------------------------------------
// Comptime interface derivation (interfaceOf): the Stilla `.st` text for
// a module struct, rendered from the same type mapping the registry uses
// — so the embedder's Zig signatures and the frontend's interface can't
// drift. Members that can't be derived (raw thunks, `RawValue`/`HostResult`
// returns — the concrete Stilla type lives only in the hand-written
// interface) are skipped; pass their lines as `extra`.
// ---------------------------------------------------------------------------

/// The Stilla type name for a binding type, or null when the type has no
/// derivable Stilla spelling.
fn hostTypeName(comptime T: type) ?[]const u8 {
    return switch (T) {
        i32, c_int => "int32",
        u32, c_uint => "uint32",
        i64 => "int64",
        u64 => "uint64",
        f32 => "float32",
        f64 => "float64",
        bool => "bool",
        Str, [*:0]const u8 => "str",
        else => null,
    };
}

/// One member as `fn <name>(<p0: t0, ...>) -> <ret>;\n`, or null when
/// the member's Stilla signature is not derivable from Zig (a
/// `RawValue`/`HostResult` return, or a parameter type with no Stilla
/// spelling) — skipped by `interfaceOf`, covered by its `extra` text.
fn renderMember(comptime name: []const u8, comptime f: anytype) ?[]const u8 {
    const hid = comptime hiddenKind(f) != .none;
    const ret = comptime retType(f);
    if (ret == RawValue or ret == HostResult) return null;
    const R = comptime if (ret == void) "void" else (hostTypeName(ret) orelse return null);
    const params = comptime paramTypes(f, hid);
    comptime var total = "fn ".len + name.len + 6 + R.len + 2; // "fn " name "(" ") -> " R ";\n"
    inline for (params, 0..) |T, i| {
        if (i > 0) total += 2; // ", "
        total += argName(i).len + 2; // "arg{i}: "
        total += (comptime hostTypeName(T) orelse return null).len;
    }
    comptime var buf: [total]u8 = undefined;
    comptime var pos: usize = 0;
    append(&buf, &pos, "fn ");
    append(&buf, &pos, name);
    append(&buf, &pos, "(");
    inline for (params, 0..) |T, i| {
        if (i > 0) append(&buf, &pos, ", ");
        append(&buf, &pos, argName(i));
        append(&buf, &pos, ": ");
        append(&buf, &pos, comptime hostTypeName(T).?);
    }
    append(&buf, &pos, ") -> ");
    append(&buf, &pos, R);
    append(&buf, &pos, ";\n");
    return &buf;
}

/// Positional Stilla parameter name — Zig's `Fn.Param` carries no name
/// in 0.16, and call sites are positional anyway, so `arg{i}` is used.
fn argName(comptime i: usize) []const u8 {
    return comptime std.fmt.comptimePrint("arg{d}", .{i});
}

/// Append `s` to `buf` at `pos` (comptime-only helper).
fn append(comptime buf: anytype, comptime pos: *usize, comptime s: []const u8) void {
    @memcpy(buf.*[pos.*..][0..s.len], s);
    pos.* += s.len;
}

/// Derive the module's `.st` interface text at comptime: every typed
/// (non-raw) member whose parameters and return all have a Stilla
/// spelling appears as a bodyless `fn` declaration, in declaration
/// order, with positional `arg0`/`arg1` parameter names (Zig's
/// `Fn.Param` carries no names; call sites are positional anyway). Members without a derivable
/// signature (raw thunks, `RawValue`/`HostResult` returns — e.g. a
/// list-returning member whose concrete Stilla type exists only in the
/// hand-written interface) are skipped; supply their lines as `extra`,
/// appended verbatim. Evaluate at comptime (a top-level `const`).
///
/// ```zig
/// const random_iface = host_bind.interfaceOf(random, "");
/// // "fn next() -> int32;\nfn int(max: int32) -> int32;\n..."
/// ```
pub inline fn interfaceOf(comptime M: type, comptime extra: []const u8) []const u8 {
    if (!@hasDecl(M, "symbol")) {
        @compileError("host_bind.interfaceOf: module struct must declare `pub const symbol`");
    }
    // The whole derivation runs at comptime even when the call site is
    // runtime (`const derived = interfaceOf(testdb, "")` in a fn body);
    // `inline` + the `const final` binding materialize the buffer as a
    // constant at the call site (same shape as std.fmt.comptimePrint).
    const text = comptime blk: {
        const names = memberFns(M);
        var parts: [names.len + @intFromBool(extra.len > 0)][]const u8 = undefined;
        var n: usize = 0;
        for (names) |name| {
            const f = @field(M, name);
            if (isRawThunk(@TypeOf(f))) continue; // no Stilla signature to derive
            if (renderMember(name, f)) |line| {
                parts[n] = line;
                n += 1;
            }
        }
        if (extra.len > 0) {
            parts[n] = extra;
            n += 1;
        }
        var total: usize = 0;
        for (parts[0..n]) |p| total += p.len;
        var buf: [total]u8 = undefined;
        var pos: usize = 0;
        for (parts[0..n]) |p| append(&buf, &pos, p);
        const final = buf;
        break :blk &final;
    };
    return text;
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

/// A hidden leading parameter: `?*anyopaque` module userdata, a typed
/// `*T` userdata (the thunk casts the registered userdata), or `*HostCtx`
/// adapter context — excluded from the expected signature, filled by the
/// generated thunk.
const Hidden = enum { none, userdata, userdata_typed, host_ctx };

fn hiddenKind(comptime f: anytype) Hidden {
    const Fn = fnInfo(f);
    if (Fn.params.len == 0) return .none;
    const T = paramType(Fn.params[0]);
    if (T == ?*anyopaque) return .userdata;
    if (T == *HostCtx) return .host_ctx;
    // Any other single pointer is a typed userdata (`*T`): the thunk
    // casts the registered userdata to `*T` at the call boundary, so
    // members read their state directly instead of casting `?*anyopaque`
    // themselves. Many-pointers (`[*:0]const u8` C strings) and fn
    // pointers stay ordinary parameters.
    if (@typeInfo(T) == .pointer) {
        const p = @typeInfo(T).pointer;
        if (p.size == .one and @typeInfo(p.child) != .@"fn") return .userdata_typed;
    }
    return .none;
}

/// The Stilla parameter types of `f` (excluding a hidden leading
/// parameter), as a comptime array value.
fn paramTypes(comptime f: anytype, comptime hide: bool) [fnInfo(f).params.len - @intFromBool(hide)]type {
    const Fn = fnInfo(f);
    comptime var ts: [Fn.params.len - @intFromBool(hide)]type = undefined;
    for (Fn.params[@intFromBool(hide)..], 0..) |p, i| ts[i] = paramType(p);
    return ts;
}

/// The fn's declared return type, with an error union unwrapped to its
/// payload.
fn retType(comptime f: anytype) type {
    const R = fnInfo(f).return_type orelse void;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

fn isErrorRet(comptime f: anytype) bool {
    return @typeInfo(fnInfo(f).return_type orelse void) == .error_union;
}

fn retHostType(comptime f: anytype) HostType {
    const R = retType(f);
    if (R == void) return .void;
    if (R == RawValue or R == HostResult) return .wildcard;
    return hostTypeOf(R);
}

fn expectedOf(comptime f: anytype) ExpectedSignature {
    const hide = comptime hiddenKind(f) != .none;
    const params = comptime blk: {
        var arr: [paramTypes(f, hide).len]interp_types.HostParam = undefined;
        for (paramTypes(f, hide), 0..) |T, i| {
            arr[i] = .{ .mode = .plain, .ty = hostTypeOf(T) };
        }
        break :blk arr;
    };
    return .{ .params = &params, .ret = retHostType(f) };
}

/// The bound function's full argument tuple type (hidden slot included).
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

fn callArgs(comptime f: anytype, comptime kind: Hidden, userdata: ?*anyopaque, hctx: *HostCtx, dec: anytype) CallArgs(f) {
    const Fn = fnInfo(f);
    var t: CallArgs(f) = undefined;
    comptime var di: usize = 0;
    inline for (Fn.params, 0..) |_, i| {
        if (i == 0 and kind != .none) {
            t[0] = switch (kind) {
                .userdata => userdata,
                .userdata_typed => @as(paramType(Fn.params[0]), @ptrCast(@alignCast(userdata orelse unreachable))),
                .host_ctx => hctx,
                .none => unreachable,
            };
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
        HostResult => r,
        else => @compileError("host binding '" ++ name ++ "': unsupported return type '" ++ @typeName(R) ++ "' (use a scalar, host.Str, host.RawValue, void, an error union over those, or HostResult)"),
    };
}

/// Deterministic trap text for a host error (docs/host-bindings.md §5):
/// the spec message for the stdlib string errors, else the error name.
fn errorMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.InvalidUtf8 => "invalid UTF-8",
        error.Range => "index out of range",
        error.BadCodepoint => "not a Unicode scalar value",
        error.OutOfMemory => "out of memory",
        else => @errorName(e),
    };
}

/// An error-returning member's trap: `"{name}: {spec message}"` formatted
/// into the VM's panic scratch (copied into the owned Termination message
/// before reuse, docs/interpreter-vm.md §10).
fn errPanic(name: []const u8, vm: *VmCtx, e: anyerror) HostResult {
    const msg = errorMessage(e);
    const slice = std.fmt.bufPrint(&vm.runtime.panic_buf, "{s}: {s}", .{ name, msg }) catch return .{ .panic = "out of memory" };
    return .{ .panic = slice };
}

/// Generate one named `Binding` from a typed function: expected signature
/// at comptime, thunk that checks signature + arity, decodes, calls, and
/// encodes (docs/host-bindings.md §5).
fn makeBinding(comptime name: []const u8, comptime f: anytype) Binding {
    const kind = comptime hiddenKind(f);
    const hide = kind != .none;
    const Fn = comptime fnInfo(f);
    const expected = comptime expectedOf(f);
    const want = comptime Fn.params.len - @intFromBool(hide);
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
                var dec: std.meta.Tuple(&paramTypes(f, hide)) = undefined;
                inline for (paramTypes(f, hide), 0..) |T, i| {
                    dec[i] = decodeArg(T, vm, args[i]) catch |e| return switch (e) {
                        error.BadArg => .{ .panic = bad_msg },
                        error.OutOfMemory => .{ .panic = oom_msg },
                    };
                }
                // The adapter context lives for the duration of the call
                // (a hidden `*HostCtx` member reads `vm`/`sig` through it).
                var hctx = HostCtx{ .vm = vm, .sig = sig };
                const r = if (comptime isErrorRet(f))
                    @call(.auto, f, callArgs(f, kind, userdata, &hctx, dec)) catch |e| return errPanic(name, vm, e)
                else
                    @call(.auto, f, callArgs(f, kind, userdata, &hctx, dec));
                return encodeResult(name, vm, sig, r);
            }
        }.thunk,
    };
}
