const builtin = import("builtin");
fn f(c: bool, x: int32) -> int32 {
    if (c) { builtin.hash(x) } else { 0 }
}
