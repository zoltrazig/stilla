const builtin = import("builtin");
fn pure(x: int32) -> int32 { x + 1 }
fn f(x: int32) -> int32 {
    let unused: int32 = pure(x);
    pure(1) + builtin.hash(x)
}
