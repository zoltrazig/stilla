// functions — named functions, lambdas, and higher-order calls.
//
// Functions are values with explicit `fn(...) -> ...` types. Declarations
// are order-independent, so `main` may refer to helpers declared later.

const builtin = import("builtin");

fn apply(f: fn(int32) -> int32, value: int32) -> int32 {
    f(value)
}

fn main() -> void {
    builtin.assert(apply(increment, 41) == 42, "named function value");

    let double = fn(value: int32) -> int32 { value * 2 };
    builtin.assert(apply(double, 21) == 42, "lambda value");
}

fn increment(value: int32) -> int32 {
    value + 1
}
