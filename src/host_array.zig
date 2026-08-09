//! Host storage for the `array` module (StdLib §2) — the contiguous
//! buffer behind an `Array[T]` opaque handle (M3). Plain data with no VM
//! knowledge: the interpreter adapter (`hostArray` in interpreter.zig)
//! does all heap mechanics — it retains elements on store, releases
//! displaced cells, and frees everything through the resource-registry
//! disposer exactly once. Indexing traps (Runtime §7.2) are reported as
//! `OutOfRange` and mapped to owned trap messages by the adapter.

const std = @import("std");
const vm_types = @import("vm_types.zig");

/// The `array` member names (StdLib §2, std/array.st); the adapter
/// resolves the syscall's member name through this enum.
pub const ArrayMember = enum { make, len, get, set, clone };

/// Errors an array handler reports; the adapter maps `OutOfRange` to an
/// owned deterministic trap message (Runtime §7.2).
pub const ArrayErr = error{ OutOfRange, OutOfMemory };

/// A host-backed contiguous buffer behind an `Array[T]` opaque handle.
/// Cells are raw canonical values: retaining/releasing counted elements
/// (str/list/box shells) is the adapter's and disposer's job.
pub const ArrayObject = struct {
    allocator: std.mem.Allocator,
    len: usize,
    cells: []vm_types.Value,

    /// StdLib §2 / Runtime §7.2: a negative length traps.
    pub fn make(allocator: std.mem.Allocator, n: i32, init: vm_types.Value) ArrayErr!*ArrayObject {
        if (n < 0) return error.OutOfRange;
        const cells = try allocator.alloc(vm_types.Value, @intCast(n));
        errdefer allocator.free(cells);
        @memset(cells, init);
        const self = try allocator.create(ArrayObject);
        self.* = .{ .allocator = allocator, .len = cells.len, .cells = cells };
        return self;
    }

    pub fn deinit(self: *ArrayObject) void {
        self.allocator.free(self.cells);
        self.allocator.destroy(self);
    }

    /// Runtime §7.2: a negative or `>= len` index traps.
    pub fn get(self: *const ArrayObject, i: i32) ArrayErr!vm_types.Value {
        if (i < 0 or i >= self.len) return error.OutOfRange;
        return self.cells[@intCast(i)];
    }

    /// Writes in place (StdLib §2: the host may mutate the buffer);
    /// returns the displaced cell for the adapter to release.
    pub fn set(self: *ArrayObject, i: i32, v: vm_types.Value) ArrayErr!vm_types.Value {
        if (i < 0 or i >= self.len) return error.OutOfRange;
        const old = self.cells[@intCast(i)];
        self.cells[@intCast(i)] = v;
        return old;
    }

    /// A fresh buffer with the same cells (element ownership is the
    /// adapter's: it retains each stored element once).
    pub fn clone(self: *const ArrayObject) ArrayErr!*ArrayObject {
        const cells = try self.allocator.alloc(vm_types.Value, self.len);
        errdefer self.allocator.free(cells);
        @memcpy(cells, self.cells);
        const copy = try self.allocator.create(ArrayObject);
        copy.* = .{ .allocator = self.allocator, .len = self.len, .cells = cells };
        return copy;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "array object: make/len/get/set/clone bounds and negative length" {
    // StdLib §2 / Runtime §7.2: negative length traps; get/set trap on
    // a negative or >= len index; set returns the displaced cell.
    try testing.expectError(error.OutOfRange, ArrayObject.make(testing.allocator, -1, 7));
    const a = try ArrayObject.make(testing.allocator, 3, 0);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.len);
    try testing.expectEqual(@as(vm_types.Value, 0), try a.get(0));
    try testing.expectEqual(@as(vm_types.Value, 0), try a.set(2, 9));
    try testing.expectEqual(@as(vm_types.Value, 9), try a.get(2));
    try testing.expectError(error.OutOfRange, a.get(3));
    try testing.expectError(error.OutOfRange, a.get(-1));
    try testing.expectError(error.OutOfRange, a.set(-1, 0));
    const b = try a.clone();
    defer b.deinit();
    try testing.expectEqual(@as(vm_types.Value, 9), try b.get(2));
    b.cells[0] = 5;
    try testing.expectEqual(@as(vm_types.Value, 0), try a.get(0)); // deep buffer copy
}
