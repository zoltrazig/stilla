struct Box { v: int32; }
fn sink(move b: Box, borrow s: str, t: str, n: int32) -> int32 { n }
fn main() -> int32 {
    let b = Box { v: 1 };
    let s = "x";
    sink(move b, s, s, 2)
}
