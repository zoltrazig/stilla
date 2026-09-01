//! VM value representation and scalar encoding.

const std = @import("std");
const llir = @import("llir.zig");

/// One raw VM cell. No bit pattern is reserved for type information.
pub const Value = u64;

/// One scalar decoded out of a canonical cell. The interpreter resolves
/// the declared type against the image and hands this plain view to host
/// handlers, so they never touch the VM or the type table.
pub const ScalarView = union(enum) {
    str: []const u8,
    byte: u8,
    bool_: bool,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    float32: f32,
    float64: f64,
};

/// Scalar representations supported by the VM's canonical cell codec.
pub const Scalar = enum { bool_, byte_, int32_, uint32_, float32_ };

/// IEEE 754 `fmin`: NaN propagates, `fmin(-0, +0) = -0` — Zig's
/// `@min` on floats does not fix the ±0 tie or propagate NaN the way
/// the StdLib `min`/`max` contract does (StdLib §4, Runtime §7.2).
/// Shared by the AIR `.min_f32`/`.min_f64` opcodes and the `math`
/// module host binding (M2).
pub fn fminIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

/// IEEE 754 `fmax`: NaN propagates, `fmax(-0, +0) = +0`.
pub fn fmaxIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(b)) a else b;
    return if (a > b) a else b;
}

pub const ValueCodec = struct {
    /// The canonical all-zero cell of every scalar type.
    pub const zero: Value = 0;

    pub fn encodeBool(v: bool) Value {
        return @intFromBool(v);
    }
    pub fn decodeBool(v: Value) ?bool {
        return switch (v) {
            0 => false,
            1 => true,
            else => null,
        };
    }
    pub fn encodeByte(v: u8) Value {
        return v;
    }
    pub fn decodeByte(v: Value) ?u8 {
        if (v >> 8 != 0) return null;
        return @truncate(v);
    }
    pub fn encodeInt32(v: i32) Value {
        return extendInt32Bits(@bitCast(v));
    }
    pub fn decodeInt32(v: Value) ?i32 {
        const low: u32 = @truncate(v);
        if (v != extendInt32Bits(low)) return null;
        return @bitCast(low);
    }
    pub fn encodeUint32(v: u32) Value {
        return extendInt32Bits(v);
    }
    pub fn decodeUint32(v: Value) ?u32 {
        const low: u32 = @truncate(v);
        if (v != extendInt32Bits(low)) return null;
        return low;
    }

    pub fn extendInt32Bits(v: u32) Value {
        return @bitCast(@as(i64, @as(i32, @bitCast(v))));
    }
    /// binary64 cells use all 64 bits.
    pub fn encodeFloat64(v: f64) Value {
        return @bitCast(v);
    }
    pub fn decodeFloat64(v: Value) f64 {
        return @bitCast(v);
    }
    pub fn encodeFloat32(v: f32) Value {
        return @as(u32, @bitCast(v));
    }
    pub fn decodeFloat32(v: Value) ?f32 {
        if (v >> 32 != 0) return null;
        return @bitCast(@as(u32, @truncate(v)));
    }
};

// ---------------------------------------------------------------------------
// Heap objects
// ---------------------------------------------------------------------------

/// One heap object header; payload cells follow it contiguously.
pub const ObjectHeader = struct {
    kind: ObjKind,
    /// The concrete TypeId this object was created for — a
    /// **module-local** id, interpreted through the declaring runtime
    /// module recorded in `type_mod` (per-artifact id spaces).
    type_id: u32,
    /// The runtime-module registry index whose artifact defines
    /// `type_id` (the allocating module). Destruction and type
    /// metadata resolve through it.
    type_mod: u32 = 0,
    /// str: byte length; list_cons: suffix length — the number of
    /// elements from this node to the end of the chain (the head
    /// node's length is the list's element count, so `list.len` is
    /// an O(1) read; `read_index` bounds-checks against it). Other
    /// kinds keep 0 payload bytes.
    len: u32,
    /// Per-object lifecycle tracking. Counted shells (`str`/`list`/`box`)
    /// carry their reference count; unique shells (tuple/struct/union/`any`/
    /// opaque) carry the once-per-object drop-hook flag.
    track: union(enum) {
        CopyValue: u32,
        /// Struct drop hooks run exactly once per object.
        UniqueValue: bool,
    },
    /// Number of payload Value slots following the header words.
    total_cells: usize = 0,
    // payloads
    cells: [*]Value,

    pub fn cell(self: *ObjectHeader, i: usize) Value {
        return self.cells[i];
    }
    pub fn setCell(self: *ObjectHeader, i: usize, v: Value) void {
        self.cells[i] = v;
    }

    /// Counted shells are reference-counted containers (`OwnMode.counted`
    /// in llir.zig); every other kind is uniquely owned and tracked by the
    /// drop-hook flag instead of a count.
    pub fn isCounted(self: *const ObjectHeader) bool {
        return self.kind == .str_ or self.kind == .list_cons or self.kind == .box_;
    }
};

pub const ObjKind = enum { str_, list_cons, box_, tuple_, struct_, union_, any_, opaque_ };

/// Header words resident before payload cells: the object header is
/// `Value`-aligned (it embeds a `[*]Value`), so its byte size divides
/// evenly into cells.
const hdr_cells = @sizeOf(ObjectHeader) / @sizeOf(Value);

/// Heap faults surfaced by allocation and provenance dereference.
pub const HeapErr = error{ ForgedPointer, NullDeref, TypeMismatch, OutOfMemory, StackOverflow, BadConstruct };

/// The VM heap: object allocation plus provenance-backed dereference.
/// Owns the allocator and the live-object registry; `newStr`/`decodeScalar`
/// and the interpreter's heap primitives all route through one instance.
///
/// The registry maps the full-width cell value to its header, so
/// membership is checked WITHOUT dereferencing the cell: forged scalars
/// and freed/stale addresses trap safely, and synthetic test-backed keys
/// above `0x0000_ffff_ffff_ffff` keep every host address bit.
pub const VmHeap = struct {
    allocator: std.mem.Allocator,
    /// Live-object provenance registry: full-width cell value → header.
    registry: std.AutoHashMapUnmanaged(u64, *ObjectHeader) = .empty,

    pub fn deinit(self: *VmHeap) void {
        self.registry.deinit(self.allocator);
    }

    /// Allocate one object; the returned cell value is the header's
    /// address. Counted shells start with one reference
    /// (`track.CopyValue`); unique shells start with the drop hook
    /// unrun (`track.UniqueValue`). The object joins the live-object
    /// registry immediately on success.
    pub fn allocObject(self: *VmHeap, kind: ObjKind, type_id: u32, payload_cells: usize, byte_len: u32) !*ObjectHeader {
        return self.allocObjectIn(kind, 0, type_id, payload_cells, byte_len);
    }

    /// `allocObject` with the allocating runtime module's registry index
    /// (the authority for interpreting `type_id`).
    pub fn allocObjectIn(self: *VmHeap, kind: ObjKind, type_mod: u32, type_id: u32, payload_cells: usize, byte_len: u32) !*ObjectHeader {
        const slack = (byte_len + @sizeOf(Value) - 1) / @sizeOf(Value);
        const total = hdr_cells + payload_cells + slack;
        const mem = try self.allocator.alloc(Value, total);
        errdefer self.allocator.free(mem);
        @memset(mem, 0);
        const h: *ObjectHeader = @ptrCast(@alignCast(mem.ptr));
        h.* = .{
            .kind = kind,
            .type_id = type_id,
            .type_mod = type_mod,
            .len = byte_len,
            .track = if (kind == .str_ or kind == .list_cons or kind == .box_)
                .{ .CopyValue = 1 }
            else
                .{ .UniqueValue = false },
            .total_cells = total - hdr_cells,
            .cells = mem.ptr + hdr_cells,
        };
        try self.registry.put(self.allocator, @intFromPtr(h), h);
        return h;
    }

    /// Free one shell's memory and drop its registry entry. The header
    /// lives in the first `hdr_cells` words of one allocation whose
    /// length we recover from the stored cell count.
    pub fn freeShell(self: *VmHeap, h: *ObjectHeader) void {
        _ = self.registry.remove(@intFromPtr(h));
        const total: usize = hdr_cells + h.total_cells;
        const mem: [*]Value = @ptrCast(h);
        self.allocator.free(mem[0..total]);
    }

    /// The fixed dereference order: registry membership (a pure table
    /// lookup — no pointer is dereferenced here) → alignment/range on
    /// the mapped header → expected-type cross-check. A zero cell under
    /// any non-list reference type rejects before lookup: null is only
    /// ever the empty list.
    pub fn deref(self: *VmHeap, addr: Value) HeapErr!*ObjectHeader {
        if (addr == 0) return error.NullDeref;
        // 1. membership by raw cell value — the mapped header pointer
        // comes from the table, so the cell itself is never
        // dereferenced (injected synthetic keys work identically).
        const h = self.registry.get(addr) orelse return error.ForgedPointer;
        // 2. alignment/range of the resolved header.
        if (@intFromPtr(h) % @alignOf(ObjectHeader) != 0) return error.ForgedPointer;
        return h;
    }

    /// Decode a live string resource without exposing the registry to
    /// value codecs or host adapters.
    pub fn strSliceOf(self: *VmHeap, cell: Value) ?[]const u8 {
        const h = self.deref(cell) catch return null;
        if (h.kind != .str_) return null;
        return @as([*]const u8, @ptrCast(h.cells))[0..h.len];
    }

    /// Allocate a str object holding `bytes`; the caller owns the returned cell.
    pub fn newStr(self: *VmHeap, ty: u32, bytes: []const u8) !Value {
        const h = try self.allocObject(.str_, ty, 0, @intCast(bytes.len));
        @memcpy(@as([*]u8, @ptrCast(h.cells))[0..bytes.len], bytes);
        return @intFromPtr(h);
    }
};

/// Decode one canonical cell into a `ScalarView` for a primitive id the
/// caller has already resolved from the image (and excluded `.hostdata`/
/// non-primitive types — the `else` arm still rejects them as a net). The
/// str decode is heap-backed. Unsupported ids and forged str cells are
/// `error.InvalidImage`; forged scalar cells decode leniently (as 0),
/// matching the previous formatter.
pub fn decodeScalar(heap: *VmHeap, pid: llir.PrimitiveId, cell: Value) !ScalarView {
    return switch (pid) {
        .byte => .{ .byte = @truncate(cell) },
        .int32 => .{ .int32 = ValueCodec.decodeInt32(cell) orelse 0 },
        .uint32 => .{ .uint32 = @truncate(cell) },
        .int64 => .{ .int64 = @as(i64, @bitCast(cell)) },
        .uint64 => .{ .uint64 = cell },
        .float32 => .{ .float32 = ValueCodec.decodeFloat32(cell) orelse 0 },
        .float64 => .{ .float64 = ValueCodec.decodeFloat64(cell) },
        .bool => .{ .bool_ = cell != 0 },
        .str => .{ .str = heap.strSliceOf(cell) orelse return error.InvalidImage },
        else => return error.InvalidImage,
    };
}

/// `builtin.str[T]` (Runtime §4.2): canonical decimal form of a decoded
/// scalar; a str view is returned unchanged.
pub fn formatView(view: ScalarView, buf: []u8) ![]const u8 {
    return switch (view) {
        .byte => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .int32 => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .uint32 => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .int64 => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .uint64 => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .float32 => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .float64 => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .bool_ => |v| std.fmt.bufPrint(buf, "{s}", .{if (v) "true" else "false"}),
        .str => |v| v,
    };
}

/// Result of one host-binding invocation.
pub const HostResult = union(enum) {
    value: Value,
    panic: []const u8,
    not_implemented: void,
};

test "value codec: canonical scalar cells round-trip" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(Value, 1), ValueCodec.encodeBool(true));
    try testing.expectEqual(@as(i32, -1), ValueCodec.decodeInt32(ValueCodec.encodeInt32(-1)).?);
    try testing.expectEqual(@as(f32, 1.5), ValueCodec.decodeFloat32(ValueCodec.encodeFloat32(1.5)).?);
}
