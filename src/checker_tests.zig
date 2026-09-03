//! Test file: `checker` — the type checker / AST annotator (phase 2).
//!
//! Organization: the black-box suite is grouped by the four orthogonal
//! semantic dimensions of phase 2 (phase2-checker.md, Test coverage — four
//! orthogonal dimensions): a driver-annotation preamble (dimension 0 —
//! host-binding bookkeeping the lowerer consumes), then dimension 1 type
//! system, dimension 2 name binding, dimension 3 constraint checking, and
//! dimension 4 control flow analysis. Every case isolates one atomic rule
//! of exactly one dimension; shared harness helpers live in the support
//! block below. White-box tests of `src/passes/checker.zig`'s own internals
//! stay in that module's file; this file aggregates them so they are
//! analyzed and run, and adds black-box tests of the checker driven through
//! the full front-end phase-1 pipeline (a program must load and parse
//! before it can be annotated).

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
// checker — test support: shared black-box harness helpers
// Compilation harnesses (single- and multi-module), the diagnostic
// assertion helper, binding-state counting, and the opaque-type test
// library.
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

/// Like `expectDiag`, and additionally asserts the diagnostic's line in the
/// source (1-based). Guards against a rejection that fires from the wrong
/// site — the checker's own span discipline — without pinning columns.
fn expectDiagAtLine(text: []const u8, want: []const u8, want_line: usize) !void {
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
    const d = ck.diag.?;
    try testing.expect(std.mem.indexOf(u8, d.message, want) != null);
    var line: usize = 1;
    for (text[0..d.span.start]) |ch| {
        if (ch == '\n') line += 1;
    }
    try testing.expectEqual(want_line, line);
}

fn countBindingsWithState(t: anytype, want: checker.BindingState) !usize {
    const ma = t.ann.per_module.get("test").?;
    var count: usize = 0;
    var it = ma.bindings.valueIterator();
    while (it.next()) |state| {
        if (state.* == want) count += 1;
    }
    return count;
}

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

/// Build an app module that imports a second source module `dep`, run the
/// checker over the pair, and return the annotation. The two modules live
/// in the same source map, so `dep` is an ordinary source module (not a
/// standard-library interface) and its members are ordinary module value
/// members (Core §2.5).
fn checkAppAgainstDep(dep: []const u8, app: []const u8) !struct { arena: std.heap.ArenaAllocator, graph: *moduleinfo.ModuleGraph, ann: checker.Annotation } {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    var source_map = std.StringHashMapUnmanaged([]const u8).empty;
    try source_map.put(arena.allocator(), "dep", dep);
    try source_map.put(arena.allocator(), "app", app);

    var builder = moduleinfo.Builder.init(arena.allocator(), moduleinfo.Sources{ .source = source_map });
    const graph = try builder.build("app");

    var ck = checker.Checker.init(arena.allocator());
    const ann = try ck.check(graph);
    return .{ .arena = arena, .graph = graph, .ann = ann };
}

// ---------------------------------------------------------------------------
// checker — dimension 0: driver annotation contract
// Host-binding detection (phase2-checker.md, Generic expansion): a function
// declaration without a Stilla body is flagged for phase 3 (which lowers its
// calls to system calls); definitions — including bodies that are just a
// trailing expression — are never flagged, and non-function module items are
// ignored. No semantic rule of dimensions 1-4; bookkeeping the lowerer
// consumes.
// ---------------------------------------------------------------------------

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
// Semantic-checker coverage matrix — dimension 1/4: type system
// Type matching, implicit conversion, generic instantiation, and type
// inference (Core §16.3, §18; Core §12; Core §11.2, §11.3, §11.8). Each case
// isolates one atomic rule: matching of arguments, returns, operators, and
// declared types; contextual literal typing and width magnitude; `any`
// widening and `never` branch joins; transparent-alias identity; generic
// specialization, deduplication, and type-argument inference; and the
// structural rules of nominal types (opaque host types, recursion
// indirection).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 1a — expression typing, literals, and implicit conversion
// ---------------------------------------------------------------------------

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
    // with `a: int64` types the literal at int64.
    const t = try checkText(
        \\fn sub(a: int64) -> int64 { a - 1 }
        \\fn add(a: int64) -> int64 { 1 + a }
        \\fn cmp(a: int64) -> bool { a == 0 }
        \\fn shi(a: uint64) -> uint64 { a >> 1 }
        \\fn call() -> int64 { brand(1) }
        \\fn brand(x: int64) -> int64 { x }
        \\fn um(a: uint32) -> uint32 { a - 1 }
        \\fn ul(a: uint32) -> uint32 { 1 + a }
        \\fn nsub(a: int64) -> int64 { a - -1 }
        \\fn ncmp(a: int64) -> bool { -1 < a }
        \\fn neq(a: int64) -> bool { -1 == a }
        \\fn uc(c: uint32) -> uint32 { -3 + c }
        \\fn ucall() -> uint32 { uarg(7) }
        \\fn uarg(x: uint32) -> uint32 { x }
    );
    defer t.arena.deinit();
}

test "checker rejects an integer literal that overflows its contextual width" {
    // A literal typed at a width context is range-checked at that width
    // (Core Types §16.3): 5e9 does not fit uint32.
    try expectDiag(
        \\fn big() -> uint32 { 5000000000 }
    , "uint32 literal magnitude");
}

test "checker types float literals at the other binary operand's width" {
    // The float mirror of the int rule (Core Types §16.3): a float literal
    // in an explicit float type context types at that width — `a - 1.5`
    // with `a: float64` types the literal at float64.
    const t = try checkText(
        \\fn dsub(a: float64) -> float64 { a - 1.5 }
        \\fn dadd(a: float64) -> float64 { 1.5 + a }
        \\fn dcmp(a: float64) -> bool { a >= 2.5 }
        \\fn fs(a: float32) -> float32 { a + 0.5 }
        \\fn dcall() -> float64 { rounder(2.5) }
        \\fn rounder(x: float64) -> float64 { x }
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

test "checker rejects a let type mismatch" {
    try expectDiag(
        \\fn f() -> int32 { let x: int32 = "nope"; 0 }
    , "let type mismatch");
}

test "checker rejects a module constant whose declared type mismatches its initializer" {
    // A declared const type is checked against the initializer exactly like
    // any other declared type (Core §5); the mismatch is reported at the
    // constant, not silently coerced.
    try expectDiag(
        \\const version: int32 = "nope";
    , "constant type mismatch");
}

test "checker rejects a construction field type mismatch" {
    // Core §8.1: the values written into a struct construction must be
    // compatible with the declared field types. Until this check,
    // constructions accepted any value into any field.
    try expectDiagAtLine(
        \\struct S { v: int32; }
        \\fn main() -> void { let s = S{ v: "x" }; }
    , "field type mismatch", 2);
}

test "checker rejects a union payload type mismatch" {
    // Core §11: a variant's payload values must be compatible with the
    // variant's declared payload types.
    try expectDiagAtLine(
        \\union U { Some(int32) }
        \\fn main() -> void { let u = U::Some("x"); }
    , "payload type mismatch", 2);
}

test "checker types a literal at the declared field width" {
    // Construction positions are an explicit type context (Core Types
    // §16.3) like parameter positions: a literal field value types at the
    // declared field's width, so `1` in an int64 field is int64, not the
    // int32 default — no field type mismatch.
    var t = try checkText(
        \\struct Big { v: int64; }
        \\fn main() -> void { let b = Big{ v: 1 }; }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker matches arguments and returns through a transparent type alias" {
    // A type alias leaves no node (Core §11.2): `Id` and `int32` are the
    // same type for matching, so the call and the operator both type.
    var t = try checkText(
        \\type Id = int32;
        \\fn f(x: Id) -> int32 { x + 1 }
        \\fn main() -> int32 { f(1) }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker widens a Copy argument implicitly to any" {
    // Coercion to the top type `any` is the sole implicit widening (Core
    // §18 *Conversion*, §11.6): a Copy source packs without a `move`.
    var t = try checkText(
        \\fn wrap(x: any) -> void {}
        \\fn main() -> void { wrap(42); }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker requires an explicit move before packing an unique value into any" {
    // An unique source must be `move`d into `any` (Core §10.6): the pack
    // transfers ownership, so an implicit pack would silently copy an
    // owner.
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn wrap(x: any) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    wrap(f);
        \\}
    , "before being passed to an 'any' parameter");
}

test "checker accepts an explicit move into any" {
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn wrap(x: any) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    wrap(move f);
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts an any recovered by as" {
    // Core §16.3: an `any` value is recovered by a cast `as T` (an
    // invalid recovery traps at runtime, Runtime §7.2) or by a type-test
    // `match` over it; the downcast types the expression at the target.
    var t = try checkText(
        \\fn describe(a: any) -> int32 { (a as int32) + 1 }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker rejects recovering an any without as or match" {
    // Core §18 *Conversion*: `any` is recovered only by `as` or a
    // type-test `match`, never by a plain value position — the declared
    // int32 binding against an `any` initializer is a type mismatch (the
    // `move` only satisfies ownership, not the type rule).
    try expectDiagAtLine(
        \\fn f(a: any) -> void { let x: int32 = move a; }
    , "let type mismatch", 1);
}

test "checker unifies a never branch with a value branch" {
    // Branch unification coerces `never` to the other branch's type (Core
    // §13.2, §18 *Typing*): the else branch diverges, so the if types at
    // the then branch's int32.
    var t = try checkText(
        \\const builtin = import("builtin");
        \\fn die() -> never { builtin.panic("x") }
        \\fn pick(flag: bool) -> int32 { if (flag) { 1 } else { die() } }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

// ---------------------------------------------------------------------------
// 1b — generic expansion and type-argument inference
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
    // Generic expansion: instances are keyed by (declaration, type
    // arguments); two calls with the same arguments share one instance.
    var t = try checkText(
        \\fn id[T](move x: T) -> T { move x }
        \\fn main() -> void { let a = id(42); let b = id(7); }
    );
    defer t.arena.deinit();

    // Two same-argument calls produce exactly one instance — a key that
    // differed per use site would yield a second one.
    try testing.expectEqual(@as(usize, 1), t.ann.instances.items.len);
    const inst = t.ann.instances.items[0];

    // Both call sites resolve to that single instance.
    const ma = t.ann.per_module.get("test").?;
    var seen: usize = 0;
    for (t.graph.modules[0].program.?.items) |*item| switch (item.*) {
        .func_def => |*f| {
            if (std.mem.eql(u8, f.name.text, "main")) {
                for (f.body.?.stmts) |*s| switch (s.*) {
                    .let => |*l| switch (l.init.*) {
                        .call => |*c| {
                            seen += 1;
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
    try testing.expectEqual(@as(usize, 2), seen);
}

test "checker specializes an explicitly annotated generic call" {
    // Core §12.3: `id::[int32](42)` specializes by explicit type argument.
    var t = try checkText(
        \\fn id[T](x: T) -> T { x }
        \\fn main() -> void { let a = id::[int32](42); }
    );
    defer t.arena.deinit();

    // One explicit specialization produces one instance, and the call
    // site maps to it via `call_of` (the annotation the lowerer consumes).
    try testing.expectEqual(@as(usize, 1), t.ann.instances.items.len);
    const inst = t.ann.instances.items[0];
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

    // One explicit specialization produces one instance, and the
    // specialization expression maps to it via `spec_of` (the annotation
    // the lowerer consumes).
    try testing.expectEqual(@as(usize, 1), t.ann.instances.items.len);
    const inst = t.ann.instances.items[0];
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
// 1c — nominal types: opaque host types, recursion indirection
// ---------------------------------------------------------------------------

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

test "checker accepts moving an opaque host value" {
    // Core §11.8: an opaque value is an ordinary unique value; ownership
    // transfers by an explicit `move` of the owner, and the host binding
    // consumes the transferred value.
    var t = try checkOpaqueText(OPAQUE_LIB,
        \\const hostlib = import("hostlib");
        \\fn main() -> void {
        \\    let a = hostlib.make::[int32]();
        \\    let c = move a;
        \\    let d = hostlib.pass(move c);
        \\}
    );
    defer t.arena.deinit();
}

test "checker accepts borrowing an opaque host value" {
    // Core §11.8: an opaque value may be passed to a `borrow` parameter;
    // the borrow is a non-owning view and leaves the owner untouched.
    var t = try checkOpaqueText(OPAQUE_LIB,
        \\const hostlib = import("hostlib");
        \\fn f(borrow h: hostlib.Handle[int32]) -> int32 { 0 }
        \\fn main() -> void {
        \\    let a = hostlib.make::[int32]();
        \\    let d = hostlib.pass(move a);
        \\    let e = f(d);
        \\}
    );
    defer t.arena.deinit();
}

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

test "checker accepts recursion through a list type" {
    var t = try checkText(
        \\struct Tree { children: list[Tree]; }
        \\fn main() -> void {}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker accepts recursion through a function type" {
    var t = try checkText(
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
// Semantic-checker coverage matrix — dimension 2/4: name binding
// Lexical scope resolution and cross-module linking (Core §2.5, §2.8, §6.2,
// §6.5, §13.2). Stilla has no overload sets — one binding per name per scope —
// so each case isolates one binding rule: block-scoped shadowing and scope
// exit; forward calls; lambda parameters binding over enclosing parameters;
// arm-scoped pattern bindings; module-qualified value members; and the
// non-capture rule.
// ---------------------------------------------------------------------------

test "checker restores the outer binding after a shadowing block" {
    // A block-scoped `let` shadows an outer binding of the same name; on
    // scope exit the outer binding is the one in scope again. The final
    // `x` types as the outer int32 — if the inner str binding leaked, the
    // return would be a type mismatch.
    var t = try checkText(
        \\fn main() -> int32 {
        \\    let x: int32 = 1;
        \\    if (true) { let x: str = "inner"; } else {};
        \\    x
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker keeps an outer unique owner untouched by a shadowing move" {
    // Shadowing isolates binding identity: the inner `f` is a fresh owner,
    // so `consume(move f)` inside the block consumes the shadow, not the
    // outer owner. The outer `f` is still owned after the block — a flat
    // (non-scoped) binding table would report it as already moved.
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { let f = File{ fd: 2 }; consume(move f); } else {};
        \\    consume(move f);
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker resolves a forward call to a later-declared function" {
    // Function references are order-independent (Core §6.5): a body may
    // call a function declared later in the module.
    var t = try checkText(
        \\fn main() -> int32 { later() }
        \\fn later() -> int32 { 7 }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker binds a lambda parameter over an enclosing function parameter" {
    // An inner function's parameters bind over an enclosing function's
    // parameters: the lambda body's `x` is the lambda's own parameter, so
    // the non-capture rule (Core §6.2) never fires.
    var t = try checkText(
        \\fn main(x: int32) -> int32 {
        \\    let g = fn (x: int32) -> int32 { x };
        \\    g(1)
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker isolates a match pattern binding from an outer binding of the same name" {
    // Arm patterns bind in an arm-scoped scope (Core §13.2). Matching an
    // unique owner through an ordinary expression borrows the payload, so
    // the arm's `f` is a borrowed binding — if it had overwritten the
    // outer owner instead of shadowing it, the post-match move would be
    // rejected as a move of a borrowed binding.
    var t = try checkText(
        \\union U { Some(File), None }
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let u = U::Some(File{ fd: 1 });
        \\    let f = File{ fd: 2 };
        \\    match (u) { U::Some(f) => 0, U::None => 0 };
        \\    consume(move f);
        \\}
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

test "checker resolves module-qualified value members of an imported module" {
    // External linking: `dep.bump` and `dep.base` resolve as value members
    // of the imported module (a monomorphic function and a const, Core
    // §2.5) and type at their declared types. Phase 1 orders `dep` before
    // `app`, so `dep` is annotated before `app` reads its members.
    var t = try checkAppAgainstDep(
        \\const base: int32 = 3;
        \\fn bump(x: int32) -> int32 { x + base }
    ,
        \\const dep = import("dep");
        \\fn main() -> int32 { dep.bump(1) + dep.base }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 2), t.graph.modules.len);
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

// ---------------------------------------------------------------------------
// Module-resident flow restrictions (Core §2.3)
// ---------------------------------------------------------------------------

test "checker rejects binding a module value by a local let" {
    // Core §2.3: a module value may exist only in a module-level `const`
    // binding. A `let` inside a function body would store it in a local
    // slot — outside module storage — so it is rejected even though the
    // binding is never used for member access. (`let m = import("x")`
    // inside a function body hits the same rejection.)
    try expectDiagAtLine(
        \\const builtin = import("builtin");
        \\fn main() -> void { let m = builtin; }
    , "a module value may not be bound by a local 'let'", 2);
}

test "checker rejects widening a module value into an any" {
    // Core §2.3 + §18 *Conversion*: a module value cannot leave module
    // storage, so it does not widen into `any` — passing one to an `any`
    // parameter is an argument type mismatch, not a silent pack.
    try expectDiagAtLine(
        \\const builtin = import("builtin");
        \\fn wrap(x: any) -> void {}
        \\fn main() -> void { wrap(builtin); }
    , "argument type mismatch", 3);
}

test "checker rejects storing a module value into an any field" {
    // Core §2.3 + §18 *Conversion*: a module value does not widen into
    // `any`, so it cannot be smuggled into an `any`-typed struct field —
    // construction typing reports it as a field type mismatch (the same
    // exclusion that blocks `hostdata`).
    try expectDiagAtLine(
        \\const builtin = import("builtin");
        \\struct S { v: any; }
        \\fn main() -> void { let s = S{ v: builtin }; }
    , "field type mismatch", 3);
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

test "checker ignores locals shadowing module constant names" {
    var t = try checkText(
        \\const a: int32 = f();
        \\fn f() -> int32 { let b = 5; b }
        \\const b: int32 = 1;
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}

// ---------------------------------------------------------------------------
// Semantic-checker coverage matrix — dimension 3/4: constraint checking
// Ownership, borrow lifetimes, conditional release, module-constant scope,
// destruction-view restrictions, and the void/never declaration contracts
// (Types & Ownership §10.4-§10.10; Core §5, §6.4, §9.2, §18). Stilla has no
// exception specification — non-returning execution is the `never` type.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 3a — void and never declaration contracts
// ---------------------------------------------------------------------------

test "checker accepts an explicitly void declaration" {
    // Core §6.4: `-> void` is stated explicitly; a body with no final
    // expression (empty, or statement-only) types void.
    const t = try checkText(
        \\fn nothing() -> void {}
        \\fn ok() -> void { let x: int32 = 1; }
    );
    defer t.arena.deinit();
    _ = t.ann;
}

test "checker accepts a never declaration whose body diverges" {
    // Core §6.4: `-> never` is stated explicitly; the body must diverge,
    // and a self-call does.
    const t = try checkText(
        \\fn diverge() -> never { diverge() }
    );
    defer t.arena.deinit();
    _ = t.ann;
}

test "checker rejects a never declaration whose body returns a value" {
    // `-> never` is the non-returning type: the body must diverge, not
    // yield a value. A trailing expression types the body at its own type,
    // so `42` makes the body int32 and the declared never is a mismatch.
    try expectDiag(
        \\fn notNever() -> never { 42 }
    , "return type mismatch");
}

// ---------------------------------------------------------------------------
// 3b — conditional release and dead-binding state
// ---------------------------------------------------------------------------

test "checker rejects use of a moved unique value" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) {} }
        \\fn open() -> File { File{ fd: 1 } }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void { let f = open(); consume(move f); let g = f; }
    , "use of moved value");
}

test "checker rejects use of a dropped value" {
    // Core §9.4, §18 *Ownership*: an explicit `drop name;` destroys the
    // binding; a later reference is a use-after-destruction. (The
    // move-path sibling — `consume(move f)` then a use — is the
    // `rejects use of a moved unique value` case above.)
    try expectDiagAtLine(
        \\struct File { fd: int32; drop(file) {} }
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    drop f;
        \\    let g = f;
        \\}
    , "use of moved value", 5);
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
    // `and` and `or` share the checker's short-circuit path, so a release
    // in the right operand of either operator is this same case.
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

test "checker rejects dropping a borrowed binding" {
    // Core §18 *Borrowing*: a borrowed unique value cannot be dropped —
    // the view is not owned (the `move` sibling is the
    // `rejects moving a borrowed binding` case above).
    try expectDiagAtLine(
        \\struct File { fd: int32; drop(file) {} }
        \\fn main(borrow f: File) -> void { drop f; }
    , "cannot drop borrowed binding", 2);
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

test "checker borrows an unique payload of a non-consuming match" {
    // Core §13.4: matching an unique owner through an ordinary expression
    // borrows it, so the payload binding is a borrow and cannot be moved.
    // (The arm's bindings are arm-scoped, so the move must be written
    // inside the arm — a post-match reference would be an unknown
    // binding, which the lowering reports.)
    try expectDiag(
        \\union U { Some(File), None }
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let u = U::Some(File{ fd: 1 });
        \\    match (u) { U::Some(f) => consume(move f), U::None => 0 };
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
// 3c — argument modes and borrow escapes
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

test "checker accepts an owned unique local as an implicit tail return" {
    // Core §10.5: a fresh unique value transfers implicitly — and so does
    // an owned local that ends the scope it was born in: returning `f`
    // moves it into the caller without an explicit `move` (the binding
    // would otherwise be destroyed at scope end anyway).
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn make() -> File { let f = File{ fd: 1 }; f }
        \\fn main() -> void { let g = make(); }
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

test "checker accepts a borrow call and keeps the caller's owner alive" {
    // Core §10.6: a `borrow` parameter receives a non-owning view; the
    // caller's owner is untouched, so it may still be dropped after the
    // call returns.
    var t = try checkText(
        \\struct File { fd: int32; drop(file) {} }
        \\fn inspect(borrow f: File) -> int32 { f.fd }
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    let fd = inspect(f);
        \\    drop f;
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

// ---------------------------------------------------------------------------
// 3d — module-constant scope and teardown reads
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
// 3e — drop-hook destruction-view restrictions
// ---------------------------------------------------------------------------

test "checker rejects moving the destruction view in a drop hook" {
    try expectDiag(
        \\struct File { fd: int32; drop(file) { let y = move file; } }
        \\fn main() -> void {}
    , "cannot move borrowed");
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

// ---------------------------------------------------------------------------
// Semantic-checker coverage matrix — dimension 4/4: control flow analysis
// Definite return, match exhaustiveness, refutable-pattern placement, and the
// reachability boundary (Core §13.2-§13.3, §14.7, §18 *Match*). Variable-
// initialization paths are vacuous (`let` always initializes); unreachable
// source is deliberately not a phase-2 diagnostic.
// ---------------------------------------------------------------------------

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

test "checker rejects a refutable let pattern" {
    try expectDiag(
        \\fn f(a: any) -> int32 { let int32 n = a; n }
    , "refutable");
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

test "checker rejects a non-void declaration whose body has no final expression" {
    // Core §6.4: a body with no final expression has type void, so a
    // declaration like `-> int32 {}` is a mismatch, not a silently
    // defaulted return.
    try expectDiag(
        \\fn empty() -> int32 { let x = 1; }
    , "return type mismatch");
}

test "checker rejects a tail if without else in a value-returning function" {
    // A value-typed body must end in an expression of the declared type
    // on every path. An `if` without an `else` has an implicit void else
    // path (Core §10.10), so as the tail of an int32 function it types the
    // body void and the return mismatches — the definite-return rule
    // catches the path that falls through.
    try expectDiag(
        \\fn f(c: bool) -> int32 { if (c) { 1 } }
    , "return type mismatch");
}

test "checker leaves code after a never call unchecked for reachability" {
    // Reachability is not a phase-2 diagnostic: statements after a call
    // that never returns are legal source here, and the lowered CFG's
    // reachability is validated downstream. This pins the boundary — if a
    // phase-2 unreachable-code check is ever added, this case moves.
    var t = try checkText(
        \\const builtin = import("builtin");
        \\fn die() -> never { builtin.panic("x") }
        \\fn main() -> int32 { die(); 42 }
    );
    defer t.arena.deinit();
    try testing.expectEqual(@as(usize, 0), t.ann.host_bindings.count());
}
