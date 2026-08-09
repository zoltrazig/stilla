fn add(a: int32, b: int32) -> int32 {
    a + b
}

fn twice(value: int32) -> int32 {
    add(value, value)
}

fn apply(f: fn(int32) -> int32, value: int32) -> int32 {
    f(value)
}

fn inspect(borrow value: str) -> bool {
    value == "probe"
}

fn consume(move value: str) -> void {
    drop value;
}

fn main() -> void {
    let _ = twice(21);
    let f = fn(value: int32) -> int32 { value + 1 };
    let _ = apply(f, 41);
    let borrowed = "probe";
    let _ = inspect(borrowed);
    consume(move borrowed);
}
