# Optimizer — Tail Call Optimization and Mid-Level Rewrites

> Status: **implemented** — Passes 7 and 8 in the frontend pipeline.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts).
> The IR op inventory and data structures are authoritative in
> [`spec/ir.md`](spec/ir.md) §4–§11 and `src/cfg.zig`.

## Overview

The optimizer is a fixed sequence of semantics-preserving CFG→CFG
rewrites that runs after [Phase 3](phase3-cfg-lowering.md) lowering
and before the runtime consumes the IR. It is wired into
`frontend.compile` behind `frontend.Options.optimize` (default off;
the `stilla` executable hardcodes it on; code-only toggle, no CLI flag).

The sequence runs as a **single ordered pass — no iteration to
fixpoint** — so compile time stays near-linear. The full ir.md §13
validator (`cfg.validate`) runs before the sequence and after every
rewrite: an optimizer bug that violates structure, SSA, typing, or the
ownership dataflow is a compile-time diagnostic.

Constant folding, arithmetic simplification, common subexpression
elimination, and copy propagation no longer exist as separate
passes — they run on-the-fly at each instruction's construction site
during [Phase 3](phase3-cfg-lowering.md) (§4.3, braun13cc.pdf §3.1).
The remaining Pass 8 sequence is: tail-call optimization, PRE,
dead-block elimination, drop elision, jump threading, and phi
simplification.

## IR validator (Pass 6.1)

`src/passes/cfg_validate.zig` (re-exported as `cfg.validate` /
`lower.validate`) is a schema-driven checker:

- **structure** — blocks, terminators, and instruction sequences;
- **SSA dominance** — every value use is dominated by its definition;
- **arity and typing** — from `cfg.opInfo` (ir.md §13);
- **edge-sensitive ownership dataflow** — `Available` / `Consumed` /
  `MaybeConsumed` over the CFG, per-edge phi inputs, atomic
  `unpack_*` / `split_list` consumption.

The frontend runs it on every lowered program; the optimizer runs it
before the sequence and after every rewrite.

## Pass 7 — Tail call optimization

`src/passes/cfg_tail_call.zig` (re-exported by `lower`) — a CFG→CFG
rewrite of calls in tail position into frame-reusing jumps, so
self-recursion becomes iteration. Runs first in the Pass 8 driver.

### Tail-position detection

A `call` (or `syscall`) whose result is immediately `ret`ed, or a
`void`/`never` call directly followed by `ret`, in a block with no live
unique state afterwards and no armed cleanup token on the tail edge.

### Rewrite

Replace `call` + `ret` with a `br` back to the function's own entry
block, re-binding the callee's parameters from the call arguments and
splicing in phis for the reused frame's SSA values (ir.md §10.9). The
chain drop is guarded:

- an intermediate chain block (between the call block and the ret block)
  must have exactly one predecessor, so it forwards only the call's
  result — an extra predecessor merges another arm's value, which dropping
  the chain edge would strand (multi-arm guarded recursion stays a call);
- the ret block must keep at least one non-chain predecessor, so the
  rewrite cannot orphan the function's only `ret`.

### Ownership preservation

The rewrite must not reorder any `drop` or observable effect: the
returned value's destruction schedule (Runtime §6) is unchanged because
the frame is reused; only direct `call`s to a known `IrFunc` are
candidates (a call through a function *value* has no statically known
target); v0.1 is **Copy-only**: loop-carried parameters are all Copy and
a move-mode parameter never loops back (ir.md §10.9).

## Pass 8 — Mid-level optimizer driver

`src/passes/cfg_optimize.zig` (re-exported by `lower`) — a driver that
runs a fixed sequence of semantics-preserving CFG→CFG rewrites over the
lowered CFG, after Pass 7 and before the runtime consumes it. Each
sub-pass is one file in `src/passes/`; each rewrite must preserve
observable behavior (Runtime §5) and the ir.md §13 invariants.

### On-the-fly optimizations (Phase 3 §4.3)

These run at each instruction's construction site in
`cfg_lower_emit.zig`'s `emit`, replacing what would otherwise be
separate CFG→CFG passes:

- **constant folding** — fold `arithmetic`/`compare`/`logic`/`num_cast`
  ops whose operands are constant at their emit site (`tryFoldOp`,
  braun13cc Algorithm 3's §3.1); `div`/`rem` by zero and out-of-range
  `float32 → int32` must still trap (Runtime §7.1);
- **arithmetic simplification** — integer identities only (`x−x→0`,
  `x+0→x`, `x·1→x`, `x·0→0`, `x/1→x`, `x%1→0`); float identities are
  unsound (`x−x≠0` for NaN, `0·x≠0` for ±inf/NaN, `0+x≠x` for −0.0);
- **common subexpression elimination** — reuse an identical pure
  computation earlier in the same block at its emit site; block-local
  (the first occurrence dominates), Copy results only (ir.md §5.4),
  operands matched positionally (no commutativity); the reused value is
  returned directly, so no `copy` is involved;
- **copy propagation** — a `move` of a Copy value lowers directly to the
  value (a copy of a Copy value is the value, ir.md §5.4), so no
  `copy` instructions reach the IR from the frontend.

### 8.3 Partial redundancy elimination

`src/passes/cfg_pre.zig` — rewrite a computation available on some —
but not all — incoming edges of a join to a phi, inserting the
computation at the end of the edges that lacked it; candidates are pure,
non-trapping ops only (comparisons, `not`, `type_is` — hoisting a
trapping op onto a skipped path would change observable behavior,
Runtime §7.2), Copy results, operands defined in a strict dominator of
the join; the join's computation is replaced by the phi with the same
result value, and values are renumbered in text order (ir.md §13).

### 8.4 Dead-instruction elimination

`src/passes/cfg_dead_instr.zig` — remove an instruction whose results
are unused, Copy, and produced by a side-effect-free, non-consuming,
non-trapping op (the guarded `read_payload` of a match arm whose payload
is unused is the common corpus case); iterated to a fixed point; calls,
syscalls, consuming destructures, `div`/`rem`/`cast`/reads (traps) and
phis are never candidates.

### 8.5 Dead-block elimination

`src/passes/cfg_dead_block.zig` — remove blocks unreachable from the
entry; update phi incoming lists and predecessor sets accordingly
(ir.md §3).

### 8.6 Drop elision

`src/passes/cfg_drop_elide.zig` — remove a `drop` whose destruction is
provably unobservable — the value is Copy, or already dead; must never
remove a user `drop` hook that performs output (ir.md §14) and never
moves a destruction earlier than its prescribed point (ir.md §6.4) — a
type with a user hook is always classified unique, so only Copy drops are
elided, and `drop_cleanup` / `cleanup_disable` (whose token's payload is
an unique owner) are never elided.

### 8.7 Phi simplification

`src/passes/cfg_phi_simplify.zig` — remove single-incoming phis,
identical-phis, and self-referential trivial phis (braun13cc Algorithm 3:
`φ(v, vφ) → v`, with the user walk iterated to a fixed point; all-self
phis are kept — the IR has no undefined value), forwarding their
operands; pairs with 8.8 (threading produces single-incoming phis).

### 8.8 Jump threading

`src/passes/cfg_jump_thread.zig` — merge empty forwarding blocks (a
block whose only op is an unconditional `br` to a single successor) into
the successor, re-wiring its phi incoming edges, so trivial blocks like
an `if`-then branch that just jumps to the join are eliminated; chains
collapse to their ultimate successor, cycles are left alone, and a
candidate whose predecessor already targets the ultimate successor is
skipped (no duplicate edges).

## Optimization harness

The optimization harness compiles the corpus (`examples/` plus added
benchmarks: `ownership.st` with `drop` hooks, `match.st` ADT `match`),
runs `optimize`, and reports instruction / block / text-byte counts
before and after. The report prints only when the frontend test binary
runs with stderr attached to a terminal — run the compiled
`.zig-cache/o/*/test` binary directly; under `zig build test` stderr is
a captured pipe, and the build runner replays any run-step stderr as an
error, so the report is suppressed there to keep the log clean.

## Implementation files

| File | Role |
| --- | --- |
| `src/passes/cfg_optimize.zig` | Pass 8 driver — runs the full sequence |
| `src/passes/cfg_tail_call.zig` | Pass 7 — tail call optimization |
| `src/passes/cfg_pre.zig` | Pass 8.3 — partial redundancy elimination |
| `src/passes/cfg_dead_instr.zig` | Pass 8.4 — dead-instruction elimination |
| `src/passes/cfg_dead_block.zig` | Pass 8.5 — dead-block elimination |
| `src/passes/cfg_drop_elide.zig` | Pass 8.6 — drop elision |
| `src/passes/cfg_phi_simplify.zig` | Pass 8.7 — phi simplification |
| `src/passes/cfg_jump_thread.zig` | Pass 8.8 — jump threading |
| `src/passes/cfg_validate.zig` | IR validator (Pass 6.1) — structure, SSA, typing, ownership |
| `src/passes/cfg_lower_emit.zig` | On-the-fly optimizations at construction (§4.3) |

## Relationship to other phases

- **Input:** the CFG produced by [Phase 3](phase3-cfg-lowering.md)
  lowering (`IrProgram` with `IrModule` / `IrFunc` / `BasicBlock` /
  `Value`);
- **Validation:** the ir.md §13 validator runs before the sequence and
  after every rewrite;
- **Output:** the optimized CFG consumed by the runtime for module
  instantiation and function execution.
