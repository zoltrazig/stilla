//! Pass: phase-2 driver — module annotation and checks (frontend.md §4).
//! In: phase-1 `ModuleGraph` (`moduleinfo`).
//! Out: `checker.Annotation` — per-module side tables of resolved types,
//! expression types, binding states, and concrete call signatures — and,
//! on the first semantic error, a `moduleinfo.Diag`.
//!
//! Phase 2 is split into two passes over this driver's context:
//! `checker_annotate` (block-level name resolution, expression/pattern
//! inference, binding-state tracking — frontend §4.1, §4.3, §4.5) and
//! `checker_validate` (the consumer checks — §4.6: type mismatch, match
//! exhaustiveness, refutable patterns). This file is the data home: the
//! `Annotation` side tables, the `Checker` context, and the ordering
//! contract (annotate every module, then validate every module, in phase-1
//! topological order).

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");

const annotate = @import("checker_annotate.zig");
const validate = @import("checker_validate.zig");

pub const CheckError = error{ OutOfMemory, Diagnostic };

/// The static ownership state of one binding (frontend §4.5): `borrowed`
/// (a `borrow` parameter or a non-consuming `match`/`for` binding),
/// `consumed` (ownership transferred by `move`, or destroyed by `drop`),
/// `released` (definitely released on every path through a conditional
/// construct, Core §10.10), and `maybe` (released on some but not all
/// normal paths through a conditional construct — the binding is unusable
/// afterward, and the implementation tracks whether it still needs
/// destruction, Core §10.10).
pub const BindingState = enum { owned, borrowed, consumed, released, maybe };

/// One used specialization of a generic function (frontend §4.4, Core §12):
/// the concrete type arguments, the monomorphic signature, and — for
/// Stilla-defined generics — the monomorphized body clone, checked under
/// the concrete substitution. Host bindings have no body (`mono = null`):
/// there is nothing to expand (frontend §5.6). Instances are deduplicated
/// per (declaration, type arguments).
pub const FuncInstance = struct {
    decl: *const ast.FuncDef,
    type_args: []cfg.Type,
    signature: cfg.Type,
    mono: ?*const ast.FuncDef = null,
};

/// Phase-2 side tables for one module (frontend §4.7 `ModuleAnnotation`).
pub const ModuleAnnotation = struct {
    module: *moduleinfo.ModuleInfo,
    /// Written `ast.Type` → resolved `cfg.Type` (frontend §4.2).
    type_of: std.AutoHashMapUnmanaged(*const ast.Type, cfg.Type) = .empty,
    /// `ast.Expr` → produced `cfg.Type` (frontend §4.3).
    expr_of: std.AutoHashMapUnmanaged(*const ast.Expr, cfg.Type) = .empty,
    /// Binding id → resolved type.
    binding_of: std.AutoHashMapUnmanaged(u32, cfg.Type) = .empty,
    /// Binding id → static ownership state (frontend §4.5).
    bindings: std.AutoHashMapUnmanaged(u32, BindingState) = .empty,
    /// Call → the callee's concrete signature, when the callee resolves
    /// statically to a non-generic function. The validate pass checks
    /// argument count and types against it (§4.6 type mismatch).
    call_sig: std.AutoHashMapUnmanaged(*const ast.Call, cfg.Type) = .empty,
    /// Call → the generic specialization it triggers (frontend §4.4): the
    /// `FuncInstance` whose signature and (checked) monomorphized body the
    /// call uses. Present for calls to generic functions only.
    call_of: std.AutoHashMapUnmanaged(*const ast.Call, *FuncInstance) = .empty,
    /// Value-position `::[...]` specialization → its `FuncInstance`
    /// (frontend §4.4): `identity::[int32]` is a first-class monomorphic
    /// function value (Core §12.4).
    spec_of: std.AutoHashMapUnmanaged(*const ast.Specialize, *FuncInstance) = .empty,
    /// Module-member name → its declared identifier (name annotation).
    names: std.StringHashMapUnmanaged(*const ast.Ident) = .empty,
    next_binding_id: u32 = 0,
};

/// The result of phase 2: arena-owned side tables plus the set of host
/// bindings (frontend §4.7, §5.6).
pub const Annotation = struct {
    arena: std.heap.ArenaAllocator,
    /// Function members that are declarations without a Stilla definition
    /// (frontend §5.6): `builtin` members and host-provided module members.
    /// Calls to these lower to system calls, never to in-IR calls.
    host_bindings: std.AutoHashMapUnmanaged(*const ast.FuncDef, void) = .empty,
    /// The used specializations of generic functions, deduplicated per
    /// (declaration, type arguments) (frontend §4.4). Built after the
    /// per-module passes so every module's instances share one arena.
    instances: std.ArrayListUnmanaged(*FuncInstance) = .empty,
    /// One `ModuleAnnotation` per module, keyed by resolved specifier.
    per_module: std.StringHashMapUnmanaged(*ModuleAnnotation) = .empty,

    pub fn deinit(self: *Annotation) void {
        self.arena.deinit();
    }
};

/// One block-level binding with its inferred type and static ownership
/// state (frontend §4.5).
pub const Local = struct {
    name: []const u8,
    type_: cfg.Type,
    id: u32,
    state: BindingState = .owned,
    /// A non-owning view (frontend §4.5): a `borrow` parameter or an unique
    /// binding produced by a non-consuming `match`/`for` (Core §13.4,
    /// §13.5). Borrowed unique values cannot be moved, dropped, returned as
    /// owned, or stored into an owning location (Core §10.7, §18).
    is_borrow: bool = false,
    /// A `using` alias to a module member (Core §2.8). Module members have
    /// execution-context lifetime and do not constitute capture (Core
    /// §6.2), so aliases are exempt from the non-capture rule.
    is_using: bool = false,
};

/// A lexical scope; locals are looked up through the parent chain.
/// Function and lambda bodies carry `is_func = true` on the scope that
/// holds their parameters, marking the boundary the non-capture rule (Core
/// §6.2) does not cross.
pub const Scope = struct {
    locals: std.StringHashMapUnmanaged(*Local) = .empty,
    parent: ?*Scope = null,
    is_func: bool = false,
};

/// The shared context threaded through the annotate and validate passes
/// for one module.
pub const Frame = struct {
    ck: *Checker,
    info: *moduleinfo.ModuleInfo,
    ma: *ModuleAnnotation,
    resolve: moduleinfo.Resolve,
    scope: *Scope,
};

/// Whether a value of type `t` is owned (not Copy): unique types are
/// subject to move/drop/conditional-release tracking (Core §18).
pub fn isUnique(frame: *Frame, t: cfg.Type) bool {
    return if (t.ownership()) |ow|
        ow == .unique
    else
        moduleinfo.ownershipOf(frame.resolve, frame.info, t) == .unique;
}

/// Record a binding's static ownership state in both the `Local` and the
/// per-module `bindings` side table (frontend §4.5, §4.7), so the
/// annotation always reflects the current state (owned/borrowed/consumed/
/// released).
pub fn setState(frame: *Frame, local: *Local, state: BindingState) CheckError!void {
    local.state = state;
    try frame.ma.bindings.put(frame.ck.alloc(), local.id, state);
}

/// The phase-2 checker: annotate the program (§4.1–§4.5), then run the
/// consumer checks (§4.6). First error wins, matching the lexer/parser
/// convention.
pub const Checker = struct {
    allocator: std.mem.Allocator,
    graph: ?*moduleinfo.ModuleGraph = null,
    diag: ?moduleinfo.Diag = null,
    annotation: Annotation = undefined,

    pub fn init(allocator: std.mem.Allocator) Checker {
        return .{ .allocator = allocator };
    }

    /// The annotation arena; all phase-2 data (and the first diagnostic's
    /// message) lives here. The arena is a child of the compilation arena,
    /// so `Compilation.deinit` frees everything.
    pub fn alloc(self: *Checker) std.mem.Allocator {
        return self.annotation.arena.allocator();
    }

    /// Report the first semantic error and abort the build.
    pub fn fail(self: *Checker, span: ast.Span, comptime fmt: []const u8, args: anytype) CheckError {
        const message = std.fmt.allocPrint(self.alloc(), fmt, args) catch return error.OutOfMemory;
        self.diag = .{ .span = span, .message = message };
        return error.Diagnostic;
    }

    /// The phase-2 annotation tables for one module, created on demand.
    pub fn moduleAnnotation(self: *Checker, info: *moduleinfo.ModuleInfo) CheckError!*ModuleAnnotation {
        const gop = try self.annotation.per_module.getOrPut(self.alloc(), info.specifier);
        if (!gop.found_existing) {
            const ma = try self.alloc().create(ModuleAnnotation);
            ma.* = .{ .module = info };
            gop.value_ptr.* = ma;
        }
        return gop.value_ptr.*;
    }

    /// Resolve a written `ast.Type` to a `cfg.Type`, cached per node
    /// (frontend §4.2). Unresolvable types fall back to `any`, matching
    /// `funcSignature`'s convention; the lowerer reports resolution errors.
    pub fn resolveTypeOf(self: *Checker, ma: *ModuleAnnotation, info: *moduleinfo.ModuleInfo, t: *const ast.Type) CheckError!cfg.Type {
        if (ma.type_of.get(t)) |rt| return rt;
        const resolve = moduleinfo.Resolve{ .arena = self.alloc(), .by_specifier = &self.graph.?.by_specifier, .type_ids = &self.graph.?.type_interner };
        const rt = moduleinfo.resolveType(resolve, info, t) orelse cfg.Type{ .primitive = .any };
        try ma.type_of.put(self.alloc(), t, rt);
        return rt;
    }

    /// Run phase 2: annotate every module in topological order, then run
    /// the consumer checks. The first `Diagnostic` aborts the build; its
    /// message is retained in the annotation arena for the caller.
    pub fn check(self: *Checker, graph: *moduleinfo.ModuleGraph) CheckError!Annotation {
        self.graph = graph;
        self.annotation = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };

        // Host bindings: declarations without a Stilla definition (§5.6),
        // gathered before annotation so the set is complete even when a
        // later module fails.
        for (graph.modules) |info| {
            const program = info.program orelse continue;
            for (program.items) |*item| switch (item.*) {
                .func_def => |*f| if (f.body == null) try self.annotation.host_bindings.put(self.alloc(), f, {}),
                else => {},
            };
        }

        for (graph.modules) |info| try annotate.annotateModule(self, info);
        for (graph.modules) |info| try validate.validateModule(self, info);

        return self.annotation;
    }
};
