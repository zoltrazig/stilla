//! Dynamic test corpus: every `probes/*.st` is a small, self-contained
//! Stilla program that isolates a source-reachable IR shape. The
//! black-box suites enumerate the directory at test time (sorted), so a
//! new probe automatically joins every corpus smoke test and differential
//! instead of being added to a hardcoded list in each file.
//!
//! Test-only helper (no test blocks of its own), like
//! `frontend_test_support.zig`. `zig build test` runs at the repository
//! root — the same cwd the existing corpus tests read `probes/*.st`
//! from — so the paths here are relative and resolved with
//! `std.testing.io`.

const std = @import("std");
const testing = std.testing;

/// A snapshot of one corpus directory. The arena owns the names; the
/// caller must `deinit` after it is done iterating.
pub const Corpus = struct {
    arena: std.heap.ArenaAllocator,
    names: []const []const u8,

    pub fn deinit(self: *Corpus) void {
        self.arena.deinit();
    }
};

/// The sorted spec names of every `.st` file directly inside `dir`
/// (`probes/numeric.st` → `numeric`). Subdirectories are ignored; a
/// non-`.st` file (e.g. a binary fixture) is not part of the corpus.
pub fn list(allocator: std.mem.Allocator, dir: []const u8) !Corpus {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var d = try std.Io.Dir.cwd().openDir(testing.io, dir, .{ .iterate = true });
    defer d.close(testing.io);

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(a);
    var it = d.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".st")) continue;
        try names.append(a, try a.dupe(u8, entry.name[0 .. entry.name.len - ".st".len]));
    }
    std.mem.sort([]const u8, names.items, {}, strLess);
    return .{ .arena = arena, .names = try names.toOwnedSlice(a) };
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `dir/<spec>.st`, allocated with `allocator`.
pub fn path(allocator: std.mem.Allocator, dir: []const u8, spec: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.st", .{ dir, spec });
}

/// The source text of one corpus file, allocated with `allocator`.
pub fn read(allocator: std.mem.Allocator, dir: []const u8, spec: []const u8) ![]u8 {
    const p = try path(allocator, dir, spec);
    defer allocator.free(p);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, p, allocator, .limited(1 << 20));
}

/// Probes whose `main` intentionally traps (`builtin.panic` / a
/// statically unreachable branch): the consumers/SEG differentials pin
/// the panic instead of treating it as coverage. A new intentionally
/// trapping probe must be added here, or its differential fails loudly.
pub fn panics(spec: []const u8) bool {
    return std.mem.eql(u8, spec, "cli_panic") or std.mem.eql(u8, spec, "control_flow");
}
