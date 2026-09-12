const builtin = import("builtin");
struct File { fd: int32; drop(file) {} }
fn open_file() -> File { File { fd: 3 } }
fn main() -> void {
    let f = open_file();
    let b = builtin.box(move f);
}
