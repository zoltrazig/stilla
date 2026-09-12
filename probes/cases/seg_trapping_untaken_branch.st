fn guarded(a: int32) -> int32 {
    let r = if (a > 0) { 1 } else { 10 / 0 };
    r
}
fn main() -> void { }
