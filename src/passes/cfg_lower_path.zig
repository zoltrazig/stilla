//! Pass: path expression lowering — `path-expression` (Core §2.5, §2.7).
//! In: Lowerer + FuncState + ast.PathExpr / Member / Index, module graph.
//! Out: CFG value for the resolved path (local, module ref, or member loads).
const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const lower = @import("../lower.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

pub fn lowerPath(self: *Lowerer, fs: *FuncState, p: *const ast.PathExpr) LowerError!?*cfg.Value {
    return switch (p.tail) {
        .construct => |sc| try cfg_lower_expr.lowerStructConstruct(self, fs, p, &sc),
        .variant => |ve| try cfg_lower_expr.lowerVariantConstruct(self, fs, p, &ve),
        .none => try lowerPathValue(self, fs, p),
    };
}

/// A dotted value path: a local, a module value, or module members
/// (`math.sqrt`, `app.calc.add` — Core §2.5, §2.7).
pub fn lowerPathValue(self: *Lowerer, fs: *FuncState, p: *const ast.PathExpr) LowerError!?*cfg.Value {
    const path = p.path;
    if (path.len == 1) {
        const n = path[0].text;
        if (cfg_lower_emit.lookupLocal(fs, n)) |local| return local.value;
        if (fs.module.module_values.get(n)) |spec| return emitModuleRef(self, fs, path[0].span, spec);
        if (fs.module.valueMember(n)) |vm| {
            const self_ref = (try selfModuleRef(self, fs, path[0].span)).?;
            return lowerMemberLoad(self, fs, path[0].span, self_ref, vm);
        }
        return self.fail(p.span, "unknown name '{s}'", .{n});
    }
    // A dotted path whose first segment is a local value walks the
    // remaining segments as member loads on that value — e.g. `file.fd`
    // on the destruction view inside a drop hook (Core §9.2). Locals
    // shadow module names, matching the single-segment resolution.
    if (cfg_lower_emit.lookupLocal(fs, path[0].text)) |local| {
        var cur = local.value;
        for (path[1..]) |seg| {
            cur = (try memberLoad(self, fs, seg.span, cur, seg.text)) orelse return null;
        }
        return cur;
    }
    const spec = fs.module.module_values.get(path[0].text) orelse
        return self.fail(p.span, "'{s}' does not name a module", .{path[0].text});
    var mod = self.graph.module(spec) orelse
        return self.fail(p.span, "module '{s}' is not loaded", .{spec});
    var cur = try emitModuleRef(self, fs, path[0].span, spec);
    for (path[1..]) |seg| {
        const vm = mod.valueMember(seg.text) orelse
            return self.fail(seg.span, "module '{s}' has no member '{s}'", .{ mod.specifier, seg.text });
        cur = try lowerMemberLoad(self, fs, seg.span, cur.?, vm);
        if (vm.module_spec) |mspec| {
            mod = self.graph.module(mspec) orelse
                return self.fail(seg.span, "module '{s}' is not loaded", .{mspec});
        }
    }
    return cur;
}

/// The function's own module reference, created once per function.
pub fn selfModuleRef(self: *Lowerer, fs: *FuncState, span: ast.Span) LowerError!?*cfg.Value {
    if (fs.self_module) |v| return v;
    const v = try emitModuleRef(self, fs, span, fs.module.specifier);
    fs.self_module = v;
    return v;
}

/// `module_ref "spec"` with module identity recorded.
pub fn emitModuleRef(self: *Lowerer, fs: *FuncState, span: ast.Span, specifier: []const u8) LowerError!?*cfg.Value {
    const v = try cfg_lower_emit.emit(self, fs, span, .{ .module_ref = specifier }, .module);
    if (v) |vv| {
        if (self.graph.module(specifier)) |target| try self.module_of.put(self.arena, vv, target);
    }
    return v;
}

/// `load_member %module, #slot` with module identity carried through
/// for module-valued members.
pub fn lowerMemberLoad(
    self: *Lowerer,
    fs: *FuncState,
    span: ast.Span,
    module_value: *cfg.Value,
    vm: *const moduleinfo.ValueMember,
) LowerError!?*cfg.Value {
    const v = try cfg_lower_emit.emit(self, fs, span, .{ .load_member = .{ .module = module_value, .slot = vm.slot } }, vm.type_);
    if (vm.module_spec) |spec| {
        if (v) |vv| {
            if (self.graph.module(spec)) |target| try self.module_of.put(self.arena, vv, target);
        }
    }
    return v;
}

/// `object.name`: a struct field, a tuple element, or a module member.
pub fn lowerMember(self: *Lowerer, fs: *FuncState, m: *const ast.Member) LowerError!?*cfg.Value {
    const base = (try cfg_lower_expr.lowerExpr(self, fs, m.object)) orelse return null;
    return memberLoad(self, fs, m.name.span, base, m.name.text);
}

/// Load member `name` of a value: a struct field (`read_field`), a
/// tuple element (`read_tuple`), or a module member (`load_member`).
pub fn memberLoad(self: *Lowerer, fs: *FuncState, span: ast.Span, base: *cfg.Value, name: []const u8) LowerError!?*cfg.Value {
    // Module-valued bases: a member load on the referenced module.
    if (self.module_of.get(base)) |target| {
        const vm = target.valueMember(name) orelse
            return self.fail(span, "module '{s}' has no member '{s}'", .{ target.specifier, name });
        return lowerMemberLoad(self, fs, span, base, vm);
    }
    switch (base.type_) {
        .named => |type_name| {
            const sd = moduleinfo.structDecl(self.resolve, fs.module, type_name) orelse
                return self.fail(span, "'{s}' is not a struct type", .{type_name});
            const idx = moduleinfo.fieldIndex(sd, name) orelse
                return self.fail(span, "struct '{s}' has no field '{s}'", .{ type_name, name });
            const field_type = try self.resolveType(fs, &sd.fields[idx].type_);
            return cfg_lower_emit.emit(self, fs, span, .{ .read_field = .{ .base = base, .index = idx } }, field_type);
        },
        .tuple => |elems| {
            const idx = std.fmt.parseInt(usize, name, 10) catch
                return self.fail(span, "tuple elements are indexed numerically", .{});
            if (idx >= elems.len) return self.fail(span, "tuple element #{d} out of range", .{idx});
            return cfg_lower_emit.emit(self, fs, span, .{ .read_tuple = .{ .base = base, .index = @intCast(idx) } }, elems[idx]);
        },
        else => return self.fail(span, "cannot access a member of this value", .{}),
    }
}

/// `object@[index]`: a list read with a bounds check (Runtime §7.2).
pub fn lowerIndex(self: *Lowerer, fs: *FuncState, ix: *const ast.Index) LowerError!?*cfg.Value {
    const base = (try cfg_lower_expr.lowerExpr(self, fs, ix.object)) orelse return null;
    const idx = (try cfg_lower_expr.lowerExpr(self, fs, ix.index)) orelse return null;
    const elem_type = switch (base.type_) {
        .list => |inner| inner.*,
        else => return self.fail(ix.span, "indexing requires a list", .{}),
    };
    return cfg_lower_emit.emit(self, fs, ix.span, .{ .read_index = .{ .base = base, .index = idx } }, elem_type);
}

/// Join a dotted path into a single written name (`app.calc`).
pub fn joinPath(self: *Lowerer, path: []const ast.Ident) LowerError![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    for (path, 0..) |id, i| {
        if (i > 0) try buf.append(self.arena, '.');
        try buf.appendSlice(self.arena, id.text);
    }
    return buf.toOwnedSlice(self.arena);
}
