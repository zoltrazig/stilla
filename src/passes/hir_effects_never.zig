//! `never`/divergence seam of the HIR effect analysis (docs/effects.md
//! §10.1). The method bodies here were moved verbatim out of the driver
//! `passes/hir_effects.zig`, which keeps a `pub const` alias per method
//! so `an.<method>(...)` call syntax is unchanged for every consumer;
//! the docs live with each method body.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const hir_effects = @import("hir_effects.zig");

const Analysis = hir_effects.Analysis;
const Error = hir_effects.Error;
const ResolvedTarget = hir_effects.ResolvedTarget;
const lambda_op = hir_effects.lambda_op;

/// `never` primitive test — the bottom type (Core §13.2). `hir_build` owns
/// the same predicate but imports this module, so it is inlined here.
fn isNeverType(t: meta.Type) bool {
    return switch (t) {
        .primitive => |k| k == .never,
        else => false,
    };
}

// -----------------------------------------------------------------
// `never_returns` must fact (docs/effects.md §10.1)
// -----------------------------------------------------------------

/// The function-level must fact `never_returns(f)` (docs/effects.md
/// §10.1): `f` has no normal return path — its declared return type
/// is `never`, or its body never normalizes. Solved as the **greatest
/// fixpoint** over the call graph: `never returns` is a coinductive
/// property, so `fn f() -> void { f() }` really never returns, and a
/// least fixpoint seeded `false` would miss it. Iteration starts from
/// "every function never returns" and decreases monotonically (the
/// transfer is monotone), stabilizing within `#funcs + 1` rounds. An
/// out-of-range id is `false`.
pub fn neverReturns(self: *Analysis, fid: hir.FuncId) Error!bool {
    try self.ensureNeverComputed();
    if (fid >= self.never_returns.len) return false;
    return self.never_returns[fid];
}

/// The structural `never` predicate on an expression subtree:
/// evaluating `id` never completes normally. A `never`-typed node
/// returns no value (Core §13.2); a strictly-evaluated operand that
/// never normalizes makes its parent never as well; an exhaustive
/// branch never normalizes only when every arm does; a `call` never
/// normalizes when every resolvable target does. Anything unproven is
/// `false` — the predicate is a must fact (取不到即 false).
///
/// Iterative post-order over the tree (no recursion: a deep `let`
/// chain is bounded by the heap, not the stack), memoized in
/// `never_memo` under one fixed `never_returns` approximation.
pub fn exprNever(self: *Analysis, id: hir.ExprId) Error!bool {
    try self.ensureNeverComputed();
    return self.exprNeverTree(id);
}

pub fn ensureNeverComputed(self: *Analysis) Error!void {
    if (self.never_computed) return;
    try self.computeNeverReturns();
}

pub fn computeNeverReturns(self: *Analysis) Error!void {
    const n = self.built.funcs.items.len;
    @memset(self.never_returns, true);
    if (n == 0) {
        self.never_computed = true;
        return;
    }
    const next = try self.arena.alloc(bool, n);
    var rounds: usize = 0;
    while (rounds <= n) : (rounds += 1) {
        // One Jacobi round: every body is evaluated against the same
        // approximation (`never_returns` is untouched until the
        // simultaneous assignment below).
        @memset(self.never_memo, null);
        for (0..n) |i| {
            const rec = self.built.funcs.items[i];
            var v = isNeverType(rec.ret);
            if (!v) {
                const regs = self.p().regionsOf(rec.root);
                if (regs.len > 0) v = try self.exprNeverTree(self.p().region(regs[0]).root);
            }
            next[i] = v;
        }
        var changed = false;
        for (0..n) |i| {
            if (next[i] != self.never_returns[i]) {
                self.never_returns[i] = next[i];
                changed = true;
            }
        }
        if (!changed) break;
    }
    // The fact is final now; drop the round-local memo so the public
    // queries memoize against it.
    @memset(self.never_memo, null);
    self.never_computed = true;
}

const NeverVisit = struct { id: hir.ExprId, expand: bool };

/// Memoized `exprNever` for `id`, filling the memo for its whole
/// subtree (children before parents).
pub fn exprNeverTree(self: *Analysis, root: hir.ExprId) Error!bool {
    const pr = self.p();
    if (root >= self.never_memo.len) return false;
    var stack = std.ArrayList(NeverVisit).empty;
    defer stack.deinit(self.arena);
    try stack.append(self.arena, .{ .id = root, .expand = false });
    while (stack.pop()) |it| {
        if (self.never_memo[it.id] != null) continue;
        if (it.expand) {
            self.never_memo[it.id] = try self.exprNeverOfNode(it.id);
            continue;
        }
        try stack.append(self.arena, .{ .id = it.id, .expand = true });
        for (pr.operands(it.id)) |op| if (op < self.never_memo.len) try stack.append(self.arena, .{ .id = op, .expand = false });
        for (pr.regionsOf(it.id)) |r| {
            const child = pr.region(r).root;
            if (child < self.never_memo.len) try stack.append(self.arena, .{ .id = child, .expand = false });
        }
    }
    return self.never_memo[root].?;
}

/// A node's memoized `exprNever`, `false` for a node appended after
/// this analysis was built (no entry yet — a later round re-analyzes).
pub fn neverMemoAt(self: *Analysis, id: hir.ExprId) bool {
    if (id >= self.never_memo.len) return false;
    return self.never_memo[id] orelse false;
}

pub fn exprNeverOfNode(self: *Analysis, id: hir.ExprId) Error!bool {
    const pr = self.p();
    const n = pr.node(id);
    if (isNeverType(n.ty)) return true;
    const name = hir.registry.get(n.op).name;
    // A λ value's creation runs no body: it is a normal value.
    if (std.mem.eql(u8, name, "lambda")) return false;
    const ops = pr.operands(id);
    const regs = pr.regionsOf(id);
    if (std.mem.eql(u8, name, "call")) {
        for (ops) |op| if (self.neverMemoAt(op)) return true;
        return self.callTargetsNever(id);
    }
    switch (hir.registry.get(n.op).policy) {
        // `if` / `and` / `or` / `match`: the head is strict, at most
        // one arm runs, so the node is never only when the head is
        // never or every arm independently never normalizes. (For
        // the short-circuit rows the constant arm always returns, so
        // this reduces to the head — sound and conservative.)
        .branch, .short_circuit, .match => {
            if (ops.len > 0 and self.neverMemoAt(ops[0])) return true;
            if (regs.len == 0) return false;
            for (regs) |r| if (!self.neverMemoAt(pr.region(r).root)) return false;
            return true;
        },
        // Every other op (including `let`) evaluates every operand
        // and region root eagerly, so any one never normalizing makes
        // the parent never normalizing.
        else => {
            for (ops) |op| if (self.neverMemoAt(op)) return true;
            for (regs) |r| if (self.neverMemoAt(pr.region(r).root)) return true;
            return false;
        },
    }
}

/// Whether every resolvable target of the call at `id` has the
/// `never_returns` fact. An unresolved callee, an empty target set,
/// or a target that may return is `false`.
pub fn callTargetsNever(self: *Analysis, id: hir.ExprId) Error!bool {
    const pr = self.p();
    const ops = pr.operands(id);
    if (ops.len == 0) return false;
    // An inline λ callee has no function record; its body is the fact.
    if (pr.node(ops[0]).op == lambda_op) {
        const regs = pr.regionsOf(ops[0]);
        if (regs.len == 0) return false;
        return self.neverMemoAt(pr.region(regs[0]).root);
    }
    var targets = std.ArrayList(ResolvedTarget).empty;
    defer targets.deinit(self.arena);
    if (!(try self.resolveTargets(ops[0], &targets))) return false;
    if (targets.items.len == 0) return false;
    for (targets.items) |t| {
        const nr = switch (t) {
            .func => |fid| if (fid < self.never_returns.len) self.never_returns[fid] else false,
            .host => |hb| self.hostNeverReturns(hb),
        };
        if (!nr) return false;
    }
    return true;
}

pub fn hostNeverReturns(self: *Analysis, hb: hir.HostBindingId) bool {
    if (hb >= self.built.hosts.items.len) return false;
    return switch (self.built.hosts.items[hb].signature) {
        .function => |f| isNeverType(f.ret.*),
        else => false,
    };
}
