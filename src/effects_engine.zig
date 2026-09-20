//! The lattice *engine* (docs/effects.md §5.7): a provider's declarations
//! (the mode set with its `commutative` / `observable` / `discardable`
//! flags, and the resource partial order) interned once at session start
//! into a frozen `Engine`, plus the operation table (`Ops`), the shared
//! product algebra over canonical rows, the default `ProductLattice`
//! instance, and the example provider declarations
//! (`product_provider`, `example_hierarchy`, `stdlib_host_tree`) with the
//! standard-library host-domain ids. The lattice *algebra* is shared by
//! every instance; an instance changes only canonicalization (aliasing is
//! a quotient) and the conflict query (disjointness is declared). A
//! summary naming a mode the instance never declared is invalid and
//! degrades to `Top`, never to an under-approximation (docs/effects.md
//! §9.3).

const std = @import("std");
const lattice = @import("effects_lattice.zig");
const registry_mod = @import("effects_registry.zig");
const hash = @import("effects_hash.zig");
const conflict_mod = @import("effects_conflict.zig");
const AccessSet = lattice.AccessSet;
const AliasMap = lattice.AliasMap;
const CanonCtx = lattice.CanonCtx;
const Conflict = conflict_mod.Conflict;
const EffectAccess = lattice.EffectAccess;
const EffectResource = lattice.EffectResource;
const HostDomainId = lattice.HostDomainId;
const ModeDecl = lattice.ModeDecl;
const ModeId = lattice.ModeId;
const ModeSet = lattice.ModeSet;
const ResourceCtx = lattice.ResourceCtx;
const Summary = lattice.Summary;
const mode_count = lattice.mode_count;
const max_mode_count = lattice.max_mode_count;
const modeBit = lattice.modeBit;
const modeDeclOf = lattice.modeDeclOf;
const modeDeclLessThan = lattice.modeDeclLessThan;
const canonicalizeMapped = lattice.canonicalizeMapped;
const contains = lattice.contains;
const default_modes = lattice.default_modes;
const isUnknownResource = lattice.isUnknownResource;
const isObservableEffectFreeWith = lattice.isObservableEffectFreeWith;
const discardViewWith = lattice.discardViewWith;
const pure = lattice.pure;
const totalOf = lattice.totalOf;
const pureOf = lattice.pureOf;
const ResourceRegistry = registry_mod.ResourceRegistry;
const hashU8 = hash.hashU8;
const hashU64 = hash.hashU64;
const hashResourceInto = hash.hashResourceInto;
const hashAccessSetInto = hash.hashAccessSetInto;
const hashResourceList = hash.hashResourceList;
const hashResourcePairs = hash.hashResourcePairs;
const resourcePairLessThan = hash.resourcePairLessThan;

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

/// Digest the lattice descriptor (docs/effects.md §5.7): provider
/// identity / version, the mode set, and the resource partial order.
/// A null provider is hashed as the default `flat` instance, so adding
/// the descriptor to an environment cannot silently keep an old digest.
pub fn hashProvider(h: *std.hash.Wyhash, arena: std.mem.Allocator, provider: ?*const Provider) std.mem.Allocator.Error!void {
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
// ===========================================================================
// Tests — the lattice engine and instances (docs/effects.md §5.7)
// ===========================================================================

const testing = std.testing;

const host_mod = @import("effects_host.zig");
const Interner = lattice.Interner;
const builtin_mode_set = lattice.builtin_mode_set;
const canonicalize = lattice.canonicalize;
const discardView = lattice.discardView;
const isObservableEffectFree = lattice.isObservableEffectFree;
const isPure = lattice.isPure;
const top = lattice.top;
const may_trap = lattice.may_trap;
const may_diverge = lattice.may_diverge;
const pure_id = lattice.pure_id;
const top_id = lattice.top_id;
const summaryOf = lattice.summaryOf;
const EffectEnvironmentFingerprint = host_mod.EffectEnvironmentFingerprint;

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
