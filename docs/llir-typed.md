# The typed LLIR lowering layer

*Part of the lowering-boundary overhaul (docs/frontend.md §The typed
lowering boundary, docs/optimizer.md §The LLIR lowering boundary).
Status: the typed layer
is wired into the emitter. `Builder.lowerLlir` walks the function with
the body emitter: `emitArith` builds a `TypedOp` per arithmetic op
inline and writes exactly one record per instruction — the typed
opcode (`add.i32`/`shr.u64`/…) carries the full rep, computes at
that width, and self-canonicalizes its result cell (Instruction Set
§4). The record-level peepholes stay in llir_fusion.zig. The
pre-expansion typed-form CSE is not wired — `typedOps` / `printTyped`
are the inspection/test surface only.*

## 1. The boundary

The CFG → LLIR emitter reads a value's type to pick the typed opcode
(`add.i32`, `div.u64`, `shl.i32`, …) and nothing else. Each typed opcode
is **exactly one record** that computes at the named width and leaves
its result in the rep's canonical cell form. There are no
canonicalization records to elide, no staging register, and no
extension state to track — the canonical-cell contract is uniform
across every producer (a typed opcode, a cast, or a `const` all leave
their cell canonical), so nothing needs a lattice to stay sound.

Redundancy elimination and CSE on the atomic typed ops remain
aspirational (see §5); what is landed is the one-record emission
itself and the immediate-fusion decision it feeds.

## 2. The typed layer

`src/passes/cfg_lower_typed.zig` defines:

- `TypedOp` — one logical arithmetic/comparison/cast node: a
  `TypedKind`, the operand type, the result type (a `cast` result
  differs), the SSA operands, and the result value. Binary ops carry
  `a` and `b`; unary ops (`neg`/`abs`/`clz`/`popcount`) and `cvt`
  carry `a` only.
- `repOf(type)` — the rep suffix of an arithmetic primitive type, or
  null for a non-arithmetic type (the typed layer only carries
  arithmetic ops).
- `typedKindOf(tag)` — the `typed` lowering kind of a CFG op tag, or
  null for a tag that lowers to a direct opcode or a composite.
  Centralizes the tag → kind mapping for both the expander and the
  budget.
- `immOf(cv, kind, t)` — the 7-bit immediate a constant fuses into for
  a comparison kind, or null when it does not fit the window
  (`ge` normalizes to `gt` of the predecessor first).
- `shiftImm(op, t, imm)` — the pre-masked shift count an immediate
  shift opcode carries (the opcode masks the count mod the width
  internally; the immediate form just stores the masked value).
- `fusedImmR(kind, t, cv)` — the fused `(opcode, imm)` pair for an
  arithmetic kind whose constant fits the rep's immediate window, or
  null (the register form stays).

## 3. The typed-assembly printer (inspection/test surface)

`printTyped(allocator, func)` renders the typed layer one `%d: <type> =
<op> %a, %b` line per arithmetic/comparison/cast instruction. The op
spelling carries the type rep — `add.i32`, `mul.u32`, `div.i64`,
`shr.u32`, `cvt.i32.f32` — the same spelling the LLIR opcode
serializes to. `typedOps(allocator, func)` returns the same Layer A
list as the printer's source, so the two stay in lockstep.

Both are **inspection/test surfaces**, not the production emitter input:
the emitter builds its `TypedOp`s inline in `emitArith`, and these two are
consumed only by `frontend_llir_typed_tests.zig` (the one-record
faithfulness test) and the module's own test block.

```text
%3: int32 = add.i32 %1, %2
```

`frontend_llir_typed_tests.zig` checks that a compiled `int32` `add`
renders as `i32 = add.i32`, that its lowering is exactly one record —
the typed opcode itself, with no canonicalization records anywhere in
the image — and that the assembly printer serializes the same
spelling.

## 4. The lowering table

The typed opcode *is* the record. The spec's per-op semantics
(`Stilla LLIR Instruction Set.md` §4) live in the opcode, not in an
expansion:

| typed operation | lowered records |
| --- | --- |
| `add.i32` / `sub.i32` / `mul.i32` / `div.i32` / `rem.i32` / `min.i32` / `max.i32` | the one R-format record |
| every other typed integer rep (`*.u32`, `*.i64`, `*.u64`) | the one R-format record |
| `neg.i32` (and the other integer reps) | the one E-format record |
| `shl`/`shr` (any rep) | the one R-format record; the count masks mod the width inside the opcode |
| `bitand`/`bitor`/`bitxor` | `and`/`or`/`xor` — widthless, canonicality-preserving, no canonicalization needed |
| `cvt.*.i32` / `cvt.*.u32` | the C-type cast record; the cell is canonical by construction |

Immediate fusion folds into the same single record: a constant right
operand inside the rep's immediate window lowers as the immediate form
(`addi.i32`, `divi.u64`, …) instead of a `const` slot read. The
multiply-accumulate peephole stays a record-level peephole
(llir_fusion.zig).

## 5. Migration status

The migration is complete:

1. **done (v9)** — the typed op/value types behind the emitter and the
   typed-assembly printer.
2. **done (v10)** — the typed-integer opcode set: every integer
   arithmetic/shift op became a four-member typed family
   (`add.i32`/`add.u32`/`add.i64`/`add.u64`, …), `neg` a typed
   integer family, and the `sext32`/`zext32` canonicalization opcodes
   were removed (their E-type codes are reserved). The value-form
   lattice, the staging-register sequences, and the budget's
   sequence-shape derivation (`arithSeqCount`,
   `fusedStagingReduction`) were deleted with them — one arithmetic
   instruction is one record, and the budget counts records the
   emitter writes directly.
3. **not wired** — pre-expansion CSE of duplicate typed ops and
   constant folding on the atomic form; `typedOps` / `printTyped`
   remain the inspection/test surface for what Layer A sees.
