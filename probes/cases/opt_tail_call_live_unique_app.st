const os = import("os");
fn f(n: int32) -> int32 {
    let h = os.get_handle();
    if (n == 0) {
        0
    } else {
        f(n - 1)
    }
}
fn main() -> void {}
