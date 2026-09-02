//! CFG-to-LLIR conversion state and emission.
//!
//! Emission writes block-local records with symbolic `BlockId` targets.
//! After allocation, lifecycle lowering, and fusion, linearization concatenates
//! records, assigns PCs and ranges, and resolves targets. `Builder` is the
//! shared state used by those passes.

const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const llir_alloc = @import("llir_alloc.zig");
const llir_coalesce = @import("llir_result_coalesce.zig");
const llir_spill = @import("llir_expand_spills.zig");
const llir_noop = @import("llir_compact_noop_ownership.zig");
const llir_fuse_lc = @import("llir_fuse_lifecycle.zig");
const llir_fusion = @import("llir_fusion.zig");
const llir_prepare = @import("cfg_lower_llir_prepare.zig");
const llir_intern = @import("cfg_lower_llir_intern.zig");
const llir_edges = @import("cfg_lower_llir_edges.zig");
const llir_budget = @import("cfg_lower_llir_budget.zig");
const llir_emit = @import("cfg_lower_llir_emit.zig");
const llir_control = @import("cfg_lower_llir_control.zig");
const linearize = @import("llir_linearize.zig");
const typed_layer = @import("cfg_lower_typed.zig");

/// One function's contiguous range into `ordered_blocks` — the global
/// block table is the concatenation of these rows in FunctionId order
/// (the sizing reads these ranges block-locally;
/// linearization lays out the linear form).
pub const BlockRange = struct {
    start: u32,
    len: u32,
};

/// One interned `{ start, len }` range into the flat `params` table —
/// the dedup key of a signature's parameter list (also used for the
/// type-argument ranges of `named`/`tuple` rows).
pub const ParamRange = struct {
    start: u32,
    len: u32,
};

/// A CFG edge `pred → succ`, the dedup key of the per-edge lifecycle
/// kills and the LLIR-only edge blocks that carry them. Keyed by block
/// pointers (stable across the stage-7 block-order expansion), so the
/// lifecycle pass never depends on a BlockId that later shifts.
pub const EdgeKey = struct {
    pred: *const cfg.BasicBlock,
    succ: *const cfg.BasicBlock,
};

/// The pointer-pair hashing context for `EdgeKey`.
pub const EdgeCtx = struct {
    pub fn hash(_: EdgeCtx, k: EdgeKey) u64 {
        return @intFromPtr(k.pred) *% 0x9e3779b97f4a7c15 ^ @intFromPtr(k.succ);
    }
    pub fn eql(_: EdgeCtx, a: EdgeKey, b: EdgeKey) bool {
        return a.pred == b.pred and a.succ == b.succ;
    }
};

// edge planning moved to cfg_lower_llir_edges.zig — EdgeCopy et al.

// fusion helpers moved to llir_fusion.zig — typedKind et al.
/// The const+op fusion peephole's before/after density report —
/// instruction counts and image bytes (4 per instruction record)
/// of the emitted code table, before and after the pass compacts
/// away the fused `const` records (a fused site is
/// 4 image bytes versus 8 for its `const` + op expansion).
const lifecycle = @import("cfg_lower_lifecycle.zig");

pub const FusionMetrics = struct {
    before_instrs: u32 = 0,
    after_instrs: u32 = 0,
    before_bytes: u32 = 0,
    after_bytes: u32 = 0,
};

// slot-allocation structures moved to llir_alloc.zig — SlotInfo et al.

/// The CFG → LLIR lowering driver: a data home plus the per-stage
/// logic (AGENTS.md — one file per pass; the stages share this context).
/// Owns the dense ID maps and the ordered entity lists.
pub const Builder = struct {
    arena: std.mem.Allocator,
    program: *const cfg.IrProgram,

    // --- dense ID allocation -----------------------------------------------
    /// `IrFunc` → LLIR `FunctionId`, in module order.
    func_ids: std.AutoHashMapUnmanaged(*const cfg.IrFunc, llir.FunctionId) = .empty,
    /// `BasicBlock` → LLIR `BlockId`, in `cfg.BlockOrder` per function.
    block_ids: std.AutoHashMapUnmanaged(*const cfg.BasicBlock, llir.BlockId) = .empty,
    /// All functions in LLIR order (`IrProgram.funcs` is already
    /// module order, then declaration order within a module).
    ordered_funcs: std.ArrayList(*const cfg.IrFunc) = .empty,
    /// All blocks in LLIR order: function by function (FunctionId
    /// order), `cfg.BlockOrder` within each function.
    ordered_blocks: std.ArrayList(*const cfg.BasicBlock) = .empty,
    /// Per-function contiguous range into `ordered_blocks`, in FunctionId
    /// order.
    block_ranges: std.ArrayList(BlockRange) = .empty,

    // --- per-block record lists — PCs deferred to linearization ------------
    /// Per-block non-phi instruction count, parallel to `ordered_blocks`:
    /// the number of instruction records at the head of each block's
    /// list (the edge copies/kills follow, the terminator last; a stage-7
    /// edge block has zero non-phi instructions).
    non_phi_counts: std.ArrayList(u32) = .empty,
    /// Per-block edge-effect record count (phi copies + lifecycle kills),
    /// parallel to `ordered_blocks`: only a stage-7 LLIR-only edge block
    /// holds copies/kills (its single edge's); every ordinary block
    /// reserves none (its edges' effects live in the edge blocks), except
    /// a tailcall whose row covers the slot_* prep + leftover kills.
    edge_copy_counts: std.ArrayList(u32) = .empty,
    /// Per-block edge-copy start position (= block_start +
    /// non_phi_count), parallel to `ordered_blocks`. Pre-computed in
    /// `cfg_lower_llir_budget.run` so `cfg_lower_llir_edges`'s
    /// cycle-staging slot lookup can find dead value
    /// slots without depending on `non_phi_counts` being already
    /// populated for the current block.
    block_edge_starts: std.ArrayList(u32) = .empty,
    /// Per-block conservative start position and full record
    /// length (non-phi + edge copies + terminator at the fixed br = 2
    /// count), parallel to `ordered_blocks` — the trailing-j
    /// elimination's reach table. Computed decision-free in
    /// `cfg_lower_llir_budget.run`
    /// (every `br` counted at two records); the final distances only
    /// shrink, so the decision (which may drop a br to one record)
    /// reads these tables and never the mutable counts, keeping budget,
    /// emission, and the post-emission passes in agreement.
    starts_cons: std.ArrayList(u32) = .empty,
    block_lens_cons: std.ArrayList(u32) = .empty,
    /// Per-block record lists, parallel to `ordered_blocks` — the
    /// symbolic intermediate the emission stages build. Each block's
    /// list holds, in order: one record per non-phi instruction (at
    /// block-local index = the instruction's non-phi ordinal), the edge
    /// copies/kills (the whole list for an LLIR-only edge block; none for
    /// ordinary blocks), then the terminator. Pre-sized by
    /// `cfg_lower_llir_budget.run` to
    /// `non_phi + edge_copies + terminator`; every stage writes at block-local
    /// indices, so no absolute PC exists until linearization builds the
    /// lists into the image.
    block_records: std.ArrayList(std.ArrayList(llir.Instr)) = .empty,
    /// `BasicBlock` → absolute start PC, filled by `llir_linearize.run` —
    /// the last stage, so the values are final. `pcOf` reads this; the
    /// emission stages never do.
    block_pcs: std.AutoHashMapUnmanaged(*const cfg.BasicBlock, u32) = .empty,
    /// The single global instruction array (one table, all
    /// functions) — the linear form, generated by `llir_linearize.run`
    /// from the per-block lists.
    instructions: std.ArrayList(llir.Instr) = .empty,
    /// `FunctionDesc` rows, parallel to `ordered_funcs`. `prepare`
    /// appends zeroed rows; the code-range fields (`code_start`,
    /// `code_end`, `entry_pc`) are filled by `llir_linearize.run`; the
    /// rest come from the later stages (slot allocation, interning,
    /// cleanup).
    func_descs: std.ArrayList(llir.FunctionDesc) = .empty,
    /// `BlockDesc` rows, parallel to `ordered_blocks`, filled by
    /// `llir_linearize.run`.
    block_descs: std.ArrayList(llir.BlockDesc) = .empty,

    // --- linear-scan value→slot mapping, frame layout numbers ---------------
    /// Physical slot for every SSA value. Values with non-overlapping,
    /// type-equal intervals share a slot; copy/move values may intentionally
    /// alias their source slot.
    value_slots: std.AutoHashMapUnmanaged(*const cfg.Value, llir.SlotId) = .empty,
    /// Per-value interval end positions, parallel to the program's
    /// value array — the global position of each value's last use (or the
    /// live-out extension). Used by the edge pass's
    /// cycle-staging slot lookup to find dead
    /// value slots that can be reused for cycle staging instead of
    /// allocating dedicated scratch.
    value_ends: std.ArrayList(u32) = .empty,
    /// Per-value interval start positions, parallel to `value_ends`
    /// (one entry per value in `f.values` order, across all functions).
    /// The spill selection replays the scan's cell occupancy over the
    /// `(start, end)` intervals to find the peak-liveness position and
    /// the values occupying cells there.
    value_starts: std.ArrayList(u32) = .empty,
    /// v1: there are no slot-type rows — every F/X cell
    /// holds one host word and the validator derives exact types from
    /// typed opcodes, signatures, and descriptors at load time.
    /// Per-function distinct phi-cycle staging types, in
    /// first-occurrence order — the scratch rows after the value area
    /// (`V + rank`). The edge pass's cycle-staging slot lookup
    /// reads it back when
    /// emission resolves a cycle's staging slot.
    scratch_cycle_types: std.ArrayList(std.ArrayList(*const cfg.Type)) = .empty,
    /// Cycle-type detection mode: while set (inside `allocateSlots`, before the
    /// scratch rows exist), the edge pass's cycle-staging lookup
    /// records the
    /// requested type into the sink and returns a placeholder id. The
    /// placeholder cannot perturb the copy-graph walk — staging ids
    /// appear only as record dsts, never as copy-graph nodes — so
    /// detection and emission run the identical walk.
    detect_cycle_types: ?*std.ArrayList(*const cfg.Type) = null,

    // --- interning (strings, constants, types, signatures, symbols, imports) ---------
    /// The lowering scope: `null` lowers every function of the program
    /// (the canonical shared-metadata pass); an index lowers exactly that
    /// module's functions into its own artifact.
    module_scope: ?usize = null,
    /// This artifact's header fields, filled by the interning pass:
    /// the module's own symbol, its init function (local id), and the
    /// symbolic entry member.
    self_symbol: u32 = 0,
    artifact_init: u32 = llir.no_index,
    entry_member: u32 = llir.no_index,
    /// `module or member name → SymbolId` (the artifact's `symbols`
    /// table, backed by the strings blob).
    symbol_starts: std.StringHashMapUnmanaged(u32) = .empty,
    symbols: std.ArrayList(llir.SymRange) = .empty,
    /// Deduped `(module_symbol, member_symbol)` cross-module imports.
    imports: std.ArrayList(llir.ImportDesc) = .empty,
    /// The sorted export table (public members plus every function).
    exports: std.ArrayList(llir.ExportDesc) = .empty,
    /// `qualified IrFunc name → FunctionId` (fn_ref operands, drop hooks) —
    /// module-scope-local: a name outside the scope lowers to a symbolic
    /// import.
    func_name_ids: std.StringHashMapUnmanaged(llir.FunctionId) = .empty,
    /// The program-owned string blob; string constants and host-type
    /// names index it with `{ start, len }` records.
    strings: std.ArrayList(u8) = .empty,
    /// String content → blob offset; equal strings share bytes.
    string_starts: std.StringHashMapUnmanaged(u32) = .empty,
    constants: std.ArrayList(llir.ConstRecord) = .empty,
    types: std.ArrayList(llir.TypeDesc) = .empty,
    type_decls: std.ArrayList(llir.TypeDeclDesc) = .empty,
    type_decl_fields: std.ArrayList(llir.TypeId) = .empty,
    union_variants: std.ArrayList(llir.UnionVariant) = .empty,
    union_payloads: std.ArrayList(llir.TypeId) = .empty,
    host_types: std.ArrayList(llir.HostTypeDesc) = .empty,
    module_slots: std.ArrayList(llir.ModuleSlot) = .empty,
    signatures: std.ArrayList(llir.SignatureDesc) = .empty,
    params: std.ArrayList(llir.ParamDesc) = .empty,
    /// Interned `{ start, len }` ranges into `params` (dedup keys for
    /// signature parameter lists).
    param_ranges: std.ArrayList(ParamRange) = .empty,
    /// Interned `{ start, len }` ranges into `types` — the type-argument
    /// ranges of `named`/`tuple` rows (dedup keys; the ranges are
    /// range-owned copies, see `internArgRange`).
    arg_ranges: std.ArrayList(ParamRange) = .empty,

    // --- syscall + construct descriptors (shared call_args) ---------------
    /// One `ValueReg` per syscall/construct argument, in order —
    /// the `syscall` and `construct` descs all range into this one
    /// table (calls carry no descriptor; their arguments travel
    /// through the outgoing window).
    call_args: std.ArrayList(llir.ValueReg) = .empty,
    syscall_descs: std.ArrayList(llir.SyscallDesc) = .empty,

    // --- construct / destructure / switch descriptors -------------------
    /// `construct` component registers — ranged into by
    /// `construct_descs`, sharing the `call_args` register table the
    /// syscall descs already use.
    construct_descs: std.ArrayList(llir.ConstructDesc) = .empty,
    /// One result slot per multi-result destructure, in result order
    /// — ranged into by `destructure_descs`.
    destructure_dsts: std.ArrayList(llir.ValueReg) = .empty,
    /// Parallel to `destructure_dsts`: each result's TypeId (v1).
    destructure_dst_types: std.ArrayList(llir.TypeId) = .empty,
    destructure_descs: std.ArrayList(llir.DestructureDesc) = .empty,
    /// `switch` arms — `{ tag, target }` rows ranged into by
    /// `switch_descs` (the implicit default is a trap).
    switch_arms: std.ArrayList(llir.SwitchArm) = .empty,
    switch_descs: std.ArrayList(llir.SwitchDesc) = .empty,

    // --- member/drop descriptors ---------------------------------------------
    /// `MemberDesc` rows for load_member/store_member/read_field/
    /// read_tuple/read_payload: base/result TypeIds plus
    /// the member/slot/index reference.
    member_descs: std.ArrayList(llir.MemberDesc) = .empty,
    /// `DropDesc` rows for the residual `drop src, DropDescId` records
    /// exactly one of type/host is set.
    drop_descs: std.ArrayList(llir.DropDesc) = .empty,

    // --- v1 lifecycle plan (cfg_lower_lifecycle.zig) -------------------------
    /// Per-instruction trailing destroy records (counted releases after
    /// a final use), from the lifecycle pass.
    release_trailing: std.AutoHashMapUnmanaged(*const cfg.Instr, std.ArrayList(lifecycle.Rec)) = .empty,
    /// Per-edge kill records (counted releases leaving the live region),
    /// keyed by `pred_block_id << 32 | succ_block_id`; appended after the
    /// edge copies by `edgeCopyList`.
    release_edges: std.HashMapUnmanaged(EdgeKey, std.ArrayList(lifecycle.Rec), EdgeCtx, 80) = .empty,
    /// Stage-7 edge blocks: `EdgeKey → LLIR-only synthetic block`, the
    /// routing target of every `br`/`switch` arm whose edge carries
    /// phi copies or lifecycle kills. `targetForEdge` reads it.
    edge_blocks: std.HashMapUnmanaged(EdgeKey, *cfg.BasicBlock, EdgeCtx, 80) = .empty,
    /// Synthetic block → its `EdgeKey`; the budgeting and edge-emit
    /// passes look up an edge block's copies/kills (and identify a
    /// block as synthetic) through it. Real CFG blocks are absent.
    edge_block_srcs: std.AutoHashMapUnmanaged(*const cfg.BasicBlock, EdgeKey) = .empty,
    /// Per-tailcall-block leftover-owner kills, emitted after
    /// the `slot_*` preparation and before `tailcall_self`.
    tailcall_kills: std.AutoHashMapUnmanaged(*const cfg.BasicBlock, std.ArrayList(lifecycle.Rec)) = .empty,

    // --- v1 spill bookkeeping (llir_alloc) -----------------------------------
    /// Spilled value → its sentinel staging byte (a free T-range code no
    /// emitter produces); the pre-linearize rewrite identifies spilled
    /// record fields by it.
    spill_bytes: std.AutoHashMapUnmanaged(*const cfg.Value, u8) = .empty,
    /// Sentinel byte → X cell index (`spill_take`/`spill_put` imm16).
    spill_x: std.AutoHashMapUnmanaged(u8, u32) = .empty,

    // --- const+op fusion ----------------------------------------------------
    /// The constant values whose records the peephole fused away — the
    /// image has no record at their old block-local indices
    /// (`isFusedConst`; tests that walk `blk.instrs` next to the image
    /// use it to keep their record bookkeeping aligned after the
    /// per-block compaction).
    fused_consts: std.AutoHashMapUnmanaged(*const cfg.Value, void) = .empty,
    /// The instructions whose records the madd fusion consumed — the `mul` (record
    /// deleted) and `add` (record rewritten to `*_madd`) of every fused
    /// multiply-accumulate site, plus `read_index` instructions folded
    /// to `read_indexi`. The immediate fusion skips
    /// these so a consumed op is never fused twice.
    consumed_instrs: std.AutoHashMapUnmanaged(*const cfg.Instr, void) = .empty,
    /// A CFG arithmetic instruction whose constant operand the expander
    /// pre-fused into an immediate form (step 6: the expander owns the
    /// fused-immediate decision). The fusion pass's use-count must not
    /// count that constant operand, and the pass must not re-fuse it.
    fused_instrs: std.AutoHashMapUnmanaged(*const cfg.Instr, void) = .empty,
    /// The last `peephole` run's before/after instruction and image-byte
    /// counts (density accounting).
    last_fusion: FusionMetrics = .{},
    /// The long-branch expansion's layout rounds:
    /// each round expands every out-of-reach branch and re-lays
    /// the image; convergence is bounded because each branch expands at
    /// most once (the `offs10 == 2` marker). Diagnostic counter for the
    /// acceptance tests.
    expansion_rounds: u32 = 0,
    /// Set when an inline ID did not fit its 7-bit field (`fit7` — an
    /// inline `TypeId`/`MemberId`/`DestructureDescId` at or above 128).
    /// `lowerLlir` checks the flag after linearization and returns
    /// `error.IdOutOfRange` —
    /// v9 adds no wide-ID fallback.
    id_overflow: bool = false,
    /// Set when the export table would carry a duplicate symbol — the
    /// artifact cannot resolve imports unambiguously, so `lowerLlir`
    /// fails with `error.DuplicateExport`.
    export_duplicate: bool = false,
    /// Set when an operand did not fit its 4-byte `Instr` field
    /// (`fit7`/`fit16`/`fit10Signed`/`fit20Signed`). `lowerLlir` checks
    /// the flag after linearization and returns `error.ProgramTooLarge` — the
    /// truncated image never escapes.
    /// The 32-bit format bounds every inline operand: a register is at
    /// most `0x7f` (the frame caps at `frame_count_max` = 109, the
    /// specials at `0x7f`), an inline R-format ID at most `0x7f` (127
    /// rows per table; ID 128 is `error.IdOutOfRange`), an I-format ID
    /// at most `0xffff`, a B-type branch target a signed 10-bit offset
    /// (reach ±512 instructions around the branch — beyond it the
    /// long-branch expansion applies), and a
    /// `jal` target a signed 20-bit offset (reach ±2¹⁹; beyond it
    /// `error.ProgramTooLarge`).
    operand_overflow: bool = false,

    pub fn init(arena: std.mem.Allocator, program: *const cfg.IrProgram) Builder {
        return .{ .arena = arena, .program = program };
    }

    /// The index of the module this Builder lowers: `module_scope` when
    /// set, else the entry function's module (the canonical
    /// shared-metadata pass publishes the entry module's artifact).
    pub fn scopeModuleIndex(self: *const Builder) usize {
        if (self.module_scope) |mi| return mi;
        if (self.program.entry) |e| {
            if (e.module_spec) |spec| {
                for (self.program.modules, 0..) |m, i| {
                    if (std.mem.eql(u8, m.name, spec)) return i;
                }
            }
        }
        // No module scope and no entry (whole-program text-form): the
        // artifact's identity is the module that owns the most functions
        // — the "app" module of a multi-module text-form fixture.
        var best: usize = 0;
        var best_n: usize = 0;
        for (self.program.modules, 0..) |m, i| {
            if (m.funcs.len > best_n) {
                best = i;
                best_n = m.funcs.len;
            }
        }
        return best;
    }

    /// Whether `f` belongs to this Builder's module scope.
    pub fn inScope(self: *const Builder, f: *const cfg.IrFunc) bool {
        // No module scope and no host-selected entry: the text-form /
        // whole-program artifact lowers every function (one artifact
        // per compilation — Runtime §6). With a module scope or an
        // entry, only that module's functions are emitted.
        if (self.module_scope == null and self.program.entry == null) return true;
        const mi = self.scopeModuleIndex();
        for (self.program.modules[mi].funcs) |mf| {
            if (mf == f) return true;
        }
        return false;
    }

    /// The module symbol of the module that declares the qualified
    /// function name `qname` ("spec.func[.inst]" — the part before the
    /// first dot), or null when the name carries no dot.
    pub fn splitQualName(qname: []const u8) ?struct { module: []const u8, member: []const u8 } {
        const dot = std.mem.indexOfScalar(u8, qname, '.') orelse return null;
        if (dot + 1 >= qname.len) return null;
        return .{ .module = qname[0..dot], .member = qname[dot + 1 ..] };
    }

    /// Whether the qualified callee/function name resolves outside this
    /// Builder's module scope — a lowering to a symbolic import. The
    /// name must still resolve somewhere in the program (else it is a
    /// lowering bug, reported by the emitter's `unreachable` as before).
    pub fn isCrossModuleName(self: *const Builder, qname: []const u8) bool {
        if (self.func_name_ids.contains(qname)) return false;
        return true;
    }

    /// The program-wide `IrFunc` behind a qualified name — a read-only
    /// lookup used for parameter-mode metadata (never for emitted
    /// references, which resolve locally or through imports).
    pub fn programFuncByName(self: *const Builder, qname: []const u8) ?*const cfg.IrFunc {
        for (self.program.funcs) |f| {
            if (std.mem.eql(u8, f.name.text, qname)) return f;
        }
        return null;
    }

    /// Intern a symbol (canonical module specifier or member name) into
    /// the artifact's `symbols` table; equal names share one `SymbolId`.
    pub fn internSymbol(self: *Builder, name: []const u8) error{OutOfMemory}!u32 {
        if (self.symbol_starts.get(name)) |id| return id;
        const start = try llir_intern.internString(self, name);
        const id: u32 = @intCast(self.symbols.items.len);
        try self.symbols.append(self.arena, .{ .start = start, .len = @intCast(name.len) });
        try self.symbol_starts.put(self.arena, name, id);
        return id;
    }

    /// Intern a deduped cross-module import `(module_symbol,
    /// member_symbol)`; `member_name` null is a module-only import
    /// (`member_sym = no_index`). Returns the `ImportDesc` index.
    pub fn importIndex(self: *Builder, module_name: []const u8, member_name: ?[]const u8) error{OutOfMemory}!u32 {
        const msym = try self.internSymbol(module_name);
        const msym2: u32 = if (member_name) |mn| try self.internSymbol(mn) else llir.no_index;
        for (self.imports.items, 0..) |imp, i| {
            if (imp.module_sym == msym and imp.member_sym == msym2) return @intCast(i);
        }
        try self.imports.append(self.arena, .{ .module_sym = msym, .member_sym = msym2 });
        return @intCast(self.imports.items.len - 1);
    }

    /// Seed this Builder with another (whole-program) lowering's
    /// canonical shared metadata — types, declarations, signatures,
    /// constants, and the strings blob are **identical rows** in every
    /// artifact of one compilation, so their ids are canonical across
    /// the artifact set and content-deduping interning never appends.
    pub fn seedShared(self: *Builder, canon: *const Builder) error{OutOfMemory}!void {
        try self.strings.appendSlice(self.arena, canon.strings.items);
        var it = canon.string_starts.iterator();
        while (it.next()) |kv| {
            try self.string_starts.put(self.arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        try self.constants.appendSlice(self.arena, canon.constants.items);
        try self.types.appendSlice(self.arena, canon.types.items);
        try self.type_decls.appendSlice(self.arena, canon.type_decls.items);
        try self.type_decl_fields.appendSlice(self.arena, canon.type_decl_fields.items);
        try self.union_variants.appendSlice(self.arena, canon.union_variants.items);
        try self.union_payloads.appendSlice(self.arena, canon.union_payloads.items);
        try self.host_types.appendSlice(self.arena, canon.host_types.items);
        try self.signatures.appendSlice(self.arena, canon.signatures.items);
        try self.params.appendSlice(self.arena, canon.params.items);
        try self.param_ranges.appendSlice(self.arena, canon.param_ranges.items);
        try self.arg_ranges.appendSlice(self.arena, canon.arg_ranges.items);
    }

    /// Run the stages implemented so far. The ID-allocation stage
    /// (`cfg_lower_llir_prepare.run`) builds the dense
    /// ID spaces and the zeroed `FunctionDesc` rows (the code-range
    /// fields come from linearization).
    pub fn prepare(self: *Builder) error{OutOfMemory}!void {
        try llir_prepare.run(self);
    }

    /// Lower the whole program to its frozen image. Every record is
    /// emitted into its block's local list (the sizing reserves them; the
    /// fill them in place — slots via `llir_alloc.allocateSlots`; the
    /// fusion passes compact them block-locally via `llir_fusion.peephole` and
    /// `llir_compact_noop_ownership.compactNoopOwnership`), and only linearization — the last
    /// stage — computes PCs (absolute, and the B-type/`jal` relative
    /// offsets), when the linear form is generated. The returned program's slices alias this Builder's
    /// arena. A program whose operands exceed the v9 format's fields
    /// fails with `error.ProgramTooLarge` (no image is
    /// returned); the format bounds inline operands — inline IDs at most
    /// 127 rows per table (ID 128 is `error.IdOutOfRange`), I-format
    /// IDs at most `0xffff`, B-type branch offsets at most ±512
    /// (expanded via the long-branch expansion safety net) and `jal`
    /// offsets at most ±2¹⁹.
    pub fn lowerLlir(self: *Builder) error{ OutOfMemory, ProgramTooLarge, IdOutOfRange, SyscallWithoutSignature, DuplicateExport }!llir.LlirProgram {
        try self.prepare();
        try llir_alloc.allocateSlots(self); // linear-scan F allocation (llir_alloc.zig)
        try llir_coalesce.run(self); // Step 8 result coalescing (llir_result_coalesce.zig)
        try lifecycle.plan(self); // release placement / tailcall kills (cfg_lower_lifecycle.zig)
        try llir_edges.planBlocks(self); // LLIR-only edge blocks for effect-bearing br/switch arms
        try llir_budget.run(self); // per-block record sizing (block-local only)
        try llir_intern.run(self); // side tables: strings/consts/types/decls/modules/sigs/bindings
        try llir_emit.run(self); // body emission: ID-ops/arith/cmp/cast/select/calls/ownership/drops/aggregates
        try llir_edges.run(self); // phi-elimination edge copies (block-local)
        try llir_control.run(self); // terminator records (symbolic targets)
        _ = try llir_fusion.peephole(self); // const+op fusion, an independent pass (llir_fusion.zig)
        try llir_noop.compactNoopOwnership(self); // same-slot ownership coalescing (llir_compact_noop_ownership.zig)
        _ = try llir_fuse_lc.fuseLifecycle(self); // ownership fusions (llir_fuse_lifecycle.zig)
        try llir_spill.expandSpills(self); // X-spill take/put expansion (llir_expand_spills.zig)
        try linearize.run(self); // the linear form: PCs, ranges, target fixups
        if (self.id_overflow) return error.IdOutOfRange;
        if (self.operand_overflow) return error.ProgramTooLarge;
        if (self.export_duplicate) return error.DuplicateExport;
        return self.finish();
    }

    /// The register encoding of an SSA value's physical slot. Frame
    /// values map to `frameReg(value_slots[v])`; a spilled value maps to
    /// its T-range sentinel byte (`spill_bytes`), already an encoding.
    /// The two spaces overlap numerically (spill sentinels `0x02–0x11`
    /// vs. low frame indexes), so the spill map — never the value —
    /// decides.
    pub fn slotOf(self: *const Builder, v: *const cfg.Value) llir.SlotId {
        const s = self.value_slots.get(v) orelse unreachable;
        if (self.spill_bytes.get(v) != null) return s; // T spill sentinel
        return llir.frameReg(s);
    }

    // register allocation moved to llir_alloc.zig — allocateSlots et al.

    // interning moved to cfg_lower_llir_intern.zig — internAll (the
    // `run` entry), the string/const/type/signature/host-binding and
    // operation-descriptor interners, and the OwnershipId enum.
    // body emission moved to cfg_lower_llir_emit.zig — emitInterned
    // et al. (the `run` entry orchestrates the instruction families).

    /// The absolute start PC of a block — the final layout, filled by
    /// `llir_linearize.run`. The emission stages never call this; it is
    /// the read-only query for consumers after `lowerLlir`.
    pub fn pcOf(self: *const Builder, blk: *const cfg.BasicBlock) u32 {
        return self.block_pcs.get(blk).?;
    }

    /// The `cfg.OpTag` → `llir.TypedKind` mapping, the typed
    /// arithmetic/shift/bitwise/extended opcode helpers, and
    /// `emitArith` moved to cfg_lower_llir_emit.zig.
    /// Whether `t` is an integer primitive — the `le`/`ge` synthesis
    /// and the immediate/register fused-branch forms read it. Shared
    /// with the budgeting pass's record counts.
    pub fn isInteger(t: cfg.Type) bool {
        return switch (t.primitive) {
            .int32, .uint32, .byte, .int64, .uint64 => true,
            else => false,
        };
    }

    /// The number of LLIR records one CFG instruction occupies: 1 plus
    /// its call-argument moves, plus one more for an integer
    /// `le`/`ge` whose `not`(gt/lt) synthesis emits a second record.
    /// Every stage that walks `blk.instrs` with the block-local record
    /// index — emission, `budget` sizing, the fusion peephole — advances
    /// by this count so the stages agree on record placement.
    /// Compatibility shim: the count lives with the budgeting pass
    /// (`cfg_lower_llir_budget.recordCount`); white-box callers (the
    /// fusion peephole, the LLIR suites) go through this Builder method
    /// until they are deliberately migrated.
    pub fn recordCount(self: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) error{OutOfMemory}!u32 {
        return llir_budget.recordCount(self, blk, ins);
    }

    /// The v9 cast opcode helper, `emitSelect`, and `emitCompare`
    /// moved to cfg_lower_llir_emit.zig.
    /// `emitDrops`, `emitAggregates`, and `emitDestructure` moved to
    /// cfg_lower_llir_emit.zig.
    /// True when the const+op fusion fused `ins`'s record away — the image has no
    /// record at its old block-local index. Only a `const_` instruction
    /// can be fused; every other instruction always has a record. Tests
    /// that walk `blk.instrs` next to the image use this to keep their
    /// record bookkeeping aligned after the per-block compaction.
    pub fn isFusedConst(self: *const Builder, ins: *const cfg.Instr) bool {
        if (std.meta.activeTag(ins.op) != .const_) return false;
        return self.fused_consts.contains(ins.results[0]);
    }

    /// True when the fusion passes deleted `ins`'s record — the image has no
    /// record at its old block-local index: a fused-away `const`, or a
    /// `mul` folded into a `*_madd`/`*_maddi`. Instructions rewritten in
    /// place (a fused `add` or `read_index`) still have records and are
    /// not reported. Tests that walk `blk.instrs` next to the image use
    /// this to keep their record bookkeeping aligned after the
    /// per-block compaction.
    pub fn isFusedAway(self: *const Builder, ins: *const cfg.Instr) bool {
        if (std.meta.activeTag(ins.op) == .const_) return self.fused_consts.contains(ins.results[0]);
        if (std.meta.activeTag(ins.op) == .mul) return self.consumed_instrs.contains(ins);
        return false;
    }

    /// Whether the instruction has no LLIR record after lowering.
    /// Fusion and same-slot ownership coalescing are kept separate so
    /// density metrics do not mislabel eliminated moves as fused arithmetic.
    pub fn isRecordElided(self: *const Builder, ins: *const cfg.Instr) bool {
        if (self.isFusedAway(ins)) return true;
        return switch (ins.op) {
            .copy, .borrow, .move_ => |source| ins.results.len > 0 and self.slotOf(ins.results[0]) == self.slotOf(source),
            // v1: cleanup tokens produce no records at all.
            .cleanup_arm, .cleanup_disarm, .cleanup_drop => true,
            else => false,
        };
    }
    /// The number of LLIR records a CFG terminator lowers to:
    /// one for every terminator, plus one more for a `br` — its image
    /// is a compare-and-branch followed by the unconditional `j` that
    /// carries the else-target. A `br` drops the
    /// trailing `j` when one of its targets is the next block in the
    /// layout: the else target then falls through (branch to then,
    /// unchanged polarity), or — when the then body is the next block
    /// and the else target sits within the compare-and-branch's ±127
    /// reach — the condition inverts (blt↔ble, bltu↔bleu, beq↔bne;
    /// `bne cond, zero` ↔ `beq cond, zero`) and the branch targets else
    /// with the then body falling through. The reach check reads the
    /// conservative `starts_cons`/`block_lens_cons` tables (every `br`
    /// at two records — final distances only shrink), never the mutable
    /// counts, so budget, emission, and the post-emission passes
    /// (fusion, `compactNoopOwnership`) all agree.
    /// Compatibility shim: the sizing lives with the budgeting pass
    /// (`cfg_lower_llir_budget.terminatorRecordCount`); white-box
    /// callers (the fusion/alloc compaction, linearization, the LLIR
    /// suites) go through this Builder method until they are
    /// deliberately migrated.
    pub fn terminatorRecordCount(self: *const Builder, blk: *const cfg.BasicBlock) u32 {
        return llir_budget.terminatorRecordCount(self, blk);
    }

    /// The next block in `ordered_blocks` when `bi` is not the last of
    /// its function — the fall-through successor of `bi` in the final
    /// linear layout. Null for a function's last block. Shared by the
    /// trailing-j decision (`terminatorRecordCount`) and the branch-target
    /// derivation (`llir_linearize.branchTargetOf`); the logic lives
    /// with the control pass's fall-through selection.
    pub fn nextBlockOf(self: *const Builder, bi: u32) ?*const cfg.BasicBlock {
        return llir_control.nextBlockOf(self, bi);
    }

    /// The phi-elimination copy list for edge `pred → succ`,
    /// ordered so every source is read before its destination is written
    /// (reverse topological order of the copy graph):
    /// a copy whose destination is another copy's source runs
    /// first. Trivial self-loops (`src == dst`) are elided. A cycle
    /// among the remaining copies — the back-edge swap `%x = phi [..:
    /// %y], %y = phi [..: %x]` — is broken through a type-matched scratch
    /// slot in the frame's scratch region `[V, V + S)`: the
    /// cycle's source is staged (`scratch ← src`, same opcode — a unique
    /// cycle stages with `move`, a view cycle with `borrow`), the remaining
    /// cycle copies run in order, and the staged value lands last. A
    /// k-cycle emits k + 1 records (one staging + k transfers). The staging
    /// slot is `V + phi_type_rank`. The budget counts through this same
    /// function, so reserved and emitted records always agree.
    pub fn edgeCopyList(self: *const Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) error{OutOfMemory}![]const llir_edges.EdgeCopy {
        return llir_edges.edgeCopyList(self, pred, succ);
    }

    /// The number of argument-move records a call emits (0 for any
    /// other instruction) — the block-local record-position offset the
    /// per-instruction emit stages advance past.
    /// Compatibility shim: the count lives with the budgeting pass
    /// (`cfg_lower_llir_budget.callArgMoveCount`).
    pub fn callArgMoveCount(self: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) error{OutOfMemory}!u32 {
        return llir_budget.callArgMoveCount(self, blk, ins);
    }

    /// The parameter list a call's callee declares — direct targets
    /// resolve through their `IrFunc`, indirect ones through the function
    /// value's type. Compatibility shim: the logic lives with the
    /// body-emission pass (`cfg_lower_llir_emit.calleeParamList`),
    /// shared with the lifecycle pass's argument-mode classification.
    pub fn calleeParamList(self: *Builder, callee: cfg.Callee) []const cfg.Param {
        return llir_emit.calleeParamList(self, callee);
    }

    /// The `slot_*` preparation records of one call, in order.
    /// Compatibility shim: the logic lives with the body-emission pass
    /// (`cfg_lower_llir_emit.callArgMoves`), shared with the budgeting
    /// pass's argument-move count.
    pub fn callArgMoves(self: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) error{OutOfMemory}![]const llir_edges.EdgeCopy {
        return llir_emit.callArgMoves(self, blk, ins);
    }

    /// Whether a non-void call emits its post-call `take` record
    /// (`cfg_lower_llir_emit.callNeedsTake`), shared with the budgeting
    /// pass so sized and emitted records agree.
    pub fn callNeedsTake(self: *Builder, blk: *const cfg.BasicBlock, ins: *const cfg.Instr) bool {
        return llir_emit.callNeedsTake(self, blk, ins);
    }

    /// The control-transfer target of edge `pred → succ`: the LLIR-only
    /// edge block when the edge carries phi copies or lifecycle kills
    /// (stage 7), otherwise `succ` itself. Every `br`/`switch` arm target
    /// and the linearization fixups route through this, so only the
    /// selected edge's effects execute.
    pub fn targetForEdge(self: *const Builder, pred: *const cfg.BasicBlock, succ: *const cfg.BasicBlock) *const cfg.BasicBlock {
        return self.edge_blocks.get(.{ .pred = pred, .succ = succ }) orelse succ;
    }

    /// Whether `blk` is a stage-7 LLIR-only edge block (not a source
    /// CFG block). Its record list holds one edge's phi copies then
    /// lifecycle kills, and its terminator is a `j` to the real
    /// successor.
    pub fn isEdgeBlock(self: *const Builder, blk: *const cfg.BasicBlock) bool {
        return self.edge_block_srcs.contains(blk);
    }

    /// The function containing `blk` — the `fi` whose `block_ranges`
    /// row covers the block's global BlockId. Shared with the extracted
    /// edge-planning and budgeting passes.
    pub fn funcIndexOfBlock(self: *const Builder, blk: *const cfg.BasicBlock) usize {
        const bi = self.block_ids.get(blk).?;
        for (self.block_ranges.items, 0..) |r, fi| {
            if (bi >= r.start and bi < r.start + r.len) return fi;
        }
        unreachable;
    }

    /// The R-format emission primitive: three
    /// 7-bit operands — registers, an inline 7-bit ID/immediate, or
    /// zero for an unused field. Writes one record at block-local
    /// index `idx` of `blk`'s record list. The list was pre-sized by
    /// `budget`, so an out-of-range write is a lowering bug, not a
    /// runtime condition — assert instead of error. No PC exists here
    /// (linearization builds the image); the index is the record's position within the
    /// block.
    pub fn setR(self: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: llir.Opcode, a: u32, b: u32, c: u32) void {
        const recs = &self.block_records.items[self.block_ids.get(blk).?];
        std.debug.assert(idx < recs.items.len);
        recs.items[idx] = llir.instrR(op, self.fit7(a), self.fit7(b), self.fit7(c));
    }

    /// The B-format emission primitive: the
    /// tested/compared register, the second register or imm7/bit field,
    /// and the signed 10-bit pc-relative offset. Branches write a
    /// placeholder offset 0 — linearization derives and encodes the target (or
    /// the +2 long-branch skip marker).
    pub fn setB(self: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: llir.Opcode, lhs: u32, mid: u32, offs10: i16) void {
        const recs = &self.block_records.items[self.block_ids.get(blk).?];
        std.debug.assert(idx < recs.items.len);
        recs.items[idx] = llir.instrB(op, self.fit7(lhs), self.fit7(mid), offs10);
    }

    /// The I-format emission primitive: one
    /// register (`a`) plus a 16-bit immediate/ID. The register is a
    /// slot, a T register, or a special; the immediate is a dense table
    /// ID (ConstId, FunctionId, ModuleId, SyscallDescId,
    /// ConstructDescId, DestructureDescId, SwitchDescId, SlotId) or an
    /// offset.
    pub fn setI(self: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: llir.Opcode, reg: u32, imm16: u32) void {
        const recs = &self.block_records.items[self.block_ids.get(blk).?];
        std.debug.assert(idx < recs.items.len);
        recs.items[idx] = llir.instrI(op, self.fit7(reg), self.fit16(imm16));
    }

    /// The C-format emission primitive: two
    /// 7-bit register fields — `a = dst, b = src` for the casts,
    /// `a = lhs, b = rhs` for the comparisons (the destination is the
    /// implicit `cond`).
    pub fn setC(self: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: llir.Opcode, a: u32, b: u32) void {
        const recs = &self.block_records.items[self.block_ids.get(blk).?];
        std.debug.assert(idx < recs.items.len);
        recs.items[idx] = llir.instrC(op, self.fit7(a), self.fit7(b));
    }

    /// The E-format emission primitive: two
    /// 7-bit register fields whose roles are fixed per opcode.
    pub fn setE(self: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: llir.Opcode, a: u32, b: u32) void {
        const recs = &self.block_records.items[self.block_ids.get(blk).?];
        std.debug.assert(idx < recs.items.len);
        recs.items[idx] = llir.instrE(op, self.fit7(a), self.fit7(b));
    }

    /// The U-format emission primitive: the
    /// link/destination register plus a signed 20-bit immediate.
    /// `jal` records write a placeholder offset 0 — linearization derives and
    /// encodes the target; `auipc`/`lui` carry their immediate
    /// directly.
    pub fn setU(self: *Builder, blk: *const cfg.BasicBlock, idx: u32, op: llir.Opcode, a: u32, imm20: i32) void {
        const recs = &self.block_records.items[self.block_ids.get(blk).?];
        std.debug.assert(idx < recs.items.len);
        recs.items[idx] = llir.instrU(op, self.fit7(a), imm20);
    }

    /// Write the unconditional jump `j offs20` — encoded as `jal`'s
    /// U-type word carrying `zero`, its no-link mark (§9.1); the
    /// offset is patched at linearization.
    pub fn setJ(self: *Builder, blk: *const cfg.BasicBlock, idx: u32, offs20: i32) void {
        const recs = &self.block_records.items[self.block_ids.get(blk).?];
        std.debug.assert(idx < recs.items.len);
        recs.items[idx] = llir.instrJ(offs20);
    }

    /// Fused-branch recognition (`FusedBranch`, `fusedBranchOperands`,
    /// `BranchReads`, `fusedBranchReads`) moved to
    /// cfg_lower_llir_control.zig; the facade re-exports the type and
    /// the read query for the allocator.
    pub const FusedBranch = llir_control.FusedBranch;
    pub const BranchReads = llir_control.BranchReads;
    pub fn fusedBranchReads(cond: *const cfg.Value) ?BranchReads {
        return llir_control.fusedBranchReads(cond);
    }

    /// The fused compare-and-branch for a condition value — the
    /// register/immediate/bit-test forms the branch reads directly.
    /// Shared with the budgeting pass (`terminatorRecordCount` reads
    /// the fused branch's invertibility).
    pub fn fusedBranchOperands(cond: *const cfg.Value) ?FusedBranch {
        return llir_control.fusedBranchOperands(cond);
    }

    /// The immediate/bit-test branch selection helpers (`imm7Of`,
    /// `immBranchOf`, `bitTestPattern`, `isAndOfPow2`, `branchOf`,
    /// `familyOf`, `famOpName`) and the constant payload queries
    /// (`constOf`, `isConstValue`) moved to cfg_lower_llir_control.zig.
    /// The inverse of a branch: a `(op, swap)` pair. Shared by the
    /// control emission (the inverted one-record form,
    /// `terminatorRecordCount`) and the linearization (the long-branch
    /// expansion in `llir_linearize.run`).
    pub const BranchInverse = llir_control.BranchInverse;
    pub fn invertBranch(op: llir.Opcode) ?BranchInverse {
        return llir_control.invertBranch(op);
    }

    /// Narrow a `u32` operand to its 7-bit field, recording an overflow
    /// on the Builder instead of truncating silently: `lowerLlir`
    /// checks `id_overflow` after linearization and fails with
    /// `error.IdOutOfRange`, so a too-large operand is a compile error,
    /// never a wrong (possibly valid-looking) instruction. On overflow
    /// the field stores 0, keeping the image obviously malformed even
    /// if it is inspected before the error propagates. The 7-bit fields
    /// carry registers (≤ 109 F cells, ≤ 0x7e T, ≤ 0x7f specials) and
    /// the inline dense IDs — an ID at or above 128 is the fixed
    /// `error.IdOutOfRange`, a register above 127 an internal overflow
    /// (`error.ProgramTooLarge`).
    pub fn fit7(self: *Builder, v: u32) u8 {
        if (v > 0x7f) {
            self.id_overflow = true;
            return 0;
        }
        return @intCast(v);
    }

    /// The 16-bit half of an I-format record — a dense side-table ID
    /// (ConstId, FunctionId, ModuleId, SyscallDescId, ConstructDescId,
    /// DestructureDescId, SwitchDescId, SlotId).
    /// An ID above `0xffff` overflows the field — recorded and failed
    /// with `error.ProgramTooLarge` at `lowerLlir`, never truncated.
    pub fn fit16(self: *Builder, v: u32) u16 {
        if (v > 0xffff) {
            self.operand_overflow = true;
            return 0;
        }
        return @intCast(v);
    }

    /// The signed 10-bit offset of a B-type branch from `pc` to
    /// `target`. An offset outside [-512, 511]
    /// overflows the field — but the long-branch expansion (Instruction
    /// long-branch expansion runs before this and expands every out-of-reach
    /// branch, so reaching the overflow here means the expansion missed
    /// a branch (a lowering bug); the flag still fails with
    /// `error.ProgramTooLarge` at `lowerLlir`, never truncated.
    pub fn fit10Signed(self: *Builder, target: u32, pc: u32) i16 {
        return llir.fit10Signed(target, pc) orelse blk: {
            self.operand_overflow = true;
            break :blk 0;
        };
    }

    /// The signed 20-bit offset of a `jal` from `pc` to `target`
    /// An offset outside ±2¹⁹ overflows the
    /// field — recorded and failed with `error.ProgramTooLarge` at
    /// `lowerLlir`, never truncated.
    pub fn fit20Signed(self: *Builder, target: u32, pc: u32) i32 {
        return llir.fit20Signed(target, pc) orelse blk: {
            self.operand_overflow = true;
            break :blk 0;
        };
    }

    /// Snapshot the Builder's tables into the frozen artifact. Interning
    /// fills the interning side tables; the remaining side tables come
    /// from their stages (call/syscall descs, construct/destructure/
    /// switch descs).
    fn finish(self: *Builder) llir.LlirProgram {
        return .{
            .instructions = self.instructions.items,
            .functions = self.func_descs.items,
            .blocks = self.block_descs.items,
            .self_symbol = self.self_symbol,
            .init = self.artifact_init,
            .entry_member = self.entry_member,
            .symbols = self.symbols.items,
            .imports = self.imports.items,
            .exports = self.exports.items,
            .module_slots = self.module_slots.items,
            .constants = self.constants.items,
            .types = self.types.items,
            .type_decls = self.type_decls.items,
            .type_decl_fields = self.type_decl_fields.items,
            .union_variants = self.union_variants.items,
            .union_payloads = self.union_payloads.items,
            .host_types = self.host_types.items,
            .signatures = self.signatures.items,
            .params = self.params.items,
            .call_args = self.call_args.items,
            .syscall_descs = self.syscall_descs.items,
            .construct_descs = self.construct_descs.items,
            .destructure_dsts = self.destructure_dsts.items,
            .destructure_dst_types = self.destructure_dst_types.items,
            .destructure_descs = self.destructure_descs.items,
            .switch_arms = self.switch_arms.items,
            .switch_descs = self.switch_descs.items,
            .member_descs = self.member_descs.items,
            .drop_descs = self.drop_descs.items,
            .strings = self.strings.items,
        };
    }
};
