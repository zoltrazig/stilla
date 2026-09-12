fn take3(t: tuple[int32, int32, int32]) -> int32 {
    let (a, b, c) = move t;
    a + b + c
}
fn main() -> int32 { take3((1, 2, 3)) }
