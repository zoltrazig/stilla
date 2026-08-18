// array — concrete, contiguous-memory sequence (StdLib §1, §2).
//
// Host binding module: every function member is a *declaration without a
// Stilla definition* (frontend §5.6); the host implements the storage and
// operations. `Array[T]` is a host-backed opaque nominal type (Core §11.8):
// it has no fields and no Stilla-visible representation, its value is a
// unique opaque handle naming a host-owned contiguous buffer, and only the
// module functions construct, read, and destroy values. Stilla can never
// raw-construct, field-access, or destructure an `Array[T]` (Core §11.8).
//
// `Array[T]` is unique by declaration (Core §11.8): it is never Copy, even
// when `T` is Copy, so consuming operations take the array by `move` and
// return the updated array and the host may mutate the buffer in place
// (StdLib §1, §2); `len`/`get`/`clone` borrow. The element type `T` must
// be Copy (StdLib §2): `make`'s `init` and `set`'s `value` are plain
// parameters, so a unique element is rejected at compile time and
// `Array[Unique]` is uninhabited; a borrowed unique return is not
// expressible (Core §10.7), so `get` returns `T` by value. Invalid
// indexing traps (Runtime §7.2). Type arguments of `len`/`get`/`clone`
// occur only in the token type and must be written explicitly
// (`::[T]`, Core §12.3); `make`'s `T` is inferred from `init`, `set`'s
// from the moved array and `value`.

opaque type Array[T];

fn make[T](length: int32, init: T) -> Array[T];
fn len[T](borrow array: Array[T]) -> int32;
fn get[T](borrow array: Array[T], index: int32) -> T;
fn set[T](move array: Array[T], index: int32, value: T) -> Array[T];
fn clone[T](borrow array: Array[T]) -> Array[T];
