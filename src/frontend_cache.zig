//! The per-module frontend cache (PLAN item 3): avoids re-lexing and
//! re-parsing unchanged modules across `frontend.compile` calls.
//!
//! `FrontendCache` keeps one entry per resolved specifier: the source's
//! content hash plus the parsed `ast.Program` and `ast.Source`, both
//! allocated in the cache's own arena so a compile that reuses them
//! does not copy. The module load pass (passes/module_load.zig)
//! consults the cache for every source/standard-library module: a hit
//! (same specifier, same content hash, byte-equal text) registers the
//! module against the cached parse; a miss parses fresh (into the cache
//! arena) and stores. A failed parse is never stored.
//!
//! The cached artifact is the parsed AST only: phase-1 member tables
//! and the phase-2/3 side tables are re-derived every compile, so a
//! dependency change can never serve stale member data and `TypeId`s
//! stay consistent with the fresh per-compile interner. Source ids are
//! stable per specifier: a cached module keeps the id it was first
//! stored with, and fresh modules draw from the cache's monotonic
//! counter, so spans resolve correctly across changing module sets.
//!
//! Counting hook: `Stats.hits` / `Stats.parses` let embedders measure
//! the lex/parse share of repeated compiles (the cache tests assert the
//! second compile's parse delta is zero).
//!
//! Ceiling (ponytail): the arena is append-only — repeated edits to
//! one module grow it until `deinit` (per-entry arenas if a long-lived
//! edit loop shows up).

const std = @import("std");
const ast = @import("ast.zig");

pub const FrontendCache = struct {
    arena: std.heap.ArenaAllocator,
    /// Monotonic source-id counter. Every module stored by this cache
    /// drew a unique id from here, so a fresh module's id can never
    /// collide with a cached module's id in the same compile.
    next_source_id: ast.SourceId = 0,
    /// Resolved specifier → cached parse. The key slice is duped into
    /// the cache arena at store time (callers' specifiers are compile-
    /// arena-owned and would dangle once the compile ends).
    entries: std.StringHashMapUnmanaged(Entry) = .{},
    stats: Stats = .{},

    /// One cached module: the content hash (a fast validity filter — a
    /// hit is confirmed by byte-comparing the text) plus the parsed
    /// program and its source, both allocated in the cache arena. The
    /// program is const: nothing downstream mutates the AST (phase-2
    /// annotation is side-table based).
    pub const Entry = struct {
        hash: u64,
        source: *const ast.Source,
        program: *const ast.Program,
    };

    pub const Stats = struct {
        /// Modules reused from the cache (lex/parse skipped).
        hits: u32 = 0,
        /// Modules parsed fresh and stored.
        parses: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) FrontendCache {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *FrontendCache) void {
        self.arena.deinit();
    }

    /// The source id for a module parsed fresh through this cache:
    /// monotonic, so it can never collide with any id a cached module
    /// already holds.
    pub fn allocSourceId(self: *FrontendCache) ast.SourceId {
        defer self.next_source_id += 1;
        return self.next_source_id;
    }

    /// Look up one specifier's cached parse, when present.
    pub fn get(self: *const FrontendCache, specifier: []const u8) ?Entry {
        return self.entries.get(specifier);
    }

    /// Store (or replace) one specifier's cached parse. `source` and
    /// `program` must already live in this cache's arena (the load pass
    /// parses into it); the specifier key is duped into the cache arena.
    pub fn store(
        self: *FrontendCache,
        specifier: []const u8,
        hash: u64,
        source: *const ast.Source,
        program: *const ast.Program,
    ) !void {
        const key = try self.arena.allocator().dupe(u8, specifier);
        try self.entries.put(self.arena.allocator(), key, .{
            .hash = hash,
            .source = source,
            .program = program,
        });
    }
};
