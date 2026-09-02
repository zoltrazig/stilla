//! Test file: `grammar_spec_tests` — black-box grammar→AST conformance.
//!
//! Walks the normative grammar — `Stilla Core Grammar Draft.abnf` (down to
//! the statement level) and `Stilla Expression Binding Power Table.md` for
//! expressions — and the example programs of the Core Language
//! Specification production by
//! production, asserting the AST each produces through the public `Parser`
//! API. Parser-internals tests stay in `parser.zig`'s own test blocks and
//! whole-file API basics in `parser_tests.zig`; this suite holds the
//! production-level conformance matrix:
//!
//!   lexical→AST    `1.5` float vs `1.x` member, `_` vs `_foo`, escapes,
//!                  comments, unicode identifiers
//!   module-item    all seven kinds; `builtin`/`array`/`hashmap` bindable,
//!                  `list` reserved
//!   const-def      init-only, type+init, host constant (§2.6)
//!   func-def       generics, param modes, required return, host binding
//!   lambda         modes, required return, immediate call, zero params
//!   empty forms    empty struct/union, parameterless opaque, drop-only
//!                  struct
//!   types          all thirteen primitives; named/list/box/tuple/function
//!   struct-def     fields, function fields, generics, drop-decl
//!   union-def      payload arity 0/1/many, trailing comma
//!   using-decl     module + block scope, `as`, reserved-word segments
//!   block/stmt     all statement kinds; the `;`/`}` split (parser note 1)
//!   expressions    every `Expr` variant; binary-operator sweep; the full
//!                  precedence/associativity ladder of the Binding Power
//!                  Table document; unary and cast chains; `move` in every
//!                  unary position; postfix suffixes after construction and
//!                  variant primaries (expression parser decisions)
//!   patterns       every `Pattern` variant; type-test sweep (note 3);
//!                  list patterns with and without `..rest`
//!   spans          node spans slice the exact source text (expressions,
//!                  statements, arms, control flow)
//!   spec examples  §2.1 calc, §2.2/§2.7 consumers, §2.3/§2.5 aliases and
//!                  qualified type paths, §2.8 shout, §4 shadowing, §6.1
//!                  counter, §13.2 sign, §13.3 match, §17 file module
//!   rejects        syntactic boundaries only (parens, else, generic
//!                  lambda, trailing commas in params/args/type-params,
//!                  comparison chains, drop-decl placement, `tuple[]`,
//!                  import literal, move operand, reserved bindings,
//!                  assignment) — static-semantics rules live in the
//!                  checker suites, not here

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const testing = std.testing;

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

/// The initializer of module item `i`, for precedence-matrix style tests.
fn initOf(item: ast.ModuleItem) *const ast.Expr {
    return item.const_def.init.?;
}

/// Assert `e` is a binary node with operator `op`; return it for chaining.
fn expectBinary(e: *const ast.Expr, op: ast.BinaryOp) !*const ast.Binary {
    try testing.expect(e.* == .binary);
    try testing.expectEqual(op, e.binary.op);
    return &e.binary;
}

/// Assert `e` is a single-segment path and return its name.
fn singlePath(e: *const ast.Expr) ![]const u8 {
    try testing.expect(e.* == .path);
    try testing.expectEqual(@as(usize, 1), e.path.path.len);
    return e.path.path[0].text;
}

// ---------------------------------------------------------------------------
// Lexical distinctions that change the AST
// ---------------------------------------------------------------------------

test "grammar: digit-dot-digit is one float; digit-dot-ident is member access" {
    // ABNF `float` note: after `1*digit` a `.` joins the token only if a
    // digit follows — `1.5` is one float token, `1.x` is the integer `1`
    // followed by `.` and the member name `x`.
    var t = try parseText("const a = 1.5; const b = 1.x;");
    defer t.arena.deinit();

    try testing.expectEqual(@as(f64, 1.5), t.program.items[0].const_def.init.?.float.value);
    const b = t.program.items[1].const_def.init.?.member;
    try testing.expectEqualStrings("x", b.name.text);
    try testing.expectEqual(@as(u64, 1), b.object.int.value);
}

test "grammar: `_` is the wildcard token; `_foo` is an identifier" {
    // ABNF `wildcard-token` note: maximal munch — `_` followed by another
    // identifier character begins an identifier; a bare `_` is the
    // wildcard (and appears only in patterns, never as an expression).
    var t = try parseText("fn f() -> int32 { let _ = 1; let _foo = 2; _foo }");
    defer t.arena.deinit();

    const body = t.program.items[0].func_def.body.?;
    try testing.expect(body.stmts[0].let.pattern == .wildcard);
    try testing.expectEqualStrings("_foo", body.stmts[1].let.pattern.path.path[0].text);
    try testing.expectEqualStrings("_foo", body.result.?.path.path[0].text);
}

test "grammar: string escapes decode into the AST value" {
    // ABNF `escape` / `unicode-escape`: the lexer resolves escapes, so the
    // `StringLiteral` value holds the decoded bytes.
    var t = try parseText("const s = \"\\u{41}\\n\\r\\t\\\"q\\\\\";");
    defer t.arena.deinit();

    try testing.expectEqualStrings("A\n\r\t\"q\\", t.program.items[0].const_def.init.?.string.value);
}

test "grammar: line and nested block comments separate tokens" {
    // Grammar "Comments (lexical)": comments are discarded before
    // syntactic parsing, and block comments nest.
    var t = try parseText(
        \\const a = /* one /* two */ three */ 1; // trailing
        \\const b = 2;
    );
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 2), t.program.items.len);
    try testing.expectEqual(@as(u64, 1), t.program.items[0].const_def.init.?.int.value);
    try testing.expectEqual(@as(u64, 2), t.program.items[1].const_def.init.?.int.value);
}

test "grammar: unicode identifiers and raw unicode string content" {
    // Grammar `identifier`: XID_Start begins, XID_Continue continues; a
    // non-ASCII identifier can never collide with a reserved word.
    var t = try parseText("const héllo = \"wörld\"; fn π(α: int32) -> int32 { α }");
    defer t.arena.deinit();

    try testing.expectEqualStrings("héllo", t.program.items[0].const_def.name.text);
    try testing.expectEqualStrings("wörld", t.program.items[0].const_def.init.?.string.value);
    const f = t.program.items[1].func_def;
    try testing.expectEqualStrings("π", f.name.text);
    try testing.expectEqualStrings("α", f.params[0].name.text);
    try testing.expectEqualStrings("α", f.body.?.result.?.path.path[0].text);
}

// ---------------------------------------------------------------------------
// Program structure — module-item, const-def, func-def, lambda
// ---------------------------------------------------------------------------

test "grammar: all seven module-item kinds parse in order" {
    const text =
        \\const v: int32 = 1;
        \\fn f() -> void {}
        \\type T = int32;
        \\struct S { x: int32; }
        \\union U { A, B(int32) }
        \\opaque type O[T];
        \\using m.n;
    ;
    var t = try parseText(text);
    defer t.arena.deinit();

    const tags = [_]std.meta.Tag(ast.ModuleItem){ .const_def, .func_def, .type_def, .struct_def, .union_def, .opaque_def, .using_decl };
    try testing.expectEqual(@as(usize, 7), t.program.items.len);
    for (tags, 0..) |tag, i| try testing.expectEqual(tag, std.meta.activeTag(t.program.items[i]));
}

test "grammar: const-def's three forms" {
    // ABNF `const-def`: init-only, type+init, and the declaration-only host
    // constant (Core §2.6) whose value the host supplies.
    var t = try parseText("const a = 1; const b: int32 = 2; const c: str;");
    defer t.arena.deinit();

    const a = t.program.items[0].const_def;
    try testing.expect(a.type_ == null);
    try testing.expect(a.init != null);
    const b = t.program.items[1].const_def;
    try testing.expectEqual(ast.PrimitiveKind.int32, b.type_.?.primitive.kind);
    try testing.expect(b.init != null);
    const c = t.program.items[2].const_def;
    try testing.expectEqual(ast.PrimitiveKind.str, c.type_.?.primitive.kind);
    try testing.expect(c.init == null);
}

test "grammar: func-def — generics, param modes, required return, host binding" {
    var t = try parseText(
        \\fn one[T](borrow t: T, move u: T) -> T { t }
        \\fn two(x: int32) -> int32 { x }
        \\fn host[T](v: T) -> str;
    );
    defer t.arena.deinit();

    const one = t.program.items[0].func_def;
    try testing.expectEqualStrings("T", one.type_params[0].text);
    try testing.expectEqual(ast.ParamMode.borrow, one.params[0].mode);
    try testing.expectEqual(ast.ParamMode.move, one.params[1].mode);
    try testing.expectEqualStrings("T", one.ret.named.path[0].text);
    try testing.expect(one.body != null);
    const two = t.program.items[1].func_def;
    try testing.expectEqual(ast.PrimitiveKind.int32, two.ret.primitive.kind);
    try testing.expect(two.body != null);
    const host = t.program.items[2].func_def;
    try testing.expect(host.body == null);
    try testing.expectEqualStrings("T", host.type_params[0].text);
    try testing.expectEqual(ast.PrimitiveKind.str, host.ret.primitive.kind);
}

test "grammar: func-def — a missing return type is a parse error" {
    // Core §6.4: the arrow is required in the body form and the host-binding
    // form alike.
    var t = try parseError("fn f(x: int32) { x }");
    defer t.arena.deinit();
    try testing.expect(std.mem.indexOf(u8, t.diag.message, "must declare its return type") != null);

    var t2 = try parseError("fn g(x: int32);");
    defer t2.arena.deinit();
    try testing.expect(std.mem.indexOf(u8, t2.diag.message, "must declare its return type") != null);
}

test "grammar: lambda — modes, required return, immediate call" {
    var t = try parseText(
        \\fn f() -> int32 {
        \\    let g = fn(borrow x: int32) -> int32 { x };
        \\    fn(x: int32) -> int32 { x }(7)
        \\}
    );
    defer t.arena.deinit();

    const body = t.program.items[0].func_def.body.?;
    const g = body.stmts[0].let.init.lambda;
    try testing.expectEqual(ast.ParamMode.borrow, g.params[0].mode);
    try testing.expectEqual(ast.PrimitiveKind.int32, g.ret.primitive.kind);
    // A lambda is a primary, so a call suffix applies directly to it.
    const call = body.result.?.call;
    try testing.expect(call.callee.* == .lambda);
    try testing.expectEqual(@as(u64, 7), call.args[0].int.value);
}

test "grammar: lambda — a missing return type is a parse error" {
    // Core §6.3: a lambda declares its return type like a named function.
    var bad = try parseError("fn f() -> void { let g = fn(x: int32) { x }; }");
    defer bad.arena.deinit();
    try testing.expect(std.mem.indexOf(u8, bad.diag.message, "must declare its return type") != null);
}

test "grammar: a zero-parameter lambda is immediately callable" {
    var t = try parseText("const n = fn() -> int32 { 4 }();");
    defer t.arena.deinit();

    const call = t.program.items[0].const_def.init.?.call;
    try testing.expectEqual(@as(usize, 0), call.callee.lambda.params.len);
    try testing.expectEqual(@as(u64, 4), call.callee.lambda.body.result.?.int.value);
    try testing.expectEqual(@as(usize, 0), call.args.len);
}

test "grammar: function types — zero params, modes, nesting" {
    var t = try parseText("type Z = fn() -> void; type N = fn(fn(int32) -> int32, borrow str) -> bool;");
    defer t.arena.deinit();

    const z = t.program.items[0].type_def.target.function;
    try testing.expectEqual(@as(usize, 0), z.params.len);
    try testing.expectEqual(ast.PrimitiveKind.void, z.ret.primitive.kind);
    const n = t.program.items[1].type_def.target.function;
    try testing.expectEqual(@as(usize, 1), n.params[0].type_.function.params.len);
    try testing.expectEqual(ast.ParamMode.borrow, n.params[1].mode);
    try testing.expectEqual(ast.PrimitiveKind.bool, n.ret.primitive.kind);
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

test "grammar: all thirteen primitive types parse in type position" {
    const cases = .{
        .{ "any", ast.PrimitiveKind.any },
        .{ "byte", ast.PrimitiveKind.byte },
        .{ "hostdata", ast.PrimitiveKind.hostdata },
        .{ "int32", ast.PrimitiveKind.int32 },
        .{ "uint32", ast.PrimitiveKind.uint32 },
        .{ "int64", ast.PrimitiveKind.int64 },
        .{ "uint64", ast.PrimitiveKind.uint64 },
        .{ "float32", ast.PrimitiveKind.float32 },
        .{ "float64", ast.PrimitiveKind.float64 },
        .{ "bool", ast.PrimitiveKind.bool },
        .{ "str", ast.PrimitiveKind.str },
        .{ "void", ast.PrimitiveKind.void },
        .{ "never", ast.PrimitiveKind.never },
    };
    inline for (cases) |c| {
        const text = try std.fmt.allocPrint(testing.allocator, "type T = {s};", .{c[0]});
        defer testing.allocator.free(text);
        var t = try parseText(text);
        defer t.arena.deinit();
        try testing.expectEqual(c[1], t.program.items[0].type_def.target.primitive.kind);
    }
}

test "grammar: named types — dotted paths and type arguments" {
    var t = try parseText("type A = Key; type B = map.Key; type C = map.Key[int32, str];");
    defer t.arena.deinit();

    const a = t.program.items[0].type_def.target.named;
    try testing.expectEqual(@as(usize, 1), a.path.len);
    try testing.expect(a.type_args == null);
    const b = t.program.items[1].type_def.target.named;
    try testing.expectEqual(@as(usize, 2), b.path.len);
    const c = t.program.items[2].type_def.target.named;
    try testing.expectEqual(@as(usize, 2), c.path.len);
    try testing.expectEqual(@as(usize, 2), c.type_args.?.len);
    try testing.expectEqual(ast.PrimitiveKind.int32, c.type_args.?[0].primitive.kind);
    try testing.expectEqual(ast.PrimitiveKind.str, c.type_args.?[1].primitive.kind);
}

test "grammar: list, box, and tuple types nest; a one-element tuple type is distinct" {
    // ABNF `tuple-type` note: `tuple[int32]` is valid and distinct from
    // `int32`; only `tuple[]` is excluded (it is spelled `void`).
    var t = try parseText("type T = list[box[tuple[int32]]]; type U = tuple[int32];");
    defer t.arena.deinit();

    const tdef = t.program.items[0].type_def.target;
    try testing.expectEqual(ast.PrimitiveKind.int32, tdef.list.elem.box.inner.tuple.elems[0].primitive.kind);
    const u = t.program.items[1].type_def.target.tuple;
    try testing.expectEqual(@as(usize, 1), u.elems.len);
}

test "grammar: type-def takes generic parameters" {
    var t = try parseText("type Pair[A, B] = tuple[A, B];");
    defer t.arena.deinit();

    const td = t.program.items[0].type_def;
    try testing.expectEqual(@as(usize, 2), td.type_params.len);
    try testing.expectEqualStrings("B", td.type_params[1].text);
    try testing.expectEqual(@as(usize, 2), td.target.tuple.elems.len);
}

// ---------------------------------------------------------------------------
// Declarations — struct-def, union-def, using-decl
// ---------------------------------------------------------------------------

test "grammar: struct-def — fields, function fields, generics, drop-decl" {
    var t = try parseText(
        \\struct Counter[T] {
        \\    value: T;
        \\    next: fn(borrow Counter[T]) -> T;
        \\    drop(c) { c.value; }
        \\}
    );
    defer t.arena.deinit();

    const s = t.program.items[0].struct_def;
    try testing.expectEqual(@as(usize, 1), s.type_params.len);
    try testing.expectEqual(@as(usize, 2), s.fields.len);
    try testing.expectEqual(@as(usize, 1), s.fields[1].type_.function.params.len);
    try testing.expectEqual(ast.ParamMode.borrow, s.fields[1].type_.function.params[0].mode);
    const d = s.drop.?;
    try testing.expectEqualStrings("c", d.param.text);
    try testing.expectEqual(@as(usize, 1), d.body.stmts.len);
    try testing.expect(d.body.result == null);
}

test "grammar: union-def — payload arity zero, one, and many; trailing comma" {
    var t = try parseText("union R[E, T] { Ok(T), Err(E), Empty, }");
    defer t.arena.deinit();

    const u = t.program.items[0].union_def;
    try testing.expectEqual(@as(usize, 2), u.type_params.len);
    try testing.expectEqual(@as(usize, 3), u.variants.len);
    try testing.expect(u.variants[0].types.?.len == 1);
    try testing.expect(u.variants[2].types == null);
    try testing.expectEqualStrings("Empty", u.variants[2].name.text);
}

test "grammar: a union variant may carry several payload types" {
    var t = try parseText("union U { Pair(int32, str), }");
    defer t.arena.deinit();

    const p = t.program.items[0].union_def.variants[0];
    try testing.expectEqual(@as(usize, 2), p.types.?.len);
    try testing.expectEqual(ast.PrimitiveKind.str, p.types.?[1].primitive.kind);
}

test "grammar: empty struct, empty union, and a parameterless opaque type" {
    // `struct-def` allows zero fields, `union-def` allows zero variants
    // (both bodies are optional lists), and `opaque-def`'s type-params are
    // optional.
    var t = try parseText("struct S {} union U {} opaque type O;");
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 0), t.program.items[0].struct_def.fields.len);
    try testing.expect(t.program.items[0].struct_def.drop == null);
    try testing.expectEqual(@as(usize, 0), t.program.items[1].union_def.variants.len);
    const o = t.program.items[2].opaque_def;
    try testing.expectEqual(@as(usize, 0), o.type_params.len);
}

test "grammar: a struct may declare only a drop hook" {
    // `struct-def = … *field-decl [drop-decl] "}"` — zero fields is a
    // valid derivation.
    var t = try parseText("struct D { drop(s) {} }");
    defer t.arena.deinit();

    const d = t.program.items[0].struct_def;
    try testing.expectEqual(@as(usize, 0), d.fields.len);
    try testing.expectEqualStrings("s", d.drop.?.param.text);
}

test "grammar: using-decl — module and block scope, `as`, reserved-word segments" {
    // ABNF `using-decl` note: every path segment may be a reserved word
    // (`builtin.str`), and the alias is scoped to the module or block.
    var t = try parseText(
        \\using builtin.str as s;
        \\fn f() -> void {
        \\    using m.Option;
        \\    s
        \\}
    );
    defer t.arena.deinit();

    const top = t.program.items[0].using_decl;
    try testing.expectEqualStrings("str", top.path[1].text);
    try testing.expectEqualStrings("s", top.alias.?.text);
    const inner = t.program.items[1].func_def.body.?.stmts[0].using;
    try testing.expectEqual(@as(usize, 2), inner.path.len);
    try testing.expect(inner.alias == null);
}

// ---------------------------------------------------------------------------
// Blocks and statements
// ---------------------------------------------------------------------------

test "grammar: let takes a pattern with an optional type annotation" {
    var t = try parseText("fn f(p: Point) -> void { let x: int32 = 1; let (a, b) = p; }");
    defer t.arena.deinit();

    const stmts = t.program.items[0].func_def.body.?.stmts;
    const first = stmts[0].let;
    try testing.expectEqual(ast.PrimitiveKind.int32, first.type_.?.primitive.kind);
    try testing.expectEqualStrings("x", first.pattern.path.path[0].text);
    const second = stmts[1].let;
    try testing.expect(second.type_ == null);
    try testing.expectEqual(@as(usize, 2), second.pattern.tuple.elems.len);
}

test "grammar: the `;` vs `}` split separates expr-stmt from final expression (parser note 1)" {
    var t = try parseText("fn f() -> int32 { 1; 2 } fn g() -> void { 1; 2; ; }");
    defer t.arena.deinit();

    const f = t.program.items[0].func_def.body.?;
    try testing.expectEqual(@as(usize, 1), f.stmts.len);
    try testing.expectEqual(@as(u64, 2), f.result.?.int.value);
    const g = t.program.items[1].func_def.body.?;
    try testing.expectEqual(@as(usize, 3), g.stmts.len);
    try testing.expect(g.stmts[2] == .empty);
    try testing.expect(g.result == null);
}

test "grammar: drop-stmt names a local binding" {
    var t = try parseText("fn f() -> void { drop handle; }");
    defer t.arena.deinit();

    const stmt = t.program.items[0].func_def.body.?.stmts[0];
    try testing.expect(stmt == .drop);
    try testing.expectEqualStrings("handle", stmt.drop.name.text);
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

test "grammar: literals — int, float, string, bool, void" {
    var t = try parseText("const a = 42; const b = 2.5; const c = \"x\"; const d = true; const e = ();");
    defer t.arena.deinit();

    try testing.expectEqual(@as(u64, 42), t.program.items[0].const_def.init.?.int.value);
    try testing.expectEqual(@as(f64, 2.5), t.program.items[1].const_def.init.?.float.value);
    try testing.expectEqualStrings("x", t.program.items[2].const_def.init.?.string.value);
    try testing.expect(t.program.items[3].const_def.init.?.bool.value);
    try testing.expect(t.program.items[4].const_def.init.?.* == .void);
}

test "grammar: path expressions — single, dotted, with type arguments" {
    var t = try parseText("const a = x; const b = m.x; const c = m.x[int32];");
    defer t.arena.deinit();

    const a = t.program.items[0].const_def.init.?.path;
    try testing.expectEqual(@as(usize, 1), a.path.len);
    try testing.expect(a.type_args == null);
    try testing.expect(a.tail == .none);
    const b = t.program.items[1].const_def.init.?.path;
    try testing.expectEqual(@as(usize, 2), b.path.len);
    const c = t.program.items[2].const_def.init.?.path;
    try testing.expectEqual(@as(usize, 1), c.type_args.?.len);
    try testing.expect(c.tail == .none);
}

test "grammar: struct construction — fields, trailing comma, nesting, generics, empty" {
    var t = try parseText(
        \\const a = Outer{ p: Point{ x: 1, y: 2 }, q: 3, };
        \\const b = Pair[int32, str]{ first: 1, second: "s" };
        \\const c = Unit{};
    );
    defer t.arena.deinit();

    const a = t.program.items[0].const_def.init.?.path.tail.construct;
    try testing.expectEqual(@as(usize, 2), a.fields.len);
    try testing.expectEqual(@as(usize, 2), a.fields[0].value.path.tail.construct.fields.len);
    const b = t.program.items[1].const_def.init.?.path;
    try testing.expectEqual(@as(usize, 2), b.type_args.?.len);
    try testing.expectEqual(@as(usize, 2), b.tail.construct.fields.len);
    try testing.expectEqualStrings("second", b.tail.construct.fields[1].name.text);
    const c = t.program.items[2].const_def.init.?.path.tail.construct;
    try testing.expectEqual(@as(usize, 0), c.fields.len);
}

test "grammar: union variant expressions — no args, one, many, dotted path" {
    var t = try parseText("const a = R::None; const b = R::Ok(1); const c = R::Pair(1, \"x\"); const d = m.r.Result::Ok(1);");
    defer t.arena.deinit();

    const a = t.program.items[0].const_def.init.?.path.tail.variant;
    try testing.expect(a.args == null);
    try testing.expectEqualStrings("None", a.name.text);
    const b = t.program.items[1].const_def.init.?.path.tail.variant;
    try testing.expectEqual(@as(usize, 1), b.args.?.len);
    const c = t.program.items[2].const_def.init.?.path.tail.variant;
    try testing.expectEqual(@as(usize, 2), c.args.?.len);
    const d = t.program.items[3].const_def.init.?.path;
    try testing.expectEqual(@as(usize, 3), d.path.len);
    try testing.expectEqualStrings("Ok", d.tail.variant.name.text);
}

test "grammar: specialization — the two `::` disambiguations (Binding Power Table document)" {
    // After a bare type-path, `::` enters the path-tail branch (variant or
    // type-args); after any other postfix form it is the specialization
    // suffix.
    var t = try parseText("const a = Vec[int32]::[str]; const b = f()::[int32];");
    defer t.arena.deinit();

    const a = t.program.items[0].const_def.init.?.specialize;
    try testing.expectEqual(@as(usize, 1), a.type_args.len);
    try testing.expectEqual(ast.PrimitiveKind.str, a.type_args[0].primitive.kind);
    try testing.expectEqual(@as(usize, 1), a.operand.path.type_args.?.len);
    const b = t.program.items[1].const_def.init.?.specialize;
    try testing.expect(b.operand.* == .call);
    try testing.expectEqual(ast.PrimitiveKind.int32, b.type_args[0].primitive.kind);
}

test "grammar: paren, one-element tuple, and multi-element tuple" {
    var t = try parseText("const a = (1); const b = (1,); const c = (1, 2, 3);");
    defer t.arena.deinit();

    try testing.expectEqual(@as(u64, 1), t.program.items[0].const_def.init.?.paren.inner.int.value);
    try testing.expectEqual(@as(usize, 1), t.program.items[1].const_def.init.?.tuple.elems.len);
    try testing.expectEqual(@as(usize, 3), t.program.items[2].const_def.init.?.tuple.elems.len);
}

test "grammar: list literals — empty, one, many, trailing comma" {
    var t = try parseText("const a = []; const b = [1]; const c = [1, 2,];");
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 0), t.program.items[0].const_def.init.?.list.elems.len);
    try testing.expectEqual(@as(usize, 1), t.program.items[1].const_def.init.?.list.elems.len);
    try testing.expectEqual(@as(usize, 2), t.program.items[2].const_def.init.?.list.elems.len);
}

test "grammar: if — without else, with else block, with else-if chain" {
    var t = try parseText(
        \\fn f(c: bool, d: bool) -> int32 {
        \\    if (c) { 0; };
        \\    if (c) { 1 } else if (d) { 2 } else { 3 }
        \\}
    );
    defer t.arena.deinit();

    const body = t.program.items[0].func_def.body.?;
    const plain = body.stmts[0].expr.expr.if_;
    try testing.expect(plain.else_ == null);
    try testing.expect(plain.then.result == null);
    const chained = body.result.?.if_;
    try testing.expectEqual(@as(u64, 1), chained.then.result.?.int.value);
    const mid = chained.else_.?.if_;
    try testing.expectEqual(@as(u64, 2), mid.then.result.?.int.value);
    try testing.expectEqual(@as(u64, 3), mid.else_.?.block.block.result.?.int.value);
}

test "grammar: match — arms, block-body arm, trailing comma" {
    // Because a block is itself an expression, a match arm may use a block
    // body (Binding Power Table document, match form).
    var t = try parseText("const r = match (x) { 0 => { 1 }, n => { let y = n; y }, _ => 2, };");
    defer t.arena.deinit();

    const m = t.program.items[0].const_def.init.?.match;
    try testing.expectEqual(@as(usize, 3), m.arms.len);
    try testing.expect(m.arms[0].body.* == .block);
    const inner = m.arms[1].body.block.block;
    try testing.expectEqual(@as(usize, 1), inner.stmts.len);
    try testing.expectEqualStrings("y", inner.result.?.path.path[0].text);
}

test "grammar: match (move owner) transfers the scrutinee (§13.4)" {
    var t = try parseText("const r = match (move value) { _ => 1 };");
    defer t.arena.deinit();

    const m = t.program.items[0].const_def.init.?.match;
    try testing.expect(m.scrutinee.* == .move);
    try testing.expectEqualStrings("value", m.scrutinee.move.name.text);
}

test "grammar: import takes the spec's specifier forms (§2.4)" {
    var t = try parseText("const a = import(\"math\"); const b = import(\"lib/math\"); const c = import(\"./utils\");");
    defer t.arena.deinit();

    try testing.expectEqualStrings("math", t.program.items[0].const_def.init.?.import.module);
    try testing.expectEqualStrings("lib/math", t.program.items[1].const_def.init.?.import.module);
    try testing.expectEqualStrings("./utils", t.program.items[2].const_def.init.?.import.module);
}

test "grammar: a block expression carries its final expression's value (§13.1)" {
    var t = try parseText("const x = { let y = 10; y + 1 };");
    defer t.arena.deinit();

    const b = t.program.items[0].const_def.init.?.block.block;
    try testing.expectEqual(@as(usize, 1), b.stmts.len);
    try testing.expectEqual(ast.BinaryOp.add, b.result.?.binary.op);
}

test "grammar: unary binds looser than postfix" {
    var t = try parseText("const a = -f().x; const b = !f();");
    defer t.arena.deinit();

    try testing.expectEqual(ast.UnaryOp.neg, t.program.items[0].const_def.init.?.unary.op);
    try testing.expectEqualStrings("x", t.program.items[0].const_def.init.?.unary.operand.member.name.text);
    try testing.expect(t.program.items[0].const_def.init.?.unary.operand.member.object.* == .call);
    try testing.expectEqual(ast.UnaryOp.not, t.program.items[1].const_def.init.?.unary.op);
    try testing.expect(t.program.items[1].const_def.init.?.unary.operand.* == .call);
}

test "grammar: cast binds tighter than arithmetic and chains right" {
    // `as` binds tighter than `+` and the other arithmetic operators:
    // `n as int32 + 1` is `(n as int32) + 1`, and repeated `as` nest.
    var t = try parseText("const a = n as int32 + 1;");
    defer t.arena.deinit();

    const a = t.program.items[0].const_def.init.?.binary;
    try testing.expectEqual(ast.BinaryOp.add, a.op);
    try testing.expectEqual(ast.PrimitiveKind.int32, a.lhs.cast.target.primitive.kind);
    try testing.expectEqual(@as(u64, 1), a.rhs.int.value);
}

test "grammar: every binary operator maps to its AST op" {
    const cases = .{
        .{ "or", ast.BinaryOp.or_ },
        .{ "and", ast.BinaryOp.and_ },
        .{ "==", ast.BinaryOp.eq },
        .{ "!=", ast.BinaryOp.ne },
        .{ "<", ast.BinaryOp.lt },
        .{ "<=", ast.BinaryOp.le },
        .{ ">", ast.BinaryOp.gt },
        .{ ">=", ast.BinaryOp.ge },
        .{ "|", ast.BinaryOp.bitor },
        .{ "^", ast.BinaryOp.bitxor },
        .{ "&", ast.BinaryOp.bitand },
        .{ "<<", ast.BinaryOp.shl },
        .{ ">>", ast.BinaryOp.shr },
        .{ "+", ast.BinaryOp.add },
        .{ "-", ast.BinaryOp.sub },
        .{ "*", ast.BinaryOp.mul },
        .{ "/", ast.BinaryOp.div },
        .{ "%", ast.BinaryOp.rem },
    };
    inline for (cases) |c| {
        const text = try std.fmt.allocPrint(testing.allocator, "const x = a {s} b;", .{c[0]});
        defer testing.allocator.free(text);
        var t = try parseText(text);
        defer t.arena.deinit();
        const e = t.program.items[0].const_def.init.?;
        try testing.expect(e.* == .binary);
        try testing.expectEqual(c[1], e.binary.op);
    }
}

test "grammar: precedence and associativity match the Binding Power Table" {
    // Binding Power Table notes: `or` loosest, `and` next; comparison is non-associative
    // and looser than the bitwise three (`|` loosest, `&` tightest);
    // shifts sit between `&` and `+`; every left-recursive level
    // (`or`, `and`, `|`, `^`, `&`, shifts, `+ -`, `* / %`) associates left.
    var t = try parseText(
        \\const a = x or y or z;
        \\const b = x or y and z;
        \\const c = x | y ^ z;
        \\const d = x & y | z;
        \\const e = x & y << z;
        \\const f = x + y << z;
        \\const g = x + y * z;
        \\const h = x - y - z;
        \\const i = x & y == z;
        \\const j = x == y and z;
    );
    defer t.arena.deinit();

    // `x or y or z` = or(or(x, y), z).
    var e = try expectBinary(initOf(t.program.items[0]), .or_);
    _ = try expectBinary(e.lhs, .or_);
    try testing.expectEqualStrings("z", try singlePath(e.rhs));
    // `x or y and z` = or(x, and(y, z)).
    e = try expectBinary(initOf(t.program.items[1]), .or_);
    try testing.expectEqualStrings("x", try singlePath(e.lhs));
    _ = try expectBinary(e.rhs, .and_);
    // `x | y ^ z` = x | (y ^ z).
    e = try expectBinary(initOf(t.program.items[2]), .bitor);
    try testing.expectEqualStrings("x", try singlePath(e.lhs));
    _ = try expectBinary(e.rhs, .bitxor);
    // `x & y | z` = (x & y) | z.
    e = try expectBinary(initOf(t.program.items[3]), .bitor);
    _ = try expectBinary(e.lhs, .bitand);
    try testing.expectEqualStrings("z", try singlePath(e.rhs));
    // `x & y << z` = x & (y << z).
    e = try expectBinary(initOf(t.program.items[4]), .bitand);
    try testing.expectEqualStrings("x", try singlePath(e.lhs));
    _ = try expectBinary(e.rhs, .shl);
    // `x + y << z` = (x + y) << z.
    e = try expectBinary(initOf(t.program.items[5]), .shl);
    _ = try expectBinary(e.lhs, .add);
    try testing.expectEqualStrings("z", try singlePath(e.rhs));
    // `x + y * z` = x + (y * z).
    e = try expectBinary(initOf(t.program.items[6]), .add);
    try testing.expectEqualStrings("x", try singlePath(e.lhs));
    _ = try expectBinary(e.rhs, .mul);
    // `x - y - z` = (x - y) - z.
    e = try expectBinary(initOf(t.program.items[7]), .sub);
    _ = try expectBinary(e.lhs, .sub);
    try testing.expectEqualStrings("z", try singlePath(e.rhs));
    // `x & y == z` = (x & y) == z: comparison is looser than `&`.
    e = try expectBinary(initOf(t.program.items[8]), .eq);
    _ = try expectBinary(e.lhs, .bitand);
    // `x == y and z` = (x == y) and z: `and` is looser than `==`.
    e = try expectBinary(initOf(t.program.items[9]), .and_);
    _ = try expectBinary(e.lhs, .eq);
}

test "grammar: unary chains nest and cast binds tighter than unary" {
    var t = try parseText(
        \\const a = - -x;
        \\const b = !!x;
        \\const c = -x as int32;
        \\const d = n as int32 as str;
    );
    defer t.arena.deinit();

    const a = initOf(t.program.items[0]).unary;
    try testing.expectEqual(ast.UnaryOp.neg, a.op);
    try testing.expectEqual(ast.UnaryOp.neg, a.operand.unary.op);
    const b = initOf(t.program.items[1]).unary;
    try testing.expectEqual(ast.UnaryOp.not, b.op);
    try testing.expectEqual(ast.UnaryOp.not, b.operand.unary.op);
    // `as` binds tighter than the prefix operators: `-x as int32` is
    // -(x as int32), the cast inside the negation.
    const c = initOf(t.program.items[2]).unary;
    try testing.expectEqual(ast.UnaryOp.neg, c.op);
    try testing.expectEqual(ast.PrimitiveKind.int32, c.operand.cast.target.primitive.kind);
    // Repeated `as` nest right: cast(cast(n, int32), str).
    const d = initOf(t.program.items[3]).cast;
    try testing.expectEqual(ast.PrimitiveKind.str, d.target.primitive.kind);
    try testing.expectEqual(ast.PrimitiveKind.int32, d.operand.cast.target.primitive.kind);
}

test "grammar: move names a complete local binding in every unary position" {
    var t = try parseText(
        \\fn f() -> int32 {
        \\    let y = move x;
        \\    take(move x);
        \\    let z = -move x;
        \\    y
        \\}
    );
    defer t.arena.deinit();

    const body = t.program.items[0].func_def.body.?;
    try testing.expectEqualStrings("x", body.stmts[0].let.init.move.name.text);
    const arg = body.stmts[1].expr.expr.call.args[0];
    try testing.expect(arg == .move);
    try testing.expectEqualStrings("x", arg.move.name.text);
    const neg = body.stmts[2].let.init.unary;
    try testing.expectEqual(ast.UnaryOp.neg, neg.op);
    try testing.expectEqualStrings("x", neg.operand.move.name.text);
}

test "grammar: postfix suffixes follow construction and variant primaries" {
    // `postfix = primary *postfix-suffix` applies to every primary, so a
    // construction brace or variant tail may itself carry member, call,
    // and specialization suffixes.
    var t = try parseText(
        \\const a = S{}.x;
        \\const b = S{}.f();
        \\const c = R::Ok(1).x;
        \\const d = Vec[int32]::[str, bool];
    );
    defer t.arena.deinit();

    const a = initOf(t.program.items[0]).member;
    try testing.expectEqualStrings("x", a.name.text);
    try testing.expectEqual(@as(usize, 0), a.object.path.tail.construct.fields.len);
    const b = initOf(t.program.items[1]).call;
    try testing.expectEqualStrings("f", b.callee.member.name.text);
    try testing.expect(b.callee.member.object.* == .path);
    const c = initOf(t.program.items[2]).member;
    try testing.expectEqualStrings("Ok", c.object.path.tail.variant.name.text);
    const d = initOf(t.program.items[3]).specialize;
    try testing.expectEqual(@as(usize, 2), d.type_args.len);
    try testing.expectEqual(@as(usize, 1), d.operand.path.type_args.?.len);
}

test "grammar: postfix chains mix member, call, and specialization" {
    var t = try parseText("const r = a.b(1).c.d(2);");
    defer t.arena.deinit();

    const r = t.program.items[0].const_def.init.?.call;
    try testing.expectEqualStrings("d", r.callee.member.name.text);
    const c = r.callee.member.object;
    try testing.expectEqualStrings("c", c.member.name.text);
    try testing.expect(c.member.object.* == .call);
    try testing.expectEqual(@as(usize, 1), c.member.object.call.args.len);
    const base = c.member.object.call.callee.path;
    try testing.expectEqual(@as(usize, 2), base.path.len);
    try testing.expect(base.tail == .none);
}

test "grammar: reserved words parse as member names after any primary (parser note 4)" {
    // The token after `.` is read as a member name whether or not it is
    // reserved — `builtin.str` via the path grammar, `f().str` and
    // `(m).box` via the postfix member suffix.
    var t = try parseText("const a = builtin.str; const b = f().str; const c = (m).box;");
    defer t.arena.deinit();

    try testing.expectEqualStrings("str", t.program.items[0].const_def.init.?.path.path[1].text);
    const b = t.program.items[1].const_def.init.?.member;
    try testing.expectEqualStrings("str", b.name.text);
    try testing.expect(b.object.* == .call);
    const c = t.program.items[2].const_def.init.?.member;
    try testing.expectEqualStrings("box", c.name.text);
    try testing.expect(c.object.* == .paren);
}

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

test "grammar: literal patterns — int, negative, float, string, bool, void" {
    var t = try parseText(
        \\const r = match (x) {
        \\    42 => 0, -7 => 1, 2.5 => 2, -0.5 => 3,
        \\    "s" => 4, true => 5, false => 6, () => 7,
        \\};
    );
    defer t.arena.deinit();

    const arms = t.program.items[0].const_def.init.?.match.arms;
    try testing.expectEqual(@as(u64, 42), arms[0].pattern.literal.value.int);
    try testing.expectEqual(@as(u64, 7), arms[1].pattern.literal.value.neg_int);
    try testing.expectEqual(@as(f64, 2.5), arms[2].pattern.literal.value.float);
    try testing.expectEqual(@as(f64, 0.5), arms[3].pattern.literal.value.neg_float);
    try testing.expectEqualStrings("s", arms[4].pattern.literal.value.string);
    try testing.expect(arms[5].pattern.literal.value.bool);
    try testing.expect(!arms[6].pattern.literal.value.bool);
    // `()` is the empty branch of tuple-pattern, matching the void value.
    try testing.expectEqual(@as(usize, 0), arms[7].pattern.tuple.elems.len);
}

test "grammar: keyword-led type-test patterns — every test type" {
    // ABNF `type-test-type`: the nine testable primitives plus the list,
    // box, tuple, and fn constructors (`any`, `never`, and `hostdata` are
    // excluded; rejecting them is covered in `parser.zig`).
    const prims = .{
        .{ "byte", ast.PrimitiveKind.byte },
        .{ "int32", ast.PrimitiveKind.int32 },
        .{ "uint32", ast.PrimitiveKind.uint32 },
        .{ "int64", ast.PrimitiveKind.int64 },
        .{ "uint64", ast.PrimitiveKind.uint64 },
        .{ "float32", ast.PrimitiveKind.float32 },
        .{ "float64", ast.PrimitiveKind.float64 },
        .{ "bool", ast.PrimitiveKind.bool },
        .{ "str", ast.PrimitiveKind.str },
    };
    inline for (prims) |c| {
        const text = try std.fmt.allocPrint(testing.allocator, "const r = match (a) {{ {s} n => 1, _ => 0 }};", .{c[0]});
        defer testing.allocator.free(text);
        var t = try parseText(text);
        defer t.arena.deinit();
        const tt = t.program.items[0].const_def.init.?.match.arms[0].pattern.type_test;
        try testing.expectEqual(c[1], tt.type_.primitive.kind);
        try testing.expectEqualStrings("n", tt.binding.?.text);
    }

    var t = try parseText(
        \\const r = match (a) {
        \\    list[int32] xs => 1,
        \\    box[str] b => 2,
        \\    tuple[int32, str] t => 3,
        \\    fn(int32) -> int32 f => 4,
        \\    _ => 0,
        \\};
    );
    defer t.arena.deinit();

    const arms = t.program.items[0].const_def.init.?.match.arms;
    try testing.expectEqual(ast.PrimitiveKind.int32, arms[0].pattern.type_test.type_.list.elem.primitive.kind);
    try testing.expectEqual(ast.PrimitiveKind.str, arms[1].pattern.type_test.type_.box.inner.primitive.kind);
    try testing.expectEqual(@as(usize, 2), arms[2].pattern.type_test.type_.tuple.elems.len);
    try testing.expectEqual(@as(usize, 1), arms[3].pattern.type_test.type_.function.params.len);
    try testing.expectEqualStrings("f", arms[3].pattern.type_test.binding.?.text);
}

test "grammar: identifier-led type-test patterns (parser note 3)" {
    // An identifier immediately following the type path (with optional
    // type arguments) marks a type-test binding; a bare identifier is an
    // identifier-pattern.
    var t = try parseText("const r = match (a) { File f => 1, Opt[int32] o => 2, mod.File g => 3, x => 4 };");
    defer t.arena.deinit();

    const arms = t.program.items[0].const_def.init.?.match.arms;
    const f = arms[0].pattern.type_test;
    try testing.expectEqualStrings("File", f.type_.named.path[0].text);
    try testing.expectEqualStrings("f", f.binding.?.text);
    const o = arms[1].pattern.type_test;
    try testing.expectEqual(@as(usize, 1), o.type_.named.type_args.?.len);
    try testing.expectEqualStrings("o", o.binding.?.text);
    const g = arms[2].pattern.type_test;
    try testing.expectEqual(@as(usize, 2), g.type_.named.path.len);
    try testing.expectEqualStrings("g", g.binding.?.text);
    try testing.expect(arms[3].pattern.path.tail == .none);
}

test "grammar: tuple patterns — one element, many, nested" {
    var t = try parseText("fn f() -> void { let (a,) = p; let (a, b) = q; let ((a, b), c) = r; }");
    defer t.arena.deinit();

    const stmts = t.program.items[0].func_def.body.?.stmts;
    try testing.expectEqual(@as(usize, 1), stmts[0].let.pattern.tuple.elems.len);
    try testing.expectEqual(@as(usize, 2), stmts[1].let.pattern.tuple.elems.len);
    const nested = stmts[2].let.pattern.tuple;
    try testing.expectEqual(@as(usize, 2), nested.elems.len);
    try testing.expect(nested.elems[0] == .tuple);
}

test "grammar: path patterns — identifier, struct, variant" {
    var t = try parseText(
        \\fn f(x: X) -> void {
        \\    match (x) {
        \\        plain => 0,
        \\        P{ x, y: 0, } => 1,
        \\        P{ inner: q::Some(v) } => 2,
        \\        Unit{} => 3,
        \\        R::Ok => 4,
        \\        R::Ok(a, b) => 5,
        \\        m.r.Result::Ok(v) => 6,
        \\    }
        \\}
    );
    defer t.arena.deinit();

    const arms = t.program.items[0].func_def.body.?.result.?.match.arms;
    try testing.expect(arms[0].pattern.path.tail == .none);
    const shorthand = arms[1].pattern.path.tail.struct_;
    try testing.expect(shorthand.fields[0].pattern == null);
    try testing.expectEqual(@as(u64, 0), shorthand.fields[1].pattern.?.literal.value.int);
    const nested = arms[2].pattern.path.tail.struct_.fields[0].pattern.?.path.tail.variant;
    try testing.expectEqualStrings("Some", nested.name.text);
    try testing.expectEqualStrings("v", nested.args.?[0].path.path[0].text);
    try testing.expectEqual(@as(usize, 0), arms[3].pattern.path.tail.struct_.fields.len);
    try testing.expect(arms[4].pattern.path.tail.variant.args == null);
    try testing.expectEqual(@as(usize, 2), arms[5].pattern.path.tail.variant.args.?.len);
    const dotted = arms[6].pattern.path;
    try testing.expectEqual(@as(usize, 3), dotted.path.len);
    try testing.expectEqualStrings("Ok", dotted.tail.variant.name.text);
}

test "grammar: list patterns — empty, rest-only, items, items-with-rest" {
    var t = try parseText(
        \\fn f(xs: list[int32]) -> void {
        \\    match (xs) {
        \\        [] => 0,
        \\        [..all] => 1,
        \\        [a] => 2,
        \\        [a, b] => 3,
        \\        [head, ..tail] => 4,
        \\        [a, b, ..rest] => 5,
        \\    }
        \\}
    );
    defer t.arena.deinit();

    const arms = t.program.items[0].func_def.body.?.result.?.match.arms;
    const empty = arms[0].pattern.list;
    try testing.expectEqual(@as(usize, 0), empty.items.len);
    try testing.expect(empty.rest == null);
    const rest_only = arms[1].pattern.list;
    try testing.expectEqual(@as(usize, 0), rest_only.items.len);
    try testing.expectEqualStrings("all", rest_only.rest.?.text);
    try testing.expectEqual(@as(usize, 1), arms[2].pattern.list.items.len);
    try testing.expect(arms[2].pattern.list.rest == null);
    try testing.expectEqual(@as(usize, 2), arms[3].pattern.list.items.len);
    try testing.expectEqual(@as(usize, 1), arms[4].pattern.list.items.len);
    try testing.expectEqualStrings("tail", arms[4].pattern.list.rest.?.text);
    try testing.expectEqual(@as(usize, 2), arms[5].pattern.list.items.len);
    try testing.expectEqualStrings("rest", arms[5].pattern.list.rest.?.text);
}

// ---------------------------------------------------------------------------
// Spans
// ---------------------------------------------------------------------------

test "grammar: spans cover statements, arms, and control flow" {
    var t = try parseText("fn f(x: int32) -> void { let y = x; match (y) { 0 => 1, _ => 2 } }");
    defer t.arena.deinit();
    const text = t.source.text;

    const body = t.program.items[0].func_def.body.?;
    const let_stmt = body.stmts[0].let;
    try testing.expectEqualStrings("let y = x;", text[let_stmt.span.start..let_stmt.span.end]);
    const m = body.result.?.match;
    try testing.expectEqualStrings("match (y) { 0 => 1, _ => 2 }", text[m.span.start..m.span.end]);
    try testing.expectEqualStrings("0 => 1", text[m.arms[0].span.start..m.arms[0].span.end]);
    try testing.expectEqualStrings("2", text[m.arms[1].body.span().start..m.arms[1].body.span().end]);

    var u = try parseText("const v = if (c) { 1 } else { 0 };");
    defer u.arena.deinit();
    const itext = u.source.text;
    const if_ = u.program.items[0].const_def.init.?.if_;
    try testing.expectEqualStrings("if (c) { 1 } else { 0 }", itext[if_.span.start..if_.span.end]);
    try testing.expectEqualStrings("{ 1 }", itext[if_.then.span.start..if_.then.span.end]);
}

test "grammar: node spans slice the exact source text" {
    var t = try parseText("const s = 1 + 2 * 3; const p = Point{ x: 1, y: 2 };");
    defer t.arena.deinit();
    const text = t.source.text;

    const s = t.program.items[0].const_def.init.?.binary;
    try testing.expectEqualStrings("2 * 3", text[s.rhs.span().start..s.rhs.span().end]);
    try testing.expectEqualStrings("1 + 2 * 3", text[s.span.start..s.span.end]);

    const p = t.program.items[1].const_def.init.?.path;
    try testing.expectEqualStrings("Point{ x: 1, y: 2 }", text[p.span.start..p.span.end]);
    try testing.expectEqualStrings("{ x: 1, y: 2 }", text[p.tail.construct.span.start..p.tail.construct.span.end]);
    try testing.expectEqualStrings("x: 1", text[p.tail.construct.fields[0].span.start..p.tail.construct.fields[0].span.end]);
}

// ---------------------------------------------------------------------------
// Core Language Specification example programs, verbatim
// ---------------------------------------------------------------------------

test "spec §2.1: the calc module parses to three members" {
    const src =
        \\const pi: float32 = 3.141592653589793;
        \\
        \\fn add(a: int32, b: int32) -> int32 {
        \\    a + b
        \\}
        \\
        \\fn square(x: float32) -> float32 {
        \\    x * x
        \\}
    ;
    var t = try parseText(src);
    defer t.arena.deinit();

    try testing.expectEqual(@as(usize, 3), t.program.items.len);
    const pi = t.program.items[0].const_def;
    try testing.expectEqual(ast.PrimitiveKind.float32, pi.type_.?.primitive.kind);
    try testing.expectEqual(@as(f64, 3.141592653589793), pi.init.?.float.value);
    const add = t.program.items[1].func_def;
    try testing.expectEqual(@as(usize, 2), add.params.len);
    try testing.expectEqual(ast.BinaryOp.add, add.body.?.result.?.binary.op);
    const square = t.program.items[2].func_def;
    try testing.expectEqual(ast.BinaryOp.mul, square.body.?.result.?.binary.op);
}

test "spec §2.2 and §2.7: import consumers with chained member access" {
    const consumer =
        \\const calc = import("calc");
        \\const builtin = import("builtin");
        \\
        \\fn main() -> void {
        \\    builtin.print(
        \\        builtin.str(calc.add(20, 22))
        \\    );
        \\}
    ;
    var c = try parseText(consumer);
    defer c.arena.deinit();

    try testing.expectEqualStrings("calc", c.program.items[0].const_def.init.?.import.module);
    const body = c.program.items[2].func_def.body.?;
    try testing.expect(body.result == null);
    const print = body.stmts[0].expr.expr.call;
    try testing.expectEqual(@as(usize, 2), print.callee.path.path.len);
    try testing.expectEqualStrings("print", print.callee.path.path[1].text);
    const str = print.args[0].call;
    try testing.expectEqualStrings("str", str.callee.path.path[1].text);
    const add = str.args[0].call;
    try testing.expectEqual(@as(usize, 2), add.callee.path.path.len);
    try testing.expectEqual(@as(u64, 20), add.args[0].int.value);
    try testing.expectEqual(@as(u64, 22), add.args[1].int.value);

    const nested =
        \\const std = import("std");
        \\const builtin = import("builtin");
        \\
        \\fn main() -> void {
        \\    let x =
        \\        std.math.sqrt(16.0);
        \\
        \\    builtin.print(
        \\        std.string.upper("hello")
        \\    );
        \\}
    ;
    var n = try parseText(nested);
    defer n.arena.deinit();

    const nbody = n.program.items[2].func_def.body.?;
    const sqrt = nbody.stmts[0].let.init.call;
    try testing.expectEqual(@as(usize, 3), sqrt.callee.path.path.len);
    try testing.expectEqual(@as(f64, 16.0), sqrt.args[0].float.value);
    const upper = nbody.stmts[1].expr.expr.call.args[0].call;
    try testing.expectEqual(@as(usize, 3), upper.callee.path.path.len);
    try testing.expectEqualStrings("hello", upper.args[0].string.value);
}

test "grammar: `builtin`, `array`, and `hashmap` are ordinary identifiers" {
    // Core §3: `builtin` may be bound, aliased, and shadowed like any
    // other identifier; Grammar "Reserved words": the collection type
    // names `array` and `hashmap` are not reserved words.
    var t = try parseText(
        \\const builtin = 1;
        \\fn main() -> int32 {
        \\    let array = 2;
        \\    let hashmap = 3;
        \\    array + hashmap
        \\}
    );
    defer t.arena.deinit();

    try testing.expectEqualStrings("builtin", t.program.items[0].const_def.name.text);
    const body = t.program.items[1].func_def.body.?;
    try testing.expectEqualStrings("array", body.stmts[0].let.pattern.path.path[0].text);
    try testing.expectEqualStrings("hashmap", body.stmts[1].let.pattern.path.path[0].text);
    try testing.expectEqual(ast.BinaryOp.add, body.result.?.binary.op);
}

test "spec §2.3 and §2.5: module constant aliasing and qualified type paths" {
    const src =
        \\const math = import("math");
        \\const public_math = math;
        \\
        \\const geometry = import("geometry");
        \\
        \\fn origin() -> float64 {
        \\    let p: geometry.Point = geometry.make_point(1.0, 2.0);
        \\    p.x
        \\}
    ;
    var t = try parseText(src);
    defer t.arena.deinit();

    // §2.3: a module binding may be initialized by another module binding.
    const alias = t.program.items[1].const_def;
    try testing.expect(alias.type_ == null);
    try testing.expectEqualStrings("math", alias.init.?.path.path[0].text);
    // §2.5: a let annotation may use a qualified module type path, while
    // the initializer is runtime member access (`p.x` is a dotted path in
    // primary position).
    const body = t.program.items[3].func_def.body.?;
    const point = body.stmts[0].let.type_.?.named;
    try testing.expectEqual(@as(usize, 2), point.path.len);
    try testing.expectEqualStrings("Point", point.path[1].text);
    const make = body.stmts[0].let.init.call;
    try testing.expectEqual(@as(usize, 2), make.callee.path.path.len);
    try testing.expectEqual(@as(usize, 2), make.args.len);
    try testing.expectEqualStrings("x", body.result.?.path.path[1].text);
}

test "spec §2.8: a using alias names a callable module member" {
    const src =
        \\const string = import("string");
        \\
        \\using string.upper as up;
        \\
        \\fn shout(text: str) -> str {
        \\    up(text)
        \\}
    ;
    var t = try parseText(src);
    defer t.arena.deinit();

    const using = t.program.items[1].using_decl;
    try testing.expectEqual(@as(usize, 2), using.path.len);
    try testing.expectEqualStrings("up", using.alias.?.text);
    const shout = t.program.items[2].func_def;
    const call = shout.body.?.result.?.call;
    try testing.expectEqualStrings("up", call.callee.path.path[0].text);
    try testing.expectEqualStrings("text", call.args[0].path.path[0].text);
}

test "spec §4: shadowing rebinds and assignment has no grammar" {
    const src =
        \\fn f() -> int32 {
        \\    let x = 10;
        \\    let x = x + 1;
        \\    x
        \\}
    ;
    var t = try parseText(src);
    defer t.arena.deinit();

    const body = t.program.items[0].func_def.body.?;
    try testing.expectEqualStrings("x", body.stmts[0].let.pattern.path.path[0].text);
    // The right-hand `x` refers to the previous binding: an ordinary path.
    try testing.expectEqualStrings("x", body.stmts[1].let.init.binary.lhs.path.path[0].text);
    try testing.expectEqual(@as(u64, 1), body.stmts[1].let.init.binary.rhs.int.value);
    try testing.expectEqualStrings("x", body.result.?.path.path[0].text);

    // Bindings are immutable — there is no assignment operator, so
    // `x = 30;` is not a statement the grammar can produce (§4).
    var bad = try parseError("fn g() -> void { x = 30; }");
    defer bad.arena.deinit();
    try testing.expectEqualStrings("expected ';' or '}' after expression, found '='", bad.diag.message);
}

test "spec §6.1: a function field is stored and called explicitly — no implicit receiver" {
    const src =
        \\fn main() -> void {
        \\    let counter =
        \\        Counter{
        \\            value: 10,
        \\            next:
        \\                fn(borrow counter: Counter) -> int32 {
        \\                    counter.value + 1
        \\                }
        \\        };
        \\
        \\    counter.next(counter);
        \\}
    ;
    var t = try parseText(src);
    defer t.arena.deinit();

    const body = t.program.items[0].func_def.body.?;
    const construct = body.stmts[0].let.init.path.tail.construct;
    try testing.expectEqual(@as(usize, 2), construct.fields.len);
    try testing.expectEqual(@as(u64, 10), construct.fields[0].value.int.value);
    const lambda = construct.fields[1].value.lambda;
    try testing.expectEqual(ast.ParamMode.borrow, lambda.params[0].mode);
    try testing.expectEqual(ast.BinaryOp.add, lambda.body.result.?.binary.op);
    // `counter.next(counter)`: the callee is the dotted access
    // `counter.next` (a two-segment path in primary position); the
    // instance is passed explicitly as the sole argument.
    const call = body.stmts[1].expr.expr.call;
    try testing.expectEqual(@as(usize, 2), call.callee.path.path.len);
    try testing.expectEqualStrings("counter", call.callee.path.path[0].text);
    try testing.expectEqualStrings("next", call.callee.path.path[1].text);
    try testing.expectEqual(@as(usize, 1), call.args.len);
    try testing.expectEqualStrings("counter", call.args[0].path.path[0].text);
}

test "spec §13.2 and §13.3: the sign and message control-flow examples" {
    const sign =
        \\fn sign(value: int32) -> int32 {
        \\    let sign =
        \\        if (value >= 0) {
        \\            1
        \\        } else {
        \\            -1
        \\        };
        \\    sign
        \\}
    ;
    var s = try parseText(sign);
    defer s.arena.deinit();

    const sif = s.program.items[0].func_def.body.?.stmts[0].let.init.if_;
    try testing.expectEqual(ast.BinaryOp.ge, sif.cond.binary.op);
    try testing.expectEqual(@as(u64, 1), sif.then.result.?.int.value);
    try testing.expectEqual(ast.UnaryOp.neg, sif.else_.?.block.block.result.?.unary.op);

    const message =
        \\fn message(result: Result) -> str {
        \\    match (result) {
        \\        Result::Ok(value) =>
        \\            "ok: " + builtin.str(value),
        \\
        \\        Result::Err(error) =>
        \\            "error: " + error
        \\    }
        \\}
    ;
    var m = try parseText(message);
    defer m.arena.deinit();

    const arms = m.program.items[0].func_def.body.?.result.?.match.arms;
    try testing.expectEqual(@as(usize, 2), arms.len);
    const ok = arms[0].pattern.path.tail.variant;
    try testing.expectEqualStrings("Ok", ok.name.text);
    try testing.expectEqualStrings("value", ok.args.?[0].path.path[0].text);
    try testing.expectEqual(ast.BinaryOp.add, arms[0].body.binary.op);
    try testing.expectEqualStrings("Err", arms[1].pattern.path.tail.variant.name.text);
    try testing.expectEqual(ast.BinaryOp.add, arms[1].body.binary.op);
}

test "spec §17: the resource module and its consumer parse verbatim" {
    const file_st =
        \\const os = import("os");
        \\const builtin = import("builtin");
        \\
        \\struct File {
        \\    fd: int32;
        \\    path: str;
        \\
        \\    drop(file) {
        \\        os.close(file.fd);
        \\    }
        \\}
        \\
        \\fn open(path: str) -> File {
        \\    File{
        \\        fd: os.open(path),
        \\        path: path
        \\    }
        \\}
        \\
        \\fn create(path: str) -> File {
        \\    File{
        \\        fd: os.create(path),
        \\        path: path
        \\    }
        \\}
        \\
        \\fn inspect(borrow file: File) -> void {
        \\    builtin.print(file.path);
        \\}
    ;
    var f = try parseText(file_st);
    defer f.arena.deinit();

    try testing.expectEqual(@as(usize, 6), f.program.items.len);
    try testing.expectEqualStrings("os", f.program.items[0].const_def.init.?.import.module);
    const file = f.program.items[2].struct_def;
    try testing.expectEqual(@as(usize, 2), file.fields.len);
    try testing.expectEqual(ast.PrimitiveKind.str, file.fields[1].type_.primitive.kind);
    const drop = file.drop.?;
    try testing.expectEqualStrings("file", drop.param.text);
    const close = drop.body.stmts[0].expr.expr.call;
    try testing.expectEqual(@as(usize, 2), close.callee.path.path.len);
    try testing.expectEqualStrings("close", close.callee.path.path[1].text);
    try testing.expectEqualStrings("fd", close.args[0].path.path[1].text);
    const open = f.program.items[3].func_def;
    try testing.expectEqualStrings("File", open.ret.named.path[0].text);
    const opened = open.body.?.result.?.path.tail.construct;
    try testing.expectEqualStrings("fd", opened.fields[0].name.text);
    try testing.expectEqualStrings("os.open(path)", f.source.text[opened.fields[0].value.span().start..opened.fields[0].value.span().end]);
    const inspect = f.program.items[5].func_def;
    try testing.expectEqual(ast.ParamMode.borrow, inspect.params[0].mode);

    const consumer =
        \\const file = import("file");
        \\
        \\fn main() -> void {
        \\    let handle =
        \\        file.open("data.txt");
        \\
        \\    file.inspect(handle);
        \\
        \\    drop handle;
        \\}
    ;
    var c = try parseText(consumer);
    defer c.arena.deinit();

    const body = c.program.items[1].func_def.body.?;
    try testing.expectEqual(@as(usize, 3), body.stmts.len);
    try testing.expectEqualStrings("file", body.stmts[0].let.init.call.callee.path.path[0].text);
    try testing.expectEqualStrings("handle", body.stmts[0].let.pattern.path.path[0].text);
    try testing.expect(body.stmts[1] == .expr);
    try testing.expect(body.stmts[2] == .drop);
}

test "grammar: every reserved word parses as a path segment after `.` (parser note 4)" {
    // The ABNF reserved list, in header order: the token after `.` is
    // read as a member name whether or not it is reserved.
    const words = .{
        "and",     "any",    "as",       "bool",   "borrow",  "box",
        "byte",    "const",  "drop",     "else",   "float64", "false",
        "float32", "fn",     "hostdata", "int64",  "if",      "import",
        "int32",   "let",    "list",     "match",  "move",    "never",
        "opaque",  "or",     "str",      "struct", "true",    "tuple",
        "type",    "uint64", "uint32",   "union",  "using",   "void",
    };
    inline for (words) |w| {
        const text = try std.fmt.allocPrint(testing.allocator, "const x = m.{s};", .{w});
        defer testing.allocator.free(text);
        var t = try parseText(text);
        defer t.arena.deinit();
        const p = t.program.items[0].const_def.init.?.path;
        try testing.expectEqual(@as(usize, 2), p.path.len);
        try testing.expectEqualStrings(w, p.path[1].text);
        try testing.expect(p.tail == .none);
    }
}

test "grammar: reserved words parse as names after `::` (parser note 4)" {
    // The same rule as after `.`: the token after `::` is a variant
    // name whether or not it is reserved.
    var t = try parseText("const a = R::str; const r = match (x) { R::or => a, _ => 0, };");
    defer t.arena.deinit();

    const v = t.program.items[0].const_def.init.?.path.tail.variant;
    try testing.expectEqualStrings("str", v.name.text);
    try testing.expect(v.args == null);
    const arm = t.program.items[1].const_def.init.?.match.arms[0].pattern.path.tail.variant;
    try testing.expectEqualStrings("or", arm.name.text);
    try testing.expect(arm.args == null);
}

// ---------------------------------------------------------------------------
// Syntactic rejections
// ---------------------------------------------------------------------------

test "grammar rejects: an unparenthesized if condition" {
    // Core §13.2: the condition is parenthesized — mandatory.
    var t = try parseError("const x = if y { 1 } else { 2 };");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected '(', found y", t.diag.message);
}

test "grammar rejects: else without a block or if" {
    var t = try parseError("fn f(c: bool) -> void { if (c) { 1; } else 2; }");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected 'if' or a block after 'else', found 2", t.diag.message);
}

test "grammar rejects: generic parameters on a lambda" {
    // The lambda form (Binding Power Table document) has no type-params;
    // only named `func-def` does.
    var t = try parseError("const f = fn[T](x: T) { x };");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected '(', found '['", t.diag.message);
}

test "grammar rejects: a trailing comma in a param list" {
    // `param-list = [ param *( "," param ) ]` — no trailing comma, unlike
    // struct constructions, match arms, list literals, and union variants.
    var t = try parseError("fn f(a: int32, b: int32,) {}");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected an identifier, found ')'", t.diag.message);
}

test "grammar rejects: an expression statement without its terminator" {
    // parser note 1's failure mode: after an expression at statement level
    // only `;` or `}` may follow.
    var t = try parseError("fn f() -> void { 1 2 }");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected ';' or '}' after expression, found 2", t.diag.message);
}

test "grammar rejects: a list rest without its preceding comma" {
    // `list-pattern-items = pattern *( "," pattern ) [ "," list-rest ] / list-rest`:
    // `..rest` either stands alone or follows a comma — `[a ..r]` is not
    // grammatical.
    var t = try parseError("fn f(xs: list[int32]) -> void { let [a ..r] = xs; }");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected ']', found '..'", t.diag.message);
}

test "grammar rejects: a match with no arms" {
    // `match-arm` is not optional: `"{" match-arm *( "," match-arm ) … `.
    var t = try parseError("const r = match (x) {};");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected a pattern, found '}'", t.diag.message);
}

test "grammar rejects: a trailing comma in a call argument list" {
    // `arg-list = [ expression *( "," expression ) ]` — like `param-list`,
    // no trailing comma (unlike constructions, match arms, list literals,
    // and union variants).
    var t = try parseError("const r = f(1,);");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected an expression, found ')'", t.diag.message);
}

test "grammar rejects: a trailing comma in type parameters" {
    // `type-params = "[" identifier *( "," identifier ) "]"`.
    var t = try parseError("fn f[T,]() {}");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected an identifier, found ']'", t.diag.message);
}

test "grammar rejects: a non-literal import specifier" {
    // Core §2.4: the argument to `import` must be a string literal.
    var t = try parseError("const m = import(42);");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected a string literal in import, found 42", t.diag.message);
}

test "grammar rejects: a chained comparison" {
    // Binding Power Table document (parser algorithm, comparison
    // branch): comparisons are non-associative and non-chaining, so the
    // second `<` is rejected right after the first comparison is built.
    var t = try parseError("fn f() -> void { a < b < c; }");
    defer t.arena.deinit();
    try testing.expectEqualStrings("comparisons do not chain", t.diag.message);
}

test "grammar rejects: a field after the drop declaration" {
    // `struct-def = … *field-decl [drop-decl] "}"` — the drop hook comes
    // after all fields, exactly once.
    var t = try parseError("struct S { drop(s) {} x: int32; }");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected '}', found x", t.diag.message);
}

test "grammar rejects: a second drop declaration" {
    var t = try parseError("struct S { x: int32; drop(a) {} drop(b) {} }");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected '}', found 'drop'", t.diag.message);
}

test "grammar rejects: an empty tuple type" {
    // ABNF `tuple-type` note: `tuple[]` is not a type; the empty tuple
    // value is spelled `()` and has type `void`.
    var t = try parseError("type T = tuple[];");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected a type, found ']'", t.diag.message);
}

test "grammar rejects: an `if` body that is not a block" {
    // `if-expression` requires a `block`; braces are what keeps control-
    // flow bodies unambiguous with struct construction (Core §13.2).
    var t = try parseError("const x = if (y) z;");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected '{', found z", t.diag.message);
}

test "grammar rejects: move of anything but a complete binding name" {
    // `move-expression = %s"move" identifier` — no field, call, or
    // path operands (there is no partial move, Core §13.4).
    var t = try parseError("fn f() -> void { let y = move x.p; }");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected ';', found '.'", t.diag.message);
}

test "grammar rejects: `list` as a binding name" {
    // Core §3: `list` is the language's type keyword, so a source binding
    // for the `list` module must use another name.
    var t = try parseError("const list = import(\"list\");");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected an identifier, found 'list'", t.diag.message);
}

test "grammar rejects: `_` as a function name" {
    // A lone `_` is the wildcard token, not an identifier — it may appear
    // only in patterns.
    var t = try parseError("fn _() {}");
    defer t.arena.deinit();
    try testing.expectEqualStrings("expected a path segment, found '_'", t.diag.message);
}
