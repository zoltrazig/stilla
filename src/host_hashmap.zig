//! Host storage for the `hashmap` module (StdLib §3) — the open-
//! addressing hash table behind a `HashMap[K, V]` opaque handle (M3).
//! Plain data with no VM knowledge: the interpreter adapter
//! (`hostHashMap` in interpreter.zig) does all heap mechanics — it
//! retains entries on store, releases displaced cells, and frees
//! everything through the resource-registry disposer exactly once.

const std = @import("std");
const vm_types = @import("vm_types.zig");

/// A stored or displaced entry: the raw key and value cells. Whether a
/// displaced cell must be released is the adapter's decision.
pub const HashMapEntry = struct { key: vm_types.Value = 0, val: vm_types.Value = 0 };

/// Hash/equality hooks: str-aware comparators come from the adapter
/// (mirroring `builtin.hash` and `==`); a pure-cell scalar comparator
/// is what the white-box test below supplies.
pub const HashMapHashFn = *const fn (ctx: ?*anyopaque, key: vm_types.Value) u64;
pub const HashMapEqFn = *const fn (ctx: ?*anyopaque, a: vm_types.Value, b: vm_types.Value) bool;

/// A host-backed open-addressing hash table (linear probing,
/// power-of-two capacity, resize at ~70% load) behind a `HashMap[K, V]`
/// opaque handle. Cells are raw canonical values; element ownership is
/// the adapter's and the disposer's.
pub const HashMapObject = struct {
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
    hash_fn: HashMapHashFn,
    eq_fn: HashMapEqFn,
    entries: []Slot,
    count: usize = 0,

    const initial_cap = 8;

    const SlotState = enum { empty, used, dead };
    const Slot = struct { state: SlotState = .empty, key: vm_types.Value = 0, val: vm_types.Value = 0 };

    pub fn empty(
        allocator: std.mem.Allocator,
        ctx: ?*anyopaque,
        hash_fn: HashMapHashFn,
        eq_fn: HashMapEqFn,
    ) anyerror!*HashMapObject {
        const self = try allocator.create(HashMapObject);
        errdefer allocator.destroy(self);
        const entries = try allocator.alloc(Slot, initial_cap);
        @memset(entries, .{});
        self.* = .{ .allocator = allocator, .ctx = ctx, .hash_fn = hash_fn, .eq_fn = eq_fn, .entries = entries };
        return self;
    }

    pub fn deinit(self: *HashMapObject) void {
        self.allocator.free(self.entries);
        self.allocator.destroy(self);
    }

    /// Insert or overwrite. Returns the displaced entry on overwrite
    /// (the map keeps the original stored key cell; the adapter releases
    /// both displaced cells), null on a fresh insert.
    pub fn insert(self: *HashMapObject, key: vm_types.Value, val: vm_types.Value) anyerror!?HashMapEntry {
        // Resize before probing so a probe never runs off a full table.
        if ((self.count + 1) * 10 >= self.entries.len * 7) try self.grow();
        const h = self.hash_fn(self.ctx, key);
        var i: usize = h & (self.entries.len - 1);
        var first_dead: ?usize = null;
        var probes = self.entries.len;
        while (probes > 0) : (probes -= 1) {
            const e = &self.entries[i];
            switch (e.state) {
                .empty => {
                    const slot = first_dead orelse i;
                    self.entries[slot] = .{ .state = .used, .key = key, .val = val };
                    self.count += 1;
                    return null;
                },
                .dead => if (first_dead == null) {
                    first_dead = i;
                },
                .used => if (self.eq_fn(self.ctx, e.key, key)) {
                    const old = HashMapEntry{ .key = e.key, .val = e.val };
                    e.val = val;
                    return old;
                },
            }
            i = (i + 1) & (self.entries.len - 1);
        }
        return error.OutOfMemory; // unreachable: resized above
    }

    /// The value stored under an equal key, if any.
    pub fn get(self: *const HashMapObject, key: vm_types.Value) ?vm_types.Value {
        const i = self.find(key) orelse return null;
        return self.entries[i].val;
    }

    pub fn contains(self: *const HashMapObject, key: vm_types.Value) bool {
        return self.find(key) != null;
    }

    /// Remove an entry: returns its cells (the adapter releases the
    /// stored key and transfers the value into the result `Option`),
    /// null when the key is absent.
    pub fn remove(self: *HashMapObject, key: vm_types.Value) ?HashMapEntry {
        const i = self.find(key) orelse return null;
        const old = HashMapEntry{ .key = self.entries[i].key, .val = self.entries[i].val };
        self.entries[i] = .{ .state = .dead };
        self.count -= 1;
        return old;
    }

    pub fn len(self: *const HashMapObject) i32 {
        return @intCast(self.count);
    }

    /// A fresh table with the same entries in the same probe positions
    /// (element ownership is the adapter's: it retains each key/value).
    pub fn clone(self: *const HashMapObject) anyerror!*HashMapObject {
        const copy = try self.allocator.create(HashMapObject);
        errdefer self.allocator.destroy(copy);
        const entries = try self.allocator.alloc(Slot, self.entries.len);
        @memcpy(entries, self.entries);
        copy.* = .{
            .allocator = self.allocator,
            .ctx = self.ctx,
            .hash_fn = self.hash_fn,
            .eq_fn = self.eq_fn,
            .entries = entries,
            .count = self.count,
        };
        return copy;
    }

    fn find(self: *const HashMapObject, key: vm_types.Value) ?usize {
        if (self.count == 0) return null;
        const h = self.hash_fn(self.ctx, key);
        var i: usize = h & (self.entries.len - 1);
        var probes = self.entries.len;
        while (probes > 0) : (probes -= 1) {
            const e = &self.entries[i];
            if (e.state == .used and self.eq_fn(self.ctx, e.key, key)) return i;
            if (e.state == .empty) return null;
            i = (i + 1) & (self.entries.len - 1);
        }
        return null;
    }

    fn grow(self: *HashMapObject) !void {
        const old = self.entries;
        const entries = try self.allocator.alloc(Slot, old.len * 2);
        @memset(entries, .{});
        self.entries = entries;
        self.count = 0;
        for (old) |e| {
            if (e.state != .used) continue;
            // Fresh table cannot be full; probe terminates.
            var i: usize = self.hash_fn(self.ctx, e.key) & (entries.len - 1);
            while (entries[i].state == .used) i = (i + 1) & (entries.len - 1);
            entries[i] = .{ .state = .used, .key = e.key, .val = e.val };
            self.count += 1;
        }
        self.allocator.free(old);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "hashmap object: insert/get/contains/remove/len/clone with collisions and resize" {
    // Scalar-cell hash/eq (Wyhash seed 0 over the raw cell, mirroring
    // `builtin.hash`; `==` equality). Two keys that share a probe
    // slot exercise the collision path; > 5 inserts force the resize;
    // remove leaves a tombstone that find/insert handle.
    const hashCell = struct {
        fn f(ctx: ?*anyopaque, key: vm_types.Value) u64 {
            _ = ctx;
            var v = key;
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&v));
        }
    }.f;
    const eqCell = struct {
        fn f(ctx: ?*anyopaque, a: vm_types.Value, b: vm_types.Value) bool {
            _ = ctx;
            return a == b;
        }
    }.f;
    const m = try HashMapObject.empty(testing.allocator, null, hashCell, eqCell);
    defer m.deinit();
    try testing.expectEqual(@as(i32, 0), m.len());
    try testing.expectEqual(@as(?HashMapEntry, null), try m.insert(10, 100));
    try testing.expectEqual(@as(?HashMapEntry, null), try m.insert(20, 200));
    try testing.expectEqual(@as(i32, 2), m.len());
    try testing.expectEqual(@as(?vm_types.Value, 100), m.get(10));
    try testing.expect(m.contains(20));
    try testing.expect(!m.contains(30));
    // Overwrite reports the displaced entry and keeps the map's key.
    const old = (try m.insert(10, 111)).?;
    try testing.expectEqual(@as(vm_types.Value, 100), old.val);
    try testing.expectEqual(@as(vm_types.Value, 10), old.key);
    try testing.expectEqual(@as(?vm_types.Value, 111), m.get(10));
    // Force a resize (70% load of 8 slots).
    var k: u32 = 100;
    while (k < 110) : (k += 1) _ = try m.insert(k, k * 2);
    try testing.expectEqual(@as(i32, 12), m.len());
    try testing.expectEqual(@as(?vm_types.Value, 111), m.get(10));
    try testing.expectEqual(@as(?vm_types.Value, 218), m.get(109));
    // Remove + tombstone probing.
    const gone = m.remove(20).?;
    try testing.expectEqual(@as(vm_types.Value, 200), gone.val);
    try testing.expect(!m.contains(20));
    try testing.expectEqual(@as(i32, 11), m.len());
    try testing.expectEqual(@as(?HashMapEntry, null), m.remove(20));
    try testing.expectEqual(@as(?vm_types.Value, 111), m.get(10));
    const c = try m.clone();
    defer c.deinit();
    try testing.expectEqual(@as(i32, 11), c.len());
    try testing.expectEqual(@as(?vm_types.Value, 111), c.get(10));
    try testing.expect(!c.contains(20));
}

test "hashmap object: str keys need the adapter's str-aware comparators" {
    // The pure-cell defaults compare addresses; the interpreter adapter
    // installs content comparators (mirroring `builtin.hash`/`==`).
    const StrCmp = struct {
        fn hash(_: ?*anyopaque, key: vm_types.Value) u64 {
            const s: [*]const u8 = @ptrFromInt(@as(usize, @intCast(key)));
            return std.hash.Wyhash.hash(0, s[0..2]);
        }
        fn eq(_: ?*anyopaque, a: vm_types.Value, b: vm_types.Value) bool {
            const sa: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a)));
            const sb: [*]const u8 = @ptrFromInt(@as(usize, @intCast(b)));
            return std.mem.eql(u8, sa[0..2], sb[0..2]);
        }
    };
    const hi = "hi";
    const hi2 = "hi";
    const m = try HashMapObject.empty(testing.allocator, null, StrCmp.hash, StrCmp.eq);
    defer m.deinit();
    _ = try m.insert(@intFromPtr(&hi), 1);
    try testing.expect(m.contains(@intFromPtr(&hi2))); // equal contents, different cell
    try testing.expect(!m.contains(@intFromPtr("bye")));
}
