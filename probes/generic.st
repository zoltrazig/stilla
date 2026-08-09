fn identity[T](move value: T) -> T {
    move value
}

fn main() -> void {
    let i = identity::[int32](42);
    let b = identity::[bool](true);
}
