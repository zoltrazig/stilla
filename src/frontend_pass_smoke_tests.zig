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
        .optimize = optimize,
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
