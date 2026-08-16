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
  bindings ([Phase 3 §5.6](phase3-cfg-lowering.md#system-calls-for-host-bindings)).

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
  recovered only by `as` or `match` type-test patterns (§4.6);
  `hostdata` is an opaque unique payload constructible only by the host;
- ownership classification computed structurally (Copy vs unique,
  Core §10.1–§10.3) to the **greatest fixpoint** (Core §10.3): a
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
| **name** | the resolved `Decl` the head of the expression refers to (binding, function, const, type, module member, …) | name resolution (§4.1) |
| **type** | the `TypeInfo` the expression produces | type resolution (§4.2) |
| **ownership** | the `Ownership` of the produced value, and — for bindings — the binding's ownership state (`is_borrow`, `consumed`, `released`, `maybe`) | ownership analysis (§4.5) |
| **expression** | the inferred `TypeInfo` of the expression node itself (`expr_of`) | inference (§4.3) |

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
  - `consumed` — ownership transferred by `move`, or destroyed by `drop`;
  - `released` — **definitely released**, the state of an enclosing
    binding after a conditional construct released it on every path
    (Core §10.10);
  - `maybe` — **maybe-unique**, released on some but not all normal paths
    through a conditional construct; a definitely-released or maybe-unique
    binding is unusable afterward, and only a maybe-unique binding is
    conditionally destroyed at scope end (in the IR: through its cleanup
    token — [Phase 3 §5.4](phase3-cfg-lowering.md#destruction-placement));
- `move name` marks the named binding consumed (Core §10.4);
- `drop name;` marks it destroyed (Core §9.4);
- a `borrow` parameter receives a non-owning view and leaves the caller's
  ownership unchanged (Core §10.6);
- a `move` parameter transfers ownership; passing an existing unique owner
  requires `move owner` at the call site, while a fresh unique value may
  transfer directly (Core §10.6, §18);
- plain parameters accept only Copy argument types (Core §10.6).

## Checks enabled by annotation

Once the annotation of a block is complete, the following are decidable
and enforced. This is the *raison d'être* of phase 2: each check consumes
the annotation and emits an `ast.Diagnostic` on failure.

### Type mismatch

Function arguments and return values must match exactly unless the source
type is `never`, the required type is `any`, or a transparent alias
expands to the required type (Core §18 *Typing*); coercion to the top
type `any` is the sole implicit widening (Core §18 *Conversion*, §11.6),
and an unique source must be `move`d into it; operator typing per
Core §16.3 (`int32 + int32 → int32`, `str + str → str`, comparisons →
`bool`, `as` conversions only the Core §16.3 set (`int32 ↔ float32`,
`int32 ↔ byte`, `int32 ↔ uint32`, `byte → int32`, `uint32 → int32`)
and `any as T` — the invalid-cast case traps at runtime, Runtime §7.2);
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
is destroyed conditionally at scope end: in the IR the implementation
arms a cleanup token at the construct's entry and emits `drop_cleanup`
at scope end, destroying the value only if it is still alive on the path
that got there (Core §10.10, Runtime §6.1, ir.md §6.4).

### Additional checks

- **non-capture rule** for functions and lambdas (Core §6.2);
- **borrow-lifetime restrictions** (`borrow` never transfers ownership;
  borrowed unique values cannot be moved, dropped, returned as owned, or
  stored into an owning location, Core §18 *Borrowing*);
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
module — resolved types are the IR-native `cfg.Type`):

```zig
pub const Annotation = struct {
    arena: std.heap.ArenaAllocator,

    /// Function members declared without a Stilla body (builtin / host):
    /// calls to these lower to system calls, never in-IR calls (§5.6).
    host_bindings: std.AutoHashMapUnmanaged(*const ast.FuncDef, void) = .empty,

    /// The used generic specializations, deduplicated per (declaration,
    /// type args) across modules (§4.4). The lowerer consumes these and
    /// lowers one monomorphic `IrFunc` per instance.
    instances: std.ArrayListUnmanaged(*FuncInstance) = .empty,

    /// One `ModuleAnnotation` per module, keyed by resolved specifier.
    per_module: std.StringHashMapUnmanaged(*ModuleAnnotation) = .empty,

    pub fn deinit(self: *Annotation) void { self.arena.deinit(); }
};

pub const ModuleAnnotation = struct {
    module: *moduleinfo.ModuleInfo,
    /// Written `ast.Type` → resolved `cfg.Type` (§4.2).
    type_of:    std.AutoHashMapUnmanaged(*const ast.Type, cfg.Type) = .empty,
    /// `ast.Expr` → produced `cfg.Type` (§4.3).
    expr_of:    std.AutoHashMapUnmanaged(*const ast.Expr, cfg.Type) = .empty,
    /// Binding id → resolved type.
    binding_of: std.AutoHashMapUnmanaged(u32, cfg.Type) = .empty,
    /// Binding id → static ownership state (§4.5).
    bindings:   std.AutoHashMapUnmanaged(u32, BindingState) = .empty,
    /// Call → callee's concrete signature (non-generic calls).
    call_sig:   std.AutoHashMapUnmanaged(*const ast.Call, cfg.Type) = .empty,
    /// Call → the generic specialization it triggers (§4.4).
    call_of:    std.AutoHashMapUnmanaged(*const ast.Call, *FuncInstance) = .empty,
    /// Value-position `::[...]` → its `FuncInstance` (§4.4).
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
| `src/passes/checker_validate.zig` | The §4.6 checks |
| `src/passes/checker_ownership.zig` | Conditional-release state merging through `if`/`match`/`and`/`or` (Core §10.10) |
| `src/passes/monomorphize.zig` | Deep-copy monomorphization of template bodies under concrete substitutions |
| `src/passes/type_infer.zig` | `bindTypeArgs`, `substSignature`, `specializeSignatureExplicit` |
| `src/passes/type_resolve.zig` | `resolveType` — syntactic `ast.Type` → `cfg.Type` |
| `src/passes/type_shape.zig` | `ownershipOf` — structural ownership classification to greatest fixpoint |
| `src/checker_tests.zig` | Black-box diagnostics tests per check (message + span) |

## Downstream consumers

Phase 2 output is consumed by:

- **[Phase 3](phase3-cfg-lowering.md)** — reads `Annotation` for
  concrete signatures, instantiated types, and ownership decisions;
  generic functions are lowered per used specialization (one monomorphic
  `IrFunc` per instance);
- **The IR validator** ([§6.1](optimizer.md#ir-validator)) — validates
  the lowered CFG against phase-2 invariants.
