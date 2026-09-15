# Compiler probes

Small Stilla programs that isolate CFG AIR and LLIR shapes. Each `.st` file
must compile independently with the current compiler; probes are inputs for IR
regression tests and manual inspection, not user-facing examples.

The detailed probes cover the source-reachable operation/type matrix:

- `numeric.st`: register arithmetic and unary negation for all six numeric types
- `integer_bits.st`: shifts and bitwise operations for all four integer types
- `immediates.st`: integer immediate arithmetic, shifts, masks, and comparisons
- `comparisons.st`: value and branch comparisons for numeric, byte, bool, and str
- `casts.st`: all 20 non-identity casts among byte, int32, uint32, float32, and float64
- `fusion.st`: multiply-add fusion for every numeric representation and integer
  immediate forms that are reachable from source
- `aggregates.st`, `union_match.st`, and `list_match.st`: construction and projection
- `patterns.st`: literal, exact-list, rest-list, shorthand struct, and multi-payload
  union patterns
- `any.st`: copy/move packing, type tests, and copy/move recovery
- `calls.st`, `tail_recursion.st`, and `ownership.st`: calls, argument modes, returns,
  tail calls, retain/release, move, borrow, and drop
- `lifecycle.st`: automatic aggregate and temporary destruction plus conditional moves
- `generic.st` and `generic_aggregates.st`: inferred and explicit function specialization,
  first-class specialization, and generic structs, unions, and aliases
- `box.st`: Copy and Unique box construction and extraction through `builtin` intrinsics
- `branch.st`, `short_circuit.st`, and `control_flow.st`: joins, short-circuit branches,
  void conditionals, and `never` branches
- `strings.st`: string concatenation and comparison
- `constants.st`: scalar constants, including 64-bit values that exercise move-wide
  materialization
- `nested_control.st`: chained and nested `if`/`else if` joins, boolean nesting, and
  value-producing conditionals (phi simplification, if-conversion candidates)
- `redundancy.st`: the same pure computation in several arms and after a join
  (CSE, copy propagation, partial redundancy elimination)
- `unused.st`: computations and field projections whose results are never consumed
  (dead-instruction elimination, dead-let)
- `mutual_recursion.st`: a mutual recursion cycle, a non-tail self call, and a self
  tail call (inlining, the tail-call pass cycle guard)
- `nested_aggregates.st`: nested struct / tuple / union values destroyed as a whole
  (recursive drop-lowering expansion)
- `select.st`: scalar if-expressions of every if-convertible type plus a unique
  aggregate that must stay branchy (if-conversion's scalar-Copy-only rule)
- `seg.st`: every source-reachable SEG rewrite family (known-variant `match`
  reduction, immediately-invoked-lambda β reduction, constant folding and
  integer algebra, constant conditions, and the cross-full-expression `let`
  folds of [hir.md](hir.md) §8.7 — a source-level `let` is not an island
  (its initializer opens its own FE), so its dead / used-once / atom-copy
  rules are admitted by their boundary contracts: `unused_let` / `forward_once`
  / `atom_twice` fold, while a borrowed-view atom, a may-trap initializer, a
  printing call, an implicit `any` coercion and a Unique constructor result
  keep their `let`)
- `consumers.st`: the M2b effect-driven consumers (dead-let of a discardable
  scalar call and of a discardable Unique constructor, selective ANF hoisting
  of a Unique call result and of a dominant effectful operand, with destructor
  placement pinned by a printing drop hook)
- `indirect_targets.st`: the §9.2 indirect-call target narrowing (a `let`-bound
  fn-ref, a `let`-bound λ, and an `if`-selected finite set) next to the
  unresolvable function-parameter callee that stays `Top`
- `effectful_beta.st`: β with effectful arguments ([effects.md](effects.md)
  §10.4) — a two-argument call evaluates both printing arguments left-to-right,
  and an unused / once-used parameter keeps its `let` so β neither drops nor
  moves the effect
- `eta.st`: η-reduction ([hir.md](hir.md) §8.5) — λ wrappers over a named
  function and over another λ wrapper (the chain resolves to the member in one
  call), next to the refused shapes: a trapping callee, a call-result callee,
  and a swapped argument order
- `struct_projection.st`: struct projection ([hir.md](hir.md) §8.3) —
  `field_get(struct_make(…), i) → vi` for every declared field index, the
  projected operand as a non-constant expression, and the refused shapes: a
  non-constructor (`let`-bound) base and a constructor written out of
  declaration order (its temp `let` chain opens a full-expression boundary)
- `tuple_list_encoding.st`: the `tuple_make` / `list_make` island encoding
  ([hir.md](hir.md) §8.3) — landing the `construct` encoding puts both
  aggregates in the CSE candidate set, so two α-equal duplicable elements
  inside a tuple or list literal share one synthesized `let`, next to the
  non-α-equal pair that stays split. The tuple / list *projection* rules are
  IR-level only: Stilla has no element-read suffix, so elements are read by
  destructuring patterns, never `field_get`
- `cse.st`: CSE-style sharing ([hir.md](hir.md) §8.3) — two α-equivalent
  `isDuplicable` operands of one island node materialize into a synthesized
  `let` (identical `mul`s, identical field reads, and a shared non-trivial
  pure subtree), next to the refusal: a Unique `Token` constructor pair is
  consumed by its aggregate, so neither is an island member / duplicable
- `egraph.st`: the slotted e-graph arena itself ([hir.md](hir.md) §8.2) — the
  union rules are an e-class table plus union-find, so they share what the
  *rules* made equal, not just what the source wrote twice:
  `(a * b) + ((a * b) * 1)` merges the two products once `x * 1 → x` has run
  and materializes one evaluation, `((a*b)*c) + (((a*b)+0)*c)` reaches one
  class through two levels, a struct projection unions the read's class with
  a rule-rewritten operand (so the AIR keeps nothing where the constructor
  and the read were), and a trivial-atom class inside a `let`-body island is
  duplicated to both operands — the emitted binder reads stay copies of the
  island-external `let` binder. The refusal sits here too: a may-trap
  initializer is no island member, so its α-equal products never merge
- `never_suffix.st`: the `never_returns` must fact's suffix deletion
  ([effects.md](effects.md) §10.1) — a structurally-never callee
  (`builtin.panic` behind a `void` signature) deletes the statements after
  it, its `let`-initializer case deletes the rest of the block, and the
  suffix after a normal-returning callee survives (`main` traps, so the
  probe is registered in `probe_corpus.panics`)
- `scope_end_cleanup.st`: the scope-end destruction model
  ([effects.md](effects.md) §11.2) — a source-level Unique `let` whose
  binding is only borrowed (its printing destructor fires at the enclosing
  block end), an owned Unique `move` parameter destroyed at normal exit,
  and a discarded Unique statement whose destructor stays at the statement
  when selective ANF materializes it into a synthesized `let`

Every `probes/*.st` file is enumerated at test time by
`src/probe_corpus.zig`, so a new probe automatically joins the HIR build
corpus (`hir_tests.zig`), the canonical-AIR seam round-trip, the M2b
consumers and `--simplify` × `--seg` four-combination differentials
(`hir_simplify_tests.zig`, `hir_seg_tests.zig`), the SEG corpus budget
(`hir_seg_tests.zig`), and the per-pass smoke suite
(`frontend_pass_smoke_tests.zig`) — no hardcoded list to update.

## Pass smoke coverage

`src/frontend_pass_smoke_tests.zig` drives every probe through every
transform/optimization pass family:

- CFG lowering plus the canonical-AIR text round-trip;
- each Pass 7-8 rewrite applied **individually** to a fresh compilation,
then validated and round-tripped (so a pass that only misbehaves alone
is caught even though the ordered driver would mask it);
- the full optimized pipeline (optimizer, then post-optimization drop
lowering, then re-validation);
- the LLIR backend: `lowerLlir`, structural image validation, symbolic
assembly, and the flat binary read/write round-trip.
A pass runs over a freshly compiled program rather than one parsed from
canonical AIR text: the text form deliberately carries no type
declarations, so the validator cannot run on a parsed aggregate program.

## Black-box test fixtures (`probes/cases/`)

Whole-program fixtures that a black-box test needs but that are *not*
part of the smoke corpus live under `probes/cases/`. They are read by
spec through `frontend_test_support.probeSource` / `probe_corpus.read`,
not enumerated: a fixture may declare host bindings, trap, or intentionally
fail to be useful to one test, and the dynamically enumerated corpus
would run it through every differential. Add a fixture here instead of
inlining a whole Stilla program in a test body.

Some LLIR instructions have no one-to-one source construct. `spill_take`,
`spill_put`, `result_take`, argument-window instructions, `jal`/`jalr`/`jr`,
`auipc`, `lui`, long-branch inversions, and replacement/release variants are
selected by register allocation, calling convention, relaxation, or ownership
normalization. `msub` is currently present in the LLIR ISA but is not selected
by the source-to-LLIR fusion pass. The control-flow and call probes exercise
some backend selectors, but exact opcode coverage belongs in the synthetic LLIR
tests because allocator and optimizer choices may change without changing
source semantics.

Compile one probe to CFG AIR:

```sh
zig build run -- probes/branch.st
```

Use `--emit-asm` or `--emit-bin <path>` to exercise the later IR stages. The
CLI enables optimization by default, including immediate and fusion selection.
