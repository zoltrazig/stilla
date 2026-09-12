struct Pair { x: int32; y: int32; }
fn main() -> int32 {
    let p = Pair{ x: 1, y: 2 };
    let Pair { x, y } = move p;
    x + y
}
