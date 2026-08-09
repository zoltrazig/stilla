//! Interpreter VM shared types (docs/interpreter-vm.md): the raw-cell
//! value model, module identity/loader contract, and the host-resource
//! and destruction-work records the interpreter and its adapters share.
//! No `VmCtx` dependency — loaded by `interpreter`, `interpreter_dispatch`,
//! and `interpreter_host`.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const ObjectHeader = vm_types.ObjectHeader;
const Value = vm_types.Value;

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
// `LoadError`, `RuntimeModule`, `imageSelfSymbol`) and the run image
// (`VmCore` and the loader functions) moved to `interpreter_loader.zig`;
// this file
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
pub const Continuation = struct {
    caller_fn: u32,
    caller_sp: u32,
    resume_pc: u32,
    kind: union(enum) { hook, module: u32 },
};

/// One initialized module's slot teardown record, appended in
/// initialization order; normal teardown destroys in reverse.
pub const SlotRef = struct { mod: u32, slot: u32 };

/// A registered host-owned resource: keyed by the full payload value.
pub const HostResource = struct {
    host_type_id: u32,
    disposer: HostDisposer,
    user: ?*anyopaque,
};

pub const HostDisposer = *const fn (user: ?*anyopaque, payload: u64) void;

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
