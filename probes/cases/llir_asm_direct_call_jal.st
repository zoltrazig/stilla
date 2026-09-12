fn recurse(n: int32) -> int32 {
    if (n <= 0) { 0 } else { n + recurse(n - 1) }
}
fn apply(f: fn(int32) -> int32, x: int32) -> int32 { f(x) }
fn inc(a: int32) -> int32 { a + 1 }
fn main() -> int32 {
    let t = recurse(3);
    let u = apply(inc, 4);
    t + u
}
