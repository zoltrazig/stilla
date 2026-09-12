union U { A(int32), B(bool) }
fn pick(u: U, d: int32) -> int32 {
    match (u) {
        U::A(n) => if (n > 0) { n } else { d },
        U::B(b) => if (b) { 1 } else { 0 }
    }
}
fn main() -> void {}
