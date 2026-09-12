const os = import("os");
const builtin = import("builtin");
struct File {
    fd: int32;
    path: str;
    drop(file) { os.close(file.fd); }
}
fn open(path: str) -> File { File{ fd: os.open(path), path: path } }
fn create(path: str) -> File { File{ fd: os.create(path), path: path } }
fn inspect(borrow file: File) -> void { builtin.print(file.path); }
fn main() -> void {
    let handle = open("data.txt");
    inspect(handle);
    drop handle;
}
