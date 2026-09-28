//! Persistent function-summary cache for incremental re-solving
//! (docs/effects.md §8.3). A session (`frontend.compile`) owns one of
//! these and threads it through every `Analysis` it constructs, so a
//! stage / pass that rewrites one function body can re-solve only the
//! SCCs whose summaries actually moved instead of re-deriving the whole
//! program.
//!
//! The cache is deliberately *data only*: it never touches the HIR and
//! never runs the solver. `passes/hir_effects_summary.zig` seeds the
//! working arrays of an `Analysis` from it, solves incrementally, and
//! snapshots the result back. The default (`Config.cache == null`) path
//! allocates a private, never-armed cache, so every solve stays full and
//! the observable behavior is unchanged.
//!
//! Two invariants make the cached values reusable across solves:
//!
//! - **Stable node identity.** `drop_node_of` / `drop_key_of_node`
//!   assign a drop node its id on first sight and never move it; a new
//!   canonical `HIRTypeId` appends, so `summary` / `known` stay aligned
//!   with the unified node space of docs/effects.md §11.1.
//! - **Stable edges.** A drop node's outgoing edges (structural children
//!   plus its `drop` hook function) depend only on its type, so they are
//!   snapshotted in `drop_edges` rather than regenerated per solve;
//!   only function bodies contribute edges that can change.

const std = @import("std");
const hir = @import("stilla").hir;
const effects = @import("stilla").effects;

/// The per-node effect value carried by the cache (docs/effects.md
/// §5.4): re-exported so callers do not need the solver module.
pub const Summary = effects.Summary;

pub const Error = std.mem.Allocator.Error;

/// The session-level incremental summary state (docs/effects.md §8.3).
pub const SummaryCache = struct {
    /// Every allocation is owned by this arena, which outlives the
    /// short-lived `Analysis` instances that read and write the cache.
    arena: std.mem.Allocator,

    /// Stable unified-node identity: canonical type key → drop node id.
    /// Entries `0..F` of the inverse table below are the function /
    /// `Top`-sink placeholders and never appear here.
    drop_node_of: std.AutoHashMapUnmanaged(hir.HIRTypeId, u32) = .empty,
    /// Node id → canonical type key (only meaningful at `F+1..`).
    drop_key_of_node: std.ArrayList(hir.HIRTypeId) = .empty,
    /// Aligned with `drop_key_of_node`: a drop node's own outgoing edges
    /// (structural children plus its `drop` hook function id).
    drop_edges: std.ArrayList([]u32) = .empty,
    /// The reserved `Top`-summary sink node id (`= function count`).
    top_sink_node: u32 = 0,

    /// The last finalized per-node summaries, indexed by unified node.
    summary: []Summary = &.{},
    /// Whether `summary[node]` is a finalized value.
    known: []bool = &.{},

    /// The last SCC id per node, and the member table per SCC: used to
    /// widen the dirty set to the members an old recursive component
    /// shared a seed with.
    cached_comp_of: []u32 = &.{},
    cached_comps: [][]u32 = &.{},

    /// Functions whose body changed since the last solve.
    dirty: std.AutoHashMapUnmanaged(hir.FuncId, void) = .empty,

    /// Cumulative solver counters, read by the targeted tests.
    stats: Stats = .{},

    /// Set once a full solve has populated the identity / value tables.
    armed: bool = false,
    /// The lattice instance the cached values were interned under
    /// (docs/effects.md §5.7). A mismatch un-arms the cache.
    instance_digest: ?u64 = null,

    pub const Stats = struct {
        /// Completed full or incremental solves.
        solves: u64 = 0,
        /// SCCs actually re-solved.
        components_solved: u64 = 0,
        /// SCCs whose cached values were reused untouched.
        components_reused: u64 = 0,
        /// Unified-node transfer evaluations (members × rounds).
        node_transfers: u64 = 0,
        /// Kleene/Jacobi rounds across every solved SCC.
        fixpoint_rounds: u64 = 0,
        /// Function nodes in reused SCCs.
        functions_reused: u64 = 0,
    };

    pub fn init(arena: std.mem.Allocator) Error!*SummaryCache {
        const self = try arena.create(SummaryCache);
        self.* = .{ .arena = arena };
        return self;
    }

    /// Mark one function body stale (docs/effects.md §8.3). The next
    /// armed solve re-derives its SCC and every transitive caller whose
    /// summary moved.
    pub fn markFunctionDirty(self: *SummaryCache, fid: hir.FuncId) Error!void {
        try self.dirty.put(self.arena, fid, {});
    }

    pub fn isDirty(self: *const SummaryCache, fid: hir.FuncId) bool {
        return self.dirty.contains(fid);
    }

    pub fn dirtyCount(self: *const SummaryCache) usize {
        return self.dirty.count();
    }

    pub fn arm(self: *SummaryCache) void {
        self.armed = true;
    }

    /// Un-arm and drop the pending dirty set: the next solve is full.
    /// Called when the lattice instance changes or when any graph
    /// structure the cache does not model moved.
    pub fn reset(self: *SummaryCache) void {
        self.armed = false;
        self.instance_digest = null;
        self.dirty.clearRetainingCapacity();
    }

    /// Grow the persistent per-node value arrays to at least `n`,
    /// copying existing values and defaulting new entries to
    /// `pure` / `false` (a never-solved node is not a fact).
    pub fn resize(self: *SummaryCache, n: usize) Error!void {
        if (self.summary.len >= n) return;
        const old = self.summary.len;
        const summary = try self.arena.alloc(Summary, n);
        @memcpy(summary[0..old], self.summary[0..old]);
        @memset(summary[old..], effects.pure);
        self.summary = summary;
        const known = try self.arena.alloc(bool, n);
        @memcpy(known[0..old], self.known[0..old]);
        @memset(known[old..], false);
        self.known = known;
    }
};
