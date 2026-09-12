struct Counter {
    value: int32;
    next: fn(borrow Counter) -> int32;
}
fn main() -> int32 {
    let counter = Counter{
        value: 10,
        next: fn(borrow c: Counter) -> int32 { c.value + 1 }
    };
    counter.next(counter)
}
