//! Pass: SEG — the *slotted e-graph* arena behind the M2a rule subset
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
//! - **e-nodes** — hash-consed on `(op, structural type hash, payload,
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
//! - **saturate** — bounded rounds of (rules → rebuild), stopping when a
//!   whole round changes nothing. This is a **bounded-round contract, not
//!   a decreasing-measure one**: every admitted rule
//!   preserves semantics, so any round prefix is a correct program and a
//!   bound hit only forfeits further unions. `Stats.converged` reports
//!   which exit was taken.
//! - **extract** — writes the saturated class back into the HIR tree.
//!   The tree is recovered by recursion over classes, not by a hash
//!   table: a class whose preferred e-node is still an original member
//!   (`preferred_prio == 0`) and whose site is one of its members keeps
//!   that site and recurses into the site's own operands / regions —
//!   exact identity, which is what makes a saturated island a fixpoint
//!   instead of fresh churn every round. A redirected class (or a site
//!   that is not a member) gets a *fresh* copy of the preferred e-node,
//!   deep-copied with fresh binders per rebuilt region, so the result is
//!   always a tree (§3.7). A class referenced twice among one
//!   `strict_ltr`, region-free parent's operands materializes into a
//!   synthesized `let` (§8.3's CSE shape); every other repeated
//!   reference is copied, which is exactly the sharing v1's sibling-only
//!   `ruleCse` had.
//!
//! The cost model is deliberately still v1's: a class's preferred e-node,
//! with the lowest e-node index as the deterministic tie-break, and no
//! per-opcode weight until item 22.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const hir_effects = @import("hir_effects.zig");

pub const Error = std.mem.Allocator.Error;

/// A binder slot: the e-graph's canonical binder reference (see the file
/// header). Slots are dense, island-scoped, and assigned on first
/// encounter in encode order.
pub const Slot = u32;

/// An e-class id. Always resolved through `find` before use — the raw id
/// may be a non-root after a union.
const Ref = u32;
/// An e-node id (index into `Island.nodes`).
const NodeId = u32;

/// What one island's saturation did — folded into `hir_seg.Stats`, and
/// the object item 23 extends.
pub const Stats = struct {
    /// Saturation rounds this island ran (a quiet round counts).
    rounds: u64 = 0,
    /// `true` when a round changed nothing (a fixpoint of the rule set
    /// within `Config.max_rounds`); `false` on a bound hit.
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
    folds: usize = 0,
    algebra: usize = 0,
    conds: usize = 0,
    projects: usize = 0,
    /// `let` bindings synthesized for a shared operand class during extraction.
    materialized: usize = 0,
    /// Fresh subtrees written at a site (a redirected class or a non-member
    /// site). Identity extraction writes nothing.
    copied: usize = 0,
    /// Sites whose content was overwritten in place.
    written: usize = 0,
};

pub const Config = struct {
    /// Bound on saturation rounds (the caller's `max_iterations`).
    max_rounds: u32 = 8,
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
    ty: meta.Type,
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
};

/// One e-class: the union-find parent (its own id at the root), the
/// members that were merged into it, and the member extraction follows.
const EClass = struct {
    parent: Ref,
    rank: u32 = 0,
    preferred: NodeId,
    /// 0 = the encode-time original; 1 = a rule chose this member, so
    /// extraction must emit it rather than keep a member site's shape.
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
    max_rounds: u32,

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

    stats: Stats = .{},
    written: std.ArrayList(hir.ExprId) = .empty,

    pub fn init(arena: std.mem.Allocator, pr: *hir.Program, analysis: *hir_effects.Analysis, config: Config) Island {
        return .{ .arena = arena, .pr = pr, .analysis = analysis, .max_rounds = config.max_rounds };
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

    fn addConstNode(self: *Island, ty: meta.Type, value: meta.ConstValue) Error!NodeId {
        return self.addNode(.{
            .op = hir.opId("const").?,
            .ty = ty,
            .payload = .{ .const_value = value },
            .operands = try self.arena.alloc(Ref, 0),
            .regions = try self.arena.alloc(RegionTerm, 0),
            .access_hops = &.{},
            .origin = null,
            .full_expr = self.island_fe,
        });
    }

    /// Hash-cons `nid`: return the class whose content it already equals,
    /// merging when a structurally equal e-node exists elsewhere
    /// (encode-time CSE).
    fn internNode(self: *Island, nid: NodeId) Error!Ref {
        const hash = self.hashNode(nid);
        self.nodes.items[nid].hash = hash;
        const gop = try self.index.getOrPut(self.arena, hash);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |other| {
            if (other == nid) continue;
            if (!self.nodeEql(nid, other)) continue;
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

    fn nodeEql(self: *Island, a: NodeId, b: NodeId) bool {
        const x = self.nodes.items[a];
        const y = self.nodes.items[b];
        if (x.op != y.op) return false;
        if (!meta.Type.eql(x.ty, y.ty)) return false;
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

    fn hashNode(self: *Island, nid: NodeId) u64 {
        const n = self.nodes.items[nid];
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&n.op));
        hashType(&h, n.ty);
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
                hashType(h, tt.ty);
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
                .type_test => |tb| meta.Type.eql(ta.ty, tb.ty) and
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

    /// Bounded-round saturation (hir.md §8.2): rules → congruence close,
    /// repeated until a round changes nothing or the bound is hit.
    pub fn saturate(self: *Island) Error!void {
        var round: u32 = 0;
        while (round < self.max_rounds) : (round += 1) {
            self.stats.rounds += 1;
            var changed = false;
            var i: usize = 0;
            while (i < self.nodes.items.len) : (i += 1) {
                if (try self.applyRules(@intCast(i))) changed = true;
            }
            if (try self.rebuild()) changed = true;
            if (!changed) break;
        } else {
            self.stats.converged = false;
        }
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
            const hash = self.hashNode(nid);
            self.nodes.items[nid].hash = hash;
            const gop = try self.index.getOrPut(self.arena, hash);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            var merged = false;
            for (gop.value_ptr.items) |other| {
                if (other == nid) continue;
                if (!self.nodeEql(nid, other)) continue;
                const ocls = self.find(self.nodes.items[other].cls);
                if (ocls == cls) continue;
                _ = try self.unionRoots(ocls, cls);
                self.stats.merges += 1;
                merged = true;
                break;
            }
            if (!merged) try gop.value_ptr.append(self.arena, nid);
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
        if (d.typed) return self.ruleNumeric(nid);
        const base = baseName(d.name);
        if (std.mem.eql(u8, base, "if") or std.mem.eql(u8, base, "and") or std.mem.eql(u8, base, "or")) {
            return self.ruleConstCond(nid);
        }
        if (std.mem.eql(u8, base, "field_get")) return self.ruleProject(nid);
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

        if (n.operands.len >= 1 and n.operands.len <= 2) {
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
                    const cc = try self.internNode(try self.addConstNode(n.ty, value));
                    if (try self.redirectToClass(cls, cc)) {
                        self.stats.folds += 1;
                        return true;
                    }
                    return false;
                }
            }
        }

        if (n.operands.len == 2 and isIntegerRep(rep)) {
            const lc = self.constIn(n.operands[0]);
            const rc = self.constIn(n.operands[1]);
            const result = integerAlgebra(base, rep, lc, rc) orelse return false;
            switch (result) {
                .keep => |idx| {
                    if (try self.redirectToClass(cls, n.operands[idx])) {
                        self.stats.algebra += 1;
                        return true;
                    }
                },
                .value => |value| {
                    const cc = try self.internNode(try self.addConstNode(n.ty, value));
                    if (try self.redirectToClass(cls, cc)) {
                        self.stats.algebra += 1;
                        return true;
                    }
                },
            }
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
        if (try self.redirectToClass(n.cls, values[idx])) {
            self.stats.projects += 1;
            return true;
        }
        return false;
    }

    /// The constant a class is known to hold, if any member is a `const`.
    fn constIn(self: *Island, cls: Ref) ?meta.ConstValue {
        const root = self.find(cls);
        for (self.classes.items[root].members.items) |m| {
            const n = self.nodes.items[m];
            if (!std.mem.eql(u8, hir.registry.get(n.op).name, "const")) continue;
            return n.payload.const_value;
        }
        return null;
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
        const n = self.nodes.items[self.classes.items[root].preferred];
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
            const pnode = self.nodes.items[self.classes.items[rc].preferred];
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
        var init_ty: []meta.Type = &.{};
        if (plan) |p| {
            init_ids = try self.arena.alloc(hir.ExprId, p.classes.len);
            binders = try self.arena.alloc(hir.BinderId, p.classes.len);
            init_ty = try self.arena.alloc(meta.Type, p.classes.len);
            for (p.classes, 0..) |c, t| {
                const pnode = self.nodes.items[self.classes.items[self.find(c)].preferred];
                init_ty[t] = pnode.ty;
                init_ids[t] = try self.copyClass(c, overlay);
                binders[t] = try self.pr.addBinder(pnode.ty, .value);
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
        const root = self.find(cls);
        const n = self.nodes.items[self.classes.items[root].preferred];
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
            fresh[i] = try self.pr.addBinder(b.ty, b.mode);
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
                const fresh = try self.arena.alloc(hir.PatternId, elems.len);
                for (elems, 0..) |e, i| fresh[i] = try self.copyPattern(e, overlay);
                break :blk .{ .tuple = fresh };
            },
            .list => |lp| blk: {
                const fresh = try self.arena.alloc(hir.PatternId, lp.elems.len);
                for (lp.elems, 0..) |e, i| fresh[i] = try self.copyPattern(e, overlay);
                break :blk .{ .list = .{
                    .elems = fresh,
                    .rest = if (lp.rest) |r| try self.copyPattern(r, overlay) else null,
                } };
            },
            .struct_ => |sp| blk: {
                const fresh = try self.arena.alloc(hir.Pattern.FieldPattern, sp.fields.len);
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

    fn addLocalNode(self: *Island, binder: hir.BinderId, ty: meta.Type, fe: hir.FullExprId) Error!hir.ExprId {
        return self.pr.addExpr(.{
            .op = hir.opId("local").?,
            .ty = ty,
            .payload = .{ .binder = binder },
            .full_expr = fe,
            .sema = try self.pr.internSema(.owned, .pending),
        });
    }

    fn makeLet(self: *Island, binder: hir.BinderId, init_id: hir.ExprId, body: hir.ExprId, ty: meta.Type, fe: hir.FullExprId) Error!hir.ExprId {
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

fn hashType(h: *std.hash.Wyhash, ty: meta.Type) void {
    switch (ty) {
        .primitive => |k| {
            h.update(&[_]u8{1});
            h.update(std.mem.asBytes(&@as(u32, @intFromEnum(k))));
        },
        .named => |n| {
            h.update(&[_]u8{2});
            h.update(std.mem.asBytes(&n.id));
            for (n.args) |a| hashType(h, a);
        },
        .param => |p| {
            h.update(&[_]u8{3});
            h.update(p);
        },
        .module => h.update(&[_]u8{4}),
        .list => |inner| {
            h.update(&[_]u8{5});
            hashType(h, inner.*);
        },
        .box => |inner| {
            h.update(&[_]u8{6});
            hashType(h, inner.*);
        },
        .tuple => |elems| {
            h.update(&[_]u8{7});
            for (elems) |e| hashType(h, e);
        },
        .function => |f| {
            h.update(&[_]u8{8});
            for (f.params) |p| {
                h.update(std.mem.asBytes(&@as(u32, @intFromEnum(p.mode))));
                hashType(h, p.type_);
            }
            hashType(h, f.ret.*);
        },
        .cleanup => h.update(&[_]u8{9}),
    }
}

fn hashConst(h: *std.hash.Wyhash, c: meta.ConstValue) void {
    switch (c) {
        .int => |v| {
            h.update(&[_]u8{1});
            h.update(std.mem.asBytes(&v));
        },
        .float => |v| {
            h.update(&[_]u8{2});
            h.update(std.mem.asBytes(&v));
        },
        .bool => |v| {
            h.update(&[_]u8{3});
            h.update(&[_]u8{@intFromBool(v)});
        },
        .string => |v| {
            h.update(&[_]u8{4});
            h.update(v);
        },
        .void => h.update(&[_]u8{5}),
    }
}

fn hashPayload(h: *std.hash.Wyhash, p: hir.Payload) void {
    switch (p) {
        .none => h.update(&[_]u8{0}),
        .const_value => |c| {
            h.update(&[_]u8{1});
            hashConst(h, c);
        },
        // The `binder` field holds a normalized Slot for an encoded `local`.
        .binder => |b| {
            h.update(&[_]u8{2});
            h.update(std.mem.asBytes(&b));
        },
        .func => |f| {
            h.update(&[_]u8{3});
            switch (f) {
                .func => |v| {
                    h.update(&[_]u8{0});
                    h.update(std.mem.asBytes(&v));
                },
                .host => |v| {
                    h.update(&[_]u8{1});
                    h.update(std.mem.asBytes(&v));
                },
            }
        },
        .module_const => |c| {
            h.update(&[_]u8{4});
            h.update(std.mem.asBytes(&c));
        },
        .field => |v| {
            h.update(&[_]u8{5});
            h.update(std.mem.asBytes(&v));
        },
        .tag => |v| {
            h.update(&[_]u8{6});
            h.update(std.mem.asBytes(&v));
        },
    }
}

fn hashHops(h: *std.hash.Wyhash, hops: []const hir.AccessHop) void {
    for (hops) |hop| {
        h.update(std.mem.asBytes(&hop.module));
        h.update(hop.name);
    }
}

fn payloadEql(a: hir.Payload, b: hir.Payload) bool {
    return switch (a) {
        .none => b == .none,
        .const_value => |ca| switch (b) {
            .const_value => |cb| constEql(ca, cb),
            else => false,
        },
        .binder => |ba| switch (b) {
            .binder => |bb| ba == bb,
            else => false,
        },
        .func => |fa| switch (b) {
            .func => |fb| std.meta.eql(fa, fb),
            else => false,
        },
        .module_const => |ca| switch (b) {
            .module_const => |cb| ca == cb,
            else => false,
        },
        .field => |fa| switch (b) {
            .field => |fb| fa == fb,
            else => false,
        },
        .tag => |ta| switch (b) {
            .tag => |tb| ta == tb,
            else => false,
        },
    };
}

/// Conservative `ConstValue` equality: strings by contents; floats by `==`
/// (a NaN pair compares unequal — a missed merge, never a wrong one).
fn constEql(a: meta.ConstValue, b: meta.ConstValue) bool {
    return switch (a) {
        .int => |ia| switch (b) {
            .int => |ib| ia == ib,
            else => false,
        },
        .float => |fa| switch (b) {
            .float => |fb| fa == fb,
            else => false,
        },
        .bool => |ba| switch (b) {
            .bool => |bb| ba == bb,
            else => false,
        },
        .string => |sa| switch (b) {
            .string => |sb| std.mem.eql(u8, sa, sb),
            else => false,
        },
        .void => b == .void,
    };
}

fn hopsEql(a: []const hir.AccessHop, b: []const hir.AccessHop) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.module != y.module) return false;
        if (!std.mem.eql(u8, x.name, y.name)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Rule predicates
// ---------------------------------------------------------------------------

fn baseName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

fn isCtorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "struct_make") or
        std.mem.eql(u8, name, "tuple_make") or
        std.mem.eql(u8, name, "list_make");
}

fn isTrivialAtomNode(op: hir.OpId) bool {
    const name = hir.registry.get(op).name;
    return std.mem.eql(u8, name, "const") or
        std.mem.eql(u8, name, "local") or
        std.mem.eql(u8, name, "fn_ref");
}

fn isIntegerRep(rep: hir.ScalarRep) bool {
    return switch (rep) {
        .i32, .i64, .u32, .u64 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Constant folding (mirrors cfg_lower_emit's runtime semantics, extended to
// the 64-bit and float reps the HIR registers). A fold that could trap is
// refused: the runtime owns the trap.
// ---------------------------------------------------------------------------

fn foldUnary(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue) ?meta.ConstValue {
    if (std.mem.eql(u8, base, "neg")) {
        return switch (rep) {
            .i32 => intCV(i32, -%(asInt(i32, a) orelse return null)),
            .i64 => intCV(i64, -%(asInt(i64, a) orelse return null)),
            .u32 => intCV(u32, 0 -% (asInt(u32, a) orelse return null)),
            .u64 => intCV(u64, 0 -% (asInt(u64, a) orelse return null)),
            .f32 => floatCV(f32, -@as(f32, @floatCast(asF64(a) orelse return null))),
            .f64 => floatCV(f64, -(asF64(a) orelse return null)),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "abs")) {
        return switch (rep) {
            .i32 => blk: {
                const x = asInt(i32, a) orelse return null;
                break :blk intCV(i32, if (x < 0) -%x else x);
            },
            .i64 => blk: {
                const x = asInt(i64, a) orelse return null;
                break :blk intCV(i64, if (x < 0) -%x else x);
            },
            .f32 => floatCV(f32, @abs(@as(f32, @floatCast(asF64(a) orelse return null)))),
            .f64 => floatCV(f64, @abs(asF64(a) orelse return null)),
            else => null, // no unsigned abs (CFG leaves it unfolded too)
        };
    }
    if (std.mem.eql(u8, base, "not")) {
        return switch (a) {
            .bool => |v| .{ .bool = !v },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "clz")) {
        return switch (rep) {
            .i32 => .{ .int = @clz(@as(u32, @bitCast(asInt(i32, a) orelse return null))) },
            .u32 => .{ .int = @clz(asInt(u32, a) orelse return null) },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "popcount")) {
        return switch (rep) {
            .i32 => .{ .int = @popCount(@as(u32, @bitCast(asInt(i32, a) orelse return null))) },
            .u32 => .{ .int = @popCount(asInt(u32, a) orelse return null) },
            else => null,
        };
    }
    return null;
}

fn foldBinary(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    if (std.mem.eql(u8, base, "add") or std.mem.eql(u8, base, "sub") or
        std.mem.eql(u8, base, "mul") or std.mem.eql(u8, base, "div") or std.mem.eql(u8, base, "rem"))
    {
        return switch (rep) {
            .i32 => intArith(i32, base, a, b),
            .i64 => intArith(i64, base, a, b),
            .u32 => intArith(u32, base, a, b),
            .u64 => intArith(u64, base, a, b),
            .f32 => floatArith(f32, base, a, b),
            .f64 => floatArith(f64, base, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "min") or std.mem.eql(u8, base, "max")) {
        const is_min = std.mem.eql(u8, base, "min");
        return switch (rep) {
            .i32 => blk: {
                const x = asInt(i32, a) orelse return null;
                const y = asInt(i32, b) orelse return null;
                break :blk intCV(i32, if (is_min) @min(x, y) else @max(x, y));
            },
            .u32 => blk: {
                const x = asInt(u32, a) orelse return null;
                const y = asInt(u32, b) orelse return null;
                break :blk intCV(u32, if (is_min) @min(x, y) else @max(x, y));
            },
            .f32 => blk: {
                const x: f32 = @floatCast(asF64(a) orelse return null);
                const y: f32 = @floatCast(asF64(b) orelse return null);
                break :blk floatCV(f32, if (is_min) fminIeee(f32, x, y) else fmaxIeee(f32, x, y));
            },
            .f64 => blk: {
                const x = asF64(a) orelse return null;
                const y = asF64(b) orelse return null;
                break :blk floatCV(f64, if (is_min) fminIeee(f64, x, y) else fmaxIeee(f64, x, y));
            },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr")) {
        const is_shl = std.mem.eql(u8, base, "shl");
        return switch (rep) {
            .i32 => intShift(i32, is_shl, a, b),
            .i64 => intShift(i64, is_shl, a, b),
            .u32 => intShift(u32, is_shl, a, b),
            .u64 => intShift(u64, is_shl, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "band") or std.mem.eql(u8, base, "bor") or std.mem.eql(u8, base, "bxor")) {
        return switch (rep) {
            .i32 => intBit(i32, base, a, b),
            .i64 => intBit(i64, base, a, b),
            .u32 => intBit(u32, base, a, b),
            .u64 => intBit(u64, base, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "eq") or std.mem.eql(u8, base, "ne") or
        std.mem.eql(u8, base, "lt") or std.mem.eql(u8, base, "le") or
        std.mem.eql(u8, base, "gt") or std.mem.eql(u8, base, "ge"))
    {
        return cmpResult(base, rep, a, b);
    }
    return null;
}

fn cmpResult(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const eq = std.mem.eql(u8, base, "eq");
    const ne = std.mem.eql(u8, base, "ne");
    const eq_style = eq or ne;
    const r: bool = switch (rep) {
        .i32 => cmpInt(i32, base, a, b) orelse return null,
        .i64 => cmpInt(i64, base, a, b) orelse return null,
        .u32 => cmpInt(u32, base, a, b) orelse return null,
        .u64 => cmpInt(u64, base, a, b) orelse return null,
        .f32, .f64 => cmpFloat(base, a, b) orelse return null,
        .bool => blk: {
            if (!eq_style) return null;
            const x = asBool(a) orelse return null;
            const y = asBool(b) orelse return null;
            break :blk if (eq) x == y else x != y;
        },
        .str => blk: {
            if (!eq_style) return null;
            const x = asStr(a) orelse return null;
            const y = asStr(b) orelse return null;
            break :blk if (eq) std.mem.eql(u8, x, y) else !std.mem.eql(u8, x, y);
        },
        // `byte` comparisons lower through the u32 family (hir.md §7.2
        // M1a note); the value occupies one host cell, compared unsigned.
        .byte => blk: {
            const x = asInt(u8, a) orelse return null;
            const y = asInt(u8, b) orelse return null;
            if (eq) break :blk x == y;
            if (ne) break :blk x != y;
            if (std.mem.eql(u8, base, "lt")) break :blk x < y;
            if (std.mem.eql(u8, base, "le")) break :blk x <= y;
            if (std.mem.eql(u8, base, "gt")) break :blk x > y;
            break :blk x >= y;
        },
    };
    return .{ .bool = r };
}

fn cmpInt(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?bool {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "eq")) return x == y;
    if (std.mem.eql(u8, base, "ne")) return x != y;
    if (std.mem.eql(u8, base, "lt")) return x < y;
    if (std.mem.eql(u8, base, "le")) return x <= y;
    if (std.mem.eql(u8, base, "gt")) return x > y;
    if (std.mem.eql(u8, base, "ge")) return x >= y;
    return null;
}

fn cmpFloat(base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?bool {
    const x = asF64(a) orelse return null;
    const y = asF64(b) orelse return null;
    if (std.mem.eql(u8, base, "eq")) return x == y;
    if (std.mem.eql(u8, base, "ne")) return x != y;
    if (std.mem.eql(u8, base, "lt")) return x < y;
    if (std.mem.eql(u8, base, "le")) return x <= y;
    if (std.mem.eql(u8, base, "gt")) return x > y;
    if (std.mem.eql(u8, base, "ge")) return x >= y;
    return null;
}

fn intArith(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "add")) return intCV(T, x +% y);
    if (std.mem.eql(u8, base, "sub")) return intCV(T, x -% y);
    if (std.mem.eql(u8, base, "mul")) return intCV(T, x *% y);
    if (y == 0) return null; // division/remainder by zero traps — leave it
    if (comptime @typeInfo(T).int.signedness == .signed) {
        if (x == std.math.minInt(T) and y == -1) {
            // `min / -1` traps for `div`; `min % -1` is exactly 0.
            if (std.mem.eql(u8, base, "div")) return null;
            return intCV(T, 0);
        }
    }
    if (std.mem.eql(u8, base, "div")) return intCV(T, @divTrunc(x, y));
    return intCV(T, @rem(x, y));
}

fn intShift(comptime T: type, is_shl: bool, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const bits = @typeInfo(T).int.bits;
    const U = std.meta.Int(.unsigned, bits);
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    const s: std.math.Log2Int(T) = @intCast(@as(U, @bitCast(y)) & (bits - 1));
    if (is_shl) return intCV(T, @bitCast(@as(U, @bitCast(x)) << s));
    return intCV(T, x >> s);
}

fn intBit(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "band")) return intCV(T, x & y);
    if (std.mem.eql(u8, base, "bor")) return intCV(T, x | y);
    return intCV(T, x ^ y);
}

fn floatArith(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asF64(a) orelse return null;
    const y = asF64(b) orelse return null;
    if (std.mem.eql(u8, base, "add")) return floatCV(T, @as(T, @floatCast(x)) + @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "sub")) return floatCV(T, @as(T, @floatCast(x)) - @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "mul")) return floatCV(T, @as(T, @floatCast(x)) * @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "div")) return floatCV(T, @as(T, @floatCast(x)) / @as(T, @floatCast(y)));
    // Zig `@rem` on floats is the truncated remainder (fmod).
    return floatCV(T, @rem(@as(T, @floatCast(x)), @as(T, @floatCast(y))));
}

// --- constant-value helpers (meta.ConstValue keeps integers as i64 bit
// patterns) ---------------------------------------------------------------

fn asInt(comptime T: type, c: meta.ConstValue) ?T {
    const U = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
    return switch (c) {
        .int => |i| @bitCast(@as(U, @truncate(@as(u64, @bitCast(i))))),
        else => null,
    };
}

fn asF64(c: meta.ConstValue) ?f64 {
    return switch (c) {
        .float => |f| f,
        else => null,
    };
}

fn asBool(c: meta.ConstValue) ?bool {
    return switch (c) {
        .bool => |b| b,
        else => null,
    };
}

fn asStr(c: meta.ConstValue) ?[]const u8 {
    return switch (c) {
        .string => |s| s,
        else => null,
    };
}

fn intCV(comptime T: type, v: T) meta.ConstValue {
    if (comptime @typeInfo(T).int.signedness == .signed) {
        return .{ .int = v };
    } else {
        return .{ .int = @bitCast(@as(u64, v)) };
    }
}

fn floatCV(comptime T: type, v: T) meta.ConstValue {
    return .{ .float = @floatCast(v) };
}

/// IEEE 754 `fmin`: NaN propagates, `fmin(-0, +0) = -0` (mirrors
/// cfg_lower_emit).
fn fminIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

fn fmaxIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(b)) a else b;
    return if (a > b) a else b;
}

// ---------------------------------------------------------------------------
// Integer algebra identities
// ---------------------------------------------------------------------------

const AlgebraResult = union(enum) {
    /// Keep operand `keep` (0 or 1) as the result.
    keep: usize,
    /// The result is this constant (drops both operands).
    value: meta.ConstValue,
};

fn integerAlgebra(base: []const u8, rep: hir.ScalarRep, lc: ?meta.ConstValue, rc: ?meta.ConstValue) ?AlgebraResult {
    return switch (rep) {
        .i32 => intAlgebraT(i32, base, lc, rc),
        .i64 => intAlgebraT(i64, base, lc, rc),
        .u32 => intAlgebraT(u32, base, lc, rc),
        .u64 => intAlgebraT(u64, base, lc, rc),
        else => null,
    };
}

fn intAlgebraT(comptime T: type, base: []const u8, lc: ?meta.ConstValue, rc: ?meta.ConstValue) ?AlgebraResult {
    const lz = if (lc) |c| (asInt(T, c) orelse return null) == 0 else false;
    const rz = if (rc) |c| (asInt(T, c) orelse return null) == 0 else false;
    const lo = if (lc) |c| (asInt(T, c) orelse return null) == 1 else false;
    const ro = if (rc) |c| (asInt(T, c) orelse return null) == 1 else false;
    const lall = if (lc) |c| (asInt(T, c) orelse return null) == ~@as(T, 0) else false;
    const rall = if (rc) |c| (asInt(T, c) orelse return null) == ~@as(T, 0) else false;

    if (std.mem.eql(u8, base, "add")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "sub")) {
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "mul")) {
        if (lo) return .{ .keep = 1 };
        if (ro) return .{ .keep = 0 };
        if (lz or rz) return .{ .value = intCV(T, 0) };
    } else if (std.mem.eql(u8, base, "band")) {
        if (lall) return .{ .keep = 1 };
        if (rall) return .{ .keep = 0 };
        if (lz or rz) return .{ .value = intCV(T, 0) };
    } else if (std.mem.eql(u8, base, "bor")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
        if (lall) return .{ .value = intCV(T, ~@as(T, 0)) };
        if (rall) return .{ .value = intCV(T, ~@as(T, 0)) };
    } else if (std.mem.eql(u8, base, "bxor")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr")) {
        if (rz) return .{ .keep = 0 };
    }
    return null;
}

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
        .params = try a.alloc(meta.Param, 0),
        .ret = ret,
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
    try testing.expectEqual(@as(usize, 1), countNodes(pr, root, "mul.i32"));
    try testing.expectEqual(@as(usize, 4), countNodes(pr, root, "local"));
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
        try testing.expect(result.stats.enodes > 0);
        try testing.expectEqualStrings("field_get", hir.registry.get(pr.node(site).op).name);
    }
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
