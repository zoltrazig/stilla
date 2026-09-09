//! Pass: HIR expression lowering (docs/hir.md §9, PROGRESS S5). In:
//! Ctx + FuncState + an `ExprId`. Out: the CFG value of the expression
//! (null when the expression trapped / is unreachable).
//!
//! Every expression lowers *wrapped*: a `created` snapshot before, and
//! a full-expression boundary (`dropCreatedRange`) after — exactly the
//! sites the direct lowering calls `lowerExpr` (hir.md §5.6 fence
//! semantics ride on the same recursion points). `let`/`seq` bind and
//! discard per the block rules in `hir_lower.zig`'s header.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_path = @import("cfg_lower_path.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");
const hir_lower = @import("hir_lower.zig");
const hir_lower_control = @import("hir_lower_control.zig");
const hir_lower_call = @import("hir_lower_call.zig");
const hir_lower_pattern = @import("hir_lower_pattern.zig");

const Ctx = hir_lower.Ctx;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;
const no_span = hir_lower.no_span;

/// Lower one expression with its full-expression boundary. A `let`/`seq`
/// node is a statement/body shape, not a sub-expression recursion point
/// (hir.md §5.6): the direct path fires fences only where it calls
/// `lowerExpr`, and ends statement blocks with `exitScope` — which the
/// callers of this function model when they push scopes around
/// block-shaped roots. A whole-subtree fence here would drop unbound
/// created temporaries the direct lowering leaves alive (a
/// destructuring `let`'s whole-value base: its leaves are borrowed
/// views, nothing owns the base, and the direct path emits no CFG drop
/// for it), so let/seq nodes get no wrap fence.
pub fn expr(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    if (fs.cur == null) return null;
    const start = fs.created.items.len;
    const result = try exprInner(c, fs, id);
    const name = c.opName(id);
    if (!is(name, "let") and !is(name, "seq")) {
        try cfg_lower_emit.dropCreatedRange(c.self, fs, start, result);
    }
    return result;
}

fn is(t: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, t, name);
}

/// The base name of a typed (rep-parameterized) op: `add.i32` → `add`.
fn typedBase(c: *const Ctx, id: hir.ExprId) []const u8 {
    const name = c.opName(id);
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

fn exprInner(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const self = c.self;
    const n = c.node(id);
    const name = c.opName(id);
    const ops = c.operands(id);

    if (is(name, "const")) {
        // A chain-reached constant (e.g. `m.sub.math.pi`): the access
        // path's loads replay first, exactly like the direct lowering;
        // the constant value itself needs no base.
        _ = try hopChain(c, fs, id);
        return switch (n.ty) {
            .primitive => |p| if (p == .void) cfg_lower_expr.emitVoid(self, fs, no_span) else cfg_lower_expr.emitConst(self, fs, no_span, n.payload.const_value, n.ty),
            else => cfg_lower_expr.emitConst(self, fs, no_span, n.payload.const_value, n.ty),
        };
    }
    if (is(name, "local")) {
        const local = c.localOf(n.payload.binder) orelse
            return self.fail(no_span, "HIR binder has no lowered local", .{});
        return local.value;
    }
    if (is(name, "fn_ref")) return fnRef(c, fs, id, false);
    if (is(name, "module_const")) return moduleConst(c, fs, id);
    if (is(name, "let")) return letNode(c, fs, id);
    if (is(name, "seq")) {
        // Statements in order; each non-last operand is a discarded
        // statement value, the last is the block result (both wrapped).
        for (ops, 0..) |op_id, i| {
            const v = try expr(c, fs, op_id);
            if (i + 1 < ops.len) {
                if (v) |vv| try cfg_lower_expr.discardValue(self, fs, vv);
            } else return v;
        }
        return null;
    }
    if (is(name, "lambda")) {
        // λ literals are hoisted at build time; only their `fn_ref` is
        // an expression (hir_build's `buildLambda`).
        return self.fail(no_span, "internal: a lambda node cannot be an expression", .{});
    }
    if (is(name, "call")) return hir_lower_call.call(c, fs, id);
    if (is(name, "if") or is(name, "and") or is(name, "or")) return hir_lower_control.branch(c, fs, id);
    if (is(name, "match")) return hir_lower_control.match(c, fs, id);

    if (is(name, "struct_make") or is(name, "variant_make") or is(name, "tuple_make") or is(name, "list_make")) {
        return construct(c, fs, id);
    }
    if (is(name, "field_get")) {
        const base = (try expr(c, fs, ops[0])) orelse return null;
        const idx = n.payload.field;
        return switch (base.type_) {
            .named => cfg_lower_emit.emit(self, fs, no_span, .{ .read_field = .{ .base = base, .index = idx } }, n.ty),
            .tuple => cfg_lower_emit.emit(self, fs, no_span, .{ .read_tuple = .{ .base = base, .index = idx } }, n.ty),
            else => self.fail(no_span, "cannot access a member of this value", .{}),
        };
    }
    if (is(name, "move")) return moveNode(c, fs, id);
    if (is(name, "drop")) {
        const arg_id = ops[0];
        const local = c.localOf(c.node(arg_id).payload.binder) orelse
            return self.fail(no_span, "HIR binder has no lowered local", .{});
        try cfg_lower_emit.emitDrop(self, fs, no_span, local.value);
        local.consumed = true;
        return cfg_lower_expr.emitVoid(self, fs, no_span);
    }
    if (is(name, "any_cast") or is(name, "num_cast")) {
        const moving = is(c.opName(ops[0]), "move");
        const v = (try expr(c, fs, ops[0])) orelse return null;
        const target = n.ty;
        const src = v.type_;
        if (src == .primitive and src.primitive == .any) {
            // `any` recovery (Core §11.6.1): an unique target requires a
            // moved source; a Copy target copies the payload out.
            if (cfg_lower_emit.isUnique(self, fs, target) and !moving) {
                return self.fail(no_span, "cannot recover an unique payload from an 'any' without moving it", .{});
            }
            const op: cfg.Op = if (moving) .{ .any_unpack_move = v } else .{ .any_unpack_copy = v };
            const r = try cfg_lower_emit.emit(self, fs, no_span, op, target);
            if (moving) {
                cfg_lower_emit.markConsumed(self, fs, v);
                try cfg_lower_emit.cleanupDisable(self, fs, no_span, v);
            }
            return r;
        }
        return cfg_lower_emit.emit(self, fs, no_span, .{ .num_cast = v }, target);
    }
    if (is(name, "panic")) {
        try cfg_lower_emit.setTerminator(self, fs, .{ .trap = {} });
        return null;
    }

    // The typed (rep-parameterized) numeric families — `add.i32` and
    // friends; the op is chosen by family, the types by the node (the
    // `emit` folder/CSE sees the same shape as the direct lowering).
    const base = typedBase(c, id);
    const operands2 = struct {
        fn two(cc: *Ctx, ffs: *FuncState, ids: []hir.ExprId) LowerError!?[2]*cfg.Value {
            const a = (try expr(cc, ffs, ids[0])) orelse return null;
            const b = (try expr(cc, ffs, ids[1])) orelse return null;
            return .{ a, b };
        }
    };
    if (is(base, "neg") or is(base, "abs") or is(base, "clz") or is(base, "popcount")) {
        const v = (try expr(c, fs, ops[0])) orelse return null;
        const op: cfg.Op = if (is(base, "neg")) .{ .neg = v } else if (is(base, "abs")) .{ .abs = v } else if (is(base, "clz")) .{ .clz = v } else .{ .popcount = v };
        return cfg_lower_emit.emit(self, fs, no_span, op, n.ty);
    }
    if (is(base, "not")) {
        const v = (try expr(c, fs, ops[0])) orelse return null;
        return cfg_lower_emit.emit(self, fs, no_span, .{ .not_ = v }, n.ty);
    }
    const bin: ?[]const u8 = blk: {
        const map = [_]struct { n: []const u8, t: []const u8 }{
            .{ .n = "add", .t = "add" },       .{ .n = "sub", .t = "sub" },
            .{ .n = "mul", .t = "mul" },       .{ .n = "div", .t = "div" },
            .{ .n = "rem", .t = "rem" },       .{ .n = "min", .t = "min" },
            .{ .n = "max", .t = "max" },       .{ .n = "shl", .t = "shl" },
            .{ .n = "shr", .t = "shr" },       .{ .n = "band", .t = "bitand" },
            .{ .n = "bor", .t = "bitor" },     .{ .n = "bxor", .t = "bitxor" },
            .{ .n = "concat", .t = "concat" }, .{ .n = "eq", .t = "eq" },
            .{ .n = "ne", .t = "ne" },         .{ .n = "lt", .t = "lt" },
            .{ .n = "le", .t = "le" },         .{ .n = "gt", .t = "gt" },
            .{ .n = "ge", .t = "ge" },
        };
        for (map) |m| {
            if (is(base, m.n)) break :blk m.t;
        }
        break :blk null;
    };
    if (bin) |tag| {
        const pair = (try operands2.two(c, fs, ops)) orelse return null;
        const op: cfg.Op = if (is(tag, "add")) .{ .add = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "sub")) .{ .sub = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "mul")) .{ .mul = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "div")) .{ .div = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "rem")) .{ .rem = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "min")) .{ .min = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "max")) .{ .max = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "shl")) .{ .shl = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "shr")) .{ .shr = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "bitand")) .{ .bitand = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "bitor")) .{ .bitor = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "bitxor")) .{ .bitxor = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "concat")) .{ .concat = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "eq")) .{ .eq = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "ne")) .{ .ne = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "lt")) .{ .lt = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "le")) .{ .le = .{ .a = pair[0], .b = pair[1] } } else if (is(tag, "gt")) .{ .gt = .{ .a = pair[0], .b = pair[1] } } else .{ .ge = .{ .a = pair[0], .b = pair[1] } };
        return cfg_lower_emit.emit(self, fs, no_span, op, n.ty);
    }
    return self.fail(no_span, "HIR op '{s}' has no CFG lowering", .{name});
}

/// A `fn_ref` node in value position. A member/instance record's value
/// is a `module_ref` + `load_member` pair (the *direct* lowering's
/// value-position form); a λ record's is an `fn_ref` to the hoisted
/// function; an intrinsic record's synthesizes its first-class wrapper
/// (the direct `intrinsicFnRef`); a host binding's is a `load_member`
/// of the binding row. Callee positions bypass this function (the call
/// lowering handles them; see `hir_lower_call`).
pub fn fnRef(c: *Ctx, fs: *FuncState, id: hir.ExprId, callee_ctx: bool) LowerError!?*cfg.Value {
    _ = callee_ctx;
    const self = c.self;
    const built = c.built;
    const n = c.node(id);
    // A leaf reached through module-valued member chains replays them
    // first (the direct lowerPathValue sequence); the final member's
    // load — when there is one — uses the chain's last value as its
    // base instead of a fresh module reference.
    const base = try hopChain(c, fs, id);
    switch (n.payload.func) {
        .func => |fid| {
            const rec = &built.funcs.items[fid];
            switch (rec.kind) {
                .lambda, .instance, .intrinsic => {
                    // A λ, a used generic specialization, or a
                    // first-class intrinsic wrapper is a standalone
                    // module function referenced by name — the direct
                    // path's `fn_ref` of the hoisted λ / of the mono
                    // instance (the direct `lowerSpecialize`:
                    // `{module}.{fn}.{id}`) / of the synthesized
                    // intrinsic wrapper (`intrinsicFnRef`). No member
                    // row exists for an instance (the generic member's
                    // row is null) or an intrinsic wrapper (its
                    // `{member}.intrinsic.{N}` suffix is not a source
                    // member name), so only true members load below.
                    return cfg_lower_emit.emit(self, fs, no_span, .{ .fn_ref = rec.name }, n.ty);
                },
                else => return memberValueRef(c, fs, built, rec, base),
            }
        },
        .host => |hid| {
            const host = built.hosts.items[hid];
            const owner = self.graph.modules[host.module];
            const vm = owner.valueMember(host.name) orelse
                return self.fail(no_span, "host binding '{s}.{s}' vanished", .{ owner.specifier, host.name });
            const mod_ref = base orelse (try cfg_lower_path.emitModuleRef(self, fs, no_span, owner.specifier)) orelse return null;
            return memberLoadHir(c, fs, mod_ref, owner, vm);
        },
    }
}

/// The value-position form of a member/instance function reference:
/// `module_ref` (+ `load_member`), with the direct lowering's
/// self-module caching for the function's own module. `base` is the
/// replay of the node's module access path (when the leaf was reached
/// through module-valued member chains): the final member's row loads
/// on it — never on a fresh module reference — so the AIR chain
/// carries the module identity exactly like the direct lowering.
fn memberValueRef(c: *Ctx, fs: *FuncState, built: *hir.BuiltProgram, rec: *const hir.FuncRecord, base: ?*cfg.Value) LowerError!?*cfg.Value {
    _ = built;
    const self = c.self;
    const owner = self.graph.modules[rec.module];
    const vm = owner.valueMember(memberNameOf(rec)) orelse
        return self.fail(no_span, "function member '{s}' vanished", .{rec.name});
    if (owner.isIntrinsic(vm)) {
        return cfg_lower_intrinsic.intrinsicFnRef(self, fs, no_span, owner, vm, null);
    }
    const mod_ref = base orelse (try moduleRefFor(c, fs, owner));
    return memberLoadHir(c, fs, mod_ref, owner, vm);
}

/// The source member name behind a qualified record name (the last
/// segment that is not a lambda/intrinsic suffix; for member records
/// the name is `{spec}.{fn}`).
fn memberNameOf(rec: *const hir.FuncRecord) []const u8 {
    // Records store qualified names; the owning module's member table
    // is keyed by the bare source name — everything after the module
    // specifier prefix. Walk past "{spec}.".
    const full = rec.name;
    var it = std.mem.splitScalar(u8, full, '.');
    _ = it.first(); // the module specifier (specifiers are single names)
    return it.rest();
}

/// The module reference for a member load: the function's own module
/// uses the cached self reference (the direct lowering's single-name
/// rule); every other module materializes a fresh `module_ref`.
fn moduleRefFor(c: *Ctx, fs: *FuncState, owner: *moduleinfo.ModuleInfo) LowerError!*cfg.Value {
    if (owner == fs.module) {
        return (try cfg_lower_path.selfModuleRef(c.self, fs, no_span)).?;
    }
    return (try cfg_lower_path.emitModuleRef(c.self, fs, no_span, owner.specifier)).?;
}

/// `load_member` with module identity recorded (the direct
/// `lowerMemberLoad`, minus the intrinsic shortcut — callers handle
/// intrinsics before reaching here).
fn memberLoadHir(c: *Ctx, fs: *FuncState, mod_ref: *cfg.Value, owner: *moduleinfo.ModuleInfo, vm: *const moduleinfo.ValueMember) LowerError!?*cfg.Value {
    const member = owner.airMemberIndex(vm) orelse
        return c.self.fail(no_span, "member '{s}' is not in the canonical member table", .{vm.name.text});
    return cfg_lower_emit.emit(c.self, fs, no_span, .{ .load_member = .{ .module = mod_ref, .member = member } }, vm.type_);
}

/// A `module_const` node: the constant's value — an intrinsic constant
/// materializes its specified value (air.md §5.6), a module-valued
/// member loads, everything else is a `load_member` of its member row.
fn moduleConst(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const self = c.self;
    const rec = &c.built.consts.items[c.node(id).payload.module_const];
    const owner = self.graph.modules[rec.module];
    const vm = owner.valueMember(rec.name) orelse
        return self.fail(no_span, "constant '{s}' vanished", .{rec.name});
    const base = try hopChain(c, fs, id);
    if (owner.isIntrinsic(vm)) {
        const bits = cfg_lower_intrinsic.constBits(owner.specifier, vm.name.text) orelse
            return self.fail(no_span, "intrinsic '{s}.{s}' has no expansion", .{ owner.specifier, vm.name.text });
        const v: f32 = @bitCast(bits);
        return cfg_lower_expr.emitConst(self, fs, no_span, .{ .float = v }, vm.type_);
    }
    if (rec.module_spec) |spec| {
        // Module-valued: the reference itself is the value — a leaf
        // under a chain ends at the chain's last hop value.
        return base orelse cfg_lower_path.emitModuleRef(self, fs, no_span, spec);
    }
    const mod_ref = base orelse (try moduleRefFor(c, fs, owner));
    return memberLoadHir(c, fs, mod_ref, owner, vm);
}

/// Replay a value leaf's resolved module access path: `module_ref` of
/// the first hop's module, then one `load_member` per hop with module
/// identity recorded on each result — the direct
/// `cfg_lower_path.lowerPathValue` chain (air.md §7). Returns the last
/// hop's value (module-typed, identity = the final member's module);
/// null when the node carries no path.
fn hopChain(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const hops = c.node(id).access_hops;
    if (hops.len == 0) return null;
    const self = c.self;
    const start = self.graph.modules[hops[0].module];
    var cur = (try cfg_lower_path.emitModuleRef(self, fs, no_span, start.specifier)) orelse return null;
    for (hops) |h| {
        const owner = self.graph.modules[h.module];
        const vm = owner.valueMember(h.name) orelse
            return self.fail(no_span, "module '{s}' has no member '{s}'", .{ owner.specifier, h.name });
        const member = owner.airMemberIndex(vm) orelse
            return self.fail(no_span, "member '{s}' is not in the canonical member table", .{vm.name.text});
        const v = try cfg_lower_emit.emit(self, fs, no_span, .{ .load_member = .{ .module = cur, .member = member } }, vm.type_);
        cur = v orelse return null;
        if (vm.module_spec) |spec| {
            if (self.graph.module(spec)) |target| try self.module_of.put(self.arena, cur, target);
        }
    }
    return cur;
}

/// A `let` node: the init (wrapped), the binder pack/pattern rules of
/// the direct `lowerLet`, then the continuation (the region root).
fn letNode(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const self = c.self;
    const ops = c.operands(id);
    const rid = c.regionsOf(id)[0];
    const region = c.built.program.region(rid);
    const binder_ids = c.built.program.params(rid);

    // Declared-`any` pack (Core §11.6): a plain single-binder let with
    // a declared `any` type materializes the top-type coercion when the
    // init's type differs (the builder recorded the binder's declared
    // type, which is the init's type unless the source declared `any`).
    const init_val = (try expr(c, fs, ops[0])) orelse return null;
    var bound = init_val;
    if (binder_ids.len == 1 and region.pattern == null) {
        const declared = c.built.program.binder(binder_ids[0]).ty;
        if (declared == .primitive and declared.primitive == .any and !cfg.Type.eql(init_val.type_, declared)) {
            if (init_val.ownership == .unique) {
                cfg_lower_emit.markConsumed(self, fs, init_val);
                try cfg_lower_emit.cleanupDisable(self, fs, no_span, init_val);
                bound = (try cfg_lower_emit.emit(self, fs, no_span, .{ .any_pack_move = init_val }, declared)).?;
            } else {
                bound = (try cfg_lower_emit.emit(self, fs, no_span, .{ .any_pack_copy = init_val }, declared)).?;
            }
        }
    }

    if (region.pattern) |pid| {
        // Destructuring let (irrefutable patterns only, hir.md §5.2):
        // `base_owned` is the `move` form of the initializer (the
        // builder records it as a `move` node; the binder modes carry
        // the consuming leaves).
        const moving = is(c.opName(ops[0]), "move");
        try hir_lower_pattern.bindPattern(c, fs, pid, bound, moving);
    } else {
        // Plain identifier bind(s): fresh unique ownership is owned by
        // the binding (Core §10.5) — the direct `bindPattern` leaf rule.
        for (binder_ids) |bid| {
            try hir_lower.bindBinder(c, fs, bid, bound, bound.ownership == .unique and bound.state == .owned);
        }
    }

    // The continuation: a fresh full-expression scope for its operands.
    return expr(c, fs, region.root);
}

/// A `move` node: unique binders emit `move_` (consumed, disarmed,
/// binding marked consumed); Copy binders copy (air.md §5.4).
fn moveNode(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const self = c.self;
    const arg_id = c.operands(id)[0];
    const local = c.localOf(c.node(arg_id).payload.binder) orelse
        return self.fail(no_span, "HIR binder has no lowered local", .{});
    const v = local.value;
    if (v.ownership == .unique) {
        const moved = (try cfg_lower_emit.emit(self, fs, no_span, .{ .move_ = v }, v.type_)).?;
        cfg_lower_emit.markConsumed(self, fs, v);
        try cfg_lower_emit.cleanupDisable(self, fs, no_span, v);
        local.consumed = true;
        return moved;
    }
    return cfg_lower_emit.emit(self, fs, no_span, .{ .copy = v }, v.type_);
}

/// Aggregate construction: operands are already in cfg argument order
/// (the builder wrote struct fields in declaration order, variants /
/// tuples / lists in written order) — emit, then transfer the unique
/// field values (the direct construct tail).
fn construct(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const self = c.self;
    const n = c.node(id);
    const ops = c.operands(id);
    var args = std.ArrayList(*cfg.Value).empty;
    for (ops) |op_id| {
        const v = (try expr(c, fs, op_id)) orelse return null;
        try args.append(self.arena, v);
    }
    const tag: ?u32 = if (is(c.opName(id), "variant_make")) n.payload.tag else null;
    const result = try cfg_lower_emit.emit(self, fs, no_span, .{ .construct = .{ .tag = tag, .args = args.items } }, n.ty);
    for (args.items) |a| {
        if (a.ownership == .unique and !cfg_lower_emit.isConsumed(fs, a)) {
            cfg_lower_emit.markConsumed(self, fs, a);
            try cfg_lower_emit.cleanupDisable(self, fs, no_span, a);
        }
    }
    return result;
}
