//! Test file: `checker` — the type checker / AST annotator.
//!
//! White-box tests of `src/passes/checker.zig`'s own internals stay in that
//! module's file; this file aggregates them so they are analyzed and run,
//! and adds black-box tests of the checker driven through the full
//! front-end phase-1 pipeline (a program must load and parse before it can
//! be annotated).

const std = @import("std");
const ast = @import("ast.zig");
const cfg = @import("cfg.zig");
const checker = @import("passes/checker.zig");
const moduleinfo = @import("moduleinfo.zig");
const testing = std.testing;

test {
    // White-box tests of the module file in this slice.
    _ = @import("passes/checker.zig");
}

// ---------------------------------------------------------------------------
// checker — black-box: the checker driven through phase 1 (a program must
// load and parse before it can be annotated).
// ---------------------------------------------------------------------------

fn checkText(text: []const u8) !struct { arena: std.heap.ArenaAllocator, graph: *moduleinfo.ModuleGraph, ann: checker.Annotation } {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(arena.allocator(), "test", text);

    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .source = source_map });
    const graph = try builder.build("test");

    var ck = checker.Checker.init(arena.allocator());
    const ann = try ck.check(graph);
    return .{ .arena = arena, .graph = graph, .ann = ann };
}

test "checker flags host bindings and leaves definitions alone" {
    var t = try checkText(
        \\fn host_fn(x: int32) -> int32;
        \\fn local_fn(x: int32) -> int32 { x }
    );
    defer t.arena.deinit();

    var saw_host = false;
    var saw_local = false;
    for (t.graph.modules[0].program.?.items) |*item| switch (item.*) {
        .func_def => |*f| {
            if (std.mem.eql(u8, f.name.text, "host_fn")) {
                saw_host = true;
                try testing.expect(t.ann.host_bindings.contains(f));
            } else if (std.mem.eql(u8, f.name.text, "local_fn")) {
                saw_local = true;
                try testing.expect(!t.ann.host_bindings.contains(f));
            }
        },
        else => {},
    };
    try testing.expect(saw_host);
    try testing.expect(saw_local);
}

test "checker flags generic host bindings and leaves bodies alone" {
    // A generic declaration without a body is a host binding (phase3-cfg-lowering.md, System calls for host bindings)
    // binding too (`builtin.str[T]` etc., Runtime §4).
    var t = try checkText(
        \\fn str[T](value: T) -> str;
        \\fn identity[T](move value: T) -> T { move value }
    );
    defer t.arena.deinit();

    var saw_generic_host = false;
    var saw_defined = false;
    for (t.graph.modules[0].program.?.items) |*item| switch (item.*) {
        .func_def => |*f| {
            if (std.mem.eql(u8, f.name.text, "str")) {
                saw_generic_host = true;
                try testing.expect(t.ann.host_bindings.contains(f));
            } else if (std.mem.eql(u8, f.name.text, "identity")) {
                saw_defined = true;
                try testing.expect(!t.ann.host_bindings.contains(f));
            }
        },
        else => {},
    };
    try testing.expect(saw_generic_host);
    try testing.expect(saw_defined);
}

test "checker ignores non-function module items" {
    // Structs, unions, consts, and using declarations are not host
    // bindings; check() annotates them without flagging them.
    var t = try checkText(
        \\const version: int32;
        \\struct File { fd: int32; }
        \\union Opt { Some(int32), None }
        \\using builtin.Option;
    );
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker annotates an empty program" {
    // A module with no function members yields an empty annotation, not
    // an error.
    var t = try checkText(
        \\const version: int32 = 1;
        \\struct Point { x: float32; y: float32; }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker distinguishes a defined body with a trailing expression" {
    // A function with a body is never a host binding, even when the body
    // is an implicit return of an expression (Core §6).
    var t = try checkText("fn answer() -> int32 { 42 }");
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

// ---------------------------------------------------------------------------
// checker — phase-2 checks (phase2-checker.md, Checks enabled by annotation): type mismatch, match
// exhaustiveness, ownership transfer.
// ---------------------------------------------------------------------------

fn expectDiag(text: []const u8, want: []const u8) !void {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(arena.allocator(), "test", text);

    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .source = source_map });
    const graph = try builder.build("test");

    var ck = checker.Checker.init(arena.allocator());
    try testing.expectError(error.Diagnostic, ck.check(graph));
    try testing.expect(ck.diag != null);
    try testing.expect(std.mem.indexOf(u8, ck.diag.?.message, want) != null);
}

test "checker rejects a call with the wrong argument count" {
    try expectDiag(
        \\fn pair(a: int32, b: int32) -> int32 { a + b }
        \\fn main() -> int32 { pair(1) }
    , "expected 2 arguments, found 1");
}

test "checker rejects a call with an argument type mismatch" {
    try expectDiag(
        \\fn greet(name: str) -> str { name }
        \\fn main() -> str { greet(42) }
    , "argument type mismatch");
}

test "checker rejects a return type mismatch" {
    try expectDiag(
        \\fn answer() -> int32 { "nope" }
    , "return type mismatch");
}

test "checker rejects a binary operator type mismatch" {
    try expectDiag(
        \\fn add(a: int32, b: str) -> int32 { a + b }
    , "type mismatch in operator");
}

test "checker widens integer literals to the other binary operand's width" {
    // Core Types §16.3: the other operand of a numeric binary operator is
    // an explicit type context, on either side of the operator — `a - 1`
    // with `a: i64` types the literal at i64.
    const t = try checkText(
        \\fn sub(a: i64) -> i64 { a - 1 }
        \\fn add(a: i64) -> i64 { 1 + a }
        \\fn cmp(a: i64) -> bool { a == 0 }
        \\fn shi(a: u64) -> u64 { a >> 1 }
        \\fn call() -> i64 { brand(1) }
        \\fn brand(x: i64) -> i64 { x }
        \\fn um(a: uint32) -> uint32 { a - 1 }
        \\fn ul(a: uint32) -> uint32 { 1 + a }
        \\fn ucall() -> uint32 { uarg(7) }
        \\fn uarg(x: uint32) -> uint32 { x }
    );
    defer t.arena.deinit();

    try expectDiag(
        \\fn big() -> uint32 { 5000000000 }
    , "uint32 literal magnitude");
}

test "checker types float literals at the other binary operand's width" {
    // The float mirror of the int rule (Core Types §16.3): a float literal
    // in an explicit float type context types at that width — `a - 1.5`
    // with `a: f64` types the literal at f64.
    const t = try checkText(
        \\fn dsub(a: f64) -> f64 { a - 1.5 }
        \\fn dadd(a: f64) -> f64 { 1.5 + a }
        \\fn dcmp(a: f64) -> bool { a >= 2.5 }
        \\fn fs(a: float32) -> float32 { a + 0.5 }
        \\fn dcall() -> f64 { rounder(2.5) }
        \\fn rounder(x: f64) -> f64 { x }
    );
    defer t.arena.deinit();
}

test "checker accepts integer shifts and rejects float/byte/mixed shifts" {
    // Core §16.3: `<<`/`>>` take same-type int32/uint32 operands;
    // float32 has no bit pattern to shift and byte has no arithmetic.
    var t = try checkText(
        \\fn l(a: int32, n: int32) -> int32 { a << n }
        \\fn r(a: uint32, n: uint32) -> uint32 { a >> n }
    );
    defer t.arena.deinit();

    try expectDiag(
        \\fn bad(a: float32) -> float32 { a << 1 }
    , "shift operator requires matching int32/uint32 operands");
    try expectDiag(
        \\fn bad(a: byte) -> byte { a >> 1 as byte }
    , "shift operator requires matching int32/uint32 operands");
    try expectDiag(
        \\fn bad(a: int32, n: uint32) -> int32 { a << n }
    , "shift operator requires matching int32/uint32 operands");
}

test "checker accepts integer bitwise ops and rejects float/byte/mixed/bool" {
    // Core §16.3: `&`/`|`/`^` take same-type int32/uint32 operands;
    // float32 has no bit pattern, byte has no arithmetic, and the
    // boolean `and`/`or` keywords are the only logical ops on bool.
    var t = try checkText(
        \\fn a(x: int32, y: int32) -> int32 { x & y }
        \\fn o(x: uint32, y: uint32) -> uint32 { x | y }
        \\fn x(x: int32, y: int32) -> int32 { x ^ y }
    );
    defer t.arena.deinit();

    try expectDiag(
        \\fn bad(a: float32) -> float32 { a & 1 }
    , "bitwise operator requires matching int32/uint32 operands");
    try expectDiag(
        \\fn bad(a: byte) -> byte { a | 1 as byte }
    , "bitwise operator requires matching int32/uint32 operands");
    try expectDiag(
        \\fn bad(a: int32, b: uint32) -> int32 { a ^ b }
    , "bitwise operator requires matching int32/uint32 operands");
    try expectDiag(
        \\fn bad(a: bool, b: bool) -> bool { a & b }
    , "bitwise operator requires matching int32/uint32 operands");
}

test "checker accepts float remainder (Core §16.3: float32 % float32)" {
    var t = try checkText(
        \\fn f(a: float32, b: float32) -> float32 { a % b }
    );
    defer t.arena.deinit();
}

test "checker rejects an invalid cast" {
    try expectDiag(
        \\fn cvt(x: bool) -> int32 { x as int32 }
    , "invalid cast");
}

test "checker rejects a non-exhaustive union match" {
    try expectDiag(
        \\union R { Ok(int32), Err(str) }
        \\fn f(r: R) -> int32 { match (r) { R::Ok(v) => v } }
    , "match is not exhaustive");
}

test "checker accepts an exhaustive union match" {
    // No diagnostic; the lowerer owns the AIR generation.
    var t = try checkText(
        \\union R { Ok(int32), Err(str) }
        \\fn f(r: R) -> int32 { match (r) { R::Ok(v) => v, R::Err(e) => 0 } }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts an exhaustive union match through a using alias" {
    // Core §2.8: a `using ... as` alias denotes the path as a whole, so
    // `Opt::Some(..)` in pattern position is the same union as the
    // scrutinee `Opt[int32]` and must count toward exhaustiveness.
    // (No diagnostic; the lowerer owns the AIR generation.)
    var t = try checkText(
        \\const builtin = import("builtin");
        \\using builtin.Option as Opt;
        \\fn f(o: Opt[int32]) -> int32 { match (o) { Opt::Some(v) => v, Opt::None => 0 } }
    );
    defer t.arena.deinit();
}

test "checker rejects use of a moved unique value" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn open() -> File { File{ fd: 1 } }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void { let f = open(); consume(move f); let g = f; }
    , "use of moved value");
}

test "checker rejects a refutable let pattern" {
    try expectDiag(
        \\fn f(a: any) -> int32 { let int32 n = a; n }
    , "refutable");
}

test "checker rejects a let type mismatch" {
    try expectDiag(
        \\fn f() -> int32 { let x: int32 = "nope"; 0 }
    , "let type mismatch");
}

test "checker accepts a type-test match over any" {
    // The only place type-test patterns are legal is a `match` over `any`,
    // and such a match must carry a wildcard arm (Core §11.6.2, §14.7).
    var t = try checkText(
        \\fn describe(a: any) -> int32 { match (a) { int32 n => n, str s => 1, _ => -1 } }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

// ---------------------------------------------------------------------------
// checker — ownership: conditional release and state merging (phase2-checker.md, Ownership analysis,
// Core §10.10): a binding released on some but not all paths through an
// if/match/and/or becomes *maybe-unique* (still owned on some paths, dead on
// others — the implementation tracks its runtime liveness), and a binding
// released on every path is definitely released.
// ---------------------------------------------------------------------------

fn countBindingsWithState(t: anytype, want: checker.BindingState) !usize {
    const ma = t.ann.per_module.get("test").?;
    var count: usize = 0;
    var it = ma.bindings.valueIterator();
    while (it.next()) |state| {
        if (state.* == want) count += 1;
    }
    return count;
}

test "checker marks a binding released on only one if branch as maybe" {
    // Core §10.10: `consume(move f)` in the then branch but not the else
    // leaves `f` owned on one normal path and dead on the other — the
    // binding becomes maybe-unique (no rejection).
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { consume(move f); } else { }
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 1), try countBindingsWithState(t, .maybe));
}

test "checker marks a binding released by one match arm as maybe" {
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    match (1) {
        \\        1 => { consume(move f); },
        \\        _ => {}
        \\    }
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 1), try countBindingsWithState(t, .maybe));
}

test "checker marks a binding released by a short-circuit right operand as maybe" {
    // Core §16.2: the right operand of and/or runs on one path only.
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    true and { drop f; true };
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 1), try countBindingsWithState(t, .maybe));
}

test "checker marks a binding released by the other short-circuit operand as maybe" {
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    false or { drop f; true };
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 1), try countBindingsWithState(t, .maybe));
}

test "checker accepts releasing a binding on every if branch and marks it released" {
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { consume(move f); } else { consume(move f); }
        \\}
    );
    defer t.arena.deinit();

    // The annotation records exactly one definitely-released binding.
    const ma = t.ann.per_module.get("test").?;
    var released_count: usize = 0;
    var it = ma.bindings.valueIterator();
    while (it.next()) |state| {
        if (state.* == .released) released_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), released_count);
}

test "checker rejects use of a definitely-released binding" {
    // Core §10.10: after the construct, `f` is definitely released and any
    // use is a use-after-move (§18).
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { consume(move f); } else { consume(move f); };
        \\    let g = f;
        \\}
    , "use of released value");
}

test "checker rejects moving a definitely-released binding" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { consume(move f); } else { consume(move f); };
        \\    consume(move f);
        \\}
    , "use of released value");
}

test "checker rejects explicitly dropping a definitely-released binding" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { drop f; } else { drop f; };
        \\    drop f;
        \\}
    , "use of released value");
}

test "checker rejects moving a binding twice" {
    // Core §18: an owner may be moved at most once.
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    consume(move f);
        \\    consume(move f);
        \\}
    , "already-moved");
}

test "checker rejects moving a borrowed binding" {
    // Core §18 *Borrowing*: a borrowed unique value cannot be moved.
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main(borrow f: File) -> void { consume(move f); }
    , "cannot move borrowed binding");
}

test "checker accepts a trap path that does not release" {
    // Core §10.10: a never/trap path is not normal control flow, so it
    // neither satisfies nor violates the release requirement; releasing on
    // the one normal path makes the binding definitely released.
    var t = try checkText(
        \\const builtin = import("builtin");
        \\fn die() -> never { builtin.panic("x") }
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { consume(move f); } else { die() }
        \\}
    );
    defer t.arena.deinit();
    const ma = t.ann.per_module.get("test").?;
    var released_count: usize = 0;
    var it = ma.bindings.valueIterator();
    while (it.next()) |state| {
        if (state.* == .released) released_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), released_count);
}

test "checker marks a release conditional inside a match arm as maybe" {
    // The arm body is itself an if that releases on one path only: the
    // arm's own merge makes the binding maybe-unique, and the match merge
    // carries it forward.
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    match (1) {
        \\        1 => if (true) { consume(move f); } else { },
        \\        _ => { }
        \\    }
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 1), try countBindingsWithState(t, .maybe));
}

test "checker rejects use of a maybe-unique binding" {
    // Core §10.10: after a construct that releases a binding on some but
    // not all paths, the binding is maybe-unique and any use is rejected.
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { consume(move f); } else { };
        \\    consume(move f);
        \\}
    , "maybe-released");
}

test "checker accepts a construct after a binding was already released" {
    // Core §10.10: a binding released before the construct is entered is
    // already dead at entry, so the construct need not release it again.
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    consume(move f);
        \\    if (true) { } else { };
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

// ---------------------------------------------------------------------------
// checker — ownership transfer and borrow lifetimes (phase2-checker.md, Checks enabled by annotation; Core
// §10.6, §10.7, §14.6, §18): a plain parameter accepts only Copy
// arguments; a move parameter requires an explicit `move` of an existing
// unique owner; a borrowed unique value cannot be moved, dropped, returned
// as owned, or stored into an owning location; consumingly destructuring a
// struct that defines a drop hook is rejected; a function or lambda may not
// capture a local binding from an enclosing function scope (Core §6.2).
// ---------------------------------------------------------------------------

test "checker rejects passing an unique value to a plain parameter" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn peek(f: File) -> int32 { f.fd }
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    let g = peek(f);
        \\}
    , "plain parameter accepts only Copy arguments");
}

test "checker accepts a Copy argument to a plain parameter" {
    var t = try checkText(
        \\fn add(a: int32, b: int32) -> int32 { a + b }
        \\fn main() -> int32 { add(1, 2) }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker requires an explicit move before a move parameter" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    consume(f);
        \\}
    , "must be moved with 'move'");
}

test "checker accepts an explicit move into a move parameter" {
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    consume(move f);
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts a fresh unique value into a move parameter" {
    // A fresh unique value transfers ownership implicitly (Core §18).
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void { consume(File{ fd: 1 }) }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects moving a value into a borrow parameter" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn inspect(borrow f: File) -> int32 { f.fd }
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    let g = inspect(move f);
        \\}
    , "cannot move a value into a borrow parameter");
}

test "checker borrows an unique payload of a non-consuming match" {
    // Core §13.4: matching an unique owner through an ordinary expression
    // borrows it, so the payload binding is a borrow and cannot be moved.
    try expectDiag(
        \\union U { Some(File), None }
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let u = U::Some(File{ fd: 1 });
        \\    match (u) { U::Some(f) => 0, U::None => 0 };
        \\    consume(move f);
        \\}
    , "cannot move borrowed binding");
}

test "checker accepts moving the payload of a consuming match" {
    // Core §13.4: `match (move u)` consumes the complete owner, so the
    // payload binding owns the moved value and may be moved onward.
    var t = try checkText(
        \\union U { Some(File), None }
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let u = U::Some(File{ fd: 1 });
        \\    match (move u) { U::Some(f) => consume(move f), U::None => 0 };
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects returning a borrowed value as owned" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn identity(borrow f: File) -> File { f }
    , "cannot return a borrowed value as owned");
}

test "checker rejects storing a borrowed value into an owning binding" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn main(borrow f: File) -> void {
        \\    let g = f;
        \\}
    , "cannot store a borrowed value into an owning binding");
}

test "checker rejects a consuming destructure of a drop-hook struct" {
    // Core §14.6 *Whole-owner*: a consuming destructure of a struct that
    // defines its own drop hook is a compile-time error.
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn main() -> void {
        \\    let s = File{ fd: 1 };
        \\    match (move s) { File{ fd: x } => {} };
        \\}
    , "cannot consumingly destructure a struct that defines a drop hook");
}

test "checker rejects a lambda capturing an enclosing local" {
    // Core §6.2: lambdas may reference their own params, module members,
    // and builtins — but not a local binding from an enclosing function.
    try expectDiag(
        \\fn make() -> fn(int32) -> int32 {
        \\    let factor = 2;
        \\    fn (x: int32) -> int32 { x + factor }
        \\}
    , "lambda may not capture enclosing local binding");
}

test "checker accepts a lambda referencing only its own scope" {
    // Referencing the lambda's own parameter and a module constant is not
    // capture (Core §6.2).
    var t = try checkText(
        \\const scale = 2;
        \\fn make() -> fn(int32) -> int32 {
        \\    fn (x: int32) -> int32 { x * scale }
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects use of a binding consumed by a match scrutinee" {
    // Regression: `match (move u)` consumes the owner, so using `u` after
    // the match is a use-after-move (Core §18).
    try expectDiag(
        \\union U { Some(File), None }
        \\struct File { fd: int32; drop(file) {} }
        \\fn main() -> void {
        \\    let u = U::Some(File{ fd: 1 });
        \\    match (move u) { U::Some(f) => {}, U::None => {} };
        \\    let g = u;
        \\}
    , "use of moved value");
}

// ---------------------------------------------------------------------------
// checker — generic expansion (phase2-checker.md, Generic expansion; Core §12): a specialization
// produces a monomorphized instance that is checked under substitution.
// ---------------------------------------------------------------------------

test "checker leaves an unspecialized generic body unchecked" {
    // Core §12.4: a template body is never checked until it is specialized.
    // `strOnly`'s body is wrong under every substitution, but the bare
    // definition must not be rejected.
    var t = try checkText(
        \\fn strOnly[T](x: T) -> str { x }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker checks the monomorphized body of a generic call" {
    // Core §12.4: the body is checked under the concrete substitution, so
    // `strOnly(42)` (T = int32) reports the return type mismatch.
    try expectDiag(
        \\fn strOnly[T](x: T) -> str { x }
        \\fn main() -> void { let s = strOnly(42); }
    , "return type mismatch");
}

test "checker deduplicates generic specializations" {
    // Generic expansion: instances are keyed by (declaration, type arguments);
    // two calls with the same args share one instance and one mono body.
    var t = try checkText(
        \\fn id[T](move x: T) -> T { move x }
        \\fn main() -> void { let a = id(42); let b = id(7); }
    );
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 1), t.ann.instances.items.len);
    const inst = t.ann.instances.items[0];
    try testing.expectEqual(@as(usize, 1), inst.type_args.len);
    try testing.expectEqual(cfg.Type{ .primitive = .int32 }, inst.type_args[0]);
    switch (inst.signature) {
        .function => |f| {
            try testing.expectEqual(@as(usize, 1), f.params.len);
            try testing.expectEqual(cfg.Type{ .primitive = .int32 }, f.params[0].type_);
            try testing.expectEqual(cfg.Type{ .primitive = .int32 }, f.ret.*);
        },
        else => try testing.expect(false),
    }
    try testing.expect(inst.mono != null);
}

test "checker specializes an explicitly annotated generic call" {
    // Core §12.3: `id::[int32](42)` specializes by explicit type argument.
    var t = try checkText(
        \\fn id[T](x: T) -> T { x }
        \\fn main() -> void { let a = id::[int32](42); }
    );
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 1), t.ann.instances.items.len);
    const inst = t.ann.instances.items[0];
    switch (inst.signature) {
        .function => |f| try testing.expectEqual(cfg.Type{ .primitive = .int32 }, f.ret.*),
        else => try testing.expect(false),
    }

    // The call site maps to the instance via `call_of`.
    const ma = t.ann.per_module.get("test").?;
    var found = false;
    for (t.graph.modules[0].program.?.items) |*item| switch (item.*) {
        .func_def => |*f| {
            if (std.mem.eql(u8, f.name.text, "main")) {
                for (f.body.?.stmts) |*s| switch (s.*) {
                    .let => |*l| switch (l.init.*) {
                        .call => |*c| {
                            found = true;
                            try testing.expect(ma.call_of.get(c) == inst);
                        },
                        else => {},
                    },
                    else => {},
                };
            }
        },
        else => {},
    };
    try testing.expect(found);
}

test "checker accepts an explicitly specialized generic as a value" {
    // Core §12.4: `id::[int32]` is a first-class monomorphic function value;
    // only the bare template `id` is rejected.
    var t = try checkText(
        \\fn id[T](move x: T) -> T { move x }
        \\fn main() -> void { let f = id::[int32]; }
    );
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 1), t.ann.instances.items.len);
    const inst = t.ann.instances.items[0];
    switch (inst.signature) {
        .function => |f| {
            try testing.expectEqual(@as(usize, 1), f.params.len);
            try testing.expectEqual(cfg.Type{ .primitive = .int32 }, f.params[0].type_);
            try testing.expectEqual(cfg.Type{ .primitive = .int32 }, f.ret.*);
        },
        else => try testing.expect(false),
    }

    // The specialization expression maps to the instance via `spec_of`.
    const ma = t.ann.per_module.get("test").?;
    var found = false;
    for (t.graph.modules[0].program.?.items) |*item| switch (item.*) {
        .func_def => |*f| {
            if (std.mem.eql(u8, f.name.text, "main")) {
                for (f.body.?.stmts) |*s| switch (s.*) {
                    .let => |*l| switch (l.init.*) {
                        .specialize => |*sp| {
                            found = true;
                            try testing.expect(ma.spec_of.get(sp) == inst);
                        },
                        else => {},
                    },
                    else => {},
                };
            }
        },
        else => {},
    };
    try testing.expect(found);
}

test "checker rejects an unspecialized generic function as a value" {
    // Core §12.4: referencing the template itself (`id`) as a value is an
    // error; only an explicit specialization is a monomorphic value.
    try expectDiag(
        \\fn id[T](x: T) -> T { x }
        \\fn main() -> void { let f = id; }
    , "unspecialized generic");
}

test "checker specializes a generic host binding without a body" {
    // Host-binding instances have no body to expand (phase3-cfg-lowering.md, System calls for host bindings).
    var t = try checkText(
        \\fn len[T](borrow xs: list[T]) -> int32;
        \\fn main() -> int32 { len([1, 2, 3]) }
    );
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 1), t.ann.instances.items.len);
    const inst = t.ann.instances.items[0];
    try testing.expect(inst.mono == null);
    switch (inst.signature) {
        .function => |f| {
            try testing.expectEqual(@as(usize, 1), f.params.len);
            try testing.expectEqual(cfg.Type{ .primitive = .int32 }, f.ret.*);
        },
        else => try testing.expect(false),
    }
}

test "checker rejects a specialization with the wrong type argument count" {
    try expectDiag(
        \\fn id[T](x: T) -> T { x }
        \\fn main() -> void { let a = id::[int32, str](42); }
    , "expected 1 type argument(s), found 2");
}

test "checker rejects a generic call it cannot fully infer" {
    try expectDiag(
        \\fn pick[A, B](x: A, y: B) -> B { y }
        \\fn main() -> void { let p = pick(1); }
    , "cannot infer type argument 'B'");
}

// ---------------------------------------------------------------------------
// checker — host-backed opaque nominal types (Core §11.8)
// ---------------------------------------------------------------------------

/// The hostlib standard-library module used by the opaque-type tests: an
/// opaque declaration plus host bindings that construct, consume, and
/// pass opaque values.
const OPAQUE_LIB =
    \\opaque type Handle[T];
    \\fn make[T]() -> Handle[T];
    \\fn pass[T](move h: Handle[T]) -> Handle[T];
;

/// Build an app (a source module) against `hostlib`, a standard-library
/// module that may declare opaque host types (Core §11.8). The hostlib
/// text is registered in the `standard_library` map, so its opaque
/// declarations are legal; the app is an ordinary source module importing
/// it.
fn checkOpaqueText(hostlib: []const u8, app: []const u8) !struct { arena: std.heap.ArenaAllocator, graph: *moduleinfo.ModuleGraph, ann: checker.Annotation } {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(arena.allocator(), "app", app);
    var std_map = std.StringHashMapUnmanaged([]const u8).empty;
    try std_map.put(arena.allocator(), "hostlib", hostlib);

    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .source = source_map, .standard_library = std_map });
    const graph = try builder.build("app");

    var ck = checker.Checker.init(arena.allocator());
    const ann = try ck.check(graph);
    return .{ .arena = arena, .graph = graph, .ann = ann };
}

fn expectOpaqueDiag(hostlib: []const u8, app: []const u8, want: []const u8) !void {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(arena.allocator(), "app", app);
    var std_map = std.StringHashMapUnmanaged([]const u8).empty;
    try std_map.put(arena.allocator(), "hostlib", hostlib);

    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .source = source_map, .standard_library = std_map });
    const graph = try builder.build("app");

    var ck = checker.Checker.init(arena.allocator());
    try testing.expectError(error.Diagnostic, ck.check(graph));
    try testing.expect(ck.diag != null);
    try testing.expect(std.mem.indexOf(u8, ck.diag.?.message, want) != null);
}

test "checker rejects raw construction of an opaque host type" {
    // Core §11.8: an opaque host type has no fields and no Stilla-side
    // construction — `Handle{ ... }` is a compile-time error, not a
    // runtime hazard.
    try expectOpaqueDiag(OPAQUE_LIB,
        \\const hostlib = import("hostlib");
        \\using hostlib.Handle;
        \\fn main() -> void {
        \\    let h = Handle{};
        \\}
    , "cannot be constructed in source");
}

test "checker rejects variant construction of an opaque host type" {
    try expectOpaqueDiag(OPAQUE_LIB,
        \\const hostlib = import("hostlib");
        \\fn main() -> void {
        \\    let h = hostlib.Handle::Some(1);
        \\}
    , "is not a union");
}

test "checker rejects member access on an opaque host type" {
    try expectOpaqueDiag(OPAQUE_LIB,
        \\const hostlib = import("hostlib");
        \\fn f(h: hostlib.Handle[int32]) -> int32 {
        \\    h.value
        \\}
    , "has no fields");
}

test "checker rejects an opaque declaration in a source module" {
    // Core §11.8: `opaque type` is legal only in a standard-library or
    // host-provided module interface.
    try expectDiag(
        \\opaque type Handle;
        \\fn main() -> void {}
    , "may only be declared by a standard-library or host-provided module");
}

test "checker classifies an opaque host type as unique" {
    // Core §11.8: an opaque type is unique by declaration — implicit copy
    // is rejected even though the type argument is Copy.
    try expectOpaqueDiag(OPAQUE_LIB,
        \\const hostlib = import("hostlib");
        \\fn main() -> void {
        \\    let a = hostlib.make::[int32]();
        \\    let b = a;
        \\}
    , "unique value must be moved with 'move'");
}

test "checker accepts move, borrow, and any-pack of an opaque host type" {
    // Core §11.8: an opaque value is a normal nominal value — moved,
    // borrowed, stored, and packed into `any` like any other unique value.
    var t = try checkOpaqueText(OPAQUE_LIB,
        \\const hostlib = import("hostlib");
        \\fn f(borrow h: hostlib.Handle[int32]) -> int32 { 0 }
        \\fn main() -> void {
        \\    let a = hostlib.make::[int32]();
        \\    let c = move a;
        \\    let d = hostlib.pass(move c);
        \\    let e = f(d);
        \\    let x: any = move d;
        \\}
    );
    defer t.arena.deinit();
    // The hostlib module's opaque declaration is a registered type member.
    const hostlib = t.graph.module("hostlib") orelse return error.TestUnexpectedResult;
    try testing.expect(hostlib.typeMember("Handle") != null);
}

// ---------------------------------------------------------------------------
// checker — recursive types without indirection (Core §11.3, §18
// *Recursion*)
// ---------------------------------------------------------------------------

test "checker rejects a directly recursive type without indirection" {
    try expectDiag(
        \\struct Node { next: Node; }
        \\fn main() -> void {}
    , "recursive type 'Node' without indirection");
}

test "checker rejects a mutually recursive type without indirection" {
    try expectDiag(
        \\struct A { b: B; }
        \\struct B { a: A; }
        \\fn main() -> void {}
    , "recursive type 'A' without indirection");
}

test "checker rejects a recursive union variant with inline payload" {
    try expectDiag(
        \\union U { Leaf, Node(U) }
        \\fn main() -> void {}
    , "recursive type 'U' without indirection");
}

test "checker accepts recursion through box indirection" {
    // A cycle that passes through `box` on any edge is legal (Core §11.3).
    var t = try checkText(
        \\struct Node { next: box[Node]; }
        \\struct A { b: B; }
        \\struct B { a: box[A]; }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts recursion through list and function types" {
    var t = try checkText(
        \\struct Tree { children: list[Tree]; }
        \\struct F { call: fn(F) -> int32; }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts a recursive generic template" {
    // The template's self-reference is behind indirection; the type
    // parameter is not a storage node.
    var t = try checkText(
        \\struct List[T] { head: T; tail: box[List[T]]; }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects a recursive type through a using type alias" {
    // A module-level `using` type alias to a local declaration keeps the
    // direct storage edge (Core §2.8, §11.3).
    try expectDiag(
        \\using Node as N;
        \\struct Node { next: N; }
        \\fn main() -> void {}
    , "recursive type 'Node' without indirection");
}

test "checker rejects recursion through a generic instantiation" {
    // The type arguments of a reference are stored inline in the
    // instantiated value, so `Pair[Node, …]` stores `Node` directly.
    try expectDiag(
        \\struct Pair[T, U] { a: T; b: U; }
        \\struct Node { x: Pair[Node, int32]; }
        \\fn main() -> void {}
    , "recursive type 'Node' without indirection");
}

test "checker rejects a recursive type through an alias to a tuple" {
    // A transparent alias to a tuple keeps the direct edge (Core §11.2,
    // §11.3).
    try expectDiag(
        \\type T = tuple[A];
        \\struct A { x: T; }
        \\fn main() -> void {}
    , "recursive type 'A' without indirection");
}

test "checker rejects a tuple field with recursive storage" {
    // Tuple elements are direct storage edges (Core §11.3).
    try expectDiag(
        \\struct T { pair: tuple[T, int32]; }
        \\fn main() -> void {}
    , "recursive type 'T' without indirection");
}

test "checker rejects a recursive type through a generic tuple alias" {
    // The alias's own parameter is substituted before the target is walked,
    // so `Pair[Node]` stores `tuple[Node, Node]` — direct storage (Core
    // §11.2, §11.3).
    try expectDiag(
        \\type Pair[T] = tuple[T, T];
        \\struct Node { x: Pair[Node]; }
        \\fn main() -> void {}
    , "recursive type 'Node' without indirection");
}

test "checker rejects a recursive type through a generic alias with repeated arguments" {
    // `Dup[Node]` expands to `B[Node, Node]`, whose field `a: T` stores
    // `Node` directly.
    try expectDiag(
        \\type Dup[T] = B[T, T];
        \\struct B[T, U] { a: T; b: U; }
        \\struct Node { x: Dup[Node]; }
        \\fn main() -> void {}
    , "recursive type 'Node' without indirection");
}

test "checker rejects a recursive type through an alias chain" {
    // A chain of transparent aliases is expanded target by target (Core
    // §11.2), so `x: S` still stores `A` directly.
    try expectDiag(
        \\type T = tuple[A];
        \\type S = T;
        \\struct A { x: S; }
        \\fn main() -> void {}
    , "recursive type 'A' without indirection");
}

test "checker accepts a recursive type through a nested box-hidden generic" {
    // `Node` is stored only behind `box` inside `C`, so `B[Node]` ->
    // `C[Node]` -> `box[Node]` adds no direct storage edge (Core §11.3).
    // The substitution must follow the callee's own storage rather than
    // treating the bare parameter reference as a direct edge.
    var t = try checkText(
        \\struct C[T] { v: box[T]; }
        \\struct B[T] { w: C[T]; }
        \\struct Node { x: B[Node]; }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts a box-hidden generic instantiation" {
    // `Pair[Node]` stores its parameter behind `box`, so the instantiation
    // adds no direct edge (Core §11.3).
    var t = try checkText(
        \\struct Pair[T] { v: box[T]; }
        \\struct Node { x: Pair[Node]; }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects recursion whose edge depends on caller-env substitution" {
    // `A[Node]` must substitute `Node` for `T` under the caller frame
    // before descending into `B[T]`; a regression that drops the
    // substitution (or applies the identity-drop to the raw argument)
    // silently accepts the `Node` -> `B[Node]` direct cycle.
    try expectDiag(
        \\struct B[T] { v: T; }
        \\struct A[T] { p: B[T]; }
        \\struct Node { x: A[Node]; }
        \\fn main() -> void {}
    , "recursive type 'Node' without indirection");
}

test "checker accepts the same declaration under different instantiations" {
    // `B[B[int32]]` re-enters `B` with a different substitution than the
    // enclosing `B[·]`, so the (declaration, substitution) stack pair does
    // not repeat; only an env-blind comparison would call this a cycle.
    var t = try checkText(
        \\struct B[T] { v: T; }
        \\struct G { x: B[B[int32]]; }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects a generic context that grows without repeating" {
    // `B[T]` contains `B[B[T]]`: every instantiation nests one level
    // deeper, so no substitution repeats and only the depth cap terminates
    // the walk — a regression that removes the cap hangs the checker.
    try expectDiag(
        \\struct B[T] { v: B[B[T]]; }
        \\struct G { x: B[int32]; }
        \\fn main() -> void {}
    , "recursive type 'B' without indirection");
}

// ---------------------------------------------------------------------------
// checker — module-constant initialization order (Core §5, §6.5)
// ---------------------------------------------------------------------------

test "checker rejects reading a later module constant" {
    // The later constant's type is declared so phase 1 can infer `a`;
    // the init-order check reports the read.
    try expectDiag(
        \\const a: int32 = b;
        \\const b: int32 = 1;
    , "module constant initializer reads 'b' declared later");
}

test "checker rejects transitively reading a later module constant" {
    // The initializer calls `f`, whose body reads `b` declared later
    // (Core §5: an initializer may not transitively call a function that
    // reads a later constant).
    try expectDiag(
        \\const a: int32 = f();
        \\fn f() -> int32 { b }
        \\const b: int32 = 1;
    , "which reads module constant 'b' declared later");
}

test "checker accepts reading an earlier module constant" {
    var t = try checkText(
        \\const a = 1;
        \\const b = a;
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts a function reading a later constant when nothing calls it" {
    // Function references are order-independent (Core §6.5); only a call
    // from an initializer makes the reads transitive.
    var t = try checkText(
        \\const a = 1;
        \\fn f() -> int32 { b }
        \\const b: int32 = 2;
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects a drop hook reading a later module constant" {
    // Teardown destroys module constants in reverse declaration order
    // (Runtime §2.5): an earlier constant's drop hook runs after later
    // constants are already destroyed, so it must not read them (Core §5).
    try expectDiag(
        \\struct File { fd: int32; drop(f) { let _ = later_msg; } }
        \\const log: File = File{ fd: 1 };
        \\const later_msg: str = "bye";
    , "drop hook of module constant 'log' reads 'later_msg' declared later");
}

test "checker rejects a drop hook transitively reading a later module constant" {
    // The drop hook calls `tell`, whose body reads `b` declared later.
    try expectDiag(
        \\fn tell() -> str { later_msg }
        \\struct File { fd: int32; drop(f) { let _ = tell(); } }
        \\const log: File = File{ fd: 1 };
        \\const later_msg: str = "bye";
    , "which reads module constant 'later_msg' declared later");
}

test "checker accepts a drop hook reading an earlier module constant" {
    // An earlier constant is destroyed later at teardown, so it is still
    // alive when the hook runs.
    var t = try checkText(
        \\const earlier: str = "hi";
        \\struct File { fd: int32; drop(f) { let _ = earlier; } }
        \\const log: File = File{ fd: 1 };
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker ignores locals shadowing module constant names" {
    var t = try checkText(
        \\const a: int32 = f();
        \\fn f() -> int32 { let b = 5; b }
        \\const b: int32 = 1;
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts a mutual call cycle that reads no constants" {
    // The transitive-call walk is guarded against the local call graph
    // cycling (Core §6.5); a cycle that never reads a later constant is
    // fine. `g` must call back into `f` so the `visiting` guard is
    // actually exercised (a regression that removes the guard would hang
    // or overflow here).
    var t = try checkText(
        \\const a: int32 = f();
        \\fn f() -> int32 { g() }
        \\fn g() -> int32 { f() }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects a module constant reading itself" {
    // A self-referential initializer is circular under Core §5's strict
    // declaration-order rule.
    try expectDiag(
        \\const a: int32 = a;
    , "reads 'a' before it is initialized");
}

test "checker rejects a module constant reading itself through a call" {
    // The self-read is transitive through a local function call.
    try expectDiag(
        \\const a: int32 = f();
        \\fn f() -> int32 { a }
    , "which reads module constant 'a' declared later");
}

// ---------------------------------------------------------------------------
// checker — drop-hook destruction-view restrictions (Core §9.2, §18
// *User drop hook*)
// ---------------------------------------------------------------------------

test "checker rejects moving the destruction view in a drop hook" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) { let y = move file; } }
        \\fn main() -> void {}
    , "cannot move borrowed");
}

test "checker rejects explicitly dropping the destruction view in a drop hook" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) { drop file; } }
        \\fn main() -> void {}
    , "cannot drop borrowed");
}

test "checker rejects returning the destruction view from a drop hook" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) { file } }
        \\fn main() -> void {}
    , "cannot return the destruction view");
}

test "checker rejects transferring field ownership out of a drop hook" {
    // The destruction view is borrowed, so an unique field may not be
    // moved into a `move` parameter (Core §18 *User drop hook*).
    try expectDiag(
        \\struct Inner { v: int32; drop(i) {} }
        \\struct File { inner: Inner; drop(file) { take(file.inner); } }
        \\fn take(move x: Inner) -> void {}
        \\fn main() -> void {}
    , "cannot move a borrowed value");
}

test "checker accepts a drop hook that reads Copy fields" {
    // Reading (not moving) fields of the destruction view is allowed
    // (Core §9.1's `os.close(file.fd)` example).
    var t = try checkText(
        \\struct File { fd: int32; drop(file) { let x = file.fd; } }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects an unique field as a drop hook result" {
    // A dotted projection of the borrowed destruction view is itself
    // borrowed, so it may not escape as the hook's result.
    try expectDiag(
        \\struct Inner { v: int32; drop(i) {} }
        \\struct File { inner: Inner; drop(file) { file.inner } }
        \\fn main() -> void {}
    , "cannot return the destruction view");
}

test "checker rejects returning an unique projection of a borrow parameter" {
    // The dotted-path borrow rule applies to ordinary `borrow` parameters
    // too (Core §10.7), not just destruction views.
    try expectDiag(
        \\struct Inner { v: int32; drop(i) {} }
        \\struct File { inner: Inner; }
        \\fn f(borrow f: File) -> Inner { f.inner }
        \\fn main() -> void {}
    , "cannot return a borrowed value as owned");
}

test "checker accepts a Copy projection as a drop hook result" {
    // A Copy projection of the destruction view is not borrowed and
    // may be returned by the hook (Core §9.1).
    var t = try checkText(
        \\struct File { fd: int32; drop(file) { let r = file.fd; r } }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}
