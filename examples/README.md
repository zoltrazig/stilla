# Examples

Small Stilla programs that compile with the frontend compiler and
demonstrate the language's constructs. Compile any of them to CFG IR with:

```sh
zig build run -- examples/<name>.st
```

| File | Demonstrates |
| --- | --- |
| [`fib.st`](fib.st) | recursive functions with self-calls, `if`/`else` expression bodies, recursion as the iteration mechanism, `builtin.print`/`builtin.str` syscalls |
| [`fib_tail_call.st`](fib_tail_call.st) | tail-recursive (accumulator-style) recursion, order-independent function references, explicit return types on recursive functions |
| [`match.st`](match.st) | union dispatch, `switch` terminators, and join phis |
| [`ownership.st`](ownership.st) | unique values, a user `drop` hook, borrow/move/drop |
| [`strings.st`](strings.st) | the `string` module: code-point lengths, concat/repeat, substring predicates, split/join, case conversion, trim; `builtin.assert` |
| [`floats.st`](floats.st) | the `math` module: float32 constants, IEEE 754 functions, rounding, min/max/abs, trigonometry, explicit `as` conversions (Core §16.3) |
| [`fold.st`](fold.st) | lists and the `iter` module: `builtin.range`, indexing, `fold` with int and tuple accumulators, `each` with a lambda, recursive `[head, ..tail]` patterns |
| [`box.st`](box.st) | ownership extraction with `builtin.box`/`peek`/`unbox`, explicit `move` at the unbox site |
| [`maps.st`](maps.st) | persistent-style `hashmap` operations, explicit generic specialization `::[K, V]`, tuple destructuring from `remove`, `Option` matching |
| [`generics.st`](generics.st) | polymorphic functions, explicit specialization `::[T]` and inference, one generic fn specialized to several types |

All examples are also compiled, optimized, and round-tripped by the
optimizer-corpus test in `src/frontend_tests.zig`, so they double as
regression tests for the whole pipeline.
