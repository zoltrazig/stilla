fn take(move s: str) -> void {}
struct File { fd: int32; drop(file) {} }
fn peek(borrow f: File) -> void {}
fn main() -> void {
    let s = "hi";
    take(move s);
    let f = File{ fd: 1 };
    peek(f);
}
