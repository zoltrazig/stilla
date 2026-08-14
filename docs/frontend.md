# Stilla Frontend: AST → CFG Transformation

> Status: **v0.1 draft** — design for the compile-time frontend that turns
> parsed source into a CFG-based intermediate representation ready for the
> runtime. Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts); this
> document describes the *implementation pipeline* that enforces and
> consumes them.
>
> Implementation status: the pipeline is built in passes — Passes 1, 2, 3,
> and 4 (lex/parse, phase 1, phase 2, phase 3) are **complete**, as are
> the optimizer's Pass 7 (tail call optimization) and Pass 8 (constant
> folding, CSE, PRE, copy propagation, dead-block elimination, drop
> elision, jump threading, phi simplification). The agreed
> fast-optimization redesign is **implemented**: the optimizer is wired
> into `frontend.compile` behind `frontend.Options.optimize` (default off;
> the `stilla` executable enables it; code-only toggle, no CLI flag), the
> dead-void lowering fix (Pass 4.1) lands at lowering, constant folding /
> arithmetic simplification / CSE / copy propagation run on-the-fly at
> construction (Pass 4.3, braun13cc.pdf §3.1 — no separate passes), and
> the Pass 8 additions (8.3–8.8) run in the single ordered pass; the
> harness (frontend.md §8.9) reports instruction / block / text-byte
> counts over the example corpus.

## 1. Overview

The frontend is the compile-time half of the implementation: lexing,
parsing, module loading, static checking, and lowering. It runs entirely
before execution and produces everything the runtime needs to instantiate
modules and run functions.

```text
source files
    │  lex            (src/lex.zig:      text → tokens)
    │  parse          (src/parser.zig:   tokens → ast.Program)
    ▼
per-module AST
    │
    │  PHASE 1  module graph construction and module-level annotation
    │          (import resolution, member tables, cycle check, topo sort)
    ▼
module graph  (every module in the program has module-level info)
    │
    │  PHASE 2  block-level inference, generic expansion, ownership
    │          (name / type / ownership / expression annotation)
    ▼
annotated AST  (monomorphic; all static checks passed)
    │
    │  PHASE 3  CFG-based IR generation
    │          (per-function basic blocks; host bindings → system calls)
    ▼
IR (CFG)  →  runtime (module instantiation, function execution, destruction)
```

The three phases are strictly ordered because each one establishes an
invariant the next one relies on:

| Phase | Output | Invariant established |
| --- | --- | --- |
| 1 | `ModuleGraph` of `ModuleInfo` nodes | every module in the program has its module-level info computed; cross-module name/type lookup is decidable |
| 2 | annotated `ast.Program` per module | every expression, binding, and type use is annotated (name, type, ownership, expression); the program is fully monomorphic and statically correct |
| 3 | CFG-based `IrModule` / `IrFunc` | control flow and value flow are explicit; every host binding call is a system call |

## 2. Inputs, outputs, and pipeline contract

**Inputs**

- an *entry module* (a source file, or a host-selected entry function),
- a *resolver* mapping import specifiers to exactly one of: a Stilla source
  module, a standard-library module, or a host-provided module
  (Core §2.4, Runtime §2.6),
- a *host interface registry* describing the statically known interface of
  each host-provided module (Core §2.6, Runtime §3.1),
- an allocator; all frontend data is arena-owned and freed with the result.

**Outputs**

- `ModuleGraph` (phase 1): the transitive closure of modules reachable from
  the entry point, each with complete `ModuleInfo`, in dependency order,
  with import cycles rejected;
- `Annotation` per module (phase 2): the side-table of resolved types,
  binding types, ownership state, and specialized `FuncInstance`s — the
  existing model in `src/passes/checker.zig`, extended to be cross-module;
- `IrModule` (phase 3): per-module init function and per-function CFG IR,
  with host binding calls lowered to `SysCall` instructions.

**Diagnostics** are reported as `ast.Diagnostic` (`span` + message), first
error wins, mirroring the lexer/parser/checker convention.

## 3. Phase 1 — Module graph construction and module-level annotation

> Goal: *check and annotate module-level information for the current AST,
> recursively expand to dependent modules, detect cycles and sort. After
> this, all modules for the program have module-level information computed.*

### 3.1 Module identity and specifier resolution

Every source file defines exactly one module (Core §2.1). A module is
identified by its **resolved specifier**; the string written in
`import("specifier")` is the *written* specifier (Core §2.4).

Resolution maps a written specifier to one of (Runtime §2.6):

1. a Stilla source module — the file is loaded and parsed;
2. a standard-library module — loaded like a source module, from the
   implementation's standard-library bundle;
3. a host-provided module — no source is loaded; its interface is taken
   from the host interface registry as *declarations without definitions*
   (see §5.6).

Resolution must be unambiguous before execution; ambiguity and unresolved
specifiers are phase-1 diagnostics.

Resolution is **deduplicated by resolved specifier** — the same module is
loaded at most once (Runtime §2.1). The frontend preserves module identity
through statically known aliases (`const b = a;` where `a` is a
module-valued const, Core §2.4 / Runtime §2.4): alias consts record the
resolved module reference rather than creating a new module value.

### 3.2 Loading, parsing, and deduplication

For each newly resolved source/standard-library module:

1. load source text and build `ast.Source` (line index, spans);
2. lex and parse to `ast.Program` (existing `lex.zig` / `parser.zig`);
3. assign the module a `SourceId` in the compilation's source table.

A `ModuleInfo` node is created for the resolved specifier. Modules already
present in the graph (by resolved specifier) are never re-loaded — this is
the frontend-side form of "instantiated at most once per context".

### 3.3 Module-level information computed per module

For each module, phase 1 computes and annotates everything that is
statically knowable **without analyzing function bodies**:

- **type members** — `struct_def`, `union_def`, `type_def` items with
  their generic parameter lists (Core §2.5: types are compile-time members;
  Core §12.1). Each module gets a member table keyed by declared name.
- **value members** — `const_def` names with their *declared* types (when
  annotated) and `func_def` names with their *signatures* (Core §2.5).
  Function signatures are resolved monomorphically (Core §6, §12.5);
  generic functions are recorded as templates, not value members
  (Core §12.4).
- **the generated module struct type** — each module is given a
  compiler-generated nominal struct type whose members are the module's
  runtime value members (Core §2.1). This type is not nameable in source;
  it is the type of the value produced by `import(...)` and by
  module-valued const aliases.
- **import edges** — every `import("specifier")` found in a module-level
  `const` initializer (Core §2.2). Edges are kept in the order the
  imports appear in source (declaration order, Runtime §2.3).
- **`using` aliases** — path aliases are resolved against names known at
  module scope and annotated (Core §2.8); they are compile-time bindings,
  not module members.
- **host bindings** — members that have a *declaration and no Stilla
  definition*: `builtin` members (Runtime §4) and host-provided module
  members (Core §2.6, Runtime §3.1). These are flagged so phase 3 can
  lower calls to them as system calls (§5.6).

Module-level **checks** performed here:

- every `import(...)` appears only as a module-level `const` initializer,
  and its argument is a string literal (Core §2.2, §2.4);
- module-valued const initializers are `import(...)` or a statically known
  module binding (Core §2.3) — a module value may not flow into local
  bindings, parameters, returns, or aggregates;
- member names of the generated module struct are unique (module members
  are struct members, Core §2.1); `using` aliases may shadow without
  becoming members (Core §2.8);
- `import` cycles are rejected (§3.5).

### 3.4 Recursive expansion

Phase 1 is a worklist/DFS over imports starting from the entry module:

```text
pending = [entry]
while pending is not empty:
    m = pop pending
    for each import edge in m (in source order):
        if resolved specifier already in graph: record edge to existing node
        else: resolve → load → parse → collect module info → push m' to pending
```

The result is the **transitive closure** of modules reachable from the
entry point — "recursively expand to dependent modules". Recursion is
bounded by the module count; each module is processed once.

### 3.5 Import-cycle detection and topological sort

Import cycles are rejected in Stilla v1.3 (Core §2.4, Runtime §2.6). The
frontend detects them with a classic three-color DFS over the import graph
(`src/passes/topo_sort.zig`):

- **white** — not yet visited;
- **gray** — on the current DFS stack;
- **black** — fully processed.

If an import edge leads to a *gray* module, the cycle is reported as a
diagnostic naming the modules in the cycle (`a.st` imports `b.st` imports
`a.st`). The frontend stops the build; no ordering is produced for a
cyclic program.

When the DFS completes, modules are collected in **reverse postorder**:
a module appears **after** every module it imports, and **before** every
module that imports it. This order:

- makes every cross-module name/type lookup in phase 2 resolvable (a
  module's imported dependencies are already fully annotated);
- is exactly the order the runtime instantiates modules (dependencies
  before dependents, each at most once — Runtime §2.1, §2.3).

Ordering is deterministic: ties (sibling modules) are broken by resolved
specifier so the pipeline is reproducible.

> Note: import cycles are distinct from two other cycle forms that are
> handled elsewhere: module-constant *initialization order* within a module
> — an initializer may not transitively read a module constant declared
> later, while function references are order-independent
> (Core §5, §6.5 — checked in phase 2, see §4.6) — and recursive *types*,
> which are legal only through indirection (Core §18 — handled by type
> resolution).

### 3.6 Data structures

```zig
/// How a written specifier resolved (Runtime §2.6).
const ModuleKind = enum { source, standard_library, host };

/// One loaded module with its phase-1 annotation.
pub const ModuleInfo = struct {
    /// Resolved specifier; the graph key (Runtime §2.1).
    specifier: module.Specifier,
    kind: ModuleKind,
    /// The parsed module, when source or standard library.
    source: ?*const ast.Source,
    program: ?*const ast.Program,

    /// The compiler-generated nominal struct type (Core §2.1): its
    /// members are the module's runtime value members.
    struct_type: *typeinfo.StructType,

    /// Dependency edges in declaration order (Runtime §2.3).
    imports: []*ModuleInfo,
    /// Topological rank: dependencies have strictly lower rank.
    order: u32,

    // Member tables (all arena-owned).
    types: MemberTable,      // struct_def / union_def / type_def, with generic params
    values: MemberTable,     // const_def and monomorphic func_def signatures
    templates: MemberTable,  // generic func_def / struct_def / union_def / alias
    using_aliases: MemberTable, // resolved path aliases (Core §2.8)

    /// Members that are declarations without definitions — `builtin`
    /// members and host-module members. Phase 3 lowers calls to these as
    /// system calls (§5.6).
    host_bindings: []HostBinding,
};

pub const HostBinding = struct {
    span: ast.Span,
    name: ast.Ident,
    /// The declaration's resolved monomorphic signature.
    signature: *typeinfo.TypeInfo,
    /// Index of the binding in its module's member table; stable, so the
    /// runtime can dispatch syscalls by (module, member_index).
    member_index: u32,
    /// The host implementation, when registered.
    impl: ?*const anyopaque,
};

/// The result of phase 1: every module of the program, in dependency
/// order, with module-level info computed.
pub const ModuleGraph = struct {
    modules: []*ModuleInfo,        // topological order
    by_specifier: std.StringHashMapUnmanaged(*ModuleInfo),
    entry: *ModuleInfo,
};
```

**Phase-1 invariant:** *after phase 1, all modules for this program have
module-level information computed.* Cross-module member lookup — `calc.add`,
`geometry.Point`, `std.math.sqrt` (Core §2.5, §2.7) — is fully decidable
from the graph alone.

## 4. Phase 2 — Block-level inference, generic expansion, ownership

> **Status (current frontend): fully implemented.** The checker is the
> phase-2 driver — `src/passes/checker.zig` plus `checker_annotate.zig`
> (block-level name resolution, expression/pattern inference, binding-state
> tracking) and `checker_validate.zig` (the consumer checks) — wired into
> `frontend.compile` between phase 1 and phase 3. It performs §4.1 name
> resolution (including block-level `using`), §4.3 inference with per-module
> side tables, §4.4 generic expansion (§12 instances with monomorphized
> bodies, deduplicated and checked under substitution; host bindings get
> body-less instances), §4.5 `move`/`drop`/use-after-move binding states and
> conditional-release state merging through `if`/`match`/`and`/`or`/`for`
> (Core §10.10), and all of §4.6: type mismatch, match exhaustiveness,
> type-test, refutable-pattern, non-capture, borrow-lifetime,
> module-constant init-order, recursive-type, and drop-hook-restriction
> checks. The lowering (`src/lower.zig`) remains structural — it does not yet
> consume the annotation (Pass 5); instance lowering is Pass 5.4. Tracked as
> **Pass 3** in §6.

> Goal: *annotate name, type, ownership, and expression at block level, and
> expand generics. After this, type mismatch, non-exhaustive match, and
> ownership transfer issues can be checked.*

Phase 2 analyzes module bodies in **topological order** from phase 1, so a
module's references to its imported dependencies resolve against their
already-annotated module info. This is the existing checker
(`src/passes/checker.zig`) extended to be cross-module; its pass structure is
preserved per module:

1. collect named declarations (module scope);
2. resolve `using` aliases — at module scope and inside blocks; both are
   scoped compile-time bindings, not runtime members (Core §2.8, §13.1);
3. check items in order — const types, function declarations, struct and
   union instantiation, drop-hook bodies (Core §2.8, §5, §6, §7, §9).

### 4.1 Cross-module name resolution

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
  bindings (Runtime §4).

Module-qualified type lookup is static: module values never enter local
value flow (Core §2.3), so a qualified path always denotes a statically
known member.

### 4.2 Type resolution

Every syntactic `ast.Type` is resolved to a `typeinfo.TypeInfo`
(`resolveType`), including:

- generic struct/union instantiations with their `args` filled
  (`Option[int32]` → `UnionType` with args, Core §12.1);
- transparent alias expansion — aliases leave no node (Core §11.2);
- the primitive types `any` and `hostdata` (Core §11.6, §11.7): `any` is
  the top type — always affine, carries a runtime type tag, and is
  recovered only by `as` or `match` type-test patterns (§4.6);
  `hostdata` is an opaque affine payload constructible only by the host;
- ownership classification computed structurally (duplicable vs affine,
  Core §10.1–§10.3) to the **greatest fixpoint** (Core §10.3): a
  recursive type whose graph cycles through an owned component is affine,
  a cycle passing only through function types is not; deferred (`null`)
  while an unspecialized type parameter remains;
- monomorphic function types with parameter modes preserved (Core §6.3,
  §10.6).

### 4.3 Expression inference and annotation tables

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

### 4.4 Generic expansion

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

### 4.5 Ownership analysis

Ownership annotation drives the transfer checks:

- each resolved type carries its structural `Ownership` (§4.2);
- each local binding carries its ownership state: `is_borrow`
  (non-owning view: a `borrow` parameter, or an affine binding produced by
  a non-consuming `match`/`for`, Core §13.4–§13.5), `consumed`
  (ownership transferred by `move`, or destroyed by `drop`), `released` —
  **definitely released**, the state of an enclosing binding after a
  conditional construct released it on every path (Core §10.10) — and
  `maybe` — **maybe-affine**, released on some but not all normal paths
  through a conditional construct; a definitely-released or maybe-affine
  binding is unusable afterward, and only a maybe-affine binding is
  conditionally destroyed at scope end (in the IR: through its cleanup
  token — ir.md §6.4);
- `move name` marks the named binding consumed (Core §10.4);
- `drop name;` marks it destroyed (Core §9.4);
- a `borrow` parameter receives a non-owning view and leaves the caller's
  ownership unchanged (Core §10.6);
- a `move` parameter transfers ownership; passing an existing affine owner
  requires `move owner` at the call site, while a fresh affine value may
  transfer directly (Core §10.6, §18);
- plain parameters accept only duplicable argument types (Core §10.6).

### 4.6 Checks enabled by annotation

Once the annotation of a block is complete, the following are decidable
and enforced. This is the *raison d'être* of phase 2: each check consumes
the annotation and emits an `ast.Diagnostic` on failure.

**Type mismatch** — function arguments and return values must match
exactly unless the source type is `never`, the required type is `any`, or
a transparent alias expands to the required type (Core §18 *Typing*);
coercion to the top type `any` is the sole implicit widening (Core §18
*Conversion*, §11.6), and an affine source must be `move`d into it;
operator typing per Core §16.3 (`int32 + int32 → int32`, `str + str →
str`, comparisons → `bool`, `as` conversions only `int32 ↔ float32` and
`any as T` — the invalid-cast case traps at runtime, Runtime §7.2);
branch unification with `never` and `any` coercions (Core §13.2);
declared const type vs inferred type (Core §5).

**Match not exhausted** — a `match` over a union must cover every variant
unless an irrefutable arm exists (Core §13.3, §18 *Match*); a `match`
over an `any` value must include a wildcard `_` arm, because the tag space
is open (Core §11.6.2); `let` and `for` require irrefutable patterns —
refutable patterns are accepted only by `match`, and type-test patterns
(`int32 n`, Core §14.7) are refutable and accepted only by `match`, only
for an `any` scrutinee (Core §18 *Patterns*, §14).

**Ownership transfer issues** — use after move or destruction
(Core §18 *Ownership*); moving or dropping a borrowed affine value;
returning/ storing a borrowed value as owned; partial movement from fields
or indexed elements (whole-owner rule, Core §18 *Whole-owner rule*);
consuming destructuring of a struct that defines its own `drop` hook
(Core §14.6); double `move` of the same owner.

**Conditional release** (Core §10.10) — an affine binding released on a
normal path through a conditional construct — `if`/`else`, `match`,
short-circuit `and`/`or` — may be released on some paths and not others.
After the construct the binding is
exactly one of definitely owned, maybe-affine (`maybe` in §4.5), or
definitely released (`released` in §4.5). A maybe-affine binding is
unusable afterward and is destroyed conditionally at scope end: in the
IR the implementation arms a cleanup token at the construct's entry and
emits `drop_cleanup` at scope end, destroying the value only if it is
still alive on the path that got there (Core §10.10, Runtime §6.1,
ir.md §6.4).

**Additional checks that share the same annotation** — the non-capture
rule for functions and lambdas (Core §6.2), borrow-lifetime restrictions
(`borrow` never transfers ownership; borrowed affine values cannot be
moved, dropped, returned as owned, or stored into an owning location,
Core §18 *Borrowing*), module-constant initialization order — an
initializer must not transitively call a function that reads a module
constant declared later, while function references themselves are
order-independent (Core §5, §6.5), recursive types without indirection
(Core §18 *Recursion*), and the destruction-view restrictions inside
`drop` hook bodies — the hook argument may not be moved, dropped,
escaped, returned, or used to transfer field ownership
(Core §9.2, §18 *User drop hook*).

> The wording matters: inference, expansion, and annotation are the
> prerequisite; the *checks* are a consumer of the annotation. Some checks
> are naturally interleaved with inference (an inference failure is
> reported eagerly), but the phase's contract is that once annotation is
> complete, every check above is decidable and has been run.

### 4.7 Data structures

The phase-2 output extends the existing `checker.Annotation`:

```zig
pub const Annotation = struct {
    arena: std.heap.ArenaAllocator,

    // Existing side tables (per module, arena-owned).
    type_of:    std.AutoHashMapUnmanaged(*const ast.Type, *typeinfo.TypeInfo),
    expr_of:    std.AutoHashMapUnmanaged(*const ast.Expr, *typeinfo.TypeInfo),
    binding_of: std.AutoHashMapUnmanaged(u32, *typeinfo.TypeInfo),
    call_of:    std.AutoHashMapUnmanaged(*const ast.Call, *FuncInstance),
    instances:  std.ArrayList(*FuncInstance),

    // Phase-2 additions: one annotation set per module, keyed by the
    // module's resolved specifier.
    per_module: std.StringHashMapUnmanaged(*ModuleAnnotation),

    // Internal checker state (existing): const types, func signatures,
    // builtin declarations, resolution guards.
};

pub const ModuleAnnotation = struct {
    module: *ModuleInfo,
    /// Resolved declaration of each module-member name (name annotation).
    names: std.StringHashMapUnmanaged(*const ast.Ident),
    /// Per-binding ownership state for diagnostics.
    bindings: std.AutoHashMapUnmanaged(u32, BindingState),
};
```

The implementation matches this sketch with the per-use-site tables living
per module: `ModuleAnnotation` carries `call_of` (ast.Call → *FuncInstance)
and `spec_of` (ast.Specialize → *FuncInstance), while the deduplicated
`instances: ArrayList(*FuncInstance)` list lives on the global
`Annotation` (keyed by declaration + type arguments across all modules).

**Phase-2 invariant:** *every expression, binding, and type use is
annotated; the program is fully monomorphic; no type, exhaustiveness, or
ownership diagnostic remains.* Phase 3 consumes annotated AST + module
graph and produces no more semantic errors.

## 5. Phase 3 — CFG-based IR generation

> Goal: *generate IR based on a CFG; lower host binding functions (which
> have only a declaration and no definition) to system calls.*

Phase 3 lowers the annotated, monomorphic AST into a CFG-based IR:
functions become directed graphs of basic blocks over typed values, with
explicit ownership operations and control flow. It is the last frontend
phase and the runtime's input. The IR itself — 3-address code in SSA
form — is specified authoritatively in [`ir.md`](ir.md); the sketch in
§5.2 below is superseded by ir.md §4–§11, and this section describes the
lowering contract.

### 5.1 IR model

- **`IrModule`** — one per `ModuleInfo`: the module's member storage
  layout, its init function (§5.5), and its host bindings (§5.6).
- **`IrFunc`** — one per runtime function: each monomorphic function
  declaration and each `FuncInstance` (host bindings get no `IrFunc` —
  they are syscalls only). Contains the signature (parameter modes, return
  type), the entry block, and all blocks.
- **`BasicBlock`** — a sequence of value ops terminated by exactly one
  `Terminator`. Blocks are laid out so that fall-through is the common
  case; explicit edges everywhere else.
- **`Value`** — an SSA-like op with a type and (for affine results) an
  ownership tag. Stilla's immutable bindings with shadowing are naturally
  SSA (Core §4: "Stilla is therefore SSA-friendly"): every `let` produces
  a fresh value; shadowing is a fresh name, not a reassignment.

Deterministic evaluation (Runtime §5) is structural: the lowering order of
ops *is* the evaluation order — callee before arguments, arguments left to
right, base before member/index, operands left to right, scrutinee before
arm selection.

### 5.2 Values, ops, and terminators

```zig
/// A typed, SSA-like operation producing one value.
pub const Value = struct {
    span: ast.Span,
    type_: *typeinfo.TypeInfo,
    /// Ownership of the produced value (duplicable / affine).
    ownership: ?typeinfo.Ownership,
    op: Op,
};

pub const Op = union(enum) {
    const_: ConstValue,          // int / float / string / bool / void
    arg: u32,                    // function parameter by index
    module_ref: *ModuleInfo,     // module value (module-resident, Core §2.3)
    load_member: LoadMember,     // module member: (module, member_index)
    load_field: LoadField,       // struct member: (base, field_index)
    index: Index,                // list element: (base, index) with bounds check
                                 // (source spelling base@[index], Core §11.5)
    arithmetic: Arithmetic,      // add/sub/mul/div/rem (Core §16.3)
    compare: Compare,            // eq/ne/lt/le/gt/ge → bool
    logic: Logic,                // and_/or_/not (short-circuit handled by CFG)
    cast: Cast,                  // int32 ↔ float32, and any as T (Core §16.3)
    construct: Construct,        // struct / union variant / tuple / list / box
    copy: Copy,                  // implicit copy of a duplicable value
    borrow: Borrow,              // non-owning view (borrow parameter, Core §10.6)
    move: Move,                  // ownership transfer (Core §10.4)
    drop: Drop,                  // deterministic destruction (Core §9)
    call: Call,                  // call to a Stilla function value (IrFunc)
    syscall: SysCall,            // host binding — see §5.6
};

pub const Terminator = union(enum) {
    ret: ?*Value,
    branch: *BasicBlock,
    branch_cond: struct { cond: *Value, then_: *BasicBlock, else_: *BasicBlock },
    switch: Switch,              // match on a union discriminant or an
                                 // `any` runtime type tag (Core §11.6.2)
    trap,                        // never / builtin.panic (Runtime §7)
};

pub const BasicBlock = struct {
    span: ast.Span,
    ops: []*Value,
    terminator: Terminator,
};

pub const IrFunc = struct {
    span: ast.Span,
    name: ast.Ident,
    /// The source function or FuncInstance this lowers.
    decl: *const ast.FuncDef,
    instance: ?*checker.FuncInstance,
    signature: *typeinfo.TypeInfo,
    entry: *BasicBlock,
    blocks: []*BasicBlock,
};
```

### 5.3 Lowering rules

Lowering is a recursive walk of the annotated AST over a builder that
emits ops into the current block and introduces new blocks at control-flow
points.

- **Literals and consts** → `const_`. A `void`-typed result that nothing
  observes — an expression statement, or the void tail of an
  `if`/`match`/`for` whose value no binding or return reads — is **not**
  materialized as a `const void` op; only its effects (calls, syscalls,
  drops) are emitted. `void` is a singleton type with no observable value
  and a void return is a bare `ret`, so such a value is always dead; this
  is a lowering rule (Pass 4.1), not an optimizer rewrite.
- **`path` value expressions** → `arg` (parameter), `module_ref`
  (module-valued const), `load_member` (module function/const member),
  `copy`/`borrow` (duplicable vs affine binding use).
- **Binary ops** → `arithmetic` / `compare` / `logic`. `and` and `or` do
  **not** become a single op — they lower to a `branch_cond` diamond so
  the right operand is evaluated only when required (Runtime §5):
  `a and b` evaluates `b` only if `a` is `true`.
- **`if`** (Core §13.2) → evaluate condition, `branch_cond` to then/else
  blocks, join block receives the selected branch's value; no `else` →
  else block yields `void`.
- **`match`** (Core §13.3) → evaluate scrutinee once; for a union, a
  `switch` on the variant discriminant dispatches to per-arm blocks
  (pattern tests compile to discriminant comparisons / payload binds /
  nested tests for list shapes); for an `any` scrutinee, a `switch` on the
  runtime type tag dispatches to type-test arms and a required wildcard
  `_` arm (Core §11.6.2, §14.7) — duplicable payloads copy out, affine
  payloads borrow (non-consuming) or transfer ownership (consuming);
  arms join at a common exit block; `never` arms end in `trap` and
  contribute no value; the join value is the match result.
- **`let`** → evaluate init, then bind the produced value as a fresh SSA
  name; `let` with a pattern lowers to destructuring ops (see §5.4).
- **`move name`** (Core §10.4) → `move` of the named binding; the old SSA
  name is dead afterwards.
- **`drop name;`** (Core §9.4) → `drop` of the named binding.
- **Member access** (Core §15.1) → `load_field` for structs; `load_member`
  for module members; chained paths lower left-to-right
  (`std.math.sqrt` → load `std` module, load `math` member, load `sqrt`
  member — Core §2.7).
- **`index`** → base, then index (Runtime §5: index after base), then
  `index` with a bounds check that traps on failure (Runtime §7.2). Source
  spelling is `base@[index]` (Core §11.5); the v1.2 `base[index]` form no
  longer parses (Grammar: `index-suffix`).
- **Calls** → evaluate callee then arguments left to right (Runtime §5);
  a Stilla function value lowers to `call`; a host binding lowers to
  `syscall` (§5.6).
- **Construction** (Core §8.1, §11) → `construct` ops: struct fields in
  written order (evaluation order; literal field order does not affect
  reverse-declaration-order destruction, Runtime §6.2), union variant with
  discriminant + payload, tuple/list elements left to right, `box`
  indirection.
- **Casts** → `num_cast` for the Core §16.3 numeric pair (`int32 ↔
  float32`); `any as T` lowers to `any_unpack_copy` (duplicable target,
  the `any` stays owned) or `any_unpack_move` (`(move any) as T`, the
  complete `any` is consumed and payload ownership transfers); an invalid
  `any` recovery — a tag mismatch — is a deterministic runtime trap with
  no unwinding (Core §11.6.1, Runtime §7.2), and phase 2 ensures the
  source is `move`d for an affine target type. Coercions into `any`
  (`any_pack_copy` / `any_pack_move`) are materialized at call arguments,
  `ret` of an `any`-typed function, and the predecessor edges of an `any`
  join (ir.md §4.4).
- **`::[...]` specialization** — already eliminated in phase 2; the
  specialized instance's body is lowered as its own `IrFunc`.

### 5.4 Destruction placement

Destruction is deterministic (Runtime §6) and phase 3 makes it explicit:

- **scope-end destruction** — every live affine local owner is destroyed
  when its scope ends during normal control flow (Core §18 *Destruction*);
  because ownership state is static, only **definitely-owned** bindings
  get a `drop` — a definitely-released binding is skipped
  (Core §10.10). The lowering pass inserts `drop` ops at the exit of every
  block that terminates the scope, including loop back-edges for a `for`
  body and every `if`/`match` branch;
- **user drop hook** — destroying a struct that defines `drop` emits the
  hook call followed by reverse-declaration-order field destruction
  (Core §9, Runtime §6.2);
- **`hostdata` payloads** — destroying a `hostdata` value runs no Stilla
  `drop` hook; it hands the opaque payload to the host for disposal, which
  phase 3 records as an ordinary `drop` of the affine value
  (Core §11.7, Runtime §3.4, §7.3);
- **affine temporaries** — temporaries surviving to the end of a full
  expression are destroyed in reverse creation order (Runtime §6.4): the
  builder records a per-expression temporary stack and emits its `drop`s
  at the expression's end;
- **`never`/trap paths** — panic and runtime traps skip all destruction
  (Core §18 *Panic and traps*): a `trap` terminator performs no drops.

Destruction is placed *after* phase-2 ownership analysis, which already
validated that every affine value is destroyed exactly once — phase 3 only
materializes it.

### 5.5 Module init functions

Each `IrModule` gets an **init function** that:

1. instantiates imported modules as required (dependency order = phase-1
   topological order, Runtime §2.3);
2. evaluates module constants **strictly in declaration order**
   (Core §5, Runtime §5) and stores them in module storage slots
   (the module struct's member layout);
3. lowers `import("specifier")` initializers to `module_ref` values —
   stable references to the (at most once) instantiated module
   (Runtime §2.1, §2.4), so `const a = import("m"); const b = a;` share
   storage;
4. records init order so the runtime can destroy module-owned affine
   constants in **reverse initialization order** during normal teardown
   (Runtime §2.5).

Host-provided modules and `builtin` need no init function: their members
have no Stilla definitions to evaluate.

### 5.6 System calls for host bindings

A **host binding** is a function member with a *declaration and no Stilla
definition*:

- every `builtin` member (`print`, `str`, `len`, `range`, `map`, `fold`,
  `box`, `peek`, `unbox`, `panic`, `assert`, `hash` — Core §3, Runtime §4);
- every member of a host-provided module (`os.open`, `file.close`, … —
  Core §2.6, Runtime §3.1), whose statically known interface is supplied
  by the host interface registry.

Phase 1 flags these in `ModuleInfo.host_bindings`; phase 2 gives them
resolved signatures but no `FuncInstance` body; phase 3 applies one rule:

> **A call to a host binding is lowered to a `SysCall` instruction —
> never to an in-IR `call`. A host binding has no `IrFunc`; its body is
> never lowered, because no body exists.**

```zig
/// A system call: transfer to the host implementation of a binding.
/// The runtime dispatches on (module, member_index) — stable, because
/// module member layout is static (Core §2.1, Runtime §2.2).
pub const SysCall = struct {
    span: ast.Span,
    target: SysCallTarget,
    /// Arguments, evaluated left-to-right before the call (Runtime §5),
    /// with parameter modes applied: plain/borrow pass views or copies,
    /// move passes ownership (Core §10.6).
    args: []*Value,
    /// Result type; `never` for panicking bindings (builtin.panic).
    ret: *typeinfo.TypeInfo,
};

pub const SysCallTarget = union(enum) {
    builtin: BuiltinId,          // enum of Runtime §4 members
    host_module: struct {
        module: *ModuleInfo,     // resolved host-provided module
        member_index: u32,       // into the module's member table
    },
};
```

Lowering rules around syscalls:

- **argument evaluation** — syscall arguments are evaluated exactly like
  call arguments: left to right, once, before the transfer (Runtime §5);
  `move` args are evaluated as moves, `borrow` args as views;
- **no inlining, no codegen** — the syscall is opaque to the frontend; the
  runtime's `builtin` vtable (`src/builtin.zig`) and host dispatch own the
  implementation (Runtime §3.2, §3.4);
- **panicking bindings** — `builtin.panic` returns `never`; its call is
  followed by a `trap` terminator, and no destruction runs after it
  (Runtime §7);
- **generic builtins** — `builtin.len`, `builtin.map`, `builtin.fold`
  are generic (Runtime §4); phase 2 specializes them like any generic
  function (producing a `FuncInstance` with `body = null`), and phase 3
  lowers the specialized call site to a syscall carrying the resolved
  concrete signature;
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
trivial: `(module, member_index) → host function`.

### 5.7 Outputs and downstream consumers

```zig
/// Phase-3 output: the program as a CFG, ready for the runtime.
pub const IrProgram = struct {
    modules: []*IrModule,        // phase-1 order
    funcs: []*IrFunc,            // all monomorphic functions + instances
    entry: ?*IrFunc,             // the host-selected entry, when present
};
```

Consumers of the CFG:

- **runtime interpreter/compiler** — executes `IrFunc` bodies; blocks and
  terminators make evaluation order and destruction explicit;
- **module instantiation** — `IrModule` init functions run in topological
  order, each module at most once (Runtime §2.1, §2.3);
- **deterministic destruction** — scope/temporary `drop` ops and
  reverse-order teardown are already materialized (§5.4, §5.5);
- **static analysis / mid-level optimizer** — the CFG is the base for the
  mid-level optimizer (Passes 7–8), a fixed sequence of semantics-
  preserving CFG→CFG rewrites — tail call optimization, partial
  redundancy elimination, dead-block elimination, jump threading, drop
  elision, and phi simplification — run as a **single ordered pass** (no
  iteration to fixpoint) behind `frontend.Options.optimize` (default off;
  the `stilla` executable enables it). Constant folding, arithmetic
  simplification, common subexpression elimination, and copy propagation
  need no passes at all: they run on-the-fly at each instruction's
  construction site (§4.3, braun13cc.pdf §3.1). Each rewrite preserves
  observable behavior (Runtime §5: "An implementation may optimize only
  when the observable behavior is unchanged").

## 6. Implementation passes and TODO

The pipeline is implemented in **passes**, tracked here with checkboxes.
Passes 1–4 are complete — their scope, files, and acceptance records are
captured in this checklist below — as are Pass 7 (tail call optimization)
and Pass 8.3–8.8 (PRE, dead-block elimination, drop elision, jump
threading, phi simplification). Constant folding, arithmetic
simplification, CSE, and copy propagation no longer exist as passes: they
run on-the-fly at construction (§4.3). The remaining work is the agreed
fast-optimization redesign: the dead-void lowering fix (4.1), the
optimizer's wiring into
`frontend.compile`, and the Pass 8 additions — jump threading, drop
elision, phi simplification, and the optimization harness (8.6–8.9).
Pass 5 remains the forward TODO for the phase-3 × phase-2 integration
that consumes the phase-2 annotation.

- [x] **Pass 1 — Lexer, parser, AST** (`src/lex.zig`, `src/parser.zig`,
      `src/ast.zig`) — implemented.
- [x] **Pass 2 — Phase 1: module graph** (`src/module.zig`,
      `src/moduleinfo.zig`, `src/passes/topo_sort.zig`,
      `src/passes/type_resolve.zig`, `src/stdbundle.zig`, `std/bundle.zig`,
      `src/frontend.zig`, `src/main.zig`) — implemented.
- [x] **Pass 3 — Phase 2: annotation and checks** (the checker,
      `src/passes/checker.zig` + `checker_annotate.zig` +
      `checker_validate.zig` + `checker_ownership.zig`) — implemented
      (annotation, ownership analysis, and the §4.6 checks below).
  - [x] **3.1 Data structures and wiring** — `checker.Annotation` has the
        §4.7 shape (`type_of`, `expr_of`, `binding_of`, `bindings`,
        `call_sig`, `names`, `per_module`); `ModuleAnnotation` added; the
        checker is wired into `frontend.compile` between phase 1 and phase
        3, iterating modules in phase-1 topological order. (Resolved types
        are the IR-native `cfg.Type`, matching phase 3; the lowerer does
        not consume the annotation until Pass 5.)
  - [x] **3.2 Cross-module name resolution** (§4.1) — `resolvePath` for
        dotted paths (`module.value`, `module.Type`, chained
        `module.submodule.value`, `builtin.member`) against each module's
        member tables; module-qualified type lookup stays static;
        block-level `using` aliases (Core §13.1) are bound in scope.
  - [x] **3.3 Type resolution** (§4.2) — `resolveType` to `cfg.Type`
        (generic instantiations, transparent alias expansion,
        `any`/`hostdata`); structural ownership classification via
        `cfg.Type.ownership()` + `type_shape.ownershipOf` (greatest
        fixpoint over recursive types); monomorphic function types with
        parameter modes.
  - [x] **3.4 Expression inference and annotation tables** (§4.3) —
        `inferExpr` over all 24 expression variants; every expression head
        resolved (locals, module members, paths, callees); binding types;
        arena-owned side tables.
  - [x] **3.5 Generic expansion** (§4.4) — `src/passes/monomorphize.zig`
        (deep-copy monomorphization of a template body under a concrete
        substitution) plus `type_infer.bindTypeArgs` / `substSignature` /
        `specializeSignatureExplicit`. Each used specialization produces a
        `FuncInstance` (concrete `type_args`, monomorphic signature, and —
        for defined functions — a monomorphized body) deduplicated by
        (declaration, type arguments) and recorded in `Annotation.instances`;
        call sites map to instances via `ModuleAnnotation.call_of`, and
        value-position `::[...]` specializations via `spec_of`. Instances
        are checked under substitution only — unspecialized generic bodies
        are never checked (Core §12.4), and an unspecialized generic used as
        a value is an error (Core §12.4). Host bindings get instances with
        no body (frontend §5.6); instance *lowering* is Pass 5.4.
  - [x] **3.6 Ownership analysis** (§4.5) — `owned`/`borrowed`/`consumed`/
        `released` states, `move`/`drop` marking, use-after-move, and
        conditional release with state merging through
        `if`/`match`/`and`/`or` (Core §10.10).
  - [x] **3.7 Checks** (§4.6) — type mismatch (call args/return/let/
        const/binary/cast), union match exhaustiveness, `any` requires a
        wildcard, type-test patterns only for `any`, refutable patterns in
        `let`/`for`, non-capture (Core §6.2), borrow lifetimes (borrowed
        affine values cannot be moved, dropped, returned as owned, or
        stored into an owning location — single-name and dotted-path
        projections, Core §10.7), recursive types without indirection
        (three-color DFS over the module's direct storage edges, Core
        §11.3), module-constant initialization order (scope-aware walk of
        every initializer, including transitive reads through local
        function calls, Core §5), and the drop-hook destruction-view
        restrictions (the hook body is annotated with the view bound as a
        borrowed affine local, so move/drop/return/field-transfer are
        rejected; Core §9.2).
  - [x] **3.8 Phase-2 tests** — black-box diagnostics per check in
        `src/checker_tests.zig` (message + span); `stdbundle_tests` runs
        the bundle through the graph API.
- [x] **Pass 4 — Phase 3: CFG lowering** (`src/cfg.zig`,
      `src/passes/cfg_lex.zig`, `src/passes/cfg_parse.zig`,
      `src/passes/cfg_print.zig`, `src/lower.zig`) — implemented.
  - [x] **4.1 dead-void elision at lowering** — the lowerer does not
        materialize a `const void` for a void result nothing observes
        (§5.3); implemented in `cfg_lower_expr.zig` (`emitVoid` emits a
        phantom value with no instruction) and `cfg_lower_module.zig`
        (void member stores are dropped);
  - [x] **4.2 SSA construction** — the IR is SSA by construction
        ("locals are values", ir.md §6), so the Braun et al. registry
        (`ssa_construct.zig`, braun13cc.pdf Algorithms 1–4) existed
        only for the `for` loop's loop-carried index — the sole source
        variable with multiple reaching definitions (Stilla has no
        mutation). The loop construct is gone (Core §13.5) and the
        registry with it: the only loops in the IR are produced by tail
        call optimization (Pass 7, `cfg_tail_call.zig`), which places
        its own header phis per parameter. Pass 8.7
        (`cfg_phi_simplify.zig`) still collapses single-incoming phis.
  - [x] **4.3 on-the-fly optimization at construction** — the IR node
        constructor (`cfg_lower_emit.zig`'s `emit`) performs the
        optimizations braun13cc.pdf §3.1 shows need no separate passes:
        constant folding (`tryFoldOp` — the same trap-preserving math as
        the old pass 8.1, now per-instruction at the emit site),
        arithmetic simplification (integer identities only — `x−x→0`,
        `x+0→x`, `x·1→x`, `x·0→0`, `x/1→x`, `x%1→0` — float identities
        are unsound: `x−x≠0` for NaN, `0·x≠0` for ±inf/NaN, `0+x≠x` for
        −0.0), common subexpression elimination (an identical pure
        computation earlier in the same block is reused directly — no
        `copy`; duplicable results only, no commutativity), and copy
        propagation (a `move` of a duplicable value lowers to the value
        itself, so the frontend emits no `copy` instructions). Passes
        8.1, 8.2, and 8.4 are folded into the constructor and no longer
        exist as CFG→CFG passes; the remaining Pass 8 sequence is
        tail-call optimization, 8.3 PRE, 8.5 dead-block elimination, 8.6
        drop elision, 8.8 jump threading, and 8.7 phi simplification.
- [ ] **Pass 5 — Phase-3 × phase-2 integration** — the lowerer consumes
      the annotation instead of re-deriving structure (frontend.md §5
      "annotated AST"):
  - [ ] **5.1** consume `Annotation` for borrow/move/drop decisions;
  - [ ] **5.2** emit `borrow` ops — currently never emitted (borrow
        parameters, non-consuming affine match payloads);
  - [ ] **5.3** non-consuming affine match payloads: borrow the payload
        while the scrutinee is dropped at scope end (phase-2 territory
        today);
  - [ ] **5.4** `::[...]` specialization lowering — the specialized
        instance's body lowers as its own `IrFunc` (frontend.md §5.3);
  - [ ] **5.5** block-level `using` lowering (once Pass 3.2 lands).
- [x] **Pass 6 — Validation and documentation**
  - [x] **6.1** ir.md §13 validator — `src/passes/cfg_validate.zig`
        (re-exported as `cfg.validate` / `lower.validate`), a
        schema-driven checker: structure, SSA dominance, op arity and
        typing from `cfg.opInfo`, and an edge-sensitive ownership
        dataflow (`Available` / `Consumed` / `MaybeConsumed` over the
        CFG, per-edge phi inputs, atomic `unpack_*` / `split_list`
        consumption). The
        frontend runs it on every lowered program; the optimizer runs it
        before the sequence and after every rewrite.
  - [ ] **6.2** cycle diagnostics name the full cycle path
        (frontend.md §3.5);
  - [ ] **6.3** docs sync — flip this §6 checklist and the §4 status
        callout; AGENTS.md/README checker rows; §3.6 sketch drift.
- [x] **Pass 7 — Tail call optimization** (`src/passes/cfg_tail_call.zig`,
      re-exported by `lower`) — a CFG→CFG rewrite of calls in tail
      position into frame-reusing jumps, so self-recursion becomes
      iteration. Runs first in the Pass 8 driver, on the lowered CFG,
      before the runtime consumes it (frontend.md §5.7). Implemented.
  - [x] **7.1** tail-position detection — a `call` (or `syscall`) whose
        result is immediately `ret`ed, or a `void`/`never` call directly
        followed by `ret`, in a block with no live affine state afterwards
        (§5.7 consumers);
  - [x] **7.2** rewrite — replace `call` + `ret` with a `br` back to the
        function's own entry block, re-binding the callee's parameters
        from the call arguments and splicing in phis for the reused
        frame's SSA values (ir.md §10.9). The chain drop is guarded: an
        intermediate chain block (between the call block and the ret
        block) must have exactly one predecessor, so it forwards only the
        call's result — an extra predecessor merges another arm's value,
        which dropping the chain edge would strand (multi-arm guarded
        recursion stays a call); and the ret block must keep at least one
        non-chain predecessor, so the rewrite cannot orphan the
        function's only `ret`;
  - [x] **7.3** ownership preservation — the rewrite must not reorder any
        `drop` or observable effect: the returned value's destruction
        schedule (Runtime §6) is unchanged because the frame is reused;
        only direct `call`s to a known `IrFunc` are candidates (a call
        through a function *value* has no statically known target);
  - [x] **7.4** tests in `frontend_tests.zig` — tail-recursive functions
        lower to loops that preserve semantics; non-tail calls, value
        calls, and calls with live affine state are left untouched.
- [ ] **Pass 8 — Mid-level optimizer** (`src/passes/cfg_optimize.zig`,
      re-exported by `lower`) — a driver that runs a fixed sequence of
      semantics-preserving CFG→CFG rewrites over the lowered CFG, after
      Pass 7 and before the runtime consumes it (frontend.md §5.7).
      Each sub-pass is one file in `src/passes/`; each rewrite must
      preserve observable behavior (Runtime §5) and the ir.md §13
      invariants.
      **Redesign policy (agreed):** the sequence runs as a **single
      ordered pass — no iteration to fixpoint** — so compile time stays
      near-linear; the driver is wired into `frontend.compile` behind
      `frontend.Options.optimize` (`false` by default; the `stilla`
      executable hardcodes it on; the toggle is code-only, no CLI flag),
      with the full ir.md §13 validator (`cfg.validate`, Pass 6.1) run
      before the sequence and after every rewrite — an optimizer bug that
      violates structure, SSA, typing, or the ownership dataflow is a
      compile-time diagnostic. The optimization harness (§8.9) measures
      instruction count (primary size metric), block count (secondary),
      and serialized text bytes (reported, not targeted) across the
      corpus (`examples/` plus the added benchmarks).
      The sequence and the per-pass checks:
  - [x] **8.1 constant folding — on-the-fly at construction** (§4.3) —
        fold `arithmetic`/`compare`/`logic`/`num_cast` ops whose
        operands are constant at their emit site (`cfg_lower_emit.zig`,
        `tryFoldOp`, braun13cc Algorithm 3's §3.1); `div`/`rem` by zero
        and out-of-range `float32 → int32` must still trap (Runtime
        §7.1). No separate pass — the fold math lives in the
        constructor;
  - [x] **8.2 common subexpression elimination — on-the-fly at
        construction** (§4.3) — reuse an identical pure computation
        earlier in the same block at its emit site; block-local (the
        first occurrence dominates), duplicable results only (ir.md
        §5.4), operands matched positionally (no commutativity); the
        reused value is returned directly, so no `copy` is involved. No
        separate pass;
  - [x] **8.3 partial redundancy elimination** (`src/passes/cfg_pre.zig`) —
        rewrite a computation available on some — but not all — incoming
        edges of a join to a phi, inserting the computation at the end of
        the edges that lacked it; candidates are pure, non-trapping ops only
        (comparisons, `not`, `type_is` — hoisting a trapping op onto a
        skipped path would change observable behavior, Runtime §7.2),
        duplicable results, operands defined in a strict dominator of the
        join; the join's computation is replaced by the phi with the same
        result value, and values are renumbered in text order (ir.md §13);
  - [x] **8.4 copy propagation — on-the-fly at construction** (§4.3) —
        a `move` of a duplicable value lowers directly to the value (a
        copy of a duplicable value is the value, ir.md §5.4), so no
        `copy` instructions reach the IR from the frontend. No separate
        pass;
  - [x] **8.5 dead-block elimination** (`src/passes/cfg_dead_block.zig`) —
        remove blocks unreachable from the entry; update phi incoming
        lists and predecessor sets accordingly (ir.md §3);
  - [x] **8.6 drop elision** (`src/passes/cfg_drop_elide.zig`) — remove a
        `drop` whose destruction is provably unobservable — the value is
        duplicable, or already dead; must never remove a user `drop` hook
        that performs output (ir.md §14) — implemented; a type with a
        user hook is always classified affine, so only duplicable drops
        are elided, and `drop_cleanup` / `cleanup_disable` (whose token's
        payload is an affine owner) are never elided (equivalence test in
        `frontend_tests.zig`);
  - [x] **8.7 phi simplification** (`src/passes/cfg_phi_simplify.zig`) —
        remove single-incoming phis, identical-phis, and self-referential
        trivial phis (braun13cc Algorithm 3: `φ(v, vφ) → v`, with the
        user walk iterated to a fixed point; all-self phis are kept — the
        IR has no undefined value), forwarding their operands —
        implemented (pairs with 8.8: threading produces single-incoming
        phis);
  - [x] **8.8 jump threading** (`src/passes/cfg_jump_thread.zig`) — merge
        empty forwarding blocks (a block whose only op is an
        unconditional `br` to a single successor) into the successor,
        re-wiring its phi incoming edges, so trivial blocks like an
        `if`-then branch that just jumps to the join are eliminated —
        implemented; chains collapse to their ultimate successor, cycles
        are left alone, and a candidate whose predecessor already
        targets the ultimate successor is skipped (no duplicate edges);
  - [x] **8.9 tests and harness** — each rewrite is verified round-trip
        (optimized IR re-parses, ir.md §13) and against the
        observable-behavior contract, including a per-pass equivalence
        test (drop elision must *not* elide a `drop` whose hook may
        `print` — an affine `hostdata` drop stays). The optimization
        harness compiles the corpus (`examples/` plus the added
        benchmarks: `ownership.st` with `drop` hooks, `match.st` ADT
        `match`), runs `optimize`, and
        reports instruction / block / text-byte counts before and after
        (the report prints only when the frontend test binary runs with
        stderr attached to a terminal — run the compiled
        `.zig-cache/o/*/test` binary directly; under `zig build test`
        stderr is a captured pipe, and the build runner replays any
        run-step stderr as an error, so the report is suppressed there to
        keep the log clean).

**Exit criterion for "frontend.md fully implemented":** `frontend.compile`
runs phases 1 → 2 → 3 and applies the Pass 8 optimizer when
`frontend.Options.optimize` is set; every §4.6 check has a diagnostic
test; the Pass 4.1–4.3 and Pass 8 (8.3–8.8) items above are checked; the
full suite (`zig build test`) passes. The fast-optimization milestone
(Pass 4.1–4.3 + Pass 8.3–8.8 + wiring) is **complete**, as is Pass 6.1
(the ir.md §13 validator, wired into the frontend and the optimizer);
Pass 5 and Pass 6.2 remain as future work.

## 7. Relationship to existing code

| Phase | Existing | To build |
| --- | --- | --- |
| lex / parse | `src/lex.zig`, `src/parser.zig` (tokens → `ast.Program` per file) | — |
| 1 — module graph | `src/module.zig` (`Specifier`, registry keyed by specifier); checker's single-module passes | `src/frontend.zig` (pipeline driver), `src/moduleinfo.zig` (`ModuleInfo`, `ModuleGraph`, resolver, cycle detection, topo sort) |
| 2 — annotation | `src/passes/checker.zig` (the phase-2 driver), `checker_annotate.zig` (name resolution, inference, binding states), `checker_validate.zig` (the checks), `checker_ownership.zig` (conditional-release state merging, §4.5/Core §10.10), `src/passes/monomorphize.zig` (generic expansion, §4.4), `src/typeinfo.zig` | — |
| 3 — CFG IR | `src/builtin.zig` vtable (syscall dispatch target) | `src/cfg.zig` (specified in [`ir.md`](ir.md): `Value`/`Instr`/`Op`/`BasicBlock`/`Terminator`/`IrFunc`/`IrModule`/`SysCall`), `src/passes/cfg_lex.zig` + `src/passes/cfg_parse.zig` + `src/passes/cfg_print.zig` (the IR text form's lexer, parser, and printer, re-exported by `cfg`), `src/lower.zig` (annotated AST → CFG, destruction placement, module init functions) |

The existing single-module checker becomes phase 2 instantiated over the
phase-1 graph; the `builtin_decls` mechanism (synthetic declarations with
no checked bodies) is exactly the seed of `host_bindings` (§5.6).

## 8. Non-goals and open questions

- **No general optimizer** — phase 3 emits direct, semantically faithful
  CFG; optimization runs as a later consumer (§5.7). The mid-level
  optimizer (Passes 7–8) is a fixed, small sequence of
  semantics-preserving CFG→CFG rewrites — tail call optimization plus
  folding, propagation, dead-block elimination, drop elision, and phi
  simplification — not a general, cost-model-driven optimizer; register
  allocation and instruction scheduling are out of scope.
- **Resolution is implementation-defined** (Core §2.4) — `frontend.md`
  fixes the pipeline shape, not the resolver's file/registry policy.
- **Borrow lifetimes** — phase 2 checks the v1.3 lexical rules (Core §10.7,
  §18) but does not infer regions; borrow info is carried into the IR as
  `borrow` ops for the runtime.
- **Module-value runtime model** — `module_ref` values are static; the
  runtime's exact storage representation of module values is open
  (`src/module.zig` TODO).
- **Host interface discovery** — the mechanism by which a host module's
  statically known interface is described (registry schema) is host-side
  policy; only the frontend's consumption of it is specified here.
