//! Test file: `frontend cfg passes` — the mid-level optimizer Pass 8.6
//! drop elision, 8.7 phi simplification, 8.8 jump threading, and the 8.9
//! measurement harness; the post-optimization drop lowering
//! (`cfg_lower_drop`); Phase 0 (self-contained AIR: concrete TypeDecls,
//! module member tables, syscall signatures); and the AIR validator
//! (`cfg_validate`, air.md §13). Split out of the former
//! `src/frontend_tests.zig`; `countOccurrences` and the block/type
//! counting helpers are local to this file.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const lower = @import("lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");
const cfg_validate = @import("passes/cfg_validate.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const compileOpt = helpers.compileOpt;
const funcBody = helpers.funcBody;
// ---------------------------------------------------------------------------
// Pass 8.6/8.7/8.8 — the new optimizer passes: drop elision, phi
// simplification, jump threading — plus the Pass 8.9 measurement harness
// over the example corpus.
// ---------------------------------------------------------------------------

/// The number of non-overlapping occurrences of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        n += 1;
        rest = rest[i + needle.len ..];
    }
    return n;
}

fn countInstrs(program: *const cfg.IrProgram) usize {
    var n: usize = 0;
    for (program.funcs) |f| {
        for (f.blocks) |b| n += b.instrs.len;
    }
    return n;
}

fn countNonPhi(program: *const cfg.IrProgram) usize {
    var n: usize = 0;
    for (program.funcs) |f| {
        for (f.blocks) |b| {
            for (b.instrs) |instr| {
                if (instr.op != .phi) n += 1;
            }
        }
    }
    return n;
}

fn countBlocks(program: *const cfg.IrProgram) usize {
    var n: usize = 0;
    for (program.funcs) |f| n += f.blocks.len;
    return n;
}

test "Pass 8.8 jump threading removes an empty forwarding block" {
    // `then:` is a forwarding block (no instructions, `j join`); its
    // edge is redirected to `join` and the join phi's `then` entry is
    // re-keyed to `entry`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    %3: bool = lt %0, %1
        \\    br %3 ? then : else
        \\then:
        \\    j join
        \\else:
        \\    %4: int32 = const 1
        \\    j join
        \\join:
        \\    %5: int32 = phi [%0, then], [%4, else]
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.jumpThread(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "then") == null);
    try testing.expect(std.mem.indexOf(u8, text, "br %3 ? join : else") != null);
    try testing.expect(std.mem.indexOf(u8, text, "phi [%0, entry]") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.8 jump threading skips a candidate with a duplicate-edge risk" {
    // `then:` forwards to `join`, but `entry` already branches to `join`
    // directly; threading would give `entry` two edges to `join`, which
    // the printer's phi ordering cannot distinguish. The skip rule keeps
    // `then` in place, and the program still round-trips.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    %3: bool = lt %0, %1
        \\    %4: int32 = const 1
        \\    br %3 ? then : join
        \\then:
        \\    j join
        \\join:
        \\    %5: int32 = phi [%4, entry], [%0, then]
        \\    ret %5
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.jumpThread(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "then") != null);
    // `entry` already branches to `join`, so threading `then` was
    // skipped: no duplicate predecessor edges were created.
    try testing.expect(std.mem.indexOf(u8, text, "br %3 ? then : join") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification removes single-incoming phis" {
    // `join` has one predecessor, so `%2` is interchangeable with `%1`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32) -> int32 {
        \\entry:
        \\    j join
        \\join:
        \\    %1: int32 = phi [%0, entry]
        \\    %2: int32 = add %1, %1
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "add %0, %0") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification collapses identical-incoming phis" {
    // Both predecessors feed the same value, so `%2` is `%0` everywhere.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    j left
        \\left:
        \\    j join
        \\right:
        \\    j join
        \\join:
        \\    %2: int32 = phi [%0, left], [%0, right]
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %0") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification removes self-referential trivial phis" {
    // braun13cc.pdf Algorithm 3: a phi that references only itself and
    // one other value (a loop-carried value whose back edge passes the
    // header phi through unchanged) is interchangeable with that value.
    // `%2` joins `%1` (entry path) and itself (back edge) → `%1`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    j left
        \\left:
        \\    j join
        \\right:
        \\    j join
        \\join:
        \\    %2: int32 = phi [%1, left], [%2, right]
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %1") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification resolves chains of trivial phis" {
    // The paper's recursive user walk in map form: `%2` is single-
    // incoming and forwards to `%3`; only once that lands does `%3`
    // become trivial (`φ(%1, %3)`), so the pass must iterate. Both phis
    // collapse to `%1`.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    j left
        \\left:
        \\    j join
        \\right:
        \\    j inner
        \\inner:
        \\    %2: int32 = phi [%3, right]
        \\    j join
        \\join:
        \\    %3: int32 = phi [%1, left], [%2, inner]
        \\    ret %3
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %1") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.7 phi simplification keeps all-self phis" {
    // `φ(vφ, vφ)` is unreachable or in the start block; the AIR has no
    // undefined value to forward it to (braun13cc.pdf Algorithm 3's Undef
    // case), so it is kept — forwarding to nothing would change its type.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: int32) -> int32 {
        \\entry:
        \\    j left
        \\left:
        \\    j join
        \\right:
        \\    j join
        \\join:
        \\    %2: int32 = phi [%2, left], [%2, right]
        \\    ret %2
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.phiSimplify(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "phi") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ret %2") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.6 drop elision removes Copy drops, keeps unique drops" {
    // A `drop` of a Copy value does nothing and can never run a
    // user hook (type_shape classifies hook-bearing structs unique), so
    // it is elided. A `drop` of an unique value (`hostdata`, `any`) may
    // run a user hook or hand a payload to the host, so it is kept even
    // though nothing observes it (air.md §14 — the print-hook guard).
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @f(a: int32, b: hostdata) -> void {
        \\entry:
        \\    drop %0
        \\    drop %1
        \\    ret
        \\}
        \\}
    );
    defer t.arena.deinit();
    try lower.dropElide(&t.program, t.arena.allocator());

    const text = try irText(&t.program);
    defer testing.allocator.free(text);
    // `a: int32` is Copy: its drop does nothing and is elided.
    try testing.expect(std.mem.indexOf(u8, text, "drop %0") == null);
    // `b: hostdata` is unique: its drop may run a user hook, kept.
    try testing.expect(std.mem.indexOf(u8, text, "drop %1") != null);

    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "drop lowering expands a struct drop into hook call + reverse field drops" {
    // Post-optimization drop lowering (air.md §6.4, §14): `drop %v` of a
    // struct becomes the hook call (when declared) followed by
    // `unpack_struct` and per-field drops in reverse declaration order
    // (Runtime §6.2). Only the *Unique* fields are dropped; Copy fields
    // destroy nothing.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; drop(file) {} }
            \\struct Other { fd: int32; drop(file) {} }
            \\struct Pair { a: File; b: Other; }
            \\fn open_file() -> File { File { fd: 3 } }
            \\fn open_other() -> Other { Other { fd: 4 } }
            \\fn main() -> void {
            \\    let x = open_file();
            \\    let y = open_other();
            \\    let p = Pair { a: move x, b: move y };
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    // The struct drop is expanded: one `unpack_struct` of the Pair, then
    // the two field destructions. The field drops run in reverse
    // declaration order — `b: Other` before `a: File` — so the Other
    // hook call precedes the File hook call.
    try testing.expect(std.mem.indexOf(u8, body, "unpack_struct %") != null);
    const other = std.mem.indexOf(u8, body, "call @app.Other.drop") orelse {
        return error.TestUnexpectedResult;
    };
    const file = std.mem.indexOf(u8, body, "call @app.File.drop") orelse {
        return error.TestUnexpectedResult;
    };
    try testing.expect(other < file);
    // No plain `drop` of the struct itself remains in main (its fields
    // are destroyed structurally).
    try testing.expect(std.mem.indexOf(u8, body, "drop %") == null);
}

test "drop lowering runs a struct's hook before its fields are destroyed" {
    // Runtime §6.2: the user hook runs while all fields remain valid —
    // the hook call is emitted on the whole value before the unpack.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const array = import("array");
            \\struct File {
            \\    arr: array.Array[int32];
            \\    drop(file) { builtin.print("closing"); }
            \\}
            \\fn main() -> void {
            \\    let f = File { arr: array.make(10, 0) };
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    const hook = std.mem.indexOf(u8, body, "call @app.File.drop") orelse {
        return error.TestUnexpectedResult;
    };
    const unpack = std.mem.indexOf(u8, body, "unpack_struct %") orelse {
        return error.TestUnexpectedResult;
    };
    try testing.expect(hook < unpack);
    // The opaque field's destruction reaches the runtime as a plain drop
    // (host side), after the hook ran.
    try testing.expect(std.mem.indexOf(u8, body, "drop %") != null);
}

test "drop lowering expands a tuple drop into reverse element drops" {
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\struct Other { fd: int32; drop(file) {} }
            \\fn open_file() -> File { File { fd: 3 } }
            \\fn open_other() -> Other { Other { fd: 4 } }
            \\fn main() -> void {
            \\    let x = open_file();
            \\    let y = open_other();
            \\    let t = (move x, move y);
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "unpack_tuple %") != null);
    // Reverse element order: the second element (`Other`) is destroyed
    // before the first (`File`).
    const other = std.mem.indexOf(u8, body, "call @app.Other.drop") orelse {
        return error.TestUnexpectedResult;
    };
    const file = std.mem.indexOf(u8, body, "call @app.File.drop") orelse {
        return error.TestUnexpectedResult;
    };
    try testing.expect(other < file);
}

test "drop lowering expands a box drop into unbox + contained drop" {
    // Runtime §6.3: destroying a `box[T]` destroys the contained value.
    // The expansion is `builtin#unbox` (which consumes the box and
    // returns ownership of the payload) followed by the payload's own
    // destruction.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; drop(file) {} }
            \\fn open_file() -> File { File { fd: 3 } }
            \\fn main() -> void {
            \\    let f = open_file();
            \\    let b = builtin.box(move f);
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "syscall builtin#unbox") != null);
    try testing.expect(std.mem.indexOf(u8, body, "call @app.File.drop") != null);
    try testing.expect(std.mem.indexOf(u8, body, "drop %") == null);
}

test "drop lowering expands a union drop into a tag switch" {
    // Runtime §6.3: only the active union variant is destroyed. The
    // expansion dispatches on the tag: payload-less variants destroy
    // nothing; payload variants `unpack_variant` and destroy the payload
    // (which itself recurses into its own expansion).
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; drop(file) {} }
            \\union Maybe {
            \\    Nothing,
            \\    Just(File),
            \\}
            \\fn open_file() -> File { File { fd: 3 } }
            \\fn main() -> void {
            \\    let f = open_file();
            \\    let m = Maybe::Just(move f);
            \\    let n = Maybe::Nothing;
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "read_tag %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "switch %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "unpack_variant %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "call @app.File.drop") != null);
    // The two unions converge on their joins; no plain `drop` of a
    // union remains.
    try testing.expect(std.mem.indexOf(u8, body, "drop %") == null);
}

test "drop lowering keeps opaque and any drops" {
    // The drops the CFG cannot expand stay single instructions: opaque
    // host types (`host_drop`) and `any` (dynamic tag). `hostdata` and
    // `list[T]` ride the same `expandable → false` guard (pass header):
    // `hostdata` cannot be constructed from Stilla source, and `list`
    // element count is dynamic (a runtime loop, Runtime §6.3). Here a
    // struct whose fields are an `any` and an opaque `Array[int32]`
    // expands to unpack + the two kept drops.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const array = import("array");
            \\struct S { a: any; arr: array.Array[int32]; }
            \\fn main() -> void {
            \\    let s = S { a: 42, arr: array.make(10, 0) };
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "unpack_struct %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "drop %") != null);
}

test "drop lowering substitutes generic instantiation args" {
    // `Option[File]`'s `Some` payload is `File`, not the declaration's
    // `T` — the payload type substitutes the instantiation's arguments
    // (Core §12.1), and its drop expands to the File destruction.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; drop(file) {} }
            \\union Option[T] {
            \\    None,
            \\    Some(T),
            \\}
            \\fn open_file() -> File { File { fd: 3 } }
            \\fn main() -> void {
            \\    let o: Option[File] = Option::Some(open_file());
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "unpack_variant %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "call @app.File.drop") != null);
}

test "drop lowering expands nested struct fields recursively" {
    // A struct field that is itself a struct recurses: the outer unpack
    // feeds the inner expansion, which eventually terminates in the
    // kept opaque drop. The whole sequence runs in the join of the outer
    // destruction's block.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const array = import("array");
            \\struct Inner { arr: array.Array[int32]; }
            \\struct Outer { inner: Inner; }
            \\fn main() -> void {
            \\    let o = Outer { inner: Inner { arr: array.make(10, 0) } };
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "unpack_struct %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "drop %") != null);
}

test "drop lowering handles a drop before a match in one block" {
    // `redirectSuccessors` must redirect the successors of a block split
    // by a union drop — including a conditional terminator (`match`
    // lowers to a `switch`; an `if` branch to a `branch_cond`). Here an
    // explicit `drop` of a union is followed by a `match` over a second
    // union in the same block: the drop's switch, then the match's
    // switch, in one block's tail.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; drop(file) {} }
            \\union Maybe {
            \\    Nothing,
            \\    Just(File),
            \\}
            \\fn open_file() -> File { File { fd: 3 } }
            \\fn main() -> void {
            \\    let f1 = open_file();
            \\    let f2 = open_file();
            \\    let m1 = Maybe::Just(move f1);
            \\    let m2 = Maybe::Just(move f2);
            \\    drop m1;
            \\    match (m2) {
            \\        Maybe::Nothing => builtin.print("none"),
            \\        Maybe::Just(f) => builtin.print(builtin.str(f.fd)),
            \\    }
            \\}
        },
    });
    defer c.deinit();
    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    // The explicit drop's switch and the match's switch both survive.
    try testing.expect(std.mem.indexOf(u8, body, "switch %") != null);
    try testing.expect(std.mem.indexOf(u8, body, "read_tag %") != null);
    // The match's payload binding (a borrow view of a non-consuming
    // match) and the drop's destruction both made it through the split.
    try testing.expect(std.mem.indexOf(u8, body, "call @app.File.drop") != null);
}

test "Pass 8.4 module/member CSE reuses identical loads in a block" {
    // `lib.ratio` lowers to `module_ref "lib"` + `load_member`, and the
    // on-the-fly CSE never shared them (module ops are not candidates at
    // emit time), so two reads of the same member in one block stay as
    // two loads until this pass. The module handle is a pure constant
    // and module storage is written only by `store_member` inside @init
    // (cfg_validate rejects stores elsewhere), so both fold to one.
    // A user-module constant member keeps this pass's load-CSE coverage:
    // a bundle intrinsic constant materializes instead (intrinsic plan,
    // phase 2 — see frontend_intrinsic_tests.zig).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const lib = import("lib");
            \\fn f() -> float32 {
            \\    let a = lib.ratio;
            \\    let b = lib.ratio;
            \\    a + b
            \\}
            \\fn main() -> void {}
        },
        .{
            "lib",
            \\const ratio: float32 = 1.5;
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.cse(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.f");
    try testing.expect(countOccurrences(body, "module_ref \"lib\"") == 1);
    try testing.expect(countOccurrences(body, "load_member") == 1);
}

test "Pass 8.4 copy propagation collapses copies of Copy values" {
    // The checker emits an explicit `copy` of the move parameter before
    // the ret; for a Copy type `move` is semantically an ordinary copy
    // (Core §10.2), so the copy is a no-op and the parameter is returned
    // directly. (`T` is deliberately a concrete Copy type: an undeclared
    // type name is now a diagnostic, Core §12.1.)
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn id(move x: int32) -> int32 { x }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    try lower.copyProp(&program, c.arena.allocator());

    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.id");
    try testing.expect(std.mem.indexOf(u8, body, "copy %") == null);
    try testing.expect(std.mem.indexOf(u8, body, "ret %0") != null);
}

test "Pass 8.4 copy propagation collapses box round-trip copies" {
    // `Token` is a plain Copy struct, so `box[Token]` is a Copy container
    // (Core §10.3) and `move` of it is an ordinary copy (Core §10.2). The
    // frontend's on-the-fly copy propagation folds that `copy` at the
    // emit site (optimizer.md, On-the-fly optimizations), so the round-trip compiles to a
    // direct `unbox` with no `copy` instruction anywhere; the mid-level
    // pass keeps it that way.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct Token { id: int32; }
            \\fn main() -> void {
            \\    let b = builtin.box::[int32](42);
            \\    let v = builtin.unbox::[int32](move b);
            \\    builtin.assert(v == 42, "unbox");
            \\    let t = builtin.box::[Token](Token { id: 7 });
            \\    let t2 = builtin.unbox::[Token](move t);
            \\    builtin.assert(t2.id == 7, "round-trip");
            \\}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    const before = try irText(&program);
    defer testing.allocator.free(before);
    try testing.expect(std.mem.indexOf(u8, funcBody(before, "func @app.main"), "copy %") == null);

    try lower.copyProp(&program, c.arena.allocator());
    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.main");
    try testing.expect(std.mem.indexOf(u8, body, "copy %") == null);
    try testing.expect(std.mem.indexOf(u8, body, "builtin#unbox") != null);
}

test "Pass 8.4 dead-instruction elimination drops unused match payloads" {
    // A `match` arm that binds the payload but returns a constant reads
    // the payload without using it: the `read_payload` is dead. It is a
    // guarded projection (the lowering emits it only after the tag
    // switch) with a Copy result, so the pass removes it.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\using builtin.Option;
            \\fn is_some(o: Option[int32]) -> bool {
            \\    match (o) {
            \\        Option::Some(v) => true,
            \\        Option::None => false,
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    var program = c.program.?;
    const before = try irText(&program);
    defer testing.allocator.free(before);
    const before_body = funcBody(before, "func @app.is_some");
    try testing.expect(std.mem.indexOf(u8, before_body, "read_payload") != null);

    try lower.deadInstr(&program, c.arena.allocator());
    const text = try irText(&program);
    defer testing.allocator.free(text);
    const body = funcBody(text, "func @app.is_some");
    try testing.expect(std.mem.indexOf(u8, body, "read_payload") == null);
}

test "Pass 8.0 inlining: nested splices keep block names unique and round-trip" {
    // fib_tail_call.st's `print_terms` TCO loop has `fib` (whose own body
    // holds a TCO'd `go` loop) inlined into it: the splice clones the
    // already-rewritten callee, so clone names collide with clones created
    // earlier in the same splice (two `entry_1`, two `inline_join`) unless
    // the name allocator sees them, and the return-phi substitution by
    // later passes must not leave a forward reference in the text form.
    const path = "examples/fib_tail_call.st";
    const src_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(src_text);
    var c = try compileText("app", &.{.{ "app", src_text }});
    defer c.deinit();
    try lower.optimize(&c.program.?, c.arena.allocator());

    const text = try irText(&c.program.?);
    defer testing.allocator.free(text);
    for (c.program.?.funcs) |f| {
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(testing.allocator);
        for (f.blocks) |b| {
            try testing.expect(!seen.contains(b.name));
            try seen.put(testing.allocator, b.name, {});
        }
    }
    // The optimized text is valid SSA text: it re-parses to the same
    // program (air.md §13), so a later print is byte-identical.
    var p = cfg.Parser.init(testing.allocator);
    defer p.deinit();
    const reparsed = try p.parse(text);
    const text2 = try irText(&reparsed);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "Pass 8.9 optimization harness: corpus compile, optimize, and measure" {
    // Compiles each example in the optimizer corpus once without and once
    // with the optimizer, printing instruction / block / text-byte counts
    // (optimizer.md, Pass 8.7). The optimizer must never grow the CFG, and the
    // optimized AIR must re-parse and re-print identically (air.md §13).
    const corpus = [_][]const u8{
        "examples/basics.st",
        "examples/fib.st",
        "examples/functions.st",
        "examples/structs.st",
        "examples/any.st",
        "examples/fib_tail_call.st",
        "examples/minmax.st",
        "examples/nest.st",
        "examples/ownership.st",
        "examples/match.st",
        "examples/strings.st",
        "examples/floats.st",
        "examples/fold.st",
        "examples/box.st",
        "examples/maps.st",
        "examples/arrays.st",
        "examples/generics.st",
        "examples/madd.st",
    };
    const io = std.testing.io;
    for (corpus) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(src);

        var raw = try compileText("app", &.{.{ "app", src }});
        defer raw.deinit();
        const raw_text = try irText(&raw.program.?);
        defer testing.allocator.free(raw_text);

        var opt = try compileText("app", &.{.{ "app", src }});
        defer opt.deinit();
        try lower.optimize(&opt.program.?, opt.arena.allocator());
        const opt_text = try irText(&opt.program.?);
        defer testing.allocator.free(opt_text);

        const before_instrs = countInstrs(&raw.program.?);
        const before_nonphi = countNonPhi(&raw.program.?);
        const before_blocks = countBlocks(&raw.program.?);
        const after_instrs = countInstrs(&opt.program.?);
        const after_nonphi = countNonPhi(&opt.program.?);
        const after_blocks = countBlocks(&opt.program.?);
        // Report the measurement only when stderr reaches a human: under
        // `zig build test` stderr is a captured pipe, and the build runner
        // replays any run-step stderr as an error (a spurious "failed
        // command:" line), so the report is gated on stderr being a TTY.
        if (std.Io.File.stderr().isTty(std.testing.io) catch false) {
            std.log.info(
                "harness {s}: {d} instr ({d} non-phi) {d} blocks {d} bytes -> {d} instr ({d} non-phi) {d} blocks {d} bytes",
                .{ path, before_instrs, before_nonphi, before_blocks, raw_text.len, after_instrs, after_nonphi, after_blocks, opt_text.len },
            );
        }

        // The inliner (Pass 8, first sub-pass) duplicates small callee
        // bodies, so the optimizer legitimately grows the CFG — bounded
        // by the inline budget (25/site) and the number of eligible call
        // sites, never by the caller. A generous sanity bound still
        // catches a runaway rewrite while leaving the inliner room to
        // work; TCO trades a tail call for a loop with parameter phis,
        // hence the non-phi metric.
        try testing.expect(after_nonphi <= before_nonphi + 200);
        try testing.expect(after_blocks <= before_blocks + 40);

        var p = cfg.Parser.init(testing.allocator);
        defer p.deinit();
        const reparsed = try p.parse(opt_text);
        const text2 = try irText(&reparsed);
        defer testing.allocator.free(text2);
        try testing.expectEqualStrings(opt_text, text2);
    }
}

test "frontend dispatches a two-arm list match on an emptiness test" {
    // Core §14.5: `[]` matches only the empty list, so a `match (xs) {
    // [] => A, [_, ..tail] => B }` must test emptiness and dispatch —
    // the `[]` arm is refutable, never an unconditional fallthrough.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn count_list(xs: list[int32]) -> int32 {
            \\    match (xs) {
            \\        [] => 0,
            \\        [_, ..tail] => 1 + count_list(tail),
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    const body = funcBody(out, "func @app.count_list");
    // The emptiness test: `list#len` of the scrutinee == 0, then a
    // conditional dispatch — the `[]` arm must not be reachable
    // unconditionally.
    try testing.expect(std.mem.indexOf(u8, body, "syscall list#len") != null);
    try testing.expect(std.mem.indexOf(u8, body, "br %") != null);
    try testing.expect(std.mem.indexOf(u8, body, " ? ") != null);
}

test "float fold to inf survives the optimizer round-trip" {
    // The emit-time fold of 4.0/0.0 produces an `inf` const; the
    // optimizer's print→re-parse round-trip must read it back (the text
    // form spells it `inf`/`-inf`/`nan`).
    var sources = moduleinfo.Sources{};
    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer source_map.deinit(testing.allocator);
    try source_map.put(testing.allocator, "app",
        \\fn f() -> float32 {
        \\    let x = 4.0 / 0.0;
        \\    x
        \\}
    );
    sources.source = source_map;
    var c = try frontend.compile(testing.allocator, .{ .entry = "app", .sources = sources, .entry_fn = "f", .optimize = true });
    defer c.deinit();
    const text = try cfg.print(&c.program.?, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "inf") != null);
}

// ---------------------------------------------------------------------------
// Phase 0 — self-contained AIR: concrete TypeDecls, the module
// member table, and syscall signatures, all queryable from `IrProgram`
// alone (air.md §9.1, §7, §8.2).
// ---------------------------------------------------------------------------

/// The `TypeId` of a named type by (module specifier, written name), or
/// null.
fn typeIdOf(program: *const cfg.IrProgram, module: []const u8, name: []const u8) ?u32 {
    for (program.types, 0..) |d, id| {
        const dmod: ?[]const u8 = switch (d) {
            .struct_ => |s| s.module,
            .union_ => |u| u.module,
            .opaque_ => |o| o.module,
            .unknown => null,
        };
        if (dmod) |m| {
            if (std.mem.eql(u8, m, module) and std.mem.eql(u8, d.name(), name)) return @intCast(id);
        }
    }
    return null;
}

/// The `TypeDecl` of a named type by (module, written name), or null.
fn typeDeclOf(program: *const cfg.IrProgram, module: []const u8, name: []const u8) ?cfg.TypeDecl {
    const id = typeIdOf(program, module, name) orelse return null;
    return program.typeDecl(@intCast(id));
}

/// The module with a resolved specifier, or null.
fn moduleByName2(program: *const cfg.IrProgram, spec: []const u8) ?*const cfg.IrModule {
    for (program.modules) |m| {
        if (std.mem.eql(u8, m.name, spec)) return m;
    }
    return null;
}

test "frontend type environment carries concrete TypeDecls (fields, variants, ownership, drop hook, opaque host ids)" {
    // air.md §9.1: the program's type environment resolves every nominal
    // type's layout, ownership, and destruction info without the module
    // graph — struct fields, union variants, drop-hook names, opaque
    // host ids, and generic ownership via argument substitution.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const array = import("array");
            \\using builtin.Option;
            \\struct File {
            \\    fd: int32;
            \\    path: str;
            \\    drop(f) {
            \\        builtin.print(f.path);
            \\    }
            \\}
            \\union Result {
            \\    Ok(int32),
            \\    Err(str),
            \\}
            \\fn main() -> void {
            \\    let f = File{ fd: 3, path: "x" };
            \\    let r = Result::Ok(1);
            \\    builtin.print(builtin.str(1));
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse return error.TestUnexpectedResult;

    // Struct: fields in declaration order, unique by the drop hook, with
    // the hidden hook function name.
    const file = typeDeclOf(&program, "app", "File") orelse return error.TestUnexpectedResult;
    try testing.expect(file == .struct_);
    const sd = file.struct_;
    try testing.expectEqualStrings("File", sd.name);
    try testing.expectEqualStrings("app", sd.module);
    try testing.expect(sd.ownership == .unique); // drop hook implies unique
    try testing.expectEqualStrings("app.File.drop", sd.drop.?);
    try testing.expectEqual(@as(usize, 0), sd.type_params.len);
    try testing.expectEqual(@as(usize, 2), sd.fields.len);
    try testing.expectEqualStrings("fd", sd.fields[0].name);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .int32 }), sd.fields[0].type_);
    try testing.expectEqualStrings("path", sd.fields[1].name);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .str }), sd.fields[1].type_);

    // Union: variants in declaration order with payload types; Copy
    // ownership (all payloads Copy).
    const result = typeDeclOf(&program, "app", "Result") orelse return error.TestUnexpectedResult;
    try testing.expect(result == .union_);
    const ud = result.union_;
    try testing.expect(ud.ownership == .copy);
    try testing.expectEqual(@as(usize, 2), ud.variants.len);
    try testing.expectEqualStrings("Ok", ud.variants[0].name);
    try testing.expectEqual(@as(usize, 1), ud.variants[0].payloads.len);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .int32 }), ud.variants[0].payloads[0]);
    try testing.expectEqualStrings("Err", ud.variants[1].name);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .str }), ud.variants[1].payloads[0]);

    // Opaque host type (Core §11.8): unique by declaration, host identity
    // naming the declaring module and the written type name.
    const array_ty = typeDeclOf(&program, "array", "Array") orelse return error.TestUnexpectedResult;
    try testing.expect(array_ty == .opaque_);
    const od = array_ty.opaque_;
    try testing.expect(od.ownership == .unique);
    try testing.expectEqualStrings("array", od.host_id.host_module);
    try testing.expectEqualStrings("Array", od.host_id.type_name);

    // Generic union: ownership deferred on the declaration, resolved per
    // instantiation by `IrProgram.namedOwnership` (Option[int32] is Copy,
    // Option[File] is unique).
    const option = typeDeclOf(&program, "builtin", "Option") orelse return error.TestUnexpectedResult;
    try testing.expect(option == .union_);
    const ou = option.union_;
    try testing.expect(ou.ownership == null); // generic: deferred
    try testing.expectEqual(@as(usize, 1), ou.type_params.len);
    try testing.expectEqualStrings("T", ou.type_params[0]);
    try testing.expectEqual(@as(usize, 2), ou.variants.len);
    try testing.expectEqualStrings("Some", ou.variants[0].name);
    try testing.expectEqual(@as(usize, 1), ou.variants[0].payloads.len);
    try testing.expectEqualStrings("T", ou.variants[0].payloads[0].param);

    const file_id = typeIdOf(&program, "app", "File") orelse return error.TestUnexpectedResult;
    const option_id = typeIdOf(&program, "builtin", "Option") orelse return error.TestUnexpectedResult;
    const arena = c.arena.allocator();
    var int_args = [_]cfg.Type{.{ .primitive = .int32 }};
    const int_arg: []cfg.Type = &int_args;
    try testing.expect(program.namedOwnership(arena, .{ .id = @intCast(option_id), .args = int_arg }) == .copy);
    var file_args = [_]cfg.Type{.{ .named = .{ .id = @intCast(file_id), .args = &.{} } }};
    const file_arg: []cfg.Type = &file_args;
    try testing.expect(program.namedOwnership(arena, .{ .id = @intCast(option_id), .args = file_arg }) == .unique);
}

test "frontend materializes the module member table with distinct member and slot index spaces" {
    // air.md §7, §9.6: every runtime value member gets one row in member
    // index order (the `load_member` operand space); a constant member's
    // storage slot is a *separate* index space (`store_member`).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const greeting: str = "hello";
            \\fn add(a: int32, b: int32) -> int32 { a + b }
            \\fn main() -> void {
            \\    let s = greeting;
            \\    let x = add(1, 2);
            \\    builtin.print(s);
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse return error.TestUnexpectedResult;

    const app = moduleByName2(&program, "app") orelse return error.TestUnexpectedResult;
    // Functions first (declaration order), then consts: add, main, the
    // `builtin` module value, greeting — so the greeting *member* index
    // (3) differs from its storage *slot* (0).
    const members = app.members.?;
    try testing.expectEqual(@as(usize, 4), members.len);
    try testing.expectEqualStrings("add", members[0].name);
    try testing.expect(members[0].kind == .function);
    try testing.expect(members[0].kind.function != null);
    try testing.expectEqualStrings("app.add", members[0].kind.function.?.name.text);
    try testing.expect(members[0].type_ == .function);
    try testing.expectEqualStrings("main", members[1].name);
    try testing.expect(members[1].kind == .function);
    try testing.expectEqualStrings("builtin", members[2].name);
    try testing.expect(members[2].kind == .module_ref);
    try testing.expectEqualStrings("builtin", members[2].kind.module_ref);
    try testing.expectEqual(@as(cfg.Type, .module), members[2].type_);
    try testing.expectEqualStrings("greeting", members[3].name);
    try testing.expect(members[3].kind == .const_slot);
    try testing.expectEqual(@as(?u32, 0), members[3].kind.const_slot);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .str }), members[3].type_);
    // The storage layout holds exactly the constant member, in slot
    // order — slot 0, distinct from member index 3.
    try testing.expectEqual(@as(usize, 1), app.slots.len);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .str }), app.slots[0].type_);

    // `load_member` resolves through the module identity of its base
    // (a `module_ref` value here): main's `greeting` read is member #3.
    const main = for (program.funcs) |f| {
        if (std.mem.eql(u8, f.name.text, "app.main")) break f;
    } else return error.TestUnexpectedResult;
    var found_load: ?*const cfg.Instr = null;
    for (main.blocks) |b| for (b.instrs) |instr| {
        if (instr.op == .load_member and instr.op.load_member.member == 3) found_load = instr;
    };
    const load = found_load orelse return error.TestUnexpectedResult;
    try testing.expectEqual(app, program.moduleOf(load.op.load_member.module).?);
}

test "validator rejects out-of-range member and slot indices by itself" {
    // The acceptance: every `load_member` / `store_member` resolves to a
    // legal member/slot via `IrProgram` alone — a mutated index is
    // rejected by `cfg.validate` with no checker involvement.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const greeting: str = "hello";
            \\fn main() -> void {
            \\    let s = greeting;
            \\    builtin.print(s);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    // The module: main (0), builtin (1, module value), greeting (2,
    // const slot 0).
    const app = moduleByName2(program, "app") orelse return error.TestUnexpectedResult;
    const main = for (program.funcs) |f| {
        if (std.mem.eql(u8, f.name.text, "app.main")) break f;
    } else return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Out-of-range member index.
    var lm: ?*cfg.Instr = null;
    for (main.blocks) |b| for (b.instrs) |instr| {
        if (instr.op == .load_member) lm = instr;
    };
    const load = lm orelse return error.TestUnexpectedResult;
    load.op.load_member.member = 99;
    var m = try lower.validate(program, arena.allocator());
    try testing.expect(m != null);
    try testing.expect(std.mem.indexOf(u8, m.?, "out of range") != null);
    load.op.load_member.member = 2; // restore

    // A member kind/type mismatch: load member #0 (the `main` function)
    // where the AIR expects a `str` constant — the member's type is a
    // function type, the result is str.
    load.op.load_member.member = 0;
    m = try lower.validate(program, arena.allocator());
    try testing.expect(m != null);
    try testing.expect(std.mem.indexOf(u8, m.?, "produces") != null);
    load.op.load_member.member = 2; // restore

    // Out-of-range store slot in @init.
    const init = app.init.?;
    var sm: ?*cfg.Instr = null;
    for (init.blocks) |b| for (b.instrs) |instr| {
        if (instr.op == .store_member) sm = instr;
    };
    const store = sm orelse return error.TestUnexpectedResult;
    store.op.store_member.slot = 7;
    m = try lower.validate(program, arena.allocator());
    try testing.expect(m != null);
    try testing.expect(std.mem.indexOf(u8, m.?, "out of range") != null);
    store.op.store_member.slot = 0; // restore

    // A store/load of the right shape validates again.
    m = try lower.validate(program, arena.allocator());
    try testing.expect(m == null);
}

test "store_member into an any-typed constant slot validates" {
    // The `T -> any` coercion is implicit at the constant boundary (air.md
    // §4.4): a concrete initializer is stored into the declared `any`
    // slot as-is, so the validator's store type check accepts any value
    // type for an `any`-typed slot (a regression guard — the member
    // table materialization must not reject it).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const x: any = 42;
            \\fn main() -> void { builtin.print(builtin.str(1)); }
        },
    });
    defer c.deinit();
    try testing.expect(c.program != null);
    const program = c.program.?;
    const app = moduleByName2(&program, "app") orelse return error.TestUnexpectedResult;
    const x_member = app.members.?[2]; // [main, builtin, x]
    try testing.expect(x_member.kind == .const_slot);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .any }), x_member.type_);
    try testing.expectEqual(@as(?u32, 0), x_member.kind.const_slot);
}

test "module identity resolves through chained module-valued member loads" {
    // lib's members: math (module value) only; math's members: sqrt.
    var c = try compileText("app", &.{
        .{ "math", "fn sqrt(x: int32) -> int32 { x }" },
        .{
            "lib",
            \\const math = import("math");
        },
        .{
            "app",
            \\const builtin = import("builtin");
            \\const lib = import("lib");
            \\fn main() -> void {
            \\    let s = lib.math.sqrt;
            \\    let r = s(4);
            \\    builtin.print(builtin.str(r));
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse return error.TestUnexpectedResult;

    // lib's members: math (module value) only; math's members: sqrt.
    const lib = for (program.modules) |m| {
        if (std.mem.eql(u8, m.name, "lib")) break m;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), lib.members.?.len);
    try testing.expect(lib.members.?[0].kind == .module_ref);
    try testing.expectEqualStrings("math", lib.members.?[0].kind.module_ref);
    const math = for (program.modules) |m| {
        if (std.mem.eql(u8, m.name, "math")) break m;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), math.members.?.len);
    try testing.expect(math.members.?[0].kind == .function);

    // The chain `module_ref "lib" -> load_member #0 -> load_member #0`:
    // both loads resolve their module from the AIR alone.
    const main = for (program.funcs) |f| {
        if (std.mem.eql(u8, f.name.text, "app.main")) break f;
    } else return error.TestUnexpectedResult;
    var loads = std.ArrayList(*const cfg.Instr).empty;
    defer loads.deinit(testing.allocator);
    for (main.blocks) |b| for (b.instrs) |instr| {
        if (instr.op == .load_member) try loads.append(testing.allocator, instr);
    };
    try testing.expectEqual(@as(usize, 2), loads.items.len);
    try testing.expectEqual(lib, program.moduleOf(loads.items[0].op.load_member.module).?);
    try testing.expectEqual(math, program.moduleOf(loads.items[1].op.load_member.module).?);
}

test "compiled syscalls carry the specialized signature" {
    // air.md §8.2, §9.3: `builtin.str`'s generic type parameter is
    // specialized from the argument, and the whole signature rides on the
    // syscall instruction.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    builtin.print(builtin.str(42));
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse return error.TestUnexpectedResult;

    const main = for (program.funcs) |f| {
        if (std.mem.eql(u8, f.name.text, "app.main")) break f;
    } else return error.TestUnexpectedResult;
    var str_sc: ?cfg.SysCall = null;
    var print_sc: ?cfg.SysCall = null;
    for (main.blocks) |b| for (b.instrs) |instr| {
        if (instr.op != .syscall) continue;
        const sc = instr.op.syscall;
        if (sc.target == .builtin and sc.target.builtin == .str) str_sc = sc;
        if (sc.target == .builtin and sc.target.builtin == .print) print_sc = sc;
    };
    const s = str_sc orelse return error.TestUnexpectedResult;
    const sig = s.sig.?;
    try testing.expectEqual(@as(usize, 1), sig.params.len);
    try testing.expect(sig.params[0].mode == .plain);
    // T specialized to int32 from the literal argument.
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .int32 }), sig.params[0].type_);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .str }), sig.ret.*);
    const p = print_sc orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .str }), p.sig.?.params[0].type_);
    try testing.expectEqual(@as(cfg.Type, .{ .primitive = .void }), p.sig.?.ret.*);
}

test "validator rejects a syscall mode/type/return mismatch from its signature alone" {
    // The acceptance: a plain/borrow/move mismatch is rejected by
    // `cfg.validate` independently — no checker annotation involved. The
    // text form carries no syscall signature, so the test attaches one
    // and mutates it, exactly as a corrupt producer would.
    const parse = struct {
        fn parseAndFindSyscall(text: []const u8) !struct { p: *cfg_parse.Parser, program: cfg.IrProgram, syscall: *cfg.Instr } {
            const parser = try testing.allocator.create(cfg_parse.Parser);
            parser.* = cfg_parse.Parser.init(testing.allocator);
            errdefer {
                parser.deinit();
                testing.allocator.destroy(parser);
            }
            const program = try parser.parse(text);
            const f = program.funcs[0];
            for (f.blocks) |b| for (b.instrs) |instr| {
                if (instr.op == .syscall) return .{ .p = parser, .program = program, .syscall = instr };
            };
            return error.TestUnexpectedResult;
        }
    }.parseAndFindSyscall;

    // A move-mode parameter fed a borrowed argument (a borrow-mode
    // parameter's value): a borrowed value can never be moved (Core
    // §10.7, air.md §6.2).
    {
        var t = try parse(
            \\module "app" {
            \\    func @f(borrow x: File) -> box[File] {
            \\    entry:
            \\        %1: box[File] = syscall builtin#box, %0
            \\        ret %1
            \\    }
            \\}
        );
        defer {
            t.p.deinit();
            testing.allocator.destroy(t.p);
        }
        const sc = &t.syscall.op.syscall;
        const ret_ptr = try testing.allocator.create(cfg.Type);
        const box_inner = try testing.allocator.create(cfg.Type);
        ret_ptr.* = .{ .box = box_inner };
        ret_ptr.*.box.* = .{ .named = .{ .id = 0, .args = &.{} } };
        const params = try testing.allocator.alloc(cfg.Param, 1);
        defer testing.allocator.free(params);
        defer testing.allocator.destroy(box_inner);
        defer testing.allocator.destroy(ret_ptr);
        params[0] = .{
            .span = ast.Span.init(0, 0, 0),
            .name = .{ .span = ast.Span.init(0, 0, 0), .text = "" },
            .mode = .move,
            .type_ = .{ .named = .{ .id = 0, .args = &.{} } },
        };
        sc.sig = .{ .params = params, .ret = ret_ptr };
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const m = try lower.validate(&t.program, arena.allocator());
        try testing.expect(m != null);
        try testing.expect(std.mem.indexOf(u8, m.?, "borrowed") != null);
    }

    // An argument type that does not match the signature's parameter
    // type, and a return type that does not match the signature's.
    {
        var t = try parse(
            \\module "app" {
            \\    func @main(xs: list[int32]) -> void {
            \\    entry:
            \\        %1: int32 = syscall list#len, %0
            \\        ret
            \\    }
            \\}
        );
        defer {
            t.p.deinit();
            testing.allocator.destroy(t.p);
        }
        const sc = &t.syscall.op.syscall;
        const ret_ptr = try testing.allocator.create(cfg.Type);
        ret_ptr.* = .{ .primitive = .int32 };
        const params = try testing.allocator.alloc(cfg.Param, 1);
        defer testing.allocator.free(params);
        defer testing.allocator.destroy(ret_ptr);
        const xs_type = t.syscall.op.syscall.args[0].type_;
        params[0] = .{
            .span = ast.Span.init(0, 0, 0),
            .name = .{ .span = ast.Span.init(0, 0, 0), .text = "" },
            .mode = .borrow,
            .type_ = xs_type,
        };
        sc.sig = .{ .params = params, .ret = ret_ptr };
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        // Valid as attached: argument and return types match.
        try testing.expect((try lower.validate(&t.program, arena.allocator())) == null);

        // Parameter type mismatch.
        sc.sig.?.params[0].type_ = .{ .primitive = .str };
        const m1 = try lower.validate(&t.program, arena.allocator());
        try testing.expect(m1 != null);
        try testing.expect(std.mem.indexOf(u8, m1.?, "does not match parameter type") != null);

        // Return type mismatch.
        sc.sig.?.params[0].type_ = xs_type; // restore
        sc.sig.?.ret.* = .{ .primitive = .str };
        const m2 = try lower.validate(&t.program, arena.allocator());
        try testing.expect(m2 != null);
        try testing.expect(std.mem.indexOf(u8, m2.?, "does not match return type") != null);
    }
}
