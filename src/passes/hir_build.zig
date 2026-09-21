//! Pass: annotated AST → canonical HIR — driver (hir.md §11 M1a,
//! phase S4). Owns `Builder` (the per-program build state), the two
//! entry points, the module/function inventory passes, and the cfg
//! type-environment mapping. Expression, block, path, call, control,
//! and pattern construction live in the sibling `hir_build_*.zig`
//! files; the full encoding contract is in this file's original
//! header (PROGRESS.md, S4 设计决定).

const std = @import("std");
const ast = @import("stilla").ast;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const lower = @import("stilla").lower;
const moduleinfo = @import("stilla").moduleinfo;
const checker = @import("stilla").checker;
const hir_build_block = @import("hir_build_block.zig");
const hir_build_expr = @import("hir_build_expr.zig");
const hir_build_cleanup = @import("hir_build_cleanup.zig");
pub const BuildError = error{ OutOfMemory, Diagnostic };

/// Program-wide first-class intrinsic wrapper cache key: the declaring
/// Key of the program-wide first-class intrinsic wrapper cache: the
/// declaring module's identity, the member's slot in its member table,
/// and the concrete specialization (the instance id, or `maxInt(u32)` for
/// non-generic members). The shared `lower.IntrinsicKey`, so the HIR
/// builder's and the CFG lowerer's wrapper caches key identically.
pub const WrapperKey = lower.IntrinsicKey;

/// The AST→HIR builder: one per whole-program build.
pub const Builder = struct {
    arena: std.mem.Allocator,
    graph: *moduleinfo.ModuleGraph,
    resolve: moduleinfo.Resolve,
    ann: *const checker.Annotation,
    built: *hir.BuiltProgram,

    /// Per-module hoisted-record pending lists (λ completion order,
    /// wrapper creation order); cleared per module.
    pending_lambdas: std.ArrayListUnmanaged(hir.FuncId) = .empty,
    pending_wrappers: std.ArrayListUnmanaged(hir.FuncId) = .empty,
    /// Global counters (λ/wrapper names must be unique across the whole
    /// program, cfg lowering's `next_lambda_id` / `next_intrinsic_id`).
    next_lambda_id: u32 = 0,
    next_intrinsic_id: u32 = 0,
    /// Program-wide first-class intrinsic wrapper cache.
    wrapper_cache: std.AutoHashMapUnmanaged(WrapperKey, hir.FuncId) = .empty,
    /// Body AST per predeclared FuncId (parallel to `funcs`; the
    /// `bodies` entry at `fid` is that function's `ast.Block`, or null
    /// for the module init). Transient build-time state — S5 consumes
    /// the HIR trees, never the AST.
    bodies: std.ArrayListUnmanaged(?*const ast.Block) = .empty,
    /// Name → id lookup tables (keys are qualified: `{spec}.{name}`,
    /// instances `{spec}.{fn}.{id}`). Filled at predeclare time so
    /// forward references resolve.
    func_ids: std.StringHashMapUnmanaged(hir.FuncId) = .empty,
    const_ids: std.StringHashMapUnmanaged(hir.ConstId) = .empty,
    host_ids: std.StringHashMapUnmanaged(hir.HostBindingId) = .empty,
    /// Source name of each pattern leaf binder (identifier patterns and
    /// struct-field shorthands don't carry the name structurally).
    pat_names: std.AutoHashMapUnmanaged(hir.BinderId, []const u8) = .empty,

    /// Lexical env stack. Names in scope for lookup; every binder is
    /// declared by exactly one region, so the stack mirrors the source
    /// scoping the HIR regions will reproduce.
    scopes: std.ArrayList(EnvScope) = .empty,
    /// Block-level `using` aliases that name *module values* (compile-
    /// time identities; value-member aliases become let leaves instead).
    module_aliases: std.ArrayList(ModuleAlias) = .empty,
    /// Depth markers for function-like bodies: a member/λ/hook/const
    /// body resets env and alias visibility (no capture, no leaking
    /// block aliases across a function boundary).
    env_depth: usize = 0,
    alias_depth: usize = 0,

    /// Source name of the function whose body is being built (the λ
    /// name chain base, mirroring `FuncState.name`).
    fn_name: []const u8 = "",
    cur_func: ?hir.FuncId = null,

    diag: ?moduleinfo.Diag = null,

    const EnvScope = struct {
        names: std.ArrayList(EnvName) = .empty,
    };
    const EnvName = struct {
        text: []const u8,
        binder: hir.BinderId,
    };
    const ModuleAlias = struct {
        name: []const u8,
        specifier: []const u8,
    };

    pub fn init(arena: std.mem.Allocator, graph: *moduleinfo.ModuleGraph, ann: *const checker.Annotation) BuildError!Builder {
        const built = try arena.create(hir.BuiltProgram);
        built.* = .{ .arena = arena, .program = try hir.Program.init(arena) };
        return .{
            .arena = arena,
            .graph = graph,
            .resolve = moduleinfo.resolveOf(graph),
            .ann = ann,
            .built = built,
        };
    }

    pub fn fail(self: *Builder, span: meta.Span, comptime fmt: []const u8, args: anytype) BuildError {
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        self.diag = .{ .span = span, .message = msg };
        return error.Diagnostic;
    }

    pub fn modIdx(self: *Builder, specifier: []const u8) BuildError!u32 {
        for (self.built.modules.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.specifier, specifier)) return @intCast(i);
        }
        return self.fail(meta.Span.init(0, 0, 0), "module '{s}' is not built", .{specifier});
    }

    /// Registry lookup with a source span for the diagnostic. New rows
    /// are data edits in hir.zig's `typed_descriptors`; a missing row is
    /// a loud builder error, never a silent fallback.
    pub fn op(self: *Builder, span: meta.Span, name: []const u8) BuildError!hir.OpId {
        return hir.opId(name) orelse
            self.fail(span, "HIR op '{s}' is not registered (add a typed_descriptors row)", .{name});
    }

    /// Intern the source span of the AST construct being built (hir.md
    /// §3.2 `origins` side table) for the node under construction.
    /// Synthetic nodes simply do not set `.origin`.
    pub fn origin(self: *Builder, span: meta.Span) BuildError!hir.SourceOriginId {
        return self.built.program.addOrigin(span);
    }

    // -- environment --------------------------------------------------------

    pub fn pushScope(self: *Builder) !void {
        try self.scopes.append(self.arena, .{});
    }

    pub fn popScope(self: *Builder) void {
        _ = self.scopes.pop();
    }

    pub fn bindName(self: *Builder, text: []const u8, binder: hir.BinderId) !void {
        try self.scopes.items[self.scopes.items.len - 1].names.append(self.arena, .{ .text = text, .binder = binder });
    }

    /// Local binding lookup through the scope stack (innermost wins).
    /// Names never cross a function-like body boundary (`env_depth`):
    /// an inner function body cannot see the caller's locals.
    pub fn lookup(self: *Builder, text: []const u8) ?hir.BinderId {
        var i = self.scopes.items.len;
        while (i > self.env_depth) {
            i -= 1;
            const scope = &self.scopes.items[i];
            var j = scope.names.items.len;
            while (j > 0) {
                j -= 1;
                const n = scope.names.items[j];
                if (std.mem.eql(u8, n.text, text)) return n.binder;
            }
        }
        return null;
    }

    pub fn pushModuleAlias(self: *Builder, name: []const u8, specifier: []const u8) !void {
        try self.module_aliases.append(self.arena, .{ .name = name, .specifier = specifier });
    }

    /// Resolve a block-level module alias (innermost wins).
    pub fn aliasModule(self: *Builder, name: []const u8) ?[]const u8 {
        var i = self.module_aliases.items.len;
        while (i > self.alias_depth) {
            i -= 1;
            const a = self.module_aliases.items[i];
            if (std.mem.eql(u8, a.name, name)) return a.specifier;
        }
        return null;
    }

    // -- program-level helpers ----------------------------------------------

    pub fn qualified(self: *Builder, specifier: []const u8, name: []const u8) BuildError![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ specifier, name });
    }

    pub fn funcType(self: *Builder, params: []meta.Param, ret: meta.Type) BuildError!meta.Type {
        const rp = try self.arena.create(meta.Type);
        rp.* = ret;
        return .{ .function = .{ .params = params, .ret = rp } };
    }

    /// The checker's annotated type of an expression in module `info`.
    pub fn annotatedType(self: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr) ?meta.Type {
        const ma = self.ann.per_module.get(info.specifier) orelse return null;
        return ma.expr_of.get(e);
    }

    pub fn resolveType(self: *Builder, info: *moduleinfo.ModuleInfo, t: *const ast.Type) BuildError!meta.Type {
        return moduleinfo.resolveType(self.resolve, info, t) orelse
            self.fail(t.span(), "cannot resolve type", .{});
    }
};

pub fn isVoid(t: meta.Type) bool {
    return t == .primitive and t.primitive == .void;
}

pub fn isNever(t: meta.Type) bool {
    return t == .primitive and t.primitive == .never;
}

pub fn typeNameOf(b: *Builder, id: meta.TypeId) ?[]const u8 {
    return b.resolve.typeNameOf(id);
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

/// Build the HIR for the whole graph. Pass 1 predeclares module records,
/// module constants, and host-binding records (in module order) so every
/// cross-module reference resolves. Pass 2, per module: predeclare the
/// cfg-ordered function records (init?, non-generic members, instances,
/// drop hooks), build the module-constant initializers, then build
/// member/instance/hook bodies — hoisting λ literals and first-class
/// intrinsic values as they are discovered; hoisted records are ordered
/// at the module end.
pub fn buildProgram(arena: std.mem.Allocator, graph: *moduleinfo.ModuleGraph, ann: *const checker.Annotation) BuildError!*hir.BuiltProgram {
    return buildProgramDiag(arena, graph, ann, null);
}

/// Re-exported sibling entry points (the whole-program entry is above; the
/// per-node builders moved to `hir_build_expr.zig` / `hir_build_block.zig`).
pub const buildExpr = hir_build_expr.buildExpr;
pub const buildBlock = hir_build_block.buildBlock;

/// `buildProgram` with the first diagnostic reported through `diag_out`
/// (a view of the builder's arena-owned message) when the build fails.
pub fn buildProgramDiag(arena: std.mem.Allocator, graph: *moduleinfo.ModuleGraph, ann: *const checker.Annotation, diag_out: ?*moduleinfo.Diag) BuildError!*hir.BuiltProgram {
    var b = try Builder.init(arena, graph, ann);
    buildProgramInner(&b) catch |err| {
        if (err == error.Diagnostic) {
            if (diag_out) |d| {
                if (b.diag) |msg| d.* = msg;
            }
        }
        return err;
    };
    return b.built;
}

fn buildProgramInner(b: *Builder) BuildError!void {
    for (b.graph.modules) |info| try predeclareModule(b, info);
    for (b.graph.modules) |info| try buildModuleFuncs(b, info);
    b.built.types = try collectTypeEnv(b);
    // Full-expression cleanup registration (docs/effects.md §11.2) —
    // needs the type environment for the ownership class of named types.
    try hir_build_cleanup.register(b);
}

/// Pass 1, one module: the module record, its constant records (in
/// value-member declaration order), and its host/intrinsic function
/// records (every bodyless function member: both ordinary host bindings
/// and bundle intrinsics lower to (module, member) syscall targets; the
/// use position decides wrapper-vs-syscall at S5).
fn predeclareModule(b: *Builder, info: *moduleinfo.ModuleInfo) BuildError!void {
    const mi: u32 = @intCast(b.built.modules.items.len);
    try b.built.modules.append(b.built.arena, .{
        .specifier = info.specifier,
        .funcs = .{ .start = @intCast(b.built.funcs.items.len), .len = 0 },
        .consts = .{ .start = @intCast(b.built.consts.items.len), .len = 0 },
    });
    for (info.values) |*vm| {
        switch (vm.decl) {
            .const_ => |c| {
                const key = try b.qualified(info.specifier, vm.name.text);
                var rec = hir.ConstRecord{
                    .name = vm.name.text,
                    .module = mi,
                    .type_ = vm.type_,
                    .key = key,
                    .init = null,
                };
                if (vm.module_spec) |spec| {
                    rec.module_spec = spec;
                } else if (c.init != null and !isVoid(vm.type_) and !info.isIntrinsic(vm)) {
                    rec.slot = try constSlot(b, info, vm);
                }
                try b.built.consts.append(b.arena, rec);
                try b.const_ids.put(b.arena, key, @intCast(b.built.consts.items.len - 1));
            },
            .func => |f| if (f.body == null) {
                const key = try b.qualified(info.specifier, vm.name.text);
                try b.built.hosts.append(b.arena, .{ .module = mi, .name = vm.name.text, .signature = vm.type_, .key = key });
                try b.host_ids.put(b.arena, key, @intCast(b.built.hosts.items.len - 1));
            },
        }
    }
    const cs = b.built.modules.items[mi].consts;
    b.built.modules.items[mi].consts.len = @intCast(b.built.consts.items.len - cs.start);
}

/// The storage slot of a constant member among the module's slot-bearing
/// consts (mirror the direct constSlot rule).
fn constSlot(_: *Builder, info: *moduleinfo.ModuleInfo, vm: *const moduleinfo.ValueMember) BuildError!?u32 {
    var n: u32 = 0;
    for (info.values) |*v| {
        if (v == vm) return n;
        if (v.decl == .const_) {
            const c = v.decl.const_;
            if (v.module_spec == null and !isVoid(v.type_) and !info.isIntrinsic(v) and c.init != null) n += 1;
        }
    }
    return null;
}

/// Pass 2, one module: predeclare function records, then build const
/// initializers and the member/instance/hook bodies (cfg lowering's
/// walk order), then order hoisted records at the module end.
fn buildModuleFuncs(b: *Builder, info: *moduleinfo.ModuleInfo) BuildError!void {
    const mi = try b.modIdx(info.specifier);
    b.pending_lambdas.clearRetainingCapacity();
    b.pending_wrappers.clearRetainingCapacity();
    const m = &b.built.modules.items[mi];
    m.funcs.start = @intCast(b.built.funcs.items.len);
    m.init_func = null;

    // init — every source / standard-library module except `builtin`
    // and host modules (the direct lowerModule rule).
    if (info.kind != .host and !std.mem.eql(u8, info.specifier, "builtin")) {
        const fid = try predeclare(b, hir.FuncKind.init, info, "init", &.{}, .{ .primitive = .void }, meta.Span.init(0, 0, 0), null);
        m.init_func = fid;
    }
    // Non-generic function members with bodies, declaration order.
    for (info.values) |*vm| {
        switch (vm.decl) {
            .func => |f| if (f.body != null and f.type_params.len == 0) {
                const sig = vm.type_.function;
                const qname = try b.qualified(info.specifier, vm.name.text);
                _ = try predeclare(b, hir.FuncKind.member, info, qname, sig.params, sig.ret.*, vm.name.span, f.body);
            },
            else => {},
        }
    }
    // Used instances declared by this module (annotation creation
    // order); host-binding generics have no body and are never lowered.
    for (b.ann.instances.items) |inst| {
        if (inst.module != info) continue;
        if (inst.mono == null) continue;
        const sig = inst.signature.function;
        const qname = try std.fmt.allocPrint(b.arena, "{s}.{s}.{d}", .{ info.specifier, inst.decl.name.text, inst.id });
        _ = try predeclare(b, hir.FuncKind.instance, info, qname, sig.params, sig.ret.*, inst.decl.name.span, inst.mono.?.body);
    }
    // Drop hooks: one per non-generic struct type member with a drop
    // declaration, in type-member order.
    for (info.types) |*tm| {
        switch (tm.decl) {
            .struct_ => |s| if (s.drop) |d| {
                if (tm.generic) continue;
                const type_id = moduleinfo.resolveTypeId(b.resolve, info, s.name.text) orelse
                    return b.fail(d.span, "drop hook type unresolved", .{});
                const qname = try std.fmt.allocPrint(b.arena, "{s}.{s}.drop", .{ info.specifier, s.name.text });
                const params = try b.arena.alloc(meta.Param, 1);
                params[0] = .{ .span = d.param.span, .name = d.param, .mode = .borrow, .type_ = .{ .named = .{ .id = type_id, .args = &.{} } } };
                _ = try predeclare(b, hir.FuncKind.drop_hook, info, qname, params, .{ .primitive = .void }, s.name.span, d.body);
            },
            else => {},
        }
    }
    const range = m.funcs;
    m.funcs.len = @intCast(b.built.funcs.items.len - range.start);
    const n_predeclared = m.funcs.len;

    // Module-constant initializer roots come first (cfg lowering lowers
    // the module init *before* the member functions — `lowerInit` runs
    // first in `lowerModule`), so any λ/wrapper a const initializer
    // contains numbers before the members'. They may reference the
    // function records predeclared above.
    const cs = m.consts;
    var j: usize = 0;
    while (j < cs.len) : (j += 1) try buildConstInit(b, @intCast(cs.start + j));
    // Bodies in cfg order: member funcs, then instances, then hooks.
    // Hoisted records append past n_predeclared as they are discovered;
    // the funcs list reallocates, so index `b.built.funcs.items` (never
    // a cached slice) at every access.
    var order: u32 = 0;
    var i: usize = 0;
    while (i < n_predeclared) : (i += 1) {
        const fid: hir.FuncId = @intCast(range.start + i);
        try buildFuncBody(b, fid);
        b.built.funcs.items[fid].order = order;
        order += 1;
    }
    for (b.pending_lambdas.items) |fid| {
        b.built.funcs.items[fid].order = order;
        order += 1;
    }
    for (b.pending_wrappers.items) |fid| {
        b.built.funcs.items[fid].order = order;
        order += 1;
    }
    // The module's function range covers every record it owns, including
    // the hoisted λ / wrapper records appended while building bodies.
    b.built.modules.items[mi].funcs.len = @intCast(b.built.funcs.items.len - b.built.modules.items[mi].funcs.start);
}

/// Append one function record skeleton (root filled by the body build);
/// returns its FuncId (its index in the funcs table).
pub fn predeclare(b: *Builder, kind: hir.FuncKind, info: *moduleinfo.ModuleInfo, name: []const u8, params: []meta.Param, ret: meta.Type, span: meta.Span, body: ?*const ast.Block) BuildError!hir.FuncId {
    const mi = try b.modIdx(info.specifier);
    const id: hir.FuncId = @intCast(b.built.funcs.items.len);
    const owned_params = try b.arena.dupe(meta.Param, params);
    try b.built.funcs.append(b.built.arena, .{
        .name = name,
        .kind = kind,
        .module = mi,
        .params = owned_params,
        .ret = ret,
        .root = undefined,
        .span_start = span.start,
        .span_end = span.end,
    });
    try b.bodies.append(b.arena, body);
    try b.func_ids.put(b.arena, name, id);
    return id;
}

/// Build one function body into a `lambda`-shaped region tree and store
/// its root on the record. Fresh environment (no capture; block aliases
/// of the caller do not leak into the body).
pub fn buildFuncBody(b: *Builder, fid: hir.FuncId) BuildError!void {
    const f = b.built.funcs.items[fid];
    const saved_fn = b.fn_name;
    const saved_cur = b.cur_func;
    const saved_env = b.env_depth;
    const saved_alias = b.alias_depth;
    defer {
        b.fn_name = saved_fn;
        b.cur_func = saved_cur;
        b.env_depth = saved_env;
        b.alias_depth = saved_alias;
    }
    b.fn_name = f.name;
    b.cur_func = fid;
    b.env_depth = @intCast(b.scopes.items.len);
    b.alias_depth = @intCast(b.module_aliases.items.len);
    try b.pushScope();
    defer b.popScope();

    // Bind parameters: one binder per param, in order.
    var binder_ids = std.ArrayList(hir.BinderId).empty;
    for (f.params) |p| {
        const bind = try b.built.program.addBinder(p.type_, switch (p.mode) {
            .plain => .value,
            .borrow => .borrow,
            .move => .move,
        });
        try binder_ids.append(b.arena, bind);
        try b.bindName(p.name.text, bind);
    }
    const body: hir.ExprId = if (b.bodies.items[fid]) |blk|
        try hir_build_block.buildBlock(b, b.graph.modules[f.module], blk)
    else
        try buildInitBody(b);
    const params_sig = try b.arena.dupe(meta.Param, f.params);
    const ty = try b.funcType(params_sig, f.ret);
    const rid = try b.built.program.addRegion(binder_ids.items, body, null);
    const regs = try b.built.program.addRegions(&.{rid});
    // The λ wrapper node carries the declaration's provenance when the
    // record has one (init records are predeclared spanless; host
    // modules have no source). The empty-span convention is the
    // FuncRecord one (span_start/end are raw offsets, 0/0 = none).
    const info = b.graph.modules[f.module];
    const decl_span: ?meta.Span = if (info.source != null and !(f.span_start == 0 and f.span_end == 0))
        meta.Span.init(info.source.?.id, f.span_start, f.span_end)
    else
        null;
    const node = try b.built.program.addExpr(.{ .op = try b.op(meta.Span.init(0, 0, 0), "lambda"), .ty = ty, .regions = regs, .origin = if (decl_span) |s| try b.origin(s) else hir.no_origin });
    b.built.funcs.items[fid].root = node;
}

/// The module init body: not encoded in S4 (const initialization and
/// store_member sequences are S5 decisions; PROGRESS "S4 设计决定").
/// The init record's body is a void literal; the const initializer trees
/// live on the const records.
fn buildInitBody(b: *Builder) BuildError!hir.ExprId {
    return hir_build_expr.voidLiteral(b, null);
}

/// One module-constant initializer tree, stashed on the record.
fn buildConstInit(b: *Builder, cid: hir.ConstId) BuildError!void {
    const rec = &b.built.consts.items[cid];
    if (rec.module_spec != null or rec.init != null) return;
    const info = b.graph.modules[rec.module];
    const vm = info.valueMember(rec.name) orelse return;
    const init = vm.decl.const_.init orelse return;
    const saved_fn = b.fn_name;
    const saved_env = b.env_depth;
    const saved_alias = b.alias_depth;
    defer {
        b.fn_name = saved_fn;
        b.env_depth = saved_env;
        b.alias_depth = saved_alias;
    }
    b.fn_name = "init";
    b.env_depth = @intCast(b.scopes.items.len);
    b.alias_depth = @intCast(b.module_aliases.items.len);
    try b.pushScope();
    rec.init = try hir_build_expr.buildExpr(b, info, init);
    b.popScope();
}

// ---------------------------------------------------------------------------
// Type environment (one meta.TypeDecl per TypeId — SerCtx shape)
// ---------------------------------------------------------------------------

fn collectTypeEnv(b: *Builder) BuildError![]meta.TypeDecl {
    const count = b.graph.type_interner.to_name.items.len;
    const decls = try b.arena.alloc(meta.TypeDecl, count);
    for (decls) |*d| d.* = .{ .unknown = "" };
    for (b.graph.modules) |info| {
        for (info.types) |*tm| {
            if (tm.decl == .alias) continue;
            const full = try b.qualified(info.specifier, tm.name.text);
            const id = b.resolve.type_ids.?.idOf(full) orelse continue;
            decls[id] = try lowerTypeDecl(b, info, tm, full);
        }
    }
    return decls;
}

fn lowerTypeDecl(b: *Builder, info: *moduleinfo.ModuleInfo, tm: *moduleinfo.TypeMember, qname: []const u8) BuildError!meta.TypeDecl {
    return switch (tm.decl) {
        .struct_ => |s| .{ .struct_ = .{
            .name = tm.name.text,
            .module = info.specifier,
            .type_params = try paramNames(b, s.type_params),
            .ownership = if (s.type_params.len > 0) null else moduleinfo.ownershipOf(b.resolve, info, .{ .named = .{ .id = b.resolve.type_ids.?.idOf(qname).?, .args = &.{} } }),
            .drop = if (s.drop) |_| try std.fmt.allocPrint(b.arena, "{s}.drop", .{qname}) else null,
            .fields = try lowerFields(b, info, s.fields),
        } },
        .union_ => |u| .{ .union_ = .{
            .name = tm.name.text,
            .module = info.specifier,
            .type_params = try paramNames(b, u.type_params),
            .ownership = if (u.type_params.len > 0) null else moduleinfo.ownershipOf(b.resolve, info, .{ .named = .{ .id = b.resolve.type_ids.?.idOf(qname).?, .args = &.{} } }),
            .variants = try lowerVariants(b, info, u.variants),
        } },
        .opaque_ => .{ .opaque_ = .{
            .name = tm.name.text,
            .module = info.specifier,
            .ownership = .unique,
            .host_id = .{ .host_module = info.specifier, .type_name = tm.name.text },
        } },
        .alias => unreachable,
    };
}

fn paramNames(b: *Builder, params: []const meta.Ident) BuildError![]const []const u8 {
    const out = try b.arena.alloc([]const u8, params.len);
    for (params, 0..) |p, i| out[i] = p.text;
    return out;
}

fn lowerFields(b: *Builder, info: *moduleinfo.ModuleInfo, fields: []const ast.FieldDecl) BuildError![]meta.FieldDecl {
    const out = try b.arena.alloc(meta.FieldDecl, fields.len);
    for (fields, 0..) |*f, i| {
        const ft = moduleinfo.resolveType(b.resolve, info, &f.type_) orelse
            return b.fail(f.span, "cannot resolve field type", .{});
        out[i] = .{ .name = f.name.text, .type_ = ft };
    }
    return out;
}

fn lowerVariants(b: *Builder, info: *moduleinfo.ModuleInfo, variants: []const ast.VariantDecl) BuildError![]meta.VariantDecl {
    const out = try b.arena.alloc(meta.VariantDecl, variants.len);
    for (variants, 0..) |*v, i| {
        var payloads = std.ArrayList(meta.Type).empty;
        if (v.types) |types| for (types) |*t| {
            const pt = moduleinfo.resolveType(b.resolve, info, t) orelse
                return b.fail(t.span(), "cannot resolve variant payload type", .{});
            try payloads.append(b.arena, pt);
        };
        out[i] = .{ .name = v.name.text, .payloads = try payloads.toOwnedSlice(b.arena) };
    }
    return out;
}
