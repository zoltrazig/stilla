// list — list operations: the bounds-checked element read and the
// derived operations (StdLib §8).
//
// `get` is the host-binding element read (Runtime §4.10): declared
// without a body and lowered by the frontend to the bounds-checked
// `read_index` op — not a system call, because a syscall's vtable slot
// cannot return an element of arbitrary type `T` by value. It is a
// member of this module rather than of `builtin` so that the list
// operations live together.
//
// The derived operations are ordinary Stilla source. Stilla defines no
// equality on generic element types (Core §16.3), so the membership
// operations take an explicit `eq` comparison function; Stilla has no
// closures (Core §18), so the comparison and the needle are threaded as
// function parameters (Core §13.5). `head` consumes the list: only a
// moved element can be returned by value for every `T` (Core §10.7,
// §11.5).
//
// Stilla has no list-construction primitive beyond literals and
// `list.range` (Runtime §4.4), so list-producing operations
// (`reverse`, `append`, `take`, `drop`, `filter`, `map`) are not
// expressible in source and are not provided.

const builtin = import("builtin");
using builtin.Option;

// §4.10 List element read, bounds-checked (Runtime §7.2). The list is
// borrowed and never consumed. A *Copy* element is returned as an owned
// copy; a *Unique* element is returned as a borrowed view (Core §10.7,
// §11.5) and cannot be independently moved.
fn get[T](borrow xs: list[T], index: int32) -> T;

// §4.3 List length. The list is borrowed and never consumed. A host
// binding: calls lower to the `list#len` system call (Runtime §4.3).
fn len[T](borrow xs: list[T]) -> int32;

// §4.4 Integer range, inclusive: [start, end]; empty when start > end.
// A host binding: calls lower to the `list#range` system call (Runtime
// §4.4). Like `get` and `len`, it is a member of this module rather
// than of `builtin` so that the list operations live together.
fn range(start: int32, end: int32) -> list[int32];

// True when the list has no elements; the list is borrowed.
fn is_empty[T](borrow xs: list[T]) -> bool {
    len(xs) == 0
}

// True when some element equals `needle` under `eq`, in increasing
// index order; iteration stops at the first match. The list and the
// needle are borrowed.
fn contains[T](
    borrow xs: list[T],
    borrow needle: T,
    eq: fn(borrow T, borrow T) -> bool
) -> bool {
    match (xs) {
        [] => false,
        [h, ..t] => {
            if (eq(needle, h)) {
                true
            } else {
                contains(t, needle, eq)
            }
        }
    }
}

// The number of elements equal to `needle` under `eq`. The list and
// the needle are borrowed.
fn count[T](
    borrow xs: list[T],
    borrow needle: T,
    eq: fn(borrow T, borrow T) -> bool
) -> int32 {
    match (xs) {
        [] => 0,
        [h, ..t] => {
            if (eq(needle, h)) {
                1 + count(t, needle, eq)
            } else {
                count(t, needle, eq)
            }
        }
    }
}

// The lowest index at which an element equals `needle` under `eq`, or
// None when nothing matches; iteration stops at the first match. The
// list and the needle are borrowed.
fn index_of[T](
    borrow xs: list[T],
    borrow needle: T,
    eq: fn(borrow T, borrow T) -> bool
) -> Option[int32] {
    index_of_from(xs, needle, eq, 0)
}

// Recursion helper for `index_of`; `index` is the position of the
// current head. Helper of `index_of`, not part of the documented
// surface.
fn index_of_from[T](
    borrow xs: list[T],
    borrow needle: T,
    eq: fn(borrow T, borrow T) -> bool,
    index: int32
) -> Option[int32] {
    match (xs) {
        [] => Option[int32]::None,
        [h, ..t] => {
            if (eq(needle, h)) {
                Option[int32]::Some(index)
            } else {
                index_of_from(t, needle, eq, index + 1)
            }
        }
    }
}

// The first element, consuming the list: the element is moved out and
// the remaining elements are dropped. None when the list is empty.
fn head[T](move xs: list[T]) -> Option[T] {
    match (move xs) {
        [] => Option[T]::None,
        [h, ..t] => Option[T]::Some(move h),
    }
}
