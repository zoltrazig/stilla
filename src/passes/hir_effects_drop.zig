//! Drop/teardown seam of the HIR effect analysis (docs/effects.md
//! §11.1). The method bodies here were moved verbatim out of the driver
//! `passes/hir_effects.zig`, which keeps a `pub const` alias per method
//! so `an.<method>(...)` call syntax is unchanged for every consumer;
//! the docs live with each method body.
//!
//! This file owns the `drop_type` half of the unified dependency graph
//! (docs/effects.md §11.1): node discovery/edge construction
//! (`addDropNode` / `collectFunctionDrops` / `generateDropChildren`)
//! and the per-node transfer (`dropNodeTransfer`). The `function` half
//! and the single Kosaraju/Kleene solver live in
//! `passes/hir_effects_summary.zig`.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const effects = @import("stilla").effects;
const hir_effects = @import("hir_effects.zig");

const Analysis = hir_effects.Analysis;
const Error = hir_effects.Error;
const Summary = hir_effects.Summary;

const drop_op = hir_effects.drop_op;

/// Recursion bound for drop-type node generation (docs/effects.md
/// §11.1). Named-type recursion is cut by canonical identity (a repeat
/// key reuses its node and becomes an SCC edge); this cap is the safety
/// net for a non-regular instantiation chain whose summary falls back
/// to the conservative `Top` sink.
const max_drop_type_depth = 64;

fn isCopy(ty: meta.Type) ?bool {
    return if (ty.ownership()) |ow| ow == .copy else null;
}

/// Intern `ty` as a canonical `HIRTypeId`. A `.cleanup` occurrence
/// (CFG-only, never on an HIR node, hir.md §3.8) has no drop node and
/// materializes the `Top` sink instead.
fn internKey(self: *Analysis, ty: meta.Type) Error!?hir.HIRTypeId {
    return self.p().intern(ty) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedCleanupType => null,
    };
}

// -----------------------------------------------------------------
// Graph construction (docs/effects.md §11.1 node set / edge kinds)
// -----------------------------------------------------------------

/// Return the unified node for `ty`, creating it (and recursively its
/// structural successors) on first sight. A descent past
/// `max_drop_type_depth` — possible only for an uninhabited non-regular
/// instantiation chain — maps to the reserved `Top` sink, so the node
/// set stays finite and the failure-closed safety net is preserved.
/// `depth` counts the structural descent, not the SCC.
pub fn addDropNode(
    self: *Analysis,
    adj: *std.ArrayList(std.ArrayList(u32)),
    ty: meta.Type,
    depth: u32,
) Error!u32 {
    const key = (try internKey(self, ty)) orelse return self.top_sink_node;
    if (self.drop_node_of.get(key)) |node| return node;
    if (depth >= max_drop_type_depth) return self.top_sink_node;
    const node: u32 = @intCast(adj.items.len);
    try self.drop_node_of.put(self.arena, key, node);
    try self.drop_key_of_node.append(self.arena, key);
    try adj.append(self.arena, .empty);
    try generateDropChildren(self, adj, node, ty, depth);
    return node;
}

/// The structural destruction successors of one drop node
/// (docs/effects.md §11.1, mirroring the recursive drop walk):
/// Unique struct fields in reverse declaration order, tuple elements,
/// `list`/`box` inner, union payloads, and the type's own `drop` hook
/// as a `drop_type → function` edge.
fn generateDropChildren(
    self: *Analysis,
    adj: *std.ArrayList(std.ArrayList(u32)),
    node: u32,
    ty: meta.Type,
    depth: u32,
) Error!void {
    if (isCopy(ty)) |copy| if (copy) return;
    switch (ty) {
        .primitive, .module, .function, .cleanup, .param => return,
        .list, .box => |inner| {
            if (isCopy(inner.*) orelse (try self.isCopyType(inner.*))) return;
            const child = try self.addDropNode(adj, inner.*, depth + 1);
            try adj.items[node].append(self.arena, child);
        },
        .tuple => |elems| {
            for (elems) |e| {
                if (isCopy(e) orelse (try self.isCopyType(e))) continue;
                const child = try self.addDropNode(adj, e, depth + 1);
                try adj.items[node].append(self.arena, child);
            }
        },
        .named => |n| {
            if (n.id >= self.built.types.len) return;
            switch (self.built.types[n.id]) {
                .struct_ => |d| {
                    if (d.drop) |dn| if (self.findFuncByName(dn)) |fid| {
                        try adj.items[node].append(self.arena, fid);
                    };
                    for (d.fields) |f| {
                        const ft = meta.substParams(self.arena, d.type_params, n.args, f.type_);
                        if (isCopy(ft) orelse (try self.isCopyType(ft))) continue;
                        const child = try self.addDropNode(adj, ft, depth + 1);
                        try adj.items[node].append(self.arena, child);
                    }
                },
                .union_ => |d| for (d.variants) |v| for (v.payloads) |payload| {
                    const pt = meta.substParams(self.arena, d.type_params, n.args, payload);
                    if (isCopy(pt) orelse (try self.isCopyType(pt))) continue;
                    const child = try self.addDropNode(adj, pt, depth + 1);
                    try adj.items[node].append(self.arena, child);
                },
                .opaque_, .unknown => {},
            }
        },
    }
}

/// Every `drop_type` a function's evaluated subtree destroys
/// (docs/effects.md §11.1, edge kind 2): the operand types of explicit
/// `drop` nodes **and** the types of cleanup tokens whose `origin_expr`
/// lies in the body. λ bodies are deferred to their own function record,
/// mirroring `cleanupEffect`'s subtree walk. Edges are appended at
/// `caller` (re-read after each `addDropNode`, which may grow `adj`).
pub fn collectFunctionDrops(
    self: *Analysis,
    fid: hir.FuncId,
    adj: *std.ArrayList(std.ArrayList(u32)),
    caller: u32,
) Error!void {
    const pr = self.p();
    var in_subtree = std.AutoHashMapUnmanaged(hir.ExprId, void).empty;
    defer in_subtree.deinit(self.arena);
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(self.arena);
    // Start at the body region root, not the λ record: the record's only
    // region *is* the body, while a nested λ is deferred to its own
    // function record (mirroring `cleanupEffect`).
    const regions = pr.regionsOf(self.built.funcs.items[fid].root);
    if (regions.len == 0) return;
    try work.append(self.arena, pr.region(regions[0]).root);
    while (work.pop()) |cur| {
        try in_subtree.put(self.arena, cur, {});
        const n = pr.node(cur);
        if (hir.registry.get(n.op).transfer == .lambda) continue; // deferred to the call
        if (n.op == drop_op) {
            const ops = pr.operands(cur);
            if (ops.len > 0) {
                const child = try self.addDropNode(adj, pr.typeOf(pr.node(ops[0]).ty), 0);
                try adj.items[caller].append(self.arena, child);
            }
        }
        for (pr.operands(cur)) |op| try work.append(self.arena, op);
        for (pr.regionsOf(cur)) |r| try work.append(self.arena, pr.region(r).root);
    }
    // The subtree's registered destruction footprint: full-expression
    // temporaries and scope-end bindings. `cleanupEffect` selects them by
    // exactly this membership test.
    for (pr.cleanup_tokens.items) |tk| {
        if (!in_subtree.contains(tk.origin_expr)) continue;
        const child = try self.addDropNode(adj, pr.typeOf(tk.ty), 0);
        try adj.items[caller].append(self.arena, child);
    }
}

/// The explicit `drop` operand types inside a module-constant
/// initializer. Constants are not dependency-graph nodes, so these
/// nodes carry no incoming edge; they exist so `effectOf`/teardown
/// lookups resolve through the unified store rather than the fallback.
pub fn collectConstDrops(
    self: *Analysis,
    root: hir.ExprId,
    adj: *std.ArrayList(std.ArrayList(u32)),
) Error!void {
    const pr = self.p();
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(self.arena);
    try work.append(self.arena, root);
    while (work.pop()) |cur| {
        const n = pr.node(cur);
        if (hir.registry.get(n.op).transfer == .lambda) continue;
        if (n.op == drop_op) {
            const ops = pr.operands(cur);
            if (ops.len > 0) _ = try self.addDropNode(adj, pr.typeOf(pr.node(ops[0]).ty), 0);
        }
        for (pr.operands(cur)) |op| try work.append(self.arena, op);
        for (pr.regionsOf(cur)) |r| try work.append(self.arena, pr.region(r).root);
    }
}

// -----------------------------------------------------------------
// Drop-type transfer (docs/effects.md §11.1)
// -----------------------------------------------------------------

/// The transfer of one `drop_type` node: its type's hook summary
/// sequenced with the structural destruction of its Unique fields,
/// where every child reads the **unified** node value (in-progress for
/// the same SCC, finalized otherwise). The type-identity cut of the
/// old recursion is now expressed by the SCC: a cyclic type reads its
/// own in-progress value, seeded `pure`.
pub fn dropNodeTransfer(self: *Analysis, node: u32) Error!Summary {
    const key = self.drop_key_of_node.items[node];
    return dropStructural(self, self.p().typeOf(key));
}

fn dropStructural(self: *Analysis, ty: meta.Type) Error!Summary {
    if (isCopy(ty)) |copy| if (copy) return effects.pure;
    switch (ty) {
        .primitive => |k| return if (k == .any or k == .hostdata) self.eng.top() else effects.pure,
        .module, .function, .cleanup => return effects.pure,
        .list, .box => |inner| return dropChildValue(self, inner.*),
        .tuple => |elems| {
            var acc = effects.pure;
            var i = elems.len;
            while (i > 0) {
                i -= 1;
                acc = try self.eng.sequence(acc, try dropChildValue(self, elems[i]));
            }
            return acc;
        },
        .param => return self.eng.top(),
        .named => |n| {
            if (n.id >= self.built.types.len) return self.eng.top();
            switch (self.built.types[n.id]) {
                .struct_ => |d| {
                    var acc = effects.pure;
                    if (d.drop) |dn| {
                        if (self.findFuncByName(dn)) |fid| acc = try self.eng.sequence(acc, try self.functionSummary(fid));
                    }
                    var i = d.fields.len;
                    while (i > 0) {
                        i -= 1;
                        const ft = meta.substParams(self.arena, d.type_params, n.args, d.fields[i].type_);
                        if (isCopy(ft) orelse (try self.isCopyType(ft))) continue;
                        acc = try self.eng.sequence(acc, try dropChildValue(self, ft));
                    }
                    return acc;
                },
                .union_ => |d| {
                    var acc = effects.pure;
                    for (d.variants) |v| {
                        var vsum = effects.pure;
                        var i = v.payloads.len;
                        while (i > 0) {
                            i -= 1;
                            const pt = meta.substParams(self.arena, d.type_params, n.args, v.payloads[i]);
                            if (isCopy(pt) orelse (try self.isCopyType(pt))) continue;
                            vsum = try self.eng.sequence(vsum, try dropChildValue(self, pt));
                        }
                        acc = try self.eng.join(acc, vsum);
                    }
                    return acc;
                },
                .opaque_ => |d| return self.hostRelease(d.host_id),
                .unknown => return self.eng.top(),
            }
        },
    }
}

/// The unified value of one structural child type. A Copy child is
/// `pure` and has no node; every other child was created during graph
/// construction, so the lookup is a single map hit. A type outside the
/// graph (only reachable from an on-demand public query) falls back to
/// the recursive computation over finalized summaries.
fn dropChildValue(self: *Analysis, ty: meta.Type) Error!Summary {
    if (isCopy(ty)) |copy| if (copy) return effects.pure;
    if (self.p().type_map.get(ty)) |key| {
        if (self.drop_node_of.get(key)) |child| return self.nodeValue(child);
    }
    return self.dropEffectFree(ty);
}

// -----------------------------------------------------------------
// Public surface
// -----------------------------------------------------------------

/// `drop_effect(T)` (docs/effects.md §11.1). Reads the unified drop
/// store when `T` is a graph node (the production path — including the
/// cleanup-token and teardown callers), otherwise computes the same
/// structural chain on demand over finalized summaries.
pub fn dropEffectOf(self: *Analysis, ty: meta.Type) Error!Summary {
    if (self.p().type_map.get(ty)) |key| {
        if (self.drop_node_of.get(key)) |node| return self.nodeValue(node);
    }
    return self.dropEffectFree(ty);
}

/// `dropSummary(key)` (docs/effects.md §11.1): the interned drop
/// summary for a canonical type key. The type-keyed store landing here
/// is the interning deferred from the `HIRTypeId` canonicalization.
pub fn dropSummary(self: *Analysis, key: hir.HIRTypeId) Error!Summary {
    if (self.drop_node_of.get(key)) |node| return self.nodeValue(node);
    return self.dropEffectFree(self.p().typeOf(key));
}

/// The recursive structural `drop_effect(T)` of the pre-unification
/// implementation, kept as the on-demand fallback for a type outside
/// the dependency graph. Named-type recursion is cut by structural
/// identity on the single descent; no result is memoized (a value
/// computed while a cycle was cut is an under-approximation).
pub fn dropEffectFree(self: *Analysis, ty: meta.Type) Error!Summary {
    var visiting = std.ArrayList(meta.Type).empty;
    defer visiting.deinit(self.arena);
    return dropEffectFreeInner(self, ty, &visiting);
}

fn dropEffectFreeInner(self: *Analysis, ty: meta.Type, visiting: *std.ArrayList(meta.Type)) Error!Summary {
    if (isCopy(ty)) |copy| if (copy) return effects.pure;
    switch (ty) {
        .primitive => |k| return if (k == .any or k == .hostdata) self.eng.top() else effects.pure,
        .module, .function, .cleanup => return effects.pure,
        .list, .box => |inner| return dropEffectFreeInner(self, inner.*, visiting),
        .tuple => |elems| {
            var acc = effects.pure;
            var i = elems.len;
            while (i > 0) {
                i -= 1;
                acc = try self.eng.sequence(acc, try dropEffectFreeInner(self, elems[i], visiting));
            }
            return acc;
        },
        .param => return self.eng.top(),
        .named => |n| {
            for (visiting.items) |v| if (meta.Type.eql(v, ty)) return effects.pure;
            if (visiting.items.len >= max_drop_type_depth) return self.eng.top();
            if (n.id >= self.built.types.len) return self.eng.top();
            try visiting.append(self.arena, ty);
            defer {
                _ = visiting.pop();
            }
            switch (self.built.types[n.id]) {
                .struct_ => |d| {
                    var acc = effects.pure;
                    if (d.drop) |dn| {
                        if (self.findFuncByName(dn)) |fid| acc = try self.eng.sequence(acc, try self.functionSummary(fid));
                    }
                    var i = d.fields.len;
                    while (i > 0) {
                        i -= 1;
                        const ft = meta.substParams(self.arena, d.type_params, n.args, d.fields[i].type_);
                        if (try self.isCopyType(ft)) continue;
                        acc = try self.eng.sequence(acc, try dropEffectFreeInner(self, ft, visiting));
                    }
                    return acc;
                },
                .union_ => |d| {
                    var acc = effects.pure;
                    for (d.variants) |v| {
                        var vsum = effects.pure;
                        var i = v.payloads.len;
                        while (i > 0) {
                            i -= 1;
                            const pt = meta.substParams(self.arena, d.type_params, n.args, v.payloads[i]);
                            if (try self.isCopyType(pt)) continue;
                            vsum = try self.eng.sequence(vsum, try dropEffectFreeInner(self, pt, visiting));
                        }
                        acc = try self.eng.join(acc, vsum);
                    }
                    return acc;
                },
                .opaque_ => |d| return self.hostRelease(d.host_id),
                .unknown => return self.eng.top(),
            }
        },
    }
}
