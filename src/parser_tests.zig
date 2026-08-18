//! Test file: `parser` — the LL(k) parser.
//!
//! White-box tests of `src/parser.zig`'s own internals stay in that module's
//! file; this file aggregates them (with the split grammar passes under
//! `src/parse/`) so they are analyzed and run, and adds black-box tests of
//! the public `Parser` API: complete program shapes, host-binding
//! declarations, and error diagnostics.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const testing = std.testing;

test {
    // White-box tests of the module files in this slice.
    _ = @import("parser.zig");
    _ = @import("parse/type.zig");
    _ = @import("parse/expr.zig");
    _ = @import("parse/stmt.zig");
    _ = @import("parse/pattern.zig");
}

// ---------------------------------------------------------------------------
// parser — black-box: the public `Parser` API over whole source texts.
// ---------------------------------------------------------------------------

fn parseText(text: []const u8) !struct { arena: std.heap.ArenaAllocator, source: *const ast.Source, program: ast.Program } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
    var p = parser.Parser.init(arena.allocator());
    const program = try p.parse(source);
    return .{ .arena = arena, .source = source, .program = program };
}

fn parseError(text: []const u8) !struct { arena: std.heap.ArenaAllocator, diag: ast.Diagnostic } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const source = try arena.allocator().create(ast.Source);
    source.* = try ast.Source.init(arena.allocator(), "test.st", 0, text);
    var p = parser.Parser.init(arena.allocator());
    try testing.expectError(error.Syntax, p.parse(source));
    return .{ .arena = arena, .diag = p.diag.? };
}

test "parser black-box: parses every module-item kind in one program" {
    const text =
        \\const version: int32 = 1;
        \\type Size = int32;
        \\struct Point { x: int32; y: int32; }
        \\union Result { Ok(int32), Err(str) }
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn add(a: int32, b: int32) -> int32 { a + b }
        \\fn main() -> void {}
    ;
    var t = try parseText(text);
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 8), t.program.items.len);
    try testing.expect(t.program.items[0] == .const_def);
    try testing.expect(t.program.items[1] == .type_def);
    try testing.expect(t.program.items[2] == .struct_def);
    try testing.expect(t.program.items[3] == .union_def);
    try testing.expect(t.program.items[4] == .const_def);
    try testing.expect(t.program.items[5] == .using_decl);
    try testing.expect(t.program.items[6] == .func_def);
    try testing.expect(t.program.items[7] == .func_def);
}

test "parser black-box: host-binding declarations parse without bodies" {
    // A declaration without a body or initializer is a host binding (phase3-cfg-lowering.md, System calls for host bindings)
    // binding (`builtin.str[T]` etc., Runtime §4).
    const text = "fn str[T](value: T) -> str;\nconst max_int32: int32;\n";
    var t = try parseText(text);
    defer t.arena.deinit();

    const f = switch (t.program.items[0]) {
        .func_def => |f| f,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(f.body == null);
    try testing.expectEqual(@as(usize, 1), f.type_params.len);
    try testing.expectEqualStrings("T", f.type_params[0].text);
    const c = switch (t.program.items[1]) {
        .const_def => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(c.init == null);
    try testing.expect(c.type_ != null);
}

test "parser black-box: a reserved-word function name with a body is an error" {
    var t = try parseError("fn if() -> void {}");
    defer t.arena.deinit();
    try testing.expect(std.mem.indexOf(u8, t.diag.message, "reserved word") != null);
}

test "parser black-box: a syntax error reports a diagnostic with a real span" {
    var t = try parseError("fn main() -> void { let x = ; }");
    defer t.arena.deinit();
    // The diagnostic points into the source (not span 0, the module 1:1).
    try testing.expect(t.diag.span.start != 0);
    try testing.expect(t.diag.message.len > 0);
}
