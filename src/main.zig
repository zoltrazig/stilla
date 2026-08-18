//! The Stilla frontend compiler: Stilla source → CFG IR (ir.md text form).
//!
//! Usage:
//!
//!     stilla <input.st> [--output <file>] [--module <spec>]
//!            [--entry-fn <name> | --no-entry-fn]
//!
//! The input's module specifier defaults to the file stem (`app.st` →
//! `app`), and the entry function defaults to `main` (Runtime §3.3).
//! Standard-library modules resolve against the embedded `std/` bundle;
//! unresolvable imports are a diagnostic.

const std = @import("std");
const stilla = @import("stilla");

const usage =
    \\usage: stilla <input.st> [options]
    \\
    \\Compile a Stilla source module and print its CFG IR (ir.md text form).
    \\
    \\options:
    \\  --output <file>   write the IR to <file> instead of stdout
    \\  --module <spec>   module specifier for the entry source (default: the
    \\                    input file's stem, e.g. app.st -> "app")
    \\  --entry-fn <name> entry function to mark (default: "main")
    \\  --no-entry-fn     do not select an entry function
    \\  -I <dir>          add <dir> to the import search path: an import
    \\                    "foo" that no module map resolves loads from
    \\                    <dir>/foo.st
    \\  -h, --help        show this help
    \\
;

const Options = struct {
    input: []const u8 = &.{},
    output: ?[]const u8 = null,
    module: ?[]const u8 = null,
    entry_fn: ?[]const u8 = "main",
    /// True when `--entry-fn <name>` was written on the command line (vs.
    /// the `main` default): an explicit name that does not exist is an error.
    entry_fn_explicit: bool = false,
    search_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer arg_list.deinit(gpa);
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
        defer it.deinit();
        while (it.next()) |a| try arg_list.append(gpa, a);
    }
    std.process.exit(run(io, gpa, arg_list.items));
}

/// Run the compiler: parse args, read the input, compile, print. Returns
/// the process exit code: 0 on success (including an explicit --help), 1
/// on any failure (usage error, unreadable input, unwritable output, or a
/// compile diagnostic). Splitting the exit-code mapping out of `main`
/// keeps the code paths unit-testable.
fn run(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const parsed = parseArgs(io, gpa, args) catch return 1;
    var opts = parsed orelse return 0; // --help
    defer opts.search_dirs.deinit(gpa);

    // The source text and specifier must outlive the compilation (the AST
    // references them), so they live in an arena alongside the compile.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = std.Io.Dir.cwd().readFileAlloc(io, opts.input, arena, .limited(16 * 1024 * 1024)) catch |err| {
        errPrint(io, gpa, "stilla: cannot read '{s}': {s}\n", .{ opts.input, @errorName(err) }) catch {};
        return 1;
    };
    const spec = arena.dupe(u8, opts.module orelse std.fs.path.stem(opts.input)) catch return 1;

    var sources = stilla.moduleinfo.Sources{};
    sources.source.put(arena, spec, text) catch return 1;
    sources.search_dirs = opts.search_dirs.items;

    const options = stilla.frontend.Options{
        .entry = spec,
        .sources = sources,
        .entry_fn = opts.entry_fn,
        .entry_fn_explicit = opts.entry_fn_explicit,
        .io = io,
        // The executable ships the optimized IR by default (optimizer.md):
        // the toggle is code-only, so there is no CLI flag to turn
        // it off; embedders of the library control it via Options.
        .optimize = true,
    };
    var compilation = stilla.frontend.compile(arena, options) catch return 1;
    defer compilation.deinit();

    if (compilation.program) |*program| {
        const ir = stilla.cfg.print(program, arena) catch return 1;
        // Prepend the source of every compiling module (the entry plus any
        // `-I` imports; embedded stdlib sources are excluded) as `;`
        // comments, so the IR file carries the Stilla that produced it for
        // reference. The IR lexer skips `;` comments, so the decorated
        // output still re-parses.
        var ir_text = std.ArrayList(u8).empty;
        if (compilation.graph) |g| {
            for (g.modules) |m| {
                if (m.kind != .source) continue;
                if (m.source) |src| commentSource(&ir_text, arena, m.specifier, src.text) catch return 1;
            }
        }
        ir_text.appendSlice(arena, ir) catch return 1;
        if (opts.output) |path| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ir_text.items }) catch |err| {
                errPrint(io, gpa, "stilla: cannot write '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
                return 1;
            };
        } else {
            std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, ir_text.items) catch return 1;
        }
        return 0;
    } else {
        const diag = compilation.diag orelse return 1;
        renderDiag(io, gpa, compilation.graph, compilation.sources, diag) catch {};
        return 1;
    }
}

/// Parse the command line. Returns null for an explicit --help (the only
/// way to exit 0 without compiling); a usage error returns `error.BadArgs`
/// (after printing its message and the usage), which main turns into exit
/// status 1.
fn parseArgs(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) !?Options {
    if (args.len < 2) {
        try errWrite(io, usage);
        return error.BadArgs;
    }
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, usage);
            return null;
        } else if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "--output needs a file argument");
            opts.output = args[i];
        } else if (std.mem.eql(u8, a, "--module")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "--module needs a specifier argument");
            opts.module = args[i];
        } else if (std.mem.eql(u8, a, "--entry-fn")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "--entry-fn needs a name argument");
            opts.entry_fn = args[i];
            opts.entry_fn_explicit = true;
        } else if (std.mem.eql(u8, a, "--no-entry-fn")) {
            opts.entry_fn = null;
        } else if (std.mem.eql(u8, a, "-I")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "-I needs a directory argument");
            try opts.search_dirs.append(gpa, args[i]);
        } else if (a.len > 0 and a[0] == '-') {
            const msg = try std.fmt.allocPrint(gpa, "unexpected argument '{s}'", .{a});
            defer gpa.free(msg);
            return argErr(io, gpa, msg);
        } else if (opts.input.len == 0) {
            opts.input = a;
        } else {
            const msg = try std.fmt.allocPrint(gpa, "unexpected argument '{s}'", .{a});
            defer gpa.free(msg);
            return argErr(io, gpa, msg);
        }
    }
    if (opts.input.len == 0) {
        try errWrite(io, usage);
        return error.BadArgs;
    }
    return opts;
}

fn argErr(io: std.Io, gpa: std.mem.Allocator, msg: []const u8) !?Options {
    // The caller owns `msg`: callers pass literals and heap-allocated
    // messages alike, and freeing a literal would be UB (caught by the
    // testing allocator). The allocPrint call sites free their own text.
    try errPrint(io, gpa, "stilla: {s}\n", .{msg});
    try errWrite(io, usage);
    return error.BadArgs;
}

/// Write a formatted message to stderr.
fn errPrint(io: std.Io, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(text);
    try errWrite(io, text);
}

/// Write raw bytes to stderr.
fn errWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, bytes);
}

/// Write `text` as `; `-prefixed comment lines, labeled with the module
/// specifier, for the source-reference header of the IR output.
fn commentSource(out: *std.ArrayList(u8), allocator: std.mem.Allocator, spec: []const u8, text: []const u8) !void {
    try out.appendSlice(allocator, "; === source: module \"");
    try out.appendSlice(allocator, spec);
    try out.appendSlice(allocator, "\" ===\n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, line);
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "; ===\n");
}

/// Render a diagnostic as `<source>:<line>:<col>: error: <message>`. The
/// span's source is resolved through the module graph when it is available
/// (a lowering or module-graph diagnostic); a parse failure leaves the
/// graph null but `sources` still names every loaded source, so the
/// location resolves from there. With neither, only the message is shown.
fn renderDiag(
    io: std.Io,
    gpa: std.mem.Allocator,
    graph: ?*stilla.moduleinfo.ModuleGraph,
    sources: []const *const stilla.ast.Source,
    diag: stilla.moduleinfo.Diag,
) !void {
    var name: []const u8 = "stilla";
    var loc: ?stilla.ast.Loc = null;
    if (graph) |g| {
        for (g.modules) |m| {
            if (m.source) |s| {
                if (s.id == diag.span.source) {
                    name = s.name;
                    loc = s.locOf(diag.span.start);
                    break;
                }
            }
        }
    }
    if (loc == null) {
        for (sources) |s| {
            if (s.id == diag.span.source) {
                name = s.name;
                loc = s.locOf(diag.span.start);
                break;
            }
        }
    }
    if (loc) |l| {
        try errPrint(io, gpa, "{s}:{d}:{d}: error: {s}\n", .{ name, l.line, l.column, diag.message });
    } else {
        try errPrint(io, gpa, "error: {s}\n", .{diag.message});
    }
}

// ---------------------------------------------------------------------------
// Tests (run via the exe test step; see build.zig)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseArgs parses input, module, entry-fn, and search dirs" {
    // Success-path parses do no I/O, so std.Io.failing is a safe stub.
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{
        "stilla", "app.st", "--module", "myapp", "--entry-fn", "run", "-I", "lib",
    })).?;
    defer opts.search_dirs.deinit(testing.allocator);

    try testing.expectEqualStrings("app.st", opts.input);
    try testing.expectEqualStrings("myapp", opts.module.?);
    try testing.expectEqualStrings("run", opts.entry_fn.?);
    try testing.expectEqual(@as(usize, 1), opts.search_dirs.items.len);
    try testing.expectEqualStrings("lib", opts.search_dirs.items[0]);
}

test "parseArgs defaults module and entry-fn" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expectEqualStrings("app.st", opts.input);
    try testing.expect(opts.module == null);
    try testing.expectEqualStrings("main", opts.entry_fn.?);
}

test "parseArgs --no-entry-fn clears the default" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "--no-entry-fn" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expect(opts.entry_fn == null);
}

test "parseArgs --output sets the output path" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "--output", "out.txt" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expectEqualStrings("out.txt", opts.output.?);
}

test "parseArgs collects multiple -I search dirs in order" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "-I", "a", "-I", "b", "-I", "c" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), opts.search_dirs.items.len);
    try testing.expectEqualStrings("a", opts.search_dirs.items[0]);
    try testing.expectEqualStrings("b", opts.search_dirs.items[1]);
    try testing.expectEqualStrings("c", opts.search_dirs.items[2]);
}

test "parseArgs rejects a missing input" {
    // No input: parseArgs writes usage to stderr, which fails on the
    // no-I/O stub host — the parse still rejects the invocation.
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{"stilla"}));
}

test "parseArgs rejects an unknown option" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "--bogus" }));
}

test "parseArgs rejects an option missing its value" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "--output" }));
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "-I" }));
}

test "parseArgs rejects a second positional input" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "a.st", "b.st" }));
}

// NOTE: the CLI process exit-code mapping (`run` above) is not unit-tested
// in-process: `std.testing.io` writes to fd 1, which under `zig build test`
// is the test-runner's `--listen` protocol pipe, so any test that prints
// usage text or compiles output would corrupt the protocol and hang the
// build. The exit codes are verified end-to-end by CLI probes instead.
