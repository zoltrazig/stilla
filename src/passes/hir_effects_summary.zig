//! Call-summary fixpoint of the HIR effect analysis (docs/effects.md
//! §8.2/§9.2/§13). The method bodies here were moved verbatim out of
//! the driver `passes/hir_effects.zig`, which keeps a `pub const`
//! alias per method so `an.<method>(...)` call syntax is unchanged for
//! every consumer; the docs live with each method body.

const std = @import("std");
const hir = @import("stilla").hir;
const effects = @import("stilla").effects;
const hir_effects = @import("hir_effects.zig");

const Analysis = hir_effects.Analysis;
const Error = hir_effects.Error;
const Summary = hir_effects.Summary;
const ResolvedTarget = hir_effects.ResolvedTarget;
const max_indirect_targets = hir_effects.max_indirect_targets;
const max_indirect_steps = hir_effects.max_indirect_steps;

const lambda_op = hir_effects.lambda_op;
const fn_ref_op = hir_effects.fn_ref_op;
const call_op = hir_effects.call_op;
const local_op = hir_effects.local_op;
const if_op = hir_effects.if_op;
const match_op = hir_effects.match_op;
const seq_op = hir_effects.seq_op;
const move_op = hir_effects.move_op;
const borrow_op = hir_effects.borrow_op;

fn targetEq(a: ResolvedTarget, b: ResolvedTarget) bool {
    return switch (a) {
        .func => |f| switch (b) {
            .func => |g| f == g,
            else => false,
        },
        .host => |h| switch (b) {
            .host => |k| h == k,
            else => false,
        },
    };
}

/// Kosaraju pass 1: DFS finishing order over the unified
/// node→dependency graph (`adj[u]` are the nodes `u` depends on).
fn finishOrder(arena: std.mem.Allocator, adj: []const std.ArrayList(u32)) Error![]u32 {
    const n = adj.len;
    const visited = try arena.alloc(bool, n);
    @memset(visited, false);
    var order = std.ArrayList(u32).empty;
    var stack = std.ArrayList(struct { u32, usize }).empty;
    for (0..n) |s| {
        if (visited[s]) continue;
        visited[s] = true;
        try stack.append(arena, .{ @intCast(s), 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const v: u32 = top[0];
            if (top[1] < adj[v].items.len) {
                const w = adj[v].items[top[1]];
                top[1] += 1;
                if (!visited[w]) {
                    visited[w] = true;
                    try stack.append(arena, .{ w, 0 });
                }
            } else {
                try order.append(arena, v);
                _ = stack.pop();
            }
        }
    }
    return order.items;
}

/// Kosaraju pass 2: one DFS tree on the reversed graph is one SCC.
fn dfsCollect(
    arena: std.mem.Allocator,
    radj: []const std.ArrayList(u32),
    start: u32,
    seen: []bool,
    out: *std.ArrayList(u32),
) Error!void {
    var stack = std.ArrayList(u32).empty;
    try stack.append(arena, start);
    seen[start] = true;
    while (stack.pop()) |v| {
        try out.append(arena, v);
        for (radj[v].items) |w| {
            if (!seen[w]) {
                seen[w] = true;
                try stack.append(arena, w);
            }
        }
    }
}

/// The effect of *calling* the value `callee` evaluates to
/// (docs/effects.md §6.1 `effect_bound`), distinct from `effects(callee)`.
///
/// An inline λ is the one special case (its body is not a `fn_ref`
/// target); every other callee — including a direct `fn_ref` — goes
/// through the local target narrowing of docs/effects.md §9.2, which
/// resolves a literal `fn_ref` to its singleton set. When narrowing
/// yields no finite target set the result is the full `top` (§9.1).
pub fn effectBound(self: *Analysis, callee: hir.ExprId) Error!Summary {
    if (self.p().node(callee).op == lambda_op) return self.lambdaBodySummary(callee);
    var targets = std.ArrayList(ResolvedTarget).empty;
    defer targets.deinit(self.arena);
    if (try self.resolveTargets(callee, &targets)) {
        if (targets.items.len > 0) {
            var acc: ?Summary = null;
            for (targets.items) |t| {
                const b = try self.targetBound(t);
                acc = if (acc) |a| try self.eng.join(a, b) else b;
            }
            return acc.?;
        }
    }
    return self.eng.top();
}

/// The context-free `effect_bound` of one resolved target
/// (docs/effects.md §6.1, §13): a function / λ record reads its
/// finalized (or in-progress) summary; a host binding with no
/// declaration is the full `top`, and a declaration is honoured only
/// as far as `HostEffects.Entry.effectiveSummary` allows. The call-site
/// refinement (callback parameterization) lives in `targetCallBound`.
pub fn targetBound(self: *Analysis, t: ResolvedTarget) Error!Summary {
    return switch (t) {
        .func => |fid| self.functionSummary(fid),
        .host => |hb| try self.hostSummary(hb),
    };
}

/// A host binding's summary as *this instance* sees it
/// (docs/effects.md §5.7, §13): the declaration is used verbatim only
/// under an explicit `StillaExecution.forbidden` attestation; every
/// weaker attestation — and a missing declaration — is this
/// instance's full `top`, which covers the modes the provider
/// declared rather than only the built-in four.
pub fn hostSummary(self: *Analysis, hb: hir.HostBindingId) Error!Summary {
    const e = self.hosts.lookupEntry(hb) orelse return self.eng.top();
    return switch (e.stilla_execution) {
        .forbidden => self.eng.admitted(e.summary),
        .may_execute, .unknown => self.eng.top(),
    };
}

/// The provable finite target set of an indirect callee
/// (docs/effects.md §9.2), demand-driven and budgeted.
///
/// Traces the callee value backwards along the *local* binding chain
/// the builder emits: a literal `fn_ref`, a `let`-bound local, the
/// regions of an `if` / `match`, a `seq`'s forwarded last operand, and
/// a `move` / `borrow` wrapper. Everything else is a boundary and
/// returns false (→ `Top` at every caller): a function / λ parameter,
/// a match-arm or destructuring binding, a `field_get` (the value
/// escaped into a structure), any `call` / `module_const` result, a
/// value-position module chain, an `any_cast` recovery. That is also
/// the "no cross-function boundary, no escape path" rule: the walk
/// only follows binding chains and stops at any other binding site.
///
/// The budget is a precision limit, never a truncation: exceeding
/// `max_indirect_targets` distinct targets or `max_indirect_steps`
/// node visits returns false, it never returns the first N targets.
/// `collectCallees` drives the same function, so the call graph always
/// sees exactly the target set the summaries use; this never reads an
/// effect summary, so graph construction has no circularity.
pub fn resolveTargets(self: *Analysis, callee: hir.ExprId, out: *std.ArrayList(ResolvedTarget)) Error!bool {
    const pr = self.p();
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(self.arena);
    try work.append(self.arena, callee);
    var steps: usize = 0;
    while (work.pop()) |id| {
        steps += 1;
        if (steps > max_indirect_steps) return false;
        const n = pr.node(id);
        // A value-position module chain runs module initialization, an
        // effect this model does not represent (docs/effects.md §14),
        // so it is a boundary — same as in `compute`.
        if (n.access_hops.len > 0) return false;
        if (n.op == fn_ref_op) {
            switch (n.payload) {
                .func => |fr| {
                    const t: ResolvedTarget = switch (fr) {
                        .func => |fid| .{ .func = fid },
                        .host => |hb| .{ .host = hb },
                    };
                    if (!try self.addTarget(out, t)) return false;
                },
                else => return false,
            }
        } else if (n.op == local_op) {
            const bind = switch (n.payload) {
                .binder => |b| b,
                else => return false,
            };
            if (bind >= self.binder_init.len) return false;
            const initializer = self.binder_init[bind];
            if (initializer == hir.no_expr) return false;
            try work.append(self.arena, initializer);
        } else if (n.op == if_op or n.op == match_op) {
            for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
        } else if (n.op == seq_op) {
            const ops = pr.operands(id);
            if (ops.len == 0) return false;
            try work.append(self.arena, ops[ops.len - 1]);
        } else if (n.op == move_op or n.op == borrow_op) {
            const ops = pr.operands(id);
            if (ops.len != 1) return false;
            try work.append(self.arena, ops[0]);
        } else {
            return false;
        }
    }
    return true;
}

/// Add one target to the set, deduplicated, refusing (never
/// truncating) once the set would exceed `max_indirect_targets`.
pub fn addTarget(self: *Analysis, out: *std.ArrayList(ResolvedTarget), t: ResolvedTarget) Error!bool {
    for (out.items) |x| if (targetEq(x, t)) return true;
    if (out.items.len >= max_indirect_targets) return false;
    try out.append(self.arena, t);
    return true;
}

/// `effect_bound` of a *call site* (docs/effects.md §6.1, §13).
///
/// The callee's target set is resolved once (docs/effects.md §9.2);
/// the site's bound is the join over the targets. A `may_execute` host
/// binding with an exhaustive callback contract is bounded by
/// `own ⊔ ⨆ effect_bound(target_i)` — the contract attests the
/// execution happens synchronously, during this invocation, and only
/// through the listed argument positions, so a binding that stores a
/// callable for a later call cannot use it.
///
/// Any unresolved callee, a missing declaration, an out-of-range
/// position, or a callback argument with no provable finite target set
/// makes the site `Top`. The same target set feeds `collectCallees`, so
/// this only ever reads finalized or in-progress SCC facts.
pub fn callBound(self: *Analysis, ops: []const hir.ExprId) Error!Summary {
    if (ops.len == 0) return self.eng.top();
    var targets = std.ArrayList(ResolvedTarget).empty;
    defer targets.deinit(self.arena);
    if (try self.resolveTargets(ops[0], &targets)) {
        if (targets.items.len > 0) {
            var acc: ?Summary = null;
            for (targets.items) |t| {
                const b = try self.targetCallBound(t, ops);
                acc = if (acc) |a| try self.eng.join(a, b) else b;
            }
            return acc.?;
        }
    }
    // Includes the λ-callee white-box case `resolveTargets` does not
    // model; every other unresolved callee is `Top` there.
    return self.effectBound(ops[0]);
}

/// One resolved target's `effect_bound` at a call site. A `may_execute`
/// host with a callback contract is the only case richer than
/// `targetBound`; `ops[1..]` are the call's arguments.
pub fn targetCallBound(self: *Analysis, t: ResolvedTarget, ops: []const hir.ExprId) Error!Summary {
    switch (t) {
        .func => |fid| return self.functionSummary(fid),
        .host => |hb| {
            const entry = self.hosts.lookupEntry(hb) orelse return self.eng.top();
            // Only a `may_execute` binding with an explicit callback
            // contract is bounded below by its declaration; every
            // other shape is this instance's `top` (docs/effects.md
            // §13).
            if (entry.stilla_execution != .may_execute) return self.hostSummary(hb);
            const positions = entry.callbacks orelse return self.hostSummary(hb);
            var acc = try self.eng.admitted(entry.summary);
            for (positions) |pos| {
                // Bounds-check before widening: `pos + 1` would overflow
                // on a 32-bit target when `pos` is `maxInt(u32)`, and a
                // wrapped index is a wrong answer, not a conservative
                // one. Arg 0 is ops[1], so a valid position is
                // `< ops.len - 1`.
                if (pos >= ops.len - 1) return self.eng.top();
                const bound = try self.callbackBound(ops[@as(usize, pos) + 1]) orelse return self.eng.top();
                acc = try self.eng.join(acc, bound);
            }
            return acc;
        },
    }
}

/// `effect_bound` of a callable value passed as an argument
/// (docs/effects.md §13 callback parameterization), for the local
/// target narrowing of §9.2. Null when no provable finite target set
/// exists, which the contract path maps to `Top` for the whole call
/// (never a truncated set). A value-position module chain would run
/// module initialization, so it is null too.
pub fn callbackBound(self: *Analysis, arg: hir.ExprId) Error!?Summary {
    const n = self.p().node(arg);
    if (n.access_hops.len > 0) return null;
    if (n.op == lambda_op) return try self.lambdaBodySummary(arg);
    var targets = std.ArrayList(ResolvedTarget).empty;
    defer targets.deinit(self.arena);
    if (try self.resolveTargets(arg, &targets)) {
        if (targets.items.len > 0) {
            var acc: ?Summary = null;
            for (targets.items) |t| {
                const b = try self.targetBound(t);
                acc = if (acc) |a| try self.eng.join(a, b) else b;
            }
            return acc.?;
        }
    }
    return null;
}

// -----------------------------------------------------------------
// Function summaries
// -----------------------------------------------------------------

/// The finalized (or in-progress) unified-node value. While its SCC is
/// being solved a member reads the in-progress approximation; every
/// other node reads the finalized value. An unknown node is `Top`
/// (docs/effects.md §8.2/§11.1).
pub fn nodeValue(self: *Analysis, node: u32) Summary {
    if (self.solving) |s| {
        if (self.comp_of[node] == s) return self.cur[node];
    }
    if (!self.known[node]) return self.eng.top();
    return self.summary[node];
}

/// A finalized (or in-progress) function summary. `Top` for an
/// out-of-range id (missing body); otherwise the function node's
/// unified value. The function-level surface every existing consumer
/// (SEG, simplify, derived queries, module-const checks) reads.
pub fn functionSummary(self: *Analysis, fid: hir.FuncId) Error!Summary {
    if (fid >= self.built.funcs.items.len) return self.eng.top();
    return self.nodeValue(fid);
}

// -----------------------------------------------------------------
// Unified dependency graph least fixpoint (docs/effects.md §8.2/§11.1)
// -----------------------------------------------------------------

/// The transfer of one unified node: a function's body summary
/// (`effectOf ; cleanupEffect`), a `drop_type`'s structural drop effect,
/// or the reserved `Top` sink.
pub fn nodeTransfer(self: *Analysis, node: u32) Error!Summary {
    if (node == self.top_sink_node) return self.eng.top();
    if (node < self.built.funcs.items.len) return self.recordBodySummary(self.built.funcs.items[node]);
    return self.dropNodeTransfer(node);
}

/// Solve the whole program's effect summaries on one dependency graph
/// (docs/effects.md §11.1). Nodes `0..F-1` are functions, `F` the `Top`
/// sink, `F+1..` `drop_type` nodes keyed by canonical `HIRTypeId`; the
/// four edge kinds are built once and kept for the SCC pass. A single
/// Kosaraju decomposition is processed dependency-first; each SCC runs
/// a Kleene/Jacobi simultaneous update over the union. `function →
/// drop_type` edges — previously missing for implicit cleanup — close
/// the cross-layer cycle (`hook → fn → type`) that used to fall back to
/// `Top`.
pub fn solveSummaries(self: *Analysis) Error!void {
    const fn_count = self.built.funcs.items.len;
    self.solving = null;
    @memset(self.memo, null);
    self.drop_node_of.clearRetainingCapacity();
    self.drop_key_of_node.clearRetainingCapacity();

    // Nodes 0..F-1 are functions, F the reserved Top sink. One adjacency
    // list per node, and the inverse type-key table grows in lockstep.
    var adj = std.ArrayList(std.ArrayList(u32)).empty;
    for (0..fn_count + 1) |_| {
        try adj.append(self.arena, .empty);
        try self.drop_key_of_node.append(self.arena, 0);
    }
    self.top_sink_node = @intCast(fn_count);

    // 1. function → function and function → drop_type.
    for (0..fn_count) |i| {
        const f: hir.FuncId = @intCast(i);
        try self.collectCallees(f, &adj.items[i]);
        try self.collectFunctionDrops(f, &adj, @intCast(i));
    }

    // 2. Drop-type roots outside function bodies: a constant's declared
    //    type (teardown), its initializer's explicit drops, and every
    //    registered cleanup token (const initializers included).
    for (self.built.consts.items) |c| {
        if (c.init) |root| try self.collectConstDrops(root, &adj);
        _ = try self.addDropNode(&adj, self.p().typeOf(c.type_), 0);
    }
    for (self.p().cleanup_tokens.items) |tk| {
        _ = try self.addDropNode(&adj, self.p().typeOf(tk.ty), 0);
    }

    // 3. Node storage sized to the whole graph.
    const n = adj.items.len;
    self.summary = try self.arena.alloc(Summary, n);
    @memset(self.summary, effects.pure);
    self.known = try self.arena.alloc(bool, n);
    @memset(self.known, false);
    self.cur = try self.arena.alloc(Summary, n);
    @memset(self.cur, effects.pure);
    self.comp_of = try self.arena.alloc(u32, n);
    @memset(self.comp_of, 0);

    // 4. SCCs by Kosaraju: finish order on G, then DFS on G^T in
    //    reverse finish order.
    var radj = try self.arena.alloc(std.ArrayList(u32), n);
    for (radj) |*a| a.* = .empty;
    for (0..n) |u| {
        for (adj.items[u].items) |v| try radj[v].append(self.arena, @intCast(u));
    }
    const order = try finishOrder(self.arena, adj.items);
    var comps = std.ArrayList(std.ArrayList(u32)).empty;
    const seen = try self.arena.alloc(bool, n);
    @memset(seen, false);
    var i = order.len;
    while (i > 0) {
        i -= 1;
        const v = order[i];
        if (seen[v]) continue;
        var comp = std.ArrayList(u32).empty;
        try dfsCollect(self.arena, radj, v, seen, &comp);
        const cid: u32 = @intCast(comps.items.len);
        for (comp.items) |m| self.comp_of[m] = cid;
        try comps.append(self.arena, comp);
    }

    // 5. Process components dependency-first. Kosaraju's second pass
    //    discovers source SCCs of G first; reverse that.
    var c = comps.items.len;
    while (c > 0) {
        c -= 1;
        try self.solveComponent(comps.items[c].items, adj.items);
    }
}

/// Every `call` target in `fid`'s body that the local narrowing of
/// docs/effects.md §9.2 can resolve to a function record, plus the
/// designated callback arguments of a host contract. The graph must
/// see exactly the target set the summaries consume (`callBound`),
/// otherwise a recursion that runs through a `let`-bound fn-ref would
/// miss the SCC `Diverge` seed (docs/effects.md §8.2).
pub fn collectCallees(self: *Analysis, fid: hir.FuncId, out: *std.ArrayList(u32)) Error!void {
    const pr = self.p();
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(self.arena);
    try work.append(self.arena, self.built.funcs.items[fid].root);
    while (work.pop()) |id| {
        const node = pr.node(id);
        if (node.op == call_op) {
            const ops = pr.operands(id);
            if (ops.len > 0) {
                var targets = std.ArrayList(ResolvedTarget).empty;
                defer targets.deinit(self.arena);
                if (try self.resolveTargets(ops[0], &targets)) {
                    for (targets.items) |t| switch (t) {
                        .func => |target| if (target < self.built.funcs.items.len and !std.mem.containsAtLeastScalar(u32, out.items, 1, target)) {
                            try out.append(self.arena, target);
                        },
                        // A host call with a callback contract
                        // instantiates its designated callback
                        // arguments: those targets are real callees of
                        // this body (docs/effects.md §13), so they
                        // belong in the call graph — otherwise a
                        // callback recursion misses the SCC `Diverge`
                        // seed. Only contracts `callBound` will honour
                        // are instantiated, so the graph matches the
                        // summaries it feeds.
                        .host => |hb| if (self.hosts.lookupEntry(hb)) |e| {
                            if (e.stilla_execution == .may_execute) {
                                if (e.callbacks) |positions| for (positions) |pos| {
                                    if (pos < ops.len - 1) try self.collectCallableTarget(ops[@as(usize, pos) + 1], out);
                                };
                            }
                        },
                    };
                }
            }
        }
        for (pr.operands(id)) |op| try work.append(self.arena, op);
        for (pr.regionsOf(id)) |r| try work.append(self.arena, pr.region(r).root);
    }
}

/// Record the function targets of a callable argument (a host
/// contract's instantiated callback) so they become edges of this
/// body's call graph — resolved through the same local narrowing as
/// any other indirect value.
pub fn collectCallableTarget(self: *Analysis, arg: hir.ExprId, out: *std.ArrayList(u32)) Error!void {
    var targets = std.ArrayList(ResolvedTarget).empty;
    defer targets.deinit(self.arena);
    if (!try self.resolveTargets(arg, &targets)) return;
    for (targets.items) |t| switch (t) {
        .func => |target| if (target < self.built.funcs.items.len and !std.mem.containsAtLeastScalar(u32, out.items, 1, target)) {
            try out.append(self.arena, target);
        },
        .host => {},
    };
}

/// Solve one SCC to its least fixpoint from `Bottom`, then finalize.
/// `may_diverge` is seeded only on the **function** members of a
/// recursive component (a cycle or self-loop containing at least one
/// function); `drop_type` nodes seed `pure`, so a purely recursive type
/// never acquires `may_diverge` (docs/effects.md §11.1).
pub fn solveComponent(self: *Analysis, comp: []const u32, adj: []const std.ArrayList(u32)) Error!void {
    const fn_count = self.built.funcs.items.len;
    var recursive = comp.len > 1;
    if (!recursive) {
        for (adj[comp[0]].items) |t| {
            if (t == comp[0]) recursive = true;
        }
    }
    var has_function = false;
    for (comp) |node| {
        if (node < fn_count) has_function = true;
    }
    const func_recursive = recursive and has_function;
    const cid = self.comp_of[comp[0]];
    self.solving = cid;
    defer self.solving = null;
    for (comp) |node| {
        self.cur[node] = if (func_recursive and node < fn_count) effects.may_diverge else effects.pure;
    }

    const next = try self.arena.alloc(Summary, comp.len);
    while (true) {
        // A round is a simultaneous (Jacobi) update: the memo is
        // cleared so every transfer is derived from the same `cur`
        // approximation, all `next` values are computed, and only then
        // is `cur` reassigned.
        @memset(self.memo, null);
        for (comp, 0..) |node, k| {
            const body = try self.nodeTransfer(node);
            const seed: Summary = if (func_recursive and node < fn_count) effects.may_diverge else effects.pure;
            next[k] = try self.eng.join(seed, body);
        }
        var changed = false;
        for (comp, 0..) |node, k| {
            if (!self.eng.eql(next[k], self.cur[node])) {
                self.cur[node] = next[k];
                changed = true;
            }
        }
        if (!changed) break;
    }
    for (comp) |node| {
        self.summary[node] = self.cur[node];
        self.known[node] = true;
    }
}

pub fn recordBodySummary(self: *Analysis, rec: hir.FuncRecord) Error!Summary {
    // A module init also stores every slotted constant and runs the
    // constant initializers; neither lives in the synthetic empty
    // init body (hir_build `buildInitBody`), so its summary is
    // conservatively Top whenever the module has storage.
    if (rec.kind == .init and self.moduleHasStorage(rec.module)) return self.eng.top();
    return self.lambdaBodySummary(rec.root);
}

pub fn moduleHasStorage(self: *Analysis, module_index: u32) bool {
    if (module_index >= self.built.modules.items.len) return true;
    const range = self.built.modules.items[module_index].consts;
    for (self.built.consts.items[range.start..][0..range.len]) |c| {
        if (c.slot != null) return true;
    }
    return false;
}

/// The body summary of a λ/fn node: the body's `eval_effect`
/// sequenced with the function's normal-exit cleanup (docs/effects.md
/// §6.1, §11.2). The cleanup is the body's registered footprint —
/// full-expression temporaries plus the scope-end destruction of the
/// function's owned Unique parameters and body locals — or `Top`
/// when unmodelled.
pub fn lambdaBodySummary(self: *Analysis, root: hir.ExprId) Error!Summary {
    const pr = self.p();
    const rs = pr.regionsOf(root);
    if (rs.len == 0) return self.eng.top();
    const reg = pr.region(rs[0]);
    const body = try self.effectOf(reg.root);
    const cleanup: Summary = (try self.cleanupEffect(reg.root)) orelse self.eng.top();
    return self.eng.sequence(body, cleanup);
}
