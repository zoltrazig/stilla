# Optimizer — Tail Call Optimization and Mid-Level Rewrites

> Status: **implemented**.
> Normative language rules are cited from the Core and Runtime
> specifications in [`spec/`](../spec/) (tracking the v1.3 drafts).
> The AIR op inventory and data structures are authoritative in
> [`spec/air.md`](../spec/air.md) and `src/cfg.zig`.
> The ordered pass inventory is canonical in [passes.md](passes.md).

## Overview

The optimizer is a fixed sequence of semantics-preserving CFG→CFG
rewrites that runs after [cfg-lowering.md](cfg-lowering.md) lowering
and before the runtime consumes the AIR. It is wired into
`frontend.compile` behind the `cfg` gate of `OptimizeConfig`
(`optimize_config.zig`): the library default is off, and the `stilla`
executable turns it on (see [Config gating](#config-gating) for all
gates and sub-toggles).

The sequence runs as a **single ordered pass — no iteration to
fixpoint** — so compile time stays near-linear. The air.md validator
(`cfg.validate`) runs before the sequence and after every rewrite: an
optimizer bug that violates structure, SSA, typing, or the ownership
dataflow is a compile-time diagnostic.

Constant folding, arithmetic simplification, block-local common
subexpression elimination, and copy folding run **on-the-fly at each
instruction's construction site** during CFG lowering
(braun13cc §3.1). Two of those also exist as **standalone
CFG rewrites** later in the sequence — `cfg_cse.zig` (module
reference / member-load CSE) and `cfg_copy_prop.zig` (copy
propagation) — because the construction-time forms are
block-local, while the pass forms catch cross-lowering redundancy. The
driver sequence is: **tail-call elimination, function inlining,
module/member CSE, copy propagation, partial redundancy elimination,
if-conversion, dead-block elimination, drop elision, dead-instruction
elimination, jump threading, phi simplification** — followed by the
post-optimization drop-lowering pass (below). The ordered inventory
with the driver entry is [passes.md](passes.md).

## Config gating

Optimization is configured by `OptimizeConfig` (`optimize_config.zig`),
one boolean per optimization unit. Three top-level gates select a
family, and each family has one sub-toggle per rewrite:

| Gate | Units (sub-toggles) |
| --- | --- |
| `hir` | `dead_let`, `anf`, `never_suffix` |
| `seg` | `seg_beta`, `seg_eta`, `seg_let_dead`, `seg_let_forward`, `seg_let_atom`, `seg_match`, `seg_reorder`, `egraph_fold`, `egraph_algebra`, `egraph_cond`, `egraph_project`, `egraph_cse`, `egraph_ac` |
| `cfg` | `cfg_tail_call`, `cfg_inline`, `cfg_cse`, `cfg_copy_prop`, `cfg_pre`, `cfg_if_convert`, `cfg_dead_block`, `cfg_drop_elide`, `cfg_dead_instr`, `cfg_jump_thread`, `cfg_phi_simplify` |

`egraph_ac` is the integer commutativity **and associativity** search in the
SEG arena (`hir.md` §8.2): it canonicalizes `eq` / `ne` operand order and, for
the integer AC ops (`add` / `mul` / `band` / `bor` / `bxor` / `min` / `max`),
flattens, canonically orders, and regroups operand chains.

**Library defaults:** every gate off, every sub-toggle on.
**Executable defaults:** `seg` and `cfg` on, `hir` off, every
sub-toggle on. The CLI exposes one generic pair, `--opt <name>` /
`--no-opt <name>`, where `<name>` is a config field name; the last
occurrence wins. The dedicated `--seg`, `--no-seg`, and `--simplify`
flags are removed.

## The LLIR lowering boundary (separate from the CFG optimizer)

The typed opcode choice at the CFG → LLIR *boundary* is not a CFG
rewrite. It lives in the typed layer (`cfg_lower_typed.zig`,
`cfg_lower_llir_emit.zig`): each arithmetic / comparison / cast node
becomes one `TypedOp` (the operand's rep in the opcode —
`add.i32`/`shr.u64`), and the emitter writes exactly one record per
node — no canonicalization records, no staging register, no value-form
lattice: every producer leaves its canonical cell canonical by
construction. Immediate fusion is part
of the same choice: an arithmetic node whose right operand is a
constant inside the rep's immediate window lowers as the immediate form
(`addi.i32`, `divi.u64`) and the single-use `const` slot read drops out.
This is distinct from the record-level peepholes that remain in
`llir_fusion.zig` (the remaining immediate fusion outside the expander,
the `le`/`ge` comparison `not`-kill, and the multiply-accumulate fuse),
which run on the already-emitted record stream. The CFG-side CSE stays
at construction and in `cfg_cse.zig`. No CSE runs on the typed ops in
production — `typedOps` / `printTyped` are the inspection/test surface
for what Layer A sees.

## AIR validator

`src/passes/cfg_validate.zig` (re-exported as `cfg.validate` /
`lower.validate`) is a schema-driven checker:

- **structure** — blocks, terminators, and instruction sequences;
- **SSA dominance** — every value use is dominated by its definition;
- **arity and typing** — from `cfg.opInfo` (air.md);
- **edge-sensitive ownership dataflow** — `Available` / `Consumed` /
  `MaybeConsumed` over the CFG, per-edge phi inputs, atomic
  `unpack_*` / `split_list` consumption.

The frontend runs it on every lowered program; the optimizer runs it
before the sequence and after every rewrite.

## Tail call optimization

`src/passes/cfg_tail_call.zig` (re-exported by `lower`) — a CFG→CFG
rewrite of calls in tail position into frame-reusing jumps, so
self-recursion becomes iteration. Runs first in the driver.

### Tail-position detection

A `call` (or `syscall`) whose result is immediately `ret`ed, or a
`void`/`never` call directly followed by `ret`, in a block with no live
unique state afterwards and no armed cleanup token on the tail edge.

### Rewrite

Replace `call` + `ret` with a `j` back to the function's own entry
block, re-binding the callee's parameters from the call arguments and
splicing in phis for the reused frame's SSA values (air.md). The
chain drop is guarded:

- an intermediate chain block (between the call block and the ret block)
  must have exactly one predecessor, so it forwards only the call's
  result — an extra predecessor merges another arm's value, which dropping
  the chain edge would strand (multi-arm guarded recursion stays a call);
- the ret block must keep at least one non-chain predecessor, so the
  rewrite cannot orphan the function's only `ret`.

### Ownership preservation

The rewrite must not reorder any `drop` or observable effect: the
returned value's destruction schedule (Runtime) is unchanged because
the frame is reused; only direct `call`s to a known `IrFunc` are
candidates (a call through a function *value* has no statically known
target); the rewrite is **Copy-only**: loop-carried parameters are all
Copy and a move-mode parameter never loops back through a phi (air.md)
— it is instead expressed as the `tailcall` terminator (air.md), which
carries move/unique state atomically into a reused frame, so the
Copy-only limitation does not forbid `iter`-style unique-accumulator
iteration, it only means a unique value never re-enters the loop as a
phi.

## The optimizer driver

`src/passes/cfg_optimize.zig` (re-exported by `lower`) — a driver that
runs a fixed sequence of semantics-preserving CFG→CFG rewrites over the
lowered CFG, after tail-call elimination and before the runtime consumes
it. Each sub-pass is one file in `src/passes/`; each rewrite must
preserve observable behavior (Runtime) and the air.md invariants, and
the driver validates after every rewrite.

The exact order (`optimizeOnce`): **`tailCall` → `inlineCalls` → `cse` →
`copyProp` → `pre` → `ifConvert` → `deadBlock` → `dropElide` →
`deadInstr` → `jumpThread` → `phiSimplify`**, then a final print-order
renumber (`cfg_inline.renumberPrintOrder`) so the canonical text form is
a valid SSA order (copyProp and phiSimplify substitute values across
blocks, which can leave a forward reference; the canonical text form
(air.md) requires definitions to print before uses).

### On-the-fly optimizations (at construction)

These run at each instruction's construction site in
`cfg_lower_emit.zig`'s `emit`, handling the redundancy a single block of
lowering produces. They are **complemented by** the two standalone CFG
rewrites of the same family (module/member CSE, copy propagation),
which catch what construction-time block-local folding cannot:

- **constant folding** — fold `arithmetic`/`bitwise`/`compare`/`logic`/`num_cast`
  ops whose operands are constant at their emit site (`tryFoldOp`,
  braun13cc Algorithm 3's §3.1); trapping integer `div`/`rem` cases stay
  unfolded (the float forms are total), while `float32 → int32` is total
  (truncate toward zero, NaN→0, then saturate; Runtime); the
  mathematically exact `int32_min % -1` folds to `0` — it never traps
  (WebAssembly semantics, Runtime) — while the `int32_min / -1`
  division-overflow case stays unfolded;
- **arithmetic simplification** — integer identities only (`x−x→0`,
  `x+0→x`, `x·1→x`, `x·0→0`, `x/1→x`, `x%1→0`, plus the bitwise
  identities `x&0→0`, `x|0→x`, `x^0→x`); float identities are
  unsound (`x−x≠0` for NaN, `0·x≠0` for ±inf/NaN, `0+x≠x` for −0.0);
- **block-local common subexpression elimination** — reuse an identical
  pure computation earlier in the same block at its emit site;
  block-local (the first occurrence dominates), Copy results only
  (air.md), operands matched positionally (no commutativity); the
  reused value is returned directly, so no `copy` is involved;
- **copy folding** — a `move` of a Copy value lowers directly to the
  value (a copy of a Copy value is the value, air.md), so no
  `copy` instructions reach the AIR from the frontend.

### Inlining

`src/passes/cfg_inline.zig` — the first sub-pass of the driver (after
`tailCall`, before `cse`). Selected **direct** calls to a statically
known `IrFunc` are replaced by a spliced copy of the callee's body:
parameters are bound at the splice point (renamed to the call's
arguments), the callee's `ret` blocks are re-wired to the call's
continuation, and the call's result is rebound as the continuation's
return phi.

Candidate rules:

- **safety filters** — direct call to a statically known `IrFunc` only
  (no function values, same as TCO, air.md); **non-recursive**:
  the candidate's call-graph path must not reach the enclosing function
  (self- and mutual recursion rejected; the call graph is built once up
  front); call-site arguments 1:1 with the callee's parameters (a
  void-typed parameter produces no call operand);
- **one-shot by contract** — the spliced body's own call sites are not
  re-scanned this round; the inliner is never re-run, because
  re-inlining a spliced *recursive* callee would keep finding new call
  sites inside its own copies and grow the CFG without bound;
- the surrounding passes clean up: `cse`/`copyProp`/`pre`/`deadInstr`
  absorb the duplicated redundancy, `dropElide`/drop lowering see the
  new drops, and `phiSimplify`/`jumpThread` clean the new blocks.

### Module/member CSE

`src/passes/cfg_cse.zig` — local common subexpression elimination over
**module references and member loads**: an identical `module_ref` earlier
in the same block is reused, and an identical `load_member` of the same
module slot (whose result is Copy) is reused, so repeated module/member
reads fold to one load.

Soundness: `module_ref` is a pure constant — the module handle is the
same value on every reference, so an identical reference earlier in the
block is reused. `load_member` reads a module slot; module storage is
written only by `store_member` inside `@init` (cfg_validate rejects a
store anywhere else, air.md), so a slot's value is stable for the
life of a function — a repeated load of the same slot from the same
module value is redundant unless a `store_member` intervenes, which
clears the table. Only Copy results are shared, mirroring the
on-the-fly rule: a Copy member read is a copy, an unique read is a
borrowed view, and sharing a view across uses would change the
destruction schedule (air.md). The rewrite is in-block — the
canonical definition sits earlier in the same block, so it dominates
the later value and every use — and values are renumbered in text order
afterwards (air.md).

### Copy propagation

`src/passes/cfg_copy_prop.zig` — replaces every `copy` of a Copy value by
the value itself, so copy-of-copy chains collapse and a copied parameter
that is directly returned passes the parameter through.

A `copy` of a Copy value does nothing at runtime (Core —
destruction is unobservable, and the ownership classification
guarantees a Copy type never runs a user drop hook), so the result is
interchangeable with the operand: every use of the result is rewritten
to the operand and the copy is removed. The operand's definition
dominates the copy's result, which dominates every use, so the rewrite
is sound. Unique copies are never touched: their refcount/ownership
transfer is observable (air.md). One pass over the blocks suffices
(`rewriteUses` scans the whole function, so a copy processed early
collapses uses in every block, including copies that later become chains
of length one); values are renumbered in text order afterwards (air.md).

### Partial redundancy elimination

`src/passes/cfg_pre.zig` — rewrite a computation available on some —
but not all — incoming edges of a join to a phi, inserting the
computation at the end of the edges that lacked it. Candidates are the
pure, non-trapping ops: the comparisons, the total unary ops (`not`,
`neg`, `abs`, `clz`, `popcount`, `type_is`), the total wrapping
arithmetic (`add`/`sub`/`mul`/`min`/`max` — integer forms wrap modulo
2³²), the shifts (count masked to its low 5 bits), the bitwise ops,
`num_cast` (casts never trap, Runtime), and the float forms of
`div`/`rem` (IEEE-total: `x/0` is ±inf, `x%0` is NaN — the
discriminator is the float result type). The integer `div`/`rem`
forms trap on a zero divisor and stay excluded — hoisting a trapping
op onto a skipped path would change observable behavior, Runtime
— as do the schema-level trapping ops (`read_index`, `any_unpack_*`,
`split_list`) and anything effectful or consuming. `concat` stays out:
it allocates a fresh string, so moving it onto skipped paths changes
allocation cost even though it is total. Copy results only, operands
defined in a strict dominator of the join; the join's computation is
replaced by the phi with the same result value, and values are
renumbered in text order (air.md).

`num_cast` availability needs one extra condition: `cfg.identical`
compares only the operand, but a cast's *target type* lives on its
result value — two casts of the same operand to different types are
different computations. The pass therefore requires result-type
equality (`meta.Type.eql`) in addition to `cfg.identical` when matching
a `num_cast` against a predecessor's computation; the other candidates
cannot hit this, because their opcode plus operand values fix the
result type.

### If-conversion (branchless select)

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
dead-block elimination, which follows in the driver sequence; the
LLIR image of a `select` is `copy cond_reg, %cond` + `cmov dst, %a,
%b` — the branchless alternative to the compare-and-branch plus the
two edge copies, and the only producer/consumer of the condition
register (`cond`, Instruction Set). Selects do not yet participate
in CSE (the CSE pass runs before it); merging identical selects across
blocks is a follow-up.

### Dead-block elimination

`src/passes/cfg_dead_block.zig` — remove blocks unreachable from the
entry; update phi incoming lists and predecessor sets accordingly
(air.md). Also removes the emptied select-diamond arms of if-conversion.

### Drop elision

`src/passes/cfg_drop_elide.zig` — remove a `drop` whose destruction is
provably unobservable — the value is Copy, or already dead; must never
remove a user `drop` hook that performs output (air.md) and never
moves a destruction earlier than its prescribed point (air.md) — a
type with a user hook is always classified unique, so only Copy drops are
elided, and `cleanup_drop` / `cleanup_disarm` (whose token's payload is
an unique owner) are never elided — the pipeline emits no cleanup
tokens, so this guards text-form and validator input only.

### Dead-instruction elimination

`src/passes/cfg_dead_instr.zig` — iteratively remove unused Copy results from
its explicit, conservative set of side-effect-free, non-consuming,
non-trapping candidates (`num_cast` qualifies — casts never trap, Runtime;
the guarded `read_payload` of a match arm whose payload is unused is
the common corpus case; shifts and bitwise ops qualify — the shift count
is masked to its low 5 bits and the bitwise ops work on raw patterns,
neither ever traps). The `div`/`rem` exclusion is type-aware rather than
wholesale: the integer forms trap (zero divisor, and the 64-bit
signed-division overflow) and a dead trap must stay, but the float forms
are total (IEEE: `x/0` is ±inf, `x%0` is NaN) and a dead float
`div`/`rem` is removed. Calls, syscalls, consuming destructures,
dynamically indexed `read_index` (traps), and phis are never candidates.
Fixed projections and `tail` are also outside the candidate set without
being classified as trapping — the audit found no ownership
impediment for Copy results (`created = .operand` means the Copy-result
filter already excludes every unique-base view) and no lowering-cost
hazard, but adoption is gated on a measured corpus case per the
acceptance criteria; the corpus today produces none.

### Jump threading

`src/passes/cfg_jump_thread.zig` — merge empty forwarding blocks (a
block whose only op is an unconditional `j` to a single successor) into
the successor, re-wiring its phi incoming edges, so trivial blocks like
an `if`-then branch that just jumps to the join are eliminated; chains
collapse to their ultimate successor, cycles are left alone, and a
candidate whose predecessor already targets the ultimate successor is
skipped (no duplicate edges).

### Phi simplification

`src/passes/cfg_phi_simplify.zig` — remove single-incoming phis,
identical-phis, and self-referential trivial phis (braun13cc Algorithm 3:
`φ(v, vφ) → v`, with the user walk iterated to a fixed point; all-self
phis are kept — the AIR has no undefined value), forwarding their
operands; pairs with jump threading (threading produces single-incoming
phis).

### Drop lowering (post-optimization)

`src/passes/cfg_lower_drop.zig` — after the optimizer sequence, expand every
`drop` the CFG can express into explicit operations at the drop's
program point: a struct drop becomes its hook call (when declared) +
`unpack_struct` + reverse-declaration-order field drops (recursively); a
tuple drop becomes `unpack_tuple` + reverse element drops; a `box[T]`
drop becomes `builtin#unbox` + a drop of the contained value; a union
drop becomes `read_tag` + a `switch` destroying the active variant's
payload (payload-less variants destroy nothing). Only the drops that
must dispatch dynamically stay single instructions: opaque host types
(`host_drop`), `hostdata`, `list[T]`, and `any`. The expansion needs the
module graph (the AIR type environment is name-only) and runs in
the frontend's optimize path, re-validated before the AIR text
round-trip (air.md).

## Optimization harness

The optimization harness compiles the corpus (`examples/` plus added
benchmarks: `ownership.st` with `drop` hooks, `match.st` ADT `match`),
runs the `cfg` gate, and reports instruction / block / text-byte counts
before and after. The report prints only when the frontend test binary
runs with stderr attached to a terminal — run the compiled
`.zig-cache/o/*/test` binary directly; under `zig build test` stderr is
a captured pipe, and the build runner replays any run-step stderr as an
error, so the report is suppressed there to keep the log clean.

## Implementation files

| File | Role |
| --- | --- |
| `src/passes/optimize_config.zig` | `OptimizeConfig`: one boolean per optimization unit (the `hir` / `seg` / `cfg` gates and their sub-toggles) |
| `src/passes/cfg_optimize.zig` | the optimizer driver — runs the full sequence |
| `src/passes/cfg_tail_call.zig` | tail call optimization |
| `src/passes/cfg_inline.zig` | function inlining (one-shot, non-recursive direct calls) |
| `src/passes/cfg_cse.zig` | module/member common subexpression elimination |
| `src/passes/cfg_copy_prop.zig` | copy propagation |
| `src/passes/cfg_pre.zig` | partial redundancy elimination |
| `src/passes/cfg_select.zig` | if-conversion (branchless select) |
| `src/passes/cfg_dead_block.zig` | dead-block elimination |
| `src/passes/cfg_drop_elide.zig` | drop elision |
| `src/passes/cfg_dead_instr.zig` | dead-instruction elimination |
| `src/passes/cfg_jump_thread.zig` | jump threading |
| `src/passes/cfg_phi_simplify.zig` | phi simplification |
| `src/passes/cfg_lower_drop.zig` | post-optimization drop lowering (structural drop expansion) |
| `src/passes/cfg_validate.zig` | AIR validator — structure, SSA, typing, ownership |
| `src/passes/cfg_lower_emit.zig` | On-the-fly optimizations at construction |

## Relationship to the pipeline

- **Input:** the CFG produced by [cfg-lowering.md](cfg-lowering.md)
  lowering (`IrProgram` with `IrModule` / `IrFunc` / `BasicBlock` /
  `Value`);
- **Validation:** the air.md validator runs before the sequence and
  after every rewrite;
- **Output:** the optimized CFG consumed by the runtime for module
  instantiation and function execution. The ordered inventory is
  canonical in [passes.md](passes.md).
