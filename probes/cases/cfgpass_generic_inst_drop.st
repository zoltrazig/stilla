const builtin = import("builtin");
struct File { fd: int32; drop(file) {} }
union Option[T] {
    None,
    Some(T),
}
fn open_file() -> File { File { fd: 3 } }
fn main() -> void {
    let o: Option[File] = Option::Some(open_file());
}
