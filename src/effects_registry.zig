//! Resource-domain declarations (docs/effects.md §5.5–§5.6): `stable`
//! domains (all their ops are deterministic, so read/read pairs are
//! swappable even when the enclosing summary has `Q = 1`), and explicit
//! `disjoint` pairs. Everything undeclared overlaps conservatively.

const std = @import("std");
const lattice = @import("effects_lattice.zig");
const EffectResource = lattice.EffectResource;

/// Resource-domain declarations (docs/effects.md §5.5–§5.6): `stable`
/// domains (all their ops are deterministic, so read/read pairs are
/// swappable even when the enclosing summary has `Q = 1`), and explicit
/// `disjoint` pairs. Everything undeclared overlaps conservatively.
pub const ResourceRegistry = struct {
    stable: []const EffectResource = &.{},
    disjoint: []const Pair = &.{},

    pub const Pair = struct { a: EffectResource, b: EffectResource };

    pub fn isStable(self: ResourceRegistry, r: EffectResource) bool {
        for (self.stable) |s| {
            if (s.eql(r)) return true;
        }
        return false;
    }

    pub fn provablyDisjoint(self: ResourceRegistry, a: EffectResource, b: EffectResource) bool {
        for (self.disjoint) |p| {
            if ((p.a.eql(a) and p.b.eql(b)) or (p.a.eql(b) and p.b.eql(a))) return true;
        }
        return false;
    }
};
