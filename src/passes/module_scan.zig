//! Pass: module scanning. In: Builder + registered RawModule + parsed
//! Program. Out: `raw.consts` (one `RawConst` per module const) and
//! `raw.module_values` seeded with imports and transitive module-value
//! aliases.
//!
//! The load pass (`module_load.zig`) registers each module, then hands it
//! to `scanModule` here: module-level consts are pre-scanned for
//! `import(...)` initializers and single-segment path aliases (frontend
//! §3.3, Core §2.2–§2.3), and module values are resolved transitively so
//! materialization can follow `import` aliases and `using` targets.

const std = @import("std");
const ast = @import("../ast.zig");
const moduleinfo = @import("../moduleinfo.zig");

const Builder = moduleinfo.Builder;
const RawModule = moduleinfo.RawModule;
const RawConst = moduleinfo.RawConst;

/// Pre-scan a module's consts for imports and module-value aliases, then
/// seed `raw.module_values` transitively.
pub fn scanModule(self: *Builder, raw: *RawModule, program: *const ast.Program) !void {
    // Pre-scan module-level consts for imports and module-value
    // aliases (frontend §3.3, Core §2.2–§2.3).
    for (program.items) |*item| switch (item.*) {
        .const_def => |*c| try collectConst(self, raw, c),
        else => {},
    };
    // Resolve module values transitively: imports directly, and
    // single-segment path aliases through other consts.
    for (raw.consts.items) |rc| {
        if (rc.def.init) |init_expr| switch (init_expr.*) {
            .import => |imp| try raw.module_values.put(self.arena, rc.def.name.text, imp.module),
            else => {},
        };
    }
    for (raw.consts.items) |rc| {
        if (resolveModuleValue(self, raw, rc.def.name.text, 0)) |spec| {
            try raw.module_values.put(self.arena, rc.def.name.text, spec);
        }
    }
}

fn collectConst(self: *Builder, raw: *RawModule, c: *const ast.ConstDef) !void {
    var rc = RawConst{ .def = c };
    if (c.init) |init_expr| switch (init_expr.*) {
        .import => |imp| {
            try raw.import_specs.append(self.arena, .{ .spec = imp.module, .span = imp.span });
            rc.import_spec = imp.module;
            rc.import_span = imp.span;
        },
        .path => |path| {
            // A single-segment, tail-less path may be a module-value
            // alias (`const b = a;`, Core §2.3 / Runtime §2.4).
            if (path.path.len == 1 and path.type_args == null and path.tail == .none) {
                rc.alias_of = path.path[0].text;
            }
        },
        else => {},
    };
    try raw.consts.append(self.arena, rc);
}

/// The resolved specifier behind a module-valued const name, chasing
/// aliases (`const c = b; const b = a;` where `a = import(..)`).
fn resolveModuleValue(self: *Builder, raw: *RawModule, name: []const u8, depth: u32) ?[]const u8 {
    if (raw.module_values.get(name)) |spec| return spec;
    if (depth > 64) return null;
    for (raw.consts.items) |rc| {
        if (std.mem.eql(u8, rc.def.name.text, name)) {
            if (rc.import_spec) |spec| return spec;
            if (rc.alias_of) |src| return resolveModuleValue(self, raw, src, depth + 1);
            return null;
        }
    }
    return null;
}
