//! Pass: path expression lowering — the path-expression nud and member
//! forms (Binding Power Table document; Core §2.5, §2.7).
//! In: Lowerer + FuncState + ast.PathExpr / Member / Index, module graph.
//! Out: CFG value for the resolved path (local, module ref, or member loads).
const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const type_resolve = @import("type_resolve.zig");
const lower = @import("stilla").lower;
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

pub fn lowerPath(self: *Lowerer, fs: *FuncState, e: *const ast.Expr, p: *const ast.PathExpr) LowerError!?*cfg.Value {
    return switch (p.tail) {
        .construct => |sc| try cfg_lower_expr.lowerStructConstruct(self, fs, e, p, &sc),
        .variant => |ve| try cfg_lower_expr.lowerVariantConstruct(self, fs, e, p, &ve),
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
        // A `using` alias of a module value member (Core §2.8) resolves to
        // the member: `using string.upper as up; up(text)` is a
        // `load_member` of `string.upper`.
        for (fs.module.using_aliases) |a| {
            if (!std.mem.eql(u8, a.name, n)) continue;
            switch (a.target) {
                .value => |mr| {
                    const mod = self.graph.module(mr.module) orelse continue;
                    const vm = mod.valueMember(mr.name) orelse continue;
                    const mod_ref = try emitModuleRef(self, fs, path[0].span, mr.module);
                    return lowerMemberLoad(self, fs, path[0].span, mod_ref.?, vm);
                },
                .module, .type => continue,
            }
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
    // Intermediate segments chain through module-valued members.
    var cur: ?*cfg.Value = null;
    for (path[1 .. path.len - 1]) |seg| {
        const vm = mod.valueMember(seg.text) orelse
            return self.fail(seg.span, "module '{s}' has no member '{s}'", .{ mod.specifier, seg.text });
        if (cur == null) cur = try emitModuleRef(self, fs, path[0].span, spec);
        cur = try lowerMemberLoad(self, fs, seg.span, cur.?, vm);
        if (vm.module_spec) |mspec| {
            mod = self.graph.module(mspec) orelse
                return self.fail(seg.span, "module '{s}' is not loaded", .{mspec});
        }
    }
    // The final segment: an intrinsic member never touches the module
    // value — its constant or wrapper value materializes without a
    // `module_ref`/`load_member` pair (intrinsic plan, phases 2–3).
    const tail = path[path.len - 1];
    const vm = mod.valueMember(tail.text) orelse
        return self.fail(tail.span, "module '{s}' has no member '{s}'", .{ mod.specifier, tail.text });
    if (mod.isIntrinsic(vm)) return try intrinsicMemberValue(self, fs, tail.span, mod, vm);
    if (cur == null) cur = try emitModuleRef(self, fs, path[0].span, spec);
    return lowerMemberLoad(self, fs, tail.span, cur.?, vm);
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

/// The use-site value of an intrinsic member: a constant materializes
/// its specified value (Intrinsics §3; air.md §5.6); a function member
/// lowers to a `fn_ref` to the synthesized wrapper (intrinsic plan,
/// phase 3). No member row is read.
fn intrinsicMemberValue(
    self: *Lowerer,
    fs: *FuncState,
    span: ast.Span,
    owner: *moduleinfo.ModuleInfo,
    vm: *const moduleinfo.ValueMember,
) LowerError!?*cfg.Value {
    switch (vm.decl) {
        .const_ => {
            const bits = cfg_lower_intrinsic.constBits(owner.specifier, vm.name.text) orelse
                return self.fail(span, "intrinsic '{s}.{s}' has no expansion", .{ owner.specifier, vm.name.text });
            const value: f32 = @bitCast(bits);
            return cfg_lower_expr.emitConst(self, fs, span, .{ .float = value }, vm.type_);
        },
        .func => {
            // A bare path only reaches here with a concrete signature:
            // the checker rejects an unspecialized generic used as a
            // value (Core §12.4).
            return cfg_lower_intrinsic.intrinsicFnRef(self, fs, span, owner, vm, null);
        },
    }
}

/// `load_member %module, #member` with module identity carried through
/// for module-valued members. The operand is the member index (an index
/// into the module's member table, air.md §7), distinct from the storage
/// slot of a constant member.
pub fn lowerMemberLoad(
    self: *Lowerer,
    fs: *FuncState,
    span: ast.Span,
    module_value: *cfg.Value,
    vm: *const moduleinfo.ValueMember,
) LowerError!?*cfg.Value {
    // An intrinsic constant materializes its specified value at the use
    // site (Intrinsics §3; air.md §5.6); an intrinsic *function* member
    // in value position lowers to the synthesized wrapper's `fn_ref`
    // (intrinsic plan, phase 3).
    if (self.module_of.get(module_value)) |owner| {
        if (owner.isIntrinsic(vm)) return intrinsicMemberValue(self, fs, span, owner, vm);
        // The canonical member-table index compacts past the module's
        // intrinsic rows (air.md §5.6) — distinct from the source-level
        // `ValueMember.slot` in a mixed member table.
        const member = owner.airMemberIndex(vm) orelse
            return self.fail(span, "member '{s}' is not in the canonical member table", .{vm.name.text});
        const v = try cfg_lower_emit.emit(self, fs, span, .{ .load_member = .{ .module = module_value, .member = member } }, vm.type_);
        if (vm.module_spec) |spec| {
            if (v) |vv| {
                if (self.graph.module(spec)) |target| try self.module_of.put(self.arena, vv, target);
            }
        }
        return v;
    }
    return self.fail(span, "module value has no owning module", .{});
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
        .named => |td| {
            const type_name = self.resolve.typeNameOf(td.id) orelse return null;
            const sd = moduleinfo.structDecl(self.resolve, fs.module, type_name) orelse
                return self.fail(span, "'{s}' is not a struct type", .{type_name});
            const idx = moduleinfo.fieldIndex(sd, name) orelse
                return self.fail(span, "struct '{s}' has no field '{s}'", .{ type_name, name });
            const resolved = try self.resolveType(fs, &sd.fields[idx].type_);
            // A generic instantiation's field type substitutes the
            // declaration's type parameters (`p.first` of a
            // `Pair[int32, str]` is `int32`).
            const field_type = type_resolve.substParams(self.arena, sd.type_params, td.args, resolved);
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

/// Join a dotted path into a single written name (`app.calc`).
pub fn joinPath(self: *Lowerer, path: []const ast.Ident) LowerError![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (path, 0..) |id, i| {
        if (i > 0) try buf.append(self.arena, '.');
        try buf.appendSlice(self.arena, id.text);
    }
    return buf.toOwnedSlice(self.arena);
}
