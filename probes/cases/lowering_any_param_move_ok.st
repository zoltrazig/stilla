const builtin = import("builtin");
struct File { fd: int32; drop(f) { builtin.print("x"); } }
fn f(a: any) -> void {}
fn main() -> void {
    f(File{ fd: 2 });
    let g = File{ fd: 3 };
    f(move g);
}
