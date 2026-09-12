struct S { x: int32; }
fn f(s: S) -> float32 {
    let a = s.x;
    let b = s.x;
    let c = a as float32;
    let d = b as float32;
    c + d
}
fn main() -> void {}
