const builtin = import("builtin");
struct File { fd: int32; path: str; drop(file) {} }
fn open_file(path: str) -> File { File{ fd: 3, path: path } }
union Result { Ok(File), Err(str) }
fn take(r: Result) -> File {
    match (move r) { Result::Ok(f) => f, Result::Err(e) => open_file(e) }
}
struct Wrapper { inner: File; tag: int32; }
fn unwrap(w: Wrapper) -> File {
    let Wrapper { inner, tag } = move w;
    inner
}
fn take_t(t: tuple[File, int32]) -> File {
    let (f, n) = move t;
    f
}
fn tail(xs: list[int32]) -> list[int32] {
    let [h, ..rest] = xs;
    rest
}
fn main() -> void { builtin.print("x"); }
