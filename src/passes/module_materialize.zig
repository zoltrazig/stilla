//! Pass: module materialization. In: Builder + RawModule (graph loaded and
//! scanned; imports resolved). Out: `raw.info` member tables (values, types,
//! using aliases, host bindings, imports) and name indexes.
//!
//! Runs in topological order so cross-module lookups resolve; idempotent
//! (guarded by the builder's `materialized` set). The five steps (frontend
//! §3.3): 1. using aliases; 2. type members; 3. function members; 4. const
//! members (module values first); 5. import edges.

const std = @import("std");
const cfg = @import("../cfg.zig");
const type_resolve = @import("type_resolve.zig");
const type_infer = @import("type_infer.zig");
const moduleinfo = @import("../moduleinfo.zig");

const Builder = moduleinfo.Builder;
const RawModule = moduleinfo.RawModule;
const ModuleInfo = moduleinfo.ModuleInfo;
const ValueMember = moduleinfo.ValueMember;
const TypeMember = moduleinfo.TypeMember;
const UsingAlias = moduleinfo.UsingAlias;
const HostBinding = moduleinfo.HostBinding;
const Resolve = moduleinfo.Resolve;

/// Compute a module's member tables and resolved member types. Runs
/// in topological order so cross-module lookups resolve; idempotent.
pub fn materialize(self: *Builder, raw: *RawModule) !void {
    if (self.materialized.contains(raw.info.specifier)) return;
    defer self.materialized.put(self.arena, raw.info.specifier, {}) catch {};

    const info = raw.info;
    const program = info.program orelse return; // host modules: nothing to annotate

    var values = std.ArrayListUnmanaged(ValueMember).empty;
    var types = std.ArrayListUnmanaged(TypeMember).empty;
    var aliases = std.ArrayListUnmanaged(UsingAlias).empty;
    var host_bindings = std.ArrayListUnmanaged(HostBinding).empty;
    var value_index: std.StringHashMapUnmanaged(u32) = .{};
    var type_index: std.StringHashMapUnmanaged(u32) = .{};
    var alias_index: std.StringHashMapUnmanaged(u32) = .{};

    // The resolution view over the partially built graph: module
    // values are known from the load pass, so type resolution below
    // can already follow `import` aliases and `using` targets.
    info.module_values = raw.module_values;
    const resolve: Resolve = .{ .arena = self.arena, .by_specifier = &self.by_specifier, .type_ids = &self.type_interner };

    // 1. using aliases first: signatures and const types may use them.
    for (program.items) |*item| switch (item.*) {
        .using_decl => |u| {
            if (type_resolve.resolveAliasTarget(resolve, info, &u)) |target| {
                const name = if (u.alias) |a| a.text else u.path[u.path.len - 1].text;
                const idx: u32 = @intCast(aliases.items.len);
                try aliases.append(self.arena, .{ .name = name, .span = u.span, .target = target });
                if (!alias_index.contains(name)) try alias_index.put(self.arena, name, idx);
            }
        },
        else => {},
    };
    // Publish aliases now: func/const types resolve through them.
    info.using_aliases = try self.arena.dupe(UsingAlias, aliases.items);
    info.alias_index = alias_index;

    // 2. Type members (structs / unions / aliases).
    for (program.items) |*item| switch (item.*) {
        .struct_def => |*s| {
            const idx: u32 = @intCast(types.items.len);
            try types.append(self.arena, .{ .name = s.name, .decl = .{ .struct_ = s }, .generic = s.type_params.len > 0 });
            if (!type_index.contains(s.name.text)) try type_index.put(self.arena, s.name.text, idx);
        },
        .union_def => |*u| {
            const idx: u32 = @intCast(types.items.len);
            try types.append(self.arena, .{ .name = u.name, .decl = .{ .union_ = u }, .generic = u.type_params.len > 0 });
            if (!type_index.contains(u.name.text)) try type_index.put(self.arena, u.name.text, idx);
        },
        .type_def => |*t| {
            const idx: u32 = @intCast(types.items.len);
            try types.append(self.arena, .{ .name = t.name, .decl = .{ .alias = t }, .generic = t.type_params.len > 0 });
            if (!type_index.contains(t.name.text)) try type_index.put(self.arena, t.name.text, idx);
        },
        else => {},
    };

    // Publish type members now, before function/const signatures: a
    // same-module struct/union return or field reference must resolve
    // to its nominal named (not parametrized) type during signature
    // materialization, so it does not leak as a generic name.
    info.types = try self.arena.dupe(TypeMember, types.items);
    info.type_index = type_index;

    // 3. Function members (host bindings and definitions). Generic
    // functions are templates (Core §12.4) but are still recorded so
    // syscall resolution can find generic builtins by name.
    for (program.items) |*item| switch (item.*) {
        .func_def => |*f| {
            const slot: u32 = @intCast(values.items.len);
            const sig = try type_resolve.funcSignature(resolve, info, f);
            try values.append(self.arena, .{
                .name = f.name,
                .slot = slot,
                .type_ = sig,
                .decl = .{ .func = f },
                .host = f.body == null,
            });
            if (!value_index.contains(f.name.text)) try value_index.put(self.arena, f.name.text, slot);
            if (f.body == null) {
                try host_bindings.append(self.arena, .{
                    .span = f.span,
                    .name = f.name,
                    .member_index = slot,
                    .signature = sig,
                });
            }
        },
        else => {},
    };

    // Publish function members now, before consts: a module constant
    // initializer may reference module functions declared anywhere
    // in the module (Core §5), so const type inference below must
    // resolve them through the member tables.
    info.values = values.items;
    info.value_index = value_index;

    // 4. Const members: module values first (imports + aliases), then
    // ordinary consts with declared or inferred types.
    for (raw.consts.items) |rc| {
        const c = rc.def;
        const slot: u32 = @intCast(values.items.len);
        var member = ValueMember{
            .name = c.name,
            .slot = slot,
            .type_ = undefined,
            .decl = .{ .const_ = c },
            .host = c.init == null,
        };
        if (info.module_values.get(c.name.text)) |spec| {
            member.module_spec = spec;
            member.type_ = .module;
        } else if (c.init == null) {
            // Host constant: the declared type is required
            // (stdbundle asserts this for every std module).
            const declared = c.type_ orelse {
                return self.failSpan(c.span, "host constant '{s}' must declare its type", .{c.name.text});
            };
            member.type_ = type_resolve.resolveType(resolve, info, &declared) orelse cfg.Type{ .primitive = .any };
        } else if (c.type_) |declared| {
            member.type_ = type_resolve.resolveType(resolve, info, &declared) orelse cfg.Type{ .primitive = .any };
        } else {
            member.type_ = type_infer.inferExprType(resolve, info, c.init.?) orelse {
                return self.failSpan(c.span, "cannot infer the type of constant '{s}'", .{c.name.text});
            };
        }
        if (!value_index.contains(c.name.text)) try value_index.put(self.arena, c.name.text, slot);
        try values.append(self.arena, member);
        // Keep the published member table current: a later const's
        // initializer may reference this one (Core §5).
        info.values = values.items;
        info.value_index = value_index;
    }

    // 5. Import edges, resolved to ModuleInfo pointers (declaration
    // order, Runtime §2.3).
    var imports = std.ArrayListUnmanaged(*ModuleInfo).empty;
    for (raw.import_specs.items) |edge| {
        const dep = self.by_specifier.get(edge.spec) orelse continue;
        try imports.append(self.arena, dep);
    }

    info.imports = try self.arena.dupe(*ModuleInfo, imports.items);
    info.values = try self.arena.dupe(ValueMember, values.items);
    info.types = try self.arena.dupe(TypeMember, types.items);
    info.host_bindings = try self.arena.dupe(HostBinding, host_bindings.items);
    info.value_index = value_index;
    info.type_index = type_index;
}
