// generics — polymorphic functions and explicit specialization
// (Core §12).
//
// A generic function's type parameters are resolved at call time.
// `identity::[int32](42)` is frontend.compile-time specialization syntax
// (Core §12.3); when the arguments determine the parameters, the `::[..]`
// can be omitted. Functions are order-independent within a module, so
// `identity` may be referenced before it is declared.

const builtin = import("builtin");

/// identity[T] — pass-through of any duplicable or moved value.
fn identity[T](move value: T) -> T {
    move value
}

/// choose[T] — select one of two values of the same type by a bool.
/// The `if`/`else` expression branches on a bool only, so T never needs
/// to be comparable; it is just carried from parameter to result.
fn choose[T](use_a: bool, a: T, b: T) -> T {
    if (use_a) { a } else { b }
}

fn main() -> void {
    // Explicit specialization: `::[int32]` binds T at the call site.
    let x = identity::[int32](42);
    builtin.assert(x == 42, "identity int32");

    // Inference when the arguments determine T.
    let y = identity(7);
    builtin.assert(y == 7, "identity inferred");

    // The same generic function specializes to different types.
    builtin.assert(choose::[int32](true, 1, 2) == 1, "choose int32");
    builtin.assert(choose::[str](false, "a", "b") == "b", "choose str");

    // Generic builtins specialize the same way (Runtime §4.2).
    builtin.assert(builtin.str::[int32](7) == "7", "str int32");
    builtin.assert(builtin.str::[bool](true) == "true", "str bool");
}
