const builtin = import("builtin");
struct File { fd: int32; drop(f) { builtin.print("x"); } }
struct Pair { a: File; b: File; }
fn main() -> void { let x = File{ fd: 1 }; let p = Pair{ a: x, b: File{ fd: 2 } }; }
