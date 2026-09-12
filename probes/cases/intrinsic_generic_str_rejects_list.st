const builtin = import("builtin");
fn show[T](x: T) -> str { builtin.str(x) }
fn main() -> void { let s = show::[list[int32]]([1, 2]); }
