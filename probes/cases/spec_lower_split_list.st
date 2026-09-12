struct File { fd: int32; drop(file) {} }
fn consume(move f: File) -> void {}
fn main() -> void {
    let xs = [File{ fd: 1 }];
    let [f, ..rest] = move xs;
    consume(move f);
}
