//! Part of the AST→HIR builder (docs/effects.md §11.2; driver:
//! `hir_build.zig`): full-expression cleanup registration.
//!
//! After every function body and constant initializer is built, this pass
//! walks each root once and (a) gives every *statement / initializer*
//! full expression its own identity, and (b) registers a `CleanupToken`
//! for each Unique value the builder knows is a full-expression
//! temporary — a value that owns destruction at the end of its full
//! expression (reverse creation order).
//!
//! **What is a temporary.** Only value-producing nodes (`call`,
//! aggregate makers, `any_pack` / `any_cast`, …) that own a Unique
//! result and are *not* transferred qualify. The pass tracks transfer
//! context down the tree:
//!
//! - an operand consumed by its parent (`Consume` occurrence — a `move`,
//!   a `move`/plain-Unique call argument, a bound `let` initializer, an
//!   aggregate element, a consuming `match` scrutinee) is transferred,
//!   not destroyed here;
//! - `seq`'s first operand is a discarded statement (its own full
//!   expression); `seq`'s rest, a `let` region body and `if` / `and` /
//!   `or` / `match` region bodies *forward* their value to the enclosing
//!   node, so the owner is the innermost producing node — never the
//!   forwarding node (`seq` / `let` / branch results do not duplicate
//!   the owner);
//! - the root of a body (function return, constant value) escapes.
//!
//! **Full expressions.** A `seq` statement operand and a `let`
//! initializer are full expressions of their own; their temporaries are
//! registered with an independent `registration_index` (creation order
//! within that FE). Region bodies and the `seq` rest continue the
//! enclosing FE.
//!
//! **Fail closed.** The pass always completes and sets
//! `Program.cleanup_modeled`; an unknown ownership class makes the
//! token's `drop_effect(T)` `Top` and the query fails closed. A program
//! that never ran this pass keeps `cleanup_modeled = false`, so its
//! empty token table is *unmodelled*, not a proof of safety.
//!
//! Region bindings and any construct this pass does not classify are
//! *not* modelled here — scope-end Unique destruction stays unmodelled
//! and `hir_effects.cleanupEffect` returns `Top` for a subtree that owns
//! one.
//!
//! Ownership and operand-use classification reuse the effect analysis'
//! own resolvers (`Analysis.capabilityOf` / `operandUseOf`), so the
//! builder registers with exactly the mapping the queries later consult.

const std = @import("std");
const hir = @import("stilla").hir;
const hir_build = @import("hir_build.zig");
const hir_effects = @import("hir_effects.zig");

/// Walk every function body and constant initializer and register its
/// cleanup tokens. Call once after all bodies are built (the driver does).
pub fn register(b: *hir_build.Builder) !void {
    const pr = &b.built.program;
    var an = try hir_effects.Analysis.init(b.arena, b.built, .{ .graph = b.graph });
    for (b.built.funcs.items) |rec| {
        const fe = try pr.addFullExpr();
        var counter: u32 = 0;
        try walkFuncRoot(&an, rec.root, fe, &counter);
    }
    for (b.built.consts.items) |c| {
        const root = c.init orelse continue;
        const fe = try pr.addFullExpr();
        var counter: u32 = 0;
        try walk(&an, root, fe, &counter, .escapes);
    }
    pr.cleanup_modeled = true;
}

/// A function record root is a `lambda` node whose region body is the
/// returned expression: the body is a full expression, and the root
/// result escapes (it is the return value). The `lambda` root itself
/// carries its body's FE so every node has a real boundary id (FE 0
/// stays the seeded default; nothing belongs to it by construction).
fn walkFuncRoot(an: *hir_effects.Analysis, root: hir.ExprId, fe: hir.FullExprId, counter: *u32) !void {
    const pr = &an.built.program;
    if (!std.mem.eql(u8, hir.registry.get(pr.node(root).op).name, "lambda")) {
        return walk(an, root, fe, counter, .escapes);
    }
    pr.exprs.items[root].full_expr = fe;
    for (pr.regionsOf(root)) |r| {
        try walk(an, pr.region(r).root, fe, counter, .escapes);
    }
}

/// Whether a node's owned Unique result is destroyed at its full
/// expression's end (`temp`) or transferred away / returned (`escapes`).
const Context = enum { temp, escapes };

fn walk(an: *hir_effects.Analysis, id: hir.ExprId, fe: hir.FullExprId, counter: *u32, ctx: Context) !void {
    const pr = &an.built.program;
    // Node-level FE annotation (hir.md §5.6): the boundary this visit is
    // splitting under is the node's own full expression. Operands that
    // open a nested FE (`seq` statement, `let` initializer) recurse with
    // their own id below, overwriting this; region bodies forward and
    // stay in this FE.
    pr.exprs.items[id].full_expr = fe;
    const n = pr.node(id);
    const name = hir.registry.get(n.op).name;

    if (std.mem.eql(u8, name, "seq")) {
        const ops = pr.operands(id);
        // Operand 0 is a discarded statement expression: its own FE.
        if (ops.len > 0) {
            const sfe = try pr.addFullExpr();
            var scount: u32 = 0;
            try walk(an, ops[0], sfe, &scount, .temp);
        }
        // Operand 1 (the rest) forwards its value to the enclosing node.
        if (ops.len > 1) try walk(an, ops[1], fe, counter, ctx);
    } else if (std.mem.eql(u8, name, "let")) {
        const ops = pr.operands(id);
        // The initializer is its own full expression and is consumed by
        // the binder (never a registered temporary of its own).
        if (ops.len > 0) {
            const ife = try pr.addFullExpr();
            var icount: u32 = 0;
            try walk(an, ops[0], ife, &icount, .escapes);
        }
        // The region body forwards its value to the `let`.
        for (pr.regionsOf(id)) |r| try walk(an, pr.region(r).root, fe, counter, ctx);
    } else {
        const ops = pr.operands(id);
        for (ops, 0..) |op, i| {
            const use = try an.operandUseOf(id, i);
            try walk(an, op, fe, counter, if (use == .consume) .escapes else .temp);
        }
        // Region bodies (if / and / or / match / …) forward their value.
        for (pr.regionsOf(id)) |r| try walk(an, pr.region(r).root, fe, counter, ctx);
    }

    // Creation order is children-then-parent: register this node's own
    // temporary last, so its registration_index is the largest among its
    // operands' (destroyed first, as its destruction is registered last).
    if (ctx == .temp and isCreator(name) and pr.viewOf(id) == .owned) {
        const cap = try an.capabilityOf(n.ty) orelse .unique;
        if (cap == .unique) {
            _ = try pr.addCleanupToken(id, n.ty, fe, counter.*);
            counter.* += 1;
        }
    }
}

/// A value-producing node that can own a Unique result. Forwarding,
/// transfer, binding, and non-value ops never carry their own owner.
fn isCreator(name: []const u8) bool {
    const non_creators = [_][]const u8{
        "const", "local", "fn_ref", "module_const", "lambda",
        "let",   "seq",   "if",     "and",          "or",
        "match", "move",  "borrow", "drop",         "panic",
    };
    for (non_creators) |x| {
        if (std.mem.eql(u8, name, x)) return false;
    }
    return true;
}
