fn identity[T](move value: T) -> T { move value }
fn main() -> int32 { let f = identity::[int32]; f(42) }
