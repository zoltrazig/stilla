//! Runtime module loading for the Stilla interpreter (Runtime
//! Specification §2; docs/interpreter-vm.md §8, §11): the loader
//! contract, the eager per-module load path, and the run image it
//! produces.
//!
//! Split off `interpreter.zig` so that "load a module" has one home that
//! produces a runnable image, and the VM itself never loads or publishes.
//! This file owns:
//!
//! - the public load types (`ModuleState`, `ModuleLoader`, `LoadResult`,
//!   `LoadError`, `RuntimeModule`, `imageSelfSymbol`) — moved from
//!   `interpreter_types.zig`;
//! - `VmCore` — the minimal, self-contained run image: the decoded
//!   instruction arena, the relocated function registry, the loaded
//!   modules (one replaceable slot per canonical symbol), and the root
//!   identity. Pure data; the execution code in `interpreter.zig` reads
//!   it but never mutates publication state;
//! - the loader functions — `loadModule` (fetch → parse → validate →
//!   decode → publish atomically, with rollback of failed loads),
//!   `publishRoot`, `publishArtifact`, and `abortLoad`. Each takes an
//!   explicit `core: *VmCore` (and, for `loadModule`, the provider
//!   callback); `VmCtx` (interpreter.zig) carries the core and provider
//!   and calls them. Hot-reload is designed for (append-only arenas keep
//!   superseded versions resident; `module_by_symbol` can be repointed
//!   at a fresh slot), but the reload entry point is a later change.
//!
//! No `Vm`/`VmCtx` dependency: this file imports only `llir.zig`,
//! `vm_types.zig`, `vm_instr.zig`, the binary/validate passes, and
//! `interpreter_types.zig`.

const std = @import("std");
const llir = @import("llir.zig");
const vm_instr = @import("vm_instr.zig");
const vm_types = @import("vm_types.zig");
const llir_emit_bin = @import("passes/llir_emit_bin.zig");
const validate = @import("passes/llir_validate.zig");
const interp_types = @import("interpreter_types.zig");
const FnEntry = interp_types.FnEntry;
const Termination = interp_types.Termination;
const RunError = interp_types.RunError;
const VmInstr = vm_instr.VmInstr;
const Value = vm_types.Value;

// ---------------------------------------------------------------------------
// Runtime modules (Runtime Specification §2): load-once identity,
// atomic publication, initialize-once, reverse-order teardown.
// ---------------------------------------------------------------------------

/// The lifecycle state of one loaded module.
pub const ModuleState = enum {
    /// A provisional, non-executable registry entry used for cycle
    /// detection while the artifact loads.
    loading,
    /// Published: code, metadata, and caches are complete and stable.
    loaded,
    /// Its initializer is currently running (cycle detection).
    initializing,
    /// Constants initialized; ready for member resolution.
    initialized,
};

/// The loader callback (Runtime §2.6): given a canonical module symbol
/// and the VM allocator, returns either allocator-owned LLIR artifact
/// bytes (the VM frees them after parsing) or a registered host module
/// descriptor. Exactly one provider may exist per symbol.
pub const ModuleLoader = struct {
    userdata: ?*const anyopaque = null,
    load: *const fn (userdata: ?*const anyopaque, allocator: std.mem.Allocator, symbol: []const u8, out: *LoadResult) LoadError!void = defaultLoader,
};

/// What a loader produced for one symbol.
pub const LoadResult = union(enum) {
    /// None: no provider registered for the symbol.
    not_found,
    /// Allocator-owned artifact bytes; the VM frees them after parsing.
    bytes: []const u8,
    /// A registered host module (ready after registration; no Stilla
    /// initializer, no artifact).
    host,
};

pub const LoadError = error{ OutOfMemory, ModuleNotFound, InvalidArtifact, LoaderCycle, ContextRunning };

/// The bytes of an artifact's own module symbol (its header fields are
/// byte ranges into its strings blob).
pub fn imageSelfSymbol(image: *const llir.LlirProgram) []const u8 {
    if (image.self_symbol >= image.symbols.len) return "";
    const r = image.symbols[image.self_symbol];
    if (r.start > image.strings.len or r.len > image.strings.len - r.start) return "";
    return image.strings[r.start..][0..r.len];
}

fn defaultLoader(_: ?*const anyopaque, _: std.mem.Allocator, _: []const u8, out: *LoadResult) LoadError!void {
    out.* = .not_found;
}

/// One loaded runtime module: its identity, published code range,
/// artifact, relocated functions, constant slots, resolved-member
/// cache, and initialization bookkeeping (Runtime §2).
pub const RuntimeModule = struct {
    /// The canonical module symbol (byte-exact identity).
    symbol: []const u8,
    state: ModuleState,
    /// The parsed artifact (owned by the VM's allocator or borrowed
    /// from the caller for the root — immutable after publication).
    image: *llir.LlirProgram,
    /// The base pc of this module's decoded instructions in the VM
    /// code arena, and its instruction count. Append-only: never
    /// relocated or unloaded for the run.
    code_base: u32,
    code_len: u32,
    /// Index of this module's first function in the VM function
    /// registry (its local `FunctionId i` is registry slot
    /// `func_base + i`).
    func_base: u32,
    /// Whether the VM owns the parsed artifact (freed on deinit).
    owned_image: bool,
    /// Constant-slot storage (Runtime §2.2).
    slots: []Value,
    /// Resolved-member cache, parallel to the artifact's `imports`
    /// table; null = not yet resolved.
    import_cache: []?u64,
    /// True when this module is a registered host module (no artifact
    /// execution, no initializer).
    is_host: bool,

    /// The bytes of the symbol `id` (caller range-checks).
    pub fn symbolBytes(self: *const RuntimeModule, id: u32) ?[]const u8 {
        if (id >= self.image.symbols.len) return null;
        const r = self.image.symbols[id];
        if (r.start > self.image.strings.len or r.len > self.image.strings.len - r.start) return null;
        return self.image.strings[r.start..][0..r.len];
    }

    /// The export row for the byte-exact member name, binary search
    /// over the sorted table, or null.
    pub fn findExport(self: *const RuntimeModule, name: []const u8) ?llir.ExportDesc {
        var lo: usize = 0;
        var hi: usize = self.image.exports.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const nm = self.symbolBytes(self.image.exports[mid].member_sym) orelse return null;
            switch (std.mem.order(u8, nm, name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.image.exports[mid],
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// VmCore: the run context the loader produces (docs/interpreter-vm.md §8).
// The decoded image, loaded modules, root identity — plus the runtime
// state: the value stack, the register file, the execution position
// (pc/sp/fp/current_fn), run status, and the dispatch-chain out-of-band
// state. Execution code reads and mutates it; only the loader functions
// mutate the publication side.
// ---------------------------------------------------------------------------

pub const VmCore = struct {
    /// The append-only decoded instruction image (docs/interpreter-vm.md
    /// §1): one `VmInstr` per artifact instruction, in artifact order,
    /// relocated by each module's `code_base`. Published modules are
    /// cached and never relocated or unloaded, so pcs stay stable.
    code: std.ArrayList(VmInstr) = .empty,
    /// The function registry: every loaded module's relocated
    /// `FunctionDesc`s, appended at load.
    funcs: std.ArrayList(FnEntry) = .empty,
    /// The loaded runtime modules, in load order. One replaceable slot
    /// per canonical symbol — the hot-reload hook repoints
    /// `module_by_symbol` at a freshly published version.
    modules: std.ArrayList(*RuntimeModule) = .empty,
    /// Canonical module symbol → current registry index.
    module_by_symbol: std.StringHashMapUnmanaged(u32) = .empty,
    /// The canonical symbol of the root module.
    root_symbol: []const u8 = "",
    /// The root module's registry index (set by root publication).
    root_module: u32 = 0,
    /// Fallback canonical-metadata image for hand-built test VMs.
    meta_image: ?*llir.LlirProgram = null,

    // --- runtime state (the execution position, register file, run
    // --- status, and dispatch-chain out-of-band state) — the core is
    // --- the run context: the image plus where execution is. -----------

    /// The value stack: dynamic cells, hard-capped by `VmCtx.stack_limit`.
    stack: std.ArrayList(Value) = .empty,
    /// The directly-indexed fast bank: `zero` at index 0 (kept
    /// permanently all-zero — writes to `zero` drop), `cond` at index
    /// 1, `ra` at index 2 (a reserved call-convention hole — never a
    /// scratch cell), T0–T15 at indexes 3–18 (Instruction Set §3.1.1).
    /// A register read below `frame_base` is one bounds check and one
    /// indexed load.
    fast_regs: [llir.fast_reg_count]Value = .{0} ** llir.fast_reg_count,
    /// Execution position: the executing pc (an index into `code`), the
    /// stack pointer, the current frame base, and the executing
    /// function's registry index.
    pc: u32 = 0,
    sp: u32 = 0,
    fp: u32 = 0,
    current_fn: llir.FunctionId = 0,
    running: bool = false,
    terminated: bool = false,
    /// Threaded-dispatch out-of-band state (docs/interpreter-vm.md §7):
    /// handler functions return `void`; terminations, errors, and the
    /// hook-resume flag travel here instead of through call/return
    /// values.
    result: ?Termination = null,
    pending_err: ?RunError = null,
    /// Set by `returnFrom` when a drop-hook continuation resumed: the
    /// `ret` handler stops the chain so the run loop re-drives from the
    /// restored pc (a resumed hook's drain may have armed a new one).
    popped_hook_cont: bool = false,

    pub fn deinit(self: *VmCore, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.funcs.deinit(allocator);
        self.stack.deinit(allocator);
        for (self.modules.items) |m| {
            if (m.owned_image) {
                llir_emit_bin.freeImage(allocator, m.image);
                allocator.destroy(m.image);
            }
            allocator.free(m.symbol);
            allocator.free(m.slots);
            allocator.free(m.import_cache);
            allocator.destroy(m);
        }
        self.modules.deinit(allocator);
        self.module_by_symbol.deinit(allocator);
    }

    /// The module at registry index `i`.
    pub inline fn curMod(self: *const VmCore, i: u32) *const RuntimeModule {
        return self.modules.items[i];
    }

    /// The artifact of the module at registry index `i`.
    pub inline fn curImage(self: *const VmCore, i: u32) *const llir.LlirProgram {
        return self.modules.items[i].image;
    }

    /// The unique function containing `pc` across every loaded module's
    /// relocated code ranges, or null (binary search over the sorted
    /// registry — see `interpreter_types.functionAtPc`).
    pub fn functionAtPc(self: *const VmCore, pc: u32) ?u32 {
        return interp_types.functionAtPc(self.funcs.items, pc);
    }
};

// ---------------------------------------------------------------------------
// Loader functions: the machinery that generates and maintains a `VmCore`
// (docs/interpreter-vm.md §11). Stateless — each function takes the core it
// operates on (and, for `loadModule`, the provider callback). `VmCtx`
// (interpreter.zig) owns the `VmCore` and the `ModuleLoader` provider and
// calls these.
// ---------------------------------------------------------------------------

/// Publish a parsed artifact as a runtime module: validate, decode,
/// relocate, and fill the registry entry — the provisional
/// `.loading` entry at `core.modules.items.len - 1` (under `symbol`)
/// becomes `.loaded` only after every fallible step succeeded.
///
/// Atomic publication: every fallible step (decode, slot/cache
/// allocation, capacity reservation) runs before the first append,
/// and the append phase is pure commit (`appendAssumeCapacity` on
/// pre-reserved capacity). A rejected load therefore never leaves
/// phantom instructions or function entries in the `code`/`funcs`
/// arenas (Runtime §2.1: malformed loads publish no runtime state).
pub fn publishArtifact(core: *VmCore, allocator: std.mem.Allocator, img: *llir.LlirProgram, owned: bool) !void {
    const mi: u32 = @intCast(core.modules.items.len - 1);
    const m = core.modules.items[mi];
    // A load is rejected when the module would run into the reserved
    // continuation sentinels.
    const base: u64 = core.code.items.len;
    if (base + img.instructions.len >= interp_types.vm_internal_pc) return error.InvalidArtifact;
    // Decode 1:1 into a temporary buffer first: a reserved or
    // unassigned word fails the whole load before anything enters
    // the arena.
    const decoded = allocator.alloc(VmInstr, img.instructions.len) catch return error.OutOfMemory;
    defer allocator.free(decoded);
    const func_base: u32 = @intCast(core.funcs.items.len);
    for (img.instructions, 0..) |w, i| {
        var vi = vm_instr.decodeInstr(w) catch return error.InvalidArtifact;
        // Static `jal ra` targets are load-time constants: resolve
        // the target to its registry index (`func_base + local
        // FunctionId`) and store the index in the instruction's
        // operand, so the direct-call path never pays a pc→function
        // search or entry check. The validator already proved the
        // target is a function entry (llir_validate
        // checkCallResultTake); the entry check here is the same
        // guard, moved from the call hot path to the load.
        if (vi.op == .jal) {
            const t: u32 = @as(u32, @intCast(i)) +% vi.operand; // llir.jalTarget
            const fid = llir.functionAtPc(img.functions, t) orelse
                return error.InvalidArtifact;
            if (t != img.functions[fid].entry_pc) return error.InvalidArtifact;
            vi.operand = func_base + fid;
        }
        decoded[i] = vi;
    }
    // Fallible storage: owned by `m` only after the commit below.
    const slots = allocator.alloc(Value, img.module_slots.len) catch return error.OutOfMemory;
    errdefer allocator.free(slots);
    @memset(slots, 0);
    const cache = allocator.alloc(?u64, img.imports.len) catch return error.OutOfMemory;
    errdefer allocator.free(cache);
    @memset(cache, null);
    // Reserve capacity up front so the commit below cannot fail.
    core.code.ensureTotalCapacity(allocator, core.code.items.len + img.instructions.len) catch return error.OutOfMemory;
    core.funcs.ensureTotalCapacity(allocator, core.funcs.items.len + img.functions.len) catch return error.OutOfMemory;
    // Commit: relocation by `code_base` (pc-relative branch/jump/
    // switch offsets stay unchanged).
    for (decoded) |vi| core.code.appendAssumeCapacity(vi);
    for (img.functions) |fd| {
        const sig = img.signatures[fd.signature_id];
        core.funcs.appendAssumeCapacity(.{
            .desc = .{
                .code_start = fd.code_start + @as(u32, @intCast(base)),
                .code_end = fd.code_end + @as(u32, @intCast(base)),
                .entry_pc = fd.entry_pc + @as(u32, @intCast(base)),
                .signature_id = fd.signature_id,
                .f_count = fd.f_count,
                .x_count = fd.x_count,
                .window_count = fd.window_count,
            },
            .mod = mi,
            .arity = .{ .params = @intCast(sig.params_len), .ret = if (sig.ret != llir.no_index) 1 else 0 },
        });
    }
    m.state = .loaded;
    m.image = img;
    m.owned_image = owned;
    m.code_base = @intCast(base);
    m.code_len = @intCast(img.instructions.len);
    m.func_base = func_base;
    m.slots = slots;
    m.import_cache = cache;
}

/// Abort a failed load: remove the provisional entry and free all
/// temporary state. No partial module ever escapes.
pub fn abortLoad(core: *VmCore, allocator: std.mem.Allocator) void {
    const m = core.modules.pop().?;
    _ = core.module_by_symbol.remove(m.symbol);
    // If the module was already published before a later step failed
    // (e.g. the root frame or its eager initializer), roll its decoded
    // code and relocated functions back out of the arenas so no phantom
    // state survives. The aborted module is always the latest
    // publication, so truncation to its base is exact. Host modules
    // publish no code (their `code_base` is never set), so they are
    // skipped to avoid wiping an earlier module's range.
    if (m.state != .loading and !m.is_host) {
        core.code.shrinkRetainingCapacity(@intCast(m.code_base));
        core.funcs.shrinkRetainingCapacity(@intCast(m.func_base));
    }
    if (m.owned_image) {
        llir_emit_bin.freeImage(allocator, m.image);
        allocator.destroy(m.image);
    }
    allocator.free(m.symbol);
    if (m.slots.len != 0) allocator.free(m.slots);
    if (m.import_cache.len != 0) allocator.free(m.import_cache);
    allocator.destroy(m);
}

/// `loadModule(symbol)` (Runtime §2.1): return the cached module;
/// otherwise add a provisional `.loading` registry entry (cycle
/// detection), obtain the artifact from the provider (or mark a
/// registered host module), parse, validate, decode, and publish
/// atomically. Load failures never expose a partial module. Each
/// demand loads its module **eagerly**: the whole fetch → parse →
/// validate → decode → publish sequence completes before any
/// instruction of the module can execute.
pub fn loadModule(core: *VmCore, allocator: std.mem.Allocator, provider: *const ModuleLoader, symbol: []const u8) LoadError!u32 {
    if (core.module_by_symbol.get(symbol)) |mi| {
        const st = core.modules.items[mi].state;
        if (st == .loading) return error.LoaderCycle; // recursive load
        return mi;
    }
    // Provisional, non-executable registry entry.
    const m = allocator.create(RuntimeModule) catch return error.OutOfMemory;
    const sym_copy = allocator.dupe(u8, symbol) catch {
        allocator.destroy(m);
        return error.OutOfMemory;
    };
    m.* = .{
        .symbol = sym_copy,
        .state = .loading,
        .image = undefined,
        .code_base = 0,
        .code_len = 0,
        .func_base = 0,
        .owned_image = false,
        .slots = &.{},
        .import_cache = &.{},
        .is_host = false,
    };
    core.modules.append(allocator, m) catch {
        allocator.free(sym_copy);
        allocator.destroy(m);
        return error.OutOfMemory;
    };
    core.module_by_symbol.put(allocator, m.symbol, @intCast(core.modules.items.len - 1)) catch {
        _ = core.modules.pop();
        allocator.free(sym_copy);
        allocator.destroy(m);
        return error.OutOfMemory;
    };
    errdefer abortLoad(core, allocator);
    // Ask the provider: one provider per symbol.
    var res: LoadResult = .not_found;
    provider.load(provider.userdata, allocator, symbol, &res) catch |e| {
        return e;
    };
    switch (res) {
        .not_found => return error.ModuleNotFound,
        .host => {
            // A registered host module: ready after registration,
            // no Stilla initializer, no artifact.
            m.state = .loaded;
            m.is_host = true;
            return @intCast(core.modules.items.len - 1);
        },
        .bytes => |bytes| {
            defer allocator.free(bytes);
            const img = allocator.create(llir.LlirProgram) catch return error.OutOfMemory;
            img.* = blk: {
                const parsed = llir_emit_bin.read(allocator, bytes) catch {
                    allocator.destroy(img);
                    return error.InvalidArtifact;
                };
                break :blk parsed;
            };
            // From here `img` owns its parsed tables. Any failure
            // (validation rejection, or publication failure) must free
            // them; a successful publication transfers ownership to the
            // runtime module, so this errdefer does not run.
            errdefer {
                llir_emit_bin.freeImage(allocator, img);
                allocator.destroy(img);
            }
            // The provider's artifact is untrusted: validate it before
            // publication so a malformed module is never visible.
            const reject = validate.validate(img, allocator) catch return error.InvalidArtifact;
            if (reject) |msg| {
                allocator.free(msg);
                return error.InvalidArtifact;
            }
            publishArtifact(core, allocator, img, true) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidArtifact,
            };
            return @intCast(core.modules.items.len - 1);
        },
    }
}

/// Publish a borrowed artifact as the root module (no provider
/// round-trip) and set the core's root identity. Returns the new
/// module's registry index. The artifact must already be
/// structurally valid.
pub fn publishRoot(core: *VmCore, allocator: std.mem.Allocator, image: *llir.LlirProgram) !u32 {
    const m = allocator.create(RuntimeModule) catch return error.OutOfMemory;
    const sym_copy = allocator.dupe(u8, imageSelfSymbol(image)) catch {
        allocator.destroy(m);
        return error.OutOfMemory;
    };
    m.* = .{
        .symbol = sym_copy,
        .state = .loading,
        .image = image,
        .code_base = 0,
        .code_len = 0,
        .func_base = 0,
        .owned_image = false,
        .slots = &.{},
        .import_cache = &.{},
        .is_host = false,
    };
    core.modules.append(allocator, m) catch {
        allocator.free(sym_copy);
        allocator.destroy(m);
        return error.OutOfMemory;
    };
    core.module_by_symbol.put(allocator, m.symbol, @intCast(core.modules.items.len - 1)) catch {
        _ = core.modules.pop();
        allocator.free(sym_copy);
        allocator.destroy(m);
        return error.OutOfMemory;
    };
    errdefer abortLoad(core, allocator);
    try publishArtifact(core, allocator, image, false);
    core.root_symbol = sym_copy;
    core.root_module = @intCast(core.modules.items.len - 1);
    return core.root_module;
}

/// Hot-reload one loaded module: `reloadModule(symbol)` re-fetches,
/// re-parses, re-validates, and re-decodes the module's artifact through
/// the provider and atomically repoints `module_by_symbol` (and the
/// module slot, when the reloaded module is the root) at the fresh
/// version, returning its new registry index. On failure the old module
/// is left untouched and the provisional load is rolled back
/// (`abortLoad`), so a bad artifact never displaces the running image.
///
/// Quiesce contract (docs/interpreter-vm.md §11): reload is only sound
/// when no running frame references the old image, so it is refused
/// while the VM is executing — the caller must drain the VM first (run
/// to termination, or never start it). The superseded module stays
/// resident in the append-only arenas (its code, functions, image, and
/// symbol are freed exactly once by `VmCore.deinit` when the VM
/// quiesces for good), and every other module's `import_cache` is
/// cleared so import resolution re-targets the new module on demand.
/// A module that was never loaded (`ModuleNotFound`) or is mid-load
/// (`LoaderCycle`) cannot be reloaded.
pub fn reloadModule(core: *VmCore, allocator: std.mem.Allocator, provider: *const ModuleLoader, symbol: []const u8) LoadError!u32 {
    if (core.running and !core.terminated) return error.ContextRunning;
    const old_index = core.module_by_symbol.get(symbol) orelse return error.ModuleNotFound;
    const old = core.modules.items[old_index];
    if (old.state == .loading) return error.LoaderCycle;
    // Temporarily unpublish the symbol so `loadModule` does not return
    // the cached module: the fresh load appends a new provisional entry
    // and repoints the map on success. Reserve the restore slot first so
    // the rollback mapping cannot fail even on OutOfMemory.
    core.module_by_symbol.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
    _ = core.module_by_symbol.remove(symbol);
    errdefer {
        // Restore the old mapping on failure (`abortLoad` already removed
        // the provisional entry and its map entry). The old module's own
        // symbol copy is the map key, so the key storage outlives the
        // caller's `symbol` slice.
        core.module_by_symbol.putAssumeCapacity(old.symbol, old_index);
    }
    const new_index = loadModule(core, allocator, provider, symbol) catch |err| return err;
    // On success the map already points at the new module (keyed by its
    // own symbol copy).
    if (std.mem.eql(u8, core.root_symbol, symbol)) core.root_module = new_index;
    // Any module that imported `symbol` cached the old index in its
    // `import_cache`; clear every cache so resolution re-targets the new
    // module on demand.
    for (core.modules.items) |m| {
        if (m.import_cache.len > 0) @memset(m.import_cache, null);
    }
    return new_index;
}
