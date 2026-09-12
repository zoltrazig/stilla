# Passes — canonical pipeline inventory

This is the authoritative **order** of every pass in the compiler and
backend. It exists because the pass sequence used to be described
piecemeal across the pipeline detail documents; those documents now hold
the detail and link here for the ordering. If the code and this document
disagree, the code wins — fix this document.

Each pass is one file under `src/passes/` (driver entries re-exported
through the owning top-level module). "Validator" entries run the
`cfg_validate` AIR validator (air.md) after the listed rewrite.

## Module graph (moduleinfo.zig)

Driver: `moduleinfo.Builder.build(entry)`. Sequence:

| Pass | File | Job |
| --- | --- | --- |
| load | `module_load.zig` | resolve a written specifier (source / stdlib / host, Runtime), lex + parse (cache-aware, frontend_cache.zig), register the `RawModule`, hand it to scan |
| scan | `module_scan.zig` | pre-scan module-level consts for `import(...)` initializers and module-value aliases; seed `raw.module_values` transitively |
| expand | `moduleinfo.zig` (`Builder.build`) | worklist over import edges: load the transitive closure, each module at most once |
| topo sort | `topo_sort.zig` | three-color DFS: reject import cycles, emit reverse-postorder (dependencies before dependents) |
| materialize | `module_materialize.zig` | per-module member tables (values, types, using aliases, host bindings, import edges), in topo order so cross-module lookups resolve |
| module checks | `module_check.zig` | duplicate member names, module-level checks |
| assemble | `moduleinfo.zig` (`Builder.build`) | `ModuleGraph` (infos in order, `by_specifier`, entry), pre-populate the nominal-type interner (air.md) |

Detail: [module-graph.md](module-graph.md).

## Checker (checker.zig)

Driver: `checker.Checker.check(graph)`. Sequence:

| Pass | File | Job |
| --- | --- | --- |
| host-binding collection | `checker.zig` | gather every bodyless declaration outside the embedded bundle (intrinsics stay out, Intrinsics Spec) |
| annotate | `checker_annotate.zig` | per-module name resolution, expression/pattern inference, binding-state tracking — all modules, topo order |
| validate | `checker_validate.zig` | the consumer checks (type mismatch, match exhaustiveness, ownership transfer, …) — only when annotation produced no errors |
| ownership merging | `checker_ownership.zig` | conditional-release state merging through `if`/`match`/`and`/`or` (Types & Ownership) |
| generic expansion | `monomorphize.zig` + `type_infer.zig` | deep-copy monomorphization of template bodies under concrete substitutions |
| type resolution | `type_resolve.zig` + `type_shape.zig` | syntactic `ast.Type` → `meta.Type`; structural ownership classification |

Detail: [checker.md](checker.md).

## HIR seam — implemented (hir.md §11)

> Status: **implemented.** The checker's annotated output is built into the
> canonical monomorphic HIR and lowered from there to CFG AIR; this is the
> only frontend lowering path (the direct annotated-AST lowering and the
> `hir_stage` toggle were removed). Files: `hir_build.zig`
> (+ `hir_build_block` / `hir_build_expr` / `hir_build_path` / `hir_build_call` /
> `hir_build_control` / `hir_build_pattern`), `hir_validate.zig`,
> `hir_effects.zig` (with the model in top-level `effects.zig`),
> `hir_simplify.zig`, `hir_seg.zig`, `hir_lower.zig`. The effect
> infrastructure is live: every reachable node carries a `ready` interned
> `EffectSummary` after analysis, and the effect validator runs in the
> compile pipeline, including the function-summary SCC least fixpoint, the
> precise `drop_effect` chain, the summary-driven module-const
> init/teardown check, and the opt-in dead-let / selective-ANF consumers
> and SEG pass.

Order: checker → AST→HIR construction → structural validation →
effect analysis + annotation validation → module-const dependency check →
*[optional]* effect consumers (`hir_simplify.zig`) → *[optional]* SEG
(`hir_seg.zig`) → HIR→CFG lowering (into today's block/value/drop
machinery). Each optional transform re-runs structural validation and a
fresh effect analysis before lowering (hir.md §2.4).

| Pass | File | Job |
| --- | --- | --- |
| build | `hir_build.zig` + `hir_build_block` / `_expr` / `_path` / `_call` / `_control` / `_pattern` / `_cleanup` (data structures in `hir.zig`) | annotated AST + module graph → canonical monomorphic HIR: binder / region / pattern normalization, full-expression fences, ownership view carried over from the checker; `SemanticInfo.effect` starts `pending`; the `_cleanup` step registers full-expression `CleanupToken`s (docs/effects.md §11.2) |
| validate | `hir_validate.zig` | structural HIR invariants only: scope, no capture, tree shape (no DAG), no duplicate BinderId, full-expression fence (hir.md §10.1 first level) |
| effects | `hir_effects.zig` (model: `effects.zig`) | `effect_transfer` per descriptor (`own_effect` + `TransferKind`); function summaries by the SCC least fixpoint (recursive SCC seeded `Diverge`, `drop` hooks in the call graph; indirect/missing/unknown → `Top`); precise `drop_effect(T)` (struct hook + Unique fields reverse-order, union/tuple/list/box, opaque release); `OperandUse` resolution; full-expression cleanup footprint (`cleanupEffect`) plus the literal cleanup-free proof; derived legality queries; the summary-driven module-const init/teardown check (`checkModuleDependencies`); publishes interned `ready` summaries and validates them against a fresh derivation (`derived ≤ stored`) |
| consumers | `hir_simplify.zig` | dead-let (`B ∉ FV(body)` ∧ `isDiscardable(init)`) and selective A-Normal Form (first `!canFloatAsTree` operand of a `StrictLTR` parent hoisted to a `let`, Copy only); legality is the derived query alone — no `switch(op)`; opt-in (`--simplify`) |
| seg | `hir_seg.zig` | β→let / let simplification / constant folding / integer algebra / known-variant `match`→let over recursively-admitted `isSegSafe` islands; opt-in (`--seg`) |
| lower | `hir_lower.zig` | HIR → CFG AIR, reusing the existing `lower.zig` / `cfg_lower_emit.zig` block, value, and drop mechanisms; replaced the direct AST → CFG expression lowering |

The canonical text form (`hir_print.zig` / `hir_parse.zig`, re-exported
through `hir.zig`) mirrors `cfg_print` / `cfg_parse` for round-trip
tests; the black-box regression suite lives in `hir_tests.zig`
(hir.md §10.2–§10.3) — a pure-HIR corpus regression (compile → canonical
AIR → standalone cfg parser round-trip), with corpus-wide effect
annotation + validation and the module-const dependency cases. The effect
model's own algebra/law tests live in `effects.zig`, the transfer/query
tests in `hir_effects.zig`; the consumer passes have their own white-box
tests plus `hir_simplify_tests.zig` and `hir_seg_tests.zig` black-box
suites.

Detail: [hir.md](hir.md) (implemented),
[effects.md](effects.md) (§5 lattice + §10–§11 queries + §12 consumers
implemented; §13 host ABI wiring proposed).

## CFG lowering (lower.zig)

Driver: `hir_lower.lowerProgram` (hir_lower.zig), which drives the
module/function/expression lowering over the retained `cfg_lower_*`
mechanism functions; those files no longer consume `ast.Expr` directly.
Sequence:

| Pass | File | Job |
| --- | --- | --- |
| type environment | `cfg_lower_program.zig` | type-environment collection consumed during program materialization |
| module | `cfg_lower_module.zig` | module constant slots |
| function | `cfg_lower_func.zig` | per-`IrFunc` lowering state (`newFuncState`) and return coercion (`coerceRet`) |
| expression | `cfg_lower_expr.zig` (with `cfg_lower_control.zig`, `cfg_lower_call.zig`, `cfg_lower_pattern.zig`, `cfg_lower_path.zig`) | the retained HIR→CFG emission helpers: const/void/discard (`cfg_lower_expr`), joins and phi unification (`cfg_lower_control`), call/syscall/host-call emission (`cfg_lower_call`), pattern type tests (`cfg_lower_pattern`), module references (`cfg_lower_path`) — along with on-the-fly constant folding, arithmetic simplification, block-local CSE, and copy folding at each emit site (`cfg_lower_emit.zig`) |
| validate | `cfg_lower_validate.zig` / `cfg_validate.zig` | the air.md validator on every lowered program |

Detail: [cfg-lowering.md](cfg-lowering.md).

## Mid-level optimizer (cfg_optimize.zig)

Driver: `cfg_optimize.optimizeOnce` — a single ordered pass, no fixpoint
by default; `optimizeAggressive` loops it to a bounded fixpoint (cap
`aggressive_max_iters = 4`, inliner skipped after iteration 1). Every
rewrite is validated against air.md before the next runs.

| Pass | File | Job |
| --- | --- | --- |
| tail call | `cfg_tail_call.zig` | frame-reusing jumps for direct calls in tail position (Copy-only loop-carried state) |
| inlining | `cfg_inline.zig` | splice selected **non-recursive** direct calls into the caller; one-shot (never re-run in aggressive mode) |
| CSE | `cfg_cse.zig` | reuse an identical `module_ref` / `load_member` earlier in the same block (Copy results only) |
| copy propagation | `cfg_copy_prop.zig` | replace `copy` of a Copy value by the value itself; collapse copy chains |
| PRE | `cfg_pre.zig` | partial redundancy elimination over pure, non-trapping ops at joins |
| if-conversion | `cfg_select.zig` | select diamonds → branchless `select` (scalar Copy types only) |
| dead-block elim. | `cfg_dead_block.zig` | remove blocks unreachable from the entry |
| drop elision | `cfg_drop_elide.zig` | remove provably unobservable drops of Copy values |
| dead-instr elim. | `cfg_dead_instr.zig` | remove side-effect-free, non-consuming, non-trapping ops with no uses |
| jump threading | `cfg_jump_thread.zig` | merge empty forwarding blocks into their successor |
| phi simplification | `cfg_phi_simplify.zig` | remove single-incoming / identical / trivial phis |
| print-order renumber | `cfg_inline.zig` (`renumberPrintOrder`) | restore valid SSA print order after cross-block substitution |
| aggressive fixpoint | `cfg_optimize.zig` (`optimizeAggressive`) | loop the sequence to a bounded fixpoint (cap `aggressive_max_iters = 4`, inliner skipped after iteration 1) |

Detail: [optimizer.md](optimizer.md).

## Drop lowering (post-optimization)

| Pass | File | Job |
| --- | --- | --- |
| drop lowering | `cfg_lower_drop.zig` | expand every statically-expandable `drop` (struct hook + reverse field drops, tuple, box, union) into explicit CFG ops; only opaque host types, `hostdata`, `list[T]`, and `any` drops stay single instructions |

Runs in the frontend's optimize path after the optimizer, re-validated
before the AIR text round-trip (air.md). Wired in
[frontend.md](frontend.md) / [optimizer.md](optimizer.md) (Drop lowering).

## LLIR backend (cfg_lower_llir.zig)

Driver: `lower.LlirBuilder.lowerLlir`. The CFG → LLIR projection runs
the named stages (prepare → allocate → result coalesce → lifecycle
plan → edge blocks → budget → intern → body emit → edge emit → control
emit → LLIR rewrites → linearize); the input CFG is never mutated. The
stage table and invariants live in [frontend.md](frontend.md). After
`lowerLlir` the frozen `LlirProgram` image is consumed by:

| Pass | File | Job |
| --- | --- | --- |
| validate | `llir_validate.zig` | structural validation of the image (LLIR Spec) — the loader boundary |
| assemble | `llir_asm.zig` | deterministic symbolic assembly text (`--emit-asm`) |
| binary | `llir_emit_bin.zig` | flat little-endian serialization + the reader (`--emit-bin <file>`; `readBin`) |
| artifact bundle | `artifact_bundle.zig` | one scoped `LlirProgram` per module, shared metadata seeded from the root build |

Detail: [frontend.md](frontend.md), [llir-typed.md](llir-typed.md).

## Orchestration (frontend.zig)

`frontend.compile` wires the whole chain in one call — module graph
(`moduleinfo`) → checker (`checker`) → HIR build (`hir_build`) →
structural validation (`hir_validate`) → effect analysis + annotation
validation (`hir_effects`, the HIR seam, [hir.md](hir.md) §11,
[effects.md](effects.md)) → HIR→CFG lowering (`hir_lower`) →
validation → `Options.optimize` (the optimizer, then drop lowering,
then re-validation plus the text round-trip) — and owns the diagnostics
and the arena that outlives every stage. The CLI (`main.zig`) adds the
LLIR emission modes on top; the embeddable path goes through
`artifact_bundle.ArtifactBundle` and the interpreter entry points
([architecture.md](architecture.md)).

## Detail documents

- [module-graph.md](module-graph.md) — module identity, resolution, loading, cycle detection.
- [checker.md](checker.md) — inference, generics, ownership, checks.
- [hir.md](hir.md) — the HIR data structures, text form, and the HIR→CFG contract (implemented).
- [effects.md](effects.md) — the effect-semantics model: lattice, derived queries, and the three consumers implemented.
- [cfg-lowering.md](cfg-lowering.md) — the AIR model and lowering rules.
- [optimizer.md](optimizer.md) — the optimizer rewrites and validator.
- [frontend.md](frontend.md) — the pipeline contract end to end, plus the LLIR stage table.
