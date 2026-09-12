struct Pair[A, B] { first: A; second: B; }
fn identity[T](move value: T) -> T { move value }
type PairList[T] = list[tuple[T, T]];
fn main() -> int32 {
    let p = Pair{ first: 1, second: "x" };
    let v = identity(42);
    let w = identity::[int32](43);
    let f = identity::[int32];
    f(v) + w
}
