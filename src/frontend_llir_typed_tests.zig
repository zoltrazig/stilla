//! Test file: `frontend LLIR typed` — the typed lowering layer
//! (`passes/cfg_lower_typed.zig`) exercised over real compiled CFGs:
//! the value-form lattice constrains every value's top-bits state from
//! its producer (docs/llir-typed.md §2 — the value-form lattice).
//! The white-box producer rules live in the
//! module's own test block; these black-box tests run the lattice over
//! the frontend's CFG and pin the observable outcomes for common
//! shapes.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const cfg = @import("cfg.zig");
const llir = @import("llir.zig");
const typed = @import("passes/cfg_lower_typed.zig");
const budget = @import("passes/cfg_lower_llir_budget.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const lower = @import("lower.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;

/// The form of the result of the first instruction in `f` whose op tag is
/// `tag`. The lattice is computed fresh over a scratch arena; only the
/// scalar form is returned, so the arena can be dropped.
fn defForm(f: *const cfg.IrFunc, comptime tag: cfg.OpTag) typed.Form {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const forms = typed.compute(arena.allocator(), f) catch unreachable;
    for (f.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (ins.results.len == 0) continue;
            if (std.meta.activeTag(ins.op) == tag) return forms[ins.results[0].id];
        }
    }
    unreachable;
}

test "lattice over compiled CFG: a u32 literal is zero-extended" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    let x: uint32 = 5;
            \\    builtin.print(builtin.str(x));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;
    const main = helpers.findFunc(program, "app.main");
    try testing.expectEqual(typed.Form.zero_extended, defForm(main, .const_));
}

test "lattice over compiled CFG: an i32 add is sign-extended" {
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
    try testing.expectEqual(typed.Form.sign_extended, defForm(main, .add));
}

test "lattice over compiled CFG: a parameter has no known form" {
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main(p: int32) -> void {
            \\    builtin.print(builtin.str(p));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;
    const main = helpers.findFunc(program, "app.main");
    const forms = try typed.compute(testing.allocator, main);
    defer testing.allocator.free(forms);
    // The parameter is an SSA root (no defining instruction).
    var found = false;
    for (main.values) |v| {
        if (v.def == null) {
            try testing.expectEqual(typed.Form.unknown, forms[v.id]);
            found = true;
        }
    }
    try testing.expect(found);
}

test "typed printer is faithful to the §4 record stream" {
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

    // The width model matches the §4 expansion: an i32 `add` is
    // `add; sext32` — two records.
    try testing.expectEqual(@as(u32, 2), budget.arithSeqCount(.add, op.type_));

    // The typed assembly renders the same op with its width rep.
    const text = try typed.printTyped(testing.allocator, main);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "i32 = add.i32") != null);
}

test "B.0 keeps the leading zext32 of a u32 divide of a cast-produced dividend" {
    // A cast into u32 writes an extendInt32Bits-canonical (sign-extended)
    // cell, so the dividend's value-form is `sign_extended` and the
    // div.u32 sequence keeps its staging `zext32 T15, @a` (a high cast
    // result with bit 31 set must be zero-extended before the full-cell
    // unsigned operation). Using a cast (not a constant dividend) keeps the
    // divide in the CFG instead of constant-folding it away.
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

    const q = helpers.findFunc(program, "app.q");
    const forms = try typed.compute(testing.allocator, q);
    defer testing.allocator.free(forms);
    var saw_div = false;
    for (q.blocks) |blk| {
        for (blk.instrs) |ins| {
            if (std.meta.activeTag(ins.op) == .div) {
                const a = ins.op.div.a;
                try testing.expectEqual(typed.Form.sign_extended, forms[a.id]);
                saw_div = true;
            }
        }
    }
    try testing.expect(saw_div);

    // The program is tiny: `q` lowers a u32 divide, `main` is empty, so the
    // only 32-bit arithmetic is the div. The staging `zext32 T15` stays.
    try testing.expect(std.mem.indexOf(u8, asmText, "divu") != null);
    try testing.expect(std.mem.indexOf(u8, asmText, "zext32 T15") != null);
}
