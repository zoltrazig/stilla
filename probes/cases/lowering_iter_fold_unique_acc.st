const builtin = import("builtin");
const iter = import("iter");
struct File { fd: int32; drop(file) {} }
fn ff(borrow acc: File, x: int32) -> File { File{ fd: acc.fd + x } }
fn run_fold(xs: list[int32]) -> File {
    let s: File = File{ fd: 0 };
    iter.fold(xs, move s, fn(move a: File, borrow x: int32) -> File { ff(a, x) })
}
fn main() -> void { builtin.print("x"); }
