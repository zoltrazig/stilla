fn pure(x: int32) -> int32 { x + 1 }
fn f(x: int32) -> int32 { let unused: int32 = pure(x); 7 }
fn main() -> void { let _ = f(1); }
