struct File { fd: int32; drop(file) {} }
struct Other { fd: int32; drop(file) {} }
fn open_file() -> File { File { fd: 3 } }
fn open_other() -> Other { Other { fd: 4 } }
fn main() -> void {
    let x = open_file();
    let y = open_other();
    let t = (move x, move y);
}
