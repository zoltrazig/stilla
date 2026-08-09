// box — ownership extraction with `builtin.box` / `builtin.unbox`
// (Runtime §4.5–§4.6, Core §10.8).
//
// A box owns its payload; extraction is explicit and consuming. There is
// no non-consuming box read (no `peek`): a payload is obtained only by
// `unbox`. For a *Copy* payload the box is *Copy* too, so `unbox` may
// omit `move` and returns a copy without invalidating the source box; a
// *Unique* payload requires `move`. A box is affine — it must be moved,
// never copied.

const builtin = import("builtin");

struct Token { id: int32; }

fn main() -> void {
    let b = builtin.box::[int32](42);

    // For a Copy payload the box is Copy (Core §10.3): unboxing without
    // `move` returns a copy and leaves the box usable.
    let v = builtin.unbox::[int32](b);
    builtin.assert(v == 42, "unbox copy");
    builtin.assert(builtin.unbox::[int32](b) == 42, "box still usable");

    // unbox with `move` consumes the box and transfers ownership.
    let w = builtin.unbox::[int32](move b);
    builtin.assert(w == 42, "unbox move");

    // A boxed *Unique* payload is extracted only by consuming the box.
    let t = builtin.box::[Token](Token { id: 7 });
    let t2 = builtin.unbox::[Token](move t);
    builtin.assert(t2.id == 7, "boxed struct round-trip");
}
