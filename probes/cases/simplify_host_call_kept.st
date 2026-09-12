const builtin = import("builtin");
fn f(x: int32) -> int32 {
    let unused: int32 = builtin.hash(x);
    0
}
