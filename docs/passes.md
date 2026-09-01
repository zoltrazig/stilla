# Passes — canonical pipeline inventory

This is the authoritative **order** of every pass in the compiler and
backend. It exists because the pass sequence used to be described
piecemeal across the phase documents; those documents now hold the
detail and link here for the ordering. If the code and this document
disagree, the code wins — fix this document.

Each pass is one file under `src/passes/` (driver entries re-exported
through the owning top-level module). "Validator" entries run the
`cfg_validate` AIR validator (air.md §12) after the listed rewrite.

## Phase 1 — module graph (moduleinfo.zig)

Driver: `moduleinfo.Builder.build(entry)`. Sequence:

| # | Pass | File | Job |
| --- | --- | --- | --- |
| 1.1 | load | `module_load.zig` | resolve a written specifier (source / stdlib / host, Runtime §2.6), lex + parse (cache-aware, frontend_cache.zig), register the `RawModule`, hand it to scan |
| 1.2 | scan | `module_scan.zig` | pre-scan module-level consts for `import(...)` initializers and module-value aliases; seed `raw.module_values` transitively |
| 1.3 | expand | `moduleinfo.zig` (`Builder.build`) | worklist over import edges: load the transitive closure, each module at most once |
| 1.4 | topo sort | `topo_sort.zig` | three-color DFS: reject import cycles, emit reverse-postorder (dependencies before dependents) |
| 1.5 | materialize | `module_materialize.zig` | per-module member tables (values, types, using aliases, host bindings, import edges), in topo order so cross-module lookups resolve |
| 1.6 | module checks | `module_check.zig` | duplicate member names, module-level checks |
| 1.7 | assemble | `moduleinfo.zig` (`Builder.build`) | `ModuleGraph` (infos in order, `by_specifier`, entry), pre-populate the nominal-type interner (air.md §11) |

Detail: [phase1-module-graph.md](phase1-module-graph.md).

## Phase 2 — checker (checker.zig)

Driver: `checker.Checker.check(graph)`. Sequence:

| # | Pass | File | Job |
| --- | --- | --- | --- |
| 2.1 | host-binding collection | `checker.zig` | gather every bodyless declaration outside the embedded bundle (intrinsics stay out, Intrinsics Spec §2) |
| 2.2 | annotate | `checker_annotate.zig` | per-module name resolution, expression/pattern inference, binding-state tracking — all modules, topo order |
| 2.3 | validate | `checker_validate.zig` | the consumer checks (type mismatch, match exhaustiveness, ownership transfer, …) — only when annotation produced no errors |
| — | ownership merging | `checker_ownership.zig` | conditional-release state merging through `if`/`match`/`and`/`or` (Types & Ownership §10.10) |
| — | generic expansion | `monomorphize.zig` + `type_infer.zig` | deep-copy monomorphization of template bodies under concrete substitutions |
| — | type resolution | `type_resolve.zig` + `type_shape.zig` | syntactic `ast.Type` → `cfg.Type`; structural ownership classification |

Detail: [phase2-checker.md](phase2-checker.md).

## Phase 3 — CFG lowering (lower.zig)

Driver: `lower.lowerProgram` (cfg_lower_program.zig). Sequence:

| # | Pass | File | Job |
| --- | --- | --- | --- |
| 3.1 | program | `cfg_lower_program.zig` | per-module `IrModule` set-up, type-environment collection |
| 3.2 | module | `cfg_lower_module.zig` | member table, module init functions, host-binding registry |
| 3.3 | function | `cfg_lower_func.zig` | per-`IrFunc` bodies, generic instances lower as their own `IrFunc` |
| 3.4 | expression | `cfg_lower_expr.zig` (with `cfg_lower_control.zig`, `cfg_lower_call.zig`, `cfg_lower_pattern.zig`, `cfg_lower_path.zig`) | AST → CFG ops; on-the-fly constant folding, arithmetic simplification, block-local CSE, and copy folding at each emit site (`cfg_lower_emit.zig`) |
| 3.5 | validate | `cfg_lower_validate.zig` / `cfg_validate.zig` | air.md §12 validator on every lowered program (Pass 6.1) |

Detail: [phase3-cfg-lowering.md](phase3-cfg-lowering.md).

## Mid-level optimizer (Passes 7–8, cfg_optimize.zig)

Driver: `cfg_optimize.optimizeOnce` — a single ordered pass, no fixpoint
by default; `optimizeAggressive` loops it to a bounded fixpoint (cap
`aggressive_max_iters = 4`, inliner skipped after iteration 1). Every
rewrite is validated against air.md §12 before the next runs.

| # | Pass | File | Job |
| --- | --- | --- | --- |
| 7 | tail call | `cfg_tail_call.zig` | frame-reusing jumps for direct calls in tail position (Copy-only loop-carried state) |
| 8.0 | inlining | `cfg_inline.zig` | splice selected **non-recursive** direct calls into the caller; one-shot (never re-run in aggressive mode) |
| 8.1 | CSE | `cfg_cse.zig` | reuse an identical `module_ref` / `load_member` earlier in the same block (Copy results only) |
| 8.2 | copy propagation | `cfg_copy_prop.zig` | replace `copy` of a Copy value by the value itself; collapse copy chains |
| 8.3 | PRE | `cfg_pre.zig` | partial redundancy elimination over pure, non-trapping ops at joins |
| 8.4 | if-conversion | `cfg_select.zig` | select diamonds → branchless `select` (scalar Copy types only) |
| 8.5 | dead-block elim. | `cfg_dead_block.zig` | remove blocks unreachable from the entry |
| 8.6 | drop elision | `cfg_drop_elide.zig` | remove provably unobservable drops of Copy values |
| 8.7 | dead-instr elim. | `cfg_dead_instr.zig` | remove side-effect-free, non-consuming, non-trapping ops with no uses |
| 8.8 | jump threading | `cfg_jump_thread.zig` | merge empty forwarding blocks into their successor |
| 8.9 | phi simplification | `cfg_phi_simplify.zig` | remove single-incoming / identical / trivial phis |
| — | print-order renumber | `cfg_inline.zig` (`renumberPrintOrder`) | restore valid SSA print order after cross-block substitution |
| — | aggressive fixpoint | `cfg_optimize.zig` (`optimizeAggressive`) | loop the sequence to a bounded fixpoint (cap `aggressive_max_iters = 4`, inliner skipped after iteration 1) |

Detail: [optimizer.md](optimizer.md).

## Drop lowering (post-optimization)

| # | Pass | File | Job |
| --- | --- | --- | --- |
| 9 | drop lowering | `cfg_lower_drop.zig` | expand every statically-expandable `drop` (struct hook + reverse field drops, tuple, box, union) into explicit CFG ops; only opaque host types, `hostdata`, `list[T]`, and `any` drops stay single instructions |

Runs in the frontend's optimize path after Pass 8, re-validated before
the AIR text round-trip (air.md §6.4, §14). Wired in
[frontend.md](frontend.md) §4 / [optimizer.md](optimizer.md) (Drop lowering).

## LLIR backend (cfg_lower_llir.zig)

Driver: `lower.LlirBuilder.lowerLlir`. The CFG → LLIR projection runs
the named stages (prepare → allocate → result coalesce → lifecycle
plan → edge blocks → budget → intern → body emit → edge emit → control
emit → LLIR rewrites → linearize); the input CFG is never mutated. The
stage table and invariants live in [frontend.md](frontend.md) §4. After
`lowerLlir` the frozen `LlirProgram` image is consumed by:

| # | Pass | File | Job |
| --- | --- | --- | --- |
| B.1 | validate | `llir_validate.zig` | structural validation of the image (LLIR Spec §8) — the loader boundary |
| B.2 | assemble | `llir_asm.zig` | deterministic symbolic assembly text (`--emit-asm`) |
| B.3 | binary | `llir_emit_bin.zig` | flat little-endian serialization + the reader (`--emit-bin <file>`; `readBin`) |
| B.4 | artifact bundle | `artifact_bundle.zig` | one scoped `LlirProgram` per module, shared metadata seeded from the root build |

Detail: [frontend.md](frontend.md) §4, [llir-typed.md](llir-typed.md).

## Orchestration (frontend.zig)

`frontend.compile` wires the whole chain in one call — phase 1
(`moduleinfo`) → phase 2 (`checker`) → phase 3 (`lower`) → Pass 6.1
validation → `Options.optimize` (Passes 7–8, then drop lowering, then
re-validation plus the text round-trip) — and owns the diagnostics and
the arena that outlives every stage. The CLI (`main.zig`) adds the LLIR
emission modes on top; the embeddable path goes through
`artifact_bundle.ArtifactBundle` and the interpreter entry points
([architecture.md](architecture.md)).

## Relationship to the phase documents

- [phase1-module-graph.md](phase1-module-graph.md) — module identity, resolution, loading, cycle detection.
- [phase2-checker.md](phase2-checker.md) — inference, generics, ownership, checks.
- [phase3-cfg-lowering.md](phase3-cfg-lowering.md) — the AIR model and lowering rules.
- [optimizer.md](optimizer.md) — the Pass 7–8 rewrites and validator.
- [frontend.md](frontend.md) — the pipeline contract end to end, plus the LLIR stage table.
