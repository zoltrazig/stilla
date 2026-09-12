struct File { fd: int32; drop(file) {} }
fn describe(a: any) -> int32 {
    match (a) { File f => 1, _ => 0 }
}
fn main() -> void {}
