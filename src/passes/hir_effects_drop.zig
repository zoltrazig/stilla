//! Drop/teardown seam of the HIR effect analysis (docs/effects.md
//! §11.1). The method bodies here were moved verbatim out of the driver
//! `passes/hir_effects.zig`, which keeps a `pub const` alias per method
//! so `an.<method>(...)` call syntax is unchanged for every consumer;
//! the docs live with each method body.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const effects = @import("stilla").effects;
const hir_effects = @import("hir_effects.zig");

const Analysis = hir_effects.Analysis;
const Error = hir_effects.Error;
const Summary = hir_effects.Summary;

/// Recursion bound for the `drop_effect` type walk (docs/effects.md
/// §11.1). Named-type recursion is cut by identity; this cap is the
/// safety net for an uninhabited non-regular instantiation chain, whose
/// summary falls back to the conservative `Top`.
const max_drop_type_depth = 64;

// -----------------------------------------------------------------
// effect_transfer (docs/effects.md §6.1)
// -----------------------------------------------------------------

// -----------------------------------------------------------------
// Precise drop_effect(T) (docs/effects.md §11.1)
// -----------------------------------------------------------------

/// `drop_effect(T)` — the interaction of destroying a value of type
/// `ty`: the type's `drop` hook first, then its Unique fields in
/// reverse declaration order, structurally through containers, and
/// `Release` for host-backed opaque handles.
///
/// Recursive types (a struct/union that reaches itself through a
/// field) are solved as the least fixpoint of the destruction
/// function: re-entering a type on the descent returns `pure`
/// (lattice bottom). Because the may-summary of a cycle is the join
/// over its finite unfoldings and joining the same accesses twice is
/// idempotent, that bottom-on-reentry yields exactly the least
/// fixpoint without an explicit iteration (docs/effects.md §11.1).
/// No result is memoized: a value computed while a cycle was cut is
/// an under-approximation that must not be reused at the top level.
pub fn dropEffectOf(self: *Analysis, ty: meta.Type) Error!Summary {
    var visiting = std.ArrayList(meta.Type).empty;
    defer visiting.deinit(self.arena);
    return self.dropEffectInner(ty, &visiting);
}

pub fn dropEffectInner(self: *Analysis, ty: meta.Type, visiting: *std.ArrayList(meta.Type)) Error!Summary {
    // A Copy value's destruction has no interaction (§11.1), and a
    // Copy result short-circuits regardless of structure. A *stuck*
    // ownership (null) is not Copy: fall through to the structural
    // case, which is where `named`/`param` recursion lives.
    if (ty.ownership()) |ow| if (ow == .copy) return effects.pure;
    switch (ty) {
        .primitive => |k| return if (k == .any or k == .hostdata) self.eng.top() else effects.pure,
        .module, .function, .cleanup => return effects.pure,
        .list, .box => |inner| return self.dropEffectInner(inner.*, visiting),
        .tuple => |elems| {
            var acc = effects.pure;
            var i = elems.len;
            while (i > 0) {
                i -= 1;
                acc = try self.eng.sequence(acc, try self.dropEffectInner(elems[i], visiting));
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
                        acc = try self.eng.sequence(acc, try self.dropEffectInner(ft, visiting));
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
                            vsum = try self.eng.sequence(vsum, try self.dropEffectInner(pt, visiting));
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

/// The drop hook functions reachable from `ty` (the type's own hook
/// plus every field/element hook), used to add the correct edges to
/// the call graph so a hook's summary is solved before the `drop`
/// that depends on it.
pub fn collectTypeHooks(
    self: *Analysis,
    ty: meta.Type,
    visiting: *std.ArrayList(meta.Type),
    out: *std.ArrayList(hir.FuncId),
) Error!void {
    if (ty.ownership()) |ow| if (ow == .copy) return;
    switch (ty) {
        .list, .box => |inner| try self.collectTypeHooks(inner.*, visiting, out),
        .tuple => |elems| for (elems) |e| try self.collectTypeHooks(e, visiting, out),
        .primitive, .module, .function, .cleanup, .param => {},
        .named => |n| {
            // Full-instantiation key: an instantiation is the identity
            // (a type argument that changes on unrolling is a distinct
            // node in the type graph). The depth cap is the safety net
            // for an uninhabited non-regular instantiation chain.
            for (visiting.items) |v| if (meta.Type.eql(v, ty)) return;
            if (visiting.items.len >= max_drop_type_depth) return;
            if (n.id >= self.built.types.len) return;
            try visiting.append(self.arena, ty);
            defer {
                _ = visiting.pop();
            }
            switch (self.built.types[n.id]) {
                .struct_ => |d| {
                    if (d.drop) |dn| {
                        if (self.findFuncByName(dn)) |fid| {
                            if (!std.mem.containsAtLeastScalar(hir.FuncId, out.items, 1, fid)) try out.append(self.arena, fid);
                        }
                    }
                    for (d.fields) |f| try self.collectTypeHooks(meta.substParams(self.arena, d.type_params, n.args, f.type_), visiting, out);
                },
                .union_ => |d| for (d.variants) |v| for (v.payloads) |payload| try self.collectTypeHooks(meta.substParams(self.arena, d.type_params, n.args, payload), visiting, out),
                .opaque_, .unknown => {},
            }
        },
    }
}
