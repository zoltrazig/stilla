struct File { fd: int32; path: str; drop(file) {} }
fn open_file(path: str) -> File { File{ fd: 3, path: path } }
fn inspect(borrow file: File) -> void {}
fn main() -> void {
    let a = open_file("a.txt");
    inspect(a);
}
