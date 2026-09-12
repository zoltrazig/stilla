const builtin = import("builtin");
struct File { fd: int32; path: str; drop(file) {} }
struct Nothing {}
union Result { Ok(File), Err(str) }
union Shape { Circle(int32), Rect(int32, int32) }
fn open_file(path: str) -> File { File{ fd: 3, path: path } }
fn make_ok(f: File) -> Result { Result::Ok(move f) }
fn mk_pair(f: File) -> tuple[File, int32] { (move f, 42) }
fn mk_list() -> list[int32] { [1, 2, 3] }
fn take(r: Result) -> File {
    match (move r) { Result::Ok(f) => f, Result::Err(e) => open_file(e) }
}
fn area(s: Shape) -> int32 {
    match (s) { Shape::Circle(r) => r, Shape::Rect(w, h) => w * h }
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
fn split(xs: list[File]) -> File {
    let [f, ..rest] = move xs;
    f
}
fn main() -> void {
    let a = Nothing{};
    let b = Nothing{};
    let _ = a;
    let _ = b;
    builtin.print("x");
}
