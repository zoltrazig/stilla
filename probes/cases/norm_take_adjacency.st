fn f(x: int32) -> int32 { x }
fn g() -> void {}
fn main() -> int32 {
    let a = f(1);
    g();
    a
}
