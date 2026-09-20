//! The effect-model element lattice (docs/effects.md §5.1–§5.4, §5.7,
//! §10.1): the summary element `(A, may_trap, may_diverge,
//! nondeterministic)`, its access-row algebra (per-mode wildcard +
//! canonical concrete accesses), the `Summary` combinators and derived
//! facts, the pending/ready `State`, and the `Interner`. This is the
//! lattice-algebra core; the instance machinery (providers, `Ops`,
//! `Engine`, instances) lives in effects_engine.zig, the host metadata
//! in effects_host.zig, the §5.6 conflict queries in
//! effects_conflict.zig.
//!
//! `Pure == Bottom` (§5.4): `(∅, false, false, false)` is both the
//! lattice bottom and "proved pure"; the difference between "bottom
//! approximation" and "proved pure" is `State`, not a lattice value.

const std = @import("std");
const hash = @import("effects_hash.zig");
const hashResourceInto = hash.hashResourceInto;

/// Dense ids owned by the surrounding program; mirrored so this module
/// stays independent of the HIR (hir.md §3.5 category 3).
pub const ConstId = u32;
pub const HostBindingId = u32;
pub const HostDomainId = u32;
pub const RuntimeDomainId = u32;
pub const ProviderId = u32;
pub const ResourceId = u32;

// ---------------------------------------------------------------------------
// Modes, resources, accesses (docs/effects.md §5.1–§5.2, §5.7)
// ---------------------------------------------------------------------------

/// A per-access mode. Non-exhaustive on purpose: the four built-in modes
/// are named here and every provider must declare them, but a provider
/// may register more (docs/effects.md §5.7). The *declared* set — owned
/// by the `Engine`, not this enum — is what every query consults; a
/// value outside it is an invalid declaration.
pub const ModeId = enum(u8) {
    read,
    write,
    allocate,
    release,
    _,
};

/// The built-in vocabulary (docs/effects.md §5.4), retained so call
/// sites keep reading `EffectMode.read` and friends.
pub const EffectMode = ModeId;

/// Number of built-in modes — the least common denominator a provider
/// declares (docs/effects.md §5.7).
pub const mode_count: usize = 4;

/// Upper bound on a provider's declared mode set: `ModeSet` is one bit
/// per mode id (docs/effects.md §5.7).
pub const max_mode_count: usize = 64;

/// The wildcarded modes of one access row (`All_m`, docs/effects.md
/// §5.4), one bit per declared mode id.
pub const ModeSet = u64;

/// The bit naming `m` in a `ModeSet`. An out-of-range id has no bit: the
/// engine rejects such a declaration at construction (docs/effects.md
/// §5.7), so this is only reachable from a hand-built invalid row.
pub fn modeBit(m: ModeId) ModeSet {
    const i = @intFromEnum(m);
    if (i >= max_mode_count) return 0;
    return @as(ModeSet, 1) << @intCast(i);
}

/// Every built-in mode wildcarded — the default instance's `All` row and
/// the `Top` of the pre-engine model.
pub const builtin_mode_set: ModeSet = (1 << mode_count) - 1;

/// One provider-declared mode (docs/effects.md §5.7). The three flags are
/// the whole of a mode's contribution to the derived queries; everything
/// else about a mode is its id.
pub const ModeDecl = struct {
    id: ModeId,
    name: []const u8,
    /// Whether two accesses of this mode on the *same* resource commute
    /// when the resource is declared `stable` (docs/effects.md §5.6). The
    /// same-resource commute relation is the product of the participating
    /// modes: a pair commutes only when *both* sides set this. True for
    /// `read`.
    commutative: bool,
    /// Whether the mode additionally qualifies for the §5.5 `Q`
    /// carve-out (a `stable` same-resource pair the summary-level `Q` does
    /// not veto). Deliberately narrower than `commutative`: the carve-out
    /// is defined for *reads*, so a provider mode must opt in explicitly
    /// rather than inherit it from `commutative`.
    read_like: bool = false,
    /// Discarding an expression carrying an access of this mode is
    /// observable (docs/effects.md §10.1). False for `read`.
    observable: bool,
    /// `discard_view` drops accesses of this mode (docs/effects.md
    /// §10.1). True for `read`.
    discardable: bool,
};

/// The default instance's mode set, the four built-ins (docs/effects.md
/// §5.4). Every provider declares at least these.
pub const default_modes = [mode_count]ModeDecl{
    .{ .id = .read, .name = "read", .commutative = true, .read_like = true, .observable = false, .discardable = true },
    .{ .id = .write, .name = "write", .commutative = false, .observable = true, .discardable = false },
    .{ .id = .allocate, .name = "allocate", .commutative = false, .observable = true, .discardable = false },
    .{ .id = .release, .name = "release", .commutative = false, .observable = true, .discardable = false },
};

pub fn modeDeclOf(modes: []const ModeDecl, id: ModeId) ?ModeDecl {
    for (modes) |d| {
        if (d.id == id) return d;
    }
    return null;
}

pub fn modeDeclLessThan(_: void, a: ModeDecl, b: ModeDecl) bool {
    return @intFromEnum(a.id) < @intFromEnum(b.id);
}

/// Per-operand value use (docs/effects.md §4) — an occurrence-level
/// ownership fact, deliberately *not* an effect: `move` is a linear
/// effect with an empty `EffectSummary`. The declaration side is
/// `BinderMode` (hir.md §3.4); there is no third vocabulary.
pub const OperandUse = enum { read, borrow, consume };

/// Abstract semantic resources (docs/effects.md §5.2). `top` is the
/// wildcard identity used when declaring "any resource of this mode";
/// it is canonicalized away (see `AccessSet`).
pub const EffectResource = union(enum) {
    module_const: ConstId,
    host: HostDomainId,
    runtime: RuntimeDomainId,
    extension: Extension,
    /// Any host/extension resource, but **not** a Stilla `ModuleConst`
    /// (docs/effects.md §13). It appears only in a binding whose embedding
    /// attests `StillaExecution.forbidden` — attests, that is, that the
    /// binding executes no Stilla code and so cannot reach a module
    /// constant. A binding with *no* declaration is the full `top`
    /// (module-const read wildcard included), and so are genuinely
    /// unknown Stilla targets.
    host_any,
    top,

    pub const Extension = struct { provider: ProviderId, resource: ResourceId };

    pub fn eql(a: EffectResource, b: EffectResource) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .module_const => |x| x == b.module_const,
            .host => |x| x == b.host,
            .runtime => |x| x == b.runtime,
            .extension => |x| x.provider == b.extension.provider and x.resource == b.extension.resource,
            .host_any, .top => true,
        };
    }

    /// Stable ordering for canonical rows: kind, then payload.
    pub fn lessThan(a: EffectResource, b: EffectResource) bool {
        const ta = @intFromEnum(std.meta.activeTag(a));
        const tb = @intFromEnum(std.meta.activeTag(b));
        if (ta != tb) return ta < tb;
        return switch (a) {
            .module_const => |x| x < b.module_const,
            .host => |x| x < b.host,
            .runtime => |x| x < b.runtime,
            .extension => |x| x.provider < b.extension.provider or
                (x.provider == b.extension.provider and x.resource < b.extension.resource),
            .host_any, .top => false,
        };
    }
};

/// A resource naming "any resource" rather than one domain
/// (docs/effects.md §5.7): `.top` always, `.host_any` always ("any
/// host/extension resource, but not a Stilla `ModuleConst`", §13). An
/// `Engine` may declare one more.
pub fn isUnknownResource(r: EffectResource) bool {
    return switch (r) {
        .top, .host_any => true,
        else => false,
    };
}

/// Hash/equality for `EffectResource`-keyed maps (`std.HashMapUnmanaged`
/// needs an explicit context because the resource is a union).
pub const ResourceCtx = struct {
    pub fn hash(_: ResourceCtx, r: EffectResource) u64 {
        var h = std.hash.Wyhash.init(0);
        hashResourceInto(&h, r);
        return h.final();
    }

    pub fn eql(_: ResourceCtx, a: EffectResource, b: EffectResource) bool {
        return a.eql(b);
    }
};

/// Provider-declared resource aliasing (docs/effects.md §5.7): the frozen
/// `resource -> canonical resource` map. Only resources the provider
/// named can be aliased; everything else is its own identity. The map is
/// empty for the default instance.
pub const AliasMap = std.HashMapUnmanaged(EffectResource, EffectResource, ResourceCtx, std.hash_map.default_max_load_percentage);

fn canonicalResource(alias: ?*const AliasMap, r: EffectResource) EffectResource {
    const map = alias orelse return r;
    return map.get(r) orelse r;
}

/// The resource-level facts the canonicalizer needs from an instance
/// (docs/effects.md §5.7). Only the *unknown* resource folds into a
/// mode's `All` bit; `.host_any` stays a concrete access that conflicts
/// with everything (docs/effects.md §13), which is why folding and
/// `isUnknownResource` are two different predicates.
pub const CanonCtx = struct {
    alias: ?*const AliasMap = null,
    /// One more resource that folds into `All`, on top of `.top`, which
    /// always does.
    extra_unknown: ?EffectResource = null,
    /// The instance's resource *inclusion* relation, as transitive
    /// `{ancestor, descendant}` pairs including self (docs/effects.md
    /// §5.7). Empty for the product instance, whose components are
    /// ordinary sets; the hierarchy instance fills it, so canonicalizing
    /// an access to `r` also records every declared descendant of `r`.
    descend: []const [2]EffectResource = &.{},

    fn folds(self: CanonCtx, r: EffectResource) bool {
        if (r == .top) return true;
        const u = self.extra_unknown orelse return false;
        return r.eql(u);
    }
};

pub const EffectAccess = struct {
    resource: EffectResource,
    mode: EffectMode,
};

fn accessLessThan(_: void, a: EffectAccess, b: EffectAccess) bool {
    if (a.mode != b.mode) return @intFromEnum(a.mode) < @intFromEnum(b.mode);
    return a.resource.lessThan(b.resource);
}

// ---------------------------------------------------------------------------
// Access sets (per-mode wildcard + canonical concrete accesses)
// ---------------------------------------------------------------------------

/// One expression's resource-access row (the `A` component of the
/// summary lattice). `all` is the set of modes whose component is `All` —
/// the wildcard above every ordinary resource set, including resources
/// registered later (docs/effects.md §5.4).
pub const AccessSet = struct {
    all: ModeSet = 0,
    /// Canonical: sorted by (mode, resource), deduplicated, never
    /// carries an unknown resource (that folds into `all`), and never
    /// lists a mode whose `all` bit is set.
    accesses: []const EffectAccess = &.{},

    pub const empty: AccessSet = .{};
    pub const top: AccessSet = .{ .all = builtin_mode_set };

    pub fn eql(a: AccessSet, b: AccessSet) bool {
        if (a.all != b.all) return false;
        if (a.accesses.len != b.accesses.len) return false;
        for (a.accesses, b.accesses) |x, y| {
            if (x.mode != y.mode or !x.resource.eql(y.resource)) return false;
        }
        return true;
    }

    pub fn isEmpty(self: AccessSet) bool {
        return self.all == 0 and self.accesses.len == 0;
    }

    /// Whether mode `m`'s component is `All_m`.
    pub fn wildcard(self: AccessSet, m: ModeId) bool {
        return self.all & modeBit(m) != 0;
    }

    /// `a ≤ b`: per mode, `a`'s component is contained in `b`'s. A
    /// concrete set is below `All`; `All` is above only `All`.
    pub fn le(a: AccessSet, b: AccessSet) bool {
        if (a.all & ~b.all != 0) return false;
        for (a.accesses) |x| {
            if (b.wildcard(x.mode)) continue;
            if (!contains(b.accesses, x)) return false;
        }
        return true;
    }
};

pub fn contains(set: []const EffectAccess, x: EffectAccess) bool {
    for (set) |y| {
        if (y.mode == x.mode and y.resource.eql(x.resource)) return true;
    }
    return false;
}

/// Canonicalize a concrete access list: map every resource to its
/// canonical identity (`alias`), fold unknown resources into the mode
/// wildcard, sort, dedupe, and drop accesses of wildcarded modes. The
/// canonical form is instance-independent — aliasing is a quotient
/// applied here (docs/effects.md §5.7).
/// Whether `raw` is already the canonical row under `ctx` — sorted,
/// deduplicated, in no wildcarded mode, free of unknown resources, and
/// unaffected by the instance's alias quotient and resource inclusion.
/// The union/intersection helpers feed canonical rows back through
/// canonicalization, and this is what keeps that from re-sorting every
/// effect row on the hot path for an instance that declares neither.
fn alreadyCanonical(ctx: CanonCtx, raw: []const EffectAccess, all: ModeSet) bool {
    if (ctx.descend.len != 0) return false;
    var prev: ?EffectAccess = null;
    for (raw) |x| {
        const r = canonicalResource(ctx.alias, x.resource);
        if (!r.eql(x.resource)) return false;
        if (ctx.folds(r)) return false;
        if (all & modeBit(x.mode) != 0) return false;
        if (prev) |p| {
            if (accessLessThan({}, x, p)) return false;
            if (p.mode == x.mode and p.resource.eql(x.resource)) return false;
        }
        prev = x;
    }
    return true;
}

pub fn canonicalizeMapped(arena: std.mem.Allocator, ctx: CanonCtx, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet {
    var out = AccessSet{ .all = all };
    if (alreadyCanonical(ctx, raw, all)) {
        out.accesses = try arena.dupe(EffectAccess, raw);
        return out;
    }
    var buf = std.ArrayList(EffectAccess).empty;
    for (raw) |x| {
        const r = canonicalResource(ctx.alias, x.resource);
        // A mode id with no bit in `ModeSet` (>= `max_mode_count`) cannot
        // be wildcarded. Never drop it: keeping it concrete is the
        // conservative answer, and every projection fails closed on a
        // mode the instance does not declare (docs/effects.md §5.7).
        if (ctx.folds(r) and modeBit(x.mode) != 0) {
            out.all |= modeBit(x.mode);
            continue;
        }
        try buf.append(arena, .{ .resource = r, .mode = x.mode });
        // Resource inclusion (docs/effects.md §5.7): an access to `r`
        // reaches everything `r` includes. The product instance declares
        // no inclusions, so this loop is empty for it. A descendant that
        // is itself an unknown resource folds into the mode's `all` bit
        // rather than leaking into the canonical row (the engine rejects
        // such a tree edge at construction, but the canonicalizer keeps
        // the invariant itself too — `CanonCtx` can also come from a
        // hand-built carrier).
        for (ctx.descend) |pr| {
            if (!pr[0].eql(r)) continue;
            if (ctx.folds(pr[1]) and modeBit(x.mode) != 0) {
                out.all |= modeBit(x.mode);
            } else {
                try buf.append(arena, .{ .resource = pr[1], .mode = x.mode });
            }
        }
    }
    std.mem.sort(EffectAccess, buf.items, {}, accessLessThan);
    var dedup = std.ArrayList(EffectAccess).empty;
    for (buf.items) |x| {
        if (out.all & modeBit(x.mode) != 0) continue;
        if (dedup.items.len > 0) {
            const last = dedup.items[dedup.items.len - 1];
            if (last.mode == x.mode and last.resource.eql(x.resource)) continue;
        }
        try dedup.append(arena, x);
    }
    out.accesses = try arena.dupe(EffectAccess, dedup.items);
    return out;
}

pub fn canonicalize(arena: std.mem.Allocator, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet {
    return canonicalizeMapped(arena, .{}, raw, all);
}

fn copyAccessSet(arena: std.mem.Allocator, set: AccessSet) std.mem.Allocator.Error!AccessSet {
    var out = set;
    out.accesses = try arena.dupe(EffectAccess, set.accesses);
    return out;
}

/// Per-mode union; `All ∪ S = All` (docs/effects.md §5.4).
pub fn joinAccess(arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    return joinAccessMapped(arena, .{}, a, b);
}

fn joinAccessMapped(arena: std.mem.Allocator, ctx: CanonCtx, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    // Aliasing is a quotient: two rows related only through an alias must
    // be re-canonicalized before they are unioned.
    // Aliasing is a quotient and the instance's unknown resource folds
    // into a wildcard, so a row must be re-canonicalized before it can be
    // unioned whenever the instance is not the identity map.
    const needs_canon = ctx.alias != null or ctx.extra_unknown != null;
    const ca = if (needs_canon) try canonicalizeMapped(arena, ctx, a.accesses, a.all) else a;
    const cb = if (needs_canon) try canonicalizeMapped(arena, ctx, b.accesses, b.all) else b;
    const all = ca.all | cb.all;
    var buf = std.ArrayList(EffectAccess).empty;
    for (ca.accesses) |x| {
        if (all & modeBit(x.mode) == 0) try buf.append(arena, x);
    }
    for (cb.accesses) |x| {
        if (all & modeBit(x.mode) == 0) try buf.append(arena, x);
    }
    return canonicalizeMapped(arena, .{}, buf.items, all);
}

/// Per-mode intersection; `All ∩ S = S` (docs/effects.md §5.4).
/// **Law-test only** — the optimizer API never exposes meet
/// (docs/effects.md §5.4: meet merges independent sound proofs, it is
/// not a control-flow join).
pub fn latticeMeetAccess(arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    return latticeMeetAccessMapped(arena, .{}, a, b);
}

fn latticeMeetAccessMapped(arena: std.mem.Allocator, ctx: CanonCtx, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    // Aliasing is a quotient and the instance's unknown resource folds
    // into a wildcard, so a row must be re-canonicalized before it can be
    // unioned whenever the instance is not the identity map.
    const needs_canon = ctx.alias != null or ctx.extra_unknown != null;
    const ca = if (needs_canon) try canonicalizeMapped(arena, ctx, a.accesses, a.all) else a;
    const cb = if (needs_canon) try canonicalizeMapped(arena, ctx, b.accesses, b.all) else b;
    const all = ca.all & cb.all;
    var buf = std.ArrayList(EffectAccess).empty;
    for (ca.accesses) |x| {
        const bit = modeBit(x.mode);
        if (all & bit != 0) continue;
        if (ca.all & bit != 0) {
            // All_a ∩ B: B's accesses of this mode survive.
            if (contains(cb.accesses, x)) try buf.append(arena, x);
            continue;
        }
        if (cb.all & bit != 0) {
            try buf.append(arena, x);
            continue;
        }
        if (contains(cb.accesses, x)) try buf.append(arena, x);
    }
    // The loop above only walks a's accesses; add b's accesses for
    // modes where a is wildcarded.
    for (cb.accesses) |x| {
        const bit = modeBit(x.mode);
        if (all & bit != 0 or ca.all & bit == 0) continue;
        try buf.append(arena, x);
    }
    return canonicalizeMapped(arena, .{}, buf.items, all);
}

// ---------------------------------------------------------------------------
// EffectSummary
// ---------------------------------------------------------------------------

/// The four-tuple `(accesses, may_trap, may_diverge, nondeterministic)`.
/// Constructors are explicit (`bottom`/`pure`/`top`) — no code may infer
/// "pure" from a default-constructed struct (docs/effects.md §10.5).
pub const Summary = struct {
    /// No field defaults: a summary is only ever built through the
    /// `bottom`/`pure`/`top` constructors or a full literal, so `.{}`
    /// cannot silently mean "proved pure" (docs/effects.md §10.5).
    accesses: AccessSet,
    /// Includes panic (docs/effects.md §5.1).
    may_trap: bool,
    may_diverge: bool,
    /// `Q`: two evaluations may differ (clock/random/volatile).
    nondeterministic: bool,

    pub fn eql(a: Summary, b: Summary) bool {
        return a.may_trap == b.may_trap and
            a.may_diverge == b.may_diverge and
            a.nondeterministic == b.nondeterministic and
            a.accesses.eql(b.accesses);
    }

    /// `a ≤ b` (false ≤ true, per-mode set inclusion).
    pub fn le(a: Summary, b: Summary) bool {
        return a.accesses.le(b.accesses) and
            (!a.may_trap or b.may_trap) and
            (!a.may_diverge or b.may_diverge) and
            (!a.nondeterministic or b.nondeterministic);
    }
};

/// Lattice bottom — and, as a value, exactly `pure` (docs/effects.md
/// §5.4). "Bottom approximation" vs "proved pure" is `State`, below.
pub const bottom: Summary = .{ .accesses = .{}, .may_trap = false, .may_diverge = false, .nondeterministic = false };
/// The pure summary `(∅, false, false, false)`.
pub const pure: Summary = .{ .accesses = .{}, .may_trap = false, .may_diverge = false, .nondeterministic = false };
/// `(∅, true, false, false)`: may trap (including panic), else pure.
pub const may_trap: Summary = .{ .accesses = .{}, .may_trap = true, .may_diverge = false, .nondeterministic = false };
/// `(∅, false, true, false)`: may diverge, else pure. The recursive-SCC
/// seed of the function-summary least fixpoint (docs/effects.md §8.2).
pub const may_diverge: Summary = .{ .accesses = .{}, .may_trap = false, .may_diverge = true, .nondeterministic = false };
/// `(All, true, true, true)`.
pub const top: Summary = .{ .accesses = AccessSet.top, .may_trap = true, .may_diverge = true, .nondeterministic = true };
/// Every host resource is touched, but no Stilla `ModuleConst` is
/// (docs/effects.md §13). It is a *declaration value*: available only for
/// a binding whose embedding attests `StillaExecution.forbidden`, i.e.
/// attests the binding executes no Stilla code and therefore cannot reach
/// a module constant. A host binding with no declaration is the full
/// `top`; missing *Stilla* targets also use `top`.
pub const host_top: Summary = .{
    .accesses = .{ .accesses = &.{
        .{ .resource = .host_any, .mode = .read },
        .{ .resource = .host_any, .mode = .write },
        .{ .resource = .host_any, .mode = .allocate },
        .{ .resource = .host_any, .mode = .release },
    } },
    .may_trap = true,
    .may_diverge = true,
    .nondeterministic = true,
};

/// Build a summary whose only interaction is the given concrete
/// accesses (`All`/unknown resources are folded into the mode flags).
pub fn summaryOf(arena: std.mem.Allocator, raw: []const EffectAccess) std.mem.Allocator.Error!Summary {
    return .{
        .accesses = try canonicalize(arena, raw, 0),
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = false,
    };
}

/// `E ⊔ F`: per-mode union + OR of the control bits.
pub fn join(arena: std.mem.Allocator, a: Summary, b: Summary) std.mem.Allocator.Error!Summary {
    return .{
        .accesses = try joinAccess(arena, a.accesses, b.accesses),
        .may_trap = a.may_trap or b.may_trap,
        .may_diverge = a.may_diverge or b.may_diverge,
        .nondeterministic = a.nondeterministic or b.nondeterministic,
    };
}

/// `E ; F` — sequential composition. Same may-formula as `join`
/// (docs/effects.md §5.4): the summary carries no order information.
pub fn sequence(arena: std.mem.Allocator, a: Summary, b: Summary) std.mem.Allocator.Error!Summary {
    return join(arena, a, b);
}

/// `E ⊓ F` — **law-test only** (docs/effects.md §5.4).
pub fn latticeMeet(arena: std.mem.Allocator, a: Summary, b: Summary) std.mem.Allocator.Error!Summary {
    return .{
        .accesses = try latticeMeetAccess(arena, a.accesses, b.accesses),
        .may_trap = a.may_trap and b.may_trap,
        .may_diverge = a.may_diverge and b.may_diverge,
        .nondeterministic = a.nondeterministic and b.nondeterministic,
    };
}

pub fn joinAll(arena: std.mem.Allocator, items: []const Summary) std.mem.Allocator.Error!Summary {
    var acc = pure;
    for (items) |s| acc = try join(arena, acc, s);
    return acc;
}

/// Fold `;` over the list in order (empty = `pure`).
pub fn sequenceAll(arena: std.mem.Allocator, items: []const Summary) std.mem.Allocator.Error!Summary {
    var acc = pure;
    for (items) |s| acc = try sequence(arena, acc, s);
    return acc;
}

// ---------------------------------------------------------------------------
// Derived summary facts (docs/effects.md §10.1) — the pure summary level
// ---------------------------------------------------------------------------

/// `total = !may_trap ∧ !may_diverge`.
pub fn isTotal(s: Summary) bool {
    return totalOf(s);
}

/// The `total` predicate, spelled once so the free function and the
/// `Engine` method cannot drift.
pub fn totalOf(s: Summary) bool {
    return !s.may_trap and !s.may_diverge;
}

/// No `Write / Allocate / Release` access and no unknown resource
/// (`All_m` wildcard). Resource *reads* are not observable by default
/// (§10.1); `Q` is not considered here. A read wildcard is `Read(Top)` —
/// an unknown resource — and per §10.1/§5.4 it is *not* an ordinary
/// read, so it fails this predicate too.
pub fn isObservableEffectFree(s: Summary) bool {
    return isObservableEffectFreeWith(s, &default_modes);
}

/// The instance-parameterized form: a mode's `observable` flag decides.
/// An undeclared mode or an unknown resource fails closed
/// (docs/effects.md §5.7).
pub fn isObservableEffectFreeWith(s: Summary, modes: []const ModeDecl) bool {
    if (s.accesses.all != 0) return false;
    for (s.accesses.accesses) |x| {
        // `host_any` is an unknown host resource: it can hide any
        // observable interaction (docs/effects.md §13).
        if (isUnknownResource(x.resource)) return false;
        const d = modeDeclOf(modes, x.mode) orelse return false;
        if (d.observable) return false;
    }
    return true;
}

/// `discard_view` (§10.1, §11.2): drop reads (non-observable) and `Q`
/// (result instability does not make discarding observable); keep the
/// control bits and the observable accesses. `discardable` requires
/// `discardView(observed_effect) == pure`.
pub fn discardView(arena: std.mem.Allocator, s: Summary) std.mem.Allocator.Error!Summary {
    return discardViewWith(arena, s, &default_modes);
}

pub fn discardViewWith(arena: std.mem.Allocator, s: Summary, modes: []const ModeDecl) std.mem.Allocator.Error!Summary {
    var buf = std.ArrayList(EffectAccess).empty;
    for (s.accesses.accesses) |x| {
        const d = modeDeclOf(modes, x.mode) orelse {
            // Undeclared mode: fail closed and keep the access.
            try buf.append(arena, x);
            continue;
        };
        if (!d.discardable) try buf.append(arena, x);
    }
    // Only the declared-discardable modes lose their wildcard; an
    // undeclared wildcard bit stays (fail-closed).
    var all = s.accesses.all;
    for (modes) |d| {
        if (d.discardable) all &= ~modeBit(d.id);
    }
    return .{
        .accesses = try canonicalize(arena, buf.items, all),
        .may_trap = s.may_trap,
        .may_diverge = s.may_diverge,
        .nondeterministic = false,
    };
}

pub fn isPure(s: Summary) bool {
    return pureOf(s);
}

/// The `pure` predicate, spelled once so the free function and the
/// `Engine` method cannot drift.
pub fn pureOf(s: Summary) bool {
    return s.accesses.isEmpty() and !s.may_trap and !s.may_diverge and !s.nondeterministic;
}

// ---------------------------------------------------------------------------
// Pending / Ready — outside the lattice (docs/effects.md §8.2, §10.5)
// ---------------------------------------------------------------------------

/// An expression's or function's analysis state. `Pending` is a
/// transient approximation, never a proof: a legality query that hits a
/// pending fact fails closed. `Bottom` and `Pure` share a lattice value,
/// so "not yet derived" and "proved pure" *must* be carried
/// here, not in the summary.
pub const State = union(enum) {
    pending,
    ready: SummaryId,

    pub fn readyId(self: State) ?SummaryId {
        return switch (self) {
            .pending => null,
            .ready => |id| id,
        };
    }
};

// ---------------------------------------------------------------------------
// Interners
// ---------------------------------------------------------------------------

pub const RowId = u32;
pub const SummaryId = u32;

/// The seeded ids: row 0 `∅`, row 1 `All`; summary 0 `Pure/Bottom`,
/// summary 1 `Top` (docs/effects.md §5.4).
pub const pure_id: SummaryId = 0;
pub const top_id: SummaryId = 1;

/// Invariant (docs/effects.md §5.7), now *enforced* rather than merely
/// documented: one session binds one lattice instance per program.
/// Interning and annotation equality are *carrier-level*, so two
/// instances whose elements share a carrier but differ in meaning (the
/// `flat` row `Read(host=2)` and the `hierarchy` row `Read(host=2)`,
/// which silently includes host=2's descendants) must never share one
/// `Interner`. The binding is **hard and instance-changing**: the table
/// records the engine descriptor digest that produced its rows, and a
/// second analysis of the same program under a *different* instance
/// (`ensureInstance`, called by `hir_effects.Analysis.analyze`) wipes
/// the previous instance's rows back to the seeds — the old rows are
/// dead weight, not facts, and the annotations are re-derived from
/// scratch. A session that pipes two instances through one program gets
/// an empty table under the new instance, never a silently-mixed one.
/// The same instance is a no-op, so one compile's many Analysis passes
/// share the rows.
pub const Interner = struct {
    arena: std.mem.Allocator,
    rows: std.ArrayList(AccessSet) = .empty,
    row_map: std.HashMapUnmanaged(AccessSet, RowId, AccessSetCtx, std.hash_map.default_max_load_percentage) = .empty,
    summaries: std.ArrayList(SummaryKey) = .empty,
    summary_map: std.AutoHashMapUnmanaged(SummaryKey, SummaryId) = .empty,
    /// The engine descriptor digest this table was interned under
    /// (docs/effects.md §5.7), or null while unbound (a built program
    /// before its first analysis).
    instance: ?u64 = null,

    pub const SummaryKey = struct {
        row: RowId,
        may_trap: bool,
        may_diverge: bool,
        nondeterministic: bool,
    };

    /// Seed `∅`/`All` rows and `Pure`/`Top` summaries so `pure_id` and
    /// `top_id` are stable. The seeded `All` is the *built-in* wildcard
    /// set; an engine whose provider adds modes interns its own `top`
    /// row on demand (docs/effects.md §5.7).
    pub fn init(arena: std.mem.Allocator) std.mem.Allocator.Error!Interner {
        var self = Interner{ .arena = arena };
        std.debug.assert(try self.rowId(AccessSet.empty) == 0);
        std.debug.assert(try self.rowId(AccessSet.top) == 1);
        std.debug.assert(try self.summaryId(bottom) == pure_id);
        std.debug.assert(try self.summaryId(top) == top_id);
        return self;
    }

    pub fn rowId(self: *Interner, set: AccessSet) std.mem.Allocator.Error!RowId {
        const gop = try self.row_map.getOrPutContext(self.arena, set, AccessSetCtx{});
        if (gop.found_existing) return gop.value_ptr.*;
        const id: RowId = @intCast(self.rows.items.len);
        const owned = try copyAccessSet(self.arena, set);
        gop.key_ptr.* = owned;
        gop.value_ptr.* = id;
        try self.rows.append(self.arena, owned);
        return id;
    }

    pub fn row(self: *const Interner, id: RowId) AccessSet {
        return self.rows.items[id];
    }

    pub fn summaryId(self: *Interner, s: Summary) std.mem.Allocator.Error!SummaryId {
        const key = SummaryKey{
            .row = try self.rowId(s.accesses),
            .may_trap = s.may_trap,
            .may_diverge = s.may_diverge,
            .nondeterministic = s.nondeterministic,
        };
        const gop = try self.summary_map.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.summaries.items.len);
            try self.summaries.append(self.arena, key);
        }
        return gop.value_ptr.*;
    }

    pub fn summary(self: *const Interner, id: SummaryId) Summary {
        const key = self.summaries.items[id];
        return .{
            .accesses = self.rows.items[key.row],
            .may_trap = key.may_trap,
            .may_diverge = key.may_diverge,
            .nondeterministic = key.nondeterministic,
        };
    }

    pub fn pureId(self: *const Interner) SummaryId {
        _ = self;
        return pure_id;
    }

    pub fn topId(self: *const Interner) SummaryId {
        _ = self;
        return top_id;
    }

    /// Which lattice instance this table is bound to (docs/effects.md
    /// §5.7): the engine descriptor digest, or null when no analysis has
    /// interned under this program yet.
    pub fn boundInstance(self: *const Interner) ?u64 {
        return self.instance;
    }

    /// Bind this table to `engine_digest`, or **re-bind** it when a
    /// different instance comes: a second analysis of the same program
    /// under a new lattice must re-derive every annotation, so the
    /// previous instance's rows are wiped back to the seeds
    /// (docs/effects.md §5.7). The same instance is a no-op, so one
    /// compile's many Analysis passes share the rows.
    pub fn ensureInstance(self: *Interner, engine_digest: u64) !void {
        const bound = self.instance orelse {
            self.instance = engine_digest;
            return;
        };
        if (bound != engine_digest) return self.reset(engine_digest);
    }

    /// Explicitly drop every interned row/summary back to the seeds and
    /// re-bind to `engine_digest` — re-analysing one program under a
    /// second lattice instance (docs/effects.md §5.7: "旧实例的行只是垃圾
    /// 而非事实"). The seeds are instance-independent, so pure/top keep
    /// their stable ids.
    pub fn reset(self: *Interner, engine_digest: u64) !void {
        self.rows = .empty;
        self.row_map = .empty;
        self.summaries = .empty;
        self.summary_map = .empty;
        self.instance = engine_digest;
        // Re-seed ∅/All rows and Pure/Top summaries (init's stable ids).
        std.debug.assert(try self.rowId(AccessSet.empty) == 0);
        std.debug.assert(try self.rowId(AccessSet.top) == 1);
        std.debug.assert(try self.summaryId(bottom) == pure_id);
        std.debug.assert(try self.summaryId(top) == top_id);
    }
};

const AccessSetCtx = struct {
    pub fn hash(_: AccessSetCtx, set: AccessSet) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&set.all));
        for (set.accesses) |x| {
            h.update(std.mem.asBytes(&x.mode));
            hashResource(&h, x.resource);
        }
        return h.final();
    }

    pub fn eql(_: AccessSetCtx, a: AccessSet, b: AccessSet) bool {
        return a.eql(b);
    }

    fn hashResource(h: *std.hash.Wyhash, r: EffectResource) void {
        hashResourceInto(h, r);
    }
};
// ===========================================================================
// Tests — lattice algebra and the §5.4 acceptance examples
// ===========================================================================

const testing = std.testing;

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

test "effects: canonical row folds the top resource into the mode wildcard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try mkSet(a, &.{.{ .resource = .top, .mode = .read }});
    try testing.expect(s.wildcard(.read));
    try testing.expectEqual(@as(usize, 0), s.accesses.len);
    try testing.expect(s.eql(.{ .all = modeBit(.read) }));
}
test "effects: empty access set is Pure and the lattice bottom" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try mks(a, &.{readOf(host(1))});
    try testing.expect(pure.le(e));
    try testing.expect(e.le(top));
    try testing.expect(!e.le(pure));
    try testing.expect(!e.accesses.isEmpty());
    try testing.expect(AccessSet.empty.isEmpty());
}
test "effects: join is per-mode union and meet per-mode intersection (wildcards)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try mkSet(a, &.{readOf(host(1))});
    const two = try mkSet(a, &.{readOf(host(2))});
    const joined = try joinAccess(a, one, two);
    try testing.expectEqual(@as(usize, 2), joined.accesses.len);

    const all_read = AccessSet{ .all = modeBit(.read) };
    try testing.expect((try joinAccess(a, one, all_read)).eql(all_read)); // All ∪ S = All
    try testing.expect((try latticeMeetAccess(a, one, all_read)).eql(one)); // All ∩ S = S
    try testing.expect((try latticeMeetAccess(a, all_read, all_read)).eql(all_read));
    try testing.expect(all_read.le(all_read));
    try testing.expect(one.le(all_read));
    try testing.expect(!all_read.le(one));
}
test "effects: join/meet lattice laws" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try mkSet(a, &.{readOf(host(1))});
    const q = try mkSet(a, &.{writeOf(host(2))});
    const r = AccessSet{ .all = modeBit(.write) };

    // commutative
    try testing.expect((try joinAccess(a, p, q)).eql(try joinAccess(a, q, p)));
    try testing.expect((try latticeMeetAccess(a, p, q)).eql(try latticeMeetAccess(a, q, p)));
    // associative
    try testing.expect((try joinAccess(a, try joinAccess(a, p, q), r)).eql(try joinAccess(a, p, try joinAccess(a, q, r))));
    // idempotent
    try testing.expect((try joinAccess(a, p, p)).eql(p));
    try testing.expect((try latticeMeetAccess(a, p, p)).eql(p));
    // absorption: p ⊓ (p ⊔ q) = p; p ⊔ (p ⊓ q) = p
    try testing.expect((try latticeMeetAccess(a, p, try joinAccess(a, p, q))).eql(p));
    try testing.expect((try joinAccess(a, p, try latticeMeetAccess(a, p, q))).eql(p));
    // monotone join: a ≤ a ⊔ b
    try testing.expect(p.le(try joinAccess(a, p, q)));
    try testing.expect(q.le(try joinAccess(a, p, q)));
    // monotone meet: a ⊓ b ≤ a
    try testing.expect((try latticeMeetAccess(a, p, q)).le(p));
    // Two-argument monotonicity of both operators: for the concrete
    // pair `p ≤ r2` (r2 = p ⊔ q), f(p,c) ≤ f(r2,c).
    const r2 = try joinAccess(a, p, q);
    try testing.expect(p.le(r2));
    try testing.expect((try joinAccess(a, p, r)).le(try joinAccess(a, r2, r)));
    try testing.expect((try latticeMeetAccess(a, p, r)).le(try latticeMeetAccess(a, r2, r)));
    // associativity of meet (join is covered above)
    try testing.expect((try latticeMeetAccess(a, try latticeMeetAccess(a, p, q), r)).eql(try latticeMeetAccess(a, p, try latticeMeetAccess(a, q, r))));
}
test "effects: sequence and join share the may-formula; summary ignores order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try mks(a, &.{writeOf(host(1))});
    const f = try mks(a, &.{readOf(host(2))});
    try testing.expect((try sequence(a, e, f)).eql(try join(a, e, f)));
    // E ; F == F ; E at the summary level.
    try testing.expect((try sequence(a, e, f)).eql(try sequence(a, f, e)));
    // Pure is the identity, not a zero.
    try testing.expect((try sequence(a, pure, e)).eql(e));
    try testing.expect((try sequence(a, e, pure)).eql(e));
}
test "effects: §5.4 acceptance examples" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const panic_s = may_trap;
    const diverge_s = Summary{ .accesses = .{}, .may_trap = false, .may_diverge = true, .nondeterministic = false };

    try testing.expect((try join(a, panic_s, pure)).eql(panic_s));
    try testing.expect((try sequence(a, panic_s, pure)).eql(panic_s));
    try testing.expect(!isTotal(try sequence(a, panic_s, pure)));

    // Panic ; Diverge keeps both control bits (suffix control is not
    // dropped by normal-return gating), and the sequence summary is
    // order-insensitive.
    const pd = try sequence(a, panic_s, diverge_s);
    try testing.expect(pd.may_trap and pd.may_diverge);
    try testing.expect(pd.accesses.isEmpty());
    try testing.expect(pd.eql(try sequence(a, diverge_s, panic_s)));

    // Abnormal termination does not drop the prefix's resource accesses
    // (§5.4 "异常终止后资源访问仍被保守保留"): a write before a trap
    // stays in the summary.
    const w = Summary{ .accesses = try mkSet(a, &.{writeOf(host(1))}), .may_trap = true, .may_diverge = false, .nondeterministic = false };
    const wt = try sequence(a, w, diverge_s);
    try testing.expect((try mkSet(a, &.{writeOf(host(1))})).le(wt.accesses));
    try testing.expect(wt.may_trap and wt.may_diverge);

    // Suffix accesses are conservatively kept even though the prefix
    // traps (no normal-return gating, §5.4).
    const suffixed = try sequence(a, panic_s, Summary{ .accesses = try mkSet(a, &.{writeOf(host(2))}), .may_trap = false, .may_diverge = false, .nondeterministic = false });
    try testing.expect((try mkSet(a, &.{writeOf(host(2))})).le(suffixed.accesses));
    try testing.expect(suffixed.may_trap);

    // Pure ⊔ E = E.
    try testing.expect((try join(a, pure, panic_s)).eql(panic_s));

    // A conditional panic does not become pure.
    try testing.expect(!isTotal(try join(a, panic_s, pure)));
}
test "effects: Top absorbs and is the top of the lattice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try mks(a, &.{writeOf(host(1))});
    try testing.expect((try join(a, top, e)).eql(top));
    try testing.expect((try latticeMeet(a, top, e)).eql(e));
    try testing.expect(e.le(top));
    try testing.expect(!isObservableEffectFree(e));
    try testing.expect(!isObservableEffectFree(top));
    try testing.expect(isObservableEffectFree(pure));
}
test "effects: reads are non-observable; discard_view strips reads and Q" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q = Summary{ .accesses = try mkSet(a, &.{readOf(host(3))}), .may_trap = false, .may_diverge = false, .nondeterministic = true };
    try testing.expect(isObservableEffectFree(q));
    const dv = try discardView(a, q);
    try testing.expect(isPure(dv));
    try testing.expect(!dv.nondeterministic);

    // A write survives discard_view and blocks discard.
    const w = Summary{ .accesses = try mkSet(a, &.{writeOf(host(3))}), .may_trap = false, .may_diverge = false, .nondeterministic = false };
    try testing.expect(!isPure(try discardView(a, w)));
    try testing.expect(!isObservableEffectFree(w));

    // A cleanup trap survives discard_view.
    const t = try sequence(a, q, may_trap);
    try testing.expect(!isPure(try discardView(a, t)));

    // A *concrete* read is non-observable; an unknown-resource`Read(Top)`
    // (`All_read`) is not (§10.1 "无未知资源"), even with no write bit.
    const read_top = try mks(a, &.{.{ .resource = .top, .mode = .read }});
    try testing.expect(read_top.accesses.wildcard(.read));
    try testing.expect(read_top.accesses.accesses.len == 0);
    try testing.expect(!isObservableEffectFree(read_top));
}
test "effects: interner is canonical and stable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var it = try Interner.init(a);
    try testing.expectEqual(pure_id, try it.summaryId(pure));
    try testing.expectEqual(top_id, try it.summaryId(top));

    const s1 = try mks(a, &.{ readOf(host(1)), writeOf(host(2)) });
    const s2 = try mks(a, &.{ writeOf(host(2)), readOf(host(1)) });
    const id1 = try it.summaryId(s1);
    const id2 = try it.summaryId(s2);
    try testing.expectEqual(id1, id2);
    try testing.expect(it.summary(id1).eql(s1));
    try testing.expectEqual(it.row(0).accesses.len, @as(usize, 0));
    try testing.expect(it.row(1).eql(AccessSet.top));
    try testing.expect(it.boundInstance() == null);
}
test "effects: Pending is not a pure proof" {
    const pending: State = .pending;
    try testing.expect(pending.readyId() == null);
    const ready: State = .{ .ready = pure_id };
    try testing.expectEqual(pure_id, ready.readyId().?);
}
test "effects: host_top touches every host resource but no ModuleConst" {
    try testing.expect(!isObservableEffectFree(host_top));
    try testing.expect(!isTotal(host_top));
    try testing.expect(host_top.nondeterministic);
    for (host_top.accesses.accesses) |a| {
        try testing.expect(a.resource == .host_any);
    }
    // Unknown Stilla targets still use the full `top`.
    try testing.expect(!top.eql(host_top));
}
test "effects: Summary join/meet laws over control bits and wildcards" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diverge = Summary{ .accesses = .{}, .may_trap = false, .may_diverge = true, .nondeterministic = false };
    const q = Summary{ .accesses = .{}, .may_trap = false, .may_diverge = false, .nondeterministic = true };
    const cases = [_]Summary{
        pure,
        may_trap,
        diverge,
        top,
        q,
        try mks(a, &.{ writeOf(host(1)), readOf(host(2)) }),
    };
    for (cases) |x| {
        for (cases) |y| {
            for (cases) |z| {
                const xy = try join(a, x, y);
                const yx = try join(a, y, x);
                const mx = try latticeMeet(a, x, y);
                const my = try latticeMeet(a, y, x);
                // commutativity
                try testing.expect(xy.eql(yx));
                try testing.expect(mx.eql(my));
                // associativity
                try testing.expect((try join(a, xy, z)).eql(try join(a, x, try join(a, y, z))));
                try testing.expect((try latticeMeet(a, mx, z)).eql(try latticeMeet(a, x, try latticeMeet(a, y, z))));
                // idempotence
                try testing.expect((try join(a, x, x)).eql(x));
                try testing.expect((try latticeMeet(a, x, x)).eql(x));
                // absorption
                try testing.expect((try latticeMeet(a, x, xy)).eql(x));
                try testing.expect((try join(a, x, mx)).eql(x));
                // monotone in each argument
                try testing.expect(x.le(xy));
                try testing.expect(y.le(xy));
                try testing.expect(mx.le(x));
                try testing.expect(mx.le(y));
                // two-argument monotonicity: x ≤ x ⊔ y ⇒ f(x, z) ≤ f(x ⊔ y, z)
                try testing.expect((try join(a, x, z)).le(try join(a, xy, z)));
                try testing.expect((try latticeMeet(a, x, z)).le(try latticeMeet(a, xy, z)));
            }
        }
    }
}
