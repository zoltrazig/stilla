//! Pass: generic expansion — frontend.md §4.4, Core §12.
//! In: a generic `ast.FuncDef` template + the concrete `cfg.Type` type
//! arguments of one specialization.
//! Out: a monomorphized `ast.FuncDef` — a deep copy of the template whose
//! every reference to a type parameter is replaced by its concrete
//! argument (Core §12.2), and whose `type_params` list is empty.
//!
//! Substitution is purely syntactic and confined to single-segment
//! `ast.Type.named` nodes whose name is one of the template's type
//! parameters; every other node (nested paths, type arguments, struct
//! constructors, …) is deep-copied unchanged. The resulting function is
//! checked by the phase-2 checker under the concrete substitution —
//! unspecialized generic bodies are never checked (Core §12.4).

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");

const Substitution = struct {
    params: []const ast.Ident,
    args: []const cfg.Type,
    /// The resolution view, used to turn a substituted `cfg.Type.named`
    /// (`TypeId`) back into its written name for the re-check (ir.md §11).
    resolve: moduleinfo.Resolve,

    fn lookup(self: Substitution, name: []const u8) ?cfg.Type {
        for (self.params, self.args) |p, a| {
            if (std.mem.eql(u8, p.text, name)) return a;
        }
        return null;
    }
};

/// Monomorphize a generic function template for one concrete set of type
/// arguments (Core §12.2). The clone lives in `arena` and shares no nodes
/// with the template, so the checker can annotate it independently.
pub fn monomorphizeFunc(arena: std.mem.Allocator, resolve: moduleinfo.Resolve, decl: *const ast.FuncDef, type_args: []const cfg.Type) !*ast.FuncDef {
    const sub = Substitution{ .params = decl.type_params, .args = type_args, .resolve = resolve };
    const out = try arena.create(ast.FuncDef);
    out.* = .{
        .span = decl.span,
        .name = decl.name,
        .type_params = &.{},
        .params = try cloneParams(arena, sub, decl.params),
        .ret = null,
        .body = null,
    };
    if (decl.ret) |r| out.ret = try cloneType(arena, sub, &r);
    if (decl.body) |b| out.body = try cloneBlockPtr(arena, sub, b);
    return out;
}

// ---------------------------------------------------------------------------
// ast.Type cloning
// ---------------------------------------------------------------------------

fn cloneType(arena: std.mem.Allocator, sub: Substitution, t: *const ast.Type) error{OutOfMemory}!ast.Type {
    return switch (t.*) {
        .primitive => |p| .{ .primitive = .{ .span = p.span, .kind = p.kind } },
        .named => |n| blk: {
            // A single-segment name matching a type parameter is replaced
            // by the concrete argument; everything else clones verbatim.
            if (n.path.len == 1) {
                if (sub.lookup(n.path[0].text)) |arg| break :blk try cfgTypeToAst(arena, sub.resolve, arg, n.span);
            }
            break :blk .{ .named = .{
                .span = n.span,
                .path = try cloneIdents(arena, n.path),
                .type_args = if (n.type_args) |args| try cloneTypes(arena, sub, args) else null,
            } };
        },
        .list => |l| .{ .list = .{ .span = l.span, .elem = try cloneTypePtr(arena, sub, l.elem) } },
        .box => |b| .{ .box = .{ .span = b.span, .inner = try cloneTypePtr(arena, sub, b.inner) } },
        .tuple => |tup| .{ .tuple = .{ .span = tup.span, .elems = try cloneTypes(arena, sub, tup.elems) } },
        .function => |f| .{ .function = .{
            .span = f.span,
            .params = try cloneFunctionParamTypes(arena, sub, f.params),
            .ret = try cloneTypePtr(arena, sub, f.ret),
        } },
    };
}

fn cloneTypePtr(arena: std.mem.Allocator, sub: Substitution, t: *const ast.Type) !*ast.Type {
    const ptr = try arena.create(ast.Type);
    ptr.* = try cloneType(arena, sub, t);
    return ptr;
}

fn cloneTypes(arena: std.mem.Allocator, sub: Substitution, types: []const ast.Type) ![]ast.Type {
    const out = try arena.alloc(ast.Type, types.len);
    for (types, 0..) |*t, i| out[i] = try cloneType(arena, sub, t);
    return out;
}

fn cloneParams(arena: std.mem.Allocator, sub: Substitution, params: []const ast.Param) ![]ast.Param {
    const out = try arena.alloc(ast.Param, params.len);
    for (params, 0..) |*p, i| {
        out[i] = .{
            .span = p.span,
            .mode = p.mode,
            .name = p.name,
            .type_ = try cloneType(arena, sub, &p.type_),
        };
    }
    return out;
}

fn cloneFunctionParamTypes(arena: std.mem.Allocator, sub: Substitution, params: []const ast.FunctionParamType) ![]ast.FunctionParamType {
    const out = try arena.alloc(ast.FunctionParamType, params.len);
    for (params, 0..) |*p, i| {
        out[i] = .{
            .span = p.span,
            .mode = p.mode,
            .type_ = try cloneTypePtr(arena, sub, p.type_),
        };
    }
    return out;
}

fn cloneIdents(arena: std.mem.Allocator, path: []const ast.Ident) ![]ast.Ident {
    const out = try arena.alloc(ast.Ident, path.len);
    for (path, 0..) |ident, i| out[i] = ident;
    return out;
}

// ---------------------------------------------------------------------------
// ast.Expr cloning
// ---------------------------------------------------------------------------

fn cloneExpr(arena: std.mem.Allocator, sub: Substitution, e: *const ast.Expr) error{OutOfMemory}!ast.Expr {
    return switch (e.*) {
        .int => |n| .{ .int = .{ .span = n.span, .value = n.value } },
        .float => |n| .{ .float = .{ .span = n.span, .value = n.value } },
        .string => |n| .{ .string = .{ .span = n.span, .value = n.value } },
        .bool => |n| .{ .bool = .{ .span = n.span, .value = n.value } },
        .void => |n| .{ .void = .{ .span = n.span } },
        .path => |p| .{ .path = .{
            .span = p.span,
            .path = try cloneIdents(arena, p.path),
            .type_args = if (p.type_args) |args| try cloneTypes(arena, sub, args) else null,
            .tail = try clonePathTail(arena, sub, &p.tail),
        } },
        .paren => |p| .{ .paren = .{ .span = p.span, .inner = try cloneExprPtr(arena, sub, p.inner) } },
        .tuple => |t| .{ .tuple = .{ .span = t.span, .elems = try cloneExprs(arena, sub, t.elems) } },
        .list => |l| .{ .list = .{ .span = l.span, .elems = try cloneExprs(arena, sub, l.elems) } },
        .lambda => |lam| .{ .lambda = .{
            .span = lam.span,
            .params = try cloneParams(arena, sub, lam.params),
            .ret = if (lam.ret) |r| try cloneType(arena, sub, &r) else null,
            .body = try cloneBlockPtr(arena, sub, lam.body),
        } },
        .if_ => |i| .{ .if_ = .{
            .span = i.span,
            .cond = try cloneExprPtr(arena, sub, i.cond),
            .then = try cloneBlockPtr(arena, sub, i.then),
            .else_ = if (i.else_) |else_e| try cloneExprPtr(arena, sub, else_e) else null,
        } },
        .match => |m| .{ .match = .{
            .span = m.span,
            .scrutinee = try cloneExprPtr(arena, sub, m.scrutinee),
            .arms = try cloneMatchArms(arena, sub, m.arms),
        } },
        .import => |im| .{ .import = .{ .span = im.span, .module = im.module } },
        .block => |b| .{ .block = .{ .span = b.span, .block = try cloneBlockPtr(arena, sub, b.block) } },
        .unary => |u| .{ .unary = .{ .span = u.span, .op = u.op, .operand = try cloneExprPtr(arena, sub, u.operand) } },
        .binary => |b| .{ .binary = .{
            .span = b.span,
            .op = b.op,
            .lhs = try cloneExprPtr(arena, sub, b.lhs),
            .rhs = try cloneExprPtr(arena, sub, b.rhs),
        } },
        .move => |m| .{ .move = .{ .span = m.span, .name = m.name } },
        .cast => |c| .{ .cast = .{
            .span = c.span,
            .operand = try cloneExprPtr(arena, sub, c.operand),
            .target = try cloneType(arena, sub, &c.target),
        } },
        .member => |m| .{ .member = .{ .span = m.span, .object = try cloneExprPtr(arena, sub, m.object), .name = m.name } },
        .call => |c| .{ .call = .{
            .span = c.span,
            .callee = try cloneExprPtr(arena, sub, c.callee),
            .args = try cloneExprs(arena, sub, c.args),
        } },
        .specialize => |s| .{ .specialize = .{
            .span = s.span,
            .operand = try cloneExprPtr(arena, sub, s.operand),
            .type_args = try cloneTypes(arena, sub, s.type_args),
        } },
    };
}

fn cloneExprPtr(arena: std.mem.Allocator, sub: Substitution, e: *const ast.Expr) !*ast.Expr {
    const ptr = try arena.create(ast.Expr);
    ptr.* = try cloneExpr(arena, sub, e);
    return ptr;
}

fn cloneExprs(arena: std.mem.Allocator, sub: Substitution, exprs: []const ast.Expr) ![]ast.Expr {
    const out = try arena.alloc(ast.Expr, exprs.len);
    for (exprs, 0..) |*e, i| out[i] = try cloneExpr(arena, sub, e);
    return out;
}

fn clonePathTail(arena: std.mem.Allocator, sub: Substitution, t: *const ast.PathTail) !ast.PathTail {
    return switch (t.*) {
        .construct => |sc| .{ .construct = .{ .span = sc.span, .fields = try cloneFieldInits(arena, sub, sc.fields) } },
        .variant => |v| .{ .variant = .{
            .span = v.span,
            .name = v.name,
            .args = if (v.args) |args| try cloneExprs(arena, sub, args) else null,
        } },
        .none => .none,
    };
}

fn cloneFieldInits(arena: std.mem.Allocator, sub: Substitution, fields: []const ast.StructFieldInit) ![]ast.StructFieldInit {
    const out = try arena.alloc(ast.StructFieldInit, fields.len);
    for (fields, 0..) |*f, i| {
        out[i] = .{
            .span = f.span,
            .name = f.name,
            .value = try cloneExprPtr(arena, sub, f.value),
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// ast.Block and ast.Stmt cloning
// ---------------------------------------------------------------------------

fn cloneBlockPtr(arena: std.mem.Allocator, sub: Substitution, b: *const ast.Block) !*ast.Block {
    const out = try arena.create(ast.Block);
    out.* = .{
        .span = b.span,
        .stmts = try cloneStmts(arena, sub, b.stmts),
        .result = null,
    };
    if (b.result) |*r| out.result = try cloneExpr(arena, sub, r);
    return out;
}

fn cloneStmts(arena: std.mem.Allocator, sub: Substitution, stmts: []const ast.Stmt) ![]ast.Stmt {
    const out = try arena.alloc(ast.Stmt, stmts.len);
    for (stmts, 0..) |*s, i| out[i] = try cloneStmt(arena, sub, s);
    return out;
}

fn cloneStmt(arena: std.mem.Allocator, sub: Substitution, s: *const ast.Stmt) error{OutOfMemory}!ast.Stmt {
    return switch (s.*) {
        .let => |l| .{ .let = .{
            .span = l.span,
            .pattern = try clonePattern(arena, sub, &l.pattern),
            .type_ = if (l.type_) |t| try cloneType(arena, sub, &t) else null,
            .init = try cloneExprPtr(arena, sub, l.init),
        } },
        .drop => |d| .{ .drop = .{ .span = d.span, .name = d.name } },
        .using => |u| .{ .using = .{
            .span = u.span,
            .path = try cloneIdents(arena, u.path),
            .alias = u.alias,
        } },
        .expr => |e| .{ .expr = .{ .span = e.span, .expr = try cloneExpr(arena, sub, &e.expr) } },
        .empty => |es| .{ .empty = .{ .span = es.span } },
    };
}

// ---------------------------------------------------------------------------
// ast.Pattern cloning
// ---------------------------------------------------------------------------

fn clonePattern(arena: std.mem.Allocator, sub: Substitution, p: *const ast.Pattern) error{OutOfMemory}!ast.Pattern {
    return switch (p.*) {
        .wildcard => |w| .{ .wildcard = .{ .span = w.span } },
        .literal => |l| .{ .literal = .{ .span = l.span, .value = l.value } },
        .type_test => |tt| .{ .type_test = .{
            .span = tt.span,
            .type_ = try cloneType(arena, sub, &tt.type_),
            .binding = tt.binding,
        } },
        .tuple => |tp| .{ .tuple = .{ .span = tp.span, .elems = try clonePatterns(arena, sub, tp.elems) } },
        .path => |pp| .{ .path = .{
            .span = pp.span,
            .path = try cloneIdents(arena, pp.path),
            .type_args = if (pp.type_args) |args| try cloneTypes(arena, sub, args) else null,
            .tail = try clonePatternTail(arena, sub, &pp.tail),
        } },
        .list => |lp| .{ .list = .{
            .span = lp.span,
            .items = try clonePatterns(arena, sub, lp.items),
            .rest = lp.rest,
        } },
    };
}

fn clonePatterns(arena: std.mem.Allocator, sub: Substitution, patterns: []const ast.Pattern) ![]ast.Pattern {
    const out = try arena.alloc(ast.Pattern, patterns.len);
    for (patterns, 0..) |*p, i| out[i] = try clonePattern(arena, sub, p);
    return out;
}

fn clonePatternTail(arena: std.mem.Allocator, sub: Substitution, t: *const ast.PatternTail) !ast.PatternTail {
    return switch (t.*) {
        .struct_ => |sp| .{ .struct_ = .{ .span = sp.span, .fields = try cloneFieldPatterns(arena, sub, sp.fields) } },
        .variant => |vp| .{ .variant = .{
            .span = vp.span,
            .name = vp.name,
            .args = if (vp.args) |args| try clonePatterns(arena, sub, args) else null,
        } },
        .none => .none,
    };
}

fn cloneFieldPatterns(arena: std.mem.Allocator, sub: Substitution, fields: []const ast.FieldPattern) ![]ast.FieldPattern {
    const out = try arena.alloc(ast.FieldPattern, fields.len);
    for (fields, 0..) |*f, i| {
        out[i] = .{
            .span = f.span,
            .name = f.name,
            .pattern = if (f.pattern) |fp| try clonePattern(arena, sub, &fp) else null,
        };
    }
    return out;
}

fn cloneMatchArms(arena: std.mem.Allocator, sub: Substitution, arms: []const ast.MatchArm) ![]ast.MatchArm {
    const out = try arena.alloc(ast.MatchArm, arms.len);
    for (arms, 0..) |*arm, i| {
        out[i] = .{
            .span = arm.span,
            .pattern = try clonePattern(arena, sub, &arm.pattern),
            .body = try cloneExprPtr(arena, sub, arm.body),
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// cfg.Type → ast.Type (the concrete substitution arguments)
// ---------------------------------------------------------------------------

/// Convert a resolved `cfg.Type` back into an `ast.Type` so a substituted
/// node can be re-resolved by the checker. Dotted named types split into a
/// path of identifiers; `.module` has no syntax and is unreachable here.
fn cfgTypeToAst(arena: std.mem.Allocator, resolve: moduleinfo.Resolve, t: cfg.Type, span: ast.Span) error{OutOfMemory}!ast.Type {
    return switch (t) {
        .primitive => |k| .{ .primitive = .{ .span = span, .kind = k } },
        .named => |n| .{
            .named = .{
                .span = span,
                .path = try splitPath(arena, resolve.typeNameOf(n.id) orelse ""),
                // The instantiation's arguments are re-emitted so the clone
                // re-resolves to the same instantiation (Core §12.1).
                .type_args = try cfgTypesToAst(arena, resolve, n.args, span),
            },
        },
        .param => |p| blk: {
            const one = try arena.alloc(ast.Ident, 1);
            one[0] = .{ .span = span, .text = p };
            break :blk .{ .named = .{ .span = span, .path = one, .type_args = null } };
        },
        .module, .cleanup => unreachable,
        .list => |inner| .{ .list = .{ .span = span, .elem = try cfgTypeToAstPtr(arena, resolve, inner.*, span) } },
        .box => |inner| .{ .box = .{ .span = span, .inner = try cfgTypeToAstPtr(arena, resolve, inner.*, span) } },
        .tuple => |elems| .{ .tuple = .{ .span = span, .elems = try cfgTypesToAst(arena, resolve, elems, span) } },
        .function => |f| .{ .function = .{
            .span = span,
            .params = try cfgParamsToAst(arena, resolve, f.params),
            .ret = try cfgTypeToAstPtr(arena, resolve, f.ret.*, span),
        } },
    };
}

fn cfgTypeToAstPtr(arena: std.mem.Allocator, resolve: moduleinfo.Resolve, t: cfg.Type, span: ast.Span) error{OutOfMemory}!*ast.Type {
    const ptr = try arena.create(ast.Type);
    ptr.* = try cfgTypeToAst(arena, resolve, t, span);
    return ptr;
}

fn cfgTypesToAst(arena: std.mem.Allocator, resolve: moduleinfo.Resolve, types: []const cfg.Type, span: ast.Span) error{OutOfMemory}![]ast.Type {
    const out = try arena.alloc(ast.Type, types.len);
    for (types, 0..) |t, i| out[i] = try cfgTypeToAst(arena, resolve, t, span);
    return out;
}

fn cfgParamsToAst(arena: std.mem.Allocator, resolve: moduleinfo.Resolve, params: []const cfg.Param) error{OutOfMemory}![]ast.FunctionParamType {
    const out = try arena.alloc(ast.FunctionParamType, params.len);
    for (params, 0..) |p, i| {
        out[i] = .{
            .span = p.span,
            .mode = p.mode,
            .type_ = try cfgTypeToAstPtr(arena, resolve, p.type_, p.span),
        };
    }
    return out;
}

fn splitPath(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]ast.Ident {
    var out = std.ArrayListUnmanaged(ast.Ident).empty;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |seg| {
        try out.append(arena, .{ .span = ast.Span.init(0, 0, 0), .text = seg });
    }
    return out.toOwnedSlice(arena);
}
