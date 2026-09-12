struct File { fd: int32; path: str; drop(file) {} }
struct Holder { file: File; drop(h) {} }
fn f(borrow h: Holder) -> int32 {
    h.file.fd + h.file.fd
}
fn main() -> void {}
