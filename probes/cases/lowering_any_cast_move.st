struct File { fd: int32; drop(file) {} }
fn use(a: any) -> File { (move a) as File }
fn main() -> void {}
