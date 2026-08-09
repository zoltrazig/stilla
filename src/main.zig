//! The Stilla frontend compiler: Stilla source → AIR (air.md text
//! form), the symbolic LLIR assembly with `--emit-asm` (5.1), or the
//! LLIR binary (bytecode) with `--emit-bin <file>` (6.3) — or, with
//! `--run`, an interpreter: a source file compiles and runs, an input
//! starting with the LLIR magic loads via `readBin` and runs from its
//! header entry id.
//!
//! Usage:
//!
//!     stilla [--output <file>] [--module <spec>]
//!            [--entry-fn <name> | --no-entry-fn]
//!            [--emit-asm | --emit-bin <file> | --run] <input>
//!
//! `--run` exit codes: 0 normal termination, 1 Stilla panic (the owned
//! message goes to stderr), 2 load/compile error.
//!
//! Options precede the input file (Unix convention); option parsing
//! stops at the first positional argument, and `--` ends it explicitly.
//!
//! The input's module specifier defaults to the file stem (`app.st` →
//! `app`), and the entry function defaults to `main` (Runtime §3.3).
//! Standard-library modules resolve against the embedded `std/` bundle;
//! unresolvable imports are a diagnostic.

const std = @import("std");
const stilla = @import("stilla");

const usage =
    \\usage: stilla [options] <input>
    \\
    \\Compile a Stilla source module and print its AIR (air.md text form) —
    \\or, with --emit-asm, the symbolic LLIR assembly (5.3), or with
    \\--emit-bin <file>, the LLIR binary (bytecode, 6.3); `<input>` is the
    \\source file or a binary produced by --emit-bin. With --run, compile
    \\(or load) and execute.
    \\Options precede the input
    \\file (Unix convention): option parsing stops at the first positional
    \\argument, and a literal `--` ends it explicitly.
    \\
    \\options:
    \\  --output <file>   write the output to <file> instead of stdout
    \\  --emit-asm        emit the LLIR assembly (symbolic) instead of
    \\                    the AIR (5.1)
    \\  --emit-bin <file> emit the LLIR binary (bytecode) to <file> (6.3);
    \\                    mutually exclusive with --emit-asm and --output
    \\  --run             compile (or load, for an input starting with the
    \\                    LLIR magic) and execute; mutually exclusive with
    \\                    --emit-asm, --emit-bin, --output, --no-entry-fn
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
    /// True when `--emit-asm` was given: print the symbolic LLIR
    /// assembly (5.3) instead of the AIR (5.1, passes/llir_asm.zig).
    emit_asm: bool = false,
    /// The `--emit-bin <file>` target: write the LLIR binary (bytecode,
    /// 6.1) to <file> instead of any text output. Mutually exclusive with
    /// `--emit-asm` and `--output` (the flag carries its own file).
    emit_bin: ?[]const u8 = null,
    /// True when `--run` was given: compile (or load a binary) and
    /// execute. Mutually exclusive with the emission flags.
    run: bool = false,
    search_dirs: std.ArrayList([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_list: std.ArrayList([]const u8) = .empty;
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
/// on a usage or emission-mode failure (unreadable input, unwritable
/// output, or a compile diagnostic), and under `--run` the interpreter
/// contract of runProgram — 0 normal termination, 1 Stilla panic, 2
/// load/compile error. Splitting the exit-code mapping out of `main`
/// keeps the code paths unit-testable.
fn run(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const parsed = parseArgs(io, gpa, args) catch return 1;
    var opts = parsed orelse return 0; // --help
    defer opts.search_dirs.deinit(gpa);
    if (opts.run) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        return runProgram(io, gpa, arena_state.allocator(), opts);
    }

    // The source text and specifier must outlive the compilation (the AST
    // references them), so they live in an arena alongside the compile.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var compilation = (compileInput(io, gpa, arena, opts) orelse return 1);
    defer compilation.deinit();

    if (compilation.program) |*program| {
        if (opts.emit_bin) |path| {
            // The binary mode: lower to the frozen LLIR image and
            // serialize it (6.1). The bytes are written to the flag's own
            // file — binary output never goes to stdout (the text sink).
            const bytes = renderBin(arena, program) catch return 1;
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
                errPrint(io, gpa, "stilla: cannot write '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
                return 1;
            };
            return 0;
        }
        const out = renderProgram(arena, opts, program, compilation) catch return 1;
        if (opts.output) |path| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out }) catch |err| {
                errPrint(io, gpa, "stilla: cannot write '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
                return 1;
            };
        } else {
            std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, out) catch return 1;
        }
        return 0;
    } else {
        const diag = compilation.diag orelse return 1;
        renderDiags(io, gpa, compilation.graph, compilation.sources, compilation.diags, diag) catch {};
        return 1;
    }
}

/// Read the source input and compile it (the shared front half of the
/// emission modes and `--run`). Returns null after printing the error;
/// the caller maps null to its own exit code (1 for the emission modes,
/// 2 under --run).
fn compileInput(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
) ?stilla.frontend.Compilation {
    const text = std.Io.Dir.cwd().readFileAlloc(io, opts.input, arena, .limited(16 * 1024 * 1024)) catch |err| {
        errPrint(io, gpa, "stilla: cannot read '{s}': {s}\n", .{ opts.input, @errorName(err) }) catch {};
        return null;
    };
    const spec = arena.dupe(u8, opts.module orelse std.fs.path.stem(opts.input)) catch return null;

    var sources = stilla.moduleinfo.Sources{};
    sources.source.put(arena, spec, text) catch return null;
    sources.search_dirs = opts.search_dirs.items;

    const options = stilla.frontend.Options{
        .entry = spec,
        .sources = sources,
        .entry_fn = opts.entry_fn,
        .entry_fn_explicit = opts.entry_fn_explicit,
        .io = io,
        // The executable ships the optimized AIR by default (optimizer.md):
        // the toggle is code-only, so there is no CLI flag to turn
        // it off; embedders of the library control it via Options.
        .optimize = true,
    };
    return stilla.frontend.compile(arena, options) catch {
        errPrint(io, gpa, "stilla: compilation failed\n", .{}) catch {};
        return null;
    };
}

/// Lower `program` to the frozen LLIR image and resolve the entry
/// `FunctionId` through the builder's `func_ids` name map (D3). The
/// image is read-only after this; `entry` is null only when the program
/// has no host-selected entry function (`--no-entry-fn`).
const LoweredWithEntry = struct {
    image: stilla.llir.LlirProgram,
    entry: ?stilla.llir.FunctionId,
};

fn lowerWithEntry(
    arena: std.mem.Allocator,
    program: *stilla.cfg.IrProgram,
) error{ OutOfMemory, ProgramTooLarge, IdOutOfRange, SyscallWithoutSignature, DuplicateExport }!LoweredWithEntry {
    var b = stilla.lower.LlirBuilder.init(arena, program);
    const image = try b.lowerLlir();
    return .{ .image = image, .entry = if (program.entry) |e| b.func_ids.get(e) else null };
}

/// The `--run` mode (interpreter-vm.md §13 M5): execute the input.
/// An input starting with the LLIR magic is a self-contained binary
/// (D3): `readBin` → `validateLlir` → run from the header's symbolic
/// entry member. Anything else compiles and runs — through the
/// builder-resolved entry function when one exists, otherwise through
/// the artifact's recorded entry export. Exit codes: 0 normal, 1 panic
/// (owned message → stderr), 2 load/compile error.
fn runProgram(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, opts: Options) u8 {
    var image: stilla.llir.LlirProgram = undefined;
    var entry: ?stilla.llir.FunctionId = null;
    // The compile path's per-module artifact bundle: the root is the
    // image; its loader serves the dependency artifacts at run time
    // (Runtime §6), so `--run` executes real cross-module programs
    // rather than only what the optimizer inlines away.
    var bundle: ?stilla.artifact_bundle.ArtifactBundle = null;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, opts.input, arena, .limited(64 * 1024 * 1024)) catch |err| {
        errPrint(io, gpa, "stilla: cannot read '{s}': {s}\n", .{ opts.input, @errorName(err) }) catch {};
        return 2;
    };
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "LLIR")) {
        // Binary load path: the image, then structural validation; the
        // interpreter resolves the header's symbolic entry member
        // through the export table (D3).
        image = stilla.lower.readBin(arena, bytes) catch {
            errPrint(io, gpa, "stilla: '{s}' is not a valid LLIR binary\n", .{opts.input}) catch {};
            return 2;
        };
        const invalid = stilla.lower.validateLlir(&image, arena) catch return 2;
        if (invalid) |msg| {
            errPrint(io, gpa, "stilla: invalid image: {s}\n", .{msg}) catch {};
            arena.free(msg);
            return 2;
        }
    } else {
        var compilation = compileInput(io, gpa, arena, opts) orelse return 2;
        defer compilation.deinit();
        const program = &(compilation.program orelse {
            const diag = compilation.diag orelse return 2;
            renderDiags(io, gpa, compilation.graph, compilation.sources, compilation.diags, diag) catch {};
            return 2;
        });
        bundle = stilla.artifact_bundle.ArtifactBundle.build(arena, program) catch return 2;
        image = bundle.?.root;
        entry = bundle.?.entry;
    }

    var term = blk: {
        if (image.entry_member != stilla.llir.no_index) {
            break :blk if (bundle) |*b|
                stilla.interpreter.runWithHostAndLoader(arena, &image, .{}, b.loaderHandle())
            else
                stilla.interpreter.run(arena, &image);
        }
        if (entry) |e| {
            break :blk if (bundle) |*b|
                stilla.interpreter.runWithEntryAndLoader(arena, &image, e, .{}, b.loaderHandle())
            else
                stilla.interpreter.runWithEntry(arena, &image, e, .{});
        }
        errPrint(io, gpa, "stilla: no entry function in '{s}'\n", .{opts.input}) catch {};
        return 2;
    } catch |err| {
        errPrint(io, gpa, "stilla: execution failed: {s}\n", .{@errorName(err)}) catch {};
        return 2;
    };
    defer term.deinit(arena);
    switch (term) {
        .normal => return 0,
        .panic => |m| {
            errPrint(io, gpa, "stilla: panic: {s}\n", .{m}) catch {};
            return 1;
        },
    }
}

/// Produce the output text for the compiled program: the AIR decorated
/// with `;`-source comments (the historical default), or the symbolic
/// LLIR assembly when `--emit-asm` (5.3). Both sinks — stdout and
/// `--output` — write this buffer verbatim, so the two paths share the
/// same content contract.
fn renderProgram(
    arena: std.mem.Allocator,
    opts: Options,
    program: *stilla.cfg.IrProgram,
    compilation: stilla.frontend.Compilation,
) error{ OutOfMemory, ProgramTooLarge, IdOutOfRange, SyscallWithoutSignature, DuplicateExport }![]const u8 {
    var out = std.ArrayList(u8).empty;
    if (opts.emit_asm) {
        // Lower the CFG to the frozen LLIR image, then project it to
        // assembly (5.1). The image is read-only here; names are resolved
        // from `program` (the image itself carries no names).
        var b = stilla.lower.LlirBuilder.init(arena, program);
        const image = try b.lowerLlir();
        const asm_text = try stilla.llir.print(&b, image, arena);
        try out.appendSlice(arena, asm_text);
    } else {
        const ir = try stilla.cfg.print(program, arena);
        // Prepend the source of every compiling module (the entry plus any
        // `-I` imports; embedded stdlib sources are excluded) as `;`
        // comments, so the AIR file carries the Stilla that produced it for
        // reference. The AIR lexer skips `;` comments, so the decorated
        // output still re-parses.
        if (compilation.graph) |g| {
            for (g.modules) |m| {
                if (m.kind != .source) continue;
                if (m.source) |src| try commentSource(&out, arena, m.specifier, src.text);
            }
        }
        try out.appendSlice(arena, ir);
    }
    return out.items;
}

/// Produce the LLIR binary (bytecode) for the compiled program (6.1):
/// lower the CFG to the frozen image and serialize it with
/// `lower.emitBinWithEntry`, so the header records the resolved entry
/// `FunctionId` (D3) — a binary this CLI writes is self-contained and
/// runs from that entry, even when it is not function 0. With no
/// host-selected entry (`--no-entry-fn`), the header records 0.
fn renderBin(arena: std.mem.Allocator, program: *stilla.cfg.IrProgram) error{ OutOfMemory, ProgramTooLarge, IdOutOfRange, SyscallWithoutSignature, DuplicateExport }![]u8 {
    const lowered = try lowerWithEntry(arena, program);
    return stilla.lower.emitBinWithEntry(lowered.image, lowered.entry orelse 0, arena);
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
    // Unix option order: `parse_options` goes false at the first
    // positional argument, so everything after the input file is a
    // positional (an option there is a second input, an error); `--`
    // ends option parsing explicitly.
    var parse_options = true;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (parse_options and std.mem.eql(u8, a, "--")) {
            parse_options = false;
        } else if (parse_options and (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help"))) {
            try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, usage);
            return null;
        } else if (parse_options and std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "--output needs a file argument");
            opts.output = args[i];
        } else if (parse_options and std.mem.eql(u8, a, "--module")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "--module needs a specifier argument");
            opts.module = args[i];
        } else if (parse_options and std.mem.eql(u8, a, "--entry-fn")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "--entry-fn needs a name argument");
            opts.entry_fn = args[i];
            opts.entry_fn_explicit = true;
        } else if (parse_options and std.mem.eql(u8, a, "--no-entry-fn")) {
            opts.entry_fn = null;
        } else if (parse_options and std.mem.eql(u8, a, "--emit-asm")) {
            opts.emit_asm = true;
        } else if (parse_options and std.mem.eql(u8, a, "--run")) {
            opts.run = true;
        } else if (parse_options and std.mem.eql(u8, a, "--emit-bin")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "--emit-bin needs a file argument");
            opts.emit_bin = args[i];
        } else if (parse_options and std.mem.eql(u8, a, "-I")) {
            i += 1;
            if (i >= args.len) return argErr(io, gpa, "-I needs a directory argument");
            try opts.search_dirs.append(gpa, args[i]);
        } else if (parse_options and a.len > 0 and a[0] == '-') {
            const msg = try std.fmt.allocPrint(gpa, "unexpected argument '{s}'", .{a});
            defer gpa.free(msg);
            return argErr(io, gpa, msg);
        } else if (opts.input.len == 0) {
            opts.input = a;
            parse_options = false; // Unix order: options precede the input
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
    // The output modes are mutually exclusive: --emit-bin carries its own
    // file, so --emit-asm (a different mode) and --output (a second sink)
    // cannot be combined with it.
    if (opts.emit_bin != null and opts.emit_asm) {
        return argErr(io, gpa, "--emit-bin cannot be combined with --emit-asm");
    }
    if (opts.emit_bin != null and opts.output != null) {
        return argErr(io, gpa, "--emit-bin carries its own output file; it cannot be combined with --output");
    }
    // --run executes rather than emitting; a binary image carries its own
    // entry id (D3), so the no-entry mode has nothing to run.
    if (opts.run and opts.emit_asm) {
        return argErr(io, gpa, "--run cannot be combined with --emit-asm");
    }
    if (opts.run and opts.emit_bin != null) {
        return argErr(io, gpa, "--run cannot be combined with --emit-bin");
    }
    if (opts.run and opts.output != null) {
        return argErr(io, gpa, "--run cannot be combined with --output");
    }
    if (opts.run and opts.entry_fn == null) {
        return argErr(io, gpa, "--run requires an entry function; --no-entry-fn has nothing to execute");
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
/// specifier, for the source-reference header of the AIR output.
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

/// Render every diagnostic the compilation collected, each with its
/// `file:line:col` prefix when the span resolves, in collection order.
/// The reported count is capped (first `kMaxDiags`) so pathological
/// inputs cannot flood the terminal; a single-error compile renders
/// byte-identically to the pre-collection behavior.
fn renderDiags(
    io: std.Io,
    gpa: std.mem.Allocator,
    graph: ?*stilla.moduleinfo.ModuleGraph,
    sources: []const *const stilla.ast.Source,
    diags: []const stilla.moduleinfo.Diag,
    first: ?stilla.moduleinfo.Diag,
) !void {
    // `diags` may be empty when a caller only has the single-diagnostic
    // accessor; fall back to it so every call site renders something.
    const list = if (diags.len > 0) diags else if (first) |d| &.{d} else &.{};
    const shown = @min(list.len, kMaxDiags);
    for (list[0..shown]) |diag| try renderDiag(io, gpa, graph, sources, diag);
    if (list.len > shown) {
        try errPrint(io, gpa, "... {d} more error{s} (truncated)\n", .{ list.len - shown, if (list.len - shown == 1) "" else "s" });
    }
}

/// The maximum number of diagnostics rendered in one run; pathological
/// inputs (a machine-generated file full of errors) must not flood the
/// terminal.
const kMaxDiags = 32;

/// Resolve one diagnostic's span and render it as
/// `file:line:col: error: message`. The
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
    // Options precede the input file (Unix convention).
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{
        "stilla", "--module", "myapp", "--entry-fn", "run", "-I", "lib", "app.st",
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
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--no-entry-fn", "app.st" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expect(opts.entry_fn == null);
}

test "parseArgs --output sets the output path" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--output", "out.txt", "app.st" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expectEqualStrings("out.txt", opts.output.?);
}

test "parseArgs collects multiple -I search dirs in order" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "-I", "a", "-I", "b", "-I", "c", "app.st" })).?;
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
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--bogus" }));
}

test "parseArgs rejects an option missing its value" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--output" }));
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "-I" }));
}

test "parseArgs stops option parsing at the first positional (Unix order)" {
    // An option after the input file is a second positional argument,
    // not an option: `stilla app.st --module app` is rejected.
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "--module", "app" }));
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st", "--output", "x" }));
}

test "parseArgs -- ends option parsing" {
    // `--` ends option parsing explicitly, so a dash-leading input file
    // (or a trailing `-h`) is a positional argument, not an option.
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--", "-weird.st" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expectEqualStrings("-weird.st", opts.input);
}

test "parseArgs rejects a second positional input" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "a.st", "b.st" }));
}

// NOTE: the CLI process exit-code mapping (`run` above) is not unit-tested
// in-process: `std.testing.io` writes to fd 1, which under `zig build test`
// is the test-runner's `--listen` protocol pipe, so any test that prints
// usage text or compiles output would corrupt the protocol and hang the
// build. The exit codes are verified end-to-end by CLI probes instead.

test "parseArgs --emit-asm sets the assembly mode; with --output it selects the file sink" {
    // stdout path: `--emit-asm` alone selects assembly (no --output).
    var o1 = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--emit-asm", "app.st" })).?;
    defer o1.search_dirs.deinit(testing.allocator);
    try testing.expect(o1.emit_asm);
    try testing.expect(o1.output == null);

    // file path: `--emit-asm --output app.s` writes the assembly to a file.
    var o2 = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--emit-asm", "--output", "app.s", "app.st" })).?;
    defer o2.search_dirs.deinit(testing.allocator);
    try testing.expect(o2.emit_asm);
    try testing.expectEqualStrings("app.s", o2.output.?);
}

test "parseArgs defaults --emit-asm off" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expect(!opts.emit_asm);
}

// The fd-1 (stdout) sink of `run` is the CLI-probed path, not an
// in-process unit: under `zig build test` fd 1 is the test-runner's
// `--listen` protocol pipe (see the note above), so any test that prints
// the compile output to stdout would corrupt it. The `--output` sink
// writes only to a real file and is therefore fully exercised here
// end-to-end: parse -> read the source -> compile -> lower to LLIR ->
// render assembly -> write the file. Both sinks write the *same*
// `renderProgram` buffer, and the stdout-path selection is covered by the
// parseArgs tests above; the real stdout run is verified by CLI probe.
test "run --emit-asm --output writes the LLIR assembly to the file" {
    const src_name = "5.3_emit_asm_probe.st";
    const out_name = "5.3_emit_asm_probe.s";
    defer std.Io.Dir.cwd().deleteFile(testing.io, src_name) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, out_name) catch {};

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = src_name, .data =
        \\fn add(a: int32, b: int32) -> int32 { a + b }
        \\fn main() -> void {}
    });

    try testing.expectEqual(@as(u8, 0), run(testing.io, testing.allocator, &.{ "stilla", "--emit-asm", "--module", "app", "--output", out_name, src_name }));

    const out = try std.Io.Dir.cwd().readFileAlloc(testing.io, out_name, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "LLIR assembly") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.add {") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".block $") != null);
}

test "run --output writes the AIR (default mode) to the file" {
    // Regression guard for the non-asm path: without --emit-asm the file
    // gets the source-decorated AIR, not the assembly.
    const src_name = "5.3_ir_probe.st";
    const out_name = "5.3_ir_probe.ir";
    defer std.Io.Dir.cwd().deleteFile(testing.io, src_name) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, out_name) catch {};

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = src_name, .data =
        \\fn main() -> void {}
    });

    try testing.expectEqual(@as(u8, 0), run(testing.io, testing.allocator, &.{ "stilla", "--module", "app", "--output", out_name, src_name }));

    const out = try std.Io.Dir.cwd().readFileAlloc(testing.io, out_name, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(out);
    // The AIR preface, distinct from the assembly header; confirms the
    // default (non-asm) mode is unaffected by the new flag.
    try testing.expect(std.mem.indexOf(u8, out, "=== source: module \"app\" ===") != null);
    try testing.expect(std.mem.indexOf(u8, out, "LLIR assembly") == null);
}

test "parseArgs --emit-bin sets the binary target; defaults off" {
    var o1 = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--emit-bin", "app.bc", "app.st" })).?;
    defer o1.search_dirs.deinit(testing.allocator);
    try testing.expectEqualStrings("app.bc", o1.emit_bin.?);
    try testing.expect(!o1.emit_asm);
    try testing.expect(o1.output == null);

    var o2 = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "app.st" })).?;
    defer o2.search_dirs.deinit(testing.allocator);
    try testing.expect(o2.emit_bin == null);
}

test "parseArgs --emit-bin needs a file argument" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--emit-bin" }));
}

test "parseArgs --emit-bin conflicts with --emit-asm and --output" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--emit-bin", "a.bc", "--emit-asm", "app.st" }));
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--emit-bin", "a.bc", "--output", "x", "app.st" }));
}

test "run --emit-bin writes the LLIR binary; CLI bytes equal a direct serialization" {
    // The binary sink writes only to the flag's own file (never stdout —
    // the fd-1 protocol pipe), so it is fully exercised in-process: parse
    // -> read the source -> compile -> lower to LLIR -> serialize -> write
    // the file. The acceptance is that the CLI bytes equal a direct
    // serialization of the same compile, and that the file reads back as
    // a valid image (6.2/6.3).
    const src_name = "6.3_emit_bin_probe.st";
    const bin_name = "6.3_emit_bin_probe.bc";
    defer std.Io.Dir.cwd().deleteFile(testing.io, src_name) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, bin_name) catch {};

    const src =
        \\fn add(a: int32, b: int32) -> int32 { a + b }
        \\fn main() -> void {}
    ;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = src_name, .data = src });

    try testing.expectEqual(@as(u8, 0), run(testing.io, testing.allocator, &.{ "stilla", "--emit-bin", bin_name, "--module", "app", src_name }));

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, bin_name, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 0);

    // The CLI bytes equal a direct serialization of the same compile...
    var sources = stilla.moduleinfo.Sources{};
    var smap = std.StringHashMapUnmanaged([]const u8).empty;
    defer smap.deinit(testing.allocator);
    try smap.put(testing.allocator, "app", src);
    sources.source = smap;
    var compilation = try stilla.frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "main", .optimize = true });
    defer compilation.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = stilla.lower.LlirBuilder.init(arena.allocator(), &compilation.program.?);
    const image = try b.lowerLlir();
    // D3: the CLI writes the resolved entry into the header (not the
    // entry-0 placeholder `emitBin` would), so the binary is
    // self-contained — `add` lowers before `main` here, so the entry is
    // not function 0.
    const entry = b.func_ids.get(compilation.program.?.entry.?).?;
    const expect = try stilla.lower.emitBinWithEntry(image, entry, arena.allocator());
    try testing.expectEqualSlices(u8, expect, bytes);
    // The header's entry member symbol range matches the image's.
    const got_entry = try stilla.lower.readBinEntry(bytes);
    const want_range = image.symbols[image.entry_member];
    try testing.expectEqual(want_range.start, got_entry[0]);
    try testing.expectEqual(want_range.len, got_entry[1]);

    // ...and the binary reads back as a valid image (6.2).
    var read_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer read_arena.deinit();
    const back = try stilla.lower.readBin(read_arena.allocator(), bytes);
    try testing.expectEqual(@as(?[]const u8, null), try stilla.lower.validateLlir(&back, testing.allocator));
}

test "parseArgs --run sets the run mode" {
    var opts = (try parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--run", "app.st" })).?;
    defer opts.search_dirs.deinit(testing.allocator);
    try testing.expect(opts.run);
    try testing.expectEqualStrings("app.st", opts.input);
}

test "parseArgs --run conflicts with the emission flags and --no-entry-fn" {
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--run", "--emit-asm", "app.st" }));
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--run", "--emit-bin", "a.bc", "app.st" }));
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--run", "--output", "x", "app.st" }));
    try testing.expectError(error.InputOutput, parseArgs(std.Io.failing, testing.allocator, &.{ "stilla", "--run", "--no-entry-fn", "app.st" }));
}

test "run --run resolves the entry through the builder's func_ids" {
    // Entry resolution (D3): the run path maps the host-selected entry
    // through `LlirBuilder.func_ids`, which keys on the `IrFunc`
    // pointer — the default `main` and an explicit `--entry-fn` resolve
    // to the functions the lowering assigned them, not to function 0.
    // `helper` lowers before `main`, so `main` is not id 0.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sources = stilla.moduleinfo.Sources{};
    var smap = std.StringHashMapUnmanaged([]const u8).empty;
    defer smap.deinit(testing.allocator);
    try smap.put(testing.allocator, "app",
        \\fn helper() -> int32 { 7 }
        \\fn main() -> int32 { 40 + 2 }
    );
    sources.source = smap;
    var compilation = try stilla.frontend.compile(a, .{ .entry = "app", .sources = sources, .entry_fn = "main", .optimize = true });
    defer compilation.deinit();
    const program = &compilation.program.?;

    var b = stilla.lower.LlirBuilder.init(a, program);
    const image = try b.lowerLlir();
    const main_id = b.func_ids.get(program.entry.?).?;
    try testing.expect(main_id != 0); // helper lowers first
    try testing.expect(main_id < image.functions.len);

    // The binary header carries the entry member symbol the run path resolves.
    const bytes = try stilla.lower.emitBinWithEntry(image, main_id, a);
    const got_entry = try stilla.lower.readBinEntry(bytes);
    const want_range = image.symbols[image.entry_member];
    try testing.expectEqual(want_range.start, got_entry[0]);
    try testing.expectEqual(want_range.len, got_entry[1]);
}

test "run --run executes a source file and exits 0" {
    // In-process `--run` covers the paths that write no stdout: fd 1 is
    // the test-runner's protocol pipe, so a printing program belongs to
    // the build.zig CLI probe. A program that terminates without
    // printing still exercises compile -> lower -> resolve entry -> run.
    const src_name = "13_m5_run_probe.st";
    defer std.Io.Dir.cwd().deleteFile(testing.io, src_name) catch {};

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = src_name, .data =
        \\fn main() -> void {}
    });
    try testing.expectEqual(@as(u8, 0), run(testing.io, testing.allocator, &.{ "stilla", "--run", "--module", "app", src_name }));
}

test "run --run loads and executes a self-contained binary from its header entry (D3)" {
    // The binary load path: sniff the LLIR magic -> readBin ->
    // validateLlir -> run from the header's entry id. `helper` lowers
    // before `main` and would panic if it ran, so exit 0 proves the
    // header entry (main, not function 0) is honored.
    const src_name = "13_m5_bin_src.st";
    const bin_name = "13_m5_bin_probe.bc";
    defer std.Io.Dir.cwd().deleteFile(testing.io, src_name) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, bin_name) catch {};

    const src =
        \\const builtin = import("builtin");
        \\fn helper() -> void { builtin.panic("ran the wrong entry") }
        \\fn main() -> void {}
    ;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = src_name, .data = src });
    try testing.expectEqual(@as(u8, 0), run(testing.io, testing.allocator, &.{ "stilla", "--emit-bin", bin_name, "--module", "app", src_name }));
    try testing.expectEqual(@as(u8, 0), run(testing.io, testing.allocator, &.{ "stilla", "--run", bin_name }));
}
