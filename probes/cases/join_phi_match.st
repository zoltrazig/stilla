struct File { fd: int32; path: str; drop(file) {} }
fn open_file(path: str) -> File { File{ fd: 3, path: path } }
union MaybeFile { Some(File), None }
fn pick(m: MaybeFile) -> File {
    match (m) {
        MaybeFile::Some(f) => f,
        MaybeFile::None => open_file("x")
    }
}
fn main() -> void {}
