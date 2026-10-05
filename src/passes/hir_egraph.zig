//! Pass: SEG — the *slotted e-graph* arena behind the rule subset
//! (docs/hir.md §8, §11; docs/effects.md §12.3). In: one HIR island root
//! whose whole subtree already passes the recursive admission predicate
//! (`OpDescriptor.seg` registered + `isSegSafe` + every operand / region
//! root admissible), a built program arena, and a *validated*
//! `hir_effects.Analysis`. Out: the same island rewritten in place to the
//! saturated normal form, plus the arena's `Stats`.
//!
//! The engine replaced the in-place tree rewriter for the union rules: the
//! rule set is expressed as e-graph rules — pattern match over
//! e-classes, union toward the improved e-node, congruence (`rebuild`)
//! to close the equality — and the result is extracted back into the HIR
//! tree. The boundary rewrites (β / η / the `let` folds) stay in
//! `hir_seg.zig`: their redexes are outside the encoding boundary (a
//! `fn_ref` has no `.seg`, and a source-level `let`'s initializer opens
//! its own full expression), so they are admitted by their
//! `rewrite_contract` instances rather than by island membership.
//!
//! The arena:
//!
//! - **e-classes** — `classes` with a union-find (`find` compresses; the
//!   root id is the canonical class id) and a `preferred` member: the
//!   e-node extraction follows. Encode seeds it with the original node
//!   (priority 0); a rule that fires *redirects* the class to its result
//!   and records priority 1, so the rewritten shape is what extraction
//!   emits. Competing rule proposals are resolved by the lowest e-node
//!   index, which keeps saturation order-independent and idempotent.
//! - **e-nodes** — hash-consed on `(op, canonical type id, payload,
//!   operand classes, region terms, access hops)`. The hash is the key;
//!   `nodeEql` is the structural comparison that turns a hash collision
//!   into a *merge*. `rebuild` re-canonicalizes every e-node and re-runs
//!   the lookup once per round, which is the congruence closure — and
//!   thereby the tree rewriter's CSE sharing: two α-equal pure subtrees
//!   land in one e-class without a dedicated rule.
//! - **SLOT numbering** — `BinderId → Slot`, one island-wide counter.
//!   `local` encodes as `var(slot)`, a region's params as its slot list,
//!   a pattern's binding leaves by the slot of the binder they bind. A
//!   binder outside the island (an enclosing function's parameter, say)
//!   still gets a slot, so two α-equal subtrees compare equal without
//!   ever confusing a free binder with a bound one. Slots are only the
//!   *key*: extraction restores the original `BinderId` for a free
//!   binder and allocates a fresh one for every region it rebuilds.
//! - **encode** — the recursive admission + term construction. The
//!   boundary is the registry's `.seg` facet, `isSegSafe`, and every
//!   operand / region root encoding in turn — **never a switch on the
//!   opcode**. A subtree that fails any of the three returns `null` and
//!   keeps its original shape (the caller never sees it).
//! - **saturate** — rounds of (rules → rebuild), stopping when a whole
//!   round changes nothing. This is a **stable-canonical-order contract,
//!   not a bounded-round one and not a global decreasing measure**: every
//!   admitted rule preserves semantics and rule-node synthesis is
//!   idempotent (a candidate is looked up before it is appended), so a
//!   quiet round is a true fixpoint. The arena's only unbounded-direction
//!   moves are canonical-term interning — at most once per distinct `Bag`
//!   multiset — and monotone, finite class merges; the AC search's
//!   near-linear per-round cost (`planAcWork` / `acChainCanonical` /
//!   `bagInto` / `bagOf` / `finalizeBag`) is a *cost* bound, not what makes
//!   the loop terminate. No numeric round cap is needed. `Stats.converged`
//!   is `true` at that exit.
//! - **select** — the cost model (item 22). After saturation, every
//!   e-class is given the member extraction must emit: the one with the
//!   least total cost under `CostModel`, computed bottom-up over the
//!   class DAG (a class is paid for once, so a shared class is worth
//!   materializing). Cost is an *optimizer* fact and never enters an op
//!   descriptor; a tie prefers the class's existing `preferred` member
//!   (the encode-time original, or a rule's proposal) and then the lower
//!   e-node index, so the choice is independent of union order.
//! - **extract** — writes the saturated class back into the HIR tree.
//!   The tree is recovered by recursion over classes, not by a hash
//!   table: a class no rule touched (`preferred_prio == 0`) whose site is
//!   one of its members keeps that site and recurses into the site's own
//!   operands / regions — exact identity, which is what makes a saturated
//!   island a fixpoint instead of fresh churn every round. A redirected
//!   class (or a site that is not a member) gets a *fresh* copy of the
//!   selected e-node, deep-copied with fresh binders per rebuilt region,
//!   so the result is always a tree (§3.7). A class referenced twice among
//!   one `strict_ltr`, region-free parent's operands materializes into a
//!   synthesized `let` (§8.3's CSE shape); every other repeated reference
//!   is copied, which is exactly the sharing v1's sibling-only `ruleCse`
//!   had.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const hir_effects = @import("hir_effects.zig");
const hir_egraph_rules = @import("hir_egraph_rules.zig");

pub const Error = hir.Program.InternTypeError;

/// A binder slot: the e-graph's canonical binder reference (see the file
/// header). Slots are dense, island-scoped, and assigned on first
/// encounter in encode order.
pub const Slot = u32;

/// An e-class id. Always resolved through `find` before use — the raw id
/// may be a non-root after a union.
const Ref = u32;
/// An e-node id (index into `Island.nodes`).
const NodeId = u32;

/// One entry of an AC `Bag`: a distinct leaf class and how many times it
/// occurs in the AC multiset. `Bag` is kept sorted ascending by the stable
/// key `acRep` (the class's lowest member `NodeId`), so it is a canonical,
/// union-order-independent representation of an AC chain.
const BagEntry = struct { cls: Ref, count: u64 };
const Bag = []BagEntry;

/// Memo key for `acExpand`: a class root plus the AC op / type being
/// expanded. A class can hold both `add` and `mul` e-nodes (an algebra fold
/// can merge its class with the kept operand's), whose expansions differ, so
/// the root alone is not enough. Auto-hashed as a struct — never packed into
/// an integer where two live keys could collide and return a wrong e-node.
const AcExpandKey = struct { root: Ref, op: hir.OpId, ty: hir.HIRTypeId };

/// What one island's saturation did — folded into `hir_seg.Stats`, the
/// per-rule counts split into the recognized-redex (matched) and the
/// applied halves.
pub const Stats = struct {
    /// Saturation rounds this island ran (a quiet round counts).
    rounds: u64 = 0,
    /// `true` when a round changed nothing (the rule set's fixpoint; there
    /// is no longer a bound-hit path).
    converged: bool = true,
    /// Live e-classes after saturation.
    eclasses: usize = 0,
    /// E-nodes created (encode + rule-synthesized).
    enodes: usize = 0,
    /// Class merges from congruence / encode-time hash-consing (CSE).
    merges: usize = 0,
    /// A union rule moved a class: either its e-classes merged or its
    /// preferred extraction changed (one per firing, so a rule that lands
    /// on a class another rule already improved still counts).
    unions: usize = 0,
    /// Times the constant-fold rule recognized a foldable redex — a
    /// rep-carrying op whose operand classes all held a constant — whether
    /// the fold was then refused (a would-be trap is the runtime's) or the
    /// union was a no-op (the class already preferred the folded shape).
    /// The applied half of the same redexes is `folds` below.
    folds_matched: usize = 0,
    /// Constant folds actually applied: the fold's class union landed
    /// (`redirect` reported a change). Strictly a subset of the redexes
    /// `folds_matched` recognized.
    folds: usize = 0,
    /// Times the integer-algebra rule recognized a redex — a binary
    /// integer-rep op on whose operands `integerAlgebra` returned an
    /// identity — whether or not the union then changed the arena.
    algebra_matched: usize = 0,
    /// Integer-algebra identities actually applied (`x + 0 → x`, …).
    algebra: usize = 0,
    /// Times the constant-condition rule recognized a redex — an `if` /
    /// `and` / `or` whose condition operand class held a `bool` constant
    /// (a non-bool constant never counts) — whether or not the union
    /// landed.
    conds_matched: usize = 0,
    /// Constant-condition selections actually applied.
    conds: usize = 0,
    /// Times the projection rule recognized a redex — a `field_get` whose
    /// base class held a constructor member and whose index was in range —
    /// whether or not the union landed.
    projects_matched: usize = 0,
    /// Aggregate projections actually applied (`field_get(C(…), i) → vi`).
    projects: usize = 0,
    /// In-place commutativity canonicalization swaps performed (the
    /// matched half; `merges` counts the applied half). After the AC
    /// search landed this covers only the commutative-but-not-associative
    /// ops (`eq` / `ne`); the associative ops flow through `assoc`.
    ac: usize = 0,
    /// AC regroup/canonicalization applications: a flattened operand
    /// multiset was rebuilt in canonical order and its chain root unioned
    /// into the node's class (`redirect` reported a change). Every AC node
    /// fires this, **including plain 2-operand commutes** (`b + a` → `a +
    /// b`), which the rule now canonicalizes through the same path; the
    /// associative half of the AC search (hir.md §8.2).
    assoc: usize = 0,
    /// `let` bindings synthesized for a shared operand class during extraction.
    materialized: usize = 0,
    /// Fresh subtrees written at a site (a redirected class or a non-member
    /// site). Identity extraction writes nothing.
    copied: usize = 0,
    /// Sites whose content was overwritten in place.
    written: usize = 0,
    /// Total cost of the form extraction selected for this island, in the
    /// cost model's units (item 22): the DAG cost of the island's root
    /// class, with every class paid for once.
    extract_cost: u64 = 0,
};

/// The extraction cost model (docs/hir.md §8.1; item 22).
///
/// Cost is an *optimizer* fact — it never enters an op descriptor — so
/// the ladder lives next to the extractor. The weights are a heuristic in
/// "roughly lowered instructions", not a measurement; what matters is
/// that they are deterministic, because extraction takes the least-cost
/// member of each e-class bottom-up over the class DAG.
pub const CostModel = struct {
    /// The fallback weight: an op the ladder does not name costs one node,
    /// so a new opcode is priced as node count until someone measures it.
    pub const default_weight: u32 = 1;

    /// One op's weight, keyed on the op's registry class with the two
    /// overrides a class alone cannot express.
    pub fn weight(op: hir.OpId) u32 {
        const d = hir.registry.get(op);
        // A projection shares the `.aggregate` class with a construction
        // but lowers to a single read (`field_get` → `read_field` /
        // `read_tuple` / `read_index`).
        if (std.mem.eql(u8, d.name, "field_get")) return 1;
        return switch (d.class) {
            // Literals, locals, fn_refs, arithmetic, casts, sequencing:
            // one node, one instruction.
            .atom, .binding, .seq, .numeric, .conversion => 1,
            // Construction and control: several instructions behind one
            // node.
            .aggregate, .control => 2,
            // A call is the expensive shape; preferring a non-call
            // candidate is exactly what a cost model is for.
            .function => 4,
            else => default_weight,
        };
    }
};

pub const Config = struct {
    pub const Rules = struct {
        /// Constant folding.
        fold: bool = true,
        /// Integer algebra identities.
        algebra: bool = true,
        /// Constant `if` / `and` / `or`.
        cond: bool = true,
        /// Aggregate projection (`field_get` over a constructor).
        project: bool = true,
        /// Materialize shared subtrees as synthesized `let`s (CSE sharing).
        cse: bool = true,
        /// Integer commutativity (AC-lite): canonicalization + congruence
        /// identities + `0 - x → neg x`.
        ac: bool = true,
    };

    /// Which union rules this island may apply.
    rules: Rules = .{},
};

pub const Result = struct {
    stats: Stats,
    /// Whether extraction changed the tree at all (`Stats.written != 0`).
    changed: bool,
    /// The sites extraction overwrote, in write order. The caller marks
    /// them dirty — a rule may not consult a pre-rewrite verdict about a
    /// node whose content this round already replaced. Valid only while
    /// the scratch arena that backs `optimizeIsland` lives.
    written: []const hir.ExprId,
};

// ---------------------------------------------------------------------------
// The e-graph
// ---------------------------------------------------------------------------

/// One encoded region: the params as slots, the body as a class, and the
/// original HIR region the term was built from (extraction reads its
/// binders, pattern and shape back).
const RegionTerm = struct {
    params: []const Slot,
    body: Ref,
    pattern: ?hir.PatternId,
    orig_region: hir.RegionId,
};

/// One e-node: an opcode applied to operand *classes*, plus everything
/// extraction needs to rebuild the HIR node. `origin` is the HIR node the
/// term was built from — `null` for a rule-synthesized node (a folded
/// constant). The payload is *normalized*: a `.binder` payload holds a
/// `Slot`, not a `BinderId`.
const ENode = struct {
    op: hir.OpId,
    /// The node's canonical HIR type id (hir.md §3.8). Equality / hashing
    /// are O(1) on the id; the arena's own `Program` is the interning
    /// authority, so equal structural types always share this id.
    ty: hir.HIRTypeId,
    payload: hir.Payload,
    /// Operand classes. Mutable: `rebuild` re-canonicalizes them in place
    /// after a union.
    operands: []Ref,
    regions: []RegionTerm,
    access_hops: []const hir.AccessHop,
    origin: ?hir.ExprId,
    full_expr: hir.FullExprId,
    hash: u64 = 0,
    cls: Ref = 0,
    /// True for the root e-node a `ruleAcRegroup` built as the canonical
    /// AC bracketing. `select`'s tie-break prefers it among equal-cost
    /// members so extraction emits the canonical form (hir.md §8.2). Not
    /// part of structural identity: `nodeEql` / `hashNode` ignore it.
    ac_root: bool = false,
};

/// One e-class: the union-find parent (its own id at the root), the
/// members that were merged into it, and the member extraction follows.
const EClass = struct {
    parent: Ref,
    rank: u32 = 0,
    preferred: NodeId,
    /// 0 = the encode-time original; 1 = a rule proposed a member. Two
    /// jobs: extraction keeps a site's own shape only while this is 0
    /// (nothing to rewrite), and the cost model's tie-break prefers this
    /// member over an equal-cost alternative.
    preferred_prio: u8 = 0,
    members: std.ArrayList(NodeId) = .empty,
};

/// One island's SEG arena. Everything it allocates comes from `arena`
/// (the caller passes a scratch arena it drops after extraction, so no
/// per-round garbage survives into the program arena).
pub const Island = struct {
    arena: std.mem.Allocator,
    pr: *hir.Program,
    analysis: *hir_effects.Analysis,
    rules: Config.Rules = .{},

    classes: std.ArrayList(EClass) = .empty,
    nodes: std.ArrayList(ENode) = .empty,
    /// Hash-cons index: structural hash → the e-nodes that hash to it.
    index: std.AutoHashMapUnmanaged(u64, std.ArrayList(NodeId)) = .empty,

    slot_binder: std.ArrayList(hir.BinderId) = .empty,
    binder_slot: std.AutoHashMapUnmanaged(hir.BinderId, Slot) = .empty,

    /// The full-expression id every node of this island belongs to
    /// (`ownershipGate` proves the island does not cross a boundary, so
    /// there is exactly one). Rule-synthesized nodes carry it.
    island_fe: hir.FullExprId = 0,

    /// The cost model's per-class choice (item 22), filled by `select`
    /// after saturation: the member extraction must emit, and that
    /// member's total cost. Empty until `select` runs.
    choice_node: []NodeId = &.{},
    choice_cost: []u64 = &.{},

    /// AC worklist for the current `saturate` round: the AC e-nodes
    /// `ruleAcRegroup` may visit at all. Rebuilt by `planAcWork` from the
    /// current class structure at the top of every round. An e-node
    /// created later in the same round is a canonical chain sub-term the
    /// rule itself synthesized, so it needs no regroup; leaving it out of
    /// the worklist is the saturation fixpoint, not a missed rule.
    ac_work: std.AutoHashMapUnmanaged(NodeId, void) = .empty,

    /// AC leaf-multiset memo shared across every `ruleAcRegroup` visit in a
    /// `saturate` round, keyed by `(class root, op, ty)` (a class can be an
    /// operand of two different AC ops). `planAcWork` empties it at the top
    /// of a round and `unionRoots` clears the whole map on every class merge
    /// (conservative and correct: a merge can change any cached bag's root),
    /// so a cached bag is only ever read while the class structure that
    /// produced it is unchanged.
    bag_memo: std.AutoHashMapUnmanaged(u128, Bag) = .empty,

    /// Memoized `constIn` answer per class root: the `const` member found by
    /// scanning, or `null` when the class holds none. The value is the
    /// e-node id, not the constant, so a hit returns the exact `ConstValue`
    /// the scan would have picked (the first `const` member in membership
    /// order). Cleared exactly when `bag_memo` is: on every `unionRoots`
    /// (the sole membership mutation), on the conservative
    /// `redirectToClass` reset, and at the top of each `planAcWork` round.
    /// Best-effort: a failed `put` is swallowed (`catch {}`) and merely
    /// costs a rescan, unlike `bag_memo`, whose value is required to build
    /// a canonical term.
    const_memo: std.AutoHashMapUnmanaged(Ref, ?NodeId) = .empty,

    /// Memoized `acExpand` answer per `(root, op, ty)`: the lowest-`NodeId`
    /// same-`(op, ty)` member, or `null` when the class is a leaf for that
    /// chain. Cleared exactly when `bag_memo` is and written best-effort
    /// like `const_memo`.
    ac_expand_memo: std.AutoHashMapUnmanaged(AcExpandKey, ?NodeId) = .empty,

    /// Memoized `acRep` answer per class root: its lowest-`NodeId` member.
    /// `acRep` runs inside `bagLess` / `finalizeBag` / `acSig` over member
    /// lists that can grow to O(N), so caching it keeps a bag's sort and
    /// coalesce from rescanning those lists on every comparison. Cleared
    /// exactly when `bag_memo` is and written best-effort like `const_memo`.
    ac_rep_memo: std.AutoHashMapUnmanaged(Ref, NodeId) = .empty,

    /// Class roots a round's flatten must treat as *shared*: referenced as
    /// an operand class by two or more AC e-nodes (a repeated operand of one
    /// e-node counts twice). A shared class's bag is materialized once and
    /// memoized; a single-use class is inlined straight into its parent's
    /// accumulator, which is what makes a wide distinct-leaf chain linear
    /// instead of copying a growing prefix at every level.
    ac_shared: std.AutoHashMapUnmanaged(Ref, void) = .empty,

    /// Test-only work meter (never a production cap or comparison): leaf /
    /// memoized-bag entries appended by `bagInto` over the island's
    /// lifetime. A wide distinct-leaf chain must append O(N) entries across
    /// all rounds, not O(N²); the regression test pins it.
    ac_flatten_appends: u64 = 0,

    stats: Stats = .{},
    written: std.ArrayList(hir.ExprId) = .empty,

    pub fn init(arena: std.mem.Allocator, pr: *hir.Program, analysis: *hir_effects.Analysis, config: Config) Island {
        return .{ .arena = arena, .pr = pr, .analysis = analysis, .rules = config.rules };
    }

    // -----------------------------------------------------------------
    // Union-find
    // -----------------------------------------------------------------

    pub fn find(self: *Island, c: Ref) Ref {
        var root = c;
        while (self.classes.items[root].parent != root) root = self.classes.items[root].parent;
        var x = c;
        while (self.classes.items[x].parent != x) {
            const next = self.classes.items[x].parent;
            self.classes.items[x].parent = root;
            x = next;
        }
        return root;
    }

    fn newClass(self: *Island, preferred: NodeId) Error!Ref {
        const cls: Ref = @intCast(self.classes.items.len);
        try self.classes.append(self.arena, .{ .parent = cls, .preferred = preferred });
        try self.classes.items[cls].members.append(self.arena, preferred);
        return cls;
    }

    /// Merge `a` and `b` (by rank, ties by lower id) and return the root.
    /// The surviving preferred member is the better of the two: a
    /// rule-chosen member (priority 1) beats an encode-time one, and two
    /// encode-time members resolve by e-node index so the result does not
    /// depend on union order.
    fn unionRoots(self: *Island, a: Ref, b: Ref) Error!Ref {
        var ra = self.find(a);
        var rb = self.find(b);
        if (ra == rb) return ra;
        if (self.classes.items[ra].rank < self.classes.items[rb].rank) {
            const t = ra;
            ra = rb;
            rb = t;
        }
        const pa = self.classes.items[ra];
        const pb = self.classes.items[rb];
        const keep_a = pa.preferred_prio >= pb.preferred_prio and
            (pa.preferred_prio > pb.preferred_prio or pa.preferred <= pb.preferred);
        self.classes.items[rb].parent = ra;
        if (pa.rank == pb.rank) self.classes.items[ra].rank += 1;
        try self.classes.items[ra].members.appendSlice(self.arena, self.classes.items[rb].members.items);
        self.classes.items[rb].members.clearRetainingCapacity();
        if (!keep_a) {
            self.classes.items[ra].preferred = pb.preferred;
            self.classes.items[ra].preferred_prio = pb.preferred_prio;
        }
        // The class structure changed: every memoized leaf multiset or
        // per-class scan may now reference a stale root, so drop them all.
        // This is a handle reset, not a per-entry walk.
        self.bag_memo.clearRetainingCapacity();
        self.const_memo.clearRetainingCapacity();
        self.ac_expand_memo.clearRetainingCapacity();
        self.ac_rep_memo.clearRetainingCapacity();
        return ra;
    }

    /// Make `node` the class's preferred member if it improves on the
    /// current choice. `true` when the preferred member changed, which is
    /// what the rule counters count (a rule re-proposing the same member
    /// in a later round is not a new rewrite).
    fn propose(self: *Island, cls: Ref, node: NodeId) bool {
        const root = self.find(cls);
        const c = &self.classes.items[root];
        if (c.preferred_prio == 1) {
            if (node >= c.preferred) return false;
            c.preferred = node;
            return true;
        }
        c.preferred = node;
        c.preferred_prio = 1;
        return true;
    }

    /// Union `from`'s class with `target`'s and make `node` the class's
    /// preferred extraction. Returns whether the arena changed *at all*: a
    /// merge that keeps the other side's already-better preferred node
    /// still counts (the extraction destination moved), while a repeated
    /// proposal against an unchanged class does not — that is the
    /// saturation fixpoint signal. A changing call bumps `stats.unions`,
    /// so every union rule is counted in exactly one place.
    fn redirect(self: *Island, from: Ref, target: Ref, node: NodeId) Error!bool {
        const merged = self.find(from) != self.find(target);
        const root = try self.unionRoots(from, target);
        const preferred = self.propose(root, node);
        if (!merged and !preferred) return false;
        self.stats.unions += 1;
        return true;
    }

    /// Union `cls` with `target`'s class and prefer that class's current
    /// preferred e-node — the shape every union rule's result takes.
    fn redirectToClass(self: *Island, cls: Ref, target: Ref) Error!bool {
        const root = self.find(target);
        // These rules (constant fold / algebra / condition / projection)
        // can union a class with a value it did not structurally contain, so
        // post-order no longer bounds the invalidation: drop every per-class
        // memo. `unionRoots` clears the same maps for every merge (including
        // the AC regroup's `redirect`), so this is a conservative whole-memo
        // reset, never a targeted key eviction.
        self.bag_memo.clearRetainingCapacity();
        self.const_memo.clearRetainingCapacity();
        self.ac_expand_memo.clearRetainingCapacity();
        self.ac_rep_memo.clearRetainingCapacity();
        return self.redirect(self.find(cls), root, self.classes.items[root].preferred);
    }

    // -----------------------------------------------------------------
    // e-nodes: construction, hashing, hash-consing
    // -----------------------------------------------------------------

    fn addNode(self: *Island, node: ENode) Error!NodeId {
        const nid: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena, node);
        const cls = try self.newClass(nid);
        self.nodes.items[nid].cls = cls;
        return nid;
    }

    /// The e-node a constant of `ty` / `value` encodes to; the caller
    /// interns it through `internCandidate`.
    fn constCandidate(self: *Island, ty: hir.HIRTypeId, value: meta.ConstValue) ENode {
        return .{
            .op = hir.opId("const").?,
            .ty = ty,
            .payload = .{ .const_value = value },
            .operands = &.{},
            .regions = &.{},
            .access_hops = &.{},
            .origin = null,
            .full_expr = self.island_fe,
        };
    }

    /// The idempotence primitive for rule synthesis: reuse an
    /// already-interned structurally equal e-node if there is one, else
    /// append it and hash-cons it. Returns the class the candidate lives
    /// in. A rule that matches a node already equivalent to an existing
    /// one therefore appends nothing and unions nothing, which is what
    /// lets a saturated island be a true fixpoint instead of churning a
    /// fresh copy of the same node every round.
    fn internCandidate(self: *Island, cand: ENode) Error!Ref {
        if (try self.lookupNode(cand)) |other| return self.find(self.nodes.items[other].cls);
        const nid = try self.addNode(cand);
        return try self.internNode(nid);
    }

    /// Hash-cons `nid`: return the class whose content it already equals,
    /// merging when a structurally equal e-node exists elsewhere
    /// (encode-time CSE).
    fn internNode(self: *Island, nid: NodeId) Error!Ref {
        const hash = self.hashNode(self.nodes.items[nid]);
        self.nodes.items[nid].hash = hash;
        const gop = try self.index.getOrPut(self.arena, hash);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |other| {
            if (other == nid) continue;
            if (!self.nodeEql(self.nodes.items[nid], self.nodes.items[other])) continue;
            const a = self.find(self.nodes.items[nid].cls);
            const b = self.find(self.nodes.items[other].cls);
            if (a != b) {
                self.stats.merges += 1;
                return self.unionRoots(a, b);
            }
            return a;
        }
        try gop.value_ptr.append(self.arena, nid);
        return self.find(self.nodes.items[nid].cls);
    }

    /// Find an already-interned e-node structurally equal to `n` without
    /// creating one, keyed on `n`'s raw structural hash. `ruleAcRegroup`
    /// uses this while rebuilding a canonical chain: the caller passes real
    /// operand roots (`find(acc)` / `find(leaf)`), so the key matches every
    /// node whose index entry the last `rebuild` re-rooted. (A node indexed
    /// before a later same-round union of one of its operand classes is not
    /// found until the next `rebuild` re-keys it — at most one transient
    /// equivalent node, never the per-round duplicate drift the deleted
    /// representative-keyed guard caused.) A no-op visit reuses the existing
    /// chain node instead of appending a duplicate; without that,
    /// saturation's growing node loop would never settle.
    fn lookupNode(self: *Island, n: ENode) Error!?NodeId {
        const hash = self.hashNode(n);
        const bucket = self.index.get(hash) orelse return null;
        for (bucket.items) |other| {
            if (self.nodeEql(n, self.nodes.items[other])) return other;
        }
        return null;
    }

    fn nodeEql(self: *Island, x: ENode, y: ENode) bool {
        if (x.op != y.op) return false;
        if (x.ty != y.ty) return false;
        if (!payloadEql(x.payload, y.payload)) return false;
        if (!hopsEql(x.access_hops, y.access_hops)) return false;
        if (x.operands.len != y.operands.len) return false;
        for (x.operands, y.operands) |p, q| {
            if (self.find(p) != self.find(q)) return false;
        }
        if (x.regions.len != y.regions.len) return false;
        for (x.regions, y.regions) |p, q| {
            if (p.params.len != q.params.len) return false;
            for (p.params, q.params) |s, t| {
                if (s != t) return false;
            }
            if (self.find(p.body) != self.find(q.body)) return false;
            if ((p.pattern == null) != (q.pattern == null)) return false;
            if (p.pattern) |pp| {
                if (!self.patternEql(pp, q.pattern.?)) return false;
            }
        }
        return true;
    }

    fn hashNode(self: *Island, n: ENode) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&n.op));
        // The canonical type id is the whole identity of the type slot:
        // equal ids ⇒ equal types (interning), matching `nodeEql`'s O(1)
        // id comparison without ever touching the structural type.
        h.update(std.mem.asBytes(&n.ty));
        hashPayload(&h, n.payload);
        hashHops(&h, n.access_hops);
        for (n.operands) |r| {
            const c = self.find(r);
            h.update(std.mem.asBytes(&c));
        }
        for (n.regions) |rt| {
            for (rt.params) |s| h.update(std.mem.asBytes(&s));
            const b = self.find(rt.body);
            h.update(std.mem.asBytes(&b));
            if (rt.pattern) |p| self.hashPattern(&h, p) else h.update(&[_]u8{0});
        }
        return h.final();
    }

    fn hashPattern(self: *Island, h: *std.hash.Wyhash, pid: hir.PatternId) void {
        const pat = self.pr.pattern(pid);
        switch (pat) {
            .wildcard => h.update(&[_]u8{1}),
            .literal => |c| {
                h.update(&[_]u8{2});
                hashConst(h, c);
            },
            .bind => |b| {
                h.update(&[_]u8{3});
                const s = self.binder_slot.get(b) orelse std.math.maxInt(Slot);
                h.update(std.mem.asBytes(&s));
            },
            .tuple => |elems| {
                h.update(&[_]u8{4});
                for (elems) |e| self.hashPattern(h, e);
            },
            .list => |lp| {
                h.update(&[_]u8{5});
                for (lp.elems) |e| self.hashPattern(h, e);
                if (lp.rest) |r| self.hashPattern(h, r);
            },
            .struct_ => |sp| {
                h.update(&[_]u8{6});
                for (sp.fields) |f| {
                    h.update(std.mem.asBytes(&f.field));
                    self.hashPattern(h, f.pat);
                }
            },
            .variant => |vp| {
                h.update(&[_]u8{7});
                h.update(std.mem.asBytes(&vp.tag));
                if (vp.payload) |p| self.hashPattern(h, p);
            },
            .type_test => |tt| {
                h.update(&[_]u8{8});
                h.update(std.mem.asBytes(&tt.ty));
                const s = self.binder_slot.get(tt.bind) orelse std.math.maxInt(Slot);
                h.update(std.mem.asBytes(&s));
            },
        }
    }

    fn patternEql(self: *Island, pa: hir.PatternId, pb: hir.PatternId) bool {
        const x = self.pr.pattern(pa);
        const y = self.pr.pattern(pb);
        switch (x) {
            .wildcard => return y == .wildcard,
            .literal => |ca| return switch (y) {
                .literal => |cb| constEql(ca, cb),
                else => false,
            },
            .bind => |ba| return switch (y) {
                .bind => |bb| self.slotOfBinder(ba) == self.slotOfBinder(bb),
                else => false,
            },
            .tuple => |ea| return switch (y) {
                .tuple => |eb| blk: {
                    if (ea.len != eb.len) break :blk false;
                    for (ea, eb) |c, d| {
                        if (!self.patternEql(c, d)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .list => |la| return switch (y) {
                .list => |lb| blk: {
                    if (la.elems.len != lb.elems.len) break :blk false;
                    for (la.elems, lb.elems) |c, d| {
                        if (!self.patternEql(c, d)) break :blk false;
                    }
                    if ((la.rest == null) != (lb.rest == null)) break :blk false;
                    if (la.rest) |r| {
                        if (!self.patternEql(r, lb.rest.?)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .struct_ => |sa| return switch (y) {
                .struct_ => |sb| blk: {
                    if (sa.fields.len != sb.fields.len) break :blk false;
                    for (sa.fields, sb.fields) |f, g| {
                        if (f.field != g.field) break :blk false;
                        if (!self.patternEql(f.pat, g.pat)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .variant => |va| return switch (y) {
                .variant => |vb| blk: {
                    if (va.tag != vb.tag) break :blk false;
                    if ((va.payload == null) != (vb.payload == null)) break :blk false;
                    if (va.payload) |p| {
                        if (!self.patternEql(p, vb.payload.?)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .type_test => |ta| return switch (y) {
                .type_test => |tb| ta.ty == tb.ty and
                    self.slotOfBinder(ta.bind) == self.slotOfBinder(tb.bind),
                else => false,
            },
        }
    }

    pub fn slotOfBinder(self: *Island, b: hir.BinderId) Slot {
        return self.binder_slot.get(b) orelse std.math.maxInt(Slot);
    }

    // -----------------------------------------------------------------
    // encode
    // -----------------------------------------------------------------

    fn slotOf(self: *Island, b: hir.BinderId) Error!Slot {
        if (self.binder_slot.get(b)) |s| return s;
        const s: Slot = @intCast(self.slot_binder.items.len);
        try self.slot_binder.append(self.arena, b);
        try self.binder_slot.put(self.arena, b, s);
        return s;
    }

    /// Recursive island admission + term construction (hir.md §8.1–§8.2).
    /// `null` = the boundary: the op has no SEG encoding, the node is not
    /// semantically seg-safe, or a subtree failed to encode. No switch on
    /// the opcode: the registry's `.seg` facet and the derived
    /// `isSegSafe` query are the whole predicate.
    pub fn encode(self: *Island, e: hir.ExprId) Error!?Ref {
        const n = self.pr.node(e);
        if (hir.registry.get(n.op).seg == null) return null;
        if (!try self.analysis.isSegSafe(e)) return null;

        const src_ops = self.pr.operands(e);
        const ops = try self.arena.alloc(Ref, src_ops.len);
        for (src_ops, 0..) |op, i| ops[i] = try self.encode(op) orelse return null;

        const src_regs = self.pr.regionsOf(e);
        const regs = try self.arena.alloc(RegionTerm, src_regs.len);
        for (src_regs, 0..) |rid, j| {
            const params = self.pr.params(rid);
            const slots = try self.arena.alloc(Slot, params.len);
            // Slots for the params first: the body's `local` references
            // and the pattern's binding leaves must resolve to them.
            for (params, 0..) |b, k| slots[k] = try self.slotOf(b);
            const body = try self.encode(self.pr.region(rid).root) orelse return null;
            regs[j] = .{
                .params = slots,
                .body = body,
                .pattern = self.pr.region(rid).pattern,
                .orig_region = rid,
            };
        }

        const payload: hir.Payload = switch (n.payload) {
            .binder => |b| .{ .binder = try self.slotOf(b) },
            else => n.payload,
        };
        const nid = try self.addNode(.{
            .op = n.op,
            .ty = n.ty,
            .payload = payload,
            .operands = ops,
            .regions = regs,
            .access_hops = n.access_hops,
            .origin = e,
            .full_expr = n.full_expr,
        });
        return try self.internNode(nid);
    }

    // -----------------------------------------------------------------
    // saturation
    // -----------------------------------------------------------------

    /// Saturation (hir.md §8.2): rules → congruence close, repeated until a
    /// round changes nothing — a true fixpoint, not a bounded prefix and not
    /// a global decreasing measure. Rule synthesis is idempotent (a
    /// candidate is looked up before it is appended) and the only
    /// unbounded-direction moves are canonical-term interning (once per
    /// distinct `Bag`) and monotone, finite class merges, so a quiet round
    /// is reached without any numeric round cap.
    pub fn saturate(self: *Island) Error!void {
        while (true) {
            self.stats.rounds += 1;
            // Select the AC e-nodes this round may regroup before mutating
            // the class structure (`planAcWork` reads `find` / `acExpand`).
            if (self.rules.ac) try self.planAcWork();
            var changed = false;
            var i: usize = 0;
            while (i < self.nodes.items.len) : (i += 1) {
                if (try self.applyRules(@intCast(i))) changed = true;
            }
            if (try self.rebuild()) changed = true;
            if (!changed) break;
        }
        self.stats.converged = true;
        // The class set is final here, so the cost model runs once at the
        // end of saturation rather than per round.
        try self.select();
    }

    /// Congruence closure: re-canonicalize every e-node's class references
    /// and re-run the hash-cons lookup, so two parents that became equal
    /// because their operands merged also merge. This is where α-equality
    /// (v1's CSE) comes from — there is no dedicated sharing rule.
    fn rebuild(self: *Island) Error!bool {
        var it = self.index.valueIterator();
        while (it.next()) |bucket| bucket.clearRetainingCapacity();
        var changed = false;
        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            const nid: NodeId = @intCast(i);
            const n = &self.nodes.items[nid];
            for (n.operands) |*r| r.* = self.find(r.*);
            for (n.regions) |*rt| rt.body = self.find(rt.body);
            const cls = self.find(n.cls);
            const hash = self.hashNode(n.*);
            self.nodes.items[nid].hash = hash;
            const gop = try self.index.getOrPut(self.arena, hash);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            var merged = false;
            // `found` is true when *any* structurally equal node is already
            // in the bucket, including a same-class one. The node is then
            // already represented, so it must not be appended again
            // (mirroring `internNode`). Only `merged` feeds `changed`,
            // though: a same-class duplicate is not a new equality, so it
            // must not keep the saturation loop from reaching a quiet round.
            var found = false;
            for (gop.value_ptr.items) |other| {
                if (other == nid) continue;
                if (!self.nodeEql(n.*, self.nodes.items[other])) continue;
                found = true;
                const ocls = self.find(self.nodes.items[other].cls);
                if (ocls == cls) continue;
                _ = try self.unionRoots(ocls, cls);
                self.stats.merges += 1;
                merged = true;
                break;
            }
            if (!found) try gop.value_ptr.append(self.arena, nid);
            changed = changed or merged;
        }
        return changed;
    }

    /// One rule visit at one e-node (v1's one-rule-per-node discipline: a
    /// visit that fires returns, and the next round sees the merged
    /// class). Returns whether anything changed.
    fn applyRules(self: *Island, nid: NodeId) Error!bool {
        const n = self.nodes.items[nid];
        const d = hir.registry.get(n.op);
        if (d.typed and (self.rules.fold or self.rules.algebra or self.rules.ac)) {
            if (try self.ruleNumeric(nid)) return true;
            // No fold / algebra / `eq`-`ne` swap landed; the AC regroup
            // (`add` / `mul` / …) is the last rule tried. The one-rule-per-
            // node discipline holds: `ruleNumeric` returning true returns
            // here, and the next round sees the merged class. `ac_work`
            // restricts the regroup to the maximal / fingerprint-shared
            // nodes `planAcWork` selected for this round (a sound pruning,
            // see there).
            if (self.rules.ac and self.ac_work.contains(nid)) return self.ruleAcRegroup(nid);
            return false;
        }
        const base = baseName(d.name);
        if (self.rules.cond and (std.mem.eql(u8, base, "if") or std.mem.eql(u8, base, "and") or std.mem.eql(u8, base, "or"))) {
            return self.ruleConstCond(nid);
        }
        if (self.rules.project and std.mem.eql(u8, base, "field_get")) return self.ruleProject(nid);
        return false;
    }

    /// Constant folding + integer algebra over the typed reps (v1's
    /// `ruleNumeric`, expressed as a union). A fold that could trap is
    /// refused: the runtime owns the trap.
    fn ruleNumeric(self: *Island, nid: NodeId) Error!bool {
        const n = self.nodes.items[nid];
        const d = hir.registry.get(n.op);
        const rep = d.rep orelse return false;
        const base = baseName(d.name);
        const cls = self.find(n.cls);

        if (self.rules.fold and n.operands.len >= 1 and n.operands.len <= 2) {
            var values: [2]meta.ConstValue = undefined;
            var all_const = true;
            for (n.operands, 0..) |op, k| {
                values[k] = self.constIn(op) orelse {
                    all_const = false;
                    break;
                };
            }
            if (all_const) {
                const folded = if (n.operands.len == 1)
                    foldUnary(base, rep, values[0])
                else
                    foldBinary(base, rep, values[0], values[1]);
                if (folded) |value| {
                    // The fold redex was recognized (all-const operands, a
                    // value computed); whether the union below lands is the
                    // applied half (`folds`).
                    self.stats.folds_matched += 1;
                    const cc = try self.internCandidate(self.constCandidate(n.ty, value));
                    if (try self.redirectToClass(cls, cc)) {
                        self.stats.folds += 1;
                        return true;
                    }
                    return false;
                }
            }
        }

        // Integer commutativity (`rules.ac`): canonicalize the operand
        // order in place so the round's `rebuild` hash-conses `a ⊕ b` with
        // `b ⊕ a` into one class. Only the commutative-but-not-associative
        // ops (`eq` / `ne`) use this path now: the associative ops
        // (`add` / `mul` / …) are owned by `ruleAcRegroup`, which orders and
        // regroups them; keeping a second, differently-keyed in-place order
        // for them made the two rules fight and never converge. No mirrored
        // e-node (a mirror is itself commutative, so `saturate`'s node loop
        // would never terminate) and no `propose` (it would raise
        // `preferred_prio` and perturb identity extraction) — a lone
        // `b ⊕ a` extracts unchanged; AC only surfaces through genuine
        // sharing. The swap mutates the node's arena slice in place (the
        // `rebuild` precedent); the stale index bucket is harmless because
        // `rebuild` clears and rebuilds every bucket. Sound because island
        // admission already proved every operand `isSegSafe` (total,
        // observable-effect-free, deterministic, `Copy`, cleanup-free) —
        // integer LTR evaluation order is unobservable inside an island, so
        // no path-sensitive `reorderable(a, b)` query is consulted
        // (docs/effects.md §12.3).
        if (self.rules.ac and n.operands.len == 2 and isIntegerRep(rep) and
            isCommutativeInt(base) and !isAssociativeInt(base))
        {
            // Sort by the stable `acRep` key (the class's lowest member
            // `NodeId`), not the union-find root id: `unionRoots` renames
            // root ids as classes merge, so an order keyed on them can flip
            // back and forth, while `acRep` only decreases across unions and
            // makes the swap monotone.
            if (self.acRep(n.operands[0]) > self.acRep(n.operands[1])) {
                const tmp = n.operands[0];
                n.operands[0] = n.operands[1];
                n.operands[1] = tmp;
                self.stats.ac += 1;
                return true;
            }
        }

        if (self.rules.algebra and n.operands.len == 2 and isIntegerRep(rep)) {
            // Class-equality congruence identities (`rules.ac`): checked
            // BEFORE `integerAlgebra`, which early-returns `null` for
            // non-constant operands and would make these dead code. Pure
            // class checks, zero node creation (except the zero const).
            if (self.rules.ac and self.find(n.operands[0]) == self.find(n.operands[1])) {
                const sub_or_bxor = std.mem.eql(u8, base, "sub") or std.mem.eql(u8, base, "bxor");
                const is_band = std.mem.eql(u8, base, "band");
                const is_bor = std.mem.eql(u8, base, "bor");
                if (sub_or_bxor or is_band or is_bor) {
                    self.stats.algebra_matched += 1;
                    const target: Ref = if (sub_or_bxor) blk: {
                        const zero: meta.ConstValue = switch (rep) {
                            .i32 => intCV(i32, 0),
                            .i64 => intCV(i64, 0),
                            .u32 => intCV(u32, 0),
                            .u64 => intCV(u64, 0),
                            else => unreachable, // isIntegerRep gates above
                        };
                        break :blk try self.internCandidate(self.constCandidate(n.ty, zero));
                    } else if (is_band) n.operands[0] else n.operands[1];
                    if (try self.redirectToClass(cls, target)) {
                        self.stats.algebra += 1;
                        return true;
                    }
                    return false;
                }
            }
            const lc = self.constIn(n.operands[0]);
            const rc = self.constIn(n.operands[1]);
            const result = integerAlgebra(base, rep, lc, rc) orelse return false;
            // The identity redex was recognized; whether the redirect lands
            // is the applied half (`algebra`).
            self.stats.algebra_matched += 1;
            switch (result) {
                .keep => |idx| {
                    if (try self.redirectToClass(cls, n.operands[idx])) {
                        self.stats.algebra += 1;
                        return true;
                    }
                },
                .value => |value| {
                    const cc = try self.internCandidate(self.constCandidate(n.ty, value));
                    if (try self.redirectToClass(cls, cc)) {
                        self.stats.algebra += 1;
                        return true;
                    }
                },
                .negate => |idx| {
                    // `0 - x → neg x` belongs to the AC bundle (`rules.ac`):
                    // with AC disabled the identity stays a `sub`.
                    if (!self.rules.ac) return false;
                    // The unary `neg` candidate is interned through the same
                    // lookup-first path, so a later visit reuses it instead
                    // of appending a fresh copy.
                    const neg_op = negOpId(rep) orelse return false;
                    const ops = try self.arena.alloc(Ref, 1);
                    ops[0] = n.operands[idx];
                    const cc = try self.internCandidate(.{
                        .op = neg_op,
                        .ty = n.ty,
                        .payload = .none,
                        .operands = ops,
                        .regions = &.{},
                        .access_hops = &.{},
                        .origin = null,
                        .full_expr = self.island_fe,
                    });
                    if (try self.redirectToClass(cls, cc)) {
                        self.stats.algebra += 1;
                        return true;
                    }
                },
            }
        }
        return false;
    }

    // -----------------------------------------------------------------
    // AC regroup (associativity + commutativity)
    // -----------------------------------------------------------------

    /// The lowest-`NodeId` member of `root` that is the same AC op and
    /// type, or null when the class is a leaf for this chain. Memoized by
    /// `(root, op, ty)`; the `null` result is cached too, so a leaf class is
    /// scanned once per union-free span instead of once per query. `root`
    /// must already be canonical (every caller resolves through `find`), and
    /// membership only changes on union, which clears the memo.
    fn acExpand(self: *Island, root: Ref, op: hir.OpId, ty: hir.HIRTypeId) ?NodeId {
        const key: AcExpandKey = .{ .root = root, .op = op, .ty = ty };
        if (self.ac_expand_memo.get(key)) |cached| return cached;
        var best: ?NodeId = null;
        for (self.classes.items[root].members.items) |m| {
            const nd = self.nodes.items[m];
            if (nd.op != op or nd.ty != ty) continue;
            if (best == null or m < best.?) best = m;
        }
        self.ac_expand_memo.put(self.arena, key, best) catch {};
        return best;
    }

    /// The canonical-order key of a leaf class: its lowest-`NodeId`
    /// member. Nodes are never removed, so this pick is monotone
    /// (non-increasing) across unions and stable when `unionRoots` renames
    /// a class (unlike the raw class id). Extraction writes operands in
    /// this order and `encode` assigns `NodeId`s depth-first left-to-right,
    /// so a re-encoded canonical chain reproduces the order — a fixpoint,
    /// not an oscillation.
    fn acRep(self: *Island, cls: Ref) NodeId {
        const root = self.find(cls);
        if (self.ac_rep_memo.get(root)) |m| return m;
        var best: NodeId = std.math.maxInt(NodeId);
        for (self.classes.items[root].members.items) |m| {
            if (m < best) best = m;
        }
        self.ac_rep_memo.put(self.arena, root, best) catch {};
        return best;
    }

    fn acLeafLess(self: *Island, a: Ref, b: Ref) bool {
        return self.acRep(a) < self.acRep(b);
    }

    /// Whether `n` is an integer binary associative-commutative node — the
    /// exact `ruleAcRegroup` admission predicate, hoisted so `planAcWork`
    /// classifies the same nodes the rule would.
    fn isAcNode(n: ENode) bool {
        const d = hir.registry.get(n.op);
        const rep = d.rep orelse return false;
        if (n.operands.len != 2 or !isIntegerRep(rep)) return false;
        return isAcInt(baseName(d.name));
    }

    /// One AC e-node's multiset fingerprint: a commutative leaf-class hash
    /// plus the total leaf count, both combined under addition so operand
    /// order and bracketing vanish. This is only a *scheduler* for
    /// `planAcWork`; a false match costs a `bagOf` visit and never
    /// correctness, because a scheduled node is still canonicalized by the
    /// exact bag path (and two classes with different bags build two
    /// different canonical roots). A cycle yields `null` (undefined
    /// multiset) and never schedules.
    fn acSig(
        self: *Island,
        nid: NodeId,
        memo: *std.AutoHashMapUnmanaged(u128, ?u128),
        on_path: *std.AutoHashMapUnmanaged(Ref, void),
    ) Error!?u128 {
        const n = self.nodes.items[nid];
        const cls = self.find(n.cls);
        // Key by `(class root, op, ty)`, not the root alone: a class can hold
        // both `add` and `mul` e-nodes (an `integerAlgebra` fold such as
        // `mul(add(a,b), 1)` merges its class with the kept operand's), and
        // the signature below expands with `acExpand(oroot, n.op, n.ty)`.
        // Keying on the root alone let whichever op was visited first serve
        // the other the wrong fingerprint. `bagOf` / `bagKey` key the same
        // way. Scheduling-only either way, but consistent.
        const key = bagKey(cls, n.op, n.ty);
        if (memo.get(key)) |v| return v;
        if (on_path.contains(cls)) return null;
        try on_path.put(self.arena, cls, {});
        var acc: u64 = 0;
        var size: u64 = 0;
        var ok = true;
        for (n.operands) |o| {
            const oroot = self.find(o);
            if (self.acExpand(oroot, n.op, n.ty)) |m| {
                const child = try self.acSig(m, memo, on_path);
                if (child) |cs| {
                    // Raw addition, compressed nowhere along the way: the
                    // fingerprint must be a pure function of the leaf
                    // multiset, independent of the tree's bracketing.
                    acc = acc +% @as(u64, @truncate(cs));
                    size +|= @as(u64, @truncate(cs >> 64));
                } else {
                    ok = false;
                    break;
                }
            } else {
                const lk = self.acRep(oroot);
                acc = acc +% std.hash.Wyhash.hash(0, std.mem.asBytes(&lk));
                size +|= 1;
            }
        }
        _ = on_path.remove(cls);
        const val: ?u128 = if (ok) (@as(u128, size) << 64) | acc else null;
        try memo.put(self.arena, key, val);
        return val;
    }

    /// A sound *sufficient* test that node `nid` already is its class's
    /// canonical left-deep chain: a left spine whose right operands are
    /// distinct leaves in strictly descending `acRep` order, bottoming out
    /// in an ascending leaf pair. That is exactly the tree
    /// `buildCanonical` folds for a bag of distinct count-1 leaves, so a
    /// `true` answer means no redirect. A `false` answer only sends the
    /// node to the exact `bagOf` path; it never claims a non-canonical node
    /// is canonical.
    fn acChainCanonical(self: *Island, nid: NodeId, op: hir.OpId, ty: hir.HIRTypeId) bool {
        var cur = self.nodes.items[nid];
        var last: ?NodeId = null;
        // Termination (no explicit visited set needed): each step descends
        // the left spine and records the right operand key in `last`, and
        // the `rkey >= lk` guard forces those right keys to strictly
        // descend. There are finitely many distinct `acRep` keys, so the
        // loop runs finitely many steps; a left-spine cycle must eventually
        // present a right key it already saw and exit through that guard.
        while (true) {
            if (cur.op != op or cur.ty != ty or cur.operands.len != 2) return false;
            const rc = self.find(cur.operands[1]);
            if (self.acExpand(rc, op, ty) != null) return false;
            const rkey = self.acRep(rc);
            if (last) |lk| {
                if (rkey >= lk) return false;
            }
            last = rkey;
            const lc = self.find(cur.operands[0]);
            if (self.acExpand(lc, op, ty)) |m| {
                cur = self.nodes.items[m];
                continue;
            }
            return self.acRep(lc) < rkey;
        }
    }

    /// Rebuild `ac_work` for one `saturate` round. Scheduled are every
    /// *maximal* AC e-node — one not the representative operand of another
    /// same-(op,ty) AC e-node — plus every AC e-node that shares its
    /// multiset fingerprint with a different e-node.
    ///
    /// An interior e-node with a unique fingerprint is deliberately left
    /// out. The load-bearing fact is the HIR tree invariant (§3.7: no DAG):
    /// a class with two or more parents necessarily holds two or more
    /// same-`(op, ty)` e-nodes (each parent occupies one tree position), so
    /// the fingerprint sees it through `counts` and schedules it. A
    /// single-e-node interior class is instead covered by the enclosing
    /// maximal node's `acChainCanonical` spine check, whose canonical build
    /// reaches through the interior. Skipping is therefore a sound missed
    /// optimization, and it makes a left-associated chain of N distinct
    /// leaves cost O(N) instead of the Σ depth = O(N²) of visiting every
    /// interior chain node. A shared fingerprint keeps an interior node
    /// scheduled exactly when it has an AC-equal sibling elsewhere: both
    /// then run the exact bag path and land in one e-class (the
    /// `(a+b)+c` / `a+(b+c)` case). The fingerprint only *schedules*; it
    /// never merges, so a collision is extra work, never a wrong union.
    fn planAcWork(self: *Island) Error!void {
        self.ac_work.clearRetainingCapacity();
        self.bag_memo.clearRetainingCapacity();
        self.const_memo.clearRetainingCapacity();
        self.ac_expand_memo.clearRetainingCapacity();
        self.ac_rep_memo.clearRetainingCapacity();
        var memo = std.AutoHashMapUnmanaged(u128, ?u128).empty;
        var on_path = std.AutoHashMapUnmanaged(Ref, void).empty;
        var counts = std.AutoHashMapUnmanaged(u128, u32).empty;
        for (self.nodes.items, 0..) |n, i| {
            if (!isAcNode(n)) continue;
            const sig = try self.acSig(@intCast(i), &memo, &on_path);
            if (sig) |s| {
                const gop = try counts.getOrPut(self.arena, s);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
        var interior = std.AutoHashMapUnmanaged(NodeId, void).empty;
        for (self.nodes.items) |n| {
            if (!isAcNode(n)) continue;
            for (n.operands) |o| {
                if (self.acExpand(self.find(o), n.op, n.ty)) |rep| {
                    try interior.put(self.arena, rep, {});
                }
            }
        }
        for (self.nodes.items, 0..) |n, i| {
            if (!isAcNode(n)) continue;
            const nid: NodeId = @intCast(i);
            var schedule = !interior.contains(nid);
            if (!schedule) {
                if (try self.acSig(nid, &memo, &on_path)) |s| {
                    if ((counts.get(s) orelse 0) >= 2) schedule = true;
                }
            }
            if (schedule) try self.ac_work.put(self.arena, nid, {});
        }
        // Operand fan-out: a class expanded by two or more AC e-nodes (or
        // twice by one) needs its bag materialized once and shared; a
        // single-use class is inlined straight into its parent's flatten.
        self.ac_shared.clearRetainingCapacity();
        var fanout = std.AutoHashMapUnmanaged(Ref, u32).empty;
        for (self.nodes.items) |n| {
            if (!isAcNode(n)) continue;
            for (n.operands) |o| {
                if (self.acExpand(self.find(o), n.op, n.ty) == null) continue;
                const gop = try fanout.getOrPut(self.arena, self.find(o));
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
        var it = fanout.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* >= 2) try self.ac_shared.put(self.arena, e.key_ptr.*, {});
        }
    }

    /// Order two `Bag` entries by the stable `acRep` key; classes are
    /// distinct within a bag, so the key alone is a strict order.
    fn bagLess(self: *Island, a: BagEntry, b: BagEntry) bool {
        return self.acLeafLess(a.cls, b.cls);
    }

    /// A one-member bag for a leaf class.
    fn singleBag(self: *Island, cls: Ref) Error!Bag {
        const out = try self.arena.alloc(BagEntry, 1);
        out[0] = .{ .cls = cls, .count = 1 };
        return out;
    }

    /// The memo key of a class's bag under one `(op, ty)`: a class can be
    /// an operand of two different AC ops, whose expansions differ, so the
    /// root alone is not enough.
    fn bagKey(root: Ref, op: hir.OpId, ty: hir.HIRTypeId) u128 {
        return (@as(u128, root) << 64) | (@as(u128, op) << 32) | @as(u128, ty);
    }

    /// Sort a raw `(class, count)` accumulator ascending by `acRep` and
    /// coalesce equal classes, summing counts (an overflowing sum sets
    /// `overflow`, and the caller refuses the rewrite). The flatten appends
    /// raw leaf / memoized entries without maintaining sortedness, so this
    /// one sort per materialized bag replaces the per-merge copy of a sorted
    /// left fold.
    fn finalizeBag(self: *Island, entries: *std.ArrayList(BagEntry), overflow: *bool) Error!Bag {
        if (entries.items.len == 0) return &.{};
        std.mem.sort(BagEntry, entries.items, self, bagLess);
        var n: usize = 0;
        var i: usize = 0;
        while (i < entries.items.len) {
            const cls = entries.items[i].cls;
            const key = self.acRep(cls);
            var j = i + 1;
            while (j < entries.items.len and self.acRep(entries.items[j].cls) == key) : (j += 1) {
                const sum = @addWithOverflow(entries.items[i].count, entries.items[j].count);
                if (sum[1] != 0) overflow.* = true;
                entries.items[i].count = sum[0];
            }
            entries.items[n] = entries.items[i];
            n += 1;
            i = j;
        }
        const out = try self.arena.alloc(BagEntry, n);
        @memcpy(out, entries.items[0..n]);
        return out;
    }

    /// Append `c`'s leaf multiset (under `op`/`ty`) to `list`. A class the
    /// round marked *shared* (`ac_shared`) is materialized once and spliced
    /// in from the memo; every other AC class is expanded in place, so a
    /// single-use chain contributes its leaves without re-copying a growing
    /// prefix. A cycle sets `cut`, exactly as before.
    fn bagInto(
        self: *Island,
        op: hir.OpId,
        ty: hir.HIRTypeId,
        c: Ref,
        list: *std.ArrayList(BagEntry),
        on_path: *std.AutoHashMapUnmanaged(Ref, void),
        cut: *bool,
        overflow: *bool,
    ) Error!void {
        const root = self.find(c);
        if (cut.*) {
            self.ac_flatten_appends += 1;
            try list.append(self.arena, .{ .cls = root, .count = 1 });
            return;
        }
        if (on_path.contains(root)) {
            cut.* = true;
            self.ac_flatten_appends += 1;
            try list.append(self.arena, .{ .cls = root, .count = 1 });
            return;
        }
        if (self.ac_shared.contains(root)) {
            const b = try self.bagOf(op, ty, root, on_path, cut, overflow);
            if (cut.*) {
                self.ac_flatten_appends += 1;
                try list.append(self.arena, .{ .cls = root, .count = 1 });
                return;
            }
            self.ac_flatten_appends += b.len;
            try list.appendSlice(self.arena, b);
            return;
        }
        const m = self.acExpand(root, op, ty) orelse {
            self.ac_flatten_appends += 1;
            try list.append(self.arena, .{ .cls = root, .count = 1 });
            return;
        };
        try on_path.put(self.arena, root, {});
        for (self.nodes.items[m].operands) |o| {
            try self.bagInto(op, ty, o, list, on_path, cut, overflow);
            if (cut.*) break;
        }
        _ = on_path.remove(root);
    }

    /// Materialize the `acRep`-sorted, coalesced bag of class `c` under
    /// `op`/`ty`, memoized by `(root, op, ty)` so a DAG-shared chain
    /// (`E_k = E_{k-1} ⊕ E_{k-1}`) costs O(k), not `2^k`, while a
    /// single-use chain flattens linearly through `bagInto` without ever
    /// copying a growing prefix. A cycle sets `cut` and returns a partial
    /// bag without memoizing; the rule then refuses the rewrite (sound: it
    /// only forgoes an optimization, and no canonical node is built, so the
    /// arena cannot grow the cycle away — bounded with no numeric budget).
    fn bagOf(
        self: *Island,
        op: hir.OpId,
        ty: hir.HIRTypeId,
        c: Ref,
        on_path: *std.AutoHashMapUnmanaged(Ref, void),
        cut: *bool,
        overflow: *bool,
    ) Error!Bag {
        const root = self.find(c);
        if (cut.*) return self.singleBag(root);
        const key = bagKey(root, op, ty);
        if (self.bag_memo.get(key)) |m| return m;
        if (on_path.contains(root)) {
            cut.* = true;
            return self.singleBag(root);
        }
        try on_path.put(self.arena, root, {});
        var list = std.ArrayList(BagEntry).empty;
        if (self.acExpand(root, op, ty)) |mn| {
            for (self.nodes.items[mn].operands) |o| {
                try self.bagInto(op, ty, o, &list, on_path, cut, overflow);
                if (cut.*) break;
            }
        } else {
            try list.append(self.arena, .{ .cls = root, .count = 1 });
        }
        _ = on_path.remove(root);
        if (cut.*) return self.singleBag(root);
        const bag = try self.finalizeBag(&list, overflow);
        // Do not cache a bag whose counts wrapped: a later memo hit would
        // return it without re-flagging `overflow`, and the rule would then
        // accept a malformed multiset. (The count is source-bounded, so this
        // is the defensive branch, not a reachable one.)
        if (!overflow.*) try self.bag_memo.put(self.arena, key, bag);
        return bag;
    }

    /// The total number of leaf occurrences a bag describes.
    fn bagTotal(bag: Bag) u64 {
        var total: u64 = 0;
        for (bag) |e| total = total +| e.count;
        return total;
    }

    /// Construct one AC e-node from two operand nodes, reusing an
    /// already-interned equal node if there is one and otherwise appending
    /// and hash-consing it. Returns the (possibly pre-existing) node id.
    fn mkAcNode(self: *Island, n: ENode, l: NodeId, r: NodeId) Error!NodeId {
        const ops = try self.arena.alloc(Ref, 2);
        ops[0] = self.find(self.nodes.items[l].cls);
        ops[1] = self.find(self.nodes.items[r].cls);
        const cand = ENode{
            .op = n.op,
            .ty = n.ty,
            .payload = n.payload,
            .operands = ops,
            .regions = &.{},
            .access_hops = &.{},
            .origin = null,
            .full_expr = n.full_expr,
        };
        if (try self.lookupNode(cand)) |other| return other;
        const nid = try self.addNode(cand);
        _ = try self.internNode(nid);
        return nid;
    }

    /// Materialize `count` copies of leaf class `c` as a balanced DAG with a
    /// shared operand at every level: `count == 1` is the representative
    /// node, an even count is `h ⊕ h` for `h = buildRun(count/2)`, and an
    /// odd count is `buildRun(count-1) ⊕ leaf`. O(log count) nodes.
    fn buildRun(self: *Island, n: ENode, c: Ref, count: u64) Error!NodeId {
        if (count <= 1) return self.acRep(c);
        if (count % 2 == 0) {
            const h = try self.buildRun(n, c, count / 2);
            return try self.mkAcNode(n, h, h);
        }
        const h = try self.buildRun(n, c, count - 1);
        return try self.mkAcNode(n, h, self.acRep(c));
    }

    /// The canonical AC term of a bag: one `buildRun` per `(leaf, count)`
    /// entry, left-folded in `acRep` order, so `a ⊕ b ⊕ c` becomes
    /// `(a ⊕ b) ⊕ c` and the result is a deterministic pure function of the
    /// bag. Every segment is reused from the arena when already interned,
    /// so a re-visit appends nothing.
    const Canonical = struct { cls: Ref, node: NodeId };
    fn buildCanonical(self: *Island, n: ENode, bag: Bag) Error!?Canonical {
        if (bag.len == 0) return null;
        var acc = try self.buildRun(n, bag[0].cls, bag[0].count);
        for (bag[1..]) |e| {
            const run = try self.buildRun(n, e.cls, e.count);
            acc = try self.mkAcNode(n, acc, run);
        }
        return .{ .cls = self.find(self.nodes.items[acc].cls), .node = acc };
    }

    /// Full AC search for one integer binary AC node (hir.md §8.2): collect
    /// the canonical leaf `Bag`, materialize its canonical term, and union
    /// that term's class into the node's class so extraction can pick the
    /// canonical bracketing.
    ///
    /// Termination: the target term is a deterministic function of the leaf
    /// bag, and classes only grow (unions are monotone), so a given class
    /// yields at most one canonical root per distinct bag; the rule fires
    /// only while the class does not already hold that root (`nodeEql`
    /// false and `find(chain_root) != find(n.cls)`), so saturation reaches a
    /// fixpoint. It deliberately does NOT `propose` unconditionally: those
    /// guards return before `redirect`, keeping an already-canonical chain
    /// at `preferred_prio == 0` and identity extraction intact. There is no
    /// flatten budget: `bagOf` memoizes a shared DAG and `buildRun`
    /// materializes an O(log count) shared tree. A cyclic AC class (one
    /// reachable from itself) is left uncanonicalized — sound, since it
    /// only forgoes an optimization, and it keeps the search bounded.
    fn ruleAcRegroup(self: *Island, nid: NodeId) Error!bool {
        const n = self.nodes.items[nid];
        const d = hir.registry.get(n.op);
        const rep = d.rep orelse return false;
        if (n.operands.len != 2 or !isIntegerRep(rep)) return false;
        if (!isAcInt(baseName(d.name))) return false;
        // Already the canonical left-deep chain? Then the exact `bagOf`
        // walk below would rebuild this very node and return without a
        // redirect. Detecting it structurally keeps a wide distinct-leaf
        // chain linear (the Σ depth flatten is the quadratic blowup).
        if (self.acChainCanonical(nid, n.op, n.ty)) return false;
        const cls = self.find(n.cls);

        var on_path = std.AutoHashMapUnmanaged(Ref, void).empty;
        defer on_path.deinit(self.arena);
        var cut = false;
        var overflow = false;
        var list = std.ArrayList(BagEntry).empty;
        // Both operand subtrees flatten into one accumulator: a single-use
        // subtree is inlined straight in (no growing-prefix copy), a shared
        // one is spliced from the memo. The memo is Island-wide and emptied
        // by `planAcWork` / `unionRoots`, so a later e-node reuses the
        // flatten of each distinct shared subtree.
        for (n.operands) |c| {
            try self.bagInto(n.op, n.ty, c, &list, &on_path, &cut, &overflow);
            if (cut) break;
        }
        // A cycle in the AC class: refuse to canonicalize (sound, and it
        // stops the arena from growing the cycle away).
        if (cut) return false;
        if (overflow) return false;
        const bag = try self.finalizeBag(&list, &overflow);
        if (overflow) return false;
        // Two operands each contribute at least one leaf; defensive.
        if (bagTotal(bag) < 2) return false;
        const built = (try self.buildCanonical(n, bag)) orelse return false;
        // Nothing to regroup when the canonical term is already this node's
        // content: a class split here is a stale-hash artifact that the
        // round's `rebuild` closes, and redirecting would needlessly raise
        // `preferred_prio` (and, on an identical shape, churn every round
        // without changing the tree).
        if (self.nodeEql(self.nodes.items[built.node], n)) return false;
        if (self.find(built.cls) == cls) return false; // canonical form already present
        self.nodes.items[built.node].ac_root = true;
        if (try self.redirect(built.cls, cls, built.node)) {
            self.stats.assoc += 1;
            return true;
        }
        return false;
    }

    /// A constant condition selects the taken branch (`if` / `and` / `or`,
    /// v1's `ruleConstCond`): both regions are island members, so the
    /// untaken one is pure and had no observable evaluation to lose.
    fn ruleConstCond(self: *Island, nid: NodeId) Error!bool {
        const n = self.nodes.items[nid];
        if (n.operands.len != 1 or n.regions.len < 2) return false;
        const cond = self.constIn(n.operands[0]) orelse return false;
        const taken: usize = switch (cond) {
            .bool => |b| if (b) 0 else 1,
            else => return false,
        };
        if (taken >= n.regions.len) return false;
        // The constant-condition redex was recognized; whether the redirect
        // lands is the applied half (`conds`).
        self.stats.conds_matched += 1;
        if (try self.redirectToClass(n.cls, n.regions[taken].body)) {
            self.stats.conds += 1;
            return true;
        }
        return false;
    }

    /// Aggregate projection (hir.md §8.3): `field_get(C(v0, …, vn), i)`
    /// with a known in-range index over a constructor class projects to
    /// `vi`. An out-of-range index or a non-constructor base is refused.
    fn ruleProject(self: *Island, nid: NodeId) Error!bool {
        const n = self.nodes.items[nid];
        if (n.operands.len != 1) return false;
        const base = self.find(n.operands[0]);
        var ctor: ?NodeId = null;
        for (self.classes.items[base].members.items) |m| {
            const mop = self.nodes.items[m].op;
            if (isCtorName(hir.registry.get(mop).name)) {
                ctor = m;
                break;
            }
        }
        const c = ctor orelse return false;
        const values = self.nodes.items[c].operands;
        const idx: usize = n.payload.field;
        if (idx >= values.len) return false;
        // The projection redex was recognized (a constructor base with the
        // index in range); whether the redirect lands is the applied half
        // (`projects`).
        self.stats.projects_matched += 1;
        if (try self.redirectToClass(n.cls, values[idx])) {
            self.stats.projects += 1;
            return true;
        }
        return false;
    }

    /// The constant a class is known to hold, if any member is a `const`.
    /// Memoized per class root: the scan stores the first `const` member (or
    /// `null`), and a hit reads the value from that same member, so the
    /// returned value is exactly what the scan would produce. Membership
    /// only changes on union, which clears the memo.
    fn constIn(self: *Island, cls: Ref) ?meta.ConstValue {
        const root = self.find(cls);
        if (self.const_memo.get(root)) |cached| {
            return if (cached) |m| self.nodes.items[m].payload.const_value else null;
        }
        var found: ?NodeId = null;
        for (self.classes.items[root].members.items) |m| {
            const n = self.nodes.items[m];
            if (!std.mem.eql(u8, hir.registry.get(n.op).name, "const")) continue;
            found = m;
            break;
        }
        self.const_memo.put(self.arena, root, found) catch {};
        return if (found) |m| self.nodes.items[m].payload.const_value else null;
    }

    // -----------------------------------------------------------------
    // cost model (item 22)
    // -----------------------------------------------------------------

    /// Give every e-class the member extraction must emit: the least-cost
    /// member under `CostModel`, relaxed bottom-up over the class DAG
    /// until no class improves. A member whose operand classes have no
    /// finite cost yet — reachable only through a cycle some rule created
    /// — waits for a later round, and a class that never becomes finite
    /// keeps its `preferred`, so selection degrades to the pre-cost
    /// behaviour instead of looping.
    fn select(self: *Island) Error!void {
        const n = self.classes.items.len;
        const cost = try self.arena.alloc(u64, n);
        const best = try self.arena.alloc(NodeId, n);
        for (0..n) |i| {
            cost[i] = std.math.maxInt(u64);
            best[i] = self.classes.items[i].preferred;
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (self.nodes.items, 0..) |nd, ni| {
                const node: NodeId = @intCast(ni);
                const cls = self.find(nd.cls);
                var total: u64 = CostModel.weight(nd.op);
                var finite = true;
                // Each class is paid for *once*: a class referenced twice
                // is the shape extraction materializes into a `let` (one
                // evaluation, two cheap reads), so charging it twice would
                // make the cost model blind to exactly the sharing it is
                // meant to reward.
                for (nd.operands, 0..) |c, k| {
                    const rc = self.find(c);
                    var seen = false;
                    for (nd.operands[0..k]) |prev| {
                        if (self.find(prev) == rc) {
                            seen = true;
                            break;
                        }
                    }
                    if (seen) continue;
                    const cc = cost[rc];
                    if (cc == std.math.maxInt(u64)) {
                        finite = false;
                        break;
                    }
                    total +|= cc;
                }
                if (finite) {
                    for (nd.regions, 0..) |rt, j| {
                        const rb = self.find(rt.body);
                        var seen = false;
                        for (nd.regions[0..j]) |prev| {
                            if (self.find(prev.body) == rb) {
                                seen = true;
                                break;
                            }
                        }
                        if (seen) continue;
                        const cc = cost[rb];
                        if (cc == std.math.maxInt(u64)) {
                            finite = false;
                            break;
                        }
                        total +|= cc;
                    }
                }
                if (!finite) continue;
                if (!self.improvesChoice(cls, node, total, cost, best)) continue;
                cost[cls] = total;
                best[cls] = node;
                changed = true;
            }
        }
        self.choice_cost = cost;
        self.choice_node = best;
    }

    /// The cost tie-break (item 22, extended by the AC search): strictly
    /// lower cost wins; on a tie a canonical AC root wins (so
    /// `(a + b) + c` and `a + (b + c)` extract the same bracketing); then
    /// the class's existing `preferred` member; otherwise the lower e-node
    /// index (creation order: encode before any rule).
    fn improvesChoice(self: *Island, cls: Ref, node: NodeId, total: u64, cost: []const u64, best: []const NodeId) bool {
        if (total < cost[cls]) return true;
        if (total != cost[cls]) return false;
        const node_root = self.nodes.items[node].ac_root;
        const best_root = self.nodes.items[best[cls]].ac_root;
        if (node_root != best_root) return node_root;
        const pref = self.classes.items[cls].preferred;
        if (node == pref) return best[cls] != pref;
        if (best[cls] == pref) return false;
        return node < best[cls];
    }

    /// The member extraction emits for `cls` (item 22). `saturate` runs
    /// `select`, so this is final for any island that saturated; a
    /// caller that skipped saturation falls back to the rule bookkeeping
    /// (`preferred`), which is the pre-cost behaviour.
    fn chosen(self: *Island, cls: Ref) NodeId {
        const root = self.find(cls);
        if (self.choice_node.len == 0) return self.classes.items[root].preferred;
        return self.choice_node[root];
    }

    /// The cost-model total of the form extraction emits for `cls`, or 0
    /// when `select` has not run.
    fn chosenCost(self: *Island, cls: Ref) u64 {
        if (self.choice_cost.len == 0) return 0;
        return self.choice_cost[self.find(cls)];
    }

    // -----------------------------------------------------------------
    // extraction
    // -----------------------------------------------------------------

    /// Write class `cls`'s saturated form into the existing node `site`.
    ///
    /// Identity path: the class was never redirected and `site` is one of
    /// its members — the site keeps its shape and the recursion descends
    /// into the site's *own* operands and regions (so a saturated island
    /// is a fixpoint, and binder identity is untouched). Every other case
    /// gets a fresh copy of the preferred e-node; a fresh copy is also
    /// what materializes a shared operand class into a `let`.
    fn normalize(self: *Island, cls: Ref, site: hir.ExprId) Error!void {
        const root = self.find(cls);
        const n = self.nodes.items[self.chosen(root)];
        const plan = try self.materialization(n);
        const site_ops = try self.arena.dupe(hir.ExprId, self.pr.operands(site));
        const site_regs = try self.arena.dupe(hir.RegionId, self.pr.regionsOf(site));
        const identity = self.classes.items[root].preferred_prio == 0 and
            plan == null and
            self.memberWithOrigin(root, site) and
            n.operands.len == site_ops.len and
            n.regions.len == site_regs.len;
        if (identity) {
            for (n.operands, 0..) |c, k| try self.normalize(c, site_ops[k]);
            for (n.regions, 0..) |rt, j| {
                try self.normalize(rt.body, self.pr.region(site_regs[j]).root);
            }
            return;
        }
        var overlay = std.AutoHashMapUnmanaged(Slot, hir.BinderId).empty;
        const fresh = try self.copyNodeContent(n, &overlay);
        self.pr.exprs.items[site] = self.pr.node(fresh);
        self.stats.written += 1;
        try self.written.append(self.arena, site);
    }

    fn memberWithOrigin(self: *Island, root: Ref, site: hir.ExprId) bool {
        for (self.classes.items[root].members.items) |m| {
            if (self.nodes.items[m].origin) |o| {
                if (o == site) return true;
            }
        }
        return false;
    }

    /// Which of one e-node's operand classes are shared (referenced at
    /// least twice right here) and worth a synthesized `let`: an
    /// `strict_ltr`, region-free parent evaluates each operand exactly
    /// once in order, the island proved every operand pure / total /
    /// deterministic (so hoisting the shared one is unobservable), and a
    /// trivial atom (`const` / `local` / `fn_ref`) is not worth a binder
    /// — which is also anti-oscillation, since `ruleLet`'s trivial-atom
    /// forwarding would immediately undo it.
    const Plan = struct {
        slot_of: []const ?usize,
        classes: []const Ref,
    };

    fn materialization(self: *Island, n: ENode) Error!?Plan {
        if (!self.rules.cse) return null;
        const d = hir.registry.get(n.op);
        if (d.regions != .none or d.policy != .strict_ltr) return null;
        if (n.operands.len < 2) return null;
        const slot_of = try self.arena.alloc(?usize, n.operands.len);
        @memset(slot_of, null);
        var list = std.ArrayList(Ref).empty;
        for (n.operands, 0..) |c, k| {
            if (slot_of[k] != null) continue;
            const rc = self.find(c);
            var count: usize = 0;
            for (n.operands) |other| {
                if (self.find(other) == rc) count += 1;
            }
            if (count < 2) continue;
            const pnode = self.nodes.items[self.chosen(rc)];
            if (isTrivialAtomNode(pnode.op)) continue;
            try list.append(self.arena, c);
            for (n.operands, 0..) |other, k2| {
                if (self.find(other) == rc) slot_of[k2] = list.items.len - 1;
            }
        }
        if (list.items.len == 0) return null;
        return .{ .slot_of = slot_of, .classes = try list.toOwnedSlice(self.arena) };
    }

    /// Emit a fresh copy of `n`'s content: operands and regions are
    /// deep-copied (fresh nodes / binders), and any shared operand class
    /// is materialized into a `let` chain around the result.
    fn copyNodeContent(self: *Island, n: ENode, overlay: *std.AutoHashMapUnmanaged(Slot, hir.BinderId)) Error!hir.ExprId {
        const plan = try self.materialization(n);
        var init_ids: []hir.ExprId = &.{};
        var binders: []hir.BinderId = &.{};
        var init_ty: []hir.HIRTypeId = &.{};
        if (plan) |p| {
            init_ids = try self.arena.alloc(hir.ExprId, p.classes.len);
            binders = try self.arena.alloc(hir.BinderId, p.classes.len);
            init_ty = try self.arena.alloc(hir.HIRTypeId, p.classes.len);
            for (p.classes, 0..) |c, t| {
                const pnode = self.nodes.items[self.chosen(c)];
                init_ty[t] = pnode.ty;
                init_ids[t] = try self.copyClass(c, overlay);
                binders[t] = try self.pr.addBinder(self.pr.typeOf(pnode.ty), .value);
            }
        }

        const ops = try self.arena.alloc(hir.ExprId, n.operands.len);
        for (n.operands, 0..) |c, k| {
            if (plan) |p| {
                if (p.slot_of[k]) |t| {
                    ops[k] = try self.addLocalNode(binders[t], init_ty[t], n.full_expr);
                    continue;
                }
            }
            ops[k] = try self.copyClass(c, overlay);
        }
        const regs = try self.arena.alloc(hir.RegionId, n.regions.len);
        for (n.regions, 0..) |rt, j| regs[j] = try self.copyRegion(rt, overlay);
        var result = try self.emit(n, ops, regs, overlay);
        self.stats.copied += 1;

        if (plan) |p| {
            var t = p.classes.len;
            while (t > 0) {
                t -= 1;
                result = try self.makeLet(binders[t], init_ids[t], result, n.ty, n.full_expr);
                self.stats.materialized += 1;
            }
        }
        return result;
    }

    fn copyClass(self: *Island, cls: Ref, overlay: *std.AutoHashMapUnmanaged(Slot, hir.BinderId)) Error!hir.ExprId {
        const n = self.nodes.items[self.chosen(cls)];
        return self.copyNodeContent(n, overlay);
    }

    /// Copy one encoded region: fresh binders for its params (pushed onto
    /// the overlay for the body's `local` references), the body, and the
    /// pattern with its binding leaves remapped through the overlay.
    fn copyRegion(self: *Island, rt: RegionTerm, overlay: *std.AutoHashMapUnmanaged(Slot, hir.BinderId)) Error!hir.RegionId {
        const orig_params = self.pr.params(rt.orig_region);
        std.debug.assert(orig_params.len == rt.params.len);
        const saved = try self.arena.alloc(?hir.BinderId, rt.params.len);
        const fresh = try self.arena.alloc(hir.BinderId, rt.params.len);
        for (rt.params, 0..) |slot, i| {
            saved[i] = overlay.get(slot);
            const b = self.pr.binder(orig_params[i]);
            fresh[i] = try self.pr.addBinder(self.pr.typeOf(b.ty), b.mode);
            try overlay.put(self.arena, slot, fresh[i]);
        }
        const body = try self.copyClass(rt.body, overlay);
        const pattern: ?hir.PatternId = if (rt.pattern) |p| try self.copyPattern(p, overlay) else null;
        for (rt.params, 0..) |slot, i| {
            if (saved[i]) |v| {
                try overlay.put(self.arena, slot, v);
            } else {
                _ = overlay.remove(slot);
            }
        }
        return self.pr.addRegion(fresh, body, pattern);
    }

    fn copyPattern(self: *Island, pid: hir.PatternId, overlay: *std.AutoHashMapUnmanaged(Slot, hir.BinderId)) Error!hir.PatternId {
        const pat = self.pr.pattern(pid);
        const out: hir.Pattern = switch (pat) {
            .wildcard, .literal => pat,
            .bind => |b| .{ .bind = self.mapBinder(b, overlay) },
            .type_test => |tt| .{ .type_test = .{ .ty = tt.ty, .bind = self.mapBinder(tt.bind, overlay) } },
            .tuple => |elems| blk: {
                // Pattern children live *inside* the pattern (there is no
                // program-owned pattern-child buffer), so they must be
                // allocated from the program's arena. The island `arena`
                // is a per-island scratch arena dropped after extraction:
                // a child slice allocated there would dangle in the
                // long-lived HIR as soon as `saturateIsland` returns.
                const fresh = try self.pr.arena.alloc(hir.PatternId, elems.len);
                for (elems, 0..) |e, i| fresh[i] = try self.copyPattern(e, overlay);
                break :blk .{ .tuple = fresh };
            },
            .list => |lp| blk: {
                const fresh = try self.pr.arena.alloc(hir.PatternId, lp.elems.len);
                for (lp.elems, 0..) |e, i| fresh[i] = try self.copyPattern(e, overlay);
                break :blk .{ .list = .{
                    .elems = fresh,
                    .rest = if (lp.rest) |r| try self.copyPattern(r, overlay) else null,
                } };
            },
            .struct_ => |sp| blk: {
                const fresh = try self.pr.arena.alloc(hir.Pattern.FieldPattern, sp.fields.len);
                for (sp.fields, 0..) |f, i| {
                    fresh[i] = .{ .field = f.field, .pat = try self.copyPattern(f.pat, overlay) };
                }
                break :blk .{ .struct_ = .{ .fields = fresh } };
            },
            .variant => |vp| .{ .variant = .{
                .tag = vp.tag,
                .payload = if (vp.payload) |p| try self.copyPattern(p, overlay) else null,
            } },
        };
        return self.pr.addPattern(out);
    }

    fn mapBinder(self: *Island, b: hir.BinderId, overlay: *std.AutoHashMapUnmanaged(Slot, hir.BinderId)) hir.BinderId {
        const slot = self.binder_slot.get(b) orelse return b;
        return overlay.get(slot) orelse b;
    }

    /// Build the HIR node for one e-node. A `.binder` payload (a `local`'s
    /// slot) resolves through the overlay to a rebuilt region's fresh
    /// binder, or back to the original binder for a free / enclosing
    /// reference (island-external identity is never confused).
    fn emit(self: *Island, n: ENode, ops: []const hir.ExprId, regs: []const hir.RegionId, overlay: *std.AutoHashMapUnmanaged(Slot, hir.BinderId)) Error!hir.ExprId {
        const payload: hir.Payload = switch (n.payload) {
            .binder => |s| .{ .binder = overlay.get(s) orelse self.slot_binder.items[s] },
            else => n.payload,
        };
        return self.pr.addExpr(.{
            .op = n.op,
            .ty = n.ty,
            .payload = payload,
            .operands = try self.pr.addOperands(ops),
            .regions = try self.pr.addRegions(regs),
            .full_expr = n.full_expr,
            .sema = try self.pr.internSema(.owned, .pending),
            .access_hops = n.access_hops,
        });
    }

    fn addLocalNode(self: *Island, binder: hir.BinderId, ty: hir.HIRTypeId, fe: hir.FullExprId) Error!hir.ExprId {
        return self.pr.addExpr(.{
            .op = hir.opId("local").?,
            .ty = ty,
            .payload = .{ .binder = binder },
            .full_expr = fe,
            .sema = try self.pr.internSema(.owned, .pending),
        });
    }

    fn makeLet(self: *Island, binder: hir.BinderId, init_id: hir.ExprId, body: hir.ExprId, ty: hir.HIRTypeId, fe: hir.FullExprId) Error!hir.ExprId {
        const rid = try self.pr.addRegion(&.{binder}, body, null);
        const regs = try self.pr.addRegions(&.{rid});
        const opr = try self.pr.addOperands(&.{init_id});
        return self.pr.addExpr(.{
            .op = hir.opId("let").?,
            .ty = ty,
            .operands = opr,
            .regions = regs,
            .full_expr = fe,
            .sema = try self.pr.internSema(.owned, .pending),
        });
    }

    // -----------------------------------------------------------------
    // Test accessors
    // -----------------------------------------------------------------

    /// The class one HIR node encoded to (its e-node's class), for
    /// white-box assertions.
    pub fn classOfOrigin(self: *Island, e: hir.ExprId) ?Ref {
        for (self.nodes.items, 0..) |n, i| {
            if (n.origin) |o| {
                if (o == e) return self.find(self.nodes.items[i].cls);
            }
        }
        return null;
    }

    pub fn memberCount(self: *Island, cls: Ref) usize {
        return self.classes.items[self.find(cls)].members.items.len;
    }

    pub fn liveClasses(self: *Island) usize {
        var count: usize = 0;
        for (self.classes.items, 0..) |c, i| {
            if (c.parent == i) count += 1;
        }
        return count;
    }
};

/// Encode, saturate and extract one island in place (see the file header).
pub fn optimizeIsland(
    arena: std.mem.Allocator,
    pr: *hir.Program,
    analysis: *hir_effects.Analysis,
    site: hir.ExprId,
    config: Config,
) Error!Result {
    var island = Island.init(arena, pr, analysis, config);
    island.island_fe = pr.node(site).full_expr;
    const root = try island.encode(site) orelse return .{
        .stats = island.stats,
        .changed = false,
        .written = &.{},
    };
    try island.saturate();
    island.stats.extract_cost = island.chosenCost(root);
    try island.normalize(root, site);
    island.stats.eclasses = island.liveClasses();
    island.stats.enodes = island.nodes.items.len;
    return .{
        .stats = island.stats,
        .changed = island.stats.written != 0,
        .written = island.written.items,
    };
}

// ---------------------------------------------------------------------------
// Hashing / equality helpers for the e-node key
// ---------------------------------------------------------------------------
// Moved verbatim to hir_egraph_rules.zig (pure, driver-free) and re-exported
// through the aliases below; the tests keep calling them unqualified.

const hashConst = hir_egraph_rules.hashConst;
const hashPayload = hir_egraph_rules.hashPayload;
const hashHops = hir_egraph_rules.hashHops;
const payloadEql = hir_egraph_rules.payloadEql;
const constEql = hir_egraph_rules.constEql;
const hopsEql = hir_egraph_rules.hopsEql;
const baseName = hir_egraph_rules.baseName;
const isCtorName = hir_egraph_rules.isCtorName;
const isTrivialAtomNode = hir_egraph_rules.isTrivialAtomNode;
const isIntegerRep = hir_egraph_rules.isIntegerRep;
const foldUnary = hir_egraph_rules.foldUnary;
const foldBinary = hir_egraph_rules.foldBinary;
const cmpResult = hir_egraph_rules.cmpResult;
const cmpInt = hir_egraph_rules.cmpInt;
const cmpFloat = hir_egraph_rules.cmpFloat;
const intArith = hir_egraph_rules.intArith;
const intShift = hir_egraph_rules.intShift;
const intBit = hir_egraph_rules.intBit;
const floatArith = hir_egraph_rules.floatArith;
const asInt = hir_egraph_rules.asInt;
const asF64 = hir_egraph_rules.asF64;
const asBool = hir_egraph_rules.asBool;
const asStr = hir_egraph_rules.asStr;
const intCV = hir_egraph_rules.intCV;
const floatCV = hir_egraph_rules.floatCV;
const fminIeee = hir_egraph_rules.fminIeee;
const fmaxIeee = hir_egraph_rules.fmaxIeee;
const integerAlgebra = hir_egraph_rules.integerAlgebra;
const intAlgebraT = hir_egraph_rules.intAlgebraT;
const isCommutativeInt = hir_egraph_rules.isCommutativeInt;
const isAssociativeInt = hir_egraph_rules.isAssociativeInt;
const isAcInt = hir_egraph_rules.isAcInt;
const negOpId = hir_egraph_rules.negOpId;

// ---------------------------------------------------------------------------
// White-box tests (hir.md §10.2: owning module `test {}`)
// ---------------------------------------------------------------------------

const testing = std.testing;
const hir_parse = @import("hir_parse.zig");

fn countNodes(pr: *hir.Program, root: hir.ExprId, name: []const u8) usize {
    var count: usize = 0;
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    work.append(testing.allocator, root) catch return count;
    while (work.pop()) |id| {
        if (std.mem.eql(u8, hir.registry.get(pr.node(id).op).name, name)) count += 1;
        for (pr.operands(id)) |op| work.append(testing.allocator, op) catch return count;
        for (pr.regionsOf(id)) |r| work.append(testing.allocator, pr.region(r).root) catch return count;
    }
    return count;
}

fn firstNodeNamed(pr: *hir.Program, root: hir.ExprId, name: []const u8) ?hir.ExprId {
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(testing.allocator);
    work.append(testing.allocator, root) catch return null;
    while (work.pop()) |id| {
        if (std.mem.eql(u8, hir.registry.get(pr.node(id).op).name, name)) return id;
        for (pr.operands(id)) |op| work.append(testing.allocator, op) catch return null;
        for (pr.regionsOf(id)) |r| work.append(testing.allocator, pr.region(r).root) catch return null;
    }
    return null;
}

/// A one-function HIR-text program with a validated analysis. The arena
/// lives on the heap because `parseText` returns its `ArenaAllocator` by
/// value: the program's allocator is re-seated onto that live copy, which
/// extraction's appends require.
const Fixture = struct {
    arena: *std.heap.ArenaAllocator,
    built: *hir.BuiltProgram,
    analysis: *hir_effects.Analysis,

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }

    fn pr(self: *Fixture) *hir.Program {
        return &self.built.program;
    }

    fn root(self: *Fixture) hir.ExprId {
        return self.built.funcs.items[0].root;
    }

    fn island(self: *Fixture) Island {
        var it = Island.init(self.arena.allocator(), self.pr(), self.analysis, .{});
        it.island_fe = self.pr().node(self.root()).full_expr;
        return it;
    }
};

fn fixture(ret: meta.Type, text: []const u8) !Fixture {
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    errdefer testing.allocator.destroy(arena);
    const parsed = try hir_parse.parseText(text, .{});
    arena.* = parsed.arena;
    errdefer arena.deinit();
    const a = arena.allocator();
    const built = try a.create(hir.BuiltProgram);
    built.* = .{ .arena = a, .program = parsed.program };
    built.program.arena = a;
    try built.funcs.append(a, .{
        .name = "f",
        .kind = .member,
        .module = 0,
        .params = try a.alloc(hir.FuncParam, 0),
        .ret = try built.program.intern(ret),
        .root = parsed.root,
    });
    const analysis = try a.create(hir_effects.Analysis);
    analysis.* = try hir_effects.Analysis.init(a, built, .{});
    try analysis.analyze();
    return .{ .arena = arena, .built = built, .analysis = analysis };
}

const i32ty = meta.Type{ .primitive = .int32 };

test "the arena merges α-equal island subtrees into one e-class (CSE)" {
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(mul.i32(%B0, %B1), mul.i32(%B0, %B1)) }");
    defer f.deinit();
    const pr = f.pr();
    const root = f.root();
    const body = pr.region(pr.regionsOf(root)[0]).root;
    const m0 = pr.operands(body)[0];
    const m1 = pr.operands(body)[1];
    try testing.expect(m0 != m1);

    var it = f.island();
    const root_cls = (try it.encode(root)).?;
    try it.saturate();
    // Congruence put both `mul`s (and both `%B0` / both `%B1` reads) into
    // one class each, without any sharing rule.
    const c0 = it.classOfOrigin(m0).?;
    try testing.expectEqual(c0, it.classOfOrigin(m1).?);
    try testing.expectEqual(@as(usize, 2), it.memberCount(c0));
    try testing.expect(it.stats.merges >= 2);
    try testing.expectEqual(@as(usize, 0), it.stats.materialized);

    try it.normalize(root_cls, root);
    // Extraction materializes the shared class as a `let` at its one
    // strict_ltr parent: one evaluation, two reads.
    try testing.expect(it.stats.written > 0);
    try testing.expectEqual(@as(usize, 1), it.stats.materialized);
    try testing.expectEqualStrings("let", hir.registry.get(pr.node(body).op).name);
    // The extraction materializes the shared `mul` once (one `let`, one
    // `mul`) and reads it twice; the emitted tree has one `mul` with four
    // `local` reads.
    try testing.expectEqual(@as(usize, 1), countNodes(pr, root, "let"));
    try testing.expectEqual(@as(usize, 1), countNodes(pr, root, "mul.i32"));
    try testing.expectEqual(@as(usize, 4), countNodes(pr, root, "local"));
}

test "rules.fold toggle: constant folding fires by default and is suppressed off" {
    {
        var f = try fixture(i32ty, "fn () { add.i32(1i32, 2i32) }");
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{});
        try testing.expect(result.stats.folds >= 1);
        try testing.expectEqualStrings("const", hir.registry.get(pr.node(body).op).name);
    }
    {
        var f = try fixture(i32ty, "fn () { add.i32(1i32, 2i32) }");
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{ .rules = .{ .fold = false } });
        try testing.expectEqual(@as(usize, 0), result.stats.folds);
        try testing.expectEqual(@as(usize, 0), result.stats.folds_matched);
        try testing.expectEqualStrings("add.i32", hir.registry.get(pr.node(body).op).name);
    }
}

test "rules.cse toggle: the synthesized sharing let fires by default and is suppressed off" {
    const text = "fn (B0: i32, B1: i32) { add.i32(mul.i32(%B0, %B1), mul.i32(%B0, %B1)) }";
    {
        var f = try fixture(i32ty, text);
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{});
        try testing.expectEqual(@as(usize, 1), result.stats.materialized);
        try testing.expectEqual(@as(usize, 1), countNodes(pr, body, "mul.i32"));
    }
    {
        var f = try fixture(i32ty, text);
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{ .rules = .{ .cse = false } });
        try testing.expectEqual(@as(usize, 0), result.stats.materialized);
        // The two α-equal `mul`s stay distinct tree nodes (no synthesized
        // `let`), and extraction wrote nothing.
        try testing.expectEqual(@as(usize, 2), countNodes(pr, body, "mul.i32"));
        try testing.expect(!result.changed);
    }
}

test "SLOT numbering reuses one slot per binder and keeps free-binder identity" {
    // The inner λ is the island: its region param is bound inside, the
    // `%B0` it reads is bound outside.
    var f = try fixture(i32ty, "fn (B0: i32) { call(fn (B1: i32) { add.i32(mul.i32(%B0, 1i32), mul.i32(%B0, 1i32)) }, %B0) }");
    defer f.deinit();
    const pr = f.pr();
    const outer = f.root();
    const call = pr.region(pr.regionsOf(outer)[0]).root;
    const lam = pr.operands(call)[0];
    const inner = pr.region(pr.regionsOf(lam)[0]).root;
    const outer_b0 = pr.node(pr.operands(call)[1]).payload.binder;

    var it = f.island();
    const cls = (try it.encode(lam)).?;
    // One slot per distinct binder: the λ param `B1` and the free `B0`.
    try testing.expectEqual(@as(usize, 2), it.slot_binder.items.len);
    const s_b1 = it.slotOfBinder(pr.params(pr.regionsOf(lam)[0])[0]);
    const s_b0 = it.slotOfBinder(outer_b0);
    try testing.expect(s_b1 != s_b0);
    // The two `%B0` reads are one class (one slot), and distinct from `%B1`.
    const add0 = pr.operands(inner)[0];
    const add1 = pr.operands(inner)[1];
    const b0_read = pr.operands(add0)[0];
    const b0_read2 = pr.operands(add1)[0];
    try testing.expectEqual(s_b0, it.slotOfBinder(pr.node(b0_read).payload.binder));
    try testing.expectEqual(it.classOfOrigin(b0_read).?, it.classOfOrigin(b0_read2).?);

    try it.saturate();
    try it.normalize(cls, lam);
    // `mul(%B0, 1) → %B0`, so each mul site is rewritten with a *fresh*
    // local node — and that node still names the island-external binder.
    try testing.expectEqual(@as(usize, 2), it.stats.written);
    const new_add0 = pr.operands(inner)[0];
    const new_add1 = pr.operands(inner)[1];
    for ([_]hir.ExprId{ new_add0, new_add1 }) |site| {
        try testing.expectEqualStrings("local", hir.registry.get(pr.node(site).op).name);
        try testing.expectEqual(outer_b0, pr.node(site).payload.binder);
    }
    // Tree, not DAG: the two rewritten sites are distinct nodes.
    try testing.expect(new_add0 != new_add1);
}

test "encode rejects an unencoded op and a non-seg-safe subtree (recursive boundary)" {
    // A `let` has a SEG encoding and is structurally pure, yet the
    // initializer's `div` may trap: `isSegSafe` — not an opcode switch —
    // refuses the node, and the refusal propagates to the enclosing λ.
    var f = try fixture(i32ty, "fn (B0: i32) { let B1: i32 = div.i32(%B0, 2i32) { add.i32(%B1, %B0) } }");
    defer f.deinit();
    const pr = f.pr();
    const root = f.root();
    const let_node = pr.region(pr.regionsOf(root)[0]).root;
    try testing.expect(hir.registry.get(pr.node(let_node).op).seg != null);
    const body = pr.region(pr.regionsOf(let_node)[0]).root;
    const init = pr.operands(let_node)[0];
    try testing.expect(!try f.analysis.isSegSafe(init));
    try testing.expect(!try f.analysis.isSegSafe(let_node));

    var it = f.island();
    // The boundary is recursive: the λ and the `let` are refused, while
    // the `let`'s region body is an island of its own.
    try testing.expect((try it.encode(root)) == null);
    try testing.expect((try it.encode(let_node)) == null);
    try testing.expect((try it.encode(init)) == null);
    try testing.expect((try it.encode(body)) != null);
    const refused = try optimizeIsland(f.arena.allocator(), pr, f.analysis, root, .{});
    try testing.expectEqual(@as(usize, 0), refused.stats.enodes);
    try testing.expect(!refused.changed);

    // An op with no `.seg` facet at all is a hard boundary: `encode`
    // refuses it on the registry facet, before any effect query.
    var g = try fixture(i32ty, "fn (B0: any) { any_cast(%B0): i32 }");
    defer g.deinit();
    const gpr = g.pr();
    const cast = firstNodeNamed(gpr, g.root(), "any_cast") orelse return error.TestUnexpectedResult;
    try testing.expect(hir.registry.get(gpr.node(cast).op).seg == null);
    var git = g.island();
    try testing.expect((try git.encode(cast)) == null);

    // The full-expression-boundary variant (a source-level `let` whose
    // initializer opens its own FE) needs the builder's FE split, so it
    // lives in `hir_seg_tests.zig`'s black-box suite.
}

test "extraction is identity on a saturated island and writes only what a rule changed" {
    {
        var f = try fixture(i32ty, "fn (B0: i32) { add.i32(%B0, 1i32) }");
        defer f.deinit();
        const pr = f.pr();
        const before = pr.exprs.items.len;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, f.root(), .{});
        try testing.expect(!result.changed);
        try testing.expectEqual(@as(usize, 0), result.stats.written);
        try testing.expectEqual(@as(usize, 0), result.stats.copied);
        try testing.expectEqual(before, pr.exprs.items.len);
        try testing.expect(result.stats.converged);
        // Non-vacuity: the island really was encoded (e-nodes exist).
        try testing.expect(result.stats.enodes > 0);
        try testing.expect(result.stats.eclasses > 0);
    }
    {
        var f = try fixture(i32ty, "fn (B0: i32) { add.i32(%B0, 0i32) }");
        defer f.deinit();
        const pr = f.pr();
        const root = f.root();
        const add_site = pr.region(pr.regionsOf(root)[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, root, .{});
        try testing.expect(result.changed);
        try testing.expectEqual(@as(usize, 1), result.stats.written);
        try testing.expectEqual(@as(usize, 1), result.stats.algebra);
        try testing.expectEqual(@as(usize, 1), result.stats.unions);
        // `add(x, 0) → x`: the site is overwritten in place with the value.
        try testing.expectEqualStrings("local", hir.registry.get(pr.node(add_site).op).name);
        try testing.expectEqual(@as(usize, 1), result.stats.copied);
        try testing.expectEqual(@as(usize, 1), countNodes(pr, root, "local"));
    }
}

test "aggregate projection fires only for an in-range index over a constructor class" {
    {
        var f = try fixture(i32ty, "fn (B0: i32) { field_get[1](tuple_make(%B0, 2i32)) : i32 }");
        defer f.deinit();
        const pr = f.pr();
        const root = f.root();
        const site = pr.region(pr.regionsOf(root)[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, root, .{});
        try testing.expectEqual(@as(usize, 1), result.stats.projects);
        try testing.expectEqualStrings("const", hir.registry.get(pr.node(site).op).name);
        try testing.expectEqual(@as(i64, 2), pr.node(site).payload.const_value.int);
    }
    {
        // Out of range for the constructor: the parser cannot write it, so
        // corrupt exactly that field (the malformed-HIR shape the black-box
        // negatives use) and assert the rule refuses.
        var f = try fixture(i32ty, "fn (B0: i32) { field_get[0](tuple_make(%B0, 2i32)) : i32 }");
        defer f.deinit();
        const pr = f.pr();
        const root = f.root();
        const site = pr.region(pr.regionsOf(root)[0]).root;
        pr.exprs.items[site].payload = .{ .field = 2 };
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, root, .{});
        try testing.expectEqual(@as(usize, 0), result.stats.projects);
        try testing.expect(!result.changed);
        try testing.expectEqualStrings("field_get", hir.registry.get(pr.node(site).op).name);
    }
    {
        // A tuple-typed binding is an admissible base (the read is pure)
        // but not a constructor, so there is nothing to project.
        var f = try fixture(i32ty, "fn (B0: (i32, i32)) { field_get[0](%B0) : i32 }");
        defer f.deinit();
        const pr = f.pr();
        const root = f.root();
        const site = pr.region(pr.regionsOf(root)[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, root, .{});
        try testing.expectEqual(@as(usize, 0), result.stats.projects);
        try testing.expectEqual(@as(usize, 0), result.stats.projects_matched);
        try testing.expect(result.stats.enodes > 0);
        try testing.expectEqualStrings("field_get", hir.registry.get(pr.node(site).op).name);
    }
}

test "per-rule counters separate recognized redexes from applied unions" {
    // A saturated redex still *matches* on a later round, but an already-
    // merged class no longer applies: matched ≥ applied, and the two are
    // equal only when every recognition changed the arena.
    var f = try fixture(i32ty, "fn (B0: i32) { add.i32(%B0, 0i32) }");
    defer f.deinit();
    const root = f.root();
    const result = try optimizeIsland(f.arena.allocator(), f.pr(), f.analysis, root, .{});
    // `x + 0 → x` matched and applied on the first round.
    try testing.expect(result.stats.algebra_matched >= 1);
    try testing.expect(result.stats.algebra_matched >= result.stats.algebra);
    try testing.expect(result.stats.algebra >= 1);

    // A non-redex shapes nothing: `add.i32(%B0, 1i32)` has no identity and
    // no constant operand list, so no rule recognizes it.
    var g = try fixture(i32ty, "fn (B0: i32) { add.i32(%B0, 1i32) }");
    defer g.deinit();
    const g_result = try optimizeIsland(g.arena.allocator(), g.pr(), g.analysis, g.root(), .{});
    try testing.expectEqual(@as(usize, 0), g_result.stats.folds_matched);
    try testing.expectEqual(@as(usize, 0), g_result.stats.algebra_matched);
    try testing.expectEqual(@as(usize, 0), g_result.stats.folds);
    try testing.expectEqual(@as(usize, 0), g_result.stats.algebra);
}

test "constant folding covers the 32/64-bit and float reps" {
    try testing.expectEqual(@as(i64, 3), foldBinary("add", .i32, .{ .int = 1 }, .{ .int = 2 }).?.int);
    try testing.expectEqual(@as(i64, 5), foldBinary("add", .i64, .{ .int = 4 }, .{ .int = 1 }).?.int);
    try testing.expectEqual(@as(i64, 6), foldBinary("mul", .u32, .{ .int = 3 }, .{ .int = 2 }).?.int);
    // Integer arithmetic wraps (never traps).
    const wrapped = foldBinary("add", .i32, .{ .int = std.math.maxInt(i32) }, .{ .int = 1 }).?;
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), wrapped.int);
    // Division by zero and signed `min / -1` are left to the runtime.
    try testing.expect(foldBinary("div", .i32, .{ .int = 1 }, .{ .int = 0 }) == null);
    try testing.expect(foldBinary("div", .i64, .{ .int = std.math.minInt(i64) }, .{ .int = -1 }) == null);
    try testing.expectEqual(@as(i64, 0), foldBinary("rem", .i64, .{ .int = std.math.minInt(i64) }, .{ .int = -1 }).?.int);
    // Float division folds (IEEE, never traps).
    const inf = foldBinary("div", .f32, .{ .float = 1.0 }, .{ .float = 0.0 }).?;
    try testing.expect(std.math.isInf(inf.float));
    // Comparisons produce bools.
    try testing.expect(foldBinary("lt", .i32, .{ .int = 1 }, .{ .int = 2 }).?.bool);
    try testing.expect(foldBinary("eq", .str, .{ .string = "a" }, .{ .string = "a" }).?.bool);
    // `byte` has no arithmetic but its comparisons fold unsigned.
    try testing.expect(foldBinary("lt", .byte, .{ .int = 1 }, .{ .int = 2 }).?.bool);
    try testing.expect(!foldBinary("gt", .byte, .{ .int = 1 }, .{ .int = 2 }).?.bool);
    try testing.expect(foldBinary("eq", .byte, .{ .int = 2 }, .{ .int = 2 }).?.bool);
    // A non-comparison byte op has no fold.
    try testing.expect(foldBinary("add", .byte, .{ .int = 1 }, .{ .int = 2 }) == null);
    // Shifts mask the count.
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), foldBinary("shl", .i32, .{ .int = 1 }, .{ .int = 31 }).?.int);
    try testing.expectEqual(@as(i64, 1), foldBinary("shl", .i32, .{ .int = 1 }, .{ .int = 32 }).?.int);
}

test "unary folding: neg wraps, abs clears the sign, not/clz/popcount" {
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), foldUnary("neg", .i32, .{ .int = std.math.minInt(i32) }).?.int);
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), foldUnary("abs", .i32, .{ .int = std.math.minInt(i32) }).?.int);
    try testing.expectEqual(@as(f64, 2.0), foldUnary("abs", .f64, .{ .float = -2.0 }).?.float);
    try testing.expect(foldUnary("not", .bool, .{ .bool = true }).?.bool == false);
    try testing.expectEqual(@as(i64, 32), foldUnary("clz", .u32, .{ .int = 0 }).?.int);
    try testing.expectEqual(@as(i64, 3), foldUnary("popcount", .u32, .{ .int = 0b1011 }).?.int);
    // No unsigned abs (the CFG leaves it unfolded too).
    try testing.expect(foldUnary("abs", .u32, .{ .int = 3 }) == null);
}

test "integer algebra identities are declared, not guessed" {
    const z = meta.ConstValue{ .int = 0 };
    const one = meta.ConstValue{ .int = 1 };
    const allones_i32 = meta.ConstValue{ .int = -1 };
    try testing.expectEqual(@as(usize, 1), intAlgebraT(i32, "add", z, null).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "add", null, z).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "sub", null, z).?.keep);
    try testing.expectEqual(@as(usize, 1), intAlgebraT(i32, "mul", one, null).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "mul", null, one).?.keep);
    try testing.expectEqual(@as(i64, 0), intAlgebraT(i32, "mul", z, null).?.value.int);
    try testing.expectEqual(@as(usize, 1), intAlgebraT(i32, "band", allones_i32, null).?.keep);
    try testing.expectEqual(@as(i64, 0), intAlgebraT(i32, "band", z, null).?.value.int);
    try testing.expectEqual(@as(usize, 1), intAlgebraT(u32, "bor", z, null).?.keep);
    try testing.expectEqual(@as(usize, 0), intAlgebraT(i32, "shl", null, z).?.keep);
    // Float reps take no integer identity.
    try testing.expect(integerAlgebra("add", .f32, null, null) == null);
}

test "AC: commutative operands merge into one class" {
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(add.i32(%B0, %B1), add.i32(%B1, %B0)) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    const a0 = pr.operands(body)[0];
    const a1 = pr.operands(body)[1];
    var it = f.island();
    _ = try it.encode(f.root());
    try it.saturate();
    // The AC regroup canonicalized the `b + a` chain into `a + b` and
    // unioned it with the `a + b` class, so the two `add`s are one class
    // (plus the canonical chain's intermediate `a + b` node). (`stats.ac`
    // — the `eq`/`ne` in-place swap — does not move for an associative op.)
    try testing.expect(it.stats.assoc > 0);
    try testing.expectEqual(@as(usize, 0), it.stats.ac);
    const c = it.classOfOrigin(a0).?;
    try testing.expectEqual(c, it.classOfOrigin(a1).?);
    // Three members: the two source `add`s plus one rule-synthesized
    // canonical `add`. The source operand orders are reversed (`a0 = a + b`,
    // `a1 = b + a`), so on the first visit — before that round's `rebuild`
    // re-keys the index — the raw-hash lookup misses and materializes one
    // extra structurally-α-equal node, which `internNode` then merges into
    // the class. It is created once, not per round, and extraction collapses
    // the class to a single canonical shape.
    try testing.expectEqual(@as(usize, 3), it.memberCount(c));
}

test "AC: x - x collapses to const 0 once commutativity merged the operands" {
    // `(a*b) - (b*a)`: the congruence identity needs the AC merge first —
    // with distinct operand classes `integerAlgebra` has no redex here.
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { sub.i32(mul.i32(%B0, %B1), mul.i32(%B1, %B0)) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    var it = f.island();
    _ = try it.encode(f.root());
    try it.saturate();
    try testing.expect(it.stats.assoc > 0);
    // The sub's class holds the folded `const 0` member.
    const sub_cls = it.classOfOrigin(body).?;
    const zero = it.constIn(sub_cls).?;
    try testing.expectEqual(@as(i64, 0), zero.int);
}

test "AC: float adds are never canonicalized (NaN payload / ±0 observable)" {
    const f32ty = meta.Type{ .primitive = .float32 };
    var f = try fixture(f32ty, "fn (B0: f32, B1: f32) { add.f32(add.f32(%B0, %B1), add.f32(%B1, %B0)) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    const a0 = pr.operands(body)[0];
    const a1 = pr.operands(body)[1];
    var it = f.island();
    _ = try it.encode(f.root());
    try it.saturate();
    // No swap / regroup fired, and the two adds stayed distinct classes.
    try testing.expectEqual(@as(usize, 0), it.stats.ac);
    try testing.expectEqual(@as(usize, 0), it.stats.assoc);
    try testing.expect(it.classOfOrigin(a0).? != it.classOfOrigin(a1).?);
}

test "AC: (a+b)+c and a+(b+c) land in one e-class" {
    // The two bracketings are structurally different, so congruence alone
    // never merges them; only the flatten/sort/regroup search does.
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32, B2: i32) { add.i32(add.i32(add.i32(%B0, %B1), %B2), add.i32(%B0, add.i32(%B1, %B2))) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    const left = pr.operands(body)[0];
    const right = pr.operands(body)[1];
    var it = f.island();
    _ = try it.encode(f.root());
    try it.saturate();
    try testing.expect(it.stats.converged);
    try testing.expect(it.stats.assoc > 0);
    const cls = it.classOfOrigin(left).?;
    try testing.expectEqual(cls, it.classOfOrigin(right).?);
    // The merged class holds the two source bracketings plus the canonical
    // left-deep chain root: the outer node's two operand classes flatten to
    // the six-occurrence multiset `[a, a, b, b, c, c]`, so the canonical
    // chain is a distinct five-`add` shape, not either source tree.
    try testing.expectEqual(@as(usize, 3), it.memberCount(cls));
}

test "AC: extraction emits the canonical left-deep form and is a fixpoint" {
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32, B2: i32) { add.i32(%B0, add.i32(%B1, %B2)) }");
    defer f.deinit();
    const pr = f.pr();
    const root = f.root();
    const body = pr.region(pr.regionsOf(root)[0]).root;
    const r1 = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{});
    try testing.expect(r1.changed);
    try testing.expect(r1.stats.assoc > 0);
    // The emitted chain is left-deep: the outer add's first operand is an
    // add, its second a leaf. A right-leaning source chain is rewritten.
    try testing.expectEqualStrings("add.i32", hir.registry.get(pr.node(body).op).name);
    const first = pr.operands(body)[0];
    const second = pr.operands(body)[1];
    try testing.expectEqualStrings("add.i32", hir.registry.get(pr.node(first).op).name);
    try testing.expectEqualStrings("local", hir.registry.get(pr.node(second).op).name);
    // A second saturation over the now-canonical chain is identity: the
    // guard keeps `preferred_prio == 0` and nothing regroups again.
    const r2 = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{});
    try testing.expect(!r2.changed);
    try testing.expectEqual(@as(usize, 0), r2.stats.assoc);
    try testing.expectEqual(@as(usize, 0), r2.stats.written);
}

test "AC: with rules.ac off the two bracketings stay in separate classes" {
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32, B2: i32) { add.i32(add.i32(add.i32(%B0, %B1), %B2), add.i32(%B0, add.i32(%B1, %B2))) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    const left = pr.operands(body)[0];
    const right = pr.operands(body)[1];
    var it = f.island();
    it.rules.ac = false;
    _ = try it.encode(f.root());
    try it.saturate();
    try testing.expectEqual(@as(usize, 0), it.stats.assoc);
    try testing.expect(it.classOfOrigin(left).? != it.classOfOrigin(right).?);
}

test "AC: non-associative and eq/ne ops are never regrouped" {
    // `sub` / `shl` / `shr` are island-admissible but not associative:
    // regrouping would change the result, so `assoc` stays zero.
    for ([_][]const u8{
        "sub.i32(sub.i32(%B0, %B1), %B2)",
        "shl.i32(shl.i32(%B0, %B1), %B2)",
        "shr.i32(shr.i32(%B0, %B1), %B2)",
    }) |expr| {
        const text = try std.fmt.allocPrint(testing.allocator, "fn (B0: i32, B1: i32, B2: i32) {{ {s} }}", .{expr});
        defer testing.allocator.free(text);
        var f = try fixture(i32ty, text);
        defer f.deinit();
        const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), f.pr(), f.analysis, body, .{});
        try testing.expectEqual(@as(usize, 0), result.stats.assoc);
    }
    // `eq` / `ne` are commutative but not associative: the in-place swap
    // (`stats.ac`) fires, regrouping never does.
    {
        const boolty = meta.Type{ .primitive = .bool };
        var f = try fixture(boolty, "fn (B0: i32, B1: i32) { eq.bool(eq.i32(%B0, %B1), eq.i32(%B1, %B0)) }");
        defer f.deinit();
        const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), f.pr(), f.analysis, body, .{});
        try testing.expectEqual(@as(usize, 0), result.stats.assoc);
        try testing.expect(result.stats.ac > 0);
    }
}

test "AC: integer min/max are commuted and regrouped" {
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { min.i32(min.i32(%B0, %B1), min.i32(%B1, %B0)) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    const left = pr.operands(body)[0];
    const right = pr.operands(body)[1];
    var it = f.island();
    _ = try it.encode(f.root());
    try it.saturate();
    try testing.expect(it.stats.assoc > 0);
    try testing.expectEqual(it.classOfOrigin(left).?, it.classOfOrigin(right).?);

    var g = try fixture(i32ty, "fn (B0: i32, B1: i32) { max.i32(max.i32(%B0, %B1), max.i32(%B1, %B0)) }");
    defer g.deinit();
    var git = g.island();
    _ = try git.encode(g.root());
    try git.saturate();
    try testing.expect(git.stats.assoc > 0);
}

test "AC: an operand class merge across rounds still converges and canonicalizes" {
    // `(a + b) + ((b + a) + c)`: the inner `a+b` and `b+a` merge in an
    // early round, which changes the outer flatten's leaf multiset — the
    // search must still reach a quiet-round fixpoint (no numeric bound).
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32, B2: i32) { add.i32(add.i32(%B0, %B1), add.i32(add.i32(%B1, %B0), %B2)) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    const inner_left = pr.operands(body)[0];
    const right_add = pr.operands(body)[1];
    const inner_right = pr.operands(right_add)[0];
    var it = f.island();
    _ = try it.encode(f.root());
    try it.saturate();
    try testing.expect(it.stats.converged);
    try testing.expect(it.stats.assoc > 0);
    try testing.expectEqual(it.classOfOrigin(inner_left).?, it.classOfOrigin(inner_right).?);
}

test "AC: DAG-shared multiplicity (x + x, x = a + b) regroups the four leaves, not two" {
    // `add(add(a, b), add(a, b))`: CSE makes both operands one class, so
    // the leaf multiset is `[a, b, a, b]` (the shared `x = a + b` class is
    // expanded twice), and the canonical form is a three-piece chain
    // distinct from the source's `x + x`. The search must see the four
    // leaves, not merge the two `x` reads naively, and a re-saturation over
    // the canonical tree must no-op instead of appending a duplicate chain
    // every round.
    const text = "fn (B0: i32, B1: i32) { add.i32(add.i32(%B0, %B1), add.i32(%B0, %B1)) }";

    // 1. Structure: the two source operands merge into one class (CSE) and
    //    the search fires on the merged class's four leaves.
    {
        var f = try fixture(i32ty, text);
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const left = pr.operands(body)[0];
        const right = pr.operands(body)[1];
        var it = f.island();
        _ = (try it.encode(f.root())).?;
        try it.saturate();
        try testing.expect(it.stats.converged);
        try testing.expect(it.stats.assoc > 0);
        try testing.expect(it.stats.merges >= 1);
        try testing.expectEqual(it.classOfOrigin(left).?, it.classOfOrigin(right).?);
    }

    // 2. Extraction emits the shared `a + b` (materialized once) plus the
    //    dangling `+ a + b` above it: two `add` nodes, not the source's
    //    three, and the canonical `x + x`-shaped result the search picked.
    {
        var f = try fixture(i32ty, text);
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const r = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{});
        try testing.expect(r.stats.assoc > 0);
        try testing.expectEqual(@as(usize, 2), countNodes(pr, body, "add.i32"));
        try testing.expectEqual(@as(usize, 1), r.stats.materialized);
    }

    // 3. Fixpoint: a second island over the same source regroups the same
    //    way and appends the same nodes — no per-round chain drift — and
    //    extraction writes the same canonical two-`add` tree.
    {
        var g = try fixture(i32ty, text);
        defer g.deinit();
        const pr2 = g.pr();
        const body2 = pr2.region(pr2.regionsOf(g.root())[0]).root;
        const r2 = try optimizeIsland(g.arena.allocator(), pr2, g.analysis, body2, .{});
        try testing.expect(r2.stats.assoc > 0);
        try testing.expectEqual(@as(usize, 2), countNodes(pr2, body2, "add.i32"));
    }
}

test "AC: a shared DAG diamond completes with no flatten budget" {
    // `k` nested `add(x, x)` levels: the *source* doubles each level, so
    // the encoded e-node count is exponential in `k` before CSE — that is
    // the parser/driver, not the AC build. The old `max_ac_leaves` budget
    // existed for the *flatten* expanding the shared DAG into `2^k` leaves;
    // that is gone: `bagOf` memoizes to the single entry `(x, 2^k)` and
    // `buildRun` materializes it as the O(k) shared doubling tree the
    // source already is. So the rewrite adds nothing, `k = 11` no longer
    // hangs, and no numeric budget is needed.
    const k6 = try diamondEnodes(testing.allocator, 6);
    const k8 = try diamondEnodes(testing.allocator, 8);
    const k11 = try diamondEnodes(testing.allocator, 11);
    try testing.expect(k6 < 512);
    try testing.expect(k8 < 2048);
    try testing.expect(k11 < 16384);

    // The source diamond is already the canonical balanced run, so the rule
    // never redirects (`assoc == 0`), the root keeps its identity, and a
    // forced extra round appends no e-nodes.
    const text = try diamondText(testing.allocator, 8);
    defer testing.allocator.free(text);
    var f = try fixture(i32ty, text);
    defer f.deinit();
    const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
    var it = f.island();
    const root_cls = (try it.encode(f.root())).?;
    try it.saturate();
    try testing.expect(it.stats.converged);
    try testing.expectEqual(@as(usize, 0), it.stats.assoc);
    try testing.expect(it.classOfOrigin(body) != null);
    try testing.expectEqual(@as(usize, 0), it.classes.items[root_cls].preferred_prio);
    const d = try forcedRound(&it);
    try testing.expectEqual(@as(isize, 0), d.nodes);
    try testing.expectEqual(@as(usize, 0), d.unions);
}

/// The e-node count `optimizeIsland` reached for a `k`-level shared add
/// diamond (`add(add(…(a, a)…, add(…)))`, each level CSE-shared).
fn diamondEnodes(allocator: std.mem.Allocator, k: usize) !usize {
    const text = try diamondText(allocator, k);
    defer allocator.free(text);
    var f = try fixture(i32ty, text);
    defer f.deinit();
    const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
    const r = try optimizeIsland(f.arena.allocator(), f.pr(), f.analysis, body, .{});
    return r.stats.enodes;
}

/// The source of a `k`-level shared add diamond: `add.i32(add.i32(…, …),
/// add.i32(…, …))`, each level CSE-shared.
fn diamondText(allocator: std.mem.Allocator, k: usize) ![]u8 {
    var expr = std.ArrayList(u8).empty;
    defer expr.deinit(allocator);
    try expr.appendSlice(allocator, "add.i32(%B0, %B0)");
    for (0..k) |_| {
        const next = try std.fmt.allocPrint(allocator, "add.i32({s}, {s})", .{ expr.items, expr.items });
        expr.clearRetainingCapacity();
        try expr.appendSlice(allocator, next);
        allocator.free(next);
    }
    return std.fmt.allocPrint(allocator, "fn (B0: i32) {{ {s} }}", .{expr.items});
}

/// Force one more `applyRules`-over-every-node + `rebuild` pass over a
/// saturated island and return the change in e-node count and in
/// `stats.unions`. Both must be zero: a saturated arena appends no node and
/// performs no union. A rewrite that re-appends a canonical chain node every
/// rebuild shows up as a positive node delta.
const ForcedRound = struct { nodes: isize, unions: usize };
fn forcedRound(it: *Island) !ForcedRound {
    const before_nodes: isize = @intCast(it.nodes.items.len);
    const before_unions = it.stats.unions;
    var i: usize = 0;
    while (i < it.nodes.items.len) : (i += 1) {
        _ = try it.applyRules(@intCast(i));
    }
    _ = try it.rebuild();
    return .{
        .nodes = @as(isize, @intCast(it.nodes.items.len)) - before_nodes,
        .unions = it.stats.unions - before_unions,
    };
}

test "AC: a forced extra round over a canonical island appends no e-nodes" {
    // Regression for the deleted representative-keyed guard: it hashed a
    // malformed placeholder root (`op(leaf_last, leaf_last)`), so it missed
    // the already-present canonical chain and appended duplicate chain
    // e-nodes on every rebuild (and never settled). One forced
    // `applyRules` + `rebuild` over a saturated island must add exactly
    // zero nodes.
    {
        var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(add.i32(%B0, %B1), add.i32(%B0, %B1)) }");
        defer f.deinit();
        var it = f.island();
        _ = (try it.encode(f.root())).?;
        try it.saturate();
        try testing.expect(it.stats.converged);
        try testing.expect(it.stats.assoc > 0);
        const d = try forcedRound(&it);
        try testing.expectEqual(@as(isize, 0), d.nodes);
        try testing.expectEqual(@as(usize, 0), d.unions);
    }
    // The DAG diamond is the case that used to append a chain node per
    // level per round when the flatten budget was in play.
    {
        const text = try diamondText(testing.allocator, 6);
        defer testing.allocator.free(text);
        var f = try fixture(i32ty, text);
        defer f.deinit();
        var it = f.island();
        _ = (try it.encode(f.root())).?;
        try it.saturate();
        try testing.expect(it.stats.converged);
        const d = try forcedRound(&it);
        try testing.expectEqual(@as(isize, 0), d.nodes);
        try testing.expectEqual(@as(usize, 0), d.unions);
    }
    // The reversed-operand chain is the shape that materializes one
    // transient equivalent node on its *first* visit (the index is not yet
    // re-rooted); after saturation the same forced round must still add
    // nothing.
    {
        var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(add.i32(%B0, %B1), add.i32(%B1, %B0)) }");
        defer f.deinit();
        var it = f.island();
        _ = (try it.encode(f.root())).?;
        try it.saturate();
        try testing.expect(it.stats.converged);
        const d = try forcedRound(&it);
        try testing.expectEqual(@as(isize, 0), d.nodes);
        try testing.expectEqual(@as(usize, 0), d.unions);
    }
}

test "AC bag: {a:2, b:2} materializes the canonical term and re-visits no-op" {
    // `add(add(a,b), add(a,b))`: CSE puts both operands in one class, so
    // the bag is the two-entry `{a:2, b:2}` (`Bag` length counts distinct
    // leaves, not occurrences).
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(add.i32(%B0, %B1), add.i32(%B0, %B1)) }");
    defer f.deinit();
    const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
    var it = f.island();
    const root = (try it.encode(body)).?;
    const add_op = hir.opId("add.i32").?;
    const ty = it.nodes.items[it.acRep(root)].ty;
    var on_path = std.AutoHashMapUnmanaged(Ref, void).empty;
    defer on_path.deinit(it.arena);
    var cut = false;
    var overflow = false;
    const bag = try it.bagOf(add_op, ty, root, &on_path, &cut, &overflow);
    try testing.expect(!cut);
    try testing.expect(!overflow);
    try testing.expectEqual(@as(usize, 2), bag.len);
    try testing.expectEqual(@as(u64, 2), bag[0].count);
    try testing.expectEqual(@as(u64, 2), bag[1].count);
    try testing.expectEqual(@as(u64, 4), Island.bagTotal(bag));
    // The first build interns the canonical term; an identical second build
    // appends nothing because every segment is looked up first.
    const n = it.nodes.items[it.acRep(root)];
    const built1 = (try it.buildCanonical(n, bag)).?;
    const after_first = it.nodes.items.len;
    const built2 = (try it.buildCanonical(n, bag)).?;
    try testing.expectEqual(built1.node, built2.node);
    try testing.expectEqual(after_first, it.nodes.items.len);
}

test "AC bag: a count-4 run shares its (x+x) middle" {
    // `((x + x) + x) + x` flattens to `{x:4}`; the canonical run is
    // `(x+x)+(x+x)` with the middle built once (both operands one class).
    var f = try fixture(i32ty, "fn (B0: i32) { add.i32(add.i32(add.i32(%B0, %B0), %B0), %B0) }");
    defer f.deinit();
    const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
    var it = f.island();
    const root = (try it.encode(body)).?;
    try it.saturate();
    try testing.expect(it.stats.converged);
    const nd = it.nodes.items[it.chosen(root)];
    try testing.expectEqualStrings("add.i32", hir.registry.get(nd.op).name);
    try testing.expectEqual(@as(usize, 2), nd.operands.len);
    try testing.expectEqual(it.find(nd.operands[0]), it.find(nd.operands[1]));
    const d = try forcedRound(&it);
    try testing.expectEqual(@as(isize, 0), d.nodes);
    try testing.expectEqual(@as(usize, 0), d.unions);
}

test "AC bag: a cyclic AC class terminates" {
    // Force a cycle by merging the add class with one of its own operand
    // classes, so expanding the add reaches itself. The on-path guard must
    // treat the back-edge as a leaf and finish.
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(%B0, %B1) }");
    defer f.deinit();
    const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
    var it = f.island();
    const root = (try it.encode(body)).?;
    const operand_cls = it.find(it.nodes.items[it.acRep(root)].operands[0]);
    _ = try it.unionRoots(root, operand_cls);
    try it.saturate();
    try testing.expect(it.stats.converged);
}

/// Source of a right-associated `add.i32(%B0, add.i32(%B1, … %B{n-1}))`
/// chain of `n` distinct leaves — the association `buildCanonical`
/// reshapes, so the rule cannot take the `acChainCanonical` shortcut and
/// really does flatten the whole chain.
fn rightChainText(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var expr = try std.fmt.allocPrint(allocator, "%B{d}", .{n - 1});
    var i = n - 1;
    while (i > 0) {
        i -= 1;
        const next = try std.fmt.allocPrint(allocator, "add.i32(%B{d}, {s})", .{ i, expr });
        allocator.free(expr);
        expr = next;
    }
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    for (0..n) |k| {
        if (k > 0) try params.appendSlice(allocator, ", ");
        const p = try std.fmt.allocPrint(allocator, "B{d}: i32", .{k});
        defer allocator.free(p);
        try params.appendSlice(allocator, p);
    }
    const text = try std.fmt.allocPrint(allocator, "fn ({s}) {{ {s} }}", .{ params.items, expr });
    allocator.free(expr);
    return text;
}

test "AC: a wide distinct-leaf chain flattens in near-linear work" {
    // A quadratic flatten copies Σ depth = O(N²) accumulator entries to
    // build the leaf multiset (the old left-fold `bagUnion`). The
    // single-use/shared split appends O(N): each leaf is inlined once into
    // the maximal node's accumulator. 120 → 240 is the scaling guard: both
    // must stay a small multiple of N, so an accidental return to
    // per-merge copying (which would quadruple) fails here.
    inline for ([_]usize{ 120, 240 }) |n| {
        const text = try rightChainText(testing.allocator, n);
        defer testing.allocator.free(text);
        var f = try fixture(i32ty, text);
        defer f.deinit();
        var it = f.island();
        _ = (try it.encode(f.root())).?;
        try it.saturate();
        try testing.expect(it.stats.converged);
        // Non-vacuous: the right-deep source really was regrouped.
        try testing.expect(it.stats.assoc > 0);
        // 2N in practice (one append per leaf); 4N leaves headroom while
        // still failing the old Σ depth = O(N²) left fold.
        try testing.expect(it.ac_flatten_appends <= 4 * n);
    }
}

test "AC scheduler: per-op signature keys and exact-bag unions" {
    // (a) A fold-merged class holds both an `add` and a `mul` e-node:
    // `mul(add(a,b), 1)` folds through `integerAlgebra` `.keep` and
    // `redirectToClass` merges the `mul` class into the `add` class. `acSig`
    // keys its memo on `(class root, op, ty)`, so each op gets its own
    // signature; keying on the root alone let whichever op was visited
    // first serve the other the wrong fingerprint (scheduling-only, but
    // wrong). This pins both visit orders.
    {
        var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { mul.i32(add.i32(%B0, %B1), 1i32) }");
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const add_expr = pr.operands(body)[0];
        var it = f.island();
        _ = (try it.encode(f.root())).?;
        try it.saturate();
        try testing.expect(it.stats.converged);
        try testing.expect(it.stats.algebra > 0);

        // The merged class really holds both source ops.
        const cls = it.classOfOrigin(body).?;
        var add_nid: ?NodeId = null;
        var mul_nid: ?NodeId = null;
        for (it.classes.items[cls].members.items) |m| {
            if (it.nodes.items[m].origin) |o| {
                if (o == add_expr) add_nid = m;
                if (o == body) mul_nid = m;
            }
        }
        try testing.expect(add_nid != null and mul_nid != null);

        // Per-op fingerprints under one class, computed in both orders over
        // fresh memos. The add node is the two-leaf multiset; the mul node's
        // operand is the merged class itself, a cycle whose signature is
        // null. A root-only key returns the add signature for the mul node
        // in one order and null for the add in the other, so the equalities
        // below fail both ways.
        var memo1 = std.AutoHashMapUnmanaged(u128, ?u128).empty;
        defer memo1.deinit(it.arena);
        var path1 = std.AutoHashMapUnmanaged(Ref, void).empty;
        defer path1.deinit(it.arena);
        const add_first = try it.acSig(add_nid.?, &memo1, &path1);
        const mul_second = try it.acSig(mul_nid.?, &memo1, &path1);

        var memo2 = std.AutoHashMapUnmanaged(u128, ?u128).empty;
        defer memo2.deinit(it.arena);
        var path2 = std.AutoHashMapUnmanaged(Ref, void).empty;
        defer path2.deinit(it.arena);
        const mul_first = try it.acSig(mul_nid.?, &memo2, &path2);
        const add_second = try it.acSig(add_nid.?, &memo2, &path2);

        try testing.expect(add_first != null);
        try testing.expectEqual(add_first, add_second);
        try testing.expect(mul_first == null);
        try testing.expectEqual(mul_first, mul_second);
    }

    // (b) The fingerprint only schedules: `planAcWork` alone changes no
    // class structure. The union that later lands comes from
    // `ruleAcRegroup`'s exact `bagOf` path, and the two source classes'
    // bags are equal before the merge — that is the union's justification,
    // so a fingerprint collision could add scheduling work but could not
    // merge differing multisets. `assoc` counts exactly the landed
    // redirects (one `ac_root` node per landed rule).
    {
        const text = "fn (B0: i32, B1: i32, B2: i32) { add.i32(add.i32(add.i32(%B0, %B1), %B2), add.i32(%B0, add.i32(%B1, %B2))) }";
        var f = try fixture(i32ty, text);
        defer f.deinit();
        const pr = f.pr();
        const body = pr.region(pr.regionsOf(f.root())[0]).root;
        const left = pr.operands(body)[0];
        const right = pr.operands(body)[1];
        var it = f.island();
        _ = (try it.encode(f.root())).?;
        const add_op = hir.opId("add.i32").?;
        const ty = it.nodes.items[it.acRep(it.classOfOrigin(left).?)].ty;

        const left_cls = it.classOfOrigin(left).?;
        const right_cls = it.classOfOrigin(right).?;
        try testing.expect(left_cls != right_cls);
        // The exact bags match and each is the three-leaf multiset.
        var cut_l = false;
        var overflow_l = false;
        var path_l = std.AutoHashMapUnmanaged(Ref, void).empty;
        defer path_l.deinit(it.arena);
        const bag_l = try it.bagOf(add_op, ty, left_cls, &path_l, &cut_l, &overflow_l);
        var cut_r = false;
        var overflow_r = false;
        var path_r = std.AutoHashMapUnmanaged(Ref, void).empty;
        defer path_r.deinit(it.arena);
        const bag_r = try it.bagOf(add_op, ty, right_cls, &path_r, &cut_r, &overflow_r);
        try testing.expect(!cut_l and !cut_r and !overflow_l and !overflow_r);
        try testing.expectEqual(@as(u64, 3), Island.bagTotal(bag_l));
        try testing.expectEqual(@as(u64, 3), Island.bagTotal(bag_r));
        try testing.expectEqual(bag_l.len, bag_r.len);
        for (bag_l, bag_r) |a, b| {
            try testing.expectEqual(a.cls, b.cls);
            try testing.expectEqual(a.count, b.count);
        }

        // Planning schedules; it never unions.
        try it.planAcWork();
        try testing.expectEqual(@as(usize, 0), it.stats.assoc);
        try testing.expectEqual(@as(usize, 0), it.stats.unions);
        try testing.expect(it.classOfOrigin(left).? != it.classOfOrigin(right).?);

        try it.saturate();
        try testing.expect(it.stats.converged);
        try testing.expect(it.stats.assoc > 0);
        try testing.expectEqual(it.classOfOrigin(left).?, it.classOfOrigin(right).?);
        var ac_roots: usize = 0;
        for (it.nodes.items) |n| {
            if (n.ac_root) ac_roots += 1;
        }
        try testing.expectEqual(it.stats.assoc, ac_roots);
    }
}

test "AC: 0 - x extracts to neg (the .negate identity)" {
    var f = try fixture(i32ty, "fn (B0: i32) { sub.i32(0i32, %B0) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{});
    try testing.expect(result.stats.algebra >= 1);
    try testing.expectEqualStrings("neg.i32", hir.registry.get(pr.node(body).op).name);
}

// ---------------------------------------------------------------------------
// White-box tests: the extraction cost model (item 22)
// ---------------------------------------------------------------------------

test "cost model: the weight ladder is per op class with a node-count fallback" {
    // Atoms, arithmetic, projections and casts are one instruction.
    try testing.expectEqual(@as(u32, 1), CostModel.weight(hir.opId("const").?));
    try testing.expectEqual(@as(u32, 1), CostModel.weight(hir.opId("local").?));
    try testing.expectEqual(@as(u32, 1), CostModel.weight(hir.opId("add.i32").?));
    try testing.expectEqual(@as(u32, 1), CostModel.weight(hir.opId("field_get").?));
    try testing.expectEqual(@as(u32, 1), CostModel.weight(hir.opId("num_cast").?));
    // Construction and control: several instructions behind one node.
    try testing.expectEqual(@as(u32, 2), CostModel.weight(hir.opId("struct_make").?));
    try testing.expectEqual(@as(u32, 2), CostModel.weight(hir.opId("tuple_make").?));
    try testing.expectEqual(@as(u32, 2), CostModel.weight(hir.opId("if").?));
    try testing.expectEqual(@as(u32, 2), CostModel.weight(hir.opId("match").?));
    // A call is the expensive shape.
    try testing.expectEqual(@as(u32, 4), CostModel.weight(hir.opId("call").?));
    // A projection is priced as a read, not as a construction, even though
    // it shares the `.aggregate` class.
    try testing.expect(CostModel.weight(hir.opId("field_get").?) < CostModel.weight(hir.opId("struct_make").?));
    // The fallback: a class the ladder does not name costs one node.
    try testing.expectEqual(@as(u32, 1), CostModel.default_weight);
    try testing.expectEqual(CostModel.default_weight, CostModel.weight(hir.opId("move").?));
}

test "cost model: the reported cost is the selected form's DAG cost" {
    {
        // `add.i32(local, const)`: one node each → 3. The island is the
        // λ body (the λ itself opens the island boundary, and pricing the
        // enclosing λ would add its own weight).
        var f = try fixture(i32ty, "fn (B0: i32) { add.i32(%B0, 1i32) }");
        defer f.deinit();
        const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), f.pr(), f.analysis, body, .{});
        try testing.expectEqual(@as(u64, 3), result.stats.extract_cost);
    }
    {
        // `add(mul(a, b), mul(a, b))`: congruence puts both `mul`s (and
        // both reads of each binder) into one class, and a class is paid
        // for once — 1 add + 1 mul + 1 local + 1 local = 4, not 7. This is
        // the sharing the materialized `let` makes explicit.
        var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(mul.i32(%B0, %B1), mul.i32(%B0, %B1)) }");
        defer f.deinit();
        const body = f.pr().region(f.pr().regionsOf(f.root())[0]).root;
        const result = try optimizeIsland(f.arena.allocator(), f.pr(), f.analysis, body, .{});
        try testing.expectEqual(@as(u64, 4), result.stats.extract_cost);
        try testing.expectEqual(@as(usize, 1), result.stats.materialized);
    }
}

test "cost model: a strictly cheaper member wins over the class's preferred one" {
    // The tie-break is a pure decision over (cost, best, preferred), so it
    // can be pinned directly: `preferred` is `nodes[0]`, a rival is
    // `nodes[1]`.
    var f = try fixture(i32ty, "fn (B0: i32) { add.i32(%B0, 1i32) }");
    defer f.deinit();
    var it = f.island();
    _ = (try it.encode(f.root())).?;
    const cls: Ref = 0;
    const pref = it.classes.items[cls].preferred;
    const rival: NodeId = 1;
    try testing.expect(pref != rival);

    const pref_wins = [_]NodeId{pref};
    const rival_wins = [_]NodeId{rival};
    const ten = [_]u64{10};

    // Strictly cheaper always wins, whatever the class prefers.
    try testing.expect(it.improvesChoice(cls, rival, 5, &ten, &pref_wins));
    try testing.expect(!it.improvesChoice(cls, pref, 11, &ten, &pref_wins));
    // A tie goes to the class's existing preferred member, in both
    // directions.
    try testing.expect(!it.improvesChoice(cls, rival, 10, &ten, &pref_wins));
    try testing.expect(it.improvesChoice(cls, pref, 10, &ten, &rival_wins));
    try testing.expect(!it.improvesChoice(cls, pref, 10, &ten, &pref_wins));
    // With neither side preferred, the lower e-node index wins.
    try testing.expect(it.improvesChoice(cls, rival, 10, &ten, &rival_wins) == false);
    const higher = [_]NodeId{rival + 1};
    try testing.expect(it.improvesChoice(cls, rival, 10, &ten, &higher));
    try testing.expect(!it.improvesChoice(cls, higher[0], 10, &ten, &rival_wins));
}

test "cost model: selection is deterministic and prefers the lower member index on a tie" {
    var f = try fixture(i32ty, "fn (B0: i32, B1: i32) { add.i32(mul.i32(%B0, %B1), mul.i32(%B0, %B1)) }");
    defer f.deinit();
    const pr = f.pr();
    const root = f.root();
    const body = pr.region(pr.regionsOf(root)[0]).root;
    const m0 = pr.operands(body)[0];

    var it = f.island();
    _ = (try it.encode(root)).?;
    // Before saturation the cost model has not run: `chosen` falls back to
    // the rule bookkeeping, which is the pre-cost behaviour.
    try testing.expectEqual(it.classes.items[0].preferred, it.chosen(0));
    try testing.expectEqual(@as(u64, 0), it.chosenCost(0));

    try it.saturate();
    const cls = it.classOfOrigin(m0).?;
    const members = it.classes.items[cls].members.items;
    // Both `mul`s are α-equal members of one class.
    try testing.expectEqual(@as(usize, 2), members.len);
    // Both members are α-equal, so the tie resolves to the lower index —
    // and it does so identically on a second island over the same tree.
    const chosen = it.chosen(cls);
    try testing.expectEqual(@as(NodeId, @min(members[0], members[1])), chosen);
    // `mul(local, local)`: the shared class costs one node per operand plus
    // itself.
    try testing.expectEqual(@as(u64, 3), it.chosenCost(cls));

    var it2 = f.island();
    _ = (try it2.encode(root)).?;
    try it2.saturate();
    try testing.expectEqual(chosen, it2.chosen(it2.classOfOrigin(m0).?));
    try testing.expectEqual(it.chosenCost(cls), it2.chosenCost(it2.classOfOrigin(m0).?));
}

test "cost model: end to end, the least-cost candidate is what extraction emits" {
    // `add.i32(local, 0)` has two candidates in one class: the `add` node
    // (3: itself plus two operands) and the left operand (1). The add-zero
    // rule unions them, and the cost model — not the rule's say-so — is
    // what picks the cheaper one.
    var f = try fixture(i32ty, "fn (B0: i32) { add.i32(%B0, 0i32) }");
    defer f.deinit();
    const pr = f.pr();
    const body = pr.region(pr.regionsOf(f.root())[0]).root;
    try testing.expectEqualStrings("add.i32", hir.registry.get(pr.node(body).op).name);

    const result = try optimizeIsland(f.arena.allocator(), pr, f.analysis, body, .{});
    try testing.expect(result.stats.unions > 0);
    try testing.expectEqual(@as(u64, 1), result.stats.extract_cost);
    try testing.expectEqualStrings("local", hir.registry.get(pr.node(body).op).name);
    try testing.expectEqual(@as(usize, 0), countNodes(pr, body, "add.i32"));
}
