# Stilla Standard Library

> **Version:** v1.3 Draft

# 1. Scope

This document defines the Stilla standard library. It is a companion to the
Stilla v1.3 specifications: *Stilla Core Language Specification*
(syntax and compile-time constraints) and *Stilla Runtime Specification*
(execution behavior).

The standard library is a set of ordinary importable modules. Its types are
not language keywords, and its functions are ordinary module functions.

Module resolution follows Core §2.4; each module here may be
resolved as a standard-library module or provided by an embedding host
(Core §2.6).

The language core provides only the abstract sequence type `list[T]`:

- immutable;
- abstract storage (an implementation may use reference-counted sharing);
- supported directly by literals, patterns, and indexing; iteration is
  provided by the `iter` module (§7).

By contrast, the collection modules `array[T]` and `hashmap[K, V]` are not
abstract types. They are concrete host-provided implementations whose values
are opaque `hostdata` payloads (§6), oriented toward a contiguous-memory
model, provided for performance:

- `array[T]` — a concrete dense sequence with contiguous element storage;
- `hashmap[K, V]` — a concrete hash table with contiguous bucket storage.

Because they are library types, no language change is required to alter or
replace them. An implementation or host may substitute alternative
representations, or add specialized collection modules, without touching the
language core.

Because a container value is a unique `hostdata` payload (Core §11.7),
`Array[T]` and `HashMap[K, V]` are always unique, regardless of the element
type (§2, §3).

The standard library provides:

```text
builtin       required core interface: print, str, len, range, box, peek,
              unbox, panic, assert, hash (Runtime §4)
array[T]      hostdata-backed contiguous-memory sequence
hashmap[K, V] hostdata-backed contiguous-bucket hash table
math          common mathematical constants and functions
string        Unicode text operations and conversions
iter          list combinators: each, each_with, fold, fold_with, consume_each,
              consume_each_with, consume_fold, consume_fold_with, try_fold,
              try_fold_with
```

Every module here, including `builtin`, is imported like any other module
(Core §2.4, Core §3):

```stilla
const builtin = import("builtin");
const array = import("array");
```

# 2. The `array` module

Conceptual interface (a conforming standard library must provide at least this):

```stilla
array.make[T]:
    fn(int32, move T) -> Array[T]

array.get[T]:
    fn(move Array[T], int32) -> T

array.len[T]:
    fn(move Array[T]) -> int32
```

- `Array[T]` is a `hostdata` payload (§6): the module functions are host
  bindings that construct, read, and destroy an opaque, host-defined
  contiguous buffer. Stilla never inspects the payload.
- `array.make(length, init)` constructs a fresh `Array[T]` of the given
  length; every element is initialized to `init`. For unique `T`, `init`
  is a fresh value and transfers implicitly (Core §10.5).
- `Array[T]` is immutable after construction.
- `array.get(a, i)` reads element `i`, borrowing the array's payload for the
  operation. Invalid indexing produces a deterministic runtime trap
  (Runtime §7.2).
- For unique `T`, element access borrows, as with `list[T]` indexing
  (Core §11.5).
- Wholesale iteration over `Array[T]` is host-provided: `for` is not a
  core-language construct (Core §13.5), and the `iter` combinators of §7
  operate on `list[T]`, not on `Array[T]`.
- `Array[T]` is always unique: it wraps an opaque `hostdata` payload, and
  `hostdata` is not Copy (§6, Core §11.7). It is not Copy even
  when `T` is Copy.
- `array.get` and `array.len` parameters are declared with `move`; call
  sites pass a plain argument to borrow (Core §10.6).

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
    fn(move HashMap[K, V]) -> int32
```

- `HashMap[K, V]` is a `hostdata` payload (§6): the module functions are
  host bindings that construct, read, transform, and destroy an opaque,
  host-defined contiguous-bucket table. Stilla never inspects the payload.
- A key type `K` must be Copy and hashable.
- `builtin.hash` provides hashing for the primitive key types (Runtime §4.9).
- Insertion and removal are persistent-style: they consume the input map and
  return a new map. Because the map is always unique, ownership transfers as
  a whole and the map is never partially mutated.
- `hashmap.get` returns the value as `Option[V]`. For unique `V`, the payload
  is borrowed for the lifetime of the operation, matching the borrow rule of
  Core §10.7. Its map parameter is declared with `move`;
  call sites pass a plain argument to borrow (Core §10.6).
- Iteration order is unspecified but stable within a single execution
  context. Wholesale iteration over `HashMap[K, V]` is host-provided:
  `for` is not a core-language construct (Core §13.5), and the `iter`
  combinators of §7 operate on `list[T]`, not on `HashMap[K, V]`.

Usage:

```stilla
const hashmap = import("hashmap");
const builtin = import("builtin");

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
    float32

math.e:
    float32

math.tau:
    float32

math.inf:
    float32

math.nan:
    float32
```

- `pi`, `e`, and `tau` are the correctly rounded `float32` approximations of
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
    fn(float32) -> float32

math.pow:
    fn(float32, float32) -> float32

math.exp:
    fn(float32) -> float32

math.ln:
    fn(float32) -> float32

math.log2:
    fn(float32) -> float32

math.log10:
    fn(float32) -> float32

math.sin:
    fn(float32) -> float32

math.cos:
    fn(float32) -> float32

math.tan:
    fn(float32) -> float32

math.asin:
    fn(float32) -> float32

math.acos:
    fn(float32) -> float32

math.atan:
    fn(float32) -> float32

math.atan2:
    fn(float32, float32) -> float32

math.floor:
    fn(float32) -> float32

math.ceil:
    fn(float32) -> float32

math.round:
    fn(float32) -> float32

math.trunc:
    fn(float32) -> float32

math.abs:
    fn(float32) -> float32

math.min:
    fn(float32, float32) -> float32

math.max:
    fn(float32, float32) -> float32
```

- `math.pow(x, y)` computes `x` raised to the power `y`.
- `math.atan2(y, x)` takes the y-coordinate first, matching IEEE 754 `atan2`.
- `math.round` rounds to the nearest integer value, with ties away from zero.
- `math.floor`, `math.ceil`, and `math.trunc` return `float32` values with the
  corresponding integral value.
- `math.abs` returns the absolute value of a `float32`. Integer absolute value
  is not provided: it is expressible directly in source, and negating the
  minimum `int32` traps (integer overflow, Runtime §7.2).
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

# 5. The `string` module

The `string` module provides Unicode text operations and conversions
between strings and sequences of bytes or code points.

A conforming implementation must provide the `string` module. Its functions
cannot be written in Stilla source alone; they are normally implemented in the
host language or on top of `builtin` extensions.

Strings are sequences of Unicode code points (Unicode scalar values). All text
processing in this module operates on code points; byte offsets are never
exposed.

Conceptual interface (a conforming standard library must provide at least this):

```stilla
string.len:
    fn(str) -> int32

string.is_empty:
    fn(str) -> bool

string.concat:
    fn(str, str) -> str

string.contains:
    fn(str, str) -> bool

string.starts_with:
    fn(str, str) -> bool

string.ends_with:
    fn(str, str) -> bool

string.index_of:
    fn(str, str) -> Option[int32]

string.substring:
    fn(str, int32, int32) -> str

string.split:
    fn(str, str) -> list[str]

string.join:
    fn(list[str], str) -> str

string.trim:
    fn(str) -> str

string.lower:
    fn(str) -> str

string.upper:
    fn(str) -> str

string.replace:
    fn(str, str, str) -> str

string.repeat:
    fn(str, int32) -> str

string.to_utf8:
    fn(str) -> list[byte]

string.from_utf8:
    fn(list[byte]) -> str

string.to_codepoints:
    fn(str) -> list[uint32]

string.from_codepoints:
    fn(list[uint32]) -> str
```

- `string.len(s)` returns the number of code points in `s`, not the number of
  bytes.
- `string.substring(s, start, end)` returns the substring from code-point
  index `start` up to but not including `end`, per the half-open interval
  `[start, end)`. Out-of-range offsets produce a deterministic runtime trap
  (Runtime §7.2).
- `string.split(s, sep)` splits `s` at every occurrence of `sep`. If `sep` is
  empty, the result is a list of single-code-point strings. An empty `s`
  splits to `[""]`.
- `string.join(parts, sep)` concatenates the strings in `parts` separated by
  `sep`. Joining an empty list yields the empty string.
- `string.index_of(s, needle)` returns the code-point index of the first
  occurrence of `needle`, or `Option::None` if there is no occurrence. An
  empty `needle` matches at index 0.
- `string.replace(s, from, to)` replaces every non-overlapping occurrence of
  `from` in `s` with `to`. An empty `from` inserts `to` between every
  code point (and at both ends).
- `string.lower` and `string.upper` perform full Unicode default case
  conversion, which may change the length of the string (for example,
  `"İ".lower`).
- `string.trim(s)` removes leading and trailing Unicode whitespace.
- `string.to_utf8(s)` encodes `s` as a UTF-8 byte sequence.
  `string.from_utf8(bytes)` decodes a UTF-8 byte sequence; invalid UTF-8
  produces a deterministic runtime trap (Runtime §7.2).
- `string.to_codepoints(s)` yields the code points of `s`.
  `string.from_codepoints(cps)` accepts any `uint32` value that is a Unicode
  scalar value; surrogates and values above `0x10FFFF` produce a
  deterministic runtime trap (Runtime §7.2).
- All functions are deterministic within a single execution context.

Usage:

```stilla
const string = import("string");

let s = string.from_utf8([104, 101, 108, 108, 111]);  // "hello"
let parts = string.split(s, "l");                     // ["he", "", "o"]
let joined = string.join(parts, "-");                 // "he--o"
let bytes = string.to_utf8(s);                        // [104, 101, 108, 108, 111]
let cps = string.to_codepoints(s);                    // [104, 101, 108, 108, 111]
let upper = string.upper(s);                          // "HELLO"
```

# 6. The `hostdata` type

`hostdata` is not a standard-library module. It is a core primitive type
(Core §11.7) carrying an **opaque, host-defined payload**. It is covered
here because the `array` (§2) and `hashmap` (§3) containers are implemented
on top of it.

- Only the host constructs `hostdata` values, through host functions and
  module members (Core §2.6, Runtime §3.1). The `array` and `hashmap`
  module functions are host bindings that construct, read, transform, and
  destroy such payloads; Stilla never constructs or inspects one itself.
- An `Array[T]` or `HashMap[K, V]` value is itself a `hostdata` payload.
  Stilla therefore defines no operation on the container other than moving,
  borrowing, storing, passing along, and handing to the host (Core §11.7),
  and the module functions of §2 and §3 are its only access path.
- `hostdata` is unique (Core §11.7). Because a container is a `hostdata`
  payload, `Array[T]` and `HashMap[K, V]` are always unique, regardless of
  `T` (§2, §3).
- Containers of `hostdata` as elements — `list[hostdata]`,
  `box[hostdata]`, `array[hostdata]`, `hashmap[K, hostdata]`, and
  `tuple[..., hostdata]` — are unique by the structural rule of Core §10.3.
  A `hostdata` value can therefore be stored as an element of a container,
  but the container itself is a separate `hostdata` payload.
- `builtin.str` and `builtin.hash` do not accept `hostdata`, so a `hostdata`
  value cannot be converted to text or used as a `hashmap` key.
- Destruction of a `hostdata` value — automatic (Core §9.5), explicit `drop`
  (Core §9.4), or container destruction — returns the opaque payload to the
  host for disposal (Runtime §3.4, §7.3); this is host cleanup, not execution
  of a Stilla `drop` hook.

Usage:

```stilla
const array = import("array");
const hashmap = import("hashmap");

let a = array.make(4, 0);              // Array[int32], a hostdata payload
let x = array.get(a, 2);               // host binding reads the payload
let b = move a;                        // ownership transfers as a whole

let m = hashmap.empty();
let m = hashmap.insert(m, "k", 1);     // HashMap[str, int32], a hostdata payload
let v = hashmap.get(m, "k");           // Option[int32]
```

# 7. The `iter` module

The `iter` module provides the list combinators `each`, `each_with`, `fold`,
`fold_with`, `consume_each`, `consume_each_with`, `consume_fold`,
`consume_fold_with`, `try_fold`, and `try_fold_with`. Stilla has no closures
(Core §18): a function or lambda cannot capture enclosing local bindings.
Each combinator therefore accepts the per-element operation as an ordinary
function-value parameter — a monomorphic, non-capturing method (Core §12).
The `*_with` variants additionally take a **context** value that is borrowed
and passed to every invocation of the operation; context threading is the
language's compensation for the absence of closures. The `consume_*`
variants consume the list and move each element into the operation.

The module is ordinary Stilla source: `fold_with` and `consume_fold_with`
are the recursion kernels (matching `[]` / `[head, ..tail]` and calling the
operation value), and every other combinator is derived from them. The
`try_fold*` functions are the exception — they are host bindings, because
their bodies need generic union-payload substitution (`Result[S, R]`'s
payload types are the type parameters) which the structural frontend
defers.

The module defines the short-circuiting fold result type:

```stilla
union Result[S, R] {
    Complete(S),
    Break(R)
}
```

A step returns `Complete(s)` to continue with accumulator `s`, or
`Break(r)` to stop.

Conceptual interface (a conforming standard library must provide at least this):

```stilla
iter.each[T]:
    fn(
        borrow values: list[T],
        action: fn(borrow T) -> void
    ) -> void

iter.each_with[T, C]:
    fn(
        borrow values: list[T],
        borrow context: C,
        action: fn(borrow C, borrow T) -> void
    ) -> void

iter.fold[T, S]:
    fn(
        borrow values: list[T],
        move state: S,
        step: fn(move S, borrow T) -> S
    ) -> S

iter.fold_with[T, S, C]:
    fn(
        borrow values: list[T],
        move state: S,
        borrow context: C,
        step: fn(move S, borrow C, borrow T) -> S
    ) -> S

iter.consume_each[T]:
    fn(
        move values: list[T],
        action: fn(move T) -> void
    ) -> void

iter.consume_each_with[T, C]:
    fn(
        move values: list[T],
        borrow context: C,
        action: fn(borrow C, move T) -> void
    ) -> void

iter.consume_fold[T, S]:
    fn(
        move values: list[T],
        move state: S,
        step: fn(move S, move T) -> S
    ) -> S

iter.consume_fold_with[T, S, C]:
    fn(
        move values: list[T],
        move state: S,
        borrow context: C,
        step: fn(move S, borrow C, move T) -> S
    ) -> S

iter.try_fold[T, S, R]:
    fn(
        borrow values: list[T],
        move state: S,
        step: fn(move S, borrow T) -> Result[S, R]
    ) -> Result[S, R]

iter.try_fold_with[T, S, R, C]:
    fn(
        borrow values: list[T],
        move state: S,
        borrow context: C,
        step: fn(move S, borrow C, borrow T) -> Result[S, R]
    ) -> Result[S, R]
```

- `iter.each(values, action)` invokes `action(item)` once per element in
  increasing index order (Runtime §5) and returns `void`. The list is
  borrowed, so its elements are borrowed and no ownership transfers.
- `iter.each_with(values, context, action)` is `each` with a borrowed
  `context` passed to every invocation.
- `iter.fold(values, state, step)` is a deterministic left fold from the
  lowest index to the highest index (Runtime §5): the accumulator `state`
  is moved into each `step(state, item)` invocation and the returned
  value becomes the next accumulator. The list is borrowed.
- `iter.fold_with(values, state, context, step)` is `fold` with a
  borrowed `context` passed to every step call.
- `iter.consume_each(values, action)` consumes the list as a whole; each
  element is moved into `action(move item)` in increasing index order
  (Runtime §5).
- `iter.consume_each_with(values, context, action)` is `consume_each`
  with a borrowed `context` passed to every invocation.
- `iter.consume_fold(values, state, step)` is a consuming left fold: the
  list is consumed as a whole and each element is moved into
  `step(state, move item)`.
- `iter.consume_fold_with(values, state, context, step)` is
  `consume_fold` with a borrowed `context` passed to every step call.
- `iter.try_fold(values, state, step)` is a short-circuiting left fold,
  lowest index to highest (Runtime §5): each `step(state, item)` returns
  `Result[S, R]`; `Complete(s)` continues with accumulator `s`, and the
  first `Break(r)` stops iteration immediately — the remaining elements
  are not visited — and is returned as the result. Completing every
  element yields `Complete(final state)`. The list is borrowed.
- `iter.try_fold_with(values, state, context, step)` is `try_fold` with a
  borrowed `context` passed to every step call.
- The `borrow` parameters are non-owning: call sites pass plain arguments
  (Core §10.6). For unique `T`, elements are borrowed (`each`, `fold`,
  `try_fold`) or moved exactly once (`consume_each`, `consume_fold`); if
  the instantiated element or accumulator type is Copy, the corresponding
  modes have ordinary copy semantics.
- The `context` value is borrowed for the duration of the operation and
  passed to every invocation; it may be any type, including a unique value
  whose ownership remains with the caller.

Usage:

```stilla
const iter = import("iter");
const builtin = import("builtin");

let total = iter.fold(
    builtin.range(1, 10),
    0,
    fn(move acc: int32, borrow x: int32) -> int32 {
        acc + x
    }
);

// Short-circuit at the first negative value:
let capped = iter.try_fold::[int32, int32, int32](
    builtin.range(1, 10),
    0,
    fn(move acc: int32, borrow x: int32) -> iter.Result[int32, int32] {
        if (x > 5) {
            iter.Result::Break(acc)
        } else {
            iter.Result::Complete(acc + x)
        }
    }
);

match (capped) {
    iter.Result::Complete(v) => builtin.print(builtin.str(v)),
    iter.Result::Break(v) => builtin.print(builtin.str(v))
};
```
