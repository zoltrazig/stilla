fn f(a: int32, b: int32, c: bool) -> int32 {
    let x = a * b;
    let y = if (c) { 1 } else { 2 };
    let z = a * b;
    x + y + z
}
fn main() -> void {}
