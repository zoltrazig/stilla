fn add(a: int32, b: int32) -> int32 { a + b }
fn apply(f: fn(int32, int32) -> int32, a: int32, b: int32) -> int32 { f(a, b) }
fn main() -> int32 {
    let z = apply(add, 10, 20);
    z
}
