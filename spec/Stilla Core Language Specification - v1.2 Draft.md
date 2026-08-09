# Stilla Core Language Specification - v1.2 Draft

> **Companion document:** *Stilla Runtime Specification - v1.2 Draft* — defines module instantiation, evaluation order, runtime destruction, termination, and the embedding-host contract.

## Table of Contents

1. Introduction
   - 1.1 What Stilla is
   - 1.2 Design principles
   - 1.3 Central rules
   - 1.4 Deliberate omissions
   - 1.5 Key terminology
   - 1.6 How this specification is organized
2. Files, Modules, and Namespaces
3. The `builtin` Module
4. Bindings
5. Module Constants
6. Functions
7. Structs
8. Construction
9. Destruction
10. Ownership
11. Algebraic Data Types
12. Generics
13. Control Flow
14. Patterns
15. Member Access and `::`
16. Operators
17. Example Resource Module
18. Formal Static Semantics
19. Lexical and Syntactic Grammar

---

## 1. Introduction

### 1.1 What Stilla is

**Stilla** is a small, statically typed language designed for:

- embedded scripting;
- deterministic execution;
- host integration;
- machine-generated code.

Stilla is engineered around a model that is *visible from the source code*: a program should be easy to parse, easy to statically analyze, and easy to reason about without hidden machinery. Ownership, destruction, and evaluation order are all explicit and deterministic.

This document — the **Core specification** — defines the Stilla v1.2 syntax and the compile-time constraints a conforming compiler must enforce: the type system, ownership checking, generic specialization, and the static module rules. The companion **Runtime specification** defines the execution model: module instantiation, evaluation order, runtime destruction, panic semantics, and the embedding-host contract.

The boundary between the two documents is drawn at the point where a program transitions from a static artifact into a running execution context.

The remainder of this specification states those rules precisely. Sections 2 through 17 explain the model; sections 18 and 19 are the normative requirements (the formal static semantics and the grammar).

### 1.2 Design principles

The design principles below give the character of the language. They fall into five groups.

**Immutability and determinism**

- immutable bindings;
- deterministic destruction on normal control flow;
- deterministic left-to-right evaluation;
- no mutable global state.

**Values are first-class; state is not**

- algebraic data types;
- structs as ordinary nominal record values;
- files as implicit immutable module structs;
- no implicit receiver;
- no inheritance.

**Ownership is explicit and by value**

- explicit borrowing with `borrow`;
- explicit ownership transfer with `move`;
- no tracing garbage collector.

**Functions are monomorphic and capture-free**

- expression-oriented control flow;
- first-class monomorphic non-capturing functions;
- compile-time generic specialization;
- no general associated-function or static-method mechanism.

**Modularity by values, statically resolved**

- modules restricted to module-scope bindings;
- static module resolution through `import`.

### 1.3 Central rules

The language rests on a small number of central rules. They are stated here once and expanded in the sections that follow.

> **Ownership rule.** Borrowing never transfers ownership. Moving always transfers ownership. Destruction is compiler-managed on normal control flow.

> **Construction rule.** Types describe values; ordinary functions construct values. There is no special constructor mechanism, and a named struct may define at most one destruction hook.

> **Generic rule.** Generics are compile-time templates; every runtime function value is monomorphic.

> **Namespace rule.** Runtime member access is ordinary `value.member`; module values are simply restricted to module scope.

> **Termination rule.** Normal control flow destroys deterministically; panic terminates without unwinding and hands cleanup to the embedding host.

The runtime consequences of the termination rule are defined in Runtime §7.

### 1.4 Deliberate omissions

Stilla deliberately omits the following mechanisms; they are not part of the language and are called out throughout the specification:

- a tracing garbage collector — resources are owned and destroyed deterministically (§10, §9);
- an implicit receiver — no method-style `receiver.foo()` sugar (§6.1);
- inheritance — data is expressed with nominal structs and unions (§7, §11);
- mutable global state — all bindings are immutable (§4, §5);
- a general associated-function or static-method mechanism — construction and helpers are ordinary functions (§8);
- exception-style unwinding on panic — a panic terminates the execution context without running `drop` hooks (Runtime §7).

A panic or runtime trap is therefore not normal control flow. It terminates the current Stilla execution context without language-level unwinding; control of cleanup then belongs to the embedding host.

### 1.5 Key terminology

These terms are used throughout the specification.

- **module** — a source file compiled into one implicit immutable struct value (§2).
- **module value / module-resident** — a value of a compiler-generated module type; it may appear only in module-level `const` bindings (§2.3).
- **binding** — a name bound to an immutable value. `let` creates local bindings (§4); `const` creates module constants (§5).
- **duplicable** — a value that may be implicitly copied, such as `int64` or `string` (§10.1).
- **affine** — a value that may be used at most once and must be destroyed exactly once; it is not implicitly copyable (§10.2).
- **owner** — a binding or location that holds an affine value.
- **borrow** — a non-owning, read-only view of a value; it never transfers ownership (§10.6).
- **move** — explicit ownership transfer of a complete local owner (§10.4).
- **drop** — deterministic destruction: a user `drop` hook (§9.1), an explicit `drop` statement (§9.4), or automatic destruction when a scope ends (§9.5).
- **nominal type** — a type defined by a `struct` or `union` declaration; it is distinct from every other type even if shape-identical (§7, §11).
- **monomorphic function** — a function value whose parameter and return types are fully concrete; there are no runtime generic function values (§12).
- **specialization** — compile-time expansion of generic code to concrete types (§12).
- **destruction view** — the special borrowed view of a value seen inside its own `drop` hook (§9.2).

Runtime-side terms (execution context, module storage, teardown, host) are defined in Runtime §1.4.

### 1.6 How this specification is organized

- **§2–§3 — Modules.** Every file is an implicit immutable module value; imports are statically resolved; `builtin` is the single implicitly available module. Module instantiation and the host contract are defined in the Runtime specification.
- **§4–§8 — Bindings and values.** Locals (`let`), module constants (`const`), functions, structs, and construction.
- **§9–§12 — Ownership and types.** Destruction, the ownership model, algebraic data types, and compile-time generics. Destruction timing and order are defined in the Runtime specification.
- **§13–§16 — The expression layer.** Control flow, patterns, operators, and member access. Evaluation order is defined in the Runtime specification.
- **§17 — Example.** A worked resource module.
- **§18–§19 — Normative requirements.** The formal static semantics and the normative grammar.

The companion **Runtime specification** covers: the execution context (§R1), module instantiation (§R2), the host environment (§R3), the required `builtin` interface (§R4), evaluation order (§R5), destruction at runtime (§R6), termination and traps (§R7), and the core runtime model (§R8).

---

# 2. Files, Modules, and Namespaces

## 2.1 Every file defines a module

Every Stilla source file defines one implicit immutable **module struct**.

For example, `calc.st`:

```stilla
const pi: float64 = 3.141592653589793;

fn add(a: int64, b: int64) -> int64 {
    a + b
}

fn square(x: float64) -> float64 {
    x * x
}
```

defines a module containing the runtime members:

```text
pi
add
square
```

A source file is therefore both a compilation unit and the definition of one module instance.

Each resolved module has its own compiler-generated **nominal struct type**. There is no separate runtime `module` type category: layout, immutability, and `.` member access use the same value/member model as structs. The generated type is not directly nameable or constructible in Stilla source.

The compiler additionally marks values of these generated module structs as **module-resident**, which imposes the placement restrictions in §2.3. Ordinary source-defined struct values remain first-class values.

Stilla has no independent runtime `namespace` construct.

## 2.2 Importing a module

Modules are imported with:

```stilla
import("specifier")
```

An `import` expression may appear only as the initializer of a module-level `const` binding.

Example:

```stilla
const calc = import("calc");

fn main() -> void {
    builtin.print(
        builtin.str(calc.add(20, 22))
    );
}
```

`import("calc")` produces a stable reference to the module instance for the current execution context (Runtime §2.4).

Therefore:

```stilla
calc.add
```

is ordinary value-member access on the imported module value. It is not a static function lookup.

## 2.3 Module values are module-scope only

A module-resident value may exist only in a module-level `const` binding (including module-valued members of another module).

Outside module storage, a module-resident value may not be:

- bound by local `let`;
- passed as a function argument;
- returned from a function;
- stored in a struct, union, tuple, list, or box;
- moved or explicitly dropped.

A module-level module binding may be initialized by `import(...)` or by another statically known module binding:

```stilla
const math = import("math");
const public_math = math;
```

The compiler preserves the resolved module identity through such aliases.

This restriction keeps module type lookup static while allowing module member access to use the same runtime `.` semantics as structs.

## 2.4 Import resolution

The argument to `import` must be a string literal.

Examples:

```stilla
import("math")
import("lib/math")
import("./utils")
```

The compiler or runtime resolves the specifier to exactly one of:

1. a Stilla source module;
2. a standard-library module;
3. a host-provided module.

Resolution is implementation-defined, but a specifier must resolve unambiguously before execution.

Import cycles are rejected in Stilla v1.2.

The standard library is specified separately.

The load-time resolution process is defined in Runtime §2.6.

## 2.5 Runtime and type members

Runtime constants and monomorphic functions are runtime members of a module.

Types declared by a module participate only in compile-time type lookup.

For example:

```stilla
const geometry = import("geometry");

let p: geometry.Point =
    geometry.make_point(1.0, 2.0);
```

Here `geometry.make_point` is runtime member access after any required generic specialization, while `geometry.Point` is compile-time qualified type lookup.

Types are not runtime values.

Because module values cannot enter local value flow, every qualified module type path is statically resolvable.

## 2.6 Host-provided modules

An embedding host may register modules before compilation or execution.

A host module must expose a statically known Stilla-compatible interface.

Conceptually:

```stilla
struct Database {
    query: fn(string) -> string;
    execute: fn(string) -> int64;
}
```

This structural illustration does not make module values ordinary first-class struct values. It means their runtime member layout follows the same immutable record/member-access model.

Source modules, standard-library modules, and host modules use the same `.` member-access syntax.

The host-side registration and integration contract is defined in Runtime §3.1.

## 2.7 Nested libraries

A module may expose another imported module as a runtime constant.

`std.st`:

```stilla
const math = import("math");
const text = import("text");
```

Here `math` is the standard-library `math` module (Standard Library
document, §4).

Consumer:

```stilla
const std = import("std");

fn main() -> void {
    let x =
        std.math.sqrt(16.0);

    builtin.print(
        std.text.upper("hello")
    );
}
```

The expression:

```stilla
std.math.sqrt
```

is chained value-member access (§15).

No nested runtime namespace mechanism is required.

---

# 3. The `builtin` Module

Every execution context automatically provides:

```stilla
builtin
```

`builtin` is the only implicitly available module binding.

It behaves as an implementation-provided module and cannot be shadowed.

Core helpers include:

```stilla
builtin.print
builtin.str
builtin.len
builtin.range
builtin.map
builtin.fold
builtin.box
builtin.peek
builtin.unbox
builtin.panic
builtin.assert
builtin.hash
```

There are no implicitly injected functions such as:

```stilla
print(...)
len(...)
```

The explicit forms are always:

```stilla
builtin.print(...)
builtin.len(...)
```

The required signatures and behavioral contracts of these helpers are defined in Runtime §4.

---

# 4. Bindings

This section covers **local** bindings. Module-level constant bindings use `const` (§5). Local `let` bindings never become module members.

Local bindings use:

```stilla
let
```

Example:

```stilla
let x = 10;
let y = x + 20;
```

Bindings are immutable.

This is illegal:

```stilla
x = 30;
```

Shadowing is allowed:

```stilla
let x = 10;
let x = x + 1;
```

The right-hand `x` refers to the previous binding.

Stilla is therefore SSA-friendly, although the source language is not itself an SSA intermediate representation.

---

# 5. Module Constants

Module-level constant bindings use `const` — the module-scope counterpart of the local `let` binding (§4). A `const` is the only binding form that can name a module value (§2.3).

Module-level immutable runtime members use:

```stilla
const
```

Example:

```stilla
const version: int64 = 1;
const calc = import("calc");
```

A module constant:

- is initialized when its module is instantiated (Runtime §2.3);
- cannot be reassigned;
- becomes a runtime member of the module when its value is a runtime value.

A module binding whose value has module type is subject to the module-scope restrictions in §2.3.

Module constant initializers are evaluated strictly in declaration order (Runtime §5).

An initializer may reference:

- earlier module constants;
- imported modules;
- module functions;
- types;
- `builtin`.

It may not reference a later module constant.

An affine non-module constant is owned by the module execution context. It cannot be explicitly moved or explicitly dropped by source code and is destroyed during normal module/context teardown (Runtime §2.5).

---

# 6. Functions

Functions are declared with:

```stilla
fn
```

Example:

```stilla
fn add(
    a: int64,
    b: int64
) -> int64 {
    a + b
}
```

A monomorphic top-level function is a function-valued runtime member of the current module. An unspecialized generic function is a compile-time template (§12).

If the module is imported as:

```stilla
const calc = import("calc");
```

then:

```stilla
calc.add(1, 2)
```

means:

1. obtain the module value;
2. read its `add` member;
3. obtain the function value;
4. call that function.

There is no separate concept of:

- static method;
- associated function;
- namespace function;
- instance method.

## 6.1 No implicit receiver

Stilla never inserts an implicit receiver.

Given:

```stilla
struct Counter {
    value: int64;
    next: fn(borrow Counter) -> int64;
}
```

an ordinary function value stored in `next` must explicitly receive any instance it needs.

For example:

```stilla
let counter =
    Counter{
        value: 10,
        next:
            fn(borrow counter: Counter) -> int64 {
                counter.value + 1
            }
    };

counter.next(counter);
```

There is no transformation from:

```stilla
counter.next()
```

to:

```stilla
counter.next(counter)
```

## 6.2 Non-capturing functions

Functions and lambdas may not capture local bindings from an enclosing function scope.

Illegal:

```stilla
fn example() -> fn(int64) -> int64 {
    let factor = 2;

    fn(x: int64) -> int64 {
        x * factor
    }
}
```

A function may reference:

- its parameters;
- its own local bindings;
- module constants;
- module functions;
- imported modules;
- types;
- `builtin`.

Module members have execution-context lifetime and do not constitute closure capture.

## 6.3 Lambdas

Anonymous functions use the same syntax without a name:

```stilla
let double =
    fn(x: int64) -> int64 {
        x * 2
    };
```

Lambdas obey the same non-capture rule.

## 6.4 Return values

A function returns the value of its body block's final expression.

Example:

```stilla
fn add_one(x: int64) -> int64 {
    x + 1
}
```

A block with no final expression has type:

```stilla
void
```

If a function return type is omitted, it is inferred from the body.

A recursive function must explicitly declare its return type.

---

# 7. Structs

A named struct defines a nominal record type.

```stilla
struct Point {
    x: float64;
    y: float64;
}
```

Construct an instance with:

```stilla
let p =
    Point{
        x: 10.0,
        y: 20.0
    };
```

Members are accessed with `.`:

```stilla
p.x
p.y
```

Function fields are ordinary fields:

```stilla
struct Math {
    add: fn(int64, int64) -> int64;
}
```

Example:

```stilla
let math =
    Math{
        add:
            fn(a: int64, b: int64) -> int64 {
                a + b
            }
    };

math.add(1, 2);
```

A named struct declaration creates a **type only**.

It does not create an implicit value.

There is no canonical struct instance.

There is no `def` declaration.

---

# 8. Construction

## 8.1 Raw struct construction

Every named struct may be directly constructed with a struct literal.

```stilla
Point{
    x: 1.0,
    y: 2.0
}
```

All fields must be supplied exactly once.

Unknown fields are compile-time errors.

Duplicate fields are compile-time errors.

## 8.2 Construction is ordinary computation

Stilla has no special `gen` declaration.

Custom construction is expressed with ordinary functions.

Example:

```stilla
const os = import("os");

struct File {
    fd: int64;
    path: string;

    drop(file) {
        os.close(file.fd);
    }
}

fn open_file(path: string) -> File {
    File{
        fd: os.open(path),
        path: path
    }
}
```

Usage:

```stilla
let file = open_file("data.txt");
```

A module may naturally provide multiple construction functions:

```stilla
fn open(path: string) -> File {
    ...
}

fn create(path: string) -> File {
    ...
}

fn from_fd(fd: int64) -> File {
    ...
}
```

If these functions are declared in `file.st`:

```stilla
const file = import("file");

let a = file.open("a.txt");
let b = file.create("b.txt");
```

No language-level constructor namespace is required.

## 8.3 No constructor invariants in v1.2

Raw struct construction remains available even if a type defines `drop`.

Therefore Stilla v1.2 does not provide language-enforced private constructor invariants.

Libraries that require stronger abstraction must rely on module conventions or host-provided opaque interfaces.

Visibility control and opaque source-defined structs are outside the scope of Stilla v1.2.

---

# 9. Destruction

This section states the compile-time constraints of destruction: how a `drop` hook is declared, what code may do inside it, and what an explicit `drop` may target. The runtime sequence of destruction — ordering, timing, and teardown — is defined in Runtime §6.

## 9.1 `drop` lifecycle declaration

A named struct may define one destruction hook:

```stilla
struct File {
    fd: int64;
    path: string;

    drop(file) {
        os.close(file.fd);
    }
}
```

The identifier inside:

```stilla
drop(file)
```

is an explicit local name for the value being destroyed.

It may be named arbitrarily:

```stilla
drop(resource) {
    ...
}
```

`self` is not a keyword.

The destruction hook is not:

- a field;
- a function value;
- an associated function;
- a callable method.

It exists only as part of the compiler-managed destruction process.

It cannot be called directly.

## 9.2 Destruction view

The argument visible inside a `drop` hook is a special borrowed **destruction view** of the complete object.

A destruction view may:

- read duplicable fields;
- borrow affine fields;
- apply `builtin.peek` to a boxed field;
- access ordinary members;
- call functions whose relevant parameters are declared `borrow` (§10.6);

A destruction view may not:

- be moved;
- be explicitly dropped;
- escape the hook;
- be returned;
- be stored into an owning binding;
- transfer ownership of one of its fields.

Partial movement from a destruction view is forbidden.

## 9.3 Destruction order

The order in which a struct value is destroyed at runtime is defined in Runtime §6.2: the user `drop` hook runs first, then affine fields are destroyed in reverse declaration order, then the complete value is marked destroyed.

## 9.4 Explicit destruction

An owned local binding may be destroyed early with:

```stilla
drop file;
```

After:

```stilla
drop file;
```

the binding is no longer usable.

Example:

```stilla
let file = open_file("data.txt");

inspect(file);

drop file;
```

Explicit `drop` applies only to an owning **affine** local binding.

It cannot directly target:

- a field;
- an indexed element;
- a module constant;
- a `borrow` parameter;
- a module value.

This restriction avoids partial-destruction state.

The destruction sequence performed by an explicit `drop` at runtime is defined in Runtime §6.5.

## 9.5 Automatic destruction

During normal control flow, an affine local owner that has not been moved or explicitly dropped is automatically destroyed when its scope ends.

The destruction order — reverse creation order — is defined in Runtime §6.1.

## 9.6 Structural destruction

Values containing affine components are destroyed structurally.

The precise ordering for each container form — struct fields, tuple elements, list elements, union payloads, `box[T]`, and module-owned affine constants — and the rule that only the active union variant is destroyed, are defined in Runtime §6.3.

---

# 10. Ownership

Stilla classifies owned runtime values as:

```text
Duplicable
Affine
```

In addition, the type checker tracks non-owning **borrowed views** of values.

A borrow is never an owner and never participates in destruction.

This section states the static (compile-time) ownership model. The timing of runtime destruction — scope exit, full-expression temporaries, and module teardown — is defined in Runtime §6.

## 10.1 Duplicable values

Typical duplicable values include:

```text
int64
float64
bool
string
void
fn(...)
```

A duplicable value may be copied implicitly.

Immutable strings may use reference-counted sharing.

All first-class function values are monomorphic (§12).

## 10.2 Affine values

A value is affine if:

- its named struct type defines `drop`; or
- one of its owned components is affine.

Affine values cannot be implicitly copied.

An affine owner may be:

- borrowed any number of times;
- moved at most once;
- destroyed at most once.

Use after move or destruction is a compile-time error.

## 10.3 Composite ownership

Ownership classification is structural.

For example, `tuple[A, B]` is affine if either `A` or `B` is affine.

A union is affine if any variant payload can contain an affine value.

For containers:

```text
list[T]
box[T]
```

the container is duplicable if `T` is duplicable and affine if `T` is affine.

An implementation may use reference-counted sharing for duplicable `list[T]` and `box[T]`.

An affine list or box has unique source-language ownership.

## 10.4 Ownership transfer with `move`

`move` always means ownership transfer.

Ownership transfer from an existing local owner is explicit:

```stilla
let a = open_file("a.txt");
let b = move a;
```

Afterward `a` is invalid.

`move` transfers the complete ownership represented by a local binding.

Stilla v1.2 does not support partial move from:

- struct fields;
- tuple elements;
- list elements;
- indexed expressions.

Syntactically, `move` names a complete local binding.

To extract owned components, the complete owner must first be consumed by destructuring (§14.6).

## 10.5 Fresh affine values

A freshly produced affine value already carries fresh ownership and has no existing local owner to invalidate.

Therefore:

```stilla
consume(open_file("data.txt"));
```

is valid when `consume` takes ownership.

By contrast:

```stilla
let file = open_file("data.txt");
consume(move file);
```

requires `move`.

## 10.6 Parameter modes

Function parameters have three modes.

### Plain parameters

```stilla
fn add_one(x: int64) -> int64 {
    x + 1
}
```

A plain parameter accepts only a duplicable argument type. The argument is passed by ordinary value semantics and may be copied.

Passing an affine value to a plain parameter is a compile-time error.

### Borrow parameters

```stilla
fn inspect(borrow file: File) -> void {
    builtin.print(file.path);
}
```

A `borrow` parameter receives a non-owning view of its argument.

Call syntax does not use an additional keyword:

```stilla
inspect(file);
inspect(file);
```

The caller remains the owner. A `borrow` parameter may receive an owned value or another compatible borrowed view.

Inside the callee, a borrowed affine value may be read, matched non-consumingly, have members read, and be passed to another compatible `borrow` parameter.

It may not be moved, explicitly dropped, returned as an owned value, or stored into an owning location.

### Move parameters

```stilla
fn consume(move file: File) -> void {
    builtin.print(file.path);
}
```

A `move` parameter is an owner inside the callee.

An existing affine local owner must be transferred explicitly:

```stilla
consume(move file);
```

A fresh affine expression transfers implicitly:

```stilla
consume(open_file("data.txt"));
```

Calling an ownership-taking parameter with an existing affine owner without `move` is a compile-time error.

For duplicable types, `move` is semantically equivalent to an ordinary copy: it has no observable ownership effect, does not invalidate the source binding, and may be omitted.

Function types preserve parameter mode:

```stilla
fn(borrow File) -> void
fn(move File) -> File
fn(int64) -> int64
```

## 10.7 Borrow lifetime rule

A borrow never outlives the operation or lexical parameter scope that created it.

A value seen through a borrow may not:

- be moved;
- be explicitly dropped;
- be returned as an owned value;
- be stored into an owning field;
- be stored into an owning container;
- be stored into a module constant;
- otherwise escape its borrow lifetime.

Stilla v1.2 does not provide general user-visible lifetime parameters.

Borrow lifetimes are intentionally restricted so they can be checked lexically.

User-defined functions may not return a borrowed affine value in v1.2.

## 10.8 Box borrowing and unboxing

Box access uses two distinct operations.

Borrow without consuming the box:

```stilla
builtin.peek(boxed)
```

Ownership transfer out of the box:

```stilla
builtin.unbox(move boxed)
```

`builtin.peek(boxed)` creates a transient borrowed view of the contained `T`.

For duplicable `T`, the value may be copied normally.

For affine `T`, the borrowed result:

- may have members read;
- may be matched non-consumingly;
- may be passed directly to a `borrow` parameter;
- may not be moved, dropped, stored as an owner, or returned as an owned value.

The transient borrow lasts until the end of the enclosing full expression.

This permits read-only recursive traversal:

```stilla
fn contains(borrow tree: Tree, v: int64) -> bool {
    match (tree) {
        Tree::Empty => false,
        Tree::Node(left, x, right) =>
            if (v == x) {
                true
            } else if (v < x) {
                contains(builtin.peek(left), v)
            } else {
                contains(builtin.peek(right), v)
            }
    }
}
```

`builtin.unbox(move boxed)` consumes the complete box and returns ownership of the contained value.

Partial movement through a borrowed box is forbidden.

## 10.9 Affine temporaries

When an affine temporary is destroyed at runtime — at the end of the containing full expression, in reverse creation order, unless interrupted by panic — is defined in Runtime §6.4.

---

# 11. Algebraic Data Types

## 11.1 Named unions

Tagged unions are nominal types declared directly with `union`:

```stilla
union Option[T] {
    Some(T),
    None
}
```

Construction:

```stilla
Option[int64]::Some(42)
Option[int64]::None
```

When type arguments are inferable from context, they may be omitted:

```stilla
let x: Option[int64] =
    Option::Some(42);
```

Multiple payload values are allowed:

```stilla
union Tree[T] {
    Empty,
    Node(
        box[Tree[T]],
        T,
        box[Tree[T]]
    )
}
```

`::Ident` on a type path is reserved for union variant construction and matching.

It is not a general associated-member operator.

This is invalid unless `open` is a union variant:

```stilla
File::open(...)
```

Construction functions are ordinary module or local functions instead.

A `union` declaration creates a nominal sum type. Two separately declared unions are distinct even when their variants have identical shapes.

## 11.2 Type aliases

`type` defines a transparent alias rather than a new nominal type:

```stilla
type UserId = int64;
type MaybeInt = Option[int64];
```

After alias expansion, the alias and aliased type are the same type for static semantics.

Generic aliases are compile-time templates:

```stilla
type PairList[T] = list[tuple[T, T]];
```

Stilla v1.2 has no anonymous struct or anonymous union type syntax.

## 11.3 Recursive types

Recursive inline storage is forbidden.

Every recursive storage cycle must pass through indirection such as `box[T]` or `list[T]`.

## 11.4 Tuple

Tuple type:

```stilla
tuple[int64, string, bool]
```

Literal:

```stilla
(42, "hello", true)
```

The empty tuple `()` is the unique `void` value.

## 11.5 List

List type:

```stilla
list[int64]
```

Literal:

```stilla
[1, 2, 3]
```

Lists are immutable.

Indexing does not mutate a list.

An indexed affine element is borrowed and cannot be independently moved.

`list[T]` is the language's abstract sequence type. Concrete dense sequences such as `array[T]` are standard-library types, not keywords.

---

# 12. Generics

Generics in Stilla v1.2 are compile-time syntax sugar for specialization (monomorphization).

They are expanded to concrete types and monomorphic functions before runtime semantics. They are not runtime polymorphic values.

## 12.1 Generic declarations

Generic structs:

```stilla
struct Pair[A, B] {
    first: A;
    second: B;
}
```

Generic unions:

```stilla
union Option[T] {
    Some(T),
    None
}
```

Generic functions:

```stilla
fn identity[T](move value: T) -> T {
    move value
}
```

Generic aliases:

```stilla
type PairList[T] = list[tuple[T, T]];
```

Each used specialization denotes a concrete type or a concrete monomorphic function.

## 12.2 Inferred specialization

Type arguments are normally inferred from the use site:

```stilla
identity(42)
```

The compiler first infers a concrete specialization and then type-checks the resulting monomorphic call.

Conceptually:

```text
identity(42)
    ↓ infer T = int64
identity::[int64](42)
    ↓ compile-time expansion
<concrete fn(int64) -> int64>(42)
```

No generic dispatch occurs at runtime.

## 12.3 Explicit specialization

Explicit function specialization uses:

```stilla
identity::[int64](42)
```

The syntax `::[...]` is compile-time specialization syntax. It does not perform a runtime postfix operation.

Type specialization uses:

```stilla
Pair[int64, string]
Option[int64]
```

## 12.4 Generic functions are not first-class before specialization

An unspecialized generic function is a compile-time entity, not a runtime function value.

Therefore:

```stilla
let f = identity;
```

is invalid.

This is valid:

```stilla
let f = identity::[int64];
```

and `f` has the monomorphic type:

```stilla
fn(move int64) -> int64
```

For a duplicable `int64`, the `move` mode has no observable ownership effect, but it remains part of the function type.

Generic functions stored in modules follow the same rule: `module.generic_name` may participate in compile-time call inference or explicit specialization, but only a concrete specialization becomes a runtime function value.

## 12.5 No generic function values

Function types are always monomorphic.

The following is not a Stilla v1.2 type:

```text
fn[T](T) -> T
```

Generic lambdas are also not supported in v1.2.

This restriction keeps runtime function representation independent of the generic system.

---

# 13. Control Flow

## 13.1 Blocks

A block is an expression.

```stilla
{
    let x = 10;
    x + 1
}
```

has value:

```text
11
```

A block without a final expression has type:

```text
void
```

Example:

```stilla
{
    builtin.print("hello");
}
```

## 13.2 `if`

`if` is an expression.

Its condition is parenthesized:

```stilla
let sign =
    if (value >= 0) {
        1
    } else {
        -1
    };
```

Parentheses are mandatory.

This removes ambiguity between control-flow bodies and struct construction.

Both branches must have the same type, except that `never` may coerce to any type.

Without `else`, the expression must have type `void`.

Example:

```stilla
if (ready) {
    builtin.print("ready");
};
```

## 13.3 `match`

`match` is an expression.

The scrutinee is parenthesized:

```stilla
let message =
    match (result) {
        Result::Ok(value) =>
            "ok: " + builtin.str(value),

        Result::Err(error) =>
            "error: " + error
    };
```

Union matching must be exhaustive.

Supported patterns include:

```text
_
x
42
(a, b)
Point{ x, y }
Option::Some(x)
[]
[head, ..tail]
```

## 13.4 Borrowing and consuming matches

Matching an affine owner normally borrows it:

```stilla
match (value) {
    ...
}
```

Affine pattern bindings produced by such a match are borrowed for the lifetime of the selected match arm.

They may be read or passed to `borrow` parameters, but they are not owners.

To consume the complete owner:

```stilla
match (move value) {
    ...
}
```

the complete value is transferred into the match operation.

Affine payload bindings then become owners within the selected arm.

This never performs a partial move from the original binding: the original binding is invalidated as a whole.

## 13.5 `for`

`for` uses an explicitly delimited header:

```stilla
for (item in values) {
    builtin.print(
        builtin.str(item)
    );
}
```

`for` has type `void`.

It does not provide loop-carried mutable state.

The iterable expression is evaluated exactly once before iteration begins (Runtime §5).

Iteration proceeds in the sequence's defined forward order. For `list[T]`, this is increasing index order (Runtime §5).

Iteration over an affine collection without `move` borrows its elements:

```stilla
for (item in values) {
    inspect(item);
}
```

A consuming iteration uses:

```stilla
for (item in move values) {
    consume(move item);
}
```

where the collection is consumed as a whole and each affine element binding becomes an owner as it is yielded.

The `for` pattern must be irrefutable for the element type (§14).

Use `builtin.fold` for accumulation.

Example:

```stilla
let total =
    builtin.fold(
        builtin.range(1, 10),
        0,
        fn(move acc: int64, move x: int64) -> int64 {
            acc + x
        }
    );
```

For duplicable instantiated types such as `int64`, `move` has no observable ownership effect.

---

# 14. Patterns

Patterns are used by `let`, `match`, and `for`.

`match` accepts the full pattern language.

`let` and `for` accept only **irrefutable patterns** so that binding never introduces an implicit runtime failure path.

Irrefutable forms are:

- `_`;
- identifier patterns;
- tuple patterns composed only of irrefutable patterns;
- struct patterns whose nested field patterns are irrefutable and whose struct type is statically the scrutinee type.

Literal, union-variant, and list-shape patterns are refutable and therefore may appear only in `match`.

Supported pattern forms are:

```text
_
identifier
literal
tuple pattern
struct pattern
union variant pattern
list pattern
```

## 14.1 Identifier pattern

```stilla
x
```

binds the matched value.

Its ownership mode depends on the operation producing the binding.

## 14.2 Tuple pattern

```stilla
(a, b)
```

## 14.3 Struct pattern

```stilla
Point{
    x,
    y
}
```

Field renaming:

```stilla
Point{
    x: px,
    y: py
}
```

## 14.4 Union pattern

```stilla
Option::Some(value)
Option::None
```

Generic type arguments may be written when required:

```stilla
Option[int64]::Some(value)
```

## 14.5 List pattern

Examples:

```stilla
[]
[a]
[head, ..tail]
[first, second, ..rest]
```

The rest binding receives the remaining list.

## 14.6 Ownership and destructuring

Destructuring an affine rvalue transfers ownership into affine pattern bindings.

Example:

```stilla
let pair =
    Pair{
        first: open_file("a"),
        second: open_file("b")
    };

let Pair{
    first,
    second
} = move pair;
```

After the destructuring:

```stilla
pair
```

is invalid.

`first` and `second` are independent owners.

This is the supported way to decompose affine aggregate ownership **when the aggregate type does not define its own `drop` hook**.

A struct that defines `drop` may be destructured only through a borrowing pattern. Consuming destructuring of such a struct is a compile-time error, because moving out its fields would conflict with the struct's own destruction lifecycle.

Direct partial movement such as:

```stilla
move pair.first
```

is illegal.

---

# 15. Member Access and `::`

## 15.1 `.`

`.` performs ordinary value-member access.

Examples:

```stilla
point.x
math.sqrt
std.math.sin
engine.audio.play
```

At runtime these all reduce to member access on values.

## 15.2 `::Variant`

A type-qualified identifier after `::` denotes a union variant.

Examples:

```stilla
Option::None
Option::Some(42)
Result[string, int64]::Ok("done")
```

It is not general type-member lookup.

## 15.3 `::[...]`

`::[...]` requests explicit compile-time specialization of a generic function name or generic function member.

Example:

```stilla
identity::[int64](42)
```

After specialization, the result is an ordinary monomorphic function value.

These uses are distinct:

```text
Type[T]::Variant     union variant syntax
function::[T]        compile-time generic specialization
```

Stilla provides no syntax for arbitrary:

```text
Type::function
```

`::[...]` is not a runtime member lookup and does not make unspecialized generic functions first-class.

---

# 16. Operators

Arithmetic:

```text
+  -  *  /  %
```

Comparison:

```text
==  !=  <  <=  >  >=
```

Boolean:

```text
&&  ||  !
```

Explicit conversion:

```stilla
value as float64
```

String concatenation is only:

```text
string + string
```

There is no implicit conversion such as:

```stilla
"value = " + 42
```

Use:

```stilla
"value = " + builtin.str(42)
```

instead.

## 16.1 Operator precedence

From lowest to highest:

1. `||`
2. `&&`
3. comparisons
4. `+ -`
5. `* / %`
6. unary `- ! move`
7. `as`
8. postfix operations

Comparison operators do not chain.

This is invalid:

```stilla
a < b < c
```

Write:

```stilla
a < b && b < c
```

## 16.2 Evaluation order

Stilla uses a single deterministic evaluation-order rule; it is defined in Runtime §5:

> **Unless a construct explicitly states otherwise, subexpressions are evaluated exactly once from left to right in source order.**

## 16.3 Core operator typing and numeric conversion

Core arithmetic is defined as follows:

- `int64 + - * / % int64 -> int64`;
- `float64 + - * / float64 -> float64`;
- `string + string -> string`;
- unary `-` accepts `int64` or `float64`;
- `!`, `&&`, and `||` accept `bool`;
- `< <= > >=` accept operands of the same numeric type;
- `== !=` are required for `int64`, `float64`, `bool`, and `string`.

The Stilla v1.2 core does not define equality for functions, structs, unions, tuples, lists, boxes, or modules. Libraries may provide explicit equality helpers.

Core `as` conversions are:

```text
int64 as float64
float64 as int64
```

No other core conversion is implied by `as`.

The runtime behavior of these operations — IEEE 754 representation and arithmetic, floating equality, overflow and division traps, and invalid-cast traps — is defined in Runtime §7.2.

---

# 17. Example Resource Module

`file.st`:

```stilla
const os = import("os");

struct File {
    fd: int64;
    path: string;

    drop(file) {
        os.close(file.fd);
    }
}

fn open(path: string) -> File {
    File{
        fd: os.open(path),
        path: path
    }
}

fn create(path: string) -> File {
    File{
        fd: os.create(path),
        path: path
    }
}

fn inspect(borrow file: File) -> void {
    builtin.print(file.path);
}
```

Consumer:

```stilla
const file = import("file");

fn main() -> void {
    let handle =
        file.open("data.txt");

    file.inspect(handle);

    drop handle;
}
```

There is no:

```text
File::gen
File::open
File::drop(...)
def File
```

The model is instead:

```text
File{...}       raw value construction
file.open(...)  ordinary module function
drop handle     ownership operation
drop(file)      lifecycle hook
```

---

# 18. Formal Static Semantics

A conforming implementation must enforce the following rules.

## Binding

A local binding is immutable after creation.

## Shadowing

A new local binding may shadow an existing binding.

## Typing

Function arguments and return values must match exactly unless the source type is `never` or a transparent `type` alias expands to the required type.

## Conversion

No implicit numeric or string conversions exist.

## Closures

A function or lambda may not reference local bindings belonging to an enclosing function scope.

## Match

A match over a union must be exhaustive.

A non-consuming match of an affine value borrows the scrutinee and produces borrowed affine bindings.

A `match (move owner)` consumes the complete owner and may produce owning payload bindings, except that a struct defining its own `drop` hook cannot be consumingly destructured into fields.

## Patterns

`let` and `for` require irrefutable patterns.

Refutable patterns are accepted only by `match` in Stilla v1.2.

## Ownership

An affine owner may be borrowed any number of times, moved at most once, and destroyed at most once.

Use after move or destruction is a compile-time error.

## Whole-owner rule

Explicit ownership movement operates on complete local owners.

Direct partial movement from fields or indexed elements is forbidden.

Consuming destructuring of a struct that defines its own `drop` hook is forbidden.

## Borrowing

`borrow` never transfers ownership.

A borrowed affine value cannot be moved, dropped, returned as owned, or stored into an owning location.

Borrow lifetimes are lexically bounded; Stilla v1.2 has no user-visible lifetime parameters and no user-defined borrowed affine return values.

## Parameters

A plain parameter accepts only duplicable argument types.

A `borrow` parameter receives a non-owning view and leaves the caller's ownership unchanged.

A `move` parameter receives ownership.

Passing an existing affine local owner to a `move` parameter requires `move owner` at the call site.

A fresh affine value may transfer directly without an explicit `move` token.

## Destruction

Every live affine local owner is destroyed when its scope ends during normal control flow unless it has already been moved or explicitly dropped.

Affine temporaries are destroyed at the end of their full expression in reverse creation order during normal control flow (Runtime §6.4).

## User drop hook

A struct may define at most one `drop` lifecycle declaration.

The hook cannot be called directly.

Its destruction-view argument cannot be moved, dropped, returned, or used to transfer field ownership.

## Structural destruction

After a struct's user hook completes normally, affine fields are destroyed in reverse declaration order (Runtime §6.2).

## Panic and traps

Panic and runtime traps terminate the current Stilla execution context without unwinding (Runtime §7).

Stilla does not execute pending local, temporary, field, or module destruction as a consequence of such termination.

Host cleanup after termination is outside Stilla source semantics.

## Evaluation order

Unless explicitly stated otherwise, subexpressions are evaluated exactly once from left to right (Runtime §5).

`&&` and `||` short-circuit (Runtime §5).

## Recursion

Recursive value types must contain indirection on every recursive storage cycle.

## Modules

Each resolved module is instantiated at most once per execution context (Runtime §2.1).

Each module has a compiler-generated nominal struct type with ordinary immutable record/member semantics; there is no separate runtime module type category.

Values of these generated module structs are module-resident and may appear only in module-level `const` bindings.

## Imports

Import specifiers must be statically known string literals.

`import(...)` may appear only as a module-level `const` initializer.

## Constructors

Stilla has no special constructor declaration.

Construction helpers are ordinary functions.

## Struct values

A named struct declaration creates a nominal type and does not automatically create a value.

## Union values

A `union` declaration creates a nominal sum type.

`Type::Variant` is reserved for union variant syntax.

## Type aliases

A `type` declaration is transparent and does not create a new nominal type.

## Associated functions

Named structs do not provide an associated-function namespace.

## Generics

Generic declarations are compile-time templates.

Every runtime function value is monomorphic.

An unspecialized generic function is not a runtime value.

Inferred or explicit specialization must produce a concrete function before runtime use.

`value::[Types]` is compile-time specialization syntax, not runtime dispatch.

---

# 19. Lexical and Syntactic Grammar

## 19.1 Grammar notation

The normative grammar uses **ABNF** as defined by RFC 5234.

Case-sensitive literal strings use RFC 7405 `%s"..."` notation.

Stilla source is case-sensitive.

The syntactic ABNF is defined over lexical tokens.

Whitespace and comments separate tokens and are otherwise discarded before syntactic parsing.

## 19.2 Lexical grammar

```abnf
identifier      = letter *( letter / digit / "_" )

letter          = %x41-5A
                / %x61-7A
                / "_"

digit           = %x30-39

integer         = 1*digit

float           = 1*digit "." 1*digit

string          = DQUOTE *( string-char / escape ) DQUOTE

escape          = "\\" ( DQUOTE
                      / "\\"
                      / "n"
                      / "r"
                      / "t" )

string-char     = <any Unicode scalar value except
                   DQUOTE, "\\", or control characters>

bool-literal    = %s"true"
                / %s"false"

void-literal    = "(" ")"
```

The leading `-` is an operator and is not part of an integer or float token.

Identifiers are ASCII in Stilla v1.2. String contents may contain Unicode.

## 19.3 Comments

Line comments begin with `//` and continue to end of line.

Block comments begin with `/*` and end with `*/`.

Block comments may nest. Nested comment recognition is performed lexically.

## 19.4 Reserved words

The following identifiers are reserved:

```text
as
bool
borrow
box
builtin
const
drop
else
false
float64
fn
for
if
import
in
int64
let
list
match
move
never
string
struct
true
tuple
type
union
void
```

The removed historical words `def`, `gen`, and `delete` have no special syntactic meaning.

The collection type names `array` and `hashmap` are not reserved words.

## 19.5 Program structure

```abnf
program =
    *module-item

module-item =
      const-def
    / func-def
    / type-def
    / struct-def
    / union-def
```

## 19.6 Module constants

```abnf
const-def =
    %s"const"
    identifier
    [ ":" type ]
    "="
    expression
    ";"
```

Static semantics restrict module-resident generated struct values to module-level `const` bindings and restrict `import-expression` to this initializer position (§2.2).

## 19.7 Functions

```abnf
func-def =
    %s"fn"
    identifier
    [ type-params ]
    "(" param-list ")"
    [ "->" type ]
    block

lambda =
    %s"fn"
    "(" param-list ")"
    [ "->" type ]
    block

param-list =
    [ param *( "," param ) ]

param =
    [ %s"borrow" / %s"move" ]
    identifier
    ":"
    type

function-type =
    %s"fn"
    "(" [ function-param-type
          *( "," function-param-type ) ] ")"
    "->"
    type

function-param-type =
    [ %s"borrow" / %s"move" ]
    type
```

A plain parameter accepts only duplicable types by static semantics.

A `borrow` parameter is non-owning.

A `move` parameter is owning.

Function types are monomorphic. Generic parameters are permitted on named function declarations but not on lambdas or function types.

## 19.8 Generic parameters

```abnf
type-params =
    "["
    identifier
    *( "," identifier )
    "]"

type-args =
    "["
    type
    *( "," type )
    "]"
```

Generic syntax is compile-time syntax (§12).

## 19.9 Types

```abnf
type =
      primitive-type
    / named-type
    / list-type
    / box-type
    / tuple-type
    / function-type

primitive-type =
      %s"int64"
    / %s"float64"
    / %s"bool"
    / %s"string"
    / %s"void"
    / %s"never"

named-type =
    type-path
    [ type-args ]

type-path =
    identifier
    *( "." identifier )

list-type =
    %s"list"
    "["
    type
    "]"

box-type =
    %s"box"
    "["
    type
    "]"

tuple-type =
    %s"tuple"
    "["
    [ type *( "," type ) ]
    "]"
```

Stilla v1.2 has no anonymous struct or anonymous union types.

## 19.10 Type aliases

```abnf
type-def =
    %s"type"
    identifier
    [ type-params ]
    "="
    type
    ";"
```

A type alias is transparent.

## 19.11 Named structs

```abnf
struct-def =
    %s"struct"
    identifier
    [ type-params ]
    "{"
    *field-decl
    [ drop-decl ]
    "}"

field-decl =
    identifier
    ":"
    type
    ";"

drop-decl =
    %s"drop"
    "(" identifier ")"
    block
```

A `drop-decl`, when present, must appear after all fields.

A struct may contain at most one `drop-decl`.

## 19.12 Named unions

```abnf
union-def =
    %s"union"
    identifier
    [ type-params ]
    "{"
    [ variant-decl *( "," variant-decl ) [ "," ] ]
    "}"

variant-decl =
    identifier
    [ "(" type *( "," type ) ")" ]
```

A union declaration creates a nominal sum type.

## 19.13 Blocks

```abnf
block =
    "{"
    *statement
    [ expression ]
    "}"
```

A final expression is distinguished from an expression statement by the absence of a trailing semicolon.

## 19.14 Statements

```abnf
statement =
      let-stmt
    / drop-stmt
    / for-stmt
    / expr-stmt
    / empty-stmt

let-stmt =
    %s"let"
    pattern
    [ ":" type ]
    "="
    expression
    ";"

drop-stmt =
    %s"drop"
    identifier
    ";"

for-stmt =
    %s"for"
    "("
    pattern
    %s"in"
    expression
    ")"
    block

expr-stmt =
    expression
    ";"

empty-stmt =
    ";"
```

Static semantics require the `let` and `for` patterns to be irrefutable.

## 19.15 Expressions

```abnf
expression =
    logic-or

logic-or =
    logic-and
    *( "||" logic-and )

logic-and =
    comparison
    *( "&&" comparison )

comparison =
    addition
    [ comparison-op addition ]

comparison-op =
      "=="
    / "!="
    / "<"
    / "<="
    / ">"
    / ">="

addition =
    multiply
    *( add-op multiply )

add-op =
      "+"
    / "-"

multiply =
    unary
    *( multiply-op unary )

multiply-op =
      "*"
    / "/"
    / "%"

unary =
      "-" unary
    / "!" unary
    / move-expression
    / cast

move-expression =
    %s"move"
    identifier

cast =
    postfix
    *( %s"as" type )
```

`move` syntactically names a complete local binding. There is no general `borrow` expression; borrowing is introduced by borrow parameters and defined borrowing operations.

## 19.16 Postfix expressions

```abnf
postfix =
    primary
    *postfix-suffix

postfix-suffix =
      member-suffix
    / index-suffix
    / call-suffix
    / specialization-suffix

member-suffix =
    "."
    identifier

index-suffix =
    "["
    expression
    "]"

call-suffix =
    "("
    arg-list
    ")"

specialization-suffix =
    "::"
    type-args

arg-list =
    [ expression *( "," expression ) ]
```

`specialization-suffix` is accepted syntactically as postfix syntax but is eliminated during compile-time generic specialization. It cannot survive into runtime evaluation.

## 19.17 Primary expressions

```abnf
primary =
      literal
    / struct-construct
    / variant-expression
    / tuple-literal
    / list-literal
    / lambda
    / if-expression
    / match-expression
    / import-expression
    / block
    / paren-expression
    / identifier

paren-expression =
    "("
    expression
    ")"
```

When an identifier path is followed by a struct-construction brace, it is parsed as `struct-construct`.

When a type path is followed by optional type arguments and `:: identifier`, it is parsed as a union variant expression.

Otherwise an identifier begins an ordinary value expression.

## 19.18 Imports

```abnf
import-expression =
    %s"import"
    "("
    string
    ")"
```

The string must be a literal token.

Static semantics permit this production only as the initializer of a module-level `const` binding.

## 19.19 Struct construction

```abnf
struct-construct =
    type-path
    [ type-args ]
    "{"
    [ struct-field-init
      *( "," struct-field-init )
      [ "," ] ]
    "}"

struct-field-init =
    identifier
    ":"
    expression
```

All fields must be supplied exactly once.

Field initializers are evaluated in written source order. Field order does not affect the struct's destruction order (Runtime §6.2).

## 19.20 Union variant expressions

```abnf
variant-expression =
    type-path
    [ type-args ]
    "::"
    identifier
    [ "(" arg-list ")" ]
```

Static semantics require the type path to denote a named union type and the identifier to name one of its variants.

This production does not define arbitrary associated functions.

## 19.21 Tuple literals

```abnf
tuple-literal =
    "("
    expression
    ","
    [ expression *( "," expression ) ]
    ")"
```

Examples:

```stilla
(1,)
(1, 2)
(1, 2, 3)
```

The empty form `()` is handled by `void-literal`.

## 19.22 List literals

```abnf
list-literal =
    "["
    [ expression *( "," expression ) [ "," ] ]
    "]"
```

## 19.23 `if`

```abnf
if-expression =
    %s"if"
    "("
    expression
    ")"
    block
    [ %s"else"
      ( block / if-expression ) ]
```

## 19.24 `match`

```abnf
match-expression =
    %s"match"
    "("
    expression
    ")"
    "{"
    match-arm
    *( "," match-arm )
    [ "," ]
    "}"

match-arm =
    pattern
    "=>"
    expression
```

Because a block is itself an expression, a match arm may use a block without a separate grammar production.

## 19.25 Patterns

```abnf
pattern =
      wildcard-pattern
    / literal-pattern
    / tuple-pattern
    / struct-pattern
    / union-pattern
    / list-pattern
    / identifier-pattern

wildcard-pattern =
    "_"

identifier-pattern =
    identifier
```

Static semantics divide these forms into irrefutable and refutable patterns (§14).

## 19.26 Literal patterns

```abnf
literal-pattern =
      integer
    / "-" integer
    / float
    / "-" float
    / string
    / bool-literal
    / void-literal
```

## 19.27 Tuple patterns

```abnf
tuple-pattern =
    "("
    pattern
    ","
    [ pattern *( "," pattern ) ]
    ")"
```

## 19.28 Struct patterns

```abnf
struct-pattern =
    type-path
    [ type-args ]
    "{"
    [ field-pattern
      *( "," field-pattern )
      [ "," ] ]
    "}"

field-pattern =
    identifier
    [ ":" pattern ]
```

## 19.29 Union patterns

```abnf
union-pattern =
    type-path
    [ type-args ]
    "::"
    identifier
    [ "(" pattern *( "," pattern ) ")" ]
```

## 19.30 List patterns

```abnf
list-pattern =
    "["
    [ list-pattern-items ]
    "]"

list-pattern-items =
      pattern
      *( "," pattern )
      [ "," list-rest ]
    / list-rest

list-rest =
    ".."
    identifier
```

## 19.31 Literals

```abnf
literal =
      integer
    / float
    / string
    / bool-literal
    / void-literal
```
