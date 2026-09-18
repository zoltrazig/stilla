//! Test file: the per-module frontend cache (PLAN item 3) — black-box
//! `frontend.compile` tests over `Options.cache`: a second compile of an
//! unchanged program performs zero lex/parse work (asserted via the
//! cache's counting hook) and produces a byte-identical AIR; a changed
//! module re-parses only itself; adding a module leaves the others
//! cached; a failed parse is never cached; cached source ids stay unique
//! so a fresh module's diagnostics resolve to the right module.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const frontend = @import("frontend.zig");
const frontend_cache = @import("frontend_cache.zig");
const moduleinfo = @import("moduleinfo.zig");
const effects = @import("effects.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const irText = helpers.irText;

/// Compile `entry` against `texts` through `cache`.
fn compileWithCache(
    cache: *frontend_cache.FrontendCache,
    entry: []const u8,
    texts: []const struct { []const u8, []const u8 },
) !frontend.Compilation {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    for (texts) |pair| {
        try source_map.put(testing.allocator, pair[0], pair[1]);
    }
    sources.source = source_map;
    return frontend.compile(testing.allocator, .{
        .entry = entry,
        .sources = sources,
        .entry_fn = "main",
        .cache = cache,
    });
}

/// The specifier whose source id `diag`'s span names, resolved through
/// the failed compilation's source list (mirrors main.zig renderDiag's
/// span→file resolution).
fn sourceNameOf(c: *const frontend.Compilation, source_id: u32) ?[]const u8 {
    for (c.sources) |s| {
        if (s.id == source_id) return s.name;
    }
    return null;
}

test "cache: an effect-environment change moves the semantic key, never the parses" {
    // docs/effects.md §13: the effect environment (host declarations,
    // domain registry, registry generation) is the semantic half of a
    // module cache key. Parsing does not depend on it, so a change must
    // leave every cached parse reusable *and* register that a phase-2/3
    // cache keyed on the fingerprint would have to invalidate.
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", "fn main() -> int32 { 0 }");
    sources.source = source_map;

    var c1 = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
    });
    defer c1.deinit();
    const parses = cache.stats.parses;
    const fp = cache.effect_environment;
    try testing.expectEqual(@as(u32, 0), cache.stats.effect_environment_changes);
    // The module's semantic key pairs its parse identity with that
    // environment fingerprint.
    const key1 = cache.semanticKey("app").?;
    try testing.expectEqualStrings("app", key1.specifier);
    try testing.expectEqual(cache.get("app").?.hash, key1.content_hash);
    try testing.expect(cache.semanticKey("absent") == null);

    // The same environment does not move the key, and the parse is
    // reused.
    var c2 = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
    });
    defer c2.deinit();
    try testing.expectEqual(parses, cache.stats.parses);
    try testing.expectEqual(@as(u32, 0), cache.stats.effect_environment_changes);
    try testing.expect(cache.effect_environment.eql(fp));
    // Same identity + same environment: the semantic key is unchanged.
    try testing.expect(key1.eql(cache.semanticKey("app").?));

    // A declaration-set change moves the key even though it names no
    // member of this program (a declaration set describes an embedding,
    // not one program) — and the parse is still reused.
    const decls = [_]effects.HostDecl{
        .{ .key = "builtin.print", .summary = effects.host_top, .stilla_execution = .forbidden },
    };
    var c3 = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
        .host_decls = &decls,
    });
    defer c3.deinit();
    try testing.expectEqual(parses, cache.stats.parses);
    try testing.expectEqual(@as(u32, 1), cache.stats.effect_environment_changes);
    try testing.expect(!cache.effect_environment.eql(fp));
    // Same identity, changed environment: the semantic key differs even
    // though the parse entry is the very same one.
    const key3 = cache.semanticKey("app").?;
    try testing.expectEqual(cache.get("app").?.hash, key3.content_hash);
    try testing.expect(!key1.eql(key3));

    // A registry-generation bump moves it too, with no declaration
    // change at all.
    var c4 = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
        .host_decls = &decls,
        .host_registry_generation = 1,
    });
    defer c4.deinit();
    try testing.expectEqual(parses, cache.stats.parses);
    try testing.expectEqual(@as(u32, 2), cache.stats.effect_environment_changes);
}

test "cache: embedded stdlib bundle modules are cached like any other" {
    // `builtin` is a comptime-constant bundle module; its content hash
    // is stable, so a program importing it reuses the bundle's parse on
    // the second compile.
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    const texts = [_]struct { []const u8, []const u8 }{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void { builtin.print(builtin.str(7)); }
            ,
        },
    };
    var c1 = try compileWithCache(&cache, "app", &texts);
    defer c1.deinit();
    try testing.expect(c1.program != null);
    const parses_after_first = cache.stats.parses;
    try testing.expect(parses_after_first >= 2); // app + the builtin bundle

    var c2 = try compileWithCache(&cache, "app", &texts);
    defer c2.deinit();
    try testing.expectEqual(parses_after_first, cache.stats.parses);
    try testing.expectEqual(parses_after_first, cache.stats.hits);
}

test "cache: an unchanged program's second compile does zero lex/parse and is byte-identical" {
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    const texts = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
        .{
            "app",
            \\const dep = import("dep");
            \\fn main() -> int32 { dep.hit() }
            ,
        },
    };

    var c1 = try compileWithCache(&cache, "app", &texts);
    defer c1.deinit();
    try testing.expect(c1.program != null);
    try testing.expectEqual(@as(u32, 2), cache.stats.parses); // app + dep parsed fresh
    const parses_after_first = cache.stats.parses;
    const out1 = try irText(&c1.program.?);
    defer testing.allocator.free(out1);

    // Second compile of the unchanged program: every module reused, zero
    // new parses, byte-identical AIR.
    var c2 = try compileWithCache(&cache, "app", &texts);
    defer c2.deinit();
    try testing.expectEqual(parses_after_first, cache.stats.parses);
    try testing.expectEqual(@as(u32, 2), cache.stats.hits);
    try testing.expectEqual(c1.graph.?.modules.len, c2.graph.?.modules.len);
    const out2 = try irText(&c2.program.?);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings(out1, out2);
}

test "cache: a changed module re-parses only itself; dependents reuse their parse" {
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    const v1 = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
        .{
            "app",
            \\const dep = import("dep");
            \\fn main() -> int32 { dep.hit() }
            ,
        },
    };

    var c1 = try compileWithCache(&cache, "app", &v1);
    defer c1.deinit();
    const out1 = try irText(&c1.program.?);
    defer testing.allocator.free(out1);
    const parses_after_first = cache.stats.parses;

    // `dep` changed content; `app` is untouched. Only dep re-parses; the
    // new behavior propagates into the AIR.
    const v2 = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 42 }" },
        .{
            "app",
            \\const dep = import("dep");
            \\fn main() -> int32 { dep.hit() }
            ,
        },
    };
    var c2 = try compileWithCache(&cache, "app", &v2);
    defer c2.deinit();
    try testing.expectEqual(parses_after_first + 1, cache.stats.parses);
    try testing.expectEqual(@as(u32, 1), cache.stats.hits); // app reused
    const out2 = try irText(&c2.program.?);
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "42") != null);
    try testing.expect(!std.mem.eql(u8, out1, out2));
}

test "cache: adding a module re-parses only the modules whose text changed" {
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    const base = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
        .{
            "app",
            \\const dep = import("dep");
            \\fn main() -> int32 { dep.hit() }
            ,
        },
    };
    var c1 = try compileWithCache(&cache, "app", &base);
    defer c1.deinit();
    const parses_after_first = cache.stats.parses;

    // `extra` joins the graph; the importer `app` must change to name
    // it (so it re-parses too), but `dep` is untouched and must be
    // reused.
    const grown = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
        .{ "extra", "fn bonus() -> int32 { 9 }" },
        .{
            "app",
            \\const dep = import("dep");
            \\const extra = import("extra");
            \\fn main() -> int32 { dep.hit() + extra.bonus() }
            ,
        },
    };
    var c2 = try compileWithCache(&cache, "app", &grown);
    defer c2.deinit();
    try testing.expectEqual(parses_after_first + 2, cache.stats.parses); // app + extra
    try testing.expectEqual(@as(u32, 1), cache.stats.hits); // dep reused
    try testing.expectEqual(@as(usize, 3), c2.graph.?.modules.len);
}

test "cache: a parse failure is never cached; the next compile re-parses" {
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    const broken = [_]struct { []const u8, []const u8 }{
        .{ "app", "fn main() { let x = ; }" },
    };
    var c1 = try compileWithCache(&cache, "app", &broken);
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(c1.diag != null);
    try testing.expectEqual(@as(u32, 1), cache.stats.parses);
    try testing.expectEqual(@as(u32, 0), cache.stats.hits);

    // Same broken source again: nothing was cached, so it parses again
    // and reports the same failure.
    var c2 = try compileWithCache(&cache, "app", &broken);
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(c2.diag != null);
    try testing.expectEqual(@as(u32, 2), cache.stats.parses);
    try testing.expectEqualStrings(c1.diag.?.message, c2.diag.?.message);
}

test "cache: a fresh module's diagnostics resolve to its own source" {
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    const with_extra = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
        .{ "extra", "fn bonus() -> int32 { 9 }" },
        .{
            "app",
            \\const dep = import("dep");
            \\const extra = import("extra");
            \\fn main() -> int32 { dep.hit() + extra.bonus() }
            ,
        },
    };
    var c1 = try compileWithCache(&cache, "app", &with_extra);
    defer c1.deinit();
    const parses_after_first = cache.stats.parses;

    // `app`/`dep` are cached (source ids 0 and 1); the re-parsed
    // `extra` draws a fresh id from the cache's counter, so its
    // parse-error span must resolve to `extra`, never to a cached
    // module's source.
    const broken_extra = [_]struct { []const u8, []const u8 }{
        .{ "dep", "fn hit() -> int32 { 7 }" },
        .{ "extra", "fn bonus() -> int32 { 9 + }" },
        .{
            "app",
            \\const dep = import("dep");
            \\const extra = import("extra");
            \\fn main() -> int32 { dep.hit() + extra.bonus() }
            ,
        },
    };
    var c2 = try compileWithCache(&cache, "app", &broken_extra);
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(c2.diag != null);
    try testing.expectEqual(parses_after_first + 1, cache.stats.parses); // only extra re-parses
    try testing.expectEqual(@as(u32, 2), cache.stats.hits); // app + dep reused
    try testing.expectEqualStrings("extra", sourceNameOf(&c2, c2.diag.?.span.source).?);
}

test "cache: an environment change flips the compile outcome while parses stay cached" {
    // The strongest form of the semantic-key claim: the *same sources*
    // compile or are rejected depending only on the effect environment
    // (a `MayExecute`-less host is the full `Top`, whose module-const
    // read wildcard §7 rejects). Parsing is environment-independent, so
    // both compiles reuse the same cached parse.
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "probe", "fn emit() -> void;");
    try source_map.put(testing.allocator, "app",
        \\const probe = import("probe");
        \\const seed: int32 = init();
        \\fn init() -> int32 { probe.emit(); 1 }
        \\fn main() -> int32 { seed }
    );
    sources.source = source_map;

    const decls = [_]effects.HostDecl{
        .{ .key = "probe.emit", .summary = effects.pure, .stilla_execution = .forbidden },
    };
    var accepted = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
        .host_decls = &decls,
    });
    defer accepted.deinit();
    try testing.expect(accepted.program != null);
    const parses = cache.stats.parses;
    const fp = cache.effect_environment;

    // Drop the declaration: the call is now `Top` and §7 rejects the
    // const initializer. The outcome flipped, the parses did not.
    var rejected = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
    });
    defer rejected.deinit();
    try testing.expect(rejected.program == null);
    try testing.expect(rejected.diag != null);
    try testing.expectEqual(parses, cache.stats.parses);
    try testing.expect(!cache.effect_environment.eql(fp));
    try testing.expectEqual(@as(u32, 1), cache.stats.effect_environment_changes);
}

test "cache: selecting a different lattice instance invalidates the effect environment" {
    var cache = frontend_cache.FrontendCache.init(testing.allocator);
    defer cache.deinit();
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app", "fn main() -> int32 { 0 }");
    var sources = moduleinfo.Sources{};
    sources.source = source_map;

    var base = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
    });
    defer base.deinit();
    const parses = cache.stats.parses;
    const fp = cache.effect_environment;
    const key = cache.semanticKey("app").?;

    // The lattice descriptor is part of the environment (docs/effects.md
    // §5.7): selecting the `hierarchy` instance moves the fingerprint,
    // and hence the semantic key, without touching the parse.
    var hierarchical = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
        .provider = &effects.example_hierarchy,
    });
    defer hierarchical.deinit();
    try testing.expectEqual(parses, cache.stats.parses);
    try testing.expect(!cache.effect_environment.eql(fp));
    try testing.expect(!key.eql(cache.semanticKey("app").?));
    try testing.expectEqual(@as(u32, 1), cache.stats.effect_environment_changes);

    // Declaring the default instance explicitly is the same environment
    // as declaring nothing, so it comes back to the original digest.
    var explicit = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .cache = &cache,
        .provider = &effects.product_provider,
    });
    defer explicit.deinit();
    try testing.expect(cache.effect_environment.eql(fp));
    try testing.expectEqual(@as(u32, 2), cache.stats.effect_environment_changes);
}
