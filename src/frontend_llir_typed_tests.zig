//! Test file: `frontend LLIR typed` — the typed lowering layer
//! (`passes/cfg_lower_typed.zig`) exercised over real compiled CFGs.
//! In v10 the opcode carries the full rep (`add.i32`/`div.u32`/…) and
//! every arithmetic instruction is exactly one record (Instruction Set
//! §4) — there are no value forms and no canonicalization records.
//! These black-box tests pin that boundary: the Layer A op view, the
//! typed printer, and the one-record emission over the frontend's CFG.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const cfg = @import("cfg.zig");
const llir = @import("llir.zig");
const typed = @import("passes/cfg_lower_typed.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const lower = @import("lower.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;

test "typed printer is faithful to the typed record" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main(p: int32, q: int32) -> void {
            \\    let r = p + q;
            \\    builtin.print(builtin.str(r));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;
    const main = helpers.findFunc(program, "app.main");

    // The Layer A op list is one atomic `add.i32` node.
    const ops = try typed.typedOps(testing.allocator, main);
    defer testing.allocator.free(ops);
    try testing.expectEqual(@as(usize, 1), ops.len);
    const op = ops[0];
    try testing.expectEqual(llir.TypedKind.add, op.kind);
    try testing.expectEqual(cfg.Type{ .primitive = .int32 }, op.type_);

    // The typed opcode for the type is the rep-carrying member, and the
    // record count of the arithmetic is exactly one (no canonicalization
    // records exist in v10).
    try testing.expectEqual(llir.Opcode.add_i32, llir.typedOpcode(.add, op.type_, undefined).?);

    // The typed assembly renders the same op with its width rep.
    const text = try typed.printTyped(testing.allocator, main);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "i32 = add.i32") != null);
}

test "an i32 add lowers to exactly one `add.i32` record — no canonicalization" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main(p: int32, q: int32) -> void {
            \\    let r = p + q;
            \\    builtin.print(builtin.str(r));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    // The add record is `add.i32`; the v10 opcode set has no
    // canonicalization opcodes at all, so one record is the whole
    // operation.
    var n_add: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .add_i32) n_add += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_add);
}

test "a u32 divide lowers to exactly one `div.u32` record — no staging" {
    // Using a cast (not a constant dividend) keeps the divide in the
    // CFG instead of constant-folding it away.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn q(x: int32, p: uint32) -> uint32 { let u = x as uint32; u / p }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));
    const asmText = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asmText);

    // One typed record: the mnemonic carries the rep; no staging
    // register, no canonicalization records.
    try testing.expect(std.mem.indexOf(u8, asmText, "div.u32") != null);
    try testing.expect(std.mem.indexOf(u8, asmText, "zext32") == null);
    try testing.expect(std.mem.indexOf(u8, asmText, "sext32") == null);
}

test "shift counts ride in the typed shift record — no mod-32 masking record" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main(p: int32, s: int32) -> void {
            \\    let r = p << s;
            \\    builtin.print(builtin.str(r));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    // `shl.i32` masks the count internally (§4): one record, no
    // `andi` staging copy.
    var n_shl: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .shl_i32) n_shl += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_shl);
}
