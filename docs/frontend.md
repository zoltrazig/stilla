# Stilla Frontend Architecture

> Status: **v1.0 implemented** — the compile-time frontend that turns
> parsed source into a CFG-based intermediate representation ready for
> the runtime. Normative language rules are cited from the Core and
> Runtime specifications in [`spec/`](spec/) (tracking the v1.3 drafts);
> this document describes the *implementation pipeline* that enforces
> and consumes them.
>
> The pipeline is complete: Passes 1–8 are **implemented**, the air.md
> §12 validator runs on every lowered program and around every optimizer
> rewrite, and the full suite (`zig build test`) passes. The AIR op
> inventory and data structures are authoritative in
> [`spec/air.md`](spec/air.md) §4–§11 and `src/cfg.zig`, not in this
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
    │  PHASE 3  CFG-based AIR generation
    │          (per-function basic blocks; host bindings → system calls;
    │           embedded-bundle intrinsics expand into ordinary AIR)
    ▼
AIR (CFG)  →  optimizer  →  runtime (module instantiation, function execution, destruction)
```

The three phases are strictly ordered because each one establishes an
invariant the next one relies on:

| Phase | Output | Invariant established |
| --- | --- | --- |
| 1 | `ModuleGraph` of `ModuleInfo` nodes | every module in the program has its module-level info computed; cross-module name/type lookup is decidable |
| 2 | annotated `ast.Program` per module | every expression, binding, and type use is annotated (name, type, ownership, expression); the program is fully monomorphic and statically correct |
| 3 | CFG-based `IrModule` / `IrFunc` | control flow and value flow are explicit; every host binding call is a system call; every intrinsic use is ordinary AIR |

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
- `IrModule` (phase 3): per-module init function and per-function CFG AIR,
  with host binding calls lowered to `SysCall` instructions and
  embedded-bundle intrinsics expanded into ordinary AIR (materialized
  constants or calls to existing host bindings; canonical AIR carries no
  intrinsic identity — air.md §5.6, Intrinsics Specification §3–§5).

**Diagnostics** are reported as `ast.Diagnostic` (`span` + message). The
lexer, parser, and checker collect every diagnostic they can in one run
(lexical recovery skips to the next token boundary; parser panic-mode
recovery resynchronizes at statement/module-item boundaries; the checker
continues per module item), with hard phase ordering — a phase whose
predecessor produced errors does not run. `frontend.Compilation` exposes
the collected list (`diags`, in source order) and a first-diagnostic
accessor; `main.zig` renders all of them, capped at 32.

**Incremental compilation (optional)** — `Options.cache` accepts an
optional `FrontendCache` (src/frontend_cache.zig): repeated `compile`
calls reuse each unchanged module's parsed `ast.Program`/`ast.Source`
from the cache's arena (keyed by resolved specifier, validated by the
content hash + byte comparison), so an unchanged program's second
compile performs zero lex/parse work. The cached artifact is the parse
only — phase-1 member tables and the phase-2/3 side tables are
re-derived each compile, keeping `TypeId`s consistent with the fresh
per-compile interner and making stale-dependency reuse impossible.
See phase1-module-graph.md, Loading, parsing, and deduplication.

**Aggressive optimization (optional)** — `Options.optimize_aggressive`
(code-only, like `optimize`) runs the Pass 7–8 sequence to a bounded
fixpoint instead of once: iteration 1 is the full sequence; each later
iteration repeats the same fixed order with the one-shot inliner
skipped (re-running it on spliced recursive callees would grow the CFG
without bound), until a full iteration changes nothing or the cap
`cfg_optimize.aggressive_max_iters` is reached, with the §6.1 validator
guarding every rewrite inside each iteration. The default (`false`)
keeps the single ordered pass and its near-linear compile time; `true`
is for embedders who want more aggressive simplification and accept the
bounded extra cost (optimizer.md, §8.9).

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
  AIR model (IrModule/IrFunc/BasicBlock/Value), lowering rules for all
  expression and statement forms, destruction placement (scope-end, user
  drop hooks, hostdata, opaque host types, temporaries, conditional),
  module init functions,
  system calls for host bindings, integration with phase 2, outputs.

- **[Optimizer — Tail Call and Mid-Level Rewrites](optimizer.md)**
  AIR validator (Pass 6.1), tail call optimization (Pass 7), mid-level
  optimizer driver (Pass 8) with partial redundancy elimination,
  if-conversion (the branchless `select`), dead-instruction/block elimination,
  drop elision, phi simplification,
  jump threading; on-the-fly constant folding, arithmetic simplification,
  CSE, and copy propagation at construction; optimization harness.

## 4. Implementation passes and status

The pipeline is implemented in **passes**. Passes 1–8 are complete.

- [x] **Pass 1 — Lexer, parser, AST** (`src/lex.zig`, `src/parser.zig`,
      `src/ast.zig`).
- [x] **Pass 2 — Phase 1: module graph** (`src/moduleinfo.zig`, `src/passes/topo_sort.zig`,
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
- [x] **Pass 6 — Validation and documentation** — air.md §12 validator
      (`src/passes/cfg_validate.zig`), cycle diagnostics, docs sync.
- [x] **Pass 7 — Tail call optimization** (`src/passes/cfg_tail_call.zig`).
- [x] **Pass 8 — Mid-level optimizer** (`src/passes/cfg_optimize.zig` plus
      `cfg_pre`, `cfg_select`, `cfg_dead_instr`, `cfg_dead_block`, `cfg_drop_elide`,
      `cfg_jump_thread`, `cfg_phi_simplify`).
- [x] **Drop lowering (post-optimization)** — expand every
      statically-expandable `drop` in the CFG (`src/passes/cfg_lower_drop.zig`):
      structs (hook call + `unpack_struct` + reverse field drops), tuples,
      boxes (`builtin#unbox` + contained drop), and unions (`read_tag` +
      `switch`); only opaque, `hostdata`, `list`, and `any` drops reach the
      runtime. Runs after Pass 8, before the final AIR round-trip.

### Backend: CFG → LLIR

Below the AIR pipeline the compiler lowers further to the executable
artifacts. The backend is a read-only projection of the validated,
optimized, drop-lowered CFG ([Stilla LLIR
Specification](../spec/Stilla%20LLIR%20Specification.md) §1): it never
mutates the input, and no stage computes or stores an absolute PC —
branch/jump/direct-call records are emitted with placeholder offsets
whose targets are derived from the input CFG during linearization,
while `switch_arms` rows hold their targets' symbolic `BlockId`s until
the same stage replaces them with final relative offsets.

**Per-module emission.** The backend emits one LLIR artifact per module of
the input program: each artifact carries only its own module's functions,
instructions, slots, and export table, plus the compilation's canonical
shared metadata (types, declarations, signatures, constants — identical
rows in every artifact of one compilation, so `TypeId`/`SignatureId`
identity is stable across the set). Cross-module references — calls,
function values, module references, member and host accesses — are
lowered to symbolic imports: `(module_symbol, member_symbol)` pairs the
runtime resolves through the target module's export table. An imported
call lowers to `module_ref` (loading and initializing the target module)
plus `load_member` (the function's VM pc) plus the indirect-call `jalr`
path; a module-internal call stays the direct `jal ra`.

The driver is `Builder.lowerLlir` in
[`src/passes/cfg_lower_llir.zig`](../src/passes/cfg_lower_llir.zig).
It runs eleven named stages in this fixed order; each has one named
input/output invariant:

| Stage | Where | Invariant (in → out) |
| --- | --- | --- |
| prepare | `cfg_lower_llir_prepare.run` | read-only input CFG → every function/block holds a dense `FunctionId`/`BlockId`; ordered function/block tables, the module/function name maps (`module_ids`, `func_name_ids`), and zeroed `FunctionDesc` rows; ID order fixed from here on |
| allocate | `llir_alloc.allocateSlots` | fixed IDs → `value_slots` map plus final frame-layout numbers; every value a record will reference has a physical slot |
| result coalesce | `llir_result_coalesce.run` | final layout numbers → eligible non-void direct-call results remapped onto the result alias `F(L+3+O-A)` (Step 8), so the emitter drops the post-call `take`; indirect (`jalr`) results and results live across another call keep their take |
| lifecycle plan | `cfg_lower_lifecycle.plan` | fixed slots → per-instruction trailing release placement, the per-edge kill plan (`edgeKills`), and tailcall leftover kills; each counted owner releases exactly once along every path; a value read only by its terminator (a `switch` discriminant) is deferred to the edge kills rather than released before the read |
| edge blocks | `cfg_lower_llir_edges.planBlocks` | lifecycle plan → expanded `ordered_blocks`/`block_ranges` with one LLIR-only edge block per distinct effect-bearing outgoing edge (phi copies or kills), `j` and `br`/`switch` arms alike; the input CFG is untouched |
| budget | `cfg_lower_llir_budget.run` | decided record content → conservative decision-free block starts/lengths and pre-sized block-local record lists that emission fills exactly |
| intern | `cfg_lower_llir_intern.run` | descriptors records reference → deduplicated side-table rows; nested dependencies are interned before a flat `{ start, len }` range is recorded |
| body emit | `cfg_lower_llir_emit.run` | budgets + slots → one record per non-phi instruction at its block-local index; any target-bearing record carries a placeholder, never a PC |
| edge emit | `cfg_lower_llir_edges.run` | planned per-edge copy lists → phi copies then lifecycle kills as ordinary records in each LLIR-only edge block, which ends in a `j` to the successor, so only the selected edge's effects run; ordinary blocks emit no inline edge effects; swap cycles staged through one scratch slot (the same `edgeCopyList` the allocator replays and the budget counts) |
| control emit | `cfg_lower_llir_control.run` | reserved terminator position → terminator records with unresolved targets: placeholder offsets in the record, actual block derived from the CFG terminators (`switch_arms` rows keep symbolic `BlockId`s) |
| LLIR rewrites | `llir_fusion.peephole`, `llir_compact_noop_ownership.compactNoopOwnership`, `llir_fuse_lifecycle.fuseLifecycle`, `llir_expand_spills.expandSpills` | fully written record lists → block-locally compacted/spilled lists only (safe because no PC exists yet) |
| linearize | `llir_linearize.run`, then `Builder.finish` | final per-block lists → global instruction array, function/block code ranges, and the written relative offsets for branches, jumps, direct calls, and switch arms, producing the frozen `LlirProgram` |

While the passes behind these stages are extracted into their own pass
files, the public surface stays frozen: `cfg_lower_llir.Builder`, its
existing inspection fields, and the methods `prepare`, `lowerLlir`,
`slotOf`, `edgeCopyList`, `terminatorRecordCount`, `recordCount`,
`callArgMoves`, `callArgMoveCount`, `calleeParamList`, `nextBlockOf`,
`fusedBranchOperands`, `fusedBranchReads`, and `invertBranch` remain
available (delegating to the extracted body-emission, edge-planning,
budgeting, and control passes);
side-table row ordering, descriptor deduplication, and emitted images do
not change (the existing LLIR suites verify both without caller
rewrites).

#### The typed lowering boundary (forward-compatible)

The arithmetic / comparison / cast choices that today land directly as
opcode records are modeled on a typed layer ([`llir-typed.md`](llir-typed.md),
`src/passes/cfg_lower_typed.zig`): a value carries its `cfg.Type` plus a
**value-form** (the top-bits state of its 64-bit canonical cell), and a
logical op (`add.i32`, `div.u32`, `cvt.i32.f32`) stays one typed SSA node
instead of a pre-expanded record sequence. The value-form lattice is the
single source of truth for the widening elimination the expander runs as
a residual step during expansion. The arithmetic emitter now routes
each op through this typed layer: `emitArith` builds a `TypedOp` and
the §4 expander (`emitBinArith`, B.1) writes the record sequence, and
`cfg_lower_llir_budget.arithSeqCount` derives its count from
`typed.arithSeqLen` rather than a hard-coded constant. The emitted image
matches the spec's canonical sequences minus the intentionally elided
staging records (the leading `zext32` of an already-zero-extended
operand, and a fused constant's `zext32`/`andi`). The lattice is verified
against known producers in
`src/frontend_llir_typed_tests.zig` and the module's own test block; the
typed-assembly printer (`printTyped`) renders what Layer A sees.

## 5. Relationship to existing code

| Phase | Where it lives (all implemented) |
| --- | --- |
| lex / parse | `src/lex.zig`, `src/parser.zig` (+ grammars under `src/parse/`); tokens → `ast.Program` per file |
| 1 — module graph | `src/frontend.zig` (pipeline driver), `src/moduleinfo.zig` (`ModuleInfo`, `ModuleGraph`, resolver, cycle detection, topo sort), `src/passes/type_resolve.zig`, `src/stdbundle.zig` + `std/bundle.zig` (embedded stdlib) |
| 2 — annotation | `src/passes/checker.zig` (phase-2 driver), `checker_annotate.zig` (name resolution, inference, binding states), `checker_validate.zig` (the checks), `checker_ownership.zig` (conditional-release state merging, Types & Ownership §10.10), `src/passes/monomorphize.zig` (generic expansion) — resolved types are `cfg.Type` |
| 3 — CFG AIR | `src/cfg.zig` (op schema `opInfo`, types, `IrProgram`), `src/passes/cfg_lex.zig` + `cfg_parse.zig` + `cfg_print.zig` (AIR text form, re-exported by `cfg`), `src/lower.zig` + `src/passes/cfg_lower_*.zig` (annotated AST → CFG, destruction placement, module init functions), `src/host.zig` (host-call handlers; dispatch is `src/interpreter_host.zig`) |
| optimizer + validator | `src/passes/cfg_optimize.zig` (+ `cfg_tail_call`, `cfg_pre`, `cfg_select`, `cfg_dead_instr`, `cfg_dead_block`, `cfg_drop_elide`, `cfg_jump_thread`, `cfg_phi_simplify`) and `src/passes/cfg_validate.zig` (air.md §12 validator); on-the-fly constant folding, arithmetic simplification, CSE, and copy propagation in `cfg_lower_emit.zig` |
| drop lowering | `src/passes/cfg_lower_drop.zig` — post-optimization expansion of statically-expandable `drop`s (struct/tuple/box/union) into explicit CFG operations; only opaque, `hostdata`, `list`, and `any` drops remain single instructions. Wired into `frontend.zig`'s optimize path after Pass 8, re-validated before the AIR text round-trip |

## 6. Non-goals and open questions

- **No general optimizer** — phase 3 emits direct, semantically faithful
  CFG; optimization runs as a later consumer. The mid-level optimizer
  (Passes 7–8) is a fixed, small sequence of semantics-preserving
  CFG→CFG rewrites — not a general, cost-model-driven optimizer; register
  allocation and instruction scheduling are out of scope.
- **Resolution is implementation-defined** (Core §2.4) — this document
  fixes the pipeline shape, not the resolver's file/registry policy.
- **Borrow lifetimes** — phase 2 checks the v1.3 lexical rules (Types & Ownership §10.7,
  Static Semantics §18) but does not infer regions; borrow info is carried into the AIR as
  `borrow` ops for the runtime.
- **Module-value runtime model** — `module_ref` values are static; the
  runtime's exact storage representation of module values is open
  (`src/interpreter_loader.zig`). The loader also owns the hot-reload
  entry point `reloadModule` (docs/interpreter-vm.md §11): it re-fetches
  and atomically repoints one loaded module under a quiesce contract
  (refused while the VM executes) with rollback on failure.
- **Host interface discovery** — the mechanism by which a host module's
  statically known interface is described (registry schema) is host-side
  policy; only the frontend's consumption of it is specified here.
