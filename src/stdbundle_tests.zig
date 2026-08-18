//! Test file: `stdbundle` — the embedded standard-library bundle.
//!
//! White-box tests of `src/stdbundle.zig`'s own internals stay in that
//! module's file; this file aggregates them so they are analyzed and run,
//! and adds black-box tests that every embedded `std/*.st` source parses
//! and checks as a host-binding surface.
//!
//! Run this file via `zig build test` (it pulls in `stdbundle.zig`, whose
//! `stilla_std_sources` anonymous import is only wired up by the build
//! system; `--dep` cannot attach to the main module from the CLI).

const std = @import("std");
const ast = @import("ast.zig");
const checker = @import("passes/checker.zig");
const moduleinfo = @import("moduleinfo.zig");
const stdbundle = @import("stdbundle.zig");
const testing = std.testing;

test {
    // White-box tests of the module file in this slice.
    _ = @import("stdbundle.zig");
}

// ---------------------------------------------------------------------------
// stdbundle — black-box: every embedded std/*.st source must parse and
// check as a host-binding surface.
// ---------------------------------------------------------------------------

test "std bundle modules parse and check as host bindings" {
    for (stdbundle.modules) |m| try checkModule(m);
}

/// Parse and type-check one bundle module, then assert that it is exactly a
/// host-binding surface: every function is a declaration without a body and
/// is flagged as a host binding; every constant without an initializer
/// carries a declared type.
fn checkModule(m: stdbundle.Module) !void {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // Register every bundle module so `import(...)` edges between bundle
    // modules (e.g. `string.st` importing `builtin`) resolve in the graph.
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (stdbundle.modules) |bm| try source_map.put(arena.allocator(), bm.specifier, bm.source);

    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .standard_library = source_map });
    const graph = builder.build(m.specifier) catch |err| {
        std.debug.print("FAIL {s}: {s}\n", .{ m.specifier, builder.diag.?.message });
        return err;
    };

    var ck = checker.Checker.init(arena.allocator());
    var ann = try ck.check(graph);
    defer ann.deinit();

    // `iter` and `list` are ordinary Stilla source (StdLib §7, §8):
    // every combinator / derived operation has a real body. `list.get`
    // is the one host binding among them — the element read, declared
    // without a body and lowered to the `read_index` op. Every other
    // bundle module is declaration-only host binding surface.
    const mixed = std.mem.eql(u8, m.specifier, "iter") or std.mem.eql(u8, m.specifier, "list");
    for (graph.modules) |info| {
        const program = info.program orelse continue;
        for (program.items) |*item| switch (item.*) {
            .func_def => |*f| {
                if (mixed) {
                    // Mixed modules: a body exactly when not a host binding.
                    try testing.expect((f.body == null) == ann.host_bindings.contains(f));
                } else {
                    // Every bundle function is a host binding: a declaration
                    // without a body, flagged in the annotation.
                    try testing.expect(f.body == null);
                    try testing.expect(ann.host_bindings.contains(f));
                }
            },
            .const_def => |*c| if (c.init == null) {
                // A host constant must name its type.
                try testing.expect(c.type_ != null);
            },
            else => {},
        };
    }
}

test "std bundle exposes exactly the StdLib §1 module set" {
    // StdLib §1: builtin, math, string, array, hashmap, iter, list.
    const expected = [_][]const u8{ "builtin", "math", "string", "array", "hashmap", "iter", "list" };
    try testing.expectEqual(@as(usize, expected.len), stdbundle.modules.len);
    for (expected, 0..) |spec, i| {
        try testing.expectEqualStrings(spec, stdbundle.modules[i].specifier);
        // Every bundle member is declaration-only host binding surface:
        // a source string that parses on its own.
        try checkModule(stdbundle.modules[i]);
    }
}

test "std bundle sources are non-empty host-binding surfaces" {
    // Each embedded source is registered under its specifier; resolution
    // loads them by that name (frontend §3.2), and they are declaration
    // surfaces without a Stilla `module` header of their own.
    for (stdbundle.modules) |m| {
        try testing.expect(m.source.len > 0);
        try testing.expect(m.specifier.len > 0);
        // Each module must expose at least one member declaration.
        try testing.expect(std.mem.indexOf(u8, m.source, "fn ") != null);
    }
}

test "std bundle registers array and hashmap as opaque host types" {
    // StdLib §1, Core §11.8: `Array[T]` and `HashMap[K, V]` are declared
    // `opaque type` in the module interface and registered as opaque type
    // members, not as structs.
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (stdbundle.modules) |bm| try source_map.put(arena.allocator(), bm.specifier, bm.source);

    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .standard_library = source_map });
    const graph = try builder.build("array");

    const arr = graph.module("array").?;
    const tm = arr.typeMember("Array") orelse return error.TestUnexpectedResult;
    try testing.expect(tm.decl == .opaque_);
    try testing.expect(tm.generic);

    var builder2 = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .standard_library = source_map });
    const graph2 = try builder2.build("hashmap");
    const hm = graph2.module("hashmap").?;
    const htm = hm.typeMember("HashMap") orelse return error.TestUnexpectedResult;
    try testing.expect(htm.decl == .opaque_);
    try testing.expect(htm.generic);
}
