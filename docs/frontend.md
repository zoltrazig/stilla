# Stilla Frontend Architecture

> Status: **v1.0 implemented** — the compile-time frontend that turns
> parsed source into a CFG-based intermediate representation ready for
> the runtime. Normative language rules are cited from the Core and
> Runtime specifications in [`spec/`](spec/) (tracking the v1.3 drafts);
> this document describes the *implementation pipeline* that enforces
> and consumes them.
>
> The pipeline is complete: Passes 1–8 are **implemented**, the ir.md
> §13 validator runs on every lowered program and around every optimizer
> rewrite, and the full suite (`zig build test`) passes. The IR op
> inventory and data structures are authoritative in
> [`spec/ir.md`](spec/ir.md) §4–§11 and `src/cfg.zig`, not in this
> document.

## 1. Pipeline overview

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
IR (CFG)  →  optimizer  →  runtime (module instantiation, function execution, destruction)
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

## 3. Phase documentation

Each phase has its own detailed document:

- **[Phase 1 — Module Graph Construction](phase1-module-graph.md)**
  Module identity and specifier resolution, loading/parsing/deduplication,
  module-level information computed per module, recursive expansion,
  import-cycle detection and topological sort, data structures.

- **[Phase 2 — Checker: Inference, Generics, Ownership](phase2-checker.md)**
  Cross-module name resolution, type resolution, expression inference and
  annotation tables, generic expansion (monomorphization), ownership
  analysis, checks enabled by annotation (type mismatch, match
  exhaustiveness, ownership transfer, conditional release), data
  structures.

- **[Phase 3 — CFG Lowering](phase3-cfg-lowering.md)**
  IR model (IrModule/IrFunc/BasicBlock/Value), lowering rules for all
  expression and statement forms, destruction placement (scope-end, user
  drop hooks, hostdata, opaque host types, temporaries, conditional),
  module init functions,
  system calls for host bindings, integration with phase 2, outputs.

- **[Optimizer — Tail Call and Mid-Level Rewrites](optimizer.md)**
  IR validator (Pass 6.1), tail call optimization (Pass 7), mid-level
  optimizer driver (Pass 8) with partial redundancy elimination,
  dead-instruction/block elimination, drop elision, phi simplification,
  jump threading; on-the-fly constant folding, arithmetic simplification,
  CSE, and copy propagation at construction; optimization harness.

## 4. Implementation passes and status

The pipeline is implemented in **passes**. Passes 1–8 are complete.

- [x] **Pass 1 — Lexer, parser, AST** (`src/lex.zig`, `src/parser.zig`,
      `src/ast.zig`).
- [x] **Pass 2 — Phase 1: module graph** (`src/module.zig`,
      `src/moduleinfo.zig`, `src/passes/topo_sort.zig`,
      `src/passes/type_resolve.zig`, `src/stdbundle.zig`, `std/bundle.zig`,
      `src/frontend.zig`, `src/main.zig`).
- [x] **Pass 3 — Phase 2: annotation and checks** (the checker,
      `src/passes/checker.zig` + `checker_annotate.zig` +
      `checker_validate.zig` + `checker_ownership.zig` +
      `src/passes/monomorphize.zig`).
- [x] **Pass 4 — Phase 3: CFG lowering** (`src/cfg.zig`,
      `src/passes/cfg_lex.zig`, `src/passes/cfg_parse.zig`,
      `src/passes/cfg_print.zig`, `src/lower.zig` +
      `src/passes/cfg_lower_*.zig`).
- [x] **Pass 5 — Phase-3 × phase-2 integration** — the lowerer consumes
      the annotation for concrete signatures, instantiated types, and
      ownership decisions.
- [x] **Pass 6 — Validation and documentation** — ir.md §13 validator
      (`src/passes/cfg_validate.zig`), cycle diagnostics, docs sync.
- [x] **Pass 7 — Tail call optimization** (`src/passes/cfg_tail_call.zig`).
- [x] **Pass 8 — Mid-level optimizer** (`src/passes/cfg_optimize.zig` plus
      `cfg_pre`, `cfg_dead_instr`, `cfg_dead_block`, `cfg_drop_elide`,
      `cfg_jump_thread`, `cfg_phi_simplify`).
- [x] **Drop lowering (post-optimization)** — expand every
      statically-expandable `drop` in the CFG (`src/passes/cfg_lower_drop.zig`):
      structs (hook call + `unpack_struct` + reverse field drops), tuples,
      boxes (`builtin#unbox` + contained drop), and unions (`read_tag` +
      `switch`); only opaque, `hostdata`, `list`, and `any` drops reach the
      runtime. Runs after Pass 8, before the final IR round-trip.

## 5. Relationship to existing code

| Phase | Where it lives (all implemented) |
| --- | --- |
| lex / parse | `src/lex.zig`, `src/parser.zig` (+ grammars under `src/parse/`); tokens → `ast.Program` per file |
| 1 — module graph | `src/module.zig` (specifier registry), `src/frontend.zig` (pipeline driver), `src/moduleinfo.zig` (`ModuleInfo`, `ModuleGraph`, resolver, cycle detection, topo sort), `src/passes/type_resolve.zig`, `src/stdbundle.zig` + `std/bundle.zig` (embedded stdlib) |
| 2 — annotation | `src/passes/checker.zig` (phase-2 driver), `checker_annotate.zig` (name resolution, inference, binding states), `checker_validate.zig` (the checks), `checker_ownership.zig` (conditional-release state merging, Core §10.10), `src/passes/monomorphize.zig` (generic expansion) — resolved types are `cfg.Type` |
| 3 — CFG IR | `src/cfg.zig` (op schema `opInfo`, types, `IrProgram`), `src/passes/cfg_lex.zig` + `cfg_parse.zig` + `cfg_print.zig` (IR text form, re-exported by `cfg`), `src/lower.zig` + `src/passes/cfg_lower_*.zig` (annotated AST → CFG, destruction placement, module init functions), `src/builtin.zig` (syscall dispatch vtable) |
| optimizer + validator | `src/passes/cfg_optimize.zig` (+ `cfg_tail_call`, `cfg_pre`, `cfg_dead_instr`, `cfg_dead_block`, `cfg_drop_elide`, `cfg_jump_thread`, `cfg_phi_simplify`) and `src/passes/cfg_validate.zig` (ir.md §13 validator); on-the-fly constant folding, arithmetic simplification, CSE, and copy propagation in `cfg_lower_emit.zig` |
| drop lowering | `src/passes/cfg_lower_drop.zig` — post-optimization expansion of statically-expandable `drop`s (struct/tuple/box/union) into explicit CFG operations; only opaque, `hostdata`, `list`, and `any` drops remain single instructions. Wired into `frontend.zig`'s optimize path after Pass 8, re-validated before the IR text round-trip |

## 6. Non-goals and open questions

- **No general optimizer** — phase 3 emits direct, semantically faithful
  CFG; optimization runs as a later consumer. The mid-level optimizer
  (Passes 7–8) is a fixed, small sequence of semantics-preserving
  CFG→CFG rewrites — not a general, cost-model-driven optimizer; register
  allocation and instruction scheduling are out of scope.
- **Resolution is implementation-defined** (Core §2.4) — this document
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
