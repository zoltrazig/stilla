fn noop() -> void { }
fn id(x: int32) -> int32 { x }
fn add3(a: int32, b: int32, c: int32) -> int32 { a + b + c }
fn mid(x: int32) -> int32 { let y = id(x); add3(y, y, y) }
fn fib(n: int32) -> int32 {
    if (n < 2) { n } else { fib(n - 1) + fib(n - 2) }
}
fn main() -> int32 {
    noop();
    let a = mid(5);
    let b = fib(10);
    a + b
}
