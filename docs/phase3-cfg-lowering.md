# Phase 3 — CFG-Based AIR Generation

> Status: **implemented** — Pass 4 and Pass 5 in the frontend pipeline.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts).
> The AIR op inventory and data structures are authoritative in
> [`spec/air.md`](spec/air.md) §4–§11 and `src/cfg.zig`, not in this
> document.

## Goal

Generate AIR based on a CFG; lower host binding functions (which have only
a declaration and no definition) to system calls.

## Overview

Phase 3 lowers the annotated, monomorphic AST into a CFG-based AIR:
functions become directed graphs of basic blocks over typed values, with
explicit ownership operations and control flow. It is the last frontend
phase and the runtime's input. The AIR itself — 3-address code in SSA
form — is specified authoritatively in [`spec/air.md`](spec/air.md); the
sketch in the original frontend.md is superseded by air.md §4–§11.

The lowerer is in `src/lower.zig` plus `src/passes/cfg_lower_*.zig`
files, consuming the [Phase 2](phase2-checker.md) annotation.

## AIR model

- **`IrModule`** — one per `ModuleInfo`: the module's member table
  (air.md §7 — constants as storage slots; functions, module values, and
  host bindings as static references), its init function (Module init functions), and its
  host bindings (System calls for host bindings).
- **`IrFunc`** — one per runtime function: each monomorphic function
  declaration and each `FuncInstance` (host bindings get no `IrFunc` —
  they are syscalls only). Contains the signature (parameter modes, return
  type), the entry block, and all blocks.
- **`BasicBlock`** — a sequence of value ops terminated by exactly one
  `Terminator`. Blocks are laid out so that fall-through is the common
  case; explicit edges everywhere else.
- **`Value`** — an SSA-like op with a type and (for unique results) an
  ownership tag. Stilla's immutable bindings with shadowing are naturally
  SSA (Core §4: "Stilla is therefore SSA-friendly"): every `let` produces
  a fresh value; shadowing is a fresh name, not a reassignment.

Deterministic evaluation (Runtime §5) is structural: the lowering order of
ops *is* the evaluation order — callee before arguments, arguments left to
right, base before member/index, operands left to right, scrutinee before
arm selection.

## Values, ops, and terminators

The authoritative inventory is the op schema in
[`spec/air.md`](spec/air.md) §5 + §9 (`.opInfo`) and its mirror
in `src/cfg.zig` (`Op` union + `opInfo` table); the text form is
air.md §10. Key points:

- parameters are **SSA roots** (no `arg` op), and the op set is the
  air.md §5 one: `const`, `module_ref`, `fn_ref`; `neg`/`not`/`num_cast`/
  `type_is`, the four `any_pack_*`/`any_unpack_*`; `add`…`ge`, `concat`;
  `copy`/`borrow`/`move`/`drop` and the `cleanup_arm`/
  `cleanup_disarm`/`cleanup_drop` token ops; `load_member`/
  `store_member`; `construct` and the `read_*`/`unpack_*`/`split_list`
  projections; `call`/`syscall`/`phi`; `ret`/`j`/`br`/`switch`/
  `trap` terminators;
- a `switch` dispatches on a **union discriminant** (`read_tag`) only;
  a match over an `any` value lowers to a **`type_is` + `br`
  chain** (the tag space is open, air.md §14.3), not a `switch`.

The `BasicBlock` / `IrFunc` / `Value` shapes are defined in air.md §9
(`BasicBlock`, `IrFunc`, `Param`, `Value`, `Instr`).

## Lowering rules

Lowering is a recursive walk of the annotated AST over a builder that
emits ops into the current block and introduces new blocks at control-flow
points.

### Literals and consts

A `void`-typed result that nothing observes — an expression statement,
or the void tail of an `if`/`match` whose value no binding or return
reads — is **not** materialized as a `const void` op; only its effects
(calls, syscalls, drops) are emitted. `void` is a singleton type with no
observable value and a void return is a bare `ret`, so such a value is
always dead; this is a lowering rule, not an optimizer rewrite.

### Path expressions

The parameter SSA root (air.md §5.1), `module_ref` (module-valued const),
`load_member` (module member lookup — const, function, or module-valued
member; air.md §7), `copy`/`borrow` (Copy vs unique binding use).

### Binary ops

`arithmetic` / `compare` / `logic`. `and` and `or` do **not** become a
single op — they lower to a `branch_cond` diamond so the right operand
is evaluated only when required (Runtime §5): `a and b` evaluates `b`
only if `a` is `true`.

### if (Core §13.2)

Evaluate condition, `branch_cond` to then/else blocks, join block
receives the selected branch's value; no `else` → else block yields
`void`.

### match (Core §13.3)

Evaluate scrutinee once; for a union, a `switch` on the variant
discriminant dispatches to per-arm blocks (pattern tests compile to
discriminant comparisons / payload binds / nested tests for list shapes);
for an `any` scrutinee, a `type_is` + `br` chain tests each
type-test arm and the required wildcard `_` arm (Core §11.6.2, §14.7;
air.md §14.3 — **not** a `switch`, because the tag space is open): a
non-consuming match binds only **Copy** payloads (copied out), and a
unique payload can be recovered only by the consuming form,
`match (move a)` (Core §11.6.2); arms join at a common exit block;
`never` arms end in `trap` and contribute no value; the join value is the
match result.

### let

Evaluate init, then bind the produced value as a fresh SSA name; `let`
with a pattern lowers to destructuring ops.

### move / drop

- `move name` (Core §10.4) → `move` of the named binding; the old SSA
  name is dead afterwards.
- `drop name;` (Core §9.4) → `drop` of the named binding.

### Member access (Core §15.1)

`load_field` for structs; `load_member` for module members; chained paths
lower left-to-right (`std.math.sqrt` → load `std` module, load `math`
member, load `sqrt` member — Core §2.7).

### List element reads

Element reads happen through list patterns (Core §11.5, §14.5) — there
is no indexed element-read function. A non-consuming `[h, ..t]` pattern
lowering length-guards the arm first (the `list#len` syscall, Runtime
§4.3), then reads each item with `read_index` (borrowed view of a
*Unique* element); the literal-item equality tests reuse the same
`read_index` at the literal's index. A consuming `match (move xs)` uses
the atomic `split_list` destructure instead (air.md §5.3), which traps on
a short list (Runtime §7.2).

### Calls

Evaluate callee then arguments left to right (Runtime §5); a Stilla
function value lowers to `call`; a host binding lowers to `syscall`
(System calls for host bindings).

### Construction (Core §8.1, §11)

`construct` ops: struct fields in written order (evaluation order;
literal field order does not affect reverse-declaration-order
destruction, Runtime §6.2), union variant with discriminant + payload,
tuple/list elements left to right, `box` indirection.

### Casts

`num_cast` for the Core §16.3 cast set (`int32 ↔ float32`,
`int32 ↔ byte`, `int32 ↔ uint32`, `byte → int32`, `uint32 → int32`);
`any as T` lowers to `any_unpack_copy` (Copy target, the `any` stays
owned) or `any_unpack_move` (`(move any) as T`, the complete `any` is
consumed and payload ownership transfers); an invalid `any` recovery — a
tag mismatch — is a deterministic runtime trap with no unwinding
(Core §11.6.1, Runtime §7.2), and phase 2 ensures the source is `move`d
for an unique target type. Coercions into `any` (`any_pack_copy` /
`any_pack_move`) are materialized at call arguments, `ret` of an
`any`-typed function, and the predecessor edges of an `any` join
(air.md §4.4).

### Specialization

`::[...]` specialization is already eliminated in phase 2; the
specialized instance's body is lowered as its own `IrFunc`.

## Destruction placement

Destruction is deterministic (Runtime §6) and phase 3 makes it explicit:

### Scope-end destruction

Every live unique local owner is destroyed when its scope ends during
normal control flow (Core §18 *Destruction*); because ownership state is
static, only **definitely-owned** bindings get a `drop` — a
definitely-released binding is skipped (Core §10.10). The lowering pass
inserts `drop` ops at the exit of every block that terminates the scope —
every `if`/`match` branch and the function epilogue (Stilla has no loop
construct, Core §13.5).

### User drop hook

Destroying a struct that defines `drop` runs the hook call followed by
reverse-declaration-order field destruction (Core §9, Runtime §6.2).
Phase 3 emits the destruction as one `drop` instruction; the
post-optimization **drop-lowering pass** (`src/passes/cfg_lower_drop.zig`)
expands it in the CFG — a direct `call` of the hidden hook function,
then `unpack_struct` and per-field drops in reverse declaration order
(recursively). The hook runs while all fields remain valid: the call is
emitted before the unpack (air.md §6.4).

### hostdata payloads

Destroying a `hostdata` value runs no Stilla `drop` hook; it hands the
opaque payload to the host for disposal, which phase 3 records as an
ordinary `drop` of the unique value (Core §11.7, Runtime §3.4, §7.3).

### opaque host types

An opaque host type value (`Array[T]`, `HashMap[K, V]` — Core §11.8,
StdLib §1) is a unique nominal value with no fields: the checker rejects
its construction, member access, and destructuring in source, and the
lowerer reports the same rules for any path that reaches it. `drop` of an
opaque value is one unexpanded instruction (air.md §6.4): the runtime
dispatches `host_drop(host_id, value)` by the type's host identity
(Runtime §3.4, §6.6), and consuming operations on containers (`set`,
`insert`, `remove`) lower to `syscall`s taking the value by `move` and
returning the updated value — the host may mutate in place.

### Unique temporaries

Temporaries surviving to the end of a full expression are destroyed in
reverse creation order (Runtime §6.4): the builder records a
per-expression temporary stack and emits its `drop`s at the expression's
end.

### never/trap paths

Panic and runtime traps skip all destruction (Core §18 *Panic and traps*):
a `trap` terminator performs no drops.

### Conditional destruction

A maybe-unique binding (Core §10.10) — released on some but not all paths
through a conditional construct — is destroyed unconditionally at the
construct's join (air.md §6.4): `joinMaybeFlags` emits a raw `drop` at the
end of every completing branch that neither consumed nor transferred the
binding, in reverse candidate order, so ownership is uniformly dead after
the join and the ordinary scope-end destruction skips the binding. The
token-based spelling of the same schedule — `cleanup_arm` at the
construct's entry, `cleanup_disarm` on consuming paths, `cleanup_drop`
at scope end — is part of the op set (air.md §5.4) but v1 does not emit
it: the join-time edge drops are the whole mechanism, and cleanup tokens
never appear in v1 CFGs (they remain in the op set for text-form and
validator coverage).
(air.md §6.4, §14).

Destruction is placed *after* phase-2 ownership analysis, which already
validated that every unique value is destroyed exactly once — phase 3 only
materializes it.

## Module init functions

Each `IrModule` gets an **init function** that:

1. evaluates module constants **strictly in declaration order**
   (Core §5, Runtime §5) and stores them into the module's constant
   slots — only constant members are storage (air.md §7);
2. lowers `import("specifier")` initializers to `module_ref` values —
   stable references to the (at most once) instantiated module
   (Runtime §2.1, §2.4), so `const a = import("m"); const b = a;`
   denote the same instance; module-valued members stay static
   `ModuleRef` members (air.md §7) with no slot — imported modules are
   instantiated by the runtime in dependency order
   ([Phase 1](phase1-module-graph.md) topological order, Runtime §2.3),
   never by `@init`;
3. records init order so the runtime can destroy module-owned unique
   constants in **reverse initialization order** during normal teardown
   (Runtime §2.5).

Host-provided modules and `builtin` need no init function: their members
have no Stilla definitions to evaluate.

## System calls for host bindings

A **host binding** is a *declaration without a Stilla definition that does
not come from the implementation standard-library bundle* (Intrinsics
Specification §2): caller-supplied stdlib-extension modules
(`Sources.standard_library`), user source modules, and host-provided
modules. Origin decides — a same-spelled declaration outside the bundle
keeps host-binding identity. [Phase 1](phase1-module-graph.md) flags these
in `ModuleInfo.host_bindings`; [Phase 2](phase2-checker.md) gives them
resolved signatures but no `FuncInstance` body.

Bundle-origin bodyless declarations are **intrinsics**, not host bindings;
the frontend expands each use while lowering source (Intrinsics
Specification §3–§4). A host-backed expansion emits the same `SysCall`
form described below, targeting a genuine host binding — e.g. every
`builtin` member (`print`, `str`, `box`, `unbox`, `panic`, `assert`,
`hash` — Core §3, Runtime §4) and the math, list, string, array, and
hashmap functions; note that `map` and `fold` are **not** builtins — the
list combinators live in the `iter` module (StdLib §7), and the list
operations `len` and `range` live in the `list` module (Runtime §4.3,
§4.4). Phase 3 applies one rule:

> **A call to a host binding is lowered to a `SysCall` instruction —
> never to an in-AIR `call`. A host binding has no `IrFunc`; its body is
> never lowered, because no body exists.**

```zig
/// A system call: transfer to the host implementation of a binding.
/// The runtime dispatches on (module, member) — the pair names the host
/// module registry's binding (Runtime §3.1); stable, because the registry
/// contract is static (Core §2.1, Runtime §2.2). It is independent of the
/// AIR member table (air.md §5.6): intrinsic declarations never occupy it.
pub const SysCall = struct {
    span: ast.Span,
    target: SysCallTarget,
    /// Arguments, evaluated left-to-right before the call (Runtime §5),
    /// with parameter modes applied: plain/borrow pass views or copies,
    /// move passes ownership (Core §10.6).
    args: []*Value,
    /// Result type; `never` for panicking bindings (builtin.panic).
    ret: *cfg.Type,
};

pub const SysCallTarget = union(enum) {
    builtin: BuiltinId,          // enum of Runtime §4 members — the builtin
                                 //   module's host interface name
    host_module: struct {
        module: []const u8,      // host-registry module name
        member: []const u8,      // host-registry member name — not a
                                 //   member-table index (air.md §5.6)
    },
};
```

### Lowering rules around syscalls

- **argument evaluation** — syscall arguments are evaluated exactly like
  call arguments: left to right, once, before the transfer (Runtime §5);
  `move` args are evaluated as moves, `borrow` args as views;
- **no borrowed results** — Stilla has no borrowed return values (Core
  §10.7), so every syscall result arrives `owned`; borrowed views arise
  only from intra-expression projections (`read_*` / `tail` over a
  *Unique* base) and borrow-mode parameters;
- **no inlining, no codegen** — the syscall is opaque to the frontend; the
  runtime's host dispatch (`src/interpreter_host.zig` → `src/host.zig`)
  own the
  implementation (Runtime §3.2, §3.4);
- **panicking bindings** — `builtin.panic` returns `never`; its call is
  followed by a `trap` terminator, and no destruction runs after it
  (Runtime §7);
- **generic builtins** — `builtin.str`, `builtin.box`,
  `builtin.unbox`, and `builtin.hash` are generic
  (Runtime §4); [Phase 2](phase2-checker.md) specializes them like any
  generic function (producing a `FuncInstance` with `body = null`), and
  phase 3 lowers the specialized call site to a syscall carrying the
  resolved concrete signature;
- **`any`, `hostdata`, and opaque host types at the host boundary** — an
  `any` argument to or result from a host binding is transferred as its
  tagged payload, and a `hostdata` argument or result as its opaque
  payload (Core §11.6–§11.7, Runtime §3.4); an opaque host type value
  (`Array[int32]`, Core §11.8) is transferred as the context-scoped
  handle naming its host object, with a concrete nominal type in the
  signature. The frontend only passes the value through — recovery from
  `any` requires a Stilla-side `as` or `match` type-test, and the tag /
  opaque representation is the runtime's concern.

Rationale: host bindings are the *only* surface where the language meets
implementation-specific behavior. Making them system calls keeps the CFG
uniform (every call is a typed edge with a known signature), keeps host
integration out of the value model, and makes the runtime's dispatch
trivial: `(module, member) → host function`.

## Integration with Phase 2 (Pass 5)

The lowerer consumes the [Phase 2](phase2-checker.md) annotation
(`lower.Lowerer.ann` reads the checker's side tables; `cfg_lower_module`
iterates `Annotation.instances`):

- **concrete signatures and instantiated types** — call sites and
  constructions read the checker's concrete signatures and instantiated
  types;
- **borrow/borrowed views** — `read_*`/`tail` projections over a unique
  base emit a borrowed view (origin `root(base)`), borrow-mode parameters
  arrive `borrowed`; no syscall or call returns a borrowed value
  (air.md §6.5);
- **non-consuming unique match payloads** — union/struct/tuple/list
  payloads are borrowed while the scrutinee is destroyed at scope end; a
  non-consuming match over an `any` binds only Copy payloads (a unique
  `any` payload requires `match (move a)`, Core §11.6.2);
- **`::[...]` specialization lowering** — generic functions are
  monomorphized in phase 2 (`monomorphize.zig` → `FuncInstance` with a
  checked monomorphized body), and each used specialization lowers as
  its own `IrFunc` (`cfg_lower_func.lowerInstance`), with a
  value-position `::[...]` lowering to a `fn_ref` of it;
- **block-level `using`** — resolved at compile time in phase 2; there is
  nothing to lower at runtime, so this is complete by construction.

## Outputs and downstream consumers

```zig
/// Phase-3 output: the program as a CFG, ready for the runtime.
pub const IrProgram = struct {
    modules: []*IrModule,        // phase-1 order
    funcs: []*IrFunc,            // all monomorphic functions + instances
    types: []cfg.TypeDecl,       // the AIR type environment (air.md §11)
    entry: ?*IrFunc,             // the host-selected entry, when present
};
```

Lowering populates `IrProgram.types` from the module graph's type
environment (`cfg_lower_program.collectTypeEnv`): one written name per
`Type` in use — including monomorphic generic specializations — indexed
by the same `TypeId` that `Type.named` carries, with aliases expanding
and leaving no entry. The AIR is self-contained in AIR-native `cfg.Type`s
and never consumes phase-2 source-level types (air.md §9, §11).

Consumers of the CFG:

- **runtime interpreter/compiler** — executes `IrFunc` bodies; blocks and
  terminators make evaluation order and destruction explicit;
- **module instantiation** — `IrModule` init functions run in topological
  order, each module at most once (Runtime §2.1, §2.3);
- **deterministic destruction** — scope/temporary `drop` ops and
  reverse-order teardown are already materialized (Destruction placement, Module init functions);
- **[optimizer](optimizer.md)** — the CFG is the base for the mid-level
  optimizer (Passes 7–8), a fixed sequence of semantics-preserving
  CFG→CFG rewrites run as a **single ordered pass** (no iteration to
  fixpoint) behind `frontend.Options.optimize`; `optimize_aggressive`
  opts into the bounded fixpoint loop (optimizer.md, §8.9).

## Implementation files

| File | Role |
| --- | --- |
| `src/cfg.zig` | Op schema (`opInfo`), types, `IrProgram` |
| `src/lower.zig` | Lowerer context and top-level driver |
| `src/passes/cfg_lower_program.zig` | Program-level lowering, type env collection |
| `src/passes/cfg_lower_module.zig` | Module-level lowering, init functions |
| `src/passes/cfg_lower_func.zig` | Function-level lowering, instance lowering |
| `src/passes/cfg_lower_expr.zig` | Expression lowering, dead-void elision |
| `src/passes/cfg_lower_control.zig` | Control flow: `if`, `match`, `and`/`or` |
| `src/passes/cfg_lower_call.zig` | Call and syscall lowering |
| `src/passes/cfg_lower_pattern.zig` | Pattern destructuring |
| `src/passes/cfg_lower_path.zig` | Path expression lowering |
| `src/passes/cfg_lower_emit.zig` | On-the-fly optimizations at construction |
| `src/passes/cfg_lower_validate.zig` | Post-lowering validation |
| `src/passes/cfg_lower_drop.zig` | Post-optimization drop lowering: expand statically-expandable `drop`s (struct/tuple/box/union) into explicit CFG operations; only opaque, `hostdata`, `list`, and `any` drops remain single instructions |
| `src/passes/cfg_lex.zig` | AIR text lexing (re-exported by `cfg`) |
| `src/passes/cfg_parse.zig` | AIR text parsing (re-exported by `cfg`) |
| `src/passes/cfg_print.zig` | AIR text printing (re-exported by `cfg`) |
| `src/host.zig` | Host-call handlers (`DefaultHostCall`, per-module handlers); dispatch is `src/interpreter_host.zig` |
