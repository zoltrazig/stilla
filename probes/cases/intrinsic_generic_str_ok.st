const builtin = import("builtin");
fn show[T](x: T) -> str { builtin.str(x) }
fn main() -> void { let s = show::[int32](42); }
