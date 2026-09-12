struct File { fd: int32; path: str; drop(file) {} }
fn consume(move n: int32) -> void {}
fn take(move file: File) -> void {}
fn main() -> void {
    let a = 5;
    consume(move a);
    let f = File{ fd: 1, path: "p" };
    take(move f);
}
