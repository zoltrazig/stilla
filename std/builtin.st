// builtin — the required `builtin` interface (Runtime §4, Core §3).
//
// Host binding module: every function member below is a *declaration
// without a Stilla definition* (frontend §5.6). The runtime dispatches
// calls to them as system calls against the host's `builtin` vtable
// (src/builtin.zig); no body is ever lowered or evaluated.
//
// `builtin` is an ordinary importable standard-library module (Core §3):
// a program brings it into scope like any other module —
//
//     const builtin = import("builtin");
//
// There is no implicit module binding. This file is the normative
// interface reference; the checker synthesizes the same members on demand
// (src/passes/checker.zig).
//
// The `Option[T]` union is a compile-time *type* member of `builtin`
// (Core §2.5, §2.8: `using builtin.Option`); it is used by the
// standard-library interfaces (`hashmap.get`, `string.index_of`) and is
// matchable in user code.

union Option[T] {
    Some(T),
    None
}

// §4.1 Output.
fn print(message: str) -> void;

// §4.2 Conversion. Supported types: byte, int32, uint32, float32, bool, str.
fn str[T](value: T) -> str;

// §4.3 List length. The list is borrowed and never consumed.
fn len[T](borrow xs: list[T]) -> int32;

// §4.4 Integer range, inclusive: [start, end]; empty when start > end.
fn range(start: int32, end: int32) -> list[int32];

// §4.5 Box: ownership extraction is explicit (`move`).
fn box[T](move value: T) -> box[T];

// §4.6 Peek and unbox. `peek` returns a transient non-owning view
// (written `T` here; the borrow lifetime follows Core §10.7), `unbox`
// consumes the box and returns ownership.
fn peek[T](borrow b: box[T]) -> T;
fn unbox[T](move b: box[T]) -> T;

// §4.7 Panic. Terminates the current execution context; no unwinding
// (Runtime §7.1). Return type `never`.
fn panic(message: str) -> never;

// §4.8 Assert. The message is evaluated even when the condition is true.
fn assert(condition: bool, message: str) -> void;

// §4.9 Hash. Supported key types: byte, int32, uint32, float32, bool, str.
// Deterministic and equal for values equal under `==` (Runtime §4.9).
fn hash[T](value: T) -> int32;
