//! Host metadata + effect-environment fingerprint (docs/effects.md §5.5,
//! §13): the symbol-keyed `HostDecl` / id-keyed `HostEffects` host
//! semantics, the `StillaExecution` attestation, callback contracts, and
//! the canonical `EffectEnvironmentFingerprint` of an embedding
//! `Environment`. A host binding with no entry / declaration is `Top`
//! (docs/effects.md §9.3): the compiler never assumes a missing
//! declaration is pure.

const std = @import("std");
const lattice = @import("effects_lattice.zig");
const hash = @import("effects_hash.zig");
const registry_mod = @import("effects_registry.zig");
const engine_mod = @import("effects_engine.zig");
const EffectResource = lattice.EffectResource;
const HostBindingId = lattice.HostBindingId;
const Summary = lattice.Summary;
const canonicalize = lattice.canonicalize;
const join = lattice.join;
const top = lattice.top;
const ResourceRegistry = registry_mod.ResourceRegistry;
const Provider = engine_mod.Provider;
const default_provider_id = engine_mod.default_provider_id;
const default_provider_version = engine_mod.default_provider_version;
const hashProvider = engine_mod.hashProvider;
const hashU8 = hash.hashU8;
const hashU32 = hash.hashU32;
const hashU64 = hash.hashU64;
const hashResourceInto = hash.hashResourceInto;
const hashAccessSetInto = hash.hashAccessSetInto;
const hashSummaryInto = hash.hashSummaryInto;
const resourceLessThan = hash.resourceLessThan;
const resourcePairLessThan = hash.resourcePairLessThan;
const hashResourceList = hash.hashResourceList;
const hashResourcePairs = hash.hashResourcePairs;

/// Declared host-call semantics. A host binding with no entry is
/// `Top` (docs/effects.md §9.3, §13) — the compiler never assumes a
/// missing declaration is pure. The pass does not wire the embedding ABI;
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
pub fn callbacksEqual(a: ?[]const u32, b: ?[]const u32) bool {
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

/// One declaration's digest. Keyed on the full content, so editing a
/// summary, the attestation, or the callback contract all change it. The
/// declared summary is canonicalized first: two declarations that differ
/// only in row order describe the same environment and must agree.
pub fn declDigest(arena: std.mem.Allocator, d: HostDecl) std.mem.Allocator.Error!u64 {
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

pub fn hashResourceRegistry(h: *std.hash.Wyhash, arena: std.mem.Allocator, reg: ResourceRegistry) std.mem.Allocator.Error!void {
    try hashResourceList(h, arena, reg.stable);
    try hashResourcePairs(h, arena, reg.disjoint);
}
// ===========================================================================
// Tests — host metadata and the environment fingerprint (docs/effects.md §13)
// ===========================================================================

const testing = std.testing;

const AccessSet = lattice.AccessSet;
const EffectAccess = lattice.EffectAccess;
const HostDomainId = lattice.HostDomainId;
const modeBit = lattice.modeBit;
const pure = lattice.pure;
const may_trap = lattice.may_trap;
const host_top = lattice.host_top;
const example_hierarchy = engine_mod.example_hierarchy;
const hierarchy_modes = engine_mod.hierarchy_modes;
const mode_commute_update = engine_mod.mode_commute_update;

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
