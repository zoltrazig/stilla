# The typed LLIR lowering layer

*Part of the lowering-boundary overhaul (docs/frontend.md §The typed
lowering boundary, docs/optimizer.md §The LLIR lowering boundary).
Status: the typed layer
is wired into the emitter. `Builder.lowerLlir` runs `typed.compute` per
function (cfg_lower_llir.zig) and the body emitter routes every
arithmetic op through it: `emitArith` builds a `TypedOp` per op and the
§4 expander `emitBinArith` writes the record sequence, eliding the
leading `zext32` when the operand form makes it a no-op and folding
fuse-eligible constants into the immediate form without their staging
record. The record-level peepholes stay in llir_fusion.zig. The
pre-expansion typed-form CSE is not wired — `typedOps` / `printTyped`
are the inspection/test surface only.*

## 1. The boundary problem

The CFG → LLIR emitter reads a value's type only long enough to pick an
opcode and write its canonicalization records (`sext32` / `zext32`, the
mod-32 shift-count mask), then discards it. The record stream that
survives carries no type, no bit-width, and no notion of a value's
top-bits state. Because each logical op is expanded to its record
sequence at emit time, redundancy the compiler would most like to remove
(`sext32` of an already-sign-extended value, `zext32` of a
already-zero-extended one, one `add.i32` computed twice) is buried inside
a multi-record sequence.

The overhaul lowers through a **typed, context-rich intermediate layer**
that keeps type and value-form on every value, expands mechanically to
the widthless opcode stream, and eliminates the redundant
canonicalization records at expansion time. Redundancy elimination and
CSE on the small, un-expanded form remain aspirational (see §6); what is
landed is the form-aware residual elimination during expansion. The
opcode image — codes, encodings, serialization, validation, interpreter —
is unchanged; only how the records are *decided* changes.

## 2. The value-form (bits) lattice

Three monotone states describe what the top 32 bits of a value's 64-bit
canonical cell are known to be. `unknown` is the bottom; the two known
states are incomparable. The meet at a join is precise only when every
incoming value carries the same form — otherwise `unknown`.

| `form` | meaning (top 32 bits of the 64-bit cell) | produced by |
| --- | --- | --- |
| `sign_extended` | all equal to bit 31 (a canonical i32 cell) | `sext32`, a 32-bit `add`/`sub`/`mul`/`neg`/`div` result (its trailing `sext32`), an arithmetic `shr.i32` of a canonical cell, the C-type casts into `int32`/`uint32` (their cells are `extendInt32Bits`-canonical) |
| `zero_extended` | all zero | `zext32`, `andi`, aligned/typed loads of u32, constants in `[0, 2^32)` |
| `unknown` | anything else | all other producers; `phi`/`select`/call results unless all inputs agree |

The producer rules that make elimination sound:

- `sext32 x` where `x.form == .sign_extended` → identity.
- `zext32 x` where `x.form == .zero_extended` → identity.
- `sext32(sext32 x)` → `sext32 x`; `zext32(zext32 x)` → `zext32 x`.
- `sext32 x` where `x.form == .zero_extended` → **not** removable (bit 31
  may be set). `zext32 x` where `x.form == .sign_extended` → **not**
  removable.

The lattice is cheap (one forward sweep over the typed block list,
conservative at joins) and is the single source of truth for the
pseudo-stage eliminator (B.0); the expander's residual elimination (B.1)
reads the same forms.

## 3. The typed layer

`src/passes/cfg_lower_typed.zig` defines:

- `Form` — the lattice state (`sign_extended`, `zero_extended`,
  `unknown`).
- `meet(a, b)` — the lattice meet at a join.
- `TypedValue` — an SSA value plus its lattice form.
- `TypedOp` — one logical arithmetic/comparison/cast node: a `TypedKind`,
  the operand type, the result type (a `cast` result differs), the SSA
  operands, and the result value. Binary ops carry `a` and `b`; unary
  ops (`neg`/`abs`/`clz`/`popcount`) and `cvt` carry `a` only.
- `constForm(bits)` — the lattice form of a constant's stored cell.
- `classifyDef(ins, forms)` — the §2 producer classification for one
  defining instruction, reading operand forms for the
  operand-form-dependent cases (arithmetic `shr.i32`), conservative
  everywhere the plan does not name a known-form producer.
- `compute(allocator, func) -> []Form` — the fixpoint forward dataflow
  over a function's blocks, indexed by value id.

## 4. The typed-assembly printer (inspection/test surface)

`printTyped(allocator, func)` renders the typed layer one `%d: <type> =
<op> %a, %b` line per arithmetic/comparison/cast instruction. The op
spelling carries the type rep — `add.i32`, `mul.u32`, `div.i64`,
`shr.u32`, `cvt.i32.f32` — the typed form the widthless opcode stream is
expanded from. `typedOps(allocator, func)` returns the same Layer A list
as the printer's source, so the two stay in lockstep.

Both are **inspection/test surfaces**, not the production emitter input:
the emitter builds its `TypedOp`s inline in `emitArith`, and these two are
consumed only by `frontend_llir_typed_tests.zig` (the faithfulness test
against the §4 record count) and the module's own test block.

```
%3: int32 = add.i32 %1, %2
```

`frontend_llir_typed_tests.zig` checks that a compiled `int32` `add`
renders as `i32 = add.i32` and that its width model matches the §4 record
count (`budget.arithSeqCount` → two records: `add; sext32`).

## 5. The lowering table

Same semantics as the spec's canonical-cell sequences (`Stilla LLIR
Instruction Set.md` §4). The *choice* moves from the emitter into the
expander; the sequences below are what the typed ops expand to:

| typed operation | lowered records (with forms) |
| --- | --- |
| `add.i32` / `sub.i32` | `add` `@d, @a, @b`; `sext32 @d, @d` |
| `mul.i32` | `mul @d, @a, @b`; `sext32 @d, @d` |
| `neg.i32` | `neg @d, @a`; `sext32 @d, @d` |
| `div.u32` | `zext32 T15, @a`; `zext32 @d, @b`; `divu @d, T15, @d`; `sext32 @d, @d` |
| `div.i32` | `div @d, @a, @b`; `sext32 @d, @d` |
| `rem.u32` | `zext32 T15, @a`; `zext32 @d, @b`; `remu @d, T15, @d`; `sext32 @d, @d` |
| `shr.u32` | `andi T15, @b, 31`; `zext32 @d, @a`; `shru @d, @d, T15`; `sext32 @d, @d` |
| `shl.i32` | `andi T15, @b, 31`; `shl @d, @a, T15`; `sext32 @d, @d` |
| `bitand/bitor/bitxor` | `and`/`or`/`xor @d, @a, @b` — no canonicalization |
| `cvt.*.i32` / `cvt.*.u32` | the C-type cast; the cell is `extendInt32Bits`-canonical (sign-extended — a high result with bit 31 set must be zero-extended before a full-cell unsigned operation) |

Immediate fusion folds into the expansion for the typed ops where the
constant's type/bits are known in place; the multiply-accumulate peephole
stays a record-level peephole.

## 6. Migration status

The migration is staged:

1. **done** — value-form lattice and typed op/value types behind the
   existing emitter (no behavior change), verified by new unit tests.
2. **done** — the typed-assembly printer (`printTyped`), with a faithfulness
   test against the §4 record count.
3. **done** — the §4 table moved into the typed expander (B.1): the emitter
   builds a `TypedOp` per arithmetic op and `emitBinArith` (the expander)
   writes the §4 sequence. `cfg_lower_llir_budget.arithSeqCount` no longer
   hard-codes the shape; it derives the count from
   `cfg_lower_typed.arithSeqLen`, the expander's source of truth. The
   emitted records are byte-identical, and the budget/emitter lockstep
   contract holds by construction.
4. **done (leading-zext case)** — B.0's extension-identity rules are landed
   and tested (`sextIsIdentity`, `zextIsIdentity`, `elideLeadingZext`), and
   the leading-`zext32` residual elimination is **turned on**: the emitter
   drops the staging `zext32` of an unsigned 32-bit `div`/`rem`/`min`/`max`/
   `shr` when the operand is already zero-extended (a
   `bitand` with a low mask — the "andi-provenance" case — or a small u32
   constant), and the budget derives the reduced count via a form-aware
   `arithSeqCount`. A cast-produced dividend is **not** elided: the C-type
   casts into `int32`/`uint32` write `extendInt32Bits`-canonical
   (sign-extended) cells, so their form is `sign_extended` and the staging
   `zext32` stays — a high cast result (bit 31 set) must be zero-extended
   before the full-cell unsigned operation.
5. **done (arithmetic staging)** — step 6's immediate-fusion staging kill:
   the expander emits the immediate form for a 32-bit `div`/`rem`/`shl`/`shr`
   whose right operand is a fuse-eligible constant, and never writes the
   constant's `zext32`/`andi` staging record; `killSeqStaging` is deleted.
   The fused form reads the zero-extended staging register (`diviu dst,
   T15, imm`) rather than the raw operand, so a sign-extended unsigned cell
   still divides correctly; the fusion pass's use-count treats a pre-fused
   constant's use as folded (the expander records the instruction in
   `Builder.fused_instrs`), so a single-use constant is still dropped. The
   non-staged and 64-bit immediate fusion and the `le`/`ge` comparison
   `not`-kill (`killFusedCmpNot`) remain record-level peepholes.

The B.0/B.1 split (docs/optimizer.md §The LLIR lowering boundary) was
resolved as follows: the extension-vs-form elimination (drop a `zext32`
whose operand is already zero-extended, a `sext32` whose result is
already sign-extended) runs as the expander's residual step using the §2
value-forms — that is steps 4 and 5 above. The pre-expansion alternative
(CSE of duplicate typed ops, constant folding on the atomic form) is
**not wired**: the emitter consumes the form lattice but runs no CSE on
the un-expanded typed IR, and `typedOps` / `printTyped` remain the
inspection/test surface for what Layer A sees. The §3 residual
elimination table is that residual elimination.
