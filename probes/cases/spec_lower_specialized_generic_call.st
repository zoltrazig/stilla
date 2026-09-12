fn identity[T](move value: T) -> T { move value }
fn main() -> void { let x = identity::[int32](42); }
