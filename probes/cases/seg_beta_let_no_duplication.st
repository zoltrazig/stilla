fn idf(x: int32) -> int32 { x }
fn dup(v: int32) -> int32 { (fn(a: int32) -> int32 { a + a })(idf(v)) }
fn main() -> void { }
