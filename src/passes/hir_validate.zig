//! Pass: structural HIR validator — hir.md §10.1, M1a first level.
//! In: one root expression of a `hir.Program`. Out: null when the
//! reachable tree satisfies the invariants, or a human-readable
//! first-violation message.
//!
//! This is the structural level only: **no ownership dataflow and no SEG
//! checks here**. The M1b effect level (every reachable node carries a
//! `ready` summary that soundly over-approximates `effect_transfer`, and
//! every `sema` id is in range) is a separate pass —
//! `passes/hir_effects.zig` (`Analysis.validate`), run by the frontend
//! right after this one (hir.md §10.1 level two). What is enforced here,
//! in order (spec references in the messages):
//!
//! - **Bounds** — every expr/region/binder/pattern id and every operand /
//!   region / param range is checked *before* the indexed access, so the
//!   validator never crashes on a malformed arena.
//! - **Tree, no DAG** (hir.md §3.7) — the walk from the root visits each
//!   expr exactly once; a second occurrence (shared operand, shared
//!   subtree, or a cycle back to an ancestor) is rejected. Regions have
//!   exactly one owning node. Patterns may be shared between arms, but
//!   pattern cycles are rejected (a pattern tree must terminate).
//! - **Registry** — op ids in range; operand / region counts match the
//!   `OpDescriptor` shape (hir.md §4.4/§5.5); payload kind pairs with the
//!   opcode (`.const_value` on `const`, `.binder` on `local`, `.func` on
//!   `fn_ref`, `.module_const` on `module_const`, `.field` on
//!   `field_get`, `.tag` on `variant_make`; everything else `.none`).
//! - **Scope** (hir.md §5.3) — a `local` binder reference resolves along
//!   the lexical region ancestry and must not cross a function boundary:
//!   a λ region's body sees its own params and inner regions only, never
//!   an outer function's locals (no capture). Because the walk evaluates
//!   a node's operands in the region that *contains* the node and enters
//!   a region's params only inside that region's root, `let` init
//!   exclusion falls out structurally (the init cannot see the binder it
//!   defines).
//! - **Region/pattern shape** — let regions carry exactly one binder, if
//!   regions none, patterns appear only on match arms; a match arm's
//!   pattern binding leaves must be a bijection onto the arm region's
//!   params (hir.md §5.4), and a patternless arm has no params. Each
//!   BinderId is declared (is a param) in at most one region.
//! - **Annotation bounds** — `full_expr` / `sema` ids are valid indices.
//!   Membership only: `FullExpr` is an identity record in M1a (S2/S4
//!   annotate FE 0 or fresh boundaries) — the validator does **not**
//!   check lifetime boundaries, cleanup-registration ordering, or
//!   cross-boundary rewrites, which are SEG/lowering-level concerns.
//!
//! `validate` walks the tree reachable from one root and does not
//! require every arena entry to be reachable (a builder may leave
//! abandoned nodes behind). S4 will validate each function root with
//! this same entry point.

const std = @import("std");
const hir = @import("stilla").hir;
// Test fixtures build cfg nominal decls (module graph stand-in).
const meta = @import("stilla").meta;

const lambda_op = hir.opId("lambda").?;
const let_op = hir.opId("let").?;
const if_op = hir.opId("if").?;
const and_op = hir.opId("and").?;
const or_op = hir.opId("or").?;
const match_op = hir.opId("match").?;

/// Validate the tree reachable from `root`. Returns null when valid,
/// otherwise a first-violation message allocated from `allocator` and
/// owned by the caller (cfg_validate convention): free it with
/// `allocator`, or pass an arena and let the arena free it.
///
/// Scratch state (marks, worklist) lives in a child arena freed before
/// this returns — only the message escapes, from `allocator`. The
/// expr/region walk is iterative (unbounded arena depth is safe);
/// pattern subtrees are depth-capped (see `checkPatternTree`) so a
/// crafted chain fails with a diagnostic instead of overflowing the
/// stack.
pub fn validate(program: *const hir.Program, root: hir.ExprId, allocator: std.mem.Allocator) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var v = Validator{
        .program = program,
        .arena = a,
        .diag = allocator,
        .expr_done = try a.alloc(bool, program.exprs.items.len),
        .region_done = try a.alloc(bool, program.regions.items.len),
        .pat_state = try a.alloc(u8, program.patterns.items.len),
        .binder_owner = try a.alloc(hir.RegionId, program.binders.items.len),
        .parent_region = try a.alloc(?hir.RegionId, program.regions.items.len),
        .owner_op = try a.alloc(hir.OpId, program.regions.items.len),
        .work = .empty,
    };
    @memset(v.expr_done, false);
    @memset(v.region_done, false);
    @memset(v.pat_state, 0);
    @memset(v.binder_owner, no_region);
    @memset(v.parent_region, null);
    @memset(v.owner_op, 0);

    try v.work.append(a, .{ .expr = .{ .id = root, .ctx = null } });
    while (v.work.pop()) |item| {
        const msg = switch (item) {
            .expr => |fr| try v.checkExpr(fr),
            .region => |fr| try v.checkRegion(fr),
        };
        if (msg) |m| return m;
    }
    return null;
}

/// Region-id sentinel for "no region" (binder declared nowhere yet).
const no_region: hir.RegionId = std.math.maxInt(hir.RegionId);

/// Pattern nesting cap for the recursive pattern walk (see
/// `checkPatternTree`): source pattern depth is tiny; only a crafted
/// arena can approach this.
const pattern_depth_cap: u32 = 4096;

const Validator = struct {
    program: *const hir.Program,
    /// Scratch allocator (child arena, freed at validate()'s return).
    arena: std.mem.Allocator,
    /// The caller's allocator — where the returned diagnostic is
    /// allocated, so the message outlives the scratch arena.
    diag: std.mem.Allocator,

    // Marks, sized to the arenas at validate() time.
    expr_done: []bool,
    region_done: []bool,
    /// 0 = unseen, 1 = in progress (cycle guard), 2 = done (may be
    /// shared between arms; done subtrees are skipped).
    pat_state: []u8,
    /// The one region a binder is a param of (no_region = none).
    binder_owner: []hir.RegionId,
    /// Lexical parent of each region (recorded when it is entered).
    parent_region: []?hir.RegionId,
    /// Op of the node that owns each region (λ ⇒ function boundary).
    owner_op: []hir.OpId,
    work: std.ArrayListUnmanaged(Work) = .empty,

    const Work = union(enum) {
        expr: ExprFrame,
        region: RegionFrame,
    };
    const ExprFrame = struct {
        id: hir.ExprId,
        /// Innermost region whose subtree contains this expr (null at
        /// the root: operands of a top-level node see no binders).
        ctx: ?hir.RegionId,
    };
    const RegionFrame = struct {
        id: hir.RegionId,
        owner: hir.OpId,
        parent: ?hir.RegionId,
    };

    // -- reporting ----------------------------------------------------------

    fn fail(self: *const Validator, comptime fmt: []const u8, args: anytype) !?[]const u8 {
        // Allocate from the *caller's* allocator, never from the scratch
        // arena: the scratch arena is freed before the caller reads the
        // returned message. A plain value may be implicitly wrapped into
        // the optional payload on return; an error union may not.
        const msg = try std.fmt.allocPrint(self.diag, fmt, args);
        return msg;
    }

    fn opName(self: *const Validator, op: hir.OpId) []const u8 {
        _ = self;
        return hir.op_descriptors[op].name;
    }

    // -- expr ---------------------------------------------------------------

    fn checkExpr(self: *Validator, fr: ExprFrame) !?[]const u8 {
        const n_exprs = self.program.exprs.items.len;
        if (fr.id >= n_exprs) return self.fail("expr {d} out of range ({d} exprs)", .{ fr.id, n_exprs });
        if (self.expr_done[fr.id]) return self.fail("expr {d} occurs more than once (tree, no DAG, hir.md §3.7)", .{fr.id});
        self.expr_done[fr.id] = true;

        const e = self.program.exprs.items[fr.id];
        if (e.op >= hir.op_descriptors.len) return self.fail("expr {d} carries op id {d} out of range", .{ fr.id, e.op });
        const name = self.opName(e.op);

        // Annotation bounds (membership only, see file header).
        if (e.full_expr >= self.program.full_exprs.items.len) {
            return self.fail("expr {d} carries full_expr {d} out of range", .{ fr.id, e.full_expr });
        }
        if (e.sema >= self.program.semantic_infos.items.len) {
            return self.fail("expr {d} carries sema id {d} out of range", .{ fr.id, e.sema });
        }

        // Payload pairs with the opcode.
        const tag = std.meta.activeTag(e.payload);
        const want: std.meta.Tag(hir.Payload) = blk: {
            if (std.mem.eql(u8, name, "const")) break :blk .const_value;
            if (std.mem.eql(u8, name, "local")) break :blk .binder;
            if (std.mem.eql(u8, name, "fn_ref")) break :blk .func;
            if (std.mem.eql(u8, name, "module_const")) break :blk .module_const;
            if (std.mem.eql(u8, name, "field_get")) break :blk .field;
            if (std.mem.eql(u8, name, "variant_make")) break :blk .tag;
            break :blk .none;
        };
        if (tag != want) {
            return self.fail("expr {d} (op {s}) carries a .{s} payload; expected .{s}", .{ fr.id, name, @tagName(tag), @tagName(want) });
        }

        // A resolved module access path (chain-reached value leaves,
        // hir.md §7.4) pairs with the leaf ops that carry member
        // identity — never with an interior or non-leaf node. Hop
        // module indexes are checked at lowering (the validator has no
        // module table; the lowering fails cleanly out of range).
        if (e.access_hops.len > 0 and
            !std.mem.eql(u8, name, "const") and
            !std.mem.eql(u8, name, "fn_ref") and
            !std.mem.eql(u8, name, "module_const"))
        {
            return self.fail("expr {d} (op {s}) carries a module access path; only const/fn_ref/module_const leaves may", .{ fr.id, name });
        }

        // Operand range bounds, then shape arity.
        const buf = self.program.expr_buffer.items;
        const ops = e.operands;
        if (ops.start > buf.len or ops.len > buf.len - ops.start) {
            return self.fail("expr {d} operand range [{d}, +{d}) exceeds the {d}-entry operand buffer", .{ fr.id, ops.start, ops.len, buf.len });
        }
        const n_ops = ops.len;
        const desc = hir.op_descriptors[e.op];
        switch (desc.operands) {
            .none => if (n_ops != 0) return self.fail("expr {d} (op {s}) carries {d} operands; the shape allows none", .{ fr.id, name, n_ops }),
            .one => if (n_ops != 1) return self.fail("expr {d} (op {s}) carries {d} operands; the shape requires one", .{ fr.id, name, n_ops }),
            .two => if (n_ops != 2) return self.fail("expr {d} (op {s}) carries {d} operands; the shape requires two", .{ fr.id, name, n_ops }),
            .callee_and_args => if (n_ops < 1) return self.fail("expr {d} (op {s}) has no callee operand", .{ fr.id, name }),
            .list => {},
        }

        // Scope: a local binder reference must resolve lexically without
        // crossing a function boundary (hir.md §5.3).
        switch (e.payload) {
            .binder => |b| {
                if (b >= self.program.binders.items.len) {
                    return self.fail("expr {d} references binder {d} out of range", .{ fr.id, b });
                }
                if (!self.resolves(fr.ctx, b)) {
                    return self.fail("expr {d} references binder {d}, which is not in scope here (no capture, hir.md §5.3)", .{ fr.id, b });
                }
            },
            else => {},
        }

        // Region range bounds, shape arity, and pushes.
        const rbuf = self.program.region_buffer.items;
        const regs = e.regions;
        if (regs.start > rbuf.len or regs.len > rbuf.len - regs.start) {
            return self.fail("expr {d} region range [{d}, +{d}) exceeds the {d}-entry region buffer", .{ fr.id, regs.start, regs.len, rbuf.len });
        }
        const n_regs = regs.len;
        switch (desc.regions) {
            .none => if (n_regs != 0) return self.fail("expr {d} (op {s}) carries {d} regions; the shape allows none", .{ fr.id, name, n_regs }),
            .one => if (n_regs != 1) return self.fail("expr {d} (op {s}) carries {d} regions; the shape requires one", .{ fr.id, name, n_regs }),
            .two => if (n_regs != 2) return self.fail("expr {d} (op {s}) carries {d} regions; the shape requires two", .{ fr.id, name, n_regs }),
            .arms => if (n_regs < 1) return self.fail("expr {d} (op {s}) carries no arm regions", .{ fr.id, name }),
        }
        const region_ids = rbuf[regs.start..][0..regs.len];
        for (region_ids) |rid| {
            try self.work.append(self.arena, .{ .region = .{ .id = rid, .owner = e.op, .parent = fr.ctx } });
        }
        // Operand children stay in the node's own context (a let init is
        // therefore evaluated outside the binder's region — §5.3).
        const operand_ids = buf[ops.start..][0..ops.len];
        for (operand_ids) |oid| {
            try self.work.append(self.arena, .{ .expr = .{ .id = oid, .ctx = fr.ctx } });
        }
        return null;
    }

    // -- region -------------------------------------------------------------

    fn checkRegion(self: *Validator, fr: RegionFrame) !?[]const u8 {
        const n_regions = self.program.regions.items.len;
        if (fr.id >= n_regions) return self.fail("region {d} out of range ({d} regions)", .{ fr.id, n_regions });
        if (self.region_done[fr.id]) return self.fail("region {d} has more than one owning expr (tree, no DAG, hir.md §3.7)", .{fr.id});
        self.region_done[fr.id] = true;
        self.parent_region[fr.id] = fr.parent;
        self.owner_op[fr.id] = fr.owner;

        const r = self.program.regions.items[fr.id];

        // Param range bounds, then one-declaration ownership per binder.
        const bbuf = self.program.binder_buffer.items;
        const prange = r.params;
        if (prange.start > bbuf.len or prange.len > bbuf.len - prange.start) {
            return self.fail("region {d} param range [{d}, +{d}) exceeds the {d}-entry binder buffer", .{ fr.id, prange.start, prange.len, bbuf.len });
        }
        const params = bbuf[prange.start..][0..prange.len];
        for (params) |b| {
            if (b >= self.program.binders.items.len) {
                return self.fail("region {d} declares binder {d} out of range", .{ fr.id, b });
            }
            if (self.binder_owner[b] != no_region) {
                return self.fail("binder {d} is a param of more than one region (no duplicate BinderId, hir.md §10.1)", .{b});
            }
            self.binder_owner[b] = fr.id;
        }

        // Region kind rules + pattern ⇄ params (hir.md §5.4). Match-arm
        // regions keep their patterns; let regions may carry an
        // *irrefutable* destructuring pattern whose binding leaves are
        // the params (the §5.2 amendment: destructuring lets). A plain
        // identifier let is a pattern-less region with exactly one
        // param.
        if (fr.owner == match_op) {
            const pattern = r.pattern;
            if (pattern) |pat| {
                var leaves: std.ArrayListUnmanaged(hir.BinderId) = .empty;
                if (try self.checkPatternTree(pat, &leaves, 0)) |m| return m;
                if (leaves.items.len != params.len) {
                    return self.fail("arm region {d} pattern binds {d} binder(s); the region declares {d} param(s)", .{ fr.id, leaves.items.len, params.len });
                }
                for (leaves.items) |b| {
                    var found = false;
                    for (params) |p| {
                        if (p == b) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return self.fail("arm region {d} pattern binds binder {d}, which is not one of its params", .{ fr.id, b });
                }
            } else if (params.len != 0) {
                return self.fail("arm region {d} declares {d} param(s) but has no pattern", .{ fr.id, params.len });
            }
        } else if (fr.owner == let_op) {
            if (r.pattern) |pat| {
                // Destructuring let: the pattern must be irrefutable
                // (literal / variant / type-test arms are refutable and
                // belong only to match arms).
                if (try self.checkIrrefutable(pat, 0)) |m| return m;
                var leaves: std.ArrayListUnmanaged(hir.BinderId) = .empty;
                if (try self.checkPatternTree(pat, &leaves, 0)) |m| return m;
                if (leaves.items.len != params.len) {
                    return self.fail("let region {d} pattern binds {d} binder(s); the region declares {d} param(s)", .{ fr.id, leaves.items.len, params.len });
                }
                for (leaves.items) |b| {
                    var found = false;
                    for (params) |p| {
                        if (p == b) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return self.fail("let region {d} pattern binds binder {d}, which is not one of its params", .{ fr.id, b });
                }
            } else if (params.len != 1) {
                return self.fail("let region {d} must carry exactly one binder; it declares {d}", .{ fr.id, params.len });
            }
        } else {
            if (r.pattern != null) return self.fail("region {d} (op {s}) carries a pattern; only match arms and destructuring lets do (hir.md §5.4)", .{ fr.id, self.opName(fr.owner) });
            if ((fr.owner == if_op or fr.owner == and_op or fr.owner == or_op) and params.len != 0) {
                return self.fail("control region {d} must not carry binders", .{fr.id});
            }
        }

        if (r.root >= self.program.exprs.items.len) {
            return self.fail("region {d} root expr {d} out of range", .{ fr.id, r.root });
        }
        try self.work.append(self.arena, .{ .expr = .{ .id = r.root, .ctx = fr.id } });
        return null;
    }

    // -- binder resolution --------------------------------------------------

    fn resolves(self: *const Validator, ctx: ?hir.RegionId, b: hir.BinderId) bool {
        var cur = ctx;
        while (cur) |rid| {
            if (self.paramsContain(rid, b)) return true;
            // Function boundary: the λ region's own params are usable,
            // but the search stops there — no capture (hir.md §5.3).
            if (self.owner_op[rid] == lambda_op) return false;
            cur = self.parent_region[rid];
        }
        return false;
    }

    fn paramsContain(self: *const Validator, rid: hir.RegionId, b: hir.BinderId) bool {
        const r = self.program.regions.items[rid];
        const buf = self.program.binder_buffer.items;
        for (buf[r.params.start..][0..r.params.len]) |p| {
            if (p == b) return true;
        }
        return false;
    }

    /// True when the pattern subtree at `pid` is *irrefutable* (hir.md
    /// §5.2 amendment): only wildcard / binding leaves / tuple / struct /
    /// list shapes. Literal, variant, and type-test patterns are
    /// refutable and belong only to match arms. Recursion is bounded by
    /// the same cap as the pattern walk (a crafted cycle fails cleanly).
    fn checkIrrefutable(self: *const Validator, pid: hir.PatternId, depth: u32) !?[]const u8 {
        if (depth > pattern_depth_cap) return self.fail("pattern nesting exceeds {d} levels", .{pattern_depth_cap});
        if (pid >= self.program.patterns.items.len) return self.fail("pattern {d} out of range", .{pid});
        switch (self.program.patterns.items[pid]) {
            .wildcard, .bind => return null,
            .type_test => return self.fail("a type-test pattern is refutable; only match arms may carry one", .{}),
            .literal => return self.fail("a literal pattern is refutable; only match arms may carry one", .{}),
            .variant => return self.fail("a variant pattern is refutable; only match arms may carry one", .{}),
            .tuple => |kids| {
                for (kids) |k| if (try self.checkIrrefutable(k, depth + 1)) |m| return m;
            },
            .list => |l| {
                for (l.elems) |k| if (try self.checkIrrefutable(k, depth + 1)) |m| return m;
                if (l.rest) |k| if (try self.checkIrrefutable(k, depth + 1)) |m| return m;
            },
            .struct_ => |st| {
                for (st.fields) |f| if (try self.checkIrrefutable(f.pat, depth + 1)) |m| return m;
            },
        }
        return null;
    }

    // -- patterns -----------------------------------------------------------

    /// Walk one pattern tree, appending every binding leaf (`.bind`,
    /// `.type_test.bind`) to `leaves` in first-visit order. Rejects
    /// out-of-range child ids and cycles. Shared subtrees (two arms
    /// referencing one pattern id) are legal for leaf-free patterns;
    /// a shared subtree that binds names is rejected downstream by the
    /// per-arm bijection (the binder can only be one arm's param).
    /// Walk one pattern tree, recording its binding leaves. Depth-capped:
    /// the walk is recursive (cycles are caught by the 0/1/2 state, so
    /// recursion depth equals the longest *cycle-free* nesting chain, which
    /// only a crafted arena can make arbitrarily deep) — past the cap a
    /// crafted chain fails with a diagnostic instead of overflowing the
    /// stack.
    fn checkPatternTree(self: *Validator, pid: hir.PatternId, leaves: *std.ArrayListUnmanaged(hir.BinderId), depth: u32) !?[]const u8 {
        if (depth > pattern_depth_cap) return self.fail("pattern nesting exceeds {d} levels", .{pattern_depth_cap});
        const n_patterns = self.program.patterns.items.len;
        if (pid >= n_patterns) return self.fail("pattern {d} out of range ({d} patterns)", .{ pid, n_patterns });
        switch (self.pat_state[pid]) {
            1 => return self.fail("pattern cycle at {d}", .{pid}),
            2 => return null, // shared and already walked: leaves recorded
            else => {},
        }
        self.pat_state[pid] = 1;
        const pat = self.program.patterns.items[pid];
        switch (pat) {
            .bind => |b| {
                if (b >= self.program.binders.items.len) return self.fail("pattern {d} binds binder {d} out of range", .{ pid, b });
                try leaves.append(self.arena, b);
            },
            .type_test => |tt| {
                // A binding-less type test (`int32 => …` matching an
                // `any` by tag) carries the no-binder sentinel and binds
                // nothing.
                if (tt.bind == std.math.maxInt(hir.BinderId)) return null;
                if (tt.bind >= self.program.binders.items.len) return self.fail("pattern {d} binds binder {d} out of range", .{ pid, tt.bind });
                try leaves.append(self.arena, tt.bind);
            },
            .tuple => |kids| {
                for (kids) |k| {
                    if (try self.checkPatternTree(k, leaves, depth + 1)) |m| return m;
                }
            },
            .list => |l| {
                for (l.elems) |k| {
                    if (try self.checkPatternTree(k, leaves, depth + 1)) |m| return m;
                }
                if (l.rest) |k| {
                    if (try self.checkPatternTree(k, leaves, depth + 1)) |m| return m;
                }
            },
            .struct_ => |s| {
                for (s.fields) |f| {
                    if (try self.checkPatternTree(f.pat, leaves, depth + 1)) |m| return m;
                }
            },
            .variant => |v| {
                if (v.payload) |k| {
                    if (try self.checkPatternTree(k, leaves, depth + 1)) |m| return m;
                }
            },
            .wildcard, .literal => {},
        }
        self.pat_state[pid] = 2;
        return null;
    }
};

// ---------------------------------------------------------------------------
// White-box tests (owning module: hir.md §10.2). Parse-shaped acceptance
// uses the S2 canonical texts; rejections that text cannot express
// (DAGs, duplicate binder ids, malformed handles) build arenas directly.
// ---------------------------------------------------------------------------

const t = std.testing;
const ty_int = meta.Type{ .primitive = .int32 };
const ty_bool = meta.Type{ .primitive = .bool };

const op_const = hir.opId("const").?;
const op_local = hir.opId("local").?;
const op_let = hir.opId("let").?;
const op_seq = hir.opId("seq").?;
const op_lambda = hir.opId("lambda").?;
const op_if = hir.opId("if").?;
const op_match = hir.opId("match").?;

fn mustAccept(text: []const u8, ctx: hir.SerCtx) !void {
    var p = try hir.parseText(text, ctx);
    defer p.arena.deinit();
    const m = try validate(&p.program, p.root, p.arena.allocator());
    try t.expect(m == null);
}

fn mustReject(text: []const u8, ctx: hir.SerCtx, expected: []const u8) !void {
    var p = try hir.parseText(text, ctx);
    defer p.arena.deinit();
    const m = try validate(&p.program, p.root, p.arena.allocator());
    const msg = m orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg, expected) != null);
}

/// A fresh program with arena-backed allocations (caller owns the arena).
fn fresh(arena: std.mem.Allocator) !struct { prog: hir.Program } {
    return .{ .prog = try hir.Program.init(arena) };
}

test "§4.7 goldens and the §8.7 fragment parse and validate" {
    try mustAccept("fn (B0: i32) => mul.i32(%B0, 2i32)", .{});
    try mustAccept("fn (B0: i32) => let B1: i32 = call(fn (B2: i32) => add.i32(%B2, 0i32), %B0) in mul.i32(%B1, 1i32)", .{});
    var fix = try optionFixture(t.allocator);
    defer fix.arena.deinit();
    try mustAccept("fn (B0: Option[i32]) => match(%B0) { Option::Some(B1) => add.i32(%B1, 1i32), Option::None => 0i32 }", fix.ctx);
}

test "shadowing, nested lets, and if with or without else validate" {
    // Inner `B0` shadows the outer λ param: distinct binder ids, so the
    // body's `%B0` resolves to the inner let (hir.md §5.1).
    try mustAccept("fn (B0: i32) => let B0: i32 = 1i32 in add.i32(%B0, %B0)", .{});
    // Nested lets see enclosing binders (no function boundary crossed).
    try mustAccept("fn (B0: i32) => let B1: i32 = %B0 in let B2: i32 = %B1 in add.i32(%B0, %B2)", .{});
    try mustAccept("fn (B0: bool) => if %B0 then 1i32 else 2i32", .{});
    try mustAccept("fn (B0: bool) => if %B0 then 1i32", .{});
    try mustAccept("fn () => 5i32", .{});
}

test "fn_ref with a resolved function payload validates" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    // `.func` on `fn_ref` is the correct pairing and validates (no
    // serialization context needed at the structural level).
    const ok = try p.addExpr(.{ .op = hir.opId("fn_ref").?, .ty = ty_int, .payload = .{ .func = .{ .func = 0 } } });
    const m_ok = try validate(&p, ok, arena.allocator());
    try t.expect(m_ok == null);
    // `.func` on `const` is a pairing mismatch and is rejected.
    const bad = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .func = .{ .func = 0 } } });
    const m_bad = try validate(&p, bad, arena.allocator());
    const msg = m_bad orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg, "payload") != null);
}

test "nested λ capture of an outer binder parses but fails validation" {
    // The parser keeps outer declarations live across λ boundaries, so
    // this text parses; the validator's function-barrier rule rejects it
    // (hir.md §5.3 no-capture).
    try mustReject("fn (B0: i32) => fn (B1: i32) => %B0", .{}, "not in scope");
}

test "sibling arm regions cannot see each other's binders" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    const b1 = try p.addBinder(ty_int, .value);
    const arm1_root = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } });
    const arm1_pat = try p.addPattern(.{ .bind = b1 });
    const arm1 = try p.addRegion(&.{b1}, arm1_root, arm1_pat);
    // Arm 2 (patternless) tries to reference arm 1's binder: the search
    // walks out of arm 2, past the match (not a boundary) and finds no
    // enclosing region declaring b1 — rejected.
    const leak = try p.addExpr(.{ .op = op_local, .ty = ty_int, .payload = .{ .binder = b1 } });
    const arm2 = try p.addRegion(&.{}, leak, null);
    const scrutinee = try p.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = true } } });
    const operands = try p.addOperands(&.{scrutinee});
    const regions = try p.addRegions(&.{ arm1, arm2 });
    const root = try p.addExpr(.{ .op = op_match, .ty = ty_int, .operands = operands, .regions = regions });
    const m = try validate(&p, root, arena.allocator());
    const msg = m orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg, "not in scope") != null);
}

test "shared operands (DAG) and self-cycles are rejected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;

    // Same child twice in one operand list: a shared subtree.
    const c = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } });
    const dup_ops = try p.addOperands(&.{ c, c });
    const seq1 = try p.addExpr(.{ .op = op_seq, .ty = ty_int, .operands = dup_ops });
    const m1 = try validate(&p, seq1, arena.allocator());
    try t.expect(m1 != null);

    // Self-reference: mutate the node to list itself as an operand.
    const self_seq = try p.addExpr(.{ .op = op_seq, .ty = ty_int });
    const self_ops = try p.addOperands(&.{self_seq});
    p.exprs.items[self_seq].operands = self_ops;
    const m2 = try validate(&p, self_seq, arena.allocator());
    const msg2 = m2 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg2, "more than once") != null);
}

test "a region with two owning exprs is rejected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    const r0 = try p.addRegion(&.{}, try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } }), null);
    const r1 = try p.addRegion(&.{}, try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 2 } } }), null);
    const shared = try p.addRegions(&.{ r0, r1 });
    const cond = try p.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = true } } });
    const op_a = try p.addOperands(&.{cond});
    // Two `if` nodes whose region slices address the same two regions.
    const if_a = try p.addExpr(.{ .op = op_if, .ty = ty_int, .operands = op_a, .regions = shared });
    const cond2 = try p.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = false } } });
    const op_b = try p.addOperands(&.{cond2});
    const if_b = try p.addExpr(.{ .op = op_if, .ty = ty_int, .operands = op_b, .regions = shared });
    const body = try p.addOperands(&.{ if_a, if_b });
    const seq_id = try p.addExpr(.{ .op = op_seq, .ty = ty_int, .operands = body });
    const m = try validate(&p, seq_id, arena.allocator());
    const msg = m orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg, "more than one owning") != null);
}

test "a BinderId is a param of at most one region" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    const b = try p.addBinder(ty_int, .value);
    // Duplicate binder in a single region's params.
    const reg = try p.addRegion(&.{ b, b }, try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 0 } } }), null);
    const regions = try p.addRegions(&.{reg});
    const fn_ty = meta.Type{ .primitive = .int32 };
    const lam = try p.addExpr(.{ .op = op_lambda, .ty = fn_ty, .regions = regions });
    const m = try validate(&p, lam, arena.allocator());
    const msg = m orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg, "more than one region") != null);
}

test "let init exclusion is structural: init cannot see its own binder" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    const b_x = try p.addBinder(ty_int, .value);
    const body = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 0 } } });
    const reg = try p.addRegion(&.{b_x}, body, null);
    const regions = try p.addRegions(&.{reg});
    // Init references the binder the let is about to introduce. The init
    // operand is walked in the outer context (here: none), so the
    // reference cannot resolve.
    const bad_init = try p.addExpr(.{ .op = op_local, .ty = ty_int, .payload = .{ .binder = b_x } });
    const operands = try p.addOperands(&.{bad_init});
    const let_id = try p.addExpr(.{ .op = op_let, .ty = ty_int, .operands = operands, .regions = regions });
    const m = try validate(&p, let_id, arena.allocator());
    const msg = m orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg, "not in scope") != null);
}

test "out-of-range expr ids and operand/region ranges are rejected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    // Root points past the (empty) arena.
    const m1 = try validate(&p, 5, arena.allocator());
    try t.expect(m1 != null);
    // An operand id that names no expr.
    const ops = try p.addOperands(&.{999});
    const seq_id = try p.addExpr(.{ .op = op_seq, .ty = ty_int, .operands = ops });
    const m2 = try validate(&p, seq_id, arena.allocator());
    const msg2 = m2 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg2, "out of range") != null);
    // A node whose region range runs past the region buffer.
    const regs = try p.addRegions(&.{});
    _ = regs;
    const r0 = try p.addRegion(&.{}, try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } }), null);
    const ok_regs = try p.addRegions(&.{r0});
    const lam = try p.addExpr(.{ .op = op_lambda, .ty = ty_int, .regions = ok_regs });
    p.exprs.items[lam].regions = .{ .start = 100, .len = 0 };
    const m3 = try validate(&p, lam, arena.allocator());
    const msg3 = m3 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg3, "exceeds") != null);
}

test "payload/op pairing and descriptor arity are enforced" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    // local with a const payload.
    const bad_payload = try p.addExpr(.{ .op = op_local, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } });
    const m1 = try validate(&p, bad_payload, arena.allocator());
    try t.expect(m1 != null);
    // const with one operand (shape allows none).
    const c = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } });
    const ops = try p.addOperands(&.{c});
    const const_w_ops = try p.addExpr(.{ .op = op_const, .ty = ty_int, .operands = ops });
    const m2 = try validate(&p, const_w_ops, arena.allocator());
    try t.expect(m2 != null);
    // let with no init operand (shape requires one).
    const body = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 0 } } });
    const reg = try p.addRegion(&.{}, body, null);
    const regs = try p.addRegions(&.{reg});
    const no_init = try p.addExpr(.{ .op = op_let, .ty = ty_int, .regions = regs });
    const m3 = try validate(&p, no_init, arena.allocator());
    try t.expect(m3 != null);
    // if with only one region (shape requires two).
    const cond = try p.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = true } } });
    const op_a = try p.addOperands(&.{cond});
    const one_reg = try p.addRegions(&.{reg});
    const if_one = try p.addExpr(.{ .op = op_if, .ty = ty_int, .operands = op_a, .regions = one_reg });
    const m4 = try validate(&p, if_one, arena.allocator());
    try t.expect(m4 != null);
}

test "out-of-range full_expr and sema ids are rejected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    const bad_fe = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } }, .full_expr = 3 });
    const m1 = try validate(&p, bad_fe, arena.allocator());
    try t.expect(m1 != null);
    const bad_sema = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } }, .sema = 3 });
    const m2 = try validate(&p, bad_sema, arena.allocator());
    try t.expect(m2 != null);
    // The seeded ids (0 = default FE / owned view) are in range.
    const ok = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } });
    const m3 = try validate(&p, ok, arena.allocator());
    try t.expect(m3 == null);
}

test "arm pattern bindings must biject onto the arm region params" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    const scrutinee = try p.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = true } } });
    const operands = try p.addOperands(&.{scrutinee});

    // Leaf names a binder the arm region does not declare.
    const b_a = try p.addBinder(ty_int, .value);
    const b_other = try p.addBinder(ty_int, .value);
    const pat_other = try p.addPattern(.{ .bind = b_other });
    const arm1 = try p.addRegion(&.{b_a}, try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } }), pat_other);
    const m1 = try validate(&p, try p.addExpr(.{ .op = op_match, .ty = ty_int, .operands = operands, .regions = try p.addRegions(&.{arm1}) }), arena.allocator());
    const msg1 = m1 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg1, "not one of its params") != null);

    // Params without a pattern (arm body has no `=>` yet declares binds).
    const b2 = try p.addBinder(ty_int, .value);
    const arm2 = try p.addRegion(&.{b2}, try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 0 } } }), null);
    const ops2 = try p.addOperands(&.{try p.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = false } } })});
    const m2 = try validate(&p, try p.addExpr(.{ .op = op_match, .ty = ty_int, .operands = ops2, .regions = try p.addRegions(&.{arm2}) }), arena.allocator());
    const msg2 = m2 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg2, "no pattern") != null);
}

test "patterns appear only on match arms; pattern cycles are rejected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;

    // A λ region carrying a pattern.
    const b = try p.addBinder(ty_int, .value);
    const pat = try p.addPattern(.{ .bind = b });
    const lam_reg = try p.addRegion(&.{b}, try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 0 } } }), pat);
    const m1 = try validate(&p, try p.addExpr(.{ .op = op_lambda, .ty = ty_int, .regions = try p.addRegions(&.{lam_reg}) }), arena.allocator());
    const msg1 = m1 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg1, "only match arms") != null);

    // A pattern cycle: make pattern 0 a tuple containing itself.
    var q = (try fresh(arena.allocator())).prog;
    const self_pat = try q.addPattern(.wildcard);
    const self_slice = try arena.allocator().alloc(hir.PatternId, 1);
    self_slice[0] = self_pat;
    q.patterns.items[self_pat] = .{ .tuple = self_slice };
    const scrutinee = try q.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = true } } });
    const operands = try q.addOperands(&.{scrutinee});
    const arm = try q.addRegion(&.{}, try q.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } }), self_pat);
    const m2 = try validate(&q, try q.addExpr(.{ .op = op_match, .ty = ty_int, .operands = operands, .regions = try q.addRegions(&.{arm}) }), arena.allocator());
    const msg2 = m2 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg2, "pattern cycle") != null);
}

test "let and if regions carry the documented param counts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;

    // let region with zero params.
    const b0 = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 0 } } });
    const init_ops = try p.addOperands(&.{b0});
    const reg0 = try p.addRegion(&.{}, b0, null);
    const let_id = try p.addExpr(.{ .op = op_let, .ty = ty_int, .operands = init_ops, .regions = try p.addRegions(&.{reg0}) });
    const m1 = try validate(&p, let_id, arena.allocator());
    const msg1 = m1 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg1, "exactly one binder") != null);

    // if region carrying a binder.
    const b_x = try p.addBinder(ty_int, .value);
    const cond = try p.addExpr(.{ .op = op_const, .ty = ty_bool, .payload = .{ .const_value = .{ .bool = true } } });
    const cond_ops = try p.addOperands(&.{cond});
    const then_reg = try p.addRegion(&.{b_x}, b0, null);
    const else_reg = try p.addRegion(&.{}, b0, null);
    const if_id = try p.addExpr(.{ .op = op_if, .ty = ty_int, .operands = cond_ops, .regions = try p.addRegions(&.{ then_reg, else_reg }) });
    const m2 = try validate(&p, if_id, arena.allocator());
    const msg2 = m2 orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, msg2, "must not carry binders") != null);
}

test "the returned violation message is caller-owned (allocated from the caller's allocator)" {
    // Regression: messages were once allocated in the validator's own
    // scratch arena, freed before the caller read them (use-after-free
    // that arena reuse happened to mask). With std.testing.allocator as
    // the caller allocator the returned slice must be live and must be
    // freed by the caller; anything else leaks or dangles.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = (try fresh(arena.allocator())).prog;
    // A const with a `.func` payload: rejected with a payload message.
    _ = try p.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .func = .{ .func = 0 } } });
    const m = (try validate(&p, 0, t.allocator)) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(m);
    try t.expect(std.mem.indexOf(u8, m, "payload") != null);
    // A valid program yields null and no allocation survives.
    var q = (try fresh(arena.allocator())).prog;
    const ok = try q.addExpr(.{ .op = op_const, .ty = ty_int, .payload = .{ .const_value = .{ .int = 1 } } });
    try t.expect((try validate(&q, ok, t.allocator)) == null);
}

// -- fixtures ---------------------------------------------------------------

const Fixture = struct { arena: std.heap.ArenaAllocator, ctx: hir.SerCtx };

/// One `Option[T]` union decl so §4.7-ex2 (nominal type + variant
/// pattern) can parse without a real module graph.
fn optionFixture(allocator: std.mem.Allocator) !Fixture {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const t_param = "T";
    const param_ty = meta.Type{ .param = t_param };
    const some_payload = try a.dupe(meta.Type, &.{param_ty});
    var variants = try a.alloc(meta.VariantDecl, 2);
    variants[0] = .{ .name = "Some", .payloads = some_payload };
    variants[1] = .{ .name = "None", .payloads = &.{} };
    const type_params = try a.dupe([]const u8, &.{t_param});
    const decls = try a.alloc(meta.TypeDecl, 1);
    decls[0] = .{ .union_ = .{
        .name = "Option",
        .module = "test",
        .type_params = type_params,
        .ownership = .copy,
        .variants = variants,
    } };
    return .{ .arena = arena, .ctx = .{ .types = decls } };
}
