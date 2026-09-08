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
| type resolution | `type_resolve.zig` + `type_shape.zig` | syntactic `ast.Type` → `cfg.Type`; structural ownership classification |

Detail: [checker.md](checker.md).

## HIR seam — planned, M1a (not implemented)

> Status: **design target with S1 data structures landed.** No HIR
> compiler stage is wired — the S1 data structures exist in `hir.zig`, but
> the checker's output still feeds the CFG lowering directly (next
> section), and this section documents the target order of
> [hir.md](hir.md) §11 M1a. When the seam lands, the CFG lowering
> consumes HIR instead of the annotated AST; the proposed files below are
> marked (planned) until then.

Target order: checker → AST→HIR construction → structural validation →
HIR→CFG lowering (into today's block/value/drop machinery).

| Pass | File (planned) | Job (planned) |
| --- | --- | --- |
| build | `hir_build.zig` (data structures in `hir.zig`) | annotated AST + module graph → canonical monomorphic HIR: binder / region / pattern normalization, full-expression fences, ownership view carried over from the checker; effect analysis disabled (M1a) |
| validate | `hir_validate.zig` | structural HIR invariants only: scope, no capture, tree shape (no DAG), no duplicate BinderId, full-expression fence (hir.md §10.1) |
| lower | `hir_lower.zig` | HIR → CFG AIR, reusing the existing `lower.zig` / `cfg_lower_emit.zig` block, value, and drop mechanisms; replaces today's direct AST → CFG expression lowering |

A planned canonical text form (`hir_print.zig` / `hir_parse.zig`,
re-exported through `hir.zig`) mirrors `cfg_print` / `cfg_parse` for
round-trip tests; black-box equivalence tests live in the planned
`hir_tests.zig` (hir.md §10.2–§10.3).

Detail: [hir.md](hir.md) (M1a; design document).

## CFG lowering (lower.zig)

Driver: `lower.lowerProgram` (cfg_lower_program.zig). Sequence:

| Pass | File | Job |
| --- | --- | --- |
| program | `cfg_lower_program.zig` | per-module `IrModule` set-up, type-environment collection |
| module | `cfg_lower_module.zig` | member table, module init functions, host-binding registry |
| function | `cfg_lower_func.zig` | per-`IrFunc` bodies, generic instances lower as their own `IrFunc` |
| expression | `cfg_lower_expr.zig` (with `cfg_lower_control.zig`, `cfg_lower_call.zig`, `cfg_lower_pattern.zig`, `cfg_lower_path.zig`) | AST → CFG ops; on-the-fly constant folding, arithmetic simplification, block-local CSE, and copy folding at each emit site (`cfg_lower_emit.zig`) |
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
(`moduleinfo`) → checker (`checker`) → CFG lowering (`lower`) →
validation → `Options.optimize` (the optimizer, then drop lowering,
then re-validation plus the text round-trip) — and owns the diagnostics
and the arena that outlives every stage. The CLI (`main.zig`) adds the
LLIR emission modes on top; the embeddable path goes through
`artifact_bundle.ArtifactBundle` and the interpreter entry points
([architecture.md](architecture.md)).

## Detail documents

- [module-graph.md](module-graph.md) — module identity, resolution, loading, cycle detection.
- [checker.md](checker.md) — inference, generics, ownership, checks.
- [cfg-lowering.md](cfg-lowering.md) — the AIR model and lowering rules.
- [optimizer.md](optimizer.md) — the optimizer rewrites and validator.
- [frontend.md](frontend.md) — the pipeline contract end to end, plus the LLIR stage table.
