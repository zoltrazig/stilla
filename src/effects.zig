//! Effect-semantics model — docs/effects.md §5 (element + lattice
//! interface, §5.7 provider contract) and §14 (minimal scope), the
//! HIR-side summary in docs/hir.md §6.2. This is the **M1b** effect
//! infrastructure: an abstract semantic resource model, a lattice
//! *engine*, and the default product instance, independent of any pass.
//! The HIR integration (transfer, function summaries, derived legality
//! queries) lives in `passes/hir_effects.zig`.
//!
//! Model in one paragraph. An expression's interaction with state
//! *outside* itself is an `EffectSummary`: a resource-access row plus
//! three control bits (`may_trap` — includes panic —, `may_diverge`,
//! `nondeterministic`). Lexical reads/moves/borrows of locals are
//! ownership facts, not effects, and do not enter the summary
//! (docs/effects.md §2.1, §4). Resources are abstract semantic domains,
//! never addresses (§5.2).
//!
//! Lattice (§5.4). The element is a four-tuple `(A, may_trap,
//! may_diverge, nondeterministic)`. For the default instance, each
//! declared mode's component of `A` is `P(K) ∪ {All}`: ordinary resource
//! sets ordered by inclusion, with `All` strictly above every ordinary
//! set (including the full registered set) so it also covers resources
//! registered later. `join` is per-mode union, `meet` per-mode
//! intersection, with `All ∪ S = All` and `All ∩ S = S`. Booleans join
//! with OR. The canonical row is a mode-wildcard bitmask plus a sorted,
//! deduplicated concrete access list; the unknown resource is
//! canonicalized into the corresponding `all` bit, so it never appears in
//! stored accesses.
//!
//! Instances (§5.7). An `Engine` is one frozen lattice instance: a
//! provider's declarations (the mode set with its `commutative` /
//! `observable` / `discardable` flags, and the resource partial order)
//! interned once at session start and read-only afterwards. The lattice
//! algebra is shared by every instance; an instance changes only
//! *canonicalization* (aliasing is a quotient) and the *conflict query*
//! (disjointness is declared). `flat` is the default instance and the
//! regression baseline; `hierarchy` is the second one, proving the
//! interface is not vacuous. A summary naming a mode the instance never
//! declared is invalid and degrades to `Top`, never to an
//! under-approximation (§9.3).
//! `Pure == Bottom` (§5.4): the four-tuple `(∅, false, false, false)`
//! is both the lattice bottom and the "proved pure" value; the
//! difference between "bottom approximation" and "proved pure" is the
//! `State` machine below, not a lattice value. `Top` is
//! `(All, true, true, true)`.
//!
//! Sequencing vs join. `E ; F` (evaluate E, then F) and `E ⊔ F` (a
//! candidate choice) have the same may-formula (§5.4) and are both
//! `join` here; they differ in *semantic role*, which lives in the op
//! descriptors, not in the summary. Summaries therefore carry no order
//! information — see `sequence` (an alias of `join`) and the law tests.

const std = @import("std");

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

fn modeDeclOf(modes: []const ModeDecl, id: ModeId) ?ModeDecl {
    for (modes) |d| {
        if (d.id == id) return d;
    }
    return null;
}

fn modeDeclLessThan(_: void, a: ModeDecl, b: ModeDecl) bool {
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
const CanonCtx = struct {
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

fn contains(set: []const EffectAccess, x: EffectAccess) bool {
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

fn canonicalizeMapped(arena: std.mem.Allocator, ctx: CanonCtx, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet {
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

fn canonicalize(arena: std.mem.Allocator, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet {
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
fn totalOf(s: Summary) bool {
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
fn isObservableEffectFreeWith(s: Summary, modes: []const ModeDecl) bool {
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

fn discardViewWith(arena: std.mem.Allocator, s: Summary, modes: []const ModeDecl) std.mem.Allocator.Error!Summary {
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
fn pureOf(s: Summary) bool {
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

// ---------------------------------------------------------------------------
// Lattice engine (docs/effects.md §5.7)
// ---------------------------------------------------------------------------

/// A resource's relation to another, as declared by the provider's
/// resource order (docs/effects.md §5.7). Only `disjoint` licenses a
/// cross-resource commute; `overlap` is the conservative default.
pub const Relation = enum { equal, disjoint, overlap };

/// Provider-declared resource partial order (docs/effects.md §5.7).
/// Disjointness is *opt-in precision*: everything undeclared overlaps.
pub const ResourceOrder = union(enum) {
    /// The default instance (docs/effects.md §5.6): a `stable` set plus
    /// explicit `disjoint` pairs. Distinct resources overlap unless a
    /// pair says otherwise, so a missing declaration only loses
    /// optimization.
    flat: Flat,
    /// A domain forest plus aliases. Nodes placed in the tree gain the
    /// tree relation — same-tree nodes with no ancestor relation (sibling
    /// subtrees) are provably disjoint, as are different trees; a resource
    /// outside the tree still overlaps everything. Aliases collapse
    /// identity. Unlike `flat`, a *missing* tree edge costs precision
    /// rather than gaining it, so the declaration is a trusted contract.
    hierarchy: Hierarchy,

    pub const Flat = struct {
        stable: []const EffectResource = &.{},
        disjoint: []const Pair = &.{},
    };

    pub const Hierarchy = struct {
        /// `child -> parent` edges of the domain forest. A cycle or a
        /// second parent for one child is an invalid declaration.
        parents: []const Edge = &.{},
        /// Two spellings of the same domain.
        aliases: []const Pair = &.{},
        stable: []const EffectResource = &.{},
        /// Extra explicit disjoint pairs, on top of the tree relation.
        disjoint: []const Pair = &.{},
        /// One more resource naming "any resource"; `.top` and `.host_any`
        /// always are.
        unknown: ?EffectResource = null,
    };

    pub const Edge = struct { child: EffectResource, parent: EffectResource };
    pub const Pair = struct { a: EffectResource, b: EffectResource };
};

/// A lattice provider (docs/effects.md §5.7): the mode set and resource
/// partial order of one lattice instance. The embedding declares it; an
/// `Engine` interns, validates, and freezes it at session start.
pub const Provider = struct {
    /// Stable identity of the instance. Part of the environment
    /// fingerprint; two instances must not share it.
    id: []const u8,
    /// Provider revision: bump on any semantic change to `modes` or
    /// `order`.
    version: u32 = 0,
    modes: []const ModeDecl = &default_modes,
    order: ResourceOrder = .{ .flat = .{} },
};

/// The default instance's provider identity: the fixed product lattice of
/// docs/effects.md §5.4, used when no provider is declared.
pub const default_provider_id = "stilla.product.default";
pub const default_provider_version: u32 = 1;

/// The default instance spelled as a declaration, so a caller can name it
/// explicitly (`frontend.Options.provider`) and get exactly the same
/// environment as passing null.
pub const product_provider = Provider{
    .id = default_provider_id,
    .version = default_provider_version,
};

/// The example second instance's extra mode (docs/effects.md §5.7). It is
/// spelled as an id because `ModeId` is non-exhaustive: only a provider
/// can name a mode outside the built-in four.
pub const mode_commute_update: ModeId = @enumFromInt(4);

/// The example `hierarchy` instance's mode set: the built-in four plus one
/// provider mode.
pub const hierarchy_modes = default_modes ++ [_]ModeDecl{
    .{
        .id = mode_commute_update,
        .name = "commute_update",
        .commutative = true,
        .observable = true,
        .discardable = false,
    },
};

/// The example `hierarchy` instance (docs/effects.md §5.7). Its purpose is
/// to show the interface is not vacuous: it shares the lattice algebra
/// with the default `flat` instance but changes *conflict precision*
/// (`host(2)` / `host(3)` are sibling subtrees of `host(1)`, hence
/// provably disjoint) and adds a mode whose `commutative` flag changes
/// `conflictOf`. `host(5)` is an alias of `host(2)`; `host(4)` is outside
/// the tree and therefore still overlaps everything.
pub const example_hierarchy = Provider{
    .id = "stilla.hierarchy.example",
    .version = 1,
    .modes = &hierarchy_modes,
    .order = .{ .hierarchy = .{
        .parents = &.{
            .{ .child = .{ .host = 2 }, .parent = .{ .host = 1 } },
            .{ .child = .{ .host = 3 }, .parent = .{ .host = 1 } },
            .{ .child = .{ .host = 7 }, .parent = .{ .host = 6 } },
        },
        .aliases = &.{.{ .a = .{ .host = 5 }, .b = .{ .host = 2 } }},
        .stable = &.{ .{ .host = 1 }, .{ .host = 2 } },
    } },
};

/// The six standard-library host domains (docs/effects.md §5.6, §13;
/// `interpreter_host.zig`'s `defaultHostRegistry`), in registry order.
/// `interpreter_host` resolves these modules to host bindings; a host hook
/// uses its module's own resource ids. `stdlib_host_tree` is a *provider
/// that declares the real tree edges over these domains* — the six
/// modules split into three sibling subtrees (I/O, collections, scalar),
/// each sharing one read pool, so e.g. `string` and `math` reads are
/// provably disjoint and a `list` read conflicts only inside its subtree.
/// Unlike `example_hierarchy` this names actual product modules, so it can
/// ride in with a host-declared program instead of standing in as a formal
/// shape.
pub const stdlib_host_tree = Provider{
    .id = "stilla.product.stdlib",
    .version = 1,
    .order = .{
        .hierarchy = .{
            .parents = &.{
                // I/O — `builtin` owns the print/write path; `host` is the
                // requested per-module root (docs/effects.md §5.6).
                .{ .child = .{ .host = domain_builtin }, .parent = .{ .host = domain_io_root } },
                // Lists and string buffers share one scalar-data read domain
                // (`list`/`string` are siblings under it).
                .{ .child = .{ .host = domain_list }, .parent = .{ .host = domain_collections_root } },
                .{ .child = .{ .host = domain_string }, .parent = .{ .host = domain_collections_root } },
                // `array`/`hashmap` are the other two collections, sibling
                // under the same read pool; `math` is the pure scalar domain.
                .{ .child = .{ .host = domain_array }, .parent = .{ .host = domain_collections_root } },
                .{ .child = .{ .host = domain_hashmap }, .parent = .{ .host = domain_collections_root } },
                .{ .child = .{ .host = domain_math }, .parent = .{ .host = domain_math_root } },
            },
            .stable = &.{
                .{ .host = domain_math },
                .{ .host = domain_builtin },
            },
        },
    },
};

// ---------------------------------------------------------------------------
// Standard-library host domain ids (docs/effects.md §5.6)
// ---------------------------------------------------------------------------

/// The `builtin` host module's domain (std/builtin.st).
pub const domain_builtin: HostDomainId = 1;
/// The `host` root for I/O modules — the only module `builtin` reads under.
pub const domain_io_root: HostDomainId = 11;
/// The root host domain for the collection modules (`list`/`array`/
/// `hashmap`/`string`).
pub const domain_collections_root: HostDomainId = 21;
/// The pure scalar-arithmetic root (`math`).
pub const domain_math_root: HostDomainId = 31;
/// The `list` module's domain (std/list.st).
pub const domain_list: HostDomainId = 22;
/// The `string` module's domain (std/string.st).
pub const domain_string: HostDomainId = 23;
/// The `array` module's domain (std/array.st).
pub const domain_array: HostDomainId = 24;
/// The `hashmap` module's domain (std/hashmap.st).
pub const domain_hashmap: HostDomainId = 25;
/// The `math` module's domain (std/math.st).
pub const domain_math: HostDomainId = 32;

// ---------------------------------------------------------------------------
// Lattice operation table (docs/effects.md §5.7)
// ---------------------------------------------------------------------------

/// The operations one lattice instance supplies (docs/effects.md §5.7).
/// `ctx` is the frozen `Engine`, so an operation is a plain file-scope
/// function and no instance state hides in a closure. Instances *may*
/// share an implementation — these do, heavily — but the table is what
/// makes the choice a runtime decision rather than a closed
/// configuration switch, and it is the list of obligations a new
/// instance must meet.
pub const Ops = struct {
    /// Canonicalize the concrete accesses of one row under the instance.
    /// This is where resource *inclusion* enters the element: an instance
    /// whose resource order is finer than identity closes the row over
    /// it, so `le` (set inclusion over canonical rows) orders what the
    /// instance says is ordered.
    canonicalize: *const fn (ctx: *const Engine, arena: std.mem.Allocator, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet,
    /// Per-mode union (`All ∪ S = All`).
    join: *const fn (ctx: *const Engine, arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet,
    /// Per-mode intersection (`All ∩ S = S`).
    meet: *const fn (ctx: *const Engine, arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet,
    /// The element order (`a ≤ b`) over canonical rows.
    le: *const fn (ctx: *const Engine, a: AccessSet, b: AccessSet) bool,
    /// The resource relation, the input to the conflict rule.
    relation: *const fn (ctx: *const Engine, a: EffectResource, b: EffectResource) Relation,
    /// The instance's `⊤` row (every declared mode wildcarded).
    top: *const fn (ctx: *const Engine) AccessSet,
    /// Canonical equality of two rows.
    eql: *const fn (ctx: *const Engine, a: AccessSet, b: AccessSet) bool,
    /// Canonical digest of one row (fingerprint / interning input).
    hash: *const fn (ctx: *const Engine, h: *std.hash.Wyhash, s: AccessSet) void,
    /// `observable_effect_free` (docs/effects.md §10.1).
    observable_free: *const fn (ctx: *const Engine, s: Summary) bool,
    /// `discard_view` (docs/effects.md §10.1).
    discard: *const fn (ctx: *const Engine, arena: std.mem.Allocator, s: Summary) std.mem.Allocator.Error!Summary,
    /// The `stable` projection (docs/effects.md §5.5).
    is_stable: *const fn (ctx: *const Engine, r: EffectResource) bool,
    /// The same-resource commute verdict (docs/effects.md §5.6).
    same_resource: *const fn (ctx: *const Engine, a: EffectAccess, b: EffectAccess) Conflict,
};

// -- operations shared by every instance (carrier-level) --------------------

fn carrierLe(_: *const Engine, a: AccessSet, b: AccessSet) bool {
    return a.le(b);
}

fn carrierEql(_: *const Engine, a: AccessSet, b: AccessSet) bool {
    return a.eql(b);
}

fn carrierTop(ctx: *const Engine) AccessSet {
    return .{ .all = ctx.all_modes };
}

fn carrierHash(_: *const Engine, h: *std.hash.Wyhash, s: AccessSet) void {
    hashAccessSetInto(h, s);
}

fn modeObservableFree(ctx: *const Engine, s: Summary) bool {
    return isObservableEffectFreeWith(s, ctx.modes);
}

fn modeDiscard(ctx: *const Engine, arena: std.mem.Allocator, s: Summary) std.mem.Allocator.Error!Summary {
    return discardViewWith(arena, s, ctx.modes);
}

fn engineIsStable(ctx: *const Engine, r: EffectResource) bool {
    return ctx.stable_set.contains(ctx.canonical(r));
}

/// The same-resource commute verdict (docs/effects.md §5.6): both sides
/// must be members of the instance's mutually commuting mode group and
/// the shared resource must be declared `stable`. Canonical resources
/// only — the caller resolves aliases first.
fn modeSameResource(ctx: *const Engine, a: EffectAccess, b: EffectAccess) Conflict {
    const da = modeDeclOf(ctx.modes, a.mode) orelse return .conflict;
    const db = modeDeclOf(ctx.modes, b.mode) orelse return .conflict;
    return if (da.commutative and db.commutative and engineIsStable(ctx, a.resource)) .commute else .conflict;
}

/// The registry/tree relation for resources the instance placed in a
/// declared relation; undeclared pairs overlap.
fn declaredRelation(ctx: *const Engine, a: EffectResource, b: EffectResource) Relation {
    const ca = ctx.canonical(a);
    const cb = ctx.canonical(b);
    if (ca.eql(cb)) return .equal;
    if (ctx.isUnknown(ca) or ctx.isUnknown(cb)) return .overlap;
    for (ctx.disjoint) |pr| {
        if ((pr[0].eql(ca) and pr[1].eql(cb)) or (pr[0].eql(cb) and pr[1].eql(ca))) return .disjoint;
    }
    if (ctx.kind != .hierarchy) return .overlap;
    if (!ctx.tree_nodes.contains(ca) or !ctx.tree_nodes.contains(cb)) return .overlap;
    const ra = ctx.rootOf(ca).?;
    const rb = ctx.rootOf(cb).?;
    if (!ra.eql(rb)) return .disjoint; // different trees
    if (ctx.isAncestor(ca, cb) or ctx.isAncestor(cb, ca)) return .overlap;
    return .disjoint; // sibling subtrees
}

/// The union half of the product algebra over canonical rows.
fn unionRows(ctx: *const Engine, arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    const canon = ctx.ops.canonicalize;
    const ca = try canon(ctx, arena, a.accesses, a.all);
    const cb = try canon(ctx, arena, b.accesses, b.all);
    const all = ca.all | cb.all;
    var buf = std.ArrayList(EffectAccess).empty;
    for (ca.accesses) |x| {
        if (all & modeBit(x.mode) == 0) try buf.append(arena, x);
    }
    for (cb.accesses) |x| {
        if (all & modeBit(x.mode) == 0) try buf.append(arena, x);
    }
    return canon(ctx, arena, buf.items, all);
}

/// The intersection half of the product algebra over canonical rows.
fn intersectRows(ctx: *const Engine, arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    const canon = ctx.ops.canonicalize;
    const ca = try canon(ctx, arena, a.accesses, a.all);
    const cb = try canon(ctx, arena, b.accesses, b.all);
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
    return canon(ctx, arena, buf.items, all);
}

// -- the default `ProductLattice` instance ----------------------------------

fn productCanonicalize(ctx: *const Engine, arena: std.mem.Allocator, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet {
    return canonicalizeMapped(arena, ctx.canonCtx(), raw, all);
}

/// The `flat` product lattice (docs/effects.md §5.4): the element's
/// resource components are ordinary sets, so canonicalization is
/// sort/dedupe plus the unknown-resource fold, and the order is
/// inclusion.
pub const ProductLattice = Ops{
    .canonicalize = productCanonicalize,
    .join = unionRows,
    .meet = intersectRows,
    .le = carrierLe,
    .relation = declaredRelation,
    .top = carrierTop,
    .eql = carrierEql,
    .hash = carrierHash,
    .observable_free = modeObservableFree,
    .discard = modeDiscard,
    .is_stable = engineIsStable,
    .same_resource = modeSameResource,
};

// -- the `hierarchy` instance ----------------------------------------------

/// The `hierarchy` instance (docs/effects.md §5.7): the resource partial
/// order is a declared forest, with `child ≤ parent` — an access to a node
/// reaches everything *below* it, so canonicalization closes the row
/// downward. Union/intersection stay the product algebra over the closed
/// sets, and inclusion stays set inclusion; the order therefore *does*
/// change with the instance (`{child} ≤ {parent}`), which is the whole
/// point of a pluggable lattice. Aliasing is a quotient applied first.
fn hierarchyCanonicalize(ctx: *const Engine, arena: std.mem.Allocator, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet {
    return canonicalizeMapped(arena, ctx.canonCtx(), raw, all);
}

pub const HierarchyLattice = Ops{
    .canonicalize = hierarchyCanonicalize,
    .join = unionRows,
    .meet = intersectRows,
    .le = carrierLe,
    .relation = declaredRelation,
    .top = carrierTop,
    .eql = carrierEql,
    .hash = carrierHash,
    .observable_free = modeObservableFree,
    .discard = modeDiscard,
    .is_stable = engineIsStable,
    .same_resource = modeSameResource,
};

/// A frozen lattice instance (docs/effects.md §5.7): the provider's
/// declarations interned into lookup tables, the selected operation
/// table, and the shared algebra. A session owns one; rows and handles
/// never cross sessions.
pub const Engine = struct {
    arena: std.mem.Allocator,
    /// Provider identity / revision (fingerprint inputs).
    id: []const u8,
    version: u32,
    /// The declared mode set, sorted by id.
    modes: []const ModeDecl,
    all_modes: ModeSet,
    /// The selected operation table (docs/effects.md §5.7).
    ops: Ops,
    kind: enum { flat, hierarchy },
    /// Frozen tables.
    alias_canon: AliasMap,
    parents: std.HashMapUnmanaged(EffectResource, EffectResource, ResourceCtx, std.hash_map.default_max_load_percentage),
    tree_nodes: std.HashMapUnmanaged(EffectResource, void, ResourceCtx, std.hash_map.default_max_load_percentage),
    /// Transitive `{ancestor, descendant}` pairs of the declared forest
    /// (including self), the downward closure the hierarchy instance
    /// applies during canonicalization.
    descend: []const [2]EffectResource,
    stable_set: std.HashMapUnmanaged(EffectResource, void, ResourceCtx, std.hash_map.default_max_load_percentage),
    disjoint: [][2]EffectResource,
    unknown_extra: ?EffectResource,
    /// Stable digest of the frozen **lattice descriptor** — the provider's
    /// identity / version, mode set, and resource partial order
    /// (docs/effects.md §5.7). This is the cross-instance binding key of
    /// `Interner.ensureInstance` / `reset`: two sessions whose providers
    /// describe the same instance must agree on it, and a change to any
    /// lattice input moves it. It deliberately excludes the *effect-domain
    /// registry* (`stable` / `disjoint` shots fed through `Engine.init`):
    /// those change conflict conclusions, not interned *row* identity, so
    /// a program whose rows were interned under one lattice may still be
    /// re-analysed with a different registry — only a different lattice
    /// instance is the hard binding.
    descriptor_digest: u64 = 0,

    pub const Error = error{ InvalidProvider, OutOfMemory };

    /// Intern, validate, and freeze a provider (docs/effects.md §5.7).
    /// An invalid declaration is a provider bug and is *rejected*, never
    /// silently degraded.
    pub fn init(arena: std.mem.Allocator, provider: ?*const Provider, registry: ResourceRegistry) Error!Engine {
        const p: Provider = if (provider) |x| x.* else .{
            .id = default_provider_id,
            .version = default_provider_version,
        };

        if (p.modes.len > max_mode_count) return error.InvalidProvider;
        var seen = [_]bool{false} ** max_mode_count;
        for (p.modes) |d| {
            const i = @intFromEnum(d.id);
            if (i >= max_mode_count or seen[i]) return error.InvalidProvider;
            seen[i] = true;
        }
        for (0..mode_count) |m| {
            if (!seen[m]) return error.InvalidProvider;
        }
        var all_modes: ModeSet = 0;
        for (p.modes) |d| all_modes |= modeBit(d.id);
        // The frozen instance owns its descriptor: the provider's slices
        // and symbol bytes are the embedder's, and the engine must stay
        // valid after they are released (docs/effects.md §5.7).
        const modes = try arena.alloc(ModeDecl, p.modes.len);
        for (p.modes, 0..) |d, i| {
            modes[i] = d;
            modes[i].name = try arena.dupe(u8, d.name);
        }
        std.mem.sort(ModeDecl, modes, {}, modeDeclLessThan);

        var self = Engine{
            .arena = arena,
            .id = try arena.dupe(u8, p.id),
            .version = p.version,
            .modes = modes,
            .all_modes = all_modes,
            .ops = ProductLattice,
            .kind = .flat,
            .alias_canon = .empty,
            .parents = .empty,
            .tree_nodes = .empty,
            .descend = &.{},
            .stable_set = .empty,
            .disjoint = &.{},
            .unknown_extra = null,
        };
        switch (p.order) {
            .flat => |f| {
                for (f.stable) |r| try self.stable_set.put(arena, self.canonical(r), {});
                for (registry.stable) |r| try self.stable_set.put(arena, self.canonical(r), {});
                try self.loadDisjoint(f.disjoint, registry.disjoint);
            },
            .hierarchy => |h| {
                self.kind = .hierarchy;
                self.ops = HierarchyLattice;
                try self.loadHierarchy(h, registry);
            },
        }
        // The descriptor digest is the frozen lattice instance's identity,
        // hashed order-independently like the fingerprint (docs/effects.md
        // §5.7): provider id / version, the mode set, and the resource
        // partial order. The effect-domain registry is deliberately left
        // out: interned row identity depends on the lattice's
        // canonicalization (alias quotient, resource inclusion), not on
        // stable/disjoint conflict facts.
        {
            var h = std.hash.Wyhash.init(0);
            try hashProvider(&h, arena, provider);
            self.descriptor_digest = h.final();
        }
        return self;
    }

    /// Intern the default `flat` instance over `registry`. This is the
    /// one declaration that needs no validation, so the error set is the
    /// allocator's — the shape white-box callers and `hir_build`'s
    /// cleanup pass can propagate without carrying `InvalidProvider`.
    pub fn initDefault(arena: std.mem.Allocator, registry: ResourceRegistry) std.mem.Allocator.Error!Engine {
        return init(arena, null, registry) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The default declaration is a compile-time constant.
            error.InvalidProvider => unreachable,
        };
    }

    fn loadHierarchy(self: *Engine, h: ResourceOrder.Hierarchy, registry: ResourceRegistry) Error!void {
        const arena = self.arena;

        // Aliases are an equivalence relation: union-find over the
        // declared spellings, then a frozen `resource -> canonical root`
        // map. The representative is the *least* member of each class
        // (`lessThan`), so the class identity — and every fact derived
        // from it — does not depend on the declaration order.
        var alias_parent = std.HashMapUnmanaged(EffectResource, EffectResource, ResourceCtx, std.hash_map.default_max_load_percentage).empty;
        for (h.aliases) |pr| {
            // The instance-declared `unknown` is a wildcard name, the same
            // kind of element `.top` / `.host_any` are: aliasing it would
            // move the wildcard's reach — a different element altogether
            // (docs/effects.md §5.7 protected names). Rejected like the
            // others rather than silently degrading the canonical form.
            if (isProtected(pr.a) or isProtected(pr.b)) return error.InvalidProvider;
            if (h.unknown) |u| {
                if (pr.a.eql(u) or pr.b.eql(u)) return error.InvalidProvider;
            }
            var ra = aliasRoot(&alias_parent, pr.a);
            var rb = aliasRoot(&alias_parent, pr.b);
            if (ra.eql(rb)) continue;
            if (rb.lessThan(ra)) {
                const t = ra;
                ra = rb;
                rb = t;
            }
            try alias_parent.put(arena, rb, ra);
        }
        for (h.aliases) |pr| {
            try self.alias_canon.put(arena, pr.a, aliasRoot(&alias_parent, pr.a));
            try self.alias_canon.put(arena, pr.b, aliasRoot(&alias_parent, pr.b));
        }
        // The instance's unknown resource is a *canonical* name, so the
        // literal stored in the field and the resource the canonicalizer
        // sees agree.
        if (h.unknown) |u| {
            if (isProtected(u)) return error.InvalidProvider;
            self.unknown_extra = self.canonical(u);
        }

        // Resource facts are canonicalized *after* the alias map exists,
        // or two spellings of one domain would answer `isStable`
        // differently depending on which one was declared.
        for (h.stable) |r| try self.stable_set.put(arena, self.canonical(r), {});
        for (registry.stable) |r| try self.stable_set.put(arena, self.canonical(r), {});

        for (h.parents) |e| {
            // A protected resource (a `ModuleConst`, or the wildcard
            // names `.top` / `.host_any`, or the instance-declared
            // `unknown`) may neither be aliased nor placed in the tree:
            // either would change which resources a wildcard covers, or
            // let the downward closure subsume one constant read by
            // another. A read that disappears is a missed init/teardown
            // dependency (docs/effects.md §7.3), a wildcard whose scope
            // moved is a different element altogether, and a tree edge
            // touching the declared `unknown` would surface it as a
            // *concrete* descendant instead of folding it into the mode's
            // `all` bit (docs/effects.md §5.4/§5.7).
            if (isProtected(e.child) or isProtected(e.parent)) return error.InvalidProvider;
            const child = self.canonical(e.child);
            const parent = self.canonical(e.parent);
            if (self.isUnknown(child) or self.isUnknown(parent)) return error.InvalidProvider;
            if (self.parents.get(child)) |prev| {
                if (!prev.eql(parent)) return error.InvalidProvider;
            }
            try self.parents.put(arena, child, parent);
            try self.tree_nodes.put(arena, child, {});
            try self.tree_nodes.put(arena, parent, {});
        }
        // A cycle makes the forest relation ill-founded: reject it rather
        // than answering with a partial walk.
        var it = self.parents.keyIterator();
        while (it.next()) |k| _ = self.rootOf(k.*) orelse return error.InvalidProvider;

        try self.loadDisjoint(h.disjoint, registry.disjoint);
        try self.loadDescend();
    }

    /// The downward closure of the declared forest (docs/effects.md
    /// §5.7): every `{ancestor, descendant}` pair, transitively, plus each
    /// node against itself. Small by construction — it is the provider's
    /// own declaration — so the pair list is materialized rather than
    /// recomputed per access.
    fn loadDescend(self: *Engine) Error!void {
        var buf = std.ArrayList([2]EffectResource).empty;
        var it = self.parents.iterator();
        while (it.next()) |entry| {
            // `parents` maps child -> parent; the closure is stated as
            // `{ancestor, descendant}`.
            try buf.append(self.arena, .{ entry.value_ptr.*, entry.key_ptr.* });
        }
        // Transitive closure: repeat until no new pair appears.
        var changed = true;
        while (changed) {
            changed = false;
            for (buf.items) |pr| {
                for (buf.items) |qr| {
                    if (!pr[1].eql(qr[0])) continue;
                    const candidate = [2]EffectResource{ pr[0], qr[1] };
                    var known = false;
                    for (buf.items) |r| {
                        if (r[0].eql(candidate[0]) and r[1].eql(candidate[1])) known = true;
                    }
                    if (!known) {
                        try buf.append(self.arena, candidate);
                        changed = true;
                    }
                }
            }
        }
        var nodes = self.tree_nodes.keyIterator();
        while (nodes.next()) |k| try buf.append(self.arena, .{ k.*, k.* });
        std.mem.sort([2]EffectResource, buf.items, {}, resourcePairLessThan);
        self.descend = try self.arena.dupe([2]EffectResource, buf.items);
    }

    fn loadDisjoint(self: *Engine, pairs: []const ResourceOrder.Pair, registry: []const ResourceRegistry.Pair) Error!void {
        var buf = std.ArrayList([2]EffectResource).empty;
        for (pairs) |pr| try buf.append(self.arena, try self.normalizePair(pr.a, pr.b));
        for (registry) |pr| try buf.append(self.arena, try self.normalizePair(pr.a, pr.b));
        std.mem.sort([2]EffectResource, buf.items, {}, resourcePairLessThan);
        var dedup = std.ArrayList([2]EffectResource).empty;
        for (buf.items) |pr| {
            if (dedup.items.len > 0) {
                const last = dedup.items[dedup.items.len - 1];
                if (last[0].eql(pr[0]) and last[1].eql(pr[1])) continue;
            }
            try dedup.append(self.arena, pr);
        }
        self.disjoint = try self.arena.dupe([2]EffectResource, dedup.items);
    }

    /// Canonicalize and order one declared disjoint pair.
    fn normalizePair(self: *Engine, x: EffectResource, y: EffectResource) Error![2]EffectResource {
        const a = self.canonical(x);
        const b = self.canonical(y);
        return if (a.lessThan(b)) .{ a, b } else .{ b, a };
    }

    /// The canonical identity of a resource (alias resolution,
    /// docs/effects.md §5.7).
    pub fn canonical(self: *const Engine, r: EffectResource) EffectResource {
        return self.alias_canon.get(r) orelse r;
    }

    /// The alias map to hand the canonicalizer, or null for the identity
    /// map (the common case — no aliasing declared).
    fn aliasPtr(self: *const Engine) ?*const AliasMap {
        if (self.alias_canon.count() == 0) return null;
        return &self.alias_canon;
    }

    /// The resource-level facts this instance's canonicalizer needs
    /// (docs/effects.md §5.7): the alias quotient, the extra unknown name,
    /// and — for the `hierarchy` instance — the downward closure.
    fn canonCtx(self: *const Engine) CanonCtx {
        return .{ .alias = self.aliasPtr(), .extra_unknown = self.unknown_extra, .descend = self.descend };
    }

    /// The `⊤` of this instance: every declared mode wildcarded.
    pub fn top(self: *const Engine) Summary {
        return .{
            .accesses = self.ops.top(self),
            .may_trap = true,
            .may_diverge = true,
            .nondeterministic = true,
        };
    }

    /// The `⊥` of this instance — the empty row, shared with `Pure`.
    pub fn bottom(self: *const Engine) Summary {
        _ = self;
        return pure;
    }

    /// Whether `s` only names modes this provider declared. A value that
    /// does not is invalid and degrades to `top` (docs/effects.md §5.7,
    /// §9.3: a missing declaration is never pure).
    pub fn admits(self: *const Engine, s: Summary) bool {
        if (s.accesses.all & ~self.all_modes != 0) return false;
        for (s.accesses.accesses) |x| {
            if (modeDeclOf(self.modes, x.mode) == null) return false;
        }
        return true;
    }

    fn normalize(self: *const Engine, s: Summary) Summary {
        return if (self.admits(s)) s else self.top();
    }

    /// The conservative closure of a *declaration* value (docs/effects.md
    /// §5.7): a row naming a mode the instance does not declare, or
    /// carrying *any* wildcard, is the universe and becomes this
    /// instance's `top` — so a four-mode `effects.top` can never silently
    /// under-approximate a provider's fifth mode. Anything else is
    /// canonicalized under the instance and used as declared.
    pub fn admitted(self: *const Engine, s: Summary) std.mem.Allocator.Error!Summary {
        if (!self.admits(s)) return self.top();
        if (s.accesses.all != 0) return self.top();
        const acc = try self.ops.canonicalize(self, self.arena, s.accesses.accesses, s.accesses.all);
        return .{
            .accesses = acc,
            .may_trap = s.may_trap,
            .may_diverge = s.may_diverge,
            .nondeterministic = s.nondeterministic,
        };
    }

    /// `E ; F` / `E ⊔ F` — the same may-formula (docs/effects.md §5.4),
    /// computed under this instance's operations.
    pub fn join(self: *const Engine, a: Summary, b: Summary) std.mem.Allocator.Error!Summary {
        if (!self.admits(a) or !self.admits(b)) return self.top();
        const acc = try self.ops.join(self, self.arena, a.accesses, b.accesses);
        return self.normalize(.{
            .accesses = acc,
            .may_trap = a.may_trap or b.may_trap,
            .may_diverge = a.may_diverge or b.may_diverge,
            .nondeterministic = a.nondeterministic or b.nondeterministic,
        });
    }

    pub fn sequence(self: *const Engine, a: Summary, b: Summary) std.mem.Allocator.Error!Summary {
        return self.join(a, b);
    }

    /// `E ⊓ F` — law-test only, like the free `latticeMeet`.
    pub fn meet(self: *const Engine, a: Summary, b: Summary) std.mem.Allocator.Error!Summary {
        if (!self.admits(a) or !self.admits(b)) return self.top();
        const acc = try self.ops.meet(self, self.arena, a.accesses, b.accesses);
        return self.normalize(.{
            .accesses = acc,
            .may_trap = a.may_trap and b.may_trap,
            .may_diverge = a.may_diverge and b.may_diverge,
            .nondeterministic = a.nondeterministic and b.nondeterministic,
        });
    }

    pub fn le(self: *const Engine, a: Summary, b: Summary) bool {
        return self.ops.le(self, a.accesses, b.accesses) and
            (!a.may_trap or b.may_trap) and
            (!a.may_diverge or b.may_diverge) and
            (!a.nondeterministic or b.nondeterministic);
    }

    pub fn eql(self: *const Engine, a: Summary, b: Summary) bool {
        return a.may_trap == b.may_trap and
            a.may_diverge == b.may_diverge and
            a.nondeterministic == b.nondeterministic and
            self.ops.eql(self, a.accesses, b.accesses);
    }

    /// Canonicalize one access row under this instance.
    pub fn canonicalize(self: *const Engine, raw: []const EffectAccess, all: ModeSet) std.mem.Allocator.Error!AccessSet {
        return self.ops.canonicalize(self, self.arena, raw, all);
    }

    /// A summary whose only interaction is the given concrete accesses
    /// (unknown resources fold into the mode flags). Validated *before*
    /// canonicalization: a mode the instance does not declare makes the
    /// whole value `Top`, rather than silently losing the access to a
    /// lossy normalization (docs/effects.md §5.7).
    pub fn summaryOf(self: *const Engine, raw: []const EffectAccess) std.mem.Allocator.Error!Summary {
        for (raw) |x| {
            if (modeDeclOf(self.modes, x.mode) == null) return self.top();
        }
        const acc = try self.ops.canonicalize(self, self.arena, raw, 0);
        return self.normalize(.{
            .accesses = acc,
            .may_trap = false,
            .may_diverge = false,
            .nondeterministic = false,
        });
    }

    pub fn isTotal(self: *const Engine, s: Summary) bool {
        _ = self;
        return totalOf(s);
    }

    pub fn isPure(self: *const Engine, s: Summary) bool {
        _ = self;
        return pureOf(s);
    }

    pub fn isObservableEffectFree(self: *const Engine, s: Summary) bool {
        return self.ops.observable_free(self, s);
    }

    pub fn discardView(self: *const Engine, s: Summary) std.mem.Allocator.Error!Summary {
        if (!self.admits(s)) return self.top();
        return self.ops.discard(self, self.arena, s);
    }

    /// Whether `r` is one of this instance's "any resource" names.
    pub fn isUnknown(self: *const Engine, r: EffectResource) bool {
        if (isUnknownResource(r)) return true;
        const u = self.unknown_extra orelse return false;
        return self.canonical(r).eql(u);
    }

    pub fn isStable(self: *const Engine, r: EffectResource) bool {
        return self.ops.is_stable(self, r);
    }

    /// The resource relation (docs/effects.md §5.7), via the instance's
    /// operation table.
    pub fn relation(self: *const Engine, a: EffectResource, b: EffectResource) Relation {
        return self.ops.relation(self, a, b);
    }

    fn rootOf(self: *const Engine, r: EffectResource) ?EffectResource {
        var cur = r;
        var steps: usize = 0;
        while (self.parents.get(cur)) |p| {
            cur = p;
            steps += 1;
            if (steps > self.parents.count()) return null;
        }
        return cur;
    }

    fn isAncestor(self: *const Engine, ancestor: EffectResource, node: EffectResource) bool {
        var cur = node;
        var steps: usize = 0;
        while (self.parents.get(cur)) |p| {
            if (p.eql(ancestor)) return true;
            cur = p;
            steps += 1;
            if (steps > self.parents.count()) return false;
        }
        return false;
    }

    /// The conflict rule of docs/effects.md §5.6/§5.7, the input to
    /// `canSwapOperands`. Unknown resources conflict; same-resource pairs
    /// go through the instance's commute rule; distinct resources commute
    /// only when the instance's relation says they are disjoint.
    pub fn conflictOf(self: *const Engine, a: EffectAccess, b: EffectAccess) Conflict {
        if (self.isUnknown(a.resource) or self.isUnknown(b.resource)) return .conflict;
        const ca = self.canonical(a.resource);
        const cb = self.canonical(b.resource);
        if (ca.eql(cb)) return self.ops.same_resource(self, .{ .resource = ca, .mode = a.mode }, .{ .resource = cb, .mode = b.mode });
        return switch (self.relation(ca, cb)) {
            .disjoint => .commute,
            .equal, .overlap => .conflict,
        };
    }

    /// Order-compatibility of two summaries for the value positions they
    /// occupy (docs/effects.md §5.6): no conflicting resource access; a
    /// may-trap/-diverge value must not cross the other's observable
    /// accesses; two potentially-failing positions are refused (their
    /// failure order is observable); and a nondeterministic (`Q`) summary
    /// is refused unless the pair is a stable same-domain read pair
    /// (§5.5 carve-out).
    pub fn orderCompatible(self: *const Engine, a: Summary, b: Summary) bool {
        const a_fail = a.may_trap or a.may_diverge;
        const b_fail = b.may_trap or b.may_diverge;
        if (a_fail and b_fail) return false;
        if (a_fail and !self.isObservableEffectFree(b)) return false;
        if (b_fail and !self.isObservableEffectFree(a)) return false;
        if ((a.nondeterministic or b.nondeterministic) and !self.stableReadPair(a, b)) return false;
        if (a.accesses.all != 0 or b.accesses.all != 0) return false;
        for (a.accesses.accesses) |x| {
            for (b.accesses.accesses) |y| {
                if (self.conflictOf(x, y) == .conflict) return false;
            }
        }
        return true;
    }

    /// The §5.5 `stable` carve-out: the sole pair for which a
    /// summary-level `Q` does not veto a swap — both summaries' accesses
    /// are `read_like`, on the same declared-stable domain.
    pub fn stableReadPair(self: *const Engine, a: Summary, b: Summary) bool {
        if (a.accesses.all != 0 or b.accesses.all != 0) return false;
        var any = false;
        for (a.accesses.accesses) |x| {
            const dx = modeDeclOf(self.modes, x.mode) orelse return false;
            if (!dx.read_like) return false;
            for (b.accesses.accesses) |y| {
                const dy = modeDeclOf(self.modes, y.mode) orelse return false;
                if (!dy.read_like) return false;
                if (!self.canonical(x.resource).eql(self.canonical(y.resource))) return false;
                if (!self.isStable(x.resource)) return false;
                any = true;
            }
        }
        return any;
    }
};

/// A *protected* resource (docs/effects.md §5.7, §7.3): a Stilla
/// `ModuleConst`, or one of the wildcard names `.top` / `.host_any`. An
/// instance may neither alias a protected resource nor place it anywhere
/// in its tree. Aliasing a constant would subsume one constant read by
/// another, and a read that disappears is a missed init/teardown
/// dependency — the §7 check reads the row, so the row must keep every
/// constant it names. Aliasing or parenting a wildcard name would change
/// which resources the wildcard covers, which is a different element
/// altogether.
fn isProtected(r: EffectResource) bool {
    return r == .module_const or isUnknownResource(r);
}

/// Union-find over the declared alias spellings; `EffectResource` is not
/// an integer, so the parent map stands in for an index array.
fn aliasRoot(parent: *const std.HashMapUnmanaged(EffectResource, EffectResource, ResourceCtx, std.hash_map.default_max_load_percentage), r: EffectResource) EffectResource {
    var cur = r;
    while (parent.*.get(cur)) |p| cur = p;
    return cur;
}

// ---------------------------------------------------------------------------
// Host metadata + resource registry (docs/effects.md §5.5–§5.6, §13)
// ---------------------------------------------------------------------------

/// Declared host-call semantics. A host binding with no entry is
/// `Top` (docs/effects.md §9.3, §13) — the compiler never assumes a
/// missing declaration is pure. M1b does not wire the embedding ABI;
/// tests supply an analysis-local registry.
pub const HostEffects = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        host: HostBindingId,
        summary: Summary,
        /// docs/effects.md §13. Defaults to `unknown`, so an entry that
        /// declares only resources/traps still gets the full `top` — it
        /// has not established that the binding cannot execute Stilla
        /// code.
        stilla_execution: StillaExecution = .unknown,
        /// The callback contract (docs/effects.md §13), or null when
        /// unspecified. See `HostDecl.callbacks`: it is an attestation
        /// that every Stilla execution this binding causes happens
        /// synchronously, during the same invocation, and only through
        /// callables passed at the listed argument positions.
        callbacks: ?[]const u32 = null,

        /// The summary actually used for this binding (docs/effects.md
        /// §13): the declared one only under an explicit `forbidden`
        /// attestation, otherwise the full `top`. This is the
        /// *context-free* value — a call site may do better (§13
        /// callback parameterization) by consulting `callbacks`.
        pub fn effectiveSummary(self: Entry) Summary {
            return switch (self.stilla_execution) {
                .forbidden => self.summary,
                .may_execute, .unknown => top,
            };
        }
    };

    /// The built-in-mode answer for a binding (docs/effects.md §13): the
    /// declared summary only under an explicit `forbidden` attestation,
    /// otherwise the full *built-in* `top`. A lattice instance that
    /// declares extra modes must close the value with
    /// `Engine.admitted`, or the extra modes are under-approximated —
    /// the analysis does that in `hir_effects.Analysis.hostSummary`.
    pub fn lookup(self: HostEffects, host_id: HostBindingId) ?Summary {
        const e = self.lookupEntry(host_id) orelse return null;
        return e.effectiveSummary();
    }

    /// The raw entry for a binding, contract included — the call-site
    /// path (docs/effects.md §13 callback parameterization) needs
    /// `summary` + `callbacks` before `effectiveSummary` degrades a
    /// `may_execute` binding to `top`.
    pub fn lookupEntry(self: HostEffects, host_id: HostBindingId) ?Entry {
        for (self.entries) |e| {
            if (e.host == host_id) return e;
        }
        return null;
    }

    /// Resolve symbol-keyed ABI declarations (`HostDecl`) against the
    /// bindings a program actually has. Unknown symbols are *ignored*, not
    /// an error: a declaration set describes an embedding, not one program.
    pub fn resolve(
        arena: std.mem.Allocator,
        decls: []const HostDecl,
        bindings: []const HostDeclKey,
    ) std.mem.Allocator.Error!HostEffects {
        if (decls.len == 0) return .{};
        var entries = std.ArrayList(Entry).empty;
        for (decls) |d| {
            for (bindings) |b| {
                if (!std.mem.eql(u8, b.key, d.key)) continue;
                try entries.append(arena, .{
                    .host = b.id,
                    .summary = d.summary,
                    .stilla_execution = d.stilla_execution,
                    .callbacks = d.callbacks,
                });
            }
        }
        return consolidate(arena, entries.items);
    }

    /// Fold declarations of the same binding into one entry, *order
    /// independently*: all declarations must agree. The summaries are
    /// joined. A disagreement on the execution attestation (`forbidden`
    /// vs `may_execute`, say) degrades it to `unknown` — the full `top`
    /// for `effectiveSummary`. A disagreement on the callback contract
    /// only drops callback refinement (`callbacks` becomes null): two
    /// `forbidden` declarations with different contracts still use their
    /// joined summary, because no contract is consulted for a binding
    /// that executes no Stilla code. Neither outcome depends on which
    /// declaration came first.
    pub fn consolidate(arena: std.mem.Allocator, entries: []const Entry) std.mem.Allocator.Error!HostEffects {
        var out = std.ArrayList(Entry).empty;
        for (entries, 0..) |e, i| {
            var already = false;
            for (out.items) |o| {
                if (o.host == e.host) already = true;
            }
            if (already) continue;
            var summary = e.summary;
            var exec = e.stilla_execution;
            var callbacks = e.callbacks;
            for (entries[i + 1 ..]) |later| {
                if (later.host != e.host) continue;
                summary = try join(arena, summary, later.summary);
                // Any disagreement — on the attestation or on the
                // callback contract — is unknown, not a merge. Equal
                // values survive; this is "all equal, else unknown".
                if (later.stilla_execution != exec) exec = .unknown;
                if (!callbacksEqual(callbacks, later.callbacks)) callbacks = null;
            }
            try out.append(arena, .{
                .host = e.host,
                .summary = summary,
                .stilla_execution = exec,
                .callbacks = callbacks,
            });
        }
        return .{ .entries = out.items };
    }
};

/// A host binding's stable identity for the embedding ABI: the qualified
/// `<module specifier>.<member>` symbol, plus the dense id the HIR builder
/// assigned. The symbol is the *key*; the id is a resolution result.
pub const HostDeclKey = struct { key: []const u8, id: HostBindingId };

/// An embedding-side host declaration (docs/effects.md §13), keyed by the
/// stable qualified symbol — the ABI form of the `HostBindingId`-keyed
/// `HostEffects` (ids are assigned by the HIR builder, so only in-tree
/// code can use that form). Declares the *single* `EffectSummary`; there
/// is no second, overlapping read-set fact.
pub const HostDecl = struct {
    key: []const u8,
    summary: Summary,
    stilla_execution: StillaExecution = .unknown,
    /// The callback contract (docs/effects.md §13), or null when
    /// unspecified. A non-null value attests that this binding, on
    /// every invocation, executes Stilla code **only** synchronously and
    /// **only** through a callable passed at one of the listed argument
    /// positions (0-based, callee excluded); a position that holds no
    /// provable finite target set makes the whole call `top`. It is an
    /// embedding attestation, never inferred from a signature; a binding
    /// that stores a callable and invokes it later cannot use it (the
    /// later invocation has no such argument, so it is `top`). Only
    /// meaningful with `may_execute`; `forbidden` needs no contract and
    /// `unknown` is always `top`. Positions are sorted ascending.
    callbacks: ?[]const u32 = null,
};

/// Set equality for callback contracts: both null, or both non-null with
/// the same positions (the lists are stored sorted).
fn callbacksEqual(a: ?[]const u32, b: ?[]const u32) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (p != q) return false;
    return true;
}

/// Whether a host binding may execute Stilla code (docs/effects.md §13).
/// It is a *trusted declaration*, not a compiler inference: a host binding
/// is arbitrary embedder code handed a live VM context, so the compiler
/// cannot prove the property from the runtime API surface (the docs list
/// async/reentrant hosts as a *non-goal*, which is scope, not a
/// guarantee). Missing or unspecified is `unknown`.
pub const StillaExecution = enum {
    /// The embedding claims nothing; treated as `may_execute`.
    unknown,
    /// The binding may execute Stilla code — a callable passed at this
    /// call, one stored by an earlier call, or any other channel back
    /// into the VM. The *context-free* summary (`effectiveSummary`) is
    /// the full `top`: every resource, `may_trap`, `may_diverge`, `Q`,
    /// *and* the module-const read wildcard. A call site can do better
    /// when the binding carries an exhaustive callback contract
    /// (docs/effects.md §13): then the invocation is bounded by the
    /// declared summary joined with the effect bounds of the listed
    /// callables it invokes synchronously.
    may_execute,
    /// The embedding attests the binding executes no Stilla code at all.
    /// Only then is the declared summary used verbatim — so only then is
    /// `host_top` (every host resource, but no `Read(ModuleConst)`)
    /// available as a declaration value.
    forbidden,
};

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

// ---------------------------------------------------------------------------
// Effect-environment fingerprint (docs/effects.md §13)
// ---------------------------------------------------------------------------

/// The embedding's effect environment (docs/effects.md §13): everything
/// outside the program text that can change an effect conclusion — the
/// host-semantics registry generation, the declared effect domains, the
/// domain relations, and the symbol-keyed host declaration set (callback
/// contracts included). It is the semantic half of a compile cache key;
/// the program text is the other half. Not part of any program.
pub const Environment = struct {
    /// Host-semantics registry generation/version, bumped by the
    /// embedding whenever a registry's *meaning* changes without its
    /// declaration set changing (adapter rewrites, domain-table edits).
    registry_generation: u64 = 0,
    /// The **domain inventory** (docs/effects.md §5.2, §5.6): every
    /// effect domain the embedding has registered. `resources` carries
    /// the per-domain `stable` / `disjoint` facts; this is the registry
    /// itself, so a domain added or removed by itself moves the digest.
    domains: []const EffectResource = &.{},
    resources: ResourceRegistry = .{},
    /// The declared lattice provider (docs/effects.md §5.7): instance
    /// identity / version, the mode set, and the resource partial order.
    /// Null = the default `flat` instance over `resources`.
    provider: ?*const Provider = null,
    host_decls: []const HostDecl = &.{},
};

/// Canonical digest of an `Environment` (docs/effects.md §13), the
/// semantic component of a compile cache key. Its job is to make a cache
/// hit improbable when the environment changed, not to *prove* equality:
/// it is a 64-bit digest, so a collision would silently reuse a stale
/// conclusion. It is a staleness guard, never a security boundary. The
/// encoding is explicit and canonical — sorted collections, fixed-width
/// little-endian integers (never native byte order), length-delimited
/// symbols, each summary row canonicalized first — and never hashes raw
/// struct bytes, arena pointers, or a session-local interner id
/// (`ResourceRegistry`'s domain ids are embedding ABI values, not
/// interned handles, so they are included).
pub const EffectEnvironmentFingerprint = struct {
    value: u64 = 0,

    pub fn eql(a: EffectEnvironmentFingerprint, b: EffectEnvironmentFingerprint) bool {
        return a.value == b.value;
    }

    /// Canonicalize and digest `env`. Collection order never changes the
    /// result; adding, removing, or editing any element does.
    pub fn compute(arena: std.mem.Allocator, env: Environment) std.mem.Allocator.Error!EffectEnvironmentFingerprint {
        var h = std.hash.Wyhash.init(0);
        hashU64(&h, env.registry_generation);

        const domains = try arena.dupe(EffectResource, env.domains);
        std.mem.sort(EffectResource, domains, {}, resourceLessThan);
        hashU64(&h, domains.len);
        for (domains) |r| hashResourceInto(&h, r);

        try hashProvider(&h, arena, env.provider);
        try hashResourceRegistry(&h, arena, env.resources);

        const digests = try arena.alloc(u64, env.host_decls.len);
        for (env.host_decls, 0..) |d, i| digests[i] = try declDigest(arena, d);
        std.mem.sort(u64, digests, {}, std.sort.asc(u64));
        hashU64(&h, digests.len);
        for (digests) |d| hashU64(&h, d);
        return .{ .value = h.final() };
    }
};

// Fixed-width little-endian integer encoding: the fingerprint must not
// depend on the host's native byte order, or two machines would key the
// same environment differently. Counts ride `hashU64` even when the
// natural width is smaller, so a length can never be confused with a
// neighbouring field.
fn hashU8(h: *std.hash.Wyhash, v: u8) void {
    h.update(&.{v});
}

fn hashU32(h: *std.hash.Wyhash, v: u32) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    h.update(&buf);
}

fn hashU64(h: *std.hash.Wyhash, v: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    h.update(&buf);
}

fn hashResourceInto(h: *std.hash.Wyhash, r: EffectResource) void {
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

fn hashAccessInto(h: *std.hash.Wyhash, a: EffectAccess) void {
    hashU8(h, @intFromEnum(a.mode));
    hashResourceInto(h, a.resource);
}

/// Hash a *canonical* access row (callers canonicalize first, so an
/// unsorted or `.top`-bearing hand-built `Summary` cannot collide with a
/// different canonical row).
fn hashAccessSetInto(h: *std.hash.Wyhash, set: AccessSet) void {
    hashU64(h, set.all);
    hashU64(h, set.accesses.len);
    for (set.accesses) |a| hashAccessInto(h, a);
}

fn hashSummaryInto(h: *std.hash.Wyhash, s: Summary) void {
    hashAccessSetInto(h, s.accesses);
    hashU8(h, @intFromBool(s.may_trap));
    hashU8(h, @intFromBool(s.may_diverge));
    hashU8(h, @intFromBool(s.nondeterministic));
}

/// One declaration's digest. Keyed on the full content, so editing a
/// summary, the attestation, or the callback contract all change it. The
/// declared summary is canonicalized first: two declarations that differ
/// only in row order describe the same environment and must agree.
fn declDigest(arena: std.mem.Allocator, d: HostDecl) std.mem.Allocator.Error!u64 {
    var h = std.hash.Wyhash.init(0x9e37_79b9_7f4a_7c15);
    hashU64(&h, d.key.len);
    h.update(d.key);
    var canonical = d.summary;
    canonical.accesses = try canonicalize(arena, d.summary.accesses.accesses, d.summary.accesses.all);
    hashSummaryInto(&h, canonical);
    hashU8(&h, @intFromEnum(d.stilla_execution));
    if (d.callbacks) |pos| {
        hashU8(&h, 1);
        hashU64(&h, pos.len);
        for (pos) |p| hashU32(&h, p);
    } else {
        hashU8(&h, 0);
    }
    return h.final();
}

fn resourceLessThan(_: void, a: EffectResource, b: EffectResource) bool {
    return a.lessThan(b);
}

fn resourcePairLessThan(_: void, a: [2]EffectResource, b: [2]EffectResource) bool {
    if (a[0].eql(b[0])) return a[1].lessThan(b[1]);
    return a[0].lessThan(b[0]);
}

/// Hash a resource collection in canonical (sorted) order, so collection
/// order never moves the digest.
fn hashResourceList(h: *std.hash.Wyhash, arena: std.mem.Allocator, list: []const EffectResource) std.mem.Allocator.Error!void {
    const stable = try arena.dupe(EffectResource, list);
    std.mem.sort(EffectResource, stable, {}, resourceLessThan);
    hashU64(h, stable.len);
    for (stable) |r| hashResourceInto(h, r);
}

/// Hash a pair collection in canonical (endpoint-sorted, then sorted)
/// order. Endpoint order carries no meaning, so it is normalized away.
fn hashResourcePairs(h: *std.hash.Wyhash, arena: std.mem.Allocator, pairs: anytype) std.mem.Allocator.Error!void {
    const canon = try arena.alloc([2]EffectResource, pairs.len);
    for (pairs, 0..) |pr, i| {
        canon[i] = if (pr.a.lessThan(pr.b)) .{ pr.a, pr.b } else .{ pr.b, pr.a };
    }
    std.mem.sort([2]EffectResource, canon, {}, resourcePairLessThan);
    hashU64(h, canon.len);
    for (canon) |pr| for (pr) |r| hashResourceInto(h, r);
}

fn hashResourceRegistry(h: *std.hash.Wyhash, arena: std.mem.Allocator, reg: ResourceRegistry) std.mem.Allocator.Error!void {
    try hashResourceList(h, arena, reg.stable);
    try hashResourcePairs(h, arena, reg.disjoint);
}

/// Digest the lattice descriptor (docs/effects.md §5.7): provider
/// identity / version, the mode set, and the resource partial order.
/// A null provider is hashed as the default `flat` instance, so adding
/// the descriptor to an environment cannot silently keep an old digest.
fn hashProvider(h: *std.hash.Wyhash, arena: std.mem.Allocator, provider: ?*const Provider) std.mem.Allocator.Error!void {
    const p: Provider = if (provider) |x| x.* else .{
        .id = default_provider_id,
        .version = default_provider_version,
    };
    hashU64(h, p.id.len);
    h.update(p.id);
    hashU64(h, p.version);

    const modes = try arena.dupe(ModeDecl, p.modes);
    std.mem.sort(ModeDecl, modes, {}, modeDeclLessThan);
    hashU64(h, modes.len);
    for (modes) |d| {
        hashU8(h, @intFromEnum(d.id));
        hashU64(h, d.name.len);
        h.update(d.name);
        hashU8(h, @intFromBool(d.commutative));
        hashU8(h, @intFromBool(d.read_like));
        hashU8(h, @intFromBool(d.observable));
        hashU8(h, @intFromBool(d.discardable));
    }

    hashU8(h, @intFromEnum(std.meta.activeTag(p.order)));
    switch (p.order) {
        .flat => |f| {
            try hashResourceList(h, arena, f.stable);
            try hashResourcePairs(h, arena, f.disjoint);
        },
        .hierarchy => |x| {
            // `parents` is directed (child, parent): normalize only the
            // collection order, never the endpoints.
            const parents = try arena.alloc([2]EffectResource, x.parents.len);
            for (x.parents, 0..) |e, i| parents[i] = .{ e.child, e.parent };
            std.mem.sort([2]EffectResource, parents, {}, resourcePairLessThan);
            hashU64(h, parents.len);
            for (parents) |pr| for (pr) |r| hashResourceInto(h, r);

            try hashResourcePairs(h, arena, x.aliases);
            try hashResourceList(h, arena, x.stable);
            try hashResourcePairs(h, arena, x.disjoint);
            if (x.unknown) |u| {
                hashU8(h, 1);
                hashResourceInto(h, u);
            } else {
                hashU8(h, 0);
            }
        },
    }
}

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

test "effects: the interner binds one lattice instance per program (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var it = try Interner.init(a);
    const flat = try Engine.init(a, null, .{});
    const hier = try Engine.init(a, &example_hierarchy, .{});

    // First analysis binds; the same instance is a no-op.
    try it.ensureInstance(flat.descriptor_digest);
    try it.ensureInstance(flat.descriptor_digest);
    try testing.expectEqual(flat.descriptor_digest, it.boundInstance().?);
    const flat_s = try flat.summaryOf(&.{readOf(host(1))});
    const flat_id = try it.summaryId(flat_s);
    // host(1) has descendants under `hierarchy`, so the two instances'
    // canonical summaries for the same carrier differ.
    try testing.expectEqual(@as(usize, 1), flat_s.accesses.accesses.len);

    // A second, different instance on the same program is a **hard
    // re-bind**: the table wipes every row back to the seeds — the
    // previous instance's rows are dead weight, not facts, and the second
    // analysis re-derives every annotation from scratch. The old id is
    // dead: it no longer indexes a live row.
    try it.ensureInstance(hier.descriptor_digest);
    try testing.expectEqual(hier.descriptor_digest, it.boundInstance().?);
    try testing.expect(flat_id >= it.summaries.items.len);
    // The seeds keep their stable ids under the new instance too; the
    // hierarchy-canonical row (descendants included) interns fresh rather
    // than reusing a flat row.
    try testing.expectEqual(pure_id, try it.summaryId(pure));
    const hier_s = try hier.summaryOf(&.{readOf(host(1))});
    try testing.expectEqual(@as(usize, 3), hier_s.accesses.accesses.len);
    const hier_id = try it.summaryId(hier_s);
    try testing.expect(hier_id >= 2); // a fresh row beyond the seeds
    try testing.expectEqual(@as(usize, 3), it.summary(hier_id).accesses.accesses.len);

    // The explicit `reset` is the same sanctioned re-bind, spelled out.
    try it.reset(flat.descriptor_digest);
    try testing.expect(flat_id >= it.summaries.items.len);
    try testing.expectEqual(flat.descriptor_digest, it.boundInstance().?);
}

test "effects: the engine descriptor digest is order-independent and differs by lattice input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const flat = try Engine.init(a, null, .{});
    const flat2 = try Engine.init(a, &product_provider, .{});
    try testing.expectEqual(flat.descriptor_digest, flat2.descriptor_digest);
    const hier = try Engine.init(a, &example_hierarchy, .{});
    try testing.expect(hier.descriptor_digest != flat.descriptor_digest);

    // Registry (stable / disjoint) is not part of the lattice identity:
    // interned row shape depends on the provider, not on conflict facts.
    const with_stable = try Engine.init(a, null, .{ .stable = &.{host(1)} });
    try testing.expectEqual(flat.descriptor_digest, with_stable.descriptor_digest);
}

test "effects: the real stdlib host-domain tree declares working sibling edges (docs/effects.md §5.6)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The provider validates to a frozen engine with its own descriptor.
    const eng = try Engine.init(a, &stdlib_host_tree, .{});
    try testing.expect(eng.descriptor_digest != (try Engine.init(a, &product_provider, .{})).descriptor_digest);
    const s_list_read = try eng.summaryOf(&.{.{ .resource = .{ .host = domain_list }, .mode = .read }});
    const s_string_read = try eng.summaryOf(&.{.{ .resource = .{ .host = domain_string }, .mode = .read }});
    const s_math_read = try eng.summaryOf(&.{.{ .resource = .{ .host = domain_math }, .mode = .read }});

    // Sibling subtrees under one root are provably disjoint — the edge
    // read pairs swap (they are the same reorder candidate class as the
    // formal example's `host(2)/host(3)`).
    try testing.expect(eng.orderCompatible(s_list_read, s_string_read));
    try testing.expect(eng.orderCompatible(s_list_read, s_math_read));

    // The flat instance over the same readings declines: distinct
    // undeclared domains conflict.
    const flat = try Engine.init(a, null, .{});
    const f_list = try flat.summaryOf(&.{.{ .resource = .{ .host = domain_list }, .mode = .read }});
    const f_math = try flat.summaryOf(&.{.{ .resource = .{ .host = domain_math }, .mode = .read }});
    try testing.expect(!(flat.orderCompatible(f_list, f_math)));

    // The stable declaration only refines conflict-within-one-domain;
    // orderCompatible of one stable read against itself still holds.
    try testing.expect(eng.orderCompatible(s_math_read, s_math_read));
}

test "effects: Pending is not a pure proof" {
    const pending: State = .pending;
    try testing.expect(pending.readyId() == null);
    const ready: State = .{ .ready = pure_id };
    try testing.expectEqual(pure_id, ready.readyId().?);
}

test "effects: host metadata defaults to Top when undeclared (docs/effects.md §13)" {
    // An entry that declares only a summary has *not* established that
    // the binding cannot execute Stilla code, so it is `unknown` and gets
    // the full `top` — declared summary and all.
    const undeclared = HostEffects{ .entries = &.{.{ .host = 7, .summary = may_trap }} };
    try testing.expect(undeclared.lookup(7).?.eql(top));
    try testing.expect(undeclared.lookup(8) == null);

    // Only an explicit `forbidden` attestation lets the declared summary
    // through — that is what makes `host_top` (no module-const read)
    // available at all.
    const attested = HostEffects{ .entries = &.{
        .{ .host = 7, .summary = host_top, .stilla_execution = .forbidden },
    } };
    try testing.expect(attested.lookup(7).?.eql(host_top));
    try testing.expect(!attested.lookup(7).?.eql(top));

    // `may_execute` covers everything an unknown callback can do, not just
    // the reads: resources, trap, diverge, Q and the read wildcard.
    const reentrant = HostEffects{ .entries = &.{
        .{ .host = 7, .summary = pure, .stilla_execution = .may_execute },
    } };
    try testing.expect(reentrant.lookup(7).?.eql(top));
}

test "effects: symbol-keyed host declarations resolve against program bindings" {
    // docs/effects.md §13: the ABI form is keyed by the stable
    // `<module>.<member>` symbol; resolution maps it to the dense id the
    // HIR builder assigned. An unknown symbol is ignored (a declaration
    // set describes an embedding, not one program).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bindings = [_]HostDeclKey{
        .{ .key = "builtin.print", .id = 3 },
        .{ .key = "builtin.str", .id = 4 },
    };
    const decls = [_]HostDecl{
        .{ .key = "builtin.print", .summary = host_top, .stilla_execution = .forbidden },
        .{ .key = "builtin.str", .summary = host_top, .stilla_execution = .forbidden },
        .{ .key = "other.module", .summary = pure, .stilla_execution = .forbidden },
    };
    const resolved = try HostEffects.resolve(arena.allocator(), &decls, &bindings);
    try testing.expectEqual(@as(usize, 2), resolved.entries.len);
    try testing.expect(resolved.lookup(3).?.eql(host_top));
    try testing.expect(resolved.lookup(4).?.eql(host_top));

    // Contradictory declarations for one binding degrade to `unknown`
    // (hence `top`) *regardless of order* — never "last one wins".
    const one = [_]HostDeclKey{.{ .key = "builtin.print", .id = 3 }};
    const forked = [_][2]HostDecl{
        .{
            .{ .key = "builtin.print", .summary = host_top, .stilla_execution = .forbidden },
            .{ .key = "builtin.print", .summary = pure, .stilla_execution = .may_execute },
        },
        .{
            .{ .key = "builtin.print", .summary = pure, .stilla_execution = .may_execute },
            .{ .key = "builtin.print", .summary = host_top, .stilla_execution = .forbidden },
        },
    };
    for (forked) |d| {
        const r = try HostEffects.resolve(arena.allocator(), &d, &one);
        try testing.expectEqual(@as(usize, 1), r.entries.len);
        try testing.expect(r.lookup(3).?.eql(top));
    }

    // Agreeing duplicates join their summaries and keep the attestation.
    const agreed = [_]HostDecl{
        .{ .key = "builtin.print", .summary = may_trap, .stilla_execution = .forbidden },
        .{ .key = "builtin.print", .summary = pure, .stilla_execution = .forbidden },
    };
    const joined = try HostEffects.resolve(arena.allocator(), &agreed, &one);
    try testing.expectEqual(@as(usize, 1), joined.entries.len);
    try testing.expect(joined.lookup(3).?.eql(may_trap));
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

test "effects: fingerprint is order independent and tracks every environment dimension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pos0 = [_]u32{0};
    const d1 = HostDecl{ .key = "random.next", .summary = host_top, .stilla_execution = .forbidden };
    const d2 = HostDecl{ .key = "random.emit", .summary = may_trap, .stilla_execution = .may_execute, .callbacks = &pos0 };
    const base = Environment{ .registry_generation = 7, .host_decls = &.{ d1, d2 } };
    const canon = try EffectEnvironmentFingerprint.compute(a, base);
    try testing.expect(canon.eql(try EffectEnvironmentFingerprint.compute(a, base)));

    // Declaration order never changes the digest...
    const reordered = try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 7, .host_decls = &.{ d2, d1 } });
    try testing.expect(canon.eql(reordered));
    // ...but a duplicate declaration is a different set.
    const duped = try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 7, .host_decls = &.{ d1, d2, d1 } });
    try testing.expect(!canon.eql(duped));

    // Each environment dimension changes the digest: registry generation,
    // the declaration set, a declaration's summary/attestation, its
    // callback contract, and the resource registry.
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 8, .host_decls = &.{ d1, d2 } })));
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 7, .host_decls = &.{d1} })));
    const edit = HostDecl{ .key = "random.emit", .summary = top, .stilla_execution = .may_execute, .callbacks = &pos0 };
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 7, .host_decls = &.{ d1, edit } })));
    const nocb = HostDecl{ .key = "random.emit", .summary = may_trap, .stilla_execution = .may_execute };
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 7, .host_decls = &.{ d1, nocb } })));
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{
        .registry_generation = 7,
        .resources = .{ .stable = &.{host(1)} },
        .host_decls = &.{ d1, d2 },
    })));
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{
        .registry_generation = 7,
        .resources = .{ .disjoint = &.{.{ .a = host(1), .b = host(2) }} },
        .host_decls = &.{ d1, d2 },
    })));
    // ...and the domain inventory, independently of the relations.
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{
        .registry_generation = 7,
        .domains = &.{host(1)},
        .host_decls = &.{ d1, d2 },
    })));
    // The domain inventory is canonicalized too.
    const dom_ab = try EffectEnvironmentFingerprint.compute(a, .{ .domains = &.{ host(1), host(2) } });
    const dom_ba = try EffectEnvironmentFingerprint.compute(a, .{ .domains = &.{ host(2), host(1) } });
    try testing.expect(dom_ab.eql(dom_ba));

    // The resource registry is canonicalized too.
    const res2 = try EffectEnvironmentFingerprint.compute(a, .{
        .registry_generation = 7,
        .resources = .{ .stable = &.{ host(1), host(2) }, .disjoint = &.{.{ .a = host(2), .b = host(1) }} },
        .host_decls = &.{ d1, d2 },
    });
    const res3 = try EffectEnvironmentFingerprint.compute(a, .{
        .registry_generation = 7,
        .resources = .{ .stable = &.{ host(2), host(1) }, .disjoint = &.{.{ .a = host(1), .b = host(2) }} },
        .host_decls = &.{ d1, d2 },
    });
    try testing.expect(res2.eql(res3));

    // The execution attestation alone, and a callback position change
    // alone, both move the digest.
    const exec_edit = HostDecl{ .key = "random.emit", .summary = may_trap, .stilla_execution = .forbidden, .callbacks = &pos0 };
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 7, .host_decls = &.{ d1, exec_edit } })));
    const pos1 = [_]u32{1};
    const cb_edit = HostDecl{ .key = "random.emit", .summary = may_trap, .stilla_execution = .may_execute, .callbacks = &pos1 };
    try testing.expect(!canon.eql(try EffectEnvironmentFingerprint.compute(a, .{ .registry_generation = 7, .host_decls = &.{ d1, cb_edit } })));

    // Rows are canonicalized before hashing: the same accesses in a
    // different order (with a duplicate) describe the same environment.
    const raw_row = HostDecl{ .key = "same", .summary = .{
        .accesses = .{ .accesses = &.{ readOf(host(2)), readOf(host(1)), readOf(host(2)) } },
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = false,
    } };
    const canon_row = HostDecl{ .key = "same", .summary = try mks(a, &.{ readOf(host(1)), readOf(host(2)) }) };
    const raw_fp = try EffectEnvironmentFingerprint.compute(a, .{ .host_decls = &.{raw_row} });
    const canon_fp = try EffectEnvironmentFingerprint.compute(a, .{ .host_decls = &.{canon_row} });
    try testing.expect(raw_fp.eql(canon_fp));
}

test "effects: callback contracts survive resolution and contradicting duplicates degrade to unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bindings = [_]HostDeclKey{.{ .key = "loop.emit", .id = 5 }};
    const pos = [_]u32{1};

    // The contract is carried from the declaration to the resolved entry.
    const decls = [_]HostDecl{
        .{ .key = "loop.emit", .summary = may_trap, .stilla_execution = .may_execute, .callbacks = &pos },
    };
    const r = try HostEffects.resolve(a, &decls, &bindings);
    try testing.expectEqual(@as(usize, 1), r.entries.len);
    try testing.expect(r.lookupEntry(5).?.callbacks != null);
    try testing.expectEqual(@as(u32, 1), r.lookupEntry(5).?.callbacks.?[0]);
    // Context-free lookup stays conservative under `may_execute`.
    try testing.expect(r.lookup(5).?.eql(top));

    // A duplicate with a different contract makes the contract unknown
    // (not a merge), regardless of order; an identical duplicate keeps it.
    const forked = [_][2]HostDecl{
        .{
            .{ .key = "loop.emit", .summary = may_trap, .stilla_execution = .may_execute, .callbacks = &pos },
            .{ .key = "loop.emit", .summary = pure, .stilla_execution = .may_execute },
        },
        .{
            .{ .key = "loop.emit", .summary = pure, .stilla_execution = .may_execute },
            .{ .key = "loop.emit", .summary = may_trap, .stilla_execution = .may_execute, .callbacks = &pos },
        },
    };
    for (forked) |d| {
        const fr = try HostEffects.resolve(a, &d, &bindings);
        try testing.expect(fr.lookupEntry(5).?.callbacks == null);
    }
    const agreed = [_]HostDecl{
        .{ .key = "loop.emit", .summary = may_trap, .stilla_execution = .may_execute, .callbacks = &pos },
        .{ .key = "loop.emit", .summary = pure, .stilla_execution = .may_execute, .callbacks = &pos },
    };
    const ar = try HostEffects.resolve(a, &agreed, &bindings);
    try testing.expect(ar.lookupEntry(5).?.callbacks != null);
    try testing.expect(ar.lookupEntry(5).?.summary.eql(may_trap));
}

// ---------------------------------------------------------------------------
// Lattice-engine tests (docs/effects.md §5.7)
// ---------------------------------------------------------------------------

/// The case set every instance's law test runs over: the control-bit
/// corners plus rows that exercise a wildcard, a concrete access pair,
/// and (under `hierarchy`) an alias.
fn engineCases(a: std.mem.Allocator, eng: *const Engine) ![]Summary {
    var list = std.ArrayList(Summary).empty;
    try list.append(a, pure);
    try list.append(a, may_trap);
    try list.append(a, may_diverge);
    try list.append(a, eng.top());
    try list.append(a, Summary{ .accesses = .{}, .may_trap = false, .may_diverge = false, .nondeterministic = true });
    try list.append(a, try eng.summaryOf(&.{ writeOf(host(1)), readOf(host(2)) }));
    try list.append(a, try eng.summaryOf(&.{ readOf(host(2)), readOf(host(5)) }));
    return list.items;
}

test "effects: lattice laws are instance-parameterized (docs/effects.md §5.7)" {
    const instances = [_]struct { name: []const u8, provider: ?*const Provider }{
        .{ .name = "flat", .provider = null },
        .{ .name = "hierarchy", .provider = &example_hierarchy },
    };
    for (instances) |inst| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var eng = try Engine.init(a, inst.provider, .{});
        const cases = try engineCases(a, &eng);
        for (cases) |x| {
            for (cases) |y| {
                for (cases) |z| {
                    const xy = try eng.join(x, y);
                    const yx = try eng.join(y, x);
                    const mx = try eng.meet(x, y);
                    const my = try eng.meet(y, x);
                    // commutative
                    try testing.expect(xy.eql(yx));
                    try testing.expect(mx.eql(my));
                    // associative
                    try testing.expect((try eng.join(xy, z)).eql(try eng.join(x, try eng.join(y, z))));
                    try testing.expect((try eng.meet(mx, z)).eql(try eng.meet(x, try eng.meet(y, z))));
                    // idempotent
                    try testing.expect((try eng.join(x, x)).eql(x));
                    try testing.expect((try eng.meet(x, x)).eql(x));
                    // absorption
                    try testing.expect((try eng.meet(x, xy)).eql(x));
                    try testing.expect((try eng.join(x, mx)).eql(x));
                    // monotone
                    try testing.expect(eng.le(x, xy));
                    try testing.expect(eng.le(y, xy));
                    try testing.expect(eng.le(mx, x));
                    try testing.expect(eng.le(mx, y));
                    // two-argument monotonicity: x ≤ x ⊔ y ⇒ f(x, z) ≤ f(x ⊔ y, z)
                    try testing.expect(eng.le(try eng.join(x, z), try eng.join(xy, z)));
                    try testing.expect(eng.le(try eng.meet(x, z), try eng.meet(xy, z)));
                    // `;` and `⊔` share the may-formula (docs/effects.md §5.4)
                    try testing.expect((try eng.sequence(x, y)).eql(xy));
                    // bottom is the identity, top absorbs
                    try testing.expect((try eng.join(eng.bottom(), x)).eql(x));
                    try testing.expect((try eng.join(eng.top(), x)).eql(eng.top()));
                    // `≤` is a partial order (docs/effects.md §5.4): reflexive,
                    // antisymmetric, transitive.
                    try testing.expect(eng.le(x, x));
                    if (eng.le(x, y) and eng.le(y, x)) try testing.expect(eng.eql(x, y));
                    if (eng.le(x, y) and eng.le(y, z)) try testing.expect(eng.le(x, z));
                }
            }
        }
    }
}

test "effects: the default instance's flat behaviour is unchanged (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var eng = try Engine.init(a, null, .{});
    try testing.expect(eng.top().eql(top));
    try testing.expect(eng.bottom().eql(pure));
    try testing.expectEqual(@as(ModeSet, builtin_mode_set), eng.all_modes);
    try testing.expect(eng.admits(top));
    try testing.expect(!eng.admits(Summary{
        .accesses = try mkSet(a, &.{.{ .resource = host(1), .mode = mode_commute_update }}),
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = false,
    }));
    // An undeclared mode degrades to `top`, never to a silent under-approximation.
    const bad = Summary{
        .accesses = try mkSet(a, &.{.{ .resource = host(1), .mode = mode_commute_update }}),
        .may_trap = false,
        .may_diverge = false,
        .nondeterministic = false,
    };
    try testing.expect((try eng.join(bad, pure)).eql(top));
    // A row that only differs from the free-function form by nothing at all.
    const raw = [_]EffectAccess{ writeOf(host(7)), readOf(host(8)) };
    try testing.expect((try eng.summaryOf(&raw)).eql(try summaryOf(a, &raw)));
}

test "effects: hierarchy changes conflict precision and mode legality (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var flat = try Engine.init(a, null, .{});
    var hier = try Engine.init(a, &example_hierarchy, .{});

    const r2 = readOf(host(2));
    const r3 = readOf(host(3));
    const r5 = readOf(host(5));

    // Sibling subtrees: provably disjoint under `hierarchy`, undeclared
    // (hence conflicting) under `flat`.
    try testing.expectEqual(Relation.disjoint, hier.relation(host(2), host(3)));
    try testing.expectEqual(Relation.overlap, flat.relation(host(2), host(3)));
    try testing.expectEqual(Conflict.commute, hier.conflictOf(r2, r3));
    try testing.expectEqual(Conflict.conflict, flat.conflictOf(r2, r3));
    // Ancestor / descendant overlaps, and so does a resource outside the
    // tree: a missing edge costs precision, never soundness.
    try testing.expectEqual(Relation.overlap, hier.relation(host(1), host(2)));
    try testing.expectEqual(Relation.overlap, hier.relation(host(1), host(4)));
    try testing.expectEqual(Relation.overlap, hier.relation(host(2), host(4)));
    // Two declared trees are disjoint.
    try testing.expectEqual(Relation.disjoint, hier.relation(host(2), host(7)));

    // Aliases are a quotient: `host(5)` *is* `host(2)`.
    try testing.expectEqual(Relation.equal, hier.relation(host(5), host(2)));
    try testing.expectEqual(Conflict.conflict, hier.conflictOf(r5, writeOf(host(2))));
    try testing.expectEqual(Conflict.commute, hier.conflictOf(r5, r2));
    const joined = try hier.join(try hier.summaryOf(&.{r5}), try hier.summaryOf(&.{r2}));
    try testing.expectEqual(@as(usize, 1), joined.accesses.accesses.len);
    // The alias is a quotient of the *row*, so flat keeps both spellings.
    const flat_joined = try flat.join(try flat.summaryOf(&.{r5}), try flat.summaryOf(&.{r2}));
    try testing.expectEqual(@as(usize, 2), flat_joined.accesses.accesses.len);

    // The added mode's `commutative` flag is a legality difference: a
    // `commute_update` beside a `read` on the same stable resource
    // commutes under `hierarchy` and conflicts under the default mode set.
    const upd = EffectAccess{ .resource = host(2), .mode = mode_commute_update };
    try testing.expectEqual(Conflict.commute, hier.conflictOf(upd, r2));
    try testing.expectEqual(Conflict.conflict, flat.conflictOf(upd, r2));
    const upd_s = try hier.summaryOf(&.{upd});
    const read_s = try hier.summaryOf(&.{r2});
    try testing.expect(hier.orderCompatible(upd_s, read_s));
    try testing.expect(!flat.orderCompatible(upd_s, read_s)); // undeclared mode, fail closed

    // The added mode is observable and non-discardable, so it blocks the
    // derived discard query.
    try testing.expect(!hier.isObservableEffectFree(upd_s));
    try testing.expect(!hier.isPure(try hier.discardView(upd_s)));
    try testing.expect(hier.admits(upd_s));
    try testing.expect(!flat.admits(upd_s));
}

test "effects: an invalid provider declaration is rejected (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A mode set missing a built-in mode.
    const partial = Provider{
        .id = "bad.partial",
        .modes = default_modes[0..3],
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &partial, .{}));

    // A duplicate mode id.
    const duped = default_modes ++ [_]ModeDecl{default_modes[0]};
    const dup_provider = Provider{ .id = "bad.duplicate", .modes = &duped };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &dup_provider, .{}));

    // A cyclic domain forest.
    const cyclic = Provider{
        .id = "bad.cycle",
        .order = .{ .hierarchy = .{ .parents = &.{
            .{ .child = .{ .host = 1 }, .parent = .{ .host = 2 } },
            .{ .child = .{ .host = 2 }, .parent = .{ .host = 1 } },
        } } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &cyclic, .{}));

    // Two parents for one child is not a forest.
    const two_parents = Provider{
        .id = "bad.two-parents",
        .order = .{ .hierarchy = .{ .parents = &.{
            .{ .child = .{ .host = 2 }, .parent = .{ .host = 1 } },
            .{ .child = .{ .host = 2 }, .parent = .{ .host = 3 } },
        } } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &two_parents, .{}));
}

test "effects: the fingerprint tracks the lattice descriptor (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try EffectEnvironmentFingerprint.compute(a, .{ .provider = &example_hierarchy });
    try testing.expect(base.eql(try EffectEnvironmentFingerprint.compute(a, .{ .provider = &example_hierarchy })));

    // Instance identity and revision both move the digest.
    const renamed = Provider{ .id = "stilla.hierarchy.other", .version = 1, .modes = &hierarchy_modes, .order = example_hierarchy.order };
    try testing.expect(!base.eql(try EffectEnvironmentFingerprint.compute(a, .{ .provider = &renamed })));
    const revised = Provider{ .id = example_hierarchy.id, .version = 2, .modes = &hierarchy_modes, .order = example_hierarchy.order };
    try testing.expect(!base.eql(try EffectEnvironmentFingerprint.compute(a, .{ .provider = &revised })));

    // A mode-set change (flag edit included) moves it.
    const flagged = hierarchy_modes;
    var edited = flagged;
    edited[4] = .{ .id = mode_commute_update, .name = "commute_update", .commutative = false, .observable = true, .discardable = false };
    const flag_provider = Provider{ .id = example_hierarchy.id, .version = 1, .modes = &edited, .order = example_hierarchy.order };
    try testing.expect(!base.eql(try EffectEnvironmentFingerprint.compute(a, .{ .provider = &flag_provider })));

    // A resource-order change moves it...
    const reparented = Provider{
        .id = example_hierarchy.id,
        .version = 1,
        .modes = &hierarchy_modes,
        .order = .{ .hierarchy = .{
            .parents = &.{
                .{ .child = .{ .host = 2 }, .parent = .{ .host = 3 } },
                .{ .child = .{ .host = 3 }, .parent = .{ .host = 1 } },
            },
            .aliases = &.{.{ .a = .{ .host = 5 }, .b = .{ .host = 2 } }},
            .stable = &.{ .{ .host = 1 }, .{ .host = 2 } },
        } },
    };
    try testing.expect(!base.eql(try EffectEnvironmentFingerprint.compute(a, .{ .provider = &reparented })));

    // ...while declaration order does not: the same tree written in the
    // other order (and the alias written the other way round) is the same
    // environment.
    const shuffled = Provider{
        .id = example_hierarchy.id,
        .version = 1,
        .modes = &hierarchy_modes,
        .order = .{ .hierarchy = .{
            .parents = &.{
                .{ .child = .{ .host = 7 }, .parent = .{ .host = 6 } },
                .{ .child = .{ .host = 3 }, .parent = .{ .host = 1 } },
                .{ .child = .{ .host = 2 }, .parent = .{ .host = 1 } },
            },
            .aliases = &.{.{ .a = .{ .host = 2 }, .b = .{ .host = 5 } }},
            .stable = &.{ .{ .host = 2 }, .{ .host = 1 } },
        } },
    };
    try testing.expect(base.eql(try EffectEnvironmentFingerprint.compute(a, .{ .provider = &shuffled })));

    // The default instance is hashed as a descriptor too, so declaring it
    // explicitly is the same environment as declaring nothing.
    const explicit_flat = Provider{ .id = default_provider_id, .version = default_provider_version };
    try testing.expect((try EffectEnvironmentFingerprint.compute(a, .{})).eql(
        try EffectEnvironmentFingerprint.compute(a, .{ .provider = &explicit_flat }),
    ));
    try testing.expect(!(try EffectEnvironmentFingerprint.compute(a, .{})).eql(base));
}

test "effects: an instance-declared unknown resource folds into the mode wildcard (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const provider = Provider{
        .id = "stilla.hierarchy.unknown",
        .order = .{ .hierarchy = .{ .unknown = .{ .host = 9 } } },
    };
    var eng = try Engine.init(a, &provider, .{});
    const s = try eng.summaryOf(&.{readOf(host(9))});
    try testing.expect(s.accesses.wildcard(.read));
    try testing.expectEqual(@as(usize, 0), s.accesses.accesses.len);
    // The fold survives the instance's own composition...
    const joined = try eng.join(s, try eng.summaryOf(&.{writeOf(host(1))}));
    try testing.expect(joined.accesses.wildcard(.read));
    // The concrete write beside it is untouched by the fold.
    try testing.expectEqual(@as(usize, 1), joined.accesses.accesses.len);
    try testing.expectEqual(.write, joined.accesses.accesses[0].mode);
    // ...and the resource conflicts with everything, like `.top`.
    try testing.expect(eng.isUnknown(host(9)));
    try testing.expectEqual(Conflict.conflict, eng.conflictOf(readOf(host(9)), readOf(host(1))));
    // A resource the instance does not name stays concrete.
    const concrete = try eng.summaryOf(&.{readOf(host(1))});
    try testing.expect(!concrete.accesses.wildcard(.read));
    try testing.expectEqual(@as(usize, 1), concrete.accesses.accesses.len);
}

test "effects: an instance-declared unknown may not be placed in the tree or aliased (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The declared `unknown` is a wildcard: as a tree *parent* or
    // *child*, or an alias endpoint, it would either change the
    // wildcard's coverage or leak concrete into canonical rows via the
    // downward closure — an invalid provider, not a silently degraded
    // one (docs/effects.md §5.4/§5.7).
    const as_child = Provider{
        .id = "stilla.bad.unknown-tree",
        .order = .{ .hierarchy = .{
            .unknown = .{ .host = 9 },
            .parents = &.{.{ .child = .{ .host = 9 }, .parent = .{ .host = 1 } }},
        } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &as_child, .{}));

    const as_parent = Provider{
        .id = "stilla.bad.unknown-tree",
        .order = .{ .hierarchy = .{
            .unknown = .{ .host = 9 },
            .parents = &.{.{ .child = .{ .host = 1 }, .parent = .{ .host = 9 } }},
        } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &as_parent, .{}));

    const as_alias = Provider{
        .id = "stilla.bad.unknown-alias",
        .order = .{ .hierarchy = .{
            .unknown = .{ .host = 9 },
            .aliases = &.{.{ .a = .{ .host = 9 }, .b = .{ .host = 5 } }},
        } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &as_alias, .{}));
}

test "effects: alias class identity does not depend on declaration order (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stable = [_]EffectResource{.{ .host = 2 }};
    const fwd = Provider{
        .id = "stilla.test.alias-order",
        .version = 1,
        .modes = &hierarchy_modes,
        .order = .{ .hierarchy = .{
            .aliases = &.{.{ .a = .{ .host = 5 }, .b = .{ .host = 2 } }},
            .stable = &stable,
        } },
    };
    const rev = Provider{
        .id = "stilla.test.alias-order",
        .version = 1,
        .modes = &hierarchy_modes,
        .order = .{ .hierarchy = .{
            .aliases = &.{.{ .a = .{ .host = 2 }, .b = .{ .host = 5 } }},
            .stable = &stable,
        } },
    };
    var ea = try Engine.init(a, &fwd, .{});
    var eb = try Engine.init(a, &rev, .{});

    // The descriptor digests agree...
    try testing.expect((try EffectEnvironmentFingerprint.compute(a, .{ .provider = &fwd })).eql(
        try EffectEnvironmentFingerprint.compute(a, .{ .provider = &rev }),
    ));
    // ...and so do the semantics: one representative, one stability
    // answer, one conflict verdict. The representative is the least
    // member of the class, so both spellings resolve to `host(2)`.
    try testing.expect(ea.canonical(.{ .host = 5 }).eql(eb.canonical(.{ .host = 5 })));
    try testing.expect(ea.canonical(.{ .host = 5 }).eql(.{ .host = 2 }));
    try testing.expectEqual(eb.isStable(.{ .host = 5 }), ea.isStable(.{ .host = 5 }));
    try testing.expect(ea.isStable(.{ .host = 2 }));
    try testing.expectEqual(
        ea.conflictOf(readOf(.{ .host = 5 }), readOf(.{ .host = 2 })),
        eb.conflictOf(readOf(.{ .host = 5 }), readOf(.{ .host = 2 })),
    );
    try testing.expectEqual(Conflict.commute, ea.conflictOf(readOf(.{ .host = 5 }), readOf(.{ .host = 2 })));
}

test "effects: an unrepresentable mode is never dropped by canonicalization (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out_of_range: ModeId = @enumFromInt(max_mode_count);
    const raw = [_]EffectAccess{.{ .resource = .{ .host = 1 }, .mode = out_of_range }};

    // The engine validates before it canonicalizes, so the request is
    // `top` rather than a silent empty row.
    var eng = try Engine.init(a, &example_hierarchy, .{});
    try testing.expect((try eng.summaryOf(&raw)).eql(eng.top()));
    // The free default entry point has no mode set to validate against, so
    // it must keep the access instead of dropping it.
    const s = try summaryOf(a, &raw);
    try testing.expectEqual(@as(usize, 1), s.accesses.accesses.len);
    try testing.expect(!isObservableEffectFree(s));
    try testing.expect(!isPure(try discardView(a, s)));
    try testing.expect(!(try eng.join(s, pure)).eql(pure));
}

test "effects: an instance may not alias or parent a ModuleConst (docs/effects.md §5.7, §7.3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mc = EffectResource{ .module_const = 3 };

    const aliased = Provider{
        .id = "bad.ns.alias",
        .order = .{ .hierarchy = .{ .aliases = &.{.{ .a = mc, .b = .{ .host = 1 } }} } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &aliased, .{}));

    const child = Provider{
        .id = "bad.ns.child",
        .order = .{ .hierarchy = .{ .parents = &.{.{ .child = mc, .parent = .{ .host = 1 } }} } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &child, .{}));

    const parent = Provider{
        .id = "bad.ns.parent",
        .order = .{ .hierarchy = .{ .parents = &.{.{ .child = .{ .host = 1 }, .parent = mc }} } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &parent, .{}));

    // Two constants under one root (or one under the other) is rejected
    // too: an ancestor subsumes the more specific read, so the more
    // specific constant stops being named.
    const const_parent = Provider{
        .id = "bad.ns.const-parent",
        .order = .{ .hierarchy = .{ .parents = &.{.{ .child = mc, .parent = .{ .module_const = 4 } }} } },
    };
    try testing.expectError(error.InvalidProvider, Engine.init(a, &const_parent, .{}));
}

test "effects: hierarchy inclusion changes the order, join and meet (docs/effects.md §5.7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var flat = try Engine.init(a, null, .{});
    var hier = try Engine.init(a, &example_hierarchy, .{});

    // `example_hierarchy` declares host(1) as the parent of host(2) and
    // host(3), so `child ≤ parent`: an access to host(1) reaches all three
    // and an access to host(2) reaches only host(2).
    const parent = try hier.summaryOf(&.{readOf(host(1))});
    const child = try hier.summaryOf(&.{readOf(host(2))});
    const sibling = try hier.summaryOf(&.{readOf(host(3))});
    try testing.expectEqual(@as(usize, 3), parent.accesses.accesses.len);
    try testing.expectEqual(@as(usize, 1), child.accesses.accesses.len);

    // The element order is the instance's: `{child} ≤ {parent}` under
    // `hierarchy`, incomparable under the product instance.
    try testing.expect(hier.le(child, parent));
    try testing.expect(!hier.le(parent, child));
    const fparent = try flat.summaryOf(&.{readOf(host(1))});
    const fchild = try flat.summaryOf(&.{readOf(host(2))});
    try testing.expect(!flat.le(fchild, fparent));
    try testing.expect(!flat.le(fparent, fchild));

    // Union and intersection follow from the order: the child's access is
    // already inside the parent's, so `{parent} ⊔ {child}` *is* the
    // parent, and `{parent} ⊓ {child}` is the child.
    try testing.expect((try hier.join(parent, child)).eql(parent));
    try testing.expect((try hier.meet(parent, child)).eql(child));
    // Disjoint siblings meet to the bottom.
    try testing.expect((try hier.meet(child, sibling)).eql(pure));
    // The product instance keeps both accesses distinct and meets to
    // bottom.
    const fjoined = try flat.join(fparent, fchild);
    try testing.expectEqual(@as(usize, 2), fjoined.accesses.accesses.len);
    try testing.expect((try flat.meet(fparent, fchild)).eql(pure));
    // Both instances still satisfy the laws they are asked to (the
    // parameterized law test is the general form of this).
    try testing.expect(hier.le(try hier.meet(parent, child), parent));
    try testing.expect(hier.le(parent, try hier.join(parent, child)));
}
