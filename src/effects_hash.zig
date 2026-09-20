//! Canonical fixed-width hashing primitives for the effect model
//! (docs/effects.md §13). Shared by the lattice interners, the engine's
//! carrier hash, and the environment fingerprint, so every digest and
//! hash-cons key uses one encoding: fixed-width little-endian integers
//! (never native byte order), length-delimited symbols, collections
//! canonicalized (sorted) before hashing.

const std = @import("std");
const lattice = @import("effects_lattice.zig");
const EffectResource = lattice.EffectResource;
const EffectAccess = lattice.EffectAccess;
const AccessSet = lattice.AccessSet;
const Summary = lattice.Summary;

// Fixed-width little-endian integer encoding: the fingerprint must not
// depend on the host's native byte order, or two machines would key the
// same environment differently. Counts ride `hashU64` even when the
// natural width is smaller, so a length can never be confused with a
// neighbouring field.
pub fn hashU8(h: *std.hash.Wyhash, v: u8) void {
    h.update(&.{v});
}

pub fn hashU32(h: *std.hash.Wyhash, v: u32) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    h.update(&buf);
}

pub fn hashU64(h: *std.hash.Wyhash, v: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    h.update(&buf);
}

pub fn hashResourceInto(h: *std.hash.Wyhash, r: EffectResource) void {
    hashU8(h, @intFromEnum(std.meta.activeTag(r)));
    switch (r) {
        .module_const => |x| hashU32(h, x),
        .host => |x| hashU32(h, x),
        .runtime => |x| hashU32(h, x),
        .extension => |x| {
            hashU32(h, x.provider);
            hashU32(h, x.resource);
        },
        .host_any, .top => {},
    }
}

pub fn hashAccessInto(h: *std.hash.Wyhash, a: EffectAccess) void {
    hashU8(h, @intFromEnum(a.mode));
    hashResourceInto(h, a.resource);
}

/// Hash a *canonical* access row (callers canonicalize first, so an
/// unsorted or `.top`-bearing hand-built `Summary` cannot collide with a
/// different canonical row).
pub fn hashAccessSetInto(h: *std.hash.Wyhash, set: AccessSet) void {
    hashU64(h, set.all);
    hashU64(h, set.accesses.len);
    for (set.accesses) |a| hashAccessInto(h, a);
}

pub fn hashSummaryInto(h: *std.hash.Wyhash, s: Summary) void {
    hashAccessSetInto(h, s.accesses);
    hashU8(h, @intFromBool(s.may_trap));
    hashU8(h, @intFromBool(s.may_diverge));
    hashU8(h, @intFromBool(s.nondeterministic));
}

pub fn resourceLessThan(_: void, a: EffectResource, b: EffectResource) bool {
    return a.lessThan(b);
}

pub fn resourcePairLessThan(_: void, a: [2]EffectResource, b: [2]EffectResource) bool {
    if (a[0].eql(b[0])) return a[1].lessThan(b[1]);
    return a[0].lessThan(b[0]);
}

pub fn hashResourceList(h: *std.hash.Wyhash, arena: std.mem.Allocator, list: []const EffectResource) std.mem.Allocator.Error!void {
    const stable = try arena.dupe(EffectResource, list);
    std.mem.sort(EffectResource, stable, {}, resourceLessThan);
    hashU64(h, stable.len);
    for (stable) |r| hashResourceInto(h, r);
}

/// Hash a pair collection in canonical (endpoint-sorted, then sorted)
/// order. Endpoint order carries no meaning, so it is normalized away.
pub fn hashResourcePairs(h: *std.hash.Wyhash, arena: std.mem.Allocator, pairs: anytype) std.mem.Allocator.Error!void {
    const canon = try arena.alloc([2]EffectResource, pairs.len);
    for (pairs, 0..) |pr, i| {
        canon[i] = if (pr.a.lessThan(pr.b)) .{ pr.a, pr.b } else .{ pr.b, pr.a };
    }
    std.mem.sort([2]EffectResource, canon, {}, resourcePairLessThan);
    hashU64(h, canon.len);
    for (canon) |pr| for (pr) |r| hashResourceInto(h, r);
}
