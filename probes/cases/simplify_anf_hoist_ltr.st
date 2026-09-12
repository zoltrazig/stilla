const builtin = import("builtin");
fn pure(x: int32) -> int32 { x * 2 }
fn f(x: int32) -> int32 { pure(1) + builtin.hash(x) }
