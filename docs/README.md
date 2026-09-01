# Implementation documentation

The implementation documents describe the compiler and runtime as built.
The language itself is specified normatively in [`spec/`](../spec/);
these documents describe the pipeline that enforces and consumes those
specifications (the spec suite index is [spec/README.md](../spec/README.md)).

## Orientation

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | end-to-end map: artifacts, pipeline, boundaries, host embedding |
| [passes.md](passes.md) | canonical ordered inventory of every pass, with links to the detail documents |
| [stilla-intro.md](stilla-intro.md) | the language and its design, for new readers |

## Compiler pipeline

| Document | Covers |
| --- | --- |
| [frontend.md](frontend.md) | the pipeline contract end to end: phases 1–3, optimizer, the LLIR backend stages |
| [phase1-module-graph.md](phase1-module-graph.md) | Phase 1: module identity, resolution, loading, cycle detection, topo sort |
| [phase2-checker.md](phase2-checker.md) | Phase 2: inference, generic expansion, ownership analysis, checks |
| [phase3-cfg-lowering.md](phase3-cfg-lowering.md) | Phase 3: annotated AST → CFG AIR, destruction placement, module init functions, syscalls |
| [optimizer.md](optimizer.md) | Passes 7–8: tail-call elimination, inlining, CSE, copy propagation, and the mid-level rewrites |
| [llir-typed.md](llir-typed.md) | the typed LLIR lowering layer (value-form lattice, typed-assembly surface) |

## Runtime and embedding

| Document | Covers |
| --- | --- |
| [interpreter-vm.md](interpreter-vm.md) | the LLIR interpreter VM: image, execution loop, ownership, loading, public API |
| [host-bindings.md](host-bindings.md) | the typed host-binding layer: comptime registry, signature checks, embedding |

## Reading order

New to the repository: [stilla-intro.md](stilla-intro.md) → [architecture.md](architecture.md) → [passes.md](passes.md), then follow the phase documents from the compiler row. Working on one area: start at [architecture.md](architecture.md) for the boundary, [passes.md](passes.md) for the pass order, and the matching detail document for depth.

## Keeping this consistent

The pass order and file inventory live in [passes.md](passes.md); the
phase and optimizer documents link to it rather than restating the
sequence. When a pass is added, renamed, or reordered, update
[passes.md](passes.md) first, then the detail document.
