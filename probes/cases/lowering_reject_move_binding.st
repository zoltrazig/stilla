const builtin = import("builtin");
struct File { fd: int32; drop(f) { builtin.print("x"); } }
fn main() -> void { let x = File{ fd: 1 }; let y = x; }
