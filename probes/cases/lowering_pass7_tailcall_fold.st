const builtin = import("builtin");
struct File { fd: int32; drop(file) {} }
fn step(borrow f: File, x: int32) -> int32 { f.fd + x }
fn fold_files(xs: list[int32], move acc: File) -> File {
    match (xs) {
        [] => acc,
        [h, ..t] => {
            let next: File = File{ fd: step(acc, h) };
            fold_files(t, move next)
        }
    }
}
fn main() -> void { builtin.print("x"); }
