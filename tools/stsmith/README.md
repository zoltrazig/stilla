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
- boolean logic over comparisons and `!`, including short-circuit
  `and`/`or` statements
- wrapping integer arithmetic, truncating `div`/`rem`, bitwise `&`, and
  shifts with width-masked counts
- explicit `as` casts between every integer/float pair the generator uses
- named helper functions with parameters and calls; recursion via a
  count-down template and via `[h, ..t]` list patterns
- structs (one to three per module, with field names deliberately reused
  across structs), tuples, unions with exhaustive `match`, `list[T]`
  literals and patterns, and `any` payloads recovered through type-test
  `match` and `as`
- wildcard `_` patterns in every pattern position the generator can model:
  whole-arm catch-alls (the `classify` helper, collapsed union-arm tails,
  `Result`/`Option` matches), payload positions in union patterns
  (`U::V(_, q)`), tuple destructuring (`let (a, _) = ...`), and list heads
  (`[_, ..t]` in both statement matches and the list-recursion template)
- `str` constants, concatenation, and `builtin.str`/`builtin.print`

Every generated program additionally imports the derived standard-library
modules (`string`, `list`, `iter` — ordinary Stilla source the frontend
compiles like user code, unlike the host-bound `builtin` members) and
weaves a modeled subset of each into the statement stream:

- `string`: `len`/`is_empty`, `upper`/`lower`, `contains`,
  `starts_with`/`ends_with`, `index_of` (asserted through an `Option`
  match), `substring`, `repeat`, `trim`
- `list`: `lists.range` lists checked with `len` and `head` (including
  empty ranges), plus `contains`/`count`/`index_of` driven through an
  equality lambda
- `iter`: `fold` and `consume_fold` with an addition lambda; `try_fold`
  with an always-`Complete` or always-`Break` step, asserted through a
  `match` on the returned `iter.Result` with a `_` catch-all arm; and
  `fold_with` whose step models the borrowed context per the spec (the
  context equals the argument on every invocation). `iter.each` /
  `iter.consume_each` run with a `builtin.print` action (output only,
  like `builtin.print` statements, since a void action has no value to
  assert). The model result for every fold is the init plus the wrapping
  sum of the range elements

The generator emits only ASCII strings, so the stdlib's Unicode operations
(code-point indexing, case conversion, whitespace trimming) are byte-exact
in the generator's model; the needle for a search is a second str local, a
literal, or the empty string. Range lists are built fresh inside one
statement and fully consumed there (borrow-then-`head`), so no list value
needs to be tracked across statements. Importing these modules also puts
the stdlib's own recursive/generic bodies (`list.contains`-family,
`iter.fold_with`) through the frontend on every run.

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
- **`==` exists only for `byte/int32/uint32/float32/bool/str`**, so 64-bit
  equality is asserted as an `and`-joined `<=`/`>=` pair on a bound local.
  (This also exercises short-circuit `and` in statement position; the
  if-conversion miscompile that used to trip on it is fixed.)
- **Ordering comparisons do not type integer literals** from the other
  operand, so literals always appear on the right of a typed variable or
  inside a typed `==`.
- Float operands are kept small enough (`<= 2^12` for `float32`, `<= 2^26`
  for `float64`) that `+ - *` stay exactly representable.
- **`iter.fold_with` steps that read their context miscompute.** The spec
  (StdLib §7, `iter.st`) says the context is borrowed and passed unchanged to
  every step, so the generator models `c` as the argument constant; the
  current runtime instead returns wrong totals (`acc + c * x` over
  `range(1, 4)` with context 100 prints 1000, expected 600) while
  context-ignoring steps and `iter.each` (whose context is a function value)
  are correct. The generator keeps the spec model and emits context-reading
  steps rarely (low flavor weight, sampled again inside the flavor), so most
  seeds pass and seeds that do fail are flagging this implementation bug —
  per the project rule the spec governs, not the runtime.
- **Inlining a many-call statement can miscompile.** A statement that calls
  the same pure helper several times (e.g. an integer expression with two
  `f6()` calls, helpers that nest calls to other helpers, sampled with
  `--funcs 8`) can compute a wrong result after the inliner splices the
  helpers; a later `builtin.assert` then panics even though the identical
  program compiles and runs correctly with the optimizer's inlining step
  off. This is independent of `and`/`or` (a no-`and`/`or` program with the
  same shape fails) and reproduces on a build with none of the stsmith
  workarounds active, so it is a real frontend bug, not a generator-model
  gap; the generator flags it when the option mix reaches it.

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
