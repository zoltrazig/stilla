fn f(n: int32) -> int32 {
    if (n == 0) {
        0
    } else {
        1 + f(n - 1)
    }
}
fn main() -> void {}
