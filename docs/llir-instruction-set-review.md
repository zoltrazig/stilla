# LLIR Instruction Set Review: Completeness and Consistency

## Scope and method

This report reviews `Stilla LLIR Instruction Set.md` for internal consistency and for agreement with its sibling specifications. The baseline is the document itself plus the sibling specs it leans on — `Stilla LLIR Specification.md`, `Stilla Runtime Specification.md`, `Stilla Core Types & Ownership Specification.md`, and `Stilla Core Language Specification.md`, and the design notes `interpreter-vm.md` and `air.md`. Source files were consulted only as **secondary corroboration** where a defect is confirmable solely from the implementation (noted inline as such); this review does not treat `src/` as normative. The review covers cross-reference resolution, numeric and structural completeness, cross-section schema agreement, encoding design, and documentation quality. Non-goals: no code or specification edits are made here; the fixes below are recommendations. The output is a deduplicated, reconciled set of findings — the factual audit and the design/documentation critique are merged where they describe the same defect, with both lines of evidence cited.

## Verdict

The document is **largely self-consistent**. The headline numbers all recompute correctly: the per-format assignment counts `112 / 20 / 31 / 64 / 38 / 4 = 269`, the logical-value ranges `R 1–112, B 113–132, C 133–196, E 197–234, I 235–265, U 266–269`, the derived family sizes (42 casts `= 7×7−7`, 22 comparisons, 20 B-type, 12 move-wide, E `44−6=38`), and all 15 `§16` golden words decode and re-encode consistently. Every internal `§N`/`§N.M` target resolves except one (`§12.1`), and the sibling targets invoked exist and support their claims.

The defects found are enumerated below, grouped by severity. Two are factual correctness problems that change what an implementer would build (`§16`'s `jal`/`j` hand-check, `§10`'s shift-masking examples), two are direct contradictions between sections, and the remainder are cross-spec model drift, encoding-design decisions, and documentation hygiene. A prioritized overhaul plan closes the report.

| Severity | Count | Where |
| --- | --- | --- |
| High | 4 | 2 consistency, 2 documentation |
| Medium | 13 | 7 consistency, 5 design, 1 documentation |
| Low | 22 | 5 consistency, 5 completeness, 3 design, 9 documentation |
| **Total** | **39** | |

X-1, X-2, DOC-1, and DOC-2 (all High) have since been resolved in their owning documents; see the annotations on those findings and the correctness-fixes list below.

---

## Consistency findings

### X-1 (High) — Broken internal cross-reference to a nonexistent subsection

- **Location.** `§1` scope note (header): *"loading decodes each record once into the VM's fixed instruction image (§12.1, `vm_instr.zig`)"*.
- **Problem.** The document has no `§12.1`. `§12` "Descriptor records" has no subsections and the table of contents runs `§1–§16`. The decode-once-into-a-fixed-image claim is not in this document at all.
- **Evidence.** The `§1–§16` table of contents and the flat `§12` body. The claim actually lives in `Stilla LLIR Specification.md` §8.2 and `interpreter-vm.md` §1/§7. (Merged with the documentation-critique observation that the authoritative opcode table lives in `llir_opcodes.zig`, re-exported by `llir.zig`.)
- **Suggested direction.** Retarget the reference to `Stilla LLIR Specification.md` §8.2 (and `interpreter-vm.md` §1/§7); if a `§12.1` is preferred, add it and name the generation source (`llir_opcodes.zig`) as the executable mirror.
- **Resolved.** The §1 scope note now points at `Stilla LLIR Specification.md` §8.2 and `interpreter-vm.md` §1/§7 (keeping the `vm_instr.zig` mention); the nonexistent `§12.1` reference is gone.

### X-2 (High) — `zero` typing rule contradicts the validation list

- **Location.** `§3.2`: *"a trusted-invalid image (frontend invariant, not a loader check)"*; `§14`: *"`zero` in a *Unique*, borrowed, function, or aggregate position"*.
- **Problem.** `§3.2` says writing a Unique/borrowed/function/aggregate result to `zero` is a frontend invariant, not a loader check; `§14` lists the same thing among what structural validation "must reject". The two cannot both hold.
- **Evidence.** Both passages; `§14`'s own closing statement, *"It performs no typed dataflow analysis"*, makes the `§14` clause structurally undecidable. (Merged with the documentation-critique finding that flagged the same `§14` clause.)
- **Suggested direction.** Pick one and delete the other. Prefer keeping it a frontend invariant — consistent with `§3.2` and with `§14`'s structural-only stance — and drop the `§14` clause; or make it a real check and remove the "trusted, not a loader check" language.
- **Resolved.** The `§14` rejection clause for `zero` in a *Unique*, borrowed, function, or aggregate position was removed; `§3.2`'s frontend-invariant wording now stands as the single statement of the rule.

### X-3 (Medium) — E-type counts violate the `§4` family rule

- **Location.** `§4`: *"contiguous run… at +1 each"*; `§8` clz/popcount selectors (`clz.i32`=12, `clz.i64`=14, `popcount.i32`=16, `popcount.i64`=18).
- **Problem.** The retired unsigned-alias holes 13/15/17/19 separate the members, so "contiguous except the reserved holes" and the "+1 each" rule cannot both hold.
- **Evidence.** `§8` selector layout versus the `§4` family rule. (Overlaps the reservation-rationale finding DES-8/Doc8.)
- **Suggested direction.** State the exception explicitly (per-family holes), or restate `§4` as a default plus an explicit exception list (see DOC-7).

### X-4 (Medium) — `load_member`'s `MemberDesc.ref` misdescribed

- **Location.** `§12`: *"`load_member`'s dense module member id"*.
- **Problem.** The sibling spec defines this field as an explicit `ImportDesc` index — a `(module_symbol, member_symbol)` pair — not a dense id.
- **Evidence.** `Stilla LLIR Specification.md` §2 and §7.
- **Suggested direction.** Reword to "an `ImportDesc` index" and align `§12` with the sibling spec.

### X-5 (Medium) — `store_member` operand named inconsistently

- **Location.** `§6`: *"`store_member` writes the value source `a` to the constant member `MemberId`"*; `§12`: *"`store_member`'s `SlotId`"*.
- **Problem.** The same operand is `MemberId` in one section and `SlotId` in another, and member indices and slot indices are distinct spaces.
- **Evidence.** `§6` aggregate paragraph versus the `§12` `MemberDesc` bullet; `air.md` stresses the two index spaces are distinct.
- **Suggested direction.** Make `§6` say `SlotId`.

### X-6 (Medium) — "not a real register" grouping over-permits T

- **Location.** `§14`: *"a `slot_*` source, a `drop` operand, a `release_ret` owner source, or a `take` source that is not a real register"*.
- **Problem.** In this document "real register" means F or T, so the grouping wrongly permits T for `slot_*` sources, the `drop` operand, and the `release_ret` owner — all F-only per other sections.
- **Evidence.** `§3.1` (*"the `slot_*` sources are always F cells"*), `§6`, and `§8`.
- **Suggested direction.** Say "not an F cell" for those three roles, and keep "real F/T register" only for `take`.

### X-7 (Medium) — Fast-bank cell count 18 versus 19

- **Location.** `§3.1.1`: *"all 18 fast cells are saved"*.
- **Problem.** Contradicts its own `[19]Value` (indexes 0–18) and `Stilla LLIR Specification.md` §3.2 (*"all 19 cells are saved"*).
- **Evidence.** The `§3.1.1` interpreter-state bullet; sibling spec §3.2. (Merged with the documentation-critique "19 vs 18" finding.)
- **Suggested direction.** Change to 19.

### X-8 (Medium) — Register-budget parenthetical is backwards

- **Location.** `§14`: *"(the O aliases must stay below the specials' encodings)"*.
- **Problem.** The specials (`0x00–0x02`) are *below* the F bank, not above it; the budget keeps frame/O encodings below `0x80`.
- **Evidence.** `§3.1` register ranges; the `§14` budget sentence.
- **Suggested direction.** Reword to keep frame/O encodings below `0x80` (the end of the F range).

### X-9 (Medium) — `§16` hand-check self-contradiction

- **Location.** `§16`: *"Setting `a` to `ra` (`0x02`) instead turns the very same word into `jal -4` (`0xe82fffff` with imm20 = −1)"*.
- **Problem.** Changing only `a` in `0xe80ffffc` (`j -4`) to `ra` yields `0xe82ffffc` (`jal -4`); `0xe82fffff` is `jal -1`. The sentence conflates two different words.
- **Evidence.** Recomputing `0xe80ffffc` with `a = 0x02` gives `0xe82ffffc`. (Merged with the documentation-critique `§16` finding.)
- **Suggested direction.** Fix to one consistent statement (`jal -4` = `0xe82ffffc`).

### X-10 (Low) — `§4` "no integer `le`/`ge` opcodes" is unscoped

- **Location.** `§4`: *"Integer `le`/`ge` have no opcodes"*.
- **Problem.** True only for the cond-producing C-type comparisons; the B-type integer branches `ble`/`bleu` exist.
- **Evidence.** `§5.1` register branches; the `§4` comparison paragraph.
- **Suggested direction.** Scope the statement to the comparison (cond-producing) families.

### X-11 (Low) — `tailcall_self`'s `a` missing from the 0-role enumeration

- **Location.** `§14`: *"the `b` of `ret`/`tailcall_self`/`trap`, the `a`/`b` of `trap`"*.
- **Problem.** `§8` requires `tailcall_self` `a`/`b` to be zero, but the enumeration omits its `a`.
- **Evidence.** `§8` return/termination paragraph.
- **Suggested direction.** Add `tailcall_self`'s `a` to the list.

### X-12 (Low) — Frame formula wrong for window-alias encodings

- **Location.** `§3.1`: *"`stack[fp + (n - 0x13)]`"*.
- **Problem.** Wrong for window-alias encodings when `x_count > 0`; the sibling spec gives `fp + x_count + reg` for `reg ≥ L`.
- **Evidence.** `Stilla LLIR Specification.md` §4.1.
- **Suggested direction.** Add the window-alias case (or explicitly defer to `Stilla LLIR Specification.md` §4.1).

### X-13 (Low) — `§14` states the tbz/tbnz bit-bound rejection twice

- **Location.** `§14`: *"a `tbz`/`tbnz` bit index ≥ 64"* and, later, *"a `tbz`/`tbnz` bit number above 63"*.
- **Problem.** The same rejection is stated in two clauses.
- **Evidence.** The `§14` bullet list.
- **Suggested direction.** Merge into one clause.

### X-14 (Low) — Two weak or mis-targeted cross-references

- **Location.** `§6`: *"residual dynamic destruction (LLIR Specification §6)"*; `§4`: the citation to the Core Language spec for numeric/trap rules.
- **Problem.** The residual dynamic-destruction content is in `Stilla LLIR Specification.md` §7, not §6; and the numeric/trap rules live in `Stilla Core Types & Ownership Specification.md` §16.3 and `Stilla Runtime Specification.md` §7.2, not in `Stilla Core Language Specification.md`.
- **Evidence.** The sibling specs.
- **Suggested direction.** Retarget both references.

---

## Completeness findings

### M-1 (Low) — `§10` immediate-window table gaps

- **Location.** `§10`: *"mask/unsigned fused immediate … `[0, 127]`"*.
- **Problem.** The unsigned-window row omits the C-type unsigned immediate comparisons `sltiu`/`sgtiu` (which `§7` states). Separately, `read_indexi`'s imm7 index extension is never stated in `§10` — it zero-extends.
- **Evidence.** `§7` immediate comparisons; `§4` inline-ID rows.
- **Suggested direction.** Add `sltiu`/`sgtiu` to the row and state `read_indexi`'s zero-extension.

### M-2 (Low) — `TypeKind` missing an eighth member

- **Location.** `§13`: *"`TypeKind = primitive | named | list | box | tuple | function | module`"*.
- **Problem.** The code mirror has an eighth member, `cleanup`, never mentioned and not covered by the `TypeDesc` bullet. This is confirmable only from `src/` (no sibling spec documents it).
- **Evidence.** Source mirror (secondary corroboration only).
- **Suggested direction.** Document `cleanup` (and its `TypeDesc` layout) or justify its omission as unreachable in serialized LLIR.

### M-3 (Low) — Undefined and absent side-table names

- **Location.** `§13`: *"`DestructureDesc { kind: DestructureKind …`"* and *"`a` an `OwnershipId`"*.
- **Problem.** `DestructureKind` and `OwnershipId` are referenced but never defined; `DestructibleKind` appears nowhere although the descriptor layout suggests it should.
- **Evidence.** The `§13` record block.
- **Suggested direction.** Define the enums, or cite the file where they are defined.

### M-4 (Low) — `PrimitiveId` order is not the serialized order

- **Location.** `§13`: *"`byte | bool | int32 | uint32 | int64 | uint64 | float32 | float64 | str | any | hostdata`"*.
- **Problem.** This order differs from the serialized dense enum order, so as written it does not document actual ID numbering.
- **Evidence.** The `§13` `TypeDesc` bullet; the source mirror (secondary corroboration).
- **Suggested direction.** Reorder to match the serialized enumeration, or label the list as illustrative rather than normative.

### M-5 (Low) — No citation to the Core Types & Ownership spec

- **Location.** Whole document.
- **Problem.** The document relies on the Copy/Unique/borrowed classification and on `ParamMode` but never cites `Stilla Core Types & Ownership Specification.md`.
- **Evidence.** `§3.2` ownership-discard rules; `§12`/`§13` `ParamMode` and ownership fields.
- **Suggested direction.** Add the cross-reference where ownership classification is invoked.

---

## Design refinements

### DES-1 (Medium) — `j` shares `jal`'s U prefix

- **Location.** `§9`/`§9.1`: *"prefix `11101` resolves its register field first"*.
- **Problem.** `j` shares `jal`'s U prefix `11101` and is disambiguated by the `a` field. This buys decoder complexity to save a prefix that is already free (`11100` is unassigned), and the "prefixes are pairwise disjoint" argument is presented as if no field inspection were needed.
- **Evidence.** `§2.1` decode order; `§9`/`§9.1`.
- **Suggested direction.** Either (A) give `j` prefix `11100` and delete `§9.1` — ripples through `§2.1`, `§2.2`, `§9`, `§9.1`, `§14`, `§16`, the code mirror, `table.json`, `interpreter-vm.md`, and `cheatsheet.md` — or (B) keep the sharing but state an explicit ordered decode algorithm.
- **Resolved.** The shared `11101` prefix is now described as a prefix whose match includes the `a` field (`ra` selects `jal`, `zero` selects `j`, any other value unclean), so decoding is a uniform prefix match; no encoding change, and the §16 golden words are unchanged.

### DES-2 (Medium) — The `10` top-level class is unexplained

- **Location.** `§2.1`: *"`10` | **reserved class**"*.
- **Problem.** Reserves a quarter of the encoding space with no stated purpose or escape discipline.
- **Evidence.** The `§2.1` classification table.
- **Suggested direction.** Add one sentence stating intent (reserve for a future format; decode must reject).

### DES-3 (Medium) — Immediate-branch asymmetry

- **Location.** `§5.2`.
- **Problem.** C-type has `slti`+`sgti`, but B-type has only `blti`/`bltiu`/`beqi`/`bnei`; an `a > k` branch therefore forces constant materialization even though 44 B codes are free.
- **Evidence.** `§5.2` versus the C-type immediate comparisons in `§7`.
- **Suggested direction.** Add `bgti`/`bgtiu` (with the same ripple list as any opcode addition), or document the omission as deliberate.

### DES-4 (Medium) — `ge`/`gt` operand-swap aliases overgeneralized

- **Location.** `§7`: *"`ge`/`gt` are operand-swap aliases"*.
- **Problem.** The swap identity is valid for floats but not integers (there is no integer `sle`), which contradicts `§4`'s `not(slt)` synthesis for integer `le`/`ge`.
- **Evidence.** `§7` swap paragraph versus `§4` `le`/`ge` synthesis and `§5.1` branch relations.
- **Suggested direction.** Scope the swap aliases to the float members and explain why branches need the non-strict `ble`/`bleu` directly. Keep C at 64.

### DES-5 (Low) — "Width-polymorphic position" is undefined

- **Location.** `§3.2`: *"two `zero` operands never provide a type in a width-polymorphic position"*.
- **Problem.** The rule names only `cmov` and never enumerates which operations are width-polymorphic or not rep-carrying, so it is not mechanically checkable.
- **Evidence.** `§3.2` versus the rep-carrying families of `§4`.
- **Suggested direction.** Define the property and list the ops it covers.

### DES-6 (Low) — The 7-bit register field is exactly saturated

- **Location.** `§3.1`: *"exactly 128 encodings"*.
- **Problem.** 109 frame registers + 16 temporaries + 3 specials = 128 exactly; any new register class forces a format revision.
- **Evidence.** `§3.1` range table and constants.
- **Suggested direction.** Note the saturation so future additions are understood to need an encoding change.

### DES-7 (Low) — `SwitchArm.target` declared `i32` but behaves modularly

- **Location.** `§12`: *"`SwitchArm { tag: u32, target: i32 }`"*.
- **Problem.** The target's semantics are modular (`+%`), so the sign is informational only.
- **Evidence.** The `§12` `SwitchArm` bullet; `§11`.
- **Suggested direction.** Declare `u32`, or annotate "sign representational only; addition is `+%`".

### DES-8 (Medium) — Reserved-hole rationale is inconsistent and unverifiable

- **Location.** `§4`/`§8`: *"alignment holes"* versus *"keeps encodings fixed"*; `§2.1`: *"reserved class"*.
- **Problem.** The E holes are called "alignment holes", the I selector 10 "keeps encodings fixed", the `10` class simply "reserved", and U uses 4 of 32 op values silently. The rationales differ and none is independently verifiable from the spec. The mirror names the real reasons: E codes 6–7 are the former `sext32`/`zext32` slots and I selector 10 is the former `result_take` slot.
- **Evidence.** `§4`, `§8`, `§2.1`; source mirror (secondary corroboration). (Merged with the documentation-critique "one canonical reservation discipline" finding.)
- **Suggested direction.** State a single reservation policy with a one-line rationale per hole (see DOC-7).

---

## Documentation refinements

### DOC-1 (High) — Inverted shift-masking examples

- **Location.** `§10`: *"`shl.i64 x, 32` is `x`; `shl.i32 x, 32` is 0"*.
- **Problem.** The examples are backwards. For `i32`, `32 mod 32 = 0`, so the result is `x`; for `i64`, `32 mod 64 = 32`, so the result is `x << 32`. This contradicts `§4`'s `(c mod W)` rule and `Stilla Runtime Specification.md` §7.2.
- **Evidence.** `§4` shift functions; `Stilla Runtime Specification.md` §7.2.
- **Suggested direction.** Swap the two clauses.
- **Resolved.** The `§10` example now reads *"`shl.i32 x, 32` is `x`; `shl.i64 x, 32` is `x << 32`"*, matching `§4`'s `(c mod W)` rule and `Stilla Runtime Specification.md` §7.2.

### DOC-2 (High) — Canonical-cell model diverges across documents

- **Location.** `§1`/`§4` canonical-cell statements: *"an `.i32` result sign-extends its low 32 bits… a `.u32` result zero-extends"*.
- **Problem.** `Stilla Runtime Specification.md` §7.2 says both `.i32` and `.u32` sign-extend; `interpreter-vm.md` §5 says both zero-extend (and is wrong for `.i32`). The Instruction Set matches the implementation (`interpreter_dispatch.zig`'s `canonicalIntResult`), so the other documents are the ones that should change.
- **Evidence.** The three documents; source `canonicalIntResult` (secondary corroboration).
- **Suggested direction.** Update `Stilla Runtime Specification.md` §7.2 and `interpreter-vm.md` §5 to the Instruction Set's model and add a forward reference from each to the canonical statement.
- **Resolved.** `Stilla Runtime Specification.md` §7.2 and `interpreter-vm.md` §5 now state the split model — `int32` sign-extends, `uint32` zero-extends — with forward references to the Instruction Set's canonical `§4` statement.

### DOC-3 (Low) — Section order does not match numeric logical-value order

- **Location.** `§4–§9` ordering `R / B / I / C / E / U`.
- **Problem.** The `§6` I-type section carries the numerically later logical values 235–265, so the section order does not track the logical-value order. The mismatch is intentional (grouping by format class), but it is easy to misread.
- **Evidence.** `§4` logical ranges.
- **Suggested direction.** Keep the order and add a compact format → section → encoded-selector range → logical-value range index near the top; do not renumber.

### DOC-4 (Medium) — Four models are restated 3–4 times and have already drifted

- **Location.** `§1`, `§3`, `§4`, `§5`, `§7`, `§10`, `§14`.
- **Problem.** The canonical-cell model, the `cond` lifetime rule, the immediate windows, and the `zero` typing rule are each restated several times, and the drift is already real (see X-2 and DOC-2).
- **Evidence.** The repeated passages.
- **Suggested direction.** Designate a single canonical home for each model and defer to it elsewhere.

### DOC-5 (Low) — The `trap` column under-specifies runtime-resolution traps

- **Location.** `§6` opcode tables (`module_ref`, `load_member`).
- **Problem.** Those traps resolve at runtime, but the `trap` column reads as a static property.
- **Evidence.** `§6` reference and aggregate tables.
- **Suggested direction.** Add a legend or caveat distinguishing static from runtime-resolution traps.

### DOC-6 (Low) — Ephemeral stage label in `§6`

- **Location.** `§6`: *"(Step 8, direct calls only, result not live across another call)"*.
- **Problem.** "Step 8" is an ephemeral stage label, which project conventions ban in specs.
- **Evidence.** `§6` I-type call-result paragraph.
- **Suggested direction.** Replace with the named stage (`llir_result_coalesce` / "result coalescing") in every file that uses the label.

### DOC-7 (Low) — `§4` contiguous-family rule has unlisted exceptions

- **Location.** `§4`: *"Every family is a **contiguous run**"*.
- **Problem.** The rule has exceptions it does not list: `abs` is a 4-member family in the order `i32, i64, f32, f64`; `clz`/`popcount` are width-only 2-member families; and the float-2 unary families break the integer-rep ordering.
- **Evidence.** `§4` rule versus `§8` family headers.
- **Suggested direction.** Restate as a default plus an explicit exception list.

### DOC-8 (Low) — Terminology overload

- **Location.** Throughout; `§2` calls the "**Behavior** column" normative while typed families use a "Comment" column.
- **Problem.** "hole" carries three meanings, "alias" three, "slot" several, "window" several; and the normative-table column is named inconsistently.
- **Evidence.** `§2`, `§4–§10`, `§14`.
- **Suggested direction.** Add a short terminology note and reword to "Behavior/Comment columns".

### DOC-9 (Low) — Version coherence and unnamed machine proof

- **Location.** Header: *"v10 encoding"*; `§16`: *"verified by the machine proof that generated this table"*.
- **Problem.** The "v10 encoding" and the serialized "binary format version" are never related, and `§16` asserts a machine proof without naming the artifact.
- **Evidence.** Header; `Stilla LLIR Specification.md` (format-version discussion); `§16`.
- **Suggested direction.** Add a sentence relating the encoding revision to the binary format version, and name the verifying test that generates the golden table.

### DOC-10 (Low) — Arm-tag uniqueness is a frontend invariant, not marked as such

- **Location.** `§12`: *"arm tags must be unique and must be variants of the union the scrutinee names"*.
- **Problem.** This is a frontend/lowering invariant (there are no slot types to check it against) but it is neither marked as non-validating nor listed in `§14`.
- **Evidence.** `§12` `SwitchDesc` bullet; `§14` trust-boundary list.
- **Suggested direction.** Mark it as a frontend invariant and list it accordingly.

### DOC-11 (Low) — `strings` blob terminology drift

- **Location.** `§13`: *"the program-owned `strings` blob"*.
- **Problem.** The sibling spec calls the same structure an "artifact-owned byte blob".
- **Evidence.** `Stilla LLIR Specification.md` §2.
- **Suggested direction.** Standardize on one term.

### DOC-12 (Low, note) — Over-engineering assessment

- No reinvented standard-library facility or speculative abstraction was found; the typed-opcode design actually reduces machinery (no canonicalization records, no masked staging cells). The one complexity-for-little-benefit spot is DES-1, and the `10` class is idle capacity. `cond` and the `zero` dual-role are forced by the encoding and well-motivated.

---

## Prioritized overhaul plan

Groups are ordered by risk: correctness fixes first, then cross-spec model alignment, then design decisions, then documentation hygiene. Every item names the files touched and how to verify the change. The document's own header contract already states that the code mirror and the document must be updated together; the generation source is `llir_opcodes.zig` (re-exported by `llir.zig`), which feeds `table.json`. **Any design change is therefore a synchronized spec-plus-mirror change**, and the verification for every opcode-affecting item is that the golden words in `§16` still decode/re-encode identically after the mirror is regenerated.

### Correctness fixes

1. **Resolve the `zero`-typing contradiction (X-2).** Edit `Stilla LLIR Instruction Set.md` `§3.2`/`§14`. Verify: the two sections state the same rule and no typed-dataflow check is implied. — **Resolved**
2. **Retarget the `§12.1` reference (X-1).** Edit `§1`; point at `Stilla LLIR Specification.md` §8.2 and `interpreter-vm.md` §1/§7 (or add the subsection and name `llir_opcodes.zig`). Verify: every `§N`/`§N.M` in the document resolves. — **Resolved**
3. **Fix the `§16` `jal`/`j` sentence (X-9).** Edit `§16` to make `jal -4` = `0xe82ffffc`. Verify by hand-decoding the word.
4. **Fix the `§10` shift examples (DOC-1).** Edit `§10`. Verify against `§4`'s `(c mod W)` and `Stilla Runtime Specification.md` §7.2. — **Resolved**
5. **Reconcile the canonical-cell model (DOC-2).** Edit `Stilla Runtime Specification.md` §7.2 and `interpreter-vm.md` §5 to match the Instruction Set, and add forward references. Verify against `interpreter_dispatch.zig`'s `canonicalIntResult` (secondary corroboration). — **Resolved**

### Cross-spec model alignment

6. **Align `MemberDesc.ref` and `store_member`'s operand (X-4, X-5).** Edit `§6` and `§12`; conform to `Stilla LLIR Specification.md` §2/§7. Verify against that spec's descriptor tables.
7. **Correct the fast-bank count and `strings` terminology (X-7, DOC-11).** Edit `§3.1.1` (19 cells) and `§13` (artifact-owned blob). Verify against `Stilla LLIR Specification.md` §2/§3.2.
8. **Add the missing ownership reference (M-5).** Edit `§3.2`/`§12` to cite `Stilla Core Types & Ownership Specification.md`. Verify: each ownership term used has a citation.
9. **Fix the weak cross-references (X-14).** Edit `§4` and `§6`. Verify: the cited sections contain the referenced content.

### Design decisions

10. **Decide the `j`/`jal` prefix (DES-1).** Choose option A or B; if A, apply the full ripple list across `Stilla LLIR Instruction Set.md`, the mirror, `table.json`, `interpreter-vm.md`, and `cheatsheet.md`. Verify: the decoder's field-discrimination logic matches `§9.1` (or `§9.1` is gone) and all golden words still round-trip. — **Resolved**
11. **Decide the immediate-branch asymmetry (DES-3).** Add `bgti`/`bgtiu` or document the omission. If added, update the mirror and golden table. Verify: `a > k` branches no longer require materialization, or the omission is stated.
12. **Scope the `ge`/`gt` swap aliases (DES-4).** Edit `§7` and reconcile with `§4`. Verify: integer `le`/`ge` synthesis and float swap behavior are both described once.
13. **Publish one reservation policy (DES-8, DOC-7).** Add a canonical paragraph (near `§2.2`) with per-hole rationale and an explicit contiguous-family exception list. Verify: every reserved hole and family exception has a one-line reason.
14. **Small design clarifications (DES-2, DES-5, DES-6, DES-7).** State the `10`-class intent; define "width-polymorphic position"; note register-field saturation; retype or annotate `SwitchArm.target`. Verify by re-reading `§2.1`, `§3.2`, `§3.1`, `§12`.

### Documentation hygiene

15. **Establish canonical homes and a format index (DOC-4, DOC-3).** Move each repeated model to one section and add a format → section → selector range → logical range index near the top. Verify: no rule appears in more than one normative location.
16. **Legend and label cleanup (DOC-5, DOC-6).** Add the trap-column legend and replace the stage label. Verify by grep for the banned label and for `trap`-column ambiguity.
17. **Terminology and version notes (DOC-8, DOC-9).** Add the terminology note and relate the encoding revision to the binary format version; name the verifying test. Verify: overloaded terms are defined once.
18. **Validation-list completeness (X-10, X-11, X-12, X-13, M-1, M-2, M-3, M-4).** Fill the `§10` table gaps, add `tailcall_self`'s `a`, fix the frame formula, deduplicate the tbz/tbnz clause, and document `cleanup`, the missing enums, and the `PrimitiveId` order. Verify against the mirror (secondary corroboration) and the sibling specs.

---

## Verified-correct coverage

The following were checked and passed.

- **Cross-reference resolution.** All internal `§N`/`§N.M` targets resolve except `§12.1` (X-1). Sibling targets invoked — `Stilla LLIR Specification.md` §2/§3.1/§5/§6/§8 and `Stilla Runtime Specification.md` §6.6/§7.2 — exist and support their claims.
- **Per-format counts.** R 112 + B 20 + I 31 + C 64 + E 38 + U 4 = 269, matching the declared logical total.
- **R 112** = 7 arithmetic families × 6 reps (42) + `madd`/`msub` × 6 (12) + 9 immediate families × 4 (36) + 6 widthless bitwise (`and`/`or`/`xor`/`andi`/`ori`/`xori`) + 16 untyped rows.
- **B 20** = 14 register branches (`beq` 3, `bne` 3, `blt` 4, `ble` 4) + 4 immediate (`blti`/`bltiu`/`beqi`/`bnei`) + 2 bit-test.
- **C 64** = 42 casts + 22 comparisons. **42 casts = 7×7−7** verified row-by-row; **22 comparisons** = `seq` 3 + `sne` 3 + `slt` 4 + `sle` 2 + scalar equality 4 + immediate 6.
- **E 38 = 44−6** = `neg` 6 + `abs` 4 + `clz` 2 + `popcount` 2 + five float-2 families × 2 (10) + 14 untyped transfer/lifecycle/control rows, across selectors 0–43 with holes 6–7 and 13/15/17/19.
- **I 31** = 4 references + 5 aggregate/destructure + 2 call/dispatch + 6 spill/slot + 2 jump/destruction + 12 move-wide.
- **Logical ranges.** R 1–112, B 113–132, C 133–196, E 197–234, I 235–265, U 266–269; `j`/`jal` are 266/267 as stated in `§9.1`.
- **`§16` golden words.** All 15 examples decode to the named opcode and re-encode to the same word (per the table's stated machine proof), including the negative-offset, imm7-signedness, and little-endian byte-order cases.
- **Register model arithmetic.** 128 encodings = 109 frame (`0x13–0x7f`) + 16 T (`0x03–0x12`) + 3 specials (`0x00–0x02`); the `frame_count_max = 109`, `temp_count = 16`, and `fast_reg_count = 0x13` constants are mutually consistent.

## Open items / not confirmable from the spec baseline

- **(a) E-family code layout.** Confirm the `neg` codes and the `clz`/`popcount` holes against the generated table and codec before treating the `§4`/`§8` counts as fully verified. The spec is internally consistent here, but the selector assignment is only corroborated by the mirror.
- **(b) Codec field discrimination.** Confirm the codec implements the `§9.1` `jal`/`j` `a`-field discrimination exactly (this matters most if DES-1 option A is rejected).
- **(c) Machine proof artifact.** The `§16` "machine proof" cannot be located from the document; its identity and invocation are unverifiable from the spec alone.
- **(d) Adjacent cross-spec tension (out of scope for this file).** `cheatsheet.md` states (around line 170) that `str` is Copy and never dropped, while elsewhere (around line 178) and in `Stilla LLIR Specification.md` §7 `str` is listed as a counted owner. This is a cross-spec tension to investigate separately.
