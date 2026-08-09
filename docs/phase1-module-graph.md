# Phase 1 — Module Graph Construction and Module-Level Annotation

> Status: **implemented** — Pass 2 in the frontend pipeline.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts).

## Goal

Check and annotate module-level information for the current AST,
recursively expand to dependent modules, detect cycles and sort.
After this phase, all modules for the program have module-level
information computed.

## Module identity and specifier resolution

Every source file defines exactly one module (Core §2.1). A module is
identified by its **resolved specifier**; the string written in
`import("specifier")` is the *written* specifier (Core §2.4).

Resolution maps a written specifier to one of (Runtime §2.6):

1. a Stilla source module — the file is loaded and parsed;
2. a standard-library module — loaded like a source module, from the
   implementation's standard-library bundle;
3. a host-provided module — no source is loaded; its interface is taken
   from the host interface registry as *declarations without definitions*
   (see [Phase 3 — System calls for host bindings](phase3-cfg-lowering.md#system-calls-for-host-bindings)).

Resolution must be unambiguous before execution; ambiguity and unresolved
specifiers are phase-1 diagnostics.

Resolution is **deduplicated by resolved specifier** — the same module is
loaded at most once (Runtime §2.1). The frontend preserves module identity
through statically known aliases (`const b = a;` where `a` is a
module-valued const, Core §2.4 / Runtime §2.4): alias consts record the
resolved module reference rather than creating a new module value.

## Loading, parsing, and deduplication

For each newly resolved source/standard-library module:

1. load source text and build `ast.Source` (line index, spans);
2. lex and parse to `ast.Program` (existing `lex.zig` / `parser.zig`);
3. assign the module a `SourceId` in the compilation's source table.

A `ModuleInfo` node is created for the resolved specifier. Modules already
present in the graph (by resolved specifier) are never re-loaded — this is
the frontend-side form of "instantiated at most once per context".

## Module-level information computed per module

For each module, phase 1 computes and annotates everything that is
statically knowable **without analyzing function bodies**:

- **type members** — `struct_def`, `union_def`, `opaque_def`, `type_def`
  items with their generic parameter lists (Core §2.5: types are
  compile-time members; Core §12.1). Each module gets a member table
  keyed by declared name. `opaque_def` is the host-backed opaque nominal
  type of Core §11.8: no fields, no variants, unique by declaration,
  legal only in standard-library / host-provided module interfaces.
- **value members** — `const_def` names with their *declared* types (when
  annotated) and `func_def` names with their *signatures* (Core §2.5).
  Function signatures are resolved monomorphically (Core §6, §12.5);
  generic functions are recorded as templates, not value members
  (Core §12.4). Phase 3 splits value members into the four AIR member
  kinds (air.md §7): constants occupy storage slots, functions and
  module-valued constants are static references, and host bindings are
  syscall targets. Intrinsic members (below) expand during lowering and
  occupy no AIR row (air.md §5.6).
- **the generated module struct type** — each module is given a
  compiler-generated nominal struct type whose members are the module's
  runtime value members (Core §2.1) — the source of the AIR member table
  (air.md §7). This type is not nameable in source; it is the type of the
  value produced by `import(...)` and by module-valued const aliases.
- **import edges** — every `import("specifier")` found in a module-level
  `const` initializer (Core §2.2). Edges are kept in the order the
  imports appear in source (declaration order, Runtime §2.3).
- **`using` aliases** — path aliases are resolved against names known at
  module scope and annotated (Core §2.8); they are compile-time bindings,
  not module members.
- **bundle origin** — whether the module came from the implementation's
  embedded standard-library bundle (`bundle_origin`; the only
  distinguishing mark — caller-supplied standard-library extensions and
  user modules share `ModuleKind.standard_library`/`.source`). Origin,
  not spelling, decides classification: a *bodyless declaration of a
  bundle-origin module* is an **intrinsic** — expanded into ordinary AIR
  during source-to-AIR lowering, never dispatched as a host binding
  (Intrinsics Specification §2).
- **host bindings** — *non-bundle* members that have a *declaration and no
  Stilla definition*: host-provided module members (Core §2.6, Runtime
  §3.1), caller-supplied standard-library extensions, and user-module
  bodyless declarations. These are flagged so phase 3 can lower calls to
  them as system calls ([Phase 3 — System calls for host bindings](phase3-cfg-lowering.md#system-calls-for-host-bindings)); a
  same-spelled declaration outside the bundle never acquires intrinsic
  identity (source spoofing).

### Module-level checks

- every `import(...)` appears only as a module-level `const` initializer,
  and its argument is a string literal (Core §2.2, §2.4);
- module-valued const initializers are `import(...)` or a statically known
  module binding (Core §2.3) — a module value may not flow into local
  bindings, parameters, returns, or aggregates;
- member names of the generated module struct are unique (module members
  are struct members, Core §2.1); `using` aliases may shadow without
  becoming members (Core §2.8);
- `import` cycles are rejected (see below).

## Recursive expansion

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

## Import-cycle detection and topological sort

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

### Cycle diagnostics

The three-color DFS in `topo_sort.reversePostorder` returns the cycle
as `[a, b, c, a]` (import order, both ends the same module) by walking
the gray DFS stack from the back-edge target to the stack top and closing
the loop; `moduleinfo.cycleDiag` renders it as "import cycle detected:
a imports b imports c imports a" at the importing expression's span.

> Note: import cycles are distinct from two other cycle forms that are
> handled elsewhere: module-constant *initialization order* within a module
> — an initializer may not transitively read a module constant declared
> later, while function references are order-independent
> (Core §5, §6.5 — checked in phase 2, see [Phase 2 — Checks enabled by annotation](phase2-checker.md#checks-enabled-by-annotation))
> — and recursive *types*, which are legal only through indirection
> (Core §18 — handled by type resolution).

## Data structures

```zig
/// How a written specifier resolved (Runtime §2.6).
const ModuleKind = enum { source, standard_library, host };

/// One loaded module with its phase-1 annotation.
pub const ModuleInfo = struct {
    /// Resolved specifier; the graph key (Runtime §2.1).
    specifier: module.Specifier,
    kind: ModuleKind,
    /// True only for the implementation's embedded `std/` bundle
    /// (Intrinsics Specification §2): the origin mark that classifies
    /// bodyless declarations as intrinsics. Caller-supplied
    /// standard-library extensions and user modules never carry it.
    bundle_origin: bool,
    /// The parsed module, when source or standard library.
    source: ?*const ast.Source,
    program: ?*const ast.Program,

    /// The compiler-generated nominal struct type (Core §2.1): its
    /// members are the module's runtime value members. There is no
    /// `typeinfo` module — resolved types are the AIR-native `cfg.Type`
    /// (see [Phase 2 — Data structures](phase2-checker.md#data-structures)).
    struct_type: *cfg.Type,

    /// Dependency edges in declaration order (Runtime §2.3).
    imports: []*ModuleInfo,
    /// Topological rank: dependencies have strictly lower rank.
    order: u32,

    // Member tables (all arena-owned).
    types: MemberTable,      // struct_def / union_def / type_def, with generic params
    values: MemberTable,     // const_def and monomorphic func_def signatures —
                             // the source of the AIR member table (air.md §7)
    templates: MemberTable,  // generic func_def / struct_def / union_def / alias
    using_aliases: MemberTable, // resolved path aliases (Core §2.8)

    /// Bodyless declarations *outside* the embedded bundle — host-provided
    /// module members, caller-supplied standard-library extensions, and
    /// user-module declarations. Bundle-origin bodyless declarations are
    /// intrinsics, expanded during lowering, and never appear here
    /// (Intrinsics Specification §2). Phase 3 lowers calls to these as
    /// system calls (phase 3 — System calls for host bindings).
    host_bindings: []HostBinding,
};

pub const HostBinding = struct {
    span: ast.Span,
    name: ast.Ident,
    /// The declaration's resolved monomorphic signature.
    signature: *cfg.Type,
    /// Index of the binding in its module's member table (a `MemberId`,
    /// air.md §7); stable, so the runtime can dispatch syscalls by
    /// (module, member).
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

## Phase-1 invariant

After phase 1, all modules for this program have module-level information
computed. Cross-module member lookup — `calc.add`, `geometry.Point`,
`std.math.sqrt` (Core §2.5, §2.7) — is fully decidable from the graph
alone.

## Implementation files

| File | Role |
| --- | --- |
| `src/frontend.zig` | Pipeline driver |
| `src/moduleinfo.zig` | `ModuleInfo`, `ModuleGraph`, resolver, cycle detection, topo sort |
| `src/passes/type_resolve.zig` | Type resolution against module member tables |
| `src/passes/topo_sort.zig` | Three-color DFS cycle detection and reverse postorder |
| `src/stdbundle.zig` | Standard-library bundle registration |
| `std/bundle.zig` | Embedded standard-library sources |

## Downstream consumers

Phase 1 output is consumed by:

- **[Phase 2](phase2-checker.md)** — iterates modules in topological
  order, resolving cross-module names against the module graph;
- **[Phase 3](phase3-cfg-lowering.md)** — reads `ModuleInfo` for member
  tables, host bindings, and the generated struct type;
- **The runtime** — instantiates modules in topological order, each at
  most once (Runtime §2.1, §2.3), using the init order recorded by
  phase 3 ([Module init functions](phase3-cfg-lowering.md#module-init-functions)).
