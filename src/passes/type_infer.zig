//! Pass: module-scope const type inference and generic specialization —
//! frontend.md §4.3–§4.4.
//! In: `Resolve` view + `from` module + `ast.Expr` / function signature.
//! Out: the inferred `cfg.Type` of a module-constant initializer, the
//! module value member behind a dotted path (with or without its owning
//! module), and a specialized generic (host-binding) signature.
//!
//! Only module scope is in play (no locals): paths resolve against the
//! module's value members, imports, and aliases. Type-shape lookups come
//! from `type_shape.zig` (`structDecl`, `fieldIndex`); written-type
//! resolution comes from `type_resolve.zig`. `src/moduleinfo.zig`
//! re-exports these so callers keep using `moduleinfo.inferExprType` and
//! friends.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const type_resolve = @import("type_resolve.zig");
const type_shape = @import("type_shape.zig");

const ModuleInfo = moduleinfo.ModuleInfo;
const ValueMember = moduleinfo.ValueMember;
const Resolve = type_resolve.Resolve;

/// Infer the type of a module-level constant initializer. Only module
/// scope is in play (no locals): paths resolve against the module's value
/// members, imports, and aliases. Returns null when not inferable.
pub fn inferExprType(resolve: Resolve, from: *ModuleInfo, e: *const ast.Expr) ?cfg.Type {
    return switch (e.*) {
        .int => .{ .primitive = .int32 },
        .float => .{ .primitive = .float32 },
        .string => .{ .primitive = .str },
        .bool => .{ .primitive = .bool },
        .void => .{ .primitive = .void },
        .import => .module,
        .path => |p| inferPathType(resolve, from, &p),
        .paren => |p| inferExprType(resolve, from, p.inner),
        .tuple => |t| blk: {
            var elems = std.ArrayListUnmanaged(cfg.Type).empty;
            for (t.elems) |*el| {
                const et = inferExprType(resolve, from, el) orelse break :blk null;
                elems.append(resolve.arena, et) catch break :blk null;
            }
            break :blk .{ .tuple = elems.toOwnedSlice(resolve.arena) catch break :blk null };
        },
        .list => |l| blk: {
            const elem_t = if (l.elems.len > 0)
                inferExprType(resolve, from, &l.elems[0]) orelse break :blk null
            else
                cfg.Type{ .primitive = .int32 };
            const ptr = resolve.arena.create(cfg.Type) catch break :blk null;
            ptr.* = elem_t;
            break :blk .{ .list = ptr };
        },
        .lambda => |lam| lambdaType(resolve, from, &lam),
        .if_ => |i| blk: {
            const t = inferBlockType(resolve, from, i.then) orelse break :blk null;
            _ = i.else_ orelse break :blk .{ .primitive = .void };
            break :blk t;
        },
        .match => |m| if (m.arms.len > 0) inferExprType(resolve, from, m.arms[0].body) else .{ .primitive = .void },
        .block => |b| inferBlockType(resolve, from, b.block),
        .unary => |u| switch (u.op) {
            .neg => inferExprType(resolve, from, u.operand),
            .not => .{ .primitive = .bool },
        },
        .binary => |b| inferBinaryType(resolve, from, &b),
        .move => null,
        .cast => |c| type_resolve.resolveType(resolve, from, &c.target),
        .member => |m| blk: {
            const base = inferExprType(resolve, from, m.object) orelse break :blk null;
            const name = m.name.text;
            break :blk switch (base) {
                .named => |n| blk2: {
                    const qname = resolve.typeNameOf(n.id) orelse break :blk2 null;
                    const sd = type_shape.structDecl(resolve, from, qname) orelse break :blk2 null;
                    const idx = type_shape.fieldIndex(sd, name) orelse break :blk2 null;
                    break :blk2 type_resolve.resolveType(resolve, from, &sd.fields[idx].type_);
                },
                .tuple => |elems| blk2: {
                    const idx = std.fmt.parseInt(usize, name, 10) catch break :blk2 null;
                    if (idx >= elems.len) break :blk2 null;
                    break :blk2 elems[idx];
                },
                else => null,
            };
        },
        .call => |c| callReturnType(resolve, from, &c),
        .specialize => |s| inferExprType(resolve, from, s.operand),
    };
}

fn inferPathType(resolve: Resolve, from: *ModuleInfo, p: *const ast.PathExpr) ?cfg.Type {
    if (p.tail != .none) {
        // Struct or union-variant construction: the path is a type name.
        const name = type_resolve.joinPath(resolve.arena, p.path) orelse return null;
        const qt = type_resolve.resolveQualifiedTypeName(resolve, from, name);
        const id = if (qt) |q| resolve.intern(q.qualified) else resolve.intern(name);
        return .{ .named = .{ .id = id orelse return null, .args = &.{} } };
    }
    const vm = resolvePathMember(resolve, from, p.path) orelse return null;
    return vm.type_;
}

/// Resolve a dotted value path to the module value member it names
/// (`math.sqrt`, `app.greeting`, chained module values).
pub fn resolvePathMember(resolve: Resolve, from: *ModuleInfo, path: []const ast.Ident) ?*const ValueMember {
    if (path.len == 1) {
        return from.valueMember(path[0].text);
    }
    const spec = from.module_values.get(path[0].text) orelse return null;
    var mod = resolve.module(spec) orelse return null;
    var i: usize = 1;
    while (i < path.len - 1) : (i += 1) {
        const vm = mod.valueMember(path[i].text) orelse return null;
        mod = resolve.module(vm.module_spec orelse return null) orelse return null;
    }
    return mod.valueMember(path[path.len - 1].text);
}

/// Like `resolvePathMember`, but also returns the module that owns the
/// member (needed for qualified call names and syscall targets).
pub const PathTarget = struct {
    vm: *const ValueMember,
    module: *ModuleInfo,
};

pub fn resolvePathTarget(resolve: Resolve, from: *ModuleInfo, path: []const ast.Ident) ?PathTarget {
    if (path.len == 1) {
        const vm = from.valueMember(path[0].text) orelse return null;
        return .{ .vm = vm, .module = from };
    }
    const spec = from.module_values.get(path[0].text) orelse return null;
    var mod = resolve.module(spec) orelse return null;
    var i: usize = 1;
    while (i < path.len - 1) : (i += 1) {
        const vm = mod.valueMember(path[i].text) orelse return null;
        mod = resolve.module(vm.module_spec orelse return null) orelse return null;
    }
    const vm = mod.valueMember(path[path.len - 1].text) orelse return null;
    return .{ .vm = vm, .module = mod };
}

fn inferBlockType(resolve: Resolve, from: *ModuleInfo, b: *const ast.Block) ?cfg.Type {
    if (b.result) |*r| return inferExprType(resolve, from, r);
    return .{ .primitive = .void };
}

fn lambdaType(resolve: Resolve, from: *ModuleInfo, lam: *const ast.Lambda) ?cfg.Type {
    var params = std.ArrayListUnmanaged(cfg.Param).empty;
    for (lam.params) |p| {
        const t = type_resolve.resolveType(resolve, from, &p.type_) orelse return null;
        params.append(resolve.arena, .{
            .span = p.span,
            .name = p.name,
            .mode = p.mode,
            .type_ = t,
        }) catch return null;
    }
    const ret = if (lam.ret) |r|
        type_resolve.resolveType(resolve, from, &r) orelse return null
    else
        inferBlockType(resolve, from, lam.body) orelse return null;
    const ret_ptr = resolve.arena.create(cfg.Type) catch return null;
    ret_ptr.* = ret;
    return .{ .function = .{
        .params = params.toOwnedSlice(resolve.arena) catch return null,
        .ret = ret_ptr,
    } };
}

fn inferBinaryType(resolve: Resolve, from: *ModuleInfo, b: *const ast.Binary) ?cfg.Type {
    switch (b.op) {
        .or_, .and_, .eq, .ne, .lt, .le, .gt, .ge => return .{ .primitive = .bool },
        else => {},
    }
    const lt = inferExprType(resolve, from, b.lhs) orelse return null;
    return switch (b.op) {
        .add => switch (lt) {
            .primitive => |k| if (k == .str) .{ .primitive = .str } else lt,
            else => lt,
        },
        else => lt,
    };
}

/// The return type of a call, from the callee's resolved signature.
/// Generic (host) bindings are specialized from the argument types
/// (frontend §4.4; the syscall carries the concrete signature).
fn callReturnType(resolve: Resolve, from: *ModuleInfo, c: *const ast.Call) ?cfg.Type {
    var callee = c.callee;
    while (true) switch (callee.*) {
        .specialize => |s| callee = s.operand,
        else => break,
    };
    switch (callee.*) {
        .path => |p| {
            if (p.tail != .none) return null;
            const vm = resolvePathMember(resolve, from, p.path) orelse return null;
            const sig = vm.type_;
            if (sig != .function) return null;
            var arg_types = std.ArrayListUnmanaged(cfg.Type).empty;
            for (c.args) |*arg| {
                const at = inferExprType(resolve, from, arg) orelse return null;
                arg_types.append(resolve.arena, at) catch return null;
            }
            const specialized = specializeSignature(resolve, from, sig.function, arg_types.items);
            const ft = switch (specialized) {
                .function => |ft| ft,
                else => return null,
            };
            return ft.ret.*;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Generic specialization (frontend §4.4) — minimal, for host bindings
// ---------------------------------------------------------------------------

/// True when the named type string denotes an unresolved name in `from` —
/// the signature of a generic binding uses such names for its type
/// parameters (`list[T]`, `fn(move A) -> B`).
fn isTypeVar(resolve: Resolve, from: *ModuleInfo, t: cfg.Type) bool {
    _ = resolve;
    _ = from;
    return switch (t) {
        .param => true,
        // Every `.named` is now a concrete interned decl; only `.param`
        // denotes a type variable.
        .named => false,
        else => false,
    };
}

/// Instantiate a generic function signature from concrete argument types
/// (Core §12.2, §12.3). Unresolved named types in the signature are the
/// type parameters; unification is structural (`list[A]` against
/// `list[str]` binds `A = str`). When nothing is specialized the
/// signature is returned unchanged.
pub fn specializeSignature(
    resolve: Resolve,
    from: *ModuleInfo,
    sig: cfg.FunctionType,
    arg_types: []const cfg.Type,
) cfg.Type {
    var env = std.StringHashMapUnmanaged(cfg.Type).empty;
    _ = bindTypeArgs(resolve, from, sig, arg_types, &env);
    return substSignature(resolve, from, sig, &env);
}

/// Bind the type parameters of `sig` from concrete argument types,
/// writing the substitution into `env`. Unification is structural and
/// does not stop at the first failure — every pair is still attempted, so
/// `env` is as complete as the arguments allow. Returns false when any
/// parameter failed to unify.
pub fn bindTypeArgs(
    resolve: Resolve,
    from: *ModuleInfo,
    sig: cfg.FunctionType,
    arg_types: []const cfg.Type,
    env: *std.StringHashMapUnmanaged(cfg.Type),
) bool {
    var ok = true;
    const count = @min(sig.params.len, arg_types.len);
    for (sig.params[0..count], arg_types[0..count]) |p, at| {
        if (!unifyType(resolve, from, p.type_, at, env)) ok = false;
    }
    return ok;
}

/// Apply a type-parameter substitution to a function signature: the
/// parameters and return type with every bound type variable replaced
/// (Core §12.2). With no bindings the signature is returned unchanged.
pub fn substSignature(
    resolve: Resolve,
    from: *ModuleInfo,
    sig: cfg.FunctionType,
    env: *const std.StringHashMapUnmanaged(cfg.Type),
) cfg.Type {
    if (env.count() == 0) return .{ .function = sig };
    var params = std.ArrayListUnmanaged(cfg.Param).empty;
    for (sig.params) |p| {
        params.append(resolve.arena, .{
            .span = p.span,
            .name = p.name,
            .mode = p.mode,
            .type_ = substType(resolve, from, p.type_, env),
        }) catch return .{ .function = sig };
    }
    const ret_ptr = resolve.arena.create(cfg.Type) catch return .{ .function = sig };
    ret_ptr.* = substType(resolve, from, sig.ret.*, env);
    return .{ .function = .{ .params = params.toOwnedSlice(resolve.arena) catch return .{ .function = sig }, .ret = ret_ptr } };
}

/// Instantiate a generic signature from an explicit `::[...]` argument
/// list (Core §12.3): the i-th type parameter binds the i-th argument,
/// positionally, with no unification.
pub fn specializeSignatureExplicit(
    resolve: Resolve,
    from: *ModuleInfo,
    type_params: []const ast.Ident,
    args: []const cfg.Type,
    sig: cfg.FunctionType,
) cfg.Type {
    var env = std.StringHashMapUnmanaged(cfg.Type).empty;
    const count = @min(type_params.len, args.len);
    for (type_params[0..count], args[0..count]) |tp, a| {
        env.put(resolve.arena, tp.text, a) catch {};
    }
    return substSignature(resolve, from, sig, &env);
}

pub fn unifyType(
    resolve: Resolve,
    from: *ModuleInfo,
    pat: cfg.Type,
    arg: cfg.Type,
    env: *std.StringHashMapUnmanaged(cfg.Type),
) bool {
    return switch (pat) {
        .param => |n| {
            // A type parameter: always a type variable (consistency-checked).
            if (env.get(n)) |prev| return cfg.Type.eql(prev, arg);
            env.put(resolve.arena, n, arg) catch return false;
            return true;
        },
        .named => |pn| blk: {
            // The same declaration, with unified type arguments: the
            // pattern's arguments may reference type parameters (in a
            // generic signature `Array[T]` unifies against `Array[int32]`
            // by binding `T`); a wildcard (empty args) matches any
            // instantiation.
            const an = switch (arg) {
                .named => |n| n,
                else => break :blk false,
            };
            if (pn.id != an.id) break :blk false;
            if (pn.args.len == 0 or an.args.len == 0) break :blk true;
            if (pn.args.len != an.args.len) break :blk false;
            for (pn.args, an.args) |x, y| {
                if (!unifyType(resolve, from, x, y, env)) break :blk false;
            }
            break :blk true;
        },
        .list => |pl| return switch (arg) {
            .list => |al| unifyType(resolve, from, pl.*, al.*, env),
            else => false,
        },
        .box => |pb| return switch (arg) {
            .box => |ab| unifyType(resolve, from, pb.*, ab.*, env),
            else => false,
        },
        .tuple => |pt| switch (arg) {
            .tuple => |at| blk: {
                if (pt.len != at.len) break :blk false;
                for (pt, at) |x, y| {
                    if (!unifyType(resolve, from, x, y, env)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .function => |pf| return switch (arg) {
            .function => |af| blk: {
                if (pf.params.len != af.params.len) break :blk false;
                for (pf.params, af.params) |x, y| {
                    if (x.mode != y.mode) break :blk false;
                    if (!unifyType(resolve, from, x.type_, y.type_, env)) break :blk false;
                }
                break :blk unifyType(resolve, from, pf.ret.*, af.ret.*, env);
            },
            else => false,
        },
        else => cfg.Type.eql(pat, arg),
    };
}

fn substType(resolve: Resolve, from: *ModuleInfo, t: cfg.Type, env: *const std.StringHashMapUnmanaged(cfg.Type)) cfg.Type {
    return switch (t) {
        .param => |n| if (env.get(n)) |r| return r else return t,
        .named => |n| blk: {
            // Substitute through the type arguments of a named
            // instantiation (`HashMap[K, V]` → `HashMap[str, int32]`).
            if (n.args.len == 0) break :blk t;
            var changed = false;
            const out = resolve.arena.alloc(cfg.Type, n.args.len) catch break :blk t;
            for (n.args, 0..) |a, i| {
                out[i] = substType(resolve, from, a, env);
                if (!cfg.Type.eql(out[i], a)) changed = true;
            }
            if (!changed) break :blk t;
            break :blk .{ .named = .{ .id = n.id, .args = out } };
        },
        .list => |inner| blk: {
            const sub = substType(resolve, from, inner.*, env);
            if (cfg.Type.eql(sub, inner.*)) break :blk t;
            const ptr = resolve.arena.create(cfg.Type) catch break :blk t;
            ptr.* = sub;
            break :blk cfg.Type{ .list = ptr };
        },
        .box => |inner| blk: {
            const sub = substType(resolve, from, inner.*, env);
            if (cfg.Type.eql(sub, inner.*)) break :blk t;
            const ptr = resolve.arena.create(cfg.Type) catch break :blk t;
            ptr.* = sub;
            break :blk cfg.Type{ .box = ptr };
        },
        .tuple => |elems| blk: {
            var changed = false;
            var out = std.ArrayListUnmanaged(cfg.Type).empty;
            for (elems) |e| {
                const sub = substType(resolve, from, e, env);
                if (!cfg.Type.eql(sub, e)) changed = true;
                out.append(resolve.arena, sub) catch break :blk t;
            }
            if (!changed) break :blk t;
            break :blk cfg.Type{ .tuple = out.items };
        },
        .function => |ft| blk: {
            var changed = false;
            var params = std.ArrayListUnmanaged(cfg.Param).empty;
            for (ft.params) |p| {
                const sub = substType(resolve, from, p.type_, env);
                if (!cfg.Type.eql(sub, p.type_)) changed = true;
                params.append(resolve.arena, .{ .span = p.span, .name = p.name, .mode = p.mode, .type_ = sub }) catch break :blk t;
            }
            const rsub = substType(resolve, from, ft.ret.*, env);
            if (!cfg.Type.eql(rsub, ft.ret.*)) changed = true;
            if (!changed) break :blk t;
            const ret_ptr = resolve.arena.create(cfg.Type) catch break :blk t;
            ret_ptr.* = rsub;
            break :blk cfg.Type{ .function = .{ .params = params.items, .ret = ret_ptr } };
        },
        else => t,
    };
}
