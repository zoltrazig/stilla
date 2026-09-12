fn g(n: int32) -> int32 { n }
fn f(n: int32) -> int32 {
    if (n == 0) {
        0
    } else {
        g(n - 1)
    }
}
fn main() -> void {}
