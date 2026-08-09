//! Pass: module loading. In: Builder + written specifier + import span.
//! Out: a `RawModule` registered in `raws`/`by_specifier`/`raw_of`, parsed
//! and scanned for module values (`module_scan.zig`).
//! Resolution (phase1-module-graph.md, Module identity and specifier resolution; Runtime §2.6) maps a written specifier to
//! exactly one of a Stilla source module, a standard-library module, or a
//! host-provided module, deduplicated by resolved specifier (Runtime §2.1).
//! Priority order (moduleinfo.zig): embedding source map, then the
//! embedded std bundle / host std sources, then host modules, then the
//! search directories. The written specifier is canonicalized first
//! (`moduleinfo.normalizeSpecifier`): `import("m")`, `import("./m")`, and
//! `import("m.st")` name the same module.
//! The registration half lives here; the scanner (`module_scan.zig`) seeds
//! the module-value cache that materialization consumes.

const std = @import("std");
const ast = @import("stilla").ast;
const parser = @import("stilla").parser;
const stdbundle = @import("stilla").stdbundle;
const module_scan = @import("module_scan.zig");
const moduleinfo = @import("stilla").moduleinfo;

const Builder = moduleinfo.Builder;
const RawModule = moduleinfo.RawModule;
const ModuleInfo = moduleinfo.ModuleInfo;
const ModuleKind = moduleinfo.ModuleKind;

/// Resolve a written specifier to exactly one module (Runtime §2.6),
/// loading and parsing it if new. Returns null (with `diag` set) when
/// resolution fails.
pub fn load(self: *Builder, written: []const u8, span: ast.Span) !?*RawModule {
    // Canonicalize before any lookup: `import("m")`, `import("./m")`,
    // and `import("m.st")` are the same module (Runtime §2.1 dedups by
    // resolved specifier), and the search dirs read `<dir>/<spec>.st`, so
    // the `.st`/`./` forms must not silently load a different file.
    const spec = try moduleinfo.normalizeSpecifier(self.arena, written);
    if (self.by_specifier.get(spec)) |_| return self.raw_of.get(spec);
    // The AIR text form embeds the specifier in printed names (func
    // refs, call/syscall targets — air.md §9) whose identifier charset
    // the AIR lexer must lex. Reject specifiers that cannot round-trip
    // here instead of failing later as an optimizer internal error.
    if (!validSpecifier(spec)) {
        return self.failSpan(span, "module specifier '{s}' is not representable in the AIR text form (allowed: letters, digits, '_', '.')", .{written});
    }
    const stdbundle_module: ?stdbundle.Module = blk: {
        for (stdbundle.modules) |m| {
            if (std.mem.eql(u8, m.specifier, spec)) break :blk m;
        }
        break :blk null;
    };
    if (self.sources.source.get(spec)) |text| {
        return try newModule(self, spec, .source, text);
    } else if (stdbundle_module) |bm| {
        // Only the embedded bundle is intrinsic origin (Intrinsics §2):
        // caller-supplied `standard_library` extensions and source/host
        // modules load with `bundle_origin` unset, even when they spell
        // the same members.
        const raw = try newModule(self, spec, .standard_library, bm.source);
        raw.info.bundle_origin = true;
        return raw;
    } else if (self.sources.standard_library.get(spec)) |text| {
        return try newModule(self, spec, .standard_library, text);
    } else if (self.sources.host.contains(spec)) {
        return newHostModule(self, spec);
    }
    if (self.sources.search_dirs.len > 0 and self.io != null) {
        if (try loadFromSearchDirs(self, spec, span)) |raw| return raw;
    }
    return self.failSpan(span, "unresolved import specifier '{s}'", .{written});
}

/// Whether a specifier survives the AIR text round-trip: it appears in
/// printed names (`func @<specifier>.<fn>`, syscall targets) and must
/// lex as identifiers there (cfg_lex `isIdentCont`: alphanumerics, '_',
/// '.'). In particular a '-' is forbidden — the AIR lexer treats `-inf`
/// as a float literal.
fn validSpecifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
    }
    return true;
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
                self.recordDiag(span, msg);
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
        // Carry over every diagnostic the lexer/parser collected (the
        // parser's arena is the builder's, so the list is arena-owned).
        for (p.diags.items) |d| self.recordDiag(d.span, d.message);
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
