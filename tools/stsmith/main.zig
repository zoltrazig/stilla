//! stsmith — a randomized, seeded, reproducible Stilla program generator in
//! the spirit of Csmith. Same seed + same options produce byte-identical
//! programs (see tools/stsmith/README.md). Generated programs are
//! self-checking: run them under `stilla --run`; any assert failure means
//! the generator's model disagreed with the Stilla runtime.

const std = @import("std");
const gen = @import("./gen.zig");

const usage =
    \\usage: stsmith [options]
    \\
    \\Generate a random self-checking Stilla program.
    \\
    \\options:
    \\  --seed <n>        random seed (default: 1); same seed reproduces output
    \\  --statements <n>  statements to generate in main (default: 60)
    \\  --funcs <n>       helper functions to generate (default: 5)
    \\  --max-depth <n>   max recursion depth for recursive templates (default: 6)
    \\  --output <file>   write the program to <file> instead of stdout
    \\  -h, --help        show this help
    \\
;

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

    const result = run(io, gpa, arg_list.items);
    std.process.exit(result);
}

fn run(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var opts = gen.Options{};
    var output: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, usage) catch return 1;
            return 0;
        } else if (std.mem.eql(u8, a, "--seed")) {
            if (i + 1 >= args.len) return usageFail(io);
            opts.seed = std.fmt.parseUnsigned(u64, args[i + 1], 10) catch return usageFail(io);
            i += 1;
        } else if (std.mem.eql(u8, a, "--statements")) {
            if (i + 1 >= args.len) return usageFail(io);
            opts.statements = std.fmt.parseUnsigned(u32, args[i + 1], 10) catch return usageFail(io);
            i += 1;
        } else if (std.mem.eql(u8, a, "--funcs")) {
            if (i + 1 >= args.len) return usageFail(io);
            opts.funcs = std.fmt.parseUnsigned(u32, args[i + 1], 10) catch return usageFail(io);
            i += 1;
        } else if (std.mem.eql(u8, a, "--max-depth")) {
            if (i + 1 >= args.len) return usageFail(io);
            opts.max_depth = std.fmt.parseUnsigned(u32, args[i + 1], 10) catch return usageFail(io);
            i += 1;
        } else if (std.mem.eql(u8, a, "--output")) {
            if (i + 1 >= args.len) return usageFail(io);
            output = args[i + 1];
            i += 1;
        } else {
            return usageFail(io);
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = gen.generate(arena, opts) catch {
        std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, "stsmith: generation failed\n") catch {};
        return 1;
    };

    if (output) |path| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src }) catch {
            std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, "stsmith: cannot write output\n") catch {};
            return 1;
        };
    } else {
        std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, src) catch return 1;
    }
    return 0;
}

fn usageFail(io: std.Io) u8 {
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, usage) catch {};
    return 1;
}
