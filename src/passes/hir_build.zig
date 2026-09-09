//! Pass: annotated AST → canonical HIR — hir.md §11 M1a, phase S4
//! (docs/hir.md; PROGRESS.md). In: module graph + `checker.Annotation`
//! (no re-inference: types, literal widths, and call/instance facts are
//! read from the checker's side tables; everything else is resolved
//! exactly like phase 3's `cfg_lower_*` resolves it). Out: a
//! `hir.BuiltProgram` — one shared node store plus the program-level
//! function/constant/host record tables and the per-module inventory.
//!
//! The HIR built here is the *source-canonical* form of hir.md §5.2:
//! blocks canonicalize to nested `let` regions and `seq`s (IR has only
//! Let / Seq / Expr shapes), `if`/`match` keep branch regions and arm
//! patterns, and the function inventory mirrors the CFG one
//! (`cfg_lower_module.lowerModule`: init?, non-generic members, used
//! instances, drop hooks, then hoisted lambdas in completion order,
//! then first-class intrinsic wrappers) so the §10.3 equivalence gate
//! (S5) has byte-comparable input. cfg-lowering *artifacts* — module_ref
//! values, `@init` store_member sequences, any-packing at let/return/
//! join edges, copy insertion, drop placement, cleanup tokens, SSA/phi —
//! are deliberately not encoded here (PROGRESS.md, "S4 设计决定"): the
//! HIR carries the structure, resolution, binder identity, types, and
//! ownership views S5 needs to re-derive them from the checker state
//! without the AST.
//!
//! Encoding contract highlights (full table: PROGRESS.md):
//! - Function bodies are `lambda`-shaped region trees: the record's
//!   `root` is a `lambda` node whose single region carries the params;
//!   every binder reference resolves through its own region (no capture
//!   is structural, S3).
//! - Non-capturing λ literals hoist like cfg lowering: the literal site
//!   becomes a `fn_ref` to a synthesized `.lambda` record named
//!   `{enclosing-name}.lambda{N}` (counter allocated before the body is
//!   walked, record finalized after — cfg's pre-order numbering /
//!   post-order drain). First-class intrinsic values synthesize
//!   `.intrinsic` records named `{using-spec}.{member}.intrinsic.{N}`,
//!   cached program-wide.
//! - `if` without `else` = an else region rooted at a void literal;
//!   `and`/`or` canonicalize to the `if` shape (short-circuit
//!   provenance survives); `match (move s)` consumption is recorded by
//!   arm-payload `BinderMode.move` (consuming) / `.borrow` (view).
//! - Destructuring lets put the irrefutable pattern on the let region
//!   (params = binding leaves; the §5.2/§10.1 amendment, PROGRESS).
//! - Paths resolve statically to `fn_ref` / `module_const` leaves
//!   mirroring `cfg_lower_path.lowerPathValue`. Struct/tuple/list
//!   projection reads encode as `field_get` nodes whose index the S5
//!   lowering dispatches on the base type.
//!
//! Errors: first-error-wins (`error.Diagnostic` + `Builder.diag`),
//! mirroring the cfg lowering convention.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const checker = @import("stilla").checker;
const type_resolve = @import("type_resolve.zig");

pub const BuildError = error{ OutOfMemory, Diagnostic };

/// Sentinel: no expr id (see struct-literal assembly).
const max_sentinel: hir.ExprId = std.math.maxInt(hir.ExprId);

/// Program-wide first-class intrinsic wrapper cache key: the declaring
/// module index, the member's source slot, and the concrete
/// specialization (the instance id, or maxInt(u32) for non-generic
/// members) — mirror `lower.IntrinsicKey`.
pub const WrapperKey = struct {
    owner: u32, // module index
    slot: u32,
    spec: u32, // maxInt(u32) = non-generic
};

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

    pub fn fail(self: *Builder, span: ast.Span, comptime fmt: []const u8, args: anytype) BuildError {
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        self.diag = .{ .span = span, .message = msg };
        return error.Diagnostic;
    }

    fn modIdx(self: *Builder, specifier: []const u8) BuildError!u32 {
        for (self.built.modules.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.specifier, specifier)) return @intCast(i);
        }
        return self.fail(ast.Span.init(0, 0, 0), "module '{s}' is not built", .{specifier});
    }

    /// Registry lookup with a source span for the diagnostic. New rows
    /// are data edits in hir.zig's `typed_descriptors`; a missing row is
    /// a loud builder error, never a silent fallback.
    fn op(self: *Builder, span: ast.Span, name: []const u8) BuildError!hir.OpId {
        return hir.opId(name) orelse
            self.fail(span, "HIR op '{s}' is not registered (add a typed_descriptors row)", .{name});
    }

    // -- environment --------------------------------------------------------

    fn pushScope(self: *Builder) !void {
        try self.scopes.append(self.arena, .{});
    }

    fn popScope(self: *Builder) void {
        _ = self.scopes.pop();
    }

    fn bindName(self: *Builder, text: []const u8, binder: hir.BinderId) !void {
        try self.scopes.items[self.scopes.items.len - 1].names.append(self.arena, .{ .text = text, .binder = binder });
    }

    /// Local binding lookup through the scope stack (innermost wins).
    /// Names never cross a function-like body boundary (`env_depth`):
    /// an inner function body cannot see the caller's locals.
    fn lookup(self: *Builder, text: []const u8) ?hir.BinderId {
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

    fn pushModuleAlias(self: *Builder, name: []const u8, specifier: []const u8) !void {
        try self.module_aliases.append(self.arena, .{ .name = name, .specifier = specifier });
    }

    /// Resolve a block-level module alias (innermost wins).
    fn aliasModule(self: *Builder, name: []const u8) ?[]const u8 {
        var i = self.module_aliases.items.len;
        while (i > self.alias_depth) {
            i -= 1;
            const a = self.module_aliases.items[i];
            if (std.mem.eql(u8, a.name, name)) return a.specifier;
        }
        return null;
    }

    // -- program-level helpers ----------------------------------------------

    fn qualified(self: *Builder, specifier: []const u8, name: []const u8) BuildError![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ specifier, name });
    }

    fn funcType(self: *Builder, params: []cfg.Param, ret: cfg.Type) BuildError!cfg.Type {
        const rp = try self.arena.create(cfg.Type);
        rp.* = ret;
        return .{ .function = .{ .params = params, .ret = rp } };
    }

    /// The checker's annotated type of an expression in module `info`.
    fn annotatedType(self: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr) ?cfg.Type {
        const ma = self.ann.per_module.get(info.specifier) orelse return null;
        return ma.expr_of.get(e);
    }

    fn resolveType(self: *Builder, info: *moduleinfo.ModuleInfo, t: *const ast.Type) BuildError!cfg.Type {
        return moduleinfo.resolveType(self.resolve, info, t) orelse
            self.fail(t.span(), "cannot resolve type", .{});
    }
};

fn isVoid(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .void;
}

fn isNever(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .never;
}

fn typeNameOf(b: *Builder, id: cfg.TypeId) ?[]const u8 {
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
/// consts (mirror `cfg_lower_module.constSlot`).
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
    // and host modules (cfg_lower_module.lowerModule's rule).
    if (info.kind != .host and !std.mem.eql(u8, info.specifier, "builtin")) {
        const fid = try predeclare(b, hir.FuncKind.init, info, "init", &.{}, .{ .primitive = .void }, ast.Span.init(0, 0, 0), null);
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
                const params = try b.arena.alloc(cfg.Param, 1);
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
fn predeclare(b: *Builder, kind: hir.FuncKind, info: *moduleinfo.ModuleInfo, name: []const u8, params: []cfg.Param, ret: cfg.Type, span: ast.Span, body: ?*const ast.Block) BuildError!hir.FuncId {
    const mi = try b.modIdx(info.specifier);
    const id: hir.FuncId = @intCast(b.built.funcs.items.len);
    const owned_params = try b.arena.dupe(cfg.Param, params);
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
fn buildFuncBody(b: *Builder, fid: hir.FuncId) BuildError!void {
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
        try buildBlock(b, b.graph.modules[f.module], blk)
    else
        try buildInitBody(b);
    const params_sig = try b.arena.dupe(cfg.Param, f.params);
    const ty = try b.funcType(params_sig, f.ret);
    const rid = try b.built.program.addRegion(binder_ids.items, body, null);
    const regs = try b.built.program.addRegions(&.{rid});
    const node = try b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "lambda"), .ty = ty, .regions = regs });
    b.built.funcs.items[fid].root = node;
}

/// The module init body: not encoded in S4 (const initialization and
/// store_member sequences are S5 decisions; PROGRESS "S4 设计决定").
/// The init record's body is a void literal; the const initializer trees
/// live on the const records.
fn buildInitBody(b: *Builder) BuildError!hir.ExprId {
    return voidLiteral(b, ast.Span.init(0, 0, 0));
}

fn voidLiteral(b: *Builder, span: ast.Span) BuildError!hir.ExprId {
    return b.built.program.addExpr(.{ .op = try b.op(span, "const"), .ty = .{ .primitive = .void }, .payload = .{ .const_value = .void } });
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
    rec.init = try buildExpr(b, info, init);
    b.popScope();
}

// ---------------------------------------------------------------------------
// Type environment (one cfg.TypeDecl per TypeId — SerCtx shape)
// ---------------------------------------------------------------------------

fn collectTypeEnv(b: *Builder) BuildError![]cfg.TypeDecl {
    const count = b.graph.type_interner.to_name.items.len;
    const decls = try b.arena.alloc(cfg.TypeDecl, count);
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

fn lowerTypeDecl(b: *Builder, info: *moduleinfo.ModuleInfo, tm: *moduleinfo.TypeMember, qname: []const u8) BuildError!cfg.TypeDecl {
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

fn paramNames(b: *Builder, params: []const ast.Ident) BuildError![]const []const u8 {
    const out = try b.arena.alloc([]const u8, params.len);
    for (params, 0..) |p, i| out[i] = p.text;
    return out;
}

fn lowerFields(b: *Builder, info: *moduleinfo.ModuleInfo, fields: []const ast.FieldDecl) BuildError![]cfg.FieldDecl {
    const out = try b.arena.alloc(cfg.FieldDecl, fields.len);
    for (fields, 0..) |*f, i| {
        const ft = moduleinfo.resolveType(b.resolve, info, &f.type_) orelse
            return b.fail(f.span, "cannot resolve field type", .{});
        out[i] = .{ .name = f.name.text, .type_ = ft };
    }
    return out;
}

fn lowerVariants(b: *Builder, info: *moduleinfo.ModuleInfo, variants: []const ast.VariantDecl) BuildError![]cfg.VariantDecl {
    const out = try b.arena.alloc(cfg.VariantDecl, variants.len);
    for (variants, 0..) |*v, i| {
        var payloads = std.ArrayList(cfg.Type).empty;
        if (v.types) |types| for (types) |*t| {
            const pt = moduleinfo.resolveType(b.resolve, info, t) orelse
                return b.fail(t.span(), "cannot resolve variant payload type", .{});
            try payloads.append(b.arena, pt);
        };
        out[i] = .{ .name = v.name.text, .payloads = try payloads.toOwnedSlice(b.arena) };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Blocks and statements → let/seq canonical trees (hir.md §5.2)
// ---------------------------------------------------------------------------

/// Canonicalize one block: statements fold onto nested `let` regions and
/// `seq`s; the block's value is its final expression, or void when there
/// is none.
pub fn buildBlock(b: *Builder, info: *moduleinfo.ModuleInfo, blk: *const ast.Block) BuildError!hir.ExprId {
    // The result expression must be addressed *inside the original
    // block*: checker side tables are keyed by AST node address, so a
    // by-value copy would lose every annotation (types, call_of,
    // spec_of) of the block's tail expression.
    const result: ?*const ast.Expr = if (blk.result) |*r| r else null;
    return buildStmts(b, info, blk.stmts, 0, result);
}

fn buildStmts(b: *Builder, info: *moduleinfo.ModuleInfo, stmts: []const ast.Stmt, i: usize, result: ?*const ast.Expr) BuildError!hir.ExprId {
    if (i >= stmts.len) {
        return if (result) |r| buildExpr(b, info, r) else voidLiteral(b, ast.Span.init(0, 0, 0));
    }
    const stmt = &stmts[i];
    switch (stmt.*) {
        .empty => return buildStmts(b, info, stmts, i + 1, result),
        .using => |*u| return buildUsing(b, info, u, stmts, i, result),
        .expr => |*es| {
            const e = try buildExpr(b, info, &es.expr);
            // A diverging statement (never) short-circuits the rest.
            if (isNever(b.built.program.node(e).ty)) return e;
            const rest = try buildStmts(b, info, stmts, i + 1, result);
            return seq2(b, es.span, e, rest);
        },
        .drop => |*ds| return buildDropStmt(b, info, ds, stmts, i, result),
        .let => |*ls| return buildLet(b, info, ls, stmts, i, result),
    }
}

/// `seq(e, rest)`: evaluate `e` (discarding its value), then `rest`;
/// the sequence's value is `rest`'s.
fn seq2(b: *Builder, span: ast.Span, e: hir.ExprId, rest: hir.ExprId) BuildError!hir.ExprId {
    const rest_ty = b.built.program.node(rest).ty;
    const ops = try b.built.program.addOperands(&.{ e, rest });
    return b.built.program.addExpr(.{ .op = try b.op(span, "seq"), .ty = rest_ty, .operands = ops });
}

/// Block-level `using` alias: a module-valued alias registers a compile-
/// time name (no runtime value); a value-member alias is bound once as a
/// let leaf (mirroring cfg `lowerUsing`'s bind-once) so the rest of the
/// block resolves through the single load. Type aliases bind nothing.
fn buildUsing(b: *Builder, info: *moduleinfo.ModuleInfo, u: *const ast.UsingDecl, stmts: []const ast.Stmt, i: usize, result: ?*const ast.Expr) BuildError!hir.ExprId {
    const alias = u.alias orelse return buildStmts(b, info, stmts, i + 1, result);
    // Resolve the alias target like the module graph's alias pass: the
    // written path's final segment names the member; resolve the path's
    // first segment as a module value / member.
    const target = try resolveAlias(b, info, u);
    switch (target) {
        .module => |spec| {
            try b.pushModuleAlias(alias.text, spec);
            const out = try buildStmts(b, info, stmts, i + 1, result);
            _ = b.module_aliases.pop();
            return out;
        },
        .value => |*mr| {
            // Bind once: a let leaf whose value is the member.
            const leaf = try memberLeaf(b, info, mr.module, mr.name, u.span, true);
            return letChain(b, info, u.span, &.{.{ .name = alias.text }}, leaf, stmts, i + 1, result);
        },
        .type => return buildStmts(b, info, stmts, i + 1, result),
    }
}

const AliasTarget = union(enum) {
    module: []const u8,
    value: moduleinfo.MemberRef,
    type: void,
};

/// Resolve a `using` decl's target (module-scope alias semantics): the
/// path's first segment names a module value, a member, or a using
/// alias; later segments chain module-valued members.
fn resolveAlias(b: *Builder, info: *moduleinfo.ModuleInfo, u: *const ast.UsingDecl) BuildError!AliasTarget {
    const path = u.path;
    // Single or dotted; the alias names the final segment by default.
    var spec: ?[]const u8 = info.specifier; // module context walk
    var mod = info;
    var k: usize = 0;
    // First segment: module value / alias / member.
    const first = path[0].text;
    if (info.module_values.get(first)) |s0| {
        mod = b.graph.module(s0) orelse return b.fail(u.span, "'{s}' does not name a loaded module", .{first});
        spec = s0;
        k = 1;
    } else if (b.aliasModule(first)) |s0| {
        mod = b.graph.module(s0) orelse return b.fail(u.span, "'{s}' does not name a loaded module", .{first});
        k = 1;
    } else if (info.valueMember(first)) |vm| {
        if (vm.module_spec) |s0| {
            mod = b.graph.module(s0) orelse return b.fail(u.span, "'{s}' does not name a loaded module", .{first});
            k = 1;
        }
        // else: a value member of the current module? A `using` target
        // of a plain local member is unusual; treat as value below.
    } else {
        return b.fail(u.span, "cannot resolve using alias '{s}'", .{u.path[u.path.len - 1].text});
    }
    if (k == path.len) {
        // Alias of a module: the name bound is a module value.
        return .{ .module = spec.? };
    }
    // Member chain: intermediate segments must be module-valued members.
    while (k < path.len - 1) : (k += 1) {
        const vm = mod.valueMember(path[k].text) orelse
            return b.fail(path[k].span, "module '{s}' has no member '{s}'", .{ mod.specifier, path[k].text });
        if (vm.module_spec) |s1| {
            mod = b.graph.module(s1) orelse return b.fail(path[k].span, "module '{s}' is not loaded", .{s1});
        } else {
            return b.fail(path[k].span, "'{s}' is not a module value", .{path[k].text});
        }
    }
    const tail = path[path.len - 1];
    if (mod.typeMember(tail.text) != null) return .{ .type = {} };
    if (mod.valueMember(tail.text) != null) {
        return .{ .value = .{ .module = mod.specifier, .name = tail.text } };
    }
    // A module-level using alias of this module chain.
    if (mod.alias(tail.text)) |a| {
        return switch (a.target) {
            .module => |s2| .{ .module = s2 },
            .value => |mr| .{ .value = mr },
            .type => .{ .type = {} },
        };
    }
    return b.fail(tail.span, "module '{s}' has no member '{s}'", .{ mod.specifier, tail.text });
}

/// Bind a fresh identifier binder for `name` over `init_value` and
/// build the continuation `rest` in the extended scope.
fn letChain(
    b: *Builder,
    info: *moduleinfo.ModuleInfo,
    span: ast.Span,
    names: []const LetName,
    init: hir.ExprId,
    stmts: []const ast.Stmt,
    i: usize,
    result: ?*const ast.Expr,
) BuildError!hir.ExprId {
    const init_ty = b.built.program.node(init).ty;
    var ids = std.ArrayList(hir.BinderId).empty;
    for (names) |n| {
        const ty = n.ty orelse init_ty;
        const mode: hir.BinderMode = if (n.moving) .move else .value;
        const bind = try b.built.program.addBinder(ty, mode);
        try ids.append(b.arena, bind);
    }
    try b.pushScope();
    for (names, ids.items) |n, bind| try b.bindName(n.name, bind);
    const rest = try buildStmts(b, info, stmts, i, result);
    b.popScope();
    return letNode(b, span, init, ids.items, rest);
}

const LetName = struct {
    name: []const u8,
    ty: ?cfg.Type = null,
    moving: bool = false,
};

/// One `let` node: init operand outside the region, region params bound
/// for the body (the source-canonical `let x = e in body`).
fn letNode(b: *Builder, span: ast.Span, init: hir.ExprId, binder_ids: []const hir.BinderId, body: hir.ExprId) BuildError!hir.ExprId {
    const ops = try b.built.program.addOperands(&.{init});
    const rid = try b.built.program.addRegion(binder_ids, body, null);
    const regs = try b.built.program.addRegions(&.{rid});
    const ty = b.built.program.node(body).ty;
    return b.built.program.addExpr(.{ .op = try b.op(span, "let"), .ty = ty, .operands = ops, .regions = regs });
}

/// A `let` statement. Irrefutable patterns only (the checker rejects
/// refutable ones). Identifier patterns bind one binder typed by the
/// declared type or the init's value type. Destructuring patterns put
/// the irrefutable pattern on the let region (params = binding leaves;
/// consuming `move` initializers give `.move`-mode leaves, non-consuming
/// views give `.borrow`-mode leaves) — the §5.2/§10.1 amendment.
fn buildLet(
    b: *Builder,
    info: *moduleinfo.ModuleInfo,
    ls: *const ast.LetStmt,
    stmts: []const ast.Stmt,
    i: usize,
    result: ?*const ast.Expr,
) BuildError!hir.ExprId {
    const moving = isMoveExpr(ls.init);
    const init = try buildExpr(b, info, ls.init);
    // `let _ = expr`: discard the value (drop at the FE, S5); the rest
    // of the block continues in the same scope.
    if (ls.pattern == .wildcard) {
        return seq2(b, ls.span, init, try buildStmts(b, info, stmts, i + 1, result));
    }
    const init_ty = b.built.program.node(init).ty;
    // Single identifier leaf: the common `let x = …` (region pattern
    // null, one param) — the §5.2 canonical form.
    if (identPatternLeaf(&ls.pattern)) |name| {
        const declared = if (ls.type_) |*dt| try b.resolveType(info, dt) else null;
        var names: [1]LetName = .{.{ .name = name, .ty = declared, .moving = moving }};
        return letChain(b, info, ls.span, &names, init, stmts, i + 1, result);
    }
    if (ls.type_ != null) return b.fail(ls.span, "a type annotation on a destructuring let is unsupported", .{});
    // Destructuring: pattern on the region, leaves as params. The leaf
    // types derive from the scrutinee type and the pattern shape.
    var binder_ids = std.ArrayList(hir.BinderId).empty;
    const pat_id = try buildPattern(b, info, &ls.pattern, init_ty, moving, &binder_ids);
    try b.pushScope();
    for (binder_ids.items) |bid| {
        const bind = b.built.program.binders.items[bid];
        // bindPattern left binder name in the Binder? no — re-find by
        // name order: patterns bind names positionally; we recorded
        // names in buildPattern's walk via env-free leaf list. Bind the
        // leaves in order to fresh names is impossible without them; so
        // destructure lets bind by *source name order* through a
        // parallel list.
        _ = bind;
    }
    // Names are bound in the same order the pattern's leaves were
    // created; buildPattern recorded them in `binder_ids` (arena order).
    // The source name of each leaf is recovered from the pattern AST
    // below — see bindPatternLeaves.
    try bindPatternLeaves(b, &ls.pattern, binder_ids.items);
    const body = try buildStmts(b, info, stmts, i + 1, result);
    b.popScope();
    // Region pattern: irrefutable destructure on the let region.
    const ops = try b.built.program.addOperands(&.{init});
    const rid = try b.built.program.addRegion(binder_ids.items, body, pat_id);
    const regs = try b.built.program.addRegions(&.{rid});
    const ty = b.built.program.node(body).ty;
    return b.built.program.addExpr(.{ .op = try b.op(ls.span, "let"), .ty = ty, .operands = ops, .regions = regs });
}

/// The identifier bound by a plain identifier pattern (`p` with no
/// tail), or null for every other shape.
fn identPatternLeaf(p: *const ast.Pattern) ?[]const u8 {
    switch (p.*) {
        .path => |pp| if (pp.path.len == 1 and pp.tail == .none) return pp.path[0].text,
        else => {},
    }
    return null;
}

fn isMoveExpr(e: *const ast.Expr) bool {
    var ex = e;
    while (ex.* == .paren) ex = ex.paren.inner;
    return ex.* == .move;
}

/// A `drop` statement: `drop x` of an owned local (mirror cfg
/// `lowerDrop`'s borrow rejection).
fn buildDropStmt(
    b: *Builder,
    info: *moduleinfo.ModuleInfo,
    ds: *const ast.DropStmt,
    stmts: []const ast.Stmt,
    i: usize,
    result: ?*const ast.Expr,
) BuildError!hir.ExprId {
    const bind = b.lookup(ds.name.text) orelse
        return b.fail(ds.span, "drop of unknown binding '{s}'", .{ds.name.text});
    const mode = b.built.program.binders.items[bind].mode;
    if (mode == .borrow) {
        return b.fail(ds.span, "cannot drop borrowed binding '{s}'", .{ds.name.text});
    }
    const local = try localNode(b, info, bind);
    const ops = try b.built.program.addOperands(&.{local});
    const drop = try b.built.program.addExpr(.{ .op = try b.op(ds.span, "drop"), .ty = .{ .primitive = .void }, .operands = ops });
    const rest = try buildStmts(b, info, stmts, i + 1, result);
    return seq2(b, ds.span, drop, rest);
}

/// A `local` read of a binder.
fn localNode(b: *Builder, info: *moduleinfo.ModuleInfo, bind: hir.BinderId) BuildError!hir.ExprId {
    const ty = b.built.program.binders.items[bind].ty;
    return b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "local"), .ty = ty, .payload = .{ .binder = bind }, .sema = try viewOf(b, info, ty, bind, .read) });
}

/// A binder's created-state view: params arrive owned (except borrow
/// params); reads off a `.borrow`-mode binder are borrowed.
fn viewOf(b: *Builder, info: *moduleinfo.ModuleInfo, ty: cfg.Type, bind: hir.BinderId, context: enum { read, value }) BuildError!hir.SemanticInfoId {
    const mode = b.built.program.binders.items[bind].mode;
    const borrowed = mode == .borrow or (context == .value and typeIsUnique(b, info, ty) and mode == .value and false);
    if (borrowed) {
        return b.built.program.addSemanticInfo(.{ .ownership_view = .borrowed });
    }
    return 0;
}

fn typeIsUnique(b: *Builder, info: *moduleinfo.ModuleInfo, t: cfg.Type) bool {
    if (t.ownership()) |ow| return ow == .unique;
    return switch (t) {
        .named => (moduleinfo.ownershipOf(b.resolve, info, t) orelse .unique) == .unique,
        else => true,
    };
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

pub fn buildExpr(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr) BuildError!hir.ExprId {
    return switch (e.*) {
        .int => |*lit| buildInt(b, lit),
        .float => |*lit| buildFloat(b, lit),
        .string => |lit| b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = .{ .primitive = .str }, .payload = .{ .const_value = .{ .string = lit.value } } }),
        .bool => |lit| b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = .{ .primitive = .bool }, .payload = .{ .const_value = .{ .bool = lit.value } } }),
        .void => |lit| voidLiteral(b, lit.span),
        .path => |*p| buildPath(b, info, e, p),
        .paren => |p| buildExpr(b, info, p.inner),
        .tuple => |*t| buildTuple(b, info, e, t),
        .list => |*l| buildList(b, info, e, l),
        .lambda => |*lam| buildLambda(b, info, lam),
        .if_ => |*i| buildIf(b, info, i),
        .match => |*m| buildMatch(b, info, e, m),
        .import => |imp| b.fail(imp.span, "import(...) is only valid as a module constant initializer", .{}),
        .block => |bx| buildBlock(b, info, bx.block),
        .unary => |*u| buildUnary(b, info, u),
        .binary => |*bin| buildBinary(b, info, bin),
        .move => |*m| buildMove(b, info, m),
        .cast => |*c| buildCast(b, info, c),
        .member => |*m| buildMember(b, info, e, m),
        .call => |*c| buildCall(b, info, e, c),
        .specialize => |*s| buildSpecialize(b, info, s),
    };
}

fn buildInt(b: *Builder, lit: *const ast.IntLiteral) BuildError!hir.ExprId {
    var ty: cfg.Type = .{ .primitive = .int32 };
    if (b.ann.int_widths.get(lit)) |k| ty = .{ .primitive = k };
    const bits: i64 = @bitCast(lit.value);
    return b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = ty, .payload = .{ .const_value = .{ .int = bits } } });
}

fn buildFloat(b: *Builder, lit: *const ast.FloatLiteral) BuildError!hir.ExprId {
    var ty: cfg.Type = .{ .primitive = .float32 };
    var v: f64 = lit.value;
    if (b.ann.float_widths.get(lit) != null) ty = .{ .primitive = .float64 };
    if (!(ty == .primitive and ty.primitive == .float64)) {
        const f: f32 = @floatCast(v);
        if (!std.math.isFinite(f)) {
            return b.fail(lit.span, "float literal out of range for float32", .{});
        }
        v = f;
    }
    return b.built.program.addExpr(.{ .op = try b.op(lit.span, "const"), .ty = ty, .payload = .{ .const_value = .{ .float = v } } });
}

fn buildTuple(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, t: *const ast.TupleExpr) BuildError!hir.ExprId {
    var ids = std.ArrayList(hir.ExprId).empty;
    var elems = std.ArrayList(cfg.Type).empty;
    for (t.elems) |*el| {
        const v = try buildExpr(b, info, el);
        try ids.append(b.arena, v);
        try elems.append(b.arena, b.built.program.node(v).ty);
    }
    const ops = try b.built.program.addOperands(ids.items);
    return b.built.program.addExpr(.{ .op = try b.op(t.span, "tuple_make"), .ty = b.annotatedType(info, e) orelse .{ .tuple = try elems.toOwnedSlice(b.arena) }, .operands = ops });
}

fn buildList(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, l: *const ast.ListExpr) BuildError!hir.ExprId {
    var ids = std.ArrayList(hir.ExprId).empty;
    var elem_type: cfg.Type = .{ .primitive = .int32 };
    for (l.elems) |*el| {
        const v = try buildExpr(b, info, el);
        if (ids.items.len == 0) elem_type = b.built.program.node(v).ty;
        try ids.append(b.arena, v);
    }
    const ops = try b.built.program.addOperands(ids.items);
    const inner = try b.arena.create(cfg.Type);
    inner.* = elem_type;
    return b.built.program.addExpr(.{ .op = try b.op(l.span, "list_make"), .ty = b.annotatedType(info, e) orelse .{ .list = inner }, .operands = ops });
}

/// Scalar-rep suffix for a primitive type (typed-op naming).
fn repSuffix(t: cfg.Type) ?[]const u8 {
    return switch (t) {
        .primitive => |k| switch (k) {
            .byte => "byte",
            .int32 => "i32",
            .uint32 => "u32",
            .int64 => "i64",
            .uint64 => "u64",
            .float32 => "f32",
            .float64 => "f64",
            .bool => "bool",
            .str => "str",
            else => null,
        },
        else => null,
    };
}

fn buildUnary(b: *Builder, info: *moduleinfo.ModuleInfo, u: *const ast.Unary) BuildError!hir.ExprId {
    const v = try buildExpr(b, info, u.operand);
    const vt = b.built.program.node(v).ty;
    const name = switch (u.op) {
        .neg => blk: {
            const rep = repSuffix(vt) orelse return b.fail(u.span, "cannot negate a '{s}' value", .{tyName(b, vt)});
            if (std.mem.eql(u8, rep, "bool") or std.mem.eql(u8, rep, "str")) {
                return b.fail(u.span, "cannot negate a '{s}' value", .{tyName(b, vt)});
            }
            break :blk try std.fmt.allocPrint(b.arena, "neg.{s}", .{rep});
        },
        .not => "not.bool",
    };
    const ops = try b.built.program.addOperands(&.{v});
    const ty: cfg.Type = if (u.op == .neg) vt else .{ .primitive = .bool };
    return b.built.program.addExpr(.{ .op = try b.op(u.span, name), .ty = ty, .operands = ops });
}

fn tyName(b: *Builder, t: cfg.Type) []const u8 {
    var buf = std.ArrayList(u8).empty;
    appendTyName(b, &buf, t) catch return "?";
    return buf.items;
}

fn appendTyName(b: *Builder, buf: *std.ArrayList(u8), t: cfg.Type) !void {
    switch (t) {
        .primitive => |k| try buf.appendSlice(b.arena, @tagName(k)),
        .named => |n| {
            if (typeNameOf(b, n.id)) |nm| try buf.appendSlice(b.arena, nm) else try buf.appendSlice(b.arena, "type");
            if (n.args.len > 0) {
                try buf.appendSlice(b.arena, "[");
                for (n.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(b.arena, ", ");
                    try appendTyName(b, buf, a);
                }
                try buf.appendSlice(b.arena, "]");
            }
        },
        .param => |p| try buf.appendSlice(b.arena, p),
        .module => try buf.appendSlice(b.arena, "module"),
        .cleanup => try buf.appendSlice(b.arena, "cleanup"),
        .list => |inner| {
            try buf.appendSlice(b.arena, "list[");
            try appendTyName(b, buf, inner.*);
            try buf.appendSlice(b.arena, "]");
        },
        .box => |inner| {
            try buf.appendSlice(b.arena, "box[");
            try appendTyName(b, buf, inner.*);
            try buf.appendSlice(b.arena, "]");
        },
        .tuple => |elems| {
            try buf.appendSlice(b.arena, "tuple[");
            for (elems, 0..) |el, i| {
                if (i > 0) try buf.appendSlice(b.arena, ", ");
                try appendTyName(b, buf, el);
            }
            try buf.appendSlice(b.arena, "]");
        },
        .function => try buf.appendSlice(b.arena, "fn"),
    }
}

fn buildBinary(b: *Builder, info: *moduleinfo.ModuleInfo, bin: *const ast.Binary) BuildError!hir.ExprId {
    if (bin.op == .and_) {
        const lhs = try buildExpr(b, info, bin.lhs);
        const rhs = try buildExpr(b, info, bin.rhs);
        const f = try b.built.program.addExpr(.{ .op = try b.op(bin.span, "const"), .ty = .{ .primitive = .bool }, .payload = .{ .const_value = .{ .bool = false } } });
        return controlNode(b, bin.span, "and", lhs, rhs, f);
    }
    if (bin.op == .or_) {
        const lhs = try buildExpr(b, info, bin.lhs);
        const rhs = try buildExpr(b, info, bin.rhs);
        const t = try b.built.program.addExpr(.{ .op = try b.op(bin.span, "const"), .ty = .{ .primitive = .bool }, .payload = .{ .const_value = .{ .bool = true } } });
        return controlNode(b, bin.span, "or", lhs, t, rhs);
    }
    const lhs = try buildExpr(b, info, bin.lhs);
    const rhs = try buildExpr(b, info, bin.rhs);
    const lt = b.built.program.node(lhs).ty;
    const rt = b.built.program.node(rhs).ty;
    const rep = repSuffix(lt) orelse return b.fail(bin.span, "binary op on non-scalar operand", .{});
    if (std.mem.eql(u8, rep, "bool") or std.mem.eql(u8, rep, "str")) {
        switch (bin.op) {
            .eq, .ne => {},
            .add => if (std.mem.eql(u8, rep, "str")) {} else return b.fail(bin.span, "unsupported operator for '{s}'", .{rep}),
            else => return b.fail(bin.span, "unsupported operator for '{s}'", .{rep}),
        }
    }
    const base: []const u8 = switch (bin.op) {
        .eq => "eq",
        .ne => "ne",
        .lt => "lt",
        .le => "le",
        .gt => "gt",
        .ge => "ge",
        .add => if (std.mem.eql(u8, rep, "str")) "concat" else "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .rem => "rem",
        .shl => "shl",
        .shr => "shr",
        .bitand => "band",
        .bitor => "bor",
        .bitxor => "bxor",
        .and_, .or_ => unreachable,
    };
    if ((std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr") or std.mem.eql(u8, base, "band") or std.mem.eql(u8, base, "bor") or std.mem.eql(u8, base, "bxor")) and (std.mem.eql(u8, rep, "f32") or std.mem.eql(u8, rep, "f64"))) {
        return b.fail(bin.span, "bitwise/shift ops are not defined for floats", .{});
    }
    const name = try std.fmt.allocPrint(b.arena, "{s}.{s}", .{ base, rep });
    const ops = try b.built.program.addOperands(&.{ lhs, rhs });
    const ty: cfg.Type = switch (bin.op) {
        .eq, .ne, .lt, .le, .gt, .ge => .{ .primitive = .bool },
        else => lt,
    };
    _ = rt;
    return b.built.program.addExpr(.{ .op = try b.op(bin.span, name), .ty = ty, .operands = ops });
}

/// `ifNode(cond, then, else)`: two regions rooted at the branch values.
fn ifNode(b: *Builder, span: ast.Span, cond: hir.ExprId, then: hir.ExprId, else_: hir.ExprId) BuildError!hir.ExprId {
    return controlNode(b, span, "if", cond, then, else_);
}

/// One control node with two regions (`if`, or the `and`/`or` short-circuit
/// rows — the §5.5/§7.1 amendment: and/or keep their own rows so the
/// HIR→CFG lowering can reproduce the reference short-circuit diamond).
fn controlNode(b: *Builder, span: ast.Span, op_name: []const u8, cond: hir.ExprId, then: hir.ExprId, else_: hir.ExprId) BuildError!hir.ExprId {
    const ops = try b.built.program.addOperands(&.{cond});
    const rt = try b.built.program.addRegion(&.{}, then, null);
    const re = try b.built.program.addRegion(&.{}, else_, null);
    const regs = try b.built.program.addRegions(&.{ rt, re });
    const tty = b.built.program.node(then).ty;
    const ety = b.built.program.node(else_).ty;
    return b.built.program.addExpr(.{ .op = try b.op(span, op_name), .ty = unifyJoin(tty, ety), .operands = ops, .regions = regs });
}

/// The join type of two branch values: never contributes nothing; equal
/// types join to themselves; a mixed pair joins as `any`.
fn unifyJoin(a: cfg.Type, b_: cfg.Type) cfg.Type {
    if (a == .primitive and a.primitive == .never) return b_;
    if (b_ == .primitive and b_.primitive == .never) return a;
    if (cfg.Type.eql(a, b_)) return a;
    return cfg.Type{ .primitive = .any };
}

fn buildMove(b: *Builder, info: *moduleinfo.ModuleInfo, m: *const ast.MoveExpr) BuildError!hir.ExprId {
    const bind = b.lookup(m.name.text) orelse
        return b.fail(m.span, "move of unknown binding '{s}'", .{m.name.text});
    const mode = b.built.program.binders.items[bind].mode;
    if (mode == .borrow) {
        return b.fail(m.span, "cannot move borrowed binding '{s}'", .{m.name.text});
    }
    const local = try localNode(b, info, bind);
    const ty = b.built.program.binders.items[bind].ty;
    // Always wrap: the lowering distinguishes unique (`move_`) from
    // Copy (`copy`) by the binder's type, and the syntactic `move`
    // matters even for Copy binders — `(move c) as T` on an `any`-typed
    // Copy unpacks with `any_unpack_move`, and a Copy-typed scrutinee
    // of `match (move c)` destructures atomically. Dropping the wrapper
    // here would lose that distinction (S5 amendment).
    const ops = try b.built.program.addOperands(&.{local});
    return b.built.program.addExpr(.{ .op = try b.op(m.span, "move"), .ty = ty, .operands = ops });
}

fn buildCast(b: *Builder, info: *moduleinfo.ModuleInfo, c: *const ast.Cast) BuildError!hir.ExprId {
    const v = try buildExpr(b, info, c.operand);
    const src = b.built.program.node(v).ty;
    const target = try b.resolveType(info, &c.target);
    const ops = try b.built.program.addOperands(&.{v});
    const op_name: []const u8 = if (src == .primitive and src.primitive == .any) "any_cast" else "num_cast";
    return b.built.program.addExpr(.{ .op = try b.op(c.span, op_name), .ty = target, .operands = ops });
}

fn buildMember(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, m: *const ast.Member) BuildError!hir.ExprId {
    if (resolveModuleChain(b, info, m.object)) |spec| {
        const mod = b.graph.module(spec) orelse return b.fail(m.span, "module '{s}' is not loaded", .{spec});
        return memberLeaf(b, info, mod.specifier, m.name.text, m.span, true);
    }
    const base = try buildExpr(b, info, m.object);
    const bt = b.built.program.node(base).ty;
    return fieldRead(b, info, e, m.span, base, bt, m.name.text);
}

/// Resolve an expression that is a module path to its specifier, or null.
fn resolveModuleChain(b: *Builder, info: *moduleinfo.ModuleInfo, ex: *const ast.Expr) ?[]const u8 {
    var exx = ex;
    while (exx.* == .paren) exx = exx.paren.inner;
    if (exx.* != .path) return null;
    const p = &exx.path;
    var mod: ?*moduleinfo.ModuleInfo = null;
    var k: usize = 0;
    if (info.module_values.get(p.path[0].text)) |s0| {
        mod = b.graph.module(s0);
        k = 1;
    } else if (b.aliasModule(p.path[0].text)) |s0| {
        mod = b.graph.module(s0);
        k = 1;
    } else if (info.valueMember(p.path[0].text)) |vm| {
        if (vm.module_spec) |s0| {
            mod = b.graph.module(s0);
            k = 1;
        }
    }
    if (mod == null) return null;
    while (k < p.path.len - 1) : (k += 1) {
        const vm = mod.?.valueMember(p.path[k].text) orelse return null;
        if (vm.module_spec) |s1| mod = b.graph.module(s1) else return null;
    }
    return mod.?.specifier;
}

/// One field/element read: index by declaration (struct) or position
/// (tuple); S5 dispatches on the base type.
fn fieldRead(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, span: ast.Span, base: hir.ExprId, bt: cfg.Type, name: []const u8) BuildError!hir.ExprId {
    const ops = try b.built.program.addOperands(&.{base});
    switch (bt) {
        .named => |td| {
            const type_name = typeNameOf(b, td.id) orelse
                return b.fail(span, "cannot resolve member '{s}'", .{name});
            const sd = moduleinfo.structDecl(b.resolve, info, type_name) orelse
                return b.fail(span, "'{s}' is not a struct type", .{type_name});
            const idx = moduleinfo.fieldIndex(sd, name) orelse
                return b.fail(span, "struct '{s}' has no field '{s}'", .{ type_name, name });
            const resolved = moduleinfo.resolveType(b.resolve, info, &sd.fields[idx].type_) orelse
                return b.fail(span, "cannot resolve field type", .{});
            const field_type = type_resolve.substParams(b.arena, sd.type_params, td.args, resolved);
            return b.built.program.addExpr(.{ .op = try b.op(span, "field_get"), .ty = b.annotatedType(info, e) orelse field_type, .operands = ops, .payload = .{ .field = @intCast(idx) } });
        },
        .tuple => |elems| {
            const idx = std.fmt.parseInt(usize, name, 10) catch
                return b.fail(span, "tuple elements are indexed numerically", .{});
            if (idx >= elems.len) return b.fail(span, "tuple element #{d} out of range", .{idx});
            return b.built.program.addExpr(.{ .op = try b.op(span, "field_get"), .ty = b.annotatedType(info, e) orelse elems[idx], .operands = ops, .payload = .{ .field = @intCast(idx) } });
        },
        else => return b.fail(span, "cannot access a member of this value", .{}),
    }
}

// ---------------------------------------------------------------------------
// Paths, member leaves, constructions
// ---------------------------------------------------------------------------

fn buildPath(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr) BuildError!hir.ExprId {
    switch (p.tail) {
        .construct => |*sc| return buildStructConstruct(b, info, e, p, sc),
        .variant => |*ve| return buildVariantConstruct(b, info, e, p, ve),
        .none => return buildPathValue(b, info, e, p),
    }
}

fn buildPathValue(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr) BuildError!hir.ExprId {
    const path = p.path;
    if (path.len == 1) {
        const n = path[0].text;
        if (b.lookup(n)) |bind| return localNode(b, info, bind);
        if (info.module_values.get(n) != null or b.aliasModule(n) != null) {
            return b.fail(path[0].span, "module value '{s}' has no runtime value", .{n});
        }
        if (info.valueMember(n) != null) {
            return memberLeaf(b, info, info.specifier, n, path[0].span, true);
        }
        if (info.alias(n)) |a| {
            return switch (a.target) {
                .value => |mr| memberLeaf(b, info, mr.module, mr.name, path[0].span, true),
                .module => b.fail(path[0].span, "module value '{s}' has no runtime value", .{n}),
                .type => b.fail(path[0].span, "'{s}' is a type, not a value", .{n}),
            };
        }
        return b.fail(path[0].span, "unknown name '{s}'", .{n});
    }
    if (b.lookup(path[0].text)) |bind| {
        const bind_ty = b.built.program.binders.items[bind].ty;
        var cur = try localNode(b, info, bind);
        var cur_ty = bind_ty;
        for (path[1..]) |seg| {
            cur = try fieldRead(b, info, e, seg.span, cur, cur_ty, seg.text);
            cur_ty = b.built.program.node(cur).ty;
        }
        return cur;
    }
    const spec = info.module_values.get(path[0].text) orelse b.aliasModule(path[0].text) orelse
        return b.fail(path[0].span, "'{s}' does not name a module", .{path[0].text});
    var mod = b.graph.module(spec) orelse
        return b.fail(path[0].span, "module '{s}' is not loaded", .{spec});
    var k: usize = 1;
    while (k < path.len - 1) : (k += 1) {
        const vm = mod.valueMember(path[k].text) orelse
            return b.fail(path[k].span, "module '{s}' has no member '{s}'", .{ mod.specifier, path[k].text });
        if (vm.module_spec) |mspec| {
            mod = b.graph.module(mspec) orelse
                return b.fail(path[k].span, "module '{s}' is not loaded", .{mspec});
        } else {
            return b.fail(path[k].span, "'{s}' is not a module value", .{path[k].text});
        }
    }
    const tail = path[path.len - 1];
    return memberLeaf(b, info, mod.specifier, tail.text, tail.span, true);
}

fn joinPath(b: *Builder, path: []const ast.Ident) BuildError![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (path, 0..) |id, i| {
        if (i > 0) try buf.append(b.arena, '.');
        try buf.appendSlice(b.arena, id.text);
    }
    return buf.toOwnedSlice(b.arena);
}

/// The value leaf of a module member: a function → `fn_ref` (member
/// record or host binding); a const → `module_const` (or materialized
/// intrinsic constant). Module-valued members have no runtime value.
/// `value_pos` distinguishes *value-position* uses (a bare intrinsic
/// function member synthesizes its first-class wrapper, mirroring
/// `cfg_lower_intrinsic.intrinsicFnRef`) from *call-position* leaves
/// (the call lowers to the inline expansion — syscall — at S5; the
/// leaf stays a host fn_ref).
fn memberLeaf(b: *Builder, info: *moduleinfo.ModuleInfo, specifier: []const u8, name: []const u8, span: ast.Span, value_pos: bool) BuildError!hir.ExprId {
    const owner = b.graph.module(specifier) orelse
        return b.fail(span, "module '{s}' is not loaded", .{specifier});
    const vm = owner.valueMember(name) orelse
        return b.fail(span, "module '{s}' has no member '{s}'", .{ specifier, name });
    switch (vm.decl) {
        .const_ => {
            if (owner.isIntrinsic(vm)) {
                const bits = cfgIntrinsicConstBits(specifier, name) orelse
                    return b.fail(span, "intrinsic '{s}.{s}' has no expansion", .{ specifier, name });
                const v: f32 = @bitCast(bits);
                return b.built.program.addExpr(.{ .op = try b.op(span, "const"), .ty = vm.type_, .payload = .{ .const_value = .{ .float = v } } });
            }
            const key = try b.qualified(specifier, name);
            const cid = b.const_ids.get(key) orelse
                return b.fail(span, "constant '{s}' has no record", .{key});
            return b.built.program.addExpr(.{ .op = try b.op(span, "module_const"), .ty = vm.type_, .payload = .{ .module_const = cid } });
        },
        .func => |f| {
            if (f.body != null and f.type_params.len == 0) {
                const key = try b.qualified(specifier, name);
                const fid = b.func_ids.get(key) orelse
                    return b.fail(span, "function '{s}' has no record", .{key});
                const rec = b.built.funcs.items[fid];
                return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = try b.funcType(rec.params, rec.ret), .payload = .{ .func = .{ .func = fid } } });
            }
            // Bodyless member: a host binding or a bundle intrinsic.
            // A *bare value use* of an intrinsic function member
            // synthesizes the first-class wrapper (the direct path's
            // `intrinsicFnRef`); call-position leaves keep the host
            // fn_ref (S5 lowers the call to the inline expansion).
            if (owner.isIntrinsic(vm) and value_pos) {
                return intrinsicWrapperFnRef(b, info, span, owner, vm, null);
            }
            const key = try b.qualified(specifier, name);
            const hid = b.host_ids.get(key) orelse
                return b.fail(span, "host binding '{s}' has no record", .{key});
            return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = vm.type_, .payload = .{ .func = .{ .host = hid } } });
        },
    }
}

/// Materializable intrinsic const bit patterns (mirror cfg's table).
fn cfgIntrinsicConstBits(module_spec: []const u8, member: []const u8) ?u32 {
    if (std.mem.eql(u8, module_spec, "math")) {
        if (std.mem.eql(u8, member, "pi")) return 0x40490FDB;
        if (std.mem.eql(u8, member, "e")) return 0x402DF854;
        if (std.mem.eql(u8, member, "tau")) return 0x40C90FDB;
        if (std.mem.eql(u8, member, "inf")) return 0x7F800000;
        if (std.mem.eql(u8, member, "nan")) return 0x7FC00000;
    }
    return null;
}

fn buildStructConstruct(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr, sc: *const ast.StructConstruct) BuildError!hir.ExprId {
    const name = try joinPath(b, p.path);
    const sd = moduleinfo.structDecl(b.resolve, info, name) orelse
        return b.fail(p.span, "unknown struct type '{s}'", .{name});
    // Evaluate field values in *written* order; the struct node carries
    // them in declaration order (member identity). When the written
    // order differs, the values are bound to temp binders first (a let
    // chain in written order) so the tree still evaluates left to right
    // in written order; the common decl-ordered case stays a plain node.
    var written = std.ArrayList(hir.ExprId).empty;
    var written_idx = std.ArrayList(u32).empty;
    for (sc.fields) |*f| {
        const idx = moduleinfo.fieldIndex(sd, f.name.text) orelse
            return b.fail(f.name.span, "struct '{s}' has no field '{s}'", .{ name, f.name.text });
        try written.append(b.arena, try buildExpr(b, info, f.value));
        try written_idx.append(b.arena, idx);
    }
    var permuted = false;
    for (written_idx.items, 0..) |idx, wpos| {
        if (idx != wpos) {
            permuted = true;
            break;
        }
    }
    const decl_reads = try b.arena.alloc(hir.ExprId, sd.fields.len);
    var value_ty: cfg.Type = undefined;
    if (b.annotatedType(info, e)) |at| {
        value_ty = at;
    } else {
        const tid = moduleinfo.resolveTypeId(b.resolve, info, name) orelse
            return b.fail(p.span, "unknown struct type '{s}'", .{name});
        value_ty = .{ .named = .{ .id = tid, .args = &.{} } };
    }
    var struct_node: hir.ExprId = undefined;
    if (!permuted) {
        for (written.items, written_idx.items) |v, idx| decl_reads[idx] = v;
        const ops = try b.built.program.addOperands(decl_reads);
        struct_node = try b.built.program.addExpr(.{ .op = try b.op(p.span, "struct_make"), .ty = value_ty, .operands = ops });
    } else {
        const temps = try b.arena.alloc(hir.BinderId, written.items.len);
        for (written.items, 0..) |v, w| {
            temps[w] = try b.built.program.addBinder(b.built.program.node(v).ty, .value);
        }
        for (written_idx.items, 0..) |idx, wpos| {
            const read = try localNode(b, info, temps[wpos]);
            decl_reads[idx] = read;
        }
        const ops = try b.built.program.addOperands(decl_reads);
        struct_node = try b.built.program.addExpr(.{ .op = try b.op(p.span, "struct_make"), .ty = value_ty, .operands = ops });
        // Wrap in temp-let regions, innermost bound last (written order
        // preserved: each temp's region contains the later-written ones).
        var wi: usize = written.items.len;
        while (wi > 0) {
            wi -= 1;
            struct_node = try letNode(b, p.span, written.items[wi], &.{temps[wi]}, struct_node);
        }
    }
    return struct_node;
}

fn buildVariantConstruct(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, p: *const ast.PathExpr, ve: *const ast.VariantExpr) BuildError!hir.ExprId {
    const name = try joinPath(b, p.path);
    const ud = moduleinfo.unionDecl(b.resolve, info, name) orelse
        return b.fail(p.span, "unknown union type '{s}'", .{name});
    const tag = moduleinfo.variantIndex(ud, ve.name.text) orelse
        return b.fail(ve.name.span, "union '{s}' has no variant '{s}'", .{ name, ve.name.text });
    var args = std.ArrayList(hir.ExprId).empty;
    if (ve.args) |exprs| for (exprs) |*arg| {
        try args.append(b.arena, try buildExpr(b, info, arg));
    };
    const ops = try b.built.program.addOperands(args.items);
    var result_ty: cfg.Type = undefined;
    if (b.annotatedType(info, e)) |at| {
        result_ty = at;
    } else {
        const tid = moduleinfo.resolveTypeId(b.resolve, info, name) orelse
            return b.fail(p.span, "unknown union type '{s}'", .{name});
        result_ty = .{ .named = .{ .id = tid, .args = &.{} } };
    }
    return b.built.program.addExpr(.{ .op = try b.op(p.span, "variant_make"), .ty = result_ty, .operands = ops, .payload = .{ .tag = tag } });
}

// ---------------------------------------------------------------------------
// λ hoisting, calls, specialization
// ---------------------------------------------------------------------------

fn buildLambda(b: *Builder, info: *moduleinfo.ModuleInfo, lam: *const ast.Lambda) BuildError!hir.ExprId {
    const name = try std.fmt.allocPrint(b.arena, "{s}.lambda{d}", .{ b.fn_name, b.next_lambda_id });
    b.next_lambda_id += 1;
    const params = try b.arena.alloc(cfg.Param, lam.params.len);
    for (lam.params, 0..) |*p, i| {
        params[i] = .{ .span = p.span, .name = p.name, .mode = p.mode, .type_ = try b.resolveType(info, &p.type_) };
    }
    const ret = try b.resolveType(info, &lam.ret);
    const fid = try predeclare(b, hir.FuncKind.lambda, info, name, params, ret, lam.span, lam.body);
    try buildFuncBody(b, fid);
    // Completion order: the record joins the module's pending list only
    // after its body is fully built (its own nested λs appended first).
    // Fallible — an OOM here must propagate, not be swallowed.
    try b.pending_lambdas.append(b.arena, fid);
    return b.built.program.addExpr(.{ .op = try b.op(lam.span, "fn_ref"), .ty = try b.funcType(params, ret), .payload = .{ .func = .{ .func = fid } } });
}
fn buildCall(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, c: *const ast.Call) BuildError!hir.ExprId {
    const ann_inst = if (b.ann.per_module.get(info.specifier)) |ma| ma.call_of.get(c) else null;
    var callee_ty: ?cfg.Type = null;
    var callee: hir.ExprId = undefined;
    if (ann_inst) |inst| {
        if (inst.mono != null) {
            const key = try std.fmt.allocPrint(b.arena, "{s}.{s}.{d}", .{ inst.module.specifier, inst.decl.name.text, inst.id });
            const fid = b.func_ids.get(key) orelse
                return b.fail(c.span, "instance '{s}' has no record", .{key});
            const rec = b.built.funcs.items[fid];
            callee_ty = try b.funcType(rec.params, rec.ret);
            callee = try b.built.program.addExpr(.{ .op = try b.op(c.span, "fn_ref"), .ty = callee_ty.?, .payload = .{ .func = .{ .func = fid } } });
        } else {
            const key = try b.qualified(inst.module.specifier, inst.decl.name.text);
            const hid = b.host_ids.get(key) orelse
                return b.fail(c.span, "host binding '{s}' has no record", .{key});
            callee_ty = inst.signature;
            callee = try b.built.program.addExpr(.{ .op = try b.op(c.span, "fn_ref"), .ty = callee_ty.?, .payload = .{ .func = .{ .host = hid } } });
        }
    } else {
        // The callee is built first (mirrors the reference lowerer's
        // traversal, so lambda/wrapper discovery order matches).
        var ex = c.callee;
        while (ex.* == .paren) ex = ex.paren.inner;
        if (ex.* == .specialize) {
            callee = try specializeCalleeLeaf(b, info, &ex.specialize, c.span);
        } else if (ex.* == .path) {
            callee = try resolvePathCallee(b, info, &ex.path, c.span, &callee_ty);
        } else {
            callee = try buildExpr(b, info, c.callee);
        }
    }
    var ids = std.ArrayList(hir.ExprId).empty;
    try ids.append(b.arena, callee);
    for (c.args) |*arg| {
        try ids.append(b.arena, try buildExpr(b, info, arg));
    }
    const ops = try b.built.program.addOperands(ids.items);
    var ty: cfg.Type = undefined;
    if (b.annotatedType(info, e)) |at| {
        ty = at;
    } else if (callee_ty) |ct| {
        ty = switch (ct) {
            .function => |f| f.ret.*,
            else => .{ .primitive = .any },
        };
    } else {
        ty = .{ .primitive = .void };
    }
    return b.built.program.addExpr(.{ .op = try b.op(c.span, "call"), .ty = ty, .operands = ops });
}

/// The callee leaf of a bare path in call position: a module-member
/// function (non-generic member / host / intrinsic → `memberLeaf`; a
/// bodyful generic must be instance-keyed by the annotation's
/// `call_of`), or a function-value callee (local / alias).
fn resolvePathCallee(b: *Builder, info: *moduleinfo.ModuleInfo, p: *const ast.PathExpr, span: ast.Span, callee_ty: *?cfg.Type) BuildError!hir.ExprId {
    const path = p.path;
    var owner = info;
    if (path.len == 1 and b.lookup(path[0].text) != null) {
        return localCallee(b, info, path[0]);
    }
    if (path.len > 1) {
        const spec = info.module_values.get(path[0].text) orelse b.aliasModule(path[0].text) orelse
            return b.fail(path[0].span, "'{s}' does not name a module", .{path[0].text});
        owner = b.graph.module(spec) orelse
            return b.fail(path[0].span, "module '{s}' is not loaded", .{spec});
        var k: usize = 1;
        while (k < path.len - 1) : (k += 1) {
            const vm = owner.valueMember(path[k].text) orelse
                return b.fail(path[k].span, "module '{s}' has no member '{s}'", .{ owner.specifier, path[k].text });
            if (vm.module_spec) |mspec| {
                owner = b.graph.module(mspec) orelse
                    return b.fail(path[k].span, "module '{s}' is not loaded", .{mspec});
            } else {
                return b.fail(path[k].span, "'{s}' is not a module value", .{path[k].text});
            }
        }
    } else if (info.valueMember(path[0].text) == null) {
        return localCallee(b, info, path[path.len - 1]);
    }
    const tail = path[path.len - 1];
    const vm = owner.valueMember(tail.text) orelse
        return b.fail(tail.span, "module '{s}' has no member '{s}'", .{ owner.specifier, tail.text });
    switch (vm.decl) {
        .func => |f| {
            if (f.body == null or f.type_params.len == 0) {
                const leaf = try memberLeaf(b, info, owner.specifier, tail.text, span, false);
                callee_ty.* = vm.type_;
                return leaf;
            }
            return b.fail(tail.span, "generic function '{s}.{s}' call is not annotated (missing call_of)", .{ owner.specifier, tail.text });
        },
        .const_ => return b.fail(tail.span, "cannot call a constant", .{}),
    }
}

/// A single-name callee that is not a module member: a local binding
/// (fn-typed value) or a module-level alias.
fn localCallee(b: *Builder, info: *moduleinfo.ModuleInfo, id: ast.Ident) BuildError!hir.ExprId {
    if (b.lookup(id.text)) |bind| return localNode(b, info, bind);
    if (info.alias(id.text)) |a| {
        switch (a.target) {
            .value => |mr| return memberLeaf(b, info, mr.module, mr.name, id.span, false),
            .module => {},
            .type => {},
        }
    }
    return b.fail(id.span, "unknown name '{s}'", .{id.text});
}

fn buildSpecialize(b: *Builder, info: *moduleinfo.ModuleInfo, s: *const ast.Specialize) BuildError!hir.ExprId {
    const ma = b.ann.per_module.get(info.specifier) orelse return b.fail(s.span, "no annotation", .{});
    const inst = ma.spec_of.get(s) orelse
        return b.fail(s.span, "an unspecialized generic cannot be used as a value (Core §12.4)", .{});
    if (inst.mono != null) {
        const key = try std.fmt.allocPrint(b.arena, "{s}.{s}.{d}", .{ inst.module.specifier, inst.decl.name.text, inst.id });
        const fid = b.func_ids.get(key) orelse
            return b.fail(s.span, "instance '{s}' has no record", .{key});
        const rec = b.built.funcs.items[fid];
        return b.built.program.addExpr(.{ .op = try b.op(s.span, "fn_ref"), .ty = try b.funcType(rec.params, rec.ret), .payload = .{ .func = .{ .func = fid } } });
    }
    const vm = inst.module.valueMember(inst.decl.name.text) orelse
        return b.fail(s.span, "member not found", .{});
    if (!inst.module.isIntrinsic(vm)) {
        return b.fail(s.span, "unsupported specialization of a host binding", .{});
    }
    return intrinsicWrapperFnRef(b, info, s.span, inst.module, vm, inst);
}

/// The callee leaf of a `::[…]`-specialized call whose callee is a
/// bodyless (host/intrinsic) member: a host fn_ref (the concrete
/// signature is derived at S5 from the arguments). Bodyful generic
/// specializations are keyed in `call_of` and handled earlier.
fn specializeCalleeLeaf(b: *Builder, info: *moduleinfo.ModuleInfo, s: *const ast.Specialize, span: ast.Span) BuildError!hir.ExprId {
    var operand = s.operand;
    while (operand.* == .paren) operand = operand.paren.inner;
    if (operand.* != .path) return b.fail(s.span, "cannot specialize a non-path callee", .{});
    const p = &operand.path;
    const spec = info.module_values.get(p.path[0].text) orelse
        b.aliasModule(p.path[0].text) orelse
        return b.fail(p.path[0].span, "'{s}' does not name a module", .{p.path[0].text});
    var mod = b.graph.module(spec) orelse
        return b.fail(p.path[0].span, "module '{s}' is not loaded", .{spec});
    var k: usize = 1;
    while (k < p.path.len - 1) : (k += 1) {
        const vm = mod.valueMember(p.path[k].text) orelse
            return b.fail(p.path[k].span, "module '{s}' has no member '{s}'", .{ mod.specifier, p.path[k].text });
        if (vm.module_spec) |mspec| mod = b.graph.module(mspec) orelse
            return b.fail(p.path[k].span, "module '{s}' is not loaded", .{mspec});
    }
    const tail = p.path[p.path.len - 1];
    const vm2 = mod.valueMember(tail.text) orelse
        return b.fail(tail.span, "module '{s}' has no member '{s}'", .{ mod.specifier, tail.text });
    switch (vm2.decl) {
        .func => |f| if (f.body != null) {
            return b.fail(s.span, "an unspecialized generic cannot be used as a value (Core §12.4)", .{});
        },
        .const_ => return b.fail(s.span, "cannot specialize a constant", .{}),
    }
    return memberLeaf(b, info, mod.specifier, tail.text, span, false);
}

fn intrinsicWrapperFnRef(b: *Builder, info: *moduleinfo.ModuleInfo, span: ast.Span, owner: *moduleinfo.ModuleInfo, vm: *const moduleinfo.ValueMember, spec: ?*checker.FuncInstance) BuildError!hir.ExprId {
    const sig = if (spec) |s| s.signature else vm.type_;
    const key = WrapperKey{
        .owner = try b.modIdx(owner.specifier),
        .slot = vm.slot,
        .spec = if (spec) |s| s.id else std.math.maxInt(u32),
    };
    if (b.wrapper_cache.get(key)) |fid| {
        const rec = b.built.funcs.items[fid];
        return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = try b.funcType(rec.params, rec.ret), .payload = .{ .func = .{ .func = fid } } });
    }
    const name = try std.fmt.allocPrint(b.arena, "{s}.{s}.intrinsic.{d}", .{ info.specifier, vm.name.text, b.next_intrinsic_id });
    b.next_intrinsic_id += 1;
    const ft = switch (sig) {
        .function => |f| f,
        else => return b.fail(span, "intrinsic '{s}.{s}' is not a function", .{ owner.specifier, vm.name.text }),
    };
    const params = try b.arena.alloc(cfg.Param, ft.params.len);
    for (ft.params, 0..) |*p, i| {
        params[i] = .{ .span = p.span, .name = .{ .span = p.span, .text = try std.fmt.allocPrint(b.arena, "p{d}", .{i}) }, .mode = p.mode, .type_ = p.type_ };
    }
    const fid = try predeclare(b, hir.FuncKind.intrinsic, info, name, params, ft.ret.*, span, null);
    try b.wrapper_cache.put(b.arena, key, fid);
    try b.pending_wrappers.append(b.arena, fid);
    // The wrapper's body forwards its parameters into the (module,
    // member) syscall target: `call(host-leaf, params…)`. The record's
    // body is a `lambda` region like every other function. The host
    // leaf is the intrinsic member's own host record — passed by id,
    // never recovered from the generated name.
    const hid = b.host_ids.get(try b.qualified(owner.specifier, vm.name.text)) orelse
        return b.fail(span, "intrinsic '{s}.{s}' has no host record", .{ owner.specifier, vm.name.text });
    b.built.funcs.items[fid].root = try synthIntrinsicRoot(b, fid, hid);
    return b.built.program.addExpr(.{ .op = try b.op(span, "fn_ref"), .ty = sig, .payload = .{ .func = .{ .func = fid } } });
}

/// The forwarding body of a first-class intrinsic wrapper: parameters
/// bound by mode, then a `call` of the intrinsic's (module, member)
/// syscall target with each parameter as an argument (mirror
/// `cfg_lower_intrinsic.synthIntrinsicFunc`; S5 emits the syscall).
fn synthIntrinsicRoot(b: *Builder, fid: hir.FuncId, hid: hir.HostBindingId) BuildError!hir.ExprId {
    const rec = b.built.funcs.items[fid];
    const info = b.graph.modules[rec.module];
    const host_rec = b.built.hosts.items[hid];
    var binder_ids = std.ArrayList(hir.BinderId).empty;
    var args = std.ArrayList(hir.ExprId).empty;
    try b.pushScope();
    for (rec.params) |prm| {
        const bind = try b.built.program.addBinder(prm.type_, switch (prm.mode) {
            .plain => .value,
            .borrow => .borrow,
            .move => .move,
        });
        try binder_ids.append(b.arena, bind);
        try b.bindName(prm.name.text, bind);
        if (isVoid(prm.type_)) continue;
        try args.append(b.arena, try localNode(b, info, bind));
    }
    const callee_leaf = try b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "fn_ref"), .ty = host_rec.signature, .payload = .{ .func = .{ .host = hid } } });
    var all = std.ArrayList(hir.ExprId).empty;
    try all.append(b.arena, callee_leaf);
    for (args.items) |a| try all.append(b.arena, a);
    const ops = try b.built.program.addOperands(all.items);
    const body = try b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "call"), .ty = rec.ret, .operands = ops });
    b.popScope();
    const rid = try b.built.program.addRegion(binder_ids.items, body, null);
    const regs = try b.built.program.addRegions(&.{rid});
    return b.built.program.addExpr(.{ .op = try b.op(ast.Span.init(0, 0, 0), "lambda"), .ty = try b.funcType(rec.params, rec.ret), .regions = regs });
}

fn buildIf(b: *Builder, info: *moduleinfo.ModuleInfo, i: *const ast.IfExpr) BuildError!hir.ExprId {
    const cond = try buildExpr(b, info, i.cond);
    const then = try buildBlock(b, info, i.then);
    const else_ = if (i.else_) |el| try buildExpr(b, info, el) else try voidLiteral(b, i.span);
    return ifNode(b, i.span, cond, then, else_);
}

// ---------------------------------------------------------------------------
// match and patterns
// ---------------------------------------------------------------------------

fn buildMatch(b: *Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, m: *const ast.MatchExpr) BuildError!hir.ExprId {
    const scrut = try buildExpr(b, info, m.scrutinee);
    const scrut_ty = b.built.program.node(scrut).ty;
    const moving = isMoveExpr(m.scrutinee);
    const ops = try b.built.program.addOperands(&.{scrut});
    var reg_ids = std.ArrayList(hir.RegionId).empty;
    var arm_tys = std.ArrayList(cfg.Type).empty;
    for (m.arms) |*arm| {
        var binder_ids = std.ArrayList(hir.BinderId).empty;
        const pat_id = try buildPattern(b, info, &arm.pattern, scrut_ty, moving, &binder_ids);
        try b.pushScope();
        try bindPatternLeaves(b, &arm.pattern, binder_ids.items);
        const body = try buildExpr(b, info, arm.body);
        b.popScope();
        try arm_tys.append(b.arena, b.built.program.node(body).ty);
        const rid = try b.built.program.addRegion(binder_ids.items, body, pat_id);
        try reg_ids.append(b.arena, rid);
    }
    const regs = try b.built.program.addRegions(reg_ids.items);
    var jt: cfg.Type = .{ .primitive = .void };
    for (arm_tys.items) |t2| jt = unifyJoin(jt, t2);
    return b.built.program.addExpr(.{ .op = try b.op(m.span, "match"), .ty = b.annotatedType(info, e) orelse jt, .operands = ops, .regions = regs });
}

/// Convert one AST pattern into a `hir.Pattern` arena tree, allocating
/// one binder per binding leaf (types derived from the scrutinee type
/// and the pattern shape) and appending leaves in source order.
fn buildPattern(
    b: *Builder,
    info: *moduleinfo.ModuleInfo,
    p: *const ast.Pattern,
    scrut_ty: cfg.Type,
    consuming: bool,
    leaves: *std.ArrayList(hir.BinderId),
) BuildError!hir.PatternId {
    switch (p.*) {
        .wildcard => return b.built.program.addPattern(.wildcard),
        .literal => |lp| {
            const value: cfg.ConstValue = switch (lp.value) {
                .int => |i| .{ .int = @intCast(i) },
                .neg_int => |i| .{ .int = -@as(i64, @intCast(i)) },
                .float => |f| .{ .float = try narrowFloat(b, lp.span, f) },
                .neg_float => |f| .{ .float = -(try narrowFloat(b, lp.span, f)) },
                .string => |st| .{ .string = st },
                .bool => |bv| .{ .bool = bv },
            };
            return b.built.program.addPattern(.{ .literal = value });
        },
        .type_test => |tt| {
            const test_ty = try b.resolveType(info, &tt.type_);
            if (tt.binding != null) {
                if (!consuming and typeIsUnique(b, info, test_ty)) {
                    return b.fail(tt.span, "cannot recover an unique payload from a borrowed 'any'; use match (move scrutinee)", .{});
                }
                const bid = try b.built.program.addBinder(test_ty, leafMode(b, info, test_ty, consuming));
                try leaves.append(b.arena, bid);
                return b.built.program.addPattern(.{ .type_test = .{ .ty = test_ty, .bind = bid } });
            }
            return b.built.program.addPattern(.{ .type_test = .{ .ty = test_ty, .bind = no_binder } });
        },
        .path => |pp| switch (pp.tail) {
            .none => {
                // Identifier pattern binds the whole scrutinee.
                const bid = try b.built.program.addBinder(scrut_ty, leafMode(b, info, scrut_ty, consuming));
                try leaves.append(b.arena, bid);
                try b.pat_names.put(b.arena, bid, pp.path[pp.path.len - 1].text);
                return b.built.program.addPattern(.{ .bind = bid });
            },
            .struct_ => |sp| {
                const name = try joinPath(b, pp.path);
                const sd = moduleinfo.structDecl(b.resolve, info, name) orelse
                    return b.fail(sp.span, "unknown struct type '{s}'", .{name});
                const args = switch (scrut_ty) {
                    .named => |n| n.args,
                    else => &.{},
                };
                var fields = std.ArrayList(hir.Pattern.FieldPattern).empty;
                for (sp.fields) |*fp| {
                    const idx = moduleinfo.fieldIndex(sd, fp.name.text) orelse
                        return b.fail(fp.name.span, "struct '{s}' has no field '{s}'", .{ name, fp.name.text });
                    const field_ty = type_resolve.substParams(b.arena, sd.type_params, args, moduleinfo.resolveType(b.resolve, info, &sd.fields[idx].type_) orelse
                        return b.fail(fp.name.span, "cannot resolve field type", .{}));
                    if (fp.pattern) |*sub| {
                        try fields.append(b.arena, .{ .field = @intCast(idx), .pat = try buildPattern(b, info, sub, field_ty, consuming, leaves) });
                    } else {
                        const bid = try b.built.program.addBinder(field_ty, leafMode(b, info, field_ty, consuming));
                        try leaves.append(b.arena, bid);
                        try b.pat_names.put(b.arena, bid, fp.name.text);
                        try fields.append(b.arena, .{ .field = @intCast(idx), .pat = try b.built.program.addPattern(.{ .bind = bid }) });
                    }
                }
                return b.built.program.addPattern(.{ .struct_ = .{ .fields = try fields.toOwnedSlice(b.arena) } });
            },
            .variant => |vp| {
                const ud = moduleinfo.unionDecl(b.resolve, info, try joinPath(b, pp.path)) orelse
                    return b.fail(vp.span, "unknown union type", .{});
                const tag = moduleinfo.variantIndex(ud, vp.name.text) orelse
                    return b.fail(vp.name.span, "union has no variant '{s}'", .{vp.name.text});
                const args = switch (scrut_ty) {
                    .named => |n| n.args,
                    else => return b.fail(vp.span, "variant pattern requires a named scrutinee", .{}),
                };
                const types = ud.variants[tag].types;
                if (vp.args) |argpats| {
                    var payload_ids = std.ArrayList(hir.PatternId).empty;
                    var idx2: usize = 0;
                    while (idx2 < argpats.len) : (idx2 += 1) {
                        const payload_ty = if (types != null and types.?.len == 1)
                            type_resolve.substParams(b.arena, ud.type_params, args, moduleinfo.resolveType(b.resolve, info, &types.?[0]) orelse
                                return b.fail(vp.span, "cannot resolve payload type", .{}))
                        else if (types) |ts| blk: {
                            const pt = moduleinfo.resolveType(b.resolve, info, &ts[idx2]) orelse
                                return b.fail(vp.span, "cannot resolve payload type", .{});
                            break :blk type_resolve.substParams(b.arena, ud.type_params, args, pt);
                        } else return b.fail(vp.span, "variant has no payload", .{});
                        try payload_ids.append(b.arena, try buildPattern(b, info, &argpats[idx2], payload_ty, consuming, leaves));
                    }
                    const payload: ?hir.PatternId = if (payload_ids.items.len == 1)
                        payload_ids.items[0]
                    else if (payload_ids.items.len > 1)
                        try b.built.program.addPattern(.{ .tuple = try payload_ids.toOwnedSlice(b.arena) })
                    else
                        null;
                    return b.built.program.addPattern(.{ .variant = .{ .tag = tag, .payload = payload } });
                }
                return b.built.program.addPattern(.{ .variant = .{ .tag = tag, .payload = null } });
            },
        },
        .tuple => |tp| {
            const elems = switch (scrut_ty) {
                .tuple => |es| es,
                else => return b.fail(tp.span, "tuple pattern requires a tuple value", .{}),
            };
            if (tp.elems.len > elems.len) return b.fail(tp.span, "tuple pattern has too many elements", .{});
            var kids = std.ArrayList(hir.PatternId).empty;
            for (tp.elems, 0..) |*el, k| {
                try kids.append(b.arena, try buildPattern(b, info, el, elems[k], consuming, leaves));
            }
            return b.built.program.addPattern(.{ .tuple = try kids.toOwnedSlice(b.arena) });
        },
        .list => |lp| {
            const elem_ty = switch (scrut_ty) {
                .list => |inner| inner.*,
                else => return b.fail(lp.span, "list pattern requires a list value", .{}),
            };
            var elems = std.ArrayList(hir.PatternId).empty;
            for (lp.items) |*it| {
                try elems.append(b.arena, try buildPattern(b, info, it, elem_ty, consuming, leaves));
            }
            var rest: ?hir.PatternId = null;
            if (lp.rest) |rest_name| {
                const tail_ty = try b.arena.create(cfg.Type);
                tail_ty.* = .{ .list = try b.arena.create(cfg.Type) };
                tail_ty.list.* = elem_ty;
                const bid = try b.built.program.addBinder(tail_ty.*, leafMode(b, info, tail_ty.*, consuming));
                try leaves.append(b.arena, bid);
                try b.pat_names.put(b.arena, bid, rest_name.text);
                rest = try b.built.program.addPattern(.{ .bind = bid });
            }
            return b.built.program.addPattern(.{ .list = .{ .elems = try elems.toOwnedSlice(b.arena), .rest = rest } });
        },
    }
}

/// The binder mode of one pattern leaf: Copy leaves bind as ordinary
/// values; unique leaves of a consuming destructure are `.move`, of a
/// non-consuming one `.borrow` (view).
fn leafMode(b: *Builder, info: *moduleinfo.ModuleInfo, ty: cfg.Type, consuming: bool) hir.BinderMode {
    if (!typeIsUnique(b, info, ty)) return .value;
    return if (consuming) .move else .borrow;
}

fn narrowFloat(b: *Builder, span: ast.Span, v: f64) BuildError!f64 {
    const f: f32 = @floatCast(v);
    if (!std.math.isFinite(f)) {
        return b.fail(span, "float literal out of range for float32", .{});
    }
    return f;
}

/// Bind the names of an AST pattern's leaves (source order) to the
/// binder ids created by `buildPattern`.
fn bindPatternLeaves(b: *Builder, p: *const ast.Pattern, leaves: []const hir.BinderId) BuildError!void {
    var names = std.ArrayList([]const u8).empty;
    try collectLeafNames(b, p, &names);
    if (names.items.len != leaves.len) return b.fail(p.span(), "internal: pattern leaf mismatch", .{});
    for (names.items, leaves) |nm, bid| {
        if (b.pat_names.get(bid)) |n2| {
            try b.bindName(n2, bid);
        } else {
            try b.bindName(nm, bid);
        }
    }
}

/// The source binding names of a pattern's leaves, left to right.
fn collectLeafNames(b: *Builder, p: *const ast.Pattern, out: *std.ArrayList([]const u8)) BuildError!void {
    switch (p.*) {
        .wildcard, .literal => {},
        .type_test => |tt| if (tt.binding) |bg| try out.append(b.arena, bg.text),
        .path => |pp| switch (pp.tail) {
            .none => try out.append(b.arena, pp.path[pp.path.len - 1].text),
            .struct_ => |sp| for (sp.fields) |*fp| {
                if (fp.pattern) |*sub| try collectLeafNames(b, sub, out) else try out.append(b.arena, fp.name.text);
            },
            .variant => |vp| if (vp.args) |args| for (args) |*a| try collectLeafNames(b, a, out),
        },
        .tuple => |tp| for (tp.elems) |*el| try collectLeafNames(b, el, out),
        .list => |lp| {
            for (lp.items) |*it| try collectLeafNames(b, it, out);
            if (lp.rest) |r| try out.append(b.arena, r.text);
        },
    }
}

/// Sentinel for a binding-less type-test pattern (matches an `any` by
/// tag without binding a name).
const no_binder: hir.BinderId = std.math.maxInt(hir.BinderId);
