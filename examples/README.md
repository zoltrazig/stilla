# Examples

Small, self-contained Stilla programs that double as frontend regression
tests. Start with the fundamentals, then move to the type system, standard
library, and compiler-focused examples. Compile any file to CFG AIR with:

```sh
zig build run -- examples/<name>.st
```

## Fundamentals

| File | Demonstrates |
| --- | --- |
| [`basics.st`](basics.st) | immutable bindings, primitive values, arithmetic, comparisons, boolean short-circuiting, and `if` expressions |
| [`fib.st`](fib.st) | recursive functions, expression bodies, recursion as iteration, and `builtin.print`/`builtin.str` |
| [`functions.st`](functions.st) | function values, lambdas, higher-order calls, and order-independent declarations |

## Types and ownership

| File | Demonstrates |
| --- | --- |
| [`structs.st`](structs.st) | structs, field access, tuples, destructuring, and type aliases |
| [`match.st`](match.st) | union construction and exhaustive matching |
| [`any.st`](any.st) | `any` values, type-test patterns, wildcard fallback, and explicit `as` recovery |
| [`generics.st`](generics.st) | polymorphic functions, inferred and explicit specialization |
| [`ownership.st`](ownership.st) | unique values, a user `drop` hook, borrow, move, and drop |
| [`box.st`](box.st) | ownership extraction with `builtin.box`/`unbox` and explicit `move` |

## Standard library

| File | Demonstrates |
| --- | --- |
| [`strings.st`](strings.st) | code-point string operations, split/join, case conversion, and trim |
| [`floats.st`](floats.st) | float32 math, IEEE 754 helpers, and explicit numeric conversions |
| [`fold.st`](fold.st) | lists, recursive list patterns, `iter.fold`, `iter.each`, and `Option` |
| [`arrays.st`](arrays.st) | opaque arrays, borrowed reads, move-consuming updates, clone, and recursive traversal |
| [`maps.st`](maps.st) | opaque hash maps, move-consuming updates, clone, specialization, and `Option` |

## Compiler and optimizer

| File | Demonstrates |
| --- | --- |
| [`fib_tail_call.st`](fib_tail_call.st) | accumulator recursion and tail-call elimination |
| [`minmax.st`](minmax.st) | helper inlining inside a tail-call-eliminated loop |
| [`nest.st`](nest.st) | nested inlining and value/block renumbering |
| [`madd.st`](madd.st) | LLIR multiply-accumulate and immediate-index fusion |

Every example is compiled, optimized, and AIR round-tripped by the corpus test
in `frontend_cfg_passes_tests.zig`. Several are additionally used by the LLIR
lowering, validation, normalization, assembly, and binary corpus tests.
