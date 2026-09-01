// builtin — the required `builtin` interface (Runtime §4, Core §3).
//
// Intrinsic module: every function member below is a *declaration without
// a Stilla definition* (the Intrinsics Specification §2). The frontend
// recognizes it as an intrinsic by its standard-library source origin and
// expands each use into ordinary AIR during source-to-AIR lowering. These
// are host-backed: each expansion is a call to the existing host binding,
// dispatched against the host's `builtin` vtable (src/builtin.zig); no
// body is ever lowered.
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

// §4.2 Conversion. Supported types: byte, int32, uint32, int64, uint64,
// float32, float64, bool, str (Runtime §4.2).
fn str[T](value: T) -> str;

// §4.5 Box: construction is by `move`.
fn box[T](move value: T) -> box[T];

// §4.6 Unbox. `unbox` consumes the box and returns ownership of the
// payload; for a *Copy* `box[T]` the call may omit `move` and returns a
// copy without invalidating the source box. There is no non-consuming
// box read: a payload is extracted only by consumption (Core §10.8).
fn unbox[T](move b: box[T]) -> T;

// §4.7 Panic. Terminates the current execution context; no unwinding
// (Runtime §7.1). Return type `never`.
fn panic(message: str) -> never;

// §4.8 Assert. The message is evaluated even when the condition is true.
fn assert(condition: bool, message: str) -> void;

// §4.9 Hash. Supported key types: byte, int32, uint32, int64, uint64, float32,
// float64, bool, str (Runtime §4.9).
// Deterministic and equal for values equal under `==` (Runtime §4.9).
fn hash[T](value: T) -> int32;
