// array — concrete, contiguous-memory sequence (StdLib §1, §2).
//
// Host binding module: every function member is a *declaration without a
// Stilla definition* (frontend §5.6); the host implements the storage and
// operations. `Array[T]` is a concrete implementation type whose value is
// itself a `hostdata` payload (StdLib §6, Core §11.7): Stilla never
// inspects it, and the module functions are its only access path. The
// empty `struct Array[T]` below is the interface token: a nominal,
// statically known type that signatures can reference. It is not
// constructible in meaningful Stilla; the host binding functions are the
// intended surface.
//
// `Array[T]` is immutable after construction; it is always affine because
// it wraps an opaque `hostdata` payload (StdLib §6, Core §11.7) — not
// duplicable even when `T` is duplicable. The `make`/`get`/`len`
// parameters are declared `move`; call sites pass a plain argument to
// borrow (Core §10.6). `get` reads element `i`; invalid indexing traps
// (Runtime §7.2).

struct Array[T] {}

fn make[T](length: int32, move init: T) -> Array[T];
fn get[T](move a: Array[T], i: int32) -> T;
fn len[T](move a: Array[T]) -> int32;
