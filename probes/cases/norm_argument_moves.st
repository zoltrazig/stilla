fn f(x: int32) -> int32 { x }
fn main() -> int32 {
    let a = 1;
    let r = f(a) + f(a);
    r
}
