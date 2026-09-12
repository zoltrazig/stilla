fn id(x: int32) -> int32 { x }
fn apply(f: fn(int32) -> int32, x: int32) -> int32 { f(x) }
fn inc(a: int32) -> int32 { a + 1 }
fn main() -> int32 {
    let t = id(1);      // consumed by `t + 1`: coalesced
    let u = t + 1;
    let b = id(2);      // live across `apply` below: keeps its take
    let c = apply(inc, 3); // indirect: always keeps its take
    b + c + u
}
