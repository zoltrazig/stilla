# Phase 3 — CFG-Based IR Generation

> Status: **implemented** — Pass 4 and Pass 5 in the frontend pipeline.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts).
> The IR op inventory and data structures are authoritative in
> [`spec/ir.md`](spec/ir.md) §4–§11 and `src/cfg.zig`, not in this
> document.

## Goal

Generate IR based on a CFG; lower host binding functions (which have only
a declaration and no definition) to system calls.

## Overview

Phase 3 lowers the annotated, monomorphic AST into a CFG-based IR:
functions become directed graphs of basic blocks over typed values, with
explicit ownership operations and control flow. It is the last frontend
phase and the runtime's input. The IR itself — 3-address code in SSA
form — is specified authoritatively in [`spec/ir.md`](spec/ir.md); the
sketch in §5.2 of the original frontend.md is superseded by ir.md §4–§11.

The lowerer is in `src/lower.zig` plus `src/passes/cfg_lower_*.zig`
files, consuming the [Phase 2](phase2-checker.md) annotation.

## IR model

- **`IrModule`** — one per `ModuleInfo`: the module's member table
  (ir.md §7 — constants as storage slots; functions, module values, and
  host bindings as static references), its init function (§5.5), and its
  host bindings (§5.6).
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
[`spec/ir.md`](spec/ir.md) §5 + §9 (`.opInfo`) and its mirror
in `src/cfg.zig` (`Op` union + `opInfo` table); the text form is
ir.md §10. Key points:

- parameters are **SSA roots** (no `arg` op), and the op set is the
  ir.md §5 one: `const`, `module_ref`, `fn_ref`; `neg`/`not`/`num_cast`/
  `type_is`, the four `any_pack_*`/`any_unpack_*`; `add`…`ge`, `concat`;
  `copy`/`borrow`/`move`/`drop` and the `cleanup_owner`/
  `cleanup_disable`/`drop_cleanup` token ops; `load_member`/
  `store_member`; `construct` and the `read_*`/`unpack_*`/`split_list`
  projections; `call`/`syscall`/`phi`; `ret`/`br`/`br_cond`/`switch`/
  `trap` terminators;
- a `switch` dispatches on a **union discriminant** (`read_tag`) only;
  a match over an `any` value lowers to a **`type_is` + `br_cond`
  chain** (the tag space is open, ir.md §14.3), not a `switch`.

The `BasicBlock` / `IrFunc` / `Value` shapes are defined in ir.md §9
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

The parameter SSA root (ir.md §5.1), `module_ref` (module-valued const),
`load_member` (module member lookup — const, function, or module-valued
member; ir.md §7), `copy`/`borrow` (Copy vs unique binding use).

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
for an `any` scrutinee, a `type_is` + `br_cond` chain tests each
type-test arm and the required wildcard `_` arm (Core §11.6.2, §14.7;
ir.md §14.3 — **not** a `switch`, because the tag space is open): a
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

### Index

Base, then index (Runtime §5: index after base), then `index` with a
bounds check that traps on failure (Runtime §7.2). Source spelling is
`base@[index]` (Core §11.5); the v1.2 `base[index]` form no longer
parses (Grammar: `index-suffix`).

### Calls

Evaluate callee then arguments left to right (Runtime §5); a Stilla
function value lowers to `call`; a host binding lowers to `syscall`
(§5.6).

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
(ir.md §4.4).

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

Destroying a struct that defines `drop` emits the hook call followed by
reverse-declaration-order field destruction (Core §9, Runtime §6.2).

### hostdata payloads

Destroying a `hostdata` value runs no Stilla `drop` hook; it hands the
opaque payload to the host for disposal, which phase 3 records as an
ordinary `drop` of the unique value (Core §11.7, Runtime §3.4, §7.3).

### Unique temporaries

Temporaries surviving to the end of a full expression are destroyed in
reverse creation order (Runtime §6.4): the builder records a
per-expression temporary stack and emits its `drop`s at the expression's
end.

### never/trap paths

Panic and runtime traps skip all destruction (Core §18 *Panic and traps*):
a `trap` terminator performs no drops.

### Conditional destruction

A maybe-unique binding (Core §10.10) is destroyed through its cleanup
token (ir.md §6.4): `cleanup_owner` at the construct's entry,
`cleanup_disable` on the paths that consume the binding, `drop_cleanup`
at scope end. The lowering **canonicalizes** the three post-construct
states — definitely owned → plain `drop`, definitely released → nothing,
maybe-unique → token — and the three ops stay in the SSA CFG: no
expansion into flag stores and branches before validation and
optimization; expansion into a frame slot / armed bit is a backend
concern, and a runtime interpreting the CFG executes the ops directly
(ir.md §6.4, §14).

Destruction is placed *after* phase-2 ownership analysis, which already
validated that every unique value is destroyed exactly once — phase 3 only
materializes it.

## Module init functions

Each `IrModule` gets an **init function** that:

1. evaluates module constants **strictly in declaration order**
   (Core §5, Runtime §5) and stores them into the module's constant
   slots — only constant members are storage (ir.md §7);
2. lowers `import("specifier")` initializers to `module_ref` values —
   stable references to the (at most once) instantiated module
   (Runtime §2.1, §2.4), so `const a = import("m"); const b = a;`
   denote the same instance; module-valued members stay static
   `ModuleRef` members (ir.md §7) with no slot — imported modules are
   instantiated by the runtime in dependency order
   ([Phase 1](phase1-module-graph.md) topological order, Runtime §2.3),
   never by `@init`;
3. records init order so the runtime can destroy module-owned unique
   constants in **reverse initialization order** during normal teardown
   (Runtime §2.5).

Host-provided modules and `builtin` need no init function: their members
have no Stilla definitions to evaluate.

## System calls for host bindings

A **host binding** is a function member with a *declaration and no Stilla
definition*:

- every `builtin` member (`print`, `str`, `len`, `range`, `box`, `peek`,
  `unbox`, `panic`, `assert`, `hash` — Core §3, Runtime §4); note that
  `map` and `fold` are **not** builtins — the list combinators live in
  the `iter` module (StdLib §7);
- every member of a host-provided module (`os.open`, `file.close`, … —
  Core §2.6, Runtime §3.1), whose statically known interface is supplied
  by the host interface registry.

[Phase 1](phase1-module-graph.md) flags these in
`ModuleInfo.host_bindings`; [Phase 2](phase2-checker.md) gives them
resolved signatures but no `FuncInstance` body; phase 3 applies one rule:

> **A call to a host binding is lowered to a `SysCall` instruction —
> never to an in-IR `call`. A host binding has no `IrFunc`; its body is
> never lowered, because no body exists.**

```zig
/// A system call: transfer to the host implementation of a binding.
/// The runtime dispatches on (module, member) — the member names a
/// host-binding member of the module's member table (ir.md §7); stable,
/// because module member layout is static (Core §2.1, Runtime §2.2).
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
    builtin: BuiltinId,          // enum of Runtime §4 members
    host_module: struct {
        module: *ModuleInfo,     // resolved host-provided module
        member_index: u32,       // MemberId into the module's member table (ir.md §7)
    },
};
```

### Lowering rules around syscalls

- **argument evaluation** — syscall arguments are evaluated exactly like
  call arguments: left to right, once, before the transfer (Runtime §5);
  `move` args are evaluated as moves, `borrow` args as views;
- **borrowed results** — a binding whose result is a borrowed view
  (`builtin.peek`, Runtime §4.8) produces a value whose `BorrowOrigin`
  is the `peek` root (ir.md §6.5): the view is bound to the syscall's
  boxed argument;
- **no inlining, no codegen** — the syscall is opaque to the frontend; the
  runtime's `builtin` vtable (`src/builtin.zig`) and host dispatch own the
  implementation (Runtime §3.2, §3.4);
- **panicking bindings** — `builtin.panic` returns `never`; its call is
  followed by a `trap` terminator, and no destruction runs after it
  (Runtime §7);
- **generic builtins** — `builtin.len`, `builtin.str`, `builtin.box`,
  `builtin.peek`, `builtin.unbox`, and `builtin.hash` are generic
  (Runtime §4); [Phase 2](phase2-checker.md) specializes them like any
  generic function (producing a `FuncInstance` with `body = null`), and
  phase 3 lowers the specialized call site to a syscall carrying the
  resolved concrete signature;
- **`any` and `hostdata` at the host boundary** — an `any` argument to or
  result from a host binding is transferred as its tagged payload, and a
  `hostdata` argument or result as its opaque payload (Core §11.6–§11.7,
  Runtime §3.4); the frontend only passes the value through — recovery
  requires a Stilla-side `as` or `match` type-test, and the tag / opaque
  representation is the runtime's concern.

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
  arrive `borrowed`, and `builtin.peek` yields a `peek`-rooted view
  (ir.md §6.5);
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
    types: []cfg.TypeDecl,       // the IR type environment (ir.md §11)
    entry: ?*IrFunc,             // the host-selected entry, when present
};
```

Lowering populates `IrProgram.types` from the module graph's type
environment (`cfg_lower_program.collectTypeEnv`): one written name per
`Type` in use — including monomorphic generic specializations — indexed
by the same `TypeId` that `Type.named` carries, with aliases expanding
and leaving no entry. The IR is self-contained in IR-native `cfg.Type`s
and never consumes phase-2 source-level types (ir.md §9, §11).

Consumers of the CFG:

- **runtime interpreter/compiler** — executes `IrFunc` bodies; blocks and
  terminators make evaluation order and destruction explicit;
- **module instantiation** — `IrModule` init functions run in topological
  order, each module at most once (Runtime §2.1, §2.3);
- **deterministic destruction** — scope/temporary `drop` ops and
  reverse-order teardown are already materialized (§5.4, §5.5);
- **[optimizer](optimizer.md)** — the CFG is the base for the mid-level
  optimizer (Passes 7–8), a fixed sequence of semantics-preserving
  CFG→CFG rewrites run as a **single ordered pass** (no iteration to
  fixpoint) behind `frontend.Options.optimize`.

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
| `src/passes/cfg_lower_emit.zig` | On-the-fly optimizations at construction (§4.3) |
| `src/passes/cfg_lower_validate.zig` | Post-lowering validation |
| `src/passes/cfg_lex.zig` | IR text lexing (re-exported by `cfg`) |
| `src/passes/cfg_parse.zig` | IR text parsing (re-exported by `cfg`) |
| `src/passes/cfg_print.zig` | IR text printing (re-exported by `cfg`) |
| `src/builtin.zig` | Syscall dispatch vtable |
