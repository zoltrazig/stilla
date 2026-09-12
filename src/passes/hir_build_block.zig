//! Part of the AST→HIR builder (hir.md §5.2; driver:
//! `hir_build.zig`): blocks and statements canonicalize onto nested
//! `let` regions and `seq`s, plus `using`/`drop` statements and the
//! binder-read helpers the other builder files share.

const std = @import("std");
const ast = @import("stilla").ast;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const hir_build = @import("hir_build.zig");
const hir_build_expr = @import("hir_build_expr.zig");
const hir_build_call = @import("hir_build_call.zig");
const hir_build_pattern = @import("hir_build_pattern.zig");

// ---------------------------------------------------------------------------
// Blocks and statements → let/seq canonical trees (hir.md §5.2)
// ---------------------------------------------------------------------------

/// Canonicalize one block: statements fold onto nested `let` regions and
/// `seq`s; the block's value is its final expression, or void when there
/// is none.
pub fn buildBlock(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, blk: *const ast.Block) hir_build.BuildError!hir.ExprId {
    // The result expression must be addressed *inside the original
    // block*: checker side tables are keyed by AST node address, so a
    // by-value copy would lose every annotation (types, call_of,
    // spec_of) of the block's tail expression.
    const result: ?*const ast.Expr = if (blk.result) |*r| r else null;
    return buildStmts(b, info, blk.stmts, 0, result);
}

fn buildStmts(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, stmts: []const ast.Stmt, i: usize, result: ?*const ast.Expr) hir_build.BuildError!hir.ExprId {
    if (i >= stmts.len) {
        return if (result) |r| hir_build_expr.buildExpr(b, info, r) else hir_build_expr.voidLiteral(b, meta.Span.init(0, 0, 0));
    }
    const stmt = &stmts[i];
    switch (stmt.*) {
        .empty => return buildStmts(b, info, stmts, i + 1, result),
        .using => |*u| return buildUsing(b, info, u, stmts, i, result),
        .expr => |*es| {
            const e = try hir_build_expr.buildExpr(b, info, &es.expr);
            // A diverging statement (never) short-circuits the rest.
            if (hir_build.isNever(b.built.program.node(e).ty)) return e;
            const rest = try buildStmts(b, info, stmts, i + 1, result);
            return seq2(b, es.span, e, rest);
        },
        .drop => |*ds| return buildDropStmt(b, info, ds, stmts, i, result),
        .let => |*ls| return buildLet(b, info, ls, stmts, i, result),
    }
}

/// `seq(e, rest)`: evaluate `e` (discarding its value), then `rest`;
/// the sequence's value is `rest`'s.
fn seq2(b: *hir_build.Builder, span: meta.Span, e: hir.ExprId, rest: hir.ExprId) hir_build.BuildError!hir.ExprId {
    const rest_ty = b.built.program.node(rest).ty;
    const ops = try b.built.program.addOperands(&.{ e, rest });
    return b.built.program.addExpr(.{ .op = try b.op(span, "seq"), .ty = rest_ty, .operands = ops });
}

/// Block-level `using` alias: a module-valued alias registers a compile-
/// time name (no runtime value); a value-member alias is bound once as a
/// let leaf (mirroring cfg `lowerUsing`'s bind-once) so the rest of the
/// block resolves through the single load. Type aliases bind nothing.
fn buildUsing(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, u: *const ast.UsingDecl, stmts: []const ast.Stmt, i: usize, result: ?*const ast.Expr) hir_build.BuildError!hir.ExprId {
    const alias = u.alias orelse return buildStmts(b, info, stmts, i + 1, result);
    // Resolve the alias target like the module graph's alias pass: the
    // written path's final segment names the member; resolve the path's
    // first segment as a module value / member.
    const target = try resolveAlias(b, info, u);
    switch (target) {
        .module => |spec| {
            try b.pushModuleAlias(alias.text, spec);
            const out = try buildStmts(b, info, stmts, i + 1, result);
            _ = b.module_aliases.pop();
            return out;
        },
        .value => |*mr| {
            // Bind once: a let leaf whose value is the member.
            const leaf = try hir_build_call.memberLeaf(b, info, mr.module, mr.name, u.span, true);
            return letChain(b, info, u.span, &.{.{ .name = alias.text }}, leaf, stmts, i + 1, result);
        },
        .type => return buildStmts(b, info, stmts, i + 1, result),
    }
}

const AliasTarget = union(enum) {
    module: []const u8,
    value: moduleinfo.MemberRef,
    type: void,
};

/// Resolve a `using` decl's target (module-scope alias semantics): the
/// path's first segment names a module value, a member, or a using
/// alias; later segments chain module-valued members.
fn resolveAlias(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, u: *const ast.UsingDecl) hir_build.BuildError!AliasTarget {
    const path = u.path;
    // Single or dotted; the alias names the final segment by default.
    var spec: ?[]const u8 = info.specifier; // module context walk
    var mod = info;
    var k: usize = 0;
    // First segment: module value / alias / member.
    const first = path[0].text;
    if (info.module_values.get(first)) |s0| {
        mod = b.graph.module(s0) orelse return b.fail(u.span, "'{s}' does not name a loaded module", .{first});
        spec = s0;
        k = 1;
    } else if (b.aliasModule(first)) |s0| {
        mod = b.graph.module(s0) orelse return b.fail(u.span, "'{s}' does not name a loaded module", .{first});
        k = 1;
    } else if (info.valueMember(first)) |vm| {
        if (vm.module_spec) |s0| {
            mod = b.graph.module(s0) orelse return b.fail(u.span, "'{s}' does not name a loaded module", .{first});
            k = 1;
        }
        // else: a value member of the current module? A `using` target
        // of a plain local member is unusual; treat as value below.
    } else {
        return b.fail(u.span, "cannot resolve using alias '{s}'", .{u.path[u.path.len - 1].text});
    }
    if (k == path.len) {
        // Alias of a module: the name bound is a module value.
        return .{ .module = spec.? };
    }
    // Member chain: intermediate segments must be module-valued members.
    while (k < path.len - 1) : (k += 1) {
        const vm = mod.valueMember(path[k].text) orelse
            return b.fail(path[k].span, "module '{s}' has no member '{s}'", .{ mod.specifier, path[k].text });
        if (vm.module_spec) |s1| {
            mod = b.graph.module(s1) orelse return b.fail(path[k].span, "module '{s}' is not loaded", .{s1});
        } else {
            return b.fail(path[k].span, "'{s}' is not a module value", .{path[k].text});
        }
    }
    const tail = path[path.len - 1];
    if (mod.typeMember(tail.text) != null) return .{ .type = {} };
    if (mod.valueMember(tail.text) != null) {
        return .{ .value = .{ .module = mod.specifier, .name = tail.text } };
    }
    // A module-level using alias of this module chain.
    if (mod.alias(tail.text)) |a| {
        return switch (a.target) {
            .module => |s2| .{ .module = s2 },
            .value => |mr| .{ .value = mr },
            .type => .{ .type = {} },
        };
    }
    return b.fail(tail.span, "module '{s}' has no member '{s}'", .{ mod.specifier, tail.text });
}

/// Bind a fresh identifier binder for `name` over `init_value` and
/// build the continuation `rest` in the extended scope.
fn letChain(
    b: *hir_build.Builder,
    info: *moduleinfo.ModuleInfo,
    span: meta.Span,
    names: []const LetName,
    init: hir.ExprId,
    stmts: []const ast.Stmt,
    i: usize,
    result: ?*const ast.Expr,
) hir_build.BuildError!hir.ExprId {
    const init_ty = b.built.program.node(init).ty;
    var ids = std.ArrayList(hir.BinderId).empty;
    for (names) |n| {
        const ty = n.ty orelse init_ty;
        const mode: hir.BinderMode = if (n.moving) .move else .value;
        const bind = try b.built.program.addBinder(ty, mode);
        try ids.append(b.arena, bind);
    }
    try b.pushScope();
    for (names, ids.items) |n, bind| try b.bindName(n.name, bind);
    const rest = try buildStmts(b, info, stmts, i, result);
    b.popScope();
    return letNode(b, span, init, ids.items, rest);
}

const LetName = struct {
    name: []const u8,
    ty: ?meta.Type = null,
    moving: bool = false,
};

/// One `let` node: init operand outside the region, region params bound
/// for the body (the source-canonical `let x = e in body`).
pub fn letNode(b: *hir_build.Builder, span: meta.Span, init: hir.ExprId, binder_ids: []const hir.BinderId, body: hir.ExprId) hir_build.BuildError!hir.ExprId {
    const ops = try b.built.program.addOperands(&.{init});
    const rid = try b.built.program.addRegion(binder_ids, body, null);
    const regs = try b.built.program.addRegions(&.{rid});
    const ty = b.built.program.node(body).ty;
    return b.built.program.addExpr(.{ .op = try b.op(span, "let"), .ty = ty, .operands = ops, .regions = regs });
}

/// A `let` statement. Irrefutable patterns only (the checker rejects
/// refutable ones). Identifier patterns bind one binder typed by the
/// declared type or the init's value type. Destructuring patterns put
/// the irrefutable pattern on the let region (params = binding leaves;
/// consuming `move` initializers give `.move`-mode leaves, non-consuming
/// views give `.borrow`-mode leaves) — the §5.2/§10.1 amendment.
fn buildLet(
    b: *hir_build.Builder,
    info: *moduleinfo.ModuleInfo,
    ls: *const ast.LetStmt,
    stmts: []const ast.Stmt,
    i: usize,
    result: ?*const ast.Expr,
) hir_build.BuildError!hir.ExprId {
    const moving = isMoveExpr(ls.init);
    const init = try hir_build_expr.buildExpr(b, info, ls.init);
    // `let _ = expr`: discard the value (drop at the FE, S5); the rest
    // of the block continues in the same scope.
    if (ls.pattern == .wildcard) {
        return seq2(b, ls.span, init, try buildStmts(b, info, stmts, i + 1, result));
    }
    const init_ty = b.built.program.node(init).ty;
    // Single identifier leaf: the common `let x = …` (region pattern
    // null, one param) — the §5.2 canonical form.
    if (identPatternLeaf(&ls.pattern)) |name| {
        const declared = if (ls.type_) |*dt| try b.resolveType(info, dt) else null;
        var names: [1]LetName = .{.{ .name = name, .ty = declared, .moving = moving }};
        return letChain(b, info, ls.span, &names, init, stmts, i + 1, result);
    }
    if (ls.type_ != null) return b.fail(ls.span, "a type annotation on a destructuring let is unsupported", .{});
    // Destructuring: pattern on the region, leaves as params. The leaf
    // types derive from the scrutinee type and the pattern shape.
    var binder_ids = std.ArrayList(hir.BinderId).empty;
    const pat_id = try hir_build_pattern.buildPattern(b, info, &ls.pattern, init_ty, moving, &binder_ids);
    try b.pushScope();
    // Names are bound in the same order the pattern's leaves were
    // created; buildPattern recorded them in `binder_ids` (arena order).
    // The source name of each leaf is recovered from the pattern AST
    // below — see bindPatternLeaves.
    try hir_build_pattern.bindPatternLeaves(b, &ls.pattern, binder_ids.items);
    const body = try buildStmts(b, info, stmts, i + 1, result);
    b.popScope();
    // Region pattern: irrefutable destructure on the let region.
    const ops = try b.built.program.addOperands(&.{init});
    const rid = try b.built.program.addRegion(binder_ids.items, body, pat_id);
    const regs = try b.built.program.addRegions(&.{rid});
    const ty = b.built.program.node(body).ty;
    return b.built.program.addExpr(.{ .op = try b.op(ls.span, "let"), .ty = ty, .operands = ops, .regions = regs });
}

/// The identifier bound by a plain identifier pattern (`p` with no
/// tail), or null for every other shape.
fn identPatternLeaf(p: *const ast.Pattern) ?[]const u8 {
    switch (p.*) {
        .path => |pp| if (pp.path.len == 1 and pp.tail == .none) return pp.path[0].text,
        else => {},
    }
    return null;
}

pub fn isMoveExpr(e: *const ast.Expr) bool {
    var ex = e;
    while (ex.* == .paren) ex = ex.paren.inner;
    return ex.* == .move;
}

/// A `drop` statement: `drop x` of an owned local (mirror cfg
/// `lowerDrop`'s borrow rejection).
fn buildDropStmt(
    b: *hir_build.Builder,
    info: *moduleinfo.ModuleInfo,
    ds: *const ast.DropStmt,
    stmts: []const ast.Stmt,
    i: usize,
    result: ?*const ast.Expr,
) hir_build.BuildError!hir.ExprId {
    const bind = b.lookup(ds.name.text) orelse
        return b.fail(ds.span, "drop of unknown binding '{s}'", .{ds.name.text});
    const mode = b.built.program.binders.items[bind].mode;
    if (mode == .borrow) {
        return b.fail(ds.span, "cannot drop borrowed binding '{s}'", .{ds.name.text});
    }
    const local = try localNode(b, info, bind);
    const ops = try b.built.program.addOperands(&.{local});
    const drop = try b.built.program.addExpr(.{ .op = try b.op(ds.span, "drop"), .ty = .{ .primitive = .void }, .operands = ops });
    const rest = try buildStmts(b, info, stmts, i + 1, result);
    return seq2(b, ds.span, drop, rest);
}

/// A `local` read of a binder.
pub fn localNode(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, bind: hir.BinderId) hir_build.BuildError!hir.ExprId {
    const ty = b.built.program.binders.items[bind].ty;
    return b.built.program.addExpr(.{ .op = try b.op(meta.Span.init(0, 0, 0), "local"), .ty = ty, .payload = .{ .binder = bind }, .sema = try viewOf(b, info, ty, bind, .read) });
}

/// A binder's created-state view: params arrive owned (except borrow
/// params); reads off a `.borrow`-mode binder are borrowed.
fn viewOf(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, ty: meta.Type, bind: hir.BinderId, context: enum { read, value }) hir_build.BuildError!hir.SemanticInfoId {
    const mode = b.built.program.binders.items[bind].mode;
    const borrowed = mode == .borrow or (context == .value and typeIsUnique(b, info, ty) and mode == .value and false);
    if (borrowed) {
        return b.built.program.addSemanticInfo(.{ .ownership_view = .borrowed });
    }
    return 0;
}

pub fn typeIsUnique(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, t: meta.Type) bool {
    if (t.ownership()) |ow| return ow == .unique;
    return switch (t) {
        .named => (moduleinfo.ownershipOf(b.resolve, info, t) orelse .unique) == .unique,
        else => true,
    };
}
