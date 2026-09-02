//! Test file: `frontend spec` — the spec-example conformance programs:
//! the normative examples of the spec documents (Core, Runtime, StdLib),
//! assembled into compilable programs and compiled through the pipeline
//! (`expectCompiles`, local). The region also carries the generic
//! instantiation / monomorphization tests and the further lowering and
//! checker-rejection coverage that followed the conformance examples in
//! the unsplit file. Split out of the former
//! `src/frontend_lowering_tests.zig`.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;

fn expectCompiles(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !void {
    var c = try compileText(entry, texts);
    defer c.deinit();
    if (c.program == null) {
        const msg = if (c.diag) |d| d.message else "no diagnostic";
        std.log.err("spec example failed to compile: {s}", .{msg});
        return error.SpecExampleFailed;
    }
}

// ---------------------------------------------------------------------------
// Spec-example conformance: the normative examples of the spec documents
// (Core, Runtime, StdLib), assembled into compilable programs. Each example
// is the exact source from the spec (wrapped in `fn main` where the spec
// shows a fragment), so a regression here means the specs and the frontend
// have drifted.
// ---------------------------------------------------------------------------

test "spec examples compile: Core 2.8 using value alias" {
    // `using string.upper as up; up(text)` resolves to the member.
    try expectCompiles("app", &.{
        .{
            "app",
            \\const string = import("string");
            \\using string.upper as up;
            \\fn shout(text: str) -> str { up(text) }
            \\fn main() -> void { let _ = shout("hi"); }
        },
    });
}

test "spec examples compile: Core 6.1 no implicit receiver" {
    try expectCompiles("app", &.{
        .{
            "app",
            \\struct Counter {
            \\    value: int32;
            \\    next: fn(borrow Counter) -> int32;
            \\}
            \\fn main() -> int32 {
            \\    let counter = Counter{
            \\        value: 10,
            \\        next: fn(borrow c: Counter) -> int32 { c.value + 1 }
            \\    };
            \\    counter.next(counter)
            \\}
        },
    });
}

test "spec examples compile: Core 10.8 box and unbox" {
    // Runtime §4.5/§4.6; Core §10.8. Boxes are written and read by
    // construction/consumption only: `box` takes ownership, `unbox`
    // returns it. A *Unique* payload is extracted only by consuming the
    // box — `unbox(move b)` — the no-borrowed-returns rule of Core
    // §10.7 applied to boxes.
    try expectCompiles("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct Token { id: int32; }
            \\fn main() -> int32 {
            \\    let t = builtin.box(Token { id: 7 });
            \\    let t2 = builtin.unbox(move t);
            \\    t2.id
            \\}
        },
    });
}

test "spec examples compile: Core 11.6 any" {
    try expectCompiles("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\struct File { fd: int32; drop(f) { builtin.print("x"); } }
            \\fn open_file(path: str) -> File { File{ fd: 1 } }
            \\fn main() -> void {
            \\    let a: any = 42;
            \\    let b: any = "hello";
            \\    let c: any = open_file("f");
            \\}
        },
    });
}

test "spec examples compile: Core 11.6.1 recovery by as" {
    try expectCompiles("app", &.{
        .{
            "app",
            \\fn main() -> int32 {
            \\    let a: any = 42;
            \\    let b = a as int32;
            \\    b
            \\}
        },
    });
}

test "spec examples compile: Core 11.6.2 type-test match" {
    try expectCompiles("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    let a: any = 42;
            \\    match (a) {
            \\        int32 n => builtin.print(builtin.str(n)),
            \\        str s => builtin.print(s),
            \\        _ => builtin.print("other")
            \\    };
            \\}
        },
    });
}

test "spec examples compile: Core 12 generics" {
    // §12.1 declarations, §12.2 inferred call, §12.3 explicit call,
    // §12.4 an explicit specialization as a first-class monomorphic value.
    try expectCompiles("app", &.{
        .{
            "app",
            \\struct Pair[A, B] { first: A; second: B; }
            \\fn identity[T](move value: T) -> T { move value }
            \\type PairList[T] = list[tuple[T, T]];
            \\fn main() -> int32 {
            \\    let p = Pair{ first: 1, second: "x" };
            \\    let v = identity(42);
            \\    let w = identity::[int32](43);
            \\    let f = identity::[int32];
            \\    f(v) + w
            \\}
        },
    });
}

test "frontend lowers only monomorphic functions: instances, not templates" {
    // Core §12, phase2-checker.md, Generic expansion: the AIR carries one monomorphic function per
    // used specialization (`{module}.{fn}.{id}`) with concrete signatures;
    // the unspecialized template never appears, and no `.param` type
    // survives. Calls target the instances; recursion inside a generic
    // stays a self-loop under tail-call optimization.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const iter = import("iter");
            \\const lists = import("list");
            \\const builtin = import("builtin");
            \\fn main() -> int32 {
            \\    iter.fold(lists.range(1, 10), 0, fn(move a: int32, borrow x: int32) -> int32 { a + x })
            \\}
        },
    });
    defer c.deinit();
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // The specialized functions have concrete signatures; the generic
    // template is absent.
    try testing.expect(std.mem.indexOf(u8, out, "func @iter.fold.0(borrow values: list[int32]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @iter.fold_with.1(borrow values: list[int32]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @iter.fold(") == null);
    // Calls target the instances; no type-parameter survives in the text.
    try testing.expect(std.mem.indexOf(u8, out, "call @iter.fold.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "list[T]") == null);
    try testing.expect(std.mem.indexOf(u8, out, ": T ") == null);
}

test "frontend distinguishes generic instantiations and types payloads" {
    // Core §12.1/§12.3: `Option[int32]` and `Option[str]` are distinct
    // instantiations; a payload read is typed by the instantiation, and a
    // payload-type mismatch is a compile error (not silently accepted).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\using builtin.Option;
            \\fn main() -> int32 {
            \\    let a: Option[int32] = Option::Some(42);
            \\    match (a) { Option::Some(v) => v, Option::None => 0 }
            \\}
        },
    });
    defer c.deinit();
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Option[int32]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "= read_payload") != null);

    // The payload-type mismatch is caught: Option::Some(42) is
    // Option[int32], not Option[str].
    var c2 = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\using builtin.Option;
            \\fn main() -> void { let x: Option[str] = Option::Some(42); }
        },
    });
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "let type mismatch") != null);
}

test "spec examples compile: Core 13.3 match" {
    try expectCompiles("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const lists = import("list");
            \\union Result { Ok(str), Err(str) }
            \\fn main() -> void {
            \\    let result = Result::Ok("done");
            \\    let message = match (result) {
            \\        Result::Ok(value) => "ok: " + builtin.str(value),
            \\        Result::Err(error) => "error: " + error
            \\    };
            \\    builtin.print(message);
            \\}
        },
    });
}

test "spec examples compile: Core 17 file module" {
    // The `os` module is a hypothetical host module, supplied here.
    try expectCompiles("app", &.{
        .{ "os", "fn open(path: str) -> int32;\nfn create(path: str) -> int32;\nfn close(fd: int32) -> void;" },
        .{
            "app",
            \\const os = import("os");
            \\const builtin = import("builtin");
            \\struct File {
            \\    fd: int32;
            \\    path: str;
            \\    drop(file) { os.close(file.fd); }
            \\}
            \\fn open(path: str) -> File { File{ fd: os.open(path), path: path } }
            \\fn create(path: str) -> File { File{ fd: os.create(path), path: path } }
            \\fn inspect(borrow file: File) -> void { builtin.print(file.path); }
            \\fn main() -> void {
            \\    let handle = open("data.txt");
            \\    inspect(handle);
            \\    drop handle;
            \\}
        },
    });
}

test "spec examples compile: StdLib 4 math and Runtime 4 box" {
    try expectCompiles("app", &.{
        .{
            "app",
            \\const math = import("math");
            \\const builtin = import("builtin");
            \\fn main() -> float32 {
            \\    let radius = 2.0;
            \\    let area = math.pi * math.pow(radius, 2.0);
            \\    let diagonal = math.sqrt(3.0 * 3.0 + 4.0 * 4.0);
            \\    area + diagonal
            \\}
        },
    });
    // Runtime §4.5/§4.6: box and unbox.
    try expectCompiles("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> int32 {
            \\    let b = builtin.box(42);
            \\    let n = builtin.unbox(b);
            \\    let u = builtin.unbox(move b);
            \\    n + u
            \\}
        },
    });
}

test "spec examples compile: StdLib 7 iter" {
    try expectCompiles("app", &.{
        .{
            "app",
            \\const iter = import("iter");
            \\const lists = import("list");
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    let total = iter.fold(
            \\        lists.range(1, 10),
            \\        0,
            \\        fn(move acc: int32, borrow x: int32) -> int32 { acc + x }
            \\    );
            \\    builtin.print(builtin.str(total));
            \\}
        },
    });
}

test "frontend rejects missing, duplicate, and unknown struct fields" {
    // Core §8.1: all fields must be supplied exactly once; unknown fields
    // and duplicate fields are frontend.compile-time errors.
    var c1 = try compileText("app", &.{
        .{ "app", "struct P { x: int32; y: int32; }\nfn main() -> void { let p = P{ x: 1 }; }" },
    });
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "missing field") != null);

    var c2 = try compileText("app", &.{
        .{ "app", "struct P { x: int32; y: int32; }\nfn main() -> void { let p = P{ x: 1, x: 2 }; }" },
    });
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "duplicate field") != null);

    var c3 = try compileText("app", &.{
        .{ "app", "struct P { x: int32; }\nfn main() -> void { let p = P{ q: 1 }; }" },
    });
    defer c3.deinit();
    try testing.expect(c3.program == null);
    try testing.expect(std.mem.indexOf(u8, c3.diag.?.message, "has no field") != null);
}

test "frontend rejects import outside a module constant initializer" {
    // Core §2.2 / Binding Power Table document, import form: `import(...)` may appear
    // only as the initializer of a module-level `const` binding. Binding the module
    // value is rejected by the checker under Core §2.3 (`let m = import("builtin")` —
    // a module value cannot be bound by a local let); a bare statement position,
    // whose result the checker discards, reaches the phase-3 backstop
    // (cfg_lower_expr.zig) tested here.
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { import(\"builtin\"); }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "module constant initializer") != null);
}

test "frontend lowers arithmetic, comparison, and string concat operators" {
    // Core §16.3: int32 arithmetic; str + str concatenation.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn ops(a: int32, b: int32) -> int32 { (a + b) * 2 - a / b % 2 }
            \\fn greet(name: str) -> str { "hi " + name }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = add ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = mul ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = sub ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = div ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = rem ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = concat ") != null);
}

test "frontend lowers as casts" {
    // Core §16.3: `float32 as int32` and `int32 as float32` are core
    // conversions; the AIR emits a `num_cast` op.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn cvt(x: float32) -> int32 { x as int32 }
            \\fn widen(x: int32) -> float32 { x as float32 }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = num_cast ") != null);
}

test "frontend lowers shadowing with the previous binding read first" {
    // Core §4: `let x = x + 1;` — the right-hand `x` refers to the
    // previous binding.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f() -> int32 { let x = 10; let x = x + 1; x }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // 10 + 1 folds at construction (optimizer.md, On-the-fly optimizations) to the constant.
    try testing.expect(std.mem.indexOf(u8, out, " = const 11") != null);
}

test "frontend lowers mutual recursion with declared return types" {
    // Core §6.5: functions are order-independent; mutual recursion is
    // permitted when every participant declares its return type.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn is_even(n: int32) -> bool { if (n == 0) { true } else { is_odd(n - 1) } }
            \\fn is_odd(n: int32) -> bool { if (n == 0) { false } else { is_even(n - 1) } }
            \\fn main() -> void { let r = is_even(4); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.is_odd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.is_even") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.is_odd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.is_even") != null);
}

test "frontend lowers tuple destructuring to read_tuple projections" {
    // Core §14.2 / §14.6: tuple patterns project elements; the whole
    // tuple is consumed as one value.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const lists = import("list");
            \\fn f(t: tuple[int32, str]) -> int32 { let (a, b) = t; lists.len(["x"]) }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_tuple") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#1") != null);
}

test "frontend lowers list pattern reads with read_index" {
    // Core §11.5: there is no indexed element-read function (`list.get`
    // does not exist); element reads happen by list matching. A
    // non-consuming `[h, ..t]` pattern lowers to the bounds-checked
    // `read_index` op (borrowed view of a *Unique* element).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const lists = import("list");
            \\fn f(xs: list[int32]) -> int32 {
            \\    match (xs) {
            \\        [] => 0,
            \\        [h, ..t] => h,
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_index") != null);
}

test "frontend rejects list.get as a removed member" {
    // Core §11.5: `list.get` was removed — a *Unique* element cannot be
    // returned by value without consuming the list (Core §10.7), and no
    // function returns a borrowed value, so element reads happen by
    // matching instead. The binding no longer exists.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const lists = import("list");
            \\fn f(xs: list[int32]) -> int32 { lists.get(xs, 0) }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "no member 'get'") != null);
}

test "frontend lowers consuming list-pattern destructuring with split_list" {
    // Core §18 (whole-owner rule): destructuring an owned list with
    // `let [head, ..rest] = move xs` consumes the collection as a whole;
    // one atomic `split_list` defines the item and the owned rest (air.md
    // §5.3) — each unique element becomes an owner.
    var c = try compileText("app", &.{
        .{
            "app",
            \\struct File { fd: int32; drop(file) {} }
            \\fn consume(move f: File) -> void {}
            \\fn main() -> void {
            \\    let xs = [File{ fd: 1 }];
            \\    let [f, ..rest] = move xs;
            \\    consume(move f);
            \\}
        },
    });
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = split_list %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = move %") != null);
}

test "frontend lowers box and unbox to syscalls" {
    // Core §10.8 / Runtime §4.5–§4.6: box/unbox are host bindings;
    // box takes ownership, unbox(move b) transfers ownership back.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn main() -> void {
            \\    let b = builtin.box(42);
            \\    let y = builtin.unbox(move b);
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#box") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#unbox") != null);
    // `unbox(move b)` on a Copy box[int32] lowers `move` to nothing
    // (Core §10.6: a copy of a Copy value is the value itself), so
    // no copy instruction is emitted — the unbox takes the box directly.
    try testing.expect(std.mem.indexOf(u8, out, "copy") == null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#unbox, %1") != null);
}

test "frontend rejects an unspecialized generic used as a value" {
    // Core §12.4: an unspecialized generic function is a compile-time
    // template, not a runtime function value; `let f = identity` references
    // the template itself and is rejected. A specialization (`identity::[int32]`)
    // is a valid monomorphic function value.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn identity[T](move value: T) -> T { move value }
            \\fn main() -> void { let f = identity; }
        },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unspecialized generic") != null);
}

test "frontend accepts an explicitly specialized generic as a value" {
    // Core §12.4: `identity::[int32]` is a first-class monomorphic function
    // value of type `fn(move int32) -> int32`; the checker records the
    // specialization and the lowering emits a `fn_ref` to the instance's
    // monomorphic function (`{module}.{fn}.{id}`).
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn identity[T](move value: T) -> T { move value }
            \\fn main() -> int32 { let f = identity::[int32]; f(42) }
        },
    });
    defer c.deinit();
    try testing.expect(c.program != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "fn_ref @app.identity.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.identity.0(") != null);
}

test "frontend lowers an explicitly specialized generic call" {
    // Core §12.3: `identity::[int32](42)` is frontend.compile-time specialization
    // syntax; the call lowers to the concrete monomorphic function.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn identity[T](move value: T) -> T { move value }
            \\fn main() -> void { let x = identity::[int32](42); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.identity") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.identity") != null);
}

test "frontend rejects moving an unknown binding" {
    // Core §10.4: `move` names a complete local binding.
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { let x = move nope; }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "move of unknown binding") != null);
}

test "frontend rejects dropping an unknown binding" {
    // Core §9.4: explicit drop applies only to an owning unique local.
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { drop nope; }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "drop of unknown binding") != null);
}

test "frontend lowers list.range and list.len with generics" {
    // Core §12.2: inferred specialization resolves `len[T]` against the
    // concrete `list[int32]` from `range` (Runtime §4.3–§4.4).
    var c = try compileText("app", &.{
        .{
            "app",
            \\const lists = import("list");
            \\fn main() -> void {
            \\    let n = lists.len(lists.range(0, 5));
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall list#len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall list#range") != null);
}

test "frontend lowers a never-returning call to a trap path" {
    // Core §13.2 / Runtime §7.1: `never` coerces to any type; a panic
    // call terminates the block (trap), so the if/else join type-checks.
    var c = try compileText("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\fn die() -> never { builtin.panic("x") }
            \\fn main() -> void {
            \\    let r = if (true) { 1 } else { die() };
            \\}
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#panic") != null);
    try testing.expect(std.mem.indexOf(u8, out, "trap") != null);
}

test "frontend rejects calling a non-function value" {
    var c = try compileText("app", &.{
        .{ "app", "fn main() -> void { let x = 42; x(); }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "calling a non-function") != null);
}

test "frontend rejects an unknown module member" {
    var c = try compileText("app", &.{
        .{ "calc", "fn add(a: int32, b: int32) -> int32 { a + b }" },
        .{ "app", "const calc = import(\"calc\");\nfn main() -> void { let x = calc.sub(1, 2); }" },
    });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "no member") != null);
}

test "frontend resolves chained module-valued member calls" {
    // Core §2.7: `std.math.sqrt` is chained value-member access through
    // nested module-valued consts.
    var c = try compileText("app", &.{
        .{ "std", "const math = import(\"math\");\n" },
        .{
            "app",
            \\const std = import("std");
            \\fn main() -> void { let x = std.math.sqrt(16.0); }
        },
    });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall math#sqrt") != null);
}
