//! Per-module artifact bundle (Runtime §6): from one whole-program
//! `cfg.IrProgram` (the frontend lowers the entry plus its transitive
//! dependency closure — app modules and stdlib — together), produce one
//! module-local `LlirProgram` per `program.modules` entry. Generic
//! instantiations (`list.head.2`) live in the module that instantiates
//! them and are emitted into that module's scoped artifact, so the root
//! artifact alone cannot satisfy a dependency's monomorphized bodies.
//!
//! The bundle backs a `interpreter.ModuleLoader`: resolving a module
//! symbol serializes that module's scoped artifact into the VM's
//! allocator; a host-only module (no runnable artifact) resolves to the
//! registered-host-module descriptor. Shared metadata (types,
//! signatures, strings, constants) is seeded identically into every
//! artifact from the root build (docs/interpreter-vm.md §6), so a
//! signature/type id means the same thing in every artifact of one
//! compilation.

const std = @import("std");
const cfg = @import("cfg.zig");
const llir = @import("llir.zig");
const interpreter = @import("interpreter.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_emit_bin = @import("passes/llir_emit_bin.zig");

/// The whole-program compilation's per-module artifacts.
pub const ArtifactBundle = struct {
    /// The entry (root) module's artifact — the image `run` executes.
    root: llir.LlirProgram,
    /// The root artifact's entry `FunctionId` (for `runWithEntry*`).
    entry: llir.FunctionId,
    /// Canonical module symbol → that module's scoped artifact.
    artifacts: std.StringHashMapUnmanaged(llir.LlirProgram) = .empty,
    /// Whether each artifact is host-only (no runnable content).
    host_only: std.StringHashMapUnmanaged(bool) = .empty,

    pub const Error = error{ OutOfMemory, ProgramTooLarge, IdOutOfRange, SyscallWithoutSignature, DuplicateExport };

    /// Lower the whole program, then one scoped artifact per module.
    /// `artifacts` and `host_only` alias `arena`.
    pub fn build(arena: std.mem.Allocator, program: *const cfg.IrProgram) Error!ArtifactBundle {
        var root_b = cfg_lower_llir.Builder.init(arena, program);
        var self = ArtifactBundle{
            .root = try root_b.lowerLlir(),
            .entry = if (program.entry) |e| root_b.func_ids.get(e) orelse 0 else 0,
        };
        errdefer self.artifacts.deinit(arena);
        errdefer self.host_only.deinit(arena);
        for (program.modules, 0..) |m, mi| {
            var sb = cfg_lower_llir.Builder.init(arena, program);
            sb.module_scope = mi;
            try sb.seedShared(&root_b);
            const img = try sb.lowerLlir();
            const host = isHostOnly(&img);
            try self.artifacts.put(arena, m.name, img);
            try self.host_only.put(arena, m.name, host);
        }
        return self;
    }

    /// A module is host-only when its scoped artifact carries nothing to
    /// run — no functions, no module slots, no initializer. Such modules
    /// are ready after registration and have no artifact (Runtime §2.1).
    fn isHostOnly(img: *const llir.LlirProgram) bool {
        return img.functions.len == 0 and img.module_slots.len == 0 and img.init == llir.no_index;
    }

    /// A `ModuleLoader` callback over this bundle: serialize the named
    /// module's scoped artifact into `allocator` (the VM frees it after
    /// parsing), or report a registered host module. Unknown symbols
    /// are `not_found`.
    pub fn loader(
        userdata: ?*const anyopaque,
        allocator: std.mem.Allocator,
        symbol: []const u8,
        out: *interpreter.LoadResult,
    ) interpreter.LoadError!void {
        const bundle: *const ArtifactBundle = @ptrCast(@alignCast(userdata.?));
        const img = bundle.artifacts.get(symbol) orelse {
            out.* = .not_found;
            return;
        };
        if (bundle.host_only.get(symbol) orelse false) {
            out.* = .host;
            return;
        }
        const bytes = llir_emit_bin.write(img, allocator) catch return error.OutOfMemory;
        out.* = .{ .bytes = bytes };
    }

    /// A loader handle bound to this bundle.
    pub fn loaderHandle(self: *const ArtifactBundle) interpreter.ModuleLoader {
        return .{ .userdata = self, .load = loader };
    }
};
