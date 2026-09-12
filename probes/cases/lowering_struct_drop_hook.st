const builtin = import("builtin");
struct File {
    fd: int32;
    path: str;
    drop(file) {
        builtin.print(file.path);
    }
}
fn main() -> void {
    let f = File{ fd: 3, path: "x" };
}
