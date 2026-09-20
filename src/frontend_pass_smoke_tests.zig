//! Probe-corpus smoke tests for every transform / optimization pass.
//!
//! Each `probes/*.st` program is enumerated at test time (`probe_corpus.zig`)
//! and pushed through every pass family, so a new probe automatically
//! widens the smoke net and a new pass is added in exactly one place:
//!
//! - CFG lowering (HIR → AIR, with the on-the-fly emit optimizations) and
//!   the canonical text round-trip;
//! - every Pass 7–8 optimizer rewrite applied **individually** to a fresh
//!   compilation, validated and round-tripped after each — this catches a
//!   pass that only misbehaves when it runs alone, which the ordered
//!   full-sequence driver masks;
//! - the full optimized pipeline (optimizer + post-optimization drop
//!   lowering + re-validation) that `--run` consumes;
//! - the LLIR backend: `lowerLlir` → structural validation → symbolic
//!   assembly → flat binary → read → re-write (byte-identical).
//!
//! A pass runs over a freshly compiled program, not one reconstructed from
//! canonical AIR text: the text form deliberately carries no type
//! declarations (`cfg_parse.zig` interns `.unknown` decls), so the air.md
//! validator cannot run on a parsed program with aggregate constructs.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const cfg = @import("cfg.zig");
const moduleinfo = @import("moduleinfo.zig");
const frontend = @import("frontend.zig");
const lower = @import("lower.zig");
const cfg_optimize = @import("passes/cfg_optimize.zig");
const cfg_inline = @import("passes/cfg_inline.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const probe_corpus = @import("probe_corpus.zig");
const effects = @import("effects.zig");
const testing = std.testing;

/// A compiled probe plus the arena holding its borrowed source text:
/// lowering borrows identifiers from the module source, so the text must
/// outlive the compilation. `deinit` drops the compilation before the
/// source.
const Compiled = struct {
    comp: frontend.Compilation,
    source_arena: std.heap.ArenaAllocator,

    fn deinit(self: *Compiled) void {
        self.comp.deinit();
        self.source_arena.deinit();
    }

    fn program(self: *Compiled) !*const cfg.IrProgram {
        if (self.comp.program) |*p| return p;
        return error.TestUnexpectedResult;
    }
};

/// Compile one probe through the frontend with `main` as the entry.
fn compileProbe(dir: []const u8, spec: []const u8, optimize: bool) !Compiled {
    var source_arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer source_arena.deinit();
    const a = source_arena.allocator();
    const text = try probe_corpus.read(a, dir, spec);
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(a, spec, text);
    sources.source = source_map;
    const comp = try frontend.compile(testing.allocator, .{
        .entry = spec,
        .sources = sources,
        .entry_fn = "main",
        .optimize = .{ .cfg = optimize },
    });
    return .{ .comp = comp, .source_arena = source_arena };
}

/// The Pass 7–8 optimizer sub-passes, each callable over a whole program.
/// `cfg_inline.renumberPrintOrder` runs after every rewrite so the text
/// round-trip is checked the way the driver's final normalization leaves
/// it (a cross-block substitution may otherwise leave a forward reference).
const Pass = struct {
    name: []const u8,
    run: *const fn (*cfg.IrProgram, std.mem.Allocator) anyerror!void,
};

const passes = [_]Pass{
    .{ .name = "tail call", .run = cfg_optimize.tailCall },
    .{ .name = "inlining", .run = cfg_optimize.inlineCalls },
    .{ .name = "CSE", .run = cfg_optimize.cse },
    .{ .name = "copy propagation", .run = cfg_optimize.copyProp },
    .{ .name = "PRE", .run = cfg_optimize.pre },
    .{ .name = "if-conversion", .run = cfg_optimize.ifConvert },
    .{ .name = "dead-block elimination", .run = cfg_optimize.deadBlock },
    .{ .name = "drop elision", .run = cfg_optimize.dropElide },
    .{ .name = "dead-instruction elimination", .run = cfg_optimize.deadInstr },
    .{ .name = "jump threading", .run = cfg_optimize.jumpThread },
    .{ .name = "phi simplification", .run = cfg_optimize.phiSimplify },
};

test "probe pass smoke: lowering produces round-trippable AIR" {
    var corpus = try probe_corpus.list(testing.allocator, "probes");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        var c = try compileProbe("probes", spec, false);
        defer c.deinit();
        const program = try c.program();

        // The lowering + on-the-fly emit optimizations produce canonical
        // AIR that re-parses and re-prints identically (air.md §13).
        const air = try cfg.print(program, testing.allocator);
        defer testing.allocator.free(air);
        var p = cfg.Parser.init(testing.allocator);
        defer p.deinit();
        const reparsed = p.parse(air) catch |err| {
            std.debug.print("pass smoke: {s} lowering AIR does not round-trip ({s})\n", .{ spec, @errorName(err) });
            return error.TestUnexpectedResult;
        };
        const again = try cfg.print(&reparsed, testing.allocator);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(air, again);
    }
}

test "probe pass smoke: every Pass 7-8 rewrite individually" {
    var corpus = try probe_corpus.list(testing.allocator, "probes");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        for (passes) |pass| {
            var c = try compileProbe("probes", spec, false);
            defer c.deinit();
            const program = @constCast(try c.program());
            const a = c.comp.arena.allocator();

            pass.run(program, a) catch |err| {
                std.debug.print("pass smoke: {s}: {s} failed ({s})\n", .{ spec, pass.name, @errorName(err) });
                return error.TestUnexpectedResult;
            };
            if (try lower.validate(program, a)) |msg| {
                defer a.free(msg);
                std.debug.print("pass smoke: {s}: validation failed after {s}: {s}\n", .{ spec, pass.name, msg });
                return error.TestUnexpectedResult;
            }
            for (program.funcs) |f| try cfg_inline.renumberPrintOrder(f, a);

            const text = try cfg.print(program, a);
            var check = cfg.Parser.init(a);
            defer check.deinit();
            _ = check.parse(text) catch |err| {
                std.debug.print("pass smoke: {s}: AIR after {s} does not round-trip ({s})\n", .{ spec, pass.name, @errorName(err) });
                return error.TestUnexpectedResult;
            };
        }
    }
}

test "probe pass smoke: optimizer + drop lowering + LLIR backend" {
    var corpus = try probe_corpus.list(testing.allocator, "probes");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        // `optimize` runs the Pass 7–8 sequence, then the post-optimization
        // drop lowering, then re-validates and re-parses the text form
        // (frontend.md): a returned compilation is already smoke-checked.
        var c = try compileProbe("probes", spec, true);
        defer c.deinit();
        const program = try c.program();
        if (program.funcs.len == 0) {
            std.debug.print("pass smoke: {s} optimized program has no functions\n", .{spec});
            return error.TestUnexpectedResult;
        }

        // LLIR backend: lower the read-only CFG projection, validate the
        // frozen image, assemble it, and round-trip the flat binary.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var builder = cfg_lower_llir.Builder.init(a, program);
        const image = builder.lowerLlir() catch |err| {
            std.debug.print("pass smoke: {s} LLIR lowering failed ({s})\n", .{ spec, @errorName(err) });
            return error.TestUnexpectedResult;
        };
        if (try llir_validate.validate(&image, a)) |msg| {
            std.debug.print("pass smoke: {s} LLIR image failed validation: {s}\n", .{ spec, msg });
            return error.TestUnexpectedResult;
        }
        const asm_text = try lower.llirAsm(&builder, image, a);
        if (asm_text.len == 0) {
            std.debug.print("pass smoke: {s} LLIR assembly is empty\n", .{spec});
            return error.TestUnexpectedResult;
        }
        const bytes = try lower.emitBin(image, a);
        const back = try lower.readBin(a, bytes);
        const bytes2 = try lower.emitBin(back, a);
        try testing.expectEqualSlices(u8, bytes, bytes2);
    }
}

/// Compile one probe with an explicit lattice provider through the whole
/// effect chain: analysis → M2b consumers → SEG → re-validation.
fn compileProbeWithProvider(spec: []const u8, provider: *const effects.Provider) !Compiled {
    var source_arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer source_arena.deinit();
    const a = source_arena.allocator();
    const text = try probe_corpus.read(a, "probes", spec);
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(a, spec, text);
    sources.source = source_map;
    const comp = try frontend.compile(testing.allocator, .{
        .entry = spec,
        .sources = sources,
        .entry_fn = "main",
        .optimize = .{ .cfg = true, .seg = true, .hir = true },
        .provider = provider,
    });
    return .{ .comp = comp, .source_arena = source_arena };
}

// The second lattice instance (docs/effects.md §5.7) must run the *whole*
// chain — effect analysis, the M2b consumers, SEG, and every
// re-validation — not merely be selectable. Because no probe declares a
// resource the example `hierarchy` instance places in its tree (its
// domains are `host(1..7)`, chosen by an embedding), the difference the
// instance can make is precision, not a different legal conclusion, so
// the differential is expected to be verbatim.
test "lattice provider: the second instance drives a whole compile unchanged" {
    var corpus = try probe_corpus.list(testing.allocator, "probes");
    defer corpus.deinit();
    for (corpus.names) |spec| {
        var plain = try compileProbeWithProvider(spec, &effects.product_provider);
        defer plain.deinit();
        var hierarchical = try compileProbeWithProvider(spec, &effects.example_hierarchy);
        defer hierarchical.deinit();
        const a = testing.allocator;
        const plain_air = try cfg.print(try plain.program(), a);
        defer a.free(plain_air);
        const hier_air = try cfg.print(try hierarchical.program(), a);
        defer a.free(hier_air);
        try testing.expectEqualStrings(plain_air, hier_air);
    }
}

/// Compile a *two-module* probe (a host-module iface under
/// `standard_library`) through the whole chain under an explicit lattice
/// provider, with host declarations for the iface's members.
fn compileHostProbeWithProvider(provider: *const effects.Provider, host_decls: []const effects.HostDecl) !Compiled {
    var source_arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer source_arena.deinit();
    const a = source_arena.allocator();
    const app = try probe_corpus.read(a, "probes/cases", "lattice_reorder_host_app");
    const sensor = try probe_corpus.read(a, "probes/cases", "lattice_reorder_host_sensor");
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(a, "app", app);
    sources.source = source_map;
    var iface_map = std.StringHashMapUnmanaged([]const u8).empty;
    try iface_map.put(a, "sensor", sensor);
    sources.standard_library = iface_map;
    const comp = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .optimize = .{ .cfg = true, .seg = true, .hir = true },
        .provider = provider,
        .host_decls = host_decls,
    });
    return .{ .comp = comp, .source_arena = source_arena };
}

// The production `reorder` rule (docs/effects.md §10.3–§10.5) consumes
// `canSwapOperands` / `rewrite_contract.swap_operands` — the one consumer
// that makes a second lattice instance produce *different* SEG output, not
// just a different legality verdict. The probe's `sensor.read` (host(2))
// and `sensor.peek` (host(3)) are one `add`'s two operands. Under the flat
// provider the two domains conflict, the swap is refused, and the AIR keeps
// the written `peek + read` order; under `example_hierarchy` (both hosts
// are children of host(1), i.e. provably disjoint sub-trees) the rule
// canonicalizes the operand order to `read + peek`. Whole-chain AIR
// difference = item-24 acceptance (i).
test "lattice provider: the reorder rule changes the produced AIR under the second instance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = [_]effects.HostDecl{
        .{ .key = "sensor.read", .summary = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 2 }, .mode = .read }}), .stilla_execution = .forbidden },
        .{ .key = "sensor.peek", .summary = try effects.summaryOf(a, &.{.{ .resource = .{ .host = 3 }, .mode = .read }}), .stilla_execution = .forbidden },
    };

    var plain = try compileHostProbeWithProvider(&effects.product_provider, &decls);
    defer plain.deinit();
    var hierarchical = try compileHostProbeWithProvider(&effects.example_hierarchy, &decls);
    defer hierarchical.deinit();
    const plain_air = try cfg.print(try plain.program(), a);
    defer a.free(plain_air);
    const hier_air = try cfg.print(try hierarchical.program(), a);
    defer a.free(hier_air);
    try testing.expect(!std.mem.eql(u8, plain_air, hier_air));
    // The flat instance's output is the written order; the hierarchy's is
    // the canonical one — the differential is directional, not noise.
    try testing.expect(std.mem.indexOf(u8, plain_air, "sensor#peek") != null);
    const canonical = std.mem.indexOf(u8, hier_air, "sensor#read");
    const peek_after = std.mem.indexOf(u8, hier_air, "sensor#peek");
    try testing.expect(canonical != null);
    try testing.expect(peek_after != null);
    try testing.expect(canonical.? < peek_after.?);
}
