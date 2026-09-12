const builtin = import("builtin");
struct File { fd: int32; drop(file) {} }
union Maybe {
    Nothing,
    Just(File),
}
fn open_file() -> File { File { fd: 3 } }
fn main() -> void {
    let f1 = open_file();
    let f2 = open_file();
    let m1 = Maybe::Just(move f1);
    let m2 = Maybe::Just(move f2);
    drop m1;
    match (m2) {
        Maybe::Nothing => builtin.print("none"),
        Maybe::Just(f) => builtin.print(builtin.str(f.fd)),
    }
}
