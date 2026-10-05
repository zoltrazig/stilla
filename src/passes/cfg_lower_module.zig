//! Pass: module-value emission helpers shared with the HIR seam. The
//! direct AST module/init/drop-hook lowering (`lowerModule`,
//! `lowerInit`, `lowerDropHook` and their helpers) was removed; the
//! HIR seam builds the module's member table and
//! lowers every function from `hir.BuiltProgram` records (see
//! hir_lower.zig). The two AST-free helpers both paths need survive
//! here.

const std = @import("std");
const moduleinfo = @import("stilla").moduleinfo;
const cfg_lower_emit = @import("cfg_lower_emit.zig");

/// The storage slot of a module-constant member (air.md §7), walking
/// the module's value-member list in declaration order: intrinsic
/// constants and module-valued / void members occupy no slot. The HIR
/// seam replicates the member table with this same compaction.
pub fn constSlot(info: *moduleinfo.ModuleInfo, vm: *const moduleinfo.ValueMember) ?u32 {
    var n: u32 = 0;
    for (info.values) |*v| {
        if (v == vm) {
            return switch (v.decl) {
                .const_ => |c| blk: {
                    _ = c;
                    if (info.isIntrinsic(v)) break :blk null;
                    if (v.module_spec == null and !cfg_lower_emit.isVoid(v.type_)) break :blk n else break :blk null;
                },
                .func => null,
            };
        }
        switch (v.decl) {
            .const_ => |c| {
                _ = c;
                if (info.isIntrinsic(v)) continue;
                if (v.module_spec == null and !cfg_lower_emit.isVoid(v.type_)) n += 1;
            },
            else => {},
        }
    }
    return null;
}
