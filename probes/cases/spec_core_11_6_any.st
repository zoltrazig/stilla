const builtin = import("builtin");
struct File { fd: int32; drop(f) { builtin.print("x"); } }
fn open_file(path: str) -> File { File{ fd: 1 } }
fn main() -> void {
    let a: any = 42;
    let b: any = "hello";
    let c: any = open_file("f");
}
