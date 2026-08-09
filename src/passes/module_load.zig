//! Pass: module loading. In: Builder + written specifier + import span.
//! Out: a `RawModule` registered in `raws`/`by_specifier`/`raw_of`, parsed
//! and scanned for module values (`module_scan.zig`).
//!
//! Resolution (frontend §3.1, Runtime §2.6) maps a written specifier to
//! exactly one of a Stilla source module, a standard-library module, or a
//! host-provided module, deduplicated by resolved specifier (Runtime §2.1).
//! The registration half lives here; the scanner (`module_scan.zig`) seeds
//! the module-value cache that materialization consumes.

const std = @import("std");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const stdbundle = @import("../stdbundle.zig");
const module_scan = @import("module_scan.zig");
const moduleinfo = @import("../moduleinfo.zig");

const Builder = moduleinfo.Builder;
const RawModule = moduleinfo.RawModule;
const ModuleInfo = moduleinfo.ModuleInfo;
const ModuleKind = moduleinfo.ModuleKind;

/// Resolve a written specifier to exactly one module (Runtime §2.6),
/// loading and parsing it if new. Returns null (with `diag` set) when
/// resolution fails.
pub fn load(self: *Builder, written: []const u8, span: ast.Span) !?*RawModule {
    if (self.by_specifier.get(written)) |_| return self.raw_of.get(written);
    const stdbundle_module: ?stdbundle.Module = blk: {
        for (stdbundle.modules) |m| {
            if (std.mem.eql(u8, m.specifier, written)) break :blk m;
        }
        break :blk null;
    };
    if (self.sources.source.get(written)) |text| {
        return try newModule(self, written, .source, text);
    } else if (stdbundle_module) |bm| {
        return try newModule(self, written, .standard_library, bm.source);
    } else if (self.sources.standard_library.get(written)) |text| {
        return try newModule(self, written, .standard_library, text);
    } else if (self.sources.host.contains(written)) {
        return newHostModule(self, written);
    }
    if (self.sources.search_dirs.len > 0 and self.io != null) {
        if (try loadFromSearchDirs(self, written, span)) |raw| return raw;
    }
    return self.failSpan(span, "unresolved import specifier '{s}'", .{written});
}

/// Resolve a written specifier through the search directories, in
/// order: read `<dir>/<specifier>.st` and load the first that exists.
/// Returns null when no directory contains the file.
fn loadFromSearchDirs(self: *Builder, written: []const u8, span: ast.Span) !?*RawModule {
    const io = self.io orelse return null;
    for (self.sources.search_dirs) |dir| {
        const file_name = std.fmt.allocPrint(self.arena, "{s}.st", .{written}) catch return error.OutOfMemory;
        const path = std.fs.path.join(self.arena, &.{ dir, file_name }) catch return error.OutOfMemory;
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.BadPathName => continue,
            else => {
                const msg = std.fmt.allocPrint(self.arena, "cannot read '{s}': {s}", .{ path, @errorName(err) }) catch return error.OutOfMemory;
                self.diag = .{ .span = span, .message = msg };
                return error.Diagnostic;
            },
        };
        return try newModule(self, written, .source, text);
    }
    return null;
}

fn newModule(self: *Builder, specifier: []const u8, kind: ModuleKind, text: []const u8) !*RawModule {
    const source = try self.arena.create(ast.Source);
    source.* = try ast.Source.init(self.arena, specifier, self.next_source_id, text);
    self.next_source_id += 1;
    try self.loaded_sources.append(self.arena, source);

    var p = parser.Parser.init(self.arena);
    // The parsed program outlives this frame (module info is
    // arena-owned), so allocate it in the arena: storing `&program`
    // (a stack local) would leave every module aliasing the same,
    // later-overwritten AST.
    const program = try self.arena.create(ast.Program);
    program.* = p.parse(source) catch |err| {
        const d = p.diag orelse return err;
        self.diag = .{ .span = d.span, .message = d.message };
        return err;
    };
    return try newRawModule(self, specifier, kind, source, program);
}

fn newHostModule(self: *Builder, specifier: []const u8) !*RawModule {
    return try newRawModule(self, specifier, .host, null, null);
}

/// The registration half of module creation: allocate the `ModuleInfo`
/// and `RawModule`, publish them in the builder's maps, then hand the
/// parsed program to the scanner (`module_scan.zig`) to seed module
/// values.
pub fn newRawModule(
    self: *Builder,
    specifier: []const u8,
    kind: ModuleKind,
    source: ?*const ast.Source,
    program: ?*const ast.Program,
) !*RawModule {
    const info = try self.arena.create(ModuleInfo);
    info.* = .{
        .specifier = specifier,
        .kind = kind,
        .source = source,
        .program = program,
        .imports = &.{},
        .values = &.{},
        .types = &.{},
        .using_aliases = &.{},
        .host_bindings = &.{},
        .module_values = .{},
        .value_index = .{},
        .type_index = .{},
        .alias_index = .{},
    };
    const raw = try self.arena.create(RawModule);
    raw.* = .{
        .info = info,
        .index = self.raws.items.len,
        .import_specs = .empty,
        .consts = .empty,
        .module_values = .empty,
    };
    try self.raws.append(self.arena, raw);
    try self.by_specifier.put(self.arena, specifier, info);
    try self.raw_of.put(self.arena, specifier, raw);

    if (program) |prog| {
        try module_scan.scanModule(self, raw, prog);
    }
    return raw;
}
