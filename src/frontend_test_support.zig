//! Test support for the `frontend` test suite (`src/frontend_*_tests.zig`):
//! the whole-pipeline compilation drivers (`compileText`, `compileOpt`),
//! the AIR printer helper (`irText`), and the small string/CFG lookups
//! (`funcBody`, `findBlock`, `blockIdx`, `findFunc`) shared across the
//! split test files. No tests live here — each split file imports this
//! module and aliases the helpers locally so its test bodies are
//! unchanged.
//!
//! Not wired into `src/root.zig` (it has no test blocks); the split files
//! import it by same-directory relative path, like their other module
//! imports.

const std = @import("std");
const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const testing = std.testing;

/// Compile the entry module from the given (specifier, source) pairs with the
/// frontend pipeline, optimizer off.
pub fn compileText(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !frontend.Compilation {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    for (texts) |pair| {
        try source_map.put(testing.allocator, pair[0], pair[1]);
    }
    sources.source = source_map;
    return frontend.compile(testing.allocator, .{ .entry = entry, .sources = sources, .entry_fn = "main" });
}

/// Print a program to canonical AIR text.
pub fn irText(program: *const cfg.IrProgram) ![]u8 {
    return cfg.print(program, testing.allocator);
}

/// Compile with the mid-level optimizer on (Passes 7–8 plus the
/// post-optimization drop lowering), as the `stilla` executable does.
pub fn compileOpt(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !frontend.Compilation {
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    for (texts) |pair| {
        try source_map.put(testing.allocator, pair[0], pair[1]);
    }
    sources.source = source_map;
    return frontend.compile(testing.allocator, .{ .entry = entry, .sources = sources, .entry_fn = "main", .optimize = true });
}

/// The printed body of one function (after its `func @…` header, before
/// the closing brace), or "" when the header is absent.
pub fn funcBody(out: []const u8, header: []const u8) []const u8 {
    const hs = std.mem.indexOf(u8, out, header) orelse return "";
    const brace = std.mem.indexOfScalar(u8, out[hs..], '{').? + hs;
    const body_start = brace + 1;
    const body_end = std.mem.indexOf(u8, out[body_start..], "\n    }").? + body_start;
    return out[body_start..body_end];
}

pub fn findBlock(blocks: []const *const cfg.BasicBlock, name: []const u8) *const cfg.BasicBlock {
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.name, name)) return blk;
    }
    unreachable;
}

pub fn blockIdx(blocks: []const *const cfg.BasicBlock, name: []const u8) usize {
    for (blocks, 0..) |blk, i| {
        if (std.mem.eql(u8, blk.name, name)) return i;
    }
    unreachable;
}

pub fn findFunc(program: *const cfg.IrProgram, name: []const u8) *const cfg.IrFunc {
    for (program.funcs) |f| {
        if (std.mem.eql(u8, f.name.text, name)) return f;
    }
    unreachable;
}
