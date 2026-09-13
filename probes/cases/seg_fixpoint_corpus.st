fn idf(x: int32) -> int32 { x }
fn dup(v: int32) -> int32 { (fn(a: int32) -> int32 { a + a })(idf(v)) }
fn g(a: int32) -> int32 { (a * 1) + (2 + 3) }
fn cse_pair(x: int32, y: int32) -> int32 { (x * y) + (x * y) }
fn main() -> void { }
