# Phase 2 — Block-Level Inference, Generic Expansion, Ownership

> Status: **implemented** — Pass 3 in the frontend pipeline.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts).

## Goal

Annotate name, type, ownership, and expression at block level, and
expand generics. After this phase, type mismatch, non-exhaustive match,
and ownership transfer issues can be checked.

## Overview

Phase 2 analyzes module bodies in **topological order** from
[Phase 1](phase1-module-graph.md), so a module's references to its
imported dependencies resolve against their already-annotated module info.
The checker (`src/passes/checker.zig`) is the phase-2 driver, with
`checker_annotate.zig` (block-level name resolution, expression/pattern
inference, binding-state tracking) and `checker_validate.zig` (the
consumer checks). Its pass structure is preserved per module:

1. collect named declarations (module scope);
2. resolve `using` aliases — at module scope and inside blocks; both are
   scoped compile-time bindings, not runtime members (Core §2.8, §13.1);
3. check items in order — const types, function declarations, struct and
   union instantiation, drop-hook bodies (Core §2.8, §5, §6, §7, §9).

## Cross-module name resolution

`resolvePath` handles dotted paths. Segments beyond the first resolve
against module members (Core §2.5):

- `module.value` — a runtime value member of the imported module
  (monomorphic function, const);
- `module.Type` — compile-time qualified type lookup (Core §2.5): the
  module's type member table is consulted, no value flows;
- `module.submodule.value` — chained value-member access through
  module-valued consts (Core §2.7);
- `builtin.member` — the standard-library `builtin` module (Core §3,
  imported like any other module), whose members resolve to host
  bindings ([Phase 3 — System calls for host bindings](phase3-cfg-lowering.md#system-calls-for-host-bindings)).

Module-qualified type lookup is static: module values never enter local
value flow (Core §2.3), so a qualified path always denotes a statically
known member.

## Type resolution

Every syntactic `ast.Type` is resolved to a `cfg.Type`
(`resolveType`), including:

- generic struct/union instantiations with their `args` filled
  (`Option[int32]` → `UnionType` with args, Core §12.1);
- transparent alias expansion — aliases leave no node (Core §11.2);
- the primitive types `any` and `hostdata` (Core §11.6, §11.7): `any` is
  the top type — always unique, carries a runtime type tag, and is
  recovered only by `as` or `match` type-test patterns (Core §11.6);
  `hostdata` is an opaque unique payload constructible only by the host;
- host-backed opaque nominal types (Core §11.8) — declared by
  standard-library / host-provided module interfaces (`opaque type
  Array[T];`): no fields or variants, unique by declaration regardless of
  type arguments, no raw construction / member access / destructuring in
  source; valid in every value position including `any`;
- ownership classification computed structurally (Copy vs unique,
  Types & Ownership §10.1–§10.3) to the **least fixpoint** (Types & Ownership §10.3): a
  recursive type whose graph cycles through an owned component is unique,
  a cycle passing only through function types is not; deferred (`null`)
  while an unspecialized type parameter remains;
- monomorphic function types with parameter modes preserved (Core §6.3,
  §10.6).

## Expression inference and annotation tables

Every expression is annotated with the `TypeInfo` it produces
(`inferExpr`), and every binding with its type. The annotation is a
**side table**, not fields on AST nodes — the AST stays immutable; the
checker's `Annotation` owns an arena with all resolved types and
instances (existing model, extended with per-module tables).

The annotation a node receives is the quadruple the phase is named for:

| annotation | meaning | source |
| --- | --- | --- |
| **name** | the resolved `Decl` the head of the expression refers to (binding, function, const, type, module member, …) | name resolution |
| **type** | the `TypeInfo` the expression produces | type resolution |
| **ownership** | the `Ownership` of the produced value, and — for bindings — the binding's ownership state (`is_borrow`, `consumed`, `released`, `maybe`) | ownership analysis |
| **expression** | the inferred `TypeInfo` of the expression node itself (`expr_of`) | expression inference |

## Generic expansion

Generic declarations are compile-time templates (Core §12); phase 2
expands them before phase 3 sees them:

- at each call to a generic function, type arguments are **inferred** from
  the use site or taken from an explicit `::[...]` specialization
  (Core §12.2, §12.3);
- each used specialization produces a `FuncInstance`: concrete `type_args`,
  a monomorphic signature, and a **monomorphized body** — a deep copy of
  the template body with every type-parameter reference replaced by its
  concrete argument (Core §12.2);
- the monomorphized body is then fully checked under the concrete
  substitution — unspecialized generic bodies are never checked
  (Core §12.4: templates are checked after specialization);
- an unspecialized generic function referenced as a value is an error
  (Core §12.4); `identity::[int32]` is a first-class monomorphic function
  value.

Instances are deduplicated per (declaration, type arguments), so each
specialization is expanded and checked exactly once. `FuncInstance` for
host bindings has no body (`body = null`, as `builtin_decls` today) —
there is nothing to expand.

The monomorphization lives in `src/passes/monomorphize.zig` (deep-copy
monomorphization of a template body under a concrete substitution) plus
`type_infer.bindTypeArgs` / `substSignature` /
`specializeSignatureExplicit`.

## Ownership analysis

Ownership annotation drives the transfer checks:

- each resolved type carries its structural `Ownership` (type resolution);
- each local binding carries its ownership state:
  - `is_borrow` — non-owning view: a `borrow` parameter, or an unique
    binding produced by a non-consuming `match` (Core §13.4);
  - a `match` arm's pattern bindings are **arm-scoped** (Core §13.2):
    they live only for the arm's body, so an arm binding reusing an
    enclosing local's name shadows it inside the arm and leaves the
    outer binding untouched after the match;
  - `consumed` — ownership transferred by `move`, or destroyed by `drop`;
  - `released` — **definitely released**, the state of an enclosing
    binding after a conditional construct released it on every path
    (Types & Ownership §10.10);
  - `maybe` — **maybe-unique**, released on some but not all normal paths
    through a conditional construct; a definitely-released or maybe-unique
    binding is unusable afterward, and only a maybe-unique binding is
    conditionally destroyed before the construct's join (in the AIR:
    join-time edge drops — [Phase 3 — Conditional destruction](phase3-cfg-lowering.md#conditional-destruction));
- `move name` marks the named binding consumed (Types & Ownership §10.4);
- `drop name;` marks it destroyed (Core §9.4);
- a `borrow` parameter receives a non-owning view and leaves the caller's
  ownership unchanged (Types & Ownership §10.6);
- a `move` parameter transfers ownership; passing an existing unique owner
  requires `move owner` at the call site, while a fresh unique value may
  transfer directly (Types & Ownership §10.6, Static Semantics §18);
- plain parameters accept only Copy argument types (Types & Ownership §10.6).

## Checks enabled by annotation

Once the annotation of a block is complete, the following are decidable
and enforced. This is the *raison d'être* of phase 2: each check consumes
the annotation and emits an `ast.Diagnostic` on failure.

### Type mismatch

Function arguments and return values must match exactly unless the source
type is `never`, the required type is `any`, or a transparent alias
expands to the required type (Core §18 *Typing*); coercion to the top
type `any` is the sole implicit widening (Core §18 *Conversion*, §11.6) —
`hostdata` never widens into it (Core §11.7) and neither does a module
value (Core §2.3: module values may not leave module storage) — and an
unique source must be `move`d into it; operator typing per
Core §16.3 (`int32 + int32 → int32`, `str + str → str`, comparisons →
`bool`, `as` conversions only the Core §16.3 set (`int32 ↔ float32`,
`int32 ↔ byte`, `int32 ↔ uint32`, `byte → int32`, `uint32 → int32`)
and `any as T` — the invalid-cast case traps at runtime, Runtime §7.2);
a literal integer defaults to `int32` and a literal float to `float32`,
but each is typed at its type's width in an explicit type context (a
typed binding, argument, return, or the other operand of a numeric binary
operator — Core Types §16.3);
branch unification with `never` and `any` coercions (Core §13.2);
declared const type vs inferred type (Core §5).

### Match not exhausted

A `match` over a union must cover every variant unless an irrefutable arm
exists (Core §13.3, §18 *Match*); a `match` over an `any` value must
include a wildcard `_` arm, because the tag space is open
(Core §11.6.2); `let` requires irrefutable patterns — refutable patterns
are accepted only by `match`, and type-test patterns (`int32 n`,
Core §14.7) are refutable and accepted only by `match`, only for an `any`
scrutinee (Core §18 *Patterns*, §14).

### Ownership transfer issues

- use after move or destruction (Core §18 *Ownership*);
- moving or dropping a borrowed unique value;
- returning/storing a borrowed value as owned;
- partial movement from fields or indexed elements (whole-owner rule,
  Core §18 *Whole-owner rule*);
- consuming destructuring of a struct that defines its own `drop` hook
  (Core §14.6);
- double `move` of the same owner.

### Conditional release

An unique binding released on a normal path through a conditional
construct — `if`/`else`, `match`, short-circuit `and`/`or` — may be
released on some paths and not others. After the construct the binding is
exactly one of definitely owned, maybe-unique (`maybe`), or definitely
released (`released`). A maybe-unique binding is unusable afterward and
is destroyed before the construct's join: the lowering emits a `drop` on
every completing edge that did not consume or transfer the binding, so
the value is destroyed only on the paths where it is still alive
(Types & Ownership §10.10, Runtime §6.1, air.md §6.4).

### Additional checks

- **non-capture rule** for functions and lambdas (Core §6.2);
- **borrow-lifetime restrictions** (`borrow` never transfers ownership;
  borrowed unique values cannot be moved, dropped, returned as owned, or
  stored into an owning location, Core §18 *Borrowing*);
- **construction typing** — the values written into a struct construction
  and a union variant's payload must be compatible with the declared
  field/payload types (Core §8.1, §11), with the declaration's type
  parameters substituted under the construction's instantiation (the
  pattern side already enforced this; the construction side did not).
  Construction positions are an explicit type context (Core Types §16.3)
  like parameter positions: a literal is typed at the declared field's
  width (`Big { v: 1 }` with `v: int64` types `1` at int64) and a nested
  construction fills its unbound type arguments from the field's goal.
  A wildcard instantiation of a generic type (no goal constrained it)
  has no concrete field types and is not checked, matching the pattern
  side. This closes the module-resident rule's struct-field and
  union-payload rows: a module value (or `hostdata`) written into an
  `any`-typed field is a field type mismatch, because neither widens
  into `any`.
- **module-resident flow restrictions** — a module value may exist only in
  a module-level `const` binding (Core §2.3): it may not be bound by a
  local `let`, and it never widens into `any`, so the value positions the
  checker types against a declared or expected type — a function
  argument, a return, a declared-`any` binding, a struct field or union
  payload — report a type error instead of silently packing it. Block-
  level `using` aliases to a module stay legal (Core §13.1): they are
  scoped compile-time bindings, not runtime storage. One boundary is
  documented, not yet closed: an inferred tuple/list element may still
  carry a module value (tuple and list elements have no declared types
  of their own to check), so §2.3 is not fully closed for those
  container positions; and `import(...)` written as a bare function-body
  statement is rejected downstream in phase 3 (`cfg_lower_expr.zig`,
  "import(...) is only valid as a module constant initializer") as a
  backstop for positions the checker cannot see.
- **module-constant initialization order** — an initializer must not
  transitively call a function that reads a module constant declared later,
  while function references themselves are order-independent
  (Core §5, §6.5);
- **recursive types without indirection** (Core §18 *Recursion*);
- **drop-hook destruction-view restrictions** — the hook argument may not
  be moved, dropped, escaped, returned, or used to transfer field
  ownership (Core §9.2, §18 *User drop hook*).

## Data structures

The phase-2 output is `checker.Annotation` (here drawn against the
implementation in `src/passes/checker.zig`; there is no `typeinfo`
module — resolved types are the AIR-native `cfg.Type`):

```zig
pub const Annotation = struct {
    arena: std.heap.ArenaAllocator,

    /// Function members declared without a Stilla body (builtin / host):
    /// calls to these lower to system calls, never in-AIR calls (phase 3 — System calls for host bindings).
    host_bindings: std.AutoHashMapUnmanaged(*const ast.FuncDef, void) = .empty,

    /// The used generic specializations, deduplicated per (declaration,
    /// type args) across modules (Generic expansion). The lowerer consumes these and
    /// lowers one monomorphic `IrFunc` per instance.
    instances: std.ArrayListUnmanaged(*FuncInstance) = .empty,

    /// One `ModuleAnnotation` per module, keyed by resolved specifier.
    per_module: std.StringHashMapUnmanaged(*ModuleAnnotation) = .empty,

    pub fn deinit(self: *Annotation) void { self.arena.deinit(); }
};

pub const ModuleAnnotation = struct {
    module: *moduleinfo.ModuleInfo,
    /// Written `ast.Type` → resolved `cfg.Type` (Type resolution).
    type_of:    std.AutoHashMapUnmanaged(*const ast.Type, cfg.Type) = .empty,
    /// `ast.Expr` → produced `cfg.Type` (Expression inference).
    expr_of:    std.AutoHashMapUnmanaged(*const ast.Expr, cfg.Type) = .empty,
    /// Binding id → resolved type.
    binding_of: std.AutoHashMapUnmanaged(u32, cfg.Type) = .empty,
    /// Binding id → static ownership state (Ownership analysis).
    bindings:   std.AutoHashMapUnmanaged(u32, BindingState) = .empty,
    /// Call → callee's concrete signature (non-generic calls).
    call_sig:   std.AutoHashMapUnmanaged(*const ast.Call, cfg.Type) = .empty,
    /// Call → the generic specialization it triggers (Generic expansion).
    call_of:    std.AutoHashMapUnmanaged(*const ast.Call, *FuncInstance) = .empty,
    /// Value-position `::[...]` → its `FuncInstance` (Generic expansion).
    spec_of:    std.AutoHashMapUnmanaged(*const ast.Specialize, *FuncInstance) = .empty,
    /// Module-member name → its declared identifier (name annotation).
    names:      std.StringHashMapUnmanaged(*const ast.Ident) = .empty,
    next_binding_id: u32 = 0,
};
```

Per-use-site tables live per module on `ModuleAnnotation`; the
`FuncInstance`s they reference (`call_of`, `spec_of`) are owned by the
global `Annotation.instances` list, deduplicated by (declaration, type
arguments) across all modules.

## Phase-2 invariant

Every expression, binding, and type use is annotated; the program is fully
monomorphic; no type, exhaustiveness, or ownership diagnostic remains.
[Phase 3](phase3-cfg-lowering.md) consumes annotated AST + module graph
and produces no more semantic errors.

## Implementation files

| File | Role |
| --- | --- |
| `src/passes/checker.zig` | Phase-2 driver |
| `src/passes/checker_annotate.zig` | Name resolution, expression/pattern inference, binding-state tracking |
| `src/passes/checker_validate.zig` | The [checks enabled by annotation](#checks-enabled-by-annotation) |
| `src/passes/checker_ownership.zig` | Conditional-release state merging through `if`/`match`/`and`/`or` (Types & Ownership §10.10) |
| `src/passes/monomorphize.zig` | Deep-copy monomorphization of template bodies under concrete substitutions |
| `src/passes/type_infer.zig` | `bindTypeArgs`, `substSignature`, `specializeSignatureExplicit` |
| `src/passes/type_resolve.zig` | `resolveType` — syntactic `ast.Type` → `cfg.Type` |
| `src/passes/type_shape.zig` | `ownershipOf` — structural ownership classification to the least *Copy* fixpoint (Types & Ownership §10.3) |
| `src/checker_tests.zig` | Black-box diagnostics tests per check (message + span) |

## Test coverage — four orthogonal dimensions

The black-box suite in `checker_tests.zig` is organized so that every
case isolates **one atomic rule of exactly one semantic dimension**. A
rule belongs to exactly one dimension; a case that would need a second
rule to be meaningful (say, an ownership case that also depends on
generic inference) is split or dropped. “Dimension” names the semantic
invariant a case targets, not every construct its fixture uses —
scaffolding (a custom drop hook, a helper function, an enclosing `if`) is
not a second rule. Near-identical variants of one invariant — the same
rejection reached through a read, a `move`, or a `drop` of a dead
binding, or through the `and`/`or` operators' shared handling — keep a
single canonical case.

Physically, the file is laid out in the same order as the matrix below:
shared harness helpers up front (checkText, expectDiag, the
multi-module builders, `OPAQUE_LIB`), a short driver-annotation preamble
for the host-binding bookkeeping that phase 3 consumes (no semantic
rule of its own), and then one section per dimension — 1 type system, 2
name binding, 3 constraints, 4 control flow — holding that dimension's
atomic cases in rule order. The four dimensions and the
rules they own:

| Dimension | Atomic rule | Test in `checker_tests.zig` |
| --- | --- | --- |
| 1. Type system | argument, return, operator, and declared-`const` type must match exactly | `rejects a call with an argument type mismatch`; `rejects a return type mismatch`; `rejects a binary operator type mismatch`; **added:** `rejects a module constant whose declared type mismatches its initializer` |
| 1. Type system | transparent aliases leave no node, so alias and target type match | **added:** `matches arguments and returns through a transparent type alias`; recursion-through-alias cases in the recursive-types section |
| 1. Type system | literals type at the context's width (explicit typed context) | `widens integer literals to the other binary operand's width`; `types float literals at the other binary operand's width` |
| 1. Type system | a literal typed at a width context is range-checked at that width | `rejects an integer literal that overflows its contextual width` |
| 1. Type system | coercion to the top type `any` is the sole implicit widening; an unique source must be `move`d | **added:** `widens a Copy argument implicitly to any`; `requires an explicit move before packing an unique value into any`; `accepts an explicit move into any` |
| 1. Type system | `any` is recovered only by `as` or a type-test `match` over it, never by a plain value position | **added:** `rejects recovering an any without as or match`; `accepts an any recovered by as` |
| 1. Type system | construction values must match the declared field/payload types (Core §8.1, §11); construction positions are explicit literal contexts | **added:** `rejects a construction field type mismatch`; `rejects a union payload type mismatch`; `types a literal at the declared field width` |
| 1. Type system | branch joins unify `never` and `any` with the other branch's type | **added:** `unifies a never branch with a value branch` |
| 1. Type system | `as` casts are restricted to the Core §16.3 set | `rejects an invalid cast` |
| 1. Type system | generic instantiation deduplicates per (declaration, type args) and checks the monomorphized body under the substitution | the generic-expansion section: `deduplicates generic specializations`, `specializes an explicitly annotated generic call`, `checks the monomorphized body of a generic call`, `rejects a generic call it cannot fully infer` |
| 1. Type system | type arguments are inferred from the use site, or taken from `::[...]` | `specializes an explicitly annotated generic call`; `rejects a specialization with the wrong type argument count` |
| 1. Type system | recursive types need indirection on every cycle | the recursive-types section, e.g. `rejects a directly recursive type without indirection`, `accepts recursion through box indirection` |
| 1. Type system | opaque host types are unique by declaration and unconstructible in source, and otherwise behave as ordinary unique values | the opaque-types section, e.g. `classifies an opaque host type as unique`, `rejects raw construction of an opaque host type`, `accepts moving an opaque host value`, `accepts borrowing an opaque host value` |
| 2. Name binding | a block-scoped `let` shadows an outer binding and the outer binding is restored on scope exit | **added:** `restores the outer binding after a shadowing block`; `keeps an outer unique owner untouched by a shadowing move` |
| 2. Name binding | functions are order-independent: a body may call a function declared later | **added:** `resolves a forward call to a later-declared function`; `accepts a function reading a later constant when nothing calls it` |
| 2. Name binding | inner function parameters bind over enclosing function parameters without capture | **added:** `binds a lambda parameter over an enclosing function parameter`; `accepts a lambda referencing only its own scope` |
| 2. Name binding | `match` arm patterns bind in an arm-scoped scope (Core §13.2) | **added:** `isolates a match pattern binding from an outer binding of the same name`; the maybe/released ownership cases that rely on arm scoping |
| 2. Name binding | dotted paths resolve module-qualified value members (Core §2.5, §2.7); each module's members are typed independently | **added:** `resolves module-qualified value members of an imported module` (two-module harness) |
| 2. Name binding | a module value may not leave module storage (Core §2.3): binding it by a local `let` or widening it into `any` is rejected | **added:** `rejects binding a module value by a local let`; `rejects widening a module value into an any` |
| 2. Name binding | lambdas may not capture an enclosing function's locals (Core §6.2) | `rejects a lambda capturing an enclosing local` |
| 3. Constraints | ownership: an owner is moved at most once; use after move/drop/release is rejected | `rejects use of a moved unique value`; `rejects moving a binding twice`; `rejects use of a definitely-released binding`; `rejects use of a maybe-unique binding` |
| 3. Constraints | ownership: an owned local transfers implicitly when it is the tail of its own scope | **added:** `accepts an owned unique local as an implicit tail return` |
| 3. Constraints | ownership: plain parameters accept only Copy, `move` parameters require an explicit `move` of an existing owner | `rejects passing an unique value to a plain parameter`; `requires an explicit move before a move parameter`; `accepts a fresh unique value into a move parameter` |
| 3. Constraints | lifetime: a borrowed unique value may not be moved, dropped, returned as owned, or stored in an owning location | `rejects moving a borrowed binding`; `rejects returning a borrowed value as owned`; `rejects storing a borrowed value into an owning binding`; **added:** `rejects dropping a borrowed binding` |
| 3. Constraints | lifetime: a `borrow` call leaves the caller's owner alive and destructible afterwards | **added:** `accepts a borrow call and keeps the caller's owner alive` |
| 3. Constraints | lifetime: conditional release merges to `maybe`/`released` (Core §10.10) | the conditional-release section, e.g. `marks a binding released on only one if branch as maybe`, `accepts releasing a binding on every if branch and marks it released` |
| 3. Constraints | drop-hook destruction view: may not move/drop/escape the view or its unique fields | the drop-hook section, e.g. `rejects moving the destruction view in a drop hook`, `accepts a drop hook that reads Copy fields` |
| 3. Constraints | module-constant scope: an initializer or drop hook may not read a later constant (Core §5) | the module-constant-init-order section, e.g. `rejects reading a later module constant`, `rejects a drop hook reading a later module constant` |
| 3. Constraints | `never` is the non-returning type: a `-> never` body must diverge, not yield a value | `rejects a never declaration whose body returns a value`; `accepts a never declaration whose body diverges`; `accepts an explicitly void declaration` |
| 4. Control flow | a value-typed body must end in an expression of the declared type on every path | `rejects a non-void declaration whose body has no final expression`; **added:** `rejects a tail if without else in a value-returning function` |
| 4. Control flow | `match` over a union must be exhaustive; over `any` it needs a wildcard arm | `rejects a non-exhaustive union match`; `accepts a type-test match over any` |
| 4. Control flow | `let` accepts only irrefutable patterns; type-test patterns are refutable and belong to `match` over `any` | `rejects a refutable let pattern` |

Language features the general taxonomy would expect here, and how Stilla
resolves them (so the matrix stays honest about what the checker owns):

- **Nested named functions** (name binding) do not exist in the grammar:
  the only function expression is a lambda, so the non-capture rule
  (Core §6.2) is exercised by lambdas, never by a `fn` nested in a `fn`
  body.
- **Match-arm lifetime** (ownership): arm pattern bindings are arm-scoped
  (Core §13.2), so a borrowed payload cannot be referenced after the
  `match` at all — the "cannot move a borrowed binding" case is tested
  inside the arm where the binding is live.
- **Overload resolution** (name binding) does not exist: there are no
  overload sets, one binding per name per scope. A duplicate module
  member is rejected in phase 1, before the checker runs
  (`moduleinfo_tests.zig`, `moduleinfo rejects a duplicate module member`;
  `module_check.zig`).
- **Exception specifications** (constraints) do not exist: Stilla has no
  exceptions. Non-returning execution is a type — `never` — and the
  declaration contract (`-> never` bodies must diverge) is the rule the
  matrix owns under dimension 3.
- **const qualification and variable-initialization paths** (constraints
  / control flow) are mostly vacuous: every binding is introduced by
  `let` with a mandatory initializer and there is no assignment, so there
  are no mutable locals, no uninitialized reads, and no partial-initialization
  paths to analyze. The path analysis the checker does run is the
  conditional-release state merge (dimension 3).
- **Unreachable code** (control flow) is not a phase-2 diagnostic: the
  checker deliberately leaves statements after a `never` call unchecked
  for reachability (`leaves code after a never call unchecked for
  reachability`), and reachability of lowered blocks is validated
  downstream on the CFG (`cfg_validate.zig`).
- **Unknown names and missing members** are reported by phase 3, not the
  checker (`cfg_lower_path.zig`), so the name-binding cases above
  are acceptance cases plus checker-owned rejections (capture, use of
  released values), never unknown-name rejections.

### Design-centered coverage lenses

A test catalog written against the v1.3 design philosophy — explicit
ownership (Unique vs Copy), module-scope isolation, no implicit capture,
explicit destruction — maps onto the four implementation dimensions
above and the physical test layout in `checker_tests.zig` (and, for
destruction-exactly-once and conditional-drop placement, the fused
runtime oracle in `ownership_fused_tests.zig`). Each lens names the
semantic invariant, not every fixture construct; the matrix below records
which atomic cases own each invariant and which catalog rows are vacuous
in Stilla v1.3.

| Design lens (catalog) | Owner dimension(s) | Representative tests in `checker_tests.zig` | Notes on vacuous or out-of-phase rows |
| --- | --- | --- | --- |
| 1. Ownership & move: explicit `move`, at-most-once use, implicit tail transfer | 3 constraints; 1 type | `requires an explicit move before a move parameter`; `accepts a fresh unique value into a move parameter`; `rejects use of a moved unique value`; `rejects moving a binding twice`; **`accepts an owned unique local as an implicit tail return`** | destruction-exactly-once is a runtime property: `ownership_fused_tests.zig` (`move` oracle, `edge kill`, `tailcall leftover kills`, drop-elision/fusion passes) |
| 2. Borrow: no ownership transfer, owner stays alive, no escape | 3 constraints | `rejects moving a borrowed binding`; **`rejects dropping a borrowed binding`**; `rejects returning a borrowed value as owned`; `rejects storing a borrowed value into an owning binding`; **`accepts a borrow call and keeps the caller's owner alive`**; non-consuming-match payload borrowing: `borrows an unique payload of a non-consuming match` | a borrow view is never destroyed by the callee: `ownership_fused_tests.zig` (`borrow` oracle) |
| 3. Conditional release: maybe-unique, auto-drop on edges | 3 constraints (state merge, Types & Ownership §10.10) | the conditional-release section: `marks a binding released on only one if branch as maybe`; `accepts releasing a binding on every if branch and marks it released`; `rejects use of a maybe-unique binding`; `rejects use of a definitely-released binding` | join-time edge drops live in phase 3 (`cfg_lower_*`); the fused oracle asserts drop-once-both-ways |
| 4. Module scope & qualified paths | 2 name binding; 3 constraints (module-value flow) | `resolves module-qualified value members of an imported module`; **`rejects binding a module value by a local let`**; **`rejects widening a module value into an any`**; **`rejects storing a module value into an any field`** | `import(...)` placement splits by phase: binding positions die in the checker (Core §2.3), the bare statement form reaches the phase-3 backstop (`frontend_spec_tests.zig`, `frontend rejects import outside a module constant initializer`); a module type cannot be *named* as a parameter type, so "module value as argument" is only reachable through the `any` coercion. Struct-field and union-payload smuggling is closed by construction typing (Core §8.1, §11); an inferred tuple/list element remains open |
| 5. No implicit capture | 2 name binding | `rejects a lambda capturing an enclosing local`; `accepts a lambda referencing only its own scope` (own params + a module constant) | nested named functions are not in the grammar — lambdas are the only function expressions |
| 6. Match: exhaustiveness, consuming vs borrowing patterns, drop hooks | 4 control flow; 3 constraints | `rejects a non-exhaustive union match`; `accepts an exhaustive union match`; `accepts a type-test match over any`; `rejects a consuming destructure of a drop-hook struct`; `accepts moving the payload of a consuming match` | arm bindings are arm-scoped, so borrowed-payload movement is tested inside the arm where the binding lives |
| 7. Type boundaries: `any`/`hostdata`/opaque | 1 type system | `widens a Copy argument implicitly to any`; `requires an explicit move before packing an unique value into any`; **`rejects recovering an any without as or match`**; **`accepts an any recovered by as`**; opaque-type section (`rejects raw construction of an opaque host type`, `accepts borrowing an opaque host value`, …) | `hostdata` is reachable in source only through host bindings: the boundary rows (no coercion to `any`, no casts, opaque payload) are covered at the integrated level in `frontend_lowering_tests.zig` (`frontend rejects every hostdata/any coercion and cast`), not duplicated in the checker suite |
| Extra. Module-const init order & teardown reads | 3 constraints (module-constant scope) | the module-constant-init-order section: `rejects reading a later module constant`; `rejects a drop hook reading a later module constant`; `accepts a mutual call cycle that reads no constants` | teardown reads are illegal because teardown destroys in reverse declaration order (Runtime §2.5) — that ordering is exercised by the fused oracle and the interpreter lifecycle tests |

## Downstream consumers

Phase 2 output is consumed by:

- **[Phase 3](phase3-cfg-lowering.md)** — reads `Annotation` for
  concrete signatures, instantiated types, and ownership decisions;
  generic functions are lowered per used specialization (one monomorphic
  `IrFunc` per instance);
- **The AIR validator** ([Pass 6.1](optimizer.md#air-validator-pass-61)) — validates
  the lowered CFG against phase-2 invariants.
