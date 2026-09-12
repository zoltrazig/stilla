const builtin = import("builtin");
const array = import("array");
struct File {
    arr: array.Array[int32];
    drop(file) { builtin.print("closing"); }
}
fn main() -> void {
    let f = File { arr: array.make(10, 0) };
}
