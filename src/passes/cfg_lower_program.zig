//! Pass: program lowering and entry selection — `program` (air.md §11).
//! In: Lowerer + module graph (every module materialized and checked).
//! Out: the `cfg.IrProgram` with module, function, and constant tables,
//! and the host-selected entry function ({spec}.{fn} qualified name).
const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_module = @import("cfg_lower_module.zig");

const Lowerer = lower.Lowerer;
const LowerError = lower.LowerError;

/// Lower the whole program: every module of the graph (frontend.md §2).
pub fn lowerProgram(self: *Lowerer) LowerError!cfg.IrProgram {
    var ir_modules = std.ArrayList(*cfg.IrModule).empty;
    var ir_funcs = std.ArrayList(*cfg.IrFunc).empty;
    for (self.graph.modules) |info| {
        const m = try cfg_lower_module.lowerModule(self, info);
        try ir_modules.append(self.arena, m);
        for (m.funcs) |f| try ir_funcs.append(self.arena, f);
    }
    var program = cfg.IrProgram{
        .modules = try self.arena.dupe(*cfg.IrModule, ir_modules.items),
        .funcs = try self.arena.dupe(*cfg.IrFunc, ir_funcs.items),
        .types = try collectTypeEnv(self),
        .entry = null,
    };
    // Host-selected entry: a function of the entry module named by
    // `entry_fn` (the runtime convention is `main`, Runtime §3.3).
    // Function names are module-qualified, so compare against the
    // entry module's qualified spelling.
    //
    // The implicit default (`main`) is selected by convention: a
    // module without `main` is legal (a library module) and simply
    // has no entry — the CLI does not error for the default. Only an
    // explicitly named entry that does not exist is a diagnostic.
    if (self.entry_fn) |want| {
        const qualified = try qualifiedName(self, self.graph.entry.specifier, want);
        for (program.funcs) |f| {
            if (std.mem.eql(u8, f.name.text, qualified)) {
                program.entry = f;
                break;
            }
        }
        if (program.entry == null and self.entry_fn_explicit) {
            const span = if (self.graph.entry.source) |s|
                ast.Span.init(s.id, 0, 0)
            else
                ast.Span.init(0, 0, 0);
            return self.fail(span, "entry function '{s}' not found in module '{s}'", .{ want, self.graph.entry.specifier });
        }
    }
    return program;
}

/// Build the program's type environment (air.md §9.1): one `TypeDecl` per
/// `TypeId`, indexed by the same `TypeId` `Type.named` carries — the
/// concrete layout (struct fields, union variants, declared ownership,
/// drop hook, opaque `host_id`) resolved from the module graph, so a
/// consumer can interpret `construct` / `unpack_*` / `drop` over a named
/// type from the program alone. Generic templates are included (a raw
/// template reference stays addressable) with deferred ownership;
/// aliases expand and leave no entry.
fn collectTypeEnv(self: *Lowerer) LowerError![]cfg.TypeDecl {
    const count = self.graph.type_interner.to_name.items.len;
    const decls = try self.arena.alloc(cfg.TypeDecl, count);
    for (decls) |*d| d.* = .{ .unknown = "" }; // defensive: every id is filled below
    for (self.graph.modules) |info| {
        for (info.types) |*tm| {
            // Aliases expand and leave no entry (Core §11.2).
            if (tm.decl == .alias) continue;
            const full = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ info.specifier, tm.name.text });
            const id = self.resolve.type_ids.?.idOf(full) orelse continue;
            decls[id] = try lowerTypeDecl(self, info, tm, full, id);
        }
    }
    return decls;
}

/// One concrete `TypeDecl` from a module's type member (air.md §9.1):
/// fields/variants resolved to AIR-native types (a generic declaration's
/// components keep their type parameters as `Type.param`), the declared
/// ownership, the hidden drop-hook name, and the opaque host identity.
fn lowerTypeDecl(
    self: *Lowerer,
    info: *moduleinfo.ModuleInfo,
    tm: *moduleinfo.TypeMember,
    qname: []const u8,
    id: cfg.TypeId,
) LowerError!cfg.TypeDecl {
    const module = info.specifier;
    const name = tm.name.text;
    const generic = switch (tm.decl) {
        .struct_ => |s| s.type_params.len > 0,
        .union_ => |u| u.type_params.len > 0,
        .opaque_ => |o| o.type_params.len > 0,
        .alias => unreachable,
    };
    return switch (tm.decl) {
        .struct_ => |s| .{
            .struct_ = .{
                .name = name,
                .module = module,
                .type_params = try typeParamNames(self, s.type_params),
                // A generic struct's ownership depends on its instantiation's
                // type arguments (`Option[int32]` vs `Option[File]`) — the
                // declared class is deferred (null) and resolved per
                // instantiation by `IrProgram.namedOwnership`. A non-generic
                // struct's ownership is structural; a drop hook implies
                // unique (air.md §9.1).
                .ownership = if (generic) null else moduleinfo.ownershipOf(self.resolve, info, .{ .named = .{ .id = id, .args = &.{} } }),
                .drop = if (s.drop) |_| try std.fmt.allocPrint(self.arena, "{s}.drop", .{qname}) else null,
                .fields = try lowerFields(self, info, s.fields),
            },
        },
        .union_ => |u| .{ .union_ = .{
            .name = name,
            .module = module,
            .type_params = try typeParamNames(self, u.type_params),
            .ownership = if (generic) null else moduleinfo.ownershipOf(self.resolve, info, .{ .named = .{ .id = id, .args = &.{} } }),
            .variants = try lowerVariants(self, info, u.variants),
        } },
        .opaque_ => .{
            .opaque_ = .{
                .name = name,
                .module = module,
                // Unique by declaration (Core §11.8): an opaque type's
                // ownership never depends on its type arguments.
                .ownership = .unique,
                .host_id = .{ .host_module = module, .type_name = name },
            },
        },
        .alias => unreachable,
    };
}

/// The declaration's type-parameter names, in declaration order.
fn typeParamNames(self: *Lowerer, params: []const ast.Ident) LowerError![]const []const u8 {
    const names = try self.arena.alloc([]const u8, params.len);
    for (params, 0..) |p, i| names[i] = p.text;
    return names;
}

/// Resolve a struct's field declarations to AIR-native types (generic
/// declarations keep their type parameters as `Type.param`).
fn lowerFields(self: *Lowerer, info: *moduleinfo.ModuleInfo, fields: []const ast.FieldDecl) LowerError![]cfg.FieldDecl {
    const out = try self.arena.alloc(cfg.FieldDecl, fields.len);
    for (fields, 0..) |f, i| {
        const ft = moduleinfo.resolveType(self.resolve, info, &f.type_) orelse
            return self.fail(f.span, "cannot resolve field type", .{});
        out[i] = .{ .name = f.name.text, .type_ = ft };
    }
    return out;
}

/// Resolve a union's variant payload types to AIR-native types (generic
/// declarations keep their type parameters as `Type.param`).
fn lowerVariants(self: *Lowerer, info: *moduleinfo.ModuleInfo, variants: []const ast.VariantDecl) LowerError![]cfg.VariantDecl {
    const out = try self.arena.alloc(cfg.VariantDecl, variants.len);
    for (variants, 0..) |v, i| {
        var payloads = std.ArrayList(cfg.Type).empty;
        if (v.types) |types| for (types) |*t| {
            const pt = moduleinfo.resolveType(self.resolve, info, t) orelse
                return self.fail(t.span(), "cannot resolve variant payload type", .{});
            try payloads.append(self.arena, pt);
        };
        out[i] = .{ .name = v.name.text, .payloads = try payloads.toOwnedSlice(self.arena) };
    }
    return out;
}

/// The module-qualified spelling of a function name ({spec}.{fn}).
pub fn qualifiedName(self: *Lowerer, specifier: []const u8, name: []const u8) LowerError![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ specifier, name });
}
