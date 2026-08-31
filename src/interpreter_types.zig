//! Interpreter VM shared types (docs/interpreter-vm.md): the raw-cell
//! value model, module identity/loader contract, the runtime state
//! (`VmRuntimeState` — the execution position plus every per-run
//! execution resource), and the host-resource and destruction-work
//! records the interpreter and its adapters share.
//! No `VmCtx` dependency — loaded by `interpreter`, `interpreter_loader`,
//! `interpreter_dispatch`, and `interpreter_host`.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const ObjectHeader = vm_types.ObjectHeader;
const Value = vm_types.Value;
const VmHeap = vm_types.VmHeap;

// ---------------------------------------------------------------------------
// Header sentinels (interpreter-vm.md §7) — payload values only ever
// appear in their own header field; position distinguishes the two equal
// `0xffff_ffff` payloads.
// ---------------------------------------------------------------------------

/// Root `saved_fp`, `saved_fn`, and `saved_ra`: the root frame has no
/// caller — returning from it terminates normally. All three root
/// header cells carry this same payload, distinguished by position.
pub const invalid_pc: u32 = 0xffff_ffff;
/// Runtime-initiated call (module init / drop hook): `ret` resumes the
/// popped continuation instead of a caller pc.
pub const vm_internal_pc: u32 = 0xffff_fffe;

/// One decoded frame header. Field ranges are validated by `check`.
pub const FrameHeader = struct {
    saved_fp: u32,
    saved_fn: u32,
    saved_ra: u32,

    /// Range/sentinel validation, in place, before any use (§7):
    /// `saved_fp` is the caller's frame base — strictly below the
    /// current `fp` — or the root sentinel; `saved_ra` is an
    /// executable pc, the root sentinel, or the
    /// internal-continuation sentinel. When `saved_ra` is a real pc
    /// (or `vm_internal_pc`), `saved_fn` must be a real registry index
    /// whose code range contains that pc — O(1), position-consistent.
    pub fn check(self: FrameHeader, funcs: []const FnEntry, fp: u32) bool {
        if (self.saved_fp != invalid_pc and self.saved_fp >= fp) return false;
        switch (self.saved_ra) {
            invalid_pc => return self.saved_fp == invalid_pc and self.saved_fn == invalid_pc,
            vm_internal_pc => return self.saved_fn < funcs.len,
            else => {
                if (self.saved_fn >= funcs.len) return false;
                const f = funcs[self.saved_fn].desc;
                return self.saved_ra >= f.code_start and self.saved_ra < f.code_end;
            },
        }
    }
};

/// The VM's function registry entry: one loaded artifact's function,
/// relocated onto the VM instruction image. `mod` is the owning
/// `RuntimeModule` registry index (signature/type metadata resolves
/// through its artifact). `arity` is the signature shape packed into
/// one byte, resolved once at load so the call/return hot paths never
/// touch the signature table.
pub const FnEntry = struct {
    desc: llir.FunctionDesc,
    mod: u32,
    /// `params` (u7) + `ret` (u1) of the signature. The value area is
    /// derived at read time, so the stored state is the irreducible
    /// `(params, ret)` pair. `params` is bounded by the frame budget
    /// (frontend guarantee `params_len <= f_count <= 109`).
    arity: packed struct { params: u7, ret: u1 } = .{ .params = 0, .ret = 0 },

    /// The call value area `A = max(params, ret)`.
    pub fn a(self: FnEntry) u32 {
        return @max(@as(u32, self.arity.params), @as(u32, self.arity.ret));
    }
    /// Whether the signature returns a value (the `ret` is not `no_index`).
    pub fn hasRet(self: FnEntry) bool {
        return self.arity.ret != 0;
    }
};

test "FnEntry: 32-byte packed arity; a()/hasRet() over the degenerate pair" {
    // Measured layout: desc 24 + mod 4 + arity 1 = 29, padded to 32 at
    // alignment 4 (Zig packs the u16s inside FunctionDesc).
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(FnEntry));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(FnEntry));
    const p3r0 = FnEntry{ .desc = undefined, .mod = 0, .arity = .{ .params = 3, .ret = 0 } };
    try std.testing.expectEqual(@as(u32, 3), p3r0.a());
    try std.testing.expect(!p3r0.hasRet());
    const p3r1 = FnEntry{ .desc = undefined, .mod = 0, .arity = .{ .params = 3, .ret = 1 } };
    try std.testing.expectEqual(@as(u32, 3), p3r1.a());
    try std.testing.expect(p3r1.hasRet());
    // (P=0, R=1): the value area is one cell.
    const p0r1 = FnEntry{ .desc = undefined, .mod = 0, .arity = .{ .params = 0, .ret = 1 } };
    try std.testing.expectEqual(@as(u32, 1), p0r1.a());
    try std.testing.expect(p0r1.hasRet());
    const p0r0 = FnEntry{ .desc = undefined, .mod = 0, .arity = .{ .params = 0, .ret = 0 } };
    try std.testing.expectEqual(@as(u32, 0), p0r0.a());
    try std.testing.expect(!p0r0.hasRet());
}

/// The unique function containing `pc` across every loaded module's
/// relocated code ranges, or null. The registry is sorted by
/// `code_start` (the validator forces each artifact's functions to
/// tile its instruction space and `publishArtifact` appends them in
/// that order under a uniform base; modules concatenate), so this is
/// a binary search. It serves the direct `jal` target (a static
/// pc-relative immediate) and the dynamic `jalr` target (a runtime
/// value) on the call path.
pub fn functionAtPc(funcs: []const FnEntry, pc: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = funcs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const f = funcs[mid].desc;
        if (pc < f.code_start) {
            hi = mid;
        } else if (pc >= f.code_end) {
            lo = mid + 1;
        } else {
            return @intCast(mid);
        }
    }
    return null;
}

test "functionAtPc: binary search over tiled ranges" {
    // Hand-built registry mimicking two appended artifacts: module A's
    // functions tile [0, 10), module B's tile [10, 16).
    const fe = struct {
        fn e(start: u32, end: u32) FnEntry {
            return .{ .desc = .{ .code_start = start, .code_end = end, .entry_pc = start, .signature_id = 0, .f_count = 0, .x_count = 0, .window_count = 0 }, .mod = 0 };
        }
    };
    const funcs = [_]FnEntry{ fe.e(0, 4), fe.e(4, 10), fe.e(10, 13), fe.e(13, 16) };
    try std.testing.expectEqual(@as(?u32, null), functionAtPc(&funcs, 16)); // past the end
    try std.testing.expectEqual(@as(?u32, 0), functionAtPc(&funcs, 0));
    try std.testing.expectEqual(@as(?u32, 0), functionAtPc(&funcs, 3));
    try std.testing.expectEqual(@as(?u32, 1), functionAtPc(&funcs, 4)); // range boundary
    try std.testing.expectEqual(@as(?u32, 2), functionAtPc(&funcs, 11));
    try std.testing.expectEqual(@as(?u32, 3), functionAtPc(&funcs, 15));
    try std.testing.expectEqual(@as(?u32, null), functionAtPc(&.{}, 0));
}

// ---------------------------------------------------------------------------
// Runtime modules (Runtime Specification §2): load-once identity,
// atomic publication, initialize-once, reverse-order teardown.
//
// The load types (`ModuleState`, `ModuleLoader`, `LoadResult`,
// `LoadError`, `RuntimeModule`, `imageSelfSymbol`) and the loaded data
// (`VmLoadedData` and the loader functions) live in
// `interpreter_loader.zig`; the execution state (`VmRuntimeState`)
// stays here. This file
// keeps the shared records both sides read.
// ---------------------------------------------------------------------------

/// The result of resolving one import: a function VM pc, a module
/// slot value, a nested module handle, or a host-binding error.
pub fn readHeader(stack: []const Value, fp: u32) FrameHeader {
    const hb = fp - 3;
    return .{
        .saved_fp = @truncate(stack[hb + 0]),
        .saved_fn = @truncate(stack[hb + 1]),
        .saved_ra = @truncate(stack[hb + 2]),
    };
}

// ---------------------------------------------------------------------------
// Termination (docs/interpreter-vm.md §10)
// ---------------------------------------------------------------------------
pub const Termination = union(enum) {
    /// Normal completion: the root's returned raw cell (all-zero when
    /// the root returns no value or discards it).
    normal: Value,
    /// Language panic or runtime trap: owned message, free with the
    /// allocator passed to `run`.
    panic: []const u8,

    pub fn deinit(self: *Termination, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .normal => {},
            .panic => |m| allocator.free(m),
        }
    }
};

pub const RunError = error{ OutOfMemory, InvalidImage, InvalidArtifact, ContextAlreadyRun, StackOverflow, ForgedPointer, NullDeref, TypeMismatch, BadConstruct };

/// Result of one host-binding invocation.
pub const HostResult = vm_types.HostResult;

/// One pending runtime-initiated call (module init / drop hook). The
/// interrupted frame's identity is not recorded here — the frame header
/// already carries it (`saved_fp`/`saved_fn`; the interrupted `sp` is the
/// frame end, `frameEnd(saved_fp, funcs[saved_fn])`, since `sp` equals
/// `frameEnd(current frame)` at every instruction boundary). The
/// continuation carries only what the frozen three-cell header cannot:
/// the resume pc (the header's `saved_ra` is the `vm_internal_pc`
/// sentinel) and the kind that tells `returnFrom` what to do on return.
pub const Continuation = struct {
    /// The pc to resume at: for a module init, the triggering
    /// instruction (it re-executes now that the module is initialized);
    /// for a hook, the interrupted instruction (the destruction drain
    /// resumes from it, possibly arming the next hook).
    resume_pc: u32,
    kind: union(enum) { hook, module: u32 },
};

/// A registered host-owned resource: keyed by the full payload value.
pub const HostResource = struct {
    host_type_id: u32,
    disposer: HostDisposer,
    user: ?*anyopaque,
};

pub const HostDisposer = *const fn (user: ?*anyopaque, payload: u64) void;

/// Reusable per-call host scratch (docs/host-bindings.md §6): `values`
/// stages syscall arguments (one canonical cell per parameter), `bytes`
/// NUL-terminates C-string arguments for `bindC` thunks. Grows on
/// demand; nothing is allocated per executed instruction.
pub const HostScratch = struct {
    values: std.ArrayList(Value) = .empty,
    bytes: std.ArrayList(u8) = .empty,
};

/// Iterative destruction work items (docs/interpreter-vm.md §6.2) — no
/// host-stack recursion for deeply nested values.
pub const DestroyWork = union(enum) {
    /// Destroy `addr` as `type_id` (children first, then the shell).
    value: struct { type_id: u32, addr: Value },
    /// Free one object whose children are already handled.
    free_obj: *ObjectHeader,
    /// Resume a struct's destruction after its user drop hook returns.
    resume_struct: struct { type_id: u32, h: *ObjectHeader },
};

// ---------------------------------------------------------------------------
// Host signature interface (docs/host-bindings.md §3.0): the host-facing
// projection of a binding's Stilla signature. The syscall path resolves a
// `SignatureId` once into a zero-allocation `HostSignature` view and passes
// it across the host boundary; hosts never touch `TypeId` tables.
// ---------------------------------------------------------------------------

/// Host-facing projection of a Stilla type, resolved from a `TypeId`
/// through the artifact's `types`/`type_decls` tables. The typed binding
/// layer handles the primitive/str/opaque/hostdata/any subset; every other
/// type resolves to `.composite` (bindable only by a raw handler).
pub const HostType = enum {
    void,
    bool,
    byte,
    int32,
    uint32,
    i64,
    u64,
    float32,
    float64,
    str,
    any,
    hostdata,
    opaque_,
    composite,
    /// Expected-signature marker only (never resolved): matches any
    /// runtime type.
    wildcard,
};

/// One parameter's host-facing shape: declared mode plus resolved type.
pub const HostParam = struct {
    mode: llir.ParamMode,
    ty: HostType,
};

/// A comptime-declared expected signature (the contract a typed binding
/// promises) — plain data, no artifact. Built from the bound function's
/// Zig parameter types (docs/host-bindings.md §3.0, §5).
pub const ExpectedSignature = struct {
    params: []const HostParam,
    ret: HostType,
};

/// The signature interface: a zero-allocation view over the executing
/// artifact's signature row. The syscall path resolves `dd.signature_id`
/// once and passes this to every host thunk; raw handlers reach the raw
/// `desc`/`image` directly, typed bindings compare against an
/// `ExpectedSignature` via `matches` before decoding.
pub const HostSignature = struct {
    /// The artifact the signature row came from (the executing module's
    /// image; its types/params/signatures tables are seeded identically
    /// into every artifact of one compilation).
    image: *const llir.LlirProgram,
    /// The resolved signature row.
    desc: llir.SignatureDesc,

    pub inline fn paramCount(self: HostSignature) usize {
        return self.desc.params_len;
    }

    /// Parameter `i` (mode + resolved type). Out of range reads
    /// `.composite`/`.plain` rather than trapping — raw handlers may
    /// still reach the raw desc.
    pub inline fn param(self: HostSignature, i: usize) HostParam {
        if (i >= self.desc.params_len) return .{ .mode = .plain, .ty = .composite };
        const p = self.image.params[self.desc.params_start + i];
        return .{ .mode = p.mode, .ty = resolveHostType(self.image, p.type_) };
    }

    pub inline fn ret(self: HostSignature) HostType {
        // `void`/`never` results have no TypeDesc row — the artifact
        // writes the `no_index` sentinel (cfg_lower_llir_intern.zig).
        if (self.desc.ret == llir.no_index) return .void;
        return resolveHostType(self.image, self.desc.ret);
    }

    /// Element-wise compare against a comptime expected signature: param
    /// count, each param's mode and type, and the return type.
    /// `.wildcard` in `expected` matches any runtime type; `.composite`
    /// matches only `.composite`. A `move`-mode runtime parameter always
    /// fails (expected modes are plain/borrow — typed glue cannot honor
    /// ownership transfer).
    pub fn matches(self: HostSignature, expected: ExpectedSignature) bool {
        if (self.desc.params_len != expected.params.len) return false;
        for (expected.params, 0..) |e, i| {
            const a = self.param(i);
            if (a.mode != e.mode or a.mode == .move) return false;
            if (e.ty != .wildcard and a.ty != e.ty) return false;
        }
        const r = self.ret();
        if (expected.ret != .wildcard and r != expected.ret) return false;
        return true;
    }
};

/// Resolve a `TypeId` to its host-facing type (docs/host-bindings.md §3.0).
/// Unresolvable ids read `.composite`, never trap.
pub fn resolveHostType(image: *const llir.LlirProgram, type_id: u32) HostType {
    if (type_id >= image.types.len) return .composite;
    const t = image.types[type_id];
    return switch (t.kind) {
        .primitive => switch (@as(llir.PrimitiveId, @enumFromInt(t.a))) {
            .byte => .byte,
            .bool => .bool,
            .int32 => .int32,
            .uint32 => .uint32,
            .float32 => .float32,
            .str => .str,
            .any => .any,
            .hostdata => .hostdata,
            .i64 => .i64,
            .u64 => .u64,
            .f64 => .float64,
        },
        .named => blk: {
            if (t.a >= image.type_decls.len) break :blk .composite;
            break :blk switch (image.type_decls[t.a].kind) {
                .opaque_ => .opaque_,
                else => .composite,
            };
        },
        else => .composite,
    };
}

test "HostSignature: type resolution and matches" {
    const testing = std.testing;
    // Hand-built image: t0=int32, t1=str, t2=opaque(named→decl 0),
    // t3=list, t4=any. Same seeded-identically shape as real artifacts.
    var types = [_]llir.TypeDesc{
        .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int32), .b = 0, .c = 0 },
        .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.str), .b = 0, .c = 0 },
        .{ .kind = .named, .a = 0, .b = 0, .c = 0 },
        .{ .kind = .list, .a = 0, .b = 0, .c = 0 },
        .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.any), .b = 0, .c = 0 },
    };
    var decls = [_]llir.TypeDeclDesc{.{
        .kind = .opaque_,
        .a = 0,
        .b = 0,
        .c = 0,
        .d = 0,
        .e = 0,
    }};
    var params = [_]llir.ParamDesc{
        .{ .mode = .plain, .type_ = 0 }, // int32
        .{ .mode = .borrow, .type_ = 1 }, // str
        .{ .mode = .plain, .type_ = 2 }, // opaque
    };
    var signatures = [_]llir.SignatureDesc{
        .{ .params_start = 0, .params_len = 2, .ret = 0 },
        .{ .params_start = 2, .params_len = 1, .ret = 4 }, // opaque -> any
    };
    var image: llir.LlirProgram = undefined;
    image.types = &types;
    image.type_decls = &decls;
    image.params = &params;
    image.signatures = &signatures;

    try testing.expectEqual(HostType.int32, resolveHostType(&image, 0));
    try testing.expectEqual(HostType.str, resolveHostType(&image, 1));
    try testing.expectEqual(HostType.opaque_, resolveHostType(&image, 2));
    try testing.expectEqual(HostType.composite, resolveHostType(&image, 3)); // list
    try testing.expectEqual(HostType.composite, resolveHostType(&image, 99)); // out of range

    const sig = HostSignature{ .image = &image, .desc = signatures[0] };
    try testing.expectEqual(@as(usize, 2), sig.paramCount());
    try testing.expectEqual(HostType.int32, sig.param(0).ty);
    try testing.expectEqual(llir.ParamMode.plain, sig.param(0).mode);
    try testing.expectEqual(HostType.str, sig.param(1).ty);
    try testing.expectEqual(llir.ParamMode.borrow, sig.param(1).mode);
    try testing.expectEqual(HostType.int32, sig.ret());
    // Out-of-range accessor reads .composite/.plain, never traps.
    try testing.expectEqual(HostType.composite, sig.param(3).ty);

    // Exact match: plain int32 + borrow str -> int32.
    try testing.expect(sig.matches(.{ .params = &.{
        .{ .mode = .plain, .ty = .int32 },
        .{ .mode = .borrow, .ty = .str },
    }, .ret = .int32 }));
    // Mode mismatch rejected.
    try testing.expect(!sig.matches(.{ .params = &.{
        .{ .mode = .plain, .ty = .int32 },
        .{ .mode = .plain, .ty = .str },
    }, .ret = .int32 }));
    // Type mismatch rejected.
    try testing.expect(!sig.matches(.{ .params = &.{
        .{ .mode = .plain, .ty = .int32 },
        .{ .mode = .borrow, .ty = .any },
    }, .ret = .int32 }));
    // Count mismatch rejected.
    try testing.expect(!sig.matches(.{ .params = &.{
        .{ .mode = .plain, .ty = .int32 },
    }, .ret = .int32 }));
    // wildcard expected param matches any actual type.
    try testing.expect(sig.matches(.{ .params = &.{
        .{ .mode = .plain, .ty = .wildcard },
        .{ .mode = .borrow, .ty = .wildcard },
    }, .ret = .wildcard }));

    const sig2 = HostSignature{ .image = &image, .desc = signatures[1] };
    try testing.expect(sig2.matches(.{ .params = &.{
        .{ .mode = .plain, .ty = .opaque_ },
    }, .ret = .any }));
    // A runtime move param fails even when the expected type matches.
    params[2].mode = .move;
    try testing.expect(!sig2.matches(.{ .params = &.{
        .{ .mode = .plain, .ty = .opaque_ },
    }, .ret = .any }));
}

// ---------------------------------------------------------------------------
// Runtime state (docs/interpreter-vm.md §4, §8): where execution is. The
// loader functions leave it untouched except for the `reloadModule` quiesce
// check (`running`/`terminated`); `interpreter.zig` and
// `interpreter_dispatch.zig` own it. The loaded data it executes against
// (`VmLoadedData`) lives in `interpreter_loader.zig`.
// ---------------------------------------------------------------------------

/// The runtime state: the value stack, the register file, the execution
/// position, run status, the threaded-dispatch out-of-band state, and
/// every per-run execution resource (the heap, the host-resource and
/// string-constant registries, the destruction-work and continuation
/// stacks, the host argument buffer, and the
/// panic scratch buffer). Split out of the former `VmCore` (and the
/// former `VmCtx` per-run fields) so the loaded data (modules, the
/// decoded image, the function registry, root identity) and everything
/// that changes with the run are distinct structs owned separately by
/// `VmCtx` (`runtime` vs `loaded`). `VmRuntimeState.deinit` tears the
/// whole run down; the loaded data outlives it.
pub const VmRuntimeState = struct {
    /// The value stack: dynamic cells, hard-capped by `VmCtx.stack_limit`.
    stack: std.ArrayList(Value) = .empty,
    /// The directly-indexed fast bank: `zero` at index 0 (kept
    /// permanently all-zero — writes to `zero` drop), `cond` at index
    /// 1, `ra` at index 2 (a reserved call-convention hole — never a
    /// scratch cell), T0–T15 at indexes 3–18 (Instruction Set §3.1.1).
    /// A register read below `frame_base` is one bounds check and one
    /// indexed load.
    fast_regs: [llir.fast_reg_count]Value = .{0} ** llir.fast_reg_count,
    /// Execution position: the executing pc (an index into the loaded
    /// data's `code`), the stack pointer, the current frame base, and
    /// the executing function's registry index.
    pc: u32 = 0,
    sp: u32 = 0,
    fp: u32 = 0,
    current_fn: llir.FunctionId = 0,
    running: bool = false,
    terminated: bool = false,
    /// Threaded-dispatch out-of-band state (docs/interpreter-vm.md §7):
    /// handler functions return `void`; terminations, errors, and the
    /// hook-resume flag travel here instead of through call/return
    /// values.
    result: ?Termination = null,
    pending_err: ?RunError = null,
    /// Set by `returnFrom` when a drop-hook continuation resumed: the
    /// `ret` handler stops the chain so the run loop re-drives from the
    /// restored pc (a resumed hook's drain may have armed a new one).
    popped_hook_cont: bool = false,

    /// The interpreter's heap: allocation plus provenance dereference.
    heap: VmHeap,
    /// Registered host-owned resources, keyed by full payload value.
    host_resources: std.AutoHashMapUnmanaged(u64, HostResource) = .empty,
    /// Context-owned string constants (one reference for the whole run).
    string_consts: std.AutoHashMapUnmanaged(u64, Value) = .empty,
    /// Iterative destruction work stack.
    destroy_work: std.ArrayList(DestroyWork) = .empty,
    continuations: std.ArrayList(Continuation) = .empty,
    /// Per-call host scratch (values + C-string bytes).
    host_scratch: HostScratch = .{},
    /// Scratch buffer for `panicFmt` messages (borrowed; `sitePrefixed`
    /// copies into the owned Termination message and this is reused).
    panic_buf: [1024]u8 = undefined,

    pub fn deinit(self: *VmRuntimeState, allocator: std.mem.Allocator) void {
        self.heap.deinit();
        self.host_resources.deinit(allocator);
        self.string_consts.deinit(allocator);
        self.destroy_work.deinit(allocator);
        self.continuations.deinit(allocator);
        self.host_scratch.values.deinit(allocator);
        self.host_scratch.bytes.deinit(allocator);
        self.stack.deinit(allocator);
    }
};
