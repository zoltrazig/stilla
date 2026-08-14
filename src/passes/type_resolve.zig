//! Pass: type resolution (ast.Type → cfg.Type) — frontend.md §4.2.
//! In: `Resolve` view (arena + specifier → ModuleInfo map) and a `from`
//! module. Out: a `cfg.Type` for a written `ast.Type`, module-member lookups
//! for written names, alias chains to the underlying declaration, and the
//! monomorphic signature of a function declaration.
//!
//! The phase-2 checker (`passes/checker.zig`) is a stub, so the phase-1
//! builder and the phase-3 lowerer share these helpers: the resolution core
//! is written once against a `Resolve` view so both the builder (while the
//! graph is under construction) and the lowering (on the finished graph)
//! share the exact same behavior.
//!
//! Shape queries over resolved types (`structDecl`, `unionDecl`, `fieldIndex`,
//! `variantIndex`, `ownershipOf`) live in `type_shape.zig`; module-scope
//! const type inference and generic specialization (`inferExprType`,
//! `resolvePathMember`, `resolvePathTarget`, `specializeSignature`) live in
//! `type_infer.zig`. `src/moduleinfo.zig` re-exports the public API of all
//! three, so callers keep using `moduleinfo.resolveType` and friends.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");

const ModuleInfo = moduleinfo.ModuleInfo;
const ModuleGraph = moduleinfo.ModuleGraph;
const ValueMember = moduleinfo.ValueMember;
const TypeMember = moduleinfo.TypeMember;
const AliasTarget = moduleinfo.AliasTarget;

pub const Resolve = struct {
    arena: std.mem.Allocator,
    by_specifier: *const std.StringHashMapUnmanaged(*ModuleInfo),
    /// The canonical nominal-type interner, when the caller has one. Null
    /// under the phase-1 builder only before the graph type table settles;
    /// resolution then falls back to not interning (raw `.named` names).
    type_ids: ?*moduleinfo.TypeInterner = null,

    pub fn module(self: Resolve, specifier: []const u8) ?*ModuleInfo {
        return self.by_specifier.get(specifier);
    }

    /// Intern a canonical qualified name to a stable `TypeId`, creating it
    /// when absent. Without an interner (null `type_ids`) returns 0 and
    /// the caller treats the reference as unresolved.
    pub fn intern(self: Resolve, qualified: []const u8) ?moduleinfo.TypeId {
        const ti = self.type_ids orelse return null;
        return ti.intern(qualified);
    }

    /// The canonical qualified name behind a `TypeId`, or null.
    pub fn typeNameOf(self: Resolve, id: moduleinfo.TypeId) ?[]const u8 {
        const ti = self.type_ids orelse return null;
        if (id >= ti.to_name.items.len) return null;
        return ti.to_name.items[id];
    }
};

/// A `Resolve` view over the finished graph, for the lowering.
pub fn resolveOf(graph: *ModuleGraph) Resolve {
    return .{ .arena = graph.arena, .by_specifier = &graph.by_specifier, .type_ids = &graph.type_interner };
}

/// pass-internal: join a dotted `ast.Ident` path into a dotted name string.
pub fn joinPath(arena: std.mem.Allocator, path: []const ast.Ident) ?[]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    for (path, 0..) |id, i| {
        if (i > 0) buf.append(arena, '.') catch return null;
        buf.appendSlice(arena, id.text) catch return null;
    }
    return buf.toOwnedSlice(arena) catch null;
}

fn rawHasType(info: *ModuleInfo, name: []const u8) bool {
    const program = info.program orelse return false;
    for (program.items) |*item| switch (item.*) {
        .struct_def => |*s| if (std.mem.eql(u8, s.name.text, name)) return true,
        .union_def => |*u| if (std.mem.eql(u8, u.name.text, name)) return true,
        .type_def => |*t| if (std.mem.eql(u8, t.name.text, name)) return true,
        else => {},
    };
    return false;
}

fn rawHasValue(info: *ModuleInfo, name: []const u8) bool {
    const program = info.program orelse return false;
    for (program.items) |*item| switch (item.*) {
        .const_def => |*c| if (std.mem.eql(u8, c.name.text, name)) return true,
        .func_def => |*f| if (std.mem.eql(u8, f.name.text, name)) return true,
        else => {},
    };
    return false;
}

/// Resolve a `using path [as name]` declaration (Core §2.8) against
/// names known at module scope. Used by the phase-1 builder (module
/// values and member tables must already be published on `info`).
pub fn resolveAliasTarget(resolve: Resolve, info: *ModuleInfo, u: *const ast.UsingDecl) ?AliasTarget {
    const path = u.path;
    if (path.len == 1) {
        const n = path[0].text;
        if (info.module_values.get(n)) |spec| return .{ .module = spec };
        if (rawHasType(info, n)) return .{ .type = .{ .module = info.specifier, .name = n } };
        if (rawHasValue(info, n)) return .{ .value = .{ .module = info.specifier, .name = n } };
        return null;
    }
    // Multi-segment: first segment is a module value; walk the rest as
    // module-valued members; the final segment is the member name.
    var spec = info.module_values.get(path[0].text) orelse return null;
    var i: usize = 1;
    while (i < path.len - 1) : (i += 1) {
        const dep = resolve.module(spec) orelse return null;
        const vm = dep.valueMember(path[i].text) orelse return null;
        spec = vm.module_spec orelse return null;
    }
    const final = path[path.len - 1].text;
    const dep = resolve.module(spec) orelse return null;
    if (dep.typeMember(final) != null) return .{ .type = .{ .module = spec, .name = final } };
    if (dep.valueMember(final) != null) return .{ .value = .{ .module = spec, .name = final } };
    return null;
}

/// The monomorphic signature of a function declaration: type parameters
/// become named references in the IR-native type (`list[T]` etc.),
/// resolved later by syscall specialization. Used by the phase-1
/// builder to fill function members' resolved signatures.
pub fn funcSignature(resolve: Resolve, info: *ModuleInfo, f: *const ast.FuncDef) !cfg.Type {
    var params = std.ArrayListUnmanaged(cfg.Param).empty;
    for (f.params) |p| {
        const t = resolveType(resolve, info, &p.type_) orelse cfg.Type{ .primitive = .any };
        try params.append(resolve.arena, .{
            .span = p.span,
            .name = p.name,
            .mode = p.mode,
            .type_ = t,
        });
    }
    const ret = if (f.ret) |r|
        resolveType(resolve, info, &r) orelse cfg.Type{ .primitive = .any }
    else
        cfg.Type{ .primitive = .void };
    const ret_ptr = try resolve.arena.create(cfg.Type);
    ret_ptr.* = ret;
    return .{ .function = .{ .params = try resolve.arena.dupe(cfg.Param, params.items), .ret = ret_ptr } };
}

/// Resolve a written type name against a module: local type members first
/// (Core §2.5), then `using` aliases (Core §2.8), then module-qualified
/// paths `module.Type` / `std.math.Vec` (Core §2.5, §2.7). Returns the
/// declaration, or null when the name denotes no known type member.
pub fn resolveTypeName(resolve: Resolve, from: *ModuleInfo, name: []const u8) ?*TypeMember {
    return resolveTypeNameInner(resolve, from, name, null);
}

/// The walk behind `resolveTypeName`, reporting the owning module's
/// specifier through `owner` on every success path — so callers that
/// need the canonical `<owner>.<decl>` name don't re-scan the graph for
/// it. `null` `owner` keeps the walk identical to the public wrapper.
fn resolveTypeNameInner(resolve: Resolve, from: *ModuleInfo, name: []const u8, owner: ?*?[]const u8) ?*TypeMember {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        const head = name[0..dot];
        const rest = name[dot + 1 ..];
        // A canonical `specifier.Name` reference (ir.md §11): the head may
        // itself be a resolved module specifier, not just a local import
        // alias. This is how a TypeId resolves back to its declaration.
        const spec = from.module_values.get(head) orelse blk: {
            if (from.alias(head)) |a| switch (a.target) {
                .module => |mspec| break :blk mspec,
                else => return null,
            } else if (resolve.module(head) != null) break :blk head else return null;
        };
        var mod = resolve.module(spec) orelse return null;
        if (std.mem.lastIndexOfScalar(u8, rest, '.')) |last_dot| {
            // Chained module-valued members: std.math.Vec.
            var it = std.mem.splitScalar(u8, rest[0..last_dot], '.');
            while (it.next()) |seg| {
                const vm = mod.valueMember(seg) orelse return null;
                mod = resolve.module(vm.module_spec orelse return null) orelse return null;
            }
            if (owner) |o| o.* = mod.specifier;
            return mod.typeMember(rest[last_dot + 1 ..]);
        }
        if (owner) |o| o.* = mod.specifier;
        return mod.typeMember(rest);
    }
    if (from.typeMember(name)) |tm| {
        if (owner) |o| o.* = from.specifier;
        return tm;
    }
    if (from.alias(name)) |a| switch (a.target) {
        .type => |mref| {
            const mod = resolve.module(mref.module) orelse return null;
            if (owner) |o| o.* = mod.specifier;
            return mod.typeMember(mref.name);
        },
        else => return null,
    };
    return null;
}

/// The canonical qualified name (`<spec>.<decl>`) of the declaration
/// behind a written type name, together with its `TypeMember`. Used to
/// intern the declaration into the program type environment, so a
/// `TypeId` always names one decl regardless of how a reference is
/// written (qualified, local, or via a `using` alias). Returns null when
/// the name denotes no known type member; the member returned is the
/// *declared* struct/union (aliases are followed to their base decl).
pub fn resolveQualifiedTypeName(resolve: Resolve, from: *ModuleInfo, name: []const u8) ?QualifiedType {
    // The walk reports the owning module of each resolved member; the
    // last successful lookup owns the declared struct/union (aliases are
    // followed to their base decl), so its canonical name is
    // `<owner>.<decl>` without a graph scan.
    var owner: ?[]const u8 = null;
    var cur = resolveTypeNameInner(resolve, from, name, &owner) orelse return null;
    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        switch (cur.decl) {
            .alias => |ad| switch (ad.target) {
                .named => |n| {
                    const tname = joinPath(resolve.arena, n.path) orelse return null;
                    cur = resolveTypeNameInner(resolve, from, tname, &owner) orelse return null;
                },
                else => break,
            },
            else => break,
        }
    }
    const qualified = std.fmt.allocPrint(resolve.arena, "{s}.{s}", .{ owner orelse return null, cur.name.text }) catch return null;
    return .{ .member = cur, .qualified = qualified };
}

pub const QualifiedType = struct {
    member: *TypeMember,
    qualified: []const u8,
};

/// Resolve a written type name (alias chains expanded) to its interned
/// `TypeId` under the canonical `<spec>.<decl>` name. Returns null when
/// the name is unresolvable or no interner is attached.
pub fn resolveTypeId(resolve: Resolve, from: *ModuleInfo, name: []const u8) ?cfg.TypeId {
    const qt = resolveQualifiedTypeName(resolve, from, name) orelse return null;
    return resolve.intern(qt.qualified);
}

/// pass-internal: follow transparent alias chains (`type A = B; type B =
/// C;`) to the underlying struct/union/primitive member, or null when the
/// chain leads out of the type-member universe (depth-bounded). Shared
/// with the shape queries in `type_shape.zig`.
pub fn followAlias(resolve: Resolve, from: *ModuleInfo, tm0: *TypeMember) ?*TypeMember {
    var tm = tm0;
    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        switch (tm.decl) {
            .alias => |ad| switch (ad.target) {
                .named => |n| {
                    const name = joinPath(resolve.arena, n.path) orelse return null;
                    tm = resolveTypeName(resolve, from, name) orelse return null;
                },
                else => return null,
            },
            else => return tm,
        }
    }
    return null;
}

/// Resolve a syntactic type to an IR-native type (frontend §4.2).
/// Transparent aliases expand and leave no node (Core §11.2); named
/// struct/union references keep their written name (decl lookup and
/// ownership defer to the graph). Returns null when a component cannot be
/// resolved.
pub fn resolveType(resolve: Resolve, from: *ModuleInfo, t: *const ast.Type) ?cfg.Type {
    return resolveTypeDepth(resolve, from, t, 0);
}

fn resolveTypeDepth(resolve: Resolve, from: *ModuleInfo, t: *const ast.Type, depth: u32) ?cfg.Type {
    if (depth > 64) return null;
    return switch (t.*) {
        .primitive => |p| .{ .primitive = p.kind },
        .named => |n| blk: {
            const name = joinPath(resolve.arena, n.path) orelse break :blk null;
            const tm = resolveTypeName(resolve, from, name) orelse break :blk .{ .param = name };
            switch (tm.decl) {
                // Transparent alias: expand the target. A generic
                // alias expands with its type parameters as named
                // references (substitution is phase-2 work).
                .alias => |ad| break :blk resolveTypeDepth(resolve, from, &ad.target, depth + 1),
                else => {
                    const qt = resolveQualifiedTypeName(resolve, from, name) orelse break :blk null;
                    const id = resolve.intern(qt.qualified) orelse break :blk .{ .param = name };
                    break :blk .{ .named = id };
                },
            }
        },
        .list => |l| blk: {
            const inner = resolveTypeDepth(resolve, from, l.elem, depth + 1) orelse break :blk null;
            const ptr = resolve.arena.create(cfg.Type) catch break :blk null;
            ptr.* = inner;
            break :blk .{ .list = ptr };
        },
        .box => |b| blk: {
            const inner = resolveTypeDepth(resolve, from, b.inner, depth + 1) orelse break :blk null;
            const ptr = resolve.arena.create(cfg.Type) catch break :blk null;
            ptr.* = inner;
            break :blk .{ .box = ptr };
        },
        .tuple => |tup| blk: {
            var elems = std.ArrayListUnmanaged(cfg.Type).empty;
            for (tup.elems) |*el| {
                const et = resolveTypeDepth(resolve, from, el, depth + 1) orelse break :blk null;
                elems.append(resolve.arena, et) catch break :blk null;
            }
            break :blk .{ .tuple = elems.toOwnedSlice(resolve.arena) catch break :blk null };
        },
        .function => |ft| blk: {
            var params = std.ArrayListUnmanaged(cfg.Param).empty;
            for (ft.params) |fp| {
                const pt = resolveTypeDepth(resolve, from, fp.type_, depth + 1) orelse break :blk null;
                params.append(resolve.arena, .{
                    .span = fp.span,
                    .name = .{ .span = fp.span, .text = "" },
                    .mode = fp.mode,
                    .type_ = pt,
                }) catch break :blk null;
            }
            const ret = resolveTypeDepth(resolve, from, ft.ret, depth + 1) orelse break :blk null;
            const ret_ptr = resolve.arena.create(cfg.Type) catch break :blk null;
            ret_ptr.* = ret;
            break :blk .{ .function = .{
                .params = params.toOwnedSlice(resolve.arena) catch break :blk null,
                .ret = ret_ptr,
            } };
        },
    };
}
