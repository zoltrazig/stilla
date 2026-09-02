# Stilla v1.3 Cheat Sheet

> A fast-reference companion to the specification suite. Normative detail and
> edge cases live in the specs; this sheet is for recall and quick lookups.

## Pipeline at a glance

```text
Stilla .st → Phase 1 module graph → Phase 2 type check & ownership
   → Phase 3 CFG lowering → AIR (validated SSA CFG)
   → mid-level optimizer (Pass 8) → drop lowering
   → LLIR builder + allocator + fusion + validation → 4-byte LLIR image
   → runtime / VM
```

- **AIR** = canonical SSA CFG (ownership explicit). **LLIR** = read-only fixed-width projection (R/B/I/C/E/U, 4 bytes).
- Specs: [Core Language](Stilla%20Core%20Language%20Specification.md), [Core Types & Ownership](Stilla%20Core%20Types%20%26%20Ownership%20Specification.md), [Core Static Semantics](Stilla%20Core%20Static%20Semantics.md), [Runtime](Stilla%20Runtime%20Specification.md), [AIR](air.md), [LLIR Spec](Stilla%20LLIR%20Specification.md), [LLIR Instruction Set](Stilla%20LLIR%20Instruction%20Set.md), [Standard Library](Stilla%20Standard%20Library.md).

## Module & import

- Every `.st` file is **one implicit immutable module struct**.
- `const m = import("spec");` — `import` only as a module-level `const` initializer.
- `m.member` is ordinary `value.member` access. No runtime `module` type, no implicit namespace.

```stilla
const builtin = import("builtin");
const array = import("array");
```

## Bindings

- `let x = expr;` — local binding (immutable).
- `const X = expr;` — module constant. Initializers evaluate in declaration order.
- A fresh *Unique* value may be used directly; an existing owner needs `move`.

## Functions

```stilla
fn add(a: int32, b: int32) -> int32 { a + b }
const f = fn(move acc: int32, borrow x: int32) -> int32 { acc + x }
```

- Monomorphic, **non-capturing** (no closures). **No implicit receiver**, no methods, no associated functions.
- First-class monomorphic values; generics are compile-time templates.
- Order-independent within a module; recursion allowed. Every function and lambda **declares its return type** (`-> void` when it returns nothing, `-> never` when it never returns normally); there is no inference.

## Types

| Kind | Syntax |
| --- | --- |
| primitives | `int32` `uint32` `int64` `uint64` `float32` `float64` `bool` `str` `byte` |
| top / bottom | `any` `never`; also `void`, `hostdata`, `module` |
| nominal | `struct Name { a: T, … }` · `union Name[T] { V(T), … }` · `opaque type Name[params];` |
| structural | `list[T]` · `box[T]` · `tuple[T, U]` · `fn(T, …) -> T` |

- `opaque type` is declared only in stdlib / host module interfaces; *Unique* by declaration.
- Every tagged value type except `hostdata` coerces to `any`; `never` has no values and coerces to every type. Recovering an `any` payload requires explicit `as` or `match`.

## Ownership

- ***Copy*** — implicitly copyable; `drop` is a no-op. ***Unique*** — used at most once, dropped exactly once.

```stilla
let a = open_file("a.txt");      // Unique owner
inspect(a);                      // borrow
inspect(a);
consume(move a);                 // ownership transfer → a dead
drop file;                       // explicit destruction
let b = builtin.box(Tree::Empty); // fresh Unique transfers implicitly
let c = builtin.box(move b);      // existing owner needs move
```

| op | effect |
| --- | --- |
| `borrow x` | non-owning view; ownership unchanged |
| `move x` | ownership transfer; source dead |
| `copy x` | copy—only for *Copy* values |
| `drop x;` | deterministic destruction at this point |

- **Parameter modes**: `T` (plain, *Copy* by value) · `borrow T` (non-owning) · `move T` (ownership-taking).

## Control flow

```stilla
if (c) { … } else { … }
match (v) { Pattern => expr, _ => expr }        // non-consuming
match (move v) { … }                            // consuming
a and b    // b evaluated only if a is true
a or b     // b evaluated only if a is false
```

- Repetition is recursion (optimized to loops / `tailcall`).
- `and`/`or` short-circuit (real control flow, not operations).

## Patterns

| pattern | matches |
| --- | --- |
| `name` | binds value (identifier) |
| `(a, b)` | tuple |
| `Name{ field: p }` | struct |
| `Variant(p)` / `Variant` | union |
| `[a, b]` / `[head, ..tail]` | list (exact / with rest) |
| `x as T` (type-test) | `any` tag test |
| `_` | wildcard (required for open tag spaces) |

## Member access / generics

- `value.member` — runtime access. `Type::Variant` — union variant. `x::[Types]` — explicit specialization. `using builtin.Option;` — brings a type member into scope.

## Operators & numeric behavior

| op | notes |
| --- | --- |
| `+ - * / %` | int wraps mod 2³² (32-bit) / mod 2⁶⁴ (`int64`/`uint64`); never traps on overflow; `div`/`rem` trap on 0; `int32` `div` wraps on `min / -1` (never traps); `int64` `div` traps on `min / -1`; `min % -1 = 0` |
| `& \| ^` | bitwise on the raw operand-width pattern (never traps) |
| `<< >>` | shift count masked mod 32 (32-bit) / mod 64 (`int64`/`uint64`); `>>` arithmetic on `int32`/`int64`, logical on `uint32`/`uint64` |
| `== != < <= > >=` | compare |
| `and` `or` `not` | `!` is `not` |
| `math.min` `math.max` | `fmin`/`fmax` over `float32` (NaN propagates; `fmin(-0,+0)=-0`) — standard-library functions, not operators |
| `math.abs` | `float32` `fabs` (clears the sign bit) — standard-library function, not an operator |
| `as` | `num_cast`: every non-identity pair of `byte`/`int32`/`uint32`/`int64`/`uint64`/`float32`/`float64` (42 casts); never traps (round-nearest-even / truncate; float→int saturates, `int64`/`uint64` targets to `[int64_min, int64_max]` / `[0, 2⁶⁴)`); `int64 ↔ uint64` reinterprets the cell |
| `+ (str)` | `str + str` concat (`concat`) |

- `float32` = IEEE 754 binary32; `float64` = IEEE 754 binary64 (NaN payload round-trips losslessly); equality: NaN ≠ everything; `+0.0 == -0.0`.
- No implicit numeric conversion; explicit `as`. No `byte` literal — write `104 as byte`. Integer literals default `int32`, float literals `float32`; a literal in an explicit integer/float type context — a typed binding, an argument, a return, or the other side of a numeric binary operator — is typed at that type's width (a `uint64` literal covers the full range, `-` is unary).

## builtin / stdlib

```stilla
builtin.print(str)                                  // print
builtin.str::[T](x)                                 // to string (byte/int32/uint32/int64/uint64/float32/float64/bool/str)
builtin.box::[T](move T) -> box[T]                  // wrap
builtin.unbox::[T](move box[T]) -> T                // own contained value
builtin.panic(str) -> never                         // terminate context
builtin.assert(bool, str)                           // panic on false
builtin.hash::[T](T) -> int32                       // deterministic hash
list.len::[T](borrow list[T]) -> int32              // length
list.range(int32, int32) -> list[int32]             // inclusive [start, end]
```

- **Modules**: `array` (`make/len/get/set/clone`) · `hashmap` (`empty/insert/get/contains/remove/len/clone`) · `math` (`sqrt/pow/…`) · `string` (`len/split/join/…`) · `iter` (`each/fold/try_fold/consume_*`) · `list` (`len/range/is_empty/contains/count/index_of/head`).
- `array`/`hashmap` are **host-backed opaque nominal** (*Unique*); consuming ops (`set`/`insert`/`remove`) take `move` and return the updated value (in-place mutation allowed).
- `Option[T]` = `builtin`'s type member, brought in with `using builtin.Option;`.

## Evaluation order & destruction

- Subexpressions evaluate **left to right, exactly once** (callee before args, base before member, operands left to right). `and`/`or` short-circuit.
- **Destruction**: *Unique* locals at scope end in **reverse creation order**; struct = `drop` hook → reverse field declaration; tuple = reverse; list = reverse index; union = active variant only; temporaries at full-expression end (reverse creation); explicit `drop x;`.
- *Maybe-Unique* bindings are resolved at each conditional construct's join into unconditional edge drops, with no runtime ownership state.

## Panic & traps

- No exception/destructor unwinding: a `panic` (`never`) or trap terminates the context immediately — no pending drops, no module teardown, control to the host.
- Traps: `div`/`rem` by 0, `int64_min/-1` division, invalid `any` recover/cast, invalid list element read (short list), invalid UTF-8/Unicode decode. Float→int conversion **never traps** (NaN → 0, saturates). `int32_min/-1` division wraps and never traps.

## Five central rules

1. **Namespace** — runtime member access is `value.member`; modules restricted to module scope.
2. **Construction** — types describe values; ordinary functions construct them; no special constructor.
3. **Ownership** — borrowing never transfers ownership; moving always transfers.
4. **Generic** — generics are compile-time templates, concrete before runtime.
5. **Termination** — normal flow destroys deterministically; panic terminates without unwinding.

## AIR (canonical SSA CFG)

- Three-address, single-result; n-ary only for `construct`/`call`/`syscall`/`phi`; `select` is the sole ternary.
- Ownership explicit: `copy`/`borrow`/`move`/`drop`; conditional ownership is resolved with edge drops at frontend joins.
- Effect classes: `pure`, `pure but may trap`, `side-effecting`. Only pure ops are folded/CSE'd/hoisted.
- Drop lowering expands struct/tuple/box/union drops and keeps opaque host types, `hostdata`, `list`, and `any` as runtime-dispatched drops — `str` is *Copy* and is never dropped (the counted `release` records for RC containers are an LLIR-level detail).

## LLIR (4-byte fixed width)

- **Formats**: `R` (three registers) · `B` (compare/branch) · `I` (register + imm16) · `C`/`E` (two registers) · `U` (register + imm20); typed opcodes carry numeric width and signedness.
- **Registers**: `F0–F108` (`0x13–0x7f`) frame cells · `zero` (`0x00`) · `cond` (`0x01`) · `ra` (`0x02`, a reserved call-convention hole) · `T0–T15` (`0x03–0x12`) volatile temps. The zero/cond/ra/T encodings index the VM's `[19]` fast bank directly. The top `window_count` encodings are the **window aliases** — the header reserve plus the output aliases `O(0)..O(O-1)` — with the register budget `f_count + window_count ≤ 109`.
- **Frame**: `[fp-3,fp)` header · `[fp,fp+L)` F cells (`L = f_count ≤ 109`) · `[fp+L,fp+L+X)` X spill cells (`x_count ≤ 65536`, imm16-addressed, never register-addressed) · `[..,+W)` output window, where each call reserves a three-cell `{saved_fp, saved_fn, saved_ra}` header plus `A=max(parameter_count,result_count)` value cells. Cells are raw `uint64`; operand types come from typed opcodes and descriptors.
- Callee params alias the caller's output-window cells (`fp=sp-A`); one `slot_*` record per parameter at its absolute window offset (`slot_borrow`/`slot_move`/`slot_retain`/`slot_copy`) — no elision; argument transfer is move-based. The window is register-addressable (v10, Itanium-style overlap): a non-void call's result is published into the caller register `F(L+3+O-A)` and consumed by exactly one `take dst, F(L+3+O-A)` at the fallthrough (a `zero` destination discards; the source register is cleared) — or read in place with no take when the lowering coalesced the result onto the alias (Step 8, direct calls only, result not live across another call).
- **Lifecycle explicit in the image**: counted owners (`str`/`list[T]`/`box[T]`) `release`/`copy_retain` (fused `replace_copy`/`replace_move`/`release_ret`); residual `drop src, DropDescId` for `any`/`hostdata`/opaque only; spill staging `spill_take`/`spill_put` under F pressure.
