//! Pass: type shape queries — phase2-checker.md, Type resolution.
//! In: `Resolve` view + `from` module + written type name or AIR-native
//! `cfg.Type`. Out: the struct/union declaration behind a name, the index
//! of a field or variant, and the structural ownership of a type.
//!
//! Written-name lookups and alias-following come from `type_resolve.zig`;
//! the ownership walk resolves field and variant types through the graph
//! (`resolveType`). `src/moduleinfo.zig` re-exports these so callers keep
//! using `moduleinfo.ownershipOf` and friends.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const type_resolve = @import("type_resolve.zig");

const ModuleInfo = moduleinfo.ModuleInfo;
const TypeMember = moduleinfo.TypeMember;
const Resolve = type_resolve.Resolve;

/// The struct declaration behind a written type name (following `using`
/// aliases and transparent `type` aliases), or null.
pub fn structDecl(resolve: Resolve, from: *ModuleInfo, name: []const u8) ?*const ast.StructDef {
    const tm = type_resolve.resolveTypeName(resolve, from, name) orelse return null;
    const final = type_resolve.followAlias(resolve, from, tm) orelse return null;
    return switch (final.decl) {
        .struct_ => |s| s,
        else => null,
    };
}

/// The union declaration behind a written type name, or null.
pub fn unionDecl(resolve: Resolve, from: *ModuleInfo, name: []const u8) ?*const ast.UnionDef {
    const tm = type_resolve.resolveTypeName(resolve, from, name) orelse return null;
    const final = type_resolve.followAlias(resolve, from, tm) orelse return null;
    return switch (final.decl) {
        .union_ => |u| u,
        else => null,
    };
}

/// The opaque declaration behind a written type name, or null. A
/// host-backed opaque nominal type (Core §11.8) is neither a struct nor a
/// union: `structDecl`/`unionDecl` return null for it, and `opaqueDecl`
/// returns the declaration.
pub fn opaqueDecl(resolve: Resolve, from: *ModuleInfo, name: []const u8) ?*const ast.OpaqueDef {
    const tm = type_resolve.resolveTypeName(resolve, from, name) orelse return null;
    const final = type_resolve.followAlias(resolve, from, tm) orelse return null;
    return switch (final.decl) {
        .opaque_ => |o| o,
        else => null,
    };
}

/// Index of a named field in a struct declaration (declaration order,
/// Core §8.1).
pub fn fieldIndex(sd: *const ast.StructDef, name: []const u8) ?u32 {
    for (sd.fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name.text, name)) return @intCast(i);
    }
    return null;
}

/// Index of a named variant in a union declaration (declaration order,
/// Core §11.1); the discriminant of a `switch`.
pub fn variantIndex(ud: *const ast.UnionDef, name: []const u8) ?u32 {
    for (ud.variants, 0..) |v, i| {
        if (std.mem.eql(u8, v.name.text, name)) return @intCast(i);
    }
    return null;
}

/// Structural ownership of an AIR-native type (Core §10.1–§10.3):
/// primitives and function/module values are Copy (except `any`),
/// containers join their components, named types resolve through the
/// graph. `null` means the ownership is genuinely deferred (an
/// unspecialized type parameter). The classification is the **least
/// fixpoint** of the Copy equations (Core §10.3): a recursive occurrence
/// reached through an owned component — a back-edge to a named type
/// currently being classified — is unique; a cycle that passes only
/// through function types is Copy (a function type is not an owned
/// component, so the cycle is never entered). The caller treats a final
/// `null` as not-unique.
pub fn ownershipOf(resolve: Resolve, from: *ModuleInfo, t: cfg.Type) ?cfg.Ownership {
    // The ancestor stack holds the named types currently being
    // classified. It is a path set, not a grow-only seen set: sibling
    // instantiations of the same declaration (`Option[int32]` and
    // `Option[str]`) are distinct types and must not look like a cycle.
    // Arena-owned; no deinit needed.
    var visited = std.ArrayList(cfg.Type).empty;
    return ownershipVisited(resolve, from, t, &visited);
}

fn ownershipVisited(
    resolve: Resolve,
    from: *ModuleInfo,
    t: cfg.Type,
    visited: *std.ArrayList(cfg.Type),
) ?cfg.Ownership {
    return switch (t) {
        .primitive => |k| if (k == .any or k == .hostdata) cfg.Ownership.unique else cfg.Ownership.copy,
        .module, .function, .cleanup => cfg.Ownership.copy,
        .param => null, // deferred until monomorphic substitution
        .list, .box => |inner| ownershipVisited(resolve, from, inner.*, visited),
        .tuple => |elems| blk: {
            var acc: ?cfg.Ownership = cfg.Ownership.copy;
            for (elems) |e| {
                const ow = ownershipVisited(resolve, from, e, visited) orelse break :blk cfg.Ownership.unique;
                if (ow == .unique) acc = cfg.Ownership.unique;
            }
            break :blk acc;
        },
        .named => |n| blk: {
            const name = resolve.typeNameOf(n.id) orelse break :blk null;
            const tm = type_resolve.resolveTypeName(resolve, from, name) orelse break :blk null;
            const final = type_resolve.followAlias(resolve, from, tm) orelse break :blk null;
            // Least fixpoint (Core §10.3): a back-edge to a named type
            // currently being classified — a recursive occurrence reached
            // through an owned component — is unique.
            for (visited.items) |anc| if (cfg.Type.eql(t, anc)) break :blk cfg.Ownership.unique;
            visited.append(resolve.arena, t) catch break :blk null;
            defer _ = visited.pop();
            break :blk switch (final.decl) {
                // A host-backed opaque nominal type is unique by declaration
                // (Core §11.8): `Array[int32]` is unique even though `int32`
                // is Copy. Ownership never recurses into the type arguments.
                .opaque_ => cfg.Ownership.unique,
                .struct_ => |s| blk2: {
                    if (s.drop != null) break :blk2 cfg.Ownership.unique;
                    var acc: ?cfg.Ownership = cfg.Ownership.copy;
                    for (s.fields) |f| {
                        const ft = type_resolve.resolveType(resolve, from, &f.type_) orelse continue;
                        // A generic instantiation's ownership resolves
                        // through its substituted fields (`Option[int32]`
                        // is Copy; `Option[File]` is unique).
                        const ft_sub = type_resolve.substParams(resolve.arena, s.type_params, n.args, ft);
                        const ow = ownershipVisited(resolve, from, ft_sub, visited) orelse {
                            acc = cfg.Ownership.unique;
                            break;
                        };
                        if (ow == .unique) acc = cfg.Ownership.unique;
                    }
                    break :blk2 acc;
                },
                .union_ => |u| blk2: {
                    var acc: ?cfg.Ownership = cfg.Ownership.copy;
                    for (u.variants) |v| {
                        if (v.types) |types| for (types) |vt| {
                            const t2 = type_resolve.resolveType(resolve, from, &vt) orelse continue;
                            const t2_sub = type_resolve.substParams(resolve.arena, u.type_params, n.args, t2);
                            const ow = ownershipVisited(resolve, from, t2_sub, visited) orelse {
                                acc = cfg.Ownership.unique;
                                break;
                            };
                            if (ow == .unique) acc = cfg.Ownership.unique;
                        };
                    }
                    break :blk2 acc;
                },
                .alias => unreachable, // followAlias resolved the chain
            };
        },
    };
}
