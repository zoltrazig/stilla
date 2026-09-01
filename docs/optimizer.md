# Optimizer — Tail Call Optimization and Mid-Level Rewrites

> Status: **implemented** — Passes 7 and 8 in the frontend pipeline.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](spec/) (tracking the v1.3 drafts).
> The AIR op inventory and data structures are authoritative in
> [`spec/air.md`](spec/air.md) §4–§11 and `src/cfg.zig`.
> The ordered pass inventory is canonical in [passes.md](passes.md).

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
(§8.10). The full air.md §12 validator (`cfg.validate`) runs before the
sequence and after every rewrite *within each iteration*: an optimizer
bug that violates structure, SSA, typing, or the ownership dataflow is
a compile-time diagnostic in either mode. The single-pass default is
byte-identical in both modes' shared path: `optimizeAggressive` with
`max_iters = 1` is exactly the default single pass.

Constant folding, arithmetic simplification, block-local common
subexpression elimination, and copy folding run **on-the-fly at each
instruction's construction site** during [Phase 3](phase3-cfg-lowering.md)
lowering (braun13cc.pdf §3.1). Two of those also exist as **standalone
CFG rewrites** later in the Pass 8 sequence — `cfg_cse.zig` (module
reference / member-load CSE, §8.1) and `cfg_copy_prop.zig` (copy
propagation, §8.2) — because the construction-time forms are
block-local, while the pass forms catch cross-lowering redundancy. The
Pass 8 driver sequence is: **tail-call elimination (Pass 7), function
inlining (§8.0), module/member CSE (§8.1), copy propagation (§8.2),
partial redundancy elimination (§8.3), if-conversion (§8.4), dead-block
elimination (§8.5), drop elision (§8.6), dead-instruction elimination
(§8.7), jump threading (§8.8), phi simplification (§8.9)** — followed by
the post-optimization drop-lowering pass (below). The ordered inventory
with the driver entry is [passes.md](passes.md).

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
already-emitted widthless stream. The CFG-side CSE stays at construction
and in `cfg_cse.zig`. The emitter consumes the form lattice
(`typed.compute` → `func_forms`) for that residual elimination only; no
CSE runs on the un-expanded typed IR in production — `typedOps` /
`printTyped` are the inspection/test surface for what Layer A sees.

## AIR validator (Pass 6.1)

`src/passes/cfg_validate.zig` (re-exported as `cfg.validate` /
`lower.validate`) is a schema-driven checker:

- **structure** — blocks, terminators, and instruction sequences;
- **SSA dominance** — every value use is dominated by its definition;
- **arity and typing** — from `cfg.opInfo` (air.md §5);
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
observable behavior (Runtime §5) and the air.md §12 invariants, and the
driver validates after every rewrite.

The exact order (`optimizeOnce`): **`tailCall` → `inlineCalls` → `cse` →
`copyProp` → `pre` → `ifConvert` → `deadBlock` → `dropElide` →
`deadInstr` → `jumpThread` → `phiSimplify`**, then a final print-order
renumber (`cfg_inline.renumberPrintOrder`) so the canonical text form is
a valid SSA order (copyProp and phiSimplify substitute values across
blocks, which can leave a forward reference; the canonical text form
(air.md §10) requires definitions to print before uses).

### On-the-fly optimizations (phase 3, at construction)

These run at each instruction's construction site in
`cfg_lower_emit.zig`'s `emit`, handling the redundancy a single block of
lowering produces. They are **complemented by** the two standalone CFG
rewrites of the same family (§8.1 module/member CSE, §8.2 copy
propagation), which catch what construction-time block-local folding
cannot:

- **constant folding** — fold `arithmetic`/`bitwise`/`compare`/`logic`/`num_cast`
  ops whose operands are constant at their emit site (`tryFoldOp`,
  braun13cc Algorithm 3's §3.1); `div`/`rem` by zero and out-of-range
  `float32 → int32` must still trap (Runtime §7.1);
- **arithmetic simplification** — integer identities only (`x−x→0`,
  `x+0→x`, `x·1→x`, `x·0→0`, `x/1→x`, `x%1→0`, plus the bitwise
  identities `x&0→0`, `x|0→x`, `x^0→x`); float identities are
  unsound (`x−x≠0` for NaN, `0·x≠0` for ±inf/NaN, `0+x≠x` for −0.0);
- **block-local common subexpression elimination** — reuse an identical
  pure computation earlier in the same block at its emit site;
  block-local (the first occurrence dominates), Copy results only
  (air.md §5.4), operands matched positionally (no commutativity); the
  reused value is returned directly, so no `copy` is involved;
- **copy folding** — a `move` of a Copy value lowers directly to the
  value (a copy of a Copy value is the value, air.md §5.4), so no
  `copy` instructions reach the AIR from the frontend.

### 8.0 Inlining

`src/passes/cfg_inline.zig` — the first sub-pass of the driver (after
`tailCall`, before `cse`). Selected **direct** calls to a statically
known `IrFunc` are replaced by a spliced copy of the callee's body:
parameters are bound at the splice point (renamed to the call's
arguments), the callee's `ret` blocks are re-wired to the call's
continuation, and the call's result is rebound as the continuation's
return phi.

Candidate rules:

- **safety filters** — direct call to a statically known `IrFunc` only
  (no function values, same as TCO, air.md §14.7); **non-recursive**:
  the candidate's call-graph path must not reach the enclosing function
  (self- and mutual recursion rejected; the call graph is built once up
  front); call-site arguments 1:1 with the callee's parameters (a
  void-typed parameter produces no call operand);
- **one-shot by contract** — the spliced body's own call sites are not
  re-scanned this round; `optimizeAggressive` never re-runs the inliner
  (§8.10), because re-inlining a spliced *recursive* callee would keep
  finding new call sites inside its own copies and grow the CFG without
  bound (fib.st measures 26 → 138 non-phi instructions over four
  iterations);
- the surrounding passes clean up: `cse`/`copyProp`/`pre`/`deadInstr`
  absorb the duplicated redundancy, `dropElide`/drop lowering see the
  new drops, and `phiSimplify`/`jumpThread` clean the new blocks.

### 8.1 Module/member CSE

`src/passes/cfg_cse.zig` — local common subexpression elimination over
**module references and member loads**: an identical `module_ref` earlier
in the same block is reused, and an identical `load_member` of the same
module slot (whose result is Copy) is reused, so repeated module/member
reads fold to one load.

Soundness: `module_ref` is a pure constant — the module handle is the
same value on every reference, so an identical reference earlier in the
block is reused. `load_member` reads a module slot; module storage is
written only by `store_member` inside `@init` (cfg_validate rejects a
store anywhere else, air.md §5.6), so a slot's value is stable for the
life of a function — a repeated load of the same slot from the same
module value is redundant unless a `store_member` intervenes, which
clears the table. Only Copy results are shared, mirroring the
on-the-fly rule: a Copy member read is a copy, an unique read is a
borrowed view, and sharing a view across uses would change the
destruction schedule (air.md §6.4). The rewrite is in-block — the
canonical definition sits earlier in the same block, so it dominates
the later value and every use — and values are renumbered in text order
afterwards (air.md §10).

### 8.2 Copy propagation

`src/passes/cfg_copy_prop.zig` — replaces every `copy` of a Copy value by
the value itself, so copy-of-copy chains collapse and a copied parameter
that is directly returned passes the parameter through.

A `copy` of a Copy value does nothing at runtime (Core §10.1 —
destruction is unobservable, and the ownership classification
guarantees a Copy type never runs a user drop hook), so the result is
interchangeable with the operand: every use of the result is rewritten
to the operand and the copy is removed. The operand's definition
dominates the copy's result, which dominates every use, so the rewrite
is sound. Unique copies are never touched: their refcount/ownership
transfer is observable (air.md §6.4). One pass over the blocks suffices
(`rewriteUses` scans the whole function, so a copy processed early
collapses uses in every block, including copies that later become chains
of length one); values are renumbered in text order afterwards (air.md
§10).

### 8.3 Partial redundancy elimination

`src/passes/cfg_pre.zig` — rewrite a computation available on some —
but not all — incoming edges of a join to a phi, inserting the
computation at the end of the edges that lacked it; candidates are pure,
non-trapping ops only (comparisons, `not`, `type_is` — hoisting a
trapping op onto a skipped path would change observable behavior,
Runtime §7.2), Copy results, operands defined in a strict dominator of
the join; the join's computation is replaced by the phi with the same
result value, and values are renumbered in text order (air.md §10).

### 8.4 If-conversion (branchless select)

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
§8.5 dead-block elimination, which follows in the driver sequence; the
LLIR image of a `select` is `copy cond_reg, %cond` + `cmov dst, %a,
%b` — the branchless alternative to the compare-and-branch plus the
two edge copies, and the only producer/consumer of the condition
register (`cond`, Instruction Set §3.1). Selects do not yet participate
in CSE (the CSE pass runs before it); merging identical selects across
blocks is a follow-up.

### 8.5 Dead-block elimination

`src/passes/cfg_dead_block.zig` — remove blocks unreachable from the
entry; update phi incoming lists and predecessor sets accordingly
(air.md §3). Also removes the emptied select-diamond arms of §8.4.

### 8.6 Drop elision

`src/passes/cfg_drop_elide.zig` — remove a `drop` whose destruction is
provably unobservable — the value is Copy, or already dead; must never
remove a user `drop` hook that performs output (air.md §14) and never
moves a destruction earlier than its prescribed point (air.md §6.4) — a
type with a user hook is always classified unique, so only Copy drops are
elided, and `cleanup_drop` / `cleanup_disarm` (whose token's payload is
an unique owner) are never elided — v1 emits no cleanup tokens, so this
guards text-form and validator input only.

### 8.7 Dead-instruction elimination

`src/passes/cfg_dead_instr.zig` — remove an instruction whose results
are unused, Copy, and produced by a side-effect-free, non-consuming,
non-trapping op (`num_cast` qualifies — casts never trap, Runtime §7.2;
the guarded `read_payload` of a match arm whose payload
is unused is the common corpus case); iterated to a fixed point; calls,
syscalls, consuming destructures, `div`/`rem`/reads (traps) and
phis are never candidates.

### 8.8 Jump threading

`src/passes/cfg_jump_thread.zig` — merge empty forwarding blocks (a
block whose only op is an unconditional `j` to a single successor) into
the successor, re-wiring its phi incoming edges, so trivial blocks like
an `if`-then branch that just jumps to the join are eliminated; chains
collapse to their ultimate successor, cycles are left alone, and a
candidate whose predecessor already targets the ultimate successor is
skipped (no duplicate edges).

### 8.9 Phi simplification

`src/passes/cfg_phi_simplify.zig` — remove single-incoming phis,
identical-phis, and self-referential trivial phis (braun13cc Algorithm 3:
`φ(v, vφ) → v`, with the user walk iterated to a fixed point; all-self
phis are kept — the AIR has no undefined value), forwarding their
operands; pairs with 8.8 (threading produces single-incoming phis).

### 8.10 Optional fixpoint iteration (aggressive mode)

`src/passes/cfg_optimize.zig`'s `optimizeAggressive(program, allocator,
max_iters)` runs the Pass 7–8 sequence repeatedly — iteration 1 is the
full fixed order of §8.0–8.9; each later iteration is the same order
with the one-shot inliner (§8.0) skipped — until a full iteration
produces a byte-identical printed text form (the fixpoint: no rewrite
in the sequence changed anything) or `max_iters` iterations have run.
The inliner is excluded from later iterations by contract (§8.0:
re-running it on a spliced *recursive* callee keeps finding new call
sites inside its own copies — the CFG grows without bound instead of
converging). The remaining passes re-run over the same order with the
same §6.1 validator after every rewrite; the loop always terminates at
equality or the cap. Whether a later iteration shrinks, reshapes (PRE
inserts edge computations, if-conversion trades phis for selects), or
leaves a program alone is program-dependent, so "aggressive never worse
than the default single pass" is enforced empirically over the example
corpus (below), not by construction. The documented one-shot behaviors
a later iteration does catch:

- **jump-threading chains** — a chain collapsed in one pass may leave
  one forwarding block behind (§8.8), which the next iteration's
  threading removes;
- **dead blocks from late passes** — a block orphaned by a pass that
  runs after dead-block elimination (threading, phi simplification) is
  removed by the next iteration's §8.5.

`frontend.Options.optimize_aggressive` (default off) wires the loop
into `frontend.compile` with the cap `cfg_optimize.aggressive_max_iters`
(4). Every iteration is guarded by the §6.1 validator, so the mode
cannot weaken the optimizer's invariant contract; it only spends more
compile time. The corpus harness (Optimization harness, below) doubles
as the never-worse
check: aggressive output is asserted ≤ the default single-pass output
on the example corpus (text bytes, non-phi instructions, blocks).

### Drop lowering (post-optimization)

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
| `src/passes/cfg_inline.zig` | 8.0 — function inlining (one-shot, non-recursive direct calls) |
| `src/passes/cfg_cse.zig` | 8.1 — module/member common subexpression elimination |
| `src/passes/cfg_copy_prop.zig` | 8.2 — copy propagation |
| `src/passes/cfg_pre.zig` | 8.3 — partial redundancy elimination |
| `src/passes/cfg_select.zig` | 8.4 — if-conversion (branchless select) |
| `src/passes/cfg_dead_block.zig` | 8.5 — dead-block elimination |
| `src/passes/cfg_drop_elide.zig` | 8.6 — drop elision |
| `src/passes/cfg_dead_instr.zig` | 8.7 — dead-instruction elimination |
| `src/passes/cfg_jump_thread.zig` | 8.8 — jump threading |
| `src/passes/cfg_phi_simplify.zig` | 8.9 — phi simplification |
| `src/passes/cfg_lower_drop.zig` | post-optimization drop lowering (structural drop expansion) |
| `src/passes/cfg_validate.zig` | AIR validator (Pass 6.1) — structure, SSA, typing, ownership |
| `src/passes/cfg_lower_emit.zig` | On-the-fly optimizations at construction |

## Relationship to other phases

- **Input:** the CFG produced by [Phase 3](phase3-cfg-lowering.md)
  lowering (`IrProgram` with `IrModule` / `IrFunc` / `BasicBlock` /
  `Value`);
- **Validation:** the air.md §12 validator runs before the sequence and
  after every rewrite;
- **Output:** the optimized CFG consumed by the runtime for module
  instantiation and function execution. The ordered inventory is
  canonical in [passes.md](passes.md).
