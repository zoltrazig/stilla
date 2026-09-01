# Architecture Overview

End-to-end map of the repository: the two build artifacts, the compile
pipeline, the runtime, and the host-embedding surface. The per-area
documents hold the detail — this page shows the boundaries and how the
pieces fit together.

## Artifacts

`build.zig` produces two artifacts from the same sources:

| Artifact | Entry | Role |
| --- | --- | --- |
| `zig-out/lib/libstilla.a` | `root.zig` | the embeddable static library — the whole compiler + interpreter behind the public Zig API |
| `zig-out/bin/stilla` | `main.zig` | the CLI: compile to AIR / LLIR assembly / LLIR binary, or compile-and-run (`--run`); builds optimized AIR by default |

`root.zig` re-exports the top-level modules as the library surface:
`frontend`, `moduleinfo`, `checker`, `lower`, `cfg`, `llir`, `interpreter`,
`artifact_bundle`, `host_bind`, `host`, `lex`, `parser`, `stdbundle`,
`frontend_cache`, `vm_instr`, `vm_types`. The CLI is a thin host of the
same API.

## The pipeline at a glance

```text
Stilla source (*.st)  +  host interfaces  +  embedded std/ bundle
    │
    ▼
phase 1  module graph — moduleinfo.Builder.build (module_load → module_scan
         → topo_sort → module_materialize → module_check)        [passes.md §Phase 1]
    ▼
phase 2  checker — annotate every module, then validate every module
         (checker_annotate / checker_validate / checker_ownership,
          monomorphize)                                            [passes.md §Phase 2]
    ▼
phase 3  CFG lowering — lower.lowerProgram → cfg.IrProgram
         (cfg_lower_program / _module / _func / _expr / _control /
          _call / _pattern / _path / _emit)                        [passes.md §Phase 3]
    ▼
Pass 6.1  AIR validator (cfg_validate, air.md §12) on every lowered program
    ▼
Passes 7–8  mid-level optimizer — cfg_optimize.optimizeOnce:
         tailCall → inline → cse → copyProp → pre → ifConvert →
         deadBlock → dropElide → deadInstr → jumpThread → phiSimplify
         (aggressive: bounded fixpoint, optimizer.md §8.10)
    ▼
drop lowering — cfg_lower_drop expands statically-expandable drops
    ▼
LLIR backend — cfg_lower_llir.Builder.lowerLlir (stage table in frontend.md §4)
         → llir_validate → llir_asm / llir_emit_bin / artifact_bundle
    ▼
per-module LLIR artifacts  →  interpreter (loader + dispatch)  →  result
```

`frontend.compile` (frontend.zig) is the one-call driver of the whole
compile side: phase 1 → 2 → 3 → validation → optional optimization
(single pass or bounded fixpoint) → drop lowering → re-validation and
the canonical text round-trip. Everything the compile allocates lives in
one arena that outlives the call; diagnostics follow first-error-wins
unless the phase collects (lexer/parser/checker collect per-module).

## Boundaries

| Component | Files | Owns | Does not own |
| --- | --- | --- | --- |
| Lexer / parser / AST | `lex.zig`, `parser.zig`, `ast.zig`, `parse/` (grammar sub-parsers) | text → tokens → `ast.Program`; recovery + diagnostics | module resolution, types |
| Module graph | `moduleinfo.zig` + `passes/module_load.zig`, `module_scan.zig`, `topo_sort.zig`, `module_materialize.zig`, `module_check.zig` | module identity, specifier resolution, dedup, cycles, topo order, member tables, host-binding classification | function bodies |
| Checker | `passes/checker.zig` + `checker_annotate.zig`, `checker_validate.zig`, `checker_ownership.zig`, `monomorphize.zig`, `type_infer.zig`, `type_resolve.zig`, `type_shape.zig` | name/type/ownership annotation; generic expansion; all static checks | control flow |
| CFG AIR | `cfg.zig` (op schema, types, `IrProgram`) + `passes/cfg_lex.zig`, `cfg_parse.zig`, `cfg_print.zig` | the mid-level IR, its text form, and the ops themselves | semantics — the validator enforces them |
| CFG lowering | `lower.zig` + `passes/cfg_lower_*.zig` | annotated AST → CFG AIR: evaluation order, destruction placement, module init functions, syscalls for host bindings | optimization (runs later) |
| Optimizer | `passes/cfg_optimize.zig` + `cfg_tail_call`, `cfg_inline`, `cfg_cse`, `cfg_copy_prop`, `cfg_pre`, `cfg_select`, `cfg_dead_block`, `cfg_drop_elide`, `cfg_dead_instr`, `cfg_jump_thread`, `cfg_phi_simplify`, `cfg_lower_drop` | semantics-preserving CFG→CFG rewrites; drop expansion | the LLIR image |
| LLIR backend | `passes/cfg_lower_llir*.zig`, `llir_alloc.zig`, `llir_linearize.zig`, `llir_fusion.zig`, `llir_validate.zig`, `llir_asm.zig`, `llir_emit_bin.zig` | validated CFG → frozen per-module `LlirProgram` images; assembly + binary serialization | execution |
| Artifact bundle | `artifact_bundle.zig` | one scoped artifact per module, shared metadata seeded from the root | the VM's runtime state |
| Interpreter | `interpreter.zig` (entry), `interpreter_host.zig` (run/host hooks), `interpreter_loader.zig` (`ModuleLoader`, image loading, hot reload), `interpreter_dispatch.zig`, `interpreter_types.zig`, `vm_types.zig`, `vm_instr.zig` | executes validated LLIR images in place; module instantiation in dependency order; deterministic destruction; panics as owned messages | host semantics |
| Host bindings | `host_bind.zig` (typed registry), `interpreter_host.zig` (dispatch), `host.zig` (stdlib implementations), `host_array.zig`, `host_hashmap.zig` | the comptime typed registry, signature verification, host dispatch | — |

## The host-embedding surface

A Zig/C host links `libstilla.a` and drives two entry points:
`frontend.compile` (source → `cfg.IrProgram`) and the interpreter
(`interpreter.runWithHostAndLoader` / `interpreter.buildProgram` +
`runProgram`, the two-stage embed path). Host modules are plain Zig
structs — `host_bind.register` derives a sorted, signature-checked
member table from the `pub fn`s, and `host_bind.interfaceOf` derives the
`.st` interface text the frontend checks call sites against, so the
interface and implementation cannot drift
([host-bindings.md](host-bindings.md)). The `builtin` module's output
hooks (notably `builtin.print`) have no runtime default; the embedder
supplies them.

## Where the documents live

- **Compiler**: [frontend.md](frontend.md) (pipeline contract end to end), [passes.md](passes.md) (canonical pass order), [phase1-module-graph.md](phase1-module-graph.md), [phase2-checker.md](phase2-checker.md), [phase3-cfg-lowering.md](phase3-cfg-lowering.md), [optimizer.md](optimizer.md), [llir-typed.md](llir-typed.md).
- **Runtime & embedding**: [interpreter-vm.md](interpreter-vm.md), [host-bindings.md](host-bindings.md).
- **Language**: [stilla-intro.md](stilla-intro.md).
- **Normative specs**: `spec/` (see [spec/README.md](../spec/README.md)); the AIR op inventory and validator contract are authoritative in [../spec/air.md](../spec/air.md).
