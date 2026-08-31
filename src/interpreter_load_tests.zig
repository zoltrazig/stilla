//! Black-box loading-boundary interpreter tests: the stage-2 `setupRoot`
//! instruction path, and the M6 whole-stdlib binary round-trips plus the M7
//! module-loading (nonzero code_base, load-once, atomic publication, teardown).

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interpreter = @import("interpreter.zig");
const interpreter_loader = @import("interpreter_loader.zig");
const interpreter_host = @import("interpreter_host.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const lower = @import("lower.zig");
const checker = @import("passes/checker.zig");
const stdbundle = @import("stdbundle.zig");
const host_module = @import("host.zig");
const artifact_bundle = @import("artifact_bundle.zig");
const llir_emit_bin = @import("passes/llir_emit_bin.zig");
const stilla_asm_printer = lower.llirAsm;
const testing = std.testing;

const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;

const support = @import("interpreter_test_support.zig");
const load = support.load;
const Loaded = support.Loaded;
const CaptureAdapter = support.CaptureAdapter;
const runHand = support.runHand;
const runHandBlocks = support.runHandBlocks;
const runHandImage = support.runHandImage;
const primType = support.primType;

// ---------------------------------------------------------------------------
// Stage-2 — the load boundary (docs/interpreter-vm.md §11): the loader
// path allocates 0 for valid images. `validate` is covered in
// frontend_llir_validate_tests.zig (1 and 10,000 instructions); here the
// interpreter's *instruction path* is covered: after `setupRoot` (the
// VM's one-time frame-stack reservation), stepping a scalar program to
// termination allocates nothing — no per-instruction workspace.
// ---------------------------------------------------------------------------

test "stage-2: the instruction path runs a scalar program with 0 allocations" {
    var l = try load(
        \\fn main() -> int32 {
        \\    let a = 40;
        \\    let b = 2;
        \\    a + b
        \\}
    , false);
    defer l.deinit();
    // A failing allocator: the VM's one-time frame-stack reservation in
    // `setupRoot` is the one allowed allocation (`fail_index = 1`); any
    // instruction-path allocation surfaces as error.OutOfMemory and
    // fails the test — the acceptance measures the instruction path
    // (docs/interpreter-vm.md §11: "validate-then-run allocates 0 on
    // the instruction path"), not the one-time frame setup.
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    vm.allocator = failing.allocator();
    defer vm.allocator = testing.allocator;
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            try testing.expectEqual(@as(vm_types.Value, 42), t.normal);
            break;
        }
        try vm.drainDestroyWork();
    }
}

// ---------------------------------------------------------------------------
// M6 — end-to-end acceptance (docs/interpreter-vm.md §12, final
// row): a representative program per stdlib module plus one combined
// program is compiled, serialized to the LLIR binary (header carries the
// resolved entry — the D3 path), read back, structurally validated, and
// executed with an output-capturing host adapter. The golden termination
// and printed text must match exactly. The `load()` path above already
// verifies full per-member behavior; this section proves the whole
// serialization→load→run pipeline reproduces it.
// ---------------------------------------------------------------------------

/// Compile `src`, serialize to the LLIR binary (resolved entry in the
/// header), read it back, validate, and run with the capturing adapter;
/// assert the golden printed text and normal termination.
fn runBinRoundTrip(src: []const u8, expected: []const u8) !void {
    var sources = moduleinfo.Sources{};
    var smap = std.StringHashMapUnmanaged([]const u8).empty;
    try smap.put(testing.allocator, "app", src);
    defer smap.deinit(testing.allocator);
    sources.source = smap;
    for (stdbundle.modules) |bm| try sources.standard_library.put(testing.allocator, bm.specifier, bm.source);
    defer sources.standard_library.deinit(testing.allocator);
    var compilation = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .optimize = false,
    });
    defer compilation.deinit();
    const program = &(compilation.program orelse {
        if (compilation.diag) |d| std.log.err("COMPILE DIAG: {s}", .{d.message});
        return error.TestUnexpectedResult;
    });

    // Compile-side: lower the whole-program artifact bundle — the root
    // image plus one scoped artifact per dependency module (generic
    // instantiations live in the module that monomorphized them) — and
    // serialize the root with the resolved entry (D3). The bundle's
    // loader serves the dependency artifacts at runtime.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var bundle = try artifact_bundle.ArtifactBundle.build(arena.allocator(), program);
    const image = &bundle.root;
    const entry = bundle.entry;
    const bytes = try lower.emitBinWithEntry(image.*, entry, arena.allocator());

    // Load-side: read the binary back, confirm the header entry is
    // honored, structurally validate, then run the same image.
    var load_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer load_arena.deinit();
    var back = try lower.readBin(load_arena.allocator(), bytes);
    const got_entry = try lower.readBinEntry(bytes);
    const want_range = back.symbols[back.entry_member];
    try testing.expectEqual(want_range.start, got_entry[0]);
    try testing.expectEqual(want_range.len, got_entry[1]);
    const reject = try llir_validate.validate(&back, testing.allocator);
    if (reject) |m| {
        std.log.err("LOAD REJECT: {s}", .{m});
        testing.allocator.free(m);
        return error.TestUnexpectedResult;
    }

    var state = CaptureAdapter{};
    var term = try interpreter.runWithEntryAndLoader(
        testing.allocator,
        &back,
        entry,
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
        bundle.loaderHandle(),
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings(expected, state.buffer[0..state.len]);
}

test "M6: builtin module runs through the binary load path" {
    try runBinRoundTrip(
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print(builtin.str(40 + 2));
        \\    builtin.assert(true, "never");
        \\    let b = builtin.box(7);
        \\    builtin.print(builtin.str(builtin.unbox(move b)));
        \\}
    ,
        "42\n7\n",
    );
}

test "M6: math module runs through the binary load path" {
    try runBinRoundTrip(
        \\const math = import("math");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print(builtin.str(math.sqrt(9.0)));
        \\    builtin.print(builtin.str(math.pow(2.0, 10.0)));
        \\    builtin.print(builtin.str(math.floor(2.7)));
        \\    builtin.print(builtin.str(math.round(-2.5)));
        \\    builtin.print(builtin.str(math.abs(-3.5)));
        \\    builtin.print(builtin.str(math.pi));
        \\}
    ,
        "3\n1024\n2\n-3\n3.5\n3.1415927\n",
    );
}

test "M6: string module runs through the binary load path" {
    try runBinRoundTrip(
        \\const string = import("string");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    let s = string.concat("hel", "lo");
        \\    builtin.print(string.substring(s, 1, 3));
        \\    builtin.print(string.upper("AbC"));
        \\    builtin.print(string.lower("İ"));
        \\    builtin.print(string.replace("banana", "na", "NA"));
        \\    builtin.print(string.repeat("ab", 3));
        \\    builtin.print(string.trim("  hi  "));
        \\}
    ,
        "el\nABC\ni̇\nbaNANA\nababab\nhi\n",
    );
}

test "M6: list module runs through the binary load path" {
    try runBinRoundTrip(
        \\const lists = import("list");
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn main() -> void {
        \\    builtin.print(builtin.str(lists.len(lists.range(2, 5))));
        \\    builtin.print(builtin.str(lists.len(lists.range(3, 1))));
        \\    match (lists.range(1, 3)) {
        \\        [] => builtin.print("empty"),
        \\        [h, ..t] => builtin.print(builtin.str(h))
        \\    };
        \\    builtin.print(builtin.str(lists.is_empty(lists.range(2, 5))));
        \\    match (lists.head(lists.range(1, 3))) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("none")
        \\    };
        \\}
    ,
        "4\n0\n1\nfalse\n1\n",
    );
}

test "M6: array module runs through the binary load path" {
    try runBinRoundTrip(
        \\const array = import("array");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    let a = array.make(3, 7);
        \\    builtin.print(builtin.str(array.len::[int32](a)));
        \\    builtin.print(builtin.str(array.get::[int32](a, 1)));
        \\    let a = array.set(move a, 2, 42);
        \\    builtin.print(builtin.str(array.get::[int32](a, 2)));
        \\    let b = array.clone::[int32](a);
        \\    builtin.print(builtin.str(array.len::[int32](b)));
        \\}
    ,
        "3\n7\n42\n3\n",
    );
}

test "M6: hashmap module runs through the binary load path" {
    try runBinRoundTrip(
        \\const hashmap = import("hashmap");
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn main() -> void {
        \\    let m = hashmap.empty::[str, int32]();
        \\    let m = hashmap.insert(move m, "a", 1);
        \\    let m = hashmap.insert(move m, "b", 2);
        \\    builtin.print(builtin.str(hashmap.len::[str, int32](m)));
        \\    builtin.print(builtin.str(hashmap.contains::[str, int32](m, "b")));
        \\    match (hashmap.get::[str, int32](m, "a")) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    let (m, removed) = hashmap.remove::[str, int32](move m, "b");
        \\    match (removed) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    builtin.print(builtin.str(hashmap.len::[str, int32](m)));
        \\}
    ,
        "2\ntrue\n1\n2\n1\n",
    );
}

test "M6: one combined program across all stdlib modules runs end to end" {
    try runBinRoundTrip(
        \\const builtin = import("builtin");
        \\const math = import("math");
        \\const string = import("string");
        \\const lists = import("list");
        \\const array = import("array");
        \\const hashmap = import("hashmap");
        \\using builtin.Option;
        \\fn main() -> void {
        \\    builtin.print(string.upper(string.concat("pi=", "x")));
        \\    builtin.print(builtin.str(math.floor(math.sqrt(50.0))));
        \\    match (lists.head(lists.range(1, 4))) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("none")
        \\    };
        \\    let a = array.make(2, "x");
        \\    let a = array.set(move a, 0, string.upper("hi"));
        \\    builtin.print(array.get::[str](a, 0));
        \\    let m = hashmap.empty::[str, int32]();
        \\    let m = hashmap.insert(move m, array.get::[str](a, 1), 5);
        \\    match (hashmap.get::[str, int32](m, "x")) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    builtin.print(string.join(string.split("a-b-c", "-"), "."));
        \\}
    ,
        "PI=X\n7\n1\nHI\n5\na.b.c\n",
    );
}

/// Walk every stdlib module's declaration-only `fn` members and assert the
/// default host dispatches each — a declared binding must never fall through
/// to `.not_implemented`.
fn expectMemberCoverage(spec: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (stdbundle.modules) |bm| try source_map.put(arena.allocator(), bm.specifier, bm.source);
    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .standard_library = source_map });
    const graph = builder.build(spec) catch |err| {
        std.log.err("FAIL {s}: {s}", .{ spec, builder.diag.?.message });
        return err;
    };
    var ck = checker.Checker.init(arena.allocator());
    var ann = try ck.check(graph);
    _ = &ann;
    defer ann.deinit();

    // Each entry's graph also carries the bundle modules it imports
    // (e.g. `string` imports `builtin`), so classify every member by its
    // own module's specifier, not the entry specifier.
    for (graph.modules) |info| {
        const program = info.program orelse continue;
        for (program.items) |*item| switch (item.*) {
            .func_def => |*f| {
                if (f.body != null) continue; // ordinary Stilla source
                const member = f.name.text;
                if (!memberRecognized(info.specifier, member)) {
                    std.log.err("M6: declared stdlib member {s}#{s} has no default-host handler", .{ info.specifier, member });
                    return error.TestUnexpectedResult;
                }
            },
            else => {},
        };
    }
}

/// Recognition is the registry: a member is handled when
/// `defaultHostRegistry` resolves its (specifier, member) pair.
fn memberRecognized(spec: []const u8, member: []const u8) bool {
    return interpreter_host.defaultHostRegistry.lookup(spec, member) != null;
}

test "M6: every declaration-only stdlib member has a default-host handler" {
    for (stdbundle.modules) |m| try expectMemberCoverage(m.specifier);
}

// ---------------------------------------------------------------------------
// M7 — runtime module loading (docs/interpreter-vm.md §2–3): the loader
// resolves per-module artifacts at runtime. These tests
// pin the load invariants — load-once caching, a deterministic trap
// for a missing module, nonzero `code_base` relocation across the module
// boundary, and atomic publication (a malformed load leaves no partial
// runtime state in the `code`/`funcs` arenas or the module registry).
// ---------------------------------------------------------------------------

/// A compiled, bundle-backed multi-module program: the root image `back` is
/// read back from the binary with the resolved entry, and `bundle` provides
/// the per-module artifacts the loader serves.
const BundleRun = struct {
    bundle_arena: std.heap.ArenaAllocator,
    load_arena: std.heap.ArenaAllocator,
    compilation: frontend.Compilation,
    bundle: artifact_bundle.ArtifactBundle,
    back: llir.LlirProgram,
    entry: llir.FunctionId,

    fn deinit(self: *BundleRun) void {
        // compilation is arena-owned; deinit is a no-op on arena memory.
        self.compilation.deinit();
        self.load_arena.deinit();
        self.bundle_arena.deinit();
    }
};

/// Compile `app` from a map of custom source modules (`extras`: resolved
/// specifier → source) plus the stdlib bundle, lower the per-module artifact
/// bundle, serialize the root with its resolved entry, and read it back into
/// a validated image.
fn buildBundleRun(
    allocator: std.mem.Allocator,
    extras: []const struct { []const u8, []const u8 },
    root_src: []const u8,
) !BundleRun {
    var bundle_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer bundle_arena.deinit();
    var sources = moduleinfo.Sources{};
    try sources.source.put(bundle_arena.allocator(), "app", root_src);
    for (extras) |e| try sources.source.put(bundle_arena.allocator(), e[0], e[1]);
    for (stdbundle.modules) |bm| try sources.standard_library.put(bundle_arena.allocator(), bm.specifier, bm.source);
    // `compile` owns its own arena from `allocator` (the source slices
    // are borrowed from `bundle_arena`, which outlives the compile).
    var compilation = try frontend.compile(allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .optimize = false,
    });
    const program = &(compilation.program orelse {
        if (compilation.diag) |d| std.log.err("COMPILE DIAG: {s}", .{d.message});
        return error.TestUnexpectedResult;
    });
    var bundle = try artifact_bundle.ArtifactBundle.build(bundle_arena.allocator(), program);
    const image = &bundle.root;
    const entry = bundle.entry;
    const bytes = try lower.emitBinWithEntry(image.*, entry, bundle_arena.allocator());
    var load_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer load_arena.deinit();
    const back = try lower.readBin(load_arena.allocator(), bytes);
    return .{
        .bundle_arena = bundle_arena,
        .load_arena = load_arena,
        .compilation = compilation,
        .bundle = bundle,
        .back = back,
        .entry = entry,
    };
}

/// A `ModuleLoader` probe: counts loader invocations per symbol (to pin
/// load-once caching) and can serve a chosen symbol as garbage bytes
/// (`poison`, for atomic-publication) or as absent (`drop`, for a missing
/// module). Call-count keys live in `arena`, owned by the test.
const ProbeLoader = struct {
    bundle: *const artifact_bundle.ArtifactBundle,
    arena: *std.heap.ArenaAllocator,
    calls: std.StringHashMapUnmanaged(u32) = .empty,
    poison: ?[]const u8 = null,
    drop: ?[]const u8 = null,

    fn count(self: *const ProbeLoader, symbol: []const u8) u32 {
        return self.calls.get(symbol) orelse 0;
    }

    fn load(ud: ?*const anyopaque, alloc: std.mem.Allocator, symbol: []const u8, out: *interpreter.LoadResult) interpreter.LoadError!void {
        const self: *ProbeLoader = @ptrCast(@alignCast(@constCast(ud.?)));
        const key = self.arena.allocator().dupe(u8, symbol) catch return error.OutOfMemory;
        const c = self.calls.get(key) orelse 0;
        self.calls.put(self.arena.allocator(), key, c + 1) catch return error.OutOfMemory;
        if (self.poison) |p| {
            if (std.mem.eql(u8, p, symbol)) {
                // Allocator-owned garbage (the VM frees it after parsing).
                const garbage = alloc.alloc(u8, 64) catch return error.OutOfMemory;
                @memset(garbage, 0xff);
                out.* = .{ .bytes = garbage };
                return;
            }
        }
        if (self.drop) |p| {
            if (std.mem.eql(u8, p, symbol)) {
                out.* = .not_found;
                return;
            }
        }
        return artifact_bundle.ArtifactBundle.loader(self.bundle, alloc, symbol, out);
    }
};

test "M7: a dependency at nonzero code_base resolves and calls across the module boundary" {
    const extras = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn add(a: int32, b: int32) -> int32 { a + b }" },
    };
    var pr = try buildBundleRun(
        testing.allocator,
        &extras,
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.add(20, 22) }
        ,
    );
    defer pr.deinit();
    var term = try interpreter.runWithEntryAndLoader(testing.allocator, &pr.back, pr.entry, .{}, pr.bundle.loaderHandle());
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 42), v),
        .panic => return error.TestUnexpectedResult,
    }
}

test "M7: shared dependencies load exactly once (load-once caching)" {
    const extras = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 1 }" },
        .{ "other", "const dep = import(\"dep\"); fn go() -> int32 { dep.hit() }" },
    };
    var pr = try buildBundleRun(
        testing.allocator,
        &extras,
        \\const dep = import("dep");
        \\const other = import("other");
        \\fn main() -> int32 { dep.hit() + other.go() }
        ,
    );
    defer pr.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var probe = ProbeLoader{ .bundle = &pr.bundle, .arena = &arena };
    var term = try interpreter.runWithEntryAndLoader(testing.allocator, &pr.back, pr.entry, .{}, .{ .userdata = &probe, .load = ProbeLoader.load });
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 2), v),
        .panic => return error.TestUnexpectedResult,
    }
    // `dep` is imported by both `app` and `other`: the loader must serve it
    // exactly once; the second importer hits the runtime cache.
    try testing.expectEqual(@as(u32, 1), probe.count("dep"));
    try testing.expectEqual(@as(u32, 1), probe.count("other"));
}

test "M7: a missing module traps deterministically before any target instruction" {
    const extras = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
    };
    var pr = try buildBundleRun(
        testing.allocator,
        &extras,
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer pr.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var probe = ProbeLoader{ .bundle = &pr.bundle, .arena = &arena, .drop = "dep" };
    try testing.expectError(
        error.InvalidImage,
        interpreter.runWithEntryAndLoader(testing.allocator, &pr.back, pr.entry, .{}, .{ .userdata = &probe, .load = ProbeLoader.load }),
    );
}

test "M7: a malformed dependency load publishes no runtime state" {
    const extras = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
    };
    var pr = try buildBundleRun(
        testing.allocator,
        &extras,
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer pr.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var probe = ProbeLoader{ .bundle = &pr.bundle, .arena = &arena, .poison = "dep" };
    var vm = interpreter.VmCtx.init(testing.allocator);
    vm.provider = .{ .userdata = &probe, .load = ProbeLoader.load };
    defer vm.deinit();
    try vm.setupRootArtifact(&pr.back, pr.entry);
    const code_before = vm.loaded.code.items.len;
    const funcs_before = vm.loaded.funcs.items.len;
    var trapped = false;
    while (!vm.runtime.terminated) {
        if (vm_dispatch.step(&vm)) |_| {} else |e| {
            try testing.expect(e == error.InvalidImage);
            trapped = true;
            break;
        }
    }
    try testing.expect(trapped);
    // The failed `dep` load must leave no phantom instructions, function
    // entries, or second published module behind.
    try testing.expectEqual(code_before, vm.loaded.code.items.len);
    try testing.expectEqual(funcs_before, vm.loaded.funcs.items.len);
    try testing.expectEqual(@as(usize, 1), vm.loaded.modules.items.len);
}

test "M7: publication is atomic — a reserved instruction publishes no code" {
    const extras = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
    };
    var pr = try buildBundleRun(
        testing.allocator,
        &extras,
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer pr.deinit();
    // A shallow copy with instruction 1 replaced by a reserved word: the
    // 1:1 decode must fail partway through, yet publish nothing. (This is
    // the atomicity boundary of docs/interpreter-vm.md §8 — the earlier
    // instructions must not leak into the `code` arena on a later decode
    // failure.)
    var image = pr.back;
    const bad = llir.bytesOf(@as(u32, 71) << 21); // unassigned opcode
    const instrs = try testing.allocator.dupe(llir.Instr, image.instructions);
    defer testing.allocator.free(instrs);
    instrs[1] = bad;
    image.instructions = instrs;
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.InvalidArtifact, vm.setupRootArtifact(&image, pr.entry));
    // No phantom instructions, function entries, or published module.
    try testing.expectEqual(@as(usize, 0), vm.loaded.code.items.len);
    try testing.expectEqual(@as(usize, 0), vm.loaded.funcs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.loaded.modules.items.len);
}

/// A `ModuleLoader` that serves a fixed byte stream for one target symbol
/// and delegates everything else to the bundle.
const BytesLoader = struct {
    bundle: *const artifact_bundle.ArtifactBundle,
    target: []const u8,
    bytes: []const u8,

    fn load(ud: ?*const anyopaque, alloc: std.mem.Allocator, symbol: []const u8, out: *interpreter.LoadResult) interpreter.LoadError!void {
        const self: *BytesLoader = @ptrCast(@alignCast(@constCast(ud.?)));
        if (std.mem.eql(u8, self.target, symbol)) {
            out.* = .{ .bytes = self.bytes };
            return;
        }
        return artifact_bundle.ArtifactBundle.loader(self.bundle, alloc, symbol, out);
    }
};

test "M7: a parsed-but-rejected artifact leaks no tables" {
    // The loader serves an artifact that parses (`read` succeeds — the
    // tables are allocated) but fails structural validation because one
    // instruction is a reserved word. A leak here means the parsed tables
    // escaped cleanup; `testing.allocator` reports it at test end.
    const extras = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
    };
    var pr = try buildBundleRun(
        testing.allocator,
        &extras,
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer pr.deinit();
    // Copy `dep`'s artifact and corrupt instruction 0 to a reserved word.
    var dep_img = pr.bundle.artifacts.get("dep") orelse return error.TestUnexpectedResult;
    const instrs = try testing.allocator.dupe(llir.Instr, dep_img.instructions);
    defer testing.allocator.free(instrs);
    instrs[0] = llir.bytesOf(@as(u32, 71) << 21); // unassigned opcode
    dep_img.instructions = instrs;
    const bytes = try llir_emit_bin.write(dep_img, testing.allocator);
    // The VM frees `bytes` after parsing; ownership is transferred to it.
    var bl = BytesLoader{ .bundle = &pr.bundle, .target = "dep", .bytes = bytes };
    try testing.expectError(
        error.InvalidImage,
        interpreter.runWithEntryAndLoader(testing.allocator, &pr.back, pr.entry, .{}, .{ .userdata = &bl, .load = BytesLoader.load }),
    );
    // If the parsed tables leaked, `testing.allocator` fails this test.
}

test "M7: a published root aborts roll its code and functions back out" {
    // The entry has a parameter: publication succeeds (the root's decoded
    // code and relocated functions enter the arenas and its state becomes
    // `.loaded`), but `installRootFrame` rejects a non-parameterless
    // entry. `abortLoad` must roll the published root's code and function
    // entries back out of the arenas and unregister it.
    var pr = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{},
        \\fn main(x: int32) -> int32 { x }
        ,
    );
    defer pr.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.InvalidImage, vm.setupRootArtifact(&pr.back, pr.entry));
    // No phantom instructions, function entries, or published module.
    try testing.expectEqual(@as(usize, 0), vm.loaded.code.items.len);
    try testing.expectEqual(@as(usize, 0), vm.loaded.funcs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.loaded.modules.items.len);
}

// ---------------------------------------------------------------------------
// M8 — hot reload (docs/interpreter-vm.md §11): `reloadModule` re-fetches a
// loaded module's artifact through the provider and atomically repoints
// `module_by_symbol` at the fresh version, with rollback on failure and the
// superseded image kept resident for exactly-once teardown by `VmLoadedData.deinit`.
// ---------------------------------------------------------------------------

/// A `ModuleLoader` probe for reload tests: serves `v1` (serialized LLIR
/// bytes) on the first request for `target` and `v2` on every later
/// request; `v2 == null` serves allocator-owned garbage instead, for the
/// failed-reload path. Bytes are freshly allocated per call (the VM frees
/// them after parsing). Everything else delegates to the bundle.
const ReloadLoader = struct {
    bundle: *const artifact_bundle.ArtifactBundle,
    arena: *std.heap.ArenaAllocator,
    target: []const u8,
    v1: []const u8,
    v2: ?[]const u8,
    calls: u32 = 0,

    fn load(ud: ?*const anyopaque, alloc: std.mem.Allocator, symbol: []const u8, out: *interpreter.LoadResult) interpreter.LoadError!void {
        const self: *ReloadLoader = @ptrCast(@alignCast(@constCast(ud.?)));
        if (std.mem.eql(u8, self.target, symbol)) {
            const first = self.calls == 0;
            self.calls += 1;
            if (first) {
                const bytes = alloc.dupe(u8, self.v1) catch return error.OutOfMemory;
                out.* = .{ .bytes = bytes };
            } else if (self.v2) |v2| {
                const bytes = alloc.dupe(u8, v2) catch return error.OutOfMemory;
                out.* = .{ .bytes = bytes };
            } else {
                // Allocator-owned garbage (the VM frees it after parsing).
                const garbage = alloc.alloc(u8, 64) catch return error.OutOfMemory;
                @memset(garbage, 0xff);
                out.* = .{ .bytes = garbage };
            }
            return;
        }
        return artifact_bundle.ArtifactBundle.loader(self.bundle, alloc, symbol, out);
    }
};

test "M8: reloadModule swaps a module's artifact and the new behavior runs" {
    // The same `app` (imports `dep`, returns dep.hit()) is compiled
    // twice: dep returns 7 in the first bundle and 42 in the second.
    var v1 = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{.{ "dep", "fn hit() -> int32 { 7 }" }},
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer v1.deinit();
    var v2 = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{.{ "dep", "fn hit() -> int32 { 42 }" }},
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer v2.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dep_v1 = v1.bundle.artifacts.get("dep") orelse return error.TestUnexpectedResult;
    const dep_v2 = v2.bundle.artifacts.get("dep") orelse return error.TestUnexpectedResult;
    const v1_bytes = try llir_emit_bin.write(dep_v1, arena.allocator());
    const v2_bytes = try llir_emit_bin.write(dep_v2, arena.allocator());

    var probe = ReloadLoader{ .bundle = &v1.bundle, .arena = &arena, .target = "dep", .v1 = v1_bytes, .v2 = v2_bytes };
    var vm = interpreter.VmCtx.init(testing.allocator);
    vm.provider = .{ .userdata = &probe, .load = ReloadLoader.load };
    defer vm.deinit();

    // Load dep v1 into a quiescent VM (no root frame installed).
    const old_index = try interpreter_loader.loadModule(&vm.loaded, testing.allocator, &vm.provider, "dep");
    const old_code_len = vm.loaded.code.items.len;
    const old_funcs_len = vm.loaded.funcs.items.len;
    const old = vm.loaded.modules.items[old_index];
    try testing.expectEqualStrings("dep", old.symbol);

    // Reload with the changed artifact: atomic repoint, old image retained.
    const new_index = try vm.reloadModule("dep");
    try testing.expect(new_index != old_index);
    try testing.expectEqual(new_index, vm.loaded.module_by_symbol.get("dep").?);
    try testing.expectEqual(@as(usize, 2), vm.loaded.modules.items.len);
    try testing.expectEqual(old_code_len + dep_v2.instructions.len, vm.loaded.code.items.len);
    try testing.expectEqual(old_funcs_len + dep_v2.functions.len, vm.loaded.funcs.items.len);
    // The superseded module is intact at its old index.
    const old2 = vm.loaded.modules.items[old_index];
    try testing.expectEqual(old2.state, .loaded);
    try testing.expectEqual(dep_v1.instructions.len, old2.code_len);

    // The new behavior is observable: publish the v2 app root into the
    // same (never-started) VM and run it — its call to `dep` resolves to
    // the reloaded module and returns 42.
    try vm.setupRootArtifact(&v2.back, v2.entry);
    var term = try interpreter_host.runLoop(&vm);
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 42), v),
        .panic => return error.TestUnexpectedResult,
    }
}

test "M8: a failed reload rolls back; the old image is intact and still runs" {
    var pr = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{.{ "dep", "fn hit() -> int32 { 7 }" }},
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer pr.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dep_img = pr.bundle.artifacts.get("dep") orelse return error.TestUnexpectedResult;
    const dep_bytes = try llir_emit_bin.write(dep_img, arena.allocator());

    var probe = ReloadLoader{ .bundle = &pr.bundle, .arena = &arena, .target = "dep", .v1 = dep_bytes, .v2 = null };
    var vm = interpreter.VmCtx.init(testing.allocator);
    vm.provider = .{ .userdata = &probe, .load = ReloadLoader.load };
    defer vm.deinit();

    const old_index = try interpreter_loader.loadModule(&vm.loaded, testing.allocator, &vm.provider, "dep");
    const code_before = vm.loaded.code.items.len;
    const funcs_before = vm.loaded.funcs.items.len;

    // The reload serves garbage: it must fail with rollback, leaving the
    // old mapping and no phantom state.
    try testing.expectError(error.InvalidArtifact, vm.reloadModule("dep"));
    try testing.expectEqual(old_index, vm.loaded.module_by_symbol.get("dep").?);
    try testing.expectEqual(@as(usize, 1), vm.loaded.modules.items.len);
    try testing.expectEqual(code_before, vm.loaded.code.items.len);
    try testing.expectEqual(funcs_before, vm.loaded.funcs.items.len);
    // The old module's state is untouched.
    try testing.expectEqual(vm.loaded.modules.items[old_index].state, .loaded);

    // The old image still runs (7, not 42).
    try vm.setupRootArtifact(&pr.back, pr.entry);
    var term = try interpreter_host.runLoop(&vm);
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 7), v),
        .panic => return error.TestUnexpectedResult,
    }
}

test "M8: two consecutive reloads keep every superseded image resident" {
    // Three generations of `dep` (7, 42, 100). Each reload appends; the
    // map points at the latest; `VmLoadedData.deinit` frees each image exactly
    // once (the `testing.allocator` leak check fails otherwise).
    var g1 = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{.{ "dep", "fn hit() -> int32 { 7 }" }},
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer g1.deinit();
    var g2 = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{.{ "dep", "fn hit() -> int32 { 42 }" }},
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer g2.deinit();
    var g3 = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{.{ "dep", "fn hit() -> int32 { 100 }" }},
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer g3.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d1 = g1.bundle.artifacts.get("dep") orelse return error.TestUnexpectedResult;
    const d2 = g2.bundle.artifacts.get("dep") orelse return error.TestUnexpectedResult;
    const d3 = g3.bundle.artifacts.get("dep") orelse return error.TestUnexpectedResult;
    const b1 = try llir_emit_bin.write(d1, arena.allocator());
    const b2 = try llir_emit_bin.write(d2, arena.allocator());
    const b3 = try llir_emit_bin.write(d3, arena.allocator());

    var probe = ReloadLoader{ .bundle = &g1.bundle, .arena = &arena, .target = "dep", .v1 = b1, .v2 = b2 };
    var vm = interpreter.VmCtx.init(testing.allocator);
    vm.provider = .{ .userdata = &probe, .load = ReloadLoader.load };
    defer vm.deinit();

    const idx1 = try interpreter_loader.loadModule(&vm.loaded, testing.allocator, &vm.provider, "dep");
    // The second reload must serve the third generation, not the second:
    // swap the probe's v2 payload first.
    probe.v2 = b3;
    const idx2 = try vm.reloadModule("dep");
    probe.v2 = b3;
    const idx3 = try vm.reloadModule("dep");
    try testing.expect(idx1 != idx2 and idx2 != idx3);
    try testing.expectEqual(idx3, vm.loaded.module_by_symbol.get("dep").?);
    try testing.expectEqual(@as(usize, 3), vm.loaded.modules.items.len);
    for (vm.loaded.modules.items) |m| try testing.expectEqual(m.state, .loaded);
    var expected_code: usize = 0;
    for (vm.loaded.modules.items) |m| expected_code += m.code_len;
    try testing.expectEqual(expected_code, vm.loaded.code.items.len);
    var expected_funcs: usize = 0;
    for (vm.loaded.modules.items) |m| expected_funcs += m.image.functions.len;
    try testing.expectEqual(expected_funcs, vm.loaded.funcs.items.len);
}

test "M8: reload is refused while the VM is executing (quiesce contract)" {
    // Reload is only sound when no running frame references the old
    // image; a running VM (a root frame installed) refuses.
    var pr = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{.{ "dep", "fn hit() -> int32 { 7 }" }},
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.hit() }
        ,
    );
    defer pr.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(&pr.back, pr.entry); // starts the eager init
    try testing.expectError(error.ContextRunning, vm.reloadModule("dep"));
}

test "M8: reloading the root module repoints the root identity" {
    // A root published without starting the VM (`publishRoot` only) can
    // be reloaded; the root identity follows the fresh slot.
    var g1 = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{},
        \\fn main() -> int32 { 7 }
        ,
    );
    defer g1.deinit();
    var g2 = try buildBundleRun(
        testing.allocator,
        &[_]struct { []const u8, []const u8 }{},
        \\fn main() -> int32 { 42 }
        ,
    );
    defer g2.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b1 = try llir_emit_bin.write(g1.bundle.root, arena.allocator());
    const b2 = try llir_emit_bin.write(g2.bundle.root, arena.allocator());
    const root_symbol = interpreter_loader.imageSelfSymbol(&g1.back);
    try testing.expect(root_symbol.len > 0); // the artifact names itself

    var probe = ReloadLoader{ .bundle = &g1.bundle, .arena = &arena, .target = root_symbol, .v1 = b1, .v2 = b2 };
    var vm = interpreter.VmCtx.init(testing.allocator);
    vm.provider = .{ .userdata = &probe, .load = ReloadLoader.load };
    defer vm.deinit();

    const old_root = try interpreter_loader.publishRoot(&vm.loaded, testing.allocator, &g1.back);
    try testing.expectEqual(old_root, vm.loaded.root_module);
    const new_root = try vm.reloadModule(root_symbol);
    try testing.expect(new_root != old_root);
    try testing.expectEqual(new_root, vm.loaded.module_by_symbol.get(root_symbol).?);
    try testing.expectEqual(new_root, vm.loaded.root_module);
    try testing.expectEqualStrings(root_symbol, vm.loaded.root_symbol);
}
