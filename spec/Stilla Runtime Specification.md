# Stilla Runtime Specification

> **Version:** v1.3 Draft
>
> **Companion document:** *Stilla Core Language Specification* — defines the syntax and compile-time constraints of the language.

## Table of Contents

1. Introduction
2. Module Instantiation
3. Host Environment
4. Required `builtin` Interface
5. Evaluation Order
6. Destruction at Runtime
7. Termination and Traps
8. Core Runtime Model

---

# 1. Introduction

## 1.1 Scope

This document — the **Runtime specification** — defines the Stilla v1.3 execution model and the contract between a Stilla program and its embedding host. It covers:

- the execution context;
- module instantiation, storage, initialization, references, and teardown;
- the host environment: host-provided modules, the `builtin` module contract, and the entry point;
- deterministic evaluation order;
- destruction at runtime;
- panic, traps, and termination.

Syntax and compile-time constraints — the type system, ownership checking, generic specialization, and the static module rules — are defined in the companion **Core specification**, whose normative grammar is defined in the standalone [`Stilla Core Grammar Draft.abnf`](Stilla%20Core%20Grammar%20Draft.abnf). This specification is normative for all conforming implementations.

## 1.2 Relationship to the Core specification

- The Core specification defines what a conforming compiler must accept and reject.
- This specification defines what a conforming implementation must do when the program runs, and what the embedding host must provide.
- Where a behavior is described in both documents, the Runtime specification governs execution and the Core specification governs what the compiler must accept and reject.

The boundary between the two documents is drawn at the point where a program transitions from a static artifact into a running execution context.

## 1.3 Execution context

A Stilla program runs inside an **execution context**.

The execution context:

- is created by the embedding host (Host Environment);
- owns all module storage (Module Instantiation);
- is the unit of panic termination (Termination and Traps);
- is disposed of by the embedding host (Host integration contract).

When a context begins relative to host lifecycle, and whether multiple contexts may run concurrently, is implementation-defined.

## 1.4 Key terminology

These terms are used throughout this specification. Language-level terms (binding, *Unique*, borrow, move, drop, etc.) are defined in the Core specification.

- **execution context** — the unit of program execution created by the host; it owns module storage and is terminated as a whole by panic (Execution context, Termination and Traps).
- **module storage** — the immutable storage of an instantiated module (Module storage).
- **module instantiation** — creating module storage for a resolved specifier (At most once per context).
- **teardown** — normal-context destruction of module-owned *Unique* constants in reverse initialization order (Teardown).
- **embedding host / host** — the environment that creates the execution context, registers host-provided modules, invokes entry points, and receives control after termination (Host Environment).
- **host-provided module** — a module implemented by the host that exposes a statically known Stilla-compatible interface (Host-provided modules).
- **runtime trap** — a deterministic runtime failure such as overflow, division by zero, invalid indexing, or invalid conversion (Runtime traps and numeric behavior).

## 1.5 Conformance

A conforming implementation must:

- instantiate each resolved module at most once per execution context (At most once per context);
- initialize module constants in declaration order (Initialization) and destroy module-owned *Unique* constants during normal teardown (Teardown);
- provide the required `builtin` interface (Required `builtin` Interface);
- evaluate subexpressions in the defined order (Evaluation Order);
- destroy values as specified (Destruction at Runtime);
- terminate on panic and runtime traps without unwinding (Termination and Traps).

---

# 2. Module Instantiation

## 2.1 At most once per context

A resolved module specifier is instantiated at most once per Stilla execution context.

Multiple imports of the same resolved module refer to the same module storage:

```stilla
const a = import("math");
const b = import("math");
```

`a` and `b` denote the same module instance.

## 2.2 Module storage

Module storage is immutable after initialization.

Its lifetime extends until the execution context ends.

Module storage follows the same immutable record/member-access model as structs (the Core specification): member access on module values is ordinary `.` access, and there is no separate runtime `module` type category.

## 2.3 Initialization

A module is initialized when it is instantiated.

Module constant initializers are evaluated strictly in declaration order (the Core specification).

An initializer may reference earlier module constants, imported modules, module functions, types, and imported standard-library modules such as `builtin`; it may not reference a later module constant (the Core specification).

Imported modules used by an initializer are instantiated as required; because each specifier is instantiated at most once per context (At most once per context) and specifiers must resolve unambiguously before execution (the Core specification), the resulting initialization is deterministic.

## 2.4 References and aliasing

`import("specifier")` produces a stable reference to the module instance for the current execution context (the Core specification).

The compiler preserves resolved module identity through statically known aliases:

```stilla
const math = import("math");
const public_math = math;
```

`public_math` denotes the same module storage as `math`.

Imported module references do not transfer ownership of module storage.

## 2.5 Teardown

Module-owned *Unique* constants are destroyed during **normal context teardown** in reverse initialization order.

Teardown runs only during normal termination of the execution context.

A panic or runtime trap performs no Stilla unwinding and does not execute pending module or local destruction hooks (Panic).

Host cleanup after termination is outside Stilla source semantics (Host integration contract).

## 2.6 Import resolution process

The argument to `import` must be a string literal, and `import(...)` may appear only as a module-level `const` initializer (the Core specification).

The compiler or runtime resolves the specifier to exactly one of:

1. a Stilla source module;
2. a standard-library module;
3. a host-provided module.

Resolution is implementation-defined, but a specifier must resolve unambiguously before execution.

Import cycles are rejected in Stilla v1.3.

The standard library is specified separately.

Host-provided modules are registered by the host before compilation or execution (Host-provided modules).

---

# 3. Host Environment

## 3.1 Host-provided modules

An embedding host may register modules before compilation or execution.

A host module must expose a statically known Stilla-compatible interface (the Core specification).

Conceptually:

```stilla
struct Database {
    query: fn(str) -> str;
    execute: fn(str) -> int32;
}
```

This structural illustration does not make module values ordinary first-class struct values. It means their runtime member layout follows the same immutable record/member-access model.

Source modules, standard-library modules, and host modules use the same `.` member-access syntax (the Core specification).

## 3.2 The `builtin` module

`builtin` is an ordinary importable standard-library module (the Core specification): a
program brings it into scope like any other module, for example

```stilla
const builtin = import("builtin");
```

There is no implicitly available module binding; the context instantiates
`builtin` on demand, exactly as it instantiates any other resolved
specifier (At most once per context, Import resolution process).

The required interface the host must provide is defined in **Required `builtin` Interface**.

## 3.3 Entry point

Stilla itself does not require a global entry-point syntax.

A standalone runtime conventionally loads an entry module and invokes:

```stilla
entry.main()
```

where normally:

```stilla
main: fn() -> void
```

is expected.

An implementation may define another entry signature.

An embedding host may directly invoke any exposed module function.

## 3.4 Host integration contract

Control returns to the embedding host/runtime:

- on normal termination, after context teardown (Teardown);
- on panic or runtime trap, immediately, without unwinding (Panic).

The host is responsible for disposing of the terminated execution context and any host-owned resources.

Such host cleanup is outside Stilla source semantics and must not be described as execution of Stilla `drop` hooks.

The host may register host-provided modules (Host-provided modules) and may directly invoke any exposed module function (Entry point).

An `any` value (the Core specification) is a type-erased payload with a runtime type tag: the tag is deterministic and comparable and identifies the concrete payload type. Stilla inspects the tag only through the two typed-recovery operations, `as` and `match` type-test patterns. Destruction of an `any` destroys the payload by the payload type's own destruction rules. An `any` argument to or result from a host binding is transferred as that opaque tagged payload.

A `hostdata` value (the Core specification) is an opaque, type-erased payload with no runtime type tag: its runtime representation is implementation- and host-defined, and Stilla performs no inspection or recovery on it. A `hostdata` value never appears as an `any` payload: the top type's tag space covers the tagged value types only. A payload leaves `hostdata` only when the complete value is passed to a host binding or destroyed. When Stilla destroys a `hostdata` value on normal control flow, the host is responsible for disposing of the opaque payload; such disposal is host cleanup and must not be described as execution of a Stilla `drop` hook. A `hostdata` argument to or result from a host binding is transferred as that opaque payload.

---

# 4. Required `builtin` Interface

Every conforming implementation must provide the following minimum interface. Programs reach it by importing the standard-library `builtin` module (the Core specification) and calling its members; each member is a host binding whose calls lower to system calls (see `docs/frontend.md`).

Stilla has no closures (the Core specification): a function or lambda may not capture enclosing local bindings. The list combinators live in the `iter` module (the Standard Library) — `each`, `each_with`, `fold`, `fold_with`, `consume_each`, `consume_each_with`, `consume_fold`, `consume_fold_with`, `try_fold`, `try_fold_with`. Each accepts the per-element operation as an ordinary function-value parameter — a monomorphic, non-capturing method — and the `*_with` variants additionally take a borrowed context value the operation may read. Method-passing and context threading are Stilla's compensation for the absence of closures.

## 4.1 Output

```stilla
builtin.print:
    fn(str) -> void
```

## 4.2 Conversion

Conceptually:

```stilla
builtin.str[T]:
    fn(T) -> str
```

Required supported types:

```text
byte
int32
uint32
float32
bool
str
```

Calling it with another type is a compile-time error unless the implementation explicitly extends the interface.

## 4.3 List length

```stilla
builtin.len[T]:
    fn(borrow list[T]) -> int32
```

The list is borrowed and never consumed.

## 4.4 Integer range

```stilla
builtin.range:
    fn(int32, int32) -> list[int32]
```

The range is inclusive:

```text
[start, end]
```

If:

```text
start > end
```

the result is an empty list.

## 4.5 Box

```stilla
builtin.box[T]:
    fn(move T) -> box[T]
```

A fresh *Unique* expression transfers implicitly:

```stilla
builtin.box(Tree[int32]::Empty)
```

An existing *Unique* owner requires `move` (the Core specification).

## 4.6 Peek and unbox

Borrowing access:

```stilla
builtin.peek[T]:
    fn(borrow box[T]) -> <borrowed T>
```

`<borrowed T>` is notation in this specification for a transient non-owning result. It is not a storable source-level type in Stilla v1.3; in the standard-library source (`std/builtin.st`) the binding is declared with the ordinary spelling `fn(borrow box[T]) -> T`, and the frontend's lowering produces the borrowed view for the result.

For *Unique* `T`, the result lives until the end of the enclosing full expression and is subject to the Core specification.

Ownership extraction:

```stilla
builtin.unbox[T]:
    fn(move box[T]) -> T
```

For an existing *Unique* box:

```stilla
builtin.unbox(move boxed)
```

consumes the box as a whole and returns ownership of `T`.

For a fresh box expression, explicit `move` is unnecessary. If `box[T]` is *Copy*, `builtin.unbox(boxed)` is also valid and returns a copy without invalidating the source box.

For *Copy* `T`, implementations may return an ordinary copy from `builtin.peek`.

## 4.7 Panic

```stilla
builtin.panic:
    fn(str) -> never
```

`builtin.panic` terminates the current Stilla execution context.

Stilla v1.3 defines **no exception-style or destructor-style unwinding** for panic or runtime traps. The full termination semantics are defined in **Panic**.

## 4.8 Assert

```stilla
builtin.assert:
    fn(bool, str) -> void
```

`builtin.assert(condition, message)` is an ordinary call for evaluation-order purposes:

1. evaluate `condition`;
2. evaluate `message`;
3. if the condition is `true`, return `()`;
4. otherwise terminate exactly as `builtin.panic(message)` (Panic).

The message expression is therefore evaluated even when the condition is true.

## 4.9 Hash

```stilla
builtin.hash[T]:
    fn(T) -> int32
```

Required supported key types:

```text
byte
int32
uint32
float32
bool
str
```

Calling it with another type is a compile-time error unless the implementation explicitly extends the interface.

`builtin.hash` is deterministic and must not depend on per-execution random seeds used internally by hash-table implementations.

For a fixed conforming implementation version, the same supported value must produce the same result across execution contexts.

Values equal under `==` must produce equal hashes.

For `float32`, `+0.0 == -0.0`, so both must hash identically. NaN follows IEEE comparison behavior and is not equal to itself; equal-hash requirements therefore do not equate distinct NaN payloads.

The exact hash algorithm and cross-implementation hash value are implementation-defined unless a standard-library profile specifies them.

---

# 5. Evaluation Order

Stilla uses a single deterministic evaluation-order rule:

> **Unless a construct explicitly states otherwise, subexpressions are evaluated exactly once from left to right in source order.**

This includes:

- the callee before call arguments;
- function arguments from left to right;
- the base before a member or index (`@[...]`) operation;
- the index expression after the indexed base;
- binary operator operands from left to right;
- tuple elements from left to right;
- list elements from left to right;
- struct field initializers from left to right;
- cast operands before conversion;
- the `match` scrutinee before selecting an arm;
- the `if` condition before evaluating exactly one selected branch.

`and` and `or` are short-circuiting:

- `a and b` evaluates `b` only if `a` is `true`;
- `a or b` evaluates `b` only if `a` is `false`.

Struct field initializers may be written in any order, but each initializer is evaluated in its written source order. Struct destruction remains reverse declaration order (Struct destruction order); literal field order does not change destruction order.

The `iter` combinators evaluate their iterable exactly once and visit elements in defined forward order (the Standard Library).

`iter.each` visits list elements in increasing index order (the Standard Library).

`iter.fold` is a left fold from the lowest index to the highest index (the Standard Library).

`iter.try_fold` is a left fold that stops at the first `Break`, leaving the remaining elements unvisited (the Standard Library).

Module constants are initialized in declaration order (the Core specification).

*Unique* temporaries surviving to the end of one full expression are destroyed in reverse creation order (*Unique* temporaries).

These rules apply to all conforming implementations and are not optimization hints. An implementation may optimize only when the observable behavior is unchanged.

---

# 6. Destruction at Runtime

The compile-time constraints of destruction — how `drop` hooks are declared, what a destruction view may do, and what an explicit `drop` may target — are defined in the Core specification. This section defines when and in what order destruction happens at runtime.

## 6.1 Automatic destruction

During normal control flow, a *Unique* local owner that has not been moved or explicitly dropped is automatically destroyed when its scope ends (the Core specification).

Local owners are destroyed in reverse creation order.

Ownership state is static (the Core specification) except for **maybe-unique** bindings — those released on some but not all paths through a conditional construct. For such a binding the implementation maintains a runtime liveness flag and destroys the value only if it is still alive (a conditional destruction). Automatic destruction at scope end otherwise applies exactly to definitely-owned bindings.

For example:

```stilla
{
    let a = open_file("a.txt");
    let b = open_file("b.txt");
}
```

destruction order is:

```text
b
a
```

## 6.2 Struct destruction order

During normal control flow, destroying a struct value proceeds in this exact order:

1. execute the user-defined `drop` hook, if present;
2. destroy *Unique* fields in reverse declaration order;
3. mark the complete value destroyed.

For:

```stilla
struct Connection {
    socket: Socket;
    log: File;

    drop(connection) {
        builtin.print("closing connection");
    }
}
```

destruction conceptually occurs as:

```text
Connection.drop
drop log
drop socket
```

The user hook runs while all fields remain valid. If the hook panics or traps, execution terminates immediately and remaining field destruction is not guaranteed (Panic).

## 6.3 Structural destruction order

Values containing *Unique* components are destroyed structurally.

The required ordering is:

- struct fields: reverse declaration order;
- tuple elements: reverse element order;
- list elements: reverse index order;
- union payloads: reverse payload order of the active variant;
- `box[T]`: destroy the contained value;
- module-owned *Unique* constants: reverse module initialization order.

Only the active union variant is destroyed.

## 6.4 *Unique* temporaries

A *Unique* temporary that is not transferred into another owner is automatically destroyed at the end of the containing full expression during normal control flow.

For example:

```stilla
open_file("temporary.txt");
```

constructs and then destroys the returned `File`.

Multiple *Unique* temporaries created within one full expression are destroyed in reverse creation order.

A **consuming destructure** destroys unbound components — a wildcard `_`
arm of a consuming `match`, unbound fields of a struct pattern, and an
exact `[a]` list pattern's unconsumed remainder — immediately after the
pattern binds, in the structural order of **Structural destruction order** (`ir.md`: an exact list
pattern's remainder is dropped at once).

A panic or runtime trap interrupts this rule because Stilla performs no unwinding (Panic).

## 6.5 Explicit destruction

An explicit `drop` statement (the Core specification):

```stilla
drop file;
```

performs the same destruction sequence as automatic destruction (Automatic destruction, Structural destruction order) at that point in control flow.

After the statement, the binding is no longer usable; this is enforced at compile time (the Core specification).

---

# 7. Termination and Traps

## 7.1 Panic

`builtin.panic` (**Panic** in the `builtin` interface) terminates the current Stilla execution context.

Stilla v1.3 defines **no exception-style or destructor-style unwinding** for panic or runtime traps.

Once panic or a runtime trap occurs:

- no enclosing Stilla statements resume;
- Stilla performs no pending automatic destruction of live locals or temporaries;
- Stilla performs no pending module teardown;
- no additional user `drop` hook is invoked as a consequence of termination;
- if termination occurs inside a `drop` hook, the remaining hook body and subsequent structural field destruction do not run.

Control returns immediately to the embedding host/runtime according to the host integration contract (Host integration contract).

The host is responsible for disposing of the terminated execution context and any host-owned resources. Such host cleanup is outside Stilla source semantics and must not be described as execution of Stilla `drop` hooks.

A panic or runtime trap occurring inside a user `drop` hook terminates the execution context immediately under the same rule.

## 7.2 Runtime traps and numeric behavior

The typing rules for operators and conversions are defined in the Core specification. This section defines their runtime behavior.

- `int32` integer overflow traps.
- Integer `div`/`rem` by zero traps for both `int32` and `uint32`; `float32` division follows IEEE 754 (`x / 0.0` is ±infinity for `x ≠ 0`, NaN for `0.0 / 0.0`) and never traps.
- `uint32` arithmetic is performed modulo 2³² and never traps on overflow or underflow; unary `-` on `uint32` computes the two's-complement negation and never traps, while `-` on `int32` traps on the minimum value (the Core specification).
- Invalid indexing traps.
- Invalid runtime numeric conversion traps.
- Invalid `any` cast traps: recovering an `any` payload under a target type that does not match its runtime tag (the Core specification).
- `int32 as float32` uses the IEEE 754 conversion with round-to-nearest, ties-to-even; precision may be lost.
- `float32 as int32` truncates toward zero and traps if the source is NaN, infinite, or outside the `int32` range.
- `int32 as byte` traps when the value is outside `[0, 255]`; `int32 as uint32` traps on a negative value; `uint32 as int32` traps when the value exceeds the `int32` maximum; `byte as int32` never traps (the Core specification).
- `float32` uses IEEE 754 binary32 representation.
- Other `float32` arithmetic follows IEEE 754 binary32 behavior.
- Floating equality follows IEEE numeric comparison: NaN is unequal to every value including itself, while `+0.0 == -0.0` is true.

All of these traps are deterministic.

## 7.3 Host cleanup responsibility

On normal termination, the host performs context teardown (Teardown).

On panic or runtime trap, Stilla performs no unwinding and no pending destruction (Panic); the host is responsible for disposing of the terminated execution context and any host-owned resources.

Host cleanup must not be described as execution of Stilla `drop` hooks (Host integration contract).

---

# 8. Core Runtime Model

The module model is:

```text
source file
    ↓
implicit immutable nominal struct type (module-resident)
    ↓
module-scope const = import("module")
    ↓
stable module reference
    ↓
ordinary `.` value-member access
```

Module values are restricted to module-level bindings (the Core specification), so module-qualified type lookup remains statically resolvable.

At the member-access level, modules and ordinary structs deliberately use the same operation:

```text
value.member
```

The ownership model at runtime is:

```text
fresh unique value
    ↓
owner binding
    ├── borrow → temporary/non-owning view
    ├── move owner → ownership transfer
    └── drop owner → deterministic destruction on normal flow
```

Function parameter modes (the Core specification) are:

```text
T            Copy value parameter
borrow T     non-owning parameter
move T       ownership-taking parameter
```

For an existing *Unique* owner, ownership transfer is always explicit:

```stilla
consume(move owner)
```

A fresh *Unique* expression may transfer directly:

```stilla
consume(make_value())
```

Box access separates borrowing from ownership extraction (the Core specification):

```stilla
builtin.peek(boxed)          // borrow contained value
builtin.unbox(move boxed)    // consume box and own contained value
```

Struct destruction on normal control flow is (Struct destruction order):

```text
drop owner
    ↓
user drop hook
    ↓
reverse field destruction
    ↓
value dead
```

Normal evaluation is deterministic (Evaluation Order):

```text
left-to-right evaluation
short-circuit and / or
forward sequence iteration
reverse destruction of surviving temporaries
```

Panic is deliberately outside the normal destruction model (Termination and Traps):

```text
panic / runtime trap
    ↓
terminate Stilla execution context immediately
    ↓
no Stilla unwinding
    ↓
embedding host regains control and performs host-defined cleanup
```

The runtime therefore does not need separate concepts for:

```text
constructor method
static method
associated function
instance method
class
runtime generic function object
canonical struct instance
exception unwinding
```

An `any` value (the Core specification) carries a deterministic runtime type tag identifying its concrete payload type; Stilla inspects the tag only through the `as` cast and `match` type-test patterns. A `hostdata` value is a type-erased opaque payload with no runtime type tag and no runtime inspection; it leaves Stilla only via host handoff or via host disposal on destruction, and never appears as an `any` payload (Host integration contract).

The central rules of the language (stated fully in the Core specification) are:

> **Namespace rule.** Runtime member access is ordinary `value.member`; module values are simply restricted to module scope.

> **Construction rule.** Types describe values; ordinary functions construct values.

> **Ownership rule.** Borrowing never transfers ownership; moving always transfers ownership.

> **Generic rule.** Generics are compile-time templates and must become concrete before runtime.

> **Termination rule.** Normal control flow destroys deterministically; panic terminates without unwinding.

The resulting runtime surface is therefore:

```text
value.member

Type{...}
Union::Variant(...)

function(...)
generic::[ConcreteTypes](...)

borrow parameter
move owner
drop owner

builtin.peek(boxed)
builtin.unbox(move boxed)
```

and nothing more is required for the Stilla v1.3 runtime.
