# Stilla LLIR Instruction Set

> **Version:** v1.3 Draft (v10 encoding)
>
> This document is the **canonical, standalone
> definition of the instruction set** — the 32-bit (4-byte) fixed-width
> encoding in six formats (R / B / I / C / E / U), the register model
> (F frame registers, the `zero`/`ra`/`cond` specials, and the T volatile
> temporaries), the complete opcode tables with per-opcode logical values,
> encoded selectors, operand schemas, and trap behavior, and the descriptor
> and side-table records instruction operands reference. It is normative for
> a LLIR backend and interpreter; it does not define a stable on-disk format.
> `src/llir.zig` is the executable mirror of these tables — its logical
> `Opcode` enum and the shared `encode`/`decode` mapping are exhaustive over
> the opcode set, so the code and this document must be updated together.
>
> In the **v10** encoding (the instruction-encoding half of the binary
> format — the artifact format is module-local since version 15; the
> header carries the module symbol and the symbolic entry member), the numeric semantics of
> every operation are written into the logical opcode at CFG → LLIR lowering
> time, so the serialized instruction record carries its own
> numeric semantics — loading decodes each record once into the VM's fixed
> 8-byte instruction image (§12.1, `vm_instr.zig`) and constructs no per-PC
> execution plan beyond that 1:1 decode. Float families carry the width in the
> opcode (`add.f32`/`add.f64`); integer families are widthless — they
> compute on the full 64-bit canonical cell, and where a 32-bit source
> type demands modulo-2³² semantics the lowering emits explicit
> canonicalization records around the widthless opcode (§4).

## Table of Contents

1. [Scope](#1-scope)
2. [Instruction encoding](#2-instruction-encoding)
3. [Operand registers and the special registers](#3-operand-registers-and-the-special-registers)
4. [Opcode tables: R-type](#4-opcode-tables-r-type)
5. [Opcode tables: B-type](#5-opcode-tables-b-type)
6. [Opcode tables: I-type](#6-opcode-tables-i-type)
7. [Opcode tables: C-type](#7-opcode-tables-c-type)
8. [Opcode tables: E-type](#8-opcode-tables-e-type)
9. [Opcode tables: U-type](#9-opcode-tables-u-type)
10. [Immediate operands and fusion windows](#10-immediate-operands-and-fusion-windows)
11. [Control flow, branches, and jumps](#11-control-flow-branches-and-jumps)
12. [Descriptor records](#12-descriptor-records)
13. [Side-table records](#13-side-table-records)
14. [Validation](#14-validation)
15. [Non-goals](#15-non-goals)
16. [Golden words](#16-golden-words)

---

# 1. Scope

LLIR is a read-only backend projection of a validated, optimized, and
post-drop-lowering CFG ([Stilla LLIR Specification](Stilla%20LLIR%20Specification.md));
its contract lives there. This document defines the instruction set that
projection emits: instruction shape (§2), operand register naming (§3),
opcode meaning and encoding (§4–§9), immediate ranges (§10), branch reach
and long-branch expansion (§11), and the records operand IDs resolve to
(§12–§13). It is the canonical home of the opcode tables; the parent
specification does not duplicate them.

The instruction set is **format-based, not dispatch-based**: opcodes are
classified by format (R/B/I/C/E/U, §2) and by semantic category within a
format, and the set defines **no fast/slow instruction classes**. Dispatch
shape — a plain switch, a split switch, direct threading, or a predecoded
execution cache — is a VM concern. The encoded LLIR remains self-describing,
and every dispatch strategy must have identical observable behavior to
decoding each instruction directly.

The defining v10 property is **self-describing numeric opcodes**: the numeric semantics of
every polymorphic operation ride in the logical opcode, not in a
load-time-resolved side channel. Each typed family (§4, §5, §7, §8) fixes
its operand representation in the opcode name. The **float families** are
rep-carrying: an `f32`/`f64` suffix fixes the width (`add.f64`,
`seq.f32`). The **integer families are widthless**: one opcode (`add`,
`mul`, `andi`, …) serves every integer width, computing on the full
64-bit canonical cell; where the operation differs by signedness the
family splits into signed and unsigned mnemonics (`div`/`divu`,
`shr`/`shru`, `min`/`minu`). A 32-bit source type never selects a
narrower opcode — the lowering wraps and canonicalizes through the
explicit `sext32`/`zext32` records of §4 instead. Comparison and branch
opcodes likewise distinguish only signed from unsigned ordering: canonical
cells have already normalized 32-bit integers to 64 bits. The decoder and interpreter read everything they need
from the decoded opcode. An implementation may cache that decoding, but the
cache must derive only from the encoded LLIR and must not change its meaning.

Instruction semantics that belong to the execution model — frame layout,
the call/ret/tailcall transfer contract, control-flow/trap behavior, VM
registers, module instantiation — are defined in the parent specification
and the Runtime specification, and are referenced here only where an
opcode's schema depends on them.

# 2. Instruction encoding

Every instruction is exactly 32 bits (4 bytes). Serialized words use
little-endian byte order. All bit layouts below are written MSB-first
(bit 31 on the left, bit 0 on the right); an implementation must never
bitcast host-endian structs over the record — the only access paths are the
`encode`/`decode` helpers and explicit little-endian read/write of the 4
canonical bytes.

**The logical opcode and the encoded selector are different objects.** The
logical opcode is a member of `Opcode = enum(u16)` — the complete,
alignment-constrained set of §4–§9. The encoded selector is the per-format
code field a word actually carries (9 bits in R, 6 in B/I/C/E, 5 in U).
`encode` maps a logical opcode to its `(format, code)` pair through the
single `opInfo` table; `decode` maps a word back. Neither direction
recomputes the mapping; the table is the one source of truth, and every
assigned opcode has exactly one encoding (`decode(encode(op)) == op`).
The one exception to pure `(format, code)` addressing is U-type prefix
`11101`, whose two jump members split on the register field: `ra`
selects `jal`, the `zero` encoding (`0x00`) selects the intra-function
`j` (§9.1).
**No encoded selector is an `enum(u16)` value**: the logical enum and the
encoded selectors are disjoint spaces that only `opInfo` connects.

## 2.1 Top-level classification

The top two bits classify every word; there is no fallback format:

| top 2 bits | class | further decoding |
| --- | --- | --- |
| `00` | R-type | `code(9) \| a(7) \| b(7) \| c(7)` (§4) |
| `01` | B-type | `code(6) \| lhs(7) \| rhs_or_imm7(7) \| offs10` (§5) |
| `10` | **reserved class** | every word with top bits `10` is rejected |
| `11` | other | `110` → I-type; `111000` → C-type; `111001` → E-type; `11101`/`11110`/`11111` → the three U-type prefixes — `11101` resolves to `jal`/`j` by its register field (§6–§9) |

Within `11`, decoding proceeds in order: the 3-bit prefix `110` selects
I-type; the 6-bit prefixes `111000`/`111001` select C-type/E-type; the
5-bit prefixes `11101`/`11110`/`11111` select the U-type opcodes, where
prefix `11101` resolves its register field first — `ra` → `jal`,
`zero` (`0x00`) → `j`, any other value rejected (§9.1). The
prefixes are pairwise disjoint (the 5-bit U prefixes start with bit 27
clear for C/E and set for U, and `110` is the only 3-bit form), so an
ordered decoder produces exactly one format for every assigned opcode and
rejects everything else — including `10`-class words and the unassigned
code/reserved-field combinations of §14.

## 2.2 The six formats

```text
R-type: 00 | code(9) | a(7) | b(7) | c(7)        512 codes, 71 assigned
B-type: 01 | code(6) | lhs(7) | rhs_or_imm7(7) | offs10   64 codes, 20 assigned
I-type: 110 | code(6) | a(7) | imm16              64 codes, 32 assigned
C-type: 111000 | code(6) | reserved(6) = 0 | a(7) | b(7)  64 codes, 64 assigned
E-type: 111001 | code(6) | reserved(6) = 0 | a(7) | b(7)  64 codes, 37 assigned
U-type: op(5) | a(7) | imm20                      4 opcodes (11101 ×2 / 11110 / 11111)
```

U-type carries four opcodes under three prefixes: `auipc`/`lui` own
`11110`/`11111`, and prefix `11101` holds both jumps, split by the
register field (`ra` = `jal`, `zero` = `j`, §9.1). E-type keeps 37
opcodes across selectors `0–43` (with `1–3` and `13/15/17/19` retired);
selectors `44–63` are reserved (§8, §14).

The opcode tables' **Behavior** column is normative pseudocode over these
encoded fields. The surrounding family rules refine rep-dependent arithmetic,
ownership, trap, and control-flow details.

- **R**: `a` = destination register, `b` = source 1, `c` = source 2 or a
  7-bit immediate (§10). The exceptions carry other meanings per the table:
  the destructure pair (`unpack_variant`/`borrow_variant`) puts a
  `DestructureDescId` in `a`, `b` the base, `c` the tag — an immediate
  variant tag, **not** a register operand (its schema role is `imm`, so
  the loader never treats it as a register encoding) — with no
  destination register; `read_index`/`read_indexi` put the destination in
  `a`, the list in `b`, and the index (register or imm7) in `c`;
  `tail` leaves `c` zero (validated).
- **B**: `lhs` = compared/tested register, the middle field is `rhs` for
  the register-branch families (§5.1), `imm7` for the immediate-branch
  families (§5.2), and the bit index for `tbz`/`tbnz` (§5.3); `offs10` is a
  signed 10-bit pc-relative instruction offset (§11).
- **I**: `a` = the single register (destination for the loads, source for
  `store_member`/the destructures/`switch`/`jr`, base for `jalr`);
  `imm16 = a 16-bit value` (§6).
- **C**: `a` and `b` are 7-bit fields whose roles are fixed by the opcode:
  casts read `a = dst, b = src`; register comparisons read `a = lhs,
  b = rhs`; integer immediate comparisons read `a = lhs, b = imm7`.
  Every comparison writes the implicit `cond` register. The six reserved
  bits are validated to be zero.
- **E**: `a` and `b` are 7-bit register fields whose roles are fixed by the
  opcode (§8); the six reserved bits are validated to be zero.
- **U**: `a` is a 7-bit register field — the link for `jal` (only `ra`),
  the fixed `zero` for `j` (its no-link mark), the destination
  for `auipc`/`lui` (§9) — and `imm20` a signed 20-bit value.

**Operand bounds.** The 32-bit format bounds every inline operand: a
register operand is a frame register `F0–F108` (`0x13–0x7f`), `zero`
(`0x00`), `cond` (`0x01`), `ra` (`0x02`), or a global volatile temporary
`T0–T15` (`0x03–0x12`); no other register encoding exists (§3).
The `zero`/`cond`/`ra`/T encodings form one contiguous low block, so the
VM indexes them directly (one bounds check into the fast bank, §3.1.1).
A 7-bit immediate is bounded per opcode (§10); an I-type `imm16` is a
16-bit value or ID; an inline ID is a 7-bit dense index (`[0, 127]` —
`TypeId`, `MemberId`, `DestructureDescId`, tags — and a 16-bit dense index
in I-type: `ConstId`, `FunctionId`, `SymbolId`, `SyscallDescId`,
`ConstructDescId`, `SwitchDescId`, `DropDescId`, spill-cell and window
offsets, §6); the move-wide family's `imm16` is an unsigned 16-bit lane
value (§6, never an ID). A `jal` target is a signed 20-bit offset from the
instruction's own `pc` (§11 — reach ±2¹⁹ at instruction granularity), a
B-type branch target a signed 10-bit offset (reach ±512), a `switch` arm
target a signed 32-bit offset from the `switch` instruction's own `pc`
(§12 — added modulo 2³², so every `u32` target is reachable), a `jr` target a
signed 16-bit offset from its base register, and an `auipc` displacement a
signed 20-bit immediate shifted left 12 (reach ±2³¹). Code size is not
otherwise capped by the fields: a B-type branch whose target lies beyond
±512 is expanded by the lowering (§11.1, long-branch expansion); a `jal`
whose offset exceeds the signed 20-bit field is rejected by the compiler
(`error.ProgramTooLarge`) rather than truncated.

- All serializable records and IDs use fixed-width integers; every ID and
  index is unsigned, and the one signed record field is `SwitchArm.target`
  (a signed pc-relative offset, §12). Frame
  payload sentinels are `invalid_pc` = `0xffffffff` (the root frame's saved frame base
  and return address), and `vm_internal_pc` = `0xfffffffe` (a VM continuation return; executable
  PCs must be lower). Side-table sentinels are `no_index` =
  `0xffffffff` (a missing module init or drop hook), and `no_tag` = `0xffffffff`
  (the union-construction discriminant sentinel of `ConstructDesc`, §12).
  `zero` (`0x00`) is an ordinary operand value, not a sentinel.
- `entry_pc` and the header's saved return address remain absolute
  instruction indexes into the program's global instruction array — never
  byte offsets or host pointers. `switch` arm targets are the one
  exception: they are **signed offsets relative to the `switch`
  instruction's own `pc`** (the decoded target is `pc +% arm.target`,
  §11). They are pc-relative like `jal`/B-type branches, but use modular
  addition to cover the full `u32` index space ([Stilla LLIR
  Specification](Stilla%20LLIR%20Specification.md)).

# 3. Operand registers and the special registers

## 3.1 The register model

A register operand is one of exactly 128 encodings:

| Range | Register | Semantics |
| --- | --- | --- |
| `0x00` | `zero` | special register with a **dual role**: reading it produces the all-zero bit pattern for the scalar type its instruction's rep/contract requires; writing it discards the result (one encoding, role-dependent meaning, RISC-V `x0` style). Writing `zero` performs no retain, release, or ownership transfer; the frontend only ever writes Copy/void results to `zero` — a trusted semantic invariant, not a loader check |
| `0x01` | `cond` | the single condition register: the block-local short-lived destination of the C-type comparisons (and `not`/`copy` may read/write it). The next instruction that writes `cond`, any call, or any block boundary must find it already consumed; `cmov`/`copy` may read it later in the same block. Not a frame register; no stack address |
| `0x01` | `cond` | the single condition register: the block-local short-lived destination of the C-type comparisons (and `not`/`copy` may read/write it). The next instruction that writes `cond`, any call, or any block boundary must find it already consumed; `cmov`/`copy` may read it later in the same block. Not a frame register; no stack address |
| `0x02` | `ra` | the fixed link register. Only `jal`'s explicit link destination, `jalr`'s implicit link destination, and the return path may touch it; the structural validator rejects every other read or write. On a call, `ra` first receives `current_pc + 1`; nested calls may overwrite it, so the incoming link is saved in the frame header ([LLIR Specification](Stilla%20LLIR%20Specification.md) §5) and restored at return. It is a **reserved hole** inside the fast bank: call-convention-only, never a scratch cell — the link lives in the frame header, so its bank cell stays dead (reads never reach it; writes are discarded) |
| `0x03–0x12` | **T0–T15 (16 global volatile temporaries)** | the VM's single bank of volatile execution storage, shared across frames and functions; caller-saved — every `jal ra`, `jalr`, or non-self tailcall logically clobbers all of it; not in the frame, not counted against the frame budget, no persistent slot type (§3.1.1) |
| `0x13–0x7f` | **F0–F108 (109 frame registers)** | `stack[fp + (n - 0x13)]`; parameters, long-lived values, spills, the call convention; cells are raw `u64` values — no inline representation tag, no fixed-width payload field — the exact value type of every operand rides in the opcode — a float family's rep or an integer family's signedness and canonicalization sequence — or the descriptor-carried types (§12–§13), never in the cell |

Constants (frozen with this document; `src/llir.zig` mirrors them):

| Constant | Value |
| --- | --- |
| `frame_count_max` | `109` (frame register count) |
| `zero_reg` / `cond_reg` / `ra_reg` | `0x00` / `0x01` / `0x02` (the fast-bank hole) |
| `temp_base` / `temp_count` | `0x03` (T0) / `16` (T0–T15) |
| `frame_base` / `fast_reg_count` | `0x13` (F0) / `0x13` (the `[0, frame_base)` bank) |

Decode helpers (the frame-relative index is `r - frame_base`, and the
`zero`/`cond`/`ra`/T block `[0, frame_base)` indexes the VM's fast bank
directly):

```zig
pub fn isFrame(r: u8) bool   { return r >= 0x13 and r < 0x80; }         // F0..F108 → stack[fp + (r - 0x13)]
pub fn isTemp(r: u8) bool    { return r >= 0x03 and r <= 0x12; }        // T0..T15
pub fn tempIndex(r: u8) u8   { return r - 0x03; }
pub fn isSpecial(r: u8) bool { return r == 0x00 or r == 0x01 or r == 0x02; } // zero/cond/ra
```

The specials' meaning is carried by their encoding and the operand
position, never by the cell: a decode that sees `zero` in a source field
supplies the type's zero; a decode that sees `zero` in a destination field
drops the result; `ra` and `cond` are position-restricted per §3.2.

**F and T are both ordinary operands**: arithmetic, memory, effect, and
control instructions do not distinguish their origin (`add T0, F2, F3`
and `add F4, T0, T1` are both legal); only the specials' placement
rules (§3.2) restrict a register. Side tables hold `ValueReg = u8` and may
name F or T (`destructure_dsts` rows); the `slot_*` sources are always F
cells — arguments home to the caller's output window and T does not
participate in the parameter ABI.

### 3.1.1 The fast bank and the T bank

- **Interpreter state.** The encodings `0x00–0x12` (`zero`, `cond`,
  `ra`, T0–T15) form one directly-indexed **fast bank**:
  `fast_regs: [19]Value` with `zero` at index 0 (kept permanently
  all-zero — writes to `zero` drop), `cond` at index 1, `ra` at index 2
  (a reserved call-convention hole — never a scratch cell, so its bank
  cell stays dead), and T0–T15 at indexes 3–18. A register read below
  `frame_base` is one bounds check and one indexed load; no
  subtraction or second test is needed. The bank is global to the VM and
  shared across frames; it is not part of any frame. The VM keeps a
  cached `frame = stack.ptr + fp`, refreshed at every call/ret/tailcall.
  (For the frame registers the fast path is `stack[fp + (r - 0x13)]` —
  the `- 0x13` folds into the addressing mode.)
- **Clobber semantics.** Every `jal ra`/`jalr` (and every non-self
  tailcall) logically clobbers all of T0–T15. The runtime clears nothing —
  "clobber" is a compile-time invariant: no T value read after a call may
  have been live before it. The callee immediately owns all 16 temporaries;
  recursion needs no special handling; there is no per-call save/restore.
  The allocator may therefore use the full T0–T15 range, but no T value
  may be live across a call, passed as an argument, returned, or held.
- **T15 is the 32-bit staging cell.** The 32-bit arithmetic sequences of
  §4 stage a masked count or a zero-extended operand through `T15`
  (`andi T15, count, 31`; `zext32 T15, src`). The register allocator
  therefore never assigns `T15` as a spill sentinel, and the staging
  reference is always unambiguous. Every staging read happens within the
  same block as its write, so the cell never crosses a call.
- **Parameter ABI unchanged.** Parameters home to the caller's output
  window — the callee's `F0..F(P-1)`, the same physical cells, zero copy.
  Calls only switch frames; T is never used to stage arguments. In v10 the
  window cells are also register-addressable: the caller's header reserve
  and output aliases (`O(0)..O(O-1)`) are the top `3 + O` encodings of the
  frame register range (`0x13–0x7f`), and a non-void call's result is
  published into
  the caller register `F(L+3+O-A)` and consumed by the generic `take`
  (§8). The `slot_*` argument writers and `spill_*` keep their imm16
  addressing unchanged.
- **`tailcall_self`** preserves `ra` and reuses the frame (§11.2): it keeps
  no T value, so tailcalls and ordinary calls share one liveness semantics.
- **Suspension.** The VM may suspend at any instruction and T may hold live
  values, so a snapshot is `{ pc, sp, fp, ctx, fast_regs }` plus the stack;
  the
  all 18 fast cells are saved.
- **No reference counting, no persistent exact type.** F/X/T cells carry no
  representation tag and no payload field — every cell is a raw `u64`. In
  v10 the exact type of every operand is fixed by the opcode — a float
  family's rep, an integer family's signedness, or its canonicalization
  sequence — or the descriptor-carried types; no load-time analysis is
  needed. T has no
  **implicit** teardown — the runtime never releases a T cell on its own
  account — but **explicit** lifecycle operations may name a T register:
  the spill expansion stages a spilled owner through T
  (`spill_take T, X; release T`), so a T cell can transiently hold a
  counted reference that an explicit record releases.

## 3.2 Special-register placement rules

- `zero` is read as the type's zero in a source position and discards in a
  destination position. The all-zero pattern is the canonical zero of every
  scalar type ([Runtime Specification](Stilla%20Runtime%20Specification.md)
  §7.2), so `zero` never carries its own type: the instruction's rep or
  operand contract supplies it. The resolution rules:
  - a float opcode's rep fixes the type outright, and an integer
    opcode's destination fixes the integer width: `add F0, F1, zero`,
    `seq zero, F1, F2` (a discarded comparison result), `ret zero`
    (a void or Copy zero return);
  - a real register source supplies the type where the opcode is not
    rep-carrying: `cmov` with one `zero` source, `bne Fx, zero` on a
    bool slot;
  - the schema-fixed positions are always legal: `not cond, cond`,
    `copy cond, zero` (bool), `bool_eq F0, zero` — bool has no width;
  - two `zero` operands never provide a type in a width-polymorphic
    position: `cmov F0, zero, zero` is rejected.
  - Only Copy/void results may be written to `zero`. Writing a Unique,
    borrowed, function, or aggregate result to `zero` is a trusted-invalid
    image (frontend invariant, not a loader check — the write would drop
    ownership).
- `ra` may name only: the explicit link destination of `jal` (`jal ra,
  addr`), and — as the canonical fixed token — the implicit link of
  `jalr ra, base, offs16`. Every other opcode reading or writing `ra` is
  rejected by the structural validator. `ret` never reads `ra`; the return
  path restores the saved link from the frame header.
- `cond` may name only the positions its opcode schema permits: the
  implicit destination of the C-type comparisons (there is no destination
  field), the destination/source of `not` and `copy`, and the implicit
  condition read of `cmov`. Every call makes `cond` unavailable: a callee
  does not inherit the caller's condition, and a `cmov`/`copy` reading
  `cond` after a call or block boundary is rejected (§14).
- `auipc`/`lui` destinations may be an F cell, a T register, or `zero` —
  never `ra` or `cond`.

## 3.3 Immediate interpretation

An `imm` operand is a statically known value — a field/element index, a
union tag, an inline table/descriptor ID, a spill-cell or window offset,
or (for the branches and `jal`/`jr`/`auipc`/`lui`) a target or constant —
never a register. The field width and interpretation are fixed per opcode
(§10); the opcode determines sign/zero extension for the integer
immediate families: the signed variants (`addi`, `subi`, `muli`, `divi`,
`remi`, `maddi`, `shri`) sign-extend the 7-bit field (exact range
`[-64, 63]`), the unsigned variants (`addiu`, `subiu`, `muliu`, `diviu`,
`remiu`, `maddiu`, `shriu`) zero-extend it (exact range `[0, 127]`); the
mask/count forms (`andi`/`ori`/`xori`/`shli`) always zero-extend.

# 4. Opcode tables: R-type

Every opcode with top bits `00` shares the layout
`code(9) | a(7) | b(7) | c(7)`. `a` is the destination (`zero` discards a
Copy/void result), `b` a source (`zero` reads the type's zero), and `c` a
second source or a 7-bit immediate, per the family. The 71 assigned
opcodes occupy codes `0–70`; codes `71–511` are reserved and rejected by
validation.

**Typed families.** Every family is a **contiguous run**: its members
occupy consecutive logical values and consecutive encoded selectors in
the order the family header lists them, so the first row of each table
anchors the group and the remaining members follow at +1 each. A float
family's members are `f32` then `f64`; a sign-agnostic operation is a
single widthless member computing on the full 64-bit canonical cell; an
operation that splits by signedness is a signed/unsigned pair, signed
first (`div` = logical 10, `divu` = 11). The logical values span `1–234`
but 7 retired E-type members leave holes, so 227 opcodes are defined —
by format: R `1–71`, B `72–91`, C `92–155`, E `156–199` (with
`157–159` and `169/171/173/175` retired), I `200–230`, U `231–234`
(sections below follow format class, so the numeric ranges interleave:
C-type §7 and E-type §8 precede I-type §6 in numeric order) — and every
format's encoded selectors are contiguous except the **reserved holes**:
R `0–70`, B `0–19`, C `0–63`, E `0–43` **with `1–3` and `13/15/17/19`
reserved** (the retired integer-`neg` members and the retired unsigned
`clz`/`popcount` members), I `0–30` **with selector 10 reserved** (the
former `result_take` slot, kept so the `slot_*` encodings never move; U
keeps `jal`/`j` sharing selector 0, `auipc` 1, `lui` 2). The v10 layout
has no inherited width slots; its alignment holes are the reserved
I-type selector 10 and the retired E-type codes `1–3`, `13`, `15`, `17`,
`19`. `repOf` reads a float member's rep from its `opInfo` row.

**The canonical-cell model and the 32-bit sequences.** Every integer
opcode computes at 64 bits and writes the raw 64-bit result; a 32-bit
source type's modulo-2³² semantics are the *lowering's* obligation,
discharged with two untyped E-type canonicalization opcodes (§8):
`sext32 dst, src` keeps the low 32 bits and sign-extends them (the
canonical cell of a signed 32-bit value), and `zext32 dst, src` keeps the
low 32 bits and zero-extends them (the operand form the full-cell
unsigned operations require). The lowering boundary emits exactly these
sequences: the CFG → LLIR expander (`cfg_lower_llir_emit.zig`) builds
each logical op as a typed node and expands it to the widthless stream,
and the record-sizer (`cfg_lower_llir_budget.zig`) derives the count from
the typed expander's own sequence length (`cfg_lower_typed.arithSeqLen`),
so the two stay in lockstep by construction. The operand value-form (the
top-bits state, `docs/llir-typed.md`) lets the expander elide a leading
`zext32` when the operand is already zero-extended. Every record's slots
shown as `dst`/`a`/`b` are the SSA slots:

| 32-bit operation | emitted sequence |
| --- | --- |
| `add`, `sub` | `add dst, a, b`; `sext32 dst, dst` |
| `mul` | `mul dst, a, b`; `sext32 dst, dst` |
| `neg` | `neg dst, a`; `sext32 dst, dst` |
| `bitand`, `bitor`, `bitxor` | `and`/`or`/`xor dst, a, b` — sign extension is preserved bit-for-bit, no canonicalization |
| `min`/`max` signed | `min`/`max dst, a, b` — the compare is order-correct on canonical cells |
| `min`/`max` unsigned | `zext32 T15, a`; `zext32 dst, b`; `minu`/`maxu dst, T15, dst`; `sext32 dst, dst` |
| `div` signed | `div dst, a, b`; `sext32 dst, dst` |
| `rem` signed | `rem dst, a, b` — the remainder of canonical cells is canonical, no truncation |
| `div`/`rem` unsigned | `zext32 T15, a`; `zext32 dst, b`; `divu`/`remu dst, T15, dst`; `sext32 dst, dst` |
| `shl` | `andi T15, b, 31`; `shl dst, a, T15`; `sext32 dst, dst` |
| `shr` signed | `andi T15, b, 31`; `shr dst, a, T15` — arithmetic shift of a canonical cell is canonical |
| `shr` unsigned | `andi T15, b, 31`; `zext32 dst, a`; `shru dst, dst, T15`; `sext32 dst, dst` |

The count mask reduces the count mod 32 because the widthless shift masks
mod 64; a fused immediate count is pre-reduced by the lowering instead
(§10). The immediate forms replace only the primary opcode record — the
canonicalization records stay, because the immediate forms compute at 64
bits too (a fused `addi` still wraps through its trailing `sext32`). For
the arithmetic expander's staged ops (`div`/`rem`/`shl`/`shr` on a 32-bit
type with a fuse-eligible constant), the constant's staging record
(`zext32 dst, b` / `andi T15, b, 31`) is **never emitted** (step 6) — the
immediate form reads the zero-extended staging register instead.

**Trap behavior is fixed by the opcode** ([Core Language
Specification](Stilla%20Core%20Language%20Specification.md), [Runtime
Specification](Stilla%20Runtime%20Specification.md)) — there is no program
arithmetic mode. The widthless integer opcodes wrap modulo 2⁶⁴ at every
step (WebAssembly semantics): `add`/`sub`/`mul` overflow wraps; the
multiply-accumulate family wraps at each step. A 32-bit operation's
modulo-2³² result is produced by its sequence's `sext32` — the wrap sits
in the instruction stream. `neg` is widthless too — two's complement
negation is sign-agnostic (bit-identical across signedness at the same
width), so a 32-bit negation emits `neg; sext32` like `add`/`sub`. The
rep-carrying unary `abs` is the one
exception: its integer rep is the entire 32-bit sequence, wrapping at
32 bits and self-canonicalizing in the single record (so `abs.i32` of the
minimum is the minimum, §8). `div`/`divu`/`rem`/
`remu` (and their immediate forms `divi`/`diviu`/`remi`/`remiu`, whose
zero immediate is a zero divisor) trap on a zero divisor, and the signed
`div` additionally traps on the 64-bit division-overflow case
`i64_min / -1`. A 32-bit `min-int / -1` does **not** trap: the 64-bit
quotient `0x8000_0000` is outside the canonical signed-32 range, and the
sequence's `sext32` wraps it back to the minimum — the modulo-2³²
WebAssembly result. `rem` never overflows (`i64_min % -1` is 0). The
float families follow IEEE 754 and never trap (`rem`'s zero divisor
included — `x % 0.0` is NaN). Casts never trap: an out-of-range integer
cast truncates to the target width (low-order bits), a float→int cast
truncates toward zero, saturating on NaN or out-of-range values (NaN
becomes zero).

#### R-type — typed binary/immediate and inline-ID families — 71 opcodes

**add** — widthless integer, then `f32, f64`

`a = b + c` (64-bit; a 32-bit result wraps through its sequence's `sext32`). Sign-agnostic — no `addu`: the low 32 bits are identical whether the operands are zero- or sign-extended.

| Opcode | Comment |
| --- | --- |
| `add` | widthless integer, sign-agnostic |
| `add.f32` | 32-bit float |
| `add.f64` | 64-bit double float |

**sub** — widthless integer, then `f32, f64`

`a = b - c` (64-bit). Sign-agnostic — no `subu`: the low 32 bits are identical whether the operands are zero- or sign-extended, so unsigned subtraction needs no staging.

| Opcode | Comment |
| --- | --- |
| `sub` | widthless integer, sign-agnostic |
| `sub.f32` | 32-bit float |
| `sub.f64` | 64-bit double float |

**mul** — widthless integer, then `f32, f64`

`a = b × c` (64-bit low half). Sign-agnostic — no `mulu`: the low 64 bits are identical whether the operands are zero- or sign-extended.

| Opcode | Comment |
| --- | --- |
| `mul` | widthless integer, sign-agnostic |
| `mul.f32` | 32-bit float |
| `mul.f64` | 64-bit double float |

**div** — signed/unsigned widthless pair, then `f32, f64`

`a = b / c` — the integer forms trap on a zero divisor, `div` additionally on `i64_min / -1`; the float forms never trap.

| Opcode | Comment |
| --- | --- |
| `div` | signed |
| `divu` | unsigned |
| `div.f32` | 32-bit float |
| `div.f64` | 64-bit double float |

**rem** — signed/unsigned widthless pair, then `f32, f64`

`a = b % c`, the sign of the dividend — the integer forms trap on a zero divisor (never on overflow); the float forms never trap.

| Opcode | Comment |
| --- | --- |
| `rem` | signed |
| `remu` | unsigned |
| `rem.f32` | 32-bit float |
| `rem.f64` | 64-bit double float |

**min** — signed/unsigned widthless pair, then `f32, f64`

`a = min(b, c)` signed 64-bit.

| Opcode | Comment |
| --- | --- |
| `min` | signed |
| `minu` | unsigned |
| `min.f32` | 32-bit float |
| `min.f64` | 64-bit double float |

**max** — signed/unsigned widthless pair, then `f32, f64`

`a = max(b, c)` signed 64-bit.

| Opcode | Comment |
| --- | --- |
| `max` | signed |
| `maxu` | unsigned |
| `max.f32` | 32-bit float |
| `max.f64` | 64-bit double float |

**addi** — signed/unsigned widthless pair

`a = b + imm7` (sign-extended, §10).

| Opcode | Comment |
| --- | --- |
| `addi` | signed imm7 |
| `addiu` | unsigned imm7 |

**subi** — signed/unsigned widthless pair

`a = b - imm7` (sign-extended).

| Opcode | Comment |
| --- | --- |
| `subi` | signed imm7 |
| `subiu` | unsigned imm7 |

**muli** — signed/unsigned widthless pair

`a = b × imm7` (sign-extended).

| Opcode | Comment |
| --- | --- |
| `muli` | signed imm7 |
| `muliu` | unsigned imm7 |

**divi** — signed/unsigned widthless pair

`a = b / imm7` signed; a zero immediate is a zero divisor (traps).

| Opcode | Comment |
| --- | --- |
| `divi` | signed imm7 |
| `diviu` | unsigned imm7 |

**remi** — signed/unsigned widthless pair

`a = b % imm7` signed; a zero immediate is a zero divisor (traps).

| Opcode | Comment |
| --- | --- |
| `remi` | signed imm7 |
| `remiu` | unsigned imm7 |

**shl** — widthless integer

`a = b << (c mod 64)` — left shift is sign-agnostic, one opcode serves every integer width.

| Opcode | Comment |
| --- | --- |
| `shl` | left shift, sign-agnostic |

**shr** — signed/unsigned widthless pair

`a = b >> (c mod 64)` arithmetic — sign-filling.

| Opcode | Comment |
| --- | --- |
| `shr` | arithmetic (sign-filling) |
| `shru` | logical (zero-filling) |

**shli** — widthless integer

`a = b << (imm7 mod 64)`.

| Opcode | Comment |
| --- | --- |
| `shli` | left shift by imm7 |

**shri** — signed/unsigned widthless pair

`a = b >> (imm7 mod 64)` arithmetic — sign-filling.

| Opcode | Comment |
| --- | --- |
| `shri` | arithmetic by imm7 |
| `shriu` | logical by imm7 |

**and** — widthless integer (bit patterns are sign-agnostic)

`a = b & c`.

| Opcode | Comment |
| --- | --- |
| `and` | bitwise AND, sign-agnostic |

**or** — widthless integer

`a = b | c`.

| Opcode | Comment |
| --- | --- |
| `or` | bitwise OR |

**xor** — widthless integer

`a = b ^ c`.

| Opcode | Comment |
| --- | --- |
| `xor` | bitwise XOR |

**andi** — widthless integer (always zero-extended, §10)

`a = b & imm7`.

| Opcode | Comment |
| --- | --- |
| `andi` | bitwise AND with imm7 |

**ori** — widthless integer

`a = b | imm7`.

| Opcode | Comment |
| --- | --- |
| `ori` | bitwise OR with imm7 |

**xori** — widthless integer

`a = b ^ imm7`.

| Opcode | Comment |
| --- | --- |
| `xori` | bitwise XOR with imm7 |

**madd** — widthless integer, then `f32, f64`

`a = a + b × c` (each step wraps at 64 bits).

| Opcode | Comment |
| --- | --- |
| `madd` | widthless integer, sign-agnostic |
| `madd.f32` | 32-bit float |
| `madd.f64` | 64-bit double float |

**msub** — widthless integer, then `f32, f64`

`a = a - b × c` (each step wraps at 64 bits).

| Opcode | Comment |
| --- | --- |
| `msub` | widthless integer, sign-agnostic |
| `msub.f32` | 32-bit float |
| `msub.f64` | 64-bit double float |

**maddi** — signed/unsigned widthless pair

`a = a + b × imm7` (sign-extended immediate).

| Opcode | Comment |
| --- | --- |
| `maddi` | signed imm7 |
| `maddiu` | unsigned imm7 |

**untyped**

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `load_member` | `a = member[c] of module b` | — | — |
| `read_field` | `a = field[c] of b` | — | — |
| `read_tuple` | `a = element[c] of b` | — | — |
| `read_payload` | `a = payload[c] of b` | — | — |
| `read_index` | `a = b[c]` | T | — |
| `read_indexi` | `a = b[imm7]` | T | — |
| `concat` | `a = b ++ c` | — | — |
| `tail` | Retain into `a` the list suffix after `b`'s first element; empty stays empty | — | — |
| `unpack_variant` | Consume `b` as variant `c` using descriptor `a` | — | — |
| `borrow_variant` | Borrow variant `c` of `b` using descriptor `a` | — | — |
| `type_is` | `a = (runtime tag of any b == TypeId c)` | — | — |
| `any_pack_copy` | Create `a = any(TypeId c, retained copy of b)` | — | — |
| `any_pack_move` | Create `a = any(TypeId c, moved b)`; `b` becomes dead | — | — |
| `any_unpack_copy` | Require tag `TypeId c`; retain the payload into `a` | T | — |
| `any_unpack_move` | Require tag `TypeId c`; move the payload into `a` and destroy `b`'s shell | T | — |
| `cmov` | `a = cond ? b : c` | — | — |

**The immediate families** read their 7-bit `c` field per opcode (§10):
the signed variants (`addi`/`subi`/`muli`/`divi`/`remi`/`maddi`/`shri`)
sign-extend; the unsigned variants (`addiu`/`subiu`/`muliu`/`diviu`/
`remiu`/`maddiu`/`shriu`) zero-extend; the shift counts (`shli`) and the
bitwise masks (`andi`/`ori`/`xori`) always zero-extend (`[0, 127]`, mask
semantics — `andi F0, F1, 0x7f` masks with `0x0000007f`, never
sign-extended). A constant outside the window is not fused — it
materializes through `const` (or the move-wide family for `u64` patterns)
and the register form is used (§10). **The float families have no
immediate forms**: every float constant materializes through `const`.

**All comparisons** use the C-type families in §7. Integer constants in the
7-bit immediate window use the C-type `slti`/`sgti`/`seqi`/`snei` families;
there are no R-type comparison forms. Integer `le`/`ge` have no opcodes:
the frontend synthesizes them as `not` of a strict comparison —
`a >= b ≡ !(a < b)`, `a <= b ≡ !(b < a)` (the register families are
`slt`-shaped, so the register form swaps the operands; the immediate
families have `sgti`/`sgtiu`, so `a <= k` is `not(sgti a, k)` with no
swap) — two instructions, the comparison followed by `not` writing the
result slot read-modify-write. The
`byte` ordering uses `sltu` (with `not(sltu)` for the `ge` form); equality uses `seq`/`sne`.

Integer comparison opcodes carry no width variant. Every 32-bit producer
stores its value as a canonical 64-bit cell (§4), so the comparison and
branch families select only signed or unsigned 64-bit ordering. The float
families retain their `f32`/`f64` variants.

**The inline-ID rows** carry 7-bit dense indexes (`[0, 127]`): `MemberId`
for `load_member`/`read_field`/`read_tuple`/`read_payload`, a register or
imm7 index for `read_index`/`read_indexi`, `DestructureDescId` in `a` for
`unpack_variant`/`borrow_variant`, and `TypeId` for `type_is`/`any_pack_*`/
`any_unpack_*`. An ID of 128 or more is a compile-time rejection
(`error.IdOutOfRange`) — v10 adds no wide-ID fallback. `tail`'s `c` is
validated zero. `cmov`
reads the implicit condition register.

# 5. Opcode tables: B-type

Every opcode with top bits `01` shares the layout
`code(6) | lhs(7) | rhs_or_imm7(7) | offs10`. The 20 assigned opcodes
occupy codes `0–19`; codes `20–63` are reserved and rejected. All B-type
opcodes are conditional transfers: they jump to
`pc + signExtend10(offs10)` when their condition holds and fall through to
`pc + 1` otherwise (reach `[-512, 511]`, §11). The B-type is an
independent format — it neither reinterprets nor shares R-type codes.

## 5.1 Register compare-and-branches

The 14 register branches are integer equality (`beq`/`bne`), signed
ordering (`blt`/`ble`), unsigned ordering (`bltu`/`bleu`), and the
`f32`/`f64` equality and ordering variants. `lhs` and the middle field are
compared registers (either may read `zero` — `bne Fx, zero` on a
bool slot is the general boolean test; `cond` is not a branch operand —
materialize a comparison result with `copy` before branching on it).
Every integer operand is already a canonical 64-bit cell: `blt`/`ble`
compare as signed `i64`, while `bltu`/`bleu` compare the same bits as
unsigned `u64`.
The float variants are IEEE ordered
comparisons with NaN semantics: `beq.f32` is false on NaN, `bne.f32` true,
`blt.f32`/`ble.f32` false on NaN. There is no `bgt`/`bge` family: the
greater relations are reached by an **operand swap** (`a > b` ≡ `blt b, a`,
`a >= b` ≡ `ble b, a`; unsigned `a >u b` ≡ `bltu b, a`, `a >=u b` ≡
`bleu b, a`), which preserves the NaN behavior of every predicate.

## 5.2 Immediate compare-and-branches

The immediate families are `blti`/`bltiu` and the equality `beqi`/`bnei` —
4 opcodes; **no float variants are generated**. There are no `le`/`ge`/
`gt` immediate mnemonics: an integer `>`, `>=`, or `<=` branch against a
constant falls back to the register form (§5.1) with the constant
materialized, or to the strict form — a constant on the left with `gt`
swaps to `blti` (`k > a` ≡ `a < k`), and a constant on the right with
`lt`/`eq`/`ne` uses `blti`/`beqi`/`bnei` directly.
The middle field is `imm7`: the signed `blti` sign-extends it (exact
range `[-64, 63]`); the unsigned `bltiu` zero-extends it (exact
range `[0, 127]`). The frontend selects an immediate branch when an integer condition's
constant operand is on the side that makes the comparison strict (or
against `eq`/`ne`) and fits the window; otherwise the register form
(§5.1) is used.

## 5.3 Bit-test branches

`tbz`/`tbnz`, 2 opcodes. `lhs` is the tested register; the middle field is
the bit index, accepted only in `[0, 63]` — the 7-bit field's high bit
must therefore be zero (validation rejects ≥ 64). `tbz lhs, bit, offs10`
branches when bit `bit` of `lhs`'s raw 64-bit cell is clear; `tbnz` when
set. `offs10` is a signed 10-bit pc-relative offset like the other
branches. Far-branch inversion pairs `tbz` with `tbnz` on the same
register and bit index (§11.1).

#### B-type — compare-and-branch, immediate-branch, and bit-test — 20 opcodes

**beq** — integers plus `f32, f64`

Branch by `offs10` when `lhs == rhs`.

| Opcode | Comment |
| --- | --- |
| `beq` | equal |
| `beq.f32` | equal, 32-bit float |
| `beq.f64` | equal, 64-bit double float |

**bne** — integers plus `f32, f64`

Branch by `offs10` when `lhs != rhs`.

| Opcode | Comment |
| --- | --- |
| `bne` | not equal |
| `bne.f32` | not equal, 32-bit float |
| `bne.f64` | not equal, 64-bit double float |

**blt / bltu** — widthless integers (`blt` signed, `bltu` unsigned) plus `f32, f64`

Branch by `offs10` when `lhs < rhs`.

| Opcode | Comment |
| --- | --- |
| `blt` | signed < |
| `bltu` | unsigned < |
| `blt.f32` | <, 32-bit float |
| `blt.f64` | <, 64-bit double float |

**ble / bleu** — widthless integers (`ble` signed, `bleu` unsigned) plus `f32, f64`

Branch by `offs10` when `lhs <= rhs`.

| Opcode | Comment |
| --- | --- |
| `ble` | signed ≤ |
| `bleu` | unsigned ≤ |
| `ble.f32` | ≤, 32-bit float |
| `ble.f64` | ≤, 64-bit double float |

**blti / bltiu** — widthless integers (`blti` signed, `bltiu` unsigned)

Branch by `offs10` when `lhs < imm7`.

| Opcode | Comment |
| --- | --- |
| `blti` | signed < imm7 |
| `bltiu` | unsigned < imm7 |

**beqi** — widthless integer

Branch by `offs10` when `lhs == imm7`.

| Opcode | Comment |
| --- | --- |
| `beqi` | == imm7 |

**bnei** — widthless integer

Branch by `offs10` when `lhs != imm7`.

| Opcode | Comment |
| --- | --- |
| `bnei` | != imm7 |

**untyped**

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `tbz` | Branch by `offs10` when bit `rhs_or_imm7` of raw `u64 lhs` is zero | — | — |
| `tbnz` | Branch by `offs10` when bit `rhs_or_imm7` of raw `u64 lhs` is nonzero | — | — |

# 6. Opcode tables: I-type

Every opcode with the 3-bit prefix `110` shares the layout
`code(6) | a(7) | imm16`. The 32 assigned opcodes occupy codes `0–31`;
codes `32–63` are reserved and rejected. `a` is the single register and
`imm16` a 16-bit value, ID, or offset.

#### I-type — register + imm16 — 31 opcodes

**References, constants, and syscalls**

`const`, `fn_ref`, `module_ref`, and `syscall` each write to `a` from a
16-bit ID: `const` reads `ConstId` (`zero` for a void constant),
`fn_ref` reads a module-local `FunctionId` (the function's relocated
`entry_pc`; a cross-module function value lowers to a `module_ref` plus a
`load_member` instead), `module_ref` reads a `SymbolId` (the module
symbol — the module's own or an imported one; `a` becomes the module
handle after the runtime has loaded and initialized the target), and
`syscall` calls the host descriptor `SyscallDescId` (whose binding is an
`ImportDesc` — a `(module_symbol, member_symbol)` host pair) and writes
its result to `a` (or discards it to `zero`). A host call may fail — the
trap is the host's, not a language trap.

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `const` | `a = constants[imm16]` | — | — |
| `fn_ref` | `a = functions[imm16].entry_pc` (module-local) | — | — |
| `module_ref` | `a` becomes the module handle for the module named by `SymbolId imm16` (loading and initializing it if needed) | — | — |
| `syscall` | Call host descriptor `imm16`; write result to `a` | T | — |

**Aggregates and destructures**

`construct` builds in `a` the aggregate and components named by
`ConstructDescId`; `store_member` writes the value source `a` to the
constant member `MemberId` (legal only inside a module `@init`). The
destructures consume the base source `a` and publish its parts via
`DestructureDescId`: `unpack_struct`/`unpack_tuple` (kind
`.struct`/`.tuple`) publish fields or elements, and `split_list` (kind
`.list`) publishes head/tail, trapping on a short list.

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `construct` | Create in `a` the aggregate and components named by `ConstructDescId imm16` | — | — |
| `store_member` | `member[imm16] = a` | — | — |
| `unpack_struct` | Consume `a` and publish fields via descriptor `imm16` | — | — |
| `unpack_tuple` | Consume `a` and publish elements via descriptor `imm16` | — | — |
| `split_list` | Consume `a` and publish heads/tail via descriptor `imm16` | T | — |

**Calls and dispatch**

`switch` dispatches on the tag register `a` (a `read_tag` result)
through `SwitchDescId`; each arm target is a signed offset from the
`switch` instruction's own `pc` (§11), so the decoded target is
`pc +% arm.target`, and an unmatched tag traps. Terminator.
`jalr` is the indirect call:
`a` is the base register (an F/T/zero source), `imm16` a signed 16-bit
offset, and `ra` the fixed implicit link destination — canonical
assembly writes `jalr ra, base, offs16`, the `ra` token required but
not encoded. The target `read(base) + signExtend16(offs16)` traps on
addition overflow, an out-of-range target, or a target that is not a
function entry; the record carries no `FunctionId` or `CallDescId` —
the function value is an executable entry PC that `enterCall` resolves
([LLIR Specification](Stilla%20LLIR%20Specification.md) §5).
Terminator.

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `switch` | Jump to the arm for tag `a` in descriptor `imm16` | T | T |
| `jalr` | `call(read(a) + signExtend16(imm16))` | T | T |

The I-type selector 10 is **reserved** — the slot the v9
`result_take` occupied. The v10 call-result transfer is the generic
`take` (§8), a plain register transfer: the non-void call's result is
published by the callee's `ret` into the caller register `F(L+3+O-A)`
([LLIR Specification](Stilla%20LLIR%20Specification.md) §5) and
consumed by exactly one `take dst, F(L+3+O-A)` at the fallthrough —
or, when the lowering coalesced the result onto the alias itself
(Step 8, direct calls only, result not live across another call), read
in place with no take. The
reserved selector keeps the `slot_*`/`spill_*` encodings fixed across
the v9 → v10 bump.

**Spill and slot transfer**

`spill_take` and `spill_put` shuttle a value between an X spill cell
and a T staging register: `spill_take` moves `X[imm16]` into the dead
destination `a` (a T register), leaving X uninitialized; `spill_put`
moves the live source `a` (a T register) into the dead cell
`X[imm16]`, leaving T dead. The `slot_*` rows establish the parameter
ABI from the F source `a` into the output-window cell at window
offset `imm16`: `slot_retain` writes `retain(F)` — establishing
the parameter owner; `slot_move` transfers the owned source (it becomes
uninitialized); `slot_borrow` installs a borrowed view valid for one
call; `slot_copy` bit-copies a plain value.

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `spill_take` | `a = move(X[imm16])` | — | — |
| `spill_put` | `X[imm16] = move(a)` | — | — |
| `slot_retain` | `window[imm16] = retain(a)` | — | — |
| `slot_move` | `window[imm16] = move(a)` | — | — |
| `slot_borrow` | `window[imm16] = borrow(a)` | — | — |
| `slot_copy` | `window[imm16] = a` | — | — |

**Jumps and destruction**

`jr` is the unconditional register-relative jump: `a` is the base
register (F or T; no special), `imm16` a signed 16-bit offset, and
`pc = base + signExtend16(imm16)` with no link. The computed target
must lie in the current function's code range — an out-of-range target
traps. The frontend never emits it (the language has no computed
jump); it exists for runtime/backend dispatch. Terminator. `drop`
destroys the F source `a` by its `DropDescId` — the residual dynamic
destruction ([LLIR Specification](Stilla%20LLIR%20Specification.md)
§6).

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `jr` | `pc = read(a) + signExtend16(imm16)` | T | T |
| `drop` | `destroy(a, DropDescId imm16)` | — | — |

**The move-wide family** (`movwn0`–`movwn3`, `movwz0`–`movwz3`,
`movwk0`–`movwk3`, 12 opcodes) constructs a 64-bit `u64` pattern directly
in a register in four 16-bit lanes — the ARM64 MOVN/MOVZ/MOVK pattern.
`a` is the destination (a real F or T register; no special); `imm16` is
the **unsigned** lane value `[0, 65535]` (the raw pattern, never
sign-extended). With `S = n * 16`, `H = zeroExtend64(imm16) << S`, and
`M = 0xffff << S`:

| Suffix | Lane | Shift `S` | Lane mask `M` |
| --- | --- | --- | --- |
| `0` | bits `15–0` | `0` | `0x000000000000ffff` |
| `1` | bits `31–16` | `16` | `0x00000000ffff0000` |
| `2` | bits `47–32` | `32` | `0x0000ffff00000000` |
| `3` | bits `63–48` | `48` | `0xffff000000000000` |

| Opcode | Semantics |
| --- | --- |
| `movwn0`…`movwn3` | `a = ~H` |
| `movwz0`…`movwz3` | `a = H` |
| `movwk0`…`movwk3` | `a = (a & ~M) \| H` |

All twelve are pure, total, non-trapping. `movwn*`/`movwz*` define a plain
`u64` pattern; `movwk*` reads the destination's old value and commits the
merged pattern in one step — it requires an initialized `u64` destination.
Move-wide creates or modifies only `u64` bit patterns: `i64`/`f64`
constants stay on the typed `const` path, and no reverse type inference is
introduced.

**movwn** — the move-wide family, lanes 0–3

`a = ~H`, `H = zeroExtend64(imm16) << S` — the not form (lane `S` per the lane table above).

| Opcode | Comment |
| --- | --- |
| `movwn0` | lane 0 |
| `movwn1` | lane 1 |
| `movwn2` | lane 2 |
| `movwn3` | lane 3 |

**movwz** — the move-wide family, lanes 0–3

`a = H`, `H = zeroExtend64(imm16) << S` — the zero form (lane `S` per the lane table above).

| Opcode | Comment |
| --- | --- |
| `movwz0` | lane 0 |
| `movwz1` | lane 1 |
| `movwz2` | lane 2 |
| `movwz3` | lane 3 |

**movwk** — the move-wide family, lanes 0–3

`a = (a & ~M) | H` — the keep form (lane `S` per the lane table above).

| Opcode | Comment |
| --- | --- |
| `movwk0` | lane 0 |
| `movwk1` | lane 1 |
| `movwk2` | lane 2 |
| `movwk3` | lane 3 |

The `movwn1`–`movwn3`, `movwz1`–`movwz3`, and `movwk1`–`movwk3` suffixes
use lanes 1–3 with the same semantics as their lane-0 anchor, per the
lane table above.

# 7. Opcode tables: C-type

Every opcode with the 6-bit prefix `111000` shares the layout
`code(6) | reserved(6) = 0 | a(7) | b(7)`. All 64 codes are
assigned (codes `0–63`). A
nonzero reserved field is rejected by validation. The two operand roles are
fixed by the opcode group: the 42 casts read `a = dst, b = src`; the 16
register comparisons read `a = lhs, b = rhs`; the 6 integer immediate
comparisons read `a = lhs, b = imm7`. Every comparison has an implicit
destination.

**The 42 casts** are the full `7 × 7` matrix over the cast types
`b, i32, u32, i64, u64, f32, f64` minus the seven identity entries:
`cvt.<src>.<dst>`. Casts are unary (`dst = op src`), never trap, and have
these semantics:
integer→integer truncates to the target width (low-order bits, zero- or
sign-extension as the rep demands; the same-width `i64 ↔ u64` forms
reinterpret the full 64-bit cell); int→float rounds to nearest (precision
may be lost — `i64 as f64`/`u64 as f64` round values beyond 2⁵³);
float→int truncates toward zero, saturating on NaN or
out-of-range values (NaN becomes zero), the 64-bit targets saturating to
`[i64_min, i64_max]` / `[0, 2⁶⁴)`; `f32 → f64` is exact; `f64 → f32`
rounds to nearest, ties-to-even; the `b` (byte) forms keep or produce the
low 8 bits.

**The 22 comparisons** include integer equality (`seq`/`sne`), signed and
unsigned less-than (`slt`/`sltu`), explicit float variants including
`sle.f32`/`sle.f64`, the immediate forms (`slti`/`sltiu`/`sgti`/`sgtiu`/
`seqi`/`snei`), plus `bool_eq`/`bool_ne` and
`str_eq`/`str_ne`.
They compare `lhs` and `rhs` and **unconditionally
overwrite `cond`**; the instruction carries no destination field. Signedness
is explicit in the mnemonic. Every integer operand is already a canonical
64-bit cell: `slt` compares as signed `i64`, while `sltu` compares the same
bits as unsigned `u64`. The `byte` ordering uses the unsigned form. The float variants keep IEEE ordered/NaN
semantics: `seq` false on NaN, `sne` true, `slt`/`sle` false on NaN.
`ge`/`gt` are operand-swap aliases: `sge lhs, rhs` ≡ `sle rhs, lhs` and
`sgt lhs, rhs` ≡ `slt rhs, lhs` (same rep — swap preserves the NaN
behavior of every predicate); `sge`/`sgt` occupy no logical opcode.
`sne lhs, rhs` ≡ `not(seq lhs, rhs)` (the `sne` opcode is the
single-instruction form of that identity).

The signed immediate ordering families are `slti`/`sgti`; the unsigned
families are `sltiu`/`sgtiu`; equality remains `seqi`/`snei`. Their `b`
field is an `imm7`: signed ordering and equality forms sign-extend it,
while unsigned ordering forms zero-extend it; `a` is the compared register. A constant
outside the window materializes in a register and uses the corresponding
register comparison.

**`cond` lifetime.** `cond` is a block-local, short-lived result: the next
instruction that writes `cond`, any call, or any block boundary must find
the previous value already consumed. Within the same block, a later
`cmov`/`copy` may read it across intervening instructions that do not
write `cond` — physical adjacency is not required. When a comparison
result must become an ordinary SSA value or live across a block, the
lowering emits `copy dst, cond` in the same block. All calls make `cond`
unavailable; a callee does not inherit the caller's condition.

#### C-type — casts and comparisons — 64 opcodes

**seq** — integers plus `f32, f64`

`cond = (a == b)`.

| Opcode | Comment |
| --- | --- |
| `seq` | equal |
| `seq.f32` | equal, 32-bit float |
| `seq.f64` | equal, 64-bit double float |

**sne** — integers plus `f32, f64`

`cond = (a != b)`.

| Opcode | Comment |
| --- | --- |
| `sne` | not equal |
| `sne.f32` | not equal, 32-bit float |
| `sne.f64` | not equal, 64-bit double float |

**slt / sltu** — widthless integers (`slt` signed, `sltu` unsigned) plus `f32, f64`

`cond = (a < b)`.

| Opcode | Comment |
| --- | --- |
| `slt` | signed < |
| `sltu` | unsigned < |
| `slt.f32` | <, 32-bit float |
| `slt.f64` | <, 64-bit double float |

**sle** — float `f32, f64` only

`cond = (a <= b)`.

| Opcode | Comment |
| --- | --- |
| `sle.f32` | ≤, 32-bit float |
| `sle.f64` | ≤, 64-bit double float |

**scalar equality**

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `bool_eq` | `cond = (a == b)` | — | — |
| `bool_ne` | `cond = (a != b)` | — | — |
| `str_eq` | `cond = (a == b)` | — | — |
| `str_ne` | `cond = (a != b)` | — | — |

**immediate comparisons**

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `slti` | `cond = (a < imm7)` | — | — |
| `sltiu` | `cond = (a < imm7)` | — | — |
| `sgti` | `cond = (a > imm7)` | — | — |
| `sgtiu` | `cond = (a > imm7)` | — | — |
| `seqi` | `cond = (a == imm7)` | — | — |
| `snei` | `cond = (a != imm7)` | — | — |

**untyped** — the 42 casts

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `cvt.b.i32` | `a = cast.b→i32(b)` | — | — |
| `cvt.b.u32` | `a = cast.b→u32(b)` | — | — |
| `cvt.b.i64` | `a = cast.b→i64(b)` | — | — |
| `cvt.b.u64` | `a = cast.b→u64(b)` | — | — |
| `cvt.b.f32` | `a = cast.b→f32(b)` | — | — |
| `cvt.b.f64` | `a = cast.b→f64(b)` | — | — |
| `cvt.i32.b` | `a = cast.i32→b(b)` | — | — |
| `cvt.i32.u32` | `a = cast.i32→u32(b)` | — | — |
| `cvt.i32.i64` | `a = cast.i32→i64(b)` | — | — |
| `cvt.i32.u64` | `a = cast.i32→u64(b)` | — | — |
| `cvt.i32.f32` | `a = cast.i32→f32(b)` | — | — |
| `cvt.i32.f64` | `a = cast.i32→f64(b)` | — | — |
| `cvt.u32.b` | `a = cast.u32→b(b)` | — | — |
| `cvt.u32.i32` | `a = cast.u32→i32(b)` | — | — |
| `cvt.u32.i64` | `a = cast.u32→i64(b)` | — | — |
| `cvt.u32.u64` | `a = cast.u32→u64(b)` | — | — |
| `cvt.u32.f32` | `a = cast.u32→f32(b)` | — | — |
| `cvt.u32.f64` | `a = cast.u32→f64(b)` | — | — |
| `cvt.i64.b` | `a = cast.i64→b(b)` | — | — |
| `cvt.i64.i32` | `a = cast.i64→i32(b)` | — | — |
| `cvt.i64.u32` | `a = cast.i64→u32(b)` | — | — |
| `cvt.i64.u64` | `a = cast.i64→u64(b)` | — | — |
| `cvt.i64.f32` | `a = cast.i64→f32(b)` | — | — |
| `cvt.i64.f64` | `a = cast.i64→f64(b)` | — | — |
| `cvt.u64.b` | `a = cast.u64→b(b)` | — | — |
| `cvt.u64.i32` | `a = cast.u64→i32(b)` | — | — |
| `cvt.u64.u32` | `a = cast.u64→u32(b)` | — | — |
| `cvt.u64.i64` | `a = cast.u64→i64(b)` | — | — |
| `cvt.u64.f32` | `a = cast.u64→f32(b)` | — | — |
| `cvt.u64.f64` | `a = cast.u64→f64(b)` | — | — |
| `cvt.f32.b` | `a = cast.f32→b(b)` | — | — |
| `cvt.f32.i32` | `a = cast.f32→i32(b)` | — | — |
| `cvt.f32.u32` | `a = cast.f32→u32(b)` | — | — |
| `cvt.f32.i64` | `a = cast.f32→i64(b)` | — | — |
| `cvt.f32.u64` | `a = cast.f32→u64(b)` | — | — |
| `cvt.f32.f64` | `a = cast.f32→f64(b)` | — | — |
| `cvt.f64.b` | `a = cast.f64→b(b)` | — | — |
| `cvt.f64.i32` | `a = cast.f64→i32(b)` | — | — |
| `cvt.f64.u32` | `a = cast.f64→u32(b)` | — | — |
| `cvt.f64.i64` | `a = cast.f64→i64(b)` | — | — |
| `cvt.f64.u64` | `a = cast.f64→u64(b)` | — | — |
| `cvt.f64.f32` | `a = cast.f64→f32(b)` | — | — |

# 8. Opcode tables: E-type

Every opcode with the 6-bit prefix `111001` shares the layout
`code(6) | reserved(6) = 0 | a(7) | b(7)` — the same body shape as C-type,
distinguished only by the prefix. The 37 assigned opcodes occupy codes
`0–43` (with `1–3` and `13/15/17/19` reserved — the retired integer-`neg`
members and the retired unsigned `clz`/`popcount` members); codes
`44–63` are reserved. A nonzero reserved field is rejected.
The operand roles are fixed per opcode: the unary and canonicalization
rows read `a = dst, b = src`; the transfer/lifecycle rows vary as listed.
The E-type holds the typed unary operations (outside the casts), the
32-bit canonicalization pair, the copy/borrow/move/take transfers, the
counted lifecycle, and the return/tail/trap terminators.
`cmov` is the one ternary transfer — it needs three register operands and
lives in R-type (§4); the E-type body carries only two.

**Typed unary.** `neg` is widthless — one untyped integer opcode
computing on the canonical 64-bit cell (its 32-bit sequence adds
`sext32`, §4), with `neg.f32`/`neg.f64` float members; `abs`
is a **4-rep family with the declared order `i32, i64, f32, f64`** — the
integer subfamily is the signed integers only (unsigned `abs` is the
identity and has no opcode) followed by the float subfamily. `clz`/
`popcount` are integer-2 families — the width selectors `i32`/`i64`,
valid for both signed and unsigned inputs (counts are sign-agnostic,
§4); `sqrt`/`floor`/`ceil`/`trunc`/`round`
are float-2 families. All unary rows are total except the signed-rep
integer `neg`/`abs` wrapping rules (WebAssembly semantics, §4) and never
trap.

**Transfer.** `not` is the boolean complement, may read/write `cond` in
place (`not cond, cond`). `copy` is a bit-copy: it may read `zero` (when
the destination fixes the kind — `copy cond, zero` is bool) and `cond`,
and may write `cond`; the general `copy dst, zero` for a non-bool type is
materialized as a typed `const` by the lowering. `borrow` and `move`
require real slots on both sides (no special may name them) and their
results may not be discarded; `move` transfers ownership and uninitializes
the source. `take dst, src` is the **generic take** — the v10 successor of
v9's `result_take`: `dst` may be any destination including `zero` (a
`zero` destination discards the value — only void/Copy results may be
discarded, §3.2), the source must be a real F/T register, and the
**source is cleared** (uninitialized) after the transfer. The post-call
contract form is `take dst, F(L+3+O-A)` — the result alias of the call
just completed ([LLIR Specification](Stilla%20LLIR%20Specification.md)
§5); the take is otherwise a general register transfer usable anywhere a
move-with-clear is wanted. `read_tag` reads the union tag of a real slot.

**Lifecycle.** `release src` decrements the counted owner's reference
count and frees the object at zero (the cell becomes uninitialized);
`copy_retain dst, src` retains the counted source into the dead
destination cell; `replace_copy dst, src` retains the source first, then
releases the old destination and stores the retained value (formed only
where those steps are infallible); `replace_move dst, src` moves the source
to a temporary, releases the old destination, then stores the moved value;
`release_ret result, x`
≡ `release x; ret result` — the released owner source `x` must be an F cell, the
result source keeps the ordinary `ret` rules. No special may name a
lifecycle source.

**Return and termination.** `ret`'s `a` is the result source — an F cell,
a T register, or `zero` (`ret zero` returns an actual zero or `false`;
void returns write `zero`); `b` is zero (validated). `tailcall_self`
reuses the current frame, preserves `ra`, and takes no operands (`a`/`b`
zero). `trap` terminates unconditionally (`a`/`b` zero).

#### E-type — unary, canonicalization, transfer, lifecycle, and control — 41 opcodes

**neg** — widthless integer, then `f32, f64`

`a = -b` — two's complement on the full canonical cell; the sign-agnostic result wraps modulo 2⁶⁴ (WebAssembly semantics, §4), and a 32-bit operand type's `neg; sext32` sequence wraps it modulo 2³². Never traps.

| Opcode | Comment |
| --- | --- |
| `neg` | negate a 32- or 64-bit integer cell |
| `neg.f32` | negate 32-bit float |
| `neg.f64` | negate 64-bit double float |

**32-bit canonicalization** — untyped, no rep

`sext32`: `a = signExtend32(low 32 bits of b)` — the canonical cell of a 32-bit result. `zext32`: `a = zeroExtend32(low 32 bits of b)` — the operand form the full-cell unsigned operations require.

| Opcode | Comment |
| --- | --- |
| `sext32` | sign-extend 32→64 |
| `zext32` | zero-extend 32→64 |

**abs** — reps `i32, i64, f32, f64`

`a = abs(b)` — declared order `i32, i64, f32, f64` (no unsigned members); never traps.

| Opcode | Comment |
| --- | --- |
| `abs.i32` | absolute value of i32 |
| `abs.i64` | absolute value of i64 |
| `abs.f32` | absolute value of 32-bit float |
| `abs.f64` | absolute value of 64-bit double float |

**clz** — width selectors `i32, i64`

`a = clz(b)` — the count of leading zeros of the operand cell, taken at
the operand's width (the 32-bit forms count from bit 31). Sign-agnostic:
the unsigned integer types alias the signed member of the same width
(`clz.u32` → `clz.i32`, `clz.u64` → `clz.i64`). Never traps.

| Opcode | Comment |
| --- | --- |
| `clz.i32` | count leading zeros of a 32-bit cell (signed or unsigned) |
| `clz.i64` | count leading zeros of a 64-bit cell (signed or unsigned) |

**popcount** — width selectors `i32, i64`

`a = popcount(b)` — the count of set bits of the operand cell, taken at
the operand's width. Sign-agnostic: the unsigned types alias the signed
member of the same width (`popcount.u32` → `popcount.i32`,
`popcount.u64` → `popcount.i64`). Never traps.

| Opcode | Comment |
| --- | --- |
| `popcount.i32` | population count of a 32-bit cell (signed or unsigned) |
| `popcount.i64` | population count of a 64-bit cell (signed or unsigned) |

**sqrt** — reps `f32, f64`

`a = sqrt(b)`.

| Opcode | Comment |
| --- | --- |
| `sqrt.f32` | √ of 32-bit float |
| `sqrt.f64` | √ of 64-bit double float |

**floor** — reps `f32, f64`

`a = floor(b)`.

| Opcode | Comment |
| --- | --- |
| `floor.f32` | floor of 32-bit float |
| `floor.f64` | floor of 64-bit double float |

**ceil** — reps `f32, f64`

`a = ceil(b)`.

| Opcode | Comment |
| --- | --- |
| `ceil.f32` | ceil of 32-bit float |
| `ceil.f64` | ceil of 64-bit double float |

**trunc** — reps `f32, f64`

`a = trunc(b)`.

| Opcode | Comment |
| --- | --- |
| `trunc.f32` | truncate to integer, 32-bit float |
| `trunc.f64` | truncate to integer, 64-bit double float |

**round** — reps `f32, f64`

`a = round(b)`.

| Opcode | Comment |
| --- | --- |
| `round.f32` | round to nearest, 32-bit float |
| `round.f64` | round to nearest, 64-bit double float |

**untyped**

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `not` | `a = !b` | — | — |
| `read_tag` | `a = tag(b)` | — | — |
| `copy` | `a = b` | — | — |
| `borrow` | `a = borrow(b)` | — | — |
| `move` | `a = move(b)` | — | — |
| `take` | `a = take(b)`; clear `b` | — | — |
| `release` | `release(a)` | — | — |
| `copy_retain` | `a = retain(b)` | — | — |
| `replace_copy` | `tmp = retain(b); release(a); a = tmp` | — | — |
| `replace_move` | `tmp = move(b); release(a); a = tmp` | — | — |
| `release_ret` | `release(b); return a` | — | T |
| `ret` | `return a` | — | T |
| `tailcall_self` | Install prepared arguments and jump to the current function entry | — | T |
| `trap` | Terminate with a runtime trap | — | T |

# 9. Opcode tables: U-type

Four opcodes share the layout `op(5) | a(7) | imm20`; three are selected
by their 5-bit prefixes outright, while `j` shares `jal`'s prefix and is
selected by its register field:

| Opcode | `op(5)` | `a` | effect |
| --- | --- | --- | --- |
| `jal` | `11101` | `ra` (only) | direct frame call |
| `j` | `11101` | `zero` (fixed) | unconditional intra-function jump, no link |
| `auipc` | `11110` | dst | `dst = current_pc + (signExtend20(imm20) << 12)`, then fall through |
| `lui` | `11111` | dst | `dst = signExtend20(imm20) << 12`, then fall through |

`jal ra, addr` is an atomic **direct call**: its
frame-enter semantics are frozen in the calling convention ([LLIR
Specification](Stilla%20LLIR%20Specification.md) §5) — it is never lowered
to a plain jump relying on a callee prologue. `jal.a` must be exactly `ra`
(validated); the only other legal register value on prefix `11101` is
`zero`, which selects the link-less `j` (§9.1). `jal`/`j` are the U-type
terminators. `auipc`/
`lui` write their destination (an F cell, T register, or `zero` — never
`ra` or `cond`) and fall through; writing `zero` discards the result. Both
accept every raw 20-bit pattern; the result is `signExtend20(imm20) <<
12`, so `lui F0, 1` sets `F0 = 0x1000` and `lui F0, 0xfffff` sets
`F0 = -0x1000` (sign-extended `-1 << 12`). `auipc` uses the same 20-bit
immediate shifted left 12 as a pc-relative displacement.

#### U-type — jal / j / auipc / lui — 4 opcodes

**untyped**

| Opcode | Behavior | trap | term |
| --- | --- | --- | --- |
| `jal` | `call(pc + signExtend20(imm20))` — `a` must be `ra` | — | T |
| `j` | `pc = pc + signExtend20(imm20)` — `a` must be `0` | — | T |
| `auipc` | `a = pc + (signExtend20(imm20) << 12)` | — | — |
| `lui` | `a = signExtend20(imm20) << 12` | — | — |

## 9.1 j — the link-less jump

Conceptually `j` and `jal` differ — a frame call versus an
intra-function jump — and they remain separate logical opcodes (209
vs. 210). At the encoding level, however, `j` extends the U-type `jal`
slot: it is the same word with the register field carrying the `zero`
special register (`0x00`):

| Encoding | Bits |
| --- | --- |
| `j offs20` | `11101` + `a = zero` + `offs20` |

while `jal` fixes the same field at `ra`; the `zero` value marks that no
link is kept.
The conceptual difference rides in the logical opcode, not the layout:
`j offs20` enters no frame and sets
`pc = current_pc + signExtend20(offs20)` (reach `[-524288, 524287]`,
the same 20-bit signed interval as `jal`). The ordered decoder resolves
prefix `11101` by that field: `ra` → `jal`, `zero` (`0x00`) → `j`;
every other register value is rejected as an unclean word.
The assembly mnemonic remains `j`; it is never a spelling of `jal` and
never targets a function entry.

# 10. Immediate operands and fusion windows

All ranges below are exact
two's-complement intervals — the asymmetric ends are the normative bounds
(any "reach ±512"-style shorthand elsewhere in this document cites the
magnitude, not the bound):

| Item | v10 range |
| --- | --- |
| signed fused immediate (`addi`/`subi`/`muli`/`divi`/`remi`/`maddi`/`shri`; C-type `slti`/`sgti`/`seqi`/`snei`; B-type `blti`/`beqi`/`bnei`) | `[-64, 63]`, sign-extended from the 7-bit pattern |
| mask/unsigned fused immediate (`addiu`/`subiu`/`muliu`/`diviu`/`remiu`/`maddiu`/`shriu`; `andi`/`ori`/`xori`; `shli` counts) | `[0, 127]`, zero-extended |
| conditional branch `offs10` (all B-type) | `[-512, 511]` |
| `jal`/`j` offset | `[-524288, 524287]` (signed 20-bit, instruction granularity) |
| `auipc`/`lui` upper immediate | every raw 20-bit pattern; `signExtend20(imm) << 12` |
| `jr`/`jalr` offset | signed 16-bit from the base register |
| inline dense ID (`TypeId`, `MemberId`, `DestructureDescId`, tags) | `[0, 127]`; ID 128 → `error.IdOutOfRange` (fixed name frozen here) |
| I-type 16-bit IDs and `XId`/window offsets | `[0, 65535]` |
| move-wide lane value | unsigned `[0, 65535]` |

**Fusion windows.** A constant fuses into an immediate-form opcode only
when it fits the opcode's window; otherwise it materializes through
`const` (or move-wide for `u64` patterns) and the register form is used.
The signed variants sign-extend the raw 7-bit pattern (so `0x7f` is −1);
the unsigned variants and the mask/count forms zero-extend it (so `0x7f`
is 127; `andi F0, F1, 0x7f` masks with `0x0000007f`). Shift counts are
masked to the low 6 bits (mod 64) at decode — a shift never traps
(`x << 32` is `x` at 64 bits). A 32-bit shift's mod-32 count semantics
are a lowering obligation (§4): the register form masks through
`andi T15, count, 31`, and a fused count is pre-reduced mod 32 by the
peephole. The immediate forms compute at 64 bits, so a fused 32-bit
operation keeps its sequence's `sext32` (§4). **The float families have
no immediate forms** — every float constant materializes through `const`.
An `imm` colliding with a special-register encoding is an ordinary
immediate (`0x6d` inside an I-type `imm16` is the value 109; in a
sign-extending field `0x6d` is −19); the interpreter never treats it as a
register.

# 11. Control flow, branches, and jumps

Control-flow, effect, and trap semantics — the source/CFG obligations, and
termination behavior — are defined in [Stilla LLIR
Specification](Stilla%20LLIR%20Specification.md) and not repeated here;
this section fixes the branch/jump reach rules and the long-branch
expansion safety net.

A `jal`/B-type branch target is the absolute PC
`pc + signExtend(offset)`: the offset is relative to the instruction's own
`pc` — the signed difference in instruction indexes, so backward branches
carry a negative offset. B-type offsets are **10 bits** (reach ±512,
§5); `jr`'s is **16 bits** (§6) added to its base register (reach ±2¹⁵);
`jal`'s is **20 bits** (§9, reach ±2¹⁹); `auipc`'s is **20 bits shifted
left 12** (§9, reach ±2³¹); a `switch` arm target is a **signed 32-bit
offset from the `switch` instruction's own `pc`**, added modulo 2³²
(§12). Every `u32` target therefore has one representable modular
difference, so a `switch` needs no reach expansion. Jump
reach is a property of the encoding and
is **host-width independent**. The runtime pc is a host word (`u64` on
64-bit hosts, `u32` on 32-bit hosts); on the 32-bit tier a computed
`auipc` target truncates to `u32`. B-type branches, `switch` arms, and
`j` must target blocks in the current function. `jal ra` instead
targets a function entry for a direct call.

A compare-and-branch replaces `pc` with the decoded target when the
comparison holds and falls through to `pc + 1` otherwise — exactly one
target per record, so a conditional transfer is normally a *pair* of
records: the compare-and-branch (targeting the then-block) followed by the
unconditional `j` (targeting the else-block). When one target is
the next block in the lowering's linear layout, the trailing-`j`
elimination drops the redundant second record and the block ends with the
compare-and-branch itself: the else target falls through directly, or the
condition inverts — `beq`↔`bne` (all reps, equality incl. the float
forms), the integer ordering pairs `blt`↔`ble` and `bltu`↔`bleu` (each
swap: `!(a<b) ≡ a>=b ≡ ble b,a`), `beqi`↔`bnei` (`blti`/`bltiu` have no
inverting complement, §11.1),
`tbz`↔`tbnz` — and the branch carries the else
target with the then body falling through. The greater relations (`bgt`/
`bge`) have no opcode: they are reached by the operand swap, which is what
makes `blt`↔`ble` complementary. **Float `blt`/`ble` inversion
is unsafe with NaN** (both are false on NaN, so the inverted branch is not
the complement), and the immediate `blti`/`bltiu` have no inverting
complement (there is no `bgei`): those use the non-inverting trampoline
below for far branches, never integer-style inversion.

The B-type branches are **not structural block terminators in the pair
form** (the block's last record is the `j`), but the one-record
form makes them legal block ends — the validator accepts a
compare-and-branch as a block's last instruction.

## 11.1 Long-branch expansion (safety net)

The 10-bit B-type offset is the inherent capacity of the format (±512).
The expansion is a **safety net** that preserves correctness beyond that
reach:

- **Near branch** (target within ±512): emit the direct
  `beq`/`bne`/`blt`/`bltu`/`ble`/`bleu` and their float forms, `beqi`/
  `bnei`/`blti`/`bltiu`, or `tbz`/`tbnz` with `offs10` = target − pc.
- **Far branch, invertible forms only** (integer `blt`/`ble`/`bltu`/
  `bleu`, `beq`/`bne` incl. the float equality forms, `beqi`/`bnei`,
  `tbz`/`tbnz`): invert the
  condition and skip over a `j` — two records:
  `b<inverted> (swap lhs, rhs) , +2` followed by `j, target`. The
  inversion pairs keep the rep: `blt ↔ ble` and `bltu ↔ bleu` (the
  operands swap, since `!(a<b) ≡ ble b,a`), `beq ↔ bne` (all reps,
  operands unchanged), `beqi ↔ bnei` (same rep and imm7), and
  `tbz ↔ tbnz` (same register and bit
  index).
- **Far branch, float `blt`/`ble` and immediate `blti`/`bltiu`**
  (NaN-ordered or with no inverting complement): the predicate cannot be
  inverted, so use the three-record non-inverting trampoline —
  `P lhs, rhs, +2; j +2; j far_target` — the predicate,
  when true, skips over the second `j` into the far jump; when
  false, the second `j` skips the far jump.

The expansion applies only to **fused** compare-and-branches (those
carrying a direct target). The generic conditional test `bne Fx,
zero` on a bool slot is always followed by a `j`, and the `j`'s
target is what skips it (+1/+2) — always within reach, never expanded.

Implementation: the lowering's linearization writes branch offsets in
place, then validates for out-of-range targets and expands any it finds —
inserting the inverted branch + `j` (or the float trampoline) in
place — recomputing PCs and re-checking until no expansion fires. Each
round turns the currently-far branch near, so the iteration converges.
After the final round every target and every U-type signed imm20 is
re-validated; an offset that still does not fit is
`error.ProgramTooLarge` (fixed name frozen here), never a silent
truncation.

## 11.2 Tail calls

`tailcall_self` reuses the current frame: no header is written, `fp` is
preserved, `ra` is not rewritten, and the stack cannot grow. The compiler
has already emitted the `slot_*` preparation records (one per argument at
its absolute window offset) followed by the leftover-owner kill records.
The instruction atomically moves prepared window slot `W - A + k` into
parameter cell `Fk` for every parameter `k`, clearing each window slot;
the remaining F/X cells become uninitialized. The record itself carries
no descriptor, and the target signature is the current function's own,
derivable from its FunctionDesc. It then sets `sp` to the current frame
end and `pc` to the current function's `entry_pc`. The instruction set
defines self-tailcalls only.

`jr` is the unconditional register-relative jump (§6): the base register
holds a dynamic instruction index and the 16-bit offset adjusts from it.
The computed target must lie in the current function's code range; because
the base is dynamic the range is a runtime check — an out-of-range target
traps. The frontend never emits it; it exists for runtime/backend dispatch.

Phi elimination has no dedicated opcode: it emits ordinary
`copy`/`move`/`borrow` instructions at the end of each predecessor edge
(§12).

# 12. Descriptor records

Variable-length operands remain atomic through descriptors rather than
being split into arbitrary binary instructions: `construct`, syscalls,
multi-result destructures, and `switch` use a fixed instruction record
that references a descriptor. A descriptor owns only index ranges into its
designated flattened table; every range is a `{ start: u32, len: u32 }`
pair, validated before execution.

```text
SyscallDesc     { host_binding_id: u32, signature_id: u32,
                  args_start: u32, args_len: u32 }
ConstructDesc   { tag: u32, args_start: u32, args_len: u32,
                  result_type: TypeId }
DestructureDesc { kind: DestructureKind, base_type: TypeId,
                  dsts_start: u32, dsts_len: u32 }
MemberDesc      { base_type: TypeId, type_: TypeId, ref: u32 }
DropDesc        { type_: TypeId, host_type_: HostTypeId }
SwitchDesc      { arms_start: u32, arms_len: u32 }
SwitchArm       { tag: u32, target: i32 }
```

- There is no `CallDesc`, `call_direct`, or `call_indirect`;
  direct calls are `jal ra, addr` (static target, no descriptor) and
  indirect calls are `jalr ra, base, offs16` (dynamic target, no
  descriptor).
- `ConstructDesc`: `tag` is the union discriminant, or `0xffffffff`
  (`no_tag`) for a struct, tuple, or list construction. `{ args_start,
  args_len }` selects the component registers from the shared `call_args`
  register table; `result_type` carries the constructed value's `TypeId`.
- `DestructureDesc`: `kind` must match its opcode — `unpack_struct`
  requires `.struct`, `unpack_tuple` `.tuple`, `unpack_variant` and
  `borrow_variant` `.variant`, `split_list` `.list` — and
  `{ dsts_start, dsts_len }` selects the result registers from
  `destructure_dsts` (8-bit `ValueReg`s), in result order, with the
  parallel `destructure_dst_types` rows giving each result's `TypeId` in
  the same order. `base_type` carries the consumed base's `TypeId`.
- `MemberDesc`: one interned row per distinct `(base TypeId, result
  TypeId, reference)` triple across `load_member`/`store_member`/
  `read_field`/`read_tuple`/`read_payload`, carrying the accessed
  object's base `TypeId` (`0xffffffff` for the write-only `store_member`),
  the result's `TypeId`, and the reference — `load_member`'s dense module
  member id, `store_member`'s `SlotId`, or `read_field`/`read_tuple`/
  `read_payload`'s field/element index (0 for `read_payload`).
- `DropDesc`: the static destruction descriptor of one residual `drop` —
  exactly one of `type_`/`host_type_` is set, the other `0xffffffff`. A
  typed drop destroys an `any` value by its runtime tag; a host drop
  dispatches the host-backed opaque type's destructor through
  `host_types[host_type_]` (Runtime §6.6). Counted owners never reach
  `drop` — they `release`.
- `SwitchDesc`: `{ arms_start, arms_len }` selects `SwitchArm` rows from
  `switch_arms`; arm tags must be unique and must be variants of the union
  the `read_tag` scrutinee names. `switch`'s default is a trap.
- `SwitchArm`: `target` is a **signed pc-relative offset** — the signed
  modular difference in instruction indexes from the `switch` instruction's
  own `pc` to the arm's target block (the decoded target `pc +% target`, §11),
  using modular addition so every `u32` target is reachable. The lowering emits
  **one descriptor per `switch`**: identical `(tag, target)` sequences at
  different pcs encode different offsets, so the absolute-target
  interning the `construct`/destructure descriptors enjoy is invalid
  here — this is a canonical-lowering rule, not a validation invariant.
- Phi elimination has no descriptor record: each phi input lowers to one
  ordinary instruction on the predecessor edge — `copy` for a plain
  *Copy* value, `copy_retain` for a counted *Copy* value, `move` for a
  *Unique* transfer, `borrow` for a borrowed view. The instructions on an
  edge are ordered so every source is read before its destination is
  written; a copy cycle between simultaneously live phi slots breaks
  through one type-matched cycle staging cell past the value cells
  ([LLIR Specification](Stilla%20LLIR%20Specification.md) §3.1).

# 13. Side-table records

```text
ConstRecord    { kind: ConstKind, type_: TypeId, a: u32, b: u32 }
ConstKind      = int | float | bool | string | void
TypeDesc       { kind: TypeKind, a: u32, b: u32, c: u32 }
TypeKind       = primitive | named | list | box | tuple | function | module
TypeDeclDesc   { kind: TypeDeclKind, a: u32, b: u32, c: u32, d: u32, e: u32 }
TypeDeclKind   = struct | union | opaque
HostTypeDesc   { host_start: u32, host_len: u32, name_start: u32, name_len: u32 }
UnionVariant   { payloads_start: u32, payloads_len: u32 }
SignatureDesc  { params_start: u32, params_len: u32, ret: TypeId }
ParamDesc      { mode: ParamMode, type_: TypeId }
ParamMode      = plain | borrow | move
SymRange       { start: u32, len: u32 }        // SymbolId → bytes
ImportDesc     { module_sym: u32, member_sym: u32 }   // member_sym: 0xffffffff for a module-only import
ExportDesc     { member_sym: u32, kind: ExportKind, ref: u32, public: u32 }
ExportKind     = const_slot | function | nested_module | host_binding
ModuleSlot     { type_: TypeId }
```

- `ConstRecord` (`const`): `type_` carries the constant's `TypeId` — the
  source for the destination cell's exact type. `int` carries the raw
  operand-width pattern (`a` low, `b` high words; a 32-bit constant
  requires `b == 0`); `float` carries the `f32` bits in `a` (`b == 0` for
  32-bit float) or the full 64-bit double float pattern across `{ a, b }`; `bool` carries
  0/1 in `a`; `string` selects `{ a: start, b: len }` bytes of the
  program-owned `strings` blob; `void` leaves both zero and its
  destination is `zero`.
- `TypeDesc`: `primitive` with `a` a `PrimitiveId` (`byte | bool | int32
  | uint32 | int64 | uint64 | float32 | float64 | str | any | hostdata`); `named`
  with `a` a declaration `TypeId` and `{ b, c }` the type-argument range
  into `types`; `list`/`box` with `a` the element `TypeId`; `tuple` with
  `{ a, b }` the element range into `types`; `function` with `a` a
  `SignatureId`; `module` with unused fields. There is **no
  per-cell slot-type table**: the types of the values in F/X/T cells ride
  in the opcodes' reps and the records/descriptors that create or consume
  them.
- `TypeDeclDesc`: `struct` with `a` an `OwnershipId`, `b` the drop-hook
  local `FunctionId` (`0xffffffff` when absent or imported), `e` the
  `ImportDesc` index of an imported drop hook (`0xffffffff` when local or
  absent — at most one of `b`/`e` is set), and `{ c, d }` the field-type
  range into `type_decl_fields`; `union` with `a` an `OwnershipId` and
  `{ b, c }` the variant range into `union_variants` (each variant's
  payload types range into `union_payloads`; `e` unused); `opaque` with
  `a` a `HostTypeId`.
- `SignatureDesc`/`ParamDesc`: parameter rows in declared order; `mode`
  is the *declared* parameter mode; the runtime derives the transfer
  behavior of a `plain` parameter from its type's ownership.
- `SymRange`/`ImportDesc`/`ExportDesc`: the artifact's symbolic linkage
  (LLIR Specification §2). A `SymbolId` resolves through `symbols` to a
  byte-exact canonical module specifier or member name. An `ImportDesc`
  is a `(module_symbol, member_symbol)` pair; a module-only import
  (a `module_ref` target other than the artifact's own module) sets
  `member_sym` to `0xffffffff`. The `exports` table is sorted by symbol
  bytes and holds the module's public members (`public = 1`, exactly the
  rows a `load_member` may resolve) plus every function of the module
  (`public = 0` unless the function is also a member) so that imported
  calls and function values — including lowered generic specializations —
  resolve by name; `ref` is per `kind`: a `SlotId`, a local `FunctionId`,
  a `SymbolId` (nested module), or unused (`host_binding` rows are never
  first-class values). Duplicate symbols are a validation error.
- `HostTypeDesc`: `{ host_start, host_len }` is the declaring host
  module's canonical specifier, a byte range into the `strings` blob —
  a symbol, never a numeric id.
- `ModuleSlot`: constant-slot indexes are their own space; `type_` is
  the slot's `TypeId` (the teardown type).

`call_args` and `destructure_dsts` rows are 8-bit `ValueReg`s (§3.1);
`call_args` always names F cells — arguments home to the output window
and T does not participate in the parameter ABI. `syscall` and `construct` share `call_args` for their
argument registers.

# 14. Validation

Before execution, structural validation must reject — this is the full
trust-boundary list ([LLIR Specification](Stilla%20LLIR%20Specification.md) §8):

- a word whose top two bits are `10` (the reserved class), a word whose
  top bits are `11` but match no format prefix, an unassigned code in any
  format (R codes 71–511; B codes 20–63; E codes 44–63;
  I codes 31–63 **and the reserved I-type selector 10**), or a `11101`
  word whose register field is neither `ra`
  nor `zero`;
- a C-type/E-type word whose six reserved bits are nonzero;
- an invalid register operand — neither a frame register (`0x13–0x7f`),
  nor `zero`/`ra`/`cond`, nor a temp (`0x03–0x12`); the frame-register
  bound is the function's register count `f_count + window_count` — the
  O aliases are legal register operands, and the budget check below keeps
  that count at or below 109 (`0x6d`); a `ra` in any position
  other than a `jal` link or the `jalr` token; a `cond` outside its
  schema positions; a move-wide `a` naming any special; a `spill_take`/
  `spill_put` `a` naming anything but a T register; a `slot_*` source, a
  `drop` operand, a `release_ret` owner source, or a `take` source that
  is not a real register; `zero` in a
  *Unique*, borrowed, function, or aggregate position;
- an immediate exceeding its opcode's bound — a 7-bit field outside the
  rep's window (sign-extended `[-64, 63]` or zero-extended `[0, 127]` is
  structurally the same raw pattern, so the window check is about the
  *semantic* range; the raw field always fits), a `tbz`/`tbnz` bit index
  ≥ 64 (high bit of the field set), a `trap`/`tailcall_self`/`ret` record
  with a nonzero unused field, an inline ID ≥ 128 (an `IdOutOfRange`
  build rejection at the frontend, and a load rejection here), an I-type
  ID above its table's bound;
- a nonzero `0`-role field (the `c` of `tail`, the `b` of
  `ret`/`tailcall_self`/`trap`, the `a`/`b` of
  `trap`);
- invalid opcode/descriptor combinations (`unpack_struct` requiring a
  `.struct` `DestructureDesc`, `split_list` a `.list`, and so on) and
  out-of-bounds descriptor ranges;
- invalid entry/branch/switch PCs — a `jal`/B-type branch offset decodes
  to `pc + signExtend(offset)` and a `switch` arm target to
  `pc +% target`; B-type branches, `switch` arms, and `j` must
  target a block start inside the current function, while `jal ra` must
  target a function entry; missing terminators are rejected; a
  `tbz`/`tbnz` bit number above 63 is
  rejected; `jr`'s target is dynamic, so validation checks only its
  register operand (a real register, no special) and the offset fields —
  the runtime range check is a trap, not a rejection; `auipc`'s
  displacement is not range-checked (a target beyond the image is a
  runtime trap);
- invalid frame layout — `f_count > frame_count_max = 109`, `x_count >
  0x1_0000` (65,536 cells addressed by `XId` 0…65535), or a window
  overflow (`f_count + x_count + window_count` exceeding the
  stack-arithmetic limit), plus the **register budget** —
  `f_count + window_count > 109` is rejected (the O aliases must stay
  below the specials' encodings) — plus invalid per-function
  `signature_id` and out-of-bounds `spill_take`/`spill_put`
  `XId`s and `slot_*` window offsets;
- symbolic-linkage violations — a `SymbolId`, `ImportDesc` index, or
  export `ref` outside its table; duplicate or unsorted export symbols; a
  struct `TypeDeclDesc` with both a local and an imported drop hook, or an
  out-of-range hook reference;
- the call-shape constraints of §6/§8/§11 — a non-void call's fallthrough
  must be a `take dst, F(L+3+O-A)` — the take's *source register* must
  equal the caller's result alias, which derives the implied
  `A = L + 3 + O - src` that is checked against the static callee's value
  area (for `jal`; for `jalr`, `enterCall` checks the same after resolving
  the actual callee and before modifying VM state); a void callee must see
  no take; a `cond` read (`cmov`/`copy`) after a call or across a
  block boundary; a `jal ra` whose static target is not a signature-compatible
  function entry; a `j` whose target lies outside the current
  function.

Validation is **structural only**: it checks shapes, ranges, tags, and
bounds — it does not re-prove SSA dominance, ownership, borrow
provenance, or lifecycle ordering, which the frontend has already
established ([LLIR Specification](Stilla%20LLIR%20Specification.md) §8).
v10 performs no typed dataflow analysis and derives no execution plan; the
opcode — a float rep, an integer signedness, or a canonicalization
sequence — and the descriptor-carried types are the single source of
operand types.

# 15. Non-goals

The shared non-goals — interpreter dispatch mechanics, value or heap
representation, the frame/call transfer contract, module-instantiation
lifecycle, host vtables, GC, concurrency, JIT compilation, source maps,
debug information, and a stable file format — are listed in [Stilla LLIR
Specification](Stilla%20LLIR%20Specification.md). This document
additionally fixes the opcode set: §4–§9 are the complete set — 227
logical opcodes — and adding an opcode is a specification change. The v10
set is **semantically trusted, structurally validated**: it is not a
security boundary for arbitrary external LLIR ([LLIR
Specification](Stilla%20LLIR%20Specification.md) §8).

# 16. Golden words

Every example below is verified by the machine proof that generated this
table: each word decodes to exactly the opcode named, and re-encodes to
the same word. Words are written as the 32-bit value (MSB-first) and as
the four little-endian bytes.

| Example | Logical opcode | Encoded | Word | Bytes (LE) |
| --- | --- | --- | --- | --- |
| normal R-type | `add` | `00` + code 0 + `a=F1,b=F2,c=F3` (`0x14`,`0x15`,`0x16`) | `0x00050a96` | `96 0a 05 00` |
| C-type immediate comparison | `slti` | `111000` + code 16 + `a=F0,b=0x7f` | `0xe10009ff` | `ff 09 00 e1` |
| B-type bit-test | `tbz` | `01` + code 18 + `lhs=F0, bit=5, offs10=-1` | `0x522617ff` | `ff 17 26 52` |
| negative B conditional offset | `beq` | `01` + code 0 + `lhs=F1, rhs=F2, offs10=-2` | `0x402857fe` | `fe 57 28 40` |
| B signed imm7 (raw `0x7f` = −1) | `blti` | `01` + code 14 + `lhs=F1, imm7=0x7f, offs10=0` | `0x4e29fc00` | `00 fc 29 4e` |
| B unsigned imm7 (raw `0x7f` = 127) | `bltiu` | `01` + code 15 + `lhs=F1, imm7=0x7f, offs10=0` | `0x4f29fc00` | `00 fc 29 4f` |
| negative U `jal ra` | `jal` | `11101` + `a=ra (0x02), imm20=-1` | `0xe82fffff` | `ff ff 2f e8` |
| Link-less jump | `j` | `11101` + `a=zero, imm20=-4` | `0xe80ffffc` | `fc ff 0f e8` |
| I-type `jalr` | `jalr` | `110` + code 11 + `a=T0, imm16=-1` | `0xc583ffff` | `ff ff 83 c5` |
| C-type cast | `cvt.i32.u32` | `111000` + code 27 + `a=F0, b=F1` | `0xe1b00994` | `94 09 b0 e1` |
| C-type comparison | `seq` | `111000` + code 0 + `a=F1, b=F2` | `0xe0000a15` | `15 0a 00 e0` |
| E-type representative | `neg` | `111001` + code 0 + `a=F0, b=F1` | `0xe4000994` | `94 09 00 e4` |
| E-type return | `ret` | `111001` + code 40 + `a=0, b=0` | `0xe6800000` | `00 00 80 e6` |
| U-type `lui` | `lui` | `11111` + `a=F0 (0x13), imm20=1` | `0xf9300001` | `01 00 30 f9` |
| U-type `auipc` | `auipc` | `11110` + `a=F0 (0x13), imm20=-1` | `0xf13fffff` | `ff ff 3f f1` |

Hand check — `seq F1, F2`: `111000` (bits 31–26), code 0 = `000000`
(bits 25–20), reserved `000000` (bits 19–14), `a` = F1 = `0010100` (bits
13–7, `0x14`), `b` = F2 = `0010101` (bits 6–0, `0x15`) → `111000 000000
000000 0010100 0010101` = `0xe0000a15`. Hand check — `lui F0, 1`: `11111`
(bits 31–27), `a` = F0 = `0010011` (bits 26–20, `0x13`), imm20 =
`00000000000000000001` (bits 19–0) → `0xf9300001`; `F0 =
signExtend20(1) << 12 = 0x1000`. Hand check —
`j -4`: `11101` (bits 31–27), `a` = `zero` = `0000000` (bits 26–20,
`0x00`), offs20 = `11111111111111111100` (bits 19–0, −4) →
`11101 0000000 11111111111111111100` = `0xe80ffffc`; `pc' = pc - 4`.
The register field carries `zero` — the no-link mark. Setting `a` to
`ra` (`0x02`) instead turns the very same word into `jal -4`
(`0xe82fffff` with imm20 = −1).

## See also

- [Stilla LLIR Specification](Stilla%20LLIR%20Specification.md) — the program image, frames, and calling convention this instruction set executes against
- [Stilla Runtime Specification](Stilla%20Runtime%20Specification.md) — execution behavior
