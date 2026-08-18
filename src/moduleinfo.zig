//! Module graph construction — frontend Phase 1 (phase1-module-graph.md).
//!
//! Phase 1 loads the transitive closure of modules reachable from the
//! entry point, checks and annotates their **module-level** information
//! (type/value members, import edges, module values, host bindings, using
//! aliases), rejects import cycles, and produces the dependency-ordered
//! `ModuleGraph` that phase 2 (checking) and phase 3 (lowering) consume.
//!
//! The algorithms are split out into `src/passes/` and used from here:
//!
//! - `src/passes/module_load.zig` — specifier resolution and module
//!   registration (phase1-module-graph.md; Runtime §2.1, §2.6);
//! - `src/passes/module_scan.zig` — module-value pre-scanning of consts
//!   (phase1-module-graph.md, Module-level information; Core §2.2–§2.3);
//! - `src/passes/topo_sort.zig` — the three-color DFS cycle detection and
//!   reverse-postorder topological sort (phase1-module-graph.md, Import-cycle detection);
//! - `src/passes/module_materialize.zig` — member-table materialization
//!   (phase1-module-graph.md, Module-level information);
//! - `src/passes/module_check.zig` — module-level checks (phase1-module-graph.md, Module-level checks);
//! - `src/passes/type_resolve.zig` — the type-resolution / module-scope
//!   inference helpers (phase2-checker.md, Type resolution — Generic expansion) that `materialize` uses for
//!   member types; the public API is re-exported below so callers keep
//!   using `moduleinfo.resolveType` and friends.
//!
//! Resolution (phase1-module-graph.md, Module identity and specifier resolution; Runtime §2.6) maps a written specifier to
//! exactly one of, in priority order:
//!
//! 1. a Stilla source module supplied by the embedding host's source map;
//! 2. the embedded `std/` bundle, then any host-supplied standard-library
//!    sources (the standard library cannot be shadowed by search dirs);
//! 3. a host-provided module (no source is loaded; its interface comes
//!    from the host interface registry — host-side policy, frontend.md §2,
//!    phase3-cfg-lowering.md, System calls for host bindings);
//! 4. the search directories in `Sources.search_dirs`, read as
//!    `<dir>/<specifier>.st`.
//!
//! The written specifier is canonicalized first (`normalizeSpecifier`): a
//! leading `./`, interior `./` segments, and a trailing `.st` are
//! stripped, so `import("m")`, `import("./m")`, and `import("m.st")` are
//! the same module — deduplicated by resolved specifier (Runtime §2.1).
//! Resolution is deduplicated by resolved specifier: the same module is
//! loaded at most once (Runtime §2.1), preserving module identity through
//! statically known aliases (`const b = a;` where `a` is a module-valued
//! const records the resolved module reference, Core §2.4 / Runtime §2.4).
//!
//! Module-level *checks* performed here (phase1-module-graph.md, Module-level checks): import
//! expressions appear only as module-level `const` initializers with a
//! string-literal argument (the parser already guarantees the literal);
//! module-valued const initializers are `import(...)` or a statically
//! known module binding; member names of the generated module struct are
//! unique; import cycles are rejected (phase1-module-graph.md, Import-cycle detection).
//!
//! All data is arena-owned and lives for the compilation. Diagnostics
//! follow the first-error-wins convention (span + message).

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const module_check = @import("passes/module_check.zig");
const module_load = @import("passes/module_load.zig");
const module_materialize = @import("passes/module_materialize.zig");
const topo_sort = @import("passes/topo_sort.zig");
const type_resolve = @import("passes/type_resolve.zig");
const type_shape = @import("passes/type_shape.zig");
const type_infer = @import("passes/type_infer.zig");

/// How a written specifier resolved (Runtime §2.6).
pub const ModuleKind = enum { source, standard_library, host };

/// One diagnostic: the offending source range and a message. The builder
/// records the first error; nothing after it is guaranteed meaningful.
pub const Diag = struct {
    span: ast.Span,
    message: []const u8,
};

// ---------------------------------------------------------------------------
// Members
// ---------------------------------------------------------------------------

/// A runtime value member of a module: a constant or a function (Core
/// §2.1 — the generated module struct's members are the module's runtime
/// value members). Monomorphic functions are first-class (Core §12.4), so
/// functions occupy member slots like consts.
pub const ValueMember = struct {
    name: ast.Ident,
    /// Member index: position in the module's value-member declaration
    /// order (Core §2.1 — consts and functions share one member space).
    /// Stable, so the runtime can dispatch on (module, member_index) and
    /// the `load_member` operand carries it (ir.md §7). Distinct from the
    /// storage slot of a constant member (`IrModule.slots`).
    slot: u32,
    /// Resolved type: the const's type, or the function's monomorphic
    /// signature.
    type_: cfg.Type,
    decl: ValueDecl,
    /// The resolved specifier when this member is a *module value* (Core
    /// §2.3): an `import("spec")` initializer or an alias of one.
    module_spec: ?[]const u8 = null,
    /// True when the member is a declaration without a Stilla definition:
    /// a function with no body, or a constant with no initializer
    /// (phase3-cfg-lowering.md, System calls for host bindings). Calls to `host` function members lower to system
    /// calls.
    host: bool = false,
};

pub const ValueDecl = union(enum) {
    const_: *const ast.ConstDef,
    func: *const ast.FuncDef,
};

/// A compile-time type member: a struct, a union, or a transparent alias
/// (Core §2.5, §12.1).
pub const TypeMember = struct {
    name: ast.Ident,
    decl: TypeDecl,
    /// True when the declaration takes type parameters (a template, Core
    /// §12.1). Templates are recorded so phase 2 can specialize them;
    /// the variant/field indices of a template are still positional.
    generic: bool,
};

pub const TypeDecl = union(enum) {
    struct_: *const ast.StructDef,
    union_: *const ast.UnionDef,
    alias: *const ast.TypeDef,
    /// A host-backed opaque nominal type (Core §11.8): no fields, no
    /// variants, no Stilla-visible representation; unique by declaration.
    /// Legal only in a standard-library or host-provided module interface.
    opaque_: *const ast.OpaqueDef,
};

/// The resolved target of a `using` alias (Core §2.8): a module value, a
/// type member, or a value member, always module-qualified.
pub const AliasTarget = union(enum) {
    module: []const u8,
    type: MemberRef,
    value: MemberRef,
};

pub const MemberRef = struct {
    /// The resolved specifier of the module that owns the member (the
    /// current module's own specifier for local members).
    module: []const u8,
    name: []const u8,
};

pub const UsingAlias = struct {
    name: []const u8,
    span: ast.Span,
    target: AliasTarget,
};

/// A host binding: a function member with a *declaration and no Stilla
/// definition* (phase3-cfg-lowering.md, System calls for host bindings). Every `builtin` member (Runtime §4) and
/// every member of a host-provided module (Core §2.6) is one. Phase 3
/// lowers calls to these as system calls, never as in-IR calls.
pub const HostBinding = struct {
    span: ast.Span,
    name: ast.Ident,
    /// Index of the binding in its module's member table; stable, so the
    /// runtime can dispatch syscalls by (module, member_index).
    member_index: u32,
    /// The declaration's resolved signature (`cfg.Type.function`).
    signature: cfg.Type,
};

// ---------------------------------------------------------------------------
// ModuleInfo and ModuleGraph
// ---------------------------------------------------------------------------

/// One loaded module with its phase-1 annotation (phase1-module-graph.md, Data structures).
pub const ModuleInfo = struct {
    /// Resolved specifier; the graph key (Runtime §2.1).
    specifier: []const u8,
    kind: ModuleKind,
    /// The parsed module, when source or standard library.
    source: ?*const ast.Source,
    program: ?*const ast.Program,

    /// Dependency edges in declaration order (Runtime §2.3).
    imports: []*ModuleInfo,
    /// Topological rank: dependencies have strictly lower rank.
    order: u32 = 0,

    /// Value members: functions first (declaration order), then consts
    /// (declaration order) — the generated module struct's member space
    /// (Core §2.1). `member_index` values in the IR follow this order
    /// (ir.md §7).
    values: []ValueMember,
    /// Type members (structs / unions / aliases).
    types: []TypeMember,
    /// Resolved `using` path aliases (Core §2.8) — compile-time bindings,
    /// not members.
    using_aliases: []UsingAlias,
    /// Function members that are declarations without definitions
    /// (phase3-cfg-lowering.md, System calls for host bindings) — the syscall surface of this module.
    host_bindings: []HostBinding,

    /// Name → resolved specifier for module-valued consts (imports and
    /// aliases of them, Core §2.3 / Runtime §2.4).
    module_values: std.StringHashMapUnmanaged([]const u8),
    value_index: std.StringHashMapUnmanaged(u32),
    type_index: std.StringHashMapUnmanaged(u32),
    alias_index: std.StringHashMapUnmanaged(u32),

    pub fn valueMember(self: *ModuleInfo, name: []const u8) ?*ValueMember {
        const i = self.value_index.get(name) orelse return null;
        return &self.values[i];
    }

    pub fn typeMember(self: *ModuleInfo, name: []const u8) ?*TypeMember {
        const i = self.type_index.get(name) orelse return null;
        return &self.types[i];
    }

    pub fn alias(self: *ModuleInfo, name: []const u8) ?*UsingAlias {
        const i = self.alias_index.get(name) orelse return null;
        return &self.using_aliases[i];
    }

    /// True when this module has a function member of the given name that
    /// is a declaration without a body (phase3-cfg-lowering.md, System calls for host bindings).
    pub fn isHostBinding(self: *const ModuleInfo, name: []const u8) bool {
        for (self.host_bindings) |hb| {
            if (std.mem.eql(u8, hb.name.text, name)) return true;
        }
        return false;
    }

    /// The value member holding a module value for the given specifier
    /// (`const calc = import("calc")`), used by the lowering to emit
    /// `module_ref` instead of a member load.
    pub fn moduleValueMember(self: *const ModuleInfo, specifier: []const u8) ?*const ValueMember {
        for (self.values) |*vm| {
            if (vm.module_spec) |spec| {
                if (std.mem.eql(u8, spec, specifier)) return vm;
            }
        }
        return null;
    }
};

/// The result of phase 1 (phase1-module-graph.md, Data structures): every module of the program, in
/// dependency order, with module-level info computed.
pub const TypeId = u32;

/// The canonical nominal-type interner for one compilation (ir.md §11).
/// Every concrete struct/union *and* every generic template decl named in
/// the graph gets a stable `TypeId`; `IrProgram.types` is populated to
/// match so `IrProgram.types[id]` is the `TypeDecl` behind a `Type.named`
/// carrying that id. `to_name` lets a `TypeId` resolve back to its
/// fully-qualified name for checker/diagnostic lookups.
pub const TypeInterner = struct {
    arena: std.mem.Allocator,
    name_to_id: std.StringHashMapUnmanaged(TypeId) = .{},
    to_name: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn intern(self: *TypeInterner, name: []const u8) TypeId {
        if (self.name_to_id.get(name)) |id| return id;
        const id: TypeId = @intCast(self.to_name.items.len);
        self.name_to_id.put(self.arena, name, id) catch return 0;
        self.to_name.append(self.arena, name) catch return 0;
        return id;
    }

    pub fn qname(self: *const TypeInterner, id: TypeId) []const u8 {
        return self.to_name.items[id];
    }

    pub fn idOf(self: *const TypeInterner, name: []const u8) ?TypeId {
        return self.name_to_id.get(name);
    }
};

pub const ModuleGraph = struct {
    arena: std.mem.Allocator,
    /// Topological order: dependencies before dependents (phase1-module-graph.md, Import-cycle detection).
    modules: []*ModuleInfo,
    by_specifier: std.StringHashMapUnmanaged(*ModuleInfo),
    entry: *ModuleInfo,
    /// The first phase-1 diagnostic, when the build failed.
    diag: ?Diag = null,
    /// Canonical nominal-type interner, shared by the checker and lowering.
    type_interner: TypeInterner = undefined,

    pub fn module(self: *const ModuleGraph, specifier: []const u8) ?*ModuleInfo {
        return self.by_specifier.get(specifier);
    }

    pub fn internType(self: *ModuleGraph, name: []const u8) TypeId {
        return self.type_interner.intern(name);
    }

    /// The fully-qualified name behind a `TypeId`, or null when out of range.
    pub fn typeName(self: *const ModuleGraph, id: TypeId) ?[]const u8 {
        if (id >= self.type_interner.to_name.items.len) return null;
        return self.type_interner.to_name.items[id];
    }
};

// ---------------------------------------------------------------------------
// Resolution policy
// ---------------------------------------------------------------------------

/// The frontend's resolution policy (phase1-module-graph.md, Module identity and specifier resolution; Runtime §2.6): maps a
/// written specifier to exactly one of a Stilla source module, a
/// standard-library module, or a host-provided module. The embedded
/// `std/` bundle is always available; `standard_library` extends it. All
/// maps are caller-owned.
pub const Sources = struct {
    /// Stilla source modules: written specifier → source text.
    source: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Host-supplied standard-library modules beyond the embedded bundle.
    standard_library: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Host-provided module specifiers (no source is loaded; the
    /// interface comes from the host interface registry).
    host: std.StringHashMapUnmanaged(void) = .{},
    /// Search directories, in order, consulted when no in-memory
    /// resolution matches: `<dir>/<specifier>.st` is read when present.
    /// The embedding's `Io` (passed separately to the builder) performs
    /// the reads.
    search_dirs: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

// pass-internal: the load/scan/materialize/check passes in `src/passes/`
// share these working structs through the builder's context fields.

/// One module-level const while the graph is under construction.
pub const RawConst = struct {
    def: *const ast.ConstDef,
    /// `import("spec")` initializer.
    import_spec: ?[]const u8 = null,
    /// Span of the `import(...)` expression, for import diagnostics.
    import_span: ast.Span = ast.Span.init(0, 0, 0),
    /// A single-segment path initializer naming another const
    /// (`const b = a;`), resolved transitively.
    alias_of: ?[]const u8 = null,
};

/// One import edge: the written specifier plus the span of the `import(...)`
/// expression that declared it. Phase-1 diagnostics (unresolved imports,
/// cycles) point at the importing module's expression, not at the module
/// start.
pub const ImportEdge = struct {
    spec: []const u8,
    span: ast.Span,
};

/// Working state for one module while the graph is under construction.
/// The materialized `ModuleInfo` is the public face; `RawModule` holds
/// the pieces that need a second pass once imports are known.
pub const RawModule = struct {
    info: *ModuleInfo,
    index: usize,
    import_specs: std.ArrayListUnmanaged(ImportEdge) = .empty,
    consts: std.ArrayListUnmanaged(RawConst) = .empty,
    /// Module-value resolution cache (name → resolved specifier).
    module_values: std.StringHashMapUnmanaged([]const u8) = .{},
};

/// Loads, parses, and annotates the transitive closure of modules
/// reachable from an entry point (phase1-module-graph.md, Recursive expansion).
pub const Builder = struct {
    // pass-internal: Builder fields are the shared context for the
    // load/scan/materialize/check passes in `src/passes/`. (Zig 0.16
    // struct fields are always public.)
    arena: std.mem.Allocator,
    sources: Sources,
    /// The embedding's Io, used only to read source modules from
    /// `sources.search_dirs`; null in embeddings that supply every module
    /// as in-memory text.
    io: ?std.Io = null,
    raws: std.ArrayListUnmanaged(*RawModule) = .empty,
    by_specifier: std.StringHashMapUnmanaged(*ModuleInfo) = .{},
    raw_of: std.StringHashMapUnmanaged(*RawModule) = .{},
    diag: ?Diag = null,
    next_source_id: u32 = 0,
    materialized: std.StringHashMapUnmanaged(void) = .{},
    /// Every `ast.Source` created, in creation order (the entry module is
    /// first). Kept even when a module fails to parse, so a phase-1
    /// diagnostic can still resolve a source location — the graph itself
    /// is null on parse failure, but the source list is not.
    loaded_sources: std.ArrayListUnmanaged(*const ast.Source) = .empty,
    /// Canonical nominal-type interner, threaded to the graph so type
    /// resolution during materialization and later phases agree on TypeIds.
    type_interner: TypeInterner = undefined,

    pub fn init(arena: std.mem.Allocator, sources: Sources) Builder {
        return .{ .arena = arena, .sources = sources, .type_interner = .{ .arena = arena } };
    }

    /// Run phase 1 from an entry specifier. On failure `diag` holds the
    /// first error.
    pub fn build(self: *Builder, entry: []const u8) !*ModuleGraph {
        const entry_span = ast.Span.init(0, 0, 0);
        const entry_raw = (try module_load.load(self, entry, entry_span)) orelse return error.Diagnostic;

        // Worklist expansion (phase1-module-graph.md, Recursive expansion): load every imported module,
        // transitively. Each module is loaded at most once (Runtime §2.1);
        // a queued set keeps cyclic import graphs from re-queueing the
        // same modules forever (the cycle is reported by topoSort below).
        var worklist = std.ArrayListUnmanaged(*RawModule).empty;
        var queued = std.StringHashMapUnmanaged(void).empty;
        try worklist.append(self.arena, entry_raw);
        try queued.put(self.arena, entry, {});
        while (worklist.items.len > 0) {
            const m = worklist.pop().?;
            for (m.import_specs.items) |edge| {
                if (queued.contains(edge.spec)) continue;
                const dep = try module_load.load(self, edge.spec, edge.span);
                if (dep) |d| {
                    try queued.put(self.arena, edge.spec, {});
                    try worklist.append(self.arena, d);
                }
            }
        }

        // Cycle detection + deterministic topological sort (phase1-module-graph.md, Import-cycle detection). The
        // order makes every cross-module lookup in materialization
        // resolvable: dependencies are materialized before dependents.
        const order = try self.topoSort();

        // Member-type resolution (phase1-module-graph.md, Module-level information), dependencies first.
        for (order.items) |raw| try module_materialize.materialize(self, raw);

        // Module-level checks.
        for (order.items) |raw| try module_check.checkModule(self, raw);

        const infos = try self.arena.alloc(*ModuleInfo, order.items.len);
        for (order.items, 0..) |raw, i| infos[i] = raw.info;
        const graph = try self.arena.create(ModuleGraph);
        graph.* = .{
            .arena = self.arena,
            .modules = infos,
            .by_specifier = .{},
            .entry = entry_raw.info,
            .diag = self.diag,
            .type_interner = self.type_interner,
        };
        for (order.items, 0..) |raw, i| {
            try graph.by_specifier.put(self.arena, raw.info.specifier, raw.info);
            raw.info.order = @intCast(i);
        }
        // Pre-populate the nominal-type interner (ir.md §11): every
        // struct/union decl, in graph (module, declaration) order, so a
        // `TypeId` assigned during type resolution later always has a
        // `TypeDecl` in `IrProgram.types`. Aliases expand and leave no
        // entry; generic templates are numbered like any other decl so a
        // raw template reference stays addressable.
        for (infos) |info| {
            for (info.types) |*tm| {
                if (tm.decl == .alias) continue;
                const qname = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ info.specifier, tm.name.text });
                _ = self.type_interner.intern(qname);
            }
        }
        graph.type_interner = self.type_interner;
        return graph;
    }

    // -----------------------------------------------------------------
    // Cycle detection and topological sort (phase1-module-graph.md, Import-cycle detection)
    // -----------------------------------------------------------------

    /// Three-color DFS over the import graph; the algorithm itself lives
    /// in `src/passes/topo_sort.zig` (phase1-module-graph.md, Import-cycle detection). Returns modules in
    /// reverse postorder (dependencies before dependents), deterministic:
    /// ties (sibling modules) are broken by resolved specifier. On a
    /// cycle, records a diagnostic and returns `error.Diagnostic`.
    fn topoSort(self: *Builder) !std.ArrayListUnmanaged(*RawModule) {
        const n = self.raws.items.len;

        // Per-module sorted child edges (imports ordered by specifier),
        // carrying the span of the importing module's `import(...)`
        // expression so a cycle diagnostic points at the offending import.
        var children = try self.arena.alloc([]topo_sort.Edge, n);
        const SortCtx = struct { raws: []*RawModule };
        for (self.raws.items) |m| {
            var list = std.ArrayListUnmanaged(topo_sort.Edge).empty;
            for (m.import_specs.items) |edge| {
                const dep = self.raw_of.get(edge.spec) orelse continue;
                try list.append(self.arena, .{ .dep = dep.index, .span = edge.span });
            }
            std.mem.sort(topo_sort.Edge, list.items, SortCtx{ .raws = self.raws.items }, struct {
                fn lessThan(ctx: SortCtx, a: topo_sort.Edge, b: topo_sort.Edge) bool {
                    return std.mem.lessThan(u8, ctx.raws[a.dep].info.specifier, ctx.raws[b.dep].info.specifier);
                }
            }.lessThan);
            children[m.index] = try list.toOwnedSlice(self.arena);
        }

        const entry = self.raws.items[0];
        const result = try topo_sort.reversePostorder(self.arena, n, entry.index, children);
        switch (result) {
            .order => |order| {
                var out = std.ArrayListUnmanaged(*RawModule).empty;
                for (order) |i| try out.append(self.arena, self.raws.items[i]);
                return out;
            },
            .cycle => |cyc| {
                // Name the full cycle in import order (phase1-module-graph.md, Import-cycle detection),
                // from the module the back edge points at back to itself.
                return self.cycleDiag(cyc.path, cyc.span);
            },
        }
    }

    /// Emit the import-cycle diagnostic. `path` is `[a, b, c, a]` — the
    /// cycle in import order with both ends the same module — rendered as
    /// "a imports b imports c imports a". The span points at the import
    /// that closed the cycle (the last element's importing expression).
    fn cycleDiag(self: *Builder, path: []usize, span: ast.Span) error{ Diagnostic, OutOfMemory } {
        var msg = std.ArrayListUnmanaged(u8).empty;
        try msg.appendSlice(self.arena, "import cycle detected: ");
        for (path, 0..) |node, k| {
            try msg.appendSlice(self.arena, self.raws.items[node].info.specifier);
            if (k + 1 < path.len) try msg.appendSlice(self.arena, " imports ");
        }
        self.diag = .{ .span = span, .message = try msg.toOwnedSlice(self.arena) };
        return error.Diagnostic;
    }

    // -----------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------

    /// pass-internal: diagnostic helper shared with the passes.
    pub fn failSpan(self: *Builder, span: ast.Span, comptime fmt: []const u8, args: anytype) error{ Diagnostic, OutOfMemory } {
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        self.diag = .{ .span = span, .message = msg };
        return error.Diagnostic;
    }
};

// ---------------------------------------------------------------------------
// Type resolution and module-scope inference — implemented in
// src/passes/type_resolve.zig (written-name and ast.Type resolution,
// phase2-checker.md, Type resolution), src/passes/type_shape.zig (shape queries and
// structural ownership, phase2-checker.md Type resolution), and src/passes/type_infer.zig
// (module-scope const inference and generic specialization, phase2-checker.md Expression inference — Generic expansion).
// Re-exported here so the phase-3 lowerer and the tests keep calling
// `moduleinfo.resolveType` and friends; the phase-1 builder itself calls
// the two shared helpers (`funcSignature`, `resolveAliasTarget`) through
// the `type_resolve` import above.
// ---------------------------------------------------------------------------

pub const Resolve = type_resolve.Resolve;
pub const resolveOf = type_resolve.resolveOf;
pub const resolveTypeName = type_resolve.resolveTypeName;
pub const resolveTypeId = type_resolve.resolveTypeId;
pub const resolveQualifiedTypeName = type_resolve.resolveQualifiedTypeName;
pub const structDecl = type_shape.structDecl;
pub const unionDecl = type_shape.unionDecl;
pub const opaqueDecl = type_shape.opaqueDecl;
pub const fieldIndex = type_shape.fieldIndex;
pub const variantIndex = type_shape.variantIndex;
pub const ownershipOf = type_shape.ownershipOf;
pub const resolveType = type_resolve.resolveType;
pub const inferExprType = type_infer.inferExprType;
pub const resolvePathMember = type_infer.resolvePathMember;
pub const PathTarget = type_infer.PathTarget;
pub const resolvePathTarget = type_infer.resolvePathTarget;
pub const specializeSignature = type_infer.specializeSignature;
pub const bindTypeArgs = type_infer.bindTypeArgs;
pub const substSignature = type_infer.substSignature;
pub const specializeSignatureExplicit = type_infer.specializeSignatureExplicit;

/// Canonical form of a written specifier: a leading `./`, interior
/// `./` segments, and a trailing `.st` are stripped, so the written
/// variants of one module dedup to a single registration (Runtime §2.1:
/// dedup by resolved specifier). The search dirs append `.st` themselves,
/// so `import("utils.st")` must not read `utils.st.st`.
pub fn normalizeSpecifier(arena: std.mem.Allocator, written: []const u8) ![]const u8 {
    var start: usize = 0;
    var end = written.len;
    if (end >= 3 and std.mem.eql(u8, written[end - 3 ..], ".st")) end -= 3;
    while (std.mem.startsWith(u8, written[start..end], "./")) start += 2;
    const stripped = try std.fmt.allocPrint(arena, "{s}", .{written[start..end]});
    return std.mem.replaceOwned(u8, arena, stripped, "/./", "/");
}
