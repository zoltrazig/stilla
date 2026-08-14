# AGENTS.md

Zig implementation of the **Stilla v1.3 runtime** plus a frontend compiler
(Stilla source → CFG IR text). Requires **Zig 0.16.0** (`build.zig.zon`).

## Commands

- `zig build` — build + install `zig-out/lib/libstilla.a` and `zig-out/bin/stilla`
- `zig build test` — run all tests (always prefer this; see test slices below)
- `zig fmt src/` — format all sources; run `zig fmt --check src/` before finishing (CI-gating check; some files were historically not fmt-clean, so run the real `fmt`, not just `--check`)
- `zig build run -- examples/fib.st` — compile a Stilla file to CFG IR text
- `zig-out/bin/stilla app.st --output app.ir` — same, without rebuilding
- CLI: `--output <file>`, `--module <spec>` (default: input file stem), `--entry-fn <name>` (default `main`), `--no-entry-fn`, `-I <dir>` (import search path → loads `<dir>/<spec>.st`)
- `zig test src/ast_tests.zig`, `zig test src/lex_tests.zig`, `zig test src/parser_tests.zig` run standalone (they only pull in `src/` modules). The other `*_tests.zig` files must use `zig build test`: they import `stdbundle.zig`/`moduleinfo.zig`/`frontend.zig`, whose `stilla_std_sources` anonymous import is only wired up in `build.zig` (CLI `--dep` cannot attach it).

## Tests

- `test {}` blocks inside a module file are **white-box** tests and must only exercise that module's own internals.
- **Black-box** tests go in separate `src/*_tests.zig` files, one per module or pipeline area, wired in by the `test` block in `src/root.zig`:
  - `ast_tests.zig`, `lex_tests.zig`, `parser_tests.zig` — the front-end AST, lexer, and parser (mirroring the Zig compiler's `pre_module_ast` slice)
  - `checker_tests.zig` — the type checker / AST annotator
  - `module_tests.zig`, `context_tests.zig`, `host_tests.zig`, `builtin_tests.zig`, `panic_tests.zig` — the module-registry, execution-context, and host-contract modules (mirroring `post_module_ast`)
  - `stdbundle_tests.zig` — the embedded standard-library bundle
  - `moduleinfo_tests.zig` — the module-graph passes (Phase 1)
  - `frontend_tests.zig` — the CFG IR text form and the frontend lowering pipeline (mirroring `pre_optimize_cfg`)
- Do not put black-box / cross-module tests inside a module's `test` block; add them to the matching `*_tests.zig` file instead.

## Architecture

- Two artifacts from `build.zig`: a static library whose public API root is `src/root.zig`, and the `stilla` compiler executable (`src/main.zig`).
- Frontend pipeline: Phase 1 module graph (`src/moduleinfo.zig`) → Phase 2 type check (`src/passes/checker.zig` — the phase-2 driver, with `checker_annotate.zig` and `checker_validate.zig`: name resolution, expression/pattern inference, binding-state tracking (owned/borrowed/consumed/released), core diagnostics, generic expansion via `monomorphize.zig`, and the §4.6 consumer checks) → Phase 3 CFG lowering (`src/lower.zig`, `src/cfg.zig`) — which also runs the **on-the-fly optimizations** of braun13cc.pdf §3.1 (constant folding, arithmetic simplification, common subexpression elimination, and copy propagation happen at each `emit` site in `cfg_lower_emit.zig`; frontend.md §4.3) → **mid-level optimizer** (`src/passes/cfg_optimize.zig`, Pass 8 driver): tail call optimization (`cfg_tail_call.zig`), module/member CSE (`cfg_cse.zig`), copy propagation (`cfg_copy_prop.zig`), partial redundancy elimination (`cfg_pre.zig`), dead-block elimination (`cfg_dead_block.zig`), drop elision (`cfg_drop_elide.zig`), dead-instruction elimination (`cfg_dead_instr.zig`), jump threading (`cfg_jump_thread.zig`), and phi simplification (`cfg_phi_simplify.zig`) all run today as a single ordered pass (no fixpoint; frontend.md §6), with the **IR validator** (`cfg_validate.zig`, ir.md §13 — structure, SSA dominance, schema-driven arity/typing, and an edge-sensitive ownership dataflow over `cfg.opInfo`) run by the frontend on every lowered program and by the optimizer before the sequence and after every rewrite.
- **One file per pass.** Every compile pass lives in its own file: parser grammars under `src/parse/` (`type`, `pattern`, `stmt`, `expr`), all other passes under `src/passes/`. The pass catalog: module graph — `module_load`, `module_scan`, `topo_sort` (cycle detection + topo sort), `module_materialize`, `module_check`; type resolution — `type_resolve`, `type_shape`, `type_infer` (re-exported by `moduleinfo`); phase-2 annotator — `checker` (driver), `checker_annotate`, `checker_validate`, `checker_ownership` (conditional release / state merging), `monomorphize` (generic expansion); CFG lowering — `cfg_lower_program`, `cfg_lower_module`, `cfg_lower_func`, `cfg_lower_expr`, `cfg_lower_control`, `cfg_lower_call`, `cfg_lower_pattern`, `cfg_lower_path`, `cfg_lower_emit`, `cfg_lower_validate`; CFG optimization — `cfg_optimize` (Pass 8 driver), `cfg_cse`, `cfg_copy_prop`, `cfg_pre`, `cfg_dead_block`, `cfg_tail_call`, `cfg_drop_elide`, `cfg_dead_instr`, `cfg_jump_thread`, `cfg_phi_simplify`, plus the IR validator `cfg_validate` (all re-exported by `lower`); on-the-fly optimization lives inside `cfg_lower_emit` (frontend.md §4.3); IR text form — `cfg_lex`, `cfg_parse`, `cfg_print` (re-exported by `cfg`). The passes import each other directly, sharing the `Lowerer`/`Parser` contexts plus `cfg`-level helpers (`cfg.finalizeBlocks`, `cfg.renumberValues`). The drivers `moduleinfo.Builder`, `lower.Lowerer`, and `parser.Parser` are data homes + thin orchestrators; each pass file starts with a `//! Pass: … In: … Out: …` doc comment and is a free function over the driver's context. Pipeline design lives in `frontend.md`; the CFG IR text form and data structures live in `ir.md`.
- The standard library is embedded at compile time: each `std/*.st` source is `@embedFile`d in `std/bundle.zig` (exported as the anonymous `stilla_std_sources` module) and registered as a specifier→source row in `src/stdbundle.zig`. **A new `std/*.st` module must be added in both files.** `std/` sits outside the `src/` package root, so `@embedFile` from `src/` cannot reach it.
- `spec/` holds the normative specs; where the Core and Runtime specs disagree, the Runtime spec governs execution.
