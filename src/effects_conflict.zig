//! The §5.6 conflict queries over a resource registry
//! (docs/effects.md §5.6, §5.5): the free functions
//! `conflictOf` / `orderCompatible` / `stableReadPair`, the input to
//! `canSwapOperands` when no lattice engine is consulted. Rules:
//! undeclared resource pairs conflict (safe default); `All`/unknown modes
//! conflict; same-domain pairs go through the mode flags + a `stable`
//! declaration; the §5.5 `Q` veto has one carve-out — two `read_like`
//! accesses on the same declared-stable domain.

const std = @import("std");
const lattice = @import("effects_lattice.zig");
const registry_mod = @import("effects_registry.zig");
const EffectResource = lattice.EffectResource;
const EffectAccess = lattice.EffectAccess;
const ModeDecl = lattice.ModeDecl;
const ResourceRegistry = registry_mod.ResourceRegistry;
const Summary = lattice.Summary;
const isUnknownResource = lattice.isUnknownResource;
const isObservableEffectFree = lattice.isObservableEffectFree;
const modeDeclOf = lattice.modeDeclOf;
const default_modes = lattice.default_modes;

pub const Conflict = enum { commute, conflict };

/// The conflict rule of docs/effects.md §5.6, the input to
/// `canSwapOperands`. Undeclared resource pairs conflict (safe
/// default); `All`/unknown modes conflict.
pub fn conflictOf(a: EffectAccess, b: EffectAccess, reg: ResourceRegistry) Conflict {
    return conflictOfWith(a, b, reg, &default_modes);
}

/// The instance-parameterized flat conflict rule: the mode flags come
/// from the provider, the resource relation from the registry.
fn conflictOfWith(a: EffectAccess, b: EffectAccess, reg: ResourceRegistry, modes: []const ModeDecl) Conflict {
    if (isUnknownResource(a.resource) or isUnknownResource(b.resource)) return .conflict;
    if (a.resource.eql(b.resource)) {
        const da = modeDeclOf(modes, a.mode) orelse return .conflict;
        const db = modeDeclOf(modes, b.mode) orelse return .conflict;
        return if (da.commutative and db.commutative and reg.isStable(a.resource)) .commute else .conflict;
    }
    if (reg.provablyDisjoint(a.resource, b.resource)) return .commute;
    return .conflict;
}

/// Order-compatibility of two summaries for the value positions they
/// occupy: no conflicting resource access; a may-trap/-diverge value must
/// not cross the other's observable accesses; two potentially-failing
/// positions are refused (their failure order is observable); and a
/// nondeterministic (`Q`) summary is refused unless the pair is a stable
/// same-domain read pair (§5.5 carve-out).
pub fn orderCompatible(a: Summary, b: Summary, reg: ResourceRegistry) bool {
    const a_fail = a.may_trap or a.may_diverge;
    const b_fail = b.may_trap or b.may_diverge;
    // Two potential failures: which trap/divergence happens first is
    // itself observable (§5.6 "无 trap/diverge 顺序可观察差异" is an input).
    if (a_fail and b_fail) return false;
    if (a_fail and !isObservableEffectFree(b)) return false;
    if (b_fail and !isObservableEffectFree(a)) return false;
    // `Q` vetoes reordering the expression as a whole (§5.5); the only
    // carve-out is two reads on the same declared-stable domain.
    if ((a.nondeterministic or b.nondeterministic) and !stableReadPair(a, b, reg)) return false;
    if (a.accesses.all != 0 or b.accesses.all != 0) {
        // Wildcarded accesses: no wildcard can establish a stable
        // domain or a disjoint pair.
        return false;
    }
    for (a.accesses.accesses) |x| {
        for (b.accesses.accesses) |y| {
            if (conflictOfWith(x, y, reg, &default_modes) == .conflict) return false;
        }
    }
    return true;
}

/// The §5.5 `stable` carve-out: the sole pair for which a summary-level
/// `Q` does not veto a swap — both summaries' accesses are reads, and
/// every cross pair is the *same* read on a declared-stable domain.
fn stableReadPair(a: Summary, b: Summary, reg: ResourceRegistry) bool {
    if (a.accesses.all != 0 or b.accesses.all != 0) return false;
    var any = false;
    for (a.accesses.accesses) |x| {
        const dx = modeDeclOf(&default_modes, x.mode) orelse return false;
        if (!dx.read_like) return false;
        for (b.accesses.accesses) |y| {
            const dy = modeDeclOf(&default_modes, y.mode) orelse return false;
            if (!dy.read_like) return false;
            if (!x.resource.eql(y.resource) or !reg.isStable(x.resource)) return false;
            any = true;
        }
    }
    return any;
}
// ===========================================================================
// Tests — §5.6 conflict queries over a registry
// ===========================================================================

const testing = std.testing;

const AccessSet = lattice.AccessSet;
const HostDomainId = lattice.HostDomainId;
const canonicalize = lattice.canonicalize;
const pure = lattice.pure;
const may_trap = lattice.may_trap;

fn host(r: HostDomainId) EffectResource {
    return .{ .host = r };
}

fn readOf(r: EffectResource) EffectAccess {
    return .{ .resource = r, .mode = .read };
}

fn writeOf(r: EffectResource) EffectAccess {
    return .{ .resource = r, .mode = .write };
}

/// Canonical access set fixture.
fn mkSet(arena: std.mem.Allocator, raw: []const EffectAccess) !AccessSet {
    var buf = std.ArrayList(EffectAccess).empty;
    for (raw) |x| try buf.append(arena, x);
    return canonicalize(arena, buf.items, 0);
}

/// Summary fixture (pure controls unless overwritten).
fn mks(arena: std.mem.Allocator, raw: []const EffectAccess) !Summary {
    return .{ .accesses = try mkSet(arena, raw), .may_trap = false, .may_diverge = false, .nondeterministic = false };
}

test "effects: conflict rules and stable domains" {
    const dom1 = host(1);
    const dom2 = host(2);
    const reg = ResourceRegistry{ .stable = &.{dom2}, .disjoint = &.{.{ .a = dom1, .b = dom2 }} };

    try testing.expectEqual(Conflict.conflict, conflictOf(readOf(dom1), readOf(dom1), .{}));
    try testing.expectEqual(Conflict.commute, conflictOf(readOf(dom2), readOf(dom2), reg));
    try testing.expectEqual(Conflict.conflict, conflictOf(readOf(dom1), writeOf(dom1), reg));
    try testing.expectEqual(Conflict.conflict, conflictOf(writeOf(dom2), readOf(dom2), reg));
    // Undeclared distinct domains conflict; declared disjoint pairs commute.
    try testing.expectEqual(Conflict.conflict, conflictOf(readOf(host(3)), readOf(host(4)), reg));
    try testing.expectEqual(Conflict.commute, conflictOf(readOf(dom1), readOf(dom2), reg));
    // Unknown (wildcard) always conflicts.
    try testing.expectEqual(Conflict.conflict, conflictOf(readOf(.top), readOf(host(9)), reg));
}
test "effects: order compatibility rejects conflicting swings and trap crossings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try mks(a, &.{readOf(host(1))});
    const w1 = try mks(a, &.{writeOf(host(1))});
    const w2 = try mks(a, &.{writeOf(host(2))});
    try testing.expect(!orderCompatible(r1, w1, .{})); // read/write same domain
    try testing.expect(!orderCompatible(w1, w2, .{})); // two writes, undeclared
    try testing.expect(!orderCompatible(may_trap, w2, .{})); // trap crossing a write
    try testing.expect(orderCompatible(may_trap, r1, .{})); // trap crossing a read
    // Same-domain reads commute only under a stable declaration.
    try testing.expect(!orderCompatible(r1, try mks(a, &.{readOf(host(1))}), .{}));
    const stable = ResourceRegistry{ .stable = &.{host(1)} };
    try testing.expect(orderCompatible(r1, try mks(a, &.{readOf(host(1))}), stable));
    // Two potentially-failing positions: failure order is observable.
    const diverge = Summary{ .accesses = .{}, .may_trap = false, .may_diverge = true, .nondeterministic = false };
    try testing.expect(!orderCompatible(may_trap, may_trap, .{}));
    try testing.expect(!orderCompatible(may_trap, diverge, .{}));
    // `Q` vetoes a swap unless the pair is a stable same-domain read
    // pair: here the reads are on disjoint (declared) domains, so the
    // whole-expression veto applies even though the resources commute.
    const qread = Summary{ .accesses = try mkSet(a, &.{readOf(host(3))}), .may_trap = false, .may_diverge = false, .nondeterministic = true };
    const disjoint = ResourceRegistry{ .disjoint = &.{.{ .a = host(3), .b = host(4) }} };
    try testing.expect(!orderCompatible(qread, try mks(a, &.{readOf(host(4))}), disjoint));
    try testing.expect(!orderCompatible(qread, pure, .{}));
}
test "effects: stable read pairs commute despite a summary-level Q (domain carve-out)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two reads on the same domain, both carrying Q from another domain
    // (docs/effects.md §5.5: a `stable` declaration refines the *pair*
    // query, not the whole-expression Q veto).
    const s = Summary{
        .accesses = try mkSet(a, &.{readOf(host(1))}),
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = true,
    };
    var stable = [_]EffectResource{host(1)};
    try testing.expect(orderCompatible(s, s, .{ .stable = &stable }));
    // Mixed (undeclared) domain: the same read pair is not order-compatible.
    try testing.expect(!orderCompatible(s, s, .{}));
    // A write on a declared-stable domain still conflicts.
    const w = Summary{
        .accesses = try mkSet(a, &.{writeOf(host(1))}),
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = false,
    };
    try testing.expect(!orderCompatible(w, s, .{ .stable = &stable }));
}
