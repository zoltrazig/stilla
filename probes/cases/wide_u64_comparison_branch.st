fn pick(a: uint64, b: uint64) -> uint64 {
    if (a < b) { 1 } else { 2 }
}
fn main() -> uint64 { pick(4294967296, 5) }
