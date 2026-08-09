struct Pair[A, B] {
    first: A;
    second: B;
}

union Maybe[T] {
    some(T), none
}

type PairList[T] = list[tuple[T, T]];

fn identity[T](move value: T) -> T {
    move value
}

fn main() -> void {
    let pair = Pair { first: 1, second: "two" };
    let value: Maybe[int32] = Maybe::some(42);
    let inferred = identity(7);
    let specialized = identity::[int32];
    let explicit = specialized(8);
    let pairs: list[tuple[int32, int32]] = [(inferred, explicit)];
    let _ = pair.first;
    let _ = value;
    let _ = pairs;
}
