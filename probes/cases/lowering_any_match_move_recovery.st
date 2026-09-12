struct File { fd: int32; drop(file) {} }
fn describe(a: any) -> int32 {
    match (move a) { File f => f.fd, _ => 0 }
}
fn main() -> void {}
