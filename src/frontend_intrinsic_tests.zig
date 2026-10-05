//! Test file: `frontend intrinsics` — phase-2 expansion of embedded-bundle
//! intrinsics (Intrinsics Specification §3–§4): direct calls expand
//! through the per-member table to the same syscalls as before the
//! migration (byte-identical), the `math` constants materialize their
//! specified f32 bit patterns as typed literals (no member load), and
//! `never` intrinsics trap. Non-bundle bodyless declarations stay host
//! bindings — origin decides, not spelling (source spoofing).
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const meta = @import("meta.zig");
const frontend = @import("frontend.zig");
const lower = @import("lower.zig");
const moduleinfo = @import("moduleinfo.zig");
const checker = @import("passes/checker.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const module_load = @import("passes/module_load.zig");
const hir_build = @import("passes/hir_build.zig");
const hir_lower = @import("passes/hir_lower.zig");
const parser = @import("parser.zig");
const cfg_lower_intrinsic = @import("passes/cfg_lower_intrinsic.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const funcBody = helpers.funcBody;
const findFunc = helpers.findFunc;

// ---------------------------------------------------------------------------
// First-class function values: synthesized wrapper IrFuncs
// ---------------------------------------------------------------------------

test "first-class intrinsic value lowers to a synthesized wrapper fn_ref" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_first_class_value_wrapper");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = &c.program.?;
    const text = try irText(&program.*);
    defer testing.allocator.free(text);
    // The use site: a `fn_ref` to the synthesized wrapper — no
    // `module_ref`/`load_member` of the bundle member row.
    const main_body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, main_body, "fn_ref @app.sqrt.intrinsic.0") != null);
    try testing.expect(std.mem.indexOf(u8, main_body, "load_member") == null);
    try testing.expect(std.mem.indexOf(u8, main_body, "module_ref") == null);
    // The value flows through an ordinary indirect call inside the
    // receiver (`apply` calls its function-typed parameter).
    const apply_body = funcBody(text, "func @app.apply");
    try testing.expect(std.mem.indexOf(u8, apply_body, "= call %") != null);
    // The wrapper: parameters forwarded by mode into the same syscall
    // as the direct expansion, then returned. It occupies no member row;
    // it joins the using module's function list like a lambda.
    const f = findFunc(program, "app.sqrt.intrinsic.0");
    try testing.expectEqualStrings("p0", f.params[0].name.text);
    const wbody = funcBody(text, "func @app.sqrt.intrinsic.0");
    try testing.expect(std.mem.indexOf(u8, wbody, "%1: float32 = syscall math#sqrt, %0") != null);
    try testing.expect(std.mem.indexOf(u8, wbody, "ret %1") != null);
}

test "generic intrinsics synthesize one wrapper per concrete specialization" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_generic_wrapper_specializations");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = &c.program.?;
    const text = try irText(&program.*);
    defer testing.allocator.free(text);
    // Each specialization gets its own wrapper carrying that concrete
    // signature (`builtin.str::[int32]` ≠ `::[float32]`).
    const int_body = funcBody(text, "func @app.str.intrinsic.0");
    try testing.expect(std.mem.indexOf(u8, int_body, "syscall builtin#str") != null);
    const float_body = funcBody(text, "func @app.str.intrinsic.1");
    try testing.expect(std.mem.indexOf(u8, float_body, "syscall builtin#str") != null);
    const f0 = findFunc(program, "app.str.intrinsic.0");
    try testing.expectEqual(meta.Type{ .primitive = .int32 }, f0.params[0].type_);
    const f1 = findFunc(program, "app.str.intrinsic.1");
    try testing.expectEqual(meta.Type{ .primitive = .float32 }, f1.params[0].type_);
}

test "cross-module uses share one synthesized wrapper" {
    const lib_src = try helpers.probeSource("probes/cases", "intrinsic_cross_module_wrapper_lib");
    defer testing.allocator.free(lib_src);
    const app_src = try helpers.probeSource("probes/cases", "intrinsic_cross_module_wrapper_app");
    defer testing.allocator.free(app_src);
    var c = try compileText("app", &.{ .{ "lib", lib_src }, .{ "app", app_src } });
    defer c.deinit();

    const program = &c.program.?;
    const text = try irText(&program.*);
    defer testing.allocator.free(text);
    // Both modules reference the same wrapper; exactly one exists, and
    // it lives in whichever module lowered first (the dependency).
    var count: usize = 0;
    for (program.modules) |m| {
        for (m.funcs) |func| {
            if (std.mem.indexOf(u8, func.name.text, ".intrinsic.") != null) count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), count);
    // The wrapper lives in the dependency module that lowered first; the
    // using module references it by qualified name — proof of the
    // program-wide cache hit.
    _ = findFunc(program, "lib.sqrt.intrinsic.0");
    const lib_body = funcBody(text, "func @lib.helper");
    try testing.expect(std.mem.indexOf(u8, lib_body, "fn_ref @lib.sqrt.intrinsic.0") != null);
    const app_body = funcBody(text, "func @app.base");
    try testing.expect(std.mem.indexOf(u8, app_body, "fn_ref @lib.sqrt.intrinsic.0") != null);
}

test "never intrinsic wrapper traps after its syscall" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_never_wrapper_traps");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = &c.program.?;
    const text = try irText(&program.*);
    defer testing.allocator.free(text);
    const f = findFunc(program, "app.panic.intrinsic.0");
    // Runtime §7.1 / air.md §8.3: the call is followed by a trap and no
    // destruction runs after it.
    try testing.expect(f.entry.terminator == .trap);
    const body = funcBody(text, "func @app.panic.intrinsic.0");
    try testing.expect(std.mem.indexOf(u8, body, "syscall builtin#panic") != null);
    try testing.expect(std.mem.indexOf(u8, body, "drop ") == null);
}

test "wrapper AIR round-trips through the standalone cfg parser" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_wrapper_air_roundtrip");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    var found = false;
    for (prog.funcs) |f| {
        if (std.mem.eql(u8, f.name.text, "app.sqrt.intrinsic.0")) {
            found = true;
            try testing.expect(f.blocks.len > 0);
            try testing.expectEqual(@as(usize, 1), f.params.len);
        }
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------------
// Direct calls: host-backed expansions keep the pre-migration syscall form
// ---------------------------------------------------------------------------

test "bundle direct calls expand to the pre-migration syscalls" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_bundle_direct_calls");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    // Each module's direct call goes through the expansion table to the
    // same `(module, member)` syscall target as before (Intrinsics §4:
    // a genuine host binding is all canonical AIR carries).
    const cases = [_]struct { header: []const u8, syscall: []const u8 }{
        .{ .header = "func @app.p", .syscall = "syscall builtin#print" },
        .{ .header = "func @app.sq", .syscall = "syscall math#sqrt" },
        .{ .header = "func @app.n", .syscall = "syscall list#len" },
        .{ .header = "func @app.sl", .syscall = "syscall string#len" },
        .{ .header = "func @app.al", .syscall = "syscall array#len" },
        .{ .header = "func @app.hl", .syscall = "syscall hashmap#len" },
    };
    for (cases) |case| {
        const body = funcBody(text, case.header);
        try testing.expect(std.mem.indexOf(u8, body, case.syscall) != null);
    }
}

// ---------------------------------------------------------------------------
// math constants: materialized f32 literals with the specified bit patterns
// ---------------------------------------------------------------------------

test "math constants materialize as typed literals with the specified bits" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_math_constants");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    // No constant-slot writes anywhere: intrinsic constants have no
    // storage and `@init` never touches them (air.md §5.6).
    {
        const text = try irText(&c.program.?);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "store_member") == null);
    }

    const program = &c.program.?;
    // (member, expected f32 bit pattern) — the contract table,
    // verified against Zig `std.math`.
    const cases = [_]struct { name: []const u8, bits: u32 }{
        .{ .name = "app.get_pi", .bits = 0x40490FDB },
        .{ .name = "app.get_e", .bits = 0x402DF854 },
        .{ .name = "app.get_tau", .bits = 0x40C90FDB },
        .{ .name = "app.get_inf", .bits = 0x7F800000 },
        .{ .name = "app.get_nan", .bits = 0x7FC00000 },
    };
    for (cases) |case| {
        const f = findFunc(program, case.name);
        // Exactly one defining instruction per getter: the materialized
        // literal — no `load_member`, no `module_ref`, no slot read
        // (air.md §5.6).
        var float_consts: usize = 0;
        for (f.blocks) |blk| {
            for (blk.instrs) |ins| switch (ins.op) {
                .load_member => return error.IntrinsicStillLoadsMember,
                .module_ref => return error.IntrinsicStillReferencesModule,
                .const_ => |cv| switch (cv) {
                    .float => |x| {
                        float_consts += 1;
                        const bits: u32 = @bitCast(@as(f32, @floatCast(x)));
                        try testing.expectEqual(case.bits, bits);
                        try testing.expect(ins.results.len == 1);
                        try testing.expectEqual(meta.PrimitiveKind.float32, ins.results[0].type_.primitive);
                    },
                    else => {},
                },
                else => {},
            };
        }
        try testing.expectEqual(@as(usize, 1), float_consts);
    }
}

// ---------------------------------------------------------------------------
// never intrinsics: the syscall traps, no destruction runs after it
// ---------------------------------------------------------------------------

test "builtin.panic expands to a trapping syscall with no following drop" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_builtin_panic");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = &c.program.?;
    const f = findFunc(program, "app.die");
    const text = try irText(&program.*);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.die");
    try testing.expect(std.mem.indexOf(u8, body, "syscall builtin#panic") != null);
    // Runtime §7.1 / air.md §8.3: the call is followed by a trap
    // terminator and no destruction runs after it.
    try testing.expect(f.entry.terminator == .trap);
    try testing.expect(std.mem.indexOf(u8, body, "drop ") == null);
}

// ---------------------------------------------------------------------------
// Origin decides: same-spelled non-bundle declarations stay host bindings
// ---------------------------------------------------------------------------

test "caller-supplied stdlib extension keeps host-binding identity" {
    // A same-spelled spoof: `extra.print` mirrors `builtin.print`, but
    // the extension is not bundle-origin — it keeps host-binding
    // classification and lowers to the ordinary `extra#print` syscall,
    // never the intrinsic expansion (Intrinsics §2: source spoofing
    // does not confer intrinsic identity).
    const app_src = try helpers.probeSource("probes/cases", "intrinsic_spoofed_host_binding_app");
    defer testing.allocator.free(app_src);
    const extra_src = try helpers.probeSource("probes/cases", "intrinsic_spoofed_host_binding_extra");
    defer testing.allocator.free(extra_src);
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", app_src);
    sources.source = source_map;
    var std_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer std_map.deinit(testing.allocator);
    try std_map.put(testing.allocator, "extra", extra_src);
    sources.standard_library = std_map;

    var c = try frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "main" });
    defer c.deinit();

    // The classification is origin, not spelling: `extra.print` is a
    // host binding (never an intrinsic), so the call lowers through the
    // ordinary host path to `syscall extra#print`.
    const info = c.graph.?.module("extra").?;
    const vm = info.valueMember("print").?;
    try testing.expect(!info.bundle_origin);
    try testing.expect(vm.class == .host_binding);
    try testing.expect(!info.isIntrinsic(vm));
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.shout");
    try testing.expect(std.mem.indexOf(u8, body, "syscall extra#print") != null);
}

test "user module shadowing a bundle specifier keeps host-binding identity" {
    // Intrinsics §2: origin decides, not spelling. A caller-supplied
    // source module named `math` — shadowing the embedded bundle — is a
    // host-binding surface: its bodyless `sqrt` dispatches through the
    // ordinary host path and its bodyless `pi` stays a host constant
    // slot. The intrinsic expansion table (and its materialized bit
    // patterns) never engages.
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    const app_src = try helpers.probeSource("probes/cases", "intrinsic_shadowed_bundle_app");
    defer testing.allocator.free(app_src);
    const math_src = try helpers.probeSource("probes/cases", "intrinsic_shadowed_bundle_math");
    defer testing.allocator.free(math_src);
    try source_map.put(testing.allocator, "app", app_src);
    try source_map.put(testing.allocator, "math", math_src);
    sources.source = source_map;

    var c = try frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "main" });
    defer c.deinit();
    const program = &c.program.?;

    // The bodyless function is a host binding, lowered exactly like any
    // non-bundle declaration — the embedded bundle's `math.sqrt` entry
    // never intercepts it.
    const text = try irText(program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "syscall math#sqrt") != null);
    // The bodyless constant keeps its member row and storage slot: it is
    // a host constant, not a materialized literal — the bundle `pi`
    // (0x40490FDB) is what the intrinsic expansion materializes.
    const pi_body = funcBody(text, "func @app.get_pi");
    try testing.expect(std.mem.indexOf(u8, pi_body, "load_member") != null);
    try testing.expect(std.mem.indexOf(u8, pi_body, "0x40490FDB") == null);
    const m = moduleOf(program, "math");
    try testing.expectEqual(@as(usize, 2), m.members.?.len);
    try testing.expectEqual(@as(usize, 1), m.slots.len);
}

// ---------------------------------------------------------------------------
// The table itself: entries are explicit, there is no wildcard default
// ---------------------------------------------------------------------------

test "expansion table has explicit entries only" {
    try testing.expect(cfg_lower_intrinsic.isHostExpansion("builtin", "print"));
    try testing.expect(cfg_lower_intrinsic.isHostExpansion("math", "atan2"));
    // A future bundle member with no entry must not silently fall back to
    // a syscall (Intrinsics §3): the predicate misses it, so lowering
    // reports "intrinsic ... has no expansion".
    try testing.expect(!cfg_lower_intrinsic.isHostExpansion("math", "hypot"));
    try testing.expect(!cfg_lower_intrinsic.isHostExpansion("extra", "log"));
    try testing.expectEqual(@as(?u32, 0x40490FDB), cfg_lower_intrinsic.constBits("math", "pi"));
    try testing.expect(cfg_lower_intrinsic.constBits("math", "half_pi") == null);
}

test "first-class synthesis validates against the expansion table too" {
    // The wrapper path shares the direct-call guard: a member with no
    // table entry fails before any wrapper is synthesized — reachable
    // today only for a future bundle member, so exercised at the seam.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A minimal graph (nothing dereferences it on this path — the
    // failure happens before any graph lookup): `Lowerer.init` resolves
    // `resolveOf(graph)`, so the pointer must be a real struct, not
    // `undefined`.
    var graph = moduleinfo.ModuleGraph{
        .arena = arena,
        .modules = &.{},
        .by_specifier = .{},
        .entry = undefined,
        .type_interner = .{ .arena = arena },
    };
    var lw = lower.Lowerer.init(arena, &graph, null, false, null);
    try testing.expectError(
        error.Diagnostic,
        cfg_lower_intrinsic.intrinsicSyscallTarget(&lw, meta.Span.init(0, 0, 0), "math", "hypot"),
    );
}

// ---------------------------------------------------------------------------
// Canonical member tables and slots
// ---------------------------------------------------------------------------

/// The `IrModule` of a compiled program by specifier.
fn moduleOf(program: *const cfg.IrProgram, name: []const u8) *const cfg.IrModule {
    for (program.modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    unreachable;
}

test "all-intrinsic modules have empty member tables and empty slots" {
    // builtin/math/array: every value member is an intrinsic (air.md
    // §5.6) — no member row, no constant slot, and `@init` stays but
    // stores nothing (the empty init is preserved).
    // string/hashmap carry exactly one ordinary row each:
    // their `const builtin = import("builtin")` module value (a module
    // member is never intrinsic — it is a static reference).
    const src = try helpers.probeSource("probes/cases", "intrinsic_all_intrinsic_modules");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = &c.program.?;
    // (specifier, expected member-row count)
    const cases = [_]struct { spec: []const u8, rows: usize }{
        .{ .spec = "builtin", .rows = 0 },
        .{ .spec = "math", .rows = 0 },
        .{ .spec = "array", .rows = 0 },
        .{ .spec = "string", .rows = 1 },
        .{ .spec = "hashmap", .rows = 1 },
    };
    for (cases) |case| {
        const m = moduleOf(program, case.spec);
        try testing.expectEqual(case.rows, m.members.?.len);
        try testing.expectEqual(@as(usize, 0), m.slots.len);
        // math still carries an (empty) `@init`: module init functions
        // are unconditional except for host modules and builtin
        // (air.md §11) — the slot-free optimization is deferred.
        if (!std.mem.eql(u8, case.spec, "builtin")) try testing.expect(m.init != null);
    }
}

test "mixed member table compacts past the intrinsic rows" {
    // `list` mixes intrinsic declarations (`len`, `range` — bodyless
    // bundle functions) with ordinary source members. The canonical
    // member table holds only the ordinary members, with indexes
    // compacted past the intrinsic rows; the source-level `slot` still
    // counts every value member (air.md §7 vs §5.6).
    const src = try helpers.probeSource("probes/cases", "intrinsic_mixed_member_table");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = &c.program.?;
    const m = moduleOf(program, "list");
    const members = m.members.?;
    // The module value `builtin` (list.st's `const builtin =
    // import("builtin")`) is an ordinary static reference and keeps
    // its row; len (1) and range (2) are intrinsic and their rows are
    // gone. The remaining ordinary members compact onto the tail.
    try testing.expectEqual(@as(usize, 7), members.len);
    try testing.expectEqualStrings("is_empty", members[0].name);
    try testing.expectEqualStrings("contains", members[1].name);
    try testing.expectEqualStrings("head", members[5].name);
    // The module value `builtin` (list.st's `const builtin =
    // import("builtin")`) is an ordinary static reference and keeps its
    // row — const members materialize after the function members
    // (module_materialize steps 3 then 4), so it lands last.
    try testing.expectEqualStrings("builtin", members[6].name);
    // `is_empty`'s source-level slot is 2 (after the two intrinsics,
    // len and range); its canonical index is 0 (compacted past them).
    const info = c.graph.?.module("list").?;
    const vm = info.valueMember("is_empty").?;
    try testing.expectEqual(@as(u32, 2), vm.slot);
    try testing.expectEqual(@as(?u32, 0), info.airMemberIndex(vm));
}

test "user modules keep their member tables and constant slots" {
    // A plain user module is untouched by the compaction: its function
    // and constant members occupy rows and slots as before (air.md §7).
    const app_src = try helpers.probeSource("probes/cases", "intrinsic_user_modules_app");
    defer testing.allocator.free(app_src);
    const lib_src = try helpers.probeSource("probes/cases", "intrinsic_user_modules_lib");
    defer testing.allocator.free(lib_src);
    var c = try compileText("app", &.{ .{ "app", app_src }, .{ "lib", lib_src } });
    defer c.deinit();

    const program = &c.program.?;
    const app = moduleOf(program, "app");
    // Members in declaration order: the module value `lib`, the
    // function `id`, the constant `ratio`, and the entry `main` — all
    // ordinary, all present (no intrinsic rows to compact).
    // Function members materialize before const members
    // (module_materialize steps 3 then 4): id, main, then the module
    // value lib, then the constant ratio.
    try testing.expectEqual(@as(usize, 4), app.members.?.len);
    try testing.expectEqualStrings("id", app.members.?[0].name);
    try testing.expectEqualStrings("main", app.members.?[1].name);
    try testing.expectEqualStrings("lib", app.members.?[2].name);
    try testing.expectEqualStrings("ratio", app.members.?[3].name);
    // The constant occupies slot 0 of the module's slot table.
    try testing.expectEqual(@as(usize, 1), app.slots.len);
    // The imported module's constant member loads through its own row:
    // `lib.ratio` is a plain member. lib's member order is function
    // members first (module_materialize step 3): add at 0, ratio at 1.
    const lib = moduleOf(program, "lib");
    try testing.expectEqual(@as(usize, 2), lib.members.?.len);
    try testing.expectEqualStrings("add", lib.members.?[0].name);
    try testing.expectEqualStrings("ratio", lib.members.?[1].name);
    const text = try irText(program);
    defer testing.allocator.free(text);
    // `lib.ratio` loads through its canonical row — #1 in lib's member
    // table (add at 0, ratio at 1) — the same index the compiled member
    // table carries (air.md §7).
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "load_member %0, #1") != null);
}

test "load_member emits the compacted canonical index" {
    // End-to-end through the emitter: `lists.builtin` is the list
    // module's module value (source-level slot 8 — after the two
    // intrinsic functions len/range and the six ordinary members). The
    // intrinsic rows are gone from the member table, so the emitted
    // `load_member` carries the compacted canonical index 6; the
    // trailing `.print` member then resolves through the intrinsic path
    // to a synthesized wrapper fn_ref — no second member row.
    const src = try helpers.probeSource("probes/cases", "intrinsic_load_member_compacted_index");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = &c.program.?;
    const text = try irText(program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "load_member %0, #6") != null);
    try testing.expect(std.mem.indexOf(u8, body, "#8") == null);
    // The AIR validates — cfg_validate runs inside the frontend
    // (compileText), so a bad member index would already have failed
    // lowering; the parse-back round-trip keeps the same member rows.
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);
    try testing.expect(prog.funcs.len > 0);
}

// ---------------------------------------------------------------------------
// Failure diagnostics: supported-type constraints and no-entry
// members fail before canonical AIR (Intrinsics §3)
// ---------------------------------------------------------------------------

/// Compile one program expected to fail and assert that its diagnostic
/// contains `needle`. The message is arena-owned, so the assertion must
/// run before `deinit`.
fn expectDiag(entry: []const u8, texts: []const struct { []const u8, []const u8 }, needle: []const u8) !void {
    var c = try compileText(entry, texts);
    defer c.deinit();
    const msg = if (c.diag) |d| d.message else "(no diagnostic)";
    try testing.expect(std.mem.indexOf(u8, msg, needle) != null);
}

test "builtin.str and builtin.hash reject list types that used to compile silently" {
    // Runtime §4.2/§4.9: T is limited to {byte, int32, uint32, float32,
    // bool, str}; a list — a container, not in the set — is a
    // compile-time error before canonical AIR. These exact programs
    // compiled silently before the migration; they must now fail.
    {
        const src = try helpers.probeSource("probes/cases", "intrinsic_str_rejects_list");
        defer testing.allocator.free(src);
        try expectDiag("app", &.{.{ "app", src }}, "intrinsic 'builtin.str' does not support type 'list[int32]'");
    }
    {
        const src = try helpers.probeSource("probes/cases", "intrinsic_hash_rejects_list");
        defer testing.allocator.free(src);
        try expectDiag("app", &.{.{ "app", src }}, "intrinsic 'builtin.hash' does not support type 'list[int32]'");
    }
}

test "builtin.str rejects a named type with the type name in the diagnostic" {
    const src = try helpers.probeSource("probes/cases", "intrinsic_str_rejects_named_type");
    defer testing.allocator.free(src);
    try expectDiag("app", &.{.{ "app", src }}, "intrinsic 'builtin.str' does not support type 'builtin.Option[int32]'");
}

test "first-class str/hash specializations reject unsupported types too" {
    // The wrapper path enforces the same constraint as the direct call:
    // a synthesized wrapper would carry a signature the host cannot
    // serve (Runtime §4.2/§4.9, Intrinsics §3).
    const src = try helpers.probeSource("probes/cases", "intrinsic_first_class_str_rejects_list");
    defer testing.allocator.free(src);
    try expectDiag("app", &.{.{ "app", src }}, "intrinsic 'builtin.str' does not support type 'list[int32]'");
}

test "str/hash accept exactly the nine supported types" {
    // The full supported set (byte, int32, uint32, i64, u64, float32,
    // f64, bool, str) compiles through the expansion; nothing else does.
    const src = try helpers.probeSource("probes/cases", "intrinsic_str_hash_supported_types");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program != null);
}

test "first-class hash specialization rejects an unsupported type too" {
    // The wrapper path covers `hash` exactly like `str`: an
    // unsupported specialization is a compile-time error.
    const src = try helpers.probeSource("probes/cases", "intrinsic_first_class_hash_rejects_list");
    defer testing.allocator.free(src);
    try expectDiag("app", &.{.{ "app", src }}, "intrinsic 'builtin.hash' does not support type 'list[int32]'");
}

test "monomorphized generic user functions keep the str/hash constraint" {
    // T resolves through the checker's specialization inside a generic
    // body: the supported case compiles, the unsupported one fails on
    // the same diagnostic with the concrete T.
    const ok_src = try helpers.probeSource("probes/cases", "intrinsic_generic_str_ok");
    defer testing.allocator.free(ok_src);
    var ok = try compileText("app", &.{.{ "app", ok_src }});
    defer ok.deinit();
    try testing.expect(ok.program != null);

    const bad_src = try helpers.probeSource("probes/cases", "intrinsic_generic_str_rejects_list");
    defer testing.allocator.free(bad_src);
    try expectDiag("app", &.{.{ "app", bad_src }}, "intrinsic 'builtin.str' does not support type 'list[int32]'");
}

test "math constant bit patterns survive the AIR text round-trip" {
    // The materialized f32 literals print and re-parse bit-exactly
    // (shortest-round-trip float spelling; inf/nan spellings parse back
    // to their canonical bit patterns) — no precision loss across the
    // canonical AIR boundary.
    const src = try helpers.probeSource("probes/cases", "intrinsic_math_constants");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const prog = try p.parse(text);

    const cases = [_]struct { name: []const u8, bits: u32 }{
        .{ .name = "app.get_pi", .bits = 0x40490FDB },
        .{ .name = "app.get_e", .bits = 0x402DF854 },
        .{ .name = "app.get_tau", .bits = 0x40C90FDB },
        .{ .name = "app.get_inf", .bits = 0x7F800000 },
        .{ .name = "app.get_nan", .bits = 0x7FC00000 },
    };
    for (cases) |case| {
        var found: usize = 0;
        for (prog.funcs) |f| {
            if (!std.mem.eql(u8, f.name.text, case.name)) continue;
            for (f.blocks) |blk| {
                for (blk.instrs) |ins| switch (ins.op) {
                    .const_ => |cv| switch (cv) {
                        .float => |x| {
                            found += 1;
                            const bits: u32 = @bitCast(@as(f32, @floatCast(x)));
                            try testing.expectEqual(case.bits, bits);
                        },
                        else => {},
                    },
                    else => {},
                };
            }
        }
        try testing.expectEqual(@as(usize, 1), found);
    }
}

test "array/hashmap members that carry types only in the token/result type require explicit ::[...]" {
    // StdLib §1–§3, Core §12.2: `array.len/get/clone` and
    // `hashmap.empty/get/contains/remove/len/clone` expose no
    // instantiation info in their arguments — the type arguments must
    // be written explicitly, never inferred. The bundle declaration's
    // interface is what binds, not the spelling: a caller-supplied
    // stdlib extension named `array` keeps inference (origin guard,
    // Intrinsics §2).
    const cases = [_]struct { spec: []const u8, needle: []const u8 }{
        .{ .spec = "intrinsic_array_len_needs_explicit_type_args", .needle = "type arguments of 'array.len' must be written explicitly" },
        .{ .spec = "intrinsic_array_get_needs_explicit_type_args", .needle = "type arguments of 'array.get' must be written explicitly" },
        .{ .spec = "intrinsic_array_clone_needs_explicit_type_args", .needle = "type arguments of 'array.clone' must be written explicitly" },
        .{ .spec = "intrinsic_hashmap_len_needs_explicit_type_args", .needle = "type arguments of 'hashmap.len' must be written explicitly" },
        .{ .spec = "intrinsic_hashmap_get_needs_explicit_type_args", .needle = "type arguments of 'hashmap.get' must be written explicitly" },
        .{ .spec = "intrinsic_hashmap_empty_needs_explicit_type_args", .needle = "type arguments of 'hashmap.empty' must be written explicitly" },
    };
    for (cases) |case| {
        const src = try helpers.probeSource("probes/cases", case.spec);
        defer testing.allocator.free(src);
        try expectDiag("app", &.{.{ "app", src }}, case.needle);
    }
    // The explicit forms compile, and `hashmap.insert` still infers
    // K/V from the key and value arguments (StdLib §3).
    const ok_src = try helpers.probeSource("probes/cases", "intrinsic_explicit_type_args_ok");
    defer testing.allocator.free(ok_src);
    var ok = try compileText("app", &.{.{ "app", ok_src }});
    defer ok.deinit();
    try testing.expect(ok.program != null);
}

test "caller-supplied array extension keeps inferred type arguments" {
    // The explicit-argument requirement is origin-guarded (Intrinsics
    // §2): a same-spelled stdlib extension is the caller's own
    // interface and keeps ordinary inference. The source map shadows
    // the embedded bundle (module_load priority), so the module is not
    // bundle-origin and the constraint does not bind it.
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    const app_src = try helpers.probeSource("probes/cases", "intrinsic_spoofed_array_app");
    defer testing.allocator.free(app_src);
    const array_src = try helpers.probeSource("probes/cases", "intrinsic_spoofed_array_module");
    defer testing.allocator.free(array_src);
    try source_map.put(testing.allocator, "app", app_src);
    try source_map.put(testing.allocator, "array", array_src);
    sources.source = source_map;

    var c = try frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "main" });
    defer c.deinit();
    try testing.expect(c.program != null);
}

test "hashmap Copy constraints keep rejecting unique values through the expansion" {
    // The K/V Copy constraint is enforced by the plain key/value
    // parameters of the declared signature at the call site — the
    // expansion path lowers arguments exactly like the host-binding
    // path, so a unique V (any is unique) still fails.
    const bad_src = try helpers.probeSource("probes/cases", "intrinsic_hashmap_unique_rejected");
    defer testing.allocator.free(bad_src);
    try expectDiag("app", &.{.{ "app", bad_src }}, "unique");
    // The specialized signature still rides the syscall for supported
    // uses: explicit ::[...] args reach the syscall's signature.
    const ok_src = try helpers.probeSource("probes/cases", "intrinsic_hashmap_copy_ok");
    defer testing.allocator.free(ok_src);
    var ok = try compileText("app", &.{.{ "app", ok_src }});
    defer ok.deinit();
    try testing.expect(ok.program != null);
}

// ---------------------------------------------------------------------------
// No expansion entry: a future bundle member fails before canonical AIR
// ---------------------------------------------------------------------------

/// Parse `text` and pre-register it as a module of `builder` with the
/// given kind, setting `bundle_origin` exactly as `module_load.load`
/// sets it for the embedded bundle. The embedded bundle is fixed at
/// compile time, so the "future bundle member" negative cases — a
/// bodyless declaration with no expansion entry — can only be
/// exercised through a synthetic bundle-origin module registered here,
/// before `build` runs.
fn registerModule(builder: *moduleinfo.Builder, spec: []const u8, text: []const u8, kind: moduleinfo.ModuleKind, bundle: bool) !*moduleinfo.ModuleInfo {
    const arena = builder.arena;
    const source = try arena.create(ast.Source);
    source.* = try ast.Source.init(arena, spec, builder.next_source_id, text);
    builder.next_source_id += 1;
    var p = parser.Parser.init(arena);
    const program = try arena.create(ast.Program);
    program.* = p.parse(source) catch |err| {
        if (p.diag) |d| builder.diag = .{ .span = d.span, .message = d.message };
        return err;
    };
    const raw = try module_load.newRawModule(builder, spec, kind, source, program);
    if (bundle) raw.info.bundle_origin = true;
    return raw.info;
}

/// Drive the whole pipeline (phases 1–3) over `app_source` with a
/// synthetic bundle-origin module `fut` (bodyless members with no
/// expansion entries) and assert that the first diagnostic contains
/// `needle`.
fn lowerWithBundleModule(app_source: []const u8, fut_source: []const u8, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", app_source);
    sources.source = source_map;

    var builder = moduleinfo.Builder.init(arena, sources);
    // The entry module first, as a source module (the builder treats
    // raws[0] as the entry), then the synthetic bundle module — loaded
    // like an embedded bundle member (standard-library kind, origin
    // set); `load` finds both through by_specifier, and the worklist
    // expansion picks up `fut` from app's import edge.
    _ = try registerModule(&builder, "app", app_source, .source, false);
    _ = try registerModule(&builder, "fut", fut_source, .standard_library, true);

    const graph = try builder.build("app");
    var ck = checker.Checker.init(arena);
    _ = ck.check(graph) catch |err| switch (err) {
        error.Diagnostic => {
            try testing.expect(std.mem.indexOf(u8, ck.diag.?.message, needle) != null);
            return;
        },
        else => return err,
    };

    // The frontend lowers exclusively through the HIR seam — build
    // the canonical HIR from the checker output, then lower it. The
    // diagnostic may surface from either stage (builder or lowerer).
    var bdiag: moduleinfo.Diag = undefined;
    const built = hir_build.buildProgramDiag(arena, graph, &ck.annotation, &bdiag) catch |err| switch (err) {
        error.Diagnostic => {
            const msg = if (bdiag.message.len > 0) bdiag.message else "(HIR build failed)";
            if (std.mem.indexOf(u8, msg, needle) == null) std.debug.print("bundle diag (build): {s}\n", .{msg});
            try testing.expect(std.mem.indexOf(u8, msg, needle) != null);
            return;
        },
        else => return err,
    };
    var lowerer = lower.Lowerer.init(arena, graph, "main", true, &ck.annotation);
    _ = hir_lower.lowerProgram(&lowerer, built) catch |err| switch (err) {
        error.Diagnostic => {
            const msg = if (lowerer.diag) |d| d.message else "(lowering failed, no diagnostic)";
            if (std.mem.indexOf(u8, msg, needle) == null) std.debug.print("bundle diag (lower): {s}\n", .{msg});
            try testing.expect(std.mem.indexOf(u8, msg, needle) != null);
            return;
        },
        else => return err,
    };
    try testing.expect(false); // expected a diagnostic, got a compiled program
}

test "bundle function member without an expansion entry fails before canonical AIR" {
    // A future bundle member (bodyless, no table entry) must not fall
    // back to a syscall: expansion reports the missing entry and
    // compilation fails before canonical AIR (Intrinsics §3). The
    // synthetic module is bundle-origin — same classification the
    // embedded bundle gets from `module_load` — so spelling alone cannot
    // bypass the table.
    const app_src = try helpers.probeSource("probes/cases", "intrinsic_synthetic_bundle_fn_app");
    defer testing.allocator.free(app_src);
    const fut_src = try helpers.probeSource("probes/cases", "intrinsic_synthetic_bundle_fn_fut");
    defer testing.allocator.free(fut_src);
    try lowerWithBundleModule(app_src, fut_src, "intrinsic 'fut.future_op' has no expansion");
}

test "bundle constant without a materialization entry fails before canonical AIR" {
    // The same guard on the constant side: an intrinsic constant the
    // frontend cannot materialize is a compile error — there is no host
    // constant slot for it (air.md §5.6, Intrinsics §3).
    const app_src = try helpers.probeSource("probes/cases", "intrinsic_synthetic_bundle_const_app");
    defer testing.allocator.free(app_src);
    const fut_src = try helpers.probeSource("probes/cases", "intrinsic_synthetic_bundle_const_fut");
    defer testing.allocator.free(fut_src);
    try lowerWithBundleModule(app_src, fut_src, "intrinsic 'fut.magic_constant' has no expansion");
}

// ---------------------------------------------------------------------------
// LLIR boundary: no intrinsic representation survives past the CFG
// ---------------------------------------------------------------------------

test "LLIR carries no intrinsic representation — host references are (module, name) only" {
    // Intrinsics §5: the LLIR image records no intrinsic identity, member
    // row, or slot for expanded members. Every intrinsic use lowers to
    // an ordinary `syscall` whose dispatch target is a `HostBinding`
    // (module_id, member-name range in the strings blob, Instruction Set
    // §8) — the symbolic projection renders `@builtin.print`,
    // `@math.sqrt`, `@list.len` — and all-intrinsic modules carry empty
    // member/slot sections in their descriptors.
    const src = try helpers.probeSource("probes/cases", "intrinsic_llir_no_representation");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    // The three intrinsic uses project as ordinary host calls by name.
    const asm_text = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm_text);
    try testing.expect(std.mem.indexOf(u8, asm_text, "@builtin.print") != null);
    try testing.expect(std.mem.indexOf(u8, asm_text, "@math.sqrt") != null);
    try testing.expect(std.mem.indexOf(u8, asm_text, "@list.len") != null);

    // The bindings table dispatches by (module_id, name): the member
    // name lives in the strings blob as a `{start, len}` range — no
    // member-row index participates.
    var seen_print = false;
    var seen_sqrt = false;
    var seen_len = false;
    for (image.imports) |imp| {
        const mr = image.symbols[imp.module_sym];
        const fr = image.symbols[imp.member_sym];
        const mname = image.strings[mr.start..][0..mr.len];
        const name = image.strings[fr.start..][0..fr.len];
        if (std.mem.eql(u8, mname, "builtin") and std.mem.eql(u8, name, "print")) seen_print = true;
        if (std.mem.eql(u8, mname, "math") and std.mem.eql(u8, name, "sqrt")) seen_sqrt = true;
        if (std.mem.eql(u8, mname, "list") and std.mem.eql(u8, name, "len")) seen_len = true;
    }
    try testing.expect(seen_print and seen_sqrt and seen_len);

    // All-intrinsic modules keep no constant slots: nothing in the
    // image represents an intrinsic beyond its symbol and imports.
    try testing.expectEqual(@as(usize, 0), image.module_slots.len);
}
