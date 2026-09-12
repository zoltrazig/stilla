const builtin = import("builtin");
struct File { fd: int32; drop(file) {} }
union Maybe {
    Nothing,
    Just(File),
}
fn open_file() -> File { File { fd: 3 } }
fn main() -> void {
    let f = open_file();
    let m = Maybe::Just(move f);
    let n = Maybe::Nothing;
}
