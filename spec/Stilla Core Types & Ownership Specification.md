# Stilla Core Types & Ownership Specification

> **Version:** v1.3 Draft

This document is part of the **Stilla core language** specification, split into
three companion files:

- [Stilla Core Language Specification](Stilla%20Core%20Language%20Specification.md) — language structure: modules, bindings, functions, control flow.
- **This file** — values and ownership: structs, construction, destruction, ownership, algebraic data types, generics, patterns, member access, operators.
- [Stilla Core Static Semantics](Stilla%20Core%20Static%20Semantics.md) — the normative formal static semantics.

Where these and the other Stilla specs overlap on execution behavior, the
Runtime specification governs.

## Table of Contents

1. [Structs](#7-structs)
2. [Construction](#8-construction)
3. [Destruction](#9-destruction)
4. [Ownership](#10-ownership)
5. [Algebraic Data Types](#11-algebraic-data-types)
6. [Generics](#12-generics)
7. [Patterns](#14-patterns)
8. [Member Access and `::`](#15-member-access-and-)
9. [Operators](#16-operators)

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

Libraries that require stronger abstraction must rely on module conventions or
**host-backed opaque nominal types** (Host-backed opaque nominal types) —
declared by a standard-library or host-provided module interface, never by a
source module.

Visibility control and opaque source-defined structs are outside the scope of Stilla v1.3.

---

# 9. Destruction

This section states the compile-time constraints of destruction: how a `drop` hook is declared, what code may do inside it, and what an explicit `drop` may target. The runtime sequence of destruction — ordering, timing, and teardown — is defined in the Runtime specification.

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

- read *Copy* fields;
- borrow *Unique* fields;
- access ordinary members;
- call functions whose relevant parameters are declared `borrow` (Parameter modes);

A destruction view may not:

- be moved;
- be explicitly dropped;
- escape the hook;
- be returned;
- be stored into an owning binding;
- transfer ownership of one of its fields.

Partial movement from a destruction view is forbidden.

## 9.3 Destruction order

The order in which a struct value is destroyed at runtime is defined in the Runtime specification: the user `drop` hook runs first, then *Unique* fields are destroyed in reverse declaration order, then the complete value is marked destroyed.

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

Explicit `drop` names a whole local binding that owns its value: for an
owning *Unique* binding it destroys the value early (before scope end), and
for a *Copy* binding it has no effect (*Unique* values).

It cannot directly target:

- a field;
- a list element read (a list-pattern projection);
- a module constant;
- a `borrow` parameter;
- a module value.

This restriction avoids partial-destruction state.

The destruction sequence performed by an explicit `drop` at runtime is defined in the Runtime specification.

## 9.5 Automatic destruction

During normal control flow, a *Unique* local owner that has not been moved or explicitly dropped is automatically destroyed when its scope ends.

The destruction order — reverse creation order — is defined in the Runtime specification.

## 9.6 Structural destruction

Values containing *Unique* components are destroyed structurally.

The precise ordering for each container form — struct fields, tuple elements, list elements, union payloads, `box[T]`, and module-owned *Unique* constants — and the rule that only the active union variant is destroyed, are defined in the Runtime specification.

---

# 10. Ownership

Stilla classifies owned runtime values as:

```text
Copy
Unique
```

In addition, the type checker tracks non-owning **borrowed views** of values.

A borrow is never an owner and never participates in destruction.

This section states the static (compile-time) ownership model. Every value has ownership: some types have the **Copy** capability (*Copy* capability), and a value without *Copy* is **unique** (*Unique* values). The timing of runtime destruction — scope exit, full-expression temporaries, and module teardown — is defined in the Runtime specification.

## 10.1 *Copy* capability

Typical *Copy* values include:

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

A *Copy* value may be copied implicitly.

*Copy* is a capability: a *Copy* value may be copied implicitly; a value without *Copy* is *Unique* (*Unique* values); `drop` of a *Copy* value does nothing.

Immutable strings may use reference-counted sharing.

All first-class function values are monomorphic (Generics).

The top type `any` is **not** *Copy*: because it may hold a value of any type — including a *Unique* value — `any` is always *Unique* (The top type `any`). The type `hostdata` is **not** *Copy*: it wraps a host-owned opaque payload and is always *Unique* (The `hostdata` type). A host-backed opaque nominal type is **not** *Copy* either: it is *Unique* by declaration, regardless of its type arguments (Host-backed opaque nominal types) — `Array[int32]` is *Unique* even though `int32` is *Copy*.

## 10.2 *Unique* values

A value is *Unique* if:

- its named struct type defines `drop`; or
- one of its owned components is *Unique*; or
- its nominal type is a host-backed opaque type (Host-backed opaque nominal types), whose declaration fixes *Unique* ownership.

*Unique* values cannot be implicitly copied.

A *Unique* owner may be:

- borrowed any number of times;
- moved at most once;
- destroyed at most once.

Use after move or destruction is a compile-time error. A *Copy* owner is exempt: it may be used, moved, and destroyed any number of times, and `drop` of a *Copy* value has no effect. The implementation may analyse whether a binding could be a simple *Copy* (passed by value) and reduce it to a simple value when compiled.

## 10.3 Composite ownership

Ownership classification is structural.

For example, `tuple[A, B]` is *Unique* if either `A` or `B` is *Unique*.

A union is *Unique* if any variant payload can contain a *Unique* value.

The top type `any` is *Unique* for the same structural reason: it may hold a value of any type, including a *Unique* value (The top type `any`).

For containers:

```text
list[T]
box[T]
```

the container is *Copy* if `T` is *Copy* and *Unique* if `T` is *Unique*.

An implementation may use reference-counted sharing for *Copy* `list[T]` and `box[T]`.

A non-*Copy* list or box has *Unique* source-language ownership.

**Recursive classification.** The rules of **Copy capability** and **Unique values** define a monotone system of equations over
types. For a type whose type graph is cyclic, the equations have multiple solutions; Stilla v1.3
resolves the ambiguity to the **least fixpoint over the *Copy* predicate** — as
few types as possible are *Copy*: a recursive occurrence reached through an owned
component is classified as *Unique*. A type is *Copy* only if its classification is well-founded
without relying on any recursive back-edge — the back-edge must not be needed to establish
*Copy*-ness (as it would be for `Tree` below).

Consequences:

- A recursive type with no `drop` hook, such as `Tree` in **Named unions**, is **unique**: it cannot be
  copied implicitly, and `box[Tree]` / `list[Tree]` are *Unique* containers.
- The reference-counting sharing freedom of this section applies only to *Copy* containers,
  which under this rule are never recursive.
- A function type is not an owned component: it contains no payload and is always *Copy*
  (*Copy* capability). A type cycle that passes only through function types — for example
  `struct F { call: fn(F) -> int32 }` — does not make the type *Unique* and is not recursive storage
  (Recursive types).

Implementations must resolve the classification to the least *Copy* fixpoint; the choice is observable
(Ownership transfer with `move`) and is therefore normative. A worklist algorithm over the strongly connected components of
the type graph is a conforming method.

## 10.4 Ownership transfer with `move`

Consuming a binding `x` of type `T` either duplicates or transfers its value:

```text
consume x:
    Copy(T)   => duplicate value, x remains live
    !Copy(T)  => transfer ownership, x becomes dead (definitely released; see **Conditional release**)
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
- list element reads (a list-pattern projection).

Syntactically, `move` names a complete local binding.

To extract owned components, the complete owner must first be consumed by destructuring (Ownership and destructuring).

## 10.5 Fresh *Unique* values

A freshly produced *Unique* value already carries fresh ownership and has no existing local owner to invalidate.

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

A plain parameter accepts only a *Copy* argument type. The argument is passed by ordinary value semantics and may be copied.

Passing a *Unique* value to a plain parameter is a compile-time error.

The top type `any` is the sole exception (The top type `any`): a plain parameter of type `any` accepts any argument type. A *Copy* argument is coerced into the `any` and may be copied; a *Unique* argument must be written with explicit `move` at the call site, and its ownership transfers into the `any`.

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

Inside the callee, a borrowed *Unique* value may be read, matched non-consumingly, have members read, and be passed to another compatible `borrow` parameter.

It may not be moved, explicitly dropped, returned as an owned value, or stored into an owning location.

### Move parameters

```stilla
const builtin = import("builtin");

fn consume(move file: File) -> void {
    builtin.print(file.path);
}
```

A `move` parameter is an owner inside the callee.

An existing *Unique* local owner must be transferred explicitly:

```stilla
consume(move file);
```

A fresh *Unique* expression transfers implicitly:

```stilla
consume(open_file("data.txt"));
```

Calling an ownership-taking parameter with an existing *Unique* owner without `move` is a compile-time error.

For *Copy* types, `move` is semantically equivalent to an ordinary copy: it has no observable ownership effect, does not invalidate the source binding, and may be omitted.

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

No function returns a borrowed value in v1.3: user-defined functions may not return a borrowed *Unique* value, and the standard-library reads are no exception. A value read through a borrow — a boxed payload or a list element — is therefore returned by value only when its type is *Copy*; reading a *Unique* payload or element requires consuming its container (Box construction and unboxing, List).

## 10.8 Box construction and unboxing

A box is written by construction and read by ownership extraction.

```stilla
builtin.box(move value)   // wrap: take ownership of the payload
builtin.unbox(move boxed) // unwrap: return ownership of the payload
```

`builtin.box(move value)` constructs a `box[T]` owning `value`; a fresh *Unique* expression transfers implicitly, an existing owner requires `move` (Ownership transfer with `move`).

`builtin.unbox(move boxed)` consumes the complete box and returns ownership of the contained value.

There is no non-consuming box read. Stilla has no borrowed return values (Borrow lifetime rule), so a boxed payload is obtained only by consuming its box. For a *Copy* payload the box is itself *Copy* (Composite ownership), and `builtin.unbox(boxed)` may omit `move`: it returns an ordinary copy and the source box remains usable. A *Unique* payload can only be extracted by `builtin.unbox(move boxed)`.

## 10.9 *Unique* temporaries

When a *Unique* temporary is destroyed at runtime — at the end of the containing full expression, in reverse creation order, unless interrupted by panic — is defined in the Runtime specification.

## 10.10 Conditional release

A **conditional construct** is an `if`/`else` expression (`if`), a `match` expression (`match`), or a short-circuit `and`/`or` operand (Evaluation order).

Let `v` be a *Unique* local binding whose scope encloses a conditional construct `C`. If any normal-control-flow path through `C` **releases** `v` — by `move` (Ownership transfer with `move`), explicit `drop` (Explicit destruction), or a consuming destructure of its whole owner (Ownership and destructuring) — and some other normal path does not, then `v` is **maybe-unique**: it may not be used, borrowed, moved, or dropped afterward (compile-time error, use-after-move; see **Unique values**). Before the paths join, the compiler destroys `v` on every completing edge that did not release it, so ownership is uniformly dead after the join.

Consequently, after a conditional construct `C`, every *Unique* binding whose scope encloses `C` is either **definitely owned**, **maybe-unique**, or **definitely released**:

- a definitely-owned binding behaves normally: it may be borrowed, moved, dropped, or automatically destroyed at scope end;
- a maybe-*Unique* binding is released on some but not all normal-control-flow paths: it may not be used, borrowed, moved, or dropped afterward, and the compiler destroys it on each non-consuming edge before the join;
- a definitely-released binding was released on every normal path: it may not be used, borrowed, moved, or dropped afterward, and is not automatically destroyed at scope end; any such use is a compile-time error (use-after-move; see **Unique values**).

Notes:

- A consuming match `match (move v)` releases `v` on every path and is unconditional; this rule governs only moves of *enclosing* bindings that occur inside arm bodies.
- Borrowing does not participate: a borrow never releases (Parameter modes, Borrow lifetime rule).
- Panic and trap paths are not normal control flow (the Runtime specification) and neither satisfy nor violate the release requirement; no destruction runs as a consequence of termination.

## 10.11 Implicit consumption positions

`move` is the explicit consume operator (Ownership transfer with `move`), but ownership is
transferred implicitly in **consuming positions** — positions that require
an owned value:

- a move-mode call argument — a fresh *Unique* expression transfers
  directly; an existing local owner requires `move` (Parameter modes);
- a struct, union-variant, tuple, or list literal slot — a fresh *Unique*
  expression is owned by the constructed value; an existing local owner
  requires `move`;
- a `let` binding with an identifier pattern — a fresh *Unique* expression
  is owned by the new binding; an existing local owner requires `move`;
- a function's final expression when the return type is *Unique* — the
  value is returned by ownership, and an existing local owner in final
  position transfers implicitly, because the binding ends with the
  return (Return values);
- a coercion of a *Unique* value to `any` — the pack consumes the source
  (The top type `any`).

In every consuming position **except the return position** (whose implicit
transfer is listed above), an existing *Unique* local owner is
transferred only with an explicit `move`; a fresh *Unique* expression
transfers implicitly (Fresh *Unique* values); and a borrowed value never transfers
(Borrow lifetime rule). Storing an existing *Unique* owner without `move` in a
non-return consuming position is a compile-time
error (Stilla Core Static Semantics, *Ownership*).

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

When type arguments are inferable from context — from the payloads, or
from the expected instantiation of the same declaration (Inferred
specialization) — they may be omitted:

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

Every recursive storage cycle must pass through indirection such as `box[T]`, `list[T]`, or a function type (Composite ownership).

The *Unique* classification of recursive types follows the least-fixpoint rule of **Composite ownership**.

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
empty tuple `()` is the sole `void` value. A single-element tuple type
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

`list[T]` holds any element type — including *Unique* values, which is what distinguishes it from the *Copy*-element standard-library containers (`array[T]`, `hashmap[K, V]`).

A list element is read by **list matching**: a non-consuming `[h, ..t]` pattern reads the head as a borrowed view of a *Unique* element (or a copy of a *Copy* element), and consuming forms — `list.head` or a consuming destructuring match (Ownership and destructuring) — extract owned elements. A read cannot return a *Unique* element by value without consuming the list, and no function returns a borrowed value (Borrow lifetime rule), so no element read has a sound by-value signature for every `T`.

`list[T]` is the language's abstract sequence type. Concrete dense sequences such as `array[T]` are standard-library types, not keywords.

## 11.6 The top type `any`

`any` is the language's **top type**: every value type `T` — except
`hostdata` (The `hostdata` type) — coerces to `any`. The bottom type `never` has no
values and coerces to every type; `any` is the inverse — it accepts every
tagged value type and coerces to no other type (Stilla Core Static Semantics, *Typing*). `hostdata`
carries no runtime type tag, so it cannot be an `any` payload.

`any` may hold a value of any type:

```stilla
let a: any = 42;                    // Copy int32, copied in
let b: any = "hello";               // Copy str, copied in
let c: any = open_file("f");        // unique File, moved in (fresh value)
```

The coercion is implicit. A *Copy* source value is copied into the `any`; a
*Unique* source value must be moved — an existing *Unique* owner requires
explicit `move` at the coercion site, while a fresh *Unique* expression
transfers implicitly (Fresh *Unique* values) — and its ownership transfers into the `any`.

`any` is **unique** (Composite ownership): because it may hold a *Unique* value, an `any` value may be used at most once, must be destroyed exactly once, and is not implicitly copyable. `any` therefore does not appear in the *Copy* list of **Copy capability**, and containers of `any` — `list[any]`, `box[any]`, `tuple[..., any]` — are *Unique*.

An `any` value carries a **runtime type tag** recording its concrete payload type (the Runtime specification). The tag is deterministic and comparable; Stilla inspects it only through the two typed-recovery operations of **Recovery by `as`** and **Recovery by `match`**. No member access, list element read, operator, or equality is defined on `any` (Core operator typing and numeric conversion), and `any` does not coerce to any other type (Formal Static Semantics, *Typing*). Destruction of an `any` value destroys the tagged payload by the payload type's own destruction rules (Core specification, Runtime specification).

The primary uses are:

- **heterogeneous data** — *Unique* containers such as `box[any]` and `list[any]` can carry values of different types together;
- **typed recovery** — `as` (Recovery by `as`) and `match` type-test patterns (Recovery by `match`) recover a payload as a specific type, trapping on mismatch;
- **opaque pass-through** — a Stilla program may receive, store, and forward `any` values without inspecting them.

## 11.6.1 Recovery by `as`

An `any` value may be recovered by an `as` cast naming a concrete type:

```stilla
let b = a as int32;
```

The target type `T` must be a concrete Stilla type other than `any` and `never`; in generic code the target is the specialization of `T` (Generics). The cast reads the runtime tag:

- if the payload type is `T`, the payload is extracted;
- otherwise the program traps: **invalid `any` cast** (the Runtime specification). The trap terminates without unwinding (the Runtime specification), so no partial ownership state remains.

Ownership follows the target type, statically:

- if `T` is *Copy* (*Copy* capability), the payload is copied out and the source `any` remains definitely owned; the same value may be recovered again;
- if `T` is *Unique*, the source must be moved: `(move a) as T`. The complete `any` is consumed (Ownership transfer with `move`), ownership of the payload transfers to the result, and the source becomes definitely released (Conditional release);
- `hostdata` never appears in an `any` payload — it does not coerce to `any` (The top type `any`, The `hostdata` type) — so `as hostdata` is never a valid recovery.

## 11.6.2 Recovery by `match`

A `match` may test an `any` value with **type-test patterns**:

```stilla
match (a) {
    int32 n => ...,
    str s => ...,
    float32 f => ...,
    _ => ...          // required
}
```

A type-test pattern is a concrete type name, optionally followed by a binding identifier (Type-test pattern). It matches when the runtime tag equals that type. Because the tag space is open — any program may define new types — a `match` over an `any` value must include a wildcard `_` arm.

(The scrutinee is parenthesized per **`match`**.)

Binding mode follows **Borrowing and consuming matches**:

- in a non-consuming match `match (a)`, the scrutinee is borrowed: arm bindings are copies of *Copy* payloads, and a *Unique* payload cannot be extracted from a borrowed `any` — recovering a *Unique* payload requires the consuming form, `match (move a)`;
- in a consuming match `match (move a)`, the complete `any` is transferred: *Copy* arm bindings are copies, *Unique* arm bindings are owners of the extracted payload, and the wildcard arm discards the payload.

Type-test patterns may reference generic parameters; under monomorphization (Generics) they resolve to concrete tags.

## 11.7 The `hostdata` type

`hostdata` is a distinct nominal type carrying an **opaque, host-defined payload**. It is unrelated to `any` (The top type `any`): a `hostdata` value is created only by a host binding and leaves Stilla only by being handed back to the host or by destruction.

Only the host constructs `hostdata` values, through host functions and module members (**Host-provided modules**; the Runtime specification). No Stilla value coerces into `hostdata`, `hostdata` does not coerce into `any` (The top type `any`) or into any other type, and `hostdata` is not a top type.

Stilla defines no operation on `hostdata` other than moving, borrowing, storing, passing along, and handing to the host. No member access, list element read, operator, cast, pattern, equality, or hash is defined on `hostdata`, and it coerces to no other type (Core operator typing and numeric conversion).

`hostdata` is **unique** (Composite ownership): a `hostdata` value may be used at most once, must be destroyed exactly once, and is not implicitly copyable. `hostdata` does not appear in the *Copy* list of **Copy capability**, and containers of `hostdata` — `list[hostdata]`, `box[hostdata]`, `tuple[..., hostdata]` — are *Unique*.

Destruction of a `hostdata` value — automatic (the Core specification), explicit `drop` (the Core specification), or container destruction — returns the opaque payload to the host for disposal (the Runtime specification); this is host cleanup, not execution of a Stilla `drop` hook.

The primary uses are:

- **host bindings** — host-provided functions and module members may accept and return `hostdata` for opaque payloads;
- **opaque handles** — a host may hand a Stilla program a `hostdata` value wrapping a host-owned resource; Stilla tracks it with *Unique* ownership and hands it back without inspecting it;
- **host-bound buffering** — *Unique* containers such as `box[hostdata]` and `list[hostdata]` can carry opaque payloads that a Stilla program collects and forwards to the host as a whole.

## 11.8 Host-backed opaque nominal types

A standard-library or host-provided module may declare a **host-backed opaque nominal type** (Grammar `opaque-def`):

```stilla
opaque type Array[T];
```

Such a declaration creates a nominal type with **no fields, no variants, and no Stilla-visible representation**: the host defines the storage, the operations, and the destruction of every value. Stilla knows only the type's identity, its type arguments, and its ownership; it can never inspect or construct a value itself. Only the host constructs values of the type, through the declaring module's host bindings (Host-provided modules; the Runtime specification).

The declaration form is restricted to module interfaces: **a Stilla source module may not declare an opaque type**. The feature exists so that libraries that need strong abstraction can depend on host-provided opaque interfaces rather than on source-defined structs; it is not general-purpose visibility control (Deliberate omissions). The type itself, however, is a first-class nominal type usable from any module that imports the declaring one.

Ownership is **declared, not structural**: every opaque type is *Unique* (*Unique* values), irrespective of its type arguments — `Array[int32]` is *Unique* even though `int32` is *Copy* (Copy capability). The value may be moved, borrowed, stored, passed along, and handed to the host, and is never implicitly copyable.

Stilla defines no construction or inspection operation on an opaque value:

- **raw construction** (Raw struct construction) does not apply — an opaque type is not a struct, so `Array{ … }` is a compile-time error;
- **member access** does not apply — an opaque type has no fields, so `a.length` is a compile-time error;
- **destructuring** does not apply — an opaque value is not matchable by struct pattern and has no payload to unpack.

In every other value position an opaque value behaves like any other nominal value: it may be a plain, `borrow`, or `move` parameter; a return value; an element of `list`, `box`, or `tuple`; and a payload of the top type `any` (The top type `any`) — an opaque value coerces to `any` like any other tagged value type, carrying its nominal type identity in the tag, and is recovered with the ordinary `as` / `match` recovery operations. `move`, `borrow`, and `drop` of an opaque value are ordinary.

Destruction of an opaque value — automatic, explicit `drop`, or container destruction — dispatches to the **host type's destructor** (the Runtime specification): the runtime calls the host-side destruction routine named by the type's host identity, which releases the backing resources. This is host cleanup, not execution of a Stilla `drop` hook (the Runtime specification).

The distinction from `hostdata` (The `hostdata` type) is one of type identity:

| | `hostdata` | opaque host type |
| --- | --- | --- |
| type identity | one untyped payload type | a distinct nominal type per declaration (`Array[int32]`, …) |
| type arguments | none | generic (`Array[T]`) |
| ownership | always *Unique* | *Unique* by declaration |
| Stilla-visible representation | none | none |
| raw construction | never | compile-time error |
| fields / destructuring | none | none |
| coercion to `any` | **not allowed** (The top type `any`) | allowed, like any nominal type |
| destruction | host payload disposal | host type destructor by host identity |
| intended use | opaque handle pass-through | stdlib / native abstractions (`array`, `hashmap` — the Standard Library) |

`hostdata` is the type-erased form — "the host knows what this is, Stilla does not". An opaque host type is the nominal form — "the compiler knows this is an `Array[int32]`, but not how it is stored".

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
a generic named type: a parameter such as `a: Array[T]` (the Standard Library) carries `T` only inside the named type's argument list, and a value of
that named type exposes no instantiation information, so `T` cannot be
inferred there and must be written explicitly with `::[...]` (Explicit specialization).
There is likewise no inference from an expected result type for generic
*function* calls in v1.3: a generic call with no type-carrying argument —
for example `hashmap.empty()` (the Standard Library) — requires explicit
type arguments. The one exception is **union-variant construction**: a
variant constructor whose payloads leave some type parameter unconstrained
fills it from the expected instantiation of the same union declaration —
the enclosing function's return type, a `let` type annotation, or an
`if`/`match` result goal. The Standard Library relies on this when
`try_fold` writes `Result::Complete(..)` / `Result::Break(..)` against a
`Result[S, R]` return type (the Standard Library).

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
type argument from the argument expressions (Inferred specialization) — for example
`array.get::[int32](a, 2)` and `hashmap.empty::[str, int32]()` (the Standard Library).

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
argument types (Inferred specialization) or written explicitly (Explicit specialization) — and an explicit
specialization in value position is a first-class monomorphic function
value:

```stilla
let v = identity::[int32](42);
let f = identity::[int32];
```

`f` has the monomorphic type:

```stilla
fn(move int32) -> int32
```

For a *Copy* `int32`, the `move` mode has no observable ownership effect, but
it remains part of the function type.

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

Destructuring a *Unique* rvalue transfers ownership into *Unique* pattern bindings.

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

This is the supported way to decompose *Unique* aggregate ownership **when the aggregate type does not define its own `drop` hook**.

A struct that defines `drop` may be destructured only through a borrowing pattern. Consuming destructuring of such a struct is a compile-time error, because moving out its fields would conflict with the struct's own destruction lifecycle.

Direct partial movement such as:

```stilla
move pair.first
```

is illegal.

## 14.7 Type-test pattern

A type-test pattern matches an `any` value (Recovery by `match`):

```stilla
int32 n
str s
File f
list[int32] xs
tuple[int32, str] t
_              // the required wildcard for `any`
```

The pattern is a concrete type name, optionally followed by a binding identifier. It matches when the runtime tag equals that type. It is refutable and is accepted only by `match` (`match`), and only for a scrutinee of type `any`. A test type with a *Unique* payload may be bound only in a consuming match, `match (move a)` (Recovery by `match`). Under monomorphization (Generics) generic parameters resolve to concrete tags. A `match` over an `any` value must include a wildcard `_` arm (Recovery by `match`).

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

Bitwise (the four integer types only, Core operator typing and numeric conversion):

```text
&  |  ^
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
4. `|`
5. `^`
6. `&`
7. `<< >>`
8. `+ -`
9. `* / %`
10. unary `- ! move`
11. `as`
12. postfix operations

The three bitwise levels differ from each other like C and Python
(`|` loosest, `&` tightest): `a | b ^ c` parses as `a | (b ^ c)` and
`a & b | c` as `(a & b) | c`. All three bind tighter than comparisons
(`a & b == c` is `(a & b) == c`) and looser than shifts (`a & b << c`
is `a & (b << c)`). All binary operator levels are left-associative.

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

Stilla uses a single deterministic evaluation-order rule; it is defined in the Runtime specification:

> **Unless a construct explicitly states otherwise, subexpressions are evaluated exactly once from left to right in source order.**

## 16.3 Core operator typing and numeric conversion

Core arithmetic is defined as follows:

- `int32 + - * / % int32 -> int32`;
- `uint32 + - * / % uint32 -> uint32`;
- `i64 + - * / % i64 -> i64`;
- `u64 + - * / % u64 -> u64`;
- `float32 + - * / % float32 -> float32`;
- `f64 + - * / % f64 -> f64`;
- `int32 & | ^ int32 -> int32`;
- `uint32 & | ^ uint32 -> uint32`;
- `i64 & | ^ i64 -> i64`;
- `u64 & | ^ u64 -> u64`;
- `int32 << >> int32 -> int32`;
- `uint32 << >> uint32 -> uint32`;
- `i64 << >> i64 -> i64`;
- `u64 << >> u64 -> u64`;
- `str + str -> str`;
- unary `-` accepts `int32`, `uint32`, `i64`, `u64`, `float32`, or `f64`;
- `!`, `and`, and `or` accept `bool`;
- `< <= > >=` accept operands of the same numeric type;
- `== !=` are required for `byte`, `int32`, `uint32`, `i64`, `u64`, `float32`, `f64`, `bool`, and `str`.

Integer `/` truncates toward zero. Integer `/` and `%` by zero trap
(the Runtime specification). `int32` and `uint32` arithmetic is performed
modulo 2³² and never traps on overflow or underflow (WebAssembly semantics,
the Runtime specification); `i64` and `u64` arithmetic is performed modulo
2⁶⁴ and never traps on overflow or underflow (WebAssembly semantics
extended to 64 bits). `int32` division does not trap on overflow —
`int32_min / -1` wraps modulo 2³² to `int32_min` (WebAssembly-style
wrapping), while `int32` remainder never overflows — `int32_min
% -1` is 0 (WebAssembly semantics); `i64` division traps on
`i64_min / -1`, while `i64` remainder does not — `i64_min % -1` is 0.
Unary `-` on `int32` wraps on
the minimum value (`int32_min` negated is `int32_min`, modulo 2³²); on
`uint32` it computes the two's-complement negation (`0 - x`), which never
traps; on `i64` it wraps on the minimum value (`i64_min` negated is
`i64_min`, modulo 2⁶⁴); on `u64` it computes the two's-complement negation
(`0 - x`), which never traps (the Runtime specification). Float arithmetic
follows IEEE 754 for the respective format, and `float32 %`/`f64 %` are the
truncated remainder `a - trunc(a / b) × b` (C `fmod`,
Rust `%`) — they never trap, not even on a zero divisor (the Runtime
specification).

`<<` and `>>` are the left and right shifts, defined for the four integer
types only (`byte` has no arithmetic, and the float types have no bit
pattern to shift — Core operator typing and numeric conversion). For the
32-bit types the shift count is the right operand's value **modulo 32**
(WebAssembly semantics): only the low five bits of the count participate,
so shifting by a count ≥ 32 is identical to shifting by `count mod 32`,
and a negative count shifts by its low five bits (`-1` is 31). For `i64`
and `u64` the count is taken **modulo 64**: only the low six bits
participate, so shifting by a count ≥ 64 is identical to shifting by
`count mod 64`, and a negative count shifts by its low six bits (`-1` is
63). Shifting never traps. `>>` on `int32`/`i64` is
the arithmetic shift (the vacated high bits are filled with the sign
bit); `>>` on `uint32`/`u64` is the logical shift (filled with zero). `<<`
shifts zero bits into the vacated low positions for all four types, and bits
shifted out of the operand width are discarded (the Runtime
specification).

`&`, `|`, and `^` are the bitwise and, or, and exclusive-or, defined for
the four integer types only (same-type operands, the result is the
operand type; `byte` has no arithmetic and the float types have no bit
pattern — Core operator typing and numeric conversion). They operate on the raw
operand-width patterns: `int32` and `uint32` are bit-identical in their
32-bit patterns, `i64` and `u64` bit-identical in their 64-bit patterns
(signedness is irrelevant — masking, setting, or toggling bits never
interprets the pattern as a number), so `x & y` is the same operation for
both signednesses of a width.
Bitwise operations never trap and never overflow: every bit of the
result is defined by the operands alone, and the result is the pattern
modulo 2³² or 2⁶⁴ (the Runtime specification).

The Stilla v1.3 core does not define equality for `any`, functions, structs, unions, tuples, lists, boxes, or modules. Libraries may provide explicit equality helpers.

No operator is defined on `hostdata` (The `hostdata` type), and none is defined on `any` other than `as` and `match` type-testing (The top type `any`): an `any` value can be moved, borrowed, stored, passed along, handed to the host, recovered by `as`, and tested by `match`.

Core `as` conversions are the uniform conversion family: every
non-identity pair of the seven conversion types `{byte, int32, uint32,
i64, u64, float32, f64}` is legal:

```text
byte as int32       int32 as byte
byte as uint32      int32 as uint32
byte as i64         int32 as i64
byte as u64         int32 as u64
byte as float32     int32 as float32
byte as f64         int32 as f64
uint32 as int32     i64 as byte
uint32 as byte      i64 as int32
uint32 as i64       i64 as uint32
uint32 as u64       i64 as u64
uint32 as float32   i64 as float32
uint32 as f64       i64 as f64
float32 as int32    u64 as byte
float32 as uint32   u64 as int32
float32 as i64      u64 as uint32
float32 as u64      u64 as i64
float32 as byte     u64 as float32
float32 as f64      u64 as f64
f64 as int32
f64 as uint32
f64 as i64
f64 as u64
f64 as float32
f64 as byte
any as T        // T a concrete type, T ≠ any, never, hostdata (the Core specification)
```

No other core conversion is implied by `as`.

An integer literal has type `int32`, and a float literal has type
`float32` (Grammar `integer`, `float`). Stilla defines no literal suffix
forms and no implicit numeric conversion; a `byte` value is written with
an explicit conversion, for example
`104 as byte`. Integer and float
literals use the same
**explicit type context** rule: in a position whose
expected type is uniquely an integer or float type — a typed binding,
parameter,
field, element, variant payload, return position, or the other operand of
a numeric binary operator (`+`, `-`, `*`, `/`, `%`, `<<`, `>>`, `&`, `|`,
`^`, `==`, `!=`, `<`, `<=`, `>`, `>=`), on either side — an integer literal
is typed at the expected integer width (`int32`, `uint32`, `i64`, or
`u64`) and a float literal at the expected float width (`float32` or
`f64`), and its decimal magnitude is parsed
directly at the target width. A `u64` literal covers the full range
`0..18446744073709551615` (`0xffff_ffff_ffff_ffff`) and is never parsed
through an intermediate
`i64`. An `i64` literal covers magnitudes up to and including `2⁶³`
(`9223372036854775808`), one beyond the positive range, so that the unary
negation of it constructs `i64_min` — `-9223372036854775808` is
`i64_min`, never a range error. A `uint32` literal covers magnitudes up to
`2³² - 1` (`4294967295`). The leading `-` is unary negation
(Grammar), never part of the
literal payload: `-1` in a `u64` context is the wrapping negation of
`u64(1)` (`0xffff_ffff_ffff_ffff`), and a literal whose magnitude fits no
expected type is a compile-time error. A float literal in an explicit
`f64` context is rounded directly to binary64 at the target width
(round-to-nearest, ties-to-even) — it is never rounded to binary32
first; in an `f32` context and in every context without an explicit
float type, float literals keep their `float32` default. In every
position without an
explicit integer or float type context, integer literals keep their
`int32` default
and float literals their `float32` default.

Conversion is total: numeric casts never
trap. The integer casts are bit-pattern operations: `int32 as byte`
and `uint32 as byte` truncate to 8 bits (the value modulo 2⁸, low
bits); `int32 as uint32` and `uint32 as int32` reinterpret the low
32 bits; `byte as int32`/`byte as uint32` zero-extend; `i64 as u64`
and `u64 as i64` reinterpret the full 64-bit cell. The 32↔64 integer
casts widen and narrow the low bits: `int32 as i64` and
`int32 as u64` sign-extend the low 32 bits (two's-complement
conversion — `-1 as u64` is `2⁶⁴ − 1`), `uint32 as i64` and
`uint32 as u64` zero-extend them, `byte as i64` and `byte as u64`
zero-extend the low 8 bits, and `i64 as int32` / `i64 as uint32` /
`u64 as int32` / `u64 as uint32` keep the low 32 bits (`i64 as byte`
and `u64 as byte` the low 8 bits). The float→int
casts truncate toward zero and saturate to the target range on NaN
or out-of-range values (NaN becomes zero): `float32 as int32`
saturates to the `int32` range, `float32 as uint32` to `[0, 2³²)`,
`float32 as i64` to the `i64` range, `float32 as u64` to
`[0, 2⁶⁴)`, and the byte forms to `[0, 255]`; the `f64` forms follow
the same rules at binary64 precision. The int→float casts round to
nearest, ties-to-even; precision may be lost — `i64 as f64` and
`u64 as f64` round values beyond 2⁵³. `float32 as f64` is exact —
every binary32 value is representable in binary64 — and `f64 as
float32` rounds to nearest, ties-to-even, with a finite source whose
magnitude exceeds the binary32 range converting to ±infinity (IEEE
overflow), never saturating and never trapping (the Runtime
specification).

`as` is not extended to `hostdata`: no cast is defined from or to `hostdata` (The `hostdata` type).

The runtime behavior of these operations — IEEE 754 representation and arithmetic, floating equality, division traps, and invalid `any`-recovery traps — is defined in the Runtime specification.

---

## See also

- [Stilla Core Language Specification](Stilla%20Core%20Language%20Specification.md) — language structure: modules, bindings, functions, control flow
- [Stilla Core Static Semantics](Stilla%20Core%20Static%20Semantics.md) — the normative formal static semantics
- [Stilla Core Grammar Draft.abnf](Stilla%20Core%20Grammar%20Draft.abnf) — the normative lexical and syntactic grammar
- [Stilla Runtime Specification](Stilla%20Runtime%20Specification.md) — execution behavior
