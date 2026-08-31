//! Pass: the Stilla interpreter VM (docs/interpreter-vm.md).
//!
//! In:  a structurally validated LLIR image (`llir_validate.validate`)
//!      interpreted **in place** — no derived typed instruction stream
//!      and no per-PC execution plan (v9, spec §8.2).
//!      Out: execution — `Termination.normal` with the root's returned
//!      raw cell, or `Termination.panic` with an owned message.
//!
//! Representation contract (Runtime Specification §7.2,
//! docs/interpreter-vm.md §5): every cell is one raw `u64` — no inline
//! kind, no payload mask, no typed-zero tag. Scalar canonical forms:
//! `bool` exactly 0/1, `byte` high 56 bits zero, `int32`/`uint32`/
//! `float32` high 32 bits zero, full-width patterns for the later
//! `i64`/`u64`/`f64`. All scalar zeros share the single all-zero cell;
//! the type of a zero comes from the decoded opcode's rep and the
//! image's type records, never from the bits. Every transfer
//! (copy/move/borrow/spill/arg/ret) copies the complete raw cell.
//!
//! Frame contract (LLIR Specification §4.3): a fixed three-cell header
//! at `[fp - 3, fp)` decoded **by position** as `{ saved_fp, saved_fn,
//! saved_ra }`, each field range-checked before use
//! (`FrameHeader.check`).
//! `saved_fp` is the caller's frame base, restored directly by `ret`.
//! The root header carries the `invalid_pc` sentinel in both cells;
//! the two equal `0xffff_ffff` payloads are distinguished by field
//! position, never by cell bits. A load guarantees every executable pc
//! < `vm_internal_pc`, so the continuation sentinel never collides
//! with a program value.
//!
//! Scope: scalars and typed ops (per-opcode rep dispatch), control
//! flow, direct (`jal ra`) / indirect (`jalr`) calls — the static
//! `jal`'s callee index is resolved at load, the dynamic `jalr` target
//! by `enterJalr`, both entering through the failure-atomic
//! `enterCalleeId` — returns, self-tailcalls, traps, spills,
//! the stack limit, heap objects (str/list/box/struct/union/any/
//! opaque), string constants, the counted lifecycle
//! (release/copy_retain), destruction with drop-hook continuation, and
//! the host adapter (phase 6 — the required `builtin` interface; M2 —
//! `(specifier, member)` dispatch to the `math`/`string`/`list`
//! stdlib modules).
//!
//! Split into: `interpreter_types.zig` (shared records and the runtime
//! state `VmRuntimeState` — the value stack, the register file, the
//! execution position pc/sp/fp/current_fn, run status, and the
//! dispatch-chain out-of-band state),
//! `interpreter_loader.zig` (runtime module loading and the loaded data
//! — the loader functions and `VmLoadedData`: the decoded instruction
//! arena, the function registry, the loaded modules, and the root
//! identity), `interpreter_dispatch.zig` (per-opcode
//! handlers + comptime table **and the execution-layer helpers they
//! drive** — register access, trap plumbing, the call/return path, the
//! dispatch loop, and the numeric/compare/cast semantics all live
//! there), `interpreter_host.zig` (run API + host adapters); this file
//! keeps the `VmCtx` execution context: allocator, the loaded data
//! (`VmLoadedData`), the runtime state (`VmRuntimeState`), heap, host
//! adapters, teardown logs, and module orchestration.
//! White-box tests live in `interpreter_vm_tests.zig`.

const std = @import("std");
const testing = std.testing;
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const Value = vm_types.Value;
const ObjectHeader = vm_types.ObjectHeader;
const HeapErr = vm_types.HeapErr;

const interp_types = @import("interpreter_types.zig");
const interp_loader = @import("interpreter_loader.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const interp_host = @import("interpreter_host.zig");

// Shared types + host facade re-exported so the rest of the crate sees
// the same `interpreter.*` surface it always did. The load types live in
// `interpreter_loader.zig`; everything else in `interpreter_types.zig`.
pub const invalid_pc = interp_types.invalid_pc;
pub const vm_internal_pc = interp_types.vm_internal_pc;
pub const FrameHeader = interp_types.FrameHeader;
pub const FnEntry = interp_types.FnEntry;
pub const functionAtPc = interp_types.functionAtPc;
pub const ModuleState = interp_loader.ModuleState;
pub const ModuleLoader = interp_loader.ModuleLoader;
pub const LoadResult = interp_loader.LoadResult;
pub const LoadError = interp_loader.LoadError;
pub const RuntimeModule = interp_loader.RuntimeModule;
pub const readHeader = interp_types.readHeader;
pub const Termination = interp_types.Termination;
pub const RunError = interp_types.RunError;
pub const HostResult = interp_types.HostResult;
pub const Continuation = interp_types.Continuation;
pub const HostSignature = interp_types.HostSignature;
pub const HostType = interp_types.HostType;
pub const HostScratch = interp_types.HostScratch;
pub const HostResource = interp_types.HostResource;
pub const HostDisposer = interp_types.HostDisposer;
pub const DestroyWork = interp_types.DestroyWork;
pub const HostCall = interp_host.HostCall;
pub const defaultHostCall = interp_host.defaultHostCall;
pub const defaultHostRegistry = interp_host.defaultHostRegistry;
/// Typed host-binding layer (docs/host-bindings.md): `bind`/`bindC`/
/// `raw`/`hostModule`/`HostRegistry`.
pub const host_bind = @import("host_bind.zig");
pub const run = interp_host.run;
pub const runWithHost = interp_host.runWithHost;
pub const runWithEntry = interp_host.runWithEntry;
pub const runWithEntryAndLoader = interp_host.runWithEntryAndLoader;
pub const runWithHostAndLoader = interp_host.runWithHostAndLoader;
pub const runValidated = interp_host.runValidated;
pub const runValidatedWithEntry = interp_host.runValidatedWithEntry;

/// The execution context (docs/interpreter-vm.md §4): the fixed
/// configuration plus the loaded data plus the runtime state. The
/// configuration is the allocator, the module-loading provider, the
/// host adapter, and the stack limit; the loaded data (`VmLoadedData` —
/// the decoded image, loaded modules, root identity) is what the loader
/// produces; the runtime state (`VmRuntimeState` — the value stack,
/// register file, pc/sp/fp, run status, dispatch-chain out-of-band
/// state, and every per-run execution resource: the heap, the
/// host-resource and string-constant registries, the destruction-work
/// and continuation stacks, the slot-teardown log, the host argument
/// buffer, the panic scratch buffer) is everything that changes with the
/// run. The dispatch
/// and host-execution layers take `*VmCtx`; loading
/// and publication stay in `interpreter_loader.zig`, which `VmCtx` never
/// performs itself.
pub const VmCtx = struct {
    allocator: std.mem.Allocator,
    /// The `ModuleLoader` provider callback: how execution obtains more
    /// code at runtime. Runtime `module_ref`/`load_member` resolution
    /// (`resolveImport`) can lazily load a module during execution, so
    /// the provider is an execution dependency; the publication
    /// algorithms themselves stay in `interpreter_loader.zig`.
    provider: ModuleLoader = .{},
    /// The loaded data (`VmLoadedData`): the decoded instruction arena,
    /// the function registry, the loaded modules (including registered
    /// host modules), and the root identity — what the loader produces
    /// and execution reads (docs/interpreter-vm.md §8). Lazy loading
    /// and hot-reload mutate it during a run; the loader functions in
    /// `interpreter_loader.zig` own the publication side.
    loaded: interp_loader.VmLoadedData = .{},
    /// The runtime state (`VmRuntimeState`): the value stack, the fast
    /// register bank, the execution position pc/sp/fp/current_fn, run
    /// status, the dispatch-chain out-of-band state, and every per-run
    /// execution resource (the heap, the host-resource and
    /// string-constant registries, the destruction-work and
    /// continuation stacks, the slot-teardown log, the host argument
    /// buffer, the panic scratch buffer) — where execution is
    /// (docs/interpreter-vm.md §4, §8). Execution reads and mutates it;
    /// the loader only reads `running`/`terminated` for the
    /// `reloadModule` quiesce check.
    runtime: interp_types.VmRuntimeState,
    /// Hard cell limit; exceeding it is a deterministic trap.
    stack_limit: u32 = 1 << 20,

    /// Host-binding dispatch (phase 6): the default adapter implements
    /// the required `builtin` interface; an embedding replaces it to
    /// provide its own host modules.
    host: HostCall = .{},

    /// The default constructor: an empty context (no provider installed).
    pub fn init(allocator: std.mem.Allocator) VmCtx {
        return .{ .allocator = allocator, .runtime = .{ .heap = .{ .allocator = allocator } } };
    }

    pub fn deinit(self: *VmCtx) void {
        // The runtime state owns every per-run resource (heap, the
        // registries, the work/continuation stacks, the teardown log,
        // the host argument buffer, the value stack); the loaded data
        // owns the decoded image, the loaded modules, and the registry.
        // Both are freed here.
        self.runtime.deinit(self.allocator);
        self.loaded.deinit(self.allocator);
    }

    // --- module accessors --------------------------------------------------

    /// The current runtime module's registry index.
    pub inline fn curModIdx(self: *const VmCtx) u32 {
        return self.loaded.funcs.items[self.runtime.current_fn].mod;
    }

    /// The current module.
    pub inline fn curMod(self: *const VmCtx) *const RuntimeModule {
        return self.loaded.curMod(self.curModIdx());
    }

    /// The current module's artifact — the metadata authority for the
    /// executing code's signatures, types, and descriptors.
    pub inline fn curImage(self: *const VmCtx) *const llir.LlirProgram {
        return self.loaded.curImage(self.curModIdx());
    }

    /// The type table of the module that declared `type_id`.
    /// The canonical shared-metadata image for type-table
    /// interpretation (types/params/signatures are seeded identically
    /// into every artifact of one compilation). The root module's
    /// artifact works even outside any frame (teardown); tests that
    /// hand-build a VM set `loader.loaded.meta_image` directly.
    pub fn metaImage(self: *const VmCtx) *const llir.LlirProgram {
        if (self.loaded.root_module < self.loaded.modules.items.len) return self.loaded.curImage(self.loaded.root_module);
        if (self.loaded.meta_image) |img| return img;
        return self.curImage();
    }

    // --- host-resource registry (minimal phase-3 API; phase 6 wires
    // --- the signature-driven adapter) ------------------------------

    /// Register a host-owned payload entering VM ownership. A duplicate
    /// registration of the same un-released payload traps before commit.
    pub fn registerHostResource(self: *VmCtx, host_type_id: u32, payload: u64, disposer: HostDisposer, user: ?*anyopaque) !void {
        if (self.runtime.host_resources.contains(payload)) return error.DuplicateHostResource;
        try self.runtime.host_resources.put(self.allocator, payload, .{
            .host_type_id = host_type_id,
            .disposer = disposer,
            .user = user,
        });
    }

    /// Transfer a registered payload back out of VM ownership.
    pub fn takeHostResource(self: *VmCtx, payload: u64) ?HostResource {
        if (self.runtime.host_resources.fetchRemove(payload)) |kv| return kv.value;
        return null;
    }

    /// True when the payload is currently registered.
    pub fn isHostResourceRegistered(self: *VmCtx, payload: u64) bool {
        return self.runtime.host_resources.contains(payload);
    }

    // ------------------------------------------------------------------
    // Module loading (Runtime §2): atomic publication, load-once
    // identity, cycle detection. The publication machinery, the
    // registry, and the loaded data live in `interpreter_loader.zig`
    // (`VmLoadedData` + the loader functions); execution code drives them
    // through `self.loaded` and never loads or publishes itself.
    // ------------------------------------------------------------------

    /// The registry index of the module named by symbol id `sym_id`
    /// (interpreted through the executing module's symbol table),
    /// loading it eagerly when first needed. The module's own symbol
    /// resolves to itself.
    pub fn resolveModuleRef(self: *VmCtx, sym_id: u32) !u32 {
        const bytes = self.curMod().symbolBytes(sym_id) orelse return error.InvalidImage;
        if (self.loaded.module_by_symbol.get(bytes)) |mi| return mi;
        return interp_loader.loadModule(&self.loaded, self.allocator, &self.provider, bytes) catch |e| switch (e) {
            error.ModuleNotFound, error.InvalidArtifact, error.LoaderCycle, error.ContextRunning => return error.InvalidImage,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// One import resolution (Runtime §2.6): load/initialize the target
    /// module, then resolve its sorted export row. Cached per import
    /// index in the importing module. `require_public` distinguishes a
    /// member load (only declared members resolve) from a function
    /// reference (every function symbol, including lowered private
    /// specializations, resolves).
    pub fn resolveImport(self: *VmCtx, mi: u32, imp_i: u32, require_public: bool) !ResolvedImport {
        const m = self.loaded.modules.items[mi];
        if (imp_i >= m.import_cache.len) return error.InvalidImage;
        if (m.import_cache[imp_i]) |v| return .{ .val = v, .started_init = false };
        const imp = m.image.imports[imp_i];
        const mod_bytes = m.symbolBytes(imp.module_sym) orelse return error.InvalidImage;
        const member_bytes = m.symbolBytes(imp.member_sym) orelse return error.InvalidImage;
        const tmi = blk: {
            if (self.loaded.module_by_symbol.get(mod_bytes)) |x| break :blk x;
            break :blk interp_loader.loadModule(&self.loaded, self.allocator, &self.provider, mod_bytes) catch |e| switch (e) {
                error.ModuleNotFound, error.InvalidArtifact, error.LoaderCycle, error.ContextRunning => return error.InvalidImage,
                error.OutOfMemory => return error.OutOfMemory,
            };
        };
        const t = self.loaded.modules.items[tmi];
        if (t.is_host) {
            // Host modules have no Stilla members to resolve as values.
            return error.InvalidImage;
        }
        // Loading does not initialize; a member load does — except for
        // the module's own symbol, which resolves to itself: during its
        // own init the slots are already being filled in declaration
        // order (each `store_member` precedes the reads that use it),
        // and after init they are final, so a self reference needs no
        // initialization step and must not trap as an init cycle.
        var started_init = false;
        if (tmi != mi) {
            started_init = try self.ensureModule(tmi);
        }
        const row = t.findExport(member_bytes) orelse return error.InvalidImage;
        // A function reference resolves every function symbol, including
        // lowered private specializations (is_empty.2); only a non-public
        // *non-function* export is barred from a public member load.
        if (require_public and row.public == 0 and row.kind != .function) return error.InvalidImage;
        const v: u64 = switch (row.kind) {
            .function => self.loaded.funcs.items[t.func_base + row.ref].desc.entry_pc,
            .const_slot => if (row.ref == llir.no_index) 0 else t.slots[row.ref],
            .nested_module => blk2: {
                const nested_bytes = t.symbolBytes(row.ref) orelse return error.InvalidImage;
                const nmi = blk3: {
                    if (self.loaded.module_by_symbol.get(nested_bytes)) |x| break :blk3 x;
                    break :blk3 interp_loader.loadModule(&self.loaded, self.allocator, &self.provider, nested_bytes) catch |e| switch (e) {
                        error.ModuleNotFound, error.InvalidArtifact, error.LoaderCycle, error.ContextRunning => return error.InvalidImage,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                };
                if (nmi != mi) started_init = try self.ensureModule(nmi);
                break :blk2 nmi;
            },
            .host_binding => return error.InvalidImage, // not a first-class value
        };
        // Starting the target's initializer defers this resolution: the
        // value read now is pre-initialization and must not enter the
        // cache (the instruction re-executes after the init completes
        // and resolves fresh).
        if (started_init) return .{ .val = 0, .started_init = true };
        m.import_cache[imp_i] = v;
        return .{ .val = v, .started_init = false };
    }

    /// The result of one import resolution: the resolved value (a
    /// function pc, constant slot, or nested module handle) and whether
    /// resolving it started a module initializer (the caller must return
    /// before the default pc advance, since `ensureModule` moved pc).
    const ResolvedImport = struct { val: u64, started_init: bool };

    // ------------------------------------------------------------------
    // Setup and the execution frame
    // ------------------------------------------------------------------

    /// Install the root frame for the function at registry index
    /// `entry_fn` (docs/interpreter-vm.md §7): the fixed three-cell
    /// header at `[0, 3)` carries `invalid_pc` in all three cells. The
    /// standalone entry contract is a parameterless function.
    fn installRootFrame(self: *VmCtx, entry_fn: u32) !void {
        const f = self.loaded.funcs.items[entry_fn].desc;
        if (self.loaded.funcs.items[entry_fn].arity.params != 0) return error.InvalidImage;
        self.runtime.running = true;
        // The host scratch grows with demand (syscall dispatch).
        var max_args: usize = 0;
        for (self.curImage().syscall_descs) |d| max_args = @max(max_args, d.args_len);
        if (max_args > self.runtime.host_scratch.values.items.len) {
            try self.runtime.host_scratch.values.resize(self.allocator, max_args);
        }
        const fp: u32 = 3;
        const end: usize = llir.frameEnd(fp, f);
        try self.ensure(end);
        @memset(self.runtime.stack.items[0..end], 0);
        self.runtime.stack.items[0] = invalid_pc;
        self.runtime.stack.items[1] = invalid_pc;
        self.runtime.stack.items[2] = invalid_pc;
        self.runtime.fp = fp;
        self.runtime.sp = @intCast(end);
        self.runtime.pc = f.entry_pc;
        self.runtime.current_fn = entry_fn;
    }

    /// Publish a borrowed artifact as the root module (no provider
    /// round-trip) and set the core's root identity, then install the
    /// root frame for its local `FunctionId` entry (the single-artifact
    /// API). The artifact must already be structurally valid.
    pub fn setupRootArtifact(self: *VmCtx, image: *llir.LlirProgram, entry: llir.FunctionId) !void {
        if (self.runtime.running or self.runtime.terminated) return error.ContextAlreadyRun;
        if (entry >= image.functions.len) return error.InvalidImage;
        if (self.loaded.module_by_symbol.get(image.strings[0..0]) != null) return error.ContextAlreadyRun;
        const mi = try interp_loader.publishRoot(&self.loaded, self.allocator, image);
        errdefer interp_loader.abortLoad(&self.loaded, self.allocator);
        const entry_global = self.loaded.modules.items[mi].func_base + entry;
        try self.installRootFrame(entry_global);
        // Root modules initialize eagerly (Runtime §3.3).
        _ = try self.ensureModule(mi);
    }

    /// The full symbolic path (Runtime §3.3): resolve and validate the
    /// artifact's entry export as a parameterless function through the
    /// same resolver, then enter its function pc.
    pub fn setupRootSymbolic(self: *VmCtx, image: *llir.LlirProgram) !void {
        if (self.runtime.running or self.runtime.terminated) return error.ContextAlreadyRun;
        if (image.entry_member == llir.no_index) return error.InvalidImage;
        const mi = try interp_loader.publishRoot(&self.loaded, self.allocator, image);
        errdefer interp_loader.abortLoad(&self.loaded, self.allocator);
        const m = self.loaded.modules.items[mi];
        // Resolve the entry export through the same resolver.
        const bytes = m.symbolBytes(image.entry_member) orelse return error.InvalidImage;
        const row = m.findExport(bytes) orelse {
            return error.InvalidImage;
        };
        if (row.public == 0 or row.kind != .function) {
            return error.InvalidImage;
        }
        const entry_global = m.func_base + row.ref;
        try self.installRootFrame(entry_global);
        // Root modules initialize eagerly (Runtime §3.3).
        _ = try self.ensureModule(mi);
    }

    /// Hot-reload one loaded module through this context's provider
    /// (interpreter_loader.zig): re-fetch/parse/validate/decode the
    /// module's artifact and atomically repoint `module_by_symbol` at the
    /// fresh version, returning its new registry index. Refused while the
    /// VM is executing (quiesce contract — the caller drains first); on
    /// failure the old module is untouched. The embedding observes the
    /// new slot through `core.module_by_symbol`.
    pub fn reloadModule(self: *VmCtx, symbol: []const u8) LoadError!u32 {
        return interp_loader.reloadModule(&self.loaded, &self.runtime, self.allocator, &self.provider, symbol);
    }

    pub fn hookActive(self: *const VmCtx) bool {
        return self.runtime.continuations.items.len != 0 and self.runtime.continuations.items[self.runtime.continuations.items.len - 1].kind == .hook;
    }
    /// on return.
    /// Initialize a loaded module exactly once (Runtime §2.3):
    /// initializing/`loading` states are cycle traps; a module without
    /// an `@init` initializes trivially. The initializer runs with a
    /// `vm_internal_pc` continuation that marks the module initialized
    /// when it returns. Returns whether an initializer was started
    /// (pc moved to the initializer's entry); callers that started one
    /// must return before the default pc advance.
    pub fn ensureModule(self: *VmCtx, module_id: u32) !bool {
        const m = self.loaded.modules.items[module_id];
        switch (m.state) {
            .initialized => return false,
            .initializing, .loading => return error.InvalidImage, // init/load cycle
            .loaded => {},
        }
        m.state = .initializing;
        const init_fn = if (m.is_host) llir.no_index else m.image.init;
        if (init_fn == llir.no_index) {
            m.state = .initialized;
            return false;
        }
        const fe = self.loaded.funcs.items[m.func_base + init_fn];
        const new_fp = self.runtime.sp + 3;
        const end: usize = llir.frameEnd(new_fp, fe.desc);
        try self.ensure(end);
        self.runtime.stack.items[new_fp - 3] = self.runtime.fp;
        self.runtime.stack.items[new_fp - 2] = self.runtime.current_fn;
        self.runtime.stack.items[new_fp - 1] = vm_internal_pc;
        try self.runtime.continuations.append(self.allocator, .{
            .resume_pc = self.runtime.pc,
            .kind = .{ .module = module_id },
        });
        self.runtime.fp = new_fp;
        self.runtime.sp = @intCast(end);
        self.runtime.pc = fe.desc.entry_pc;
        self.runtime.current_fn = m.func_base + init_fn;
        return true;
    }

    /// Grow the stack so index `need` is valid; deterministic trap on
    /// exceeding the configured limit. Failure leaves nothing partial.
    pub fn ensure(self: *VmCtx, need: usize) !void {
        if (need >= self.stack_limit) return error.StackOverflow;
        if (need >= self.runtime.stack.items.len) {
            try self.runtime.stack.resize(self.allocator, need + 1);
        }
    }

    // -----------------------------------------------------------------
    // Heap core: provenance dereference, retain, destroy. Allocation
    // (`allocObject`/`freeShell`) and `deref`/`strSliceOf` live in
    // `VmHeap` (vm_types.zig); this section keeps the typed lifecycle
    // and destruction machinery that also needs the image.
    // -----------------------------------------------------------------

    /// Expand one doomed object into destructor work items (children in
    /// reverse destruction order, then the shell). A struct's user drop
    /// hook runs first, while all fields remain valid: destruction of
    /// that object pauses until the hook's frame returns.
    fn expandDestruction(self: *VmCtx, type_id: u32, h: *ObjectHeader) !void {
        const image = self.metaImage();
        switch (h.kind) {
            .str_ => {}, // bytes die with the shell
            .list_cons => {
                const row = image.types[h.type_id];
                const elem_ty = row.a;
                const head = h.cell(0);
                const nxt = h.cell(1);
                var items: [2]DestroyWork = undefined;
                var n: usize = 0;
                if (nxt != 0) {
                    items[n] = .{ .value = .{ .type_id = type_id, .addr = nxt } };
                    n += 1;
                }
                if (head != 0) {
                    items[n] = .{ .value = .{ .type_id = elem_ty, .addr = head } };
                    n += 1;
                }
                for (items[0..n]) |it| try self.runtime.destroy_work.append(self.allocator, it);
            },
            .box_ => {
                const elem_ty = image.types[type_id].a;
                const v = h.cell(0);
                if (v != 0) try self.runtime.destroy_work.append(self.allocator, .{ .value = .{ .type_id = elem_ty, .addr = v } });
            },
            .tuple_ => {
                const row = image.types[type_id];
                // The tuple row's range is `{ a = start, b = len }`
                // into `types` — the element count is `b`, not
                // `b - a` (the range start is a table offset).
                var k = row.b;
                while (k > 0) {
                    k -= 1;
                    const v = h.cell(k);
                    if (v != 0) try self.runtime.destroy_work.append(self.allocator, .{ .value = .{ .type_id = row.a + k, .addr = v } });
                }
            },
            .struct_ => {
                const row = image.types[type_id];
                const decl = image.type_decls[row.a];
                if (decl.b != llir.no_index and !h.track.UniqueValue) {
                    // Hook first, fields still valid; resume afterwards.
                    // The hook's parameter receives the doomed object's
                    // address (startHookCall writes it into F0).
                    h.track.UniqueValue = true;
                    try self.runtime.destroy_work.append(self.allocator, .{ .resume_struct = .{ .type_id = type_id, .h = h } });
                    try self.startHookCall(decl.b, @intFromPtr(h));
                    return;
                }
                var k = decl.d;
                while (k > decl.c) {
                    k -= 1;
                    const ft = image.type_decl_fields[k];
                    if (ft == llir.no_index) continue;
                    const v = h.cell(k - decl.c);
                    if (v != 0) try self.runtime.destroy_work.append(self.allocator, .{ .value = .{ .type_id = ft, .addr = v } });
                }
            },
            .union_ => {
                const row = image.types[type_id];
                const decl = image.type_decls[row.a];
                const tag: u32 = @truncate(h.cell(0));
                if (tag < decl.c) {
                    const v = image.union_variants[decl.b + tag];
                    var k = v.payloads_len;
                    while (k > 0) {
                        k -= 1;
                        const pt = image.union_payloads[v.payloads_start + k];
                        const pv = h.cell(1 + k);
                        if (pv != 0 and pt != llir.no_index) {
                            try self.runtime.destroy_work.append(self.allocator, .{ .value = .{ .type_id = pt, .addr = pv } });
                        }
                    }
                }
            },
            .any_ => {
                const pt: u32 = @truncate(h.cell(0));
                const pv = h.cell(1);
                if (pv != 0 and pt != llir.no_index) {
                    try self.runtime.destroy_work.append(self.allocator, .{ .value = .{ .type_id = pt, .addr = pv } });
                }
            },
            .opaque_ => {
                // Host-owned: dispose through the resource registry.
                const addr = @intFromPtr(h);
                if (self.runtime.host_resources.fetchRemove(addr)) |kv| {
                    kv.value.disposer(kv.value.user, addr);
                }
            },
        }
    }

    /// Initiate a runtime-initiated call to a struct drop hook
    /// (docs/interpreter-vm.md §7.1): ordinary frame convention with a
    /// `vm_internal_pc` return; the run loop resumes destruction when
    /// the hook's frame returns.
    ///
    /// The hook frame is placed **above** `sp` (like `ensureModule`),
    /// never at `sp - p`: the interrupted frame may be the root frame
    /// at the top of the stack, where the value-area overlap would
    /// land the header inside (or below) the root frame's cells and
    /// corrupt it. The doomed object's address is written into the
    /// hook's parameter cells (`F0..F(P-1)`), which were previously
    /// uninitialized.
    fn startHookCall(self: *VmCtx, hook_fn: u32, doomed: Value) !void {
        const image = self.curImage();
        const callee = image.functions[hook_fn];
        const p: u32 = self.loaded.funcs.items[self.curMod().func_base + hook_fn].arity.params;
        const new_fp = self.runtime.sp + 3;
        const end: usize = llir.frameEnd(new_fp, callee);
        try self.ensure(end);
        const hb = new_fp - 3;
        self.runtime.stack.items[hb + 0] = self.runtime.fp; // the interrupted frame's base
        self.runtime.stack.items[hb + 1] = self.runtime.current_fn;
        self.runtime.stack.items[hb + 2] = vm_internal_pc;
        for (0..p) |k| self.runtime.stack.items[new_fp + k] = doomed; // the hook's parameter
        try self.runtime.continuations.append(self.allocator, .{
            .resume_pc = self.runtime.pc,
            .kind = .hook,
        });
        self.runtime.fp = new_fp;
        self.runtime.sp = @intCast(end);
        self.runtime.pc = self.loaded.funcs.items[self.curMod().func_base + hook_fn].desc.entry_pc;
        self.runtime.current_fn = self.curMod().func_base + hook_fn;
    }

    /// Termination cleanup (docs/interpreter-vm.md §6.4, §10): release the
    /// loader-owned string references, dispose every registered host
    /// resource exactly once, then raw-free whatever still lives on the
    /// heap — no Stilla hooks run here. Counts end at zero on every path.
    pub fn finishCleanup(self: *VmCtx) void {
        var sit = self.runtime.string_consts.valueIterator();
        while (sit.next()) |v| {
            if (self.runtime.heap.registry.get(v.*)) |h| {
                if (h.track.CopyValue > 0) h.track.CopyValue -= 1; // loader-owned str reference
            }
        }
        self.runtime.string_consts.clearRetainingCapacity();
        self.drainDestroyWork() catch {};
        // Registered host resources are disposed exactly once each.
        while (self.runtime.host_resources.count() > 0) {
            var it = self.runtime.host_resources.iterator();
            const kv = it.next().?;
            const payload = kv.key_ptr.*;
            kv.value_ptr.disposer(kv.value_ptr.user, payload);
            _ = self.runtime.host_resources.remove(payload);
        }
        while (self.runtime.heap.registry.count() > 0) {
            var it = self.runtime.heap.registry.iterator();
            const kv = it.next().?;
            self.runtime.heap.freeShell(kv.value_ptr.*);
        }
        self.runtime.destroy_work.clearRetainingCapacity();
    }

    /// Drain the destruction work stack. While a user drop hook runs,
    /// the drain pauses (the run loop re-enters after its frame
    /// returns).
    pub fn drainDestroyWork(self: *VmCtx) HeapErr!void {
        while (!self.hookActive()) {
            const item = self.runtime.destroy_work.pop() orelse return;
            switch (item) {
                .free_obj => |h| self.runtime.heap.freeShell(h),
                .resume_struct => |w| {
                    // The hook finished: expand fields + shell now.
                    if (self.runtime.heap.registry.get(@intFromPtr(w.h)) == null) continue;
                    w.h.track.UniqueValue = true;
                    try self.expandDestruction(w.type_id, w.h);
                    self.runtime.heap.freeShell(w.h);
                    try self.drainDestroyWork();
                    return;
                },
                .value => |w| {
                    if (w.addr == 0) continue;
                    const h = self.runtime.heap.registry.get(w.addr) orelse continue; // synthetic or already freed
                    // Counted shells only die at rc 0.
                    if (h.isCounted() and h.track.CopyValue > 0) continue;
                    try self.expandDestruction(w.type_id, h);
                    if (self.hookActive()) {
                        // Shell frees when the resumed expansion finishes.
                        try self.runtime.destroy_work.append(self.allocator, .{ .free_obj = h });
                    } else {
                        self.runtime.heap.freeShell(h);
                        try self.drainDestroyWork();
                        return;
                    }
                },
            }
        }
    }

    /// Teardown in reverse initialization order (Runtime §2.5): each
    /// module's destruction log is popped in reverse — the stored value
    /// is released and the slot cleared — then the next module.
    pub fn teardownModules(self: *VmCtx) HeapErr!void {
        var mi = self.loaded.modules.items.len;
        while (mi > 0) {
            mi -= 1;
            const m = self.loaded.modules.items[mi];
            while (m.slot_log.pop()) |slot| {
                const slot_ty = m.image.module_slots[slot].type_;
                const v = m.slots[slot];
                m.slots[slot] = 0;
                if (v != 0) try vm_dispatch.destroyValue(self, slot_ty, v);
            }
        }
        try self.drainDestroyWork();
    }
};
