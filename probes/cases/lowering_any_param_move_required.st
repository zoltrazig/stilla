const builtin = import("builtin");
struct File { fd: int32; drop(f) { builtin.print("x"); } }
fn f(a: any) -> void {}
fn main() -> void { let h = File{ fd: 4 }; f(h); }
