//! Annotated AST → CFG IR lowering — frontend Phase 3 (frontend.md §5,
//! ir.md §12).
//!
//! Phase 3 consumes the phase-1 module graph (with its module-level
//! annotation) and produces the CFG-based IR of ir.md: per module an
//! `@init` function plus one `IrFunc` per Stilla function, all host
//! binding calls lowered to `syscall` instructions, ownership operations
//! explicit (`move`/`copy`/`drop`), and destruction materialized in the
//! CFG (frontend §5.4, ir.md §6.4).
//!
//! This module is the phase-3 driver: the `Lowerer` context plus the
//! per-pass logic in `src/passes/` (the `cfg_lower_*` passes, one file
//! per pass: program, module, func, expr, control, call, pattern, path,
//! emit, validate — see frontend.md §5.7). The passes import each other
//! directly and share the `Lowerer` context, the `Local`/`Scope`/
//! `FuncState` types, and the optimizer entry points below.
//!
//! The IR-native types of `cfg` are used directly. The lowerer consumes
//! the phase-2 `checker.Annotation` (`Lowerer.ann`) for concrete
//! signatures and instantiated generic types; expression and local types
//! are otherwise derived structurally from the AST and the module graph.
//!
//! Generic Stilla functions are monomorphized in phase 2 (a used
//! specialization is a `checker.FuncInstance` with a checked monomorphized
//! body) and each used specialization is lowered as its own monomorphic
//! `IrFunc` (`cfg_lower_func.lowerInstance` — the IR receives only
//! specialized, monomorphic programs, Core §12); host-binding generics
//! get a body-less instance and lower to `syscall`. Lambda values are
//! lowered to synthesized `IrFunc`s referenced by `fn_ref` (ir.md §5.5);
//! ownership for generic instantiations (`Option[File]`) resolves through
//! the declared type.

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const checker = @import("passes/checker.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg_lower_program = @import("passes/cfg_lower_program.zig");
const cfg_optimize = @import("passes/cfg_optimize.zig");
const cfg_tail_call = @import("passes/cfg_tail_call.zig");
const cfg_pre = @import("passes/cfg_pre.zig");
const cfg_dead_block = @import("passes/cfg_dead_block.zig");
const cfg_drop_elide = @import("passes/cfg_drop_elide.zig");
const cfg_jump_thread = @import("passes/cfg_jump_thread.zig");
const cfg_phi_simplify = @import("passes/cfg_phi_simplify.zig");

pub const LowerError = error{ OutOfMemory, Diagnostic };

/// pass-internal: the lowering passes of src/passes/ share `Local`,
/// `Scope`, `FuncState`, and the `Lowerer` context fields through this
/// module. (Zig 0.16 struct fields are always public.)
/// One local binding: a name mapped to an SSA value, with the
/// ownership bookkeeping needed to place scope-end drops (ir.md §6.4).
pub const Local = struct {
    name: []const u8,
    value: *cfg.Value,
    /// True when this local owns an unique value that must be dropped at
    /// scope end unless consumed (moved, dropped, returned, stored).
    owns_unique: bool,
    consumed: bool = false,
};

pub const Scope = struct {
    locals: std.ArrayListUnmanaged(*Local) = .empty,
};

/// Per-function lowering state: blocks under construction, the value
/// table, the symbol table, scope stack, and ownership bookkeeping.
pub const FuncState = struct {
    module: *moduleinfo.ModuleInfo,
    name: ast.Ident,
    params: []cfg.Param,
    ret: cfg.Type,
    /// The function's own module reference (`module_ref "<spec>"`),
    /// created lazily for member loads.
    self_module: ?*cfg.Value = null,
    values: std.ArrayListUnmanaged(*cfg.Value) = .empty,
    blocks: std.ArrayListUnmanaged(*cfg.BasicBlock) = .empty,
    block_instrs: std.ArrayListUnmanaged(std.ArrayListUnmanaged(*cfg.Instr)) = .empty,
    cur: ?*cfg.BasicBlock = null,
    symbols: std.StringHashMapUnmanaged(*Local) = .{},
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    /// Values that are bound to a local (for move-at-call decisions).
    local_values: std.AutoHashMapUnmanaged(*cfg.Value, void) = .empty,
    /// Unique-owned values consumed by an ownership operation (move,
    /// drop, take, move-call-arg, phi input, ret, construct arg).
    consumed: std.AutoHashMapUnmanaged(*cfg.Value, void) = .empty,
    /// Conditional-release tokens (Core §10.10, ir.md §6.4): value → its
    /// cleanup token (a `cleanup_owner` result in the dominating block of
    /// the construct that first made it a candidate). A consuming path
    /// disarms the token (`cleanup_disable`); the scope-end destruction is
    /// `drop_cleanup` of the token — conditional on the per-path armed
    /// bit, so the maybe-unique value itself is never referenced after the
    /// construct's join.
    cleanup_tokens: std.AutoHashMapUnmanaged(*cfg.Value, *cfg.Value) = .empty,
    /// The local bound to an unique value, for resetting `consumed` on the
    /// owning `Local` at a maybe-merge.
    value_locals: std.AutoHashMapUnmanaged(*cfg.Value, *Local) = .empty,
    /// Unique-owned values created by `emit`, in creation order: the
    /// scope-end / full-expression drop candidates.
    created: std.ArrayListUnmanaged(*cfg.Value) = .empty,
    /// Phi incoming builders, keyed by the phi instruction; materialized
    /// at `finishFunc` (loop back-edges are added after creation).
    phi_lists: std.AutoHashMapUnmanaged(*cfg.Instr, *std.ArrayListUnmanaged(cfg.PhiIn)) = .empty,
};

/// The phase-3 lowering driver.
pub const Lowerer = struct {
    arena: std.mem.Allocator,
    graph: *moduleinfo.ModuleGraph,
    resolve: moduleinfo.Resolve,
    /// The phase-2 annotation: per-module side tables (types, ownership,
    /// generic `FuncInstance`s) the lowering reads for concrete signatures
    /// and instantiated types (frontend §4.7, §5.7).
    ann: ?*checker.Annotation = null,
    /// Which module a module-typed SSA value refers to (`module_ref`
    /// values and module-valued member loads).
    module_of: std.AutoHashMapUnmanaged(*cfg.Value, *moduleinfo.ModuleInfo) = .empty,
    diag: ?moduleinfo.Diag = null,
    entry_fn: ?[]const u8,
    /// True when `entry_fn` was explicitly requested by the user (vs. the
    /// `main` default): a missing explicitly-named entry is a diagnostic.
    entry_fn_explicit: bool = false,
    next_func_id: u32 = 0,
    /// Lambda literals hoisted to synthesized `IrFunc`s during module
    /// lowering (ir.md §5.5); drained into the owning module's `funcs`
    /// list by `cfg_lower_module.lowerModule`. Cleared per module.
    lambda_funcs: std.ArrayListUnmanaged(*cfg.IrFunc) = .empty,
    /// Deterministic per-program lambda counter (lambda names must be
    /// unique across the whole program's IR text).
    next_lambda_id: u32 = 0,

    pub fn init(arena: std.mem.Allocator, graph: *moduleinfo.ModuleGraph, entry_fn: ?[]const u8, entry_fn_explicit: bool, ann: ?*checker.Annotation) Lowerer {
        return .{
            .arena = arena,
            .graph = graph,
            .resolve = moduleinfo.resolveOf(graph),
            .ann = ann,
            .diag = null,
            .entry_fn = entry_fn,
            .entry_fn_explicit = entry_fn_explicit,
        };
    }

    // No deinit: `module_of` is arena-owned.

    /// The checker's annotated type of an expression (frontend §4.3): the
    /// instantiated type of a construction, the resolved type of a use
    /// site. Null when the annotation is unavailable (or the expression
    /// was not annotated — e.g. inside an unspecialized generic template).
    pub fn annotatedType(self: *Lowerer, fs: *FuncState, e: *const ast.Expr) ?cfg.Type {
        const a = self.ann orelse return null;
        const ma = a.per_module.get(fs.module.specifier) orelse return null;
        return ma.expr_of.get(e);
    }

    /// pass-internal: type resolution helper shared with the passes.
    pub fn resolveType(self: *Lowerer, fs: *FuncState, t: *const ast.Type) LowerError!cfg.Type {
        return moduleinfo.resolveType(self.resolve, fs.module, t) orelse
            self.fail(t.span(), "cannot resolve type", .{});
    }

    /// pass-internal: diagnostic helper shared with the passes.
    pub fn fail(self: *Lowerer, span: ast.Span, comptime fmt: []const u8, args: anytype) LowerError {
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        self.diag = .{ .span = span, .message = msg };
        return error.Diagnostic;
    }
};

// -----------------------------------------------------------------
// Entry points (frontend.md §5.7, §8)
// -----------------------------------------------------------------

pub const lowerProgram = cfg_lower_program.lowerProgram;

pub const pre = cfg_pre.pre;
pub const deadBlock = cfg_dead_block.deadBlock;
pub const tailCall = cfg_tail_call.tailCall;
pub const dropElide = cfg_drop_elide.dropElide;
pub const jumpThread = cfg_jump_thread.jumpThread;
pub const phiSimplify = cfg_phi_simplify.phiSimplify;
pub const cse = cfg_optimize.cse;
pub const copyProp = cfg_optimize.copyProp;
pub const deadInstr = cfg_optimize.deadInstr;
pub const optimize = cfg_optimize.optimize;
/// The ir.md §13 IR validator (frontend.md Pass 6.1), re-exported for
/// the frontend and tests.
pub const validate = cfg_optimize.validate;
