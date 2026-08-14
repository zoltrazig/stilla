# Stilla IR: 3-Address Code in SSA Form for the CFG

> Status: **v0.1 draft** — the design of the compile-time intermediate
> representation produced by frontend Phase 3 (frontend.md §5) and consumed
> by the runtime. This document is **authoritative for the IR**: it refines
> and supersedes the §5.2 sketch in `frontend.md`. Normative language
> semantics are cited from the Core and Runtime specifications in
> [`spec/`](spec/).

## 1. Purpose and scope

The IR is the boundary between the compile-time and run-time halves of the
implementation. It is a **control-flow graph of basic blocks over
three-address instructions in static single assignment (SSA) form**, with
ownership and destruction made explicit.

The IR must carry, without reference to source text:

- the full **control flow** of a function (CFG: blocks, edges, terminators);
- the full **value flow** (SSA: each value defined exactly once, joined by
  phi nodes at merges);
- the **evaluation order** (Runtime §5) — linear instruction order inside a
  block *is* evaluation order; short-circuiting is real control flow;
- the **ownership semantics** (Core §10) — every affine value is moved,
  borrowed, copied, or dropped by an explicit instruction;
- the **destruction schedule** (Runtime §6) — when and in what order values
  are destroyed;
- **module storage** — module members as statically laid-out slots, and
  host bindings as system calls (frontend.md §5.5–§5.6).

What the IR is *not*: it is not an optimizer IR, not a register-based IR,
and not target code. Phase 3 emits direct, semantically faithful CFG; all
optimization is a later consumer (§14).

## 2. Design principles

1. **Three-address code.** Every instruction computes **one result** from
   **at most two source operands**. The exceptions — aggregate
   `construct`, `call`, `syscall`, and `phi` — are n-ary in operands but
   still have exactly one result (or are pure effects); they are the
   standard exceptions every 3-address IR makes (§4.2). A strict
   canonization into ≤2-operand form is always available by introducing
   intermediate values, so the property is not lost, merely elided where
   the operand list is statically typed.
2. **Static single assignment.** Every value is defined exactly once;
   control-flow merges join values with `phi`. Stilla's immutable
   bindings and shadowing map onto SSA without any renaming pass
   (Core §4: "Stilla is therefore SSA-friendly"): each `let` is a fresh
   definition, shadowing is a fresh name.
3. **Exactly-once, left-to-right evaluation.** Inside a block, instruction
   order *is* source evaluation order (Runtime §5). Short-circuit `and` /
   `or` never become instructions — they lower to conditional-branch
   diamonds so the right operand is evaluated only when required.
4. **Ownership is explicit.** `move`, `borrow`, `copy`, and `drop` are
   instructions. Every affine value is used at most once per path and
   destroyed exactly once per path; destruction is materialized in the CFG
   (frontend.md §5.4), not left to the runtime to infer.
5. **Locals are values; only module storage is memory.** All local state
   lives in SSA values. The sole memory in the IR is module storage —
   statically laid-out slots written once by the module init function and
   read afterwards (Core §2.1, Runtime §2.2).

## 3. The CFG

A function is a directed graph of **basic blocks**. A block is a linear
sequence of instructions terminated by exactly one **terminator**.

- **Entry block.** Every function has exactly one entry block, which has
  no predecessors; the parameter values `%0..%k-1` are defined there.
- **Terminators.** Exactly one per block, and it is the last instruction.
  The five forms are `ret`, `br` (unconditional), `br_cond` (conditional),
  `switch` (union dispatch), and `trap` (never/panic — Runtime §7).
- **Layout.** Blocks are ordered so that fall-through is the common case:
  an unconditional `br` to the *next* block in layout may be elided by the
  printer; the in-memory form always carries an explicit terminator.
- **Edges.** `br_cond` has exactly two out-edges; `switch` has one per arm
  plus an implicit default that is `trap` (match exhaustiveness is
  guaranteed by the checker, Core §13.3, so the default is unreachable).

```
terminator ::= "ret" value?                  -- return; bare "ret" for void
             | "br" label
             | "br" value "?" label ":" label
             | "switch" value "{" tag "->" label ("," tag "->" label)* "}"
             | "trap"
```

**CFG invariants** (checked by the validator, §13):

- every block except the entry has at least one predecessor;
- every block ends in exactly one terminator; no instruction follows it;
- the entry block is reachable; every block is reachable from the entry
  (phase 3 produces no dead blocks; a consumer may prove more);
- every out-edge of `br_cond`/`switch` names an existing block;
- `phi` nodes appear only at the head of a block, one incoming per
  predecessor edge, in the same order as the block's predecessor list.

## 4. Values, instructions, and SSA

### 4.1 Definitions

- **Value** — one SSA definition: the result of exactly one instruction.
  Values carry an IR-native `Type` (§4.2, §11), an **ownership class**
  inherited from the type (duplicable / affine, `cfg.Ownership`), and a
  **created state** (owned / borrowed, §6.1). Whether a value is still
  *available* at a program point — alive, consumed, or consumed on some
  paths only — is not a value property: it is an edge-sensitive dataflow
  property computed by the validator (§13) and the lowering's
  consumption bookkeeping. Values are numbered per function in definition
  order (`%0, %1, …`); the text form also permits symbolic names (`%sum`)
  for readability.
- **Instruction** — a unit of computation. An instruction either *defines*
  one or more values (a single result for ordinary ops; several for the
  atomic destructure ops `unpack_*` / `split_list`, §5.3) or is a
  **pure effect** with no results: `drop`, `store_member`,
  `cleanup_disable`, `drop_cleanup`.
- **Use** — a reference to a value as an operand. SSA requires that every
  non-phi use of a value is **dominated** by its definition; a phi's
  operands are defined in the corresponding predecessor blocks.

```
instr   ::= value "=" op            -- defining instruction
          | effect                   -- drop | store_member
value   ::= "%" ident | "%" number
```

### 4.2 The three-address property, precisely

For every *defining* instruction except `construct`, `call`, `syscall`,
and `phi`, the operand count is at most two; the atomic destructure ops
are the only multi-*result* instructions:

```
%r = op %a           -- unary
%r = op %a, %b       -- binary
```

The four n-ary exceptions are exactly the instructions whose operand list
is a **statically typed, fixed-shape list** (field list, argument list,
incoming-edge list). They are kept n-ary so the CFG stays small and the
dataflow edges remain explicit; §13's validator checks operand counts
against each op's arity.

### 4.3 Phi

A join merges one value per incoming edge:

```
join:
    %m: int32 = phi [%a, then], [%b, else]
    ret %m
```

The phi's type is the **join type** of the merged values:

- identical types join to themselves;
- `never` contributes nothing — a `trap`-terminated block is simply not
  listed as a phi source, because it never completes (Core §13.2);
- a mix coercible to `any` joins as `any` (Core §11.6);
- anything else is a phase-2 error and never reaches the IR.

The `T → any` coercion of a mixed join is **not** implicit at the phi:
the lowering materializes it on each predecessor edge (§4.4) — `%x_any =
any_pack_copy %x` (duplicable source) or `any_pack_move %x` (affine
source) is appended to the branch block before its `br join`, and the
phi joins the homogeneous `any` values. Ownership stays explicit and the
phi's operand types are verifiable (§13).

### 4.4 Coercions

Conversions are explicit instructions (Core §16): `num_cast` for the
numeric pair (`int32 ↔ float32`, §5.2), and the four `any`-ops
(`any_pack_copy` / `any_pack_move` / `any_unpack_copy` /
`any_unpack_move`, §5.2) for the top type. The remaining coercion is
implicit and materialized at specific points:

- **`never` → T** — a call whose result type is `never` is always
  immediately followed by `trap` (§8.3); a `trap` block contributes no
  value to a phi (§4.3).
- **T → `any`** — at call boundaries (arguments to `any`-typed
  parameters, `ret` of an `any`-typed function) and on the predecessor
  edges of an `any` join (§4.3). A duplicable source is `any_pack_copy`'d
  into the `any` (the source stays owned); an affine source is
  `any_pack_move`'d (the source is consumed) (Core §11.6: "A duplicable
  source value is copied into the `any`; an affine source value must be
  moved"). Both are ordinary instructions emitted by the lowering pass.
- **`any` → T recovery** — `a as T` for a duplicable `T` lowers to
  `any_unpack_copy` (payload copied out, the `any` stays owned); `(move
  a) as T` — the only legal recovery of an affine payload — lowers to
  `any_unpack_move`, consuming the complete `any` and transferring
  payload ownership to the result (Core §11.6.1).

## 5. The instruction set

`type_` is the static type of the produced value; state transitions are
defined in §6.2. `#i` denotes a statically known index. Operand order in
the text form is operand order in memory and, where evaluation order
matters, source order (Runtime §5).

### 5.1 Constants, parameters, modules

| op | form | produces | notes |
| --- | --- | --- | --- |
| `const` | `%d = const k` | literal type | int/uint/float/bool/str/void (Core §5); negative literals are constants |
| `arg` | `%d = arg #i` | param type | parameter `i` by index; created `owned`, or `borrowed` when the parameter's mode is `borrow` (Core §10.6) |
| `module_ref` | `%d = module_ref "spec"` | module type | static module value (Core §2.3); a constant usable in any function (§7) |

### 5.2 Arithmetic, comparison, logic, casts

Operand types per Core §16.3; trap behavior (overflow, divide-by-zero,
invalid `any` recovery, out-of-range float→int) per Runtime §7.2. Every
op's **effect class** — pure, pure-but-may-trap, side-effecting — is
declared in the op schema (`cfg.opInfo`, §11) and consumed by the
validator (§13) and the optimizer's rewrite legality (CSE and PRE may
only move or share effect-free computations).

| op | form | produces |
| --- | --- | --- |
| `neg` | `%d = neg %a` | same numeric type; traps on `minInt` negation |
| `not` | `%d = not %a` | `bool` (source `!`) |
| `num_cast` | `%d = num_cast %a` | the other numeric type; the Core §16.3 pair (`int32 ↔ float32`) only; `float32 → int32` traps on NaN, ±inf, or out-of-range |
| `type_is` | `%d = type_is %a, T` | `bool` — runtime tag test against type `T` (Core §11.6.2, §14.7: a type-test arm of a `match` over an `any`) |
| `any_pack_copy` | `%d = any_pack_copy %a` | `any` — `T → any` of a duplicable source (Core §11.6); the source stays owned |
| `any_pack_move` | `%d = any_pack_move %a` | `any` — `T → any` of an affine source; the source is consumed |
| `any_unpack_copy` | `%d = any_unpack_copy %a` | `T` — `any as T` for a duplicable `T` (Core §11.6.1); the `any` stays owned; traps on a tag mismatch |
| `any_unpack_move` | `%d = any_unpack_move %a` | `T` — `(move any) as T`; the complete `any` is consumed, payload ownership transfers to the result; traps on a tag mismatch |
| `add sub mul div rem` | `%d = add %a, %b` | same numeric type; int overflow and `div`/`rem` by zero trap |
| `concat` | `%d = concat %a, %b` | `str` (source `str + str`, Core §16) |
| `eq ne lt le gt ge` | `%d = lt %a, %b` | `bool` |

`and` and `or` have **no** instructions: they lower to `br_cond` diamonds
(§10.3). `!` is `not`. Comparison operators do not chain (Core §16.1), so
no IR constraint is needed beyond what phase 2 enforces.

### 5.3 Aggregates and projections

`construct` builds a value from components; projections read components.
Projections come in two access kinds:

- **read** — non-consuming: copies the component for duplicable bases,
  produces a **borrowed view** for affine bases (member reads, borrowed
  matches, Core §10.7, §13.4);
- **unpack** — consuming destructure: **atomic and multi-result**. One op
  consumes the base *as a whole* and defines all of its parts at once
  (destructuring with `move`, Core §14.6, §18 *Whole-owner rule*) — no
  half-consumed base states exist. The results are the struct fields in
  declaration order, the tuple elements, the variant's payload values
  (tag-carrying, see below), or the list items followed by the owned
  rest. An exact list pattern (`[a, b]`, no `..rest`) defines only the
  items; the consumed remainder is dropped immediately (the whole list
  is still consumed). A `[]` arm of a consuming match defines nothing
  and still consumes the base.

| op | form | produces |
| --- | --- | --- |
| `construct` | `%d = construct %a, %b, …` | struct (fields in declaration order, Core §8.1) |
| `construct` | `%d = construct #tag %a, …` | union variant with discriminant `#tag` (Core §11.1) |
| `construct` | `%d = construct %a, %b` | tuple (Core §11.4) |
| `construct` | `%d = construct %a, %b, …` | list literal (Core §11.5) |
| `read_field` | `%d = read_field %b, #i` | struct field `i`, borrowed view |
| `read_tuple` | `%d = read_tuple %t, #i` | tuple element `i`, borrowed view |
| `read_index` | `%d = read_index %l, %i` | list element, borrowed view; bounds check traps (Runtime §7.2) |
| `tail` | `%d = tail %l` | borrowed sublist view (`[head, ..tail]`, Core §14.5) |
| `unpack_struct` | `%a: T, %b: U = unpack_struct %s` | all struct fields (consumes `%s`) |
| `unpack_tuple` | `%a: T, %b: U = unpack_tuple %t` | all tuple elements (consumes `%t`) |
| `unpack_variant` | `%p: T = unpack_variant %u, #k` | the payload of variant `#k` (consumes `%u`); the tag is carried for backend self-containment — the arm's `switch` dispatch already guaranteed the variant |
| `split_list` | `%a: T, %b: T, %r: list[T] = split_list %l` | list items then the owned rest (consumes `%l`; may trap on a short list, Runtime §7.2) |
| `read_tag` | `%d = read_tag %u` | union discriminant, as a tag index |
| `read_payload` | `%d = read_payload %u` | payload of the active variant, borrowed view |

`builtin.box`, `builtin.peek`, and `builtin.unbox` are **not** IR ops:
they are host bindings and lower to `syscall` (Core §3, Runtime §4.7–§4.8,
§8.2). A `peek` result arrives in the IR as a `borrowed` value (§6.2),
matching `<borrowed T>` (Runtime §4.8).

### 5.4 Ownership

| op | form | produces |
| --- | --- | --- |
| `copy` | `%d = copy %a` | an owned copy; `%a` must be duplicable (Core §10.1) |
| `borrow` | `%d = borrow %a` | a non-owning view of `%a` (Core §10.7, §10.8) |
| `move` | `%d = move %a` | ownership of `%a` transferred; `%a` is dead (Core §10.4) |
| `drop` | `drop %v` | effect: deterministic destruction (Core §9, Runtime §6); `%v` is dead; `%v` is never duplicable — the frontend does not emit `drop` for duplicable values |
| `cleanup_owner` | `%d: cleanup = cleanup_owner %v` | a **cleanup token** (type `cleanup`, §11) scheduling `%v`'s conditional destruction (Core §10.10, §6.4); a compiler-only value usable only by `cleanup_disable` / `drop_cleanup` |
| `cleanup_disable` | `cleanup_disable %d` | effect: disarms the token without destroying the payload — emitted on the paths where the owner was consumed (moved, taken, transferred) |
| `drop_cleanup` | `drop_cleanup %d` | effect: the scope-end conditional destruction — destroys the payload iff the token is still armed, then disarms it |

`move` of a duplicable value is semantically a copy with no invalidation
(Core §10.6: "For duplicable types, `move` is semantically equivalent to
an ordinary copy") — the lowering emits `copy` in that case. Because
duplicable is a subset of affine (Core §10.1), `drop` of a duplicable
value does nothing and the frontend never emits it; the lowering's
`emitDrop` skips any value whose type is duplicable. `drop` of a
struct with a user drop hook executes the full Runtime §6.2 sequence
(hook, then reverse-declaration-order field destruction) inside the
runtime; the IR does not expand it (§6.4). Conditional destruction of a
maybe-affine value is scheduled through its cleanup token (§6.4): the
maybe-affine *value* itself is never referenced after its construct's
join — only its token is, so the destruction instruction is SSA-clean on
every path (a v0.1 `trydrop %v, %flag` required referencing a value that
was already consumed on the `%flag == false` paths).

### 5.5 Calls and system calls

| op | form | produces |
| --- | --- | --- |
| `call` | `%d = call %f, %a, %b, …` | return type; n-ary; callee is a function value or a direct function reference (§8) |
| `syscall` | `%d = syscall target, %a, …` | return type; host binding (§8.2); when the return type is `void` or `never` the result may be omitted |

Both are n-ary (§4.2). Argument evaluation is callee, then arguments left
to right, exactly once (Runtime §5).

### 5.6 Memory: module storage

| op | form | produces |
| --- | --- | --- |
| `load_member` | `%d = load_member %m, #i` | the member type (Runtime §2.2) |
| `store_member` | `store_member #i, %v` | effect; writes slot `#i` of the *current* module — legal only inside `@init` (§7) |

### 5.7 Phi and terminators

| op | form |
| --- | --- |
| `phi` | `%d = phi [%v, L1], [%w, L2]` — n-ary, block head only (§4.3) |
| `ret` | `ret %v` or `ret` — return, transferring ownership of an affine result to the caller |
| `br` | `br L` — unconditional |
| `br_cond` | `br %c ? L1 : L2` — `%c: bool` |
| `switch` | `switch %t { #a -> L1, #b -> L2 }` — dispatch on a tag value; implicit `trap` default |
| `trap` | `trap` — panic / `never` / unreachable (Runtime §7.1) |

## 6. Ownership model

### 6.1 Value states

A value carries its **created state**, fixed by its defining op:

| state | meaning | created by |
| --- | --- | --- |
| `owned` | the current function owns the value | every defining op that is not a view |
| `borrowed` | a non-owning view of some base | `borrow`, `read_*` / `tail` over an affine base, `arg` of a borrow-mode parameter, `peek` (Runtime §4.8) |

Whether a value is still *available* at a program point is **not** a
value property: it is an edge-sensitive dataflow state — `Available`,
`Consumed`, or `MaybeConsumed` (alive on some paths, consumed on others
after a join) — computed by the validator (§13) and mirrored by the
lowering's consumption bookkeeping. A value in `MaybeConsumed` state has
**no uses at all** after its construct's join (Core §10.10: a
maybe-affine binding is unusable); its destruction is scheduled through
its cleanup token (§6.4), which references the token, never the value.

### 6.2 State transitions

| instruction | operand state → | result state | notes |
| --- | --- | --- | --- |
| `const`, `arg` (plain/move), arithmetic, `num_cast`, `any_pack_*`, `construct`, `call`, `syscall`, `load_member`, `module_ref` | — | `owned` | |
| `arg` (borrow mode) | — | `borrowed` | |
| `copy` | `owned` or `borrowed`, duplicable | `owned` | copying a duplicable value is always legal (Core §10.1) |
| `borrow` | `owned` or `borrowed` | `borrowed` | |
| `read_*` / `tail` | base `owned` (duplicable) → base unchanged | `owned` | implicit copy |
| `read_*` / `tail` | base `owned`/`borrowed` (affine) → base unchanged | `borrowed` | |
| `read_tag` / `read_payload` | scrutinee unchanged | `owned` (tag) / per above (payload) | |
| `move` | `%a` consumed | `owned` | |
| `unpack_*` / `split_list` | base consumed as a whole; results owned | `owned` | §5.3 |
| `any_pack_move` / `any_unpack_move` | operand consumed | `owned` | the `T → any` / `any → T` ownership transfers (§4.4) |
| `call` arg, plain/borrow | unchanged | — | borrow params take a view; no ownership change (Core §10.6) |
| `call` arg, move | consumed | — | ownership transfers (Core §10.6) |
| `drop` | `%v` consumed | — | effect |
| `cleanup_disable` / `drop_cleanup` | token only | — | effect; the scheduled owner is never referenced (§6.4) |
| `phi` | incoming affine values consumed on their edges | `owned` (join) | §6.3 |
| `ret %v` | `%v` (owned affine) consumed | — | borrowed returns are a phase-2 error (Core §10.7) |

**Affine discipline invariants** (guaranteed by phase 2, checked by the
validator in simplified form, §13):

- an affine `owned` value is consumed at most once per path (one of:
  `move`, `drop`, `unpack_*` / `split_list`, a move-mode call argument, a phi, `ret`);
- after consumption there are no further uses on that path;
- a `borrowed` value is never `move`'d, `drop`'d, `unpack_*`'d / `split_list`'d,
  stored, or returned (Core §10.7) — its uses are reads, borrows, and
  borrow-mode arguments only;
- a duplicable value may be used any number of times.

### 6.3 Phi and ownership

A phi over affine values is legal because CFG join edges are
**exclusive by construction**: exactly one predecessor edge is taken, so
exactly one incoming value is ever materialized. The phi's result owns
whichever value arrived:

```
then:  %a = …            else:  %b = …
       br join                   br join
join:  %f = phi [%a, then], [%b, else]
       … uses of %f …           ; drops of %f at scope end drop the arrived value
```

Two consequences the lowering must respect:

1. **Ownership transfers to the phi.** An affine value listed as a phi
   input is *not* destroyed at the end of its producing block; the scope
   ends *after* the join, and destruction targets the phi result. This is
   how `let f = if (c) { open_a() } else { open_b() };` destroys exactly
   the branch that executed.
2. **An affine phi result is destroyed at most once.** The frontend places
   the `drop` after the last use of the phi result (§6.4), never in the
   branch blocks.

Stilla source has no loop-carried mutable state and no loop construct
(Core §13.5); the only loops in the IR are produced by tail call
optimization (§10.9), whose header phis carry the reused parameters and
are duplicable and free of ownership concerns.

### 6.4 Destruction placement

Destruction is deterministic (Runtime §6) and materialized by the lowering
pass (frontend.md §5.4). The placement rules:

- **Scope-end destruction.** Every live affine `owned` local is destroyed
  when its scope ends during normal control flow (Core §9.5, Runtime
  §6.1): `drop` ops are inserted at the exit of every block that
  terminates a scope — every `if`/`match` branch, the `for` body
  back-edge, and the function epilogue — in **reverse creation order**.
- **Join locals.** A local created by an `if`/`match` expression is a phi
  result (§6.3); its `drop` goes at the end of the *enclosing* scope.
- **Affine temporaries.** A temporary surviving to the end of its full
  expression is destroyed in **reverse creation order** (Runtime §6.4):
  the builder keeps a per-expression temporary stack and emits its `drop`s
  at the expression's end. `consume(open_file("f"))` moves the temporary
  into the call and destroys nothing; `open_file("f");` as a statement
  drops it.
- **Explicit `drop`.** Source `drop name;` (Core §9.4) is one `drop`
  instruction at that point in control flow.
- **Conditional destruction.** A maybe-affine binding (Core §10.10) —
  released on some but not all paths through a conditional construct — is
  scheduled with a **cleanup token**. The lowering arms a token at the
  construct's entry (`%c: cleanup = cleanup_owner %v`, in the block that
  dominates every branch and the join); a path that consumes `%v` (moves,
  takes, transfers it) also disarms the token (`cleanup_disable %c`); the
  scope-end destruction is `drop_cleanup %c` — destroying the payload iff
  the token is still armed on the path that reached the scope exit. The
  per-path liveness lives in the token's armed bit (runtime state), not in
  an SSA value, so the maybe-affine value itself is never referenced after
  the construct's join and the destruction schedule is SSA-clean on every
  path.
- **Drop hooks.** `drop %v` where `v`'s struct defines a `drop` hook is a
  *single* instruction: the runtime executes the Runtime §6.2 sequence —
  hook call (fields still valid), then reverse-declaration-order field
  destruction, then the value is marked destroyed. The IR does not expand
  this; the ordering is a runtime contract (Runtime §6.2).
- **Trap paths.** `trap` performs no drops: panic and runtime traps skip
  all pending destruction (Core §18 *Panic and traps*, Runtime §7.1).
  Destruction is therefore always placed on edges that complete normally.

## 7. Memory model: module storage

The only memory in the IR is **module storage**: the statically laid-out
slots of the generated module struct (Core §2.1, Runtime §2.2). The
runtime lays out `IrModule.slots`; each slot has a static type from which
its ownership is known.

- `module_ref "spec"` — a static module value (Core §2.3). It is a
  constant usable in any function; module values are module-scope-only in
  source, but the IR may materialize them anywhere because they are
  statically known references.
- `load_member %m, #i` — read slot `#i` of module `%m`. User functions
  reference module constants and functions this way; chained library paths
  (`std.math.sqrt`, Core §2.7) lower to a chain of `load_member` ops.
- `store_member #i, %v` — write slot `#i` of the **current** module.
  Legal only inside that module's `@init` function; slot writes are
  immutable once `@init` completes (Core §5).

Each `IrModule` has an `@init` function (null for host modules, which have
no Stilla definitions to evaluate — frontend.md §5.5):

1. instantiate imported modules in dependency order (phase-1 topological
   order, Runtime §2.3) — the runtime does this from the module graph, so
   `@init` only needs `module_ref` for values that flow into slots;
2. evaluate module constants **strictly in declaration order** (Core §5,
   Runtime §5), `store_member`-ing each into its slot;
3. record slot metadata (`type_`, `init_order`) so the runtime can destroy
   module-owned affine constants in **reverse initialization order** during
   teardown (Runtime §2.5) without a separate teardown function.

## 8. Calls and system calls

### 8.1 `call`

```
%r = call %f, %a, %b        -- callee is a function value
%r = call @add, %a, %b      -- callee is a direct function reference
```

The callee is either a function value (a `load_member`d monomorphic
function, or a function-typed `arg`/const — monomorphic functions are
first-class, Core §12.4) or a direct reference to the function's `IrFunc`
(the common case). When the return type is `void` or `never`, the result
is omitted (`call @print, %s`).

Parameter modes are applied at the call site (Core §10.6):

- **plain** — the argument type must be duplicable; passed by value;
  coercions to `any` materialize as `copy` (§4.4);
- **borrow** — the argument is passed as a view; the caller's ownership is
  unchanged; the callee's `arg` value is `borrowed`;
- **move** — the argument's ownership transfers: an existing affine owner
  arrives as `%a' = move %a` (or directly when fresh, Core §10.5); the
  argument is dead after the call; duplicable `move` lowers to `copy`.

Return: `ret %v` transfers ownership of an affine result to the caller.
Borrowed returns are a phase-2 error (Core §10.7) and never reach the IR.

### 8.2 `syscall`

A call to a **host binding** — a member with a declaration and no Stilla
definition — lowers to `syscall`, never to `call`; a host binding has no
`IrFunc` and its body is never lowered (frontend.md §5.6). The target
dispatches on (module, member_index):

```
%n: int32  = syscall builtin#len, %values        -- builtin module member
%t: File   = syscall os#open_file, "a.txt"       -- host-provided module member
```

```
syscallTarget ::= module "#" member_name   -- text form
                | builtin                  -- shorthand for "builtin" module
```

In memory, `SysCallTarget` is `(module, member_index)` — stable because
module member layout is static (Core §2.1, Runtime §2.2). Argument
evaluation is identical to `call` (left to right, once, Runtime §5);
`move`/`borrow` modes apply (Core §10.6); generic builtins (`len`, `map`,
`fold`, `box`, `peek`, `unbox`) were specialized in phase 2, so the
syscall carries a concrete signature.

### 8.3 `never` returns

`builtin.panic` returns `never` (Runtime §4.9). Its call is always
followed by `trap`, and no destruction runs after it (Runtime §7.1):

```
    syscall builtin#panic, "boom"
    trap
```

## 9. Textual form

The text form is the canonical printable representation: used for IR
dumps, tests, and golden files. It is a debug format, not a persistence
format — the in-memory structures (§11) are authoritative. The printer may
omit types where inferable, omit `br` to the next block in layout
(fall-through, §3), and use symbolic names instead of `%N`. Constant
literals may appear inline wherever a value operand is expected (they are
`const` instructions in memory).

> Implemented by `src/cfg.zig`: `cfg.Parser` reads the text form into the
> §11 structures (with IR-native types, since the standalone parser has no
> dependency on the checker or module graph), and `cfg.print` serializes
> them back canonically — parse → print → parse round-trips exactly.

```
ir      ::= module*
module  ::= "module" string "{" func* "}"
func    ::= "func" "@" ident "(" params? ")" ("->" type)? "{" block+ "}"
params  ::= param ("," param)*
param   ::= ("borrow" | "move")? ident ":" type
block   ::= label ":" instr* terminator
label   ::= ident
instr   ::= value ":" type "=" op      -- defining
          | effect                     -- drop / store_member
op      ::= "const" literal
          | "arg" number
          | "module_ref" string
          | "fn_ref" "@" ident
          | ("neg" | "not" | "num_cast" | "any_pack_copy" | "any_pack_move"
             | "any_unpack_copy" | "any_unpack_move" | "cleanup_owner"
             | "copy" | "borrow" | "move") value
          | ("add"|"sub"|"mul"|"div"|"rem"|"concat"|"eq"|"ne"|"lt"|"le"|"gt"|"ge") value "," value
          | "type_is" value "," type
          | "load_member" value "," number
          | ("read_field"|"read_tuple") value "," number
          | "read_index" value "," value
          | ("tail" | "unpack_struct" | "unpack_tuple" | "split_list") value
          | "unpack_variant" value "," number
          | ("read_tag"|"read_payload") value
          | "construct" ("#" tag)? value ("," value)*
          | "call" ("@" ident | value) ("," value)*
          | "syscall" target ("," value)*
          | "phi" "[" value "," label "]" ("," "[" value "," label "]")*
effect  ::= "drop" value
          | "cleanup_disable" value
          | "drop_cleanup" value
          | "store_member" number "," value
```

The op spellings above are generated from the machine-readable op schema
(`cfg.opInfo`, §11): the parser's op-name map and the printer's op text
derive from the same table, so the grammar, the text form, and the
in-memory `Op` union cannot drift (ir.md §13).

## 10. Worked examples

Source snippets and their lowered IR. Arg values `%a`, `%b`, … are the
function's parameters in order.

### 10.1 Arithmetic

```stilla
fn add(a: int32, b: int32) -> int32 {
    a + b
}
```

```text
func @add(a: int32, b: int32) -> int32 {
entry:
    %r: int32 = add %a, %b
    ret %r
}
```

### 10.2 `if` expression with a join phi

```stilla
let sign =
    if (value >= 0) {
        1
    } else {
        -1
    };
```

```text
func @sign(value: int32) -> int32 {
entry:
    %z: int32 = const 0
    %c: bool  = ge %value, %z
    br %c ? pos : neg
pos:
    %one: int32 = const 1
    br join
neg:
    %mone: int32 = const -1
    br join
join:
    %sign: int32 = phi [%one, pos], [%mone, neg]
    ret %sign
}
```

### 10.3 Short-circuit `and`

`and`/`or` are control flow, not instructions (Runtime §5):

```stilla
if (a and b) { … }
```

```text
entry:
    %a1: bool = …                  ; evaluate a
    br %a1 ? rhs : false_
rhs:
    %b1: bool = …                  ; evaluate b, only when a is true
    br join
false_:
    %f: bool = const false
    br join
join:
    %r: bool = phi [%b1, rhs], [%f, false_]
    br %r ? then : done
```

### 10.4 `match` with a `switch`

```stilla
let message =
    match (result) {
        Result::Ok(value) => "ok: " + builtin.str(value),
        Result::Err(error) => "error: " + error
    };
```

(`Result::Ok(str) | Result::Err(str)`, tag indices 0 and 1.)

```text
func @msg(result: Result) -> str {
entry:
    %tag: u32 = read_tag %result
    switch %tag { #0 -> arm_ok, #1 -> arm_err }
arm_ok:
    %v: str   = read_payload %result        ; duplicable scrutinee: copy
    %s: str   = syscall builtin#str, %v
    %pre: str = const "ok: "
    %r1: str  = concat %pre, %s
    br join
arm_err:
    %e: str   = read_payload %result
    %pre2: str = const "error: "
    %r2: str  = concat %pre2, %e
    br join
join:
    %message: str = phi [%r1, arm_ok], [%r2, arm_err]
    ret %message
}
```

`_`, literal, tuple, struct, and list patterns lower to the same
primitives: `eq` + `br_cond` for literals, `read_*` projections and
discriminant tests for shapes, `tail`/`read_index` for `[head, ..tail]`
(Core §14). A `match (move value)` binds payloads with `unpack_variant` (tag-carrying) and
the scrutinee is wholly consumed (Core §13.4).

A `match` over an `any` value with **type-test** patterns does *not*
lower to a `switch`: the tag space is open (Core §11.6.2), so each arm
becomes a `type_is` test followed by a `br_cond` chain that falls through
to the next test, and the selected arm recovers the payload with an `any_unpack_copy`
(non-consuming match) or `any_unpack_move` (`match (move a)`,
Core §11.6.1, §14.7). A wildcard `_` arm is required because the tag
space is open (Core §11.6.2).

### 10.5 Ownership: borrow, move, drop

```stilla
fn inspect(borrow file: File) -> void { … }
fn consume(move file: File) -> void { … }

let a = open_file("a.txt");
inspect(a);
inspect(a);
consume(move a);
let b = open_file("b.txt");
consume(move b);
```

```text
func @main() -> void {
entry:
    %a: File = syscall os#open_file, "a.txt"
    call @inspect, %a                    ; borrow param: %a stays live
    call @inspect, %a
    %a2: File = move %a                  ; %a dead (Core §10.4)
    call @consume, %a2
    %b: File = syscall os#open_file, "b.txt"
    %b2: File = move %b
    call @consume, %b2
    ret void
}
```

An explicit `drop name;` (Core §9.4) is a single `drop` instruction.

### 10.6 Affine temporaries

```stilla
open_file("temporary.txt");
```

```text
    %t: File = syscall os#open_file, "temporary.txt"
    drop %t                          ; end of full expression (Runtime §6.4)
```

A `drop` of a struct with a user hook stays one instruction — the runtime
runs the hook, then reverse-declaration-order field destruction
(Runtime §6.2); the IR never expands it (§6.4).

### 10.7 `never` and traps

```stilla
let v = builtin.panic("boom");       -- never coerces to any type
```

```text
    syscall builtin#panic, "boom"
    trap
```

The `trap` block contributes no phi input (§4.3) and performs no drops
(Runtime §7.1).

### 10.8 Module init, syscalls, and cross-module calls

```stilla
// app.st
const greeting: str = "hello";
const calc = import("calc");
fn add(a: int32, b: int32) -> int32 { a + b }
```

```text
module "app" {
    func @init() -> void {
    entry:
        %g: str = const "hello"
        store_member #0, %g                  ; slot 0: greeting
        %c: module = module_ref "calc"
        store_member #1, %c                  ; slot 1: calc
        ret void
    }
    func @add(a: int32, b: int32) -> int32 {
    entry:
        %r: int32 = add %a, %b
        ret %r
    }
}
```

```stilla
// use.st
const app = import("app");
app.add(1, 2)
```

```text
module "use" {
    func @main() -> int32 {
    entry:
        %app: module = module_ref "app"
        %add: fn     = load_member %app, #1   ; slot 1: add (function value)
        %one: int32  = const 1
        %two: int32  = const 2
        %r: int32    = call %add, %one, %two
        ret %r
    }
}
```

The runtime instantiates `"calc"` before `"app"` and `"app"` before
`"use"` (phase-1 topological order, Runtime §2.3), each at most once
(Runtime §2.1).

### 10.9 Tail call optimization

Pass 7 (frontend.md §6) rewrites calls in tail position — a `call` whose
result is immediately `ret`ed, or a `void`/`never` call directly followed
by `ret` — into frame-reusing jumps. Only direct calls to a known `IrFunc`
are candidates; a call through a function *value* has no statically known
target. Before:

```stilla
fn countdown(n: int32) -> int32 {
    if (n == 0) { 0 } else { countdown(n - 1) }
}
```

```text
func @countdown(n: int32) -> int32 {
entry:
    %z: int32 = const 0
    %c: bool  = eq %n, %z
    br %c ? base : recur
base:
    ret %z
recur:
    %one: int32 = const 1
    %nm1: int32 = sub %n, %one
    %r: int32   = call @countdown, %nm1
    ret %r
}
```

After: the `call` + `ret` in `recur` becomes a `br` to a **loop header**,
with one phi per parameter merging the initial entry values with the
loop-back arguments, so the frame is reused and the recursion runs as a
loop. The entry block must have no predecessors (ir.md §13), so a
no-pred **trampoline** forwards to the header:

```text
func @countdown(n: int32) -> int32 {
entry:
    br header
header:
    %n1: int32 = phi [%n, entry], [%nm1, recur]
    %z: int32 = const 0
    %c: bool  = eq %n1, %z
    br %c ? base : recur
base:
    ret %z
recur:
    %one: int32 = const 1
    %nm1: int32 = sub %n1, %one
    br header
}
```

Every use of a raw parameter in the body is rewritten to its header phi
result, so the loop-carried value is genuinely SSA (`%n1` is defined in
`header`, which dominates the body) and the phi's loop-back incoming is
the fresh argument value. The rewrite is valid only when no live affine
value's destruction would be reordered (frontend.md §6, Pass 7.3): the
reused frame holds the parameter (now the phi result via the back-edge)
and the arguments, and everything else the caller owned is already
destroyed before the tail position, so the destruction schedule
(Runtime §6) is unchanged. The validator's edge-sensitive ownership
analysis checks each header phi's incoming against its arriving edge
(§13), so a move-mode parameter's loop-back is only accepted once an
ownership-aware loop phi is verifiable; the first release keeps
loop-carried affine parameters conservative.

### 10.10 Mid-level optimizer (folding + dead-block elimination)

Pass 8 (frontend.md §6) rewrites the lowered CFG with semantics-preserving
passes. Two examples. Constant folding replaces ops over constant operands
with their result:

```text
entry:
    %two: int32   = const 2
    %three: int32 = const 3
    %five: int32  = add %two, %three
    ret %five
```

becomes:

```text
entry:
    %five: int32 = const 5
    ret %five
```

Dead-block elimination removes blocks unreachable from the entry. In this
function the `else` arm of `if (n == 0)` never executes after `base`:

```text
func @abs(n: int32) -> int32 {
entry:
    %z: int32 = const 0
    %c: bool  = eq %n, %z
    br %c ? base : neg
base:
    ret %z
neg:
    %mone: int32 = const -1
    %neg: int32  = mul %mone, %n
    ret %neg
}
```

If the analysis proves `%n` is never zero on entry (e.g. after constant
propagation through a caller), `neg` becomes unreachable, and the pass
removes the block, its phi incoming (none here), and any now-unused
instructions:

```text
func @abs(n: int32) -> int32 {
entry:
    %z: int32 = const 0
    ret %z
}
```

Both rewrites preserve observable behavior (Runtime §5): folding changes
no side effect, and removing an unreachable block deletes no reachable
effect (its `drop`s and `syscall`s were unreachable too).

## 11. In-memory data structures
## 11. In-memory data structures

Zig declarations in `src/cfg.zig` (arena-owned; no node owns memory). The
IR is self-contained: it uses the IR-native resolved `Type` throughout
(the checker's `typeinfo` types are **not** consumed), and the op schema
below is the single machine-readable contract the parser, printer, and
validator share.

```zig
/// Ownership classification of a value type (Core §10.1–§10.3).
pub const Ownership = enum { duplicable, affine };

/// An IR-native resolved type (ir.md §4.2). Named struct/union
/// references defer ownership to their declaration (`null`).
pub const Type = union(enum) {
    primitive: ast.PrimitiveKind,   // int32 / uint32 / float32 / bool /
                                    // str / byte / any / hostdata / void / never
    named: []const u8,              // e.g. `File` or `os.File`
    module,                         // the type of module_ref values
    cleanup,                        // cleanup-token type (§6.4)
    list: *Type,
    box: *Type,
    tuple: []Type,
    function: FunctionType,
};

/// One SSA value: the result of exactly one instruction.
pub const Value = struct {
    id: u32,
    span: ast.Span,
    type_: Type,
    /// Ownership class from the type (duplicable / affine), `null` when
    /// deferred by a named type.
    ownership: ?Ownership,
    /// The created state (owned / borrowed, §6.1) — a definition-time
    /// property; availability is an edge-sensitive dataflow property.
    state: ValueState,
    /// The instruction that defines this value (null for parameters).
    def: ?*Instr,
};

pub const ValueState = enum { owned, borrowed };

/// One instruction: defines `results` (one value for single-result ops,
/// several for the atomic destructure ops `unpack_*` / `split_list`,
/// §5.3) unless it is a pure effect.
pub const Instr = struct {
    span: ast.Span,
    results: []*Value,
    op: Op,
};

/// The op set. Each op's metadata — canonical text spelling, value
/// arity, ownership effect, created state, may-trap, and side-effect
/// classification — is declared once in the machine-readable op schema
/// (`OpInfo` / `opInfo`); the parser's op-name map and the printer's op
/// text derive from it, and the validator checks arity, typing, and the
/// ownership dataflow against it.
pub const Op = union(enum) {
    // constants, parameters, modules (§5.1)
    const_: ConstValue,
    arg: u32,
    module_ref: []const u8,         // module specifier
    fn_ref: []const u8,             // qualified IrFunc name (§5.5)

    // unary and conversions (§5.2)
    neg: *Value,
    not_: *Value,
    num_cast: *Value,               // int32 <-> float32 only (Core §16.3)
    type_is: TypeIs,
    any_pack_copy: *Value,          // T -> any, duplicable source
    any_pack_move: *Value,          // T -> any, affine source (consumes)
    any_unpack_copy: *Value,        // any -> T, duplicable target
    any_unpack_move: *Value,        // (move any) -> T (consumes)

    // binary (§5.2)
    add: Bin, sub: Bin, mul: Bin, div: Bin, rem: Bin,
    concat: Bin,
    eq: Bin, ne: Bin, lt: Bin, le: Bin, gt: Bin, ge: Bin,

    // ownership (§5.4)
    copy: *Value,
    borrow: *Value,
    move_: *Value,
    drop_: *Value,                  // effect; no result
    cleanup_owner: *Value,          // creates a cleanup token (Type.cleanup)
    cleanup_disable: *Value,        // effect; disarms a token
    drop_cleanup: *Value,           // effect; conditional destruction

    // memory (§5.6)
    load_member: LoadMember,
    store_member: StoreMember,      // effect; @init only

    // aggregates and projections (§5.3)
    construct: Construct,           // n-ary
    read_field: Proj,
    read_tuple: Proj,
    read_index: Index,
    tail: *Value,                   // borrowed sublist view (§5.3)
    // atomic multi-result consuming destructures (§5.3)
    unpack_struct: *Value,
    unpack_tuple: *Value,
    unpack_variant: UnpackVariant,  // { base: *Value, tag: u32 }
    split_list: *Value,
    read_tag: *Value,
    read_payload: *Value,

    // calls (§8)
    call: Call,                     // n-ary
    syscall: SysCall,               // n-ary

    // SSA (§4.3)
    phi: Phi,                       // n-ary
};

pub const Bin = struct { a: *Value, b: *Value };
pub const Proj = struct { base: *Value, index: u32 };
pub const Index = struct { base: *Value, index: *Value };

/// The op schema row (ir.md §5, §13): the machine-readable contract.
pub const OpInfo = struct {
    text: []const u8,               // canonical spelling (§9)
    arity: Arity,                   // zero / one / two / nary (§4.2)
    consumes: Consumes,             // none / op0 / op1 / both / all
    created: Created,               // owned / borrowed / operand / none
    may_trap: bool,                 // Runtime §7.2
    effects: bool,                  // observable beyond the result
};

pub const ConstValue = union(enum) {
    int: i64,        // int32 / uint32 payload; sign per type
    float: f32,
    bool: bool,
    string: []const u8,
    void,
};

pub const Construct = struct {
    tag: ?u32,                       // union variant discriminant, else null
    args: []*Value,
};

pub const LoadMember = struct { module: *Value, slot: u32 };
pub const StoreMember = struct { slot: u32, value: *Value };
pub const TypeIs = struct { value: *Value, type_: Type };

pub const Call = struct {
    callee: union(enum) { direct: DirectCallee, value: *Value },
    args: []*Value,
};
pub const DirectCallee = struct { name: []const u8, func: ?*IrFunc };

pub const SysCallTarget = union(enum) {
    builtin: BuiltinId,
    host_module: struct { module: []const u8, member: []const u8 },
};
pub const SysCall = struct {
    span: ast.Span,
    target: SysCallTarget,
    args: []*Value,
    ret: Type,                       // `never` for panicking bindings
};

pub const Phi = struct {
    incoming: []PhiIn,               // one per in-edge, in `preds` order
};
pub const PhiIn = struct { value: *Value, pred: *BasicBlock };

pub const Terminator = union(enum) {
    ret: ?*Value,
    branch: *BasicBlock,
    branch_cond: struct { cond: *Value, then_: *BasicBlock, else_: *BasicBlock },
    switch: Switch,
    trap,
};
pub const Switch = struct {
    disc: *Value,                    // a read_tag result
    arms: []SwitchArm,               // tag -> block; implicit trap default
};
pub const SwitchArm = struct { tag: u32, block: *BasicBlock };

pub const BasicBlock = struct {
    id: u32,
    span: ast.Span,
    name: []const u8,                // text-form label
    instrs: []*Instr,
    terminator: Terminator,
    preds: []*BasicBlock,            // in-edges, in phi order
};

pub const Param = struct {
    span: ast.Span,
    name: ast.Ident,
    mode: ast.ParamMode,             // plain / borrow / move (Core §10.6)
    type_: Type,
};

pub const IrFunc = struct {
    id: u32,
    span: ast.Span,
    name: ast.Ident,
    params: []Param,
    ret: Type,
    entry: *BasicBlock,
    blocks: []*BasicBlock,
    values: []*Value,                // per-function value table, in order
    module_spec: ?[]const u8,        // set by the frontend lowering
};

pub const SlotMeta = struct {
    type_: Type,
    init_order: u32,                 // teardown destroys affine slots in
                                     // reverse rank (Runtime §2.5)
};

pub const IrModule = struct {
    span: ast.Span,
    name: []const u8,
    init: ?*IrFunc,                  // null for host modules
    funcs: []*IrFunc,
    slots: []SlotMeta,               // module storage layout (Runtime §2.2)
};

pub const IrProgram = struct {
    modules: []*IrModule,
    funcs: []*IrFunc,
    entry: ?*IrFunc,
};
```


## 12. Lowering rules (source → IR)

Phase 3 walks the annotated, monomorphic AST with a builder that appends
instructions to the current block and introduces blocks at control-flow
points (frontend.md §5.3). The mapping:

| source construct | IR |
| --- | --- |
| literal, `const` value | `const` |
| parameter | `arg` |
| module-valued const / import | `module_ref` |
| module member reference | `load_member` (chained for library paths) |
| binary arithmetic / comparison | one `add`…`ge` |
| `!` | `not` |
| `and` / `or` | `br_cond` diamond, join phi (§10.3) |
| `a as T` | `num_cast` (numeric pair) or `any_unpack_copy` / `any_unpack_move` (Core §16, §11.6.1) |
| coercion to `any` | `copy` (duplicable) or `move` (affine) at the boundary (§4.4) |
| `let name = expr` | evaluate `expr`, bind result as a fresh value |
| `let pattern = expr` | destructure: `read_*` views or the atomic `unpack_*` / `split_list` (§5.3, §6.2) |
| `if` | `br_cond` then/else, join phi; no `else` → `void` join |
| `match` (union) | `read_tag` + `switch`; per-arm payload binds; join phi (§10.4) |
| `match` (other patterns) | `eq`/`br_cond` chains, projections, `tail` |
| `match (move s)` | `unpack_variant` binds (tag-carrying); scrutinee wholly consumed (§13.4) |
| `move name` | `move` (or `copy` for duplicable); old value dead (Core §10.4, §10.6) |
| `drop name;` | `drop` (Core §9.4) |
| member access / index | `read_field` / `read_index` (bounds check traps) |
| call | `call` (direct or value); modes applied per §8.1 |
| host binding call | `syscall` (never `call`); `never` return → `trap` (§8.2–§8.3) |
| struct / variant / tuple / list literal | `construct` (written order, Core §8.1, §11) |
| `box` / `peek` / `unbox` | `syscall` (Runtime §4.7–§4.8) |
| module constants | `store_member` in `@init`, declaration order (§7) |

**Destruction placement** (§6.4) runs after the walk: for each scope that
ends normally, `drop` its live affine locals in reverse creation order;
append per-expression temporary drops at full-expression boundaries;
never on `trap` paths. The phase-2 ownership analysis has already proved
every affine value is destroyed exactly once — phase 3 only materializes
the schedule (frontend.md §5.4).

**Ordering guarantees.** Instruction emission order *is* evaluation order
(Runtime §5): callee before arguments, arguments left to right, base
before member/index, index after base, operands left to right, scrutinee
before arm selection, struct field initializers in written order,
tuple/list elements left to right. No reordering pass exists or is
permitted to reorder observable effects (Runtime §5 optimization clause).

**Optimizer contract.** The mid-level optimizer (frontend.md Passes 7–8)
is a *consumer* of the CFG: it rewrites instructions, blocks, and phis but
must keep the program satisfying the §13 invariants and unchanged
observable behavior (Runtime §5). Folding/propagation may replace an
instruction with a constant but never change a `div`/`rem` by zero into a
non-trap; dead-block elimination must fix up phi incoming lists and
predecessor sets; drop elision must not remove a user `drop` hook that
performs output; every optimized function must re-parse to the same CFG
shape.

## 13. IR validity invariants

These invariants are the contract the frontend and the standalone parser
must uphold. **Status:** fully enforced by the schema-driven validator
(`src/passes/cfg_validate.zig`, re-exported as `cfg.validate` / `lower.
validate`, frontend.md Pass 6.1). The frontend runs it on every lowered
program (`frontend.compile`); the mid-level optimizer runs it before the
pass sequence and after **every** rewrite (`cfg_optimize.zig`) — an
optimizer bug that violates structure, SSA, typing, or the ownership
dataflow is a compile-time diagnostic, not a runtime surprise. The
validator is schema-driven: arity and the static ownership/effect rules
come from `cfg.opInfo`, so the invariant set below and the op union
cannot drift. The check set:

**Structure**

- one entry block; entry has no predecessors; every block reachable;
- exactly one terminator per block, last instruction;
- `phi` only at block heads; one incoming per predecessor, in `preds`
  order; a `trap`-terminated predecessor contributes no phi input;
- arity: every op has its declared operand count (≤2 except the four
  n-ary forms); `Proj.index < field/element count` per the static type;
  `store_member` only in `@init`; `switch` arms exhaustive over the
  union's variants.

**SSA**

- each value defined exactly once; `Value.def` points to its instruction;
- non-phi uses dominated by their definitions (structured CFGs make this
  checkable in one pass);
- phi operands are defined in their named predecessor block.

**Ownership (edge-sensitive dataflow)**

- a `borrowed` value is never `move`'d, `drop`'d, `unpack_*`'d / `split_list`'d,
  stored, or returned; never passed to a move-mode parameter (Core §10.7);
- `copy`/`move`/`drop`/`unpack_*`/`split_list`/`any_pack_move`/
  `any_unpack_move`/phi/`ret` operands that are affine are `owned`
  (never `borrowed`, never already consumed in that instruction);
- a forward analysis over the CFG tracks each affine value as
  `Available` / `Consumed` / `MaybeConsumed` per program point, merging
  at joins (`Available ⊔ Consumed = MaybeConsumed`): a consuming op
  requires its operand *available*; a `MaybeConsumed` value has no uses
  at all (its destruction is scheduled through its cleanup token, §6.4);
  a phi input is checked against its **arriving edge's** exit state, so
  the loop-carried phis of tail-call optimization validate per edge;
- a destructure consumes its base atomically (`unpack_*` / `split_list`,
  ir.md §5.3): one op, base `Available` on arrival and `Consumed`
  afterwards — there is no partial-consumption state to track;
- `drop` of a duplicable value is absent (the frontend never emits it);
  `cleanup_disable` / `drop_cleanup` operands are cleanup tokens;
- borrow-mode `arg` is the only way a parameter arrives `borrowed`.

**Semantics**

- `div`/`rem` and `num_cast` operand types are numeric per Core §16.3;
  `num_cast` is the `int32 ↔ float32` pair only;
- not yet checked (the checker guarantees them at the source boundary,
  and the IR carries no callee signatures or union declarations):
  call-argument types against the callee's signature, syscall argument
  modes, and `switch` arm exhaustiveness over a union's variants;
- `read_index` bases are lists; `read_tag` bases are unions;
- no `ret` of a `borrowed` value.

## 14. Consumers and future work

Consumers of the CFG:

- **runtime interpreter/compiler** — executes `IrFunc` bodies; blocks,
  terminators, and explicit `drop`s make evaluation order and destruction
  unambiguous; module instantiation runs `@init` in topological order;
- **static analysis / mid-level optimizer** — the CFG is the base for a
  fixed sequence of semantics-preserving rewrites (frontend.md Passes 7–8):
  tail call optimization (§10.9), constant folding, common subexpression
  elimination, partial redundancy elimination, copy propagation,
  dead-block elimination, drop elision (a `drop` whose effect is provably
  unobservable may be removed — `drop_cleanup` / `cleanup_disable` act on
  a token whose payload is an affine owner and are never elided), and phi
  simplification. Runtime §5 permits
  optimization only when the observable behavior is unchanged; drop
  elision must not remove a user drop hook that performs output.

Non-goals: no register allocation, no instruction scheduling, no
cost-model-driven optimizer in this document. The mid-level optimizer
(frontend.md Passes 7–8) is a fixed, small set of CFG→CFG rewrites that
preserve observable behavior; tail call optimization (§10.9, frontend.md
Pass 7) is the first of them, the remainder (folding, propagation,
dead-block elimination, drop elision, phi simplification) is Pass 8.
`any`'s runtime representation (tagging) is a runtime concern; the IR only
requires that a value coerced to `any` carries its payload.

## 15. Relationship to frontend.md and the codebase

| frontend.md | ir.md |
| --- | --- |
| §5.1 IR model | §3, §4 |
| §5.2 `Value`/`Op`/`BasicBlock`/`Terminator`/`IrFunc` sketch | §5, §11 — superseded: instructions split into `Instr` (results + op), values carry `ValueState`, phis added, the atomic multi-result destructures documented |
| §5.3 lowering rules | §12 |
| §5.4 destruction placement | §6.4 |
| §5.5 module init | §7 |
| §5.6 syscalls | §8.2 |
| §5.7 outputs | §11 `IrProgram` |

Implementation target: `src/cfg.zig` (structures + op schema + text-form
parser and canonical printer) and `src/lower.zig` (annotated AST → CFG),
per the frontend.md §7 build table. The `src/typeinfo.zig` types are
**not** consumed by the IR: it uses IR-native `cfg.Type` throughout and
defines its own `cfg.Ownership`. The validity contract is enforced by
`src/passes/cfg_validate.zig` (§13), run by the frontend on every lowered
program and by the optimizer before and after every rewrite.
