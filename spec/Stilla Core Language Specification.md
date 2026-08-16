# Stilla Core Language Specification

> **Version:** v1.3 Draft
>
> **Companion document:** *Stilla Runtime Specification* — defines module instantiation, evaluation order, runtime destruction, termination, and the embedding-host contract.

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

---

## 1. Introduction

### 1.1 What Stilla is

**Stilla** is a small, statically typed language designed for:

- embedded scripting;
- deterministic execution;
- host integration;
- machine-generated code.

Stilla is engineered around a model that is *visible from the source code*: a program should be easy to parse, easy to statically analyze, and easy to reason about without hidden machinery. Ownership, destruction, and evaluation order are all explicit and deterministic.

This document — the **Core specification** — defines the Stilla v1.3 syntax and the compile-time constraints a conforming compiler must enforce: the type system, ownership checking, generic specialization, and the static module rules. The companion **Runtime specification** defines the execution model: module instantiation, evaluation order, runtime destruction, panic semantics, and the embedding-host contract.

The boundary between the two documents is drawn at the point where a program transitions from a static artifact into a running execution context.

The remainder of this specification states those rules precisely. Sections 2 through 17 explain the model; section 18 is the normative requirement (the formal static semantics). The normative lexical and syntactic grammar is defined in the standalone [`Stilla Core Grammar Draft.abnf`](Stilla%20Core%20Grammar%20Draft.abnf).

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
- **Copy** — a capability held by some types: a Copy value may be implicitly copied, such as `int32` or `str`; dropping a Copy value does nothing (§10.1).
- **unique** — a value without the Copy capability: it may be used at most once and must be destroyed exactly once; it is not implicitly copyable (§10.2).
- **owner** — a binding or location that holds a value; every value has ownership (§10).
- **maybe-unique** — a unique binding released on some but not all normal paths through a conditional construct; it is unusable after the join, and its destruction is guarded by an implementation-maintained liveness state (§10.10).
- **borrow** — a non-owning, read-only view of a value; it never transfers ownership (§10.6).
- **move** — explicit ownership transfer of a complete local owner (§10.4).
- **drop** — deterministic destruction: a user `drop` hook (§9.1), an explicit `drop` statement (§9.4), or automatic destruction when a scope ends (§9.5).
- **nominal type** — a type defined by a `struct` or `union` declaration; it is distinct from every other type even if shape-identical (§7, §11).
- **monomorphic function** — a function value whose parameter and return types are fully concrete; there are no runtime generic function values (§12).
- **specialization** — compile-time expansion of generic code to concrete types (§12).
- **top type** — `any`, the type every value type coerces to; its counterpart is the bottom type `never`, which has no values and coerces to every type (§11.6, §13.2).
- **destruction view** — the special borrowed view of a value seen inside its own `drop` hook (§9.2).
- **full expression** — an expression that is not a subexpression of a
  larger expression: a statement-level expression, a binding or constant
  initializer, an argument, a field initializer, a match-arm body, or a
  block's final expression. Unique temporaries are destroyed at the end
  of the innermost enclosing full expression (Runtime §6.4).

Runtime-side terms (execution context, module storage, teardown, host) are defined in Runtime §1.4.

### 1.6 How this specification is organized

- **§2–§3 — Modules.** Every file is an implicit immutable module value; imports are statically resolved; the `builtin` module is imported like any other standard-library module. Module instantiation and the host contract are defined in the Runtime specification.
- **§4–§8 — Bindings and values.** Locals (`let`), module constants (`const`), functions, structs, and construction.
- **§9–§12 — Ownership and types.** Destruction, the ownership model, algebraic data types, and compile-time generics. Destruction timing and order are defined in the Runtime specification.
- **§13–§16 — The expression layer.** Control flow, patterns, operators, and member access. Evaluation order is defined in the Runtime specification.
- **§17 — Example.** A worked resource module.
- **§18 — Normative requirements.** The formal static semantics and the grammar.

The companion **Runtime specification** covers: the execution context (§R1), module instantiation (§R2), the host environment (§R3), the required `builtin` interface (§R4), evaluation order (§R5), destruction at runtime (§R6), termination and traps (§R7), and the core runtime model (§R8).

---

# 2. Files, Modules, and Namespaces

## 2.1 Every file defines a module

Every Stilla source file defines one implicit immutable **module struct**.

For example, `calc.st`:

```stilla
const pi: float32 = 3.141592653589793;

fn add(a: int32, b: int32) -> int32 {
    a + b
}

fn square(x: float32) -> float32 {
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
const builtin = import("builtin");

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

Import cycles are rejected in Stilla v1.3.

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

A host module's function members may be **host bindings** — function
declarations without a Stilla body (Grammar `func-def`, second form) — and
its constant members may be **host constants** — `const` declarations
without an initializer (Grammar `const-def`, second form). The host
supplies the implementation or value: a host binding is callable only as a
runtime system call, its body is never lowered, and a host constant is
read as a runtime value the host provides at instantiation (Runtime §3.1).
Standard-library modules use the same forms for their host-implemented
members (Standard Library §1).

Conceptually:

```stilla
struct Database {
    query: fn(str) -> str;
    execute: fn(str) -> int32;
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
const string = import("string");
```

Here `math` is the standard-library `math` module (Standard Library
document, §4), and `string` is the standard-library `string` module
(Standard Library document, §5).

Consumer:

```stilla
const std = import("std");
const builtin = import("builtin");

fn main() -> void {
    let x =
        std.math.sqrt(16.0);

    builtin.print(
        std.string.upper("hello")
    );
}
```

The expression:

```stilla
std.math.sqrt
```

is chained value-member access (§15).

No nested runtime namespace mechanism is required.

## 2.8 Path aliases with `using`

A **path alias** introduces a new name for a path in the current scope.
Path aliases use:

```stilla
using
```

Examples:

```stilla
const builtin = import("builtin");

using builtin.Option      // Option = builtin.Option
using string.repeat as re // re = string.repeat
```

Without `as`, the alias name is the final segment of the path; with `as`, it
is the identifier that follows. The alias refers to the path as a whole, and
at a use site denotes whatever the path denotes — a type, a value, or a
module member (Grammar `using-decl`).

A `using` declaration:

- may appear at module scope and inside blocks (Grammar `module-item`,
  `statement`);
- is scoped: the alias is visible from the declaration point to the end of
  the enclosing module or block, and is not visible to sibling or outer
  scopes;
- may shadow an outer binding, and may itself be shadowed, with the same
  rules as `let` (§4);
- is a compile-time binding: it does not create a runtime member, is not
  present on the module struct, and cannot be assigned, moved, or dropped;
- requires the path to resolve; a path alias for an unresolved path is a
  compile-time error.

Example:

```stilla
const string = import("string");

using string.upper as up;

fn shout(text: str) -> str {
    up(text)
}
```

Here `up` is the alias of `string.upper` within the module.

---

# 3. The `builtin` Module

`builtin` is an ordinary importable standard-library module (Standard
Library §1). A program brings it into scope like any other module:

```stilla
const builtin = import("builtin");
```

There is no implicitly available module binding and no reserved word:
`builtin` may be bound, aliased, and shadowed like any other identifier.

Core helpers include:

```stilla
builtin.print
builtin.str
builtin.len
builtin.range
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
const builtin = import("builtin");

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
const version: int32 = 1;
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
- module functions declared anywhere in the module, including functions declared after the constant; function references do not depend on initialization order;
- types;
- the `builtin` module (imported like any other module).

It may not reference a later module constant.

A module constant initializer must not transitively call a function that reads a module constant declared later than the initializer; such a program is rejected at compile time. This preserves the guarantee that module constants are read only after initialization (Runtime §2.3).

A unique non-module constant is owned by the module execution context. It cannot be explicitly moved or explicitly dropped by source code and is destroyed during normal module/context teardown (Runtime §2.5).

The initialization-order restriction applies symmetrically at teardown:
teardown destroys unique constants in **reverse** declaration order
(Runtime §2.5), so a later constant is already destroyed when an earlier
constant's `drop` hook runs. A unique module constant whose type defines a
`drop` hook — the hook and every function it transitively calls — must
not read a module constant declared later than the constant being
destroyed; such a program is rejected at compile time.

---

# 6. Functions

Functions are declared with:

```stilla
fn
```

Example:

```stilla
fn add(
    a: int32,
    b: int32
) -> int32 {
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
    value: int32;
    next: fn(borrow Counter) -> int32;
}
```

an ordinary function value stored in `next` must explicitly receive any instance it needs.

For example:

```stilla
let counter =
    Counter{
        value: 10,
        next:
            fn(borrow counter: Counter) -> int32 {
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
fn example() -> fn(int32) -> int32 {
    let factor = 2;

    fn(x: int32) -> int32 {
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
- the `builtin` module (imported like any other module).

Module members have execution-context lifetime and do not constitute closure capture.

## 6.3 Lambdas

Anonymous functions use the same syntax without a name:

```stilla
let double =
    fn(x: int32) -> int32 {
        x * 2
    };
```

Lambdas obey the same non-capture rule.

## 6.4 Return values

A function returns the value of its body block's final expression.

Example:

```stilla
fn add_one(x: int32) -> int32 {
    x + 1
}
```

A block with no final expression has type:

```stilla
void
```

If a function return type is omitted, it is inferred from the body.

A recursive function must explicitly declare its return type.

## 6.5 Order and recursion

Functions and lambdas are **order-independent** within the module in which they are declared: a function body may reference any module-level function, including functions declared later in the same source file. Direct and **mutual recursion** are permitted. Because functions are non-capturing (§6.2) and are represented as monomorphic code references, a function reference does not depend on module-constant initialization order (§5).

Every function participating in a recursion cycle — direct or mutual — must declare its return type explicitly (§6.4).

A function type is a finite code-reference type. A struct or union may contain a function field whose type mentions the enclosing type; the function type breaks the storage cycle (§11.3) and does not make the enclosing type unique on that account (§10.3).

---

# 7. Structs

A named struct defines a nominal record type.

```stilla
struct Point {
    x: float32;
    y: float32;
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
    add: fn(int32, int32) -> int32;
}
```

Example:

```stilla
let math =
    Math{
        add:
            fn(a: int32, b: int32) -> int32 {
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
    fd: int32;
    path: str;

    drop(file) {
        os.close(file.fd);
    }
}

fn open_file(path: str) -> File {
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
fn open(path: str) -> File {
    ...
}

fn create(path: str) -> File {
    ...
}

fn from_fd(fd: int32) -> File {
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

## 8.3 No constructor invariants in v1.3

Raw struct construction remains available even if a type defines `drop`.

Therefore Stilla v1.3 does not provide language-enforced private constructor invariants.

Libraries that require stronger abstraction must rely on module conventions or host-provided opaque interfaces.

Visibility control and opaque source-defined structs are outside the scope of Stilla v1.3.

---

# 9. Destruction

This section states the compile-time constraints of destruction: how a `drop` hook is declared, what code may do inside it, and what an explicit `drop` may target. The runtime sequence of destruction — ordering, timing, and teardown — is defined in Runtime §6.

## 9.1 `drop` lifecycle declaration

A named struct may define one destruction hook:

```stilla
struct File {
    fd: int32;
    path: str;

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

- read Copy fields;
- borrow unique fields;
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

The order in which a struct value is destroyed at runtime is defined in Runtime §6.2: the user `drop` hook runs first, then unique fields are destroyed in reverse declaration order, then the complete value is marked destroyed.

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

Explicit `drop` applies only to an owning **unique** local binding.

It cannot directly target:

- a field;
- an indexed element;
- a module constant;
- a `borrow` parameter;
- a module value.

This restriction avoids partial-destruction state.

The destruction sequence performed by an explicit `drop` at runtime is defined in Runtime §6.5.

## 9.5 Automatic destruction

During normal control flow, a unique local owner that has not been moved or explicitly dropped is automatically destroyed when its scope ends.

The destruction order — reverse creation order — is defined in Runtime §6.1.

## 9.6 Structural destruction

Values containing unique components are destroyed structurally.

The precise ordering for each container form — struct fields, tuple elements, list elements, union payloads, `box[T]`, and module-owned unique constants — and the rule that only the active union variant is destroyed, are defined in Runtime §6.3.

---

# 10. Ownership

Stilla classifies owned runtime values as:

```text
Copy
Unique
```

In addition, the type checker tracks non-owning **borrowed views** of values.

A borrow is never an owner and never participates in destruction.

This section states the static (compile-time) ownership model. Every value has ownership: some types have the **Copy** capability (§10.1), and a value without Copy is **unique** (§10.2). The timing of runtime destruction — scope exit, full-expression temporaries, and module teardown — is defined in Runtime §6.

## 10.1 Copy capability

Typical Copy values include:

```text
byte
int32
uint32
float32
bool
str
void
fn(...)
```

A Copy value may be copied implicitly.

Copy is a capability: a Copy value may be copied implicitly; a value without Copy is unique (§10.2); `drop` of a Copy value does nothing.

Immutable strings may use reference-counted sharing.

All first-class function values are monomorphic (§12).

The top type `any` is **not** Copy: because it may hold a value of any type — including a unique value — `any` is always unique (§11.6). The type `hostdata` is **not** Copy: it wraps a host-owned opaque payload and is always unique (§11.7).

## 10.2 Unique values

A value is unique if:

- its named struct type defines `drop`; or
- one of its owned components is unique.

Unique values cannot be implicitly copied.

A unique owner may be:

- borrowed any number of times;
- moved at most once;
- destroyed at most once.

Use after move or destruction is a compile-time error. A Copy owner is exempt: it may be used, moved, and destroyed any number of times, and `drop` of a Copy value has no effect. The implementation may analyse whether a binding could be a simple Copy (passed by value) and reduce it to a simple value when compiled.

## 10.3 Composite ownership

Ownership classification is structural.

For example, `tuple[A, B]` is unique if either `A` or `B` is unique.

A union is unique if any variant payload can contain a unique value.

The top type `any` is unique for the same structural reason: it may hold a value of any type, including a unique value (§11.6).

For containers:

```text
list[T]
box[T]
```

the container is Copy if `T` is Copy and unique if `T` is unique.

An implementation may use reference-counted sharing for Copy `list[T]` and `box[T]`.

A non-Copy list or box has unique source-language ownership.

**Recursive classification.** The rules of §10.2–§10.3 define a monotone system of equations over
types. For a type whose type graph is cyclic, the equations have multiple solutions; Stilla v1.3
resolves the ambiguity to the **greatest fixpoint**. A recursive occurrence reached through an owned
component is classified as unique. A type is Copy only if its classification is well-founded
without treating any recursive back-edge as unique.

Consequences:

- A recursive type with no `drop` hook, such as `Tree` in §11.1, is **unique**: it cannot be
  copied implicitly, and `box[Tree]` / `list[Tree]` are unique containers.
- The reference-counting sharing freedom of this section applies only to Copy containers,
  which under this rule are never recursive.
- A function type is not an owned component: it contains no payload and is always Copy
  (§10.1). A type cycle that passes only through function types — for example
  `struct F { call: fn(F) -> int32 }` — does not make the type unique and is not recursive storage
  (§11.3).

Implementations must resolve the classification to the greatest fixpoint; the choice is observable
(§10.4) and is therefore normative. A worklist algorithm over the strongly connected components of
the type graph is a conforming method.

## 10.4 Ownership transfer with `move`

Consuming a binding `x` of type `T` either duplicates or transfers its value:

```text
consume x:
    Copy(T)   => duplicate value, x remains live
    !Copy(T)  => transfer ownership, x becomes dead (definitely released, §10.10)
```

`move` is the consume operator: `move x` consumes `x`.

Ownership transfer from an existing local owner is explicit:

```stilla
let a = open_file("a.txt");
let b = move a;
```

Afterward `a` is invalid.

`move` transfers the complete ownership represented by a local binding.

Stilla v1.3 does not support partial move from:

- struct fields;
- tuple elements;
- list elements;
- indexed expressions.

Syntactically, `move` names a complete local binding.

To extract owned components, the complete owner must first be consumed by destructuring (§14.6).

## 10.5 Fresh unique values

A freshly produced unique value already carries fresh ownership and has no existing local owner to invalidate.

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
fn add_one(x: int32) -> int32 {
    x + 1
}
```

A plain parameter accepts only a Copy argument type. The argument is passed by ordinary value semantics and may be copied.

Passing a unique value to a plain parameter is a compile-time error.

The top type `any` is the sole exception (§11.6): a plain parameter of type `any` accepts any argument type. A Copy argument is coerced into the `any` and may be copied; a unique argument must be written with explicit `move` at the call site, and its ownership transfers into the `any`.

### Borrow parameters

```stilla
const builtin = import("builtin");

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

Inside the callee, a borrowed unique value may be read, matched non-consumingly, have members read, and be passed to another compatible `borrow` parameter.

It may not be moved, explicitly dropped, returned as an owned value, or stored into an owning location.

### Move parameters

```stilla
const builtin = import("builtin");

fn consume(move file: File) -> void {
    builtin.print(file.path);
}
```

A `move` parameter is an owner inside the callee.

An existing unique local owner must be transferred explicitly:

```stilla
consume(move file);
```

A fresh unique expression transfers implicitly:

```stilla
consume(open_file("data.txt"));
```

Calling an ownership-taking parameter with an existing unique owner without `move` is a compile-time error.

For Copy types, `move` is semantically equivalent to an ordinary copy: it has no observable ownership effect, does not invalidate the source binding, and may be omitted.

Function types preserve parameter mode:

```stilla
fn(borrow File) -> void
fn(move File) -> File
fn(int32) -> int32
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

Stilla v1.3 does not provide general user-visible lifetime parameters.

Borrow lifetimes are intentionally restricted so they can be checked lexically.

User-defined functions may not return a borrowed unique value in v1.3.

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

For Copy `T`, the value may be copied normally.

For unique `T`, the borrowed result:

- may have members read;
- may be matched non-consumingly;
- may be passed directly to a `borrow` parameter;
- may not be moved, dropped, stored as an owner, or returned as an owned value.

The transient borrow lasts until the end of the enclosing full expression.

This permits read-only recursive traversal:

```stilla
const builtin = import("builtin");

fn contains(borrow tree: Tree, v: int32) -> bool {
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

## 10.9 Unique temporaries

When a unique temporary is destroyed at runtime — at the end of the containing full expression, in reverse creation order, unless interrupted by panic — is defined in Runtime §6.4.

## 10.10 Conditional release

A **conditional construct** is an `if`/`else` expression (§13.2), a `match` expression (§13.3), or a short-circuit `and`/`or` operand (§16.2).

Let `v` be a unique local binding whose scope encloses a conditional construct `C`. If any normal-control-flow path through `C` **releases** `v` — by `move` (§10.4), explicit `drop` (§9.4), or a consuming destructure of its whole owner (§14.6) — and some other normal path does not, then `v` is **maybe-unique**: it may not be used, borrowed, moved, or dropped afterward (compile-time error, §10.2 use-after-move), and its scope-end destruction is conditional — the implementation tracks at runtime whether the binding was already released and destroys it only if it is still alive.

Consequently, after a conditional construct `C`, every unique binding whose scope encloses `C` is either **definitely owned**, **maybe-unique**, or **definitely released**:

- a definitely-owned binding behaves normally: it may be borrowed, moved, dropped, or automatically destroyed at scope end;
- a maybe-unique binding is released on some but not all normal-control-flow paths: it may not be used, borrowed, moved, or dropped afterward, and its scope-end destruction is conditional — the implementation tracks whether the binding was already released and destroys it only if it is still alive;
- a definitely-released binding was released on every normal path: it may not be used, borrowed, moved, or dropped afterward, and is not automatically destroyed at scope end; any such use is a compile-time error (§10.2, use-after-move).

For a maybe-unique binding, the runtime liveness flag is introduced only when the implementation cannot statically establish that the binding was released on every path (e.g. a binding released in one arm of an `if` but not the other).

Notes:

- A consuming match `match (move v)` releases `v` on every path and is unconditional; this rule governs only moves of *enclosing* bindings that occur inside arm bodies.
- Borrowing does not participate: a borrow never releases (§10.6, §10.7).
- Panic and trap paths are not normal control flow (Runtime §7) and neither satisfy nor violate the release requirement; no destruction runs as a consequence of termination.

## 10.11 Implicit consumption positions

`move` is the explicit consume operator (§10.4), but ownership is
transferred implicitly in **consuming positions** — positions that require
an owned value:

- a move-mode call argument — a fresh unique expression transfers
  directly; an existing local owner requires `move` (§10.6);
- a struct, union-variant, tuple, or list literal slot — a fresh unique
  expression is owned by the constructed value; an existing local owner
  requires `move`;
- a `let` binding with an identifier pattern — a fresh unique expression
  is owned by the new binding; an existing local owner requires `move`;
- a function's final expression when the return type is unique — the
  value is returned by ownership, and an existing local owner in final
  position transfers implicitly, because the binding ends with the
  return (§6.4);
- a coercion of a unique value to `any` — the pack consumes the source
  (§11.6).

In every consuming position, an existing unique local owner is
transferred only with an explicit `move`; a fresh unique expression
transfers implicitly (§10.5); and a borrowed value never transfers
(§10.7). Storing an existing unique owner without `move` is a compile-time
error (§18 *Ownership*).

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
Option[int32]::Some(42)
Option[int32]::None
```

When type arguments are inferable from context, they may be omitted:

```stilla
let x: Option[int32] =
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
type UserId = int32;
type MaybeInt = Option[int32];
```

After alias expansion, the alias and aliased type are the same type for static semantics.

Generic aliases are compile-time templates:

```stilla
type PairList[T] = list[tuple[T, T]];
```

Stilla v1.3 has no anonymous struct or anonymous union type syntax.

## 11.3 Recursive types

Recursive inline storage is forbidden.

Every recursive storage cycle must pass through indirection such as `box[T]`, `list[T]`, or a function type (§10.3).

The unique classification of recursive types follows the greatest-fixpoint rule of §10.3.

## 11.4 Tuple

Tuple type:

```stilla
tuple[int32, str, bool]
```

Literal:

```stilla
(42, "hello", true)
```

A tuple type has **at least one element**: `tuple[]` is not a type — the
empty tuple `()` is the unique `void` value. A single-element tuple type
`tuple[int32]` is valid and distinct from `int32`; its literal is written
`(42,)` (Grammar `paren-or-tuple`).

## 11.5 List

List type:

```stilla
list[int32]
```

Literal:

```stilla
[1, 2, 3]
```

Lists are immutable.

Indexing uses the `@[...]` syntax and does not mutate a list:

```stilla
let first = values@[0];
```

An indexed unique element is borrowed and cannot be independently moved.

`list[T]` is the language's abstract sequence type. Concrete dense sequences such as `array[T]` are standard-library types, not keywords.

## 11.6 The top type `any`

`any` is the language's **top type**: every value type `T` — except
`hostdata` (§11.7) — coerces to `any`. The bottom type `never` has no
values and coerces to every type; `any` is the inverse — it accepts every
tagged value type and coerces to no other type (§18 *Typing*). `hostdata`
carries no runtime type tag, so it cannot be an `any` payload.

`any` may hold a value of any type:

```stilla
let a: any = 42;                    // Copy int32, copied in
let b: any = "hello";               // Copy str, copied in
let c: any = open_file("f");        // unique File, moved in (fresh value)
```

The coercion is implicit. A Copy source value is copied into the `any`; a
unique source value must be moved — an existing unique owner requires
explicit `move` at the coercion site, while a fresh unique expression
transfers implicitly (§10.5) — and its ownership transfers into the `any`.

`any` is **unique** (§10.3): because it may hold a unique value, an `any` value may be used at most once, must be destroyed exactly once, and is not implicitly copyable. `any` therefore does not appear in the Copy list of §10.1, and containers of `any` — `list[any]`, `box[any]`, `tuple[..., any]` — are unique.

An `any` value carries a **runtime type tag** recording its concrete payload type (Runtime §8). The tag is deterministic and comparable; Stilla inspects it only through the two typed-recovery operations of §11.6.1 and §11.6.2. No member access, indexing, operator, or equality is defined on `any` (§16.3), and `any` does not coerce to any other type (§18 *Typing*). Destruction of an `any` value destroys the tagged payload by the payload type's own destruction rules (Core §9, Runtime §6).

The primary uses are:

- **heterogeneous data** — unique containers such as `box[any]` and `list[any]` can carry values of different types together;
- **typed recovery** — `as` (§11.6.1) and `match` type-test patterns (§11.6.2) recover a payload as a specific type, trapping on mismatch;
- **opaque pass-through** — a Stilla program may receive, store, and forward `any` values without inspecting them.

## 11.6.1 Recovery by `as`

An `any` value may be recovered by an `as` cast naming a concrete type:

```stilla
let b = a as int32;
```

The target type `T` must be a concrete Stilla type other than `any` and `never`; in generic code the target is the specialization of `T` (§12). The cast reads the runtime tag:

- if the payload type is `T`, the payload is extracted;
- otherwise the program traps: **invalid `any` cast** (Runtime §7.2). The trap terminates without unwinding (§7.1), so no partial ownership state remains.

Ownership follows the target type, statically:

- if `T` is Copy (§10.1), the payload is copied out and the source `any` remains definitely owned; the same value may be recovered again;
- if `T` is unique, the source must be moved: `(move a) as T`. The complete `any` is consumed (§10.4), ownership of the payload transfers to the result, and the source becomes definitely released (§10.10);
- `hostdata` never appears in an `any` payload — it does not coerce to `any` (§11.6, §11.7) — so `as hostdata` is never a valid recovery.

## 11.6.2 Recovery by `match`

A `match` may test an `any` value with **type-test patterns**:

```stilla
match (a) {
    int32 n => ...,
    str s => ...,
    File f => ...,
    _ => ...          // required
}
```

A type-test pattern is a concrete type name, optionally followed by a binding identifier (§14.7). It matches when the runtime tag equals that type. Because the tag space is open — any program may define new types — a `match` over an `any` value must include a wildcard `_` arm.

(The scrutinee is parenthesized per §13.3.)

Binding mode follows §13.4:

- in a non-consuming match `match (a)`, the scrutinee is borrowed: Copy arm bindings are copies, and unique arm bindings are borrows usable only within the selected arm;
- in a consuming match `match (move a)`, the complete `any` is transferred: Copy arm bindings are copies, unique arm bindings are owners of the extracted payload, and the wildcard arm discards the payload.

Type-test patterns may reference generic parameters; under monomorphization (§12) they resolve to concrete tags.

## 11.7 The `hostdata` type

`hostdata` is a distinct nominal type carrying an **opaque, host-defined payload**. It is unrelated to `any` (§11.6): a `hostdata` value is created only by a host binding and leaves Stilla only by being handed back to the host or by destruction.

Only the host constructs `hostdata` values, through host functions and module members (§2.6, Runtime §3.1). No Stilla value coerces into `hostdata`, `hostdata` does not coerce into `any` (§11.6) or into any other type, and `hostdata` is not a top type.

Stilla defines no operation on `hostdata` other than moving, borrowing, storing, passing along, and handing to the host. No member access, indexing, operator, cast, pattern, equality, or hash is defined on `hostdata`, and it coerces to no other type (§16.3).

`hostdata` is **unique** (§10.3): a `hostdata` value may be used at most once, must be destroyed exactly once, and is not implicitly copyable. `hostdata` does not appear in the Copy list of §10.1, and containers of `hostdata` — `list[hostdata]`, `box[hostdata]`, `tuple[..., hostdata]` — are unique.

Destruction of a `hostdata` value — automatic (Core §9.5), explicit `drop` (Core §9.4), or container destruction — returns the opaque payload to the host for disposal (Runtime §3.4, §7.3); this is host cleanup, not execution of a Stilla `drop` hook.

The primary uses are:

- **host bindings** — host-provided functions and module members may accept and return `hostdata` for opaque payloads;
- **opaque handles** — a host may hand a Stilla program a `hostdata` value wrapping a host-owned resource; Stilla tracks it with unique ownership and hands it back without inspecting it;
- **host-bound buffering** — unique containers such as `box[hostdata]` and `list[hostdata]` can carry opaque payloads that a Stilla program collects and forwards to the host as a whole.

---

# 12. Generics

Generics in Stilla v1.3 are compile-time syntax sugar for specialization (monomorphization).

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

The inference is **structural over the types of the call's argument
expressions**: `list[T]`, `box[T]`, `tuple[...]`, and function types are
matched componentwise. A type argument is not recovered from the value of
a generic named type: a parameter such as `a: Array[T]` (Standard Library
§2) carries `T` only inside the named type's argument list, and a value of
that named type exposes no instantiation information, so `T` cannot be
inferred there and must be written explicitly with `::[...]` (§12.3).
There is likewise no inference from an expected result type in v1.3: a
generic call with no type-carrying argument — for example
`hashmap.empty()` (Standard Library §3) — requires explicit type
arguments.

Conceptually:

```text
identity(42)
    ↓ infer T = int32
identity::[int32](42)
    ↓ compile-time expansion
<concrete fn(int32) -> int32>(42)
```

No generic dispatch occurs at runtime.

## 12.3 Explicit specialization

Explicit function specialization uses:

```stilla
identity::[int32](42)
```

The syntax `::[...]` is compile-time specialization syntax. It does not perform a runtime postfix operation.

Explicit specialization is required whenever inference cannot determine a
type argument from the argument expressions (§12.2) — for example
`array.get::[int32](a, 2)` and `hashmap.empty::[str, int32]()` (Standard
Library §2, §3).

Type specialization uses:

```stilla
Pair[int32, str]
Option[int32]
```

## 12.4 Generic functions are not first-class before specialization

An unspecialized generic function is a compile-time entity, not a runtime function value.

Therefore:

```stilla
let f = identity;
```

is invalid.

A generic function is specialized at each call site — inferred from the
argument types (§12.2) or written explicitly (§12.3):

```stilla
let v = identity::[int32](42);
```

The explicit specialization denotes the monomorphic call; in v1.3 the
specialized function is invoked at a call site, and binding a specialized
generic as a standalone function value (`let f = identity::[int32];`) is
not part of the v1.3 surface — the frontend lowers generic templates
unspecialized, so a specialized generic value has no IR representation
(§18 *Generics*).

Generic functions stored in modules follow the same rule: `module.generic_name` may participate in compile-time call inference or explicit specialization, but only a concrete specialization becomes a runtime function value.

## 12.5 No generic function values

Function types are always monomorphic.

The following is not a Stilla v1.3 type:

```text
fn[T](T) -> T
```

Generic lambdas are also not supported in v1.3.

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

A block may contain `using` declarations (§2.8); an alias declared inside a
block is visible only within that block.

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

Both branches must have the same type, except that `never` may coerce to any type and any type may coerce to the top type `any` (§11.6); the `if` expression then has the wider of the two types.

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
int32 n           // type-test pattern (§11.6.2, §14.7)
```

## 13.4 Borrowing and consuming matches

Matching a unique owner normally borrows it:

```stilla
match (value) {
    ...
}
```

Unique pattern bindings produced by such a match are borrowed for the lifetime of the selected match arm.

They may be read or passed to `borrow` parameters, but they are not owners.

To consume the complete owner:

```stilla
match (move value) {
    ...
}
```

the complete value is transferred into the match operation.

Unique payload bindings then become owners within the selected arm.

This never performs a partial move from the original binding: the original binding is invalidated as a whole.

## 13.5 Iteration

The core language defines no iteration construct. Repetition is expressed with ordinary recursive function calls (§6.5); a library may provide iteration helpers as ordinary module functions (§8), invoked like any other call. The core language has no special knowledge of such helpers.

A conforming implementation **must** reuse the caller's frame for a direct
self-recursive call in tail position (tail-call optimization), so
iteration expressed as self-recursion does not grow the stack. Mutual
recursion and non-tail recursion may grow the stack, bounded by
implementation-defined resources (the frontend performs this optimization;
ir.md §14.7).

---

# 14. Patterns

Patterns are used by `let` and `match`.

`match` accepts the full pattern language.

`let` accepts only **irrefutable patterns** so that binding never introduces an implicit runtime failure path.

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
Option[int32]::Some(value)
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

Destructuring a unique rvalue transfers ownership into unique pattern bindings.

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

This is the supported way to decompose unique aggregate ownership **when the aggregate type does not define its own `drop` hook**.

A struct that defines `drop` may be destructured only through a borrowing pattern. Consuming destructuring of such a struct is a compile-time error, because moving out its fields would conflict with the struct's own destruction lifecycle.

Direct partial movement such as:

```stilla
move pair.first
```

is illegal.

## 14.7 Type-test pattern

A type-test pattern matches an `any` value (§11.6.2):

```stilla
int32 n
str s
File f
list[int32] xs
tuple[int32, str] t
_              // the required wildcard for `any`
```

The pattern is a concrete type name, optionally followed by a binding identifier. It matches when the runtime tag equals that type. It is refutable and is accepted only by `match` (§13.3), and only for a scrutinee of type `any`. Under monomorphization (§12) generic parameters resolve to concrete tags. A `match` over an `any` value must include a wildcard `_` arm (§11.6.2).

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
Result[str, int32]::Ok("done")
```

It is not general type-member lookup.

## 15.3 `::[...]`

`::[...]` requests explicit compile-time specialization of a generic function name or generic function member.

Example:

```stilla
identity::[int32](42)
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
and  or  !
```

Explicit conversion:

```stilla
value as float32
```

String concatenation is only:

```text
str + str
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

1. `or`
2. `and`
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
a < b and b < c
```

## 16.2 Evaluation order

Stilla uses a single deterministic evaluation-order rule; it is defined in Runtime §5:

> **Unless a construct explicitly states otherwise, subexpressions are evaluated exactly once from left to right in source order.**

## 16.3 Core operator typing and numeric conversion

Core arithmetic is defined as follows:

- `int32 + - * / % int32 -> int32`;
- `uint32 + - * / % uint32 -> uint32`;
- `float32 + - * / float32 -> float32`;
- `str + str -> str`;
- unary `-` accepts `int32`, `uint32`, or `float32`;
- `!`, `and`, and `or` accept `bool`;
- `< <= > >=` accept operands of the same numeric type;
- `== !=` are required for `byte`, `int32`, `uint32`, `float32`, `bool`, and `str`.

Integer `/` truncates toward zero. Integer `div` and `rem` by zero trap
(Runtime §7.2). `int32` arithmetic traps on overflow; `uint32` arithmetic
is performed modulo 2³² and never traps on overflow or underflow
(Runtime §7.2). Unary `-` on `int32` traps on the minimum value; on
`uint32` it computes the two's-complement negation (`0 - x`), which never
traps (Runtime §7.2). Float arithmetic follows IEEE 754 (Runtime §7.2).

The Stilla v1.3 core does not define equality for `any`, functions, structs, unions, tuples, lists, boxes, or modules. Libraries may provide explicit equality helpers.

No operator is defined on `hostdata` (§11.7), and none is defined on `any` other than `as` and `match` type-testing (§11.6): an `any` value can be moved, borrowed, stored, passed along, handed to the host, recovered by `as`, and tested by `match`.

Core `as` conversions are:

```text
int32 as float32
float32 as int32
int32 as byte
byte as int32
int32 as uint32
uint32 as int32
any as T        // T a concrete type, T ≠ any, never, hostdata (Core §11.6.1)
```

No other core conversion is implied by `as`.

An integer literal has type `int32`, and a float literal has type
`float32` (Grammar `integer`, `float`). Stilla defines no `byte` or
`uint32` literal form and no implicit numeric conversion; a `byte` or
`uint32` value is written with an explicit conversion, for example
`104 as byte` or `7 as uint32`. Conversion from `int32` traps when the
value is outside the target's range (Runtime §7.2).

`as` is not extended to `hostdata`: no cast is defined from or to `hostdata` (§11.7).

The runtime behavior of these operations — IEEE 754 representation and arithmetic, floating equality, overflow and division traps, and invalid-cast traps — is defined in Runtime §7.2.

---

# 17. Example Resource Module

`file.st`:

```stilla
const os = import("os");
const builtin = import("builtin");

struct File {
    fd: int32;
    path: str;

    drop(file) {
        os.close(file.fd);
    }
}

fn open(path: str) -> File {
    File{
        fd: os.open(path),
        path: path
    }
}

fn create(path: str) -> File {
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

Function arguments and return values must match exactly unless the source type is `never`, the required type is the top type `any`, or a transparent `type` alias expands to the required type (§11.6).

`any` carries a runtime type tag identifying its payload type; recovery requires naming the type explicitly, via `a as T` (§11.6.1) or a `match` type-test pattern (§11.6.2). Stilla defines no equality on `any`. `hostdata` is opaque and tagless; no cast, pattern, or equality is defined on it (§11.7).

## Conversion

No implicit numeric or `str` conversions exist.

Coercion to the top type `any` is the sole implicit widening (§11.6), and
`hostdata` does not participate: no value coerces into `hostdata`, and
`hostdata` does not coerce into `any` (§11.7).

## Closures

A function or lambda may not reference local bindings belonging to an enclosing function scope.

## Functions

Functions are order-independent within a module; direct and mutual recursion are permitted (§6.5). Every function in a recursion cycle declares its return type explicitly. Module constant initialization must not transitively read a later-declared module constant (§5).

## Path aliases

A `using` declaration introduces a scoped compile-time alias for a path
(§2.8): it is visible from its declaration point to the end of the
enclosing module or block, may shadow and be shadowed like `let`, is not a
runtime member, and requires its path to resolve.

## Match

A match over a union must be exhaustive.

A non-consuming match of a unique value borrows the scrutinee and produces borrowed unique bindings.

A `match (move owner)` consumes the complete owner and may produce owning payload bindings, except that a struct defining its own `drop` hook cannot be consumingly destructured into fields.

## Patterns

`let` requires an irrefutable pattern.

Refutable patterns are accepted only by `match` in Stilla v1.3.

## Ownership

A unique owner may be borrowed any number of times, moved at most once, and destroyed at most once.

Use after move or destruction is a compile-time error.

If a binding is released on some but not all normal paths through a conditional construct, it becomes **maybe-unique** and is unusable after the join; its automatic destruction is guarded by its runtime liveness state (§10.10). A definitely-released binding is unusable and is not automatically destroyed at scope end.

Consuming positions (§10.11): a struct, union-variant, tuple, or list
literal slot, a `let` binding with an identifier pattern, and a move-mode
call argument transfer ownership implicitly for a fresh unique expression;
an existing unique local owner in any consuming position must be moved
with explicit `move`, and storing it without `move` is a compile-time
error.

## Whole-owner rule

Explicit ownership movement operates on complete local owners.

Direct partial movement from fields or indexed elements is forbidden.

Consuming destructuring of a struct that defines its own `drop` hook is forbidden.

## Borrowing

`borrow` never transfers ownership.

A borrowed unique value cannot be moved, dropped, returned as owned, or stored into an owning location.

Borrow lifetimes are lexically bounded; Stilla v1.3 has no user-visible lifetime parameters and no user-defined borrowed unique return values.

## Parameters

A plain parameter accepts only Copy argument types.

The top type `any` is the sole exception (§10.6): a plain `any` parameter
accepts any argument type — a Copy argument coerces into the `any`, and a
unique argument must be written with explicit `move` at the call site,
with its ownership transferring into the `any`.

A `borrow` parameter receives a non-owning view and leaves the caller's ownership unchanged.

A `move` parameter receives ownership.

Passing an existing unique local owner to a `move` parameter requires `move owner` at the call site.

A fresh unique value may transfer directly without an explicit `move` token.

## Destruction

Every live unique local owner is destroyed when its scope ends during normal control flow unless it has already been moved or explicitly dropped.

Unique temporaries are destroyed at the end of their full expression in reverse creation order during normal control flow (Runtime §6.4).

## User drop hook

A struct may define at most one `drop` lifecycle declaration.

The hook cannot be called directly.

Its destruction-view argument cannot be moved, dropped, returned, or used to transfer field ownership.

## Structural destruction

After a struct's user hook completes normally, unique fields are destroyed in reverse declaration order (Runtime §6.2).

## Panic and traps

Panic and runtime traps terminate the current Stilla execution context without unwinding (Runtime §7).

Stilla does not execute pending local, temporary, field, or module destruction as a consequence of such termination.

Host cleanup after termination is outside Stilla source semantics.

## Evaluation order

Unless explicitly stated otherwise, subexpressions are evaluated exactly once from left to right (Runtime §5).

`and` and `or` short-circuit (Runtime §5).

## Recursion

Recursive value types must contain indirection on every recursive storage cycle, and their ownership classification follows the greatest-fixpoint rule of §10.3.

Iteration is expressed as self-recursion; a conforming implementation must reuse the caller's frame for a direct self-recursive call in tail position (§13.5, ir.md §14.7), so self-recursive iteration does not grow the stack. Mutual recursion and non-tail recursion may grow the stack, bounded by implementation-defined resources.

## Teardown

A unique module constant whose type defines a `drop` hook must not read —
directly or through any transitively called function — a module constant
declared later than the constant being destroyed, because teardown
destroys constants in reverse declaration order and a later constant is
already destroyed when the hook runs (§5, Runtime §2.5).

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

A specialized generic is invoked at a call site; binding a specialized
generic as a standalone function value is outside v1.3 (§12.4).

`value::[Types]` is compile-time specialization syntax, not runtime dispatch.

Type arguments are inferred structurally from the call's argument
expressions (§12.2); a type argument carried only inside a generic named
type's argument list, and a call with no type-carrying argument, require
explicit `::[...]` specialization (§12.3).

---

