struct File { fd: int32; path: str; drop(file) {} }
fn open_file(path: str) -> File { File{ fd: 3, path: path } }
fn choose(c: bool) -> File {
    if (c) { open_file("a") } else { open_file("b") }
}
fn main() -> void {}
