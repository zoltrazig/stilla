# stsmith — a randomized Stilla test generator

`stsmith` mirrors Csmith's role for C: it generates random but
semantically-well-formed Stilla programs, seeded so any run reproduces the
same output byte-for-byte. Like Csmith's "paranoid" mode, every generated
program is self-checking: the generator computes the value each emitted
expression must produce and embeds `builtin.assert` checks for it. Running
the program under `stilla --run` then fails with a panic (exit 1) if the
Stilla runtime disagrees with the generator's arithmetic or typing model.

## Usage

```
zig build                       # builds zig-out/bin/stsmith
zig build stsmith -- --seed 42  # print a generated program to stdout
zig build stsmith -- --seed 42 --output gen.st
zig build stsmith-check -- --seed 42   # generate then run under stilla --run
```

`zig build stsmith-check` fails when the generated program panics or fails
to compile, so a nonzero exit means the generator produced something Stilla
disagrees with. Sweep seeds (e.g. `--seed 1 .. --seed 500`) to widen
coverage. The default (`seed 1`) passes; a minority of seeds still trip
unresolved stilla frontend bugs, which is exactly the signal a test
generator should surface — see "Stilla behaviors stsmith avoids".

### Options

All options precede the seed/positional-free flags and are optional:

- `--seed <u64>`      random seed; default 1. Same seed + same options ⇒
                      byte-identical output (tested by `zig build test`).
- `--statements <n>`  number of top-level statements in `main`; default 60.
- `--funcs <n>`       number of generated helper functions; default 5.
- `--max-depth <n>`   maximum recursion depth for recursive helpers; default 6.
- `--output <file>`   write the program here instead of stdout.

The generator prints a header comment recording the seed and options so any
regression can be reproduced exactly.

## What it exercises

Generated programs cover, per Csmith philosophy, only constructs whose
behavior the generator can model exactly (no UB in the generator's model):

- scalar literals of every primitive integer width plus `bool`; no float
  literals are ever printed (see float strategy below)
- wrapping integer arithmetic, truncating `div`/`rem`, bitwise `&`, and
  shifts with width-masked counts
- explicit `as` casts between every integer/float pair the generator uses
- named helper functions with parameters and calls; recursion via a
  count-down template and via `[h, ..t]` list patterns
- structs, tuples, unions with exhaustive `match`, `list[T]` literals and
  patterns, and `any` payloads recovered through type-test `match` and `as`
- `str` constants, concatenation, and `builtin.str`/`builtin.print`

The self-checks compare only integers, so no float round-trip text is ever
needed: floats are introduced as `(int_expr as float32|float64)`, combined
with `+ - * /` only when the generator's own IEEE model confirms the result
is exactly integral and representable, then projected back with
`as int32|int64` and compared to the expected integer literal.

### Stilla behaviors stsmith avoids (observed empirically)

`stsmith` is ultimately a test generator for the stilla frontend, and a few
current stilla behaviors would otherwise make the generator's model disagree
with the runtime. The generator shapes around them:

- **Bitwise `|` / `^` are only reliable on compile-time constants.** On any
  operand derived from a binding/param/cast the frontend folds them into `&`.
  stsmith therefore never emits them, and uses `&` (correct everywhere).
- **Function-body bitwise/`if` contexts.** Values bound from casts and
  function parameters behave specially inside `fn` bodies; stsmith keeps
  function bodies to arithmetic, `&`, shifts, and comparisons.
- **Short-circuit `and`/`or` in generated statements** can trip stilla's
  if-conversion ("optimizer invariant violation"); stsmith exercises boolean
  logic with comparisons and `!` and control flow with recursion and
  `match` instead.
- **`==` exists only for `byte/int32/uint32/float32/bool/str`**, so 64-bit
  equality is asserted as paired `<=`/`>=` on a bound local (a single
  `and`-joined comparison miscompiles).
- **Only one `struct` per module**: stilla resolves struct fields by name
  across the whole module, and fields of a second declared struct read
  garbage.
- **Ordering comparisons do not type integer literals** from the other
  operand, so literals always appear on the right of a typed variable or
  inside a typed `==`.
- Float operands are kept small enough (`<= 2^12` for `float32`, `<= 2^26`
  for `float64`) that `+ - *` stay exactly representable.

These are documented here so the generator's model stays honest: any
generated program that fails under `stilla --run` is either a real stilla
bug or a mismatch worth reporting — never silent UB.

## Reproducibility

Every random draw comes from a single deterministic PRNG (splitmix64) in a
fixed order, and no output depends on allocation layout or hash iteration
order. `zig build test` includes a unit test asserting that two generators
with the same seed produce identical bytes.

## Layout

- `rng.zig` — deterministic seeded PRNG and helpers
- `model.zig` — the generator's value/type model, mirroring Stilla's
  arithmetic and casts
- `gen.zig` — expression AST, printer, evaluator, and the program generator
- `main.zig` — CLI

`build.zig` exposes the `stsmith` and `stsmith-check` steps and wires this
module's tests into `zig build test`.
