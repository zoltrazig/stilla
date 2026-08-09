//! Pass: module-level checks. In: Builder + RawModule (materialized). Out:
//! `error.Diagnostic` with the builder's `diag` set on the first duplicate
//! member name.
//!
//! Member names of the generated module struct are unique (Core §2.1);
//! type member names are unique too (frontend §3.3).

const std = @import("std");
const moduleinfo = @import("../moduleinfo.zig");

const Builder = moduleinfo.Builder;
const RawModule = moduleinfo.RawModule;

pub fn checkModule(self: *Builder, raw: *RawModule) !void {
    const info = raw.info;
    // Member names of the generated module struct are unique
    // (Core §2.1); type member names are unique too.
    var seen_values = std.StringHashMapUnmanaged(void).empty;
    for (info.values) |vm| {
        if (seen_values.contains(vm.name.text)) {
            return self.failSpan(vm.name.span, "duplicate module member '{s}'", .{vm.name.text});
        }
        try seen_values.put(self.arena, vm.name.text, {});
    }
    var seen_types = std.StringHashMapUnmanaged(void).empty;
    for (info.types) |tm| {
        if (seen_types.contains(tm.name.text)) {
            return self.failSpan(tm.name.span, "duplicate type member '{s}'", .{tm.name.text});
        }
        try seen_types.put(self.arena, tm.name.text, {});
    }
}
