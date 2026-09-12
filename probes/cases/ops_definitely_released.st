struct File { fd: int32; drop(file) {} }
fn consume(move f: File) -> void {}
fn main() -> void {
    let f = File{ fd: 1 };
    if (true) { consume(move f); } else { consume(move f); }
}
