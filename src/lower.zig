//! Annotated AST → AIR lowering — frontend Phase 3 (phase3-cfg-lowering.md,
//! air.md §12).
//!
//! Phase 3 consumes the phase-1 module graph (with its module-level
//! annotation) and produces the CFG-based AIR of air.md: per module an
//! `@init` function plus one `IrFunc` per Stilla function, all host
//! binding calls lowered to `syscall` instructions, ownership operations
//! explicit (`move`/`copy`/`drop`), and destruction materialized in the
//! CFG (phase3-cfg-lowering.md, Destruction placement; air.md §6.4).
//!
//! This module is the phase-3 driver: the `Lowerer` context plus the
//! per-pass logic in `src/passes/` (the `cfg_lower_*` passes, one file
//! per pass: program, module, func, expr, control, call, pattern, path,
//! emit, validate — see frontend.md §4). The passes import each other
//! directly and share the `Lowerer` context, the `Local`/`Scope`/
//! `FuncState` types, and the optimizer entry points below.
//!
//! The AIR-native types of `cfg` are used directly. The lowerer consumes
//! the phase-2 `checker.Annotation` (`Lowerer.ann`) for concrete
//! signatures and instantiated generic types; expression and local types
//! are otherwise derived structurally from the AST and the module graph.
//!
//! Generic Stilla functions are monomorphized in phase 2 (a used
//! specialization is a `checker.FuncInstance` with a checked monomorphized
//! body) and each used specialization is lowered as its own monomorphic
//! `IrFunc` (`cfg_lower_func.lowerInstance` — the AIR receives only
//! specialized, monomorphic programs, Core §12); host-binding generics
//! get a body-less instance and lower to `syscall`. Lambda values are
//! lowered to synthesized `IrFunc`s referenced by `fn_ref` (air.md §5.5);
//! ownership for generic instantiations (`Option[File]`) resolves through
//! the declared type.

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const checker = @import("passes/checker.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg_lower_program = @import("passes/cfg_lower_program.zig");
const cfg_lower_drop = @import("passes/cfg_lower_drop.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_alloc = @import("passes/llir_alloc.zig");
const llir_noop = @import("passes/llir_compact_noop_ownership.zig");
const llir_fusion = @import("passes/llir_fusion.zig");
const llir_validate = @import("passes/llir_validate.zig");
const llir_asm = @import("passes/llir_asm.zig");
const llir_emit_bin = @import("passes/llir_emit_bin.zig");
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
/// ownership bookkeeping needed to place scope-end drops (air.md §6.4).
pub const Local = struct {
    name: []const u8,
    value: *cfg.Value,
    /// True when this local owns an unique value that must be dropped at
    /// scope end unless consumed (moved, dropped, returned, stored).
    owns_unique: bool,
    consumed: bool = false,
};

pub const Scope = struct {
    locals: std.ArrayList(*Local) = .empty,
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
    values: std.ArrayList(*cfg.Value) = .empty,
    blocks: std.ArrayList(*cfg.BasicBlock) = .empty,
    block_instrs: std.ArrayList(std.ArrayList(*cfg.Instr)) = .empty,
    cur: ?*cfg.BasicBlock = null,
    symbols: std.StringHashMapUnmanaged(*Local) = .{},
    scopes: std.ArrayList(Scope) = .empty,
    /// Values that are bound to a local (for move-at-call decisions).
    local_values: std.AutoHashMapUnmanaged(*cfg.Value, void) = .empty,
    /// Unique-owned values consumed by an ownership operation (move,
    /// drop, take, move-call-arg, phi input, ret, construct arg).
    consumed: std.AutoHashMapUnmanaged(*cfg.Value, void) = .empty,
    /// v1 (Instruction Set §4): cleanup tokens are gone. Conditional ownership
    /// resolves at each construct's join — the non-consuming branch
    /// edges receive unconditional `.drop_` effects (`joinMaybeFlags`),
    /// so no per-path armed state exists anywhere downstream. The map
    /// stays (empty) only so stale text-AIR fixtures keep parsing.
    /// The local bound to an unique value, for resetting `consumed` on the
    /// owning `Local` at a maybe-merge.
    value_locals: std.AutoHashMapUnmanaged(*cfg.Value, *Local) = .empty,
    /// Unique-owned values created by `emit`, in creation order: the
    /// scope-end / full-expression drop candidates.
    created: std.ArrayList(*cfg.Value) = .empty,
    /// Phi incoming builders, keyed by the phi instruction; materialized
    /// at `finishFunc` (loop back-edges are added after creation).
    phi_lists: std.AutoHashMapUnmanaged(*cfg.Instr, *std.ArrayList(cfg.PhiIn)) = .empty,
};

/// Cache key of a first-class intrinsic wrapper (intrinsic plan,
/// phase 3): the declaring module, the member's index in its member
/// table, and the concrete specialization — the instance id for generic
/// intrinsics, `maxInt(u32)` for non-generic members.
pub const IntrinsicKey = struct {
    owner: usize,
    slot: u32,
    spec: u32,
};

/// The phase-3 lowering driver.
pub const Lowerer = struct {
    arena: std.mem.Allocator,
    graph: *moduleinfo.ModuleGraph,
    resolve: moduleinfo.Resolve,
    /// The phase-2 annotation: per-module side tables (types, ownership,
    /// generic `FuncInstance`s) the lowering reads for concrete signatures
    /// and instantiated types (phase2-checker.md, Data structures; frontend.md §2).
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
    /// lowering (air.md §5.5); drained into the owning module's `funcs`
    /// list by `cfg_lower_module.lowerModule`. Cleared per module.
    lambda_funcs: std.ArrayList(*cfg.IrFunc) = .empty,
    /// Deterministic per-program lambda counter (lambda names must be
    /// unique across the whole program's AIR text).
    next_lambda_id: u32 = 0,
    /// First-class intrinsic wrappers (intrinsic plan, phase 3), keyed by
    /// (declaring module, member index, specialization): the cache is
    /// program-wide, so two modules using the same intrinsic value share
    /// one synthesized function. `intrinsic_funcs` holds only the
    /// wrappers synthesized while lowering the *current* module;
    /// `cfg_lower_module.lowerModule` drains them into that module's
    /// `funcs` list like lambdas. Cleared per module — the cache is not.
    intrinsic_wrappers: std.AutoHashMapUnmanaged(IntrinsicKey, *cfg.IrFunc) = .empty,
    intrinsic_funcs: std.ArrayList(*cfg.IrFunc) = .empty,
    /// Deterministic per-program wrapper counter (wrapper names must be
    /// unique across the whole program's AIR text).
    next_intrinsic_id: u32 = 0,

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

    /// The checker's annotated type of an expression (phase2-checker.md, Expression inference): the
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
// Entry points (frontend.md §2, optimizer.md)
// -----------------------------------------------------------------

pub const lowerProgram = cfg_lower_program.lowerProgram;
/// The CFG → LLIR lowering driver (`Builder.lowerLlir`): twelve named
/// stages run in this fixed order; each has one named input/output
/// contract (full table: frontend.md, "Backend: CFG → LLIR").
///
/// 1. prepare (`cfg_lower_llir_prepare.run`) — dense `FunctionId`/`BlockId`s,
///    the ordered function/block tables, and zeroed `FunctionDesc` rows.
/// 2. allocate (`llir_alloc.allocateSlots`) — the type-constrained
///    linear-scan value→F-cell mapping and the per-function frame
///    layout numbers (`value_slot_count`/`scratch_slot_count`/
///    `cleanup_count`/`window_count`/`slot_types_len`); parameters
///    keep the ABI cells.
/// 3. result coalesce (`llir_result_coalesce.run`) — Step 8: eligible
///    non-void direct-call results remapped onto the result alias
///    `F(L+3+O-A)` so the emitter drops the post-call `take`.
/// 4. lifecycle plan (`cfg_lower_lifecycle.plan`) — per-instruction
///    trailing release placement, the per-edge kill plan (`edgeKills`),
///    and tailcall leftover kills for counted values: each owner
///    releases exactly once along every path.
/// 5. budget (`cfg_lower_llir_budget.run`) — per-block record sizing: CFG record counts,
///    argument-move counts, conservative decision-free block
///    starts/lengths, and pre-sized block-local record lists that
///    emission fills exactly.
/// 6. intern (`cfg_lower_llir_intern.run`) — strings/constants/types/
///    type-decls/modules/signatures/host-bindings to dense side tables
///    with integer instruction references; nested dependencies are
///    interned before a flat `{ start, len }` range is recorded.
/// 7. body emit (`cfg_lower_llir_emit.run`) — one record per
///    non-phi instruction at its block-local index: the ID-operand
///    records (`const`, `fn_ref`, `module_ref`, `type_is`,
///    `load_member`, `store_member`) and the real `slot_types` rows;
///    the type-specialized arithmetic/comparison/cast records
///    (`emitArith`/`emitCompare` fix trap, NaN, truncation, and sign
///    semantics by opcode, so an interpreter dispatch never reads a
///    result type); select; calls — direct calls resolve by name so
///    the input program stays read-only, the `slot_*` preparation
///    records place each argument at its absolute outgoing-window
///    offset (the window's `A = max(P, R)` cells overlap callee
///    parameters with the result, published into the caller register
///    `F(L+3+O-A)` and taken right after the call by
///    `take dst, F(L+3+O-A)`; indirect calls are
///    `jalr ra, base, 0`; self-tailcalls are a pure jump preceded by
///    explicit argument copies), and syscalls carry their host
///    binding, specialized signature, and shared argument registers
///    in `SyscallDesc`; ownership ops (`.copy`/`.borrow`/`.move_`
///    lower to the fast `copy`/`borrow`/`move_` slot ops; the
///    verify-only annotations that picked the opcode are consumed at
///    lowering time and never reach the image); residual drops; the
///    n-ary aggregates kept atomic (one fixed 4-byte record plus
///    descriptor); cleanup tokens (`cleanup_arm` allocates the next
///    function-local cleanup cell, `cleanup_disarm`/`cleanup_drop`
///    carry its index, `drop_` lowers to `drop`, and
///    `FunctionDesc.cleanup_base`/`cleanup_count`/
///    `cleanup_descs_start` fill the frame layout).
/// 8. edge blocks (`cfg_lower_llir_edges.planBlocks`) — expand the block
///    order with one LLIR-only edge block per effect-bearing outgoing
///    edge (phi copies or lifecycle kills), so only the selected edge's
///    effects execute (TODO.md 7.1).
/// 9. edge emit (`cfg_lower_llir_edges.run`) — phi elimination as ordinary edge
///    records in each edge block: each incoming lowers to `copy`/`move`/`borrow`
///    then the lifecycle kills, reverse-topologically ordered,
///    self-loops elided, back-edge swap cycles serialized through
///    one scratch slot in `[V, V + S)` with its type row filled.
/// 10. control emit (`cfg_lower_llir_control.run`) — the terminator records with
///    unresolved targets: `j`/`br` records carry placeholder offsets
///    (their targets are derived from the input CFG's terminators),
///    while the `switch_arms` rows still hold their targets' symbolic
///    `BlockId`s.
/// 11. LLIR rewrites (`llir_fusion.peephole`,
///    `llir_compact_noop_ownership.compactNoopOwnership`,
///    `llir_fuse_lifecycle.fuseLifecycle`,
///    `llir_expand_spills.expandSpills`) — block-local record-list changes
///    only: const+op fusion into the 38 `*_i` immediate variants
///    (integer commuting, ordering swap+flip) plus `read_indexi` and
///    the fused multiply-accumulate family (density reported in
///    `last_fusion`), same-slot ownership coalescing, ownership
///    fusions, and X-spill take/put expansion.
/// 12. linearize (`llir_linearize.run`, then `finish`) — the deferred-PC
///     stage: it alone generates the linear form (the single global
///     instruction array, `FunctionDesc` code ranges/`entry_pc`,
///     `BlockDesc` rows), expands out-of-reach branches iteratively,
///     writes the final relative offsets for branches, jumps, direct
///     calls, and switch arms, and snapshots the frozen image.
///
/// No stage before linearization computes, stores, or re-backfills an
/// absolute PC — target identities simply do not exist until then —
/// and the whole backend is a read-only projection of the input CFG
/// (Stilla LLIR Specification §1): nothing ever rewrites it.
pub const LlirBuilder = cfg_lower_llir.Builder;
/// 2.3 register allocation (`llir_alloc.zig`): the type-constrained
/// linear-scan value→slot mapping and the per-function frame layout
/// numbers (`value_slot_count`/`scratch_slot_count`/`cleanup_count`/
/// `window_count`/`slot_types_len`). The Step 8 result coalescing runs
/// as the driver's next stage (`llir_result_coalesce.zig`), and the
/// same-slot ownership-transfer cleanup runs after fusion
/// (`llir_compact_noop_ownership.zig`).
pub const allocateSlots = llir_alloc.allocateSlots;
pub const compactNoopOwnership = llir_noop.compactNoopOwnership;
/// 2.14/2.15 instruction fusion (`llir_fusion.zig`): the const+op
/// immediate fusion, `read_indexi`, and the fused
/// multiply-accumulate peepholes — folds fused sites into their
/// immediate variants and compacts each block's record list
/// block-locally.
pub const fuseLlir = llir_fusion.peephole;
/// The LLIR-layer shape validator (Stilla LLIR Specification §8):
/// dense/range IDs, function/block code ranges, terminator positions,
/// descriptor kinds and ranges, branch/call targets, register/special
/// schemas, and frame/stack-size bounds — never SSA dominance or
/// ownership dataflow (§8.1). Re-exported
/// for the frontend and tests. `validate(image)` checks the image in
/// place; the interpreter runs the same image — v9 has no validated-
/// handle type and no derived execution plan (`loadValidated` is
/// deleted).
pub const validateLlir = llir_validate.validate;
/// Symbolic LLIR assembly printer: the frozen program
/// image rendered as a deterministic symbolic text projection, using the
/// source program for names. Read-only projection of the image.
pub const llirAsm = llir_asm.print;
/// LLIR binary serialization: the frozen image written as a
/// flat little-endian byte stream — magic/version/table-count header
/// plus the side tables row by row, hand-encoded per field (spec §8
/// forbids serializing Zig struct layouts directly). Deterministic and
/// pointer-free; `bytes.len == emitBinSize(image)`.
pub const emitBin = llir_emit_bin.write;
/// `emitBin` with the entry `FunctionId` written into the header (D3):
/// the self-contained form a `--run` binary load executes from.
pub const emitBinWithEntry = llir_emit_bin.writeWithEntry;
/// The serialized byte size of an image.
pub const emitBinSize = llir_emit_bin.size;
/// The minimal binary reader: reconstructs the field-equal
/// in-memory image from `emitBin` bytes, bounds-checked, all slices
/// allocated with the caller's allocator.
pub const readBin = llir_emit_bin.read;
/// The entry `FunctionId` from a `emitBinWithEntry` header; the caller
/// range-checks it against the loaded image before use.
pub const readBinEntry = llir_emit_bin.readEntry;
/// Post-optimization drop lowering (air.md §6.4, §14): expand every
/// statically-expandable `drop` in the CFG — structs (hook call +
/// reverse-order field drops), tuples, boxes, and unions — leaving only
/// the drops that must reach the runtime (opaque host types, `hostdata`,
/// `list[T]`, `any`). Runs after the optimizer; requires the phase-1
/// module graph for field/variant types and ownership.
pub const lowerDrop = cfg_lower_drop.lowerDrop;

pub const pre = cfg_pre.pre;
pub const ifConvert = cfg_optimize.ifConvert;
pub const deadBlock = cfg_dead_block.deadBlock;
pub const tailCall = cfg_tail_call.tailCall;
pub const inlineCalls = cfg_optimize.inlineCalls;
pub const dropElide = cfg_drop_elide.dropElide;
pub const jumpThread = cfg_jump_thread.jumpThread;
pub const phiSimplify = cfg_phi_simplify.phiSimplify;
pub const cse = cfg_optimize.cse;
pub const copyProp = cfg_optimize.copyProp;
pub const deadInstr = cfg_optimize.deadInstr;
pub const optimize = cfg_optimize.optimize;
/// The air.md §13 AIR validator (frontend.md Pass 6.1), re-exported for
/// the frontend and tests.
pub const validate = cfg_optimize.validate;
