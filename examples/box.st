// box — ownership extraction with `builtin.box`/`peek`/`unbox`
// (Runtime §4.5–§4.6, Core §10).
//
// A box owns its payload; extraction is explicit. `peek` returns a
// transient non-owning view (the borrow lifetime follows Core §10.7),
// `unbox` consumes the box and transfers ownership of the payload. A box
// is always affine — it must be moved, never copied.

const builtin = import("builtin");

struct Token { id: int32; }

fn main() -> void {
    let b = builtin.box::[int32](42);

    // peek borrows the box and yields a view; the box stays usable.
    let view = builtin.peek::[int32](b);
    builtin.assert(view == 42, "peek");

    // unbox consumes the box and returns the payload by ownership.
    let v = builtin.unbox::[int32](move b);
    builtin.assert(v == 42, "unbox");

    // A boxed payload still follows the move rules: building and
    // immediately unboxing is the common ownership round trip.
    let t = builtin.box::[Token](Token { id: 7 });
    let t2 = builtin.unbox::[Token](move t);
    builtin.assert(t2.id == 7, "boxed struct round-trip");
}
