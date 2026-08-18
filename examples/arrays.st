// array — concrete, contiguous-memory sequence (StdLib §1, §2).
//
// `Array[T]` is a host-backed opaque nominal type (Core §11.8): unique by
// declaration, no raw construction, only the module's host bindings produce
// and consume values. `set` consumes the input array (`move a`) and returns
// the updated array, so the host may mutate the buffer in place and the
// source semantics stay purely functional; `len`/`get`/`clone` borrow. The
// element type must be Copy (a unique element is rejected), so `get`
// returns `T` by value. Stilla has no loop construct, so traversal is
// explicit recursion over an index.

const builtin = import("builtin");
const array = import("array");

/// Sum elements a[0..n) with explicit index recursion (no loops in Stilla).
fn sum_from(borrow a: array.Array[int32], n: int32, i: int32) -> int32 {
    if (i >= n) {
        0
    } else {
        array.get::[int32](a, i) + sum_from(a, n, i + 1)
    }
}

/// Copy a[i..n) into a fresh array.
fn copy_from(borrow src: array.Array[int32], n: int32, i: int32) -> array.Array[int32] {
    if (i >= n) {
        array.make(0, 0)
    } else {
        let rest = copy_from(src, n, i + 1);
        array.set::[int32](move rest, i, array.get::[int32](src, i))
    }
}

fn main() -> void {
    // make infers T from init; len/g get borrow the array.
    let a = array.make(5, 0);
    builtin.assert(array.len::[int32](a) == 5, "length");
    builtin.assert(array.get::[int32](a, 0) == 0, "zero-initialized");

    // set consumes and returns: each step threads the moved array.
    let a = array.set(move a, 0, 10);
    let a = array.set(move a, 1, 20);
    let a = array.set(move a, 2, 30);
    let a = array.set(move a, 3, 40);
    let a = array.set(move a, 4, 50);
    builtin.assert(array.get::[int32](a, 4) == 50, "set updates in place");

    // Recursive traversal over the borrowed array.
    builtin.assert(sum_from(a, 5, 0) == 150, "recursive sum");

    // clone gives independent storage: mutating the copy leaves a intact.
    let b = array.clone::[int32](a);
    let b = array.set(move b, 0, 999);
    builtin.assert(array.get::[int32](a, 0) == 10, "clone is independent");
    builtin.assert(array.get::[int32](b, 0) == 999, "clone mutated");

    // A recursive builder copies the array back-to-front.
    let c = copy_from(a, 5, 0);
    builtin.assert(array.len::[int32](c) == 5, "copy length");
    builtin.assert(array.get::[int32](c, 4) == 50, "copy contents");
}
