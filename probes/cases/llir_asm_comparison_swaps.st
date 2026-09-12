fn sum(n: int32) -> int32 { if (n <= 0) { 0 } else { n + sum(n - 1) } }
fn gtB(a: int32, b: int32) -> int32 { if (a > b) { 1 } else { 0 } }
fn geUB(a: uint32, b: uint32) -> int32 { if (a >= b) { 1 } else { 0 } }
fn eqF(a: float64, b: float64) -> int32 { if (a == b) { 1 } else { 0 } }
fn neI(a: int32) -> int32 { if (a != 5) { 1 } else { 0 } }
fn cmp3(k: int32, a: int32) -> bool { k < a }
fn main() -> int32 {
    let s = sum(4);
    let p = gtB(s, 10);
    let q = geUB(3 as uint32, 4 as uint32);
    let f1: float64 = 1.5;
    let f2: float64 = -2.5;
    let r = eqF(f1, f2);
    let t = neI(7);
    let v = cmp3(2, 9);
    s
}
