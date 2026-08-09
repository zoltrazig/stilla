# Stilla Standard Library - v1.2 Draft

# 1. Scope

This document defines the Stilla standard library. It is a companion to the
Stilla v1.2 specifications: *Stilla Core Language Specification - v1.2 Draft*
(syntax and compile-time constraints) and *Stilla Runtime Specification -
v1.2 Draft* (execution behavior).

The standard library is a set of ordinary importable modules. Its types are
not language keywords, and its functions are ordinary module functions.

Module resolution follows Core §2.4; each module here may be
resolved as a standard-library module or provided by an embedding host
(Core §2.6).

The language core provides only the abstract sequence type `list[T]`:

- immutable;
- abstract storage (an implementation may use reference-counted sharing);
- supported directly by literals, patterns, indexing, and `for` iteration.

By contrast, the collection modules `array[T]` and `hashmap[K, V]` are not
abstract types. They are concrete implementations oriented toward a
contiguous-memory model, provided for performance:

- `array[T]` — a concrete dense sequence with contiguous element storage;
- `hashmap[K, V]` — a concrete hash table with contiguous bucket storage.

Because they are library types, no language change is required to alter or
replace them. An implementation or host may substitute alternative
representations, or add specialized collection modules, without touching the
language core.

The standard library provides:

```text
array[T]      concrete, contiguous-memory sequence
hashmap[K, V] concrete, contiguous-bucket hash table
math          common mathematical constants and functions
```

# 2. The `array` module

Conceptual interface (a conforming standard library must provide at least this):

```stilla
array.make[T]:
    fn(int64, move T) -> Array[T]

array.get[T]:
    fn(move Array[T], int64) -> T

array.len[T]:
    fn(move Array[T]) -> int64
```

- `array.make(length, init)` constructs a fresh `Array[T]` of the given
  length; every element is initialized to `init`. For affine `T`, `init`
  is a fresh value and transfers implicitly (Core §10.5).
- `Array[T]` is immutable after construction.
- `array.get(a, i)` reads element `i`. Invalid indexing produces a
  deterministic runtime trap (Runtime §7.2).
- For affine `T`, element access borrows, as with `list[T]` indexing
  (Core §11.5).
- `for (item in a)` iterates in index order. Iterating a borrowed array
  borrows its elements; `for (item in move a)` consumes the array.
- `Array[T]` is duplicable when `T` is duplicable and affine when `T` is
  affine, by the structural rule of Core §10.3.
- For affine `T`, `array.get` and `array.len` parameters are declared with
  `move`; call sites pass a plain argument to borrow (Core §10.6).

Usage:

```stilla
const array = import("array");

let a = array.make(4, 0);
let x = array.get(a, 2);
```

# 3. The `hashmap` module

Conceptual interface:

```stilla
hashmap.empty[K, V]:
    fn() -> HashMap[K, V]

hashmap.insert[K, V]:
    fn(move HashMap[K, V], move K, move V) -> HashMap[K, V]

hashmap.get[K, V]:
    fn(move HashMap[K, V], K) -> Option[V]

hashmap.contains[K, V]:
    fn(move HashMap[K, V], K) -> bool

hashmap.remove[K, V]:
    fn(move HashMap[K, V], K) -> tuple[HashMap[K, V], Option[V]]

hashmap.len[K, V]:
    fn(move HashMap[K, V]) -> int64
```

- A key type `K` must be duplicable and hashable.
- `builtin.hash` provides hashing for the primitive key types (Runtime §4.11).
- Insertion and removal are persistent-style: they consume the input map and
  return a new map. An affine map therefore transfers ownership as a whole
  and is never partially mutated. For duplicable instantiations, `move` may
  be omitted because copying is permitted (Core §10.6).
- `hashmap.get` returns the value as `Option[V]`. For affine `V`, the payload
  is borrowed for the lifetime of the operation, matching the borrow rule of
  Core §10.7. Its map parameter is declared with `move`;
  call sites pass a plain argument to borrow (Core §10.6).
- Iteration order is unspecified but stable within a single execution
  context. `for (kv in m)` iterates `tuple[K, V]` entries; `for (kv in move m)`
  consumes the map.

Usage:

```stilla
const hashmap = import("hashmap");

let m = hashmap.empty();
let m = hashmap.insert(m, "a", 1);
let m = hashmap.insert(m, "b", 2);

match (hashmap.get(m, "a")) {
    Option::Some(value) => builtin.print(builtin.str(value)),
    Option::None => builtin.print("missing")
};
```

# 4. The `math` module

The `math` module provides common mathematical constants and functions.

A conforming implementation must provide the `math` module. Its functions
cannot be written in Stilla source alone; they are normally implemented in the
host language or on top of `builtin` extensions.

Constants:

```stilla
math.pi:
    float64

math.e:
    float64

math.tau:
    float64

math.inf:
    float64

math.nan:
    float64
```

- `pi`, `e`, and `tau` are the correctly rounded `float64` approximations of
  the corresponding mathematical constants.
- `inf` is positive infinity; `nan` is a quiet NaN.
- Float results follow IEEE 754, including NaN and infinity. For example,
  `math.sqrt(-1.0)` is NaN and `math.ln(0.0)` is negative infinity. The
  deterministic trap rules of Runtime §7.2 concern integer
  operations, invalid indexing, and numeric conversion; a conforming
  implementation that traps on IEEE 754 NaN or infinity results instead must
  document the deviation.
- Results are deterministic within a single execution context. Cross-platform
  bit-exactness is not required.

Functions:

```stilla
math.sqrt:
    fn(float64) -> float64

math.pow:
    fn(float64, float64) -> float64

math.exp:
    fn(float64) -> float64

math.ln:
    fn(float64) -> float64

math.log2:
    fn(float64) -> float64

math.log10:
    fn(float64) -> float64

math.sin:
    fn(float64) -> float64

math.cos:
    fn(float64) -> float64

math.tan:
    fn(float64) -> float64

math.asin:
    fn(float64) -> float64

math.acos:
    fn(float64) -> float64

math.atan:
    fn(float64) -> float64

math.atan2:
    fn(float64, float64) -> float64

math.floor:
    fn(float64) -> float64

math.ceil:
    fn(float64) -> float64

math.round:
    fn(float64) -> float64

math.trunc:
    fn(float64) -> float64

math.abs:
    fn(float64) -> float64

math.min:
    fn(float64, float64) -> float64

math.max:
    fn(float64, float64) -> float64
```

- `math.pow(x, y)` computes `x` raised to the power `y`.
- `math.atan2(y, x)` takes the y-coordinate first, matching IEEE 754 `atan2`.
- `math.round` rounds to the nearest integer value, with ties away from zero.
- `math.floor`, `math.ceil`, and `math.trunc` return `float64` values with the
  corresponding integral value.
- `math.abs` returns the absolute value of a `float64`. Integer absolute value
  is not provided: it is expressible directly in source, and negating the
  minimum `int64` traps (integer overflow, Runtime §7.2).
- `math.min` and `math.max` follow IEEE 754 `fmin` and `fmax` semantics.
- `math.asin` and `math.acos` accept arguments in the range `[-1.0, 1.0]`.
  Out-of-domain arguments produce NaN per IEEE 754 (or a documented trap, as
  above).
- There is no implicit numeric conversion in Stilla; integer arguments must be
  converted explicitly with `as` (Core §16.3).

Usage:

```stilla
const math = import("math");

let radius = 2.0;
let area = math.pi * math.pow(radius, 2.0);
let diagonal = math.sqrt(3.0 * 3.0 + 4.0 * 4.0);
```
