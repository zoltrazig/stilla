# Implementation documentation

The implementation documents describe the compiler and runtime as built.
The language itself is specified normatively in [`spec/`](../spec/);
these documents describe the pipeline that enforces and consumes those
specifications (the spec suite index is [spec/README.md](../spec/README.md)).

## Orientation

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | end-to-end map: artifacts, pipeline, boundaries, host embedding |
| [passes.md](passes.md) | ordered inventory of every pass, with links to the detail documents |
| [todo.md](todo.md) | the remaining HIR / effect-model work: prioritized items with scope, dependencies, and acceptance criteria |

## Compiler pipeline

| Document | Covers |
| --- | --- |
| [frontend.md](frontend.md) | the pipeline contract end to end: module graph, checker, the HIR seam, CFG lowering, the optimizer, drop lowering, the LLIR backend stages |
| [module-graph.md](module-graph.md) | module identity, resolution, loading, cycle detection, topo sort |
| [checker.md](checker.md) | inference, generic expansion, ownership analysis, checks |
| [hir.md](hir.md) | the canonical monomorphic HIR seam between the checker and CFG lowering: data structures, text form, structural invariants, HIR→CFG contract, effect annotations and opt-in consumers |
| [effects.md](effects.md) | the effect-semantics model: resource/control summary lattice, `effect_transfer`, function-summary SCC fixpoint, cleanup-aware legality queries, the module-const check (host ABI metadata wiring remains a proposal) |
| [cfg-lowering.md](cfg-lowering.md) | the CFG AIR model and the HIR→CFG emission rules: destruction placement, module init functions, syscalls |
| [optimizer.md](optimizer.md) | tail-call elimination, inlining, CSE, copy propagation, and the mid-level rewrites |
| [llir-typed.md](llir-typed.md) | the typed LLIR lowering layer (typed opcodes, typed-assembly surface) |

## Runtime and embedding

| Document | Covers |
| --- | --- |
| [interpreter-vm.md](interpreter-vm.md) | the LLIR interpreter VM: image, execution loop, ownership, loading, public API |
| [host-bindings.md](host-bindings.md) | the typed host-binding layer: comptime registry, signature checks, embedding |

## Unimplemented proposals

The remaining unimplemented parts of the model are described inside the
documents above rather than in a standalone proposal: the host ABI
metadata wiring (effects.md §13), node-level full-expression boundary
annotation (hir.md §5.6), and indirect-call target narrowing
(effects.md §9.2). [todo.md](todo.md) is the prioritized work list with
dependencies and acceptance criteria. The effect infrastructure —
lattice, transfer, SCC-fixpoint function summaries, precise
`drop_effect`, cleanup gate, derived queries — is implemented, as are
the three consumers (dead-let / selective ANF / SEG-safe) and the
module-const init/teardown check.

## Reading order

New to the repository: [architecture.md](architecture.md) →
[passes.md](passes.md), then follow the pipeline documents from the
compiler row. Working on one area: start at [architecture.md](architecture.md)
for the boundary, [passes.md](passes.md) for the pass order, and the
matching detail document for depth.

## Keeping this consistent

The pass order and file inventory live in [passes.md](passes.md); the
pipeline and optimizer documents link to it rather than restating the
sequence. When a pass is added, renamed, or reordered, update
[passes.md](passes.md) first, then the detail document.
