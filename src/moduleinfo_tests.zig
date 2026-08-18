//! Test file: `moduleinfo` — frontend Phase 1 module-graph construction.
//!
//! White-box tests of `src/moduleinfo.zig`'s own internals stay in that
//! module's file; this file aggregates them (with the split passes in
//! `src/passes/` — `module_load`, `module_scan`, `module_materialize`,
//! `module_check`, `topo_sort`, `type_resolve`, `type_shape`,
//! `type_infer`) so they are analyzed and run, and adds black-box tests of
//! module graphs built from in-memory sources.
//!
//! Run this file via `zig build test` (it pulls in `moduleinfo.zig`, whose
//! `stilla_std_sources` anonymous import is only wired up by the build
//! system; `--dep` cannot attach to the main module from the CLI).

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const moduleinfo = @import("moduleinfo.zig");
const testing = std.testing;

test {
    // White-box tests of the module files in this slice.
    _ = @import("moduleinfo.zig");
    _ = @import("passes/module_load.zig");
    _ = @import("passes/module_scan.zig");
    _ = @import("passes/module_materialize.zig");
    _ = @import("passes/module_check.zig");
    _ = @import("passes/topo_sort.zig");
    _ = @import("passes/type_resolve.zig");
    _ = @import("passes/type_shape.zig");
    _ = @import("passes/type_infer.zig");
}

// ---------------------------------------------------------------------------
// moduleinfo — black-box: module graphs built from in-memory sources
// (Phase 1 of the frontend pipeline).
// ---------------------------------------------------------------------------

/// Build a module graph from an entry specifier and a set of in-memory
/// source modules. The arena is heap-allocated so `graph.arena` (an
/// `Allocator` whose `ptr` is the `ArenaAllocator`) stays valid after this
/// helper returns — the graph is used directly by tests afterwards, unlike
/// the frontend which only touches it during `compile()`. `deinit` frees
/// the arena and its backing memory.
fn buildGraph(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !struct {
    arena: *std.heap.ArenaAllocator,
    graph: *moduleinfo.ModuleGraph,
} {
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    errdefer testing.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const arena_alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    for (texts) |pair| try source_map.put(testing.allocator, pair[0], pair[1]);
    sources.source = source_map;

    var b = moduleinfo.Builder.init(arena_alloc, sources);
    const graph = try b.build(entry);
    return .{ .arena = arena, .graph = graph };
}

test "moduleinfo loads the entry module and orders modules by dependency" {
    var t = try buildGraph("use", &.{
        .{ "calc", "fn add(a: int32, b: int32) -> int32 { a + b }" },
        .{ "use", "const calc = import(\"calc\");\nfn main() -> int32 { calc.add(1, 2) }" },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 2), t.graph.modules.len);
    // Dependencies before dependents (phase1-module-graph.md, Import-cycle detection): `calc` first.
    try testing.expectEqualStrings("calc", t.graph.modules[0].specifier);
    try testing.expectEqualStrings("use", t.graph.modules[1].specifier);
    try testing.expectEqualStrings("use", t.graph.entry.specifier);
    try testing.expect(t.graph.module("calc") != null);
    try testing.expect(t.graph.module("missing") == null);
}

test "moduleinfo resolves the stdbundle standard-library modules" {
    // The embedded `std/` bundle (phase1-module-graph.md, Loading, parsing, and deduplication) is always resolvable,
    // before the caller's extra `standard_library` map (Runtime §2.6).
    var t = try buildGraph("app", &.{
        .{ "app", "const math = import(\"math\");\nfn main() -> void {}" },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 2), t.graph.modules.len);
    const math = t.graph.module("math").?;
    try testing.expectEqual(moduleinfo.ModuleKind.standard_library, math.kind);
    try testing.expect(math.source != null);
    // The math module's members are all host bindings.
    try testing.expect(math.values.len > 0);
    var all_host = true;
    for (math.values) |vm| {
        if (!vm.host) all_host = false;
    }
    try testing.expect(all_host);
}

test "moduleinfo resolves extra standard-library and host modules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var std_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer std_map.deinit(testing.allocator);
    try std_map.put(testing.allocator, "extra", "fn f() -> int32;");
    sources.standard_library = std_map;
    var host_map = std.StringHashMapUnmanaged(void).empty;
    defer host_map.deinit(testing.allocator);
    try host_map.put(testing.allocator, "os", {});
    sources.host = host_map;
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", "const extra = import(\"extra\");\nconst os = import(\"os\");\nfn main() -> void {}");
    sources.source = source_map;

    var b = moduleinfo.Builder.init(arena_alloc, sources);
    const graph = try b.build("app");

    try testing.expectEqual(@as(usize, 3), graph.modules.len);
    const extra = graph.module("extra").?;
    try testing.expectEqual(moduleinfo.ModuleKind.standard_library, extra.kind);
    const os = graph.module("os").?;
    try testing.expectEqual(moduleinfo.ModuleKind.host, os.kind);
    // A host module has no source and no program to annotate.
    try testing.expect(os.source == null);
    try testing.expect(os.program == null);
    try testing.expectEqual(@as(usize, 0), os.values.len);
}

test "moduleinfo rejects an import cycle with a diagnostic" {
    // Core §2.4 / Runtime §2.6: import cycles are rejected in v1.3. The
    // builder fails with `error.Diagnostic` and records the first error.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "a", "const b = import(\"b\");\n");
    try source_map.put(testing.allocator, "b", "const a = import(\"a\");\n");
    sources.source = source_map;

    var b = moduleinfo.Builder.init(arena_alloc, sources);
    try testing.expectError(error.Diagnostic, b.build("a"));
    try testing.expect(b.diag != null);
    try testing.expect(std.mem.indexOf(u8, b.diag.?.message, "import cycle") != null);
    // Pass 6.2: the full cycle path is named, not just one module.
    try testing.expect(std.mem.indexOf(u8, b.diag.?.message, "a imports b imports a") != null);
}

test "moduleinfo rejects an unresolved import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "a", "const missing = import(\"nope\");\n");
    sources.source = source_map;

    var b = moduleinfo.Builder.init(arena_alloc, sources);
    try testing.expectError(error.Diagnostic, b.build("a"));
    try testing.expect(b.diag != null);
    try testing.expect(std.mem.indexOf(u8, b.diag.?.message, "unresolved import") != null);
}

test "moduleinfo builds member tables: values, types, using aliases" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\using builtin.Option;
            \\struct Point { x: int32; y: int32; }
            \\union Result { Ok(int32), Err(str) }
            \\type Size = int32;
            \\const version: int32 = 1;
            \\fn add(a: int32, b: int32) -> int32 { a + b }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const app = t.graph.module("app").?;
    // Value members: functions first, then module-value consts and
    // ordinary consts (phase1-module-graph.md, Module-level information materializes funcs before consts,
    // mirroring the generated module struct's member space).
    try testing.expectEqual(@as(usize, 4), app.values.len);
    try testing.expectEqualStrings("add", app.values[0].name.text);
    try testing.expectEqualStrings("main", app.values[1].name.text);
    try testing.expectEqualStrings("builtin", app.values[2].name.text);
    try testing.expect(app.values[2].module_spec != null);
    try testing.expectEqualStrings("builtin", app.values[2].module_spec.?);
    try testing.expectEqualStrings("version", app.values[3].name.text);

    // Type members: struct, union, alias in declaration order.
    try testing.expectEqual(@as(usize, 3), app.types.len);
    try testing.expectEqualStrings("Point", app.types[0].name.text);
    try testing.expectEqualStrings("Result", app.types[1].name.text);
    try testing.expectEqualStrings("Size", app.types[2].name.text);
    try testing.expect(app.types[0].decl == .struct_);
    try testing.expect(app.types[1].decl == .union_);
    try testing.expect(app.types[2].decl == .alias);

    // The `using builtin.Option` alias resolves to the type member.
    try testing.expectEqual(@as(usize, 1), app.using_aliases.len);
    const al = app.alias("Option").?;
    try testing.expectEqualStrings("Option", al.name);
    switch (al.target) {
        .type => |mref| {
            try testing.expectEqualStrings("builtin", mref.module);
            try testing.expectEqualStrings("Option", mref.name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "moduleinfo member lookup helpers" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\struct Point { x: int32; y: int32; }
            \\const pi: float32 = 3.14;
            \\fn sq(x: float32) -> float32 { x * x }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const app = t.graph.module("app").?;
    try testing.expectEqualStrings("pi", app.valueMember("pi").?.name.text);
    try testing.expect(app.valueMember("nope") == null);
    try testing.expectEqualStrings("Point", app.typeMember("Point").?.name.text);
    try testing.expect(app.typeMember("nope") == null);
    try testing.expect(app.alias("nope") == null);
}

test "moduleinfo flags host bindings (declarations without definitions)" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\fn host_fn(x: int32) -> int32;
            \\const host_const: int32;
            \\fn real_fn(x: int32) -> int32 { x }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const app = t.graph.module("app").?;
    try testing.expect(app.isHostBinding("host_fn"));
    try testing.expect(!app.isHostBinding("real_fn"));
    try testing.expect(!app.isHostBinding("main"));
    try testing.expect(!app.isHostBinding("host_const")); // consts are not function bindings
    try testing.expectEqual(@as(usize, 1), app.host_bindings.len);
    try testing.expectEqualStrings("host_fn", app.host_bindings[0].name.text);
    try testing.expect(app.host_bindings[0].signature == .function);
}

test "moduleinfo rejects a duplicate module member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", "fn f() -> void {}\nconst f: int32 = 1;\n");
    sources.source = source_map;

    var b = moduleinfo.Builder.init(arena_alloc, sources);
    try testing.expectError(error.Diagnostic, b.build("app"));
    try testing.expect(std.mem.indexOf(u8, b.diag.?.message, "duplicate module member") != null);
}

test "moduleinfo requires a host constant to declare its type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", "const x;\n");
    sources.source = source_map;

    var b = moduleinfo.Builder.init(arena_alloc, sources);
    try testing.expectError(error.Diagnostic, b.build("app"));
    try testing.expect(std.mem.indexOf(u8, b.diag.?.message, "must declare its type") != null);
}

test "moduleinfo preserves module identity through const aliases" {
    // Core §2.3 / Runtime §2.4: `const public_math = math;` denotes the
    // same module storage as `math`.
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\const math = import("math");
            \\const public_math = math;
            \\fn main() -> void { let x = public_math.pi; }
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const app = t.graph.module("app").?;
    // Both consts carry the resolved specifier "math": the import and
    // its alias denote the same module instance (Runtime §2.4).
    const math_member = app.valueMember("math").?;
    try testing.expectEqualStrings("math", math_member.module_spec.?);
    try testing.expect(math_member.type_ == .module);
    const alias_member = app.valueMember("public_math").?;
    try testing.expectEqualStrings("math", alias_member.module_spec.?);
    try testing.expect(alias_member.type_ == .module);
    // moduleValueMember finds the member that names the specifier.
    try testing.expect(app.moduleValueMember("math") != null);
}

test "moduleinfo resolves module-qualified type names" {
    // Core §2.5: chained module-valued member paths resolve at compile
    // time (`std.math.Vec`-style); a `using` alias to a module resolves
    // as a type-path prefix too (Core §2.8).
    var t = try buildGraph("app", &.{
        .{ "nested", "const builtin = import(\"builtin\");\n" },
        .{
            "app",
            \\const nested = import("nested");
            \\using nested as n;
            \\type O = n.builtin.Option;
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    // Direct chained path `nested.builtin.Option` resolves to builtin's
    // Option union member through the module-valued members.
    try testing.expect(moduleinfo.resolveTypeName(resolve, app, "nested.builtin.Option") != null);
    // A `using` alias to a module (`using nested as n`) is a valid
    // prefix for a qualified type path.
    try testing.expect(moduleinfo.resolveTypeName(resolve, app, "n.builtin.Option") != null);
    try testing.expect(moduleinfo.resolveTypeName(resolve, app, "nope.Option") == null);
}

test "moduleinfo structDecl and unionDecl follow transparent aliases" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\struct Point { x: int32; y: int32; }
            \\union Result { Ok(int32), Err(str) }
            \\type P2 = Point;
            \\type R2 = Result;
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    const sd = moduleinfo.structDecl(resolve, app, "Point").?;
    try testing.expectEqual(@as(usize, 2), sd.fields.len);
    try testing.expectEqualStrings("x", sd.fields[0].name.text);
    // Through the alias.
    try testing.expect(moduleinfo.structDecl(resolve, app, "P2") != null);
    try testing.expect(moduleinfo.structDecl(resolve, app, "Result") == null);
    const ud = moduleinfo.unionDecl(resolve, app, "Result").?;
    try testing.expectEqual(@as(usize, 2), ud.variants.len);
    try testing.expect(moduleinfo.unionDecl(resolve, app, "R2") != null);
    try testing.expect(moduleinfo.unionDecl(resolve, app, "Point") == null);
}

test "moduleinfo fieldIndex and variantIndex" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\struct Point { x: int32; y: int32; }
            \\union Result { Ok(int32), Err(str) }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    const sd = moduleinfo.structDecl(resolve, app, "Point").?;
    try testing.expectEqual(@as(u32, 0), moduleinfo.fieldIndex(sd, "x").?);
    try testing.expectEqual(@as(u32, 1), moduleinfo.fieldIndex(sd, "y").?);
    try testing.expect(moduleinfo.fieldIndex(sd, "z") == null);
    const ud = moduleinfo.unionDecl(resolve, app, "Result").?;
    try testing.expectEqual(@as(u32, 0), moduleinfo.variantIndex(ud, "Ok").?);
    try testing.expectEqual(@as(u32, 1), moduleinfo.variantIndex(ud, "Err").?);
    try testing.expect(moduleinfo.variantIndex(ud, "Nope") == null);
}

test "moduleinfo ownershipOf classifies primitives and containers" {
    var t = try buildGraph("app", &.{.{ "app", "fn main() -> void {}" }});
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();
    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;

    // Core §10.1: primitives are Copy except any / hostdata.
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .primitive = .int32 }).?);
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .primitive = .str }).?);
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .primitive = .void }).?);
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .primitive = .any }).?);
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .primitive = .hostdata }).?);
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .module).?);
    var void_ret = cfg.Type{ .primitive = .void };
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .function = .{ .params = &.{}, .ret = &void_ret } }).?);

    // Core §10.3: containers join their components.
    var int32 = cfg.Type{ .primitive = .int32 };
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .list = &int32 }).?);
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .box = &int32 }).?);
    var any = cfg.Type{ .primitive = .any };
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .list = &any }).?);
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .box = &any }).?);
    var tuple_unique = [_]cfg.Type{ int32, any };
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .tuple = &tuple_unique }).?);
    var tuple_dup = [_]cfg.Type{ int32, int32 };
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .tuple = &tuple_dup }).?);
}

test "moduleinfo ownershipOf resolves named structs and unions" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\struct Dup { x: int32; }
            \\struct File { fd: int32; drop(file) {} }
            \\struct Holds { f: File; }
            \\union Maybe { Some(File), None }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    // Core §10.2: a struct with a drop hook is unique.
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.Dup").?, .args = &.{} } }).?);
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.File").?, .args = &.{} } }).?);
    // Core §10.3: a struct with an unique field is unique; a union with
    // an unique payload variant is unique.
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.Holds").?, .args = &.{} } }).?);
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.Maybe").?, .args = &.{} } }).?);
}

test "moduleinfo ownershipOf handles recursive types through indirection" {
    // Core §11.3: recursion is legal only through indirection (box). Core
    // §10.3: a recursive type with no drop hook, such as `Tree`, is
    // unique — it cannot be copied implicitly, and box[Tree]/list[Tree]
    // are unique containers (least fixpoint).
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\union Tree { Empty, Node(box[Tree], int32, box[Tree]) }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.Tree").?, .args = &.{} } }).?);
    // box[Tree] / list[Tree] are unique containers of the recursive type.
    var tree = cfg.Type{ .named = .{ .id = resolve.intern("app.Tree").?, .args = &.{} } };
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .box = &tree }).?);
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .list = &tree }).?);
    // A type cycle that passes only through function types is Copy
    // (Core §10.3: a function type is not an owned component).
    var t2 = try buildGraph("app", &.{
        .{
            "app",
            \\struct F { call: fn(F) -> int32; }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t2.arena);
    defer t2.arena.deinit();

    const resolve2 = moduleinfo.resolveOf(t2.graph);
    const app2 = t2.graph.module("app").?;
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve2, app2, .{ .named = .{ .id = resolve2.intern("app.F").?, .args = &.{} } }).?);
}

test "moduleinfo ownershipOf: containers of a named Copy type are Copy" {
    // Core §10.3: `box[T]` / `list[T]` are Copy when `T` is Copy, so a
    // struct whose only component is such a container is Copy — including
    // when the element is a named Copy type (a generic instantiation), and
    // when two sibling instantiations of one declaration appear in one
    // struct (they are distinct types, not a cycle).
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\union Option[T] { Some(T), None }
            \\struct Holder { b: box[Option[int32]]; }
            \\struct Both { a: Option[int32]; b: Option[str]; }
            \\struct Tree { children: list[Tree]; }
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    var opt_i32_args = [_]cfg.Type{cfg.Type{ .primitive = .int32 }};
    var opt_i32 = cfg.Type{ .named = .{ .id = resolve.intern("app.Option").?, .args = &opt_i32_args } };
    var opt_str_args = [_]cfg.Type{cfg.Type{ .primitive = .str }};
    const opt_str = cfg.Type{ .named = .{ .id = resolve.intern("app.Option").?, .args = &opt_str_args } };
    // The named instantiation itself is Copy (its payload is Copy).
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, opt_i32).?);
    // The container of a named Copy type is Copy (was: unique).
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .box = &opt_i32 }).?);
    // A struct holding it is Copy (was: unique).
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.Holder").?, .args = &.{} } }).?);
    // Sibling instantiations of one declaration are distinct, not a cycle.
    try testing.expectEqual(cfg.Ownership.copy, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.Both").?, .args = &.{} } }).?);
    _ = opt_str;
    // A recursive type through list indirection stays unique (least fixpoint).
    try testing.expectEqual(cfg.Ownership.unique, moduleinfo.ownershipOf(resolve, app, .{ .named = .{ .id = resolve.intern("app.Tree").?, .args = &.{} } }).?);
}

test "moduleinfo resolveType expands aliases and resolves containers" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\type Size = int32;
            \\type ListOf = list[Size];
            \\type Pair = tuple[Size, str];
            \\type Func = fn(move Size) -> bool;
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    const sizetm = app.typeMember("Size").?;
    const size_ast = sizetm.decl.alias;
    const t1 = moduleinfo.resolveType(resolve, app, &size_ast.target).?;
    try testing.expect(t1 == .primitive);
    try testing.expectEqual(ast.PrimitiveKind.int32, t1.primitive);

    const ltm = app.typeMember("ListOf").?;
    const t2 = moduleinfo.resolveType(resolve, app, &ltm.decl.alias.target).?;
    try testing.expect(t2 == .list);
    try testing.expectEqual(ast.PrimitiveKind.int32, t2.list.*.primitive);

    const ptm = app.typeMember("Pair").?;
    const t3 = moduleinfo.resolveType(resolve, app, &ptm.decl.alias.target).?;
    try testing.expectEqual(@as(usize, 2), t3.tuple.len);
    try testing.expectEqual(ast.PrimitiveKind.str, t3.tuple[1].primitive);

    const ftm = app.typeMember("Func").?;
    const t4 = moduleinfo.resolveType(resolve, app, &ftm.decl.alias.target).?;
    try testing.expect(t4 == .function);
    try testing.expectEqual(@as(usize, 1), t4.function.params.len);
    try testing.expectEqual(ast.ParamMode.move, t4.function.params[0].mode);
    try testing.expectEqual(ast.PrimitiveKind.bool, t4.function.ret.*.primitive);
}

test "moduleinfo inferExprType infers module constant types" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\const a = 42;
            \\const b = 3.14;
            \\const c = "hi";
            \\const d = true;
            \\const e = (1, "two");
            \\const f = [1, 2, 3];
            \\const g = 1 + 2;
            \\const h = 1 == 2;
            \\struct P { x: int32; y: int32; }
            \\fn make_p() -> P { P{ x: 1, y: 2 } }
            \\const p = make_p();
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    const expectInt32 = struct {
        fn check(rsv: moduleinfo.Resolve, from: *moduleinfo.ModuleInfo, c: *const ast.ConstDef) !void {
            try testing.expectEqual(ast.PrimitiveKind.int32, (moduleinfo.inferExprType(rsv, from, c.init.?).?).primitive);
        }
    }.check;
    try expectInt32(resolve, app, app.valueMember("a").?.decl.const_);
    try testing.expectEqual(ast.PrimitiveKind.float32, (moduleinfo.inferExprType(resolve, app, app.valueMember("b").?.decl.const_.init.?).?).primitive);
    try testing.expectEqual(ast.PrimitiveKind.str, (moduleinfo.inferExprType(resolve, app, app.valueMember("c").?.decl.const_.init.?).?).primitive);
    try testing.expectEqual(ast.PrimitiveKind.bool, (moduleinfo.inferExprType(resolve, app, app.valueMember("d").?.decl.const_.init.?).?).primitive);
    try testing.expectEqual(@as(usize, 2), (moduleinfo.inferExprType(resolve, app, app.valueMember("e").?.decl.const_.init.?).?).tuple.len);
    try testing.expectEqual(ast.PrimitiveKind.int32, (moduleinfo.inferExprType(resolve, app, app.valueMember("f").?.decl.const_.init.?).?).list.*.primitive);
    try testing.expectEqual(ast.PrimitiveKind.int32, (moduleinfo.inferExprType(resolve, app, app.valueMember("g").?.decl.const_.init.?).?).primitive);
    try testing.expectEqual(ast.PrimitiveKind.bool, (moduleinfo.inferExprType(resolve, app, app.valueMember("h").?.decl.const_.init.?).?).primitive);
    // A call's return type resolves through the callee signature.
    try testing.expectEqualStrings("app.P", resolve.typeNameOf((moduleinfo.inferExprType(resolve, app, app.valueMember("p").?.decl.const_.init.?).?).named.id).?);
}

test "moduleinfo resolvePathMember and resolvePathTarget" {
    var t = try buildGraph("app", &.{
        .{ "calc", "fn add(a: int32, b: int32) -> int32 { a + b }\nconst two: int32 = 2;\n" },
        .{
            "app",
            \\const calc = import("calc");
            \\fn main() -> void { let x = calc.add(1, 2); }
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    const calc = t.graph.module("calc").?;

    // Local member.
    const main = app.valueMember("main").?;
    try testing.expectEqualStrings("main", main.name.text);

    // Module-qualified member.
    var path = [_]ast.Ident{ .{ .span = ast.Span.init(0, 0, 0), .text = "calc" }, .{ .span = ast.Span.init(0, 0, 0), .text = "add" } };
    const add_vm = moduleinfo.resolvePathMember(resolve, app, &path).?;
    try testing.expectEqualStrings("add", add_vm.name.text);

    // PathTarget returns the owning module.
    const target = moduleinfo.resolvePathTarget(resolve, app, &path).?;
    try testing.expectEqualStrings("calc", target.module.specifier);
    try testing.expectEqualStrings("add", target.vm.name.text);

    // A single-segment path resolves against the module itself.
    const single = [_]ast.Ident{.{ .span = ast.Span.init(0, 0, 0), .text = "two" }};
    const two_vm = moduleinfo.resolvePathMember(resolve, calc, &single).?;
    try testing.expectEqualStrings("two", two_vm.name.text);

    // Unknown paths resolve to null.
    const bad = [_]ast.Ident{.{ .span = ast.Span.init(0, 0, 0), .text = "nope" }};
    try testing.expect(moduleinfo.resolvePathMember(resolve, app, &bad) == null);
}

test "moduleinfo specializeSignature instantiates generic host bindings" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\const lists = import("list");
            \\fn main() -> void {
            \\    let n = lists.len(["a", "b"]);
            \\    let r = lists.range(0, 5);
            \\}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const len_vm = t.graph.module("list").?.valueMember("len").?;
    const sig = len_vm.type_.function;

    // `len[T](borrow xs: list[T]) -> int32` with a list[str] argument
    // binds T = str.
    var str_t = cfg.Type{ .primitive = .str };
    const list_str = cfg.Type{ .list = &str_t };
    const arg_types = [_]cfg.Type{list_str};
    const specialized = moduleinfo.specializeSignature(resolve, t.graph.module("list").?, sig, &arg_types);
    try testing.expect(specialized == .function);
    const ft = specialized.function;
    try testing.expectEqual(@as(usize, 1), ft.params.len);
    try testing.expectEqual(ast.ParamMode.borrow, ft.params[0].mode);
    try testing.expect(ft.params[0].type_ == .list);
    try testing.expectEqual(ast.PrimitiveKind.str, ft.params[0].type_.list.*.primitive);
    try testing.expectEqual(ast.PrimitiveKind.int32, ft.ret.*.primitive);

    // `range(start: int32, end: int32) -> list[int32]` is a non-generic
    // host binding of the `list` module and passes through unchanged.
    const range_vm = t.graph.module("list").?.valueMember("range").?;
    const range_sig = range_vm.type_.function;
    const range_args = [_]cfg.Type{ .{ .primitive = .int32 }, .{ .primitive = .int32 } };
    const r_specialized = moduleinfo.specializeSignature(resolve, t.graph.module("list").?, range_sig, &range_args);
    try testing.expect(r_specialized == .function);
    try testing.expect(r_specialized.function.ret.* == .list);
    try testing.expectEqual(ast.PrimitiveKind.int32, r_specialized.function.ret.*.list.*.primitive);
}

test "moduleinfo specializes generic signatures with mode preservation" {
    // Core §10.6: function types preserve parameter mode through
    // specialization (`fn(move A) -> B` stays `fn(move int32) -> str`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "m", "fn map[A, B](move xs: list[A], f: fn(move A) -> B) -> list[B];\n");
    sources.source = source_map;

    var b = moduleinfo.Builder.init(arena_alloc, sources);
    const graph = try b.build("m");
    const resolve = moduleinfo.resolveOf(graph);
    const m = graph.module("m").?;
    const map_vm = m.valueMember("map").?;
    const sig = map_vm.type_.function;

    var int_t = cfg.Type{ .primitive = .int32 };
    const list_int = cfg.Type{ .list = &int_t };
    var str_t2 = cfg.Type{ .primitive = .str };
    const int_param_t = cfg.Type{ .primitive = .int32 };
    var fn_params = [_]cfg.Param{.{ .span = ast.Span.init(0, 0, 0), .name = .{ .span = ast.Span.init(0, 0, 0), .text = "" }, .mode = .move, .type_ = int_param_t }};
    const fn_type = cfg.Type{ .function = .{
        .params = &fn_params,
        .ret = &str_t2,
    } };
    const arg_types = [_]cfg.Type{ list_int, fn_type };
    const specialized = moduleinfo.specializeSignature(resolve, m, sig, &arg_types);
    const ft = specialized.function;
    // param 0: `move xs: list[int32]` — the list is specialized.
    try testing.expectEqual(ast.ParamMode.move, ft.params[0].mode);
    try testing.expectEqual(ast.PrimitiveKind.int32, ft.params[0].type_.list.*.primitive);
    // param 1: `f: fn(move int32) -> str` — A substituted inside fn type,
    // mode preserved.
    try testing.expectEqual(ast.ParamMode.move, ft.params[1].type_.function.params[0].mode);
    try testing.expectEqual(ast.PrimitiveKind.int32, ft.params[1].type_.function.params[0].type_.primitive);
    try testing.expectEqual(ast.PrimitiveKind.str, ft.params[1].type_.function.ret.*.primitive);
    // ret: list[B] → list[str].
    try testing.expectEqual(ast.PrimitiveKind.str, ft.ret.*.list.*.primitive);
}

test "moduleinfo resolveTypeName follows using aliases for local type members" {
    // Core §2.8: `using builtin.Option;` at module scope makes the type
    // name `Option` resolvable locally.
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\using builtin.Option;
            \\type Maybe = Option[int32];
            \\fn main() -> void {}
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const resolve = moduleinfo.resolveOf(t.graph);
    const app = t.graph.module("app").?;
    const tm = app.typeMember("Maybe").?;
    // The alias target is the named type `Option[int32]`; resolving it
    // through the using alias yields the IR-native named reference
    // (type arguments resolve in the lowering, phase2-checker.md, Type resolution).
    const target = moduleinfo.resolveType(resolve, app, &tm.decl.alias.target).?;
    try testing.expectEqualStrings("builtin.Option", resolve.typeNameOf(target.named.id).?);
}

test "moduleinfo isHostBinding distinguishes host and source modules" {
    var t = try buildGraph("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn local() -> void {}
            \\fn main() -> void { builtin.print("x"); }
        },
    });
    defer testing.allocator.destroy(t.arena);
    defer t.arena.deinit();

    const app = t.graph.module("app").?;
    const builtin = t.graph.module("builtin").?;
    try testing.expect(!app.isHostBinding("local"));
    try testing.expect(!app.isHostBinding("main"));
    // Every builtin member is a host binding (Runtime §4).
    var saw_print = false;
    for (builtin.host_bindings) |hb| {
        if (std.mem.eql(u8, hb.name.text, "print")) saw_print = true;
    }
    try testing.expect(saw_print);
}
