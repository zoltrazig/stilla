# Optimizer — Tail Call Optimization and Mid-Level Rewrites

> Status: **implemented** — Passes 7 and 8 in the frontend pipeline.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts).
> The AIR op inventory and data structures are authoritative in
> [`spec/air.md`](spec/air.md) §4–§11 and `src/cfg.zig`.

## Overview

The optimizer is a fixed sequence of semantics-preserving CFG→CFG
rewrites that runs after [Phase 3](phase3-cfg-lowering.md) lowering
and before the runtime consumes the AIR. It is wired into
`frontend.compile` behind `frontend.Options.optimize` (default off;
the `stilla` executable hardcodes it on; code-only toggle, no CLI flag).

The sequence runs as a **single ordered pass by default — no
iteration to fixpoint** — so compile time stays near-linear.
`frontend.Options.optimize_aggressive` (code-only, like `optimize`)
requests bounded iteration instead: the sequence loops until a full
iteration changes nothing (the printed text form is unchanged) or the
compile-time cap `cfg_optimize.aggressive_max_iters` is reached
(§8.9). The full air.md §13 validator (`cfg.validate`) runs before the
sequence and after every rewrite *within each iteration*: an optimizer
bug that violates structure, SSA, typing, or the ownership dataflow is
a compile-time diagnostic in either mode. The single-pass default is
byte-identical in both modes' shared path: `optimizeAggressive` with
`max_iters = 1` is exactly the default single pass.

Constant folding, arithmetic simplification, common subexpression
elimination, and copy propagation no longer exist as separate
passes — they run on-the-fly at each instruction's construction site
during [Phase 3](phase3-cfg-lowering.md) (braun13cc.pdf §3.1).
The remaining Pass 8 sequence is: tail-call optimization, PRE,
dead-block elimination, drop elision, jump threading, and phi
simplification — followed by the post-optimization drop-lowering pass
(§8.7), which expands every statically-expandable `drop` into explicit
CFG operations.

## The LLIR lowering boundary (separate from the CFG optimizer)

The redundancy elimination at the CFG → LLIR *boundary* is
not a CFG rewrite. It lives in the typed layer
(`cfg_lower_typed.zig`, `cfg_lower_llir_emit.zig`): a value-form lattice
(the top-bits state of the 64-bit cell) is computed once per function,
and the expander uses it to elide a canonicalization record whose operand
form makes it a no-op (`typed.elideLeadingZext` — a leading `zext32` on
an already-zero-extended operand of a u32 `div`/`rem`/`min`/`max`/`shr`).
The expander also owns the staged immediate fusion (step 6): a 32-bit
`div`/`rem`/`shl`/`shr` with a fuse-eligible constant is emitted as the
immediate form, and the constant's `zext32`/`andi` staging record is never
written (it reads the zero-extended staging register). This is distinct
from the record-level peepholes that remain in `llir_fusion.zig` (the
non-staged and 64-bit immediate fusion, the `le`/`ge` comparison
`not`-kill, and the multiply-accumulate fuse), which run on the
already-emitted widthless stream. The CFG-side CSE stays at construction.
The emitter consumes the form lattice (`typed.compute` → `func_forms`)
for that residual elimination only; no CSE runs on the un-expanded typed
IR in production — `typedOps` / `printTyped` are the inspection/test
surface for what Layer A sees.

## AIR validator (Pass 6.1)

`src/passes/cfg_validate.zig` (re-exported as `cfg.validate` /
`lower.validate`) is a schema-driven checker:

- **structure** — blocks, terminators, and instruction sequences;
- **SSA dominance** — every value use is dominated by its definition;
- **arity and typing** — from `cfg.opInfo` (air.md §13);
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

Replace `call` + `ret` with a `j` back to the function's own entry
block, re-binding the callee's parameters from the call arguments and
splicing in phis for the reused frame's SSA values (air.md §14.7). The
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
a move-mode parameter never loops back through a phi (air.md §14.7) — it
is instead expressed as the `tailcall` terminator (air.md §14.7.1), which
carries move/unique state atomically into a reused frame, so the
Copy-only limitation does not forbid `iter`-style unique-accumulator
iteration, it only means a unique value never re-enters the loop as a
phi.

## Pass 8 — Mid-level optimizer driver

`src/passes/cfg_optimize.zig` (re-exported by `lower`) — a driver that
runs a fixed sequence of semantics-preserving CFG→CFG rewrites over the
lowered CFG, after Pass 7 and before the runtime consumes it. Each
sub-pass is one file in `src/passes/`; each rewrite must preserve
observable behavior (Runtime §5) and the air.md §13 invariants.

### On-the-fly optimizations (phase 3, at construction)

These run at each instruction's construction site in
`cfg_lower_emit.zig`'s `emit`, replacing what would otherwise be
separate CFG→CFG passes:

- **constant folding** — fold `arithmetic`/`bitwise`/`compare`/`logic`/`num_cast`
  ops whose operands are constant at their emit site (`tryFoldOp`,
  braun13cc Algorithm 3's §3.1); `div`/`rem` by zero and out-of-range
  `float32 → int32` must still trap (Runtime §7.1);
- **arithmetic simplification** — integer identities only (`x−x→0`,
  `x+0→x`, `x·1→x`, `x·0→0`, `x/1→x`, `x%1→0`, plus the bitwise
  identities `x&0→0`, `x|0→x`, `x^0→x`); float identities are
  unsound (`x−x≠0` for NaN, `0·x≠0` for ±inf/NaN, `0+x≠x` for −0.0);
- **common subexpression elimination** — reuse an identical pure
  computation earlier in the same block at its emit site; block-local
  (the first occurrence dominates), Copy results only (air.md §5.4),
  operands matched positionally (no commutativity); the reused value is
  returned directly, so no `copy` is involved;
- **copy propagation** — a `move` of a Copy value lowers directly to the
  value (a copy of a Copy value is the value, air.md §5.4), so no
  `copy` instructions reach the AIR from the frontend.

### 8.1 Partial redundancy elimination

`src/passes/cfg_pre.zig` — rewrite a computation available on some —
but not all — incoming edges of a join to a phi, inserting the
computation at the end of the edges that lacked it; candidates are pure,
non-trapping ops only (comparisons, `not`, `type_is` — hoisting a
trapping op onto a skipped path would change observable behavior,
Runtime §7.2), Copy results, operands defined in a strict dominator of
the join; the join's computation is replaced by the phi with the same
result value, and values are renumbered in text order (air.md §13).

### 8.2 Dead-instruction elimination

`src/passes/cfg_dead_instr.zig` — remove an instruction whose results
are unused, Copy, and produced by a side-effect-free, non-consuming,
non-trapping op (`num_cast` qualifies — casts never trap, Runtime §7.2;
the guarded `read_payload` of a match arm whose payload
is unused is the common corpus case); iterated to a fixed point; calls,
syscalls, consuming destructures, `div`/`rem`/reads (traps) and
phis are never candidates.

### 8.3 Dead-block elimination

`src/passes/cfg_dead_block.zig` — remove blocks unreachable from the
entry; update phi incoming lists and predecessor sets accordingly
(air.md §3).

### 8.4 Drop elision

`src/passes/cfg_drop_elide.zig` — remove a `drop` whose destruction is
provably unobservable — the value is Copy, or already dead; must never
remove a user `drop` hook that performs output (air.md §14) and never
moves a destruction earlier than its prescribed point (air.md §6.4) — a
type with a user hook is always classified unique, so only Copy drops are
elided, and `cleanup_drop` / `cleanup_disarm` (whose token's payload is
an unique owner) are never elided — v1 emits no cleanup tokens, so this
guards text-form and validator input only.

### 8.5 Phi simplification

`src/passes/cfg_phi_simplify.zig` — remove single-incoming phis,
identical-phis, and self-referential trivial phis (braun13cc Algorithm 3:
`φ(v, vφ) → v`, with the user walk iterated to a fixed point; all-self
phis are kept — the AIR has no undefined value), forwarding their
operands; pairs with 8.6 (threading produces single-incoming phis).

### 8.6 Jump threading

`src/passes/cfg_jump_thread.zig` — merge empty forwarding blocks (a
block whose only op is an unconditional `j` to a single successor) into
the successor, re-wiring its phi incoming edges, so trivial blocks like
an `if`-then branch that just jumps to the join are eliminated; chains
collapse to their ultimate successor, cycles are left alone, and a
candidate whose predecessor already targets the ultimate successor is
skipped (no duplicate edges).

### 8.8 If-conversion (branchless select)

`src/passes/cfg_select.zig` — replace a *select diamond* — `br %c, B1,
B2` where both arms hold only pure, non-consuming instructions and jump
to the same join whose phis have exactly the `[B1, B2]` incomings —
with one `select %c, %a, %b` per joined phi (the condition, then, and
else values), hoisting the arms' instructions into the cond block and
forwarding the phi results' uses. Fires only when every joined value is
a scalar *Copy* type (int32/uint32/float32/byte/bool) and every arm
instruction is pure and non-consuming (no effects, traps, or
consumptions — a side effect must stay on its path, a trap the branch
would have avoided, a `move`/`unpack` of a unique base its conditional
destruction). The emptied arms become unreachable and are removed by
8.3 dead-block elimination, which follows in the driver sequence; the
LLIR image of a `select` is `copy cond_reg, %cond` + `cmov dst, %a,
%b` — the branchless alternative to the compare-and-branch plus the
two edge copies, and the only producer/consumer of the condition
register (`cond`, Instruction Set §3.1). Selects do not yet participate
in CSE (the pass runs after it); merging identical selects across
blocks is a follow-up.

### 8.9 Optional fixpoint iteration (aggressive mode)

`src/passes/cfg_optimize.zig`'s `optimizeAggressive(program, allocator,
max_iters)` runs the Pass 7–8 sequence repeatedly — iteration 1 is the
full fixed order of §8.0–8.6; each later iteration is the same order
with the one-shot inliner (§8.0) skipped — until a full iteration
produces a byte-identical printed text form (the fixpoint: no rewrite
in the sequence changed anything) or `max_iters` iterations have run.
The inliner is excluded from later iterations by contract: it is
explicitly one-shot ("the spliced body's own call sites are not
re-scanned this round, keeping the pass one shot"), and re-running it
on a spliced *recursive* callee keeps finding new call sites inside
its own copies — the CFG grows without bound (fib.st measures 26 →
138 non-phi instructions over four iterations) instead of converging.
The remaining passes re-run over the same order with the same §6.1
validator after every rewrite; the loop always terminates at equality
or the cap. Whether a later iteration shrinks, reshapes (PRE inserts
edge computations, if-conversion trades phis for selects), or leaves a
program alone is program-dependent, so "aggressive never worse than
the default single pass" is enforced empirically over the example
corpus (below), not by construction. The documented one-shot behaviors
a later iteration does catch:

- **jump-threading chains** — a chain collapsed in one pass may leave
  one forwarding block behind (§8.6), which the next iteration's
  threading removes;
- **dead blocks from late passes** — a block orphaned by a pass that
  runs after dead-block elimination (threading, phi simplification) is
  removed by the next iteration's §8.3.

`frontend.Options.optimize_aggressive` (default off) wires the loop
into `frontend.compile` with the cap `cfg_optimize.aggressive_max_iters`
(4). Every iteration is guarded by the §6.1 validator, so the mode
cannot weaken the optimizer's invariant contract; it only spends more
compile time. The corpus harness (Optimization harness, below) doubles
as the never-worse
check: aggressive output is asserted ≤ the default single-pass output
on the example corpus (text bytes, non-phi instructions, blocks).

### 8.7 Drop lowering (post-optimization)

`src/passes/cfg_lower_drop.zig` — after the Pass 8 sequence, expand every
`drop` the CFG can express into explicit operations at the drop's
program point: a struct drop becomes its hook call (when declared) +
`unpack_struct` + reverse-declaration-order field drops (recursively); a
tuple drop becomes `unpack_tuple` + reverse element drops; a `box[T]`
drop becomes `builtin#unbox` + a drop of the contained value; a union
drop becomes `read_tag` + a `switch` destroying the active variant's
payload (payload-less variants destroy nothing). Only the drops that
must dispatch dynamically stay single instructions: opaque host types
(`host_drop`), `hostdata`, `list[T]`, and `any`. The expansion needs the
phase-1 module graph (the AIR type environment is name-only) and runs in
the frontend's optimize path, re-validated before the AIR text
round-trip (air.md §6.4, §14).

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
| `src/passes/cfg_pre.zig` | Pass 8.1 — partial redundancy elimination |
| `src/passes/cfg_dead_instr.zig` | Pass 8.2 — dead-instruction elimination |
| `src/passes/cfg_dead_block.zig` | Pass 8.3 — dead-block elimination |
| `src/passes/cfg_drop_elide.zig` | Pass 8.4 — drop elision |
| `src/passes/cfg_phi_simplify.zig` | Pass 8.5 — phi simplification |
| `src/passes/cfg_jump_thread.zig` | Pass 8.6 — jump threading |
| `src/passes/cfg_select.zig` | Pass 8.8 — if-conversion (branchless select) |
| `src/passes/cfg_lower_drop.zig` | 8.7 — post-optimization drop lowering (structural drop expansion) |
| `src/passes/cfg_validate.zig` | AIR validator (Pass 6.1) — structure, SSA, typing, ownership |
| `src/passes/cfg_lower_emit.zig` | On-the-fly optimizations at construction |

## Relationship to other phases

- **Input:** the CFG produced by [Phase 3](phase3-cfg-lowering.md)
  lowering (`IrProgram` with `IrModule` / `IrFunc` / `BasicBlock` /
  `Value`);
- **Validation:** the air.md §13 validator runs before the sequence and
  after every rewrite;
- **Output:** the optimized CFG consumed by the runtime for module
  instantiation and function execution.
