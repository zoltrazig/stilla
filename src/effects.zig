//! Effect-semantics model — docs/effects.md §5 (lattice) and §14
//! (minimal scope), the HIR-side summary in docs/hir.md §6.2. This is
//! the **M1b** effect infrastructure: an abstract semantic resource
//! model plus the fixed product lattice and its rules, independent of
//! any pass. The HIR integration (transfer, function summaries, derived
//! legality queries) lives in `passes/hir_effects.zig`.
//!
//! Model in one paragraph. An expression's interaction with state
//! *outside* itself is an `EffectSummary`: a resource-access row plus
//! three control bits (`may_trap` — includes panic —, `may_diverge`,
//! `nondeterministic`). Lexical reads/moves/borrows of locals are
//! ownership facts, not effects, and do not enter the summary
//! (docs/effects.md §2.1, §4). Resources are abstract semantic domains,
//! never addresses (§5.2).
//!
//! Lattice (§5.4). Per mode (`Read | Write | Allocate | Release`) the
//! component is `P(K) ∪ {All}`: ordinary resource sets ordered by
//! inclusion, with `All` strictly above every ordinary set (including
//! the full registered set) so it also covers resources registered
//! later. `join` is per-mode union, `meet` per-mode intersection, with
//! `All ∪ S = All` and `All ∩ S = S`. Booleans join with OR. The
//! canonical row is a per-mode `all` flag plus a sorted, deduplicated
//! concrete access list; a `.top` resource is canonicalized into the
//! mode's `all` flag, so `.top` never appears in stored accesses.
//!
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
const meta = @import("meta.zig");

/// Dense ids owned by the surrounding program; mirrored so this module
/// stays independent of the HIR (hir.md §3.5 category 3).
pub const ConstId = u32;
pub const HostBindingId = u32;
pub const HostDomainId = u32;
pub const RuntimeDomainId = u32;
pub const ProviderId = u32;
pub const ResourceId = u32;

// ---------------------------------------------------------------------------
// Modes, resources, accesses (docs/effects.md §5.1–§5.2)
// ---------------------------------------------------------------------------

pub const EffectMode = enum(u2) { read, write, allocate, release };
pub const mode_count = std.enums.values(EffectMode).len;

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
/// summary lattice). `all[m]` is mode `m`'s `All`: the wildcard above
/// every ordinary resource set, including resources registered later.
pub const AccessSet = struct {
    all: [mode_count]bool = .{ false, false, false, false },
    /// Canonical: sorted by (mode, resource), deduplicated, never
    /// carries `.top` (the wildcard is `all`), and never lists a mode
    /// whose `all` flag is set.
    accesses: []const EffectAccess = &.{},

    pub const empty: AccessSet = .{};
    pub const top: AccessSet = .{ .all = .{ true, true, true, true } };

    pub fn eql(a: AccessSet, b: AccessSet) bool {
        if (!std.mem.eql(bool, &a.all, &b.all)) return false;
        if (a.accesses.len != b.accesses.len) return false;
        for (a.accesses, b.accesses) |x, y| {
            if (x.mode != y.mode or !x.resource.eql(y.resource)) return false;
        }
        return true;
    }

    pub fn isEmpty(self: AccessSet) bool {
        if (self.accesses.len != 0) return false;
        for (self.all) |a| if (a) return false;
        return true;
    }

    /// `a ≤ b`: per mode, `a`'s component is contained in `b`'s. A
    /// concrete set is below `All`; `All` is above only `All`.
    pub fn le(a: AccessSet, b: AccessSet) bool {
        for (0..mode_count) |m| {
            if (a.all[m] and !b.all[m]) return false;
        }
        for (a.accesses) |x| {
            if (b.all[@intFromEnum(x.mode)]) continue;
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

/// Canonicalize a concrete access list: sort, dedupe, drop accesses of
/// wildcarded modes, and fold `.top` resources into the mode flags.
fn canonicalize(arena: std.mem.Allocator, raw: []const EffectAccess, all: [mode_count]bool) std.mem.Allocator.Error!AccessSet {
    var out = AccessSet{ .all = all };
    var buf = std.ArrayListUnmanaged(EffectAccess).empty;
    for (raw) |x| {
        if (x.resource == .top) {
            out.all[@intFromEnum(x.mode)] = true;
            continue;
        }
        try buf.append(arena, x);
    }
    std.mem.sort(EffectAccess, buf.items, {}, accessLessThan);
    var dedup = std.ArrayListUnmanaged(EffectAccess).empty;
    for (buf.items) |x| {
        if (out.all[@intFromEnum(x.mode)]) continue;
        if (dedup.items.len > 0) {
            const last = dedup.items[dedup.items.len - 1];
            if (last.mode == x.mode and last.resource.eql(x.resource)) continue;
        }
        try dedup.append(arena, x);
    }
    out.accesses = try arena.dupe(EffectAccess, dedup.items);
    return out;
}

fn copyAccessSet(arena: std.mem.Allocator, set: AccessSet) std.mem.Allocator.Error!AccessSet {
    var out = set;
    out.accesses = try arena.dupe(EffectAccess, set.accesses);
    return out;
}

/// Per-mode union; `All ∪ S = All` (docs/effects.md §5.4).
pub fn joinAccess(arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    var out = AccessSet{};
    for (0..mode_count) |m| out.all[m] = a.all[m] or b.all[m];
    var buf = std.ArrayListUnmanaged(EffectAccess).empty;
    for (a.accesses) |x| {
        if (!out.all[@intFromEnum(x.mode)]) try buf.append(arena, x);
    }
    for (b.accesses) |x| {
        if (!out.all[@intFromEnum(x.mode)]) try buf.append(arena, x);
    }
    return canonicalize(arena, buf.items, out.all);
}

/// Per-mode intersection; `All ∩ S = S` (docs/effects.md §5.4).
/// **Law-test only** — the optimizer API never exposes meet
/// (docs/effects.md §5.4: meet merges independent sound proofs, it is
/// not a control-flow join).
pub fn latticeMeetAccess(arena: std.mem.Allocator, a: AccessSet, b: AccessSet) std.mem.Allocator.Error!AccessSet {
    var out = AccessSet{};
    for (0..mode_count) |m| out.all[m] = a.all[m] and b.all[m];
    var buf = std.ArrayListUnmanaged(EffectAccess).empty;
    for (a.accesses) |x| {
        const mi = @intFromEnum(x.mode);
        if (out.all[mi]) continue;
        if (a.all[mi]) {
            // All_a ∩ B: B's accesses of this mode survive.
            if (contains(b.accesses, x)) try buf.append(arena, x);
            continue;
        }
        if (b.all[mi]) {
            try buf.append(arena, x);
            continue;
        }
        if (contains(b.accesses, x)) try buf.append(arena, x);
    }
    // The loop above only walks a's accesses; add b's accesses for
    // modes where a is wildcarded.
    for (b.accesses) |x| {
        const mi = @intFromEnum(x.mode);
        if (out.all[mi] or !a.all[mi]) continue;
        try buf.append(arena, x);
    }
    return canonicalize(arena, buf.items, out.all);
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
/// accesses (`Top`/wildcard resources are folded into the mode flags).
pub fn summaryOf(arena: std.mem.Allocator, raw: []const EffectAccess) std.mem.Allocator.Error!Summary {
    return .{
        .accesses = try canonicalize(arena, raw, .{ false, false, false, false }),
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
    return !s.may_trap and !s.may_diverge;
}

/// No `Write / Allocate / Release` access and no unknown resource
/// (`All_m` wildcard). Resource *reads* are not observable by default
/// (§10.1); `Q` is not considered here. A read wildcard is `Read(Top)` —
/// an unknown resource — and per §10.1/§5.4 it is *not* an ordinary
/// read, so it fails this predicate too.
pub fn isObservableEffectFree(s: Summary) bool {
    for (s.accesses.all) |wildcard| if (wildcard) return false;
    for (s.accesses.accesses) |x| {
        // `host_any` is an unknown host resource: it can hide any
        // observable interaction (docs/effects.md §13).
        if (x.resource == .host_any) return false;
        switch (x.mode) {
            .read => {},
            .write, .allocate, .release => return false,
        }
    }
    return true;
}

/// `discard_view` (§10.1, §11.2): drop reads (non-observable) and `Q`
/// (result instability does not make discarding observable); keep the
/// control bits and the observable accesses. `discardable` requires
/// `discardView(observed_effect) == pure`.
pub fn discardView(arena: std.mem.Allocator, s: Summary) std.mem.Allocator.Error!Summary {
    var buf = std.ArrayListUnmanaged(EffectAccess).empty;
    for (s.accesses.accesses) |x| {
        if (x.mode != .read) try buf.append(arena, x);
    }
    var out = AccessSet{};
    for (0..mode_count) |m| out.all[m] = s.accesses.all[m] and m != @intFromEnum(EffectMode.read);
    return .{
        .accesses = try canonicalize(arena, buf.items, out.all),
        .may_trap = s.may_trap,
        .may_diverge = s.may_diverge,
        .nondeterministic = false,
    };
}

pub fn isPure(s: Summary) bool {
    return s.accesses.isEmpty() and !s.may_trap and !s.may_diverge and !s.nondeterministic;
}

// ---------------------------------------------------------------------------
// Pending / Ready — outside the lattice (docs/effects.md §8.2, §10.5)
// ---------------------------------------------------------------------------

/// An expression's or function's analysis state. `Pending` is a
/// transient approximation, never a proof: a legality query that hits a
/// pending fact fails closed. `Bottom` and `Pure` share a lattice
/// value, so "not yet derived" and "proved pure" *must* be carried
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

pub const Interner = struct {
    arena: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(AccessSet) = .empty,
    row_map: std.HashMapUnmanaged(AccessSet, RowId, AccessSetCtx, std.hash_map.default_max_load_percentage) = .empty,
    summaries: std.ArrayListUnmanaged(SummaryKey) = .empty,
    summary_map: std.AutoHashMapUnmanaged(SummaryKey, SummaryId) = .empty,

    pub const SummaryKey = struct {
        row: RowId,
        may_trap: bool,
        may_diverge: bool,
        nondeterministic: bool,
    };

    /// Seed `∅`/`All` rows and `Pure`/`Top` summaries so `pure_id` and
    /// `top_id` are stable.
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
        var entries = std.ArrayListUnmanaged(Entry).empty;
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
    /// independently*: the entries survive only when every declaration
    /// for that binding agrees — an identical attestation and an
    /// identical callback contract — and the summaries are joined. A
    /// contradiction (e.g. `forbidden` vs `may_execute`, or two different
    /// callback contracts) therefore degrades to the full `top`, rather
    /// than depending on which declaration happened to come first.
    pub fn consolidate(arena: std.mem.Allocator, entries: []const Entry) std.mem.Allocator.Error!HostEffects {
        var out = std.ArrayListUnmanaged(Entry).empty;
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
    host_decls: []const HostDecl = &.{},
};

/// Canonical digest of an `Environment` (docs/effects.md §13). Two
/// environments with the same fingerprint must produce the same effect
/// conclusions for the same program — so a cache keyed on it may reuse
/// phase-2/3 results — and a different fingerprint must not reuse them.
/// The encoding is explicit and canonical: collections are sorted,
/// integers are little-endian fixed width (never native byte order),
/// symbols are length-delimited, and each summary row is canonicalized
/// before hashing. It never hashes raw struct bytes, arena pointers, or a
/// session-local interner id (`ResourceRegistry`'s domain ids are
/// embedding ABI values, not interned handles, so they are included).
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
    for (set.all) |b| hashU8(h, @intFromBool(b));
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

fn hashResourceRegistry(h: *std.hash.Wyhash, arena: std.mem.Allocator, reg: ResourceRegistry) std.mem.Allocator.Error!void {
    const stable = try arena.dupe(EffectResource, reg.stable);
    std.mem.sort(EffectResource, stable, {}, resourceLessThan);
    hashU64(h, stable.len);
    for (stable) |r| hashResourceInto(h, r);

    const pairs = try arena.alloc([2]EffectResource, reg.disjoint.len);
    for (reg.disjoint, 0..) |pr, i| {
        pairs[i] = if (pr.a.lessThan(pr.b)) .{ pr.a, pr.b } else .{ pr.b, pr.a };
    }
    std.mem.sort([2]EffectResource, pairs, {}, resourcePairLessThan);
    hashU64(h, pairs.len);
    for (pairs) |pr| for (pr) |r| hashResourceInto(h, r);
}

pub const Conflict = enum { commute, conflict };

/// The conflict rule of docs/effects.md §5.6, the input to
/// `canSwapOperands`. Undeclared resource pairs conflict (safe
/// default); `All`/unknown modes conflict.
pub fn conflictOf(a: EffectAccess, b: EffectAccess, reg: ResourceRegistry) Conflict {
    if (a.resource == .top or b.resource == .top) return .conflict;
    if (a.resource == .host_any or b.resource == .host_any) return .conflict;
    if (a.resource.eql(b.resource)) {
        return switch (a.mode) {
            .read => switch (b.mode) {
                .read => if (reg.isStable(a.resource)) .commute else .conflict,
                else => .conflict,
            },
            else => .conflict,
        };
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
    for (0..mode_count) |m| {
        if (a.accesses.all[m] or b.accesses.all[m]) {
            // Wildcarded accesses: no wildcard can establish a stable
            // domain or a disjoint pair.
            return false;
        }
    }
    for (a.accesses.accesses) |x| {
        for (b.accesses.accesses) |y| {
            if (conflictOf(x, y, reg) == .conflict) return false;
        }
    }
    return true;
}

/// The §5.5 `stable` carve-out: the sole pair for which a summary-level
/// `Q` does not veto a swap — both summaries' accesses are reads, and
/// every cross pair is the *same* read on a declared-stable domain.
fn stableReadPair(a: Summary, b: Summary, reg: ResourceRegistry) bool {
    for (0..mode_count) |m| {
        if (a.accesses.all[m] or b.accesses.all[m]) return false;
    }
    var any = false;
    for (a.accesses.accesses) |x| {
        if (x.mode != .read) return false;
        for (b.accesses.accesses) |y| {
            if (y.mode != .read) return false;
            if (!x.resource.eql(y.resource) or !reg.isStable(x.resource)) return false;
            any = true;
        }
    }
    return any;
}

// ---------------------------------------------------------------------------
// drop_effect (docs/effects.md §11.1)
// ---------------------------------------------------------------------------

/// `drop_effect(T)` in M1b is deliberately minimal: a Copy value's
/// destruction has no interaction (`{}`), and everything else is
/// unmodelled (`Top`). Precise structural/hook destructor summaries are
/// deferred (docs/effects.md §14 再后 1); the conservative Top is what
/// makes unknown cleanup block deletion/floating/duplication/SEG
/// admission. `capability` is `null` when the type could not be
/// classified — also Top.
pub fn dropEffect(capability: ?meta.Ownership) Summary {
    const cap = capability orelse return top;
    return switch (cap) {
        .copy => pure,
        .unique => top,
    };
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
    var buf = std.ArrayListUnmanaged(EffectAccess).empty;
    for (raw) |x| try buf.append(arena, x);
    return canonicalize(arena, buf.items, .{ false, false, false, false });
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
    try testing.expect(s.all[@intFromEnum(EffectMode.read)]);
    try testing.expectEqual(@as(usize, 0), s.accesses.len);
    try testing.expect(s.eql(.{ .all = .{ true, false, false, false } }));
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

    const all_read = AccessSet{ .all = .{ true, false, false, false } };
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
    const r = AccessSet{ .all = .{ false, true, false, false } };

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
    try testing.expect(read_top.accesses.all[@intFromEnum(EffectMode.read)]);
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

test "effects: drop_effect is Pure for Copy and Top otherwise" {
    try testing.expect(dropEffect(.copy).eql(pure));
    try testing.expect(dropEffect(.unique).eql(top));
    try testing.expect(dropEffect(null).eql(top));
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
        .resources = .{ .stable = &.{host(1)}, .disjoint = &.{.{ .a = host(1), .b = host(2) }} },
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
