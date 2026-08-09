# Stilla Core Static Semantics

> **Version:** v1.3 Draft

This document is the normative **formal static semantics** of the Stilla core
language. It is one of three companion files:

- [Stilla Core Language Specification](Stilla%20Core%20Language%20Specification.md) — language structure: modules, bindings, functions, control flow.
- [Stilla Core Types & Ownership Specification](Stilla%20Core%20Types%20%26%20Ownership%20Specification.md) — values and ownership.
- **This file** — the normative formal static semantics.

Where these and the other Stilla specs overlap on execution behavior, the
Runtime specification governs.

## Table of Contents

 1. [Formal Static Semantics](#18-formal-static-semantics)

---

# 18. Formal Static Semantics

A conforming implementation must enforce the following rules.

## Binding

A local binding is immutable after creation.

## Shadowing

A new local binding may shadow an existing binding.

## Typing

Function arguments and return values must match exactly unless the source type is `never`, the required type is the top type `any`, or a transparent `type` alias expands to the required type (The top type `any`).

`any` carries a runtime type tag identifying its payload type; recovery requires naming the type explicitly, via `a as T` (Recovery by `as`) or a `match` type-test pattern (Recovery by `match`). Stilla defines no equality on `any`. `hostdata` is opaque and tagless; no cast, pattern, or equality is defined on it (The `hostdata` type). A host-backed opaque nominal type has no fields or variants (Opaque host types): it is *Unique* by declaration, may be moved, borrowed, stored, and `any`-packed, and may not be constructed from raw data, accessed by field, or destructured in source.

## Conversion

No implicit numeric or `str` conversions exist.

Coercion to the top type `any` is the sole implicit widening (The top type `any`), and
`hostdata` does not participate: no value coerces into `hostdata`, and
`hostdata` does not coerce into `any` (The `hostdata` type).

## Closures

A function or lambda may not reference local bindings belonging to an enclosing function scope.

## Functions

Functions are order-independent within a module; direct and mutual recursion are permitted (Order and recursion). Every function in a recursion cycle declares its return type explicitly. Module constant initialization must not transitively read a later-declared module constant (Module Constants).

## Path aliases

A `using` declaration introduces a scoped compile-time alias for a path
(Path aliases with `using`): it is visible from its declaration point to the end of the
enclosing module or block, may shadow and be shadowed like `let`, is not a
runtime member, and requires its path to resolve.

## Match

A match over a union must be exhaustive.

A non-consuming match of a *Unique* value borrows the scrutinee and produces borrowed *Unique* bindings.

Recovering a *Unique* payload from an `any` requires a consuming match, `match (move a)` (Recovery by `match`).

A `match (move owner)` consumes the complete owner and may produce owning payload bindings, except that a struct defining its own `drop` hook cannot be consumingly destructured into fields.

## Patterns

`let` requires an irrefutable pattern.

Refutable patterns are accepted only by `match` in Stilla v1.3.

A struct pattern over an opaque host type is a compile-time error (Opaque host types).

## Ownership

A *Unique* owner may be borrowed any number of times, moved at most once, and destroyed at most once.

Use after move or destruction is a compile-time error.

If a binding is released on some but not all normal paths through a conditional construct, it becomes **maybe-unique** and is unusable after the join; the compiler inserts destruction on every non-consuming edge before the join (Conditional release). A definitely-released binding is unusable and is not automatically destroyed at scope end.

Consuming positions (Implicit consumption positions): a struct, union-variant, tuple, or list
literal slot, a `let` binding with an identifier pattern, a move-mode
call argument, and the return position of a function whose return type is
*Unique* transfer ownership implicitly for a fresh *Unique* expression; an
existing *Unique* local owner in final (return) position transfers
implicitly, because the binding ends with the return; an existing *Unique*
local owner in any other consuming position must be moved
with explicit `move`, and storing it without `move` is a compile-time
error.

## Whole-owner rule

Explicit ownership movement operates on complete local owners.

Direct partial movement from fields or list element reads is forbidden.

Consuming destructuring of a struct that defines its own `drop` hook is forbidden.

## Borrowing

`borrow` never transfers ownership.

A borrowed *Unique* value cannot be moved, dropped, returned as owned, or stored into an owning location.

Borrow lifetimes are lexically bounded; Stilla v1.3 has no user-visible lifetime parameters and no user-defined borrowed *Unique* return values.

## Parameters

A plain parameter accepts only *Copy* argument types.

The top type `any` is the sole exception (Parameter modes): a plain `any` parameter
accepts any argument type — a *Copy* argument coerces into the `any`, and a
*Unique* argument must be written with explicit `move` at the call site,
with its ownership transferring into the `any`.

A `borrow` parameter receives a non-owning view and leaves the caller's ownership unchanged.

A `move` parameter receives ownership.

Passing an existing *Unique* local owner to a `move` parameter requires `move owner` at the call site.

A fresh *Unique* value may transfer directly without an explicit `move` token.

## Destruction

Every live *Unique* local owner is destroyed when its scope ends during normal control flow unless it has already been moved or explicitly dropped.

*Unique* temporaries are destroyed at the end of their full expression in reverse creation order during normal control flow (the Runtime specification).

## User drop hook

A struct may define at most one `drop` lifecycle declaration.

The hook cannot be called directly.

Its destruction-view argument cannot be moved, dropped, returned, or used to transfer field ownership.

## Structural destruction

After a struct's user hook completes normally, *Unique* fields are destroyed in reverse declaration order (the Runtime specification).

## Opaque host types

An opaque host type is declared only by a standard-library or host-provided module interface (Host-backed opaque nominal types).

An opaque value is *Unique* by declaration, irrespective of its type arguments.

No construction, member access, or destructuring is defined on an opaque value: a struct literal, variant construction, member access, struct pattern, or consuming destructure over an opaque type is a compile-time error.

An opaque value may be a plain, `borrow`, or `move` parameter; a return value; an element of `list`, `box`, or `tuple`; and an `any` payload, recovered with the ordinary `as` / `match` operations.

Destruction of an opaque value dispatches to the host type's destructor (the Runtime specification); an opaque type has no user `drop` hook.

## Panic and traps

Panic and runtime traps terminate the current Stilla execution context without unwinding (the Runtime specification).

Stilla does not execute pending local, temporary, field, or module destruction as a consequence of such termination.

Host cleanup after termination is outside Stilla source semantics.

## Evaluation order

Unless explicitly stated otherwise, subexpressions are evaluated exactly once from left to right (the Runtime specification).

`and` and `or` short-circuit (the Runtime specification).

## Recursion

Recursive value types must contain indirection on every recursive storage cycle, and their ownership classification follows the least-fixpoint rule of **Composite ownership**.

Iteration is expressed as self-recursion; a conforming implementation must reuse the caller's frame for a direct self-recursive call in tail position (**Iteration**; `air.md`), so self-recursive iteration does not grow the stack. Mutual recursion and non-tail recursion may grow the stack, bounded by implementation-defined resources.

## Teardown

A *Unique* module constant whose type defines a `drop` hook must not read —
directly or through any transitively called function — a module constant
declared later than the constant being destroyed, because teardown
destroys constants in reverse declaration order and a later constant is
already destroyed when the hook runs (**Module Constants**; the Runtime specification).

## Modules

Each resolved module is instantiated at most once per execution context (the Runtime specification).

Each module has a compiler-generated nominal struct type with ordinary immutable record/member semantics; there is no separate runtime module type category.

Values of these generated module structs are module-resident and may appear only in module-level `const` bindings.

## Imports

Import specifiers must be statically known string literals.

`import(...)` may appear only as a module-level `const` initializer.

## Constructors

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

A specialized generic is a first-class monomorphic function value
(`identity::[int32]`; see Stilla Core Types & Ownership Specification); the AIR carries one monomorphic function per
used specialization, never the unspecialized template.

`value::[Types]` is compile-time specialization syntax, not runtime dispatch.

Type arguments are inferred structurally from the call's argument
expressions (Stilla Core Types & Ownership Specification); a type argument carried only inside a generic named
type's argument list, and a call with no type-carrying argument, require
explicit `::[...]` specialization (Stilla Core Types & Ownership Specification).

---

## See also

- [Stilla Core Language Specification](Stilla%20Core%20Language%20Specification.md) — language structure: modules, bindings, functions, control flow
- [Stilla Core Types & Ownership Specification](Stilla%20Core%20Types%20%26%20Ownership%20Specification.md) — values and ownership
- [Stilla Core Grammar Draft.abnf](Stilla%20Core%20Grammar%20Draft.abnf) — the normative lexical and syntactic grammar
- [Stilla Runtime Specification](Stilla%20Runtime%20Specification.md) — module instantiation, evaluation order, runtime destruction, termination, and the embedding-host contract
