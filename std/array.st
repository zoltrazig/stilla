// array — concrete, contiguous-memory sequence (StdLib §1, §2).
//
// Host binding module: every function member is a *declaration without a
// Stilla definition* (frontend §5.6); the host implements the storage and
// operations. `Array[T]` is an ordinary nominal struct (StdLib §2): its
// value is an immutable *token* naming a host-owned opaque buffer. Stilla
// never inspects the buffer; the module functions are its only access
// path, and the host owns the buffer's memory and lifetime (StdLib §6).
//
// The element type `T` must be Copy (StdLib §2): the token is Copy when
// `T` is Copy, accessors take plain (Copy) parameters, and `get` returns
// an element by value — a borrowed unique return is not expressible
// (Core §10.7), so unique element types are out of scope for `array`;
// use `list[T]` for unique elements. `make(length, init)` copies `init`
// into every slot; `get` copies element `i` out; invalid indexing traps
// (Runtime §7.2). Type arguments of `get`/`len` occur only in the token
// type and must be written explicitly (`::[T]`, Core §12.3); `make`'s
// `T` is inferred from `init`.

struct Array[T] {}

fn make[T](length: int32, init: T) -> Array[T];
fn get[T](a: Array[T], i: int32) -> T;
fn len[T](a: Array[T]) -> int32;
