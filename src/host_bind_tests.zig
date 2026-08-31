//! Typed host-binding tests (docs/host-bindings.md): a module defined as
//! a struct (`pub const symbol` + `pub fn` members) registered via
//! `register` — signature-checked glue end to end, module-userdata
//! injection, C strings through the reusable scratch, and the
//! deterministic mismatch traps.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interpreter = @import("interpreter.zig");
const host_bind = @import("host_bind.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const testing = std.testing;

const TESTDB_IFACE =
    \\fn add(x: int32, y: int32) -> int32;
    \\fn query(sql: str) -> int32;
    \\fn cquery(sql: str) -> int32;
    \\fn greet(sql: str) -> int32;
    \\fn report(v: int32) -> void;
;

/// The embedding's module context: injected as the bound functions'
/// leading `?*anyopaque` parameter (never a Stilla parameter).
const DB = struct {
    prefix: []const u8 = "ho",
    count: usize = 0,
    values: [8]i32 = undefined,
};

/// A host module defined as a struct: `pub const symbol` names the
/// module; every `pub fn` is a member binding.
const testdb = struct {
    pub const symbol = "testdb";
    pub fn add(x: i32, y: i32) i32 {
        return x + y;
    }
    pub fn query(s: host_bind.Str) i32 {
        return @intCast(s.bytes.len);
    }
    pub fn cquery(s: [*:0]const u8) callconv(.c) c_int {
        return @intCast(std.mem.span(s).len);
    }
    pub fn greet(ctx: ?*anyopaque, s: host_bind.Str) i32 {
        const db: *DB = @ptrCast(@alignCast(ctx.?));
        return @as(i32, @intCast(db.prefix.len)) + @as(i32, @intCast(s.bytes.len));
    }
    pub fn report(ctx: ?*anyopaque, v: i32) void {
        const db: *DB = @ptrCast(@alignCast(ctx.?));
        db.values[db.count] = v;
        db.count += 1;
    }
};
const testdb_desc: host_bind.ModuleDesc = host_bind.register(testdb);

/// Wrong signatures for `query` (interface: str -> int32) and `add`
/// (interface: (int32, int32) -> int32).
const bad_module = struct {
    pub const symbol = "testdb";
    pub fn query(x: i32) i32 {
        return x;
    }
    pub fn add(x: i32) i32 {
        return x;
    }
};
const bad_desc: host_bind.ModuleDesc = host_bind.register(bad_module);

/// `testdb` without the `greet` member (the interface declares it).
const no_greet_module = struct {
    pub const symbol = "testdb";
    pub fn add(x: i32, y: i32) i32 {
        return x + y;
    }
};
const no_greet_desc: host_bind.ModuleDesc = host_bind.register(no_greet_module);

// --- loader: compile "app" against the testdb interface ----------------

const Loaded = struct {
    compilation: frontend.Compilation,
    arena: std.heap.ArenaAllocator,
    image: *llir.LlirProgram,
    fids: std.StringArrayHashMapUnmanaged(llir.FunctionId) = .empty,

    fn fid(self: *const Loaded, name: []const u8) !llir.FunctionId {
        return self.fids.get(name) orelse error.TestUnexpectedResult;
    }
    fn deinit(self: *Loaded) void {
        self.fids.deinit(testing.allocator);
        self.arena.deinit();
        self.compilation.deinit();
    }
};

fn load(app: []const u8) !Loaded {
    var sources = moduleinfo.Sources{};
    var smap = std.StringHashMapUnmanaged([]const u8).empty;
    defer smap.deinit(testing.allocator);
    try smap.put(testing.allocator, "app", app);
    sources.source = smap;
    var lmap = std.StringHashMapUnmanaged([]const u8).empty;
    defer lmap.deinit(testing.allocator);
    try lmap.put(testing.allocator, "testdb", TESTDB_IFACE);
    sources.standard_library = lmap;
    var compilation = try frontend.compile(testing.allocator, .{
        .entry = "app",
        .sources = sources,
        .entry_fn = "main",
        .optimize = false,
    });
    errdefer compilation.deinit();
    const program = &(compilation.program orelse {
        if (compilation.diag) |d| std.log.err("COMPILE DIAG: {s}", .{d.message});
        return error.TestUnexpectedResult;
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try arena.allocator().create(llir.LlirProgram);
    image.* = try b.lowerLlir();
    const reject = try llir_validate.validate(image, testing.allocator);
    if (reject) |m| {
        std.log.err("LOAD REJECT: {s}", .{m});
        testing.allocator.free(m);
        return error.TestUnexpectedResult;
    }
    var fids = std.StringArrayHashMapUnmanaged(llir.FunctionId).empty;
    errdefer fids.deinit(testing.allocator);
    var it = b.func_ids.iterator();
    while (it.next()) |kv| {
        const full = kv.key_ptr.*.name.text;
        const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse 0;
        const short = if (dot < full.len - 1) full[dot + 1 ..] else full;
        try fids.put(testing.allocator, short, kv.value_ptr.*);
    }
    return .{ .compilation = compilation, .arena = arena, .image = image, .fids = fids };
}

/// Fill a caller-owned module table: the default registry plus `desc`
/// (sorted: "testdb" > "string", so appending keeps the binary-search
/// invariant). The buffer must outlive the run.
fn fillRegistry(
    db: *DB,
    desc: *const host_bind.ModuleDesc,
    out: *[interpreter.defaultHostRegistry.modules.len + 1]host_bind.RegisteredModule,
) host_bind.HostRegistry {
    @memcpy(out[0 .. out.len - 1], interpreter.defaultHostRegistry.modules);
    out[out.len - 1] = .{ .desc = desc, .userdata = db };
    return .{ .modules = out[0..] };
}

// --- tests ---------------------------------------------------------------

test "host bind: typed Zig and C bindings round-trip through the registry" {
    var db = DB{};
    var modules_buf: [interpreter.defaultHostRegistry.modules.len + 1]host_bind.RegisteredModule = undefined;
    const host = interpreter.HostCall{ .userdata = &db, .registry = fillRegistry(&db, &testdb_desc, &modules_buf) };
    var l = try load(
        \\const testdb = import("testdb");
        \\fn main() -> void {
        \\    testdb.report(testdb.add(3, 4));
        \\    testdb.report(testdb.query("hello"));
        \\    testdb.report(testdb.cquery("world"));
        \\    testdb.report(testdb.greet("hi"));
        \\}
    );
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), host);
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqual(@as(usize, 4), db.count);
    // add(3,4)=7, query("hello")=5, cquery("world")=5, greet("hi")=2+2.
    try testing.expectEqual(@as(i32, 7), db.values[0]);
    try testing.expectEqual(@as(i32, 5), db.values[1]);
    try testing.expectEqual(@as(i32, 5), db.values[2]);
    try testing.expectEqual(@as(i32, 4), db.values[3]);
}

test "host bind: signature mismatch traps before decoding" {
    // The binding's Zig signature (int32 -> int32) disagrees with the
    // interface (.st: str -> int32): the thunk's matches() check must
    // trap deterministically, never misdecode.
    var db = DB{};
    var modules_buf: [interpreter.defaultHostRegistry.modules.len + 1]host_bind.RegisteredModule = undefined;
    const host = interpreter.HostCall{ .userdata = &db, .registry = fillRegistry(&db, &bad_desc, &modules_buf) };
    var l = try load(
        \\const testdb = import("testdb");
        \\fn main() -> void { testdb.query("hi"); }
    );
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), host);
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult, // must not succeed
        .panic => |m| {
            try testing.expect(std.mem.indexOf(u8, m, "signature mismatch") != null);
        },
    }
}

test "host bind: wrong arity traps" {
    // A 1-param binding on a 2-param interface: `matches()` rejects the
    // param-count difference, so the trap is the signature mismatch
    // (the thunk's own arity check is defensive-only — call sites are
    // typechecked against the interface).
    var db = DB{};
    var modules_buf: [interpreter.defaultHostRegistry.modules.len + 1]host_bind.RegisteredModule = undefined;
    const host = interpreter.HostCall{ .userdata = &db, .registry = fillRegistry(&db, &bad_desc, &modules_buf) };
    var l = try load(
        \\const testdb = import("testdb");
        \\fn main() -> void { testdb.add(1, 2); }
    );
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), host);
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult, // must not succeed
        .panic => |m| {
            try testing.expect(std.mem.indexOf(u8, m, "signature mismatch") != null);
        },
    }
}

test "host bind: member absent from the registry traps as not implemented" {
    var db = DB{};
    var modules_buf: [interpreter.defaultHostRegistry.modules.len + 1]host_bind.RegisteredModule = undefined;
    const host = interpreter.HostCall{ .userdata = &db, .registry = fillRegistry(&db, &no_greet_desc, &modules_buf) };
    // The interface declares `greet`, but the registry's module omits it.
    var l = try load(
        \\const testdb = import("testdb");
        \\fn main() -> void { testdb.greet("hi"); }
    );
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), host);
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| {
            try testing.expect(std.mem.indexOf(u8, m, "not implemented") != null);
        },
    }
}
