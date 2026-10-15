# Roadmap

This document is the durable catalog of work the Stilla compiler and runtime
still have open. It records *what is not done*, grouped by subsystem, with the
design document and section that specify it, the source files that would carry
the change, its dependencies, and concrete acceptance criteria. It is not a
work-history log: when an item lands it is removed from this file rather than
marked done, and nothing here records how or when earlier items were completed.

Every item carries one status label:

- **planned** — specified or designed and accepted as work, not yet
  implemented. The remaining blocker is implementation effort.
- **spec-blocked** — the compiler behavior is correct under the current
  normative wording, but the work cannot be finished until the specification
  decides or clarifies the underlying rule.
- **intentionally deferred** — deliberately out of scope for now, gated on
  evidence (a profile, a measurement, or a feature request) or on a consumer
  that does not yet exist.
- **design-blocked** — the design is not settled: a proof model or algorithm the
  work depends on does not exist yet, so the item cannot be finished by
  implementation effort alone. This is distinct from **spec-blocked** (a
  normative wording decision) and from **planned** (implementation only).

**Current priorities.** Correctness first — compiler and runtime destruction
correctness and stronger end-to-end differential and benchmark harnesses; then
the bounded language-conformance gaps; then the C embedding API when non-Zig hosts
are the next consumers. Advanced optimizer expansion (SEG linear-value
rewrites, HIR PRE) proceeds only with evidence of a missed optimization, and
the runtime, `canMove`, and other evidence-gated items stay deferred.

The pipeline documents under this directory remain normative for the
implemented behavior; this file only points at their open edges.

**Relationship to the overhaul plan.** [todo.md](todo.md) is the
prioritized, actionable overhaul plan: ordered work items with code
evidence and a concrete verification for each, spanning the whole compiler
and runtime. This file is the detailed design-level backlog: each item
records the design document and section that specify it, its dependencies,
and its acceptance criteria. Where a todo item overlaps an item here, the
todo item names that item's section rather than restating its design
rationale; the authoritative design detail stays in this file.

## Compiler and optimizer

### SEG linear-value cases

- **Status:** design-blocked.
- **What and why it is open:** SEG is a slotted e-graph arena
  (`hir_egraph.zig`) whose boundary rewrites are admitted through typed
  contracts (`rewrite_contract.zig`), and its rule families currently operate
  only on Copy, total, observable-effect-free subterms. A rewrite that would
  duplicate, drop, or reorder a Unique / consuming / borrowed value is not
  admissible, because the arena has no way to prove that the value's
  destruction schedule is preserved. Closing this needs a linear-equality or
  ownership-preservation proof folded into the rewrite contract, and no such
  proof model exists yet; the rule table marks the Unique rewrite unsupported
  for exactly this reason. The remaining blocker is the missing proof model,
  not implementation effort.
- **Tracked in:** [hir.md](hir.md) §8.3 (`重写规则集`, the `Unique rewrite`
  row); sources `hir_seg.zig`, `hir_egraph.zig`, `rewrite_contract.zig`.
- **Dependencies:** the ownership and `drop_effect` machinery in
  [effects.md](effects.md) §11; the per-node ownership gate reached through
  `hir_effects_queries.zig`.
- **Acceptance:** a probe exercises at least one Unique, consuming, or borrowed
  value that a new rule is allowed to rewrite only after the linear proof
  holds; with SEG on and off the emitted CFG AIR differs and the program's
  runtime output is identical. A candidate that cannot produce the proof is
  still refused, asserted by a white-box rule test.

### HIR PRE (cross-statement and branch sharing)

- **Status:** intentionally deferred.
- **What and why it is open:** the HIR consumer's sharing (`CSE-style
  sharing`) is sibling-only: two candidates must be operands of the same
  `strict_ltr` node inside one full expression. A subexpression computed in
  two separate statements or on two branches of an `if` is therefore not
  shared. [hir.md](hir.md) §8.3 assigns non-sibling sharing to the CFG
  optimizer, so the design question is resolved in favor of CFG PRE
  (`cfg_pre.zig`), while [hir.md](hir.md) §11 still records HIR-level PRE as
  not implemented. The open action is to record the CFG-only decision in
  [hir.md](hir.md) §11, or to revisit HIR-level PRE only with evidence of an
  opportunity that CFG PRE misses.
- **Tracked in:** [hir.md](hir.md) §8.3 (the note that non-sibling sharing is
  left to the CFG optimizer) and §11 (`尚未实现`, PRE); sources
  `hir_simplify.zig` (the HIR consumer) and `hir_seg.zig`.
- **Dependencies:** the sibling-only SEG admission rules in
  [hir.md](hir.md) §8.1–§8.3, and the existing CFG PRE (`cfg_pre.zig`) as the
  fallback.
- **Acceptance:** [hir.md](hir.md) §11 records the CFG-only decision and this
  item is removed; if HIR-level PRE is ever revisited, the evidence is a
  missed optimization that CFG PRE does not capture, demonstrated on a probe
  whose subexpression is computed on both branches of an `if` (or in two
  statements) and is shared once only after the HIR change.

### `select` CSE

- **Status:** planned.
- **What and why it is open:** the emit-time CSE candidate set in
  `cfg_lower_emit.zig` (its `cseOk` tag list) does not include `select`, and
  the standalone CSE pass (`cfg_cse.zig`) runs earlier in the driver sequence
  than if-conversion (`cfg_select.zig`), which is what produces `select`
  instructions. Identical selects in different blocks are therefore never
  merged. The standalone CSE pass recognizes only `module_ref` and
  `load_member`, and its tables are block-local: moving it after
  if-conversion alone would not add select matching or cross-block reuse.
  [optimizer.md](optimizer.md) `If-conversion (branchless select)`
  records merging identical selects across blocks as a follow-up.
- **Tracked in:** [optimizer.md](optimizer.md) `If-conversion (branchless
  select)` and `Module/member CSE`; sources `cfg_lower_emit.zig`,
  `cfg_select.zig`, `cfg_cse.zig`.
- **Dependencies:** none beyond the existing CFG validator (`cfg_validate.zig`),
  which must accept the shared result under the SSA and ownership dataflow.
- **Acceptance:** a probe contains two identical `select`s in different blocks;
  select-aware CSE after if-conversion merges them only when their operands
  and types are exactly identical, the earlier result dominates the later
  definition and all its uses, and the shared result satisfies the SSA and
  ownership dataflow the CFG validator enforces. The emitted CFG AIR differs
  from the unmerged run, and the program's runtime output is unchanged. A
  negative test proves that selects with differing operands or types, or where
  neither definition dominates the other, are not shared. The candidate-set
  comptime assertions in `cfg_lower_emit.zig` still hold. The benefit is
  measured on the corpus through the compile and runtime benchmark baseline,
  because the existing optimization harness reports only instruction, block,
  and text-byte counts.

### `cfg_inline` budget heuristics

- **Status:** planned.
- **What and why it is open:** `cfg_inline.zig` inlines a candidate when its
  cost is below a fixed `inline_budget` (25). The module's own comment records
  that bonuses and penalties on the effective budget are not implemented:
  a single call site, a leaf callee, a tail-position call site, and a call
  site in a loop should raise the effective budget; many call sites and a
  large caller should lower it. The effective budget must also account for the
  caller's size and the resulting code-size and compile-time cost, so a single
  call site is not by itself unconditional permission to inline a callee of
  any size.
- **Tracked in:** [optimizer.md](optimizer.md) `Inlining`; source
  `cfg_inline.zig`.
- **Dependencies:** the optimization harness in [optimizer.md](optimizer.md)
  `Optimization harness` (`frontend_cfg_passes_tests.zig`) for tuning on the
  corpus.
- **Acceptance:** the heuristics are implemented behind the existing budget
  knob and are exercised by the corpus harness; a probe with a single
  call-site callee above the flat budget is inlined while a multi-call-site
  callee of the same size is not, and every optimized program still validates
  and produces unchanged runtime output.

### Canonical HIR text: derived annotations and full-expression wrapping

- **Status:** intentionally deferred (no tooling consumer yet).
- **What and why it is open:** the canonical HIR printer emits only the core
  structural syntax; it does not print the derived `view` / `eff` / `fe`
  annotations or the explicit `fe[ … ]` full-expression wrapper that
  [hir.md](hir.md) §4.6 reserves for them, and `hir_parse.zig` does not accept
  them either. The text form therefore round-trips structure and α-equivalence
  but not the derived boundaries a SEG acceptance output would want to show.
  Structural round-trip and `alphaEq` alone do not prove that the derived
  annotations or the full-expression boundaries survive, so a consumer of the
  text form must reconstruct, recompute, or validate them rather than trusting
  the round-trip.
- **Tracked in:** [hir.md](hir.md) §4.6 (`派生标注与 full-expression 边界`)
  and §4.10 (`工具与测试归属`); sources `hir_print.zig`, `hir_parse.zig`.
- **Dependencies:** the SEG output that would consume the explicit wrapper
  ([hir.md](hir.md) §8), which may be the first real caller.
- **Acceptance:** a golden round-trip test prints a HIR containing derived
  annotations and an explicit full-expression wrapper, re-parses it, and
  passes the structural validator and `alphaEq`; the `--emit-hir` dump remains
  deterministic and byte-stable across invocations.

### Typed HIR target (monomorphization and ownership checking on HIR)

- **Status:** intentionally deferred (architecture direction; not yet scoped).
- **What and why it is open:** monomorphization and the ownership check run
  before HIR construction today. [hir.md](hir.md) §2.3 records a long-term
  boundary in which the pipeline instead builds a *Typed HIR* first and
  specializes it after, moving monomorphization and the ownership check up
  onto HIR. The direction is architectural and unscoped: it would restructure
  the checker / monomorphizer boundary and the HIR builder, and no consumer
  requires it yet, so it stays a recorded direction rather than scheduled
  work.
- **Tracked in:** [hir.md](hir.md) §2.3 (`与现状管线的边界`, the
  `远期边界（Target）` bullet).
- **Dependencies:** none; gated on a concrete consumer or requirement that a
  Typed HIR would serve.
- **Acceptance:** the direction is either adopted with a scoping design that
  names the affected passes and a migration test on the corpus (the full
  corpus still compiles, and an existing test proves the ownership check runs
  on HIR), or it is dropped and [hir.md](hir.md) §2.3 no longer lists it as
  open. Until then this item stays a recorded direction.

## Effects model

### `canMove` / `MovementContext`

- **Status:** intentionally deferred.
- **What and why it is open:** the effect model exposes `isIntrinsicallySpeculatable`
  and `canSwapOperands`, but not `canMove`. Moving an expression between
  evaluation positions needs facts the analysis does not currently model: the
  move path's full-expression boundaries, borrowed-value lifetimes, target
  binder visibility, evaluation counts, and cleanup-registration changes. The
  design says to expose `canMove` only once a code-motion rewrite actually
  needs it, because a query that always returns false would be noise.
- **Tracked in:** [effects.md](effects.md) §10.5 (`实现形态（Zig）`, the
  `canMove` / `MoveContext` sketch and the note that `canMove` is not yet
  exposed); sources `hir_effects_queries.zig` (alongside
  `isIntrinsicallySpeculatable` / `canSwapOperands`).
- **Dependencies:** a HIR code-motion rewrite that consumes the query; the
  full-expression and cleanup model in [effects.md](effects.md) §11.
- **Acceptance:** when the first code-motion consumer lands, `canMove` is
  implemented with a documented `MovementContext`, and a white-box test proves
  it refuses a move that crosses a full-expression boundary, an outstanding
  borrow, or a cleanup registration change. Until such a consumer exists, the
  query stays unexposed.

## Type checker

### Inferred tuple/list element module-value boundary

- **Status:** planned.
- **What and why it is open:** the checker's module-resident flow restriction
  keeps a module value out of local `let` bindings, function arguments,
  returns, declared-`any` positions, struct fields, and union payloads, because
  it types each of those positions against a declared or expected type.
  Tuple and list elements have no declared element type of their own, so an
  inferred element may still carry a module value and the rule is not fully
  closed for container positions. The document records this boundary as
  documented but not yet closed.
- **Tracked in:** [checker.md](checker.md) `Additional checks` (the
  `module-resident flow restrictions` bullet); sources `checker.zig`,
  `checker_validate.zig`, `type_infer.zig`.
- **Dependencies:** the construction-typing rule already in
  [checker.md](checker.md) `Additional checks`, which closes the struct-field
  and union-payload rows (a module value does not widen into `any`).
- **Acceptance:** a black-box diagnostic test in `checker_tests.zig` proves
  that a tuple or list literal with an inferred element position holding a
  module value is rejected with a module-value diagnostic, in addition to the
  existing declared-type cases.

## Embedding and ABI

### C embedding API

- **Status:** planned.
- **What and why it is open:** `libstilla.a` is the linking surface for hosts
  written in other languages, but only the Zig API is public today: there is
  no exported C ABI and no header that declares one. A C embedder currently
  has no declared surface to link against. The deliverable is the exported C
  surface — opaque handles for the program and runtime, an allocator and
  ownership convention, diagnostics retrieval, result and termination
  disposal, and host callback lifetimes — of which the header is one part.
- **Tracked in:** `README.md` (`As a C embedder`) and
  [host-bindings.md](host-bindings.md) §9 (the embedding/typed-layer gaps);
  source `root.zig` (the static-library root that defines the public Zig
  surface).
- **Dependencies:** none; it can ship independently of the typed-layer gaps
  below.
- **Acceptance:** a header is installed alongside `libstilla.a` and declares
  the full exported surface — opaque program/runtime handles, the allocator
  and ownership convention, diagnostics, result and termination disposal, and
  host callback lifetimes — covering the build-program and run-program entry
  points. A small C program that compiles a Stilla source, runs it through a
  host print hook, inspects the termination, and disposes every result
  compiles and links against `libstilla.a` with only the header.

### Automatic host interface-registry discovery

- **Status:** planned.
- **What and why it is open:** [host-bindings.md](host-bindings.md) §9 lists
  automatic discovery of each host module's interface as out of scope: the
  embedder supplies each module's `.st` interface through `interfaceOf`, and
  the registry is not discovered from the module descriptions, so a host
  module that omits its explicit interface does not resolve.
- **Tracked in:** [host-bindings.md](host-bindings.md) §9 (`Out of scope /
  future`, the registry bullet); sources `host_bind.zig`, `host.zig`,
  `interpreter_host.zig`, `interpreter_dispatch.zig`.
- **Dependencies:** none; independent of the other typed-layer gaps.
- **Acceptance:** an embedder that omits an explicit interface for a host
  module still resolves it, and the discovered registry matches the one an
  explicit interface produces.

### Typed ownership transfer through the glue

- **Status:** planned.
- **What and why it is open:** [host-bindings.md](host-bindings.md) §9 lists
  typed ownership transfer as out of scope: `move`/`borrow` transfer and
  list/union/opaque parameters are rejected by the mode check and fall back to
  `raw()`, borrowed-opaque and borrowed-`str` parameters are deferred, and
  retained returns through the typed layer remain open. List/union returns
  already work through hidden-context members returning `RawValue` or
  `HostResult`.
- **Tracked in:** [host-bindings.md](host-bindings.md) §9 (`Out of scope /
  future`, the typed-ownership bullet); sources `host_bind.zig`, `host.zig`,
  `interpreter_host.zig`, `interpreter_dispatch.zig`.
- **Dependencies:** none; independent of the other typed-layer gaps.
- **Acceptance:** members exercising `move`/`borrow` transfer, list/union/opaque
  parameters, and retained returns through typed glue pass the signature check
  and preserve the destruction schedule observed by the lifecycle tests.
  Reusable argument scratch remains allocation-free after capacity is
  established, but owned string-result allocation is not prohibited.

### C-string (`char *`) host returns

- **Status:** intentionally deferred.
- **What and why it is open:** [host-bindings.md](host-bindings.md) §9 lists
  C string (`char *`) returns as out of scope, and no consumer needs them yet.
  The pointer-lifetime, copying, and disposal contract must be defined first:
  whether the host retains ownership, whether the glue copies into an owned
  Stilla string, and when the pointer is freed.
- **Tracked in:** [host-bindings.md](host-bindings.md) §9 (`Out of scope /
  future`, the C-string bullet); sources `host_bind.zig`, `host.zig`,
  `interpreter_host.zig`, `interpreter_dispatch.zig`.
- **Dependencies:** a consumer that returns C strings, and the lifetime /
  copying / disposal contract in [host-bindings.md](host-bindings.md) §9.
- **Acceptance:** once the contract is defined, tests cover conversion to an
  owned Stilla string and disposal under that contract; until then the typed
  layer keeps rejecting C-string returns.

### Hosts that cannot enumerate members statically

- **Status:** planned.
- **What and why it is open:** [host-bindings.md](host-bindings.md) §9 lists
  hosts that cannot enumerate members statically as out of scope; the `invoke`
  opt-out covers them today, so such a host must declare every call through a
  single `invoke` member instead of named members.
- **Tracked in:** [host-bindings.md](host-bindings.md) §9 (`Out of scope /
  future`, the static-enumeration bullet); sources `host_bind.zig`, `host.zig`,
  `interpreter_host.zig`, `interpreter_dispatch.zig`.
- **Dependencies:** none; independent of the other typed-layer gaps.
- **Acceptance:** a host that cannot enumerate its members statically resolves
  and dispatches through the declared mechanism without per-member
  declarations, and the calls it receives pass the signature check.

## Runtime

### Generic-instantiation ownership classification in the destruction walker

- **Status:** intentionally deferred.
- **What and why it is open:** the runtime walker's `typeIsUnique` classifies a
  named struct/union from the serialized image's `TypeDeclDesc.a`, but a generic
  declaration's `ownership` is `null` at lowering and serializes as `no_index`,
  so every generic instantiation falls back to Copy. For a counted child that
  was transferred (a Unique instantiation), construction then retains it while
  the fixed walker releases it once, a net leak in walker-only (`--no-opt cfg`)
  mode; bare `.param` payloads skip both retain and release. It is not reachable
  end to end today because generic recursive unions are rejected by the checker
  and generic counted fields abort interning, but the classification is unsound
  for any future reachable instantiation and contradicts the documented Copy
  fallback. Fix by classifying from the instantiation (serialize a
  per-instantiation ownership row, or thread the already-resolved ownership)
  rather than the template.
- **Tracked in:** [interpreter-vm.md](interpreter-vm.md) §6 (destruction) and §13
  (`Deferred decisions`); sources `interpreter_dispatch.zig` (`typeIsUnique`,
  `retainConstructedChild`), `cfg_lower_llir_intern.zig` (the ownership
  serialization), `cfg_lower_program.zig`.
- **Dependencies:** generic recursive / generic counted-field types becoming
  source-reachable (the checker and `internType` blockers).
- **Acceptance:** a generic instantiation with a Unique counted child destroys
  it exactly once in walker-only mode (no leak, hook runs), asserted by a
  runtime lifecycle test once such a program is accepted by the checker.

### Interpreter VM: deferred decisions

- **Status:** intentionally deferred.
- **What and why it is open:** the VM adopts token-based indirect threading,
  flat value objects, and synchronous host calls. The following are
  deliberately deferred until profiling or a feature request provides
  evidence, and must not shape the public API or add fields to every runtime
  object preemptively: true direct threading (per-instruction jump addresses,
  gated on measurement); a predecode cache (v11 opcodes are already typed, so
  a cache would only save decode, not re-typing — measure first); a stable
  persistence ABI for LLIR binaries; debugger metadata, stepping, snapshots,
  or suspension; asynchronous or reentrant host calls; and JIT compilation,
  concurrency, exceptions, or cycle collection. Flat-array lists and slice
  views, and custom slab allocation or packed object layouts, are also
  deferred under the same evidence gate.
- **Tracked in:** [interpreter-vm.md](interpreter-vm.md) §13 (`Deferred
  decisions`); sources `interpreter.zig`, `interpreter_dispatch.zig`,
  `vm_types.zig`.
- **Dependencies:** a measurement or feature request for each capability.
- **Acceptance:** an item is pulled from this list only together with the
  evidence that motivates it, and then has a test that exercises the new
  behavior without changing the observable results of existing programs; no
  deferred field is added to the runtime object layout before that.

## Testing and reliability harness

### End-to-end and differential test hardening

- **Status:** planned.
- **What and why it is open:** the stsmith sweep driver (`sweep.py`) runs
  generated programs only under the default CLI mode, invokes subprocesses
  without a timeout, and retains failing sources but no generator stderr or
  reproduction metadata. CI does not exercise optimization-mode differentials or
  recursive-type and ownership run fixtures. A generator or compiler hang can
  therefore stall a sweep, and a failure cannot be reproduced from the
  retained artifacts.
- **Tracked in:** the end-to-end harness (`sweep.py`); the differential and run
  fixtures under `probes/` (`probes/README.md`).
- **Dependencies:** none; independent of optimizer work.
- **Acceptance:** subprocess invocations have a bounded timeout; the corpus
  runs with deterministic optimization on/off differentials whose outputs are
  compared; a failing case retains the program, the generator stderr, and the
  exact reproduction command.

### Compile and runtime benchmark baseline

- **Status:** planned.
- **What and why it is open:** the optimization harness
  (`frontend_cfg_passes_tests.zig`) reports only instruction, block, and
  text-byte counts, so the benefit of a pass or of the VM cannot be measured.
  Tuning `cfg_inline` or validating `select` CSE therefore has no stable
  before/after signal.
- **Tracked in:** the optimization harness in [optimizer.md](optimizer.md)
  `Optimization harness`; the run corpus under `probes/` and `examples/`.
- **Dependencies:** none; independent of the items it measures.
- **Acceptance:** a repeatable harness records compile latency and run
  latency/peak memory over the corpus, stable enough to gate future optimizer
  work. It is a prerequisite for the `select` CSE and inlining items.

## Specification decisions

### Core teardown wording versus element-level hook reads

- **Status:** spec-blocked.
- **What and why it is open:** the Core teardown rule is written as "the drop
  hook and its transitive calls" must not read a later-declared module
  constant. Read literally, it omits field- and container-element-level drop
  hooks that run during teardown. The compiler already checks the complete
  `drop_effect(type)` chain, including those hooks; the open work is aligning
  the normative wording with that coverage, not implementing the chain.
  The Copy-constant scope decision is tracked separately below.
- **Tracked in:** [effects.md](effects.md) §15 (`开放问题与现状核对`) and
  §7.2 (`teardown 的对称限制`); sources `hir_effects.zig`
  (`checkModuleDependencies`) and `hir_effects_const.zig`
  (`checkTeardownReads`). The former AST-level `InitOrder` check in
  `checker_validate.zig` has been removed.
- **Dependencies:** the normative teardown rule in the Core and Runtime
  specifications.
- **Acceptance:** once the specification states the intended rule, the
  compiler check implements exactly that wording, `effects.md` §15 no longer
  lists it as open, and the module-constant teardown tests cover both the
  element-level hook read and the Copy-constant read.

### Tightening the teardown schedule to later Unique only

- **Status:** spec-blocked.
- **What and why it is open:** the teardown schedule contains only Unique
  constants, so reading a later Copy constant during teardown has no runtime
  hazard. The Core wording nonetheless forbids reading *any* later constant,
  including Copy. Whether the schedule (and therefore the check) should
  tighten to reject only later Unique reads is a specification decision; the
  compiler currently follows the literal wording.
- **Tracked in:** [effects.md](effects.md) §15 (`开放问题与现状核对`) and
  §7.2 (`teardown 的对称限制`); source `hir_effects.zig`
  (`checkModuleDependencies`).
- **Dependencies:** the same normative decision as the wording item above;
  these two are expected to be resolved together.
- **Acceptance:** the specification states the schedule scope, the checker
  matches it, and a test distinguishes a later Unique read (rejected) from a
  later Copy read (accepted, if that is the decision).

## Host effect metadata

### Concrete effect-domain overlap/disjoint entries

- **Status:** intentionally deferred.
- **What and why it is open:** the resource registry currently holds a
  `stable` domain set and explicit non-transitive `disjoint` pairs. The
  standard-library host tree declares the six bundled host modules'
  relationships, but the concrete overlap/disjoint entries for the remaining
  real host domains do not exist yet. Undeclared pairs conservatively
  conflict, which is sound but leaves optimization on the table. The
  relationship model is already defined; concrete entries are supplied as
  host modules appear, rather than waiting on a normative rule change.
- **Tracked in:** [effects.md](effects.md) §15 (`开放问题与现状核对`) and
  §5.6 (`冲突、可交换与资源域粒度`); sources `effects_registry.zig`,
  `effects_conflict.zig`, `effects_host.zig`.
- **Dependencies:** concrete host modules with declared effect metadata
  ([effects.md](effects.md) §13) and known resource relationships, which
  supply the domains to relate.
- **Acceptance:** each newly declared host domain has its `stable` /
  `disjoint` entries filled into the registry provider and validated at engine
  freeze; a test shows the intended pair becomes `orderCompatible` while an
  undeclared pair still conflicts.

## Explicit non-goal

### Runtime-side host-contract verification

Runtime-side verification that a host module honors the contract it declares
(effect metadata, reentrancy, ownership transfer) is deliberately out of
scope and is **not** a roadmap item. The compiler cannot see host code, so it
cannot verify the contract at runtime; it trusts an explicitly declared
contract and treats a missing one as `Unknown`. This is separate from the
compile-time signature verification the host-binding layer does own. See
[effects.md](effects.md) §15 and [host-bindings.md](host-bindings.md) §5.
